//! sessions.zig — carry Claude Desktop's local Code sessions into another profile.
//!
//! Desktop keeps one JSON record per local Code session under
//! `<desktop dir>/claude-code-sessions/<accountUuid>/<organizationUuid>/local_*.json`
//! and reads them at launch. Each record names a CLI session whose history is
//! `<code dir>/projects/<slug>/<cliSessionId>.jsonl` plus a same-named directory.
//! Carrying a session copies both into the target profile and archives the
//! original, so the same task is not continued in two places.

const std = @import("std");
const exec = @import("exec.zig");
const json = @import("json.zig");

/// One side of a carry-over: a profile's Desktop data and Code config.
pub const Side = struct {
    /// e.g. `~/Library/Application Support/Claude` or `…/Claude.<profile>`.
    desktop_dir: []const u8,
    /// `<accountUuid>/<organizationUuid>` for this profile's account.
    account_rel: []const u8,
    /// e.g. `~/.claude.<profile>`.
    code_dir: []const u8,
};

pub const Failure = struct {
    title: []const u8,
    reason: []const u8,
};

pub const Result = struct {
    carried: usize = 0,
    failed: std.ArrayList(Failure) = .empty,

    pub fn deinit(r: *Result, gpa: std.mem.Allocator) void {
        for (r.failed.items) |f| gpa.free(f.title);
        r.failed.deinit(gpa);
    }
};

/// The project folder name Claude Code derives from a working directory.
pub fn slug(gpa: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, cwd);
    for (out) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*)) ch.* = '-';
    }
    return out;
}

/// `<accountUuid>/<organizationUuid>` from a profile's `.claude.<profile>.json`.
pub fn accountRel(gpa: std.mem.Allocator, io: std.Io, profile_json_path: []const u8) ![]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, profile_json_path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.NoAccount;
    const acct = parsed.value.object.get("oauthAccount") orelse return error.NoAccount;
    if (acct != .object) return error.NoAccount;
    const a = acct.object.get("accountUuid") orelse return error.NoAccount;
    const o = acct.object.get("organizationUuid") orelse return error.NoAccount;
    if (a != .string or o != .string) return error.NoAccount;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ a.string, o.string });
}

