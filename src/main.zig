const std = @import("std");
const borg = @import("borg.zig");
const git = @import("git.zig");
const walker = @import("walker.zig");

fn printUsageAndExit(programName: []const u8) noreturn {
    std.debug.print("Usage: {s} <root directory> <ignore>...\n", .{programName});
    std.posix.exit(1);
}

pub fn main() !void {
    borg.init();
    defer borg.deinit();

    try git.init();
    defer git.deinit() catch unreachable;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var args = try std.process.ArgIterator.initWithAllocator(arena.allocator());
    defer args.deinit();

    const program_name = args.next() orelse unreachable;
    const path = args.next() orelse printUsageAndExit(program_name);

    var states = std.ArrayList(walker.Filter).init(arena.allocator());
    defer {
        for (states.items) |*state| state.deinit();
        states.deinit();
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--borg")) {
            const file = try std.fs.cwd().openFile(args.next() orelse printUsageAndExit(program_name), .{});
            defer file.close();

            var state = try borg.State.init(file, path.len);
            errdefer state.deinit();

            try states.append(.{ .borg = state });
        } else if (std.mem.eql(u8, arg, "--git")) {
            try states.append(.{ .git = git.State.init() });
        } else {
            printUsageAndExit(program_name);
        }
    }

    try walker.recurseRoot(arena.allocator(), path, states.items);
}
