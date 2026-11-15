import AppKit
import MdbCore
import SwiftUI
import Testing

@testable import MarkdownBrowser

@Suite @MainActor struct NativeEditorTests {
    private func makeDocument(_ source: String, data: Data? = nil) throws -> (OpenDocument, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        try (data ?? Data(source.utf8)).write(to: url)
        return (try OpenDocument(id: 1, url: url, kind: .markdown), url)
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
        try await Task.sleep(for: .milliseconds(200))

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
        #expect(!host.liveLayout.concealed.contains(0))
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
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(30))
            view.layoutSubtreeIfNeeded()
        }
        #expect(host.scrollView.contentSize.width > 800)
        let rendered = host.textView.subviews.filter { $0.accessibilityIdentifier().hasPrefix("markdown-block-") }
        #expect(!rendered.isEmpty)
        #expect(rendered.allSatisfy { $0.frame.width > 700 && $0.frame.height > 0 })
        let largeWidth = rendered.first?.frame.width ?? 0
        window.setContentSize(NSSize(width: 600, height: 600))
        view.layoutSubtreeIfNeeded()
        host.livePreview.updateViewport()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let resized = host.textView.subviews.filter { $0.accessibilityIdentifier().hasPrefix("markdown-block-") }
        #expect(!resized.isEmpty)
        #expect(resized.allSatisfy { $0.frame.width < largeWidth })
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
        try await Task.sleep(for: .milliseconds(150))
        host.scrollView.layoutSubtreeIfNeeded()

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
        func renderedView(_ tag: String) throws -> NSView {
            let plan = try #require(plans.first { parsed.rendered.nodes[$0.renderIndex].tag == tag })
            return try #require(host.textView.subviews.first {
                $0.accessibilityIdentifier() == "markdown-block-\(plan.renderIndex)"
            })
        }
        let disclosure = try renderedView("details")
        let closedHeight = disclosure.frame.height
        try click(disclosure, point: NSPoint(x: 7, y: 9))
        try await Task.sleep(for: .milliseconds(350))
        host.scrollView.layoutSubtreeIfNeeded()
        #expect(host.textView.string == source)
        #expect(host.liveLayout.concealed.contains((source as NSString).range(of: "<details>").location))
        #expect(disclosure.frame.height > closedHeight)
        let checkbox = try renderedView("ul")
        try click(checkbox, point: NSPoint(x: 16, y: 9))
        try await Task.sleep(for: .milliseconds(150))
        #expect(host.textView.string == source.replacingOccurrences(of: "[ ]", with: "[x]"))
        host.textView.undoManager?.undo()
        #expect(host.textView.string == source)
        try await Task.sleep(for: .milliseconds(150))
        host.scrollView.layoutSubtreeIfNeeded()
        var followed: (String, Bool)?
        host.onOpenLink = { _, href, newTab in followed = (href, newTab) }
        let link = try renderedView("p")
        try click(link, point: NSPoint(x: 10, y: 9), modifiers: [.command, .shift])
        try await Task.sleep(for: .milliseconds(100))
        #expect(followed?.0 == "guide.md")
        #expect(followed?.1 == true)
        try click(link, point: NSPoint(x: 10, y: 9))
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.textView.selectedRange().location == (source as NSString).range(of: "[guide]").location)
        #expect(host.textView.string == source)
    }
}
