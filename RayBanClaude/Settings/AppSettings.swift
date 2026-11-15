import Foundation
import Observation
import Security

/// Модели Claude, доступные в настройках.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case opus55 = "claude-opus-5-5"
    case sonnet55 = "claude-sonnet-5-5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opus55: return "Claude Opus 5.5"
        case .sonnet55: return "Claude Sonnet 5.5"
        }
    }
}

/// Язык распознавания и синтеза речи.
enum AssistantLanguage: String, CaseIterable, Identifiable {
    case russian = "ru-RU"
    case english = "en-US"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .russian: return "Русский"
        case .english: return "English"
        }
    }

    var defaultWakeWord: String {
        switch self {
        case .russian: return "Клод"
        case .english: return "Claude"
        }
    }

    /// ISO 639-1 для ElevenLabs.
    var isoCode: String {
        switch self {
        case .russian: return "ru"
        case .english: return "en"
        }
    }
}

/// Настройки приложения. API-ключ хранится в Keychain, остальное — в UserDefaults.
@MainActor
@Observable
final class AppSettings {
    var apiKey: String {
        didSet { KeychainStore.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Keys.apiKey) }
    }
    var model: ClaudeModel {
        didSet { defaults.set(model.rawValue, forKey: Keys.model) }
    }
    var language: AssistantLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    /// В режиме «без рук» отвечать только на фразы, начинающиеся с обращения.
    var wakeWordEnabled: Bool {
        didSet { defaults.set(wakeWordEnabled, forKey: Keys.wakeWordEnabled) }
    }
    var wakeWord: String {
        didSet { defaults.set(wakeWord, forKey: Keys.wakeWord) }
    }
    var webSearchEnabled: Bool {
        didSet { defaults.set(webSearchEnabled, forKey: Keys.webSearch) }
    }

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

    @ObservationIgnored private let defaults: UserDefaults

    var trimmedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedElevenLabsKey: String { elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Настройки синтеза ElevenLabs или nil, если ключ или голос не заданы.
    var elevenLabsConfiguration: ElevenLabsConfiguration? {
        let voiceID = elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedElevenLabsKey.isEmpty, !voiceID.isEmpty,
              voiceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return ElevenLabsConfiguration(
            apiKey: trimmedElevenLabsKey,
            voiceID: voiceID,
            model: elevenLabsModel,
            languageCode: language.isoCode
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apiKey = KeychainStore.read(account: Keys.apiKey) ?? ""
        model = defaults.string(forKey: Keys.model).flatMap(ClaudeModel.init(rawValue:)) ?? .opus55
        let language = defaults.string(forKey: Keys.language).flatMap(AssistantLanguage.init(rawValue:)) ?? .russian
        self.language = language
        wakeWordEnabled = defaults.object(forKey: Keys.wakeWordEnabled) as? Bool ?? true
        wakeWord = defaults.string(forKey: Keys.wakeWord) ?? language.defaultWakeWord
        webSearchEnabled = defaults.object(forKey: Keys.webSearch) as? Bool ?? true
        elevenLabsAPIKey = KeychainStore.read(account: Keys.elevenLabsKey) ?? ""
        elevenLabsVoiceID = defaults.string(forKey: Keys.elevenLabsVoiceID) ?? ""
        elevenLabsVoiceName = defaults.string(forKey: Keys.elevenLabsVoiceName) ?? ""
        elevenLabsModel = defaults.string(forKey: Keys.elevenLabsModel).flatMap(ElevenLabsModel.init(rawValue:)) ?? .flash
        stereoAnswers = defaults.object(forKey: Keys.stereoAnswers) as? Bool ?? true
    }

    private enum Keys {
        static let apiKey = "anthropic-api-key"
        static let model = "model"
        static let language = "language"
        static let wakeWordEnabled = "wakeWordEnabled"
        static let wakeWord = "wakeWord"
        static let webSearch = "webSearchEnabled"
        static let elevenLabsKey = "elevenlabs-api-key"
        static let elevenLabsVoiceID = "elevenLabsVoiceID"
        static let elevenLabsVoiceName = "elevenLabsVoiceName"
        static let elevenLabsModel = "elevenLabsModel"
        static let stereoAnswers = "stereoAnswers"
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
