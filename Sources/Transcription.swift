import AVFoundation
import Foundation
import Metal

final class WhisperModel: @unchecked Sendable {
    let engine: UnsafeMutableRawPointer
    let recognitionQueue = DispatchQueue(label: "local.meetingscribe.whisper", qos: .userInitiated)

    init(url: URL) throws {
        let useGPU = MTLCreateSystemDefaultDevice() != nil
        let backends = ScribeResources.hasBundledEngines ? ScribeResources.backends.path : nil
        guard let engine = scribe_whisper_open(url.path, useGPU, backends) else {
            throw ScribeError("Whisper 한국어 받아쓰기 모델을 열 수 없습니다.")
        }
        self.engine = engine
    }

    deinit { scribe_whisper_close(engine) }
}

final class SpeechChannel: @unchecked Sendable {
    static let sampleRate = 16_000
    static let modelName = "ggml-large-v3-turbo-q5_0.bin"

    static var modelURL: URL {
        if let path = ProcessInfo.processInfo.environment["MEETING_SCRIBE_WHISPER_MODEL"] {
            return URL(fileURLWithPath: path)
        }
        return ScribeResources.model(named: modelName)
    }

    let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
    private let engine: UnsafeMutableRawPointer
    private let model: WhisperModel
    private let glossary: String
    private let (results, output) = AsyncStream.makeStream(of: Segment.self)
    private var reader: Task<Void, Never>?
    // Segmentation state is confined to the serial capture queue.
    private var samples: [Float] = []
    private var segmentStart: Double?
    private var quietSamples = 0
    private var loudSamples = 0
    private let minimumThreshold: Float
    private var noiseFloor: Float = 0

    private struct Segment: Sendable {
        let text: String?
        let seconds: Double
    }

    init(model: WhisperModel, source: Source, glossary: String,
         receive: @escaping @Sendable (String, Double) async -> Void,
         onError: @escaping @Sendable (String) async -> Void) throws {
        guard let engine = scribe_whisper_channel(model.engine) else {
            throw ScribeError("Whisper 입력 채널을 초기화할 수 없습니다.")
        }
        self.engine = engine
        self.model = model
        self.glossary = String(glossary.prefix(400))
        self.minimumThreshold = source == .room ? 0.0015 : 0.001
        let incoming = results
        self.reader = Task {
            for await segment in incoming {
                if let text = segment.text {
                    if !text.isEmpty { await receive(text, segment.seconds) }
                } else {
                    await onError("Whisper가 오디오 구간을 처리하지 못했습니다.")
                }
            }
        }
    }

    deinit { scribe_whisper_end_channel(engine) }

    func append(_ buffer: AVAudioPCMBuffer, endTime: Double) {
        guard let pointer = buffer.floatChannelData?.pointee else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let block = UnsafeBufferPointer(start: pointer, count: count)
        let rms = sqrt(block.reduce(Float(0)) { $0 + $1 * $1 } / Float(count))
        let rate = Self.sampleRate
        let threshold = max(minimumThreshold, noiseFloor * 2.5)
        if rms >= threshold {
            quietSamples = 0
            loudSamples += count
        } else {
            quietSamples += count
            noiseFloor += (rms - noiseFloor) * 0.05
        }
        if segmentStart == nil { segmentStart = max(0, endTime - Double(count) / Double(rate)) }
        samples.append(contentsOf: block)
        if samples.count >= rate * 22 || (samples.count >= rate * 2 && quietSamples >= rate * 8 / 10) {
            flush()
        }
    }

    func flush() {
        let slice = samples
        let seconds = segmentStart ?? 0
        let hasLittleSpeech = loudSamples < Self.sampleRate
        segmentStart = nil
        samples = []
        defer { loudSamples = 0; quietSamples = 0 }
        guard loudSamples >= Self.sampleRate / 6 else { return }
        model.recognitionQueue.async { [self] in
            let text = slice.withUnsafeBufferPointer { buffer in
                scribe_whisper_run(engine, buffer.baseAddress, Int32(buffer.count), glossary).map { String(cString: $0) }
            }
            let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let phrase = cleaned?.trimmingCharacters(in: .punctuationCharacters)
            let boilerplate = ["시청해 주셔서 감사합니다", "시청해주셔서 감사합니다", "구독과 좋아요 부탁드립니다"]
            if hasLittleSpeech, let phrase, boilerplate.contains(phrase) { return }
            output.yield(Segment(text: cleaned, seconds: seconds))
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            model.recognitionQueue.async { continuation.resume() }
        }
        output.finish()
        await reader?.value
    }

    func cancel() {
        output.finish()
        reader?.cancel()
    }
}
