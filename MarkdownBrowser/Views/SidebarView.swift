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
                if workspace.isFolder {
                    FilterBar(workspace: workspace)
                }
                if workspace.isFolder, workspace.filter.isActive {
                    FilterResultsView(workspace: workspace)
                } else {
                    FileTreeView(workspace: workspace)
                }
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
                await workspace.activateFromSidebar(url, activation)
            }
        }
    }
}

extension Workspace {
    /// Opens a file chosen in the sidebar the way a click does: in the preview tab, pinned, or in a new tab.
    func activateFromSidebar(_ url: URL, _ activation: FileOutlineView.Activation) async {
        switch activation {
        case .open, .pin:
            if let delegate {
                await delegate.workspace(self, showFromSidebar: url, hit: nil, pin: activation == .pin)
            } else {
                await open(url)
            }
        case .openInNewTab:
            delegate?.workspace(self, openInNewTab: url, anchor: nil)
        }
    }

    /// Opens a filter result like a sidebar click. A folder can't be opened, so it's revealed in the tree instead.
    func activateFromFilter(_ result: FilterResult, _ activation: FileOutlineView.Activation) async {
        guard result.isDirectory else {
            await activateFromSidebar(result.url, activation)
            return
        }
        await open(result.url)
        pendingReveal = result.url
        filter.clear()
    }
}
