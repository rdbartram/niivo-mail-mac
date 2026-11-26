import Foundation

/// Positions overlapping timed events side by side (Outlook/Fantastical-style columns).
/// O(n log n) per day; runs on every visible-range change, so it must stay cheap.
public struct PlacedEvent: Sendable, Hashable {
    public var event: CalendarEvent
    /// Column index and how many columns the overlap cluster needs.
    public var column: Int
    public var columns: Int
    /// Clipped to the day, in minutes from local midnight.
    public var startMinute: Int
    public var endMinute: Int
}

public enum DayLayout {
    public static func place(_ events: [CalendarEvent], day: Date, calendar: Calendar = .current) -> [PlacedEvent] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let timed = events
            .filter { !$0.isAllDay && $0.end > dayStart && $0.start < dayEnd }
            .map { e -> PlacedEvent in
                let s = max(e.start, dayStart), en = min(e.end, dayEnd)
                let sm = Int(s.timeIntervalSince(dayStart) / 60)
                let em = max(sm + 15, Int(en.timeIntervalSince(dayStart) / 60)) // min visual height
                return PlacedEvent(event: e, column: 0, columns: 1, startMinute: sm, endMinute: em)
            }
            .sorted { ($0.startMinute, -$0.endMinute, $0.event.id) < ($1.startMinute, -$1.endMinute, $1.event.id) }

        var result: [PlacedEvent] = []
        var cluster: [PlacedEvent] = []
        var columnEnds: [Int] = []
        var clusterEnd = -1

        func flush() {
            let n = columnEnds.count
            result += cluster.map { var p = $0; p.columns = n; return p }
            cluster.removeAll(); columnEnds.removeAll()
        }

        for var p in timed {
            if p.startMinute >= clusterEnd { flush(); clusterEnd = -1 }
            if let free = columnEnds.firstIndex(where: { $0 <= p.startMinute }) {
                p.column = free; columnEnds[free] = p.endMinute
            } else {
                p.column = columnEnds.count; columnEnds.append(p.endMinute)
            }
            clusterEnd = max(clusterEnd, p.endMinute)
            cluster.append(p)
        }
        flush()
        return result
    }
}
