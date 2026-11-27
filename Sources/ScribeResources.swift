import Foundation

enum ScribeResources {
    private static let frameworks = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Frameworks", isDirectory: true)

    static var hasBundledEngines: Bool {
        FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("libggml.1.dylib").path)
    }

    /// Performance-core count on Apple Silicon (efficiency cores slow down inference),
    /// capped at 8 because Whisper and llama.cpp stop scaling beyond that.
    static let computeThreads: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 {
            return Int(min(cores, 8))
        }
        return max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
    }()

    static var backends: URL {
        frameworks
    }

    static func model(named name: String) -> URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("models").appendingPathComponent(name)
        if let bundled, FileManager.default.isReadableFile(atPath: bundled.path) { return bundled }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("models").appendingPathComponent(name)
        if FileManager.default.isReadableFile(atPath: sibling.path) { return sibling }
        let installed = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MeetingScribe/Models").appendingPathComponent(name)
        if let installed, FileManager.default.isReadableFile(atPath: installed.path) { return installed }
        return sibling
    }
}
