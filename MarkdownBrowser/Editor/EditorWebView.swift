import SwiftUI
import WebKit

struct EditorWebView: NSViewRepresentable {
    let host: EditorHost

    func makeNSView(context: Context) -> WKWebView {
        host.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
