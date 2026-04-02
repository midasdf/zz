const std = @import("std");
const view_mod = @import("view.zig");
const EditorView = view_mod.EditorView;
const Theme = view_mod.Theme;
const Highlighter = view_mod.Highlighter;
const SyntaxKind = @import("highlight.zig").SyntaxKind;
const Renderer = @import("../ui/render.zig").Renderer;
const Color = @import("../ui/render.zig").Color;
const FontFace = @import("../ui/font.zig").FontFace;
const CursorState = @import("cursor.zig").CursorState;
const Diagnostic = @import("../lsp/client.zig").Diagnostic;
const TabManager = @import("tabs.zig").TabManager;

// ═══════════════════════════════════════════════════════════════
// SECTION: Main render entry point
// ═══════════════════════════════════════════════════════════════

pub fn render(self: *EditorView, renderer: *Renderer, font: *FontFace) void {
    const active_theme = view_mod.getActiveTheme();
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return;

    const xo = self.x_offset; // pane x origin
    const pw = self.paneWidth(renderer.width); // pane pixel width
    const gw = self.gutterWidth(font);
    const code_x = xo + gw; // code area starts right after gutter
    const total_lines = self.buffer.lineCount();

    // Primary cursor position info (for current-line highlight + status bar)
    const cursor_pos = self.cursor.primary().head;
    const cursor_lc = self.buffer.offsetToLineCol(cursor_pos);

    // Multi-cursor: check if ANY cursor has a selection
    var has_sel = false;
    for (self.cursor.cursors.items) |c| {
        if (c.hasSelection()) {
            has_sel = true;
            break;
        }
    }

    // Walk through buffer to find the byte offset for scroll_line.
    // We compute it once via lineToOffset for the first visible line,
    // then track byte_offset incrementally per row.
    var byte_offset: u32 = self.buffer.lineToOffset(self.scroll_line);

    // Query tree-sitter highlights for visible range (extended for minimap)
    var query_start = byte_offset;
    var query_end = byte_offset;
    {
        // Compute end of visible code area
        var skip_line: u32 = 0;
        var tmp_off = byte_offset;
        while (skip_line < self.visible_rows and tmp_off < self.buffer.total_len) {
            const sl = self.buffer.contiguousSliceAt(tmp_off);
            if (sl.len == 0) break;
            if (std.mem.indexOfScalar(u8, sl, '\n')) |nl| {
                tmp_off += @intCast(nl + 1);
                skip_line += 1;
            } else {
                tmp_off += @intCast(sl.len);
            }
        }
        query_end = tmp_off;

        // Extend range for minimap (which may show lines beyond viewport)
        if (self.minimap_visible and cell_h > 0) {
            const mm_h = self.visible_rows * cell_h;
            const line_height: u32 = 2;
            const max_mm_lines = mm_h / line_height;
            if (max_mm_lines > 0) {
                const center = self.scroll_line + self.visible_rows / 2;
                const half = max_mm_lines / 2;
                var mm_start: u32 = 0;
                if (center > half) mm_start = center - half;
                if (mm_start + max_mm_lines > total_lines and total_lines > max_mm_lines) {
                    mm_start = total_lines - max_mm_lines;
                }
                const mm_end = @min(mm_start + max_mm_lines, total_lines);

                // Extend query_start backwards if minimap starts before viewport
                if (mm_start < self.scroll_line) {
                    query_start = self.buffer.lineToOffset(mm_start);
                }
                // Extend query_end forwards if minimap ends after viewport
                if (mm_end > self.scroll_line + self.visible_rows) {
                    var ext_off = query_end;
                    var ext_lines: u32 = 0;
                    const extra = mm_end - (self.scroll_line + self.visible_rows);
                    while (ext_lines < extra and ext_off < self.buffer.total_len) {
                        const sl = self.buffer.contiguousSliceAt(ext_off);
                        if (sl.len == 0) break;
                        if (std.mem.indexOfScalar(u8, sl, '\n')) |nl| {
                            ext_off += @as(u32, @intCast(nl)) + 1;
                            ext_lines += 1;
                        } else {
                            ext_off += @as(u32, @intCast(sl.len));
                        }
                    }
                    query_end = ext_off;
                }
            }
        }
    }
    self.highlighter.queryRange(query_start, query_end);

    // Find matching bracket position (computed once per frame)
    const match_pos = self.findMatchingBracket();
    const match_lc = if (match_pos) |mp| self.buffer.offsetToLineCol(mp) else null;

    // ── Word occurrence highlighting ──────────────────────────────
    var word_highlights: [64]WordHighlight = undefined;
    var word_hl_count: u32 = 0;

    if (!has_sel and cursor_pos < self.buffer.total_len) {
        // Find word boundaries at cursor
        const cursor_slice = self.buffer.contiguousSliceAt(cursor_pos);
        if (cursor_slice.len > 0 and view_mod.isWordChar(cursor_slice[0])) {
            var ws = cursor_pos;
            while (ws > 0) {
                const s = self.buffer.contiguousSliceAt(ws - 1);
                if (s.len == 0 or !view_mod.isWordChar(s[0])) break;
                ws -= 1;
            }
            var we = cursor_pos;
            while (we < self.buffer.total_len) {
                const s = self.buffer.contiguousSliceAt(we);
                if (s.len == 0 or !view_mod.isWordChar(s[0])) break;
                we += 1;
            }

            const word_len = we - ws;
            if (word_len >= 2 and word_len <= 128) {
                // Collect word bytes from piece table
                var word_buf: [128]u8 = undefined;
                {
                    var wi: u32 = 0;
                    var wo = ws;
                    while (wi < word_len) {
                        const s = self.buffer.contiguousSliceAt(wo);
                        if (s.len == 0) break;
                        const n = @min(@as(u32, @intCast(s.len)), word_len - wi);
                        @memcpy(word_buf[wi..][0..n], s[0..n]);
                        wi += n;
                        wo += n;
                    }
                }
                const word = word_buf[0..word_len];

                // Search for occurrences in the visible byte range
                const vis_start = query_start;
                const vis_end_off = query_end;
                var search_pos = vis_start;
                while (search_pos + word_len <= vis_end_off and word_hl_count < 64) {
                    // Check if content at search_pos matches the word
                    var matches = true;
                    var mi: u32 = 0;
                    var mo = search_pos;
                    while (mi < word_len) {
                        const s = self.buffer.contiguousSliceAt(mo);
                        if (s.len == 0) {
                            matches = false;
                            break;
                        }
                        const n = @min(@as(u32, @intCast(s.len)), word_len - mi);
                        if (!std.mem.eql(u8, s[0..n], word[mi..][0..n])) {
                            matches = false;
                            break;
                        }
                        mi += n;
                        mo += n;
                    }

                    if (matches) {
                        // Check word boundaries
                        const before_ok = search_pos == 0 or blk: {
                            const bs = self.buffer.contiguousSliceAt(search_pos - 1);
                            break :blk bs.len == 0 or !view_mod.isWordChar(bs[0]);
                        };
                        const after_ok = search_pos + word_len >= self.buffer.total_len or blk: {
                            const as2 = self.buffer.contiguousSliceAt(search_pos + word_len);
                            break :blk as2.len == 0 or !view_mod.isWordChar(as2[0]);
                        };
                        if (before_ok and after_ok) {
                            word_highlights[word_hl_count] = .{
                                .start = search_pos,
                                .end = search_pos + word_len,
                            };
                            word_hl_count += 1;
                        }
                        search_pos += 1;
                    } else {
                        search_pos += 1;
                    }
                }
            }
        }
    }

    // Compute starting doc_line from scroll_line, accounting for folds.
    // byte_offset already points to scroll_line.
    var screen_row: u32 = 0;
    var doc_line: u32 = self.scroll_line;
    while (screen_row < self.visible_rows) : (screen_row += 1) {
        // Skip folded lines (lines hidden inside a fold range)
        while (doc_line < total_lines and self.isLineFolded(doc_line)) {
            byte_offset = self.advancePastLine(byte_offset);
            doc_line += 1;
        }

        const row_y = self.y_offset + screen_row * cell_h;

        // Skip clean rows -- but we must advance byte_offset past this line
        if (screen_row < self.dirty_rows.len and !self.dirty_rows[screen_row]) {
            // Advance byte_offset past this line by scanning for newline
            if (doc_line < total_lines) {
                byte_offset = self.advancePastLine(byte_offset);
            }
            doc_line += 1;
            continue;
        }

        const is_current_line = (doc_line == cursor_lc.line);
        const line_bg = if (is_current_line) active_theme.surface0 else active_theme.base;

        // Clear the entire row (gutter + code area) within this pane
        renderer.fillRect(xo, row_y, pw, cell_h, line_bg);

        // -- Gutter: line number --
        if (doc_line < total_lines) {
            renderGutterNumber(self, renderer, font, doc_line, screen_row, is_current_line);
        }

        // -- Fold indicator in gutter --
        if (self.folded_lines.get(doc_line)) |_| {
            // Draw fold indicator: ">" in gutter area
            const fold_x = xo + 2;
            if (font.getGlyph('>')) |glyph| {
                const gx = @as(i32, @intCast(fold_x)) + glyph.bearing_x;
                const gy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                renderer.drawGlyph(glyph, gx, gy, active_theme.peach);
            } else |_| {}
        }

        // -- Git diff gutter marker (2px bar at left edge of gutter) --
        if (self.git_info) |gi| {
            if (doc_line < total_lines) {
                if (gi.lineKind(doc_line)) |kind| {
                    const diff_color: Color = switch (kind) {
                        .added => active_theme.green,
                        .modified => active_theme.peach,
                        .deleted => active_theme.red,
                    };
                    renderer.fillRect(xo, row_y, 2, cell_h, diff_color);
                }
            }
        }

        // -- Gutter separator (1px vertical line) --
        const sep_x = xo + gw - self.left_pad / 2;
        renderer.fillRect(sep_x, row_y, 1, cell_h, active_theme.surface2);

        // -- Code area --
        if (doc_line < total_lines) {
            renderIndentGuides(self, renderer, font, byte_offset, screen_row, code_x);
            renderCodeLine(self, renderer, font, byte_offset, doc_line, screen_row, code_x, line_bg, has_sel, word_highlights[0..word_hl_count]);

            // -- Fold ellipsis indicator at end of fold-start line --
            if (self.folded_lines.get(doc_line)) |fold_end| {
                // Draw "... N lines" after line content
                const line_end_off = self.advancePastLine(byte_offset);
                const line_len_bytes = line_end_off - byte_offset;
                const approx_cols = @min(line_len_bytes, self.visible_cols);
                const ellipsis_x = code_x + self.left_pad + approx_cols * cell_w;
                var fold_buf: [24]u8 = undefined;
                const fold_count = fold_end - doc_line;
                const fold_str = std.fmt.bufPrint(&fold_buf, " ... {d} lines", .{fold_count}) catch "...";
                var fx = ellipsis_x;
                for (fold_str) |ch| {
                    if (font.getGlyph(ch)) |glyph| {
                        const gfx = @as(i32, @intCast(fx)) + glyph.bearing_x;
                        const gfy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                        renderer.drawGlyph(glyph, gfx, gfy, active_theme.overlay0);
                    } else |_| {}
                    fx += cell_w;
                }
            }

            // -- Diagnostic underlines --
            renderDiagnostics(self, renderer, font, doc_line, code_x, self.y_offset + screen_row * cell_h);

            // Advance byte_offset past this line
            byte_offset = self.advancePastLine(byte_offset);
        }

        // -- Cursors (thin 2px beam) -- draw for ALL cursors on this line
        if (self.cursor_visible) {
            for (self.cursor.cursors.items) |c| {
                const clc = self.buffer.offsetToLineCol(c.head);
                if (clc.line == doc_line) {
                    const vcol = self.visualColAtOffset(clc.line, clc.col);
                    const cursor_px_x = code_x + self.left_pad + vcol * cell_w;
                    renderer.fillRect(cursor_px_x, row_y, 2, cell_h, active_theme.rosewater);
                }
            }
        }

        // -- Matching bracket highlight --
        if (match_lc) |mlc| {
            if (mlc.line == doc_line) {
                const vcol = self.visualColAtOffset(mlc.line, mlc.col);
                const bx = code_x + self.left_pad + vcol * cell_w;
                // Background highlight
                renderer.fillRect(bx, row_y, cell_w, cell_h, active_theme.surface2);
                // Underline (2px at bottom)
                renderer.fillRect(bx, row_y + cell_h - 2, cell_w, 2, active_theme.lavender);
                // Re-draw the bracket character on top of the highlight
                if (match_pos) |mp| {
                    const ms = self.buffer.contiguousSliceAt(mp);
                    if (ms.len > 0 and ms[0] < 0x80) {
                        if (font.getGlyph(ms[0])) |glyph| {
                            const gx = @as(i32, @intCast(bx)) + glyph.bearing_x;
                            const gy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                            renderer.drawGlyph(glyph, gx, gy, active_theme.lavender);
                        } else |_| {}
                    }
                }
            }
        }

        // Mark row as clean
        if (screen_row < self.dirty_rows.len) {
            self.dirty_rows[screen_row] = false;
        }

        doc_line += 1;
    }

    // -- Sticky scroll (scope header pinned to top) --
    renderStickyScroll(self, renderer, font);

    // -- Minimap (code overview on right edge) --
    renderMinimap(self, renderer, font);

    // -- Scrollbar indicator --
    renderScrollbar(self, renderer, font);

    // -- Status bar --
    renderStatusBar(self, renderer, font, cursor_lc.line, cursor_lc.col);
}

