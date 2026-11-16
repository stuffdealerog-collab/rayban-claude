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
        await AppContainer.shared.assistant.listenFromShortcut()
        return .result()
    }
}

/// «На связь»: ассистент звонит в очки — примите вызов и говорите. В отличие от «Спросить»,
/// работает с заблокированным телефоном и из автоматизаций («надел очки», «в 8:00»).
struct ConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Выйти на связь"
    static let description = IntentDescription(
        "Ассистент звонит вам: примите вызов касанием очков и говорите. Работает с заблокированным телефоном."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        journal("команда", "«Выйти на связь»")
        await AppContainer.shared.assistant.ringUser()
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
            intent: ConnectIntent(),
            phrases: [
                "\(.applicationName), на связь",
                "Свяжи меня с \(.applicationName)",
                "Call me, \(.applicationName)",
            ],
            shortTitle: "На связь",
            systemImageName: "phone.arrow.down.left"
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
