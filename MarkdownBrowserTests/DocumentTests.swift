import Foundation
import Testing

@testable import MarkdownBrowser

/// Stands in for the web editor: holds the "live" text and tracks what was saved.
final class FakeEditor: DocumentEditor {
    var text: String
    var savedText: String
    var replaced: [String] = []
    private var snapshots: [Int: String] = [:]
    private var counter = 0

    init(text: String) {
        self.text = text
        savedText = text
    }

    func snapshot(docId: Int) async -> EditorSnapshot? {
        counter += 1
        snapshots[counter] = text
        return EditorSnapshot(snapshotId: counter, text: text, dirty: text != savedText)
    }

    func markSaved(docId: Int, snapshotId: Int) async {
        if let saved = snapshots[snapshotId] { savedText = saved }
    }

    func replaceText(docId: Int, text: String) {
        self.text = text
        savedText = text
        replaced.append(text)
    }

    func text(docId: Int) async -> String? {
        text
    }

    func applyText(docId: Int, text: String) {
        self.text = text
    }
}

@Suite struct DocumentSavingTests {
    private func makeDocument(_ contents: String) throws -> (OpenDocument, FakeEditor, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        try Data(contents.utf8).write(to: url)
        let document = try OpenDocument(id: 1, url: url, kind: .markdown)
        let editor = FakeEditor(text: document.content.text)
        document.editor = editor
        return (document, editor, url)
    }

    @Test func savesOnlyWhenDirty() async throws {
        let (document, editor, url) = try makeDocument("# A\r\n")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await document.save() == .notNeeded)
        editor.text = "# A\r\nmore\r\n"
        document.isDirty = true
        #expect(await document.save() == .saved)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# A\r\nmore\r\n")
    }

    @Test func restoresUnsavedTextAfterEditorRestart() async throws {
        let (document, editor, url) = try makeDocument("saved\n")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(EditorHost.loadArguments(for: document, rootURL: nil, anchor: nil)["current"] is NSNull)
        editor.text = "saved\nunsaved\n"
        document.isDirty = true
        document.unsavedText = editor.text
        var args = EditorHost.loadArguments(for: document, rootURL: nil, anchor: nil)
        #expect(args["text"] as? String == "saved\n")
        #expect(args["current"] as? String == "saved\nunsaved\n")

        // Saving refreshes the baseline, so a later restart doesn't bring back an old load.
        #expect(await document.save() == .saved)
        document.isDirty = false
        args = EditorHost.loadArguments(for: document, rootURL: nil, anchor: nil)
        #expect(args["text"] as? String == "saved\nunsaved\n")
        #expect(args["current"] is NSNull)
        #expect(document.unsavedText == nil)
    }

    @Test func keepsNewerUnsavedTextReportedDuringSave() async throws {
        let (document, editor, url) = try makeDocument("a\n")
        defer { try? FileManager.default.removeItem(at: url) }

        editor.text = "b\n"
        document.isDirty = true
        document.unsavedText = "c\n"
        #expect(await document.save() == .saved)
        #expect(document.recoveryText == "c\n")
    }

    @Test func refusesToOverwriteExternalChanges() async throws {
        let (document, editor, url) = try makeDocument("original\n")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("from another app\n".utf8).write(to: url)
        editor.text = "mine\n"
        document.isDirty = true
        #expect(await document.save() == .conflict)
        #expect(document.diskState == .changedOnDisk)
        #expect(try String(contentsOf: url, encoding: .utf8) == "from another app\n")

        #expect(await document.save(overwritingExternalChanges: true) == .saved)
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine\n")
    }

    @Test func ownSaveIsNotTreatedAsExternalChange() async throws {
        let (document, editor, url) = try makeDocument("a\n")
        defer { try? FileManager.default.removeItem(at: url) }

        editor.text = "b\n"
        document.isDirty = true
        _ = await document.save()
        document.isDirty = false
        document.diskDidChange()
        #expect(document.diskState == .inSync)
        #expect(editor.replaced.isEmpty)
    }

    @Test func reloadsCleanDocumentOnExternalChange() async throws {
        let (document, editor, url) = try makeDocument("a\n")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("changed\n".utf8).write(to: url)
        document.diskDidChange()
        #expect(editor.replaced == ["changed\n"])
        #expect(document.diskState == .inSync)
    }

    @Test func dirtyDocumentGetsConflictInsteadOfReload() async throws {
        let (document, editor, url) = try makeDocument("a\n")
        defer { try? FileManager.default.removeItem(at: url) }

        document.isDirty = true
        try Data("changed\n".utf8).write(to: url)
        document.diskDidChange()
        #expect(editor.replaced.isEmpty)
        #expect(document.diskState == .changedOnDisk)
    }
}

