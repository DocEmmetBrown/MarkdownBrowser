import Foundation
import Testing

@testable import MarkdownBrowser

@Suite struct TextCodecTests {
    @Test func utf8RoundTripIsByteExact() {
        let original = Data("# Title\r\nemoji 😀 é e\u{301}\r\n".utf8)
        let decoded = TextCodec.decode(original)
        #expect(decoded.lineSeparator == "\r\n")
        #expect(TextCodec.encode(decoded.text, as: decoded.encoding).0 == original)
    }

    @Test func preservesUTF8BOM() {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("hello\n".utf8)
        let decoded = TextCodec.decode(original)
        #expect(decoded.encoding == .utf8(bom: true))
        #expect(decoded.text == "hello\n")
        #expect(TextCodec.encode(decoded.text, as: decoded.encoding).0 == original)
    }

    @Test func utf16LittleEndianRoundTrip() {
        let original = Data([0xFF, 0xFE]) + "ab\nc".data(using: .utf16LittleEndian)!
        let decoded = TextCodec.decode(original)
        #expect(decoded.encoding == .utf16LittleEndian)
        #expect(TextCodec.encode(decoded.text, as: decoded.encoding).0 == original)
    }

    @Test func invalidUTF8FallsBackToLatin1Losslessly() {
        let original = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])
        let decoded = TextCodec.decode(original)
        #expect(decoded.encoding == .latin1)
        #expect(decoded.text == "café\n")
        #expect(TextCodec.encode(decoded.text, as: decoded.encoding).0 == original)
    }

    @Test func latin1UpgradesToUTF8WhenNeeded() {
        let (data, encoding) = TextCodec.encode("😀", as: .latin1)
        #expect(encoding == .utf8(bom: false))
        #expect(data == Data("😀".utf8))
    }

    @Test(arguments: [("a\nb\n", "\n"), ("a\r\nb\r\n", "\r\n"), ("a\rb\r", "\r"), ("none", "\n"), ("a\r\nb\nc\n", "\n")])
    func detectsDominantLineSeparator(text: String, expected: String) {
        #expect(TextCodec.lineSeparator(of: text) == expected)
    }
}

@Suite struct PathPolicyTests {
    @Test func rejectsTraversalOutsideRoot() {
        let root = URL(filePath: "/tmp/workspace")
        #expect(PathPolicy.isWithin(URL(filePath: "/tmp/workspace/docs/a.md"), roots: [root]))
        #expect(PathPolicy.isWithin(root, roots: [root]))
        #expect(!PathPolicy.isWithin(URL(filePath: "/tmp/workspace/../secret.txt"), roots: [root]))
        #expect(!PathPolicy.isWithin(URL(filePath: "/tmp/workspace-other/a.md"), roots: [root]))
    }

    @Test func rejectsSymlinkEscapingRoot() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = base.appending(path: "root")
        let outside = base.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("secret".utf8).write(to: outside.appending(path: "secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: outside)

        #expect(!PathPolicy.isWithin(root.appending(path: "link/secret.txt"), roots: [root]))
    }
}

@Suite struct AppearanceTests {
    @Test func mapsModesToAppearances() {
        #expect(AppearanceMode.system.nsAppearance == nil)
        #expect(AppearanceMode.light.nsAppearance?.name == .aqua)
        #expect(AppearanceMode.dark.nsAppearance?.name == .darkAqua)
    }
}

@Suite struct CommandLineToolInstallerTests {
    @Test func linksAndReplacesOnlyEarlierLaunchers() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appending(path: "mdb")
        let oldTool = URL(filePath: "/Applications/Old.app/Contents/SharedSupport/bin/mdb")
        let tool = URL(filePath: "/Applications/MarkdownBrowser.app/Contents/SharedSupport/bin/mdb")

        try CommandLineToolInstaller.createLink(at: link, to: oldTool, replacingExisting: false)
        try CommandLineToolInstaller.createLink(at: link, to: tool, replacingExisting: false)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == tool.path)

        try FileManager.default.removeItem(at: link)
        try Data("#!/bin/sh\n".utf8).write(to: link)
        #expect(throws: CommandLineToolInstaller.LinkError.occupied) {
            try CommandLineToolInstaller.createLink(at: link, to: tool, replacingExisting: false)
        }
        try CommandLineToolInstaller.createLink(at: link, to: tool, replacingExisting: true)
        #expect(CommandLineToolInstaller.isLauncherLink(link))
    }

    @Test func quotesManualCommand() {
        let command = CommandLineToolInstaller.manualCommand(
            directory: URL(filePath: "/usr/local/bin"), tool: URL(filePath: "/Applications/It's.app/Contents/SharedSupport/bin/mdb"))
        #expect(
            command
                == "sudo mkdir -p '/usr/local/bin' && sudo ln -sf '/Applications/It'\\''s.app/Contents/SharedSupport/bin/mdb' '/usr/local/bin/mdb'"
        )
    }
}

