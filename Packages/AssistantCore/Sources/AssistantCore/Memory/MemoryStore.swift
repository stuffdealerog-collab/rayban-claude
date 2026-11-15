import Foundation

/// Команда инструмента заметок. Формат повторяет memory tool Claude (`/memories/...`),
/// поэтому модель пользуется им без отдельного обучения.
public enum MemoryCommand: Sendable, Equatable {
    case view(path: String, range: [Int]?)
    case create(path: String, text: String)
    case strReplace(path: String, old: String, new: String)
    case insert(path: String, line: Int, text: String)
    case delete(path: String)
    case rename(from: String, to: String)
}

/// Результат команды: текст для `tool_result` и признак ошибки.
public struct MemoryResult: Sendable, Equatable {
    public let text: String
    public let isError: Bool

    static func ok(_ text: String) -> MemoryResult { MemoryResult(text: text, isError: false) }
    static func error(_ text: String) -> MemoryResult { MemoryResult(text: text, isError: true) }
}

/// Заметка для экрана «Память».
public struct MemoryNote: Sendable, Identifiable, Hashable {
    /// Путь относительно корня памяти, например `Люди/Анна.md`.
    public let relativePath: String
    public let modified: Date
    public let size: Int

    public var id: String { relativePath }
    /// Имя файла без расширения — так на заметку ссылаются `[[Анна]]`, как в Obsidian.
    public var title: String { (relativePath as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "") }
    /// Папка заметки (пусто — корень).
    public var folder: String { (relativePath as NSString).deletingLastPathComponent }
}

/// Память ассистента — папка обычных Markdown-файлов (как хранилище Obsidian).
///
/// Claude видит её как `/memories`. Все пути проверяются: выйти за пределы папки нельзя
/// ни через `..`, ни через закодированные символы или ссылки.
public final class MemoryStore: @unchecked Sendable {
    public static let virtualRoot = "/memories"
    /// Главная заметка о пользователе: её содержимое подставляется в начало каждого диалога.
    public static let profileName = "Обо мне.md"

    public let root: URL
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let maxFileSize = 100_000
    private let maxViewCharacters = 16_000

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func ensureExists() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Команды Claude

    public func execute(_ command: MemoryCommand) -> MemoryResult {
        lock.lock()
        defer { lock.unlock() }
        do {
            try ensureExists()
            switch command {
            case .view(let path, let range): return try view(path, range: range)
            case .create(let path, let text): return try create(path, text: text)
            case .strReplace(let path, let old, let new): return try strReplace(path, old: old, new: new)
            case .insert(let path, let line, let text): return try insert(path, line: line, text: text)
            case .delete(let path): return try delete(path)
            case .rename(let from, let to): return try rename(from, to: to)
            }
        } catch let error as MemoryPathError {
            return .error(error.message)
        } catch {
            return .error("Error: \(error.localizedDescription)")
        }
    }

    private func view(_ path: String, range: [Int]?) throws -> MemoryResult {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .error("The path \(path) does not exist. Please provide a valid path.")
        }
        if isDirectory.boolValue {
            var lines = ["Here're the files and directories up to 2 levels deep in \(path), excluding hidden items and node_modules:"]
            lines.append("\(Self.humanSize(directorySize(url)))\t\(virtualPath(of: url))")
            for entry in entries(in: url, depth: 2) {
                lines.append("\(Self.humanSize(entry.size))\t\(virtualPath(of: entry.url))")
            }
            return .ok(lines.joined(separator: "\n"))
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        var fileLines = text.components(separatedBy: "\n")
        var firstNumber = 1
        if let range, range.count == 2 {
            let start = max(1, range[0])
            let end = range[1] == -1 ? fileLines.count : min(range[1], fileLines.count)
            guard start <= end else {
                return .error("Error: Invalid `view_range` parameter: \(range). Lines are [1, \(fileLines.count)].")
            }
            fileLines = Array(fileLines[(start - 1)..<end])
            firstNumber = start
        }
        var body = fileLines.enumerated()
            .map { String(format: "%6d", $0.offset + firstNumber) + "\t" + $0.element }
            .joined(separator: "\n")
        if body.count > maxViewCharacters {
            body = String(body.prefix(maxViewCharacters)) + "\n… (обрезано)"
        }
        return .ok("Here's the content of \(path) with line numbers:\n" + body)
    }

