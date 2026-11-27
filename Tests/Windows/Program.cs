using MeetingScribe;
using System.Text.Json;

using var cases = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "ToDoCases.json")));
foreach (var example in cases.RootElement.EnumerateArray())
{
    string input = example.GetProperty("input").GetString()!;
    string expected = example.GetProperty("expected").GetString()!;
    if (ToDoList.AtEnd(input) != expected || ToDoList.AtEnd(expected) != expected)
        throw new InvalidOperationException($"Unexpected checklist for {input}");
}
Console.WriteLine("C# checks passed");
