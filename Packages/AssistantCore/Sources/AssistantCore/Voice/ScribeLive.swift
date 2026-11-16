import Foundation

/// Потоковое распознавание речи ElevenLabs Scribe: звук уходит по WebSocket, текст приходит на лету.
///
/// `scribe_v3_live` понимает узбекский, русский и английский, в том числе вперемешку внутри фразы
/// (`multilang_mode`), и сам угадывает конец реплики (`turn_prediction`). Если сервер отвергает
/// параметры (`invalid_request`), сеанс один раз переподключается к `scribe_v2_realtime`.
public struct ScribeLiveConfiguration: Sendable, Equatable {
    public enum Commit: String, Sendable {
        /// Конец фразы решает приложение (`commit()`).
        case manual
        /// Сервер режет фразы по тишине.
        case vad
        /// Сервер режет по тишине и по предсказанию конца реплики (только v3 Live).
        case turnPrediction = "turn_prediction"
    }

    public static let liveModel = "scribe_v3_live"
    public static let fallbackModel = "scribe_v2_realtime"

    public var apiKey: String
    public var model: String
    /// Основной язык, ISO 639-1 (`uz`, `ru`, `en`). nil — определить автоматически.
    public var languageCode: String?
    /// Остальные ожидаемые языки: распознавание выбирает только среди них и основного.
    public var secondaryLanguages: [String]
    /// Смешанная речь: каждый язык пишется своей графикой, переключения ловятся посреди фразы.
    public var multilingual: Bool
    public var commit: Commit
    /// Пауза, по которой сервер считает фразу законченной.
    public var silenceSeconds: Double
    /// Слова, которые важно узнавать точно (имя ассистента). Тарифицируются отдельно.
    public var keyterms: [String]
    /// Присылать язык каждой фразы (нужно переводчику).
    public var detectLanguage: Bool
    public var sampleRate: Int

    public init(
        apiKey: String,
        model: String = ScribeLiveConfiguration.liveModel,
        languageCode: String? = nil,
        secondaryLanguages: [String] = [],
        multilingual: Bool = false,
        commit: Commit = .turnPrediction,
        silenceSeconds: Double = 0.7,
        keyterms: [String] = [],
        detectLanguage: Bool = false,
        sampleRate: Int = 16_000
    ) {
        self.apiKey = apiKey
        self.model = model
        self.languageCode = languageCode
        self.secondaryLanguages = secondaryLanguages
        self.multilingual = multilingual
        self.commit = commit
        self.silenceSeconds = silenceSeconds
        self.keyterms = keyterms
        self.detectLanguage = detectLanguage
        self.sampleRate = sampleRate
    }

    public var url: URL {
        let isLive = model == Self.liveModel
        var items: [(String, String?)] = [
            ("model_id", model),
            ("audio_format", "pcm_\(sampleRate)"),
            ("commit_strategy", commit.rawValue),
        ]
        if commit != .manual {
            items.append(("vad_silence_threshold_secs", String(format: "%.2f", min(3, max(0.2, silenceSeconds)))))
        }
        if multilingual && isLive {
            items.append(("multilang_mode", "true"))
        } else {
            items.append(("language_code", languageCode))
            for language in secondaryLanguages where language != languageCode {
                items.append(("secondary_languages", language))
            }
        }
        if detectLanguage {
            items.append(("include_language_detection", "true"))
            // Итоговый язык фразы приходит только в событии с метками времени.
            items.append(("include_timestamps", "true"))
        }
        for term in keyterms.prefix(50) where !term.isEmpty {
            items.append(("keyterms", String(term.prefix(20))))
        }
        return LiveURL.make("wss://api.elevenlabs.io/v1/speech-to-text/realtime", items)
    }

    public var request: URLRequest {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15
        return request
    }

    /// Упрощённый вариант для сервера, который не принял параметры v3 Live.
    public var downgraded: ScribeLiveConfiguration? {
        guard model == Self.liveModel else { return nil }
        var copy = self
        copy.model = Self.fallbackModel
        copy.multilingual = false
        copy.secondaryLanguages = []
        copy.keyterms = []
        if copy.commit == .turnPrediction { copy.commit = .vad }
        return copy
    }
}

