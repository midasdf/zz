const std = @import("std");
const render_mod = @import("render.zig");
const Renderer = render_mod.Renderer;
const FontFace = @import("font.zig").FontFace;
const EditorView = @import("../editor/view.zig").EditorView;
const lsp = @import("../lsp/client.zig");

/// Render the LSP completion popup near the cursor.
pub fn renderCompletionPopup(
    renderer: *Renderer,
    font: *FontFace,
    items: []const lsp.CompletionItem,
    selected: usize,
    editor: *const EditorView,
) void {
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    if (cell_w == 0 or cell_h == 0 or items.len == 0) return;

    const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
    if (lc.line < editor.scroll_line) return;
    const screen_row = lc.line - editor.scroll_line;
    const vcol = editor.visualColAtOffset(lc.line, lc.col);
    const gw = editor.gutterWidth(font);
    const popup_x = editor.x_offset + gw + editor.left_pad + vcol * cell_w;
    const popup_y = editor.y_offset + (screen_row + 1) * cell_h;

    const max_items: u32 = @min(@as(u32, @intCast(items.len)), 10);
    const popup_w: u32 = 35 * cell_w;
    const popup_h: u32 = max_items * cell_h;

    const bg = render_mod.Color.fromHex(0x1e1e2e);
    const sel_bg = render_mod.Color.fromHex(0x45475a);
    const border = render_mod.Color.fromHex(0x585b70);
    const text_color = render_mod.Color.fromHex(0xcdd6f4);
    const detail_color = render_mod.Color.fromHex(0x6c7086);

    renderer.fillRect(popup_x -| 1, popup_y -| 1, popup_w + 2, popup_h + 2, border);
    renderer.fillRect(popup_x, popup_y, popup_w, popup_h, bg);

    var row: u32 = 0;
    for (items[0..max_items], 0..) |item, i| {
        const ry = popup_y + row * cell_h;
        const rbg = if (i == selected) sel_bg else bg;
        renderer.fillRect(popup_x, ry, popup_w, cell_h, rbg);

        var tx = popup_x + 4;
        for (item.label) |ch| {
            if (tx + cell_w > popup_x + popup_w) break;
            const glyph = font.getGlyph(ch) catch continue;
            const gx = @as(i32, @intCast(tx)) + glyph.bearing_x;
            const gy = @as(i32, @intCast(ry)) + font.ascent - glyph.bearing_y;
            renderer.drawGlyph(glyph, gx, gy, text_color);
            tx += cell_w;
        }

        if (item.detail) |detail| {
            tx += cell_w;
            for (detail) |ch| {
                if (tx + cell_w > popup_x + popup_w) break;
                const glyph = font.getGlyph(ch) catch continue;
                const gx = @as(i32, @intCast(tx)) + glyph.bearing_x;
                const gy = @as(i32, @intCast(ry)) + font.ascent - glyph.bearing_y;
                renderer.drawGlyph(glyph, gx, gy, detail_color);
                tx += cell_w;
            }
        }

        row += 1;
    }
}

