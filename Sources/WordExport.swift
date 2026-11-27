import Foundation

enum WordExport {
    static func save(_ text: String, to destination: URL, templates: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: templates, to: folder)
        let word = folder.appendingPathComponent("word", isDirectory: true)
        try FileManager.default.createDirectory(at: word, withIntermediateDirectories: true)
        let paragraphs = text.components(separatedBy: "\n").map { line in
            let clean = String(line.unicodeScalars.filter {
                $0.value == 0x9 || (0x20...0xD7FF).contains($0.value) ||
                (0xE000...0xFFFD).contains($0.value) || $0.value >= 0x10000
            })
            let escaped = clean.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<w:p><w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>"
        }.joined()
        let document = """
            <?xml version="1.0" encoding="UTF-8"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>\(paragraphs)</w:body></w:document>
            """
        try document.write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        let archive = folder.appendingPathComponent("minutes.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-q", archive.path, "[Content_Types].xml", "_rels/.rels", "word/document.xml"]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try Data(contentsOf: archive).write(to: destination, options: .atomic)
    }
}
