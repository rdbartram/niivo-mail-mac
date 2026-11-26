import Foundation

// WHEN (docs/SUITE.md, wireframe v0-4): slot finding for a piece of work, and the confirm-gated focus block it becomes.
//
// * `SlotFinder.propose` is pure: busy intervals + existing focus blocks + working hours + duration + due date → the
//   next three slots. Day windows are built with `Calendar` wall-clock arithmetic (never `+ 86_400`), so DST weeks keep
//   08:30 local on both sides. Every blocker is padded by a buffer (10 min by default); the working-hours edges aren't.
//   Slots that end before the due day is over come first; for deep work (≥ 45 min) a morning start beats an afternoon
//   one; then earliest first. When nothing fits before the due date it says so (`nothingBeforeDue`) and still offers
//   the next slots after it.
// * `FocusBlockPlan` is what a taken slot turns into: an event on the OWNER'S OWN calendar, shown as tentative, with no
//   attendees and no online meeting, so nobody is ever invited. `PendingFocusBlock` holds it until the user confirms;
//   only `confirm(using:)` calls the writer. The subject is the user's own typed title or a neutral "Focus block":
//   text derived from (possibly labelled) mail never leaves the label gate through a calendar subject.

public struct SlotHours: Codable, Sendable, Hashable {
    /// Minutes from local midnight (08:30 → 510, 17:00 → 1020).
    public var startMinute: Int
    public var endMinute: Int
    /// `Calendar` weekday numbers (1 = Sunday … 7 = Saturday). Default Monday–Friday.
    public var weekdays: Set<Int>
    public init(startMinute: Int = 510, endMinute: Int = 1020, weekdays: Set<Int> = [2, 3, 4, 5, 6]) {
        self.startMinute = startMinute; self.endMinute = endMinute; self.weekdays = weekdays
    }
    public static let standard = SlotHours()
    public var length: Int { max(0, endMinute - startMinute) }
}

public struct SlotProposal: Sendable, Hashable {
    /// Up to `count` slots, best first.
    public var slots: [DateInterval]
    /// A due date was given and no slot fits before the end of that day (the slots, if any, are after it).
    public var nothingBeforeDue: Bool
    /// The work is longer than a whole working day: no single slot can hold it.
    public var tooLong: Bool
    public init(slots: [DateInterval], nothingBeforeDue: Bool, tooLong: Bool) {
        self.slots = slots; self.nothingBeforeDue = nothingBeforeDue; self.tooLong = tooLong
    }
}

public enum SlotFinder {
    /// Work of this length or more counts as deep work (mornings preferred).
    public static let deepMinutes = 45

    /// The deadline a due date stands for: the end of that local day (due dates are days; promises resolve to midnight).
    public static func deadline(for due: Date, calendar: Calendar) -> Date {
        let d0 = calendar.startOfDay(for: due)
        return calendar.date(byAdding: .day, value: 1, to: d0) ?? due
    }

    /// Next slots for `minutes` of work.
    /// - busy: anything that blocks (meetings, tentative, OOF); merge order doesn't matter, overlaps are fine.
    /// - focus: existing focus blocks (they block like meetings).
    /// - deep: nil = decide from the duration.
    public static func propose(minutes: Int, due: Date?, busy: [DateInterval], focus: [DateInterval] = [],
                               hours: SlotHours = .standard, now: Date, calendar: Calendar, count: Int = 3,
                               buffer: Int = 10, horizonDays: Int = 14, deep: Bool? = nil, step: Int = 5) -> SlotProposal {
        let need = TimeInterval(max(1, minutes) * 60)
        guard minutes <= hours.length, hours.length > 0 else { return SlotProposal(slots: [], nothingBeforeDue: due != nil, tooLong: true) }
        let isDeep = deep ?? (minutes >= deepMinutes)
        let pad = TimeInterval(max(0, buffer) * 60)
        let blockers = merge((busy + focus).filter { $0.duration > 0 }.map {
            DateInterval(start: $0.start.addingTimeInterval(-pad), end: $0.end.addingTimeInterval(pad))
        })
        let deadline = due.map { deadline(for: $0, calendar: calendar) }
        var days = horizonDays
        if let deadline, let n = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: deadline).day { days = max(days, n + 3) }
        days = min(days, 120)

