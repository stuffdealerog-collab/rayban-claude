import Foundation

/// Язык интерфейса — тот же, что язык ассистента: русский, узбекский или английский.
///
/// Надписи в коде написаны по-русски и служат ключами каталога `Localizable.xcstrings`.
/// Язык переключается прямо в приложении, поэтому перевод берётся не из системного языка,
/// а из папки выбранного (`uz.lproj`, `en.lproj`).
enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bundle: Bundle?
    nonisolated(unsafe) private static var current = "ru"

    /// Код текущего языка интерфейса: «ru», «uz» или «en».
    static var code: String { lock.withLock { current } }

    static func setLanguage(_ code: String) {
        // Русский — язык исходных строк: перевод не нужен.
        let path = code == "ru" ? nil : Bundle.main.path(forResource: code, ofType: "lproj")
        lock.withLock {
            current = code
            bundle = path.flatMap(Bundle.init(path:))
        }
    }

    static func string(_ key: String) -> String {
        guard let bundle = lock.withLock({ bundle }) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// Надпись на языке интерфейса. Подстановки в ключе помечены `%@` и заполняются по порядку.
func L(_ key: String, _ arguments: Any...) -> String {
    var text = L10n.string(key)
    for argument in arguments {
        guard let range = text.range(of: "%@") else { break }
        text.replaceSubrange(range, with: "\(argument)")
    }
    return text
}
