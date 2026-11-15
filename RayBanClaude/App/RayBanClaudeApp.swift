import MWDATCore
import SwiftUI

@main
struct RayBanClaudeApp: App {
    @State private var settings: AppSettings
    @State private var glasses: GlassesManager
    @State private var assistant: AssistantController

    init() {
        // DAT нужно сконфигурировать один раз до первого обращения к Wearables.shared.
        do {
            try Wearables.configure()
        } catch {
            NSLog("[RayBanClaude] Wearables.configure failed: \(error)")
        }
        let settings = AppSettings()
        let glasses = GlassesManager()
        _settings = State(initialValue: settings)
        _glasses = State(initialValue: glasses)
        _assistant = State(initialValue: AssistantController(settings: settings, glasses: glasses))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(glasses)
                .environment(assistant)
                // Возврат из Meta AI после регистрации или выдачи разрешений.
                .onOpenURL { url in
                    Task { await glasses.handle(url: url) }
                }
        }
    }
}
