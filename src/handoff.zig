//! handoff.zig — `csw handoff`: move the day's work to the next account.
//!
//! Order matters. Cloud handoffs need the outgoing account's login, so they run
//! before the switch; continuations need the next account's, so they run after.
//! Local sessions are carried inside the switch itself (profile.useWith).

const std = @import("std");
const cloud = @import("cloud.zig");
const display = @import("display.zig");
const exec = @import("exec.zig");
const oauth = @import("oauth.zig");
const paths = @import("paths.zig");
const profile = @import("profile.zig");
const sessions = @import("sessions.zig");
const usage = @import("usage.zig");

pub const Options = struct {
    dry_run: bool = false,
    /// Ignore the usage threshold (manual run).
    force: bool = false,
    /// Started by the launchd schedule; only acts inside the night window.
    scheduled: bool = false,
};

/// The scheduled run acts only from 22:00 until 06:00 local time (KTD10).
pub fn inNightWindow(hour: u8) bool {
    return hour >= 22 or hour < 6;
}

/// Everything the routine does to the outside world, so tests can use fakes.
pub const Effects = struct {
    ctx: *anyopaque,
    collectUsage: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]usage.ProfileUsage,
    listCloud: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, io: std.Io, active: []const u8) anyerror![]cloud.Session,
    handOff: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, s: cloud.Session, out_dir: []const u8) cloud.HandOffResult,
    switchTo: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!profile.UseResult,
    continueFrom: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, title: []const u8, h: cloud.Handoff) cloud.ContinueResult,
    notify: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, title: []const u8, message: []const u8) void,
    writeReport: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, out_dir: []const u8, text: []const u8) void,
    nowS: *const fn (ctx: *anyopaque) i64,
    localHour: *const fn (ctx: *anyopaque, epoch_s: i64) u8,
};

pub const Outcome = enum {
    missed_window,
    active_unknown,
    below_threshold,
    no_capacity,
    dry_run,
    window_closed,
    switched,
    switch_failed,
};

const Report = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    fn line(r: *Report, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(r.gpa, fmt ++ "\n", args) catch return;
        defer r.gpa.free(s);
        r.buf.appendSlice(r.gpa, s) catch {};
    }

    fn deinit(r: *Report) void {
        r.buf.deinit(r.gpa);
    }
};

const Pending = struct { session: cloud.Session, handoff: cloud.Handoff };

fn notifyUnlessDry(fx: Effects, gpa: std.mem.Allocator, io: std.Io, opts: Options, title: []const u8, message: []const u8) void {
    if (opts.dry_run) return;
    fx.notify(fx.ctx, gpa, io, title, message);
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, fx: Effects, opts: Options, out_dir: []const u8) !Outcome {
    var report: Report = .{ .gpa = gpa };
    defer report.deinit();
    const outcome = runInner(gpa, io, fx, opts, out_dir, &report) catch |err| {
        report.line("The handoff stopped on an error: {s}. Nothing after that point ran.", .{@errorName(err)});
        if (!@import("builtin").is_test) display.print("{s}", .{report.buf.items});
        if (!opts.dry_run) {
            fx.writeReport(fx.ctx, gpa, io, out_dir, report.buf.items);
            fx.notify(fx.ctx, gpa, io, "csw: handoff failed", @errorName(err));
        }
        return err;
    };
    // The test runner owns stdout, so the report is only printed outside tests.
    if (!@import("builtin").is_test) display.print("{s}", .{report.buf.items});
    if (!opts.dry_run and outcome != .below_threshold) fx.writeReport(fx.ctx, gpa, io, out_dir, report.buf.items);
    return outcome;
}

