# MarkdownBrowser: plan to replace the JS components with native code

Date: 2026-11-13 · Base: `main` @ `2789857` · Prototype: `origin/prototype/native-app` @ `57b3cfd`

## 1. Review of `prototype/native-app`

A single commit, "feat: prototype native Markdown editor and search". It has 25 files changed (+784/−703) and its base is 9 commits behind `main`.

What it does:

- `EditorHost` uses an `NSTextView` with TextKit 2 instead of `WKWebView` and CodeMirror. It still conforms to the existing `DocumentEditor` protocol, so `Workspace`, `OpenDocument`, saving, recovery and the find bar are unchanged. That protocol is the right seam for the migration.
- `NativeMarkdownStyle` adds about 10 regexes that set fonts and colors on the raw source. The syntax stays visible.
- `SearchEngine` uses `NSRegularExpression` (ICU) instead of JavaScriptCore running `search-engine.js`. A `Source` helper maps CRLF-normalized offsets back to original offsets.
- It removes the `web/build.sh` pre-build phase, `LocalResourceSchemeHandler`, `web.yml` and the npm Dependabot entry.
- It adds `native.yml`, which runs `xcodebuild test` on `macos-26`.
- It changes the bundle id to `…MarkdownBrowser.NativePrototype` and the display name to "MarkdownBrowser Native".
- It adds 146 lines of `NativeEditorTests`.

Status: it builds and all 69 tests pass locally.

### CI failure (run 42236772628)

`PreviewTabTests.sidebarClicksReuseThePreviewTabLikeVSCode` fails because `TabDoubleClickMonitor.tabController(at:)` returns `nil` on the headless `macos-26` runner. The same test passes locally on the same commit, so this is an environment-dependent tab-bar layout flake, not an editor regression. `main` never hits it because `main` has no workflow that runs the Swift tests on push or PR; only the `release` workflow, on tags, does.

### Good, keep it

- Byte preservation: `NativeTextView.insertText` rewrites `\r\n`, `\r` and `\n` to the file's line separator. Edits go through `shouldChangeText`, `replaceCharacters` and `didChangeText`, so undo stays coherent.
- Styling only changes attributes, never the source, which satisfies "Never re-serialize Markdown" in CONTRIBUTING.
- `SearchEngine.Source` maps normalized offsets back to the original text with a binary search. Replace All leaves unmatched mixed line endings untouched.
- `native.yml`: the Swift tests should run on PRs to `main` regardless of this migration.

### Problems to fix before any of it lands

| # | Where | Issue |
|---|---|---|
| 1 | `NativeMarkdownStyle.apply`, called from `textDidChange` | Every keystroke resets attributes on the whole document and rescans it with about 10 regexes: O(n) per keystroke, capped by `livePreviewSizeLimit` (5 MB). `setAttributes` over the full range during editing can also break marked-text (IME) composition underlines. |
| 2 | `NativeMarkdownStyle` | It isn't a parser. Inside fenced code, `[x](y)` still gets a `.link` attribute (links are applied after fences), so clicking text in a code block navigates. Emphasis inside code spans, `#tag` lines, setext headings and nested or escaped constructs are all styled wrongly. |
| 3 | `EditorHost.scrollToAnchor` | The slug logic doesn't match `web/src/render/slug.ts` (the github-slugger port): it doesn't strip `[text](url)` targets, inline HTML, trailing `#`s or `_`, and it treats `#` lines inside code fences and `#tag` lines as headings. `#heading` links from other files will miss. Port `Slugger`, `githubSlug` and `headingPlainText` exactly. |
| 4 | `textView(_:clickedOnLink:at:)` | Plain clicks follow links, so the caret can't be placed inside link text. `main` uses ⌘-click to follow; the prototype uses Shift-click for a new tab. This changes behavior and conflicts with editing. |
| 5 | Link regex `\[…\]\(([^\s)]+)\)` | No reference links, titles, `<…>` destinations or balanced parentheses. `web/src/markdownLinks.ts` handles all of these. |
| 6 | `SearchEngine` | ICU regex syntax instead of the documented JavaScript syntax, which is a user-visible change (README, "Find & replace"). Native ECMAScript engines exist (see §3), so this isn't necessary. |
| 7 | `snapshot(docId:)` | `snapshots = [revision: text]` drops older snapshots. If two saves overlap, the first `markSaved` is ignored and the document stays dirty. Keep a small map instead. |
| 8 | `project.yml`, `Info.plist`, README | The prototype bundle id and display name, and the "Native Prototype" README, must not reach `main`. |
| 9 | Paste, drag, `insertNewline:` | Only `insertText` is normalized. Add tests proving that paste (`readSelection(from:type:)`), drag-and-drop and the services menu also end up with the file's separator. |

