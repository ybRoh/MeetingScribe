using System.Text.RegularExpressions;

namespace MeetingScribe;

internal static class ToDoList
{
    public static string AtEnd(string markdown)
    {
        var body = new List<string>();
        var items = new List<string>();
        bool inTasks = false;
        foreach (string line in markdown.Replace("\r\n", "\n").Split('\n'))
        {
            string trimmed = line.Trim();
            if (trimmed is "```" or "```markdown") continue;
            var heading = Regex.Match(trimmed, @"^#{1,6}\s+(.+)$");
            if (heading.Success)
            {
                string title = Regex.Replace(heading.Groups[1].Value, @"[-*:：#\s]", "").ToLowerInvariant();
                inTasks = title is "todolist" or "todo" or "할일" or "실행항목" or "todolist할일";
                if (inTasks) continue;
            }
            if (!inTasks)
            {
                body.Add(line);
                continue;
            }
            string item = Regex.Replace(trimmed,
                @"^(?:(?:[-*+]\s+|\d+[.)]\s+)?\[[ xX]\]\s*|[-*+]\s+|\d+[.)]\s+)", "").Trim();
            if (item is "" or "없음" or "없음." or "해당 없음" or "해당 없음." or "할 일 없음" or "할 일 없음." or "확인된 할 일 없음") continue;
            if (!items.Contains(item)) items.Add(item);
        }
        string content = string.Join("\n", body).Trim();
        string checklist = items.Count == 0 ? "확인된 할 일 없음" : string.Join("\n", items.Select(item => "- [ ] " + item));
        return (content.Length == 0 ? "" : content + "\n\n") + "## To-Do List\n\n" + checklist;
    }
}
