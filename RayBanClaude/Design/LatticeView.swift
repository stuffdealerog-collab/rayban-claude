import SwiftUI

/// Состояние, которое показывает решётка.
enum LatticeMode: Equatable {
    case idle, listening, thinking, speaking
}

/// Солнцезащитная решётка фасада — главный образ приложения.
///
/// Ячейки со стрельчатым верхом, как в модернистских фасадах Ташкента. Свет проходит сквозь них
/// и показывает, что происходит: пока ассистент слушает, ячейки у центра разгораются от голоса;
/// пока думает, по решётке медленно идёт полоса света, как солнце по фасаду; пока говорит,
/// свет расходится от центра в такт речи. В покое решётка освещена с той стороны, где сейчас солнце.
struct LatticeView: View {
    var mode: LatticeMode
    var columns = 9
    var rows = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var previousMode: LatticeMode = .idle
    @State private var changedAt = Date.distantPast
    /// Меняется после окончания перехода, чтобы TimelineView остановился в покое.
    @State private var settleTick = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: mode == .idle && !isBlending)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let blend = min(1, max(0, timeline.date.timeIntervalSince(changedAt) / 0.45))
            let levels = Levels(
                input: Double(AudioLevels.shared.input),
                output: Double(AudioLevels.shared.output),
                systemVoice: AudioLevels.shared.systemVoiceActive
            )
            let sunAngle = Self.sunAngle(for: timeline.date)
            let current = mode
            let previous = previousMode
            let still = reduceMotion
            let dark = colorScheme == .dark

            Canvas { context, size in
                Self.draw(
                    in: &context, size: size, columns: columns, rows: rows,
                    intensity: { x, y, index in
                        let now = Self.intensity(current, x: x, y: y, index: index, time: time, levels: levels, sunAngle: sunAngle, still: still)
                        guard blend < 1 else { return now }
                        let before = Self.intensity(previous, x: x, y: y, index: index, time: time, levels: levels, sunAngle: sunAngle, still: still)
                        let eased = 1 - pow(1 - blend, 3)
                        return before + (now - before) * eased
                    },
                    dark: dark
                )
            }
        }
        .onChange(of: mode) { oldValue, _ in
            previousMode = oldValue
            changedAt = Date()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 550_000_000)
                settleTick += 1
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var isBlending: Bool {
        _ = settleTick
        return Date().timeIntervalSince(changedAt) < 0.5
    }

    private var accessibilityText: String {
        switch mode {
        case .idle: return "Ассистент ждёт"
        case .listening: return "Ассистент слушает"
        case .thinking: return "Ассистент думает"
        case .speaking: return "Ассистент говорит"
        }
    }

    fileprivate struct Levels: Sendable {
        let input: Double
        let output: Double
        let systemVoice: Bool
    }

    // MARK: - Свет

    /// Освещённость ячейки 0…1. x, y — положение от −1 до 1 относительно центра решётки.
    nonisolated private static func intensity(
        _ mode: LatticeMode, x: Double, y: Double, index: Int, time: Double,
        levels: Levels, sunAngle: Double, still: Bool
    ) -> Double {
        let radius = sqrt(x * x + y * y * 1.6)
        let grain = hash(index) // у каждой ячейки свой оттенок, как у стекла в старой раме
        switch mode {
        case .idle:
            // Солнце сбоку: освещена сторона, обращённая к нему.
            let along = (x * cos(sunAngle) + y * sin(sunAngle) + 1.4) / 2.8
            return 0.06 + 0.22 * smoothstep(0.35, 1.0, along) + 0.03 * grain

        case .listening:
            let voice = still ? 0.4 : levels.input
            let flicker = still ? 0 : 0.05 * sin(time * 9 + grain * 12)
            return 0.08 + (0.25 + voice * 1.1) * exp(-radius * 1.5) + flicker * voice + 0.03 * grain

        case .thinking:
            guard !still else { return 0.1 + 0.25 * exp(-radius * 1.2) }
            // Полоса света идёт по диагонали слева направо раз в 2,4 с.
            let u = (x * 0.8 + y * 0.6 + 1.4) / 2.8
            let band = (time / 2.4).truncatingRemainder(dividingBy: 1) * 1.6 - 0.3
            let distance = u - band
            return 0.07 + 0.55 * exp(-(distance * distance) / 0.012) + 0.03 * grain

        case .speaking:
            let level = levels.systemVoice ? 0.35 + 0.15 * sin(time * 7) : levels.output
            guard !still else { return 0.12 + (0.3 + level * 0.5) * exp(-radius) }
            let wave = 0.5 + 0.5 * sin(radius * 7 - time * 5.5)
            return 0.08 + (0.18 + level * 0.9) * wave * exp(-radius * 0.9) + 0.03 * grain
        }
    }

    /// Направление солнца по местному времени: утром свет слева, вечером справа, ночью снизу.
    nonisolated private static func sunAngle(for date: Date) -> Double {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hours = Double(components.hour ?? 12) + Double(components.minute ?? 0) / 60
        let dayProgress = min(1, max(0, (hours - 6) / 14)) // 6:00 → 0, 20:00 → 1
        return .pi + dayProgress * .pi + (hours < 6 || hours > 20 ? .pi / 2 : 0)
    }

    nonisolated private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    nonisolated private static func hash(_ index: Int) -> Double {
        var value = UInt64(truncatingIfNeeded: index &* 2_654_435_761)
        value ^= value >> 13
        value = value &* 0x5bd1e995
        value ^= value >> 15
        return Double(value % 1000) / 1000
    }

    // MARK: - Рисование

    nonisolated private static func draw(
        in context: inout GraphicsContext, size: CGSize, columns: Int, rows: Int,
        intensity: (Double, Double, Int) -> Double, dark: Bool
    ) {
        let gap: CGFloat = 6
        let cellWidth = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        guard cellWidth > 2, cellHeight > 2 else { return }

        let sun = Theme.sun
        let stone = Theme.stone

        for row in 0..<rows {
            for column in 0..<columns {
                let rect = CGRect(
                    x: CGFloat(column) * (cellWidth + gap),
                    y: CGFloat(row) * (cellHeight + gap),
                    width: cellWidth,
                    height: cellHeight
                )
                let x = columns > 1 ? Double(column) / Double(columns - 1) * 2 - 1 : 0
                let y = rows > 1 ? Double(row) / Double(rows - 1) * 2 - 1 : 0
                let light = min(1, max(0, intensity(x, y, row * columns + column)))
                let path = archPath(in: rect)

                // Камень вокруг проёма — тонкая линия; свет — заливка проёма.
                context.fill(path, with: .color(sun.opacity(light * (dark ? 0.95 : 0.85))))
                context.stroke(path, with: .color(stone.opacity(dark ? 0.14 : 0.12)), lineWidth: 1)
            }
        }
    }

    /// Проём со стрельчатой аркой сверху.
    nonisolated private static func archPath(in rect: CGRect) -> Path {
        var path = Path()
        let archHeight = min(rect.width * 0.75, rect.height * 0.45)
        let springY = rect.minY + archHeight
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: springY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY + archHeight * 0.25)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: springY),
            control: CGPoint(x: rect.maxX, y: rect.minY + archHeight * 0.25)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
