import Foundation

// Чистый разбор протокола IMAP4rev1 (RFC 3501) без сети: нарезка потока на ответы,
// токенизатор (атомы, строки в кавычках, литералы {n}, NIL, списки), FETCH, кодирование аргументов.

/// Значение в ответе сервера.
enum IMAPValue: Sendable, Equatable {
    /// Атом, число или флаг. Ключи вида `BODY[HEADER.FIELDS (FROM)]<0>` — тоже один атом.
    case atom(String)
    /// Строка в кавычках или литерал — сырые байты (кодировка не известна).
    case string([UInt8])
    /// NIL.
    case null
    case list([IMAPValue])

    var bytes: [UInt8]? {
        switch self {
        case .string(let bytes): bytes
        case .atom(let atom): Array(atom.utf8)
        case .null, .list: nil
        }
    }

    var text: String? {
        bytes.map { String(decoding: $0, as: UTF8.self) }
    }

    var listItems: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var number: UInt32? {
        if case .atom(let atom) = self { return UInt32(atom) }
        return nil
    }
}

enum IMAPStatus: String, Sendable {
    case ok = "OK", no = "NO", bad = "BAD", preauth = "PREAUTH", bye = "BYE"
}

/// Один ответ сервера (строка вместе со всеми литералами).
enum IMAPResponse: Sendable, Equatable {
    /// Статус; `tag == nil` для нетегированного `* OK/NO/BAD/BYE/PREAUTH`.
    case status(tag: String?, status: IMAPStatus, code: String?, text: String)
    /// Нетегированные данные: `* 5 FETCH (...)`, `* SEARCH 1 2`, `* 3 EXISTS`.
    case data(number: UInt32?, name: String, values: [IMAPValue])
    /// `+ ...` — сервер ждёт продолжения команды (литерала).
    case continuation(String)
}

struct IMAPParseError: Error, Equatable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

private enum ASCII {
    static let cr: UInt8 = 0x0D
    static let lf: UInt8 = 0x0A
    static let space: UInt8 = 0x20
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let plus = UInt8(ascii: "+")
    static let tilde = UInt8(ascii: "~")
    static let star = UInt8(ascii: "*")
}

// MARK: - Нарезка потока

/// Накопитель байтов из сокета: отдаёт целые ответы, учитывая литералы `{n}\r\n`,
/// которые могут содержать переводы строк и приходить по частям.
struct IMAPFramer: Sendable {
    /// Защита от абсурдных литералов (письма мы и так берём частями до 512 КБ).
    static let maxLiteralSize = 64 * 1024 * 1024

    private var buffer: [UInt8] = []
    /// Начало текущего сегмента строки (после последнего литерала) — отсюда ищем LF.
    private var segmentStart = 0

    var bufferedByteCount: Int { buffer.count }

    mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    /// Очередной полный ответ (с завершающим CRLF) или `nil`, если данных пока мало.
    mutating func nextResponse() throws -> [UInt8]? {
        var start = segmentStart
        while start < buffer.count {
            guard let lf = buffer[start...].firstIndex(of: ASCII.lf) else { break }
            var lineEnd = lf
            if lineEnd > start, buffer[lineEnd - 1] == ASCII.cr { lineEnd -= 1 }
            if let length = try Self.literalLength(in: buffer, end: lineEnd, lowerBound: start) {
                let literalEnd = lf + 1 + length
                if literalEnd > buffer.count {
                    segmentStart = literalEnd // ждём остаток литерала, не пересканируя его
                    return nil
                }
                start = literalEnd
                continue
            }
            let response = Array(buffer[...lf])
            buffer.removeSubrange(...lf)
            segmentStart = 0
            return response
        }
        segmentStart = start
        return nil
    }

