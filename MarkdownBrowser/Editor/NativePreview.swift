import AppKit
import AVKit
import ImageIO
import MdbCore
import Observation
import SwiftMath
import SwiftUI
import os

nonisolated struct NativeRenderTree: Sendable {
    let nodes: [RenderNode]
    let children: [[Int]]
    let roots: [Int]
    let source: String
    let sourceMaps: [Int: NativeRenderedSourceMap]
    let sourceRanges: [Int: NSRange]
    let failure: String?

    init(_ source: String, structure: [MarkdownNode] = []) {
        self.source = source
        let tasks = Dictionary(structure.filter { $0.kind == .task }.map { ($0.start, $0) }, uniquingKeysWith: { first, _ in first })
        let headings = Dictionary(structure.filter { $0.kind == .heading }.map { ($0.start, $0.destination) }, uniquingKeysWith: { first, _ in first })
        var records: [RenderNode]
        do {
            records = try renderMarkdown(text: source)
            failure = nil
        } catch {
            failure = error.localizedDescription
            records = []
            Logger(subsystem: "MarkdownBrowser", category: "NativePreview")
                .error("Preview failed: \(error.localizedDescription, privacy: .public)")
        }
        for index in records.indices {
            guard let start = records[index].attributes["source-start"].flatMap(UInt32.init) else { continue }
            if let task = tasks[start], records[index].tag == "li" {
                records[index].attributes["task-offset"] = task.detail
                records[index].attributes["task-checked"] = task.level == 1 ? "true" : "false"
            }
            if let heading = headings[start], records[index].tag.hasPrefix("h") {
                records[index].attributes["id"] = heading
            }
        }
        nodes = records
        var children = Array(repeating: [Int](), count: nodes.count)
        var roots: [Int] = []
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent {
                children[Int(parent)].append(index)
            } else {
                roots.append(index)
            }
        }
        self.children = children
        self.roots = roots
        var sourceChildren = Array(repeating: [Int](), count: structure.count)
        for (index, node) in structure.enumerated() {
            if let parent = node.parent { sourceChildren[Int(parent)].append(index) }
        }
        let byStart = Dictionary(grouping: structure.indices, by: { structure[$0].start })
        let kinds: [String: MarkdownKind] = [
            "p": .paragraph, "h1": .heading, "h2": .heading, "h3": .heading,
            "h4": .heading, "h5": .heading, "h6": .heading, "td": .tableCell, "th": .tableCell,
            "strong": .strong, "em": .emphasis, "del": .strike, "a": .link, "code": .code, "pre": .codeBlock,
            "img": .image, "span": .math, "hr": .rule,
        ]
        let sourceText = source as NSString
        var sourceMaps: [Int: NativeRenderedSourceMap] = [:]
        var sourceRanges: [Int: NSRange] = [:]
        for (index, node) in records.enumerated() {
            if let start = node.attributes["source-start"].flatMap(Int.init),
               let end = node.attributes["source-end"].flatMap(Int.init),
               start >= 0, end >= start, end <= sourceText.length {
                sourceRanges[index] = NSRange(location: start, length: end - start)
            }
            guard let kind = kinds[node.tag],
                  let start = node.attributes["source-start"].flatMap(UInt32.init),
                  let original = byStart[start]?.first(where: { structure[$0].kind == kind }) else { continue }
            sourceMaps[index] = NativeRenderedSourceMap.make(
                index: original, nodes: structure, children: sourceChildren, source: sourceText)
            sourceRanges[index] = structure[original].range
        }
        let containers: Set<String> = ["html", "body", "div", "section", "article", "table", "thead",
            "tbody", "tfoot", "tr", "ul", "ol", "li", "details", "blockquote", "pre"]
        for index in records.indices.reversed()
            where sourceMaps[index] == nil && sourceRanges[index] != nil && !containers.contains(records[index].tag) {
            if records[index].attributes["source-text"] == "true", let range = sourceRanges[index] {
                let text = children[index].map { records[$0].text }.joined()
                sourceMaps[index] = .aligned(text, range: range, source: sourceText)
            } else {
                var text = ""
                var offsets: [Int] = []
                var complete = true
                for child in children[index] {
                    if let part = sourceMaps[child], !part.text.isEmpty {
                        if !offsets.isEmpty { offsets.removeLast() }
                        text += part.text
                        offsets.append(contentsOf: part.offsets)
                    } else if records[child].tag == "#text", !records[child].text.isEmpty {
                        complete = false
                    }
                }
                if complete, !text.isEmpty {
                    sourceMaps[index] = NativeRenderedSourceMap(text: text, offsets: offsets)
                }
            }
        }
        self.sourceMaps = sourceMaps
        self.sourceRanges = sourceRanges
    }

    func text(_ index: Int) -> String {
        var output = ""
        var stack = [index]
        while let next = stack.popLast() {
            output += nodes[next].text
            stack.append(contentsOf: children[next].reversed())
        }
        return output
    }
}