fn recordsDir(gpa: std.mem.Allocator, side: Side) ![]u8 {
    return std.fs.path.join(gpa, &.{ side.desktop_dir, "claude-code-sessions", side.account_rel });
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn copyTree(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) !void {
    const r = try exec.run(gpa, io, .{ .argv = &.{ "/bin/cp", "-Rp", src, dst } });
    defer r.deinit(gpa);
    if (!r.ok()) return error.CopyFailed;
}

/// Carries every unarchived session record from `src` into `dst`. Sessions whose
/// CLI id appears in `busy_ids` (a process still running it) are left in place
/// and reported as failed.
pub fn carryIn(gpa: std.mem.Allocator, io: std.Io, src: Side, dst: Side, busy_ids: []const []const u8) !Result {
    var result: Result = .{};
    errdefer result.deinit(gpa);

    const src_records = try recordsDir(gpa, src);
    defer gpa.free(src_records);
    const dst_records = try recordsDir(gpa, dst);
    defer gpa.free(dst_records);

    var dir = std.Io.Dir.cwd().openDir(io, src_records, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "local_") or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }

    try std.Io.Dir.cwd().createDirPath(io, dst_records);

    for (names.items) |name| {
        const src_path = try std.fs.path.join(gpa, &.{ src_records, name });
        defer gpa.free(src_path);
        const data = try std.Io.Dir.cwd().readFileAlloc(io, src_path, gpa, .limited(64 * 1024 * 1024));
        defer gpa.free(data);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var record = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch continue;
        if (record != .object) continue;
        if (record.object.get("isArchived")) |a| {
            if (a == .bool and a.bool) continue;
        }

        const title = json.stringField(record, "title") orelse name;
        const cli_id = json.stringField(record, "cliSessionId");
        const cwd = json.stringField(record, "cwd");
        if (cli_id == null or cwd == null) {
            try result.failed.append(gpa, .{ .title = try gpa.dupe(u8, title), .reason = "record has no history reference" });
            continue;
        }

        var busy = false;
        for (busy_ids) |b| {
            if (std.mem.eql(u8, b, cli_id.?)) busy = true;
        }
        if (busy) {
            try result.failed.append(gpa, .{ .title = try gpa.dupe(u8, title), .reason = "session process was still running" });
            continue;
        }

        const project = try slug(gpa, cwd.?);
        defer gpa.free(project);
        const history_name = try std.fmt.allocPrint(gpa, "{s}.jsonl", .{cli_id.?});
        defer gpa.free(history_name);
        const src_project = try std.fs.path.join(gpa, &.{ src.code_dir, "projects", project });
        defer gpa.free(src_project);
        const dst_project = try std.fs.path.join(gpa, &.{ dst.code_dir, "projects", project });
        defer gpa.free(dst_project);
        const src_history = try std.fs.path.join(gpa, &.{ src_project, history_name });
        defer gpa.free(src_history);
        if (!exists(io, src_history)) {
            try result.failed.append(gpa, .{ .title = try gpa.dupe(u8, title), .reason = "history file is missing" });
            continue;
        }

        try std.Io.Dir.cwd().createDirPath(io, dst_project);
        const dst_history = try std.fs.path.join(gpa, &.{ dst_project, history_name });
        defer gpa.free(dst_history);
        copyTree(gpa, io, src_history, dst_history) catch {
            try result.failed.append(gpa, .{ .title = try gpa.dupe(u8, title), .reason = "history could not be copied" });
            continue;
        };
        const src_extra = try std.fs.path.join(gpa, &.{ src_project, cli_id.? });
        defer gpa.free(src_extra);
        const dst_extra = try std.fs.path.join(gpa, &.{ dst_project, cli_id.? });
        defer gpa.free(dst_extra);
        if (exists(io, src_extra)) {
            exec.removeTree(gpa, io, dst_extra);
            copyTree(gpa, io, src_extra, dst_extra) catch {
                try result.failed.append(gpa, .{ .title = try gpa.dupe(u8, title), .reason = "history could not be copied" });
                continue;
            };
        }

        const dst_path = try std.fs.path.join(gpa, &.{ dst_records, name });
        defer gpa.free(dst_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst_path, .data = data });

        try record.object.put(arena, "isArchived", .{ .bool = true });
        const archived = try std.json.Stringify.valueAlloc(gpa, record, .{});
        defer gpa.free(archived);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src_path, .data = archived });
        result.carried += 1;
    }
    return result;
}

/// CLI session ids of Desktop-spawned session processes still running from
/// `desktop_dir`'s bundled Claude Code. Caller owns the list and each id.
pub fn liveSessionIds(gpa: std.mem.Allocator, io: std.Io, desktop_dir: []const u8) !std.ArrayList([]u8) {
    const r = try exec.run(gpa, io, .{ .argv = &.{ "/bin/ps", "-axo", "command=" }, .timeout_s = 10 });
    defer r.deinit(gpa);
    return parseLiveSessionIds(gpa, r.stdout, desktop_dir);
}

pub fn parseLiveSessionIds(gpa: std.mem.Allocator, ps_output: []const u8, desktop_dir: []const u8) !std.ArrayList([]u8) {
    var ids: std.ArrayList([]u8) = .empty;
    errdefer {
        for (ids.items) |id| gpa.free(id);
        ids.deinit(gpa);
    }
    const marker = try std.fs.path.join(gpa, &.{ desktop_dir, "claude-code" });
    defer gpa.free(marker);
    var lines = std.mem.splitScalar(u8, ps_output, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), marker)) continue;
        const key = "--resume=";
        const at = std.mem.indexOf(u8, line, key) orelse continue;
        const rest = line[at + key.len ..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        if (end == 0) continue;
        try ids.append(gpa, try gpa.dupe(u8, rest[0..end]));
    }
    return ids;
}

