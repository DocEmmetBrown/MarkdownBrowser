import AppKit
import MdbCore
import SwiftUI

struct NativeEditorView: View {
    let host: NativeEditorHost

    var body: some View {
        VStack(spacing: 0) {
            if let notice = host.preview.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(8)
            }
            NativeSourceView(host: host)
        }
    }
}

private struct NativeSourceView: NSViewRepresentable {
    let host: NativeEditorHost
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSScrollView {
        host.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        host.setDarkAppearance(colorScheme == .dark)
    }
}

final class NativeEditorHost: NSObject, DocumentEditor, NSTextViewDelegate {
    let textView: NativeTextView
    let scrollView: NSScrollView
    let preview = NativePreviewModel()
    let liveLayout: NativeLiveLayoutManager
    private(set) lazy var livePreview = NativeLivePreviewController(textView: textView, layout: liveLayout, model: preview)

    var onDirtyChange: (Int, Bool) -> Void = { _, _ in }
    var onUnsavedText: (Int, String) -> Void = { _, _ in }
    var onOpenLink: (Int, String, Bool) -> Void = { _, _, _ in }
    var onFindStatus: (Int, FindStatus) -> Void = { _, _ in }

    private weak var document: OpenDocument?
    private var savedText = ""
    private var revision = 0
    private var snapshots: [Int: String] = [:]
    private var options = SearchOptions(query: "")
    private var replacement = ""
    private var matches: [(search: SearchEngine.Match, range: NSRange)] = []
    private var matchedRevision = -1
    private var matchedOptions: SearchOptions?
    private var isLoading = false
    private let engine = SearchEngine()
    private var markdown: NativeMarkdown?
    private var parsedSource = ""
    private var parseTask: Task<Void, Never>?
    private var styles: [NativeMarkdownStyle] = []
    private var pendingMarkdownStyle = false
    private var editedStyleRange: NSRange?
    private var codeTask: Task<Void, Never>?
    private var isDark = false
    private var loadsRemoteMedia = AppSettings.loadRemoteMedia

