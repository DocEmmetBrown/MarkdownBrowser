import SwiftUI

@main
struct MarkdownBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Document windows are AppKit-managed (see WindowManager) for native tabs, close prompts and focus events.
        Settings {
            SettingsView()
        }
        .commands {
            AppCommands()
        }
    }
}
