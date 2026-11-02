import AppKit
import Observation

protocol WorkspaceDelegate: AnyObject {
    /// Called before navigating away from (or closing) a document with unsaved changes.
    func workspace(_ workspace: Workspace, shouldLeave document: OpenDocument) async -> Bool
    /// Asks the user to grant a folder that contains `url`; returns the granted folder.
    func workspace(_ workspace: Workspace, requestAccessTo url: URL) async -> URL?
    func workspace(_ workspace: Workspace, openInNewTab url: URL, anchor: String?)
}

enum SidebarMode: Hashable {
    case files
    case search
}

extension URL {
    /// File URL without a trailing slash, so files and folders compare consistently.
    nonisolated var normalizedFileURL: URL {
        URL(filePath: standardizedFileURL.path(percentEncoded: false), directoryHint: .notDirectory)
    }
}

/// One window's (or tab's) browsing session over a folder or a single file.
@Observable
final class Workspace {
    let rootURL: URL
    let isFolder: Bool
    let root: FileNode?
    let search: SearchModel
    let find = FindBarModel()

    private(set) var selection: URL?
    private(set) var selectionKind: FileKind = .other
    private(set) var document: OpenDocument?
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []
    var expanded: Set<URL> = []
    var sidebarMode: SidebarMode = .files
    var isSidebarVisible: Bool
    /// A resource the web view was denied access to; drives the "Grant Access…" banner.
    var deniedResource: URL?
    var openError: String?

    @ObservationIgnored let editor = EditorHost()
    @ObservationIgnored weak var delegate: WorkspaceDelegate?
    @ObservationIgnored private var scopes: [SecurityScope] = []
    @ObservationIgnored private var accessRoots: [URL] = []
    @ObservationIgnored private var folderWatcher: FolderWatcher?
    @ObservationIgnored private var nextDocumentId = 1
    @ObservationIgnored private let canonicalRootPath: String

    init(url: URL) {
        let url = url.normalizedFileURL
        rootURL = url
        scopes.append(SecurityScope(url: url))
        isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        canonicalRootPath = PathPolicy.canonical(url).path(percentEncoded: false)
        accessRoots = [url]
        for folder in BookmarkStore.shared.grantedFolders(containing: url) {
            scopes.append(SecurityScope(url: folder))
            accessRoots.append(folder)
        }

        if isFolder {
            let root = FileNode(url: url, isDirectory: true)
            root.reloadChildren()
            self.root = root
        } else {
            root = nil
        }
        search = SearchModel(root: isFolder ? url : nil)
        isSidebarVisible = isFolder
        sidebarMode = isFolder ? .files : .search

        configureEditor()
        configureSearch()
        if isFolder {
            folderWatcher = FolderWatcher(url: url) { [weak self] paths in self?.filesChanged(paths) }
        }
    }

    private func configureSearch() {
        search.currentDocument = { [weak self] in self?.document }
        search.openDocuments = { WindowManager.shared.openDocuments }
        search.onOpenHit = { [weak self] hit in
            guard let self else { return }
            Task { await self.reveal(hit) }
        }
    }

    private func configureEditor() {
        editor.schemeHandler.isAllowed = { [weak self] url in self?.canAccess(url) ?? false }
        editor.schemeHandler.onDenied = { [weak self] url in
            Task { @MainActor [weak self] in self?.deniedResource = url }
        }
        editor.onDirtyChange = { [weak self] docId, dirty in
            guard let document = self?.document, document.id == docId else { return }
            document.isDirty = dirty
        }
        editor.onOpenLink = { [weak self] docId, href, newTab in
            guard let self, self.document?.id == docId else { return }
            Task { await self.followLink(href, newTab: newTab) }
        }
        editor.onFindStatus = { [weak self] docId, status in
            guard let self, self.document?.id == docId else { return }
            self.find.apply(status)
            if status.atEnd { NSSound.beep() }
        }
    }

    var title: String { rootURL.lastPathComponent }

