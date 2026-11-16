import AssistantCore
import MWDATCore
import SwiftUI
import UserNotifications

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
        // Таймеры звучат и при открытом приложении.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        let settings = AppSettings()
        let glasses = GlassesManager()
        #if DEBUG
        let memory = MemoryStore(root: DemoMode.isActive ? DemoMode.memoryFolder : Self.memoryFolder)
        #else
        let memory = MemoryStore(root: Self.memoryFolder)
        #endif
        try? memory.ensureExists()
        let assistant = AssistantController(settings: settings, glasses: glasses, memory: memory)
        let translator = TranslatorController(settings: settings, assistant: assistant)
        #if DEBUG
        DemoMode.prepare(settings: settings, assistant: assistant, memory: memory)
        DemoMode.prepare(translator: translator)
        #endif
        _settings = State(initialValue: settings)
        _glasses = State(initialValue: glasses)
        _assistant = State(initialValue: assistant)
        _translator = State(initialValue: translator)
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

/// Показывает уведомления (таймеры, будильники) и когда приложение на экране.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
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
