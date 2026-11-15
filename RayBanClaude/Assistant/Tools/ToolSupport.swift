import ClaudeKit
import Foundation
import UIKit

extension Notification.Name {
    /// Claude изменил заметки — экран «Память» перечитывает список.
    static let memoryDidChange = Notification.Name("memoryDidChange")
}

/// Общее для инструментов: даты, проверка активного экрана, показ системных окон.
enum ToolSupport {
    /// Системные окна (запрос доступа, окно отправки) видны только на активном экране.
    /// При заблокированном телефоне они ждали бы вечно, а ходы ClaudeKit идут по очереди.
    static func isAppActive() async -> Bool {
        await MainActor.run { UIApplication.shared.applicationState == .active }
    }

    static let foregroundNeeded = "Для этого нужно, чтобы приложение было открыто на экране телефона. Попроси пользователя разблокировать телефон и повторить."

    /// «YYYY-MM-DDTHH:MM» в местном времени (так время отдаёт Claude) и варианты с секундами, датой без времени.
    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Дата для Claude: однозначно и в местном времени.
    static func describe(_ date: Date, allDay: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .current
        formatter.dateFormat = allDay ? "EEEE, d MMMM yyyy" : "EEEE, d MMMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    /// Самый верхний экран — с него показываются окна отправки сообщений и писем.
    @MainActor
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }

    /// Открывает ссылку в другом приложении (Telegram, WhatsApp, Карты, Команды).
    @MainActor
    static func openURL(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }

    static func string(_ input: [String: JSONValue], _ key: String) -> String? {
        guard let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func int(_ input: [String: JSONValue], _ key: String) -> Int? {
        input[key]?.doubleValue.map { Int($0) }
    }

    static func bool(_ input: [String: JSONValue], _ key: String) -> Bool? {
        input[key]?.boolValue
    }
}