Scope gap, already acknowledged in the prototype README: there is no live preview (hidden syntax), tables, images, math, Mermaid, sanitized HTML, `<details>`, footnotes, emoji, alerts or code highlighting. It's a styled source editor. Treat it as the starting point for the **editor shell** (Phase 2), not as the migration itself.

## 2. Inventory: what JS does today

About 2.7k lines of our own TypeScript in `web/src`, plus these upstream packages:

| Component | Our code | Upstream JS | Role |
|---|---|---|---|
| Editor core | `editor.ts`, `textDiff.ts`, `flash.ts`, `context.ts`, `bridge.ts`, `main.ts` | `@codemirror/state`, `view`, `commands` | Text model, undo, keymaps, Swift bridge |
| Incremental Markdown parse | `syntax/{math,footnote,emoji}.ts` | `@lezer/markdown` (+ GFM), `@codemirror/lang-markdown` | Syntax tree used by live preview |
| Live preview (inline) | `livePreview/inline.ts`, `state.ts` | — | Hide syntax off-cursor, bullets, tasks, images, links, emoji, footnote refs |
| Live preview (blocks) | `livePreview/blocks.ts`, `widgets.ts` | — | Tables, HTML, math and Mermaid blocks shown as widgets |
| GitHub HTML render | `render/html.ts` | `unified`, `remark-parse`, `remark-gfm`, `remark-gemoji`, `remark-rehype`, `rehype-raw`, `rehype-sanitize`, `rehype-stringify`, `unist-util-visit` | Render table and HTML blocks with GitHub's sanitizer schema |
| Math | `render/math.ts` | `katex` (+ CSS) | `$…$` and `$$…$$` |
| Diagrams | `render/mermaid.ts` | `mermaid` (+ d3, dagre, …) | Mermaid diagrams, light and dark themes |
| Emoji data | `syntax/emoji.ts` | `gemoji` | `:shortcode:` lookup |
| Theme | `styles/app.css` | `github-markdown-css` | GitHub look, light and dark |
| Code highlighting | `editor.ts` | `@codemirror/language-data`, `@lezer/highlight` | Fenced code blocks and non-Markdown files |
| Links, anchors, footnotes | `links.ts`, `markdownLinks.ts`, `anchors.ts`, `footnotes.ts`, `render/slug.ts` | — | ⌘-click, reference definitions, heading slugs |
| Find | `find.ts`, `search/engine.ts` | `@codemirror/search` | Find bar; also bundled for Find in Files through JavaScriptCore |

Swift integration points to delete at the end: `EditorHost` (WKWebView + `callAsyncJavaScript`), `EditorWebView`, `LocalResourceSchemeHandler`, `SearchEngine` (JavaScriptCore), the `web/build.sh` pre-build phase, `web.yml`, and the npm entry in `dependabot.yml`.

## 3. Native replacements (verified 2026-11-13)

Rule: take a maintained compiled library when one exists, so upstream fixes arrive through a version bump. Port to Swift only our own glue, and the pieces with no native equivalent.

