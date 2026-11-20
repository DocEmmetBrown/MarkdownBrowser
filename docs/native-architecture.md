# Native architecture and validation

## Native does not mean Swift-only

**MarkdownBrowser is a native Swift + Rust application, not an all-Swift application.**
The interface and editable document live in Swift/AppKit/SwiftUI. Text processing,
syntax highlighting and some image generation run in a compiled Rust library
linked into the same process.

There is no embedded WebKit editor, JavaScript engine, Node process or web-based
fallback. HTML and JavaScript can appear as document content or highlighting
languages; that does not make them executable application code.

The split is intentional: keep macOS interaction and document ownership in
Swift, and reuse native libraries for specialized parsing and rendering rather
than implement every format from scratch. Rust is native machine code here,
not an interpreter or remote service. This does not imply these features could
not be implemented in Swift.

## Runtime architecture

### What stays in Swift

| Responsibility | Implementation and reason |
|---|---|
| Windows, tabs, menus and sidebar | AppKit/SwiftUI in [Window](../MarkdownBrowser/Window/), [Views](../MarkdownBrowser/Views/) and [Workspace](../MarkdownBrowser/Workspace/). These are macOS interactions, not responsibilities of the Rust core. |
| Editable source, selection, undo and IME | [NativeEditorHost](../MarkdownBrowser/Editor/NativeEditorHost.swift) owns one `NSTextView`. TextKit 1 supplies the public glyph-generation hooks needed to conceal syntax without replacing document characters. |
| In-place presentation and click mapping | [NativeLivePreview](../MarkdownBrowser/Editor/NativeLivePreview.swift) reserves layout space and hosts nearby SwiftUI blocks. [NativePreview](../MarkdownBrowser/Editor/NativePreview.swift) chooses native controls and applies fonts, colors and source-position maps. Rust does not create views or control focus. |
| Encoding, saving, conflicts and recovery | [OpenDocument](../MarkdownBrowser/Document/OpenDocument.swift) and [TextCodec](../MarkdownBrowser/Document/TextCodec.swift) preserve encoding, BOM and line separators. Revision-tagged snapshots prevent acknowledging newer edits as saved. |
| Filesystem access and permissions | [Access](../MarkdownBrowser/Access/) manages user grants, security-scoped URLs and canonical path checks. Swift also enumerates files and coordinates multi-file search/replacement. |
| Math | [NativeMath](../MarkdownBrowser/Editor/NativePreview.swift) uses the third-party **SwiftMath** package, pinned in [project.yml](../project.yml). It supplies native mathematical typesetting without writing a TeX layout engine or using a web renderer. Results are display images/attachments, never replacements in editable storage. |
| Images, video and other files | AppKit/ImageIO, AVKit/AVFoundation and Quick Look in [Viewers](../MarkdownBrowser/Viewers/Viewers.swift) and [NativePreview](../MarkdownBrowser/Editor/NativePreview.swift). These are Apple system frameworks, not bundled browser UI. |

SwiftMath is a library dependency rather than project-owned Swift code, but it
does not cross the Swift/Rust boundary. It is the only SwiftPM package declared
by the project.

### Where non-Swift code is embedded, and why

The direct Rust dependencies are declared in [mdb-core/Cargo.toml](../native/mdb-core/Cargo.toml).
Their transitive dependencies are locked in [Cargo.lock](../native/Cargo.lock).

