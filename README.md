# zz

> **WIP** — This project is under active development. Expect bugs, missing features, and breaking changes.

A lightweight, fast code editor written in Zig. No AI, no telemetry, no bloat.

```
 ┌─ zz ──────────────────────────────────────────────┐
 │ [main.zig] [view.zig] [+]                         │
 ├─ ▾ src/    ─┬──────────────────────────────────────┤
 │   ▾ editor/ │  1 │ const std = @import("std");     │
 │     buffer  │  2 │                                 │
 │     cursor  │  3 │ pub fn main() !void {           │
 │     view    │  4 │     // ...                      │
 │   ▾ ui/     │  5 │ }                               │
 │     window  │                                      │
 │     font    ├──────────────────────────────────────┤
 │     render  │  master │ Zig │ Ln 3, Col 5 │ UTF-8  │
 ├─────────────┼──────────────────────────────────────┤
 │ $ zig build                                        │
 │ Build succeeded.                                   │
 └────────────────────────────────────────────────────┘
```

## Why

- **VS Code / Zed**: Feature-rich but heavy, ships AI and telemetry
- **Neovim / Helix**: Fast but no native GUI, no mouse-first UX
- **zz**: Fast GUI editor with zero telemetry. 3MB binary, 18MB RAM, idle CPU 0%

## Features

### Editor Core
- **Piece Table** buffer with O(1) insert and undo/redo coalescing
- **Multi-cursor** editing (Ctrl+D, Ctrl+Shift+L)
- **Split panes** (vertical/horizontal, binary tree layout)
- **Tabs** with multi-file editing
- **Auto-indent** on Enter (copies whitespace, extra indent after `{`)
- **Line operations** (duplicate, move up/down, delete)
- **Bracket matching** with highlight and auto-closing
- **Word occurrence highlighting** on cursor
- **Indent guides** (vertical lines at tab stops)
- **Trailing whitespace** visualization and trim-on-save
- **Smart selection** (Ctrl+Shift+Up/Down expand/shrink)
- **4 themes**: Catppuccin Mocha, Tokyo Night, Gruvbox Dark, One Dark
- **UTF-8** with CJK wide character support
- **XIM/fcitx5** input method for Japanese/Chinese

### Rendering
- **xcb + SHM** direct framebuffer (no GPU, no compositor dependency)
- **FreeType** font rendering with glyph cache (ASCII pre-rendered)
- **Catppuccin Mocha** theme with syntax-colored highlights
- **Dirty region** tracking (only re-renders changed rows)
- **Event-driven** rendering (0% CPU when idle)