fn runInner(gpa: std.mem.Allocator, io: std.Io, fx: Effects, opts: Options, out_dir: []const u8, report: *Report) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    report.line("# csw nightly handoff", .{});
    if (opts.dry_run) report.line("Dry run: nothing will be switched, carried, or handed off.", .{});

    if (opts.scheduled and !inNightWindow(fx.localHour(fx.ctx, fx.nowS(fx.ctx)))) {
        report.line("The scheduled run started outside 22:00–06:00, so nothing was switched. Run `csw handoff` by hand if needed.", .{});
        notifyUnlessDry(fx, gpa, io, opts, "csw: nightly handoff missed", "The Mac was asleep at 22:00. Nothing was switched; run csw handoff by hand if needed.");
        return .missed_window;
    }

    const rows = try fx.collectUsage(fx.ctx, gpa, io);
    defer usage.freeRows(gpa, rows);

    var active_name: ?[]const u8 = null;
    for (rows) |r| if (r.active) {
        active_name = r.name;
    };
    const weekly = usage.activeWeekly(rows) orelse {
        report.line("The active profile's weekly usage could not be read, so nothing was switched.", .{});
        notifyUnlessDry(fx, gpa, io, opts, "csw: handoff skipped", "Active profile usage could not be read. Nothing was switched.");
        return .active_unknown;
    };
    report.line("Active profile: {s}, weekly usage {d:.0}%.", .{ active_name.?, weekly.pct });
    if (weekly.pct < usage.THRESHOLD_PCT and !opts.force) {
        report.line("Below {d:.0}%: nothing to do tonight.", .{usage.THRESHOLD_PCT});
        return .below_threshold;
    }

    var choice = try usage.chooseNext(gpa, rows);
    defer choice.deinit(gpa);
    for (choice.excluded.items) |e| report.line("- Not {s}: {s}", .{ e.name, e.reason() });
    const next_i: ?usize = choice.next;
    if (next_i == null and opts.dry_run) report.line("No profile has capacity, so a real run would not switch.", .{});
    if (next_i == null and !opts.dry_run) {
        report.line("No profile has capacity, so nothing was switched.", .{});
        var sign_in: ?[]const u8 = null;
        for (choice.excluded.items) |e| if (e.kind == .needs_sign_in) {
            sign_in = e.name;
        };
        const msg = if (sign_in) |n|
            try std.fmt.allocPrint(gpa, "No profile has capacity. {s} needs signing in again.", .{n})
        else
            try gpa.dupe(u8, "No profile has capacity. Nothing was switched.");
        defer gpa.free(msg);
        notifyUnlessDry(fx, gpa, io, opts, "csw: handoff skipped", msg);
        return .no_capacity;
    }
    const next_name: []const u8 = if (next_i) |i| rows[i].name else "(none)";
    if (next_i != null) report.line("Next profile: {s}.", .{next_name});

    const all_cloud = fx.listCloud(fx.ctx, arena, io, active_name.?) catch |err| blk: {
        report.line("Cloud sessions could not be listed ({s}); none will be handed off.", .{@errorName(err)});
        break :blk &[_]cloud.Session{};
    };
    const now = fx.nowS(fx.ctx);
    var picked: std.ArrayList(cloud.Session) = .empty;
    for (all_cloud) |s| if (cloud.shouldHandOff(s, now)) try picked.append(arena, s);
    report.line("Cloud sessions to hand off: {d}.", .{picked.items.len});
    for (picked.items) |s| report.line("- {s} ({s})", .{ s.title, s.status });

    if (opts.dry_run) {
        if (next_i != null) report.line("Every open local Code session would be carried into {s}.", .{next_name});
        return .dry_run;
    }

    var pending: std.ArrayList(Pending) = .empty;
    defer {
        for (pending.items) |p| p.handoff.deinit(gpa);
        pending.deinit(gpa);
    }
    var failed: usize = 0;
    for (picked.items) |s| switch (fx.handOff(fx.ctx, gpa, io, s, out_dir)) {
        .ok => |h| try pending.append(gpa, .{ .session = s, .handoff = h }),
        .failed => |why| {
            failed += 1;
            report.line("- Handoff failed for {s}: {s}. It stays on {s}.", .{ s.title, why, active_name.? });
        },
    };

    if (opts.scheduled and !inNightWindow(fx.localHour(fx.ctx, fx.nowS(fx.ctx)))) {
        report.line("The night window closed before the switch, so nothing was switched. Handoffs are saved in {s}.", .{out_dir});
        notifyUnlessDry(fx, gpa, io, opts, "csw: handoff not finished", "Handoffs ran past 06:00, so the account was not switched.");
        for (pending.items) |p| exec.removeTree(gpa, io, p.handoff.work_dir);
        return .window_closed;
    }

    var use_result = fx.switchTo(fx.ctx, gpa, io, next_name) catch |err| {
        report.line("The switch to {s} failed ({s}), so the account was not switched. Handoffs are saved in {s}.", .{ next_name, @errorName(err), out_dir });
        for (pending.items) |p| exec.removeTree(gpa, io, p.handoff.work_dir);
        const msg = try std.fmt.allocPrint(gpa, "The switch to {s} failed ({s}). Still on {s}.", .{ next_name, @errorName(err), active_name.? });
        defer gpa.free(msg);
        notifyUnlessDry(fx, gpa, io, opts, "csw: switch failed", msg);
        return .switch_failed;
    };
    defer use_result.deinit(gpa);
    var carried: usize = 0;
    if (use_result.carry) |c| {
        carried = c.carried;
        for (c.failed.items) |f| {
            failed += 1;
            report.line("- Not carried: {s} ({s}). It stays on {s}.", .{ f.title, f.reason, active_name.? });
        }
    } else if (use_result.carry_skipped) |why| {
        report.line("Local sessions were not carried: {s}.", .{why});
    }
    report.line("Switched to {s}. Carried {d} local session(s).", .{ next_name, carried });

    var continued: usize = 0;
    for (pending.items) |p| switch (fx.continueFrom(fx.ctx, gpa, io, p.session.title, p.handoff)) {
        .ok => |id| {
            defer gpa.free(id);
            continued += 1;
            report.line("- Continued {s} as {s}.", .{ p.session.title, id });
        },
        .failed => |why| {
            failed += 1;
            report.line("- Could not continue {s}: {s}. Its handoff is at {s}.", .{ p.session.title, why, p.handoff.saved_path });
        },
    };

    const msg = try std.fmt.allocPrint(gpa, "Now on {s}: {d} local session(s) carried, {d} cloud session(s) continued, {d} problem(s). Sign the Claude mobile app in to {s}.", .{ next_name, carried, continued, failed, next_name });
    defer gpa.free(msg);
    report.line("{s}", .{msg});
    notifyUnlessDry(fx, gpa, io, opts, "csw: switched accounts", msg);
    return .switched;
}

