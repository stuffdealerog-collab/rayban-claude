import SwiftUI

/// Лента диалога: реплики, вызовы инструментов, снимки с камеры.
struct TranscriptView: View {
    let entries: [TranscriptEntry]
    let partial: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty && partial.isEmpty {
                        EmptyStateView()
                    }
                    ForEach(entries) { entry in
                        EntryRow(entry: entry).id(entry.id)
                    }
                    if !partial.isEmpty {
                        Text(partial)
                            .italic()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .id("partial")
                    }
                }
                .padding()
            }
            .onChange(of: entries.last?.text) { _, _ in scrollToBottom(proxy) }
            .onChange(of: entries.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: partial) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if !partial.isEmpty {
                proxy.scrollTo("partial", anchor: .bottom)
            } else if let last = entries.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct EntryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.role {
        case .user:
            bubble(entry.text, color: .accentColor.opacity(0.18))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            bubble(entry.text, color: Color(.secondarySystemBackground))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text).font(.caption).foregroundStyle(.secondary)
                if let image = entry.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        case .info:
            Text(entry.text).font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func bubble(_ text: String, color: Color) -> some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Что можно спросить").font(.headline)
            ForEach([
                "«Что передо мной?»",
                "«Прочитай, что написано на вывеске»",
                "«Переведи меню на русский»",
                "«Где я сейчас?»",
                "«Напомни через час позвонить маме»",
                "«Какая завтра погода?»",
            ], id: \.self) { example in
                Text(example).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
