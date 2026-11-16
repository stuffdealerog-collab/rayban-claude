import Foundation
import Testing
@testable import AssistantCore

@Suite struct MemoryStoreTests {
    let store: MemoryStore

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        store = MemoryStore(root: root)
        try store.ensureExists()
    }

    @Test func createViewAndEdit() {
        let created = store.execute(.create(path: "/memories/Люди/Анна.md", text: "# Анна\nСестра.\nЛюбит кофе."))
        #expect(created == MemoryResult(text: "File created successfully at: /memories/Люди/Анна.md", isError: false))

        let view = store.execute(.view(path: "/memories/Люди/Анна.md", range: nil))
        #expect(!view.isError)
        #expect(view.text.hasPrefix("Here's the content of /memories/Люди/Анна.md with line numbers:"))
        #expect(view.text.contains("     2\tСестра."))

        let ranged = store.execute(.view(path: "/memories/Люди/Анна.md", range: [3, -1]))
        #expect(ranged.text.contains("     3\tЛюбит кофе."))
        #expect(!ranged.text.contains("Сестра"))

        let replaced = store.execute(.strReplace(path: "/memories/Люди/Анна.md", old: "кофе", new: "зелёный чай"))
        #expect(replaced.text == "The memory file has been edited.")
        let inserted = store.execute(.insert(path: "/memories/Люди/Анна.md", line: 1, text: "День рождения: 12 марта."))
        #expect(!inserted.isError)
        #expect((try? store.read("Люди/Анна.md")) == "# Анна\nДень рождения: 12 марта.\nСестра.\nЛюбит зелёный чай.")
    }

    @Test func strReplaceReportsMissingAndDuplicates() {
        _ = store.execute(.create(path: "/memories/a.md", text: "x\nx\ny"))
        let missing = store.execute(.strReplace(path: "/memories/a.md", old: "z", new: "q"))
        #expect(missing.isError)
        #expect(missing.text.contains("did not appear verbatim"))
        let duplicate = store.execute(.strReplace(path: "/memories/a.md", old: "x", new: "q"))
        #expect(duplicate.isError)
        #expect(duplicate.text.contains("lines: [1, 2]"))
        let noFile = store.execute(.strReplace(path: "/memories/nope.md", old: "x", new: "q"))
        #expect(noFile.text.contains("does not exist"))
    }

    @Test func insertValidatesLine() {
        _ = store.execute(.create(path: "/memories/a.md", text: "one"))
        let bad = store.execute(.insert(path: "/memories/a.md", line: 5, text: "x"))
        #expect(bad.isError)
        #expect(bad.text.contains("[0, 1]"))
    }

    @Test func deleteAndRename() {
        _ = store.execute(.create(path: "/memories/Дела/старое.md", text: "x"))
        let renamed = store.execute(.rename(from: "/memories/Дела/старое.md", to: "/memories/Архив/старое.md"))
        #expect(renamed.text == "Successfully renamed /memories/Дела/старое.md to /memories/Архив/старое.md")
        _ = store.execute(.create(path: "/memories/b.md", text: "y"))
        let clash = store.execute(.rename(from: "/memories/b.md", to: "/memories/Архив/старое.md"))
        #expect(clash.isError)
        #expect(store.execute(.delete(path: "/memories/Архив")).text == "Successfully deleted /memories/Архив")
        #expect(store.execute(.delete(path: "/memories")).isError)
        #expect(store.execute(.delete(path: "/memories/Архив")).isError)
    }

    @Test func rejectsEscapes() {
        for path in ["/memories/../secret.txt", "/memories/%2e%2e/secret", "/etc/passwd", "/memories/a\\..\\b",
                     "/memories/.hidden", "memories/a.md", "/memories/./a.md"] {
            let result = store.execute(.create(path: path, text: "x"))
            #expect(result.isError, "должен отклонить \(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: store.root.deletingLastPathComponent().appendingPathComponent("secret.txt").path))
    }

    @Test func directoryViewAndContext() {
        _ = store.execute(.create(path: "/memories/Обо мне.md", text: "Меня зовут Латиф. Живу в Ташкенте."))
        _ = store.execute(.create(path: "/memories/Люди/Анна.md", text: "Сестра"))
        let listing = store.execute(.view(path: "/memories", range: nil))
        #expect(listing.text.hasPrefix("Here're the files and directories up to 2 levels deep in /memories"))
        #expect(listing.text.contains("\t/memories/Люди/Анна.md"))
        #expect(listing.text.contains("\t/memories/Обо мне.md"))

        let context = store.conversationContext()
        #expect(context.contains("Меня зовут Латиф"))
        #expect(context.contains("- /memories/Люди/Анна.md"))
        #expect(store.notes().count == 2)
        #expect(store.note(titled: "анна")?.relativePath == "Люди/Анна.md")
        #expect(store.note(titled: "Люди/Анна")?.relativePath == "Люди/Анна.md")
        #expect(store.note(titled: "Места/Анна") == nil)
    }

    @Test func emptyContext() {
        #expect(store.conversationContext().contains("пока пуста"))
    }

    @Test func humanSizes() {
        #expect(MemoryStore.humanSize(512) == "512")
        #expect(MemoryStore.humanSize(1536) == "1.5K")
    }
}
