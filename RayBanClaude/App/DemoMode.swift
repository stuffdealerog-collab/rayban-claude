#if DEBUG
import AssistantCore
import Foundation
import UIKit

/// Готовые состояния экранов для снимков в CI: запуск с аргументами `-demo <экран>`.
/// Работает только в Debug и ничего не пишет в настоящую память.
@MainActor
enum DemoMode {
    nonisolated static let screen: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-demo"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    nonisolated static var isActive: Bool { screen != nil }

    /// `onboarding-3` → шаг 3.
    nonisolated static var onboardingStep: Int? {
        guard let screen, screen.hasPrefix("onboarding-") else { return nil }
        return Int(screen.dropFirst("onboarding-".count))
    }

    nonisolated static var memoryFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("demo-memory", isDirectory: true)
    }

    static func prepare(settings: AppSettings, assistant: AssistantController, memory: MemoryStore) {
        guard let screen else { return }
        settings.onboardingCompleted = onboardingStep == nil
        settings.persona.assistantName = "Джарвис"
        settings.persona.userName = "Тимур"
        seed(memory)

        switch screen {
        case "assistant-chat":
            assistant.loadDemo(entries: chat, phase: .idle)
        case "assistant-listening":
            assistant.loadDemo(entries: Array(chat.prefix(3)), phase: .listening, partial: "Напомни в час выйти")
        case "assistant-speaking":
            assistant.loadDemo(entries: Array(chat.prefix(3)), phase: .speaking)
        default:
            break
        }
    }

    static func prepare(translator: TranslatorController) {
        guard screen == "translator-chat" else { return }
        translator.loadDemo(entries: [
            .init(original: "Сколько стоит этот ковёр?", translation: "Bu gilam qancha turadi?", fromMe: true,
                  sourceName: "Русский", targetName: "Oʻzbekcha", isFinished: true),
            .init(original: "Ikki million soʻm, lekin sizga arzonroq beraman.", translation: "Два миллиона сумов, но вам отдам дешевле.",
                  fromMe: false, sourceName: "Oʻzbekcha", targetName: "Русский", isFinished: true),
            .init(original: "А ручная работа?", translation: "Qoʻl mehnatimi?", fromMe: true,
                  sourceName: "Русский", targetName: "Oʻzbekcha", isFinished: true),
        ])
    }

    private static var chat: [TranscriptEntry] {
        var photo = TranscriptEntry(role: .tool, text: "Смотрю через очки", symbol: "camera.viewfinder", toolName: "take_photo")
        if let url = Bundle.main.url(forResource: "mock_photo", withExtension: "jpg"), let data = try? Data(contentsOf: url) {
            photo.image = UIImage(data: data)
        }
        return [
            TranscriptEntry(role: .user, text: "Что у меня завтра?"),
            TranscriptEntry(role: .tool, text: "Смотрю календарь", symbol: "calendar", toolName: "list_events"),
            TranscriptEntry(role: .assistant, text: "Завтра в десять созвон с командой, в половине третьего стоматолог на Амира Темура. Вечер свободен."),
            TranscriptEntry(role: .user, text: "Напомни в час выйти пораньше"),
            TranscriptEntry(role: .tool, text: "Создаю напоминание", symbol: "checklist", toolName: "create_reminder"),
            TranscriptEntry(role: .assistant, text: "Готово, напомню в 13:00."),
            TranscriptEntry(role: .user, text: "Что передо мной?"),
            photo,
            TranscriptEntry(role: .assistant, text: "Вход в медресе Кукельдаш, шестнадцатый век. Справа касса, билет стоит двадцать тысяч сумов."),
        ]
    }

    private static func seed(_ memory: MemoryStore) {
        try? FileManager.default.removeItem(at: memoryFolder)
        try? memory.ensureExists()
        let notes: [(String, String)] = [
            ("Обо мне.md", "# Обо мне\n\n- Имя: Тимур\n- Живу в Ташкенте, работаю архитектором\n- Не ем острое\n- Утром бегаю в парке, встаю в 6:30\n- Сестра — [[Анна]], друг — [[Рустам]]\n"),
            ("Люди/Анна.md", "# Анна\n\nСестра. Живёт в Самарканде.\n\n- День рождения: 12 марта\n- Любит зелёный чай и керамику\n- Дочь Малика, 6 лет\n\nСвязано: [[Поездка в Самарканд]]\n"),
            ("Люди/Рустам.md", "# Рустам\n\nДруг и коллега, ведёт проект на Чиланзаре.\n\n- Созвон по вторникам в 10:00\n"),
            ("Дела/Поездка в Самарканд.md", "# Поездка в Самарканд\n\n- Поезд «Афросиаб», суббота, 8:00\n- Подарок для [[Анна|Анны]]: чайный набор\n- Взять чертежи для Рустама\n"),
            ("Предпочтения.md", "# Предпочтения\n\n- Отвечать коротко\n- Новости — только про город и технологии\n"),
        ]
        for (path, text) in notes { try? memory.write(path, text: text) }
    }
}
#endif
