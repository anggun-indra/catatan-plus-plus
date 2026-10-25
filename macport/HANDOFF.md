# Handoff — Notepad++ for macOS (native port)

Written for the next agent picking this up. Everything below was verified in this
repository on 2026-10-25; anything not verified is marked as such.

---

## 1. What this is

A native Apple Silicon port of the **Notepad++ editor**, not a wrapper.

Notepad++ itself is Win32-only: ~158k lines in `PowerEditor/src`, 985 `HWND`
uses, 70 dialog templates across 3,504 lines of `.rc`. None of that compiles on
macOS. But the editor engine is portable, and upstream already ships a native
macOS backend for it. So the port:

- **keeps** Scintilla (text engine) and Lexilla (142 registered lexers) unchanged
- **keeps** Notepad++'s own language/style data, consumed from upstream files
- **replaces** the entire Win32 shell with a new Cocoa application

Result: a 4.0 MB arm64 `.app` that opens, edits, highlights, and has a working
toolbar.

**No Wine, no emulation, no Rosetta.**

---

## 2. Where things are

```
/Users/nb-mac-fj2n0x/Work/wproject/notepad++/
├── src/                        upstream clone (NOT in git, see §3)
│   ├── scintilla/              text engine + cocoa backend
│   ├── lexilla/                141 files → 142 lexers
│   └── PowerEditor/            upstream Win32 app (reference only, never built)
└── macport/                    ← all port work lives here
    ├── build.sh                builds the .app, no network needed
    ├── README.md               user-facing docs
    ├── HANDOFF.md              this file
    ├── icons/                  32 Solar outline SVGs (see §6)
    ├── shim/windows.h          the only Windows shim (3 lines of real content)
    ├── tools/gen.py            regenerates the 4 data tables from upstream
    ├── tools/fetch_icons.py    re-downloads icons from Iconify
    └── src/                    the port's own code (~4,000 lines)
        ├── main.mm             2,603  app, tabs, docs, panels, actions, self-test
        ├── Toolbar.m/.h          336  toolbar view + 32-command table
        ├── Sidebar.m/.h          165  docked panel with outline list
        ├── PrintView.m/.h        140  paginated print rendering
        ├── Keywords.c            556  GENERATED — 76 languages of keywords
        ├── Theme.c             2,158  GENERATED — 93 colour palettes
        ├── LexerMap.m            387  GENERATED — 96 langs, 242 extensions
        └── LangFromExt.m         259  GENERATED — extension → language
```

### Not in version control

The project is **not a git repository**. There is no commit history to inherit.
If you want one, initialise it yourself — but read §10 (licensing) first, because
`src/` is GPLv3 upstream code and the port is a derivative work.

---

## 3. The upstream clone in `src/`

Sparse + shallow, created with:

```bash
git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/notepad-plus-plus/notepad-plus-plus.git src
cd src && git sparse-checkout set scintilla lexilla PowerEditor/src
```

- Pinned at `cda2acf54b3f68d51753e4fb3fe7789615e909bf` (2026-10-24)
- Present paths: `PowerEditor/bin`, `PowerEditor/installer`, `PowerEditor/src`,
  `lexilla`, `scintilla`
- 52 MB on disk

`PowerEditor/src` is **never compiled**. It is read only as the source of truth
for language tables, style palettes and tooltips.

---

## 4. Build and run

```bash
cd macport
./build.sh                          # ~3-4 min, fully offline
open dist/Catatan++.app
```

Requirements: Xcode command line tools only (verified with Apple clang 21, SDK 27,
macOS 26.6.2 on arm64). No CMake, no Ninja, no Homebrew packages.

`build.sh` compiles Scintilla core (33 files) → Cocoa layer (4) → Lexilla (141 files)
→ port sources → links → assembles the bundle → copies icons → ad-hoc codesigns.

### Verification entry points

```bash
dist/Catatan++.app/Contents/MacOS/Catatan++ --selftest   # 66 assertions, exit 0/1
dist/Catatan++.app/Contents/MacOS/Catatan++ --snapshot   # also writes PNGs to /tmp
NPP_REPORT_TABS=1 .../Catatan++ a.cpp b.py               # prints tab count, exits
.../Catatan++ file1 file2                                # normal GUI launch
```

Current state: **66 OK, 0 FAIL**. The self-test is the regression suite — if you
change anything, run it. It covers: language sweep (96 langs), keyword/colour
correctness, active-line behaviour, multi-tab lifecycle, toolbar layout and every
action, panels, workspace tree, function list, monitoring, macro, print,
split-view sync, custom keywords.

Sections are printed with `== name ==` headers, so a failure tells you the area.

---

## 4b. Five-minute onboarding

If you have just been handed this and want confidence before changing anything:

```bash
cd macport
./build.sh                                   # expect "==> Done: .../Catatan++.app"
dist/Catatan++.app/Contents/MacOS/Catatan++ --selftest | tail -3
#   expect: SELFTEST_DONE failures=0 / SELFTEST_EXIT failures=0
dist/Catatan++.app/Contents/MacOS/Catatan++ --selftest | grep -c '^OK  '   # expect 66
open dist/Catatan++.app                      # sanity-check the GUI by eye
```

