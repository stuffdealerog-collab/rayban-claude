import AssistantCore
import Foundation
import Observation
import Security

/// Модели Claude, доступные в настройках.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case sonnet55 = "claude-sonnet-5-5"
    case opus55 = "claude-opus-5-5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sonnet55: return "Claude Sonnet 5.5"
        case .opus55: return "Claude Opus 5.5"
        }
    }

    var subtitle: String {
        switch self {
        case .sonnet55: return "Быстрее и вдвое дешевле — для живого разговора"
        case .opus55: return "Умнее в сложных задачах, медленнее и дороже"
        }
    }
}

/// Язык управления: на нём ассистент слушает и по умолчанию отвечает.
enum AssistantLanguage: String, CaseIterable, Identifiable, Sendable {
    case russian = "ru-RU"
    case uzbek = "uz-UZ"
    case english = "en-US"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .russian: return "Русский"
        case .uzbek: return "Oʻzbekcha"
        case .english: return "English"
        }
    }

    /// ISO 639-1 для ElevenLabs.
    var isoCode: String {
        switch self {
        case .russian: return "ru"
        case .uzbek: return "uz"
        case .english: return "en"
        }
    }

    /// У Apple нет распознавания и голоса для узбекского — нужен ElevenLabs.
    var needsElevenLabs: Bool { self == .uzbek }

    var promptName: String {
        switch self {
        case .russian: return "русском"
        case .uzbek: return "узбекском (латиница)"
        case .english: return "английском"
        }
    }

    /// Короткое «Да?» на языке пользователя.
    var acknowledgement: String {
        switch self {
        case .russian: return "Да?"
        case .uzbek: return "Ha?"
        case .english: return "Yes?"
        }
    }

    var failureMessage: String {
        switch self {
        case .russian: return "Не получилось получить ответ."
        case .uzbek: return "Javob olib boʻlmadi."
        case .english: return "I couldn't get an answer."
        }
    }

    var refusalMessage: String {
        switch self {
        case .russian: return "Извините, с этим я помочь не могу."
        case .uzbek: return "Kechirasiz, bunga yordam bera olmayman."
        case .english: return "Sorry, I can't help with that."
        }
    }
}

