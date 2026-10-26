# Handoff — Catatan++ for macOS (native port)

Written for the next agent or developer picking this up. Updated on 2026-10-25 with all major features, OOTB diagram engines, and local packagers implemented.

---

## 1. What this is

A native Apple Silicon port of the **Notepad++ editor**, branded as **catatan++** (`Catatan++.app`).

- **keeps** Scintilla (text engine) and Lexilla (142 registered lexers) unchanged
- **keeps** Notepad++'s own language/style data, consumed from upstream files
- **adds** out-of-the-box Live Preview for Markdown, Mermaid.js, and PlantUML diagrams via native WebKit
- **replaces** the entire Win32 shell with a modern Cocoa application

Result: a 6.0 MB arm64 `.app` that opens, edits, highlights, previews diagrams, and packages cleanly.

**No Wine, no emulation, no Rosetta.**

---

## 2. Directory Structure

```
/Users/nb-mac-fj2n0x/Work/wproject/notepad++/
├── src/                        upstream clone (scintilla, lexilla, PowerEditor)
└── macport/                    ← all port work lives here
    ├── build.sh                fast cached build script
    ├── make_dmg.sh             local DMG packaging script
    ├── README.md               user-facing docs
    ├── HANDOFF.md              this file
    ├── icons/                  AppIcon.icns (Docker-style) + 32 Solar outline SVGs
    ├── resources/preview/      marked.min.js + mermaid.min.js + preview.html
    └── src/                    the port's own code
        ├── main.mm             app lifecycle, tabs, panels, preview, self-tests
        ├── FindInFiles.h/.m    recursive multi-file search engine & modeless dialog
        ├── ColumnEditor.h/.m   rectangular text/number insertion dialog & engine
        ├── UDLManager.h/.m     Notepad++ XML user-defined language parser & persistence
        ├── Toolbar.m/.h        toolbar view + 32-command table
        ├── Sidebar.m/.h        docked panel with outline list (Search, Functions, Files)
        ├── PrintView.m/.h      paginated print rendering with syntax colouring
        ├── Keywords.c          generated + custom keywords (Mermaid, PlantUML, etc.)
        ├── Theme.c             generated colour palettes
        ├── LexerMap.m          generated extension/lexer mappings
        └── LangFromExt.m       extension → language mappings (including md, mmd, puml)
```

---

## 3. Build & Packaging

```bash
cd macport
./build.sh                  # incremental cached build (~4 seconds)
./make_dmg.sh               # packages dist/Catatan++-macOS-arm64.dmg (~3.6 MB)
open dist/Catatan++.app     # launches application
```

### Self-Test Regression Suite

```bash
cd macport
dist/Catatan++.app/Contents/MacOS/Catatan++ --selftest
```
Output: **89 OK, 0 FAIL**.
Covers:
- Language sweep (96 langs)
- Keyword & colour styling
- Active-line behaviour
- Multi-tab lifecycle
- Toolbar actions & layout
- Sidebar panels (Document List, Folder as Workspace, Function List, Document Map)
- Extended Function List (Bash, SQL, Ruby, Perl, R, Markdown, YAML)
- Print with syntax colouring
- Split view + sync scrolling
- Find & Replace (Match case, Whole word, Wrap, Replace All)
- Find in Files (directory search with file filters)
- Column Editor (text & number insertion across lines)
- UDL Importer (Notepad++ XML parsing & persistence)
- Markdown, Mermaid & PlantUML diagram detection & Live Preview toggling

---

## 4. Implemented Features

1. **Live Previewer (OOTB)**: Native `WKWebView` side-by-side live preview for `.md`, `.mermaid`, `.mmd`, `.puml`, `.plantuml` with Mermaid.js v10, Marked v12, and PlantUML rendering (`⌥⌘P`).
2. **Find in Files**: Recursive search with wildcard filters (`*.cpp,*.h,*.py`) and Search Results panel with jump-to-location (`⌘⇧F`).
3. **Column Editor**: Rectangular selection text/number sequence insertion with Decimal, Hex, Octal, Binary formats and leading zeros (`⌥C`).
4. **Preferences Window**: Configuration for Font, Font Size, Tab Width, Soft Tabs, Word Wrap, and Line Numbers (`⌘,`).
5. **Session Restoration**: Automatic session persistence to `session.plist` and restore on relaunch.
6. **UDL XML Importer**: Import custom Notepad++ `.xml` syntax files with persistent storage in `~/Library/Application Support/catatan++/udl/`.
7. **Print Syntax Colouring**: Paginated, paper-aware printing with full Scintilla syntax colors.
8. **App Branding**: Docker-style full-bleed emerald squircle app icon (`AppIcon.icns`).
9. **DMG Packager**: Local `make_dmg.sh` and GitHub Actions CI/CD release workflow.
10. **Best-Practice Undo/Redo Coalescing**: Industry-standard coalescing rules (Enter line breaks, whitespace/punctuation token breaks, 1.2s idle pauses, caret jumps) preventing accidental full-buffer loss on Undo.
11. **Native In-Place Auto-Updater (VS Code / Antigravity Style)**: Silent background update check via GitHub Releases API, background zip download, atomic `.app` bundle replacement via detached helper, and instant relaunch with zero-loss session restoration.

*Note*: Plugin architecture was explicitly omitted per project requirements.
