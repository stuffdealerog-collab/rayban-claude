import Foundation
import Testing
@testable import AssistantCore

// MARK: - Токенизатор IMAP

@Suite struct IMAPTokenizerTests {
    /// Подаёт байты в нарезчик кусками заданного размера и собирает все ответы.
    private func frame(_ bytes: [UInt8], chunk: Int) throws -> [[UInt8]] {
        var framer = IMAPFramer()
        var responses: [[UInt8]] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + chunk, bytes.count)
            framer.append(bytes[index..<end])
            index = end
            while let response = try framer.nextResponse() { responses.append(response) }
        }
        #expect(framer.bufferedByteCount == 0)
        return responses
    }

    private var fetchStream: [UInt8] {
        let headers = MailFixtures.bytes(MailFixtures.crlf("""
        From: =?UTF-8?B?0J7Qu9GM0LPQsA==?= <olga@example.ru>
        Subject: Test {5}
        Date: Mon, 16 Nov 2026 10:15:00 +0300


        """))
        let text = MailFixtures.bytes("Line one\r\n) not the end {3}\r\nабв\r\n")
        return MailFixtures.bytes("* 12 FETCH (UID 345 FLAGS (\\Seen \\Answered) INTERNALDATE \" 7-Nov-2026 02:44:25 -0700\" ")
            + MailFixtures.bytes("BODY[HEADER.FIELDS (FROM SUBJECT DATE)] ") + MailFixtures.literal(headers)
            + MailFixtures.bytes(" BODY[TEXT]<0> ") + MailFixtures.literal(text)
            + MailFixtures.bytes(")\r\n* 13 FETCH (UID 346 FLAGS () BODY[TEXT]<0> NIL)\r\n")
            + MailFixtures.bytes("* 12 FETCH (RFC822.SIZE 4410)\r\n")
            + MailFixtures.bytes("a7 OK [READ-ONLY] Fetch completed (0.003 + 0.000 secs).\r\n")
    }

    @Test(arguments: [1, 2, 5, 17, 4096])
    func framerHandlesLiteralsAcrossReads(chunk: Int) throws {
        let responses = try frame(fetchStream, chunk: chunk)
        #expect(responses.count == 4)
        #expect(responses.last == MailFixtures.bytes("a7 OK [READ-ONLY] Fetch completed (0.003 + 0.000 secs).\r\n"))
    }

    @Test func parsesMultiLineFetchWithLiterals() throws {
        let parsed = try frame(fetchStream, chunk: 4096).map(IMAPResponseParser.parse)
        let items = IMAPFetchItem.collect(from: parsed)
        #expect(items.count == 2)

        let first = try #require(items.first)
        #expect(first.sequence == 12)
        #expect(first.uid == 345)
        #expect(first.flags == ["\\Seen", "\\Answered"])
        #expect(first.isSeen)
        #expect(first.attributes["RFC822.SIZE"] == .atom("4410")) // вторая порция того же письма объединена
        #expect(first.internalDate == Date(timeIntervalSince1970: 1_794_044_665)) // 2026-11-07 09:44:25 UTC
        let text = try #require(first.section("TEXT"))
        #expect(String(decoding: text, as: UTF8.self) == "Line one\r\n) not the end {3}\r\nабв\r\n")
        let header = try #require(first.section("HEADER.FIELDS"))
        #expect(String(decoding: header, as: UTF8.self).hasPrefix("From: =?UTF-8?B?"))
        #expect(first.section("") == nil)

        let second = try #require(items.last)
        #expect(second.uid == 346)
        #expect(second.flags.isEmpty)
        #expect(!second.isSeen)
        #expect(second.section("TEXT") == [])

        #expect(parsed.last == .status(tag: "a7", status: .ok, code: "READ-ONLY",
                                       text: "Fetch completed (0.003 + 0.000 secs)."))
    }

    @Test func parsesQuotedStringsNilAndNestedLists() throws {
        let response = try IMAPResponseParser.parse(MailFixtures.bytes(
            #"* LIST (\HasNoChildren \Marked) "/" "Folder \"quoted\" \\ name""# + "\r\n"))
        #expect(response == .data(number: nil, name: "LIST", values: [
            .list([.atom("\\HasNoChildren"), .atom("\\Marked")]),
            .string(MailFixtures.bytes("/")),
            .string(MailFixtures.bytes(#"Folder "quoted" \ name"#)),
        ]))

        let envelope = try IMAPResponseParser.parse(MailFixtures.bytes(
            "* 1 FETCH (ENVELOPE (\"Mon, 16 Nov 2026\" NIL ((\"Olga\" NIL \"olga\" \"example.ru\")) nil))\r\n"))
        guard case .data(1, "FETCH", let values) = envelope, let list = values.first?.listItems,
              let envelopeFields = list.last?.listItems else {
            Issue.record("неожиданный разбор: \(envelope)")
            return
        }
        #expect(envelopeFields.count == 4)
        #expect(envelopeFields[1] == .null)
        #expect(envelopeFields[3] == .null)
        #expect(envelopeFields[2].listItems?.first?.listItems?.first == .string(MailFixtures.bytes("Olga")))
    }

    @Test func parsesStatusAndDataResponses() throws {
        #expect(try IMAPResponseParser.parse(MailFixtures.bytes("a1 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n"))
            == .status(tag: "a1", status: .no, code: "AUTHENTICATIONFAILED", text: "Invalid credentials (Failure)"))
        #expect(try IMAPResponseParser.parse(MailFixtures.bytes("* OK [CAPABILITY IMAP4rev1 LITERAL+ AUTH=PLAIN] Dovecot ready.\r\n"))
            == .status(tag: nil, status: .ok, code: "CAPABILITY IMAP4rev1 LITERAL+ AUTH=PLAIN", text: "Dovecot ready."))
        #expect(try IMAPResponseParser.parse(MailFixtures.bytes("* SEARCH 4 15 16\r\n"))
            == .data(number: nil, name: "SEARCH", values: [.atom("4"), .atom("15"), .atom("16")]))
        #expect(try IMAPResponseParser.parse(MailFixtures.bytes("* 172 EXISTS\r\n"))
            == .data(number: 172, name: "EXISTS", values: []))
        #expect(try IMAPResponseParser.parse(MailFixtures.bytes("+ Ready for literal data\r\n"))
            == .continuation("Ready for literal data"))
        #expect(throws: IMAPParseError.self) {
            try IMAPResponseParser.parse(MailFixtures.bytes("* 1 FETCH (UID 5 BODY[TEXT] {10}\r\nshort)\r\n"))
        }
    }

    @Test func encodesCommandArguments() {
        #expect(IMAPCommandEncoder.astring("ivan@yandex.ru") == .text("\"ivan@yandex.ru\""))
        #expect(IMAPCommandEncoder.astring(#"p"ss\word"#) == .text(#""p\"ss\\word""#))
        #expect(IMAPCommandEncoder.astring("привет") == .literal(MailFixtures.bytes("привет")))
        #expect(IMAPCommandEncoder.astring("a\r\nb") == .literal(MailFixtures.bytes("a\r\nb")))
        #expect(IMAPCommandEncoder.mailboxName("INBOX") == "INBOX")
        #expect(IMAPCommandEncoder.mailboxName("Входящие") == "&BBIERQQ+BDQETwRJBDgENQ-")
        #expect(IMAPCommandEncoder.mailboxName("Отправленные") == "&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-")
        #expect(IMAPCommandEncoder.mailboxName("Tom & Jerry") == "Tom &- Jerry")
        #expect(IMAPCommandEncoder.sequenceSet([10, 3, 5, 6, 7, 7]) == "3,5:7,10")
    }
}

