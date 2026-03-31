const std = @import("std");
const PieceTable = @import("buffer.zig").PieceTable;

const ts = @cImport({
    @cInclude("tree_sitter/api.h");
    @cInclude("tree_sitter/tree-sitter-c.h");
    @cInclude("tree_sitter/tree-sitter-python.h");
    @cInclude("tree_sitter/tree-sitter-rust.h");
    @cInclude("tree_sitter/tree-sitter-javascript.h");
    @cInclude("tree_sitter/tree-sitter-bash.h");
});

// ── SyntaxKind ────────────────────────────────────────────────────────

pub const SyntaxKind = enum {
    keyword,
    function,
    function_builtin,
    type_name,
    string,
    number,
    comment,
    operator,
    variable,
    constant,
    property,
    punctuation,
    none,

    pub fn fromCaptureName(name: []const u8) SyntaxKind {
        // Ordered from most specific to least specific
        if (startsWith(name, "function.builtin")) return .function_builtin;
        if (startsWith(name, "function")) return .function;
        if (startsWith(name, "keyword")) return .keyword;
        if (startsWith(name, "type")) return .type_name;
        if (startsWith(name, "string")) return .string;
        if (startsWith(name, "number") or startsWith(name, "float")) return .number;
        if (startsWith(name, "comment")) return .comment;
        if (startsWith(name, "operator")) return .operator;
        if (startsWith(name, "variable")) return .variable;
        if (startsWith(name, "constant")) return .constant;
        if (startsWith(name, "property")) return .property;
        if (startsWith(name, "punctuation")) return .punctuation;
        return .none;
    }

    fn startsWith(haystack: []const u8, prefix: []const u8) bool {
        if (haystack.len < prefix.len) return false;
        return std.mem.eql(u8, haystack[0..prefix.len], prefix);
    }
};

// ── Highlight span ────────────────────────────────────────────────────

pub const Highlight = struct {
    start: u32,
    end: u32,
    kind: SyntaxKind,
};

// ── Read callback (PieceTable -> TSInput bridge) ──────────────────────

fn tsReadCallback(
    payload: ?*anyopaque,
    byte_index: u32,
    _: ts.TSPoint,
    bytes_read: [*c]u32,
) callconv(.c) [*c]const u8 {
    const buffer: *const PieceTable = @ptrCast(@alignCast(payload));
    if (byte_index >= buffer.total_len) {
        bytes_read.* = 0;
        return null;
    }
    const slice = buffer.contiguousSliceAt(byte_index);
    bytes_read.* = @intCast(slice.len);
    if (slice.len == 0) return null;
    return slice.ptr;
}

// ── Highlighter ───────────────────────────────────────────────────────

