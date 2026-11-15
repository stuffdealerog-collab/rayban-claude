import AVFoundation
import ClaudeKit

/// Голос iOS (AVSpeechSynthesizer): запасной, когда ElevenLabs не настроен или не ответил.
/// Звук идёт по текущему маршруту аудиосессии — при подключённых очках это их динамики.
@MainActor
final class SystemVoice: NSObject {
    var languageCode = "ru-RU" {
        didSet { cachedVoice = nil }
    }

    var isSpeaking: Bool { !activeUtterances.isEmpty }

    private var synthesizer = AVSpeechSynthesizer()
    /// Фразы держим сильными ссылками до колбэка: иначе адрес освобождённой фразы может достаться
    /// новой, и поздний колбэк старой «закончит» новую раньше времени.
    private var activeUtterances: [ObjectIdentifier: AVSpeechUtterance] = [:]
    /// Остановленные фразы, чей didCancel ещё не пришёл (по той же причине).
    private var cancellingUtterances: [ObjectIdentifier: AVSpeechUtterance] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var watchdog: Task<Void, Never>?
    private var cachedVoice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    /// Ставит фразу в очередь озвучки.
    func speak(_ text: String) {
        let clean = SpeechText.clean(text)
        guard !clean.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = voice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.05
        activeUtterances[ObjectIdentifier(utterance)] = utterance
        synthesizer.speak(utterance)
    }

    /// Немедленно прерывает речь.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        cancellingUtterances.merge(activeUtterances) { current, _ in current }
        if cancellingUtterances.count > 64 { cancellingUtterances.removeAll() } // колбэки для части фраз могут не прийти
        activeUtterances.removeAll()
        resumeWaiters()
    }

    /// После сброса медиасервисов iOS синтезатор нужно создать заново.
    func rebuildSynthesizer() {
        stop()
        synthesizer.delegate = nil
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        cancellingUtterances.removeAll()
    }

    /// Ждёт, пока прозвучат все фразы из очереди.
    func waitUntilFinished() async {
        guard isSpeaking else { return }
        startWatchdog()
        await withCheckedContinuation { waiters.append($0) }
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        cancellingUtterances[id] = nil
        activeUtterances[id] = nil
        if activeUtterances.isEmpty { resumeWaiters() }
    }

    private func resumeWaiters() {
        watchdog?.cancel()
        watchdog = nil
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    /// Если синтезатор замолчал, но не прислал didFinish (бывает при прерывании аудиосессии),
    /// не ждём вечно: две проверки подряд без речи — очередь считается пустой.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            var silentChecks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.synthesizer.isSpeaking {
                    silentChecks = 0
                } else {
                    silentChecks += 1
                }
                if silentChecks >= 2, self.isSpeaking {
                    self.activeUtterances.removeAll()
                    self.resumeWaiters()
                    return
                }
            }
        }
    }

    /// Лучший установленный голос для языка (premium > enhanced > default).
    private func voice() -> AVSpeechSynthesisVoice? {
        if let cachedVoice { return cachedVoice }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }
        let best = candidates.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: languageCode)
        cachedVoice = best
        return best
    }
}

extension SystemVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }
}