// MARK: - RFC 2047 и адреса

@Suite struct MailHeaderDecodingTests {
    @Test(arguments: [
        ("=?UTF-8?B?0J/RgNC40LLQtdGC?=", "Привет"),
        ("=?utf-8?Q?=D0=BC=D0=B8=D1=80?=", "мир"),
        ("=?UTF-8?B?0J/RgNC40LLQtdGC?= =?utf-8?Q?_=D0=BC=D0=B8=D1=80?=", "Привет мир"),
        ("=?koi8-r?B?8NLJ18XU?=", "Привет"),
        ("=?KOI8-R?B?+sHLwdogz9TQ0sHXzMXO?=", "Заказ отправлен"),
        ("=?windows-1251?Q?=CF=F0=E8=E2=E5=F2?=", "Привет"),
        ("=?windows-1251?q?=CF=F0=E8=E2=E5=F2_=EC=E8=F0?=", "Привет мир"),
        // символ UTF-8 разрезан между соседними словами
        ("=?UTF-8?B?0J/R?=\r\n =?UTF-8?B?gNC40LLQtdGC?=", "Привет"),
        ("Re: =?UTF-8?B?0J/RgNC40LLQtdGC?= world", "Re: Привет world"),
        ("=?UTF-8*ru?Q?=D0=BC=D0=B8=D1=80?=", "мир"),
        ("Plain subject", "Plain subject"),
        ("Broken =?UTF-8?X?abc?= and =?unterminated", "Broken =?UTF-8?X?abc?= and =?unterminated"),
    ])
    func decodesEncodedWords(input: String, expected: String) {
        #expect(MailEncodedWords.decode(input) == expected)
    }

