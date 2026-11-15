import AssistantCore
import ClaudeKit
import Foundation
import Observation
import UIKit

/// Запись в ленте диалога на экране.
struct TranscriptEntry: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, tool, info, error }
    enum ToolState: Equatable { case running, done, failed }

    let id = UUID()
    var role: Role
    var text: String
    var image: UIImage?
    /// SF Symbol инструмента.
    var symbol: String?
    var toolName: String?
    var toolState: ToolState = .done
}

/// Связывает микрофон, Claude, инструменты, память и озвучку в голосовой цикл:
/// слушаем → распознаём → Claude (+ камера, календарь, почта…) → озвучиваем → снова слушаем.
@MainActor
@Observable
final class AssistantController {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    private(set) var phase: Phase = .idle
    /// Режим «без рук»: после ответа ассистент снова слушает.
    private(set) var handsFree = false
    private(set) var partialTranscript = ""
    private(set) var entries: [TranscriptEntry] = []
    private(set) var microphone = "—"
    /// Микрофоном сейчас пользуется переводчик.
    private(set) var translatorActive = false
    var errorMessage: String?

    let settings: AppSettings
    let glasses: GlassesManager
    let memory: MemoryStore

    @ObservationIgnored private let audio = AudioSessionManager()
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let speaker = SpeechSpeaker()
    @ObservationIgnored private let conversation = ClaudeConversation(maxToolIterations: 12)
    @ObservationIgnored private let locationProvider = LocationProvider()
    @ObservationIgnored private var chunker = SentenceChunker()
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var currentTurnID: UUID?
    @ObservationIgnored private var currentAssistantEntry: UUID?
    @ObservationIgnored private var audioPermissionsGranted = false
    @ObservationIgnored private var consecutiveRecognizerFailures = 0
    @ObservationIgnored private var lastInteraction = Date.distantPast
    @ObservationIgnored private var consecutiveIdleRestarts = 0
    @ObservationIgnored private var isPreparingAudio = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    /// Язык текущего ответа: по нему озвучиваются фразы без явных признаков языка.
    @ObservationIgnored private var replyLanguage = "ru"

    // Переводчик
    @ObservationIgnored private var translationHandler: ((String) -> Void)?
    @ObservationIgnored private var translationIdleHandler: (() -> Void)?
    @ObservationIgnored private var translationContinuous = false
    @ObservationIgnored private var translationLanguage: String?
    @ObservationIgnored private var handsFreeBeforeTranslation = false

    /// После такой паузы диалог начинается заново (контекст не раздувается бесконечно).
    private let conversationTimeout: TimeInterval = 10 * 60

    init(settings: AppSettings, glasses: GlassesManager, memory: MemoryStore) {
        self.settings = settings
        self.glasses = glasses
        self.memory = memory

        listener.onPartial = { [weak self] text in
            self?.partialTranscript = text
        }
        listener.onUtterance = { [weak self] text in
            self?.handleUtterance(text)
        }
        listener.onIdle = { [weak self] reason in
            self?.handleListenerIdle(reason)
        }

        audio.onInterruptionBegan = { [weak self] in
            self?.suspendForAudioInterruption()
        }
        audio.onInterruptionEnded = { [weak self] in
            self?.resumeAfterAudioInterruption()
        }
        audio.onMediaServicesReset = { [weak self] in
            guard let self else { return }
            // Apple: после сброса медиасервисов аудиообъекты нужно создать заново.
            self.suspendForAudioInterruption()
            self.listener.rebuildEngine()
            self.speaker.rebuildSynthesizer()
            self.resumeAfterAudioInterruption()
        }
        audio.onRouteChanged = { [weak self] in
            guard let self else { return }
            self.microphone = self.audio.inputDescription
        }
        speaker.onVoiceProblem = { [weak self] message in
            self?.entries.append(TranscriptEntry(role: .info, text: message))
        }
    }

    /// Порядок и состав инструментов постоянны: они входят в кэшируемый префикс запроса.
    private var tools: [any ClaudeTool] {
        let mail = settings.mailAccount.map { MailCredentials(account: $0, password: settings.mailPassword) }
        return [
            TakePhotoTool(glasses: glasses),
            NotesTool(store: memory),
            LocationTool(provider: locationProvider),
            NavigateTool(),
            ListEventsTool(),
            CreateEventTool(),
            ReminderTool(),
            TimerTool(),
            FindContactTool(),
            SendMessageTool(),
            ComposeEmailTool(),
            CallTool(),
            CheckMailTool(credentials: mail),
            ReadMailTool(credentials: mail),
            ShortcutTool(),
        ]
    }

