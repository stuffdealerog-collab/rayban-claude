import Foundation

// Текст письма для озвучивания: выбор части, HTML → текст, нормализация пробелов, сниппет, обрезка,
// а также сборка MailSummary / MailMessage из ответов FETCH.

enum MailText {
    /// Лучший текст: первая text/plain (не вложение), иначе text/html без разметки.
    static func bestText(in root: MIMEPart) -> String {
        var plain: MIMEPart?
        var html: MIMEPart?
        collectTextParts(root, plain: &plain, html: &html)
        if let plain {
            let text = normalize(plain.decodedText)
            if !text.isEmpty || html == nil { return text }
        }
        if let html { return htmlToText(html.decodedText) }
        return ""
    }

    private static func collectTextParts(_ part: MIMEPart, plain: inout MIMEPart?, html: inout MIMEPart?) {
        if !part.parts.isEmpty {
            for child in part.parts { collectTextParts(child, plain: &plain, html: &html) }
            return
        }
        guard !part.isAttachment else { return }
        switch part.mediaType {
        case "text/plain": if plain == nil { plain = part }
        case "text/html": if html == nil { html = part }
        default: break
        }
    }

    /// Сниппет: текст одной строкой, не длиннее `limit` символов.
    static func snippet(_ text: String, limit: Int = 200) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return truncate(line, maxLength: limit)
    }

    /// Обрезка по границе слова с «…» (длина результата ≤ maxLength).
    static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        guard text.count > maxLength else { return text }
        guard maxLength > 1 else { return "…" }
        var cut = String(text.prefix(maxLength - 1))
        if let space = cut.lastIndex(where: \.isWhitespace),
           cut.distance(from: cut.startIndex, to: space) >= (maxLength * 2) / 3 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Пробелы: CRLF → LF, невидимые символы убраны, пробелы в строке схлопнуты, не больше одной пустой строки подряд.
    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if previousWasCR && scalar == "\n" {
                previousWasCR = false
                continue
            }
            previousWasCR = scalar == "\r"
            if scalar == "\r" {
                scalars.append("\n")
            } else if invisibleScalars.contains(scalar.value) {
                continue
            } else if scalar == "\n" {
                scalars.append(scalar)
            } else if scalar.properties.isWhitespace {
                scalars.append(" ") // NBSP, табуляции и прочие пробелы
            } else {
                scalars.append(scalar)
            }
        }

        var lines: [String] = []
        var blankRun = 0
        for rawLine in String(scalars).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 || lines.isEmpty { continue }
            } else {
                blankRun = 0
            }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Нулевой ширины, мягкий перенос, «пустышки» из прехедеров рассылок.
    private static let invisibleScalars: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD, 0x034F, 0x180E]

    // MARK: HTML → текст

    /// Убирает разметку: style/script/head выбрасываются, <br>, </p> и блочные теги → перевод строки,
    /// сущности декодируются, пробелы схлопываются.
    static func htmlToText(_ html: String) -> String {
        let source = Array(html.unicodeScalars)
        let count = source.count
        var output = String.UnicodeScalarView()
        var index = 0

        while index < count {
            let scalar = source[index]
            if scalar == "<", index + 1 < count, isTagStart(source[index + 1]) {
                if matches(source, at: index, "<!--") {
                    index = find(source, "-->", from: index + 4).map { $0 + 3 } ?? count
                    continue
                }
                guard let close = tagEnd(source, from: index + 1) else { break } // обрезанный тег в конце
                var nameIndex = index + 1
                let isClosing = source[nameIndex] == "/"
                if isClosing { nameIndex += 1 }
                var name = ""
                while nameIndex < close, source[nameIndex].properties.isAlphabetic || ("0"..."9").contains(source[nameIndex]) {
                    name.unicodeScalars.append(contentsOf: source[nameIndex].properties.lowercaseMapping.unicodeScalars)
                    nameIndex += 1
                }
                index = close + 1

                if !isClosing, skippedElements.contains(name) {
                    if let endTag = find(source, "</" + name, from: index, caseInsensitive: true) {
                        index = tagEnd(source, from: endTag + 1).map { $0 + 1 } ?? count
                    } else {
                        index = count
                    }
                    continue
                }
                if name == "br" || name == "hr" || blockElements.contains(name) {
                    output.append("\n")
                } else if name == "td" || name == "th" {
                    output.append(" ")
                }
                continue
            }
            if scalar == "&", let (decoded, length) = decodeEntity(source, at: index) {
                output.append(contentsOf: decoded.unicodeScalars)
                index += length
                continue
            }
            // Переводы строк в исходнике HTML — просто пробелы.
            output.append(scalar == "\n" || scalar == "\r" || scalar == "\t" ? " " : scalar)
            index += 1
        }
        return normalize(String(output))
    }

    private static let skippedElements: Set<String> = ["style", "script", "head", "title", "noscript", "template"]

    private static let blockElements: Set<String> = [
        "p", "div", "tr", "li", "ul", "ol", "table", "blockquote", "pre", "section", "article", "header",
        "footer", "h1", "h2", "h3", "h4", "h5", "h6", "dt", "dd", "address", "center", "form", "tbody",
    ]

    private static func isTagStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "/" || scalar == "!" || scalar == "?" || (scalar.isASCII && scalar.properties.isAlphabetic)
    }

    /// Индекс `>`, закрывающего тег; значения атрибутов в кавычках пропускаются.
    private static func tagEnd(_ source: [Unicode.Scalar], from start: Int) -> Int? {
        var index = start
        var quote: Unicode.Scalar?
        var afterEquals = false
        while index < source.count {
            let scalar = source[index]
            if let open = quote {
                if scalar == open { quote = nil }
            } else if scalar == ">" {
                return index
            } else if afterEquals && (scalar == "\"" || scalar == "'") {
                quote = scalar
            }
            if scalar == "=" {
                afterEquals = true
            } else if scalar != " " && scalar != "\t" && scalar != "\n" && scalar != "\r" {
                afterEquals = false
            }
            index += 1
        }
        return nil
    }

    private static func matches(_ source: [Unicode.Scalar], at index: Int, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
        var position = index
        for expected in pattern.unicodeScalars {
            guard position < source.count else { return false }
            var actual = source[position]
            if caseInsensitive, actual.isASCII, ("A"..."Z").contains(actual) {
                actual = Unicode.Scalar(actual.value + 32) ?? actual
            }
            guard actual == expected else { return false }
            position += 1
        }
        return true
    }

    private static func find(_ source: [Unicode.Scalar], _ pattern: String, from start: Int, caseInsensitive: Bool = false) -> Int? {
        guard let first = pattern.unicodeScalars.first else { return nil }
        var index = start
        while index < source.count {
            var scalar = source[index]
            if caseInsensitive, ("A"..."Z").contains(scalar) { scalar = Unicode.Scalar(scalar.value + 32) ?? scalar }
            if scalar == first, matches(source, at: index, pattern, caseInsensitive: caseInsensitive) { return index }
            index += 1
        }
        return nil
    }

    /// `&amp;`, `&#1055;`, `&#x41F;` → символ и длина сущности.
    private static func decodeEntity(_ source: [Unicode.Scalar], at start: Int) -> (String, Int)? {
        var index = start + 1
        var name = ""
        while index < source.count, index - start <= 32 {
            let scalar = source[index]
            if scalar == ";" {
                break
            }
            guard scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "#" else {
                return nil
            }
            name.unicodeScalars.append(scalar)
            index += 1
        }
        guard index < source.count, source[index] == ";", !name.isEmpty else { return nil }
        let length = index - start + 1

        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return (String(scalar), length)
        }
        guard let decoded = namedEntities[name] ?? namedEntities[name.lowercased()] else { return nil }
        return (decoded, length)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "laquo": "«", "raquo": "»", "mdash": "—", "ndash": "–", "hellip": "…", "minus": "−",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£",
        "yen": "¥", "cent": "¢", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "sect": "§",
        "para": "¶", "shy": "\u{00AD}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "thinsp": "\u{2009}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "num": "#", "excl": "!",
    ]
}

