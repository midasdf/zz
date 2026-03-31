const std = @import("std");

// Placeholder — Task 4 implements this
pub const CursorState = struct {
    pub fn init(_: std.mem.Allocator) CursorState {
        return .{};
    }
    pub fn deinit(_: *CursorState) void {}
};
