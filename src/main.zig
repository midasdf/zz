const std = @import("std");
const Window = @import("ui/window.zig").Window;
const window_mod = @import("ui/window.zig");
const FontFace = @import("ui/font.zig").FontFace;
const render_mod = @import("ui/render.zig");
const Renderer = render_mod.Renderer;
const EditorView = @import("editor/view.zig").EditorView;
const view_mod = @import("editor/view.zig");
const PieceTable = @import("editor/buffer.zig").PieceTable;
const TabManager = @import("editor/tabs.zig").TabManager;
const panes_mod = @import("editor/panes.zig");
const PaneManager = panes_mod.PaneManager;
const keymap = @import("input/keymap.zig");
const Overlay = @import("ui/overlay.zig").Overlay;
const fuzzy = @import("core/fuzzy.zig");
const file_walker = @import("core/file_walker.zig");
const lsp = @import("lsp/client.zig");
const FileTree = @import("ui/file_tree.zig").FileTree;
const GitInfo = @import("core/git.zig").GitInfo;
const Terminal = @import("ui/terminal.zig").Terminal;

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

    // Tab manager
    var tab_mgr = TabManager.init(allocator);
    defer tab_mgr.deinit();

    // Compute tab bar height
    const tab_bar_h = view_mod.tabBarHeight(&font);

    // Create initial tab
    const initial_view = try tab_mgr.addTab(content, file_path);
    initial_view.y_offset = tab_bar_h;
    initial_view.initHighlighting();
    try initial_view.updateViewport(win.width, win.height, &font);

    // Git integration
    var git_info = GitInfo.init(allocator);
    defer git_info.deinit();
    git_info.readBranch();
    if (file_path) |fp| {
        git_info.computeDiff(fp);
    }
    initial_view.git_info = &git_info;

    // Pane manager
    var pane_mgr = try PaneManager.init(allocator, initial_view);
    defer pane_mgr.deinit();

    // File tree sidebar (open by default like Zed)
    var file_tree = FileTree.init(allocator, ".");
    defer file_tree.deinit();
    file_tree.visible = true;
    file_tree.populate() catch {};

    // Terminal panel
    var terminal = try Terminal.init(allocator);
    defer terminal.deinit();

    // LSP client
    var lsp_client = lsp.LspClient.init(allocator);
    defer lsp_client.deinit();

    // Start LSP server if applicable
    if (initial_view.file_path) |path| {
        if (lsp.serverCommand(path)) |cmd| {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd_path = std.fs.cwd().realpath(".", &cwd_buf) catch null;
            if (cwd_path) |root| {
                lsp_client.start(cmd, root) catch {};
                // Send didOpen
                var uri_buf: [4096]u8 = undefined;
                const uri = lsp.formatUri(path, &uri_buf);
                const lsp_content = initial_view.buffer.collectContent(allocator) catch null;
                if (lsp_content) |c| {
                    defer allocator.free(c);
                    lsp_client.didOpen(uri, lsp.languageId(path) orelse "text", c);
                }
            }
        }
    }

    // Overlay state
    var mode: EditorMode = .normal;
    var overlay = Overlay{};
    var file_list: ?[][]const u8 = null;
    defer if (file_list) |fl| file_walker.freeFiles(allocator, fl);
    var filtered_display: std.ArrayList([]const u8) = .{};
    defer filtered_display.deinit(allocator);

    // Completion popup state
    var completion_active = false;
    var completion_selected: usize = 0;
    _ = &completion_active;
    _ = &completion_selected;

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

    // Register LSP stdout fd with epoll
    if (lsp_client.getStdoutFd()) |lsp_fd| {
        var lsp_ev = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .u32 = 2 },
        };
        std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, lsp_fd, &lsp_ev) catch {};
    }

    var running = true;
    var mouse_dragging = false;
    var pty_registered: ?std.posix.fd_t = null; // Track registered PTY fd

    // Initial layout (account for sidebar + terminal)
    relayoutWithTerminal(&pane_mgr, &file_tree, &terminal, tab_bar_h, win.width, win.height, &font);

    // Initial render
    {
        const editor = tab_mgr.activeView();
        editor.lsp_diagnostics = lsp_client.diagnostics.items;
        file_tree.active_path = if (editor.file_path) |p| p else null;
        renderFrame(&tab_mgr, &pane_mgr, &win, &font, &overlay, &file_tree, &terminal);
    }

    while (running) {
        var events: [16]std.os.linux.epoll_event = undefined;
        const n = std.posix.epoll_wait(epoll_fd, &events, -1);

        for (events[0..n]) |ev| {
            switch (ev.data.u32) {
                0 => { // xcb events
                    while (win.pollEvent()) |event| {
                        const editor = pane_mgr.active_leaf;
                        switch (event) {
                            .close => running = false,

                            .key_press => |ke| {
                                if (mode != .normal) {
                                    handleOverlayKey(&mode, &overlay, &tab_mgr, &pane_mgr, ke, allocator, &file_list, &filtered_display, &lsp_client, &font, &git_info);
                                } else {
                                    const mod = keymap.modFromWindow(ke.modifiers);
                                    // Check for toggle_terminal first (Ctrl+`)
                                    if (keymap.mapKey(ke.keysym, mod)) |action| {
                                        if (action == .toggle_terminal) {
                                            terminal.toggle();
                                            // Register/deregister PTY fd with epoll
                                            if (terminal.visible) {
                                                if (terminal.getPtyFd()) |pty_fd| {
                                                    if (pty_registered == null) {
                                                        var pty_ev = std.os.linux.epoll_event{
                                                            .events = std.os.linux.EPOLL.IN,
                                                            .data = .{ .u32 = 3 },
                                                        };
                                                        std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, pty_fd, &pty_ev) catch {};
                                                        pty_registered = pty_fd;
                                                    }
                                                }
                                            } else {
                                                if (pty_registered) |reg_fd| {
                                                    std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_DEL, reg_fd, null) catch {};
                                                    pty_registered = null;
                                                }
                                            }
                                            relayoutWithTerminal(&pane_mgr, &file_tree, &terminal, tab_bar_h, win.width, win.height, &font);
                                            markAllPanesDirty(&pane_mgr);
                                        } else if (terminal.focused) {
                                            // Terminal is focused: only Ctrl+` escapes, rest goes to PTY
                                            // (handled above as toggle_terminal)
                                            _ = terminal.handleKey(ke.keysym, ke.modifiers.ctrl, ke.modifiers.shift);
                                        } else {
                                        switch (action) {
                                            .command_palette => openCommandPalette(&mode, &overlay, &filtered_display, allocator),
                                            .finder_files => openFileFinder(&mode, &overlay, allocator, &file_list, &filtered_display),
                                            .find => openSearch(&mode, &overlay),
                                            .goto_line => openGotoLine(&mode, &overlay),
                                            .next_tab => {
                                                tab_mgr.nextTab();
                                                syncPaneToActiveTab(&pane_mgr, &tab_mgr);
                                                recomputeGitDiff(&git_info, tab_mgr.activeView());
                                                tab_mgr.activeView().markAllDirty();
                                            },
                                            .prev_tab => {
                                                tab_mgr.prevTab();
                                                syncPaneToActiveTab(&pane_mgr, &tab_mgr);
                                                recomputeGitDiff(&git_info, tab_mgr.activeView());
                                                tab_mgr.activeView().markAllDirty();
                                            },
                                            .close_tab => {
                                                tab_mgr.closeActive();
                                                syncPaneToActiveTab(&pane_mgr, &tab_mgr);
                                                recomputeGitDiff(&git_info, tab_mgr.activeView());
                                                tab_mgr.activeView().markAllDirty();
                                            },
                                            .split_vertical => {
                                                handleSplit(&pane_mgr, &tab_mgr, .vertical, allocator, &font, &file_tree, tab_bar_h, win.width, win.height, &terminal);
                                            },
                                            .split_horizontal => {
                                                handleSplit(&pane_mgr, &tab_mgr, .horizontal, allocator, &font, &file_tree, tab_bar_h, win.width, win.height, &terminal);
                                            },
                                            .focus_next_pane => {
                                                pane_mgr.focusNext();
                                                // Sync tab_mgr.active to match the focused pane
                                                syncTabToActivePane(&pane_mgr, &tab_mgr);
                                                markAllPanesDirty(&pane_mgr);
                                            },
                                            .close_pane => {
                                                if (pane_mgr.isSplit()) {
                                                    pane_mgr.unsplitActive();
                                                    relayoutWithTerminal(&pane_mgr, &file_tree, &terminal, tab_bar_h, win.width, win.height, &font);
                                                    syncTabToActivePane(&pane_mgr, &tab_mgr);
                                                    markAllPanesDirty(&pane_mgr);
                                                }
                                            },
                                            .toggle_sidebar => {
                                                file_tree.toggle();
                                                file_tree.active_path = if (pane_mgr.active_leaf.file_path) |p| p else null;
                                                relayoutWithTerminal(&pane_mgr, &file_tree, &terminal, tab_bar_h, win.width, win.height, &font);
                                                markAllPanesDirty(&pane_mgr);
                                            },
                                            .toggle_terminal => unreachable,
                                            else => handleAction(editor, &win, action, &lsp_client, allocator),
                                        }
                                        }
                                        resetCursorBlink(editor);
                                    } else if (terminal.focused) {
                                        // Unmapped key while terminal focused -- send raw
                                        _ = terminal.handleKey(ke.keysym, ke.modifiers.ctrl, ke.modifiers.shift);
                                    }
                                }
                            },

                            .text_input => |te| {
                                if (mode != .normal) {
                                    overlay.appendText(te.slice());
                                    updateOverlayResults(&mode, &overlay, allocator, file_list, &filtered_display);
                                    editor.markAllDirty();
                                } else if (terminal.focused) {
                                    terminal.handleTextInput(te.slice());
                                } else {
                                    editor.insertAtCursor(te.slice()) catch {};
                                    notifyLspChange(editor, &lsp_client, allocator);
                                    resetCursorBlink(editor);
                                }
                            },

                            .resize => |r| {
                                win.resize(r.width, r.height) catch {};
                                relayoutWithTerminal(&pane_mgr, &file_tree, &terminal, tab_bar_h, r.width, r.height, &font);
                            },

                            .expose => markAllPanesDirty(&pane_mgr),

                            .scroll => |s| {
                                if (!terminal.focused) {
                                    handleScroll(editor, s.delta);
                                }
                            },

                            .mouse_press => |me| {
                                if (me.button == .left) {
                                    // Check if click is in terminal area
                                    if (terminal.containsPoint(me.x, me.y)) {
                                        terminal.focused = true;
                                    } else {
                                        terminal.focused = false;
                                    const sw = file_tree.sidebarWidth(&font);
                                    if (file_tree.visible and me.x >= 0 and me.x < @as(i32, @intCast(sw))) {
                                        // Click in file tree sidebar
                                        if (file_tree.handleClick(me.x, me.y, &font, tab_bar_h)) |path| {
                                            openFileInTab(&tab_mgr, allocator, path, &lsp_client, &font, &git_info);
                                            syncPaneToActiveTab(&pane_mgr, &tab_mgr);
                                            file_tree.active_path = if (pane_mgr.active_leaf.file_path) |p| p else null;
                                            relayoutWithTerminal(&pane_mgr, &file_tree, &terminal, tab_bar_h, win.width, win.height, &font);
                                        }
                                        markAllPanesDirty(&pane_mgr);
                                    } else if (me.y >= 0 and me.y < @as(i32, @intCast(tab_bar_h))) {
                                        // Click in tab bar area
                                        handleTabBarClick(&tab_mgr, me.x, &font, sw);
                                        syncPaneToActiveTab(&pane_mgr, &tab_mgr);
                                        recomputeGitDiff(&git_info, tab_mgr.activeView());
                                        file_tree.active_path = if (pane_mgr.active_leaf.file_path) |p| p else null;
                                    } else {
                                        // Determine which pane was clicked
                                        if (pane_mgr.isSplit()) {
                                            if (pane_mgr.leafAtPixel(me.x, me.y)) |clicked_view| {
                                                if (clicked_view != pane_mgr.active_leaf) {
                                                    pane_mgr.active_leaf = clicked_view;
                                                    syncTabToActivePane(&pane_mgr, &tab_mgr);
                                                    markAllPanesDirty(&pane_mgr);
                                                }
                                            }
                                        }
                                        const active = pane_mgr.active_leaf;
                                        const pos = active.pixelToPosition(me.x, me.y, &font);
                                        active.cursor.moveTo(pos);
                                        mouse_dragging = true;
                                        active.markAllDirty();
                                        resetCursorBlink(active);
                                    }
                                    }
                                } else if (me.button == .middle) {
                                    win.requestPrimary();
                                }
                            },

                            .mouse_release => |me| {
                                if (me.button == .left) {
                                    mouse_dragging = false;
                                    const active = pane_mgr.active_leaf;
                                    if (active.getSelectedText()) |text| {
                                        win.setClipboard(text);
                                    }
                                }
                            },

                            .mouse_motion => |me| {
                                if (mouse_dragging) {
                                    const active = pane_mgr.active_leaf;
                                    const pos = active.pixelToPosition(me.x, me.y, &font);
                                    active.cursor.selectTo(pos);
                                    active.markAllDirty();
                                }
                            },

                            .paste => |pe| {
                                if (terminal.focused) {
                                    terminal.handlePaste(pe.data);
                                } else {
                                    const active = pane_mgr.active_leaf;
                                    active.insertAtCursor(pe.data) catch {};
                                    notifyLspChange(active, &lsp_client, allocator);
                                    resetCursorBlink(editor);
                                }
                                pe.deinit();
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
                    const editor = pane_mgr.active_leaf;
                    var buf: [8]u8 = undefined;
                    _ = std.posix.read(timer_fd, &buf) catch {};
                    editor.cursor_visible = !editor.cursor_visible;
                    const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
                    if (lc.line >= editor.scroll_line) {
                        editor.markRowDirty(lc.line - editor.scroll_line);
                    }
                },

                2 => { // LSP
                    const editor = pane_mgr.active_leaf;
                    lsp_client.processMessages();
                    editor.lsp_diagnostics = lsp_client.diagnostics.items;
                    editor.markAllDirty();

                    // Handle goto definition response
                    if (lsp_client.has_goto) {
                        lsp_client.has_goto = false;
                        if (lsp_client.goto_location) |loc| {
                            if (lsp.uriToPath(loc.uri)) |p| {
                                const should_open = if (editor.file_path) |current|
                                    !std.mem.eql(u8, p, current)
                                else
                                    true;
                                if (should_open) {
                                    openFileInTab(&tab_mgr, allocator, p, &lsp_client, &font, &git_info);
                                    syncPaneToActiveTab(&pane_mgr, &tab_mgr);
                                }
                                // Move cursor in the (now-active) tab
                                const active = tab_mgr.activeView();
                                const is_target = if (active.file_path) |fp| std.mem.eql(u8, fp, p) else false;
                                if (is_target) {
                                    const target_off = active.buffer.lineToOffset(loc.line) + loc.col;
                                    active.cursor.moveTo(@min(target_off, active.buffer.total_len));
                                    active.ensureCursorVisible();
                                    active.markAllDirty();
                                }
                            }
                        }
                    }
                },

                3 => { // PTY output
                    terminal.processOutput();
                },

                else => {},
            }
        }

        {
            const editor = pane_mgr.active_leaf;
            editor.lsp_diagnostics = lsp_client.diagnostics.items;
            renderFrame(&tab_mgr, &pane_mgr, &win, &font, &overlay, &file_tree, &terminal);
        }
    }
}

