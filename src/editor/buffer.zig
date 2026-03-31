const std = @import("std");

// Placeholder — Task 2 implements this
pub const PieceTable = struct {
    pub fn init(_: std.mem.Allocator, _: []const u8) !PieceTable {
        return .{};
    }
    pub fn deinit(_: *PieceTable) void {}
};
