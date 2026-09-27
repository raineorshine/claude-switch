//! cloud.zig — hand off cloud Code sessions and continue them on another account.
//!
//! Cloud sessions live on Anthropic's servers under the account that created
//! them. Before the switch each recent one is downloaded into a throwaway clone
//! (`claude -p --teleport`) where `/ce-handoff create` writes HANDOFF.md. After
//! the switch a new cloud session is created from that clone and sent the
//! handoff, so the task continues on the next account.

const std = @import("std");
const exec = @import("exec.zig");
const http = @import("http.zig");
const json = @import("json.zig");
const usage = @import("usage.zig");

pub const SESSIONS_URL = "https://api.anthropic.com/v1/sessions";
pub const HANDOFF_FILE = "HANDOFF.md";
const DAY_S: i64 = 24 * 60 * 60;

pub const TELEPORT_TIMEOUT_S: i64 = 20 * 60;
pub const CREATE_TIMEOUT_S: i64 = 45;
pub const SEND_TIMEOUT_S: i64 = 5 * 60;
pub const CLONE_TIMEOUT_S: i64 = 5 * 60;

/// Tools the unattended teleport may use: read the repo, run the skill, write one file.
pub const TELEPORT_ALLOWED_TOOLS = "Read,Glob,Grep,Skill,Write(" ++ HANDOFF_FILE ++ ")";

/// Every unattended claude run in a cloned repo loads only the user's own
/// settings, never the clone's project settings, hooks, or MCP servers.
pub const ISOLATION_FLAGS = [_][]const u8{ "--setting-sources", "user", "--strict-mcp-config" };

pub const Session = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    env_kind: []const u8,
    created_at: i64,
    repo_url: ?[]const u8,
    branch: ?[]const u8,
};

pub const Page = struct {
    sessions: []Session,
    has_more: bool,
    last_id: ?[]const u8,
};

/// Parses one page of `/v1/sessions`. All memory comes from `arena`.
pub fn parsePage(arena: std.mem.Allocator, body: []const u8) !Page {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.MalformedSessionList;
    if (root != .object) return error.MalformedSessionList;
    const data = root.object.get("data") orelse return error.MalformedSessionList;
    if (data != .array) return error.MalformedSessionList;

    var out: std.ArrayList(Session) = .empty;
    for (data.array.items) |s| {
        const id = json.stringField(s, "id") orelse continue;
        const created = json.stringField(s, "created_at") orelse continue;
        var repo: ?[]const u8 = null;
        if (s.object.get("session_context")) |ctx| {
            if (ctx == .object) if (ctx.object.get("sources")) |sources| {
                if (sources == .array) for (sources.array.items) |src| {
                    const kind = json.stringField(src, "type") orelse continue;
                    if (std.mem.eql(u8, kind, "git_repository")) {
                        repo = json.stringField(src, "url");
                        break;
                    }
                };
            };
        }
        var branch: ?[]const u8 = null;
        if (s.object.get("external_metadata")) |meta| {
            if (meta == .object) if (meta.object.get("current_branches")) |b| {
                if (b == .object) {
                    var it = b.object.iterator();
                    while (it.next()) |e| if (e.value_ptr.* == .string) {
                        branch = e.value_ptr.string;
                        break;
                    };
                }
            };
        }
        try out.append(arena, .{
            .id = id,
            .title = json.stringField(s, "title") orelse "",
            .status = json.stringField(s, "session_status") orelse "",
            .env_kind = json.stringField(s, "environment_kind") orelse "",
            .created_at = usage.parseIso8601(created) catch continue,
            .repo_url = repo,
            .branch = branch,
        });
    }
    const has_more = if (root.object.get("has_more")) |h| h == .bool and h.bool else false;
    return .{ .sessions = try out.toOwnedSlice(arena), .has_more = has_more, .last_id = json.stringField(root, "last_id") };
}

/// R8: cloud sessions that are running, or open and started in the last 24 hours.
pub fn shouldHandOff(s: Session, now_s: i64) bool {
    if (!std.mem.eql(u8, s.env_kind, "anthropic_cloud")) return false;
    if (std.mem.eql(u8, s.status, "archived")) return false;
    if (std.mem.eql(u8, s.status, "running")) return true;
    return now_s - s.created_at <= DAY_S;
}

