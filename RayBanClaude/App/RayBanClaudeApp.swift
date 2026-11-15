import AssistantCore
import MWDATCore
import SwiftUI

@main
struct RayBanClaudeApp: App {
    @State private var settings: AppSettings
    @State private var glasses: GlassesManager
    @State private var assistant: AssistantController
    @State private var translator: TranslatorController

    init() {
        // DAT нужно сконфигурировать один раз до первого обращения к Wearables.shared.
        do {
            try Wearables.configure()
        } catch {
            NSLog("[RayBanClaude] Wearables.configure failed: \(error)")
        }
        let settings = AppSettings()
        let glasses = GlassesManager()
        let memory = MemoryStore(root: Self.memoryFolder)
        try? memory.ensureExists()
        let assistant = AssistantController(settings: settings, glasses: glasses, memory: memory)
        _settings = State(initialValue: settings)
        _glasses = State(initialValue: glasses)
        _assistant = State(initialValue: assistant)
        _translator = State(initialValue: TranslatorController(settings: settings, assistant: assistant))
    }

    /// Папка памяти видна в приложении «Файлы» (На iPhone → это приложение → Память).
    private static var memoryFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Память", isDirectory: true)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(glasses)
                .environment(assistant)
                .environment(translator)
                // Возврат из Meta AI после регистрации или выдачи разрешений.
                .onOpenURL { url in
                    Task { await glasses.handle(url: url) }
                }
        }
    }
}

/// Первая настройка или приложение.
struct RootView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack {
            if settings.onboardingCompleted {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(Theme.ease(0.5), value: settings.onboardingCompleted)
        .tint(Theme.accent)
    }
}
