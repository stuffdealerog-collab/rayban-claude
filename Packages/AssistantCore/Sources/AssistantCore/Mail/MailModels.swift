import Foundation

/// Параметры IMAP-ящика. Пароль приложения хранится отдельно (Keychain) и передаётся в `IMAPClient`.
public struct MailAccount: Sendable, Codable, Equatable {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    /// Готовые настройки по адресу почты (IMAP over TLS, порт 993). `nil` — домен неизвестен.
    public static func preset(forEmail email: String) -> MailAccount? {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = address.lastIndex(of: "@"), at != address.startIndex else { return nil }
        let domain = address[address.index(after: at)...].lowercased()
        guard let host = presetHosts[domain] else { return nil }
        return MailAccount(host: host, port: 993, username: address)
    }

    private static let presetHosts: [String: String] = [
        "gmail.com": "imap.gmail.com",
        "googlemail.com": "imap.gmail.com",
        "yandex.ru": "imap.yandex.com",
        "yandex.com": "imap.yandex.com",
        "ya.ru": "imap.yandex.com",
        "yandex.uz": "imap.yandex.com",
        "yandex.by": "imap.yandex.com",
        "yandex.kz": "imap.yandex.com",
        "yandex.ua": "imap.yandex.com",
        "mail.ru": "imap.mail.ru",
        "inbox.ru": "imap.mail.ru",
        "list.ru": "imap.mail.ru",
        "bk.ru": "imap.mail.ru",
        "icloud.com": "imap.mail.me.com",
        "me.com": "imap.mail.me.com",
        "mac.com": "imap.mail.me.com",
        "outlook.com": "outlook.office365.com",
        "hotmail.com": "outlook.office365.com",
        "live.com": "outlook.office365.com",
    ]
}

/// Краткие сведения о письме для списка.
public struct MailSummary: Sendable, Equatable {
    public let uid: UInt32
    /// «Имя <адрес>» или просто адрес.
    public let from: String
    public let subject: String
    /// Дата из заголовка Date, иначе INTERNALDATE сервера.
    public let date: Date?
    public let isUnread: Bool
    /// Начало текста одной строкой (~200 символов).
    public let snippet: String

    public init(uid: UInt32, from: String, subject: String, date: Date?, isUnread: Bool, snippet: String) {
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.isUnread = isUnread
        self.snippet = snippet
    }
}

/// Письмо целиком (текстовая часть).
public struct MailMessage: Sendable, Equatable {
    public let uid: UInt32
    public let from: String
    public let to: String
    public let subject: String
    public let date: Date?
    /// text/plain, либо text/html без разметки; обрезано до `maxLength`.
    public let text: String

    public init(uid: UInt32, from: String, to: String, subject: String, date: Date?, text: String) {
        self.uid = uid
        self.from = from
        self.to = to
        self.subject = subject
        self.date = date
        self.text = text
    }
}

/// Ошибки почты; тексты — для пользователя (озвучиваются ассистентом).
public enum MailError: LocalizedError, Sendable, Equatable {
    case authenticationFailed(String)
    case connectionFailed(String)
    case protocolError(String)
    case timeout
    case notFound

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let text):
            text.isEmpty
                ? "Не удалось войти в почту. Проверьте адрес и пароль приложения."
                : "Не удалось войти в почту: \(text)"
        case .connectionFailed(let text):
            "Нет связи с почтовым сервером: \(text)"
        case .protocolError(let text):
            "Ошибка почтового сервера: \(text)"
        case .timeout:
            "Почтовый сервер не отвечает."
        case .notFound:
            "Письмо не найдено."
        }
    }
}
