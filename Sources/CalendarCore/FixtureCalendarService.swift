import Foundation

/// Synthetic tenant so the app is demonstrable without an Entra app registration.
/// All names/subjects are invented — no real calendar data is ever written into fixtures.
public final class FixtureCalendarService: CalendarService, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String: CalendarEvent] = [:]
    public var simulateOffline = false
    /// Added calendars (by address / group), see the extension at the end of the file.
    var addedSources: [CalendarSource] = []

    public static let labels: [SensitivityLabel] = [
        .init(id: "a1f0c4e2-0000-4000-8000-000000000001", name: "Public", hexColor: "#2E9E5B", priority: 0),
        .init(id: "a1f0c4e2-0000-4000-8000-000000000002", name: "General", hexColor: "#3B7BD8", priority: 1),
        .init(id: "a1f0c4e2-0000-4000-8000-000000000003", name: "Confidential", tooltip: "Business data that could cause harm if shared",
              hexColor: "#E08A1E", priority: 2, headerText: "CONFIDENTIAL — Internal use only",
              footerText: "Classified Confidential by Purview"),
        .init(id: "a1f0c4e2-0000-4000-8000-000000000004", name: "Highly Confidential", tooltip: "Encrypted. Named recipients only.",
              hexColor: "#D2333F", priority: 3, hasProtection: true, headerText: "HIGHLY CONFIDENTIAL",
              footerText: "Protected by Microsoft Purview — do not forward", watermarkText: "HIGHLY CONFIDENTIAL"),
        // Encrypted labels whose per-user usage rights are known (as Graph `sensitivityLabel/rights` returns them),
        // so the demo shows each case. Index 3 above stays "encrypted, rights unknown" → VIEW only.
        .init(id: "a1f0c4e2-0000-4000-8000-000000000005", name: "Restricted — View only", tooltip: "Encrypted. Read only: no copy, print or forward.",
              hexColor: "#8E44AD", priority: 4, hasProtection: true, headerText: "RESTRICTED — VIEW ONLY",
              rights: [.view, .viewRightsData]),
        .init(id: "a1f0c4e2-0000-4000-8000-000000000006", name: "Partner — Copy & print", tooltip: "Encrypted. Recipients may copy, print, reply and forward.",
              hexColor: "#16A085", priority: 5, hasProtection: true, headerText: "PARTNER CONFIDENTIAL",
              rights: [.view, .extract, .print, .reply, .replyAll, .forward, .viewRightsData]),
        .init(id: "a1f0c4e2-0000-4000-8000-000000000007", name: "Internal — Do Not Forward", tooltip: "Encrypted. Reply only: no forward, print or copy.",
              hexColor: "#C0392B", priority: 6, hasProtection: true, headerText: "DO NOT FORWARD",
              rights: [.view, .docEdit, .edit, .reply, .replyAll, .viewRightsData]),
        // A Purview parent label with sub-labels (indices 7–9; keep 0–6 stable, tests index them). The parent is a
        // group header only (Graph `isAppliable: false`); its sub-labels share its priority and colour, as Graph
        // returns them. Ranked above every label before it so existing thresholds don't move.
        .init(id: "a1f0c4e2-0000-4000-8000-000000000008", name: "Secret", tooltip: "Board and M&A material. Pick a sub-label.",
              hexColor: "#5B2C83", priority: 7, isAppliable: false),
        .init(id: "a1f0c4e2-0000-4000-8000-000000000009", name: "All Employees", tooltip: "Encrypted. Any employee may read and reply.",
              hexColor: "#5B2C83", priority: 7, hasProtection: true, headerText: "SECRET — ALL EMPLOYEES",
              parentId: "a1f0c4e2-0000-4000-8000-000000000008",
              rights: [.view, .docEdit, .edit, .reply, .replyAll, .viewRightsData], displayOrder: 1),
        .init(id: "a1f0c4e2-0000-4000-8000-00000000000a", name: "Specified People", tooltip: "Encrypted. Named recipients only.",
              hexColor: "#5B2C83", priority: 7, hasProtection: true, headerText: "SECRET — SPECIFIED PEOPLE",
              parentId: "a1f0c4e2-0000-4000-8000-000000000008", displayOrder: 2),
    ]
    /// Shorthand for the hierarchy-demo labels above.
    public static var labelSecretGroup: String { labels[7].id }
    public static var labelSecretAllEmployees: String { labels[8].id }
    public static var labelSecretSpecified: String { labels[9].id }
    /// Shorthand for the rights-demo labels above.
    public static var labelViewOnly: String { labels[4].id }
    public static var labelCopyPrint: String { labels[5].id }
    public static var labelDoNotForward: String { labels[6].id }
    /// A label ID present on an item but absent from the published policy → must fail closed.
    public static let orphanLabelId = "deadbeef-0000-4000-8000-00000000dead"

    public static let calendars: [CalendarInfo] = [
        .init(id: "cal-me", name: "Calendar", ownerName: "You", ownerAddress: "you@contoso.example",
              mailboxPath: "/me", access: .own, canEdit: true, hexColor: "#5B7FFF", isDefault: true),
        .init(id: "cal-projects", name: "Projects", ownerName: "You", ownerAddress: "you@contoso.example",
              mailboxPath: "/me", access: .own, canEdit: true, hexColor: "#18A999"),
        .init(id: "cal-alex", name: "Alex Morgan", ownerName: "Alex Morgan", ownerAddress: "alex@contoso.example",
              mailboxPath: "/me", access: .shared, canEdit: false, hexColor: "#B05BFF"),
        .init(id: "cal-exec", name: "Sam Rivera (CEO)", ownerName: "Sam Rivera", ownerAddress: "sam@contoso.example",
              mailboxPath: "/users/sam@contoso.example", access: .delegated, canEdit: true, hexColor: "#FF7A45", isDefault: true),
        .init(id: "cal-mia", name: "Calendar", ownerName: "Mia Keller", ownerAddress: "mia@contoso.example",
              mailboxPath: "/me", access: .shared, canEdit: false, hexColor: "#E0457B"),
        // Blank colour on purpose: Graph often returns "" — exercises the palette fallback.
        .init(id: "cal-board", name: "Board of Directors", ownerName: "Board Office", ownerAddress: "board@contoso.example",
              mailboxPath: "/users/board@contoso.example", access: .delegated, canEdit: true, hexColor: ""),
    ]

    public init(anchor: Date = .now, eventsPerCalendarPerWeek: Int = 9, weeks: ClosedRange<Int> = -4...26) {
        var all: [String: CalendarEvent] = [:]
        var rng = SplitMix(seed: 42)
        let cal = Calendar.current
        let week0 = cal.dateInterval(of: .weekOfYear, for: anchor)!.start
        let subjects = ["Design review", "1:1", "Quarterly planning", "Customer call", "Architecture sync",
                        "Hiring panel", "Budget review", "Standup", "Board prep", "Vendor negotiation",
                        "Security briefing", "Incident retro", "Roadmap workshop", "Lunch & learn"]
        let places = ["Room Matterhorn", "Room Eiger", "Teams", "Zürich office", nil, nil]
        // Non-Teams meetings carry their link in the location or body, like real invites.
        let external: [(loc: String?, body: String)] = [
            ("https://contoso.zoom.us/j/81234567890?pwd=Zm9vYmFy", "Join Zoom Meeting"),
            ("Google Meet", "Join with Google Meet: https://meet.google.com/abc-defg-hij\nOr dial: +41 44 000 00 00"),
            (nil, "<p>Join Webex meeting <a href=\"https://contoso.webex.com/meet/jordan.lee\">here</a></p>"),
            ("GoTo Meeting", "Please join my meeting from your computer: https://meet.goto.com/123456789"),
        ]
        let people = ["Jordan Lee", "Priya Shah", "Chris Novak", "Mia Keller", "Luca Bianchi"]
        // Generated events draw from the original four labels only, so the synthetic data set is unchanged; the
        // rights-demo labels get hand-placed events below.
        let labelIds = Self.labels.prefix(4).map(\.id)

        for c in Self.calendars {
            for w in weeks {
                for n in 0..<eventsPerCalendarPerWeek {
                    let day = Int(rng.next() % 5)
                    let hour = 8 + Int(rng.next() % 9)
                    let minute = [0, 0, 30, 15][Int(rng.next() % 4)]
                    let duration = [30, 30, 45, 60, 60, 90, 120][Int(rng.next() % 7)]
                    let start = cal.date(byAdding: .minute, value: (w * 7 + day) * 1440 + hour * 60 + minute, to: week0)!
                    let roll = rng.next() % 100
                    var label: String? = roll < 35 ? nil : labelIds[Int(rng.next() % UInt64(labelIds.count))]
                    if c.id == "cal-exec" && roll > 96 { label = Self.orphanLabelId }
                    let isPrivate = c.access != .own && roll % 11 == 0
                    let id = "\(c.id)-\(w)-\(n)"
                    let ext = roll % 2 == 1 && roll % 5 == 0 ? external[Int(roll) % external.count] : nil
                    let place = ext?.loc ?? places[Int(rng.next() % UInt64(places.count))]
                    // ~2/3 organised by the calendar's owner (editable), the rest invitations (decline only).
                    let organises = roll % 3 != 0
                    all[id] = CalendarEvent(
                        id: id, calendarId: c.id, subject: subjects[Int(rng.next() % UInt64(subjects.count))],
                        start: start, end: start.addingTimeInterval(Double(duration * 60)),
                        location: place,
                        organizer: organises ? c.ownerName : people[Int(rng.next() % UInt64(people.count))],
                        attendees: (0..<Int(rng.next() % 4 + 1)).map { i in
                            let p = people[(i + Int(roll)) % people.count]
                            return Attendee(name: p, address: p.lowercased().replacingOccurrences(of: " ", with: ".") + "@contoso.example",
                                            response: ["accepted", "tentativelyAccepted", "none"][i % 3])
                        },
                        bodyPreview: "Agenda: review open items, decide next steps, agree owners.",
                        showAs: roll % 9 == 0 ? .tentative : .busy,
                        legacySensitivity: isPrivate ? .private : .normal,
                        labelId: label, changeKey: "ck-1",
                        onlineMeetingURL: MeetingLink.extract(
                            joinUrl: roll % 2 == 0 ? "https://teams.microsoft.com/l/meetup-join/fixture" : nil,
                            location: place, body: ext?.body),
                        isOrganizer: organises)
                }
            }
            // A couple of all-day items.
            let d = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: anchor))!
            let id = "\(c.id)-allday"
            all[id] = CalendarEvent(id: id, calendarId: c.id, subject: c.access == .own ? "Public holiday" : "Out of office",
                                    start: d, end: cal.date(byAdding: .day, value: 1, to: d)!, isAllDay: true,
                                    showAs: .oof, changeKey: "ck-1")
        }
        // Rights demo (Projects calendar, tomorrow): one event per usage-rights label.
        let demoDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: anchor))!
        for (i, l) in [Self.labelViewOnly, Self.labelCopyPrint, Self.labelDoNotForward].enumerated() {
            let s = cal.date(byAdding: .hour, value: 7 + i, to: demoDay)!
            let id = "rights-demo-\(i)"
            all[id] = CalendarEvent(id: id, calendarId: "cal-projects", subject: ["Audit read-out", "Partner workshop", "Reorg briefing"][i],
                                    start: s, end: s.addingTimeInterval(1800), location: "Room Säntis", organizer: "You",
                                    attendees: [Attendee(name: "Priya Shah", address: "priya.shah@contoso.example", response: "accepted")],
                                    bodyPreview: "Encrypted agenda.", showAs: .busy, labelId: l, changeKey: "ck-1", isOrganizer: true)
        }
        // One recurring series per editable calendar: weekly team sync, Mondays 09:00, organised by the owner.
        for c in Self.calendars where c.canEdit {
            let mid = "series-\(c.id)"
            let firstStart = cal.date(byAdding: .hour, value: 9, to: cal.date(byAdding: .day, value: 0, to: week0)!)!
            var occ: [CalendarEvent] = []
            for w in weeks {
                let s = cal.date(byAdding: .weekOfYear, value: w, to: firstStart)!
                occ.append(CalendarEvent(id: "\(mid)-\(w)", calendarId: c.id, subject: "Weekly team sync", start: s,
                                         end: s.addingTimeInterval(1800), location: "Room Eiger", organizer: c.ownerName,
                                         attendees: [Attendee(name: "Jonas Weber", address: "jonas@contoso.example", response: "accepted")],
                                         showAs: .busy, changeKey: "ck-1", isOrganizer: true, seriesMasterId: mid))
            }
            for o in occ { all[o.id] = o }
            var m = occ[occ.count / 2]; m.id = mid; m.seriesMasterId = nil
            masters[mid] = m
        }
        events = Self.seedCategories(all)
    }

    /// Series masters (never returned by sync, like Graph's calendarView).
    private var masters: [String: CalendarEvent] = [:]

    public func fetch(calendar: CalendarInfo, eventId: String) async throws -> CalendarEvent {
        try await latency()
        return try lock.withLock {
            guard let m = masters[eventId] ?? events[eventId] else { throw ServiceError.http(404, "not found") }
            return m
        }
    }

    /// Colleagues with no shared calendar — only free/busy, like most of a real org.
    public static let teammates: [Teammate] = [
        .init(name: "Jonas Weber", address: "jonas@contoso.example"),
        .init(name: "Priya Nair", address: "priya@contoso.example"),
        .init(name: "Luca Rossi", address: "luca@contoso.example"),
    ]

    public func freeBusy(for addresses: [String], window: DateInterval) async throws -> [String: [FreeBusySlot]] {
        try await latency()
        let cal = Calendar.current
        var out: [String: [FreeBusySlot]] = [:]
        for a in addresses {
            var slots: [FreeBusySlot] = []
            var d = cal.startOfDay(for: window.start)
            while d < window.end {
                let seed = a.utf8.reduce(UInt64(d.timeIntervalSince1970 / 86400)) { $0 &* 31 &+ UInt64($1) }
                if cal.isDateInWeekend(d) { d = cal.date(byAdding: .day, value: 1, to: d)!; continue }
                if seed % 23 == 0 {
                    slots.append(.init(start: d, end: cal.date(byAdding: .day, value: 1, to: d)!, status: .oof))
                } else {
                    var minute = 8 * 60 + Int(seed % 4) * 15
                    var r = seed
                    while minute < 17 * 60 {
                        r = r &* 6364136223846793005 &+ 1442695040888963407
                        let len = [30, 45, 60, 90][Int((r >> 33) % 4)]
                        if (r >> 40) % 3 != 0 {
                            let st: ShowAs = (r >> 50) % 7 == 0 ? .tentative : .busy
                            slots.append(.init(start: cal.date(byAdding: .minute, value: minute, to: d)!,
                                               end: cal.date(byAdding: .minute, value: minute + len, to: d)!, status: st))
                        }
                        minute += len + [0, 15, 30][Int((r >> 20) % 3)]
                    }
                }
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
            out[a.lowercased()] = slots
        }
        return out
    }

    public func listCalendars() async throws -> [CalendarInfo] {
        try await latency(); return Self.calendars + addedCalendars()
    }

    public func sensitivityLabels() async throws -> [SensitivityLabel] {
        try await latency(); return Self.labels
    }

    public func sync(calendar: CalendarInfo, window: DateInterval, deltaLink: String?) async throws -> SyncBatch {
        try await latency()
        let inWindow = lock.withLock {
            events.values.filter { $0.calendarId == calendar.id && $0.end > window.start && $0.start < window.end }
        }
        return SyncBatch(mode: .replaceWindow, upserts: Array(inWindow))
    }

    public func update(calendar: CalendarInfo, eventId: String, patch: Data, ifMatch: String?) async throws -> CalendarEvent {
        try await latency()
        return try lock.withLock { try applyPatch(eventId: eventId, patch: patch, ifMatch: ifMatch) }
    }

    public func create(calendar: CalendarInfo, body: Data) async throws -> CalendarEvent {
        try await latency()
        let j = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        var e = EventDraft.apply(json: j, to: CalendarEvent(id: "fx-\(UUID().uuidString.prefix(8))", calendarId: calendar.id,
                                                             subject: "", start: .now, end: .now, changeKey: "ck-new"))
        e.organizer = calendar.ownerName; e.isOrganizer = true
        if j["isOnlineMeeting"] as? Bool == true {
            e.onlineMeetingURL = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3afixture-\(e.id)%40thread.v2/0")
        }
        if let r = j["recurrence"] as? [String: Any], let p = r["pattern"] as? [String: Any] {
            let c = Calendar.current
            let mid = e.id
            var occ: [CalendarEvent] = []
            var s = e.start
            let days = (p["daysOfWeek"] as? [String])?.count ?? 1
            while occ.count < 26 {
                let wd = c.component(.weekday, from: s)
                let include = p["type"] as? String != "weekly" || days == 1 || (2...6).contains(wd)
                if include {
                    var o = e; o.id = "\(mid)-\(occ.count)"; o.seriesMasterId = mid
                    o.start = s; o.end = s.addingTimeInterval(e.end.timeIntervalSince(e.start))
                    occ.append(o)
                }
                switch p["type"] as? String {
                case "daily": s = c.date(byAdding: .day, value: 1, to: s)!
                case "absoluteMonthly": s = c.date(byAdding: .month, value: 1, to: s)!
                case "weekly" where days > 1: s = c.date(byAdding: .day, value: 1, to: s)!
                default: s = c.date(byAdding: .weekOfYear, value: 1, to: s)!
                }
            }
            lock.withLock { masters[mid] = e; for o in occ { events[o.id] = o } }
            return e
        }
        lock.withLock { events[e.id] = e }
        return e
    }

    public func remove(calendar: CalendarInfo, eventId: String, mode: RemoveMode, comment: String?, ifMatch: String?) async throws {
        try await latency()
        try lock.withLock {
            if masters[eventId] != nil {
                masters[eventId] = nil
                for (id, o) in events where o.seriesMasterId == eventId { events[id] = nil }
                return
            }
            guard let e = events[eventId] else { return }
            if mode == .delete, let ifMatch, ifMatch != e.changeKey { throw ServiceError.conflict }
            events[eventId] = nil
        }
    }

    private func applyPatch(eventId: String, patch: Data, ifMatch: String?) throws -> CalendarEvent {
        if var m = masters[eventId] {
            // Series master PATCH: apply to the master and fan out to every occurrence (time shift + fields).
            if let ifMatch, ifMatch != m.changeKey { throw ServiceError.conflict }
            let obj = try JSONSerialization.jsonObject(with: patch) as? [String: Any] ?? [:]
            let before = m
            m = EventDraft.apply(json: obj, to: m)
            let shift = m.start.timeIntervalSince(before.start), dur = m.end.timeIntervalSince(m.start)
            for (id, o) in events where o.seriesMasterId == eventId {
                var n = EventDraft.apply(json: obj.filter { $0.key != "start" && $0.key != "end" }, to: o)
                n.start = o.start.addingTimeInterval(shift); n.end = n.start.addingTimeInterval(dur)
                n.changeKey = "ck-\(UUID().uuidString.prefix(6))"; n.pendingSync = false
                events[id] = n
            }
            m.changeKey = "ck-\(UUID().uuidString.prefix(6))"
            masters[eventId] = m
            return m
        }
        guard var e = events[eventId] else { throw ServiceError.http(404, "not found") }
        if let ifMatch, ifMatch != e.changeKey { throw ServiceError.conflict }
        let obj = try JSONSerialization.jsonObject(with: patch) as? [String: Any] ?? [:]
        e = EventDraft.apply(json: obj, to: e)
        if obj["isOnlineMeeting"] as? Bool == true, e.onlineMeetingURL == nil {
            e.onlineMeetingURL = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3afixture-\(e.id)%40thread.v2/0")
        }
        e.changeKey = "ck-\(UUID().uuidString.prefix(6))"
        e.pendingSync = false
        events[eventId] = e
        return e
    }

    /// Test hook: mutate the "server" copy behind the client's back.
    public func serverSideEdit(eventId: String) {
        lock.lock(); defer { lock.unlock() }
        events[eventId]?.changeKey = "ck-server"
        events[eventId]?.subject += " (moved by organiser)"
    }

    private func latency() async throws {
        if simulateOffline { throw ServiceError.offline }
        try await Task.sleep(for: .milliseconds(120))
    }
}