        struct Cand { var slot: DateInterval; var beforeDue: Bool; var morning: Bool }
        var cands: [Cand] = []
        let today = calendar.startOfDay(for: now)
        for k in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: k, to: today),
                  hours.weekdays.contains(calendar.component(.weekday, from: day)),
                  let ws = wallClock(day, hours.startMinute, calendar), let we = wallClock(day, hours.endMinute, calendar), ws < we else { continue }
            var cursor = max(ws, roundUp(now, step: step, calendar: calendar))
            guard cursor < we else { continue }
            let noon = wallClock(day, 12 * 60, calendar) ?? we
            // Free gaps inside [cursor, we).
            var gaps: [DateInterval] = []
            for b in blockers where b.end > cursor && b.start < we {
                if b.start > cursor { gaps.append(DateInterval(start: cursor, end: b.start)) }
                cursor = max(cursor, b.end)
                if cursor >= we { break }
            }
            if cursor < we { gaps.append(DateInterval(start: cursor, end: we)) }
            for g in gaps {
                let s = roundUp(g.start, step: step, calendar: calendar)
                let e = s.addingTimeInterval(need)
                guard e <= g.end else { continue }
                let slot = DateInterval(start: s, end: e)
                cands.append(Cand(slot: slot, beforeDue: deadline.map { e <= $0 } ?? true, morning: s < noon))
                // A long gap offers a second start in the afternoon (a choice on the same day), not just its first minute.
                if s < noon, g.end.timeIntervalSince(noon) >= need {
                    let a = roundUp(max(noon, e.addingTimeInterval(pad)), step: step, calendar: calendar)
                    let e2 = a.addingTimeInterval(need)
                    if e2 <= g.end {
                        cands.append(Cand(slot: DateInterval(start: a, end: e2), beforeDue: deadline.map { e2 <= $0 } ?? true, morning: false))
                    }
                }
            }
        }
        let sorted = cands.sorted { a, b in
            if a.beforeDue != b.beforeDue { return a.beforeDue }
            if isDeep, a.morning != b.morning { return a.morning }
            return a.slot.start < b.slot.start
        }
        let anyBefore = cands.contains { $0.beforeDue }
        return SlotProposal(slots: Array(sorted.prefix(max(0, count)).map(\.slot)), nothingBeforeDue: deadline != nil && !anyBefore, tooLong: false)
    }

    /// Busy intervals from calendar events, with FreeTime's rules: free and cancelled items never block; an all-day item
    /// that isn't free blocks its whole day(s).
    public static func busy(from events: [CalendarEvent], excluding ids: Set<String> = [], calendar: Calendar) -> [DateInterval] {
        events.filter { !$0.isCancelled && $0.showAs != .free && !ids.contains($0.id) }.compactMap { e in
            if e.isAllDay {
                let s = calendar.startOfDay(for: e.start)
                let end = max(e.end, calendar.date(byAdding: .day, value: 1, to: s) ?? e.end)
                return DateInterval(start: s, end: end)
            }
            return e.end > e.start ? DateInterval(start: e.start, end: e.end) : nil
        }
    }

    /// Sorted, overlapping or touching intervals joined.
    public static func merge(_ xs: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for x in xs.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, x.start <= last.end { out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, x.end)) }
            else { out.append(x) }
        }
        return out
    }

    static func wallClock(_ day: Date, _ minute: Int, _ calendar: Calendar) -> Date? {
        if minute >= 24 * 60 { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }

    /// Up to the next `step`-minute mark (local wall clock).
    static func roundUp(_ d: Date, step: Int, calendar: Calendar) -> Date {
        guard step > 1 else { return d }
        let c = calendar.dateComponents([.minute, .second, .nanosecond], from: d)
        let m = c.minute ?? 0, s = c.second ?? 0, ns = c.nanosecond ?? 0
        if m % step == 0, s == 0, ns == 0 { return d }
        let add = (step - m % step) * 60 - s
        return calendar.date(byAdding: .second, value: add, to: d).map { calendar.date(bySetting: .nanosecond, value: 0, of: $0) ?? $0 } ?? d
    }
}

