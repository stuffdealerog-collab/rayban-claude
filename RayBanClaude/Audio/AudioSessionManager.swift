import AVFoundation

/// Настраивает общую аудиосессию. Два режима:
///
/// - **разговор** — запись + воспроизведение через Bluetooth HFP: очки работают как гарнитура,
///   их 5 микрофонов с шумоподавлением дают речевой сигнал 16 кГц. Пока открыт микрофон,
///   звук тоже идёт по HFP — моно и в «телефонном» качестве (ограничение Bluetooth);
/// - **ответ** — только воспроизведение: очки получают звук по A2DP, как музыку, — стерео
///   и полное качество. Используется в режиме кнопки, пока Claude думает и говорит.
@MainActor
final class AudioSessionManager {
    enum Mode { case inactive, conversation, playback }

    private(set) var mode: Mode = .inactive

    /// Звонок, Siri, другое приложение забрали аудио.
    var onInterruptionBegan: (() -> Void)?
    /// Прерывание закончилось — сессию и движок нужно поднять заново.
    var onInterruptionEnded: (() -> Void)?
    /// Медиасервисы iOS перезапустились — всё аудио надо создать заново.
    var onMediaServicesReset: (() -> Void)?
    /// Подключилось или отключилось устройство (например, очки).
    var onRouteChanged: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let reasonValue = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            Task { @MainActor in self?.handleInterruption(typeValue, reason: reasonValue) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onMediaServicesReset?() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reasonValue) }
        })
    }

    /// Режим разговора: микрофон очков и звук по HFP.
    func activate() throws {
        // .defaultToSpeaker — без очков звук идёт в динамик телефона, а не в разговорный.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        mode = .conversation
        preferGlassesInput()
    }

    /// Режим ответа: микрофон выключен, звук по A2DP (стерео, полное качество).
    /// Без очков звук идёт в динамик телефона.
    func activatePlayback() throws {
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        mode = .playback
    }

    /// Отпускает аудио: другие приложения (музыка, подкасты) могут продолжить играть.
    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        mode = .inactive
    }

    // MARK: - Звонок («На связи»)

    /// Звук звонка включила система (CallKit): микрофон и динамик доступны и в фоне.
    func callAudioActivated() {
        mode = .conversation
        preferGlassesInput()
        journal("звук", "звонок: звук включён, микрофон — \(inputDescription)")
    }

    func callAudioDeactivated() {
        mode = .inactive
    }

    /// После удержания (обычный звонок закончился) система не всегда включает звук сама.
    func reactivateForCall() -> Bool {
        do {
            try session.setActive(true)
            mode = .conversation
            preferGlassesInput()
            return true
        } catch {
            journal("звук", "вернуть звук звонка не удалось: \(error.localizedDescription)")
            return false
        }
    }

    /// Переводчик: фраза для собеседника звучит из динамика телефона, а не в очках.
    /// Работает только в режиме разговора. Возвращает, удалось ли переключить.
    @discardableResult
    func setPhoneSpeaker(_ enabled: Bool) -> Bool {
        guard mode == .conversation else { return false }
        do {
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
            journal("звук", enabled ? "перевод собеседнику: динамик телефона" : "звук возвращён в очки")
            if !enabled { preferGlassesInput() }
            return true
        } catch {
            journal("звук", "динамик телефона не включился: \(error.localizedDescription)")
            return false
        }
    }

    /// После переключения из A2DP канал гарнитуры (HFP) поднимается не сразу. Ждём его,
    /// чтобы первые слова не записались микрофоном телефона. Без очков возвращается сразу.
    func waitForGlassesInput(timeout: TimeInterval = 2) async {
        guard session.availableInputs?.contains(where: { $0.portType == .bluetoothHFP }) == true else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while !isUsingGlassesInput, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Выбирает микрофон очков, если они подключены. Иначе остаётся встроенный микрофон телефона.
    @discardableResult
    func preferGlassesInput() -> Bool {
        if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? session.setPreferredInput(glasses)
        }
        return isUsingGlassesInput
    }

    var isUsingGlassesInput: Bool {
        session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    }

    /// Человекочитаемое название текущего микрофона.
    var inputDescription: String {
        guard let input = session.currentRoute.inputs.first else { return L("нет") }
        return input.portType == .bluetoothHFP ? L("очки (%@)", input.portName) : L("телефон")
    }

    /// Задержка вывода (Bluetooth — до нескольких сотен миллисекунд): столько ещё звучит уже отданный звук.
    var outputLatency: TimeInterval { session.outputLatency }

    private func handleInterruption(_ typeValue: UInt?, reason: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        // С iOS 16 прерывание «приложение было приостановлено» не приходит; на случай старых
        // систем пропускаем его по сырому значению (1) — это не звонок.
        if reason == 1 { return }
        switch type {
        case .began: onInterruptionBegan?()
        case .ended: onInterruptionEnded?()
        @unknown default: break
        }
    }

    private func handleRouteChange(_ reasonValue: UInt?) {
        guard let reasonValue, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            preferGlassesInput()
            onRouteChanged?()
        default:
            break
        }
    }
}
