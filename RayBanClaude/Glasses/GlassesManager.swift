import Foundation
import MWDATCamera
import MWDATCore
import MWDATInputs
import Observation
import UIKit

enum GlassesError: LocalizedError {
    case notRegistered
    case noDevice
    case sessionFailed(String)
    case sessionTimeout
    case cameraPermissionRequired
    case cameraUnavailable(String?)
    case photoTimeout
    case photoFailed(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .notRegistered: return "Приложение не подключено к очкам через Meta AI."
        case .noDevice: return "Очки не найдены. Разложите дужки и проверьте Bluetooth."
        case .sessionFailed(let reason): return "Не удалось подключиться к очкам: \(reason)"
        case .sessionTimeout: return "Очки не ответили вовремя."
        case .cameraPermissionRequired: return "Нет разрешения на камеру очков. Откройте приложение и нажмите «Разрешить камеру»."
        case .cameraUnavailable(let reason): return "Камера очков недоступна" + (reason.map { ": \($0)" } ?? ".")
        case .photoTimeout: return "Снимок не пришёл с очков вовремя."
        case .photoFailed(let reason): return "Не удалось сделать снимок: \(reason)"
        case .busy: return "Камера занята предыдущим снимком."
        }
    }
}

/// Жест на очках (экспериментальный модуль Inputs из DAT).
enum GlassesGesture: String, Sendable {
    case doubleTap = "двойное касание дужки"
    case capture = "кнопка камеры"
    case captureHold = "удержание кнопки камеры"
    case captureDouble = "двойное нажатие кнопки камеры"
    case action = "кнопка действия"
}

/// Связь с очками через Meta Wearables Device Access Toolkit:
/// регистрация в Meta AI, сессия устройства, видеопоток камеры и снимки.
@MainActor
@Observable
final class GlassesManager {
    private(set) var registrationState: RegistrationState
    private(set) var hasActiveDevice = false
    private(set) var batteryLevel: Int?
    private(set) var sessionState: DeviceSessionState?
    private(set) var streamState: StreamState?
    private(set) var cameraPermissionGranted: Bool?
    private(set) var previewImage: UIImage?
    private(set) var lastError: String?

    var isRegistered: Bool { registrationState == .registered }
    var isStreaming: Bool { streamState == .streaming }

    @ObservationIgnored private let wearables: any WearablesInterface
    @ObservationIgnored private let selector: AutoDeviceSelector
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var sessionObservers: [Task<Void, Never>] = []
    @ObservationIgnored private var lastSessionError: String?
    @ObservationIgnored private var sessionSetup: Task<DeviceSession, Error>?
    @ObservationIgnored private var camera: Camera?
    @ObservationIgnored private var streamHasStarted = false
    @ObservationIgnored private var lastStreamError: String?
    @ObservationIgnored private var streamSetup: Task<MWDATCamera.Stream, Error>?
    @ObservationIgnored private let streamTokens = ListenerTokenBag()
    @ObservationIgnored private let latestFrame = LatestFrameBox()
    @ObservationIgnored private var pendingPhoto: (id: UUID, continuation: CheckedContinuation<Data, Error>)?
    /// Снимки, которые уже не ждут (таймаут/отмена), но ещё могут прийти: их надо выбросить.
    @ObservationIgnored private var abandonedCaptures: [Date] = []
    @ObservationIgnored private var lastPermissionCheck = Date.distantPast
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    // Эксперимент: касания и кнопки очков
    /// Жест с очков: двойное касание дужки, кнопка камеры.
    @ObservationIgnored var onGesture: ((GlassesGesture) -> Void)?
    private(set) var gesturesActive = false
    @ObservationIgnored private var gesturesWanted = false
    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputRetry: Task<Void, Never>?
    @ObservationIgnored private let inputTokens = ListenerTokenBag()
    @ObservationIgnored private var deviceStateToken: (any AnyListenerToken)?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []

    /// Через сколько секунд без снимков гасить камеру и сессию (экономия батареи очков).
    private let idleTimeout: UInt64 = 90

