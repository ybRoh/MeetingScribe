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