    var subtitle: String {
        guard isFolder, let selection else { return "" }
        let path = selection.path(percentEncoded: false)
        let rootPath = rootURL.path(percentEncoded: false)
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func canAccess(_ url: URL) -> Bool {
        PathPolicy.isWithin(url, roots: accessRoots)
    }

    /// The file to show when the workspace opens: the file itself, or a folder's README.
    func defaultSelection() -> URL? {
        guard isFolder else { return rootURL }
        let candidates = ["readme.md", "readme.markdown", "index.md", "readme", "readme.txt"]
        let files = root?.children?.filter { !$0.isDirectory } ?? []
        for name in candidates {
            if let match = files.first(where: { $0.name.lowercased() == name }) { return match.url }
        }
        return nil
    }

    // MARK: Navigation

    @discardableResult
    func open(_ url: URL, anchor: String? = nil, hit: SearchHit? = nil, recordHistory: Bool = true) async -> Bool {
        let url = url.normalizedFileURL
        if url == selection {
            if let anchor { editor.scrollToAnchor(anchor) }
            if let hit, let document {
                editor.reveal(docId: document.id, line: hit.line, column: hit.column, length: hit.length)
            }
            return true
        }

        if !canAccess(url) {
            guard let folder = await delegate?.workspace(self, requestAccessTo: url) else { return false }
            grantAccess(to: folder)
            guard canAccess(url) else { return false }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            openError = "“\(url.lastPathComponent)” couldn't be found."
            return false
        }
        if isDirectory.boolValue {
            revealInSidebar(url, expandingTarget: true)
            return false
        }

        if let current = document, current.isDirty {
            guard await delegate?.workspace(self, shouldLeave: current) ?? true else { return false }
        }

        let kind = FileKind.of(url)
        var newDocument: OpenDocument?
        if kind.isTextual {
            do {
                newDocument = try OpenDocument(id: nextDocumentId, url: url, kind: kind)
                nextDocumentId += 1
            } catch {
                openError = error.localizedDescription
                return false
            }
        }

        if recordHistory, let selection {
            backStack.append(selection)
            forwardStack.removeAll()
        }
        document?.stopWatching()
        document = newDocument
        selection = url
        selectionKind = kind
        openError = nil
        deniedResource = nil
        revealInSidebar(url, expandingTarget: false)

        if let newDocument {
            newDocument.editor = editor
            newDocument.startWatching()
            editor.load(newDocument, rootURL: isFolder ? rootURL : nil, anchor: anchor)
            if find.isVisible { pushFindQuery() }
            if let hit { editor.reveal(docId: newDocument.id, line: hit.line, column: hit.column, length: hit.length) }
        }
        return true
    }

    func goBack() async {
        guard let target = backStack.popLast() else { return }
        let current = selection
        if await open(target, recordHistory: false) {
            if let current { forwardStack.append(current) }
        } else {
            backStack.append(target)
        }
    }

    func goForward() async {
        guard let target = forwardStack.popLast() else { return }
        let current = selection
        if await open(target, recordHistory: false) {
            if let current { backStack.append(current) }
        } else {
            forwardStack.append(target)
        }
    }

    /// Follows a link clicked in the editor: web links go to the default browser, relative links open here.
    func followLink(_ href: String, newTab: Bool) async {
        guard let document else { return }
        if let url = URL(string: href), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https", "mailto":
                NSWorkspace.shared.open(url)
            case "file":
                await openLocal(url, anchor: url.fragment(percentEncoded: false), newTab: newTab)
            default:
                break
            }
            return
        }

        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        var path = String(parts.first ?? "")
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        path = path.removingPercentEncoding ?? path
        let fragment = parts.count > 1 ? String(parts[1]) : nil

