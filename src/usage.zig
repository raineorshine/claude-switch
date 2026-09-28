//! usage.zig — per-profile plan usage and the choice of the next profile.

const std = @import("std");
const display = @import("display.zig");
const http = @import("http.zig");
const oauth = @import("oauth.zig");
const profile = @import("profile.zig");

pub const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";
/// Weekly usage at or above this percentage makes a profile full.
pub const THRESHOLD_PCT: f64 = 90;

pub const Window = struct {
    pct: f64,
    /// Unix seconds.
    resets_at: i64,
};

pub const Usage = struct {
    five_hour: ?Window = null,
    seven_day: ?Window = null,
};

/// Parses an ISO 8601 timestamp such as `2026-10-01T17:00:00.148936+00:00` to Unix seconds.
pub fn parseIso8601(s: []const u8) !i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':')
        return error.InvalidTimestamp;
    const year = try std.fmt.parseInt(i64, s[0..4], 10);
    const month = try std.fmt.parseInt(u8, s[5..7], 10);
    const day = try std.fmt.parseInt(u8, s[8..10], 10);
    const hour = try std.fmt.parseInt(i64, s[11..13], 10);
    const minute = try std.fmt.parseInt(i64, s[14..16], 10);
    const second = try std.fmt.parseInt(i64, s[17..19], 10);
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidTimestamp;

    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    var offset: i64 = 0;
    if (i < s.len) {
        if (s[i] == 'Z') {
            offset = 0;
        } else if ((s[i] == '+' or s[i] == '-') and s.len >= i + 6 and s[i + 3] == ':') {
            const oh = try std.fmt.parseInt(i64, s[i + 1 .. i + 3], 10);
            const om = try std.fmt.parseInt(i64, s[i + 4 .. i + 6], 10);
            offset = (oh * 3600 + om * 60) * @as(i64, if (s[i] == '-') -1 else 1);
        } else return error.InvalidTimestamp;
    }

    // Days from civil (Howard Hinnant's algorithm).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + minute * 60 + second - offset;
}

fn parseWindow(v: ?std.json.Value) ?Window {
    const w = v orelse return null;
    if (w != .object) return null;
    const util = w.object.get("utilization") orelse return null;
    const pct: f64 = switch (util) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return null,
    };
    const resets = w.object.get("resets_at") orelse return null;
    if (resets != .string) return null;
    return .{ .pct = pct, .resets_at = parseIso8601(resets.string) catch return null };
}

pub fn parseUsage(gpa: std.mem.Allocator, body: []const u8) !Usage {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return error.MalformedUsage;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedUsage;
    return .{
        .five_hour = parseWindow(parsed.value.object.get("five_hour")),
        .seven_day = parseWindow(parsed.value.object.get("seven_day")),
    };
}

pub fn fetch(gpa: std.mem.Allocator, io: std.Io, access_token: []const u8) !Usage {
    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{access_token});
    defer {
        @memset(auth, 0);
        gpa.free(auth);
    }
    const resp = try http.send(gpa, io, .{
        .url = USAGE_URL,
        .headers = &.{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" },
        },
    });
    defer resp.deinit(gpa);
    if (resp.status != 200) return error.UsageRequestFailed;
    return parseUsage(gpa, resp.body);
}

pub const State = union(enum) {
    usage: Usage,
    needs_sign_in,
    no_login,
    failed,
};

pub const ProfileUsage = struct {
    name: []const u8,
    active: bool,
    state: State,
};

/// Reads usage for every saved profile, refreshing expired logins (KTD2).
/// Caller owns the slice and each name.
pub fn collect(gpa: std.mem.Allocator, io: std.Io) ![]ProfileUsage {
    const names = try profile.list(gpa);
    defer gpa.free(names);
    const current = try profile.current(gpa);
    defer if (current) |cur| gpa.free(cur);

    var rows: std.ArrayList(ProfileUsage) = .empty;
    errdefer {
        for (rows.items) |r| gpa.free(r.name);
        rows.deinit(gpa);
    }
    for (names) |name| {
        defer gpa.free(name);
        const active = if (current) |cur| std.mem.eql(u8, cur, name) else false;
        const state: State = blk: {
            const login = oauth.freshAccessToken(gpa, io, name, active) catch break :blk .failed;
            switch (login) {
                .token => |t| {
                    defer {
                        @memset(t, 0);
                        gpa.free(t);
                    }
                    break :blk if (fetch(gpa, io, t)) |u| .{ .usage = u } else |_| .failed;
                },
                .needs_sign_in => break :blk .needs_sign_in,
                .missing => break :blk .no_login,
            }
        };
        try rows.append(gpa, .{ .name = try gpa.dupe(u8, name), .active = active, .state = state });
    }
    return rows.toOwnedSlice(gpa);
}

