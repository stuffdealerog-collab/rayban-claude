import AssistantCore
import AVFoundation
import ClaudeKit

/// Озвучивает ответ по фразам строго по порядку. Три ступени, от быстрой к надёжной:
///
/// 1. **Поток** (ElevenLabs v4 Turbo по WebSocket): текст уходит по мере того, как его пишет Claude,
///    звук начинает играть через доли секунды. Одна реплика — одно соединение.
/// 2. **По фразам** (HTTP): каждая фраза синтезируется отдельным запросом, с опережением на одну.
///    Сюда ответ переходит, если поток не открылся или сервер его отверг.
/// 3. **Голос iOS** — если ElevenLabs недоступен совсем. Ответ не теряется.
@MainActor
final class SpeechSpeaker: NSObject {
    var languageCode = "ru-RU" {
        didSet { systemVoice.languageCode = languageCode }
    }

    /// nil — говорим голосом iOS.
    var elevenLabs: ElevenLabsConfiguration? {
        didSet {
            guard elevenLabs != oldValue else { return }
            neuralBlocked = false
            neuralPausedUntil = nil
            consecutiveNeuralFailures = 0
            reportedProblem = nil
        }
    }

    /// Потоковая озвучка: nil — выключена (нет ключа или выбран режим «по фразам»).
    var streaming: DialogueSpeechConfiguration? {
        didSet {
            guard streaming != oldValue else { return }
            streamBlocked = false
            streamPausedUntil = nil
        }
    }

    /// Сообщение для ленты, когда ElevenLabs перестал работать и включился голос iOS.
    var onVoiceProblem: ((String) -> Void)?

    var isSpeaking: Bool { !queue.isEmpty || stream != nil || !afterStream.isEmpty }

    private struct Segment {
        let text: String
        /// ISO 639-1 языка фразы — по нему выбирается голос iOS и модель ElevenLabs.
        let language: String?
        /// Синтез ElevenLabs; nil — фразу говорит голос iOS. Результат nil — синтез не удался.
        let audio: Task<Data?, Never>?
    }

    private let systemVoice = SystemVoice()
    private let client = ElevenLabsClient()
    private var queue: [Segment] = []
    private var playbackLoop: Task<Void, Never>?
    private var lastSynthesis: Task<Data?, Never>?
    /// Уже отправленный в синтез текст ответа — для связной интонации между фразами.
    private var spokenContext = ""
    private var generation = UUID()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var player: AVAudioPlayer?
    private var playerFinished: CheckedContinuation<Bool, Never>?
    private var playerWatchdog: Task<Void, Never>?

    private var neuralBlocked = false
    private var neuralPausedUntil: Date?
    private var consecutiveNeuralFailures = 0
    private var reportedProblem: String?

    // Поток
    private let streamPlayer = StreamingVoice()
    private var stream: DialogueSpeechStream?
    private var streamID = 0
    /// Фразы текущей реплики — чтобы повторить их по HTTP, если поток не дал звука.
    private var streamTexts: [(text: String, language: String?)] = []
    private var streamGotAudio = false
    private var streamClosing = false
    private var streamStarted = Date.distantPast
    /// Фразы, пришедшие, пока прошлая реплика договаривала: пойдут следующей репликой.
    private var afterStream: [(text: String, language: String?)] = []
    private var firstAudioTimer: Task<Void, Never>?
    private var streamBlocked = false
    private var streamPausedUntil: Date?

    override init() {
        super.init()
        streamPlayer.onFinished = { [weak self] in self?.streamPlaybackEnded() }
    }

    /// Ставит фразу в очередь озвучки. `language` — ISO 639-1 фразы; nil — язык из настроек.
    func speak(_ text: String, language: String? = nil) {
        let clean = SpeechText.clean(text)
        guard !clean.isEmpty else { return }
        if streamClosing {
            // Прошлая реплика ещё договаривает — эта фраза начнёт следующую.
            afterStream.append((clean, language))
            return
        }
        if stream != nil || (streamUsable && queue.isEmpty) {
            streamSpeak(clean, language: language)
            return
        }
        enqueueSegment(clean, language: language)
    }

