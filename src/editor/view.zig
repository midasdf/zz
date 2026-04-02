const std = @import("std");
const PieceTable = @import("buffer.zig").PieceTable;
const CursorState = @import("cursor.zig").CursorState;
const Selection = @import("cursor.zig").Selection;
pub const Highlighter = @import("highlight.zig").Highlighter;
const Renderer = @import("../ui/render.zig").Renderer;
const FontFace = @import("../ui/font.zig").FontFace;
const Color = @import("../ui/render.zig").Color;
const Diagnostic = @import("../lsp/client.zig").Diagnostic;
pub const GitInfo = @import("../core/git.zig").GitInfo;

// ── Theme system ──────────────────────────────────────────────────
pub const Theme = struct {
    // UI colors
    base: Color,
    mantle: Color,
    surface0: Color,
    surface1: Color,
    surface2: Color,
    overlay0: Color,
    text: Color,
    subtext0: Color,
    rosewater: Color,
    lavender: Color,
    green: Color,
    red: Color,
    peach: Color,
    mauve: Color,
    // Syntax colors
    syn_keyword: Color,
    syn_function: Color,
    syn_func_builtin: Color,
    syn_type: Color,
    syn_string: Color,
    syn_number: Color,
    syn_comment: Color,
    syn_operator: Color,
    syn_variable: Color,
    syn_constant: Color,
    syn_property: Color,
    syn_punctuation: Color,
};

pub const themes = struct {
    pub const catppuccin_mocha = Theme{
        .base = Color.fromHex(0x1e1e2e),
        .mantle = Color.fromHex(0x181825),
        .surface0 = Color.fromHex(0x313244),
        .surface1 = Color.fromHex(0x45475a),
        .surface2 = Color.fromHex(0x585b70),
        .overlay0 = Color.fromHex(0x6c7086),
        .text = Color.fromHex(0xcdd6f4),
        .subtext0 = Color.fromHex(0xa6adc8),
        .rosewater = Color.fromHex(0xf5e0dc),
        .lavender = Color.fromHex(0xb4befe),
        .green = Color.fromHex(0xa6e3a1),
        .red = Color.fromHex(0xf38ba8),
        .peach = Color.fromHex(0xfab387),
        .mauve = Color.fromHex(0xcba6f7),
        .syn_keyword = Color.fromHex(0xcba6f7),
        .syn_function = Color.fromHex(0x89b4fa),
        .syn_func_builtin = Color.fromHex(0xf9e2af),
        .syn_type = Color.fromHex(0xf9e2af),
        .syn_string = Color.fromHex(0xa6e3a1),
        .syn_number = Color.fromHex(0xfab387),
        .syn_comment = Color.fromHex(0x6c7086),
        .syn_operator = Color.fromHex(0x89dceb),
        .syn_variable = Color.fromHex(0xcdd6f4),
        .syn_constant = Color.fromHex(0xfab387),
        .syn_property = Color.fromHex(0x89b4fa),
        .syn_punctuation = Color.fromHex(0x9399b2),
    };

    pub const tokyo_night = Theme{
        .base = Color.fromHex(0x1a1b26),
        .mantle = Color.fromHex(0x16161e),
        .surface0 = Color.fromHex(0x292e42),
        .surface1 = Color.fromHex(0x3b4261),
        .surface2 = Color.fromHex(0x545c7e),
        .overlay0 = Color.fromHex(0x565f89),
        .text = Color.fromHex(0xc0caf5),
        .subtext0 = Color.fromHex(0xa9b1d6),
        .rosewater = Color.fromHex(0xf7768e),
        .lavender = Color.fromHex(0x7aa2f7),
        .green = Color.fromHex(0x9ece6a),
        .red = Color.fromHex(0xf7768e),
        .peach = Color.fromHex(0xff9e64),
        .mauve = Color.fromHex(0xbb9af7),
        .syn_keyword = Color.fromHex(0xbb9af7),
        .syn_function = Color.fromHex(0x7aa2f7),
        .syn_func_builtin = Color.fromHex(0xe0af68),
        .syn_type = Color.fromHex(0x2ac3de),
        .syn_string = Color.fromHex(0x9ece6a),
        .syn_number = Color.fromHex(0xff9e64),
        .syn_comment = Color.fromHex(0x565f89),
        .syn_operator = Color.fromHex(0x89ddff),
        .syn_variable = Color.fromHex(0xc0caf5),
        .syn_constant = Color.fromHex(0xff9e64),
        .syn_property = Color.fromHex(0x73daca),
        .syn_punctuation = Color.fromHex(0xa9b1d6),
    };

    pub const gruvbox_dark = Theme{
        .base = Color.fromHex(0x282828),
        .mantle = Color.fromHex(0x1d2021),
        .surface0 = Color.fromHex(0x3c3836),
        .surface1 = Color.fromHex(0x504945),
        .surface2 = Color.fromHex(0x665c54),
        .overlay0 = Color.fromHex(0x7c6f64),
        .text = Color.fromHex(0xebdbb2),
        .subtext0 = Color.fromHex(0xd5c4a1),
        .rosewater = Color.fromHex(0xfb4934),
        .lavender = Color.fromHex(0x83a598),
        .green = Color.fromHex(0xb8bb26),
        .red = Color.fromHex(0xfb4934),
        .peach = Color.fromHex(0xfe8019),
        .mauve = Color.fromHex(0xd3869b),
        .syn_keyword = Color.fromHex(0xfb4934),
        .syn_function = Color.fromHex(0xb8bb26),
        .syn_func_builtin = Color.fromHex(0xfabd2f),
        .syn_type = Color.fromHex(0xfabd2f),
        .syn_string = Color.fromHex(0xb8bb26),
        .syn_number = Color.fromHex(0xd3869b),
        .syn_comment = Color.fromHex(0x928374),
        .syn_operator = Color.fromHex(0x8ec07c),
        .syn_variable = Color.fromHex(0xebdbb2),
        .syn_constant = Color.fromHex(0xd3869b),
        .syn_property = Color.fromHex(0x83a598),
        .syn_punctuation = Color.fromHex(0xa89984),
    };

    pub const one_dark = Theme{
        .base = Color.fromHex(0x282c34),
        .mantle = Color.fromHex(0x21252b),
        .surface0 = Color.fromHex(0x2c313a),
        .surface1 = Color.fromHex(0x3e4451),
        .surface2 = Color.fromHex(0x5c6370),
        .overlay0 = Color.fromHex(0x636d83),
        .text = Color.fromHex(0xabb2bf),
        .subtext0 = Color.fromHex(0x9da5b4),
        .rosewater = Color.fromHex(0xe06c75),
        .lavender = Color.fromHex(0x61afef),
        .green = Color.fromHex(0x98c379),
        .red = Color.fromHex(0xe06c75),
        .peach = Color.fromHex(0xd19a66),
        .mauve = Color.fromHex(0xc678dd),
        .syn_keyword = Color.fromHex(0xc678dd),
        .syn_function = Color.fromHex(0x61afef),
        .syn_func_builtin = Color.fromHex(0xe5c07b),
        .syn_type = Color.fromHex(0xe5c07b),
        .syn_string = Color.fromHex(0x98c379),
        .syn_number = Color.fromHex(0xd19a66),
        .syn_comment = Color.fromHex(0x5c6370),
        .syn_operator = Color.fromHex(0x56b6c2),
        .syn_variable = Color.fromHex(0xabb2bf),
        .syn_constant = Color.fromHex(0xd19a66),
        .syn_property = Color.fromHex(0xe06c75),
        .syn_punctuation = Color.fromHex(0xabb2bf),
    };

    pub const names = [_][]const u8{ "Catppuccin Mocha", "Tokyo Night", "Gruvbox Dark", "One Dark" };
    pub const all = [_]*const Theme{ &catppuccin_mocha, &tokyo_night, &gruvbox_dark, &one_dark };
};