pub fn freeIds(gpa: std.mem.Allocator, ids: *std.ArrayList([]u8)) void {
    for (ids.items) |id| gpa.free(id);
    ids.deinit(gpa);
}

/// Waits up to `wait_s` for Desktop's session processes to exit, then sends
/// SIGTERM and waits briefly. Returns the ids still running afterwards.
pub fn settleSessionProcesses(gpa: std.mem.Allocator, io: std.Io, desktop_dir: []const u8, wait_s: u32) !std.ArrayList([]u8) {
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        var ids = try liveSessionIds(gpa, io, desktop_dir);
        if (ids.items.len == 0 or waited >= wait_s) {
            if (ids.items.len == 0) return ids;
            freeIds(gpa, &ids);
            break;
        }
        freeIds(gpa, &ids);
        std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch {};
    }
    const pattern = try std.fs.path.join(gpa, &.{ desktop_dir, "claude-code/" });
    defer gpa.free(pattern);
    const r = exec.run(gpa, io, .{ .argv = &.{ "/usr/bin/pkill", "-TERM", "-f", pattern }, .timeout_s = 10 }) catch null;
    if (r) |res| res.deinit(gpa);
    std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .awake) catch {};
    return liveSessionIds(gpa, io, desktop_dir);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(std.testing.io, &buf);
        return .{ .tmp = tmp, .base = try std.testing.allocator.dupe(u8, buf[0..len]) };
    }

    fn deinit(f: *Fixture) void {
        std.testing.allocator.free(f.base);
        f.tmp.cleanup();
    }

    fn path(f: Fixture, parts: []const []const u8) ![]u8 {
        var all: std.ArrayList([]const u8) = .empty;
        defer all.deinit(std.testing.allocator);
        try all.append(std.testing.allocator, f.base);
        try all.appendSlice(std.testing.allocator, parts);
        return std.fs.path.join(std.testing.allocator, all.items);
    }

    fn write(f: Fixture, parts: []const []const u8, data: []const u8) !void {
        const p = try f.path(parts);
        defer std.testing.allocator.free(p);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(p).?);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p, .data = data });
    }

    fn read(f: Fixture, parts: []const []const u8) ![]u8 {
        const p = try f.path(parts);
        defer std.testing.allocator.free(p);
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, std.testing.allocator, .limited(1 << 20));
    }

    fn has(f: Fixture, parts: []const []const u8) bool {
        const p = f.path(parts) catch return false;
        defer std.testing.allocator.free(p);
        return exists(std.testing.io, p);
    }

    fn sides(f: Fixture, gpa: std.mem.Allocator) ![4][]u8 {
        return .{
            try std.fs.path.join(gpa, &.{ f.base, "Claude" }),
            try std.fs.path.join(gpa, &.{ f.base, ".claude.a" }),
            try std.fs.path.join(gpa, &.{ f.base, "Claude.b" }),
            try std.fs.path.join(gpa, &.{ f.base, ".claude.b" }),
        };
    }
};

fn recordJson(gpa: std.mem.Allocator, id: []const u8, cli: []const u8, cwd: []const u8, archived: bool) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"sessionId\":\"{s}\",\"cliSessionId\":\"{s}\",\"cwd\":\"{s}\",\"title\":\"T {s}\",\"isArchived\":{},\"model\":\"m\"}}", .{ id, cli, cwd, id, archived });
}

test "slug replaces every non-alphanumeric character" {
    const gpa = std.testing.allocator;
    const s = try slug(gpa, "/Users/a/projects/x.y");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("-Users-a-projects-x-y", s);
}

