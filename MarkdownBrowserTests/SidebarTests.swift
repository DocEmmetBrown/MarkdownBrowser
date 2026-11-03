import AppKit
import SwiftUI
import Testing

@testable import MarkdownBrowser

@Suite struct SidebarOutlineTests {
    private func outline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { outline(in: $0) }.first
    }

    private func names(_ outline: NSOutlineView) -> [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.name }
    }

    @Test func showsTheTreeAndFollowsTheWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        for name in ["b.md", "A.md", "docs/guide.md"] { try Data("# x\n".utf8).write(to: root.appending(path: name)) }
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(url: root)
        defer { workspace.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: FileTreeView(workspace: workspace))
        window.layoutIfNeeded()
        let outline = try #require(outline(in: window.contentView!))
        #expect(names(outline) == ["A.md", "b.md", "docs"])

        await workspace.open(root.appending(path: "docs/guide.md"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(names(outline) == ["A.md", "b.md", "docs", "guide.md"])
        #expect((outline.item(atRow: outline.selectedRow) as? FileNode)?.name == "guide.md")

        try Data().write(to: root.appending(path: "a2.md"))
        workspace.root?.reloadChildren()
        #expect(names(outline) == ["A.md", "a2.md", "b.md", "docs", "guide.md"])
        #expect((outline.item(atRow: outline.selectedRow) as? FileNode)?.name == "guide.md")
    }

    @Test func expandsAFolderThatWasNeverListed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "docs/guide.md"))
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(url: root)
        defer { workspace.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: FileTreeView(workspace: workspace))
        window.layoutIfNeeded()
        let outline = try #require(outline(in: window.contentView!))
        let docs = try #require(outline.item(atRow: 0) as? FileNode)
        #expect(docs.children == nil)

        // Clicking the disclosure triangle lists the folder while NSOutlineView is mid-expansion.
        outline.expandItem(docs)
        #expect(names(outline) == ["docs", "guide.md"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(workspace.expanded == [docs.url])
    }
}