var active_theme: *const Theme = &themes.catppuccin_mocha;

pub fn setTheme(t: *const Theme) void {
    active_theme = t;
}

pub fn cycleTheme() void {
    for (themes.all, 0..) |t, i| {
        if (t == active_theme) {
            active_theme = themes.all[(i + 1) % themes.all.len];
            return;
        }
    }
    active_theme = themes.all[0];
}

pub fn getActiveTheme() *const Theme {
    return active_theme;
}

pub fn activeThemeName() []const u8 {
    for (themes.all, 0..) |t, i| {
        if (t == active_theme) return themes.names[i];
    }
    return "Unknown";
}

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
    word_wrap: bool = false,
    sticky_scroll_visible: bool = true,
    folded_lines: std.AutoHashMap(u32, u32), // start_line -> end_line (exclusive)

    // Status bar action buttons — state passed from main, hit-boxes written by renderStatusBar
    status_terminal_visible: bool = false,
    status_diagnostic_count: u32 = 0,
    status_btn_terminal_x: u32 = 0, // pixel x of terminal button
    status_btn_terminal_w: u32 = 0, // pixel width of terminal button
    status_btn_diag_x: u32 = 0, // pixel x of diagnostics button
    status_btn_diag_w: u32 = 0, // pixel width of diagnostics button
    status_btn_gear_x: u32 = 0, // pixel x of settings gear
    status_btn_gear_w: u32 = 0, // pixel width of settings gear
    status_bar_y: u32 = 0, // pixel y of status bar top

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

    pub fn deleteWordLeft(self: *EditorView) !void {
        const sel = self.cursor.primary();
        if (sel.hasSelection()) {
            try self.deleteSelection();
            return;
        }

        const pos = sel.head;
        if (pos == 0) return;

        var new_pos = pos - 1;

        // Skip whitespace first (but stop at newline)
        while (new_pos > 0) {
            const s = self.buffer.contiguousSliceAt(new_pos);
            if (s.len == 0) break;
            if (s[0] == '\n') break;
            if (s[0] != ' ' and s[0] != '\t') break;
            new_pos -= 1;
        }

        // Check if we landed on a newline -- just delete back to it
        {
            const s = self.buffer.contiguousSliceAt(new_pos);
            if (s.len > 0 and s[0] == '\n') {
                // If we only skipped whitespace to hit newline, delete up to (not including) newline
                if (new_pos + 1 < pos) {
                    // Delete the whitespace between newline and original pos
                    const del_start = new_pos + 1;
                    try self.buffer.delete(del_start, pos - del_start);
                    self.highlighter.notifyEdit(&self.buffer, del_start, pos, del_start);
                    self.cursor.moveTo(del_start);
                } else {
                    // Cursor was right after newline, delete the newline
                    try self.buffer.delete(new_pos, 1);
                    self.highlighter.notifyEdit(&self.buffer, new_pos, new_pos + 1, new_pos);
                    self.cursor.moveTo(new_pos);
                }
                self.modified = true;
                self.markAllDirty();
                self.ensureCursorVisible();
                return;
            }
        }

        // Then skip word chars
        while (new_pos > 0) {
            const prev = self.buffer.contiguousSliceAt(new_pos - 1);
            if (prev.len == 0) break;
            if (!isWordChar(prev[0])) break;
            new_pos -= 1;
        }
        // Check current position too
        {
            const s = self.buffer.contiguousSliceAt(new_pos);
            if (s.len > 0 and !isWordChar(s[0]) and new_pos + 1 < pos) {
                // We're on a non-word char after skipping whitespace;
                // the word ends at new_pos+1, but if we started on a non-word char
                // we should delete just the non-word chars
                new_pos += 1;
            }
        }

        if (new_pos < pos) {
            try self.buffer.delete(new_pos, pos - new_pos);
            self.highlighter.notifyEdit(&self.buffer, new_pos, pos, new_pos);
            self.cursor.moveTo(new_pos);
            self.modified = true;
            self.markAllDirty();
            self.ensureCursorVisible();
        }
    }

    pub fn deleteWordRight(self: *EditorView) !void {
        const sel = self.cursor.primary();
        if (sel.hasSelection()) {
            try self.deleteSelection();
            return;
        }

        const pos = sel.head;
        if (pos >= self.buffer.total_len) return;

        var end_pos = pos;

        // Check what we're starting on
        const first = self.buffer.contiguousSliceAt(pos);
        if (first.len == 0) return;

        if (first[0] == '\n') {
            // Just delete the newline
            try self.buffer.delete(pos, 1);
            self.highlighter.notifyEdit(&self.buffer, pos, pos + 1, pos);
            self.modified = true;
            self.markAllDirty();
            return;
        }

        if (isWordChar(first[0])) {
            // Skip word chars first
            while (end_pos < self.buffer.total_len) {
                const s = self.buffer.contiguousSliceAt(end_pos);
                if (s.len == 0) break;
                if (!isWordChar(s[0])) break;
                end_pos += 1;
            }
            // Then skip trailing whitespace (but not newlines)
            while (end_pos < self.buffer.total_len) {
                const s = self.buffer.contiguousSliceAt(end_pos);
                if (s.len == 0) break;
                if (s[0] != ' ' and s[0] != '\t') break;
                end_pos += 1;
            }
        } else {
            // On whitespace or punctuation: skip non-word, non-newline chars
            while (end_pos < self.buffer.total_len) {
                const s = self.buffer.contiguousSliceAt(end_pos);
                if (s.len == 0) break;
                if (s[0] == '\n') break;
                if (isWordChar(s[0])) break;
                end_pos += 1;
            }
        }

        if (end_pos > pos) {
            const del_len = end_pos - pos;
            try self.buffer.delete(pos, del_len);
            self.highlighter.notifyEdit(&self.buffer, pos, pos + del_len, pos);
            self.modified = true;
            self.markAllDirty();
        }
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

        const sel_len: u32 = @intCast(selected.len);

        // Search forward from last cursor using piece-table indexOf
        if (self.buffer.indexOf(selected, search_from)) |abs_pos| {
            if (!self.hasCursorAt(abs_pos, abs_pos + sel_len)) {
                try self.cursor.addSelection(.{
                    .anchor = abs_pos,
                    .head = abs_pos + sel_len,
                });
                self.markAllDirty();
                return;
            }
        }

        // Wrap around: search from beginning
        if (self.buffer.indexOf(selected, 0)) |abs_pos| {
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

        const sel_len: u32 = @intCast(selected.len);

        // Clear all cursors and re-add for every occurrence using piece-table indexOf
        self.cursor.cursors.clearRetainingCapacity();

        var search_pos: u32 = 0;
        while (self.buffer.indexOf(selected, search_pos)) |abs_pos| {
            self.cursor.cursors.append(self.allocator, .{
                .anchor = abs_pos,
                .head = abs_pos + sel_len,
            }) catch break;
            search_pos = abs_pos + sel_len;
        }

        // Ensure at least one cursor
        if (self.cursor.cursors.items.len == 0) {
            self.cursor.cursors.append(self.allocator, .{ .anchor = 0, .head = 0 }) catch {};
        }

        self.markAllDirty();
    }

    fn selectWordAtCursor(self: *EditorView) void {
        self.selectWordAtPosition(self.cursor.primary().head);
    }

    /// Select the word at a given byte offset (used by double-click).
    pub fn selectWordAtPosition(self: *EditorView, pos: u32) void {
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

    /// Select the entire line at a given byte offset (used by triple-click).
    pub fn selectLineAtPosition(self: *EditorView, pos: u32) void {
        const lc = self.buffer.offsetToLineCol(pos);
        const line_start = self.buffer.lineToOffset(lc.line);
        const next_line = if (lc.line + 1 < self.buffer.lineCount())
            self.buffer.lineToOffset(lc.line + 1)
        else
            self.buffer.total_len;
        self.cursor.cursors.items[0] = .{ .anchor = line_start, .head = next_line };
        self.markAllDirty();
    }

    fn hasCursorAt(self: *const EditorView, anchor: u32, head: u32) bool {
        for (self.cursor.cursors.items) |c| {
            if (c.anchor == anchor and c.head == head) return true;
            if (c.anchor == head and c.head == anchor) return true;
        }
        return false;
    }

    // ── Rendering (delegated to view_render.zig) ────────────────────

    const view_render = @import("view_render.zig");

    pub fn render(self: *EditorView, renderer: *Renderer, font: *FontFace) void {
        view_render.render(self, renderer, font);
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

    /// Check if a pixel coordinate is within the scrollbar track area.
    pub fn isInScrollbar(self: *const EditorView, px: i32, py: i32, font: *const FontFace) bool {
        const cell_h = font.cell_height;
        if (cell_h == 0) return false;
        const total_lines = self.buffer.lineCount();
        if (total_lines <= self.visible_rows) return false;

        const pw = self.paneWidth(0);
        const mm_offset: u32 = if (self.minimap_visible) self.minimap_width else 0;
        if (pw <= mm_offset + 8) return false;
        const bar_x = self.x_offset + pw - mm_offset - 8;
        const bar_y = self.y_offset;
        const bar_h = self.visible_rows * cell_h;
        const bar_w: u32 = 6;

        return px >= @as(i32, @intCast(bar_x)) and
            px < @as(i32, @intCast(bar_x + bar_w + 4)) and // extra 4px click target
            py >= @as(i32, @intCast(bar_y)) and
            py < @as(i32, @intCast(bar_y + bar_h));
    }

    /// Handle a scrollbar click/drag: convert pixel Y to scroll_line.
    pub fn handleScrollbarClick(self: *EditorView, py: i32, font: *const FontFace) void {
        const cell_h = font.cell_height;
        if (cell_h == 0) return;
        const total_lines = self.buffer.lineCount();
        if (total_lines <= self.visible_rows) return;

        const bar_y = self.y_offset;
        const bar_h = self.visible_rows * cell_h;
        if (bar_h == 0) return;

        const rel_y: f32 = @floatFromInt(@max(py - @as(i32, @intCast(bar_y)), 0));
        const bar_h_f: f32 = @floatFromInt(bar_h);
        const ratio = @min(rel_y / bar_h_f, 1.0);
        const max_scroll = total_lines -| self.visible_rows;
        self.scroll_line = @intFromFloat(ratio * @as(f32, @floatFromInt(max_scroll)));
        self.markAllDirty();
    }

    // ── Internal helpers ───────────────────────────────────────────

    /// Check if a byte offset falls within any cursor's selection.
    pub fn isInAnySelection(self: *const EditorView, offset: u32) bool {
        for (self.cursor.cursors.items) |c| {
            if (c.hasSelection() and offset >= c.start() and offset < c.end()) {
                return true;
            }
        }
        return false;
    }

    pub fn advancePastLine(self: *const EditorView, start_offset: u32) u32 {
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

    pub fn gutterDigits(self: *const EditorView) u32 {
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

        const line_text = self.buffer.extractRange(self.allocator, line_start, next_line) catch return;
        defer self.allocator.free(line_text);

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
        const this_line = self.buffer.extractRange(self.allocator, this_start, this_end) catch return;
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
        const this_line = self.buffer.extractRange(self.allocator, this_start, this_end) catch return;
        defer self.allocator.free(this_line);
        const next_line_text = self.buffer.extractRange(self.allocator, this_end, next_end) catch return;
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

    // ── Join lines (Ctrl+J) ────────────────────────────────────────

    pub fn joinLines(self: *EditorView) !void {
        const lc = self.buffer.offsetToLineCol(self.cursor.primary().head);
        if (lc.line + 1 >= self.buffer.lineCount()) return;

        // Find end of current line (the newline character)
        const next_line = self.buffer.lineToOffset(lc.line + 1);
        const newline_pos = next_line - 1;

        // Count leading whitespace on next line
        var ws_end = next_line;
        while (ws_end < self.buffer.total_len) {
            const s = self.buffer.contiguousSliceAt(ws_end);
            if (s.len == 0) break;
            if (s[0] != ' ' and s[0] != '\t') break;
            ws_end += 1;
        }

        // Delete from newline through leading whitespace, replace with single space
        const del_len = ws_end - newline_pos;
        try self.buffer.delete(newline_pos, del_len);
        self.highlighter.notifyEdit(&self.buffer, newline_pos, newline_pos + del_len, newline_pos);
        try self.buffer.insert(newline_pos, " ");
        self.highlighter.notifyEdit(&self.buffer, newline_pos, newline_pos, newline_pos + 1);

        self.cursor.moveTo(newline_pos);
        self.modified = true;
        self.markAllDirty();
        self.ensureCursorVisible();
    }

    // ── Insert line above/below ──────────────────────────────────────

    pub fn insertLineBelow(self: *EditorView) !void {
        // Move to end of current line, then insert newline with auto-indent
        const lc = self.buffer.offsetToLineCol(self.cursor.primary().head);
        const next_line = if (lc.line + 1 < self.buffer.lineCount())
            self.buffer.lineToOffset(lc.line + 1)
        else
            self.buffer.total_len;

        // Position cursor at end of current line (before newline)
        const eol = if (next_line > 0 and lc.line + 1 < self.buffer.lineCount()) next_line - 1 else next_line;
        self.cursor.moveTo(eol);

        // Insert newline with auto-indent
        try self.insertNewline();
    }

    pub fn insertLineAbove(self: *EditorView) !void {
        const lc = self.buffer.offsetToLineCol(self.cursor.primary().head);
        const line_start = self.buffer.lineToOffset(lc.line);

        // Get indent of current line
        const indent = self.getLineIndent(lc.line);
        var buf: [257]u8 = undefined;
        const safe_indent = @min(indent, 256);
        @memset(buf[0..safe_indent], ' ');
        buf[safe_indent] = '\n';

        try self.buffer.insert(line_start, buf[0 .. safe_indent + 1]);
        self.highlighter.notifyEdit(&self.buffer, line_start, line_start, line_start + safe_indent + 1);
        self.cursor.moveTo(line_start + safe_indent);
        self.modified = true;
        self.markAllDirty();
        self.ensureCursorVisible();
    }

    fn getLineIndent(self: *const EditorView, line: u32) u32 {
        const line_start = self.buffer.lineToOffset(line);
        var indent: u32 = 0;
        var off = line_start;
        while (off < self.buffer.total_len) {
            const s = self.buffer.contiguousSliceAt(off);
            if (s.len == 0) break;
            if (s[0] == ' ') {
                indent += 1;
                off += 1;
            } else if (s[0] == '\t') {
                indent += 4;
                off += 1;
            } else break;
        }
        return indent;
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

    // ── Indent / Outdent selected lines ─────────────────────────────

    pub fn indentSelectedLines(self: *EditorView) !void {
        const sel = self.cursor.primary();
        if (!sel.hasSelection()) return;

        const start_lc = self.buffer.offsetToLineCol(sel.start());
        const end_lc = self.buffer.offsetToLineCol(sel.end() -| 1);

        // Process back-to-front to preserve earlier offsets
        var line = end_lc.line + 1;
        while (line > start_lc.line) {
            line -= 1;
            const line_start = self.buffer.lineToOffset(line);
            try self.buffer.insert(line_start, "    ");
            self.highlighter.notifyEdit(&self.buffer, line_start, line_start, line_start + 4);
        }

        // Adjust selection to cover the indented range
        const lines_count = end_lc.line - start_lc.line + 1;
        const cur = &self.cursor.cursors.items[0];
        if (cur.anchor <= cur.head) {
            cur.anchor = cur.anchor + 4;
            cur.head = cur.head + lines_count * 4;
        } else {
            cur.head = cur.head + 4;
            cur.anchor = cur.anchor + lines_count * 4;
        }

        self.modified = true;
        self.markAllDirty();
    }

    pub fn outdentSelectedLines(self: *EditorView) !void {
        const sel = self.cursor.primary();
        const start_lc = self.buffer.offsetToLineCol(if (sel.hasSelection()) sel.start() else sel.head);
        const end_lc = self.buffer.offsetToLineCol(if (sel.hasSelection()) sel.end() -| 1 else sel.head);

        // Process back-to-front to preserve earlier offsets
        var line = end_lc.line + 1;
        while (line > start_lc.line) {
            line -= 1;
            const line_start = self.buffer.lineToOffset(line);
            // Count up to 4 leading spaces to remove
            var remove: u32 = 0;
            var off = line_start;
            while (remove < 4 and off < self.buffer.total_len) {
                const s = self.buffer.contiguousSliceAt(off);
                if (s.len == 0 or s[0] != ' ') break;
                remove += 1;
                off += 1;
            }
            if (remove > 0) {
                try self.buffer.delete(line_start, remove);
                self.highlighter.notifyEdit(&self.buffer, line_start, line_start + remove, line_start);
            }
        }

        self.modified = true;
        self.markAllDirty();
        self.ensureCursorVisible();
    }

    // ── Go to matching bracket ──────────────────────────────────────

    pub fn gotoMatchingBracket(self: *EditorView) void {
        if (self.findMatchingBracket()) |match_pos| {
            self.cursor.moveTo(match_pos);
            self.ensureCursorVisible();
            self.markAllDirty();
        }
    }

    // ── Smart selection expand/shrink ──────────────────────────────

    pub fn expandSelection(self: *EditorView) void {
        const sel = self.cursor.primary();

        if (!sel.hasSelection()) {
            // First expand: select current word
            self.selectWordAtCursor();
            return;
        }

        // Already has selection: try expanding to enclosing brackets/braces
        const start = sel.start();
        const end_pos = sel.end();

        // Search backward for opening bracket
        var s: u32 = if (start > 0) start - 1 else start;
        var depth: i32 = 0;
        var found_open = false;
        while (true) {
            const slice = self.buffer.contiguousSliceAt(s);
            if (slice.len == 0) break;
            const ch = slice[0];
            if (ch == ')' or ch == ']' or ch == '}') {
                depth += 1;
            } else if (ch == '(' or ch == '[' or ch == '{') {
                if (depth == 0) {
                    found_open = true;
                    break;
                }
                depth -= 1;
            }
            if (s == 0) break;
            s -= 1;
        }

        if (!found_open) {
            // No enclosing bracket found: expand to full line, then full buffer
            const start_lc = self.buffer.offsetToLineCol(start);
            const end_lc = self.buffer.offsetToLineCol(end_pos);
            const line_start = self.buffer.lineToOffset(start_lc.line);
            const next_after_end = if (end_lc.line + 1 < self.buffer.lineCount())
                self.buffer.lineToOffset(end_lc.line + 1)
            else
                self.buffer.total_len;

            if (line_start < start or next_after_end > end_pos) {
                // Expand to full lines
                self.cursor.cursors.items[0] = .{ .anchor = line_start, .head = next_after_end };
            } else {
                // Already full lines: expand to whole buffer
                self.cursor.cursors.items[0] = .{ .anchor = 0, .head = self.buffer.total_len };
            }
            self.markAllDirty();
            return;
        }

        // Find matching close bracket
        const open_ch = self.buffer.contiguousSliceAt(s)[0];
        const close_ch: u8 = switch (open_ch) {
            '(' => ')',
            '[' => ']',
            '{' => '}',
            else => return,
        };

        var e: u32 = end_pos;
        depth = 0;
        var found_close = false;
        while (e < self.buffer.total_len) {
            const slice = self.buffer.contiguousSliceAt(e);
            if (slice.len == 0) break;
            const ch = slice[0];
            if (ch == open_ch) {
                depth += 1;
            } else if (ch == close_ch) {
                if (depth == 0) {
                    e += 1; // include the closing bracket
                    found_close = true;
                    break;
                }
                depth -= 1;
            }
            e += 1;
        }

        if (found_close and (s < start or e > end_pos)) {
            self.cursor.cursors.items[0] = .{ .anchor = s, .head = e };
            self.ensureCursorVisible();
            self.markAllDirty();
        }
    }

    pub fn shrinkSelection(self: *EditorView) void {
        const sel = self.cursor.primary();
        if (sel.hasSelection()) {
            // Shrink: try to find inner brackets within current selection
            const start = sel.start();
            const end_pos = sel.end();

            // Look for the first opening bracket after start
            var inner_start: ?u32 = null;
            var s = start;
            while (s < end_pos) {
                const slice = self.buffer.contiguousSliceAt(s);
                if (slice.len == 0) break;
                const ch = slice[0];
                if (ch == '(' or ch == '[' or ch == '{') {
                    inner_start = s;
                    break;
                }
                s += 1;
            }

            if (inner_start) |is| {
                // Find matching close bracket
                const open_ch = self.buffer.contiguousSliceAt(is)[0];
                const close_ch: u8 = switch (open_ch) {
                    '(' => ')',
                    '[' => ']',
                    '{' => '}',
                    else => {
                        self.cursor.cursors.items[0] = .{ .anchor = sel.head, .head = sel.head };
                        self.markAllDirty();
                        return;
                    },
                };

                var e = is + 1;
                var depth: i32 = 0;
                while (e < end_pos) {
                    const slice = self.buffer.contiguousSliceAt(e);
                    if (slice.len == 0) break;
                    const ch = slice[0];
                    if (ch == open_ch) {
                        depth += 1;
                    } else if (ch == close_ch) {
                        if (depth == 0) {
                            // Found matching pair within selection
                            self.cursor.cursors.items[0] = .{ .anchor = is, .head = e + 1 };
                            self.ensureCursorVisible();
                            self.markAllDirty();
                            return;
                        }
                        depth -= 1;
                    }
                    e += 1;
                }
            }

            // No inner brackets: collapse to cursor position
            self.cursor.cursors.items[0] = .{ .anchor = sel.head, .head = sel.head };
            self.markAllDirty();
        }
    }

    // ── Sort selected lines ───────────────────────────────────────

    pub fn sortSelectedLines(self: *EditorView, descending: bool) !void {
        const sel = self.cursor.primary();
        const start_off = if (sel.hasSelection()) sel.start() else sel.head;
        const end_off = if (sel.hasSelection()) sel.end() else sel.head;
        const start_lc = self.buffer.offsetToLineCol(start_off);
        const end_raw = self.buffer.offsetToLineCol(if (end_off > 0) end_off -| 1 else 0);
        const end_lc_line = if (sel.hasSelection() and end_off > start_off) end_raw.line else start_lc.line;

        if (start_lc.line == end_lc_line) return; // Need at least 2 lines

        // Collect line contents
        const line_count = end_lc_line - start_lc.line + 1;
        var lines_list = try self.allocator.alloc([]const u8, line_count);
        defer self.allocator.free(lines_list);

        var line_copies = try self.allocator.alloc([]u8, line_count);
        defer {
            for (line_copies[0..line_count]) |lc| {
                self.allocator.free(lc);
            }
            self.allocator.free(line_copies);
        }

        var line: u32 = start_lc.line;
        var idx: usize = 0;
        while (line <= end_lc_line) : ({ line += 1; idx += 1; }) {
            const ls = self.buffer.lineToOffset(line);
            const le = if (line + 1 < self.buffer.lineCount()) self.buffer.lineToOffset(line + 1) else self.buffer.total_len;
            // Collect line content byte by byte from piece table
            const line_len = le - ls;
            const copy = try self.allocator.alloc(u8, line_len);
            var ci: u32 = 0;
            while (ci < line_len) {
                const slice = self.buffer.contiguousSliceAt(ls + ci);
                if (slice.len == 0) break;
                const to_copy = @min(slice.len, line_len - ci);
                @memcpy(copy[ci..][0..to_copy], slice[0..to_copy]);
                ci += to_copy;
            }
            line_copies[idx] = copy;
            lines_list[idx] = copy[0..line_len];
        }

        // Sort
        if (descending) {
            std.mem.sort([]const u8, lines_list, {}, struct {
                fn cmp(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .gt;
                }
            }.cmp);
        } else {
            std.mem.sort([]const u8, lines_list, {}, struct {
                fn cmp(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.cmp);
        }

        // Build sorted text
        var total_len: usize = 0;
        for (lines_list) |ln| total_len += ln.len;

        var sorted = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(sorted);
        var pos: usize = 0;
        for (lines_list) |ln| {
            @memcpy(sorted[pos..][0..ln.len], ln);
            pos += ln.len;
        }

        // Replace the range in buffer
        const range_start = self.buffer.lineToOffset(start_lc.line);
        const range_end = if (end_lc_line + 1 < self.buffer.lineCount())
            self.buffer.lineToOffset(end_lc_line + 1)
        else
            self.buffer.total_len;

        const del_len = range_end - range_start;
        try self.buffer.delete(range_start, del_len);
        try self.buffer.insert(range_start, sorted);

        self.modified = true;
        self.markAllDirty();
    }

    // ── Diagnostic navigation ────────────────────────────────────

    pub fn gotoNextDiagnostic(self: *EditorView) void {
        if (self.lsp_diagnostics.len == 0) return;
        const cursor_line = self.buffer.offsetToLineCol(self.cursor.primary().head).line;

        // Find first diagnostic after cursor line
        for (self.lsp_diagnostics) |d| {
            if (d.line > cursor_line) {
                const offset = self.buffer.lineToOffset(d.line) + d.col_start;
                self.cursor.moveTo(@min(offset, self.buffer.total_len));
                self.ensureCursorVisible();
                self.markAllDirty();
                return;
            }
        }
        // Wrap to first diagnostic
        const d = self.lsp_diagnostics[0];
        const offset = self.buffer.lineToOffset(d.line) + d.col_start;
        self.cursor.moveTo(@min(offset, self.buffer.total_len));
        self.ensureCursorVisible();
        self.markAllDirty();
    }

    pub fn gotoPrevDiagnostic(self: *EditorView) void {
        if (self.lsp_diagnostics.len == 0) return;
        const cursor_line = self.buffer.offsetToLineCol(self.cursor.primary().head).line;

        // Find last diagnostic before cursor line
        var i: usize = self.lsp_diagnostics.len;
        while (i > 0) {
            i -= 1;
            if (self.lsp_diagnostics[i].line < cursor_line) {
                const d = self.lsp_diagnostics[i];
                const offset = self.buffer.lineToOffset(d.line) + d.col_start;
                self.cursor.moveTo(@min(offset, self.buffer.total_len));
                self.ensureCursorVisible();
                self.markAllDirty();
                return;
            }
        }
        // Wrap to last diagnostic
        const d = self.lsp_diagnostics[self.lsp_diagnostics.len - 1];
        const offset = self.buffer.lineToOffset(d.line) + d.col_start;
        self.cursor.moveTo(@min(offset, self.buffer.total_len));
        self.ensureCursorVisible();
        self.markAllDirty();
    }

    // ── Text case transformation ─────────────────────────────────

    pub const CaseMode = enum { upper, lower, title };

    pub fn transformCase(self: *EditorView, mode: CaseMode) !void {
        const sel = self.cursor.primary();
        if (!sel.hasSelection()) return;

        const start = sel.start();
        const len = sel.end() - start;

        // Get selected text via contiguous slices
        var transformed = try self.allocator.alloc(u8, len);
        defer self.allocator.free(transformed);
        var written: usize = 0;
        var offset: u32 = start;
        while (offset < sel.end()) {
            const slice = self.buffer.contiguousSliceAt(offset);
            if (slice.len == 0) break;
            const remaining: usize = @intCast(sel.end() - offset);
            const take = @min(slice.len, remaining);
            @memcpy(transformed[written..][0..take], slice[0..take]);
            written += take;
            offset += @intCast(take);
        }
        const text = transformed[0..written];

        switch (mode) {
            .upper => {
                for (text) |*ch| {
                    if (ch.* >= 'a' and ch.* <= 'z') ch.* -= 32;
                }
            },
            .lower => {
                for (text) |*ch| {
                    if (ch.* >= 'A' and ch.* <= 'Z') ch.* += 32;
                }
            },
            .title => {
                var word_start = true;
                for (text) |*ch| {
                    if (ch.* >= 'a' and ch.* <= 'z' and word_start) {
                        ch.* -= 32;
                        word_start = false;
                    } else if (ch.* >= 'A' and ch.* <= 'Z' and !word_start) {
                        ch.* += 32;
                        word_start = false;
                    } else {
                        word_start = (ch.* == ' ' or ch.* == '\t' or ch.* == '\n' or ch.* == '_' or ch.* == '-');
                    }
                }
            },
        }

        // Replace selection with transformed text
        try self.buffer.delete(start, len);
        try self.buffer.insert(start, text);
        self.cursor.cursors.items[0] = .{ .anchor = start, .head = start + len };
        self.modified = true;
        self.markAllDirty();
    }
};

// ── Re-exports from view_render.zig ───────────────────────────────
const view_render_mod = @import("view_render.zig");
pub const tabBarHeight = view_render_mod.tabBarHeight;
pub const renderTabBar = view_render_mod.renderTabBar;
pub const tabAtPixel = view_render_mod.tabAtPixel;

pub fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// ── Shared helpers (used by both view.zig and view_render.zig) ────
const decodeUtf8 = view_render_mod.decodeUtf8;
const isWide = view_render_mod.isWide;
