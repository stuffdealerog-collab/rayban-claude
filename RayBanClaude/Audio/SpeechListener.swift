import AVFoundation
import Speech

enum SpeechListenerError: LocalizedError {
    case noAudioInput
    case engineStopped
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .noAudioInput: return "Нет доступного микрофона."
        case .engineStopped: return "Микрофон выключен — аудио нужно перезапустить."
        case .recognizerUnavailable: return "Распознавание речи сейчас недоступно для выбранного языка."
        }
    }
}

/// Почему распознавание закончилось без фразы.
struct ListenerIdleReason {
    /// Текст ошибки распознавателя (nil — просто тишина или отмена).
    var error: String?
    /// Закончилось подозрительно быстро — признак неисправного распознавателя, а не тишины.
    var isQuickFailure: Bool
}

/// Слушает микрофон (очков или телефона) и превращает речь в текст через Apple Speech.
///
/// Аудио-движок работает постоянно, а распознавание включается на одну фразу:
/// конец фразы определяется по паузе. Пока ассистент говорит, распознавание выключено,
/// чтобы он не слышал сам себя.
@MainActor
final class SpeechListener {
    /// Промежуточный текст для UI.
    var onPartial: ((String) -> Void)?
    /// Завершённая фраза.
    var onUtterance: ((String) -> Void)?
    /// Распознавание закончилось без текста (тишина, ошибка) — можно перезапустить.
    var onIdle: ((ListenerIdleReason) -> Void)?

    /// Пауза после речи, по которой фраза считается законченной.
    var endOfUtteranceSilence: Double = 1.2

    private(set) var isCapturing = false
    var isEngineRunning: Bool { engine.isRunning }

    private var engine = AVAudioEngine()
    private let requestBox = RecognitionRequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var latestText = ""
    private var captureStarted = Date.distantPast
    private var generation = UUID()
    private var configurationObserver: NSObjectProtocol?
    /// Движок остановлен намеренно (ответ в режиме A2DP) — смена конфигурации не должна его поднимать.
    private var engineWanted = false

    static func requestPermissions() async -> Bool {
        let speechStatus = await requestSpeechAuthorization()
        let micGranted = await AVAudioApplication.requestRecordPermission()
        return speechStatus == .authorized && micGranted
    }

    /// Колбэк авторизации приходит на произвольной очереди — замыкание создаётся вне MainActor.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    func setLanguage(_ identifier: String) {
        if recognizer?.locale.identifier != identifier {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
        }
    }

    // MARK: - Engine

    func startEngine() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // В симуляторе без микрофона или без разрешения формат нулевой — installTap упал бы.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechListenerError.noAudioInput }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(requestBox))
        engine.prepare()
        try engine.start()
        engineWanted = true

        if configurationObserver == nil {
            // Смена маршрута (очки подключились/отключились) меняет формат входа и останавливает движок.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.restartEngine() }
            }
        }
    }

    func stopEngine() {
        engineWanted = false
        cancelCapture()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// После сброса медиасервисов iOS старый AVAudioEngine непригоден — создаём новый.
    func rebuildEngine() {
        stopEngine()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine = AVAudioEngine()
    }

    /// Tap вызывается на аудиопотоке — замыкание создаётся вне MainActor.
    private nonisolated static func makeTapBlock(_ box: RecognitionRequestBox) -> AVAudioNodeTapBlock {
        { buffer, _ in box.append(buffer) }
    }

    private func restartEngine() {
        guard engineWanted else { return }
        let wasCapturing = isCapturing
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try startEngine()
            if wasCapturing { try beginCapture() }
        } catch {
            let wasActive = isCapturing || wasCapturing
            cancelCapture()
            if wasActive { onIdle?(ListenerIdleReason(error: error.localizedDescription, isQuickFailure: true)) }
        }
    }

    // MARK: - Recognition

    /// Начинает распознавание одной фразы.
    func beginCapture() throws {
        guard engine.isRunning else { throw SpeechListenerError.engineStopped }
        guard let recognizer, recognizer.isAvailable else { throw SpeechListenerError.recognizerUnavailable }
        cancelCapture()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            // Распознавание на устройстве: приватнее, без лимита длительности и без сети.
            request.requiresOnDeviceRecognition = true
        }
        requestBox.set(request)
        latestText = ""
        isCapturing = true
        captureStarted = Date()

        let current = UUID()
        generation = current
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler(owner: self, generation: current))
    }

    /// Результаты приходят на очереди Speech — замыкание создаётся вне MainActor и переходит на него само.
    private nonisolated static func makeResultHandler(
        owner: SpeechListener, generation: UUID
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorText = error?.localizedDescription
            Task { @MainActor in
                owner?.handleResult(text: text, isFinal: isFinal, error: errorText, generation: generation)
            }
        }
    }

    /// Прекращает распознавание без отправки фразы.
    func cancelCapture() {
        silenceTimer?.cancel()
        silenceTimer = nil
        requestBox.set(nil)
        task?.cancel()
        task = nil
        isCapturing = false
        generation = UUID() // поздние колбэки старой задачи игнорируются
    }

    private func handleResult(text: String?, isFinal: Bool, error: String?, generation: UUID) {
        guard generation == self.generation, isCapturing else { return }

        if let text, !text.isEmpty, text != latestText {
            latestText = text
            onPartial?(text)
            restartSilenceTimer()
        }
        if isFinal || error != nil {
            finishUtterance(error: error)
        }
    }

    private func restartSilenceTimer() {
        silenceTimer?.cancel()
        let delay = UInt64(endOfUtteranceSilence * 1_000_000_000)
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.finishUtterance(error: nil)
        }
    }

    private func finishUtterance(error: String?) {
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Date().timeIntervalSince(captureStarted)
        cancelCapture()
        if text.isEmpty {
            onIdle?(ListenerIdleReason(error: error, isQuickFailure: error != nil && duration < 1.0))
        } else {
            onUtterance?(text)
        }
    }
}

/// Текущий запрос распознавания, доступный из аудиопотока (tap вызывается не на главном потоке).
private final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let previous = self.request
        self.request = request
        lock.unlock()
        previous?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }
}
