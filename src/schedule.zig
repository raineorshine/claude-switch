//! schedule.zig — `csw schedule install|uninstall|status`: the 22:00 launchd agent.

const std = @import("std");
const display = @import("display.zig");
const exec = @import("exec.zig");
const paths = @import("paths.zig");

pub const LABEL = "com.github.raineorshine.csw-handoff";
/// Directories the unattended run needs besides claude's: git and its credential
/// helpers for the cloud-session clones, plus the system tools csw calls.
const BASE_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

fn xmlEscape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |ch| switch (ch) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        else => try out.append(gpa, ch),
    };
    return out.toOwnedSlice(gpa);
}

/// The LaunchAgent plist. `claude_dir` is prepended to PATH so the run finds claude.
pub fn plist(gpa: std.mem.Allocator, csw_path: []const u8, claude_dir: []const u8, log_path: []const u8) ![]u8 {
    const exe = try xmlEscape(gpa, csw_path);
    defer gpa.free(exe);
    const path_env = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ claude_dir, BASE_PATH });
    defer gpa.free(path_env);
    const path_xml = try xmlEscape(gpa, path_env);
    defer gpa.free(path_xml);
    const log = try xmlEscape(gpa, log_path);
    defer gpa.free(log);
    return std.fmt.allocPrint(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>{s}</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>{s}</string>
        \\    <string>handoff</string>
        \\    <string>--scheduled</string>
        \\  </array>
        \\  <key>StartCalendarInterval</key>
        \\  <dict>
        \\    <key>Hour</key>
        \\    <integer>22</integer>
        \\    <key>Minute</key>
        \\    <integer>0</integer>
        \\  </dict>
        \\  <key>EnvironmentVariables</key>
        \\  <dict>
        \\    <key>PATH</key>
        \\    <string>{s}</string>
        \\  </dict>
        \\  <key>StandardOutPath</key>
        \\  <string>{s}</string>
        \\  <key>StandardErrorPath</key>
        \\  <string>{s}</string>
        \\</dict>
        \\</plist>
        \\
    , .{ LABEL, exe, path_xml, log, log });
}

fn selfPath(buf: []u8) ![]const u8 {
    var size: u32 = @intCast(buf.len);
    if (std.c._NSGetExecutablePath(buf.ptr, &size) != 0) return error.NoExecutablePath;
    return std.mem.sliceTo(buf, 0);
}

/// Directory holding the `claude` found on PATH.
fn claudeDir(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const path = std.c.getenv("PATH") orelse return error.ClaudeNotFound;
    var it = std.mem.splitScalar(u8, std.mem.sliceTo(path, 0), ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(gpa, &.{ dir, "claude" });
        defer gpa.free(candidate);
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return gpa.dupe(u8, dir);
    }
    return error.ClaudeNotFound;
}

fn plistPath(gpa: std.mem.Allocator) ![]u8 {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    const name = LABEL ++ ".plist";
    return std.fs.path.join(gpa, &.{ h, "Library", "LaunchAgents", name });
}

fn domain(gpa: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(gpa, "gui/{d}", .{std.c.getuid()});
}

fn launchctl(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "/bin/launchctl");
    try argv.appendSlice(gpa, args);
    const r = try exec.run(gpa, io, .{ .argv = argv.items, .timeout_s = 30 });
    defer r.deinit(gpa);
    return r.ok();
}

pub fn isLoaded(gpa: std.mem.Allocator, io: std.Io) !bool {
    const d = try domain(gpa);
    defer gpa.free(d);
    const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ d, LABEL });
    defer gpa.free(target);
    return launchctl(gpa, io, &.{ "print", target });
}

pub fn install(gpa: std.mem.Allocator, io: std.Io) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const csw = try selfPath(&buf);
    const cdir = claudeDir(gpa, io) catch {
        display.err("claude not found on PATH; install Claude Code first.");
        return error.ClaudeNotFound;
    };
    defer gpa.free(cdir);
    const h = try paths.home(gpa);
    defer gpa.free(h);
    const log_dir = try std.fs.path.join(gpa, &.{ h, "Library", "Application Support", "csw" });
    defer gpa.free(log_dir);
    try std.Io.Dir.cwd().createDirPath(io, log_dir);
    const log = try std.fs.path.join(gpa, &.{ log_dir, "handoff.log" });
    defer gpa.free(log);

    const text = try plist(gpa, csw, cdir, log);
    defer gpa.free(text);
    const p = try plistPath(gpa);
    defer gpa.free(p);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?);

    uninstallAgent(gpa, io) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text });
    const d = try domain(gpa);
    defer gpa.free(d);
    if (!try launchctl(gpa, io, &.{ "bootstrap", d, p })) return error.LaunchctlFailed;
    display.ok("Nightly handoff scheduled for 22:00.");
}

fn uninstallAgent(gpa: std.mem.Allocator, io: std.Io) !void {
    const d = try domain(gpa);
    defer gpa.free(d);
    const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ d, LABEL });
    defer gpa.free(target);
    _ = launchctl(gpa, io, &.{ "bootout", target }) catch false;
}

pub fn uninstall(gpa: std.mem.Allocator, io: std.Io) !void {
    try uninstallAgent(gpa, io);
    const p = try plistPath(gpa);
    defer gpa.free(p);
    std.Io.Dir.cwd().deleteFile(io, p) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    display.ok("Nightly handoff unscheduled.");
}

pub fn status(gpa: std.mem.Allocator, io: std.Io) !void {
    if (try isLoaded(gpa, io)) {
        display.print("Nightly handoff: scheduled daily at 22:00 ({s}).\n", .{LABEL});
    } else {
        display.print("Nightly handoff: not scheduled. Run: csw schedule install\n", .{});
    }
}

pub fn cmdSchedule(gpa: std.mem.Allocator, io: std.Io, sub: ?[]const u8) !void {
    const s = sub orelse "status";
    if (std.mem.eql(u8, s, "install")) return install(gpa, io);
    if (std.mem.eql(u8, s, "uninstall")) return uninstall(gpa, io);
    if (std.mem.eql(u8, s, "status")) return status(gpa, io);
    display.print("❌  Usage: csw schedule [install|uninstall|status]\n", .{});
    return error.UnknownOption;
}

test "plist runs csw handoff --scheduled at 22:00 with claude on PATH" {
    const gpa = std.testing.allocator;
    const text = try plist(gpa, "/Users/a b/.local/bin/csw", "/Users/a b/.local/bin", "/tmp/h.log");
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "<string>" ++ LABEL ++ "</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<string>/Users/a b/.local/bin/csw</string>\n    <string>handoff</string>\n    <string>--scheduled</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<key>Hour</key>\n    <integer>22</integer>\n    <key>Minute</key>\n    <integer>0</integer>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<string>/Users/a b/.local/bin:/opt/homebrew/bin:") != null);
}

test "plist escapes XML special characters in paths" {
    const gpa = std.testing.allocator;
    const text = try plist(gpa, "/x/<&>/csw", "/y", "/l");
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "/x/&lt;&amp;&gt;/csw") != null);
}