    @Test func unfoldsHeaders() {
        let headers = MIMEHeaders.parse(MailFixtures.bytes(MailFixtures.crlf("""
        Subject: =?UTF-8?B?0JLRgdGC0YDQtdGH0LAg?=
         =?UTF-8?B?0LIg0L/Rj9GC0L3QuNGG0YM=?=
        Content-Type: multipart/alternative;
        \tboundary="b1"
        X-Long: first
          second

        """)))
        #expect(headers["subject"].map(MailAssembler.decodeSubject) == "Встреча в пятницу")
        #expect(headers["CONTENT-TYPE"] == "multipart/alternative;\tboundary=\"b1\"")
        #expect(headers["x-long"] == "first  second")
        #expect(headers["missing"] == nil)
    }

    @Test func decodesRaw8BitHeadersAsWindows1251() {
        let raw: [UInt8] = MailFixtures.bytes("Subject: ") + [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2] + MailFixtures.bytes("\r\n")
        #expect(MIMEHeaders.parse(raw)["subject"] == "Привет")
    }

    @Test func formatsAddresses() {
        #expect(MailAddressFormatter.format("=?UTF-8?B?0J7Qu9GM0LPQsCDQn9C10YLRgNC+0LLQsA==?= <olga@example.ru>")
            == "Ольга Петрова <olga@example.ru>")
        #expect(MailAddressFormatter.format("\"Ivanov, Ivan\" <ivan@yandex.ru>, petr@mail.ru")
            == "Ivanov, Ivan <ivan@yandex.ru>, petr@mail.ru")
        #expect(MailAddressFormatter.format("\"=?windows-1251?Q?=CC=E0=E3=E0=E7=E8=ED?=\" <shop@example.ru>")
            == "Магазин <shop@example.ru>")
        #expect(MailAddressFormatter.format("<noreply@example.com>") == "noreply@example.com")
        #expect(MailAddressFormatter.format(nil) == "")
    }
}

// MARK: - MIME и текст

@Suite struct MIMEParsingTests {
    @Test func multipartAlternativePrefersBase64Plain() throws {
        let root = MIMEParser.parse(MailFixtures.bytes(MailFixtures.alternative))
        #expect(root.mediaType == "multipart/alternative")
        #expect(root.parameters["boundary"] == "----=_Part_1_alt")
        #expect(root.parts.map(\.mediaType) == ["text/plain", "text/html"])
        #expect(MailText.bestText(in: root) == MailFixtures.alternativePlainText)

        // HTML-часть в quoted-printable тоже читается корректно.
        let html = try #require(root.parts.last)
        #expect(html.transferEncoding == "quoted-printable")
        #expect(MailText.htmlToText(html.decodedText)
            == "Здравствуйте, Иван!\n\nВстреча переносится на пятницу, 15:00.\nС уважением,\nОльга")

