// zz/src/ui/terminal.zig — Embedded terminal panel using zt's PTY/VT/Term core
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const render_mod = @import("render.zig");
const Renderer = render_mod.Renderer;
const Color = render_mod.Color;
const font_mod = @import("font.zig");
const FontFace = font_mod.FontFace;

// ── Terminal Cell ──────────────────────────────────────────────────

const Cell = struct {
    char: u21 = ' ',
    fg: u8 = 7,
    bg: u8 = 0,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
};

// ── xterm-256 Color Palette ────────────────────────────────────────

const PalColor = struct { r: u8, g: u8, b: u8 };

const palette: [256]PalColor = buildPalette();

fn buildPalette() [256]PalColor {
    var pal: [256]PalColor = undefined;
    // 0-7: standard
    pal[0] = .{ .r = 0, .g = 0, .b = 0 };
    pal[1] = .{ .r = 128, .g = 0, .b = 0 };
    pal[2] = .{ .r = 0, .g = 128, .b = 0 };
    pal[3] = .{ .r = 128, .g = 128, .b = 0 };
    pal[4] = .{ .r = 0, .g = 0, .b = 128 };
    pal[5] = .{ .r = 128, .g = 0, .b = 128 };
    pal[6] = .{ .r = 0, .g = 128, .b = 128 };
    pal[7] = .{ .r = 192, .g = 192, .b = 192 };
    // 8-15: bright
    pal[8] = .{ .r = 128, .g = 128, .b = 128 };
    pal[9] = .{ .r = 255, .g = 0, .b = 0 };
    pal[10] = .{ .r = 0, .g = 255, .b = 0 };
    pal[11] = .{ .r = 255, .g = 255, .b = 0 };
    pal[12] = .{ .r = 0, .g = 0, .b = 255 };
    pal[13] = .{ .r = 255, .g = 0, .b = 255 };
    pal[14] = .{ .r = 0, .g = 255, .b = 255 };
    pal[15] = .{ .r = 255, .g = 255, .b = 255 };
    // 16-231: 6x6x6 color cube
    const cube = [6]u8{ 0, 95, 135, 175, 215, 255 };
    for (16..232) |i| {
        const idx = i - 16;
        pal[i] = .{ .r = cube[idx / 36], .g = cube[(idx / 6) % 6], .b = cube[idx % 6] };
    }
    // 232-255: grayscale
    for (232..256) |i| {
        const v: u8 = @intCast(8 + (i - 232) * 10);
        pal[i] = .{ .r = v, .g = v, .b = v };
    }
    return pal;
}

fn palToColor(p: PalColor) Color {
    return .{ .r = p.r, .g = p.g, .b = p.b };
}

// ── VT Parser ──────────────────────────────────────────────────────

const VtState = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
    utf8,
};