public struct ScribeLiveError: Error, Sendable, Equatable, LocalizedError {
    /// Тип сообщения сервера: `auth_error`, `quota_exceeded`, `invalid_request`… или `connection`.
    public let kind: String
    public let message: String

    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }

    /// Само не пройдёт: неверный ключ, кончился лимит, не приняты условия.
    public var isPermanent: Bool {
        ["auth_error", "quota_exceeded", "unaccepted_terms"].contains(kind)
    }

    /// Сервер не принял параметры подключения.
    public var isConfiguration: Bool { kind == "invalid_request" }

    public var errorDescription: String? {
        switch kind {
        case "auth_error": return "ElevenLabs не принял ключ. Проверьте его в настройках."
        case "quota_exceeded": return "На счёте ElevenLabs закончился лимит."
        case "unaccepted_terms": return "В кабинете ElevenLabs нужно принять условия Scribe."
        case "connection": return "Нет связи с распознаванием речи: \(message)"
        default: return message.isEmpty ? "Ошибка распознавания (\(kind))" : message
        }
    }
}

public enum ScribeLiveEvent: Sendable, Equatable {
    case started(model: String)
    /// Текст текущей фразы целиком; следующий заменяет предыдущий.
    case partial(text: String, language: String?, turnProbability: Double?)
    case committed(text: String)
    /// Итоговый язык только что завершённой фразы.
    case language(String)
    case failed(ScribeLiveError)
    case closed
}

public enum ScribeLiveMessage {
    public static func audio(_ pcm: Data, commit: Bool, sampleRate: Int) -> String {
        LiveURL.json([
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm.base64EncodedString(),
            "commit": commit,
            "sample_rate": sampleRate,
        ])
    }

    static let errorKinds: Set<String> = [
        "error", "auth_error", "quota_exceeded", "transcriber_error", "input_error", "invalid_request",
        "commit_throttled", "unaccepted_terms", "rate_limited", "queue_overflow", "resource_exhausted",
        "session_time_limit_exceeded", "chunk_size_exceeded", "insufficient_audio_activity",
    ]

    public static func parse(_ text: String) -> ScribeLiveEvent? {
        guard let object = LiveURL.object(text), let type = object["message_type"] as? String else { return nil }
        switch type {
        case "session_started":
            let config = object["config"] as? [String: Any]
            return .started(model: config?["model_id"] as? String ?? "")
        case "partial_transcript":
            return .partial(
                text: object["text"] as? String ?? "",
                language: object["language_code"] as? String,
                turnProbability: (object["turn_probability"] as? NSNumber)?.doubleValue
            )
        case "committed_transcript":
            return .committed(text: object["text"] as? String ?? "")
        case "committed_transcript_with_timestamps":
            guard let language = object["language_code"] as? String, !language.isEmpty else { return nil }
            return .language(language)
        default:
            guard errorKinds.contains(type) else { return nil }
            return .failed(ScribeLiveError(kind: type, message: object["error"] as? String ?? ""))
        }
    }
}

/// Один сеанс распознавания: открыть, слать звук, получать события, закрыть.
public final class ScribeLiveSession: @unchecked Sendable {
    public typealias Handler = @Sendable (ScribeLiveEvent) -> Void

    /// Звук уходит порциями не короче этого (сервер просит 0,1–1 с).
    private static let chunkSeconds = 0.12
    /// Столько отправленного звука помним, чтобы повторить после переподключения к запасной модели.
    private static let replayLimitSeconds = 30.0

    private let factory: any LiveSocketFactory
    private let handler: Handler
    private let lock = NSLock()
    private var configuration: ScribeLiveConfiguration
    private var socket: (any LiveSocket)?
    private var pending = Data()
    private var replay = Data()
    private var gotTranscript = false
    private var finished = false
    private var generation = 0
    private var sendChain: Task<Void, Never>?

    public init(
        configuration: ScribeLiveConfiguration,
        factory: any LiveSocketFactory = URLSessionSocketFactory(),
        handler: @escaping Handler
    ) {
        self.configuration = configuration
        self.factory = factory
        self.handler = handler
    }

