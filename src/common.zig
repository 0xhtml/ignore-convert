const std = @import("std");

pub fn concatPath(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    if (b.len == 0) return error.EmptyPath;
    if (a.len == 0) return try allocator.dupe(u8, b);
    return try std.mem.concat(allocator, u8, &.{ a, "/", b });
}
