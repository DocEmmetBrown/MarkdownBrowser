import Foundation
import MdbCore

/// Find and replace with the find bar's semantics (JavaScript regex, CodeMirror's cursors), run natively by the Rust
/// core (native/mdb-core). goldens/search.json records the JavaScript results it must reproduce. Not thread-safe:
/// create one per task.
nonisolated final class SearchEngine {
    struct Match: Equatable {
        /// 1-based line number.
        let line: Int
        /// UTF-16 offsets, counting each line break as one unit, as the editor does.
        let column: Int
        let length: Int
    }

    private var cached: (options: SearchOptions, searcher: Searcher)?

    /// The JavaScript-style error message for an invalid regular expression, or nil.
    func validate(_ options: SearchOptions) -> String? {
        searcher(options).validationError()
    }

    func matches(in text: String, lineSeparator: String, options: SearchOptions, limit: Int) -> [Match] {
        searcher(options).find(text: text, lineSeparator: lineSeparator, limit: UInt32(clamping: max(0, limit))).map {
            Match(line: Int($0.line), column: Int($0.column), length: Int($0.length))
        }
    }

    /// Replaces every match; in regex mode `template` may use `$&`, `$1`… and `\n`, as in the find bar.
    func replace(in text: String, lineSeparator: String, options: SearchOptions, template: String) -> (
        text: String, count: Int
    ) {
        let result = searcher(options).replace(text: text, lineSeparator: lineSeparator, template: template)
        return (result.text, Int(result.count))
    }

    func replaceMatch(
        in text: String, lineSeparator: String, options: SearchOptions, line: Int, column: Int, template: String
    ) -> String? {
        searcher(options).replaceMatch(
            text: text,
            lineSeparator: lineSeparator,
            line: UInt32(clamping: line),
            column: UInt32(clamping: column),
            template: template)
    }

    private func searcher(_ options: SearchOptions) -> Searcher {
        if let cached, cached.options == options { return cached.searcher }
        let searcher = Searcher(
            query: SearchQuery(search: options.query, caseSensitive: options.caseSensitive, regexp: options.regex))
        cached = (options, searcher)
        return searcher
    }
}