        let message = MailAssembler.message(uid: 7, raw: MailFixtures.bytes(MailFixtures.alternative), internalDate: nil, maxLength: 4000)
        #expect(message.from == "Ольга Петрова <olga@example.ru>")
        #expect(message.to == "Ivanov, Ivan <ivan@yandex.ru>, petr@mail.ru")
        #expect(message.subject == "Встреча в пятницу")
        #expect(message.date == Date(timeIntervalSince1970: 1_794_813_300)) // 2026-11-16 07:15:00 UTC
        #expect(message.text == MailFixtures.alternativePlainText)
    }

    @Test func htmlOnlyWindows1251() {
        let message = MailAssembler.message(uid: 9, raw: MailFixtures.bytes(MailFixtures.htmlOnly), internalDate: nil, maxLength: 4000)
        #expect(message.from == "Магазин <shop@example.ru>")
        #expect(message.subject == "Заказ отправлен")
        #expect(message.text == MailFixtures.htmlOnlyText)
        #expect(message.date == Date(timeIntervalSince1970: 1_794_768_012)) // 2026-11-15 18:40:12 UTC
    }

    @Test func htmlStripping() {
        #expect(MailText.htmlToText("<p>A&amp;B &lt;tag&gt; &#1055;&#x440;&#1080;</p>") == "A&B <tag> При")
        #expect(MailText.htmlToText("<SCRIPT type=\"x\">var a = '<p>';</SCRIPT>Текст<br/>ещё<BR>  и   ещё")
            == "Текст\nещё\nи ещё")
        #expect(MailText.htmlToText("<img alt=\"a > b\" src=x>после &unknown; 1 < 2") == "после &unknown; 1 < 2")
        #expect(MailText.htmlToText("Обрезано <a href=\"https://exa") == "Обрезано")
        #expect(MailText.htmlToText("<div>&nbsp;\u{034F}\u{200C}&zwnj; </div><div>Привет</div>") == "Привет")
    }

    @Test func multipartMixedWithAttachmentAndNestedAlternative() {
        let raw = MailFixtures.crlf("""
        Content-Type: multipart/mixed; boundary=outer

        --outer
        Content-Type: multipart/alternative; boundary="outer-inner"

        --outer-inner
        Content-Type: text/html; charset=utf-8

        <p>Только <i>HTML</i></p>
        --outer-inner--
        --outer
        Content-Type: text/plain; name="notes.txt"
        Content-Disposition: attachment; filename="notes.txt"

        Это вложение, а не текст письма.
        --outer--

        """)
        let root = MIMEParser.parse(MailFixtures.bytes(raw))
        #expect(root.parts.count == 2)
        #expect(root.parts.first?.parts.count == 1)
        #expect(MailText.bestText(in: root) == "Только HTML")
    }

    @Test func transferEncodingsAreLenient() {
        #expect(MIMETransferEncoding.decodeBase64(MailFixtures.bytes("0J/R\r\ngNC4 0LLQ\ntdGC")) == MailFixtures.bytes("Привет"))
        #expect(MIMETransferEncoding.decodeBase64(MailFixtures.bytes("SGk=SGk=")) == MailFixtures.bytes("HiHi"))
        #expect(MIMETransferEncoding.decodeQuotedPrintable(MailFixtures.bytes("a=3Db=\r\nc= \r\nd=E2=82")) == MailFixtures.bytes("a=bcd") + [0xE2, 0x82])
        #expect(MIMECharset.decode([0xD0, 0x9F, 0xD1, 0x80, 0xD0], charset: "utf-8") == "Пр") // обрезанный хвост
        #expect(MIMECharset.decode([0xF0, 0xD2, 0xC9], charset: "KOI8-R") == "При")
        #expect(MIMECharset.decode([0xCF, 0xF0, 0xE8], charset: "cp1251") == "При")
        #expect(MIMECharset.decode(MailFixtures.bytes("plain"), charset: "x-unknown-charset") == "plain")
    }
}

// MARK: - Сниппеты

