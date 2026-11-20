import Foundation

/// Fuzzy matching, case-insensitive unless asked otherwise: the query's characters must appear in the candidate in
/// order, and alignments that are consecutive, start words and leave fewer gaps score higher ("rdm" → "README.md").
nonisolated struct FuzzyMatcher: Sendable {
    private let query: [Unicode.Scalar]
    private let caseSensitive: Bool

    private static let matchScore = 16
    private static let boundaryBonus = 10
    private static let consecutiveBonus = 12
    private static let gapOpen = 4
    private static let gapExtend = 1
    private static let maxLeadingPenalty = 6
    private static let impossible = Int.min / 2

    /// `nil` when there's nothing to match: the query is empty or only whitespace.
    init?(query: String, caseSensitive: Bool = false) {
        let scalars = query.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return nil }
        self.query = caseSensitive ? Array(scalars) : scalars.map(Self.lowercased)
        self.caseSensitive = caseSensitive
    }

    /// Whether the query is a path (contains "/"), to be matched against whole paths rather than names.
    var isPathQuery: Bool { query.contains("/") }

    /// How well `candidate` matches, or `nil` when it doesn't. Only comparable between candidates of one query.
    func score(_ candidate: String) -> Int? {
        guard isSubsequence(candidate) else { return nil }
        let original = Array(candidate.unicodeScalars)
        let lowered = caseSensitive ? original : original.map(Self.lowercased)
        let count = original.count
        let none = Self.impossible

        // `previous[i]` is the best score of matching the query up to the previous character, ending at candidate i.
        var previous = [Int](repeating: none, count: count)
        var current = previous
        for (row, wanted) in query.enumerated() {
            var gapBest = none
            for i in 0..<count {
                // Best score ending at any earlier, non-adjacent position, minus the cost of skipping to here.
                if i >= 2 { gapBest = max(gapBest - Self.gapExtend, previous[i - 2] - Self.gapOpen) }
                guard lowered[i] == wanted else {
                    current[i] = none
                    continue
                }
                let bonus = Self.matchScore + (Self.isBoundary(original, i) ? Self.boundaryBonus : 0)
                if row == 0 {
                    current[i] = bonus - min(i, Self.maxLeadingPenalty)
                } else {
                    var best = gapBest
                    if i >= 1 { best = max(best, previous[i - 1] + Self.consecutiveBonus) }
                    current[i] = best + bonus
                }
            }
            swap(&previous, &current)
        }
        guard let best = previous.max(), best > none / 2 else { return nil }
        return best
    }

    private func isSubsequence(_ candidate: String) -> Bool {
        var next = 0
        for scalar in candidate.unicodeScalars where (caseSensitive ? scalar : Self.lowercased(scalar)) == query[next] {
            next += 1
            if next == query.count { return true }
        }
        return false
    }

    private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.isASCII {
            return scalar.value >= 65 && scalar.value <= 90 ? Unicode.Scalar(scalar.value + 32)! : scalar
        }
        let mapped = scalar.properties.lowercaseMapping.unicodeScalars
        return mapped.count == 1 ? mapped.first! : scalar
    }

    /// The start of a word: after a separator or, in camelCase, at an uppercase letter that follows a lowercase one.
    private static func isBoundary(_ scalars: [Unicode.Scalar], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = scalars[index - 1]
        if !previous.properties.isAlphabetic && previous.properties.numericType == nil { return true }
        return previous.properties.isLowercase && scalars[index].properties.isUppercase
    }
}
