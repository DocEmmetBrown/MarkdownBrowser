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
| Code highlighting | syntect, background highlighting |
| Emoji | Comrak's shortcode extension |
| Resource permissions | Workspace grants and canonical `PathPolicy` checks |

The native editor is unconditional; the experimental preference and web-host switching have been removed. There is one editing pane. Selection reveals the active block's source; other blocks render in place. Inline emphasis, code and link markers reveal when the selection touches them. Command-U reveals all source without replacing the editor or resetting selection/undo. Source remains authoritative for saving, including encoding, BOM and untouched line separators.

## Deliberate differences

- TextKit 1 provides the public glyph-generation delegate used for presentation-only concealment and layout reservation. Source characters are never replaced with attachments or rendered text. Clicking a rendered block reveals its source beginning, not an exact rendered-character position. Command-click follows rendered and source links.
- Native styling replaces GitHub CSS; this is GitHub-flavored Markdown, not pixel-identical GitHub rendering.
- Comrak full parses are debounced and run off-main after edits. Changed source styles are applied selectively, but parsing is not incremental; tree-sitter has not been introduced.
- syntect replaces the originally proposed tree-sitter language grammars.
- HTML supports the implemented native elements, not arbitrary CSS/browser layout.
- SwiftMath is not KaTeX, and the Rust Mermaid implementation is not Mermaid.js. Unsupported expressions/diagrams retain source; diagram failures show an error and math failures are logged.
- No development-only Node oracle or Node data generator remains. The existing search goldens are retained as a static compatibility corpus. Native tests are the ongoing conformance mechanism; exact browser-renderer equivalence is not claimed.

## Validation and remaining release checks

Automated tests cover parser ranges (Unicode, CRLF), nested/reference links and anchors, source-only styling, stale parse rejection, marked-text preservation, task edits and undo, single-pane layout and resize, inline marker reveal, multiline block geometry, common math, resource traversal/symlinks/schemes, sanitization, code highlight ranges, Mermaid PNG generation, saving and search-golden replay.

The 10k-line insertion test records only editor insertion time, excluding display/layout. It does **not** establish the original under-16-ms end-to-end goal. Use Instruments with the preview visible before making that claim.

Remaining manual/release checks:

- Real IME interaction, drag/drop, VoiceOver and keyboard navigation.
- The complete `Samples/` light/dark visual checklist, including disclosure groups, navigation and media permission prompts.
- Representative KaTeX/Mermaid compatibility corpora; unsupported features are documented fallbacks, not proven parity.
- End-to-end 10k-line typing latency, retained memory and large-folder responsiveness.
- A distribution build on the minimum supported macOS. This development toolchain currently emits Rust standard-library minimum-OS linker warnings; local execution on a newer macOS is not proof of macOS 14 compatibility.

See [CONTRIBUTING](CONTRIBUTING.md) for native build commands and the manual checklist.
