const std = @import("std");

pub const PieceTable = struct {
    original: []const u8,
    owned_original: ?[]u8 = null, // Non-null if we allocated original (for file reopen)
    add_buf: std.ArrayList(u8),
    pieces: std.ArrayList(Piece),
    total_len: u32,
    allocator: std.mem.Allocator,
    undo_stack: std.ArrayList(UndoEntry),
    redo_stack: std.ArrayList(UndoEntry),
    last_edit_pos: ?u32 = null, // For undo coalescing
    last_edit_time: i128 = 0, // nanoseconds from monotonic clock, for undo time-based break
    line_offsets: std.ArrayList(u32), // line_offsets[i] = byte offset of line i
    line_cache_valid: bool = false,

    pub const Source = enum { original, add };

    pub const Piece = struct {
        source: Source,
        start: u32,
        len: u32,
    };

    pub const UndoEntry = struct {
        pieces_snapshot: []Piece,
        total_len: u32,

        pub fn deinit(self: *UndoEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.pieces_snapshot);
        }
    };

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !PieceTable {
        var pieces: std.ArrayList(Piece) = .{};
        if (content.len > 0) {
            try pieces.append(allocator, .{
                .source = .original,
                .start = 0,
                .len = @intCast(content.len),
            });
        }
        return .{
            .original = content,
            .add_buf = .{},
            .pieces = pieces,
            .total_len = @intCast(content.len),
            .allocator = allocator,
            .undo_stack = .{},
            .redo_stack = .{},
            .line_offsets = .{},
        };
    }

    pub fn deinit(self: *PieceTable) void {
        if (self.owned_original) |o| self.allocator.free(o);
        self.pieces.deinit(self.allocator);
        self.add_buf.deinit(self.allocator);
        for (self.undo_stack.items) |*entry| entry.deinit(self.allocator);
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |*entry| entry.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.line_offsets.deinit(self.allocator);
    }

    pub fn pieceContent(self: *const PieceTable, piece: Piece) []const u8 {
        const buf = switch (piece.source) {
            .original => self.original,
            .add => self.add_buf.items,
        };
        return buf[piece.start..][0..piece.len];
    }

    fn rebuildLineCache(self: *PieceTable) void {
        self.line_offsets.clearRetainingCapacity();
        // Line 0 always starts at offset 0
        self.line_offsets.append(self.allocator, 0) catch return;

        var offset: u32 = 0;
        for (self.pieces.items) |piece| {
            const content = self.pieceContent(piece);
            for (content) |byte| {
                offset += 1;
                if (byte == '\n') {
                    self.line_offsets.append(self.allocator, offset) catch return;
                }
            }
        }
        self.line_cache_valid = true;
    }

    fn ensureLineCache(self: *const PieceTable) void {
        if (!self.line_cache_valid) {
            @constCast(self).rebuildLineCache();
        }
    }

    fn invalidateLineCache(self: *PieceTable) void {
        self.line_cache_valid = false;
    }

    pub fn lineCount(self: *const PieceTable) u32 {
        self.ensureLineCache();
        return @intCast(self.line_offsets.items.len);
    }

    // --- Undo helpers ---

    fn pushUndo(self: *PieceTable) !void {
        if (self.undo_stack.items.len >= 1000) {
            var oldest = self.undo_stack.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        const snapshot = try self.allocator.dupe(Piece, self.pieces.items);
        try self.undo_stack.append(self.allocator, .{
            .pieces_snapshot = snapshot,
            .total_len = self.total_len,
        });

        if (self.redo_stack.items.len > 0) {
            for (self.redo_stack.items) |*entry| entry.deinit(self.allocator);
            self.redo_stack.clearRetainingCapacity();
            // Good time to compact: redo is gone, no snapshots reference old offsets
            self.compactIfNeeded();
        }
    }

    /// Compact add_buf by rebuilding with only referenced content.
    /// Only runs when add_buf is large relative to the document and
    /// both undo and redo stacks are empty (no snapshots reference old offsets).
    fn compactIfNeeded(self: *PieceTable) void {
        // Skip if add_buf is small
        if (self.add_buf.items.len < 1024 * 1024) return;
        // Skip if add_buf isn't bloated relative to document size
        if (self.add_buf.items.len < self.total_len * 4) return;
        // Don't compact if undo entries exist (they reference add_buf offsets)
        if (self.undo_stack.items.len > 0) return;

        var new_add: std.ArrayList(u8) = .{};
        for (self.pieces.items) |*piece| {
            if (piece.source == .add) {
                const content = self.add_buf.items[piece.start..][0..piece.len];
                const new_start: u32 = @intCast(new_add.items.len);
                new_add.appendSlice(self.allocator, content) catch return;
                piece.start = new_start;
            }
        }

        self.add_buf.deinit(self.allocator);
        self.add_buf = new_add;
    }

    pub fn undo(self: *PieceTable) !bool {
        self.last_edit_pos = null;
        self.last_edit_time = 0;
        if (self.undo_stack.items.len == 0) return false;

        const current_snapshot = try self.allocator.dupe(Piece, self.pieces.items);
        try self.redo_stack.append(self.allocator, .{
            .pieces_snapshot = current_snapshot,
            .total_len = self.total_len,
        });

        var entry = self.undo_stack.pop().?;
        errdefer entry.deinit(self.allocator);
        self.pieces.clearRetainingCapacity();
        try self.pieces.appendSlice(self.allocator, entry.pieces_snapshot);
        self.total_len = entry.total_len;
        entry.deinit(self.allocator);
        self.invalidateLineCache();

        return true;
    }

    pub fn redo(self: *PieceTable) !bool {
        self.last_edit_time = 0;
        if (self.redo_stack.items.len == 0) return false;

        const current_snapshot = try self.allocator.dupe(Piece, self.pieces.items);
        try self.undo_stack.append(self.allocator, .{
            .pieces_snapshot = current_snapshot,
            .total_len = self.total_len,
        });

        var entry = self.redo_stack.pop().?;
        errdefer entry.deinit(self.allocator);
        self.pieces.clearRetainingCapacity();
        try self.pieces.appendSlice(self.allocator, entry.pieces_snapshot);
        self.total_len = entry.total_len;
        entry.deinit(self.allocator);
        self.invalidateLineCache();

        return true;
    }

    // --- Core operations ---

    pub fn insert(self: *PieceTable, pos: u32, text: []const u8) !void {
        if (text.len == 0) return;
        if (pos > self.total_len) return error.OutOfBounds;

        // Coalesce: single-char inserts at consecutive positions share one undo entry,
        // but break if more than 1 second has passed since the last edit
        const now = std.time.nanoTimestamp();
        const time_gap = now - self.last_edit_time;
        const time_threshold: i128 = 1_000_000_000; // 1 second in ns
        const is_coalesced = text.len == 1 and text[0] != '\n' and
            self.last_edit_pos != null and pos == self.last_edit_pos.? + 1 and
            self.undo_stack.items.len > 0 and
            time_gap < time_threshold;
        if (!is_coalesced) {
            try self.pushUndo();
        }
        self.last_edit_pos = pos;
        self.last_edit_time = now;

        const add_start: u32 = @intCast(self.add_buf.items.len);
        try self.add_buf.appendSlice(self.allocator, text);

        const new_piece = Piece{
            .source = .add,
            .start = add_start,
            .len = @intCast(text.len),
        };

        if (self.pieces.items.len == 0) {
            try self.pieces.append(self.allocator, new_piece);
            self.total_len += @intCast(text.len);
            self.invalidateLineCache();
            return;
        }

        // Find which piece contains `pos`
        var offset: u32 = 0;
        var idx: usize = 0;
        for (self.pieces.items, 0..) |p, i| {
            if (offset + p.len > pos or i == self.pieces.items.len - 1) {
                idx = i;
                break;
            }
            offset += p.len;
        }

        const piece = self.pieces.items[idx];
        const local_pos = pos - offset;

        if (local_pos == 0) {
            try self.pieces.insert(self.allocator, idx, new_piece);
        } else if (local_pos == piece.len) {
            try self.pieces.insert(self.allocator, idx + 1, new_piece);
        } else {
            // Split piece: [before | new_piece | after]
            const before = Piece{
                .source = piece.source,
                .start = piece.start,
                .len = local_pos,
            };
            const after = Piece{
                .source = piece.source,
                .start = piece.start + local_pos,
                .len = piece.len - local_pos,
            };
            self.pieces.items[idx] = before;
            try self.pieces.insert(self.allocator, idx + 1, new_piece);
            try self.pieces.insert(self.allocator, idx + 2, after);
        }

        self.total_len += @intCast(text.len);
        self.invalidateLineCache();
    }

    pub fn delete(self: *PieceTable, pos: u32, len: u32) !void {
        if (len == 0) return;
        if (pos + len > self.total_len) return error.OutOfBounds;

        self.last_edit_pos = null; // Break undo coalescing
        self.last_edit_time = 0;
        try self.pushUndo();

        const end = pos + len;
        var new_pieces: std.ArrayList(Piece) = .{};
        errdefer new_pieces.deinit(self.allocator);

        var offset: u32 = 0;
        for (self.pieces.items) |piece| {
            const piece_start = offset;
            const piece_end = offset + piece.len;
            offset = piece_end;

            if (piece_end <= pos or piece_start >= end) {
                try new_pieces.append(self.allocator, piece);
            } else {
                if (piece_start < pos) {
                    const keep_len = pos - piece_start;
                    try new_pieces.append(self.allocator, .{
                        .source = piece.source,
                        .start = piece.start,
                        .len = keep_len,
                    });
                }
                if (piece_end > end) {
                    const skip = end - piece_start;
                    const keep_len = piece_end - end;
                    try new_pieces.append(self.allocator, .{
                        .source = piece.source,
                        .start = piece.start + skip,
                        .len = keep_len,
                    });
                }
            }
        }

        self.pieces.deinit(self.allocator);
        self.pieces = new_pieces;
        self.total_len -= len;
        self.invalidateLineCache();
    }

    // --- Content access ---

    pub fn writeAll(self: *const PieceTable, writer: anytype) !void {
        for (self.pieces.items) |piece| {
            try writer.writeAll(self.pieceContent(piece));
        }
    }

    pub fn collectContent(self: *const PieceTable, allocator: std.mem.Allocator) ![]u8 {
        const result = try allocator.alloc(u8, self.total_len);
        var offset: usize = 0;
        for (self.pieces.items) |piece| {
            const content = self.pieceContent(piece);
            @memcpy(result[offset..][0..content.len], content);
            offset += content.len;
        }
        return result;
    }

    pub fn contiguousSliceAt(self: *const PieceTable, byte_offset: u32) []const u8 {
        var offset: u32 = 0;
        for (self.pieces.items) |piece| {
            if (offset + piece.len > byte_offset) {
                const local = byte_offset - offset;
                const content = self.pieceContent(piece);
                return content[local..];
            }
            offset += piece.len;
        }
        return "";
    }

    /// Search for `needle` in the buffer starting at `start`, without allocating.
    /// Returns the byte offset of the first match, or null.
    pub fn indexOf(self: *const PieceTable, needle: []const u8, start: u32) ?u32 {
        if (needle.len == 0) return null;
        const nlen: u32 = @intCast(needle.len);
        var off = start;
        while (off + nlen <= self.total_len) {
            const slice = self.contiguousSliceAt(off);
            if (slice.len == 0) break;

            // How many candidate positions can start within this contiguous run
            const search_end: u32 = @intCast(@min(slice.len, self.total_len - off - nlen + 1));
            for (slice[0..search_end], 0..) |ch, i| {
                if (ch == needle[0]) {
                    const candidate = off + @as(u32, @intCast(i));
                    if (self.matchAt(candidate, needle)) return candidate;
                }
            }
            off += @intCast(search_end);
            if (search_end == 0) off += 1;
        }
        return null;
    }

    /// Check if `needle` matches at the given byte offset, across piece boundaries.
    fn matchAt(self: *const PieceTable, off: u32, needle: []const u8) bool {
        var qi: u32 = 0;
        while (qi < needle.len) {
            const slice = self.contiguousSliceAt(off + qi);
            if (slice.len == 0) return false;
            const check_len: u32 = @intCast(@min(slice.len, needle.len - qi));
            if (!std.mem.eql(u8, slice[0..check_len], needle[qi..][0..check_len])) return false;
            qi += check_len;
        }
        return true;
    }

    /// Extract content between two byte offsets into an allocated slice.
    /// Much cheaper than collectContent when you only need a portion of the buffer.
    pub fn extractRange(self: *const PieceTable, allocator: std.mem.Allocator, start: u32, end: u32) ![]u8 {
        if (end <= start) return try allocator.alloc(u8, 0);
        const len = end - start;
        const result = try allocator.alloc(u8, len);
        var write_pos: u32 = 0;
        var off = start;
        while (off < end) {
            const slice = self.contiguousSliceAt(off);
            if (slice.len == 0) break;
            const copy_len: u32 = @intCast(@min(slice.len, end - off));
            @memcpy(result[write_pos..][0..copy_len], slice[0..copy_len]);
            write_pos += copy_len;
            off += copy_len;
        }
        return result[0..write_pos];
    }

    // --- Line/offset conversion ---

    pub fn lineToOffset(self: *const PieceTable, target_line: u32) u32 {
        self.ensureLineCache();
        if (target_line < self.line_offsets.items.len) {
            return self.line_offsets.items[target_line];
        }
        return self.total_len;
    }

    pub fn offsetToLineCol(self: *const PieceTable, target_offset: u32) struct { line: u32, col: u32 } {
        self.ensureLineCache();
        const offsets = self.line_offsets.items;
        // Binary search for the line containing target_offset
        var lo: u32 = 0;
        var hi: u32 = @intCast(offsets.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (offsets[mid] <= target_offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const line = if (lo > 0) lo - 1 else 0;
        const col = target_offset - offsets[line];
        return .{ .line = line, .col = col };
    }
};

// =============================================================================
// Tests
// =============================================================================

fn expectContent(buf: *const PieceTable, expected: []const u8) !void {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(std.testing.allocator);
    try buf.writeAll(out.writer(std.testing.allocator));
    try std.testing.expectEqualStrings(expected, out.items);
}

test "init empty" {
    var buf = try PieceTable.init(std.testing.allocator, "");
    defer buf.deinit();
    try std.testing.expectEqual(@as(u32, 0), buf.total_len);
    try std.testing.expectEqual(@as(usize, 0), buf.pieces.items.len);
    try std.testing.expectEqual(@as(u32, 1), buf.lineCount());
}

test "init with content" {
    const content = "hello\nworld";
    var buf = try PieceTable.init(std.testing.allocator, content);
    defer buf.deinit();
    try std.testing.expectEqual(@as(u32, 11), buf.total_len);
    try std.testing.expectEqual(@as(usize, 1), buf.pieces.items.len);
    try std.testing.expectEqual(@as(u32, 2), buf.lineCount());
}

test "insert into empty" {
    var buf = try PieceTable.init(std.testing.allocator, "");
    defer buf.deinit();
    try buf.insert(0, "hello");
    try std.testing.expectEqual(@as(u32, 5), buf.total_len);
    try expectContent(&buf, "hello");
}

test "insert at beginning" {
    var buf = try PieceTable.init(std.testing.allocator, "world");
    defer buf.deinit();
    try buf.insert(0, "hello ");
    try std.testing.expectEqual(@as(u32, 11), buf.total_len);
    try expectContent(&buf, "hello world");
}

test "insert in middle" {
    var buf = try PieceTable.init(std.testing.allocator, "helo");
    defer buf.deinit();
    try buf.insert(2, "l");
    try expectContent(&buf, "hello");
}

test "insert at end" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try buf.insert(5, " world");
    try expectContent(&buf, "hello world");
}

test "insert out of bounds" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try std.testing.expectError(error.OutOfBounds, buf.insert(10, "x"));
}

