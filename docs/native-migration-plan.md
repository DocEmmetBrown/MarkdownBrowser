# Native migration status

## Implemented

The app now uses Swift/AppKit/SwiftUI and Rust only. There is no bundled web editor, JavaScript runtime, Node/npm build requirement, web CI job or npm dependency-update job.

| Component | Native implementation |
|---|---|
| Editable source, undo, selection, IME | `NSTextView`, TextKit 1 |
| Markdown structure and original UTF-16 ranges | Comrak |
| Find bar and Find in Files | Shared Rust `regress` search engine |
| Heading slugs, reference links, footnotes | Parser-backed native navigation |
| Source styling | Attribute-only updates, debounced background parses |
| In-place rendering | Presentation-only glyph concealment and embedded native SwiftUI blocks |
| Tables, tasks, lists, details | Native grids, checkboxes and disclosure groups |
| HTML | Comrak HTML, ammonia sanitizer, flattened native rendering tree |
| Math | SwiftMath 1.7.3 |
| Mermaid | mermaid-rs-renderer, resvg PNG rendering |
| SVG images | resvg, with image resource resolution disabled |
| Code highlighting | syntect with bat-curated two-face grammars, background highlighting |
| Emoji | Comrak's shortcode extension |
| Resource permissions | Workspace grants and canonical `PathPolicy` checks |

The native editor is unconditional; the experimental preference and web-host switching have been removed. There is one editing pane. Clicking rendered prose, code or table text maps the caret to its original UTF-16 source position; double-click, Shift-click and dragging select source text. The clicked row stays anchored as surrounding blocks resize. Selection reveals the active block's source; other blocks render in place. Inline emphasis, code and link markers reveal when the selection touches them. Command-U reveals all source without replacing the editor or resetting selection/undo. Source remains authoritative for saving, including encoding, BOM and untouched line separators.

## Deliberate differences

- TextKit 1 provides the public glyph-generation delegate used for presentation-only concealment and layout reservation. Source characters are never replaced with attachments or rendered text. Images, video, diagrams and math target their source construct rather than infer characters from pixels. Raw HTML text maps through scoped provenance; unsupported or ambiguous fragments retain an enclosing-block fallback. Command-click follows rendered and source links.
- Native styling replaces GitHub CSS; this is GitHub-flavored Markdown, not pixel-identical GitHub rendering.
- Comrak full parses are debounced and run off-main after edits. Changed source styles are applied selectively, but parsing is not incremental; tree-sitter has not been introduced.
- syntect replaces the originally proposed tree-sitter language grammars.
- HTML supports the implemented native elements, not arbitrary CSS/browser layout.
- SwiftMath is not KaTeX, and the Rust Mermaid implementation is not Mermaid.js. Unsupported expressions/diagrams retain source; diagram failures show an error and math failures are logged.
- No development-only Node oracle or Node data generator remains. The existing search goldens are retained as a static compatibility corpus. Native tests are the ongoing conformance mechanism; exact browser-renderer equivalence is not claimed.

## Validation and remaining release checks

Automated tests cover parser ranges (Unicode, CRLF), nested/reference links and anchors, source-only styling, stale parse rejection, marked-text preservation, task edits and undo, single-pane layout and resize, inline marker reveal, exact click-to-source positions, word/Shift/drag selection, scrolled caret anchoring, multiline block geometry, common math, resource traversal/symlinks/schemes, sanitization, code highlight ranges, Mermaid PNG generation, saving and search-golden replay.

Additional native tests cover repeated raw HTML text, entities and quoted attributes, source shifts before reparsing, widget-specific targets, accessibility edit actions, native arrow-key entry into rendered blocks, and undo after accessibility-driven editing. Rust tests verify provenance cannot be forged and annotations preserve sanitized visible text.

Swift and TypeScript fences use the extended grammar set rather than syntect's plain-text fallback. Rust tests verify distinct token colors and complete UTF-16 coverage for Swift, TypeScript, Rust, Python and JavaScript in both themes; native-view tests check the actual displayed colors for Swift and TypeScript while preserving source bytes.

Light/dark native window fixtures were captured and visually inspected for tables/alignment, alerts, tasks, details, inline/display math, Mermaid, code, local images and denied image/video access. This caught and fixed oversized table columns, unnecessary image/diagram upscaling, hidden-source background painting, and video tasks that never started from an empty loading view. Captures are Swift Testing attachments; no external browser or screen-capture permission is required.

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
- Representative KaTeX/Mermaid compatibility corpora; unsupported features are documented fallbacks, not proven parity.
- Sustained 10k-line typing, latency optimization toward 16 ms, retained-memory profiling and large-folder responsiveness.
- A distribution build on the minimum supported macOS. This development toolchain currently emits Rust standard-library minimum-OS linker warnings; local execution on a newer macOS is not proof of macOS 14 compatibility.

See [CONTRIBUTING](CONTRIBUTING.md) for native build commands and the manual checklist.
