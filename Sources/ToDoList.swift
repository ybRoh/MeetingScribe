import Foundation

enum ToDoList {
    static func atEnd(of markdown: String) -> String {
        var body: [String] = []
        var items: [String] = []
        var inTasks = false
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "```" || trimmed == "```markdown" { continue }
            if trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil {
                let title = trimmed.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"[-*:：#\s]"#, with: "", options: .regularExpression)
                    .lowercased()
                inTasks = ["todolist", "todo", "할일", "실행항목", "todolist할일"].contains(title)
                if inTasks { continue }
            }
            if !inTasks {
                body.append(line)
                continue
            }
            let item = trimmed.replacingOccurrences(
                of: #"^(?:(?:[-*+]\s+|\d+[.)]\s+)?\[[ xX]\]\s*|[-*+]\s+|\d+[.)]\s+)"#,
                with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            if !item.isEmpty, !["없음", "없음.", "해당 없음", "해당 없음.", "할 일 없음", "할 일 없음.", "확인된 할 일 없음"].contains(item),
               !items.contains(item) {
                items.append(item)
            }
        }
        let checklist = items.isEmpty ? "확인된 할 일 없음" : items.map { "- [ ] \($0)" }.joined(separator: "\n")
        let content = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (content.isEmpty ? "" : content + "\n\n") + "## To-Do List\n\n" + checklist
    }
}
