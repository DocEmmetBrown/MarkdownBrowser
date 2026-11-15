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

nonisolated struct NativeRenderedSourceMap: Sendable {
    let text: String
    let offsets: [Int]

    static func make(index: Int, nodes: [MarkdownNode], children: [[Int]], source: NSString) -> Self {
        let node = nodes[index]
        switch node.kind {
        case .text, .code:
            var range = node.range
            if node.kind == .code {
                let raw = source.substring(with: range)
                let fence = raw.prefix { $0 == "`" }.utf16.count
                if fence > 0, range.length >= 2 * fence {
                    range.location += fence
                    range.length -= 2 * fence
                }
            }
            return aligned(node.text, range: range, source: source)
        case .softBreak, .lineBreak:
            return Self(text: "\n", offsets: [node.range.location, NSMaxRange(node.range)])
        case .codeBlock:
            var range = node.range
            let first = source.lineRange(for: NSRange(location: range.location, length: 0))
            let opening = source.substring(with: NSIntersectionRange(first, range)).trimmingCharacters(in: .whitespaces)
            if opening.hasPrefix("```") || opening.hasPrefix("~~~") {
                let last = source.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
                let closing = source.substring(with: NSIntersectionRange(last, range)).trimmingCharacters(in: .whitespaces)
                let fence = String(opening.prefix { $0 == opening.first })
                let closingFence = closing.prefix { $0 == opening.first }
                let isClosing = closingFence.count >= fence.count
                    && closing.dropFirst(closingFence.count).trimmingCharacters(in: .whitespaces).isEmpty
                let end = last.location > first.location && isClosing ? last.location : NSMaxRange(range)
                range = NSRange(location: NSMaxRange(first), length: max(0, end - NSMaxRange(first)))
            }
            return aligned(node.text, range: range, source: source)
        case .emoji, .footnoteReference:
            return atomic(node.text, range: node.range)
        case .math:
            return atomic("\u{fffc}", range: node.range)
        case .html:
            return Self(text: "", offsets: [node.range.location])
        default:
            var text = ""
            var offsets = [node.range.location]
            for child in children[index] {
                let part = make(index: child, nodes: nodes, children: children, source: source)
                guard !part.text.isEmpty else { continue }
                text += part.text
                offsets.removeLast()
                offsets.append(contentsOf: part.offsets)
            }
            return Self(text: text, offsets: offsets)
        }
    }

    private static func atomic(_ text: String, range: NSRange) -> Self {
        var offsets = Array(repeating: range.location, count: text.utf16.count + 1)
        offsets[offsets.count - 1] = NSMaxRange(range)
        return Self(text: text, offsets: offsets)
    }

    static func aligned(_ text: String, range: NSRange, source: NSString) -> Self {
        guard range.location >= 0, NSMaxRange(range) <= source.length else {
            preconditionFailure("Parser source range is outside the document")
        }
        let raw = source.substring(with: range)
        if raw == text, raw.utf16.count == text.utf16.count {
            return Self(text: text, offsets: Array(range.location...NSMaxRange(range)))
        }
        // Align only within a parser leaf, never by searching the document for repeated rendered text.
        let original = Array(raw)
        let rendered = Array(text)
        let changes = rendered.difference(from: original)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var starts = [range.location]
        var sourceOffset = range.location
        for character in original {
            sourceOffset += character.utf16.count
            starts.append(sourceOffset)
        }
        var positions = Array(repeating: range.location, count: rendered.count + 1)
        var originals = original.indices.filter { !removed.contains($0) }.makeIterator()
        var previous = range.location
        for index in rendered.indices {
            if !inserted.contains(index), let originalIndex = originals.next() {
                positions[index] = starts[originalIndex]
                previous = starts[originalIndex + 1]
            } else {
                positions[index] = previous
            }
        }
        positions[rendered.count] = NSMaxRange(range)
        var offsets: [Int] = []
        for index in rendered.indices {
            let count = rendered[index].utf16.count
            let span = positions[index + 1] - positions[index]
            for unit in 0..<count {
                offsets.append(positions[index] + (span == count ? unit : 0))
            }
        }
        offsets.append(NSMaxRange(range))
        return Self(text: text, offsets: offsets)
    }
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
