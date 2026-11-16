import SwiftUI

/// Фирменный приём приложения: разговор рисуется линией метро.
/// Реплика пользователя — станция, ответ ассистента — пересадка, шаг ассистента — короткая остановка,
/// а в конце линии — живая станция, которая дышит голосом.

/// Что стоит на линии в этой строке.
enum LineStop: Equatable {
    /// Станция: реплика пользователя.
    case station
    /// Пересадка: ответ ассистента.
    case interchange
    /// Короткая остановка: шаг ассистента (инструмент).
    case tick(running: Bool, failed: Bool)
    /// Живая станция: здесь разговор идёт прямо сейчас.
    case live(LivePhase)
    /// Строка без отметки: линия просто идёт мимо.
    case none
}

enum LivePhase: Equatable {
    case listening, thinking, speaking
}

enum LineMetrics {
    /// Ширина колонки с линией.
    static let rail: CGFloat = 30
    static let stroke: CGFloat = 6
    /// Центр отметки по вертикали от верха строки: на уровне подписи-таблички.
    static let nodeCenter: CGFloat = 10
    static let station: CGFloat = 20
    static let interchange: CGFloat = 24
}

/// Строка на линии: слева рельс с отметкой, справа содержимое.
struct LineRow<Content: View>: View {
    let stop: LineStop
    let tone: Theme.Tone
    var isFirst = false
    var isLast = false
    /// Участок линии ещё не построен (подсказки в пустом состоянии) — рисуется пунктиром.
    var planned = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, LineMetrics.rail + Theme.Space.m)
            .padding(.bottom, isLast ? Theme.Space.s : Theme.Space.l)
            .background(alignment: .topLeading) {
                LineRail(stop: stop, tone: tone, isFirst: isFirst, isLast: isLast, planned: planned)
            }
    }
}

/// Отрезок линии высотой в строку и отметка на нём.
struct LineRail: View {
    let stop: LineStop
    let tone: Theme.Tone
    let isFirst: Bool
    let isLast: Bool
    let planned: Bool

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { proxy in
                let top = isFirst ? LineMetrics.nodeCenter : 0
                let bottom = isLast ? LineMetrics.nodeCenter : proxy.size.height
                Path { path in
                    path.move(to: CGPoint(x: LineMetrics.rail / 2, y: top))
                    path.addLine(to: CGPoint(x: LineMetrics.rail / 2, y: max(top, bottom)))
                }
                .stroke(
                    tone.color.opacity(planned ? 0.45 : 1),
                    style: StrokeStyle(lineWidth: LineMetrics.stroke, lineCap: .round, dash: planned ? [2, 10] : [])
                )
            }
            node
        }
        .frame(width: LineMetrics.rail)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var node: some View {
        switch stop {
        case .station:
            Circle()
                .fill(Theme.background)
                .overlay(Circle().strokeBorder(Theme.textPrimary, lineWidth: 4.5))
                .frame(width: LineMetrics.station, height: LineMetrics.station)
                .offset(y: LineMetrics.nodeCenter - LineMetrics.station / 2)
        case .interchange:
            Circle()
                .fill(Theme.porcelain)
                .overlay(Circle().strokeBorder(tone.color, lineWidth: 5.5))
                .frame(width: LineMetrics.interchange, height: LineMetrics.interchange)
                .offset(y: LineMetrics.nodeCenter - LineMetrics.interchange / 2)
        case .tick(let running, let failed):
            TickMark(running: running, color: failed ? Theme.negative : Theme.textPrimary)
                .offset(x: 7, y: LineMetrics.nodeCenter - 2.5)
        case .live(let phase):
            LiveStation(phase: phase, tone: tone)
                .offset(y: LineMetrics.nodeCenter - LiveStation.box / 2)
        case .none:
            EmptyView()
        }
    }
}

/// Отметка остановки: короткая планка сбоку от линии. Пока шаг выполняется, она мерцает.
private struct TickMark: View {
    let running: Bool
    let color: Color
    @State private var dim = false

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: 14, height: 5)
            .opacity(running && dim ? 0.25 : 1)
            .onAppear { animate() }
            .onChange(of: running) { _, _ in animate() }
    }

    private func animate() {
        guard running else {
            dim = false
            return
        }
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// Живая станция в конце линии: дышит громкостью голоса, когда слушает или говорит,
/// и ведёт огонёк по кольцу, пока ассистент думает.
struct LiveStation: View {
    let phase: LivePhase
    let tone: Theme.Tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let box: CGFloat = 52
    private let core: CGFloat = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let level = CGFloat(reduceMotion ? 0.45 : currentLevel(time))
            ZStack {
                if phase != .thinking {
                    Circle()
                        .fill(tone.color.opacity(0.16))
                        .frame(width: core + 8 + 20 * level, height: core + 8 + 20 * level)
                    Circle()
                        .fill(tone.color.opacity(0.32))
                        .frame(width: core + 4 + 9 * level, height: core + 4 + 9 * level)
                }
                Circle()
                    .fill(phase == .speaking ? tone.color : Theme.porcelain)
                    .overlay(Circle().strokeBorder(phase == .speaking ? Theme.porcelain : tone.color, lineWidth: 5.5))
                    .frame(width: core, height: core)
                if phase == .thinking {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(tone.color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .frame(width: core + 14, height: core + 14)
                        .rotationEffect(.degrees(reduceMotion ? 0 : time.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360))
                }
            }
            .frame(width: Self.box, height: Self.box)
        }
        .frame(width: Self.box, height: Self.box)
    }

    private func currentLevel(_ time: TimeInterval) -> Float {
        switch phase {
        case .listening:
            // Даже в тишине станция чуть дышит: видно, что микрофон открыт.
            return max(AudioLevels.shared.input, Float(0.08 + 0.05 * sin(time * 2.4)))
        case .speaking:
            if AudioLevels.shared.systemVoiceActive { return Float(0.5 + 0.3 * sin(time * 7)) }
            return max(AudioLevels.shared.output, 0.1)
        case .thinking:
            return 0
        }
    }
}

