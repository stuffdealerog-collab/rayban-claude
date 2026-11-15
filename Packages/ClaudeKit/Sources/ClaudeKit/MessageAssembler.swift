import Foundation

/// Сообщение ассистента, собранное из SSE-событий Messages API.
public struct AssembledMessage: Sendable {
    public var id: String?
    public var model: String?
    /// Блоки контента в исходном виде (включая thinking с signature, server_tool_use, fallback),
    /// чтобы вернуть их в следующий запрос без изменений.
    public var content: [JSONValue] = []
    public var stopReason: String?
    public var stopDetails: JSONValue?
    public var usage: JSONValue?
    /// `tool_use_id` -> сырой `partial_json`, который не удалось разобрать как JSON-объект.
    public var invalidToolInputs: [String: String] = [:]

    public init() {}

    /// Весь текст ответа (только блоки `text`).
    public var text: String {
        content.compactMap { block in
            block.blockType == "text" ? block["text"]?.stringValue : nil
        }.joined()
    }
}

/// Инкрементальные события стрима, интересные UI и озвучке.
public enum StreamDelta: Sendable, Equatable {
    case textDelta(String)
    case blockStarted(type: String, name: String?)
    case fallback(from: String?, to: String?)
}

/// Ошибка, пришедшая событием `error` внутри стрима.
public struct StreamedAPIError: Error, Sendable, Equatable, LocalizedError {
    public var type: String
    public var message: String
    public var errorDescription: String? { "\(type): \(message)" }
}

/// Собирает `AssembledMessage` из событий `message_start` / `content_block_*` / `message_delta`.
public struct MessageAssembler: Sendable {
    private var message = AssembledMessage()
    private var blocks: [Int: [String: JSONValue]] = [:]
    private var textBuffers: [Int: String] = [:]
    private var thinkingBuffers: [Int: String] = [:]
    private var jsonBuffers: [Int: String] = [:]
    private var citationBuffers: [Int: [JSONValue]] = [:]
    private(set) public var isFinished = false

    public init() {}

    /// Обрабатывает одно SSE-событие. Возвращает дельты для UI. Бросает `StreamedAPIError` на событии `error`.
    public mutating func handle(_ event: SSEEvent) throws -> [StreamDelta] {
        guard let payload = try? JSONValue.decode(event.data) else { return [] }
        let type = payload.blockType ?? event.event ?? ""

        switch type {
        case "message_start":
            if let start = payload["message"] {
                message.id = start["id"]?.stringValue
                message.model = start["model"]?.stringValue
                message.usage = start["usage"]
            }
            return []

        case "content_block_start":
            guard let index = payload["index"].flatMap(Self.intValue),
                  let block = payload["content_block"]?.objectValue
            else { return [] }
            blocks[index] = block
            let blockType = block["type"]?.stringValue ?? "unknown"
            if blockType == "fallback" {
                return [.fallback(from: block["from"]?["model"]?.stringValue, to: block["to"]?["model"]?.stringValue)]
            }
            return [.blockStarted(type: blockType, name: block["name"]?.stringValue)]

        case "content_block_delta":
            guard let index = payload["index"].flatMap(Self.intValue),
                  let delta = payload["delta"]
            else { return [] }
            switch delta.blockType {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                textBuffers[index, default: ""] += text
                return text.isEmpty ? [] : [.textDelta(text)]
            case "thinking_delta":
                thinkingBuffers[index, default: ""] += delta["thinking"]?.stringValue ?? ""
            case "signature_delta":
                if let signature = delta["signature"]?.stringValue {
                    blocks[index]?["signature"] = .string(signature)
                }
            case "input_json_delta":
                jsonBuffers[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
            case "citations_delta":
                if let citation = delta["citation"] {
                    citationBuffers[index, default: []].append(citation)
                }
            default:
                break // неизвестные дельты игнорируем — блок вернётся как есть
            }
            return []

        case "content_block_stop":
            guard let index = payload["index"].flatMap(Self.intValue) else { return [] }
            finalizeBlock(at: index)
            return []

        case "message_delta":
            if let delta = payload["delta"] {
                if let stop = delta["stop_reason"]?.stringValue { message.stopReason = stop }
                if let details = delta["stop_details"], details != .null { message.stopDetails = details }
            }
            if let usage = payload["usage"] { message.usage = usage }
            return []

        case "message_stop":
            isFinished = true
            return []

        case "error":
            let error = payload["error"]
            throw StreamedAPIError(
                type: error?["type"]?.stringValue ?? "error",
                message: error?["message"]?.stringValue ?? event.data
            )

        default:
            return [] // ping и будущие типы событий
        }
    }

    /// Итоговое сообщение. Незакрытые блоки (обрыв стрима) тоже финализируются.
    public mutating func finish() -> AssembledMessage {
        for index in blocks.keys.sorted() where !finalizedIndices.contains(index) {
            finalizeBlock(at: index)
        }
        message.content = finalized.keys.sorted().compactMap { finalized[$0] }
        return message
    }

    // MARK: - Private

    private var finalized: [Int: JSONValue] = [:]
    private var finalizedIndices: Set<Int> { Set(finalized.keys) }

    private mutating func finalizeBlock(at index: Int) {
        guard var block = blocks[index] else { return }

        if let text = textBuffers[index] {
            let existing = block["text"]?.stringValue ?? ""
            block["text"] = .string(existing + text)
        }
        if let thinking = thinkingBuffers[index] {
            let existing = block["thinking"]?.stringValue ?? ""
            block["thinking"] = .string(existing + thinking)
        }
        if let citations = citationBuffers[index] {
            let existing = block["citations"]?.arrayValue ?? []
            block["citations"] = .array(existing + citations)
        }
        if let raw = jsonBuffers[index] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Инструмент без параметров: оставляем input из content_block_start (обычно {}).
                if block["input"] == nil { block["input"] = .object([:]) }
            } else if let parsed = try? JSONValue.decode(trimmed), case .object = parsed {
                block["input"] = parsed
            } else {
                // eager_input_streaming: API не валидирует JSON — разбор может провалиться.
                block["input"] = .object([:])
                if let id = block["id"]?.stringValue {
                    message.invalidToolInputs[id] = raw
                }
            }
        }

        finalized[index] = .object(block)
        blocks[index] = nil
        textBuffers[index] = nil
        thinkingBuffers[index] = nil
        jsonBuffers[index] = nil
        citationBuffers[index] = nil
    }

    private static func intValue(_ value: JSONValue) -> Int? {
        switch value {
        case .int(let int): return Int(int)
        case .double(let double): return Int(double)
        default: return nil
        }
    }
}
