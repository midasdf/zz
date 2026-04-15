const std = @import("std");
const posix = std.posix;

// ── Data types ──────────────────────────────────────────────────────

pub const Diagnostic = struct {
    line: u32, // 0-based
    col_start: u32, // 0-based byte offset
    col_end: u32,
    severity: Severity,
    message: []u8, // Owned

    pub const Severity = enum { err, warning, info, hint };
};

pub const CompletionItem = struct {
    label: []u8, // Owned
    detail: ?[]u8, // Owned, nullable
    kind: u8, // CompletionItemKind number
};

pub const Location = struct {
    uri: []u8, // Owned
    line: u32,
    col: u32,
};

pub const FormattingEdit = struct {
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    new_text: []u8, // Owned
};

pub const DocumentSymbol = struct {
    name: []u8, // owned
    kind: u8, // SymbolKind number
    line: u32,
};

pub const CodeAction = struct {
    title: []u8, // owned
    // Store workspace edit if present (array of FormattingEdit per file)
    edits: std.ArrayList(FormattingEdit),
    edit_uri: ?[]u8, // owned URI for the edits (null if no edit)
};

pub const RenameEdit = struct {
    uri: []u8, // owned
    edits: std.ArrayList(FormattingEdit),
};

pub const SignatureInfo = struct {
    label: []u8, // Owned - full signature label
    active_param: u32, // Which parameter is active
    param_offsets: ?ParamRange = null, // Byte offsets of active param in label

    pub const ParamRange = struct { start: u32, end: u32 };
};

pub const ServerCapabilities = struct {
    has_completion: bool = false,
    has_definition: bool = false,
    has_hover: bool = false,
    has_formatting: bool = false,
    has_document_symbols: bool = false,
    has_rename: bool = false,
    has_code_action: bool = false,
    has_references: bool = false,
    has_signature_help: bool = false,
};

// ── LSP Client ──────────────────────────────────────────────────────

