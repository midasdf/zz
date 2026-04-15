const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable — all imports via relative paths from main.zig
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zz",
        .root_module = exe_mod,
    });

    exe_mod.linkSystemLibrary("xcb", .{});
    exe_mod.linkSystemLibrary("xcb-shm", .{});
    exe_mod.linkSystemLibrary("xcb-xkb", .{});
    exe_mod.linkSystemLibrary("xkbcommon", .{});
    exe_mod.linkSystemLibrary("xkbcommon-x11", .{});
    exe_mod.linkSystemLibrary("xcb-imdkit", .{});
    exe_mod.linkSystemLibrary("freetype2", .{});
    exe_mod.linkSystemLibrary("tree-sitter", .{});
    exe_mod.linkSystemLibrary("tree-sitter-c", .{});
    exe_mod.linkSystemLibrary("tree-sitter-python", .{});
    exe_mod.linkSystemLibrary("tree-sitter-rust", .{});
    exe_mod.linkSystemLibrary("tree-sitter-javascript", .{});
    exe_mod.linkSystemLibrary("tree-sitter-bash", .{});
    exe_mod.link_libc = true;

    b.installArtifact(exe);

    // Tests — buffer (standalone, no C deps)
    const buffer_test_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/buffer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const buffer_tests = b.addTest(.{ .root_module = buffer_test_mod });
    const run_buffer_tests = b.addRunArtifact(buffer_tests);

    // Tests — cursor (uses relative @import("buffer.zig"))
    const cursor_test_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/cursor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cursor_tests = b.addTest(.{ .root_module = cursor_test_mod });
    const run_cursor_tests = b.addRunArtifact(cursor_tests);

    // Tests — lsp client (standalone, no C deps)
    const lsp_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lsp_tests = b.addTest(.{ .root_module = lsp_test_mod });
    const run_lsp_tests = b.addRunArtifact(lsp_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_buffer_tests.step);
    test_step.dependOn(&run_cursor_tests.step);
    test_step.dependOn(&run_lsp_tests.step);
}