@Suite struct MailSnippetTests {
    @Test func snippetFromTruncatedMultipartText() {
        let message = MailFixtures.alternative
        let header = MailFixtures.headerFields(message, names: ["From", "Subject", "Content-Type", "Content-Transfer-Encoding"])
        // Обрезаем тело посреди base64, как это делает BODY.PEEK[TEXT]<0.N>.
        let body = Array(MailFixtures.split(message).body.prefix(260))
        let snippet = MailAssembler.snippet(headerBytes: header, bodyPrefix: body)
        #expect(snippet.hasPrefix("Здравствуйте, Иван! Встреча"))
        #expect(!snippet.contains("\n"))
        #expect(!snippet.contains("Part_1_alt"))
    }

    @Test func snippetFromSinglePartQuotedPrintable() {
        let header = MailFixtures.headerFields(MailFixtures.plain, names: ["Content-Type", "Content-Transfer-Encoding"])
        let body = MailFixtures.split(MailFixtures.plain).body
        #expect(MailAssembler.snippet(headerBytes: header, bodyPrefix: body) == "Привет! Отчёт во вложении.")
    }

    @Test func snippetWithoutContentTypeButBoundaryInBody() {
        let body = MailFixtures.bytes(MailFixtures.crlf("""
        --zzz
        Content-Type: text/plain; charset=utf-8

        Первая часть
        --zzz
        """))
        #expect(MailAssembler.snippet(headerBytes: [], bodyPrefix: body) == "Первая часть")
    }

    @Test func snippetIsOneLineAndLimited() {
        let long = (1...80).map { "слово\($0)" }.joined(separator: "\n\n  ")
        let snippet = MailText.snippet(long)
        #expect(snippet.count <= 200)
        #expect(snippet.hasSuffix("…"))
        #expect(!snippet.contains("\n"))
        #expect(snippet.hasPrefix("слово1 слово2 слово3"))
        #expect(MailText.snippet("  коротко \r\n ") == "коротко")
        #expect(MailText.truncate("абвгд", maxLength: 3) == "аб…")
    }
}

// MARK: - Даты и пресеты

@Suite struct MailMiscTests {
    @Test func parsesDates() {
        #expect(MailDate.parseRFC5322("Mon, 16 Nov 2026 10:15:00 +0300 (MSK)") == Date(timeIntervalSince1970: 1_794_813_300))
        #expect(MailDate.parseRFC5322("16 Nov 2026 07:15:00 GMT") == Date(timeIntervalSince1970: 1_794_813_300))
        #expect(MailDate.parseRFC5322("Mon, 16 Nov 26 10:15 +0300") == Date(timeIntervalSince1970: 1_794_813_300))
        #expect(MailDate.parseRFC5322("Mon Nov 16 07:15:00 2026") == Date(timeIntervalSince1970: 1_794_813_300))
        #expect(MailDate.parseRFC5322("Mon, 16 Nov 2026 02:15:00 -0500") == Date(timeIntervalSince1970: 1_794_813_300))
        #expect(MailDate.parseInternalDate("16-Nov-2026 10:15:00 +0300") == Date(timeIntervalSince1970: 1_794_813_300))
        #expect(MailDate.parseInternalDate(" 1-Jan-2027 00:00:00 +0000") == Date(timeIntervalSince1970: 1_798_761_600))
        #expect(MailDate.parseRFC5322("not a date") == nil)
    }