pub const LspClient = struct {
    process: ?std.process.Child,
    allocator: std.mem.Allocator,
    io: std.Io,
    next_id: u32,
    server_capabilities: ServerCapabilities,
    initialized: bool,

    // Diagnostics received from server
    diagnostics: std.ArrayList(Diagnostic),

    // Pending completion response
    completion_items: std.ArrayList(CompletionItem),
    has_completion: bool,

    // Pending definition response
    goto_location: ?Location,
    has_goto: bool,

    // Pending hover response
    hover_text: ?[]u8,
    has_hover: bool,

    // Read buffer for JSON-RPC framing
    read_buf: [65536]u8,
    read_pos: usize,

    // Partial message buffer
    msg_buf: std.ArrayList(u8),
    expected_content_length: ?usize,

    // Document version counter for textDocument/didChange
    doc_version: u32,

    // Pending formatting response
    formatting_edits: std.ArrayList(FormattingEdit),
    has_formatting: bool,

    // Pending document symbols response
    document_symbols: std.ArrayList(DocumentSymbol),
    has_symbols: bool,

    // Pending rename response
    rename_edits: std.ArrayList(RenameEdit),
    has_rename: bool,

    // Pending code action response
    code_actions: std.ArrayList(CodeAction),
    has_code_actions: bool,

    // Pending references response
    references: std.ArrayList(Location),
    has_references: bool,

    // Pending signature help response
    signature: ?SignatureInfo,
    has_signature: bool,

    // Track pending request IDs
    pending_completion_id: ?u32,
    pending_definition_id: ?u32,
    pending_hover_id: ?u32,
    pending_formatting_id: ?u32,
    pending_symbols_id: ?u32,
    pending_rename_id: ?u32,
    pending_code_action_id: ?u32,
    pending_references_id: ?u32,
    pending_signature_id: ?u32,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) LspClient {
        return .{
            .process = null,
            .allocator = allocator,
            .io = io,
            .next_id = 1,
            .server_capabilities = .{},
            .initialized = false,
            .diagnostics = .empty,
            .completion_items = .empty,
            .has_completion = false,
            .goto_location = null,
            .has_goto = false,
            .hover_text = null,
            .has_hover = false,
            .formatting_edits = .empty,
            .has_formatting = false,
            .document_symbols = .empty,
            .has_symbols = false,
            .rename_edits = .empty,
            .has_rename = false,
            .code_actions = .empty,
            .has_code_actions = false,
            .references = .empty,
            .has_references = false,
            .signature = null,
            .has_signature = false,
            .read_buf = undefined,
            .read_pos = 0,
            .msg_buf = .empty,
            .expected_content_length = null,
            .doc_version = 1,
            .pending_completion_id = null,
            .pending_definition_id = null,
            .pending_hover_id = null,
            .pending_formatting_id = null,
            .pending_symbols_id = null,
            .pending_rename_id = null,
            .pending_code_action_id = null,
            .pending_references_id = null,
            .pending_signature_id = null,
        };
    }

    pub fn start(self: *LspClient, server_cmd: []const u8, root_path: []const u8) !void {
        // Split server_cmd on first space for argv (e.g. "zls" or "clangd --background-index")
        var argv_buf: [16][]const u8 = undefined;
        var argc: usize = 0;
        var it = std.mem.splitScalar(u8, server_cmd, ' ');
        while (it.next()) |arg| {
            if (argc >= argv_buf.len) break;
            if (arg.len > 0) {
                argv_buf[argc] = arg;
                argc += 1;
            }
        }
        if (argc == 0) return error.InvalidCommand;

        const child = try std.process.spawn(self.io, .{
            .argv = argv_buf[0..argc],
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        self.process = child;

        // Set stdout to non-blocking for epoll integration
        if (child.stdout) |stdout| {
            const fd = stdout.handle;
            const F_GETFL: c_int = 3;
            const F_SETFL: c_int = 4;
            const O_NONBLOCK: c_int = 0x800;
            const flags = std.c.fcntl(fd, F_GETFL, @as(c_int, 0));
            _ = std.c.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        }

        // Send initialize request
        self.sendInitialize(root_path);
    }

    pub fn deinit(self: *LspClient) void {
        // Send shutdown + exit if running
        if (self.process != null and self.initialized) {
            self.sendShutdown();
            self.sendExit();
        }

        // Close pipes and wait/kill process
        if (self.process) |*proc| {
            if (proc.stdin) |f| f.close(self.io);
            proc.stdin = null;
            if (proc.stdout) |f| f.close(self.io);
            proc.stdout = null;
            if (proc.stderr) |f| f.close(self.io);
            proc.stderr = null;
            _ = proc.wait(self.io) catch {
                proc.kill(self.io);
            };
        }
        self.process = null;

        // Free owned memory
        self.freeDiagnostics();
        self.diagnostics.deinit(self.allocator);
        self.freeCompletionItems();
        self.completion_items.deinit(self.allocator);
        if (self.goto_location) |loc| {
            self.allocator.free(loc.uri);
            self.goto_location = null;
        }
        if (self.hover_text) |ht| {
            self.allocator.free(ht);
            self.hover_text = null;
        }
        self.freeFormattingEdits();
        self.formatting_edits.deinit(self.allocator);
        self.freeDocumentSymbols();
        self.document_symbols.deinit(self.allocator);
        self.freeRenameEdits();
        self.rename_edits.deinit(self.allocator);
        self.freeCodeActions();
        self.code_actions.deinit(self.allocator);
        self.freeReferences();
        self.references.deinit(self.allocator);
        self.freeSignature();
        self.msg_buf.deinit(self.allocator);
    }

    pub fn getStdoutFd(self: *const LspClient) ?posix.fd_t {
        if (self.process) |proc| {
            if (proc.stdout) |stdout| {
                return stdout.handle;
            }
        }
        return null;
    }

    // ── Document Sync ───────────────────────────────────────────────

    pub fn didOpen(self: *LspClient, uri: []const u8, language_id: []const u8, content: []const u8) void {
        // Build params JSON with escaped content
        var params_buf: [256]u8 = undefined;
        const params_prefix = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}","languageId":"{s}","version":1,"text":"
        , .{ uri, language_id }) catch return;

        const suffix = "\"}}";

        // Calculate total body: prefix + escaped_content + suffix
        // For the JSON-RPC wrapper we need to build the full body
        self.sendNotificationWithTextContent("textDocument/didOpen", params_prefix, content, suffix);
    }

    pub fn didChange(self: *LspClient, uri: []const u8, content: []const u8) void {
        self.doc_version += 1;
        var params_buf: [256]u8 = undefined;
        const params_prefix = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}","version":{d}}},"contentChanges":[{{"text":"
        , .{ uri, self.doc_version }) catch return;

        const suffix = "\"}]}";

        self.sendNotificationWithTextContent("textDocument/didChange", params_prefix, content, suffix);
    }

    pub fn didClose(self: *LspClient, uri: []const u8) void {
        var params_buf: [1024]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}}}}
        , .{uri}) catch return;
        self.sendNotification("textDocument/didClose", params);
    }

    pub fn didSave(self: *LspClient, uri: []const u8) void {
        var params_buf: [256]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}}}}
        , .{uri}) catch return;
        self.sendNotification("textDocument/didSave", params);
    }

    // ── Requests ────────────────────────────────────────────────────

    pub fn requestCompletion(self: *LspClient, uri: []const u8, line: u32, col: u32) void {
        var params_buf: [512]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}
        , .{ uri, line, col }) catch return;
        self.pending_completion_id = self.next_id;
        self.sendRequest("textDocument/completion", params);
    }

    pub fn requestDefinition(self: *LspClient, uri: []const u8, line: u32, col: u32) void {
        var params_buf: [512]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}
        , .{ uri, line, col }) catch return;
        self.pending_definition_id = self.next_id;
        self.sendRequest("textDocument/definition", params);
    }

    pub fn requestHover(self: *LspClient, uri: []const u8, line: u32, col: u32) void {
        var params_buf: [512]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}
        , .{ uri, line, col }) catch return;
        self.pending_hover_id = self.next_id;
        self.sendRequest("textDocument/hover", params);
    }

    pub fn requestFormatting(self: *LspClient, uri: []const u8) void {
        var params_buf: [1024]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}},"options":{{"tabSize":4,"insertSpaces":true}}}}
        , .{uri}) catch return;
        self.pending_formatting_id = self.next_id;
        self.sendRequest("textDocument/formatting", params);
    }

    pub fn requestDocumentSymbols(self: *LspClient, uri: []const u8) void {
        var params_buf: [1024]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}}}}
        , .{uri}) catch return;
        self.pending_symbols_id = self.next_id;
        self.sendRequest("textDocument/documentSymbol", params);
    }

    pub fn requestRename(self: *LspClient, uri: []const u8, line: u32, col: u32, new_name: []const u8) void {
        var params_buf: [2048]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"newName":"{s}"}}
        , .{ uri, line, col, new_name }) catch return;
        self.pending_rename_id = self.next_id;
        self.sendRequest("textDocument/rename", params);
    }

    pub fn requestCodeAction(self: *LspClient, uri: []const u8, line: u32, col: u32, end_line: u32, end_col: u32) void {
        var params_buf: [2048]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}},"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}},"context":{{"diagnostics":[]}}}}
        , .{ uri, line, col, end_line, end_col }) catch return;
        self.pending_code_action_id = self.next_id;
        self.sendRequest("textDocument/codeAction", params);
    }

    pub fn requestReferences(self: *LspClient, uri: []const u8, line: u32, col: u32) void {
        var params_buf: [1024]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"context":{{"includeDeclaration":true}}}}
        , .{ uri, line, col }) catch return;
        self.pending_references_id = self.next_id;
        self.sendRequest("textDocument/references", params);
    }

    pub fn requestSignatureHelp(self: *LspClient, uri: []const u8, line: u32, col: u32) void {
        var params_buf: [1024]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}
        , .{ uri, line, col }) catch return;
        self.pending_signature_id = self.next_id;
        self.sendRequest("textDocument/signatureHelp", params);
    }

    // ── Message Processing ──────────────────────────────────────────

    pub fn processMessages(self: *LspClient) void {
        const stdout = if (self.process) |proc| proc.stdout orelse return else return;

        // Read available bytes (non-blocking)
        var buffers = [_][]u8{self.read_buf[self.read_pos..]};
        const n = stdout.readStreaming(self.io, &buffers) catch |err| {
            switch (err) {
                error.WouldBlock => return,
                else => return,
            }
        };
        if (n == 0) return;
        self.read_pos += n;

        // Consolidate: if msg_buf has partial data, append new read_buf data
        if (self.msg_buf.items.len > 0 and self.read_pos > 0) {
            self.msg_buf.appendSlice(self.allocator, self.read_buf[0..self.read_pos]) catch return;
            self.read_pos = 0;
        }

        // Process complete messages from buffer
        self.extractMessages();
    }

    fn extractMessages(self: *LspClient) void {
        while (true) {
            if (self.expected_content_length == null) {
                // Look for Content-Length header in read_buf or msg_buf
                const data = if (self.msg_buf.items.len > 0) self.msg_buf.items else self.read_buf[0..self.read_pos];
                const header_end = findHeaderEnd(data) orelse {
                    // Not enough data yet — move read_buf data into msg_buf if needed
                    if (self.msg_buf.items.len == 0 and self.read_pos > 0) {
                        self.msg_buf.appendSlice(self.allocator, self.read_buf[0..self.read_pos]) catch return;
                        self.read_pos = 0;
                    }
                    return;
                };

                // Parse Content-Length from header
                const header = data[0..header_end];
                self.expected_content_length = parseContentLength(header);
                if (self.expected_content_length == null) {
                    // Malformed header, skip
                    self.discardBytes(header_end + 4); // +4 for \r\n\r\n
                    continue;
                }

                // Remove header from buffer
                self.discardBytes(header_end + 4);
            }

            // We have a content length — check if we have enough body data
            const content_len = self.expected_content_length.?;
            const available = if (self.msg_buf.items.len > 0) self.msg_buf.items.len else self.read_pos;

            if (available < content_len) {
                // Need more data — accumulate into msg_buf
                if (self.msg_buf.items.len == 0 and self.read_pos > 0) {
                    self.msg_buf.appendSlice(self.allocator, self.read_buf[0..self.read_pos]) catch return;
                    self.read_pos = 0;
                }
                return;
            }

            // Extract the complete message body
            const body = if (self.msg_buf.items.len > 0) self.msg_buf.items[0..content_len] else self.read_buf[0..content_len];

            // Parse and dispatch
            self.dispatchMessage(body);

            // Remove consumed bytes
            self.discardBytes(content_len);
            self.expected_content_length = null;
        }
    }

    fn discardBytes(self: *LspClient, count: usize) void {
        if (self.msg_buf.items.len > 0) {
            // Shift msg_buf
            if (count >= self.msg_buf.items.len) {
                const msg_len = self.msg_buf.items.len;
                self.msg_buf.clearRetainingCapacity();
                // Also consume any remaining read_buf data
                const remaining = count - msg_len;
                if (remaining > 0 and remaining <= self.read_pos) {
                    const left = self.read_pos - remaining;
                    if (left > 0) {
                        std.mem.copyForwards(u8, self.read_buf[0..left], self.read_buf[remaining..self.read_pos]);
                    }
                    self.read_pos = left;
                }
            } else {
                const remaining = self.msg_buf.items.len - count;
                std.mem.copyForwards(u8, self.msg_buf.items[0..remaining], self.msg_buf.items[count..][0..remaining]);
                self.msg_buf.items.len = remaining;
            }
            // Pull any read_buf data into msg_buf
            if (self.read_pos > 0 and self.msg_buf.items.len > 0) {
                self.msg_buf.appendSlice(self.allocator, self.read_buf[0..self.read_pos]) catch {};
                self.read_pos = 0;
            }
        } else {
            // Data is in read_buf
            if (count <= self.read_pos) {
                const left = self.read_pos - count;
                if (left > 0) {
                    std.mem.copyForwards(u8, self.read_buf[0..left], self.read_buf[count..][0..left]);
                }
                self.read_pos = left;
            } else {
                self.read_pos = 0;
            }
        }
    }

    fn dispatchMessage(self: *LspClient, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        const obj = switch (root) {
            .object => |o| o,
            else => return,
        };

        // Check if this is a notification (no "id") or a response (has "id")
        if (obj.get("method")) |method_val| {
            const method = switch (method_val) {
                .string => |s| s,
                else => return,
            };
            self.handleNotification(method, obj);
        } else if (obj.get("id")) |id_val| {
            const id: u32 = switch (id_val) {
                .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(@as(u64, @bitCast(i))) else return,
                else => return,
            };
            self.handleResponse(id, obj);
        }
    }

    fn handleNotification(self: *LspClient, method: []const u8, params_obj: std.json.ObjectMap) void {
        if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            self.handleDiagnostics(params_obj);
        }
        // Other notifications can be added here
    }

    fn handleResponse(self: *LspClient, id: u32, obj: std.json.ObjectMap) void {
        // Initialize response
        if (id == 0) {
            // id=1 was our initialize request (next_id starts at 1)
        }

        const result = obj.get("result") orelse return;

        // Check if this is the initialize response (id == 0 means our first request used next_id=1 but we start at 1)
        // Actually we track by matching against pending IDs
        if (id == 1 and !self.initialized) {
            // Initialize response — parse server capabilities
            self.parseServerCapabilities(result);
            self.initialized = true;
            // Send initialized notification
            self.sendNotification("initialized", "{}");
            return;
        }

        if (self.pending_completion_id) |cid| {
            if (id == cid) {
                self.pending_completion_id = null;
                self.handleCompletionResponse(result);
                return;
            }
        }

        if (self.pending_definition_id) |did| {
            if (id == did) {
                self.pending_definition_id = null;
                self.handleDefinitionResponse(result);
                return;
            }
        }

        if (self.pending_hover_id) |hid| {
            if (id == hid) {
                self.pending_hover_id = null;
                self.handleHoverResponse(result);
                return;
            }
        }

        if (self.pending_formatting_id) |fid| {
            if (id == fid) {
                self.pending_formatting_id = null;
                self.handleFormattingResponse(result);
                return;
            }
        }

        if (self.pending_symbols_id) |sid| {
            if (id == sid) {
                self.pending_symbols_id = null;
                self.handleDocumentSymbolResponse(result);
                return;
            }
        }

        if (self.pending_rename_id) |rid| {
            if (id == rid) {
                self.pending_rename_id = null;
                self.handleRenameResponse(result);
                return;
            }
        }

        if (self.pending_code_action_id) |caid| {
            if (id == caid) {
                self.pending_code_action_id = null;
                self.handleCodeActionResponse(result);
                return;
            }
        }

        if (self.pending_references_id) |refid| {
            if (id == refid) {
                self.pending_references_id = null;
                self.handleReferencesResponse(result);
                return;
            }
        }

        if (self.pending_signature_id) |sid| {
            if (id == sid) {
                self.pending_signature_id = null;
                self.handleSignatureHelpResponse(result);
                return;
            }
        }
    }

    fn parseServerCapabilities(self: *LspClient, result: std.json.Value) void {
        const obj = switch (result) {
            .object => |o| o,
            else => return,
        };

        const caps_val = obj.get("capabilities") orelse return;
        const caps = switch (caps_val) {
            .object => |o| o,
            else => return,
        };

        if (caps.get("completionProvider")) |_| {
            self.server_capabilities.has_completion = true;
        }
        if (caps.get("definitionProvider")) |dp| {
            self.server_capabilities.has_definition = switch (dp) {
                .bool => |b| b,
                else => true, // Object means it has options = supported
            };
        }
        if (caps.get("hoverProvider")) |hp| {
            self.server_capabilities.has_hover = switch (hp) {
                .bool => |b| b,
                else => true,
            };
        }
        if (caps.get("documentFormattingProvider")) |fp| {
            self.server_capabilities.has_formatting = switch (fp) {
                .bool => |b| b,
                else => true,
            };
        }
        if (caps.get("documentSymbolProvider")) |sp| {
            self.server_capabilities.has_document_symbols = switch (sp) {
                .bool => |b| b,
                else => true,
            };
        }
        if (caps.get("renameProvider")) |rp| {
            self.server_capabilities.has_rename = switch (rp) {
                .bool => |b| b,
                else => true,
            };
        }
        if (caps.get("codeActionProvider")) |cap| {
            self.server_capabilities.has_code_action = switch (cap) {
                .bool => |b| b,
                else => true,
            };
        }
        if (caps.get("referencesProvider")) |refp| {
            self.server_capabilities.has_references = switch (refp) {
                .bool => |b| b,
                else => true,
            };
        }
        if (caps.get("signatureHelpProvider")) |_| {
            self.server_capabilities.has_signature_help = true;
        }
    }

    fn handleDiagnostics(self: *LspClient, obj: std.json.ObjectMap) void {
        const params_val = obj.get("params") orelse return;
        const params = switch (params_val) {
            .object => |o| o,
            else => return,
        };

        const diags_val = params.get("diagnostics") orelse return;
        const diags = switch (diags_val) {
            .array => |a| a,
            else => return,
        };

        // Free old diagnostics
        self.freeDiagnostics();

        for (diags.items) |diag_val| {
            const diag = switch (diag_val) {
                .object => |o| o,
                else => continue,
            };

            const msg_str = blk: {
                const v = diag.get("message") orelse continue;
                break :blk switch (v) {
                    .string => |s| s,
                    else => continue,
                };
            };

            const range_val = diag.get("range") orelse continue;
            const range = switch (range_val) {
                .object => |o| o,
                else => continue,
            };

            const start_val = range.get("start") orelse continue;
            const range_start = switch (start_val) {
                .object => |o| o,
                else => continue,
            };

            const end_val = range.get("end") orelse continue;
            const range_end = switch (end_val) {
                .object => |o| o,
                else => continue,
            };

            const line = jsonGetU32(range_start, "line") orelse continue;
            const col_start = jsonGetU32(range_start, "character") orelse 0;
            const col_end = jsonGetU32(range_end, "character") orelse col_start;

            const severity_int = jsonGetU32(diag, "severity") orelse 1;
            const severity: Diagnostic.Severity = switch (severity_int) {
                1 => .err,
                2 => .warning,
                3 => .info,
                4 => .hint,
                else => .err,
            };

            const owned_msg = self.allocator.dupe(u8, msg_str) catch continue;
            self.diagnostics.append(self.allocator, .{
                .line = line,
                .col_start = col_start,
                .col_end = col_end,
                .severity = severity,
                .message = owned_msg,
            }) catch {
                self.allocator.free(owned_msg);
                continue;
            };
        }
    }

    fn handleCompletionResponse(self: *LspClient, result: std.json.Value) void {
        self.freeCompletionItems();
        self.has_completion = true;

        // Result can be an array or an object with "items" array
        const items = switch (result) {
            .array => |a| a.items,
            .object => |o| blk: {
                const items_val = o.get("items") orelse return;
                break :blk switch (items_val) {
                    .array => |a| a.items,
                    else => return,
                };
            },
            else => return,
        };

        for (items) |item_val| {
            const item = switch (item_val) {
                .object => |o| o,
                else => continue,
            };

            const label_str = blk: {
                const v = item.get("label") orelse continue;
                break :blk switch (v) {
                    .string => |s| s,
                    else => continue,
                };
            };

            const detail_str: ?[]const u8 = blk: {
                const v = item.get("detail") orelse break :blk null;
                break :blk switch (v) {
                    .string => |s| s,
                    else => null,
                };
            };

            const kind: u8 = @intCast(jsonGetU32(item, "kind") orelse 0);

            const owned_label = self.allocator.dupe(u8, label_str) catch continue;
            const owned_detail: ?[]u8 = if (detail_str) |d| self.allocator.dupe(u8, d) catch null else null;

            self.completion_items.append(self.allocator, .{
                .label = owned_label,
                .detail = owned_detail,
                .kind = kind,
            }) catch {
                self.allocator.free(owned_label);
                if (owned_detail) |d| self.allocator.free(d);
                continue;
            };
        }
    }

    fn handleDefinitionResponse(self: *LspClient, result: std.json.Value) void {
        if (self.goto_location) |loc| {
            self.allocator.free(loc.uri);
            self.goto_location = null;
        }
        self.has_goto = true;

        // Result can be a Location, Location[], or LocationLink[]
        const loc_obj = switch (result) {
            .object => |o| o, // Single Location
            .array => |a| blk: {
                if (a.items.len == 0) return;
                break :blk switch (a.items[0]) {
                    .object => |o| o,
                    else => return,
                };
            },
            else => return,
        };

        // Handle both Location and LocationLink
        const uri_str = blk: {
            // LocationLink has "targetUri", Location has "uri"
            if (loc_obj.get("uri")) |v| {
                break :blk switch (v) {
                    .string => |s| s,
                    else => return,
                };
            }
            if (loc_obj.get("targetUri")) |v| {
                break :blk switch (v) {
                    .string => |s| s,
                    else => return,
                };
            }
            return;
        };

        // Get range — "range" for Location, "targetRange" for LocationLink
        const range_key = if (loc_obj.get("targetRange") != null) "targetRange" else "range";
        const range_val = loc_obj.get(range_key) orelse return;
        const range = switch (range_val) {
            .object => |o| o,
            else => return,
        };

        const start_val = range.get("start") orelse return;
        const range_start = switch (start_val) {
            .object => |o| o,
            else => return,
        };

        const line = jsonGetU32(range_start, "line") orelse return;
        const col = jsonGetU32(range_start, "character") orelse 0;

        const owned_uri = self.allocator.dupe(u8, uri_str) catch return;
        self.goto_location = .{
            .uri = owned_uri,
            .line = line,
            .col = col,
        };
    }

    fn handleHoverResponse(self: *LspClient, result: std.json.Value) void {
        if (self.hover_text) |ht| {
            self.allocator.free(ht);
            self.hover_text = null;
        }
        self.has_hover = true;

        const obj = switch (result) {
            .object => |o| o,
            .null => return,
            else => return,
        };

        // "contents" can be MarkedString, MarkedString[], or MarkupContent
        const contents_val = obj.get("contents") orelse return;
        switch (contents_val) {
            .string => |s| {
                self.hover_text = self.allocator.dupe(u8, s) catch null;
            },
            .object => |o| {
                // MarkupContent: { kind: string, value: string }
                if (o.get("value")) |v| {
                    switch (v) {
                        .string => |s| {
                            self.hover_text = self.allocator.dupe(u8, s) catch null;
                        },
                        else => {},
                    }
                }
            },
            .array => |a| {
                // Array of MarkedString — concatenate
                var total_len: usize = 0;
                for (a.items) |item| {
                    switch (item) {
                        .string => |s| total_len += s.len + 1, // +1 for newline
                        .object => |o| {
                            if (o.get("value")) |v| {
                                switch (v) {
                                    .string => |s| total_len += s.len + 1,
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }
                if (total_len == 0) return;
                const buf = self.allocator.alloc(u8, total_len) catch return;
                var pos: usize = 0;
                for (a.items) |item| {
                    const s: []const u8 = switch (item) {
                        .string => |s| s,
                        .object => |o| blk: {
                            const v = o.get("value") orelse continue;
                            break :blk switch (v) {
                                .string => |s| s,
                                else => continue,
                            };
                        },
                        else => continue,
                    };
                    @memcpy(buf[pos..][0..s.len], s);
                    pos += s.len;
                    if (pos < buf.len) {
                        buf[pos] = '\n';
                        pos += 1;
                    }
                }
                self.hover_text = buf[0..pos];
            },
            else => {},
        }
    }

    fn handleFormattingResponse(self: *LspClient, result: std.json.Value) void {
        self.freeFormattingEdits();
        self.has_formatting = true;

        // Result is TextEdit[] or null
        const edits = switch (result) {
            .array => |a| a.items,
            .null => return,
            else => return,
        };

        for (edits) |edit_val| {
            const edit = switch (edit_val) {
                .object => |o| o,
                else => continue,
            };

            const new_text_str = blk: {
                const v = edit.get("newText") orelse continue;
                break :blk switch (v) {
                    .string => |s| s,
                    else => continue,
                };
            };

            const range_val = edit.get("range") orelse continue;
            const range = switch (range_val) {
                .object => |o| o,
                else => continue,
            };

            const start_val = range.get("start") orelse continue;
            const range_start = switch (start_val) {
                .object => |o| o,
                else => continue,
            };

            const end_val = range.get("end") orelse continue;
            const range_end = switch (end_val) {
                .object => |o| o,
                else => continue,
            };

            const start_line = jsonGetU32(range_start, "line") orelse continue;
            const start_col = jsonGetU32(range_start, "character") orelse 0;
            const end_line = jsonGetU32(range_end, "line") orelse continue;
            const end_col = jsonGetU32(range_end, "character") orelse 0;

            const owned_text = self.allocator.dupe(u8, new_text_str) catch continue;
            self.formatting_edits.append(self.allocator, .{
                .start_line = start_line,
                .start_col = start_col,
                .end_line = end_line,
                .end_col = end_col,
                .new_text = owned_text,
            }) catch {
                self.allocator.free(owned_text);
                continue;
            };
        }
    }

    fn handleDocumentSymbolResponse(self: *LspClient, result: std.json.Value) void {
        self.freeDocumentSymbols();
        self.has_symbols = true;

        // Result can be DocumentSymbol[] or SymbolInformation[]
        const items = switch (result) {
            .array => |a| a.items,
            .null => return,
            else => return,
        };

        for (items) |item_val| {
            const item = switch (item_val) {
                .object => |o| o,
                else => continue,
            };

            const name_str = blk: {
                const v = item.get("name") orelse continue;
                break :blk switch (v) {
                    .string => |s| s,
                    else => continue,
                };
            };

            const kind: u8 = @intCast(jsonGetU32(item, "kind") orelse 0);

            // DocumentSymbol has "range", SymbolInformation has "location"
            const line: u32 = blk: {
                if (item.get("range")) |rv| {
                    const range = switch (rv) {
                        .object => |o| o,
                        else => continue,
                    };
                    const start_val = range.get("start") orelse continue;
                    const rs = switch (start_val) {
                        .object => |o| o,
                        else => continue,
                    };
                    break :blk jsonGetU32(rs, "line") orelse continue;
                } else if (item.get("location")) |lv| {
                    const loc = switch (lv) {
                        .object => |o| o,
                        else => continue,
                    };
                    const range_val = loc.get("range") orelse continue;
                    const range = switch (range_val) {
                        .object => |o| o,
                        else => continue,
                    };
                    const start_val = range.get("start") orelse continue;
                    const rs = switch (start_val) {
                        .object => |o| o,
                        else => continue,
                    };
                    break :blk jsonGetU32(rs, "line") orelse continue;
                } else continue;
            };

            const owned_name = self.allocator.dupe(u8, name_str) catch continue;
            self.document_symbols.append(self.allocator, .{
                .name = owned_name,
                .kind = kind,
                .line = line,
            }) catch {
                self.allocator.free(owned_name);
                continue;
            };

            // Also recurse into children (DocumentSymbol nesting)
            if (item.get("children")) |cv| {
                const children = switch (cv) {
                    .array => |a| a.items,
                    else => continue,
                };
                for (children) |child_val| {
                    const child = switch (child_val) {
                        .object => |o| o,
                        else => continue,
                    };
                    const cname_str = cblk: {
                        const v = child.get("name") orelse continue;
                        break :cblk switch (v) {
                            .string => |s| s,
                            else => continue,
                        };
                    };
                    const ckind: u8 = @intCast(jsonGetU32(child, "kind") orelse 0);
                    const cline: u32 = cblk: {
                        const crv = child.get("range") orelse continue;
                        const crange = switch (crv) {
                            .object => |o| o,
                            else => continue,
                        };
                        const csv = crange.get("start") orelse continue;
                        const crs = switch (csv) {
                            .object => |o| o,
                            else => continue,
                        };
                        break :cblk jsonGetU32(crs, "line") orelse continue;
                    };
                    const owned_cname = self.allocator.dupe(u8, cname_str) catch continue;
                    self.document_symbols.append(self.allocator, .{
                        .name = owned_cname,
                        .kind = ckind,
                        .line = cline,
                    }) catch {
                        self.allocator.free(owned_cname);
                        continue;
                    };
                }
            }
        }
    }

    fn handleRenameResponse(self: *LspClient, result: std.json.Value) void {
        self.freeRenameEdits();
        self.has_rename = true;

        // Result is a WorkspaceEdit: { "changes": { "uri": [TextEdit, ...], ... } }
        // or { "documentChanges": [...] }
        const obj = switch (result) {
            .object => |o| o,
            .null => return,
            else => return,
        };

        // Handle "changes" format: { "file:///path": [TextEdit, ...] }
        if (obj.get("changes")) |changes_val| {
            const changes = switch (changes_val) {
                .object => |o| o,
                else => return,
            };
            var changes_it = changes.iterator();
            while (changes_it.next()) |entry| {
                const uri_str = entry.key_ptr.*;
                const edits_val = entry.value_ptr.*;
                const edits_arr = switch (edits_val) {
                    .array => |a| a.items,
                    else => continue,
                };

                const owned_uri = self.allocator.dupe(u8, uri_str) catch continue;
                var edit_list: std.ArrayList(FormattingEdit) = .empty;

                for (edits_arr) |edit_val| {
                    const edit = switch (edit_val) {
                        .object => |o| o,
                        else => continue,
                    };
                    if (parseTextEdit(self.allocator, edit)) |fe| {
                        edit_list.append(self.allocator, fe) catch {
                            self.allocator.free(fe.new_text);
                            continue;
                        };
                    }
                }

                self.rename_edits.append(self.allocator, .{
                    .uri = owned_uri,
                    .edits = edit_list,
                }) catch {
                    self.allocator.free(owned_uri);
                    for (edit_list.items) |e| self.allocator.free(e.new_text);
                    edit_list.deinit(self.allocator);
                    continue;
                };
            }
        }
    }

    fn handleCodeActionResponse(self: *LspClient, result: std.json.Value) void {
        self.freeCodeActions();
        self.has_code_actions = true;

        // Result is (Command | CodeAction)[] or null
        const items = switch (result) {
            .array => |a| a.items,
            .null => return,
            else => return,
        };

        for (items) |item_val| {
            const item = switch (item_val) {
                .object => |o| o,
                else => continue,
            };

            const title_str = blk: {
                const v = item.get("title") orelse continue;
                break :blk switch (v) {
                    .string => |s| s,
                    else => continue,
                };
            };

            const owned_title = self.allocator.dupe(u8, title_str) catch continue;
            var edit_list: std.ArrayList(FormattingEdit) = .empty;
            var edit_uri: ?[]u8 = null;

            // Parse workspace edit if present
            if (item.get("edit")) |edit_val| {
                const edit_obj = switch (edit_val) {
                    .object => |o| o,
                    else => null,
                };
                if (edit_obj) |eo| {
                    if (eo.get("changes")) |changes_val| {
                        const changes = switch (changes_val) {
                            .object => |o| o,
                            else => null,
                        };
                        if (changes) |ch| {
                            var ch_it = ch.iterator();
                            // Take first file's edits for simplicity
                            if (ch_it.next()) |entry| {
                                edit_uri = self.allocator.dupe(u8, entry.key_ptr.*) catch null;
                                const edits_arr = switch (entry.value_ptr.*) {
                                    .array => |a| a.items,
                                    else => &[_]std.json.Value{},
                                };
                                for (edits_arr) |ev| {
                                    const eo2 = switch (ev) {
                                        .object => |o| o,
                                        else => continue,
                                    };
                                    if (parseTextEdit(self.allocator, eo2)) |fe| {
                                        edit_list.append(self.allocator, fe) catch {
                                            self.allocator.free(fe.new_text);
                                            continue;
                                        };
                                    }
                                }
                            }
                        }
                    }
                }
            }

            self.code_actions.append(self.allocator, .{
                .title = owned_title,
                .edits = edit_list,
                .edit_uri = edit_uri,
            }) catch {
                self.allocator.free(owned_title);
                if (edit_uri) |eu| self.allocator.free(eu);
                for (edit_list.items) |e| self.allocator.free(e.new_text);
                edit_list.deinit(self.allocator);
                continue;
            };
        }
    }

    fn handleReferencesResponse(self: *LspClient, result: std.json.Value) void {
        self.freeReferences();
        self.has_references = true;

        // Result is Location[] or null
        const items = switch (result) {
            .array => |a| a.items,
            .null => return,
            else => return,
        };

        for (items) |item_val| {
            const loc_obj = switch (item_val) {
                .object => |o| o,
                else => continue,
            };

            const uri_str = blk: {
                const v = loc_obj.get("uri") orelse continue;
                break :blk switch (v) {
                    .string => |s| s,
                    else => continue,
                };
            };

            const range_val = loc_obj.get("range") orelse continue;
            const range = switch (range_val) {
                .object => |o| o,
                else => continue,
            };

            const start_val = range.get("start") orelse continue;
            const range_start = switch (start_val) {
                .object => |o| o,
                else => continue,
            };

            const line = jsonGetU32(range_start, "line") orelse continue;
            const col = jsonGetU32(range_start, "character") orelse 0;

            const owned_uri = self.allocator.dupe(u8, uri_str) catch continue;
            self.references.append(self.allocator, .{
                .uri = owned_uri,
                .line = line,
                .col = col,
            }) catch {
                self.allocator.free(owned_uri);
                continue;
            };
        }
    }

    // ── JSON-RPC Transport ──────────────────────────────────────────

    fn sendRequest(self: *LspClient, method: []const u8, params: []const u8) void {
        const id = self.next_id;
        self.next_id += 1;

        var body_buf: [8192]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
        , .{ id, method, params }) catch return;

        self.writeMessage(body);
    }

    fn sendNotification(self: *LspClient, method: []const u8, params: []const u8) void {
        var body_buf: [8192]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"jsonrpc":"2.0","method":"{s}","params":{s}}}
        , .{ method, params }) catch return;

        self.writeMessage(body);
    }

    /// Send a notification where the params contain a "text" field with file content
    /// that needs JSON string escaping. This avoids pre-escaping large file contents.
    fn sendNotificationWithTextContent(
        self: *LspClient,
        method: []const u8,
        params_prefix: []const u8,
        text_content: []const u8,
        params_suffix: []const u8,
    ) void {
        // Build notification JSON wrapper
        var wrapper_prefix_buf: [512]u8 = undefined;
        const wrapper_prefix = std.fmt.bufPrint(&wrapper_prefix_buf,
            \\{{"jsonrpc":"2.0","method":"{s}","params":
        , .{method}) catch return;
        const wrapper_suffix = "}";

        // Calculate escaped text length
        const escaped_len = jsonEscapedLen(text_content);

        // Total body length
        const body_len = wrapper_prefix.len + params_prefix.len + escaped_len + params_suffix.len + wrapper_suffix.len;

        // Write header
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body_len}) catch return;

        const stdin = if (self.process) |proc| proc.stdin orelse return else return;

        stdin.writeStreamingAll(self.io, header) catch return;
        stdin.writeStreamingAll(self.io, wrapper_prefix) catch return;
        stdin.writeStreamingAll(self.io, params_prefix) catch return;
        writeJsonEscaped(stdin, self.io, text_content);
        stdin.writeStreamingAll(self.io, params_suffix) catch return;
        stdin.writeStreamingAll(self.io, wrapper_suffix) catch return;
    }

    fn writeMessage(self: *LspClient, body: []const u8) void {
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;

        const stdin = if (self.process) |proc| proc.stdin orelse return else return;
        stdin.writeStreamingAll(self.io, header) catch return;
        stdin.writeStreamingAll(self.io, body) catch return;
    }

    fn sendInitialize(self: *LspClient, root_path: []const u8) void {
        var uri_buf: [4096]u8 = undefined;
        const root_uri = formatUri(root_path, &uri_buf);

        var params_buf: [4096]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf,
            \\{{"processId":{d},"rootUri":"{s}","capabilities":{{"textDocument":{{"completion":{{"completionItem":{{"snippetSupport":false}}}},"hover":{{"contentFormat":["plaintext"]}},"publishDiagnostics":{{"relatedInformation":false}},"synchronization":{{"didSave":true}},"definition":{{}}}}}}}}
        , .{ std.os.linux.getpid(), root_uri }) catch return;

        // Use id=1 (next_id starts at 1, will be incremented)
        self.sendRequest("initialize", params);
    }

    fn sendShutdown(self: *LspClient) void {
        self.sendRequest("shutdown", "null");
    }

    fn sendExit(self: *LspClient) void {
        self.sendNotification("exit", "null");
    }

    // ── Helpers ─────────────────────────────────────────────────────

    fn freeDiagnostics(self: *LspClient) void {
        for (self.diagnostics.items) |diag| {
            self.allocator.free(diag.message);
        }
        self.diagnostics.clearRetainingCapacity();
    }

    fn freeCompletionItems(self: *LspClient) void {
        for (self.completion_items.items) |item| {
            self.allocator.free(item.label);
            if (item.detail) |d| self.allocator.free(d);
        }
        self.completion_items.clearRetainingCapacity();
    }

    fn handleSignatureHelpResponse(self: *LspClient, result: std.json.Value) void {
        self.freeSignature();
        self.has_signature = true;

        const obj = switch (result) {
            .object => |o| o,
            .null => return,
            else => return,
        };

        const sigs_val = obj.get("signatures") orelse return;
        const sigs = switch (sigs_val) {
            .array => |a| a,
            else => return,
        };

        if (sigs.items.len == 0) return;

        // Use activeSignature if present, default to 0
        const active_sig_idx: usize = blk: {
            const v = jsonGetU32(obj, "activeSignature") orelse break :blk 0;
            break :blk @min(@as(usize, v), sigs.items.len - 1);
        };

        const sig_obj = switch (sigs.items[active_sig_idx]) {
            .object => |o| o,
            else => return,
        };

        const label_str = blk: {
            const v = sig_obj.get("label") orelse return;
            break :blk switch (v) {
                .string => |s| s,
                else => return,
            };
        };

        // Get active parameter: use response-level activeParameter, fallback to signature-level
        const active_param = jsonGetU32(obj, "activeParameter") orelse
            jsonGetU32(sig_obj, "activeParameter") orelse 0;

        // Try to find parameter label offsets for highlighting
        var param_offsets: ?SignatureInfo.ParamRange = null;
        if (sig_obj.get("parameters")) |params_val| {
            const params = switch (params_val) {
                .array => |a| a,
                else => null,
            };
            if (params) |p| {
                if (active_param < p.items.len) {
                    const param_obj = switch (p.items[active_param]) {
                        .object => |o| o,
                        else => null,
                    };
                    if (param_obj) |po| {
                        if (po.get("label")) |plabel| {
                            switch (plabel) {
                                .array => |arr| {
                                    // [start, end] offsets
                                    if (arr.items.len >= 2) {
                                        const s = switch (arr.items[0]) {
                                            .integer => |i| if (i >= 0) @as(u32, @intCast(@as(u64, @bitCast(i)))) else null,
                                            else => null,
                                        };
                                        const e = switch (arr.items[1]) {
                                            .integer => |i| if (i >= 0) @as(u32, @intCast(@as(u64, @bitCast(i)))) else null,
                                            else => null,
                                        };
                                        if (s != null and e != null) {
                                            param_offsets = .{ .start = s.?, .end = e.? };
                                        }
                                    }
                                },
                                .string => |ps| {
                                    // String label: find it in the signature label
                                    if (std.mem.indexOf(u8, label_str, ps)) |idx| {
                                        param_offsets = .{
                                            .start = @intCast(idx),
                                            .end = @intCast(idx + ps.len),
                                        };
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            }
        }

        const owned_label = self.allocator.dupe(u8, label_str) catch return;
        self.signature = .{
            .label = owned_label,
            .active_param = active_param,
            .param_offsets = param_offsets,
        };
    }

    fn freeSignature(self: *LspClient) void {
        if (self.signature) |sig| {
            self.allocator.free(sig.label);
            self.signature = null;
        }
    }

    fn freeFormattingEdits(self: *LspClient) void {
        for (self.formatting_edits.items) |edit| {
            self.allocator.free(edit.new_text);
        }
        self.formatting_edits.clearRetainingCapacity();
    }

    fn freeDocumentSymbols(self: *LspClient) void {
        for (self.document_symbols.items) |sym| {
            self.allocator.free(sym.name);
        }
        self.document_symbols.clearRetainingCapacity();
    }

    fn freeRenameEdits(self: *LspClient) void {
        for (self.rename_edits.items) |*re| {
            self.allocator.free(re.uri);
            for (re.edits.items) |e| self.allocator.free(e.new_text);
            re.edits.deinit(self.allocator);
        }
        self.rename_edits.clearRetainingCapacity();
    }

    fn freeCodeActions(self: *LspClient) void {
        for (self.code_actions.items) |*ca| {
            self.allocator.free(ca.title);
            if (ca.edit_uri) |eu| self.allocator.free(eu);
            for (ca.edits.items) |e| self.allocator.free(e.new_text);
            ca.edits.deinit(self.allocator);
        }
        self.code_actions.clearRetainingCapacity();
    }

    fn freeReferences(self: *LspClient) void {
        for (self.references.items) |ref| {
            self.allocator.free(ref.uri);
        }
        self.references.clearRetainingCapacity();
    }
};

// ── Helpers ────────────────────────────────────────────────────────

fn parseTextEdit(allocator: std.mem.Allocator, edit: std.json.ObjectMap) ?FormattingEdit {
    const new_text_str = blk: {
        const v = edit.get("newText") orelse return null;
        break :blk switch (v) {
            .string => |s| s,
            else => return null,
        };
    };

    const range_val = edit.get("range") orelse return null;
    const range = switch (range_val) {
        .object => |o| o,
        else => return null,
    };

    const start_val = range.get("start") orelse return null;
    const range_start = switch (start_val) {
        .object => |o| o,
        else => return null,
    };

    const end_val = range.get("end") orelse return null;
    const range_end = switch (end_val) {
        .object => |o| o,
        else => return null,
    };

    const start_line = jsonGetU32(range_start, "line") orelse return null;
    const start_col = jsonGetU32(range_start, "character") orelse 0;
    const end_line = jsonGetU32(range_end, "line") orelse return null;
    const end_col = jsonGetU32(range_end, "character") orelse 0;

    const owned_text = allocator.dupe(u8, new_text_str) catch return null;
    return .{
        .start_line = start_line,
        .start_col = start_col,
        .end_line = end_line,
        .end_col = end_col,
        .new_text = owned_text,
    };
}

// ── Free Functions ──────────────────────────────────────────────────

pub fn languageId(file_path: []const u8) ?[]const u8 {
    const ext = getExt(file_path) orelse return null;
    if (eql(ext, "zig")) return "zig";
    if (eql(ext, "c") or eql(ext, "h")) return "c";
    if (eql(ext, "cpp") or eql(ext, "hpp") or eql(ext, "cc") or eql(ext, "cxx")) return "cpp";
    if (eql(ext, "py")) return "python";
    if (eql(ext, "rs")) return "rust";
    if (eql(ext, "js") or eql(ext, "jsx")) return "javascript";
    if (eql(ext, "ts") or eql(ext, "tsx")) return "typescript";
    if (eql(ext, "go")) return "go";
    if (eql(ext, "sol")) return "solidity";
    return null;
}

pub fn serverCommand(file_path: []const u8) ?[]const u8 {
    const ext = getExt(file_path) orelse return null;
    if (eql(ext, "zig")) return "zls";
    if (eql(ext, "c") or eql(ext, "h") or eql(ext, "cpp") or eql(ext, "hpp") or eql(ext, "cc") or eql(ext, "cxx")) return "clangd";
    if (eql(ext, "py")) return "pylsp";
    if (eql(ext, "rs")) return "rust-analyzer";
    if (eql(ext, "go")) return "gopls";
    if (eql(ext, "js") or eql(ext, "jsx") or eql(ext, "ts") or eql(ext, "tsx")) return "typescript-language-server --stdio";
    return null;
}

pub fn formatUri(path: []const u8, buf: []u8) []const u8 {
    const prefix = "file://";
    if (buf.len < prefix.len + path.len) return "";
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..path.len], path);
    return buf[0 .. prefix.len + path.len];
}

pub fn uriToPath(uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) {
        return uri[prefix.len..];
    }
    return null;
}

// ── Internal Helpers ────────────────────────────────────────────────

fn getExt(path: []const u8) ?[]const u8 {
    // Find last '.' that comes after the last '/'
    var last_dot: ?usize = null;
    var last_slash: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') last_slash = i;
        if (c == '.') last_dot = i;
    }
    const dot = last_dot orelse return null;
    // Dot must be after the last slash
    if (last_slash) |s| {
        if (dot <= s) return null;
        // Hidden file: dot is first char of filename (e.g. ".gitignore")
        if (dot == s + 1) return null;
    } else {
        // No slash: dot at position 0 = hidden file
        if (dot == 0) return null;
    }
    if (dot + 1 >= path.len) return null;
    return path[dot + 1 ..];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn findHeaderEnd(data: []const u8) ?usize {
    // Find "\r\n\r\n" — returns index of the start of this sequence
    if (data.len < 4) return null;
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n') {
            return i;
        }
    }
    return null;
}