const VtParser = struct {
    state: VtState = .ground,
    // CSI accumulators
    params: [16]u16 = [_]u16{0} ** 16,
    param_count: u8 = 0,
    intermediates: [2]u8 = [_]u8{0} ** 2,
    intermediate_count: u8 = 0,
    private_marker: u8 = 0,
    // UTF-8
    utf8_buf: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_expected: u3 = 0,
    // OSC
    osc_buf: [256]u8 = undefined,
    osc_len: u16 = 0,
    esc_in_osc: bool = false,

    const VtAction = union(enum) {
        print: u21,
        execute: u8,
        csi: CsiData,
        esc: EscData,
        osc: []const u8,
        none,
    };

    const CsiData = struct {
        params: [16]u16 = [_]u16{0} ** 16,
        param_count: u8 = 0,
        intermediates: [2]u8 = [_]u8{0} ** 2,
        intermediate_count: u8 = 0,
        final_byte: u8 = 0,
        private_marker: u8 = 0,
    };

    const EscData = struct {
        intermediate: u8 = 0,
        final_byte: u8 = 0,
    };

    fn feed(self: *VtParser, byte: u8) VtAction {
        return switch (self.state) {
            .ground => self.handleGround(byte),
            .utf8 => self.handleUtf8(byte),
            .escape => self.handleEscape(byte),
            .escape_intermediate => self.handleEscapeIntermediate(byte),
            .csi_entry => self.handleCsiEntry(byte),
            .csi_param => self.handleCsiParam(byte),
            .csi_intermediate => self.handleCsiIntermediate(byte),
            .csi_ignore => self.handleCsiIgnore(byte),
            .osc_string => self.handleOscString(byte),
        };
    }

    fn handleGround(self: *VtParser, byte: u8) VtAction {
        if (byte <= 0x1F) {
            if (byte == 0x1B) {
                self.state = .escape;
                return .none;
            }
            return .{ .execute = byte };
        } else if (byte <= 0x7E) {
            return .{ .print = @as(u21, byte) };
        } else if (byte >= 0xC0 and byte <= 0xDF) {
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 2;
            self.state = .utf8;
            return .none;
        } else if (byte >= 0xE0 and byte <= 0xEF) {
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 3;
            self.state = .utf8;
            return .none;
        } else if (byte >= 0xF0 and byte <= 0xF7) {
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 4;
            self.state = .utf8;
            return .none;
        }
        return .none;
    }

    fn handleUtf8(self: *VtParser, byte: u8) VtAction {
        if (byte >= 0x80 and byte <= 0xBF) {
            self.utf8_buf[self.utf8_len] = byte;
            self.utf8_len += 1;
            if (self.utf8_len == self.utf8_expected) {
                const cp = decodeUtf8(self.utf8_buf[0..self.utf8_len]);
                self.state = .ground;
                return .{ .print = cp };
            }
            return .none;
        }
        self.state = .ground;
        const a = self.handleGround(byte);
        return switch (a) {
            .none => .{ .print = 0xFFFD },
            else => a,
        };
    }

    fn decodeUtf8(bytes: []const u8) u21 {
        return switch (bytes.len) {
            2 => (@as(u21, bytes[0] & 0x1F) << 6) | @as(u21, bytes[1] & 0x3F),
            3 => (@as(u21, bytes[0] & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | @as(u21, bytes[2] & 0x3F),
            4 => (@as(u21, bytes[0] & 0x07) << 18) | (@as(u21, bytes[1] & 0x3F) << 12) | (@as(u21, bytes[2] & 0x3F) << 6) | @as(u21, bytes[3] & 0x3F),
            else => 0xFFFD,
        };
    }

    fn handleEscape(self: *VtParser, byte: u8) VtAction {
        if (byte == '[') {
            self.clearCsi();
            self.state = .csi_entry;
            return .none;
        } else if (byte == ']') {
            self.osc_len = 0;
            self.esc_in_osc = false;
            self.state = .osc_string;
            return .none;
        } else if (byte >= 0x20 and byte <= 0x2F) {
            self.intermediates[0] = byte;
            self.intermediate_count = 1;
            self.state = .escape_intermediate;
            return .none;
        } else if (byte >= 0x30 and byte <= 0x7E) {
            self.state = .ground;
            return .{ .esc = .{ .intermediate = 0, .final_byte = byte } };
        } else if (byte == 0x1B) {
            return .none;
        }
        self.state = .ground;
        return .none;
    }

    fn handleEscapeIntermediate(self: *VtParser, byte: u8) VtAction {
        if (byte >= 0x20 and byte <= 0x2F) {
            if (self.intermediate_count < 2) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            return .none;
        } else if (byte >= 0x30 and byte <= 0x7E) {
            self.state = .ground;
            return .{ .esc = .{ .intermediate = self.intermediates[0], .final_byte = byte } };
        }
        self.state = .ground;
        return .none;
    }

    fn handleCsiEntry(self: *VtParser, byte: u8) VtAction {
        if (byte >= 0x3C and byte <= 0x3F) {
            self.private_marker = byte;
            self.state = .csi_param;
            return .none;
        } else if (byte >= '0' and byte <= '9') {
            self.params[0] = byte - '0';
            self.state = .csi_param;
            return .none;
        } else if (byte == ';') {
            self.param_count = 1;
            self.state = .csi_param;
            return .none;
        } else if (byte >= 0x40 and byte <= 0x7E) {
            self.state = .ground;
            return .{ .csi = self.buildCsi(byte) };
        } else if (byte >= 0x20 and byte <= 0x2F) {
            self.intermediates[0] = byte;
            self.intermediate_count = 1;
            self.state = .csi_intermediate;
            return .none;
        }
        return .none;
    }

    fn handleCsiParam(self: *VtParser, byte: u8) VtAction {
        if (byte >= '0' and byte <= '9') {
            const idx = self.param_count;
            if (idx < 16) {
                self.params[idx] = self.params[idx] *| 10 +| (byte - '0');
            }
            return .none;
        } else if (byte == ':') {
            // Sub-parameter -- skip digits
            return .none;
        } else if (byte == ';') {
            if (self.param_count < 15) self.param_count += 1;
            return .none;
        } else if (byte >= 0x20 and byte <= 0x2F) {
            self.intermediates[0] = byte;
            self.intermediate_count = 1;
            self.state = .csi_intermediate;
            return .none;
        } else if (byte >= 0x40 and byte <= 0x7E) {
            self.param_count += 1;
            self.state = .ground;
            return .{ .csi = self.buildCsi(byte) };
        } else if (byte >= 0x3C and byte <= 0x3F) {
            self.state = .csi_ignore;
            return .none;
        }
        return .none;
    }

    fn handleCsiIntermediate(self: *VtParser, byte: u8) VtAction {
        if (byte >= 0x20 and byte <= 0x2F) {
            if (self.intermediate_count < 2) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            return .none;
        } else if (byte >= 0x40 and byte <= 0x7E) {
            self.state = .ground;
            return .{ .csi = self.buildCsi(byte) };
        }
        self.state = .csi_ignore;
        return .none;
    }

    fn handleCsiIgnore(self: *VtParser, byte: u8) VtAction {
        if (byte >= 0x40 and byte <= 0x7E) self.state = .ground;
        return .none;
    }

    fn handleOscString(self: *VtParser, byte: u8) VtAction {
        if (self.esc_in_osc) {
            self.esc_in_osc = false;
            if (byte == '\\') {
                self.state = .ground;
                return .{ .osc = self.osc_buf[0..self.osc_len] };
            }
            if (self.osc_len < 256) { self.osc_buf[self.osc_len] = 0x1B; self.osc_len += 1; }
            if (self.osc_len < 256) { self.osc_buf[self.osc_len] = byte; self.osc_len += 1; }
            return .none;
        }
        if (byte == 0x07) {
            self.state = .ground;
            return .{ .osc = self.osc_buf[0..self.osc_len] };
        } else if (byte == 0x9C) {
            self.state = .ground;
            return .{ .osc = self.osc_buf[0..self.osc_len] };
        } else if (byte == 0x1B) {
            self.esc_in_osc = true;
            return .none;
        }
        if (self.osc_len < 256) { self.osc_buf[self.osc_len] = byte; self.osc_len += 1; }
        return .none;
    }

    fn clearCsi(self: *VtParser) void {
        self.params = [_]u16{0} ** 16;
        self.param_count = 0;
        self.intermediates = [_]u8{0} ** 2;
        self.intermediate_count = 0;
        self.private_marker = 0;
    }

    fn buildCsi(self: *const VtParser, final_byte: u8) CsiData {
        return .{
            .params = self.params,
            .param_count = self.param_count,
            .intermediates = self.intermediates,
            .intermediate_count = self.intermediate_count,
            .final_byte = final_byte,
            .private_marker = self.private_marker,
        };
    }
};

// ── Terminal Grid ──────────────────────────────────────────────────

const TermGrid = struct {
    allocator: Allocator,
    cols: u32,
    rows: u32,
    cells: []Cell,
    // Cursor
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    // Scroll region
    scroll_top: u32 = 0,
    scroll_bottom: u32 = 0,
    // Current drawing attributes
    cur_fg: u8 = 7,
    cur_bg: u8 = 0,
    cur_bold: bool = false,
    cur_dim: bool = false,
    cur_italic: bool = false,
    cur_underline: bool = false,
    cur_reverse: bool = false,
    cur_strikethrough: bool = false,
    // TrueColor overrides (per-cell)
    fg_rgb: []?[3]u8,
    bg_rgb: []?[3]u8,
    cur_fg_rgb: ?[3]u8 = null,
    cur_bg_rgb: ?[3]u8 = null,
    // Auto-wrap
    decawm: bool = true,
    wrap_next: bool = false,
    // Cursor visibility
    cursor_visible: bool = true,
    // Bracketed paste mode
    bracketed_paste: bool = false,
    // DEC application cursor keys
    decckm: bool = false,
    // Alternate screen
    alt_cells: ?[]Cell = null,
    alt_fg_rgb: ?[]?[3]u8 = null,
    alt_bg_rgb: ?[]?[3]u8 = null,
    is_alt_screen: bool = false,
    // Insert mode
    insert_mode: bool = false,

    fn init(allocator: Allocator, cols: u32, rows: u32) !TermGrid {
        const total = @as(usize, cols) * @as(usize, rows);
        const cells = try allocator.alloc(Cell, total);
        @memset(cells, Cell{});
        const fg_rgb = try allocator.alloc(?[3]u8, total);
        @memset(fg_rgb, null);
        const bg_rgb = try allocator.alloc(?[3]u8, total);
        @memset(bg_rgb, null);
        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .scroll_bottom = rows -| 1,
            .fg_rgb = fg_rgb,
            .bg_rgb = bg_rgb,
        };
    }

    fn deinit(self: *TermGrid) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.fg_rgb);
        self.allocator.free(self.bg_rgb);
        if (self.alt_cells) |ac| self.allocator.free(ac);
        if (self.alt_fg_rgb) |af| self.allocator.free(af);
        if (self.alt_bg_rgb) |ab| self.allocator.free(ab);
    }

    fn idx(self: *const TermGrid, x: u32, y: u32) usize {
        return @as(usize, y) * @as(usize, self.cols) + @as(usize, x);
    }

    fn getCell(self: *const TermGrid, x: u32, y: u32) Cell {
        if (x >= self.cols or y >= self.rows) return .{};
        return self.cells[self.idx(x, y)];
    }

    fn setCell(self: *TermGrid, x: u32, y: u32, cell: Cell) void {
        if (x >= self.cols or y >= self.rows) return;
        const i = self.idx(x, y);
        self.cells[i] = cell;
    }

    fn putChar(self: *TermGrid, cp: u21) void {
        if (self.wrap_next) {
            if (self.decawm) {
                self.cursor_x = 0;
                self.newline();
            }
            self.wrap_next = false;
        }
        if (self.insert_mode) {
            // Shift cells right
            const y = self.cursor_y;
            const x = self.cursor_x;
            const end = self.cols - 1;
            var sx = end;
            while (sx > x) : (sx -= 1) {
                const di = self.idx(sx, y);
                const si = self.idx(sx - 1, y);
                self.cells[di] = self.cells[si];
                self.fg_rgb[di] = self.fg_rgb[si];
                self.bg_rgb[di] = self.bg_rgb[si];
            }
        }
        const i = self.idx(self.cursor_x, self.cursor_y);
        self.cells[i] = .{
            .char = cp,
            .fg = self.cur_fg,
            .bg = self.cur_bg,
            .bold = self.cur_bold,
            .dim = self.cur_dim,
            .italic = self.cur_italic,
            .underline = self.cur_underline,
            .reverse = self.cur_reverse,
            .strikethrough = self.cur_strikethrough,
        };
        self.fg_rgb[i] = self.cur_fg_rgb;
        self.bg_rgb[i] = self.cur_bg_rgb;
        if (self.cursor_x + 1 < self.cols) {
            self.cursor_x += 1;
        } else {
            self.wrap_next = true;
        }
    }

    fn newline(self: *TermGrid) void {
        if (self.cursor_y == self.scroll_bottom) {
            self.scrollUp(1);
        } else if (self.cursor_y < self.rows - 1) {
            self.cursor_y += 1;
        }
    }

    fn scrollUp(self: *TermGrid, n: u32) void {
        if (n == 0) return;
        const cols: usize = self.cols;
        const top: usize = self.scroll_top;
        const bot: usize = self.scroll_bottom;
        const region = bot - top + 1;
        const shift: usize = @min(n, @as(u32, @intCast(region)));
        // Move rows up
        for (top..bot + 1 - shift) |y| {
            const dst = y * cols;
            const src = (y + shift) * cols;
            @memcpy(self.cells[dst .. dst + cols], self.cells[src .. src + cols]);
            @memcpy(self.fg_rgb[dst .. dst + cols], self.fg_rgb[src .. src + cols]);
            @memcpy(self.bg_rgb[dst .. dst + cols], self.bg_rgb[src .. src + cols]);
        }
        // Clear bottom rows
        for (bot + 1 - shift..bot + 1) |y| {
            const start = y * cols;
            @memset(self.cells[start .. start + cols], Cell{});
            @memset(self.fg_rgb[start .. start + cols], null);
            @memset(self.bg_rgb[start .. start + cols], null);
        }
    }

    fn scrollDown(self: *TermGrid, n: u32) void {
        if (n == 0) return;
        const cols: usize = self.cols;
        const top: usize = self.scroll_top;
        const bot: usize = self.scroll_bottom;
        const region = bot - top + 1;
        const shift: usize = @min(n, @as(u32, @intCast(region)));
        // Move rows down (from bottom)
        var y_idx: usize = bot;
        while (y_idx >= top + shift) : (y_idx -= 1) {
            const dst = y_idx * cols;
            const src = (y_idx - shift) * cols;
            @memcpy(self.cells[dst .. dst + cols], self.cells[src .. src + cols]);
            @memcpy(self.fg_rgb[dst .. dst + cols], self.fg_rgb[src .. src + cols]);
            @memcpy(self.bg_rgb[dst .. dst + cols], self.bg_rgb[src .. src + cols]);
            if (y_idx == top + shift) break;
        }
        // Clear top rows
        for (top..top + shift) |y| {
            const start = y * cols;
            @memset(self.cells[start .. start + cols], Cell{});
            @memset(self.fg_rgb[start .. start + cols], null);
            @memset(self.bg_rgb[start .. start + cols], null);
        }
    }

    fn eraseDisplay(self: *TermGrid, mode: u16) void {
        const cols: usize = self.cols;
        switch (mode) {
            0 => { // Cursor to end
                const start = self.idx(self.cursor_x, self.cursor_y);
                const total = @as(usize, self.cols) * @as(usize, self.rows);
                @memset(self.cells[start..total], Cell{});
                @memset(self.fg_rgb[start..total], null);
                @memset(self.bg_rgb[start..total], null);
            },
            1 => { // Start to cursor
                const end = self.idx(self.cursor_x, self.cursor_y) + 1;
                @memset(self.cells[0..end], Cell{});
                @memset(self.fg_rgb[0..end], null);
                @memset(self.bg_rgb[0..end], null);
            },
            2, 3 => { // Entire screen
                const total = @as(usize, cols) * @as(usize, self.rows);
                @memset(self.cells[0..total], Cell{});
                @memset(self.fg_rgb[0..total], null);
                @memset(self.bg_rgb[0..total], null);
            },
            else => {},
        }
    }

    fn eraseLine(self: *TermGrid, mode: u16) void {
        const cols: usize = self.cols;
        const y: usize = self.cursor_y;
        const row_start = y * cols;
        switch (mode) {
            0 => {
                const start = row_start + self.cursor_x;
                @memset(self.cells[start .. row_start + cols], Cell{});
                @memset(self.fg_rgb[start .. row_start + cols], null);
                @memset(self.bg_rgb[start .. row_start + cols], null);
            },
            1 => {
                const end = row_start + self.cursor_x + 1;
                @memset(self.cells[row_start..end], Cell{});
                @memset(self.fg_rgb[row_start..end], null);
                @memset(self.bg_rgb[row_start..end], null);
            },
            2 => {
                @memset(self.cells[row_start .. row_start + cols], Cell{});
                @memset(self.fg_rgb[row_start .. row_start + cols], null);
                @memset(self.bg_rgb[row_start .. row_start + cols], null);
            },
            else => {},
        }
    }

    fn deleteChars(self: *TermGrid, n: u32) void {
        const y = self.cursor_y;
        const x = self.cursor_x;
        const cols = self.cols;
        const count = @min(n, cols - x);
        const row_start = @as(usize, y) * @as(usize, cols);
        // Shift left
        const src_start = row_start + x + count;
        const src_end = row_start + cols;
        if (src_start < src_end) {
            const dst_start = row_start + x;
            const len = src_end - src_start;
            std.mem.copyForwards(Cell, self.cells[dst_start .. dst_start + len], self.cells[src_start..src_end]);
            std.mem.copyForwards(?[3]u8, self.fg_rgb[dst_start .. dst_start + len], self.fg_rgb[src_start..src_end]);
            std.mem.copyForwards(?[3]u8, self.bg_rgb[dst_start .. dst_start + len], self.bg_rgb[src_start..src_end]);
        }
        // Clear end
        const clear_start = row_start + cols - count;
        @memset(self.cells[clear_start .. row_start + cols], Cell{});
        @memset(self.fg_rgb[clear_start .. row_start + cols], null);
        @memset(self.bg_rgb[clear_start .. row_start + cols], null);
    }

    fn insertBlanks(self: *TermGrid, n: u32) void {
        const y = self.cursor_y;
        const x = self.cursor_x;
        const cols = self.cols;
        const count = @min(n, cols - x);
        const row_start = @as(usize, y) * @as(usize, cols);
        // Shift right (from end)
        const shift_end = row_start + cols;
        const shift_src_end = row_start + cols - count;
        const shift_src_start = row_start + x;
        if (shift_src_start < shift_src_end) {
            std.mem.copyBackwards(Cell, self.cells[shift_src_start + count .. shift_end], self.cells[shift_src_start..shift_src_end]);
            std.mem.copyBackwards(?[3]u8, self.fg_rgb[shift_src_start + count .. shift_end], self.fg_rgb[shift_src_start..shift_src_end]);
            std.mem.copyBackwards(?[3]u8, self.bg_rgb[shift_src_start + count .. shift_end], self.bg_rgb[shift_src_start..shift_src_end]);
        }
        // Clear inserted blanks
        @memset(self.cells[shift_src_start .. shift_src_start + count], Cell{});
        @memset(self.fg_rgb[shift_src_start .. shift_src_start + count], null);
        @memset(self.bg_rgb[shift_src_start .. shift_src_start + count], null);
    }

    fn deleteLines(self: *TermGrid, n: u32) void {
        const cols: usize = self.cols;
        const y: usize = self.cursor_y;
        const bot: usize = self.scroll_bottom;
        if (y > bot) return;
        const region = bot - y + 1;
        const shift: usize = @min(n, @as(u32, @intCast(region)));
        for (y..bot + 1 - shift) |r| {
            const dst = r * cols;
            const src = (r + shift) * cols;
            @memcpy(self.cells[dst .. dst + cols], self.cells[src .. src + cols]);
            @memcpy(self.fg_rgb[dst .. dst + cols], self.fg_rgb[src .. src + cols]);
            @memcpy(self.bg_rgb[dst .. dst + cols], self.bg_rgb[src .. src + cols]);
        }
        for (bot + 1 - shift..bot + 1) |r| {
            const start = r * cols;
            @memset(self.cells[start .. start + cols], Cell{});
            @memset(self.fg_rgb[start .. start + cols], null);
            @memset(self.bg_rgb[start .. start + cols], null);
        }
    }

    fn insertLines(self: *TermGrid, n: u32) void {
        const cols: usize = self.cols;
        const y: usize = self.cursor_y;
        const bot: usize = self.scroll_bottom;
        if (y > bot) return;
        const region = bot - y + 1;
        const shift: usize = @min(n, @as(u32, @intCast(region)));
        var r = bot;
        while (r >= y + shift) : (r -= 1) {
            const dst = r * cols;
            const src = (r - shift) * cols;
            @memcpy(self.cells[dst .. dst + cols], self.cells[src .. src + cols]);
            @memcpy(self.fg_rgb[dst .. dst + cols], self.fg_rgb[src .. src + cols]);
            @memcpy(self.bg_rgb[dst .. dst + cols], self.bg_rgb[src .. src + cols]);
            if (r == y + shift) break;
        }
        for (y..y + shift) |clr| {
            const start = clr * cols;
            @memset(self.cells[start .. start + cols], Cell{});
            @memset(self.fg_rgb[start .. start + cols], null);
            @memset(self.bg_rgb[start .. start + cols], null);
        }
    }

    fn switchScreen(self: *TermGrid, alt: bool) void {
        if (alt == self.is_alt_screen) return;
        const total = @as(usize, self.cols) * @as(usize, self.rows);
        if (self.alt_cells == null) {
            self.alt_cells = self.allocator.alloc(Cell, total) catch return;
            @memset(self.alt_cells.?, Cell{});
        }
        if (self.alt_fg_rgb == null) {
            self.alt_fg_rgb = self.allocator.alloc(?[3]u8, total) catch return;
            @memset(self.alt_fg_rgb.?, null);
        }
        if (self.alt_bg_rgb == null) {
            self.alt_bg_rgb = self.allocator.alloc(?[3]u8, total) catch return;
            @memset(self.alt_bg_rgb.?, null);
        }
        // Swap cells
        const tmp = self.cells;
        self.cells = self.alt_cells.?;
        self.alt_cells = tmp;
        // Swap fg_rgb
        const tmp_fg = self.fg_rgb;
        self.fg_rgb = self.alt_fg_rgb.?;
        self.alt_fg_rgb = tmp_fg;
        // Swap bg_rgb
        const tmp_bg = self.bg_rgb;
        self.bg_rgb = self.alt_bg_rgb.?;
        self.alt_bg_rgb = tmp_bg;
        self.is_alt_screen = alt;
        if (alt) {
            // Clear alt screen on entry
            @memset(self.cells[0..total], Cell{});
            @memset(self.fg_rgb[0..total], null);
            @memset(self.bg_rgb[0..total], null);
        }
    }

    fn resize(self: *TermGrid, new_cols: u32, new_rows: u32) !void {
        const new_total = @as(usize, new_cols) * @as(usize, new_rows);
        const new_cells = try self.allocator.alloc(Cell, new_total);
        errdefer self.allocator.free(new_cells);
        @memset(new_cells, Cell{});
        const new_fg = try self.allocator.alloc(?[3]u8, new_total);
        errdefer self.allocator.free(new_fg);
        @memset(new_fg, null);
        const new_bg = try self.allocator.alloc(?[3]u8, new_total);
        @memset(new_bg, null);
        // Copy existing
        const copy_cols: usize = @min(self.cols, new_cols);
        const copy_rows: usize = @min(self.rows, new_rows);
        for (0..copy_rows) |y| {
            const old_start = y * @as(usize, self.cols);
            const new_start = y * @as(usize, new_cols);
            @memcpy(new_cells[new_start .. new_start + copy_cols], self.cells[old_start .. old_start + copy_cols]);
            @memcpy(new_fg[new_start .. new_start + copy_cols], self.fg_rgb[old_start .. old_start + copy_cols]);
            @memcpy(new_bg[new_start .. new_start + copy_cols], self.bg_rgb[old_start .. old_start + copy_cols]);
        }
        self.allocator.free(self.cells);
        self.allocator.free(self.fg_rgb);
        self.allocator.free(self.bg_rgb);
        self.cells = new_cells;
        self.fg_rgb = new_fg;
        self.bg_rgb = new_bg;
        self.cols = new_cols;
        self.rows = new_rows;
        self.scroll_top = 0;
        self.scroll_bottom = new_rows -| 1;
        self.cursor_x = @min(self.cursor_x, new_cols -| 1);
        self.cursor_y = @min(self.cursor_y, new_rows -| 1);
        if (self.alt_cells) |ac| {
            self.allocator.free(ac);
            self.alt_cells = try self.allocator.alloc(Cell, new_total);
            @memset(self.alt_cells.?, Cell{});
        }
        if (self.alt_fg_rgb) |af| {
            self.allocator.free(af);
            self.alt_fg_rgb = try self.allocator.alloc(?[3]u8, new_total);
            @memset(self.alt_fg_rgb.?, null);
        }
        if (self.alt_bg_rgb) |ab| {
            self.allocator.free(ab);
            self.alt_bg_rgb = try self.allocator.alloc(?[3]u8, new_total);
            @memset(self.alt_bg_rgb.?, null);
        }
    }
};

