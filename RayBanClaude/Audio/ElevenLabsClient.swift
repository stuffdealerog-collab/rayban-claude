import Foundation

/// Модели синтеза ElevenLabs, доступные в настройках. Обе говорят по-русски.
enum ElevenLabsModel: String, CaseIterable, Identifiable, Sendable {
    /// ~100 мс, вдвое дешевле за символ.
    case flash = "eleven_flash_v2_5"
    /// Медленнее, но естественнее интонации.
    case multilingual = "eleven_multilingual_v2"
    /// Самая выразительная, 70+ языков, в том числе узбекский. Отвечает медленнее Flash.
    case v3 = "eleven_v3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flash: return "Быстрая (Flash v2.5)"
        case .multilingual: return "Качественная (Multilingual v2)"
        case .v3: return "Выразительная (v3)"
        }
    }

    /// `language_code` не поддерживает только Multilingual v2.
    fileprivate var supportsLanguageCode: Bool { self != .multilingual }

    /// Языки Flash v2.5 (ISO 639-1). Для остальных, например узбекского, нужна v3.
    static let flashLanguages: Set<String> = [
        "en", "ja", "zh", "de", "hi", "fr", "ko", "pt", "it", "es", "id", "nl", "tr", "fil", "pl", "sv",
        "bg", "ro", "ar", "cs", "el", "fi", "hr", "ms", "sk", "da", "ta", "uk", "ru", "hu", "no", "vi",
    ]
}

/// Всё, что нужно для запроса синтеза.
struct ElevenLabsConfiguration: Equatable, Sendable {
    var apiKey: String
    var voiceID: String
    var model: ElevenLabsModel
    /// ISO 639-1: «ru», «en».
    var languageCode: String
}

extension ElevenLabsConfiguration {
    /// Та же настройка для фразы на другом языке: язык, которого нет у Flash и Multilingual
    /// (например, узбекский), озвучивает v3.
    func adapted(to language: String) -> ElevenLabsConfiguration {
        var copy = self
        copy.languageCode = language
        if !ElevenLabsModel.flashLanguages.contains(language) { copy.model = .v3 }
        return copy
    }
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
    case badRequest(String)
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
        case .badRequest(let detail):
            return "ElevenLabs отклонил запрос\(Self.suffix(detail))."
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
        case .unauthorized, .quotaExceeded, .paymentRequired, .voiceNotFound, .badRequest: return true
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

        // apply_text_normalization не отправляем: для v2.5 принудительная нормализация была только
        // на корпоративных тарифах, а числа Claude и так пишет словами (см. системный промпт).
        let body = SpeechRequest(
            text: text,
            modelID: configuration.model.rawValue,
            languageCode: configuration.model.supportsLanguageCode ? configuration.languageCode : nil,
            previousText: configuration.model == .v3 ? nil : previousText
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        guard !data.isEmpty else { throw ElevenLabsError.emptyAudio }
        return data
    }

    /// Распознаёт речь (Scribe): 16 кГц, моно, 16 бит PCM. Нужна для узбекского — у Apple его нет.
    func transcribe(pcm16kHz: Data, languageCode: String?, apiKey: String) async throws -> String {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/speech-to-text"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", "scribe_v2")
        field("file_format", "pcm_s16le_16")
        if let languageCode { field("language_code", languageCode) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.pcm\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(pcm16kHz)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if lowered.contains("voice_not_found") { throw ElevenLabsError.voiceNotFound }
        if lowered.contains("paid_plan_required") || lowered.contains("payment") { throw ElevenLabsError.paymentRequired(detail) }
        switch http.statusCode {
        case 401, 403: throw ElevenLabsError.unauthorized(detail)
        case 402: throw ElevenLabsError.paymentRequired(detail)
        case 404: throw ElevenLabsError.voiceNotFound
        case 400, 422: throw ElevenLabsError.badRequest(detail)
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

    enum CodingKeys: String, CodingKey {
        case text
        case modelID = "model_id"
        case languageCode = "language_code"
        case previousText = "previous_text"
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
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
