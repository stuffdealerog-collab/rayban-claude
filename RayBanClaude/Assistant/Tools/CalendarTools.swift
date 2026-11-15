import ClaudeKit
import EventKit
import Foundation

/// Доступ к календарю с запросом разрешения только на активном экране.
enum CalendarAccess {
    static func store() async throws -> EKEventStore {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined, !(await ToolSupport.isAppActive()) {
            throw ToolFailure(ToolSupport.foregroundNeeded)
        }
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw ToolFailure("Нет доступа к Календарю. Разрешите его: Настройки iOS → Конфиденциальность → Календари.")
        }
        return store
    }
}

struct ToolFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// События календаря за период.
struct ListEventsTool: ClaudeTool {
    let name = "list_events"
    let description = """
    Возвращает события из календарей iPhone за период: название, время, место. \
    Время — местное, формат YYYY-MM-DDTHH:MM. Для «что у меня завтра» передай начало и конец завтрашнего дня.
    """
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "from": ["type": "string", "description": "Начало периода, YYYY-MM-DDTHH:MM."],
            "to": ["type": "string", "description": "Конец периода, YYYY-MM-DDTHH:MM."],
        ],
        "required": ["from", "to"],
    ]

    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        guard let fromText = ToolSupport.string(input, "from"), let from = ToolSupport.parseDate(fromText),
              let toText = ToolSupport.string(input, "to"), let to = ToolSupport.parseDate(toText), to > from
        else { return .error("Нужен период: from и to в формате YYYY-MM-DDTHH:MM, to позже from.") }
        guard to.timeIntervalSince(from) <= 62 * 24 * 3600 else { return .error("Период не длиннее двух месяцев.") }

        let store = try await CalendarAccess.store()
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return .text("Событий нет.") }

        let lines = events.prefix(40).map { event -> String in
            var line = event.isAllDay
                ? "• \(ToolSupport.describe(event.startDate, allDay: true)), весь день — \(event.title ?? "Без названия")"
                : "• \(ToolSupport.describe(event.startDate)) – \(event.endDate.formatted(date: .omitted, time: .shortened)) — \(event.title ?? "Без названия")"
            if let location = event.location, !location.isEmpty { line += " (\(location))" }
            return line
        }
        let more = events.count > 40 ? "\n…и ещё \(events.count - 40)." : ""
        return .text(lines.joined(separator: "\n") + more)
    }
}

/// Новое событие в календаре по умолчанию.
struct CreateEventTool: ClaudeTool {
    let name = "create_event"
    let description = """
    Добавляет событие в календарь iPhone. Время — местное, формат YYYY-MM-DDTHH:MM. \
    Если длительность не названа, ставь один час. Для событий на весь день передай all_day.
    """
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Название."],
            "start": ["type": "string", "description": "Начало, YYYY-MM-DDTHH:MM (для all_day — YYYY-MM-DD)."],
            "end": ["type": "string", "description": "Конец, YYYY-MM-DDTHH:MM. Необязательно."],
            "all_day": ["type": "boolean", "description": "Событие на весь день."],
            "location": ["type": "string", "description": "Место. Необязательно."],
            "notes": ["type": "string", "description": "Заметки. Необязательно."],
            "alert_minutes": ["type": "integer", "description": "Напомнить за столько минут. Необязательно."],
        ],
        "required": ["title", "start"],
    ]

    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        guard let title = ToolSupport.string(input, "title") else { return .error("Нужно название события.") }
        guard let startText = ToolSupport.string(input, "start"), let start = ToolSupport.parseDate(startText) else {
            return .error("Не понял время начала. Нужен формат YYYY-MM-DDTHH:MM.")
        }
        let allDay = ToolSupport.bool(input, "all_day") ?? false
        var end = ToolSupport.string(input, "end").flatMap(ToolSupport.parseDate) ?? start.addingTimeInterval(allDay ? 86_400 : 3_600)
        if end <= start { end = start.addingTimeInterval(3_600) }

        let store = try await CalendarAccess.store()
        guard let calendar = store.defaultCalendarForNewEvents else { return .error("Нет календаря для новых событий.") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        event.location = ToolSupport.string(input, "location")
        event.notes = ToolSupport.string(input, "notes")
        event.calendar = calendar
        if let minutes = ToolSupport.int(input, "alert_minutes"), minutes >= 0 {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }
        try store.save(event, span: .thisEvent, commit: true)
        return .text("Событие «\(title)» добавлено: \(ToolSupport.describe(start, allDay: allDay)).")
    }
}
