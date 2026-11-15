# Contributing

By contributing, you agree to license your contributions under the [MIT License](../LICENSE).

## Setup

Install Xcode 27 (Swift 6.4), XcodeGen, and Rust through rustup. The app targets macOS 14 or later on Apple silicon only.

```sh
brew install xcodegen rustup
rustup-init -y
xcodegen generate
open MarkdownBrowser.xcodeproj
```

The Xcode project is generated and ignored. Edit `project.yml`, not the project. Regenerate after adding, removing or renaming files. Xcode resolves the pinned SwiftMath package automatically; there is no Node/npm toolchain.

## Architecture

- **Windows**: AppKit window controllers host SwiftUI, providing native tabs, close prompts and focus events.
- **Workspace**: owns navigation, the selected document, search/find state and security-scoped access. Its `NativeEditorHost` is the only editor implementation.
- **Sidebar**: an `NSOutlineView` over a shared, lazy `FileTree`. Keep large folders lazy; do not replace this with a fully materialized SwiftUI list. The filter uses a debounced, cancellable stream and retains only its best matches.
- **OpenDocument**: owns encoding, BOM, line separator, disk fingerprint, recovery text and saving. It requests a revision-tagged snapshot from `DocumentEditor` and acknowledges exactly the version written.
- **NativeEditorHost**: one editable `NSTextView` with TextKit 1, native undo and IME. It coordinates source styling, Rust-backed find/replace and in-place rendering. Command-click follows links; plain clicks reveal editable source.
- **NativeLivePreview**: TextKit 1's public glyph delegate conceals inactive source ranges without replacing characters or inserting attachments. Native SwiftUI block views occupy reserved layout rectangles; only nearby views are instantiated. Selection reveals the active block, and inline delimiters reveal when the selection touches their construct. Command-U removes concealment and embedded views without replacing the editor.
- **NativeMarkdown**: Comrak source ranges, resolved links, headings and styling. After edits, parsing is debounced on a background task; obsolete results are discarded by revision. Only changed style ranges are applied. This is not an incremental parser.
- **NativePreview**: the native SwiftUI rendering tree embedded in the editor, not a second pane. Tables, task lists, disclosure groups and media use native controls. Task toggles edit only the original checkbox symbol through the editor's undo path. SwiftMath draws math; Rust renders Mermaid to SVG and rasterizes SVG with resvg. Failed diagrams retain source and show an error; failed math retains source and logs the error.
- **Native core**: `native/mdb-core` provides parsing, sanitizing, syntax highlighting, diagrams and ECMAScript-compatible search through UniFFI. `native/build.sh` builds for `aarch64-apple-darwin` and generates ignored Swift bindings. Unchanged builds are hash-stamped.
- **Search**: the find bar and Find in Files share `SearchEngine` and Rust `regress`. `goldens/search.json` is the static reference recorded from the former JavaScript implementation; replaying it requires no JavaScript.

Rendered inline labels use read-only `NSTextView` instances for character-level link hit testing, including Command/Shift modifiers. Their attributed text and math attachments are display-only; they never enter the editable document's text storage.

The native build phase declares the generated Swift/C/modulemap and Rust archive as outputs. Keep these declarations: Xcode must regenerate bindings before Swift dependency scanning/compilation, or an API change can link stale Swift bindings to a new archive and crash on UniFFI's checksum check.

## Rules worth knowing

**Never re-serialize Markdown.** The document is raw source. Parsing and rendering consume copies; they must never print an AST back into the editor or into a saved file.

**Preserve bytes.** `TextCodec` retains encoding and BOM. Typed, pasted, dropped and committed IME text use the document's line separator. Untouched text, including mixed line endings, stays unchanged.

**Keep undo and composition intact.** Programmatic edits must use the editor's `shouldChangeText`/text storage/`didChangeText` path. Styling changes attributes, not characters, and is deferred during marked-text composition.

