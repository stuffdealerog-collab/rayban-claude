import ClaudeKit
import Foundation
import Observation

/// Язык переводчика.
struct TranslatorLanguage: Identifiable, Hashable, Sendable {
    /// BCP-47 для распознавания, например `uz-UZ`.
    let code: String
    /// Самоназвание: «Oʻzbekcha», «English».
    let name: String
    /// Название по-русски для промпта.
    let russianName: String

    var id: String { code }
    /// ISO 639-1 для голоса.
    var iso: String { String(code.prefix(2)) }

    static let all: [TranslatorLanguage] = [
        .init(code: "ru-RU", name: "Русский", russianName: "русский"),
        .init(code: "uz-UZ", name: "Oʻzbekcha", russianName: "узбекский (латиница)"),
        .init(code: "en-US", name: "English", russianName: "английский"),
        .init(code: "tr-TR", name: "Türkçe", russianName: "турецкий"),
        .init(code: "kk-KZ", name: "Қазақша", russianName: "казахский"),
        .init(code: "ky-KG", name: "Кыргызча", russianName: "киргизский"),
        .init(code: "tg-TJ", name: "Тоҷикӣ", russianName: "таджикский"),
        .init(code: "zh-CN", name: "中文", russianName: "китайский (упрощённый)"),
        .init(code: "ko-KR", name: "한국어", russianName: "корейский"),
        .init(code: "ja-JP", name: "日本語", russianName: "японский"),
        .init(code: "ar-SA", name: "العربية", russianName: "арабский"),
        .init(code: "hi-IN", name: "हिन्दी", russianName: "хинди"),
        .init(code: "de-DE", name: "Deutsch", russianName: "немецкий"),
        .init(code: "fr-FR", name: "Français", russianName: "французский"),
        .init(code: "es-ES", name: "Español", russianName: "испанский"),
        .init(code: "it-IT", name: "Italiano", russianName: "итальянский"),
        .init(code: "uk-UA", name: "Українська", russianName: "украинский"),
    ]

    static func find(_ code: String) -> TranslatorLanguage {
        all.first { $0.code == code } ?? all[0]
    }
}

/// Быстрый перевод фразы через Claude Haiku 5.5 со стримингом.
struct TranslationService: Sendable {
    let client = ClaudeClient()

