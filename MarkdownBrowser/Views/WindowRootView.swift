import SwiftUI

struct WindowRootView: View {
    let state: WindowState
    let actions: WindowActions

    var body: some View {
        if let workspace = state.workspace {
            WorkspaceView(workspace: workspace)
                .id(ObjectIdentifier(workspace))
        } else {
            WelcomeView(actions: actions)
                .navigationTitle("MarkdownBrowser")
        }
    }
}

struct WelcomeView: View {
    let actions: WindowActions
    private let store = BookmarkStore.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                Text("MarkdownBrowser")
                    .font(.largeTitle.weight(.semibold))
                Text("Open a Markdown file or a folder, or drop one here.")
                    .foregroundStyle(.secondary)
                Button("Open File or Folder…") { actions.showOpenPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !store.recents.isEmpty {
                Divider()
                List {
                    Section("Recent") {
                        ForEach(store.recents) { item in
                            Button {
                                actions.openRecent(item)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                        Text((item.path as NSString).abbreviatingWithTildeInPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                } icon: {
                                    Image(systemName: item.isDirectory ? "folder" : "doc.text")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 300)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { actions.open(url) }
            return !urls.isEmpty
        }
    }
}