test "delete from beginning" {
    var buf = try PieceTable.init(std.testing.allocator, "hello world");
    defer buf.deinit();
    try buf.delete(0, 6);
    try expectContent(&buf, "world");
}

test "delete from middle" {
    var buf = try PieceTable.init(std.testing.allocator, "hello world");
    defer buf.deinit();
    try buf.delete(5, 1);
    try expectContent(&buf, "helloworld");
}

test "delete from end" {
    var buf = try PieceTable.init(std.testing.allocator, "hello world");
    defer buf.deinit();
    try buf.delete(5, 6);
    try expectContent(&buf, "hello");
}

test "delete across pieces" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try buf.insert(5, " world");
    try buf.delete(3, 4);
    try expectContent(&buf, "helorld");
}

test "delete out of bounds" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try std.testing.expectError(error.OutOfBounds, buf.delete(3, 5));
}

test "line to offset" {
    var buf = try PieceTable.init(std.testing.allocator, "line1\nline2\nline3");
    defer buf.deinit();
    try std.testing.expectEqual(@as(u32, 0), buf.lineToOffset(0));
    try std.testing.expectEqual(@as(u32, 6), buf.lineToOffset(1));
    try std.testing.expectEqual(@as(u32, 12), buf.lineToOffset(2));
}

test "offset to line col" {
    var buf = try PieceTable.init(std.testing.allocator, "ab\ncd\nef");
    defer buf.deinit();
    const r0 = buf.offsetToLineCol(0);
    try std.testing.expectEqual(@as(u32, 0), r0.line);
    try std.testing.expectEqual(@as(u32, 0), r0.col);

    const r1 = buf.offsetToLineCol(4);
    try std.testing.expectEqual(@as(u32, 1), r1.line);
    try std.testing.expectEqual(@as(u32, 1), r1.col);

    const r2 = buf.offsetToLineCol(6);
    try std.testing.expectEqual(@as(u32, 2), r2.line);
    try std.testing.expectEqual(@as(u32, 0), r2.col);
}

