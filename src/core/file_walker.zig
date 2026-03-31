const std = @import("std");

/// Walk a directory and collect file paths (relative to root).
/// Skips .git/, node_modules/, zig-cache/, .zig-cache/, zig-out/
/// Respects .gitignore at root level (simple glob patterns only).
pub fn walkFiles(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    max_files: usize,
) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .{};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    // Load .gitignore if present
    var ignore_patterns: std.ArrayList([]const u8) = .{};
    defer ignore_patterns.deinit(allocator);

    // Read .gitignore from root_path directory
    var root_dir = std.fs.cwd().openDir(root_path, .{}) catch null;
    const gitignore = if (root_dir) |*rd| blk: {
        defer rd.close();
        break :blk rd.readFileAlloc(allocator, ".gitignore", 64 * 1024) catch null;
    } else null;
    if (gitignore) |content| {
        defer allocator.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            // Store a copy of the pattern
            const pat = allocator.dupe(u8, trimmed) catch continue;
            ignore_patterns.append(allocator, pat) catch {
                allocator.free(pat);
            };
        }
    }
    defer for (ignore_patterns.items) |p| allocator.free(p);

    // Walk directory
    var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch return try files.toOwnedSlice(allocator);
    defer dir.close();

    try walkDir(allocator, dir, "", &files, ignore_patterns.items, max_files);

    return try files.toOwnedSlice(allocator);
}

fn walkDir(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    files: *std.ArrayList([]const u8),
    ignore_patterns: []const []const u8,
    max_files: usize,
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (files.items.len >= max_files) return;

        const name = entry.name;

        // Skip hidden dirs and common build dirs
        if (name[0] == '.') continue;
        if (std.mem.eql(u8, name, "node_modules")) continue;
        if (std.mem.eql(u8, name, "zig-cache")) continue;
        if (std.mem.eql(u8, name, "zig-out")) continue;
        if (std.mem.eql(u8, name, "__pycache__")) continue;
        if (std.mem.eql(u8, name, "target")) continue; // Rust build dir

        // Build relative path
        const rel_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);

        // Check gitignore
        if (isIgnored(rel_path, name, ignore_patterns)) {
            allocator.free(rel_path);
            continue;
        }

        if (entry.kind == .directory) {
            var subdir = dir.openDir(name, .{ .iterate = true }) catch {
                allocator.free(rel_path);
                continue;
            };
            defer subdir.close();
            walkDir(allocator, subdir, rel_path, files, ignore_patterns, max_files) catch {};
            allocator.free(rel_path);
        } else if (entry.kind == .file) {
            try files.append(allocator, rel_path);
        } else {
            allocator.free(rel_path);
        }
    }
}

fn isIgnored(rel_path: []const u8, name: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        // Simple pattern matching
        if (pattern.len == 0) continue;

        // Strip trailing /
        const pat = if (pattern[pattern.len - 1] == '/') pattern[0 .. pattern.len - 1] else pattern;

        // Exact name match (e.g., "*.o" matches any .o file)
        if (pat[0] == '*' and pat.len > 1) {
            // Wildcard suffix match: *.ext
            const suffix = pat[1..];
            if (std.mem.endsWith(u8, name, suffix)) return true;
        } else if (std.mem.indexOfScalar(u8, pat, '/') != null) {
            // Path pattern — match on segment boundary
            if (std.mem.startsWith(u8, rel_path, pat) and
                (rel_path.len == pat.len or rel_path[pat.len] == '/')) return true;
        } else {
            // Simple name match
            if (std.mem.eql(u8, name, pat)) return true;
        }
    }
    return false;
}

/// Free a file list returned by walkFiles.
pub fn freeFiles(allocator: std.mem.Allocator, files: [][]const u8) void {
    for (files) |f| allocator.free(f);
    allocator.free(files);
}
