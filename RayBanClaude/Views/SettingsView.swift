import AssistantCore
import SwiftUI

/// Настройки: короткий список разделов, детали — внутри каждого.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlassesManager.self) private var glasses
    @Environment(AssistantController.self) private var assistant

    @State private var showGlasses = false
    @State private var confirmReset = false
    /// Раздел, открытый сразу при запуске для снимка (`-demo settings-voice`); в обычной работе пуст.
    @State private var opened: [String] = SettingsView.demoSection

    private static var demoSection: [String] {
        #if DEBUG
        if let screen = DemoMode.screen, screen.hasPrefix("settings-") {
            return [String(screen.dropFirst("settings-".count))]
        }
        #endif
        return []
    }

    var body: some View {
        NavigationStack(path: $opened) {
            Form {
                Section {
                    NavigationLink {
                        PersonaEditorView()
                    } label: {
                        SettingsRow(symbol: "person.crop.circle", tone: .assistant, title: settings.persona.displayName, value: characterSummary)
                    }
                } footer: {
                    Text(L("Имя, характер и манера общения."))
                        .foregroundStyle(Theme.textMuted)
                }
                .listRowBackground(Theme.surface)

                Section {
                    NavigationLink {
                        ConversationSettingsView()
                    } label: {
                        SettingsRow(symbol: "bubble.left.and.text.bubble.right", tone: .assistant, title: L("Разговор"), value: settings.language.title)
                    }
                    NavigationLink {
                        VoiceSettingsView()
                    } label: {
                        SettingsRow(symbol: "waveform", tone: .assistant, title: L("Голос"), value: voiceSummary)
                    }
                    NavigationLink {
                        ClaudeSettingsView()
                    } label: {
                        SettingsRow(symbol: "sparkles", tone: .assistant, title: "Claude", value: settings.trimmedAPIKey.isEmpty ? L("нет ключа") : settings.model.shortTitle)
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    NavigationLink {
                        BackgroundSettingsView()
                    } label: {
                        SettingsRow(symbol: "phone.arrow.down.left", tone: .assistant, title: L("На связи и фон"), value: nil)
                    }
                    Button {
                        showGlasses = true
                    } label: {
                        SettingsRow(symbol: "eyeglasses", tone: .system, title: L("Очки"), value: glassesSummary)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    NavigationLink {
                        MailSettingsView()
                    } label: {
                        SettingsRow(symbol: "envelope", tone: .translator, title: L("Почта"), value: settings.mailAccount == nil ? L("не подключена") : settings.mailAddress)
                    }
                    NavigationLink {
                        TranslatorSettingsView()
                    } label: {
                        SettingsRow(symbol: "character.bubble", tone: .translator, title: L("Переводчик"), value: nil)
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    NavigationLink {
                        JournalView()
                    } label: {
                        SettingsRow(symbol: "list.bullet.rectangle", tone: .system, title: L("Журнал"), value: nil)
                    }
                    Button(L("Пройти первую настройку заново")) { confirmReset = true }
                } header: {
                    Text(L("Данные"))
                        .foregroundStyle(Theme.textSecondary)
                } footer: {
                    Text(L("Заметки памяти — файлы Markdown: Файлы → На iPhone → это приложение. Ключи и пароль почты хранятся только в Keychain этого iPhone."))
                        .foregroundStyle(Theme.textMuted)
                }
                .listRowBackground(Theme.surface)

                #if DEBUG
                MockGlassesSection()
                #endif
            }
            .navigationTitle(L("Настройки"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationDestination(for: String.self) { name in section(name) }
            .sheet(isPresented: $showGlasses) { GlassesSheet() }
            .confirmationDialog(L("Пройти первую настройку заново?"), isPresented: $confirmReset, titleVisibility: .visible) {
                Button(L("Начать")) {
                    Task {
                        await assistant.setHandsFree(false)
                        assistant.interrupt()
                        settings.onboardingCompleted = false
                    }
                }
            } message: {
                Text(L("Память, ключи и разговоры сохранятся."))
            }
        }
    }

    @ViewBuilder
    private func section(_ name: String) -> some View {
        switch name {
        case "persona": PersonaEditorView()
        case "conversation": ConversationSettingsView()
        case "voice": VoiceSettingsView()
        case "claude": ClaudeSettingsView()
        case "background": BackgroundSettingsView()
        case "mail": MailSettingsView()
        case "translator": TranslatorSettingsView()
        default: JournalView()
        }
    }

    private var characterSummary: String {
        let persona = settings.persona
        return "\(persona.character.title), \(persona.address == .informal ? L("на «ты»") : L("на «вы»"))"
    }

    private var voiceSummary: String {
        if settings.trimmedElevenLabsKey.isEmpty { return L("голос iOS") }
        return settings.elevenLabsVoiceName.isEmpty ? "ElevenLabs" : settings.elevenLabsVoiceName
    }

    private var glassesSummary: String {
        guard glasses.isRegistered else { return L("не подключены") }
        guard glasses.hasActiveDevice else { return L("не рядом") }
        return glasses.batteryLevel.map { "\($0)%" } ?? L("на связи")
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
                Picker(L("Язык"), selection: $settings.language) {
                    ForEach(AssistantLanguage.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(L("На этом языке ассистент слушает и отвечает по умолчанию. Заговорите на другом из трёх — ответит на нём."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)

            Section {
                Picker(L("Когда отвечать"), selection: $settings.addressing) {
                    ForEach(AddressingMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if settings.addressing != .always {
                    TextField(L("Имя для обращения: %@", settings.persona.displayName), text: $settings.wakeWord)
                }
            } header: {
                Text(L("Когда отвечать"))
                    .foregroundStyle(Theme.textSecondary)
            } footer: {
                Text(L("%@ Действует в режимах «Без рук» и «На связи». Сразу после ответа можно продолжать без имени.", settings.addressing.detail))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)

            Section {
                Toggle(L("Распознавание ElevenLabs"), isOn: $settings.liveRecognition)
                    .disabled(settings.trimmedElevenLabsKey.isEmpty)
                if settings.usesLiveRecognition {
                    Toggle(L("Смешанная речь"), isOn: $settings.mixedSpeech)
                }
            } header: {
                Text(L("Распознавание"))
                    .foregroundStyle(Theme.textSecondary)
            } footer: {
                Text(recognitionFooter)
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)
        }
        .navigationTitle(L("Разговор"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private var recognitionFooter: String {
        if settings.trimmedElevenLabsKey.isEmpty {
            return L("Сейчас речь распознаёт Apple на самом iPhone: русский и английский. Для узбекского и для работы в фоне добавьте ключ ElevenLabs в разделе «Голос».")
        }
        if settings.usesLiveRecognition {
            return L("Речь распознаётся потоком: быстрее, точнее и с узбекским. «Смешанная речь» понимает узбекский и русский вперемешку в одной фразе, но может ошибаться на очень коротких репликах.")
        }
        return L("Русский и английский распознаёт Apple на самом iPhone, узбекский — ElevenLabs.")
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
                SecureField(L("Ключ ElevenLabs"), text: $settings.elevenLabsAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text(L("elevenlabs.io → Developers → API Keys. С ключом ассистент говорит живым голосом и понимает узбекский. Без ключа звучит голос iOS."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)

            if !settings.trimmedElevenLabsKey.isEmpty {
                Section {
                    if voices.isEmpty {
                        LabeledContent(L("Голос")) {
                            if loadingVoices {
                                ProgressView()
                            } else {
                                Text(voicesError ?? (settings.elevenLabsVoiceName.isEmpty ? L("нет голосов") : settings.elevenLabsVoiceName))
                                    .foregroundStyle(voicesError == nil ? Theme.textSecondary : Theme.negative)
                            }
                        }
                    } else {
                        Picker(L("Голос"), selection: $settings.elevenLabsVoiceID) {
                            if !voices.contains(where: { $0.voiceID == settings.elevenLabsVoiceID }) {
                                Text(settings.elevenLabsVoiceName.isEmpty ? L("Не выбран") : settings.elevenLabsVoiceName)
                                    .tag(settings.elevenLabsVoiceID)
                            }
                            ForEach(voices) { voice in
                                Text(title(for: voice)).tag(voice.voiceID)
                            }
                        }
                    }
                    Picker(L("Модель"), selection: $settings.elevenLabsModel) {
                        ForEach(ElevenLabsModel.allCases) { Text($0.title).tag($0) }
                    }
                    Button(L("Обновить список голосов")) {
                        Task { await loadVoices() }
                    }
                    .disabled(loadingVoices)
                } footer: {
                    Text(modelFooter)
                        .foregroundStyle(Theme.textMuted)
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                Toggle(L("Стерео в режиме кнопки"), isOn: $settings.stereoAnswers)
                Button(L("Проверить голос")) {
                    Task { await assistant.say(assistant.greeting) }
                }
                .disabled(assistant.phase != .idle || assistant.translatorActive)
            } footer: {
                Text(L("Стерео: когда вы спрашиваете по кнопке, ответ идёт в очки как музыка, а не в телефонном качестве гарнитуры."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)
        }
        .navigationTitle(L("Голос"))
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
        var text = settings.elevenLabsModel.streams
            ? L("Модели v4 говорят по-узбекски, по-русски и по-английски одним голосом; звук идёт потоком и начинается, пока ответ ещё пишется. Голоса носителей узбекского помечены «узб.»; другие добавляются из библиотеки голосов в «My Voices» на сайте ElevenLabs.")
            : L("Прежние модели озвучивают ответ фразу за фразой, с заметной паузой. Для быстрого ответа и узбекского выберите v4 Turbo.")
        if settings.elevenLabsFreePlan {
            text += "\n\n" + L("У вас бесплатный тариф ElevenLabs: в приложении работают только стандартные голоса. Голоса из библиотеки (Voice Library) требуют платного тарифа.")
        }
        return text
    }

    /// На бесплатном тарифе голоса из библиотеки помечены: выбрать можно, но сервер их отклонит.
    private func title(for voice: ElevenLabsVoice) -> String {
        settings.elevenLabsFreePlan && !voice.worksOnFreePlan ? voice.title + L(" · платный тариф") : voice.title
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
            let client = ElevenLabsClient()
            let list = try await client.voices(apiKey: key)
            // Тариф решает, какие голоса заработают; если ключ не даёт его узнать — остаётся прежний.
            let tier = try? await client.subscriptionTier(apiKey: key)
            guard key == settings.trimmedElevenLabsKey else { return }
            if let tier { settings.elevenLabsTier = tier }
            // Сначала то, что заработает на этом тарифе, внутри — голоса носителей языка ассистента.
            let native = settings.language.isoCode
            let free = settings.elevenLabsFreePlan
            voices = list.arranged(language: native, freePlan: free)
            if settings.elevenLabsVoiceID.isEmpty, let first = list.preferred(language: native, freePlan: free) ?? voices.first {
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
                SecureField(L("API-ключ Anthropic"), text: $settings.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text(L("platform.claude.com → API Keys. Оплата — за использование."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)

            Section {
                Picker(L("Модель"), selection: $settings.model) {
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
                Text(L("Модель"))
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)

            Section {
                Toggle(L("Отвечать сразу"), isOn: $settings.instantAnswers)
                    .disabled(settings.model.instantThinking == nil)
                Toggle(L("Поиск в интернете"), isOn: $settings.webSearchEnabled)
                Toggle(L("Экономить на длинных разговорах"), isOn: $settings.saveTokens)
            } footer: {
                Text(L("«Отвечать сразу»: модель не размышляет перед ответом, первая фраза звучит раньше. Для сложных вопросов выключите. Экономия: из длинного разговора сервер убирает старые снимки и результаты поиска."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)
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
                Text(L("iOS не даёт приложению включить микрофон, когда оно уже свёрнуто. Исключение — звонки. Поэтому разговор с заблокированным телефоном идёт как звонок: нажмите «На связи» на главном экране, заблокируйте телефон и уберите его в карман."))
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            } header: {
                Text(L("Как это работает"))
                    .foregroundStyle(Theme.textSecondary)
            } footer: {
                Text(L("Пока идёт такой звонок, звук в очках телефонного качества, музыка на паузе, очки расходуют заряд как при разговоре. Чтобы закончить, скажите «Отбой» или завершите вызов."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)

            Section {
                GuideRow(number: 1, text: L("Siri: «%@, на связь» — ассистент позвонит в очки, даже если телефон заблокирован.", settings.persona.displayName))
                GuideRow(number: 2, text: L("Команды → Автоматизация → Bluetooth → ваши очки → «Выйти на связь»: надели очки — он позвонил."))
                GuideRow(number: 3, text: L("Фокусирование: разрешите уведомления и звонки от этого приложения, иначе режим «Не беспокоить» заглушит вызов."))
            } header: {
                Text(L("Ассистент звонит сам"))
                    .foregroundStyle(Theme.textSecondary)
            } footer: {
                Text(L("Из фона ассистент может только позвонить вам — принять вызов нужно касанием очков или на экране."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)

            Section {
                Stepper(value: $settings.followUpSeconds, in: 0...20, step: 2) {
                    LabeledContent(L("Продолжение без имени"), value: settings.followUpSeconds == 0 ? L("выкл.") : L("%@ с", Int(settings.followUpSeconds)))
                }
            } footer: {
                Text(L("Столько секунд после ответа ассистент слушает уточняющий вопрос без обращения по имени."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)

            Section {
                Toggle(L("Жесты очков"), isOn: $settings.glassesGestures)
                    .onChange(of: settings.glassesGestures) { _, _ in assistant.applyGlassesGestures() }
            } header: {
                Text(L("Эксперимент"))
                    .foregroundStyle(Theme.textSecondary)
            } footer: {
                Text(L("Двойное касание дужки или кнопка камеры вызывают ассистента и перебивают ответ. Это пробная возможность очков: что именно приходит с ваших очков, видно в журнале. Одиночное касание и удержание очки оставляют себе."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)
        }
        .navigationTitle(L("На связи и фон"))
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
                Toggle(L("Озвучивать перевод"), isOn: $settings.translatorSpeaks)
                Toggle(L("Собеседнику — из динамика телефона"), isOn: $settings.translatorPartnerSpeaker)
                    .disabled(!settings.translatorSpeaks)
            } footer: {
                Text(L("Перевод слов собеседника звучит у вас в очках. Перевод ваших слов — из динамика телефона, чтобы его услышал собеседник. Без озвучки переводчик не делает пауз и показывает перевод на экране, пока человек ещё говорит."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)
        }
        .navigationTitle(L("Переводчик"))
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
            Section {
                TextField(L("Джарвис"), text: $settings.persona.assistantName)
                    .font(.title3)
            } header: {
                Text(L("Имя ассистента"))
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
            Section {
                TextField(L("Ваше имя"), text: $settings.persona.userName)
            } header: {
                Text(L("Как вас зовут"))
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
            Section {
                Picker(L("Характер"), selection: $settings.persona.character) {
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
                    TextField(L("Опишите характер"), text: $settings.persona.customCharacter, axis: .vertical)
                        .lineLimit(3...6)
                }
            } header: {
                Text(L("Характер"))
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
            Section {
                Picker(L("Обращение"), selection: $settings.persona.address) {
                    ForEach(AddressForm.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(L("Ответы"), selection: $settings.persona.length) {
                    ForEach(AnswerLength.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(L("Юмор"))
                    Slider(value: $settings.persona.humor, in: 0...1) {
                        Text(L("Юмор"))
                    } minimumValueLabel: {
                        Image(systemName: "face.dashed")
                    } maximumValueLabel: {
                        Image(systemName: "face.smiling")
                    }
                }
            } header: {
                Text(L("Манера"))
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
        }
        .navigationTitle(L("Ассистент"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
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
                TextField(L("Адрес, например you@gmail.com"), text: $settings.mailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(L("Пароль приложения"), text: $settings.mailPassword)
                TextField(L("Сервер IMAP (необязательно)"), text: $settings.mailHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text(L("Нужен не обычный пароль, а «пароль приложения»: Gmail — Аккаунт Google → Безопасность → Пароли приложений (нужна двухэтапная проверка); Яндекс — Яндекс ID → Безопасность → Пароли приложений → Почта; Mail.ru — Настройки → Безопасность → Пароли для внешних приложений; iCloud — appleid.apple.com → Пароли приложений. Сервер для этих почт определяется сам. Письма только читаются и не помечаются прочитанными."))
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)
            Section {
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text(L("Проверить подключение"))
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
            .listRowBackground(Theme.surface)
        }
        .navigationTitle(L("Почта"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private func check() async {
        guard let account = settings.mailAccount else {
            result = L("Для этого адреса нужен сервер IMAP.")
            return
        }
        checking = true
        defer { checking = false }
        let client = IMAPClient(account: account, password: settings.mailPassword)
        do {
            let unread = try await client.recentMessages(unreadOnly: true, limit: 15)
            result = unread.isEmpty ? L("Подключено. Непрочитанных писем нет.") : L("Подключено. Непрочитанных: %@%@.", unread.count, unread.count == 15 ? "+" : "")
        } catch {
            result = error.localizedDescription
        }
        await client.close()
    }
}