| Capability | Compiled Rust libraries | Boundary and rationale |
|---|---|---|
| Markdown parsing, structure and navigation | **Comrak**, plus **unicode-general-category** for heading slugs | [markdown.rs](../native/mdb-core/src/markdown.rs) returns flat Markdown records, parent indexes and original UTF-16 source ranges. A source-ranged GFM parser supports tables, tasks, reference links, footnotes and shortcodes without maintaining a separate parser in Swift. The ranges are essential to in-place editing without reformatting source. |
| HTML sanitization and interpretation | **Comrak**, **ammonia**, **scraper** | [render.rs](../native/mdb-core/src/render.rs) formats a rendering copy, sanitizes it and returns a flat element/text tree. This reuses native HTML parsing and sanitization instead of a browser DOM. Swift renders only its supported elements. |
| Find and replace | **regress**, **unicode-normalization** | [search.rs](../native/mdb-core/src/search.rs) shares one matching/replacement implementation between the find bar and Find in Files. `regress` provides ECMAScript regex semantics; Foundation's ICU regular expressions are not interchangeable. Normalization and UTF-16 mapping preserve the search contract checked by the shared corpus. |
| Code highlighting | **syntect**, **two-face** | [highlight_source](../native/mdb-core/src/render.rs) returns UTF-16 ranges and RGB colors, not HTML or views. Reusing maintained language grammars avoids building a tokenizer for each language. The extended set includes Swift and TypeScript, absent from syntect's defaults. Both use the pure-Rust fancy-regex backend. |
| Mermaid diagrams | **mermaid-rs-renderer**, then **resvg** | [render_diagram](../native/mdb-core/src/render.rs) performs diagram layout and produces SVG, then rasterizes it to PNG. This keeps diagram generation local and compiled, without embedding Mermaid.js or a JavaScript runtime. Supported syntax is a subset, not full Mermaid.js parity. |
| SVG images | **resvg** | [rasterize_svg](../native/mdb-core/src/render.rs) turns SVG bytes into bounded PNG bytes for `NSImage`. The same rasterizer serves diagrams and SVG resources, with external and embedded image references disabled. |
| Swift/Rust interoperation | **UniFFI**; **thiserror** for Rust rendering errors | Generated Swift/C bindings expose typed records, Rust search objects and explicit errors. This avoids a hand-maintained C ABI and keeps a single native library boundary. UniFFI's command-line generator is a build tool, not a runtime service. |

Grammar definitions, themes, fonts and the search corpus are data, not scripting
engines. [Syntax-Notices.txt](../MarkdownBrowser/Resources/Syntax-Notices.txt)
contains the redistribution notices for the extended grammar assets.

## Data flow and document ownership

```text
File bytes
  -> Swift TextCodec / OpenDocument
  -> authoritative NSTextView text storage
       |
       +-> source copy -> Rust Markdown parser -> structure + UTF-16 ranges
       |
       +-> rendering copy -> Rust HTML formatting/sanitization -> flat render tree
       |                    -> SwiftUI/AppKit blocks, SwiftMath and native media
       |
       +-> code / Mermaid / SVG -> Rust -> color spans or PNG -> native display
       |
       +-> Swift SearchEngine -> Rust Searcher -> matches / replacement text
       |
       +-> versioned snapshot -> Swift TextCodec -> saved file bytes
```

Parsing and rendering never serialize an AST back into the document. Generated
HTML is an internal interchange step, not a page loaded into a browser. Math
attachments and rendered images belong only to read-only presentation views.
Search replacements are explicit, undoable edits to source.

The find bar and folder search share the Rust matcher; file enumeration, reading,
access checks and writing stay in Swift. See [SearchEngine](../MarkdownBrowser/Search/SearchEngine.swift)
and [FolderSearch](../MarkdownBrowser/Search/FolderSearch.swift).

There is one editing pane. Clicking rendered prose, code or table text maps the caret to its original UTF-16 source position; double-click, Shift-click and dragging select source text. The clicked row stays anchored as surrounding blocks resize. Selection reveals the active block's source; other blocks render in place. Inline emphasis, code and link markers reveal when the selection touches them. Command-U reveals all source without replacing the editor or resetting selection/undo. Source remains authoritative for saving, including encoding, BOM and untouched line separators.

## Build and FFI boundary

1. [project.yml](../project.yml) defines the Swift app, SwiftMath dependency and
   `MdbCore` static-library target. The app targets Apple silicon.
2. The target's prebuild phase runs [native/build.sh](../native/build.sh). Cargo
   compiles `mdb-core` for `aarch64-apple-darwin` into `libmdb_core.a`.
3. UniFFI generates ignored Swift bindings, a C header and a module map under
   `native/generated/`. The build declares these outputs so Swift never links
   stale bindings against a changed Rust API. XcodeGen registers the Swift path
   with `type: file`, keeping it in compile sources even before it exists on a
   clean checkout.
4. Xcode compiles the wrappers and links the Rust archive into the app. At
   runtime, calls are in-process native calls through the generated bindings:
   there is no separate Rust executable, JSON message channel or web bridge.

The bridge exchanges copied text/bytes, records and search handles rather than
live AppKit objects. Source maps use UTF-16 offsets to match `NSTextView`.
Build tools fetch dependencies as needed; document processing does not call a
remote rendering service. Explicit HTTP(S) image/video URLs load network media
only when "Load remote images and video" is on in Settings (off by default).

## Trust and execution boundaries

- Document HTML is untrusted data. Scripts, event handlers and CSS are not
  executed. Rust sanitizes a rendering copy before returning native render nodes.