    // MARK: - Actions

    /// Большая кнопка: слушать одну фразу, или прервать ответ.
    func mainButtonTapped() async {
        guard !isPreparingAudio else { return }
        switch phase {
        case .thinking, .speaking:
            interrupt()
        case .listening:
            listener.cancelCapture()
            phase = .idle
            handsFree = false
            releaseMicrophoneIfIdle()
        case .idle:
            guard await prepareAudio() else { return }
            startListening()
        }
    }

    func setHandsFree(_ enabled: Bool) async {
        if enabled {
            guard await prepareAudio() else { return }
            handsFree = true
            if phase == .idle { startListening() }
        } else {
            handsFree = false
            if phase == .listening {
                listener.cancelCapture()
                phase = .idle
            }
            releaseMicrophoneIfIdle()
        }
    }

    /// Прерывает текущий ответ (и запрос к Claude, если он ещё идёт).
    func interrupt() {
        turnTask?.cancel()
        turnTask = nil
        currentTurnID = nil
        speaker.stop()
        listener.cancelCapture()
        markRunningToolsFinished()
        phase = .idle
        endBackgroundWork()
        if handsFree {
            startListening()
        } else {
            releasePlaybackAudioNow()
        }
    }

    func newConversation() {
        interrupt()
        entries.removeAll()
        Task { await conversation.reset() }
    }

    /// Вопрос текстом.
    func submitTyped(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if phase == .thinking || phase == .speaking { interrupt() }
        listener.cancelCapture()
        submit(trimmed)
    }

    func dismissError() {
        errorMessage = nil
    }

    /// «Проверить голос» и приветствие после первой настройки.
    func say(_ text: String) async {
        guard phase == .idle, !translatorActive else { return }
        applyVoiceSettings()
        if handsFree || !settings.stereoAnswers {
            guard await prepareAudio(), phase == .idle else { return }
        } else {
            switchToPlaybackIfNeeded()
        }
        phase = .speaking
        speaker.speak(text, language: LanguageGuess.iso(for: text, fallback: settings.language.isoCode))
        await speaker.waitUntilFinished()
        guard phase == .speaking else { return }
        phase = .idle
        if handsFree {
            startListening()
        } else {
            scheduleAudioRelease()
        }
    }

    var greeting: String {
        let persona = settings.persona
        let user = persona.userName.trimmingCharacters(in: .whitespaces)
        switch settings.language {
        case .russian:
            let hello = user.isEmpty ? "Привет!" : "Привет, \(user)!"
            return "\(hello) Я \(persona.displayName). Спроси меня о чём угодно — или скажи «что передо мной»."
        case .uzbek:
            let hello = user.isEmpty ? "Salom!" : "Salom, \(user)!"
            return "\(hello) Men \(persona.displayName). Menga istalgan savolni bering."
        case .english:
            let hello = user.isEmpty ? "Hi!" : "Hi, \(user)!"
            return "\(hello) I'm \(persona.displayName). Ask me anything, or say “what's in front of me”."
        }
    }

    // MARK: - Listening

    private func prepareAudio() async -> Bool {
        guard !isPreparingAudio else { return false }
        isPreparingAudio = true
        defer { isPreparingAudio = false }
        releaseTask?.cancel()

        if !audioPermissionsGranted {
            guard await SpeechListener.requestPermissions() else {
                errorMessage = "Нужен доступ к микрофону (Настройки iOS → Конфиденциальность → Микрофон)."
                return false
            }
            audioPermissionsGranted = true
        }
        // Движок мог остановиться (звонок, Siri, сброс медиасервисов, ответ через A2DP) — проверяем каждый раз.
        if !listener.isEngineRunning {
            do {
                try audio.activate()
            } catch {
                errorMessage = "Не удалось включить микрофон: \(error.localizedDescription)"
                return false
            }
            await audio.waitForGlassesInput()
            // Пока ждали гарнитуру, могли задать вопрос текстом — тогда аудио уже в режиме ответа.
            guard audio.mode == .conversation else { return false }
            do {
                try listener.startEngine()
            } catch {
                errorMessage = "Не удалось включить микрофон: \(error.localizedDescription)"
                return false
            }
        }
        audio.preferGlassesInput()
        microphone = audio.inputDescription
        applyListeningLanguage()
        applyVoiceSettings()
        return true
    }

