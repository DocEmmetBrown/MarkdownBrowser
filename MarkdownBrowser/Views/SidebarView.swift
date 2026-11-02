import SwiftUI

struct SidebarView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if workspace.isFolder {
                Picker("Sidebar", selection: $workspace.sidebarMode) {
                    Text("Files").tag(SidebarMode.files)
                    Text("Search").tag(SidebarMode.search)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            } else {
                Spacer().frame(height: 8)
            }

            switch workspace.sidebarMode {
            case .files:
                FileTreeView(workspace: workspace)
            case .search:
                SearchPanel(workspace: workspace, model: workspace.search)
            }
        }
    }
}

struct FileTreeView: View {
    let workspace: Workspace

    var body: some View {
        List(selection: selection) {
            if let root = workspace.root {
                FileTreeRows(nodes: root.children ?? [], workspace: workspace)
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<URL?> {
        Binding(
            get: { workspace.selection },
            set: { url in
                guard let url, url != workspace.selection else { return }
                if NSEvent.modifierFlags.contains(.command) {
                    workspace.delegate?.workspace(workspace, openInNewTab: url, anchor: nil)
                } else {
                    Task { await workspace.open(url) }
                }
            })
    }
}

private struct FileTreeRows: View {
    let nodes: [FileNode]
    let workspace: Workspace

    var body: some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { workspace.isExpanded(node) },
                        set: { workspace.setExpanded(node, $0) })
                ) {
                    FileTreeRows(nodes: node.children ?? [], workspace: workspace)
                } label: {
                    FileRow(node: node)
                        .contentShape(Rectangle())
                        .onTapGesture { workspace.setExpanded(node, !workspace.isExpanded(node)) }
                        .contextMenu { RowMenu(url: node.url, workspace: workspace, canOpen: false) }
                }
            } else {
                FileRow(node: node)
                    .tag(node.url)
                    .contextMenu { RowMenu(url: node.url, workspace: workspace, canOpen: true) }
            }
        }
    }
}

private struct FileRow: View {
    let node: FileNode

    var body: some View {
        Label(node.name, systemImage: icon)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var icon: String {
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

private struct RowMenu: View {
    let url: URL
    let workspace: Workspace
    let canOpen: Bool

    var body: some View {
        if canOpen {
            Button("Open in New Tab") { workspace.delegate?.workspace(workspace, openInNewTab: url, anchor: nil) }
            Divider()
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
