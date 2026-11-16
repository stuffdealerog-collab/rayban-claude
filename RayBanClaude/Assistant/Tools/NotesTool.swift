import AssistantCore
import ClaudeKit
import Foundation

/// Долговременная память — заметки Markdown в папке `/memories` (как хранилище Obsidian).
///
/// Команды повторяют memory tool Claude, но инструмент объявлен как обычный: так API не заставляет
/// модель просматривать папку перед каждым ответом — список заметок уже есть в начале диалога.
struct NotesTool: ClaudeTool {
    let store: MemoryStore

    let name = "notes"
    let description = """
    Долговременная память ассистента: заметки Markdown в папке /memories, которые сохраняются между разговорами \
    и видны пользователю на экране «Память». Команды: view (показать папку или файл с номерами строк, \
    view_range [начало, конец], конец -1 — до конца файла), create (создать или перезаписать файл: path, file_text), \
    str_replace (заменить уникальный фрагмент: path, old_str, new_str), insert (вставить текст после строки \
    insert_line, 0 — в начало: path, insert_line, insert_text), delete (path), rename (old_path, new_path). \
    Все пути начинаются с /memories.
    """
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "command": ["type": "string", "enum": ["view", "create", "str_replace", "insert", "delete", "rename"]],
            "path": ["type": "string", "description": "Путь, например /memories/Люди/Анна.md"],
            "view_range": ["type": "array", "items": ["type": "integer"], "description": "Для view: [начало, конец]."],
            "file_text": ["type": "string", "description": "Для create: полный текст файла."],
            "old_str": ["type": "string", "description": "Для str_replace: точный фрагмент, встречающийся один раз."],
            "new_str": ["type": "string", "description": "Для str_replace: новый текст (пусто — удалить фрагмент)."],
            "insert_line": ["type": "integer", "description": "Для insert: номер строки, после которой вставить."],
            "insert_text": ["type": "string", "description": "Для insert: вставляемый текст."],
            "old_path": ["type": "string", "description": "Для rename: текущий путь."],
            "new_path": ["type": "string", "description": "Для rename: новый путь."],
        ],
        "required": ["command"],
    ]

    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        guard let command = Self.command(from: input) else {
            return .error("Не хватает параметров для команды \(input["command"]?.stringValue ?? "?").")
        }
        let result = store.execute(command)
        if !result.isError, Self.isMutating(command) {
            await MainActor.run { NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
        }
        return result.isError ? .error(result.text) : .text(result.text)
    }

    static func command(from input: [String: JSONValue]) -> MemoryCommand? {
        let path = input["path"]?.stringValue
        switch input["command"]?.stringValue {
        case "view":
            let range = input["view_range"]?.arrayValue?.compactMap { ToolSupport.int($0) }
            return path.map { .view(path: $0, range: range) }
        case "create":
            guard let path, let text = input["file_text"]?.stringValue else { return nil }
            return .create(path: path, text: text)
        case "str_replace":
            guard let path, let old = input["old_str"]?.stringValue else { return nil }
            return .strReplace(path: path, old: old, new: input["new_str"]?.stringValue ?? "")
        case "insert":
            guard let path, let line = ToolSupport.int(input["insert_line"]),
                  let text = input["insert_text"]?.stringValue ?? input["new_str"]?.stringValue
            else { return nil }
            return .insert(path: path, line: line, text: text)
        case "delete":
            return path.map { .delete(path: $0) }
        case "rename":
            guard let from = input["old_path"]?.stringValue, let to = input["new_path"]?.stringValue else { return nil }
            return .rename(from: from, to: to)
        default:
            return nil
        }
    }

    private static func isMutating(_ command: MemoryCommand) -> Bool {
        if case .view = command { return false }
        return true
    }

    /// Короткое описание действия для ленты.
    static func activityTitle(for input: JSONValue) -> String {
        let path = (input["path"]?.stringValue ?? input["new_path"]?.stringValue ?? "")
        let title = (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        switch input["command"]?.stringValue {
        case "view": return title.isEmpty || path == MemoryStore.virtualRoot ? L("Вспоминаю") : L("Вспоминаю: %@", title)
        case "delete": return L("Забываю: %@", title)
        default: return title.isEmpty ? L("Запоминаю") : L("Запоминаю: %@", title)
        }
    }
}
