import Foundation

/// Режет поток текста на фразы, чтобы озвучивать ответ, не дожидаясь его конца.
public struct SentenceChunker: Sendable {
    private var buffer = ""
    private let terminators: Set<Character> = [".", "!", "?", "…", ";"]

    public init() {}

    /// Добавляет фрагмент и возвращает завершённые фразы (могут быть пустым массивом).
    public mutating func append(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        var start = buffer.startIndex
        var index = buffer.startIndex

        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)
            let isBoundary: Bool
            if character == "\n" {
                isBoundary = true
            } else if terminators.contains(character) {
                // Граница — только если дальше пробел/перевод строки: так «3.5» и «т.е» не режутся.
                isBoundary = next < buffer.endIndex && buffer[next].isWhitespace
            } else {
                isBoundary = false
            }

            if isBoundary {
                let sentence = buffer[start..<next].trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                start = next
            }
            index = next
        }

        buffer = String(buffer[start...])
        return sentences
    }

    /// Остаток после конца ответа.
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }
}

/// Подготовка текста к синтезу речи: убирает Markdown-разметку и ссылки.
public enum SpeechText {
    public static func clean(_ text: String) -> String {
        var result = text
        // [текст](url) -> текст
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // голые URL
        result = result.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        // маркеры списков и заголовков в начале строки
        result = result.replacingOccurrences(of: #"(?m)^\s*(#{1,6}|[-*•]|\d+\.)\s+"#, with: "", options: .regularExpression)
        // выделение и код
        for symbol in ["**", "__", "`", "*", "_", "#"] {
            result = result.replacingOccurrences(of: symbol, with: "")
        }
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
