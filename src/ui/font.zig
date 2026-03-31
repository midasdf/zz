const std = @import("std");

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub const GlyphBitmap = struct {
    pixels: []const u8, // 8-bit alpha values (owned copy)
    width: u16,
    height: u16,
    bearing_x: i16,
    bearing_y: i16,
    advance: u16, // Horizontal advance in pixels
};

pub const FontFace = struct {
    ft_lib: c.FT_Library,
    face: c.FT_Face,
    cell_width: u32, // Max advance (monospace: all glyphs same)
    cell_height: u32, // ascent + descent + 1
    ascent: i32,
    descent: i32,
    cache: std.AutoHashMap(u32, GlyphBitmap),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, font_path: [*:0]const u8, size_px: u32) !FontFace {
        var ft_lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_lib) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(ft_lib);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(ft_lib, font_path, 0, &face) != 0) return error.FontLoadFailed;
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) return error.SetSizeFailed;

        // Font metrics (26.6 fixed-point -> pixels)
        const metrics = face.*.size.*.metrics;
        const ascent: i32 = @intCast(@divTrunc(metrics.ascender, 64));
        const descent: i32 = @intCast(@divTrunc(-metrics.descender, 64));
        const cell_height: u32 = @intCast(ascent + descent + 1);

        // Load 'M' to get cell_width for monospace
        if (c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) != 0) return error.GlyphLoadFailed;
        const cell_width: u32 = @intCast(@divTrunc(face.*.glyph.*.advance.x, 64));

        var self = FontFace{
            .ft_lib = ft_lib,
            .face = face,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .ascent = ascent,
            .descent = descent,
            .cache = std.AutoHashMap(u32, GlyphBitmap).init(allocator),
            .allocator = allocator,
        };

        // Pre-cache printable ASCII
        for (0x20..0x7F) |cp| {
            _ = self.getGlyph(@intCast(cp)) catch {};
        }

        return self;
    }

    pub fn deinit(self: *FontFace) void {
        var it = self.cache.valueIterator();
        while (it.next()) |glyph| {
            if (glyph.pixels.len > 0) {
                self.allocator.free(glyph.pixels);
            }
        }
        self.cache.deinit();
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.ft_lib);
    }

    pub fn getGlyph(self: *FontFace, codepoint: u32) !GlyphBitmap {
        if (self.cache.get(codepoint)) |cached| return cached;

        // Load and render glyph
        if (c.FT_Load_Char(self.face, codepoint, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_LIGHT) != 0) {
            // Missing glyph: return empty bitmap with default advance
            const empty = GlyphBitmap{
                .pixels = &.{},
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = @intCast(self.cell_width),
            };
            try self.cache.put(codepoint, empty);
            return empty;
        }

        const glyph = self.face.*.glyph;
        const bitmap = glyph.*.bitmap;
        const w: u32 = bitmap.width;
        const h: u32 = bitmap.rows;

        var pixels: []u8 = &.{};
        if (w > 0 and h > 0 and bitmap.buffer != null) {
            pixels = try self.allocator.alloc(u8, w * h);
            const pitch: i32 = bitmap.pitch;

            if (pitch == @as(i32, @intCast(w))) {
                // Pitch matches width: single memcpy
                @memcpy(pixels, bitmap.buffer[0 .. w * h]);
            } else {
                // Pitch differs: copy row by row
                const src: [*]const u8 = bitmap.buffer;
                for (0..h) |row| {
                    const src_offset: usize = @intCast(@as(i32, @intCast(row)) * pitch);
                    const dst_offset: usize = row * w;
                    @memcpy(pixels[dst_offset..][0..w], src[src_offset..][0..w]);
                }
            }
        }

        const result = GlyphBitmap{
            .pixels = pixels,
            .width = @intCast(w),
            .height = @intCast(h),
            .bearing_x = @intCast(glyph.*.bitmap_left),
            .bearing_y = @intCast(glyph.*.bitmap_top),
            .advance = @intCast(@divTrunc(glyph.*.advance.x, 64)),
        };

        try self.cache.put(codepoint, result);
        return result;
    }
};
