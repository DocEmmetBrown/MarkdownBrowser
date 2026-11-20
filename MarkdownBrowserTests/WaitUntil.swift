import Testing

/// Polls `condition` until it holds, recording an issue at the caller if it still fails after `timeout`.
func waitUntil(
    timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while try !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Condition still false after \(timeout)", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
