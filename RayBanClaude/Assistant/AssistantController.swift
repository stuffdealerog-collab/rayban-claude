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
    /// Когда реплика появилась — для подписи на линии.
    var date = Date()
    var role: Role
    var text: String
    var image: UIImage?
    /// SF Symbol инструмента.
    var symbol: String?
    var toolName: String?
    var toolState: ToolState = .done
    /// Сколько шёл шаг ассистента, секунд.
    var duration: TimeInterval?
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
    /// «На связи»: разговор идёт как звонок, микрофон работает и с заблокированным экраном.
    private(set) var callState: CallSession.State = .idle
    var errorMessage: String?

    var onCall: Bool { callState != .idle }

    let settings: AppSettings
    let glasses: GlassesManager
    let memory: MemoryStore

    @ObservationIgnored private let audio = AudioSessionManager()
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let speaker = SpeechSpeaker()
    @ObservationIgnored private let call = CallSession()
    @ObservationIgnored private let addresseeGate = AddresseeGate()
    @ObservationIgnored private var voiceLookup: Task<Void, Never>?
    /// Что ассистент скажет, как только звонок соединится.
    @ObservationIgnored private var callGreeting: String?
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
    /// «Новый разговор» нажали — история Claude очистится перед следующим ходом (в той же очереди ходов).
    @ObservationIgnored private var resetPending = false
    /// После «Джарвис» без вопроса и ответа «Да?» следующая фраза — вопрос, даже без обращения.
    @ObservationIgnored private var wakeArmedUntil = Date.distantPast
    /// В этом ходе ассистент уже что-то произнёс.
    @ObservationIgnored private var spokeThisTurn = false
    @ObservationIgnored private var turnStarted = Date()
    /// Переводчик: языки, на которые собеседники могут перейти (BCP-47) — для определения языка фразы.
    @ObservationIgnored private var translationOtherLanguages: [String] = []

    // Переводчик
    @ObservationIgnored private var translationHandler: ((String, String?) -> Void)?
    @ObservationIgnored private var translationPartialHandler: ((String, String?) -> Void)?
    @ObservationIgnored private var translationIdleHandler: (() -> Void)?
    @ObservationIgnored private var translationContinuous = false
    @ObservationIgnored private var translationLanguage: String?
    @ObservationIgnored private var handsFreeBeforeTranslation = false
    /// Перевод сейчас звучит из динамика телефона (для собеседника).
    @ObservationIgnored private var partnerSpeakerOn = false

    /// После такой паузы диалог начинается заново (контекст не раздувается бесконечно).
    private let conversationTimeout: TimeInterval = 10 * 60

    /// Для команд Siri и кнопки «Действие» (App Intents создаются системой, без доступа к окружению SwiftUI).
    static weak var shared: AssistantController?

    init(settings: AppSettings, glasses: GlassesManager, memory: MemoryStore) {
        self.settings = settings
        self.glasses = glasses
        self.memory = memory
        Self.shared = self

        listener.onPartial = { [weak self] text in
            guard let self else { return }
            self.partialTranscript = text
            self.translationPartialHandler?(text, self.listener.lastLanguage)
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
        call.onStateChanged = { [weak self] state in
            self?.callStateChanged(state)
        }
        call.onAudioActivated = { [weak self] in
            self?.callAudioActivated()
        }
        call.onAudioDeactivated = { [weak self] in
            self?.callAudioDeactivated()
        }
        call.onResumed = { [weak self] in
            self?.recoverCallAudio()
        }
        glasses.onGesture = { [weak self] gesture in
            self?.glassesGesture(gesture)
        }
        if settings.glassesGestures {
            Task { await glasses.setGestures(true) }
        }
    }

    /// Жест на очках (эксперимент): перебить ответ или начать слушать без обращения по имени.
    private func glassesGesture(_ gesture: GlassesGesture) {
        guard settings.glassesGestures, !translatorActive else { return }
        journal("очки", "жест «\(gesture.rawValue)» → фаза \(phase)")
        switch phase {
        case .thinking, .speaking:
            interrupt()
        case .listening:
            break
        case .idle:
            wakeArmedUntil = Date().addingTimeInterval(10)
            if handsFree {
                resumeListening()
            } else if UIApplication.shared.applicationState == .active {
                Task { await mainButtonTapped() }
            } else {
                // В фоне микрофон включить нельзя — ассистент перезванивает в очки.
                Task { await ringUser() }
            }
        }
    }

    /// Включить или выключить жесты очков (настройка «Эксперименты»).
    func applyGlassesGestures() {
        Task { await glasses.setGestures(settings.glassesGestures) }
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
            // Микрофон ещё включается по нажатию кнопки — дождёмся, а не откажем молча.
            for _ in 0..<40 where isPreparingAudio {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard await prepareAudio() else { return }
            handsFree = true
            if phase == .idle { startListening() }
        } else {
            if onCall {
                endCall()
                return
            }
            handsFree = false
            if phase == .listening {
                listener.cancelCapture()
                phase = .idle
            }
            releaseMicrophoneIfIdle()
        }
    }

    // MARK: - На связи (звонок)

    /// Кнопка «На связи»: начать или закончить разговор-звонок. Начать можно только с экрана приложения,
    /// дальше телефон можно заблокировать и убрать в карман.
    func toggleCall() async {
        if onCall {
            endCall()
            return
        }
        guard !translatorActive, !isPreparingAudio else { return }
        guard await ensureAudioPermissions() else { return }
        releaseAudioForCall()
        callGreeting = Self.callGreeting(settings.language)
        do {
            try await call.startOutgoing(name: settings.persona.displayName)
        } catch {
            errorMessage = L("Не удалось выйти на связь: %@", error.localizedDescription)
        }
    }

    /// Ассистент звонит сам: команда Siri, автоматизация «надел очки», напоминание. Работает из фона.
    /// `message` — что он скажет, когда вы ответите.
    func ringUser(message: String? = nil) async {
        if onCall {
            // Уже на связи — просто слушаем следующую фразу без обращения.
            wakeArmedUntil = Date().addingTimeInterval(10)
            if phase == .idle { resumeListening() }
            return
        }
        guard !translatorActive else { return }
        releaseAudioForCall()
        callGreeting = message ?? Self.callGreeting(settings.language)
        do {
            try await call.ring(name: settings.persona.displayName)
        } catch {
            journal("звонок", "позвонить не удалось: \(error.localizedDescription)")
        }
    }

    func endCall() {
        call.end()
    }

    private static func callGreeting(_ language: AssistantLanguage) -> String {
        switch language {
        case .russian: return "На связи."
        case .uzbek: return "Aloqadaman."
        case .english: return "I'm here."
        }
    }

    /// Перед звонком свою аудиосессию нужно отпустить: иначе система не сможет включить звонковую.
    private func releaseAudioForCall() {
        turnTask?.cancel()
        turnTask = nil
        currentTurnID = nil
        speaker.stop()
        markRunningToolsFinished()
        endBackgroundWork()
        handsFree = false
        phase = .idle
        releaseTask?.cancel()
        listener.rebuildEngine()
        audio.deactivate()
    }

    private func callStateChanged(_ state: CallSession.State) {
        let wasOnCall = onCall
        callState = state
        switch state {
        case .idle where wasOnCall:
            turnTask?.cancel()
            turnTask = nil
            currentTurnID = nil
            speaker.stop()
            markRunningToolsFinished()
            endBackgroundWork()
            handsFree = false
            phase = .idle
            callGreeting = nil
            listener.rebuildEngine()
            audio.callAudioDeactivated()
        case .held:
            suspendForAudioInterruption()
        default:
            break
        }
    }

    /// Система включила звук звонка: запускаем микрофон и здороваемся.
    private func callAudioActivated() {
        audio.callAudioActivated()
        Task {
            guard await prepareAudio() else { return }
            handsFree = true
            if let greeting = callGreeting {
                callGreeting = nil
                phase = .speaking
                speaker.speak(greeting, language: LanguageGuess.iso(for: greeting, fallback: settings.language.isoCode))
                await speaker.waitUntilFinished()
                guard phase == .speaking else { return }
                phase = .idle
            }
            // Первая фраза после соединения — вопрос, даже без обращения.
            wakeArmedUntil = Date().addingTimeInterval(10)
            if phase == .idle, onCall { startListening() }
        }
    }

    private func callAudioDeactivated() {
        audio.callAudioDeactivated()
        listener.cancelCapture()
        if phase == .listening { phase = .idle }
    }

    /// Вызов сняли с удержания после обычного звонка. Система не всегда возвращает звук сама:
    /// пробуем включить его, а если нельзя — перезваниваем.
    private func recoverCallAudio() {
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard callState == .connecting else { return }
            if audio.reactivateForCall() {
                journal("звонок", "звук возвращён после удержания")
                call.markActive()
                callAudioActivated()
                return
            }
            journal("звонок", "звук не вернулся — перезваниваю")
            call.end()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let message: String
            switch settings.language {
            case .russian: message = "Я снова на связи."
            case .uzbek: message = "Yana aloqadaman."
            case .english: message = "I'm back."
            }
            await ringUser(message: message)
        }
    }

    /// Фраза, которой заканчивают разговор-звонок.
    private static func isHangUp(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["отбой", "конец связи", "пока", "до связи", "xayr", "aloqa tugadi", "goodbye", "bye", "hang up"]
            .contains(normalized)
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
            resumeListening()
        } else {
            settleAudioWhenIdle(immediately: true)
        }
    }

    /// Команда «Спросить ассистента»: приложение открылось — сразу слушаем.
    func listenFromShortcut() async {
        if translatorActive { return }
        if phase == .thinking || phase == .speaking { interrupt() }
        guard phase == .idle else { return }
        guard await prepareAudio() else { return }
        startListening()
    }

    func newConversation() {
        interrupt()
        entries.removeAll()
        resetPending = true
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

    #if DEBUG
    /// Готовое состояние экрана для снимков (см. DemoMode).
    func loadDemo(entries: [TranscriptEntry], phase: Phase, partial: String = "") {
        self.entries = entries
        self.phase = phase
        partialTranscript = partial
    }
    #endif

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
            resumeListening()
        } else {
            settleAudioWhenIdle()
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

    private func ensureAudioPermissions() async -> Bool {
        if audioPermissionsGranted { return true }
        guard await SpeechListener.requestPermissions() else {
            errorMessage = L("Нужен доступ к микрофону (Настройки iOS → Конфиденциальность → Микрофон).")
            return false
        }
        audioPermissionsGranted = true
        return true
    }

    private func prepareAudio() async -> Bool {
        guard !isPreparingAudio else { return false }
        isPreparingAudio = true
        defer { isPreparingAudio = false }
        releaseTask?.cancel()

        guard await ensureAudioPermissions() else { return false }
        if onCall {
            // Звонок: аудиосессию включает система. Наше дело — только движок микрофона.
            guard audio.mode == .conversation else {
                journal("звук", "звонок без звука (удержание) — микрофон не запускаю")
                return false
            }
        }
        // Движок мог остановиться (звонок, Siri, сброс медиасервисов, ответ через A2DP) — проверяем каждый раз.
        if !listener.isEngineRunning {
            if !onCall {
                do {
                    try audio.activate()
                } catch {
                    journal("звук", "сессия не включилась: \(error.localizedDescription)")
                    errorMessage = L("Не удалось включить микрофон: %@", error.localizedDescription)
                    return false
                }
                await audio.waitForGlassesInput()
                // Пока ждали гарнитуру, могли задать вопрос текстом — тогда аудио уже в режиме ответа.
                guard audio.mode == .conversation else { return false }
            }
            do {
                try listener.startEngine()
            } catch {
                journal("звук", "микрофон не запустился: \(error.localizedDescription)")
                errorMessage = L("Не удалось включить микрофон: %@", error.localizedDescription)
                return false
            }
            journal("звук", "микрофон включён: \(audio.inputDescription)")
        }
        audio.preferGlassesInput()
        microphone = audio.inputDescription
        applyListeningLanguage()
        applyVoiceSettings()
        return true
    }

    private func applyListeningLanguage() {
        let identifier = translationLanguage ?? settings.language.rawValue
        listener.setLanguage(identifier)
        let key = settings.trimmedElevenLabsKey
        if key.isEmpty {
            listener.cloudTranscriber = nil
            listener.liveSession = nil
            listener.prefersCloud = false
            return
        }
        listener.cloudTranscriber = { @Sendable audio, language in
            try await ElevenLabsClient().transcribe(pcm16kHz: audio, languageCode: language, apiKey: key)
        }
        listener.prefersCloud = settings.usesLiveRecognition

        // Поток: основной язык и те, на которые собеседник может перейти.
        let language = String(identifier.prefix(2))
        var configuration: ScribeLiveConfiguration?
        if translatorActive {
            let others = translationOtherLanguages.map { String($0.prefix(2)) }
            configuration = settings.scribeConfiguration(
                language: language, others: others, detectLanguage: !others.isEmpty, silence: 0.5
            )
            // Имена и цифры в переводе важнее смешанной речи: языки заданы явно.
            configuration?.multilingual = false
        } else {
            configuration = settings.scribeConfiguration(language: language)
            if handsFree, settings.wakeWordEnabled {
                configuration?.keyterms = WakeWord.keyterms(for: settings.effectiveWakeWord)
            }
        }
        listener.liveDetectsLanguage = configuration?.detectLanguage ?? false
        listener.liveSession = configuration.map { configuration in
            { handler in ScribeLiveSession(configuration: configuration, handler: handler) }
        }
    }

    private func applyVoiceSettings() {
        speaker.languageCode = settings.language.rawValue
        speaker.elevenLabs = settings.elevenLabsConfiguration
        speaker.streaming = settings.streamingVoiceConfiguration
        selectVoiceIfNeeded()
    }

    /// Ключ ElevenLabs есть, а голос ещё не выбран (так бывает сразу после первой настройки):
    /// берём голос носителя языка ассистента или первый из библиотеки, чтобы он сразу говорил живым голосом.
    @discardableResult
    private func selectVoiceIfNeeded() -> Task<Void, Never>? {
        if let voiceLookup { return voiceLookup }
        let key = settings.trimmedElevenLabsKey
        guard !key.isEmpty, settings.elevenLabsVoiceID.isEmpty else { return nil }
        let task = Task { [weak self] in
            let voices = try? await ElevenLabsClient().voices(apiKey: key)
            guard let self else { return }
            self.voiceLookup = nil
            guard let voices, key == self.settings.trimmedElevenLabsKey, self.settings.elevenLabsVoiceID.isEmpty else { return }
            let native = self.settings.language.isoCode
            guard let voice = voices.first(where: { $0.speaks(native) }) ?? voices.first else { return }
            self.settings.elevenLabsVoiceID = voice.voiceID
            self.settings.elevenLabsVoiceName = voice.name
            journal("голос", "голос выбран автоматически: \(voice.name)")
            self.applyVoiceSettings()
        }
        voiceLookup = task
        return task
    }

    /// Дождаться автоматического выбора голоса (перед первым приветствием).
    func prepareVoice() async {
        await selectVoiceIfNeeded()?.value
    }

    private func startListening() {
        guard phase == .idle || phase == .listening else { return }
        // «Без рук» ждёт обращения часами: поток распознавания открывается, только когда кто-то заговорил.
        // По кнопке и сразу после «Да?» — заранее, чтобы не терять ни доли секунды.
        listener.connectImmediately = translatorActive || !handsFree || Date() < wakeArmedUntil
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
            handler(text, listener.lastLanguage)
            return
        }

        var query = text
        if handsFree && settings.wakeWordEnabled {
            if Date() < wakeArmedUntil {
                // Обращение уже было («Джарвис» → «Да?») или разговор только что шёл — эта фраза и есть вопрос.
                wakeArmedUntil = .distantPast
                query = WakeWord.strip(settings.effectiveWakeWord, from: text) ?? text
            } else if let stripped = WakeWord.strip(settings.effectiveWakeWord, from: text) {
                query = stripped
            } else if settings.addressing == .smart, !settings.trimmedAPIKey.isEmpty {
                // Имени не было: по смыслу фразы и ходу разговора решаем, к ассистенту ли она.
                phase = .idle
                decideIfAddressed(text)
                return
            } else {
                // Фраза не к ассистенту — продолжаем слушать.
                phase = .idle
                resumeListening()
                return
            }
        }
        accept(query)
    }

    /// Фраза без имени: спросить быстрый фильтр, обращена ли она к ассистенту.
    private func decideIfAddressed(_ text: String) {
        let lastQuestion = entries.last { $0.role == .user }?.text
        let lastAnswer = entries.last { $0.role == .assistant }?.text
        let sinceAnswer = Int(Date().timeIntervalSince(lastInteraction))
        let recent = sinceAnswer < 180 && lastAnswer != nil
        let context = AddresseeGate.Context(
            assistantName: settings.persona.displayName,
            userName: settings.persona.userName,
            lastQuestion: recent ? lastQuestion : nil,
            lastAnswer: recent ? lastAnswer : nil,
            secondsSinceAnswer: recent ? sinceAnswer : nil
        )
        let key = settings.trimmedAPIKey
        let started = Date()
        beginBackgroundWork()
        Task {
            let addressed = await addresseeGate.isAddressed(text, context: context, apiKey: key)
            journal("ход", "фильтр обращения: \(addressed ? "к ассистенту" : "мимо") за \(Int(Date().timeIntervalSince(started) * 1_000)) мс")
            // Пока решали, пользователь мог нажать кнопку, выключить режим или начался другой ход.
            guard handsFree, phase == .idle, !translatorActive else {
                if phase == .idle { endBackgroundWork() }
                return
            }
            if addressed {
                accept(text)
            } else {
                endBackgroundWork()
                resumeListening()
            }
        }
    }

    /// Фраза обращена к ассистенту: команда звонка, пустое обращение или вопрос.
    private func accept(_ query: String) {

        if onCall, Self.isHangUp(query) {
            phase = .idle
            endCall()
            return
        }

        guard !query.isEmpty else {
            phase = .speaking
            speaker.speak(settings.language.acknowledgement, language: settings.language.isoCode)
            Task {
                await speaker.waitUntilFinished()
                guard phase == .speaking else { return }
                phase = .idle
                wakeArmedUntil = Date().addingTimeInterval(8)
                if handsFree { resumeListening() }
            }
            return
        }
        submit(query)
    }

    private func handleListenerIdle(_ reason: ListenerIdleReason) {
        guard phase == .listening else { return }
        phase = .idle

        // Ошибка, которая сама не пройдёт (ключ ElevenLabs, лимит): сразу останавливаемся и говорим как есть.
        if reason.isFatal {
            consecutiveRecognizerFailures = 0
            handsFree = false
            translationContinuous = false
            errorMessage = reason.error ?? L("Распознавание речи недоступно.")
            if translatorActive { translationIdleHandler?() }
            releaseMicrophoneIfIdle()
            return
        }

        // Распознаватель падает сразу после старта (выключена диктовка, нет языковых данных и т. п.) —
        // это не тишина: после нескольких попыток останавливаемся и показываем ошибку.
        if reason.isQuickFailure {
            consecutiveRecognizerFailures += 1
            if consecutiveRecognizerFailures >= 5 {
                consecutiveRecognizerFailures = 0
                handsFree = false
                translationContinuous = false
                errorMessage = L("Распознавание речи не работает: %@. Проверьте, что диктовка включена (Настройки → Основные → Клавиатура).", reason.error ?? L("неизвестная ошибка"))
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
        // Тишина — сразу слушаем снова; пауза только при частых сбоях распознавателя.
        consecutiveIdleRestarts = reason.isQuickFailure ? consecutiveIdleRestarts + 1 : 0
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
        journal("звук", "аудио прервано (звонок, Siri или другое приложение)")
        turnTask?.cancel()
        currentTurnID = nil
        speaker.stop()
        listener.cancelCapture()
        markRunningToolsFinished()
        phase = .idle
        endBackgroundWork()
        // Переводчик в режиме диалога не должен остаться с «нажатой» кнопкой, которая не слушает.
        if translatorActive && !translationContinuous { translationIdleHandler?() }
    }

    private func resumeAfterAudioInterruption() {
        guard handsFree || (translatorActive && translationContinuous) else { return }
        journal("звук", "прерывание закончилось")
        if onCall, audio.mode != .conversation {
            // Обычный звонок закончился: в этот момент система разрешает вернуть звук самим.
            guard audio.reactivateForCall() else { return }
            call.markActive()
        }
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

    /// Режим кнопки, ассистент ничего не делает: выключаем микрофон и гарнитурный режим очков —
    /// не пишем звук в фоне и не держим музыку на паузе.
    private func releaseMicrophoneIfIdle() {
        guard !handsFree, !translatorActive, phase == .idle, !isPreparingAudio, audio.mode == .conversation else { return }
        listener.rebuildEngine()
        audio.deactivate()
    }

    /// После ответа или прерывания в режиме кнопки: отпускаем A2DP после хвоста звука, а если
    /// ответ шёл через гарнитуру (стерео выключено или «Без рук» выключили посреди ответа) — микрофон.
    private func settleAudioWhenIdle(immediately: Bool = false) {
        if audio.mode == .playback {
            if immediately { releasePlaybackAudioNow() } else { scheduleAudioRelease() }
        } else {
            releaseMicrophoneIfIdle()
        }
    }

    /// Снова слушать (режим «без рук», субтитры): сначала убеждаемся, что микрофон жив —
    /// движок мог упасть при смене маршрута, пока ассистент говорил.
    private func resumeListening() {
        Task {
            guard await prepareAudio() else { return }
            if phase == .idle { startListening() }
        }
    }

    /// iOS держит фоновое приложение живым, пока оно играет или пишет звук. Пока Claude думает,
    /// звука нет — без фоновой задачи телефон с выключенным экраном усыпил бы приложение посреди ответа.
    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "assistant-turn") { [weak self] in
            // Обработчик истечения вызывается на главном потоке и должен закончить задачу до возврата.
            MainActor.assumeIsolated { self?.endBackgroundWork() }
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
            errorMessage = L("Добавьте API-ключ Anthropic в настройках.")
            phase = .idle
            return
        }
        entries.append(TranscriptEntry(role: .user, text: text))
        replyLanguage = LanguageGuess.iso(for: text, fallback: settings.language.isoCode)
        spokeThisTurn = false
        turnStarted = Date()
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
        if resetPending || Date().timeIntervalSince(lastInteraction) > conversationTimeout {
            resetPending = false
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
            contextEditingExcludedTools: ["notes"],
            thinking: settings.instantAnswers ? settings.model.instantThinking : nil
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
                entries.append(TranscriptEntry(role: .info, text: L("Ответ обрезан по лимиту длины.")))
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
            // Уточняющий вопрос сразу после ответа не требует обращения по имени.
            wakeArmedUntil = Date().addingTimeInterval(settings.followUpSeconds)
            try? await Task.sleep(nanoseconds: 300_000_000) // хвост звука не должен попасть в микрофон
            if handsFree, phase == .idle { resumeListening() }
        } else {
            settleAudioWhenIdle()
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
            sayHoldingPhrase(for: name)
            speaker.flushPending()
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
                entries[index].duration = Date().timeIntervalSince(entries[index].date)
            }

        case .serverToolStarted(let name):
            closeAssistantEntry()
            sayHoldingPhrase(for: name)
            speaker.flushPending()
            let presentation = ToolPresentation.make(name: name, input: nil)
            entries.append(TranscriptEntry(role: .tool, text: presentation.title, symbol: presentation.symbol, toolName: name, toolState: .done))

        case .fallback(_, let to):
            entries.append(TranscriptEntry(role: .info, text: L("Ответ продолжила модель %@.", to ?? "fallback")))
        }
    }

    /// Ответ ассистента, когда реплика была не к нему: он молчит.
    static let silenceMark = "[молчу]"

    private func say(sentence: String) {
        // Реплика была не к ассистенту — он промолчал. Ни звука, ни записи в ленте.
        if sentence.contains(Self.silenceMark) || sentence.contains("[silent]") {
            removeSilentEntry()
            return
        }
        let language = LanguageGuess.iso(for: sentence, fallback: replyLanguage)
        replyLanguage = language
        if !spokeThisTurn {
            spokeThisTurn = true
            journal("ход", "первая фраза ответа через \(Int(Date().timeIntervalSince(turnStarted) * 1_000)) мс")
        }
        speaker.speak(sentence, language: language)
        if phase == .thinking { phase = .speaking }
    }

    /// Инструмент работает секунды (камера, почта, поиск). Если ассистент ещё ничего не сказал,
    /// коротко отзывается — тишина в очках ощущается как поломка.
    private func sayHoldingPhrase(for tool: String) {
        guard !spokeThisTurn, let phrase = HoldingPhrase.make(tool: tool, language: replyLanguage) else { return }
        spokeThisTurn = true
        speaker.speak(phrase, language: replyLanguage)
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

    /// Ассистент решил промолчать: убираем из ленты и его пометку, и услышанную фразу.
    private func removeSilentEntry() {
        if let id = currentAssistantEntry, let index = entries.firstIndex(where: { $0.id == id }) {
            entries.remove(at: index)
            currentAssistantEntry = nil
        }
        if let last = entries.indices.last, entries[last].role == .user {
            entries.remove(at: last)
        }
        journal("ход", "ассистент промолчал: фраза не к нему")
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
        parts.append("режим: \(onCall ? "на связи" : (handsFree ? "без рук" : "кнопка"))")
        parts.append(settings.mailAccount == nil ? "почта не подключена" : "почта подключена")
        return "[контекст: \(parts.joined(separator: "; "))]"
    }

    // MARK: - Переводчик

    /// Переводчик забирает микрофон: ассистент замолкает и слушает речь на языке `language` (BCP-47).
    /// `others` — языки, на которые говорящие могут перейти: тогда каждой фразе сообщается её язык.
    /// `continuous` — слушать фразу за фразой, иначе одну фразу.
    /// `onPartial` и `onText` получают текст и язык фразы (ISO 639), если распознавание его определило.
    func beginTranslationCapture(
        language: String,
        others: [String] = [],
        continuous: Bool,
        onPartial: ((String, String?) -> Void)? = nil,
        onText: @escaping (String, String?) -> Void,
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
        translationPartialHandler = onPartial
        translationIdleHandler = onIdle
        translationContinuous = continuous
        translationLanguage = language
        translationOtherLanguages = others
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
        resumeListening()
    }

    /// Перестать слушать, но не отдавать микрофон: в режиме диалога собеседники говорят по очереди,
    /// и переподключать гарнитуру очков перед каждой фразой — значит терять её начало.
    func pauseTranslationCapture() {
        guard translatorActive else { return }
        listener.cancelCapture()
        speaker.stop()
        phase = .idle
        partialTranscript = ""
    }

    func endTranslationCapture() {
        guard translatorActive else { return }
        translationHandler = nil
        translationPartialHandler = nil
        translationIdleHandler = nil
        translationContinuous = false
        translationLanguage = nil
        translationOtherLanguages = []
        listener.cancelCapture()
        speaker.stop()
        if partnerSpeakerOn {
            partnerSpeakerOn = false
            audio.setPhoneSpeaker(false)
        }
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
        applyVoiceSettings()
        speaker.speak(text, language: language)
        await speaker.waitUntilFinished()
    }

    /// Перевод ещё пишется: очередная законченная фраза сразу уходит в озвучку.
    /// `forPartner` — фраза для собеседника: звучит из динамика телефона, а не в очках.
    func speakTranslationPiece(_ text: String, language: String, forPartner: Bool) {
        guard translatorActive else { return }
        if !speaker.isSpeaking {
            applyVoiceSettings()
            if forPartner, settings.translatorPartnerSpeaker, !partnerSpeakerOn {
                partnerSpeakerOn = audio.setPhoneSpeaker(true)
            }
        }
        speaker.speak(text, language: language)
    }

    /// Ждёт, пока договорит перевод, начатый `speakTranslationPiece`, и возвращает звук в очки.
    func finishTranslationSpeech() async {
        await speaker.waitUntilFinished()
        if partnerSpeakerOn {
            partnerSpeakerOn = false
            audio.setPhoneSpeaker(false)
            await audio.waitForGlassesInput()
        }
    }

    /// Пока звучит перевод, распознавание выключено — иначе переводчик услышит сам себя.
    func pauseListeningForSpeech() {
        guard translatorActive, phase == .listening else { return }
        listener.cancelCapture()
        phase = .idle
        partialTranscript = ""
    }

    var isTranslationListening: Bool { translatorActive && phase == .listening }
}