    /// Текста в этой реплике больше не будет: поток договаривает и закрывается.
    func finishReply() {
        guard let stream, !streamClosing else { return }
        streamClosing = true
        stream.finish()
        armFirstAudioTimer()
    }

    /// Пауза в ответе (Claude вызывает инструмент): озвучить уже присланное, соединение оставить.
    func flushPending() {
        guard !streamClosing else { return }
        stream?.flush()
    }

    private func enqueueSegment(_ clean: String, language: String?) {
        queue.append(Segment(text: clean, language: language, audio: synthesisTask(for: clean, language: language)))
        spokenContext = String((spokenContext + " " + clean).suffix(400))
        startPlaybackLoopIfNeeded()
    }

    /// Немедленно прерывает речь и отменяет запросы синтеза.
    func stop() {
        generation = UUID()
        playbackLoop?.cancel()
        playbackLoop = nil
        queue.forEach { $0.audio?.cancel() }
        queue.removeAll()
        lastSynthesis = nil
        spokenContext = ""
        player?.stop()
        player = nil
        finishPlayback(started: true)
        systemVoice.stop()
        closeStream()
        afterStream.removeAll()
        streamPlayer.stop()
        AudioLevels.shared.output = 0
        AudioLevels.shared.systemVoiceActive = false
        resumeWaiters()
    }

    /// После сброса медиасервисов iOS синтезатор нужно создать заново.
    func rebuildSynthesizer() {
        stop()
        systemVoice.rebuildSynthesizer()
    }