// ── Pane management helpers ──────────────────────────────────────

fn handleSplit(
    pane_mgr: *PaneManager,
    tab_mgr: *TabManager,
    direction: panes_mod.Direction,
    allocator: std.mem.Allocator,
    font: *FontFace,
    file_tree: *FileTree,
    tab_bar_h: u32,
    win_w: u32,
    win_h: u32,
    term: *Terminal,
) void {
    // Clone current buffer content for split (preserves unsaved edits)
    const current = pane_mgr.active_leaf;
    const fp = current.file_path;

    const content = current.buffer.collectContent(allocator) catch return;

    const new_view = tab_mgr.addTab(content, fp) catch {
        allocator.free(content);
        return;
    };
    new_view.buffer.owned_original = content;
    new_view.initHighlighting();

    // Copy cursor position and scroll from original
    new_view.scroll_line = current.scroll_line;
    new_view.cursor.cursors.items[0] = current.cursor.primary();

    pane_mgr.splitActive(direction, new_view) catch return;

    relayoutWithTerminal(pane_mgr, file_tree, term, tab_bar_h, win_w, win_h, font);
    markAllPanesDirty(pane_mgr);
}

fn relayoutPanes(pane_mgr: *PaneManager, file_tree: *FileTree, tab_bar_h: u32, win_w: u32, win_h: u32, font: *const FontFace) void {
    const sw = file_tree.sidebarWidth(font);
    const content_h = if (win_h > tab_bar_h) win_h - tab_bar_h else 0;
    const editor_w = if (win_w > sw) win_w - sw else 0;
    pane_mgr.applyLayout(sw, tab_bar_h, editor_w, content_h);

    // Update viewports for all leaves
    var leaves: [16]*EditorView = undefined;
    const count = pane_mgr.allLeaves(&leaves);
    for (leaves[0..count]) |view| {
        view.updateViewport(view.paneWidth(editor_w), win_h, font) catch {};
    }
}

