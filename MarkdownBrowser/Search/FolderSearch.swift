import Foundation

nonisolated struct SearchOptions: Sendable, Equatable {
    var query: String
    var caseSensitive = false
    var regex = false
}

nonisolated struct SearchHit: Identifiable, Hashable, Sendable {
    let url: URL
    /// 1-based line number.
    let line: Int
    /// Match position within the line, in UTF-16 code units (what the editor uses).
    let column: Int
    let length: Int
    let preview: String
    let previewMatch: NSRange

    var id: String { "\(url.path):\(line):\(column)" }
}

nonisolated struct SearchFileResult: Identifiable, Sendable {
    let url: URL
    let hits: [SearchHit]
    var id: URL { url }
}

/// Where search text comes from: the file on disk, or an open editor's live (possibly unsaved) text.
nonisolated enum SearchSource: Sendable {
    case file(URL)
    case text(URL, String, lineSeparator: String)

    var url: URL {
        switch self {
        case .file(let url), .text(let url, _, _): url
        }
    }
}

nonisolated enum SearchError: Error, LocalizedError {
    case invalidPattern(String)

    var errorDescription: String? {
        switch self {
        case .invalidPattern(let message): "Invalid regular expression: \(message)"
        }
    }
}

nonisolated struct ReplaceSummary: Sendable, Equatable {
    var files = 0
    var occurrences = 0
    var failures: [String] = []
}

nonisolated enum FolderSearch {
    static let maxFileSize = 5_000_000
    static let maxHits = 2_000

    /// Streams per-file results, matching line by line so hits line up with the editor.
    static func run(sources: [SearchSource], matcher: Matcher) -> AsyncStream<SearchFileResult> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var total = 0
                for source in sources {
                    if Task.isCancelled || total >= maxHits { break }
                    let hits = search(source, matcher: matcher, limit: maxHits - total)
                    if !hits.isEmpty {
                        total += hits.count
                        continuation.yield(SearchFileResult(url: source.url, hits: hits))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func textFiles(under root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if FileKind.ignoredNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard
                let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                (values.fileSize ?? 0) <= maxFileSize, FileKind.of(url).isTextual
            else { continue }
            files.append(url.normalizedFileURL)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func read(_ source: SearchSource) -> (text: String, lineSeparator: String)? {
        switch source {
        case .text(_, let text, let separator):
            return (text, separator)
        case .file(let url):
            guard let data = try? Data(contentsOf: url), data.count <= maxFileSize else { return nil }
            let decoded = TextCodec.decode(data)
            return (decoded.text, decoded.lineSeparator)
        }
    }

    static func search(_ source: SearchSource, matcher: Matcher, limit: Int) -> [SearchHit] {
        guard let (text, separator) = read(source) else { return [] }
        var hits: [SearchHit] = []
        // Split only on the file's own separator so line numbers match the editor's.
        for (index, line) in text.components(separatedBy: separator).enumerated() {
            let nsLine = line as NSString
            for range in matcher.matches(in: nsLine) {
                hits.append(makeHit(url: source.url, line: index + 1, text: nsLine, match: range))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Replaces every match line by line (the same matches `search` reports), preserving line separators.
    static func replace(in text: String, lineSeparator: String, matcher: Matcher, template: String) -> (
        text: String, count: Int
    ) {
        var count = 0
        let lines = text.components(separatedBy: lineSeparator).map { line in
            let (replaced, n) = matcher.replace(in: line as NSString, template: template)
            count += n
            return replaced
        }
        return count == 0 ? (text, 0) : (lines.joined(separator: lineSeparator), count)
    }

    /// Rewrites files on disk in their original encoding and line endings.
    static func replaceInFiles(_ urls: [URL], matcher: Matcher, template: String) -> ReplaceSummary {
        var summary = ReplaceSummary()
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let decoded = TextCodec.decode(data)
            let (text, count) = replace(
                in: decoded.text, lineSeparator: decoded.lineSeparator, matcher: matcher, template: template)
            guard count > 0 else { continue }
            do {
                try SafeFileWriter.write(TextCodec.encode(text, as: decoded.encoding).0, to: url)
                summary.files += 1
                summary.occurrences += count
            } catch {
                summary.failures.append(url.lastPathComponent)
            }
        }
        return summary
    }

    private static func makeHit(url: URL, line: Int, text: NSString, match: NSRange) -> SearchHit {
        let context = 60
        let start = max(0, match.location - context)
        let end = min(text.length, match.location + match.length + 120)
        let leading = text.substring(with: NSRange(location: start, length: match.location - start))
        let trimmedLeading = String(leading.drop(while: { $0 == " " || $0 == "\t" }))
        let prefix = (start > 0 ? "…" : "") + trimmedLeading
        let preview = prefix + text.substring(with: NSRange(location: match.location, length: end - match.location))
        let previewMatch = NSRange(location: (prefix as NSString).length, length: match.length)
        return SearchHit(
            url: url, line: line, column: match.location, length: match.length, preview: preview,
            previewMatch: previewMatch)
    }

    struct Matcher: Sendable {
        private let regex: NSRegularExpression?
        private let options: SearchOptions

        init(_ options: SearchOptions) throws {
            self.options = options
            if options.regex {
                do {
                    regex = try NSRegularExpression(
                        pattern: options.query, options: options.caseSensitive ? [] : [.caseInsensitive])
                } catch {
                    throw SearchError.invalidPattern(options.query)
                }
            } else {
                regex = nil
            }
        }

        func matches(in line: NSString) -> [NSRange] {
            results(in: line).map(\.range)
        }

        /// Replaces matches in one line; in regex mode `template` may use `$1`-style group references.
        func replace(in line: NSString, template: String) -> (String, Int) {
            let found = results(in: line)
            guard !found.isEmpty else { return (line as String, 0) }
            let output = NSMutableString()
            var cursor = 0
            for (range, result) in found {
                output.append(line.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                if let regex, let result {
                    output.append(regex.replacementString(for: result, in: line as String, offset: 0, template: template))
                } else {
                    output.append(template)
                }
                cursor = range.location + range.length
            }
            output.append(line.substring(from: cursor))
            return (output as String, found.count)
        }

        private func results(in line: NSString) -> [(range: NSRange, result: NSTextCheckingResult?)] {
            guard !options.query.isEmpty else { return [] }
            if let regex {
                return regex.matches(in: line as String, range: NSRange(location: 0, length: line.length))
                    .filter { $0.range.length > 0 }
                    .map { ($0.range, $0) }
            }
            var ranges: [(NSRange, NSTextCheckingResult?)] = []
            var searchRange = NSRange(location: 0, length: line.length)
            let compare: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            while searchRange.length > 0 {
                let found = line.range(of: options.query, options: compare, range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                ranges.append((found, nil))
                let next = found.location + found.length
                searchRange = NSRange(location: next, length: line.length - next)
            }
            return ranges
        }
    }
}

nonisolated enum SafeFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // Single-file sandbox grants can't create the temporary sibling an atomic write needs.
            try data.write(to: url)
        }
    }
}
