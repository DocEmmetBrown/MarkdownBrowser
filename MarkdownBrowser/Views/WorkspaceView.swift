import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 440)
        } detail: {
            DocumentArea(workspace: workspace)
        }
        .navigationTitle(workspace.title)
        .navigationSubtitle(workspace.subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    Task { await workspace.goBack() }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Go back")
                .disabled(!workspace.canGoBack)

                Button {
                    Task { await workspace.goForward() }
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .help("Go forward")
                .disabled(!workspace.canGoForward)
            }

            ToolbarItem(placement: .primaryAction) {
                if let document = workspace.document, document.kind == .markdown {
                    Toggle(
                        isOn: Binding(get: { document.sourceMode }, set: { _ in workspace.toggleSourceMode() })
                    ) {
                        Label("Markdown Source", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .help("Show the Markdown source (⌘U)")
                }
            }
        }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { workspace.isSidebarVisible ? .all : .detailOnly },
            set: { workspace.isSidebarVisible = $0 != .detailOnly })
    }
}
