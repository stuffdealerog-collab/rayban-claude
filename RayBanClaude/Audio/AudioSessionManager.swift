import AVFoundation

/// Настраивает общую аудиосессию: запись + воспроизведение через Bluetooth HFP очков.
///
/// Очки подключаются к iPhone как гарнитура (HFP): их 5 микрофонов с шумоподавлением дают
/// речевой сигнал 16 кГц, а синтезированный ответ звучит в динамиках очков. Пока открыт
/// микрофон, воспроизведение тоже идёт по HFP (моно) — это ограничение Bluetooth.
@MainActor
final class AudioSessionManager {
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
            Task { @MainActor in self?.handleInterruption(typeValue) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onMediaServicesReset?() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reasonValue) }
        })
    }

    func activate() throws {
        // .defaultToSpeaker — без очков звук идёт в динамик телефона, а не в разговорный.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        preferGlassesInput()
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
        guard let input = session.currentRoute.inputs.first else { return "нет" }
        return input.portType == .bluetoothHFP ? "очки (\(input.portName))" : "телефон"
    }

    private func handleInterruption(_ typeValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
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
