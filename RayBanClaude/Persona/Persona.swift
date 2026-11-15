import Foundation

/// Характер ассистента — пользователь выбирает его при первом запуске.
enum PersonaCharacter: String, CaseIterable, Codable, Identifiable, Sendable {
    case warm
    case calm
    case witty
    case business
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .warm: return "Тёплый"
        case .calm: return "Спокойный"
        case .witty: return "С иронией"
        case .business: return "Деловой"
        case .custom: return "Свой"
        }
    }

    var summary: String {
        switch self {
        case .warm: return "Заботливый друг: замечает настроение, поддержит и напомнит о важном"
        case .calm: return "Собранный и точный: говорит по делу, без лишних эмоций"
        case .witty: return "Остроумный: шутит к месту, но дело делает всерьёз"
        case .business: return "Как личный секретарь: коротко, чётко, всё под контролем"
        case .custom: return "Опишите характер своими словами"
        }
    }

    /// Описание для системного промпта.
    var prompt: String {
        switch self {
        case .warm:
            return "Тёплый и внимательный, как близкий друг. Замечаешь настроение собеседника, искренне радуешься его успехам, мягко поддерживаешь, когда трудно. Не приторный: забота в делах, а не в словах."
        case .calm:
            return "Спокойный, собранный и точный. Говоришь размеренно и по существу, без лишних эмоций и оценок. Рядом с тобой спокойно."
        case .witty:
            return "Умный и остроумный, с лёгкой самоиронией и сдержанностью британского дворецкого. Шутишь коротко и к месту, иногда подтруниваешь по-доброму, но задачи решаешь всерьёз и никогда не шутишь над бедой."
        case .business:
            return "Деловой, как опытный личный секретарь. Коротко, чётко, без воды. Держишь в голове планы и сроки, сам предлагаешь следующий шаг."
        case .custom:
            return ""
        }
    }
}

/// Обращение к пользователю.
enum AddressForm: String, CaseIterable, Codable, Identifiable, Sendable {
    case informal
    case formal

    var id: String { rawValue }
    var title: String { self == .informal ? "На «ты»" : "На «вы»" }
}

/// Длина ответов.
enum AnswerLength: String, CaseIterable, Codable, Identifiable, Sendable {
    case brief
    case balanced
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: return "Коротко"
        case .balanced: return "Обычно"
        case .detailed: return "Подробно"
        }
    }

    var prompt: String {
        switch self {
        case .brief: return "Отвечай очень коротко: обычно одна-две фразы. Подробнее — только если попросят."
        case .balanced: return "Отвечай коротко, как в живом разговоре: обычно две-четыре фразы."
        case .detailed: return "Можешь отвечать развёрнуто, если вопрос того требует, но без воды и без перечислений."
        }
    }
}

/// Личность ассистента и то, что он знает о пользователе с первого дня.
struct Persona: Codable, Equatable, Sendable {
    var assistantName = "Джарвис"
    var userName = ""
    var character: PersonaCharacter = .warm
    var customCharacter = ""
    var address: AddressForm = .informal
    var length: AnswerLength = .brief
    /// 0 — без шуток, 1 — шутит часто.
    var humor = 0.4

    var displayName: String {
        let trimmed = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Джарвис" : trimmed
    }

    var characterPrompt: String {
        if character == .custom {
            let text = customCharacter.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? PersonaCharacter.warm.prompt : text
        }
        return character.prompt
    }

    var humorPrompt: String {
        switch humor {
        case ..<0.15: return "Не шути."
        case ..<0.5: return "Шути редко и только если это уместно."
        case ..<0.8: return "Можешь шутить, когда к месту."
        default: return "Чувство юмора — твоя сильная сторона: шути часто, но не в ущерб делу."
        }
    }

    /// Варианты имён на экране выбора.
    static let suggestedNames = ["Джарвис", "Пятница", "Клод", "Лола", "Тимур", "Ева"]
}
