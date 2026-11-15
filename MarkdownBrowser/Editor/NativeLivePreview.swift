import AppKit
import MdbCore
import SwiftUI
import os

nonisolated struct NativeInlineConcealment {
    let range: NSRange
    let markers: [NSRange]

    static func ranges(source: String, markdown: NativeMarkdown) -> [NativeInlineConcealment] {
        let text = source as NSString
        return markdown.nodes.indices.compactMap { index in
            let node = markdown.nodes[index]
            guard NSMaxRange(node.range) <= text.length else { return nil }
            switch node.kind {
            case .strong, .emphasis, .strike, .link:
                let children = markdown.children[index].map { markdown.nodes[$0].range }
                    .filter { $0.length > 0 && $0.location >= node.range.location && NSMaxRange($0) <= NSMaxRange(node.range) }
                guard let first = children.first, let last = children.last else { return nil }
                return NativeInlineConcealment(range: node.range, markers: [
                    NSRange(location: node.range.location, length: first.location - node.range.location),
                    NSRange(location: NSMaxRange(last), length: NSMaxRange(node.range) - NSMaxRange(last)),
                ].filter { $0.length > 0 })
            case .code:
                let raw = text.substring(with: node.range)
                let count = raw.prefix { $0 == "`" }.utf16.count
                guard count > 0, node.range.length >= 2 * count else { return nil }
                return NativeInlineConcealment(range: node.range, markers: [
                    NSRange(location: node.range.location, length: count),
                    NSRange(location: NSMaxRange(node.range) - count, length: count),
                ])
            default:
                return nil
            }
        }
    }
}

nonisolated struct NativeLiveBlock: Equatable {
    var range: NSRange
    let renderIndex: Int
    var sourceShift = 0

    static func blocks(source: String, markdown: NativeMarkdown) -> [NativeLiveBlock] {
        let text = source as NSString
        let tree = markdown.rendered
        guard tree.failure == nil else { return [] }
        var byStart: [String: Int] = [:]
        for index in tree.nodes.indices {
            if let start = tree.nodes[index].attributes["source-start"], byStart[start] == nil {
                byStart[start] = index
            }
        }
        let roots = markdown.nodes.indices.filter { markdown.nodes[$0].parent == 0 }
        let htmlRanges = markdown.nodes.filter { $0.kind == .html }.map(\.range)
        let tags = /(?i)<(\/?)(details|div|section|article|table|blockquote|ul|ol|pre)\b[^>]*>/
        let firstTag = /(?i)<([a-z][a-z0-9]*)\b/
        var consumed: Set<Int> = []
        var coveredUntil = 0
        var output: [NativeLiveBlock] = []
        for root in roots {
            let node = markdown.nodes[root]
            guard node.length > 0, node.range.location >= coveredUntil,
                  NSMaxRange(node.range) <= text.length else { continue }
            var range = node.range
            var renderIndex = byStart[String(node.start)]
            if node.kind == .html {
                let raw = text.substring(from: range.location)
                var stack: [String] = []
                var started = false
                for match in raw.matches(of: tags) {
                    let location = range.location + raw[..<match.range.lowerBound].utf16.count
                    guard htmlRanges.contains(where: { NSLocationInRange(location, $0) }) else { continue }
                    let tag = String(match.output.2).lowercased()
                    if match.output.1.isEmpty {
                        if !started, location >= NSMaxRange(range) { break }
                        started = true
                        stack.append(tag)
                    } else if let last = stack.lastIndex(of: tag) {
                        stack.removeSubrange(last...)
                    }
                    if started, stack.isEmpty {
                        range.length = max(range.length, raw[..<match.range.upperBound].utf16.count)
                        break
                    }
                }
                if started, !stack.isEmpty { range.length = text.length - range.location }
                let fragment = text.substring(with: range)
                if let tag = fragment.firstMatch(of: firstTag)?.output.1 {
                    renderIndex = tree.nodes.indices.first {
                        !consumed.contains($0) && tree.nodes[$0].tag == tag.lowercased()
                    }
                }
            } else if node.kind == .footnote {
                renderIndex = tree.nodes.indices.first { tree.nodes[$0].attributes["id"] == node.destination }
            }
            guard let renderIndex else { continue }
            let line = text.lineRange(for: NSRange(location: range.location, length: 0))
            let prefix = NSRange(location: line.location, length: range.location - line.location)
            if text.substring(with: prefix).trimmingCharacters(in: .whitespaces).isEmpty {
                range.length += prefix.length
                range.location = line.location
            }
            output.append(NativeLiveBlock(range: range, renderIndex: renderIndex))
            coveredUntil = NSMaxRange(range)
            var stack = [renderIndex]
            while let next = stack.popLast() {
                consumed.insert(next)
                stack.append(contentsOf: tree.children[next])
            }
        }
        return output
    }
}