| JS component | Native replacement | Language | Notes |
|---|---|---|---|
| CodeMirror view and state | `NSTextView` (TextKit 1 or 2; decided in the Phase 1 spike), or `STTextView` (TextKit 2, ★1.6k) | Swift / AppKit | The prototype's `EditorHost` is the base. |
| Lezer Markdown (incremental, for live preview) | `tree-sitter-markdown` (split block and inline grammars, GFM tables, task lists, strikethrough; crate `tree-sitter-md` 0.5.4) through `swift-tree-sitter` + `Neon` | C + Swift | Incremental and byte-range based, a direct analogue of Lezer. Footnotes, math and emoji are small extra passes, as today's custom Lezer extensions already are. |
| remark/rehype (GitHub semantics for rendered blocks) | **comrak** 0.59 (Rust): `table`, `tasklist`, `strikethrough`, `autolink`, `footnotes`, `alerts`, `math_dollars`, `shortcodes`, plus sourcepos | Rust | Covers everything `remark-gfm` + `remark-gemoji` + our math syntax do. Alternative: `cmark-gfm` (GitHub's C fork), but it lacks alerts, math and shortcodes. |
| rehype-sanitize (GitHub schema) | **ammonia** 4.2 (html5ever based), configured from the generated GitHub schema (§4A) | Rust | Same allow-list approach. |
| Rendering sanitized HTML (`<details>`, `<img>`, `<kbd>`, `<sub>`, tables, …) | Our own renderer: sanitized DOM (ammonia output parsed with `SwiftSoup`, or html5ever on the Rust side) mapped to `NSAttributedString` or small `NSView`s | Swift | No web engine. Supports GitHub's allowed tag subset and falls back to source for anything else. `NSAttributedString(html:)` is rejected because it uses WebKit internally and is main-thread only. |
| KaTeX | **SwiftMath** (iosMath port, CoreText, MIT) | Swift | Covers common LaTeX math. Unsupported commands fall back to source, and coverage is tracked by the conformance corpus (§4B). |
| Mermaid | **mermaid-rs-renderer** 0.3 (pure Rust, 23 diagram types, ★1.8k) to SVG, then **resvg** 0.50 to a `CGImage` | Rust | Highest-risk item: upstream says it is "under active early development". Diagrams that fail to render fall back to source. |
| gemoji | Generated Swift table (§4A) | Swift | Data only. |
| github-markdown-css | Generated `GitHubTheme` tokens for light and dark (§4A) | Swift | Data only. |
| language-data + Lezer highlight | tree-sitter grammars + `highlights.scm` queries through Neon (the same infrastructure as the Markdown parser; also handles injections into fenced code) | C + Swift | Start with the top ~25 languages. Alternative: `syntect` (Rust, Sublime grammars, ~200 languages, not incremental). |
| `@codemirror/search` + JS regex | **regress** 0.12 (Rust, ECMAScript regex syntax and semantics) | Rust | Keeps the documented JS regex behavior, unlike the prototype's ICU. Keep the prototype's `Source` offset mapping and `$&`/`$1`/`\n` templating. |
| Our TS (live preview, links, anchors, footnotes, slug, textDiff, find) | Hand port | Swift | No upstream to follow. Port once and keep the behavior locked with converted tests (§4C). |

Packaging the Rust code: one crate, `native/mdb-core` (comrak, ammonia, regress, mermaid-rs-renderer, resvg), exposed through **UniFFI** 0.32. It's built by `native/build.sh` into a static library for Apple silicon (the only platform the app targets), with a hash stamp so unchanged sources are skipped, as `web/build.sh` does today. The Rust toolchain replaces Node as a build requirement, and Dependabot gets a `cargo` entry. tree-sitter stays C and comes in through SwiftPM.

## 4. "Follow upstream": what can be converted

A general TS→Swift transpiler isn't viable. CodeMirror, unified and Mermaid depend on the DOM and on dynamic JS idioms, and Mermaid alone pulls in d3, dagre and cytoscape. Preferring compiled libraries (§3) already covers most upstream tracking. For the rest, four converters are realistic:

### A. Data generators (`scripts/codegen/`, run in CI; outputs committed as `*.generated.swift` / `.rs`)

| Source package | Output | Tracks |
|---|---|---|
| `gemoji` `db.json` | `Emoji.generated.swift` (shortcode to emoji) | New emoji |
| `github-markdown-css` | `GitHubTheme.generated.swift` (CSS custom properties for light and dark: colors, font sizes, spacing, code and alert colors) | GitHub restyles |
| `hast-util-sanitize` `defaultSchema` (GitHub's schema) + our additions from `render/html.ts` | `sanitize_schema.generated.rs` (ammonia allow-list) | Security allow-list changes |
| `@codemirror/language-data` | `Languages.generated.swift` (name, aliases, extensions, mapped to a tree-sitter grammar) + a list of unmapped languages | New languages and aliases |
| `katex` function list | Coverage report (KaTeX functions that SwiftMath doesn't support) | Math gaps |

The generators run in a scheduled CI job with Node as a CI-only dependency. If the output changes, the job opens a PR, so upstream bumps arrive as reviewable Swift diffs.

### B. Conformance goldens (differential testing)

`web/` becomes a dev-only oracle under `tools/oracle/`. A Node script runs the current JS implementation over a corpus: the CommonMark spec, the GFM spec, `Samples/`, today's vitest fixtures and the Mermaid upstream examples. It writes JSON goldens covering:

- block segmentation and kinds (from `blocks.ts`)
- inline hide and reveal ranges per cursor position (`inline.ts`)
- sanitized HTML (`render/html.ts`)
- slugs and anchors
- footnote and reference resolution
- find and replace results (`search/engine.ts`)

Swift tests load the goldens and compare. Bumping an upstream JS package and regenerating turns any behavior change into a failing Swift test, which is how hand-ported logic keeps up with upstream fixes. The oracle stays after `web/` is deleted from the app.

### C. Test converter (one-off)

Extract the 67 vitest cases in `web/test/*.test.ts` (most are literal input and expectation pairs) into Swift Testing parameterized tables. Do it with a script plus manual cleanup for DOM-dependent cases.

### D. Own code

Port it once, by hand, with LLM assistance file by file in dependency order: `slug`, `markdownLinks`, `footnotes`, `anchors`, `search`, `inline`, `blocks`, `widgets`. B and C lock in the behavior.

## 5. Phases

**Phase 0: groundwork (on `main`; small PRs)**
1. Bring over `native.yml` from the prototype and make Swift tests a required PR check.
2. Fix the `PreviewTabTests` headless flake: force tab-bar layout, or hit-test through the window's tab group rather than screen coordinates.
3. Add `tools/oracle` and the first goldens (§4B), plus the vitest-to-Swift converter (§4C).
4. Rebase or cherry-pick the useful prototype parts: `EditorHost` byte-preservation logic, `SearchEngine.Source`, `NativeEditorTests`. Drop the bundle-id, README and CI deletions.

**Phase 1: spikes (decision gates, about one week each, in parallel)**
- **Text engine.** Live preview needs two things while the text storage stays the raw source:
  - inline syntax hiding: TextKit 1 can hide glyphs through `NSLayoutManagerDelegate.shouldGenerateGlyphs` (null glyph property); TextKit 2 has no public equivalent.
  - block widget replacement: TextKit 2 can substitute a custom `NSTextLayoutFragment`.

  Prototype TextKit 1, TextKit 2 and STTextView. The decision is based on IME, accessibility (VoiceOver), and 10k-line performance.
- **Rust core.** Build a UniFFI + xcframework skeleton, check that sandbox and hardened runtime still work, measure the build-time impact, and add a release-workflow job.
- **Mermaid fidelity.** Render the Mermaid example corpus with mermaid-rs-renderer and resvg and diff the output against Mermaid. Decide which diagram types to enable and which fall back to source.

**Phase 2: native search (smallest shippable win; removes JavaScriptCore)**

Replace JavaScriptCore with `mdb-core::search` (regress) and keep JS regex syntax. Must pass the find and replace goldens. Delete `search-engine.js` and `vite.engine.config.ts`.

**Phase 3: native editor shell behind a flag**

Add a hidden `AppSettings.nativeEditor` setting. `DocumentArea` picks the web or native `DocumentEditor`.
- Fix review items 1–9.
- Style through tree-sitter-markdown, incrementally, re-styling only the edited ranges.
- Add tree-sitter code highlighting for non-Markdown files.
- Port `slug` and `markdownLinks`, and add ⌘-click links.

Progress on `feat/native-core`: the hidden setting defaults off, and the native shell uses `NSTextView` with Rust-backed find and replace. It currently edits raw Markdown source only; Markdown styling, live preview, clickable links and code highlighting are still pending. For a local run, set `defaults write com.guillaumewinter.MarkdownBrowser nativeEditor -bool YES`; newly created workspaces use the selected editor. Typed, pasted and plain-text drop insertions use the file's line separator; tests cover the drop reader path and a marked-text commit, but real drag/drop and IME interaction still need manual validation. Anchor lookup handles percent-decoded fragments, the `user-content-` prefix, duplicate heading slugs and explicit HTML `id`/`name` attributes. Full Markdown link parsing and command-click navigation remain pending.

**Phase 4: inline live preview**

Hide syntax away from the cursor. Add bullets, task checkboxes (toggling edits the source), emphasis, links, inline images (local loading through `PathPolicy`, which replaces `LocalResourceSchemeHandler`), emoji (generated table), footnote references and anchors.

**Phase 5: block widgets**

Tables (comrak to native grid), alerts, sanitized HTML and `<details>` (comrak, ammonia, then the Swift renderer), math (SwiftMath), Mermaid (Rust to SVG to `CGImage`, cached per theme, follows light and dark mode). Each widget falls back to source on failure.

**Phase 6: parity and removal**
- All goldens are green or have documented exceptions.
- The `Samples/` manual checklist passes.
- Performance meets budget: 10k-line document, typing latency under 16 ms.
- A security review covers: sanitizer schema, no script execution, image path policy, link schemes (`http`, `https`, `mailto` only).

Then flip the default and remove `web/` from the app build. Delete `EditorWebView`, `LocalResourceSchemeHandler`, the web `EditorHost`, `web.yml`, the npm Dependabot entry, and the Node requirement and editor docs in README and CONTRIBUTING (rewrite the "Architecture" and "Rules worth knowing" sections).

## 6. Risks and fallbacks

| Risk | Mitigation |
|---|---|
| Live preview on TextKit (hiding syntax, block widgets) is the hard part. | Phase 1 spike first. Fallback: ship the styled-source editor plus rendered block widgets, without inline hiding. |
| Mermaid fidelity (mermaid-rs-renderer is early-stage) | Enable diagram types per corpus results and fall back to source. Last resort, only if you explicitly accept it: render Mermaid alone in an offscreen, script-isolated web view and keep only the resulting SVG. |
| KaTeX coverage with SwiftMath | Coverage report (§4A); fall back to source; contribute fixes upstream. |
| Raw HTML without a web engine | Limit to GitHub's sanitized subset and fall back to source. |
| Two Markdown parsers (tree-sitter for the editor, comrak for blocks) | Mirrors today's Lezer and remark split, and goldens catch divergence. Alternative to evaluate in Phase 1: comrak only, re-parsing changed blocks (simpler, but not incremental). |
| Rust toolchain in the build | Hash-stamped build like `web/build.sh`; prebuilt xcframework cached in CI. |
| Byte preservation | Keep the "never re-serialize" rule; tests for paste, drag, IME and newline paths (review item 9). |