// ═══════════════════════════════════════════════════════════════
// SECTION: Component renderers
// ═══════════════════════════════════════════════════════════════

fn renderStickyScroll(self: *const EditorView, renderer: *Renderer, font: *FontFace) void {
    const active_theme = view_mod.getActiveTheme();
    if (!self.sticky_scroll_visible) return;
    // Only show when scrolled past the first line
    if (self.scroll_line == 0) return;

    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return;

    const xo = self.x_offset;
    const pw = self.paneWidth(renderer.width);
    const gw = self.gutterWidth(font);
    const code_x = xo + gw;
    const sticky_y = self.y_offset;

    // Find the enclosing scope for the top visible line by walking
    // backward and tracking brace depth. The first line we find where
    // depth goes negative (more '{' than '}') is our scope header.
    var scope_line: ?u32 = null;
    var depth: i32 = 0;
    var search_line = self.scroll_line;
    const max_search: u32 = @min(search_line, 200);
    var searched: u32 = 0;
    while (search_line > 0 and searched < max_search) {
        search_line -= 1;
        searched += 1;
        const ls = self.buffer.lineToOffset(search_line);
        const le = if (search_line + 1 < self.buffer.lineCount())
            self.buffer.lineToOffset(search_line + 1)
        else
            self.buffer.total_len;

        var line_has_open = false;
        var off = ls;
        while (off < le) {
            const s = self.buffer.contiguousSliceAt(off);
            if (s.len == 0) break;
            const remaining: u32 = le - off;
            const n = @min(@as(u32, @intCast(s.len)), remaining);
            for (s[0..n]) |byte| {
                if (byte == '{') {
                    depth -= 1;
                    line_has_open = true;
                } else if (byte == '}') {
                    depth += 1;
                }
            }
            off += n;
        }
        if (depth < 0 and line_has_open) {
            scope_line = search_line;
            break;
        }
    }

    const sl = scope_line orelse return;

    // Don't show sticky scroll if the scope line is visible on screen
    if (sl >= self.scroll_line and sl < self.scroll_line + self.visible_rows) return;

    // Background overlay
    renderer.fillRect(xo, sticky_y, pw, cell_h, active_theme.mantle);

    // Render gutter number for the scope line
    renderGutterNumber(self, renderer, font, sl, 0, false);

    // Render code content
    const line_start = self.buffer.lineToOffset(sl);
    var empty_wh: [0]WordHighlight = undefined;
    renderCodeLine(self, renderer, font, line_start, sl, 0, code_x, active_theme.mantle, false, &empty_wh);

    // Bottom border
    renderer.fillRect(xo, sticky_y + cell_h - 1, pw, 1, active_theme.surface2);
}

