import Foundation

/// What the editor edits. Turned into a Graph JSON body for POST (all fields) or PATCH (changed fields only).
/// The body (notes) is only ever sent for NEW events: existing bodies are HTML with Teams/Zoom join blocks and
/// the cache only holds a plain-text preview, so a PATCH would destroy them.
public struct EventDraft: Sendable, Equatable {
    public var calendarId: String
    public var subject: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String
    public var notes: String
    public var showAs: ShowAs
    public var isPrivate: Bool
    public var isOnlineMeeting: Bool
    public var attendees: [Attendee]
    /// New events only. Editing an existing series' pattern is left to Outlook in the spike.
    public var repeats: Repeat = .never
    /// Outlook category names (master list colours). Sent only when changed.
    public var categories: [String] = []
    /// Room mailbox picked in the room finder: sent as `location.locationEmailAddress` (+ conferenceRoom type).
    public var locationEmail: String = ""
    /// PURVIEW-HOOK: label for a NEW meeting and its msip_labels value (written as the extended property on POST only;
    /// existing events keep their label, see EventEditor).
    public var labelId: String?
    public var labelHeader: String?

    public enum Repeat: String, CaseIterable, Sendable {
        case never, daily, weekdays, weekly, monthly
        public var title: String {
            switch self { case .never: "Never"; case .daily: "Every day"; case .weekdays: "Every weekday"
                          case .weekly: "Every week"; case .monthly: "Every month" }
        }
    }

    public init(calendarId: String, subject: String = "", start: Date, end: Date, isAllDay: Bool = false,
                location: String = "", notes: String = "", showAs: ShowAs = .busy, isPrivate: Bool = false,
                isOnlineMeeting: Bool = false, attendees: [Attendee] = []) {
        self.calendarId = calendarId; self.subject = subject; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.location = location; self.notes = notes; self.showAs = showAs
        self.isPrivate = isPrivate; self.isOnlineMeeting = isOnlineMeeting; self.attendees = attendees
    }

    public init(_ e: CalendarEvent) {
        self.init(calendarId: e.calendarId, subject: e.subject, start: e.start, end: e.end, isAllDay: e.isAllDay,
                  location: e.location ?? "", notes: "", showAs: e.showAs == .unknown ? .busy : e.showAs,
                  isPrivate: e.legacySensitivity == .private, isOnlineMeeting: e.onlineMeetingURL != nil,
                  attendees: e.attendees)
        categories = e.categories ?? []
    }

    /// Graph JSON. `old == nil` → full body for POST. Otherwise only what changed (PATCH), never `body`.
    public func graphJSON(changedFrom old: EventDraft? = nil) -> [String: Any] {
        var j: [String: Any] = [:]
        func changed<T: Equatable>(_ k: KeyPath<EventDraft, T>) -> Bool { old.map { $0[keyPath: k] != self[keyPath: k] } ?? true }
        if changed(\.subject) { j["subject"] = subject }
        if changed(\.start) || changed(\.end) || changed(\.isAllDay) {
            j["isAllDay"] = isAllDay
            j["start"] = GraphTime.json(start, allDay: isAllDay)
            j["end"] = GraphTime.json(end, allDay: isAllDay)
        }
        if changed(\.location) || changed(\.locationEmail) {
            var loc: [String: Any] = ["displayName": location]
            if !locationEmail.isEmpty { loc["locationEmailAddress"] = locationEmail; loc["locationType"] = "conferenceRoom" }
            j["location"] = loc
        }
        if changed(\.categories) { j["categories"] = categories }
        if changed(\.showAs) { j["showAs"] = showAs.rawValue }
        if changed(\.isPrivate) { j["sensitivity"] = isPrivate ? "private" : "normal" }
        if changed(\.attendees) {
            j["attendees"] = attendees.map { ["emailAddress": ["address": $0.address, "name": $0.name], "type": $0.type ?? "required"] }
        }
        if old == nil, repeats != .never {
            j["recurrence"] = recurrenceJSON()
        }
        if old == nil {
            if !notes.isEmpty { j["body"] = ["contentType": "text", "content": notes] }
            if let h = labelHeader, !h.isEmpty {   // PURVIEW-HOOK
                j["singleValueExtendedProperties"] = [["id": MIPMetadata.extendedPropertyId, "value": h]]
            }
            if isOnlineMeeting { j["isOnlineMeeting"] = true; j["onlineMeetingProvider"] = "teamsForBusiness" }
        } else if changed(\.isOnlineMeeting), isOnlineMeeting {
            j["isOnlineMeeting"] = true; j["onlineMeetingProvider"] = "teamsForBusiness"
        }
        return j
    }

