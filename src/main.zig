const std = @import("std");
const Borg = @import("borg.zig");
const Git = @import("git.zig");
const Walker = @import("walker.zig");
const MinifiedWalker = @import("minified_walker.zig");

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
    const alloc = arena.allocator();

    var args = try std.process.ArgIterator.initWithAllocator(alloc);
    defer args.deinit();

    const program_name = args.next() orelse unreachable;
    const path = args.next() orelse printUsageAndExit(program_name);

    var filters = try std.ArrayListUnmanaged(Walker.Filter).initCapacity(alloc, 0);
    defer {
        for (filters.items) |*f| f.free();
        filters.deinit(alloc);
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--borg")) {
            const file_name = args.next() orelse printUsageAndExit(program_name);
            const file = try std.fs.cwd().openFile(file_name, .{});
            defer file.close();

            var state = try Borg.new(file, path.len);
            errdefer state.free();

            try filters.append(alloc, .{ .borg = state });
        } else if (std.mem.eql(u8, arg, "--git")) {
            try filters.append(alloc, .{ .git = Git.new() });
        } else {
            printUsageAndExit(program_name);
        }
    }

    var walker = try MinifiedWalker.init(alloc, path, filters.items);
    defer walker.deinit(alloc);

    while (try walker.next()) |entry| {
        std.debug.print("{s}\n", .{entry});
        alloc.free(entry);
    }
}