// ── Action Executor ────────────────────────────────────────────────

fn executeAction(action: VtParser.VtAction, grid: *TermGrid) void {
    switch (action) {
        .print => |cp| grid.putChar(cp),
        .execute => |c| handleControl(c, grid),
        .csi => |csi| handleCsi(csi, grid),
        .esc => |esc| handleEsc(esc, grid),
        .osc => {},
        .none => {},
    }
}

fn handleControl(c: u8, grid: *TermGrid) void {
    switch (c) {
        0x07 => {}, // BEL
        0x08 => { // BS
            grid.wrap_next = false;
            if (grid.cursor_x > 0) grid.cursor_x -= 1;
        },
        0x09 => { // TAB
            grid.wrap_next = false;
            grid.cursor_x = @min((grid.cursor_x + 8) & ~@as(u32, 7), grid.cols - 1);
        },
        0x0A, 0x0B, 0x0C => { // LF/VT/FF
            grid.wrap_next = false;
            grid.newline();
        },
        0x0D => { // CR
            grid.cursor_x = 0;
            grid.wrap_next = false;
        },
        else => {},
    }
}

fn handleEsc(esc: VtParser.EscData, grid: *TermGrid) void {
    if (esc.intermediate == 0) {
        switch (esc.final_byte) {
            'D' => { // IND - Index (down)
                grid.wrap_next = false;
                grid.newline();
            },
            'M' => { // RI - Reverse Index (up)
                grid.wrap_next = false;
                if (grid.cursor_y == grid.scroll_top) {
                    grid.scrollDown(1);
                } else if (grid.cursor_y > 0) {
                    grid.cursor_y -= 1;
                }
            },
            'E' => { // NEL - Next Line
                grid.cursor_x = 0;
                grid.wrap_next = false;
                grid.newline();
            },
            'c' => { // RIS - Full Reset
                const cols = grid.cols;
                const rows = grid.rows;
                const total = @as(usize, cols) * @as(usize, rows);
                @memset(grid.cells[0..total], Cell{});
                @memset(grid.fg_rgb[0..total], null);
                @memset(grid.bg_rgb[0..total], null);
                grid.cursor_x = 0;
                grid.cursor_y = 0;
                grid.cur_fg = 7;
                grid.cur_bg = 0;
                grid.cur_bold = false;
                grid.cur_dim = false;
                grid.cur_italic = false;
                grid.cur_underline = false;
                grid.cur_reverse = false;
                grid.cur_strikethrough = false;
                grid.cur_fg_rgb = null;
                grid.cur_bg_rgb = null;
                grid.scroll_top = 0;
                grid.scroll_bottom = rows -| 1;
                grid.decawm = true;
                grid.wrap_next = false;
                grid.cursor_visible = true;
                grid.insert_mode = false;
            },
            '7' => {}, // DECSC - save cursor (simplified: ignore)
            '8' => {}, // DECRC - restore cursor (simplified: ignore)
            else => {},
        }
    }
}