    /// Длина литерала, если строка `bytes[lowerBound..<end]` заканчивается на `{n}` (или `{n+}`).
    static func literalLength(in bytes: [UInt8], end: Int, lowerBound: Int) throws -> Int? {
        var index = end - 1
        guard index >= lowerBound, bytes[index] == ASCII.closeBrace else { return nil }
        index -= 1
        if index >= lowerBound, bytes[index] == ASCII.plus { index -= 1 }
        var value = 0
        var multiplier = 1
        var digits = 0
        while index >= lowerBound, (0x30...0x39).contains(bytes[index]) {
            digits += 1
            guard digits <= 10 else { throw IMAPParseError("слишком длинный литерал") }
            value += Int(bytes[index] - 0x30) * multiplier
            multiplier *= 10
            index -= 1
        }
        guard digits > 0, index >= lowerBound, bytes[index] == ASCII.openBrace else { return nil }
        guard value <= maxLiteralSize else { throw IMAPParseError("слишком большой литерал: \(value) байт") }
        return value
    }
}

// MARK: - Разбор ответа

enum IMAPResponseParser {
    static func parse(_ raw: [UInt8]) throws -> IMAPResponse {
        var cursor = IMAPCursor(raw)
        guard !cursor.isAtEnd else { throw IMAPParseError("пустой ответ") }

        if cursor.peek == ASCII.plus {
            cursor.index += 1
            cursor.skipSpaces()
            return .continuation(cursor.restAsText())
        }

        let tag = cursor.readWord()
        guard !tag.isEmpty else { throw IMAPParseError("нет тега") }
        cursor.skipSpaces()

        if tag == "*" {
            let word = cursor.readWord()
            cursor.skipSpaces()
            if let number = UInt32(word) {
                let name = cursor.readWord().uppercased()
                return .data(number: number, name: name, values: try cursor.readValues())
            }
            let name = word.uppercased()
            if let status = IMAPStatus(rawValue: name) {
                let (code, text) = cursor.readResponseText()
                return .status(tag: nil, status: status, code: code, text: text)
            }
            return .data(number: nil, name: name, values: try cursor.readValues())
        }

        guard let status = IMAPStatus(rawValue: cursor.readWord().uppercased()) else {
            throw IMAPParseError("неизвестный статус в ответе \(tag)")
        }
        let (code, text) = cursor.readResponseText()
        return .status(tag: tag, status: status, code: code, text: text)
    }
}

