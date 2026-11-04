import SwiftUI

struct AppCommands: Commands {
    @AppStorage(AppSettings.wrapLongLinesKey) private var wrapLongLines = true
    private var windows: WindowManager { .shared }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Install Command Line Tool…") { CommandLineToolInstaller.install() }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Window") { windows.newWindow() }
                .keyboardShortcut("n")
            Button("New Tab") { windows.newTab() }
                .keyboardShortcut("t")
            Divider()
            Button("Open…") { windows.showOpenPanel() }
                .keyboardShortcut("o")
            RecentItemsMenu()
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            Button("Save") { windows.activeController?.save() }
                .keyboardShortcut("s")
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Markdown Source") { windows.activeController?.toggleSourceMode() }
                .keyboardShortcut("u")
        }

        CommandGroup(before: .windowArrangement) {
            Button("Keep Tab Open") { windows.activeController?.pin() }
                .keyboardShortcut("k", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { windows.activeController?.showFind(replace: false) }
                    .keyboardShortcut("f")
                Button("Find and Replace…") { windows.activeController?.showFind(replace: true) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { windows.activeController?.findNext() }
                    .keyboardShortcut("g")
                Button("Find Previous") { windows.activeController?.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Find in Files…") { windows.activeController?.findInFiles() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            Divider()
            Toggle("Wrap Long Lines", isOn: $wrapLongLines)
        }

        CommandMenu("Go") {
            Button("Back") { windows.activeController?.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { windows.activeController?.goForward() }
                .keyboardShortcut("]")
            Divider()
            Button("Filter Files…") { windows.activeController?.showFilter() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}

private struct RecentItemsMenu: View {
    private let store = BookmarkStore.shared

    var body: some View {
        Menu("Open Recent") {
            ForEach(store.recents) { item in
                Button(item.name) { WindowManager.shared.openRecent(item) }
            }
            if !store.recents.isEmpty {
                Divider()
            }
            Button("Clear Menu") { store.clearRecents() }
                .disabled(store.recents.isEmpty)
        }
    }
}