fn handleCsi(csi: VtParser.CsiData, grid: *TermGrid) void {
    const p = csi.params;
    const pc = csi.param_count;

    // Private mode sequences (DECSET/DECRST)
    if (csi.private_marker == '?') {
        switch (csi.final_byte) {
            'h' => { // DECSET
                for (0..@max(pc, 1)) |i| {
                    switch (p[i]) {
                        1 => grid.decckm = true, // DECCKM
                        7 => grid.decawm = true, // DECAWM
                        25 => grid.cursor_visible = true, // DECTCEM
                        1049 => grid.switchScreen(true), // Alt screen
                        2004 => grid.bracketed_paste = true,
                        else => {},
                    }
                }
                return;
            },
            'l' => { // DECRST
                for (0..@max(pc, 1)) |i| {
                    switch (p[i]) {
                        1 => grid.decckm = false,
                        7 => grid.decawm = false,
                        25 => grid.cursor_visible = false,
                        1049 => grid.switchScreen(false),
                        2004 => grid.bracketed_paste = false,
                        else => {},
                    }
                }
                return;
            },
            else => return,
        }
    }

    // Handle space-intermediated CSIs
    if (csi.intermediate_count > 0 and csi.intermediates[0] == ' ') {
        // DECSCUSR (cursor style) - silently ignore
        return;
    }

    switch (csi.final_byte) {
        'A' => { // CUU - Cursor Up
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.wrap_next = false;
            grid.cursor_y = grid.cursor_y -| @as(u32, n);
        },
        'B', 'e' => { // CUD - Cursor Down
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.wrap_next = false;
            grid.cursor_y = @min(grid.cursor_y + @as(u32, n), grid.rows - 1);
        },
        'C', 'a' => { // CUF - Cursor Forward
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.wrap_next = false;
            grid.cursor_x = @min(grid.cursor_x + @as(u32, n), grid.cols - 1);
        },
        'D' => { // CUB - Cursor Back
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.wrap_next = false;
            grid.cursor_x = grid.cursor_x -| @as(u32, n);
        },
        'E' => { // CNL
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.cursor_x = 0;
            grid.wrap_next = false;
            grid.cursor_y = @min(grid.cursor_y + @as(u32, n), grid.rows - 1);
        },
        'F' => { // CPL
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.cursor_x = 0;
            grid.wrap_next = false;
            grid.cursor_y = grid.cursor_y -| @as(u32, n);
        },
        'G', '`' => { // CHA / HPA
            const col = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
            grid.cursor_x = @min(@as(u32, col), grid.cols - 1);
            grid.wrap_next = false;
        },
        'H', 'f' => { // CUP / HVP
            const row = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
            const col = if (pc > 1 and p[1] > 0) p[1] - 1 else 0;
            grid.cursor_y = @min(@as(u32, row), grid.rows - 1);
            grid.cursor_x = @min(@as(u32, col), grid.cols - 1);
            grid.wrap_next = false;
        },
        'J' => { // ED - Erase Display
            const mode = if (pc > 0) p[0] else 0;
            grid.eraseDisplay(mode);
        },
        'K' => { // EL - Erase Line
            const mode = if (pc > 0) p[0] else 0;
            grid.eraseLine(mode);
        },
        'L' => { // IL - Insert Lines
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.insertLines(n);
        },
        'M' => { // DL - Delete Lines
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.deleteLines(n);
        },
        'P' => { // DCH - Delete Characters
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.deleteChars(n);
        },
        'S' => { // SU - Scroll Up
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.scrollUp(n);
        },
        'T' => { // SD - Scroll Down
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.scrollDown(n);
        },
        'X' => { // ECH - Erase Characters
            const n: u32 = if (pc > 0 and p[0] > 0) p[0] else 1;
            const x = grid.cursor_x;
            const y = grid.cursor_y;
            const end = @min(x + n, grid.cols);
            for (x..end) |cx| {
                const i = grid.idx(@intCast(cx), y);
                grid.cells[i] = Cell{};
                grid.fg_rgb[i] = null;
                grid.bg_rgb[i] = null;
            }
        },
        '@' => { // ICH - Insert Blank Characters
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            grid.insertBlanks(n);
        },
        'd' => { // VPA - Line Position Absolute
            const row = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
            grid.cursor_y = @min(@as(u32, row), grid.rows - 1);
            grid.wrap_next = false;
        },
        'h' => { // SM - Set Mode
            for (0..@max(pc, 1)) |i| {
                if (p[i] == 4) grid.insert_mode = true;
            }
        },
        'l' => { // RM - Reset Mode
            for (0..@max(pc, 1)) |i| {
                if (p[i] == 4) grid.insert_mode = false;
            }
        },
        'm' => handleSgr(csi, grid), // SGR - Select Graphic Rendition
        'n' => {}, // DSR - Device Status Report (ignore for now)
        'r' => { // DECSTBM - Set Scrolling Region
            const top = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
            const bot = if (pc > 1 and p[1] > 0) p[1] - 1 else grid.rows - 1;
            grid.scroll_top = @min(@as(u32, top), grid.rows - 1);
            grid.scroll_bottom = @min(@as(u32, bot), grid.rows - 1);
            grid.cursor_x = 0;
            grid.cursor_y = 0;
            grid.wrap_next = false;
        },
        't' => {}, // Window manipulation (ignore)
        'c' => {}, // DA - Device Attributes (ignore)
        else => {},
    }
}

