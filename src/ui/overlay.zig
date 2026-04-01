const std = @import("std");
const Renderer = @import("render.zig").Renderer;
const Color = @import("render.zig").Color;
const FontFace = @import("font.zig").FontFace;

// Catppuccin Mocha overlay colors
const overlay_bg = Color.fromHex(0x1e1e2e); // Base
const overlay_border = Color.fromHex(0x585b70); // Surface2
const overlay_input_bg = Color.fromHex(0x313244); // Surface0
const overlay_text = Color.fromHex(0xcdd6f4); // Text
const overlay_dim = Color.fromHex(0x6c7086); // Overlay0 (dimmed text)
const overlay_selected = Color.fromHex(0x45475a); // Surface1 (selection)
const overlay_accent = Color.fromHex(0xb4befe); // Lavender (input cursor, matched chars)
const overlay_dim_bg = Color.fromHex(0x11111b); // Crust (screen dimming)

pub const Overlay = struct {
    input_buf: [256]u8 = undefined,
    input_len: u32 = 0,
    selected: usize = 0,
    scroll_offset: usize = 0,
    items: []const []const u8 = &.{}, // Current filtered items to display
    active: bool = false,
    title: []const u8 = "",
    // Secondary input field (for find & replace)
    secondary_buf: ?*[256]u8 = null,
    secondary_len: ?*u32 = null,
    secondary_label: []const u8 = "",
    secondary_active: bool = false, // Is secondary field focused?

    pub fn open(self: *Overlay, title: []const u8) void {
        self.active = true;
        self.input_len = 0;
        self.selected = 0;
        self.scroll_offset = 0;
        self.title = title;
        self.secondary_buf = null;
        self.secondary_len = null;
        self.secondary_label = "";
        self.secondary_active = false;
    }

    pub fn close(self: *Overlay) void {
        self.active = false;
    }

    pub fn inputSlice(self: *const Overlay) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    pub fn appendChar(self: *Overlay, ch: u8) void {
        if (self.input_len < self.input_buf.len) {
            self.input_buf[self.input_len] = ch;
            self.input_len += 1;
            self.selected = 0;
            self.scroll_offset = 0;
        }
    }

    pub fn appendText(self: *Overlay, text: []const u8) void {
        for (text) |ch| {
            if (ch < 0x20) continue; // Skip control chars
            self.appendChar(ch);
        }
    }

    pub fn backspace(self: *Overlay) void {
        if (self.input_len > 0) {
            self.input_len -= 1;
            self.selected = 0;
            self.scroll_offset = 0;
        }
    }

    pub fn moveUp(self: *Overlay) void {
        if (self.selected > 0) self.selected -= 1;
        if (self.selected < self.scroll_offset) self.scroll_offset = self.selected;
    }

    pub fn moveDown(self: *Overlay) void {
        if (self.items.len > 0 and self.selected < self.items.len - 1) {
            self.selected += 1;
        }
    }

    pub fn selectedItem(self: *const Overlay) ?[]const u8 {
        if (self.items.len == 0) return null;
        if (self.selected >= self.items.len) return null;
        return self.items[self.selected];
    }

    /// Render the overlay on top of the editor.
    pub fn render(self: *Overlay, renderer: *Renderer, font: *FontFace) void {
        if (!self.active) return;

        const cell_w = font.cell_width;
        const cell_h = if (font.cell_height > 0) font.cell_height else 1;
        const win_w = renderer.width;
        const win_h = renderer.height;

        // Overlay dimensions: 60% width, up to 50% height
        const box_w = @min(win_w * 6 / 10, 800);
        const max_visible: u32 = @min(win_h / cell_h / 2, 15);
        const has_secondary = self.secondary_buf != null;
        const extra_rows: u32 = if (has_secondary) 2 else 0; // label + input
        const box_h = (max_visible + 3 + extra_rows) * cell_h;
        const box_x = (win_w - box_w) / 2;
        const box_y = win_h / 6; // Upper third

        // Dim background
        dimScreen(renderer);

        // Box background + border
        renderer.fillRect(box_x -| 1, box_y -| 1, box_w + 2, box_h + 2, overlay_border);
        renderer.fillRect(box_x, box_y, box_w, box_h, overlay_bg);

        var y = box_y + cell_h / 2;

        // Title
        {
            var tx = box_x + cell_w;
            for (self.title) |ch| {
                const glyph = font.getGlyph(ch) catch continue;
                renderer.fillRect(tx, y, cell_w, cell_h, overlay_bg);
                const gx: i32 = @intCast(tx);
                const gy: i32 = @as(i32, @intCast(y)) + font.ascent - @as(i32, glyph.bearing_y);
                renderer.drawGlyph(glyph, gx, gy, overlay_dim);
                tx += cell_w;
            }
        }
        y += cell_h;

        // Input field (search)
        const input_x = box_x + cell_w / 2;
        const input_w = box_w - cell_w;
        const search_bg = if (has_secondary and self.secondary_active) overlay_bg else overlay_input_bg;
        renderer.fillRect(input_x, y, input_w, cell_h + 4, search_bg);

        // Input text
        {
            var ix = input_x + 4;
            const input = self.inputSlice();
            for (input) |ch| {
                const glyph = font.getGlyph(ch) catch continue;
                const gx: i32 = @intCast(ix);
                const gy: i32 = @as(i32, @intCast(y + 2)) + font.ascent - @as(i32, glyph.bearing_y);
                renderer.drawGlyph(glyph, gx, gy, overlay_text);
                ix += cell_w;
            }
            // Cursor only if search field is active
            if (!has_secondary or !self.secondary_active) {
                renderer.fillRect(ix, y + 2, 2, cell_h, overlay_accent);
            }
        }
        y += cell_h + 8;

        // Secondary input field (replace)
        if (has_secondary) {
            // Label
            {
                var tx = box_x + cell_w;
                for (self.secondary_label) |ch| {
                    const glyph = font.getGlyph(ch) catch continue;
                    renderer.fillRect(tx, y, cell_w, cell_h, overlay_bg);
                    const gx: i32 = @intCast(tx);
                    const gy: i32 = @as(i32, @intCast(y)) + font.ascent - @as(i32, glyph.bearing_y);
                    renderer.drawGlyph(glyph, gx, gy, overlay_dim);
                    tx += cell_w;
                }
            }
            y += cell_h;

            const replace_bg = if (self.secondary_active) overlay_input_bg else overlay_bg;
            renderer.fillRect(input_x, y, input_w, cell_h + 4, replace_bg);

            // Replace text
            if (self.secondary_buf) |sbuf| {
                const slen = if (self.secondary_len) |sl| sl.* else 0;
                var ix = input_x + 4;
                for (sbuf[0..slen]) |ch| {
                    const glyph = font.getGlyph(ch) catch continue;
                    const gx: i32 = @intCast(ix);
                    const gy: i32 = @as(i32, @intCast(y + 2)) + font.ascent - @as(i32, glyph.bearing_y);
                    renderer.drawGlyph(glyph, gx, gy, overlay_text);
                    ix += cell_w;
                }
                // Cursor only if replace field is active
                if (self.secondary_active) {
                    renderer.fillRect(ix, y + 2, 2, cell_h, overlay_accent);
                }
            }
            y += cell_h + 8;
        }

        // Separator
        renderer.fillRect(box_x + cell_w / 2, y, box_w - cell_w, 1, overlay_border);
        y += 4;

        // Results
        // Ensure scroll keeps selected visible
        if (self.selected >= self.scroll_offset + max_visible) {
            self.scroll_offset = self.selected - max_visible + 1;
        }

        var visible: u32 = 0;
        var idx = self.scroll_offset;
        while (visible < max_visible and idx < self.items.len) : ({
            visible += 1;
            idx += 1;
        }) {
            const item = self.items[idx];
            const is_selected = (idx == self.selected);
            const row_bg = if (is_selected) overlay_selected else overlay_bg;
            const row_fg = if (is_selected) overlay_text else overlay_dim;

            renderer.fillRect(box_x + cell_w / 2, y, box_w - cell_w, cell_h, row_bg);

            var ix = box_x + cell_w;
            const max_chars = (box_w - cell_w * 2) / cell_w;
            var chars: u32 = 0;
            for (item) |ch| {
                if (chars >= max_chars) break;
                const glyph = font.getGlyph(ch) catch continue;
                const gx: i32 = @intCast(ix);
                const gy: i32 = @as(i32, @intCast(y)) + font.ascent - @as(i32, glyph.bearing_y);
                renderer.drawGlyph(glyph, gx, gy, row_fg);
                ix += cell_w;
                chars += 1;
            }

            y += cell_h;
        }

        // Item count
        {
            var count_buf: [32]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{d} items", .{self.items.len}) catch "";
            const required_w = @as(u32, @intCast(count_str.len + 1)) * cell_w;
            const count_x = if (box_w > required_w) box_x + box_w - required_w else box_x;
            for (count_str, 0..) |ch, ci| {
                const glyph = font.getGlyph(ch) catch continue;
                const gx: i32 = @intCast(count_x + @as(u32, @intCast(ci)) * cell_w);
                const gy: i32 = @as(i32, @intCast(y)) + font.ascent - @as(i32, glyph.bearing_y);
                renderer.drawGlyph(glyph, gx, gy, overlay_dim);
            }
        }
    }

    fn dimScreen(renderer: *Renderer) void {
        // Darken every pixel by blending with dark color at 60% opacity
        const dim = overlay_dim_bg;
        var i: usize = 0;
        while (i + 4 <= renderer.buffer.len) : (i += 4) {
            renderer.buffer[i] = @intCast((@as(u16, renderer.buffer[i]) * 100 + @as(u16, dim.b) * 155) / 255);
            renderer.buffer[i + 1] = @intCast((@as(u16, renderer.buffer[i + 1]) * 100 + @as(u16, dim.g) * 155) / 255);
            renderer.buffer[i + 2] = @intCast((@as(u16, renderer.buffer[i + 2]) * 100 + @as(u16, dim.r) * 155) / 255);
        }
    }
};
