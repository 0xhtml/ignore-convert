const std = @import("std");
const libgit2 = @cImport({
    @cInclude("git2.h");
    @cInclude("git2/sys/repository.h");
});

pub const State = struct {
    repo: ?*libgit2.git_repository,
    offset: usize,
    owner: bool,

    pub fn init() @This() {
        return .{ .repo = null, .offset = 0, .owner = false };
    }

    pub fn update(s: @This(), path: [*:0]u8, kind: std.fs.Dir.Entry.Kind) !@This() {
        if (s.repo != null or kind != .directory) {
            return .{ .repo = s.repo, .offset = s.offset, .owner = false};
        }

        var repo: ?*libgit2.git_repository = null;
        _ = libgit2.git_repository_open(&repo, path);
        if (repo) |_| {
            _ = libgit2.git_repository_submodule_cache_all(repo);
        }
        return .{ .repo = repo, .offset = 0, .owner = true };
    }

    pub fn skip(s: @This(), path: [*:0]u8, kind: std.fs.Dir.Entry.Kind) !bool {
        if (s.repo != null) {
            const offset_path = path[s.offset..];

            if (kind == .directory and libgit2.git_submodule_lookup(null, s.repo, offset_path) >= 0) {
                return true;
            }

            var ignored: c_int = undefined;
            if (libgit2.git_ignore_path_is_ignored(&ignored, s.repo, offset_path) < 0) {
                return error.InvalidIgnoreRules;
            }
            return switch (ignored) {
                0 => false,
                1 => true,
                else => unreachable,
            };
        }

        return false;
    }

    pub fn free(s: *@This()) void {
        if (s.repo != null and s.owner) libgit2.git_repository_free(s.repo);
        s.* = undefined;
    }
};

pub fn init() !void {
    if (libgit2.git_libgit2_init() < 0) return error.ErrorInitializingLibgit2;
}

pub fn deinit() !void {
    if (libgit2.git_libgit2_shutdown() < 0) return error.ErrorDeinitializingLibgit2;
}
