import Foundation

@main
struct Check {
    static func main() throws {
        struct Example: Decodable { let input: String; let expected: String }
        let cases = try JSONDecoder().decode([Example].self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/ToDoCases.json")))
        for example in cases {
            precondition(ToDoList.atEnd(of: example.input) == example.expected)
            precondition(ToDoList.atEnd(of: example.expected) == example.expected)
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = folder.appendingPathComponent("recovery.json")
        let entry = Utterance(source: .room, seconds: 1.5, text: "금요일에 보고서 검토")
        try MeetingRecovery(title: "품질 회의", entries: [entry], draft: "편집한 초안",
                            started: Date(timeIntervalSince1970: 123), summarizedIDs: [entry.id]).save(to: snapshot)
        let restored = try MeetingRecovery.load(from: snapshot)
        precondition(restored?.entries.first?.id == entry.id)
        precondition(restored?.entries.first?.text == entry.text)
        precondition(restored?.draft == "편집한 초안")
        precondition(restored?.summarizedIDs == [entry.id])
        try MeetingRecovery.remove(at: snapshot)
        let deleted = try MeetingRecovery.load(from: snapshot)
        precondition(deleted == nil)

        precondition(TranscriptSimilarity.matches("제품검사보고서를금요일에작성", "제품검사보고서를금요일까지작성"))
        precondition(!TranscriptSimilarity.matches("제품검사보고서를2026년에작성", "제품검사보고서를2027년에작성"))
        print("Swift checks passed")
    }
}