fn renderMinimap(self: *const EditorView, renderer: *Renderer, font: *const FontFace) void {
    const active_theme = view_mod.getActiveTheme();
    if (!self.minimap_visible) return;

    const cell_h = font.cell_height;
    if (cell_h == 0) return;
    const pw = self.paneWidth(renderer.width);
    const mm_w = self.minimap_width;
    if (pw <= mm_w) return; // pane too narrow

    const mm_x = self.x_offset + pw - mm_w;
    const mm_y = self.y_offset;
    const mm_h = self.visible_rows * cell_h;

    // Minimap background
    renderer.fillRect(mm_x, mm_y, mm_w, mm_h, active_theme.mantle);

    // Left border (1px)
    renderer.fillRect(mm_x, mm_y, 1, mm_h, active_theme.surface2);

    const total_lines = self.buffer.lineCount();
    const line_height: u32 = 2; // Each doc line = 2px in minimap
    const max_minimap_lines = mm_h / line_height;
    if (max_minimap_lines == 0) return;

    // Determine which document lines to show, centered around viewport
    const center_line = self.scroll_line + self.visible_rows / 2;
    const half_range = max_minimap_lines / 2;
    var mm_start: u32 = 0;
    if (center_line > half_range) {
        mm_start = center_line - half_range;
    }
    // Clamp so we don't go past the end
    if (mm_start + max_minimap_lines > total_lines and total_lines > max_minimap_lines) {
        mm_start = total_lines - max_minimap_lines;
    }
    const mm_end = @min(mm_start + max_minimap_lines, total_lines);

    // Draw viewport indicator (which lines are currently visible on screen)
    {
        const vp_start: u32 = if (self.scroll_line >= mm_start)
            mm_y + (self.scroll_line - mm_start) * line_height
        else
            mm_y;
        const vp_end_line = @min(self.scroll_line + self.visible_rows, mm_end);
        const vp_end: u32 = if (vp_end_line >= mm_start)
            mm_y + (vp_end_line - mm_start) * line_height
        else
            mm_y;
        const vp_h = if (vp_end > vp_start) vp_end - vp_start else 0;
        if (vp_h > 0) {
            renderer.fillRect(mm_x, vp_start, mm_w, vp_h, active_theme.surface0);
        }
    }

    // Walk buffer to find byte offset for mm_start line
    var byte_offset: u32 = self.buffer.lineToOffset(mm_start);

    // Usable columns inside minimap (leave 2px left padding after border)
    const mm_pad: u32 = 3; // left padding inside minimap
    const mm_cols = if (mm_w > mm_pad + 1) mm_w - mm_pad - 1 else 1;

    // Draw each line as a thin colored strip
    var line: u32 = mm_start;
    while (line < mm_end) : (line += 1) {
        const y = mm_y + (line - mm_start) * line_height;

        var col: u32 = 0;
        var off = byte_offset;
        var hit_newline = false;
        while (col < mm_cols and off < self.buffer.total_len) {
            const slice = self.buffer.contiguousSliceAt(off);
            if (slice.len == 0) break;
            if (slice[0] == '\n') {
                off += 1;
                hit_newline = true;
                break;
            }

            if (slice[0] == ' ') {
                col += 1;
                off += 1;
            } else if (slice[0] == '\t') {
                col += 4;
                off += 1;
            } else {
                // Get syntax color for this position
                const syn = self.highlighter.getSyntaxAt(off);
                const fg = syntaxColor(syn);

                const px_x = mm_x + mm_pad + col;
                if (px_x < mm_x + mm_w) {
                    renderer.fillRect(px_x, y, 1, line_height, fg);
                }
                col += 1;
                off += 1;

                // Skip continuation bytes of multi-byte UTF-8
                while (off < self.buffer.total_len) {
                    const s2 = self.buffer.contiguousSliceAt(off);
                    if (s2.len == 0) break;
                    if ((s2[0] & 0xC0) != 0x80) break;
                    off += 1;
                }
            }
        }

        // Advance past rest of line if we stopped early (line longer than minimap)
        if (!hit_newline) {
            while (off < self.buffer.total_len) {
                const s = self.buffer.contiguousSliceAt(off);
                if (s.len == 0) break;
                if (std.mem.indexOfScalar(u8, s, '\n')) |nl| {
                    off += @as(u32, @intCast(nl)) + 1;
                    break;
                }
                off += @as(u32, @intCast(s.len));
            }
        }
        byte_offset = off;
    }
}

