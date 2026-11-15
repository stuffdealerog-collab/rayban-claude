import Foundation
import Testing
@testable import ClaudeKit

/// Склеивает SSE-события в поток так, как их отдаёт сервер.
func sse(_ events: [(String, String)]) -> String {
    events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
}

func assemble(_ stream: String) throws -> (AssembledMessage, [StreamDelta]) {
    var splitter = LineSplitter()
    var parser = SSEParser()
    var assembler = MessageAssembler()
    var deltas: [StreamDelta] = []
    for byte in Array(stream.utf8) {
        if let line = splitter.append(byte), let event = parser.feed(line: line) {
            deltas += try assembler.handle(event)
        }
    }
    if let event = parser.finish() { deltas += try assembler.handle(event) }
    return (assembler.finish(), deltas)
}

let toolTurnStream = sse([
    ("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":10}}}"#),
    ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig=="}}"#),
    ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
    ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Сейчас "}}"#),
    ("ping", #"{"type":"ping"}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"посмотрю."}}"#),
    ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
    ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"take_photo","input":{}}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"reason\": \"what"}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":" is it\", \"count\": 3}"}}"#),
    ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
    ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#),
    ("message_stop", #"{"type":"message_stop"}"#),
])

@Suite struct SSEAndAssemblerTests {
    @Test func parsesMultilineDataAndComments() {
        var parser = SSEParser()
        #expect(parser.feed(line: ": comment") == nil)
        #expect(parser.feed(line: "event: x") == nil)
        #expect(parser.feed(line: "data: a") == nil)
        #expect(parser.feed(line: "data: b\r") == nil)
        #expect(parser.feed(line: "") == SSEEvent(event: "x", data: "a\nb"))
    }

    @Test func assemblesToolTurn() throws {
        let (message, deltas) = try assemble(toolTurnStream)
        #expect(message.id == "msg_1")
        #expect(message.stopReason == "tool_use")
        #expect(message.content.count == 3)
        #expect(message.content[0]["signature"] == "sig==")
        #expect(message.text == "Сейчас посмотрю.")
        #expect(message.content[2]["input"] == ["reason": "what is it", "count": 3])
        #expect(message.invalidToolInputs.isEmpty)
        #expect(deltas.contains(.textDelta("Сейчас ")))
        #expect(deltas.contains(.blockStarted(type: "tool_use", name: "take_photo")))
    }

    @Test func recordsInvalidToolInput() throws {
        let stream = sse([
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_x","name":"t","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\": \"unterminated"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let (message, _) = try assemble(stream)
        #expect(message.invalidToolInputs["toolu_x"] == "{\"a\": \"unterminated")
        #expect(message.content[0]["input"] == [:])
    }

    @Test func throwsOnStreamError() {
        let stream = sse([("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)])
        #expect(throws: StreamedAPIError.self) { try assemble(stream) }
    }

    @Test func refusalCarriesStopDetails() throws {
        let stream = sse([
            ("message_start", #"{"type":"message_start","message":{"id":"m","model":"claude-opus-5-5"}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let (message, _) = try assemble(stream)
        #expect(message.stopReason == "refusal")
        #expect(message.stopDetails?["category"] == "cyber")
        #expect(message.content.isEmpty)
    }
}

@Suite struct JSONValueTests {
    @Test func integersStayIntegers() throws {
        let value = try JSONValue.decode(#"{"b":3,"a":1.5,"c":[true,null,"x"]}"#)
        let text = String(decoding: try value.encoded(), as: UTF8.self)
        #expect(text == #"{"a":1.5,"b":3,"c":[true,null,"x"]}"#)
    }
}

@Suite struct FallbackEchoTests {
    @Test func stripsInternalBlocksBeforeBoundary() {
        let content: [JSONValue] = [
            ["type": "thinking", "thinking": "", "signature": "s1"],
            ["type": "text", "text": "Частичный "],
            ["type": "server_tool_use", "id": "srv_1", "name": "web_search", "input": [:]],
            ["type": "web_search_tool_result", "tool_use_id": "srv_1", "content": []],
            ["type": "server_tool_use", "id": "srv_2", "name": "web_search", "input": [:]],
            ["type": "tool_use", "id": "toolu_old", "name": "take_photo", "input": [:]],
            ["type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-4-8"]],
            ["type": "thinking", "thinking": "", "signature": "s2"],
            ["type": "text", "text": "ответ"],
            ["type": "tool_use", "id": "toolu_new", "name": "take_photo", "input": [:]],
        ]
        let echo = FallbackEcho.sanitize(content)
        #expect(echo.map { $0.blockType ?? "" } == [
            "text", "server_tool_use", "web_search_tool_result", "fallback", "thinking", "text", "tool_use",
        ])
        #expect(FallbackEcho.executableToolUses(content).map { $0["id"] } == ["toolu_new"])
    }

    @Test func noBoundaryKeepsEverything() {
        let content: [JSONValue] = [["type": "thinking", "signature": "s"], ["type": "text", "text": "hi"]]
        #expect(FallbackEcho.sanitize(content) == content)
    }
}

@Suite struct SpeechTextTests {
    @Test func chunksSentences() {
        var chunker = SentenceChunker()
        #expect(chunker.append("Привет! Цена 3.5 ру") == ["Привет!"])
        #expect(chunker.append("бля. Ещё") == ["Цена 3.5 рубля."])
        #expect(chunker.flush() == "Ещё")
        #expect(chunker.flush() == nil)
    }

    @Test func cleansMarkdown() {
        #expect(SpeechText.clean("**Важно**: см. [сайт](https://x.y) и `код`") == "Важно: см. сайт и код")
        #expect(SpeechText.clean("- первый пункт") == "первый пункт")
    }
}

@Suite struct SchemaValidatorTests {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "minutes": ["type": "integer"],
            "mode": ["type": "string", "enum": ["a", "b"]],
        ],
        "required": ["title"],
    ]

    @Test func acceptsValidInput() {
        #expect(SchemaValidator.validate(["title": "x", "minutes": 5, "mode": "a"], against: schema) == nil)
    }

    @Test func rejectsInvalidInput() {
        #expect(SchemaValidator.validate([:], against: schema) != nil)
        #expect(SchemaValidator.validate(["title": 1], against: schema) != nil)
        #expect(SchemaValidator.validate(["title": "x", "minutes": 1.5], against: schema) != nil)
        #expect(SchemaValidator.validate(["title": "x", "mode": "c"], against: schema) != nil)
    }
}
