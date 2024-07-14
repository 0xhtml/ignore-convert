const std = @import("std");
const python = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", "");
    @cInclude("python3.12/Python.h");
});

const Patterns = struct {
    obj: *python.PyObject,

    const PatternMatcher = struct {
        obj: *python.PyObject,

        fn deinit(s: @This()) void {
            python.Py_DECREF(s.obj);
        }

        fn addInclexcl(s: @This(), patterns: *python.PyObject) !void {
            if (python.PyObject_CallMethod(s.obj, "add_inclexcl", "O", patterns) != python.Py_None()) return error.PythonError;
        }

        fn match(s: @This(), path: []const u8) !bool {
            const result = python.PyObject_CallMethod(s.obj, "match", "s#", path.ptr, path.len) orelse return error.PythonError;
            defer python.Py_DECREF(result);
            return switch (python.PyLong_AsLong(result)) {
                0 => true,
                1 => false,
                else => error.PythonError,
            };
        }
    };

    fn init() !@This() {
        return .{
            .obj = python.PyImport_ImportModule("borg.patterns") orelse return error.PythonError,
        };
    }

    fn deinit(s: @This()) void {
        python.Py_DECREF(s.obj);
    }

    fn loadExcludeFile(s: @This(), file: std.fs.File) !*python.PyObject {
        const py_file = python.PyFile_FromFd(file.handle, "", "r", -1, null, null, null, 0) orelse return error.PythonError;
        defer python.Py_DECREF(py_file);

        const patterns = python.PyList_New(0) orelse return error.PythonError;

        if (python.PyObject_CallMethod(s.obj, "load_exclude_file", "OO", py_file, patterns) != python.Py_None()) return error.PythonError;

        return patterns;
    }

    fn patternMatcher(s: @This()) !PatternMatcher {
        return .{
            .obj = python.PyObject_CallMethod(s.obj, "PatternMatcher", "i", @as(c_int, 1)) orelse return error.PythonError,
        };
    }
};

pub const State = struct {
    matcher: Patterns.PatternMatcher,

    pub fn init(file: std.fs.File) !@This() {
        // TODO move to more global state
        const patterns = try Patterns.init();
        defer patterns.deinit();

        const list = try patterns.loadExcludeFile(file);
        const matcher = try patterns.patternMatcher();
        try matcher.addInclexcl(list);

        return .{
            .matcher = matcher,
        };
    }

    pub fn deinit(s: *@This()) void {
        s.matcher.deinit();
        s.* = undefined;
    }

    pub fn skip(s: @This(), path: []const u8) !bool {
        return s.matcher.match(path);
    }
};

pub fn init() void {
    python.Py_Initialize();
}

pub fn deinit() void {
    python.Py_Finalize();
}
