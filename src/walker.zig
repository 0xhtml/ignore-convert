const std = @import("std");
const common = @import("common.zig");
const Borg = @import("borg.zig");
const Git = @import("git.zig");

pub const Filter = union(enum) {
    borg: Borg,
    git: Git,

    fn enter(s: *@This(), level: usize, _path: [:0]const u8) !void {
        return switch (s.*) {
            .borg => {},
            .git => |*g| g.enter(level, _path),
        };
    }

    fn leave(s: *@This(), level: usize) void {
        return switch (s.*) {
            .borg => {},
            .git => |*g| g.leave(level),
        };
    }

    fn check(s: @This(), kind: std.fs.File.Kind, _path: [:0]const u8) !common.Action {
        return switch (s) {
            .borg => |b| b.check(_path),
            .git => |g| g.check(kind, _path),
        };
    }

    pub fn free(s: *@This()) void {
        switch (s.*) {
            .borg => |*b| b.free(),
            .git => |*g| g.free(),
        }
    }
};

pub const Entry = struct {
    action: common.Action,
    path: [:0]const u8,

    pub fn copy(s: @This(), allocator: std.mem.Allocator) !Entry {
        return .{ .action = s.action, .path = try allocator.dupeZ(u8, s.path) };
    }
};

pub const ActionOrEntry = union(enum) {
    enter: void,
    leave: struct {
        path: [:0]const u8,
    },
    entry: Entry,
};

const StackItem = struct {
    iter: std.fs.Dir.Iterator,
    dirname_len: usize,
};

allocator: std.mem.Allocator,
stack: std.ArrayListUnmanaged(StackItem),
name_buffer: std.ArrayListUnmanaged(u8),
filters: []Filter,

pub fn init(allocator: std.mem.Allocator, dirname: [:0]const u8, filters: []Filter) !@This() {
    var stack: std.ArrayListUnmanaged(StackItem) = .{};
    errdefer stack.deinit(allocator);

    var name_buffer = try std.ArrayListUnmanaged(u8).initCapacity(allocator, dirname.len + 1);
    errdefer name_buffer.deinit(allocator);
    name_buffer.appendSliceAssumeCapacity(dirname);
    name_buffer.appendAssumeCapacity(0);

    var dir = try std.fs.cwd().openDir(dirname, .{ .iterate = true });
    errdefer dir.close();

    try stack.append(allocator, .{
        .iter = dir.iterateAssumeFirstIteration(),
        .dirname_len = name_buffer.items.len - 1,
    });

    for (filters) |*f| try f.enter(1, dirname);

    return .{
        .allocator = allocator,
        .stack = stack,
        .name_buffer = name_buffer,
        .filters = filters,
    };
}

fn path(s: @This()) [:0]const u8 {
    return s.name_buffer.items[0 .. s.name_buffer.items.len - 1 :0];
}

fn enter(s: *@This(), name: []const u8) !void {
    var dir = try s.stack.getLast().iter.dir.openDir(name, .{ .iterate = true });
    errdefer dir.close();

    try s.stack.append(s.allocator, .{
        .iter = dir.iterateAssumeFirstIteration(),
        .dirname_len = s.name_buffer.items.len - 1,
    });

    for (s.filters) |*f| try f.enter(s.stack.items.len, s.path());
}

fn check(s: @This(), kind: std.fs.File.Kind) !common.Action {
    for (s.filters) |f| {
        switch (try f.check(kind, s.path())) {
            .include => {},
            .exclude => return .exclude,
        }
    }
    return .include;
}

pub fn next(s: *@This()) !?ActionOrEntry {
    while (s.stack.items.len != 0) {
        const top = &s.stack.items[s.stack.items.len - 1];

        if (try top.iter.next()) |entry| {
            s.name_buffer.shrinkRetainingCapacity(top.dirname_len);
            if (s.name_buffer.items.len != 0) s.name_buffer.appendAssumeCapacity(std.fs.path.sep);
            try s.name_buffer.ensureUnusedCapacity(s.allocator, entry.name.len + 1);
            s.name_buffer.appendSliceAssumeCapacity(entry.name);
            s.name_buffer.appendAssumeCapacity(0);

            const action = try s.check(entry.kind);
            return switch (entry.kind) {
                .directory => switch (action) {
                    .include => blk: {
                        try s.enter(entry.name);
                        break :blk .{ .enter = {} };
                    },
                    .exclude => .{ .entry = .{
                        .action = .exclude,
                        .path = s.path(),
                    } },
                },
                else => .{ .entry = .{
                    .action = action,
                    .path = s.path(),
                } },
            };
        }

        for (s.filters) |*f| f.leave(s.stack.items.len);
        var item = s.stack.pop();
        item.iter.dir.close();

        s.name_buffer.shrinkRetainingCapacity(item.dirname_len);
        s.name_buffer.appendAssumeCapacity(0);

        if (s.stack.items.len != 0) return .{ .leave = .{
            .path = s.path(),
        } };
    }
    return null;
}

pub fn deinit(s: *@This(), allocator: std.mem.Allocator) void {
    for (s.stack.items) |*i| i.iter.dir.close();
    s.stack.deinit(allocator);
    s.name_buffer.deinit(allocator);
    s.* = undefined;
}