// MARK: - Сборка моделей

enum MailAssembler {
    /// Заголовки, которые берём для списка писем (Content-* нужны для разбора начала тела).
    static let summaryHeaderFields = "FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING"

    /// Сводка из FETCH (UID FLAGS INTERNALDATE BODY[HEADER.FIELDS (...)] BODY[TEXT]<0>).
    /// Непрошенные FETCH без заголовков (например, смена флагов) пропускаются.
    static func summary(from item: IMAPFetchItem) -> MailSummary? {
        guard let uid = item.uid, let headerBytes = item.section("HEADER.FIELDS") else { return nil }
        let headers = MIMEHeaders.parse(headerBytes)
        let date = headers["date"].flatMap(MailDate.parseRFC5322) ?? item.internalDate
        return MailSummary(
            uid: uid,
            from: MailAddressFormatter.format(headers["from"]),
            subject: decodeSubject(headers["subject"]),
            date: date,
            isUnread: !item.isSeen,
            snippet: snippet(headerBytes: headerBytes, bodyPrefix: item.section("TEXT") ?? [])
        )
    }

    /// Сниппет из начала тела (BODY[TEXT]<0.N>). Для multipart это сырой MIME — собираем
    /// временное письмо из заголовков Content-* и куска тела и разбираем как обычно.
    static func snippet(headerBytes: [UInt8], bodyPrefix: [UInt8], limit: Int = 200) -> String {
        var headers = headerBytes
        while let last = headers.last, last == 0x0D || last == 0x0A { headers.removeLast() }
        var raw = headers
        if !raw.isEmpty { raw += [0x0D, 0x0A] }
        raw += [0x0D, 0x0A]
        raw += bodyPrefix
        var root = MIMEParser.parse(raw)
        if root.headers["content-type"] == nil, let boundary = MIMEParser.inferBoundary(root.body) {
            // Content-Type нет, но тело начинается с границы — это multipart, берём первую текстовую часть.
            root.mediaType = "multipart/mixed"
            root.parts = MIMEParser.splitMultipart(root.body, boundary: boundary).map { MIMEParser.parse($0, depth: 1) }
        }
        return MailText.snippet(MailText.bestText(in: root), limit: limit)
    }

    /// Полное письмо из BODY[] (возможно обрезанного до 512 КБ).
    static func message(uid: UInt32, raw: [UInt8], internalDate: Date?, maxLength: Int) -> MailMessage {
        let root = MIMEParser.parse(raw)
        let headers = root.headers
        return MailMessage(
            uid: uid,
            from: MailAddressFormatter.format(headers["from"]),
            to: MailAddressFormatter.format(headers["to"]),
            subject: decodeSubject(headers["subject"]),
            date: headers["date"].flatMap(MailDate.parseRFC5322) ?? internalDate,
            text: MailText.truncate(MailText.bestText(in: root), maxLength: maxLength)
        )
    }

    static func decodeSubject(_ raw: String?) -> String {
        guard let raw else { return "" }
        return MailAddressFormatter.collapseSpaces(MailEncodedWords.decode(raw))
    }
}
