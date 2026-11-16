import AssistantCore
import SwiftUI

/// Настройки: короткий список разделов, детали — внутри каждого.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlassesManager.self) private var glasses
    @Environment(AssistantController.self) private var assistant

    @State private var showGlasses = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        PersonaEditorView()
                    } label: {
                        SettingsRow(symbol: "person.crop.circle", tone: .assistant, title: settings.persona.displayName, value: characterSummary)
                    }
                } footer: {
                    Text("Имя, характер и манера общения.")
                }

                Section {
                    NavigationLink {
                        ConversationSettingsView()
                    } label: {
                        SettingsRow(symbol: "bubble.left.and.text.bubble.right", tone: .assistant, title: "Разговор", value: settings.language.title)
                    }
                    NavigationLink {
                        VoiceSettingsView()
                    } label: {
                        SettingsRow(symbol: "waveform", tone: .translator, title: "Голос", value: voiceSummary)
                    }
                    NavigationLink {
                        ClaudeSettingsView()
                    } label: {
                        SettingsRow(symbol: "sparkles", tone: .memory, title: "Claude", value: settings.trimmedAPIKey.isEmpty ? "нет ключа" : settings.model.shortTitle)
                    }
                }

                Section {
                    NavigationLink {
                        BackgroundSettingsView()
                    } label: {
                        SettingsRow(symbol: "phone.arrow.down.left", tone: .assistant, title: "На связи и фон", value: nil)
                    }
                    Button {
                        showGlasses = true
                    } label: {
                        SettingsRow(symbol: "eyeglasses", tone: .system, title: "Очки", value: glassesSummary)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    NavigationLink {
                        MailSettingsView()
                    } label: {
                        SettingsRow(symbol: "envelope", tone: .translator, title: "Почта", value: settings.mailAccount == nil ? "не подключена" : settings.mailAddress)
                    }
                    NavigationLink {
                        TranslatorSettingsView()
                    } label: {
                        SettingsRow(symbol: "character.bubble", tone: .translator, title: "Переводчик", value: nil)
                    }
                }

                Section {
                    NavigationLink {
                        JournalView()
                    } label: {
                        SettingsRow(symbol: "list.bullet.rectangle", tone: .system, title: "Журнал", value: nil)
                    }
                    Button("Пройти первую настройку заново") { confirmReset = true }
                } header: {
                    Text("Данные")
                } footer: {
                    Text("Заметки памяти — файлы Markdown: Файлы → На iPhone → это приложение. Ключи и пароль почты хранятся только в Keychain этого iPhone.")
                }

                #if DEBUG
                MockGlassesSection()
                #endif
            }
            .navigationTitle("Настройки")
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .sheet(isPresented: $showGlasses) { GlassesSheet() }
            .confirmationDialog("Пройти первую настройку заново?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Начать") {
                    Task {
                        await assistant.setHandsFree(false)
                        assistant.interrupt()
                        settings.onboardingCompleted = false
                    }
                }
            } message: {
                Text("Память, ключи и разговоры сохранятся.")
            }
        }
    }

    private var characterSummary: String {
        let persona = settings.persona
        return "\(persona.character.title), \(persona.address == .informal ? "на «ты»" : "на «вы»")"
    }

    private var voiceSummary: String {
        if settings.trimmedElevenLabsKey.isEmpty { return "голос iOS" }
        return settings.elevenLabsVoiceName.isEmpty ? "ElevenLabs" : settings.elevenLabsVoiceName
    }

    private var glassesSummary: String {
        guard glasses.isRegistered else { return "не подключены" }
        guard glasses.hasActiveDevice else { return "не рядом" }
        return glasses.batteryLevel.map { "\($0)%" } ?? "на связи"
    }
}

