import Foundation

/// Даты писем: заголовок Date (RFC 5322, с поблажками на устаревшие форматы) и INTERNALDATE IMAP.
enum MailDate {
    /// `Mon, 16 Nov 2026 10:15:00 +0300 (MSK)`, `16 Nov 26 10:15 GMT`, `Mon Nov 16 10:15:00 2026`.
    static func parseRFC5322(_ raw: String) -> Date? {
        let cleaned = removeComments(raw).replacingOccurrences(of: ",", with: " ")
        var day: Int?
        var month: Int?
        var year: Int?
        var time: (hour: Int, minute: Int, second: Int)?
        var offset: Int?

        for token in cleaned.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let first = token.first, first == "+" || first == "-", token.contains(":") {
                // Нестандартная зона вида +03:00.
                let pieces = token.dropFirst().split(separator: ":").compactMap { Int($0) }
                guard pieces.count == 2 else { continue }
                let seconds = pieces[0] * 3600 + pieces[1] * 60
                offset = first == "-" ? -seconds : seconds
            } else if token.contains(":") {
                guard time == nil else { continue }
                let pieces = token.split(separator: ":").compactMap { Int($0) }
                guard pieces.count == 2 || pieces.count == 3 else { return nil }
                time = (pieces[0], pieces[1], pieces.count == 3 ? pieces[2] : 0)
            } else if let monthIndex = monthNumber(token) {
                month = monthIndex
            } else if let first = token.first, first == "+" || first == "-", token.count == 5, let value = Int(token.dropFirst()) {
                let seconds = (value / 100) * 3600 + (value % 100) * 60
                offset = first == "-" ? -seconds : seconds
            } else if let number = Int(token), token.allSatisfy(\.isNumber) {
                if token.count <= 2 && day == nil {
                    day = number
                } else if year == nil {
                    year = normalizeYear(number, digits: token.count)
                }
            } else if let zone = zoneOffsets[token.uppercased()] {
                offset = zone * 3600
            }
        }

        guard let day, let month, let year else { return nil }
        let clock = time ?? (0, 0, 0)
        return makeDate(year: year, month: month, day: day, hour: clock.hour, minute: clock.minute,
                        second: clock.second, offset: offset ?? 0)
    }

    /// INTERNALDATE: `17-Jul-1996 02:44:25 -0700` (день может быть с пробелом впереди).
    static func parseInternalDate(_ raw: String) -> Date? {
        var tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        tokens[0] = tokens[0].replacingOccurrences(of: "-", with: " ")
        return parseRFC5322(tokens.joined(separator: " "))
    }

    private static func removeComments(_ raw: String) -> String {
        var result = ""
        var depth = 0
        for character in raw {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                result.append(character)
            }
        }
        return result
    }

    private static func monthNumber(_ token: String) -> Int? {
        guard token.count >= 3, token.allSatisfy(\.isLetter) else { return nil }
        let prefix = token.prefix(3).lowercased()
        return months.firstIndex(of: prefix).map { $0 + 1 }
    }

    private static func normalizeYear(_ year: Int, digits: Int) -> Int {
        switch digits {
        case ...2: year < 50 ? 2000 + year : 1900 + year
        case 3: 1900 + year
        default: year
        }
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Устаревшие буквенные зоны (RFC 5322, 4.3) и пара частых нестандартных.
    private static let zoneOffsets: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0,
        "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7,
        "MSK": 3, "CET": 1, "CEST": 2,
    ]

    /// Гражданская дата → секунды от 1970 (алгоритм days_from_civil Х. Хиннанта), без Calendar.
    static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offset: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second), (1900...2200).contains(year) else { return nil }
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + min(second, 59) - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
