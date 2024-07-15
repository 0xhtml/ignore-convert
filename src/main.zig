const std = @import("std");
const Borg = @import("borg.zig");
const Git = @import("git.zig");
const walker = @import("walker.zig");

fn printUsageAndExit(programName: []const u8) noreturn {
    std.debug.print("Usage: {s} <root directory> <ignore>...\n", .{programName});
    std.posix.exit(1);
}

pub fn main() !void {
    Borg.init();
    defer Borg.deinit();

    try Git.init();
    defer Git.deinit() catch unreachable;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var args = try std.process.ArgIterator.initWithAllocator(arena.allocator());
    defer args.deinit();

    const program_name = args.next() orelse unreachable;
    const path = args.next() orelse printUsageAndExit(program_name);

    var filters = std.ArrayList(walker.Filter).init(arena.allocator());
    defer {
        for (filters.items) |*f| f.free();
        filters.deinit();
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--borg")) {
            const file = try std.fs.cwd().openFile(args.next() orelse printUsageAndExit(program_name), .{});
            defer file.close();

            var state = try Borg.new(file, path.len);
            errdefer state.free();

            try filters.append(.{ .borg = state });
        } else if (std.mem.eql(u8, arg, "--git")) {
            try filters.append(.{ .git = Git.new() });
        } else {
            printUsageAndExit(program_name);
        }
    }

    try walker.recurseRoot(arena.allocator(), path, filters.items);
}
