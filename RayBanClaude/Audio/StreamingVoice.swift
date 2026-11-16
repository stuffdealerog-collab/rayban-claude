@preconcurrency import AVFoundation

/// Играет голос ElevenLabs по мере прихода: куски PCM сразу встают в очередь плеера,
/// поэтому ответ начинает звучать, пока Claude ещё дописывает его.
@MainActor
final class StreamingVoice {
    /// Весь присланный звук доигран (или воспроизведение не удалось продолжить).
    var onFinished: (() -> Void)?

    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var sampleRate = 24_000
    /// Нечётный байт на стыке кусков: сэмпл 16 бит не должен разорваться.
    private var leftover = Data()
    private var pendingFrames = 0
    private var bufferedBeforeStart = 0
    private var started = false
    private var inputEnded = false
    private var generation = 0
    private var watchdog: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?

    /// Сколько звука накопить перед стартом, чтобы первые слова не заикались.
    private let startBufferSeconds = 0.12

    var isActive: Bool { engine != nil }

    /// Готовит плеер к новой реплике.
    func begin(sampleRate: Int) {
        stop(notify: false)
        self.sampleRate = sampleRate
        generation += 1
    }

    /// Кусок PCM: 16 бит, моно, little-endian. Бросает ошибку, если плеер не удалось запустить.
    func append(_ pcm: Data) throws {
        var data = leftover + pcm
        if data.count % 2 == 1 {
            leftover = data.suffix(1)
            data.removeLast()
        } else {
            leftover = Data()
        }
        guard !data.isEmpty else { return }
        try prepareEngineIfNeeded()
        guard let node, let format else { return }

        let frames = data.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768
            }
        }

        pendingFrames += frames
        let current = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: Self.makeCompletion(
            owner: self, frames: frames, generation: current
        ))
        if !started {
            bufferedBeforeStart += frames
            if Double(bufferedBeforeStart) >= Double(sampleRate) * startBufferSeconds { startPlayback() }
        }
    }

    /// Звука больше не будет: доиграть очередь и сообщить о конце.
    func endOfInput() {
        guard engine != nil else {
            finish()
            return
        }
        inputEnded = true
        if !started, pendingFrames > 0 { startPlayback() }
        if pendingFrames == 0 {
            finish()
            return
        }
        // Колбэк конца мог потеряться (прерывание аудио) — не ждём вечно.
        let current = generation
        let limit = Double(pendingFrames) / Double(sampleRate) + 2.5
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == current else { return }
            journal("голос", "поток: конец не пришёл вовремя, завершаю")
            self.finish()
        }
    }

    /// Обрывает звук немедленно.
    func stop() {
        stop(notify: false)
    }

    private func stop(notify: Bool) {
        generation += 1
        watchdog?.cancel()
        watchdog = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.mainMixerNode.removeTap(onBus: 0)
            node?.stop()
            engine.stop()
        }
        engine = nil
        node = nil
        format = nil
        leftover = Data()
        pendingFrames = 0
        bufferedBeforeStart = 0
        started = false
        inputEnded = false
        AudioLevels.shared.output = 0
        if notify { onFinished?() }
    }

    private func finish() {
        stop(notify: true)
    }

    private func startPlayback() {
        started = true
        node?.play()
    }

    private func prepareEngineIfNeeded() throws {
        guard engine == nil else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
            throw StreamingVoiceError.format
        }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: nil, block: Self.makeMeterBlock())
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.node = node
        self.format = format

        // Смена маршрута (очки отключились) останавливает движок: доигрывать уже нечем.
        let current = generation
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                journal("голос", "поток: сменился аудиомаршрут, реплика оборвана")
                self.finish()
            }
        }
    }

    private func bufferPlayed(frames: Int, generation current: Int) {
        guard current == generation else { return }
        pendingFrames = max(0, pendingFrames - frames)
        if inputEnded, pendingFrames == 0 { finish() }
    }

    /// Колбэк плеера приходит на аудиопотоке — замыкание создаётся вне MainActor.
    private nonisolated static func makeCompletion(
        owner: StreamingVoice, frames: Int, generation: Int
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak owner] _ in
            Task { @MainActor in owner?.bufferPlayed(frames: frames, generation: generation) }
        }
    }

    /// Громкость голоса для решётки — считается на аудиопотоке.
    private nonisolated static func makeMeterBlock() -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for index in 0..<count {
                let sample = channel[index]
                sum += sample * sample
            }
            let rms = (sum / Float(count)).squareRoot()
            AudioLevels.shared.output = AudioLevels.normalize(decibels: 20 * log10(max(rms, 0.000_001)))
        }
    }
}

enum StreamingVoiceError: Error {
    case format
}