/// Строка раздела: значок в цветной плашке, название, краткое значение.
struct SettingsRow: View {
    let symbol: String
    let tone: Theme.Tone
    let title: String
    let value: String?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.onColor)
                .frame(width: 30, height: 30)
                .background(tone.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Space.s)
            if let value {
                Text(value)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Разговор

struct ConversationSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Язык", selection: $settings.language) {
                    ForEach(AssistantLanguage.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("На этом языке ассистент слушает и отвечает по умолчанию. Заговорите на другом из трёх — ответит на нём.")
            }

            Section {
                Picker("Когда отвечать", selection: $settings.addressing) {
                    ForEach(AddressingMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if settings.addressing != .always {
                    TextField("Имя для обращения: \(settings.persona.displayName)", text: $settings.wakeWord)
                }
            } header: {
                Text("Когда отвечать")
            } footer: {
                Text("\(settings.addressing.detail) Действует в режимах «Без рук» и «На связи». Сразу после ответа можно продолжать без имени.")
            }

            Section {
                Toggle("Распознавание ElevenLabs", isOn: $settings.liveRecognition)
                    .disabled(settings.trimmedElevenLabsKey.isEmpty)
                if settings.usesLiveRecognition {
                    Toggle("Смешанная речь", isOn: $settings.mixedSpeech)
                }
            } header: {
                Text("Распознавание")
            } footer: {
                Text(recognitionFooter)
            }
        }
        .navigationTitle("Разговор")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private var recognitionFooter: String {
        if settings.trimmedElevenLabsKey.isEmpty {
            return "Сейчас речь распознаёт Apple на самом iPhone: русский и английский. Для узбекского и для работы в фоне добавьте ключ ElevenLabs в разделе «Голос»."
        }
        if settings.usesLiveRecognition {
            return "Речь распознаётся потоком: быстрее, точнее и с узбекским. «Смешанная речь» понимает узбекский и русский вперемешку в одной фразе, но может ошибаться на очень коротких репликах."
        }
        return "Русский и английский распознаёт Apple на самом iPhone, узбекский — ElevenLabs."
    }
}

// MARK: - Голос

struct VoiceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AssistantController.self) private var assistant

    @State private var voices: [ElevenLabsVoice] = []
    @State private var loadingVoices = false
    @State private var voicesError: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SecureField("Ключ ElevenLabs", text: $settings.elevenLabsAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("elevenlabs.io → Developers → API Keys. С ключом ассистент говорит живым голосом и понимает узбекский. Без ключа звучит голос iOS.")
            }

            if !settings.trimmedElevenLabsKey.isEmpty {
                Section {
                    if voices.isEmpty {
                        LabeledContent("Голос") {
                            if loadingVoices {
                                ProgressView()
                            } else {
                                Text(voicesError ?? (settings.elevenLabsVoiceName.isEmpty ? "нет голосов" : settings.elevenLabsVoiceName))
                                    .foregroundStyle(voicesError == nil ? Theme.textSecondary : Theme.negative)
                            }
                        }
                    } else {
                        Picker("Голос", selection: $settings.elevenLabsVoiceID) {
                            if !voices.contains(where: { $0.voiceID == settings.elevenLabsVoiceID }) {
                                Text(settings.elevenLabsVoiceName.isEmpty ? "Не выбран" : settings.elevenLabsVoiceName)
                                    .tag(settings.elevenLabsVoiceID)
                            }
                            ForEach(voices) { voice in
                                Text(voice.title).tag(voice.voiceID)
                            }
                        }
                    }
                    Picker("Модель", selection: $settings.elevenLabsModel) {
                        ForEach(ElevenLabsModel.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Обновить список голосов") {
                        Task { await loadVoices() }
                    }
                    .disabled(loadingVoices)
                } footer: {
                    Text(modelFooter)
                }
            }

            Section {
                Toggle("Стерео в режиме кнопки", isOn: $settings.stereoAnswers)
                Button("Проверить голос") {
                    Task { await assistant.say(assistant.greeting) }
                }
                .disabled(assistant.phase != .idle || assistant.translatorActive)
            } footer: {
                Text("Стерео: когда вы спрашиваете по кнопке, ответ идёт в очки как музыка, а не в телефонном качестве гарнитуры.")
            }
        }
        .navigationTitle("Голос")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .task(id: settings.trimmedElevenLabsKey) {
            // Ключ могут ещё вставлять — загружаем список голосов после короткой паузы.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await loadVoices()
        }
        .onChange(of: settings.elevenLabsVoiceID) { _, voiceID in
            if let voice = voices.first(where: { $0.voiceID == voiceID }) {
                settings.elevenLabsVoiceName = voice.name
            }
        }
    }

    private var modelFooter: String {
        if settings.elevenLabsModel.streams {
            return "Модели v4 говорят по-узбекски, по-русски и по-английски одним голосом; звук идёт потоком и начинается, пока ответ ещё пишется. Голоса носителей узбекского помечены «узб.»; другие добавляются из библиотеки голосов в «My Voices» на сайте ElevenLabs."
        }
        return "Прежние модели озвучивают ответ фразу за фразой, с заметной паузой. Для быстрого ответа и узбекского выберите v4 Turbo."
    }

    private func loadVoices() async {
        let key = settings.trimmedElevenLabsKey
        guard !key.isEmpty else {
            voices = []
            voicesError = nil
            return
        }
        loadingVoices = true
        voicesError = nil
        defer { loadingVoices = false }
        do {
            let list = try await ElevenLabsClient().voices(apiKey: key)
            guard key == settings.trimmedElevenLabsKey else { return }
            // Сначала голоса носителей языка ассистента, потом остальные в порядке ElevenLabs.
            let native = settings.language.isoCode
            voices = list.filter { $0.speaks(native) } + list.filter { !$0.speaks(native) }
            if settings.elevenLabsVoiceID.isEmpty, let first = voices.first {
                settings.elevenLabsVoiceID = first.voiceID
                settings.elevenLabsVoiceName = first.name
            }
        } catch {
            guard key == settings.trimmedElevenLabsKey else { return }
            voices = []
            voicesError = error.localizedDescription
        }
    }
}

