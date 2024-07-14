const std = @import("std");
const common = @import("common.zig");
const libgit2 = @cImport({
    @cInclude("git2.h");
    @cInclude("git2/sys/repository.h");
});

pub const State = struct {
    repo: ?struct {
        ptr: *libgit2.git_repository,
        path: []const u8,
    },

    pub fn init() @This() {
        return .{ .repo = null };
    }

    pub fn update(s: *const @This(), allocator: std.mem.Allocator, dir: std.fs.Dir, entry: std.fs.Dir.Entry) !@This() {
        if (s.repo) |_repo| {
            return .{
                .repo = .{
                    .ptr = _repo.ptr,
                    .path = try common.concatPath(allocator, _repo.path, entry.name),
                },
            };
        }

        if (entry.kind != .directory) return .{ .repo = null };

        // TODO: replace with base_path ++ path if more performant
        // TODO: or just save the prefix that has to be removed
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const path = try std.posix.toPosixPath(try dir.realpath(entry.name, buf[0..]));

        var ptr: ?*libgit2.git_repository = null;
        _ = libgit2.git_repository_open(&ptr, &path);
        if (ptr) |_ptr| {
            _ = libgit2.git_repository_submodule_cache_all(_ptr);
            return .{
                .repo = .{
                    .ptr = _ptr,
                    .path = "",
                },
            };
        }

        return .{ .repo = null };
    }

    pub fn skip(s: *const @This(), kind: std.fs.Dir.Entry.Kind) !bool {
        if (s.repo) |_repo| {
            const c_path = try std.posix.toPosixPath(_repo.path);

            if (kind == .directory and libgit2.git_submodule_lookup(null, _repo.ptr, &c_path) >= 0) {
                return true;
            }

            var ignored: c_int = undefined;
            if (libgit2.git_ignore_path_is_ignored(&ignored, _repo.ptr, &c_path) < 0) {
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

    pub fn free(s: *@This(), allocator: std.mem.Allocator) void {
        if (s.repo) |_repo| {
            if (_repo.path.len == 0) {
                libgit2.git_repository_free(_repo.ptr);
            } else {
                allocator.free(_repo.path);
            }
        }
        s.* = undefined;
    }
};

pub fn init() !void {
    if (libgit2.git_libgit2_init() < 0) return error.ErrorInitializingLibgit2;
}

pub fn deinit() !void {
    if (libgit2.git_libgit2_shutdown() < 0) return error.ErrorDeinitializingLibgit2;
}
