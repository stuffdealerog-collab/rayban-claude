import Foundation
import Network

/// Байтовый канал до IMAP-сервера. Вынесен в протокол, чтобы логику клиента можно было тестировать без сети.
protocol IMAPTransport: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    /// Очередная порция данных; `nil` — сервер закрыл соединение.
    func receive() async throws -> Data?
    /// Взводит таймер: по истечении все ожидания завершатся `MailError.timeout`, соединение закроется.
    func armDeadline(_ seconds: TimeInterval)
    func disarmDeadline()
    func close()
}

/// TLS-соединение через Network.framework (порт 993, IMAP over TLS).
/// Колбэки NWConnection переводятся в async через продолжения; одновременно ждём не больше одной операции
/// (клиент-актор сериализует команды). Таймаут и отмена задачи будят ожидающего и рвут соединение.
final class NWIMAPTransport: IMAPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "AssistantCore.IMAPTransport")

    // Состояние под `lock`.
    private let lock = NSLock()
    private var failure: (any Error)?
    private var pending: (id: UInt64, continuation: CheckedContinuation<Data?, any Error>)?
    private var operationCounter: UInt64 = 0
    private var deadlineGeneration: UInt64 = 0

    init(host: String, port: Int, connectTimeout: TimeInterval) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(connectTimeout.rounded(.up)))
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .imaps
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
    }

    deinit {
        connection.cancel()
    }

    func start() async throws {
        _ = try await perform { [connection, queue] id in
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleState(state, startID: id)
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        _ = try await perform { [connection] id in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.fail(Self.mailError(error))
                } else {
                    self?.complete(id, with: .success(nil))
                }
            })
        }
    }

    func receive() async throws -> Data? {
        try await perform { [connection] id in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.complete(id, with: .success(data))
                } else if let error {
                    self.fail(Self.mailError(error))
                } else {
                    // Пустой кусок без EOF вернём как пустые данные: вызывающий просто прочитает ещё раз.
                    self.complete(id, with: .success(isComplete ? nil : Data()))
                }
            }
        }
    }

    func armDeadline(_ seconds: TimeInterval) {
        let generation = lock.withLock {
            deadlineGeneration &+= 1
            return deadlineGeneration
        }
        queue.asyncAfter(deadline: .now() + max(0.1, seconds)) { [weak self] in
            guard let self else { return }
            let expired = self.lock.withLock { self.deadlineGeneration == generation }
            if expired { self.fail(MailError.timeout) }
        }
    }

    func disarmDeadline() {
        lock.withLock { deadlineGeneration &+= 1 }
    }

    func close() {
        fail(MailError.connectionFailed("соединение закрыто"))
    }

    // MARK: - Внутреннее

    /// Регистрирует единственное ожидание и запускает операцию; результат придёт через `complete` или `fail`.
    private func perform(_ operation: (UInt64) -> Void) async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                let registration: Result<UInt64, any Error> = lock.withLock {
                    if let failure { return .failure(failure) }
                    operationCounter &+= 1
                    pending = (operationCounter, continuation)
                    return .success(operationCounter)
                }
                switch registration {
                case .success(let id): operation(id)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            self.fail(CancellationError())
        }
    }

    private func complete(_ id: UInt64, with result: Result<Data?, any Error>) {
        let continuation: CheckedContinuation<Data?, any Error>? = lock.withLock {
            guard let current = pending, current.id == id else { return nil }
            pending = nil
            return current.continuation
        }
        continuation?.resume(with: result)
    }

    /// Переводит канал в состояние ошибки навсегда: будит ожидающего и закрывает соединение.
    private func fail(_ error: any Error) {
        let (continuation, reason): (CheckedContinuation<Data?, any Error>?, any Error) = lock.withLock {
            if failure == nil { failure = error }
            let waiting = pending?.continuation
            pending = nil
            return (waiting, failure ?? error)
        }
        continuation?.resume(throwing: reason)
        connection.cancel()
    }

    private func handleState(_ state: NWConnection.State, startID: UInt64) {
        switch state {
        case .ready:
            complete(startID, with: .success(nil))
        case .failed(let error), .waiting(let error):
            // .waiting — нет сети/сервер недоступен: голосовому ассистенту лучше сразу сказать об этом.
            fail(Self.mailError(error))
        case .cancelled:
            fail(MailError.connectionFailed("соединение закрыто"))
        default:
            break
        }
    }

    static func mailError(_ error: NWError) -> MailError {
        if case .dns = error {
            return .connectionFailed("не удалось найти сервер")
        }
        if case .tls(let status) = error {
            return .connectionFailed("ошибка защищённого соединения (TLS \(status))")
        }
        if case .posix(let code) = error {
            switch code {
            case .ETIMEDOUT: return .timeout
            case .ECONNREFUSED: return .connectionFailed("сервер отклонил подключение")
            case .ENETDOWN, .ENETUNREACH, .ENOTCONN: return .connectionFailed("нет сети")
            case .EHOSTUNREACH, .EHOSTDOWN: return .connectionFailed("сервер недоступен")
            case .ECONNRESET, .EPIPE: return .connectionFailed("соединение сброшено")
            case .ECANCELED: return .connectionFailed("соединение закрыто")
            default: return .connectionFailed(String(cString: strerror(code.rawValue)))
            }
        }
        return .connectionFailed(error.localizedDescription)
    }
}
