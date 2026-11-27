import AppKit
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
    var availableApps: [NSRunningApplication] = []
    var confirmed = false
    var entries: [Utterance] = []
    var levels: [Source: Double] = [:]
    var draft = ""
    var status = ""
    var modelStatus = Minutes.unavailableReason
    var started: Date?
    var generating = false

    @ObservationIgnored private var channels: [Source: SpeechChannel] = [:]
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var microphone: MicrophoneCapture?
    @ObservationIgnored private var output: CaptureOutput?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var summarizedIDs: Set<UUID> = []
    @ObservationIgnored private var captureID: UUID?

    var transcript: String { orderedEntries.map(\.line).joined(separator: "\n") }
    var orderedEntries: [Utterance] { entries.sorted { $0.seconds < $1.seconds } }
    var isMicrophoneOnly: Bool { selection == Self.microphoneOnly }
    var recordingSources: [Source] { isMicrophoneOnly ? [.room] : Source.allCases }
    var hasMaterial: Bool { !entries.isEmpty || !draft.isEmpty }

    func refresh() {
        availableApps = MeetingCapture.apps()
        if !isMicrophoneOnly, !availableApps.contains(where: { $0.bundleIdentifier == selection }) {
            selection = Self.microphoneOnly
        }
        modelStatus = Minutes.unavailableReason
    }

    func start() async {
        guard phase == .idle, confirmed, !hasMaterial else { return }
        phase = .preparing
        status = "한국어 받아쓰기 모델과 오디오 권한을 준비하는 중…"
        let id = UUID()
        captureID = id
        do {
            let model = SpeechChannel.modelURL
            guard FileManager.default.fileExists(atPath: model.path) else {
                throw ScribeError("한국어 Whisper 모델이 없습니다. 사용 안내의 모델 설치 단계를 확인하세요.")
            }
            for source in recordingSources {
                let receive: @Sendable (String, Double) async -> Void = { [weak self] text, seconds in
                    await self?.receive(text, seconds: seconds, source: source, id: id)
                }
                let onError: @Sendable (String) async -> Void = { [weak self] message in
                    await self?.report("\(source.rawValue) 받아쓰기: \(message)", id: id)
                }
                channels[source] = try await Task.detached {
                    try SpeechChannel(model: model, source: source, receive: receive, onError: onError)
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
                microphone = try await MicrophoneCapture.start(output: output)
            } else {
                stream = try await MeetingCapture.start(bundleID: selection, output: output)
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
        let entry = Utterance(source: source, seconds: seconds, text: text)
        // Prefer the digital feed when identical text also reaches the room microphone.
        if entry.comparisonText.count >= 8 {
            let matches: (Utterance) -> Bool = {
                $0.source != source && abs($0.seconds - seconds) < 6 && $0.comparisonText == entry.comparisonText
            }
            if source == .room, entries.contains(where: matches) { return }
            if source == .online { entries.removeAll(where: matches) }
        }
        entries.append(entry)
    }

    private func queueLiveUpdate() {
        guard phase == .recording, liveTask == nil else { return }
        let pending = orderedEntries.filter { !summarizedIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        liveTask = Task {
            defer { liveTask = nil }
            if await summarize(pending, previous: draft) { summarizedIDs.formUnion(pending.map(\.id)) }
        }
    }

    func stop() async {
        guard phase == .recording else { return }
        phase = .finishing
        timer?.cancel()
        timer = nil
        liveTask?.cancel()
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
        if !entries.isEmpty { await summarize(orderedEntries, previous: "") }
        else if status.isEmpty { status = "받아쓴 발언이 없습니다. 선택한 입력의 음량과 권한을 확인하세요." }
        phase = .idle
    }

    func regenerate() async {
        guard phase == .idle, !entries.isEmpty, !generating else { return }
        await summarize(orderedEntries, previous: "")
    }

    @discardableResult
    private func summarize(_ input: [Utterance], previous: String) async -> Bool {
        modelStatus = Minutes.unavailableReason
        guard modelStatus == nil else { return false }
        generating = true
        defer { generating = false }
        do {
            let result = try await Minutes.update(previous: previous, entries: input)
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
        title = ""
        entries.removeAll()
        summarizedIDs.removeAll()
        draft = ""
        status = ""
        started = nil
        confirmed = false
        refresh()
    }

    func export(includeTranscript: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = (name.isEmpty ? "회의록" : name.replacingOccurrences(of: "/", with: "-")) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var body = "# \(name.isEmpty ? "회의록" : name)\n"
        if let started { body += "\n\(started.formatted(date: .abbreviated, time: .shortened))\n" }
        if !draft.isEmpty { body += "\n" + draft + "\n" }
        if includeTranscript { body += "\n## 받아쓰기\n\n" + transcript + "\n" }
        do { try body.write(to: url, atomically: true, encoding: .utf8) }
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