test "contiguous slice at" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try buf.insert(5, " world");
    const s1 = buf.contiguousSliceAt(3);
    try std.testing.expectEqualStrings("lo", s1);
    const s2 = buf.contiguousSliceAt(5);
    try std.testing.expectEqualStrings(" world", s2);
}

test "undo insert" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try buf.insert(5, " world");
    try std.testing.expectEqual(@as(u32, 11), buf.total_len);

    const undone = try buf.undo();
    try std.testing.expect(undone);
    try std.testing.expectEqual(@as(u32, 5), buf.total_len);
    try expectContent(&buf, "hello");
}

test "undo delete" {
    var buf = try PieceTable.init(std.testing.allocator, "hello world");
    defer buf.deinit();
    try buf.delete(5, 6);
    const undone = try buf.undo();
    try std.testing.expect(undone);
    try expectContent(&buf, "hello world");
}

test "redo" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try buf.insert(5, " world");
    _ = try buf.undo();
    const redone = try buf.redo();
    try std.testing.expect(redone);
    try std.testing.expectEqual(@as(u32, 11), buf.total_len);
}

test "redo cleared on new edit" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try buf.insert(5, " world");
    _ = try buf.undo();
    try buf.insert(5, "!");
    const redone = try buf.redo();
    try std.testing.expect(!redone);
}