fn renderScrollbar(self: *const EditorView, renderer: *Renderer, font: *const FontFace) void {
    const active_theme = view_mod.getActiveTheme();
    const cell_h = font.cell_height;
    if (cell_h == 0) return;

    const total_lines = self.buffer.lineCount();
    if (total_lines <= self.visible_rows) return; // No scrollbar needed

    const pw = self.paneWidth(renderer.width);
    const mm_offset: u32 = if (self.minimap_visible) self.minimap_width else 0;
    if (pw <= mm_offset + 8) return; // pane too narrow
    const bar_x = self.x_offset + pw - mm_offset - 8;
    const bar_y = self.y_offset;
    const bar_h = self.visible_rows * cell_h;
    const bar_w: u32 = 6;

    // Track background (very subtle)
    renderer.fillRect(bar_x, bar_y, bar_w, bar_h, active_theme.surface0);

    // Thumb: proportional to visible fraction, min 20px
    const total_f = @as(f32, @floatFromInt(total_lines));
    const visible_f = @as(f32, @floatFromInt(self.visible_rows));
    const bar_h_f = @as(f32, @floatFromInt(bar_h));
    const thumb_ratio = visible_f / total_f;
    const thumb_h_f = @min(@max(bar_h_f * thumb_ratio, 20.0), bar_h_f);
    const thumb_h: u32 = @intFromFloat(thumb_h_f);

    const max_scroll = total_lines - self.visible_rows;
    if (max_scroll == 0) return;
    const scroll_ratio = @as(f32, @floatFromInt(self.scroll_line)) / @as(f32, @floatFromInt(max_scroll));
    const thumb_travel = @max(bar_h_f - thumb_h_f, 0.0);
    const thumb_y_offset: u32 = @intFromFloat(thumb_travel * scroll_ratio);
    const thumb_y = bar_y + thumb_y_offset;

    renderer.fillRect(bar_x, thumb_y, bar_w, thumb_h, active_theme.overlay0);
}

fn renderIndentGuides(self: *const EditorView, renderer: *Renderer, font: *const FontFace, line_start_offset: u32, screen_row: u32, code_x: u32) void {
    const active_theme = view_mod.getActiveTheme();
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return;
    const row_y = self.y_offset + screen_row * cell_h;
    const tab_size: u32 = 4;

    // Count leading whitespace (in columns)
    var indent: u32 = 0;
    var off = line_start_offset;
    while (off < self.buffer.total_len) {
        const s = self.buffer.contiguousSliceAt(off);
        if (s.len == 0) break;
        if (s[0] == ' ') {
            indent += 1;
            off += 1;
        } else if (s[0] == '\t') {
            indent = ((indent / tab_size) + 1) * tab_size;
            off += 1;
        } else {
            break;
        }
    }

    // Draw vertical guide lines at each tab stop within the indent
    const guide_color = active_theme.surface2;
    var level: u32 = tab_size;
    while (level < indent) : (level += tab_size) {
        const guide_x = code_x + self.left_pad + level * cell_w;
        renderer.fillRect(guide_x, row_y, 1, cell_h, guide_color);
    }
}

fn renderDiagnostics(
    self: *const EditorView,
    renderer: *Renderer,
    font: *FontFace,
    doc_line: u32,
    code_x: u32,
    row_y: u32,
) void {
    const active_theme = view_mod.getActiveTheme();
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return;

    const underline_y = row_y + cell_h - 2; // 2px from bottom of cell
    const pad = self.left_pad;

    for (self.lsp_diagnostics) |diag| {
        if (diag.line != doc_line) continue;

        const color: Color = switch (diag.severity) {
            .err => active_theme.red,
            .warning => active_theme.peach,
            .info => active_theme.lavender,
            .hint => active_theme.overlay0,
        };

        // Convert byte columns to visual columns for underline placement
        const vis_start = self.visualColAtOffset(doc_line, diag.col_start);
        const vis_end_col = if (diag.col_end > diag.col_start)
            self.visualColAtOffset(doc_line, diag.col_end)
        else
            vis_start + 1;

        const start_px = code_x + pad + vis_start * cell_w;
        const width_px = (vis_end_col - vis_start) * cell_w;

        if (width_px == 0) continue;

        // Draw a 2px underline
        renderer.fillRect(start_px, underline_y, width_px, 2, color);
    }
}

fn renderGutterNumber(
    self: *const EditorView,
    renderer: *Renderer,
    font: *FontFace,
    doc_line: u32,
    screen_row: u32,
    is_current: bool,
) void {
    const active_theme = view_mod.getActiveTheme();
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    const row_y = self.y_offset + screen_row * cell_h;
    const xo = self.x_offset;

    const fg_color = if (is_current) active_theme.lavender else active_theme.overlay0;
    const line_bg = if (is_current) active_theme.surface0 else active_theme.base;

    // Line number (1-based, right-aligned)
    const line_num = doc_line + 1;
    var num_buf: [12]u8 = undefined;
    const num_str = formatU32(line_num, &num_buf);

    // Calculate gutter digit columns (excluding separator padding)
    const digit_cols = self.gutterDigits();

    // Right-align: start at (digit_cols - num_str.len)
    const padding_cols: u32 = if (digit_cols > num_str.len) digit_cols - @as(u32, @intCast(num_str.len)) else 0;

    for (num_str, 0..) |ch, i| {
        const col_x = xo + (padding_cols + @as(u32, @intCast(i))) * cell_w;
        renderer.fillRect(col_x, row_y, cell_w, cell_h, line_bg);
        const glyph = font.getGlyph(ch) catch continue;
        const glyph_x = @as(i32, @intCast(col_x)) + glyph.bearing_x;
        const glyph_y = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
        renderer.drawGlyph(glyph, glyph_x, glyph_y, fg_color);
    }
}

