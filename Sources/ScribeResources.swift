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
        return Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("models").appendingPathComponent(name)
    }
}
