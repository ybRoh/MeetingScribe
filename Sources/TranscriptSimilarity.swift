enum TranscriptSimilarity {
    /// True when the two comparison texts differ by at most 20% (Levenshtein distance)
    /// and contain the same digits in the same order.
    ///
    /// Only the diagonal band of width `limit` is evaluated, so the cost is
    /// O(length × limit) instead of O(length²), and two rows are reused instead of
    /// allocating a new row per character.
    static func matches(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let a = Array(first.unicodeScalars), b = Array(second.unicodeScalars)
        let size = max(a.count, b.count)
        let limit = size / 5
        guard min(a.count, b.count) >= 12, size <= 500, abs(a.count - b.count) <= limit,
              a.lazy.filter(isDigit).elementsEqual(b.lazy.filter(isDigit)) else { return false }

        let far = Int.max / 2
        let m = b.count
        var previous = [Int](repeating: far, count: m + 1)
        var current = [Int](repeating: far, count: m + 1)
        for column in 0...min(m, limit) { previous[column] = column }
        for row in 1...a.count {
            let low = max(1, row - limit), high = min(m, row + limit)
            current[low - 1] = low == 1 && row <= limit ? row : far
            var rowMinimum = current[low - 1]
            let left = a[row - 1]
            for column in low...high {
                let substitution = previous[column - 1] + (left == b[column - 1] ? 0 : 1)
                let value = min(substitution, min(previous[column], current[column - 1]) + 1)
                current[column] = value
                if value < rowMinimum { rowMinimum = value }
            }
            if high < m { current[high + 1] = far }
            if rowMinimum > limit { return false }
            swap(&previous, &current)
        }
        return previous[m] <= limit
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.numericType != nil
    }
}