    private func create(_ path: String, text: String) throws -> MemoryResult {
        let url = try resolve(path)
        guard url != root else { return .error("Error: \(path) is a directory") }
        guard text.utf8.count <= maxFileSize else {
            return .error("Error: File is too large (limit \(maxFileSize / 1000) KB). Split it into several notes.")
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .error("Error: \(path) is a directory")
        }
        // Перезапись существующей заметки разрешена: так Claude обновляет её целиком.
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return .ok("File created successfully at: \(path)")
    }

    private func strReplace(_ path: String, old: String, new: String) throws -> MemoryResult {
        guard let url = try existingFile(path) else {
            return .error("Error: The path \(path) does not exist. Please provide a valid path.")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let occurrences = text.ranges(of: old)
        guard !old.isEmpty, !occurrences.isEmpty else {
            return .error("No replacement was performed, old_str `\(old)` did not appear verbatim in \(path).")
        }
        guard occurrences.count == 1, let range = occurrences.first else {
            let lines = occurrences.map { text[..<$0.lowerBound].components(separatedBy: "\n").count }
            return .error("No replacement was performed. Multiple occurrences of old_str `\(old)` in lines: \(lines). Please ensure it is unique")
        }
        let updated = text.replacingCharacters(in: range, with: new)
        guard updated.utf8.count <= maxFileSize else { return .error("Error: File would exceed the size limit.") }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return .ok("The memory file has been edited.")
    }

    private func insert(_ path: String, line: Int, text: String) throws -> MemoryResult {
        guard let url = try existingFile(path) else {
            return .error("Error: The path \(path) does not exist")
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        guard line >= 0, line <= lines.count else {
            return .error("Error: Invalid `insert_line` parameter: \(line). It should be within the range of lines of the file: [0, \(lines.count)]")
        }
        lines.insert(contentsOf: text.components(separatedBy: "\n"), at: line)
        let updated = lines.joined(separator: "\n")
        guard updated.utf8.count <= maxFileSize else { return .error("Error: File would exceed the size limit.") }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return .ok("The file \(path) has been edited.")
    }

    private func delete(_ path: String) throws -> MemoryResult {
        let url = try resolve(path)
        guard url != root else { return .error("Error: Cannot delete \(Self.virtualRoot)") }
        guard fileManager.fileExists(atPath: url.path) else {
            return .error("Error: The path \(path) does not exist")
        }
        try fileManager.removeItem(at: url)
        return .ok("Successfully deleted \(path)")
    }

    private func rename(_ from: String, to: String) throws -> MemoryResult {
        let source = try resolve(from)
        let destination = try resolve(to)
        guard source != root, destination != root else { return .error("Error: Cannot rename \(Self.virtualRoot)") }
        guard fileManager.fileExists(atPath: source.path) else {
            return .error("Error: The path \(from) does not exist")
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            return .error("Error: The destination \(to) already exists")
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
        return .ok("Successfully renamed \(from) to \(to)")
    }

    // MARK: - Для экрана «Память» и начала диалога

    /// Все заметки (.md и .txt), новые сверху.
    public func notes() -> [MemoryNote] {
        lock.lock()
        defer { lock.unlock() }
        return entries(in: root, depth: 8)
            .filter { !$0.isDirectory && ["md", "txt"].contains($0.url.pathExtension.lowercased()) }
            .map { MemoryNote(relativePath: relativePath(of: $0.url), modified: $0.modified, size: $0.size) }
            .sorted { $0.modified > $1.modified }
    }

    public func read(_ relativePath: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let url = try resolve(Self.virtualRoot + "/" + relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ relativePath: String, text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureExists()
        let url = try resolve(Self.virtualRoot + "/" + relativePath)
        guard url != root else { throw MemoryPathError(message: "Нельзя записать в корень памяти.") }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func remove(_ relativePath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = try resolve(Self.virtualRoot + "/" + relativePath)
        guard url != root else { return }
        try fileManager.removeItem(at: url)
    }

    /// Заметка по имени `[[ссылки]]` (без учёта регистра).
    public func note(titled title: String) -> MemoryNote? {
        let wanted = title.trimmingCharacters(in: .whitespaces).lowercased()
        return notes().first { $0.title.lowercased() == wanted }
    }

    /// Блок памяти для первого сообщения диалога: список заметок и главная заметка о пользователе.
    /// Так Claude не тратит отдельный запрос на просмотр папки перед ответом.
    public func conversationContext(maxNotes: Int = 60, maxProfileCharacters: Int = 3_000) -> String {
        let all = notes()
        var parts: [String] = []
        if let profile = try? read(Self.profileName), !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Содержимое \(Self.virtualRoot)/\(Self.profileName):\n" + String(profile.prefix(maxProfileCharacters)))
        }
        if all.isEmpty {
            parts.append("Папка \(Self.virtualRoot) пока пуста.")
        } else {
            let listed = all.prefix(maxNotes).map { "- \(Self.virtualRoot)/\($0.relativePath)" }
            var listing = "Заметки в \(Self.virtualRoot) (новые сверху):\n" + listed.joined(separator: "\n")
            if all.count > maxNotes { listing += "\n- … ещё \(all.count - maxNotes)" }
            parts.append(listing)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Пути

    /// Переводит путь Claude (`/memories/...`) в файл внутри корня. Бросает при любой попытке выйти наружу.
    func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == Self.virtualRoot || trimmed.hasPrefix(Self.virtualRoot + "/") else {
            throw MemoryPathError(message: "Error: Path must start with \(Self.virtualRoot)")
        }
        let relative = String(trimmed.dropFirst(Self.virtualRoot.count))
        let lowered = relative.lowercased()
        guard !relative.contains("\\"), !relative.contains("\0"), !lowered.contains("%2e"), !lowered.contains("%2f"),
              !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
        else {
            throw MemoryPathError(message: "Error: Invalid path \(path)")
        }
        let components = relative.split(separator: "/").map(String.init)
        if components.contains(where: { $0.hasPrefix(".") }) {
            throw MemoryPathError(message: "Error: Hidden files are not allowed: \(path)")
        }
        var url = root
        for component in components { url.appendPathComponent(component) }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootResolved = root.resolvingSymlinksInPath()
        guard resolved.path == rootResolved.path || resolved.path.hasPrefix(rootResolved.path + "/") else {
            throw MemoryPathError(message: "Error: Path escapes \(Self.virtualRoot): \(path)")
        }
        return url.standardizedFileURL
    }

    private func existingFile(_ path: String) throws -> URL? {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url
    }

    private func relativePath(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func virtualPath(of url: URL) -> String {
        let relative = relativePath(of: url)
        return relative.isEmpty ? Self.virtualRoot : Self.virtualRoot + "/" + relative
    }

    private struct Entry {
        let url: URL
        let isDirectory: Bool
        let size: Int
        let modified: Date
    }

    private func entries(in directory: URL, depth: Int) -> [Entry] {
        guard depth > 0,
              let items = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }
        var result: [Entry] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where item.lastPathComponent != "node_modules" {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = values?.isDirectory ?? false
            let size = isDirectory ? directorySize(item) : (values?.fileSize ?? 0)
            result.append(Entry(url: item, isDirectory: isDirectory, size: size, modified: values?.contentModificationDate ?? .distantPast))
            if isDirectory {
                result += entries(in: item, depth: depth - 1)
            }
        }
        return result
    }

    private func directorySize(_ url: URL) -> Int {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total = 0
        for case let file as URL in enumerator {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    static func humanSize(_ bytes: Int) -> String {
        let units = ["B", "K", "M", "G"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes)" : String(format: "%.1f%@", value, units[unit])
    }
}

struct MemoryPathError: Error {
    let message: String
}

private extension String {
    /// Все вхождения подстроки (без перекрытий).
    func ranges(of needle: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var start = startIndex
        while start < endIndex, let range = self.range(of: needle, range: start..<endIndex) {
            result.append(range)
            start = range.upperBound
        }
        return result
    }
}