    init(wearables: any WearablesInterface = Wearables.shared) {
        self.wearables = wearables
        self.registrationState = wearables.registrationState
        self.selector = AutoDeviceSelector(wearables: wearables)

        let registrationStream = wearables.registrationStateStream()
        observers.append(Task { [weak self] in
            for await state in registrationStream {
                self?.registrationState = state
            }
        })
        let deviceStream = selector.activeDeviceStream()
        observers.append(Task { [weak self] in
            for await deviceId in deviceStream {
                self?.activeDeviceChanged(deviceId)
            }
        })
    }

    private func activeDeviceChanged(_ deviceId: DeviceIdentifier?) {
        hasActiveDevice = deviceId != nil
        let previousToken = deviceStateToken
        deviceStateToken = nil
        Task { await previousToken?.cancel() }

        guard let deviceId, let device = wearables.deviceForIdentifier(deviceId) else {
            batteryLevel = nil
            return
        }
        batteryLevel = device.batteryLevel
        // Затем — каждое изменение состояния устройства.
        deviceStateToken = device.addDeviceStateListener { [weak self] state in
            let level = state.batteryLevel
            Task { @MainActor in self?.batteryLevel = level }
        }
    }

    // MARK: - Registration

    /// Открывает Meta AI, где пользователь подтверждает подключение приложения к очкам.
    func connect() async {
        do {
            try await wearables.startRegistration()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        shutdown()
        do {
            try await wearables.startUnregistration()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Обрабатывает возврат из Meta AI (`<scheme>://...?metaWearablesAction=...`).
    func handle(url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else { return }
        do {
            _ = try await wearables.handleUrl(url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Тихая проверка разрешения (без перехода в Meta AI) — для UI.
    func refreshCameraPermission() async {
        guard isRegistered else { return }
        _ = try? await checkCameraPermission()
    }

    /// Флаг меняется только по успешному ответу: временная ошибка связи — не «нет разрешения».
    private func checkCameraPermission() async throws -> Bool {
        let granted = try await wearables.checkPermissionStatus(.camera) == .granted
        cameraPermissionGranted = granted
        lastPermissionCheck = Date()
        return granted
    }

    /// Запрос разрешения на камеру (переключает на Meta AI). Вызывать только по нажатию пользователя.
    func requestCameraPermission() async {
        do {
            cameraPermissionGranted = try await wearables.requestPermission(.camera) == .granted
            lastPermissionCheck = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Session

    /// Одна сессия на всех: параллельные вызовы ждут одну и ту же установку.
    private func ensureSession() async throws -> DeviceSession {
        if let sessionSetup { return try await Self.awaitCancellable(sessionSetup) }
        if let session {
            switch session.state {
            case .started:
                return session
            case .starting, .paused:
                try await waitForSessionStart(session, timeout: 15)
                return session
            default:
                dropSession()
            }
        }

        let setup = Task { try await self.startSession() }
        sessionSetup = setup
        defer { sessionSetup = nil }
        return try await Self.awaitCancellable(setup)
    }

    /// Ждёт общую задачу установки и отменяет её вместе с вызывающим ходом: иначе прерванный
    /// ход держал бы очередь ClaudeKit до таймаутов (20 + 15 с). Все ожидающие — из одного хода.
    private static func awaitCancellable<T: Sendable>(_ task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func startSession() async throws -> DeviceSession {
        guard isRegistered else { throw GlassesError.notRegistered }
        guard hasActiveDevice || selector.activeDevice != nil else { throw GlassesError.noDevice }

        let session = try wearables.createSession(deviceSelector: selector)
        lastSessionError = nil
        // Подписываемся до start(), чтобы не пропустить первые переходы.
        let states = session.stateStream()
        let errors = session.errorStream()
        sessionObservers = [
            Task { [weak self] in
                for await state in states {
                    self?.sessionStateChanged(state, session: session)
                }
            },
            Task { [weak self] in
                for await error in errors {
                    self?.lastSessionError = error.localizedDescription
                }
            },
        ]
        self.session = session

        do {
            try session.start()
            try await waitForSessionStart(session, timeout: 20)
        } catch {
            dropSession()
            throw error
        }
        return session
    }

    /// Сессия, остановившаяся во время ожидания, — это ошибка, а не повод ждать до таймаута.
    private func waitForSessionStart(_ session: DeviceSession, timeout: Double) async throws {
        try await waitUntil(timeout: timeout, success: { session.state == .started }, failure: {
            guard session.state == .stopped else { return nil }
            return GlassesError.sessionFailed(lastSessionError ?? "сессия остановлена")
        })
    }

    private func sessionStateChanged(_ state: DeviceSessionState, session: DeviceSession) {
        guard session === self.session else { return }
        sessionState = state
        if state == .stopped {
            // Сессию остановило устройство (сложили дужки, другое приложение и т. п.).
            dropSession()
        }
    }

    // MARK: - Жесты (эксперимент)

    /// Слушать касания и кнопки очков. Пока включено, сеанс с очками не закрывается по простою.
    /// Одиночное касание и удержание дужки очки оставляют себе (пауза и стоп сеанса).
    func setGestures(_ enabled: Bool) async {
        gesturesWanted = enabled
        inputRetry?.cancel()
        if enabled {
            await attachInputs()
        } else {
            detachInputs()
            if camera == nil { scheduleIdleShutdown() }
        }
    }

    private func attachInputs() async {
        guard gesturesWanted, inputs == nil, isRegistered else { return }
        do {
            let session = try await ensureSession()
            idleTask?.cancel()
            let configuration = InputsConfiguration(sources: [.captouch, .captureButton, .actionButton], consumeBack: false)
            guard let inputs = try session.addInputs(configuration: configuration) else {
                journal("очки", "жесты: эти очки о них не сообщают")
                return
            }
            self.inputs = inputs
            inputs.statePublisher.listen { [weak self] state in
                journal("очки", "жесты: \(state)")
                Task { @MainActor in self?.gesturesActive = state == .active }
            }.store(in: inputTokens)
            inputs.errorPublisher.listen { error in
                journal("очки", "жесты: ошибка — \(error.description)")
            }.store(in: inputTokens)
            let events = inputs.events
            inputTask = Task { [weak self] in
                for await event in events { self?.handleInput(event) }
                journal("очки", "жесты: поток событий закончился")
            }
        } catch {
            journal("очки", "жесты не подключились: \(error.localizedDescription)")
            retryInputsLater()
        }
    }

    private func detachInputs() {
        inputTask?.cancel()
        inputTask = nil
        inputTokens.clear()
        if inputs != nil, let session, session.state == .started {
            try? session.removeInputs()
        }
        inputs = nil
        gesturesActive = false
    }

    /// Сеанс закрыли сами очки (сложили дужки, удержали касание) — пробуем вернуться.
    private func retryInputsLater() {
        guard gesturesWanted else { return }
        inputRetry?.cancel()
        inputRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.attachInputs()
        }
    }

    private func handleInput(_ event: InputEvent) {
        // В журнал идёт всё: какие жесты очки присылают на самом деле, известно только с устройства.
        journal("очки", "жест: \(event)")
        switch event {
        case .select:
            onGesture?(.doubleTap)
        case .capture(let press, _, _):
            switch press {
            case .shortPress: onGesture?(.capture)
            case .hold: onGesture?(.captureHold)
            case .doublePress: onGesture?(.captureDouble)
            }
        case .button:
            onGesture?(.action)
        case .nav, .back, .drag:
            break
        @unknown default:
            break
        }
    }

    /// Останавливает и забывает сессию вместе с камерой.
    private func dropSession() {
        stopCamera()
        if inputs != nil {
            inputTask?.cancel()
            inputTask = nil
            inputTokens.clear()
            inputs = nil
            gesturesActive = false
            retryInputsLater()
        }
        if let session, session.state != .stopped, session.state != .stopping {
            session.stop()
        }
        session = nil
        sessionState = nil
        sessionObservers.forEach { $0.cancel() }
        sessionObservers = []
    }

    /// Полностью отключается от очков (камера + сессия).
    func shutdown() {
        idleTask?.cancel()
        dropSession()
    }

    // MARK: - Camera

    private func ensureStreaming() async throws -> MWDATCamera.Stream {
        // Таймер простоя не должен сработать посреди установки; после неё (и после ошибки) — заводим заново,
        // чтобы сессия не осталась открытой навсегда.
        idleTask?.cancel()
        defer { scheduleIdleShutdown() }
        if let streamSetup { return try await Self.awaitCancellable(streamSetup) }
        let setup = Task { try await self.startStreaming() }
        streamSetup = setup
        defer { streamSetup = nil }
        return try await Self.awaitCancellable(setup)
    }

    private func startStreaming() async throws -> MWDATCamera.Stream {
        let session = try await ensureSession()

        // «Разрешить один раз» действует одну сессию, поэтому периодически перепроверяем (запрос тихий).
        if cameraPermissionGranted != true || Date().timeIntervalSince(lastPermissionCheck) > 60 {
            guard try await checkCameraPermission() else { throw GlassesError.cameraPermissionRequired }
        }

        let camera: Camera
        if let existing = self.camera {
            camera = existing
        } else {
            // Средняя чёткость и 15 к/с: меньше сжатия по Bluetooth, кадр годится как запасной снимок.
            let configuration = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)
            guard let created = try session.addCamera(config: configuration) else {
                throw GlassesError.cameraUnavailable("сессия ещё не запущена")
            }
            self.camera = created
            streamHasStarted = false
            lastStreamError = nil
            subscribe(to: created.stream)
            camera = created
        }

        let stream = camera.stream
        switch stream.state {
        case .streaming:
            break
        case .paused, .starting, .waitingForDevice:
            // На паузе поток не перезапускаем — ждём, пока устройство само его возобновит.
            try await waitForStreaming(stream)
        case .stopped, .stopping:
            stream.start()
            try await waitForStreaming(stream)
        }
        scheduleIdleShutdown()
        return stream
    }

    private func waitForStreaming(_ stream: MWDATCamera.Stream) async throws {
        let started = Date()
        try await waitUntil(timeout: 15, success: { stream.state == .streaming }, failure: {
            // Сразу после start() состояние ещё может быть .stopped — даём ему время смениться.
            guard stream.state == .stopped, Date().timeIntervalSince(started) > 1.5 else { return nil }
            return GlassesError.cameraUnavailable(lastStreamError)
        })
    }

    private func subscribe(to stream: MWDATCamera.Stream) {
        let frames = latestFrame
        stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.streamStateChanged(state, stream: stream) }
        }.store(in: streamTokens)

        stream.videoFramePublisher.listen { [weak self] frame in
            // Превью и запасной кадр обновляем не чаще ~4 раз в секунду.
            guard frames.shouldProcessFrame() else { return }
            guard let image = frame.makeUIImage() else { return }
            frames.store(image)
            Task { @MainActor in self?.previewImage = image }
        }.store(in: streamTokens)

        stream.photoDataPublisher.listen { [weak self] photo in
            let data = photo.data
            Task { @MainActor in self?.deliverPhoto(data) }
        }.store(in: streamTokens)

        stream.errorPublisher.listen { [weak self] error in
            let message = error.localizedDescription
            let permissionDenied = error == .permissionDenied
            Task { @MainActor in self?.streamFailed(message, permissionDenied: permissionDenied, stream: stream) }
        }.store(in: streamTokens)
    }

    private func streamStateChanged(_ state: StreamState, stream: MWDATCamera.Stream) {
        guard camera?.stream === stream else { return }
        streamState = state
        switch state {
        case .waitingForDevice, .starting, .streaming:
            streamHasStarted = true
        case .stopped:
            // Поток остановился сам (ошибка, перегрев, дужки): камеру надо отсоединить,
            // иначе следующий addCamera() не создаст новую (остановка не идёт от потомка к родителю).
            if streamHasStarted { stopCamera() }
        default:
            break
        }
    }

    private func streamFailed(_ message: String, permissionDenied: Bool, stream: MWDATCamera.Stream) {
        guard camera?.stream === stream else { return }
        lastStreamError = message
        lastError = message
        if permissionDenied { cameraPermissionGranted = false }
        failPendingPhoto(GlassesError.photoFailed(message))
    }

    func stopCamera() {
        camera?.stop()
        camera = nil
        streamHasStarted = false
        streamTokens.clear()
        streamState = nil
        previewImage = nil
        latestFrame.clear()
        abandonedCaptures.removeAll()
        failPendingPhoto(GlassesError.cameraUnavailable(nil))
    }

    private func scheduleIdleShutdown() {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            // Пока слушаем жесты, сеанс нужен постоянно.
            guard !Task.isCancelled, self?.gesturesWanted != true else { return }
            self?.dropSession()
        }
    }

    // MARK: - Photo

    /// Снимок для Claude: JPEG, уменьшенный до 1568 px по длинной стороне
    /// (больше API всё равно не использует, а меньший файл быстрее уходит в сеть).
    func photoForAssistant() async throws -> Data {
        let stream = try await ensureStreaming()

        let original: UIImage
        do {
            let data = try await capturePhoto(on: stream)
            guard let image = UIImage(data: data) else { throw GlassesError.photoFailed("не удалось декодировать JPEG") }
            original = image
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Запасной вариант — свежий кадр видеопотока (до 720p, но мгновенно). Старый кадр не годится:
            // Claude описал бы прошлую сцену как текущую.
            guard let frame = latestFrame.image(maxAge: 2) else { throw error }
            original = frame
        }
        guard let jpeg = original.resizedJPEG(maxDimension: 1568, quality: 0.8) else {
            throw GlassesError.photoFailed("не удалось сжать изображение")
        }
        return jpeg
    }

    private func capturePhoto(on stream: MWDATCamera.Stream) async throws -> Data {
        guard pendingPhoto == nil else { throw GlassesError.busy }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingPhoto = (id, continuation)
                guard !Task.isCancelled else {
                    failPendingPhoto(CancellationError())
                    return
                }
                guard stream.capturePhoto(format: .jpeg) else {
                    failPendingPhoto(GlassesError.busy)
                    return
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard let self, self.pendingPhoto?.id == id else { return }
                    // После 8 с снимок уже вряд ли придёт — не помечаем его к выбросу,
                    // иначе пострадал бы следующий настоящий снимок.
                    self.failPendingPhoto(GlassesError.photoTimeout)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.pendingPhoto?.id == id else { return }
                self.abandonPendingPhoto(CancellationError())
            }
        }
    }

    private func deliverPhoto(_ data: Data) {
        // Снимки приходят по порядку: если недавно отменён запрос, это его снимок.
        abandonedCaptures.removeAll { Date().timeIntervalSince($0) > 5 }
        if !abandonedCaptures.isEmpty {
            abandonedCaptures.removeFirst()
            return
        }
        guard let pending = pendingPhoto else { return }
        pendingPhoto = nil
        pending.continuation.resume(returning: data)
    }

    /// Ожидание снимка отменено, но очки ещё могут прислать его в ближайшие секунды — запоминаем, чтобы выбросить.
    private func abandonPendingPhoto(_ error: Error) {
        guard pendingPhoto != nil else { return }
        abandonedCaptures.append(Date())
        failPendingPhoto(error)
    }

    private func failPendingPhoto(_ error: Error) {
        guard let pending = pendingPhoto else { return }
        pendingPhoto = nil
        pending.continuation.resume(throwing: error)
    }

    // MARK: - Helpers

    private func waitUntil(timeout seconds: Double, success: () -> Bool, failure: () -> Error?) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !success() {
            try Task.checkCancellation()
            if let error = failure() { throw error }
            guard Date() < deadline else { throw GlassesError.sessionTimeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

/// Последний кадр видеопотока; пишется из потока SDK, читается с главного.
private final class LatestFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (image: UIImage, time: Date)?
    private var lastProcessed = Date.distantPast

    /// Кадр не старше `maxAge` секунд.
    func image(maxAge: TimeInterval) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, Date().timeIntervalSince(latest.time) <= maxAge else { return nil }
        return latest.image
    }

    func shouldProcessFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= 0.25 else { return false }
        lastProcessed = now
        return true
    }

    func store(_ image: UIImage) {
        lock.lock()
        latest = (image, Date())
        lock.unlock()
    }

    func clear() {
        lock.lock()
        latest = nil
        lastProcessed = .distantPast
        lock.unlock()
    }
}

extension UIImage {
    func resizedJPEG(maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return jpegData(compressionQuality: quality) }
        let scale = maxDimension / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
