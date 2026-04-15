// zz/src/ui/terminal.zig — Embedded terminal panel using XEmbed (child xcb window + real terminal emulator)
const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const render_mod = @import("render.zig");
const Renderer = render_mod.Renderer;
const Color = render_mod.Color;
const font_mod = @import("font.zig");
const FontFace = font_mod.FontFace;

const c = @cImport({
    @cInclude("xcb/xcb.h");
});

/// Cast an opaque connection pointer (from window.zig's separate @cImport)
/// to our local xcb_connection_t pointer.
fn xcbConn(ptr: *anyopaque) *c.xcb_connection_t {
    return @ptrCast(ptr);
}

// ── Public Terminal Panel ──────────────────────────────────────────

pub const Terminal = struct {
    visible: bool = false,
    focused: bool = false,
    height_rows: u32 = 14,

    // XCB child window for embedding
    child_window: u32 = 0, // xcb_window_t
    connection: ?*anyopaque = null, // xcb_connection_t, borrowed from Window (opaque to avoid cross-cImport mismatch)
    parent_window: u32 = 0,

    // Terminal subprocess
    pid: ?posix.pid_t = null,

    // Layout (pixels)
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    // Configuration
    terminal_cmd: [128]u8 = undefined,
    terminal_cmd_len: u8 = 0,

    allocator: Allocator,

    pub fn init(allocator: Allocator, env_map: *std.process.Environ.Map) !Terminal {
        var self = Terminal{
            .allocator = allocator,
        };
        // Check ZZ_TERMINAL env var, default to "st"
        if (env_map.get("ZZ_TERMINAL")) |env_term| {
            const len: u8 = @intCast(@min(env_term.len, 128));
            @memcpy(self.terminal_cmd[0..len], env_term[0..len]);
            self.terminal_cmd_len = len;
        } else {
            const default = "st";
            @memcpy(self.terminal_cmd[0..default.len], default);
            self.terminal_cmd_len = default.len;
        }
        return self;
    }

    /// Store the xcb connection and parent window from Window.
    /// Accepts *anyopaque to bridge separate @cImport namespaces.
    pub fn setup(self: *Terminal, xcb_conn: *anyopaque, parent: u32) void {
        self.connection = xcb_conn;
        self.parent_window = parent;
    }

    pub fn deinit(self: *Terminal) void {
        self.killChild();
        self.destroyChildWindow();
    }

    pub fn toggle(self: *Terminal) void {
        if (self.visible) {
            self.hide();
        } else {
            self.show();
        }
    }

    pub fn show(self: *Terminal) void {
        self.visible = true;
        self.focused = true;
        if (self.pid == null) {
            self.spawn();
        } else if (self.child_window != 0) {
            // Re-show existing child window
            const cx = xcbConn(self.connection orelse return);
            _ = c.xcb_map_window(cx, self.child_window);
            _ = c.xcb_flush(cx);
        }
    }

    pub fn hide(self: *Terminal) void {
        self.visible = false;
        self.focused = false;
        if (self.child_window != 0) {
            const cx = xcbConn(self.connection orelse return);
            _ = c.xcb_unmap_window(cx, self.child_window);
            _ = c.xcb_flush(cx);
        }
    }

    pub fn spawn(self: *Terminal) void {
        const cx = xcbConn(self.connection orelse return);

        // Create child window if needed
        if (self.child_window == 0) {
            self.child_window = c.xcb_generate_id(cx);
            const event_mask: u32 = c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY;
            const values = [_]u32{ 0x1e1e2e, event_mask }; // bg color (Catppuccin base), event mask
            _ = c.xcb_create_window(
                cx,
                c.XCB_COPY_FROM_PARENT,
                self.child_window,
                self.parent_window,
                @intCast(self.x),
                @intCast(self.y + 2), // +2 for separator
                @intCast(@max(self.width, 1)),
                @intCast(@max(if (self.height > 2) self.height - 2 else 1, 1)),
                0,
                c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
                c.XCB_COPY_FROM_PARENT,
                c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK,
                &values,
            );
            _ = c.xcb_map_window(cx, self.child_window);
            _ = c.xcb_flush(cx);
        }

        // Format window ID as decimal string for -w argument
        var wid_buf: [20]u8 = undefined;
        const wid_str = std.fmt.bufPrint(&wid_buf, "{d}", .{self.child_window}) catch return;

        // Prepare the terminal command name (null-terminated)
        var cmd_buf: [129]u8 = undefined;
        const cmd_name = self.terminal_cmd[0..self.terminal_cmd_len];
        if (cmd_name.len >= cmd_buf.len) return;
        @memcpy(cmd_buf[0..cmd_name.len], cmd_name);
        cmd_buf[cmd_name.len] = 0;
        const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..cmd_name.len :0]);

        // Determine embed flag based on terminal name
        const embed_flag = embedFlag(cmd_name);
        var flag_buf: [20]u8 = undefined;
        @memcpy(flag_buf[0..embed_flag.len], embed_flag);
        flag_buf[embed_flag.len] = 0;
        const flag_z: [*:0]const u8 = @ptrCast(flag_buf[0..embed_flag.len :0]);

        // Window ID (null-terminated)
        var wid_z_buf: [21]u8 = undefined;
        @memcpy(wid_z_buf[0..wid_str.len], wid_str);
        wid_z_buf[wid_str.len] = 0;
        const wid_z: [*:0]const u8 = @ptrCast(wid_z_buf[0..wid_str.len :0]);

        const argv = [_:null]?[*:0]const u8{ cmd_z, flag_z, wid_z, null };

        // Debug: log what we're spawning
        {
            var dbg: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&dbg, "zz: spawn terminal: {s} {s} {s} (win={d} {d}x{d}+{d}+{d})\n", .{ cmd_name, embed_flag, wid_str, self.child_window, self.width, self.height, self.x, self.y }) catch "";
            _ = posix.write(posix.STDERR_FILENO, msg) catch {};
        }

        const fork_result = posix.fork() catch return;
        if (fork_result == 0) {
            // Child process: exec the terminal emulator
            _ = posix.execvpeZ(cmd_z, &argv, @ptrCast(std.c.environ)) catch {};
            posix.exit(1);
        }
        self.pid = fork_result;
    }

    pub fn setFocus(self: *Terminal) void {
        if (!self.visible or self.child_window == 0) return;
        const cx = xcbConn(self.connection orelse return);
        self.focused = true;
        _ = c.xcb_set_input_focus(
            cx,
            c.XCB_INPUT_FOCUS_POINTER_ROOT,
            self.child_window,
            c.XCB_CURRENT_TIME,
        );
        _ = c.xcb_flush(cx);
    }

    pub fn unfocus(self: *Terminal) void {
        self.focused = false;
        const cx = xcbConn(self.connection orelse return);
        _ = c.xcb_set_input_focus(
            cx,
            c.XCB_INPUT_FOCUS_POINTER_ROOT,
            self.parent_window,
            c.XCB_CURRENT_TIME,
        );
        _ = c.xcb_flush(cx);
    }

    pub fn updateLayout(self: *Terminal, x: u32, y: u32, width: u32, height: u32, font: *const FontFace) void {
        _ = font;
        self.x = x;
        self.y = y;
        self.width = width;
        self.height = height;

        if (self.child_window != 0 and self.visible) {
            const cx = xcbConn(self.connection orelse return);
            const child_y = y + 2; // separator
            const child_h = if (height > 2) height - 2 else 1;
            const mask: u16 = c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y |
                c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT;
            const values = [_]u32{
                x,
                child_y,
                @max(width, 1),
                @max(child_h, 1),
            };
            _ = c.xcb_configure_window(cx, self.child_window, mask, &values);
            _ = c.xcb_flush(cx);
        }
    }

    pub fn pixelHeight(self: *const Terminal, font: *const FontFace) u32 {
        if (!self.visible) return 0;
        return self.height_rows * font.cell_height + 2; // +2 for separator
    }

    pub fn render(self: *const Terminal, renderer: *Renderer, font: *FontFace) void {
        _ = font;
        if (!self.visible) return;

        // Only draw the separator line -- the embedded terminal renders itself
        const separator_color = Color.fromHex(0x585b70);
        renderer.fillRect(self.x, self.y, self.width, 2, separator_color);
    }

    pub fn containsPoint(self: *const Terminal, px: i32, py: i32) bool {
        if (!self.visible) return false;
        return px >= @as(i32, @intCast(self.x)) and
            px < @as(i32, @intCast(self.x + self.width)) and
            py >= @as(i32, @intCast(self.y)) and
            py < @as(i32, @intCast(self.y + self.height));
    }

    /// Check if child process is still alive; clean up zombie if not
    pub fn checkChild(self: *Terminal) void {
        const pid = self.pid orelse return;
        const result = posix.waitpid(pid, posix.W{ .NOHANG = true });
        if (result.pid != 0) {
            // Child exited
            self.pid = null;
        }
    }

    // ── Internal helpers ──────────────────────────────────────────────

    fn killChild(self: *Terminal) void {
        if (self.pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
            _ = posix.waitpid(pid, 0);
            self.pid = null;
        }
    }

    fn destroyChildWindow(self: *Terminal) void {
        if (self.child_window != 0) {
            if (self.connection) |raw| {
                const cx = xcbConn(raw);
                _ = c.xcb_destroy_window(cx, self.child_window);
                _ = c.xcb_flush(cx);
            }
            self.child_window = 0;
        }
    }

};

// ── Helpers ──────────────────────────────────────────────────────────

/// Determine the embed flag for a terminal by name.
/// st: -w, alacritty: --embed, xterm: -into, default: -w
fn embedFlag(cmd_name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, cmd_name, "alacritty")) return "--embed";
    if (std.mem.endsWith(u8, cmd_name, "xterm")) return "-into";
    // st, uxterm, and most others use -w
    return "-w";
}