/// Настройки приложения. Ключи и пароль почты — в Keychain, остальное — в UserDefaults.
@MainActor
@Observable
final class AppSettings {
    // MARK: Первый запуск и личность

    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }
    var persona: Persona {
        didSet { if let data = try? JSONEncoder().encode(persona) { defaults.set(data, forKey: Keys.persona) } }
    }

    // MARK: Claude

    var apiKey: String {
        didSet { KeychainStore.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Keys.apiKey) }
    }
    var model: ClaudeModel {
        didSet { defaults.set(model.rawValue, forKey: Keys.model) }
    }
    var webSearchEnabled: Bool {
        didSet { defaults.set(webSearchEnabled, forKey: Keys.webSearch) }
    }
    /// Сервер убирает из длинного диалога старые снимки и результаты поиска.
    var saveTokens: Bool {
        didSet { defaults.set(saveTokens, forKey: Keys.saveTokens) }
    }

    // MARK: Речь

    var language: AssistantLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    /// В режиме «без рук» отвечать только на фразы, начинающиеся с обращения.
    var wakeWordEnabled: Bool {
        didSet { defaults.set(wakeWordEnabled, forKey: Keys.wakeWordEnabled) }
    }
    /// Пусто — обращение по имени ассистента.
    var wakeWord: String {
        didSet { defaults.set(wakeWord, forKey: Keys.wakeWord) }
    }
    var effectiveWakeWord: String {
        let custom = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? persona.displayName : custom
    }

    // MARK: Голос

    /// Ключ ElevenLabs. Пустой — ассистент говорит голосом iOS.
    var elevenLabsAPIKey: String {
        didSet { KeychainStore.write(trimmedElevenLabsKey, account: Keys.elevenLabsKey) }
    }
    var elevenLabsVoiceID: String {
        didSet { defaults.set(elevenLabsVoiceID, forKey: Keys.elevenLabsVoiceID) }
    }
    /// Имя выбранного голоса — чтобы показать его, пока список голосов не загружен.
    var elevenLabsVoiceName: String {
        didSet { defaults.set(elevenLabsVoiceName, forKey: Keys.elevenLabsVoiceName) }
    }
    var elevenLabsModel: ElevenLabsModel {
        didSet { defaults.set(elevenLabsModel.rawValue, forKey: Keys.elevenLabsModel) }
    }
    /// В режиме кнопки отвечать через A2DP (стерео, полное качество) вместо гарнитурного HFP.
    var stereoAnswers: Bool {
        didSet { defaults.set(stereoAnswers, forKey: Keys.stereoAnswers) }
    }

    // MARK: Почта

    var mailAddress: String {
        didSet { defaults.set(mailAddress, forKey: Keys.mailAddress) }
    }
    /// Сервер IMAP; пусто — по адресу (Gmail, Яндекс, Mail.ru, iCloud, Outlook).
    var mailHost: String {
        didSet { defaults.set(mailHost, forKey: Keys.mailHost) }
    }
    var mailPassword: String {
        didSet { KeychainStore.write(mailPassword, account: Keys.mailPassword) }
    }

    var mailAccount: MailAccount? {
        let address = mailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), !mailPassword.isEmpty else { return nil }
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty { return MailAccount(host: host, port: 993, username: address) }
        return MailAccount.preset(forEmail: address)
    }

    // MARK: Переводчик

    var translatorMine: String {
        didSet { defaults.set(translatorMine, forKey: Keys.translatorMine) }
    }
    var translatorTheirs: String {
        didSet { defaults.set(translatorTheirs, forKey: Keys.translatorTheirs) }
    }
    var translatorSpeaks: Bool {
        didSet { defaults.set(translatorSpeaks, forKey: Keys.translatorSpeaks) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    var trimmedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedElevenLabsKey: String { elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Настройки синтеза ElevenLabs для языка или nil, если ключ или голос не заданы.
    /// Узбекский умеет только модель v3, поэтому для него она выбирается сама.
    func voiceConfiguration(for languageCode: String? = nil) -> ElevenLabsConfiguration? {
        let voiceID = elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedElevenLabsKey.isEmpty, !voiceID.isEmpty,
              voiceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        let code = languageCode ?? language.isoCode
        return ElevenLabsConfiguration(
            apiKey: trimmedElevenLabsKey,
            voiceID: voiceID,
            model: ElevenLabsModel.flashLanguages.contains(code) || elevenLabsModel == .v3 ? elevenLabsModel : .v3,
            languageCode: code
        )
    }

    var elevenLabsConfiguration: ElevenLabsConfiguration? { voiceConfiguration() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        persona = defaults.data(forKey: Keys.persona).flatMap { try? JSONDecoder().decode(Persona.self, from: $0) } ?? Persona()
        apiKey = KeychainStore.read(account: Keys.apiKey) ?? ""
        model = defaults.string(forKey: Keys.model).flatMap(ClaudeModel.init(rawValue:)) ?? .sonnet55
        webSearchEnabled = defaults.object(forKey: Keys.webSearch) as? Bool ?? true
        saveTokens = defaults.object(forKey: Keys.saveTokens) as? Bool ?? true
        language = defaults.string(forKey: Keys.language).flatMap(AssistantLanguage.init(rawValue:)) ?? .russian
        wakeWordEnabled = defaults.object(forKey: Keys.wakeWordEnabled) as? Bool ?? true
        wakeWord = defaults.string(forKey: Keys.wakeWord) ?? ""
        elevenLabsAPIKey = KeychainStore.read(account: Keys.elevenLabsKey) ?? ""
        elevenLabsVoiceID = defaults.string(forKey: Keys.elevenLabsVoiceID) ?? ""
        elevenLabsVoiceName = defaults.string(forKey: Keys.elevenLabsVoiceName) ?? ""
        elevenLabsModel = defaults.string(forKey: Keys.elevenLabsModel).flatMap(ElevenLabsModel.init(rawValue:)) ?? .flash
        stereoAnswers = defaults.object(forKey: Keys.stereoAnswers) as? Bool ?? true
        mailAddress = defaults.string(forKey: Keys.mailAddress) ?? ""
        mailHost = defaults.string(forKey: Keys.mailHost) ?? ""
        mailPassword = KeychainStore.read(account: Keys.mailPassword) ?? ""
        translatorMine = defaults.string(forKey: Keys.translatorMine) ?? "ru-RU"
        translatorTheirs = defaults.string(forKey: Keys.translatorTheirs) ?? "en-US"
        translatorSpeaks = defaults.object(forKey: Keys.translatorSpeaks) as? Bool ?? true
    }

    private enum Keys {
        static let onboardingCompleted = "onboardingCompleted"
        static let persona = "persona"
        static let apiKey = "anthropic-api-key"
        static let model = "model.v2"
        static let webSearch = "webSearchEnabled"
        static let saveTokens = "saveTokens"
        static let language = "language"
        static let wakeWordEnabled = "wakeWordEnabled"
        static let wakeWord = "wakeWord.v2"
        static let elevenLabsKey = "elevenlabs-api-key"
        static let elevenLabsVoiceID = "elevenLabsVoiceID"
        static let elevenLabsVoiceName = "elevenLabsVoiceName"
        static let elevenLabsModel = "elevenLabsModel"
        static let stereoAnswers = "stereoAnswers"
        static let mailAddress = "mailAddress"
        static let mailHost = "mailHost"
        static let mailPassword = "mail-password"
        static let translatorMine = "translatorMine"
        static let translatorTheirs = "translatorTheirs"
        static let translatorSpeaks = "translatorSpeaks"
    }
}

/// Простое хранилище строк в Keychain.
enum KeychainStore {
    private static var service: String { Bundle.main.bundleIdentifier ?? "RayBanClaude" }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }

        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        // Доступно после первой разблокировки: ассистент работает и при заблокированном экране.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