    func translate(
        _ text: String,
        from source: TranslatorLanguage,
        to target: TranslatorLanguage,
        apiKey: String,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let system = """
        Ты синхронный переводчик живой речи. Переведи реплику с языка «\(source.russianName)» на язык «\(target.russianName)». \
        Если реплика уже на языке «\(target.russianName)», переведи её на «\(source.russianName)». \
        Выведи только перевод — без кавычек, пояснений и вариантов. Сохраняй смысл, тон и вежливость, имена и числа. \
        Пиши так, как говорят вслух. Реплика получена распознаванием речи и может содержать ошибки — переводи по смыслу.
        """
        let body: JSONValue = [
            "model": "claude-haiku-5-5",
            "max_tokens": 1_024,
            "stream": true,
            "system": [["type": "text", "text": .string(system)]],
            "messages": [["role": "user", "content": [["type": "text", "text": .string(text)]]]],
            "thinking": ["type": "disabled"],
            "output_config": ["effort": "low"],
        ]
        let response = try await client.streamMessage(body: body, apiKey: apiKey) { delta in
            if case .textDelta(let piece) = delta { await onDelta(piece) }
        }
        if response.stopReason == "refusal" { throw TranslationError.refused }
        return response.content
            .filter { $0.blockType == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranslationError: LocalizedError {
    case refused
    case noKey

    var errorDescription: String? {
        switch self {
        case .refused: return "Эту фразу перевести не получилось."
        case .noKey: return "Для перевода нужен API-ключ Anthropic (Настройки → Claude)."
        }
    }
}

/// Живой перевод разговора: вы и собеседник говорите по очереди, или субтитры чужой речи.
@MainActor
@Observable
final class TranslatorController {
    enum Mode: String, CaseIterable, Identifiable {
        case dialog, subtitles
        var id: String { rawValue }
        var title: String { self == .dialog ? "Диалог" : "Субтитры" }
    }

    enum Side { case me, them }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var original: String
        var translation: String
        let fromMe: Bool
        let sourceName: String
        let targetName: String
        var isFinished = false
    }

    var mode: Mode = .dialog {
        didSet { if mode != oldValue { stop() } }
    }
    private(set) var entries: [Entry] = []
    private(set) var activeSide: Side?
    private(set) var isTranslating = false
    var errorMessage: String?

    let settings: AppSettings
    let assistant: AssistantController
    @ObservationIgnored private let service = TranslationService()
    @ObservationIgnored private var sessionID = UUID()

    init(settings: AppSettings, assistant: AssistantController) {
        self.settings = settings
        self.assistant = assistant
    }

    var mine: TranslatorLanguage {
        get { TranslatorLanguage.find(settings.translatorMine) }
        set { settings.translatorMine = newValue.code }
    }

    var theirs: TranslatorLanguage {
        get { TranslatorLanguage.find(settings.translatorTheirs) }
        set { settings.translatorTheirs = newValue.code }
    }

    func swapLanguages() {
        stop()
        let previous = settings.translatorMine
        settings.translatorMine = settings.translatorTheirs
        settings.translatorTheirs = previous
    }

    /// Последний перевод — его показывают собеседнику крупно.
    var latestTranslation: Entry? { entries.last { !$0.translation.isEmpty } }

    func clear() {
        stop()
        entries.removeAll()
    }

    /// Кнопка «я говорю» / «собеседник говорит»; в субтитрах — старт и стоп.
    func toggle(_ side: Side) async {
        if activeSide == side {
            stop()
            return
        }
        stop()
        guard !settings.trimmedAPIKey.isEmpty else {
            errorMessage = TranslationError.noKey.localizedDescription
            return
        }
        let language = side == .me ? mine : theirs
        let session = UUID()
        sessionID = session
        activeSide = side
        let started = await assistant.beginTranslationCapture(
            language: language.code,
            continuous: mode == .subtitles,
            onText: { [weak self] text in
                Task { await self?.handle(text, side: side, session: session) }
            },
            onIdle: { [weak self] in
                guard let self, self.sessionID == session else { return }
                self.activeSide = nil
                self.assistant.endTranslationCapture()
            }
        )
        if !started, sessionID == session {
            activeSide = nil
            if let error = assistant.errorMessage {
                errorMessage = error
                assistant.dismissError()
            }
        }
    }

    func stop() {
        sessionID = UUID()
        activeSide = nil
        isTranslating = false
        assistant.endTranslationCapture()
    }

    private func handle(_ text: String, side: Side, session: UUID) async {
        guard sessionID == session else { return }
        let source = side == .me ? mine : theirs
        let target = side == .me ? theirs : mine
        entries.append(Entry(original: text, translation: "", fromMe: side == .me, sourceName: source.name, targetName: target.name))
        let entryID = entries[entries.count - 1].id
        isTranslating = true

        do {
            let translation = try await service.translate(
                text, from: source, to: target, apiKey: settings.trimmedAPIKey
            ) { [weak self] piece in
                await self?.append(piece, to: entryID)
            }
            guard sessionID == session else { return }
            update(entryID) {
                $0.translation = translation
                $0.isFinished = true
            }
            isTranslating = false
            if settings.translatorSpeaks, !translation.isEmpty {
                await assistant.speakTranslation(translation, language: target.iso)
            }
        } catch {
            guard sessionID == session else { return }
            isTranslating = false
            update(entryID) { $0.isFinished = true }
            errorMessage = error.localizedDescription
        }

        guard sessionID == session else { return }
        if mode == .subtitles {
            assistant.continueTranslationCapture()
        } else {
            activeSide = nil
            assistant.endTranslationCapture()
        }
    }

    private func append(_ piece: String, to id: UUID) {
        update(id) { $0.translation += piece }
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }
}
