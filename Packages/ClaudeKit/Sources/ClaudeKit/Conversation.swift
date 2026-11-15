import Foundation

/// Параметры запросов к Claude.
public struct ClaudeConfiguration: Sendable {
    public var apiKey: String
    public var model: String
    public var systemPrompt: String
    /// Ограничение на ответ (вместе с thinking). Реплики голосового ассистента короткие.
    public var maxTokens: Int
    /// `output_config.effort`. Для живого диалога `low` — быстрее и дешевле; на Claude Opus 5.5
    /// значение по умолчанию `medium`, поэтому задаём явно.
    public var effort: String?
    /// Серверный fallback при отказе классификатора (`fallbacks: "default"`).
    public var serverFallbacks: Bool
    /// Серверный инструмент веб-поиска.
    public var webSearch: Bool
    /// Контекстное редактирование: когда диалог разрастается (снимки, результаты поиска),
    /// сервер сам убирает старые результаты инструментов. История на клиенте не меняется.
    public var contextEditing: Bool
    /// Инструменты, чьи результаты нельзя убирать (например, заметки памяти).
    public var contextEditingExcludedTools: [String]

    public init(
        apiKey: String,
        model: String = "claude-opus-5-5",
        systemPrompt: String,
        maxTokens: Int = 16_000,
        effort: String? = "low",
        serverFallbacks: Bool = true,
        webSearch: Bool = true,
        contextEditing: Bool = true,
        contextEditingExcludedTools: [String] = []
    ) {
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.effort = effort
        self.serverFallbacks = serverFallbacks
        self.webSearch = webSearch
        self.contextEditing = contextEditing
        self.contextEditingExcludedTools = contextEditingExcludedTools
    }

    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let contextManagementBeta = "context-management-2025-06-27"
}

/// События хода, которые нужны UI и озвучке.
public enum AgentEvent: Sendable {
    case textDelta(String)
    case toolStarted(name: String, input: JSONValue)
    case toolFinished(name: String, output: ToolOutput)
    case serverToolStarted(name: String)
    case fallback(from: String?, to: String?)
}

/// Итог одного хода пользователя.
public enum TurnOutcome: Sendable, Equatable {
    /// Ответ получен. `text` — весь текст ассистента за ход.
    case completed(text: String)
    /// Запрос отклонён (классификатором или моделью). История откатывается.
    case refused(category: String?)
    /// Ответ обрезан по `max_tokens`.
    case truncated(text: String)
}

public enum ConversationError: Error, Sendable, LocalizedError {
    case tooManyToolIterations
    case tooManyContinuations

    public var errorDescription: String? {
        switch self {
        case .tooManyToolIterations: return "Слишком много вызовов инструментов подряд."
        case .tooManyContinuations: return "Сервер слишком долго выполнял поиск."
        }
    }
}