### IDE
- **Tree-sitter** syntax highlighting (C, Python, Rust, JavaScript, Bash)
- **LSP** integration (zls, clangd, rust-analyzer auto-detected)
- **Diagnostics** underlines (error/warning/info severity colors)
- **F12** go-to-definition (same file jump + cross-file open)
- **Ctrl+P** fuzzy file finder (.gitignore aware)
- **Ctrl+Shift+P** command palette
- **Ctrl+F** text search with wrap-around
- **Ctrl+H** find and replace
- **Ctrl+Shift+F** search across project files
- **Ctrl+Shift+O** go to symbol (LSP document symbols)
- **Code folding** (Ctrl+Shift+[) with bracket matching
- **Minimap** code overview with syntax colors
- **F2** rename symbol, **Ctrl+.** code actions, **Shift+F12** references
- **LSP signature help** (auto-trigger on `(` and `,`)
- **F8** / **Shift+F8** navigate diagnostics

### Extras
- **File tree** sidebar (Ctrl+B) with expand/collapse
- **Git** branch name + diff gutter (added/modified/deleted markers)
- **Embedded terminal** (Ctrl+\`) with full VT parser, xterm-256color, ANSI/truecolor

## Requirements

Arch Linux x86_64 with:

```bash
# Build dependencies
sudo pacman -S zig

# Runtime dependencies (most already installed on a desktop system)
sudo pacman -S libxcb xcb-util-xrm xkbcommon xcb-imdkit freetype2

# Tree-sitter (syntax highlighting)
sudo pacman -S tree-sitter tree-sitter-c tree-sitter-python tree-sitter-rust tree-sitter-javascript tree-sitter-bash

# LSP servers (optional, for IDE features)
sudo pacman -S zls               # Zig
# clangd included with clang
# rust-analyzer included with rustup
```

## Build

```bash
git clone https://github.com/midasdf/zz.git
cd zz
zig build                        # Debug build
zig build -Doptimize=ReleaseFast  # Release build (~4MB)
```

## Usage

```bash
./zig-out/bin/zz                  # New empty buffer
./zig-out/bin/zz file.zig         # Open a file
./zig-out/bin/zz src/main.zig     # Edit your own source
```

## Keybindings

| Key | Action |
|-----|--------|
| **File** | |
| Ctrl+S | Save |
| Ctrl+P | Fuzzy file finder |
| Ctrl+Q | Quit |
| **Edit** | |
| Ctrl+Z | Undo |
| Ctrl+Shift+Z | Redo |
| Ctrl+C / X / V | Copy / Cut / Paste |
| Ctrl+A | Select all |
| Ctrl+D | Select next occurrence |
| Ctrl+Shift+L | Select all occurrences |
| Esc | Collapse multi-cursor |
| **Navigate** | |
| Ctrl+G | Go to line |
| Ctrl+F | Find |
| Ctrl+Shift+P | Command palette |
| F12 | Go to definition |
| **View** | |
| Ctrl+Tab | Next tab |
| Ctrl+Shift+Tab | Previous tab |
| Ctrl+W | Close tab |
| Ctrl+\\ | Split vertical |
| Ctrl+Shift+\\ | Split horizontal |
| Ctrl+B | Toggle file tree |
| Ctrl+\` | Toggle terminal |
| **Search** | |
| Ctrl+Shift+F | Search in project |
| Ctrl+H | Find & replace |
| **Code** | |
| Ctrl+Space | Trigger completion |
| Ctrl+Shift+I | Format document |
| Ctrl+Shift+D | Duplicate line |
| Alt+Up / Down | Move line up / down |
| Ctrl+Shift+K | Delete line |
| Ctrl+Shift+O | Go to symbol |
| Ctrl+Shift+[ | Toggle code fold |
| Ctrl+/ | Toggle line comment |
| Ctrl+L | Select line |
| Ctrl+J | Join lines |
| Ctrl+Enter | Insert line below |
| Ctrl+Shift+Enter | Insert line above |
| F2 | Rename symbol |
| Ctrl+. | Code actions |
| Shift+F12 | Go to references |
| F8 / Shift+F8 | Next / prev diagnostic |
| Ctrl+Backspace | Delete word left |
| Ctrl+Delete | Delete word right |
| Tab (selection) | Indent lines |
| Shift+Tab | Outdent lines |
| Ctrl+Home / End | Start / end of file |
| Ctrl+Up / Down | Scroll without cursor |
| Ctrl+M | Go to matching bracket |
| Ctrl+Shift+Up / Down | Expand / shrink selection |

## Architecture

```
src/
├── main.zig              Event loop, mode dispatch
├── editor/
│   ├── buffer.zig        Piece Table with undo/redo
│   ├── cursor.zig        Multi-cursor, UTF-8 movement
│   ├── view.zig          Editor rendering, diagnostics
│   ├── highlight.zig     Tree-sitter integration
│   ├── tabs.zig          Tab manager
│   └── panes.zig         Split pane binary tree
├── ui/
│   ├── window.zig        xcb + SHM, keyboard, clipboard, XIM
│   ├── font.zig          FreeType glyph cache
│   ├── render.zig        Pixel rendering (BGRA32)
│   ├── overlay.zig       Command palette / finder popup
│   ├── file_tree.zig     Directory tree sidebar
│   └── terminal_zt.zig   Embedded terminal (powered by zt)
├── lsp/
│   └── client.zig        LSP JSON-RPC client
├── core/
│   ├── fuzzy.zig         Fuzzy matching algorithm
│   ├── file_walker.zig   Directory walker (.gitignore)
│   └── git.zig           Git branch + diff info
└── input/
    └── keymap.zig        Keybind mapping
```

**~16,000 lines of Zig. Single Zig dependency: [zt](https://github.com/midasdf/zt) — embedded terminal VT/PTY engine.**

All rendering is CPU-based (xcb shared memory). No GPU, no OpenGL, no Wayland (yet). Single-threaded epoll event loop. The only subprocess communication is with LSP servers (JSON-RPC over stdin/stdout) and the embedded terminal (PTY).

## Stats

| Metric | Value |
|--------|-------|
| Binary (ReleaseFast) | 4.1 MB |
| Binary (ReleaseSmall + strip) | ~240 KB |
| Memory (RSS) | ~18 MB |
| Idle CPU | 0% |
| Startup time | Instant (mmap + single piece) |
| Source lines | ~16,000 |
| Dependencies (Zig packages) | 0 |

## License

MIT

## Disclaimer
This project uses AI-generated code (LLM). I do my best to review and test it, but I can't guarantee it's perfect. Please use it at your own risk.\n