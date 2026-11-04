import Foundation
import Observation

/// The sidebar's quick filter: the query, its scope, and the matches found for it. Searching runs off the main
/// actor, is debounced, and is cancelled by the next change.
@Observable
final class SidebarFilterModel {
    private(set) var query = ""
    private(set) var isRecursive = false
    private(set) var results: [FilterResult] = []
    private(set) var isSearching = false
    private(set) var isTruncated = false
    /// Set to move keyboard focus to the filter field; the field resets it once it has taken focus.
    var focusRequested = false

    private(set) var root: URL?
    /// The folders whose entries the tree currently shows; what a non-recursive filter searches.
    @ObservationIgnored var visibleDirectories: () -> [URL] = { [] }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var chosen: URL?
    @ObservationIgnored private let debounce: Duration

    init(root: URL?, debounce: Duration = .milliseconds(100)) {
        self.root = root
        self.debounce = debounce
    }

    var isActive: Bool { FuzzyMatcher(query: query) != nil }

    /// The result Return would open: the one chosen with the arrow keys or mouse, else the best match.
    var selected: FilterResult? {
        chosen.flatMap { url in results.first { $0.url == url } } ?? results.first
    }

    func setQuery(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        chosen = nil
        refresh()
    }

    func setRecursive(_ isRecursive: Bool) {
        guard isRecursive != self.isRecursive else { return }
        self.isRecursive = isRecursive
        refresh()
    }

    func clear() {
        setQuery("")
    }

    func choose(_ url: URL) {
        chosen = url
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = selected.flatMap { selected in results.firstIndex { $0.url == selected.url } } ?? 0
        chosen = results[min(max(current + offset, 0), results.count - 1)].url
    }

    /// Follows the sidebar into another folder, searching it for the current query.
    func setRoot(_ url: URL) {
        guard root != nil, url != root else { return }
        root = url
        refresh()
    }

    /// Copies another model's query and scope, e.g. into a tab opened from one of its results.
    func adopt(_ other: SidebarFilterModel) {
        query = other.query
        isRecursive = other.isRecursive
        refresh()
        chosen = other.chosen
    }

    func cancel() {
        task?.cancel()
        isSearching = false
    }

    /// Restarts the search for the current query and scope.
    func refresh() {
        task?.cancel()
        guard let root, isActive else {
            results = []
            isSearching = false
            isTruncated = false
            return
        }
        isSearching = true
        let (query, isRecursive) = (query, isRecursive)
        task = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let directories = isRecursive ? [] : visibleDirectories()
            for await update in FileFilter.run(query: query, root: root, directories: directories, recursive: isRecursive) {
                guard !Task.isCancelled else { return }
                results = update.results
                isTruncated = update.isTruncated
                isSearching = !update.isComplete
            }
            if !Task.isCancelled { isSearching = false }
        }
    }
}