@Observable
final class NativePreviewModel {
    var tree: NativeRenderTree?
    var notice: String?
    var isVisible = false
    var mediaRevision = 0
    var documentURL: URL?
    var rootURL: URL?
    var isAllowed: (URL) -> Bool = { _ in false }
    var onDenied: (URL) -> Void = { _ in }
    var openLink: (String, Bool) -> Void = { _, _ in }
    var toggleTask: (Int, String) -> Void = { _, _ in }
    var editBlock: (Int) -> Void = { _ in }
    var editText: (Int, Int, NSEvent) -> Void = { _, _, _ in }
    var editPosition: (Int, Int) -> Void = { _, _ in }
    var pageLayout = AppSettings.pageLayout
    let logger = Logger(subsystem: "MarkdownBrowser", category: "NativePreview")

    func resourceURL(_ href: String) throws -> URL {
        guard let documentURL else { throw PreviewError.resource("No document is open.") }
        let url: URL
        if let absolute = URL(string: href), let scheme = absolute.scheme?.lowercased() {
            guard ["file", "http", "https"].contains(scheme) else {
                throw PreviewError.resource("Unsupported resource scheme: \(scheme)")
            }
            url = absolute
        } else {
            let pathPart = href.prefix { $0 != "#" && $0 != "?" }
            let path = String(pathPart).removingPercentEncoding ?? String(pathPart)
            if path.hasPrefix("/") {
                url = (rootURL ?? documentURL.deletingLastPathComponent()).appending(path: String(path.dropFirst()))
            } else {
                url = documentURL.deletingLastPathComponent().appending(path: path)
            }
        }
        guard url.isFileURL else { return url }
        let canonical = PathPolicy.canonical(url)
        guard isAllowed(canonical) else {
            onDenied(canonical)
            throw PreviewError.resource("Access to \(url.lastPathComponent) has not been granted.")
        }
        return canonical
    }

    nonisolated static func imageData(_ url: URL) async throws -> Data {
        let limit = 16_000_000
        let data: Data
        if url.isFileURL {
            data = try await Task.detached {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? limit + 1) <= limit else {
                    throw PreviewError.resource("Image exceeds the 16 MB limit.")
                }
                return try Data(contentsOf: url)
            }.value
        } else {
            let request = URLRequest(url: url, timeoutInterval: 20)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw PreviewError.resource("Image request failed.")
            }
            var received = Data()
            for try await byte in bytes {
                guard received.count < limit else { throw PreviewError.resource("Image exceeds the 16 MB limit.") }
                received.append(byte)
            }
            data = received
        }
        guard data.count <= limit else { throw PreviewError.resource("Image exceeds the 16 MB limit.") }
        if ["svg", "svgz"].contains(url.pathExtension.lowercased()) || data.range(of: Data("<svg".utf8)) != nil {
            return try await Task.detached { try rasterizeSvg(source: data) }.value
        }
        return data
    }
}

enum PreviewError: LocalizedError {
    case resource(String)
    var errorDescription: String? {
        switch self { case .resource(let message): message }
    }
}

