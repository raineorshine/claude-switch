//! exec.zig — run a subprocess with optional stdin data and a wall-clock timeout.
//!
//! std.process.run in Zig 0.16 always ignores stdin, and csw needs to pass
//! secrets on stdin (never in argv) and bound unattended runs.

const std = @import("std");

pub const Options = struct {
    argv: []const []const u8,
    /// Written to the child's stdin, which is then closed. Null leaves stdin empty.
    input: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    /// Wall-clock limit in seconds. Null waits forever.
    timeout_s: ?i64 = null,
    stdout_limit: usize = 4 * 1024 * 1024,
    stderr_limit: usize = 64 * 1024,
};

pub const Result = struct {
    /// Exit code when the process exited normally.
    code: ?u8,
    timed_out: bool,
    stdout: []u8,
    stderr: []u8,

    pub fn ok(r: Result) bool {
        return !r.timed_out and r.code != null and r.code.? == 0;
    }

    pub fn deinit(r: Result, gpa: std.mem.Allocator) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: Options) !Result {
    var child = try std.process.spawn(io, .{
        .argv = opts.argv,
        .cwd = if (opts.cwd) |p| .{ .path = p } else .inherit,
        .stdin = if (opts.input != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    if (opts.input) |data| {
        child.stdin.?.writeStreamingAll(io, data) catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }

    const timeout: std.Io.Timeout = if (opts.timeout_s) |s|
        (std.Io.Timeout{ .duration = .{ .raw = std.Io.Duration.fromSeconds(s), .clock = .awake } }).toDeadline(io)
    else
        .none;

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(gpa, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();

    var timed_out = false;
    while (reader.fill(64, timeout)) |_| {
        if (reader.reader(0).buffered().len > opts.stdout_limit) return error.StreamTooLong;
        if (reader.reader(1).buffered().len > opts.stderr_limit) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => timed_out = true,
        else => |e| return e,
    }

    var code: ?u8 = null;
    if (timed_out) {
        child.kill(io);
    } else {
        try reader.checkAnyError();
        const term = try child.wait(io);
        code = switch (term) {
            .exited => |c| c,
            else => null,
        };
    }

    const out = try reader.toOwnedSlice(0);
    errdefer gpa.free(out);
    const err_out = try reader.toOwnedSlice(1);
    return .{ .code = code, .timed_out = timed_out, .stdout = out, .stderr = err_out };
}

test "run passes input on stdin, not argv" {
    const gpa = std.testing.allocator;
    const r = try run(gpa, std.testing.io, .{ .argv = &.{"/bin/cat"}, .input = "secret-token" });
    defer r.deinit(gpa);
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings("secret-token", r.stdout);
}

test "run reports a nonzero exit" {
    const gpa = std.testing.allocator;
    const r = try run(gpa, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "echo oops >&2; exit 3" } });
    defer r.deinit(gpa);
    try std.testing.expect(!r.ok());
    try std.testing.expectEqual(@as(?u8, 3), r.code);
    try std.testing.expectEqualStrings("oops\n", r.stderr);
}

test "run kills a process that outlives its timeout" {
    const gpa = std.testing.allocator;
    const r = try run(gpa, std.testing.io, .{ .argv = &.{ "/bin/sleep", "30" }, .timeout_s = 1 });
    defer r.deinit(gpa);
    try std.testing.expect(r.timed_out);
    try std.testing.expect(!r.ok());
}
