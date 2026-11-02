import Observation

nonisolated struct FindStatus: Sendable, Equatable {
    var current = 0
    var total = 0
    var isValid = true
    var wrapped = false
    var atEnd = false
}

/// State of the in-document find bar; matching itself runs in the editor.
@Observable
final class FindBarModel {
    var isVisible = false
    var showsReplace = false
    var query = ""
    var replacement = ""
    var caseSensitive = false
    var regex = false
    var wrap = true
    var focusRequest = 0
    private(set) var status = FindStatus()

    func apply(_ status: FindStatus) {
        self.status = status
    }

    var statusText: String {
        guard !query.isEmpty else { return "" }
        guard status.isValid else { return "Invalid pattern" }
        if status.total == 0 { return "No results" }
        let position = status.current > 0 ? "\(status.current) of \(status.total)" : "\(status.total) results"
        if status.wrapped { return position + " · wrapped" }
        if status.atEnd { return position + " · end" }
        return position
    }
}