**Treat content as untrusted.** Rust HTML is sanitized with ammonia before Swift sees it. The preview is not a browser: scripts, event handlers and CSS do not run. Local resources must pass `PathPolicy`, resolving traversal and symlinks, before loading. SVG image resolvers cannot load external resources. AVFoundation external references are forbidden. Only HTTP, HTTPS and mail links leave the app.

**Bound rendering.** Preview/highlighting stops above 5 MB; images are bounded by encoded size and decoded pixel count; diagram and SVG inputs and raster dimensions are bounded. Surface failures visibly or through the preview logger, not silent success-shaped results.

**Swift concurrency.** The app defaults to main-actor isolation. Pure values used in background tasks must be `nonisolated` and `Sendable`. Do not parse, highlight code or render diagrams on each keystroke on the main actor.

**Dependencies.** Reuse the existing libraries. Review the Cargo lockfile and exact SwiftPM version when updating dependencies. Do not add a browser or Node-based build step.

## Common changes

- **Setting**: add a key/default in `AppSettings`, expose it in `SettingsView`, and apply it to existing editors.
- **Rendered Markdown**: extend the Rust parser/sanitizer and native preview together; preserve source ranges and add focused native tests.
- **File type**: classify it in `FileKind` and choose its viewer in `DocumentArea`.
- **App icon**: run `swift scripts/make-icon.swift` and commit the generated icon PNGs.

## Validation

The VS Code **Build and Run MarkdownBrowser** task tests Rust, generates the project, runs Swift tests and launches only on success. Swift CI remains manual while the repository is private; the Linux Rust job runs on pushes/PRs.

```sh
cargo fmt --manifest-path native/Cargo.toml --check
cargo clippy --locked --manifest-path native/Cargo.toml --all-targets --features mdb-core/bindgen -- -D warnings
cargo test --locked --release --manifest-path native/Cargo.toml
xcodegen generate
xcodebuild -project MarkdownBrowser.xcodeproj -scheme MarkdownBrowser -derivedDataPath build test
```

Swift tests cover byte preservation, source styling, links/anchors, preview controls and layout, path permissions, search, saves/conflicts, sidebar navigation and tabs. Rust tests cover parser source ranges, sanitized HTML, code highlights, diagrams, regex semantics and the recorded search corpus.

Open `Samples/` for the manual checks:

1. Inspect tables, images, alerts, emoji, footnotes, details, math and diagrams in light/dark mode.
2. Click rendered blocks to edit, toggle a task, undo and save; compare bytes with a copy. Reveal all source with Command-U; resize and scroll through the same editor.
3. Command-click `docs/guide.md#installation` from source and rendered text; test Shift for a new tab and history navigation.
4. Change the file externally, both with and without local edits; check reload/conflict handling.
5. Test real IME composition, drag/drop, VoiceOver and keyboard-only navigation.
6. Measure 10k-line typing with a visible window, layout and preview updates. The automated insertion timing excludes display/layout and is not an end-to-end performance claim.
7. Test find/replace and Find in Files in each scope, with wrap on/off.
8. Test resource permission requests and root-relative images after changing the sidebar folder.
9. Run `cli/mdb` with the current directory and explicit paths.

Rendered-block clicks currently reveal the beginning of that block, not the exact rendered character. Math/Mermaid and HTML/CSS fidelity differ from browser renderers; keep the [migration status](native-migration-plan.md) and README honest about limitations.

## Releasing

Push a version tag to run tests, build and attach the zip and SHA-256:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Locally run `scripts/build-release.sh 0.2.0` (`SKIP_TESTS=1` skips tests). Builds are ad-hoc signed unless `DEVELOPER_ID_APPLICATION` is set. Notarization also needs `NOTARY_PROFILE` or the three `NOTARY_KEY_*`/issuer settings documented in that script.

Keep changes focused, add regression tests for changed behavior, and document which manual checks actually ran.
