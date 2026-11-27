import Foundation

enum Source: String, CaseIterable, Codable, Sendable {
    case room = "회의실"
    case online = "온라인"
}

struct Utterance: Identifiable, Codable, Sendable {
    var id = UUID()
    let source: Source
    let seconds: Double
    let text: String
    var overlapsOtherChannel: Bool? = nil

    var line: String {
        let time = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", time / 60, time % 60) + " [\(source.rawValue)] " + (overlapsOtherChannel == true ? "[중복 가능] " : "") + text
    }

    var comparisonText: String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// Helpers for an array kept in ascending `seconds` order, so the view and the
/// minutes never have to sort the whole transcript again.
extension Array where Element == Utterance {
    /// First index whose time is not less than `seconds` (strict: `after` skips equal times).
    func boundary(for seconds: Double, after: Bool = false) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if after ? self[middle].seconds <= seconds : self[middle].seconds < seconds {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// Inserts after any entries with the same time, keeping arrival order for ties.
    mutating func insertSorted(_ entry: Utterance) {
        insert(entry, at: boundary(for: entry.seconds, after: true))
    }

    /// Indices of entries whose time is strictly within `window` seconds of `seconds`.
    func indices(near seconds: Double, within window: Double) -> Range<Int> {
        let low = boundary(for: seconds - window, after: true)
        return low..<Swift.max(low, boundary(for: seconds + window))
    }
}