@Suite struct FileKindTests {
    @Test(arguments: [
        ("README.md", FileKind.markdown), ("notes.markdown", .markdown), ("a.swift", .text), ("data.json", .text),
        ("photo.png", .image), ("clip.mp4", .video), ("doc.pdf", .other), ("Makefile", .text),
    ])
    func classifies(name: String, expected: FileKind) {
        #expect(FileKind.of(URL(filePath: "/tmp/\(name)")) == expected)
    }
}

@Suite struct SchemeHandlerTests {
    @Test func mapsFileURLsBothWays() {
        let file = URL(filePath: "/Users/me/My Docs/read me.md")
        let scheme = LocalResourceSchemeHandler.schemeURL(for: file)
        #expect(scheme.absoluteString == "mdb-file://local/Users/me/My%20Docs/read%20me.md")
        #expect(LocalResourceSchemeHandler.fileURL(for: scheme)?.path == file.path)
    }

    @Test func rejectsOtherHosts() {
        #expect(LocalResourceSchemeHandler.fileURL(for: URL(string: "mdb-file://evil/etc/passwd")!) == nil)
    }

    @Test func parsesByteRanges() {
        #expect(LocalResourceSchemeHandler.byteRange("bytes=0-99", size: 1000) == 0..<100)
        #expect(LocalResourceSchemeHandler.byteRange("bytes=900-", size: 1000) == 900..<1000)
        #expect(LocalResourceSchemeHandler.byteRange("bytes=-100", size: 1000) == 900..<1000)
        #expect(LocalResourceSchemeHandler.byteRange("bytes=0-5000", size: 1000) == 0..<1000)
        #expect(LocalResourceSchemeHandler.byteRange("bytes=2000-", size: 1000) == nil)
        #expect(LocalResourceSchemeHandler.byteRange(nil, size: 1000) == nil)
    }
}

@Suite struct FolderSearchTests {
    @Test func findsMatchesWithUTF16Columns() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first\r\n😀 needle here\r\n".utf8).write(to: root.appending(path: "a.md"))
        try Data("needle".utf8).write(to: root.appending(path: "node_modules/ignored.md"))
        try Data([0, 1, 2]).write(to: root.appending(path: "binary.bin"))

        let files = FolderSearch.textFiles(under: root)
        #expect(files.map(\.lastPathComponent) == ["a.md"])

        let hits = FolderSearch.search(
            .file(files[0]), matcher: try FolderSearch.Matcher(SearchOptions(query: "NEEDLE")), limit: 10)
        #expect(hits.count == 1)
        #expect(hits[0].line == 2)
        #expect(hits[0].column == 3)
        #expect(hits[0].length == 6)
    }

    @Test func regexAndCaseSensitivity() throws {
        let matcher = try FolderSearch.Matcher(SearchOptions(query: "n[e]+dle", caseSensitive: true, regex: true))
        #expect(matcher.matches(in: "needle Needle" as NSString).map(\.location) == [0])
        #expect(throws: SearchError.self) { try FolderSearch.Matcher(SearchOptions(query: "(", regex: true)) }
    }

    @Test func replacesLiterallyAndPreservesLineEndings() throws {
        let matcher = try FolderSearch.Matcher(SearchOptions(query: "cat"))
        let (text, count) = FolderSearch.replace(
            in: "Cat $1\r\ncat\r\n", lineSeparator: "\r\n", matcher: matcher, template: "$1dog")
        #expect(count == 2)
        #expect(text == "$1dog $1\r\n$1dog\r\n")
    }

    @Test func replacesWithRegexGroups() throws {
        let matcher = try FolderSearch.Matcher(SearchOptions(query: "(\\w+)@(\\w+)", regex: true))
        let (text, count) = FolderSearch.replace(
            in: "a@b c@d\ne", lineSeparator: "\n", matcher: matcher, template: "$2@$1")
        #expect(count == 2)
        #expect(text == "b@a d@c\ne")
    }

    @Test func replacementMatchesSearchCounts() throws {
        let matcher = try FolderSearch.Matcher(SearchOptions(query: "x*", regex: true))
        let hits = FolderSearch.search(.text(URL(filePath: "/t.md"), "axxb\nx", lineSeparator: "\n"), matcher: matcher, limit: 10)
        let (_, count) = FolderSearch.replace(in: "axxb\nx", lineSeparator: "\n", matcher: matcher, template: "y")
        #expect(hits.count == count)
    }

    @Test func replacesFilesOnDiskKeepingEncoding() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try (Data([0xEF, 0xBB, 0xBF]) + Data("foo\r\nbar foo\r\n".utf8)).write(to: url)

        let summary = FolderSearch.replaceInFiles(
            [url], matcher: try FolderSearch.Matcher(SearchOptions(query: "foo")), template: "baz")
        #expect(summary == ReplaceSummary(files: 1, occurrences: 2))
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF]) + Data("baz\r\nbar baz\r\n".utf8))
    }
}
