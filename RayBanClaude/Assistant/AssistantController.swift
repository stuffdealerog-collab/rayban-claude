import ClaudeKit
import Foundation
import Observation
import UIKit

/// Запись в ленте диалога на экране.
struct TranscriptEntry: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, tool, info, error }

    let id = UUID()
    var role: Role
    var text: String
    var image: UIImage?
}

/// Связывает микрофон, Claude, инструменты и озвучку в голосовой цикл:
/// слушаем → распознаём → Claude (+ камера/инструменты) → озвучиваем → снова слушаем.
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
    var errorMessage: String?

    let settings: AppSettings
    let glasses: GlassesManager

    @ObservationIgnored private let audio = AudioSessionManager()
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let speaker = SpeechSpeaker()
    @ObservationIgnored private let conversation = ClaudeConversation()
    @ObservationIgnored private let locationProvider = LocationProvider()
    @ObservationIgnored private var chunker = SentenceChunker()
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var currentTurnID: UUID?
    @ObservationIgnored private var currentAssistantEntry: UUID?
    @ObservationIgnored private var audioPermissionsGranted = false
    @ObservationIgnored private var consecutiveRecognizerFailures = 0
    @ObservationIgnored private var lastInteraction = Date.distantPast
    @ObservationIgnored private var consecutiveIdleRestarts = 0

    /// После такой паузы диалог начинается заново (контекст не раздувается бесконечно).
    private let conversationTimeout: TimeInterval = 10 * 60

    init(settings: AppSettings, glasses: GlassesManager) {
        self.settings = settings
        self.glasses = glasses

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
    }

    private var tools: [any ClaudeTool] {
        [TakePhotoTool(glasses: glasses), LocationTool(provider: locationProvider), ReminderTool()]
    }

    // MARK: - Actions

    /// Большая кнопка: слушать одну фразу, или прервать ответ.
    func mainButtonTapped() async {
        switch phase {
        case .thinking, .speaking:
            interrupt()
        case .listening:
            listener.cancelCapture()
            phase = .idle
            handsFree = false
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
        }
    }

    /// Прерывает текущий ответ (и запрос к Claude, если он ещё идёт).
    func interrupt() {
        turnTask?.cancel()
        turnTask = nil
        currentTurnID = nil
        speaker.stop()
        listener.cancelCapture()
        phase = .idle
        if handsFree { startListening() }
    }

    func newConversation() {
        interrupt()
        entries.removeAll()
        Task { await conversation.reset() }
    }

    /// Вопрос текстом (удобно в симуляторе, где нет микрофона очков).
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

    // MARK: - Listening

    private func prepareAudio() async -> Bool {
        if !audioPermissionsGranted {
            guard await SpeechListener.requestPermissions() else {
                errorMessage = "Нужен доступ к микрофону и распознаванию речи (Настройки → Конфиденциальность)."
                return false
            }
            audioPermissionsGranted = true
        }
        // Движок мог остановиться (звонок, Siri, сброс медиасервисов) — проверяем каждый раз.
        if !listener.isEngineRunning {
            do {
                try audio.activate()
                try listener.startEngine()
            } catch {
                errorMessage = "Не удалось включить микрофон: \(error.localizedDescription)"
                return false
            }
        }
        audio.preferGlassesInput()
        microphone = audio.inputDescription
        listener.setLanguage(settings.language.rawValue)
        speaker.languageCode = settings.language.rawValue
        return true
    }

    private func startListening() {
        guard phase == .idle || phase == .listening else { return }
        do {
            try listener.beginCapture()
            partialTranscript = ""
            phase = .listening
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    private func handleUtterance(_ text: String) {
        partialTranscript = ""
        consecutiveIdleRestarts = 0
        var query = text

        if handsFree && settings.wakeWordEnabled {
            guard let stripped = WakeWord.strip(settings.wakeWord, from: text) else {
                // Фраза не к ассистенту — продолжаем слушать.
                phase = .idle
                startListening()
                return
            }
            query = stripped
        }

        guard !query.isEmpty else {
            phase = .idle
            speaker.speak(settings.language == .russian ? "Да?" : "Yes?")
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
                errorMessage = "Распознавание речи не работает: \(reason.error ?? "неизвестная ошибка"). Проверьте, что диктовка включена (Настройки → Основные → Клавиатура)."
                return
            }
        } else {
            consecutiveRecognizerFailures = 0
        }

        guard handsFree else { return }
        // Тишина: перезапускаем; при частых сбоях — с паузой.
        consecutiveIdleRestarts += 1
        let delay: UInt64 = consecutiveIdleRestarts > 3 ? 2_000_000_000 : 300_000_000
        Task {
            try? await Task.sleep(nanoseconds: delay)
            guard handsFree, phase == .idle else { return }
            // Движок мог упасть при смене маршрута — поднимаем его заново, а не просто стартуем распознавание.
            guard await prepareAudio() else { return }
            if handsFree, phase == .idle { startListening() }
        }
    }

    /// Звонок или Siri забрали аудио: прекращаем ответ и прослушивание, режим «без рук» сохраняем.
    private func suspendForAudioInterruption() {
        turnTask?.cancel()
        currentTurnID = nil
        speaker.stop()
        listener.cancelCapture()
        phase = .idle
    }

    private func resumeAfterAudioInterruption() {
        guard handsFree else { return }
        Task {
            guard await prepareAudio() else { return }
            if handsFree, phase == .idle { startListening() }
        }
    }

    // MARK: - Turn

    private func submit(_ text: String) {
        guard !settings.trimmedAPIKey.isEmpty else {
            errorMessage = "Добавьте API-ключ Anthropic в настройках."
            phase = .idle
            return
        }
        entries.append(TranscriptEntry(role: .user, text: text))
        phase = .thinking
        turnTask?.cancel()
        let turnID = UUID()
        currentTurnID = turnID
        turnTask = Task { await runTurn(text, turnID: turnID) }
    }

    private func runTurn(_ text: String, turnID: UUID) async {
        if Date().timeIntervalSince(lastInteraction) > conversationTimeout {
            await conversation.reset()
        }
        lastInteraction = Date()
        chunker = SentenceChunker()
        currentAssistantEntry = nil

        let configuration = ClaudeConfiguration(
            apiKey: settings.trimmedAPIKey,
            model: settings.model.rawValue,
            systemPrompt: SystemPrompt.text,
            webSearch: settings.webSearchEnabled
        )

        do {
            let outcome = try await conversation.send(
                userText: contextLine() + "\n" + text,
                configuration: configuration,
                tools: tools
            ) { [weak self] event in
                await self?.handle(event, turnID: turnID)
            }
            guard !Task.isCancelled else { return }
            if let rest = chunker.flush() { say(rest) }

            switch outcome {
            case .completed:
                break
            case .refused(let category):
                speaker.stop()
                let message = "Извините, с этим я помочь не могу."
                entries.append(TranscriptEntry(role: .info, text: message + (category.map { " (\($0))" } ?? "")))
                say(message)
            case .truncated:
                entries.append(TranscriptEntry(role: .info, text: "Ответ обрезан по лимиту длины."))
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if (error as? URLError)?.code == .cancelled { return }
            entries.append(TranscriptEntry(role: .error, text: error.localizedDescription))
            say(settings.language == .russian ? "Не получилось получить ответ." : "I couldn't get an answer.")
        }

        if speaker.isSpeaking {
            phase = .speaking
            await speaker.waitUntilFinished()
        }
        guard !Task.isCancelled else { return }
        lastInteraction = Date()
        phase = .idle
        if handsFree {
            try? await Task.sleep(nanoseconds: 300_000_000) // хвост звука не должен попасть в микрофон
            if handsFree, phase == .idle { startListening() }
        }
    }

    private func handle(_ event: AgentEvent, turnID: UUID) {
        // События прерванного хода (догоняющие дельты стрима) игнорируем.
        guard turnID == currentTurnID else { return }
        switch event {
        case .textDelta(let delta):
            appendAssistantText(delta)
            for sentence in chunker.append(delta) { say(sentence) }

        case .toolStarted(let name, _):
            closeAssistantEntry()
            entries.append(TranscriptEntry(role: .tool, text: Self.toolTitle(name)))

        case .toolFinished(let name, let output):
            let image = output.content.lazy.compactMap { item -> UIImage? in
                if case .jpeg(let data) = item { return UIImage(data: data) }
                return nil
            }.first
            if let index = entries.lastIndex(where: { $0.role == .tool && $0.text == Self.toolTitle(name) }) {
                entries[index].image = image
                if output.isError, case .text(let reason)? = output.content.first {
                    entries[index].text += " — ошибка: \(reason)"
                }
            }

        case .serverToolStarted(let name):
            closeAssistantEntry()
            entries.append(TranscriptEntry(role: .tool, text: name == "web_search" ? "🔎 Поиск в интернете" : name))

        case .fallback(_, let to):
            entries.append(TranscriptEntry(role: .info, text: "Ответ продолжила модель \(to ?? "fallback")."))
        }
    }

    private func say(_ text: String) {
        speaker.speak(text)
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
        if let rest = chunker.flush() { say(rest) }
    }

    /// Служебная строка контекста в начале реплики. Не в системном промпте — чтобы не ломать кэш.
    private func contextLine() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.language.rawValue)
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        var parts = ["\(formatter.string(from: now)) (\(TimeZone.current.identifier))"]
        parts.append(glasses.isRegistered ? (glasses.hasActiveDevice ? "очки подключены" : "очки не на связи") : "очки не зарегистрированы")
        if let battery = glasses.batteryLevel { parts.append("заряд очков \(battery)%") }
        parts.append("микрофон: \(microphone)")
        return "[контекст: \(parts.joined(separator: "; "))]"
    }

    private static func toolTitle(_ name: String) -> String {
        switch name {
        case "take_photo": return "📷 Снимок с камеры очков"
        case "get_location": return "📍 Определяю местоположение"
        case "create_reminder": return "⏰ Создаю напоминание"
        default: return "🛠 \(name)"
        }
    }
}

/// Обращение к ассистенту в режиме «без рук»: «Клод, что это?» → «что это?».
enum WakeWord {
    /// Варианты, в которые распознаватель часто превращает «Клод/Claude».
    private static let variants: [String: [String]] = [
        "клод": ["клод", "клауд", "клот", "claude", "клоуд"],
        "claude": ["claude", "cloud", "clod", "клод"],
    ]

    /// Возвращает запрос без обращения или `nil`, если обращения в первых словах нет.
    static func strip(_ wakeWord: String, from text: String) -> String? {
        let key = wakeWord.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return text }
        let accepted = Set(variants[key] ?? [key])

        let words = text.split(whereSeparator: \.isWhitespace)
        for (position, word) in words.prefix(3).enumerated() {
            let normalized = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if accepted.contains(normalized) {
                return words.dropFirst(position + 1).joined(separator: " ")
                    .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            }
        }
        return nil
    }
}
