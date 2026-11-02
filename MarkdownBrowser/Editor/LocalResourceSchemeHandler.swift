import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled editor (`mdb-app://bundle/…`) and workspace files (`mdb-file://local/<path>`) to the web view.
final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let appScheme = "mdb-app"
    static let fileScheme = "mdb-file"
    static let fileHost = "local"
    static let editorURL = URL(string: "mdb-app://bundle/index.html")!

    private let webRoot: URL
    var isAllowed: (URL) -> Bool = { _ in false }
    var onDenied: (URL) -> Void = { _ in }

    init(webRoot: URL = Bundle.main.resourceURL!.appending(path: "Web", directoryHint: .isDirectory)) {
        self.webRoot = webRoot
    }

    static func schemeURL(for fileURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = fileScheme
        components.host = fileHost
        let path = fileURL.path(percentEncoded: false)
        components.path = fileURL.hasDirectoryPath && !path.hasSuffix("/") ? path + "/" : path
        return components.url!
    }

    static func fileURL(for schemeURL: URL) -> URL? {
        guard schemeURL.scheme == fileScheme, schemeURL.host() == fileHost else { return nil }
        return URL(fileURLWithPath: schemeURL.path(percentEncoded: false))
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        switch url.scheme {
        case Self.appScheme:
            serveBundleResource(url, task: task)
        case Self.fileScheme:
            serveFile(url, task: task)
        default:
            respond(task, url: url, status: 400)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func serveBundleResource(_ url: URL, task: any WKURLSchemeTask) {
        var relative = url.path(percentEncoded: false)
        while relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "index.html" }
        let target = webRoot.appending(path: relative)
        guard PathPolicy.isWithin(target, roots: [webRoot]), let data = try? Data(contentsOf: target) else {
            return respond(task, url: url, status: 404)
        }
        respond(task, url: url, status: 200, data: data, headers: ["Content-Type": Self.mimeType(for: target)])
    }

    private func serveFile(_ url: URL, task: any WKURLSchemeTask) {
        guard let fileURL = Self.fileURL(for: url) else { return respond(task, url: url, status: 400) }
        guard isAllowed(fileURL) else {
            onDenied(fileURL)
            return respond(task, url: url, status: 403)
        }
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
            let handle = try? FileHandle(forReadingFrom: fileURL)
        else { return respond(task, url: url, status: 404) }
        defer { try? handle.close() }

        var headers = [
            "Content-Type": Self.mimeType(for: fileURL),
            "Accept-Ranges": "bytes",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "sandbox",
        ]
        if let range = Self.byteRange(task.request.value(forHTTPHeaderField: "Range"), size: size) {
            try? handle.seek(toOffset: UInt64(range.lowerBound))
            let data = (try? handle.read(upToCount: range.count)) ?? Data()
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.lowerBound + data.count - 1)/\(size)"
            respond(task, url: url, status: 206, data: data, headers: headers)
        } else {
            respond(task, url: url, status: 200, data: (try? handle.readToEnd()) ?? Data(), headers: headers)
        }
    }

    private static let maxRangeLength = 8 << 20

    /// Parses a single `bytes=` range (as sent by media elements), capping open-ended ranges.
    static func byteRange(_ header: String?, size: Int) -> Range<Int>? {
        guard let header, header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: ",").first ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return nil }
        var start: Int
        var end: Int
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            start = max(size - suffix, 0)
            end = size - 1
        } else {
            guard let first = Int(parts[0]), first < size else { return nil }
            start = first
            end = parts[1].isEmpty ? min(first + maxRangeLength, size) - 1 : min(Int(parts[1]) ?? size - 1, size - 1)
        }
        guard end >= start else { return nil }
        return start..<(end + 1)
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "html": return "text/html; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    private func respond(
        _ task: any WKURLSchemeTask, url: URL, status: Int, data: Data = Data(), headers: [String: String] = [:]
    ) {
        var fields = headers
        fields["Content-Length"] = String(data.count)
        fields["Cache-Control"] = "no-store"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