fn handleSgr(csi: VtParser.CsiData, grid: *TermGrid) void {
    const p = csi.params;
    const pc = csi.param_count;
    if (pc == 0) {
        // ESC[m = reset
        resetSgr(grid);
        return;
    }
    var i: u8 = 0;
    while (i < pc) : (i += 1) {
        switch (p[i]) {
            0 => resetSgr(grid),
            1 => grid.cur_bold = true,
            2 => grid.cur_dim = true,
            3 => grid.cur_italic = true,
            4 => grid.cur_underline = true,
            7 => grid.cur_reverse = true,
            9 => grid.cur_strikethrough = true,
            22 => { grid.cur_bold = false; grid.cur_dim = false; },
            23 => grid.cur_italic = false,
            24 => grid.cur_underline = false,
            27 => grid.cur_reverse = false,
            29 => grid.cur_strikethrough = false,
            // Foreground 30-37
            30...37 => { grid.cur_fg = @truncate(p[i] - 30); grid.cur_fg_rgb = null; },
            38 => {
                // Extended foreground
                if (i + 1 < pc and p[i + 1] == 5 and i + 2 < pc) {
                    grid.cur_fg = @truncate(p[i + 2]);
                    grid.cur_fg_rgb = null;
                    i += 2;
                } else if (i + 1 < pc and p[i + 1] == 2 and i + 4 < pc) {
                    grid.cur_fg_rgb = .{ @truncate(p[i + 2]), @truncate(p[i + 3]), @truncate(p[i + 4]) };
                    i += 4;
                }
            },
            39 => { grid.cur_fg = 7; grid.cur_fg_rgb = null; },
            // Background 40-47
            40...47 => { grid.cur_bg = @truncate(p[i] - 40); grid.cur_bg_rgb = null; },
            48 => {
                // Extended background
                if (i + 1 < pc and p[i + 1] == 5 and i + 2 < pc) {
                    grid.cur_bg = @truncate(p[i + 2]);
                    grid.cur_bg_rgb = null;
                    i += 2;
                } else if (i + 1 < pc and p[i + 1] == 2 and i + 4 < pc) {
                    grid.cur_bg_rgb = .{ @truncate(p[i + 2]), @truncate(p[i + 3]), @truncate(p[i + 4]) };
                    i += 4;
                }
            },
            49 => { grid.cur_bg = 0; grid.cur_bg_rgb = null; },
            // Bright foreground 90-97
            90...97 => { grid.cur_fg = @truncate(p[i] - 90 + 8); grid.cur_fg_rgb = null; },
            // Bright background 100-107
            100...107 => { grid.cur_bg = @truncate(p[i] - 100 + 8); grid.cur_bg_rgb = null; },
            else => {},
        }
    }
}

