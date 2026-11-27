using MeetingScribe;
using System.Text;
using System.Text.Json;

static void Expect(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

using var cases = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "ToDoCases.json")));
foreach (var example in cases.RootElement.EnumerateArray())
{
    string input = example.GetProperty("input").GetString()!;
    string expected = example.GetProperty("expected").GetString()!;
    Expect(ToDoList.AtEnd(input) == expected && ToDoList.AtEnd(expected) == expected, $"Unexpected checklist for {input}");
}

// Transcript chunks: whole lines, within the limit, nothing lost or reordered.
var lines = Enumerable.Range(0, 400).Select(i => $"[{i:000}] 다음 주까지 품질 보고서를 검토하겠습니다 " + new string('가', i % 90)).ToList();
string transcript = string.Join("\n", lines);
var chunks = TranscriptChunks.Split(transcript);
Expect(chunks.All(chunk => chunk.Length <= 3000), "chunk over limit");
Expect(string.Join("\n", chunks) == transcript, "chunks must rebuild the transcript");
Expect(chunks.SelectMany(chunk => chunk.Split('\n')).SequenceEqual(lines), "a line was split");
Expect(chunks.Count == (int)Math.Ceiling(transcript.Length / 3000.0) || chunks.Count == (int)Math.Ceiling(transcript.Length / 3000.0) + 1,
    $"unexpected chunk count {chunks.Count} for {transcript.Length} chars");

Expect(TranscriptChunks.Split("").Count == 0, "empty transcript");
Expect(TranscriptChunks.Split("\r\n첫 줄\r\n둘째 줄") is [var crlf] && crlf == "\n첫 줄\n둘째 줄", "CRLF normalised");

// A single very long line is cut at spaces, never inside a surrogate pair.
string emoji = string.Concat(Enumerable.Repeat("발언😀 ", 1500));
var pieces = TranscriptChunks.Split(emoji, 1000);
Expect(pieces.All(piece => piece.Length <= 1000), "long line piece over limit");
Expect(string.Concat(pieces.SelectMany(piece => piece.Split('\n'))) == emoji, "long line content lost");
Expect(pieces.All(piece => !char.IsHighSurrogate(piece[^1]) && !char.IsLowSurrogate(piece[0])), "surrogate pair split");
string noSpaces = string.Concat(Enumerable.Repeat("😀", 1500));
var hard = TranscriptChunks.Split(noSpaces, 1001);
Expect(hard.All(piece => piece.Length <= 1001 && !char.IsHighSurrogate(piece[^1])), "surrogate pair split without spaces");
Expect(string.Concat(hard.SelectMany(piece => piece.Split('\n'))) == noSpaces, "content lost without spaces");

Console.WriteLine("C# checks passed");
