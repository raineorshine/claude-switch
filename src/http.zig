//! http.zig — HTTPS requests through curl, with every secret passed on stdin.
//!
//! The request (URL, headers, body) is written as a curl config block to
//! curl's stdin (`--config -`), so tokens never appear in process arguments.

const std = @import("std");
const exec = @import("exec.zig");

/// Cloudflare rejects curl's and Python's default agents on Anthropic's token
/// endpoint (error 1010); a CLI-style agent is accepted.
pub const USER_AGENT = "claude-cli/2.1.283 (external, cli)";

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    method: []const u8 = "GET",
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    timeout_s: i64 = 20,
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(r: Response, gpa: std.mem.Allocator) void {
        gpa.free(r.body);
    }
};

fn appendQuoted(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(gpa, '"');
    for (value) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => try out.append(gpa, ch),
    };
    try out.append(gpa, '"');
}

fn appendOption(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try out.appendSlice(gpa, name);
    try out.appendSlice(gpa, " = ");
    try appendQuoted(gpa, out, value);
    try out.append(gpa, '\n');
}

/// Builds the curl config block for `req`. Caller owns the result.
pub fn curlConfig(gpa: std.mem.Allocator, req: Request) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "silent\nshow-error\n");
    try appendOption(gpa, &out, "url", req.url);
    try appendOption(gpa, &out, "request", req.method);
    try appendOption(gpa, &out, "user-agent", USER_AGENT);
    const max_time = try std.fmt.allocPrint(gpa, "{d}", .{req.timeout_s});
    defer gpa.free(max_time);
    try appendOption(gpa, &out, "max-time", max_time);
    try appendOption(gpa, &out, "write-out", "\n%{http_code}");
    for (req.headers) |h| {
        const line = try std.fmt.allocPrint(gpa, "{s}: {s}", .{ h.name, h.value });
        defer gpa.free(line);
        try appendOption(gpa, &out, "header", line);
    }
    if (req.body) |body| try appendOption(gpa, &out, "data-raw", body);
    return out.toOwnedSlice(gpa);
}

/// curl's argv. Fixed: everything request-specific travels on stdin.
pub const CURL_ARGV = [_][]const u8{ "curl", "--config", "-" };

/// Splits curl's stdout (`<body>\n<status>`) into a response. Caller owns body.
pub fn parseOutput(gpa: std.mem.Allocator, stdout: []const u8) !Response {
    const nl = std.mem.lastIndexOfScalar(u8, stdout, '\n') orelse return error.MalformedCurlOutput;
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, stdout[nl + 1 ..], " \r\n"), 10) catch return error.MalformedCurlOutput;
    return .{ .status = status, .body = try gpa.dupe(u8, stdout[0..nl]) };
}

pub fn send(gpa: std.mem.Allocator, io: std.Io, req: Request) !Response {
    const config = try curlConfig(gpa, req);
    defer {
        @memset(config, 0);
        gpa.free(config);
    }
    const result = try exec.run(gpa, io, .{ .argv = &CURL_ARGV, .input = config, .timeout_s = req.timeout_s + 5 });
    defer result.deinit(gpa);
    if (!result.ok()) return error.RequestFailed;
    return parseOutput(gpa, result.stdout);
}

test "curlConfig keeps the token out of argv and escapes values" {
    const gpa = std.testing.allocator;
    const cfg = try curlConfig(gpa, .{
        .method = "POST",
        .url = "https://example.test/x",
        .headers = &.{.{ .name = "Authorization", .value = "Bearer sk-secret" }},
        .body = "{\"a\":\"b\\c\"}",
    });
    defer gpa.free(cfg);
    for (CURL_ARGV) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "sk-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "header = \"Authorization: Bearer sk-secret\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "data-raw = \"{\\\"a\\\":\\\"b\\\\c\\\"}\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "user-agent = \"claude-cli/") != null);
}

test "parseOutput splits body from status" {
    const gpa = std.testing.allocator;
    const r = try parseOutput(gpa, "{\"ok\":true}\n200");
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
}

test "parseOutput rejects output without a status line" {
    try std.testing.expectError(error.MalformedCurlOutput, parseOutput(std.testing.allocator, "no status"));
}

test "send round-trips through a real curl against a local file" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "body.json", .data = "{\"x\":1}" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const url = try std.fmt.allocPrint(gpa, "file://{s}/body.json", .{buf[0..len]});
    defer gpa.free(url);
    const r = try send(gpa, std.testing.io, .{ .url = url });
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("{\"x\":1}", r.body);
}
