const std = @import("std");
const EditorView = @import("view.zig").EditorView;

pub const Direction = enum { horizontal, vertical };

pub const Pane = union(enum) {
    leaf: *EditorView,
    split: Split,

    pub const Split = struct {
        direction: Direction,
        ratio: f32, // 0.0 - 1.0
        first: *Pane,
        second: *Pane,
    };
};

pub const PaneManager = struct {
    root: *Pane,
    active_leaf: *EditorView,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, view: *EditorView) !PaneManager {
        const root = try allocator.create(Pane);
        root.* = .{ .leaf = view };
        return .{
            .root = root,
            .active_leaf = view,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PaneManager) void {
        self.freePane(self.root);
    }

    fn freePane(self: *PaneManager, pane: *Pane) void {
        switch (pane.*) {
            .leaf => {}, // EditorView owned by TabManager
            .split => |s| {
                self.freePane(s.first);
                self.freePane(s.second);
            },
        }
        self.allocator.destroy(pane);
    }

    /// Split the active pane in the given direction.
    pub fn splitActive(self: *PaneManager, direction: Direction, new_view: *EditorView) !void {
        try self.splitPaneContaining(self.root, self.active_leaf, direction, new_view);
        self.active_leaf = new_view;
    }

    fn splitPaneContaining(
        self: *PaneManager,
        pane: *Pane,
        target: *EditorView,
        direction: Direction,
        new_view: *EditorView,
    ) !void {
        switch (pane.*) {
            .leaf => |view| {
                if (view == target) {
                    const first = try self.allocator.create(Pane);
                    first.* = .{ .leaf = view };
                    const second = try self.allocator.create(Pane);
                    second.* = .{ .leaf = new_view };
                    pane.* = .{ .split = .{
                        .direction = direction,
                        .ratio = 0.5,
                        .first = first,
                        .second = second,
                    } };
                }
            },
            .split => |s| {
                try self.splitPaneContaining(s.first, target, direction, new_view);
                try self.splitPaneContaining(s.second, target, direction, new_view);
            },
        }
    }

    /// Apply layout: walk the tree and set x_offset/render_width/y_offset on each leaf.
    pub fn applyLayout(self: *PaneManager, x: u32, y: u32, w: u32, h: u32) void {
        self.applyLayoutPane(self.root, x, y, w, h);
    }

    fn applyLayoutPane(self: *PaneManager, pane: *Pane, x: u32, y: u32, w: u32, h: u32) void {
        switch (pane.*) {
            .leaf => |view| {
                view.x_offset = x;
                view.y_offset = y;
                view.render_width = w;
            },
            .split => |s| {
                if (s.direction == .vertical) {
                    const first_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * s.ratio));
                    const sep: u32 = 1;
                    const second_w = if (w > first_w + sep) w - first_w - sep else 0;
                    self.applyLayoutPane(s.first, x, y, first_w, h);
                    self.applyLayoutPane(s.second, x + first_w + sep, y, second_w, h);
                } else {
                    const first_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(h)) * s.ratio));
                    const sep: u32 = 1;
                    const second_h = if (h > first_h + sep) h - first_h - sep else 0;
                    self.applyLayoutPane(s.first, x, y, w, first_h);
                    self.applyLayoutPane(s.second, x, y + first_h + sep, w, second_h);
                }
            },
        }
    }

    /// Render separators between split panes.
    pub fn renderSeparators(self: *PaneManager, buffer: []u8, stride: u32, buf_w: u32, buf_h: u32, x: u32, y: u32, w: u32, h: u32) void {
        self.renderSepPane(self.root, buffer, stride, buf_w, buf_h, x, y, w, h);
    }

    fn renderSepPane(self: *PaneManager, pane: *Pane, buffer: []u8, stride: u32, buf_w: u32, buf_h: u32, x: u32, y: u32, w: u32, h: u32) void {
        switch (pane.*) {
            .leaf => {},
            .split => |s| {
                if (s.direction == .vertical) {
                    const first_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * s.ratio));
                    const sep_x = x + first_w;
                    const sep: u32 = 1;
                    const second_w = if (w > first_w + sep) w - first_w - sep else 0;
                    // Draw vertical separator
                    fillRectRaw(buffer, stride, buf_w, buf_h, sep_x, y, 1, h, 0x585b70);
                    self.renderSepPane(s.first, buffer, stride, buf_w, buf_h, x, y, first_w, h);
                    self.renderSepPane(s.second, buffer, stride, buf_w, buf_h, x + first_w + sep, y, second_w, h);
                } else {
                    const first_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(h)) * s.ratio));
                    const sep: u32 = 1;
                    const second_h = if (h > first_h + sep) h - first_h - sep else 0;
                    fillRectRaw(buffer, stride, buf_w, buf_h, x, y + first_h, w, 1, 0x585b70);
                    self.renderSepPane(s.first, buffer, stride, buf_w, buf_h, x, y, w, first_h);
                    self.renderSepPane(s.second, buffer, stride, buf_w, buf_h, x, y + first_h + sep, w, second_h);
                }
            },
        }
    }

    /// Unsplit: remove the active pane, collapse its parent to the sibling.
    pub fn unsplitActive(self: *PaneManager) void {
        if (self.root.* == .leaf) return;
        const remaining = self.findFirstLeafExcluding(self.root, self.active_leaf);
        if (remaining) |view| {
            self.freePane(self.root);
            self.root = self.allocator.create(Pane) catch return;
            self.root.* = .{ .leaf = view };
            self.active_leaf = view;
        }
    }

    fn findFirstLeafExcluding(self: *PaneManager, pane: *Pane, exclude: *EditorView) ?*EditorView {
        switch (pane.*) {
            .leaf => |view| return if (view != exclude) view else null,
            .split => |s| {
                return self.findFirstLeafExcluding(s.first, exclude) orelse
                    self.findFirstLeafExcluding(s.second, exclude);
            },
        }
    }

    /// Cycle focus to the next leaf pane.
    pub fn focusNext(self: *PaneManager) void {
        // Collect all leaves in order
        var leaves: [16]*EditorView = undefined;
        var count: usize = 0;
        self.collectLeaves(self.root, &leaves, &count);
        if (count <= 1) return;

        // Find current active
        for (0..count) |i| {
            if (leaves[i] == self.active_leaf) {
                self.active_leaf = leaves[(i + 1) % count];
                return;
            }
        }
    }

    fn collectLeaves(self: *PaneManager, pane: *Pane, out: *[16]*EditorView, count: *usize) void {
        switch (pane.*) {
            .leaf => |view| {
                if (count.* < 16) {
                    out[count.*] = view;
                    count.* += 1;
                }
            },
            .split => |s| {
                self.collectLeaves(s.first, out, count);
                self.collectLeaves(s.second, out, count);
            },
        }
    }

    /// Find which leaf pane contains the given pixel coordinate.
    pub fn leafAtPixel(self: *PaneManager, px: i32, py: i32) ?*EditorView {
        return self.leafAtPixelPane(self.root, px, py);
    }

    fn leafAtPixelPane(self: *PaneManager, pane: *Pane, px: i32, py: i32) ?*EditorView {
        switch (pane.*) {
            .leaf => |view| {
                const vx = @as(i32, @intCast(view.x_offset));
                const vy = @as(i32, @intCast(view.y_offset));
                const vw = @as(i32, @intCast(view.render_width));
                // Only check x bounds -- y is handled by the pane's own viewport
                if (px >= vx and px < vx + vw and py >= vy) {
                    return view;
                }
                return null;
            },
            .split => |s| {
                return self.leafAtPixelPane(s.first, px, py) orelse
                    self.leafAtPixelPane(s.second, px, py);
            },
        }
    }

    pub fn isSplit(self: *const PaneManager) bool {
        return self.root.* == .split;
    }

    /// Collect all unique EditorView pointers from all leaves.
    pub fn allLeaves(self: *PaneManager, out: *[16]*EditorView) usize {
        var count: usize = 0;
        self.collectLeaves(self.root, out, &count);
        return count;
    }
};

/// Raw fillRect on a pixel buffer -- avoids needing a Renderer instance.
fn fillRectRaw(buffer: []u8, stride: u32, buf_w: u32, buf_h: u32, x: u32, y: u32, w: u32, h: u32, hex: u24) void {
    const pixel: u32 = @as(u32, @as(u8, @intCast(hex & 0xFF))) |
        (@as(u32, @as(u8, @intCast((hex >> 8) & 0xFF))) << 8) |
        (@as(u32, @as(u8, @intCast((hex >> 16) & 0xFF))) << 16) |
        (0xFF << 24);
    const pixel_bytes: [4]u8 = @bitCast(pixel);

    var row = y;
    while (row < y + h and row < buf_h) : (row += 1) {
        var col = x;
        while (col < x + w and col < buf_w) : (col += 1) {
            const offset = row * stride + col * 4;
            if (offset + 4 <= buffer.len) {
                buffer[offset..][0..4].* = pixel_bytes;
            }
        }
    }
}
