import Foundation
import UIKit

/// Журнал событий приложения: что происходило с микрофоном, распознаванием, озвучкой и звонком.
/// Нужен, чтобы разбираться с поведением на настоящем телефоне (в фоне, с очками): его видно
/// в «Настройки → Журнал», оттуда им можно поделиться.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 800
    private let fileURL: URL
    private var unsaved = 0
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = caches.appendingPathComponent("journal.txt")
        if let saved = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = Array(saved.split(separator: "\n").map(String.init).suffix(limit / 2))
        }
        lines.append("———— запуск \(Self.dayStamp()) ————")
    }

    /// Добавляет строку. `area` — короткая метка: «звук», «речь», «голос», «звонок», «очки».
    func add(_ area: String, _ message: String) {
        lock.lock()
        let line = "\(formatter.string(from: Date())) [\(area)] \(message)"
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        unsaved += 1
        let shouldSave = unsaved >= 20
        if shouldSave { unsaved = 0 }
        let snapshot = shouldSave ? lines.joined(separator: "\n") : nil
        lock.unlock()
        if let snapshot { try? snapshot.write(to: fileURL, atomically: true, encoding: .utf8) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func save() {
        lock.lock()
        unsaved = 0
        let snapshot = lines.joined(separator: "\n")
        lock.unlock()
        try? snapshot.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func clear() {
        lock.lock()
        lines = ["———— очищен \(Self.dayStamp()) ————"]
        unsaved = 0
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM, HH:mm"
        return formatter.string(from: Date())
    }
}

/// Короткая запись в журнал.
func journal(_ area: String, _ message: String) {
    DiagnosticLog.shared.add(area, message)
}
