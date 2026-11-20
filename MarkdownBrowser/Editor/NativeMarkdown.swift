import AppKit
import MdbCore
import os

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

    static func make(index: Int, nodes: [MarkdownNode], children: [[Int]], source: NSString) -> Self? {
        let node = nodes[index]
        switch node.kind {
        case .text, .code:
            var range = node.range
            guard contains(range, in: source) else { return nil }
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
            guard contains(range, in: source) else { return nil }
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
            guard contains(node.range, in: source) else { return nil }
            var text = ""
            var offsets = [node.range.location]
            for child in children[index] {
                guard let part = make(index: child, nodes: nodes, children: children, source: source) else { return nil }
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

    private static func contains(_ range: NSRange, in source: NSString) -> Bool {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= source.length else {
            Logger(subsystem: "MarkdownBrowser", category: "NativePreview")
                .error("Parser source range \(range.location),\(range.length) is outside the document")
            return false
        }
        return true
    }

    static func aligned(_ text: String, range: NSRange, source: NSString) -> Self? {
        guard contains(range, in: source) else { return nil }
        let raw = source.substring(with: range)
        if raw == text, raw.utf16.count == text.utf16.count {
            return Self(text: text, offsets: Array(range.location...NSMaxRange(range)))
        }
        // Align only within a parser leaf, never by searching the document for repeated rendered text.
        let original = Array(raw)
        let rendered = Array(text)
        var starts = [range.location]
        var sourceOffset = range.location
        for character in original {
            sourceOffset += character.utf16.count
            starts.append(sourceOffset)
        }
        var positions = Array(repeating: range.location, count: rendered.count + 1)
        var previous = range.location
        // A diff costs the leaf's length times its number of changes, which is quadratic for a long line full of
        // entities. Longer leaves are diffed a window at a time, keeping only the first half of each window so the
        // cut never decides an alignment. A leaf that fits in one window is diffed whole.
        let window = 128
        var renderedIndex = 0
        var originalIndex = 0
        while renderedIndex < rendered.count {
            let renderedPart = rendered[renderedIndex..<min(rendered.count, renderedIndex + window)]
            let originalPart = original[originalIndex..<min(original.count, originalIndex + window)]
            if originalPart.isEmpty {
                for index in renderedIndex..<rendered.count { positions[index] = previous }
                break
            }
            let isLast = renderedPart.endIndex == rendered.count && originalPart.endIndex == original.count
            var removed = Set<Int>()
            var inserted = Set<Int>()
            for change in renderedPart.difference(from: originalPart) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            var renderedOffset = 0
            var originalOffset = 0
            while renderedOffset < renderedPart.count {
                if !isLast, renderedOffset + originalOffset > 0,
                   renderedOffset >= renderedPart.count / 2 || originalOffset >= originalPart.count / 2 { break }
                while removed.contains(originalOffset) { originalOffset += 1 }
                if !inserted.contains(renderedOffset), originalOffset < originalPart.count {
                    positions[renderedIndex + renderedOffset] = starts[originalIndex + originalOffset]
                    previous = starts[originalIndex + originalOffset + 1]
                    originalOffset += 1
                } else {
                    positions[renderedIndex + renderedOffset] = previous
                }
                renderedOffset += 1
            }
            renderedIndex += renderedOffset
            originalIndex += originalOffset
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

struct NativeMarkdownStyle: Hashable {
    let range: NSRange
    let kind: MarkdownKind
    let level: UInt32

    /// Ranges whose attributes differ between `old` and `new` styling, in the offsets of `new`.
    /// `edited` is the text replaced since `old` was applied (in current offsets) and `delta` its length change:
    /// old styles after it are compared at their shifted offsets, so an edit only invalidates what it touched.
    static func changedRanges(
        from old: [NativeMarkdownStyle], to new: [NativeMarkdownStyle], edited: NSRange?, delta: Int
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var moved = old
        if let edited {
            let oldEnd = NSMaxRange(edited) - delta
            moved = old.compactMap { style in
                if NSMaxRange(style.range) <= edited.location { return style }
                if style.range.location >= oldEnd {
                    let range = NSRange(location: style.range.location + delta, length: style.range.length)
                    return NativeMarkdownStyle(range: range, kind: style.kind, level: style.level)
                }
                // The edit cut into this style: its attributes now sit on whatever text surrounds the edit.
                let start = min(style.range.location, edited.location)
                let end = max(NSMaxRange(style.range) + delta, NSMaxRange(edited))
                ranges.append(NSRange(location: start, length: end - start))
                return nil
            }
        }
        let before = Set(moved)
        let after = Set(new)
        return ranges + (moved.filter { !after.contains($0) } + new.filter { !before.contains($0) }).map(\.range)
    }

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
