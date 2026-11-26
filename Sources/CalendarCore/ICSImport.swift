import Foundation

/// One VEVENT read from an .ics file, before it becomes an `EventDraft`.
public struct ICSEvent: Sendable, Equatable, Identifiable {
    public var id: String { uid ?? "\(start.timeIntervalSince1970)-\(summary)" }
    public var uid: String?
    public var summary: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    /// Mapped repeat (simple RRULEs only). `.never` with `recurrenceDropped` = only the first occurrence is imported.
    public var repeats: EventDraft.Repeat
    public var recurrenceDropped: Bool
    /// ATTENDEE lines seen. Never imported: creating an event with attendees sends them invitations.
    public var attendeeCount: Int
    /// TZID that isn't an IANA zone (e.g. a Windows name): times were read in the Mac's zone.
    public var unknownZone: String?

    /// Draft for the write path (outbox). No attendees, by design.
    public func draft(calendarId: String) -> EventDraft {
        var d = EventDraft(calendarId: calendarId, subject: summary.isEmpty ? "Imported event" : summary, start: start, end: end,
                           isAllDay: isAllDay, location: location ?? "", notes: notes ?? "")
        d.repeats = repeats
        return d
    }
}

/// Minimal RFC 5545 reader: VEVENT with SUMMARY, DTSTART/DTEND/DURATION (UTC, TZID, floating, VALUE=DATE),
/// LOCATION, DESCRIPTION, UID, RRULE (FREQ=DAILY/WEEKLY/MONTHLY without COUNT/UNTIL/INTERVAL), line unfolding and
/// text unescaping. Cancelled events (STATUS:CANCELLED) and VTODO/VJOURNAL are skipped.
public enum ICSParser {
    public static func parse(_ text: String) -> [ICSEvent] {
        var out: [ICSEvent] = []
        var cur: [(name: String, params: [String: String], value: String)]? = nil
        for line in unfold(text) {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" { cur = []; continue }
            if upper == "END:VEVENT" {
                if let props = cur, let e = event(from: props) { out.append(e) }
                cur = nil; continue
            }
            guard cur != nil, let p = property(line) else { continue }
            cur?.append(p)
        }
        return out
    }

    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = raw.first, f == " " || f == "\t", !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() }
            else { lines.append(String(raw)) }
        }
        return lines.filter { !$0.isEmpty }
    }

    /// `NAME;PARAM=V;PARAM2="v":value` (colon inside quotes allowed).
    static func property(_ line: String) -> (name: String, params: [String: String], value: String)? {
        var inQuote = false, colon: String.Index?
        for i in line.indices {
            if line[i] == "\"" { inQuote.toggle() }
            if line[i] == ":" && !inQuote { colon = i; break }
        }
        guard let colon else { return nil }
        let head = line[..<colon].split(separator: ";").map(String.init)
        guard let name = head.first?.uppercased() else { return nil }
        var params: [String: String] = [:]
        for p in head.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (name, params, String(line[line.index(after: colon)...]))
    }

    static func unescape(_ s: String) -> String {
        var out = "", it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n { case "n", "N": out.append("\n"); default: out.append(n) }
        }
        return out
    }

    /// (date, isDate, unknown TZID).
    static func date(_ value: String, params: [String: String]) -> (Date, Bool, String?)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if params["VALUE"]?.uppercased() == "DATE" || (v.count == 8 && !v.contains("T")) {
            f.dateFormat = "yyyyMMdd"; f.timeZone = .current
            return f.date(from: String(v.prefix(8))).map { ($0, true, nil) }
        }
        var unknown: String?
        if v.hasSuffix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
        } else if let tzid = params["TZID"] {
            if let z = TimeZone(identifier: tzid) { f.timeZone = z } else { f.timeZone = .current; unknown = tzid }
        } else {
            f.timeZone = .current   // floating time: the reader's wall clock
        }
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: String(v.prefix(15))).map { ($0, false, unknown) }
    }

    /// `P1D`, `PT1H30M`, `P2W`, `-PT15M` (sign ignored for DTEND maths).
    static func duration(_ s: String) -> TimeInterval? {
        var v = Substring(s.uppercased()); if v.first == "-" || v.first == "+" { v = v.dropFirst() }
        guard v.first == "P" else { return nil }
        v = v.dropFirst()
        var total: TimeInterval = 0, num = "", inTime = false
        for c in v {
            if c == "T" { inTime = true; continue }
            if c.isNumber { num.append(c); continue }
            guard let n = Double(num) else { return nil }
            switch (c, inTime) {
            case ("W", _): total += n * 7 * 86400
            case ("D", _): total += n * 86400
            case ("H", true): total += n * 3600
            case ("M", true): total += n * 60
            case ("S", true): total += n
            default: return nil
            }
            num = ""
        }
        return total
    }

    static func event(from props: [(name: String, params: [String: String], value: String)]) -> ICSEvent? {
        func first(_ n: String) -> (name: String, params: [String: String], value: String)? { props.first { $0.name == n } }
        if first("STATUS")?.value.uppercased() == "CANCELLED" { return nil }
        guard let ds = first("DTSTART"), let st = date(ds.value, params: ds.params) else { return nil }
        let start = st.0, allDay = st.1, z1 = st.2
        var end: Date, z2: String? = nil
        if let de = first("DTEND"), let en = date(de.value, params: de.params) { end = en.0; z2 = en.2 }
        else if let du = first("DURATION").flatMap({ duration($0.value) }) { end = start.addingTimeInterval(du) }
        else { end = allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(3600) }
        if end <= start { end = allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(1800) }

        var repeats = EventDraft.Repeat.never, dropped = false
        if let r = first("RRULE")?.value.uppercased() {
            let parts = Dictionary(r.split(separator: ";").compactMap { p -> (String, String)? in
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init); return kv.count == 2 ? (kv[0], kv[1]) : nil
            }, uniquingKeysWith: { a, _ in a })
            let plain = parts["COUNT"] == nil && parts["UNTIL"] == nil && (parts["INTERVAL"] ?? "1") == "1"
            switch (parts["FREQ"], plain) {
            case ("DAILY", true) where parts["BYDAY"] == nil: repeats = .daily
            case ("WEEKLY", true) where parts["BYDAY"] == "MO,TU,WE,TH,FR": repeats = .weekdays
            case ("WEEKLY", true) where parts["BYDAY"] == nil || parts["BYDAY"]?.contains(",") == false: repeats = .weekly
            case ("MONTHLY", true) where parts["BYDAY"] == nil: repeats = .monthly
            default: dropped = true
            }
        }
        return ICSEvent(uid: first("UID")?.value, summary: unescape(first("SUMMARY")?.value ?? ""), start: start, end: end,
                        isAllDay: allDay, location: first("LOCATION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
                        notes: first("DESCRIPTION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
                        repeats: repeats, recurrenceDropped: dropped,
                        attendeeCount: props.filter { $0.name == "ATTENDEE" }.count, unknownZone: z1 ?? z2)
    }
}
