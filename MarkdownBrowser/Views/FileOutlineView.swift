import AppKit
import SwiftUI

/// The sidebar file tree, backed by NSOutlineView so folders with tens of thousands of entries stay fast:
/// rows are created only when visible and folders are listed only when expanded.
struct FileOutlineView: NSViewRepresentable {
    enum Activation {
        case open
        case openInNewTab
    }

    let tree: FileTree
    let selection: URL?
    let expanded: Set<URL>
    let workspace: Workspace
    let onActivate: (URL, Activation) async -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(tree: tree)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.backgroundColor = .clear
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.clicked(_:))
        outline.onCommandClick = { [weak coordinator = context.coordinator] row in coordinator?.commandClicked(row) }
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.sync(expanded: expanded, selection: selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let tree: FileTree
        var parent: FileOutlineView?
        weak var outline: NSOutlineView?
        private var isSyncing = false
        private var shownSelection: URL?

        init(tree: FileTree) {
            self.tree = tree
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(childrenReloaded(_:)), name: FileNode.didReloadChildren, object: nil)
        }

        private func node(_ item: Any?) -> FileNode {
            (item as? FileNode) ?? tree.root
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            let node = node(item)
            node.loadChildrenIfNeeded()
            return node.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            node(item).children![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            node(item).isDirectory
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let node = node(item)
            let identifier = NSUserInterfaceItemIdentifier("FileCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier)
            cell.textField?.stringValue = node.name
            cell.imageView?.image = NSImage(systemSymbolName: Self.symbol(for: node), accessibilityDescription: nil)
            return cell
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSyncing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            parent?.workspace.setExpanded(node, true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            parent?.workspace.setExpanded(node, false)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let outline, outline.selectedRow >= 0,
                let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.isDirectory,
                node.url != parent?.selection
            else { return }
            shownSelection = node.url
            activate(node.url, .open)
        }

        /// Puts the selection back on the shown file if opening was cancelled (e.g. at an unsaved-changes prompt).
        private func activate(_ url: URL, _ activation: Activation) {
            guard let parent else { return }
            Task {
                await parent.onActivate(url, activation)
                applying { showSelection(parent.workspace.selection, force: true) }
            }
        }

        // MARK: Clicks

        @objc func clicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? FileNode, node.isDirectory else { return }
            // The disclosure triangle already toggled the folder.
            let point = sender.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil)
            if sender.frameOfOutlineCell(atRow: row).contains(point) { return }
            if sender.isItemExpanded(node) {
                sender.animator().collapseItem(node)
            } else {
                sender.animator().expandItem(node)
            }
        }

        func commandClicked(_ row: Int) {
            guard let outline, let node = outline.item(atRow: row) as? FileNode, !node.isDirectory else { return }
            activate(node.url, .openInNewTab)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode
            else { return }
            if !node.isDirectory {
                let open = menu.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTab(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = node.url
                menu.addItem(.separator())
            }
            let reveal = menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = node.url
        }

        @objc private func openInNewTab(_ item: NSMenuItem) {
            guard let url = item.representedObject as? URL else { return }
            activate(url, .openInNewTab)
        }

        @objc private func revealInFinder(_ item: NSMenuItem) {
            guard let url = item.representedObject as? URL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        // MARK: Syncing with the workspace

        func sync(expanded: Set<URL>, selection: URL?) {
            applying {
                expand(expanded)
                showSelection(selection, force: false)
            }
        }

        /// Runs changes to the outline without reporting them back to the workspace as user actions.
        private func applying(_ changes: () -> Void) {
            let wasSyncing = isSyncing
            isSyncing = true
            changes()
            isSyncing = wasSyncing
        }

        private func expand(_ expanded: Set<URL>) {
            guard let outline, let workspace = parent?.workspace else { return }
            // Parents before children, so each folder's row exists when it's expanded.
            for url in expanded.sorted(by: { $0.path.count < $1.path.count }) {
                if let node = workspace.node(for: url), !outline.isItemExpanded(node) { outline.expandItem(node) }
            }
        }

        private func showSelection(_ selection: URL?, force: Bool) {
            guard let outline, force || selection != shownSelection else { return }
            shownSelection = selection
            let row = selection.flatMap { parent?.workspace.node(for: $0) }.map { outline.row(forItem: $0) } ?? -1
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            } else {
                outline.deselectAll(nil)
            }
        }

        @objc private func childrenReloaded(_ notification: Notification) {
            guard let outline, let node = notification.object as? FileNode else { return }
            let item: FileNode? = node === tree.root ? nil : node
            // Collapsed or hidden folders are asked for their children again when expanded.
            guard item == nil || outline.row(forItem: item) >= 0 else { return }
            applying {
                outline.reloadItem(item, reloadChildren: true)
                if let parent { expand(parent.workspace.expanded) }
                showSelection(shownSelection, force: true)
            }
        }

        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            for view in [image, text] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private static func symbol(for node: FileNode) -> String {
            if node.isDirectory { return "folder" }
            switch node.kind {
            case .markdown: return "doc.richtext"
            case .text: return "doc.plaintext"
            case .image: return "photo"
            case .video: return "film"
            case .other: return "doc"
            }
        }
    }
}

/// Lets ⌘-click open a file in a new tab instead of toggling the row's selection.
private final class SidebarOutlineView: NSOutlineView {
    var onCommandClick: (Int) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let row = row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 { onCommandClick(row) }
            return
        }
        super.mouseDown(with: event)
    }
}
