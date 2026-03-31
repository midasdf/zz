const std = @import("std");
const PieceTable = @import("buffer.zig").PieceTable;
const CursorState = @import("cursor.zig").CursorState;
const Selection = @import("cursor.zig").Selection;
pub const Highlighter = @import("highlight.zig").Highlighter;
const SyntaxKind = @import("highlight.zig").SyntaxKind;
const Renderer = @import("../ui/render.zig").Renderer;
const FontFace = @import("../ui/font.zig").FontFace;
const Color = @import("../ui/render.zig").Color;
const Diagnostic = @import("../lsp/client.zig").Diagnostic;

// ── Catppuccin Mocha palette ───────────────────────────────────────
const theme = struct {
    const base = Color.fromHex(0x1e1e2e); // Background
    const mantle = Color.fromHex(0x181825); // Status bar / darker bg
    const surface0 = Color.fromHex(0x313244); // Current line highlight
    const surface1 = Color.fromHex(0x45475a); // Selection
    const surface2 = Color.fromHex(0x585b70); // Subtle borders
    const overlay0 = Color.fromHex(0x6c7086); // Line numbers (inactive)
    const text = Color.fromHex(0xcdd6f4); // Main text
    const subtext0 = Color.fromHex(0xa6adc8); // Status bar text
    const rosewater = Color.fromHex(0xf5e0dc); // Cursor
    const lavender = Color.fromHex(0xb4befe); // Active line number, accents
    const green = Color.fromHex(0xa6e3a1); // Modified indicator
    const red = Color.fromHex(0xf38ba8); // Error/close
    const peach = Color.fromHex(0xfab387); // Warnings
    const mauve = Color.fromHex(0xcba6f7); // Keywords (future)

    // Syntax colors (Catppuccin Mocha)
    const syn_keyword = Color.fromHex(0xcba6f7); // Mauve
    const syn_function = Color.fromHex(0x89b4fa); // Blue
    const syn_func_builtin = Color.fromHex(0xf9e2af); // Yellow
    const syn_type = Color.fromHex(0xf9e2af); // Yellow
    const syn_string = Color.fromHex(0xa6e3a1); // Green
    const syn_number = Color.fromHex(0xfab387); // Peach
    const syn_comment = Color.fromHex(0x6c7086); // Overlay0
    const syn_operator = Color.fromHex(0x89dceb); // Sky
    const syn_variable = Color.fromHex(0xcdd6f4); // Text
    const syn_constant = Color.fromHex(0xfab387); // Peach
    const syn_property = Color.fromHex(0x89b4fa); // Blue
    const syn_punctuation = Color.fromHex(0x9399b2); // Overlay2
};

