import SwiftUI

/// Лента диалога: реплики пользователя справа, ответы ассистента — обычным текстом, действия — тихими строками.
struct TranscriptView: View {
    let entries: [TranscriptEntry]
    let partial: String
    var emptyState: AnyView? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    if entries.isEmpty, partial.isEmpty, let emptyState {
                        emptyState
                    }
                    ForEach(entries) { entry in
                        TranscriptRow(entry: entry)
                            .id(entry.id)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    if !partial.isEmpty {
                        UserBubble(text: partial, isPartial: true)
                            .id("partial")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
                .animation(Theme.ease(0.35), value: entries.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: entries.last?.text) { _, _ in scrollToBottom(proxy) }
            .onChange(of: entries.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: partial) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.ease(0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

private struct TranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.role {
        case .user:
            UserBubble(text: entry.text, isPartial: false)
        case .assistant:
            Text(entry.text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolRow(entry: entry)
        case .info:
            Text(entry.text)
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Theme.negative)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct UserBubble: View {
    let text: String
    let isPartial: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.body)
                .foregroundStyle(isPartial ? Theme.textSecondary : Theme.textPrimary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s + 2)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay {
                    if isPartial {
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
        }
    }
}

/// Действие ассистента: значок, подпись, состояние. Пока выполняется — пунктир, готово — сплошная линия.
private struct ToolRow: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s + 2) {
                Image(systemName: entry.symbol ?? "wrench.and.screwdriver")
                    .font(.footnote)
                    .frame(width: 18)
                    .foregroundStyle(entry.toolState == .failed ? Theme.negative : Theme.textMuted)
                    .symbolEffect(.pulse, options: .repeating, isActive: entry.toolState == .running)
                Text(entry.text)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Rectangle()
                    .fill(.clear)
                    .frame(height: 1)
                    .overlay(
                        Line()
                            .stroke(Theme.textMuted.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: entry.toolState == .running ? [3, 3] : []))
                    )
                if entry.toolState == .failed {
                    Text("не вышло")
                        .font(.caption)
                        .foregroundStyle(Theme.negative)
                }
            }
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 220, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous)
                            .strokeBorder(Theme.hairline)
                    )
                    .accessibilityLabel("Снимок с камеры очков")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
