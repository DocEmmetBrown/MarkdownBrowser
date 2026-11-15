import AppKit
import Testing

@testable import MarkdownBrowser

@Suite @MainActor struct NativeEditorTests {
    private func makeDocument(_ source: String, data: Data? = nil) throws -> (OpenDocument, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        try (data ?? Data(source.utf8)).write(to: url)
        return (try OpenDocument(id: 1, url: url, kind: .markdown), url)
    }

    @Test func hiddenFlagSelectsTheNativeEditorForNewWorkspaces() throws {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? "com.guillaumewinter.MarkdownBrowser"
        let previous = defaults.persistentDomain(forName: domain)?[AppSettings.nativeEditorKey]
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppSettings.nativeEditorKey)
            } else {
                defaults.removeObject(forKey: AppSettings.nativeEditorKey)
            }
            try? FileManager.default.removeItem(at: root)
        }

        defaults.set(true, forKey: AppSettings.nativeEditorKey)
        let nativeWorkspace = Workspace(url: root)
        #expect(nativeWorkspace.usesNativeEditor)
        nativeWorkspace.close()

        defaults.set(false, forKey: AppSettings.nativeEditorKey)
        let webWorkspace = Workspace(url: root)
        #expect(!webWorkspace.usesNativeEditor)
        webWorkspace.close()
    }

    @Test func editsAndSavesWithoutChangingOriginalLineEndingsOrBom() async throws {
        let source = "# Title\r\n"
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(source.utf8)
        let (document, url) = try makeDocument(source, data: original)
        defer { try? FileManager.default.removeItem(at: url) }

        let host = NativeEditorHost()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeFirstResponder(host.textView)
        document.editor = host
        host.onDirtyChange = { _, dirty in document.isDirty = dirty }
        host.load(document, rootURL: nil, anchor: nil)

        let insertion = (source as NSString).length
        host.textView.insertText("new\n😀", replacementRange: NSRange(location: insertion, length: 0))
        #expect(await host.text(docId: document.id) == "# Title\r\nnew\r\n😀")
        #expect(document.isDirty)
        #expect(await document.save() == .saved)
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF]) + Data("# Title\r\nnew\r\n😀".utf8))
    }

    @Test func pastedAndDroppedPlainTextUseTheFileLineSeparator() throws {
        let (document, url) = try makeDocument("ab")
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        host.textView.lineSeparator = "\r\n"
        host.textView.setSelectedRange(NSRange(location: 1, length: 0))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        #expect(pasteboard.setString("one\ntwo", forType: .string))
        #expect(host.textView.paste(from: pasteboard))
        #expect(host.textView.string == "aone\r\ntwob")

        host.textView.setSelectedRange(NSRange(location: (host.textView.string as NSString).length - 1, length: 0))
        #expect(pasteboard.setString("\nthree", forType: .string))
        #expect(host.textView.readSelection(from: pasteboard, type: .string))
        #expect(host.textView.string == "aone\r\ntwo\r\nthreeb")
    }

    @Test func committedInputMethodTextUsesTheFileLineSeparator() throws {
        let (document, url) = try makeDocument("")
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        host.textView.lineSeparator = "\r\n"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeFirstResponder(host.textView)

        host.textView.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        #expect(host.textView.hasMarkedText())
        host.textView.insertText("日本\n語", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(host.textView.string == "日本\r\n語")
        #expect(!host.textView.hasMarkedText())
    }

    @Test func findAndReplaceUsesRustRegexContextAndOnlyReplacesTheSelectedMatch() throws {
        let (document, url) = try makeDocument("😀 foo! foo!")
        defer { try? FileManager.default.removeItem(at: url) }

        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let find = FindBarModel()
        find.query = "(?<=😀 )(foo)(?=!)"
        find.regex = true
        find.replacement = "$1x"
        host.setFindQuery(docId: document.id, find)
        host.findNext(docId: document.id, wrap: false)
        #expect(host.textView.selectedRange() == NSRange(location: 3, length: 3))

        host.replaceCurrent(docId: document.id, wrap: false)
        #expect(host.textView.string == "😀 foox! foo!")
    }

    @Test func findMapsUtf16PositionsAcrossCrLfAndAnchorsSkipFencedCode() throws {
        let source = "# Guide\r\n```md\n# Guide\n```\r\n# [Guide](docs/a.md)\r\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)

        let find = FindBarModel()
        find.query = "Guide"
        host.setFindQuery(docId: document.id, find)
        host.findNext(docId: document.id, wrap: false)
        #expect(host.textView.selectedRange() == NSRange(location: 2, length: 5))

        host.scrollToAnchor("guide-1")
        #expect(host.textView.selectedRange().location == (source as NSString).range(of: "# [Guide]").location)
    }

    @Test func anchorsDecodeFragmentsStripGitHubPrefixAndFindExplicitHtmlIds() throws {
        let source = "# Café [docs](guide.md) ###\n\n<span name='custom-anchor'></span>\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)

        host.scrollToAnchor("caf%C3%A9-docs")
        #expect(host.textView.selectedRange().location == (source as NSString).range(of: "# Café").location)

        host.scrollToAnchor("user-content-custom-anchor")
        #expect(host.textView.selectedRange().location == (source as NSString).range(of: "<span").location)
    }

    @Test func revealUsesTheEditorLineSeparatorInMixedEndingFiles() throws {
        let source = "one\r\ntwo\n😀 needle\rfinal needle"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        host.textView.lineSeparator = "\r\n"

        host.reveal(docId: document.id, line: 2, column: 7, length: 6)
        #expect(host.textView.selectedRange() == NSRange(location: 12, length: 6))
    }

    @Test func olderSaveSnapshotDoesNotHideNewerEdits() async throws {
        let (document, url) = try makeDocument("before")
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        document.editor = host

        let snapshot = try #require(await host.snapshot(docId: document.id))
        host.applyText(docId: document.id, text: "after")
        await host.markSaved(docId: document.id, snapshotId: snapshot.snapshotId)

        let current = try #require(await host.snapshot(docId: document.id))
        #expect(current.text == "after")
        #expect(current.dirty)
    }
}
