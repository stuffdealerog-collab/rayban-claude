import Foundation
import Testing
@testable import AssistantCore

/// Сокет-заглушка: входящие сообщения задаёт тест, исходящие записываются.
final class FakeSocket: LiveSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    private var closed = false
    private let incoming: AsyncStream<String>
    private let feed: AsyncStream<String>.Continuation

    init() {
        (incoming, feed) = AsyncStream.makeStream(of: String.self)
    }

    func send(_ text: String) async throws {
        lock.withLock { sent.append(text) }
    }

    func receive() async throws -> String {
        for await message in incoming { return message }
        throw URLError(.networkConnectionLost)
    }

    func close() {
        lock.withLock { closed = true }
        feed.finish()
    }

    func push(_ message: String) { feed.yield(message) }
    func drop() { feed.finish() }
    var sentMessages: [String] { lock.withLock { sent } }
    var isClosed: Bool { lock.withLock { closed } }
}

final class FakeFactory: LiveSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [(URLRequest, FakeSocket)] = []

    func open(_ request: URLRequest) -> any LiveSocket {
        let socket = FakeSocket()
        lock.withLock { opened.append((request, socket)) }
        return socket
    }

    var sockets: [FakeSocket] { lock.withLock { opened.map(\.1) } }
    var requests: [URLRequest] { lock.withLock { opened.map(\.0) } }
}

final class EventBox<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Event] = []
    func add(_ event: Event) { lock.withLock { items.append(event) } }
    var all: [Event] { lock.withLock { items } }
}

/// Ждёт условие до секунды: события приходят из фоновых задач.
func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

private func query(_ url: URL) -> [String] {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { "\($0.name)=\($0.value ?? "")" } ?? []
}

@Suite struct ScribeLiveTests {
    @Test func urlForUzbekWithRussianAndEnglish() {
        let configuration = ScribeLiveConfiguration(
            apiKey: "k", languageCode: "uz", secondaryLanguages: ["ru", "en", "uz"], keyterms: ["Жарвис", ""]
        )
        let items = query(configuration.url)
        #expect(configuration.url.absoluteString.hasPrefix("wss://api.elevenlabs.io/v1/speech-to-text/realtime?"))
        #expect(items.contains("model_id=scribe_v3_live"))
        #expect(items.contains("audio_format=pcm_16000"))
        #expect(items.contains("commit_strategy=turn_prediction"))
        #expect(items.contains("vad_silence_threshold_secs=0.70"))
        #expect(items.contains("language_code=uz"))
        #expect(items.filter { $0.hasPrefix("secondary_languages=") } == ["secondary_languages=ru", "secondary_languages=en"])
        #expect(items.contains("keyterms=Жарвис"))
        #expect(!items.contains { $0.hasPrefix("multilang_mode") })
        #expect(configuration.request.value(forHTTPHeaderField: "xi-api-key") == "k")
    }

    @Test func multilingualDropsLanguageHints() {
        let configuration = ScribeLiveConfiguration(
            apiKey: "k", languageCode: "uz", secondaryLanguages: ["ru"], multilingual: true, detectLanguage: true
        )
        let items = query(configuration.url)
        #expect(items.contains("multilang_mode=true"))
        #expect(!items.contains { $0.hasPrefix("language_code=") || $0.hasPrefix("secondary_languages=") })
        #expect(items.contains("include_language_detection=true"))
        #expect(items.contains("include_timestamps=true"))
    }

    @Test func downgradeKeepsOnlyWhatOldModelAccepts() {
        let configuration = ScribeLiveConfiguration(
            apiKey: "k", languageCode: "uz", secondaryLanguages: ["ru"], multilingual: true, keyterms: ["Жарвис"]
        )
        let downgraded = configuration.downgraded
        #expect(downgraded?.model == "scribe_v2_realtime")
        #expect(downgraded?.commit == .vad)
        let items = query(downgraded!.url)
        #expect(items.contains("language_code=uz"))
        #expect(!items.contains { $0.hasPrefix("multilang_mode") || $0.hasPrefix("keyterms") || $0.hasPrefix("secondary_languages") })
        #expect(downgraded?.downgraded == nil)
    }