// MARK: - Focus block (confirm-gated calendar write)

/// What a taken slot becomes: a tentative block on the owner's own calendar, nobody invited.
public struct FocusBlockPlan: Sendable, Equatable {
    public var calendarId: String
    public var subject: String
    public var slot: DateInterval
    /// An earlier focus block of the same work item that this one replaces (removed after the new one is created).
    public var replacing: String?
    /// Purview: the tenant's default label for new meetings and its msip_labels stamp (same path as the event editor).
    public var labelId: String?
    public var labelHeader: String?
    public init(calendarId: String, subject: String, slot: DateInterval, replacing: String? = nil) {
        self.calendarId = calendarId; self.subject = subject; self.slot = slot; self.replacing = replacing
    }

    /// "Focus: <title>" only for a title the user typed; anything derived from mail gives a neutral subject.
    public static func subject(userTitle: String?) -> String {
        let t = (userTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Focus block" : "Focus: " + String(t.prefix(120))
    }

    /// The owner's own, writable, non-group calendar (default first). Never a principal's or shared calendar, whatever
    /// persona is active.
    public static func ownCalendar(_ cals: [CalendarInfo]) -> CalendarInfo? {
        let own = cals.filter { $0.access == .own && $0.canEdit && !$0.isGroup }
        return own.first(where: \.isDefault) ?? own.first
    }

    /// The event: tentative, private to the owner, no attendees, no Teams link, no body.
    public var draft: EventDraft {
        var d = EventDraft(calendarId: calendarId, subject: subject, start: slot.start, end: slot.end, isAllDay: false, location: "",
                           notes: "", showAs: .tentative, isPrivate: false, isOnlineMeeting: false, attendees: [])
        d.labelId = labelId; d.labelHeader = labelHeader
        return d
    }
}

/// The calendar write behind a confirmed focus block (the app: SyncEngine → outbox → Graph POST /calendars/{id}/events).
public protocol FocusBlockWriter: Sendable {
    /// Creates the event; returns its id (may be a local id until Exchange assigns one).
    func createFocusBlock(_ draft: EventDraft) async throws -> String
    /// Removes an earlier focus block (delete, never cancel: it has no attendees). Throws `FocusBlockError.notFound`
    /// when there is no such event to remove.
    func removeFocusBlock(eventId: String) async throws
}

public enum FocusBlockError: Error, Equatable { case notFound }

public struct FocusBlockResult: Sendable, Equatable {
    public var eventId: String
    /// nil: nothing to replace; false: the earlier block is still on the calendar (the user is told).
    public var replacedRemoved: Bool?
}

/// A slot the user picked, waiting for the explicit confirm. Nothing is written until `confirm(using:)`.
public struct PendingFocusBlock: Sendable, Equatable, Identifiable {
    public var id: String { workItemId + "|" + String(plan.slot.start.timeIntervalSince1970) }
    public var workItemId: String
    public var plan: FocusBlockPlan
    public init(workItemId: String, plan: FocusBlockPlan) { self.workItemId = workItemId; self.plan = plan }

    /// The one write path: create the tentative block, then remove the block it replaces (if any).
    public func confirm(using writer: FocusBlockWriter) async throws -> FocusBlockResult {
        let d = plan.draft
        precondition(d.attendees.isEmpty && !d.isOnlineMeeting, "a focus block never invites anyone")
        let id = try await writer.createFocusBlock(d)
        var removed: Bool?
        if let old = plan.replacing, old != id {
            do { try await writer.removeFocusBlock(eventId: old); removed = true } catch { removed = false }
        }
        return FocusBlockResult(eventId: id, replacedRemoved: removed)
    }
}
