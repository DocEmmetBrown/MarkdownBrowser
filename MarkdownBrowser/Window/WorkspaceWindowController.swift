import AppKit
import Observation
import SwiftUI

@Observable
final class WindowState {
    var workspace: Workspace?
    /// A preview tab (italic title) is replaced by the next file opened from the sidebar, like in VS Code.
    var isPreview = false
}

/// AppKit-managed window (or tab) hosting SwiftUI content, so we control tabbing, close prompts and focus events.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let state = WindowState()
    private let autosave = AutosaveCoordinator()
    private var closeApproved = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingIdentifier = "MarkdownBrowser.workspace"
        window.isRestorable = false
        window.minSize = NSSize(width: 520, height: 360)
        super.init(window: window)
        window.delegate = self

        let hosting = NSHostingController(rootView: WindowRootView(state: state, actions: WindowActions(controller: self)))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1100, height: 760))
        observeWindowState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var workspace: Workspace? { state.workspace }

    var hasUnsavedChanges: Bool { workspace?.document?.isDirty ?? false }

    func show(
        _ url: URL, selecting file: URL? = nil, anchor: String? = nil, hit: SearchHit? = nil, preview: Bool = true,
        inheritingSidebarFrom source: Workspace? = nil
    ) {
        let workspace = Workspace(url: url)
        workspace.delegate = self
        if let source { workspace.inheritSidebar(from: source) }
        state.workspace?.close()
        state.workspace = workspace
        state.isPreview = preview && workspace.isFolder
        BookmarkStore.shared.noteOpened(workspace.rootURL, isDirectory: workspace.isFolder)
        if let target = file ?? workspace.defaultSelection() {
            Task { await workspace.open(target, anchor: anchor, hit: hit, recordHistory: false) }
        }
    }

    private func observeWindowState() {
        withObservationTracking {
            let document = state.workspace?.document
            window?.isDocumentEdited = document?.isDirty ?? false
            window?.representedURL = state.workspace?.selection
            // Editing a preview keeps it, as in VS Code.
            if document?.isDirty == true, state.isPreview { state.isPreview = false }
            updateTabTitle()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeWindowState() }
        }
    }

    /// Tabs show the file name (all tabs of a folder share the window title); previews are slanted.
    private func updateTabTitle() {
        guard let window else { return }
        guard let workspace = state.workspace, let selection = workspace.selection else {
            window.tab.attributedTitle = nil
            window.tab.toolTip = nil
            return
        }
        let attributes: [NSAttributedString.Key: Any] = state.isPreview ? [.obliqueness: 0.2] : [:]
        window.tab.attributedTitle = NSAttributedString(string: selection.lastPathComponent, attributes: attributes)
        let path = workspace.subtitle.isEmpty ? selection.lastPathComponent : workspace.subtitle
        window.tab.toolTip = state.isPreview ? "\(path) (preview)" : path
    }

    /// Keeps this tab: the next file opened from the sidebar goes to another tab.
    func pin() {
        state.isPreview = false
    }

    /// This window's tabs on the same folder, in tab-bar order.
    private var siblingTabs: [WorkspaceWindowController] {
        let windows = window?.tabGroup?.windows ?? window.map { [$0] } ?? []
        return windows.compactMap { $0.windowController as? WorkspaceWindowController }
            .filter { $0.workspace?.rootURL == workspace?.rootURL }
    }

    /// VS Code-style opening: show the tab that already has the file, else reuse the preview tab, else open a
    /// preview tab next to this one.
    func showFromSidebar(_ url: URL, hit: SearchHit?, pin: Bool) async {
        guard let workspace, let window else { return }
        let url = url.normalizedFileURL
        let tabs = siblingTabs
        if let existing = tabs.first(where: { $0.workspace?.selection == url }) {
            existing.select()
            if let hit { await existing.workspace?.open(url, hit: hit) }
            if pin { existing.pin() }
            return
        }
        if let preview = state.isPreview ? self : tabs.first(where: { $0.state.isPreview }) {
            preview.select()
            if await preview.workspace?.open(url, hit: hit) == true, pin { preview.pin() }
            return
        }
        let controller = WindowManager.shared.newWindow(tabbedWith: window)
        controller.show(
            workspace.rootURL, selecting: url, hit: hit, preview: !pin, inheritingSidebarFrom: workspace)
    }

    private func select() {
        guard let window, window.tabGroup?.selectedWindow !== window else { return }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Commands

    func save() {
        guard let document = workspace?.document else { return }
        Task {
            let outcome = await document.save()
            _ = await resolve(outcome, for: document, leaving: false)
        }
    }

    func goBack() {
        guard let workspace else { return }
        Task { await workspace.goBack() }
    }

    func goForward() {
        guard let workspace else { return }
        Task { await workspace.goForward() }
    }

    func goUp() {
        guard let workspace else { return }
        Task { await workspace.goUp() }
    }

    func toggleSourceMode() {
        workspace?.toggleSourceMode()
    }

    func findInFiles() {
        workspace?.showSearchInFiles()
    }

    func showFilter() {
        workspace?.showFilter()
    }

    func showFind(replace: Bool) {
        workspace?.showFind(replace: replace)
    }

    func findNext() {
        workspace?.findNext()
    }

    func findPrevious() {
        workspace?.findPrevious()
    }

    override func newWindowForTab(_ sender: Any?) {
        WindowManager.shared.newTab()
    }

    /// Saves or asks the user what to do with unsaved changes; false means the user cancelled.
    func confirmClose() async -> Bool {
        guard let workspace, let document = workspace.document, document.isDirty else { return true }
        return await self.workspace(workspace, shouldLeave: document)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved || !hasUnsavedChanges { return true }
        Task {
            if await confirmClose() {
                closeApproved = true
                window?.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        state.workspace?.close()
        WindowManager.shared.remove(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        focusLost()
    }

    func focusLost() {
        let document = workspace?.document
        Task { await autosave.focusLost(document: document) }
    }

    // MARK: Alerts

    private func runAlert(_ message: String, info: String, buttons: [String]) async -> Int {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        for title in buttons { alert.addButton(withTitle: title) }
        let response: NSApplication.ModalResponse
        if let window, window.isVisible, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// Handles a save outcome; returns true when it's fine to proceed (navigate away / close).
    private func resolve(_ outcome: SaveOutcome, for document: OpenDocument, leaving: Bool) async -> Bool {
        switch outcome {
        case .saved, .notNeeded:
            return true
        case .conflict:
            let discard = leaving ? "Discard My Changes" : "Reload From Disk"
            let choice = await runAlert(
                "“\(document.name)” was changed by another application.",
                info: "Do you want to replace those changes with your version?",
                buttons: ["Overwrite", discard, "Cancel"])
            switch choice {
            case 0:
                return await resolve(
                    await document.save(overwritingExternalChanges: true), for: document, leaving: leaving)
            case 1:
                if !leaving { document.reloadFromDisk() }
                return true
            default:
                return false
            }
        case .failed(let message):
            let choice = await runAlert(
                "“\(document.name)” couldn't be saved.", info: message,
                buttons: leaving ? ["Cancel", "Discard Changes"] : ["OK"])
            return leaving && choice == 1
        }
    }
}

extension WorkspaceWindowController: WorkspaceDelegate {
    func workspace(_ workspace: Workspace, shouldLeave document: OpenDocument) async -> Bool {
        if autosave.enabled {
            return await resolve(await document.save(), for: document, leaving: true)
        }
        let choice = await runAlert(
            "Do you want to save the changes you made to “\(document.name)”?",
            info: "Your changes will be lost if you don't save them.",
            buttons: ["Save", "Don't Save", "Cancel"])
        switch choice {
        case 0: return await resolve(await document.save(), for: document, leaving: true)
        case 1: return true
        default: return false
        }
    }

    func workspace(_ workspace: Workspace, requestAccessTo url: URL) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = "MarkdownBrowser needs permission to access “\(url.lastPathComponent)”. Choose a folder that contains it."
        panel.prompt = "Grant Access"
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let folder = panel.url, PathPolicy.isWithin(url, roots: [folder]) else { return nil }
        return folder
    }

    func workspace(_ workspace: Workspace, openInNewTab url: URL, anchor: String?) {
        let controller = WindowManager.shared.newWindow(tabbedWith: window)
        controller.show(
            workspace.rootURL, selecting: url, anchor: anchor, preview: false, inheritingSidebarFrom: workspace)
    }

    func workspace(_ workspace: Workspace, showFromSidebar url: URL, hit: SearchHit?, pin: Bool) async {
        await showFromSidebar(url, hit: hit, pin: pin)
    }
}

/// Double-clicking a tab keeps it (ends its preview), as in VS Code. AppKit has no API for clicks on tabs, so this
/// finds the tab button under the click.
enum TabDoubleClickMonitor {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, let controller = tabController(at: event) else { return event }
            controller.pin()
            return nil
        }
    }

    static func tabController(at event: NSEvent) -> WorkspaceWindowController? {
        guard let window = event.window, let frame = window.contentView?.superview,
            let windows = window.tabGroup?.windows, windows.count > 1
        else { return nil }
        let point = event.locationInWindow
        // The tab bar can take the hit itself (e.g. while its buttons settle), so buttons are matched by frame.
        var view = frame.hitTest(point)
        while let current = view, !isKind(current, "NSTabBar"), !isKind(current, "NSTabButton") {
            view = current.superview
        }
        guard let hit = view else { return nil }
        var bar = hit
        while let parent = bar.superview, !isKind(bar, "NSTabBar") { bar = parent }
        if !isKind(bar, "NSTabBar") { bar = hit.superview ?? hit }
        let buttons = tabButtons(in: bar).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        guard buttons.count == windows.count,
            let index = buttons.firstIndex(where: { $0.convert($0.bounds, to: nil).contains(point) })
        else { return nil }
        return windows[index].windowController as? WorkspaceWindowController
    }

    private static func isKind(_ view: NSView, _ name: String) -> Bool {
        String(describing: type(of: view)) == name
    }

    private static func tabButtons(in view: NSView) -> [NSView] {
        isKind(view, "NSTabButton") ? [view] : view.subviews.flatMap(tabButtons(in:))
    }
}

/// Window-scoped actions for SwiftUI views, holding the controller weakly to avoid a retain cycle.
struct WindowActions {
    weak var controller: WorkspaceWindowController?

    func open(_ url: URL) {
        guard let controller else { return }
        WindowManager.shared.open(url, in: controller)
    }

    func showOpenPanel() {
        WindowManager.shared.showOpenPanel()
    }

    func openRecent(_ item: RecentItem) {
        guard let url = BookmarkStore.shared.resolve(item) else { return }
        open(url)
    }
}
