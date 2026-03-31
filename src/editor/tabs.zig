const std = @import("std");
const EditorView = @import("view.zig").EditorView;
const PieceTable = @import("buffer.zig").PieceTable;

pub const TabManager = struct {
    tabs: std.ArrayList(*EditorView),
    active: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TabManager {
        return .{
            .tabs = .{},
            .active = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TabManager) void {
        for (self.tabs.items) |tab| {
            tab.deinit();
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);
    }

    /// Create a new tab with the given content and optional file path.
    /// Returns the newly created EditorView.
    pub fn addTab(self: *TabManager, content: []const u8, file_path: ?[]const u8) !*EditorView {
        const view = try self.allocator.create(EditorView);
        errdefer self.allocator.destroy(view);
        view.* = try EditorView.init(self.allocator, content);
        errdefer view.deinit();
        if (file_path) |p| {
            view.file_path = try self.allocator.dupe(u8, p);
        }
        try self.tabs.append(self.allocator, view);
        self.active = self.tabs.items.len - 1;
        return view;
    }

    /// Close a tab by index. Won't close the last remaining tab.
    pub fn closeTab(self: *TabManager, idx: usize) void {
        if (self.tabs.items.len <= 1) return;
        const tab = self.tabs.orderedRemove(idx);
        tab.deinit();
        self.allocator.destroy(tab);
        if (self.active >= self.tabs.items.len) {
            self.active = self.tabs.items.len - 1;
        }
    }

    /// Close the currently active tab.
    pub fn closeActive(self: *TabManager) void {
        self.closeTab(self.active);
    }

    /// Get the active EditorView.
    pub fn activeView(self: *TabManager) *EditorView {
        return self.tabs.items[self.active];
    }

    /// Switch to the next tab (wraps around).
    pub fn nextTab(self: *TabManager) void {
        if (self.tabs.items.len > 1) {
            self.active = (self.active + 1) % self.tabs.items.len;
        }
    }

    /// Switch to the previous tab (wraps around).
    pub fn prevTab(self: *TabManager) void {
        if (self.tabs.items.len > 1) {
            self.active = if (self.active == 0) self.tabs.items.len - 1 else self.active - 1;
        }
    }

    /// Find a tab by file path. Returns the index or null.
    pub fn findByPath(self: *TabManager, path: []const u8) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.file_path) |tp| {
                if (std.mem.eql(u8, tp, path)) return i;
            }
        }
        return null;
    }

    /// Switch to a specific tab by index.
    pub fn switchTo(self: *TabManager, idx: usize) void {
        if (idx < self.tabs.items.len) {
            self.active = idx;
        }
    }

    /// Number of open tabs.
    pub fn count(self: *const TabManager) usize {
        return self.tabs.items.len;
    }
};
