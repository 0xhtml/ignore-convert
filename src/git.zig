const std = @import("std");
const common = @import("common.zig");
const libgit2 = @cImport({
    @cInclude("git2.h");
    @cInclude("git2/sys/repository.h");
});

pub fn init() !void {
    if (libgit2.git_libgit2_init() < 0) return error.ErrorInitializingLibgit2;
}

pub fn deinit() !void {
    if (libgit2.git_libgit2_shutdown() < 0) return error.ErrorDeinitializingLibgit2;
}

repo: ?*libgit2.git_repository,
level: usize,
dirname_len: usize,

pub fn new() @This() {
    return .{ .repo = null, .level = 0, .dirname_len = 0 };
}

pub fn filter(s: *@This()) common.Filter {
    return .{
        .ptr = s,
        .enterFn = enter,
        .leaveFn = leave,
        .checkFn = check,
        .includeEmptyFn = includeEmpty,
        .freeFn = free,
    };
}

fn enter(ptr: *anyopaque, level: usize, path: [:0]const u8) void {
    const s: *@This() = @ptrCast(@alignCast(ptr));

    if (s.repo != null) return;

    // TODO: support opening repo in parent dir
    if (libgit2.git_repository_open(&s.repo, path) < 0) return;
    std.debug.assert(s.repo != null);

    s.level = level;
    s.dirname_len = path.len;
    _ = libgit2.git_repository_submodule_cache_all(s.repo);
}

fn leave(ptr: *anyopaque, level: usize) void {
    const s: *@This() = @ptrCast(@alignCast(ptr));
    if (s.repo == null or level > s.level) return;
    libgit2.git_repository_free(s.repo);
    s.repo = null;
}

fn check(ptr: *const anyopaque, kind: std.fs.Dir.Entry.Kind, path: [:0]const u8) !common.Action {
    const s: *const @This() = @ptrCast(@alignCast(ptr));

    if (s.repo == null) return .include;

    const offset_path = path[s.dirname_len + 1 .. :0];

    return switch (kind) {
        // TODO make submodule exclusion configurable
        .directory => if (libgit2.git_submodule_lookup(null, s.repo, offset_path) >= 0) .exclude else .include,
        else => blk: {
            // TODO configure libgit to include .git
            if (std.mem.startsWith(u8, offset_path, ".git") and (offset_path.len == 4 or offset_path[4] == '/')) {
                break :blk .include;
            }
            var ignored: c_int = undefined;
            if (libgit2.git_ignore_path_is_ignored(&ignored, s.repo, offset_path) < 0) {
                break :blk error.InvalidIgnoreRules;
            }
            break :blk switch (ignored) {
                0 => .include,
                1 => .exclude,
                else => unreachable,
            };
        },
    };
}

fn includeEmpty(ptr: *const anyopaque) bool {
    const s: *const @This() = @ptrCast(@alignCast(ptr));
    return s.repo == null;
}

fn free(ptr: *anyopaque) void {
    const s: *@This() = @ptrCast(@alignCast(ptr));
    libgit2.git_repository_free(s.repo);
    s.* = undefined;
}
