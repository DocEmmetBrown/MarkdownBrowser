import SwiftUI

struct DocumentArea: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if let document = workspace.document {
                DocumentBanners(document: document)
            }
            if workspace.usesNativeEditor, workspace.selectionKind == .markdown {
                Text("Native editor test mode: plain Markdown source; rich preview hasn't been migrated yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            if let denied = workspace.deniedResource {
                Banner(
                    systemImage: "lock",
                    message: "“\(denied.lastPathComponent)” can't be shown because MarkdownBrowser doesn't have access to its folder."
                ) {
                    Button("Grant Access…") {
                        Task {
                            if let folder = await workspace.delegate?.workspace(workspace, requestAccessTo: denied) {
                                workspace.grantAccess(to: folder)
                            }
                        }
                    }
                }
            }
            if let error = workspace.openError {
                Banner(systemImage: "exclamationmark.triangle", message: error) {
                    Button("Dismiss") { workspace.openError = nil }
                }
            }
            if workspace.find.isVisible, workspace.selectionKind.isTextual {
                FindBar(workspace: workspace, model: workspace.find)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let url = workspace.selection {
            switch workspace.selectionKind {
            case .markdown, .text:
                if let editor = workspace.editor as? EditorHost {
                    EditorWebView(host: editor)
                } else if let editor = workspace.editor as? NativeEditorHost {
                    NativeEditorView(host: editor)
                } else {
                    ContentUnavailableView("Editor Unavailable", systemImage: "exclamationmark.triangle")
                }
            case .image:
                ImageViewer(url: url)
            case .video:
                VideoViewer(url: url)
            case .other:
                QuickLookViewer(url: url)
            }
        } else {
            ContentUnavailableView(
                "No File Selected", systemImage: "doc.text",
                description: Text(workspace.isFolder ? "Choose a file in the sidebar." : ""))
        }
    }
}

private struct DocumentBanners: View {
    let document: OpenDocument

    var body: some View {
        switch document.diskState {
        case .changedOnDisk:
            Banner(
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                message: "“\(document.name)” was changed by another application."
            ) {
                Button("Reload") { document.reloadFromDisk() }
                Button("Keep My Version") { document.keepLocalVersion() }
            }
        case .deletedOnDisk:
            Banner(
                systemImage: "trash",
                message: "“\(document.name)” was deleted or moved. Saving will create it again.")
            {
                EmptyView()
            }
        case .inSync:
            EmptyView()
        }
        if let error = document.lastError {
            Banner(systemImage: "exclamationmark.triangle", message: "Couldn't save: \(error)") {
                Button("Dismiss") { document.lastError = nil }
            }
        }
    }
}

struct Banner<Actions: View>: View {
    let systemImage: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(2)
            Spacer()
            actions
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
