const std = @import("std");

pub const PieceTable = struct {
    original: []const u8,
    add_buf: std.ArrayList(u8),
    pieces: std.ArrayList(Piece),
    total_len: u32,
    allocator: std.mem.Allocator,
    undo_stack: std.ArrayList(UndoEntry),
    redo_stack: std.ArrayList(UndoEntry),

    pub const Source = enum { original, add };

    pub const Piece = struct {
        source: Source,
        start: u32,
        len: u32,
        newline_count: u32,
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
                .newline_count = countNewlines(content),
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
        };
    }

    pub fn deinit(self: *PieceTable) void {
        self.pieces.deinit(self.allocator);
        self.add_buf.deinit(self.allocator);
        for (self.undo_stack.items) |*entry| entry.deinit(self.allocator);
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |*entry| entry.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    pub fn countNewlines(data: []const u8) u32 {
        var count: u32 = 0;
        for (data) |byte| {
            if (byte == '\n') count += 1;
        }
        return count;
    }

    pub fn pieceContent(self: *const PieceTable, piece: Piece) []const u8 {
        const buf = switch (piece.source) {
            .original => self.original,
            .add => self.add_buf.items,
        };
        return buf[piece.start..][0..piece.len];
    }

    pub fn lineCount(self: *const PieceTable) u32 {
        var total: u32 = 0;
        for (self.pieces.items) |p| {
            total += p.newline_count;
        }
        return total + 1;
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

        for (self.redo_stack.items) |*entry| entry.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn undo(self: *PieceTable) !bool {
        if (self.undo_stack.items.len == 0) return false;

        const current_snapshot = try self.allocator.dupe(Piece, self.pieces.items);
        try self.redo_stack.append(self.allocator, .{
            .pieces_snapshot = current_snapshot,
            .total_len = self.total_len,
        });

        var entry = self.undo_stack.pop().?;
        self.pieces.clearRetainingCapacity();
        try self.pieces.appendSlice(self.allocator, entry.pieces_snapshot);
        self.total_len = entry.total_len;
        entry.deinit(self.allocator);

        return true;
    }

    pub fn redo(self: *PieceTable) !bool {
        if (self.redo_stack.items.len == 0) return false;

        const current_snapshot = try self.allocator.dupe(Piece, self.pieces.items);
        try self.undo_stack.append(self.allocator, .{
            .pieces_snapshot = current_snapshot,
            .total_len = self.total_len,
        });

        var entry = self.redo_stack.pop().?;
        self.pieces.clearRetainingCapacity();
        try self.pieces.appendSlice(self.allocator, entry.pieces_snapshot);
        self.total_len = entry.total_len;
        entry.deinit(self.allocator);

        return true;
    }

    // --- Core operations ---

    pub fn insert(self: *PieceTable, pos: u32, text: []const u8) !void {
        if (text.len == 0) return;
        if (pos > self.total_len) return error.OutOfBounds;

        try self.pushUndo();

        const add_start: u32 = @intCast(self.add_buf.items.len);
        try self.add_buf.appendSlice(self.allocator, text);

        const new_piece = Piece{
            .source = .add,
            .start = add_start,
            .len = @intCast(text.len),
            .newline_count = countNewlines(text),
        };

        if (self.pieces.items.len == 0) {
            try self.pieces.append(self.allocator, new_piece);
            self.total_len += @intCast(text.len);
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
            const content = self.pieceContent(piece);
            const before = Piece{
                .source = piece.source,
                .start = piece.start,
                .len = local_pos,
                .newline_count = countNewlines(content[0..local_pos]),
            };
            const after = Piece{
                .source = piece.source,
                .start = piece.start + local_pos,
                .len = piece.len - local_pos,
                .newline_count = countNewlines(content[local_pos..]),
            };
            self.pieces.items[idx] = before;
            try self.pieces.insert(self.allocator, idx + 1, new_piece);
            try self.pieces.insert(self.allocator, idx + 2, after);
        }

        self.total_len += @intCast(text.len);
    }

    pub fn delete(self: *PieceTable, pos: u32, len: u32) !void {
        if (len == 0) return;
        if (pos + len > self.total_len) return error.OutOfBounds;

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
                        .newline_count = countNewlines(self.pieceContent(piece)[0..keep_len]),
                    });
                }
                if (piece_end > end) {
                    const skip = end - piece_start;
                    const keep_len = piece_end - end;
                    try new_pieces.append(self.allocator, .{
                        .source = piece.source,
                        .start = piece.start + skip,
                        .len = keep_len,
                        .newline_count = countNewlines(self.pieceContent(piece)[skip..]),
                    });
                }
            }
        }

        self.pieces.deinit(self.allocator);
        self.pieces = new_pieces;
        self.total_len -= len;
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

    // --- Line/offset conversion ---

    pub fn lineToOffset(self: *const PieceTable, target_line: u32) u32 {
        if (target_line == 0) return 0;

        var line: u32 = 0;
        var offset: u32 = 0;
        for (self.pieces.items) |piece| {
            if (line + piece.newline_count >= target_line) {
                const content = self.pieceContent(piece);
                for (content) |byte| {
                    if (byte == '\n') {
                        line += 1;
                        if (line == target_line) return offset + 1;
                    }
                    offset += 1;
                }
            } else {
                line += piece.newline_count;
                offset += piece.len;
            }
        }
        return offset;
    }

    pub fn offsetToLineCol(self: *const PieceTable, target_offset: u32) struct { line: u32, col: u32 } {
        var line: u32 = 0;
        var col: u32 = 0;
        var offset: u32 = 0;
        for (self.pieces.items) |piece| {
            const content = self.pieceContent(piece);
            for (content) |byte| {
                if (offset == target_offset) return .{ .line = line, .col = col };
                if (byte == '\n') {
                    line += 1;
                    col = 0;
                } else {
                    col += 1;
                }
                offset += 1;
            }
        }
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
    try buf.insert(0, "a");
    try buf.insert(1, "b");
    try buf.insert(2, "c");
    try expectContent(&buf, "abc");

    _ = try buf.undo();
    try expectContent(&buf, "ab");
    _ = try buf.undo();
    try expectContent(&buf, "a");
    _ = try buf.redo();
    try expectContent(&buf, "ab");
}