fn resetSgr(grid: *TermGrid) void {
    grid.cur_fg = 7;
    grid.cur_bg = 0;
    grid.cur_bold = false;
    grid.cur_dim = false;
    grid.cur_italic = false;
    grid.cur_underline = false;
    grid.cur_reverse = false;
    grid.cur_strikethrough = false;
    grid.cur_fg_rgb = null;
    grid.cur_bg_rgb = null;
}

// ── PTY ────────────────────────────────────────────────────────────

const TIOCSPTLCK: u32 = 0x40045431;
const TIOCGPTN: u32 = 0x80045430;
const TIOCSCTTY: u32 = 0x540E;
const TIOCSWINSZ: u32 = 0x5414;

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

fn spawnPty(cols: u16, rows: u16) !struct { master_fd: posix.fd_t, child_pid: posix.pid_t } {
    // Open master
    const master_fd = try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer posix.close(master_fd);

    // Unlock slave
    var unlock: c_int = 0;
    const unlock_rc = linux.ioctl(@intCast(master_fd), TIOCSPTLCK, @intFromPtr(&unlock));
    if (@as(isize, @bitCast(unlock_rc)) < 0) return error.IoctlFailed;

    // Get slave path
    var pty_num: c_int = undefined;
    const ptn_rc = linux.ioctl(@intCast(master_fd), TIOCGPTN, @intFromPtr(&pty_num));
    if (@as(isize, @bitCast(ptn_rc)) < 0) return error.IoctlFailed;

    var slave_path_buf: [64]u8 = undefined;
    const slave_path = std.fmt.bufPrintZ(&slave_path_buf, "/dev/pts/{d}", .{pty_num}) catch return error.PathTooLong;

    // Fork
    const pid = try posix.fork();

    if (pid == 0) {
        // Child
        posix.close(master_fd);
        _ = linux.syscall0(.setsid);

        const slave_fd = posix.open(slave_path, .{ .ACCMODE = .RDWR }, 0) catch std.posix.exit(1);
        _ = linux.ioctl(@intCast(slave_fd), TIOCSCTTY, 0);

        var ws = Winsize{ .ws_row = rows, .ws_col = cols };
        _ = linux.ioctl(@intCast(slave_fd), TIOCSWINSZ, @intFromPtr(&ws));

        posix.dup2(slave_fd, 0) catch std.posix.exit(1);
        posix.dup2(slave_fd, 1) catch std.posix.exit(1);
        posix.dup2(slave_fd, 2) catch std.posix.exit(1);
        if (slave_fd > 2) posix.close(slave_fd);

        // Environment
        var col_buf: [32]u8 = undefined;
        var row_buf: [32]u8 = undefined;
        var home_buf: [256]u8 = undefined;
        var user_buf: [128]u8 = undefined;
        var lang_buf: [64]u8 = undefined;
        var path_buf: [1024]u8 = undefined;
        var shell_buf: [256]u8 = undefined;

        const home_val = std.posix.getenv("HOME") orelse "/root";
        const user_val = std.posix.getenv("USER") orelse "root";
        const lang_val = std.posix.getenv("LANG") orelse "C.UTF-8";
        const path_val = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";

        // Detect user's shell
        const shell_val = std.posix.getenv("SHELL") orelse "/bin/sh";

        const col_env = std.fmt.bufPrintZ(&col_buf, "COLUMNS={d}", .{cols}) catch "COLUMNS=80";
        const row_env = std.fmt.bufPrintZ(&row_buf, "LINES={d}", .{rows}) catch "LINES=24";
        const home_env = std.fmt.bufPrintZ(&home_buf, "HOME={s}", .{home_val}) catch "HOME=/root";
        const user_env = std.fmt.bufPrintZ(&user_buf, "USER={s}", .{user_val}) catch "USER=root";
        const lang_env = std.fmt.bufPrintZ(&lang_buf, "LANG={s}", .{lang_val}) catch "LANG=C.UTF-8";
        const path_env = std.fmt.bufPrintZ(&path_buf, "PATH={s}", .{path_val}) catch "PATH=/usr/local/bin:/usr/bin:/bin";
        const shell_env = std.fmt.bufPrintZ(&shell_buf, "SHELL={s}", .{shell_val}) catch "SHELL=/bin/sh";

        var shell_path_buf: [256]u8 = undefined;
        const shell_path: [*:0]const u8 = std.fmt.bufPrintZ(&shell_path_buf, "{s}", .{shell_val}) catch "/bin/sh";

        var env_arr: [20:null]?[*:0]const u8 = .{null} ** 20;
        var ei: usize = 0;
        env_arr[ei] = "TERM=xterm-256color"; ei += 1;
        env_arr[ei] = "COLORTERM=truecolor"; ei += 1;
        env_arr[ei] = "TERM_PROGRAM=zz"; ei += 1;
        env_arr[ei] = path_env; ei += 1;
        env_arr[ei] = lang_env; ei += 1;
        env_arr[ei] = shell_env; ei += 1;
        env_arr[ei] = home_env; ei += 1;
        env_arr[ei] = user_env; ei += 1;
        env_arr[ei] = col_env; ei += 1;
        env_arr[ei] = row_env; ei += 1;

        // Inherit display variables
        var disp_buf: [128]u8 = undefined;
        var xdg_buf: [256]u8 = undefined;
        if (std.posix.getenv("DISPLAY")) |d| {
            if (std.fmt.bufPrintZ(&disp_buf, "DISPLAY={s}", .{d})) |e| {
                env_arr[ei] = e; ei += 1;
            } else |_| {}
        }
        if (std.posix.getenv("XDG_RUNTIME_DIR")) |d| {
            if (std.fmt.bufPrintZ(&xdg_buf, "XDG_RUNTIME_DIR={s}", .{d})) |e| {
                env_arr[ei] = e; ei += 1;
            } else |_| {}
        }

        const env: [*:null]const ?[*:0]const u8 = &env_arr;
        const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{ shell_path, "--login" };
        _ = posix.execveZ(shell_path, argv, env) catch {};
        std.posix.exit(1);
    }

    // Parent: set non-blocking
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK: u32 = 0x800;
    const cur_flags = try posix.fcntl(master_fd, F_GETFL, 0);
    _ = try posix.fcntl(master_fd, F_SETFL, cur_flags | O_NONBLOCK);

    return .{ .master_fd = master_fd, .child_pid = pid };
}

