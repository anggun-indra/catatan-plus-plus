# catatan++ (Notepad++ for macOS — native port)

A native Apple Silicon build of Notepad++'s editor engine. No Wine, no emulation.

**Status:** working editor. Not a full Notepad++ feature port — see *What is and isn't ported*.

## Build

```bash
./build.sh
open dist/Catatan++.app
```

Produces `dist/Catatan++.app` (arm64, ~4.0 MB).

Requirements: Xcode command line tools. Nothing else.

## How it works

Notepad++ itself is Win32-only (985 `HWND` uses, 70 dialog templates in 3504 lines of `.rc`).
But its editing engine is not Windows-specific, and upstream already ships a native macOS
backend for it. This port keeps the engine and replaces only the Windows shell.

| Layer | Source | Status |
|---|---|---|
| Text engine (Scintilla) | `src/scintilla/src` + `src/scintilla/cocoa` | Reused as-is |
| Syntax highlighting (Lexilla) | `src/lexilla/lexers` — 142 lexers | Reused as-is |
| Generated tables | `tools/gen.py` | Reads upstream XML/C++, emits the four data files |
| Keywords | `PowerEditor/src/langs.model.xml` | Generated → `KeywordMap` |
| Colour themes | `PowerEditor/src/stylers.model.xml` | Generated → `Theme.c` |
| Language/extension table | `PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp` | Generated → `LexerMap.m` |
| Win32 GUI shell (11 MB, 158k lines) | `PowerEditor/src` | **Rewritten in Cocoa** |

The three generated files are built from upstream data, not hand-written, so the port stays
faithful to Notepad++'s own definitions rather than inventing new ones.

### The one shim

