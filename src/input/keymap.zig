const std = @import("std");
const Window = @import("../ui/window.zig");

pub const Modifier = enum {
    none,
    ctrl,
    shift,
    ctrl_shift,
    alt,
};

pub const Action = enum {
    // Movement
    move_left,
    move_right,
    move_up,
    move_down,
    move_home,
    move_end,
    page_up,
    page_down,
    // Selection (shift variants)
    select_left,
    select_right,
    select_up,
    select_down,
    select_home,
    select_end,
    select_all,
    // Editing
    backspace,
    delete,
    enter,
    tab,
    // Clipboard
    copy,
    cut,
    paste,
    // Undo
    undo,
    redo,
    // File
    save,
    quit,
};

pub fn modFromWindow(mods: Window.Modifiers) Modifier {
    if (mods.ctrl and mods.shift) return .ctrl_shift;
    if (mods.ctrl) return .ctrl;
    if (mods.shift) return .shift;
    if (mods.alt) return .alt;
    return .none;
}

/// Map an XKB keysym + modifiers to an editor action.
pub fn mapKey(keysym: u32, mods: Modifier) ?Action {
    // Ctrl+key bindings (normalize to lowercase for CapsLock compat)
    if (mods == .ctrl) {
        const k = if (keysym >= 'A' and keysym <= 'Z') keysym + 32 else keysym;
        return switch (k) {
            'a' => .select_all,
            'c' => .copy,
            'x' => .cut,
            'v' => .paste,
            'z' => .undo,
            's' => .save,
            'q' => .quit,
            else => null,
        };
    }
    if (mods == .ctrl_shift) {
        return switch (keysym) {
            'z', 'Z' => .redo,
            else => null,
        };
    }

    // Shift+arrow = selection
    if (mods == .shift) {
        return switch (keysym) {
            Window.XK_Left => .select_left,
            Window.XK_Right => .select_right,
            Window.XK_Up => .select_up,
            Window.XK_Down => .select_down,
            Window.XK_Home => .select_home,
            Window.XK_End => .select_end,
            else => null,
        };
    }

    // No modifier (or alt)
    return switch (keysym) {
        Window.XK_Left => .move_left,
        Window.XK_Right => .move_right,
        Window.XK_Up => .move_up,
        Window.XK_Down => .move_down,
        Window.XK_Home => .move_home,
        Window.XK_End => .move_end,
        Window.XK_Page_Up => .page_up,
        Window.XK_Page_Down => .page_down,
        Window.XK_BackSpace => .backspace,
        Window.XK_Delete => .delete,
        Window.XK_Return => .enter,
        Window.XK_Tab => .tab,
        else => null,
    };
}
