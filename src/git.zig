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

pub fn enter(s: *@This(), level: usize, path: [:0]const u8) !void {
    if (s.repo != null) return;

    // TODO: support opening repo in parent dir
    if (libgit2.git_repository_open(&s.repo, path) < 0) return;
    std.debug.assert(s.repo != null);

    s.level = level;
    s.dirname_len = path.len;
    _ = libgit2.git_repository_submodule_cache_all(s.repo);
}

pub fn leave(s: *@This(), level: usize) void {
    if (s.repo == null or level > s.level) return;
    libgit2.git_repository_free(s.repo);
    s.repo = null;
}

fn isIgnored(s: @This(), path: [:0]const u8) !bool {
    // TODO configure libgit to include .git
    if (std.mem.startsWith(u8, path, ".git") and (path.len == 4 or path[4] == '/')) {
        return false;
    }
    var ignored: c_int = undefined;
    if (libgit2.git_ignore_path_is_ignored(&ignored, s.repo, path) < 0) {
        return error.InvalidIgnoreRules;
    }
    return switch (ignored) {
        0 => false,
        1 => true,
        else => unreachable,
    };
}

pub fn check(s: @This(), kind: std.fs.Dir.Entry.Kind, path: [:0]const u8) !common.Action {
    if (s.repo == null) return .include;

    const offset_path = path[s.dirname_len + 1 .. :0];

    return switch (kind) {
        // TODO make submodule exclusion configurable
        .directory => if (libgit2.git_submodule_lookup(null, s.repo, offset_path) >= 0) .exclude else .include,
        else => if (try isIgnored(s, offset_path)) .exclude else .include,
    };
}

pub fn free(s: *@This()) void {
    libgit2.git_repository_free(s.repo);
    s.* = undefined;
}
