import SwiftUI

/// Вкладки приложения: ассистент, переводчик, память, настройки.
struct MainTabView: View {
    @Environment(AssistantController.self) private var assistant
    @Environment(GlassesManager.self) private var glasses
    @Environment(TranslatorController.self) private var translator

    enum Tab: Hashable { case assistant, translator, memory, settings }

    @State private var tab: Tab = MainTabView.initialTab

    private var tone: Theme.Tone {
        switch tab {
        case .assistant: return .assistant
        case .translator: return .translator
        case .memory: return .memory
        case .settings: return .system
        }
    }

    private static var initialTab: Tab {
        #if DEBUG
        switch DemoMode.screen {
        case .some(let screen) where screen.hasPrefix("translator"): return .translator
        case "memory", "note": return .memory
        case "settings": return .settings
        default: break
        }
        #endif
        return .assistant
    }

    var body: some View {
        TabView(selection: $tab) {
            AssistantView()
                .tabItem { Label(L("Ассистент"), systemImage: "waveform") }
                .tag(Tab.assistant)
            TranslatorView()
                .tabItem { Label(L("Переводчик"), systemImage: "character.bubble") }
                .tag(Tab.translator)
            MemoryView()
                .tabItem { Label(L("Память"), systemImage: "books.vertical") }
                .tag(Tab.memory)
            SettingsView()
                .tabItem { Label(L("Настройки"), systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // У каждой вкладки свой цвет линии.
        .tint(tone.text)
        .onReceive(NotificationCenter.default.publisher(for: .openTranslator)) { _ in
            tab = .translator
        }
        .onChange(of: tab) { oldValue, _ in
            // Переводчик отдаёт микрофон ассистенту, как только с него уходят.
            if oldValue == .translator { translator.stop() }
        }
        .alert(L("Ошибка"), isPresented: errorBinding) {
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