// MARK: - Claude

struct ClaudeSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SecureField("API-ключ Anthropic", text: $settings.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("platform.claude.com → API Keys. Оплата — за использование.")
            }

            Section {
                Picker("Модель", selection: $settings.model) {
                    ForEach(ClaudeModel.allCases) { model in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.title)
                            Text(model.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .tag(model)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Модель")
            }

            Section {
                Toggle("Отвечать сразу", isOn: $settings.instantAnswers)
                    .disabled(settings.model.instantThinking == nil)
                Toggle("Поиск в интернете", isOn: $settings.webSearchEnabled)
                Toggle("Экономить на длинных разговорах", isOn: $settings.saveTokens)
            } footer: {
                Text("«Отвечать сразу»: модель не размышляет перед ответом, первая фраза звучит раньше. Для сложных вопросов выключите. Экономия: из длинного разговора сервер убирает старые снимки и результаты поиска.")
            }
        }
        .navigationTitle("Claude")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }
}

// MARK: - На связи и фон

struct BackgroundSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AssistantController.self) private var assistant

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Text("iOS не даёт приложению включить микрофон, когда оно уже свёрнуто. Исключение — звонки. Поэтому разговор с заблокированным телефоном идёт как звонок: нажмите «На связи» на главном экране, заблокируйте телефон и уберите его в карман.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            } header: {
                Text("Как это работает")
            } footer: {
                Text("Пока идёт такой звонок, звук в очках телефонного качества, музыка на паузе, очки расходуют заряд как при разговоре. Чтобы закончить, скажите «Отбой» или завершите вызов.")
            }

            Section {
                GuideRow(number: 1, text: "Siri: «\(settings.persona.displayName), на связь» — ассистент позвонит в очки, даже если телефон заблокирован.")
                GuideRow(number: 2, text: "Команды → Автоматизация → Bluetooth → ваши очки → «Выйти на связь»: надели очки — он позвонил.")
                GuideRow(number: 3, text: "Фокусирование: разрешите уведомления и звонки от этого приложения, иначе режим «Не беспокоить» заглушит вызов.")
            } header: {
                Text("Ассистент звонит сам")
            } footer: {
                Text("Из фона ассистент может только позвонить вам — принять вызов нужно касанием очков или на экране.")
            }

            Section {
                Stepper(value: $settings.followUpSeconds, in: 0...20, step: 2) {
                    LabeledContent("Продолжение без имени", value: settings.followUpSeconds == 0 ? "выкл." : "\(Int(settings.followUpSeconds)) с")
                }
            } footer: {
                Text("Столько секунд после ответа ассистент слушает уточняющий вопрос без обращения по имени.")
            }

            Section {
                Toggle("Жесты очков", isOn: $settings.glassesGestures)
                    .onChange(of: settings.glassesGestures) { _, _ in assistant.applyGlassesGestures() }
            } header: {
                Text("Эксперимент")
            } footer: {
                Text("Двойное касание дужки или кнопка камеры вызывают ассистента и перебивают ответ. Это пробная возможность очков: что именно приходит с ваших очков, видно в журнале. Одиночное касание и удержание очки оставляют себе.")
            }
        }
        .navigationTitle("На связи и фон")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }
}