/// Lists every session on the signed-in account, following `after_id` paging.
pub fn list(arena: std.mem.Allocator, io: std.Io, access_token: []const u8, org_uuid: []const u8) ![]Session {
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{access_token});
    var all: std.ArrayList(Session) = .empty;
    var after: ?[]const u8 = null;
    var pages: usize = 0;
    while (pages < 20) : (pages += 1) {
        const url = if (after) |a|
            try std.fmt.allocPrint(arena, "{s}?limit=50&after_id={s}", .{ SESSIONS_URL, a })
        else
            try std.fmt.allocPrint(arena, "{s}?limit=50", .{SESSIONS_URL});
        const resp = try http.send(arena, io, .{
            .url = url,
            .headers = &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "anthropic-beta", .value = "ccr-byoc-2025-07-29" },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
                .{ .name = "x-organization-uuid", .value = org_uuid },
            },
        });
        if (resp.status != 200) return error.SessionListFailed;
        const page = try parsePage(arena, resp.body);
        try all.appendSlice(arena, page.sessions);
        if (!page.has_more or page.last_id == null) break;
        after = page.last_id;
    }
    return all.toOwnedSlice(arena);
}

pub fn handoffPrompt(gpa: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(gpa, "/ce-handoff create — write the handoff to ./{s} in the current directory and nowhere else.", .{HANDOFF_FILE});
}

/// argv for the unattended teleport. Never carries a bypass permission flag.
pub fn teleportArgv(gpa: std.mem.Allocator, claude: []const u8, session_id: []const u8, prompt: []const u8) ![]const []const u8 {
    const argv = try gpa.alloc([]const u8, 12);
    argv[0..12].* = .{ claude, ISOLATION_FLAGS[0], ISOLATION_FLAGS[1], ISOLATION_FLAGS[2], "-p", "--teleport", session_id, "--allowedTools", TELEPORT_ALLOWED_TOOLS, "--output-format", "json", prompt };
    return argv;
}

/// The id printed by `claude --cloud` ("Created cloud session: … session_…").
pub fn parseCreatedId(output: []const u8) ?[]const u8 {
    const marker = "session_";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, output, i, marker)) |at| {
        var end = at + marker.len;
        while (end < output.len and (std.ascii.isAlphanumeric(output[end]) or output[end] == '_')) end += 1;
        if (end - at > marker.len + 8) return output[at..end];
        i = end;
    }
    return null;
}

pub fn continuationMessage(gpa: std.mem.Allocator, handoff: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\This session continues a task that was running on another Claude account, which ran out of weekly usage. The handoff below was written by /ce-handoff from that session. Read it, orient yourself in this repository, and wait for my go-ahead before changing anything.
        \\
        \\{s}
    , .{handoff});
}

pub const Handoff = struct {
    /// Temporary working directory (clone or empty dir) kept for the continuation.
    work_dir: []u8,
    /// Where the handoff was saved, under the handoffs directory.
    saved_path: []u8,

    pub fn deinit(h: Handoff, gpa: std.mem.Allocator) void {
        gpa.free(h.work_dir);
        gpa.free(h.saved_path);
    }
};

pub const Failure = struct { reason: []const u8 };

/// Downloads `s` into a throwaway clone and writes its handoff there, then saves
/// a copy under `out_dir`. On failure the temp dir is removed and a reason returned.
pub fn handOff(gpa: std.mem.Allocator, io: std.Io, claude: []const u8, s: Session, tmp_root: []const u8, out_dir: []const u8) HandOffResult {
    return handOffWithTimeout(gpa, io, claude, s, tmp_root, out_dir, TELEPORT_TIMEOUT_S);
}

pub const HandOffResult = union(enum) { ok: Handoff, failed: []const u8 };

/// Shallow-clones `url` into `dest`, on `branch` when given. True on success.
fn cloneRepo(gpa: std.mem.Allocator, io: std.Io, url: []const u8, branch: ?[]const u8, dest: []const u8) bool {
    const argv: []const []const u8 = if (branch) |b|
        &.{ "git", "clone", "--quiet", "--depth", "1", "--branch", b, url, dest }
    else
        &.{ "git", "clone", "--quiet", "--depth", "1", url, dest };
    const r = exec.run(gpa, io, .{ .argv = argv, .timeout_s = CLONE_TIMEOUT_S }) catch return false;
    defer r.deinit(gpa);
    return r.ok();
}

