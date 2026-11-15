import ClaudeKit
import Contacts
import Foundation
import MessageUI
import UIKit

// MARK: - Контакты

struct FoundContact: Sendable {
    let name: String
    let phones: [String]
    let emails: [String]
}

enum ContactsDirectory {
    static func search(_ query: String) async throws -> [FoundContact] {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined, !(await ToolSupport.isAppActive()) {
            throw ToolFailure(ToolSupport.foregroundNeeded)
        }
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else {
            throw ToolFailure("Нет доступа к Контактам. Разрешите его: Настройки iOS → Конфиденциальность → Контакты.")
        }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        return contacts.prefix(8).map { contact in
            FoundContact(
                name: CNContactFormatter.string(from: contact, style: .fullName) ?? contact.nickname,
                phones: contact.phoneNumbers.map { $0.value.stringValue },
                emails: contact.emailAddresses.map { $0.value as String }
            )
        }
    }

    /// Номер из текста («+998 90 123-45-67») или из контакта по имени.
    static func resolvePhone(_ recipient: String) async throws -> (name: String, phone: String) {
        let digits = recipient.filter { $0.isNumber }
        if digits.count >= 7 {
            return (recipient, phoneDigits(recipient))
        }
        let matches = try await search(recipient).filter { !$0.phones.isEmpty }
        guard let first = matches.first else {
            throw ToolFailure("В контактах нет «\(recipient)» с номером телефона. Уточни имя или назови номер.")
        }
        let distinctNames = Set(matches.map(\.name))
        if distinctNames.count > 1 {
            throw ToolFailure("Нашлось несколько контактов: \(distinctNames.sorted().joined(separator: ", ")). Уточни, кому.")
        }
        return (first.name, phoneDigits(first.phones[0]))
    }

    static func phoneDigits(_ text: String) -> String {
        let plus = text.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
        return plus + text.filter { $0.isNumber }
    }
}

struct FindContactTool: ClaudeTool {
    let name = "find_contact"
    let description = "Ищет человека в Контактах iPhone по имени. Возвращает телефоны и почту."
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["query": ["type": "string", "description": "Имя или его часть."]],
        "required": ["query"],
    ]

    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        guard let query = ToolSupport.string(input, "query") else { return .error("Нужно имя.") }
        let contacts = try await ContactsDirectory.search(query)
        guard !contacts.isEmpty else { return .text("В контактах никого не нашлось по запросу «\(query)».") }
        let lines = contacts.map { contact in
            var parts = [contact.name]
            if !contact.phones.isEmpty { parts.append("тел.: " + contact.phones.joined(separator: ", ")) }
            if !contact.emails.isEmpty { parts.append("почта: " + contact.emails.joined(separator: ", ")) }
            return "• " + parts.joined(separator: "; ")
        }
        return .text(lines.joined(separator: "\n"))
    }
}

// MARK: - Сообщения

struct SendMessageTool: ClaudeTool {
    let name = "send_message"
    let description = """
    Готовит сообщение и открывает его для отправки: SMS/iMessage, WhatsApp или Telegram. \
    Получатель — имя из контактов или номер телефона. Отправляет пользователь нажатием «Отправить» — iOS иначе не позволяет. \
    В Telegram чат выбирается в самом Telegram.
    """
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "app": ["type": "string", "enum": ["sms", "whatsapp", "telegram"], "description": "sms включает iMessage."],
            "to": ["type": "string", "description": "Имя контакта или номер телефона (для telegram необязательно)."],
            "text": ["type": "string", "description": "Текст сообщения."],
        ],
        "required": ["app", "text"],
    ]

    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        guard let text = ToolSupport.string(input, "text") else { return .error("Нужен текст сообщения.") }
        guard await ToolSupport.isAppActive() else { return .error(ToolSupport.foregroundNeeded) }
        let app = ToolSupport.string(input, "app") ?? "sms"
        let recipient = ToolSupport.string(input, "to")

        switch app {
        case "telegram":
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            guard let url = URL(string: "tg://msg?text=\(encoded)"), await open(url) else {
                return .error("Telegram не установлен.")
            }
            return .text("Открыл Telegram с текстом сообщения — пользователь выбирает чат и нажимает «Отправить».")

        case "whatsapp":
            guard let recipient else { return .error("Для WhatsApp нужен получатель.") }
            let target = try await ContactsDirectory.resolvePhone(recipient)
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let digits = target.phone.filter { $0.isNumber }
            guard let url = URL(string: "https://wa.me/\(digits)?text=\(encoded)"), await open(url) else {
                return .error("Не удалось открыть WhatsApp.")
            }
            return .text("Открыл чат WhatsApp с \(target.name) и готовым текстом — осталось нажать «Отправить».")

        default:
            guard let recipient else { return .error("Нужен получатель.") }
            let target = try await ContactsDirectory.resolvePhone(recipient)
            let result = await MessageComposer.compose(to: target.phone, text: text)
            switch result {
            case .sent: return .text("Сообщение для \(target.name) отправлено.")
            case .cancelled: return .text("Пользователь отменил отправку сообщения для \(target.name).")
            case .unavailable: return .error("Этот iPhone не может отправлять SMS/iMessage.")
            case .pending: return .text("Окно сообщения для \(target.name) открыто, пользователь ещё не подтвердил отправку.")
            case .failed: return .error("Сообщение не отправилось.")
            }
        }
    }

    private func open(_ url: URL) async -> Bool {
        await ToolSupport.openURL(url)
    }
}