// ── Real effects ──────────────────────────────────────────────────────────────

const c_time = @cImport(@cInclude("time.h"));

fn realNow(_: *anyopaque) i64 {
    return @intCast(c_time.time(null));
}

fn realHour(_: *anyopaque, epoch_s: i64) u8 {
    var t: c_time.time_t = @intCast(epoch_s);
    var tm: c_time.struct_tm = undefined;
    _ = c_time.localtime_r(&t, &tm);
    return @intCast(tm.tm_hour);
}

fn realCollect(_: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]usage.ProfileUsage {
    return usage.collect(gpa, io);
}

fn activeOrg(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    const p = try paths.claudeJsonIn(gpa, h);
    defer gpa.free(p);
    const rel = try sessions.accountRel(gpa, io, p);
    defer gpa.free(rel);
    const slash = std.mem.indexOfScalar(u8, rel, '/') orelse return error.NoAccount;
    return gpa.dupe(u8, rel[slash + 1 ..]);
}

fn realListCloud(_: *anyopaque, arena: std.mem.Allocator, io: std.Io, active: []const u8) anyerror![]cloud.Session {
    const login = try oauth.freshAccessToken(arena, io, active, true);
    const token = switch (login) {
        .token => |t| t,
        else => return error.NoActiveLogin,
    };
    const org = try activeOrg(arena, io);
    return cloud.list(arena, io, token, org);
}

fn tmpRoot(gpa: std.mem.Allocator) ![]u8 {
    const t = std.c.getenv("TMPDIR");
    const base = if (t) |p| std.mem.sliceTo(p, 0) else "/tmp";
    return std.fs.path.join(gpa, &.{ base, "csw-handoff" });
}

fn realHandOff(_: *anyopaque, gpa: std.mem.Allocator, io: std.Io, s: cloud.Session, out_dir: []const u8) cloud.HandOffResult {
    const root = tmpRoot(gpa) catch return .{ .failed = "out of memory" };
    defer gpa.free(root);
    std.Io.Dir.cwd().createDirPath(io, root) catch return .{ .failed = "temporary directory could not be created" };
    return cloud.handOff(gpa, io, "claude", s, root, out_dir);
}

