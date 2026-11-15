import SwiftUI
import UIKit

/// Цвета, отступы и движение приложения.
///
/// Мир — ташкентский модернизм: светлый камень фасадов, кобальт мозаик и тёплый свет,
/// проходящий сквозь солнцезащитную решётку. Поверхности остаются нейтральными (чуть тёплыми),
/// цвет живёт в одном акценте и в решётке на экране ассистента.
enum Theme {
    // MARK: Цвета

    /// Единственный акцент интерфейса: основное действие, выбор, ссылки.
    static let accent = Color(light: 0x2A4FBF, dark: 0x7D9BF2)
    /// Свет в решётке — только для неё.
    static let sun = Color(light: 0xC9741F, dark: 0xF2B45A)
    /// «Камень»: рамка ячеек решётки и линии.
    static let stone = Color(light: 0x1F1B16, dark: 0xEFE9DE)

    static let background = Color(light: 0xF7F4EE, dark: 0x12110F)
    static let surface = Color(light: 0xFDFBF7, dark: 0x1C1A18)
    static let raised = Color(light: 0xEFE9DF, dark: 0x262421)

    static let textPrimary = Color(light: 0x1F1B16, dark: 0xEFE9DE)
    static let textSecondary = Color(light: 0x5E554A, dark: 0xAAA398)
    static let textMuted = Color(light: 0x7B7266, dark: 0x8A847A)
    static let hairline = Color(light: 0x1F1B16, dark: 0xEFE9DE).opacity(0.08)

    static let positive = Color(light: 0x16A34A, dark: 0x4CC38A)
    static let negative = Color(light: 0xDC2626, dark: 0xE5484D)

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
        static let control: CGFloat = 10
        static let card: CGFloat = 16
        static let panel: CGFloat = 20
    }

    // MARK: Движение — одна кривая на всё приложение

    static func ease(_ duration: Double = 0.3) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
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
