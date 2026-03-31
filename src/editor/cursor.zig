const std = @import("std");
const PieceTable = @import("buffer.zig").PieceTable;

pub const Selection = struct {
    anchor: u32,
    head: u32,

    pub fn hasSelection(self: Selection) bool {
        return self.anchor != self.head;
    }

    pub fn start(self: Selection) u32 {
        return @min(self.anchor, self.head);
    }

    pub fn end(self: Selection) u32 {
        return @max(self.anchor, self.head);
    }

    pub fn collapse(self: *Selection) void {
        self.anchor = self.head;
    }
};

pub const CursorState = struct {
    cursors: std.ArrayList(Selection),
    desired_col: ?u32 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CursorState {
        var cursors: std.ArrayList(Selection) = .{};
        try cursors.append(allocator, .{ .anchor = 0, .head = 0 });
        return .{ .cursors = cursors, .desired_col = null, .allocator = allocator };
    }

    pub fn deinit(self: *CursorState) void {
        self.cursors.deinit(self.allocator);
    }

    pub fn primary(self: *const CursorState) Selection {
        return self.cursors.items[0];
    }

    pub fn moveTo(self: *CursorState, pos: u32) void {
        self.cursors.items[0] = .{ .anchor = pos, .head = pos };
        self.desired_col = null;
    }

    pub fn selectTo(self: *CursorState, pos: u32) void {
        self.cursors.items[0].head = pos;
    }

    pub fn moveRight(self: *CursorState, buf: *const PieceTable, extend: bool) void {
        const cur = &self.cursors.items[0];
        if (cur.head < buf.total_len) {
            const slice = buf.contiguousSliceAt(cur.head);
            if (slice.len == 0) {
                cur.head = buf.total_len;
            } else {
                const byte_len = utf8ByteLen(slice[0]);
                cur.head = @min(cur.head + byte_len, buf.total_len);
            }
        }
        if (!extend) cur.anchor = cur.head;
        self.desired_col = null;
    }

    pub fn moveLeft(self: *CursorState, buf: *const PieceTable, extend: bool) void {
        const cur = &self.cursors.items[0];
        if (cur.head > 0) {
            var pos = cur.head - 1;
            while (pos > 0) {
                const slice = buf.contiguousSliceAt(pos);
                if (slice.len == 0) break;
                if ((slice[0] & 0xC0) != 0x80) break;
                pos -= 1;
            }
            cur.head = pos;
        }
        if (!extend) cur.anchor = cur.head;
        self.desired_col = null;
    }

    pub fn moveHome(self: *CursorState, buf: *const PieceTable, extend: bool) void {
        const cur = &self.cursors.items[0];
        const lc = buf.offsetToLineCol(cur.head);
        cur.head = buf.lineToOffset(lc.line);
        if (!extend) cur.anchor = cur.head;
        self.desired_col = null;
    }

    pub fn moveEnd(self: *CursorState, buf: *const PieceTable, extend: bool) void {
        const cur = &self.cursors.items[0];
        const lc = buf.offsetToLineCol(cur.head);
        if (lc.line + 1 < buf.lineCount()) {
            cur.head = buf.lineToOffset(lc.line + 1) - 1;
        } else {
            cur.head = buf.total_len;
        }
        if (!extend) cur.anchor = cur.head;
        self.desired_col = null;
    }

    // ── Multi-cursor support ─────────────────────────────────────────

    pub fn addCursorAt(self: *CursorState, pos: u32) !void {
        try self.cursors.append(self.allocator, .{ .anchor = pos, .head = pos });
    }

    pub fn addSelection(self: *CursorState, sel: Selection) !void {
        try self.cursors.append(self.allocator, sel);
    }

    pub fn collapseToSingle(self: *CursorState) void {
        if (self.cursors.items.len > 1) {
            const primary_sel = self.cursors.items[0];
            self.cursors.clearRetainingCapacity();
            self.cursors.append(self.allocator, primary_sel) catch {};
        }
    }

    pub fn cursorCount(self: *const CursorState) usize {
        return self.cursors.items.len;
    }

    /// Sort cursors descending by head position (for back-to-front editing).
    pub fn sortDescending(self: *CursorState) void {
        const items = self.cursors.items;
        // Simple insertion sort -- cursor counts are small
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            const key = items[i];
            var j: usize = i;
            while (j > 0 and items[j - 1].head < key.head) {
                items[j] = items[j - 1];
                j -= 1;
            }
            items[j] = key;
        }
    }

    /// Adjust all cursor positions after an edit.
    /// Cursors at or after `edit_pos` are shifted by `delta`.
    pub fn adjustPositionsAfter(self: *CursorState, edit_pos: u32, delta: i64, skip_index: usize) void {
        for (self.cursors.items, 0..) |*sel, idx| {
            if (idx == skip_index) continue;
            sel.anchor = applyDelta(sel.anchor, edit_pos, delta);
            sel.head = applyDelta(sel.head, edit_pos, delta);
        }
    }

    fn applyDelta(pos: u32, edit_pos: u32, delta: i64) u32 {
        if (pos < edit_pos) return pos;
        const result = @as(i64, pos) + delta;
        return if (result < 0) 0 else @intCast(result);
    }

    pub fn utf8ByteLen(first_byte: u8) u32 {
        if (first_byte < 0x80) return 1;
        if (first_byte < 0xE0) return 2;
        if (first_byte < 0xF0) return 3;
        return 4;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "move right" {
    var buf = try PieceTable.init(std.testing.allocator, "abc");
    defer buf.deinit();
    var cs = try CursorState.init(std.testing.allocator);
    defer cs.deinit();

    cs.moveRight(&buf, false);
    try std.testing.expectEqual(@as(u32, 1), cs.primary().head);
    cs.moveRight(&buf, false);
    try std.testing.expectEqual(@as(u32, 2), cs.primary().head);
    cs.moveRight(&buf, false);
    try std.testing.expectEqual(@as(u32, 3), cs.primary().head);
    cs.moveRight(&buf, false);
    try std.testing.expectEqual(@as(u32, 3), cs.primary().head);
}

test "move left" {
    var buf = try PieceTable.init(std.testing.allocator, "abc");
    defer buf.deinit();
    var cs = try CursorState.init(std.testing.allocator);
    defer cs.deinit();

    cs.moveTo(3);
    cs.moveLeft(&buf, false);
    try std.testing.expectEqual(@as(u32, 2), cs.primary().head);
    cs.moveLeft(&buf, false);
    try std.testing.expectEqual(@as(u32, 1), cs.primary().head);
    cs.moveLeft(&buf, false);
    try std.testing.expectEqual(@as(u32, 0), cs.primary().head);
    cs.moveLeft(&buf, false);
    try std.testing.expectEqual(@as(u32, 0), cs.primary().head);
}

test "selection extend" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    var cs = try CursorState.init(std.testing.allocator);
    defer cs.deinit();

    cs.moveRight(&buf, true);
    cs.moveRight(&buf, true);
    try std.testing.expectEqual(@as(u32, 0), cs.primary().anchor);
    try std.testing.expectEqual(@as(u32, 2), cs.primary().head);
    try std.testing.expect(cs.primary().hasSelection());
}

