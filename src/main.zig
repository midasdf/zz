const std = @import("std");
const Window = @import("ui/window.zig").Window;
const window_mod = @import("ui/window.zig");
const FontFace = @import("ui/font.zig").FontFace;
const render_mod = @import("ui/render.zig");
const Renderer = render_mod.Renderer;
const EditorView = @import("editor/view.zig").EditorView;
const PieceTable = @import("editor/buffer.zig").PieceTable;
const keymap = @import("input/keymap.zig");
const Overlay = @import("ui/overlay.zig").Overlay;
const fuzzy = @import("core/fuzzy.zig");
const file_walker = @import("core/file_walker.zig");

const EditorMode = enum {
    normal,
    command_palette,
    file_finder,
    search,
    goto_line,
};

const command_list = [_][]const u8{
    "File: Save",
    "File: Open",
    "Edit: Undo",
    "Edit: Redo",
    "Edit: Select All",
    "Edit: Copy",
    "Edit: Cut",
    "Edit: Paste",
    "View: Go to Line",
    "View: Find",
    "Editor: Close",
};

const font_path = "/usr/share/fonts/PlemolJP/PlemolJPConsoleNF-Regular.ttf";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Load file or start empty
    var content: []const u8 = "";
    var owned_content: ?[]u8 = null;
    var file_path: ?[]const u8 = null;
    if (args.len > 1) {
        file_path = args[1];
        owned_content = std.fs.cwd().readFileAlloc(allocator, args[1], 100 * 1024 * 1024) catch null;
        if (owned_content) |c| content = c;
    }
    defer if (owned_content) |c| allocator.free(c);

    // Init window
    var win = try Window.init(allocator, 900, 640, "zz");
    defer win.deinit();

    // Init font
    var font = try FontFace.init(allocator, font_path, 16);
    defer font.deinit();

    // Init editor view
    var editor = try EditorView.init(allocator, content);
    defer editor.deinit();
    if (file_path) |p| {
        editor.file_path = try allocator.dupe(u8, p);
    }
    editor.initHighlighting();
    try editor.updateViewport(win.width, win.height, &font);

    // Overlay state
    var mode: EditorMode = .normal;
    var overlay = Overlay{};
    var file_list: ?[][]const u8 = null;
    defer if (file_list) |fl| file_walker.freeFiles(allocator, fl);
    var filtered_display: std.ArrayList([]const u8) = .{};
    defer filtered_display.deinit(allocator);

    // Epoll setup
    const epoll_fd = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
    defer std.posix.close(epoll_fd);

    // Register xcb fd
    const xcb_fd = win.getFd();
    var xcb_ev = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN,
        .data = .{ .u32 = 0 },
    };
    try std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, xcb_fd, &xcb_ev);

    // Timer for cursor blink (500ms)
    const timer_fd = try createTimerFd(500_000_000);
    defer std.posix.close(timer_fd);
    var timer_ev = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN,
        .data = .{ .u32 = 1 },
    };
    try std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, timer_fd, &timer_ev);

    var running = true;
    var mouse_dragging = false;

    // Initial render
    renderFrame(&editor, &win, &font, &overlay);

    while (running) {
        var events: [16]std.os.linux.epoll_event = undefined;
        const n = std.posix.epoll_wait(epoll_fd, &events, -1);

        for (events[0..n]) |ev| {
            switch (ev.data.u32) {
                0 => { // xcb events
                    while (win.pollEvent()) |event| {
                        switch (event) {
                            .close => running = false,

                            .key_press => |ke| {
                                if (mode != .normal) {
                                    handleOverlayKey(&mode, &overlay, &editor, ke, allocator, &file_list, &filtered_display);
                                } else {
                                    const mod = keymap.modFromWindow(ke.modifiers);
                                    if (keymap.mapKey(ke.keysym, mod)) |action| {
                                        switch (action) {
                                            .command_palette => openCommandPalette(&mode, &overlay, &filtered_display, allocator),
                                            .finder_files => openFileFinder(&mode, &overlay, allocator, &file_list, &filtered_display),
                                            .find => openSearch(&mode, &overlay),
                                            .goto_line => openGotoLine(&mode, &overlay),
                                            else => handleAction(&editor, &win, action),
                                        }
                                        resetCursorBlink(&editor);
                                    }
                                }
                            },

                            .text_input => |te| {
                                if (mode != .normal) {
                                    overlay.appendText(te.slice());
                                    updateOverlayResults(&mode, &overlay, allocator, file_list, &filtered_display);
                                    editor.markAllDirty();
                                } else {
                                    editor.insertAtCursor(te.slice()) catch {};
                                    resetCursorBlink(&editor);
                                }
                            },

                            .resize => |r| {
                                win.resize(r.width, r.height) catch {};
                                editor.updateViewport(r.width, r.height, &font) catch {};
                            },

                            .expose => editor.markAllDirty(),

                            .scroll => |s| {
                                handleScroll(&editor, s.delta);
                            },

                            .mouse_press => |me| {
                                if (me.button == .left) {
                                    const pos = editor.pixelToPosition(me.x, me.y, &font);
                                    editor.cursor.moveTo(pos);
                                    mouse_dragging = true;
                                    editor.markAllDirty();
                                    resetCursorBlink(&editor);
                                } else if (me.button == .middle) {
                                    win.requestPrimary();
                                }
                            },

                            .mouse_release => |me| {
                                if (me.button == .left) {
                                    mouse_dragging = false;
                                    // Set PRIMARY selection if text selected
                                    if (editor.getSelectedText()) |text| {
                                        win.setClipboard(text);
                                    }
                                }
                            },

                            .mouse_motion => |me| {
                                if (mouse_dragging) {
                                    const pos = editor.pixelToPosition(me.x, me.y, &font);
                                    editor.cursor.selectTo(pos);
                                    editor.markAllDirty();
                                }
                            },

                            .paste => |pe| {
                                editor.insertAtCursor(pe.data) catch {};
                                pe.deinit();
                                resetCursorBlink(&editor);
                            },

                            .focus_in => {
                                editor.cursor_visible = true;
                                editor.markAllDirty();
                            },

                            .focus_out => {
                                editor.cursor_visible = false;
                                editor.markAllDirty();
                            },
                        }
                    }
                },

                1 => { // cursor blink timer
                    var buf: [8]u8 = undefined;
                    _ = std.posix.read(timer_fd, &buf) catch {};
                    editor.cursor_visible = !editor.cursor_visible;
                    // Only dirty the cursor row
                    const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
                    if (lc.line >= editor.scroll_line) {
                        editor.markRowDirty(lc.line - editor.scroll_line);
                    }
                },

                else => {},
            }
        }

        renderFrame(&editor, &win, &font, &overlay);
    }
}

