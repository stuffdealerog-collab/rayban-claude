@preconcurrency import AVFoundation
import CallKit

/// «На связи»: разговор с ассистентом оформлен как звонок через CallKit.
///
/// Зачем: iOS не даёт приложению включить микрофон, когда оно уже в фоне. Единственное исключение
/// для обычных приложений — звонки. Пока идёт такой «звонок», микрофон работает с заблокированным
/// экраном, а очки ведут себя как при телефонном разговоре. Позвонить можно в обе стороны:
/// пользователь — кнопкой в приложении, ассистент — входящим вызовом (в том числе из фона).
///
/// Правило CallKit: аудиосессию включает система (`didActivate`), а не приложение.
@MainActor
final class CallSession: NSObject {
    enum State: Equatable {
        case idle
        /// Входящий вызов звонит.
        case ringing
        /// Вызов принят или начат, система ещё не включила звук.
        case connecting
        case active
        /// Удержание: пришёл обычный телефонный звонок.
        case held
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            journal("звонок", "состояние: \(state)")
            onStateChanged?(state)
        }
    }

    var onStateChanged: ((State) -> Void)?
    /// Система включила звук для звонка: можно запускать микрофон.
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?
    /// Вызов снят с удержания: звук нужно вернуть самим (система не всегда делает это сама).
    var onResumed: (() -> Void)?

    var isOngoing: Bool { state != .idle }

    private let provider: CXProvider
    private let controller = CXCallController()
    private var callID: UUID?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        // «Звонки» ассистенту не должны засорять список недавних в Телефоне.
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    /// Пользователь звонит ассистенту. Работает, только пока приложение на экране.
    func startOutgoing(name: String) async throws {
        guard !isOngoing else { return }
        let id = UUID()
        callID = id
        state = .connecting
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: name))
        action.isVideo = false
        action.contactIdentifier = name
        do {
            try await controller.request(CXTransaction(action: action))
        } catch {
            journal("звонок", "исходящий не начался: \(error.localizedDescription)")
            callID = nil
            state = .idle
            throw error
        }
    }

    /// Ассистент звонит пользователю: очки и телефон звонят, приём вызова включает микрофон.
    /// Работает и из фона, пока процесс приложения жив.
    func ring(name: String) async throws {
        guard !isOngoing else { return }
        let id = UUID()
        callID = id
        state = .ringing
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        do {
            try await provider.reportNewIncomingCall(with: id, update: update)
            journal("звонок", "входящий показан")
        } catch {
            // Например, включён режим «Не беспокоить» или звонки от приложения запрещены.
            journal("звонок", "входящий отклонён системой: \(error.localizedDescription)")
            callID = nil
            state = .idle
            throw error
        }
    }

    /// Завершить разговор.
    func end() {
        guard let id = callID else { return }
        Task {
            do {
                try await controller.request(CXTransaction(action: CXEndCallAction(call: id)))
            } catch {
                journal("звонок", "завершение через систему не прошло: \(error.localizedDescription)")
                provider.reportCall(with: id, endedAt: nil, reason: .remoteEnded)
                finish()
            }
        }
    }

    /// Звук вернули сами после удержания (система `didActivate` не прислала).
    func markActive() {
        guard callID != nil else { return }
        state = .active
    }

    private func finish() {
        callID = nil
        state = .idle
    }

    /// Категория аудио для звонка. Включать сессию нельзя — это сделает система.
    private func configureAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        } catch {
            journal("звонок", "категория аудио не задана: \(error.localizedDescription)")
        }
    }
}

extension CallSession: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            journal("звонок", "система сбросила звонки")
            finish()
            onAudioDeactivated?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            configureAudio()
            // Незавершённое действие через несколько минут обрывает звонок по таймауту.
            action.fulfill()
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            journal("звонок", "вызов принят")
            configureAudio()
            state = .connecting
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            journal("звонок", "вызов завершён")
            action.fulfill()
            finish()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        MainActor.assumeIsolated {
            action.fulfill()
            if action.isOnHold {
                state = .held
            } else {
                state = .connecting
                onResumed?()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            // Касания дужки во время звонка могут приходить как «выключить микрофон» — смотрим в журнале.
            journal("звонок", "микрофон: \(action.isMuted ? "выключен" : "включён") (команда гарнитуры или экрана)")
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        MainActor.assumeIsolated {
            journal("звонок", "тональный сигнал: \(action.digits)")
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        MainActor.assumeIsolated {
            journal("звонок", "действие не выполнено вовремя: \(type(of: action))")
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            journal("звонок", "система включила звук")
            state = .active
            onAudioActivated?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            journal("звонок", "система выключила звук")
            onAudioDeactivated?()
        }
    }
}