    /// Ждёт, пока прозвучат все фразы. Раз ждут конца — текста больше не будет.
    func waitUntilFinished() async {
        finishReply()
        guard isSpeaking else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: - Поток

    private var streamUsable: Bool {
        guard streaming != nil, !streamBlocked else { return false }
        if let streamPausedUntil, streamPausedUntil > Date() { return false }
        return true
    }

    private func streamSpeak(_ text: String, language: String?) {
        if stream == nil { openStream(language: language) }
        streamTexts.append((text, language))
        stream?.speak(text + " ")
        // Каждая фраза — законченная мысль: пусть звучит сразу, не дожидаясь следующей.
        stream?.flush()
        if !streamGotAudio { armFirstAudioTimer() }
    }

    private func openStream(language: String?) {
        guard var configuration = streaming else { return }
        configuration.languageCode = language ?? configuration.languageCode
        streamID += 1
        let id = streamID
        streamTexts = []
        streamGotAudio = false
        streamClosing = false
        streamStarted = Date()
        streamPlayer.begin(sampleRate: configuration.sampleRate)
        let stream = DialogueSpeechStream(configuration: configuration) { [weak self] event in
            Task { @MainActor in self?.handleStream(event, id: id) }
        }
        self.stream = stream
        stream.start()
    }

    private func handleStream(_ event: DialogueSpeechEvent, id: Int) {
        guard id == streamID, stream != nil else { return }
        switch event {
        case .audio(let pcm):
            if !streamGotAudio {
                streamGotAudio = true
                firstAudioTimer?.cancel()
                let delay = Int(Date().timeIntervalSince(streamStarted) * 1_000)
                journal("голос", "поток: первый звук через \(delay) мс")
                neuralSucceeded()
            }
            do {
                try streamPlayer.append(pcm)
            } catch {
                journal("голос", "поток: плеер не запустился — \(error.localizedDescription)")
                streamFailed(permanent: false, reason: L("плеер не запустился"))
            }
        case .finished:
            if streamGotAudio {
                streamPlayer.endOfInput()
            } else if streamTexts.isEmpty {
                streamPlaybackEnded()
            } else {
                streamFailed(permanent: false, reason: L("сервер закрыл сеанс без звука"))
            }
        case .failed(let error):
            journal("голос", "поток: ошибка \(error.kind) — \(error.message)")
            let permanent = error.kind != "connection"
            streamFailed(permanent: permanent, reason: error.localizedDescription)
        }
    }

    /// Поток не справился. Если звука ещё не было — фразы уходят на ступень «по фразам».
    private func streamFailed(permanent: Bool, reason: String) {
        let texts = streamGotAudio ? [] : streamTexts
        let hadAudio = streamGotAudio
        closeStream()
        // Отказ сервера (ключ, модель, формат) сам не пройдёт — не пробуем на каждой фразе.
        streamPausedUntil = Date().addingTimeInterval(permanent ? 600 : 60)
        journal("голос", "поток выключен на \(permanent ? "10 минут" : "минуту"): \(reason)")
        let pending = texts + afterStream
        afterStream.removeAll()
        if hadAudio {
            streamPlayer.endOfInput()
        } else {
            streamPlayer.stop()
        }
        for item in pending { enqueueSegment(item.text, language: item.language) }
        if !isSpeaking { resumeWaiters() }
    }

    private func closeStream() {
        firstAudioTimer?.cancel()
        firstAudioTimer = nil
        stream?.cancel()
        stream = nil
        streamID += 1
        streamTexts = []
        streamClosing = false
        streamGotAudio = false
    }

    /// Плеер доиграл всё, что прислал сервер.
    private func streamPlaybackEnded() {
        if stream != nil {
            // Реплика ещё открыта (ждём продолжения после инструмента) — звук кончился, текст может прийти.
            guard streamClosing else { return }
            closeStream()
        }
        let next = afterStream
        afterStream.removeAll()
        for item in next { speak(item.text, language: item.language) }
        if !next.isEmpty { finishReply() }
        if !isSpeaking { resumeWaiters() }
    }

    /// Если первый звук не пришёл за 4 секунды, не молчим: фразы уходят на запасную ступень.
    private func armFirstAudioTimer() {
        guard !streamGotAudio, firstAudioTimer == nil else { return }
        let id = streamID
        firstAudioTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.streamID == id, !self.streamGotAudio else { return }
            self.firstAudioTimer = nil
            self.streamFailed(permanent: false, reason: L("нет звука 4 секунды"))
        }
    }

    // MARK: - ElevenLabs

    private var neuralUsable: Bool {
        if neuralBlocked { return false }
        if let neuralPausedUntil, neuralPausedUntil > Date() { return false }
        return true
    }

    private func synthesisTask(for text: String, language: String?) -> Task<Data?, Never>? {
        guard let base = elevenLabs, neuralUsable else { return nil }
        let configuration = language.map { base.adapted(to: $0) } ?? base
        let previous = lastSynthesis
        let context = spokenContext.trimmingCharacters(in: .whitespaces)
        let client = self.client
        let task = Task<Data?, Never> { [weak self] in
            _ = await previous?.value // по одному запросу за раз
            guard !Task.isCancelled, let self, self.neuralUsable else { return nil }
            do {
                let data = try await client.synthesize(
                    text,
                    previousText: context.isEmpty ? nil : context,
                    configuration: configuration
                )
                self.neuralSucceeded()
                return data
            } catch {
                if !Task.isCancelled { self.neuralFailed(error) }
                return nil
            }
        }
        lastSynthesis = task
        return task
    }

    private func neuralSucceeded() {
        consecutiveNeuralFailures = 0
        reportedProblem = nil
    }

    private func neuralFailed(_ error: Error) {
        if let error = error as? ElevenLabsError, error.isPermanent {
            neuralBlocked = true
            report(L("Голос ElevenLabs недоступен: %@ Пока говорю голосом iOS.", error.localizedDescription))
            return
        }
        // Сеть или перегрузка: после двух сбоев подряд минуту не ждём ElevenLabs на каждой фразе.
        consecutiveNeuralFailures += 1
        if consecutiveNeuralFailures >= 2 {
            consecutiveNeuralFailures = 0
            neuralPausedUntil = Date().addingTimeInterval(60)
            report(L("ElevenLabs не отвечает (%@). Минуту говорю голосом iOS.", error.localizedDescription))
        }
    }