fn realSwitch(_: *anyopaque, gpa: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!profile.UseResult {
    return profile.useWith(gpa, io, name, .{ .carry_sessions = true });
}

fn realContinue(_: *anyopaque, gpa: std.mem.Allocator, io: std.Io, title: []const u8, h: cloud.Handoff) cloud.ContinueResult {
    return cloud.continueFrom(gpa, io, "claude", title, h);
}

/// Message and title go to osascript as arguments, never into the script text.
pub fn notifyArgv(title: []const u8, message: []const u8) [9][]const u8 {
    return .{ "/usr/bin/osascript", "-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)", "-e", "end run", message, title };
}

fn realNotify(_: *anyopaque, gpa: std.mem.Allocator, io: std.Io, title: []const u8, message: []const u8) void {
    const argv = notifyArgv(title, message);
    const r = exec.run(gpa, io, .{ .argv = &argv, .timeout_s = 15 }) catch return;
    r.deinit(gpa);
}

fn realWriteReport(_: *anyopaque, gpa: std.mem.Allocator, io: std.Io, out_dir: []const u8, text: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, out_dir) catch return;
    const p = std.fs.path.join(gpa, &.{ out_dir, "report.md" }) catch return;
    defer gpa.free(p);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text }) catch {};
}

var real_ctx: u8 = 0;

pub fn realEffects() Effects {
    return .{
        .ctx = &real_ctx,
        .collectUsage = realCollect,
        .listCloud = realListCloud,
        .handOff = realHandOff,
        .switchTo = realSwitch,
        .continueFrom = realContinue,
        .notify = realNotify,
        .writeReport = realWriteReport,
        .nowS = realNow,
        .localHour = realHour,
    };
}

/// `~/Library/Application Support/csw/handoffs/<YYYY-MM-DD>`.
pub fn outDirFor(gpa: std.mem.Allocator, epoch_s: i64) ![]u8 {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    var t: c_time.time_t = @intCast(epoch_s);
    var tm: c_time.struct_tm = undefined;
    _ = c_time.localtime_r(&t, &tm);
    var buf: [16]u8 = undefined;
    const n = c_time.strftime(&buf, buf.len, "%Y-%m-%d", &tm);
    return std.fs.path.join(gpa, &.{ h, "Library", "Application Support", "csw", "handoffs", buf[0..n] });
}