/// Курсор по байтам одного ответа.
struct IMAPCursor {
    let bytes: [UInt8]
    var index = 0
    let end: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        var end = bytes.count
        if end > 0, bytes[end - 1] == ASCII.lf { end -= 1 }
        if end > 0, bytes[end - 1] == ASCII.cr { end -= 1 }
        self.end = end
    }

    var isAtEnd: Bool { index >= end }
    var peek: UInt8? { isAtEnd ? nil : bytes[index] }

    mutating func skipSpaces() {
        while index < end, bytes[index] == ASCII.space { index += 1 }
    }

    /// Слово до пробела.
    mutating func readWord() -> String {
        let start = index
        while index < end, bytes[index] != ASCII.space { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func restAsText() -> String {
        let text = String(decoding: bytes[min(index, end)..<end], as: UTF8.self)
        index = end
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// resp-text: необязательный `[CODE ...]` и произвольный текст до конца строки.
    mutating func readResponseText() -> (code: String?, text: String) {
        skipSpaces()
        var code: String?
        if peek == ASCII.openBracket {
            let start = index + 1
            var close = start
            while close < end, bytes[close] != ASCII.closeBracket { close += 1 }
            code = String(decoding: bytes[start..<close], as: UTF8.self)
            index = min(close + 1, end)
        }
        return (code, restAsText())
    }

    mutating func readValues() throws -> [IMAPValue] {
        var values: [IMAPValue] = []
        while true {
            skipSpaces()
            if isAtEnd { return values }
            values.append(try readValue())
        }
    }

    mutating func readValue() throws -> IMAPValue {
        guard let byte = peek else { throw IMAPParseError("неожиданный конец ответа") }
        switch byte {
        case ASCII.openParen:
            index += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard let next = peek else { throw IMAPParseError("незакрытый список") }
                if next == ASCII.closeParen {
                    index += 1
                    return .list(items)
                }
                items.append(try readValue())
            }
        case ASCII.closeParen:
            throw IMAPParseError("лишняя закрывающая скобка")
        case ASCII.quote:
            return .string(try readQuoted())
        case ASCII.openBrace:
            return .string(try readLiteral())
        case ASCII.tilde where index + 1 < end && bytes[index + 1] == ASCII.openBrace:
            index += 1 // literal8
            return .string(try readLiteral())
        default:
            let atom = try readAtom()
            return atom.uppercased() == "NIL" ? .null : .atom(atom)
        }
    }

    /// Строка в кавычках с экранированием `\"` и `\\`.
    mutating func readQuoted() throws -> [UInt8] {
        index += 1
        var result: [UInt8] = []
        while index < end {
            let byte = bytes[index]
            if byte == ASCII.backslash, index + 1 < end {
                result.append(bytes[index + 1])
                index += 2
            } else if byte == ASCII.quote {
                index += 1
                return result
            } else {
                result.append(byte)
                index += 1
            }
        }
        throw IMAPParseError("незакрытая строка в кавычках")
    }

    /// Литерал `{n}\r\n` + n байт.
    mutating func readLiteral() throws -> [UInt8] {
        index += 1
        var length = 0
        var digits = 0
        while index < end, (0x30...0x39).contains(bytes[index]) {
            length = length * 10 + Int(bytes[index] - 0x30)
            digits += 1
            index += 1
            guard digits <= 10 else { throw IMAPParseError("слишком длинный литерал") }
        }
        if index < end, bytes[index] == ASCII.plus { index += 1 }
        guard digits > 0, index < end, bytes[index] == ASCII.closeBrace else {
            throw IMAPParseError("неверный литерал")
        }
        index += 1
        if index < bytes.count, bytes[index] == ASCII.cr { index += 1 }
        guard index < bytes.count, bytes[index] == ASCII.lf else { throw IMAPParseError("нет CRLF после литерала") }
        index += 1
        guard length <= bytes.count - index else { throw IMAPParseError("литерал обрезан") }
        let literal = Array(bytes[index..<(index + length)])
        index += length
        return literal
    }

    /// Атом; секции в квадратных скобках (`BODY[HEADER.FIELDS (FROM DATE)]<0>`) входят в него целиком.
    mutating func readAtom() throws -> String {
        let start = index
        scan: while index < end {
            switch bytes[index] {
            case ASCII.openBracket:
                skipBracketed()
            case ASCII.space, ASCII.openParen, ASCII.closeParen, ASCII.quote, ASCII.openBrace, ASCII.cr, ASCII.lf:
                break scan
            default:
                index += 1
            }
        }
        guard index > start else { throw IMAPParseError("неожиданный символ в ответе") }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func skipBracketed() {
        var depth = 0
        var inQuotes = false
        while index < end {
            let byte = bytes[index]
            index += 1
            if inQuotes {
                if byte == ASCII.backslash { index += 1 } else if byte == ASCII.quote { inQuotes = false }
            } else if byte == ASCII.quote {
                inQuotes = true
            } else if byte == ASCII.openBracket {
                depth += 1
            } else if byte == ASCII.closeBracket {
                depth -= 1
                if depth == 0 { return }
            }
        }
    }
}

// MARK: - FETCH

/// Атрибуты одного письма из ответов `* n FETCH (...)` (могут прийти несколькими ответами).
struct IMAPFetchItem: Sendable, Equatable {
    var sequence: UInt32
    /// Ключи в верхнем регистре: `UID`, `FLAGS`, `BODY[TEXT]<0>`…
    var attributes: [String: IMAPValue]

    var uid: UInt32? { attributes["UID"]?.number }

    var flags: [String] {
        attributes["FLAGS"]?.listItems?.compactMap(\.text) ?? []
    }

    var isSeen: Bool {
        flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }
    }

    var internalDate: Date? {
        attributes["INTERNALDATE"]?.text.flatMap(MailDate.parseInternalDate)
    }

    /// Содержимое секции `BODY[<spec>]`: "" — всё письмо, "TEXT", "HEADER.FIELDS".
    /// NIL от сервера даёт пустой массив; отсутствие секции — `nil`.
    func section(_ spec: String) -> [UInt8]? {
        for (key, value) in attributes where key.hasPrefix("BODY[") {
            guard let close = key.lastIndex(of: "]") else { continue }
            let inner = key[key.index(key.startIndex, offsetBy: 5)..<close]
            let matches = spec.isEmpty ? inner.isEmpty : (inner == spec || inner.hasPrefix(spec + " "))
            if matches { return value.bytes ?? [] }
        }
        return nil
    }

    /// Собирает FETCH-ответы, объединяя части одного письма по номеру.
    static func collect(from responses: [IMAPResponse]) -> [IMAPFetchItem] {
        var order: [UInt32] = []
        var bySequence: [UInt32: [String: IMAPValue]] = [:]
        for response in responses {
            guard case .data(let number?, let name, let values) = response, name == "FETCH",
                  let items = values.first?.listItems else { continue }
            var attributes = bySequence[number] ?? [:]
            if bySequence[number] == nil { order.append(number) }
            var index = 0
            while index + 1 < items.count {
                if let key = items[index].text {
                    attributes[key.uppercased()] = items[index + 1]
                }
                index += 2
            }
            bySequence[number] = attributes
        }
        return order.map { IMAPFetchItem(sequence: $0, attributes: bySequence[$0] ?? [:]) }
    }
}

// MARK: - Команды

/// Часть команды: обычный текст или литерал (отправляется после `+` от сервера).
enum IMAPCommandPart: Sendable, Equatable {
    case text(String)
    case literal([UInt8])
}

enum IMAPCommandEncoder {
    /// astring: строка в кавычках, если это 7-битный текст без CR/LF, иначе литерал.
    static func astring(_ value: String) -> IMAPCommandPart {
        let bytes = Array(value.utf8)
        let quotable = bytes.allSatisfy { $0 >= 0x01 && $0 <= 0x7F && $0 != ASCII.cr && $0 != ASCII.lf }
        guard quotable else { return .literal(bytes) }
        var quoted = "\""
        for scalar in value.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { quoted.unicodeScalars.append("\\") }
            quoted.unicodeScalars.append(scalar)
        }
        quoted += "\""
        return .text(quoted)
    }

    /// Имя папки в modified UTF-7 (RFC 3501, 5.1.3): «Входящие» → `&BBIERQQ+BDQETwRJBDgENQ-`.
    static func mailboxName(_ name: String) -> String {
        var result = ""
        var pending: [UInt16] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            for unit in pending {
                bytes.append(UInt8(unit >> 8))
                bytes.append(UInt8(unit & 0xFF))
            }
            let base64 = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "/", with: ",")
                .replacingOccurrences(of: "=", with: "")
            result += "&" + base64 + "-"
            pending.removeAll()
        }

        for scalar in name.unicodeScalars {
            if (0x20...0x7E).contains(scalar.value) {
                flush()
                result += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: String(scalar).utf16)
            }
        }
        flush()
        return result
    }

    /// Набор UID через запятую со сжатием подряд идущих: `3,5:7,10`.
    static func sequenceSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var ranges: [String] = []
        var index = 0
        while index < sorted.count {
            let first = sorted[index]
            var last = first
            while index + 1 < sorted.count, sorted[index + 1] == last + 1 {
                index += 1
                last = sorted[index]
            }
            ranges.append(first == last ? "\(first)" : "\(first):\(last)")
            index += 1
        }
        return ranges.joined(separator: ",")
    }
}
