import Foundation

/// Текстовый WebSocket: всё, что нужно потоковым клиентам ElevenLabs.
/// Отдельный протокол — чтобы клиенты проверялись тестами без сети.
public protocol LiveSocket: Sendable {
    func send(_ text: String) async throws
    /// Следующее текстовое сообщение. Бросает ошибку, когда соединение закрыто.
    func receive() async throws -> String
    func close()
}

public protocol LiveSocketFactory: Sendable {
    func open(_ request: URLRequest) -> any LiveSocket
}

/// Настоящее соединение через URLSession.
public struct URLSessionSocketFactory: LiveSocketFactory {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func open(_ request: URLRequest) -> any LiveSocket {
        let task = session.webSocketTask(with: request)
        // Ответы с аудио крупные: по умолчанию предел 1 МБ на сообщение.
        task.maximumMessageSize = 8 * 1024 * 1024
        task.resume()
        return URLSessionSocket(task: task)
    }
}

private struct URLSessionSocket: LiveSocket {
    let task: URLSessionWebSocketTask

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        while true {
            switch try await task.receive() {
            case .string(let text):
                return text
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) { return text }
            @unknown default:
                continue
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Сборка адреса с повторяющимися параметрами (`secondary_languages=ru&secondary_languages=en`).
enum LiveURL {
    static func make(_ base: String, _ items: [(String, String?)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items.compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        return components.url!
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
