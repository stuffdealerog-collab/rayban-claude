import Foundation

/// Содержимое результата инструмента.
public enum ToolContent: Sendable, Equatable {
    case text(String)
    /// JPEG-изображение (например, снимок с камеры очков).
    case jpeg(Data)
}

/// Результат выполнения инструмента, который уйдёт в Claude как `tool_result`.
public struct ToolOutput: Sendable, Equatable {
    public var content: [ToolContent]
    public var isError: Bool

    public init(content: [ToolContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> ToolOutput { ToolOutput(content: [.text(text)]) }
    public static func error(_ text: String) -> ToolOutput { ToolOutput(content: [.text(text)], isError: true) }
}

/// Клиентский инструмент, который Claude может вызвать (камера, геолокация, напоминания ...).
public protocol ClaudeTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema объекта входных параметров.
    var inputSchema: JSONValue { get }
    func run(_ input: [String: JSONValue]) async throws -> ToolOutput
}

extension ClaudeTool {
    /// Определение инструмента для поля `tools` запроса.
    /// `eager_input_streaming` включён для стриминговых запросов: API перестаёт буферизовать
    /// и валидировать параметры, поэтому вход проверяется на клиенте (`SchemaValidator`).
    public var definition: JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "input_schema": inputSchema,
            "eager_input_streaming": true,
        ]
    }
}

/// Упрощённая проверка входа по JSON Schema: объект, обязательные поля, типы и enum свойств
/// верхнего уровня. Этого достаточно для плоских схем инструментов этого приложения.
public enum SchemaValidator {
    public static func validate(_ input: [String: JSONValue], against schema: JSONValue) -> String? {
        let properties = schema["properties"]?.objectValue ?? [:]
        for case .string(let key) in schema["required"]?.arrayValue ?? [] where input[key] == nil {
            return "Missing required parameter '\(key)'"
        }
        for (key, value) in input {
            guard let property = properties[key] else {
                if schema["additionalProperties"] == .bool(false) {
                    return "Unknown parameter '\(key)'"
                }
                continue
            }
            if let expected = property["type"]?.stringValue, !matches(value, type: expected) {
                return "Parameter '\(key)' must be of type \(expected)"
            }
            if let allowed = property["enum"]?.arrayValue, !allowed.contains(value) {
                return "Parameter '\(key)' must be one of \(allowed.compactMap(\.stringValue))"
            }
        }
        return nil
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("array", .array), ("object", .object), ("null", .null):
            return true
        case ("integer", .int):
            return true
        case ("integer", .double(let double)):
            return double.rounded() == double
        case ("number", .int), ("number", .double):
            return true
        default:
            return false
        }
    }
}