const WordHighlight = struct { start: u32, end: u32 };
const word_hl_bg = Color.fromHex(0x3b3d54); // Subtle word occurrence highlight

fn renderCodeLine(
    self: *const EditorView,
    renderer: *Renderer,
    font: *FontFace,
    line_start_offset: u32,
    doc_line: u32,
    screen_row: u32,
    code_x: u32,
    line_bg: Color,
    has_sel: bool,
    word_highlights: []const WordHighlight,
) void {
    const active_theme = view_mod.getActiveTheme();
    _ = doc_line;
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    const row_y = self.y_offset + screen_row * cell_h;
    const pad = self.left_pad;

    var col: u32 = 0;
    var offset = line_start_offset;
    var last_non_ws_col: u32 = 0; // Track last non-whitespace column for trailing ws highlight

    while (col < self.visible_cols) {
        if (offset >= self.buffer.total_len) break;

        const slice = self.buffer.contiguousSliceAt(offset);
        if (slice.len == 0) break;

        const byte = slice[0];

        // Stop at end of line
        if (byte == '\n') break;

        // Determine background: selection > word highlight > current-line
        var cell_bg = line_bg;
        if (has_sel and self.isInAnySelection(offset)) {
            cell_bg = active_theme.surface1;
        } else if (isInWordHighlight(offset, word_highlights)) {
            cell_bg = word_hl_bg;
        }

        // Determine syntax color for this byte position
        const syn = self.highlighter.getSyntaxAt(offset);
        const fg = syntaxColor(syn);

        if (byte == '\t') {
            // Render tab as spaces to next 4-column tab stop
            const tab_stop = 4;
            const next_tab = ((col / tab_stop) + 1) * tab_stop;
            const spaces = @min(next_tab - col, self.visible_cols - col);
            // Fill tab background
            renderer.fillRect(code_x + pad + col * cell_w, row_y, spaces * cell_w, cell_h, cell_bg);
            col += spaces;
            offset += 1;
        } else if (byte < 0x80) {
            // ASCII character -- fast path
            const px_x = code_x + pad + col * cell_w;
            renderer.fillRect(px_x, row_y, cell_w, cell_h, cell_bg);
            const glyph = font.getGlyph(byte) catch {
                col += 1;
                offset += 1;
                continue;
            };
            const glyph_x = @as(i32, @intCast(px_x)) + glyph.bearing_x;
            const glyph_y = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
            renderer.drawGlyph(glyph, glyph_x, glyph_y, fg);
            if (byte != ' ') last_non_ws_col = col + 1;
            col += 1;
            offset += 1;
        } else {
            // Multi-byte UTF-8 codepoint
            const cp_len = CursorState.utf8ByteLen(byte);
            if (cp_len > @as(u32, @intCast(slice.len))) {
                // Incomplete codepoint at piece boundary -- skip
                offset += 1;
                col += 1;
                continue;
            }
            const codepoint = decodeUtf8(slice[0..@intCast(cp_len)]);
            const px_x = code_x + pad + col * cell_w;

            // Check if this is a wide (CJK) character -- assume 2 cells
            const char_cells: u32 = if (isWide(codepoint)) 2 else 1;
            const char_width = char_cells * cell_w;

            // Fill background for all cells this char occupies
            // For selection: check if any byte of this char is in selection
            renderer.fillRect(px_x, row_y, char_width, cell_h, cell_bg);

            const glyph = font.getGlyph(codepoint) catch {
                col += char_cells;
                offset += cp_len;
                continue;
            };
            const glyph_x = @as(i32, @intCast(px_x)) + glyph.bearing_x;
            const glyph_y = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
            renderer.drawGlyph(glyph, glyph_x, glyph_y, fg);

            last_non_ws_col = col + char_cells;
            col += char_cells;
            offset += cp_len;
        }
    }

    // Highlight trailing whitespace (spaces/tabs at end of line) with a subtle reddish tint
    if (last_non_ws_col < col) {
        const trailing_ws_bg = Color.fromHex(0x45293a); // Subtle dark red tint
        const ws_x = code_x + pad + last_non_ws_col * cell_w;
        const ws_w = (col - last_non_ws_col) * cell_w;
        renderer.fillRect(ws_x, row_y, ws_w, cell_h, trailing_ws_bg);
    }
}