fn handOffWithTimeout(gpa: std.mem.Allocator, io: std.Io, claude: []const u8, s: Session, tmp_root: []const u8, out_dir: []const u8, timeout_s: i64) HandOffResult {
    const work = std.fmt.allocPrint(gpa, "{s}/{s}", .{ tmp_root, s.id }) catch return .{ .failed = "out of memory" };
    var keep = false;
    defer if (!keep) {
        exec.removeTree(gpa, io, work);
        gpa.free(work);
    };
    exec.removeTree(gpa, io, work);

    if (s.repo_url) |url| {
        // The session's branch when it still exists, else the default branch.
        const on_branch = if (s.branch) |b| cloneRepo(gpa, io, url, b, work) else false;
        if (!on_branch) {
            exec.removeTree(gpa, io, work);
            if (!cloneRepo(gpa, io, url, null, work)) return .{ .failed = "repository could not be cloned" };
        }
    } else {
        std.Io.Dir.cwd().createDirPath(io, work) catch return .{ .failed = "temporary directory could not be created" };
    }

    const prompt = handoffPrompt(gpa) catch return .{ .failed = "out of memory" };
    defer gpa.free(prompt);
    const argv = teleportArgv(gpa, claude, s.id, prompt) catch return .{ .failed = "out of memory" };
    defer gpa.free(argv);
    const r = exec.run(gpa, io, .{ .argv = argv, .cwd = work, .timeout_s = timeout_s }) catch return .{ .failed = "claude could not be started" };
    defer r.deinit(gpa);
    if (r.timed_out) return .{ .failed = "timed out" };

    const file = std.fs.path.join(gpa, &.{ work, HANDOFF_FILE }) catch return .{ .failed = "out of memory" };
    defer gpa.free(file);
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(4 * 1024 * 1024)) catch
        return .{ .failed = if (r.ok()) "handoff file was not written" else "handoff run failed" };
    defer gpa.free(text);

    std.Io.Dir.cwd().createDirPath(io, out_dir) catch return .{ .failed = "handoffs directory could not be created" };
    const name = std.fmt.allocPrint(gpa, "{s}.md", .{s.id}) catch return .{ .failed = "out of memory" };
    defer gpa.free(name);
    const saved = std.fs.path.join(gpa, &.{ out_dir, name }) catch return .{ .failed = "out of memory" };
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = saved, .data = text }) catch {
        gpa.free(saved);
        return .{ .failed = "handoff could not be saved" };
    };
    keep = true;
    return .{ .ok = .{ .work_dir = work, .saved_path = saved } };
}

/// Creates a cloud session on the signed-in account from `h.work_dir` and sends
/// it the handoff. Always removes the work dir. Returns the new session id.
pub const ContinueResult = union(enum) { ok: []u8, failed: []const u8 };

pub fn continueFrom(gpa: std.mem.Allocator, io: std.Io, claude: []const u8, title: []const u8, h: Handoff) ContinueResult {
    defer exec.removeTree(gpa, io, h.work_dir);
    const text = std.Io.Dir.cwd().readFileAlloc(io, h.saved_path, gpa, .limited(4 * 1024 * 1024)) catch return .{ .failed = "handoff file is missing" };
    defer gpa.free(text);

    const new_title = std.fmt.allocPrint(gpa, "{s} (continued)", .{title}) catch return .{ .failed = "out of memory" };
    defer gpa.free(new_title);
    const created = exec.run(gpa, io, .{
        .argv = &.{ "/usr/bin/script", "-q", "/dev/null", claude, ISOLATION_FLAGS[0], ISOLATION_FLAGS[1], ISOLATION_FLAGS[2], "--cloud", new_title },
        .cwd = h.work_dir,
        .timeout_s = CREATE_TIMEOUT_S,
    }) catch return .{ .failed = "claude could not be started" };
    defer created.deinit(gpa);
    const id = parseCreatedId(created.stdout) orelse return .{ .failed = "cloud session was not created" };
    const id_owned = gpa.dupe(u8, id) catch return .{ .failed = "out of memory" };

    const msg = continuationMessage(gpa, text) catch {
        gpa.free(id_owned);
        return .{ .failed = "out of memory" };
    };
    defer gpa.free(msg);
    const sent = exec.run(gpa, io, .{
        .argv = &.{ claude, ISOLATION_FLAGS[0], ISOLATION_FLAGS[1], ISOLATION_FLAGS[2], "-p", msg, "--cloud", id_owned },
        .cwd = h.work_dir,
        .timeout_s = SEND_TIMEOUT_S,
    }) catch {
        gpa.free(id_owned);
        return .{ .failed = "handoff could not be sent" };
    };
    defer sent.deinit(gpa);
    if (sent.timed_out) {
        gpa.free(id_owned);
        return .{ .failed = "timed out" };
    }
    if (!sent.ok()) {
        gpa.free(id_owned);
        return .{ .failed = "handoff could not be sent" };
    }
    return .{ .ok = id_owned };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const PAGE =
    \\{"data":[
    \\ {"id":"session_run","title":"Running","session_status":"running","environment_kind":"anthropic_cloud","created_at":"2026-09-20T10:00:00Z",
    \\  "session_context":{"sources":[{"type":"git_repository","url":"https://github.com/o/r"}]},
    \\  "external_metadata":{"current_branches":{"":"claude/b1"}}},
    \\ {"id":"session_recent","title":"Recent","session_status":"idle","environment_kind":"anthropic_cloud","created_at":"2026-09-27T19:00:00Z"},
    \\ {"id":"session_old","title":"Old","session_status":"idle","environment_kind":"anthropic_cloud","created_at":"2026-09-24T10:00:00Z"},
    \\ {"id":"session_bridge","title":"Local","session_status":"running","environment_kind":"bridge","created_at":"2026-09-27T19:00:00Z"},
    \\ {"id":"session_arch","title":"Done","session_status":"archived","environment_kind":"anthropic_cloud","created_at":"2026-09-27T20:00:00Z"}
    \\],"has_more":true,"last_id":"session_arch"}
;

test "parsePage reads sessions, repo, branch and paging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const page = try parsePage(arena.allocator(), PAGE);
    try std.testing.expectEqual(@as(usize, 5), page.sessions.len);
    try std.testing.expect(page.has_more);
    try std.testing.expectEqualStrings("session_arch", page.last_id.?);
    try std.testing.expectEqualStrings("https://github.com/o/r", page.sessions[0].repo_url.?);
    try std.testing.expectEqualStrings("claude/b1", page.sessions[0].branch.?);
    try std.testing.expect(page.sessions[1].repo_url == null);
}

