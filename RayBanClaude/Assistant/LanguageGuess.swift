import Foundation

/// Грубое определение языка фразы для выбора голоса: русский, узбекский или английский.
///
/// Claude отвечает на языке собеседника, поэтому язык озвучки определяется по каждой фразе ответа,
/// а не по настройке: узбекская фраза не должна звучать с русским акцентом.
enum LanguageGuess {
    private static let uzbekMarkers: Set<String> = [
        "va", "bu", "men", "sen", "siz", "biz", "uchun", "bilan", "emas", "yoʻq", "yo'q", "kerak", "bor", "edi",
        "qanday", "nima", "rahmat", "salom", "albatta", "hozir", "bugun", "ertaga", "kecha", "juda", "yaxshi",
        "mumkin", "boʻladi", "bo'ladi", "qilish", "qiling", "keyin", "lekin", "agar", "ham", "shu", "u", "ular",
    ]
    private static let englishMarkers: Set<String> = [
        "the", "and", "is", "are", "you", "your", "it", "to", "of", "in", "that", "this", "for", "with", "i", "we",
        "what", "how", "can", "will", "have", "be", "not", "do", "on", "at",
    ]

    /// ISO 639-1 код фразы или `fallback`, если по фразе не понять.
    static func iso(for text: String, fallback: String) -> String {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return fallback }
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        if Double(cyrillic) / Double(letters.count) > 0.5 {
            // Узбекская кириллица встречается редко, но у неё свои буквы.
            let uzbekCyrillic = text.contains("ў") || text.contains("қ") || text.contains("ғ") || text.contains("ҳ")
            return uzbekCyrillic ? "uz" : "ru"
        }
        let lowered = text.lowercased()
        if lowered.contains("oʻ") || lowered.contains("gʻ") || lowered.contains("o'") || lowered.contains("g'") {
            return "uz"
        }
        let words = lowered.split { !$0.isLetter && $0 != "'" && $0 != "ʻ" }.map(String.init)
        let uzbek = words.filter { uzbekMarkers.contains($0) }.count
        let english = words.filter { englishMarkers.contains($0) }.count
        if uzbek > english { return "uz" }
        if english > 0 { return "en" }
        return fallback == "ru" ? "en" : fallback // латиница без подсказок — скорее английский
    }

    /// BCP-47 для голоса iOS.
    static func bcp47(for iso: String) -> String {
        switch iso {
        case "ru": return "ru-RU"
        case "uz": return "uz-UZ"
        case "en": return "en-US"
        default: return iso
        }
    }
}
