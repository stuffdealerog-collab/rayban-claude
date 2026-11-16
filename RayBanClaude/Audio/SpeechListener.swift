@preconcurrency import AVFoundation
import Speech

enum SpeechListenerError: LocalizedError {
    case noAudioInput
    case engineStopped
    case recognizerUnavailable
    case cloudRecognizerMissing

    var errorDescription: String? {
        switch self {
        case .noAudioInput: return "Нет доступного микрофона."
        case .engineStopped: return "Микрофон выключен — аудио нужно перезапустить."
        case .recognizerUnavailable: return "Распознавание речи сейчас недоступно для выбранного языка."
        case .cloudRecognizerMissing: return "Apple не распознаёт этот язык (например, узбекский) или нет разрешения на распознавание речи. Добавьте ключ ElevenLabs в настройках — тогда речь распознает он."
        }
    }
}

/// Почему распознавание закончилось без фразы.
struct ListenerIdleReason {
    /// Текст ошибки распознавателя (nil — просто тишина или отмена).
    var error: String?
    /// Закончилось подозрительно быстро — признак неисправного распознавателя, а не тишины.
    var isQuickFailure: Bool
    /// Ошибка, которая сама не пройдёт (неверный ключ ElevenLabs, кончился лимит): повторять бессмысленно.
    var isFatal = false
}

/// Слушает микрофон (очков или телефона) и превращает речь в текст.
///
/// Аудио-движок работает постоянно, а распознавание включается на одну фразу:
/// конец фразы определяется по паузе. Пока ассистент говорит, распознавание выключено,
/// чтобы он не слышал сам себя.
///
/// Два способа распознавания: Apple Speech (на устройстве, с промежуточным текстом) и облачный —
/// фраза записывается и отправляется в ElevenLabs Scribe. Облачный нужен для языков, которых
/// у Apple нет, прежде всего узбекского.
@MainActor
final class SpeechListener {
    /// Промежуточный текст для UI.
    var onPartial: ((String) -> Void)?
    /// Завершённая фраза.
    var onUtterance: ((String) -> Void)?
    /// Распознавание закончилось без текста (тишина, ошибка) — можно перезапустить.
    var onIdle: ((ListenerIdleReason) -> Void)?
    /// Облачное распознавание: PCM 16 кГц моно → текст. nil — облака нет (нет ключа ElevenLabs).
    var cloudTranscriber: (@Sendable (Data, String) async throws -> String)?

    /// Пауза после речи, по которой фраза считается законченной.
    var endOfUtteranceSilence: Double = 1.2

    private(set) var isCapturing = false
    /// Язык распознаётся облаком (у Apple распознавателя для него нет).
    private(set) var usesCloud = false
    var isEngineRunning: Bool { engine.isRunning }

    private var engine = AVAudioEngine()
    private let tapBox = TapBox()
    private var recognizer: SFSpeechRecognizer?
    private var languageCode = "ru"
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var cloudMonitor: Task<Void, Never>?
    private var latestText = ""
    private var captureStarted = Date.distantPast
    private var generation = UUID()
    private var configurationObserver: NSObjectProtocol?
    /// Движок остановлен намеренно (ответ в режиме A2DP) — смена конфигурации не должна его поднимать.
    private var engineWanted = false

    static func requestPermissions() async -> Bool {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        let speechStatus = await requestSpeechAuthorization()
        // Без Apple Speech можно обойтись облачным распознаванием, без микрофона — нет.
        return micGranted && (speechStatus == .authorized || speechStatus == .denied || speechStatus == .restricted)
    }

    static var speechRecognitionAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Колбэк авторизации приходит на произвольной очереди — замыкание создаётся вне MainActor.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Язык распознавания (BCP-47, например `ru-RU`, `uz-UZ`).
    func setLanguage(_ identifier: String) {
        languageCode = String(identifier.prefix(2))
        if recognizer?.locale.identifier != identifier {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
        }
        // Нет распознавателя Apple для языка или нет разрешения на него — распознаёт облако.
        usesCloud = recognizer == nil || !Self.speechRecognitionAuthorized
    }

    // MARK: - Engine

    func startEngine() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // В симуляторе без микрофона или без разрешения формат нулевой — installTap упал бы.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechListenerError.noAudioInput }