test "carryIn copies open sessions with history and archives the originals" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.sides(gpa);
    defer for (s) |p| gpa.free(p);
    const src: Side = .{ .desktop_dir = s[0], .account_rel = "accA/orgA", .code_dir = s[1] };
    const dst: Side = .{ .desktop_dir = s[2], .account_rel = "accB/orgB", .code_dir = s[3] };

    const r1 = try recordJson(gpa, "local_1", "cli-1", "/w/p1", false);
    defer gpa.free(r1);
    const r2 = try recordJson(gpa, "local_2", "cli-2", "/w/p2", false);
    defer gpa.free(r2);
    const r3 = try recordJson(gpa, "local_3", "cli-3", "/w/p3", true);
    defer gpa.free(r3);
    try f.write(&.{ "Claude", "claude-code-sessions", "accA", "orgA", "local_1.json" }, r1);
    try f.write(&.{ "Claude", "claude-code-sessions", "accA", "orgA", "local_2.json" }, r2);
    try f.write(&.{ "Claude", "claude-code-sessions", "accA", "orgA", "local_3.json" }, r3);
    try f.write(&.{ ".claude.a", "projects", "-w-p1", "cli-1.jsonl" }, "h1");
    try f.write(&.{ ".claude.a", "projects", "-w-p1", "cli-1", "subagents", "x.jsonl" }, "sub");
    try f.write(&.{ ".claude.a", "projects", "-w-p2", "cli-2.jsonl" }, "h2");
    try f.write(&.{ ".claude.a", "projects", "-w-p3", "cli-3.jsonl" }, "h3");

    var res = try carryIn(gpa, std.testing.io, src, dst, &.{});
    defer res.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), res.carried);
    try std.testing.expectEqual(@as(usize, 0), res.failed.items.len);

    const copied = try f.read(&.{ "Claude.b", "claude-code-sessions", "accB", "orgB", "local_1.json" });
    defer gpa.free(copied);
    try std.testing.expectEqualStrings(r1, copied);
    try std.testing.expect(f.has(&.{ ".claude.b", "projects", "-w-p1", "cli-1.jsonl" }));
    try std.testing.expect(f.has(&.{ ".claude.b", "projects", "-w-p1", "cli-1", "subagents", "x.jsonl" }));
    try std.testing.expect(!f.has(&.{ "Claude.b", "claude-code-sessions", "accB", "orgB", "local_3.json" }));

    const archived = try f.read(&.{ "Claude", "claude-code-sessions", "accA", "orgA", "local_1.json" });
    defer gpa.free(archived);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, archived, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("isArchived").?.bool);
    try std.testing.expectEqualStrings("m", parsed.value.object.get("model").?.string);
    try std.testing.expectEqualStrings("cli-1", parsed.value.object.get("cliSessionId").?.string);
}

test "carryIn replaces an older copy in the target (AE4)" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.sides(gpa);
    defer for (s) |p| gpa.free(p);
    const src: Side = .{ .desktop_dir = s[0], .account_rel = "accA/orgA", .code_dir = s[1] };
    const dst: Side = .{ .desktop_dir = s[2], .account_rel = "accB/orgB", .code_dir = s[3] };

    const fresh = try recordJson(gpa, "local_X", "cli-x", "/w/p", false);
    defer gpa.free(fresh);
    try f.write(&.{ "Claude", "claude-code-sessions", "accA", "orgA", "local_X.json" }, fresh);
    try f.write(&.{ ".claude.a", "projects", "-w-p", "cli-x.jsonl" }, "newer history");
    try f.write(&.{ "Claude.b", "claude-code-sessions", "accB", "orgB", "local_X.json" }, "{\"sessionId\":\"local_X\",\"isArchived\":true}");
    try f.write(&.{ ".claude.b", "projects", "-w-p", "cli-x.jsonl" }, "older history");

    var res = try carryIn(gpa, std.testing.io, src, dst, &.{});
    defer res.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), res.carried);
    const rec = try f.read(&.{ "Claude.b", "claude-code-sessions", "accB", "orgB", "local_X.json" });
    defer gpa.free(rec);
    try std.testing.expectEqualStrings(fresh, rec);
    const hist = try f.read(&.{ ".claude.b", "projects", "-w-p", "cli-x.jsonl" });
    defer gpa.free(hist);
    try std.testing.expectEqualStrings("newer history", hist);
}