    @Test func parsesServerMessages() {
        #expect(ScribeLiveMessage.parse(#"{"message_type":"session_started","session_id":"s","config":{"model_id":"scribe_v3_live"}}"#)
            == .started(model: "scribe_v3_live"))
        #expect(ScribeLiveMessage.parse(#"{"message_type":"partial_transcript","text":"Salom","language_code":"uz","turn_probability":0.25}"#)
            == .partial(text: "Salom", language: "uz", turnProbability: 0.25))
        #expect(ScribeLiveMessage.parse(#"{"message_type":"partial_transcript","text":"","language_code":null}"#)
            == .partial(text: "", language: nil, turnProbability: nil))
        #expect(ScribeLiveMessage.parse(#"{"message_type":"committed_transcript","text":"Salom, Жарвис"}"#)
            == .committed(text: "Salom, Жарвис"))
        #expect(ScribeLiveMessage.parse(#"{"message_type":"committed_transcript_with_timestamps","text":"x","language_code":"ru","words":[]}"#)
            == .language("ru"))
        #expect(ScribeLiveMessage.parse(#"{"message_type":"auth_error","error":"bad key"}"#)
            == .failed(ScribeLiveError(kind: "auth_error", message: "bad key")))
        #expect(ScribeLiveMessage.parse(#"{"message_type":"diarized_transcript","text":"x"}"#) == nil)
        #expect(ScribeLiveMessage.parse("not json") == nil)
        #expect(ScribeLiveError(kind: "quota_exceeded", message: "").isPermanent)
        #expect(!ScribeLiveError(kind: "connection", message: "").isPermanent)
    }

    @Test func audioMessageShape() throws {
        let message = ScribeLiveMessage.audio(Data([1, 2, 3, 4]), commit: true, sampleRate: 16_000)
        let object = try #require(LiveURL.object(message))
        #expect(object["message_type"] as? String == "input_audio_chunk")
        #expect(object["audio_base_64"] as? String == "AQIDBA==")
        #expect(object["commit"] as? Bool == true)
        #expect(object["sample_rate"] as? Int == 16_000)
    }

    @Test func buffersBeforeStartAndSendsInOrder() async throws {
        let factory = FakeFactory()
        let events = EventBox<ScribeLiveEvent>()
        let session = ScribeLiveSession(configuration: .init(apiKey: "k"), factory: factory) { events.add($0) }

        // Звук до подключения (начало фразы) не теряется.
        session.send(Data(repeating: 1, count: 2_000))
        session.start()
        session.send(Data(repeating: 2, count: 2_000))
        session.send(Data(repeating: 3, count: 100))
        session.commit()

        let socket = try #require(factory.sockets.first)
        #expect(await eventually { socket.sentMessages.count == 2 })
        let first = try #require(LiveURL.object(socket.sentMessages[0]))
        let firstAudio = try #require(Data(base64Encoded: first["audio_base_64"] as? String ?? ""))
        #expect(firstAudio.count == 4_000)
        #expect(firstAudio.first == 1 && firstAudio.last == 2)
        #expect(first["commit"] as? Bool == false)
        let second = try #require(LiveURL.object(socket.sentMessages[1]))
        #expect(second["commit"] as? Bool == true)
        #expect(Data(base64Encoded: second["audio_base_64"] as? String ?? "")?.count == 100)

        socket.push(#"{"message_type":"partial_transcript","text":"Привет"}"#)
        socket.push(#"{"message_type":"committed_transcript","text":"Привет, Джарвис"}"#)
        #expect(await eventually { events.all.count == 2 })
        #expect(events.all.last == .committed(text: "Привет, Джарвис"))

        session.close()
        #expect(await eventually { events.all.last == .closed })
        #expect(!events.all.contains { if case .failed = $0 { return true } else { return false } })
    }

    @Test func fallsBackToOlderModelWhenParametersRejected() async throws {
        let factory = FakeFactory()
        let events = EventBox<ScribeLiveEvent>()
        let session = ScribeLiveSession(
            configuration: .init(apiKey: "k", languageCode: "uz", multilingual: true), factory: factory
        ) { events.add($0) }
        session.start()
        session.send(Data(repeating: 7, count: 4_000))
        let first = try #require(factory.sockets.first)
        #expect(await eventually { first.sentMessages.count == 1 })

        first.push(#"{"message_type":"invalid_request","error":"multilang_mode is not supported"}"#)
        #expect(await eventually { factory.sockets.count == 2 })
        #expect(session.model == "scribe_v2_realtime")
        #expect(query(factory.requests[1].url!).contains("model_id=scribe_v2_realtime"))

        // Уже отправленный звук повторяется новому соединению.
        let second = factory.sockets[1]
        #expect(await eventually { second.sentMessages.count == 1 })
        let replayed = try #require(LiveURL.object(second.sentMessages[0]))
        #expect(Data(base64Encoded: replayed["audio_base_64"] as? String ?? "")?.count == 4_000)
        #expect(events.all.isEmpty)

        second.push(#"{"message_type":"committed_transcript","text":"Salom"}"#)
        #expect(await eventually { events.all == [.committed(text: "Salom")] })
        session.close()
    }

    @Test func reportsPermanentErrorOnce() async throws {
        let factory = FakeFactory()
        let events = EventBox<ScribeLiveEvent>()
        let session = ScribeLiveSession(configuration: .init(apiKey: "bad"), factory: factory) { events.add($0) }
        session.start()
        let socket = try #require(factory.sockets.first)
        socket.push(#"{"message_type":"auth_error","error":"Invalid API key"}"#)
        #expect(await eventually { events.all.last == .closed })
        #expect(events.all == [.failed(ScribeLiveError(kind: "auth_error", message: "Invalid API key")), .closed])
        #expect(factory.sockets.count == 1)
    }

    @Test func lostConnectionIsAnError() async throws {
        let factory = FakeFactory()
        let events = EventBox<ScribeLiveEvent>()
        let session = ScribeLiveSession(configuration: .init(apiKey: "k"), factory: factory) { events.add($0) }
        session.start()
        try #require(factory.sockets.first).drop()
        #expect(await eventually { events.all.last == .closed })
        guard case .failed(let error) = events.all.first else {
            Issue.record("ожидалась ошибка связи")
            return
        }
        #expect(error.kind == "connection")
    }
}

@Suite struct DialogueSpeechTests {
    @Test func urlAndMessages() throws {
        let configuration = DialogueSpeechConfiguration(apiKey: "k", voiceID: "v1", languageCode: "uz")
        let items = query(configuration.url)
        #expect(configuration.url.absoluteString.hasPrefix("wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input?"))
        #expect(items == ["model_id=eleven_v4_turbo", "output_format=pcm_24000", "language_code=uz"])
        #expect(configuration.request.value(forHTTPHeaderField: "xi-api-key") == "k")

        let open = try #require(LiveURL.object(DialogueSpeechMessage.open(voiceID: "v1", stability: 0.4)))
        #expect(open["voices"] as? [String] == ["v1"])
        #expect((open["voice_settings"] as? [String: Any])?["stability"] as? Double == 0.4)
        #expect(open["xi_api_key"] == nil)

        let text = try #require(LiveURL.object(DialogueSpeechMessage.text("Salom!", voiceID: "v1")))
        let input = try #require((text["inputs"] as? [[String: Any]])?.first)
        #expect(input["text"] as? String == "Salom!")
        #expect(input["voice_id"] as? String == "v1")
        #expect(DialogueSpeechMessage.close == #"{"close_socket":true}"#)
    }

    @Test func parsesServerMessages() {
        #expect(DialogueSpeechMessage.parse(#"{"audio":"AQID","alignment":null}"#) == .audio(Data([1, 2, 3])))
        #expect(DialogueSpeechMessage.parse(#"{"is_final":true}"#) == .finished)
        #expect(DialogueSpeechMessage.parse(#"{"is_final_audio_for_turn":true}"#) == nil)
        #expect(DialogueSpeechMessage.parse(#"{"message":"Model not allowed","error":"invalid_model","code":1008}"#)
            == .failed(DialogueSpeechError(kind: "invalid_model", message: "Model not allowed")))
    }

    @Test func streamsTextInOrderAndFinishes() async throws {
        let factory = FakeFactory()
        let events = EventBox<DialogueSpeechEvent>()
        let stream = DialogueSpeechStream(configuration: .init(apiKey: "k", voiceID: "v1"), factory: factory) { events.add($0) }
        stream.start()
        stream.speak("Завтра в десять созвон.")
        stream.speak(" Вечер свободен.")
        stream.finish()
        stream.speak("это уже не уйдёт")

        let socket = try #require(factory.sockets.first)
        #expect(await eventually { socket.sentMessages.count == 4 })
        let sent = socket.sentMessages
        #expect(sent[0].contains("\"voices\""))
        #expect(sent[1].contains("Завтра в десять созвон."))
        #expect(sent[2].contains("Вечер свободен."))
        #expect(sent[3] == DialogueSpeechMessage.close)

        socket.push(#"{"audio":"AQID"}"#)
        socket.push(#"{"is_final_audio_for_turn":true}"#)
        socket.push(#"{"audio":"BAU="}"#)
        socket.push(#"{"is_final":true}"#)
        #expect(await eventually { events.all.last == .finished })
        #expect(events.all == [.audio(Data([1, 2, 3])), .audio(Data([4, 5])), .finished])
    }

    @Test func serverErrorAndCancel() async throws {
        let factory = FakeFactory()
        let events = EventBox<DialogueSpeechEvent>()
        let stream = DialogueSpeechStream(configuration: .init(apiKey: "k", voiceID: "v1"), factory: factory) { events.add($0) }
        stream.start()
        let socket = try #require(factory.sockets.first)
        socket.push(#"{"message":"Unsupported output format","error":"invalid_output_format","code":1008}"#)
        #expect(await eventually { !events.all.isEmpty })
        #expect(events.all == [.failed(DialogueSpeechError(kind: "invalid_output_format", message: "Unsupported output format"))])

        // Перебили на полуслове: событий больше нет.
        let cancelled = EventBox<DialogueSpeechEvent>()
        let second = DialogueSpeechStream(configuration: .init(apiKey: "k", voiceID: "v1"), factory: factory) { cancelled.add($0) }
        second.start()
        second.speak("Долгий ответ")
        second.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(cancelled.all.isEmpty)
        #expect(factory.sockets[1].isClosed)
    }

    @Test func closedAfterFinishCountsAsFinished() async throws {
        let factory = FakeFactory()
        let events = EventBox<DialogueSpeechEvent>()
        let stream = DialogueSpeechStream(configuration: .init(apiKey: "k", voiceID: "v1"), factory: factory) { events.add($0) }
        stream.start()
        stream.speak("Готово.")
        stream.finish()
        try #require(factory.sockets.first).drop()
        #expect(await eventually { events.all == [.finished] })
    }
}
