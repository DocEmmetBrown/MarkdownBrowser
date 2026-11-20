import Foundation
import Testing

@testable import MarkdownBrowser

/// Holds the live text and tracks what was saved.
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

        let host = NativeEditorHost()
        host.load(document, rootURL: nil, anchor: nil)
        #expect(host.textView.string == "saved\n")
        editor.text = "saved\nunsaved\n"
        document.isDirty = true
        document.unsavedText = editor.text
        host.load(document, rootURL: nil, anchor: nil)
        #expect(host.textView.string == "saved\nunsaved\n")

        // Saving refreshes the baseline, so a later restart doesn't bring back an old load.
        #expect(await document.save() == .saved)
        document.isDirty = false
        host.load(document, rootURL: nil, anchor: nil)
        #expect(host.textView.string == "saved\nunsaved\n")
        #expect(await host.snapshot(docId: document.id)?.dirty == false)
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

    @Test func reloadAdoptsTheLineSeparatorOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        try Data("one\ntwo\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try OpenDocument(id: 1, url: url, kind: .markdown)
        let host = NativeEditorHost()
        document.editor = host
        host.load(document, rootURL: nil, anchor: nil)
        #expect(document.content.lineSeparator == "\n")

        try Data("one\r\ntwo\r\n".utf8).write(to: url)
        document.diskDidChange()
        #expect(document.content.lineSeparator == "\r\n")
        #expect(host.textView.string == "one\r\ntwo\r\n")

        let end = (host.textView.string as NSString).length
        host.textView.insertText("three\nfour", replacementRange: NSRange(location: end, length: 0))
        #expect(await host.text(docId: document.id) == "one\r\ntwo\r\nthree\r\nfour")
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

    private func folderModel(files: Int) throws -> (SearchModel, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<files { try Data("needle\n".utf8).write(to: root.appending(path: "\(index).md")) }
        let model = SearchModel(root: root)
        model.options.query = "needle"
        return (model, root)
    }

    private func waitUntilSearching(_ model: SearchModel) async {
        for _ in 0..<1000 where !model.isSearching { await Task.yield() }
    }

    @Test func invalidPatternStopsTheSpinnerOfARunningSearch() async throws {
        let (model, root) = try folderModel(files: 50)
        defer { try? FileManager.default.removeItem(at: root) }
        model.run()
        await waitUntilSearching(model)
        #expect(model.isSearching)

        model.options.regex = true
        model.options.query = "("
        await model.runAndWait()
        #expect(model.errorMessage != nil)
        #expect(!model.isSearching)
    }

    @Test func replaceAllSearchDoesNotDuplicateResultsOfARunningSearch() async throws {
        let (model, root) = try folderModel(files: 50)
        defer { try? FileManager.default.removeItem(at: root) }
        model.run()
        await waitUntilSearching(model)
        #expect(model.isSearching)

        await model.runAndWait()
        #expect(model.results.count == 50)
        #expect(Set(model.results.map(\.id)).count == 50)
        #expect(!model.isSearching)
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
