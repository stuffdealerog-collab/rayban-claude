import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlassesManager.self) private var glasses
    @Environment(\.dismiss) private var dismiss

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
                    Text("Голос")
                } footer: {
                    Text("В режиме «Без рук» ассистент отвечает только на фразы, которые начинаются с обращения, например: «\(settings.wakeWord), что передо мной?». Кнопка микрофона работает без обращения.")
                }

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
        }
    }
}
