import Foundation

/// Date / time formatting from the mailbox's regional settings (`mailboxSettings.dateFormat` / `timeFormat` /
/// `language.locale`, read from Graph). Graph gives .NET short-date / short-time patterns; they're translated to ICU.
/// Missing or unusable values fall back to the system formats. Times stay in the device time zone (no shift).
public struct MailRegionalFormat: Sendable {
    public let locale: Locale
    public let datePattern: String?
    public let timePattern: String?
    public let timeZone: TimeZone

    public init(_ s: MailboxRegionalSettings?, fallbackLocale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        if let id = s?.locale?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            locale = Locale(identifier: id.replacingOccurrences(of: "-", with: "_"))
        } else { locale = fallbackLocale }
        datePattern = s?.dateFormat.flatMap(Self.icuPattern)
        timePattern = s?.timeFormat.flatMap(Self.icuPattern)
        self.timeZone = timeZone
    }

    /// .NET custom date/time pattern → ICU (DateFormatter). `tt`/`t` → `a`, `ddd`/`dddd` → `EEE`/`EEEE`, `f`/`K`/`z`
    /// families dropped. Quoted literals are kept. Returns nil for an empty or standard-format specifier ("d", "t").
    public static func icuPattern(_ net: String) -> String? {
        let p = net.trimmingCharacters(in: .whitespaces)
        guard p.count > 1 else { return nil }   // single-letter = .NET standard format specifier: use the system
        var out = ""
        let chars = Array(p)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" || c == "\"" {   // literal run
                var j = i + 1; var lit = ""
                while j < chars.count, chars[j] != c { lit.append(chars[j]); j += 1 }
                out += "'" + lit.replacingOccurrences(of: "'", with: "''") + "'"
                i = j + 1; continue
            }
            if c == "\\", i + 1 < chars.count { out += "'\(chars[i + 1])'"; i += 2; continue }
            var j = i
            while j < chars.count, chars[j] == c { j += 1 }
            let n = j - i
            switch c {
            case "t": out += "a"
            case "d": out += n >= 4 ? "EEEE" : (n == 3 ? "EEE" : String(repeating: "d", count: n))
            case "f", "F", "K", "z", "g": break
            case "y", "M", "H", "h", "m", "s": out += String(repeating: c, count: n)
            default:
                if c.isLetter { out += "'\(String(repeating: c, count: n))'" } else { out += String(repeating: c, count: n) }
            }
            i = j
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func formatter(_ pattern: String?, date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        if let pattern { f.dateFormat = pattern } else { f.dateStyle = date; f.timeStyle = time }
        return f
    }

    public func shortDate(_ d: Date) -> String { formatter(datePattern, date: .short, time: .none).string(from: d) }
    public func shortTime(_ d: Date) -> String { formatter(timePattern, date: .none, time: .short).string(from: d) }
    public func dateTime(_ d: Date) -> String { shortDate(d) + " " + shortTime(d) }

    /// Message-list column: today → time, within 6 days → weekday, else day + month (locale template).
    public func listTime(_ d: Date, now: Date = .now) -> String {
        var cal = Calendar(identifier: .gregorian); cal.locale = locale; cal.timeZone = timeZone
        if cal.isDate(d, inSameDayAs: now) { return shortTime(d) }
        let f = DateFormatter(); f.locale = locale; f.timeZone = timeZone
        if let days = cal.dateComponents([.day], from: d, to: now).day, days >= 0, days < 6 {
            f.setLocalizedDateFormatFromTemplate("EEE")
        } else {
            f.setLocalizedDateFormatFromTemplate("dMMM")
        }
        return f.string(from: d)
    }
}
