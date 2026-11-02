import Foundation

/// Saves the open document when its window or the app loses focus, if enabled in Settings.
final class AutosaveCoordinator {
    private let isEnabled: () -> Bool

    init(isEnabled: @escaping () -> Bool = { AppSettings.autosaveOnFocusLoss }) {
        self.isEnabled = isEnabled
    }

    var enabled: Bool { isEnabled() }

    /// Skips documents with a pending on-disk conflict so focus changes never overwrite another app's edits.
    @discardableResult
    func focusLost(document: OpenDocument?) async -> SaveOutcome {
        guard isEnabled(), let document, document.isDirty, document.diskState == .inSync else { return .notNeeded }
        return await document.save()
    }
}