struct NativePreviewBlock: View {
    let tree: NativeRenderTree
    let index: Int
    let model: NativePreviewModel
    private var node: RenderNode { tree.nodes[index] }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .id(node.attributes["id"] ?? node.attributes["name"] ?? "block-\(index)")
            .contextMenu {
                Button("Edit Markdown Source") { model.editBlock(index) }
            }
            .accessibilityAction(named: Text("Edit Markdown Source")) { model.editBlock(index) }
    }

    @ViewBuilder private var content: some View {
        switch node.tag {
        case "div" where node.attributes["class"]?.contains("markdown-alert") == true:
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Color.accentColor).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) { blocks }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.06))
            .fixedSize(horizontal: false, vertical: true)
        case "html", "body", "div", "section", "article":
            LazyVStack(alignment: .leading, spacing: 12) { blocks }
        case "p", "h1", "h2", "h3", "h4", "h5", "h6", "summary":
            if containsMedia(index) {
                VStack(alignment: .leading, spacing: 8) { blocks }
            } else {
                inline(index)
                    .textSelection(.disabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case "hr":
            Divider()
                .onTapGesture { model.editBlock(index) }
        case "blockquote":
            HStack(alignment: .top) {
                Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) { blocks }
            }.fixedSize(horizontal: false, vertical: true)
        case "ul", "ol":
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(tree.children[index].filter { tree.nodes[$0].tag == "li" }.enumerated()), id: \.element) { offset, child in
                    HStack(alignment: .top, spacing: 8) {
                        if let task = tree.nodes[child].attributes["task-offset"].flatMap(Int.init) {
                            Toggle("Task", isOn: Binding(
                                get: { tree.nodes[child].attributes["task-checked"] == "true" },
                                set: { _ in model.toggleTask(task, tree.source) }))
                                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(tree.text(child))
                        } else {
                            Text(node.tag == "ol" ? "\(offset + (Int(node.attributes["start"] ?? "") ?? 1))." : "•")
                                .foregroundStyle(.secondary)
                        }
                        NativePreviewBlock(tree: tree, index: child, model: model)
                    }
                }
            }.padding(.leading, 8)
        case "li":
            VStack(alignment: .leading, spacing: 4) { blocks }
        case "pre":
            let child = tree.children[index].first { tree.nodes[$0].tag == "code" }
            let language = child.flatMap { tree.nodes[$0].attributes["class"] }?
                .replacingOccurrences(of: "language-", with: "") ?? ""
            if language == "mermaid" {
                NativeDiagramView(source: tree.text(index), model: model)
                    .onTapGesture { model.editBlock(index) }
            } else {
                NativeCodeView(tree: tree, index: index, language: language, model: model)
            }
        case "table":
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(rows(index), id: \.self) { row in
                        GridRow {
                            ForEach(tree.children[row].filter { ["td", "th"].contains(tree.nodes[$0].tag) }, id: \.self) { cell in
                                NativePreviewBlock(tree: tree, index: cell, model: model)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: alignment(cell))
                                    .background(tree.nodes[cell].tag == "th" ? Color.secondary.opacity(0.12) : .clear)
                                    .border(Color.secondary.opacity(0.3), width: 0.5)
                            }
                        }
                    }
                }
            }
        case "details":
            let summary = tree.children[index].first { tree.nodes[$0].tag == "summary" }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tree.children[index].filter { $0 != summary }, id: \.self) { child in
                        NativePreviewBlock(tree: tree, index: child, model: model)
                    }
                }
            } label: {
                if let summary { inline(summary) } else { Text("Details") }
            }
        case "img":
            NativeImageView(href: node.attributes["src"] ?? "", alt: node.attributes["alt"] ?? "", model: model)
                .onTapGesture { model.editBlock(index) }
        case "video":
            NativeVideoView(href: node.attributes["src"] ?? tree.children[index].compactMap { tree.nodes[$0].attributes["src"] }.first ?? "", model: model)
        case "a" where containsMedia(index):
            VStack(alignment: .leading) { blocks }
                .onTapGesture {
                    guard let href = node.attributes["href"], let url = URL(string: href) else {
                        model.logger.error("Invalid rendered media link.")
                        return
                    }
                    openURL(url)
                }
        case "#text":
            if !node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(node.text).textSelection(.disabled)
            }
        default:
            if containsMedia(index) {
                VStack(alignment: .leading, spacing: 8) { blocks }
            } else {
                inline(index).textSelection(.disabled)
            }
        }
    }

    @ViewBuilder private var blocks: some View {
        ForEach(tree.children[index], id: \.self) { child in
            NativePreviewBlock(tree: tree, index: child, model: model)
        }
    }

    private func rows(_ index: Int) -> [Int] {
        tree.children[index].flatMap {
            tree.nodes[$0].tag == "tr" ? [$0] : rows($0)
        }
    }

    private func containsMedia(_ index: Int) -> Bool {
        var stack = tree.children[index]
        while let child = stack.popLast() {
            if ["img", "video"].contains(tree.nodes[child].tag) { return true }
            stack.append(contentsOf: tree.children[child])
        }
        return false
    }

    private func alignment(_ index: Int) -> Alignment {
        switch tree.nodes[index].attributes["align"] {
        case "center": .center
        case "right": .trailing
        default: .leading
        }
    }

    private func inline(_ index: Int) -> some View {
        NativeInlineText(tree: tree, index: index, model: model, dark: colorScheme == .dark,
            wraps: !["td", "th"].contains(tree.nodes[index].tag))
    }
}