fn relayoutWithTerminal(pane_mgr: *PaneManager, file_tree: *FileTree, term: *Terminal, tab_bar_h: u32, win_w: u32, win_h: u32, font: *const FontFace) void {
    const term_h = term.pixelHeight(font);
    const available_h = if (win_h > tab_bar_h + term_h) win_h - tab_bar_h - term_h else 0;
    const sw = file_tree.sidebarWidth(font);
    const editor_w = if (win_w > sw) win_w - sw else 0;
    pane_mgr.applyLayout(sw, tab_bar_h, editor_w, available_h);

    // Update viewports for all leaves
    var leaves: [16]*EditorView = undefined;
    const count = pane_mgr.allLeaves(&leaves);
    for (leaves[0..count]) |view| {
        view.updateViewport(view.paneWidth(editor_w), tab_bar_h + available_h, font) catch {};
    }

    // Update terminal layout
    if (term.visible) {
        const term_y = tab_bar_h + available_h;
        term.updateLayout(0, term_y, win_w, term_h, font);
    }
}

fn syncPaneToActiveTab(pane_mgr: *PaneManager, tab_mgr: *TabManager) void {
    // If not split, just update the active_leaf pointer
    if (!pane_mgr.isSplit()) {
        pane_mgr.active_leaf = tab_mgr.activeView();
        pane_mgr.root.* = .{ .leaf = tab_mgr.activeView() };
    }
}

