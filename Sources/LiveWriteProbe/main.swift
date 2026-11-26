import Foundation
import CalendarCore

// Real-tenant write probe. Creates "[Spike test]" items in the signed-in user's DEFAULT calendar only, no
// attendees (no mail goes out), verifies each write path, and deletes everything it created at the end.
// Prints ids/status only. Usage: CC_TOKEN_FILE=… swift run LiveWriteProbe
let tokenPath = ProcessInfo.processInfo.environment["CC_TOKEN_FILE"] ?? ""
guard let token = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
else { print("set CC_TOKEN_FILE"); exit(2) }
let svc = GraphCalendarService(token: { token })
var created: [String] = []
var ok = 0, bad = 0
@MainActor func report(_ pass: Bool, _ msg: String) { print(pass ? "  ✓ \(msg)" : "  ✗ \(msg)"); if pass { ok += 1 } else { bad += 1 } }
func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }

let cals = try await svc.listCalendars()
guard let cal = cals.first(where: { $0.isDefault }) else { print("no default calendar"); exit(1) }
print("default calendar found (own=\(cal.access == .own), canEdit=\(cal.canEdit))")
let c = Calendar.current
let base = c.date(bySettingHour: 7, minute: 0, second: 0, of: c.date(byAdding: .day, value: 1, to: .now)!)!

do {
    // 1. Create a plain appointment.
    let d = EventDraft(calendarId: cal.id, subject: "[Spike test] create", start: base, end: base.addingTimeInterval(1800),
                       location: "Spike room", notes: "Created by the Compliant Calendar spike. Safe to delete.")
    let e1 = try await svc.create(calendar: cal, body: json(d.graphJSON()))
    created.append(e1.id)
    report(abs(e1.start.timeIntervalSince(base)) < 1 && e1.location == "Spike room" && e1.changeKey != nil,
           "POST appointment: times round-trip in UTC, location kept, changeKey returned")
    report(e1.isOrganizer == true, "isOrganizer decoded (\(String(describing: e1.isOrganizer)))")

    // 2. PATCH only changed keys, with If-Match.
    var d2 = d; d2.start = base.addingTimeInterval(3600); d2.end = base.addingTimeInterval(5400); d2.location = "Spike room 2"
    // Exchange may bump the changeKey shortly after a create (calendar assistant processing): read it back first.
    let e1b = try await svc.fetch(calendar: cal, eventId: e1.id)
    print("  · changeKey changed after create: \(e1b.changeKey != e1.changeKey)")
    let e2 = try await svc.update(calendar: cal, eventId: e1.id, patch: json(d2.graphJSON(changedFrom: d)), ifMatch: e1b.changeKey)
    report(abs(e2.start.timeIntervalSince(d2.start)) < 1 && e2.location == "Spike room 2" && e2.changeKey != e1.changeKey,
           "PATCH move + location with If-Match: accepted, new changeKey")

    // 3. Stale If-Match must be refused (otherwise offline edits could silently clobber server changes).
    do {
        _ = try await svc.update(calendar: cal, eventId: e1.id, patch: json(["location": ["displayName": "stale"]]), ifMatch: e1b.changeKey)
        report(false, "stale If-Match was ACCEPTED — weak ETag from changeKey not enforced")
    } catch ServiceError.conflict {
        report(true, "stale If-Match → 412 conflict (weak ETag from changeKey works)")
    } catch { report(false, "stale If-Match → unexpected \(error)") }

    // 4. Teams meeting creation (no attendees → no mail).
    var d3 = EventDraft(calendarId: cal.id, subject: "[Spike test] Teams", start: base.addingTimeInterval(7200), end: base.addingTimeInterval(9000))
    d3.isOnlineMeeting = true
    let e3 = try await svc.create(calendar: cal, body: json(d3.graphJSON()))
    created.append(e3.id)
    report(e3.onlineMeetingURL.map { MeetingProvider(url: $0) == .teams } == true, "isOnlineMeeting=true → Teams join link generated")

    // 5. All-day with an IANA time zone.
    let day = c.startOfDay(for: base)
    let d4 = EventDraft(calendarId: cal.id, subject: "[Spike test] all-day", start: day, end: c.date(byAdding: .day, value: 1, to: day)!,
                        isAllDay: true, showAs: .free)
    let e4 = try await svc.create(calendar: cal, body: json(d4.graphJSON()))
    created.append(e4.id)
    report(e4.isAllDay && c.isDate(e4.start, inSameDayAs: day), "all-day with IANA zone \(TimeZone.current.identifier) accepted, lands on the right day")

    // 6. Private flag.
    let e5 = try await svc.update(calendar: cal, eventId: e4.id, patch: json(["sensitivity": "private"]), ifMatch: e4.changeKey)
    report(e5.legacySensitivity == .private, "PATCH sensitivity=private")

    // 7. DELETE with stale If-Match, then with the current one.
    do {
        try await svc.remove(calendar: cal, eventId: e1.id, mode: .delete, comment: nil, ifMatch: e1b.changeKey)
        report(false, "DELETE with stale changeKey was accepted")
        created.removeAll { $0 == e1.id }
    } catch ServiceError.conflict {
        report(true, "DELETE with stale changeKey → conflict (client-side check; Exchange ignores If-Match on DELETE)")
    } catch { report(false, "DELETE stale → unexpected \(error)") }
    if created.contains(e1.id) {
        try await svc.remove(calendar: cal, eventId: e1.id, mode: .delete, comment: nil, ifMatch: e2.changeKey)
        created.removeAll { $0 == e1.id }
        report(true, "DELETE with current If-Match → removed")
    }
    // 8. Deleting something already gone is treated as done (offline queue replay).
    do { try await svc.remove(calendar: cal, eventId: e1.id, mode: .delete, comment: nil, ifMatch: nil); report(true, "DELETE of an already-deleted item tolerated (404 → done)") }
    catch { report(false, "DELETE of gone item threw \(error)") }
    // 9. Repeating event: POST with patternedRecurrence returns the series master.
    var d6 = EventDraft(calendarId: cal.id, subject: "[Spike test] daily", start: base.addingTimeInterval(-3600), end: base.addingTimeInterval(-2700))
    d6.repeats = .weekdays
    let m6 = try await svc.create(calendar: cal, body: json(d6.graphJSON()))
    created.append(m6.id)
    let fetched = try await svc.fetch(calendar: cal, eventId: m6.id)
    report(fetched.id == m6.id && fetched.seriesMasterId == nil, "repeating create → series master returned and fetchable")
    let m7 = try await svc.update(calendar: cal, eventId: m6.id, patch: json(["location": ["displayName": "Series room"]]), ifMatch: fetched.changeKey)
    report(m7.location == "Series room", "PATCH on the series master (all occurrences) with If-Match")
    try await svc.remove(calendar: cal, eventId: m6.id, mode: .delete, comment: nil, ifMatch: nil)
    created.removeAll { $0 == m6.id }
    report(true, "DELETE series master → whole series removed")
} catch { report(false, "probe threw \(error)") }

// Cleanup: everything we created.
for id in created {
    do { try await svc.remove(calendar: cal, eventId: id, mode: .delete, comment: nil, ifMatch: nil); print("  cleanup: deleted 1 test item") }
    catch { print("  cleanup FAILED for one item: \(error) — delete '[Spike test]' items manually") }
}
print("\n\(ok) passed, \(bad) failed")
exit(bad == 0 ? 0 : 1)
