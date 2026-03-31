const std = @import("std");
const Window = @import("ui/window.zig").Window;
const FontFace = @import("ui/font.zig").FontFace;
const render_mod = @import("ui/render.zig");
const Renderer = render_mod.Renderer;
const Color = render_mod.Color;

const font_path = "/usr/share/fonts/PlemolJP/PlemolJPConsoleNF-Regular.ttf";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Init window
    var win = try Window.init(allocator, 800, 600, "zz");
    defer win.deinit();

    // Init font
    var font = try FontFace.init(allocator, font_path, 16);
    defer font.deinit();

    const bg = Color.fromHex(0x1e1e2e);
    const fg = Color.fromHex(0xcdd6f4);

    // Initial render
    {
        var renderer = Renderer{
            .buffer = win.getBuffer(),
            .stride = win.stride,
            .width = win.width,
            .height = win.height,
        };

        // Fill background
        renderer.fillRect(0, 0, win.width, win.height, bg);

        // Render text
        const lines = [_][]const u8{
            "zz editor v0.1.0",
            "",
            "Phase 1: Minimal Editor",
            "  xcb + SHM + freetype",
            "",
            "Press any key or close window.",
        };

        for (lines, 0..) |line, row| {
            for (line, 0..) |ch, col| {
                renderer.drawCell(&font, ch, @intCast(col), @intCast(row), fg, bg, 8);
            }
        }
    }

    win.markAllDirty();
    win.present();

    // Event loop
    const Window_mod = @import("ui/window.zig");
    while (true) {
        if (win.pollEvent()) |event| {
            switch (event) {
                .close => break,
                .expose => {
                    win.markAllDirty();
                    win.present();
                },
                .key_press => |ke| {
                    if (ke.keysym == Window_mod.XK_Escape) break;
                },
                .text_input => |te| {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, te.slice()) catch {};
                },
                .paste => |pe| {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, pe.data) catch {};
                    pe.deinit();
                },
                else => {},
            }
        }
    }
}