    @Test func presets() throws {
        let gmail = try #require(MailAccount.preset(forEmail: " ivan.petrov@gmail.com "))
        #expect(gmail == MailAccount(host: "imap.gmail.com", port: 993, username: "ivan.petrov@gmail.com"))
        #expect(MailAccount.preset(forEmail: "x@googlemail.com")?.host == "imap.gmail.com")
        for domain in ["yandex.ru", "Yandex.COM", "ya.ru", "yandex.uz"] {
            #expect(MailAccount.preset(forEmail: "ivan@\(domain)")?.host == "imap.yandex.com")
        }
        for domain in ["mail.ru", "inbox.ru", "list.ru", "bk.ru"] {
            #expect(MailAccount.preset(forEmail: "ivan@\(domain)")?.host == "imap.mail.ru")
        }
        for domain in ["icloud.com", "me.com", "mac.com"] {
            #expect(MailAccount.preset(forEmail: "ivan@\(domain)")?.host == "imap.mail.me.com")
        }
        for domain in ["outlook.com", "hotmail.com", "live.com"] {
            #expect(MailAccount.preset(forEmail: "ivan@\(domain)")?.host == "outlook.office365.com")
        }
        #expect(MailAccount.preset(forEmail: "ivan@example.org") == nil)
        #expect(MailAccount.preset(forEmail: "not-an-email") == nil)
        #expect(MailAccount.preset(forEmail: "@gmail.com") == nil)
        #expect(MailAccount.preset(forEmail: "ivan@yandex.ru")?.port == 993)
    }

    @Test func errorsAreRussianAndUserFacing() {
        #expect(MailError.timeout.errorDescription == "Почтовый сервер не отвечает.")
        #expect(MailError.notFound.localizedDescription == "Письмо не найдено.")
        #expect(MailError.authenticationFailed("Invalid credentials").errorDescription == "Не удалось войти в почту: Invalid credentials")
    }
}

// MARK: - Клиент на сценарном сервере

@Suite struct IMAPClientFlowTests {
    static let account = MailAccount(host: "imap.example.ru", port: 993, username: "ivan@yandex.ru")

    static let mailbox = MailFakeMailbox(messages: [
        .init(uid: 101, seen: true, internalDate: "14-Nov-2026 06:00:01 +0000", raw: MailFixtures.plain),
        .init(uid: 102, seen: false, internalDate: "16-Nov-2026 07:15:02 +0000", raw: MailFixtures.alternative),
        .init(uid: 105, seen: false, internalDate: "15-Nov-2026 18:40:13 +0000", raw: MailFixtures.htmlOnly),
    ], searchResult: [102, 105])

    private func makeClient(
        mailbox: MailFakeMailbox = IMAPClientFlowTests.mailbox,
        password: String = "app-password",
        closeAfterCommands: Int? = nil
    ) -> (IMAPClient, MailTransportRecorder) {
        let recorder = MailTransportRecorder()
        let client = IMAPClient(account: Self.account, password: password, timeout: 5) {
            let transport = MailFakeTransport(closeAfterCommands: recorder.transports.isEmpty ? closeAfterCommands : nil) { tag, command in
                mailbox.respond(tag: tag, command: command)
            }
            recorder.add(transport)
            return transport
        }
        return (client, recorder)
    }

