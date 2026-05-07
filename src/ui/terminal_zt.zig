// zz/src/ui/terminal_zt.zig — Embedded terminal panel powered by zt.
// Owns zt.term.Term + zt.vt.Parser + zt.pty.Pty. Renders cells through zz's
// existing FreeType-based Renderer (no XEmbed, no external terminal binary).

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const render_mod = @import("render.zig");
const Renderer = render_mod.Renderer;
const Color = render_mod.Color;
const font_mod = @import("font.zig");
const FontFace = font_mod.FontFace;

const zt = @import("zt");
const Term = zt.term.Term;
const Cell = zt.term.Cell;
const Parser = zt.vt.Parser;
const feedBulk = zt.vt.feedBulk;
const Pty = zt.pty.Pty;

// xterm-256color palette (matches zt's render.zig palette exactly).
const PalColor = struct { r: u8, g: u8, b: u8 };
const palette: [256]PalColor = buildPalette();

fn buildPalette() [256]PalColor {
    var p: [256]PalColor = undefined;
    p[0] = .{ .r = 0, .g = 0, .b = 0 };
    p[1] = .{ .r = 128, .g = 0, .b = 0 };
    p[2] = .{ .r = 0, .g = 128, .b = 0 };
    p[3] = .{ .r = 128, .g = 128, .b = 0 };
    p[4] = .{ .r = 0, .g = 0, .b = 128 };
    p[5] = .{ .r = 128, .g = 0, .b = 128 };
    p[6] = .{ .r = 0, .g = 128, .b = 128 };
    p[7] = .{ .r = 192, .g = 192, .b = 192 };
    p[8] = .{ .r = 128, .g = 128, .b = 128 };
    p[9] = .{ .r = 255, .g = 0, .b = 0 };
    p[10] = .{ .r = 0, .g = 255, .b = 0 };
    p[11] = .{ .r = 255, .g = 255, .b = 0 };
    p[12] = .{ .r = 0, .g = 0, .b = 255 };
    p[13] = .{ .r = 255, .g = 0, .b = 255 };
    p[14] = .{ .r = 0, .g = 255, .b = 255 };
    p[15] = .{ .r = 255, .g = 255, .b = 255 };
    const cube = [6]u8{ 0, 95, 135, 175, 215, 255 };
    for (16..232) |i| {
        const idx = i - 16;
        p[i] = .{ .r = cube[idx / 36], .g = cube[(idx / 6) % 6], .b = cube[idx % 6] };
    }
    for (232..256) |i| {
        const v: u8 = @intCast(8 + (i - 232) * 10);
        p[i] = .{ .r = v, .g = v, .b = v };
    }
    return p;
}

inline fn pal(i: u8) Color {
    return .{ .r = palette[i].r, .g = palette[i].g, .b = palette[i].b };
}