pub fn freeRows(gpa: std.mem.Allocator, rows: []ProfileUsage) void {
    for (rows) |r| gpa.free(r.name);
    gpa.free(rows);
}

pub const ExclusionKind = enum { needs_sign_in, no_login, unreadable, weekly_unknown, full, resets_later };

pub const Exclusion = struct {
    name: []const u8,
    kind: ExclusionKind,

    pub fn reason(e: Exclusion) []const u8 {
        return switch (e.kind) {
            .needs_sign_in => "needs signing in again",
            .no_login => "no saved login",
            .unreadable => "usage could not be read",
            .weekly_unknown => "weekly usage unknown",
            .full => "weekly usage at or above 90%",
            .resets_later => "a profile resets sooner",
        };
    }
};

pub const Choice = struct {
    /// Index into the rows, or null when no profile qualifies.
    next: ?usize,
    /// One entry per non-active profile that was not chosen.
    excluded: std.ArrayList(Exclusion),

    pub fn deinit(c: *Choice, gpa: std.mem.Allocator) void {
        c.excluded.deinit(gpa);
    }
};

/// Picks the profile to switch to: not active, logged in, below the threshold,
/// with the earliest weekly reset; ties go to lower usage, then name.
pub fn chooseNext(gpa: std.mem.Allocator, rows: []const ProfileUsage) !Choice {
    var choice: Choice = .{ .next = null, .excluded = .empty };
    errdefer choice.deinit(gpa);
    for (rows, 0..) |row, i| {
        if (row.active) continue;
        const excluded: ?ExclusionKind = switch (row.state) {
            .needs_sign_in => .needs_sign_in,
            .no_login => .no_login,
            .failed => .unreadable,
            .usage => |u| if (u.seven_day) |w| (if (w.pct >= THRESHOLD_PCT) ExclusionKind.full else null) else .weekly_unknown,
        };
        if (excluded) |kind| {
            try choice.excluded.append(gpa, .{ .name = row.name, .kind = kind });
            continue;
        }
        if (choice.next) |best| {
            const a = rows[i].state.usage.seven_day.?;
            const b = rows[best].state.usage.seven_day.?;
            const better = a.resets_at < b.resets_at or
                (a.resets_at == b.resets_at and (a.pct < b.pct or (a.pct == b.pct and std.mem.lessThan(u8, rows[i].name, rows[best].name))));
            if (better) {
                try choice.excluded.append(gpa, .{ .name = rows[best].name, .kind = .resets_later });
                choice.next = i;
            } else {
                try choice.excluded.append(gpa, .{ .name = row.name, .kind = .resets_later });
            }
        } else choice.next = i;
    }
    return choice;
}

/// Weekly usage of the active profile, or null when it could not be read.
pub fn activeWeekly(rows: []const ProfileUsage) ?Window {
    for (rows) |r| {
        if (!r.active) continue;
        return switch (r.state) {
            .usage => |u| u.seven_day,
            else => null,
        };
    }
    return null;
}

fn formatReset(buf: []u8, epoch: i64) []const u8 {
    const c = @cImport(@cInclude("time.h"));
    var t: c.time_t = @intCast(epoch);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&t, &tm);
    const n = c.strftime(buf.ptr, buf.len, "%a %b %d %H:%M", &tm);
    return buf[0..n];
}

pub fn printRows(rows: []const ProfileUsage) void {
    for (rows) |row| {
        const marker: []const u8 = if (row.active) "> " else "  ";
        switch (row.state) {
            .usage => |u| {
                var b1: [64]u8 = undefined;
                var b2: [64]u8 = undefined;
                const five = u.five_hour orelse Window{ .pct = -1, .resets_at = 0 };
                const week = u.seven_day orelse Window{ .pct = -1, .resets_at = 0 };
                display.print("{s}{s:<12} 5h {d:>5.1}%  (resets {s})   7d {d:>5.1}%  (resets {s})\n", .{
                    marker,   row.name,                         five.pct, formatReset(&b1, five.resets_at),
                    week.pct, formatReset(&b2, week.resets_at),
                });
            },
            .needs_sign_in => display.print("{s}{s:<12} needs signing in again (saved login is no longer valid)\n", .{ marker, row.name }),
            .no_login => display.print("{s}{s:<12} no saved Claude Code login\n", .{ marker, row.name }),
            .failed => display.print("{s}{s:<12} usage could not be read\n", .{ marker, row.name }),
        }
    }
}

pub fn cmdUsage(gpa: std.mem.Allocator, io: std.Io) !void {
    const rows = try collect(gpa, io);
    defer freeRows(gpa, rows);
    display.print("\n", .{});
    printRows(rows);
    display.print("\n", .{});
}

