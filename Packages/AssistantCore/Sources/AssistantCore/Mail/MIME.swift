import Foundation

// Разбор MIME (RFC 2045/2046) на уровне байтов: заголовки с развёрткой строк, multipart с границами,
// base64 / quoted-printable, перевод charset → String (koi8-r, windows-1251 и др. через CoreFoundation).

// MARK: - Заголовки

struct MIMEHeaderField: Sendable, Equatable {
    let name: String
    /// Значение после развёртки (unfolding), без декодирования RFC 2047.
    let value: String
}

struct MIMEHeaders: Sendable, Equatable {
    var fields: [MIMEHeaderField] = []

    /// Первое поле с таким именем (без учёта регистра).
    subscript(name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func parse<C: Collection>(_ bytes: C) -> MIMEHeaders where C.Element == UInt8 {
        let text = decodeBlock(Array(bytes))
        var fields: [MIMEHeaderField] = []
        var name: String?
        var value = ""

        func flush() {
            if let name {
                fields.append(MIMEHeaderField(name: name, value: value.trimmingCharacters(in: .whitespaces)))
            }
            name = nil
            value = ""
        }

        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let first = line.first, first == " " || first == "\t" {
                // Развёртка: убираем только перевод строки, пробельный символ остаётся.
                if name != nil { value += line }
            } else if let colon = line.firstIndex(of: ":") {
                flush()
                name = line[..<colon].trimmingCharacters(in: .whitespaces)
                value = String(line[line.index(after: colon)...])
            } else {
                flush() // мусорная строка (например, mbox «From ...») — пропускаем
            }
        }
        flush()
        return MIMEHeaders(fields: fields)
    }

    /// Заголовки должны быть ASCII; 8-битные без кодирования декодируем по charset из Content-Type,
    /// иначе как windows-1251 (самый частый случай для старой русской почты).
    private static func decodeBlock(_ bytes: [UInt8]) -> String {
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        let latin = String(decoding: bytes.map { $0 < 0x80 ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
        let charset = MIMEParameters.parse(latin.lowercased().components(separatedBy: "content-type:").dropFirst().first ?? "").1["charset"]
        return MIMECharset.decode(bytes, charset: charset ?? "windows-1251")
    }
}

// MARK: - Параметры заголовков

enum MIMEParameters {
    /// `text/plain; charset="utf-8"` → ("text/plain", ["charset": "utf-8"]). Имена параметров — в нижнем регистре.
    static func parse(_ raw: String) -> (String, [String: String]) {
        let segments = split(raw)
        let value = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, parameters[key] == nil else { continue }
            parameters[key] = unquote(rawValue)
        }
        return (value, parameters)
    }

    /// Делит по `;` вне кавычек.
    private static func split(_ raw: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in raw {
            if escaped {
                escaped = false
            } else if character == "\\" && inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == ";" && !inQuotes {
                segments.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        segments.append(current)
        return segments
    }

    static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\"") else {
            return value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        }
        var result = ""
        var escaped = false
        for character in value.dropFirst() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                result.append(character)
            }
        }
        return result
    }
}

// MARK: - Части письма

struct MIMEPart: Sendable {
    var headers: MIMEHeaders
    /// Тип в нижнем регистре, например `text/plain`.
    var mediaType: String
    var parameters: [String: String]
    /// Тело как в письме (до снятия Content-Transfer-Encoding).
    var body: [UInt8]
    var parts: [MIMEPart] = []

    var charset: String? { parameters["charset"] }

    var transferEncoding: String {
        headers["content-transfer-encoding"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "7bit"
    }

    var isAttachment: Bool {
        headers["content-disposition"]?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") ?? false
    }

    var decodedBody: [UInt8] {
        switch transferEncoding {
        case "base64": MIMETransferEncoding.decodeBase64(body)
        case "quoted-printable": MIMETransferEncoding.decodeQuotedPrintable(body)
        default: body // 7bit, 8bit, binary
        }
    }

    var decodedText: String {
        MIMECharset.decode(decodedBody, charset: charset)
    }
}

enum MIMEParser {
    static let maxDepth = 12

