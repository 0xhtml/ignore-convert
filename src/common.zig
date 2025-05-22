const std = @import("std");

pub const Action = enum {
    include,
    exclude,
};

pub const Filter = struct {
    ptr: *anyopaque,
    enterFn: ?*const fn (ptr: *anyopaque, level: usize, path: [:0]const u8) void,
    leaveFn: ?*const fn (ptr: *anyopaque, level: usize) void,
    checkFn: *const fn (ptr: *anyopaque, kind: std.fs.Dir.Entry.Kind, path: [:0]const u8) error{ PythonError, InvalidIgnoreRules }!Action,
    includeEmptyFn: ?*const fn (ptr: *anyopaque) bool,
    freeFn: *const fn (ptr: *anyopaque) void,

    pub fn enter(s: *const @This(), level: usize, path: [:0]const u8) void {
        if (s.enterFn) |f| f(s.ptr, level, path);
    }

    pub fn leave(s: *const @This(), level: usize) void {
        if (s.leaveFn) |f| f(s.ptr, level);
    }

    pub fn check(s: *const @This(), kind: std.fs.Dir.Entry.Kind, path: [:0]const u8) !Action {
        return s.checkFn(s.ptr, kind, path);
    }

    pub fn includeEmpty(s: *const @This()) bool {
        return if (s.includeEmptyFn) |f| f(s.ptr) else true;
    }

    pub fn free(s: *const @This()) void {
        s.freeFn(s.ptr);
    }
};