@Suite struct SearchModelTests {
    @Test func searchesLiveTextAndReplacesAcrossScopes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let openURL = root.appending(path: "open.md")
        let closedURL = root.appending(path: "closed.md")
        try Data("saved\n".utf8).write(to: openURL)
        try Data("needle on disk\n".utf8).write(to: closedURL)

        let document = try OpenDocument(id: 1, url: openURL, kind: .markdown)
        let editor = FakeEditor(text: "unsaved needle\n")
        document.editor = editor

        let model = SearchModel(root: root)
        model.currentDocument = { document }
        model.openDocuments = { [document] }
        model.options.query = "needle"

        model.scope = .currentFile
        await model.search()
        #expect(model.hitCount == 1)

        model.scope = .folder
        await model.search()
        #expect(model.hitCount == 2)

        model.replacement = "pin"
        await model.replaceAll()
        #expect(editor.text == "unsaved pin\n")
        #expect(try String(contentsOf: openURL, encoding: .utf8) == "saved\n")
        #expect(try String(contentsOf: closedURL, encoding: .utf8) == "pin on disk\n")
        #expect(model.hitCount == 0)
    }

    @Test func stepsThroughResultsWithOptionalWrap() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        try Data("a a\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try OpenDocument(id: 1, url: url, kind: .markdown)

        let model = SearchModel(root: nil)
        model.currentDocument = { document }
        model.options.query = "a"
        await model.search()
        var opened: [Int] = []
        model.onOpenHit = { opened.append($0.column) }

        model.wrap = false
        #expect(model.step(forward: true))
        #expect(model.step(forward: true))
        #expect(!model.step(forward: true))
        model.wrap = true
        #expect(model.step(forward: true))
        #expect(opened == [0, 2, 0])
    }
}

@Suite struct AutosaveTests {
    private func dirtyDocument() throws -> (OpenDocument, FakeEditor, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        try Data("a\n".utf8).write(to: url)
        let document = try OpenDocument(id: 1, url: url, kind: .markdown)
        let editor = FakeEditor(text: "a\n")
        document.editor = editor
        editor.text = "edited\n"
        document.isDirty = true
        return (document, editor, url)
    }

    @Test func savesOnFocusLossWhenEnabled() async throws {
        let (document, editor, url) = try dirtyDocument()
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = await AutosaveCoordinator(isEnabled: { true }).focusLost(document: document)
        #expect(outcome == .saved)
        #expect(try String(contentsOf: url, encoding: .utf8) == "edited\n")
        withExtendedLifetime(editor) {}
    }

    @Test func doesNothingWhenDisabled() async throws {
        let (document, editor, url) = try dirtyDocument()
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = await AutosaveCoordinator(isEnabled: { false }).focusLost(document: document)
        #expect(outcome == .notNeeded)
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\n")
        withExtendedLifetime(editor) {}
    }

    @Test func neverOverwritesPendingConflict() async throws {
        let (document, editor, url) = try dirtyDocument()
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("external\n".utf8).write(to: url)
        document.diskDidChange()
        let outcome = await AutosaveCoordinator(isEnabled: { true }).focusLost(document: document)
        #expect(outcome == .notNeeded)
        #expect(try String(contentsOf: url, encoding: .utf8) == "external\n")
        withExtendedLifetime(editor) {}
    }
}
