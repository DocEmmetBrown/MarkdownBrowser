import Foundation
import Observation

@Observable
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    /// `nil` until the directory has been listed.
    private(set) var children: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var kind: FileKind { isDirectory ? .other : FileKind.of(url) }

    init(url: URL, isDirectory: Bool) {
        self.url = url.normalizedFileURL
        self.isDirectory = isDirectory
    }

    /// Lists the directory, reusing existing child nodes so expanded subtrees stay loaded.
    func reloadChildren() {
        guard isDirectory else { return }
        let existing = Dictionary((children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        children =
            urls
            .filter { !FileKind.ignoredNames.contains($0.lastPathComponent) }
            .map { child in
                let values = try? child.resourceValues(forKeys: Set(keys))
                let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
                if let node = existing[child.normalizedFileURL], node.isDirectory == isDirectory { return node }
                return FileNode(url: child, isDirectory: isDirectory)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func loadChildrenIfNeeded() {
        if children == nil { reloadChildren() }
    }
}
