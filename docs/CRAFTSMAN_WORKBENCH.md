# Craftsman Workbench & Co-Pilot User Manual

> **Sovereign In-Browser IDE & Autonomic Development Cockpit**  
> **Component**: `web/static/` & `web/src/main.rs`  
> **Last Updated**: September 2026

---

## 1. Overview & Industrial Design Philosophy

The Craftsman Workbench is an in-browser code editor and pair-programming cockpit designed under Tony Fadell hardware principles: high-contrast dark palette, razor-sharp hairline borders, zero latency, uncluttered breathing room, and strict geometric proportionality.

Operators can read, refactor, and write workspace code with zero dependencies on external IDEs, backed by local GPU inference through George Co-Pilot.

---

## 2. Geometric Layout Rules & 88-Column Minimum

To guarantee readability for complex shell scripts and systems code without premature line wrapping:

1. **88-Column Floor**: Every active code editor pane enforces a minimum width of 88 monospace columns (`~88ch + 104px` for line-number gutters, margins, and scrollbars $\approx 755\text{px}$).
2. **Dynamic Container Expansion**:
   - The workbench modal container expands dynamically as layout tools are opened:
     - Default single-pane width: $\ge 1,000\text{px}$.
     - Opening File Explorer sidebar: expands $+240\text{px}$.
     - Opening George Co-Pilot drawer: expands $+400\text{px}$.
     - Maximum width scales up to full viewport width (`window.innerWidth - 32px`).
3. **Dual-Pane Side-by-Side Tiling (`[ ◫ SPLIT ]`)**:
   - Toggling `◫ SPLIT` instantiates Left (`#editorPaneLeft`) and Right (`#editorPaneRight`) panes separated by an adjustable vertical divider (`#editorPaneSplitter`).
   - The right pane includes a dedicated tab selector (`#paneRightTabSelect`) to edit two files side-by-side or inspect different sections of the same file.
   - **Asymmetric Resize Rule**: An operator can manually shrink one window below 88 columns *only* if the other window expands to take up the space, ensuring that at least one window maintains $\ge 88$ columns.

---

## 3. Ported Vim Engine & Command Reference

The built-in Craftsman editor includes a native zero-latency JavaScript Vim emulation layer.

### Modes
- **NORMAL Mode**: Press `Esc` to enter command mode. Cursor turns into a block; status line displays `-- NORMAL --` and the header badge glows amber (`VIM: NORMAL`).
- **INSERT Mode**: Press `i` or `a` to enter text input mode. Status line displays `-- INSERT --` and the header badge turns green (`VIM: INSERT`).

### Motions & Navigation
| Key | Action | Description |
| :--- | :--- | :--- |
| `gg` | Jump to Start | Moves cursor to line 1 and scrolls to top. |
| `G` | Jump to End | Moves cursor to the last line and scrolls to bottom. |
| `gf` | Go to File | Detects file reference, `source` path, or module under cursor and opens it in a new tab. |
| `gt` | Next Tab | Cycles forward to the next open buffer tab. |
| `gT` | Previous Tab | Cycles backward to the previous buffer tab. |
| `0` / `$` | Line Boundaries | Jumps to start / end of current line. |

### Line & Clipboard Operations
| Key | Action | Description |
| :--- | :--- | :--- |
| `dd` | Delete Line | Deletes the current line and sets buffer dirty. |
| `yy` | Yank Line | Copies the current line directly to the system clipboard. |
| `Ctrl+S` | Quick Save | Instantly saves active buffer and triggers `bash -n` syntax check. |
| `Tab` | 2-Space Soft Tab | Indents by 2 spaces in Insert mode. |

### Delimiter Manipulation (`vim-surround`)
| Key Pattern | Action | Example |
| :--- | :--- | :--- |
| `cs<old><new>` | Change Surround | `cs"'` replaces `"hello"` with `'hello'`. |
| `ds<char>` | Delete Surround | `ds"` strips quotes from `"hello"` $\to$ `hello`. |
| `ysiw<char>` | Surround Inner Word | `ysiw"` wraps current word in quotes `word` $\to$ `"word"`. |

### Ex-Commands (`:`)
| Command | Action | Dirty State Behavior |
| :--- | :--- | :--- |
| `:w` | Write / Save | Runs `bash -n` validation and saves buffer. |
| `:w!` | Force Write | Bypasses non-critical checks and saves buffer. |
| `:q` | Quit Buffer | Closes active tab. If unsaved changes exist, displays error `E37: No write since last change (add ! to override: :q!)`. |
| `:q!` | Force Quit | **Immediately discards unsaved changes and closes tab without prompt**. If last tab, closes modal. |
| `:wq` / `:x` | Save & Close | Validates, saves buffer, and closes active tab. |
| `:bd` / `:bd!` | Buffer Delete | Closes / force-closes active buffer tab. |
| `:qa` | Quit All | Closes all tabs. Blocks if any tab has unsaved changes. |
| `:qa!` | Force Quit All | Discards all changes and closes workbench modal immediately. |
| `:tabnew` | New Tab | Opens a new blank script buffer. |
| `:e <path>` | Edit File | Opens specified file path in a new tab. |
| `:help` / `:h` | Help | Opens the 3-column Vim Command Reference Legend dropdown. |

---

## 4. George Co-Pilot & Autonomic Steering

The George Co-Pilot drawer provides continuous pair-programming capabilities powered by the local PRISM inference model:

1. **Auto-Expanding Multiline Prompt Area**:
   - The prompt input (`#copilotPromptInput`) expands dynamically on focus and typing (from 1 line to up to 5 lines), allowing operators to review multi-line refactoring prompts comfortably.
2. **Autonomic Task Bay Integration**:
   - Every refactor request registers a first-class autonomic task pill in the top rail (`#autonomicTaskBay`).
   - A collapsible `GEORGE TASK` blueprint card renders in the Co-Pilot drawer with real-time SSE monologue streaming (`reasoning_content`) and progress dials.
3. **Operator Intervention & Controls**:
   - **Row 1**: Full-width steering guidance input area.
   - **Row 2**:
     - `[ ⚡ INJECT GUIDANCE ]`: Sends immediate steering prompt into the running sandbox.
     - `[ ⏸ PAUSE / ▶ RESUME ]`: Freezes / thaws process execution.
     - `[ ✕ TERMINATE ]`: Requires double-click confirmation (`[ CONFIRM KILL? ]`) to terminate child process trees and remove sandbox immediately.
4. **Interactive Unified & Split Diff Viewer**:
   - Proposed code modifications render in a side-by-side or unified diff viewer with syntax highlighting.
   - Operators can click `[ ✓ APPLY DIFF ]` to write changes or `[ ✕ REJECT ]` to discard.

---

## 5. Dual-Engine Architecture: Craftsman DOM vs. Neovim PTY

Operators can switch between two complementary execution engines via the statusbar toggle:

1. **CRAFTSMAN Engine**: Zero-latency DOM textarea with custom syntax highlighting, instant input response, and integrated visual diff viewer. Best for quick edits and guided AI refactorings.
2. **NEOVIM Engine**: Native Linux Neovim PTY process streaming over WebSockets to an xterm.js terminal. Runs operator's personal `init.lua`, tree-sitter plugins, and full terminal tooling.
