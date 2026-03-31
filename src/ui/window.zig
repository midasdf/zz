const std = @import("std");

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/shm.h");
    @cInclude("sys/shm.h");
    @cInclude("xcb-imdkit/imclient.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
    @cInclude("xcb/xkb.h");
});

// ── Event types ──────────────────────────────────────────────────────

pub const Event = union(enum) {
    key_press: KeyEvent,
    text_input: TextEvent,
    mouse_press: MouseEvent,
    mouse_release: MouseEvent,
    mouse_motion: MouseEvent,
    scroll: ScrollEvent,
    resize: ResizeEvent,
    expose: void,
    close: void,
    focus_in: void,
    focus_out: void,
    paste: PasteEvent,
};

pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    meta: bool = false,
};

pub const KeyEvent = struct {
    keysym: u32,
    modifiers: Modifiers,
};

pub const TextEvent = struct {
    data: [128]u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const TextEvent) []const u8 {
        const safe_len = @min(self.len, self.data.len);
        return self.data[0..safe_len];
    }
};

pub const PasteEvent = struct {
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const PasteEvent) void {
        self.allocator.free(self.data);
    }
};

pub const MouseEvent = struct {
    x: i32,
    y: i32,
    button: MouseButton,
};

pub const MouseButton = enum { left, middle, right, none };

pub const ScrollEvent = struct {
    delta: i32, // positive=down, negative=up
};

pub const ResizeEvent = struct {
    width: u32,
    height: u32,
};

// ── X11 keysyms for special keys ────────────────────────────────────

pub const XK_BackSpace = 0xFF08;
pub const XK_Tab = 0xFF09;
pub const XK_ISO_Left_Tab = 0xFE20;
pub const XK_Return = 0xFF0D;
pub const XK_Escape = 0xFF1B;
pub const XK_Home = 0xFF50;
pub const XK_Left = 0xFF51;
pub const XK_Up = 0xFF52;
pub const XK_Right = 0xFF53;
pub const XK_Down = 0xFF54;
pub const XK_Page_Up = 0xFF55;
pub const XK_Page_Down = 0xFF56;
pub const XK_End = 0xFF57;
pub const XK_Insert = 0xFF63;
pub const XK_Delete = 0xFFFF;
pub const XK_F1 = 0xFFBE;
pub const XK_F2 = 0xFFBF;
pub const XK_F3 = 0xFFC0;
pub const XK_F4 = 0xFFC1;
pub const XK_F5 = 0xFFC2;
pub const XK_F6 = 0xFFC3;
pub const XK_F7 = 0xFFC4;
pub const XK_F8 = 0xFFC5;
pub const XK_F9 = 0xFFC6;
pub const XK_F10 = 0xFFC7;
pub const XK_F11 = 0xFFC8;
pub const XK_F12 = 0xFFC9;

fn isSpecialKeysym(keysym: u32) bool {
    return switch (keysym) {
        XK_BackSpace,
        XK_Tab,
        XK_ISO_Left_Tab,
        XK_Return,
        XK_Escape,
        XK_Home,
        XK_Left,
        XK_Up,
        XK_Right,
        XK_Down,
        XK_Page_Up,
        XK_Page_Down,
        XK_End,
        XK_Insert,
        XK_Delete,
        XK_F1,
        XK_F2,
        XK_F3,
        XK_F4,
        XK_F5,
        XK_F6,
        XK_F7,
        XK_F8,
        XK_F9,
        XK_F10,
        XK_F11,
        XK_F12,
        => true,
        else => false,
    };
}

fn xcbStateToMods(state: u16) Modifiers {
    return .{
        .shift = (state & c.XCB_MOD_MASK_SHIFT) != 0,
        .ctrl = (state & c.XCB_MOD_MASK_CONTROL) != 0,
        .alt = (state & c.XCB_MOD_MASK_1) != 0, // Mod1 = Alt
        .meta = (state & c.XCB_MOD_MASK_4) != 0, // Mod4 = Super
    };
}

// ── Window struct ────────────────────────────────────────────────────