fn parseContentLength(header: []const u8) ?usize {
    // Look for "Content-Length: " in header
    const prefix = "Content-Length: ";
    const idx = std.mem.indexOf(u8, header, prefix) orelse return null;
    const start = idx + prefix.len;
    // Find end of number (before \r or end of header)
    var end = start;
    while (end < header.len and header[end] >= '0' and header[end] <= '9') {
        end += 1;
    }
    if (end == start) return null;
    return std.fmt.parseInt(usize, header[start..end], 10) catch null;
}

fn jsonGetU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(@as(u64, @bitCast(i))) else null,
        else => null,
    };
}

fn jsonEscapedLen(s: []const u8) usize {
    var len: usize = 0;
    for (s) |c| {
        len += switch (c) {
            '"', '\\' => 2,
            '\n' => 2, // \n
            '\r' => 2, // \r
            '\t' => 2, // \t
            else => if (c < 0x20) @as(usize, 6) else @as(usize, 1), // \u00XX
        };
    }
    return len;
}

fn writeJsonEscaped(file: std.Io.File, io: std.Io, s: []const u8) void {
    var write_start: usize = 0;
    for (s, 0..) |c, i| {
        const escape: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (c < 0x20) blk: {
                // Flush preceding clean segment
                if (i > write_start) {
                    file.writeStreamingAll(io,s[write_start..i]) catch return;
                }
                // Write \u00XX escape
                var esc_buf: [6]u8 = undefined;
                const hex = "0123456789abcdef";
                esc_buf[0] = '\\';
                esc_buf[1] = 'u';
                esc_buf[2] = '0';
                esc_buf[3] = '0';
                esc_buf[4] = hex[c >> 4];
                esc_buf[5] = hex[c & 0xf];
                file.writeStreamingAll(io,&esc_buf) catch return;
                write_start = i + 1;
                break :blk null;
            } else null,
        };
        if (escape) |esc| {
            if (i > write_start) {
                file.writeStreamingAll(io,s[write_start..i]) catch return;
            }
            file.writeStreamingAll(io,esc) catch return;
            write_start = i + 1;
        }
    }
    // Flush remaining
    if (write_start < s.len) {
        file.writeStreamingAll(io,s[write_start..]) catch return;
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "languageId" {
    const testing = std.testing;
    try testing.expectEqualStrings("zig", languageId("/foo/bar.zig").?);
    try testing.expectEqualStrings("c", languageId("test.c").?);
    try testing.expectEqualStrings("python", languageId("/a/b/c.py").?);
    try testing.expect(languageId("noext") == null);
}

test "serverCommand" {
    const testing = std.testing;
    try testing.expectEqualStrings("zls", serverCommand("main.zig").?);
    try testing.expectEqualStrings("clangd", serverCommand("foo.c").?);
    try testing.expect(serverCommand("unknown.xyz") == null);
}

test "formatUri" {
    var buf: [256]u8 = undefined;
    const uri = formatUri("/home/user/file.zig", &buf);
    try std.testing.expectEqualStrings("file:///home/user/file.zig", uri);
}

test "uriToPath" {
    const path = uriToPath("file:///home/user/file.zig").?;
    try std.testing.expectEqualStrings("/home/user/file.zig", path);
    try std.testing.expect(uriToPath("http://foo") == null);
}

test "parseContentLength" {
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength("Content-Length: 42\r\n"));
    try std.testing.expectEqual(@as(?usize, 1234), parseContentLength("Content-Type: text\r\nContent-Length: 1234\r\n"));
    try std.testing.expect(parseContentLength("no header") == null);
}

test "findHeaderEnd" {
    // "Content-Length: 5" is 17 chars, so \r\n\r\n starts at index 17
    try std.testing.expectEqual(@as(?usize, 17), findHeaderEnd("Content-Length: 5\r\n\r\n{\"a\":1}"));
    try std.testing.expect(findHeaderEnd("incomplete\r\n") == null);
}

test "jsonEscapedLen" {
    try std.testing.expectEqual(@as(usize, 5), jsonEscapedLen("hello"));
    try std.testing.expectEqual(@as(usize, 4), jsonEscapedLen("a\\b"));
    try std.testing.expectEqual(@as(usize, 4), jsonEscapedLen("a\nb"));
}

test "init and deinit" {
    var client = LspClient.init(std.testing.allocator);
    defer client.deinit();
    try std.testing.expect(!client.initialized);
    try std.testing.expect(client.process == null);
}

test {
    // Force analysis of all declarations
    std.testing.refAllDecls(@This());
}