test "undo empty returns false" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    const undone = try buf.undo();
    try std.testing.expect(!undone);
}

test "multiple undo redo" {
    var buf = try PieceTable.init(std.testing.allocator, "");
    defer buf.deinit();
    // Consecutive single-char inserts coalesce into one undo entry
    try buf.insert(0, "a");
    try buf.insert(1, "b");
    try buf.insert(2, "c");
    try expectContent(&buf, "abc");

    _ = try buf.undo(); // Undoes all coalesced inserts at once
    try expectContent(&buf, "");
    _ = try buf.redo();
    try expectContent(&buf, "abc");
}

test "undo non-coalesced edits" {
    var buf = try PieceTable.init(std.testing.allocator, "");
    defer buf.deinit();
    try buf.insert(0, "hello"); // Multi-char insert: own undo entry
    try buf.insert(5, " world"); // Multi-char insert: own undo entry
    try expectContent(&buf, "hello world");

    _ = try buf.undo();
    try expectContent(&buf, "hello");
    _ = try buf.undo();
    try expectContent(&buf, "");
}

test "line cache matches sequential scan" {
    var buf = try PieceTable.init(std.testing.allocator, "line1\nline2\nline3\n");
    defer buf.deinit();

    // These should use cache
    try std.testing.expectEqual(@as(u32, 0), buf.lineToOffset(0));
    try std.testing.expectEqual(@as(u32, 6), buf.lineToOffset(1));
    try std.testing.expectEqual(@as(u32, 12), buf.lineToOffset(2));
    try std.testing.expectEqual(@as(u32, 18), buf.lineToOffset(3));
    try std.testing.expectEqual(@as(u32, 4), buf.lineCount());

    // After edit, cache should invalidate and rebuild
    // "line1\nline2\nline3\n" -> insert "new " at 6 -> "line1\nnew line2\nline3\n"
    try buf.insert(6, "new ");
    try std.testing.expectEqual(@as(u32, 6), buf.lineToOffset(1)); // line 1 still starts at offset 6
    try std.testing.expectEqual(@as(u32, 16), buf.lineToOffset(2)); // line 2 shifted by 4

    // offsetToLineCol binary search: offset 10 = "new l" -> line 1, col 4
    const lc = buf.offsetToLineCol(10);
    try std.testing.expectEqual(@as(u32, 1), lc.line);
    try std.testing.expectEqual(@as(u32, 4), lc.col);
}

