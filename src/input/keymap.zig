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
    // Line operations
    duplicate_line,
    move_line_up,
    move_line_down,
    delete_line,
    // Multi-cursor
    select_next_occurrence,
    select_all_occurrences,
    escape,
    // Find & Replace
    find_replace,
    // LSP
    goto_definition,
    hover,
    trigger_completion,
    format_document,
    // Panes
    split_vertical,
    split_horizontal,
    focus_next_pane,
    close_pane,
    // Sidebar
    toggle_sidebar,
    // Terminal
    toggle_terminal,
    // Project search
    find_in_project,
    // Symbol navigation
    goto_symbol,
    // Code folding
    toggle_fold,
    // Minimap
    toggle_minimap,
    // Toggle comment
    toggle_comment,
    // Select line
    select_line,
    // Word wrap
    toggle_word_wrap,
    // LSP: rename, code actions, references
    rename_symbol,
    code_action,
    goto_references,
    // Word deletion
    delete_word_left,
    delete_word_right,
    // Join lines
    join_lines,
    // Insert line above/below
    insert_line_below,
    insert_line_above,
    // Theme switcher
    switch_theme,
    // Indent/outdent
    outdent_lines,
    // File navigation
    goto_file_start,
    goto_file_end,
    // Scroll without cursor
    scroll_up,
    scroll_down,
    // Bracket matching
    goto_matching_bracket,
    // Smart selection expand/shrink
    expand_selection,
    shrink_selection,
    // Sort lines
    sort_lines_asc,
    sort_lines_desc,
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
        // Ctrl+Backspace / Ctrl+Delete -> word deletion
        if (keysym == Window.XK_BackSpace) return .delete_word_left;
        if (keysym == Window.XK_Delete) return .delete_word_right;
        // Ctrl+Tab -> next tab
        if (keysym == Window.XK_Tab) return .next_tab;
        // Ctrl+Home / Ctrl+End -> file start/end
        if (keysym == Window.XK_Home) return .goto_file_start;
        if (keysym == Window.XK_End) return .goto_file_end;
        // Ctrl+Up / Ctrl+Down -> scroll without moving cursor
        if (keysym == Window.XK_Up) return .scroll_up;
        if (keysym == Window.XK_Down) return .scroll_down;
        // Ctrl+\ -> split vertical
        if (keysym == Window.XK_backslash) return .split_vertical;
        // Ctrl+` -> toggle terminal
        if (keysym == Window.XK_grave) return .toggle_terminal;
        // Ctrl+Space -> trigger completion
        if (keysym == ' ') return .trigger_completion;
        // Ctrl+/ -> toggle comment
        if (keysym == '/') return .toggle_comment;
        // Ctrl+. -> code action
        if (keysym == '.') return .code_action;
        // Ctrl+Enter -> insert line below
        if (keysym == Window.XK_Return) return .insert_line_below;
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
            'h' => .find_replace,
            'd' => .select_next_occurrence,
            'g' => .goto_line,
            'j' => .join_lines,
            'l' => .select_line,
            'm' => .goto_matching_bracket,
            else => null,
        };
    }
    if (mods == .ctrl_shift) {
        // Ctrl+Shift+Up/Down -> expand/shrink selection
        if (keysym == Window.XK_Up) return .expand_selection;
        if (keysym == Window.XK_Down) return .shrink_selection;
        // Ctrl+Shift+Enter -> insert line above
        if (keysym == Window.XK_Return) return .insert_line_above;
        // Ctrl+Shift+Tab -> prev tab (XK_ISO_Left_Tab = 0xFE20)
        if (keysym == Window.XK_Tab or keysym == Window.XK_ISO_Left_Tab) return .prev_tab;
        // Ctrl+Shift+\ (often produces | keysym) -> split horizontal
        if (keysym == Window.XK_bar or keysym == Window.XK_backslash) return .split_horizontal;
        // Ctrl+Shift+[ -> toggle fold
        if (keysym == Window.XK_bracketleft or keysym == '{') return .toggle_fold;
        return switch (keysym) {
            'z', 'Z' => .redo,
            'p', 'P' => .command_palette,
            'd', 'D' => .duplicate_line,
            'k', 'K' => .delete_line,
            'f', 'F' => .find_in_project,
            'i', 'I' => .format_document,
            'l', 'L' => .select_all_occurrences,
            'o', 'O' => .goto_symbol,
            'w', 'W' => .close_pane,
            else => null,
        };
    }
    if (mods == .alt) {
        // Alt+\ -> focus next pane
        if (keysym == Window.XK_backslash) return .focus_next_pane;
        // Alt+Up/Down -> move line up/down
        if (keysym == Window.XK_Up) return .move_line_up;
        if (keysym == Window.XK_Down) return .move_line_down;
        // Alt+Z -> toggle word wrap
        if (keysym == 'z' or keysym == 'Z') return .toggle_word_wrap;
    }

    // Shift+arrow = selection, Shift+F12 = goto references
    if (mods == .shift) {
        // Shift+Tab -> outdent lines
        if (keysym == Window.XK_ISO_Left_Tab or keysym == Window.XK_Tab) return .outdent_lines;
        return switch (keysym) {
            Window.XK_Left => .select_left,
            Window.XK_Right => .select_right,
            Window.XK_Up => .select_up,
            Window.XK_Down => .select_down,
            Window.XK_Home => .select_home,
            Window.XK_End => .select_end,
            Window.XK_F12 => .goto_references,
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
        Window.XK_F2 => .rename_symbol,
        Window.XK_F11 => .hover,
        Window.XK_F12 => .goto_definition,
        else => null,
    };
}