        let target: URL
        if path.isEmpty {
            target = document.url
        } else if path.hasPrefix("/") {
            let base = isFolder ? rootURL : document.url.deletingLastPathComponent()
            target = base.appending(path: String(path.drop(while: { $0 == "/" })))
        } else {
            target = document.url.deletingLastPathComponent().appending(path: path)
        }
        await openLocal(target, anchor: fragment, newTab: newTab)
    }

    private func openLocal(_ url: URL, anchor: String?, newTab: Bool) async {
        let url = url.normalizedFileURL
        if newTab && url != selection {
            delegate?.workspace(self, openInNewTab: url, anchor: anchor)
        } else {
            await open(url, anchor: anchor)
        }
    }

    // MARK: Find

    private var findableDocument: OpenDocument? {
        selectionKind.isTextual ? document : nil
    }

    func showFind(replace: Bool) {
        guard findableDocument != nil else { return }
        find.isVisible = true
        if replace { find.showsReplace = true }
        find.focusRequest += 1
        pushFindQuery()
    }

    func hideFind() {
        find.isVisible = false
        editor.closeFind()
        editor.focus()
    }

    func pushFindQuery() {
        guard find.isVisible, let document = findableDocument else { return }
        editor.setFindQuery(docId: document.id, find)
    }

    func findNext() {
        guard let document = findableDocument else { return }
        guard find.isVisible, !find.query.isEmpty else { return showFind(replace: false) }
        editor.findNext(docId: document.id, wrap: find.wrap)
    }

    func findPrevious() {
        guard let document = findableDocument else { return }
        guard find.isVisible, !find.query.isEmpty else { return showFind(replace: false) }
        editor.findPrevious(docId: document.id, wrap: find.wrap)
    }

    func replaceCurrent() {
        guard let document = findableDocument, find.isVisible else { return }
        editor.replaceCurrent(docId: document.id, wrap: find.wrap)
    }

    func replaceAllInDocument() {
        guard let document = findableDocument, find.isVisible else { return }
        editor.replaceAll(docId: document.id)
    }

    func selectAllMatches() {
        guard let document = findableDocument, find.isVisible else { return }
        editor.selectAllMatches(docId: document.id)
    }

    func showSearchInFiles() {
        isSidebarVisible = true
        sidebarMode = .search
        if search.options.query.isEmpty, !find.query.isEmpty { search.options.query = find.query }
        search.focusRequest += 1
    }

    /// Opens a search hit here when this workspace can reach it, otherwise in the window that has it open.
    func reveal(_ hit: SearchHit) async {
        if canAccess(hit.url) {
            await open(hit.url, hit: hit)
        } else if let other = WindowManager.shared.controller(showing: hit.url), let workspace = other.workspace {
            other.window?.makeKeyAndOrderFront(nil)
            await workspace.open(hit.url, hit: hit)
        }
    }

    // MARK: Editing

    func toggleSourceMode() {
        guard let document, document.kind == .markdown else { return }
        document.sourceMode.toggle()
        editor.setSourceMode(document.sourceMode)
    }

    func grantAccess(to folder: URL) {
        scopes.append(SecurityScope(url: folder))
        accessRoots.append(folder)
        BookmarkStore.shared.addGrant(folder)
        deniedResource = nil
        editor.refreshMedia()
    }

    func close() {
        document?.stopWatching()
        folderWatcher?.stop()
        folderWatcher = nil
        search.cancel()
        scopes.forEach { $0.stop() }
        scopes.removeAll()
    }

    // MARK: Sidebar

    func isExpanded(_ node: FileNode) -> Bool {
        expanded.contains(node.url)
    }

    func setExpanded(_ node: FileNode, _ isExpanded: Bool) {
        if isExpanded {
            node.loadChildrenIfNeeded()
            expanded.insert(node.url)
        } else {
            expanded.remove(node.url)
        }
    }

    private func relativeComponents(of url: URL) -> [String]? {
        let path = PathPolicy.canonical(url).path(percentEncoded: false)
        return relativeComponents(ofPath: path)
    }

    private func relativeComponents(ofPath path: String) -> [String]? {
        if path == canonicalRootPath { return [] }
        guard path.hasPrefix(canonicalRootPath + "/") else { return nil }
        return path.dropFirst(canonicalRootPath.count + 1).split(separator: "/").map(String.init)
    }

    private func revealInSidebar(_ url: URL, expandingTarget: Bool) {
        guard let root, var components = relativeComponents(of: url) else { return }
        if !expandingTarget { components = components.dropLast() }
        var node = root
        for name in components {
            node.loadChildrenIfNeeded()
            guard let child = node.children?.first(where: { $0.name == name && $0.isDirectory }) else { return }
            setExpanded(child, true)
            node = child
        }
    }

    private func loadedNode(atPath path: String) -> FileNode? {
        guard let root, let components = relativeComponents(ofPath: path) else { return nil }
        var node = root
        for name in components {
            guard let child = node.children?.first(where: { $0.name == name }) else { return nil }
            node = child
        }
        return node
    }

    private func filesChanged(_ paths: [String]) {
        var directories = Set<String>()
        for path in paths {
            directories.insert(path)
            directories.insert((path as NSString).deletingLastPathComponent)
        }
        for directory in directories {
            guard let node = loadedNode(atPath: directory), node.isDirectory, node.children != nil else { continue }
            node.reloadChildren()
        }
    }
}