final class NativeLiveLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private(set) var concealed = IndexSet()
    private(set) var blocks: [Int: NSSize] = [:]
    private var blockStarts = IndexSet()
    private nonisolated let backgroundConcealment = OSAllocatedUnfairLock(initialState: IndexSet())

    nonisolated override init() { super.init() }
    nonisolated required init?(coder: NSCoder) { super.init(coder: coder) }

    func present(_ ranges: [(NSRange, NSSize)], concealing markers: [NSRange] = []) {
        delegate = self
        var concealed = IndexSet()
        var blocks: [Int: NSSize] = [:]
        for range in markers { concealed.insert(integersIn: range.location..<NSMaxRange(range)) }
        for (range, size) in ranges {
            concealed.insert(integersIn: range.location..<NSMaxRange(range))
            blocks[range.location] = size
        }
        guard self.concealed != concealed || self.blocks != blocks else { return }
        var changed = self.concealed.symmetricDifference(concealed)
        for key in Set(self.blocks.keys).union(blocks.keys) where self.blocks[key] != blocks[key] {
            changed.insert(key)
        }
        self.concealed = concealed
        let snapshot = concealed
        backgroundConcealment.withLock { $0 = snapshot }
        self.blocks = blocks
        blockStarts = IndexSet(blocks.keys)
        let length = textStorage?.length ?? 0
        let first = min(changed.first ?? 0, length)
        let end = min((changed.last ?? 0) + 1, length)
        let range = NSRange(location: first, length: max(0, end - first))
        invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        invalidateDisplay(forCharacterRange: range)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
        font: NSFont, forGlyphRange range: NSRange) -> Int {
        guard !concealed.isEmpty else { return 0 }
        var glyphs = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
        var properties = Array(UnsafeBufferPointer(start: props, count: range.length))
        for index in 0..<range.length where concealed.contains(characterIndexes[index]) {
            // Control glyphs reserve native-view space without inserting attachment characters into the source.
            glyphs[index] = 0
            properties[index] = .controlCharacter
        }
        setGlyphs(&glyphs, properties: &properties, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        return range.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if blocks[charIndex] != nil { return .whitespace }
        return concealed.contains(charIndex) ? .zeroAdvancement : action
    }

    nonisolated override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        let hidden = backgroundConcealment.withLock { $0 }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let visible = IndexSet(integersIn: characters.location..<NSMaxRange(characters)).subtracting(hidden)
        for run in visible.rangeView {
            let range = glyphRange(forCharacterRange: NSRange(location: run.lowerBound, length: run.count),
                actualCharacterRange: nil)
            super.drawBackground(forGlyphRange: NSIntersectionRange(range, glyphs), at: origin)
        }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint, characterIndex: Int) -> NSRect {
        NSRect(origin: .zero, size: blocks[characterIndex] ?? .zero)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let range = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard let start = blockStarts.integerGreaterThanOrEqualTo(range.location),
              start < NSMaxRange(range), let height = blocks[start]?.height else { return false }
        lineFragmentRect.pointee.size.height = height + 6
        lineFragmentUsedRect.pointee.size.height = height + 6
        baselineOffset.pointee = height
        return true
    }
}

