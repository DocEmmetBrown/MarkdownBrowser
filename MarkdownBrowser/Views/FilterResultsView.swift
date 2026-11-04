import AppKit
import SwiftUI

/// The sidebar while filtering: a flat list of matches, each with its name and folder.
struct FilterResultsView: View {
    let workspace: Workspace

    var body: some View {
        let filter = workspace.filter
        VStack(spacing: 0) {
            ZStack {
                FilterResultsTable(results: filter.results, selection: filter.selected?.url, filter: filter) { result, activation in
                    await workspace.activateFromFilter(result, activation)
                }
                if filter.results.isEmpty, !filter.isSearching {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                }
            }
            if filter.isTruncated {
                Text("Showing the best \(FileFilter.maxResults) matches. Type more to narrow them down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }
}

private struct FilterResultsTable: NSViewRepresentable {
    let results: [FilterResult]
    let selection: URL?
    let filter: SidebarFilterModel
    let onActivate: (FilterResult, FileOutlineView.Activation) async -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(filter: filter)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsTableView()
        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 36
        table.backgroundColor = .clear
        table.allowsMultipleSelection = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked(_:))
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onCommandClick = { [weak coordinator = context.coordinator] row in coordinator?.commandClicked(row) }
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.returnPressed() }
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(results: results, selection: selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let filter: SidebarFilterModel
        var parent: FilterResultsTable?
        weak var table: NSTableView?
        private var results: [FilterResult] = []
        private var isSyncing = false
        private var shownSelection: URL?

        init(filter: SidebarFilterModel) {
            self.filter = filter
        }

        func sync(results: [FilterResult], selection: URL?) {
            guard let table else { return }
            isSyncing = true
            defer { isSyncing = false }
            if results != self.results {
                self.results = results
                shownSelection = nil
                table.reloadData()
            }
            guard selection != shownSelection else { return }
            shownSelection = selection
            if let row = results.firstIndex(where: { $0.url == selection }) {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
            } else {
                table.deselectAll(nil)
            }
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            results.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let result = results[row]
            let identifier = NSUserInterfaceItemIdentifier("ResultCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultCell ?? ResultCell(identifier)
            cell.show(result)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let table, table.selectedRow >= 0, table.selectedRow < results.count else { return }
            let url = results[table.selectedRow].url
            shownSelection = url
            filter.choose(url)
        }

        // MARK: Activation

        private func activate(_ row: Int, _ activation: FileOutlineView.Activation) {
            guard let parent, row >= 0, row < results.count else { return }
            let result = results[row]
            filter.choose(result.url)
            Task { await parent.onActivate(result, activation) }
        }

        @objc func clicked(_ sender: NSTableView) {
            activate(sender.clickedRow, .open)
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            activate(sender.clickedRow, .pin)
        }

        func commandClicked(_ row: Int) {
            activate(row, .openInNewTab)
        }

        func returnPressed() {
            guard let table else { return }
            activate(table.selectedRow, .open)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, table.clickedRow < results.count else { return }
            let result = results[table.clickedRow]
            if !result.isDirectory {
                let open = menu.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTab(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = table.clickedRow
                menu.addItem(.separator())
            }
            let reveal = menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = result.url
        }

        @objc private func openInNewTab(_ item: NSMenuItem) {
            guard let row = item.representedObject as? Int else { return }
            activate(row, .openInNewTab)
        }

        @objc private func revealInFinder(_ item: NSMenuItem) {
            guard let url = item.representedObject as? URL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private final class ResultCell: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")

    init(_ identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let image = NSImageView()
        name.lineBreakMode = .byTruncatingMiddle
        folder.lineBreakMode = .byTruncatingHead
        folder.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        folder.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [name, folder])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for view in [image, stack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = image
        textField = name
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ result: FilterResult) {
        name.stringValue = result.name
        folder.stringValue = result.folder
        folder.isHidden = result.folder.isEmpty
        let kind = result.isDirectory ? FileKind.other : FileKind.of(result.url)
        imageView?.image = NSImage(
            systemSymbolName: FileOutlineView.Coordinator.symbol(isDirectory: result.isDirectory, kind: kind),
            accessibilityDescription: nil)
        toolTip = result.url.path(percentEncoded: false)
    }
}

/// Lets ⌘-click open a result in a new tab and Return open the selected one.
private final class ResultsTableView: NSTableView {
    var onCommandClick: (Int) -> Void = { _ in }
    var onReturn: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let row = row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 { onCommandClick(row) }
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn()
        } else {
            super.keyDown(with: event)
        }
    }
}
