import AppKit
import Darwin
import MdbCore
import SwiftUI
import Testing

@testable import MarkdownBrowser

@Suite(.serialized) @MainActor struct NativeEditorTests {
    private func makeDocument(_ source: String, data: Data? = nil) throws -> (OpenDocument, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        try (data ?? Data(source.utf8)).write(to: url)
        return (try OpenDocument(id: 1, url: url, kind: .markdown), url)
    }

    private func inlineView(in view: NSView, containing text: String, index: Int? = nil) -> NativeInlineTextView? {
        if let view = view as? NativeInlineTextView, view.string.contains(text),
           index.map({ view.accessibilityIdentifier() == "markdown-inline-\($0)" }) ?? true { return view }
        return view.subviews.lazy.compactMap { inlineView(in: $0, containing: text, index: index) }.first
    }

    private func clickPoint(in view: NSTextView, at index: Int) throws -> NSPoint {
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let point = NSPoint(x: view.textContainerOrigin.x + rect.minX + 0.1,
            y: view.textContainerOrigin.y + rect.midY)
        #expect(view.characterIndexForInsertion(at: point) == index)
        return view.convert(point, to: nil)
    }

    private func postClick(in window: NSWindow, at point: NSPoint, modifiers: NSEvent.ModifierFlags = [],
        count: Int = 1, draggingTo end: NSPoint? = nil) throws {
        let types: [NSEvent.EventType] = end == nil
            ? [.leftMouseDown, .leftMouseUp] : [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        for type in types {
            let location = type == .leftMouseDown ? point : end ?? point
            let event = try #require(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1))
            NSApp.postEvent(event, atStart: false)
        }
    }

    @Test func newWorkspacesUseTheNativeEditor() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(url: root)
        #expect(workspace.editor.scrollView.documentView === workspace.editor.textView)
        workspace.close()
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

    @MainActor private final class AttributeEditRecorder: NSObject {
        private(set) var longest = 0

        init(_ storage: NSTextStorage) {
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(processed), name: NSTextStorage.didProcessEditingNotification,
                object: storage)
        }

        @objc private func processed(_ notification: Notification) {
            guard let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedAttributes) else { return }
            longest = max(longest, storage.editedRange.length)
        }
    }

    @Test func typingAboveThePreviewLimitDoesNotResetTheWholeDocument() throws {
        let source = String(repeating: "Plain line of text.\n", count: 300_000)
        #expect(source.utf8.count > OpenDocument.livePreviewSizeLimit)
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(document.sourceMode)
        let host = NativeEditorHost()
        host.onDirtyChange = { _, dirty in document.isDirty = dirty }
        host.load(document, rootURL: nil, anchor: nil)
        #expect(host.preview.tree == nil)

        let storage = try #require(host.textView.textStorage)
        let recorder = AttributeEditRecorder(storage)
        host.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        host.textView.insertText("y", replacementRange: NSRange(location: storage.length, length: 0))

        #expect(document.isDirty)
        #expect(host.textView.string.hasPrefix("xPlain") && host.textView.string.hasSuffix("y"))
        #expect(host.preview.tree == nil)
        #expect(recorder.longest < 1_000,
            "A keystroke re-attributed \(recorder.longest) of \(storage.length) UTF-16 units.")
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

    @Test func parserBackedLinksResolveReferencesAndIgnoreCode() throws {
        let source = "😀 [nested](a(b).md \"Title\")\r\n`[no](bad)`\r\n\r\n[guide][ DOCS ]\r\n\r\n[docs]: <docs/my guide.md>\r\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        var opened: [(Int, String, Bool)] = []
        host.onOpenLink = { opened.append(($0, $1, $2)) }

        #expect(host.textView.openLink((source as NSString).range(of: "nested").location, false))
        #expect(host.textView.openLink((source as NSString).range(of: "guide]").location, true))
        #expect(!host.textView.openLink((source as NSString).range(of: "[no]").location, false))
        #expect(opened.count == 2)
        #expect(opened[0].0 == document.id)
        #expect(opened[0].1 == "a(b).md")
        #expect(!opened[0].2)
        #expect(opened[1].1 == "docs/my guide.md")
        #expect(opened[1].2)
        #expect(host.textView.string == source)
    }

    @Test func headingAnchorsFollowNestedMarkdownStructure() throws {
        let source = "```\n# Fake\n```\n\n> # Nested *heading*\n\n    # Fake\n\n# Nested heading\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)

        host.scrollToAnchor("NESTED-HEADING")
        #expect(host.textView.selectedRange().location == (source as NSString).range(of: "# Nested *").location)
        host.scrollToAnchor("nested-heading-1")
        #expect(host.textView.selectedRange().location == (source as NSString).range(of: "# Nested heading").location)
    }

    @Test func stylingNeverChangesSourceOrDirtyStateAndSurvivesReload() async throws {
        let source = "# Heading\r\n\r\n**bold** and `code` 😀\r\n"
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(source.utf8)
        let (document, url) = try makeDocument(source, data: original)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        document.editor = host
        host.onDirtyChange = { _, dirty in document.isDirty = dirty }
        host.load(document, rootURL: nil, anchor: nil)

        let offset = (source as NSString).range(of: "bold").location
        let font = try #require(host.textView.textStorage?.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        #expect(await host.text(docId: document.id) == source)
        #expect(await document.save() == .notNeeded)
        #expect(try Data(contentsOf: url) == original)

        host.replaceText(docId: document.id, text: source)
        let reloaded = try #require(host.textView.textStorage?.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: reloaded).contains(.boldFontMask))
        #expect(!document.isDirty)
    }

    @Test func parsingDoesNotDisturbMarkedTextOrItsSelection() throws {
        let (document, url) = try makeDocument("**bold** ")
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeFirstResponder(host.textView)
        host.load(document, rootURL: nil, anchor: nil)
        host.textView.setMarkedText(
            "に", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 9, length: 0))
        let selection = host.textView.selectedRange()
        let marked = host.textView.markedRange()
        host.ensureMarkdown()
        #expect(host.textView.hasMarkedText())
        #expect(host.textView.selectedRange() == selection)
        #expect(host.textView.markedRange() == marked)
    }

    @Test func nestedEmphasisKeepsBothFontTraits() throws {
        let source = "***both***"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let font = try #require(host.textView.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        let traits = NSFontManager.shared.traits(of: font)
        #expect(traits.contains(.boldFontMask))
        #expect(traits.contains(.italicFontMask))
    }

    @Test func backgroundStylingUsesTheLatestRevision() async throws {
        let (document, url) = try makeDocument("**old**")
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)

        host.applyText(docId: document.id, text: "**intermediate**")
        host.applyText(docId: document.id, text: "[latest](current.md)")
        try await waitUntil { host.preview.tree?.source == "[latest](current.md)" }

        #expect(host.textView.string == "[latest](current.md)")
        let color = try #require(host.textView.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor)
        #expect(color == .linkColor)
        let font = try #require(host.textView.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        #expect(!NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        var target = ""
        host.onOpenLink = { _, href, _ in target = href }
        #expect(host.textView.openLink(2, false))
        #expect(target == "current.md")
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

    @Test func previewUsesSourceMappedTasksAndHeadingsAndTogglesOnlyTheSymbol() throws {
        let source = "# Tasks\r\n\r\n- [ ] **First** 😀\r\n- [x] Second\r\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeFirstResponder(host.textView)
        let tree = try #require(host.preview.tree)
        #expect(tree.nodes.contains { $0.attributes["id"] == "tasks" })
        let tasks = tree.nodes.filter { $0.attributes["task-offset"] != nil }
        #expect(tasks.count == 2)
        let offset = try #require(tasks.first?.attributes["task-offset"].flatMap(Int.init))
        host.preview.toggleTask(offset, source)
        #expect(host.textView.string == source.replacingOccurrences(of: "[ ]", with: "[x]"))
        host.textView.undoManager?.undo()
        #expect(host.textView.string == source)
        host.setSourceMode(true)
        #expect(!host.preview.isVisible)
        host.setSourceMode(false)
        #expect(host.preview.isVisible)
    }

    @Test func previewResourcesEnforceSchemesTraversalAndSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = base.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appending(path: "outside.png")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link.png"), withDestinationURL: outside)
        let model = NativePreviewModel()
        model.documentURL = root.appending(path: "readme.md")
        model.rootURL = root
        model.isAllowed = { PathPolicy.isWithin($0, roots: [root]) }
        var denied: [URL] = []
        model.onDenied = { denied.append($0) }
        #expect(try model.resourceURL("images/hello%20world.png?raw=1#x") == PathPolicy.canonical(root.appending(path: "images/hello world.png")))
        #expect(try model.resourceURL("/logo.png") == PathPolicy.canonical(root.appending(path: "logo.png")))
        #expect(throws: (any Error).self) { try model.resourceURL("../outside.png") }
        #expect(throws: (any Error).self) { try model.resourceURL("link.png") }
        #expect(throws: (any Error).self) { try model.resourceURL("javascript:alert(1)") }
        #expect(denied.count == 2)
    }

    @Test func nativeMathAndRichPreviewLayOutWithoutChangingSource() throws {
        let source = "# Rich\n\n![alt](image.png)\n\n| A | B |\n| - | - |\n| x | y |\n\n<details><summary>More</summary>\n\n**bold**\n\n</details>\n\n$\\frac{a}{b}$\n\n```mermaid\nflowchart LR\nA --> B\n```\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let tree = try #require(host.preview.tree)
        for tag in ["table", "details", "summary", "img", "span", "pre"] {
            #expect(tree.nodes.contains { $0.tag == tag })
        }
        let view = NSHostingView(rootView: NativeEditorView(host: host))
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        view.layoutSubtreeIfNeeded()
        #expect(host.textView.string == source)
        #expect(try NativeMath.image("\\frac{a}{b}", display: true, dark: false).size.width > 0)
        #expect(try NativeMath.image("x^2", display: false, dark: true).size.height > 0)
        #expect(throws: (any Error).self) { try NativeMath.image("\\notARealCommand{x}", display: false, dark: false) }
    }

    @Test func rawHTMLOrderedListStartCannotOverflowItemNumbers() throws {
        let source = "<ol start=\"9223372036854775807\"><li>a</li><li>b</li></ol>\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let tree = try #require(host.preview.tree)
        let list = try #require(tree.nodes.indices.first { tree.nodes[$0].tag == "ol" })
        let view = NSHostingView(rootView: NativePreviewBlock(tree: tree, index: list, model: host.preview))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        // Laying out the list evaluates each item's number; before the clamp this trapped on integer overflow.
        view.layoutSubtreeIfNeeded()
        #expect(view.subviews.isEmpty == false)
    }

    @Test func tenThousandLineTypingKeepsTheSourceAndReportsLatency() throws {
        let source = String(repeating: "A paragraph with **bold** and [link](guide.md).\n", count: 10_000)
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let start = ContinuousClock.now
        host.textView.insertText("x", replacementRange: NSRange(location: (source as NSString).length, length: 0))
        let elapsed = start.duration(to: .now)
        print("Native 10k-line insertion (without display/layout): \(elapsed)")
        #expect(host.textView.string == source + "x")
    }

    @Test func insertedPlainTextDoesNotKeepInheritedMarkdownAttributes() throws {
        let (document, url) = try makeDocument("**bold**")
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        host.textView.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)]
        host.textView.insertText(" plain", replacementRange: NSRange(location: 8, length: 0))
        host.ensureMarkdown()
        let font = try #require(host.textView.textStorage?.attribute(.font, at: 10, effectiveRange: nil) as? NSFont)
        #expect(!NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        #expect(host.textView.string == "**bold** plain")
    }

    @Test func editAtTheTopRestylesOnlyTheEditedRegion() throws {
        let source = "Intro\n\n" + (1...200).map { "# Heading \($0)\n\nSome **bold** text.\n\n" }.joined()
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let storage = try #require(host.textView.textStorage)
        func fontSize(at location: Int) -> CGFloat? {
            (storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize
        }
        let last = (source as NSString).range(of: "# Heading 200")

        host.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        host.ensureMarkdown()
        #expect(host.restyledRanges == [NSRange(location: 0, length: 2)])
        #expect(fontSize(at: last.location) == 14)
        #expect(fontSize(at: last.location + 1) == 23)
        #expect(fontSize(at: NSMaxRange(last)) == 23)
        #expect(fontSize(at: NSMaxRange(last) + 1) == 14)

        host.textView.insertText("", replacementRange: NSRange(location: 0, length: 1))
        host.ensureMarkdown()
        #expect(host.restyledRanges == [NSRange(location: 0, length: 1)])
        #expect(fontSize(at: last.location) == 23)
        #expect(fontSize(at: NSMaxRange(last)) == 14)
        #expect(host.textView.string == source)

        // Turning the intro into a heading changes one style; the 200 below still only move.
        host.textView.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
        host.ensureMarkdown()
        #expect(host.restyledRanges == [NSRange(location: 0, length: 7)])
        #expect(fontSize(at: 6) == 23)
        #expect(fontSize(at: last.location + 2) == 23)
    }

    @Test func editInsideAStyleInvalidatesItsShiftedExtent() {
        let style = NativeMarkdownStyle(range: NSRange(location: 5, length: 10), kind: .strong, level: 0)
        // Offsets 3..<7 became six characters: the old attributes now end at 17 even though a style sits at 5..<15 again.
        let ranges = NativeMarkdownStyle.changedRanges(
            from: [style], to: [style], edited: NSRange(location: 3, length: 6), delta: 2)
        #expect(ranges.contains(NSRange(location: 3, length: 14)))
    }

    @Test func untrackedEditFallsBackToRestylingMovedStyles() throws {
        let (document, url) = try makeDocument("Intro\n\n# One\n\ntail")
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let storage = try #require(host.textView.textStorage)
        host.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        // Bypasses the delegate, so the tracked edit no longer explains the length change.
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "y")
        host.ensureMarkdown()
        #expect(host.restyledRanges.contains { NSLocationInRange(8, $0) && NSLocationInRange(12, $0) })
        #expect((storage.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)?.pointSize == 23)
        #expect((storage.attribute(.font, at: 13, effectiveRange: nil) as? NSFont)?.pointSize == 14)
    }

    @Test func nonMarkdownCodeHighlightsWithoutChangingCrLf() async throws {
        let source = "let greeting = \"hello\";\r\n// comment\r\n"
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).rs")
        try Data(source.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try OpenDocument(id: 1, url: url, kind: .text)
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        for _ in 0..<20 {
            let keyword = host.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            let string = host.textView.textStorage?.attribute(.foregroundColor, at: 16, effectiveRange: nil) as? NSColor
            if keyword != string { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let keyword = host.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let string = host.textView.textStorage?.attribute(.foregroundColor, at: 16, effectiveRange: nil) as? NSColor
        #expect(keyword != string)
        #expect(host.textView.string == source)
        #expect(!host.preview.isVisible)
    }

    @Test func inPlaceRenderingRevealsTheActiveBlockAndSourceModeKeepsOffsets() async throws {
        let source = "# Active\r\n\r\n**bold** and [guide](guide.md)\r\n\r\nlast\r\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let paragraph = (source as NSString).range(of: "**bold** and [guide](guide.md)")
        #expect(host.liveLayout.concealed.contains(paragraph.location))
        #expect(host.liveLayout.concealed.contains(0))
        host.livePreview.reveal(paragraph)
        #expect(host.textView.selectedRange().location == paragraph.location)
        #expect(!host.liveLayout.concealed.contains(paragraph.location))
        #expect(host.liveLayout.concealed.contains(0))
        let selection = host.textView.selectedRange()
        host.setSourceMode(true)
        #expect(host.liveLayout.concealed.isEmpty)
        #expect(host.textView.selectedRange() == selection)
        #expect(await host.text(docId: document.id) == source)
        host.setSourceMode(false)
        #expect(host.liveLayout.concealed.contains(0))
        #expect(host.textView.selectedRange() == selection)
        #expect(!(try #require(await host.snapshot(docId: document.id))).dirty)
    }

    @Test func openingOrFollowingAnAnchorKeepsTheCaretBlockRenderedUntilTheUserActs() throws {
        let source = "# First\n\nbody\n\n## Second\n\nmore\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        #expect(host.textView.selectedRange() == NSRange(location: 0, length: 0))
        #expect(host.liveLayout.concealed.contains(0))
        host.livePreview.reveal(NSRange(location: 0, length: 0))
        #expect(!host.liveLayout.concealed.contains(0))

        let second = (source as NSString).range(of: "## Second").location
        host.load(document, rootURL: nil, anchor: "second")
        #expect(host.textView.selectedRange() == NSRange(location: second, length: 0))
        #expect(host.liveLayout.concealed.contains(0))
        #expect(host.liveLayout.concealed.contains(second))

        host.load(document, rootURL: nil, anchor: nil)
        host.textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!host.liveLayout.concealed.contains(0))

        host.load(document, rootURL: nil, anchor: nil)
        host.textView.deleteForward(nil)
        host.ensureMarkdown()
        #expect(host.textView.selectedRange() == NSRange(location: 0, length: 0))
        #expect(!host.liveLayout.concealed.contains(0))
        #expect(host.textView.string == " First\n\nbody\n\n## Second\n\nmore\n")
    }

    @Test func concealedMultilineBlocksReserveOneRenderedRectangle() {
        let source = "top\n```md\n**hidden**\n```\nafter\n"
        let storage = NSTextStorage(string: source)
        let layout = NativeLiveLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        let start = (source as NSString).range(of: "```md").location
        let after = (source as NSString).range(of: "after").location
        let range = NSRange(location: start, length: after - start - 1)
        layout.present([(range, NSSize(width: 300, height: 120))])
        layout.ensureLayout(for: container)
        let first = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
        let next = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: after), effectiveRange: nil)
        #expect(first.height >= 120)
        #expect(next.minY - first.minY >= 120)
        #expect(next.minY - first.minY < 150)
        #expect(textView.string == source)
        layout.present([])
        layout.ensureLayout(for: container)
        let revealed = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: after), effectiveRange: nil)
        #expect(revealed.minY < next.minY)
    }

    @Test func detailsAndListsRenderAsWholeBlocksWithoutLeakingClosingTags() {
        let source = "# Title\n\n<details>\n<summary>More</summary>\n\n**inside**\n\n</details>\n\n- [ ] task\n- other\n"
        let parsed = NativeMarkdown(source)
        let blocks = NativeLiveBlock.blocks(source: source, markdown: parsed)
        let details = blocks.first { parsed.rendered.nodes[$0.renderIndex].tag == "details" }
        #expect(details != nil)
        if let details {
            #expect((source as NSString).substring(with: details.range).hasSuffix("</details>"))
            #expect(!blocks.contains { $0.range.location > details.range.location && $0.range.location < NSMaxRange(details.range) })
        }
        #expect(blocks.contains { parsed.rendered.nodes[$0.renderIndex].tag == "ul" })
    }

    @Test(arguments: ["<!-- -->\n\n", "</div\n\n", "<x-block><div>\n\n"])
    func liveBlockPlanningStaysLinearInHTMLBlocks(block: String) {
        func planningTime(_ count: Int) -> Duration {
            let source = String(repeating: block, count: count) + ">\n"
            let parsed = NativeMarkdown(source)
            return (0..<3).map { _ in
                ContinuousClock().measure { _ = NativeLiveBlock.blocks(source: source, markdown: parsed) }
            }.min()!
        }
        let baseline = planningTime(1_000)
        let large = planningTime(16_000)
        // Linear planning takes about 16 times the baseline; rescanning the rest of the document per block takes 256.
        #expect(large < baseline * 64, "1,000 blocks: \(baseline), 16,000 blocks: \(large)")
    }

    @Test func oneEditingPaneHostsRenderedBlocksAndResizesWithoutChangingText() async throws {
        let source = "# Title\n\nA **rendered** paragraph with $x^2$.\n\n| A | B |\n| - | - |\n| x | y |\n\nlast\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let view = NSHostingView(rootView: NativeEditorView(host: host))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        host.livePreview.updateViewport()
        func rendered() -> [NSView] {
            view.layoutSubtreeIfNeeded()
            return host.textView.subviews.filter { $0.accessibilityIdentifier().hasPrefix("markdown-block-") }
        }
        try await waitUntil {
            let views = rendered()
            return !views.isEmpty && views.allSatisfy { $0.frame.width > 700 && $0.frame.height > 0 }
        }
        #expect(host.scrollView.contentSize.width > 800)
        let largeWidth = rendered().first?.frame.width ?? 0
        window.setContentSize(NSSize(width: 600, height: 600))
        view.layoutSubtreeIfNeeded()
        host.livePreview.updateViewport()
        try await waitUntil {
            let views = rendered()
            return !views.isEmpty && views.allSatisfy { $0.frame.width < largeWidth }
        }
        #expect(host.textView.string == source)
        host.setSourceMode(true)
        #expect(host.textView.subviews.allSatisfy { !$0.accessibilityIdentifier().hasPrefix("markdown-block-") })
        #expect(host.textView.string == source)
    }

    @Test func inPlaceCompositionKeepsOtherBlocksAndUndoUsesRawSource() throws {
        let source = "Editing\n\n**Rendered**\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeFirstResponder(host.textView)
        host.load(document, rootURL: nil, anchor: nil)
        host.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        #expect(host.textView.hasMarkedText())
        let renderedStart = (host.textView.string as NSString).range(of: "**Rendered**").location
        #expect(host.liveLayout.concealed.contains(renderedStart))
        host.textView.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(host.textView.string == "日本" + source)
        #expect(!host.textView.hasMarkedText())
        host.ensureMarkdown()
        host.textView.undoManager?.undo()
        #expect(host.textView.string == source)
        #expect(!host.textView.string.contains("\u{fffc}"))
    }

    @Test func inlineDelimitersRevealOnlyWhenSelectionTouchesTheirConstruct() throws {
        let source = "plain **bold** and [guide](guide.md) and `code`\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let bold = (source as NSString).range(of: "**bold**")
        let link = (source as NSString).range(of: "[guide](guide.md)")
        let code = (source as NSString).range(of: "`code`")
        #expect(host.liveLayout.concealed.contains(bold.location))
        #expect(host.liveLayout.concealed.contains(link.location))
        #expect(host.liveLayout.concealed.contains(code.location))
        host.textView.setSelectedRange(NSRange(location: bold.location + 3, length: 0))
        #expect(!host.liveLayout.concealed.contains(bold.location))
        #expect(host.liveLayout.concealed.contains(link.location))
        host.textView.setSelectedRange(NSRange(location: link.location + 3, length: 0))
        #expect(host.liveLayout.concealed.contains(bold.location))
        #expect(!host.liveLayout.concealed.contains(link.location))
        host.setSourceMode(true)
        #expect(host.liveLayout.concealed.isEmpty)
        #expect(host.textView.string == source)
    }

    @Test func renderedControlsRemainInteractiveInsideTheEditingPane() async throws {
        let source = "# Editing\n\n- [ ] Task\n\n<details>\n<summary>More</summary>\n\nExpanded content\n\n</details>\n\n[guide](guide.md)\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeFirstResponder(host.textView)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.scrollView.layoutSubtreeIfNeeded()
        host.livePreview.updateViewport()

        func click(_ view: NSView, point: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws {
            let location = view.convert(point, to: nil)
            let target = window.contentView?.hitTest(location)
            #expect(target?.isDescendant(of: view) == true, "Target \(String(describing: target)), frame \(view.frame), point \(location)")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                NSApp.postEvent(event, atStart: false)
            }
        }

        let parsed = NativeMarkdown(source)
        let plans = NativeLiveBlock.blocks(source: source, markdown: parsed)
        func blockView(_ tag: String) -> NSView? {
            guard let plan = plans.first(where: { parsed.rendered.nodes[$0.renderIndex].tag == tag }) else { return nil }
            return host.textView.subviews.first { $0.accessibilityIdentifier() == "markdown-block-\(plan.renderIndex)" }
        }
        func renderedView(_ tag: String) throws -> NSView { try #require(blockView(tag)) }
        try await waitUntil {
            host.scrollView.layoutSubtreeIfNeeded()
            return ["details", "ul", "p"].allSatisfy { blockView($0) != nil }
        }
        let disclosure = try renderedView("details")
        let closedHeight = disclosure.frame.height
        try click(disclosure, point: NSPoint(x: 7, y: 9))
        try await waitUntil {
            host.scrollView.layoutSubtreeIfNeeded()
            return disclosure.frame.height > closedHeight
        }
        #expect(host.textView.string == source)
        #expect(host.liveLayout.concealed.contains((source as NSString).range(of: "<details>").location))
        let checkbox = try renderedView("ul")
        try click(checkbox, point: NSPoint(x: 16, y: 9))
        let checked = source.replacingOccurrences(of: "[ ]", with: "[x]")
        try await waitUntil { host.textView.string == checked && host.preview.tree?.source == checked }
        host.textView.undoManager?.undo()
        #expect(host.textView.string == source)
        try await waitUntil { host.preview.tree?.source == source }
        host.scrollView.layoutSubtreeIfNeeded()
        var followed: (String, Bool)?
        host.onOpenLink = { _, href, newTab in followed = (href, newTab) }
        let link = try renderedView("p")
        try click(link, point: NSPoint(x: 10, y: 9), modifiers: [.command, .shift])
        try await waitUntil { followed != nil }
        #expect(followed?.0 == "guide.md")
        #expect(followed?.1 == true)
        try click(link, point: NSPoint(x: 10, y: 9))
        let label = (source as NSString).range(of: "guide")
        try await waitUntil { NSLocationInRange(host.textView.selectedRange().location, label) }
        #expect(host.textView.string == source)
    }

    @Test func renderedPositionsMapThroughMarkdownSyntaxAndUnicode() throws {
        let source = "# Same **same** and [same](guide.md)\r\n\r\n😀 cafe\u{301} &amp; `same` :smile: same\r\n"
        let parsed = NativeMarkdown(source)
        let heading = try #require(parsed.rendered.nodes.firstIndex { $0.tag == "h1" })
        let map = try #require(parsed.rendered.sourceMaps[heading])
        #expect(map.text == "Same same and same")
        let bold = (source as NSString).range(of: "**same**")
        #expect(map.offsets[5] == bold.location + 2)
        #expect(map.offsets[7] == bold.location + 4)
        let label = (source as NSString).range(of: "[same]")
        #expect(map.offsets[14] == label.location + 1)
        let paragraph = try #require(parsed.rendered.nodes.firstIndex { $0.tag == "p" })
        let prose = try #require(parsed.rendered.sourceMaps[paragraph])
        #expect(prose.text.hasPrefix("😀 cafe\u{301} & same "))
        let code = (source as NSString).range(of: "`same`")
        let displayedCode = (prose.text as NSString).range(of: "same")
        #expect(prose.offsets[displayedCode.location + 2] == code.location + 3)
        let last = (prose.text as NSString).range(of: "same", options: .backwards)
        let rawLast = (source as NSString).range(of: "same", options: .backwards)
        #expect(prose.offsets[last.location] == rawLast.location)
        #expect(prose.offsets.count == (prose.text as NSString).length + 1)

        let unclosed = "```swift\nlet value = 42\n```not-a-fence"
        let codeTree = NativeMarkdown(unclosed).rendered
        let pre = try #require(codeTree.nodes.firstIndex { $0.tag == "pre" })
        let codeMap = try #require(codeTree.sourceMaps[pre])
        let position = (codeMap.text as NSString).range(of: "not-a-fence").location + 4
        #expect(codeMap.offsets[position] == (unclosed as NSString).range(of: "not-a-fence").location + 4)
    }

    @Test func outOfRangeParserNodesFallBackToBlockEditing() throws {
        let source = "plain `code` text\n"
        let parsed = NativeMarkdown(source)
        let paragraph = try #require(parsed.nodes.firstIndex { $0.kind == .paragraph })
        let children = parsed.children[paragraph]
        let text = try #require(children.first { parsed.nodes[$0].kind == .text })
        let code = try #require(children.first { parsed.nodes[$0].kind == .code })
        let sourceText = source as NSString
        for target in [text, code] {
            var broken = parsed.nodes
            broken[target].length = UInt32(source.utf16.count + 10)
            #expect(NativeRenderedSourceMap.make(
                index: paragraph, nodes: broken, children: parsed.children, source: sourceText) == nil)
            let tree = NativeRenderTree(source, structure: broken)
            let rendered = try #require(tree.nodes.firstIndex { $0.tag == "p" })
            #expect(tree.sourceMaps[rendered] == nil)
        }
        #expect(NativeRenderedSourceMap.aligned("x", range: NSRange(location: 3, length: 100), source: sourceText) == nil)
    }

    @Test func renderedClicksUseExactSourceOffsetsAndNativeSelection() async throws {
        let source = "# Active\r\n\r\n😀 before **repeat** then [repeat](guide.md) and `repeat`.\r\n\r\nlast\r\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        func rendered() async throws -> NativeInlineTextView {
            host.textView.setSelectedRange(NSRange(location: 2, length: 0))
            host.scrollView.layoutSubtreeIfNeeded()
            host.livePreview.updateViewport()
            try await waitUntil {
                host.scrollView.layoutSubtreeIfNeeded()
                return inlineView(in: host.textView, containing: "😀 before") != nil
            }
            return try #require(inlineView(in: host.textView, containing: "😀 before"))
        }

        var view = try await rendered()
        let bold = (source as NSString).range(of: "**repeat**")
        var position = (view.string as NSString).range(of: "repeat").location + 2
        try postClick(in: window, at: clickPoint(in: view, at: position))
        try await waitUntil { host.textView.selectedRange() == NSRange(location: bold.location + 4, length: 0) }
        #expect(window.firstResponder === host.textView)
        host.textView.moveRightAndModifySelection(nil)
        #expect(host.textView.selectedRange() == NSRange(location: bold.location + 4, length: 1))

        view = try await rendered()
        position = (view.string as NSString).range(of: "repeat").location + 2
        try postClick(in: window, at: clickPoint(in: view, at: position), count: 2)
        try await waitUntil { host.textView.selectedRange() == NSRange(location: bold.location + 2, length: 6) }

        view = try await rendered()
        position = (view.string as NSString).range(of: "repeat", options: .backwards).location + 3
        let code = (source as NSString).range(of: "`repeat`")
        try postClick(in: window, at: clickPoint(in: view, at: position), modifiers: .shift)
        try await waitUntil { host.textView.selectedRange() == NSRange(location: 2, length: code.location + 4 - 2) }
        #expect(host.textView.string == source)
        #expect(!(host.textView.undoManager?.canUndo ?? false))

        view = try await rendered()
        position = (view.string as NSString).range(of: "repeat").location + 2
        let point = try clickPoint(in: view, at: position)
        try postClick(in: window, at: point, draggingTo: NSPoint(x: point.x + 120, y: point.y))
        try await waitUntil { host.textView.selectedRange().length > 0 }
        #expect(host.textView.selectedRange().location == bold.location + 4)
        #expect(host.textView.string == source)
    }

    @Test func revealingScrolledTextKeepsTheClickedCaretOnItsScreenRow() async throws {
        let list = (0..<30).map { "- item \($0)" }.joined(separator: "\n")
        let target = "Target **word** " + String(repeating: "wrapping text ", count: 30)
        let source = "# Heading\n\n\(list)\n\n\(target)\n\n"
            + (0..<40).map { "Trailing paragraph \($0)\n\n" }.joined()
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.livePreview.reveal((source as NSString).range(of: "- item 0"))
        host.scrollView.layoutSubtreeIfNeeded()
        let targetRange = (source as NSString).range(of: target)
        host.textView.scrollRangeToVisible(NSRange(location: targetRange.location, length: 0))
        host.livePreview.updateViewport()
        try await waitUntil {
            host.scrollView.layoutSubtreeIfNeeded()
            return inlineView(in: host.textView, containing: "Target word") != nil
        }
        let view = try #require(inlineView(in: host.textView, containing: "Target word"))
        let position = (view.string as NSString).range(of: "wrapping text").location + 4
        let point = try clickPoint(in: view, at: position)
        try postClick(in: window, at: point)
        let expected = (source as NSString).range(of: "wrapping text").location + 4
        func caretY() -> CGFloat {
            let rect = host.textView.firstRect(forCharacterRange: NSRange(location: expected, length: 0), actualRange: nil)
            return window.convertPoint(fromScreen: NSPoint(x: rect.minX, y: rect.midY)).y
        }
        try await waitUntil {
            host.scrollView.layoutSubtreeIfNeeded()
            return host.textView.selectedRange() == NSRange(location: expected, length: 0) && abs(caretY() - point.y) <= 1
        }
        #expect(host.scrollView.contentView.bounds.minY > 0)
        #expect(host.textView.string == source)
    }

    @Test func renderedCodeAndNestedTableCellsKeepTheirSourcePositions() async throws {
        let source = "# Active\n\noutside value\n\n```swift\nlet value = 42\n```\n\n"
            + "| Item | Value |\n| --- | --- |\n| same **value** | 99 |\n\nlast\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for (renderedText, rawText) in [("let value", "value = 42"), ("same value", "value**")] {
            host.textView.setSelectedRange(NSRange(location: 2, length: 0))
            host.scrollView.layoutSubtreeIfNeeded()
            host.livePreview.updateViewport()
            try await waitUntil {
                host.scrollView.layoutSubtreeIfNeeded()
                return inlineView(in: host.textView, containing: renderedText) != nil
            }
            let view = try #require(inlineView(in: host.textView, containing: renderedText))
            let position = (view.string as NSString).range(of: "value").location + 2
            try postClick(in: window, at: clickPoint(in: view, at: position))
            let expected = NSRange(location: (source as NSString).range(of: rawText).location + 2, length: 0)
            try await waitUntil { host.textView.selectedRange() == expected }
        }
        #expect(host.textView.string == source)
    }

    @Test func renderedFencedCodeHasTokenColorsInBothThemes() async throws {
        let source = "# Active\r\n\r\n```swift\r\nstruct Greeting {\r\n    let name: String = \"😀\"\r\n}\r\n```\r\n\r\n"
            + "```typescript\r\nconst count: number = 42; // counter\r\n```\r\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        for (scheme, appearance) in [
            (ColorScheme.light, NSAppearance.Name.aqua), (ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            let host = NativeEditorHost()
            host.load(document, rootURL: nil, anchor: nil)
            let view = NSHostingView(rootView: NativeEditorView(host: host).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            func tokenColors(_ text: String) -> Set<NSColor> {
                guard let label = inlineView(in: host.textView, containing: text) else { return [] }
                let attributed = label.attributedString()
                var colors = Set<NSColor>()
                attributed.enumerateAttribute(.foregroundColor,
                    in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                    if let color = value as? NSColor { colors.insert(color) }
                }
                return colors
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
                view.layoutSubtreeIfNeeded()
                host.livePreview.updateViewport()
                if ["struct Greeting", "const count"].allSatisfy({ tokenColors($0).count >= 3 }) { break }
            }
            for text in ["struct Greeting", "const count"] {
                #expect(tokenColors(text).count >= 3, "\(text) should have distinct token colors in \(scheme).")
            }
            #expect(host.textView.string == source)
        }
    }

    @Test func rawHTMLTextAndWidgetsHaveScopedSourceTargetsAndAccessibleEditing() async throws {
        let source = "# Active\r\n\r\n<div title=\"a > b\">\r\n<p>same &amp; 😀 <b>repeat</b></p>\r\n"
            + "<p>same &amp; 😀 <b>repeat</b></p>\r\n<img src=\"missing.png\" alt=\"Local image\">\r\n"
            + "<video src=\"missing.mov\" controls></video>\r\n</div>\r\n\r\n```mermaid\r\nflowchart LR\r\nA --> B\r\n```\r\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.load(document, rootURL: nil, anchor: nil)
        let tree = try #require(host.preview.tree)
        let paragraphs = tree.nodes.indices.filter { tree.nodes[$0].tag == "p" && tree.sourceRanges[$0] != nil }
        #expect(paragraphs.count == 2)
        let last = try #require(paragraphs.last)
        let map = try #require(tree.sourceMaps[last])
        #expect(map.text == "same & 😀 repeat")
        let repeatOffset = (map.text as NSString).range(of: "repeat").location + 2
        #expect(map.offsets[repeatOffset] == (source as NSString).range(of: "repeat", options: .backwards).location + 2)
        host.preview.editPosition(last, map.offsets[repeatOffset])
        #expect(host.textView.selectedRange().location == map.offsets[repeatOffset])

        for tag in ["img", "video", "pre"] {
            let index = try #require(tree.nodes.firstIndex { $0.tag == tag })
            let range = try #require(tree.sourceRanges[index])
            host.preview.editBlock(index)
            #expect(host.textView.selectedRange() == NSRange(location: range.location, length: 0))
        }
        host.textView.insertText("x", replacementRange: NSRange(location: 2, length: 0))
        let image = try #require(tree.nodes.firstIndex { $0.tag == "img" })
        host.preview.editBlock(image)
        #expect(host.textView.selectedRange().location == tree.sourceRanges[image]!.location + 1)
        host.textView.undoManager?.undo()
        #expect(host.textView.string == source)
        host.textView.setSelectedRange(NSRange(location: 2, length: 0))
        host.ensureMarkdown()
        host.scrollView.layoutSubtreeIfNeeded()
        host.livePreview.updateViewport()
        let firstParagraph = try #require(paragraphs.first)
        try await waitUntil { inlineView(in: host.textView, containing: "same & 😀 repeat", index: firstParagraph) != nil }
        let label = try #require(inlineView(in: host.textView, containing: "same & 😀 repeat", index: firstParagraph))
        #expect(label.accessibilityCustomActions()?.contains { $0.name == "Edit Markdown Source" } == true)
        #expect(label.accessibilityPerformPress())
        #expect(window.firstResponder === host.textView)
        #expect(host.textView.selectedRange().location == (source as NSString).range(of: "same").location)
        host.textView.insertText("typed ", replacementRange: host.textView.selectedRange())
        #expect(host.textView.string == source.replacingOccurrences(of: "<p>same", with: "<p>typed same",
            options: [], range: source.range(of: "<p>same")))
        host.textView.undoManager?.undo()
        #expect(host.textView.string == source)
        host.setSourceMode(true)
        #expect(host.textView.accessibilityRole() == .textArea)
        #expect(host.liveLayout.concealed.isEmpty)
    }

    @Test func nativeVisualFixturesProduceLightAndDarkWindowAttachments() async throws {
        let imageURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 240, height: 64), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let source = """
        # Editing

        ## Native rendering

        Some **bold**, *italic*, `code`, 😀 and inline math $x^2 + y^2 = z^2$.

        | Item | Value | Notes |
        | :--- | ---: | :---: |
        | A **table** | 42 | centered |
        | Unicode | 日本語 | 😀 |

        > [!NOTE]
        > Native alert, not browser CSS.

        - [ ] Unfinished task
        - [x] Finished task

        <details><summary>More details</summary><p>Disclosure content</p></details>

        ```mermaid
        flowchart LR
          A[Swift] --> B[Rust]
        ```

        ![Local blue image](\(imageURL.lastPathComponent))

        $$
        \\frac{a}{b} + \\sqrt{x}
        $$

        ```swift
        let greeting = "Hello, 😀"
        print(greeting)
        ```

        <video src="not-granted.mov" controls></video>

        ![Denied image](not-granted.png)

        End of visual fixture.
        """
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        for (name, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            let host = NativeEditorHost()
            var denied: [URL] = []
            host.preview.isAllowed = { PathPolicy.canonical($0) == PathPolicy.canonical(imageURL) }
            host.preview.onDenied = { denied.append($0) }
            host.load(document, rootURL: nil, anchor: nil)
            let view = NSHostingView(rootView: NativeEditorView(host: host).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            for page in 0..<2 {
                if page == 1 { host.textView.scrollToEndOfDocument(nil) }
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(50))
                    view.layoutSubtreeIfNeeded()
                    host.livePreview.updateViewport()
                }
                view.displayIfNeeded()
                let rendered = host.textView.subviews.filter {
                    $0.accessibilityIdentifier().hasPrefix("markdown-block-")
                }.sorted { $0.frame.minY < $1.frame.minY }
                #expect(!rendered.isEmpty)
                for (first, next) in zip(rendered, rendered.dropFirst()) {
                    #expect(first.frame.maxY <= next.frame.minY + 1)
                }
                if page == 0 {
                    let notes = try #require(inlineView(in: host.textView, containing: "Notes"))
                    let cell = notes.convert(notes.bounds, to: host.textView)
                    #expect(cell.minX >= 0 && cell.maxX <= host.textView.bounds.maxX)
                    #expect((notes.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                        as? NSParagraphStyle)?.alignment == .center)
                }
                let capture = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: capture)
                Attachment.record(try #require(capture.representation(using: .png, properties: [:])),
                    named: "native-\(name)-\(page).png")
            }
            #expect(host.textView.string == source)
            #expect(!document.isDirty)
            #expect(denied.contains { $0.lastPathComponent == "not-granted.mov" })
            #expect(denied.contains { $0.lastPathComponent == "not-granted.png" })
        }
    }

    @Test func keyboardArrowsEnterRenderedBlocksWithoutChangingSource() throws {
        let source = "# Active\n\nsecond **paragraph**\n\nlast\n"
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.load(document, rootURL: nil, anchor: nil)
        window.makeFirstResponder(host.textView)
        let paragraph = (source as NSString).range(of: "second")
        host.textView.setSelectedRange(NSRange(location: paragraph.location - 1, length: 0))
        #expect(host.liveLayout.concealed.contains(paragraph.location))
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}",
            isARepeat: false, keyCode: 124))
        host.textView.keyDown(with: right)
        #expect(host.textView.selectedRange() == NSRange(location: paragraph.location, length: 0))
        #expect(!host.liveLayout.concealed.contains(paragraph.location))
        #expect(host.textView.string == source)
    }

    @Test func visibleTenThousandLineEditingReportsFrameAndReparseLatency() async throws {
        func residentBytes() throws -> UInt64 {
            var info = mach_task_basic_info()
            let capacity = MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
            var count = mach_msg_type_number_t(capacity)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            try #require(status == KERN_SUCCESS)
            return info.resident_size
        }
        let source = String(repeating: "A paragraph with **bold** and [link](guide.md).\n\n", count: 5_000)
        let (document, url) = try makeDocument(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NativeEditorHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let beforeLoad = try residentBytes()
        host.load(document, rootURL: nil, anchor: nil)
        host.scrollView.layoutSubtreeIfNeeded()
        host.livePreview.updateViewport()
        try await Task.sleep(for: .milliseconds(300))
        var report = "Visible 10,000-line document; 5,000 Markdown blocks; 900x600 window.\n"
        report += "Process resident bytes: before load \(beforeLoad); loaded \(try residentBytes()).\n"
        for fraction in [0.0, 0.5, 1.0] {
            let position = Int(Double((host.textView.string as NSString).length) * fraction)
            host.textView.setSelectedRange(NSRange(location: position, length: 0))
            host.textView.scrollRangeToVisible(host.textView.selectedRange())
            host.scrollView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let start = ContinuousClock.now
            host.textView.insertText("x", replacementRange: host.textView.selectedRange())
            host.scrollView.layoutSubtreeIfNeeded()
            host.scrollView.displayIfNeeded()
            let frame = start.duration(to: .now)
            let expected = host.textView.string
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while host.preview.tree?.source != expected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(host.preview.tree?.source == expected)
            host.scrollView.layoutSubtreeIfNeeded()
            host.scrollView.displayIfNeeded()
            let settled = start.duration(to: .now)
            let views = host.textView.subviews.filter { $0.accessibilityIdentifier().hasPrefix("markdown-block-") }.count
            #expect(views < 100, "Only nearby blocks should have native views, not all 5,000 blocks.")
            report += "Position \(fraction): first displayed frame \(frame); reparsed frame \(settled); hosted blocks \(views).\n"
        }
        report += "Process resident bytes after three edits and scrolling: \(try residentBytes()).\n"
        print(report)
        Attachment.record(report, named: "visible-10k-line-latency.txt")
        #expect((host.textView.string as NSString).length == (source as NSString).length + 3)
    }
}
