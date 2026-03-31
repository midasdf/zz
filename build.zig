const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Buffer module (shared between exe and tests)
    const buffer_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/buffer.zig"),
    });

    // Cursor module (depends on buffer)
    const cursor_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/cursor.zig"),
        .imports = &.{
            .{ .name = "buffer", .module = buffer_mod },
        },
    });

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "cursor", .module = cursor_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zz",
        .root_module = exe_mod,
    });

    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("xcb-shm");
    exe.linkSystemLibrary("xcb-xkb");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("xkbcommon-x11");
    exe.linkSystemLibrary("xcb-imdkit");
    exe.linkSystemLibrary("freetype2");
    exe.linkLibC();

    b.installArtifact(exe);

    // Tests — buffer
    const buffer_test_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/buffer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const buffer_tests = b.addTest(.{ .root_module = buffer_test_mod });
    const run_buffer_tests = b.addRunArtifact(buffer_tests);

    // Tests — cursor
    const cursor_test_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/cursor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "buffer", .module = buffer_mod },
        },
    });
    const cursor_tests = b.addTest(.{ .root_module = cursor_test_mod });
    const run_cursor_tests = b.addRunArtifact(cursor_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_buffer_tests.step);
    test_step.dependOn(&run_cursor_tests.step);
}