- Raw HTML source mappings use generated provenance, not document-supplied
  position attributes. Swift bounds-checks mapped edits against their source block.
- Swift checks local resources against canonical, user-granted paths. SVG image
  resolvers cannot load other images; AVFoundation asset references are restricted.
- Rust runs inside the app's process and sandbox. This is **not process
  isolation**: native library bugs can still fail or crash the app. Input limits,
  explicit errors and tests remain necessary.
- Document/code processing and highlighting run locally. Neither JavaScript
  examples nor grammar files are evaluated as application code.

## Rendering and editing constraints

- TextKit 1 provides the public glyph-generation delegate used for presentation-only concealment and layout reservation. Source characters are never replaced with attachments or rendered text. Images, video, diagrams and math target their source construct rather than infer characters from pixels. Raw HTML text maps through scoped provenance; unsupported or ambiguous fragments retain an enclosing-block fallback. Command-click follows rendered and source links.
- GitHub-flavored Markdown uses native styles, not pixel-identical GitHub rendering.
- Comrak full parses are debounced and run off-main after edits. Changed source styles are applied selectively, but parsing is not incremental. Heading slugs retain per-base suffix counters and an occupied-slug set to avoid quadratic duplicate-heading work while preserving collisions with explicitly suffixed headings.
- syntect highlights code with the extended two-face grammars.
- HTML supports the implemented native elements, not arbitrary CSS layout.
- SwiftMath and the Rust Mermaid renderer support a subset of expressions and diagrams. Unsupported expressions/diagrams retain source; diagram failures show an error and math failures are logged.
- The shared search corpus checks validation, Unicode and multiline matches, and replacements in both Rust and Swift. Cached searchers compare exact UTF-8 query sequences as well as options: Swift's canonically equivalent string equality is not sufficient for regex patterns.

Background parsing on edits does not make every entry path asynchronous:
initial loading and explicit `ensureMarkdown()` calls can parse synchronously.
Using Rust also does not by itself guarantee a frame-time budget. The FFI layer
adds generated-code maintenance and data-copying costs, and the parser currently
builds separate structure and rendering trees.

A Swift-only implementation would need replacements for the Rust-backed
capabilities above and their conformance tests; it is not an existing editor
setting or fallback.

## Direct-AST presentation investigation

The more useful simplification is **parsing Markdown once**, not replacing the
specialized Rust engines with Swift equivalents. The current
[NativeMarkdown](../MarkdownBrowser/Editor/NativeMarkdown.swift) pipeline calls
`parseMarkdown` for structure and source ranges, then `renderMarkdown` through
`NativeRenderTree` for presentation. Each Rust entry point parses the same
Markdown with Comrak and builds its own source map. The rendering entry point
also formats HTML, sanitizes it with ammonia, reparses it with scraper and copies
a second flat tree across UniFFI.

A temporary prototype instead built presentation records directly in Swift from
the first parser result. It reused the existing native render-tree processing
and UTF-16 mapping so the comparison did not replace those costs with a stub.
The prototype supported prose, headings, emphasis, links and code, not the full
document format. It was removed from production sources after measurement.

Local Apple-silicon measurements against baseline `80806e0`, in milliseconds:

| Fixture | Build | Existing pipeline | Direct AST | Speedup |
|---|---|---:|---:|---:|
| Small styled paragraph with CRLF and emoji | Debug | 0.924 | 0.282 | 3.27x |
| Same small fixture | Release | 0.204 | 0.100 | 2.03x |
| 5,000 styled paragraphs / 10,000 lines | Debug | 1,453.12 | 457.24 | 3.18x |
| Same 10,000-line fixture | Release | 354.36 | 167.99 | 2.11x |
| 500 heading / Swift-code-block pairs | Debug | 103.25 | 27.69 | 3.73x |
| Same code-heavy fixture | Release | 22.05 | 8.17 | 2.70x |

Each value is the median of five warmed samples, alternating existing and direct
paths in a shared Swift Testing process. Both paths include the first Rust parse,
FFI transfers, native record indexing and UTF-16 source-map construction. Tests
required matching rendered block text, source ranges and every mapped block's
UTF-16 offsets for these fixtures. Both Debug and Release passed. Release used
`ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO` only for the local ad-hoc
test-host invocation; repository build/security settings were not changed.

These are synthetic, feature-limited **model-construction measurements**, not
end-to-end editing, frame-presentation, memory or full-format parity results.
They exclude `NativeMarkdown.children` construction, TextKit layout/drawing,
highlighting and media. Even the direct Release model takes about 168 ms for
10,000 lines: this does not meet the 16-ms interaction goal. Production still
uses the original renderer.

