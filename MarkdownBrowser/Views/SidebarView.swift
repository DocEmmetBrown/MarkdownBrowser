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
            VStack(spacing: 0) {
                SidebarFolderBar(workspace: workspace)
                FileOutlineView(
                    tree: tree, selection: workspace.selection, expanded: workspace.expanded, workspace: workspace
                ) { url, activation in
                    await workspace.activateFromSidebar(url, activation)
                }
                // A new outline for each folder, so it starts at the top with fresh state.
                .id(tree.root.url)
            }
        }
    }
}

/// The folder the sidebar shows, with a button for its enclosing folder and a menu to jump to any ancestor.
private struct SidebarFolderBar: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 2) {
            Button {
                Task { await workspace.goUp() }
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(workspace.parentURL == nil)
            .help("Enclosing Folder (⌥⌘↑)")

            Menu {
                ForEach(workspace.ancestors, id: \.self) { folder in
                    Button(Self.name(of: folder)) { Task { await workspace.setRoot(folder) } }
                }
            } label: {
                Label(Self.name(of: workspace.rootURL), systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(workspace.ancestors.isEmpty ? .hidden : .visible)
            .disabled(workspace.ancestors.isEmpty)
            .help(workspace.rootURL.path(percentEncoded: false))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private static func name(of folder: URL) -> String {
        FileManager.default.displayName(atPath: folder.path(percentEncoded: false))
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

    /// Opens a filter result like a sidebar click. A double-clicked folder opens in the sidebar, as in the tree;
    /// otherwise a folder is revealed in the tree.
    func activateFromFilter(_ result: FilterResult, _ activation: FileOutlineView.Activation) async {
        guard result.isDirectory else {
            await activateFromSidebar(result.url, activation)
            return
        }
        if activation == .pin {
            guard await setRoot(result.url) else { return }
        } else {
            await open(result.url)
            pendingReveal = result.url
        }
        filter.clear()
    }
}
