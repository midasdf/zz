const std = @import("std");
const EditorView = @import("../editor/view.zig").EditorView;

/// Search for a query string across multiple files, appending formatted results.
pub fn searchInFiles(
    allocator: std.mem.Allocator,
    query: []const u8,
    files: []const []const u8,
    max_results: usize,
    results: *std.ArrayList([]u8),
) void {
    for (files) |file_path| {
        if (results.items.len >= max_results) break;
        const content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch continue;
        defer allocator.free(content);

        var line_num: u32 = 1;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (results.items.len >= max_results) break;
            if (containsIgnoreCase(line, query)) {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                const preview_len = @min(trimmed.len, 60);
                const result = std.fmt.allocPrint(allocator, "{s}:{d}: {s}", .{ file_path, line_num, trimmed[0..preview_len] }) catch continue;
                results.append(allocator, result) catch {
                    allocator.free(result);
                    continue;
                };
            }
            line_num += 1;
        }
    }
}

/// Case-insensitive substring search.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const end = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            const hn = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            const nn = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
            if (hn != nn) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

pub const ParsedSearchResult = struct {
    path: []const u8,
    line: u32,
};

/// Parse a search result string in "path:line: content" format.
pub fn parseSearchResult(result: []const u8) ?ParsedSearchResult {
    // Format: "path:line: content"
    // Find the line number by looking for :DIGITS: pattern
    // Scan for a colon followed by digits followed by colon
    var i: usize = 0;
    while (i < result.len) {
        if (result[i] == ':' and i + 1 < result.len) {
            // Check if digits follow
            var j = i + 1;
            while (j < result.len and result[j] >= '0' and result[j] <= '9') j += 1;
            if (j > i + 1 and j < result.len and result[j] == ':') {
                // Found :DIGITS: pattern
                const line_str = result[i + 1 .. j];
                const line_num = std.fmt.parseInt(u32, line_str, 10) catch {
                    i += 1;
                    continue;
                };
                return .{ .path = result[0..i], .line = line_num };
            }
        }
        i += 1;
    }
    return null;
}

/// Find the next occurrence of query in the editor buffer, wrapping around.
/// Uses PieceTable.indexOf to avoid allocating the entire buffer.
pub fn findNext(editor: *EditorView, query: []const u8) void {
    if (query.len == 0) return;
    const start: u32 = @min(editor.cursor.primary().head + 1, editor.buffer.total_len);
    const qlen: u32 = @intCast(query.len);

    // Search forward from cursor
    if (editor.buffer.indexOf(query, start)) |pos| {
        editor.cursor.cursors.items[0] = .{ .anchor = pos, .head = pos + qlen };
        editor.ensureCursorVisible();
        return;
    }
    // Wrap around: search from beginning
    if (editor.buffer.indexOf(query, 0)) |pos| {
        editor.cursor.cursors.items[0] = .{ .anchor = pos, .head = pos + qlen };
        editor.ensureCursorVisible();
    }
}

/// Replace current selection if it matches query, then find next occurrence.
pub fn replaceCurrentAndFindNext(editor: *EditorView, query: []const u8, replacement: []const u8, allocator: std.mem.Allocator) void {
    if (query.len == 0) return;

    const sel = editor.cursor.primary();
    // Check if current selection matches the search query
    if (sel.hasSelection()) {
        const selected = editor.getSelectedText() orelse {
            findNext(editor, query);
            return;
        };
        defer allocator.free(selected);

        if (std.mem.eql(u8, selected, query)) {
            // Replace the current selection
            editor.deleteSelection() catch return;
            editor.insertAtCursor(replacement) catch return;
        }
    }

    // Find next occurrence
    findNext(editor, query);
}