fn handleAction(editor: *EditorView, win: *Window, action: keymap.Action) void {
    switch (action) {
        .move_left => {
            editor.cursor.moveLeft(&editor.buffer, false);
            editor.ensureCursorVisible();
            editor.markAllDirty();
        },
        .move_right => {
            editor.cursor.moveRight(&editor.buffer, false);
            editor.ensureCursorVisible();
            editor.markAllDirty();
        },
        .move_up => {
            moveVertical(editor, -1, false);
        },
        .move_down => {
            moveVertical(editor, 1, false);
        },
        .move_home => {
            editor.cursor.moveHome(&editor.buffer, false);
            editor.ensureCursorVisible();
            editor.markAllDirty();
        },
        .move_end => {
            editor.cursor.moveEnd(&editor.buffer, false);
            editor.ensureCursorVisible();
            editor.markAllDirty();
        },
        .page_up => {
            const jump = editor.visible_rows -| 2;
            var i: u32 = 0;
            while (i < jump) : (i += 1) moveVertical(editor, -1, false);
        },
        .page_down => {
            const jump = editor.visible_rows -| 2;
            var i: u32 = 0;
            while (i < jump) : (i += 1) moveVertical(editor, 1, false);
        },
        .select_left => {
            editor.cursor.moveLeft(&editor.buffer, true);
            editor.ensureCursorVisible();
            editor.markAllDirty();
        },
        .select_right => {
            editor.cursor.moveRight(&editor.buffer, true);
            editor.ensureCursorVisible();
            editor.markAllDirty();
        },
        .select_up => moveVertical(editor, -1, true),
        .select_down => moveVertical(editor, 1, true),
        .select_home => {
            editor.cursor.moveHome(&editor.buffer, true);
            editor.ensureCursorVisible();
            editor.markAllDirty();
        },
        .select_end => {
            editor.cursor.moveEnd(&editor.buffer, true);
            editor.ensureCursorVisible();
            editor.markAllDirty();
        },
        .select_all => {
            editor.cursor.cursors.items[0] = .{ .anchor = 0, .head = editor.buffer.total_len };
            editor.markAllDirty();
        },
        .backspace => {
            editor.backspace() catch {};
            editor.markAllDirty();
        },
        .delete => {
            editor.deleteForward() catch {};
            editor.markAllDirty();
        },
        .enter => {
            editor.insertAtCursor("\n") catch {};
        },
        .tab => {
            editor.insertAtCursor("    ") catch {};
        },
        .copy => {
            if (editor.getSelectedText()) |text| {
                win.setClipboard(text);
            }
        },
        .cut => {
            if (editor.getSelectedText()) |text| {
                win.setClipboard(text);
                editor.deleteSelection() catch {};
            }
        },
        .paste => {
            win.requestClipboard();
        },
        .undo => {
            _ = editor.buffer.undo() catch {};
            editor.markAllDirty();
        },
        .redo => {
            _ = editor.buffer.redo() catch {};
            editor.markAllDirty();
        },
        .save => saveFile(editor),
        .quit => std.process.exit(0),
        // These are handled before reaching handleAction
        .command_palette, .finder_files, .find, .goto_line => {},
    }
}