    private func applyListeningLanguage() {
        listener.setLanguage(translationLanguage ?? settings.language.rawValue)
        let key = settings.trimmedElevenLabsKey
        if key.isEmpty {
            listener.cloudTranscriber = nil
        } else {
            listener.cloudTranscriber = { @Sendable audio, language in
                try await ElevenLabsClient().transcribe(pcm16kHz: audio, languageCode: language, apiKey: key)
            }
        }
    }

    private func applyVoiceSettings() {
        speaker.languageCode = settings.language.rawValue
        speaker.elevenLabs = settings.elevenLabsConfiguration
    }

    private func startListening() {
        guard phase == .idle || phase == .listening else { return }
        do {
            try listener.beginCapture()
            partialTranscript = ""
            phase = .listening
        } catch {
            phase = .idle
            if translatorActive { translationIdleHandler?() }
            errorMessage = error.localizedDescription
        }
    }

    private func handleUtterance(_ text: String) {
        partialTranscript = ""
        consecutiveIdleRestarts = 0
        consecutiveRecognizerFailures = 0

        if let handler = translationHandler {
            phase = .idle
            handler(text)
            return
        }

        var query = text
        if handsFree && settings.wakeWordEnabled {
            guard let stripped = WakeWord.strip(settings.effectiveWakeWord, from: text) else {
                // Фраза не к ассистенту — продолжаем слушать.
                phase = .idle
                startListening()
                return
            }
            query = stripped
        }

        guard !query.isEmpty else {
            phase = .idle
            speaker.speak(settings.language.acknowledgement, language: settings.language.isoCode)
            Task {
                await speaker.waitUntilFinished()
                if handsFree, phase == .idle { startListening() }
            }
            return
        }
        submit(query)
    }

    private func handleListenerIdle(_ reason: ListenerIdleReason) {
        guard phase == .listening else { return }
        phase = .idle

        // Распознаватель падает сразу после старта (выключена диктовка, нет языковых данных и т. п.) —
        // это не тишина: после нескольких попыток останавливаемся и показываем ошибку.
        if reason.isQuickFailure {
            consecutiveRecognizerFailures += 1
            if consecutiveRecognizerFailures >= 5 {
                consecutiveRecognizerFailures = 0
                handsFree = false
                translationContinuous = false
                errorMessage = "Распознавание речи не работает: \(reason.error ?? "неизвестная ошибка"). Проверьте, что диктовка включена (Настройки → Основные → Клавиатура)."
                if translatorActive { translationIdleHandler?() }
                releaseMicrophoneIfIdle()
                return
            }
        } else {
            consecutiveRecognizerFailures = 0
        }

        let keepListening = translatorActive ? translationContinuous : handsFree
        guard keepListening else {
            if translatorActive { translationIdleHandler?() }
            releaseMicrophoneIfIdle()
            return
        }
        // Тишина: перезапускаем; при частых сбоях — с паузой.
        consecutiveIdleRestarts += 1
        let delay: UInt64 = consecutiveIdleRestarts > 3 ? 2_000_000_000 : 300_000_000
        Task {
            try? await Task.sleep(nanoseconds: delay)
            let stillWanted = translatorActive ? translationContinuous : handsFree
            guard stillWanted, phase == .idle else { return }
            // Движок мог упасть при смене маршрута — поднимаем его заново, а не просто стартуем распознавание.
            guard await prepareAudio() else { return }
            if phase == .idle { startListening() }
        }
    }

    /// Звонок или Siri забрали аудио: прекращаем ответ и прослушивание, режим «без рук» сохраняем.
    private func suspendForAudioInterruption() {
        turnTask?.cancel()
        currentTurnID = nil
        speaker.stop()
        listener.cancelCapture()
        markRunningToolsFinished()
        phase = .idle
        endBackgroundWork()
    }

    private func resumeAfterAudioInterruption() {
        guard handsFree || (translatorActive && translationContinuous) else { return }
        Task {
            guard await prepareAudio() else { return }
            if phase == .idle { startListening() }
        }
    }

    // MARK: - Аудио в режиме кнопки

