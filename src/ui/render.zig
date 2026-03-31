// zz/src/ui/render.zig
const std = @import("std");
const font_mod = @import("font.zig");
const GlyphBitmap = font_mod.GlyphBitmap;
const FontFace = font_mod.FontFace;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromHex(hex: u24) Color {
        return .{
            .r = @intCast((hex >> 16) & 0xFF),
            .g = @intCast((hex >> 8) & 0xFF),
            .b = @intCast(hex & 0xFF),
        };
    }
};

pub const Renderer = struct {
    buffer: []u8,       // SHM buffer (BGRA32)
    stride: u32,        // bytes per row
    width: u32,         // pixel width
    height: u32,        // pixel height

    /// Fill a rectangle with solid color.
    pub fn fillRect(self: *Renderer, x: u32, y: u32, w: u32, h: u32, color: Color) void {
        const pixel: u32 = @as(u32, color.b) |
            (@as(u32, color.g) << 8) |
            (@as(u32, color.r) << 16) |
            (0xFF << 24);
        const pixel_bytes: [4]u8 = @bitCast(pixel);

        var row = y;
        while (row < y + h and row < self.height) : (row += 1) {
            var col = x;
            while (col < x + w and col < self.width) : (col += 1) {
                const offset = row * self.stride + col * 4;
                if (offset + 4 <= self.buffer.len) {
                    self.buffer[offset..][0..4].* = pixel_bytes;
                }
            }
        }
    }

    /// Render a glyph bitmap at pixel position with alpha blending.
    pub fn drawGlyph(self: *Renderer, glyph: GlyphBitmap, px: i32, py: i32, fg: Color) void {
        if (glyph.width == 0 or glyph.height == 0) return;
        if (glyph.pixels.len == 0) return;

        var row: u32 = 0;
        while (row < glyph.height) : (row += 1) {
            const screen_y = py + @as(i32, @intCast(row));
            if (screen_y < 0 or screen_y >= @as(i32, @intCast(self.height))) continue;

            var col: u32 = 0;
            while (col < glyph.width) : (col += 1) {
                const screen_x = px + @as(i32, @intCast(col));
                if (screen_x < 0 or screen_x >= @as(i32, @intCast(self.width))) continue;

                const alpha = glyph.pixels[row * glyph.width + col];
                if (alpha == 0) continue;

                const offset = @as(u32, @intCast(screen_y)) * self.stride + @as(u32, @intCast(screen_x)) * 4;
                if (offset + 4 > self.buffer.len) continue;

                if (alpha == 255) {
                    self.buffer[offset] = fg.b;
                    self.buffer[offset + 1] = fg.g;
                    self.buffer[offset + 2] = fg.r;
                    self.buffer[offset + 3] = 0xFF;
                } else {
                    // Alpha blend
                    const a = @as(u16, alpha);
                    const inv_a: u16 = 255 - a;
                    self.buffer[offset] = @intCast((@as(u16, fg.b) * a + @as(u16, self.buffer[offset]) * inv_a) / 255);
                    self.buffer[offset + 1] = @intCast((@as(u16, fg.g) * a + @as(u16, self.buffer[offset + 1]) * inv_a) / 255);
                    self.buffer[offset + 2] = @intCast((@as(u16, fg.r) * a + @as(u16, self.buffer[offset + 2]) * inv_a) / 255);
                }
            }
        }
    }

    /// Render a single character in a grid cell.
    pub fn drawCell(
        self: *Renderer,
        font: *FontFace,
        codepoint: u32,
        grid_col: u32,
        grid_row: u32,
        fg: Color,
        bg: Color,
        left_pad: u32,
    ) void {
        const cell_x = left_pad + grid_col * font.cell_width;
        const cell_y = grid_row * font.cell_height;

        // Fill background
        self.fillRect(cell_x, cell_y, font.cell_width, font.cell_height, bg);

        // Draw glyph
        const glyph = font.getGlyph(codepoint) catch return;
        const glyph_x = @as(i32, @intCast(cell_x)) + glyph.bearing_x;
        const glyph_y = @as(i32, @intCast(cell_y)) + font.ascent - glyph.bearing_y;
        self.drawGlyph(glyph, glyph_x, glyph_y, fg);
    }
};
