import Foundation

struct MeetingRecovery: Codable {
    let title: String
    let entries: [Utterance]
    let draft: String
    let started: Date?
    let summarizedIDs: Set<UUID>

    private static func file() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingScribe", isDirectory: true)
            .appendingPathComponent("recovery.json")
    }

    static func load(from location: URL? = nil) throws -> Self? {
        let url = try location ?? file()
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    func save(to location: URL? = nil) throws {
        let url = try location ?? Self.file()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func preserveUnreadable() throws {
        let url = try file()
        let archived = url.deletingLastPathComponent()
            .appendingPathComponent("recovery-unreadable-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: url, to: archived)
    }

    static func remove(at location: URL? = nil) throws {
        do { try FileManager.default.removeItem(at: location ?? file()) }
        catch CocoaError.fileNoSuchFile {}
    }
}
