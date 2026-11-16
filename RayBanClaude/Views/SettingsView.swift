import AssistantCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlassesManager.self) private var glasses
    @Environment(AssistantController.self) private var assistant

    @State private var voices: [ElevenLabsVoice] = []
    @State private var loadingVoices = false
    @State private var voicesError: String?
    @State private var showGlasses = false
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        PersonaEditorView()
                    } label: {
                        LabeledContent(settings.persona.displayName, value: characterSummary)
                    }
                } header: {
                    Text("Ассистент")
                } footer: {
                    Text("Имя, характер и манера общения.")
                }

                Section {
                    Picker("Язык управления", selection: $settings.language) {
                        ForEach(AssistantLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Обращение по имени", isOn: $settings.wakeWordEnabled)
                    if settings.wakeWordEnabled {
                        TextField("Обращение: \(settings.persona.displayName)", text: $settings.wakeWord)
                    }
                } header: {
                    Text("Речь")
                } footer: {
                    Text(speechFooter)
                }

                voiceSection(settings)

                Section {
                    SecureField("API-ключ Anthropic", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Модель", selection: $settings.model) {
                        ForEach(ClaudeModel.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    Toggle("Поиск в интернете", isOn: $settings.webSearchEnabled)
                    Toggle("Экономить токены", isOn: $settings.saveTokens)
                } header: {
                    Text("Claude")
                } footer: {
                    Text("\(settings.model.subtitle). Ключ создаётся в Claude Console (platform.claude.com) и хранится только в Keychain этого iPhone. «Экономить токены»: в длинном разговоре сервер убирает старые снимки и результаты поиска.")
                }

                Section("Почта и связь") {
                    NavigationLink {
                        MailSettingsView()
                    } label: {
                        LabeledContent("Почта", value: settings.mailAccount == nil ? "не подключена" : settings.mailAddress)
                    }
                    Button("Очки Ray-Ban Meta") { showGlasses = true }
                }

                Section {
                    LabeledContent("Где хранятся", value: "Файлы → На iPhone")
                    Button("Пройти первую настройку заново") { confirmReset = true }
                } header: {
                    Text("Память и данные")
                } footer: {
                    Text("Заметки памяти — обычные файлы Markdown в папке приложения. Ключи и пароль почты — только в Keychain этого iPhone.")
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
    }

    private var characterSummary: String {
        let persona = settings.persona
        return "\(persona.character.title), \(persona.address == .informal ? "на «ты»" : "на «вы»")"
    }

    private var speechFooter: String {
        var text = "На этом языке ассистент слушает и по умолчанию отвечает. Заговорите на другом из трёх — ответит на нём."
        if settings.language == .uzbek && settings.trimmedElevenLabsKey.isEmpty {
            text += " Узбекскую речь Apple не распознаёт и не озвучивает — добавьте ключ ElevenLabs ниже."
        }
        return text
    }

    // MARK: - Голос

    @ViewBuilder
    private func voiceSection(_ model: AppSettings) -> some View {
        @Bindable var settings = model
        Section {
            SecureField("Ключ ElevenLabs (необязательно)", text: $settings.elevenLabsAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !settings.trimmedElevenLabsKey.isEmpty {
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
            }

            Toggle("Стерео-звук ответов", isOn: $settings.stereoAnswers)

            Button("Проверить голос") {
                Task { await assistant.say(assistant.greeting) }
            }
            .disabled(assistant.phase != .idle || assistant.translatorActive)
        } header: {
            Text("Голос")
        } footer: {
            Text("""
            С ключом ElevenLabs (elevenlabs.io → Developers → API Keys) ассистент говорит живым голосом и понимает узбекскую речь. \
            Голоса с пометкой «рус.» записаны носителями русского; другие можно добавить в «My Voices» на сайте ElevenLabs. \
            Узбекский всегда озвучивает модель v3. Без ключа звучит лучший голос iOS: Настройки → Универсальный доступ → Устный контент → Голоса.
            Стерео: в режиме кнопки ответ идёт в очки как музыка (A2DP), а не в «телефонном» качестве гарнитуры.
            """)
        }
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
            // Русские голоса — первыми, остальные в порядке ElevenLabs.
            voices = list.filter(\.isRussian) + list.filter { !$0.isRussian }
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
