import Foundation

/// Runtime reader for a String Catalog (`Localizable.xcstrings`, JSON). The Command Line Tools have no
/// `xcstringstool`, so SwiftPM can't compile the catalog into `.strings` tables; the app ships the raw catalog in its
/// resource bundle (`.copy`) and looks strings up here. Keys are the British English source strings; format keys use
/// `%@` / `%lld` like Xcode-extracted keys.
public struct StringCatalog: Sendable {
    public let sourceLanguage: String
    /// key → language → value
    public let table: [String: [String: String]]

    public init(sourceLanguage: String = "en", table: [String: [String: String]] = [:]) {
        self.sourceLanguage = sourceLanguage; self.table = table
    }

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var t: [String: [String: String]] = [:]
        for (key, entry) in strings {
            guard let locs = (entry as? [String: Any])?["localizations"] as? [String: Any] else { continue }
            var langs: [String: String] = [:]
            for (lang, l) in locs {
                if let unit = (l as? [String: Any])?["stringUnit"] as? [String: Any], let v = unit["value"] as? String {
                    langs[lang] = v
                }
            }
            if !langs.isEmpty { t[key] = langs }
        }
        sourceLanguage = root["sourceLanguage"] as? String ?? "en"
        table = t
    }

    public init(contentsOf url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    public static let supported = ["en", "de", "fr", "it"]

    /// First supported language in `preferred` (e.g. `Locale.preferredLanguages`: "de-CH", "fr-CH"), else English.
    public static func resolve(_ choice: UILanguage, preferred: [String]) -> String {
        if choice != .system { return choice.rawValue }
        for p in preferred {
            let base = String(p.lowercased().prefix { $0 != "-" && $0 != "_" })
            if supported.contains(base) { return base }
        }
        return "en"
    }

    /// Translation of `key` in `language`; the key itself (English source) when missing.
    public func string(_ key: String, language: String) -> String {
        table[key]?[language] ?? key
    }

    public func has(_ key: String, language: String) -> Bool { table[key]?[language] != nil }
}
