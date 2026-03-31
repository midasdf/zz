const std = @import("std");

pub fn main() !void {
    _ = std.posix.write(std.posix.STDOUT_FILENO, "zz editor v0.1.0\n") catch {};
}
