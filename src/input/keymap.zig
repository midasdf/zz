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
    // Overlay modes
    command_palette,
    finder_files,
    find,
    goto_line,
    // Tabs
    next_tab,
    prev_tab,
    close_tab,
    // Multi-cursor
    select_next_occurrence,
    select_all_occurrences,
    escape,
    // LSP
    goto_definition,
    hover,
    // Panes
    split_vertical,
    split_horizontal,
    focus_next_pane,
    close_pane,
    // Sidebar
    toggle_sidebar,
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
        // Ctrl+Tab -> next tab
        if (keysym == Window.XK_Tab) return .next_tab;
        // Ctrl+\ -> split vertical
        if (keysym == Window.XK_backslash) return .split_vertical;
        const k = if (keysym >= 'A' and keysym <= 'Z') keysym + 32 else keysym;
        return switch (k) {
            'a' => .select_all,
            'b' => .toggle_sidebar,
            'c' => .copy,
            'x' => .cut,
            'v' => .paste,
            'z' => .undo,
            's' => .save,
            'q' => .quit,
            'w' => .close_tab,
            'p' => .finder_files,
            'f' => .find,
            'd' => .select_next_occurrence,
            'g' => .goto_line,
            else => null,
        };
    }
    if (mods == .ctrl_shift) {
        // Ctrl+Shift+Tab -> prev tab (XK_ISO_Left_Tab = 0xFE20)
        if (keysym == Window.XK_Tab or keysym == Window.XK_ISO_Left_Tab) return .prev_tab;
        // Ctrl+Shift+\ (often produces | keysym) -> split horizontal
        if (keysym == Window.XK_bar or keysym == Window.XK_backslash) return .split_horizontal;
        return switch (keysym) {
            'z', 'Z' => .redo,
            'p', 'P' => .command_palette,
            'l', 'L' => .select_all_occurrences,
            'w', 'W' => .close_pane,
            else => null,
        };
    }
    if (mods == .alt) {
        // Alt+\ -> focus next pane
        if (keysym == Window.XK_backslash) return .focus_next_pane;
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
        Window.XK_Escape => .escape,
        Window.XK_F12 => .goto_definition,
        else => null,
    };
}