/// Deterministic PRNG so fixtures are stable across launches.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Added calendars, groups, responses, rooms, categories (synthetic)

extension FixtureCalendarService {
    /// Directory the fixture "tenant" knows. Anything else → 404; `noaccess@` → 403 (exists, not shared).
    public static let directory: [String: String] = [
        "lena@contoso.example": "Lena Fischer",
        "facilities@contoso.example": "Facilities",
    ]
    public static let noAccessAddress = "noaccess@contoso.example"
    public static let groups: [GroupRef] = [
        GroupRef(id: "grp-marketing", name: "Marketing Team", mail: "marketing@contoso.example"),
        GroupRef(id: "grp-allhands", name: "All Hands", mail: "allhands@contoso.example"),
    ]
    public static let roomListsFixture: [RoomList] = [
        RoomList(name: "Zürich HQ", emailAddress: "rooms-zurich@contoso.example"),
        RoomList(name: "Bern office", emailAddress: "rooms-bern@contoso.example"),
    ]
    public static let roomsFixture: [String: [Room]] = [
        "rooms-zurich@contoso.example": [
            Room(name: "Room Eiger", emailAddress: "room-eiger@contoso.example", capacity: 8, building: "HQ", floor: "3"),
            Room(name: "Room Pilatus", emailAddress: "room-pilatus@contoso.example", capacity: 4, building: "HQ", floor: "3"),
            Room(name: "Room Säntis", emailAddress: "room-saentis@contoso.example", capacity: 14, building: "HQ", floor: "5"),
        ],
        "rooms-bern@contoso.example": [
            Room(name: "Room Aare", emailAddress: "room-aare@contoso.example", capacity: 6, building: "Bern", floor: "1"),
        ],
    ]
    public static let categoriesFixture: [OutlookCategory] = [
        OutlookCategory(name: "Customer", preset: "preset0"), OutlookCategory(name: "Internal", preset: "preset7"),
        OutlookCategory(name: "Travel", preset: "preset4"), OutlookCategory(name: "Follow-up", preset: "preset3"),
    ]

