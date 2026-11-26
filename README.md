# MarkdownBrowser

A native macOS app for browsing and editing Markdown, built with Swift and Rust. Open a file or a whole folder and edit GitHub-flavored Markdown in place, without the app ever reformatting your file.

## Features

- **Browse files and folders**: open a single file or a folder; folders get a sidebar file tree, sorted by name like Finder, that updates when files change on disk, stays fast with tens of thousands of files, and opens on the folder's README. Double-click a folder to open it in the sidebar; go back up with the arrow above the tree (or ⌥⌘↑), or pick any enclosing folder from the folder menu next to it. Going above the folder you opened asks for access to it first.
- **Native Markdown preview**: tables, interactive task lists, `> [!NOTE]` alerts, footnotes, `:emoji:` shortcodes, math (`$…$`, `$$…$$`), sanitized HTML (including `<details>` wrapping Markdown), images, video, and syntax-highlighted code.
- **Mermaid diagrams**: ```` ```mermaid ```` blocks render as diagrams and switch theme with light/dark mode.
- **In-place editing**: one editing pane renders inactive blocks; click rendered text to place the caret at its matching source position. Double-click selects a word; Shift-click and dragging extend selection. Revealing source keeps the clicked row anchored while surrounding blocks resize. Inline emphasis, code and link markers appear when the selection touches them. Edits change exactly the characters you type: line endings, encoding and formatting elsewhere are preserved byte for byte.
- **View Source**: toggle (⌘U) to reveal all Markdown syntax in the same editor, sharing selection and undo history.
- **Edit rendered content**: images and diagrams target their own source construct. Right-click rendered content for **Edit Markdown Source**; rendered labels and widgets expose the same accessibility action. Raw HTML text uses scoped source mappings where available.
- **Links**: ⌘-click source or rendered links to follow; add ⇧ to open in a new tab. Links to other files open in the app, `#heading` links scroll, web links open in your browser.
- **Other files**: text and code open as editable source with syntax highlighting; images, videos and everything else use native viewers (Quick Look for the rest).
- **Find & replace**: a find bar for the current file, and Find in Files across the current file, all open files, or the whole folder. Options for match case, regex, and wrap around; Find in Files asks for confirmation before Replace All. Both share the Rust search engine with ECMAScript-compatible regex syntax, and patterns can span lines (`foo\nbar`); regex replacements can use `$&`, `$1` and `\n`.
- **Quick filter**: a field above the sidebar's file tree (⇧⌘O) finds files and folders by fuzzy name, so `rdm` matches `README.md`; best matches first, case-insensitive, and a `/` in the query matches the relative path (`docs/rdm`). Toggle **Aa** to match case or **.\*** to filter with a regular expression instead (`\.txt$`, `^docs/.+\.md$`), using the same engine as Find in Files. It searches the folders shown in the tree; tick **Include subfolders** to search the whole folder (hidden files and folders such as `node_modules` are skipped, at most 500 results). Click a result to open it like a tree click (⌘-click a file to open it in a new tab), double-click a folder to open it in the sidebar (Return reveals it in the tree instead), ↓/↑ and Return to pick one from the keyboard, Escape to clear the filter and bring back the tree.
- **Saving**: ⌘S, or autosave when the window or app loses focus (on by default, can be turned off in Settings). Changes made by other apps are detected and never silently overwritten.
- **Tabs and windows**: native macOS tabs (⌘T) and multiple windows. As in VS Code, a file clicked in the sidebar opens in a preview tab (slanted title) that the next click replaces; double-click the file or the tab, edit it, or choose **Keep Tab Open** (⌥⌘K) to keep it, and the next click opens a new tab.
- **Appearance**: Automatic, Light or Dark.
- **Command line**: `mdb` opens the current directory or any path, like Sublime Text's `subl`.

## Installing