test "shouldHandOff keeps running and recent cloud sessions only (AE3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const page = try parsePage(arena.allocator(), PAGE);
    const now = try usage.parseIso8601("2026-09-27T22:00:00Z");
    var picked: std.ArrayList([]const u8) = .empty;
    defer picked.deinit(std.testing.allocator);
    for (page.sessions) |s| if (shouldHandOff(s, now)) try picked.append(std.testing.allocator, s.id);
    try std.testing.expectEqual(@as(usize, 2), picked.items.len);
    try std.testing.expectEqualStrings("session_run", picked.items[0]);
    try std.testing.expectEqualStrings("session_recent", picked.items[1]);
}

test "parsePage rejects a body without data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MalformedSessionList, parsePage(arena.allocator(), "{\"error\":\"x\"}"));
}

test "teleportArgv scopes tools and never bypasses permissions" {
    const gpa = std.testing.allocator;
    const argv = try teleportArgv(gpa, "claude", "session_1", "do it");
    defer gpa.free(argv);
    try std.testing.expectEqualStrings("--setting-sources", argv[1]);
    try std.testing.expectEqualStrings("user", argv[2]);
    try std.testing.expectEqualStrings("--strict-mcp-config", argv[3]);
    try std.testing.expectEqualStrings("--teleport", argv[5]);
    try std.testing.expectEqualStrings("session_1", argv[6]);
    try std.testing.expectEqualStrings(TELEPORT_ALLOWED_TOOLS, argv[8]);
    try std.testing.expectEqualStrings("do it", argv[11]);
    for (argv) |a| {
        try std.testing.expect(std.mem.indexOf(u8, a, "dangerously") == null);
        try std.testing.expect(std.mem.indexOf(u8, a, "bypass") == null);
        try std.testing.expect(std.mem.indexOf(u8, a, "permission-mode") == null);
    }
}

test "parseCreatedId finds the id among terminal escapes" {
    const out = "\x1b[2K\x1b[1GCreated cloud session: csw test\r\n\x1b[36mclaude.ai/code/session_01NbmheqtYbw7mtm2boQNuYC\x1b[0m\r\n";
    try std.testing.expectEqualStrings("session_01NbmheqtYbw7mtm2boQNuYC", parseCreatedId(out).?);
    try std.testing.expect(parseCreatedId("no id here") == null);
}

test "handOff with an unreachable repo fails and leaves no temp dir" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..len];
    const s: Session = .{ .id = "session_x", .title = "t", .status = "running", .env_kind = "anthropic_cloud", .created_at = 0, .repo_url = "/nonexistent/repo", .branch = null };
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);
    const r = handOff(gpa, std.testing.io, "/usr/bin/false", s, root, out_dir);
    try std.testing.expectEqualStrings("repository could not be cloned", r.failed);
    const work = try std.fs.path.join(gpa, &.{ root, "session_x" });
    defer gpa.free(work);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, work, .{}));
}