fn renderStatusBar(self: *EditorView, renderer: *Renderer, font: *FontFace, cursor_line: u32, cursor_col: u32) void {
    const active_theme = view_mod.getActiveTheme();
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    const xo = self.x_offset;
    const pw = self.paneWidth(renderer.width);

    // Status bar: 1px top border + cell_height + 4px vertical padding
    const bar_pad: u32 = 4; // 2px top + 2px bottom padding
    const status_y = self.y_offset + self.visible_rows * cell_h;

    // Store status bar Y for click detection
    self.status_bar_y = status_y;

    // Top border (1px surface2) — subtle separator
    renderer.fillRect(xo, status_y, pw, 1, active_theme.surface2);

    // Status bar background — fill from separator to bottom of window
    const bar_y = status_y + 1;
    const bar_h = if (renderer.height > bar_y) renderer.height - bar_y else cell_h + bar_pad;
    renderer.fillRect(xo, bar_y, pw, bar_h, active_theme.mantle);

    // Text baseline — vertically centered in the bar
    const text_y = bar_y + bar_pad / 2;

    // -- Left section: git branch + file path --
    var left_col: u32 = 1; // 1-col left margin

    // Git branch icon + name in lavender
    const branch_name = if (self.git_info) |gi| gi.branchName() else "";
    if (branch_name.len > 0) {
        // Branch icon: U+E0A0 (Powerline branch symbol) or fallback '*'
        const branch_icon: u32 = 0xE0A0;
        if (font.getGlyph(branch_icon)) |glyph| {
            const px_x = xo + left_col * cell_w;
            const gx = @as(i32, @intCast(px_x)) + glyph.bearing_x;
            const gy = @as(i32, @intCast(text_y)) + font.ascent - glyph.bearing_y;
            renderer.drawGlyph(glyph, gx, gy, active_theme.lavender);
        } else |_| {
            // Fallback: draw '*' as branch indicator
            drawStatusChar(self, renderer, font, '*', left_col, text_y, active_theme.lavender);
        }
        left_col += 1;
        // Space after icon
        left_col += 1;
        // Branch name in lavender
        for (branch_name) |ch| {
            if (left_col >= self.visible_cols) break;
            drawStatusChar(self, renderer, font, ch, left_col, text_y, active_theme.lavender);
            left_col += 1;
        }
        // Separator
        const sep = "  |  ";
        for (sep) |ch| {
            if (left_col >= self.visible_cols) break;
            drawStatusChar(self, renderer, font, ch, left_col, text_y, active_theme.surface2);
            left_col += 1;
        }
    }

    // File path with breadcrumb separators (/ -> " > ")
    const name = self.file_path orelse "[untitled]";
    for (name) |ch| {
        if (left_col >= self.visible_cols) break;
        if (ch == '/' or ch == '\\') {
            // Render " > " separator instead of slash
            for (" > ") |sep_ch| {
                if (left_col >= self.visible_cols) break;
                drawStatusChar(self, renderer, font, sep_ch, left_col, text_y, active_theme.overlay0);
                left_col += 1;
            }
        } else {
            drawStatusChar(self, renderer, font, ch, left_col, text_y, active_theme.subtext0);
            left_col += 1;
        }
    }

    if (self.modified) {
        const mod_str = " [+]";
        for (mod_str) |ch| {
            if (left_col >= self.visible_cols) break;
            const color = if (ch == '+') active_theme.green else active_theme.subtext0;
            drawStatusChar(self, renderer, font, ch, left_col, text_y, color);
            left_col += 1;
        }
    }

    // -- Selection info (center) --
    const sel = self.cursor.primary();
    var sel_info_buf: [48]u8 = undefined;
    var sel_info_len: usize = 0;
    if (sel.hasSelection()) {
        // Count UTF-8 codepoints in selection
        var sel_chars: u32 = 0;
        {
            var cp_off = sel.start();
            while (cp_off < sel.end()) {
                const s = self.buffer.contiguousSliceAt(cp_off);
                if (s.len == 0) break;
                const byte_len = CursorState.utf8ByteLen(s[0]);
                sel_chars += 1;
                cp_off += byte_len;
            }
        }
        // Count newlines in selection
        var newlines: u32 = 0;
        var scan = sel.start();
        while (scan < sel.end()) {
            const s = self.buffer.contiguousSliceAt(scan);
            if (s.len == 0) break;
            const chunk = @min(s.len, sel.end() - scan);
            for (s[0..chunk]) |ch| {
                if (ch == '\n') newlines += 1;
            }
            scan += @intCast(chunk);
        }
        if (newlines > 0) {
            var nl_buf: [12]u8 = undefined;
            const nl_str = formatU32(newlines + 1, &nl_buf);
            var ch_buf: [12]u8 = undefined;
            const ch_str = formatU32(sel_chars, &ch_buf);
            const parts = [_][]const u8{ nl_str, " lines, ", ch_str, " chars" };
            for (parts) |part| {
                @memcpy(sel_info_buf[sel_info_len..][0..part.len], part);
                sel_info_len += part.len;
            }
        } else {
            var ch_buf: [12]u8 = undefined;
            const ch_str = formatU32(sel_chars, &ch_buf);
            const parts = [_][]const u8{ ch_str, " chars" };
            for (parts) |part| {
                @memcpy(sel_info_buf[sel_info_len..][0..part.len], part);
                sel_info_len += part.len;
            }
        }
        // Render selection info after the left section with a separator
        const sel_sep = "   ";
        for (sel_sep) |ch| {
            if (left_col >= self.visible_cols) break;
            drawStatusChar(self, renderer, font, ch, left_col, text_y, active_theme.surface2);
            left_col += 1;
        }
        for (sel_info_buf[0..sel_info_len]) |ch| {
            if (left_col >= self.visible_cols) break;
            drawStatusChar(self, renderer, font, ch, left_col, text_y, active_theme.lavender);
            left_col += 1;
        }
    }

    // -- Right section: language, line:col, encoding --
    const lang_name = self.highlighter.languageName();
    var right_buf: [192]u8 = undefined;
    const right_str = formatStatusRight(cursor_line + 1, cursor_col + 1, lang_name, "", &right_buf);
    const right_len: u32 = @intCast(right_str.len);

    // -- Action buttons (rendered right-of-center, before the right info section) --
    // Layout: ... [Terminal] [! N] [*] ...  Zig  Ln 1, Col 5  UTF-8
    // We place buttons just left of the right section.
    const btn_pad: u32 = 2; // columns of padding around each button

    // Compute button labels
    // Use simple ASCII labels for reliable rendering
    const term_text: []const u8 = if (self.status_terminal_visible) "Terminal v" else "Terminal >";
    const term_text_len: u32 = @intCast(term_text.len);

    var diag_buf: [20]u8 = undefined;
    const diag_count = self.status_diagnostic_count;
    // Format: "! N" or "0" when no issues
    var diag_pos: usize = 0;
    if (diag_count > 0) {
        diag_buf[0] = '!';
        diag_buf[1] = ' ';
        diag_pos = 2;
        var count_buf: [12]u8 = undefined;
        const count_str = formatU32(diag_count, &count_buf);
        @memcpy(diag_buf[diag_pos..][0..count_str.len], count_str);
        diag_pos += count_str.len;
    } else {
        const no_issues = "0 issues";
        @memcpy(diag_buf[0..no_issues.len], no_issues);
        diag_pos = no_issues.len;
    }
    const diag_text = diag_buf[0..diag_pos];
    const diag_text_len: u32 = @intCast(diag_text.len);

    const gear_text: []const u8 = "*";
    const gear_text_len: u32 = 1;

    // Total button area width in columns: pad + term + pad + pad + diag + pad + pad + gear + pad
    const btn_total_cols = btn_pad + term_text_len + btn_pad + 1 + btn_pad + diag_text_len + btn_pad + 1 + btn_pad + gear_text_len + btn_pad;

    // Place buttons so they end just before the right section
    const right_start = if (pw / cell_w > right_len + 1) pw / cell_w - right_len - 1 else 0;
    const btn_start_col = if (right_start > btn_total_cols + 2) right_start - btn_total_cols - 2 else left_col + 2;

    // Only render buttons if there's room between left and right sections
    if (btn_start_col > left_col + 1) {
        var bcol = btn_start_col;

        // -- Terminal button with subtle background --
        const term_btn_x = xo + bcol * cell_w;
        const term_bg = if (self.status_terminal_visible) active_theme.surface1 else active_theme.surface0;
        const term_fg = if (self.status_terminal_visible) active_theme.lavender else active_theme.overlay0;
        // Button background: slight highlight
        renderer.fillRect(term_btn_x, bar_y + 1, (term_text_len + btn_pad * 2) * cell_w, bar_h -| 2, term_bg);
        bcol += btn_pad;
        for (term_text) |ch| {
            if (bcol >= self.visible_cols) break;
            drawStatusChar(self, renderer, font, ch, bcol, text_y, term_fg);
            bcol += 1;
        }
        bcol += btn_pad;
        const term_btn_w = (xo + bcol * cell_w) - term_btn_x;
        self.status_btn_terminal_x = term_btn_x;
        self.status_btn_terminal_w = term_btn_w;

        // Gap between buttons
        bcol += 1;

        // -- Diagnostics button with subtle background --
        const diag_btn_x = xo + bcol * cell_w;
        const diag_bg = if (diag_count > 0) active_theme.surface1 else active_theme.surface0;
        const diag_fg = if (diag_count > 0) active_theme.peach else active_theme.overlay0;
        renderer.fillRect(diag_btn_x, bar_y + 1, (diag_text_len + btn_pad * 2) * cell_w, bar_h -| 2, diag_bg);
        bcol += btn_pad;
        for (diag_text) |ch| {
            if (bcol >= self.visible_cols) break;
            drawStatusChar(self, renderer, font, ch, bcol, text_y, diag_fg);
            bcol += 1;
        }
        bcol += btn_pad;
        const diag_btn_w = (xo + bcol * cell_w) - diag_btn_x;
        self.status_btn_diag_x = diag_btn_x;
        self.status_btn_diag_w = diag_btn_w;

        // Gap between buttons
        bcol += 1;

        // -- Settings gear button --
        const gear_btn_x = xo + bcol * cell_w;
        renderer.fillRect(gear_btn_x, bar_y + 1, (gear_text_len + btn_pad * 2) * cell_w, bar_h -| 2, active_theme.surface0);
        bcol += btn_pad;
        for (gear_text) |ch| {
            if (bcol >= self.visible_cols) break;
            drawStatusChar(self, renderer, font, ch, bcol, text_y, active_theme.overlay0);
            bcol += 1;
        }
        bcol += btn_pad;
        const gear_btn_w = (xo + bcol * cell_w) - gear_btn_x;
        self.status_btn_gear_x = gear_btn_x;
        self.status_btn_gear_w = gear_btn_w;
    } else {
        // No room for buttons — clear hit-boxes
        self.status_btn_terminal_x = 0;
        self.status_btn_terminal_w = 0;
        self.status_btn_diag_x = 0;
        self.status_btn_diag_w = 0;
        self.status_btn_gear_x = 0;
        self.status_btn_gear_w = 0;
    }

    // -- Right section text --
    for (right_str, 0..) |ch, i| {
        const rcol = right_start + @as(u32, @intCast(i));
        if (rcol >= self.visible_cols) break;
        drawStatusChar(self, renderer, font, ch, rcol, text_y, active_theme.subtext0);
    }
}