    private func report(_ message: String) {
        guard reportedProblem != message else { return }
        reportedProblem = message
        onVoiceProblem?(message)
    }

    // MARK: - Воспроизведение

    private func startPlaybackLoopIfNeeded() {
        guard playbackLoop == nil else { return }
        let current = generation
        playbackLoop = Task { [weak self] in
            await self?.playQueue(generation: current)
        }
    }

    private func playQueue(generation current: UUID) async {
        while current == generation, let segment = queue.first {
            var played = false
            // Плохая сеть: дольше 5 секунд не ждём — фразу скажет голос iOS.
            if let audio = segment.audio, let data = await Self.value(of: audio, timeout: 5), current == generation {
                played = await play(data)
            }
            if !played, current == generation {
                AudioLevels.shared.systemVoiceActive = true
                systemVoice.languageCode = segment.language.map(LanguageGuess.bcp47(for:)) ?? languageCode
                systemVoice.speak(segment.text)
                await systemVoice.waitUntilFinished()
                AudioLevels.shared.systemVoiceActive = false
            }
            guard current == generation else { return }
            queue.removeFirst()
        }
        guard current == generation else { return }
        playbackLoop = nil
        lastSynthesis = nil
        spokenContext = ""
        if !isSpeaking { resumeWaiters() }
    }

    /// Результат синтеза, но не дольше `timeout` секунд.
    private static func value(of task: Task<Data?, Never>, timeout: TimeInterval) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Проигрывает MP3 и ждёт конца. false — звук не воспроизвёлся (тогда фразу скажет голос iOS).
    private func play(_ data: Data) async -> Bool {
        guard let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue) else { return false }
        player.delegate = self
        player.isMeteringEnabled = true
        self.player = player
        let meter = startMeter(for: player)
        let played = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            playerFinished = continuation
            if player.play() {
                startPlayerWatchdog(for: player)
            } else {
                finishPlayback(started: false)
            }
        }
        meter.cancel()
        AudioLevels.shared.output = 0
        if self.player === player { self.player = nil }
        return played
    }

    /// Громкость голоса для решётки — 20 раз в секунду.
    private func startMeter(for player: AVAudioPlayer) -> Task<Void, Never> {
        Task { @MainActor [weak player] in
            while !Task.isCancelled, let player {
                player.updateMeters()
                AudioLevels.shared.output = AudioLevels.normalize(decibels: player.averagePower(forChannel: 0))
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func finishPlayback(started: Bool) {
        playerWatchdog?.cancel()
        playerWatchdog = nil
        let continuation = playerFinished
        playerFinished = nil
        continuation?.resume(returning: started)
    }

    /// Если делегат не сообщил о конце (прерывание аудиосессии), не ждём вечно.
    private func startPlayerWatchdog(for player: AVAudioPlayer) {
        let id = ObjectIdentifier(player)
        let limit = max(player.duration, 1) + 3
        playerWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self, let current = self.player, ObjectIdentifier(current) == id else { return }
            current.stop()
            self.finishPlayback(started: true)
        }
    }

    private func playerEnded(_ id: ObjectIdentifier, successfully: Bool) {
        // Проверка isPlaying: поздний колбэк освобождённого плеера не должен закончить новый с тем же адресом.
        guard let player, ObjectIdentifier(player) == id, !player.isPlaying else { return }
        // Ошибка декодирования — фразу повторит голос iOS, а не потеряет.
        finishPlayback(started: successfully)
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

extension SpeechSpeaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerEnded(id, successfully: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerEnded(id, successfully: false) }
    }
}
