import Foundation

@main
struct Check {
    static func main() throws {
        try checkToDoList()
        try checkRecovery()
        checkSimilarity()
        checkSortedEntries()
        checkMinutesBatches()
        checkSegmenter()
        print("Swift checks passed")
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        if !condition {
            print("FAILED (Check.swift:\(line)): \(message())")
            exit(1)
        }
    }

    static func checkToDoList() throws {
        struct Example: Decodable { let input: String; let expected: String }
        let cases = try JSONDecoder().decode([Example].self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/ToDoCases.json")))
        for example in cases {
            expect(ToDoList.atEnd(of: example.input) == example.expected, "To-Do 정리: \(example.input)")
            expect(ToDoList.atEnd(of: example.expected) == example.expected, "To-Do 정리가 반복 적용에 안정적이지 않음")
        }
    }

    static func checkRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = folder.appendingPathComponent("recovery.json")
        let entry = Utterance(source: .room, seconds: 1.5, text: "금요일에 보고서 검토")
        try MeetingRecovery(title: "품질 회의", entries: [entry], draft: "편집한 초안",
                            started: Date(timeIntervalSince1970: 123), summarizedIDs: [entry.id]).save(to: snapshot)
        let restored = try MeetingRecovery.load(from: snapshot)
        expect(restored?.entries.first?.id == entry.id, "복구 ID")
        expect(restored?.entries.first?.text == entry.text, "복구 본문")
        expect(restored?.draft == "편집한 초안", "복구 초안")
        expect(restored?.summarizedIDs == [entry.id], "복구 요약 ID")
        try MeetingRecovery.remove(at: snapshot)
        expect(try MeetingRecovery.load(from: snapshot) == nil, "복구 파일 삭제")
    }

    static func checkSimilarity() {
        expect(TranscriptSimilarity.matches("제품검사보고서를금요일에작성", "제품검사보고서를금요일까지작성"), "비슷한 문장")
        expect(!TranscriptSimilarity.matches("제품검사보고서를2026년에작성", "제품검사보고서를2027년에작성"), "숫자가 다르면 다른 발언")
        expect(TranscriptSimilarity.matches("짧은말", "짧은말"), "같은 문장")
        expect(!TranscriptSimilarity.matches("짧은말", "짧은말이"), "12자 미만은 비교 안 함")
        expect(!TranscriptSimilarity.matches("다음주월요일까지견적서를보내주세요", "오늘회의는여기서마치겠습니다감사합니다"),
               "전혀 다른 문장")
        // 20% 경계: 15자 기준 허용 편집 3회
        let base = "가나다라마바사아자차카타파하거"
        expect(TranscriptSimilarity.matches(base, "가나다라마바사아자차카타파너더러".prefix(15).description) ==
               (levenshtein(base, "가나다라마바사아자차카타파너더러".prefix(15).description) <= 3), "경계값")
        expect(TranscriptSimilarity.matches(base, "X나다라마바Y아자차Z타파하거"), "편집 3회 허용")
        expect(!TranscriptSimilarity.matches(base, "X나다W마바Y아자차Z타파하거"), "편집 4회 거부")
        let long = String(repeating: "회의록", count: 167)  // 501자
        expect(!TranscriptSimilarity.matches(long, long + "가"), "500자 초과는 비교 안 함")
    }

