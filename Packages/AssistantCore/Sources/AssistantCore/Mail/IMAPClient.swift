import Foundation

/// Минимальный IMAP-клиент только для чтения: вход по паролю приложения, список писем, текст письма.
/// Папка открывается через EXAMINE (read-only), тела берутся через BODY.PEEK — письма не помечаются прочитанными.
/// Соединение переиспользуется между вызовами; команды выполняются строго по очереди.
public actor IMAPClient {
    /// Предел числа писем в одном списке.
    static let maxSummaryCount = 100
    /// Сколько байт начала тела берём для сниппета.
    static let snippetPrefixBytes = 3000
    /// Предел размера письма для `message(uid:)`.
    static let fullMessageByteLimit = 512 * 1024

    private let account: MailAccount
    private let password: String
    private let timeout: TimeInterval
    private let makeTransport: @Sendable () -> any IMAPTransport

    private var transport: (any IMAPTransport)?
    private var framer = IMAPFramer()
    private var tagCounter = 0
    private var byeText: String?

    // Очередь операций: одна команда на соединении в каждый момент.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(account: MailAccount, password: String, timeout: TimeInterval = 20) {
        let timeout = max(1, timeout)
        self.init(account: account, password: password, timeout: timeout) {
            NWIMAPTransport(host: account.host, port: account.port, connectTimeout: timeout)
        }
    }

    init(
        account: MailAccount,
        password: String,
        timeout: TimeInterval,
        transportFactory: @escaping @Sendable () -> any IMAPTransport
    ) {
        self.account = account
        self.password = password
        self.timeout = timeout
        self.makeTransport = transportFactory
    }

    deinit {
        transport?.close()
    }

    // MARK: - Публичный API

    /// Письма, новые первыми. `unreadOnly` — только непрочитанные (UID SEARCH UNSEEN), иначе последние `limit`.
    /// `query` — поиск SEARCH TEXT по заголовкам и телу (UTF-8).
    public func recentMessages(
        mailbox: String = "INBOX",
        unreadOnly: Bool,
        limit: Int,
        query: String? = nil
    ) async throws -> [MailSummary] {
        try await exclusive {
            try await self.loadSummaries(mailbox: mailbox, unreadOnly: unreadOnly, limit: limit, query: query)
        }
    }

    /// Письмо целиком: текст text/plain (или HTML без разметки), обрезанный до `maxLength` символов.
    public func message(uid: UInt32, mailbox: String = "INBOX", maxLength: Int = 4000) async throws -> MailMessage {
        try await exclusive {
            try await self.loadMessage(uid: uid, mailbox: mailbox, maxLength: maxLength)
        }
    }

    /// Вежливо завершает сессию (LOGOUT) и закрывает соединение.
    public func close() async {
        await acquire()
        defer { release() }
        guard let current = transport else { return }
        _ = try? await execute([.text("LOGOUT")], timeout: min(timeout, 5))
        current.close()
        transport = nil
    }

    // MARK: - Операции

    private func loadSummaries(mailbox: String, unreadOnly: Bool, limit: Int, query: String?) async throws -> [MailSummary] {
        let limit = min(max(limit, 1), Self.maxSummaryCount)
        let searchText = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = searchText?.isEmpty == false ? searchText : nil

        try await ensureSession()
        let exists = try await examine(mailbox)

        let items = "(UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(MailAssembler.summaryHeaderFields))] "
            + "BODY.PEEK[TEXT]<0.\(Self.snippetPrefixBytes)>)"
        let command: String
        var wanted: Set<UInt32>?
        if unreadOnly || text != nil {
            let uids = try await searchUIDs(unseen: unreadOnly, text: text)
            let newest = Array(uids.sorted(by: >).prefix(limit))
            guard !newest.isEmpty else { return [] }
            wanted = Set(newest)
            command = "UID FETCH \(IMAPCommandEncoder.sequenceSet(newest)) \(items)"
        } else {
            guard exists > 0 else { return [] }
            let first = exists > UInt32(limit) ? exists - UInt32(limit) + 1 : 1
            command = "FETCH \(first):\(exists) \(items)"
        }

        let result = try await execute([.text(command)])
        try result.requireOK("не удалось получить список писем")
        let summaries = IMAPFetchItem.collect(from: result.untagged)
            .compactMap(MailAssembler.summary(from:))
            .filter { wanted?.contains($0.uid) ?? true }
        return Array(summaries.sorted { $0.uid > $1.uid }.prefix(limit))
    }

    private func loadMessage(uid: UInt32, mailbox: String, maxLength: Int) async throws -> MailMessage {
        guard uid > 0 else { throw MailError.notFound }
        try await ensureSession()
        _ = try await examine(mailbox)
        let result = try await execute([.text("UID FETCH \(uid) (UID FLAGS INTERNALDATE BODY.PEEK[]<0.\(Self.fullMessageByteLimit)>)")])
        try result.requireOK("не удалось получить письмо")
        guard let item = IMAPFetchItem.collect(from: result.untagged).first(where: { $0.uid == uid }),
              let raw = item.section("") else {
            throw MailError.notFound
        }
        return MailAssembler.message(uid: uid, raw: raw, internalDate: item.internalDate, maxLength: maxLength)
    }

    /// EXAMINE — открыть папку только для чтения. Возвращает число писем (EXISTS).
    private func examine(_ mailbox: String) async throws -> UInt32 {
        let name = IMAPCommandEncoder.mailboxName(mailbox)
        let result = try await execute([.text("EXAMINE "), IMAPCommandEncoder.astring(name)])
        guard result.status == .ok else {
            throw MailError.protocolError("папка «\(mailbox)» недоступна" + (result.text.isEmpty ? "" : ": \(result.text)"))
        }
        var exists: UInt32 = 0
        for response in result.untagged {
            if case .data(let number?, "EXISTS", _) = response { exists = number }
        }
        return exists
    }

    private func searchUIDs(unseen: Bool, text: String?) async throws -> [UInt32] {
        func command(charset: Bool) -> [IMAPCommandPart] {
            var parts: [IMAPCommandPart] = [.text("UID SEARCH")]
            if charset { parts.append(.text(" CHARSET UTF-8")) }
            if unseen { parts.append(.text(" UNSEEN")) }
            if let text {
                parts.append(.text(" TEXT "))
                parts.append(IMAPCommandEncoder.astring(text)) // литерал последним: меньше обменов
            }
            return parts
        }

        var result = try await execute(command(charset: text != nil))
        if result.status != .ok, let text, text.allSatisfy(\.isASCII) {
            // Некоторые серверы не принимают CHARSET — для ASCII-запроса он и не нужен.
            result = try await execute(command(charset: false))
        }
        try result.requireOK("поиск писем не удался")

        var uids: [UInt32] = []
        for response in result.untagged {
            if case .data(nil, "SEARCH", let values) = response {
                uids += values.compactMap(\.number)
            }
        }
        return uids
    }

    // MARK: - Сессия

    /// Подключение, приветствие и LOGIN, если соединения ещё нет.
    private func ensureSession() async throws {
        guard transport == nil else { return }
        let current = makeTransport()
        transport = current
        framer = IMAPFramer()
        byeText = nil

        current.armDeadline(timeout)
        try await current.start()
        let greeting = try await readResponse(from: current)
        current.disarmDeadline()

        switch greeting {
        case .status(nil, .ok, _, _):
            break
        case .status(nil, .preauth, _, _):
            return
        case .status(nil, .bye, _, let text):
            throw MailError.connectionFailed(text.isEmpty ? "сервер отказал в подключении" : text)
        default:
            throw MailError.protocolError("неожиданное приветствие сервера")
        }

        let login = try await execute([
            .text("LOGIN "), IMAPCommandEncoder.astring(account.username),
            .text(" "), IMAPCommandEncoder.astring(password),
        ])
        switch login.status {
        case .ok:
            return
        case .no:
            throw MailError.authenticationFailed(login.text)
        default:
            throw MailError.protocolError(login.text.isEmpty ? "сервер не принял команду входа" : login.text)
        }
    }

    private func dropConnection() {
        transport?.close()
        transport = nil
        framer = IMAPFramer()
    }

    /// Выполняет операцию эксклюзивно. Ошибка рвёт соединение (кроме «не найдено»);
    /// если упало старое переиспользованное соединение (сервер закрыл его по простою) — одна повторная попытка.
    private func exclusive<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        var attempt = 0
        while true {
            let reused = transport != nil
            do {
                return try await operation()
            } catch let error as MailError {
                guard error != .notFound else { throw error }
                dropConnection()
                if case .connectionFailed = error, reused, attempt == 0, !Task.isCancelled {
                    attempt += 1
                    continue
                }
                throw error
            } catch is CancellationError {
                dropConnection()
                throw CancellationError()
            } catch {
                dropConnection()
                throw MailError.connectionFailed(error.localizedDescription)
            }
        }
    }

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume() // занятость передаётся следующему
        }
    }

    // MARK: - Команды

    struct CommandResult: Sendable {
        var status: IMAPStatus
        var code: String?
        var text: String
        var untagged: [IMAPResponse]

        func requireOK(_ context: String) throws {
            guard status == .ok else {
                throw MailError.protocolError(text.isEmpty ? context : "\(context): \(text)")
            }
        }
    }

    /// Отправляет команду с новым тегом и читает ответы до тегированного OK/NO/BAD.
    /// Литералы отправляются после приглашения `+` от сервера.
    private func execute(_ parts: [IMAPCommandPart], timeout commandTimeout: TimeInterval? = nil) async throws -> CommandResult {
        guard let current = transport else { throw MailError.connectionFailed("нет соединения") }
        tagCounter += 1
        let tag = "a\(tagCounter)"
        current.armDeadline(commandTimeout ?? timeout)
        defer { current.disarmDeadline() }

        var untagged: [IMAPResponse] = []
        var outgoing = Data("\(tag) ".utf8)
        for part in parts {
            switch part {
            case .text(let text):
                outgoing.append(contentsOf: Array(text.utf8))
            case .literal(let bytes):
                outgoing.append(contentsOf: Array("{\(bytes.count)}\r\n".utf8))
                try await current.send(outgoing)
                outgoing = Data()
                waiting: while true {
                    let response = try await readResponse(from: current)
                    switch response {
                    case .continuation:
                        break waiting
                    case .status(let responseTag?, let status, let code, let text) where responseTag == tag:
                        return CommandResult(status: status, code: code, text: text, untagged: untagged)
                    default:
                        untagged.append(response)
                    }
                }
                outgoing.append(contentsOf: bytes)
            }
        }
        outgoing.append(contentsOf: [0x0D, 0x0A])
        try await current.send(outgoing)

        while true {
            let response = try await readResponse(from: current)
            switch response {
            case .status(let responseTag?, let status, let code, let text) where responseTag == tag:
                return CommandResult(status: status, code: code, text: text, untagged: untagged)
            case .continuation:
                throw MailError.protocolError("сервер ждёт продолжения команды")
            default:
                untagged.append(response)
            }
        }
    }

    /// Следующий ответ сервера; дочитывает сокет, пока ответ (с литералами) не придёт целиком.
    private func readResponse(from current: any IMAPTransport) async throws -> IMAPResponse {
        while true {
            let raw: [UInt8]?
            do {
                raw = try framer.nextResponse()
            } catch {
                throw MailError.protocolError("\(error)")
            }
            if let raw {
                guard let response = try? IMAPResponseParser.parse(raw) else {
                    if raw.first == UInt8(ascii: "*") { continue } // непонятные нетегированные данные пропускаем
                    throw MailError.protocolError("непонятный ответ сервера")
                }
                if case .status(nil, .bye, _, let text) = response { byeText = text }
                return response
            }
            guard let chunk = try await current.receive() else {
                let reason = byeText.map { $0.isEmpty ? "сервер закрыл соединение" : "сервер закрыл соединение: \($0)" }
                throw MailError.connectionFailed(reason ?? "сервер закрыл соединение")
            }
            framer.append(chunk)
        }
    }
}
