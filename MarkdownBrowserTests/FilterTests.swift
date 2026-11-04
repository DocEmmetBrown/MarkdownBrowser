import Foundation
import Testing

@testable import MarkdownBrowser

@Suite struct FuzzyMatcherTests {
    private func score(_ query: String, _ candidate: String) -> Int? {
        FuzzyMatcher(query: query)?.score(candidate)
    }

    @Test func matchesSubsequencesInOrder() {
        #expect(score("rdm", "README.md") != nil)
        #expect(score("rdm", "mdr") == nil)
        #expect(score("xyz", "README.md") == nil)
        #expect(score("readmee", "README.md") == nil)
    }

    @Test func ignoresCase() {
        #expect(score("readme", "README.md") != nil)
        #expect(score("README", "readme.md") != nil)
        #expect(score("ÉCOLE", "école.txt") != nil)
        #expect(score("rm", "README.md") == score("RM", "readme.md"))
    }

    @Test func ignoresWhitespaceInTheQuery() {
        #expect(score(" r d m ", "README.md") == score("rdm", "README.md"))
        #expect(FuzzyMatcher(query: "") == nil)
        #expect(FuzzyMatcher(query: "  \t") == nil)
    }

    @Test func rankingPrefersTighterMatches() throws {
        let consecutive = try #require(score("abc", "abcdef"))
        let scattered = try #require(score("abc", "a-b-c"))
        #expect(consecutive > scattered)

        let exact = try #require(score("readme", "README.md"))
        let loose = try #require(score("readme", "already-me.md"))
        #expect(exact > loose)
    }

    @Test func rankingPrefersWordStarts() throws {
        let wordStarts = try #require(score("fb", "foo-bar.md"))
        let inside = try #require(score("fb", "fabulous.md"))
        #expect(wordStarts > inside)

        let camelCase = try #require(score("fb", "FooBar.swift"))
        let flat = try #require(score("fb", "foobar.swift"))
        #expect(camelCase > flat)
    }

    @Test func pathQueriesAreDetected() {
        #expect(FuzzyMatcher(query: "docs/rd")?.isPathQuery == true)
        #expect(FuzzyMatcher(query: "rd")?.isPathQuery == false)
    }

    @Test func staysFastOnLongNames() {
        let matcher = FuzzyMatcher(query: "abcdefghij")!
        let name = String(repeating: "abcdefghij-", count: 40)
        #expect(matcher.score(name) != nil)
    }
}

@Suite struct FileFilterTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let files = [
            "README.md", "readme-extra.txt", "notes.md", "docs/guide.md", "docs/deep/readme.md",
            "node_modules/readme.md", ".hidden/readme.md", ".secret-readme.md",
        ]
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# x\n".utf8).write(to: url)
        }
        return root
    }

    private func paths(_ update: FilterUpdate) -> [String] {
        update.results.map { $0.folder.isEmpty ? $0.name : "\($0.folder)/\($0.name)" }
    }

    @Test func nonRecursiveSearchesOnlyTheGivenFolders() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let top = await FileFilter.results(query: "readme", root: root, directories: [root], recursive: false)
        #expect(Set(paths(top)) == ["README.md", "readme-extra.txt"])
        #expect(top.isComplete)

        let docs = root.appending(path: "docs")
        let shown = await FileFilter.results(query: "readme", root: root, directories: [root, docs], recursive: false)
        #expect(Set(paths(shown)) == ["README.md", "readme-extra.txt"])

        let guide = await FileFilter.results(query: "guide", root: root, directories: [root], recursive: false)
        #expect(guide.results.isEmpty)
        let expanded = await FileFilter.results(query: "guide", root: root, directories: [root, docs], recursive: false)
        #expect(paths(expanded) == ["docs/guide.md"])
    }

    @Test func recursiveSearchWalksSubfoldersButSkipsHiddenAndIgnored() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let update = await FileFilter.results(query: "readme", root: root, directories: [], recursive: true)
        #expect(Set(paths(update)) == ["README.md", "readme-extra.txt", "docs/deep/readme.md"])
    }

    @Test func findsFoldersToo() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let update = await FileFilter.results(query: "dcs", root: root, directories: [], recursive: true)
        let docs = try #require(update.results.first { $0.name == "docs" })
        #expect(docs.isDirectory)
        #expect(docs.folder.isEmpty)
        #expect(update.results.first { $0.name == "guide.md" }?.isDirectory != true)
    }

    @Test func rankedBestFirst() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let update = await FileFilter.results(query: "readme", root: root, directories: [], recursive: true)
        #expect(update.results.first?.name.lowercased() == "readme.md")
        #expect(update.results.last?.name == "readme-extra.txt")
        #expect(update.results.map(\.score) == update.results.map(\.score).sorted(by: >))
    }

    @Test func pathQueriesMatchTheRelativePath() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let update = await FileFilter.results(query: "docs/rdm", root: root, directories: [], recursive: true)
        #expect(paths(update) == ["docs/deep/readme.md"])
        #expect(update.results.first?.folder == "docs/deep")
    }

    @Test func capsResults() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let total = FileFilter.maxResults + 100
        for index in 0..<total { try Data().write(to: root.appending(path: "file-\(index).txt")) }

        let update = await FileFilter.results(query: "file", root: root, directories: [], recursive: true)
        #expect(update.results.count == FileFilter.maxResults)
        #expect(update.matchCount == total)
        #expect(update.isTruncated)
    }

    @Test func cancellingStopsTheSearchWithoutAResult() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let task = Task { () -> [FilterUpdate] in
            var updates: [FilterUpdate] = []
            for await update in FileFilter.run(query: "readme", root: root, directories: [], recursive: true) {
                updates.append(update)
            }
            return updates
        }
        task.cancel()
        let updates = await task.value
        #expect(updates.allSatisfy { !$0.isComplete })
    }
}

