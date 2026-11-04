import AppKit
import SwiftUI

/// The filter field and its "Include subfolders" option, shown above the sidebar's file tree.
struct FilterBar: View {
    let workspace: Workspace

    var body: some View {
        let filter = workspace.filter
        VStack(alignment: .leading, spacing: 6) {
            FilterField(
                query: filter.query, focusRequested: filter.focusRequested, model: filter,
                onOpen: { newTab in open(newTab: newTab) },
                onEscapeWhenEmpty: { workspace.editor.focus() })
            HStack(spacing: 6) {
                Toggle(
                    "Include subfolders",
                    isOn: Binding(get: { filter.isRecursive }, set: { filter.setRecursive($0) })
                )
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Search all subfolders instead of only the folders shown in the tree")
                Spacer()
                if filter.isSearching { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func open(newTab: Bool) {
        guard let result = workspace.filter.selected else { return }
        Task { await workspace.activateFromFilter(result, newTab ? .openInNewTab : .open) }
    }
}

/// A search field with the keys a list filter needs: ↓/↑ move through the results, Return opens one, Escape clears.
private struct FilterField: NSViewRepresentable {
    let query: String
    let focusRequested: Bool
    let model: SidebarFilterModel
    let onOpen: (_ newTab: Bool) -> Void
    let onEscapeWhenEmpty: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Filter files"
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Filter files")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
        if focusRequested {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                model.focusRequested = false
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: SidebarFilterModel
        var parent: FilterField?

        init(model: SidebarFilterModel) {
            self.model = model
        }

        @objc func changed(_ sender: NSSearchField) {
            model.setQuery(sender.stringValue)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            model.setQuery(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                model.moveSelection(by: 1)
            case #selector(NSResponder.moveUp(_:)):
                model.moveSelection(by: -1)
            case #selector(NSResponder.insertNewline(_:)):
                parent?.onOpen(NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
            case #selector(NSResponder.cancelOperation(_:)):
                if model.query.isEmpty {
                    parent?.onEscapeWhenEmpty()
                } else {
                    model.clear()
                    control.stringValue = ""
                }
            default:
                return false
            }
            return true
        }
    }
}