    /// Режим кнопки: пока Claude думает и отвечает, микрофон не нужен. Переводим очки из гарнитуры (HFP)
    /// в A2DP — ответ звучит в стерео и полном качестве. Заодно освобождается полоса Bluetooth для камеры.
    private func switchToPlaybackIfNeeded() {
        // Без проверки текущего режима: после звонка или сброса медиасервисов сессию нужно поднять заново.
        guard settings.stereoAnswers, !handsFree, !translatorActive else { return }
        releaseTask?.cancel()
        // Новый движок к следующему вопросу: старый мог запомнить формат входа до смены режима.
        listener.rebuildEngine()
        do {
            try audio.activatePlayback()
        } catch {
            NSLog("[RayBanClaude] A2DP недоступен, отвечаю через гарнитуру: \(error)")
        }
    }

    /// Отпускает аудио после ответа, когда договорил последний звук (задержка Bluetooth + запас).
    private func scheduleAudioRelease() {
        releaseTask?.cancel()
        let delay = audio.outputLatency + 0.3
        releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.releasePlaybackAudioNow()
        }
    }

    /// Снова заиграет музыка, если она была.
    private func releasePlaybackAudioNow() {
        guard !handsFree, !translatorActive, phase == .idle, !speaker.isSpeaking, audio.mode == .playback else { return }
        audio.deactivate()
    }

    /// Вопрос в режиме кнопки так и не прозвучал: выключаем микрофон и гарнитурный режим очков.
    private func releaseMicrophoneIfIdle() {
        guard settings.stereoAnswers, !handsFree, !translatorActive, phase == .idle, !isPreparingAudio else { return }
        listener.rebuildEngine()
        audio.deactivate()
    }

    /// iOS держит фоновое приложение живым, пока оно играет или пишет звук. Пока Claude думает,
    /// звука нет — без фоновой задачи телефон с выключенным экраном усыпил бы приложение посреди ответа.
    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "assistant-turn") { [weak self] in
            Task { @MainActor in self?.endBackgroundWork() }
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Turn

    private func submit(_ text: String) {
        guard !settings.trimmedAPIKey.isEmpty else {
            errorMessage = "Добавьте API-ключ Anthropic в настройках."
            phase = .idle
            return
        }
        entries.append(TranscriptEntry(role: .user, text: text))
        replyLanguage = LanguageGuess.iso(for: text, fallback: settings.language.isoCode)
        applyVoiceSettings()
        switchToPlaybackIfNeeded()
        beginBackgroundWork()
        phase = .thinking
        turnTask?.cancel()
        let turnID = UUID()
        currentTurnID = turnID
        turnTask = Task { await runTurn(text, turnID: turnID) }
    }

    private func runTurn(_ text: String, turnID: UUID) async {
        defer { if currentTurnID == turnID || currentTurnID == nil { endBackgroundWork() } }
        if Date().timeIntervalSince(lastInteraction) > conversationTimeout {
            await conversation.reset()
        }
        lastInteraction = Date()
        chunker = SentenceChunker()
        currentAssistantEntry = nil

        // Память — в первой реплике диалога: так она кэшируется вместе с диалогом и не тратит
        // отдельный запрос на просмотр заметок.
        var message = contextLine()
        if await conversation.isEmpty {
            message = "[память:\n\(memory.conversationContext())\n]\n" + message
        }
        message += "\n" + text

        let configuration = ClaudeConfiguration(
            apiKey: settings.trimmedAPIKey,
            model: settings.model.rawValue,
            systemPrompt: SystemPrompt.make(persona: settings.persona, language: settings.language),
            maxTokens: 8_000,
            webSearch: settings.webSearchEnabled,
            contextEditing: settings.saveTokens,
            contextEditingExcludedTools: ["notes"]
        )

        do {
            let outcome = try await conversation.send(
                userText: message,
                configuration: configuration,
                tools: tools
            ) { [weak self] event in
                await self?.handle(event, turnID: turnID)
            }
            guard !Task.isCancelled else { return }
            if let rest = chunker.flush() { say(sentence: rest) }

            switch outcome {
            case .completed:
                break
            case .refused(let category):
                speaker.stop()
                let message = settings.language.refusalMessage
                entries.append(TranscriptEntry(role: .info, text: message + (category.map { " (\($0))" } ?? "")))
                say(sentence: message)
            case .truncated:
                entries.append(TranscriptEntry(role: .info, text: "Ответ обрезан по лимиту длины."))
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if (error as? URLError)?.code == .cancelled { return }
            markRunningToolsFinished(failed: true)
            entries.append(TranscriptEntry(role: .error, text: error.localizedDescription))
            say(sentence: settings.language.failureMessage)
        }

        if speaker.isSpeaking {
            phase = .speaking
            await speaker.waitUntilFinished()
        }
        guard !Task.isCancelled, currentTurnID == turnID else { return }
        lastInteraction = Date()
        phase = .idle
        if handsFree {
            try? await Task.sleep(nanoseconds: 300_000_000) // хвост звука не должен попасть в микрофон
            if handsFree, phase == .idle { startListening() }
        } else {
            scheduleAudioRelease()
        }
    }

    private func handle(_ event: AgentEvent, turnID: UUID) {
        // События прерванного хода (догоняющие дельты стрима) игнорируем.
        guard turnID == currentTurnID else { return }
        switch event {
        case .textDelta(let delta):
            appendAssistantText(delta)
            for sentence in chunker.append(delta) { say(sentence: sentence) }

        case .toolStarted(let name, let input):
            closeAssistantEntry()
            let presentation = ToolPresentation.make(name: name, input: input)
            entries.append(TranscriptEntry(
                role: .tool, text: presentation.title, symbol: presentation.symbol, toolName: name, toolState: .running
            ))

        case .toolFinished(let name, let output):
            let image = output.content.lazy.compactMap { item -> UIImage? in
                if case .jpeg(let data) = item { return UIImage(data: data) }
                return nil
            }.first
            if let index = entries.lastIndex(where: { $0.role == .tool && $0.toolName == name && $0.toolState == .running }) {
                entries[index].image = image
                entries[index].toolState = output.isError ? .failed : .done
            }

        case .serverToolStarted(let name):
            closeAssistantEntry()
            let presentation = ToolPresentation.make(name: name, input: nil)
            entries.append(TranscriptEntry(role: .tool, text: presentation.title, symbol: presentation.symbol, toolName: name, toolState: .done))

        case .fallback(_, let to):
            entries.append(TranscriptEntry(role: .info, text: "Ответ продолжила модель \(to ?? "fallback")."))
        }
    }

    private func say(sentence: String) {
        let language = LanguageGuess.iso(for: sentence, fallback: replyLanguage)
        replyLanguage = language
        speaker.speak(sentence, language: language)
        if phase == .thinking { phase = .speaking }
    }

    private func appendAssistantText(_ delta: String) {
        if let id = currentAssistantEntry, let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].text += delta
        } else {
            let entry = TranscriptEntry(role: .assistant, text: delta.trimmingCharacters(in: .whitespacesAndNewlines))
            entries.append(entry)
            currentAssistantEntry = entry.id
        }
    }

    /// Текст после вызова инструмента пойдёт в новую запись — чтобы лента шла по порядку.
    private func closeAssistantEntry() {
        currentAssistantEntry = nil
        if let rest = chunker.flush() { say(sentence: rest) }
    }

    private func markRunningToolsFinished(failed: Bool = false) {
        for index in entries.indices where entries[index].toolState == .running {
            entries[index].toolState = failed ? .failed : .done
        }
    }

    /// Служебная строка контекста в начале реплики. Не в системном промпте — чтобы не ломать кэш.
    private func contextLine() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        var parts = ["\(formatter.string(from: now)) (\(TimeZone.current.identifier))"]
        parts.append(glasses.isRegistered ? (glasses.hasActiveDevice ? "очки подключены" : "очки не на связи") : "очки не зарегистрированы")
        if let battery = glasses.batteryLevel { parts.append("заряд очков \(battery)%") }
        parts.append("микрофон: \(microphone)")
        parts.append(settings.mailAccount == nil ? "почта не подключена" : "почта подключена")
        return "[контекст: \(parts.joined(separator: "; "))]"
    }

    // MARK: - Переводчик

    /// Переводчик забирает микрофон: ассистент замолкает и слушает речь на языке `language` (BCP-47).
    /// `continuous` — слушать фразу за фразой (субтитры), иначе одну фразу.
    func beginTranslationCapture(
        language: String,
        continuous: Bool,
        onText: @escaping (String) -> Void,
        onIdle: @escaping () -> Void
    ) async -> Bool {
        if phase == .thinking || phase == .speaking { interrupt() }
        if !translatorActive { handsFreeBeforeTranslation = handsFree }
        handsFree = false
        listener.cancelCapture()
        speaker.stop()
        phase = .idle
        translatorActive = true
        translationHandler = onText
        translationIdleHandler = onIdle
        translationContinuous = continuous
        translationLanguage = language
        guard await prepareAudio(), translatorActive else {
            endTranslationCapture()
            return false
        }
        startListening()
        return phase == .listening
    }

    /// Снова слушать в режиме субтитров (после озвучки перевода).
    func continueTranslationCapture() {
        guard translatorActive, translationContinuous, phase == .idle else { return }
        startListening()
    }

    func endTranslationCapture() {
        guard translatorActive else { return }
        translationHandler = nil
        translationIdleHandler = nil
        translationContinuous = false
        translationLanguage = nil
        listener.cancelCapture()
        speaker.stop()
        translatorActive = false
        phase = .idle
        partialTranscript = ""
        applyListeningLanguage()
        handsFree = handsFreeBeforeTranslation
        if handsFree {
            Task {
                guard await prepareAudio() else { return }
                if phase == .idle { startListening() }
            }
        } else {
            releaseMicrophoneIfIdle()
        }
    }

    /// Озвучивает перевод (ISO 639-1 языка) и ждёт конца.
    func speakTranslation(_ text: String, language: String) async {
        speaker.elevenLabs = settings.elevenLabsConfiguration
        speaker.speak(text, language: language)
        await speaker.waitUntilFinished()
    }

    var isTranslationListening: Bool { translatorActive && phase == .listening }
}

