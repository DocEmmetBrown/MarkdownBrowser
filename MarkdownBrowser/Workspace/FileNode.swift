import Foundation

/// A file or folder in the sidebar tree. Children are listed on demand and reused across reloads, so expanded
/// subtrees and the outline view's item identity survive file system changes.
final class FileNode {
    static let didReloadChildren = Notification.Name("FileNode.didReloadChildren")

    let url: URL
    let name: String
    let isDirectory: Bool
    /// `nil` until the directory has been listed.
    private(set) var children: [FileNode]?
    private var childrenByName: [String: FileNode] = [:]

    var kind: FileKind { isDirectory ? .other : FileKind.of(url) }

    init(url: URL, isDirectory: Bool) {
        self.url = url.normalizedFileURL
        name = self.url.lastPathComponent
        self.isDirectory = isDirectory
    }

    /// Builds the URL from the already-normalized parent; normalizing every child is slow in huge folders.
    private init(name: String, in parent: URL, isDirectory: Bool) {
        url = parent.appending(path: name, directoryHint: .notDirectory)
        self.name = name
        self.isDirectory = isDirectory
    }

    func child(named name: String) -> FileNode? {
        childrenByName[name]
    }

    /// Lists the directory, reusing existing child nodes so expanded subtrees stay loaded.
    func reloadChildren() {
        guard isDirectory else { return }
        let nodes = Self.entries(in: url).map { entry in
            if let node = childrenByName[entry.name], node.isDirectory == entry.isDirectory { return node }
            return FileNode(name: entry.name, in: url, isDirectory: entry.isDirectory)
        }
        children = nodes
        childrenByName = Dictionary(nodes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        NotificationCenter.default.post(name: Self.didReloadChildren, object: self)
    }

    func loadChildrenIfNeeded() {
        if children == nil { reloadChildren() }
    }

    nonisolated struct Entry: Sendable, Equatable {
        let name: String
        let isDirectory: Bool
    }

    /// Visible entries sorted by name the way Finder sorts them, files and folders mixed.
    nonisolated static func entries(in url: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var entries: [Entry] = []
        entries.reserveCapacity(urls.count)
        for child in urls {
            let name = child.lastPathComponent
            if FileKind.ignoredNames.contains(name) { continue }
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            entries.append(Entry(name: name, isDirectory: isDirectory))
        }
        // Compare stored names: deriving them from URLs inside the comparator is several times slower.
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return entries
    }
}

/// The file tree of one folder, shared by every window and tab showing it, and kept current by a folder watcher.
final class FileTree {
    let root: FileNode
    private let rootPath: String
    private var watcher: FolderWatcher?
    private var users = 0

    private static var open: [URL: FileTree] = [:]

    /// The tree for `url`, listed once and shared until the last user releases it.
    static func acquire(_ url: URL) -> FileTree {
        let url = url.normalizedFileURL
        let tree = open[url] ?? FileTree(url: url)
        open[url] = tree
        tree.users += 1
        return tree
    }

    func release() {
        users -= 1
        guard users <= 0 else { return }
        watcher?.stop()
        watcher = nil
        Self.open[root.url] = nil
    }

    private init(url: URL) {
        root = FileNode(url: url, isDirectory: true)
        rootPath = PathPolicy.canonical(url).path(percentEncoded: false)
        root.reloadChildren()
        watcher = FolderWatcher(url: url) { [weak self] paths in self?.filesChanged(paths) }
    }

    /// Path components from the root to `path` (canonical), or nil when it's outside the tree.
    func relativeComponents(ofPath path: String) -> [String]? {
        if path == rootPath { return [] }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return path.dropFirst(rootPath.count + 1).split(separator: "/").map(String.init)
    }

    func relativeComponents(of url: URL) -> [String]? {
        relativeComponents(ofPath: PathPolicy.canonical(url).path(percentEncoded: false))
    }

    /// The already-listed node for `url`; never lists directories.
    func loadedNode(for url: URL) -> FileNode? {
        relativeComponents(of: url).flatMap(loadedNode(components:))
    }

    private func loadedNode(components: [String]) -> FileNode? {
        var node = root
        for name in components {
            guard let child = node.child(named: name) else { return nil }
            node = child
        }
        return node
    }

    private func filesChanged(_ paths: [String]) {
        var directories = Set<String>()
        for path in paths {
            directories.insert(path)
            directories.insert((path as NSString).deletingLastPathComponent)
        }
        for directory in directories {
            guard
                let components = relativeComponents(ofPath: directory),
                let node = loadedNode(components: components), node.isDirectory, node.children != nil
            else { continue }
            node.reloadChildren()
        }
    }
}