    /// Разбирает письмо или часть. Терпим к обрезанному концу (частичный FETCH).
    static func parse(_ bytes: [UInt8], depth: Int = 0) -> MIMEPart {
        let (headerEnd, bodyStart) = splitHeaderAndBody(bytes)
        let headers = MIMEHeaders.parse(bytes[0..<headerEnd])
        let (parsedType, parameters) = MIMEParameters.parse(headers["content-type"] ?? "")
        let mediaType = parsedType.contains("/") ? parsedType : "text/plain"
        var part = MIMEPart(
            headers: headers,
            mediaType: mediaType,
            parameters: parameters,
            body: bodyStart < bytes.count ? Array(bytes[bodyStart...]) : []
        )
        guard depth < maxDepth else { return part }

        if mediaType.hasPrefix("multipart/") {
            let boundary = parameters["boundary"].flatMap { $0.isEmpty ? nil : $0 } ?? inferBoundary(part.body)
            if let boundary {
                part.parts = splitMultipart(part.body, boundary: boundary).map { parse($0, depth: depth + 1) }
            }
        } else if mediaType == "message/rfc822" {
            part.parts = [parse(part.decodedBody, depth: depth + 1)]
        }
        return part
    }

    /// Граница между заголовками и телом: первая пустая строка.
    /// Если первая строка не похожа на заголовок — заголовков нет, всё тело.
    static func splitHeaderAndBody(_ bytes: [UInt8]) -> (headerEnd: Int, bodyStart: Int) {
        if bytes.first == 0x0A { return (0, 1) }
        if bytes.count >= 2, bytes[0] == 0x0D, bytes[1] == 0x0A { return (0, 2) }
        guard looksLikeHeaderLine(bytes) else { return (0, 0) }

        var index = 0
        while let lf = bytes[index...].firstIndex(of: 0x0A) {
            let next = lf + 1
            if next < bytes.count, bytes[next] == 0x0A { return (next, next + 1) }
            if next + 1 < bytes.count, bytes[next] == 0x0D, bytes[next + 1] == 0x0A { return (next, next + 2) }
            index = next
            if index >= bytes.count { break }
        }
        return (bytes.count, bytes.count) // только заголовки (например, обрезанная часть)
    }

    private static func looksLikeHeaderLine(_ bytes: [UInt8]) -> Bool {
        for byte in bytes.prefix(200) {
            if byte == UInt8(ascii: ":") { return true }
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { return false }
        }
        return false
    }

    /// Граница из первой строки вида `--boundary`, если в Content-Type её нет.
    static func inferBoundary(_ body: [UInt8]) -> String? {
        var index = 0
        while index < body.count, body[index] == 0x0D || body[index] == 0x0A { index += 1 }
        guard index + 2 < body.count, body[index] == UInt8(ascii: "-"), body[index + 1] == UInt8(ascii: "-") else {
            return nil
        }
        let lineEnd = body[index...].firstIndex(of: 0x0A) ?? body.count
        let line = String(decoding: body[(index + 2)..<lineEnd], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// Делит тело multipart по строкам `--boundary`; закрывающая `--boundary--` завершает разбор.
    /// Без закрывающей границы (обрезанное письмо) последняя часть идёт до конца данных.
    static func splitMultipart(_ body: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [[UInt8]] = []
        var partStart: Int?
        var lineStart = 0

        while lineStart < body.count {
            let lineEnd = body[lineStart...].firstIndex(of: 0x0A) ?? body.count
            if let kind = delimiterKind(body, at: lineStart, lineEnd: lineEnd, delimiter: delimiter) {
                if let start = partStart {
                    var end = lineStart
                    if end > start, body[end - 1] == 0x0A { end -= 1 }
                    if end > start, body[end - 1] == 0x0D { end -= 1 }
                    parts.append(Array(body[start..<max(start, end)]))
                }
                if kind == .close { return parts }
                partStart = min(lineEnd + 1, body.count)
            }
            lineStart = lineEnd + 1
        }
        if let start = partStart, start < body.count {
            parts.append(Array(body[start...]))
        }
        return parts
    }

    private enum DelimiterKind { case open, close }

    private static func delimiterKind(_ body: [UInt8], at start: Int, lineEnd: Int, delimiter: [UInt8]) -> DelimiterKind? {
        guard lineEnd - start >= delimiter.count else { return nil }
        for offset in 0..<delimiter.count where body[start + offset] != delimiter[offset] {
            return nil
        }
        let rest = body[(start + delimiter.count)..<lineEnd]
        if rest.starts(with: [UInt8(ascii: "-"), UInt8(ascii: "-")]) { return .close }
        // Иначе после границы допустимы только пробелы — защита от вложенных границ с общим префиксом.
        guard rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { return nil }
        return .open
    }
}

// MARK: - Content-Transfer-Encoding

enum MIMETransferEncoding {
    /// Терпимый base64: пропускает пробелы и мусор, понимает URL-алфавит, склейку блоков с `=` и обрезанный хвост.
    static func decodeBase64<C: Collection>(_ input: C) -> [UInt8] where C.Element == UInt8 {
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 3 / 4)
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in input {
            let value: UInt32
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = UInt32(byte - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(byte - UInt8(ascii: "a")) + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = UInt32(byte - UInt8(ascii: "0")) + 52
            case UInt8(ascii: "+"), UInt8(ascii: "-"): value = 62
            case UInt8(ascii: "/"), UInt8(ascii: "_"): value = 63
            case UInt8(ascii: "="):
                accumulator = 0 // конец блока; следующий блок начинается с чистого листа
                bits = 0
                continue
            default:
                continue
            }
            accumulator = (accumulator << 6) | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
                accumulator &= (1 << UInt32(bits)) - 1
            }
        }
        return output
    }