private struct NativeInlineText: NSViewRepresentable {
    let tree: NativeRenderTree
    let index: Int
    let model: NativePreviewModel
    let dark: Bool
    var highlighted: NSAttributedString?
    var wraps = true
    @Environment(\.openURL) private var openURL

    func makeNSView(context: Context) -> NativeInlineTextView {
        let view = NativeInlineTextView()
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Edit Markdown Source", handler: { [weak view] in
                view?.accessibilityPerformPress() ?? false
            }),
        ])
        return view
    }

    func updateNSView(_ view: NativeInlineTextView, context: Context) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.textColor,
        ]
        let node = tree.nodes[index]
        switch node.tag {
        case "h1": attributes[.font] = NSFont.systemFont(ofSize: 28, weight: .semibold)
        case "h2": attributes[.font] = NSFont.systemFont(ofSize: 24, weight: .semibold)
        case "h3": attributes[.font] = NSFont.systemFont(ofSize: 20, weight: .semibold)
        case "h4", "h5", "h6", "th": attributes[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold)
        default: break
        }
        if node.attributes["class"]?.contains("markdown-alert-title") == true {
            attributes[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold)
        }
        if ["td", "th"].contains(node.tag) {
            let paragraph = NSMutableParagraphStyle()
            switch node.attributes["align"] {
            case "center": paragraph.alignment = .center
            case "right": paragraph.alignment = .right
            default: paragraph.alignment = .left
            }
            attributes[.paragraphStyle] = paragraph
        }
        let text = highlighted ?? attributed(index, attributes: attributes)
        if view.attributedString() != text { view.textStorage?.setAttributedString(text) }
        view.activateLink = { openURL($0) }
        let sourceMap = tree.sourceMaps[index]
        view.edit = { position, event in
            if let sourceMap, sourceMap.text == text.string, position < sourceMap.offsets.count {
                model.editText(index, sourceMap.offsets[position], event)
            } else {
                model.editBlock(index)
            }
        }
        view.editSource = { position in
            if let sourceMap, sourceMap.text == text.string, position < sourceMap.offsets.count {
                model.editPosition(index, sourceMap.offsets[position])
            } else {
                model.editBlock(index)
            }
        }
        view.setAccessibilityLabel(tree.text(index))
        view.setAccessibilityIdentifier("markdown-inline-\(index)")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeInlineTextView, context: Context) -> NSSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let proposedWidth = wraps ? proposal.width : nil
        let width = proposedWidth.map { max(1, $0) } ?? CGFloat.greatestFiniteMagnitude
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return NSSize(width: proposedWidth == nil ? max(1, ceil(used.width)) : width,
            height: max(1, ceil(used.height)))
    }

    private func attributed(_ index: Int, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let node = tree.nodes[index]
        var attributes = attributes
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 15)
        switch node.tag {
        case "#text": return NSAttributedString(string: node.text, attributes: attributes)
        case "br": return NSAttributedString(string: "\n", attributes: attributes)
        case "strong", "b": attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        case "em", "i": attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        case "del", "s", "strike": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case "code", "kbd": attributes[.font] = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        case "sup", "sub":
            attributes[.font] = NSFont.systemFont(ofSize: 11)
            attributes[.baselineOffset] = node.tag == "sup" ? 5 : -3
        case "a":
            attributes[.link] = node.attributes["href"].flatMap(URL.init(string:))
            attributes[.foregroundColor] = NSColor.controlAccentColor
        case "img":
            return NSAttributedString(string: "[\(node.attributes["alt"] ?? "Image")]", attributes: attributes)
        case "span" where node.attributes["data-math-style"] != nil:
            let latex = tree.text(index)
            do {
                let image = try NativeMath.image(latex,
                    display: node.attributes["data-math-style"] == "display", dark: dark)
                let attachment = NSTextAttachment()
                attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
                return NSAttributedString(attachment: attachment)
            } catch {
                model.logger.error("Math render failed: \(error.localizedDescription, privacy: .public)")
                return NSAttributedString(string: "$\(latex)$", attributes: attributes)
            }
        default: break
        }
        let result = NSMutableAttributedString()
        for child in tree.children[index] { result.append(attributed(child, attributes: attributes)) }
        return result
    }
}

