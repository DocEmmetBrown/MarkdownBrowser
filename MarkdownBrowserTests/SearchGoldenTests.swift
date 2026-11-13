import Foundation
import Testing

@testable import MarkdownBrowser

/// Replays `goldens/search.json`, recorded from the editor's JavaScript engine (`web/test/searchGoldens.test.ts`),
/// so Find in Files keeps matching exactly like the find bar whichever engine runs it.
@Suite struct SearchGoldenTests {
    private struct Goldens: Decodable {
        struct Doc: Decodable {
            let name: String
            let text: String
            let lineSeparator: String
        }

        struct Replacement: Decodable {
            let template: String
            let count: Int
            let text: String?
        }

        struct Case: Decodable {
            let doc: Int
            let search: String
            let caseSensitive: Bool
            let regexp: Bool
            let valid: Bool
            let find: [Int]
            let replacements: [Replacement]
        }

        let docs: [Doc]
        let cases: [Case]
    }

    private final class BundleToken {}

    @Test func searchMatchesTheJavaScriptEngine() throws {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: "search", withExtension: "json", subdirectory: "goldens"))
        let goldens = try JSONDecoder().decode(Goldens.self, from: Data(contentsOf: url))
        let engine = SearchEngine()
        var failures: [String] = []
        for golden in goldens.cases {
            let doc = goldens.docs[golden.doc]
            let options = SearchOptions(query: golden.search, caseSensitive: golden.caseSensitive, regex: golden.regexp)
            let label = "\(doc.name) \(golden.regexp ? "/" : "\"")\(golden.search.debugDescription)"
                + "\(golden.caseSensitive ? "" : " (ignoring case)")"
            if (engine.validate(options) == nil) != golden.valid {
                failures.append("\(label): valid should be \(golden.valid)")
            }
            let limit = doc.name == "long" ? 300 : 10_000
            let found = engine.matches(in: doc.text, lineSeparator: doc.lineSeparator, options: options, limit: limit)
                .flatMap { [$0.line, $0.column, $0.length] }
            if found != golden.find { failures.append("\(label): found \(found), expected \(golden.find)") }
            for replacement in golden.replacements {
                let result = engine.replace(
                    in: doc.text, lineSeparator: doc.lineSeparator, options: options, template: replacement.template)
                let expected = replacement.text ?? doc.text
                if result.count != replacement.count || result.text != expected {
                    failures.append(
                        "\(label) -> \(replacement.template.debugDescription): replaced \(result.count) "
                            + "\(result.text.debugDescription), expected \(replacement.count) \(expected.debugDescription)")
                }
            }
        }
        #expect(goldens.cases.count > 1000)
        #expect(failures.isEmpty, "\(failures.count) mismatches:\n\(failures.prefix(30).joined(separator: "\n"))")
    }
}
