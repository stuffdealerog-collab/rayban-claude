import ClaudeKit
import Foundation

/// Когда ассистент отвечает на услышанное в режимах «Без рук» и «На связи».
enum AddressingMode: String, CaseIterable, Identifiable, Sendable {
    /// Сам понимает, что фраза обращена к нему — как собеседник за столом.
    case smart
    /// Только если назвали по имени.
    case name
    /// На каждую услышанную фразу.
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: return L("Сам понимает")
        case .name: return L("Только по имени")
        case .always: return L("На каждую фразу")
        }
    }

    var detail: String {
        switch self {
        case .smart: return L("Отвечает, когда фраза обращена к нему, и молчит, когда вы говорите с другими. Имя не обязательно.")
        case .name: return L("Отвечает, только если фраза начинается с имени.")
        case .always: return L("Отвечает на всё, что слышит. Для тихого места, где вы один.")
        }
    }
}

/// Решает, обращена ли услышанная фраза к ассистенту. Это быстрый и дешёвый запрос к Claude Haiku 5.5:
/// фраза, имя ассистента и последние реплики разговора. Основная модель в этом не участвует —
/// чужие разговоры не попадают в историю диалога и не стоят денег.
struct AddresseeGate: Sendable {
    let client = ClaudeClient()

    struct Context: Sendable {
        var assistantName: String
        var userName: String
        /// Последний вопрос пользователя и ответ ассистента, если разговор шёл недавно.
        var lastQuestion: String?
        var lastAnswer: String?
        var secondsSinceAnswer: Int?
    }

    /// true — фраза к ассистенту. При сбое сети — false: лучше промолчать, чем ответить невпопад.
    func isAddressed(_ phrase: String, context: Context, apiKey: String) async -> Bool {
        let system = """
        Ты — слух голосового ассистента по имени «\(context.assistantName)», который живёт в умных очках. \
        Микрофон очков слышит всё: обращения хозяина к ассистенту, его разговоры с другими людьми, чужую речь, \
        телевизор. Реши, обращена ли последняя услышанная фраза к ассистенту. Фразы бывают на русском, узбекском \
        и английском, в том числе вперемешку.

        К ассистенту обращены: вопросы и просьбы, которые выполняет ассистент (узнать, найти, напомнить, записать, \
        перевести, позвонить, написать, посмотреть камерой, рассказать, посчитать); продолжение недавнего разговора \
        с ним (уточнение, ответ на его вопрос, «а завтра?», «спасибо», «не надо»); фразы с его именем.

        Не к ассистенту: реплики другому человеку (обращение по чужому имени, бытовой разговор, «передай», \
        «пойдём», «как дела у мамы»), обрывки чужих разговоров, мысли вслух без просьбы, речь из телевизора, \
        приветствия и прощания с людьми.

        Если разговор с ассистентом шёл только что и фраза может быть его продолжением — считай, что к нему. \
        Если сомневаешься и недавнего разговора не было — не к нему.

        Ответь одним словом: YES или NO.
        """
        var lines: [String] = []
        if let question = context.lastQuestion, let answer = context.lastAnswer, let seconds = context.secondsSinceAnswer {
            lines.append("Последний обмен с ассистентом (\(seconds) с назад):")
            lines.append("Хозяин: \(question.prefix(200))")
            lines.append("Ассистент: \(answer.prefix(300))")
        } else {
            lines.append("Недавнего разговора с ассистентом не было.")
        }
        if !context.userName.isEmpty { lines.append("Хозяина зовут \(context.userName).") }
        lines.append("Услышанная фраза: «\(phrase)»")

        let body: JSONValue = [
            "model": "claude-haiku-5-5",
            "max_tokens": 8,
            "stream": true,
            "system": [["type": "text", "text": .string(system)]],
            "messages": [["role": "user", "content": [["type": "text", "text": .string(lines.joined(separator: "\n"))]]]],
            "thinking": ["type": "disabled"],
            "output_config": ["effort": "low"],
        ]
        do {
            let response = try await client.streamMessage(body: body, apiKey: apiKey) { _ in }
            let answer = response.content
                .compactMap { $0.blockType == "text" ? $0["text"]?.stringValue : nil }
                .joined()
                .uppercased()
            return answer.contains("YES") || answer.contains("ДА")
        } catch {
            journal("ход", "фильтр обращения недоступен: \(error.localizedDescription)")
            return false
        }
    }
}
