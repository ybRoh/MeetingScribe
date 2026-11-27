import AppKit
import AVFoundation
import Foundation
import Observation
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor @Observable
final class Meeting {
    enum Phase { case idle, preparing, recording, finishing }
    var phase = Phase.idle
    var title = ""
    static let microphoneOnly = "microphone"
    var selection = Meeting.microphoneOnly
    var microphoneID = ""
    var microphones: [AVCaptureDevice] = []
    var availableApps: [NSRunningApplication] = []
    var confirmed = false
    var entries: [Utterance] = []
    var levels: [Source: Double] = [:]
    var draft = ""
    var status = ""
    var modelStatus = Minutes.unavailableReason
    var started: Date?
    var generating = false
    var recovery: MeetingRecovery?
    var recoveryBlocked = false
    var glossary = UserDefaults.standard.string(forKey: "meetingGlossary") ?? "" {
        didSet { UserDefaults.standard.set(glossary, forKey: "meetingGlossary") }
    }

    @ObservationIgnored private var channels: [Source: SpeechChannel] = [:]
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var microphone: MicrophoneCapture?
    @ObservationIgnored private var output: CaptureOutput?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var summarizedIDs: Set<UUID> = []
    @ObservationIgnored private var captureID: UUID?

    var transcript: String { orderedEntries.map(\.line).joined(separator: "\n") }
    /// `entries` is kept in time order on insert (see `receive`), so this is free.
    var orderedEntries: [Utterance] { entries }
    var isMicrophoneOnly: Bool { selection == Self.microphoneOnly }
    var recordingSources: [Source] { isMicrophoneOnly ? [.room] : Source.allCases }
    var hasMaterial: Bool { !entries.isEmpty || !draft.isEmpty }

    func loadRecovery() {
        guard !hasMaterial, recovery == nil, !recoveryBlocked else { return }
        do { recovery = try MeetingRecovery.load() }
        catch is DecodingError {
            do {
                try MeetingRecovery.preserveUnreadable()
                status = "읽을 수 없는 자동 저장본을 별도 파일로 보관했습니다."
            } catch {
                recoveryBlocked = true
                status = "복구 자료 보관: \(error.localizedDescription)"
            }
        } catch {
            recoveryBlocked = true
            status = "복구 자료 읽기: \(error.localizedDescription)"
        }
    }

    func restoreRecovery() {
        guard let recovery else { return }
        title = recovery.title
        entries = recovery.entries.sorted { $0.seconds < $1.seconds }
        draft = recovery.draft
        started = recovery.started
        summarizedIDs = recovery.summarizedIDs
        self.recovery = nil
        status = "자동 저장된 회의를 복구했습니다."
    }

    func discardRecovery() {
        do {
            try MeetingRecovery.remove()
            recovery = nil
        } catch { status = "복구 자료 삭제: \(error.localizedDescription)" }
    }

    @discardableResult
    func checkpoint() -> Bool {
        guard recovery == nil, hasMaterial else { return true }
        guard !recoveryBlocked else { return false }
        do {
            try MeetingRecovery(title: title, entries: entries, draft: draft,
                                started: started, summarizedIDs: summarizedIDs).save()
            return true
        } catch {
            status = "자동 저장: \(error.localizedDescription)"
            return false
        }
    }

    func confirmClosing() -> Bool {
        if phase != .idle || generating {
            let alert = NSAlert()
            alert.messageText = "처리가 진행 중입니다."
            alert.informativeText = "기록 중이면 기록 종료를 누르고, 처리가 끝난 뒤 창을 닫으세요."
            alert.runModal()
            return false
        }
        guard hasMaterial else { return true }
        let alert = NSAlert()
        alert.messageText = "회의록 서기 창을 닫을까요?"
        alert.informativeText = "현재 받아쓰기와 회의록을 자동 저장합니다. 다음 실행에서 복구할 수 있습니다."
        alert.addButton(withTitle: "자동 저장 후 닫기")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn && checkpoint()
    }

    func refresh() {
        availableApps = MeetingCapture.apps()
        microphones = MeetingCapture.microphones()
        if !microphones.contains(where: { $0.uniqueID == microphoneID }) { microphoneID = "" }
        if !isMicrophoneOnly, !availableApps.contains(where: { $0.bundleIdentifier == selection }) {
            selection = Self.microphoneOnly
        }
        modelStatus = Minutes.unavailableReason
    }

