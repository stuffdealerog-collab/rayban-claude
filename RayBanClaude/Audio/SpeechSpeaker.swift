import AVFoundation
import ClaudeKit

/// Озвучивает ответ по фразам строго по порядку: голосом ElevenLabs, если он настроен, иначе голосом iOS.
/// Фразу, которую ElevenLabs не смог озвучить (сеть, лимит, ключ), произносит голос iOS — ответ не теряется.
///
/// Запросы к ElevenLabs идут по одному (на бесплатном тарифе мало параллельных запросов), но с опережением:
/// пока звучит одна фраза, уже синтезируется следующая.
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

    /// Сообщение для ленты, когда ElevenLabs перестал работать и включился голос iOS.
    var onVoiceProblem: ((String) -> Void)?

    var isSpeaking: Bool { !queue.isEmpty }

    private struct Segment {
        let text: String
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

    /// Ставит фразу в очередь озвучки.
    func speak(_ text: String) {
        let clean = SpeechText.clean(text)
        guard !clean.isEmpty else { return }
        queue.append(Segment(text: clean, audio: synthesisTask(for: clean)))
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
        resumeWaiters()
    }

    /// После сброса медиасервисов iOS синтезатор нужно создать заново.
    func rebuildSynthesizer() {
        stop()
        systemVoice.rebuildSynthesizer()
    }

    /// Ждёт, пока прозвучат все фразы из очереди.
    func waitUntilFinished() async {
        guard isSpeaking else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: - ElevenLabs

    private var neuralUsable: Bool {
        if neuralBlocked { return false }
        if let neuralPausedUntil, neuralPausedUntil > Date() { return false }
        return true
    }

    private func synthesisTask(for text: String) -> Task<Data?, Never>? {
        guard let configuration = elevenLabs, neuralUsable else { return nil }
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
            report("Голос ElevenLabs недоступен: \(error.localizedDescription) Пока говорю голосом iOS.")
            return
        }
        // Сеть или перегрузка: после двух сбоев подряд минуту не ждём ElevenLabs на каждой фразе.
        consecutiveNeuralFailures += 1
        if consecutiveNeuralFailures >= 2 {
            consecutiveNeuralFailures = 0
            neuralPausedUntil = Date().addingTimeInterval(60)
            report("ElevenLabs не отвечает (\(error.localizedDescription)). Минуту говорю голосом iOS.")
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
            if let audio = segment.audio, let data = await audio.value, current == generation {
                played = await play(data)
            }
            if !played, current == generation {
                systemVoice.speak(segment.text)
                await systemVoice.waitUntilFinished()
            }
            guard current == generation else { return }
            queue.removeFirst()
        }
        guard current == generation else { return }
        playbackLoop = nil
        lastSynthesis = nil
        spokenContext = ""
        resumeWaiters()
    }

    /// Проигрывает MP3 и ждёт конца. false — звук не запустился (тогда фразу скажет голос iOS).
    private func play(_ data: Data) async -> Bool {
        guard let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue) else { return false }
        player.delegate = self
        self.player = player
        let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            playerFinished = continuation
            if player.play() {
                startPlayerWatchdog(for: player)
            } else {
                finishPlayback(started: false)
            }
        }
        if self.player === player { self.player = nil }
        return started
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

    private func playerEnded(_ id: ObjectIdentifier) {
        // Проверка isPlaying: поздний колбэк освобождённого плеера не должен закончить новый с тем же адресом.
        guard let player, ObjectIdentifier(player) == id, !player.isPlaying else { return }
        finishPlayback(started: true)
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
        Task { @MainActor in self.playerEnded(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerEnded(id) }
    }
}
