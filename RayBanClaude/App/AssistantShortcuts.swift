import AppIntents
import Foundation

/// «Слушай» из Siri, кнопки «Действие», виджета «Команд» или экрана блокировки:
/// открывает приложение и сразу включает микрофон.
struct ListenIntent: AppIntent {
    static let title: LocalizedStringResource = "Спросить ассистента"
    static let description = IntentDescription("Открывает ассистента и сразу начинает слушать.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await AssistantController.shared?.listenFromShortcut()
        return .result()
    }
}

/// Перевод разговора одной командой.
struct TranslateIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть переводчик"
    static let description = IntentDescription("Открывает переводчик.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .openTranslator, object: nil)
        return .result()
    }
}

struct AssistantShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListenIntent(),
            phrases: [
                "Спросить \(.applicationName)",
                "Слушай, \(.applicationName)",
                "Ask \(.applicationName)",
            ],
            shortTitle: "Спросить",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: TranslateIntent(),
            phrases: [
                "Переводчик в \(.applicationName)",
                "Translate with \(.applicationName)",
            ],
            shortTitle: "Переводчик",
            systemImageName: "character.bubble"
        )
    }
}

extension Notification.Name {
    /// Открыть вкладку переводчика (из команды Siri).
    static let openTranslator = Notification.Name("openTranslator")
}