private struct NativeLiveBlockView: View {
    let tree: NativeRenderTree
    let index: Int
    let model: NativePreviewModel
    let width: CGFloat
    let dark: Bool
    let edit: () -> Void
    let resized: (CGFloat) -> Void
    private var modifiers: NSEvent.ModifierFlags { NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags }

    var body: some View {
        NativePreviewBlock(tree: tree, index: index, model: model)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture {
                if !modifiers.contains(.command) { edit() }
            }
            .accessibilityElement(children: .contain)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.openURL, OpenURLAction { url in
                if modifiers.contains(.command) {
                    model.openLink(url.absoluteString, modifiers.contains(.shift))
                } else {
                    edit()
                }
                return .handled
            })
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { resized(geometry.size.height) }
                        .onChange(of: geometry.size.height) { _, height in resized(height) }
                }
            }
    }
}

final class NativeLivePreviewController: NSObject {
    private weak var textView: NativeTextView?
    private let layout: NativeLiveLayoutManager
    private let model: NativePreviewModel
    private var tree: NativeRenderTree?
    private var plans: [NativeLiveBlock] = []
    private var displayed: [NativeLiveBlock] = []
    private var concealments: [NativeInlineConcealment] = []
    private var markers: [NSRange] = []
    private var views: [Int: NSHostingView<NativeLiveBlockView>] = [:]
    private var heights: [Int: CGFloat] = [:]
    private var width: CGFloat = 0
    private var dark = false
    private var updating = false
    private var pendingEdit: (NSRange, Int)?
    private var generation = 0
    private var interactionLocation: Int?
    private var pinnedCaret: (position: Int, viewportY: CGFloat)?
    var reveal: (NSRange) -> Void = { _ in }
    var interact: (Int, NSEvent) -> Void = { _, _ in }

    init(textView: NativeTextView, layout: NativeLiveLayoutManager, model: NativePreviewModel) {
        self.textView = textView
        self.layout = layout
        self.model = model
        super.init()
        textView.updateLiveViews = { [weak self] in self?.updateViewport() }
        model.editBlock = { [weak self] index in self?.revealRenderedBlock(index) }
        model.editPosition = { [weak self] index, position in
            guard let self, let position = self.sourcePosition(index, offset: position) else { return }
            self.reveal(NSRange(location: position, length: 0))
        }
        model.editText = { [weak self] index, position, event in
            guard let self, let position = self.sourcePosition(index, offset: position) else { return }
            if let textView = self.textView {
                self.pinnedCaret = (position, textView.convert(event.locationInWindow, from: nil).y - textView.visibleRect.minY)
            }
            self.interactionLocation = position
            self.updateSelection()
            self.interact(position, event)
            self.interactionLocation = nil
            self.updateSelection()
        }
    }

