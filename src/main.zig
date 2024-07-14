const std = @import("std");
const borg = @import("borg.zig");
const git = @import("git.zig");

fn printUsageAndExit(programName: []const u8) noreturn {
    std.debug.print("Usage: {s} <root directory> <ignore>...\n", .{programName});
    std.posix.exit(1);
}

const State = union(enum) {
    borg: borg.State,
    git: git.State,

    pub fn update(s: @This(), dir: std.fs.Dir, entry: std.fs.Dir.Entry) !@This() {
        return switch (s) {
            .borg => |b| .{ .borg = b },
            .git => |g| .{ .git = try g.update(dir, entry) },
        };
    }

    pub fn skip(s: @This(), path: [*:0]u8, entry: std.fs.Dir.Entry) !bool {
        return switch (s) {
            .borg => |b| b.skip(std.mem.span(path)),
            .git => |g| g.skip(path, entry.kind),
        };
    }

    pub fn free(s: *@This()) void {
        switch (s.*) {
            .borg => {},
            .git => |*g| g.free(),
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

const RecurseState = struct {
    path: [std.fs.MAX_PATH_BYTES:0]u8,

    fn recurseRoot(allocator: std.mem.Allocator, dir: std.fs.Dir, states: []const State) !void {
        var recurse_state = RecurseState{ .path = undefined };
        recurse_state.path[0] = 0;

        // const dir_w_path = .{ .dir = dir, .path = "" };
        var it = dir.iterate();
        while (try it.next()) |entry| {
            switch (try recurse_state.recurse(allocator, dir, entry, states)) {
                .exclude => std.debug.print("- {s}\n", .{entry.name}),
                .include => std.debug.print("+ {s}\n", .{entry.name}),
                .ignore => {},
            }
        }
    }

    fn recurse(s: *@This(), allocator: std.mem.Allocator, dir: std.fs.Dir, entry: std.fs.Dir.Entry, states: []const State) !Return {
        switch (entry.kind) {
            .directory, .file => {},
            .sym_link => return .ignore,
            else => return error.UnsupportedFileType,
        }

        // TODO make a option or move to git
        if (std.mem.eql(u8, entry.name, ".git")) return .ignore;

        var path_len = std.mem.span(@as([*:0]u8, &s.path)).len;
        if (path_len != 0) {
            s.path[path_len] = '/';
            path_len += 1;
        }
        @memcpy(s.path[path_len..path_len + entry.name.len], entry.name);
        s.path[path_len + entry.name.len] = 0;
        if (path_len != 0) path_len -= 1;
        defer s.path[path_len] = 0;

        var _states = std.ArrayList(State).init(allocator);
        defer {
            for (_states.items) |*state| state.free();
            _states.deinit();
        }
        for (states) |state| {
            var _state = try state.update(dir, entry);
            errdefer _state.free();
            try _states.append(_state);
            if (try _state.skip(&s.path, entry)) return .exclude;
        }

        if (entry.kind != .directory) return .include;

        var _dir = try dir.openDir(entry.name, .{ .iterate = true });
        defer _dir.close();

        var excluded = std.ArrayList([]const u8).init(allocator);
        defer {
            for (excluded.items) |name| allocator.free(name);
            excluded.deinit();
        }

        var included = std.ArrayList([]const u8).init(allocator);
        defer {
            for (included.items) |name| allocator.free(name);
            included.deinit();
        }

        var it = _dir.iterate();
        while (try it.next()) |_entry| {
            const name = try allocator.dupe(u8, _entry.name);
            errdefer allocator.free(name);

            switch (try s.recurse(allocator, _dir, _entry, _states.items)) {
                .exclude => try excluded.append(name),
                .include => try included.append(name),
                .ignore => allocator.free(name),
            }
        }

        if (included.items.len != 0 and excluded.items.len != 0) {
            for (excluded.items) |name| std.debug.print("- {s}/{s}\n", .{ @as([*:0]u8, &s.path), name });
            for (included.items) |name| std.debug.print("+ {s}/{s}\n", .{ @as([*:0]u8, &s.path), name });
            return .include;
        }
        if (included.items.len == 0 and excluded.items.len != 0) return .exclude;
        return .ignore;
    }
};

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

    try RecurseState.recurseRoot(arena.allocator(), dir, states.items);
}
