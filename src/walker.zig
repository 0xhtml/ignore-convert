const std = @import("std");
const borg = @import("borg.zig");
const git = @import("git.zig");

pub const Filter = union(enum) {
    borg: borg.State,
    git: git.State,

    pub fn update(s: @This(), path: [*:0]u8, entry: std.fs.Dir.Entry) !@This() {
        return switch (s) {
            .borg => |b| .{ .borg = b },
            .git => |g| .{ .git = try g.update(path, entry.kind) },
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

pub fn recurseRoot(allocator: std.mem.Allocator, path: []const u8, filters: []const Filter) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var _path: [std.fs.MAX_PATH_BYTES:0]u8 = undefined;
    @memcpy(_path[0..path.len], path);
    _path[path.len] = 0;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (try recurse(allocator, &_path, dir, entry, filters)) {
            .exclude => std.debug.print("- {s}\n", .{entry.name}),
            .include => std.debug.print("+ {s}\n", .{entry.name}),
            .ignore => {},
        }
    }
}

fn recurse(allocator: std.mem.Allocator, path: *[std.fs.MAX_PATH_BYTES:0]u8, dir: std.fs.Dir, entry: std.fs.Dir.Entry, filters: []const Filter) !Return {
    switch (entry.kind) {
        .directory, .file => {},
        .sym_link => return .ignore,
        else => return error.UnsupportedFileType,
    }

    // TODO make a option or move to git
    if (std.mem.eql(u8, entry.name, ".git")) return .ignore;

    var path_len = std.mem.span(@as([*:0]u8, path)).len;
    if (path_len != 0) {
        path[path_len] = '/';
        path_len += 1;
    }
    @memcpy(path[path_len..path_len + entry.name.len], entry.name);
    path[path_len + entry.name.len] = 0;
    if (path_len != 0) path_len -= 1;
    defer path[path_len] = 0;

    var _filters = std.ArrayList(Filter).init(allocator);
    defer {
        for (_filters.items) |*f| f.free();
        _filters.deinit();
    }
    for (filters) |filter| {
        var _filter = try filter.update(path, entry);
        errdefer _filter.free();
        try _filters.append(_filter);
        if (try _filter.skip(path, entry)) return .exclude;
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

        switch (try recurse(allocator, path, _dir, _entry, _filters.items)) {
            .exclude => try excluded.append(name),
            .include => try included.append(name),
            .ignore => allocator.free(name),
        }
    }

    if (included.items.len != 0 and excluded.items.len != 0) {
        for (excluded.items) |name| std.debug.print("- {s}/{s}\n", .{ @as([*:0]u8, path), name });
        for (included.items) |name| std.debug.print("+ {s}/{s}\n", .{ @as([*:0]u8, path), name });
        return .include;
    }
    if (included.items.len == 0 and excluded.items.len != 0) return .exclude;
    return .ignore;
}
