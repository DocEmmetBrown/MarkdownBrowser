import Foundation

nonisolated enum PathPolicy {
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// True when `url` (after resolving `..` and symlinks) is one of `roots` or lies beneath one.
    static func isWithin(_ url: URL, roots: [URL]) -> Bool {
        let target = canonical(url).pathComponents
        return roots.contains { root in
            let prefix = canonical(root).pathComponents
            return target.count >= prefix.count && Array(target.prefix(prefix.count)) == prefix
        }
    }
}