    func observe(_ clipView: NSClipView) {
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: clipView)
    }

    func reset() {
        plans = []
        displayed = []
        concealments = []
        markers = []
        tree = nil
        pendingEdit = nil
        pinnedCaret = nil
        interactionLocation = nil
        heights = [:]
        removeViews()
        layout.present([])
    }

    func apply(_ markdown: NativeMarkdown, source: String) {
        tree = markdown.rendered
        plans = NativeLiveBlock.blocks(source: source, markdown: markdown)
        concealments = NativeInlineConcealment.ranges(source: source, markdown: markdown)
        heights = [:]
        removeViews()
        updateSelection()
    }

    func prepareForEdit(_ range: NSRange, length: Int) {
        pendingEdit = (range, length)
        concealments = []
        markers = []
        displayed.removeAll { NSIntersectionRange($0.range, range).length > 0 || NSLocationInRange(range.location, $0.range) }
        present()
    }

    func textChanged() {
        pinnedCaret = nil
        guard let (range, length) = pendingEdit else { reset(); return }
        pendingEdit = nil
        let delta = length - range.length
        let shift: (NativeLiveBlock) -> NativeLiveBlock? = { plan in
            if NSIntersectionRange(plan.range, range).length > 0 || NSLocationInRange(range.location, plan.range) { return nil }
            var plan = plan
            if plan.range.location >= NSMaxRange(range) {
                plan.range.location += delta
                plan.sourceShift += delta
            }
            return plan
        }
        plans = plans.compactMap(shift)
        displayed = displayed.compactMap(shift)
        removeViews()
        if textView?.hasMarkedText() == true {
            present()
            updateViewport()
        } else {
            updateSelection()
        }
    }

    func updateSelection() {
        guard let textView, !textView.hasMarkedText() else { return }
        if interactionLocation == nil, let pinnedCaret,
           textView.selectedRange() != NSRange(location: pinnedCaret.position, length: 0) {
            self.pinnedCaret = nil
        }
        let source = textView.string as NSString
        let selections = textView.selectedRanges.map(\.rangeValue).map {
            source.lineRange(for: NSIntersectionRange($0, NSRange(location: 0, length: source.length)))
        }
        displayed = model.isVisible ? plans.filter { plan in
            if let interactionLocation,
               interactionLocation >= plan.range.location && interactionLocation <= NSMaxRange(plan.range) { return false }
            return !selections.contains { selection in
                NSIntersectionRange(plan.range, selection).length > 0 || NSLocationInRange(selection.location, plan.range)
            }
        } : []
        markers = model.isVisible && interactionLocation == nil ? concealments.filter { inline in
            !textView.selectedRanges.contains { selected in
                let range = selected.rangeValue
                return NSIntersectionRange(inline.range, range).length > 0
                    || (range.location >= inline.range.location && range.location <= NSMaxRange(inline.range))
            }
        }.flatMap(\.markers) : []
        present()
        updateViewport()
    }

    func appearanceChanged(_ dark: Bool) {
        guard self.dark != dark else { return }
        self.dark = dark
        heights = [:]
        removeViews()
        updateSelection()
    }

    private func present() {
        guard let textView else { return }
        let wasUpdating = updating
        updating = true
        defer { updating = wasUpdating }
        let anchor = viewportAnchor()
        let available = (textView.textContainer?.containerSize.width ?? 600)
            - 2 * (textView.textContainer?.lineFragmentPadding ?? 5)
        width = max(40, min(available, textView.bounds.width - 2 * textView.textContainerInset.width))
        layout.present(displayed.map { ($0.range, NSSize(width: width, height: heights[$0.renderIndex] ?? 28)) },
            concealing: markers)
        if let (character, viewportY) = anchor, let scrollView = textView.enclosingScrollView {
            layout.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
            let glyph = layout.glyphIndexForCharacter(at: character)
            let y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).midY
            let clip = scrollView.contentView
            var bounds = clip.bounds
            bounds.origin.y = y + textView.textContainerOrigin.y - viewportY
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func viewportAnchor() -> (Int, CGFloat)? {
        guard let textView, let container = textView.textContainer,
              let length = textView.textStorage?.length, length > 0 else { return nil }
        if let pinnedCaret, pinnedCaret.position < length { return (pinnedCaret.position, pinnedCaret.viewportY) }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect
        let selection = textView.selectedRange()
        var character = min(textView.selectionAffinity == .upstream ? selection.location : NSMaxRange(selection), length - 1)
        var glyph = layout.glyphIndexForCharacter(at: character)
        var line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        if layout.concealed.contains(character) || !visible.intersects(line.offsetBy(dx: origin.x, dy: origin.y)) {
            let point = NSPoint(x: container.lineFragmentPadding, y: max(0, visible.minY - origin.y))
            glyph = layout.glyphIndex(for: point, in: container)
            guard glyph < layout.numberOfGlyphs else { return nil }
            character = layout.characterIndexForGlyph(at: glyph)
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        return (character, line.midY + origin.y - visible.minY)
    }

    @objc private func scrolled() {
        if !updating, interactionLocation == nil,
           let type = NSApp.currentEvent?.type,
           type == .scrollWheel || type == .leftMouseDragged || type == .leftMouseDown || type == .keyDown {
            pinnedCaret = nil
        }
        updateViewport()
    }

    private func revealRenderedBlock(_ index: Int) {
        guard let plan = plan(containing: index) else { return }
        let offset = tree?.sourceRanges[index]?.location ?? plan.range.location - plan.sourceShift
        guard let position = sourcePosition(index, offset: offset) else { return }
        reveal(NSRange(location: position, length: 0))
    }

    private func sourcePosition(_ index: Int, offset: Int) -> Int? {
        guard let plan = plan(containing: index) else { return nil }
        let position = offset + plan.sourceShift
        guard position >= plan.range.location, position <= NSMaxRange(plan.range) else {
            model.notice = "Could not map the rendered content to its source."
            model.logger.error("Rendered position is outside its source block.")
            return nil
        }
        return position
    }

    private func plan(containing index: Int) -> NativeLiveBlock? {
        guard let tree else { return nil }
        var index: Int? = index
        while let current = index {
            if let plan = plans.first(where: { $0.renderIndex == current }) {
                return plan
            }
            index = tree.nodes[current].parent.map(Int.init)
        }
        return nil
    }

    func updateViewport() {
        guard !updating, let textView, let container = textView.textContainer, let tree else { return }
        updating = true
        defer { updating = false }
        let available = max(40, min(container.containerSize.width - 2 * container.lineFragmentPadding,
            textView.bounds.width - 2 * textView.textContainerInset.width))
        if abs(width - available) > 1 {
            width = available
            heights = [:]
            removeViews()
            present()
        }
        let bounds = textView.visibleRect.insetBy(dx: 0, dy: -200)
        let glyphs = layout.glyphRange(forBoundingRect: bounds.offsetBy(
            dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let visible = displayed.filter {
            NSIntersectionRange($0.range, characters).length > 0 || NSLocationInRange($0.range.location, characters)
        }
        let indices = Set(visible.map(\.renderIndex))
        for index in Array(views.keys) where !indices.contains(index) {
            views.removeValue(forKey: index)?.removeFromSuperview()
        }
        for block in visible {
            let view: NSHostingView<NativeLiveBlockView>
            if let existing = views[block.renderIndex] {
                view = existing
            } else {
                view = NSHostingView(rootView: NativeLiveBlockView(
                    tree: tree, index: block.renderIndex, model: model, width: width, dark: dark,
                    edit: { [weak self] in self?.reveal(block.range) },
                    resized: { [weak self, generation] height in
                        guard let self, self.generation == generation else { return }
                        self.resized(block.renderIndex, height: height)
                    }))
                views[block.renderIndex] = view
                view.setAccessibilityIdentifier("markdown-block-\(block.renderIndex)")
                view.setAccessibilityHelp("Click to edit Markdown source.")
                view.toolTip = "Click to edit Markdown source"
                textView.addSubview(view)
            }
            let glyph = layout.glyphIndexForCharacter(at: block.range.location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            view.frame = NSRect(x: textView.textContainerOrigin.x + line.minX + container.lineFragmentPadding,
                y: textView.textContainerOrigin.y + line.minY + 3, width: width,
                height: heights[block.renderIndex] ?? 28)
        }
    }

    private func resized(_ index: Int, height: CGFloat) {
        guard height.isFinite, height > 0, abs((heights[index] ?? 28) - height) > 0.5 else { return }
        heights[index] = height
        present()
        textView?.needsLayout = true
        textView?.needsDisplay = true
    }

    private func removeViews() {
        generation += 1
        views.values.forEach { $0.removeFromSuperview() }
        views = [:]
    }
}