private struct GuideRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("\(number)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.Tone.assistant.onColor)
                .frame(width: 22, height: 22)
                .background(Theme.Tone.assistant.color, in: Circle())
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Переводчик

struct TranslatorSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Озвучивать перевод", isOn: $settings.translatorSpeaks)
                Toggle("Собеседнику — из динамика телефона", isOn: $settings.translatorPartnerSpeaker)
                    .disabled(!settings.translatorSpeaks)
            } footer: {
                Text("Перевод слов собеседника звучит у вас в очках. Перевод ваших слов — из динамика телефона, чтобы его услышал собеседник. Без озвучки переводчик не делает пауз и показывает перевод на экране, пока человек ещё говорит.")
            }
        }
        .navigationTitle("Переводчик")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }
}

/// Имя, характер и манера — то же, что на первом запуске.
struct PersonaEditorView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Имя ассистента") {
                TextField("Джарвис", text: $settings.persona.assistantName)
                    .font(.title3)
            }
            Section("Как вас зовут") {
                TextField("Ваше имя", text: $settings.persona.userName)
            }
            Section {
                Picker("Характер", selection: $settings.persona.character) {
                    ForEach(PersonaCharacter.allCases) { character in
                        VStack(alignment: .leading) {
                            Text(character.title)
                            Text(character.summary).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .tag(character)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if settings.persona.character == .custom {
                    TextField("Опишите характер", text: $settings.persona.customCharacter, axis: .vertical)
                        .lineLimit(3...6)
                }
            } header: {
                Text("Характер")
            }
            Section("Манера") {
                Picker("Обращение", selection: $settings.persona.address) {
                    ForEach(AddressForm.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Ответы", selection: $settings.persona.length) {
                    ForEach(AnswerLength.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Юмор")
                    Slider(value: $settings.persona.humor, in: 0...1) {
                        Text("Юмор")
                    } minimumValueLabel: {
                        Image(systemName: "face.dashed")
                    } maximumValueLabel: {
                        Image(systemName: "face.smiling")
                    }
                }
            }
        }
        .navigationTitle("Ассистент")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Почта по IMAP с паролем приложения.
struct MailSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var checking = false
    @State private var result: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextField("Адрес, например you@gmail.com", text: $settings.mailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Пароль приложения", text: $settings.mailPassword)
                TextField("Сервер IMAP (необязательно)", text: $settings.mailHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("""
                Нужен не обычный пароль, а «пароль приложения»: Gmail — Аккаунт Google → Безопасность → Пароли приложений (нужна двухэтапная проверка); \
                Яндекс — Яндекс ID → Безопасность → Пароли приложений → Почта; Mail.ru — Настройки → Безопасность → Пароли для внешних приложений; \
                iCloud — appleid.apple.com → Пароли приложений. Сервер для этих почт определяется сам. Письма только читаются и не помечаются прочитанными.
                """)
            }
            Section {
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Проверить подключение")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(settings.mailAccount == nil || checking)
                if let result {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .navigationTitle("Почта")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func check() async {
        guard let account = settings.mailAccount else {
            result = "Для этого адреса нужен сервер IMAP."
            return
        }
        checking = true
        defer { checking = false }
        let client = IMAPClient(account: account, password: settings.mailPassword)
        do {
            let unread = try await client.recentMessages(unreadOnly: true, limit: 15)
            result = unread.isEmpty ? "Подключено. Непрочитанных писем нет." : "Подключено. Непрочитанных: \(unread.count)\(unread.count == 15 ? "+" : "")."
        } catch {
            result = error.localizedDescription
        }
        await client.close()
    }
}