pub const Terminal = struct {
    visible: bool = false,
    focused: bool = false,
    height_rows: u32 = 14,

    // Layout (pixels)
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    term: Term,
    parser: Parser = .{},
    pty: ?Pty = null,

    allocator: Allocator,

    pub fn init(allocator: Allocator) !Terminal {
        const term = try Term.init(allocator, 80, 14);
        return .{
            .term = term,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Terminal) void {
        if (self.pty) |*p| p.deinit();
        self.term.deinit();
    }

    pub fn toggle(self: *Terminal) void {
        if (self.visible) {
            self.hide();
        } else {
            self.show();
        }
    }

    pub fn show(self: *Terminal) void {
        self.visible = true;
        self.focused = true;
        self.ensureSpawned();
    }

    pub fn hide(self: *Terminal) void {
        self.visible = false;
        self.focused = false;
    }

    /// XEmbed leftover — no-op for the integrated terminal.
    pub fn setup(self: *Terminal, xcb_conn: *anyopaque, parent: u32) void {
        _ = self;
        _ = xcb_conn;
        _ = parent;
    }

    /// Spawn the shell as a child of the editor process via a fresh PTY.
    pub fn ensureSpawned(self: *Terminal) void {
        if (self.pty != null) return;
        const shell_z = getShellPathZ();
        const cols: u16 = @intCast(@max(self.term.cols, 1));
        const rows: u16 = @intCast(@max(self.term.rows, 1));
        const p = Pty.spawn(cols, rows, shell_z, null) catch return;
        self.pty = p;
    }

    pub fn setFocus(self: *Terminal) void {
        if (self.visible) self.focused = true;
    }

    pub fn unfocus(self: *Terminal) void {
        self.focused = false;
    }

    pub fn checkChild(self: *Terminal) void {
        // Pty.deinit handles full reaping. We poll non-blockingly here so that
        // a `exit` in the shell tears the panel down without leaking the PID.
        const p = self.pty orelse return;
        var status: c_int = 0;
        const rc = std.c.waitpid(p.child_pid, &status, 1); // WNOHANG
        if (rc == p.child_pid) {
            // Child exited; close fd and forget the Pty without re-killing.
            _ = std.c.close(p.master_fd);
            self.pty = null;
            self.visible = false;
            self.focused = false;
        }
    }

    pub fn getPtyFd(self: *const Terminal) ?posix.fd_t {
        if (!self.visible) return null;
        const p = self.pty orelse return null;
        return p.master_fd;
    }

    /// Drain everything readable from the PTY into the VT parser, then
    /// flush any pending VT responses (DA1/cursor reports/etc.) back to it.
    pub fn processOutput(self: *Terminal) void {
        var p = if (self.pty) |*pp| pp else return;
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = p.read(&buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => break,
            };
            if (n == 0) break;
            feedBulk(&self.parser, buf[0..n], &self.term, p.master_fd);
        }
        if (self.term.vt_response_len > 0) {
            const data = self.term.vt_response_buf[0..self.term.vt_response_len];
            _ = p.write(data) catch {};
            self.term.vt_response_len = 0;
        }
    }

    pub fn sendBytes(self: *Terminal, data: []const u8) void {
        var p = if (self.pty) |*pp| pp else return;
        _ = p.write(data) catch {};
    }

    /// X11 keysym → terminal escape sequence. Returns true if the keysym was
    /// handled (caller should stop propagating to the editor).
    pub fn handleKey(self: *Terminal, keysym: u32, ctrl: bool, shift: bool) bool {
        _ = shift;
        if (ctrl) {
            const k: u32 = if (keysym >= 'A' and keysym <= 'Z') keysym + 32 else keysym;
            if (k >= 'a' and k <= 'z') {
                const ch: [1]u8 = .{@intCast(k - 'a' + 1)};
                self.sendBytes(&ch);
                return true;
            }
            if (k == '[') { self.sendBytes("\x1b"); return true; }
            if (k == '\\') { self.sendBytes("\x1c"); return true; }
            if (k == ']') { self.sendBytes("\x1d"); return true; }
            return false;
        }

        const decckm = self.term.decckm;
        const XK_Return: u32 = 0xFF0D;
        const XK_BackSpace: u32 = 0xFF08;
        const XK_Tab: u32 = 0xFF09;
        const XK_Escape: u32 = 0xFF1B;
        const XK_Up: u32 = 0xFF52;
        const XK_Down: u32 = 0xFF54;
        const XK_Right: u32 = 0xFF53;
        const XK_Left: u32 = 0xFF51;
        const XK_Home: u32 = 0xFF50;
        const XK_End: u32 = 0xFF57;
        const XK_Insert: u32 = 0xFF63;
        const XK_Delete: u32 = 0xFFFF;
        const XK_Page_Up: u32 = 0xFF55;
        const XK_Page_Down: u32 = 0xFF56;

        switch (keysym) {
            XK_Return => self.sendBytes("\r"),
            XK_BackSpace => self.sendBytes("\x7f"),
            XK_Tab => self.sendBytes("\t"),
            XK_Escape => self.sendBytes("\x1b"),
            XK_Up => self.sendBytes(if (decckm) "\x1bOA" else "\x1b[A"),
            XK_Down => self.sendBytes(if (decckm) "\x1bOB" else "\x1b[B"),
            XK_Right => self.sendBytes(if (decckm) "\x1bOC" else "\x1b[C"),
            XK_Left => self.sendBytes(if (decckm) "\x1bOD" else "\x1b[D"),
            XK_Home => self.sendBytes(if (decckm) "\x1bOH" else "\x1b[H"),
            XK_End => self.sendBytes(if (decckm) "\x1bOF" else "\x1b[F"),
            XK_Insert => self.sendBytes("\x1b[2~"),
            XK_Delete => self.sendBytes("\x1b[3~"),
            XK_Page_Up => self.sendBytes("\x1b[5~"),
            XK_Page_Down => self.sendBytes("\x1b[6~"),
            else => return false,
        }
        return true;
    }

    pub fn updateLayout(self: *Terminal, x: u32, y: u32, width: u32, height: u32, font: *const FontFace) void {
        self.x = x;
        self.y = y;
        self.width = width;
        self.height = height;

        const usable_h = if (height > 2) height - 2 else 1;
        const new_cols: u32 = @max(width / font.cell_width, 1);
        const new_rows: u32 = @max(usable_h / font.cell_height, 1);

        if (new_cols != self.term.cols or new_rows != self.term.rows) {
            self.term.resize(new_cols, new_rows) catch return;
            self.height_rows = new_rows;
            if (self.pty) |*p| {
                p.resize(@intCast(new_cols), @intCast(new_rows)) catch {};
            }
        }
    }

    pub fn pixelHeight(self: *const Terminal, font: *const FontFace) u32 {
        if (!self.visible) return 0;
        return self.height_rows * font.cell_height + 2; // +2 for separator
    }

    pub fn render(self: *const Terminal, renderer: *Renderer, font: *FontFace) void {
        if (!self.visible) return;

        const bg_default = Color.fromHex(0x1e1e2e);
        const separator_color = Color.fromHex(0x585b70);

        renderer.fillRect(self.x, self.y, self.width, 2, separator_color);
        renderer.fillRect(self.x, self.y + 2, self.width, self.height -| 2, bg_default);

        const base_y = self.y + 2;
        const cols = self.term.cols;
        const rows = self.term.rows;
        const safe_ascent: u32 = if (font.ascent >= 0) @intCast(font.ascent) else 0;

        var ry: u32 = 0;
        while (ry < rows) : (ry += 1) {
            const phys_row: usize = @as(usize, self.term.row_map[ry]) * @as(usize, cols);
            var rx: u32 = 0;
            while (rx < cols) : (rx += 1) {
                const cell = self.term.getCell(rx, ry).*;
                if (cell.attrs.wide_dummy) continue; // right half of wide glyph

                const idx = phys_row + @as(usize, rx);
                var fg_c: Color = if (self.term.fg_rgb[idx]) |rgb|
                    .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] }
                else blk: {
                    var fi = cell.fg;
                    if (cell.attrs.bold and fi < 8) fi += 8; // brighten
                    break :blk pal(fi);
                };
                var bg_c: Color = if (self.term.bg_rgb[idx]) |rgb|
                    .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] }
                else
                    pal(cell.bg);

                if (cell.attrs.reverse) {
                    const tmp = fg_c;
                    fg_c = bg_c;
                    bg_c = tmp;
                }
                if (cell.attrs.dim) {
                    fg_c.r /= 2;
                    fg_c.g /= 2;
                    fg_c.b /= 2;
                }

                const cw: u32 = if (cell.attrs.wide) font.cell_width * 2 else font.cell_width;
                const cx = self.x + rx * font.cell_width;
                const cy = base_y + ry * font.cell_height;

                const has_explicit_bg = cell.bg != 0 or cell.attrs.reverse or self.term.bg_rgb[idx] != null;
                if (has_explicit_bg) {
                    renderer.fillRect(cx, cy, cw, font.cell_height, bg_c);
                }

                if (cell.char > ' ') {
                    if (font.getGlyph(@intCast(cell.char))) |g| {
                        const gx = @as(i32, @intCast(cx)) + g.bearing_x;
                        const gy = @as(i32, @intCast(cy)) + font.ascent - g.bearing_y;
                        renderer.drawGlyph(g, gx, gy, fg_c);
                    } else |_| {}
                }

                if (cell.attrs.underline_style != 0) {
                    const uy = cy + safe_ascent + 1;
                    renderer.fillRect(cx, uy, cw, 1, fg_c);
                }
                if (cell.attrs.strikethrough) {
                    const sy = cy + safe_ascent / 2;
                    renderer.fillRect(cx, sy, cw, 1, fg_c);
                }
            }
        }

        if (self.term.cursor_visible and self.focused) {
            const cur_x = self.x + self.term.cursor_x * font.cell_width;
            const cur_y = base_y + self.term.cursor_y * font.cell_height;
            const cursor_color = Color.fromHex(0xcdd6f4);
            renderer.fillRect(cur_x, cur_y, 2, font.cell_height, cursor_color);
        }
    }

    pub fn containsPoint(self: *const Terminal, px: i32, py: i32) bool {
        if (!self.visible) return false;
        return px >= @as(i32, @intCast(self.x)) and
            px < @as(i32, @intCast(self.x + self.width)) and
            py >= @as(i32, @intCast(self.y)) and
            py < @as(i32, @intCast(self.y + self.height));
    }
};

/// Resolve $SHELL → a null-terminated path, falling back to /bin/sh.
fn getShellPathZ() [*:0]const u8 {
    const shell_env = std.c.getenv("SHELL");
    if (shell_env) |p| return p;
    return "/bin/sh";
}
