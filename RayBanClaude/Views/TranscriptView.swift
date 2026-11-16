import SwiftUI

/// Лента разговора в виде линии метро: реплика пользователя — станция, ответ — пересадка,
/// шаг ассистента — короткая остановка, а в конце — живая станция текущего момента.
struct TranscriptView: View {
    let entries: [TranscriptEntry]
    /// Что происходит прямо сейчас.
    let phase: AssistantController.Phase
    /// Промежуточный текст распознавания.
    let partial: String
    let assistantName: String
    /// Подпись живой станции, когда ассистент слушает без нажатия кнопки.
    var listeningCaption = "Слушаю"
    var emptyState: AnyView?

    private let tone = Theme.Tone.assistant

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty, phase == .idle, let emptyState {
                        emptyState
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(for: entry, index: index)
                                .transition(.opacity.combined(with: .offset(y: 10)))
                        }
                        liveRow
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.xl)
                .animation(Theme.ease(0.35), value: entries.count)
                .animation(Theme.ease(0.3), value: phase)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: entries.last?.text) { _, _ in scrollToBottom(proxy) }
            .onChange(of: entries.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: partial) { _, _ in scrollToBottom(proxy) }
            .onChange(of: phase) { _, _ in scrollToBottom(proxy) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.ease(0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    /// Последняя реплика ассистента, пока он её произносит, — живая станция.
    private func isSpeakingEntry(_ index: Int) -> Bool {
        phase == .speaking && index == entries.count - 1 && entries[index].role == .assistant
    }

    private var hasLiveRow: Bool {
        switch phase {
        case .listening, .thinking: return true
        case .speaking: return entries.last?.role != .assistant
        case .idle: return false
        }
    }

    @ViewBuilder
    private func row(for entry: TranscriptEntry, index: Int) -> some View {
        let isFirst = index == 0
        let isLast = index == entries.count - 1 && !hasLiveRow
        switch entry.role {
        case .user:
            LineRow(stop: .station, tone: tone, isFirst: isFirst, isLast: isLast) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Вы · \(Self.time(entry.date))").plateStyle()
                    Text(entry.text)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
        case .assistant:
            LineRow(stop: isSpeakingEntry(index) ? .live(.speaking) : .interchange, tone: tone, isFirst: isFirst, isLast: isLast) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(assistantName).plateStyle(tone.text)
                    Text(entry.text)
                        .font(.body)
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
        case .tool:
            LineRow(stop: .tick(running: entry.toolState == .running, failed: entry.toolState == .failed), tone: tone, isFirst: isFirst, isLast: isLast) {
                ToolStop(entry: entry)
            }
        case .info:
            LineRow(stop: .none, tone: tone, isFirst: isFirst, isLast: isLast) {
                Text(entry.text)
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            }
        case .error:
            LineRow(stop: .tick(running: false, failed: true), tone: tone, isFirst: isFirst, isLast: isLast) {
                ServiceNotice(text: entry.text)
            }
        }
    }

    @ViewBuilder
    private var liveRow: some View {
        let isFirst = entries.isEmpty
        switch phase {
        case .listening:
            LineRow(stop: .live(.listening), tone: tone, isFirst: isFirst, isLast: true) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(listeningCaption).plateStyle(tone.text)
                    Text(partial.isEmpty ? "Говорите" : partial)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(partial.isEmpty ? Theme.textMuted : Theme.textPrimary)
                        .contentTransition(.opacity)
                }
                .padding(.bottom, Theme.Space.m)
            }
        case .thinking:
            LineRow(stop: .live(.thinking), tone: tone, isFirst: isFirst, isLast: true) {
                Text("\(assistantName) думает")
                    .plateStyle(tone.text)
                    .padding(.bottom, Theme.Space.xl)
            }
        case .speaking where entries.last?.role != .assistant:
            LineRow(stop: .live(.speaking), tone: tone, isFirst: isFirst, isLast: true) {
                Text(assistantName)
                    .plateStyle(tone.text)
                    .padding(.bottom, Theme.Space.xl)
            }
        default:
            EmptyView()
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Шаг ассистента: значок в цвете своей линии и подпись. Снимок с очков — под ней.
private struct ToolStop: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: entry.symbol ?? "wrench.and.screwdriver")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(entry.toolState == .failed ? Theme.negative : ToolLine.tone(for: entry.toolName).text)
                    .frame(width: 18)
                Text(entry.text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if entry.toolState == .failed {
                    Text("сбой")
                        .font(.sign(.caption2, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.negative)
                }
            }
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 240, maxHeight: 170)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .accessibilityLabel("Снимок с камеры очков")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// К какой линии относится шаг: память — зелёная, календарь и таймеры — жёлтая,
/// всё из внешнего мира — синяя, камера очков — красная.
enum ToolLine {
    static func tone(for tool: String?) -> Theme.Tone {
        switch tool {
        case "notes": return .memory
        case "list_events", "create_event", "create_reminder", "set_timer": return .system
        case "take_photo": return .assistant
        default: return .translator
        }
    }
}

/// Сообщение о сбое: как объявление на линии — жёлтое, со значком.
struct ServiceNotice: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.negative)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .background(Theme.negative.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
