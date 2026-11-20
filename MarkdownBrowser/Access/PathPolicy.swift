import Foundation

nonisolated enum PathPolicy {
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The names leading from `root` to `path` (empty when they are the same), or nil when `path` lies outside `root`.
    /// Plain string work: a trailing "/" on either path is ignored and a root of "/" works.
    static func relativeComponents(of path: String, under root: String) -> [String]? {
        let target = path.split(separator: "/")
        let base = root.split(separator: "/")
        guard target.starts(with: base) else { return nil }
        return target.dropFirst(base.count).map(String.init)
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