/// Плашка линии: цветная капсула с подписью, как указатель пересадки.
struct LinePill: View {
    let text: String
    let tone: Theme.Tone
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.sign(.caption2, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.4)
        }
        .foregroundStyle(tone.onColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.color, in: Capsule())
    }
}

/// Полоска состояния под заголовком экрана: цвет линии и что на ней сейчас происходит.
struct LineStatus: View {
    let tone: Theme.Tone
    let text: String
    var detail: String?
    var active = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Capsule()
                .fill(tone.color)
                .frame(width: active ? 30 : 18, height: 6)
                .animation(Theme.ease(0.35), value: active)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.opacity)
            Spacer(minLength: Theme.Space.s)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .animation(Theme.ease(0.2), value: text)
        .accessibilityElement(children: .combine)
    }
}

/// Маленькая схема из четырёх линий, сходящихся на одной пересадке: всё, что умеет ассистент.
/// Линии идут только под 45° и 90°, как на настоящей схеме.
struct RouteMap: View {
    /// Имя ассистента — название центральной пересадки.
    let hub: String

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let unit = min(size.width / 10, size.height / 8)
            let center = CGPoint(x: size.width / 2, y: size.height * 0.52)
            let at: (CGFloat, CGFloat) -> CGPoint = { x, y in CGPoint(x: center.x + x * unit, y: center.y + y * unit) }

            ZStack {
                // Красная: разговор — сверху слева вниз направо через центр.
                line([at(-4.4, -3.2), at(-2.2, -3.2), at(0, -1), at(0, 0), at(2.2, 2.2), at(4.4, 2.2)], .assistant)
                // Синяя: перевод — горизонталь с изломом.
                line([at(-4.6, 0.9), at(-0.9, 0.9), at(0, 0), at(1.2, -1.2), at(4.6, -1.2)], .translator)
                // Зелёная: память — снизу вверх.
                line([at(-2.6, 3.4), at(-2.6, 2.6), at(0, 0), at(0, -1), at(2.4, -3.4), at(4.2, -3.4)], .memory)
                // Жёлтая: почта и календарь.
                line([at(-4.4, 2.4), at(-3.4, 2.4), at(-1, 0), at(0, 0), at(3.4, 0), at(4.6, 1.2)], .system)

                station(at(-2.2, -3.2), "Вопрос", .bottom)
                station(at(3.3, 2.2), "Камера", .top)
                station(at(-3, 0.9), "Перевод", .top)
                station(at(3, -1.2), "Субтитры", .bottom)
                station(at(-2.6, 2.6), "Заметки", .trailing)
                station(at(2.4, -3.4), "Люди", .bottom)
                station(at(2.2, 0), "Календарь", .top)
                station(at(-3.4, 2.4), "Почта", .top)

                Circle()
                    .fill(Theme.porcelain)
                    .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 4))
                    .frame(width: unit * 1.05, height: unit * 1.05)
                    .position(center)
                Text(hub)
                    .font(.sign(.headline))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.background, in: Capsule())
                    .position(x: center.x + unit * 1.9, y: center.y + unit * 0.95)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Схема: разговор, перевод, память, почта и календарь сходятся на станции \(hub)")
    }

    private func line(_ points: [CGPoint], _ tone: Theme.Tone) -> some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(tone.color, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
    }

    private func station(_ point: CGPoint, _ name: String, _ side: Edge) -> some View {
        let offset: CGSize
        switch side {
        case .top: offset = CGSize(width: 0, height: -17)
        case .bottom: offset = CGSize(width: 0, height: 17)
        case .leading: offset = CGSize(width: -34, height: 0)
        case .trailing: offset = CGSize(width: 38, height: 0)
        }
        return ZStack {
            Circle()
                .fill(Theme.background)
                .overlay(Circle().strokeBorder(Theme.textPrimary, lineWidth: 3))
                .frame(width: 13, height: 13)
                .position(point)
            Text(name)
                .font(.sign(.caption2, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
                .position(x: point.x + offset.width, y: point.y + offset.height)
        }
    }
}
