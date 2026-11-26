import Foundation

/// Date maths for the month and agenda views and the secondary time-zone column. UI-free so CoreSelfTest covers it.
public enum CalendarRanges {
    /// The 6 × 7 month grid containing `date`: starts on the first weekday of the week holding the 1st
    /// (locale's `firstWeekday`), always 42 days so the grid height never jumps.
    public static func monthGrid(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let first = calendar.dateInterval(of: .month, for: date)!.start
        let start = calendar.dateInterval(of: .weekOfYear, for: first)!.start
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    /// Interval covered by the month grid (what must be loaded, and what is on screen).
    public static func monthGridInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let days = monthGrid(containing: date, calendar: calendar)
        return DateInterval(start: days[0], end: calendar.date(byAdding: .day, value: 1, to: days[41])!)
    }

    /// Agenda: `days` days from the start of `from`'s day.
    public static func agendaInterval(from: Date, days: Int, calendar: Calendar = .current) -> DateInterval {
        let s = calendar.startOfDay(for: from)
        return DateInterval(start: s, end: calendar.date(byAdding: .day, value: max(1, days), to: s)!)
    }

    /// Events touching `day` (multi-day events appear on each day they cover), all-day first, then by start.
    public static func events(on day: Date, in events: [CalendarEvent], calendar: Calendar = .current) -> [CalendarEvent] {
        let s = calendar.startOfDay(for: day), e = calendar.date(byAdding: .day, value: 1, to: s)!
        return events.filter { $0.start < e && $0.end > s && !$0.isCancelled }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.subject) < ($1.isAllDay ? 0 : 1, $1.start, $1.subject) }
    }

    /// Agenda sections: one per day that has events, in order. Past events of today are kept (they're on screen).
    public static func agendaSections(_ events: [CalendarEvent], interval: DateInterval,
                                      calendar: Calendar = .current) -> [(day: Date, events: [CalendarEvent])] {
        var out: [(Date, [CalendarEvent])] = []
        var d = calendar.startOfDay(for: interval.start)
        while d < interval.end {
            let es = Self.events(on: d, in: events, calendar: calendar)
            if !es.isEmpty { out.append((d, es)) }
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }

    /// Month cell density: show at most `capacity` chips, the rest becomes "+n more".
    public static func chips(_ events: [CalendarEvent], capacity: Int) -> (shown: [CalendarEvent], more: Int) {
        guard events.count > capacity else { return (events, 0) }
        let n = max(0, capacity - 1)   // keep one line for "+n more"
        return (Array(events.prefix(n)), events.count - n)
    }
}

/// Secondary time zone for the week/day gutter.
public enum SecondaryZone {
    /// Label for local hour `hour` on `day` as seen in `zone` ("15:00", or "15:30" for half-hour zones).
    public static func label(hour: Int, day: Date, zone: TimeZone, calendar: Calendar = .current) -> String {
        let local = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        let h = c.component(.hour, from: local), m = c.component(.minute, from: local)
        return String(format: "%02d:%02d", h, m)
    }

    /// Short header for the column: the zone's abbreviation (e.g. "GMT", "EST"), else "UTC+9".
    public static func shortName(_ zone: TimeZone, at date: Date = .now) -> String {
        if let a = zone.abbreviation(for: date), !a.hasPrefix("GMT+"), !a.hasPrefix("GMT-") { return a }
        let s = zone.secondsFromGMT(for: date)
        let h = s / 3600, m = abs(s % 3600) / 60
        return "UTC" + (s >= 0 ? "+" : "-") + "\(abs(h))" + (m != 0 ? String(format: ":%02d", m) : "")
    }

    /// Offered in the picker (IANA ids). Plus whatever the user picked before.
    public static let common = ["Europe/London", "Europe/Zurich", "America/New_York", "America/Chicago", "America/Los_Angeles",
                                "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore", "Asia/Tokyo", "Australia/Sydney", "UTC"]
}
