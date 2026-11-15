import Foundation
import Testing
@testable import ClaudeKit

/// Подменяет сеть: отдаёт заранее заготовленные SSE-ответы по очереди и запоминает тела запросов.
final class MockAPIProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requests: [JSONValue] = []
    /// Задержка следующего ответа (имитация долгого запроса, который успевают прервать).
    nonisolated(unsafe) static var nextDelay: Double = 0
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        if let body = Self.bodyData(of: request), let json = try? JSONValue.decode(body) {
            Self.requests.append(json)
        }
        let next = Self.responses.isEmpty ? (status: 500, body: "{}") : Self.responses.removeFirst()
        let delay = Self.nextDelay
        Self.nextDelay = 0
        Self.lock.unlock()

        let deliver: @Sendable () -> Void = { [self] in
            guard !self.isStopped else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["content-type": "text/event-stream"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(next.body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            deliver()
        }
    }

    private var isStopped = false
    override func stopLoading() { isStopped = true }

    private static func bodyData(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func makeClient() -> ClaudeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAPIProtocol.self]
        return ClaudeClient(session: URLSession(configuration: configuration), maxRetries: 0)
    }
}

struct FakePhotoTool: ClaudeTool {
    let name = "take_photo"
    let description = "Take a photo"
    let inputSchema: JSONValue = ["type": "object", "properties": ["reason": ["type": "string"]]]
    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        ToolOutput(content: [.jpeg(Data([0xFF, 0xD8, 0xFF])), .text("photo")])
    }
}

let finalAnswerStream = sse([
    ("message_start", #"{"type":"message_start","message":{"id":"msg_2","model":"claude-opus-5-5"}}"#),
    ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" Это кружка."}}"#),
    ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
    ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
    ("message_stop", #"{"type":"message_stop"}"#),
])

actor EventLog {
    var events: [String] = []
    func add(_ event: AgentEvent) {
        switch event {
        case .textDelta(let text): events.append("text:\(text)")
        case .toolStarted(let name, _): events.append("start:\(name)")
        case .toolFinished(let name, _): events.append("done:\(name)")
        case .serverToolStarted(let name): events.append("server:\(name)")
        case .fallback: events.append("fallback")
        }
    }
}

@Suite(.serialized) struct ConversationTests {
    let configuration = ClaudeConfiguration(apiKey: "test-key", systemPrompt: "Голосовой ассистент.")

    @Test func runsToolLoopAndKeepsHistoryAppendOnly() async throws {
        MockAPIProtocol.responses = [(200, toolTurnStream), (200, finalAnswerStream)]
        MockAPIProtocol.requests = []
        let conversation = ClaudeConversation(client: MockAPIProtocol.makeClient())
        let log = EventLog()

        let outcome = try await conversation.send(
            userText: "Что передо мной?", configuration: configuration, tools: [FakePhotoTool()]
        ) { await log.add($0) }

        #expect(outcome == .completed(text: "Сейчас посмотрю. Это кружка."))
        let events = await log.events
        #expect(events.contains("start:take_photo"))
        #expect(events.contains("done:take_photo"))

        let messages = await conversation.messages
        #expect(messages.count == 4) // user, assistant(tool_use), user(tool_result), assistant
        #expect(messages[1]["content"]?.arrayValue?.first?["signature"] == "sig==") // thinking возвращён как есть
        let toolResult = messages[2]["content"]?.arrayValue?.first
        #expect(toolResult?["type"] == "tool_result")
        #expect(toolResult?["tool_use_id"] == "toolu_1")
        #expect(toolResult?["content"]?.arrayValue?.first?["source"]?["media_type"] == "image/jpeg")

        // Тело первого запроса: стриминг, effort, fallbacks, eager_input_streaming, веб-поиск, кэш.
        let first = MockAPIProtocol.requests[0]
        #expect(first["model"] == "claude-opus-5-5")
        #expect(first["stream"] == true)
        #expect(first["output_config"]?["effort"] == "low")
        #expect(first["fallbacks"] == "default")
        #expect(first["cache_control"]?["type"] == "ephemeral")
        #expect(first["thinking"] == nil)
        let tools = first["tools"]?.arrayValue ?? []
        #expect(tools.first?["eager_input_streaming"] == true)
        #expect(tools.contains { $0["type"] == "web_search_20260209" })
        // Второй запрос начинается с той же истории (append-only).
        let second = MockAPIProtocol.requests[1]
        #expect(second["messages"]?.arrayValue?.count == 3)
    }

    @Test func refusalRollsBackHistory() async throws {
        let refusal = sse([
            ("message_start", #"{"type":"message_start","message":{"id":"m","model":"claude-opus-5-5"}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"category":"bio"}}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        MockAPIProtocol.responses = [(200, refusal)]
        MockAPIProtocol.requests = []
        let conversation = ClaudeConversation(client: MockAPIProtocol.makeClient())

        let outcome = try await conversation.send(userText: "...", configuration: configuration, tools: []) { _ in }
        #expect(outcome == .refused(category: "bio"))
        #expect(await conversation.isEmpty)
    }

    @Test func httpErrorRollsBackAndSurfacesMessage() async throws {
        MockAPIProtocol.responses = [(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)]
        MockAPIProtocol.requests = []
        let conversation = ClaudeConversation(client: MockAPIProtocol.makeClient())

        await #expect(throws: ClaudeAPIError.self) {
            _ = try await conversation.send(userText: "привет", configuration: configuration, tools: []) { _ in }
        }
        #expect(await conversation.isEmpty)
    }

    @Test func invalidToolJSONReturnsErrorResult() async throws {
        let badTool = sse([
            ("message_start", #"{"type":"message_start","message":{"id":"m","model":"claude-opus-5-5"}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_bad","name":"take_photo","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"reason\": "}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        MockAPIProtocol.responses = [(200, badTool), (200, finalAnswerStream)]
        MockAPIProtocol.requests = []
        let conversation = ClaudeConversation(client: MockAPIProtocol.makeClient())
        let log = EventLog()

        _ = try await conversation.send(userText: "фото", configuration: configuration, tools: [FakePhotoTool()]) { await log.add($0) }
        let result = await conversation.messages[2]["content"]?.arrayValue?.first
        #expect(result?["is_error"] == true)
        #expect(result?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("INVALID_JSON") == true)
        #expect(await log.events.contains("start:take_photo") == false) // инструмент не запускался
    }

    @Test func interruptedTurnDoesNotCorruptNextTurn() async throws {
        MockAPIProtocol.responses = [(200, finalAnswerStream), (200, finalAnswerStream)]
        MockAPIProtocol.requests = []
        MockAPIProtocol.nextDelay = 1.0
        let conversation = ClaudeConversation(client: MockAPIProtocol.makeClient())
        let configuration = self.configuration

        let first = Task {
            try await conversation.send(userText: "первый", configuration: configuration, tools: []) { _ in }
        }
        try await Task.sleep(nanoseconds: 200_000_000) // первый ход ждёт ответа сети
        first.cancel()

        let outcome = try await conversation.send(userText: "второй", configuration: configuration, tools: []) { _ in }
        #expect(outcome == .completed(text: " Это кружка."))
        _ = try? await first.value

        let messages = await conversation.messages
        #expect(messages.count == 2) // только второй ход; прерванный откатился и не задел его
        #expect(messages.first?["content"]?.arrayValue?.first?["text"] == "второй")

        await conversation.reset()
        #expect(await conversation.isEmpty)
    }
}