/// Окно отправки SMS/iMessage и ожидание решения пользователя.
@MainActor
final class MessageComposer: NSObject, MFMessageComposeViewControllerDelegate {
    enum Outcome { case sent, cancelled, failed, unavailable, pending }

    private static var active: MessageComposer?
    private var continuation: CheckedContinuation<Outcome, Never>?

    static func compose(to phone: String, text: String) async -> Outcome {
        guard MFMessageComposeViewController.canSendText(), let presenter = ToolSupport.topViewController() else {
            return .unavailable
        }
        let composer = MessageComposer()
        active = composer
        let controller = MFMessageComposeViewController()
        controller.recipients = [phone]
        controller.body = text
        controller.messageComposeDelegate = composer
        return await withCheckedContinuation { continuation in
            composer.continuation = continuation
            presenter.present(controller, animated: true)
            // Не держим разговор бесконечно: через 2 минуты отвечаем, что окно ещё открыто.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                composer.finish(.pending)
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
        if outcome != .pending, Self.active === self { Self.active = nil }
    }

    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        let outcome: Outcome
        switch result {
        case .sent: outcome = .sent
        case .cancelled: outcome = .cancelled
        default: outcome = .failed
        }
        // Делегат вызывается на главном потоке.
        MainActor.assumeIsolated {
            controller.dismiss(animated: true)
            self.finish(outcome)
            if Self.active === self { Self.active = nil }
        }
    }
}

// MARK: - Письма

struct ComposeEmailTool: ClaudeTool {
    let name = "compose_email"
    let description = "Готовит письмо в почтовом приложении iPhone. Отправляет пользователь сам."
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "to": ["type": "string", "description": "Адрес или имя из контактов."],
            "subject": ["type": "string"],
            "body": ["type": "string"],
        ],
        "required": ["to", "body"],
    ]

    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        guard let recipient = ToolSupport.string(input, "to"), let body = ToolSupport.string(input, "body") else {
            return .error("Нужны получатель и текст письма.")
        }
        guard await ToolSupport.isAppActive() else { return .error(ToolSupport.foregroundNeeded) }
        var address = recipient
        if !recipient.contains("@") {
            let matches = try await ContactsDirectory.search(recipient).filter { !$0.emails.isEmpty }
            guard let first = matches.first else { return .error("У «\(recipient)» в контактах нет почты.") }
            address = first.emails[0]
        }
        let subject = ToolSupport.string(input, "subject") ?? ""
        let outcome = await MailComposer.compose(to: address, subject: subject, body: body)
        switch outcome {
        case .sent: return .text("Письмо для \(address) отправлено.")
        case .saved: return .text("Письмо сохранено в черновиках.")
        case .cancelled: return .text("Пользователь отменил письмо.")
        case .openedMailApp: return .text("Открыл письмо в почтовом приложении — пользователь отправит сам.")
        case .pending: return .text("Окно письма открыто, пользователь ещё не отправил.")
        case .failed: return .error("Не удалось подготовить письмо.")
        }
    }
}

@MainActor
final class MailComposer: NSObject, MFMailComposeViewControllerDelegate {
    enum Outcome { case sent, saved, cancelled, failed, openedMailApp, pending }

    private static var active: MailComposer?
    private var continuation: CheckedContinuation<Outcome, Never>?

    static func compose(to address: String, subject: String, body: String) async -> Outcome {
        guard MFMailComposeViewController.canSendMail(), let presenter = ToolSupport.topViewController() else {
            // Нет настроенной Почты — открываем mailto: в любом почтовом приложении.
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = address
            components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            guard let url = components.url, await UIApplication.shared.open(url) else { return .failed }
            return .openedMailApp
        }
        let composer = MailComposer()
        active = composer
        let controller = MFMailComposeViewController()
        controller.setToRecipients([address])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        controller.mailComposeDelegate = composer
        return await withCheckedContinuation { continuation in
            composer.continuation = continuation
            presenter.present(controller, animated: true)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                composer.finish(.pending)
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }

    nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        let outcome: Outcome
        switch result {
        case .sent: outcome = .sent
        case .saved: outcome = .saved
        case .cancelled: outcome = .cancelled
        default: outcome = .failed
        }
        MainActor.assumeIsolated {
            controller.dismiss(animated: true)
            self.finish(outcome)
            if Self.active === self { Self.active = nil }
        }
    }
}

// MARK: - Звонки

struct CallTool: ClaudeTool {
    let name = "call"
    let description = "Звонит контакту или на номер: обычный звонок или FaceTime-аудио. iOS сама попросит подтвердить вызов."
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "to": ["type": "string", "description": "Имя из контактов или номер."],
            "via": ["type": "string", "enum": ["phone", "facetime"], "description": "По умолчанию phone."],
        ],
        "required": ["to"],
    ]

    func run(_ input: [String: JSONValue]) async throws -> ToolOutput {
        guard let recipient = ToolSupport.string(input, "to") else { return .error("Кому звонить?") }
        guard await ToolSupport.isAppActive() else { return .error(ToolSupport.foregroundNeeded) }
        let target = try await ContactsDirectory.resolvePhone(recipient)
        let scheme = ToolSupport.string(input, "via") == "facetime" ? "facetime-audio" : "tel"
        guard let url = URL(string: "\(scheme)://\(target.phone)") else { return .error("Неверный номер.") }
        let opened = await ToolSupport.openURL(url)
        return opened ? .text("Набираю \(target.name).") : .error("Не удалось начать звонок.")
    }
}