final class NativeInlineTextView: NSTextView {
    var activateLink: (URL) -> Void = { _ in }
    var edit: (Int, NSEvent) -> Void = { _, _ in }
    var editSource: (Int) -> Void = { _ in }
    private var contextPosition = 0

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        editSource(0)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextPosition = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        let item = NSMenuItem(title: "Edit Markdown Source", action: #selector(revealSource), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func revealSource() { editSource(contextPosition) }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: location)
        if event.modifierFlags.contains(.command) {
            if let storage = textStorage, index < storage.length,
               let link = storage.attribute(.link, at: index, effectiveRange: nil) as? URL {
                activateLink(link)
            }
        } else {
            edit(index, event)
        }
    }
}

enum NativeMath {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ latex: String, display: Bool, dark: Bool) throws -> NSImage {
        let key = "\(dark):\(display):\(latex)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard latex.utf8.count <= 10_000 else { throw PreviewError.resource("Math expression exceeds the rendering limit.") }
        let label = MTMathUILabel(frame: .zero)
        label.fontSize = display ? 20 : 16
        label.labelMode = display ? .display : .text
        label.textColor = dark ? .white : .black
        label.latex = latex
        if let error = label.error { throw error }
        let size = label.fittingSize
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, size.width * size.height < 4_000_000 else {
            throw PreviewError.resource("Math expression has unsupported dimensions.")
        }
        label.frame.size = size
        label.layoutSubtreeIfNeeded()
        guard let bitmap = label.bitmapImageRepForCachingDisplay(in: label.bounds) else {
            throw PreviewError.resource("Cannot allocate the math image.")
        }
        label.cacheDisplay(in: label.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.accessibilityDescription = latex
        cache.setObject(image, forKey: key, cost: Int(size.width * size.height * 4))
        cache.totalCostLimit = 16_000_000
        return image
    }
}