    func start() async {
        guard phase == .idle, confirmed, !hasMaterial, recovery == nil, !recoveryBlocked else { return }
        phase = .preparing
        status = "한국어 받아쓰기 모델과 오디오 권한을 준비하는 중…"
        let id = UUID()
        captureID = id
        do {
            let model = SpeechChannel.modelURL
            guard FileManager.default.fileExists(atPath: model.path) else {
                throw ScribeError("한국어 Whisper 모델이 없습니다. 사용 안내의 모델 설치 단계를 확인하세요.")
            }
            let speechModel = try await Task.detached { try WhisperModel(url: model) }.value
            let terms = glossary
            for source in recordingSources {
                let receive: @Sendable (String, Double) async -> Void = { [weak self] text, seconds in
                    await self?.receive(text, seconds: seconds, source: source, id: id)
                }
                let onError: @Sendable (String) async -> Void = { [weak self] message in
                    await self?.report("\(source.rawValue) 받아쓰기: \(message)", id: id)
                }
                channels[source] = try await Task.detached {
                    try SpeechChannel(model: speechModel, source: source, glossary: terms, receive: receive, onError: onError)
                }.value
            }
            let output = CaptureOutput(channels: channels) { [weak self] source, value in
                Task { @MainActor in
                    if self?.captureID == id { self?.levels[source] = value }
                }
            } failure: { [weak self] message, stopped in
                Task { @MainActor in
                    self?.report(message, id: id)
                    if stopped, self?.captureID == id { await self?.stop() }
                }
            }
            self.output = output
            if isMicrophoneOnly {
                microphone = try await MicrophoneCapture.start(deviceID: microphoneID, output: output)
            } else {
                stream = try await MeetingCapture.start(bundleID: selection, microphoneID: microphoneID, output: output)
            }
            started = Date()
            phase = .recording
            status = ""
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { break }
                    self?.queueLiveUpdate()
                }
            }
        } catch {
            for channel in channels.values { channel.cancel() }
            captureID = nil
            channels.removeAll()
            output = nil
            levels.removeAll()
            phase = .idle
            status = error.localizedDescription
        }
    }

    private func report(_ message: String, id: UUID) {
        guard captureID == id else { return }
        status = message
    }

    private func receive(_ text: String, seconds: Double, source: Source, id: UUID) {
        guard captureID == id else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var entry = Utterance(source: source, seconds: seconds, text: text)
        let candidate = entry.comparisonText
        // Only utterances within 6 s on the other channel can be the same speech.
        let nearby = entries.indices(near: seconds, within: 6).filter { entries[$0].source != source }
        if candidate.count >= 8, let match = nearby.last(where: { entries[$0].comparisonText == candidate }) {
            if source == .room { return }
            entry.id = entries[match].id
            entries.remove(at: match)
            entries.insertSorted(entry)
            return
        }
        if nearby.contains(where: { TranscriptSimilarity.matches(entries[$0].comparisonText, candidate) }) {
            entry.overlapsOtherChannel = true
        }
        let firstEntry = entries.isEmpty
        entries.insertSorted(entry)
        if firstEntry { checkpoint() }
    }

    private func queueLiveUpdate() {
        guard phase == .recording, liveTask == nil else { return }
        let pending = orderedEntries.filter { !summarizedIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        liveTask = Task {
            defer { liveTask = nil }
            if await summarize(pending, previous: draft) {
                summarizedIDs.formUnion(pending.map(\.id))
                checkpoint()
            }
        }
    }

    func stop() async {
        guard phase == .recording else { return }
        phase = .finishing
        checkpoint()
        timer?.cancel()
        timer = nil
        // Let an in-flight draft update finish: cancelling it restarts the local
        // model server and redoes the same batch, which makes stopping slower.
        if let stream {
            do { try await stream.stopCapture() }
            catch { status = error.localizedDescription }
        }
        if let microphone { await microphone.stop() }
        if let output {
            let pendingChannels = Array(channels.values)
            await output.queue.flush(pendingChannels)
        }
        for channel in channels.values { await channel.finish() }
        captureID = nil
        channels.removeAll()
        stream = nil
        microphone = nil
        output = nil
        levels.removeAll()
        await liveTask?.value
        checkpoint()
        let pending = orderedEntries.filter { !summarizedIDs.contains($0.id) }
        if !pending.isEmpty {
            if await summarize(pending, previous: draft) { summarizedIDs.formUnion(pending.map(\.id)) }
        } else if entries.isEmpty && status.isEmpty { status = "받아쓴 발언이 없습니다. 선택한 입력의 음량과 권한을 확인하세요." }
        phase = .idle
        checkpoint()
    }

    func regenerate() async {
        guard phase == .idle, !entries.isEmpty, !generating else { return }
        if await summarize(orderedEntries, previous: "") {
            summarizedIDs = Set(entries.map(\.id))
            checkpoint()
        }
    }

    @discardableResult
    private func summarize(_ input: [Utterance], previous: String) async -> Bool {
        modelStatus = Minutes.unavailableReason
        guard modelStatus == nil else { return false }
        generating = true
        defer { generating = false }
        do {
            let result = try await Minutes.update(previous: previous, entries: input, glossary: glossary)
            try Task.checkCancellation()
            draft = result
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled { status = "회의록 생성: \(error.localizedDescription)" }
            return false
        }
    }

    func reset() {
        guard phase == .idle, !generating else { return }
        do { try MeetingRecovery.remove() }
        catch { status = "복구 자료 삭제: \(error.localizedDescription)"; return }
        title = ""
        entries.removeAll()
        summarizedIDs.removeAll()
        draft = ""
        status = ""
        started = nil
        confirmed = false
        refresh()
    }

    func export(includeTranscript: Bool, word: Bool = false) {
        let panel = NSSavePanel()
        let extensionName = word ? "docx" : "md"
        panel.allowedContentTypes = [UTType(filenameExtension: extensionName) ?? .data]
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = (name.isEmpty ? "회의록" : name.replacingOccurrences(of: "/", with: "-")) + "." + extensionName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var body = "# \(name.isEmpty ? "회의록" : name)\n"
        if let started { body += "\n\(started.formatted(date: .abbreviated, time: .shortened))\n" }
        if !draft.isEmpty { body += "\n" + draft + "\n" }
        if includeTranscript { body += "\n## 받아쓰기\n\n" + transcript + "\n" }
        do {
            if word {
                guard let templates = Bundle.main.resourceURL?.appendingPathComponent("Word") else {
                    throw ScribeError("Word 서식 파일을 찾을 수 없습니다.")
                }
                try WordExport.save(body, to: url, templates: templates)
            } else {
                try body.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        catch { status = "파일 저장: \(error.localizedDescription)" }
    }
}

private extension DispatchQueue {
    func flush(_ channels: [SpeechChannel]) async {
        await withCheckedContinuation { continuation in
            async {
                for channel in channels { channel.flush() }
                continuation.resume()
            }
        }
    }
}