pub fn cmdHandoff(gpa: std.mem.Allocator, io: std.Io, opts: Options) !void {
    const out_dir = try outDirFor(gpa, realNow(&real_ctx));
    defer gpa.free(out_dir);
    _ = try run(gpa, io, realEffects(), opts, out_dir);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const Fake = struct {
    gpa: std.mem.Allocator,
    active_pct: ?f64 = 92,
    next_state: usage.State = .{ .usage = .{ .seven_day = .{ .pct = 0, .resets_at = 500 } } },
    hour_seq: []const u8 = &.{ 22, 22, 22 },
    hour_i: usize = 0,
    fail_handoff: ?[]const u8 = null,
    fail_switch: bool = false,
    calls: std.ArrayList([]const u8) = .empty,
    notes: std.ArrayList([]u8) = .empty,

    fn log(f: *Fake, what: []const u8) void {
        f.calls.append(f.gpa, what) catch {};
    }

    fn deinit(f: *Fake) void {
        f.calls.deinit(f.gpa);
        for (f.notes.items) |n| f.gpa.free(n);
        f.notes.deinit(f.gpa);
    }

    fn self(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }

    fn collect(ctx: *anyopaque, gpa: std.mem.Allocator, _: std.Io) anyerror![]usage.ProfileUsage {
        const f = self(ctx);
        f.log("usage");
        const rows = try gpa.alloc(usage.ProfileUsage, 2);
        rows[0] = .{ .name = try gpa.dupe(u8, "primary"), .active = true, .state = if (f.active_pct) |p| .{ .usage = .{ .seven_day = .{ .pct = p, .resets_at = 100 } } } else .failed };
        rows[1] = .{ .name = try gpa.dupe(u8, "overflow1"), .active = false, .state = f.next_state };
        return rows;
    }

    fn listCloud(ctx: *anyopaque, arena: std.mem.Allocator, _: std.Io, _: []const u8) anyerror![]cloud.Session {
        self(ctx).log("list-cloud");
        const out = try arena.alloc(cloud.Session, 2);
        out[0] = .{ .id = "session_a", .title = "A", .status = "running", .env_kind = "anthropic_cloud", .created_at = 0, .repo_url = null, .branch = null };
        out[1] = .{ .id = "session_old", .title = "Old", .status = "idle", .env_kind = "anthropic_cloud", .created_at = 0, .repo_url = null, .branch = null };
        return out;
    }

    fn handOff(ctx: *anyopaque, gpa: std.mem.Allocator, _: std.Io, s: cloud.Session, _: []const u8) cloud.HandOffResult {
        const f = self(ctx);
        f.log("handoff");
        if (f.fail_handoff) |why| return .{ .failed = why };
        return .{ .ok = .{ .work_dir = gpa.dupe(u8, "/tmp/w") catch unreachable, .saved_path = std.fmt.allocPrint(gpa, "/h/{s}.md", .{s.id}) catch unreachable } };
    }

    fn switchTo(ctx: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8) anyerror!profile.UseResult {
        const f = self(ctx);
        f.log("switch");
        if (f.fail_switch) return error.KeychainWriteFailed;
        return .{ .carry = .{ .carried = 3 } };
    }

    fn continueFrom(ctx: *anyopaque, gpa: std.mem.Allocator, _: std.Io, _: []const u8, _: cloud.Handoff) cloud.ContinueResult {
        self(ctx).log("continue");
        return .{ .ok = gpa.dupe(u8, "session_new") catch unreachable };
    }

    fn notify(ctx: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8, message: []const u8) void {
        const f = self(ctx);
        f.log("notify");
        f.notes.append(f.gpa, f.gpa.dupe(u8, message) catch return) catch {};
    }

    fn writeReport(ctx: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8, _: []const u8) void {
        self(ctx).log("report");
    }

    /// Ten days after the fixture sessions were created, so only the running one qualifies.
    fn now(_: *anyopaque) i64 {
        return 10 * 24 * 60 * 60;
    }

    fn hour(ctx: *anyopaque, _: i64) u8 {
        const f = self(ctx);
        const h = f.hour_seq[@min(f.hour_i, f.hour_seq.len - 1)];
        f.hour_i += 1;
        return h;
    }

    fn effects(f: *Fake) Effects {
        return .{ .ctx = f, .collectUsage = collect, .listCloud = listCloud, .handOff = handOff, .switchTo = switchTo, .continueFrom = continueFrom, .notify = notify, .writeReport = writeReport, .nowS = now, .localHour = hour };
    }

    fn expectCalls(f: *Fake, want: []const []const u8) !void {
        try std.testing.expectEqual(want.len, f.calls.items.len);
        for (want, f.calls.items) |w, got| try std.testing.expectEqualStrings(w, got);
    }
};

test "below threshold: nothing is switched (AE1)" {
    var f: Fake = .{ .gpa = std.testing.allocator, .active_pct = 77 };
    defer f.deinit();
    try std.testing.expectEqual(Outcome.below_threshold, try run(std.testing.allocator, std.testing.io, f.effects(), .{ .scheduled = true }, "/out"));
    try f.expectCalls(&.{"usage"});
}

test "above threshold: handoffs, then switch with carry, then continuations (AE2)" {
    var f: Fake = .{ .gpa = std.testing.allocator };
    defer f.deinit();
    try std.testing.expectEqual(Outcome.switched, try run(std.testing.allocator, std.testing.io, f.effects(), .{ .scheduled = true }, "/out"));
    try f.expectCalls(&.{ "usage", "list-cloud", "handoff", "switch", "continue", "notify", "report" });
    try std.testing.expect(std.mem.indexOf(u8, f.notes.items[0], "Sign the Claude mobile app in to overflow1") != null);
}

test "dry run lists the plan and changes nothing (AE6)" {
    var f: Fake = .{ .gpa = std.testing.allocator, .active_pct = 95 };
    defer f.deinit();
    try std.testing.expectEqual(Outcome.dry_run, try run(std.testing.allocator, std.testing.io, f.effects(), .{ .dry_run = true }, "/out"));
    try f.expectCalls(&.{ "usage", "list-cloud" });
}

test "dry run with no capacity still lists cloud sessions and never notifies" {
    var f: Fake = .{ .gpa = std.testing.allocator, .active_pct = 95, .next_state = .needs_sign_in };
    defer f.deinit();
    try std.testing.expectEqual(Outcome.dry_run, try run(std.testing.allocator, std.testing.io, f.effects(), .{ .dry_run = true }, "/out"));
    try f.expectCalls(&.{ "usage", "list-cloud" });
}

test "a failed handoff does not stop the switch (R16)" {
    var f: Fake = .{ .gpa = std.testing.allocator, .fail_handoff = "timed out" };
    defer f.deinit();
    try std.testing.expectEqual(Outcome.switched, try run(std.testing.allocator, std.testing.io, f.effects(), .{}, "/out"));
    try f.expectCalls(&.{ "usage", "list-cloud", "handoff", "switch", "notify", "report" });
    try std.testing.expect(std.mem.indexOf(u8, f.notes.items[0], "1 problem(s)") != null);
}

test "a failed switch still reports and notifies" {
    var f: Fake = .{ .gpa = std.testing.allocator, .fail_switch = true };
    defer f.deinit();
    try std.testing.expectEqual(Outcome.switch_failed, try run(std.testing.allocator, std.testing.io, f.effects(), .{}, "/out"));
    try f.expectCalls(&.{ "usage", "list-cloud", "handoff", "switch", "notify", "report" });
    try std.testing.expect(std.mem.indexOf(u8, f.notes.items[0], "Still on primary") != null);
}

test "next profile needs sign-in: no switch, notification names it (R17)" {
    var f: Fake = .{ .gpa = std.testing.allocator, .next_state = .needs_sign_in };
    defer f.deinit();
    try std.testing.expectEqual(Outcome.no_capacity, try run(std.testing.allocator, std.testing.io, f.effects(), .{}, "/out"));
    try f.expectCalls(&.{ "usage", "notify", "report" });
    try std.testing.expect(std.mem.indexOf(u8, f.notes.items[0], "overflow1 needs signing in again") != null);
}

test "scheduled run starting at 09:00 switches nothing" {
    var f: Fake = .{ .gpa = std.testing.allocator, .hour_seq = &.{9} };
    defer f.deinit();
    try std.testing.expectEqual(Outcome.missed_window, try run(std.testing.allocator, std.testing.io, f.effects(), .{ .scheduled = true }, "/out"));
    try f.expectCalls(&.{ "notify", "report" });
}

test "scheduled run whose handoffs pass 06:00 does not switch" {
    var f: Fake = .{ .gpa = std.testing.allocator, .hour_seq = &.{ 23, 6 } };
    defer f.deinit();
    try std.testing.expectEqual(Outcome.window_closed, try run(std.testing.allocator, std.testing.io, f.effects(), .{ .scheduled = true }, "/out"));
    try f.expectCalls(&.{ "usage", "list-cloud", "handoff", "notify", "report" });
}

test "unreadable active usage switches nothing" {
    var f: Fake = .{ .gpa = std.testing.allocator, .active_pct = null };
    defer f.deinit();
    try std.testing.expectEqual(Outcome.active_unknown, try run(std.testing.allocator, std.testing.io, f.effects(), .{}, "/out"));
}

test "inNightWindow covers 22:00 to 06:00" {
    try std.testing.expect(inNightWindow(22));
    try std.testing.expect(inNightWindow(3));
    try std.testing.expect(!inNightWindow(6));
    try std.testing.expect(!inNightWindow(21));
}

test "notifyArgv passes titles with quotes as separate arguments" {
    const argv = notifyArgv("csw", "Session \"A\" \\ failed");
    try std.testing.expectEqualStrings("Session \"A\" \\ failed", argv[7]);
    try std.testing.expectEqualStrings("csw", argv[8]);
    for (argv[0..7]) |a| try std.testing.expect(std.mem.indexOf(u8, a, "Session") == null);
}
