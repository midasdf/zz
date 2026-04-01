const std = @import("std");
const EditorView = @import("../editor/view.zig").EditorView;
const lsp = @import("../lsp/client.zig");
const search_ops = @import("search_ops.zig");

/// Notify LSP of a document content change.
pub fn notifyLspChange(editor: *EditorView, lsp_client: *lsp.LspClient, allocator: std.mem.Allocator) void {
    const path = editor.file_path orelse return;
    var uri_buf: [4096]u8 = undefined;
    const uri = lsp.formatUri(path, &uri_buf);
    const content = editor.buffer.collectContent(allocator) catch return;
    defer allocator.free(content);
    lsp_client.didChange(uri, content);
}

/// Apply formatting edits from LSP response (back-to-front to preserve offsets).
pub fn applyFormattingEdits(editor: *EditorView, lsp_client: *lsp.LspClient) void {
    const items = lsp_client.formatting_edits.items;
    if (items.len == 0) return;

    // Build index array sorted descending by position (back-to-front)
    const sorted = editor.allocator.alloc(usize, items.len) catch return;
    defer editor.allocator.free(sorted);
    for (sorted, 0..) |*s, i| s.* = i;

    // Insertion sort descending by position
    var sort_i: usize = 1;
    while (sort_i < sorted.len) : (sort_i += 1) {
        var j = sort_i;
        while (j > 0) {
            const a = items[sorted[j]];
            const b = items[sorted[j - 1]];
            if (a.start_line > b.start_line or (a.start_line == b.start_line and a.start_col > b.start_col)) {
                const tmp = sorted[j];
                sorted[j] = sorted[j - 1];
                sorted[j - 1] = tmp;
                j -= 1;
            } else break;
        }
    }

    const saved_pos = editor.cursor.primary().head;

    for (sorted) |idx| {
        const edit = items[idx];
        const start_off = editor.buffer.lineToOffset(edit.start_line) + edit.start_col;
        const end_off = editor.buffer.lineToOffset(edit.end_line) + edit.end_col;
        const del_len = if (end_off > start_off) end_off - start_off else 0;

        if (del_len > 0) {
            editor.buffer.delete(start_off, del_len) catch continue;
        }
        if (edit.new_text.len > 0) {
            editor.buffer.insert(start_off, edit.new_text) catch continue;
        }
    }

    editor.cursor.moveTo(@min(saved_pos, editor.buffer.total_len));
    editor.ensureCursorVisible();
    editor.modified = true;
    editor.markAllDirty();
    editor.highlighter.parse(&editor.buffer);
}

/// Apply code action text edits to an editor buffer (back-to-front).
pub fn applyCodeActionEdits(editor: *EditorView, items: []const lsp.FormattingEdit) void {
    if (items.len == 0) return;

    // Sort indices descending by position (back-to-front)
    const sorted = editor.allocator.alloc(usize, items.len) catch return;
    defer editor.allocator.free(sorted);
    for (sorted, 0..) |*s, i| s.* = i;

    // Insertion sort descending by position
    var sort_i: usize = 1;
    while (sort_i < sorted.len) : (sort_i += 1) {
        var j = sort_i;
        while (j > 0) {
            const a = items[sorted[j]];
            const b = items[sorted[j - 1]];
            if (a.start_line > b.start_line or (a.start_line == b.start_line and a.start_col > b.start_col)) {
                const tmp = sorted[j];
                sorted[j] = sorted[j - 1];
                sorted[j - 1] = tmp;
                j -= 1;
            } else break;
        }
    }

    const saved_pos = editor.cursor.primary().head;

    for (sorted) |idx| {
        const edit = items[idx];
        const start_off = editor.buffer.lineToOffset(edit.start_line) + edit.start_col;
        const end_off = editor.buffer.lineToOffset(edit.end_line) + edit.end_col;
        const del_len = if (end_off > start_off) end_off - start_off else 0;

        if (del_len > 0) {
            editor.buffer.delete(start_off, del_len) catch continue;
        }
        if (edit.new_text.len > 0) {
            editor.buffer.insert(start_off, edit.new_text) catch continue;
        }
    }

    editor.cursor.moveTo(@min(saved_pos, editor.buffer.total_len));
    editor.ensureCursorVisible();
    editor.modified = true;
    editor.markAllDirty();
    editor.highlighter.parse(&editor.buffer);
}

/// Delete the identifier word immediately before the cursor position.
pub fn deleteWordBeforeCursor(editor: *EditorView) void {
    const pos = editor.cursor.primary().head;
    if (pos == 0) return;

    var start = pos;
    while (start > 0) {
        const slice = editor.buffer.contiguousSliceAt(start - 1);
        if (slice.len == 0) break;
        if (!isWordByte(slice[0])) break;
        start -= 1;
    }

    if (start == pos) return;

    const del_len = pos - start;
    editor.buffer.delete(start, del_len) catch return;
    editor.cursor.moveTo(start);
    editor.markAllDirty();
}

pub fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '_';
}

/// Populate the overlay display with LSP reference locations.
pub fn populateReferencesDisplay(lsp_client: *lsp.LspClient, filtered_display: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    filtered_display.clearRetainingCapacity();
    for (lsp_client.references.items) |ref| {
        const path = lsp.uriToPath(ref.uri) orelse ref.uri;
        // Format as "path:line"
        var buf: [512]u8 = undefined;
        const display = std.fmt.bufPrint(&buf, "{s}:{d}", .{ path, ref.line + 1 }) catch continue;
        const owned = allocator.dupe(u8, display) catch continue;
        filtered_display.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }
}

/// Free heap-allocated reference display strings.
pub fn freeRefDisplay(filtered_display: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    for (filtered_display.items) |item| {
        allocator.free(item);
    }
    filtered_display.clearRetainingCapacity();
}

/// Return a fixed-width prefix string for a given LSP symbol kind.
pub fn symbolKindPrefix(kind: u8) []const u8 {
    return switch (kind) {
        1 => "file ",
        2 => "mod  ",
        5 => "class",
        6 => "meth ",
        12 => "fn   ",
        13 => "var  ",
        14 => "const",
        23 => "strct",
        26 => "type ",
        else => "     ",
    };
}

/// Populate the overlay display with LSP document symbols, optionally filtered.
pub fn populateSymbolDisplay(
    lsp_client: *lsp.LspClient,
    filtered_display: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    query: []const u8,
) void {
    filtered_display.clearRetainingCapacity();
    for (lsp_client.document_symbols.items) |sym| {
        // Build display string: "prefix name"
        const prefix = symbolKindPrefix(sym.kind);
        const display = std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, sym.name }) catch continue;
        // Filter by query if non-empty
        if (query.len > 0) {
            if (!search_ops.containsIgnoreCase(sym.name, query)) {
                allocator.free(display);
                continue;
            }
        }
        filtered_display.append(allocator, display) catch {
            allocator.free(display);
            continue;
        };
    }
}

/// Free heap-allocated symbol display strings.
pub fn freeSymbolDisplay(filtered_display: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    for (filtered_display.items) |item| {
        allocator.free(item);
    }
    filtered_display.clearRetainingCapacity();
}
