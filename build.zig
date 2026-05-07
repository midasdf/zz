const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── zt embedded terminal: build a "zt" module out of the upstream sources
    //    via a WriteFiles staging dir, with our own render.zig stub and
    //    config build_options. zt's own build.zig is not modified.
    const zt_dep = b.dependency("zt", .{});

    const zt_opts = b.addOptions();
    zt_opts.addOption(bool, "use_x11", true);
    zt_opts.addOption(bool, "use_wayland", false);
    zt_opts.addOption(bool, "use_macos", false);
    zt_opts.addOption(u32, "scale", 1);
    zt_opts.addOption(bool, "use_jp_keymap", false);
    zt_opts.addOption(u32, "max_fps", 60);
    zt_opts.addOption(u32, "pty_buf_kb", 64);
    zt_opts.addOption(u32, "scrollback_lines", 10_000);
    zt_opts.addOption([:0]const u8, "shell", "/bin/sh");
    zt_opts.addOption([:0]const u8, "version", "embedded");

    const zt_config_mod = b.createModule(.{
        .root_source_file = zt_dep.path("config.zig"),
        .target = target,
        .optimize = optimize,
    });
    zt_config_mod.addImport("build_options", zt_opts.createModule());

    const zt_wf = b.addWriteFiles();
    _ = zt_wf.addCopyFile(zt_dep.path("src/term.zig"), "term.zig");
    _ = zt_wf.addCopyFile(zt_dep.path("src/vt.zig"), "vt.zig");
    _ = zt_wf.addCopyFile(zt_dep.path("src/pty.zig"), "pty.zig");
    _ = zt_wf.addCopyFile(zt_dep.path("src/posix.zig"), "posix.zig");
    _ = zt_wf.addCopyFile(zt_dep.path("src/scrollback.zig"), "scrollback.zig");
    _ = zt_wf.addCopyFile(zt_dep.path("src/input.zig"), "input.zig");

    // Stub render.zig — vt.zig only references render.palette[i] for SGR
    // 256-color underline color. Anything else (renderCell, font, etc.) is
    // never reached from term/vt/pty/scrollback/input.
    const render_stub = zt_wf.add("render.zig",
        \\pub const Color = struct { r: u8, g: u8, b: u8 };
        \\pub const palette: [256]Color = buildPalette();
        \\fn buildPalette() [256]Color {
        \\    var pal: [256]Color = undefined;
        \\    pal[0] = .{ .r = 0, .g = 0, .b = 0 };
        \\    pal[1] = .{ .r = 128, .g = 0, .b = 0 };
        \\    pal[2] = .{ .r = 0, .g = 128, .b = 0 };
        \\    pal[3] = .{ .r = 128, .g = 128, .b = 0 };
        \\    pal[4] = .{ .r = 0, .g = 0, .b = 128 };
        \\    pal[5] = .{ .r = 128, .g = 0, .b = 128 };
        \\    pal[6] = .{ .r = 0, .g = 128, .b = 128 };
        \\    pal[7] = .{ .r = 192, .g = 192, .b = 192 };
        \\    pal[8] = .{ .r = 128, .g = 128, .b = 128 };
        \\    pal[9] = .{ .r = 255, .g = 0, .b = 0 };
        \\    pal[10] = .{ .r = 0, .g = 255, .b = 0 };
        \\    pal[11] = .{ .r = 255, .g = 255, .b = 0 };
        \\    pal[12] = .{ .r = 0, .g = 0, .b = 255 };
        \\    pal[13] = .{ .r = 255, .g = 0, .b = 255 };
        \\    pal[14] = .{ .r = 0, .g = 255, .b = 255 };
        \\    pal[15] = .{ .r = 255, .g = 255, .b = 255 };
        \\    const cube = [6]u8{ 0, 95, 135, 175, 215, 255 };
        \\    for (16..232) |i| {
        \\        const idx = i - 16;
        \\        pal[i] = .{ .r = cube[idx / 36], .g = cube[(idx / 6) % 6], .b = cube[idx % 6] };
        \\    }
        \\    for (232..256) |i| {
        \\        const v: u8 = @intCast(8 + (i - 232) * 10);
        \\        pal[i] = .{ .r = v, .g = v, .b = v };
        \\    }
        \\    return pal;
        \\}
        \\
    );
    _ = render_stub;

    const zt_umbrella = zt_wf.add("lib.zig",
        \\pub const term = @import("term.zig");
        \\pub const vt = @import("vt.zig");
        \\pub const pty = @import("pty.zig");
        \\pub const input = @import("input.zig");
        \\pub const scrollback = @import("scrollback.zig");
        \\
    );

    const zt_mod = b.createModule(.{
        .root_source_file = zt_umbrella,
        .target = target,
        .optimize = optimize,
    });
    zt_mod.addImport("config", zt_config_mod);
    zt_mod.link_libc = true;

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
    exe_mod.addImport("zt", zt_mod);

    b.installArtifact(exe);

    // Tests — buffer (standalone, no C deps)
    const buffer_test_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/buffer.zig"),
        .target = target,
        .optimize = optimize,
    });
    buffer_test_mod.link_libc = true;
    const buffer_tests = b.addTest(.{ .root_module = buffer_test_mod });
    const run_buffer_tests = b.addRunArtifact(buffer_tests);

    // Tests — cursor (uses relative @import("buffer.zig"))
    const cursor_test_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/cursor.zig"),
        .target = target,
        .optimize = optimize,
    });
    cursor_test_mod.link_libc = true;
    const cursor_tests = b.addTest(.{ .root_module = cursor_test_mod });
    const run_cursor_tests = b.addRunArtifact(cursor_tests);

    // Tests — lsp client (standalone, no C deps)
    const lsp_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_test_mod.link_libc = true;
    const lsp_tests = b.addTest(.{ .root_module = lsp_test_mod });
    const run_lsp_tests = b.addRunArtifact(lsp_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_buffer_tests.step);
    test_step.dependOn(&run_cursor_tests.step);
    test_step.dependOn(&run_lsp_tests.step);
}
