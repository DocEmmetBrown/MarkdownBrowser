import Foundation

/// Balances `startAccessingSecurityScopedResource` with an explicit `stop()`.
final class SecurityScope {
    let url: URL
    private var isAccessing: Bool

    init(url: URL) {
        self.url = url
        isAccessing = url.startAccessingSecurityScopedResource()
    }

    func stop() {
        guard isAccessing else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }
}