/// Render an LSP hover tooltip near the cursor.
pub fn renderHoverTooltip(
    renderer: *Renderer,
    font: *FontFace,
    text: []const u8,
    editor: *const EditorView,
) void {
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    if (cell_w == 0 or cell_h == 0 or text.len == 0) return;

    const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
    if (lc.line < editor.scroll_line) return;
    const screen_row = lc.line - editor.scroll_line;
    const vcol = editor.visualColAtOffset(lc.line, lc.col);
    const gw = editor.gutterWidth(font);
    const tip_x = editor.x_offset + gw + editor.left_pad + vcol * cell_w;

    var line_count: u32 = 1;
    var max_line_len: u32 = 0;
    var cur_len: u32 = 0;
    for (text) |ch| {
        if (ch == '\n') {
            line_count += 1;
            if (cur_len > max_line_len) max_line_len = cur_len;
            cur_len = 0;
        } else {
            cur_len += 1;
        }
    }
    if (cur_len > max_line_len) max_line_len = cur_len;

    const tip_w = @min((max_line_len + 2) * cell_w, renderer.width * 7 / 10);
    const visible_lines = @min(line_count, 8);
    const tip_h = visible_lines * cell_h + 4;
    const tip_y = if (screen_row > 0 and editor.y_offset + (screen_row) * cell_h > tip_h)
        editor.y_offset + screen_row * cell_h - tip_h
    else
        editor.y_offset + (screen_row + 1) * cell_h;

    const bg = render_mod.Color.fromHex(0x1e1e2e);
    const border = render_mod.Color.fromHex(0x585b70);
    const text_color = render_mod.Color.fromHex(0xcdd6f4);

    renderer.fillRect(tip_x -| 1, tip_y -| 1, tip_w + 2, tip_h + 2, border);
    renderer.fillRect(tip_x, tip_y, tip_w, tip_h, bg);

    var ly: u32 = tip_y + 2;
    var lx: u32 = tip_x + cell_w / 2;
    var lines_drawn: u32 = 0;
    for (text) |ch| {
        if (lines_drawn >= visible_lines) break;
        if (ch == '\n') {
            ly += cell_h;
            lx = tip_x + cell_w / 2;
            lines_drawn += 1;
            continue;
        }
        if (lx + cell_w > tip_x + tip_w) continue;
        const glyph = font.getGlyph(ch) catch continue;
        const gx = @as(i32, @intCast(lx)) + glyph.bearing_x;
        const gy = @as(i32, @intCast(ly)) + font.ascent - glyph.bearing_y;
        renderer.drawGlyph(glyph, gx, gy, text_color);
        lx += cell_w;
    }
}

/// Render the LSP signature help tooltip near the cursor.
pub fn renderSignatureHelp(
    renderer: *Renderer,
    font: *FontFace,
    sig: lsp.SignatureInfo,
    editor: *const EditorView,
) void {
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    if (cell_w == 0 or cell_h == 0 or sig.label.len == 0) return;

    const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
    if (lc.line < editor.scroll_line) return;
    const screen_row = lc.line - editor.scroll_line;
    const vcol = editor.visualColAtOffset(lc.line, lc.col);
    const gw = editor.gutterWidth(font);
    const popup_x = editor.x_offset + gw + editor.left_pad + vcol * cell_w;
    const popup_w = @as(u32, @intCast(sig.label.len)) * cell_w + 16;
    const popup_h = cell_h + 8;

    // Position above cursor if possible, else below
    const popup_y = if (screen_row > 0 and editor.y_offset + screen_row * cell_h > popup_h + 4)
        editor.y_offset + screen_row * cell_h - popup_h - 4
    else
        editor.y_offset + (screen_row + 1) * cell_h;

    const bg = render_mod.Color.fromHex(0x313244);
    const border = render_mod.Color.fromHex(0x585b70);
    const text_color = render_mod.Color.fromHex(0xcdd6f4);
    const highlight_color = render_mod.Color.fromHex(0xf9e2af); // Yellow for active param

    renderer.fillRect(popup_x -| 1, popup_y -| 1, popup_w + 2, popup_h + 2, border);
    renderer.fillRect(popup_x, popup_y, popup_w, popup_h, bg);

    // Render signature text with highlighted active parameter
    var x = popup_x + 8;
    const y = popup_y + 4;

    for (sig.label, 0..) |ch, i| {
        const color = if (sig.param_offsets) |offsets|
            (if (i >= offsets.start and i < offsets.end) highlight_color else text_color)
        else
            text_color;

        const glyph = font.getGlyph(ch) catch continue;
        const gx: i32 = @intCast(x);
        const gy: i32 = @as(i32, @intCast(y)) + font.ascent - glyph.bearing_y;
        renderer.drawGlyph(glyph, gx, gy, color);
        x += cell_w;
    }
}