    static func levenshtein(_ first: String, _ second: String) -> Int {
        let a = Array(first), b = Array(second)
        var previous = Array(0...b.count)
        for (row, left) in a.enumerated() {
            var current = [row + 1]
            for (column, right) in b.enumerated() {
                current.append(min(previous[column + 1] + 1, current[column] + 1, previous[column] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    static func checkSortedEntries() {
        var entries: [Utterance] = []
        for (seconds, text) in [(5.0, "c"), (1.0, "a"), (9.0, "e"), (5.0, "d"), (3.0, "b")] {
            entries.insertSorted(Utterance(source: .room, seconds: seconds, text: text))
        }
        expect(entries.map(\.text) == ["a", "b", "c", "d", "e"], "정렬 삽입 순서: \(entries.map(\.text))")
        expect(entries.map(\.seconds) == entries.map(\.seconds).sorted(), "시간순 유지")
        // 같은 시각이면 먼저 들어온 발언이 앞에 온다.
        expect(entries[2].text == "c" && entries[3].text == "d", "동시각 도착 순서 유지")

        // indices(near:within:) == 원래 쓰던 abs(차이) < 6 조건
        var random = SystemRandomNumberGenerator()
        var sample: [Utterance] = []
        for _ in 0..<400 {
            sample.insertSorted(Utterance(source: .room, seconds: Double(Int.random(in: 0...600, using: &random)) / 2, text: "x"))
        }
        for probe in stride(from: -10.0, through: 320.0, by: 0.5) {
            let expected = sample.indices.filter { abs(sample[$0].seconds - probe) < 6 }
            let window = Array(sample.indices(near: probe, within: 6))
            expect(window == expected, "시간창 검색 \(probe)")
        }
        expect([Utterance]().indices(near: 3, within: 6).isEmpty, "빈 목록")
    }

    static func checkMinutesBatches() {
        let entries = (0..<200).map { Utterance(source: .room, seconds: Double($0) * 4, text: "발언 내용 \($0) " + String(repeating: "가", count: $0 % 60)) }
        let batches = MinutesBatches.make(entries)
        expect(batches.allSatisfy { $0.count <= 3000 }, "배치 길이 한도")
        expect(batches.joined() == entries.map { $0.line + "\n" }.joined(), "배치가 모든 줄을 순서대로 보존")
        expect(batches.allSatisfy { $0.hasSuffix("\n") }, "줄 단위로만 나뉨")

        let huge = Utterance(source: .online, seconds: 0, text: String(repeating: "긴", count: 6000))
        let pieces = MinutesBatches.make([huge])
        expect(pieces.joined().replacingOccurrences(of: "\n", with: "") == huge.line, "긴 발언도 내용 보존")
        expect(pieces.allSatisfy { $0.count <= 3000 }, "긴 발언도 한도 이내")
        expect(MinutesBatches.make([]).isEmpty, "빈 입력")
    }

    // MARK: - Voice activity segmentation

    struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Float {  // uniform in [-1, 1)
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 23) - 1
        }
    }

    /// Feeds `parts` (seconds, rms) through the segmenter in ~21 ms capture blocks.
    /// Levels at or above `voiced` are shaped like speech: 0.35 s words with 0.12 s
    /// gaps at 15% level, since constant-level sound is indistinguishable from noise.
    static func segments(minimum: Float, _ parts: [(Double, Float)], voiced: Float = 0.02) -> [SpeechSegmenter.Segment] {
        var segmenter = SpeechSegmenter(minimumThreshold: minimum)
        var noise = Noise()
        var output: [SpeechSegmenter.Segment] = []
        var clock = 0.0
        let block = 341
        let uniformRMS = Float(1 / 3.0.squareRoot())
        for (seconds, rms) in parts {
            let start = clock
            var remaining = Int(seconds * Double(SpeechSegmenter.sampleRate))
            while remaining > 0 {
                let count = min(block, remaining)
                let phase = (clock - start).truncatingRemainder(dividingBy: 0.47)
                let level = rms >= voiced && phase > 0.35 ? rms * 0.15 : rms
                let samples = (0..<count).map { _ in noise.next() * level / uniformRMS }
                remaining -= count
                clock += Double(count) / Double(SpeechSegmenter.sampleRate)
                if let segment = samples.withUnsafeBufferPointer({ segmenter.append($0, endTime: clock) }) {
                    output.append(segment)
                }
            }
        }
        if let segment = segmenter.flush() { output.append(segment) }
        return output
    }

    static func seconds(_ segment: SpeechSegmenter.Segment) -> Double {
        Double(segment.samples.count) / Double(SpeechSegmenter.sampleRate)
    }

    static func checkSegmenter() {
        let quiet: Float = 0.0005, speech: Float = 0.05, fan: Float = 0.004

        expect(segments(minimum: 0.0015, [(10, quiet)]).isEmpty, "무음은 받아쓰지 않음")
        expect(segments(minimum: 0.0015, [(2, quiet), (0.1, speech), (2, quiet)]).isEmpty, "0.1초 잡음은 버림")

        let calm = segments(minimum: 0.0015, [(1, quiet), (3, speech), (1.5, quiet), (3, speech), (1.5, quiet), (3, speech), (1.5, quiet)])
        expect(calm.count == 3, "조용한 방: 발언 3개 → 구간 \(calm.count)개")
        expect(calm.allSatisfy { seconds($0) < 5.5 }, "조용한 방: 구간 길이 \(calm.map(seconds))")
        expect(abs(calm[0].seconds - 0) < 0.05 && abs(calm[1].seconds - 4.8) < 0.3, "구간 시작 시각 \(calm.map(\.seconds))")

        // 이전 구현은 최소 기준(0.0015)을 넘는 상시 소음에서 소음 바닥을 배우지 못해
        // 발언 사이를 끊지 못하고 22초마다 한 덩어리로 보냈다.
        var noisy: [(Double, Float)] = [(2, fan)]
        for _ in 0..<5 { noisy += [(3, speech), (1.5, fan)] }
        // 시작 직후 소음 바닥을 배우는 1초 미만 동안은 소음 구간이 하나 생길 수 있다
        // (짧은 구간으로 표시되며 Whisper 무음 판정이 걸러 낸다).
        var fanSegments = segments(minimum: 0.0015, noisy)
        if let first = fanSegments.first, first.seconds < 0.1, first.hasLittleSpeech { fanSegments.removeFirst() }
        expect(fanSegments.count == 5, "상시 소음: 발언 5개 → 구간 \(fanSegments.count)개 \(fanSegments.map(seconds))")
        expect(fanSegments.allSatisfy { seconds($0) < 6 }, "상시 소음: 구간 길이 \(fanSegments.map(seconds))")

        // 회의 시작과 동시에 말해도 첫 발언이 소음으로 학습되지 않아야 한다.
        let immediate = segments(minimum: 0.0015, [(6, speech), (1.5, quiet)])
        expect(immediate.count == 1 && immediate[0].loudSamples >= SpeechSegmenter.sampleRate * 4,
               "즉시 발언: \(immediate.map { $0.loudSamples })")

        let monologue = segments(minimum: 0.0015, [(50, speech)])
        expect(monologue.count == 3 && monologue.dropLast().allSatisfy { seconds($0) <= 22.05 },
               "긴 발언은 22초 단위: \(monologue.map(seconds))")

        let short = segments(minimum: 0.0015, [(1, quiet), (0.5, speech), (1.5, quiet)])
        expect(short.count == 1 && short[0].hasLittleSpeech, "짧은 발언 표시")
    }
}