Then read, in this order:
1. `src/main.mm` — the `Application` section (`#pragma mark Documents` onwards).
   Start at `makeEditor`, `showDocumentAtIndex:`, `toolbar:didActivateItemAtIndex:`.
2. `src/Toolbar.m` — the `kItems[]` table; every button is one row.
3. `tools/gen.py` — how the four generated files are produced.

Do **not** start by reading `PowerEditor/src`. It is 158k lines of Win32 you will
never build; dip into it only to look up a specific constant or string.

---

## 5. Architecture you must understand

### Document model

`EditorDocument` = one `ScintillaView` + path + language + dirty flag. Tabs are a
`NSMutableArray<EditorDocument *>` in `AppDelegate`; `activeIndex` selects one.

`showDocumentAtIndex:` swaps the view into `editorContainer`. **Only the active
document's view is in the hierarchy** — every other document keeps its view alive
but detached. This is why closing a tab does not lose the neighbour's text.

### Notification bridge

Each document owns a `DocNotifier` (implements `ScintillaNotificationProtocol`)
with a block handler, so notifications route to the right document instead of a
single global delegate.

### Generated data — do not hand-edit

`Keywords.c`, `Theme.c`, `LexerMap.m`, `LangFromExt.m` are produced by
`tools/gen.py` from upstream sources:

| Generated | Read from |
|---|---|
| `Keywords.c` | `PowerEditor/src/langs.model.xml` `<Keywords>` |
| `Theme.c` | `PowerEditor/src/stylers.model.xml` `<WordsStyle>` |
| `LexerMap.m` | `langs.model.xml` extensions + `ScintillaEditView.cpp` `_langNameInfoArray` |
| `LangFromExt.m` | extension → language name from `langs.model.xml` |

Regenerate with `python3 tools/gen.py`. It expects `../src` to exist. Verified
idempotent — regenerating produces byte-identical output.

### The one Windows shim

`shim/windows.h` exists solely because Lexilla's `LexUser.cxx` includes
`<windows.h>` while using nothing from it except `_itoa`. The shim provides
`_itoa` and nothing else. If you extend the port, resist adding to it.

---

## 6. Icons

32 Solar **outline** icons from <https://solar-icons.dev/icons?style=outline>,
fetched through the Iconify API and stored as original SVG.

- Files: `icons/<command>.svg` — one per toolbar command
- Mapping: `ICONS` list in `tools/fetch_icons.py`
- Re-fetch: `python3 tools/fetch_icons.py` (needs network; retries, idempotent)
- Runtime: copied to `Contents/Resources/icons/`, loaded via `NSImage`, which
  AppKit decodes through `_NSSVGImageRep` — **vector, stays sharp at any scale**,
  and `template = YES` so glyphs follow the system appearance.

---

## 7. Bug classes this port already hit — read before touching Scintilla

This is the highest-value section. Each item below cost real debugging time.

### (a) `wParam` vs `lParam` — the recurring trap

Scintilla setters differ in which parameter carries the value. The Cocoa wrapper
maps:

```objc
setGeneralProperty:parameter:value:  →  WndProc(msg, parameter, value)   // wParam, lParam
setGeneralProperty:value:            →  WndProc(msg, value, 0)           // wParam
setColorProperty:parameter:value:    →  WndProc(msg, parameter, colour)  // wParam, lParam
```

These read the value from **wParam** and therefore need the single-value form or
`message:wParam:`:

- `SCI_SETCARETLINEBACK`, `SCI_SETCARETLINEBACKALPHA`, `SCI_SETCARETLINEVISIBLE`,
  `SCI_SETCARETLINEVISIBLEALWAYS`
- `SCI_SETWRAPMODE`, `SCI_SETVIEWWS`, `SCI_SETINDENTATIONGUIDES`
- `SCI_SETXOFFSET`, `SCI_SETFIRSTVISIBLELINE`

Symptom when wrong: **the call appears to succeed but nothing changes**, because
the value landed in lParam and was ignored. Two shipped bugs came from this
(caret line stuck black; three toolbar toggles dead).

Also note `SCI_SETCARETLINEVISIBLE` with wParam 0 *clears* the caret-line colour,
so it is not the way to enable the band — setting the back colour does that.

### (b) `COLORREF` byte order

Raw integer colour paths (`SCI_SETCARETLINEBACK`, indicator values) expect
Windows `0x00BBGGRR`, not `0xRRGGBB`. `setColorProperty:` converts for you;
direct `message:` calls do not. Use `BGRFromRGB()` in `main.mm`. Symptom: a dark
blue renders as brown.

### (c) `INDIC_TEXTFORE` leaks

Do not recolour the active line's text with a `TextFore` indicator. It requires
manual bookkeeping to clear the old line; pressing Enter reset the bookkeeping
and left white text on white background — invisible lines. The fix was to delete
the mechanism and use Notepad++'s own approach (caret-line **background** only,
`E8E8FF`, Scintilla tracks the line). Do not reintroduce it.

