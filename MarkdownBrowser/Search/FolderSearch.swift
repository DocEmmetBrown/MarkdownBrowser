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
        case .invalidPattern(let message): message
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

    /// Streams per-file results. Matching has the find bar's semantics (SearchEngine), so hits line up with it.
    static func run(sources: [SearchSource], options: SearchOptions) -> AsyncStream<SearchFileResult> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let engine = SearchEngine()
                var total = 0
                for source in sources {
                    if Task.isCancelled || total >= maxHits { break }
                    let hits = search(source, options: options, engine: engine, limit: maxHits - total)
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

    static func search(_ source: SearchSource, options: SearchOptions, engine: SearchEngine, limit: Int) -> [SearchHit] {
        guard let (text, separator) = read(source) else { return [] }
        let matches = engine.matches(in: text, lineSeparator: separator, options: options, limit: limit)
        guard !matches.isEmpty else { return [] }
        // Split only on the file's own separator so line numbers match the editor's.
        let lines = text.components(separatedBy: separator)
        return matches.compactMap { match in
            guard lines.indices.contains(match.line - 1) else { return nil }
            let line = lines[match.line - 1] as NSString
            let column = min(match.column, line.length)
            // A match spanning lines is highlighted up to the end of its first line.
            let shown = NSRange(location: column, length: min(match.length, line.length - column))
            return makeHit(url: source.url, line: match.line, text: line, match: shown, length: match.length)
        }
    }

    static func replace(
        in text: String, lineSeparator: String, options: SearchOptions, template: String, engine: SearchEngine
    ) -> (text: String, count: Int) {
        engine.replace(in: text, lineSeparator: lineSeparator, options: options, template: template)
    }

    /// Rewrites files on disk in their original encoding and line endings.
    static func replaceInFiles(_ urls: [URL], options: SearchOptions, template: String) -> ReplaceSummary {
        var summary = ReplaceSummary()
        let engine = SearchEngine()
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let decoded = TextCodec.decode(data)
            let (text, count) = replace(
                in: decoded.text, lineSeparator: decoded.lineSeparator, options: options, template: template,
                engine: engine)
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

    private static func makeHit(url: URL, line: Int, text: NSString, match: NSRange, length: Int) -> SearchHit {
        let context = 60
        let start = max(0, match.location - context)
        let end = min(text.length, match.location + match.length + 120)
        let leading = text.substring(with: NSRange(location: start, length: match.location - start))
        let trimmedLeading = String(leading.drop(while: { $0 == " " || $0 == "\t" }))
        let prefix = (start > 0 ? "…" : "") + trimmedLeading
        let preview = prefix + text.substring(with: NSRange(location: match.location, length: end - match.location))
        let previewMatch = NSRange(location: (prefix as NSString).length, length: match.length)
        return SearchHit(
            url: url, line: line, column: match.location, length: length, preview: preview,
            previewMatch: previewMatch)
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
