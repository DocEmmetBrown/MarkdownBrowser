import AppKit
import MdbCore

nonisolated struct NativeMarkdown: Sendable {
    let nodes: [MarkdownNode]
    let children: [[Int]]
    let rendered: NativeRenderTree

    init(_ source: String) {
        nodes = parseMarkdown(text: source)
        rendered = NativeRenderTree(source, structure: nodes)
        var children = Array(repeating: [Int](), count: nodes.count)
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent {
                children[Int(parent)].append(index)
            }
        }
        self.children = children
    }

    func link(at location: Int) -> String? {
        nodes.last {
            [.link, .image, .footnoteReference].contains($0.kind)
                && NSLocationInRange(location, $0.range)
        }?.destination
    }

    func anchor(_ fragment: String) -> NSRange? {
        let decoded = fragment.removingPercentEncoding ?? fragment
        let target = decoded.hasPrefix("user-content-")
            ? String(decoded.dropFirst("user-content-".count)) : decoded
        return nodes.first {
            ([.heading, .footnote].contains($0.kind) && $0.destination == target.lowercased())
                || ($0.kind == .footnoteReference && $0.detail == target.lowercased())
        }?.range
    }
}

extension MarkdownNode {
    nonisolated var range: NSRange { NSRange(location: Int(start), length: Int(length)) }
}

struct NativeMarkdownStyle: Equatable {
    let range: NSRange
    let kind: MarkdownKind
    let level: UInt32
    var key: String { "\(range.location):\(range.length):\(kind):\(level)" }

    var attributes: [NSAttributedString.Key: Any] {
        switch kind {
        case .heading:
            [.font: NSFont.monospacedSystemFont(ofSize: max(15, 25 - CGFloat(level) * 2), weight: .semibold)]
        case .strong:
            [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)]
        case .emphasis:
            [.font: NSFontManager.shared.convert(.monospacedSystemFont(ofSize: 14, weight: .regular), toHaveTrait: .italicFontMask)]
        case .strike:
            [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .code, .codeBlock:
            [.foregroundColor: NSColor.secondaryLabelColor, .backgroundColor: NSColor.quaternaryLabelColor]
        case .link, .image, .footnoteReference:
            [.foregroundColor: NSColor.linkColor]
        case .html, .math:
            [.foregroundColor: NSColor.systemPurple]
        case .quote, .alert:
            [.foregroundColor: NSColor.secondaryLabelColor]
        default:
            [:]
        }
    }

    func apply(to storage: NSTextStorage, range: NSRange) {
        guard kind == .strong || kind == .emphasis else {
            storage.addAttributes(attributes, range: range)
            return
        }
        var fonts: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, span, _ in
            let font = value as? NSFont ?? .monospacedSystemFont(ofSize: 14, weight: .regular)
            let trait: NSFontTraitMask = kind == .strong ? .boldFontMask : .italicFontMask
            fonts.append((span, NSFontManager.shared.convert(font, toHaveTrait: trait)))
        }
        for (span, font) in fonts {
            storage.addAttribute(.font, value: font, range: span)
        }
    }
}