/// Как показать вызов инструмента в ленте: подпись и SF Symbol.
enum ToolPresentation {
    static func make(name: String, input: JSONValue?) -> (title: String, symbol: String) {
        switch name {
        case "take_photo": return ("Смотрю через очки", "camera.viewfinder")
        case "notes": return (input.map(NotesTool.activityTitle(for:)) ?? "Память", "books.vertical")
        case "get_location": return ("Определяю, где мы", "location")
        case "navigate": return ("Строю маршрут", "map")
        case "list_events": return ("Смотрю календарь", "calendar")
        case "create_event": return ("Добавляю в календарь", "calendar.badge.plus")
        case "create_reminder": return ("Создаю напоминание", "checklist")
        case "set_timer": return ("Ставлю таймер", "timer")
        case "find_contact": return ("Ищу в контактах", "person.crop.circle")
        case "send_message": return ("Готовлю сообщение", "message")
        case "compose_email": return ("Готовлю письмо", "square.and.pencil")
        case "call": return ("Звоню", "phone")
        case "check_mail": return ("Проверяю почту", "tray")
        case "read_mail": return ("Читаю письмо", "envelope.open")
        case "run_shortcut": return ("Запускаю команду", "square.stack.3d.up")
        case "web_search": return ("Ищу в интернете", "magnifyingglass")
        case "web_fetch": return ("Открываю страницу", "doc.text.magnifyingglass")
        default: return (name, "wrench.and.screwdriver")
        }
    }
}

