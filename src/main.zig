const std = @import("std");
const common = @import("common.zig");
const borg = @import("borg.zig");
const git = @import("git.zig");

fn printUsageAndExit(programName: []const u8) noreturn {
    std.debug.print("Usage: {s} <root directory> <ignore>...\n", .{programName});
    std.posix.exit(1);
}

const PathDir = struct {
    path: []const u8,
    dir: std.fs.Dir,

    fn openDir(s: *const @This(), allocator: std.mem.Allocator, name: []const u8) !@This() {
        return .{
            .path = try common.concatPath(allocator, s.path, name),
            .dir = try s.dir.openDir(name, .{ .iterate = true }),
        };
    }

    fn free(s: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(s.path);
        s.dir.close();
        s.* = undefined;
    }
};

const State = union(enum) {
    borg: borg.State,
    git: git.State,

    pub fn update(s: *const @This(), allocator: std.mem.Allocator, path_dir: PathDir, entry: std.fs.Dir.Entry) !@This() {
        return switch (s.*) {
            .borg => |b| .{ .borg = b },
            .git => |g| .{ .git = try g.update(allocator, path_dir.dir, entry) },
        };
    }

    pub fn skip(s: *const @This(), allocator: std.mem.Allocator, path_dir: PathDir, entry: std.fs.Dir.Entry) !bool {
        return switch (s.*) {
            .borg => |b| b.skip(allocator, path_dir.path, entry.name),
            .git => |g| g.skip(entry.kind),
        };
    }

    pub fn free(s: *@This(), allocator: std.mem.Allocator) void {
        switch (s.*) {
            .borg => {},
            .git => |*g| g.free(allocator),
        }
    }

    pub fn deinit(s: *@This()) void {
        switch (s.*) {
            .borg => |*b| b.deinit(),
            .git => {},
        }
    }
};

const Return = enum {
    exclude,
    include,
    ignore,
};

fn recurse(allocator: std.mem.Allocator, path_dir: PathDir, entry: std.fs.Dir.Entry, states: []const State) !Return {
    switch (entry.kind) {
        .directory, .file => {},
        .sym_link => return .ignore,
        else => return error.UnsupportedFileType,
    }

    // TODO make a option or move to git
    if (std.mem.eql(u8, entry.name, ".git")) return .ignore;

    var _states = std.ArrayList(State).init(allocator);
    defer {
        for (_states.items) |*state| state.free(allocator);
        _states.deinit();
    }
    for (states) |state| {
        var _state = try state.update(allocator, path_dir, entry);
        errdefer _state.free(allocator);
        try _states.append(_state);
        if (try _state.skip(allocator, path_dir, entry)) return .exclude;
    }

    if (entry.kind != .directory) return .include;

    var _path_dir = try path_dir.openDir(allocator, entry.name);
    defer _path_dir.free(allocator);

    var ret: Return = .ignore;

    // TODO test if lazy allocation or smth if faster
    var excluded = std.ArrayList([]const u8).init(allocator);
    defer excluded.deinit();

    var it = _path_dir.dir.iterate();
    while (try it.next()) |_entry| {
        switch (try recurse(allocator, _path_dir, _entry, _states.items)) {
            .exclude => {
                if (ret == .ignore) ret = .exclude;
                try excluded.append(_entry.name);
            },
            .include => ret = .include,
            .ignore => {},
        }
    }

    if (ret == .include) for (excluded.items) |name| {
        std.debug.print("{s}/{s}\n", .{ _path_dir.path, name });
    };

    return ret;
}

fn recurseRoot(allocator: std.mem.Allocator, dir: std.fs.Dir, states: []const State) !void {
    const dir_w_path = .{ .dir = dir, .path = "" };
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (try recurse(allocator, dir_w_path, entry, states) == .exclude) {
            std.debug.print("{s}\n", .{entry.name});
        }
    }
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

    var states = std.ArrayList(State).init(arena.allocator());
    defer {
        for (states.items) |*state| state.deinit();
        states.deinit();
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--borg")) {
            const file = try std.fs.cwd().openFile(args.next() orelse printUsageAndExit(program_name), .{});
            defer file.close();

            var state = try borg.State.init(file);
            errdefer state.deinit();

            try states.append(.{ .borg = state });
        } else if (std.mem.eql(u8, arg, "--git")) {
            try states.append(.{ .git = git.State.init() });
        } else {
            printUsageAndExit(program_name);
        }
    }

    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    try recurseRoot(arena.allocator(), dir, states.items);
}
