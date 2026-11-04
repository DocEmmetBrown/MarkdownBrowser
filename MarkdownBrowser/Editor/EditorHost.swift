import Foundation
import WebKit
import os

/// Owns the window's web view running the CodeMirror editor and bridges messages in both directions.
final class EditorHost: NSObject, DocumentEditor {
    let webView: WKWebView
    let schemeHandler: LocalResourceSchemeHandler

    var onDirtyChange: (Int, Bool) -> Void = { _, _ in }
    var onUnsavedText: (Int, String) -> Void = { _, _ in }
    var onOpenLink: (Int, String, Bool) -> Void = { _, _, _ in }
    var onFindStatus: (Int, FindStatus) -> Void = { _, _ in }

    private var isReady = false
    private var pendingLoad: [String: Any]?
    private weak var loadedDocument: OpenDocument?
    private var loadedRootURL: URL?
    private var wrapsLines = AppSettings.wrapLongLines
    private let logger = Logger(subsystem: "MarkdownBrowser", category: "Editor")

    override init() {
        schemeHandler = LocalResourceSchemeHandler()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: LocalResourceSchemeHandler.appScheme)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: LocalResourceSchemeHandler.fileScheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        configuration.userContentController.add(ScriptMessageProxy(target: self), name: "bridge")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.allowsMagnification = true
        #if DEBUG
            webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: LocalResourceSchemeHandler.editorURL))
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    /// Applies the Wrap Long Lines setting, changed from the Edit menu or Settings, to the open document.
    @objc private func defaultsChanged() {
        let on = AppSettings.wrapLongLines
        guard on != wrapsLines else { return }
        wrapsLines = on
        pendingLoad?["wrapLines"] = on
        run("window.mdb.setLineWrapping(on)", ["on": on])
    }

    func load(_ document: OpenDocument, rootURL: URL?, anchor: String?) {
        loadedDocument = document
        loadedRootURL = rootURL
        let args = Self.loadArguments(for: document, rootURL: rootURL, anchor: anchor)
        if isReady {
            run("window.mdb.load(args)", ["args": args])
        } else {
            pendingLoad = args
        }
    }

    /// Built from the document's current state, so a reload after a crash gets the latest saved and unsaved text.
    static func loadArguments(for document: OpenDocument, rootURL: URL?, anchor: String?) -> [String: Any] {
        [
            "docId": document.id,
            "text": document.content.text,
            "current": document.recoveryText ?? NSNull(),
            "lineSeparator": document.content.lineSeparator,
            "kind": document.kind == .markdown ? "markdown" : "text",
            "fileName": document.name,
            "baseURL": LocalResourceSchemeHandler.schemeURL(for: document.url).absoluteString,
            "rootURL": rootURL.map { LocalResourceSchemeHandler.schemeURL(for: $0).absoluteString } ?? NSNull(),
            "sourceMode": document.sourceMode,
            "wrapLines": AppSettings.wrapLongLines,
            "anchor": anchor ?? NSNull(),
        ]
    }

    func setSourceMode(_ on: Bool) {
        run("window.mdb.setSourceMode(on)", ["on": on])
    }

    func scrollToAnchor(_ fragment: String) {
        run("window.mdb.scrollToAnchor(fragment)", ["fragment": fragment])
    }

    func reveal(docId: Int, line: Int, column: Int, length: Int) {
        run(
            "window.mdb.reveal(docId, line, column, length)",
            ["docId": docId, "line": line, "column": column, "length": length])
    }

    func refreshMedia() {
        run(
            "document.querySelectorAll('img, video').forEach(el => { const src = el.src; el.src = ''; el.src = src })",
            [:])
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
        run("window.mdb.focus()", [:])
    }

    // MARK: DocumentEditor

    func snapshot(docId: Int) async -> EditorSnapshot? {
        guard isReady else { return nil }
        let result = try? await webView.callAsyncJavaScript(
            "return window.mdb.snapshot(docId)", arguments: ["docId": docId], in: nil, contentWorld: .page)
        guard
            let dict = result as? [String: Any],
            let snapshotId = (dict["snapshotId"] as? NSNumber)?.intValue,
            let text = dict["text"] as? String,
            let dirty = dict["dirty"] as? Bool
        else { return nil }
        return EditorSnapshot(snapshotId: snapshotId, text: text, dirty: dirty)
    }

    func markSaved(docId: Int, snapshotId: Int) async {
        _ = try? await webView.callAsyncJavaScript(
            "window.mdb.markSaved(docId, snapshotId)", arguments: ["docId": docId, "snapshotId": snapshotId], in: nil,
            contentWorld: .page)
    }

    func replaceText(docId: Int, text: String) {
        run("window.mdb.replaceText(docId, text)", ["docId": docId, "text": text])
    }

    func text(docId: Int) async -> String? {
        guard isReady else { return nil }
        let result = try? await webView.callAsyncJavaScript(
            "return window.mdb.getText(docId)", arguments: ["docId": docId], in: nil, contentWorld: .page)
        return result as? String
    }

    func applyText(docId: Int, text: String) {
        run("window.mdb.applyText(docId, text)", ["docId": docId, "text": text])
    }

    // MARK: Find

    func setFindQuery(docId: Int, _ model: FindBarModel) {
        let options: [String: Any] = [
            "search": model.query, "replace": model.replacement, "caseSensitive": model.caseSensitive,
            "regexp": model.regex,
        ]
        run("window.mdb.find.setQuery(docId, options)", ["docId": docId, "options": options])
    }

    func findNext(docId: Int, wrap: Bool) {
        run("window.mdb.find.next(docId, wrap)", ["docId": docId, "wrap": wrap])
    }

    func findPrevious(docId: Int, wrap: Bool) {
        run("window.mdb.find.previous(docId, wrap)", ["docId": docId, "wrap": wrap])
    }

    func replaceCurrent(docId: Int, wrap: Bool) {
        run("window.mdb.find.replace(docId, wrap)", ["docId": docId, "wrap": wrap])
    }

    func replaceAll(docId: Int) {
        run("window.mdb.find.replaceAll(docId)", ["docId": docId])
    }

    func selectAllMatches(docId: Int) {
        run("window.mdb.find.selectAll(docId)", ["docId": docId])
        webView.window?.makeFirstResponder(webView)
    }

    func closeFind() {
        run("window.mdb.find.close()", [:])
    }

    // MARK: Bridge

    private func reloadArguments() -> [String: Any]? {
        loadedDocument.map { Self.loadArguments(for: $0, rootURL: loadedRootURL, anchor: nil) }
    }

    private func run(_ script: String, _ arguments: [String: Any]) {
        guard isReady else { return }
        Task {
            do {
                _ = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
            } catch {
                logger.error("JS call failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        let docId = (message["docId"] as? NSNumber)?.intValue ?? 0
        switch type {
        case "ready":
            isReady = true
            logger.notice("Editor ready")
            if let args = pendingLoad ?? reloadArguments() {
                pendingLoad = nil
                run("window.mdb.load(args)", ["args": args])
            }
        case "dirty":
            onDirtyChange(docId, message["dirty"] as? Bool ?? false)
        case "text":
            guard let text = message["text"] as? String else { return }
            onUnsavedText(docId, text)
        case "openLink":
            guard let href = message["href"] as? String else { return }
            onOpenLink(docId, href, message["newTab"] as? Bool ?? false)
        case "findStatus":
            let number = { (key: String) in (message[key] as? NSNumber)?.intValue ?? 0 }
            onFindStatus(
                docId,
                FindStatus(
                    current: number("current"), total: number("total"), isValid: message["valid"] as? Bool ?? true,
                    wrapped: message["wrapped"] as? Bool ?? false, atEnd: message["atEnd"] as? Bool ?? false))
        case "error":
            logger.error("Editor error: \(message["message"] as? String ?? "?", privacy: .public)")
        default:
            break
        }
    }
}

extension EditorHost: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let isEditorPage =
            navigationAction.request.url?.scheme == LocalResourceSchemeHandler.appScheme
            && navigationAction.targetFrame?.isMainFrame == true
        return (isEditorPage ? .allow : .cancel, preferences)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        pendingLoad = reloadArguments()
        let restored = loadedDocument?.recoveryText?.utf16.count ?? 0
        logger.error("Editor process terminated; reloading with \(restored) unsaved UTF-16 units restored")
        webView.load(URLRequest(url: LocalResourceSchemeHandler.editorURL))
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

/// Breaks the retain cycle between WKUserContentController and the host.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: EditorHost?

    init(target: EditorHost) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}
