import Foundation

nonisolated struct FilterResult: Identifiable, Sendable, Equatable {
    let url: URL
    let name: String
    /// The containing folder relative to the workspace folder; empty at the top level.
    let folder: String
    let isDirectory: Bool
    let score: Int

    var id: URL { url }
}

nonisolated struct FilterUpdate: Sendable, Equatable {
    /// The best matches so far, best first, at most `FileFilter.maxResults`.
    var results: [FilterResult] = []
    /// Every match found so far, including those beyond the cap.
    var matchCount = 0
    var isComplete = false

    var isTruncated: Bool { matchCount > results.count }
}

/// Fuzzy file-name search for the sidebar. A query containing "/" is matched against the path relative to the
/// workspace folder instead of the name, so "docs/rdm" finds "docs/README.md".
nonisolated enum FileFilter {
    static let maxResults = 500
    private static let updateInterval = Duration.milliseconds(120)
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]

    /// Streams growing snapshots of the best matches, ending with a complete one; nothing is yielded when cancelled.
    /// Non-recursive searches list only `directories` (the levels the tree shows); recursive ones walk all of `root`.
    static func run(query: String, root: URL, directories: [URL], recursive: Bool) -> AsyncStream<FilterUpdate> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                guard let matcher = FuzzyMatcher(query: query) else {
                    continuation.finish()
                    return
                }
                var collector = Collector(matcher: matcher, rootPath: root.path(percentEncoded: false))
                var lastUpdate = ContinuousClock.now
                var scanned = 0
                var unsent = false
                forEachEntry(in: recursive ? [root] : directories, recursive: recursive) { url in
                    if collector.consider(url) { unsent = true }
                    scanned += 1
                    if unsent, scanned & 0xFF == 0, ContinuousClock.now - lastUpdate >= updateInterval {
                        continuation.yield(collector.snapshot(isComplete: false))
                        lastUpdate = .now
                        unsent = false
                    }
                }
                if !Task.isCancelled { continuation.yield(collector.snapshot(isComplete: true)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The final result of a search, for callers that don't need progress.
    static func results(query: String, root: URL, directories: [URL], recursive: Bool) async -> FilterUpdate {
        var last = FilterUpdate()
        for await update in run(query: query, root: root, directories: directories, recursive: recursive) {
            last = update
        }
        return last
    }

    /// Visible entries, skipping hidden files and the folders the tree ignores (never descending into them).
    private static func forEachEntry(in directories: [URL], recursive: Bool, _ body: (URL) -> Void) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        for directory in directories {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: Array(keys), options: options)
            else { continue }
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { return }
                if FileKind.ignoredNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                body(url)
            }
        }
    }

    private struct Collector {
        let matcher: FuzzyMatcher
        let rootPath: String
        private(set) var results: [FilterResult] = []
        private(set) var matchCount = 0

        init(matcher: FuzzyMatcher, rootPath: String) {
            self.matcher = matcher
            self.rootPath = rootPath
        }

        /// Records the entry if it matches; returns whether it did.
        mutating func consider(_ url: URL) -> Bool {
            let name = url.lastPathComponent
            var path: String?
            let score: Int?
            if matcher.isPathQuery {
                path = relativePath(of: url, name: name)
                score = matcher.score(path!)
            } else {
                score = matcher.score(name)
            }
            guard let score else { return false }
            let relative = path ?? relativePath(of: url, name: name)
            let values = try? url.resourceValues(forKeys: FileFilter.keys)
            let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            let folder = relative.count > name.count ? String(relative.dropLast(name.count + 1)) : ""
            results.append(FilterResult(url: url, name: name, folder: folder, isDirectory: isDirectory, score: score))
            matchCount += 1
            if results.count >= 2 * FileFilter.maxResults { results = ranked }
            return true
        }

        func snapshot(isComplete: Bool) -> FilterUpdate {
            FilterUpdate(results: ranked, matchCount: matchCount, isComplete: isComplete)
        }

        private var ranked: [FilterResult] {
            Array(results.sorted(by: FileFilter.isRankedBefore).prefix(FileFilter.maxResults))
        }

        private func relativePath(of url: URL, name: String) -> String {
            let path = url.path(percentEncoded: false)
            return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : name
        }
    }

    /// Best score first; ties go to the shorter name, then Finder order.
    static func isRankedBefore(_ a: FilterResult, _ b: FilterResult) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let (aLength, bLength) = (a.name.utf16.count, b.name.utf16.count)
        if aLength != bLength { return aLength < bLength }
        let order = a.name.localizedStandardCompare(b.name)
        if order != .orderedSame { return order == .orderedAscending }
        return a.folder.localizedStandardCompare(b.folder) == .orderedAscending
    }
}
