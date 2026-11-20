import AppKit
import Observation

enum SearchScope: String, CaseIterable, Identifiable {
    case currentFile
    case openFiles
    case folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentFile: "File"
        case .openFiles: "Open Files"
        case .folder: "Folder"
        }
    }
}

/// Find / replace across the current file, all open files, or the workspace folder.
@Observable
final class SearchModel {
    var options = SearchOptions(query: "")
    var replacement = ""
    var wrap = true
    var scope: SearchScope
    private(set) var results: [SearchFileResult] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private(set) var summary: String?
    private(set) var currentHitID: SearchHit.ID?
    var focusRequest = 0

    private(set) var root: URL?
    var availableScopes: [SearchScope] { root == nil ? [.currentFile, .openFiles] : SearchScope.allCases }
    var hitCount: Int { results.reduce(0) { $0 + $1.hits.count } }
    var hits: [SearchHit] { results.flatMap(\.hits) }

    @ObservationIgnored var onOpenHit: (SearchHit) -> Void = { _ in }
    @ObservationIgnored var currentDocument: () -> OpenDocument? = { nil }
    @ObservationIgnored var openDocuments: () -> [OpenDocument] = { [] }
    @ObservationIgnored private var task: Task<Void, Never>?

    init(root: URL?) {
        self.root = root
        scope = root == nil ? .currentFile : .folder
    }

    /// Points folder searches at another folder; earlier results stay until the next search.
    func setRoot(_ url: URL) {
        guard root != nil else { return }
        root = url
    }

    func run() {
        task?.cancel()
        task = Task { await search() }
    }

    /// Like `run()`, but returns once the search has finished, so callers never see results from two runs.
    func runAndWait() async {
        task?.cancel()
        let current = Task { await search() }
        task = current
        await current.value
    }

    func cancel() {
        task?.cancel()
        isSearching = false
    }

    /// Copies another model's query and finished results, e.g. into a tab opened from a search result.
    func adopt(_ other: SearchModel) {
        options = other.options
        replacement = other.replacement
        wrap = other.wrap
        if availableScopes.contains(other.scope) { scope = other.scope }
        results = other.results
        currentHitID = other.currentHitID
        summary = other.summary
        errorMessage = other.errorMessage
    }

    func search() async {
        results = []
        errorMessage = nil
        summary = nil
        currentHitID = nil
        guard !options.query.isEmpty else {
            isSearching = false
            return
        }
        if let message = SearchEngine().validate(options) {
            errorMessage = SearchError.invalidPattern(message).localizedDescription
            isSearching = false
            return
        }
        isSearching = true
        let (sources, _) = await gatherSources()
        for await result in FolderSearch.run(sources: sources, options: options) {
            guard !Task.isCancelled else { return }
            results.append(result)
        }
        if !Task.isCancelled { isSearching = false }
    }

    /// Open documents are edited in their editor (undoable, left unsaved); other files are rewritten on disk.
    func replaceAll() async {
        task?.cancel()
        let engine = SearchEngine()
        guard !options.query.isEmpty, engine.validate(options) == nil else {
            isSearching = false
            return
        }
        isSearching = true
        let (sources, documents) = await gatherSources()
        var total = ReplaceSummary()
        var diskFiles: [URL] = []
        for source in sources {
            switch source {
            case .text(let url, let text, let separator):
                let (replaced, count) = FolderSearch.replace(
                    in: text, lineSeparator: separator, options: options, template: replacement, engine: engine)
                guard count > 0, let document = documents[url], let editor = document.editor else { continue }
                editor.applyText(docId: document.id, text: replaced)
                total.files += 1
                total.occurrences += count
            case .file(let url):
                diskFiles.append(url)
            }
        }
        let template = replacement
        let options = options
        let disk = await Task.detached(priority: .userInitiated) {
            FolderSearch.replaceInFiles(diskFiles, options: options, template: template)
        }.value
        total.files += disk.files
        total.occurrences += disk.occurrences
        total.failures += disk.failures

        await search()
        var message = "Replaced \(total.occurrences) occurrence\(total.occurrences == 1 ? "" : "s") in \(total.files) file\(total.files == 1 ? "" : "s")."
        if !total.failures.isEmpty { message += " Couldn't write: \(total.failures.joined(separator: ", "))." }
        summary = message
    }

    func open(_ hit: SearchHit) {
        currentHitID = hit.id
        onOpenHit(hit)
    }

    /// Steps through results across files; returns false at either end when wrapping is off.
    @discardableResult
    func step(forward: Bool) -> Bool {
        let hits = hits
        guard !hits.isEmpty else { return false }
        guard let currentHitID, let index = hits.firstIndex(where: { $0.id == currentHitID }) else {
            open(forward ? hits[0] : hits[hits.count - 1])
            return true
        }
        let next = index + (forward ? 1 : -1)
        if hits.indices.contains(next) {
            open(hits[next])
        } else if wrap {
            open(hits[(next + hits.count) % hits.count])
        } else {
            NSSound.beep()
            return false
        }
        return true
    }

    private func gatherSources() async -> ([SearchSource], [URL: OpenDocument]) {
        let documents: [OpenDocument]
        switch scope {
        case .currentFile: documents = currentDocument().map { [$0] } ?? []
        case .openFiles, .folder: documents = openDocuments()
        }

        var live: [URL: SearchSource] = [:]
        var byURL: [URL: OpenDocument] = [:]
        var order: [URL] = []
        for document in documents where document.kind.isTextual {
            let url = document.url.normalizedFileURL
            guard live[url] == nil else { continue }
            let text = await document.editor?.text(docId: document.id) ?? document.content.text
            live[url] = .text(url, text, lineSeparator: document.content.lineSeparator)
            byURL[url] = document
            order.append(url)
        }

        guard scope == .folder, let root else { return (order.compactMap { live[$0] }, byURL) }
        let files = await Task.detached(priority: .userInitiated) { FolderSearch.textFiles(under: root) }.value
        return (files.map { live[$0] ?? .file($0) }, byURL)
    }
}
