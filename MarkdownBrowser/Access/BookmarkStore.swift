import Foundation
import Observation

nonisolated struct RecentItem: Codable, Identifiable, Hashable, Sendable {
    var path: String
    var isDirectory: Bool
    var bookmark: Data
    var lastOpened: Date

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Persists security-scoped bookmarks for recent files/folders and for extra folders granted to single files.
@Observable
final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var recents: [RecentItem] = []
    private var grants: [RecentItem] = []

    private let defaults: UserDefaults
    private let recentsKey = "recentItems"
    private let grantsKey = "grantedFolders"
    private let maxRecents = 15

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = Self.decode(defaults.data(forKey: recentsKey))
        grants = Self.decode(defaults.data(forKey: grantsKey))
    }

    func noteOpened(_ url: URL, isDirectory: Bool) {
        guard let bookmark = try? Self.makeBookmark(url) else { return }
        recents.removeAll { $0.path == url.path }
        recents.insert(RecentItem(path: url.path, isDirectory: isDirectory, bookmark: bookmark, lastOpened: .now), at: 0)
        recents = Array(recents.prefix(maxRecents))
        persist()
    }

    func clearRecents() {
        recents = []
        persist()
    }

    /// Resolves a recent entry, refreshing its bookmark if stale and dropping it if unresolvable.
    func resolve(_ item: RecentItem) -> URL? {
        guard let (url, refreshed) = Self.resolve(item.bookmark) else {
            recents.removeAll { $0.id == item.id }
            persist()
            return nil
        }
        if let refreshed, let index = recents.firstIndex(where: { $0.id == item.id }) {
            recents[index].bookmark = refreshed
            persist()
        }
        return url
    }

    func addGrant(_ folder: URL) {
        guard let bookmark = try? Self.makeBookmark(folder) else { return }
        grants.removeAll { $0.path == folder.path }
        grants.append(RecentItem(path: folder.path, isDirectory: true, bookmark: bookmark, lastOpened: .now))
        persist()
    }

    /// Previously granted folders that contain `url`, resolved and ready for scoped access.
    func grantedFolders(containing url: URL) -> [URL] {
        grants
            .filter { PathPolicy.isWithin(url, roots: [URL(fileURLWithPath: $0.path)]) }
            .compactMap { Self.resolve($0.bookmark)?.0 }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(recents), forKey: recentsKey)
        defaults.set(try? JSONEncoder().encode(grants), forKey: grantsKey)
    }

    private static func decode(_ data: Data?) -> [RecentItem] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RecentItem].self, from: data)) ?? []
    }

    private static func makeBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ bookmark: Data) -> (URL, Data?)? {
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        else { return nil }
        guard isStale else { return (url, nil) }
        let scope = SecurityScope(url: url)
        defer { scope.stop() }
        return (url, try? makeBookmark(url))
    }
}
