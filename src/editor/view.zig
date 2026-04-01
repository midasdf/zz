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
pub const GitInfo = @import("../core/git.zig").GitInfo;

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
    git_info: ?*GitInfo = null,
    y_offset: u32 = 0, // Pixel offset for tab bar
    x_offset: u32 = 0, // Pixel offset for split panes
    render_width: u32 = 0, // Pane width (0 = use renderer.width)
    minimap_visible: bool = true,
    minimap_width: u32 = 60, // pixels
    folded_lines: std.AutoHashMap(u32, u32), // start_line -> end_line (exclusive)

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
            .folded_lines = std.AutoHashMap(u32, u32).init(allocator),
        };
    }

    pub fn deinit(self: *EditorView) void {
        self.highlighter.deinit();
        self.buffer.deinit();
        self.cursor.deinit();
        self.allocator.free(self.dirty_rows);
        self.folded_lines.deinit();
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

    /// Effective pane width: render_width if set, otherwise full window width.
    pub fn paneWidth(self: *const EditorView, fallback: u32) u32 {
        return if (self.render_width > 0) self.render_width else fallback;
    }

    pub fn updateViewport(self: *EditorView, win_width: u32, win_height: u32, font: *const FontFace) !void {
        if (font.cell_height == 0 or font.cell_width == 0) return;

        // Available height = window height minus tab bar offset and status bar
        // Status bar = 1px separator + cell_height + 4px padding
        const status_bar_h: u32 = font.cell_height + 5;
        const avail_h = if (win_height > self.y_offset + status_bar_h) win_height - self.y_offset - status_bar_h else 0;
        const total_rows = avail_h / font.cell_height;
        self.visible_rows = if (total_rows > 0) total_rows else 1;

        // Use pane width if set, otherwise full window width
        const effective_w = self.paneWidth(win_width);

        // Cols = (width - gutter - left_pad) / cell_width
        const gw = self.gutterWidth(font);
        const code_area = if (effective_w > gw) effective_w - gw else 0;
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
            if (cursor_slice.len > 0 and isWordChar(cursor_slice[0])) {
                var ws = cursor_pos;
                while (ws > 0) {
                    const s = self.buffer.contiguousSliceAt(ws - 1);
                    if (s.len == 0 or !isWordChar(s[0])) break;
                    ws -= 1;
                }
                var we = cursor_pos;
                while (we < self.buffer.total_len) {
                    const s = self.buffer.contiguousSliceAt(we);
                    if (s.len == 0 or !isWordChar(s[0])) break;
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
                                break :blk bs.len == 0 or !isWordChar(bs[0]);
                            };
                            const after_ok = search_pos + word_len >= self.buffer.total_len or blk: {
                                const as2 = self.buffer.contiguousSliceAt(search_pos + word_len);
                                break :blk as2.len == 0 or !isWordChar(as2[0]);
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
            const line_bg = if (is_current_line) theme.surface0 else theme.base;

            // Clear the entire row (gutter + code area) within this pane
            renderer.fillRect(xo, row_y, pw, cell_h, line_bg);

            // -- Gutter: line number --
            if (doc_line < total_lines) {
                self.renderGutterNumber(renderer, font, doc_line, screen_row, is_current_line);
            }

            // -- Fold indicator in gutter --
            if (self.folded_lines.get(doc_line)) |_| {
                // Draw fold indicator: ">" in gutter area
                const fold_x = xo + 2;
                if (font.getGlyph('>')) |glyph| {
                    const gx = @as(i32, @intCast(fold_x)) + glyph.bearing_x;
                    const gy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                    renderer.drawGlyph(glyph, gx, gy, theme.peach);
                } else |_| {}
            }

            // -- Git diff gutter marker (2px bar at left edge of gutter) --
            if (self.git_info) |gi| {
                if (doc_line < total_lines) {
                    if (gi.lineKind(doc_line)) |kind| {
                        const diff_color: Color = switch (kind) {
                            .added => theme.green,
                            .modified => theme.peach,
                            .deleted => theme.red,
                        };
                        renderer.fillRect(xo, row_y, 2, cell_h, diff_color);
                    }
                }
            }

            // -- Gutter separator (1px vertical line) --
            const sep_x = xo + gw - self.left_pad / 2;
            renderer.fillRect(sep_x, row_y, 1, cell_h, theme.surface2);

            // -- Code area --
            if (doc_line < total_lines) {
                self.renderIndentGuides(renderer, font, byte_offset, screen_row, code_x);
                self.renderCodeLine(renderer, font, byte_offset, doc_line, screen_row, code_x, line_bg, has_sel, word_highlights[0..word_hl_count]);

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
                            renderer.drawGlyph(glyph, gfx, gfy, theme.overlay0);
                        } else |_| {}
                        fx += cell_w;
                    }
                }

                // -- Diagnostic underlines --
                self.renderDiagnostics(renderer, font, doc_line, code_x, self.y_offset + screen_row * cell_h);

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

            // -- Matching bracket highlight --
            if (match_lc) |mlc| {
                if (mlc.line == doc_line) {
                    const vcol = self.visualColAtOffset(mlc.line, mlc.col);
                    const bx = code_x + self.left_pad + vcol * cell_w;
                    // Background highlight
                    renderer.fillRect(bx, row_y, cell_w, cell_h, theme.surface2);
                    // Underline (2px at bottom)
                    renderer.fillRect(bx, row_y + cell_h - 2, cell_w, 2, theme.lavender);
                    // Re-draw the bracket character on top of the highlight
                    if (match_pos) |mp| {
                        const ms = self.buffer.contiguousSliceAt(mp);
                        if (ms.len > 0 and ms[0] < 0x80) {
                            if (font.getGlyph(ms[0])) |glyph| {
                                const gx = @as(i32, @intCast(bx)) + glyph.bearing_x;
                                const gy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                                renderer.drawGlyph(glyph, gx, gy, theme.lavender);
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

        // -- Minimap (code overview on right edge) --
        self.renderMinimap(renderer, font);

        // -- Scrollbar indicator --
        self.renderScrollbar(renderer, font);

        // -- Status bar --
        self.renderStatusBar(renderer, font, cursor_lc.line, cursor_lc.col);
    }

    // ── Minimap ────────────────────────────────────────────────────

    fn renderMinimap(self: *const EditorView, renderer: *Renderer, font: *const FontFace) void {
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
        renderer.fillRect(mm_x, mm_y, mm_w, mm_h, theme.mantle);

        // Left border (1px)
        renderer.fillRect(mm_x, mm_y, 1, mm_h, theme.surface2);

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
                renderer.fillRect(mm_x, vp_start, mm_w, vp_h, theme.surface0);
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

    /// Check if a pixel coordinate is within the minimap area.
    pub fn isInMinimap(self: *const EditorView, px: i32, py: i32, renderer_width: u32) bool {
        if (!self.minimap_visible) return false;
        const pw = self.paneWidth(renderer_width);
        if (pw <= self.minimap_width) return false;
        const mm_x = self.x_offset + pw - self.minimap_width;
        const mm_y = self.y_offset;
        return px >= @as(i32, @intCast(mm_x)) and
            py >= @as(i32, @intCast(mm_y));
    }

    /// Handle a click in the minimap area: scroll to the corresponding line.
    pub fn handleMinimapClick(self: *EditorView, py: i32, font: *const FontFace) void {
        const cell_h = font.cell_height;
        if (cell_h == 0) return;
        const mm_h = self.visible_rows * cell_h;
        const line_height: u32 = 2;
        const max_minimap_lines = mm_h / line_height;
        if (max_minimap_lines == 0) return;

        const total_lines = self.buffer.lineCount();
        const center_line = self.scroll_line + self.visible_rows / 2;
        const half_range = max_minimap_lines / 2;
        var mm_start: u32 = 0;
        if (center_line > half_range) {
            mm_start = center_line - half_range;
        }
        if (mm_start + max_minimap_lines > total_lines and total_lines > max_minimap_lines) {
            mm_start = total_lines - max_minimap_lines;
        }

        const mm_y = self.y_offset;
        const rel_y: u32 = if (py > @as(i32, @intCast(mm_y)))
            @intCast(py - @as(i32, @intCast(mm_y)))
        else
            0;
        const clicked_line = mm_start + rel_y / line_height;
        const target = @min(clicked_line, total_lines -| 1);

        // Scroll so the clicked line is centered in the viewport
        if (target > self.visible_rows / 2) {
            self.scroll_line = target - self.visible_rows / 2;
        } else {
            self.scroll_line = 0;
        }
        // Clamp scroll
        if (self.scroll_line + self.visible_rows > total_lines) {
            self.scroll_line = total_lines -| self.visible_rows;
        }
        self.markAllDirty();
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
        const row_y = self.y_offset + screen_row * cell_h;
        const xo = self.x_offset;

        const fg_color = if (is_current) theme.lavender else theme.overlay0;
        const line_bg = if (is_current) theme.surface0 else theme.base;

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
        _ = doc_line;
        const cell_w = font.cell_width;
        const cell_h = font.cell_height;
        const row_y = self.y_offset + screen_row * cell_h;
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

            // Determine background: selection > word highlight > current-line
            var cell_bg = line_bg;
            if (has_sel and self.isInAnySelection(offset)) {
                cell_bg = theme.surface1;
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

    fn isInWordHighlight(offset: u32, highlights: []const WordHighlight) bool {
        for (highlights) |h| {
            if (offset >= h.start and offset < h.end) return true;
        }
        return false;
    }

    // ── Scrollbar indicator ───────────────────────────────────────────

    fn renderScrollbar(self: *const EditorView, renderer: *Renderer, font: *const FontFace) void {
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
        renderer.fillRect(bar_x, bar_y, bar_w, bar_h, theme.surface0);

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

        renderer.fillRect(bar_x, thumb_y, bar_w, thumb_h, theme.overlay0);
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
        const xo = self.x_offset;
        const pw = self.paneWidth(renderer.width);

        // Status bar: 1px top border + cell_height + 4px vertical padding
        const bar_pad: u32 = 4; // 2px top + 2px bottom padding
        const status_y = self.y_offset + self.visible_rows * cell_h;

        // Top border (1px surface2) — subtle separator
        renderer.fillRect(xo, status_y, pw, 1, theme.surface2);

        // Status bar background — fill from separator to bottom of window
        const bar_y = status_y + 1;
        const bar_h = if (renderer.height > bar_y) renderer.height - bar_y else cell_h + bar_pad;
        renderer.fillRect(xo, bar_y, pw, bar_h, theme.mantle);

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
                renderer.drawGlyph(glyph, gx, gy, theme.lavender);
            } else |_| {
                // Fallback: draw '*' as branch indicator
                self.drawStatusChar(renderer, font, '*', left_col, text_y, theme.lavender);
            }
            left_col += 1;
            // Space after icon
            left_col += 1;
            // Branch name in lavender
            for (branch_name) |ch| {
                if (left_col >= self.visible_cols) break;
                self.drawStatusChar(renderer, font, ch, left_col, text_y, theme.lavender);
                left_col += 1;
            }
            // Separator
            const sep = "  |  ";
            for (sep) |ch| {
                if (left_col >= self.visible_cols) break;
                self.drawStatusChar(renderer, font, ch, left_col, text_y, theme.surface2);
                left_col += 1;
            }
        }

        // File path
        const name = self.file_path orelse "[untitled]";
        for (name) |ch| {
            if (left_col >= self.visible_cols) break;
            self.drawStatusChar(renderer, font, ch, left_col, text_y, theme.subtext0);
            left_col += 1;
        }

        if (self.modified) {
            const mod_str = " [+]";
            for (mod_str) |ch| {
                if (left_col >= self.visible_cols) break;
                const color = if (ch == '+') theme.green else theme.subtext0;
                self.drawStatusChar(renderer, font, ch, left_col, text_y, color);
                left_col += 1;
            }
        }

        // -- Selection info (center) --
        const sel = self.cursor.primary();
        var sel_info_buf: [48]u8 = undefined;
        var sel_info_len: usize = 0;
        if (sel.hasSelection()) {
            const sel_chars = sel.end() - sel.start();
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
                self.drawStatusChar(renderer, font, ch, left_col, text_y, theme.surface2);
                left_col += 1;
            }
            for (sel_info_buf[0..sel_info_len]) |ch| {
                if (left_col >= self.visible_cols) break;
                self.drawStatusChar(renderer, font, ch, left_col, text_y, theme.lavender);
                left_col += 1;
            }
        }

        // -- Right section: language, line:col, encoding --
        const lang_name = self.highlighter.languageName();
        var right_buf: [192]u8 = undefined;
        const right_str = formatStatusRight(cursor_line + 1, cursor_col + 1, lang_name, "", &right_buf);
        const right_len: u32 = @intCast(right_str.len);
        const right_start = if (pw / cell_w > right_len + 1) pw / cell_w - right_len - 1 else 0;

        for (right_str, 0..) |ch, i| {
            const col = right_start + @as(u32, @intCast(i));
            if (col >= self.visible_cols) break;
            self.drawStatusChar(renderer, font, ch, col, text_y, theme.subtext0);
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

        // Determine target column from pixel x (adjusted for pane x_offset)
        const gw = self.gutterWidth(font);
        const code_x = @as(i32, @intCast(self.x_offset + gw + self.left_pad));
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
    pub fn visualColAtOffset(self: *const EditorView, line: u32, col: u32) u32 {
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

    pub fn gutterWidth(self: *const EditorView, font: *const FontFace) u32 {
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

    // ── Line operations ───────────────────────────────────────────

    pub fn duplicateLine(self: *EditorView) !void {
        const lc = self.buffer.offsetToLineCol(self.cursor.primary().head);
        const line_start = self.buffer.lineToOffset(lc.line);
        const next_line = if (lc.line + 1 < self.buffer.lineCount())
            self.buffer.lineToOffset(lc.line + 1)
        else
            self.buffer.total_len;

        // Get current line content
        const line_len = next_line - line_start;
        if (line_len == 0) return;

        const content = self.buffer.collectContent(self.allocator) catch return;
        defer self.allocator.free(content);
        const line_text = content[line_start..next_line];

        // If this is the last line (no trailing newline), prepend one
        const needs_newline = (next_line == self.buffer.total_len and (line_text.len == 0 or line_text[line_text.len - 1] != '\n'));

        if (needs_newline) {
            // Insert newline + line text at end
            var buf = self.allocator.alloc(u8, line_text.len + 1) catch return;
            defer self.allocator.free(buf);
            buf[0] = '\n';
            @memcpy(buf[1..], line_text);
            try self.buffer.insert(next_line, buf);
            self.highlighter.notifyEdit(&self.buffer, next_line, next_line, next_line + @as(u32, @intCast(buf.len)));
            self.cursor.moveTo(self.cursor.primary().head + @as(u32, @intCast(buf.len)));
        } else {
            // Insert copy at next line start
            try self.buffer.insert(next_line, line_text);
            self.highlighter.notifyEdit(&self.buffer, next_line, next_line, next_line + line_len);
            self.cursor.moveTo(self.cursor.primary().head + line_len);
        }
        self.modified = true;
        self.markAllDirty();
    }

    pub fn moveLineUp(self: *EditorView) !void {
        const lc = self.buffer.offsetToLineCol(self.cursor.primary().head);
        if (lc.line == 0) return;

        const this_start = self.buffer.lineToOffset(lc.line);
        const this_end = if (lc.line + 1 < self.buffer.lineCount())
            self.buffer.lineToOffset(lc.line + 1)
        else
            self.buffer.total_len;
        const prev_start = self.buffer.lineToOffset(lc.line - 1);

        // Get this line's text
        const content = self.buffer.collectContent(self.allocator) catch return;
        defer self.allocator.free(content);
        const this_line = self.allocator.dupe(u8, content[this_start..this_end]) catch return;
        defer self.allocator.free(this_line);

        // Delete this line, then insert before previous line
        const del_len: u32 = this_end - this_start;
        try self.buffer.delete(this_start, del_len);
        self.highlighter.notifyEdit(&self.buffer, this_start, this_start + del_len, this_start);
        try self.buffer.insert(prev_start, this_line);
        self.highlighter.notifyEdit(&self.buffer, prev_start, prev_start, prev_start + @as(u32, @intCast(this_line.len)));

        // Adjust cursor to same column on new line position
        self.cursor.moveTo(prev_start + lc.col);
        self.modified = true;
        self.markAllDirty();
        self.ensureCursorVisible();
    }

    pub fn moveLineDown(self: *EditorView) !void {
        const lc = self.buffer.offsetToLineCol(self.cursor.primary().head);
        const total = self.buffer.lineCount();
        if (lc.line + 1 >= total) return;

        const this_start = self.buffer.lineToOffset(lc.line);
        const this_end = self.buffer.lineToOffset(lc.line + 1);
        const next_end = if (lc.line + 2 < total)
            self.buffer.lineToOffset(lc.line + 2)
        else
            self.buffer.total_len;

        // Get this line's text and next line's text
        const content = self.buffer.collectContent(self.allocator) catch return;
        defer self.allocator.free(content);
        const this_line = self.allocator.dupe(u8, content[this_start..this_end]) catch return;
        defer self.allocator.free(this_line);
        const next_line_text = self.allocator.dupe(u8, content[this_end..next_end]) catch return;
        defer self.allocator.free(next_line_text);

        // Delete both lines (from this_start to next_end)
        const both_len: u32 = next_end - this_start;
        try self.buffer.delete(this_start, both_len);
        self.highlighter.notifyEdit(&self.buffer, this_start, this_start + both_len, this_start);

        // Insert next line first, then this line
        try self.buffer.insert(this_start, next_line_text);
        self.highlighter.notifyEdit(&self.buffer, this_start, this_start, this_start + @as(u32, @intCast(next_line_text.len)));
        const new_this_start = this_start + @as(u32, @intCast(next_line_text.len));
        try self.buffer.insert(new_this_start, this_line);
        self.highlighter.notifyEdit(&self.buffer, new_this_start, new_this_start, new_this_start + @as(u32, @intCast(this_line.len)));

        // Cursor stays at same column on the moved line
        self.cursor.moveTo(new_this_start + lc.col);
        self.modified = true;
        self.markAllDirty();
        self.ensureCursorVisible();
    }

    pub fn deleteLine(self: *EditorView) !void {
        const lc = self.buffer.offsetToLineCol(self.cursor.primary().head);
        const line_start = self.buffer.lineToOffset(lc.line);
        const next_line = if (lc.line + 1 < self.buffer.lineCount())
            self.buffer.lineToOffset(lc.line + 1)
        else
            self.buffer.total_len;

        if (next_line > line_start) {
            const del_len = next_line - line_start;
            try self.buffer.delete(line_start, del_len);
            self.highlighter.notifyEdit(&self.buffer, line_start, line_start + del_len, line_start);
            self.cursor.moveTo(line_start);
            self.modified = true;
            self.markAllDirty();
            self.ensureCursorVisible();
        }
    }

    // ── Auto-indent newline ───────────────────────────────────────

    pub fn insertNewline(self: *EditorView) !void {
        const lc = self.buffer.offsetToLineCol(self.cursor.primary().head);
        const line_start = self.buffer.lineToOffset(lc.line);

        // Count leading whitespace of current line
        var indent_len: u32 = 0;
        var off = line_start;
        while (off < self.buffer.total_len) {
            const s = self.buffer.contiguousSliceAt(off);
            if (s.len == 0) break;
            if (s[0] == ' ') {
                indent_len += 1;
                off += 1;
            } else if (s[0] == '\t') {
                indent_len += 4;
                off += 1;
            } else break;
        }

        // Check if character before cursor is an opener bracket
        var extra_indent = false;
        const head = self.cursor.primary().head;
        if (head > line_start) {
            const before = self.buffer.contiguousSliceAt(head - 1);
            if (before.len > 0) {
                extra_indent = (before[0] == '{' or before[0] == '(' or before[0] == '[' or before[0] == ':');
            }
        }

        // Build newline + indent
        var buf: [256]u8 = undefined;
        buf[0] = '\n';
        const total_indent = indent_len + if (extra_indent) @as(u32, 4) else 0;
        const safe_indent = @min(total_indent, buf.len - 1);
        @memset(buf[1..][0..safe_indent], ' ');

        try self.insertAtCursor(buf[0 .. safe_indent + 1]);
    }

    // ── Code folding ──────────────────────────────────────────────

    pub fn toggleFold(self: *EditorView) void {
        const lc = self.buffer.offsetToLineCol(self.cursor.primary().head);
        if (self.folded_lines.get(lc.line)) |_| {
            // Unfold
            _ = self.folded_lines.remove(lc.line);
        } else {
            // Find fold range using bracket matching
            if (self.findFoldEnd(lc.line)) |end| {
                if (end > lc.line) {
                    self.folded_lines.put(lc.line, end) catch {};
                }
            }
        }
        self.markAllDirty();
    }

    fn findFoldEnd(self: *EditorView, line: u32) ?u32 {
        // Find the opening brace/paren/bracket on this line
        const line_start = self.buffer.lineToOffset(line);
        const total = self.buffer.lineCount();
        const next_line_off = if (line + 1 < total)
            self.buffer.lineToOffset(line + 1)
        else
            self.buffer.total_len;

        var off = line_start;
        while (off < next_line_off) {
            const s = self.buffer.contiguousSliceAt(off);
            if (s.len == 0) break;
            for (s, 0..) |byte, i| {
                if (off + @as(u32, @intCast(i)) >= next_line_off) break;
                if (byte == '{' or byte == '(' or byte == '[') {
                    // Found opener -- find matching close bracket
                    const open_pos = off + @as(u32, @intCast(i));
                    const open = byte;
                    const close: u8 = switch (byte) {
                        '{' => '}',
                        '(' => ')',
                        '[' => ']',
                        else => unreachable,
                    };
                    if (self.searchBracketForward(open_pos + 1, open, close)) |match_pos| {
                        const match_lc = self.buffer.offsetToLineCol(match_pos);
                        if (match_lc.line > line) return match_lc.line;
                    }
                }
            }
            off += @intCast(s.len);
        }
        return null;
    }

    pub fn isLineFolded(self: *const EditorView, line: u32) bool {
        var it = self.folded_lines.iterator();
        while (it.next()) |entry| {
            if (line > entry.key_ptr.* and line <= entry.value_ptr.*) return true;
        }
        return false;
    }

    // ── Toggle line comment ──────────────────────────────────────

    pub fn toggleComment(self: *EditorView) !void {
        const comment_prefix = self.getCommentPrefix();

        const sel = self.cursor.primary();
        const start_lc = self.buffer.offsetToLineCol(sel.start());
        const end_lc = self.buffer.offsetToLineCol(if (sel.hasSelection()) sel.end() -| 1 else sel.head);

        // Check if ALL lines in range start with the comment prefix (after whitespace)
        var all_commented = true;
        var line = start_lc.line;
        while (line <= end_lc.line) : (line += 1) {
            const line_start = self.buffer.lineToOffset(line);
            var off = line_start;
            while (off < self.buffer.total_len) {
                const s = self.buffer.contiguousSliceAt(off);
                if (s.len == 0 or (s[0] != ' ' and s[0] != '\t')) break;
                off += 1;
            }
            if (!self.hasCommentAt(off, comment_prefix)) {
                all_commented = false;
                break;
            }
        }

        // Apply: toggle comment on each line, back-to-front to preserve offsets
        var apply_line = end_lc.line + 1;
        while (apply_line > start_lc.line) {
            apply_line -= 1;
            const line_start = self.buffer.lineToOffset(apply_line);

            if (all_commented) {
                // Remove comment prefix
                var off = line_start;
                while (off < self.buffer.total_len) {
                    const s = self.buffer.contiguousSliceAt(off);
                    if (s.len == 0 or (s[0] != ' ' and s[0] != '\t')) break;
                    off += 1;
                }
                if (self.hasCommentAt(off, comment_prefix)) {
                    var del_len: u32 = @intCast(comment_prefix.len);
                    if (off + del_len < self.buffer.total_len) {
                        const after = self.buffer.contiguousSliceAt(off + del_len);
                        if (after.len > 0 and after[0] == ' ') del_len += 1;
                    }
                    try self.buffer.delete(off, del_len);
                    self.highlighter.notifyEdit(&self.buffer, off, off + del_len, off);
                }
            } else {
                // Add comment prefix after existing indent
                var off = line_start;
                while (off < self.buffer.total_len) {
                    const s = self.buffer.contiguousSliceAt(off);
                    if (s.len == 0 or (s[0] != ' ' and s[0] != '\t')) break;
                    off += 1;
                }
                var prefix_buf: [8]u8 = undefined;
                const plen = comment_prefix.len;
                @memcpy(prefix_buf[0..plen], comment_prefix);
                prefix_buf[plen] = ' ';
                const prefix_with_space = prefix_buf[0 .. plen + 1];
                try self.buffer.insert(off, prefix_with_space);
                self.highlighter.notifyEdit(&self.buffer, off, off, off + @as(u32, @intCast(prefix_with_space.len)));
            }
        }

        self.modified = true;
        self.markAllDirty();
    }

    fn getCommentPrefix(self: *const EditorView) []const u8 {
        const lang = self.highlighter.languageName();
        if (std.mem.eql(u8, lang, "Python")) return "#";
        if (std.mem.eql(u8, lang, "Bash")) return "#";
        return "//"; // C, Rust, JavaScript, Zig, default
    }

    fn hasCommentAt(self: *const EditorView, off: u32, prefix: []const u8) bool {
        if (off + prefix.len > self.buffer.total_len) return false;
        for (prefix, 0..) |ch, i| {
            const s = self.buffer.contiguousSliceAt(off + @as(u32, @intCast(i)));
            if (s.len == 0 or s[0] != ch) return false;
        }
        return true;
    }

    // ── Select line ──────────────────────────────────────────────────

    pub fn selectLine(self: *EditorView) void {
        const lc = self.buffer.offsetToLineCol(self.cursor.primary().head);
        const line_start = self.buffer.lineToOffset(lc.line);
        const next_line = if (lc.line + 1 < self.buffer.lineCount())
            self.buffer.lineToOffset(lc.line + 1)
        else
            self.buffer.total_len;
        self.cursor.cursors.items[0] = .{ .anchor = line_start, .head = next_line };
        self.markAllDirty();
    }

    // ── Bracket matching ──────────────────────────────────────────

    const BracketPair = struct { open: u8, close: u8, forward: bool };

    pub fn findMatchingBracket(self: *const EditorView) ?u32 {
        const pos = self.cursor.primary().head;
        if (pos >= self.buffer.total_len) return null;

        const slice = self.buffer.contiguousSliceAt(pos);
        if (slice.len == 0) return null;

        const ch = slice[0];
        const info = getBracketPair(ch) orelse return null;

        if (info.forward) {
            return self.searchBracketForward(pos + 1, info.open, info.close);
        } else {
            return self.searchBracketBackward(pos, info.open, info.close);
        }
    }

    fn getBracketPair(ch: u8) ?BracketPair {
        return switch (ch) {
            '(' => .{ .open = '(', .close = ')', .forward = true },
            ')' => .{ .open = '(', .close = ')', .forward = false },
            '[' => .{ .open = '[', .close = ']', .forward = true },
            ']' => .{ .open = '[', .close = ']', .forward = false },
            '{' => .{ .open = '{', .close = '}', .forward = true },
            '}' => .{ .open = '{', .close = '}', .forward = false },
            else => null,
        };
    }

    fn searchBracketForward(self: *const EditorView, start: u32, open: u8, close: u8) ?u32 {
        var depth: i32 = 1;
        var off = start;
        while (off < self.buffer.total_len) {
            const s = self.buffer.contiguousSliceAt(off);
            if (s.len == 0) break;
            for (s) |byte| {
                if (byte == open) {
                    depth += 1;
                } else if (byte == close) {
                    depth -= 1;
                    if (depth == 0) return off;
                }
                off += 1;
            }
        }
        return null;
    }

    fn searchBracketBackward(self: *const EditorView, pos: u32, open: u8, close: u8) ?u32 {
        if (pos == 0) return null;
        var depth: i32 = 1;
        var off = pos - 1;
        while (true) {
            const s = self.buffer.contiguousSliceAt(off);
            if (s.len == 0) break;
            const byte = s[0];
            if (byte == close) {
                depth += 1;
            } else if (byte == open) {
                depth -= 1;
                if (depth == 0) return off;
            }
            if (off == 0) break;
            off -= 1;
        }
        return null;
    }

    // ── Indent guides ────────────────────────────────────────────────

    fn renderIndentGuides(self: *const EditorView, renderer: *Renderer, font: *const FontFace, line_start_offset: u32, screen_row: u32, code_x: u32) void {
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
        const guide_color = theme.surface2;
        var level: u32 = tab_size;
        while (level < indent) : (level += tab_size) {
            const guide_x = code_x + self.left_pad + level * cell_w;
            renderer.fillRect(guide_x, row_y, 1, cell_h, guide_color);
        }
    }

    // ── Auto-closing brackets/quotes ─────────────────────────────────

    pub fn insertWithAutoClose(self: *EditorView, text: []const u8) !bool {
        if (text.len != 1) return false;

        const ch = text[0];
        const pair: ?u8 = switch (ch) {
            '(' => @as(u8, ')'),
            '[' => @as(u8, ']'),
            '{' => @as(u8, '}'),
            '"' => @as(u8, '"'),
            '\'' => @as(u8, '\''),
            '`' => @as(u8, '`'),
            else => null,
        };

        const close = pair orelse return false;

        // For quotes: don't auto-close if previous char is alphanumeric (mid-word)
        if (ch == '"' or ch == '\'' or ch == '`') {
            const pos = self.cursor.primary().head;
            if (pos > 0) {
                const prev = self.buffer.contiguousSliceAt(pos - 1);
                if (prev.len > 0 and isWordChar(prev[0])) return false;
            }
        }

        // Skip-over: if next char is the same closing char, just move past it
        const pos = self.cursor.primary().head;
        if (pos < self.buffer.total_len) {
            const next = self.buffer.contiguousSliceAt(pos);
            if (next.len > 0 and next[0] == close and ch == close) {
                self.cursor.moveTo(pos + 1);
                self.markAllDirty();
                return true;
            }
        }

        // Insert both chars, position cursor between them
        var buf: [2]u8 = .{ ch, close };
        try self.insertAtCursor(&buf);
        // Move cursor back one position (between the pair)
        self.cursor.moveTo(self.cursor.primary().head - 1);
        return true;
    }

    pub fn backspaceWithPairDelete(self: *EditorView) !bool {
        const pos = self.cursor.primary().head;
        if (pos == 0 or pos >= self.buffer.total_len) return false;

        const prev = self.buffer.contiguousSliceAt(pos - 1);
        const next = self.buffer.contiguousSliceAt(pos);
        if (prev.len == 0 or next.len == 0) return false;

        const is_pair = (prev[0] == '(' and next[0] == ')') or
            (prev[0] == '[' and next[0] == ']') or
            (prev[0] == '{' and next[0] == '}') or
            (prev[0] == '"' and next[0] == '"') or
            (prev[0] == '\'' and next[0] == '\'') or
            (prev[0] == '`' and next[0] == '`');

        if (is_pair) {
            try self.buffer.delete(pos - 1, 2);
            self.highlighter.notifyEdit(&self.buffer, pos - 1, pos + 1, pos - 1);
            self.cursor.moveTo(pos - 1);
            self.modified = true;
            self.ensureCursorVisible();
            self.markAllDirty();
            return true;
        }
        return false;
    }
};

// ── Tab bar rendering ─────────────────────────────────────────────
const TabManager = @import("tabs.zig").TabManager;

/// Compute the tab bar height in pixels.
pub fn tabBarHeight(font: *const FontFace) u32 {
    return font.cell_height + 10; // cell height + top accent (2px) + padding (8px) — taller Zed-like tabs
}

/// Render the tab bar at the top of the window.
pub fn renderTabBar(
    tab_mgr: *const TabManager,
    renderer: *Renderer,
    font: *FontFace,
    x_start: u32,
) void {
    const cell_w = font.cell_width;
    if (cell_w == 0 or font.cell_height == 0) return;

    const bar_h = tabBarHeight(font);
    const win_w = renderer.width;

    // Full bar background (mantle — darker than editor)
    renderer.fillRect(0, 0, win_w, bar_h, theme.mantle);

    // Bottom separator (1px surface2)
    renderer.fillRect(0, bar_h - 1, win_w, 1, theme.surface2);

    // Render each tab (offset by sidebar width)
    var x: u32 = x_start + 4;
    for (tab_mgr.tabs.items, 0..) |tab, i| {
        const is_active = (i == tab_mgr.active);
        const bg = if (is_active) theme.base else theme.mantle;
        const fg = if (is_active) theme.text else theme.overlay0;

        // Tab label
        const label = if (tab.file_path) |p| basename(p) else "[untitled]";
        const label_len: u32 = @intCast(label.len);
        const mod_extra: u32 = if (tab.modified) 2 else 0; // " +"
        const tab_w = (label_len + mod_extra + 3) * cell_w; // +3 for generous horizontal padding

        // Tab background (full height minus bottom separator)
        renderer.fillRect(x, 0, tab_w, bar_h - 1, bg);

        // Active tab: 2px lavender accent line at TOP
        if (is_active) {
            renderer.fillRect(x, 0, tab_w, 2, theme.lavender);
        }

        // Tab label text — vertically centered
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
                renderer.drawGlyph(glyph, gx, gy, theme.green);
            } else |_| {}
        }

        x += tab_w + 1; // 1px gap between tabs
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
