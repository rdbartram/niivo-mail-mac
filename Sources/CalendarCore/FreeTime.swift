import Foundation

public enum FreeTime {
    /// Minute ranges (from local midnight of `day`) of ≥ `minGap` minutes where none of `events` blocks.
    /// Free and cancelled items never block. All-day items block the whole window when busy/OOF/tentative/
    /// working elsewhere: someone out of office all day is not free.
    public static func gaps(_ events: [CalendarEvent], day: Date, from: Int, to: Int, minGap: Int = 15,
                            calendar: Calendar = .current) -> [(Int, Int)] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let blocking = events.filter { !$0.isCancelled && $0.showAs != .free && $0.start < dayEnd && $0.end > dayStart }
        if blocking.contains(where: \.isAllDay) { return [] }
        let busy = blocking
            .map { (max(Int($0.start.timeIntervalSince(dayStart) / 60), from), min(Int($0.end.timeIntervalSince(dayStart) / 60), to)) }
            .filter { $0.0 < $0.1 }
            .sorted { $0.0 < $1.0 }
        var gaps: [(Int, Int)] = [], cursor = from
        for b in busy {
            if b.0 - cursor >= minGap { gaps.append((cursor, b.0)) }
            cursor = max(cursor, b.1)
        }
        if to - cursor >= minGap { gaps.append((cursor, to)) }
        return gaps
    }
}
