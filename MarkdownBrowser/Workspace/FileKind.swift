import Foundation
import UniformTypeIdentifiers

nonisolated enum FileKind: Equatable, Sendable {
    case markdown, text, image, video, other

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdx"]

    /// Folders and files hidden from the sidebar and skipped by search.
    static let ignoredNames: Set<String> = [".git", "node_modules", ".DS_Store", ".build", "DerivedData"]

    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "json", "jsonc", "yaml", "yml", "toml", "ini", "cfg", "conf", "env",
        "xml", "plist", "html", "htm", "css", "scss", "less", "js", "mjs", "cjs", "ts", "tsx", "jsx", "swift",
        "py", "rb", "go", "rs", "java", "kt", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "bash",
        "zsh", "fish", "sql", "graphql", "proto", "lua", "pl", "r", "dart", "scala", "vue", "svelte", "tex", "rst",
        "adoc", "org", "gitignore", "gitattributes", "editorconfig", "dockerfile", "makefile", "mermaid", "mmd",
    ]

    private static let textFileNames: Set<String> = [
        "Makefile", "Dockerfile", "LICENSE", "README", "CHANGELOG", "AUTHORS", "CODEOWNERS", "Gemfile", "Rakefile",
        "Procfile", "Brewfile",
    ]

    private static let quickLookOnly: Set<String> = ["rtf", "rtfd", "pdf", "webarchive"]

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if quickLookOnly.contains(ext) { return .other }
        if textExtensions.contains(ext) || textFileNames.contains(url.lastPathComponent) { return .text }
        if let type = UTType(filenameExtension: ext), !type.isDynamic {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audiovisualContent) { return .video }
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
            return .other
        }
        return looksLikeText(url) ? .text : .other
    }

    var isTextual: Bool { self == .markdown || self == .text }

    /// Heuristic for extension-less files: no NUL bytes and valid UTF-8 in the first 8 KB.
    static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192) else { return false }
        if data.isEmpty { return true }
        if data.contains(0) { return false }
        for trim in 0...3 where data.count > trim {
            if String(data: data.dropLast(trim), encoding: .utf8) != nil { return true }
        }
        return false
    }
}
