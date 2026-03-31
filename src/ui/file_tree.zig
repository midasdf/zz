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
};

pub const FileTree = struct {
    entries: std.ArrayList(Entry),
    selected: usize,
    scroll_offset: usize,
    visible: bool,
    width: u32,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    active_path: ?[]const u8, // Currently open file (for highlighting)

    pub const Entry = struct {
        name: []u8,
        path: []u8,
        depth: u16,
        is_dir: bool,
        is_expanded: bool,
        has_children: bool,
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

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) FileTree {
        return .{
            .entries = .{},
            .selected = 0,
            .scroll_offset = 0,
            .visible = false,
            .width = 220,
            .allocator = allocator,
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
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        // Collect entries first for sorting
        const DirItem = struct {
            name: []u8,
            is_dir: bool,
        };
        var items: std.ArrayList(DirItem) = .{};
        defer {
            for (items.items) |item| self.allocator.free(item.name);
            items.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
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
                var sub = std.fs.cwd().openDir(rel_path, .{ .iterate = true }) catch {
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
                defer sub.close();
                var sub_iter = sub.iterate();
                if (try sub_iter.next()) |_| {
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
        var dir = std.fs.cwd().openDir(parent_path, .{ .iterate = true }) catch return;
        defer dir.close();

        const DirItem = struct {
            name: []u8,
            is_dir: bool,
        };
        var items: std.ArrayList(DirItem) = .{};
        defer {
            for (items.items) |item| self.allocator.free(item.name);
            items.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next()) |e| {
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
                var sub = std.fs.cwd().openDir(rel_path, .{ .iterate = true }) catch {
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
                defer sub.close();
                var sub_iter = sub.iterate();
                if (try sub_iter.next()) |_| {
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

        // Background
        renderer.fillRect(0, tab_bar_h, sw, area_h, theme.crust);

        // Right separator
        renderer.fillRect(sw - 1, tab_bar_h, 1, area_h, theme.surface2);

        // Visible rows
        const max_rows = if (cell_h > 0) area_h / cell_h else 0;
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
            const row_y = tab_bar_h + @as(u32, @intCast(row)) * cell_h;

            // Selected highlight
            const is_selected = (entry_idx == self.selected);
            if (is_selected) {
                renderer.fillRect(0, row_y, sw - 1, cell_h, theme.surface0);
            }

            // Indentation
            const indent: u32 = @as(u32, entry.depth) * 2 * cell_w;
            var text_x: u32 = 4 + indent; // 4px left margin

            // Directory icon
            if (entry.is_dir) {
                const icon: u8 = if (entry.is_expanded) 0x76 else 0x3e; // 'v' or '>'
                // Use triangle characters
                const icon_cp: u32 = if (entry.is_expanded) 0x25be else 0x25b8; // "▾" or "▸"
                if (font.getGlyph(icon_cp)) |glyph| {
                    const gx = @as(i32, @intCast(text_x)) + glyph.bearing_x;
                    const gy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                    renderer.drawGlyph(glyph, gx, gy, theme.overlay0);
                } else |_| {
                    // Fallback to ASCII
                    if (font.getGlyph(icon)) |glyph| {
                        const gx = @as(i32, @intCast(text_x)) + glyph.bearing_x;
                        const gy = @as(i32, @intCast(row_y)) + font.ascent - glyph.bearing_y;
                        renderer.drawGlyph(glyph, gx, gy, theme.overlay0);
                    } else |_| {}
                }
                text_x += cell_w;
            } else {
                // File: add space to align with dir names
                text_x += cell_w;
            }

            // Determine text color
            const fg = if (entry.is_dir)
                theme.lavender
            else if (self.isActivePath(entry.path))
                theme.green
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

        // Must be below tab bar
        if (py < @as(i32, @intCast(tab_bar_h))) return null;

        const sw = self.sidebarWidth(font);
        if (px < 0 or px >= @as(i32, @intCast(sw))) return null;

        const adj_y = @as(u32, @intCast(py)) - tab_bar_h;
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

    /// Handle scroll wheel in sidebar area.
    pub fn handleScroll(self: *FileTree, delta: i32) void {
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
};