    override init() {
        let storage = NSTextStorage()
        liveLayout = NativeLiveLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(liveLayout)
        liveLayout.addTextContainer(container)
        textView = NativeTextView(frame: .zero, textContainer: container)
        scrollView = NativeEditorScrollView()
        super.init()
        livePreview.reveal = { [weak self] range in
            guard let self else { return }
            self.livePreview.restingCaret = nil
            self.textView.setSelectedRange(NSRange(location: range.location, length: 0))
            self.livePreview.updateSelection()
            self.textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
            self.focus()
        }
        livePreview.interact = { [weak self] position, event in
            self?.interactWithSource(at: position, event: event)
        }
        textView.delegate = self
        textView.didTrackMouse = { [weak self] in
            guard let self, self.livePreview.restingCaret != nil else { return }
            self.livePreview.restingCaret = nil
            self.livePreview.updateSelection()
        }
        textView.openLink = { [weak self] location, newTab in
            guard let self, let document = self.document, document.kind == .markdown else { return false }
            self.ensureMarkdown()
            guard let href = self.markdown?.link(at: location) else { return false }
            self.onOpenLink(document.id, href, newTab)
            return true
        }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.font = font
        textView.textColor = .textColor
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        scrollView.documentView = textView
        livePreview.observe(scrollView.contentView)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        textView.textContainerInset = NSSize(width: CGFloat(AppSettings.pageLayout.margins.points), height: 16)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: UserDefaults.didChangeNotification, object: nil)
        applySettings()
    }

    func load(_ document: OpenDocument, rootURL: URL?, anchor: String?) {
        self.document = document
        preview.documentURL = document.url
        preview.notice = nil
        preview.rootURL = rootURL
        preview.isVisible = document.kind == .markdown && !document.sourceMode
        preview.openLink = { [weak self] href, newTab in
            guard let self, let id = self.document?.id else { return }
            self.onOpenLink(id, href, newTab)
        }
        preview.toggleTask = { [weak self] offset, source in
            self?.toggleTask(at: offset, source: source)
        }
        savedText = document.content.text
        textView.lineSeparator = document.content.lineSeparator
        isLoading = true
        textView.string = document.recoveryText ?? savedText
        resetMarkdown()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        livePreview.restingCaret = 0
        textView.undoManager?.removeAllActions()
        isLoading = false
        snapshots.removeAll()
        revision += 1
        options.query = ""
        ensureMarkdown()
        scheduleCodeHighlighting()
        updateMatches()
        if let anchor {
            scrollToAnchor(anchor)
        } else {
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    func setSourceMode(_ on: Bool) {
        preview.isVisible = document?.kind == .markdown && !on
        livePreview.updateSelection()
    }

    func scrollToAnchor(_ fragment: String) {
        let decodedTarget = fragment.removingPercentEncoding ?? fragment
        let target = decodedTarget.hasPrefix("user-content-")
            ? String(decodedTarget.dropFirst("user-content-".count))
            : decodedTarget
        ensureMarkdown()
        let source = textView.string as NSString
        guard let range = markdown?.anchor(fragment) ?? explicitAnchorRange(in: source, target: target) else { return }
        livePreview.restingCaret = range.location
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        livePreview.updateSelection()
        textView.scrollRangeToVisible(range)
    }

    func reveal(docId: Int, line: Int, column: Int, length: Int) {
        guard document?.id == docId else { return }
        let match = SearchEngine.Match(line: line, column: column, length: length)
        guard let range = mappedMatches([match]).first?.range else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    func refreshMedia() {
        preview.mediaRevision += 1
    }

    func toggleTask(at offset: Int, source: String) {
        guard textView.string == source, !textView.hasMarkedText() else {
            NSSound.beep()
            return
        }
        ensureMarkdown()
        guard markdown?.nodes.contains(where: { $0.kind == .task && Int($0.detail) == offset }) == true,
              offset >= 0, offset < (source as NSString).length else {
            NSSound.beep()
            return
        }
        let symbol = (source as NSString).substring(with: NSRange(location: offset, length: 1))
        edit(range: NSRange(location: offset, length: 1), text: symbol == " " ? "x" : " ")
        textView.undoManager?.setActionName("Toggle Task")
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    private func interactWithSource(at position: Int, event: NSEvent) {
        guard let window = textView.window, let rect = textView.insertionRect(at: position) else {
            preview.notice = "Could not locate the source insertion point."
            preview.logger.error("Could not locate source insertion point at \(position).")
            return
        }
        let clip = scrollView.contentView
        let delta = rect.midY - textView.convert(event.locationInWindow, from: nil).y
        var bounds = clip.bounds
        bounds.origin.y += delta
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
        focus()
        textView.trackRenderedSelection(at: position, event: event, in: window)
    }

    func snapshot(docId: Int) async -> EditorSnapshot? {
        guard document?.id == docId else { return nil }
        let text = textView.string
        snapshots[revision] = text
        while snapshots.count > 8, let oldest = snapshots.keys.min() {
            snapshots.removeValue(forKey: oldest)
        }
        return EditorSnapshot(snapshotId: revision, text: text, dirty: text != savedText)
    }

    func markSaved(docId: Int, snapshotId: Int) async {
        guard document?.id == docId, let text = snapshots.removeValue(forKey: snapshotId) else { return }
        savedText = text
        reportChanges()
    }

    func replaceText(docId: Int, text: String) {
        guard document?.id == docId else { return }
        isLoading = true
        textView.string = text
        resetMarkdown()
        textView.lineSeparator = document?.content.lineSeparator ?? textView.lineSeparator
        textView.undoManager?.removeAllActions()
        isLoading = false
        savedText = text
        snapshots.removeAll()
        revision += 1
        ensureMarkdown()
        scheduleCodeHighlighting()
        reportChanges()
    }

    func text(docId: Int) async -> String? {
        document?.id == docId ? textView.string : nil
    }

    func applyText(docId: Int, text: String) {
        guard document?.id == docId else { return }
        edit(range: NSRange(location: 0, length: (textView.string as NSString).length), text: text)
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        livePreview.textChanged()
        revision += 1
        reportChanges()
        scheduleMarkdown()
        scheduleCodeHighlighting()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !isLoading, document?.kind == .markdown, let replacementString else { return true }
        let length = (replacementString as NSString).length
        livePreview.prepareForEdit(range, length: length)
        let delta = length - range.length
        var changed = NSRange(location: range.location, length: length)
        if var previous = editedStyleRange {
            if NSMaxRange(range) <= previous.location {
                previous.location += delta
            } else if range.location < NSMaxRange(previous) {
                let end = max(NSMaxRange(previous) + delta, NSMaxRange(changed))
                previous.location = min(previous.location, changed.location)
                previous.length = max(0, end - previous.location)
            }
            changed = NSUnionRange(changed, previous)
        }
        editedStyleRange = changed
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isLoading else { return }
        updateMatches()
        if pendingMarkdownStyle, !textView.hasMarkedText(), let markdown, parsedSource == textView.string {
            applyMarkdown(markdown, source: parsedSource)
        }
        livePreview.updateSelection()
    }

    func setFindQuery(docId: Int, _ model: FindBarModel) {
        guard document?.id == docId else { return }
        options = SearchOptions(query: model.query, caseSensitive: model.caseSensitive, regex: model.regex)
        replacement = model.replacement
        updateMatches()
    }

    func findNext(docId: Int, wrap: Bool) {
        step(docId: docId, forward: true, wrap: wrap)
    }

    func findPrevious(docId: Int, wrap: Bool) {
        step(docId: docId, forward: false, wrap: wrap)
    }

    func replaceCurrent(docId: Int, wrap: Bool) {
        guard document?.id == docId else { return }
        guard let match = matches.first(where: { $0.range == textView.selectedRange() }) else {
            findNext(docId: docId, wrap: wrap)
            return
        }
        guard
            let result = engine.replaceMatch(
                in: textView.string,
                lineSeparator: textView.lineSeparator,
                options: options,
                line: match.search.line,
                column: match.search.column,
                template: replacement)
        else {
            updateMatches()
            NSSound.beep()
            return
        }
        let oldLength = (textView.string as NSString).length
        let newLength = (result as NSString).length
        let replacementLength = max(0, newLength - oldLength + match.range.length)
        applyText(docId: docId, text: result)
        let caret = min(match.range.location + replacementLength, (textView.string as NSString).length)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        findNext(docId: docId, wrap: wrap)
    }

    func replaceAll(docId: Int) {
        guard document?.id == docId else { return }
        let result = engine.replace(
            in: textView.string, lineSeparator: textView.lineSeparator, options: options, template: replacement)
        if result.count > 0 { applyText(docId: docId, text: result.text) }
    }

    func selectAllMatches(docId: Int) {
        guard document?.id == docId, !matches.isEmpty else { return }
        textView.selectedRanges = matches.map { NSValue(range: $0.range) }
        focus()
    }

    func closeFind() {
        options.query = ""
        updateMatches()
    }

    private func reportChanges() {
        guard let id = document?.id else { return }
        let text = textView.string
        onUnsavedText(id, text)
        onDirtyChange(id, text != savedText)
        updateMatches()
    }

    func ensureMarkdown() {
        guard document?.kind == .markdown else { return }
        let source = textView.string
        guard source.utf8.count <= OpenDocument.livePreviewSizeLimit else { return }
        guard markdown == nil || parsedSource != source else { return }
        parseTask?.cancel()
        applyMarkdown(NativeMarkdown(source), source: source)
    }

    private func scheduleMarkdown() {
        parseTask?.cancel()
        guard document?.kind == .markdown else { return }
        let source = textView.string
        guard source.utf8.count <= OpenDocument.livePreviewSizeLimit else {
            // resetMarkdown() re-attributes the whole storage, so run it once when the document crosses the limit.
            if markdown != nil {
                resetMarkdown()
            } else {
                editedStyleRange = nil
            }
            return
        }
        let currentRevision = revision
        parseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let parsed = await Task.detached(priority: .userInitiated) { NativeMarkdown(source) }.value
            guard let self, !Task.isCancelled, self.revision == currentRevision else { return }
            self.applyMarkdown(parsed, source: source)
        }
    }

    private func applyMarkdown(_ parsed: NativeMarkdown, source: String) {
        markdown = parsed
        preview.tree = parsed.rendered
        parsedSource = source
        pendingMarkdownStyle = textView.hasMarkedText()
        guard !pendingMarkdownStyle, let storage = textView.textStorage else { return }
        defer {
            preview.notice = parsed.rendered.failure
            livePreview.apply(parsed, source: source)
        }
        let newStyles = parsed.nodes.compactMap { node -> NativeMarkdownStyle? in
            let style = NativeMarkdownStyle(range: node.range, kind: node.kind, level: node.level)
            return style.attributes.isEmpty || NSMaxRange(style.range) > storage.length ? nil : style
        }
        let fullRange = NSRange(location: 0, length: storage.length)
        let oldStyles = styles
        styles = newStyles
        let oldKeys = Set(oldStyles.map(\.key))
        let newKeys = Set(newStyles.map(\.key))
        var ranges = (oldStyles.filter { !newKeys.contains($0.key) } + newStyles.filter { !oldKeys.contains($0.key) })
            .map { NSIntersectionRange($0.range, fullRange) }
        if let edited = editedStyleRange {
            let start = max(0, edited.location - 1)
            let end = min(storage.length, NSMaxRange(edited) + 1)
            if end > start { ranges.append(NSRange(location: start, length: end - start)) }
        }
        editedStyleRange = nil
        ranges = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var changed: [NSRange] = []
        for range in ranges {
            if let last = changed.last, NSMaxRange(last) >= range.location {
                changed[changed.count - 1] = NSUnionRange(last, range)
            } else {
                changed.append(range)
            }
        }
        guard !changed.isEmpty else { return }
        isLoading = true
        storage.beginEditing()
        for range in changed {
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ], range: range)
        }
        for style in newStyles {
            var low = 0
            var high = changed.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(changed[middle]) <= style.range.location {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            var index = low
            while index < changed.count, changed[index].location < NSMaxRange(style.range) {
                style.apply(to: storage, range: NSIntersectionRange(changed[index], style.range))
                index += 1
            }
        }
        storage.endEditing()
        isLoading = false
    }

    private func resetMarkdown() {
        livePreview.reset()
        parseTask?.cancel()
        codeTask?.cancel()
        markdown = nil
        preview.tree = nil
        parsedSource = ""
        styles = []
        pendingMarkdownStyle = false
        editedStyleRange = nil
        textView.textStorage?.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ], range: NSRange(location: 0, length: (textView.string as NSString).length))
    }

    func setDarkAppearance(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        livePreview.appearanceChanged(dark)
        scheduleCodeHighlighting()
    }

    private func scheduleCodeHighlighting() {
        codeTask?.cancel()
        guard document?.kind == .text, let document else { return }
        let source = textView.string
        guard source.utf8.count <= OpenDocument.livePreviewSizeLimit else { return }
        let language = document.url.pathExtension.isEmpty ? document.name : document.url.pathExtension
        let dark = isDark
        let currentRevision = revision
        codeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
                let spans = try await Task.detached {
                    try highlightSource(text: source, language: language, dark: dark)
                }.value
                guard let self, !Task.isCancelled, self.revision == currentRevision,
                      !self.textView.hasMarkedText(), let storage = self.textView.textStorage else { return }
                self.isLoading = true
                storage.beginEditing()
                for span in spans {
                    storage.addAttribute(.foregroundColor, value: NSColor(
                        red: CGFloat(span.red) / 255, green: CGFloat(span.green) / 255,
                        blue: CGFloat(span.blue) / 255, alpha: 1),
                        range: NSRange(location: Int(span.start), length: Int(span.length)))
                }
                storage.endEditing()
                self.isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.revision == currentRevision else { return }
                self.preview.notice = "Syntax highlighting failed: \(error.localizedDescription)"
                self.preview.logger.error("Syntax highlighting failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func edit(range: NSRange, text: String) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
    }

    private func updateMatches(wrapped: Bool = false, atEnd: Bool = false) {
        guard let id = document?.id else { return }
        let isValid = engine.validate(options) == nil
        if matchedRevision != revision || matchedOptions != options {
            matches = isValid && !options.query.isEmpty
                ? mappedMatches(engine.matches(
                    in: textView.string, lineSeparator: textView.lineSeparator, options: options, limit: Int(UInt32.max)))
                : []
            matchedRevision = revision
            matchedOptions = options
        }
        let current = matches.firstIndex { $0.range == textView.selectedRange() }
        onFindStatus(
            id,
            FindStatus(
                current: current.map { $0 + 1 } ?? 0,
                total: matches.count,
                isValid: isValid,
                wrapped: wrapped,
                atEnd: atEnd))
    }

    private func mappedMatches(_ found: [SearchEngine.Match]) -> [(search: SearchEngine.Match, range: NSRange)] {
        guard !found.isEmpty else { return [] }
        let source = textView.string as NSString
        let separator = textView.lineSeparator as NSString
        guard separator.length > 0 else { return [] }
        var originalLineStarts = [0]
        var normalizedLineStarts = [0]
        var originalCursor = 0
        var normalizedCursor = 0
        while originalCursor < source.length {
            let searchRange = NSRange(location: originalCursor, length: source.length - originalCursor)
            let range = source.range(of: textView.lineSeparator, options: [], range: searchRange)
            guard range.location != NSNotFound else { break }
            normalizedCursor += range.location - originalCursor + 1
            originalCursor = NSMaxRange(range)
            originalLineStarts.append(originalCursor)
            normalizedLineStarts.append(normalizedCursor)
        }
        let normalizedLength = normalizedCursor + source.length - originalCursor
        let separatorExtra = separator.length - 1
        return found.compactMap { match in
            let lineIndex = match.line - 1
            guard lineIndex >= 0, lineIndex < normalizedLineStarts.count else { return nil }
            let normalizedStart = normalizedLineStarts[lineIndex] + match.column
            let originalStart = originalLineStarts[lineIndex] + match.column
            guard normalizedStart <= normalizedLength else { return nil }
            let normalizedEnd = min(normalizedStart + match.length, normalizedLength)
            var low = 0
            var high = normalizedLineStarts.count
            while low < high {
                let middle = low + (high - low) / 2
                if normalizedLineStarts[middle] <= normalizedEnd {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            let endLine = max(0, low - 1)
            let originalEnd = normalizedEnd + endLine * separatorExtra
            return (match, NSRange(location: originalStart, length: max(0, originalEnd - originalStart)))
        }
    }

    private func step(docId: Int, forward: Bool, wrap: Bool) {
        guard document?.id == docId, !matches.isEmpty else { return }
        let selection = textView.selectedRange()
        let next: Int?
        if forward {
            next = matches.firstIndex { $0.range.location >= NSMaxRange(selection) }
        } else {
            next = matches.lastIndex { NSMaxRange($0.range) <= selection.location }
        }
        guard let index = next ?? (wrap ? (forward ? 0 : matches.count - 1) : nil) else {
            updateMatches(atEnd: true)
            return
        }
        textView.setSelectedRange(matches[index].range)
        textView.scrollRangeToVisible(matches[index].range)
        updateMatches(wrapped: next == nil)
    }

    @objc private func settingsChanged() {
        applySettings()
    }

    private func applySettings() {
        if loadsRemoteMedia != AppSettings.loadRemoteMedia {
            loadsRemoteMedia = AppSettings.loadRemoteMedia
            refreshMedia()
        }
        textView.textContainerInset = NSSize(width: CGFloat(AppSettings.pageLayout.margins.points), height: 16)
        scrollView.hasHorizontalScroller = !AppSettings.wrapLongLines
        textView.isHorizontallyResizable = !AppSettings.wrapLongLines
        scrollView.tile()
    }

    private func explicitAnchorRange(in source: NSString, target: String) -> NSRange? {
        guard !target.isEmpty else { return nil }
        let escapedTarget = NSRegularExpression.escapedPattern(for: target)
        let pattern = #"(?:id|name)\s*=\s*["']?\#(escapedTarget)["'\s/>]"#
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            assertionFailure("Unable to create the explicit-anchor matcher: \(error)")
            return nil
        }
        let range = NSRange(location: 0, length: source.length)
        guard let match = expression.firstMatch(in: source as String, range: range) else { return nil }
        return source.lineRange(for: NSRange(location: match.range.location, length: 0))
    }
}

final class NativeTextView: NSTextView {
    var lineSeparator = "\n"
    var openLink: (Int, Bool) -> Bool = { _, _ in false }
    var updateLiveViews: () -> Void = {}
    var didTrackMouse: () -> Void = {}

    func insertionRect(at position: Int) -> NSRect? {
        guard let layout = layoutManager, let storage = textStorage, let container = textContainer,
              position >= 0, position <= storage.length else { return nil }
        layout.ensureLayout(for: container)
        if position == storage.length, layout.extraLineFragmentTextContainer != nil {
            return layout.extraLineFragmentRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        let count = layout.getLineFragmentInsertionPoints(forCharacterAt: position,
            alternatePositions: false, inDisplayOrder: false, positions: nil, characterIndexes: nil)
        var points = Array(repeating: CGFloat.zero, count: count)
        var indexes = Array(repeating: 0, count: count)
        layout.getLineFragmentInsertionPoints(forCharacterAt: position,
            alternatePositions: false, inDisplayOrder: false, positions: &points, characterIndexes: &indexes)
        guard let index = indexes.firstIndex(of: position) else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: min(position, storage.length - 1))
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(x: textContainerOrigin.x + line.minX + points[index],
            y: textContainerOrigin.y + line.minY, width: 0, height: line.height)
    }

    func trackRenderedSelection(at position: Int, event: NSEvent, in window: NSWindow) {
        let granularity: NSSelectionGranularity = event.clickCount >= 3
            ? .selectByParagraph : event.clickCount == 2 ? .selectByWord : .selectByCharacter
        let clicked = selectionRange(forProposedRange: NSRange(location: position, length: 0), granularity: granularity)
        let previous = selectedRange()
        let anchor = event.modifierFlags.contains(.shift)
            ? NSRange(location: selectionAffinity == .upstream ? NSMaxRange(previous) : previous.location, length: 0)
            : clicked

        func select(_ range: NSRange, tracking: Bool) {
            let selected = NSUnionRange(anchor, range)
            setSelectedRange(selected, affinity: range.location < anchor.location ? .upstream : .downstream,
                stillSelecting: tracking)
        }

        select(clicked, tracking: true)
        var drag: NSEvent?
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: 0.05, mode: .eventTracking) { next, stop in
            if next?.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            if let next { drag = next }
            guard let drag else { return }
            let scrolled = self.autoscroll(with: drag)
            guard next != nil || scrolled else { return }
            let point = self.convert(drag.locationInWindow, from: nil)
            let position = self.characterIndexForInsertion(at: point)
            select(self.selectionRange(forProposedRange: NSRange(location: position, length: 0), granularity: granularity),
                tracking: true)
        }
        setSelectedRange(selectedRange(), affinity: selectionAffinity, stillSelecting: false)
    }

    override func layout() {
        super.layout()
        updateLiveViews()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let location = characterIndexForInsertion(at: point)
            if openLink(location, event.modifierFlags.contains(.shift)) { return }
        }
        super.mouseDown(with: event)
        didTrackMouse()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text: String
        if let attributed = insertString as? NSAttributedString {
            text = attributed.string
        } else if let string = insertString as? String {
            text = string
        } else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: lineSeparator)
        super.insertText(normalized, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        guard paste(from: NSPasteboard.general) else {
            super.paste(sender)
            return
        }
    }

    @discardableResult
    func paste(from pasteboard: NSPasteboard) -> Bool {
        guard let text = pasteboard.string(forType: .string) else { return false }
        insertText(text, replacementRange: selectedRange())
        return true
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, paste(from: pboard) else {
            return super.readSelection(from: pboard, type: type)
        }
        return true
    }
}

private final class NativeEditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        guard AppSettings.wrapLongLines else {
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            return
        }
        let margins = textView.textContainerInset.width * 2
        let width =
            AppSettings.pageLayout.limitsWidth
            ? min(980, contentSize.width - margins)
            : contentSize.width - margins
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: contentSize.width, height: max(textView.frame.height, contentSize.height)))
    }
}