/// Короткая реплика на время работы медленного инструмента.
enum HoldingPhrase {
    static func make(tool: String, language: String) -> String? {
        let phrases: [String: String]
        switch tool {
        case "take_photo":
            phrases = ["ru": "Смотрю.", "uz": "Qarayapman.", "en": "Looking."]
        case "web_search", "web_fetch":
            phrases = ["ru": "Ищу.", "uz": "Qidiryapman.", "en": "Searching."]
        case "check_mail", "read_mail":
            phrases = ["ru": "Проверяю почту.", "uz": "Pochtani tekshiryapman.", "en": "Checking your mail."]
        case "get_location", "navigate":
            phrases = ["ru": "Секунду.", "uz": "Bir soniya.", "en": "One moment."]
        default:
            // Календарь, заметки, таймеры отвечают мгновенно — реплика только задержала бы ответ.
            return nil
        }
        return phrases[language] ?? phrases["ru"]
    }
}

/// Как показать вызов инструмента в ленте: подпись и SF Symbol.
enum ToolPresentation {
    static func make(name: String, input: JSONValue?) -> (title: String, symbol: String) {
        switch name {
        case "take_photo": return (L("Смотрю через очки"), "camera.viewfinder")
        case "notes": return (input.map(NotesTool.activityTitle(for:)) ?? L("Память"), "books.vertical")
        case "get_location": return (L("Определяю, где мы"), "location")
        case "navigate": return (L("Строю маршрут"), "map")
        case "list_events": return (L("Смотрю календарь"), "calendar")
        case "create_event": return (L("Добавляю в календарь"), "calendar.badge.plus")
        case "create_reminder": return (L("Создаю напоминание"), "checklist")
        case "set_timer": return (L("Ставлю таймер"), "timer")
        case "find_contact": return (L("Ищу в контактах"), "person.crop.circle")
        case "send_message": return (L("Готовлю сообщение"), "message")
        case "compose_email": return (L("Готовлю письмо"), "square.and.pencil")
        case "call": return (L("Звоню"), "phone")
        case "check_mail": return (L("Проверяю почту"), "tray")
        case "read_mail": return (L("Читаю письмо"), "envelope.open")
        case "run_shortcut": return (L("Запускаю команду"), "square.stack.3d.up")
        case "web_search": return (L("Ищу в интернете"), "magnifyingglass")
        case "web_fetch": return (L("Открываю страницу"), "doc.text.magnifyingglass")
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

    /// Подсказки распознаванию: имя и его частые написания (не длиннее 20 знаков каждое).
    static func keyterms(for wakeWord: String) -> [String] {
        let key = wakeWord.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        var seen = Set<String>()
        return ([wakeWord.trimmingCharacters(in: .whitespacesAndNewlines), transliterate(key)] + (variants[key] ?? []))
            .filter { !$0.isEmpty && $0.count <= 20 && seen.insert($0.lowercased()).inserted }
            .prefix(6)
            .map { $0 }
    }

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
