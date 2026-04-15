const std = @import("std");
const render_mod = @import("render.zig");
const Renderer = render_mod.Renderer;
const Color = render_mod.Color;
const FontFace = @import("font.zig").FontFace;

// Catppuccin Mocha palette (matching view.zig)
const theme = struct {
    const base = Color.fromHex(0x1e1e2e);
    const mantle = Color.fromHex(0x181825);
    const crust = Color.fromHex(0x11111b);
    const surface0 = Color.fromHex(0x313244);
    const surface1 = Color.fromHex(0x45475a);
    const surface2 = Color.fromHex(0x585b70);
    const overlay0 = Color.fromHex(0x6c7086);
    const text = Color.fromHex(0xcdd6f4);
    const subtext0 = Color.fromHex(0xa6adc8);
    const lavender = Color.fromHex(0xb4befe);
    const green = Color.fromHex(0xa6e3a1);
    const rosewater = Color.fromHex(0xf5e0dc);
};

pub const FileTree = struct {
    entries: std.ArrayList(Entry),
    selected: usize,
    scroll_offset: usize,
    visible: bool,
    width: u32,
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    active_path: ?[]const u8, // Currently open file (for highlighting)
    hover_entry: ?usize = null, // Entry under mouse cursor (for hover highlight)
    inline_input: ?InlineInput = null,

    pub const Entry = struct {
        name: []u8,
        path: []u8,
        depth: u16,
        is_dir: bool,
        is_expanded: bool,
        has_children: bool,
    };

    pub const InlineInput = struct {
        buffer: [256]u8 = undefined,
        len: usize = 0,
        cursor_pos: usize = 0, // byte offset, always at codepoint boundary
        mode: enum { new_file, new_folder, rename_file } = .new_file,
        target_dir: []const u8 = "",
        insert_at: usize = 0,
        original_name: ?[]const u8 = null,

        pub fn setText(self: *InlineInput, text: []const u8) void {
            const n = @min(text.len, self.buffer.len);
            @memcpy(self.buffer[0..n], text[0..n]);
            self.len = n;
            self.cursor_pos = n;
        }

        pub fn insertChar(self: *InlineInput, codepoint: u21) void {
            var seq: [4]u8 = undefined;
            const seq_len = std.unicode.utf8Encode(codepoint, &seq) catch return;
            if (self.len + seq_len > self.buffer.len) return;
            // Shift bytes right from cursor_pos
            std.mem.copyBackwards(
                u8,
                self.buffer[self.cursor_pos + seq_len .. self.len + seq_len],
                self.buffer[self.cursor_pos .. self.len],
            );
            @memcpy(self.buffer[self.cursor_pos .. self.cursor_pos + seq_len], seq[0..seq_len]);
            self.len += seq_len;
            self.cursor_pos += seq_len;
        }

        pub fn backspace(self: *InlineInput) void {
            if (self.cursor_pos == 0) return;
            // Walk backwards over continuation bytes
            var pos = self.cursor_pos - 1;
            while (pos > 0 and (self.buffer[pos] & 0xC0) == 0x80) {
                pos -= 1;
            }
            const seq_len = self.cursor_pos - pos;
            std.mem.copyForwards(
                u8,
                self.buffer[pos .. self.len - seq_len],
                self.buffer[self.cursor_pos .. self.len],
            );
            self.len -= seq_len;
            self.cursor_pos = pos;
        }

        pub fn delete(self: *InlineInput) void {
            if (self.cursor_pos >= self.len) return;
            const seq_len = std.unicode.utf8ByteSequenceLength(self.buffer[self.cursor_pos]) catch 1;
            const actual_len = @min(seq_len, self.len - self.cursor_pos);
            std.mem.copyForwards(
                u8,
                self.buffer[self.cursor_pos .. self.len - actual_len],
                self.buffer[self.cursor_pos + actual_len .. self.len],
            );
            self.len -= actual_len;
        }

        pub fn moveLeft(self: *InlineInput) void {
            if (self.cursor_pos == 0) return;
            var pos = self.cursor_pos - 1;
            while (pos > 0 and (self.buffer[pos] & 0xC0) == 0x80) {
                pos -= 1;
            }
            self.cursor_pos = pos;
        }

        pub fn moveRight(self: *InlineInput) void {
            if (self.cursor_pos >= self.len) return;
            const seq_len = std.unicode.utf8ByteSequenceLength(self.buffer[self.cursor_pos]) catch 1;
            self.cursor_pos += @min(seq_len, self.len - self.cursor_pos);
        }

        pub fn content(self: *const InlineInput) []const u8 {
            return self.buffer[0..self.len];
        }

        /// Returns null if valid, or an error message string if invalid.
        pub fn validate(self: *const InlineInput) ?[]const u8 {
            if (self.len == 0) return "Name cannot be empty";
            const text = self.buffer[0..self.len];
            for (text) |byte| {
                if (byte == '/') return "Name cannot contain '/'";
                if (byte == 0) return "Name cannot contain null bytes";
            }
            return null;
        }
    };

    const skip_dirs = [_][]const u8{
        ".git",
        "node_modules",
        "zig-cache",
        ".zig-cache",
        "zig-out",
        "__pycache__",
        "target",
        ".cache",
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) FileTree {
        return .{
            .entries = .empty,
            .selected = 0,
            .scroll_offset = 0,
            .visible = false,
            .width = 220,
            .allocator = allocator,
            .io = io,
            .root_path = root_path,
            .active_path = null,
        };
    }

    pub fn deinit(self: *FileTree) void {
        self.freeEntries();
        self.entries.deinit(self.allocator);
    }

    fn freeEntries(self: *FileTree) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.path);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn toggle(self: *FileTree) void {
        self.visible = !self.visible;
        if (self.visible and self.entries.items.len == 0) {
            self.populate() catch {};
        }
    }

    pub fn sidebarWidth(self: *const FileTree, font: *const FontFace) u32 {
        if (!self.visible) return 0;
        const min_w = 25 * font.cell_width;
        return @max(self.width, min_w);
    }

    pub fn populate(self: *FileTree) !void {
        self.freeEntries();
        try self.scanDir(self.root_path, 0);
    }

    fn scanDir(self: *FileTree, dir_path: []const u8, depth: u16) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        // Collect entries first for sorting
        const DirItem = struct {
            name: []u8,
            is_dir: bool,
        };
        var items: std.ArrayList(DirItem) = .empty;
        defer {
            for (items.items) |item| self.allocator.free(item.name);
            items.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            // Skip hidden files/dirs
            if (entry.name[0] == '.') continue;

            // Skip known build/cache dirs
            if (self.shouldSkip(entry.name)) continue;

            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);

            try items.append(self.allocator, .{
                .name = name,
                .is_dir = entry.kind == .directory,
            });
        }

        // Sort: directories first, then alphabetical
        std.mem.sort(DirItem, items.items, {}, struct {
            fn lessThan(_: void, a: DirItem, b: DirItem) bool {
                if (a.is_dir and !b.is_dir) return true;
                if (!a.is_dir and b.is_dir) return false;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);

        // Add sorted entries
        for (items.items) |item| {
            const rel_path = if (std.mem.eql(u8, dir_path, "."))
                try self.allocator.dupe(u8, item.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, item.name });
            errdefer self.allocator.free(rel_path);

            const entry_name = try self.allocator.dupe(u8, item.name);
            errdefer self.allocator.free(entry_name);

            var has_children = false;
            if (item.is_dir) {
                // Quick check if directory has children
                var sub = std.Io.Dir.cwd().openDir(self.io, rel_path, .{ .iterate = true }) catch {
                    has_children = false;
                    try self.entries.append(self.allocator, .{
                        .name = entry_name,
                        .path = rel_path,
                        .depth = depth,
                        .is_dir = true,
                        .is_expanded = false,
                        .has_children = false,
                    });
                    continue;
                };
                defer sub.close(self.io);
                var sub_iter = sub.iterate();
                if (try sub_iter.next(self.io)) |_| {
                    has_children = true;
                }
            }

            try self.entries.append(self.allocator, .{
                .name = entry_name,
                .path = rel_path,
                .depth = depth,
                .is_dir = item.is_dir,
                .is_expanded = false,
                .has_children = has_children,
            });
        }
    }

    fn shouldSkip(self: *const FileTree, name: []const u8) bool {
        _ = self;
        for (&skip_dirs) |skip| {
            if (std.mem.eql(u8, name, skip)) return true;
        }
        return false;
    }

    pub fn toggleExpand(self: *FileTree) void {
        if (self.selected >= self.entries.items.len) return;
        const entry = &self.entries.items[self.selected];
        if (!entry.is_dir) return;

        self.hover_entry = null; // Invalidate hover on tree mutation

        if (entry.is_expanded) {
            // Collapse: remove all children
            self.collapseAt(self.selected);
        } else {
            // Expand: insert children after this entry
            self.expandAt(self.selected) catch {};
        }
    }

    fn expandAt(self: *FileTree, idx: usize) !void {
        var entry = &self.entries.items[idx];
        entry.is_expanded = true;

        const parent_path = entry.path;
        const child_depth = entry.depth + 1;

        // Scan directory
        var dir = std.Io.Dir.cwd().openDir(self.io, parent_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        const DirItem = struct {
            name: []u8,
            is_dir: bool,
        };
        var items: std.ArrayList(DirItem) = .empty;
        defer {
            for (items.items) |item| self.allocator.free(item.name);
            items.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next(self.io)) |e| {
            if (e.name[0] == '.') continue;
            if (self.shouldSkip(e.name)) continue;

            const name = try self.allocator.dupe(u8, e.name);
            errdefer self.allocator.free(name);
            try items.append(self.allocator, .{
                .name = name,
                .is_dir = e.kind == .directory,
            });
        }

        std.mem.sort(DirItem, items.items, {}, struct {
            fn lessThan(_: void, a: DirItem, b: DirItem) bool {
                if (a.is_dir and !b.is_dir) return true;
                if (!a.is_dir and b.is_dir) return false;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);

        // Insert children after idx (in reverse to maintain order)
        var insert_pos = idx + 1;
        for (items.items) |item| {
            const rel_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent_path, item.name });
            errdefer self.allocator.free(rel_path);

            const entry_name = try self.allocator.dupe(u8, item.name);
            errdefer self.allocator.free(entry_name);

            var has_children = false;
            if (item.is_dir) {
                var sub = std.Io.Dir.cwd().openDir(self.io, rel_path, .{ .iterate = true }) catch {
                    try self.entries.insert(self.allocator, insert_pos, .{
                        .name = entry_name,
                        .path = rel_path,
                        .depth = child_depth,
                        .is_dir = true,
                        .is_expanded = false,
                        .has_children = false,
                    });
                    insert_pos += 1;
                    continue;
                };
                defer sub.close(self.io);
                var sub_iter = sub.iterate();
                if (try sub_iter.next(self.io)) |_| {
                    has_children = true;
                }
            }

            try self.entries.insert(self.allocator, insert_pos, .{
                .name = entry_name,
                .path = rel_path,
                .depth = child_depth,
                .is_dir = item.is_dir,
                .is_expanded = false,
                .has_children = has_children,
            });
            insert_pos += 1;
        }
    }

    fn collapseAt(self: *FileTree, idx: usize) void {
        const parent_depth = self.entries.items[idx].depth;
        self.entries.items[idx].is_expanded = false;

        // Remove all entries after idx whose depth > parent_depth
        var remove_count: usize = 0;
        var i = idx + 1;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].depth <= parent_depth) break;
            // Free the entry's allocations
            self.allocator.free(self.entries.items[i].name);
            self.allocator.free(self.entries.items[i].path);
            remove_count += 1;
            i += 1;
        }

        // Shift remaining entries down
        if (remove_count > 0) {
            const start = idx + 1;
            const remaining = self.entries.items.len - start - remove_count;
            if (remaining > 0) {
                std.mem.copyForwards(Entry, self.entries.items[start .. start + remaining], self.entries.items[start + remove_count .. start + remove_count + remaining]);
            }
            self.entries.items.len -= remove_count;
        }

        // Adjust selected if it was in the collapsed range
        if (self.selected > idx and self.selected < idx + 1 + remove_count) {
            self.selected = idx;
        } else if (self.selected >= idx + 1 + remove_count) {
            self.selected -= remove_count;
        }
    }

    pub fn render(self: *FileTree, renderer: *Renderer, font: *FontFace, tab_bar_h: u32) void {
        if (!self.visible) return;

        const cell_w = font.cell_width;
        const cell_h = font.cell_height;
        if (cell_w == 0 or cell_h == 0) return;

        const sw = self.sidebarWidth(font);
        const area_h = if (renderer.height > tab_bar_h) renderer.height - tab_bar_h else 0;

        // Background — mantle (slightly lighter than crust, closer to editor bg)
        renderer.fillRect(0, tab_bar_h, sw, area_h, theme.mantle);

        // Right border separator (1px surface2)
        renderer.fillRect(sw - 1, tab_bar_h, 1, area_h, theme.surface2);

        // Top padding below tab bar (4px gap)
        const top_pad: u32 = 4;
        const content_y = tab_bar_h + top_pad;
        const content_h = if (area_h > top_pad) area_h - top_pad else 0;

        // Visible rows
        const max_rows = if (cell_h > 0) content_h / cell_h else 0;
        if (max_rows == 0) return;

        // Adjust scroll if selected is out of view
        if (self.selected < self.scroll_offset) {
            self.scroll_offset = self.selected;
        }
        if (self.selected >= self.scroll_offset + max_rows) {
            self.scroll_offset = self.selected - max_rows + 1;
        }

        var row: usize = 0;
        var entry_idx = self.scroll_offset;
        while (row < max_rows and entry_idx < self.entries.items.len) : ({
            row += 1;
            entry_idx += 1;
        }) {
            const entry = self.entries.items[entry_idx];
            const row_y = content_y + @as(u32, @intCast(row)) * cell_h;

            // Selected or hover highlight
            const is_selected = (entry_idx == self.selected);
            const is_hovered = if (self.hover_entry) |h| h == entry_idx else false;
            if (is_selected) {
                renderer.fillRect(0, row_y, sw - 1, cell_h, theme.surface1);
            } else if (is_hovered) {
                renderer.fillRect(0, row_y, sw - 1, cell_h, theme.surface0);
            }

            // Indentation — 16px per depth level
            const indent_px: u32 = 16;
            const indent: u32 = @as(u32, entry.depth) * indent_px;
            var text_x: u32 = 8 + indent; // 8px left margin

            // Directory icon (▸/▾)
            if (entry.is_dir) {
                const icon_cp: u32 = if (entry.is_expanded) 0x25be else 0x25b8; // "▾" or "▸"
                if (font.getGlyph(icon_cp)) |glyph| {
                    const gx = @as(i32, @intCast(text_x)) + glyph.bearing_x;
                    const gy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                    renderer.drawGlyph(glyph, gx, gy, theme.overlay0);
                } else |_| {
                    // Fallback to ASCII '>' / 'v'
                    const icon: u8 = if (entry.is_expanded) 'v' else '>';
                    if (font.getGlyph(icon)) |glyph| {
                        const gx = @as(i32, @intCast(text_x)) + glyph.bearing_x;
                        const gy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                        renderer.drawGlyph(glyph, gx, gy, theme.overlay0);
                    } else |_| {}
                }
                text_x += cell_w + 2; // icon + small gap
            } else {
                // File: indent to align with directory text (past icon column)
                text_x += cell_w + 2;
            }

            // Determine text color
            const fg = if (entry.is_dir)
                theme.lavender // directories in lavender
            else if (self.isActivePath(entry.path))
                theme.lavender // active file in lavender (not green)
            else
                theme.text;

            // Draw entry name
            const max_chars = if (sw > text_x + cell_w) (sw - text_x - cell_w) / cell_w else 0;
            var chars_drawn: u32 = 0;
            for (entry.name) |ch| {
                if (chars_drawn >= max_chars) break;
                if (font.getGlyph(ch)) |glyph| {
                    const gx = @as(i32, @intCast(text_x)) + glyph.bearing_x;
                    const gy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                    renderer.drawGlyph(glyph, gx, gy, fg);
                } else |_| {}
                text_x += cell_w;
                chars_drawn += 1;
            }
        }
    }

    fn isActivePath(self: *const FileTree, entry_path: []const u8) bool {
        const active = self.active_path orelse return false;
        return std.mem.eql(u8, entry_path, active);
    }

    /// Handle a mouse click. Returns the file path to open, or null.
    pub fn handleClick(self: *FileTree, px: i32, py: i32, font: *const FontFace, tab_bar_h: u32) ?[]const u8 {
        if (!self.visible) return null;

        const cell_h = font.cell_height;
        if (cell_h == 0) return null;

        // Must be below tab bar + top padding
        const top_pad: u32 = 4;
        const content_start = tab_bar_h + top_pad;
        if (py < @as(i32, @intCast(content_start))) return null;

        const sw = self.sidebarWidth(font);
        if (px < 0 or px >= @as(i32, @intCast(sw))) return null;

        const adj_y = @as(u32, @intCast(py)) - content_start;
        const row = adj_y / cell_h;
        const entry_idx = self.scroll_offset + row;

        if (entry_idx >= self.entries.items.len) return null;

        self.selected = entry_idx;

        const entry = &self.entries.items[entry_idx];
        if (entry.is_dir) {
            if (entry.is_expanded) {
                self.collapseAt(entry_idx);
            } else {
                self.expandAt(entry_idx) catch {};
            }
            return null;
        }

        // Return the file path
        return entry.path;
    }

    /// Update hover entry based on mouse position. Returns true if hover changed.
    pub fn handleMouseMotion(self: *FileTree, px: i32, py: i32, font: *const FontFace, tab_bar_h: u32) bool {
        if (!self.visible) {
            if (self.hover_entry != null) {
                self.hover_entry = null;
                return true;
            }
            return false;
        }

        const cell_h = font.cell_height;
        if (cell_h == 0) return false;

        const top_pad: u32 = 4;
        const content_start = tab_bar_h + top_pad;
        const sw = self.sidebarWidth(font);

        const old_hover = self.hover_entry;

        if (px < 0 or px >= @as(i32, @intCast(sw)) or py < @as(i32, @intCast(content_start))) {
            self.hover_entry = null;
        } else {
            const adj_y = @as(u32, @intCast(py)) - content_start;
            const row = adj_y / cell_h;
            const entry_idx = self.scroll_offset + row;
            if (entry_idx < self.entries.items.len) {
                self.hover_entry = entry_idx;
            } else {
                self.hover_entry = null;
            }
        }

        return self.hover_entry != old_hover;
    }

    /// Handle scroll wheel in sidebar area.
    pub fn handleScroll(self: *FileTree, delta: i32) void {
        self.hover_entry = null; // Invalidate hover on scroll
        const lines: i32 = delta * 3;
        if (lines < 0) {
            const up: usize = @intCast(-lines);
            self.scroll_offset = self.scroll_offset -| up;
        } else {
            self.scroll_offset = @min(
                self.scroll_offset + @as(usize, @intCast(lines)),
                if (self.entries.items.len > 0) self.entries.items.len - 1 else 0,
            );
        }
    }

    pub fn moveUp(self: *FileTree) void {
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *FileTree) void {
        if (self.selected + 1 < self.entries.items.len) self.selected += 1;
    }

    pub fn selectedPath(self: *const FileTree) ?[]const u8 {
        if (self.selected >= self.entries.items.len) return null;
        const entry = self.entries.items[self.selected];
        if (entry.is_dir) return null;
        return entry.path;
    }

    pub fn renderInlineInput(self: *FileTree, renderer: *Renderer, font: *FontFace, tab_bar_h: u32) void {
        const input = self.inline_input orelse return;
        if (!self.visible) return;

        const cell_w = font.cell_width;
        const cell_h = font.cell_height;
        if (cell_w == 0 or cell_h == 0) return;

        const sw = self.sidebarWidth(font);
        const top_pad: u32 = 4;
        const content_y = tab_bar_h + top_pad;

        // Row position for the inline input
        const row = if (input.insert_at >= self.scroll_offset)
            input.insert_at - self.scroll_offset
        else
            return;

        const max_rows = blk: {
            const area_h = if (renderer.height > tab_bar_h) renderer.height - tab_bar_h else 0;
            const content_h = if (area_h > top_pad) area_h - top_pad else 0;
            break :blk if (cell_h > 0) content_h / cell_h else 0;
        };
        if (row >= max_rows) return;

        const row_y = content_y + @as(u32, @intCast(row)) * cell_h;

        // Compute indent based on depth at insert_at (child of that entry)
        const indent_px: u32 = 16;
        const depth: u32 = blk: {
            if (input.insert_at < self.entries.items.len) {
                // Insert is inside a directory — child depth = parent depth + 1
                break :blk @as(u32, self.entries.items[input.insert_at].depth) + 1;
            }
            break :blk 0;
        };
        const indent: u32 = depth * indent_px;
        const text_x: u32 = 8 + indent + cell_w + 2; // match file text start

        // Background highlight
        renderer.fillRect(0, row_y, sw - 1, cell_h, theme.surface1);

        // Draw text content
        const text = input.content();
        var draw_x: u32 = text_x;
        var byte_offset: usize = 0;
        var cursor_x: u32 = text_x; // default cursor at start

        // Draw characters, tracking byte offset to find cursor x
        var i: usize = 0;
        while (i < text.len) {
            // Update cursor_x if we've reached cursor_pos in bytes
            if (byte_offset == input.cursor_pos) {
                cursor_x = draw_x;
            }
            const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const actual_seq_len = @min(seq_len, text.len - i);
            const codepoint: u21 = std.unicode.utf8Decode(text[i .. i + actual_seq_len]) catch @as(u21, text[i]);
            if (font.getGlyph(codepoint)) |glyph| {
                const gx = @as(i32, @intCast(draw_x)) + glyph.bearing_x;
                const gy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                renderer.drawGlyph(glyph, gx, gy, theme.text);
            } else |_| {}
            draw_x += cell_w;
            byte_offset += actual_seq_len;
            i += actual_seq_len;
        }
        // If cursor is at end of text
        if (byte_offset == input.cursor_pos) {
            cursor_x = draw_x;
        }

        // Draw 2px beam cursor in rosewater
        const cursor_draw_y = row_y;
        renderer.fillRect(cursor_x, cursor_draw_y, 2, cell_h, theme.rosewater);
    }

    pub fn refreshDirectory(self: *FileTree, dir_path: []const u8) !void {
        // Find the directory entry by path
        var found_idx: ?usize = null;
        for (self.entries.items, 0..) |entry, idx| {
            if (entry.is_dir and std.mem.eql(u8, entry.path, dir_path)) {
                found_idx = idx;
                break;
            }
        }

        const idx = found_idx orelse {
            // Fallback: full repopulate
            return self.populate();
        };

        // Record expanded subdirectory paths before collapsing
        var expanded_paths: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (expanded_paths.items) |p| self.allocator.free(p);
            expanded_paths.deinit(self.allocator);
        }

        const parent_depth = self.entries.items[idx].depth;
        var scan_i = idx + 1;
        while (scan_i < self.entries.items.len) {
            const e = self.entries.items[scan_i];
            if (e.depth <= parent_depth) break;
            if (e.is_dir and e.is_expanded) {
                const duped = try self.allocator.dupe(u8, e.path);
                try expanded_paths.append(self.allocator, duped);
            }
            scan_i += 1;
        }

        // Collapse then expand
        self.collapseAt(idx);
        try self.expandAt(idx);

        // Re-expand previously expanded subdirectories
        for (expanded_paths.items) |ep| {
            for (self.entries.items, 0..) |entry, ei| {
                if (entry.is_dir and !entry.is_expanded and std.mem.eql(u8, entry.path, ep)) {
                    try self.expandAt(ei);
                    break;
                }
            }
        }
    }

    pub fn createNewFile(self: *FileTree, dir_path: []const u8, name: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name });
        defer self.allocator.free(full_path);

        const file = try std.Io.Dir.cwd().createFile(self.io, full_path, .{ .exclusive = true });
        file.close(self.io);

        try self.refreshDirectory(dir_path);
    }

    pub fn createNewFolder(self: *FileTree, dir_path: []const u8, name: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name });
        defer self.allocator.free(full_path);

        try std.Io.Dir.cwd().createDirPath(self.io, full_path);
        try self.refreshDirectory(dir_path);
    }

    pub fn renameEntry(self: *FileTree, old_path: []const u8, new_name: []const u8) !void {
        // Determine parent directory
        const parent = std.fs.path.dirname(old_path) orelse ".";
        const new_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent, new_name });
        defer self.allocator.free(new_path);

        const cwd = std.Io.Dir.cwd();
        try cwd.rename(old_path, cwd, new_path, self.io);
        try self.refreshDirectory(parent);
    }

    pub fn deleteEntry(self: *FileTree, path: []const u8, is_dir: bool) !void {
        if (is_dir) {
            try std.Io.Dir.cwd().deleteTree(self.io, path);
        } else {
            try std.Io.Dir.cwd().deleteFile(self.io, path);
        }
        const parent = std.fs.path.dirname(path) orelse ".";
        try self.refreshDirectory(parent);
    }
};
