import AVFoundation
import AppKit
import Foundation
import ImageIO
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

    @Test func relativeComponentsHandleTrailingSlashesAndTheFilesystemRoot() {
        #expect(PathPolicy.relativeComponents(of: "/a/b/c.md", under: "/a") == ["b", "c.md"])
        #expect(PathPolicy.relativeComponents(of: "/a/b/", under: "/a/") == ["b"])
        #expect(PathPolicy.relativeComponents(of: "/a", under: "/a") == [])
        #expect(PathPolicy.relativeComponents(of: "/a/b/c.md", under: "/") == ["a", "b", "c.md"])
        #expect(PathPolicy.relativeComponents(of: "/", under: "/") == [])
        #expect(PathPolicy.relativeComponents(of: "/ab/c.md", under: "/a") == nil)
        #expect(PathPolicy.relativeComponents(of: "/a", under: "/a/b") == nil)
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

    @Test func editMenuOffersLineWrapping() throws {
        let edit = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let item = try #require(edit.items.first { $0.title == "Wrap Long Lines" })
        #expect(item.state == (AppSettings.wrapLongLines ? .on : .off))
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

    @Test func detectsTranslocatedBundles() {
        let translocated = URL(filePath: "/private/var/folders/4v/x/T/AppTranslocation/6A37/d/MarkdownBrowser.app")
        #expect(CommandLineToolInstaller.isTranslocated(translocated))
        #expect(!CommandLineToolInstaller.isTranslocated(URL(filePath: "/Applications/MarkdownBrowser.app")))
        #expect(
            CommandLineToolInstaller.tool(inBundleAt: URL(filePath: "/Applications/MarkdownBrowser.app")).path
                == "/Applications/MarkdownBrowser.app/Contents/SharedSupport/bin/mdb")
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

@Suite struct FileTreeTests {
    private func makeFolder(_ names: [String: Bool]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, isDirectory) in names {
            let url = root.appending(path: name)
            if isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data().write(to: url)
            }
        }
        return root
    }

    @Test func sortsFilesAndFoldersTogetherByName() throws {
        let root = try makeFolder([
            "echo10.md": false, "Beta": true, "alpha.md": false, "delta": true, "Charlie.md": false, "echo9.md": false,
            ".hidden": false, "node_modules": true,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            FileNode.entries(in: root).map(\.name) == ["alpha.md", "Beta", "Charlie.md", "delta", "echo9.md", "echo10.md"])
    }

    @Test func sharesOneTreePerFolderAndReusesNodes() throws {
        let root = try makeFolder(["a.md": false, "docs": true])
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = FileTree.acquire(root)
        let other = FileTree.acquire(root)
        #expect(tree === other)

        let docs = try #require(tree.root.child(named: "docs"))
        try Data().write(to: root.appending(path: "b.md"))
        tree.root.reloadChildren()
        #expect(tree.root.child(named: "docs") === docs)
        #expect(tree.root.children?.map(\.name) == ["a.md", "b.md", "docs"])
        #expect(tree.loadedNode(for: root.appending(path: "docs")) === docs)
        #expect(docs.url == root.appending(path: "docs").normalizedFileURL)

        other.release()
        tree.release()
        let reopened = FileTree.acquire(root)
        #expect(reopened !== tree)
        reopened.release()
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

@Suite struct MediaBoundsTests {
    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func temporaryFile(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name)
    }

    @Test func loadsAnImageWithinBothBounds() async throws {
        let url = try temporaryFile("small.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writePNG(width: 8, height: 4, to: url)
        let image = try await NativePreviewModel.boundedImage(url)
        #expect(image.size == CGSize(width: 8, height: 4))
    }

    @Test func rejectsAnImageOverTheEncodedByteLimit() async throws {
        let url = try temporaryFile("huge.tiff")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(NativePreviewModel.imageByteLimit + 1))
        try handle.close()
        await #expect(throws: PreviewError.self) { try await NativePreviewModel.boundedImage(url) }
    }

    @Test func rejectsAnImageOverTheDecodedPixelLimit() async throws {
        let url = try temporaryFile("wide.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let side = Int(NativePreviewModel.imagePixelLimit.squareRoot()) + 1
        try writePNG(width: side, height: side, to: url)
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size <= NativePreviewModel.imageByteLimit)
        await #expect(throws: PreviewError.self) { try await NativePreviewModel.boundedImage(url) }
    }

    @Test func rejectsUndecodableData() async throws {
        let url = try temporaryFile("broken.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("not an image".utf8).write(to: url)
        await #expect(throws: PreviewError.self) { try await NativePreviewModel.boundedImage(url) }
    }

    @Test func standaloneVideoPlayerForbidsExternalReferences() throws {
        let url = URL(filePath: "/tmp/clip.mov")
        let asset = try #require(VideoViewer.player(for: url).currentItem?.asset as? AVURLAsset)
        #expect(asset.url == url)
        #expect(asset.referenceRestrictions == .forbidAll)
    }
}

@Suite struct SvgSniffTests {
    private static let embedded = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>"#.utf8)
    /// A PNG signature and IHDR followed by a tEXt chunk whose payload is SVG markup.
    private static let png =
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data("IHDR".utf8)
        + Data(count: 17) + Data([0, 0, 0, UInt8(embedded.count + 8)]) + Data("tEXtComment\0".utf8) + embedded
    private static let jpeg =
        Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x80]) + Data("http://ns.adobe.com/xap/1.0/\0".utf8) + embedded

    @Test func acceptsPlainSvg() {
        #expect(NativePreviewModel.isSvg(Self.embedded))
        #expect(NativePreviewModel.isSvg(Data([0xEF, 0xBB, 0xBF]) + Data(" \r\n\t".utf8) + Self.embedded))
    }

    @Test func acceptsSvgAfterXmlPrologAndComment() {
        let prolog = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n<!-- Generator: Adobe Illustrator -->\n"
        #expect(NativePreviewModel.isSvg(Data(prolog.utf8) + Self.embedded))
        #expect(NativePreviewModel.isSvg(Data("<!-- exported -->\n".utf8) + Self.embedded))
        let doctype = #"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">"#
        #expect(NativePreviewModel.isSvg(Data(doctype.utf8) + Self.embedded))
    }

    @Test func rejectsRasterImagesEmbeddingSvgMarkup() {
        #expect(!NativePreviewModel.isSvg(Self.png))
        #expect(!NativePreviewModel.isSvg(Self.jpeg))
        #expect(!NativePreviewModel.isSvg(Data("GIF89a".utf8) + Self.embedded))
        #expect(!NativePreviewModel.isSvg(Data("RIFF".utf8) + Data(count: 4) + Data("WEBPVP8 ".utf8) + Self.embedded))
    }

    @Test func rejectsDataWithoutLeadingSvgMarkup() {
        #expect(!NativePreviewModel.isSvg(Data()))
        #expect(!NativePreviewModel.isSvg(Data("<html><body>".utf8) + Self.embedded))
        #expect(!NativePreviewModel.isSvg(Data(#"<?xml version="1.0"?><plist version="1.0"/>"#.utf8)))
        // The root element must appear within the sniffed prefix, not anywhere in the file.
        let padding = Data("<!--".utf8) + Data(repeating: 0x20, count: 16_000) + Data("-->".utf8)
        #expect(!NativePreviewModel.isSvg(padding + Self.embedded))
    }

    @Test func rasterFilesEmbeddingSvgMarkupAreNotRasterized() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try Self.png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try await NativePreviewModel.imageData(url) == Self.png)
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
            .file(files[0]), options: SearchOptions(query: "NEEDLE"), engine: SearchEngine(), limit: 10)
        #expect(hits.count == 1)
        #expect(hits[0].line == 2)
        #expect(hits[0].column == 3)
        #expect(hits[0].length == 6)
    }

    @Test func usesJavaScriptRegexSyntax() throws {
        let engine = SearchEngine()
        let options = SearchOptions(query: "n[e]+dle(?<end>s?)\\b", caseSensitive: true, regex: true)
        #expect(engine.validate(options) == nil)
        #expect(engine.matches(in: "needle Needle needles", lineSeparator: "\n", options: options, limit: 10).map(\.column) == [0, 14])
        // Valid ICU (possessive quantifier), invalid JavaScript.
        #expect(engine.validate(SearchOptions(query: "a++", regex: true)) != nil)
        #expect(engine.validate(SearchOptions(query: "(", regex: true)) != nil)
    }

    @Test func regexCacheDistinguishesCanonicalUnicodeSequences() {
        let engine = SearchEngine()
        let source = "é e\u{301}"
        for (query, column, length, replacement) in [
            ("é", 0, 1, "X e\u{301}"),
            ("e\u{301}", 2, 2, "é X"),
            ("é", 0, 1, "X e\u{301}"),
        ] {
            let options = SearchOptions(query: query, caseSensitive: true, regex: true)
            #expect(engine.matches(in: source, lineSeparator: "\n", options: options, limit: 10) == [
                SearchEngine.Match(line: 1, column: column, length: length)
            ])
            let result = engine.replace(in: source, lineSeparator: "\n", options: options, template: "X")
            #expect(result.text == replacement)
            #expect(result.count == 1)
        }
    }

    @Test func matchesAcrossLines() throws {
        let text = "intro\r\nfoo\r\nbar baz\r\n"
        let hits = FolderSearch.search(
            .text(URL(filePath: "/t.md"), text, lineSeparator: "\r\n"),
            options: SearchOptions(query: "foo\\nbar", regex: true), engine: SearchEngine(), limit: 10)
        #expect(hits.map(\.line) == [2])
        #expect(hits[0].length == 7)
        #expect(hits[0].previewMatch.length == 3)
    }

    @Test func replacesLiterallyAndPreservesLineEndings() throws {
        let (text, count) = FolderSearch.replace(
            in: "Cat $1\r\ncat\r\n", lineSeparator: "\r\n", options: SearchOptions(query: "cat"), template: "$1dog",
            engine: SearchEngine())
        #expect(count == 2)
        #expect(text == "$1dog $1\r\n$1dog\r\n")
    }

    @Test func replacesWithRegexGroupsAcrossLines() throws {
        let engine = SearchEngine()
        var (text, count) = FolderSearch.replace(
            in: "a@b c@d\ne", lineSeparator: "\n", options: SearchOptions(query: "(\\w+)@(\\w+)", regex: true),
            template: "$2@$1", engine: engine)
        #expect(count == 2)
        #expect(text == "b@a d@c\ne")
        (text, count) = FolderSearch.replace(
            in: "one\r\ntwo\r\n", lineSeparator: "\r\n", options: SearchOptions(query: "one\\ntwo", regex: true),
            template: "[$&]\\n", engine: engine)
        #expect(count == 1)
        #expect(text == "[one\r\ntwo]\r\n\r\n")
    }

    @Test func replacementMatchesSearchCounts() throws {
        let engine = SearchEngine()
        let options = SearchOptions(query: "x*", regex: true)
        let hits = FolderSearch.search(
            .text(URL(filePath: "/t.md"), "axxb\nx", lineSeparator: "\n"), options: options, engine: engine, limit: 10)
        let (_, count) = FolderSearch.replace(
            in: "axxb\nx", lineSeparator: "\n", options: options, template: "y", engine: engine)
        #expect(hits.count == 2)
        #expect(hits.count == count)
    }

    @Test func replacesFilesOnDiskKeepingEncoding() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try (Data([0xEF, 0xBB, 0xBF]) + Data("foo\r\nbar foo\r\n".utf8)).write(to: url)

        let summary = FolderSearch.replaceInFiles([url], options: SearchOptions(query: "foo"), template: "baz")
        #expect(summary == ReplaceSummary(files: 1, occurrences: 2))
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF]) + Data("baz\r\nbar baz\r\n".utf8))
    }
}