test "line cache after delete and undo" {
    var buf = try PieceTable.init(std.testing.allocator, "a\nb\nc\n");
    defer buf.deinit();

    try std.testing.expectEqual(@as(u32, 4), buf.lineCount());
    try buf.delete(2, 2); // delete "b\n"
    try std.testing.expectEqual(@as(u32, 3), buf.lineCount());
    try std.testing.expectEqual(@as(u32, 2), buf.lineToOffset(1));

    _ = try buf.undo();
    try std.testing.expectEqual(@as(u32, 4), buf.lineCount());
    try std.testing.expectEqual(@as(u32, 2), buf.lineToOffset(1));
}

test "line cache empty buffer" {
    var buf = try PieceTable.init(std.testing.allocator, "");
    defer buf.deinit();

    try std.testing.expectEqual(@as(u32, 1), buf.lineCount());
    try std.testing.expectEqual(@as(u32, 0), buf.lineToOffset(0));
    try std.testing.expectEqual(@as(u32, 0), buf.lineToOffset(1)); // beyond last line

    const lc = buf.offsetToLineCol(0);
    try std.testing.expectEqual(@as(u32, 0), lc.line);
    try std.testing.expectEqual(@as(u32, 0), lc.col);
}

test "insert at piece boundary" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try buf.insert(5, " world");
    try buf.insert(5, ","); // Insert at exact boundary between pieces
    try expectContent(&buf, "hello, world");
}

