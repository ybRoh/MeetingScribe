enum TranscriptSimilarity {
    static func matches(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let a = Array(first), b = Array(second)
        let size = max(a.count, b.count)
        let limit = size / 5
        guard min(a.count, b.count) >= 12, size <= 500, abs(a.count - b.count) <= limit,
              a.filter(\.isNumber) == b.filter(\.isNumber) else { return false }
        var previous = Array(0...b.count)
        for (r, left) in a.enumerated() {
            var row = [r + 1]
            row.reserveCapacity(b.count + 1)
            for (c, right) in b.enumerated() {
                row.append(min(previous[c + 1] + 1, row[c] + 1, previous[c] + (left == right ? 0 : 1)))
            }
            if row.min()! > limit { return false }
            previous = row
        }
        return previous[b.count] <= limit
    }
}
