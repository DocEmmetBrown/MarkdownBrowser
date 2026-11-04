import AppKit
import SwiftUI
import Testing

@testable import MarkdownBrowser

@MainActor
private final class AccessDenier: WorkspaceDelegate {
    private(set) var requested: [URL] = []

    func workspace(_ workspace: Workspace, shouldLeave document: OpenDocument) async -> Bool { true }
    func workspace(_ workspace: Workspace, requestAccessTo url: URL) async -> URL? {
        requested.append(url)
        return nil
    }
    func workspace(_ workspace: Workspace, openInNewTab url: URL, anchor: String?) {}
    func workspace(_ workspace: Workspace, showFromSidebar url: URL, hit: SearchHit?, pin: Bool) async {}
}

@Suite(.serialized) struct FolderNavigationTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "docs/deep"), withIntermediateDirectories: true)
        for name in ["README.md", "docs/guide.md", "docs/deep/note.md"] {
            try Data("# x\n".utf8).write(to: root.appending(path: name))
        }
        return root
    }

    private func names(_ node: FileNode?) -> [String] {
        node?.children?.map(\.name) ?? []
    }

    @Test func entersASubfolderAndGoesBackUp() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appending(path: "docs").normalizedFileURL

        let workspace = Workspace(url: root)
        defer { workspace.close() }
        #expect(workspace.search.root == root.normalizedFileURL)

        #expect(await workspace.setRoot(docs))
        #expect(workspace.rootURL == docs)
        #expect(workspace.title == "docs")
        #expect(workspace.search.root == docs)
        #expect(names(workspace.root) == ["deep", "guide.md"])
        #expect(workspace.parentURL == root.normalizedFileURL)

        await workspace.goUp()
        #expect(workspace.rootURL == root.normalizedFileURL)
        #expect(names(workspace.root) == ["docs", "README.md"])
        #expect(workspace.search.root == root.normalizedFileURL)
        // The folder we came from stays open.
        #expect(workspace.expanded.contains(docs))
    }

    @Test func doesNothingForTheCurrentRootOrAMissingFolder() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(url: root)
        defer { workspace.close() }
        #expect(await workspace.setRoot(root) == false)
        #expect(await workspace.setRoot(root.appending(path: "missing")) == false)
        #expect(workspace.openError != nil)
        // A file isn't a folder to enter.
        #expect(await workspace.setRoot(root.appending(path: "README.md")) == false)
        #expect(workspace.rootURL == root.normalizedFileURL)
    }

    @Test func askForAccessBeforeLeavingTheGrantedFolder() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appending(path: "docs").normalizedFileURL

        let workspace = Workspace(url: docs)
        defer { workspace.close() }
        let delegate = AccessDenier()
        workspace.delegate = delegate

        await workspace.goUp()
        #expect(delegate.requested == [root.normalizedFileURL])
        #expect(workspace.rootURL == docs)
    }

    @Test func singleFilesHaveNoEnclosingFolder() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(url: root.appending(path: "README.md"))
        defer { workspace.close() }
        #expect(workspace.parentURL == nil)
        #expect(workspace.ancestors.isEmpty)
        #expect(await workspace.setRoot(root) == false)
    }

    @Test func listsAncestorsNearestFirstUpToTheFileSystemRoot() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appending(path: "docs/deep").normalizedFileURL

        let workspace = Workspace(url: deep)
        defer { workspace.close() }
        let ancestors = workspace.ancestors
        #expect(Array(ancestors.prefix(2)) == [deep.deletingLastPathComponent().normalizedFileURL, root.normalizedFileURL])
        #expect(ancestors.last?.path == "/")
    }

    @Test func theSidebarShowsTheNewFolderAndKeepsTheOpenFileSelectedWhenInside() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appending(path: "docs").normalizedFileURL

        let workspace = Workspace(url: root)
        defer { workspace.close() }
        await workspace.open(docs.appending(path: "guide.md"))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: FileTreeView(workspace: workspace))
        window.layoutIfNeeded()
        func outline(in view: NSView) -> NSOutlineView? {
            (view as? NSOutlineView) ?? view.subviews.lazy.compactMap { outline(in: $0) }.first
        }
        func shown() -> [String] {
            guard let outline = outline(in: window.contentView!) else { return [] }
            return (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.name }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown().contains("README.md"))

        await workspace.setRoot(docs)
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        #expect(shown() == ["deep", "guide.md"])
        let current = try #require(outline(in: window.contentView!))
        #expect((current.item(atRow: current.selectedRow) as? FileNode)?.name == "guide.md")
    }
}