fn moveVertical(editor: *EditorView, delta: i32, extend: bool) void {
    const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
    const new_line = if (delta < 0)
        if (lc.line > 0) lc.line - 1 else 0
    else
        @min(lc.line + 1, editor.buffer.lineCount() -| 1);

    if (new_line == lc.line) return;

    // Sticky column
    const target_col = editor.cursor.desired_col orelse lc.col;
    if (editor.cursor.desired_col == null) {
        editor.cursor.desired_col = lc.col;
    }

    const line_start = editor.buffer.lineToOffset(new_line);
    const next_line_start = editor.buffer.lineToOffset(new_line + 1);
    const line_len = if (next_line_start > line_start + 1)
        next_line_start - line_start - 1
    else if (next_line_start > line_start)
        next_line_start - line_start
    else
        0;

    const clamped_col = @min(target_col, line_len);
    const new_pos = line_start + clamped_col;

    if (extend) {
        editor.cursor.selectTo(new_pos);
    } else {
        editor.cursor.cursors.items[0] = .{ .anchor = new_pos, .head = new_pos };
    }

    editor.ensureCursorVisible();
    editor.markAllDirty();
}

fn handleScroll(editor: *EditorView, delta: i32) void {
    const lines: i32 = delta * 3;
    if (lines < 0) {
        const up: u32 = @intCast(-lines);
        editor.scroll_line = editor.scroll_line -| up;
    } else {
        editor.scroll_line = @min(
            editor.scroll_line + @as(u32, @intCast(lines)),
            editor.buffer.lineCount() -| 1,
        );
    }
    editor.markAllDirty();
}

fn saveFile(editor: *EditorView) void {
    const path = editor.file_path orelse return;
    const content = editor.buffer.collectContent(editor.allocator) catch return;
    defer editor.allocator.free(content);

    // Atomic save: write to temp, rename
    var tmp_buf: [512]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.zz-tmp", .{path}) catch return;

    const file = std.fs.cwd().createFile(tmp_path, .{}) catch return;
    file.writeAll(content) catch {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
        return;
    };
    file.close();

    std.fs.cwd().rename(tmp_path, path) catch return;
    editor.modified = false;
    editor.markAllDirty(); // Redraw status bar
}

