import Foundation
@testable import AssistantCore

// Заготовки писем и сценарный IMAP-сервер в памяти для тестов почты (без сети).

enum MailFixtures {
    /// Многострочный литерал с `\n` → письмо с CRLF, как на проводе.
    static func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// multipart/alternative: text/plain в base64 (UTF-8) + text/html в quoted-printable.
    static let alternative = crlf(#"""
    Return-Path: <olga@example.ru>
    Received: from mx.example.ru (mx.example.ru [192.0.2.1])
    	by mx.yandex.ru with ESMTPS; Mon, 16 Nov 2026 10:15:02 +0300
    From: =?UTF-8?B?0J7Qu9GM0LPQsCDQn9C10YLRgNC+0LLQsA==?= <olga@example.ru>
    To: "Ivanov, Ivan" <ivan@yandex.ru>, petr@mail.ru
    Subject: =?UTF-8?B?0JLRgdGC0YDQtdGH0LAg?=
     =?UTF-8?B?0LIg0L/Rj9GC0L3QuNGG0YM=?=
    Date: Mon, 16 Nov 2026 10:15:00 +0300
    MIME-Version: 1.0
    Content-Type: multipart/alternative;
    	boundary="----=_Part_1_alt"

    This is a multi-part message in MIME format.
    ------=_Part_1_alt
    Content-Type: text/plain; charset=UTF-8
    Content-Transfer-Encoding: base64

    0JfQtNGA0LDQstGB0YLQstGD0LnRgtC1LCDQmNCy0LDQvSEK0JLRgdGC0YDQtdGH0LAg0L/QtdGA
    0LXQvdC+0YHQuNGC0YHRjyDQvdCwINC/0Y/RgtC90LjRhtGDLCAxNTowMC4KCtChINGD0LLQsNC2
    0LXQvdC40LXQvCwK0J7Qu9GM0LPQsA==
    ------=_Part_1_alt
    Content-Type: text/html; charset="utf-8"
    Content-Transfer-Encoding: quoted-printable

    <html><head><title>=D0=9F=D0=B8=D1=81=D1=8C=D0=BC=D0=BE</title><style>p { c=
    olor: red; }</style></head><body><p>=D0=97=D0=B4=D1=80=D0=B0=D0=B2=D1=81=D1=
    =82=D0=B2=D1=83=D0=B9=D1=82=D0=B5,&nbsp;=D0=98=D0=B2=D0=B0=D0=BD!</p><p>=D0=
    =92=D1=81=D1=82=D1=80=D0=B5=D1=87=D0=B0 =D0=BF=D0=B5=D1=80=D0=B5=D0=BD=D0=
    =BE=D1=81=D0=B8=D1=82=D1=81=D1=8F =D0=BD=D0=B0 <b>=D0=BF=D1=8F=D1=82=D0=BD=
    =D0=B8=D1=86=D1=83</b>, 15:00.<br>=D0=A1 =D1=83=D0=B2=D0=B0=D0=B6=D0=B5=D0=
    =BD=D0=B8=D0=B5=D0=BC,<br>=D0=9E=D0=BB=D1=8C=D0=B3=D0=B0</p><script>alert(1=
    )</script></body></html>
    ------=_Part_1_alt--

    """#)

    static let alternativePlainText = "Здравствуйте, Иван!\nВстреча переносится на пятницу, 15:00.\n\nС уважением,\nОльга"

    /// Только HTML, windows-1251 + quoted-printable, тема в koi8-r.
    static let htmlOnly = crlf(#"""
    From: "=?windows-1251?Q?=CC=E0=E3=E0=E7=E8=ED?=" <shop@example.ru>
    To: ivan@yandex.ru
    Subject: =?koi8-r?B?+sHLwdogz9TQ0sHXzMXO?=
    Date: Sun, 15 Nov 2026 18:40:12 +0000 (UTC)
    Content-Type: text/html; charset="windows-1251"
    Content-Transfer-Encoding: quoted-printable

    <div style=3D"font-family: Arial">=C2=E0=F8 =E7=E0=EA=E0=E7 &laquo;=B9&nbsp=
    ;4521&raquo; =EE=F2=EF=F0=E0=E2=EB=E5=ED.</div><div>=D2=F0=E5=EA-=ED=EE=EC=
    =E5=F0: <a href=3D"https://example.ru/t?a=3D1&amp;b=3D2">RR123456789RU</a><=
    /div><table><tr><td>=C8=F2=EE=E3=EE:</td><td>1&nbsp;250&nbsp;&#8381;</td></=
    tr></table><!-- =F1=EA=F0=FB=F2=FB=E9 =EA=EE=EC=EC=E5=ED=F2=E0=F0=E8=E9 -->=
    <p>=D1=EF=E0=F1=E8=E1=EE &amp; =E4=EE =E2=F1=F2=F0=E5=F7=E8!</p>

    """#)

    static let htmlOnlyText = "Ваш заказ «№ 4521» отправлен.\n\nТрек-номер: RR123456789RU\n\nИтого: 1 250 ₽\n\nСпасибо & до встречи!"

    /// Простое письмо: text/plain, quoted-printable, UTF-8.
    static let plain = crlf(#"""
    From: petr@mail.ru
    To: ivan@yandex.ru
    Subject: =?utf-8?Q?=D0=9E=D1=82=D1=87=D1=91=D1=82?= за ноябрь
    Date: 14 Nov 26 09:00 +0300
    Content-Type: text/plain; charset=utf-8; format=flowed
    Content-Transfer-Encoding: quoted-printable

    =D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82! =D0=9E=D1=82=D1=87=D1=91=D1=82 =D0=B2=
    =D0=BE =D0=B2=D0=BB=D0=BE=D0=B6=D0=B5=D0=BD=D0=B8=D0=B8.

    """#)

    // MARK: Ответы сервера

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    static func literal(_ data: [UInt8]) -> [UInt8] {
        bytes("{\(data.count)}\r\n") + data
    }

    /// Делит письмо на заголовок и тело (по первой пустой строке).
    static func split(_ message: String) -> (header: String, body: [UInt8]) {
        let raw = bytes(message)
        let separator = bytes("\r\n\r\n")
        var index = 0
        while index + separator.count <= raw.count {
            if Array(raw[index..<(index + separator.count)]) == separator {
                return (String(decoding: raw[..<(index + 2)], as: UTF8.self), Array(raw[(index + 4)...]))
            }
            index += 1
        }
        return (message, [])
    }

    /// Имитация сервера: BODY[HEADER.FIELDS (...)] — только нужные поля с продолжениями и пустой строкой в конце.
    static func headerFields(_ message: String, names: [String]) -> [UInt8] {
        let wanted = Set(names.map { $0.lowercased() })
        var result = ""
        var keep = false
        for line in split(message).header.components(separatedBy: "\r\n") where !line.isEmpty {
            if line.first == " " || line.first == "\t" {
                if keep { result += line + "\r\n" }
            } else {
                let name = line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
                keep = wanted.contains(name)
                if keep { result += line + "\r\n" }
            }
        }
        return bytes(result + "\r\n")
    }

    struct StoredMessage: Sendable {
        let uid: UInt32
        let seen: Bool
        let internalDate: String
        let raw: String
    }

    static func summaryFetch(sequence: Int, message: StoredMessage) -> [UInt8] {
        let names = MailAssembler.summaryHeaderFields.split(separator: " ").map(String.init)
        let header = headerFields(message.raw, names: names)
        let text = Array(split(message.raw).body.prefix(IMAPClient.snippetPrefixBytes))
        let flags = message.seen ? "\\Seen" : ""
        return bytes("* \(sequence) FETCH (UID \(message.uid) FLAGS (\(flags)) INTERNALDATE \"\(message.internalDate)\" ")
            + bytes("BODY[HEADER.FIELDS (\(MailAssembler.summaryHeaderFields))] ") + literal(header)
            + bytes(" BODY[TEXT]<0> ") + literal(text) + bytes(")\r\n")
    }

    static func fullFetch(sequence: Int, message: StoredMessage) -> [UInt8] {
        bytes("* \(sequence) FETCH (UID \(message.uid) FLAGS () BODY[]<0> ") + literal(bytes(message.raw)) + bytes(")\r\n")
    }
}

/// Сценарный IMAP-сервер в памяти. Принимает байты команд (с литералами через «+»),
/// отвечает через `handler` и отдаёт ответы кусками разной длины, чтобы литералы рвались между чтениями.
final class MailFakeTransport: IMAPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (_ tag: String, _ command: String) -> [UInt8]

    private let lock = NSLock()
    private let greeting: String
    private let handler: Handler
    private let chunkSizes: [Int]
    private let closeAfterCommands: Int?
    private var outgoing: [UInt8] = []
    private var inbound: [UInt8] = []
    private var literalRemaining = 0
    private var chunkIndex = 0
    private var log: [String] = []
    private var closed = false

    init(
        greeting: String = "* OK [CAPABILITY IMAP4rev1 LITERAL+ AUTH=PLAIN] Fake IMAP ready\r\n",
        chunkSizes: [Int] = [1, 3, 7, 64, 500],
        closeAfterCommands: Int? = nil,
        handler: @escaping Handler
    ) {
        self.greeting = greeting
        self.chunkSizes = chunkSizes
        self.closeAfterCommands = closeAfterCommands
        self.handler = handler
    }

    /// Полученные команды без тега (литералы — вместе с маркером `{n}`).
    var commands: [String] { lock.withLock { log } }
    var isClosed: Bool { lock.withLock { closed } }

    func start() async throws {
        lock.withLock { outgoing += Array(greeting.utf8) }
    }

    func send(_ data: Data) async throws {
        lock.withLock {
            for byte in data {
                inbound.append(byte)
                if literalRemaining > 0 {
                    literalRemaining -= 1
                    continue
                }
                guard byte == 0x0A else { continue }
                let lineEnd = inbound.count >= 2 && inbound[inbound.count - 2] == 0x0D ? inbound.count - 2 : inbound.count - 1
                if let length = try? IMAPFramer.literalLength(in: inbound, end: lineEnd, lowerBound: 0), length > 0 {
                    literalRemaining = length
                    outgoing += Array("+ Ready for literal data\r\n".utf8)
                    continue
                }
                let line = String(decoding: inbound[..<lineEnd], as: UTF8.self)
                inbound.removeAll()
                let tag = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                let command = String(line.dropFirst(tag.count + 1))
                log.append(command)
                if let limit = closeAfterCommands, log.count > limit {
                    closed = true // сервер «закрыл» соединение по простою
                    continue
                }
                outgoing += handler(tag, command)
            }
        }
    }

    func receive() async throws -> Data? {
        lock.withLock {
            guard !closed, !outgoing.isEmpty else { return nil }
            let size = min(chunkSizes[chunkIndex % chunkSizes.count], outgoing.count)
            chunkIndex += 1
            let chunk = Data(outgoing.prefix(size))
            outgoing.removeFirst(size)
            return chunk
        }
    }

    func armDeadline(_ seconds: TimeInterval) {}
    func disarmDeadline() {}

    func close() {
        lock.withLock { closed = true }
    }
}

/// Почтовый ящик для сценария: отвечает на LOGIN/EXAMINE/SEARCH/FETCH/LOGOUT.
struct MailFakeMailbox: Sendable {
    var messages: [MailFixtures.StoredMessage]
    var searchResult: [UInt32] = []
    var loginResponse: String = "OK LOGIN completed"

    func respond(tag: String, command: String) -> [UInt8] {
        let upper = command.uppercased()
        func line(_ text: String) -> [UInt8] { MailFixtures.bytes(text + "\r\n") }

        if upper.hasPrefix("LOGIN ") {
            return line("\(tag) \(loginResponse)")
        }
        if upper.hasPrefix("EXAMINE ") {
            return line("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)")
                + line("* OK [PERMANENTFLAGS ()] No permanent flags permitted")
                + line("* \(messages.count) EXISTS")
                + line("* 0 RECENT")
                + line("* OK [UIDVALIDITY 1700000000] UIDs valid")
                + line("\(tag) OK [READ-ONLY] EXAMINE completed")
        }
        if upper.hasPrefix("UID SEARCH") {
            let list = searchResult.map(String.init).joined(separator: " ")
            return line("* SEARCH" + (list.isEmpty ? "" : " " + list)) + line("\(tag) OK SEARCH completed")
        }
        if upper.hasPrefix("UID FETCH ") {
            let set = command.split(separator: " ")[2]
            let uids = Set(set.split(separator: ",").compactMap { UInt32($0) })
            var out: [UInt8] = []
            for (offset, message) in messages.enumerated() where uids.contains(message.uid) {
                out += upper.contains("BODY.PEEK[]")
                    ? MailFixtures.fullFetch(sequence: offset + 1, message: message)
                    : MailFixtures.summaryFetch(sequence: offset + 1, message: message)
            }
            return out + line("\(tag) OK UID FETCH completed")
        }
        if upper.hasPrefix("FETCH ") {
            let range = command.split(separator: " ")[1].split(separator: ":").compactMap { Int($0) }
            var out: [UInt8] = []
            if range.count == 2 {
                for sequence in range[0]...range[1] where sequence >= 1 && sequence <= messages.count {
                    out += MailFixtures.summaryFetch(sequence: sequence, message: messages[sequence - 1])
                }
            }
            return out + line("\(tag) OK FETCH completed")
        }
        if upper.hasPrefix("LOGOUT") {
            return line("* BYE Logging out") + line("\(tag) OK LOGOUT completed")
        }
        return line("\(tag) BAD Unknown command")
    }
}

/// Учёт созданных фейковых соединений.
final class MailTransportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MailFakeTransport] = []

    var transports: [MailFakeTransport] { lock.withLock { items } }

    func add(_ transport: MailFakeTransport) {
        lock.withLock { items.append(transport) }
    }
}