Download the `.dmg` from the [latest release](https://github.com/DocEmmetBrown/MarkdownBrowser/releases/latest), open it and drag **MarkdownBrowser** onto the **Applications** folder. A zip of the app is attached too.

Release builds aren't signed with a Developer ID yet, so macOS blocks the first launch. Right-click the app and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/MarkdownBrowser.app
```

## Requirements

| To run | To build |
|---|---|
| macOS 14 Sonoma or later on Apple silicon | Xcode 27 (Swift 6.4) |
| | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| | Rust, through [rustup](https://rustup.rs) (to build the native core) |

## Building

```sh
brew install xcodegen rustup
rustup-init -y
xcodegen generate
open MarkdownBrowser.xcodeproj
```

Then build and run the **MarkdownBrowser** scheme. From the command line:

```sh
xcodebuild -project MarkdownBrowser.xcodeproj -scheme MarkdownBrowser -derivedDataPath build build
open build/Build/Products/Debug/MarkdownBrowser.app
```

The first build resolves SwiftMath through Swift Package Manager and builds the Rust core (`native/`) with Cargo. Later builds reuse unchanged dependencies and native build outputs.

CI tests and release builds use GitHub's ARM64 `xcode-27` runner image (macOS 27, currently in preview).

Debug builds are signed ad hoc. Set your development team in `project.yml` before distributing.

## Command-line tool

The app bundle ships an `mdb` launcher. To install it, choose **MarkdownBrowser › Install Command Line Tool…** (also offered on first launch and in Settings › General) and pick a folder on your `PATH`, such as `/opt/homebrew/bin` or `~/.local/bin`. The app is sandboxed, so it can only write to a folder you pick; if that folder belongs to root (like `/usr/local/bin` on a fresh Mac), it offers a `sudo ln -sf` command to link it instead. To link it by hand:

```sh
sudo ln -sf "/Applications/MarkdownBrowser.app/Contents/SharedSupport/bin/mdb" /usr/local/bin/mdb
```

```sh
mdb                 # open the current directory
mdb README.md docs  # open files or folders
```

The link points into the app, so reinstall it if you move the app.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Open file or folder | ⌘O |
| New window / new tab | ⌘N / ⌘T |
| Save / close | ⌘S / ⌘W |
| Toggle Markdown source | ⌘U |
| Back / forward | ⌘[ / ⌘] |
| Enclosing folder (sidebar) | ⌥⌘↑ |
| Follow link (in a new tab) | ⌘-click (⇧⌘-click) |
| Open sidebar file in a new tab | ⌘-click |
| Keep a preview tab open | ⌥⌘K, or double-click the tab |
| Find / find and replace | ⌘F / ⌥⌘F |
| Find next / previous | ⌘G / ⇧⌘G |
| Find in Files | ⇧⌘F |
| Filter files in the sidebar | ⇧⌘O |
| Settings | ⌘, |

## Settings

- **General**: autosave when focus is lost (on by default). When off, you're asked before unsaved changes are discarded. Install the `mdb` command.
- **Wrap long lines** (on by default, also in the Edit menu): wrap lines wider than the editor instead of scrolling sideways, in rendered prose and source alike; code blocks and tables scroll horizontally.
- **Appearance**: Automatic (follows macOS), Light, or Dark. Page margins around rendered Markdown (none by default, or narrow, normal, wide), and an optional GitHub-style 980-point text width (applies when wrapping is on).

## Known limitations

- Pictures do not map arbitrary pixels to source characters. Unmapped or ambiguous HTML falls back to the enclosing source block. Rendered appearance uses native styles, not GitHub's CSS.
- SwiftMath and the Rust Mermaid renderer support a subset of math expressions and Mermaid diagrams. Rendering errors show the source and an error (math retains its source and logs the error).
- Raw HTML supports native text, lists, tables, links, images, video and disclosure groups; CSS, scripts and arbitrary browser layout are not supported. SVG images do not load external or embedded image references.
- Code fences use their language tag, including Swift and TypeScript, through the extended native grammar set. Untagged or unsupported languages remain plain text; there is no automatic language detection.
- Images are limited to 16 MB and 40 million decoded pixels; diagrams to 100 KB of source. Preview and source highlighting are disabled above 5 MB.
- A file that is not valid UTF-8 is read as Latin-1 and saved back byte for byte, until it contains a character Latin-1 cannot represent (above U+00FF). From then on it is saved as UTF-8 (without BOM), which rewrites its other non-ASCII bytes.
- Parsing is debounced and runs off the main thread after edits, but is not incremental. A visible 10k-line Debug fixture measured 46-65 ms through synchronous layout/drawing and 2.3-2.5 seconds through the debounced reparse; the 16 ms goal is not met. Live VoiceOver and physical IME testing remain manual checks; see [native architecture and validation](docs/native-architecture.md).

## Project layout

```
MarkdownBrowser/        Swift app (SwiftUI + AppKit)
MarkdownBrowserTests/   Swift Testing unit tests
native/                 Native core (Rust, exposed to Swift through UniFFI)
goldens/                Shared search conformance corpus for Rust and Swift tests
cli/mdb                 Command-line launcher
Samples/                Fixture folder for manual testing
project.yml             XcodeGen project definition
```

## Contributing

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Guillaume Winter

The app includes third-party code under MIT, Apache-2.0, BSD, ISC, Zlib, Unicode and MPL-2.0 licenses. Their notices are bundled in `MarkdownBrowser.app/Contents/Resources` (see [Resources](MarkdownBrowser/Resources)).
