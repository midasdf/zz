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
const search_ops = @import("core/search_ops.zig");
const lsp_ops = @import("core/lsp_ops.zig");
const popups = @import("ui/popups.zig");

fn logError(context: []const u8, err: anyerror) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zz: {s}: {s}\n", .{ context, @errorName(err) }) catch return;
    _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {}; // last-resort log, nowhere to report
}

const EditorMode = enum {
    normal,
    command_palette,
    file_finder,
    search,
    goto_line,
    project_search,
    find_replace,
    goto_symbol,
    rename,
    code_action,
    goto_references,
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
    "Edit: Sort Lines (Ascending)",
    "Edit: Sort Lines (Descending)",
    "View: Go to Line",
    "View: Find",
    "Editor: Close",
    "Theme: Catppuccin Mocha",
    "Theme: Tokyo Night",
    "Theme: Gruvbox Dark",
    "Theme: One Dark",
    "Theme: Cycle Next",
    "Transform: UPPER CASE",
    "Transform: lower case",
    "Transform: Title Case",
    "Tab: Close Other Tabs",
    "Tab: Close All Tabs",
};

const font_path = "/usr/share/fonts/PlemolJP/PlemolJPConsoleNF-Regular.ttf";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            const msg = "zz: memory leak detected\n";
            _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch 0;
        }
    }
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
    file_tree.populate() catch |err| logError("file tree populate", err);

    // Terminal panel (XEmbed: embeds a real terminal emulator)
    var terminal = try Terminal.init(allocator);
    defer terminal.deinit();
    terminal.setup(win.getConnection(), win.getWindowId());

    // LSP client
    var lsp_client = lsp.LspClient.init(allocator);
    defer lsp_client.deinit();

    // Start LSP server if applicable
    if (initial_view.file_path) |path| {
        if (lsp.serverCommand(path)) |cmd| {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd_path = std.fs.cwd().realpath(".", &cwd_buf) catch null;
            if (cwd_path) |root| {
                lsp_client.start(cmd, root) catch |err| logError("LSP start", err);
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
    var replace_buf: [256]u8 = undefined;
    var replace_len: u32 = 0;
    var replace_field_active: bool = false; // false=search field, true=replace field
    var file_list: ?[][]const u8 = null;
    defer if (file_list) |fl| file_walker.freeFiles(allocator, fl);
    var filtered_display: std.ArrayList([]const u8) = .{};
    defer filtered_display.deinit(allocator);
    var search_results: std.ArrayList([]u8) = .{};
    defer {
        for (search_results.items) |r| allocator.free(r);
        search_results.deinit(allocator);
    }

    // Completion popup state
    var completion_active = false;
    var completion_selected: usize = 0;

    // Hover tooltip state
    var hover_active = false;

    // Signature help state
    var signature_active = false;

    // Format-on-save: when true, auto-save after formatting edits arrive
    var format_then_save = false;

    // LSP batched sync: set true on edits, sync once before render
    var lsp_needs_sync = false;

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
        std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, lsp_fd, &lsp_ev) catch {}; // non-fatal: LSP poll optional
    }

    var running = true;
    var mouse_dragging = false;
    var minimap_dragging = false;

    // Initial layout (account for sidebar + terminal)
    relayoutWithTerminal(&pane_mgr, &file_tree, &terminal, tab_bar_h, win.width, win.height, &font);

    // Initial render
    {
        const editor = tab_mgr.activeView();
        editor.lsp_diagnostics = lsp_client.diagnostics.items;
        editor.status_terminal_visible = terminal.visible;
        editor.status_diagnostic_count = @intCast(lsp_client.diagnostics.items.len);
        file_tree.active_path = if (editor.file_path) |p| p else null;
        renderFrame(&tab_mgr, &pane_mgr, &win, &font, &overlay, &file_tree, &terminal, &lsp_client, completion_active, completion_selected, hover_active, signature_active);
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
                                if (hover_active) {
                                    // Any key dismisses hover tooltip
                                    hover_active = false;
                                    editor.markAllDirty();
                                    // Fall through to process the key normally below
                                }
                                if (signature_active) {
                                    // Escape or ')' dismisses signature help
                                    if (ke.keysym == window_mod.XK_Escape) {
                                        signature_active = false;
                                        editor.markAllDirty();
                                        continue;
                                    }
                                }
                                if (completion_active) {
                                    if (ke.keysym == window_mod.XK_Escape) {
                                        completion_active = false;
                                        editor.markAllDirty();
                                        continue;
                                    } else if (ke.keysym == window_mod.XK_Up) {
                                        if (completion_selected > 0) completion_selected -= 1;
                                        editor.markAllDirty();
                                        continue;
                                    } else if (ke.keysym == window_mod.XK_Down) {
                                        if (completion_selected + 1 < lsp_client.completion_items.items.len) completion_selected += 1;
                                        editor.markAllDirty();
                                        continue;
                                    } else if (ke.keysym == window_mod.XK_Return or ke.keysym == window_mod.XK_Tab) {
                                        // Accept selected completion
                                        if (completion_selected < lsp_client.completion_items.items.len) {
                                            const item = lsp_client.completion_items.items[completion_selected];
                                            // Delete the partial word being typed, then insert completion
                                            lsp_ops.deleteWordBeforeCursor(editor);
                                            editor.insertAtCursor(item.label) catch {}; // OOM: completion insert best-effort
                                            lsp_needs_sync = true;
                                        }
                                        completion_active = false;
                                        editor.markAllDirty();
                                        continue;
                                    } else {
                                        // Any other key: close popup and process normally
                                        completion_active = false;
                                        editor.markAllDirty();
                                    }
                                }
                                if (mode != .normal) {
                                    handleOverlayKey(&mode, &overlay, &tab_mgr, &pane_mgr, ke, allocator, &file_list, &filtered_display, &search_results, &lsp_client, &font, &git_info, &replace_buf, &replace_len, &replace_field_active, &lsp_needs_sync);
                                } else {
                                    const mod = keymap.modFromWindow(ke.modifiers);
                                    // Check for toggle_terminal first (Ctrl+`)
                                    if (keymap.mapKey(ke.keysym, mod)) |action| {
                                        if (action == .toggle_terminal) {
                                            terminal.toggle();
                                            relayoutWithTerminal(&pane_mgr, &file_tree, &terminal, tab_bar_h, win.width, win.height, &font);
                                            markAllPanesDirty(&pane_mgr);
                                        } else if (terminal.focused) {
                                            // Terminal is focused: only Ctrl+` escapes back to editor
                                            // All other keys are delivered by X11 directly to the child window
                                        } else {
                                        switch (action) {
                                            .command_palette => openCommandPalette(&mode, &overlay, &filtered_display, allocator),
                                            .finder_files => openFileFinder(&mode, &overlay, allocator, &file_list, &filtered_display),
                                            .find => openSearch(&mode, &overlay),
                                            .find_replace => openFindReplace(&mode, &overlay, &replace_buf, &replace_len, &replace_field_active),
                                            .goto_line => openGotoLine(&mode, &overlay),
                                            .find_in_project => openProjectSearch(&mode, &overlay, allocator, &file_list, &filtered_display, &search_results),
                                            .goto_symbol => openGotoSymbol(&mode, &overlay, editor, &lsp_client, &filtered_display, allocator),
                                            .rename_symbol => openRename(&mode, &overlay, editor),
                                            .code_action => openCodeAction(&mode, &overlay, editor, &lsp_client, &filtered_display, allocator),
                                            .goto_references => openGotoReferences(&mode, &overlay, editor, &lsp_client, &filtered_display, allocator),
                                            .toggle_fold => {
                                                editor.toggleFold();
                                            },
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
                                            .trigger_completion => {
                                                if (editor.file_path) |path| {
                                                    var tc_buf: [4096]u8 = undefined;
                                                    const tc_uri = lsp.formatUri(path, &tc_buf);
                                                    const tc_lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
                                                    lsp_client.requestCompletion(tc_uri, tc_lc.line, tc_lc.col);
                                                }
                                            },
                                            .format_document => {
                                                if (editor.file_path) |path| {
                                                    var fd_buf: [4096]u8 = undefined;
                                                    const fd_uri = lsp.formatUri(path, &fd_buf);
                                                    lsp_client.requestFormatting(fd_uri);
                                                }
                                            },
                                            .save => {
                                                // Format-on-save: request formatting first if LSP supports it
                                                if (lsp_client.server_capabilities.has_formatting) {
                                                    if (editor.file_path) |path| {
                                                        var sv_buf: [4096]u8 = undefined;
                                                        const sv_uri = lsp.formatUri(path, &sv_buf);
                                                        lsp_client.requestFormatting(sv_uri);
                                                        format_then_save = true;
                                                    }
                                                } else {
                                                    handleAction(editor, &win, action, &lsp_client, &lsp_needs_sync);
                                                }
                                            },
                                            .toggle_minimap => {
                                                editor.minimap_visible = !editor.minimap_visible;
                                                editor.markAllDirty();
                                            },
                                            .toggle_word_wrap => {
                                                editor.word_wrap = !editor.word_wrap;
                                                editor.markAllDirty();
                                            },
                                            .toggle_terminal => unreachable,
                                            else => handleAction(editor, &win, action, &lsp_client, &lsp_needs_sync),
                                        }
                                        }
                                        resetCursorBlink(editor);
                                        // IME position: ext_move disabled for stability
                                    } else if (terminal.focused) {
                                        // Terminal focused: X11 delivers keys to child window directly
                                    }
                                }
                            },

                            .text_input => |te| {
                                if (mode != .normal) {
                                    if (mode == .find_replace and replace_field_active) {
                                        // Append to replace buffer
                                        for (te.slice()) |ch| {
                                            if (ch >= 0x20 and replace_len < replace_buf.len) {
                                                replace_buf[replace_len] = ch;
                                                replace_len += 1;
                                            }
                                        }
                                    } else {
                                        overlay.appendText(te.slice());
                                        updateOverlayResults(&mode, &overlay, allocator, file_list, &filtered_display, &search_results, &lsp_client);
                                    }
                                    editor.markAllDirty();
                                } else if (terminal.focused) {
                                    // Terminal focused: X11 delivers text to child window directly
                                } else {
                                    if (completion_active) {
                                        completion_active = false;
                                    }
                                    const text = te.slice();
                                    const auto_closed = editor.insertWithAutoClose(text) catch false;
                                    if (!auto_closed) {
                                        editor.insertAtCursor(text) catch {}; // OOM: text input best-effort
                                    }
                                    lsp_needs_sync = true;
                                    resetCursorBlink(editor);
                                    // IME position: ext_move disabled for stability
                                    // Auto-trigger completion after . : ( @
                                    if (text.len == 1 and (text[0] == '.' or text[0] == ':' or text[0] == '(' or text[0] == '@')) {
                                        // Flush LSP sync before request so server sees latest content
                                        lsp_needs_sync = false;
                                        lsp_ops.notifyLspChange(editor, &lsp_client, allocator);
                                        if (editor.file_path) |path| {
                                            var uri_buf2: [4096]u8 = undefined;
                                            const uri2 = lsp.formatUri(path, &uri_buf2);
                                            const lc2 = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
                                            lsp_client.requestCompletion(uri2, lc2.line, lc2.col);
                                        }
                                    }
                                    // Auto-trigger signature help after ( and ,
                                    if (text.len == 1 and (text[0] == '(' or text[0] == ',')) {
                                        if (lsp_needs_sync) {
                                            lsp_needs_sync = false;
                                            lsp_ops.notifyLspChange(editor, &lsp_client, allocator);
                                        }
                                        if (editor.file_path) |path| {
                                            var sh_buf: [4096]u8 = undefined;
                                            const sh_uri = lsp.formatUri(path, &sh_buf);
                                            const sh_lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
                                            lsp_client.requestSignatureHelp(sh_uri, sh_lc.line, sh_lc.col);
                                        }
                                    }
                                    // Dismiss signature help on )
                                    if (text.len == 1 and text[0] == ')') {
                                        signature_active = false;
                                    }
                                }
                            },

                            .resize => |r| {
                                win.resize(r.width, r.height) catch |err| logError("window resize", err);
                                relayoutWithTerminal(&pane_mgr, &file_tree, &terminal, tab_bar_h, r.width, r.height, &font);
                            },

                            .expose => markAllPanesDirty(&pane_mgr),

                            .scroll => |s| {
                                if (!terminal.focused) {
                                    handleScroll(editor, s.delta);
                                }
                                // When terminal focused, X11 delivers scroll to child window
                            },

                            .mouse_press => |me| {
                                if (terminal.containsPoint(me.x, me.y)) {
                                    // Click in terminal area: set X focus to child window
                                    terminal.setFocus();
                                } else if (me.button == .left) {
                                    if (terminal.focused) {
                                        terminal.unfocus();
                                    }
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
                                    } else if (handleStatusBarClick(pane_mgr.active_leaf, me.x, me.y, &terminal, &pane_mgr, &file_tree, tab_bar_h, win.width, win.height, &font)) {
                                        // Status bar button was clicked — handled above
                                        markAllPanesDirty(&pane_mgr);
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
                                        // Check if click is in minimap
                                        if (active.isInMinimap(me.x, me.y, win.width)) {
                                            active.handleMinimapClick(me.y, &font);
                                            minimap_dragging = true;
                                        } else {
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
                                if (!terminal.focused and me.button == .left) {
                                    mouse_dragging = false;
                                    minimap_dragging = false;
                                    const active = pane_mgr.active_leaf;
                                    if (active.getSelectedText()) |text| {
                                        win.setClipboard(text);
                                    }
                                }
                                // When terminal focused, X11 delivers mouse events to child window
                            },

                            .mouse_motion => |me| {
                                if (minimap_dragging) {
                                    const active = pane_mgr.active_leaf;
                                    active.handleMinimapClick(me.y, &font);
                                } else if (mouse_dragging) {
                                    const active = pane_mgr.active_leaf;
                                    const pos = active.pixelToPosition(me.x, me.y, &font);
                                    active.cursor.selectTo(pos);
                                    active.markAllDirty();
                                }
                                // When terminal focused, X11 delivers motion to child window
                            },

                            .paste => |pe| {
                                if (!terminal.focused) {
                                    const active = pane_mgr.active_leaf;
                                    active.insertAtCursor(pe.data) catch {}; // OOM: paste best-effort
                                    lsp_needs_sync = true;
                                    resetCursorBlink(editor);
                                }
                                // When terminal focused, terminal handles its own clipboard
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
                    _ = std.posix.read(timer_fd, &buf) catch {}; // non-fatal: drain timer fd
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

                    // Handle completion response
                    if (lsp_client.has_completion) {
                        lsp_client.has_completion = false;
                        if (lsp_client.completion_items.items.len > 0) {
                            completion_active = true;
                            completion_selected = 0;
                        }
                    }

                    // Handle hover response
                    if (lsp_client.has_hover) {
                        lsp_client.has_hover = false;
                        if (lsp_client.hover_text != null) {
                            hover_active = true;
                        }
                    }

                    // Handle signature help response
                    if (lsp_client.has_signature) {
                        lsp_client.has_signature = false;
                        if (lsp_client.signature != null) {
                            signature_active = true;
                        } else {
                            signature_active = false;
                        }
                    }

                    // Handle formatting response
                    if (lsp_client.has_formatting) {
                        lsp_client.has_formatting = false;
                        if (lsp_client.formatting_edits.items.len > 0) {
                            lsp_ops.applyFormattingEdits(editor, &lsp_client);
                            lsp_ops.notifyLspChange(editor, &lsp_client, allocator);
                        }
                        // Format-on-save: auto-save after formatting completes
                        if (format_then_save) {
                            format_then_save = false;
                            saveFile(editor);
                            if (editor.file_path) |path| {
                                var sv_uri_buf: [4096]u8 = undefined;
                                const sv_uri = lsp.formatUri(path, &sv_uri_buf);
                                lsp_client.didSave(sv_uri);
                            }
                        }
                    }

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

                    // Handle document symbols response
                    if (lsp_client.has_symbols) {
                        lsp_client.has_symbols = false;
                        if (mode == .goto_symbol) {
                            // Refresh the overlay with new symbols
                            lsp_ops.freeSymbolDisplay(&filtered_display, allocator);
                            lsp_ops.populateSymbolDisplay(&lsp_client, &filtered_display, allocator, overlay.inputSlice());
                            overlay.items = filtered_display.items;
                            editor.markAllDirty();
                        }
                    }

                    // Handle rename response
                    if (lsp_client.has_rename) {
                        lsp_client.has_rename = false;
                        applyRenameEdits(editor, &lsp_client, &tab_mgr, &pane_mgr, allocator, &font, &git_info);
                        lsp_ops.notifyLspChange(editor, &lsp_client, allocator);
                    }

                    // Handle code action response
                    if (lsp_client.has_code_actions) {
                        lsp_client.has_code_actions = false;
                        if (lsp_client.code_actions.items.len > 0 and mode == .code_action) {
                            // Populate overlay with action titles
                            filtered_display.clearRetainingCapacity();
                            for (lsp_client.code_actions.items) |ca| {
                                filtered_display.append(allocator, ca.title) catch {}; // OOM: skip display item
                            }
                            overlay.items = filtered_display.items;
                            editor.markAllDirty();
                        }
                    }

                    // Handle references response
                    if (lsp_client.has_references) {
                        lsp_client.has_references = false;
                        if (lsp_client.references.items.len > 0 and mode == .goto_references) {
                            lsp_ops.populateReferencesDisplay(&lsp_client, &filtered_display, allocator);
                            overlay.items = filtered_display.items;
                            editor.markAllDirty();
                        }
                    }
                },

                else => {},
            }
        }

        // Flush batched LSP sync before render
        if (lsp_needs_sync) {
            lsp_needs_sync = false;
            lsp_ops.notifyLspChange(pane_mgr.active_leaf, &lsp_client, allocator);
        }

        {
            const editor = pane_mgr.active_leaf;
            editor.lsp_diagnostics = lsp_client.diagnostics.items;
            editor.status_terminal_visible = terminal.visible;
            editor.status_diagnostic_count = @intCast(lsp_client.diagnostics.items.len);
            renderFrame(&tab_mgr, &pane_mgr, &win, &font, &overlay, &file_tree, &terminal, &lsp_client, completion_active, completion_selected, hover_active, signature_active);
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
        view.updateViewport(view.paneWidth(editor_w), win_h, font) catch |err| logError("viewport update", err);
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
        view.updateViewport(view.paneWidth(editor_w), tab_bar_h + available_h, font) catch |err| logError("viewport update", err);
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

/// Check if a click at (mx, my) hits a status bar action button.
/// Returns true if a button was clicked and handled.
fn handleStatusBarClick(
    editor: *EditorView,
    mx: i32,
    my: i32,
    term: *Terminal,
    pane_mgr: *PaneManager,
    file_tree: *FileTree,
    tab_bar_h: u32,
    win_w: u32,
    win_h: u32,
    font: *const FontFace,
) bool {
    // Status bar Y: check if click is below the status bar top
    if (my < 0 or @as(u32, @intCast(my)) < editor.status_bar_y) return false;

    const px: u32 = if (mx >= 0) @intCast(mx) else return false;

    // Terminal button
    if (editor.status_btn_terminal_w > 0 and
        px >= editor.status_btn_terminal_x and
        px < editor.status_btn_terminal_x + editor.status_btn_terminal_w)
    {
        term.toggle();
        relayoutWithTerminal(pane_mgr, file_tree, term, tab_bar_h, win_w, win_h, font);
        return true;
    }

    // Diagnostics button — jump to next diagnostic
    if (editor.status_btn_diag_w > 0 and
        px >= editor.status_btn_diag_x and
        px < editor.status_btn_diag_x + editor.status_btn_diag_w)
    {
        if (editor.lsp_diagnostics.len > 0) {
            // Find the next diagnostic after the current cursor line
            const cursor_line = editor.buffer.offsetToLineCol(editor.cursor.primary().head).line;
            var best: ?u32 = null;
            var first: ?u32 = null;
            for (editor.lsp_diagnostics) |diag| {
                if (first == null or diag.line < first.?) first = diag.line;
                if (diag.line > cursor_line) {
                    if (best == null or diag.line < best.?) best = diag.line;
                }
            }
            // Wrap around to first diagnostic if none found after cursor
            const target_line = best orelse (first orelse 0);
            const offset = editor.buffer.lineToOffset(target_line);
            editor.cursor.moveTo(offset);
            editor.ensureCursorVisible();
            editor.markAllDirty();
        }
        return true;
    }

    // Settings gear — currently a no-op placeholder (future: open config)
    if (editor.status_btn_gear_w > 0 and
        px >= editor.status_btn_gear_x and
        px < editor.status_btn_gear_x + editor.status_btn_gear_w)
    {
        // Placeholder: no action yet
        return true;
    }

    return false;
}

fn markAllPanesDirty(pane_mgr: *PaneManager) void {
    var leaves: [16]*EditorView = undefined;
    const count = pane_mgr.allLeaves(&leaves);
    for (leaves[0..count]) |view| {
        view.markAllDirty();
    }
}

fn handleAction(editor: *EditorView, win: *Window, action: keymap.Action, lsp_client: *lsp.LspClient, lsp_sync: *bool) void {
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
            const pair_deleted = editor.backspaceWithPairDelete() catch false;
            if (!pair_deleted) {
                editor.backspace() catch {}; // OOM: edit best-effort
            }
            lsp_sync.* = true;
        },
        .delete => {
            editor.deleteForward() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .delete_word_left => {
            editor.deleteWordLeft() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .delete_word_right => {
            editor.deleteWordRight() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .enter => {
            editor.insertNewline() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .tab => {
            if (editor.cursor.primary().hasSelection()) {
                editor.indentSelectedLines() catch {}; // OOM: edit best-effort
            } else {
                editor.insertAtCursor("    ") catch {}; // OOM: edit best-effort
            }
            lsp_sync.* = true;
        },
        .copy => {
            if (editor.getSelectedText()) |text| {
                win.setClipboard(text);
            }
        },
        .cut => {
            if (editor.getSelectedText()) |text| {
                win.setClipboard(text);
                editor.deleteSelection() catch {}; // OOM: edit best-effort
                lsp_sync.* = true;
            }
        },
        .paste => {
            win.requestClipboard();
        },
        .undo => {
            _ = editor.buffer.undo() catch {}; // OOM: undo best-effort
            lsp_sync.* = true;
            editor.markAllDirty();
        },
        .redo => {
            _ = editor.buffer.redo() catch {}; // OOM: redo best-effort
            lsp_sync.* = true;
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
            editor.selectNextOccurrence() catch {}; // OOM: multi-cursor best-effort
        },
        .select_all_occurrences => {
            editor.selectAllOccurrences() catch {}; // OOM: multi-cursor best-effort
        },
        .escape => {
            if (editor.cursor.cursorCount() > 1) {
                editor.cursor.collapseToSingle();
                editor.markAllDirty();
            }
        },
        .duplicate_line => {
            editor.duplicateLine() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .move_line_up => {
            editor.moveLineUp() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .move_line_down => {
            editor.moveLineDown() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .delete_line => {
            editor.deleteLine() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        // These are handled before reaching handleAction
        .command_palette, .finder_files, .find, .goto_line, .find_in_project, .find_replace => {},
        .trigger_completion, .format_document => {},
        .next_tab, .prev_tab, .close_tab => {},
        .split_vertical, .split_horizontal, .focus_next_pane, .close_pane => {},
        .toggle_sidebar, .toggle_terminal, .toggle_minimap, .toggle_word_wrap => {},
        .goto_symbol, .toggle_fold => {},
        .rename_symbol, .code_action, .goto_references => {},
        .toggle_comment => {
            editor.toggleComment() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .select_line => {
            editor.selectLine();
        },
        .join_lines => {
            editor.joinLines() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .insert_line_below => {
            editor.insertLineBelow() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .insert_line_above => {
            editor.insertLineAbove() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .outdent_lines => {
            editor.outdentSelectedLines() catch {}; // OOM: edit best-effort
            lsp_sync.* = true;
        },
        .goto_file_start => {
            editor.cursor.moveTo(0);
            editor.scroll_line = 0;
            editor.markAllDirty();
        },
        .goto_file_end => {
            editor.cursor.moveTo(editor.buffer.total_len);
            editor.ensureCursorVisible();
            editor.markAllDirty();
        },
        .scroll_up => {
            if (editor.scroll_line > 0) {
                editor.scroll_line -= 1;
                editor.markAllDirty();
            }
        },
        .scroll_down => {
            if (editor.scroll_line + editor.visible_rows < editor.buffer.lineCount()) {
                editor.scroll_line += 1;
                editor.markAllDirty();
            }
        },
        .goto_matching_bracket => {
            editor.gotoMatchingBracket();
        },
        .expand_selection => {
            editor.expandSelection();
        },
        .shrink_selection => {
            editor.shrinkSelection();
        },
        .sort_lines_asc, .sort_lines_desc => {},
        .next_diagnostic => {
            editor.gotoNextDiagnostic();
        },
        .prev_diagnostic => {
            editor.gotoPrevDiagnostic();
        },
        .switch_theme => {
            view_mod.cycleTheme();
            editor.markAllDirty();
        },
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

fn trimTrailingWhitespace(content: []u8) []u8 {
    // In-place trim: remove trailing spaces/tabs before newlines and at end of file
    var write: usize = 0;
    var line_start: usize = 0;
    var read: usize = 0;

    while (read < content.len) : (read += 1) {
        if (content[read] == '\n') {
            // Trim trailing whitespace from this line
            var line_end = read;
            while (line_end > line_start and (content[line_end - 1] == ' ' or content[line_end - 1] == '\t')) {
                line_end -= 1;
            }
            const len = line_end - line_start;
            if (write != line_start) {
                std.mem.copyForwards(u8, content[write..][0..len], content[line_start..][0..len]);
            }
            write += len;
            content[write] = '\n';
            write += 1;
            line_start = read + 1;
        }
    }
    // Last line (no trailing newline)
    if (read > line_start) {
        var line_end = read;
        while (line_end > line_start and (content[line_end - 1] == ' ' or content[line_end - 1] == '\t')) {
            line_end -= 1;
        }
        const len = line_end - line_start;
        if (write != line_start) {
            std.mem.copyForwards(u8, content[write..][0..len], content[line_start..][0..len]);
        }
        write += len;
    }
    return content[0..write];
}

fn saveFile(editor: *EditorView) void {
    const path = editor.file_path orelse return;
    const content = editor.buffer.collectContent(editor.allocator) catch return;
    defer editor.allocator.free(content);

    // Trim trailing whitespace before saving
    const trimmed = trimTrailingWhitespace(content);

    // Atomic save: write to temp, rename
    var tmp_buf: [512]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.zz-tmp", .{path}) catch return;

    const file = std.fs.cwd().createFile(tmp_path, .{}) catch return;
    file.writeAll(trimmed) catch {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {}; // non-fatal: temp file cleanup
        return;
    };
    file.close();

    std.fs.cwd().rename(tmp_path, path) catch return;

    // If trimming changed the content, reload the buffer to reflect trimmed state
    if (trimmed.len != content.len) {
        editor.buffer.deinit();
        editor.buffer = PieceTable.init(editor.allocator, trimmed) catch {
            // If reinit fails, just mark as saved anyway
            editor.modified = false;
            editor.markAllDirty();
            return;
        };
        // Clamp cursor position to valid range
        const cur = editor.cursor.primary();
        if (cur.head > editor.buffer.total_len) {
            editor.cursor.moveTo(editor.buffer.total_len);
        }
        editor.highlighter.parse(&editor.buffer);
    }
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

fn renderFrame(
    tab_mgr: *TabManager,
    pane_mgr: *PaneManager,
    win: *Window,
    font: *FontFace,
    overlay: *Overlay,
    file_tree: *FileTree,
    term: *Terminal,
    lsp_client: *lsp.LspClient,
    comp_active: bool,
    comp_selected: usize,
    show_hover: bool,
    show_signature: bool,
) void {
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

    // Completion popup
    if (comp_active and lsp_client.completion_items.items.len > 0) {
        const active_ed = pane_mgr.active_leaf;
        popups.renderCompletionPopup(&renderer, font, lsp_client.completion_items.items, comp_selected, active_ed);
    }

    // Hover tooltip
    if (show_hover) {
        if (lsp_client.hover_text) |hover_text| {
            const active_ed = pane_mgr.active_leaf;
            popups.renderHoverTooltip(&renderer, font, hover_text, active_ed);
        }
    }

    // Signature help tooltip
    if (show_signature) {
        if (lsp_client.signature) |sig| {
            const active_ed = pane_mgr.active_leaf;
            popups.renderSignatureHelp(&renderer, font, sig, active_ed);
        }
    }

    // IME cursor position updated separately via updateImeCursorPosition()

    win.markAllDirty();
    win.present();
}

fn resetCursorBlink(editor: *EditorView) void {
    editor.cursor_visible = true;
}

fn updateImeCursorPosition(editor: *const EditorView, win: *Window, font: *const FontFace) void {
    const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
    if (lc.line >= editor.scroll_line) {
        const screen_row = lc.line - editor.scroll_line;
        const vcol = editor.visualColAtOffset(lc.line, lc.col);
        const gw = editor.gutterWidth(font);
        const px_x: i32 = @intCast(editor.x_offset + gw + editor.left_pad + vcol * font.cell_width);
        const px_y: i32 = @intCast(editor.y_offset + (screen_row + 1) * font.cell_height);
        win.updateImeCursorPos(px_x, px_y);
    }
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
        filtered_display.append(allocator, cmd) catch {}; // OOM: skip display item
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
            filtered_display.append(allocator, f) catch {}; // OOM: skip display item
        }
    }
    overlay.items = filtered_display.items;
}

fn openSearch(mode: *EditorMode, overlay: *Overlay) void {
    mode.* = .search;
    overlay.open("Search");
}

fn openFindReplace(mode: *EditorMode, overlay: *Overlay, replace_buf: *[256]u8, replace_len: *u32, replace_field_active: *bool) void {
    mode.* = .find_replace;
    replace_len.* = 0;
    replace_field_active.* = false;
    overlay.open("Find & Replace");
    overlay.secondary_buf = replace_buf;
    overlay.secondary_len = replace_len;
    overlay.secondary_label = "Replace with:";
    overlay.secondary_active = false;
}

fn openGotoLine(mode: *EditorMode, overlay: *Overlay) void {
    mode.* = .goto_line;
    overlay.open("Go to Line");
}

fn openGotoSymbol(
    mode: *EditorMode,
    overlay: *Overlay,
    editor: *EditorView,
    lsp_client: *lsp.LspClient,
    filtered_display: *std.ArrayList([]const u8),
    _: std.mem.Allocator,
) void {
    mode.* = .goto_symbol;
    overlay.open("Go to Symbol");
    // Request document symbols from LSP
    if (editor.file_path) |path| {
        var uri_buf: [4096]u8 = undefined;
        const uri = lsp.formatUri(path, &uri_buf);
        lsp_client.requestDocumentSymbols(uri);
    }
    // Pre-populate with any cached symbols
    filtered_display.clearRetainingCapacity();
    overlay.items = filtered_display.items;
}

fn openRename(mode: *EditorMode, overlay: *Overlay, editor: *EditorView) void {
    mode.* = .rename;
    overlay.open("Rename Symbol");
    // Pre-fill with word under cursor
    const pos = editor.cursor.primary().head;
    // Find word boundaries
    var start = pos;
    while (start > 0) {
        const slice = editor.buffer.contiguousSliceAt(start - 1);
        if (slice.len == 0) break;
        if (!lsp_ops.isWordByte(slice[0])) break;
        start -= 1;
    }
    var end = pos;
    while (end < editor.buffer.total_len) {
        const slice = editor.buffer.contiguousSliceAt(end);
        if (slice.len == 0) break;
        if (!lsp_ops.isWordByte(slice[0])) break;
        end += 1;
    }
    // Copy word into overlay input
    const word_len = end - start;
    if (word_len > 0 and word_len < overlay.input_buf.len) {
        var i: u32 = 0;
        var off = start;
        while (off < end and i < overlay.input_buf.len) {
            const slice = editor.buffer.contiguousSliceAt(off);
            if (slice.len == 0) break;
            overlay.input_buf[i] = slice[0];
            i += 1;
            off += 1;
        }
        overlay.input_len = i;
    }
}

fn openCodeAction(
    mode: *EditorMode,
    overlay: *Overlay,
    editor: *EditorView,
    lsp_client: *lsp.LspClient,
    filtered_display: *std.ArrayList([]const u8),
    _: std.mem.Allocator,
) void {
    mode.* = .code_action;
    overlay.open("Code Actions");
    // Request code actions at cursor position
    if (editor.file_path) |path| {
        var uri_buf: [4096]u8 = undefined;
        const uri = lsp.formatUri(path, &uri_buf);
        const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
        lsp_client.requestCodeAction(uri, lc.line, lc.col, lc.line, lc.col);
    }
    filtered_display.clearRetainingCapacity();
    overlay.items = filtered_display.items;
}

fn openGotoReferences(
    mode: *EditorMode,
    overlay: *Overlay,
    editor: *EditorView,
    lsp_client: *lsp.LspClient,
    filtered_display: *std.ArrayList([]const u8),
    _: std.mem.Allocator,
) void {
    mode.* = .goto_references;
    overlay.open("References");
    // Request references at cursor position
    if (editor.file_path) |path| {
        var uri_buf: [4096]u8 = undefined;
        const uri = lsp.formatUri(path, &uri_buf);
        const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
        lsp_client.requestReferences(uri, lc.line, lc.col);
    }
    filtered_display.clearRetainingCapacity();
    overlay.items = filtered_display.items;
}

fn openProjectSearch(
    mode: *EditorMode,
    overlay: *Overlay,
    allocator: std.mem.Allocator,
    file_list: *?[][]const u8,
    filtered_display: *std.ArrayList([]const u8),
    search_results: *std.ArrayList([]u8),
) void {
    // Walk files if not cached
    if (file_list.* == null) {
        file_list.* = file_walker.walkFiles(allocator, ".", 5000) catch null;
    }
    mode.* = .project_search;
    overlay.open("Search in Project");
    // Clear previous results
    for (search_results.items) |r| allocator.free(r);
    search_results.clearRetainingCapacity();
    filtered_display.clearRetainingCapacity();
    overlay.items = &.{};
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
    search_results: *std.ArrayList([]u8),
    lsp_client: *lsp.LspClient,
    font: *const FontFace,
    git_info: ?*GitInfo,
    replace_buf: *[256]u8,
    replace_len: *u32,
    replace_field_active: *bool,
    lsp_sync: *bool,
) void {
    const keysym = ke.keysym;
    const editor = pane_mgr.active_leaf;

    if (keysym == window_mod.XK_Escape) {
        if (mode.* == .goto_symbol) {
            lsp_ops.freeSymbolDisplay(filtered_display, allocator);
        }
        if (mode.* == .goto_references) {
            lsp_ops.freeRefDisplay(filtered_display, allocator);
        }
        if (mode.* == .code_action) {
            filtered_display.clearRetainingCapacity();
        }
        overlay.close();
        mode.* = .normal;
        replace_field_active.* = false;
        editor.markAllDirty();
        return;
    }

    // Tab switches between search/replace fields in find_replace mode
    if (mode.* == .find_replace and keysym == window_mod.XK_Tab) {
        replace_field_active.* = !replace_field_active.*;
        overlay.secondary_active = replace_field_active.*;
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
                search_ops.findNext(editor, query);
            },
            .command_palette => {
                if (overlay.selectedItem()) |cmd_name| {
                    executeCommand(cmd_name, editor, tab_mgr, pane_mgr, git_info);
                }
            },
            .project_search => {
                if (overlay.selectedItem()) |result| {
                    // Parse "path:line: content" format
                    if (search_ops.parseSearchResult(result)) |parsed| {
                        openFileInTab(tab_mgr, allocator, parsed.path, lsp_client, font, git_info);
                        syncPaneToActiveTab(pane_mgr, tab_mgr);
                        const view = tab_mgr.activeView();
                        if (parsed.line > 0) {
                            const offset = view.buffer.lineToOffset(parsed.line - 1);
                            view.cursor.moveTo(offset);
                            view.ensureCursorVisible();
                        }
                        view.markAllDirty();
                    }
                }
            },
            .find_replace => {
                // Enter = replace current match + find next
                const query = overlay.inputSlice();
                const replacement = replace_buf[0..replace_len.*];
                if (query.len > 0) {
                    search_ops.replaceCurrentAndFindNext(editor, query, replacement, allocator);
                    lsp_sync.* = true;
                }
                // Don't close overlay -- allow multiple replacements
                editor.markAllDirty();
                return;
            },
            .goto_symbol => {
                // Jump to selected symbol's line
                if (overlay.selectedItem()) |_| {
                    const sel_idx = overlay.selected;
                    if (sel_idx < filtered_display.items.len) {
                        // Display format is "prefix name" -- extract name (after 6 chars)
                        const display_str = filtered_display.items[sel_idx];
                        const sym_name = if (display_str.len > 6) display_str[6..] else display_str;
                        for (lsp_client.document_symbols.items) |sym| {
                            if (std.mem.eql(u8, sym.name, sym_name)) {
                                const offset = editor.buffer.lineToOffset(sym.line);
                                editor.cursor.moveTo(offset);
                                editor.ensureCursorVisible();
                                break;
                            }
                        }
                    }
                }
                // Free allocated display strings before closing
                lsp_ops.freeSymbolDisplay(filtered_display, allocator);
            },
            .rename => {
                // Send rename request with the new name from overlay input
                const new_name = overlay.inputSlice();
                if (new_name.len > 0) {
                    if (editor.file_path) |path| {
                        var uri_buf: [4096]u8 = undefined;
                        const uri = lsp.formatUri(path, &uri_buf);
                        const lc = editor.buffer.offsetToLineCol(editor.cursor.primary().head);
                        lsp_client.requestRename(uri, lc.line, lc.col, new_name);
                    }
                }
            },
            .code_action => {
                // Apply the selected code action
                if (overlay.selectedItem()) |_| {
                    const sel_idx = overlay.selected;
                    if (sel_idx < lsp_client.code_actions.items.len) {
                        const ca = lsp_client.code_actions.items[sel_idx];
                        if (ca.edits.items.len > 0) {
                            // Apply edits to the current file (same-file only)
                            lsp_ops.applyCodeActionEdits(editor, ca.edits.items);
                            lsp_sync.* = true;
                        }
                    }
                }
                filtered_display.clearRetainingCapacity();
            },
            .goto_references => {
                // Jump to selected reference
                if (overlay.selectedItem()) |_| {
                    const sel_idx = overlay.selected;
                    if (sel_idx < lsp_client.references.items.len) {
                        const ref = lsp_client.references.items[sel_idx];
                        if (lsp.uriToPath(ref.uri)) |p| {
                            const should_open = if (editor.file_path) |current|
                                !std.mem.eql(u8, p, current)
                            else
                                true;
                            if (should_open) {
                                openFileInTab(tab_mgr, allocator, p, lsp_client, font, git_info);
                                syncPaneToActiveTab(pane_mgr, tab_mgr);
                            }
                            const active = tab_mgr.activeView();
                            const is_target = if (active.file_path) |fp| std.mem.eql(u8, fp, p) else false;
                            if (is_target) {
                                const target_off = active.buffer.lineToOffset(ref.line) + ref.col;
                                active.cursor.moveTo(@min(target_off, active.buffer.total_len));
                                active.ensureCursorVisible();
                                active.markAllDirty();
                            }
                        }
                    }
                }
                lsp_ops.freeRefDisplay(filtered_display, allocator);
            },
            .normal => {},
        }
        overlay.close();
        mode.* = .normal;
        replace_field_active.* = false;
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
        if (mode.* == .find_replace and replace_field_active.*) {
            if (replace_len.* > 0) replace_len.* -= 1;
        } else {
            overlay.backspace();
            updateOverlayResults(mode, overlay, allocator, file_list.*, filtered_display, search_results, lsp_client);
        }
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
    search_results: *std.ArrayList([]u8),
    lsp_client: ?*lsp.LspClient,
) void {
    const query = overlay.inputSlice();

    switch (mode.*) {
        .file_finder => {
            filtered_display.clearRetainingCapacity();
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
            filtered_display.clearRetainingCapacity();
            const matches = fuzzy.filter(allocator, query, &command_list, 50) catch {
                overlay.items = &.{};
                return;
            };
            defer allocator.free(matches);
            for (matches) |m| {
                filtered_display.append(allocator, command_list[m.index]) catch {};
            }
        },
        .project_search => {
            filtered_display.clearRetainingCapacity();
            // Free previous search results
            for (search_results.items) |r| allocator.free(r);
            search_results.clearRetainingCapacity();

            if (query.len >= 2) {
                if (file_list) |files| {
                    search_ops.searchInFiles(allocator, query, files, 100, search_results);
                    for (search_results.items) |r| {
                        filtered_display.append(allocator, r) catch {};
                    }
                }
            }
        },
        .goto_symbol => {
            if (lsp_client) |lc| {
                lsp_ops.freeSymbolDisplay(filtered_display, allocator);
                lsp_ops.populateSymbolDisplay(lc, filtered_display, allocator, query);
            }
        },
        else => {
            filtered_display.clearRetainingCapacity();
        },
    }

    overlay.items = filtered_display.items;
    overlay.selected = 0;
    overlay.scroll_offset = 0;
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

    // Create a new tab — PieceTable references new_content as `original`
    const tab_bar_h = view_mod.tabBarHeight(font);
    const view = tab_mgr.addTab(new_content, path) catch {
        allocator.free(new_content);
        return;
    };
    view.buffer.owned_original = new_content; // Transfer ownership to PieceTable
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

    var x: u32 = sidebar_w + 4;
    for (tab_mgr.tabs.items, 0..) |tab, i| {
        const label = if (tab.file_path) |p| fileBasename(p) else "[untitled]";
        const label_len: u32 = @intCast(label.len);
        const mod_extra: u32 = if (tab.modified) 2 else 0;
        const close_btn_w: u32 = cell_w + cell_w / 2;
        const tab_w = (label_len + mod_extra + 3) * cell_w + close_btn_w;

        const tab_x: i32 = @intCast(x);
        if (click_x >= tab_x and click_x < tab_x + @as(i32, @intCast(tab_w))) {
            // Check if click is on the × close button (right portion of tab)
            const close_region_start = tab_x + @as(i32, @intCast(tab_w - close_btn_w));
            if (click_x >= close_region_start) {
                // Close this tab
                tab_mgr.closeTab(i);
                // Ensure the active view has proper y_offset after close
                const view = tab_mgr.activeView();
                if (view.y_offset == 0) {
                    view.y_offset = view_mod.tabBarHeight(font);
                }
                view.markAllDirty();
                // Note: caller (main event loop) calls syncPaneToActiveTab after this
            } else {
                // Switch to this tab
                tab_mgr.switchTo(i);
                tab_mgr.activeView().markAllDirty();
            }
            return;
        }

        x += tab_w + 1;
    }
}

fn fileBasename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

// ── Execute a command palette command ─────────────────────────────

fn executeCommand(cmd_name: []const u8, editor: *EditorView, tab_mgr: *TabManager, pane_mgr: *PaneManager, git_info: ?*GitInfo) void {
    if (std.mem.eql(u8, cmd_name, "File: Save")) {
        saveFile(editor);
    } else if (std.mem.eql(u8, cmd_name, "Edit: Undo")) {
        _ = editor.buffer.undo() catch {}; // OOM: undo best-effort
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Edit: Redo")) {
        _ = editor.buffer.redo() catch {}; // OOM: redo best-effort
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Edit: Select All")) {
        editor.cursor.cursors.items[0] = .{ .anchor = 0, .head = editor.buffer.total_len };
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Editor: Close")) {
        std.process.exit(0);
    } else if (std.mem.eql(u8, cmd_name, "Theme: Catppuccin Mocha")) {
        view_mod.setTheme(&view_mod.themes.catppuccin_mocha);
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Theme: Tokyo Night")) {
        view_mod.setTheme(&view_mod.themes.tokyo_night);
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Theme: Gruvbox Dark")) {
        view_mod.setTheme(&view_mod.themes.gruvbox_dark);
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Theme: One Dark")) {
        view_mod.setTheme(&view_mod.themes.one_dark);
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Theme: Cycle Next")) {
        view_mod.cycleTheme();
        editor.markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Edit: Sort Lines (Ascending)")) {
        editor.sortSelectedLines(false) catch {}; // OOM: edit best-effort
    } else if (std.mem.eql(u8, cmd_name, "Edit: Sort Lines (Descending)")) {
        editor.sortSelectedLines(true) catch {}; // OOM: edit best-effort
    } else if (std.mem.eql(u8, cmd_name, "Transform: UPPER CASE")) {
        editor.transformCase(.upper) catch {}; // OOM: edit best-effort
    } else if (std.mem.eql(u8, cmd_name, "Transform: lower case")) {
        editor.transformCase(.lower) catch {}; // OOM: edit best-effort
    } else if (std.mem.eql(u8, cmd_name, "Transform: Title Case")) {
        editor.transformCase(.title) catch {}; // OOM: edit best-effort
    } else if (std.mem.eql(u8, cmd_name, "Tab: Close Other Tabs")) {
        tab_mgr.closeOthers();
        syncPaneToActiveTab(pane_mgr, tab_mgr);
        if (git_info) |gi| recomputeGitDiff(gi, tab_mgr.activeView());
        tab_mgr.activeView().markAllDirty();
    } else if (std.mem.eql(u8, cmd_name, "Tab: Close All Tabs")) {
        tab_mgr.closeAll();
        syncPaneToActiveTab(pane_mgr, tab_mgr);
        if (git_info) |gi| recomputeGitDiff(gi, tab_mgr.activeView());
        tab_mgr.activeView().markAllDirty();
    }
    // Other commands (Copy, Cut, Paste, Open, Find, Go to Line) require
    // additional context (window for clipboard, overlay for sub-modes).
    // They are no-ops from the palette for now.
}

// ── Apply rename edits from LSP ──────────────────────────────────

fn applyRenameEdits(
    editor: *EditorView,
    lsp_client: *lsp.LspClient,
    tab_mgr: *TabManager,
    pane_mgr: *PaneManager,
    allocator: std.mem.Allocator,
    font: *FontFace,
    git_info: ?*GitInfo,
) void {
    for (lsp_client.rename_edits.items) |re| {
        const path = lsp.uriToPath(re.uri) orelse continue;

        // Check if this is the current file
        const is_current = if (editor.file_path) |fp| std.mem.eql(u8, fp, path) else false;

        if (is_current) {
            // Apply edits to current buffer (back-to-front)
            lsp_ops.applyCodeActionEdits(editor, re.edits.items);
        } else {
            // Open the file in a new tab and apply edits
            openFileInTab(tab_mgr, allocator, path, lsp_client, font, git_info);
            syncPaneToActiveTab(pane_mgr, tab_mgr);
            const target = tab_mgr.activeView();
            lsp_ops.applyCodeActionEdits(target, re.edits.items);
        }
    }
    editor.markAllDirty();
}