test "handOff reports a missing handoff file and removes the temp dir" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..len];
    const s: Session = .{ .id = "session_y", .title = "t", .status = "running", .env_kind = "anthropic_cloud", .created_at = 0, .repo_url = null, .branch = null };
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);
    const r = handOff(gpa, std.testing.io, "/usr/bin/true", s, root, out_dir);
    try std.testing.expectEqualStrings("handoff file was not written", r.failed);
}

test "handOff times out a claude that never exits" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..len];
    // A stand-in "claude" that ignores its arguments and hangs.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hang.sh", .data = "#!/bin/sh\nexec sleep 600\n", .flags = .{ .permissions = .fromMode(0o755) } });
    const hang = try std.fs.path.join(gpa, &.{ root, "hang.sh" });
    defer gpa.free(hang);
    const s: Session = .{ .id = "session_z", .title = "t", .status = "running", .env_kind = "anthropic_cloud", .created_at = 0, .repo_url = null, .branch = null };
    const out_dir = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_dir);
    const r = handOffWithTimeout(gpa, std.testing.io, hang, s, root, out_dir, 1);
    try std.testing.expectEqualStrings("timed out", r.failed);
}

/// A stand-in claude for continueFrom: `--cloud <title>` prints a created id;
/// `-p` exits with `send_exit`.
fn fakeContinueClaude(dir: std.Io.Dir, send_exit: u8) !void {
    const script = try std.fmt.allocPrint(std.testing.allocator,
        \\#!/bin/sh
        \\for a in "$@"; do [ "$a" = "-p" ] && exit {d}; done
        \\echo "Created cloud session: t"; echo "claude.ai/code/session_01ABCDEFGHJKLMNOP"
        \\
    , .{send_exit});
    defer std.testing.allocator.free(script);
    try dir.writeFile(std.testing.io, .{ .sub_path = "claude.sh", .data = script, .flags = .{ .permissions = .fromMode(0o755) } });
}

fn continueFixture(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir, with_handoff: bool) !struct { root: []u8, h: Handoff } {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const root = try gpa.dupe(u8, buf[0..len]);
    const work = try std.fs.path.join(gpa, &.{ root, "work" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, work);
    const saved = try std.fs.path.join(gpa, &.{ root, "handoff.md" });
    if (with_handoff) try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = saved, .data = "# handoff" });
    return .{ .root = root, .h = .{ .work_dir = work, .saved_path = saved } };
}

test "continueFrom creates the session, sends the handoff, and removes the work dir" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeContinueClaude(tmp.dir, 0);
    const fx = try continueFixture(gpa, &tmp, true);
    defer gpa.free(fx.root);
    defer fx.h.deinit(gpa);
    const claude = try std.fs.path.join(gpa, &.{ fx.root, "claude.sh" });
    defer gpa.free(claude);
    const r = continueFrom(gpa, std.testing.io, claude, "Task", fx.h);
    defer if (r == .ok) gpa.free(r.ok);
    try std.testing.expectEqualStrings("session_01ABCDEFGHJKLMNOP", r.ok);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, fx.h.work_dir, .{}));
}

test "continueFrom reports a failed send" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeContinueClaude(tmp.dir, 1);
    const fx = try continueFixture(gpa, &tmp, true);
    defer gpa.free(fx.root);
    defer fx.h.deinit(gpa);
    const claude = try std.fs.path.join(gpa, &.{ fx.root, "claude.sh" });
    defer gpa.free(claude);
    const r = continueFrom(gpa, std.testing.io, claude, "Task", fx.h);
    try std.testing.expectEqualStrings("handoff could not be sent", r.failed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, fx.h.work_dir, .{}));
}

test "continueFrom reports a create that prints no session id" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fx = try continueFixture(gpa, &tmp, true);
    defer gpa.free(fx.root);
    defer fx.h.deinit(gpa);
    const r = continueFrom(gpa, std.testing.io, "/usr/bin/true", "Task", fx.h);
    try std.testing.expectEqualStrings("cloud session was not created", r.failed);
}

test "continueFrom reports a missing handoff file" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fx = try continueFixture(gpa, &tmp, false);
    defer gpa.free(fx.root);
    defer fx.h.deinit(gpa);
    const r = continueFrom(gpa, std.testing.io, "/usr/bin/true", "Task", fx.h);
    try std.testing.expectEqualStrings("handoff file is missing", r.failed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, fx.h.work_dir, .{}));
}
