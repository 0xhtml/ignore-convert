const std = @import("std");
const common = @import("common.zig");
const Borg = @import("borg.zig");
const Git = @import("git.zig");
const Walker = @import("walker.zig");
const MinifiedWalker = @import("minified_walker.zig");

fn printUsageAndExit(programName: []const u8) noreturn {
    std.debug.print("Usage: {s} <root directory> <ignore>...\n", .{programName});
    std.posix.exit(1);
}

const FilterUnion =  union {
    borg: Borg,
    git: Git,
};

const FilterList = struct {
    filters: std.ArrayListUnmanaged(FilterUnion),
    interfaces: std.ArrayListUnmanaged(common.Filter),

    fn init(alloc: std.mem.Allocator) !@This() {
        return .{
            .filters = try std.ArrayListUnmanaged(FilterUnion).initCapacity(alloc, 0),
            .interfaces = try std.ArrayListUnmanaged(common.Filter).initCapacity(alloc, 0),
        };
    }

    fn deinit(s: *@This(), alloc: std.mem.Allocator) void {
        for (s.interfaces.items) |*f| f.free();
        s.filters.deinit(alloc);
        s.interfaces.deinit(alloc);
    }

    fn append(s: *@This(), alloc: std.mem.Allocator, filter: FilterUnion, interface: common.Filter) !void {
        try s.filters.append(alloc, filter);
        errdefer _ = s.filters.pop();
        try s.interfaces.append(alloc, interface);
    }
};

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

    var filters = try FilterList.init(alloc);
    defer filters.deinit(alloc);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--borg")) {
            const file_name = args.next() orelse printUsageAndExit(program_name);
            const file = try std.fs.cwd().openFile(file_name, .{});
            defer file.close();

            var filter = try Borg.new(file, path.len);
            errdefer filter.filter().free();
            try filters.append(alloc, .{ .borg = filter }, filter.filter());
        } else if (std.mem.eql(u8, arg, "--git")) {
            var filter = Git.new();
            errdefer filter.filter().free();
            try filters.append(alloc, .{ .git = filter }, filter.filter());
        } else {
            printUsageAndExit(program_name);
        }
    }

    var walker = try MinifiedWalker.init(alloc, path, filters.interfaces.items);
    defer walker.deinit(alloc);

    while (try walker.next()) |entry| {
        std.debug.print("{s}\n", .{entry});
        alloc.free(entry);
    }
}