### (d) Scintilla's Cocoa layer cannot print

Handing `ScintillaView` to `NSPrintOperation` produces a PDF whose content stream
is literally `q Q` — a blank page. Verified. `PrintView.m` renders text itself.
Two sub-traps there: without an explicit white background the page prints solid
black, and `rectForPage:` must return the real paper size (a zero-area rect
produces the blank `q Q` page).

### (e) Objective-C++ quoting

`main.mm` is compiled as ObjC++. `template` is a C++ keyword — write
`[image setTemplate:YES]`, not `image.template = YES`. Over-escaped `\\"` inside
`@"..."` silently terminates the string.

---

## 8. Current feature state

### Works (verified by self-test)

Multi-document tabs, undo/redo, multi-selection, 96 languages with Notepad++
keywords and palettes, extension detection (242), line numbers, active-line
highlight, brace matching, open/save/save-as/new, unsaved-changes prompt, find,
all 32 toolbar buttons, sidebar panels (Document List, Folder as Workspace,
Function List, Document Map), split view + scroll sync, `tail -f` monitoring,
macro record/playback/multi-run/save, print with pagination, custom keywords.

### Not implemented

These live in Notepad++'s Win32 shell or need substantial new subsystems:

| Missing | Why |
|---|---|
| Plugin system | `.dll` ABI, `NppPluginInterface`; needs a whole host |
| Preferences dialog | ~7,400 lines upstream |
| Full UDL editor | upstream UDL engine is ~2,100 lines in `UserDefineDialog.cpp`; port exposes a custom-keyword dialog instead |
| Session / backup | needs session file format |
| Column editor, character panel | Win32 dialogs |
| Project panels 1-3 | docking system |
| Syntax colouring in print | `PrintView` draws plain text |
| Full Find/Replace dialog | current one is a minimal `NSAlert` |
| Function List beyond 13 languages | `functionItemsForText:` has regexes for C-family (cpp, c, cs, java, js, ts, objc, rust, go, swift, php), Python and Lua only; everything else reports "No functions found" |

---

## 9. Highest-value next steps

Ordered by user-visible payoff per unit of risk:

1. **Syntax colouring in print.** `PrintView` already paginates; it needs to read
   `SCI_GETSTYLEAT` per character and apply `SCI_STYLEGETFORE`. Self-contained,
   no architectural change. Test: render a page bitmap, assert >1 distinct glyph
   colour.
2. **Function List for more languages.** `functionItemsForText:` already covers 13
   languages (C-family via one C-style regex, plus Python and Lua). SQL, Ruby,
   Bash, Perl, R and others are missing. Low risk to add patterns; the real fix is
   to use Lexilla's own fold/symbol information instead of regexes.
3. **Real Find/Replace dialog** with options (regex, whole word, in selection).
   `ScintillaView` already exposes `findAndHighlightText:` and
   `findAndReplaceText:`.
4. **Preferences dialog** for the settings currently hardcoded (font, tab width,
   theme). Read Notepad++'s `config.model.xml` schema for key names.
5. **UDL engine** — largest item; port `LexUser`-style keyword sets on top of the
   generator pipeline.

### Testing discipline that has worked

- Assert **resulting Scintilla state**, not that a function was called. Every real
  bug in this port was found this way.
- Render to PNG and inspect pixels when the bug is visual. Two bugs (black print
  page, blank `q Q` page) were invisible to numeric assertions.
- Beware tests that "fail" because the expectation is wrong. Several did — e.g.
  `int` correctly maps to `SCE_C_WORD2` (16), not `SCE_C_WORD` (5), per upstream's
  keyword-list remapping.

---

## 10. Licensing — non-negotiable

Upstream is **GPLv3**. Scintilla/Lexilla are GPLv3-compatible permissive. The port
consumes Notepad++'s `langs.model.xml` and `stylers.model.xml` directly, so the
whole result is a GPLv3 derivative work.

If you distribute:
- ship the complete corresponding source
- mark modified files with dates
- keep copyright and licence notices
- **rename it** — the "Notepad++" name and logo are not part of the licence

Current bundle name/identifier (`Notepad++`, `org.notepad-plus-plus.macos`) is fine
for local use, not for distribution.

---

## 11. Quick reference

| Thing | Value |
|---|---|
| Bundle | `macport/dist/Notepad++.app`, 4.0 MB, arm64 |
| Min macOS | 11.0 (deployment target); built on 26.6.2 |
| Scintilla upstream commit | `cda2acf5`, 2026-10-24 |
| Languages selectable | 96 |
| Lexer files compiled | 141 (12 lexlib + 128 lexers + `Lexilla.cxx`) |
| Lexers registered at runtime | 142 (some files register several) |
| Keyword lists | 76 languages, from upstream XML |
| Colour palettes | 93 lexer types |
| Toolbar | 32 buttons, 9 separators, 41 slots |
| Self-test | 66 assertions |
| Active line colour | `E8E8FF` (Notepad++ default) |
| Tab width / font | 4 spaces / Menlo 13 |
