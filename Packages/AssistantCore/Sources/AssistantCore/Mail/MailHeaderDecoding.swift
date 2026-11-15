import Foundation

// RFC 2047: =?charset?B|Q?текст?= в заголовках и форматирование адресов From/To.

enum MailEncodedWords {
    private enum Token {
        case text([UInt8])
        case word(charset: String, bytes: [UInt8])
    }

    /// Декодирует закодированные слова. Пробелы между соседними словами отбрасываются,
    /// байты соседних слов в одной кодировке склеиваются (символ UTF-8 может быть разрезан между словами).
    static func decode(_ value: String) -> String {
        let bytes = Array(value.utf8)
        guard bytes.count > 7, value.contains("=?") else { return value }

        var tokens: [Token] = []
        var textStart = 0
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "="), bytes[index + 1] == UInt8(ascii: "?"),
               let (token, end) = parseWord(bytes, at: index) {
                if textStart < index { tokens.append(.text(Array(bytes[textStart..<index]))) }
                tokens.append(token)
                index = end
                textStart = end
            } else {
                index += 1
            }
        }
        if textStart < bytes.count { tokens.append(.text(Array(bytes[textStart...]))) }

        var result = ""
        var pending: (charset: String, bytes: [UInt8])?
        func flush() {
            if let current = pending { result += MIMECharset.decode(current.bytes, charset: current.charset) }
            pending = nil
        }

        for (position, token) in tokens.enumerated() {
            switch token {
            case .text(let text):
                let isGap = text.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
                let nextIsWord: Bool = {
                    guard position + 1 < tokens.count, case .word = tokens[position + 1] else { return false }
                    return true
                }()
                if isGap && pending != nil && nextIsWord { continue }
                flush()
                result += String(decoding: text, as: UTF8.self)
            case .word(let charset, let decoded):
                if let current = pending, current.charset == charset {
                    pending = (charset, current.bytes + decoded)
                } else {
                    flush()
                    pending = (charset, decoded)
                }
            }
        }
        flush()
        return result
    }

    /// `=?charset?B?...?=` начиная с `start`; возвращает токен и индекс за `?=`.
    private static func parseWord(_ bytes: [UInt8], at start: Int) -> (Token, Int)? {
        let question = UInt8(ascii: "?")
        var index = start + 2
        let charsetStart = index
        while index < bytes.count, bytes[index] != question {
            let byte = bytes[index]
            guard byte > 0x20, byte < 0x7F, index - charsetStart < 64 else { return nil }
            index += 1
        }
        guard index > charsetStart, index + 2 < bytes.count, bytes[index + 2] == question else { return nil }
        var charset = String(decoding: bytes[charsetStart..<index], as: UTF8.self)
        if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) } // RFC 2231: язык
        let encoding = bytes[index + 1] | 0x20 // в нижний регистр
        guard encoding == UInt8(ascii: "b") || encoding == UInt8(ascii: "q") else { return nil }

        let textStart = index + 3
        var end = textStart
        while end + 1 < bytes.count, !(bytes[end] == question && bytes[end + 1] == UInt8(ascii: "=")) {
            let byte = bytes[end]
            guard byte > 0x20, byte < 0x7F else { return nil } // пробелов внутри слова быть не может
            end += 1
        }
        guard end + 1 < bytes.count else { return nil }
        let encoded = bytes[textStart..<end]
        let decoded = encoding == UInt8(ascii: "b")
            ? MIMETransferEncoding.decodeBase64(encoded)
            : MIMETransferEncoding.decodeQuotedPrintable(encoded, underscoreIsSpace: true)
        return (.word(charset: charset.lowercased(), bytes: decoded), end + 2)
    }
}

enum MailAddressFormatter {
    /// Список адресов из заголовка → «Имя <адрес>, адрес2». Кавычки вокруг имени снимаются.
    static func format(_ raw: String?) -> String {
        guard let raw else { return "" }
        return splitAddresses(raw)
            .map(formatSingle)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func formatSingle(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = value.lastIndex(of: "<"),
              let close = value[open...].firstIndex(of: ">") else {
            return collapseSpaces(MailEncodedWords.decode(value))
        }
        let address = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        var name = collapseSpaces(MailEncodedWords.decode(String(value[..<open])))
        if name.hasPrefix("\"") {
            name = MIMEParameters.unquote(name)
        }
        name = name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        if name.isEmpty || name.caseInsensitiveCompare(address) == .orderedSame { return address }
        if address.isEmpty { return name }
        return "\(name) <\(address)>"
    }

    /// Делит по запятым вне кавычек, угловых скобок и комментариев.
    static func splitAddresses(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var angle = 0
        var comment = 0
        for character in raw {
            if escaped {
                escaped = false
            } else if character == "\\" && inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes {
                switch character {
                case "<": angle += 1
                case ">": angle = max(0, angle - 1)
                case "(": comment += 1
                case ")": comment = max(0, comment - 1)
                case "," where angle == 0 && comment == 0:
                    result.append(current)
                    current = ""
                    continue
                default: break
                }
            }
            current.append(character)
        }
        result.append(current)
        return result
    }

    static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
