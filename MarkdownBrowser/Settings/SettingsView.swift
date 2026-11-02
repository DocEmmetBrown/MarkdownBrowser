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

    var body: some View {
        Form {
            Section("Saving") {
                Toggle("Save automatically when focus is lost", isOn: $autosaveOnFocusLoss)
                Text(
                    "Saves the open document when you switch to another window or app, open another file, close the window, or quit. When off, you're asked before unsaved changes are discarded."
                )
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

    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appearance) { AppSettings.applyAppearance() }
    }
}
