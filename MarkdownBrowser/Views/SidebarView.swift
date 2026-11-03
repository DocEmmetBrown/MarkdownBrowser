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
        if let tree = workspace.tree {
            FileOutlineView(
                tree: tree, selection: workspace.selection, expanded: workspace.expanded, workspace: workspace
            ) { url, activation in
                switch activation {
                case .open:
                    await workspace.open(url)
                case .openInNewTab:
                    workspace.delegate?.workspace(workspace, openInNewTab: url, anchor: nil)
                }
            }
        }
    }
}