    static func seedCategories(_ all: [String: CalendarEvent]) -> [String: CalendarEvent] {
        var out = all
        for (id, e) in all {
            if e.subject == "Customer call" { out[id]?.categories = ["Customer"] }
            if e.subject == "Architecture sync" { out[id]?.categories = ["Internal", "Follow-up"] }
        }
        return out
    }

    public func setSources(_ s: [CalendarSource]) {
        lock.withLock { addedSources = s }
        for c in addedCalendars() { seedEvents(for: c) }
    }
    public var sourceProblems: [String: CalendarSourceError] {
        lock.withLock { addedSources }.reduce(into: [:]) { out, s in
            if case .failure(let e) = Self.resolve(s) { out[s.id] = e }
        }
    }

    static func resolve(_ s: CalendarSource) -> Result<[CalendarInfo], CalendarSourceError> {
        switch s {
        case .user(let raw):
            let a = raw.lowercased()
            if a == noAccessAddress { return .failure(.noAccess) }
            guard let name = directory[a] else { return .failure(.notFound) }
            return .success([CalendarInfo(id: "cal-added-\(a)", name: "Calendar", ownerName: name, ownerAddress: a,
                                          mailboxPath: "/users/\(a)", access: .shared, canEdit: false, hexColor: nil)])
        case .group(let id, let name, let mail):
            guard groups.contains(where: { $0.id == id }) else { return .failure(.notFound) }
            return .success([CalendarInfo(id: "cal-\(id)", name: name, ownerName: name, ownerAddress: (mail ?? id).lowercased(),
                                          mailboxPath: "/groups/\(id)", access: .shared, canEdit: true, hexColor: nil)])
        }
    }