    /// Graph patternedRecurrence, open-ended, anchored at the start day (local).
    func recurrenceJSON() -> [String: Any] {
        let c = Calendar.current
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        let pattern: [String: Any]
        switch repeats {
        case .daily: pattern = ["type": "daily", "interval": 1]
        case .weekdays: pattern = ["type": "weekly", "interval": 1, "daysOfWeek": Array(names[1...5]), "firstDayOfWeek": "monday"]
        case .weekly: pattern = ["type": "weekly", "interval": 1, "daysOfWeek": [names[c.component(.weekday, from: start) - 1]]]
        case .monthly: pattern = ["type": "absoluteMonthly", "interval": 1, "dayOfMonth": c.component(.day, from: start)]
        case .never: pattern = [:]
        }
        return ["pattern": pattern, "range": ["type": "noEnd", "startDate": f.string(from: start),
                                              "recurrenceTimeZone": TimeZone.current.identifier]]
    }

    /// The optimistic local copy shown until Exchange confirms.
    public func applied(to e: CalendarEvent) -> CalendarEvent {
        var e = e
        e.calendarId = calendarId; e.subject = subject; e.start = start; e.end = end; e.isAllDay = isAllDay
        e.location = location.isEmpty ? nil : location; e.showAs = showAs
        e.legacySensitivity = isPrivate ? .private : (e.legacySensitivity == .private ? .normal : e.legacySensitivity)
        e.attendees = attendees
        e.categories = categories.isEmpty ? nil : categories
        if e.bodyPreview == nil, !notes.isEmpty { e.bodyPreview = notes }
        e.pendingSync = true
        return e
    }

    /// Apply a Graph PATCH/POST body to an event (fixture server, and tests).
    public static func apply(json j: [String: Any], to e: CalendarEvent) -> CalendarEvent {
        var e = e
        if let s = j["subject"] as? String { e.subject = s }
        if let a = j["isAllDay"] as? Bool { e.isAllDay = a }
        if let s = (j["start"] as? [String: Any]).flatMap(GraphTime.parse(json:)) { e.start = s }
        if let s = (j["end"] as? [String: Any]).flatMap(GraphTime.parse(json:)) { e.end = s }
        if let l = (j["location"] as? [String: Any])?["displayName"] as? String { e.location = l.isEmpty ? nil : l }
        if let s = j["showAs"] as? String { e.showAs = ShowAs(rawValue: s) ?? e.showAs }
        if let s = j["sensitivity"] as? String { e.legacySensitivity = LegacySensitivity(rawValue: s) ?? .normal }
        if let b = (j["body"] as? [String: Any])?["content"] as? String { e.bodyPreview = b }
        if let c = j["categories"] as? [String] { e.categories = c.isEmpty ? nil : c }
        if let a = j["attendees"] as? [[String: Any]] {
            e.attendees = a.compactMap { raw -> Attendee? in
                guard let m = raw["emailAddress"] as? [String: Any] else { return nil }
                let t = raw["type"] as? String
                return Attendee(name: m["name"] as? String ?? "", address: m["address"] as? String ?? "", response: "none",
                                type: t == "required" ? nil : t)
            }
        }
        return e
    }
}

/// How an event leaves the calendar. Exchange semantics differ and the UI must say which one happens.
public enum RemoveMode: String, Codable, Sendable {
    /// Appointment (no attendees) or an item only in this calendar: just delete it.
    case delete
    /// I organise a meeting with attendees: send a cancellation (with optional message), then it's removed.
    case cancel
    /// I'm an attendee: decline (organiser is told) and remove it from my calendar.
    case decline
}

extension GraphTime {
    /// Graph `dateTimeTimeZone`. Timed: UTC wall time. All-day: local midnight in the local IANA zone, as Outlook does.
    public static func json(_ d: Date, allDay: Bool) -> [String: String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = allDay ? .current : TimeZone(identifier: "UTC")
        return ["dateTime": f.string(from: d), "timeZone": allDay ? TimeZone.current.identifier : "UTC"]
    }

    static func parse(json: [String: Any]) -> Date? {
        guard let s = json["dateTime"] as? String else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }      // legacy "…Z" bodies
        let tz = (json["timeZone"] as? String).flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.timeZone = tz
        return f.date(from: String(s.prefix(19)))
    }
}