    @Test func recentMessagesNewestFirstWithoutMarkingRead() async throws {
        let (client, recorder) = makeClient(password: #"pa"ss\word"#)
        let summaries = try await client.recentMessages(unreadOnly: false, limit: 10)

        #expect(summaries.map(\.uid) == [105, 102, 101])
        #expect(summaries.map(\.isUnread) == [true, true, false])
        #expect(summaries[0].from == "Магазин <shop@example.ru>")
        #expect(summaries[0].subject == "Заказ отправлен")
        #expect(summaries[0].snippet == MailText.snippet(MailFixtures.htmlOnlyText))
        #expect(summaries[1].subject == "Встреча в пятницу")
        #expect(summaries[1].snippet == MailText.snippet(MailFixtures.alternativePlainText))
        #expect(summaries[1].date == Date(timeIntervalSince1970: 1_794_813_300))
        #expect(summaries[2].subject == "Отчёт за ноябрь")
        #expect(summaries[2].from == "petr@mail.ru")
        #expect(summaries[2].snippet == "Привет! Отчёт во вложении.")

        let commands = try #require(recorder.transports.first).commands
        #expect(commands.first == #"LOGIN "ivan@yandex.ru" "pa\"ss\\word""#)
        #expect(commands.contains("EXAMINE \"INBOX\""))
        #expect(commands.last?.hasPrefix("FETCH 1:3 (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE") == true)
        #expect(commands.last?.contains("BODY.PEEK[TEXT]<0.3000>") == true)
        #expect(!commands.contains { $0.uppercased().hasPrefix("SELECT") || $0.uppercased().contains(" BODY[") })

        // Повторный вызов идёт по тому же соединению, limit ограничивает диапазон.
        let latest = try await client.recentMessages(unreadOnly: false, limit: 2)
        #expect(latest.map(\.uid) == [105, 102])
        #expect(recorder.transports.count == 1)
        #expect(recorder.transports[0].commands.last?.hasPrefix("FETCH 2:3 ") == true)
    }

    @Test func unreadSearchWithCyrillicQueryUsesLiteral() async throws {
        let (client, recorder) = makeClient()
        let summaries = try await client.recentMessages(unreadOnly: true, limit: 1, query: " встреча ")
        #expect(summaries.map(\.uid) == [105])

        let commands = try #require(recorder.transports.first).commands
        let literal = "встреча".utf8.count
        #expect(commands.contains("UID SEARCH CHARSET UTF-8 UNSEEN TEXT {\(literal)}\r\nвстреча"))
        #expect(commands.last?.hasPrefix("UID FETCH 105 (UID FLAGS") == true)
    }

    @Test func unreadOnlyWithoutQuery() async throws {
        let (client, recorder) = makeClient()
        let summaries = try await client.recentMessages(unreadOnly: true, limit: 5)
        #expect(summaries.map(\.uid) == [105, 102])
        #expect(recorder.transports[0].commands.contains("UID SEARCH UNSEEN"))
        #expect(recorder.transports[0].commands.last?.hasPrefix("UID FETCH 102,105 ") == true)
    }

    @Test func fullMessageAndNotFound() async throws {
        let (client, recorder) = makeClient()
        let message = try await client.message(uid: 102, maxLength: 30)
        #expect(message.uid == 102)
        #expect(message.subject == "Встреча в пятницу")
        #expect(message.to == "Ivanov, Ivan <ivan@yandex.ru>, petr@mail.ru")
        #expect(message.text.count <= 30)
        #expect(message.text.hasPrefix("Здравствуйте, Иван!"))
        #expect(message.text.hasSuffix("…"))
        #expect(recorder.transports[0].commands.last == "UID FETCH 102 (UID FLAGS INTERNALDATE BODY.PEEK[]<0.524288>)")

        await #expect(throws: MailError.notFound) {
            try await client.message(uid: 999)
        }
        // «Не найдено» не рвёт соединение.
        _ = try await client.message(uid: 105)
        #expect(recorder.transports.count == 1)

        await client.close()
        #expect(recorder.transports[0].commands.last == "LOGOUT")
        #expect(recorder.transports[0].isClosed)
    }

    @Test func loginRejectedMapsToAuthenticationFailed() async throws {
        var mailbox = Self.mailbox
        mailbox.loginResponse = "NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)"
        let (client, recorder) = makeClient(mailbox: mailbox)
        await #expect(throws: MailError.authenticationFailed("Invalid credentials (Failure)")) {
            try await client.recentMessages(unreadOnly: true, limit: 5)
        }
        #expect(recorder.transports.first?.isClosed == true)
    }

    @Test func reconnectsOnceWhenIdleConnectionWasClosed() async throws {
        // Первое соединение обслуживает LOGIN, EXAMINE и FETCH, а затем сервер его молча закрывает.
        let (client, recorder) = makeClient(closeAfterCommands: 3)
        _ = try await client.recentMessages(unreadOnly: false, limit: 3)
        let again = try await client.recentMessages(unreadOnly: false, limit: 3)
        #expect(again.map(\.uid) == [105, 102, 101])
        #expect(recorder.transports.count == 2)
    }

    @Test func greetingByeIsConnectionFailure() async throws {
        let recorder = MailTransportRecorder()
        let client = IMAPClient(account: Self.account, password: "x", timeout: 5) {
            let transport = MailFakeTransport(greeting: "* BYE Too many connections\r\n") { _, _ in [] }
            recorder.add(transport)
            return transport
        }
        await #expect(throws: MailError.connectionFailed("Too many connections")) {
            try await client.recentMessages(unreadOnly: false, limit: 3)
        }
    }
}
