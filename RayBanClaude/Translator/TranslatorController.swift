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

    /// Распознавание называет язык по ISO 639-1 («uz») или 639-3 («uzb») — понимаем оба.
    func matches(_ detected: String?) -> Bool {
        guard let detected = detected?.lowercased(), !detected.isEmpty else { return false }
        return detected == iso || detected.hasPrefix(iso + "-") || Self.iso3[iso]?.contains(detected) == true
    }

    private static let iso3: [String: Set<String>] = [
        "ru": ["rus"], "uz": ["uzb", "uzn"], "en": ["eng"], "tr": ["tur"], "kk": ["kaz"], "ky": ["kir"],
        "tg": ["tgk"], "zh": ["zho", "cmn", "chi"], "ko": ["kor"], "ja": ["jpn"], "ar": ["ara", "arb"],
        "hi": ["hin"], "de": ["deu", "ger"], "fr": ["fra", "fre"], "es": ["spa"], "it": ["ita"], "uk": ["ukr"],
    ]

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

/// Живой перевод разговора.
///
/// **Разговор** — оба говорят свободно: распознавание идёт потоком и само определяет, на каком из двух
/// языков сказана фраза, перевод появляется, пока человек ещё говорит (черновик), и уточняется в конце.
/// **По очереди** — две кнопки, язык задаёт кнопка: надёжнее в шуме и без ключа ElevenLabs.
@MainActor
@Observable
final class TranslatorController {
    enum Mode: String, CaseIterable, Identifiable {
        case conversation, dialog
        var id: String { rawValue }
        var title: String { self == .conversation ? "Разговор" : "По очереди" }
    }

