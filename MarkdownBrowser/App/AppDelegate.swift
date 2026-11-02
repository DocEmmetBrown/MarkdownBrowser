import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        AppSettings.applyAppearance()
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if WindowManager.shared.controllers.isEmpty {
            WindowManager.shared.newWindow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Logger(subsystem: "MarkdownBrowser", category: "App").notice("Open request for \(urls.count) item(s)")
        for url in urls { WindowManager.shared.open(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.newWindow() }
        return true
    }

    func applicationWillResignActive(_ notification: Notification) {
        for controller in WindowManager.shared.controllers { controller.focusLost() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pending = WindowManager.shared.controllers.filter(\.hasUnsavedChanges)
        guard !pending.isEmpty else { return .terminateNow }
        Task {
            for controller in pending {
                controller.window?.makeKeyAndOrderFront(nil)
                guard await controller.confirmClose() else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
