import Foundation

// UI translations are bundled separately from private contest profiles.
// The Chinese source string is used as a stable key and as a safe fallback.
enum HUDLanguage {
    static let choices = ["system", "zh-Hans", "zh-Hant", "en", "ja"]
    static func canonical(_ value: String) -> String {
        choices.contains(value) ? value : "system"
    }
    static func resolved(_ choice: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let value = canonical(choice)
        if value != "system" { return value }
        for identifier in preferredLanguages {
            let item = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
            if item.hasPrefix("zh-hant") || item.hasPrefix("zh-tw") || item.hasPrefix("zh-hk") || item.hasPrefix("zh-mo") { return "zh-Hant" }
            if item.hasPrefix("zh") { return "zh-Hans" }
            if item.hasPrefix("ja") { return "ja" }
            if item.hasPrefix("en") { return "en" }
        }
        return "en"
    }
}

enum L10n {
    // Test tools may specify a local fixture directory. Published macOS apps
    // use Contents/Resources/locales; no network translation is performed.
    static var overrideLocalesURL: URL? = nil
    private static var cache: [String: [String: String]] = [:]
    private static let lock = NSLock()

    static func translations(for locale: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let found = cache[locale] { return found }
        let url = overrideLocalesURL?.appendingPathComponent("\(locale).json")
            ?? Bundle.main.url(forResource: locale, withExtension: "json", subdirectory: "locales")
        let parsed = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache[locale] = parsed
        return parsed
    }

    static func resetCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    static func tr(_ key: String, choice: String) -> String {
        let locale = HUDLanguage.resolved(choice)
        if locale == "zh-Hans" { return key }
        return translations(for: locale)[key] ?? key
    }

    // Uses named replacement tokens rather than printf, so translator-supplied
    // percent signs and format syntax cannot cause type mismatches.
    static func format(_ key: String, choice: String, values: [String: String]) -> String {
        var result = tr(key, choice: choice)
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
    }

    // The parser's internal status values remain canonical across languages:
    // do not translate them in the model or the existing success checks break.
    static func status(_ original: String, choice: String) -> String {
        if original.hasPrefix("同步失败：") {
            let detail = String(original.dropFirst("同步失败：".count))
                .replacingOccurrences(of: "（原数据可能过时）", with: "")
            return format("同步失败：{{error}}（原数据可能过时）", choice: choice, values: ["error": tr(detail, choice: choice)])
        }
        if original.hasPrefix("数据格式不匹配：") {
            let detail = String(original.dropFirst("数据格式不匹配：".count))
            return format("数据格式不匹配：{{error}}", choice: choice, values: ["error": tr(detail, choice: choice)])
        }
        return tr(original, choice: choice)
    }
}