fn drawStatusChar(
    self: *const EditorView,
    renderer: *Renderer,
    font: *FontFace,
    ch: u8,
    col: u32,
    bar_y: u32,
    fg: Color,
) void {
    const cell_w = font.cell_width;
    const px_x = self.x_offset + col * cell_w;
    const glyph = font.getGlyph(ch) catch return;
    const glyph_x = @as(i32, @intCast(px_x)) + glyph.bearing_x;
    const glyph_y = @as(i32, @intCast(bar_y)) + font.ascent - glyph.bearing_y;
    renderer.drawGlyph(glyph, glyph_x, glyph_y, fg);
}

// ═══════════════════════════════════════════════════════════════
// SECTION: Tab bar
// ═══════════════════════════════════════════════════════════════

/// Compute the tab bar height in pixels.
pub fn tabBarHeight(font: *const FontFace) u32 {
    return font.cell_height + 10; // cell height + top accent (2px) + padding (8px) -- taller Zed-like tabs
}

/// Render the tab bar at the top of the window.
pub fn renderTabBar(
    tab_mgr: *const TabManager,
    renderer: *Renderer,
    font: *FontFace,
    x_start: u32,
    hover_tab: ?usize,
) void {
    const active_theme = view_mod.getActiveTheme();
    const cell_w = font.cell_width;
    if (cell_w == 0 or font.cell_height == 0) return;

    const bar_h = tabBarHeight(font);
    const win_w = renderer.width;

    // Full bar background (mantle -- darker than editor)
    renderer.fillRect(0, 0, win_w, bar_h, active_theme.mantle);

    // Bottom separator (1px surface2)
    renderer.fillRect(0, bar_h - 1, win_w, 1, active_theme.surface2);

    // Render each tab (offset by sidebar width)
    var x: u32 = x_start + 4;
    for (tab_mgr.tabs.items, 0..) |tab, i| {
        const is_active = (i == tab_mgr.active);
        const is_hovered = if (hover_tab) |ht| ht == i else false;
        const bg = if (is_active) active_theme.base else if (is_hovered) active_theme.surface0 else active_theme.mantle;
        const fg = if (is_active) active_theme.text else if (is_hovered) active_theme.subtext0 else active_theme.overlay0;

        // Tab label
        const label = if (tab.file_path) |p| basename(p) else "[untitled]";
        const label_len: u32 = @intCast(label.len);
        const tab_w = computeTabWidth(label_len, tab.modified, cell_w);

        // Tab background (full height minus bottom separator)
        renderer.fillRect(x, 0, tab_w, bar_h - 1, bg);

        // Active tab: 2px lavender accent line at TOP
        if (is_active) {
            renderer.fillRect(x, 0, tab_w, 2, active_theme.lavender);
        }

        // Tab label text -- vertically centered
        const text_y: u32 = (bar_h - font.cell_height) / 2 + 1;
        var tx = x + cell_w + cell_w / 2; // 1.5-cell left padding
        for (label) |ch| {
            if (font.getGlyph(ch)) |glyph| {
                const gx: i32 = @intCast(tx);
                const gy: i32 = @as(i32, @intCast(text_y)) + font.ascent - @as(i32, glyph.bearing_y);
                renderer.drawGlyph(glyph, gx, gy, fg);
            } else |_| {}
            tx += cell_w;
        }

        // Modified indicator " +" in green
        if (tab.modified) {
            tx += cell_w; // space
            if (font.getGlyph('+')) |glyph| {
                const gx: i32 = @intCast(tx);
                const gy: i32 = @as(i32, @intCast(text_y)) + font.ascent - @as(i32, glyph.bearing_y);
                renderer.drawGlyph(glyph, gx, gy, active_theme.green);
            } else |_| {}
        }

        // Close button "×" — right side of tab (brighter on hover)
        {
            const close_btn_w_r: u32 = cell_w + cell_w / 2;
            const close_x = x + tab_w - close_btn_w_r;
            const close_fg = if (is_active or is_hovered) active_theme.overlay0 else active_theme.surface2;
            if (font.getGlyph('x')) |glyph| {
                const gx: i32 = @intCast(close_x + cell_w / 4);
                const gy: i32 = @as(i32, @intCast(text_y)) + font.ascent - @as(i32, glyph.bearing_y);
                renderer.drawGlyph(glyph, gx, gy, close_fg);
            } else |_| {}
        }

        x += tab_w + 1; // 1px gap between tabs
    }
}