// ── EditorView ─────────────────────────────────────────────────────
pub const EditorView = struct {
    buffer: PieceTable,
    cursor: CursorState,
    highlighter: Highlighter,
    scroll_line: u32,
    visible_rows: u32,
    visible_cols: u32,
    left_pad: u32 = 8,
    dirty_rows: []bool,
    allocator: std.mem.Allocator,
    modified: bool = false,
    file_path: ?[]const u8 = null,
    cursor_visible: bool = true,
    lsp_diagnostics: []const Diagnostic = &.{},
    y_offset: u32 = 0, // Pixel offset for tab bar

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !EditorView {
        var buffer = try PieceTable.init(allocator, content);
        errdefer buffer.deinit();
        var cursor = try CursorState.init(allocator);
        errdefer cursor.deinit();
        const dirty = try allocator.alloc(bool, 1);
        @memset(dirty, true);
        var highlighter = Highlighter.init(allocator);
        errdefer highlighter.deinit();

        return .{
            .buffer = buffer,
            .cursor = cursor,
            .highlighter = highlighter,
            .scroll_line = 0,
            .visible_rows = 1,
            .visible_cols = 80,
            .dirty_rows = dirty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EditorView) void {
        self.highlighter.deinit();
        self.buffer.deinit();
        self.cursor.deinit();
        self.allocator.free(self.dirty_rows);
        if (self.file_path) |path| {
            self.allocator.free(path);
        }
    }

    // ── Syntax highlighting ──────────────────────────────────────────

    pub fn initHighlighting(self: *EditorView) void {
        self.highlighter.setLanguage(self.file_path);
        self.highlighter.parse(&self.buffer);
    }

    // ── Viewport management ────────────────────────────────────────

    pub fn updateViewport(self: *EditorView, win_width: u32, win_height: u32, font: *const FontFace) !void {
        if (font.cell_height == 0 or font.cell_width == 0) return;

        // Available height = window height minus tab bar offset and status bar (2 rows)
        const avail_h = if (win_height > self.y_offset) win_height - self.y_offset else 0;
        const total_rows = avail_h / font.cell_height;
        self.visible_rows = if (total_rows > 2) total_rows - 2 else 1;

        // Cols = (width - gutter - left_pad) / cell_width
        const gw = self.gutterWidth(font);
        const code_area = if (win_width > gw) win_width - gw else 0;
        self.visible_cols = if (code_area > 0) code_area / font.cell_width else 1;

        // Reallocate dirty row flags (alloc new before freeing old)
        const new_dirty = try self.allocator.alloc(bool, self.visible_rows);
        @memset(new_dirty, true);
        self.allocator.free(self.dirty_rows);
        self.dirty_rows = new_dirty;
    }

    // ── Dirty tracking ─────────────────────────────────────────────

    pub fn markAllDirty(self: *EditorView) void {
        @memset(self.dirty_rows, true);
    }

    pub fn markRowDirty(self: *EditorView, screen_row: u32) void {
        if (screen_row < self.dirty_rows.len) {
            self.dirty_rows[screen_row] = true;
        }
    }

    // ── Scroll ─────────────────────────────────────────────────────

    pub fn ensureCursorVisible(self: *EditorView) void {
        const pos = self.cursor.primary().head;
        const lc = self.buffer.offsetToLineCol(pos);
        const cursor_line = lc.line;

        // Scroll up if cursor is above viewport
        if (cursor_line < self.scroll_line) {
            self.scroll_line = cursor_line;
            self.markAllDirty();
        }

        // Scroll down if cursor is below viewport
        if (cursor_line >= self.scroll_line + self.visible_rows) {
            self.scroll_line = cursor_line - self.visible_rows + 1;
            self.markAllDirty();
        }
    }

    // ── Editing operations ─────────────────────────────────────────

    pub fn insertAtCursor(self: *EditorView, text: []const u8) !void {
        const len: u32 = @intCast(text.len);

        if (self.cursor.cursorCount() <= 1) {
            // Fast path: single cursor
            const sel = self.cursor.primary();
            if (sel.hasSelection()) {
                try self.deleteSelection();
            }
            const pos = self.cursor.primary().head;
            try self.buffer.insert(pos, text);
            self.highlighter.notifyEdit(&self.buffer, pos, pos, pos + len);
            self.cursor.moveTo(pos + len);
        } else {
            // Multi-cursor: sort descending by head, process back-to-front
            self.cursor.sortDescending();
            for (self.cursor.cursors.items) |*sel| {
                if (sel.hasSelection()) {
                    const start = sel.start();
                    const del_len = sel.end() - start;
                    try self.buffer.delete(start, del_len);
                    self.highlighter.notifyEdit(&self.buffer, start, start + del_len, start);
                    sel.anchor = start;
                    sel.head = start;
                }
                try self.buffer.insert(sel.head, text);
                self.highlighter.notifyEdit(&self.buffer, sel.head, sel.head, sel.head + len);
                sel.head += len;
                sel.anchor = sel.head;
            }
        }

        self.modified = true;
        self.ensureCursorVisible();
        self.markAllDirty();
    }

    pub fn backspace(self: *EditorView) !void {
        if (self.cursor.cursorCount() <= 1) {
            // Fast path: single cursor
            const sel = self.cursor.primary();
            if (sel.hasSelection()) {
                try self.deleteSelection();
                return;
            }

            const pos = sel.head;
            if (pos == 0) return;

            var prev = pos - 1;
            while (prev > 0) {
                const slice = self.buffer.contiguousSliceAt(prev);
                if (slice.len == 0) break;
                if ((slice[0] & 0xC0) != 0x80) break;
                prev -= 1;
            }

            const del_len = pos - prev;
            try self.buffer.delete(prev, del_len);
            self.highlighter.notifyEdit(&self.buffer, prev, prev + del_len, prev);
            self.cursor.moveTo(prev);
        } else {
            // Multi-cursor: sort descending, process back-to-front
            self.cursor.sortDescending();
            for (self.cursor.cursors.items) |*sel| {
                if (sel.hasSelection()) {
                    const start = sel.start();
                    const del_len = sel.end() - start;
                    try self.buffer.delete(start, del_len);
                    self.highlighter.notifyEdit(&self.buffer, start, start + del_len, start);
                    sel.anchor = start;
                    sel.head = start;
                    continue;
                }
                if (sel.head == 0) continue;
                var prev = sel.head - 1;
                while (prev > 0) {
                    const slice = self.buffer.contiguousSliceAt(prev);
                    if (slice.len == 0) break;
                    if ((slice[0] & 0xC0) != 0x80) break;
                    prev -= 1;
                }
                const del_len = sel.head - prev;
                try self.buffer.delete(prev, del_len);
                self.highlighter.notifyEdit(&self.buffer, prev, prev + del_len, prev);
                sel.head = prev;
                sel.anchor = prev;
            }
        }

        self.modified = true;
        self.ensureCursorVisible();
        self.markAllDirty();
    }

    pub fn deleteForward(self: *EditorView) !void {
        if (self.cursor.cursorCount() <= 1) {
            // Fast path: single cursor
            const sel = self.cursor.primary();
            if (sel.hasSelection()) {
                try self.deleteSelection();
                return;
            }

            const pos = sel.head;
            if (pos >= self.buffer.total_len) return;

            const slice = self.buffer.contiguousSliceAt(pos);
            if (slice.len == 0) return;

            const byte_len = CursorState.utf8ByteLen(slice[0]);
            try self.buffer.delete(pos, byte_len);
            self.highlighter.notifyEdit(&self.buffer, pos, pos + byte_len, pos);
        } else {
            // Multi-cursor: sort descending, process back-to-front
            self.cursor.sortDescending();
            for (self.cursor.cursors.items) |*sel| {
                if (sel.hasSelection()) {
                    const start = sel.start();
                    const del_len = sel.end() - start;
                    try self.buffer.delete(start, del_len);
                    self.highlighter.notifyEdit(&self.buffer, start, start + del_len, start);
                    sel.anchor = start;
                    sel.head = start;
                    continue;
                }
                if (sel.head >= self.buffer.total_len) continue;
                const slice = self.buffer.contiguousSliceAt(sel.head);
                if (slice.len == 0) continue;
                const byte_len = CursorState.utf8ByteLen(slice[0]);
                try self.buffer.delete(sel.head, byte_len);
                self.highlighter.notifyEdit(&self.buffer, sel.head, sel.head + byte_len, sel.head);
            }
        }

        self.modified = true;
        self.markAllDirty();
    }

    pub fn deleteSelection(self: *EditorView) !void {
        if (self.cursor.cursorCount() <= 1) {
            // Fast path: single cursor
            const sel = self.cursor.primary();
            if (!sel.hasSelection()) return;

            const start = sel.start();
            const end = sel.end();
            try self.buffer.delete(start, end - start);
            self.highlighter.notifyEdit(&self.buffer, start, end, start);
            self.cursor.moveTo(start);
        } else {
            // Multi-cursor: sort descending, process back-to-front
            self.cursor.sortDescending();
            for (self.cursor.cursors.items) |*sel| {
                if (!sel.hasSelection()) continue;
                const start = sel.start();
                const del_len = sel.end() - start;
                try self.buffer.delete(start, del_len);
                self.highlighter.notifyEdit(&self.buffer, start, start + del_len, start);
                sel.anchor = start;
                sel.head = start;
            }
        }

        self.modified = true;
        self.ensureCursorVisible();
        self.markAllDirty();
    }

    pub fn getSelectedText(self: *EditorView) ?[]u8 {
        const sel = self.cursor.primary();
        if (!sel.hasSelection()) return null;

        const start = sel.start();
        const end = sel.end();
        const len = end - start;

        const result = self.allocator.alloc(u8, len) catch return null;
        var written: usize = 0;
        var offset: u32 = start;

        while (offset < end) {
            const slice = self.buffer.contiguousSliceAt(offset);
            if (slice.len == 0) break;
            const remaining: usize = @intCast(end - offset);
            const take = @min(slice.len, remaining);
            @memcpy(result[written..][0..take], slice[0..take]);
            written += take;
            offset += @intCast(take);
        }

        return result[0..written];
    }

    // ── Multi-cursor: select next/all occurrence ──────────────────

    pub fn selectNextOccurrence(self: *EditorView) !void {
        const sel = self.cursor.primary();
        if (!sel.hasSelection()) {
            // Select current word under cursor
            self.selectWordAtCursor();
            return;
        }

        // Get selected text
        const selected = self.getSelectedText() orelse return;
        defer self.allocator.free(selected);
        if (selected.len == 0) return;

        // Search forward from the last cursor's end position
        var search_from: u32 = 0;
        for (self.cursor.cursors.items) |c| {
            const e = c.end();
            if (e > search_from) search_from = e;
        }

        const content = self.buffer.collectContent(self.allocator) catch return;
        defer self.allocator.free(content);

        const sel_len: u32 = @intCast(selected.len);

        // Search forward from last cursor
        if (search_from < content.len) {
            if (std.mem.indexOf(u8, content[search_from..], selected)) |pos| {
                const abs_pos: u32 = @intCast(search_from + pos);
                // Check not already a cursor at this position
                if (!self.hasCursorAt(abs_pos, abs_pos + sel_len)) {
                    try self.cursor.addSelection(.{
                        .anchor = abs_pos,
                        .head = abs_pos + sel_len,
                    });
                    self.markAllDirty();
                    return;
                }
            }
        }

        // Wrap around: search from beginning
        if (std.mem.indexOf(u8, content, selected)) |pos| {
            const abs_pos: u32 = @intCast(pos);
            if (!self.hasCursorAt(abs_pos, abs_pos + sel_len)) {
                try self.cursor.addSelection(.{
                    .anchor = abs_pos,
                    .head = abs_pos + sel_len,
                });
                self.markAllDirty();
            }
        }
    }

    pub fn selectAllOccurrences(self: *EditorView) !void {
        const sel = self.cursor.primary();
        if (!sel.hasSelection()) {
            self.selectWordAtCursor();
            if (!self.cursor.primary().hasSelection()) return;
        }

        const selected = self.getSelectedText() orelse return;
        defer self.allocator.free(selected);
        if (selected.len == 0) return;

        const content = self.buffer.collectContent(self.allocator) catch return;
        defer self.allocator.free(content);

        const sel_len: u32 = @intCast(selected.len);

        // Clear all cursors and re-add for every occurrence
        self.cursor.cursors.clearRetainingCapacity();

        var search_pos: usize = 0;
        while (search_pos < content.len) {
            if (std.mem.indexOf(u8, content[search_pos..], selected)) |pos| {
                const abs_pos: u32 = @intCast(search_pos + pos);
                self.cursor.cursors.append(self.allocator, .{
                    .anchor = abs_pos,
                    .head = abs_pos + sel_len,
                }) catch break;
                search_pos = search_pos + pos + selected.len;
            } else break;
        }

        // Ensure at least one cursor
        if (self.cursor.cursors.items.len == 0) {
            self.cursor.cursors.append(self.allocator, .{ .anchor = 0, .head = 0 }) catch {};
        }

        self.markAllDirty();
    }

    fn selectWordAtCursor(self: *EditorView) void {
        const pos = self.cursor.primary().head;
        var start = pos;
        while (start > 0) {
            const slice = self.buffer.contiguousSliceAt(start - 1);
            if (slice.len == 0) break;
            if (!isWordChar(slice[0])) break;
            start -= 1;
        }
        var end_pos = pos;
        while (end_pos < self.buffer.total_len) {
            const slice = self.buffer.contiguousSliceAt(end_pos);
            if (slice.len == 0) break;
            if (!isWordChar(slice[0])) break;
            end_pos += 1;
        }
        if (start != end_pos) {
            self.cursor.cursors.items[0] = .{ .anchor = start, .head = end_pos };
            self.markAllDirty();
        }
    }

    fn hasCursorAt(self: *const EditorView, anchor: u32, head: u32) bool {
        for (self.cursor.cursors.items) |c| {
            if (c.anchor == anchor and c.head == head) return true;
            if (c.anchor == head and c.head == anchor) return true;
        }
        return false;
    }

    // ── Rendering ──────────────────────────────────────────────────

    pub fn render(self: *EditorView, renderer: *Renderer, font: *FontFace) void {
        const cell_w = font.cell_width;
        const cell_h = font.cell_height;
        if (cell_w == 0 or cell_h == 0) return;

        const gw = self.gutterWidth(font);
        const code_x = gw; // code area starts right after gutter
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

        // Query tree-sitter highlights for visible range
        const vis_start = byte_offset;
        var vis_end = vis_start;
        {
            var skip_line: u32 = 0;
            var tmp_off = vis_start;
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
            vis_end = tmp_off;
        }
        self.highlighter.queryRange(vis_start, vis_end);

        var screen_row: u32 = 0;
        while (screen_row < self.visible_rows) : (screen_row += 1) {
            const doc_line = self.scroll_line + screen_row;
            const row_y = self.y_offset + screen_row * cell_h;

            // Skip clean rows -- but we must advance byte_offset past this line
            if (screen_row < self.dirty_rows.len and !self.dirty_rows[screen_row]) {
                // Advance byte_offset past this line by scanning for newline
                if (doc_line < total_lines) {
                    byte_offset = self.advancePastLine(byte_offset);
                }
                continue;
            }

            const is_current_line = (doc_line == cursor_lc.line);
            const line_bg = if (is_current_line) theme.surface0 else theme.base;

            // Clear the entire row (gutter + code area)
            renderer.fillRect(0, row_y, renderer.width, cell_h, line_bg);

            // -- Gutter: line number --
            if (doc_line < total_lines) {
                self.renderGutterNumber(renderer, font, doc_line, screen_row, is_current_line);
            }

            // -- Gutter separator (1px vertical line) --
            const sep_x = gw - self.left_pad / 2;
            renderer.fillRect(sep_x, row_y, 1, cell_h, theme.surface2);

            // -- Code area --
            if (doc_line < total_lines) {
                self.renderCodeLine(renderer, font, byte_offset, doc_line, screen_row, code_x, line_bg, has_sel);

                // -- Diagnostic underlines --
                self.renderDiagnostics(renderer, font, doc_line, code_x, screen_row * cell_h);

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
                        renderer.fillRect(cursor_px_x, row_y, 2, cell_h, theme.rosewater);
                    }
                }
            }

            // Mark row as clean
            if (screen_row < self.dirty_rows.len) {
                self.dirty_rows[screen_row] = false;
            }
        }

        // -- Status bar --
        self.renderStatusBar(renderer, font, cursor_lc.line, cursor_lc.col);
    }

    // ── Render helpers (private) ───────────────────────────────────

    fn renderGutterNumber(
        self: *const EditorView,
        renderer: *Renderer,
        font: *FontFace,
        doc_line: u32,
        screen_row: u32,
        is_current: bool,
    ) void {
        const cell_w = font.cell_width;
        const cell_h = font.cell_height;
        const row_y = screen_row * cell_h;

        const fg_color = if (is_current) theme.lavender else theme.overlay0;
        const line_bg = if (is_current) theme.surface0 else theme.base;

        // Line number (1-based, right-aligned)
        const line_num = doc_line + 1;
        var num_buf: [12]u8 = undefined;
        const num_str = formatU32(line_num, &num_buf);

        // Calculate gutter digit columns (excluding separator padding)
        const digit_cols = self.gutterDigits();

        // Right-align: start at (digit_cols - num_str.len)
        const padding: u32 = if (digit_cols > num_str.len) digit_cols - @as(u32, @intCast(num_str.len)) else 0;

        for (num_str, 0..) |ch, i| {
            const col_x = (padding + @as(u32, @intCast(i))) * cell_w;
            renderer.fillRect(col_x, row_y, cell_w, cell_h, line_bg);
            const glyph = font.getGlyph(ch) catch continue;
            const glyph_x = @as(i32, @intCast(col_x)) + glyph.bearing_x;
            const glyph_y = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
            renderer.drawGlyph(glyph, glyph_x, glyph_y, fg_color);
        }
    }

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
    ) void {
        _ = doc_line;
        const cell_w = font.cell_width;
        const cell_h = font.cell_height;
        const row_y = screen_row * cell_h;
        const pad = self.left_pad;

        var col: u32 = 0;
        var offset = line_start_offset;

        while (col < self.visible_cols) {
            if (offset >= self.buffer.total_len) break;

            const slice = self.buffer.contiguousSliceAt(offset);
            if (slice.len == 0) break;

            const byte = slice[0];

            // Stop at end of line
            if (byte == '\n') break;

            // Determine background: selection overrides current-line highlight
            var cell_bg = line_bg;
            if (has_sel and self.isInAnySelection(offset)) {
                cell_bg = theme.surface1;
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

                col += char_cells;
                offset += cp_len;
            }
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
        const cell_w = font.cell_width;
        const cell_h = font.cell_height;
        if (cell_w == 0 or cell_h == 0) return;

        const underline_y = row_y + cell_h - 2; // 2px from bottom of cell
        const pad = self.left_pad;

        for (self.lsp_diagnostics) |diag| {
            if (diag.line != doc_line) continue;

            const color: Color = switch (diag.severity) {
                .err => theme.red,
                .warning => theme.peach,
                .info => theme.lavender,
                .hint => theme.overlay0,
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

    fn renderStatusBar(self: *const EditorView, renderer: *Renderer, font: *FontFace, cursor_line: u32, cursor_col: u32) void {
        const cell_w = font.cell_width;
        const cell_h = font.cell_height;
        const win_w = renderer.width;

        // Status bar occupies the last 2 rows: 1px separator + 1 row of text
        const status_y = self.y_offset + self.visible_rows * cell_h;
        const bar_y = status_y + 1;

        // Separator line (1px)
        renderer.fillRect(0, status_y, win_w, 1, theme.surface2);

        // Status bar background
        renderer.fillRect(0, bar_y, win_w, cell_h, theme.mantle);

        // -- Left section: filename + modified indicator --
        var left_col: u32 = 1; // 1-col left margin

        const name = self.file_path orelse "[untitled]";
        for (name) |ch| {
            if (left_col >= self.visible_cols) break;
            self.drawStatusChar(renderer, font, ch, left_col, bar_y, theme.subtext0);
            left_col += 1;
        }

        if (self.modified) {
            // " [+]"
            const mod_str = " [+]";
            for (mod_str) |ch| {
                if (left_col >= self.visible_cols) break;
                const color = if (ch == '+') theme.green else theme.subtext0;
                self.drawStatusChar(renderer, font, ch, left_col, bar_y, color);
                left_col += 1;
            }
        }

        // -- Right section: "Lang   Ln X, Col Y   UTF-8" --
        const lang_name = self.highlighter.languageName();
        var right_buf: [96]u8 = undefined;
        const right_str = formatStatusRight(cursor_line + 1, cursor_col + 1, lang_name, &right_buf);
        const right_len: u32 = @intCast(right_str.len);
        const right_start = if (win_w / cell_w > right_len + 1) win_w / cell_w - right_len - 1 else 0;

        for (right_str, 0..) |ch, i| {
            const col = right_start + @as(u32, @intCast(i));
            if (col >= self.visible_cols) break;
            self.drawStatusChar(renderer, font, ch, col, bar_y, theme.subtext0);
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
        _ = self;
        const cell_w = font.cell_width;
        const px_x = col * cell_w;
        const glyph = font.getGlyph(ch) catch return;
        const glyph_x = @as(i32, @intCast(px_x)) + glyph.bearing_x;
        const glyph_y = @as(i32, @intCast(bar_y)) + font.ascent - glyph.bearing_y;
        renderer.drawGlyph(glyph, glyph_x, glyph_y, fg);
    }

    // ── Coordinate conversion ──────────────────────────────────────

    pub fn pixelToPosition(self: *EditorView, px: i32, py: i32, font: *const FontFace) u32 {
        const cell_w = font.cell_width;
        const cell_h = font.cell_height;
        if (cell_w == 0 or cell_h == 0) return 0;

        // Adjust for tab bar offset
        const adj_y = py - @as(i32, @intCast(self.y_offset));

        // Determine screen row from pixel y
        const screen_row: u32 = if (adj_y < 0) 0 else @min(@as(u32, @intCast(@divTrunc(adj_y, @as(i32, @intCast(cell_h))))), self.visible_rows -| 1);
        const doc_line = self.scroll_line + screen_row;

        const total_lines = self.buffer.lineCount();
        if (doc_line >= total_lines) {
            // Past end of document -- return end of buffer
            return self.buffer.total_len;
        }

        const line_offset = self.buffer.lineToOffset(doc_line);

        // Determine target column from pixel x
        const gw = self.gutterWidth(font);
        const code_x = @as(i32, @intCast(gw + self.left_pad));
        const target_col: u32 = if (px < code_x) 0 else @intCast(@divTrunc(px - code_x, @as(i32, @intCast(cell_w))));

        // Walk along the line to find the byte offset at target_col
        var col: u32 = 0;
        var offset = line_offset;

        while (offset < self.buffer.total_len) {
            if (col >= target_col) break;

            const slice = self.buffer.contiguousSliceAt(offset);
            if (slice.len == 0) break;

            const byte = slice[0];
            if (byte == '\n') break;

            if (byte == '\t') {
                const tab_stop: u32 = 4;
                const next_tab = ((col / tab_stop) + 1) * tab_stop;
                // If target is inside this tab, snap to tab start
                if (target_col < next_tab) break;
                col = next_tab;
                offset += 1;
            } else if (byte < 0x80) {
                col += 1;
                offset += 1;
            } else {
                const cp_len = CursorState.utf8ByteLen(byte);
                const cp = if (cp_len <= @as(u32, @intCast(slice.len))) decodeUtf8(slice[0..@intCast(cp_len)]) else 0;
                const char_cells: u32 = if (isWide(cp)) 2 else 1;
                col += char_cells;
                offset += cp_len;
            }
        }

        return offset;
    }

    // ── Internal helpers ───────────────────────────────────────────

    /// Check if a byte offset falls within any cursor's selection.
    fn isInAnySelection(self: *const EditorView, offset: u32) bool {
        for (self.cursor.cursors.items) |c| {
            if (c.hasSelection() and offset >= c.start() and offset < c.end()) {
                return true;
            }
        }
        return false;
    }

    fn advancePastLine(self: *const EditorView, start_offset: u32) u32 {
        var offset = start_offset;
        while (offset < self.buffer.total_len) {
            const slice = self.buffer.contiguousSliceAt(offset);
            if (slice.len == 0) break;

            // Scan this contiguous slice for newline
            for (slice, 0..) |byte, i| {
                if (byte == '\n') {
                    return offset + @as(u32, @intCast(i)) + 1;
                }
            }
            // No newline in this slice -- advance past it
            offset += @intCast(slice.len);
        }
        return offset;
    }

    /// Compute the visual column for a cursor position, accounting for tabs.
    fn visualColAtOffset(self: *const EditorView, line: u32, col: u32) u32 {
        const line_start = self.buffer.lineToOffset(line);
        const target = line_start + col;
        var vcol: u32 = 0;
        var off = line_start;
        while (off < target and off < self.buffer.total_len) {
            const slice = self.buffer.contiguousSliceAt(off);
            if (slice.len == 0 or slice[0] == '\n') break;
            if (slice[0] == '\t') {
                vcol += 4 - (vcol % 4);
                off += 1;
            } else {
                const byte_len = CursorState.utf8ByteLen(slice[0]);
                const cp = decodeUtf8(slice[0..@min(byte_len, @as(u32, @intCast(slice.len)))]);
                vcol += if (isWide(cp)) 2 else 1;
                off += byte_len;
            }
        }
        return vcol;
    }

    fn gutterWidth(self: *const EditorView, font: *const FontFace) u32 {
        const digits = self.gutterDigits();
        return (digits + 1) * font.cell_width + self.left_pad;
    }

    fn gutterDigits(self: *const EditorView) u32 {
        const total = self.buffer.lineCount();
        var digits: u32 = 1;
        var n: u32 = total;
        while (n >= 10) {
            n /= 10;
            digits += 1;
        }
        return @max(3, digits);
    }
};

// ── Tab bar rendering ─────────────────────────────────────────────
const TabManager = @import("tabs.zig").TabManager;

/// Compute the tab bar height in pixels.
pub fn tabBarHeight(font: *const FontFace) u32 {
    return font.cell_height + 6; // cell height + top accent (2px) + padding (4px)
}

/// Render the tab bar at the top of the window.
pub fn renderTabBar(
    tab_mgr: *const TabManager,
    renderer: *Renderer,
    font: *FontFace,
) void {
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return;

    const bar_h = tabBarHeight(font);
    const win_w = renderer.width;

    // Full bar background
    renderer.fillRect(0, 0, win_w, bar_h, theme.mantle);

    // Bottom separator
    renderer.fillRect(0, bar_h - 1, win_w, 1, theme.surface2);

    // Render each tab
    var x: u32 = 2;
    for (tab_mgr.tabs.items, 0..) |tab, i| {
        const is_active = (i == tab_mgr.active);
        const bg = if (is_active) theme.base else theme.mantle;
        const fg = if (is_active) theme.text else theme.overlay0;

        // Tab label
        const label = if (tab.file_path) |p| basename(p) else "[untitled]";
        const label_len: u32 = @intCast(label.len);
        const mod_extra: u32 = if (tab.modified) 2 else 0; // " +"
        const tab_w = (label_len + mod_extra + 2) * cell_w; // +2 for left/right padding

        // Tab background (leave 1px gap at bottom for separator)
        renderer.fillRect(x, 0, tab_w, bar_h - 1, bg);

        // Active tab: lavender accent line at top (2px)
        if (is_active) {
            renderer.fillRect(x, 0, tab_w, 2, theme.lavender);
        }

        // Tab label text
        const text_y: u32 = 3; // 2px accent + 1px padding
        var tx = x + cell_w; // 1-cell left padding
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
            if (font.getGlyph(' ')) |_| {} else |_| {}
            tx += cell_w; // space
            if (font.getGlyph('+')) |glyph| {
                const gx: i32 = @intCast(tx);
                const gy: i32 = @as(i32, @intCast(text_y)) + font.ascent - @as(i32, glyph.bearing_y);
                renderer.drawGlyph(glyph, gx, gy, theme.green);
            } else |_| {}
        }

        x += tab_w + 2; // 2px gap between tabs
    }
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

fn syntaxColor(kind: SyntaxKind) Color {
    return switch (kind) {
        .keyword => theme.syn_keyword,
        .function => theme.syn_function,
        .function_builtin => theme.syn_func_builtin,
        .type_name => theme.syn_type,
        .string => theme.syn_string,
        .number => theme.syn_number,
        .comment => theme.syn_comment,
        .operator => theme.syn_operator,
        .variable => theme.syn_variable,
        .constant => theme.syn_constant,
        .property => theme.syn_property,
        .punctuation => theme.syn_punctuation,
        .none => theme.text,
    };
}

// ── Free functions ─────────────────────────────────────────────────

fn decodeUtf8(bytes: []const u8) u32 {
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
fn isWide(cp: u32) bool {
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

fn formatU32(val: u32, buf: *[12]u8) []const u8 {
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

fn formatStatusRight(line: u32, col: u32, lang: []const u8, buf: *[96]u8) []const u8 {
    // Build "Lang   Ln X, Col Y   UTF-8"
    const sep = "   ";
    const prefix = "Ln ";
    const mid = ", Col ";
    const suffix = "   UTF-8";

    var line_buf: [12]u8 = undefined;
    const line_str = formatU32(line, &line_buf);

    var col_buf: [12]u8 = undefined;
    const col_str = formatU32(col, &col_buf);

    var pos: usize = 0;
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
