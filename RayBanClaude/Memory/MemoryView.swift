import AssistantCore
import SwiftUI
import UIKit

/// Память ассистента — заметки Markdown, как в Obsidian: читать, править, переходить по [[ссылкам]], выгружать.
struct MemoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AssistantController.self) private var assistant

    @State private var notes: [MemoryNote] = []
    @State private var query = ""
    @State private var path: [MemoryNote] = []
    @State private var showNewNote = false
    @State private var export: ExportTarget?

    private var memory: MemoryStore { assistant.memory }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if notes.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Theme.background)
            .navigationTitle("Память")
            .navigationDestination(for: MemoryNote.self) { note in
                NoteDetailView(note: note, memory: memory) { linked in
                    if let target = memory.note(titled: linked) { path.append(target) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showNewNote = true
                        } label: {
                            Label("Новая заметка", systemImage: "square.and.pencil")
                        }
                        Button {
                            export = ExportTarget(url: memory.root)
                        } label: {
                            Label("Сохранить копию в Файлы", systemImage: "folder")
                        }
                        .disabled(notes.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Действия с памятью")
                }
            }
            .searchable(text: $query, prompt: "Поиск")
            .sheet(isPresented: $showNewNote) {
                NoteEditorView(title: "", text: "", memory: memory, isNew: true) { reload() }
            }
            .sheet(item: $export) { target in
                FolderExporter(url: target.url)
            }
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in reload() }
        }
    }

    private var filtered: [MemoryNote] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return notes }
        return notes.filter { note in
            note.title.lowercased().contains(trimmed)
                || ((try? memory.read(note.relativePath))?.lowercased().contains(trimmed) ?? false)
        }
    }

    private var grouped: [(folder: String, notes: [MemoryNote])] {
        let groups = Dictionary(grouping: filtered, by: \.folder)
        return groups.keys
            .sorted { lhs, rhs in lhs.isEmpty ? true : (rhs.isEmpty ? false : lhs < rhs) }
            .map { ($0, groups[$0] ?? []) }
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.folder) { group in
                Section(group.folder.isEmpty ? "Главное" : group.folder) {
                    ForEach(group.notes) { note in
                        NavigationLink(value: note) {
                            NoteRow(note: note, preview: preview(of: note))
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { try? memory.remove(group.notes[index].relativePath) }
                        reload()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Text("Здесь \(settings.persona.displayName) хранит то, что узнаёт о вас")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Скажите, например: «Запомни, что я не ем острое» или «Мою сестру зовут Анна». Заметки — обычные файлы Markdown: их можно читать, править и перенести в Obsidian.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Написать о себе") { showNewNote = true }
                .buttonStyle(.bordered)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func preview(of note: MemoryNote) -> String {
        guard let text = try? memory.read(note.relativePath) else { return "" }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-* \t")) }
            .first { !$0.isEmpty && $0.lowercased() != note.title.lowercased() } ?? ""
    }

    private func reload() {
        notes = memory.notes()
    }
}

private struct NoteRow: View {
    let note: MemoryNote
    let preview: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(note.modified, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            if !preview.isEmpty {
                Text(preview)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Заметка: Markdown с переходами по [[ссылкам]].
private struct NoteDetailView: View {
    let note: MemoryNote
    let memory: MemoryStore
    let openLink: (String) -> Void

    @State private var text = ""
    @State private var editing = false

    var body: some View {
        ScrollView {
            MarkdownBlocks(text: text)
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Править") { editing = true }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "note" else { return .systemAction }
            openLink(url.host(percentEncoded: false) ?? url.path)
            return .handled
        })
        .sheet(isPresented: $editing) {
            NoteEditorView(title: note.title, text: text, memory: memory, isNew: false, relativePath: note.relativePath) {
                load()
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        text = (try? memory.read(note.relativePath)) ?? ""
    }
}

/// Редактор заметки.
private struct NoteEditorView: View {
    @State var title: String
    @State var text: String
    let memory: MemoryStore
    let isNew: Bool
    var relativePath: String? = nil
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if isNew {
                    Section("Название") {
                        TextField("Например, Обо мне", text: $title)
                    }
                }
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 280)
                        .font(.body)
                } footer: {
                    Text("Markdown: # заголовок, - список, [[Другая заметка]] — ссылка.")
                }
                if let error {
                    Text(error).foregroundStyle(Theme.negative)
                }
            }
            .navigationTitle(isNew ? "Новая заметка" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить", action: save)
                        .disabled(isNew && title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        let path = relativePath ?? (name.hasSuffix(".md") ? name : name + ".md")
        if isNew, (try? memory.read(path)) != nil {
            error = "Заметка «\(name)» уже есть — откройте её и допишите."
            return
        }
        do {
            try memory.write(path, text: text)
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
            onSave()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Небольшой рендер Markdown: заголовки, списки, абзацы; [[ссылки]] открывают другие заметки.
private struct MarkdownBlocks: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    Text(inline(content))
                        .font(level == 1 ? .title2 : (level == 2 ? .title3 : .headline))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, level == 1 ? 0 : Theme.Space.s)
                case .bullet(let content):
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Circle().fill(Theme.textMuted).frame(width: 5, height: 5).offset(y: -3)
                        Text(inline(content)).foregroundStyle(Theme.textPrimary)
                    }
                case .paragraph(let content):
                    Text(inline(content)).foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .font(.body)
        .tint(Theme.accent)
        .textSelection(.enabled)
    }

    private enum Block {
        case heading(Int, String)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                return .heading(min(level, 3), line.dropFirst(level).trimmingCharacters(in: .whitespaces))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                return .bullet(String(line.dropFirst(2)))
            }
            return .paragraph(line)
        }
    }

    /// [[Ссылка]] → markdown-ссылка note://; остальное — встроенный Markdown (жирный, курсив, ссылки).
    private func inline(_ content: String) -> AttributedString {
        var converted = content
        while let open = converted.range(of: "[["), let close = converted.range(of: "]]", range: open.upperBound..<converted.endIndex) {
            let inner = String(converted[open.upperBound..<close.lowerBound])
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first ?? inner
            let label = parts.count > 1 ? parts[1] : target
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? target
            converted.replaceSubrange(open.lowerBound..<close.upperBound, with: "[\(label)](note://\(encoded))")
        }
        return (try? AttributedString(markdown: converted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(content)
    }
}

/// Сохранение копии папки памяти в «Файлы» (например, в хранилище Obsidian).
private struct FolderExporter: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

private struct ExportTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
