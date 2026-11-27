import Foundation

enum ScribeResources {
    private static let frameworks = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Frameworks", isDirectory: true)

    static var hasBundledEngines: Bool {
        FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("libggml.1.dylib").path)
    }

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