fn resizePty(fd: posix.fd_t, cols: u16, rows: u16) void {
    var ws = Winsize{ .ws_row = rows, .ws_col = cols };
    _ = linux.ioctl(@intCast(fd), TIOCSWINSZ, @intFromPtr(&ws));
}

// ── Public Terminal Panel ──────────────────────────────────────────

pub const Terminal = struct {
    visible: bool = false,
    focused: bool = false,
    height_rows: u32 = 14,

    grid: TermGrid,
    parser: VtParser = .{},
    pty_fd: ?posix.fd_t = null,
    child_pid: ?posix.pid_t = null,

    allocator: Allocator,

    // Layout (pixels)
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(allocator: Allocator) !Terminal {
        // Start with a reasonable default; will resize when shown
        var grid = try TermGrid.init(allocator, 80, 14);
        _ = &grid;
        return .{
            .grid = grid,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Terminal) void {
        if (self.pty_fd) |fd| {
            posix.close(fd);
        }
        if (self.child_pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
            _ = posix.waitpid(pid, 0);
        }
        self.grid.deinit();
    }

    pub fn toggle(self: *Terminal) void {
        self.visible = !self.visible;
        if (self.visible) {
            self.focused = true;
            self.ensureSpawned();
        } else {
            self.focused = false;
        }
    }

    pub fn ensureSpawned(self: *Terminal) void {
        if (self.pty_fd != null) return;
        const cols: u16 = @intCast(@max(self.grid.cols, 1));
        const rows: u16 = @intCast(@max(self.grid.rows, 1));
        const result = spawnPty(cols, rows) catch return;
        self.pty_fd = result.master_fd;
        self.child_pid = result.child_pid;
    }

    pub fn getPtyFd(self: *const Terminal) ?posix.fd_t {
        if (!self.visible) return null;
        return self.pty_fd;
    }

    pub fn processOutput(self: *Terminal) void {
        const fd = self.pty_fd orelse return;
        var buf: [8192]u8 = undefined;
        // Read all available data
        while (true) {
            const n = posix.read(fd, &buf) catch |err| {
                if (err == error.WouldBlock) break;
                // Child exited or error
                break;
            };
            if (n == 0) break;
            // Feed through VT parser
            for (buf[0..n]) |byte| {
                const action = self.parser.feed(byte);
                executeAction(action, &self.grid);
            }
        }
    }

    pub fn sendBytes(self: *Terminal, data: []const u8) void {
        const fd = self.pty_fd orelse return;
        _ = posix.write(fd, data) catch {};
    }

    /// Convert XKB keysym + modifiers to terminal escape sequence and send
    pub fn handleKey(self: *Terminal, keysym: u32, ctrl: bool, shift: bool) bool {
        _ = shift;
        if (ctrl) {
            // Ctrl+letter -> ASCII control char
            const k = if (keysym >= 'A' and keysym <= 'Z') keysym + 32 else keysym;
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
        // Special keys
        const XK_Return = 0xFF0D;
        const XK_BackSpace = 0xFF08;
        const XK_Tab = 0xFF09;
        const XK_Escape = 0xFF1B;
        const XK_Up = 0xFF52;
        const XK_Down = 0xFF54;
        const XK_Right = 0xFF53;
        const XK_Left = 0xFF51;
        const XK_Home = 0xFF50;
        const XK_End = 0xFF57;
        const XK_Insert = 0xFF63;
        const XK_Delete = 0xFFFF;
        const XK_Page_Up = 0xFF55;
        const XK_Page_Down = 0xFF56;
        const XK_F1 = 0xFFBE;

        switch (keysym) {
            XK_Return => self.sendBytes("\r"),
            XK_BackSpace => self.sendBytes("\x7f"),
            XK_Tab => self.sendBytes("\t"),
            XK_Escape => self.sendBytes("\x1b"),
            XK_Up => self.sendBytes(if (self.grid.decckm) "\x1bOA" else "\x1b[A"),
            XK_Down => self.sendBytes(if (self.grid.decckm) "\x1bOB" else "\x1b[B"),
            XK_Right => self.sendBytes(if (self.grid.decckm) "\x1bOC" else "\x1b[C"),
            XK_Left => self.sendBytes(if (self.grid.decckm) "\x1bOD" else "\x1b[D"),
            XK_Home => self.sendBytes(if (self.grid.decckm) "\x1bOH" else "\x1b[H"),
            XK_End => self.sendBytes(if (self.grid.decckm) "\x1bOF" else "\x1b[F"),
            XK_Insert => self.sendBytes("\x1b[2~"),
            XK_Delete => self.sendBytes("\x1b[3~"),
            XK_Page_Up => self.sendBytes("\x1b[5~"),
            XK_Page_Down => self.sendBytes("\x1b[6~"),
            // F1-F12
            XK_F1 => self.sendBytes("\x1bOP"),
            XK_F1 + 1 => self.sendBytes("\x1bOQ"),
            XK_F1 + 2 => self.sendBytes("\x1bOR"),
            XK_F1 + 3 => self.sendBytes("\x1bOS"),
            XK_F1 + 4 => self.sendBytes("\x1b[15~"),
            XK_F1 + 5 => self.sendBytes("\x1b[17~"),
            XK_F1 + 6 => self.sendBytes("\x1b[18~"),
            XK_F1 + 7 => self.sendBytes("\x1b[19~"),
            XK_F1 + 8 => self.sendBytes("\x1b[20~"),
            XK_F1 + 9 => self.sendBytes("\x1b[21~"),
            XK_F1 + 10 => self.sendBytes("\x1b[23~"),
            XK_F1 + 11 => self.sendBytes("\x1b[24~"),
            else => return false,
        }
        return true;
    }

    pub fn handleTextInput(self: *Terminal, text: []const u8) void {
        self.sendBytes(text);
    }

    pub fn handlePaste(self: *Terminal, text: []const u8) void {
        if (self.grid.bracketed_paste) {
            self.sendBytes("\x1b[200~");
            self.sendBytes(text);
            self.sendBytes("\x1b[201~");
        } else {
            self.sendBytes(text);
        }
    }

    pub fn updateLayout(self: *Terminal, x: u32, y: u32, width: u32, height: u32, font: *const FontFace) void {
        self.x = x;
        self.y = y;
        self.width = width;
        self.height = height;

        // Compute grid dimensions from pixel size (subtract 1px for separator)
        const usable_h = if (height > 2) height - 2 else 1;
        const new_cols = @max(width / font.cell_width, 1);
        const new_rows = @max(usable_h / font.cell_height, 1);

        if (new_cols != self.grid.cols or new_rows != self.grid.rows) {
            self.grid.resize(new_cols, new_rows) catch return;
            self.height_rows = new_rows;
            if (self.pty_fd) |fd| {
                resizePty(fd, @intCast(new_cols), @intCast(new_rows));
            }
        }
    }

    pub fn pixelHeight(self: *const Terminal, font: *const FontFace) u32 {
        if (!self.visible) return 0;
        return self.height_rows * font.cell_height + 2; // +2 for separator
    }

    pub fn render(self: *const Terminal, renderer: *Renderer, font: *FontFace) void {
        if (!self.visible) return;

        const bg_color = Color.fromHex(0x1e1e2e); // Dark terminal bg (Catppuccin)
        const separator_color = Color.fromHex(0x585b70); // Separator line

        // Separator line (2px)
        renderer.fillRect(self.x, self.y, self.width, 2, separator_color);

        // Terminal background
        renderer.fillRect(self.x, self.y + 2, self.width, self.height -| 2, bg_color);

        // Render cells
        const base_y = self.y + 2;
        for (0..self.grid.rows) |row| {
            for (0..self.grid.cols) |col| {
                const cell = self.grid.getCell(@intCast(col), @intCast(row));
                var fg_c: Color = undefined;
                var bg_c: Color = undefined;

                // Resolve colors
                const ci = self.grid.idx(@intCast(col), @intCast(row));
                if (self.grid.fg_rgb[ci]) |rgb| {
                    fg_c = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
                } else {
                    var fg_idx = cell.fg;
                    if (cell.bold and fg_idx < 8) fg_idx += 8; // Bold brightens
                    fg_c = palToColor(palette[fg_idx]);
                }
                if (self.grid.bg_rgb[ci]) |rgb| {
                    bg_c = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
                } else {
                    bg_c = palToColor(palette[cell.bg]);
                }

                // Reverse video
                if (cell.reverse) {
                    const tmp = fg_c;
                    fg_c = bg_c;
                    bg_c = tmp;
                }

                // Dim
                if (cell.dim) {
                    fg_c.r /= 2;
                    fg_c.g /= 2;
                    fg_c.b /= 2;
                }

                const cx = self.x + @as(u32, @intCast(col)) * font.cell_width;
                const cy = base_y + @as(u32, @intCast(row)) * font.cell_height;
                const safe_ascent: u32 = if (font.ascent >= 0) @intCast(font.ascent) else 0;

                // Background (only non-default)
                if (cell.bg != 0 or cell.reverse or self.grid.bg_rgb[ci] != null) {
                    renderer.fillRect(cx, cy, font.cell_width, font.cell_height, bg_c);
                }

                // Glyph
                if (cell.char > ' ') {
                    const glyph = font.getGlyph(@intCast(cell.char)) catch continue;
                    const gx = @as(i32, @intCast(cx)) + glyph.bearing_x;
                    const gy = @as(i32, @intCast(cy)) + font.ascent - glyph.bearing_y;
                    renderer.drawGlyph(glyph, gx, gy, fg_c);
                }

                // Underline
                if (cell.underline) {
                    const uy = cy + safe_ascent + 1;
                    renderer.fillRect(cx, uy, font.cell_width, 1, fg_c);
                }

                // Strikethrough
                if (cell.strikethrough) {
                    const sy = cy + safe_ascent / 2;
                    renderer.fillRect(cx, sy, font.cell_width, 1, fg_c);
                }
            }
        }

        // Cursor
        if (self.grid.cursor_visible and self.focused) {
            const cur_x = self.x + self.grid.cursor_x * font.cell_width;
            const cur_y = base_y + self.grid.cursor_y * font.cell_height;
            const cursor_color = Color.fromHex(0xcdd6f4); // Light cursor
            renderer.fillRect(cur_x, cur_y, 2, font.cell_height, cursor_color);
        }
    }

    /// Check if pixel position is within terminal area
    pub fn containsPoint(self: *const Terminal, px: i32, py: i32) bool {
        if (!self.visible) return false;
        return px >= @as(i32, @intCast(self.x)) and
            px < @as(i32, @intCast(self.x + self.width)) and
            py >= @as(i32, @intCast(self.y)) and
            py < @as(i32, @intCast(self.y + self.height));
    }
};
