import Foundation
import CryptoKit
import CalendarCore

// CALENDAR: added calendars, group calendars, invite responses, rooms, categories, ICS import, month/agenda maths,
// secondary time zone. Graph paths run against GraphStub (synthetic JSON only).

final class AuthLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, String)] = []
    func add(_ path: String, _ auth: String) { lock.withLock { items.append((path, auth)) } }
    func auth(for prefix: String) -> String? { lock.withLock { items.last { $0.0.hasPrefix(prefix) }?.1 } }
    func paths() -> [String] { lock.withLock { items.map(\.0) } }
    func clear() { lock.withLock { items.removeAll() } }
}

@MainActor
func runCalendarFeatureTests() async {
    let saved = GraphStub.handler
    defer { GraphStub.handler = saved }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [GraphStub.self]
    let session = URLSession(configuration: cfg)
    let log = AuthLog()

    section("Calendar: add by address / group calendars (sources, 403 vs 404, token per scope)")
    check(CalendarSources.address(from: "Lena Fischer <Lena@Contoso.example>") == "lena@contoso.example", "address parsed from \"Name <addr>\"")
    check(CalendarSources.address(from: "not an address") == nil && CalendarSources.address(from: "a@b") == nil, "non-addresses refused")
    let lena = CalendarSource.user(address: "lena@x.example")
    check(CalendarSources.adding(lena, to: [lena]).count == 1, "same source isn't added twice")
    do {
        let store = try mkStore()
        try store.setCalendarSources([lena, .group(id: "g1", name: "Marketing Team", mail: "mkt@x.example")])
        check(store.calendarSources().count == 2, "sources round-trip through the sealed kv")
        let raw = try store.value(for: CalendarSources.storeKey) ?? ""
        check(!raw.contains("lena") && !raw.contains("Marketing"), "sources are sealed at rest (no address / group name in kv)")
    } catch { check(false, "sources store threw \(error)") }

    let groupTokenFails = StubFlag()
    GraphStub.handler = { req in
        let path = req.url!.path, m = req.httpMethod ?? "GET"
        log.add("\(m) \(path)", req.value(forHTTPHeaderField: "Authorization") ?? "")
        switch (m, path) {
        case ("GET", "/v1.0/me"): return (200, #"{"displayName":"You","mail":"you@x.example"}"#)
        case ("GET", "/v1.0/me/calendars"):
            return (200, #"{"value":[{"id":"prim","name":"Calendar","isDefaultCalendar":true,"canEdit":true,"owner":{"name":"You","address":"you@x.example"}}]}"#)
        case ("GET", "/beta/me/security/informationProtection/sensitivityLabels"): return (200, #"{"value":[]}"#)
        case ("GET", "/v1.0/me/calendarView/delta"):
            return (200, #"{"value":[\#(graphEvent("own1", "2026-11-18T09:00:00.0000000", "2026-11-18T10:00:00.0000000", extra: #","categories":["Customer"],"responseStatus":{"response":"notResponded"},"allowNewTimeProposals":true"#))],"@odata.deltaLink":"https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=z"}"#)
        case ("POST", "/v1.0/$batch"): return (200, #"{"responses":[]}"#)
        case ("GET", "/v1.0/users/lena@x.example/calendars"):
            return (200, #"{"value":[{"id":"lena-cal","name":"Calendar","isDefaultCalendar":true,"canEdit":false,"owner":{"name":"Lena Fischer","address":"lena@x.example"}}]}"#)
        case ("GET", "/v1.0/users/lena@x.example/calendars/lena-cal/calendarView"):
            return (200, #"{"value":[\#(graphEvent("lena1", "2026-11-18T11:00:00.0000000", "2026-11-18T12:00:00.0000000"))]}"#)
        case ("GET", "/v1.0/users/onlydefault@x.example/calendars"): return (403, #"{"error":{"code":"ErrorAccessDenied"}}"#)
        case ("GET", "/v1.0/users/onlydefault@x.example/calendar"):
            return (200, #"{"id":"od-cal","name":"Calendar","canEdit":false,"owner":{"name":"Only Default","address":"onlydefault@x.example"}}"#)
        case ("GET", "/v1.0/users/onlydefault@x.example/calendars/od-cal/calendarView"): return (200, #"{"value":[]}"#)
        case ("GET", "/v1.0/users/private@x.example/calendars"), ("GET", "/v1.0/users/private@x.example/calendar"):
            return (403, #"{"error":{"code":"ErrorAccessDenied"}}"#)
        case ("GET", "/v1.0/users/ghost@x.example/calendars"): return (404, #"{"error":{"code":"ErrorItemNotFound"}}"#)
        case ("GET", "/v1.0/groups/g1/calendar"): return (200, #"{"id":"g1-cal","name":"Calendar"}"#)
        case ("GET", "/v1.0/groups/g1/calendarView"):
            return (200, #"{"value":[\#(graphEvent("g1e", "2026-11-19T09:00:00.0000000", "2026-11-19T10:00:00.0000000"))]}"#)
        case ("POST", "/v1.0/groups/g1/calendar/events"):
            return (201, graphEvent("g1new", "2026-11-20T09:00:00.0000000", "2026-11-20T09:30:00.0000000"))
        case ("PATCH", "/v1.0/groups/g1/events/g1e"):
            return (200, graphEvent("g1e", "2026-11-19T10:00:00.0000000", "2026-11-19T11:00:00.0000000"))
        case ("GET", "/v1.0/me/memberOf/microsoft.graph.group"):
            return (200, #"{"value":[{"id":"g2","displayName":"Zeta"},{"id":"g1","displayName":"Marketing Team","mail":"mkt@x.example"}]}"#)
        case ("POST", "/v1.0/me/calendars/prim/events/own1/tentativelyAccept"), ("POST", "/v1.0/me/calendars/prim/events/own1/accept"):
            return (202, "")
        case ("POST", "/v1.0/me/events/inv1/accept"): return (202, "")
        case ("POST", "/v1.0/me/events/inv2/tentativelyAccept"):
            return (400, #"{"error":{"code":"ErrorProposeNewTimeNotAllowed"}}"#)
        case ("GET", "/v1.0/places/microsoft.graph.roomlist"):
            return (200, #"{"value":[{"displayName":"HQ","emailAddress":"hq-rooms@x.example"}]}"#)
        case ("GET", "/v1.0/places/hq-rooms@x.example/microsoft.graph.roomlist/rooms"):
            return (200, #"{"value":[{"displayName":"Room B","emailAddress":"b@x.example","capacity":4},{"displayName":"Room A","emailAddress":"a@x.example","capacity":10,"building":"HQ"}]}"#)
        case ("GET", "/v1.0/me/outlook/masterCategories"):
            return (200, #"{"value":[{"displayName":"Customer","color":"preset0"},{"displayName":"Plain","color":"none"}]}"#)
        default: return (404, #"{"error":{"code":"unexpected \#(path)"}}"#)
        }
    }
    let scoped: GraphCalendarService.ScopedTokenProvider = { scope in
        switch scope {
        case .calendar: return "tok-cal"
        case .groupMembership: return "tok-mem"
        case .groupCalendar:
            if groupTokenFails.value { throw NSError(domain: "MSALErrorDomain", code: -50002) }
            return "tok-grp"
        case .places: return "tok-place"
        case .mailboxSettings: return "tok-mbx"
        }
    }
    let svc = GraphCalendarService(token: { "unused" }, session: session, scopedToken: scoped)

    // Probe: 403 and 404 stay distinct; default-only share falls back to /calendar.
    do { _ = try await svc.probe(source: .user(address: "ghost@x.example")); check(false, "404 probe should throw") }
    catch { check(error as? CalendarSourceError == .notFound, "404 → notFound (\(error))") }
    do { _ = try await svc.probe(source: .user(address: "private@x.example")); check(false, "403 probe should throw") }
    catch { check(error as? CalendarSourceError == .noAccess, "403 → noAccess, not notFound (\(error))") }
    let od = try? await svc.probe(source: .user(address: "onlydefault@x.example"))
    check(od?.first?.id == "od-cal" && od?.first?.isDefault == false, "listing refused (403) → default calendar via GET /users/{addr}/calendar")
    let groups = (try? await svc.myGroups()) ?? []
    check(groups.map(\.name) == ["Marketing Team", "Zeta"] && log.auth(for: "GET /v1.0/me/memberOf") == "Bearer tok-mem",
          "my groups listed with the membership token, sorted")

    do {
        let store = try mkStore()
        svc.setSources([lena, .group(id: "g1", name: "Marketing Team", mail: "mkt@x.example"), .user(address: "ghost@x.example")])
        let sync = SyncEngine(service: svc, store: store, compliance: CachedLabelPolicyEngine(), onChange: { _ in })
        log.clear()
        await sync.syncNow()
        let st = await sync.status
        check({ if case .idle = st { return true }; return false }(), "sync with added calendars completes (\(st))")
        let cals = try store.calendars()
        let lenaCal = cals.first { $0.id == "lena-cal" }, grp = cals.first { $0.isGroup }
        check(lenaCal?.access == .shared && lenaCal?.isDefault == false && lenaCal?.mailboxPath == "/users/lena@x.example",
              "address calendar: shared, snapshot path (not delta)")
        check(grp?.groupId == "g1" && grp?.canEdit == true && grp?.name == "Marketing Team", "group calendar listed (writable, named after the group)")
        check(try store.event(id: "lena1") != nil && store.event(id: "g1e") != nil, "events of added + group calendars cached")
        check(log.paths().contains("GET /v1.0/groups/g1/calendarView"), "group events read from /groups/{id}/calendarView")
        check(log.auth(for: "GET /v1.0/groups/g1") == "Bearer tok-grp" && log.auth(for: "GET /v1.0/me/calendars") == "Bearer tok-cal",
              "group requests use the group token; calendar requests keep the calendar token")
        check(!log.paths().contains { $0.contains("lena") && $0.contains("delta") }, "no delta on added calendars")
        check(svc.sourceProblems["user:ghost@x.example"] == .notFound && svc.sourceProblems[lena.id] == nil,
              "a missing source is reported per source, others unaffected")
        let own = try store.event(id: "own1")
        check(own?.categories == ["Customer"] && own?.myResponse == "notResponded" && own?.allowNewTimeProposals == true,
              "categories, responseStatus and allowNewTimeProposals decoded")

        // Group token needs consent: own calendar still syncs, group keeps its cache, status healthy.
        groupTokenFails.value = true
        await sync.syncNow()
        let st2 = await sync.status
        check({ if case .idle = st2 { return true }; return false }(), "group token failing → sync still idle (\(st2))")
        check(try store.event(id: "g1e") != nil && store.event(id: "own1") != nil, "group cache kept, own calendar synced")
        check(await sync.calendarIssues[grp?.id ?? ""] != nil, "per-calendar issue recorded for the group calendar")
        groupTokenFails.value = false

        // Group writes: create → /groups/{id}/calendar/events, update → /groups/{id}/events/{id}.
        if let grp {
            let body = try JSONSerialization.data(withJSONObject: ["subject": "x"])
            let created = try await svc.create(calendar: grp, body: body)
            check(created.id == "g1new" && log.auth(for: "POST /v1.0/groups/g1/calendar/events") == "Bearer tok-grp",
                  "group create → POST /groups/{id}/calendar/events with the group token")
            _ = try await svc.update(calendar: grp, eventId: "g1e", patch: body, ifMatch: nil)
            check(log.paths().contains("PATCH /v1.0/groups/g1/events/g1e"), "group update → PATCH /groups/{id}/events/{id}")
        }

    } catch { check(false, "sources sync threw \(error)") }

    section("Calendar: rooms + categories")
    do {
        let lists = try await svc.roomLists()
        let rooms = try await svc.rooms(inList: lists.first?.emailAddress)
        check(lists.map(\.emailAddress) == ["hq-rooms@x.example"] && rooms.map(\.name) == ["Room A", "Room B"] && rooms.first?.capacity == 10,
              "room lists + rooms (by list email, sorted, capacity)")
        check(log.auth(for: "GET /v1.0/places") == "Bearer tok-place", "places use the Place.Read.All token")
        let cats = try await svc.masterCategories()
        check(cats.first?.hex == "#E7484F" && cats.last?.hex == nil && log.auth(for: "GET /v1.0/me/outlook") == "Bearer tok-mbx",
              "master categories with preset colours (mailbox-settings token)")
    } catch { check(false, "rooms/categories threw \(error)") }
    check(OutlookCategory.lookup("customer", in: [OutlookCategory(name: "Customer", preset: "preset0")]) != nil, "category lookup is case-insensitive")
    var d = EventDraft(calendarId: "c", subject: "s", start: t0, end: t0.addingTimeInterval(1800))
    var d2 = d
    d2.location = "Room A"; d2.locationEmail = "a@x.example"
    d2.attendees = [Attendee(name: "Room A", address: "a@x.example", response: "none", type: "resource")]
    d2.categories = ["Customer"]
    let j = d2.graphJSON(changedFrom: d)
    let loc = j["location"] as? [String: Any], att = (j["attendees"] as? [[String: Any]])?.first
    check(loc?["locationEmailAddress"] as? String == "a@x.example" && loc?["locationType"] as? String == "conferenceRoom",
          "room → location with locationEmailAddress")
    check(att?["type"] as? String == "resource" && j["categories"] as? [String] == ["Customer"], "room attendee is a resource; categories sent")
    let back = EventDraft.apply(json: j, to: CalendarEvent(id: "x", calendarId: "c", subject: "", start: t0, end: t0))
    check(back.attendees.first?.isResource == true && back.categories == ["Customer"], "resource type + categories survive apply(json:)")
    d = EventDraft(back)
    check(Set(d.graphJSON(changedFrom: EventDraft(back)).keys).isEmpty, "unchanged draft → empty PATCH (no resource re-sent as required)")
    var redacted = back; redacted.categories = ["Secret project"]
    let pol = CachedLabelPolicyEngine().policy(labelId: nil, isPrivate: true, access: .shared)
    check(pol.redactDetails && SyncEngine.sanitizeForCache(redacted, policy: pol).categories == nil, "private item on a shared calendar: categories not cached")

    section("Calendar: ICS import")
    let ics = """
    BEGIN:VCALENDAR\r
    BEGIN:VEVENT\r
    UID:one@x\r
    SUMMARY:Board prep\\, round two\r
    DTSTART;TZID=Europe/Zurich:20261202T093000\r
    DTEND;TZID=Europe/Zurich:20261202T103000\r
    LOCATION:Room Eiger\r
    DESCRIPTION:Line one\\nLine two that is folded\r
      and continues\r
    ATTENDEE;CN=Someone:mailto:someone@x.example\r
    RRULE:FREQ=WEEKLY\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    SUMMARY:Holiday\r
    DTSTART;VALUE=DATE:20261224\r
    DTEND;VALUE=DATE:20261226\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    SUMMARY:Quick call\r
    DTSTART:20261203T140000Z\r
    DURATION:PT45M\r
    RRULE:FREQ=WEEKLY;COUNT=3\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    SUMMARY:Gone\r
    STATUS:CANCELLED\r
    DTSTART:20261203T140000Z\r
    END:VEVENT\r
    END:VCALENDAR\r
    """
    let parsed = ICSParser.parse(ics)
    check(parsed.count == 3, "three events (cancelled skipped) — got \(parsed.count)")
    if parsed.count == 3 {
        let a = parsed[0], h = parsed[1], q = parsed[2]
        var zc = Calendar(identifier: .gregorian); zc.timeZone = TimeZone(identifier: "Europe/Zurich")!
        check(a.summary == "Board prep, round two" && zc.component(.hour, from: a.start) == 9 && a.end.timeIntervalSince(a.start) == 3600,
              "TZID times + text unescaping")
        check(a.notes == "Line one\nLine two that is folded and continues", "line unfolding + \\n")
        check(a.repeats == .weekly && a.attendeeCount == 1, "simple RRULE mapped; attendees counted")
        check(a.draft(calendarId: "c").attendees.isEmpty, "imported drafts never carry attendees (no invitations sent)")
        check(h.isAllDay && h.end.timeIntervalSince(h.start) > 86400, "all-day VALUE=DATE, two days")
        check(q.end.timeIntervalSince(q.start) == 2700 && q.repeats == .never && q.recurrenceDropped, "DURATION; RRULE with COUNT → first occurrence only, flagged")
    }

    section("Calendar: month / agenda / secondary zone")
    var gc = Calendar(identifier: .gregorian); gc.timeZone = TimeZone(identifier: "Europe/Zurich")!; gc.firstWeekday = 2
    let nov = gc.date(from: DateComponents(year: 2026, month: 11, day: 18))!
    let grid = CalendarRanges.monthGrid(containing: nov, calendar: gc)
    let first = gc.date(from: DateComponents(year: 2026, month: 11, day: 1))!
    check(grid.count == 42 && gc.component(.weekday, from: grid[0]) == 2 && grid.contains(first) && grid[0] <= first,
          "month grid: 42 days from the Monday of the week holding the 1st")
    let iv = CalendarRanges.monthGridInterval(containing: nov, calendar: gc)
    check(iv.duration >= 41 * 86400 && iv.start == grid[0], "month interval covers the grid")
    let d18 = gc.date(bySettingHour: 9, minute: 0, second: 0, of: nov)!
    let evs = [CalendarEvent(id: "m", calendarId: "c", subject: "multi", start: d18, end: d18.addingTimeInterval(86400 * 2)),
               CalendarEvent(id: "x", calendarId: "c", subject: "cx", start: d18, end: d18.addingTimeInterval(600), isCancelled: true),
               CalendarEvent(id: "ad", calendarId: "c", subject: "allday", start: gc.startOfDay(for: d18), end: gc.startOfDay(for: d18).addingTimeInterval(86400), isAllDay: true)]
    let on18 = CalendarRanges.events(on: nov, in: evs, calendar: gc)
    check(on18.map(\.id) == ["ad", "m"], "day events: all-day first, cancelled hidden")
    let secs = CalendarRanges.agendaSections(evs, interval: CalendarRanges.agendaInterval(from: nov, days: 7, calendar: gc), calendar: gc)
    check(secs.count == 3 && secs[0].events.count == 2, "agenda: one section per day with events; multi-day repeats")
    let c5 = CalendarRanges.chips(Array(repeating: evs[0], count: 5), capacity: 3)
    check(c5.shown.count == 2 && c5.more == 3, "month cell: 2 chips + \"+3 more\"")
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    check(SecondaryZone.label(hour: 9, day: nov, zone: tokyo, calendar: gc) == "17:00", "09:00 Zürich (CET) = 17:00 Tokyo")
    check(SecondaryZone.label(hour: 9, day: nov, zone: TimeZone(identifier: "Asia/Kolkata")!, calendar: gc) == "13:30", "half-hour zone label")
    check(SecondaryZone.shortName(TimeZone(identifier: "UTC")!) == "UTC" || SecondaryZone.shortName(TimeZone(identifier: "UTC")!) == "GMT", "zone short name")
}

final class StubFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _v = false
    var value: Bool { get { lock.withLock { _v } } set { lock.withLock { _v = newValue } } }
}
