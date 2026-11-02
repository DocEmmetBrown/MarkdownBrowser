import AppKit
import Observation
import SwiftUI

@Observable
final class WindowState {
    var workspace: Workspace?
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

    func show(_ url: URL, selecting file: URL? = nil, anchor: String? = nil) {
        let workspace = Workspace(url: url)
        workspace.delegate = self
        state.workspace?.close()
        state.workspace = workspace
        BookmarkStore.shared.noteOpened(workspace.rootURL, isDirectory: workspace.isFolder)
        if let target = file ?? workspace.defaultSelection() {
            Task { await workspace.open(target, anchor: anchor, recordHistory: false) }
        }
    }

    private func observeWindowState() {
        withObservationTracking {
            window?.isDocumentEdited = state.workspace?.document?.isDirty ?? false
            window?.representedURL = state.workspace?.selection
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeWindowState() }
        }
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

    func toggleSourceMode() {
        workspace?.toggleSourceMode()
    }

    func findInFiles() {
        workspace?.showSearchInFiles()
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
        panel.message = "MarkdownBrowser needs permission to open “\(url.lastPathComponent)”. Choose a folder that contains it."
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
        controller.show(workspace.rootURL, selecting: url, anchor: anchor)
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