fn renderFrame(editor: *EditorView, win: *Window, font: *FontFace, overlay: *Overlay) void {
    var renderer = Renderer{
        .buffer = win.getBuffer(),
        .stride = win.stride,
        .width = win.width,
        .height = win.height,
    };
    editor.render(&renderer, font);
    overlay.render(&renderer, font);
    win.markAllDirty();
    win.present();
}

fn resetCursorBlink(editor: *EditorView) void {
    editor.cursor_visible = true;
}

fn createTimerFd(interval_ns: u64) !std.posix.fd_t {
    const fd = try std.posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
    const ts = std.os.linux.timespec{
        .sec = @intCast(interval_ns / 1_000_000_000),
        .nsec = @intCast(interval_ns % 1_000_000_000),
    };
    const spec = std.os.linux.itimerspec{ .it_interval = ts, .it_value = ts };
    try std.posix.timerfd_settime(fd, .{}, &spec, null);
    return fd;
}

// ── Overlay mode openers ──────────────────────────────────────────

fn openCommandPalette(mode: *EditorMode, overlay: *Overlay, filtered_display: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    mode.* = .command_palette;
    overlay.open("Command Palette");
    // Pre-populate with all commands
    filtered_display.clearRetainingCapacity();
    for (&command_list) |cmd| {
        filtered_display.append(allocator, cmd) catch {};
    }
    overlay.items = filtered_display.items;
}

fn openFileFinder(mode: *EditorMode, overlay: *Overlay, allocator: std.mem.Allocator, file_list: *?[][]const u8, filtered_display: *std.ArrayList([]const u8)) void {
    // Walk files if not cached
    if (file_list.* == null) {
        file_list.* = file_walker.walkFiles(allocator, ".", 5000) catch null;
    }
    mode.* = .file_finder;
    overlay.open("Open File");
    // Pre-populate with all files
    filtered_display.clearRetainingCapacity();
    if (file_list.*) |files| {
        for (files) |f| {
            filtered_display.append(allocator, f) catch {};
        }
    }
    overlay.items = filtered_display.items;
}

fn openSearch(mode: *EditorMode, overlay: *Overlay) void {
    mode.* = .search;
    overlay.open("Search");
}

fn openGotoLine(mode: *EditorMode, overlay: *Overlay) void {
    mode.* = .goto_line;
    overlay.open("Go to Line");
}

// ── Overlay keyboard handler ──────────────────────────────────────

fn handleOverlayKey(
    mode: *EditorMode,
    overlay: *Overlay,
    editor: *EditorView,
    ke: window_mod.KeyEvent,
    allocator: std.mem.Allocator,
    file_list: *?[][]const u8,
    filtered_display: *std.ArrayList([]const u8),
) void {
    const keysym = ke.keysym;

    if (keysym == window_mod.XK_Escape) {
        overlay.close();
        mode.* = .normal;
        editor.markAllDirty();
        return;
    }

    if (keysym == window_mod.XK_Return) {
        switch (mode.*) {
            .file_finder => {
                if (overlay.selectedItem()) |path| {
                    openFile(editor, allocator, path);
                }
            },
            .goto_line => {
                const input = overlay.inputSlice();
                const line_num = std.fmt.parseInt(u32, input, 10) catch 0;
                if (line_num > 0) {
                    const offset = editor.buffer.lineToOffset(line_num - 1);
                    editor.cursor.moveTo(offset);
                    editor.ensureCursorVisible();
                }
            },
            .search => {
                const query = overlay.inputSlice();
                findNext(editor, query);
            },
            .command_palette => {
                if (overlay.selectedItem()) |cmd_name| {
                    executeCommand(cmd_name, editor);
                }
            },
            .normal => {},
        }
        overlay.close();
        mode.* = .normal;
        editor.markAllDirty();
        return;
    }

    if (keysym == window_mod.XK_Up) {
        overlay.moveUp();
        editor.markAllDirty();
        return;
    }
    if (keysym == window_mod.XK_Down) {
        overlay.moveDown();
        editor.markAllDirty();
        return;
    }
    if (keysym == window_mod.XK_BackSpace) {
        overlay.backspace();
        updateOverlayResults(mode, overlay, allocator, file_list.*, filtered_display);
        editor.markAllDirty();
        return;
    }
}

