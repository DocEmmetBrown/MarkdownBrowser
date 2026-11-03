import AppKit

final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [WorkspaceWindowController] = []

    /// Documents shown in any window or tab.
    var openDocuments: [OpenDocument] {
        controllers.compactMap { $0.workspace?.document }
    }

    func controller(showing url: URL) -> WorkspaceWindowController? {
        let url = url.normalizedFileURL
        return controllers.first { $0.workspace?.document?.url == url }
    }

    var activeController: WorkspaceWindowController? {
        for window in [NSApp.keyWindow, NSApp.mainWindow] {
            if let controller = window?.windowController as? WorkspaceWindowController { return controller }
        }
        return nil
    }

    @discardableResult
    func newWindow(tabbedWith parent: NSWindow? = nil) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController()
        controllers.append(controller)
        guard let window = controller.window else { return controller }
        if let parent {
            parent.addTabbedWindow(window, ordered: .above)
        } else {
            // "New Window" means a separate window even if the user prefers tabs.
            window.tabbingMode = .disallowed
            if let reference = controllers.dropLast().last?.window {
                window.setFrameTopLeftPoint(
                    window.cascadeTopLeft(from: NSPoint(x: reference.frame.minX, y: reference.frame.maxY)))
            } else {
                window.center()
            }
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.tabbingMode = .automatic
        return controller
    }

    func newTab() {
        newWindow(tabbedWith: activeController?.window)
    }

    /// Opens a file or folder, reusing a window already showing it, or an empty window, when possible.
    func open(_ url: URL, in preferred: WorkspaceWindowController? = nil) {
        let url = url.normalizedFileURL
        if let existing = controllers.first(where: { $0.workspace?.rootURL == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !isDirectory,
            let folderWindow = controllers.first(where: { $0.workspace?.isFolder == true && $0.workspace?.canAccess(url) == true })
        {
            folderWindow.window?.makeKeyAndOrderFront(nil)
            Task { await folderWindow.showFromSidebar(url, hit: nil, pin: false) }
            return
        }
        let target: WorkspaceWindowController
        if let candidate = preferred ?? activeController, candidate.workspace == nil {
            target = candidate
        } else {
            target = newWindow()
        }
        target.show(url)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a Markdown file or a folder to browse."
        panel.prompt = "Open"
        Task {
            guard await panel.begin() == .OK else { return }
            for url in panel.urls { open(url) }
        }
    }

    func openRecent(_ item: RecentItem) {
        guard let url = BookmarkStore.shared.resolve(item) else {
            let alert = NSAlert()
            alert.messageText = "“\(item.name)” is no longer available."
            alert.informativeText = "It may have been moved or deleted."
            alert.runModal()
            return
        }
        open(url)
    }

    func remove(_ controller: WorkspaceWindowController) {
        controllers.removeAll { $0 === controller }
    }
}
