const std = @import("std");

pub const GitInfo = struct {
    branch: [64]u8 = undefined,
    branch_len: u32 = 0,
    diff_lines: std.ArrayList(DiffLine),
    allocator: std.mem.Allocator,

    pub const DiffLine = struct {
        line: u32, // 0-based line number
        kind: Kind,

        pub const Kind = enum { added, modified, deleted };
    };

    pub fn init(allocator: std.mem.Allocator) GitInfo {
        return .{
            .diff_lines = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitInfo) void {
        self.diff_lines.deinit(self.allocator);
    }

    /// Read current branch from .git/HEAD
    pub fn readBranch(self: *GitInfo) void {
        const head = std.fs.cwd().readFileAlloc(self.allocator, ".git/HEAD", 256) catch return;
        defer self.allocator.free(head);

        const prefix = "ref: refs/heads/";
        if (std.mem.startsWith(u8, head, prefix)) {
            const rest = head[prefix.len..];
            const branch = std.mem.trim(u8, rest, "\n\r ");
            const len: u32 = @intCast(@min(branch.len, self.branch.len));
            @memcpy(self.branch[0..len], branch[0..len]);
            self.branch_len = len;
        } else {
            // Detached HEAD -- show first 8 chars of hash
            const hash = std.mem.trim(u8, head, "\n\r ");
            const len: u32 = @intCast(@min(hash.len, 8));
            @memcpy(self.branch[0..len], hash[0..len]);
            self.branch_len = len;
        }
    }

    pub fn branchName(self: *const GitInfo) []const u8 {
        return self.branch[0..self.branch_len];
    }

    /// Compute diff against git HEAD for a file.
    /// Runs `git diff HEAD -- <path>` and parses unified diff hunk headers.
    pub fn computeDiff(self: *GitInfo, file_path: []const u8) void {
        self.diff_lines.clearRetainingCapacity();

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "git", "diff", "HEAD", "--unified=0", "--", file_path },
        }) catch return;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Parse unified diff output for hunk headers: @@ -old,count +new,count @@
        var it = std.mem.splitScalar(u8, result.stdout, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "@@ ")) continue;
            self.parseHunk(line);
        }
    }

    /// Parse a hunk header like "@@ -10,3 +12,5 @@" or "@@ -10 +12,5 @@"
    /// and mark lines as added/modified/deleted.
    fn parseHunk(self: *GitInfo, header: []const u8) void {
        // Find the +N,M part (new file side)
        const plus_idx = std.mem.indexOf(u8, header, " +") orelse return;
        const after_plus = header[plus_idx + 2 ..];
        // Find end of the range (next space or @)
        const end_idx = std.mem.indexOfAny(u8, after_plus, " @") orelse after_plus.len;
        const range_str = after_plus[0..end_idx];

        // Parse start,count or just start
        var new_start: u32 = 0;
        var new_count: u32 = 1;

        if (std.mem.indexOfScalar(u8, range_str, ',')) |comma| {
            new_start = std.fmt.parseInt(u32, range_str[0..comma], 10) catch return;
            new_count = std.fmt.parseInt(u32, range_str[comma + 1 ..], 10) catch return;
        } else {
            new_start = std.fmt.parseInt(u32, range_str, 10) catch return;
        }

        // Also parse old side to determine kind
        const minus_idx = std.mem.indexOf(u8, header, " -") orelse return;
        const after_minus = header[minus_idx + 2 ..];

        // Find old count
        var old_count: u32 = 1;
        const old_range_end = std.mem.indexOfAny(u8, after_minus, " @") orelse after_minus.len;
        const old_range = after_minus[0..old_range_end];
        if (std.mem.indexOfScalar(u8, old_range, ',')) |comma| {
            old_count = std.fmt.parseInt(u32, old_range[comma + 1 ..], 10) catch 1;
        }

        // Determine kind based on old_count and new_count
        if (new_count == 0) {
            // Pure deletion: old lines removed, nothing added at new_start
            // Mark the line where deletion occurred (line before, 0-based)
            const del_line = if (new_start > 0) new_start - 1 else 0;
            self.diff_lines.append(self.allocator, .{ .line = del_line, .kind = .deleted }) catch {};
        } else if (old_count == 0) {
            // Pure addition
            if (new_start == 0) return; // guard: 0 is invalid in unified diff (1-based)
            var i: u32 = 0;
            while (i < new_count) : (i += 1) {
                const line_0based = new_start - 1 + i; // convert 1-based to 0-based
                self.diff_lines.append(self.allocator, .{ .line = line_0based, .kind = .added }) catch {};
            }
        } else {
            // Modification (both old and new have content)
            if (new_start == 0) return; // guard: 0 is invalid in unified diff (1-based)
            var i: u32 = 0;
            while (i < new_count) : (i += 1) {
                const line_0based = new_start - 1 + i;
                self.diff_lines.append(self.allocator, .{ .line = line_0based, .kind = .modified }) catch {};
            }
        }
    }

    /// Look up the diff kind for a given 0-based line number.
    pub fn lineKind(self: *const GitInfo, line: u32) ?DiffLine.Kind {
        for (self.diff_lines.items) |d| {
            if (d.line == line) return d.kind;
        }
        return null;
    }
};