    /// Quoted-printable (RFC 2045, 6.7). `underscoreIsSpace` — для Q-кодирования RFC 2047.
    static func decodeQuotedPrintable<C: Collection>(_ input: C, underscoreIsSpace: Bool = false) -> [UInt8]
    where C.Element == UInt8 {
        let bytes = Array(input)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "=") {
                // Мягкий перенос: «=» + (пробелы) + CRLF/LF.
                var next = index + 1
                while next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x09 { next += 1 }
                if next < bytes.count, bytes[next] == 0x0A {
                    index = next + 1
                    continue
                }
                if next + 1 < bytes.count, bytes[next] == 0x0D, bytes[next + 1] == 0x0A {
                    index = next + 2
                    continue
                }
                if index + 2 < bytes.count, let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
                if index + 2 >= bytes.count { break } // обрезанная последовательность в конце
                output.append(byte) // одиночный «=» оставляем как есть
                index += 1
            } else if underscoreIsSpace && byte == UInt8(ascii: "_") {
                output.append(0x20)
                index += 1
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}

// MARK: - Кодировки

enum MIMECharset {
    /// Байты в строку по имени charset (IANA). Неизвестная кодировка или битые данные — UTF-8 с заменой.
    static func decode(_ bytes: [UInt8], charset: String?) -> String {
        guard !bytes.isEmpty else { return "" }
        let name = normalizedName(charset)

        if name == nil || name == "utf-8" || name == "us-ascii" {
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            let trimmed = trimIncompleteUTF8Tail(bytes) // обрезка частичного FETCH посреди символа
            if trimmed.count != bytes.count, let text = String(bytes: trimmed, encoding: .utf8) { return text }
            if name == "utf-8" { return String(decoding: bytes, as: UTF8.self) }
            // Кодировка не объявлена, а байты не UTF-8 — чаще всего это windows-1251.
            if let encoding = encoding(forIANAName: "windows-1251"), let text = String(bytes: bytes, encoding: encoding) {
                return text
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        if let name, let encoding = encoding(forIANAName: name), let text = String(bytes: bytes, encoding: encoding) {
            return text
        }
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func encoding(forIANAName name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// Имя в нижнем регистре с поправками на частые ошибки почтовиков.
    static func normalizedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var name = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            .lowercased()
        if let star = name.firstIndex(of: "*") { name = String(name[..<star]) } // RFC 2231: charset*lang
        guard !name.isEmpty else { return nil }
        switch name {
        case "utf8", "unicode-1-1-utf-8", "x-unicode20utf8": return "utf-8"
        case "ascii", "us-ascii", "ansi_x3.4-1968", "unknown-8bit", "x-unknown", "default": return "us-ascii"
        case "cp1251", "win-1251", "x-cp1251", "windows1251", "cp-1251": return "windows-1251"
        case "koi8r", "koi8": return "koi8-r"
        case "koi8u": return "koi8-u"
        case "iso-8859-1", "latin1", "iso8859-1": return "windows-1252" // надмножество, как в браузерах
        case "gb2312", "gbk": return "gb18030"
        default: return name
        }
    }

    /// Убирает незавершённую UTF-8 последовательность в конце.
    static func trimIncompleteUTF8Tail(_ bytes: [UInt8]) -> [UInt8] {
        var index = bytes.count - 1
        var continuation = 0
        while index >= 0, continuation < 3, bytes[index] & 0xC0 == 0x80 {
            continuation += 1
            index -= 1
        }
        guard index >= 0 else { return bytes }
        let lead = bytes[index]
        let needed = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return needed > continuation + 1 ? Array(bytes[..<index]) : bytes
    }
}