        input.removeTap(onBus: 0)
        tapBox.prepare(inputFormat: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(tapBox))
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
        AudioLevels.shared.input = 0
    }

    /// После сброса медиасервисов или смены режима аудио старый AVAudioEngine непригоден — создаём новый.
    func rebuildEngine() {
        stopEngine()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine = AVAudioEngine()
    }

    /// Tap вызывается на аудиопотоке — замыкание создаётся вне MainActor.
    private nonisolated static func makeTapBlock(_ box: TapBox) -> AVAudioNodeTapBlock {
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
        if usesCloud {
            guard cloudTranscriber != nil else { throw SpeechListenerError.cloudRecognizerMissing }
            cancelCapture()
            beginCloudCapture()
            return
        }
        guard let recognizer, recognizer.isAvailable else { throw SpeechListenerError.recognizerUnavailable }
        cancelCapture()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            // Распознавание на устройстве: приватнее, без лимита длительности и без сети.
            request.requiresOnDeviceRecognition = true
        }
        tapBox.setRequest(request)
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
        cloudMonitor?.cancel()
        cloudMonitor = nil
        tapBox.setRequest(nil)
        _ = tapBox.stopRecording()
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

    // MARK: - Облачное распознавание (узбекский)

    /// Записывает фразу и сам определяет её конец по громкости: речь, затем пауза.
    private func beginCloudCapture() {
        tapBox.startRecording()
        isCapturing = true
        captureStarted = Date()
        latestText = ""
        let current = UUID()
        generation = current
        let silence = endOfUtteranceSilence

        cloudMonitor = Task { [weak self] in
            var noiseFloor: Float = 1
            var speechFrames = 0
            var heardSpeech = false
            var lastVoice = Date()
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled, self.generation == current else { return }
                let level = AudioLevels.shared.input
                let elapsed = Date().timeIntervalSince(started)
                if elapsed < 0.4 { noiseFloor = min(noiseFloor, level) }
                let threshold = max(noiseFloor + 0.12, 0.18)
                if level > threshold {
                    speechFrames += 1
                    if speechFrames >= 3 { heardSpeech = true }
                    lastVoice = Date()
                } else {
                    speechFrames = 0
                }
                if heardSpeech, Date().timeIntervalSince(lastVoice) > silence || elapsed > 25 {
                    self.finishCloudCapture(generation: current)
                    return
                }
                if !heardSpeech, elapsed > 8 {
                    // Тишина: фразы не было.
                    self.cancelCapture()
                    self.onIdle?(ListenerIdleReason(error: nil, isQuickFailure: false))
                    return
                }
            }
        }
    }

    private func finishCloudCapture(generation current: UUID) {
        let audio = tapBox.stopRecording()
        cloudMonitor = nil
        guard let transcriber = cloudTranscriber, audio.count > 6_400 else { // меньше 0,2 с — не речь
            cancelCapture()
            onIdle?(ListenerIdleReason(error: nil, isQuickFailure: false))
            return
        }
        onPartial?("Распознаю…")
        let language = languageCode
        Task { [weak self] in
            do {
                let raw = try await transcriber(audio, language)
                let text = Self.withoutSoundTags(raw)
                guard let self, self.generation == current else { return }
                self.cancelCapture()
                if text.isEmpty {
                    self.onIdle?(ListenerIdleReason(error: nil, isQuickFailure: false))
                } else {
                    self.onUtterance?(text)
                }
            } catch {
                guard let self, self.generation == current else { return }
                self.cancelCapture()
                let permanent = (error as? ElevenLabsError)?.isPermanent ?? false
                let message = permanent ? "Распознавание ElevenLabs: \(error.localizedDescription)" : error.localizedDescription
                // Сетевой сбой — не поломка распознавателя: просто слушаем снова.
                self.onIdle?(ListenerIdleReason(error: message, isQuickFailure: false, isFatal: permanent))
            }
        }
    }
}

extension SpeechListener {
    /// Scribe помечает звуки «(кашель)», «[музыка]» — это не речь.
    nonisolated static func withoutSoundTags(_ text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.trimmingCharacters(in: .punctuationCharacters).isEmpty ? "" : stripped
    }
}

/// Мост между аудиопотоком и главным потоком: запрос Apple Speech, запись для облака и громкость.
private final class TapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recording = false
    private var recorded = Data()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)

    func prepare(inputFormat: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        converter = targetFormat.flatMap { AVAudioConverter(from: inputFormat, to: $0) }
    }

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let previous = self.request
        self.request = request
        lock.unlock()
        previous?.endAudio()
    }

    func startRecording() {
        lock.lock()
        recorded = Data()
        recording = true
        lock.unlock()
    }

    /// Останавливает запись и отдаёт её: PCM 16 бит, 16 кГц, моно.
    func stopRecording() -> Data {
        lock.lock()
        defer { lock.unlock() }
        recording = false
        let data = recorded
        recorded = Data()
        return data
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        AudioLevels.shared.input = Self.level(of: buffer)

        lock.lock()
        let request = self.request
        let shouldRecord = recording && recorded.count < 16_000 * 2 * 30 // не больше 30 секунд
        let converter = self.converter
        lock.unlock()

        request?.append(buffer)
        guard shouldRecord, let converter, let targetFormat else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        let once = OnceFlag()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard once.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = output.int16ChannelData else { return }
        let bytes = Data(bytes: samples[0], count: Int(output.frameLength) * 2)
        lock.lock()
        if recording { recorded.append(bytes) }
        lock.unlock()
    }

    /// Громкость буфера 0…1 (по RMS в децибелах).
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        return AudioLevels.normalize(decibels: 20 * log10(max(rms, 0.000_001)))
    }
}

/// Отдаёт входной буфер конвертеру ровно один раз.
private final class OnceFlag: @unchecked Sendable {
    private var used = false
    func take() -> Bool {
        guard !used else { return false }
        used = true
        return true
    }
}
