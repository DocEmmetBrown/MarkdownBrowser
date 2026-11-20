import AppKit
import Testing

@testable import MarkdownBrowser

@Suite(.serialized) struct PreviewTabTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    private func tabButtons(in view: NSView) -> [NSView] {
        if String(describing: type(of: view)) == "NSTabButton" { return [view] }
        return view.subviews.flatMap(tabButtons(in:))
    }

    @Test func sidebarClicksReuseThePreviewTabLikeVSCode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        for name in ["README.md", "a.md", "b.md", "c.md", "docs/d.md"] {
            try Data("# \(name)\n".utf8).write(to: root.appending(path: name))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = { (name: String) in root.appending(path: name).normalizedFileURL }

        let suite = "PreviewTabTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let recents = BookmarkStore(defaults: defaults)
        let realRecents = WindowManager.shared.bookmarks
        WindowManager.shared.bookmarks = recents
        defer {
            WindowManager.shared.bookmarks = realRecents
            defaults.removePersistentDomain(forName: suite)
        }

        let first = WindowManager.shared.newWindow()
        defer { for controller in WindowManager.shared.controllers { controller.window?.close() } }
        first.show(root)
        #expect(recents.recents.first?.path == root.path)
        try await waitUntil { first.workspace?.selection == file("README.md") }
        #expect(first.state.isPreview)
        try await waitUntil { first.window?.tab.attributedTitle?.string == "README.md" }
        let attributes = first.window?.tab.attributedTitle?.attributes(at: 0, effectiveRange: nil)
        #expect(attributes?[.obliqueness] != nil)

        // A preview tab is replaced in place.
        await first.showFromSidebar(file("a.md"), hit: nil, pin: false)
        #expect(first.workspace?.selection == file("a.md"))
        #expect(first.window?.tabGroup?.windows.count ?? 1 == 1)

        // Once kept, the next click opens a new preview tab with the same sidebar.
        first.workspace?.setExpanded(try #require(first.workspace?.root?.child(named: "docs")), true)
        first.pin()
        await first.showFromSidebar(file("b.md"), hit: nil, pin: false)
        let tabs = try #require(first.window?.tabGroup?.windows)
        #expect(tabs.count == 2)
        let second = try #require(tabs.last?.windowController as? WorkspaceWindowController)
        try await waitUntil { second.workspace?.selection == file("b.md") }
        #expect(second.state.isPreview)
        #expect(second.workspace?.expanded == first.workspace?.expanded)
        #expect(second.workspace?.tree === first.workspace?.tree)

        // Clicks from the kept tab reuse that preview tab instead of adding more.
        await first.showFromSidebar(file("c.md"), hit: nil, pin: false)
        #expect(first.window?.tabGroup?.windows.count == 2)
        #expect(second.workspace?.selection == file("c.md"))
        #expect(first.workspace?.selection == file("a.md"))

        // Double-clicking the preview's tab keeps it. Only the selected tab's window shows the tab bar.
        let window = try #require(first.window?.tabGroup?.selectedWindow)
        try await waitUntil { window.tabGroup?.isTabBarVisible == true }
        window.layoutIfNeeded()
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let buttons = tabButtons(in: frame).sorted { $0.frame.minX < $1.frame.minX }
        try #require(buttons.count == 2, "found \(buttons.count) tab buttons")
        let center = buttons[1].convert(NSPoint(x: buttons[1].bounds.midX, y: buttons[1].bounds.midY), to: nil)
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        #expect(
            TabDoubleClickMonitor.tabController(at: click) === second,
            "window: \(String(describing: click.window)), frame: \(frame.frame), buttons: \(buttons.map(\.frame)), click: \(center), hit: \(String(describing: frame.hitTest(center)))")

        // A file that's already open just selects its tab.
        await second.showFromSidebar(file("a.md"), hit: nil, pin: false)
        #expect(first.window?.tabGroup?.selectedWindow === first.window)
        #expect(second.workspace?.selection == file("c.md"))

        // Double-clicking a file keeps the tab it opens in.
        await first.showFromSidebar(file("docs/d.md"), hit: nil, pin: true)
        #expect(second.workspace?.selection == file("docs/d.md"))
        #expect(!second.state.isPreview)

        // Editing a preview keeps it too.
        await second.showFromSidebar(file("README.md"), hit: nil, pin: false)
        let third = try #require(first.window?.tabGroup?.windows.last?.windowController as? WorkspaceWindowController)
        try await waitUntil { third.workspace?.document != nil }
        third.workspace?.document?.isDirty = true
        try await waitUntil { !third.state.isPreview }
        third.workspace?.document?.isDirty = false
    }
}
