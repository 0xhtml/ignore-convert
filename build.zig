const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "ignore-convert",
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.linkSystemLibrary("libgit2");
    exe.linkSystemLibrary("python3.13");
    exe.linkLibC();
    b.installArtifact(exe);
}
