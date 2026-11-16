import SwiftUI

/// Журнал событий: что происходило с микрофоном, распознаванием, голосом, звонком и очками.
/// Нужен, чтобы разобраться, что случилось на телефоне, когда приложение было в фоне.
struct JournalView: View {
    @State private var lines: [String] = []
    @State private var confirmClear = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    JournalLine(text: line)
                        .id(index)
                        .listRowBackground(Theme.surface)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .overlay {
                if lines.isEmpty {
                    ContentUnavailableView("Журнал пуст", systemImage: "list.bullet.rectangle", description: Text("События появятся, как только вы начнёте разговор."))
                }
            }
            .onAppear {
                reload()
                if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .navigationTitle("Журнал")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: DiagnosticLog.shared.text) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Поделиться журналом")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Обновить", systemImage: "arrow.clockwise") { reload() }
                    Button("Очистить", systemImage: "trash", role: .destructive) { confirmClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Действия с журналом")
            }
        }
        .confirmationDialog("Очистить журнал?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) {
                DiagnosticLog.shared.clear()
                reload()
            }
        }
    }

    private func reload() {
        lines = DiagnosticLog.shared.entries
    }
}

/// Строка журнала: время и раздел приглушены, сообщение — основным цветом.
private struct JournalLine: View {
    let text: String

    var body: some View {
        if let close = text.firstIndex(of: "]"), text.contains("[") {
            let meta = String(text[...close])
            let message = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 1)
        } else {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
