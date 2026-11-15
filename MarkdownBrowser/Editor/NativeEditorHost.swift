import AppKit
import SwiftUI

struct NativeEditorView: NSViewRepresentable {
    let host: NativeEditorHost

    func makeNSView(context: Context) -> NSScrollView {
        host.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

final class NativeEditorHost: NSObject, WorkspaceEditor, NSTextViewDelegate {
    let textView: NativeTextView
    let scrollView: NSScrollView

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
    private var isLoading = false
    private let engine = SearchEngine()

    override init() {
        textView = NativeTextView(usingTextLayoutManager: true)
        scrollView = NativeEditorScrollView()
        super.init()
        textView.delegate = self
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
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        textView.textContainerInset = NSSize(width: CGFloat(AppSettings.pageLayout.margins.points), height: 16)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: UserDefaults.didChangeNotification, object: nil)
        applySettings()
    }

    func load(_ document: OpenDocument, rootURL: URL?, anchor: String?) {
        self.document = document
        savedText = document.content.text
        textView.lineSeparator = document.content.lineSeparator
        isLoading = true
        textView.string = document.recoveryText ?? savedText
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        isLoading = false
        snapshots.removeAll()
        revision += 1
        options.query = ""
        updateMatches()
        if let anchor {
            scrollToAnchor(anchor)
        } else {
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    func setSourceMode(_ on: Bool) {}

    func scrollToAnchor(_ fragment: String) {
        let decodedTarget = fragment.removingPercentEncoding ?? fragment
        let target = decodedTarget.hasPrefix("user-content-")
            ? String(decodedTarget.dropFirst("user-content-".count))
            : decodedTarget
        let normalizedTarget = target.lowercased()
        let source = textView.string as NSString
        var lines: [(text: String, range: NSRange)] = []
        var location = 0
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            lines.append((source.substring(with: range).trimmingCharacters(in: .newlines), range))
            location = NSMaxRange(range)
        }

        var inFence: (character: Character, length: Int)?
        var usedSlugs = Set<String>()
        for index in lines.indices {
            let line = lines[index].text
            if let activeFence = inFence {
                if selfFenceEndMatches(activeFence, line: line) { inFence = nil }
                continue
            }
            let fence = fenceMarker(in: line)
            if let fence {
                inFence = fence
                continue
            }

            let heading: (String, NSRange)?
            if let parsed = atxHeading(in: line) {
                heading = (parsed, lines[index].range)
            } else if index + 1 < lines.count, isSetextUnderline(lines[index + 1].text) {
                heading = (line.trimmingCharacters(in: .whitespaces), lines[index].range)
            } else {
                heading = nil
            }
            guard let (text, range) = heading else { continue }
            let base = githubSlug(headingPlainText(text))
            var slug = base
            var duplicate = 0
            while usedSlugs.contains(slug) {
                duplicate += 1
                slug = "\(base)-\(duplicate)"
            }
            usedSlugs.insert(slug)
            if slug == normalizedTarget {
                textView.setSelectedRange(NSRange(location: range.location, length: 0))
                textView.scrollRangeToVisible(range)
                return
            }
        }

        guard let range = explicitAnchorRange(in: source, target: target) else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
    }

    func reveal(docId: Int, line: Int, column: Int, length: Int) {
        guard document?.id == docId else { return }
        let match = SearchEngine.Match(line: line, column: column, length: length)
        guard let range = mappedMatches([match]).first?.range else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    func refreshMedia() {}

    func focus() {
        textView.window?.makeFirstResponder(textView)
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
        textView.lineSeparator = document?.content.lineSeparator ?? textView.lineSeparator
        textView.undoManager?.removeAllActions()
        isLoading = false
        savedText = text
        snapshots.removeAll()
        revision += 1
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
        revision += 1
        reportChanges()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateMatches()
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

    private func edit(range: NSRange, text: String) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
    }

    private func updateMatches(wrapped: Bool = false, atEnd: Bool = false) {
        guard let id = document?.id else { return }
        let isValid = engine.validate(options) == nil
        matches = isValid
            ? mappedMatches(engine.matches(
                in: textView.string, lineSeparator: textView.lineSeparator, options: options, limit: 10_000))
            : []
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
        textView.textContainerInset = NSSize(width: CGFloat(AppSettings.pageLayout.margins.points), height: 16)
        scrollView.hasHorizontalScroller = !AppSettings.wrapLongLines
        textView.isHorizontallyResizable = !AppSettings.wrapLongLines
        textView.textContainer?.widthTracksTextView = AppSettings.wrapLongLines
        textView.textContainer?.containerSize = NSSize(
            width: AppSettings.wrapLongLines ? scrollView.contentSize.width : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude)
        scrollView.tile()
    }

    private func atxHeading(in line: String) -> String? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let content = String(line.dropFirst(indent))
        let hashes = content.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let remainder = String(content.dropFirst(hashes))
        guard remainder.isEmpty || remainder.first == " " || remainder.first == "\t" else { return nil }
        let heading = remainder.trimmingCharacters(in: .whitespaces)
        return heading.replacingOccurrences(
            of: "[ \\t]+#+[ \\t]*$",
            with: "",
            options: .regularExpression)
    }

    private func isSetextUnderline(_ line: String) -> Bool {
        let content = line.trimmingCharacters(in: .whitespaces)
        guard let marker = content.first, marker == "=" || marker == "-" else { return false }
        return content.allSatisfy { $0 == marker }
    }

    private func fenceMarker(in line: String) -> (character: Character, length: Int)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let content = line.dropFirst(indent)
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let count = content.prefix(while: { $0 == marker }).count
        return count >= 3 ? (marker, count) : nil
    }

    private func selfFenceEndMatches(_ fence: (character: Character, length: Int), line: String) -> Bool {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return false }
        let content = line.dropFirst(indent)
        let count = content.prefix(while: { $0 == fence.character }).count
        guard count >= fence.length else { return false }
        return content.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private func headingPlainText(_ source: String) -> String {
        var text = source
        for (pattern, replacement) in [
            ("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
            ("!?\\[([^\\]]*)\\]\\[[^\\]]*\\]", "$1"),
            ("<[^>]+>", ""),
            ("[*_~`]", ""),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func githubSlug(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber,
                .connectorPunctuation:
                true
            default:
                scalar == "-" || scalar == " "
            }
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: " ", with: "-")
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
