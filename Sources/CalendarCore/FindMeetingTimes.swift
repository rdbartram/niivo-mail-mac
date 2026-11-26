import Foundation

// "Find a time": Graph `POST /me/findMeetingTimes` (Learn, 2026-11-20: delegated Calendars.Read.Shared — our calendar
// set has Calendars.ReadWrite.Shared; work/school accounts only). Times are sent and asked back in UTC
// (`Prefer: outlook.timezone="UTC"`), so no Windows/IANA zone mapping is needed. On any error or an empty answer the
// app falls back to the local `FreeTime.gaps` over the loaded calendar (own calendar only).

public struct MeetingTimeSuggestion: Sendable, Hashable {
    public var start: Date
    public var end: Date
    /// 0–100 (Graph's confidence that every attendee can make it).
    public var confidence: Double
    /// free / tentative / busy / oof / workingElsewhere / unknown.
    public var organizerAvailability: String
    public var reason: String?
    public init(start: Date, end: Date, confidence: Double, organizerAvailability: String, reason: String? = nil) {
        self.start = start; self.end = end; self.confidence = confidence; self.organizerAvailability = organizerAvailability; self.reason = reason
    }
}

public struct MeetingTimeResult: Sendable, Hashable {
    public var suggestions: [MeetingTimeSuggestion]
    /// Graph's `emptySuggestionsReason` (e.g. attendeesUnavailable, organizerUnavailable, unknown); nil/"" when there are suggestions.
    public var emptyReason: String?
    /// true = computed locally from the organiser's own calendar (Graph unavailable / empty).
    public var isLocalFallback: Bool
    public init(suggestions: [MeetingTimeSuggestion], emptyReason: String?, isLocalFallback: Bool) {
        self.suggestions = suggestions; self.emptyReason = emptyReason; self.isLocalFallback = isLocalFallback
    }
}

public enum FindMeetingTimes {
    static let utcFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
    static func dtz(_ d: Date) -> [String: String] { ["dateTime": utcFormat.string(from: d), "timeZone": "UTC"] }

    /// Request body. `attendees` = addresses (required attendees); empty = organiser only.
    public static func body(attendees: [String], from: Date, to: Date, minutes: Int, maxCandidates: Int = 10) throws -> Data {
        let json: [String: Any] = [
            "attendees": attendees.filter { $0.contains("@") }.map { ["type": "required", "emailAddress": ["address": $0]] },
            "timeConstraint": ["activityDomain": "work", "timeSlots": [["start": dtz(from), "end": dtz(to)]]],
            "meetingDuration": "PT\(max(minutes, 5))M",
            "maxCandidates": maxCandidates,
            "isOrganizerOptional": false,
            "returnSuggestionReasons": true,
            "minimumAttendeePercentage": 100,
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    struct R: Decodable {
        struct DT: Decodable { var dateTime: String; var timeZone: String? }
        struct Slot: Decodable { var start: DT; var end: DT }
        struct S: Decodable {
            var confidence: Double?; var organizerAvailability: String?; var suggestionReason: String?; var meetingTimeSlot: Slot?
        }
        var emptySuggestionsReason: String?
        var meetingTimeSuggestions: [S]?
    }

    /// Graph returns e.g. "2026-11-20T09:00:00.0000000" in the requested zone (UTC).
    static func parseDate(_ dt: R.DT) -> Date? {
        let s = String(dt.dateTime.prefix(19))
        guard let d = utcFormat.date(from: s) else { return nil }
        if let z = dt.timeZone, z.uppercased() != "UTC", let tz = TimeZone(identifier: z) {
            return d.addingTimeInterval(-Double(tz.secondsFromGMT(for: d)))
        }
        return d
    }

    public static func parse(_ data: Data) throws -> MeetingTimeResult {
        let r = try JSONDecoder().decode(R.self, from: data)
        let s = (r.meetingTimeSuggestions ?? []).compactMap { x -> MeetingTimeSuggestion? in
            guard let slot = x.meetingTimeSlot, let a = parseDate(slot.start), let b = parseDate(slot.end), b > a else { return nil }
            return MeetingTimeSuggestion(start: a, end: b, confidence: x.confidence ?? 0, organizerAvailability: x.organizerAvailability ?? "unknown",
                                         reason: x.suggestionReason)
        }.sorted { ($0.confidence, $1.start) > ($1.confidence, $0.start) }
        let reason = r.emptySuggestionsReason.flatMap { $0.isEmpty ? nil : $0 }
        return MeetingTimeResult(suggestions: s, emptyReason: s.isEmpty ? (reason ?? "unknown") : nil, isLocalFallback: false)
    }

    /// Local fallback: free slots of `minutes` in the organiser's own loaded events, working hours, weekdays, from
    /// `from` for `days` days (first fit in each gap, max `limit`).
    public static func localSlots(events: [CalendarEvent], from: Date, days: Int, minutes: Int, workStart: Int = 8 * 60,
                                  workEnd: Int = 18 * 60, limit: Int = 10, calendar: Calendar = .current) -> [MeetingTimeSuggestion] {
        var out: [MeetingTimeSuggestion] = []
        let first = calendar.startOfDay(for: from)
        for i in 0..<max(days, 1) {
            guard let day = calendar.date(byAdding: .day, value: i, to: first), !calendar.isDateInWeekend(day) else { continue }
            let nowMin = calendar.isDate(day, inSameDayAs: from)
                ? Int(from.timeIntervalSince(first) / 60) : 0
            let start = max(workStart, Int((Double(nowMin) / 15).rounded(.up)) * 15)
            guard start < workEnd else { continue }
            for g in FreeTime.gaps(events, day: day, from: start, to: workEnd, minGap: minutes, calendar: calendar) {
                let a = day.addingTimeInterval(Double(g.0) * 60)
                out.append(MeetingTimeSuggestion(start: a, end: a.addingTimeInterval(Double(minutes) * 60), confidence: 100,
                                                 organizerAvailability: "free", reason: "Free in your calendar"))
                if out.count >= limit { return out }
            }
        }
        return out
    }
}

/// Minimal client (own URLSession path; the calendar service's HTTP helpers are private).
public struct FindMeetingTimesClient: Sendable {
    public typealias TokenProvider = @Sendable () async throws -> String
    let token: TokenProvider
    let session: URLSession
    public init(token: @escaping TokenProvider, session: URLSession = .shared) { self.token = token; self.session = session }

    public func suggest(attendees: [String], from: Date, to: Date, minutes: Int) async throws -> MeetingTimeResult {
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/findMeetingTimes")!)
        req.httpMethod = "POST"
        req.httpBody = try FindMeetingTimes.body(attendees: attendees, from: from, to: to, minutes: minutes)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw URLError(.badServerResponse) }
        return try FindMeetingTimes.parse(data)
    }
}
