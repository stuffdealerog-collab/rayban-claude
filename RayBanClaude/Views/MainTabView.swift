import SwiftUI

/// Вкладки приложения: ассистент, переводчик, память, настройки.
struct MainTabView: View {
    @Environment(AssistantController.self) private var assistant
    @Environment(GlassesManager.self) private var glasses
    @Environment(TranslatorController.self) private var translator

    enum Tab: Hashable { case assistant, translator, memory, settings }

    @State private var tab: Tab = .assistant

    var body: some View {
        TabView(selection: $tab) {
            AssistantView()
                .tabItem { Label("Ассистент", systemImage: "waveform") }
                .tag(Tab.assistant)
            TranslatorView()
                .tabItem { Label("Переводчик", systemImage: "character.bubble") }
                .tag(Tab.translator)
            MemoryView()
                .tabItem { Label("Память", systemImage: "books.vertical") }
                .tag(Tab.memory)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTranslator)) { _ in
            tab = .translator
        }
        .onChange(of: tab) { oldValue, _ in
            // Переводчик отдаёт микрофон ассистенту, как только с него уходят.
            if oldValue == .translator { translator.stop() }
        }
        .alert("Ошибка", isPresented: errorBinding) {
            Button("OK") {
                assistant.dismissError()
                glasses.clearError()
            }
        } message: {
            Text(assistant.errorMessage ?? glasses.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { (assistant.errorMessage != nil && !assistant.translatorActive) || glasses.lastError != nil },
            set: { if !$0 { assistant.dismissError(); glasses.clearError() } }
        )
    }
}
