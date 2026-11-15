import Foundation

/// Модели синтеза ElevenLabs, доступные в настройках. Обе говорят по-русски.
enum ElevenLabsModel: String, CaseIterable, Identifiable, Sendable {
    /// ~100 мс, вдвое дешевле за символ.
    case flash = "eleven_flash_v2_5"
    /// Медленнее, но естественнее интонации.
    case multilingual = "eleven_multilingual_v2"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flash: return "Быстрая (Flash v2.5)"
        case .multilingual: return "Качественная (Multilingual v2)"
        }
    }

    /// `language_code` и принудительная нормализация текста (числа, даты) есть только у Flash.
    fileprivate var supportsLanguageCode: Bool { self == .flash }
}

/// Всё, что нужно для запроса синтеза.
struct ElevenLabsConfiguration: Equatable, Sendable {
    var apiKey: String
    var voiceID: String
    var model: ElevenLabsModel
    /// ISO 639-1: «ru», «en».
    var languageCode: String
}

/// Голос из библиотеки пользователя ElevenLabs.
struct ElevenLabsVoice: Identifiable, Hashable, Sendable, Decodable {
    let voiceID: String
    let name: String
    let category: String?
    let labels: [String: String]
    let languages: [String]

    var id: String { voiceID }

    /// Голос записан носителем русского (по меткам ElevenLabs).
    var isRussian: Bool {
        languages.contains { $0.lowercased().hasPrefix("ru") }
            || labels["language"]?.lowercased().hasPrefix("ru") == true
    }

    /// Название для списка: «Имя — пол, акцент».
    var title: String {
        let details = ["gender", "accent", "age"].compactMap { labels[$0] }.filter { !$0.isEmpty }
        let name = isRussian ? "\(self.name) · рус." : self.name
        return details.isEmpty ? name : "\(name) — \(details.joined(separator: ", "))"
    }

    private enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id", name, category, labels
        case verifiedLanguages = "verified_languages"
    }

    private struct VerifiedLanguage: Decodable {
        let language: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        voiceID = try container.decode(String.self, forKey: .voiceID)
        name = (try? container.decode(String.self, forKey: .name)) ?? voiceID
        category = try? container.decode(String.self, forKey: .category)
        // В метках бывают null — их пропускаем, а не теряем все метки.
        labels = ((try? container.decode([String: String?].self, forKey: .labels)) ?? [:]).compactMapValues { $0 }
        let verified = (try? container.decode([VerifiedLanguage].self, forKey: .verifiedLanguages)) ?? []
        languages = verified.compactMap(\.language)
    }
}

enum ElevenLabsError: LocalizedError, Equatable {
    case unauthorized(String)
    case quotaExceeded
    case paymentRequired(String)
    case voiceNotFound
    case busy(Int)
    case server(Int, String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .unauthorized(let detail):
            return "ключ ElevenLabs не подошёл\(Self.suffix(detail))."
        case .quotaExceeded:
            return "закончился лимит символов ElevenLabs."
        case .paymentRequired(let detail):
            return "нужен платный тариф ElevenLabs\(Self.suffix(detail))."
        case .voiceNotFound:
            return "выбранный голос не найден — выберите другой в настройках."
        case .busy(let status):
            return "ElevenLabs перегружен (HTTP \(status))."
        case .server(let status, let detail):
            return "ошибка ElevenLabs (HTTP \(status))\(Self.suffix(detail))."
        case .emptyAudio:
            return "ElevenLabs вернул пустой звук."
        }
    }

    /// Сама не пройдёт (ключ, лимит, голос): до смены настроек говорим голосом iOS.
    var isPermanent: Bool {
        switch self {
        case .unauthorized, .quotaExceeded, .paymentRequired, .voiceNotFound: return true
        case .busy, .server, .emptyAudio: return false
        }
    }

    private static func suffix(_ detail: String) -> String {
        detail.isEmpty ? "" : ": \(detail)"
    }
}

/// HTTP-клиент ElevenLabs: синтез речи и список голосов.
struct ElevenLabsClient: Sendable {
    private static let baseURL = URL(string: "https://api.elevenlabs.io")!

    var session: URLSession = .shared