@Suite struct SidebarFilterModelTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for file in ["README.md", "notes.md", "docs/readme-docs.md", "docs/deep/readme-deep.md"] {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# x\n".utf8).write(to: url)
        }
        return root
    }

    private func settle(_ model: SidebarFilterModel) async throws {
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<200 where model.isSearching { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func filtersAndClears() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SidebarFilterModel(root: root, debounce: .milliseconds(1))
        model.visibleDirectories = { [root] }

        #expect(!model.isActive)
        model.setQuery("rdm")
        #expect(model.isActive)
        try await settle(model)
        #expect(model.results.map(\.name) == ["README.md"])
        #expect(model.selected?.name == "README.md")

        model.clear()
        #expect(!model.isActive)
        #expect(model.results.isEmpty)
    }

    @Test func recursiveToggleWidensTheScope() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SidebarFilterModel(root: root, debounce: .milliseconds(1))
        model.visibleDirectories = { [root] }

        model.setQuery("readme")
        try await settle(model)
        #expect(model.results.count == 1)

        model.setRecursive(true)
        try await settle(model)
        #expect(Set(model.results.map(\.name)) == ["README.md", "readme-docs.md", "readme-deep.md"])

        model.setRecursive(false)
        try await settle(model)
        #expect(model.results.count == 1)
    }

    @Test func arrowKeysMoveTheSelectionWithinTheResults() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SidebarFilterModel(root: root, debounce: .milliseconds(1))
        model.visibleDirectories = { [root] }
        model.setRecursive(true)
        model.setQuery("readme")
        try await settle(model)
        let names = model.results.map(\.name)
        #expect(names.count == 3)

        #expect(model.selected?.name == names[0])
        model.moveSelection(by: 1)
        #expect(model.selected?.name == names[1])
        model.moveSelection(by: 10)
        #expect(model.selected?.name == names[2])
        model.moveSelection(by: -10)
        #expect(model.selected?.name == names[0])
    }

    @Test func workspaceReportsTheLevelsTheTreeShows() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(url: root)
        defer { workspace.close() }
        let tree = try #require(workspace.tree)
        let docs = try #require(tree.root.child(named: "docs"))
        #expect(workspace.visibleDirectories() == [tree.root.url])

        workspace.setExpanded(docs, true)
        #expect(workspace.visibleDirectories() == [tree.root.url, docs.url])

        // A folder that's expanded but hidden inside a collapsed one isn't shown.
        let deep = try #require(docs.child(named: "deep"))
        workspace.setExpanded(deep, true)
        workspace.setExpanded(docs, false)
        #expect(workspace.visibleDirectories() == [tree.root.url])
    }

    @Test func showFilterRevealsTheSidebarInFilesMode() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(url: root)
        defer { workspace.close() }
        workspace.sidebarMode = .search
        workspace.isSidebarVisible = false

        workspace.showFilter()
        #expect(workspace.sidebarMode == .files)
        #expect(workspace.isSidebarVisible)
        #expect(workspace.filter.focusRequested)
    }
}