pub fn cmdNext(gpa: std.mem.Allocator, io: std.Io) !void {
    const rows = try collect(gpa, io);
    defer freeRows(gpa, rows);
    var choice = try chooseNext(gpa, rows);
    defer choice.deinit(gpa);
    if (choice.next) |i| {
        display.print("Next profile: {s}\n", .{rows[i].name});
    } else {
        display.print("No profile has capacity.\n", .{});
    }
    for (choice.excluded.items) |e| display.print("  {s}: {s}\n", .{ e.name, e.reason() });
}

test "parseIso8601 handles offsets and fractions" {
    try std.testing.expectEqual(@as(i64, 1790874000), try parseIso8601("2026-10-01T17:00:00.148936+00:00"));
    try std.testing.expectEqual(@as(i64, 1790874000), try parseIso8601("2026-10-01T10:00:00-07:00"));
    try std.testing.expectEqual(@as(i64, 0), try parseIso8601("1970-01-01T00:00:00Z"));
    try std.testing.expectError(error.InvalidTimestamp, parseIso8601("yesterday"));
}

test "parseUsage reads both windows" {
    const u = try parseUsage(std.testing.allocator,
        \\{"five_hour":{"utilization":4.0,"resets_at":"2026-09-27T22:10:00+00:00"},"seven_day":{"utilization":79.0,"resets_at":"2026-10-01T17:00:00.148936+00:00"},"seven_day_opus":null}
    );
    try std.testing.expectEqual(@as(f64, 79), u.seven_day.?.pct);
    try std.testing.expectEqual(@as(i64, 1790874000), u.seven_day.?.resets_at);
    try std.testing.expectEqual(@as(f64, 4), u.five_hour.?.pct);
}

test "parseUsage reports a null weekly window as unknown, not 0%" {
    const u = try parseUsage(std.testing.allocator, "{\"five_hour\":null,\"seven_day\":null}");
    try std.testing.expect(u.seven_day == null);
}

test "parseUsage rejects non-JSON" {
    try std.testing.expectError(error.MalformedUsage, parseUsage(std.testing.allocator, "<html>"));
}

fn testRow(name: []const u8, active: bool, pct: f64, resets: i64) ProfileUsage {
    return .{ .name = name, .active = active, .state = .{ .usage = .{ .seven_day = .{ .pct = pct, .resets_at = resets } } } };
}

test "chooseNext picks the soonest weekly reset" {
    const gpa = std.testing.allocator;
    const rows = [_]ProfileUsage{ testRow("primary", true, 92, 100), testRow("b-fri", false, 0, 300), testRow("a-thu", false, 0, 200) };
    var c = try chooseNext(gpa, &rows);
    defer c.deinit(gpa);
    try std.testing.expectEqualStrings("a-thu", rows[c.next.?].name);
}

test "chooseNext excludes full profiles and ones needing sign-in" {
    const gpa = std.testing.allocator;
    const rows = [_]ProfileUsage{
        testRow("primary", true, 92, 100),
        testRow("full", false, 92, 50),
        .{ .name = "dead", .active = false, .state = .needs_sign_in },
        testRow("ok", false, 10, 400),
    };
    var c = try chooseNext(gpa, &rows);
    defer c.deinit(gpa);
    try std.testing.expectEqualStrings("ok", rows[c.next.?].name);
    try std.testing.expectEqual(@as(usize, 2), c.excluded.items.len);
    try std.testing.expectEqual(ExclusionKind.needs_sign_in, c.excluded.items[1].kind);
}

test "chooseNext returns none when every other profile is full (AE5)" {
    const gpa = std.testing.allocator;
    const rows = [_]ProfileUsage{ testRow("primary", true, 95, 100), testRow("x", false, 90, 50), testRow("y", false, 99, 60) };
    var c = try chooseNext(gpa, &rows);
    defer c.deinit(gpa);
    try std.testing.expect(c.next == null);
    try std.testing.expectEqual(@as(usize, 2), c.excluded.items.len);
}

test "chooseNext breaks reset ties by lower usage" {
    const gpa = std.testing.allocator;
    const rows = [_]ProfileUsage{ testRow("primary", true, 95, 100), testRow("x", false, 40, 500), testRow("y", false, 5, 500) };
    var c = try chooseNext(gpa, &rows);
    defer c.deinit(gpa);
    try std.testing.expectEqualStrings("y", rows[c.next.?].name);
}

test "activeWeekly returns the active profile's weekly window" {
    const rows = [_]ProfileUsage{ testRow("x", false, 1, 1), testRow("primary", true, 91, 7) };
    try std.testing.expectEqual(@as(f64, 91), activeWeekly(&rows).?.pct);
}
