import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlassesManager.self) private var glasses
    @Environment(AssistantController.self) private var assistant
    @Environment(\.dismiss) private var dismiss

    @State private var voices: [ElevenLabsVoice] = []
    @State private var loadingVoices = false
    @State private var voicesError: String?

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Модель", selection: $settings.model) {
                        ForEach(ClaudeModel.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Поиск в интернете", isOn: $settings.webSearchEnabled)
                } header: {
                    Text("Claude")
                } footer: {
                    Text("Ключ создаётся в Claude Console (platform.claude.com) и хранится в Keychain этого iPhone. Поиск в интернете должен быть разрешён для организации в Console.")
                }

                Section {
                    Picker("Язык", selection: $settings.language) {
                        ForEach(AssistantLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Обращение по имени", isOn: $settings.wakeWordEnabled)
                    if settings.wakeWordEnabled {
                        TextField("Слово-обращение", text: $settings.wakeWord)
                    }
                } header: {
                    Text("Речь")
                } footer: {
                    Text("В режиме «Без рук» ассистент отвечает только на фразы, которые начинаются с обращения, например: «\(settings.wakeWord), что передо мной?». Кнопка микрофона работает без обращения.")
                }

                voiceSection(settings)

                Section("Очки") {
                    LabeledContent("Регистрация", value: glasses.isRegistered ? "подключены" : "нет")
                    LabeledContent("Рядом", value: glasses.hasActiveDevice ? "да" : "нет")
                    if let battery = glasses.batteryLevel {
                        LabeledContent("Заряд", value: "\(battery)%")
                    }
                    if glasses.isRegistered {
                        Button("Разрешить камеру в Meta AI") {
                            Task { await glasses.requestCameraPermission() }
                        }
                        Button("Отключить приложение от очков", role: .destructive) {
                            Task { await glasses.disconnect() }
                        }
                    } else {
                        Button("Подключить очки через Meta AI") {
                            Task { await glasses.connect() }
                        }
                    }
                }

                #if DEBUG
                MockGlassesSection()
                #endif
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
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
                                .foregroundStyle(voicesError == nil ? Color.secondary : Color.red)
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
                Task { await assistant.previewVoice() }
            }
            .disabled(assistant.phase != .idle)
        } header: {
            Text("Голос ассистента")
        } footer: {
            Text("""
            С ключом ElevenLabs (elevenlabs.io → Developers → API Keys) ассистент говорит нейросетевым голосом. \
            Голоса с пометкой «рус.» записаны носителями русского; другие можно добавить в «My Voices» из Voice Library \
            на сайте ElevenLabs. Без ключа или без сети звучит голос iOS — лучший из установленных: \
            Настройки → Универсальный доступ → Устный контент → Голоса.
            Стерео: в режиме кнопки ответ идёт в очки как музыка (A2DP), а не в «телефонном» качестве гарнитуры. \
            В режиме «Без рук» микрофон включён всегда, поэтому там звук остаётся гарнитурным.
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
