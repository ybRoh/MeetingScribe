using System.Text;

namespace MeetingScribe;

/// <summary>
/// Groups whole transcript lines into prompt-sized chunks for the minutes model,
/// matching the Mac app's batching. A sentence is never cut in half unless a
/// single line is longer than the limit.
/// </summary>
internal static class TranscriptChunks
{
    public static List<string> Split(string transcript, int limit = 3000)
    {
        var chunks = new List<string>();
        var current = new StringBuilder();
        bool started = false;
        foreach (string line in transcript.Replace("\r\n", "\n").Split('\n'))
        {
            foreach (string piece in Pieces(line, limit))
            {
                if (started && current.Length + 1 + piece.Length > limit)
                {
                    chunks.Add(current.ToString());
                    current.Clear();
                    started = false;
                }
                if (started) current.Append('\n');
                current.Append(piece);
                started = true;
            }
        }
        if (current.ToString().Trim().Length > 0) chunks.Add(current.ToString());
        return chunks;
    }

    private static IEnumerable<string> Pieces(string line, int limit)
    {
        for (int offset = 0; offset < line.Length || offset == 0;)
        {
            int length = Math.Min(limit, line.Length - offset);
            if (offset + length < line.Length)
            {
                int space = line.LastIndexOf(' ', offset + length - 1, length);
                if (space > offset + limit / 2) length = space + 1 - offset;
                else if (char.IsHighSurrogate(line[offset + length - 1])) length--;
            }
            yield return line.Substring(offset, length);
            offset += length;
            if (line.Length == 0) yield break;
        }
    }
}