/// Обращение к ассистенту в режиме «без рук»: «Джарвис, что это?» → «что это?».
enum WakeWord {
    /// Варианты, в которые распознаватель часто превращает популярные имена.
    private static let variants: [String: [String]] = [
        "клод": ["клод", "клауд", "клот", "claude", "клоуд", "cloud"],
        "claude": ["claude", "cloud", "clod", "клод"],
        "джарвис": ["джарвис", "джарвиз", "жарвис", "jarvis", "чарвис"],
        "jarvis": ["jarvis", "джарвис", "jarvi"],
    ]

    /// Возвращает запрос без обращения или `nil`, если обращения в первых словах нет.
    static func strip(_ wakeWord: String, from text: String) -> String? {
        let key = wakeWord.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return text }
        let accepted = Set((variants[key] ?? []) + [key, transliterate(key)])

        let words = text.split(whereSeparator: \.isWhitespace)
        for (position, word) in words.prefix(3).enumerated() {
            let normalized = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if accepted.contains(normalized) || isClose(normalized, to: accepted) {
                return words.dropFirst(position + 1).joined(separator: " ")
                    .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            }
        }
        return nil
    }

    /// Распознаватель часто ошибается на одну букву в именах: «Пятница» → «Пятниц».
    private static func isClose(_ word: String, to accepted: Set<String>) -> Bool {
        guard word.count >= 4 else { return false }
        return accepted.contains { candidate in
            candidate.count >= 4 && abs(candidate.count - word.count) <= 1 && distance(word, candidate) <= 1
        }
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func transliterate(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        return latin.applyingTransform(.stripDiacritics, reverse: false)?.lowercased() ?? latin.lowercased()
    }
}
