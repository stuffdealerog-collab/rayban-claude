import AssistantCore
import MWDATCore
import SwiftUI
import UIKit
import UserNotifications

/// Все долгоживущие объекты приложения. Создаётся один раз — и когда приложение открыл человек,
/// и когда система запустила его в фоне ради команды Siri или автоматизации.
@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let settings: AppSettings
    let glasses: GlassesManager
    let memory: MemoryStore
    let assistant: AssistantController
    let translator: TranslatorController

    private init() {
        // DAT нужно сконфигурировать один раз до первого обращения к Wearables.shared.
        do {
            try Wearables.configure()
        } catch {
            NSLog("[RayBanClaude] Wearables.configure failed: \(error)")
        }
        Theme.applyNavigationAppearance()
        // Таймеры звучат и при открытом приложении.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        settings = AppSettings()
        glasses = GlassesManager()
        #if DEBUG
        memory = MemoryStore(root: DemoMode.isActive ? DemoMode.memoryFolder : Self.memoryFolder)
        #else
        memory = MemoryStore(root: Self.memoryFolder)
        #endif
        try? memory.ensureExists()
        assistant = AssistantController(settings: settings, glasses: glasses, memory: memory)
        translator = TranslatorController(settings: settings, assistant: assistant)
        #if DEBUG
        DemoMode.prepare(settings: settings, assistant: assistant, memory: memory)
        DemoMode.prepare(translator: translator)
        #endif
        journal("приложение", "запуск, состояние: \(UIApplication.shared.applicationState == .background ? "фон" : "экран")")
    }

    /// Папка памяти видна в приложении «Файлы» (На iPhone → это приложение → Память).
    private static var memoryFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(L("Память"), isDirectory: true)
    }
}

@main
struct RayBanClaudeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let container = AppContainer.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                // Смена языка перестраивает интерфейс целиком: надписи берутся из каталога заново.
                .id(container.settings.language)
                .environment(\.locale, Locale(identifier: container.settings.language.rawValue))
                .environment(container.settings)
                .environment(container.glasses)
                .environment(container.assistant)
                .environment(container.translator)
                // Возврат из Meta AI после регистрации или выдачи разрешений.
                .onOpenURL { url in
                    Task { await container.glasses.handle(url: url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: journal("приложение", "на экране")
            case .background:
                journal("приложение", "в фоне")
                DiagnosticLog.shared.save()
            default: break
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
    }
}