private struct NativeImageView: View {
    let href: String
    let alt: String
    let model: NativePreviewModel
    @State private var image: NSImage?
    @State private var failure: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: min(800, image.size.height))
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(alt)
            } else if let failure {
                Label("\(alt): \(failure)", systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                ProgressView().accessibilityLabel("Loading \(alt)")
            }
        }
        .task(id: "\(model.documentURL?.absoluteString ?? ""):\(href):\(model.mediaRevision)") {
            image = nil
            failure = nil
            do {
                let url = try model.resourceURL(href)
                let data = try await NativePreviewModel.imageData(url)
                guard !Task.isCancelled else { return }
                guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      width.doubleValue * height.doubleValue <= 40_000_000,
                      let decoded = NSImage(data: data) else {
                    throw PreviewError.resource("Unsupported image or image dimensions.")
                }
                image = decoded
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
                model.logger.error("Image load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct NativeVideoView: View {
    let href: String
    let model: NativePreviewModel
    @State private var player: AVPlayer?
    @State private var failure: String?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player).frame(height: 280)
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
            } else {
                ProgressView("Loading video")
            }
        }
        .task(id: "\(model.documentURL?.absoluteString ?? ""):\(href):\(model.mediaRevision)") {
            player?.pause()
            player = nil
            failure = nil
            do {
                let url = try model.resourceURL(href)
                let asset = AVURLAsset(url: url, options: [
                    AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                ])
                guard try await asset.load(.isPlayable) else {
                    throw PreviewError.resource("This video cannot be played.")
                }
                guard !Task.isCancelled else { return }
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                model.logger.error("Video load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        .onDisappear { player?.pause() }
    }
}

private struct NativeDiagramView: View {
    let source: String
    let model: NativePreviewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var failure: String?
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: image.size.width)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(source)
            } else if let failure {
                VStack(alignment: .leading) {
                    Text(failure).font(.caption).foregroundStyle(.secondary)
                    Text(source).font(.system(.body, design: .monospaced)).textSelection(.disabled)
                }
            } else {
                ProgressView("Rendering diagram")
            }
        }
        .task(id: "\(colorScheme):\(source)") {
            let dark = colorScheme == .dark
            let key = "\(dark):\(source)" as NSString
            if let cached = Self.cache.object(forKey: key) { image = cached; return }
            image = nil
            failure = nil
            do {
                let data = try await Task.detached { Data(try renderDiagram(source: source, dark: dark)) }.value
                guard !Task.isCancelled else { return }
                guard let rendered = NSImage(data: data) else { throw PreviewError.resource("Invalid diagram image.") }
                image = rendered
                Self.cache.totalCostLimit = 32_000_000
                Self.cache.setObject(rendered, forKey: key, cost: data.count)
            } catch {
                guard !Task.isCancelled else { return }
                failure = "Diagram shown as source: \(error.localizedDescription)"
                model.logger.error("Diagram render failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct NativeCodeView: View {
    let tree: NativeRenderTree
    let index: Int
    let language: String
    let model: NativePreviewModel
    private var source: String { tree.text(index) }
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlighted: NSAttributedString?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading) {
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
                NativeInlineText(tree: tree, index: index, model: model, dark: colorScheme == .dark,
                    highlighted: highlighted, wraps: false)
                    .padding(12)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .task(id: "\(colorScheme):\(language):\(source)") {
            highlighted = nil
            failure = nil
            let source = source
            do {
                let dark = colorScheme == .dark
                let spans = try await Task.detached { try highlightSource(text: source, language: language, dark: dark) }.value
                guard !Task.isCancelled else { return }
                let text = NSMutableAttributedString(string: source, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: NSColor.textColor,
                ])
                for span in spans {
                    text.addAttribute(.foregroundColor, value: NSColor(
                        red: CGFloat(span.red) / 255, green: CGFloat(span.green) / 255,
                        blue: CGFloat(span.blue) / 255, alpha: 1),
                        range: NSRange(location: Int(span.start), length: Int(span.length)))
                }
                highlighted = text
            } catch {
                guard !Task.isCancelled else { return }
                failure = "Highlighting unavailable: \(error.localizedDescription)"
                model.logger.error("Code highlighting failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
