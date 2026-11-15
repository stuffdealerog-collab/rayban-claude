import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Ошибка HTTP-уровня от Messages API.
public struct ClaudeAPIError: Error, Sendable, LocalizedError {
    public var statusCode: Int
    public var type: String?
    public var message: String

    public var isRetryable: Bool {
        statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
    }

    public var errorDescription: String? {
        switch statusCode {
        case 401: return "Неверный API-ключ Anthropic (401). Проверьте ключ в настройках."
        case 403: return "Нет доступа (403): \(message)"
        case 429: return "Превышен лимит запросов (429). Попробуйте чуть позже."
        case 529: return "Серверы Claude перегружены (529). Попробуйте ещё раз."
        default: return "Ошибка Claude API \(statusCode)\(type.map { " (\($0))" } ?? ""): \(message)"
        }
    }
}

/// Минимальный HTTP-клиент Messages API со стримингом (SSE).
/// Официального Swift SDK у Anthropic нет, поэтому запросы идут через URLSession.
public final class ClaudeClient: Sendable {
    public static let apiVersion = "2026-10-21"

    private let session: URLSession
    private let baseURL: URL
    private let maxRetries: Int

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        maxRetries: Int = 2
    ) {
        self.session = session
        self.baseURL = baseURL
        self.maxRetries = maxRetries
    }

    /// Отправляет `POST /v1/messages` с `stream: true` и собирает ответ.
    /// `onDelta` вызывается для каждого фрагмента текста — по нему озвучка стартует до конца ответа.
    public func streamMessage(
        body: JSONValue,
        apiKey: String,
        betas: [String] = [],
        onDelta: @Sendable (StreamDelta) async -> Void
    ) async throws -> AssembledMessage {
        let request = try makeRequest(body: body, apiKey: apiKey, betas: betas)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            guard http.statusCode == 200 else {
                let error = await Self.readError(bytes: bytes, statusCode: http.statusCode)
                // Повторяем только до начала стрима: частично озвученный ответ не дублируем.
                if error.isRetryable, attempt < maxRetries {
                    attempt += 1
                    try await Task.sleep(nanoseconds: Self.backoff(attempt: attempt, response: http))
                    continue
                }
                throw error
            }

            var splitter = LineSplitter()
            var parser = SSEParser()
            var assembler = MessageAssembler()

            for try await byte in bytes {
                guard let line = splitter.append(byte) else { continue }
                if let event = parser.feed(line: line) {
                    for delta in try assembler.handle(event) {
                        await onDelta(delta)
                    }
                }
            }
            if let line = splitter.finish(), let event = parser.feed(line: line) {
                for delta in try assembler.handle(event) { await onDelta(delta) }
            }
            if let event = parser.finish() {
                for delta in try assembler.handle(event) { await onDelta(delta) }
            }

            try Task.checkCancellation()
            guard assembler.isFinished else {
                throw URLError(.networkConnectionLost)
            }
            return assembler.finish()
        }
    }

    // MARK: - Private

    private func makeRequest(body: JSONValue, apiKey: String, betas: [String]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty {
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try body.encoded()
        return request
    }

    private static func readError(bytes: URLSession.AsyncBytes, statusCode: Int) async -> ClaudeAPIError {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
        } catch {
            // Тело ошибки не дочитали — вернём то, что есть.
        }
        let json = try? JSONValue.decode(data)
        return ClaudeAPIError(
            statusCode: statusCode,
            type: json?["error"]?["type"]?.stringValue,
            message: json?["error"]?["message"]?.stringValue ?? String(decoding: data, as: UTF8.self)
        )
    }

    private static func backoff(attempt: Int, response: HTTPURLResponse) -> UInt64 {
        if let header = response.value(forHTTPHeaderField: "retry-after"), let seconds = Double(header) {
            return UInt64(min(seconds, 10) * 1_000_000_000) // голосовому ассистенту дольше ждать нет смысла
        }
        let seconds = min(0.5 * pow(2, Double(attempt - 1)), 4)
        return UInt64(seconds * 1_000_000_000)
    }
}
