//! json.zig — small helpers for reading std.json values.

const std = @import("std");

/// The string at `key` when `v` is an object holding a string there.
pub fn stringField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

test "stringField returns strings only" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"a\":\"x\",\"b\":1}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("x", stringField(parsed.value, "a").?);
    try std.testing.expect(stringField(parsed.value, "b") == null);
    try std.testing.expect(stringField(parsed.value, "c") == null);
}
