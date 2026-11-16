import AssistantCore
import Foundation
import Observation
import Security

/// Модели Claude, доступные в настройках.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case haiku55 = "claude-haiku-5-5"
    case sonnet55 = "claude-sonnet-5-5"
    case opus55 = "claude-opus-5-5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .haiku55: return "Claude Haiku 5.5"
        case .sonnet55: return "Claude Sonnet 5.5"
        case .opus55: return "Claude Opus 5.5"
        }
    }

    var shortTitle: String {
        switch self {
        case .haiku55: return "Haiku 5.5"
        case .sonnet55: return "Sonnet 5.5"
        case .opus55: return "Opus 5.5"
        }
    }

    var subtitle: String {
        switch self {
        case .haiku55: return L("Самый быстрый и в двадцать раз дешевле Sonnet")
        case .sonnet55: return L("Лучший баланс: живой разговор и хороший узбекский")
        case .opus55: return L("Умнее в сложных задачах, медленнее и дороже")
        }
    }

    /// Настройка «не размышлять перед ответом» для этой модели; nil — модель так не умеет.
    var instantThinking: String? {
        switch self {
        case .haiku55: return "disabled"
        case .sonnet55: return "between_tools"
        case .opus55: return nil
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
        case .russian: return L("Русский")
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
    /// Отвечать сразу, без размышления перед ответом: быстрее первая фраза.
    var instantAnswers: Bool {
        didSet { defaults.set(instantAnswers, forKey: Keys.instantAnswers) }
    }

    // MARK: Речь

    /// Язык ассистента и интерфейса приложения.
    var language: AssistantLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            L10n.setLanguage(language.isoCode)
            // Имя ещё не выбирали — пишем его так, как принято на новом языке.
            if !onboardingCompleted, Persona.defaultNames.contains(persona.assistantName) {
                persona.assistantName = language == .russian ? "Джарвис" : "Jarvis"
            }
        }
    }
    /// Когда отвечать на услышанное в режимах «Без рук» и «На связи».
    var addressing: AddressingMode {
        didSet { defaults.set(addressing.rawValue, forKey: Keys.addressing) }
    }
    /// Ассистент отвечает не на всё подряд: по имени или когда сам понял, что обращаются к нему.
    var wakeWordEnabled: Bool { addressing != .always }
    /// Пусто — обращение по имени ассистента.
    var wakeWord: String {
        didSet { defaults.set(wakeWord, forKey: Keys.wakeWord) }
    }
    var effectiveWakeWord: String {
        let custom = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? persona.displayName : custom
    }
    /// Эксперимент: двойное касание дужки или кнопка камеры вызывают ассистента.
    var glassesGestures: Bool {
        didSet { defaults.set(glassesGestures, forKey: Keys.glassesGestures) }
    }
    /// Сколько секунд после ответа можно говорить без обращения по имени (0 — всегда с именем).
    var followUpSeconds: Double {
        didSet { defaults.set(followUpSeconds, forKey: Keys.followUpSeconds) }
    }
    /// Распознавать речь потоком через ElevenLabs (точнее, понимает узбекский) вместо Apple.
    var liveRecognition: Bool {
        didSet { defaults.set(liveRecognition, forKey: Keys.liveRecognition) }
    }
    /// Смешанная речь: узбекский и русский вперемешку в одной фразе.
    var mixedSpeech: Bool {
        didSet { defaults.set(mixedSpeech, forKey: Keys.mixedSpeech) }
    }

    /// Потоковое распознавание доступно и включено.
    var usesLiveRecognition: Bool { liveRecognition && !trimmedElevenLabsKey.isEmpty }

    /// Настройки потокового распознавания для языка (ISO 639-1); остальные языки приложения — запасные.
    func scribeConfiguration(
        language: String, others: [String]? = nil, detectLanguage: Bool = false, silence: Double = 0.7
    ) -> ScribeLiveConfiguration? {
        guard usesLiveRecognition else { return nil }
        let expected = others ?? AssistantLanguage.allCases.map(\.isoCode).filter { $0 != language }
        return ScribeLiveConfiguration(
            apiKey: trimmedElevenLabsKey,
            languageCode: language,
            secondaryLanguages: expected,
            multilingual: mixedSpeech,
            silenceSeconds: silence,
            detectLanguage: detectLanguage
        )
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
    /// Перевод ваших слов звучит из динамика телефона — для собеседника.
    var translatorPartnerSpeaker: Bool {
        didSet { defaults.set(translatorPartnerSpeaker, forKey: Keys.translatorPartnerSpeaker) }
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
            model: elevenLabsModel,
            languageCode: code
        ).adapted(to: code)
    }

    var elevenLabsConfiguration: ElevenLabsConfiguration? { voiceConfiguration() }

    /// Потоковая озвучка — только для моделей v4.
    var streamingVoiceConfiguration: DialogueSpeechConfiguration? {
        guard elevenLabsModel.streams, let voice = voiceConfiguration() else { return nil }
        return DialogueSpeechConfiguration(
            apiKey: voice.apiKey, voiceID: voice.voiceID, model: elevenLabsModel.rawValue, languageCode: voice.languageCode
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        persona = defaults.data(forKey: Keys.persona).flatMap { try? JSONDecoder().decode(Persona.self, from: $0) } ?? Persona()
        apiKey = KeychainStore.read(account: Keys.apiKey) ?? ""
        model = defaults.string(forKey: Keys.model).flatMap(ClaudeModel.init(rawValue:)) ?? .sonnet55
        webSearchEnabled = defaults.object(forKey: Keys.webSearch) as? Bool ?? true
        saveTokens = defaults.object(forKey: Keys.saveTokens) as? Bool ?? true
        instantAnswers = defaults.object(forKey: Keys.instantAnswers) as? Bool ?? true
        liveRecognition = defaults.object(forKey: Keys.liveRecognition) as? Bool ?? true
        mixedSpeech = defaults.object(forKey: Keys.mixedSpeech) as? Bool ?? false
        language = defaults.string(forKey: Keys.language).flatMap(AssistantLanguage.init(rawValue:)) ?? Self.systemLanguage
        if let saved = defaults.string(forKey: Keys.addressing).flatMap(AddressingMode.init(rawValue:)) {
            addressing = saved
        } else {
            // Прежняя настройка «Обращение по имени»: выключенная означала «отвечать на всё».
            addressing = defaults.object(forKey: Keys.wakeWordEnabled) as? Bool == false ? .always : .smart
        }
        wakeWord = defaults.string(forKey: Keys.wakeWord) ?? ""
        followUpSeconds = defaults.object(forKey: Keys.followUpSeconds) as? Double ?? 8
        glassesGestures = defaults.bool(forKey: Keys.glassesGestures)
        elevenLabsAPIKey = KeychainStore.read(account: Keys.elevenLabsKey) ?? ""
        elevenLabsVoiceID = defaults.string(forKey: Keys.elevenLabsVoiceID) ?? ""
        elevenLabsVoiceName = defaults.string(forKey: Keys.elevenLabsVoiceName) ?? ""
        elevenLabsModel = defaults.string(forKey: Keys.elevenLabsModel).flatMap(ElevenLabsModel.init(rawValue:)) ?? .v4Turbo
        stereoAnswers = defaults.object(forKey: Keys.stereoAnswers) as? Bool ?? true
        mailAddress = defaults.string(forKey: Keys.mailAddress) ?? ""
        mailHost = defaults.string(forKey: Keys.mailHost) ?? ""
        mailPassword = KeychainStore.read(account: Keys.mailPassword) ?? ""
        translatorMine = defaults.string(forKey: Keys.translatorMine) ?? "ru-RU"
        translatorTheirs = defaults.string(forKey: Keys.translatorTheirs) ?? "en-US"
        translatorSpeaks = defaults.object(forKey: Keys.translatorSpeaks) as? Bool ?? true
        translatorPartnerSpeaker = defaults.object(forKey: Keys.translatorPartnerSpeaker) as? Bool ?? true

        // didSet в init не срабатывает — язык интерфейса задаём явно, когда все свойства уже заполнены.
        L10n.setLanguage(language.isoCode)
        if !onboardingCompleted, Persona.defaultNames.contains(persona.assistantName) {
            persona.assistantName = language == .russian ? "Джарвис" : "Jarvis"
        }
    }

    /// Язык при первом запуске — по языку iPhone: узбекский, английский, иначе русский.
    private static var systemLanguage: AssistantLanguage {
        for identifier in Locale.preferredLanguages {
            let code = identifier.prefix(2).lowercased()
            if code == "uz" { return .uzbek }
            if code == "ru" { return .russian }
            if code == "en" { return .english }
        }
        return .russian
    }

    private enum Keys {
        static let onboardingCompleted = "onboardingCompleted"
        static let persona = "persona"
        static let apiKey = "anthropic-api-key"
        static let model = "model.v2"
        static let webSearch = "webSearchEnabled"
        static let saveTokens = "saveTokens"
        static let instantAnswers = "instantAnswers"
        static let liveRecognition = "liveRecognition"
        static let mixedSpeech = "mixedSpeech"
        static let language = "language"
        static let wakeWordEnabled = "wakeWordEnabled"
        static let addressing = "addressing"
        static let wakeWord = "wakeWord.v2"
        static let followUpSeconds = "followUpSeconds"
        static let glassesGestures = "glassesGestures"
        static let elevenLabsKey = "elevenlabs-api-key"
        static let elevenLabsVoiceID = "elevenLabsVoiceID"
        static let elevenLabsVoiceName = "elevenLabsVoiceName"
        static let elevenLabsModel = "elevenLabsModel.v2"
        static let stereoAnswers = "stereoAnswers"
        static let mailAddress = "mailAddress"
        static let mailHost = "mailHost"
        static let mailPassword = "mail-password"
        static let translatorMine = "translatorMine"
        static let translatorTheirs = "translatorTheirs"
        static let translatorSpeaks = "translatorSpeaks"
        static let translatorPartnerSpeaker = "translatorPartnerSpeaker"
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