    /// Озвучивает одну фразу. Возвращает MP3 44,1 кГц / 128 кбит/с (доступно и на бесплатном тарифе).
    /// `previousText` — уже сказанное: с ним интонация между фразами звучит связно.
    func synthesize(_ text: String, previousText: String?, configuration: ElevenLabsConfiguration) async throws -> Data {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("v1/text-to-speech/\(configuration.voiceID)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        // Короткий таймаут: на плохой сети лучше быстро перейти на голос iOS, чем молчать.
        request.timeoutInterval = 8
        request.setValue(configuration.apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let flash = configuration.model.supportsLanguageCode
        let body = SpeechRequest(
            text: text,
            modelID: configuration.model.rawValue,
            languageCode: flash ? configuration.languageCode : nil,
            previousText: previousText,
            // У Flash нормализация по умолчанию выключена — без неё числа и даты читаются плохо.
            applyTextNormalization: flash ? "on" : nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        guard !data.isEmpty else { throw ElevenLabsError.emptyAudio }
        return data
    }

    /// Голоса из библиотеки пользователя (стандартные, клонированные и добавленные из Voice Library).
    func voices(apiKey: String) async throws -> [ElevenLabsVoice] {
        var all: [ElevenLabsVoice] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(url: Self.baseURL.appendingPathComponent("v2/voices"), resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "page_size", value: "100"),
                URLQueryItem(name: "include_total_count", value: "false"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "next_page_token", value: pageToken)) }
            components.queryItems = items

            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 15
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

            let (data, response) = try await session.data(for: request)
            try Self.check(response, data)
            let page = try JSONDecoder().decode(VoicePage.self, from: data)
            all += page.voices
            pageToken = page.hasMore == true ? page.nextPageToken : nil
        } while pageToken != nil && all.count < 500
        return all
    }

    // MARK: - Ошибки

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ElevenLabsError.server(0, "") }
        guard !(200..<300).contains(http.statusCode) else { return }

        let (detail, everything) = errorDetail(from: data)
        let lowered = everything.lowercased()
        // Превышение лимита ElevenLabs может вернуть и с 401, и с 402/429 — узнаём по тексту.
        if lowered.contains("quota") || lowered.contains("credits") {
            throw ElevenLabsError.quotaExceeded
        }
        switch http.statusCode {
        case 401, 403: throw ElevenLabsError.unauthorized(detail)
        case 402: throw ElevenLabsError.paymentRequired(detail)
        case 404: throw ElevenLabsError.voiceNotFound
        case 429, 500..<600: throw ElevenLabsError.busy(http.statusCode)
        default: throw ElevenLabsError.server(http.statusCode, detail)
        }
    }

    /// Текст ошибки из тела ответа: короткий для человека и все поля — для распознавания причины.
    /// Формат не задокументирован, поэтому разбираем все известные варианты:
    /// `{"detail": "…"}`, `{"detail": {"status"/"code": …, "message": …}}`, `{"detail": [{"msg": …}]}`.
    static func errorDetail(from data: Data) -> (message: String, everything: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(200), as: UTF8.self)
            return (text, text)
        }
        let detail = object["detail"] ?? object
        if let text = detail as? String { return (text, text) }
        if let fields = detail as? [String: Any] {
            let strings = ["status", "code", "type", "message"].compactMap { fields[$0] as? String }
            let message = (fields["message"] as? String) ?? strings.first ?? ""
            return (message, strings.joined(separator: " "))
        }
        if let list = detail as? [[String: Any]] {
            let text = list.compactMap { $0["msg"] as? String }.joined(separator: "; ")
            return (text, text)
        }
        return ("", "")
    }
}

private struct SpeechRequest: Encodable {
    let text: String
    let modelID: String
    let languageCode: String?
    let previousText: String?
    let applyTextNormalization: String?

    enum CodingKeys: String, CodingKey {
        case text
        case modelID = "model_id"
        case languageCode = "language_code"
        case previousText = "previous_text"
        case applyTextNormalization = "apply_text_normalization"
    }
}

private struct VoicePage: Decodable {
    let voices: [ElevenLabsVoice]
    let hasMore: Bool?
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case voices
        case hasMore = "has_more"
        case nextPageToken = "next_page_token"
    }
}
