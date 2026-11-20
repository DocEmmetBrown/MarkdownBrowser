import SwiftUI

struct SearchPanel: View {
    let workspace: Workspace
    @Bindable var model: SearchModel
    @FocusState private var fieldFocused: Bool
    @State private var confirmingReplace = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            results
        }
        .onChange(of: model.options.caseSensitive) { model.run() }
        .onChange(of: model.options.regex) { model.run() }
        .onChange(of: model.scope) { model.run() }
        .onChange(of: model.focusRequest) { fieldFocused = true }
        .onAppear { fieldFocused = true }
        .alert("Replace All", isPresented: $confirmingReplace) {
            Button("Replace All", role: .destructive) { Task { await model.replaceAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Scope", selection: $model.scope) {
                ForEach(model.availableScopes) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Find", text: $model.options.query)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { model.run() }

            TextField("Replace", text: $model.replacement)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 6) {
                SearchOptionToggles(
                    caseSensitive: $model.options.caseSensitive, regex: $model.options.regex, wrap: $model.wrap)
                Spacer()
                ControlGroup {
                    Button { model.step(forward: false) } label: { Image(systemName: "chevron.up") }
                        .help("Previous result")
                    Button { model.step(forward: true) } label: { Image(systemName: "chevron.down") }
                        .help("Next result")
                }
                .fixedSize()
                .disabled(model.results.isEmpty)
            }

            HStack(spacing: 6) {
                Button("Find All") { model.run() }
                    .disabled(model.options.query.isEmpty)
                Button("Replace All…") {
                    Task {
                        await model.runAndWait()
                        if model.hitCount > 0 { confirmingReplace = true }
                    }
                }
                .disabled(model.options.query.isEmpty)
                Spacer()
                if model.isSearching { ProgressView().controlSize(.small) }
            }

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let summary = model.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            } else if !model.results.isEmpty {
                Text(
                    "\(model.hitCount)\(model.hitCount >= FolderSearch.maxHits ? "+" : "") results in \(model.results.count) files"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var results: some View {
        List {
            ForEach(model.results) { file in
                Section {
                    ForEach(file.hits) { hit in
                        Button {
                            model.open(hit)
                        } label: {
                            SearchHitRow(hit: hit, isCurrent: hit.id == model.currentHitID)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(relativePath(file.url))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var confirmationMessage: String {
        let count = model.hitCount >= FolderSearch.maxHits ? "at least \(model.hitCount)" : "\(model.hitCount)"
        let files = model.results.count
        return
            "Replace \(count) occurrence\(model.hitCount == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")? Open files are edited and can be undone; other files are saved immediately and can't be undone."
    }

    private func relativePath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let components =
            workspace.isFolder
            ? PathPolicy.relativeComponents(of: path, under: workspace.rootURL.path(percentEncoded: false)) : nil
        if let components, !components.isEmpty { return components.joined(separator: "/") }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(hit.line)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
            Text(highlighted)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(isCurrent ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 4))
    }

    private var highlighted: AttributedString {
        var text = AttributedString(hit.preview)
        if let range = Range(hit.previewMatch, in: hit.preview), let match = Range(range, in: text) {
            text[match].backgroundColor = .yellow.opacity(0.35)
            text[match].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}