    enum Side { case me, them }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var original: String
        var translation: String
        var fromMe: Bool
        var sourceName: String
        var targetName: String
        var isFinished = false
    }

    var mode: Mode = .conversation {
        didSet { if mode != oldValue { stop() } }
    }
    private(set) var entries: [Entry] = []
    /// Кнопка, которая сейчас слушает (режим «По очереди»).
    private(set) var activeSide: Side?
    /// Разговор идёт: переводчик слушает обоих.
    private(set) var isRunning = false
    private(set) var isTranslating = false
    /// Фраза, которая звучит прямо сейчас: текст и черновой перевод.
    private(set) var live: Entry?
    var errorMessage: String?

    let settings: AppSettings
    let assistant: AssistantController
    @ObservationIgnored private let service = TranslationService()
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var draftSource = ""
    @ObservationIgnored private var lastDraftAt = Date.distantPast
    @ObservationIgnored private var chunkers: [UUID: SentenceChunker] = [:]
    @ObservationIgnored private var spokenEntries: Set<UUID> = []

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

    /// Свободный разговор требует потокового распознавания: только оно определяет язык фразы.
    var conversationDetectsLanguage: Bool { settings.usesLiveRecognition }

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

    #if DEBUG
    func loadDemo(live: Entry? = nil, running: Bool = false, entries: [Entry]) {
        self.entries = entries
        self.live = live
        isRunning = running
    }
    #endif

    // MARK: - Разговор

    /// Старт и стоп свободного разговора.
    func toggleConversation() async {
        if isRunning {
            pause()
            return
        }
        guard !settings.trimmedAPIKey.isEmpty else {
            errorMessage = TranslationError.noKey.localizedDescription
            return
        }
        let session = UUID()
        sessionID = session
        isRunning = true
        let started = await assistant.beginTranslationCapture(
            // Чужую речь расслышать труднее — она основной язык, свой — запасной.
            language: theirs.code,
            others: conversationDetectsLanguage ? [mine.code] : [],
            continuous: true,
            onPartial: { [weak self] text, language in
                self?.handlePartial(text, language: language, session: session)
            },
            onText: { [weak self] text, language in
                guard let self else { return }
                let side = self.side(for: text, detected: language)
                Task { await self.handle(text, side: side, session: session, continuous: true) }
            },
            onIdle: { [weak self] in
                guard let self, self.sessionID == session else { return }
                self.isRunning = false
                self.live = nil
            }
        )
        if !started, sessionID == session {
            isRunning = false
            surfaceAssistantError()
        }
    }

    /// Чья это фраза. Без потокового распознавания разговор слушает только собеседника.
    private func side(for text: String, detected: String?) -> Side {
        guard conversationDetectsLanguage else { return .them }
        if mine.matches(detected) { return .me }
        if theirs.matches(detected) { return .them }
        // Распознавание язык не назвало — смотрим на сам текст.
        let guess = LanguageGuess.iso(for: text, fallback: theirs.iso)
        return guess == mine.iso && mine.iso != theirs.iso ? .me : .them
    }

    private func handlePartial(_ text: String, language: String?, session: UUID) {
        guard sessionID == session, isRunning, !text.isEmpty else { return }
        let side = side(for: text, detected: language)
        let source = side == .me ? mine : theirs
        let target = side == .me ? theirs : mine
        if var current = live {
            current.original = text
            if current.fromMe != (side == .me) {
                // Язык определился иначе — черновик был не в ту сторону.
                current.fromMe = side == .me
                current.sourceName = source.name
                current.targetName = target.name
                current.translation = ""
                draftSource = ""
            }
            live = current
        } else {
            live = Entry(original: text, translation: "", fromMe: side == .me, sourceName: source.name, targetName: target.name)
            draftSource = ""
        }
        requestDraft(text, from: source, to: target, session: session)
    }

    /// Черновой перевод звучащей фразы: только на экран, не чаще раза в секунду.
    private func requestDraft(_ text: String, from source: TranslatorLanguage, to target: TranslatorLanguage, session: UUID) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words >= 3, draftTask == nil, text != draftSource, Date().timeIntervalSince(lastDraftAt) > 1.0 else { return }
        draftSource = text
        lastDraftAt = Date()
        let key = settings.trimmedAPIKey
        draftTask = Task { [weak self, service] in
            let draft = try? await service.translate(text, from: source, to: target, apiKey: key) { _ in }
            guard let self else { return }
            self.draftTask = nil
            guard self.sessionID == session, let draft, !draft.isEmpty,
                  var current = self.live, current.original.hasPrefix(String(text.prefix(12)))
            else { return }
            current.translation = draft
            self.live = current
        }
    }

    // MARK: - По очереди

    /// Кнопка «я говорю» / «собеседник говорит».
    func toggle(_ side: Side) async {
        if activeSide == side {
            pause()
            return
        }
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
            continuous: false,
            onText: { [weak self] text, _ in
                Task { await self?.handle(text, side: side, session: session, continuous: false) }
            },
            onIdle: { [weak self] in
                guard let self, self.sessionID == session else { return }
                self.activeSide = nil
            }
        )
        if !started, sessionID == session {
            activeSide = nil
            surfaceAssistantError()
        }
    }

    // MARK: - Общее

    /// Перестать слушать; микрофон остаётся у переводчика до ухода с вкладки.
    private func pause() {
        sessionID = UUID()
        activeSide = nil
        isRunning = false
        isTranslating = false
        live = nil
        draftTask?.cancel()
        draftTask = nil
        assistant.pauseTranslationCapture()
    }

    /// Полностью отдать микрофон ассистенту: уход с вкладки, смена режима или языков.
    func stop() {
        sessionID = UUID()
        activeSide = nil
        isRunning = false
        isTranslating = false
        live = nil
        draftTask?.cancel()
        draftTask = nil
        assistant.endTranslationCapture()
    }

    private func surfaceAssistantError() {
        if let error = assistant.errorMessage {
            errorMessage = error
            assistant.dismissError()
        }
    }

    private func handle(_ text: String, side: Side, session: UUID, continuous: Bool) async {
        guard sessionID == session else { return }
        let source = side == .me ? mine : theirs
        let target = side == .me ? theirs : mine
        let speaks = settings.translatorSpeaks
        live = nil
        draftSource = ""
        entries.append(Entry(original: text, translation: "", fromMe: side == .me, sourceName: source.name, targetName: target.name))
        let entryID = entries[entries.count - 1].id
        isTranslating = true
        // Без озвучки слушаем дальше сразу: следующая фраза переводится, пока эта ещё пишется.
        if continuous, !speaks { assistant.continueTranslationCapture() }

        chunkers[entryID] = SentenceChunker()
        defer {
            chunkers[entryID] = nil
            spokenEntries.remove(entryID)
        }
        do {
            let translation = try await service.translate(
                text, from: source, to: target, apiKey: settings.trimmedAPIKey
            ) { [weak self] piece in
                await self?.receive(piece, entry: entryID, side: side, language: target.iso, session: session, speaks: speaks)
            }
            guard sessionID == session else { return }
            update(entryID) {
                $0.translation = translation
                $0.isFinished = true
            }
            if speaks, let rest = chunkers[entryID]?.flush() {
                speak(rest, entry: entryID, to: side, language: target.iso, session: session)
            }
            isTranslating = false
            if spokenEntries.contains(entryID) { await assistant.finishTranslationSpeech() }
        } catch {
            guard sessionID == session else { return }
            isTranslating = false
            update(entryID) { $0.isFinished = true }
            errorMessage = error.localizedDescription
        }

        guard sessionID == session else { return }
        if continuous {
            if speaks { assistant.continueTranslationCapture() }
        } else {
            activeSide = nil
        }
    }

    /// Очередной кусок перевода: в ленту, а законченные фразы — сразу в озвучку.
    private func receive(_ piece: String, entry: UUID, side: Side, language: String, session: UUID, speaks: Bool) {
        append(piece, to: entry)
        guard speaks, sessionID == session, var chunker = chunkers[entry] else { return }
        let sentences = chunker.append(piece)
        chunkers[entry] = chunker
        for sentence in sentences { speak(sentence, entry: entry, to: side, language: language, session: session) }
    }

    /// Первая фраза перевода: распознавание замолкает, чтобы не услышать собственный голос.
    private func speak(_ sentence: String, entry: UUID, to side: Side, language: String, session: UUID) {
        guard sessionID == session else { return }
        spokenEntries.insert(entry)
        assistant.pauseListeningForSpeech()
        // Перевод моих слов нужен собеседнику, перевод его слов — мне в очки.
        assistant.speakTranslationPiece(sentence, language: language, forPartner: side == .me)
    }

    private func append(_ piece: String, to id: UUID) {
        update(id) { $0.translation += piece }
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }
}