`shim/windows.h` exists only because `LexUser.cxx` (Lexilla's user-defined-language lexer)
includes `<windows.h>` while using nothing from it except `_itoa`. The shim provides `_itoa`
and nothing else.


## Active line highlighting

The current line is highlighted the same way Notepad++ does it: set the
caret-line **background** and let Scintilla track which line that is. The
default colour is Notepad++'s own `E8E8FF`. Text is never recoloured.

An earlier version recoloured the active line's glyphs to white with an
`INDIC_TEXTFORE` indicator. That needed its own bookkeeping to clear the old
line, and pressing Enter reset that bookkeeping while leaving the indicator
behind — so old lines kept white text on a white background and appeared blank.
Removing the recolouring removed the whole class of bug.

Two Scintilla details still matter:

- `SCI_SETCARETLINEBACK`, `SCI_SETCARETLINEBACKALPHA` and
  `SCI_SETCARETLINEVISIBLEALWAYS` take their argument in **wParam**, not lParam.
  `setColorProperty:` / `setGeneralProperty:` send lParam, so they silently did
  nothing. They are sent with `message:wParam:`.
- Those raw colour paths expect Windows `COLORREF` order (`0x00BBGGRR`), not
  `0xRRGGBB`; `BGRFromRGB()` converts. Without it a colour comes out wrong.

## Toolbar

The toolbar reproduces Notepad++'s `toolBarIcons[]` table from `Notepad_Plus.cpp`:
the same 32 commands in the same order, with the same 9 group separators (41
slots). Tooltips use the exact strings from
`PowerEditor/installer/nativeLang/english.xml`.

Icons are Solar **outline** icons from <https://solar-icons.dev/icons?style=outline>,
downloaded into `icons/` by `tools/fetch_icons.py` and copied into the app bundle
at `Contents/Resources/icons/`. They ship as the original SVG, which AppKit decodes
through `_NSSVGImageRep`, so they stay sharp at any scale and are tinted as
template images to follow the system appearance.

Live in this port — all 32 buttons do real work:

| Group | Behaviour |
|---|---|
| New, Open, Save, Save All, Close, Close All | working |
| Undo, Redo, Cut, Copy, Paste | working; enabled state follows `canUndo`/`canRedo`/clipboard |
| Find, Replace | working |
| Zoom In, Zoom Out | working |
| Word wrap, Show All Characters, Show Indent Guide | working toggles |
| Start/Stop Recording, Playback, Run Multiple Times, Save Macro | working; recorded via `SCN_MACRORECORD`, saved in Notepad++'s `shortcuts.xml` shape |
| Document List | panel listing open tabs; click switches |
| Folder as Workspace | real disk tree (depth 6); click opens the file |
| Function List | scans the document per language family; click jumps to the line |
| Document Map | outline with function children and a line count |
| Monitoring | `tail -f`: polls mtime, follows appends, keeps the caret at the end |
| Synchronize vertical/horizontal scrolling | works with the new split view |
| Define your language | applies a custom keyword list to the current lexer |
| Print | paginates and prints through a custom `NSPrintOperation` view |

### Printing

Scintilla's Cocoa layer has no print support — handing `ScintillaView` to
`NSPrintOperation` produces a page whose only content is `q Q`, i.e. nothing.
`PrintView` renders the text itself instead, paginating by line and stamping a
`page / total` footer. Page size is read from the live print operation, because
computing the page count before the operation exists silently yielded one page
per line.

### Split view

Required by the synchronize buttons. Two independent `ScintillaView`s show the
same buffer side by side (View > Split View). Vertical sync mirrors
`SCI_GET/SETFIRSTVISIBLELINE`; horizontal sync mirrors `SCI_GET/SETXOFFSET`,
which is clamped to the scrollable range — a short line cannot scroll sideways.

### Another wParam trap

`SCI_SETWRAPMODE`, `SCI_SETVIEWWS` and `SCI_SETINDENTATIONGUIDES` read their value
from **wParam**. The `setGeneralProperty:parameter:value:` form puts the value in
lParam, so those setters must use the single-value form. This is the same class of
bug as the caret-line one above; it was caught by the toolbar tests, which assert
the resulting Scintilla state rather than that the call was made.

## What is and isn't ported

Working:
- Multi-document tabs: custom strip, middle-truncated titles, close buttons,
  dirty indicators, click-to-switch, ⌘W / ⌘⇧] / ⌘⇧[
- Editing, undo/redo, multi-selection, column editing
- 96 selectable languages; 76 with Notepad++'s keyword lists, 93 with its palettes
- Extension → language detection (242 extensions)
- Line numbers, active-line highlight, brace matching
- Open (many files at once), save, save as, new tab; reopening focuses the
  existing tab; unsaved-changes prompt on close
- All 32 toolbar buttons (see the Toolbar section)
- Sidebar panels: Document List, Folder as Workspace, Function List, Document Map
- Split view with vertical/horizontal scroll synchronization
- `tail -f` monitoring of the active file
- Macro record / playback / multi-run / save
- Print with line-based pagination
- Find / find next

Not ported — these belong to Notepad++'s Win32 shell, not to Scintilla, so each
needs a fresh Cocoa implementation:
- Plugin system (`.dll` ABI, `NppPluginInterface`)
- Preferences dialog
- Full User Defined Language editor (the port exposes a custom-keyword dialog
  instead; upstream's UDL engine lives in `UserDefineDialog.cpp`, ~2100 lines)
- Session and backup handling
- Column editor / character panel dialogs
- Project panels 1-3
- Syntax colouring in printed output (print emits plain text)
- Find/Replace dialog is a minimal alert, not upstream's full dialog

## Verifying

```bash
dist/Catatan++.app/Contents/MacOS/Catatan++ --selftest          # exits 0 on success
dist/Catatan++.app/Contents/MacOS/Catatan++ --snapshot          # also writes PNGs to /tmp
```

Loads every language, asserts each produces styled text, then checks specific
token→style mappings against values from `stylers.model.xml`:

```
RESULT checked=96 failures=0
OK   cpp            word=int        style=16 expected=16
OK   cpp            word=//         style=2  expected=2
OK   cpp            word=#          style=9  expected=9
OK   javascript.js  word=function   style=5  expected=5
```

`style=16` means Notepad++'s `TYPE WORD` class, `5` is `INSTRUCTION WORD` — the same
distinction upstream makes when it remaps keyword-list indices for the C++ lexer.

The suite is 66 assertions and should report `SELFTEST_DONE failures=0`. It covers
the language sweep above plus: document lifecycle (multiple tabs with independent
buffers, dirty state in the title bar, reopening focuses the existing tab),
active-line behaviour while typing and after Enter, all 32 toolbar buttons and
their toggle/enable state, the sidebar panels, workspace tree, function list,
`tail -f` monitoring, macro record and playback, print pagination, split-view
scroll sync, and custom keywords.

If you are picking this project up as a new contributor, read
[HANDOFF.md](HANDOFF.md) first — it documents the architecture, the Scintilla
pitfalls that already caused shipped bugs, and what is still missing.

## Licensing

Upstream is GPLv3. This port reuses GPLv3 Scintilla/Lexilla code and Notepad++'s own
language and style data, so **the whole result is GPLv3**. If you distribute it:

- ship the complete corresponding source
- mark modified files with dates
- keep copyright and licence notices
- rename it — the "Notepad++" name and logo are not part of the licence

`src/` is a sparse, shallow clone of
[notepad-plus-plus/notepad-plus-plus](https://github.com/notepad-plus-plus/notepad-plus-plus).