fn syncTabToActivePane(pane_mgr: *PaneManager, tab_mgr: *TabManager) void {
    const active = pane_mgr.active_leaf;
    // Find which tab index matches this view
    for (tab_mgr.tabs.items, 0..) |tab, i| {
        if (tab == active) {
            tab_mgr.active = i;
            return;
        }
    }
}

fn markAllPanesDirty(pane_mgr: *PaneManager) void {
    var leaves: [16]*EditorView = undefined;
    const count = pane_mgr.allLeaves(&leaves);
    for (leaves[0..count]) |view| {
        view.markAllDirty();
    }
}

fn handleAction(editor: *EditorView, win: *Window, action: keymap.Action, lsp_client: *lsp.LspClient, allocator: std.mem.Allocator) void {
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
            notifyLspChange(editor, lsp_client, allocator);
            editor.markAllDirty();
        },
        .delete => {
            editor.deleteForward() catch {};
            notifyLspChange(editor, lsp_client, allocator);
            editor.markAllDirty();
        },
        .enter => {
            editor.insertAtCursor("\n") catch {};
            notifyLspChange(editor, lsp_client, allocator);
        },
        .tab => {
            editor.insertAtCursor("    ") catch {};
            notifyLspChange(editor, lsp_client, allocator);
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
                notifyLspChange(editor, lsp_client, allocator);
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
        .save => {
            saveFile(editor);
            // Notify LSP of save
            if (editor.file_path) |path| {
                var uri_buf: [4096]u8 = undefined;
                const uri = lsp.formatUri(path, &uri_buf);
                lsp_client.didSave(uri);
            }
        },
        .quit => std.process.exit(0),
        .goto_definition => {
            if (editor.file_path) |path| {
                var uri_buf: [4096]u8 = undefined;
                const uri = lsp.formatUri(path, &uri_buf);
                const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
                lsp_client.requestDefinition(uri, lc.line, lc.col);
            }
        },
        .hover => {
            if (editor.file_path) |path| {
                var uri_buf: [4096]u8 = undefined;
                const uri = lsp.formatUri(path, &uri_buf);
                const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
                lsp_client.requestHover(uri, lc.line, lc.col);
            }
        },
        .select_next_occurrence => {
            editor.selectNextOccurrence() catch {};
        },
        .select_all_occurrences => {
            editor.selectAllOccurrences() catch {};
        },
        .escape => {
            if (editor.cursor.cursorCount() > 1) {
                editor.cursor.collapseToSingle();
                editor.markAllDirty();
            }
        },
        // These are handled before reaching handleAction
        .command_palette, .finder_files, .find, .goto_line => {},
        .next_tab, .prev_tab, .close_tab => {},
        .split_vertical, .split_horizontal, .focus_next_pane, .close_pane => {},
        .toggle_sidebar, .toggle_terminal => {},
    }
}

