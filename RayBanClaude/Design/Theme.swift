import SwiftUI
import UIKit

/// Цвета, шрифты, отступы и движение приложения.
///
/// Мир — схема ташкентского метро. Ночью — тёмно-синяя эмаль, днём — белая бумага схемы.
/// Четыре цвета линий, у каждого своя работа: красная — ассистент, синяя — переводчик,
/// зелёная — память, жёлтая — настройки и служебные сообщения. Разговор рисуется линией
/// со станциями (см. `LineKit.swift`).
enum Theme {
    // MARK: Поверхности

    /// Фон экранов: эмаль ночью, бумага схемы днём.
    static let background = Color(light: 0xF7F6F2, dark: 0x0B1230)
    /// Карточки, поля ввода, строки списков.
    static let surface = Color(light: 0xFFFFFF, dark: 0x131C47)
    /// Реплики пользователя, второстепенные кнопки.
    static let raised = Color(light: 0xE9E7E0, dark: 0x1C2759)
    /// Белый фарфор станций и главной кнопки — одинаковый в обеих темах.
    static let porcelain = Color(light: 0xFFFFFF, dark: 0xF7F6F2)
    /// Тёмно-синяя эмаль: текст на фарфоре.
    static let ink = Color(light: 0x0B1230, dark: 0x0B1230)

    // MARK: Текст

    static let textPrimary = Color(light: 0x0B1230, dark: 0xF7F6F2)
    static let textSecondary = Color(light: 0x434D72, dark: 0xB7C0E0)
    static let textMuted = Color(light: 0x68718F, dark: 0x8B96C2)
    static let hairline = Color(light: 0x0B1230, dark: 0xF7F6F2).opacity(0.12)

    // MARK: Линии

    /// Цвет линии: у каждой вкладки и каждого рода действий свой.
    enum Tone: Sendable, CaseIterable {
        /// Красная линия — разговор с ассистентом.
        case assistant
        /// Синяя — переводчик и всё, что идёт из сети.
        case translator
        /// Зелёная — память.
        case memory
        /// Жёлтая — настройки, календарь и служебные сообщения.
        case system

        /// Краска линии: заливки, кольца станций, плашки.
        var color: Color {
            switch self {
            case .assistant: return Color(light: 0xDC1F2E, dark: 0xE02A38)
            case .translator: return Color(light: 0x1E5BFF, dark: 0x2A63FF)
            case .memory: return Color(light: 0x16994A, dark: 0x2CC561)
            case .system: return Color(light: 0xF2B200, dark: 0xFFC20E)
            }
        }

        /// Тот же цвет для текста и значков на фоне: достаточно контрастный в обеих темах.
        var text: Color {
            switch self {
            case .assistant: return Color(light: 0xC0161F, dark: 0xFF7178)
            case .translator: return Color(light: 0x1848D8, dark: 0x8FB0FF)
            case .memory: return Color(light: 0x0F7A39, dark: 0x5BDD88)
            case .system: return Color(light: 0x8A5A00, dark: 0xFFD257)
            }
        }

        /// Цвет значка или текста поверх заливки этой линии: контраст не ниже 4,5:1 в обеих темах.
        /// На красной и синей — белый, на зелёной и жёлтой — тёмная эмаль.
        var onColor: Color {
            switch self {
            case .assistant, .translator: return .white
            case .memory, .system: return Theme.ink
            }
        }
    }

    /// Главное действие приложения — красная линия.
    static let accent = Tone.assistant.color
    /// Значок на цветной плашке (для жёлтой — см. `Tone.onColor`).
    static let onTone = Color.white

    /// Готово, включено.
    static let positive = Tone.memory.text
    /// Сбой: как на схеме, сбои помечают жёлтым, а не красным — красный здесь цвет линии.
    static let negative = Color(light: 0xA85400, dark: 0xFFB13D)

    // MARK: Отступы (сетка 4 pt)

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 12
        static let card: CGFloat = 16
        static let panel: CGFloat = 22
    }

    // MARK: Движение — одна кривая на всё приложение

    static func ease(_ duration: Double = 0.3) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    // MARK: Шрифты

    /// Системная панель навигации: заголовки — узким жирным начертанием, как названия станций.
    @MainActor
    static func applyNavigationAppearance() {
        let large = UIFont.systemFont(ofSize: 36, weight: .bold, width: .condensed)
        let inline = UIFont.systemFont(ofSize: 18, weight: .semibold, width: .condensed)
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        let color = UIColor(Theme.textPrimary)
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: metrics.scaledFont(for: large), .foregroundColor: color]
        UINavigationBar.appearance().titleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline), .foregroundColor: color,
        ]
    }
}

extension Font {
    /// Узкое жирное начертание SF — голос вывесок и названий станций.
    static func sign(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style).weight(weight).width(.condensed)
    }
}

extension View {
    /// Подпись-табличка: «ВЫ · 18:42», «ДЖАРВИС». Короткие узкие прописные, как на схеме.
    func plateStyle(_ color: Color = Theme.textMuted) -> some View {
        font(.sign(.caption, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

extension Color {
    /// Цвет, который сам меняется в тёмной теме.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Уровни звука для решётки: микрофон (пишется из аудиопотока) и голос ассистента.
/// Читается при отрисовке каждого кадра, поэтому без привязки к MainActor — под замком.
final class AudioLevels: @unchecked Sendable {
    static let shared = AudioLevels()

    private let lock = NSLock()
    private var _input: Float = 0
    private var _output: Float = 0
    private var _systemVoiceActive = false

    /// 0…1, громкость речи в микрофоне.
    var input: Float {
        get { lock.withLock { _input } }
        set { lock.withLock { _input = newValue } }
    }

    /// 0…1, громкость голоса ассистента (ElevenLabs).
    var output: Float {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }

    /// Говорит голос iOS: его громкость недоступна, решётка рисует ровную волну.
    var systemVoiceActive: Bool {
        get { lock.withLock { _systemVoiceActive } }
        set { lock.withLock { _systemVoiceActive = newValue } }
    }

    /// dBFS → 0…1: −55 дБ и тише — ноль, −10 дБ и громче — единица.
    static func normalize(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 55) / 45))
    }
}