test "home and end" {
    var buf = try PieceTable.init(std.testing.allocator, "hello\nworld");
    defer buf.deinit();
    var cs = try CursorState.init(std.testing.allocator);
    defer cs.deinit();

    cs.moveTo(8); // 'r' in "world"
    cs.moveHome(&buf, false);
    try std.testing.expectEqual(@as(u32, 6), cs.primary().head);
    cs.moveEnd(&buf, false);
    try std.testing.expectEqual(@as(u32, 11), cs.primary().head);
}

test "selection start end" {
    const sel = Selection{ .anchor = 5, .head = 2 };
    try std.testing.expectEqual(@as(u32, 2), sel.start());
    try std.testing.expectEqual(@as(u32, 5), sel.end());
    try std.testing.expect(sel.hasSelection());
}

test "utf8 move right" {
    // "aあb" = 'a'(1) + 'あ'(3) + 'b'(1) = 5 bytes
    var buf = try PieceTable.init(std.testing.allocator, "a\xe3\x81\x82b");
    defer buf.deinit();
    var cs = try CursorState.init(std.testing.allocator);
    defer cs.deinit();

    cs.moveRight(&buf, false); // skip 'a'
    try std.testing.expectEqual(@as(u32, 1), cs.primary().head);
    cs.moveRight(&buf, false); // skip 'あ' (3 bytes)
    try std.testing.expectEqual(@as(u32, 4), cs.primary().head);
    cs.moveRight(&buf, false); // skip 'b'
    try std.testing.expectEqual(@as(u32, 5), cs.primary().head);
}
