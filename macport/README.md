# catatan++ (Notepad++ for macOS — native port)

A native Apple Silicon build of Notepad++'s editor engine with modern macOS Big Sur+ aesthetics and out-of-the-box developer tooling. No Wine, no emulation, no Rosetta.

**Status:** Full-featured native code editor with live diagram previewers, session management, find in files, and DMG installer packaging.

---

## 1. Quick Start

### Build Application Bundle
```bash
cd macport
./build.sh
open dist/Catatan++.app
```

Produces `dist/Catatan++.app` (arm64, ~6.0 MB including all offline diagram engines).

### Build Compressed DMG Installer
```bash
cd macport
./make_dmg.sh
```
Produces `dist/Catatan++-macOS-arm64.dmg` with standard `/Applications` drag-and-drop shortcut and volume icon.

### Verification Suite
```bash
cd macport
./dist/Catatan++.app/Contents/MacOS/Catatan++ --selftest
```
Runs 89 automated assertions across language detection, syntax highlighting, multi-tab lifecycle, print engine, function list, find & replace, preferences, session restoration, find in files, column editor, UDL importer, and live diagram previewers.

---

## 2. Key Features

### 🌟 Out-of-the-box (OOTB) Live Diagram & Markdown Previewer
- **Markdown (`.md`, `.markdown`)**: Real-time GitHub-flavored Markdown rendering with syntax-highlighted code blocks, tables, task lists, and math.
- **Mermaid.js (`.mermaid`, `.mmd`)**: Native offline rendering of flowcharts, sequence diagrams, class diagrams, state diagrams, ER diagrams, Gantt charts, git graphs, and mindmaps.
- **PlantUML (`.puml`, `.plantuml`, `.iuml`)**: Real-time preview for PlantUML diagrams (`@startuml ... @enduml`) with dual offline/online engine.
- Embedded diagram support: Type ````mermaid ```` or ````plantuml ```` inside any Markdown file to see interactive rendered diagrams inline!
- Toggleable via **View > Live Preview** (`⌥⌘P`) side-by-side with automatic macOS Dark/Light theme matching.

### 🔍 Advanced Search & Replace
- **Find & Replace Panel (`⌘F` / `⌥⌘F`)**: Modeless floating panel with Match Case, Whole Word, Wrap Around, and Replace All.
- **Find in Files (`⌘⇧F`)**: Recursive multi-file search across directories with file filter wildcards (`*.cpp,*.h,*.py`) and a dedicated Search Results panel with one-click jump-to-line.

### ✏️ Column Mode & Column Editor (`⌥C`)
- Rectangular selection via `⌥ + Drag`.
- **Column Editor dialog (`⌥C`)**:
  - Insert Text across all lines at column offset.
  - Insert Numbers with Initial value, Increase step, Repeat count, Leading zeros, and formats (Decimal, Hex, Octal, Binary).

### ⚙️ Preferences & Session Restoration
- **Preferences Dialog (`⌘,`)**: Persisted configuration for Editor Font, Font Size, Tab Width, Soft Tabs, Word Wrap, and Line Numbers.
- **Session Auto-Save & Restore**: Active tabs, file paths, and cursor positions automatically persist to `session.plist` and restore seamlessly on reopen.

### 🎨 User Defined Language (UDL) Importer
- Import custom syntax definitions from Notepad++ Windows `.xml` format (**Language > Import User Defined Language (XML)…**).
- Keywords, comments, operators, and extensions persist in `~/Library/Application Support/catatan++/udl/` and reload automatically.

### 🖨️ Syntax-Coloured Printing & Export
- Custom `NSPrintOperation` engine with pagination, paper-aware margins, and full syntax colouring across all 96 supported languages.

### ↩️ Best-Practice Undo/Redo Coalescing
- Industry-standard coalescing rules (Enter line breaks, whitespace/delimiters, 1.2s typing pause, and cursor navigation jumps) ensuring intuitive word-by-word and line-by-line undo rather than accidental whole-document erasure.

---

## 3. Architecture

| Layer | Implementation | Notes |
|---|---|---|
| **Text Engine** | Scintilla (`src/scintilla`) + Cocoa layer | Native CoreText rendering |
| **Lexer Engine** | Lexilla (`src/lexilla`) — 142 lexers | Reused upstream C++ |
| **GUI Shell** | Native AppKit / Cocoa (`macport/src`) | Custom TabStrip, Toolbar, SplitView, Sidebar, Search |
| **Live Preview** | WebKit (`WKWebView`) + bundled offline JS | `marked.min.js` + `mermaid.min.js` in Resources |
| **App Branding** | Custom full-bleed emerald squircle | Docker-style macOS icon (`AppIcon.icns`) |

---

## 4. Licensing

Upstream is **GPLv3**. This port is licensed under **GPLv3**. All modified files include timestamp headers and GPLv3 notices.