    func addedCalendars() -> [CalendarInfo] {
        lock.withLock { addedSources }.flatMap { (try? Self.resolve($0).get()) ?? [] }
    }

    public func probe(source: CalendarSource) async throws -> [CalendarInfo] {
        try await latency()
        return try Self.resolve(source).get()
    }

    public func myGroups() async throws -> [GroupRef] { try await latency(); return Self.groups }

    /// A few synthetic meetings per weekday for an added calendar (deterministic, invented subjects).
    private func seedEvents(for c: CalendarInfo) {
        let cal = Calendar.current
        let week0 = cal.dateInterval(of: .weekOfYear, for: .now)!.start
        let subjects = c.isGroup ? ["Team stand-up", "Campaign review", "Offsite planning"] : ["Site visit", "Budget review", "Hiring panel"]
        lock.withLock {
            guard !events.values.contains(where: { $0.calendarId == c.id }) else { return }
            for w in -4...26 {
                for d in 0..<5 {
                    let day = cal.date(byAdding: .day, value: w * 7 + d, to: week0)!
                    let h = 9 + (abs(w * 5 + d * 3 + c.id.count) % 8)
                    let s = cal.date(bySettingHour: h, minute: (d % 2) * 30, second: 0, of: day)!
                    let id = "\(c.id)-\(w)-\(d)"
                    events[id] = CalendarEvent(id: id, calendarId: c.id, subject: subjects[(w + d + 12) % subjects.count], start: s,
                                               end: s.addingTimeInterval(d == 2 ? 3600 : 1800), location: d == 3 ? "Room Pilatus" : nil,
                                               organizer: c.ownerName, showAs: .busy, changeKey: "ck-1", isOrganizer: c.isGroup)
                }
            }
        }
    }

    public func roomLists() async throws -> [RoomList] { try await latency(); return Self.roomListsFixture }
    public func rooms(inList listAddress: String?) async throws -> [Room] {
        try await latency()
        if let l = listAddress { return Self.roomsFixture[l.lowercased()] ?? [] }
        return Self.roomsFixture.values.flatMap { $0 }.sorted { $0.name < $1.name }
    }
    public func masterCategories() async throws -> [OutlookCategory] { try await latency(); return Self.categoriesFixture }
}