### Recommended implementation sequence

1. Extend the parser's typed metadata before replacing rendering. It currently
   discards table-column alignment and list tightness; `level == 0` also conflates
   bullet lists with ordered lists starting at zero. Preserve alert type when a
   custom title is present, and verify footnote ordering/backlinks explicitly.
2. Build ordinary Markdown presentation directly in Swift, initially reusing the
   flat native render model to avoid rewriting the views at the same time. Keep
   Comrak, source ranges and the specialized highlighting/diagram/SVG engines in
   Rust. Do not serialize the model back into editable source.
3. Retain the existing whole-document HTML path for documents containing raw
   HTML until mixed Markdown/HTML behavior has parity. Sanitizing each raw HTML
   AST node separately is not equivalent: a `<details>` opening and closing tag
   can surround parsed Markdown across multiple nodes.
4. Preserve URL policy, trusted HTML provenance, the 5 MB UTF-8 input limit,
   nesting/node budgets and explicit errors. The prototype's basic link check
   was not a replacement for the existing sanitizer. Any shared-parse HTML
   fallback must annotate a rendering copy, not mutate authoritative source.
5. Gate rollout on full feature/source-map parity tests, representative real
   documents and Release end-to-end editing measurements. Then consider sharing
   one Rust parse between structure and any remaining HTML fallback. The local
   speedup supports this direction, not shipping the partial prototype.

## Validation and remaining release checks

Automated tests cover parser ranges (Unicode, CRLF), nested/reference links and anchors, source-only styling, stale parse rejection, marked-text preservation, task edits and undo, single-pane layout and resize, inline marker reveal, exact click-to-source positions, word/Shift/drag selection, scrolled caret anchoring, multiline block geometry, common math, resource traversal/symlinks/schemes, sanitization, code highlight ranges, Mermaid PNG generation, saving and search-golden replay.

Additional native tests cover repeated raw HTML text, entities and quoted attributes, source shifts before reparsing, widget-specific targets, accessibility edit actions, native arrow-key entry into rendered blocks, and undo after accessibility-driven editing. Rust tests verify provenance cannot be forged and annotations preserve sanitized visible text.

Rust tests verify distinct token colors and complete UTF-16 coverage for Swift, TypeScript, Rust, Python and JavaScript in both themes; native-view tests check the actual displayed colors for Swift and TypeScript while preserving source bytes.

Light/dark native window fixtures cover tables/alignment, alerts, tasks, details, inline/display math, Mermaid, code, local images and denied image/video access. Captures are Swift Testing attachments and have been visually inspected. They also check table bounds/alignment, nonoverlapping blocks and denied-resource reporting.

The visible 10,000-line test uses 5,000 Markdown blocks in a 900x600 window and types at the beginning, middle and end. A local Debug run measured:

| Measurement | Observed |
|---|---|
| Insertion through synchronous AppKit layout/draw completion | 46-65 ms |
| Edit through debounced reparse and subsequent layout/draw | 2.28-2.50 s |
| Simultaneously hosted rendered blocks | 19-24 |
| Process RSS growth after load / after three edits and scrolling | About 29 MiB / 22 MiB |

These are three samples in a shared test process, not percentile, leak, standalone memory-footprint or hardware presentation guarantees. The **under-16-ms goal is not met**. Profiling exposed a full block scan per line fragment and full-document invalidation for each measured block height; these are now indexed and range-limited. Parsing remains nonincremental. The older insertion-only timing still excludes display/layout.

Remaining manual/release checks:

- Physical IME interaction, drag/drop, live VoiceOver and complete keyboard-only workflows. Native AX actions, source-editor roles, arrow keys and simulated composition are tested, not human assistive-technology parity.
- The complete `Samples/` light/dark visual checklist, including external media playback, navigation and real permission prompts. Local fixtures and denied-resource states are covered automatically.
- Broader math-expression and Mermaid-diagram compatibility corpora; unsupported features are documented fallbacks, not proven parity.
- Sustained 10k-line typing, latency optimization toward 16 ms, retained-memory profiling and large-folder responsiveness.
- A distribution build on the minimum supported macOS. This development toolchain currently emits Rust standard-library minimum-OS linker warnings; local execution on a newer macOS is not proof of macOS 14 compatibility.

See [CONTRIBUTING](CONTRIBUTING.md) for native build commands and the manual checklist.