/// Determine which tab index is at pixel position (click_x), or null.
pub fn tabAtPixel(tab_mgr: *const TabManager, click_x: i32, font: *const FontFace, x_start: u32) ?usize {
    const cell_w = font.cell_width;
    if (cell_w == 0) return null;

    var x: u32 = x_start + 4;
    for (tab_mgr.tabs.items, 0..) |tab, i| {
        const label = if (tab.file_path) |p| basename(p) else "[untitled]";
        const label_len: u32 = @intCast(label.len);
        const tab_w = computeTabWidth(label_len, tab.modified, cell_w);

        const tab_x: i32 = @intCast(x);
        if (click_x >= tab_x and click_x < tab_x + @as(i32, @intCast(tab_w))) {
            return i;
        }
        x += tab_w + 1;
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════
// SECTION: Helper functions
// ═══════════════════════════════════════════════════════════════

fn isInWordHighlight(offset: u32, highlights: []const WordHighlight) bool {
    for (highlights) |h| {
        if (offset >= h.start and offset < h.end) return true;
    }
    return false;
}

fn syntaxColor(kind: SyntaxKind) Color {
    const active_theme = view_mod.getActiveTheme();
    return switch (kind) {
        .keyword => active_theme.syn_keyword,
        .function => active_theme.syn_function,
        .function_builtin => active_theme.syn_func_builtin,
        .type_name => active_theme.syn_type,
        .string => active_theme.syn_string,
        .number => active_theme.syn_number,
        .comment => active_theme.syn_comment,
        .operator => active_theme.syn_operator,
        .variable => active_theme.syn_variable,
        .constant => active_theme.syn_constant,
        .property => active_theme.syn_property,
        .punctuation => active_theme.syn_punctuation,
        .none => active_theme.text,
    };
}

/// Compute the pixel width of a single tab, shared by renderTabBar and tabAtPixel.
fn computeTabWidth(label_len: u32, modified: bool, cell_w: u32) u32 {
    const mod_extra: u32 = if (modified) 2 else 0;
    const close_btn_w: u32 = cell_w + cell_w / 2;
    return (label_len + mod_extra + 3) * cell_w + close_btn_w;
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

pub fn decodeUtf8(bytes: []const u8) u32 {
    if (bytes.len == 0) return 0xFFFD;
    const b0 = bytes[0];
    if (b0 < 0x80) return b0;
    if (b0 < 0xE0) {
        if (bytes.len < 2) return 0xFFFD;
        return (@as(u32, b0 & 0x1F) << 6) | @as(u32, bytes[1] & 0x3F);
    }
    if (b0 < 0xF0) {
        if (bytes.len < 3) return 0xFFFD;
        return (@as(u32, b0 & 0x0F) << 12) |
            (@as(u32, bytes[1] & 0x3F) << 6) |
            @as(u32, bytes[2] & 0x3F);
    }
    if (bytes.len < 4) return 0xFFFD;
    return (@as(u32, b0 & 0x07) << 18) |
        (@as(u32, bytes[1] & 0x3F) << 12) |
        (@as(u32, bytes[2] & 0x3F) << 6) |
        @as(u32, bytes[3] & 0x3F);
}

/// Simple wide-character check (CJK Unified Ideographs + common fullwidth ranges).
pub fn isWide(cp: u32) bool {
    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true;
    // CJK Unified Ideographs Extension A
    if (cp >= 0x3400 and cp <= 0x4DBF) return true;
    // CJK Compatibility Ideographs
    if (cp >= 0xF900 and cp <= 0xFAFF) return true;
    // Hangul Syllables
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true;
    // Fullwidth Forms
    if (cp >= 0xFF01 and cp <= 0xFF60) return true;
    // Katakana/Hiragana
    if (cp >= 0x3000 and cp <= 0x30FF) return true;
    if (cp >= 0x31F0 and cp <= 0x31FF) return true;
    // CJK Symbols and Punctuation
    if (cp >= 0x3000 and cp <= 0x303F) return true;
    return false;
}

pub fn formatU32(val: u32, buf: *[12]u8) []const u8 {
    var n = val;
    var i: usize = buf.len;
    if (n == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (n > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (n % 10));
        n /= 10;
    }
    return buf[i..];
}

fn formatStatusRight(line: u32, col: u32, lang: []const u8, branch: []const u8, buf: *[192]u8) []const u8 {
    // Build "branch   Lang   Ln X, Col Y   UTF-8"
    const sep = "   ";
    const prefix = "Ln ";
    const mid = ", Col ";
    const suffix = "   UTF-8";

    var line_buf: [12]u8 = undefined;
    const line_str = formatU32(line, &line_buf);

    var col_buf: [12]u8 = undefined;
    const col_str = formatU32(col, &col_buf);

    var pos: usize = 0;

    // Branch name first (if available)
    if (branch.len > 0) {
        @memcpy(buf[pos..][0..branch.len], branch);
        pos += branch.len;
        @memcpy(buf[pos..][0..sep.len], sep);
        pos += sep.len;
    }

    @memcpy(buf[pos..][0..lang.len], lang);
    pos += lang.len;
    @memcpy(buf[pos..][0..sep.len], sep);
    pos += sep.len;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..line_str.len], line_str);
    pos += line_str.len;
    @memcpy(buf[pos..][0..mid.len], mid);
    pos += mid.len;
    @memcpy(buf[pos..][0..col_str.len], col_str);
    pos += col_str.len;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    return buf[0..pos];
}
