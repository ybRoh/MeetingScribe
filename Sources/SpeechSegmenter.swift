/// Splits a 16 kHz mono stream into utterance-sized segments for Whisper.
///
/// A segment closes after 0.8 s of quiet (once it is at least 2 s long) or at 22 s.
/// The noise floor follows the quietest 100 ms frame in the last 5 s, so a steady
/// background noise above the minimum threshold (a projector fan, air conditioning)
/// is learned instead of being treated as continuous speech.
struct SpeechSegmenter {
    static let sampleRate = 16_000
    static let maximumSeconds = 22
    private static let frameSamples = sampleRate / 10
    private static let floorFrames = 50
    private static let floorCeiling: Float = 0.05
    private static let floorRisePerFrame: Float = 0.0005

    struct Segment: Sendable {
        let samples: [Float]
        let seconds: Double
        let loudSamples: Int
        /// Whisper often invents a closing phrase for segments with under 1 s of speech.
        var hasLittleSpeech: Bool { loudSamples < SpeechSegmenter.sampleRate }
    }

    let minimumThreshold: Float
    private var samples: [Float] = []
    private var segmentStart: Double?
    private var quietSamples = 0
    private var loudSamples = 0
    private var frameEnergy: Float = 0
    private var frameCount = 0
    private var recentFrames: [Float] = []
    private var nextFrame = 0
    private(set) var noiseFloor: Float = 0

    init(minimumThreshold: Float) {
        self.minimumThreshold = minimumThreshold
        samples.reserveCapacity(Self.sampleRate * Self.maximumSeconds + Self.sampleRate)
        recentFrames.reserveCapacity(Self.floorFrames)
    }

    var threshold: Float { max(minimumThreshold, noiseFloor * 2.5) }

    /// Appends one capture block. Returns a finished segment when this block closes one.
    mutating func append(_ block: UnsafeBufferPointer<Float>, endTime: Double) -> Segment? {
        let count = block.count
        guard count > 0 else { return nil }
        var energy: Float = 0
        for sample in block { energy += sample * sample }
        let rms = (energy / Float(count)).squareRoot()
        if rms >= threshold {
            quietSamples = 0
            loudSamples += count
        } else {
            quietSamples += count
        }
        trackNoise(energy: energy, count: count)
        if segmentStart == nil { segmentStart = max(0, endTime - Double(count) / Double(Self.sampleRate)) }
        samples.append(contentsOf: block)
        let rate = Self.sampleRate
        if samples.count >= rate * Self.maximumSeconds || (samples.count >= rate * 2 && quietSamples >= rate * 8 / 10) {
            return flush()
        }
        return nil
    }

    /// Closes the current segment. Returns nil when it holds too little speech to transcribe.
    mutating func flush() -> Segment? {
        defer {
            samples.removeAll(keepingCapacity: true)
            segmentStart = nil
            loudSamples = 0
            quietSamples = 0
        }
        guard loudSamples >= Self.sampleRate / 6 else { return nil }
        return Segment(samples: samples, seconds: segmentStart ?? 0, loudSamples: loudSamples)
    }

    private mutating func trackNoise(energy: Float, count: Int) {
        frameEnergy += energy
        frameCount += count
        guard frameCount >= Self.frameSamples else { return }
        let frameRMS = (frameEnergy / Float(frameCount)).squareRoot()
        frameEnergy = 0
        frameCount = 0
        if recentFrames.count < Self.floorFrames {
            recentFrames.append(frameRMS)
        } else {
            recentFrames[nextFrame] = frameRMS
            nextFrame = (nextFrame + 1) % Self.floorFrames
        }
        // Fall immediately, rise slowly: speech at the very start of a meeting must not
        // be mistaken for background noise before the window has seen a pause.
        let target = min(recentFrames.min() ?? 0, Self.floorCeiling)
        noiseFloor = target < noiseFloor ? target : min(target, noiseFloor + Self.floorRisePerFrame)
    }
}
