import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppSettings.autosaveOnFocusLossKey) private var autosaveOnFocusLoss = true
    @AppStorage(AppSettings.wrapLongLinesKey) private var wrapLongLines = true
    @AppStorage(AppSettings.loadRemoteMediaKey) private var loadRemoteMedia = false

    var body: some View {
        Form {
            Section("Editing") {
                Toggle("Wrap long lines", isOn: $wrapLongLines)
                Text("Wraps lines longer than the window instead of scrolling sideways, in rendered Markdown, Markdown source and other text files. Also in Edit › Wrap Long Lines.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Saving") {
                Toggle("Save automatically when focus is lost", isOn: $autosaveOnFocusLoss)
                Text(
                    "Saves the open document when you switch to another window or app, open another file, close the window, or quit. When off, you're asked before unsaved changes are discarded."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section("Privacy") {
                Toggle("Load remote images and video", isOn: $loadRemoteMedia)
                Text("Fetches media that a document links to over the network. The site hosting it can see when you open the document, and from where. When off, only files on this Mac are shown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Command Line") {
                LabeledContent("mdb command") {
                    Button("Install…") { CommandLineToolInstaller.install() }
                }
                Text("Adds mdb to a folder on your PATH so “mdb .” opens the current folder from Terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppearanceMode.system
    @AppStorage(AppSettings.pageMarginsKey) private var pageMargins = PageMargins.none
    @AppStorage(AppSettings.limitPageWidthKey) private var limitPageWidth = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("Automatic follows the system setting. Applies to the app and rendered documents, including diagrams.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Page") {
                Picker("Margins", selection: $pageMargins) {
                    ForEach(PageMargins.allCases) { margins in
                        Text(margins.title).tag(margins)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Limit text width, like GitHub", isOn: $limitPageWidth)
                Text("Space around rendered Markdown. With the limit on and wrapping enabled, lines stop at 980 points and the page is centered.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appearance) { AppSettings.applyAppearance() }
    }
}
