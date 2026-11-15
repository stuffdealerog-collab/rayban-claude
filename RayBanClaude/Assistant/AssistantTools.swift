import ClaudeKit
import CoreLocation
import EventKit
import Foundation
import UIKit

/// Снимок камерой очков — «глаза» ассистента.
struct TakePhotoTool: ClaudeTool {
    let glasses: GlassesManager

    let name = "take_photo"
    let description = """
    Делает снимок камерой очков Ray-Ban Meta — это вид от первого лица, то, что пользователь сейчас видит перед собой. \
    Возвращает изображение. Вызывай, когда пользователь просит посмотреть, спрашивает «что это», «что передо мной», \
    просит прочитать, перевести или пересказать текст, узнать предмет, растение, блюдо, оценить обстановку. \
    Не вызывай для вопросов, не связанных с тем, что вокруг пользователя.
    """
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "focus": [
                "type": "string",
                "description": "Что нужно рассмотреть на снимке (необязательно).",
            ],
        ],
    ]

    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        let jpeg = try await glasses.photoForAssistant()
        let time = Date().formatted(date: .omitted, time: .shortened)
        return ToolOutput(content: [.jpeg(jpeg), .text("Снимок с камеры очков, сделан в \(time).")])
    }
}

/// Текущее местоположение и адрес.
struct LocationTool: ClaudeTool {
    let provider: LocationProvider

    let name = "get_location"
    let description = """
    Возвращает текущее местоположение пользователя: координаты и ближайший адрес. \
    Используй для вопросов «где я», «что рядом», для погоды или маршрутов, если место не названо.
    """
    let inputSchema: JSONValue = ["type": "object", "properties": [:]]

    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        let location = try await provider.currentLocation()
        let address = await provider.address(for: location)
        let coordinate = location.coordinate
        var text = String(format: "Координаты: %.5f, %.5f (точность ~%.0f м).", coordinate.latitude, coordinate.longitude, location.horizontalAccuracy)
        if let address { text += " Адрес: \(address)." }
        return .text(text)
    }
}

/// Напоминание в системном приложении «Напоминания».
struct ReminderTool: ClaudeTool {
    let name = "create_reminder"
    let description = """
    Создаёт напоминание в приложении «Напоминания» на iPhone. \
    Время указывай в локальном часовом поясе пользователя в формате YYYY-MM-DDTHH:MM; \
    относительное время («через час», «завтра в 9») вычисляй от текущего времени из строки [контекст: ...].
    """
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Текст напоминания."],
            "due": ["type": "string", "description": "Когда напомнить, YYYY-MM-DDTHH:MM, локальное время. Необязательно."],
            "notes": ["type": "string", "description": "Дополнительные заметки. Необязательно."],
        ],
        "required": ["title"],
    ]

    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        guard let title = input["title"]?.stringValue, !title.isEmpty else { return .error("Пустой текст напоминания.") }

        // Системный запрос доступа виден только на активном экране. При заблокированном телефоне
        // он ждал бы вечно, а ClaudeKit выполняет ходы по очереди — завис бы весь диалог.
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            let isActive = await MainActor.run { UIApplication.shared.applicationState == .active }
            guard isActive else {
                return .error("Нужно разрешение на Напоминания: откройте приложение на телефоне и попросите ещё раз.")
            }
        }

        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            return .error("Нет доступа к Напоминаниям. Разрешите его в Настройках iOS.")
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            return .error("Не найден список напоминаний по умолчанию.")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = input["notes"]?.stringValue
        reminder.calendar = calendar

        var dueDescription = "без срока"
        if let dueText = input["due"]?.stringValue {
            guard let due = Self.parseLocalDate(dueText) else {
                return .error("Не понял время '\(dueText)'. Нужен формат YYYY-MM-DDTHH:MM.")
            }
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
            dueDescription = due.formatted(date: .abbreviated, time: .shortened)
        }

        try store.save(reminder, commit: true)
        return .text("Напоминание «\(title)» создано (\(dueDescription)).")
    }

    static func parseLocalDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Одноразовый запрос геопозиции через CLLocationManager.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        if manager.authorizationStatus == .notDetermined {
            // Системный запрос разрешения виден только на активном экране — иначе ход завис бы навсегда.
            guard UIApplication.shared.applicationState == .active else {
                throw LocationToolError.permissionNeedsForeground
            }
            guard authorizationContinuation == nil else { throw LocationToolError.busy }
            await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            throw LocationToolError.denied
        }
        guard locationContinuation == nil else { throw LocationToolError.busy }

        let requestID = UUID()
        let location: CLLocation = try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            locationRequestID = requestID
            manager.requestLocation()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                // Таймер относится только к своему запросу, а не к более позднему.
                guard let self, self.locationRequestID == requestID else { return }
                self.finishLocation(.failure(LocationToolError.timeout))
            }
        }
        return location
    }

    private var locationRequestID: UUID?

    private func finishLocation(_ result: Result<CLLocation, Error>) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        locationRequestID = nil
        continuation.resume(with: result)
    }

    func address(for location: CLLocation) async -> String? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let street = [placemark.thoroughfare, placemark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [placemark.name, street.isEmpty ? nil : street, placemark.locality, placemark.country]
            .compactMap { $0 }
        var unique: [String] = []
        for part in parts where !unique.contains(part) { unique.append(part) }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            self.authorizationContinuation?.resume()
            self.authorizationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.finishLocation(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.finishLocation(.failure(LocationToolError.failed(message))) }
    }
}

enum LocationToolError: LocalizedError {
    case permissionNeedsForeground
    case denied
    case busy
    case timeout
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionNeedsForeground: return "Нужно разрешение на геолокацию: откройте приложение на телефоне и спросите ещё раз."
        case .denied: return "Доступ к геолокации запрещён в настройках iOS."
        case .busy: return "Местоположение уже определяется."
        case .timeout: return "Не удалось определить местоположение за 15 секунд."
        case .failed(let message): return "Ошибка геолокации: \(message)"
        }
    }
}