test "carryIn leaves sessions with missing history or a live process in place" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.sides(gpa);
    defer for (s) |p| gpa.free(p);
    const src: Side = .{ .desktop_dir = s[0], .account_rel = "accA/orgA", .code_dir = s[1] };
    const dst: Side = .{ .desktop_dir = s[2], .account_rel = "accB/orgB", .code_dir = s[3] };

    const missing = try recordJson(gpa, "local_m", "cli-m", "/w/m", false);
    defer gpa.free(missing);
    const busy = try recordJson(gpa, "local_b", "cli-b", "/w/b", false);
    defer gpa.free(busy);
    const ok = try recordJson(gpa, "local_o", "cli-o", "/w/o", false);
    defer gpa.free(ok);
    try f.write(&.{ "Claude", "claude-code-sessions", "accA", "orgA", "local_m.json" }, missing);
    try f.write(&.{ "Claude", "claude-code-sessions", "accA", "orgA", "local_b.json" }, busy);
    try f.write(&.{ "Claude", "claude-code-sessions", "accA", "orgA", "local_o.json" }, ok);
    try f.write(&.{ ".claude.a", "projects", "-w-b", "cli-b.jsonl" }, "b");
    try f.write(&.{ ".claude.a", "projects", "-w-o", "cli-o.jsonl" }, "o");

    var res = try carryIn(gpa, std.testing.io, src, dst, &.{"cli-b"});
    defer res.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), res.carried);
    try std.testing.expectEqual(@as(usize, 2), res.failed.items.len);
    const still_open = try f.read(&.{ "Claude", "claude-code-sessions", "accA", "orgA", "local_b.json" });
    defer gpa.free(still_open);
    try std.testing.expectEqualStrings(busy, still_open);
    try std.testing.expect(!f.has(&.{ "Claude.b", "claude-code-sessions", "accB", "orgB", "local_m.json" }));
}

test "carryIn with no records folder carries nothing" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.sides(gpa);
    defer for (s) |p| gpa.free(p);
    var res = try carryIn(gpa, std.testing.io, .{ .desktop_dir = s[0], .account_rel = "a/o", .code_dir = s[1] }, .{ .desktop_dir = s[2], .account_rel = "b/o", .code_dir = s[3] }, &.{});
    defer res.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), res.carried);
}

test "parseLiveSessionIds keeps only this Desktop's session processes" {
    const gpa = std.testing.allocator;
    const ps =
        \\/Applications/Claude.app/Contents/MacOS/Claude
        \\/D/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude --output-format stream-json --resume=abc-1 --allowedTools x
        \\/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- /D/Claude/claude-code/2.1/claude --resume=abc-1
        \\/Users/me/.local/bin/claude --resume=other
        \\/D/Claude.b/claude-code/2.1/claude --resume=zzz
    ;
    var ids = try parseLiveSessionIds(gpa, ps, "/D/Claude");
    defer freeIds(gpa, &ids);
    try std.testing.expectEqual(@as(usize, 1), ids.items.len);
    try std.testing.expectEqualStrings("abc-1", ids.items[0]);
}

test "accountRel reads account and organization ids" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(&.{".claude.x.json"}, "{\"oauthAccount\":{\"accountUuid\":\"acc\",\"organizationUuid\":\"org\"}}");
    const p = try f.path(&.{".claude.x.json"});
    defer gpa.free(p);
    const rel = try accountRel(gpa, std.testing.io, p);
    defer gpa.free(rel);
    try std.testing.expectEqualStrings("acc/org", rel);
}
