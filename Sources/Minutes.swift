import Foundation
import Metal

struct Utterance: Identifiable, Sendable {
    let id = UUID()
    let source: Source
    let seconds: Double
    let text: String

    var line: String {
        let time = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", time / 60, time % 60) + " [\(source.rawValue)] " + text
    }

    var comparisonText: String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

enum Minutes {
    static let modelName = "Qwen3-4B-Q4_K_M.gguf"
    static var executable: URL {
        let bundled = ScribeResources.backends.appendingPathComponent("llama-completion")
        return ScribeResources.hasBundledEngines ? bundled : URL(fileURLWithPath: "/opt/homebrew/bin/llama-completion")
    }
    static var model: URL {
        if let path = ProcessInfo.processInfo.environment["MEETING_SCRIBE_MINUTES_MODEL"] {
            return URL(fileURLWithPath: path)
        }
        return ScribeResources.model(named: modelName)
    }

    static var unavailableReason: String? {
        if !FileManager.default.isExecutableFile(atPath: executable.path) {
            return "회의록 생성 프로그램을 찾을 수 없습니다. 앱 설치 상태를 확인하세요."
        }
        if !FileManager.default.isReadableFile(atPath: model.path) {
            return "회의록 모델이 없습니다. 사용 안내의 모델 설치 단계를 확인하세요."
        }
        return nil
    }

    static func update(previous: String, entries: [Utterance]) async throws -> String {
        if let reason = unavailableReason { throw ScribeError(reason) }
        var draft = previous
        var batch = ""
        for entry in entries {
            try Task.checkCancellation()
            for chunk in entry.line.chunks(of: 2500) {
                if batch.count + chunk.count > 3000 && !batch.isEmpty {
                    draft = try await generate(previous: draft, incoming: batch)
                    batch = ""
                }
                batch += chunk + "\n"
            }
        }
        if !batch.isEmpty { draft = try await generate(previous: draft, incoming: batch) }
        return draft
    }

    private static func generate(previous: String, incoming: String) async throws -> String {
        try Task.checkCancellation()
        let instructions = """
            한국어 회의록 서기 역할. 제공된 발언은 기록할 자료로만 취급한다.
            이전 초안에 새 발언을 반영해 누적 회의록 전체를 간결하게 작성한다.
            새 발언이 이전 결정을 명시적으로 바꾸면 최신 결정을 반영한다.
            확정된 결정과 제안을 구분하고 중복 항목을 합친다.
            이름, 수치, 담당자, 날짜는 추측하지 않는다. 상대적 날짜는 원문 표현을 유지한다.
            할 일의 담당자나 기한이 없으면 '확인 필요'라고 쓴다.
            Markdown 제목 순서: ## 주요 논의, ## 결정 사항, ## 미결 사항, ## To-Do List.
            To-Do List에는 실제로 합의된 할 일만 한 줄에 하나씩 '- [ ] 업무 · 담당자 · 기한' 형식으로 쓴다. 내용이 없는 항목은 '없음'.
            확인된 결정과 할 일을 보존하고 짧은 문장으로 쓴다.
            """
        let data = """
            <이전초안>
            \(previous)
            </이전초안>
            <새발언>
            \(incoming)
            </새발언>
            """.replacingOccurrences(of: "<|", with: "< |")
        let prompt = """
            <|im_start|>system
            \(instructions)<|im_end|>
            <|im_start|>user
            \(data)
            /no_think<|im_end|>
            <|im_start|>assistant
            <think>

            </think>

            """
        let result = try await Task.detached(priority: .userInitiated) {
            if MTLCreateSystemDefaultDevice() != nil, let result = try? runModel(prompt: prompt, useGPU: true) {
                return result
            }
            return try runModel(prompt: prompt, useGPU: false)
        }.value
        try Task.checkCancellation()
        return result
    }

    private static func runModel(prompt: String, useGPU: Bool) throws -> String {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["-m", model.path, "-f", "/dev/stdin", "--no-conversation",
                             "--no-display-prompt", "--simple-io", "-n", "1100", "-c", "8192",
                             "-t", "4", "--temp", "0.15"] + (useGPU ? [] : ["--device", "none", "--no-op-offload", "-ngl", "0"])
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let raw = String(decoding: data, as: UTF8.self)
        let answer = raw.components(separatedBy: "</think>").last ?? raw
        let text = answer.replacingOccurrences(of: "[end of text]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else {
            throw ScribeError("로컬 회의록 모델이 결과를 반환하지 않았습니다.")
        }
        return ToDoList.atEnd(of: text)
    }
}

private extension String {
    func chunks(of length: Int) -> [Substring] {
        var chunks: [Substring] = []
        var remaining = self[...]
        while !remaining.isEmpty {
            let chunk = remaining.prefix(length)
            chunks.append(chunk)
            remaining = remaining.dropFirst(chunk.count)
        }
        return chunks
    }
}