fn notifyLspChange(editor: *EditorView, lsp_client: *lsp.LspClient, allocator: std.mem.Allocator) void {
    const path = editor.file_path orelse return;
    var uri_buf: [4096]u8 = undefined;
    const uri = lsp.formatUri(path, &uri_buf);
    const content = editor.buffer.collectContent(allocator) catch return;
    defer allocator.free(content);
    lsp_client.didChange(uri, content);
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

    // Recompute git diff after save
    if (editor.git_info) |gi| {
        gi.computeDiff(path);
    }

    editor.markAllDirty(); // Redraw status bar
}

fn recomputeGitDiff(git_info: *GitInfo, view: *EditorView) void {
    if (view.file_path) |fp| {
        git_info.computeDiff(fp);
    }
}

fn renderFrame(tab_mgr: *TabManager, pane_mgr: *PaneManager, win: *Window, font: *FontFace, overlay: *Overlay, file_tree: *FileTree, term: *Terminal) void {
    var renderer = Renderer{
        .buffer = win.getBuffer(),
        .stride = win.stride,
        .width = win.width,
        .height = win.height,
    };
    // Render tab bar first (offset by sidebar width)
    const sidebar_w = file_tree.sidebarWidth(font);
    view_mod.renderTabBar(tab_mgr, &renderer, font, sidebar_w);

    if (pane_mgr.isSplit()) {
        // Render all pane leaves
        var leaves: [16]*EditorView = undefined;
        const count = pane_mgr.allLeaves(&leaves);
        for (leaves[0..count]) |view| {
            view.render(&renderer, font);
        }
        // Render separators between panes
        const tab_bar_h = view_mod.tabBarHeight(font);
        const editor_w = if (win.width > sidebar_w) win.width - sidebar_w else 0;
        pane_mgr.renderSeparators(
            win.getBuffer(),
            win.stride,
            win.width,
            win.height,
            sidebar_w,
            tab_bar_h,
            editor_w,
            if (win.height > tab_bar_h) win.height - tab_bar_h else 0,
        );
        // Active pane indicator (lavender left border, 2px)
        const active = pane_mgr.active_leaf;
        const indicator_color = render_mod.Color.fromHex(0xb4befe);
        renderer.fillRect(active.x_offset, active.y_offset, 2, active.visible_rows * font.cell_height, indicator_color);
    } else {
        // Single pane -- render as before
        const editor = tab_mgr.activeView();
        editor.render(&renderer, font);
    }

    // Render file tree sidebar
    const tab_bar_h_render = view_mod.tabBarHeight(font);
    file_tree.render(&renderer, font, tab_bar_h_render);

    // Render terminal panel
    term.render(&renderer, font);

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
    tab_mgr: *TabManager,
    pane_mgr: *PaneManager,
    ke: window_mod.KeyEvent,
    allocator: std.mem.Allocator,
    file_list: *?[][]const u8,
    filtered_display: *std.ArrayList([]const u8),
    lsp_client: *lsp.LspClient,
    font: *const FontFace,
    git_info: ?*GitInfo,
) void {
    const keysym = ke.keysym;
    const editor = pane_mgr.active_leaf;

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
                    openFileInTab(tab_mgr, allocator, path, lsp_client, font, git_info);
                    syncPaneToActiveTab(pane_mgr, tab_mgr);
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
        pane_mgr.active_leaf.markAllDirty();
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

// ── Open a file in a tab (reuse existing or create new) ──────────

fn openFileInTab(tab_mgr: *TabManager, allocator: std.mem.Allocator, path: []const u8, lsp_client: ?*lsp.LspClient, font: *const FontFace, git_info: ?*GitInfo) void {
    // Check if already open in a tab
    if (tab_mgr.findByPath(path)) |idx| {
        tab_mgr.switchTo(idx);
        const view = tab_mgr.activeView();
        // Recompute diff for the switched-to file
        if (git_info) |gi| {
            if (view.file_path) |fp| gi.computeDiff(fp);
        }
        view.markAllDirty();
        return;
    }

    // Read the file
    const new_content = std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024) catch return;
    defer allocator.free(new_content);

    // Create a new tab
    const tab_bar_h = view_mod.tabBarHeight(font);
    const view = tab_mgr.addTab(new_content, path) catch return;
    view.y_offset = tab_bar_h;
    view.initHighlighting();
    view.git_info = git_info;

    // Compute git diff for the new tab
    if (git_info) |gi| {
        gi.computeDiff(path);
    }

    // Send didOpen for the new file to LSP
    if (lsp_client) |lc| {
        if (view.file_path) |new_path| {
            var uri_buf: [4096]u8 = undefined;
            const uri = lsp.formatUri(new_path, &uri_buf);
            const lsp_content = view.buffer.collectContent(allocator) catch null;
            if (lsp_content) |c| {
                defer allocator.free(c);
                lc.didOpen(uri, lsp.languageId(new_path) orelse "text", c);
            }
        }
    }
}

// ── Handle click on tab bar ──────────────────────────────────────

fn handleTabBarClick(tab_mgr: *TabManager, click_x: i32, font: *const FontFace, sidebar_w: u32) void {
    const cell_w = font.cell_width;
    if (cell_w == 0) return;

    var x: u32 = sidebar_w + 2;
    for (tab_mgr.tabs.items, 0..) |tab, i| {
        const label = if (tab.file_path) |p| fileBasename(p) else "[untitled]";
        const label_len: u32 = @intCast(label.len);
        const mod_extra: u32 = if (tab.modified) 2 else 0;
        const tab_w = (label_len + mod_extra + 2) * cell_w;

        if (click_x >= @as(i32, @intCast(x)) and click_x < @as(i32, @intCast(x + tab_w))) {
            tab_mgr.switchTo(i);
            tab_mgr.activeView().markAllDirty();
            return;
        }

        x += tab_w + 2;
    }
}

fn fileBasename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
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
