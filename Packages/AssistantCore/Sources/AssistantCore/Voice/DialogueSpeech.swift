import Foundation

/// Потоковая озвучка ElevenLabs (Text to Dialogue WebSocket): текст уходит по мере того, как его
/// пишет Claude, звук возвращается кусками PCM и начинает играть, пока ответ ещё не дописан.
///
/// `eleven_v4_turbo` говорит по-узбекски, по-русски и по-английски одним голосом и начинает
/// отвечать примерно через 0,1 с. Один голос на соединение.
public struct DialogueSpeechConfiguration: Sendable, Equatable {
    public static let turboModel = "eleven_v4_turbo"

    public var apiKey: String
    public var voiceID: String
    public var model: String
    /// ISO 639-1. nil — модель определит язык по тексту.
    public var languageCode: String?
    /// Частота PCM: 16000, 22050, 24000 (44100 — только на тарифе Pro).
    public var sampleRate: Int
    /// 0…1: ниже — живее интонации, выше — ровнее.
    public var stability: Double?

    public init(
        apiKey: String,
        voiceID: String,
        model: String = DialogueSpeechConfiguration.turboModel,
        languageCode: String? = nil,
        sampleRate: Int = 24_000,
        stability: Double? = nil
    ) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.model = model
        self.languageCode = languageCode
        self.sampleRate = sampleRate
        self.stability = stability
    }

    public var url: URL {
        LiveURL.make("wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input", [
            ("model_id", model),
            ("output_format", "pcm_\(sampleRate)"),
            ("language_code", languageCode),
        ])
    }

    public var request: URLRequest {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15
        return request
    }
}

public struct DialogueSpeechError: Error, Sendable, Equatable, LocalizedError {
    /// Идентификатор ошибки сервера или `connection`.
    public let kind: String
    public let message: String

    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? {
        message.isEmpty ? "Ошибка озвучки (\(kind))" : message
    }
}

public enum DialogueSpeechEvent: Sendable, Equatable {
    /// Кусок звука: PCM 16 бит, моно, little-endian.
    case audio(Data)
    /// Сервер отдал весь звук и закрыл сеанс.
    case finished
    case failed(DialogueSpeechError)
}

public enum DialogueSpeechMessage {
    public static func open(voiceID: String, stability: Double?) -> String {
        var object: [String: Any] = ["voices": [voiceID]]
        if let stability { object["voice_settings"] = ["stability": stability] }
        return LiveURL.json(object)
    }

    public static func text(_ text: String, voiceID: String) -> String {
        LiveURL.json(["inputs": [["text": text, "voice_id": voiceID, "new_turn": false]]])
    }

    public static let flush = LiveURL.json(["flush": true])
    public static let keepAlive = LiveURL.json(["keep_alive": true])
    public static let close = LiveURL.json(["close_socket": true])

    public static func parse(_ text: String) -> DialogueSpeechEvent? {
        guard let object = LiveURL.object(text) else { return nil }
        if let error = object["error"] as? String {
            return .failed(DialogueSpeechError(kind: error, message: object["message"] as? String ?? ""))
        }
        if let encoded = object["audio"] as? String, let audio = Data(base64Encoded: encoded), !audio.isEmpty {
            return .audio(audio)
        }
        if object["is_final"] as? Bool == true { return .finished }
        return nil
    }
}

/// Одна реплика ассистента: открыть, дописывать текст, закончить.
public final class DialogueSpeechStream: @unchecked Sendable {
    public typealias Handler = @Sendable (DialogueSpeechEvent) -> Void

    private let configuration: DialogueSpeechConfiguration
    private let factory: any LiveSocketFactory
    private let handler: Handler
    private let lock = NSLock()
    private var socket: (any LiveSocket)?
    private var closing = false
    private var done = false
    private var keepAlive: Task<Void, Never>?
    /// Сообщения уходят строго по порядку: текст не должен обогнать регистрацию голоса.
    private var sendChain: Task<Void, Never>?

    public init(
        configuration: DialogueSpeechConfiguration,
        factory: any LiveSocketFactory = URLSessionSocketFactory(),
        handler: @escaping Handler
    ) {
        self.configuration = configuration
        self.factory = factory
        self.handler = handler
    }

    /// Открывает соединение заранее — пока Claude думает, рукопожатие уже проходит.
    public func start() {
        let socket = lock.withLock { () -> (any LiveSocket)? in
            guard self.socket == nil, !done else { return nil }
            let socket = factory.open(configuration.request)
            self.socket = socket
            return socket
        }
        guard let socket else { return }
        enqueue(DialogueSpeechMessage.open(voiceID: configuration.voiceID, stability: configuration.stability))
        Task { await self.receiveLoop(socket) }
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.enqueue(DialogueSpeechMessage.keepAlive)
            }
        }
    }

    /// Дописывает текст к реплике. Сервер сам копит около 40 знаков перед первым звуком.
    public func speak(_ text: String) {
        guard !text.isEmpty else { return }
        enqueue(DialogueSpeechMessage.text(text, voiceID: configuration.voiceID))
    }

    /// Озвучить уже присланное, не дожидаясь нового текста (пауза перед вызовом инструмента).
    public func flush() {
        enqueue(DialogueSpeechMessage.flush)
    }

    /// Текста больше не будет: сервер договаривает и закрывает сеанс.
    public func finish() {
        let shouldSend = lock.withLock { () -> Bool in
            guard !closing, !done else { return false }
            closing = true
            return true
        }
        guard shouldSend else { return }
        keepAlive?.cancel()
        enqueue(DialogueSpeechMessage.close, force: true)
    }

    /// Оборвать немедленно (пользователь перебил).
    public func cancel() {
        keepAlive?.cancel()
        let socket = lock.withLock { () -> (any LiveSocket)? in
            done = true
            defer { self.socket = nil }
            return self.socket
        }
        socket?.close()
    }

    private func enqueue(_ message: String, force: Bool = false) {
        lock.withLock {
            guard let socket = self.socket, !done, force || !closing else { return }
            let previous = sendChain
            sendChain = Task {
                await previous?.value
                try? await socket.send(message)
            }
        }
    }

    private func receiveLoop(_ socket: any LiveSocket) async {
        var outcome: DialogueSpeechEvent?
        while outcome == nil {
            do {
                let text = try await socket.receive()
                guard let event = DialogueSpeechMessage.parse(text) else { continue }
                switch event {
                case .audio: handler(event)
                case .finished, .failed: outcome = event
                }
            } catch {
                let (cancelled, closing) = lock.withLock { (done, self.closing) }
                if cancelled { return }
                // После `close_socket` сервер может закрыть соединение, не прислав `is_final`.
                outcome = closing
                    ? .finished
                    : .failed(DialogueSpeechError(kind: "connection", message: error.localizedDescription))
            }
        }
        keepAlive?.cancel()
        let alreadyDone = lock.withLock { () -> Bool in
            let value = done
            done = true
            self.socket = nil
            return value
        }
        socket.close()
        if !alreadyDone, let outcome { handler(outcome) }
    }
}