test "delete entire content" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try buf.delete(0, 5);
    try std.testing.expectEqual(@as(u32, 0), buf.total_len);
    try expectContent(&buf, "");
}

test "rapid insert delete cycle" {
    var buf = try PieceTable.init(std.testing.allocator, "");
    defer buf.deinit();
    // Simulate rapid typing and deleting
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try buf.insert(i, "x");
    }
    try std.testing.expectEqual(@as(u32, 100), buf.total_len);
    // Delete all
    try buf.delete(0, 100);
    try std.testing.expectEqual(@as(u32, 0), buf.total_len);
}

test "indexOf basic" {
    var buf = try PieceTable.init(std.testing.allocator, "hello world hello");
    defer buf.deinit();
    try std.testing.expectEqual(@as(?u32, 0), buf.indexOf("hello", 0));
    try std.testing.expectEqual(@as(?u32, 12), buf.indexOf("hello", 1));
    try std.testing.expectEqual(@as(?u32, 6), buf.indexOf("world", 0));
    try std.testing.expectEqual(@as(?u32, null), buf.indexOf("xyz", 0));
}

test "indexOf across pieces" {
    var buf = try PieceTable.init(std.testing.allocator, "hel");
    defer buf.deinit();
    try buf.insert(3, "lo world");
    // "hello world" split across two pieces at position 3
    try std.testing.expectEqual(@as(?u32, 0), buf.indexOf("hello", 0));
    try std.testing.expectEqual(@as(?u32, 2), buf.indexOf("llo", 0));
}

test "extractRange" {
    var buf = try PieceTable.init(std.testing.allocator, "hello world");
    defer buf.deinit();
    const range = try buf.extractRange(std.testing.allocator, 6, 11);
    defer std.testing.allocator.free(range);
    try std.testing.expectEqualStrings("world", range);
}

test "extractRange across pieces" {
    var buf = try PieceTable.init(std.testing.allocator, "hello");
    defer buf.deinit();
    try buf.insert(5, " world");
    const range = try buf.extractRange(std.testing.allocator, 3, 8);
    defer std.testing.allocator.free(range);
    try std.testing.expectEqualStrings("lo wo", range);
}