pub const Highlighter = struct {
    parser: ?*ts.TSParser,
    tree: ?*ts.TSTree,
    query: ?*ts.TSQuery,
    language: ?*const ts.TSLanguage,
    cached_highlights: std.ArrayList(Highlight),
    allocator: std.mem.Allocator,
    lang_name: []const u8,

    pub fn init(allocator: std.mem.Allocator) Highlighter {
        return .{
            .parser = ts.ts_parser_new(),
            .tree = null,
            .query = null,
            .language = null,
            .cached_highlights = .{},
            .allocator = allocator,
            .lang_name = "Plain",
        };
    }

    pub fn deinit(self: *Highlighter) void {
        if (self.query) |q| ts.ts_query_delete(q);
        if (self.tree) |t| ts.ts_tree_delete(t);
        if (self.parser) |p| ts.ts_parser_delete(p);
        self.cached_highlights.deinit(self.allocator);
        self.query = null;
        self.tree = null;
        self.parser = null;
        self.language = null;
    }

    // ── Language detection + setup ────────────────────────────────────

    pub fn setLanguage(self: *Highlighter, file_path: ?[]const u8) void {
        const path = file_path orelse return;

        const ext = extFromPath(path);
        const lang_info = langFromExt(ext) orelse {
            self.language = null;
            self.lang_name = "Plain";
            return;
        };

        self.language = lang_info.factory();
        self.lang_name = lang_info.name;

        if (self.parser) |p| {
            if (!ts.ts_parser_set_language(p, self.language)) {
                self.language = null;
                self.lang_name = "Plain";
                return;
            }
        }

        // Free previous query before loading a new one
        if (self.query) |q| {
            ts.ts_query_delete(q);
            self.query = null;
        }
        self.loadQuery(lang_info.query_dir);
    }

    const LangInfo = struct {
        factory: *const fn () callconv(.c) ?*const ts.TSLanguage,
        name: []const u8,
        query_dir: []const u8,
    };

    fn langFromExt(ext: []const u8) ?LangInfo {
        const map = [_]struct { exts: []const []const u8, info: LangInfo }{
            .{
                .exts = &.{ ".c", ".h" },
                .info = .{ .factory = &ts.tree_sitter_c, .name = "C", .query_dir = "c" },
            },
            .{
                .exts = &.{".py"},
                .info = .{ .factory = &ts.tree_sitter_python, .name = "Python", .query_dir = "python" },
            },
            .{
                .exts = &.{".rs"},
                .info = .{ .factory = &ts.tree_sitter_rust, .name = "Rust", .query_dir = "rust" },
            },
            .{
                .exts = &.{ ".js", ".jsx" },
                .info = .{ .factory = &ts.tree_sitter_javascript, .name = "JavaScript", .query_dir = "javascript" },
            },
            .{
                .exts = &.{ ".sh", ".bash" },
                .info = .{ .factory = &ts.tree_sitter_bash, .name = "Bash", .query_dir = "bash" },
            },
        };

        for (&map) |entry| {
            for (entry.exts) |e| {
                if (std.mem.eql(u8, ext, e)) return entry.info;
            }
        }
        return null;
    }

    fn extFromPath(path: []const u8) []const u8 {
        var i: usize = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '.') return path[i..];
            if (path[i] == '/') break;
        }
        return "";
    }

    // ── Query loading ─────────────────────────────────────────────────

    fn loadQuery(self: *Highlighter, query_dir: []const u8) void {
        const lang = self.language orelse return;

        // Build path: /usr/share/tree-sitter/queries/{lang}/highlights.scm
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/usr/share/tree-sitter/queries/{s}/highlights.scm", .{query_dir}) catch return;

        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        const source = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return;
        defer self.allocator.free(source);

        var error_offset: u32 = 0;
        var error_type: ts.TSQueryError = ts.TSQueryErrorNone;

        self.query = ts.ts_query_new(
            lang,
            source.ptr,
            @intCast(source.len),
            &error_offset,
            &error_type,
        );
    }

    // ── Parsing ───────────────────────────────────────────────────────

    pub fn parse(self: *Highlighter, buffer: *const PieceTable) void {
        const parser = self.parser orelse return;
        if (self.language == null) return;

        const input = ts.TSInput{
            .payload = @constCast(@ptrCast(buffer)),
            .read = &tsReadCallback,
            .encoding = ts.TSInputEncodingUTF8,
            .decode = null,
        };

        const new_tree = ts.ts_parser_parse(parser, self.tree, input);

        // Free old tree only after successful parse
        if (new_tree) |nt| {
            if (self.tree) |old| ts.ts_tree_delete(old);
            self.tree = nt;
        }
    }

    // ── Incremental edit + re-parse ───────────────────────────────────

    pub fn notifyEdit(
        self: *Highlighter,
        buffer: *const PieceTable,
        start_byte: u32,
        old_end_byte: u32,
        new_end_byte: u32,
    ) void {
        if (self.tree) |t| {
            const start_lc = buffer.offsetToLineCol(start_byte);
            const new_end_lc = buffer.offsetToLineCol(new_end_byte);

            // old_end_point: buffer reflects NEW state, so we cannot accurately
            // compute old line:col for multi-line deletions. For single-line edits
            // (most common: typing, backspace), the column estimate is correct.
            // For multi-line deletions, skip ts_tree_edit and do a full re-parse.
            const old_len = old_end_byte - start_byte;
            if (old_len > 200) {
                // Large or potentially multi-line deletion — full re-parse is safer
                ts.ts_tree_delete(t);
                self.tree = null;
                self.parse(buffer);
                return;
            }

            const old_end_col = if (old_len == 0) start_lc.col else start_lc.col + old_len;

            const edit = ts.TSInputEdit{
                .start_byte = start_byte,
                .old_end_byte = old_end_byte,
                .new_end_byte = new_end_byte,
                .start_point = .{ .row = start_lc.line, .column = start_lc.col },
                .old_end_point = .{ .row = start_lc.line, .column = old_end_col },
                .new_end_point = .{ .row = new_end_lc.line, .column = new_end_lc.col },
            };

            ts.ts_tree_edit(t, &edit);
        }

        self.parse(buffer);
    }

    // ── Query execution ───────────────────────────────────────────────

    pub fn queryRange(self: *Highlighter, start_byte: u32, end_byte: u32) void {
        self.cached_highlights.clearRetainingCapacity();

        const q = self.query orelse return;
        const t = self.tree orelse return;

        const root = ts.ts_tree_root_node(t);
        const cursor = ts.ts_query_cursor_new() orelse return;
        defer ts.ts_query_cursor_delete(cursor);

        ts.ts_query_cursor_exec(cursor, q, root);
        _ = ts.ts_query_cursor_set_byte_range(cursor, start_byte, end_byte);

        var match: ts.TSQueryMatch = undefined;
        var capture_index: u32 = undefined;

        while (ts.ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
            if (capture_index >= match.capture_count) continue;
            const capture = match.captures[capture_index];
            const node = capture.node;
            const node_start = ts.ts_node_start_byte(node);
            const node_end = ts.ts_node_end_byte(node);

            // Skip captures outside our range
            if (node_end <= start_byte or node_start >= end_byte) continue;

            var name_len: u32 = 0;
            const name_ptr = ts.ts_query_capture_name_for_id(q, capture.index, &name_len);
            if (name_ptr == null) continue;

            const name = name_ptr[0..name_len];
            const kind = SyntaxKind.fromCaptureName(name);
            if (kind == .none) continue;

            self.cached_highlights.append(self.allocator, .{
                .start = node_start,
                .end = node_end,
                .kind = kind,
            }) catch return;
        }
    }

    // ── Point lookup ──────────────────────────────────────────────────

    pub fn getSyntaxAt(self: *const Highlighter, byte_offset: u32) SyntaxKind {
        // Walk backwards: later captures have higher priority (tree-sitter
        // query semantics: last match wins for overlapping captures).
        var i: usize = self.cached_highlights.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.cached_highlights.items[i];
            if (byte_offset >= h.start and byte_offset < h.end) return h.kind;
        }
        return .none;
    }

    // ── Language name for status bar ──────────────────────────────────

    pub fn languageName(self: *const Highlighter) []const u8 {
        return self.lang_name;
    }
};