/// Диалог с Claude и агентный цикл: запрос → инструменты → результаты → ... → финальный ответ.
///
/// История только дописывается (append-only): блоки thinking на новых моделях привязаны
/// к диалогу, в котором созданы, поэтому прошлые сообщения не редактируются. Если ход
/// не удался (ошибка, отказ, отмена), история целиком откатывается к состоянию до хода.
public actor ClaudeConversation {
    public private(set) var messages: [JSONValue] = []
    private let client: ClaudeClient
    private let maxToolIterations: Int
    private let maxContinuations: Int
    /// API отклонил `context_management` (модель или аккаунт без беты) — дальше без него.
    private var contextEditingRejected = false

    public init(client: ClaudeClient = ClaudeClient(), maxToolIterations: Int = 8, maxContinuations: Int = 5) {
        self.client = client
        self.maxToolIterations = maxToolIterations
        self.maxContinuations = maxContinuations
    }

    /// Очищает историю. Ждёт завершения текущего хода, чтобы его откат не вернул старую историю.
    public func reset() async {
        await acquireTurn()
        messages.removeAll()
        releaseTurn()
    }

    public var isEmpty: Bool { messages.isEmpty }

    /// Выполняет ход пользователя. `userText` — распознанная речь.
    ///
    /// Ходы выполняются строго по очереди: actor допускает повторный вход на каждом `await`,
    /// и без очереди новый ход мог бы начаться поверх прерванного, а откат прерванного — стереть новый.
    public func send(
        userText: String,
        configuration: ClaudeConfiguration,
        tools: [any ClaudeTool],
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> TurnOutcome {
        await acquireTurn()
        defer { releaseTurn() }
        return try await performTurn(userText: userText, configuration: configuration, tools: tools, onEvent: onEvent)
    }

    // MARK: - Turn queue

    private var turnInProgress = false
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireTurn() async {
        guard turnInProgress else {
            turnInProgress = true
            return
        }
        // Право на ход передаётся напрямую из releaseTurn(): флаг остаётся true.
        await withCheckedContinuation { turnWaiters.append($0) }
    }

    private func releaseTurn() {
        if turnWaiters.isEmpty {
            turnInProgress = false
        } else {
            turnWaiters.removeFirst().resume()
        }
    }

    private func performTurn(
        userText: String,
        configuration: ClaudeConfiguration,
        tools: [any ClaudeTool],
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> TurnOutcome {
        let checkpoint = messages
        messages.append(["role": "user", "content": [["type": "text", "text": .string(userText)]]])

        var toolIterations = 0
        var continuations = 0
        var turnText = ""

        do {
            while true {
                try Task.checkCancellation()

                let contextEditing = configuration.contextEditing && !contextEditingRejected
                let body = Self.requestBody(
                    messages: messages, configuration: configuration, tools: tools, contextEditing: contextEditing
                )
                var betas: [String] = []
                if configuration.serverFallbacks { betas.append(ClaudeConfiguration.fallbackBeta) }
                if contextEditing { betas.append(ClaudeConfiguration.contextManagementBeta) }
                let response: AssembledMessage
                do {
                    response = try await client.streamMessage(body: body, apiKey: configuration.apiKey, betas: betas) { delta in
                        switch delta {
                        case .textDelta(let text):
                            await onEvent(.textDelta(text))
                        case .blockStarted(let type, let name) where type == "server_tool_use":
                            await onEvent(.serverToolStarted(name: name ?? "server_tool"))
                        case .fallback(let from, let to):
                            await onEvent(.fallback(from: from, to: to))
                        default:
                            break
                        }
                    }
                } catch let error as ClaudeAPIError where contextEditing && Self.rejectsContextManagement(error) {
                    // Ошибка пришла до начала стрима — повторяем тот же запрос без контекстного редактирования.
                    contextEditingRejected = true
                    continue
                }
                try Task.checkCancellation()

                let echo = FallbackEcho.sanitize(response.content)
                turnText += FallbackEcho.allText(response.content)

                switch response.stopReason {
                case "refusal":
                    // Частичный вывод отказавшего ответа отбрасываем вместе со всем ходом.
                    messages = checkpoint
                    return .refused(category: response.stopDetails?["category"]?.stringValue)

                case "pause_turn":
                    // Серверный инструмент (веб-поиск) не уложился в лимит итераций:
                    // возвращаем ответ как есть, без лишнего user-сообщения — сервер продолжит сам.
                    continuations += 1
                    guard continuations <= maxContinuations else { throw ConversationError.tooManyContinuations }
                    if !echo.isEmpty { messages.append(["role": "assistant", "content": .array(echo)]) }
                    continue

                case "tool_use":
                    toolIterations += 1
                    guard toolIterations <= maxToolIterations else { throw ConversationError.tooManyToolIterations }
                    messages.append(["role": "assistant", "content": .array(echo)])
                    let results = await runTools(
                        FallbackEcho.executableToolUses(response.content),
                        invalidInputs: response.invalidToolInputs,
                        tools: tools,
                        onEvent: onEvent
                    )
                    messages.append(["role": "user", "content": .array(results)])
                    continue

                case "max_tokens":
                    let hasToolUse = response.content.contains { $0.blockType == "tool_use" }
                    if hasToolUse || echo.isEmpty {
                        // Незавершённый tool_use без tool_result сломал бы следующий запрос.
                        messages = checkpoint
                    } else {
                        messages.append(["role": "assistant", "content": .array(echo)])
                    }
                    return .truncated(text: turnText)

                default: // end_turn, stop_sequence
                    if echo.isEmpty {
                        messages = checkpoint
                        return .completed(text: turnText)
                    }
                    messages.append(["role": "assistant", "content": .array(echo)])
                    return .completed(text: turnText)
                }
            }
        } catch {
            messages = checkpoint
            throw error
        }
    }

    // MARK: - Request

    static func requestBody(
        messages: [JSONValue],
        configuration: ClaudeConfiguration,
        tools: [any ClaudeTool],
        contextEditing: Bool = false
    ) -> JSONValue {
        var toolDefinitions = tools.map(\.definition)
        if configuration.webSearch {
            toolDefinitions.append(["type": "web_search_20260209", "name": "web_search", "max_uses": 3])
        }

        var body: [String: JSONValue] = [
            "model": .string(configuration.model),
            "max_tokens": .int(Int64(configuration.maxTokens)),
            "stream": true,
            "system": [["type": "text", "text": .string(configuration.systemPrompt)]],
            "messages": .array(messages),
            // Автоматическое кэширование: точка кэша ставится на последний кэшируемый блок.
            "cache_control": ["type": "ephemeral"],
        ]
        if !toolDefinitions.isEmpty {
            body["tools"] = .array(toolDefinitions)
        }
        if let effort = configuration.effort {
            body["output_config"] = ["effort": .string(effort)]
        }
        if configuration.serverFallbacks {
            body["fallbacks"] = "default"
        }
        if contextEditing {
            // Старые результаты инструментов (снимки, поиск) убираются, когда запрос перерастает
            // ~30 тыс. токенов; три последних остаются. Чистить меньше 5 тыс. невыгодно: очистка
            // сбрасывает кэш промпта.
            var edit: [String: JSONValue] = [
                "type": "clear_tool_uses_20250919",
                "trigger": ["type": "input_tokens", "value": 30_000],
                "keep": ["type": "tool_uses", "value": 3],
                "clear_at_least": ["type": "input_tokens", "value": 5_000],
            ]
            if !configuration.contextEditingExcludedTools.isEmpty {
                edit["exclude_tools"] = .array(configuration.contextEditingExcludedTools.map { .string($0) })
            }
            body["context_management"] = ["edits": [.object(edit)]]
        }
        return .object(body)
    }

    /// 400 из-за `context_management`: бета недоступна для модели или аккаунта.
    static func rejectsContextManagement(_ error: ClaudeAPIError) -> Bool {
        guard error.statusCode == 400 else { return false }
        let text = error.message.lowercased()
        return text.contains("context_management") || text.contains("context-management") || text.contains("clear_tool_uses")
    }

    // MARK: - Tools

    private func runTools(
        _ toolUses: [JSONValue],
        invalidInputs: [String: String],
        tools: [any ClaudeTool],
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async -> [JSONValue] {
        let toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        // Все вызовы выполняются параллельно, результаты возвращаются одним user-сообщением в исходном порядке.
        return await withTaskGroup(of: (Int, JSONValue).self) { group in
            for (position, block) in toolUses.enumerated() {
                group.addTask {
                    let id = block["id"]?.stringValue ?? ""
                    let name = block["name"]?.stringValue ?? ""
                    let input = block["input"]?.objectValue ?? [:]

                    if let raw = invalidInputs[id] {
                        let payload = (try? String(decoding: JSONValue.object(["INVALID_JSON": .string(raw)]).encoded(), as: UTF8.self)) ?? raw
                        return (position, Self.toolResult(id: id, output: .error(payload)))
                    }
                    guard let tool = toolsByName[name] else {
                        return (position, Self.toolResult(id: id, output: .error("Unknown tool '\(name)'")))
                    }
                    if let problem = SchemaValidator.validate(input, against: tool.inputSchema) {
                        return (position, Self.toolResult(id: id, output: .error(problem)))
                    }

                    await onEvent(.toolStarted(name: name, input: .object(input)))
                    let output: ToolOutput
                    do {
                        output = try await tool.run(input)
                    } catch {
                        output = .error(error.localizedDescription)
                    }
                    await onEvent(.toolFinished(name: name, output: output))
                    return (position, Self.toolResult(id: id, output: output))
                }
            }

            var results = [JSONValue?](repeating: nil, count: toolUses.count)
            for await (position, result) in group {
                results[position] = result
            }
            return results.compactMap { $0 }
        }
    }

    static func toolResult(id: String, output: ToolOutput) -> JSONValue {
        let content: [JSONValue] = output.content.map { item in
            switch item {
            case .text(let text):
                return ["type": "text", "text": .string(text.isEmpty ? "(empty)" : text)]
            case .jpeg(let data):
                return [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": .string(data.base64EncodedString()),
                    ],
                ]
            }
        }
        var result: [String: JSONValue] = [
            "type": "tool_result",
            "tool_use_id": .string(id),
            "content": .array(content.isEmpty ? [["type": "text", "text": "(empty)"]] : content),
        ]
        if output.isError {
            result["is_error"] = true
        }
        return .object(result)
    }
}

/// Правила возврата ответа в историю после серверного fallback.
///
/// Если модель отказала посреди вывода и запрос продолжила fallback-модель, в `content`
/// появляется блок `fallback`. До последнего такого блока нужно убрать thinking,
/// redacted_thinking, tool_use, непарные server_tool_use и прочие внутренние блоки,
/// оставив текст и парные серверные блоки; сам блок `fallback` остаётся на месте.
public enum FallbackEcho {
    public static func sanitize(_ content: [JSONValue]) -> [JSONValue] {
        guard let boundary = content.lastIndex(where: { $0.blockType == "fallback" }) else {
            return content
        }
        let resultIDs = Set(content.compactMap { block -> String? in
            guard let type = block.blockType, type.hasSuffix("_tool_result") else { return nil }
            return block["tool_use_id"]?.stringValue
        })

        var output: [JSONValue] = []
        for (index, block) in content.enumerated() {
            guard index < boundary else {
                output.append(block)
                continue
            }
            switch block.blockType {
            case "text", "fallback":
                output.append(block)
            case "server_tool_use":
                if let id = block["id"]?.stringValue, resultIDs.contains(id) { output.append(block) }
            case let type? where type.hasSuffix("_tool_result"):
                output.append(block)
            default:
                break // thinking, redacted_thinking, tool_use и неизвестные внутренние блоки
            }
        }
        return output
    }

    /// Вызовы инструментов, которые нужно выполнить: только после последней границы fallback.
    public static func executableToolUses(_ content: [JSONValue]) -> [JSONValue] {
        let start = (content.lastIndex(where: { $0.blockType == "fallback" }) ?? -1) + 1
        return content[start...].filter { $0.blockType == "tool_use" }
    }

    /// Текст ответа целиком (частичный текст до fallback продолжается fallback-моделью).
    public static func allText(_ content: [JSONValue]) -> String {
        content.compactMap { $0.blockType == "text" ? $0["text"]?.stringValue : nil }.joined()
    }
}