pub const Window = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    // XCB core
    connection: *c.xcb_connection_t,
    window: c.xcb_window_t,
    gc: c.xcb_gcontext_t,
    screen: *c.xcb_screen_t,
    screen_id: c_int = 0,

    // SHM double buffer
    shm_seg: [2]c.xcb_shm_seg_t,
    shm_id: [2]c_int,
    buffers: [2][]u8,
    buf_idx: u1 = 0,

    // Dimensions
    width: u32,
    height: u32,
    stride: u32,

    // Dirty region tracking (pixel rows)
    dirty_y_min: u32 = std.math.maxInt(u32),
    dirty_y_max: u32 = 0,

    // Atoms
    wm_delete_atom: c.xcb_atom_t,
    clipboard_atom: c.xcb_atom_t = 0,
    primary_atom: c.xcb_atom_t = 0,
    utf8_string_atom: c.xcb_atom_t = 0,
    zz_paste_atom: c.xcb_atom_t = 0,

    // XKB keyboard layout
    xkb_ctx: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,

    // XIM input method
    xim: ?*c.xcb_xim_t = null,
    xic: c.xcb_xic_t = 0,
    xim_connected: bool = false,
    committed_text: TextEvent = .{},
    has_committed: bool = false,
    forwarded_keycode: u8 = 0,
    has_forwarded_key: bool = false,
    pending_xim_keycode: u8 = 0,
    has_pending_xim: bool = false,
    suppress_xim_result: bool = false,

    // Event coalescing
    pending_event: ?*c.xcb_generic_event_t = null,

    // Lazy init
    keyboard_initialized: bool = false,

    // Clipboard ownership — we own this memory
    clipboard_content: ?[]u8 = null,

    // ── init ─────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, title: []const u8) !Window {
        // 1. Connect to X server
        var screen_num: c_int = 0;
        const connection = c.xcb_connect(null, &screen_num) orelse return error.XcbConnectFailed;
        errdefer c.xcb_disconnect(connection);

        if (c.xcb_connection_has_error(connection) != 0) {
            return error.XcbConnectionError;
        }

        // 2. Get screen
        const setup = c.xcb_get_setup(connection);
        var iter = c.xcb_setup_roots_iterator(setup);
        var i: c_int = 0;
        while (i < screen_num) : (i += 1) {
            c.xcb_screen_next(&iter);
        }
        const screen = iter.data orelse return error.NoScreen;

        const stride: u32 = width * 4;

        // 3. Create window
        const window = c.xcb_generate_id(connection);
        const event_mask: u32 = c.XCB_EVENT_MASK_KEY_PRESS |
            c.XCB_EVENT_MASK_KEY_RELEASE |
            c.XCB_EVENT_MASK_BUTTON_PRESS |
            c.XCB_EVENT_MASK_BUTTON_RELEASE |
            c.XCB_EVENT_MASK_POINTER_MOTION |
            c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            c.XCB_EVENT_MASK_EXPOSURE |
            c.XCB_EVENT_MASK_FOCUS_CHANGE;
        const values = [_]u32{ 0, event_mask };
        _ = c.xcb_create_window(
            connection,
            c.XCB_COPY_FROM_PARENT,
            window,
            screen.*.root,
            0,
            0,
            @intCast(width),
            @intCast(height),
            0,
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen.*.root_visual,
            c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK,
            &values,
        );

        // 4. Set WM_NAME and WM_CLASS
        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            window,
            c.XCB_ATOM_WM_NAME,
            c.XCB_ATOM_STRING,
            8,
            @intCast(title.len),
            title.ptr,
        );
        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            window,
            c.XCB_ATOM_WM_CLASS,
            c.XCB_ATOM_STRING,
            8,
            6,
            "zz\x00zz\x00",
        );

        // 5. Intern atoms
        const protocols_cookie = c.xcb_intern_atom(connection, 0, 12, "WM_PROTOCOLS");
        const delete_cookie = c.xcb_intern_atom(connection, 0, 16, "WM_DELETE_WINDOW");
        const clipboard_cookie = c.xcb_intern_atom(connection, 0, 9, "CLIPBOARD");
        const primary_cookie = c.xcb_intern_atom(connection, 0, 7, "PRIMARY");
        const utf8_cookie = c.xcb_intern_atom(connection, 0, 11, "UTF8_STRING");
        const paste_cookie = c.xcb_intern_atom(connection, 0, 8, "ZZ_PASTE");

        const protocols_reply = c.xcb_intern_atom_reply(connection, protocols_cookie, null);
        defer if (protocols_reply) |r| std.c.free(r);

        const delete_reply = c.xcb_intern_atom_reply(connection, delete_cookie, null);
        defer if (delete_reply) |r| std.c.free(r);

        var wm_delete_atom: c.xcb_atom_t = 0;
        if (protocols_reply) |pr| {
            if (delete_reply) |dr| {
                wm_delete_atom = dr.*.atom;
                _ = c.xcb_change_property(
                    connection,
                    c.XCB_PROP_MODE_REPLACE,
                    window,
                    pr.*.atom,
                    c.XCB_ATOM_ATOM,
                    32,
                    1,
                    @ptrCast(&dr.*.atom),
                );
            }
        }

        const clipboard_reply = c.xcb_intern_atom_reply(connection, clipboard_cookie, null);
        defer if (clipboard_reply) |r| std.c.free(r);
        const primary_reply = c.xcb_intern_atom_reply(connection, primary_cookie, null);
        defer if (primary_reply) |r| std.c.free(r);
        const utf8_reply = c.xcb_intern_atom_reply(connection, utf8_cookie, null);
        defer if (utf8_reply) |r| std.c.free(r);
        const paste_reply = c.xcb_intern_atom_reply(connection, paste_cookie, null);
        defer if (paste_reply) |r| std.c.free(r);

        var clipboard_atom: c.xcb_atom_t = 0;
        var primary_atom: c.xcb_atom_t = 0;
        var utf8_string_atom: c.xcb_atom_t = 0;
        var zz_paste_atom: c.xcb_atom_t = 0;
        if (clipboard_reply) |r| clipboard_atom = r.*.atom;
        if (primary_reply) |r| primary_atom = r.*.atom;
        if (utf8_reply) |r| utf8_string_atom = r.*.atom;
        if (paste_reply) |r| zz_paste_atom = r.*.atom;

        // 6. Set up SHM (second buffer created lazily on first present)
        const buffer_size = stride * height;
        const shm_id = c.shmget(c.IPC_PRIVATE, buffer_size, c.IPC_CREAT | 0o600);
        if (shm_id < 0) return error.ShmGetFailed;
        errdefer _ = c.shmctl(shm_id, c.IPC_RMID, null);

        const shm_ptr = c.shmat(shm_id, null, 0);
        if (shm_ptr == @as(*allowzero anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
            return error.ShmAtFailed;
        }
        const buffer: []u8 = @as([*]u8, @ptrCast(shm_ptr))[0..buffer_size];
        @memset(buffer, 0);

        const shm_seg = c.xcb_generate_id(connection);
        _ = c.xcb_shm_attach(connection, shm_seg, @intCast(shm_id), 0);
        _ = c.shmctl(shm_id, c.IPC_RMID, null);

        // 7. Create GC
        const gc = c.xcb_generate_id(connection);
        _ = c.xcb_create_gc(connection, gc, window, 0, null);

        // 8. Map window and flush
        _ = c.xcb_map_window(connection, window);
        _ = c.xcb_flush(connection);

        return Window{
            .allocator = allocator,
            .connection = connection,
            .window = window,
            .gc = gc,
            .screen = screen,
            .screen_id = screen_num,
            .shm_seg = .{ shm_seg, 0 },
            .shm_id = .{ shm_id, -1 },
            .buffers = .{ buffer, &.{} },
            .buf_idx = 0,
            .width = width,
            .height = height,
            .stride = stride,
            .wm_delete_atom = wm_delete_atom,
            .clipboard_atom = clipboard_atom,
            .primary_atom = primary_atom,
            .utf8_string_atom = utf8_string_atom,
            .zz_paste_atom = zz_paste_atom,
        };
        // NOTE: XKB and XIM are lazy-initialized on first key event,
        // after the struct is at its final memory address.
    }

    // ── deinit ───────────────────────────────────────────────────────

    pub fn deinit(self: *Window) void {
        // XIM
        if (self.xim) |xim| {
            if (self.xim_connected) {
                c.xcb_xim_close(xim);
            }
            c.xcb_xim_destroy(xim);
            self.xim = null;
        }
        // XKB
        if (self.xkb_state) |s| c.xkb_state_unref(s);
        if (self.xkb_keymap) |km| c.xkb_keymap_unref(km);
        if (self.xkb_ctx) |ctx| c.xkb_context_unref(ctx);
        // SHM
        for (0..2) |i| {
            if (self.buffers[i].len > 0) {
                _ = c.xcb_shm_detach(self.connection, self.shm_seg[i]);
                _ = c.shmdt(self.buffers[i].ptr);
            }
        }
        // Clipboard content
        if (self.clipboard_content) |content| {
            self.allocator.free(content);
        }
        // Pending event
        if (self.pending_event) |pe| {
            std.c.free(pe);
        }
        // XCB
        _ = c.xcb_free_gc(self.connection, self.gc);
        _ = c.xcb_destroy_window(self.connection, self.window);
        _ = c.xcb_flush(self.connection);
        c.xcb_disconnect(self.connection);
    }

    // ── Buffer access ────────────────────────────────────────────────

    pub fn getBuffer(self: *Window) []u8 {
        return self.buffers[self.buf_idx];
    }

    pub fn markDirtyRows(self: *Window, y_start: u32, y_end: u32) void {
        if (y_start < self.dirty_y_min) self.dirty_y_min = y_start;
        if (y_end > self.dirty_y_max) self.dirty_y_max = y_end;
    }

    pub fn markAllDirty(self: *Window) void {
        self.dirty_y_min = 0;
        self.dirty_y_max = self.height;
    }

    // ── Present (SHM put_image for dirty region, then swap buffers) ──

    pub fn present(self: *Window) void {
        if (self.dirty_y_min > self.dirty_y_max) return;

        const front = self.buf_idx;
        const y_start = self.dirty_y_min;
        const y_end = @min(self.dirty_y_max + 1, self.height);
        const dirty_h = y_end - y_start;
        const shm_offset = y_start * self.stride;

        _ = c.xcb_shm_put_image(
            self.connection,
            self.window,
            self.gc,
            @intCast(self.width),
            @intCast(dirty_h),
            0,
            0,
            @intCast(self.width),
            @intCast(dirty_h),
            0,
            @intCast(y_start),
            self.screen.*.root_depth,
            c.XCB_IMAGE_FORMAT_Z_PIXMAP,
            0,
            self.shm_seg[front],
            shm_offset,
        );

        // Lazy-init second buffer, then swap
        const back: u1 = front ^ 1;
        if (self.buffers[back].len == 0) {
            self.initSecondBuffer() catch {
                self.dirty_y_min = std.math.maxInt(u32);
                self.dirty_y_max = 0;
                _ = c.xcb_flush(self.connection);
                return;
            };
        }
        const byte_start = y_start * self.stride;
        const byte_end = y_end * self.stride;
        @memcpy(self.buffers[back][byte_start..byte_end], self.buffers[front][byte_start..byte_end]);
        self.buf_idx = back;

        self.dirty_y_min = std.math.maxInt(u32);
        self.dirty_y_max = 0;

        _ = c.xcb_flush(self.connection);
    }

    fn initSecondBuffer(self: *Window) !void {
        const buf_size = self.stride * self.height;
        const new_shm_id = c.shmget(c.IPC_PRIVATE, buf_size, c.IPC_CREAT | 0o600);
        if (new_shm_id < 0) return error.ShmGetFailed;
        const ptr = c.shmat(new_shm_id, null, 0);
        if (ptr == @as(*allowzero anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
            _ = c.shmctl(new_shm_id, c.IPC_RMID, null);
            return error.ShmAtFailed;
        }
        const buf: []u8 = @as([*]u8, @ptrCast(ptr))[0..buf_size];
        @memcpy(buf, self.buffers[self.buf_idx]);
        const seg = c.xcb_generate_id(self.connection);
        _ = c.xcb_shm_attach(self.connection, seg, @intCast(new_shm_id), 0);
        _ = c.shmctl(new_shm_id, c.IPC_RMID, null);
        const back: u1 = self.buf_idx ^ 1;
        self.shm_seg[back] = seg;
        self.shm_id[back] = new_shm_id;
        self.buffers[back] = buf;
    }

    // ── Resize ───────────────────────────────────────────────────────

    pub fn resize(self: *Window, w: u32, h: u32) !void {
        if (w == self.width and h == self.height) return;

        // Detach old SHM buffers
        for (0..2) |i| {
            if (self.buffers[i].len > 0) {
                _ = c.xcb_shm_detach(self.connection, self.shm_seg[i]);
                _ = c.shmdt(self.buffers[i].ptr);
                self.buffers[i] = &.{};
            }
        }

        // Create primary buffer; second will be lazy-inited on next present
        const new_stride = w * 4;
        const new_size = new_stride * h;
        const new_shm_id = c.shmget(c.IPC_PRIVATE, new_size, c.IPC_CREAT | 0o600);
        if (new_shm_id < 0) return error.ShmGetFailed;
        const new_ptr = c.shmat(new_shm_id, null, 0);
        if (new_ptr == @as(*allowzero anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
            _ = c.shmctl(new_shm_id, c.IPC_RMID, null);
            return error.ShmAtFailed;
        }
        self.buffers[0] = @as([*]u8, @ptrCast(new_ptr))[0..new_size];
        @memset(self.buffers[0], 0);
        const new_seg = c.xcb_generate_id(self.connection);
        _ = c.xcb_shm_attach(self.connection, new_seg, @intCast(new_shm_id), 0);
        _ = c.shmctl(new_shm_id, c.IPC_RMID, null);
        self.shm_seg[0] = new_seg;
        self.shm_id[0] = new_shm_id;
        self.buf_idx = 0;
        self.width = w;
        self.height = h;
        self.stride = new_stride;
    }

    // ── Event polling ────────────────────────────────────────────────

    pub fn pollEvent(self: *Window) ?Event {
        // Check XIM callback results first
        if (self.has_committed) {
            self.has_committed = false;
            if (self.suppress_xim_result) {
                self.suppress_xim_result = false;
            } else {
                return .{ .text_input = self.committed_text };
            }
        }
        if (self.has_forwarded_key) {
            self.has_forwarded_key = false;
            if (self.suppress_xim_result) {
                self.suppress_xim_result = false;
            } else {
                return self.processKeycode(self.forwarded_keycode);
            }
        }

        while (true) {
            const event = if (self.pending_event) |pe| blk: {
                self.pending_event = null;
                break :blk pe;
            } else c.xcb_poll_for_event(self.connection) orelse {
                return null;
            };
            defer std.c.free(event);

            // Let XIM filter first — needed even before xim_connected
            // because xcb-imdkit uses this for the XIM protocol handshake
            if (self.xim) |xim| {
                if (c.xcb_xim_filter_event(xim, event)) {
                    if (self.has_committed) {
                        self.has_committed = false;
                        if (self.suppress_xim_result) {
                            self.suppress_xim_result = false;
                        } else {
                            return .{ .text_input = self.committed_text };
                        }
                    }
                    if (self.has_forwarded_key) {
                        self.has_forwarded_key = false;
                        if (self.suppress_xim_result) {
                            self.suppress_xim_result = false;
                        } else {
                            return self.processKeycode(self.forwarded_keycode);
                        }
                    }
                    continue;
                }
            }

            const event_type = event.*.response_type & 0x7F;
            switch (event_type) {
                c.XCB_KEY_PRESS => {
                    self.ensureKeyboardInit();
                    const key: *c.xcb_key_press_event_t = @ptrCast(@alignCast(event));
                    const mods = xcbStateToMods(key.*.state);
                    const xcb_keycode: u32 = key.*.detail;

                    // Sync XKB modifier state from X server
                    if (self.xkb_state) |state| {
                        _ = c.xkb_state_update_mask(
                            state,
                            key.*.state,
                            0,
                            0,
                            0,
                            0,
                            0,
                        );
                    }

                    // Ctrl+Shift+V -> paste from clipboard
                    if (self.getKeysym(xcb_keycode) == 0x0076 and mods.ctrl and mods.shift and !mods.alt) { // 'v'
                        self.requestClipboard();
                        return null;
                    }

                    // Forward to XIM for text composition (skip Ctrl-modified keys)
                    if (!mods.ctrl) {
                        if (self.xim) |xim| {
                            if (self.xim_connected and self.xic != 0) {
                                const keysym = self.getKeysym(xcb_keycode);
                                const is_ime_toggle = keysym == 0x0020 and mods.shift and !mods.alt and !mods.meta; // Shift+Space
                                if (is_ime_toggle) {
                                    self.suppress_xim_result = true;
                                } else {
                                    self.suppress_xim_result = false;
                                }

                                self.pending_xim_keycode = key.*.detail;
                                self.has_pending_xim = true;
                                _ = c.xcb_xim_forward_event(xim, self.xic, key);

                                if (self.has_committed) {
                                    self.has_committed = false;
                                    if (!self.suppress_xim_result) {
                                        return .{ .text_input = self.committed_text };
                                    }
                                    self.suppress_xim_result = false;
                                    return null;
                                }
                                if (self.has_forwarded_key) {
                                    self.has_forwarded_key = false;
                                    if (!self.suppress_xim_result) {
                                        return self.processKeycode(self.forwarded_keycode);
                                    }
                                    self.suppress_xim_result = false;
                                    return null;
                                }
                                return null; // wait for async XIM response
                            }
                        }
                    }

                    // No XIM — process directly
                    return self.processXcbKeyPress(xcb_keycode, mods);
                },
                c.XCB_BUTTON_PRESS => {
                    const btn: *c.xcb_button_press_event_t = @ptrCast(@alignCast(event));
                    switch (btn.*.detail) {
                        4 => return .{ .scroll = .{ .delta = -1 } }, // scroll up
                        5 => return .{ .scroll = .{ .delta = 1 } }, // scroll down
                        else => {
                            const button: MouseButton = switch (btn.*.detail) {
                                1 => .left,
                                2 => .middle,
                                3 => .right,
                                else => .none,
                            };
                            return .{ .mouse_press = .{
                                .x = btn.*.event_x,
                                .y = btn.*.event_y,
                                .button = button,
                            } };
                        },
                    }
                },
                c.XCB_BUTTON_RELEASE => {
                    const btn: *c.xcb_button_release_event_t = @ptrCast(@alignCast(event));
                    // Ignore scroll button releases
                    if (btn.*.detail >= 4 and btn.*.detail <= 5) continue;
                    const button: MouseButton = switch (btn.*.detail) {
                        1 => .left,
                        2 => .middle,
                        3 => .right,
                        else => .none,
                    };
                    return .{ .mouse_release = .{
                        .x = btn.*.event_x,
                        .y = btn.*.event_y,
                        .button = button,
                    } };
                },
                c.XCB_MOTION_NOTIFY => {
                    const motion: *c.xcb_motion_notify_event_t = @ptrCast(@alignCast(event));
                    return .{ .mouse_motion = .{
                        .x = motion.*.event_x,
                        .y = motion.*.event_y,
                        .button = .none,
                    } };
                },
                c.XCB_CONFIGURE_NOTIFY => {
                    const cfg: *c.xcb_configure_notify_event_t = @ptrCast(@alignCast(event));
                    var latest_w: u32 = cfg.*.width;
                    var latest_h: u32 = cfg.*.height;
                    // Coalesce: drain queued ConfigureNotify, keep only last size
                    while (c.xcb_poll_for_queued_event(self.connection)) |next| {
                        const next_type = next.*.response_type & 0x7F;
                        if (next_type == c.XCB_CONFIGURE_NOTIFY) {
                            const next_cfg: *c.xcb_configure_notify_event_t = @ptrCast(@alignCast(next));
                            latest_w = next_cfg.*.width;
                            latest_h = next_cfg.*.height;
                            std.c.free(next);
                        } else {
                            self.pending_event = next;
                            break;
                        }
                    }
                    if (latest_w != self.width or latest_h != self.height) {
                        return .{ .resize = .{ .width = latest_w, .height = latest_h } };
                    }
                    continue;
                },
                c.XCB_EXPOSE => return .expose,
                c.XCB_CLIENT_MESSAGE => {
                    const msg: *c.xcb_client_message_event_t = @ptrCast(@alignCast(event));
                    if (msg.*.data.data32[0] == self.wm_delete_atom) {
                        return .close;
                    }
                    continue;
                },
                c.XCB_SELECTION_NOTIFY => {
                    const sel: *c.xcb_selection_notify_event_t = @ptrCast(@alignCast(event));
                    if (sel.*.property == 0) continue;

                    const prop_cookie = c.xcb_get_property(
                        self.connection,
                        1, // delete after reading
                        self.window,
                        sel.*.property,
                        c.XCB_ATOM_ANY,
                        0,
                        4 * 1024 * 1024, // max 4MB in 32-bit units (16MB data)
                    );
                    const prop_reply = c.xcb_get_property_reply(self.connection, prop_cookie, null);
                    if (prop_reply) |reply| {
                        defer std.c.free(reply);
                        const len: u32 = @intCast(c.xcb_get_property_value_length(reply));
                        if (len > 0) {
                            const data: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply));
                            // Dynamically allocate — no size limit
                            const buf = self.allocator.alloc(u8, len) catch continue;
                            @memcpy(buf, data[0..len]);
                            return .{ .paste = .{
                                .data = buf,
                                .allocator = self.allocator,
                            } };
                        }
                    }
                    continue;
                },
                c.XCB_SELECTION_REQUEST => {
                    self.handleSelectionRequest(@ptrCast(@alignCast(event)));
                    continue;
                },
                c.XCB_DESTROY_NOTIFY => return .close,
                c.XCB_FOCUS_IN => return .focus_in,
                c.XCB_FOCUS_OUT => return .focus_out,
                else => continue,
            }
        }
    }

    // ── Key processing ───────────────────────────────────────────────

    fn getKeysym(self: *Window, xcb_keycode: u32) u32 {
        if (self.xkb_state) |state| {
            return c.xkb_state_key_get_one_sym(state, xcb_keycode);
        }
        return 0;
    }

    /// Process an xcb keycode into an Event (used for XIM forward_event fallback).
    fn processKeycode(self: *Window, xcb_keycode: u8) ?Event {
        const code32: u32 = xcb_keycode;
        const keysym = self.getKeysym(code32);

        if (isSpecialKeysym(keysym)) {
            return .{ .key_press = .{ .keysym = keysym, .modifiers = .{} } };
        }

        // Try text via XKB
        if (self.xkb_state) |state| {
            var xkb_buf: [128]u8 = undefined;
            const len = c.xkb_state_key_get_utf8(state, code32, &xkb_buf, xkb_buf.len);
            if (len > 0) {
                const ulen: u32 = @intCast(len);
                var text_ev: TextEvent = .{};
                const clamped = @min(ulen, 128);
                @memcpy(text_ev.data[0..clamped], xkb_buf[0..clamped]);
                text_ev.len = clamped;
                return .{ .text_input = text_ev };
            }
        }

        return .{ .key_press = .{ .keysym = keysym, .modifiers = .{} } };
    }

    /// Process a key press event that was NOT consumed by XIM.
    fn processXcbKeyPress(self: *Window, xcb_keycode: u32, mods: Modifiers) ?Event {
        const keysym = self.getKeysym(xcb_keycode);

        // Special keys -> KeyEvent
        if (isSpecialKeysym(keysym)) {
            return .{ .key_press = .{ .keysym = keysym, .modifiers = mods } };
        }

        // Ctrl+key -> KeyEvent with keysym for the editor to interpret
        if (mods.ctrl) {
            return .{ .key_press = .{ .keysym = keysym, .modifiers = mods } };
        }

        // Regular text via XKB
        if (self.xkb_state) |state| {
            var xkb_buf: [128]u8 = undefined;
            const len = c.xkb_state_key_get_utf8(state, xcb_keycode, &xkb_buf, xkb_buf.len);
            if (len > 0) {
                const ulen: u32 = @intCast(len);
                var text_ev: TextEvent = .{};
                const clamped = @min(ulen, 128);
                @memcpy(text_ev.data[0..clamped], xkb_buf[0..clamped]);
                text_ev.len = clamped;
                return .{ .text_input = text_ev };
            }
            return null; // modifier-only key, no text produced
        }

        // Fallback: no XKB available
        return .{ .key_press = .{ .keysym = keysym, .modifiers = mods } };
    }

    // ── XCB fd for epoll ─────────────────────────────────────────────

    pub fn getFd(self: *Window) i32 {
        return c.xcb_get_file_descriptor(self.connection);
    }

    // ── Clipboard ────────────────────────────────────────────────────

    pub fn requestClipboard(self: *Window) void {
        if (self.clipboard_atom == 0 or self.utf8_string_atom == 0) return;
        _ = c.xcb_convert_selection(
            self.connection,
            self.window,
            self.clipboard_atom,
            self.utf8_string_atom,
            self.zz_paste_atom,
            c.XCB_CURRENT_TIME,
        );
        _ = c.xcb_flush(self.connection);
    }

    pub fn requestPrimary(self: *Window) void {
        if (self.primary_atom == 0 or self.utf8_string_atom == 0) return;
        _ = c.xcb_convert_selection(
            self.connection,
            self.window,
            self.primary_atom,
            self.utf8_string_atom,
            self.zz_paste_atom,
            c.XCB_CURRENT_TIME,
        );
        _ = c.xcb_flush(self.connection);
    }

    /// Take ownership of `text` and become the CLIPBOARD selection owner.
    /// The caller must NOT free the passed slice; Window owns it now.
    pub fn setClipboard(self: *Window, text: []u8) void {
        if (self.clipboard_content) |old| {
            self.allocator.free(old);
        }
        self.clipboard_content = text;
        _ = c.xcb_set_selection_owner(
            self.connection,
            self.window,
            self.clipboard_atom,
            c.XCB_CURRENT_TIME,
        );
        _ = c.xcb_flush(self.connection);
    }

    /// Serve clipboard content to another application requesting our selection.
    fn handleSelectionRequest(self: *Window, req: *c.xcb_selection_request_event_t) void {
        var notify: c.xcb_selection_notify_event_t = std.mem.zeroes(c.xcb_selection_notify_event_t);
        notify.response_type = c.XCB_SELECTION_NOTIFY;
        notify.requestor = req.*.requestor;
        notify.selection = req.*.selection;
        notify.target = req.*.target;
        notify.time = req.*.time;

        if (self.clipboard_content) |content| {
            if (req.*.target == self.utf8_string_atom or req.*.target == c.XCB_ATOM_STRING) {
                _ = c.xcb_change_property(
                    self.connection,
                    c.XCB_PROP_MODE_REPLACE,
                    req.*.requestor,
                    req.*.property,
                    self.utf8_string_atom,
                    8,
                    @intCast(content.len),
                    content.ptr,
                );
                notify.property = req.*.property;
            } else {
                notify.property = 0; // can't provide requested format
            }
        } else {
            notify.property = 0;
        }

        _ = c.xcb_send_event(
            self.connection,
            0,
            req.*.requestor,
            c.XCB_EVENT_MASK_NO_EVENT,
            @ptrCast(&notify),
        );
        _ = c.xcb_flush(self.connection);
    }

    // ── Keyboard init (lazy) ─────────────────────────────────────────

    fn ensureKeyboardInit(self: *Window) void {
        if (self.keyboard_initialized) return;
        self.keyboard_initialized = true;
        self.initXkb();
        self.initXim();
    }

    fn initXkb(self: *Window) void {
        const xkb_result = c.xkb_x11_setup_xkb_extension(
            self.connection,
            c.XKB_X11_MIN_MAJOR_XKB_VERSION,
            c.XKB_X11_MIN_MINOR_XKB_VERSION,
            c.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
            null,
            null,
            null,
            null,
        );
        if (xkb_result == 0) return;

        const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return;
        self.xkb_ctx = ctx;

        const device_id = c.xkb_x11_get_core_keyboard_device_id(self.connection);
        if (device_id < 0) return;

        const km = c.xkb_x11_keymap_new_from_device(ctx, self.connection, device_id, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
        self.xkb_keymap = km;

        const state = c.xkb_x11_state_new_from_device(km, self.connection, device_id) orelse return;
        self.xkb_state = state;
    }

    fn initXim(self: *Window) void {
        const im_names = [_]?[*:0]const u8{ null, "@im=fcitx", "@im=ibus" };
        var xim: ?*c.xcb_xim_t = null;
        for (im_names) |name| {
            xim = c.xcb_xim_create(self.connection, self.screen_id, name);
            if (xim != null) break;
        }
        if (xim == null) return;
        self.xim = xim;

        c.xcb_xim_set_use_utf8_string(xim.?, true);

        const S = struct {
            var callbacks = c.xcb_xim_im_callback{
                .set_event_mask = null,
                .forward_event = forwardEventCallback,
                .commit_string = commitStringCallback,
                .geometry = null,
                .preedit_start = null,
                .preedit_draw = null,
                .preedit_caret = null,
                .preedit_done = null,
                .status_start = null,
                .status_draw_text = null,
                .status_draw_bitmap = null,
                .status_done = null,
                .sync = null,
                .disconnected = disconnectedCallback,
            };
        };
        c.xcb_xim_set_im_callback(xim.?, &S.callbacks, @ptrCast(self));

        _ = c.xcb_xim_open(xim.?, ximOpenCallback, true, @ptrCast(self));
        _ = c.xcb_flush(self.connection);
    }

    // ── XIM callbacks ────────────────────────────────────────────────

    fn ximOpenCallback(xim: ?*c.xcb_xim_t, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(user_data));
        self.xim_connected = true;

        const input_style: u32 = 0x0008 | 0x0400; // XIMPreeditNothing | XIMStatusNothing
        _ = c.xcb_xim_create_ic(
            xim,
            ximCreateIcCallback,
            user_data,
            c.XCB_XIM_XNInputStyle,
            &input_style,
            c.XCB_XIM_XNClientWindow,
            &self.window,
            c.XCB_XIM_XNFocusWindow,
            &self.window,
            @as(?*anyopaque, null),
        );
    }

    fn ximCreateIcCallback(_: ?*c.xcb_xim_t, ic: c.xcb_xic_t, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(user_data));
        self.xic = ic;
        if (self.xim) |xim| {
            _ = c.xcb_xim_set_ic_focus(xim, ic);
        }
    }

    fn commitStringCallback(
        _: ?*c.xcb_xim_t,
        _: c.xcb_xic_t,
        _: u32,
        str: [*c]u8,
        length: u32,
        _: [*c]u32,
        _: usize,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(user_data));
        var data = str[0..length];

        // Strip ISO 2022 Compound Text wrappers if present
        // ESC % G (switch to UTF-8) = 1b 25 47
        if (data.len >= 3 and data[0] == 0x1b and data[1] == 0x25 and data[2] == 0x47) {
            data = data[3..];
        }
        // ESC % @ (switch back to Latin-1) = 1b 25 40
        if (data.len >= 3 and data[data.len - 3] == 0x1b and data[data.len - 2] == 0x25 and data[data.len - 1] == 0x40) {
            data = data[0 .. data.len - 3];
        }

        const len = @min(data.len, 128);
        @memcpy(self.committed_text.data[0..len], data[0..len]);
        self.committed_text.len = @intCast(len);
        self.has_committed = true;
        self.has_pending_xim = false;
    }

    fn forwardEventCallback(
        _: ?*c.xcb_xim_t,
        _: c.xcb_xic_t,
        event: ?*c.xcb_key_press_event_t,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(user_data));
        if (event) |ev| {
            const is_press = (ev.response_type & 0x7F) == c.XCB_KEY_PRESS;
            if (!is_press) return;
            self.forwarded_keycode = ev.detail;
            self.has_forwarded_key = true;
            self.has_pending_xim = false;
        }
    }

    fn disconnectedCallback(_: ?*c.xcb_xim_t, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(user_data));
        self.xim_connected = false;
        self.xic = 0;
    }
};
