# MarkdownBrowser

A native macOS app for browsing and editing Markdown. Open a file or a whole folder, read it rendered the way GitHub renders it, and edit it in place without the app ever reformatting your file.

## Features

- **Browse files and folders**: open a single file or a folder; folders get a sidebar file tree, sorted by name like Finder, that updates when files change on disk, stays fast with tens of thousands of files, and opens on the folder's README. Double-click a folder to open it in the sidebar; go back up with the arrow above the tree (or ⌥⌘↑), or pick any enclosing folder from the folder menu next to it. Going above the folder you opened asks for access to it first.
- **GitHub-style rendering**: GitHub's stylesheet and colors; tables, task lists, `> [!NOTE]` alerts, footnotes, `:emoji:` shortcodes, math (`$…$`, `$$…$$`), raw HTML (sanitized, including `<details>` wrapping Markdown), images, and syntax-highlighted code.
- **Mermaid diagrams**: ```` ```mermaid ```` blocks render as diagrams and switch theme with light/dark mode.
- **Edit in the rendered view**: click anywhere to edit; the Markdown syntax appears only where the cursor is. Edits change exactly the characters you type: line endings, encoding and formatting elsewhere are preserved byte for byte.
- **View Source**: toggle (⌘U) to the plain Markdown, sharing the same undo history.
- **Links**: ⌘-click to follow. Links to other files open in the app, `#heading` links scroll, web links open in your browser.
- **Other files**: text and code open as editable source with syntax highlighting; images, videos and everything else use native viewers (Quick Look for the rest).
- **Find & replace**: a find bar for the current file, and Find in Files across the current file, all open files, or the whole folder. Options for match case, regex, and wrap around; Replace All with confirmation. Both use JavaScript regex syntax and match the same way, and patterns can span lines (`foo\nbar`); regex replacements can use `$&`, `$1` and `\n`.
- **Quick filter**: a field above the sidebar's file tree (⇧⌘O) finds files and folders by fuzzy name, so `rdm` matches `README.md`; best matches first, case-insensitive, and a `/` in the query matches the relative path (`docs/rdm`). It searches the folders shown in the tree; tick **Include subfolders** to search the whole folder (hidden files and folders such as `node_modules` are skipped, at most 500 results). Click a result to open it like a tree click (⌘-click for a new tab), ↓/↑ and Return to pick one from the keyboard, Escape to clear the filter and bring back the tree.
- **Saving**: ⌘S, or autosave when the window or app loses focus (on by default, can be turned off in Settings). Changes made by other apps are detected and never silently overwritten.
- **Tabs and windows**: native macOS tabs (⌘T) and multiple windows. As in VS Code, a file clicked in the sidebar opens in a preview tab (slanted title) that the next click replaces; double-click the file or the tab, edit it, or choose **Keep Tab Open** (⌥⌘K) to keep it, and the next click opens a new tab.
- **Appearance**: Automatic, Light or Dark.
- **Command line**: `mdb` opens the current directory or any path, like Sublime Text's `subl`.

## Installing

Download the zip from the [latest release](https://github.com/DocEmmetBrown/MarkdownBrowser/releases/latest), unzip it and move **MarkdownBrowser.app** to `/Applications`.

Release builds aren't signed with a Developer ID yet, so macOS blocks the first launch. Right-click the app and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/MarkdownBrowser.app
```

## Requirements

| To run | To build |
|---|---|
| macOS 14 Sonoma or later on Apple silicon | Xcode 27 (Swift 6.4) |
| | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| | Node.js and npm (to bundle the editor) |
| | Rust, through [rustup](https://rustup.rs) (to build the native core) |

## Building

```sh
brew install xcodegen node rustup
rustup-init -y
xcodegen generate
open MarkdownBrowser.xcodeproj
```

Then build and run the **MarkdownBrowser** scheme. From the command line:

```sh
xcodebuild -project MarkdownBrowser.xcodeproj -scheme MarkdownBrowser -derivedDataPath build build
open build/Build/Products/Debug/MarkdownBrowser.app
```

The first build runs `npm ci` and bundles the web editor (`web/`), and builds the Rust core (`native/`) with Cargo. Later builds skip those steps when their sources haven't changed.

Debug builds are signed ad hoc. Set your development team in `project.yml` before distributing.

## Command-line tool

The app bundle ships an `mdb` launcher. To install it, choose **MarkdownBrowser › Install Command Line Tool…** (also offered on first launch and in Settings › General) and pick a folder on your `PATH`, such as `/opt/homebrew/bin` or `~/.local/bin`. The app is sandboxed, so it can only write to a folder you pick; if that folder belongs to root (like `/usr/local/bin` on a fresh Mac), it offers a `sudo` command to copy instead. To link it by hand:

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
- **Wrap long lines** (on by default, also in the Edit menu): wrap lines wider than the window instead of scrolling sideways, in rendered Markdown, Markdown source and other text files.
- **Appearance**: Automatic (follows macOS), Light, or Dark. Page margins around rendered Markdown (none by default, or narrow, normal, wide), and an optional GitHub-style 980-point text width.

## Known limitations

- Tables, diagrams and HTML inside blockquotes are shown as source.
- A footnote definition ends at the first blank line, so multi-paragraph footnotes aren't supported.
- If the editor's web process crashes, the last second of typing may be lost, along with undo history.
- After changing the sidebar's folder, images in the open file written with a leading `/` (relative to the folder) resolve against the new folder only once the file is reopened.

## Project layout

```
MarkdownBrowser/        Swift app (SwiftUI + AppKit)
MarkdownBrowserTests/   Swift Testing unit tests
web/                    Editor bundle (TypeScript, CodeMirror 6)
native/                 Native core (Rust, exposed to Swift through UniFFI)
goldens/                Results recorded from the JavaScript code that the native code must reproduce
cli/mdb                 Command-line launcher
Samples/                Fixture folder for manual testing
project.yml             XcodeGen project definition
```

## Contributing

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Guillaume Winter
