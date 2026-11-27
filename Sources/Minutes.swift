import Foundation

enum Minutes {
    static let modelName = "Qwen3-4B-Q4_K_M.gguf"
    static var executable: URL {
        let bundled = ScribeResources.backends.appendingPathComponent("llama-server")
        return ScribeResources.hasBundledEngines ? bundled : URL(fileURLWithPath: "/opt/homebrew/bin/llama-server")
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

    /// Read once: the prompt file is part of the signed app bundle and never changes at run time.
    private static let instructions: String? = Bundle.main.url(forResource: "MinutesPrompt", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    static func update(previous: String, entries: [Utterance], glossary: String = "") async throws -> String {
        if let reason = unavailableReason { throw ScribeError(reason) }
        var draft = previous
        for batch in MinutesBatches.make(entries) {
            try Task.checkCancellation()
            draft = try await generate(previous: draft, incoming: batch, glossary: glossary)
        }
        return draft
    }

    private static func generate(previous: String, incoming: String, glossary: String) async throws -> String {
        try Task.checkCancellation()
        guard let instructions = Self.instructions else {
            throw ScribeError("회의록 지침 파일을 찾을 수 없습니다.")
        }
        let data = """
            <표기용어>
            \(glossary.prefix(1200))
            </표기용어>
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
        let raw = try await MinutesServer.shared.complete(prompt)
        try Task.checkCancellation()
        let answer = raw.components(separatedBy: "</think>").last ?? raw
        let text = answer.replacingOccurrences(of: "[end of text]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ScribeError("로컬 회의록 모델이 결과를 반환하지 않았습니다.")
        }
        return ToDoList.atEnd(of: text)
    }
}
