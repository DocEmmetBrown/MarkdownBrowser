import SwiftUI

/// Match-case, regex and wrap-around toggles shared by the find bar and the search panel.
struct SearchOptionToggles: View {
    @Binding var caseSensitive: Bool
    @Binding var regex: Bool
    @Binding var wrap: Bool

    var body: some View {
        HStack(spacing: 2) {
            Toggle(isOn: $caseSensitive) { Text("Aa") }
                .help("Match case")
            Toggle(isOn: $regex) { Text(".*").monospaced() }
                .help("Use regular expression")
            Toggle(isOn: $wrap) { Image(systemName: "repeat") }
                .help("Wrap around when reaching the end")
        }
        .toggleStyle(.button)
    }
}

struct FindBar: View {
    let workspace: Workspace
    @Bindable var model: FindBarModel
    @FocusState private var focusedField: Field?

    private enum Field {
        case find, replace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    model.showsReplace.toggle()
                } label: {
                    Image(systemName: model.showsReplace ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                .help(model.showsReplace ? "Hide replace" : "Show replace")

                TextField("Find", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .find)
                    .onSubmit {
                        if NSEvent.modifierFlags.contains(.shift) {
                            workspace.findPrevious()
                        } else {
                            workspace.findNext()
                        }
                        focusedField = .find
                    }

                SearchOptionToggles(caseSensitive: $model.caseSensitive, regex: $model.regex, wrap: $model.wrap)

                Text(model.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.status.isValid ? Color.secondary : Color.red)
                    .frame(minWidth: 90, alignment: .leading)

                ControlGroup {
                    Button { workspace.findPrevious() } label: { Image(systemName: "chevron.left") }
                        .help("Previous match (⇧⌘G)")
                    Button { workspace.findNext() } label: { Image(systemName: "chevron.right") }
                        .help("Next match (⌘G)")
                }
                .fixedSize()

                Button("All") { workspace.selectAllMatches() }
                    .help("Select all matches for multi-cursor editing")
                    .disabled(model.status.total == 0)

                Button {
                    workspace.hideFind()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close (Esc)")
            }

            if model.showsReplace {
                HStack(spacing: 6) {
                    Spacer().frame(width: 18)
                    TextField("Replace", text: $model.replacement)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .replace)
                        .onSubmit {
                            workspace.replaceCurrent()
                            focusedField = .replace
                        }
                    Button("Replace") { workspace.replaceCurrent() }
                        .disabled(model.status.total == 0)
                    Button("Replace All") { workspace.replaceAllInDocument() }
                        .disabled(model.status.total == 0)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand { workspace.hideFind() }
        .onAppear { focusedField = .find }
        .onChange(of: model.focusRequest) { focusedField = .find }
        .onChange(of: model.query) { workspace.pushFindQuery() }
        .onChange(of: model.replacement) { workspace.pushFindQuery() }
        .onChange(of: model.caseSensitive) { workspace.pushFindQuery() }
        .onChange(of: model.regex) { workspace.pushFindQuery() }
    }
}
