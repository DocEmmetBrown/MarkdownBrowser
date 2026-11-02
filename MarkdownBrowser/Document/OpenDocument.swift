import CryptoKit
import Foundation
import Observation

nonisolated struct EditorSnapshot: Sendable {
    let snapshotId: Int
    let text: String
    let dirty: Bool
}

/// The editor that holds a document's live text (the web editor in the app, a fake in tests).
protocol DocumentEditor: AnyObject {
    func snapshot(docId: Int) async -> EditorSnapshot?
    func markSaved(docId: Int, snapshotId: Int) async
    func replaceText(docId: Int, text: String)
    /// The live text, including unsaved edits.
    func text(docId: Int) async -> String?
    /// Applies a programmatic edit as an undoable change that leaves the document unsaved.
    func applyText(docId: Int, text: String)
}

enum SaveOutcome: Equatable {
    case saved
    case notNeeded
    case conflict
    case failed(String)
}

@Observable
final class OpenDocument: Identifiable {
    enum DiskState: Equatable {
        case inSync
        case changedOnDisk
        case deletedOnDisk
    }

    static let livePreviewSizeLimit = 5_000_000

    let id: Int
    let url: URL
    let kind: FileKind
    private(set) var content: DecodedText
    var isDirty = false
    var sourceMode: Bool
    private(set) var diskState: DiskState = .inSync
    var lastError: String?

    @ObservationIgnored weak var editor: DocumentEditor?
    @ObservationIgnored private var diskHash: Data
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var isSaving = false

    var name: String { url.lastPathComponent }

    init(id: Int, url: URL, kind: FileKind) throws {
        let data = try Data(contentsOf: url)
        self.id = id
        self.url = url
        self.kind = kind
        content = TextCodec.decode(data)
        diskHash = Self.hash(data)
        sourceMode = data.count > Self.livePreviewSizeLimit
    }

    func startWatching() {
        watcher?.stop()
        watcher = FileWatcher(url: url) { [weak self] in self?.diskDidChange() }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Writes the editor's current text. Refuses (returning `.conflict`) if the file changed on disk since it was
    /// loaded, unless `overwritingExternalChanges` is set.
    func save(overwritingExternalChanges: Bool = false) async -> SaveOutcome {
        guard !isSaving else { return .notNeeded }
        isSaving = true
        defer { isSaving = false }

        guard let editor, let snapshot = await editor.snapshot(docId: id) else {
            return .failed("The editor isn't ready.")
        }
        guard snapshot.dirty || overwritingExternalChanges || diskState == .deletedOnDisk else {
            isDirty = false
            return .notNeeded
        }
        let onDisk = try? Data(contentsOf: url)
        if !overwritingExternalChanges, let onDisk, Self.hash(onDisk) != diskHash {
            diskState = .changedOnDisk
            return .conflict
        }

        let (data, encoding) = TextCodec.encode(snapshot.text, as: content.encoding)
        do {
            try SafeFileWriter.write(data, to: url)
        } catch {
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
        diskHash = Self.hash(data)
        content = DecodedText(text: snapshot.text, encoding: encoding, lineSeparator: content.lineSeparator)
        diskState = .inSync
        lastError = nil
        await editor.markSaved(docId: id, snapshotId: snapshot.snapshotId)
        return .saved
    }

    /// Discards local edits and loads what's on disk.
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: url) else {
            diskState = .deletedOnDisk
            return
        }
        apply(diskData: data)
    }

    /// Keeps the editor's version; the next save overwrites the external change.
    func keepLocalVersion() {
        if let data = try? Data(contentsOf: url) { diskHash = Self.hash(data) }
        diskState = .inSync
    }

    func diskDidChange() {
        guard !isSaving else { return }
        guard let data = try? Data(contentsOf: url) else {
            diskState = .deletedOnDisk
            return
        }
        if Self.hash(data) == diskHash {
            diskState = .inSync
            return
        }
        if isDirty {
            diskState = .changedOnDisk
        } else {
            apply(diskData: data)
        }
    }

    private func apply(diskData data: Data) {
        let decoded = TextCodec.decode(data)
        diskHash = Self.hash(data)
        content = DecodedText(text: decoded.text, encoding: decoded.encoding, lineSeparator: content.lineSeparator)
        diskState = .inSync
        isDirty = false
        editor?.replaceText(docId: id, text: decoded.text)
    }

    private static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