// ── Update overlay results on input change ────────────────────────

fn updateOverlayResults(
    mode: *const EditorMode,
    overlay: *Overlay,
    allocator: std.mem.Allocator,
    file_list: ?[][]const u8,
    filtered_display: *std.ArrayList([]const u8),
) void {
    const query = overlay.inputSlice();
    filtered_display.clearRetainingCapacity();

    switch (mode.*) {
        .file_finder => {
            if (file_list) |files| {
                const matches = fuzzy.filter(allocator, query, files, 50) catch {
                    overlay.items = &.{};
                    return;
                };
                defer allocator.free(matches);
                for (matches) |m| {
                    filtered_display.append(allocator, files[m.index]) catch {};
                }
            }
        },
        .command_palette => {
            const matches = fuzzy.filter(allocator, query, &command_list, 50) catch {
                overlay.items = &.{};
                return;
            };
            defer allocator.free(matches);
            for (matches) |m| {
                filtered_display.append(allocator, command_list[m.index]) catch {};
            }
        },
        else => {},
    }

    overlay.items = filtered_display.items;
    overlay.selected = 0;
    overlay.scroll_offset = 0;
}

// ── Find next occurrence in buffer ────────────────────────────────

fn findNext(editor: *EditorView, query: []const u8) void {
    if (query.len == 0) return;
    const content = editor.buffer.collectContent(editor.allocator) catch return;
    defer editor.allocator.free(content);

    const cursor_pos = editor.cursor.primary().head;
    const start: usize = @min(@as(usize, cursor_pos) + 1, content.len);

    // Search forward from cursor
    if (start < content.len) {
        if (std.mem.indexOf(u8, content[start..], query)) |pos| {
            const abs_pos: u32 = @intCast(start + pos);
            const end_pos: u32 = abs_pos + @as(u32, @intCast(query.len));
            editor.cursor.cursors.items[0] = .{ .anchor = abs_pos, .head = end_pos };
            editor.ensureCursorVisible();
            return;
        }
    }
    // Wrap around
    if (std.mem.indexOf(u8, content, query)) |pos| {
        const abs_pos: u32 = @intCast(pos);
        const end_pos: u32 = abs_pos + @as(u32, @intCast(query.len));
        editor.cursor.cursors.items[0] = .{ .anchor = abs_pos, .head = end_pos };
        editor.ensureCursorVisible();
    }
}

// ── Open a file into the editor ───────────────────────────────────

fn openFile(editor: *EditorView, allocator: std.mem.Allocator, path: []const u8) void {
    const new_content = std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024) catch return;

    editor.buffer.deinit(); // Frees owned_original if set
    editor.buffer = PieceTable.init(allocator, new_content) catch return;
    editor.buffer.owned_original = new_content; // Transfer ownership to PieceTable
    editor.cursor.moveTo(0);
    editor.scroll_line = 0;
    editor.modified = false;
    if (editor.file_path) |old| allocator.free(old);
    editor.file_path = allocator.dupe(u8, path) catch null;
    editor.initHighlighting();
    editor.markAllDirty();
}

// ── Execute a command palette command ─────────────────────────────

fn executeCommand(cmd_name: []const u8, editor: *EditorView) void {
    if (std.mem.eql(u8, cmd_name, "File: Save")) {
        saveFile(editor);
    } else if (std.mem.eql(u8, cmd_name, "Edit: Undo")) {
        _ = editor.buffer.undo() catch {};
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Edit: Redo")) {
        _ = editor.buffer.redo() catch {};
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Edit: Select All")) {
        editor.cursor.cursors.items[0] = .{ .anchor = 0, .head = editor.buffer.total_len };
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Editor: Close")) {
        std.process.exit(0);
    }
    // Other commands (Copy, Cut, Paste, Open, Find, Go to Line) require
    // additional context (window for clipboard, overlay for sub-modes).
    // They are no-ops from the palette for now.
}
