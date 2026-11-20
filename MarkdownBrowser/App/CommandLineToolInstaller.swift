import AppKit
import os

/// Links the bundled `mdb` launcher into a folder the user picks; the sandbox only allows writing there.
enum CommandLineToolInstaller {
    nonisolated static let toolName = "mdb"

    nonisolated enum LinkError: Error, Equatable {
        case occupied
    }

    /// The launcher inside the app bundle, at the app's real location rather than a Gatekeeper translocation mount.
    static var bundledTool: URL? {
        tool(inBundleAt: originalBundleURL(Bundle.main.bundleURL))
    }

    nonisolated static func tool(inBundleAt bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/SharedSupport/bin/\(toolName)")
    }

    nonisolated static func isTranslocated(_ url: URL) -> Bool {
        url.path.contains("/AppTranslocation/")
    }

    /// An app launched from a quarantined spot (Downloads, a disk image) runs from a random read-only mount that
    /// disappears on relaunch, so a link into it would break. Ask the system for the real location.
    private static func originalBundleURL(_ url: URL) -> URL {
        guard isTranslocated(url) else { return url }
        typealias Resolve = @convention(c) (CFURL, UnsafeMutablePointer<Bool>?, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return url }
        let resolve = unsafeBitCast(symbol, to: Resolve.self)
        return resolve(url as CFURL, nil, nil)?.takeRetainedValue() as URL? ?? url
    }

    /// Asks once, on the first launch, whether to install the command.
    static func offerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppSettings.commandLineToolOfferedKey), !isRunningTests else { return }
        defaults.set(true, forKey: AppSettings.commandLineToolOfferedKey)

        let alert = NSAlert()
        alert.messageText = "Install the mdb command?"
        alert.informativeText =
            "Open files and folders from Terminal with “mdb .” or “mdb README.md”. You can do this later from the MarkdownBrowser menu or in Settings."
        alert.addButton(withTitle: "Install…")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { install() }
    }

    static func install() {
        guard let tool = bundledTool, FileManager.default.fileExists(atPath: tool.path) else {
            showAlert("The mdb command is missing from this copy of MarkdownBrowser.", detail: "Reinstall the app and try again.")
            return
        }
        guard !isTranslocated(tool) else {
            showAlert(
                "Move MarkdownBrowser to your Applications folder first.",
                detail: "macOS is running it from a temporary location. Move it to Applications, reopen it, then install the mdb command.")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Install Here"
        panel.message = "Choose a folder on your PATH for the mdb command, such as /usr/local/bin, /opt/homebrew/bin or ~/.local/bin."
        panel.directoryURL = ["/usr/local/bin", "/opt/homebrew/bin"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let link = directory.appendingPathComponent(toolName)
        do {
            do {
                try createLink(at: link, to: tool, replacingExisting: false)
            } catch LinkError.occupied {
                guard confirmReplace(link) else { return }
                try createLink(at: link, to: tool, replacingExisting: true)
            }
            showAlert("Installed the mdb command in \(directory.path).", detail: "Open a new Terminal window and run “mdb .” to try it.")
        } catch {
            Logger(subsystem: "MarkdownBrowser", category: "CLI").error("Install failed: \(error.localizedDescription, privacy: .public)")
            showManualInstall(directory: directory, tool: tool, error: error)
        }
    }

    /// Replaces an earlier link to any copy of the app's launcher without asking; anything else needs `replacingExisting`.
    nonisolated static func createLink(at link: URL, to tool: URL, replacingExisting: Bool) throws {
        let fileManager = FileManager.default
        if (try? fileManager.attributesOfItem(atPath: link.path)) != nil {
            guard replacingExisting || isLauncherLink(link) else { throw LinkError.occupied }
            try fileManager.removeItem(at: link)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: tool)
    }

    nonisolated static func isLauncherLink(_ url: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
        return destination.hasSuffix(".app/Contents/SharedSupport/bin/\(toolName)")
    }

    nonisolated static func manualCommand(directory: URL, tool: URL) -> String {
        let link = directory.appendingPathComponent(toolName)
        return "sudo mkdir -p \(shellQuoted(directory.path)) && sudo ln -sf \(shellQuoted(tool.path)) \(shellQuoted(link.path))"
    }

    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    private static func confirmReplace(_ link: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace the existing “\(toolName)” in \(link.deletingLastPathComponent().path)?"
        alert.informativeText = "It isn't a link to MarkdownBrowser's mdb command."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func showManualInstall(directory: URL, tool: URL, error: Error) {
        let command = manualCommand(directory: directory, tool: tool)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MarkdownBrowser can't write to \(directory.path)."
        alert.informativeText = "\(error.localizedDescription)\n\nChoose a folder you own, or run this command in Terminal:\n\n\(command)"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }

    private static func showAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
