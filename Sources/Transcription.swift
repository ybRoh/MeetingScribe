import AVFoundation
import Foundation
import Metal

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
    private let recognitionQueue = DispatchQueue(label: "local.meetingscribe.whisper", qos: .userInitiated)
    private let (results, output) = AsyncStream.makeStream(of: Segment.self)
    private var reader: Task<Void, Never>?
    // Segmentation state is confined to the serial capture queue.
    private var samples: [Float] = []
    private var segmentStart: Double?
    private var quietSamples = 0
    private var loudSamples = 0
    private let threshold: Float

    private struct Segment: Sendable {
        let text: String?
        let seconds: Double
    }

    init(model: URL, source: Source, useGPU: Bool = true,
         receive: @escaping @Sendable (String, Double) async -> Void,
         onError: @escaping @Sendable (String) async -> Void) throws {
        let useGPU = useGPU && MTLCreateSystemDefaultDevice() != nil
        let engine = ScribeResources.hasBundledEngines
            ? scribe_whisper_open(model.path, useGPU, ScribeResources.backends.path)
            : scribe_whisper_open(model.path, useGPU, nil)
        guard let engine else {
            throw ScribeError("Whisper 한국어 받아쓰기 모델을 열 수 없습니다.")
        }
        self.engine = engine
        self.threshold = source == .room ? 0.0015 : 0.001
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

    deinit { scribe_whisper_close(engine) }

    func append(_ buffer: AVAudioPCMBuffer, endTime: Double) {
        guard let pointer = buffer.floatChannelData?.pointee else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let block = UnsafeBufferPointer(start: pointer, count: count)
        let rms = sqrt(block.reduce(Float(0)) { $0 + $1 * $1 } / Float(count))
        let rate = Self.sampleRate
        if rms >= threshold {
            quietSamples = 0
            loudSamples += count
        } else {
            quietSamples += count
        }
        if segmentStart == nil { segmentStart = max(0, endTime - Double(count) / Double(rate)) }
        samples.append(contentsOf: block)
        if samples.count >= rate * 7 || (samples.count >= rate * 2 && quietSamples >= rate * 7 / 10) {
            flush()
        }
    }

    func flush() {
        let slice = samples
        let seconds = segmentStart ?? 0
        segmentStart = nil
        samples = []
        defer { loudSamples = 0; quietSamples = 0 }
        guard loudSamples >= Self.sampleRate / 6 else { return }
        recognitionQueue.async { [self] in
            let text = slice.withUnsafeBufferPointer { buffer in
                scribe_whisper_run(engine, buffer.baseAddress, Int32(buffer.count)).map { String(cString: $0) }
            }
            output.yield(Segment(text: text?.trimmingCharacters(in: .whitespacesAndNewlines), seconds: seconds))
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            recognitionQueue.async { continuation.resume() }
        }
        output.finish()
        await reader?.value
    }

    func cancel() {
        output.finish()
        reader?.cancel()
    }
}
