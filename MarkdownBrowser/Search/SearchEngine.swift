import Foundation
import JavaScriptCore

/// Runs the editor's own search code (web/src/search/engine.ts) so Find in Files matches exactly what the find bar
/// matches. Not thread-safe: create one per task.
nonisolated final class SearchEngine {
    struct Match: Equatable {
        /// 1-based line number.
        let line: Int
        /// UTF-16 offsets, counting each line break as one unit, as the editor does.
        let column: Int
        let length: Int
    }

    private let context: JSContext
    private let api: JSValue

    static var scriptURL: URL? {
        Bundle.main.url(forResource: "search-engine", withExtension: "js", subdirectory: "Web")
    }

    init() throws {
        guard
            let url = Self.scriptURL, let source = try? String(contentsOf: url, encoding: .utf8),
            let context = JSContext()
        else { throw SearchError.engineUnavailable }
        context.evaluateScript(source, withSourceURL: url)
        guard context.exception == nil, let api = context.objectForKeyedSubscript("mdbSearch"), api.isObject else {
            throw SearchError.engineUnavailable
        }
        self.context = context
        self.api = api
    }

    /// The JavaScript error message for an invalid regular expression, or nil.
    func validate(_ options: SearchOptions) -> String? {
        let result = call("validate", [query(options)])
        return result?.isString == true ? result?.toString() : nil
    }

    func matches(in text: String, lineSeparator: String, options: SearchOptions, limit: Int) -> [Match] {
        guard let numbers = call("find", [text, lineSeparator, query(options), limit])?.toArray() as? [NSNumber] else {
            return []
        }
        return stride(from: 0, to: numbers.count - 2, by: 3).map {
            Match(line: numbers[$0].intValue, column: numbers[$0 + 1].intValue, length: numbers[$0 + 2].intValue)
        }
    }

    /// Replaces every match; in regex mode `template` may use `$&`, `$1`… and `\n`, as in the find bar.
    func replace(in text: String, lineSeparator: String, options: SearchOptions, template: String) -> (
        text: String, count: Int
    ) {
        guard
            let result = call("replace", [text, lineSeparator, query(options), template]),
            let replaced = result.forProperty("text")?.toString(),
            let count = result.forProperty("count")?.toNumber()?.intValue
        else { return (text, 0) }
        return (replaced, count)
    }

    private func query(_ options: SearchOptions) -> [String: Any] {
        ["search": options.query, "caseSensitive": options.caseSensitive, "regexp": options.regex]
    }

    private func call(_ name: String, _ arguments: [Any]) -> JSValue? {
        context.exception = nil
        let result = api.invokeMethod(name, withArguments: arguments)
        return context.exception == nil ? result : nil
    }
}
