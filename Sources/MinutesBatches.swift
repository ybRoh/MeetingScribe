/// Groups transcript lines into prompt-sized batches for the minutes model.
enum MinutesBatches {
    /// Lines are kept whole unless a single line is longer than `lineLimit`;
    /// a batch holds at most `limit` characters (newlines included), except a
    /// lone over-long piece.
    static func make(_ entries: [Utterance], limit: Int = 3000, lineLimit: Int = 2500) -> [String] {
        var batches: [String] = []
        var batch = ""
        var batchLength = 0  // String.count is O(n); track the length instead.
        for entry in entries {
            for chunk in entry.line.chunks(of: lineLimit) {
                let length = chunk.count
                if batchLength + length > limit && !batch.isEmpty {
                    batches.append(batch)
                    batch = ""
                    batchLength = 0
                }
                batch += chunk + "\n"
                batchLength += length + 1
            }
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }
}

private extension String {
    func chunks(of length: Int) -> [Substring] {
        var chunks: [Substring] = []
        var remaining = self[...]
        while !remaining.isEmpty {
            let chunk = remaining.prefix(length)
            chunks.append(chunk)
            remaining = remaining.dropFirst(chunk.count)
        }
        return chunks
    }
}