    /// Модель, с которой сеанс работает сейчас (после отката — запасная).
    public var model: String { lock.withLock { configuration.model } }

    public func start() {
        let (socket, generation) = lock.withLock { () -> ((any LiveSocket)?, Int) in
            guard self.socket == nil, !finished else { return (nil, 0) }
            let socket = factory.open(configuration.request)
            self.socket = socket
            self.generation += 1
            return (socket, self.generation)
        }
        guard let socket else { return }
        Task { await self.receiveLoop(socket, generation: generation) }
    }

    /// PCM 16 бит, моно, с частотой из настройки. До `start()` звук копится и уйдёт первым.
    public func send(_ pcm: Data) {
        let chunkBytes = Int(Double(configuration.sampleRate) * 2 * Self.chunkSeconds)
        lock.withLock {
            guard !finished else { return }
            pending.append(pcm)
            guard let socket = self.socket, pending.count >= chunkBytes else { return }
            let chunk = pending
            pending = Data()
            remember(chunk)
            transmit(chunk, commit: false, over: socket)
        }
    }

    /// Закончить текущую фразу сейчас, не дожидаясь паузы.
    public func commit() {
        lock.withLock {
            guard !finished, let socket = self.socket else { return }
            let chunk = pending
            pending = Data()
            remember(chunk)
            transmit(chunk, commit: true, over: socket)
        }
    }

    public func close() {
        let socket = lock.withLock { () -> (any LiveSocket)? in
            finished = true
            defer { self.socket = nil }
            return self.socket
        }
        socket?.close()
    }

    private func remember(_ chunk: Data) {
        guard !gotTranscript else { return }
        replay.append(chunk)
        let limit = Int(Double(configuration.sampleRate) * 2 * Self.replayLimitSeconds)
        if replay.count > limit { replay.removeFirst(replay.count - limit) }
    }

    /// Вызывается под замком: куски звука уходят строго по порядку.
    private func transmit(_ chunk: Data, commit: Bool, over socket: any LiveSocket) {
        let message = ScribeLiveMessage.audio(chunk, commit: commit, sampleRate: configuration.sampleRate)
        let previous = sendChain
        sendChain = Task {
            await previous?.value
            // Ошибку отправки сообщит цикл чтения: соединение закроется.
            try? await socket.send(message)
        }
    }

    private func receiveLoop(_ socket: any LiveSocket, generation: Int) async {
        var failure: ScribeLiveError?
        while true {
            let text: String
            do {
                text = try await socket.receive()
            } catch {
                if failure == nil, !lock.withLock({ finished }) {
                    failure = ScribeLiveError(kind: "connection", message: error.localizedDescription)
                }
                break
            }
            guard let event = ScribeLiveMessage.parse(text) else { continue }
            switch event {
            case .failed(let error):
                // `commit_throttled` — не поломка: фраза просто закончится по паузе.
                if error.kind == "commit_throttled" { continue }
                failure = error
            case .partial(let text, _, _):
                if !text.isEmpty { markTranscript() }
                handler(event)
            case .committed:
                markTranscript()
                handler(event)
            default:
                handler(event)
            }
            if failure != nil { break }
        }

        let (stale, retry) = lock.withLock { () -> (Bool, Data?) in
            guard self.generation == generation else { return (true, nil) }
            self.socket = nil
            guard !finished, !gotTranscript, let failure, failure.isConfiguration,
                  let downgraded = configuration.downgraded
            else { return (false, nil) }
            configuration = downgraded
            let audio = replay + pending
            replay = Data()
            pending = Data()
            return (false, audio)
        }
        guard !stale else { return }
        socket.close()

        if let retry {
            start()
            if !retry.isEmpty { send(retry) }
            return
        }
        let wasFinished = lock.withLock { () -> Bool in
            let value = finished
            finished = true
            return value
        }
        if let failure, !wasFinished { handler(.failed(failure)) }
        handler(.closed)
    }

    private func markTranscript() {
        lock.withLock {
            gotTranscript = true
            replay = Data()
        }
    }
}
