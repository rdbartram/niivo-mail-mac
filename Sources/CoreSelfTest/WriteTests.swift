import Foundation
import CalendarCore

@MainActor
func runWriteTests() async {
    section("Write path: create / edit / delete (offline-first)")
    do {
        let t0 = Date()
        let svc = FixtureCalendarService(anchor: t0, eventsPerCalendarPerWeek: 3, weeks: 0...0)
        let store = try mkStore()
        let sync = SyncEngine(service: svc, store: store, compliance: CachedLabelPolicyEngine(), onChange: { _ in })
        await sync.syncNow()
        let start = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: t0)!
        let ids: Set<String> = ["cal-me"]
        func find(_ subject: String) throws -> CalendarEvent? {
            try store.events(from: start.addingTimeInterval(-86400), to: start.addingTimeInterval(86400 * 2), calendarIds: ids)
                .first { $0.subject == subject }
        }

        // JSON: PATCH carries only what changed and never the body.
        var d = EventDraft(calendarId: "cal-me", subject: "Spike: create", start: start, end: start.addingTimeInterval(1800),
                           notes: "hello")
        let full = d.graphJSON()
        check(full["subject"] as? String == "Spike: create" && full["body"] != nil, "POST body has subject + notes")
        var d2 = d; d2.location = "Room Eiger"
        let patch = d2.graphJSON(changedFrom: d)
        check(Set(patch.keys) == ["location"], "PATCH body only has changed keys (\(patch.keys.sorted()))")

        // Offline create → visible at once with a local id; edit before it syncs rewrites the queued POST.
        svc.simulateOffline = true
        let localId = try await sync.create(d)
        try await Task.sleep(for: .milliseconds(30))
        let shown = try find("Spike: create")
        check(localId.hasPrefix("local-") && shown?.pendingSync == true, "offline create shown optimistically")
        d.subject = "Spike: create (edited offline)"
        try await sync.edit(eventId: localId, to: d)
        check(try await sync.pendingCount() == 1, "edit of a pending create folds into the one queued POST")
        await sync.syncNow()                          // still offline: nothing lost, local copy survives
        check(try find("Spike: create (edited offline)") != nil, "pending create survives an offline sync")
        svc.simulateOffline = false
        await sync.syncNow()
        let created = try find("Spike: create (edited offline)")
        check(created != nil && created?.id.hasPrefix("fx-") == true && created?.pendingSync == false,
              "POST on reconnect: server id assigned (\(created?.id ?? "nil"))")
        check(await sync.remappedIds[localId] == created?.id, "local → server id remap reported for selection")
        check(try store.event(id: localId) == nil, "no duplicate left under the local id")

        // Two different-field edits offline merge into one PATCH with both.
        let c = created!
        svc.simulateOffline = true
        var e1 = EventDraft(c); e1.location = "Room Matterhorn"
        try await sync.edit(eventId: c.id, to: e1)
        try await sync.move(eventId: c.id, to: c.start.addingTimeInterval(3600), end: c.end.addingTimeInterval(3600))
        check(try await sync.pendingCount() == 1, "location edit + move coalesce into one PATCH")
        svc.simulateOffline = false
        await sync.syncNow()
        let after = try store.event(id: c.id)
        check(after?.location == "Room Matterhorn" && after?.start == c.start.addingTimeInterval(3600),
              "both changes reached the server (merge, not last-write-wins on the body)")

        // Delete a pending create: never reaches Exchange.
        svc.simulateOffline = true
        let tmp = try await sync.create(EventDraft(calendarId: "cal-me", subject: "Spike: never sent", start: start, end: start.addingTimeInterval(900)))
        try await sync.remove(eventId: tmp, mode: .delete)
        let pc = try await sync.pendingCount(); let gone = try find("Spike: never sent")
        check(pc == 0 && gone == nil, "deleting an unsent create just drops it")
        svc.simulateOffline = false

        // Delete an existing event; it must not come back on the next sync.
        try await sync.remove(eventId: c.id, mode: .delete)
        check(try store.event(id: c.id) == nil, "delete is immediate locally")
        await sync.syncNow()
        await sync.syncNow()
        let pc2 = try await sync.pendingCount(); let back = try store.event(id: c.id)
        check(back == nil && pc2 == 0, "delete reached the server; sync doesn't resurrect it")

        // Delete with a stale changeKey → server wins (organiser changed it), item returns.
        let victim = try store.events(from: start.addingTimeInterval(-86400 * 7), to: start.addingTimeInterval(86400 * 7), calendarIds: ids)
            .first { !$0.isAllDay }!
        svc.simulateOffline = true
        try await sync.remove(eventId: victim.id, mode: .delete)
        svc.serverSideEdit(eventId: victim.id)
        svc.simulateOffline = false
        await sync.syncNow()
        let restored = try store.event(id: victim.id)
        check(await sync.conflicts.contains(victim.id) && restored != nil,
              "delete of a meanwhile-changed item → conflict, server copy restored")

        // Recurring series.
        let w = SyncEngine.syncWindow()
        func series() throws -> [CalendarEvent] {
            try store.events(from: w.start, to: w.end, calendarIds: ids).filter { $0.seriesMasterId == "series-cal-me" }
        }
        let occ = try series()
        check(occ.count >= 1, "fixture series occurrences synced (\(occ.count)), carry seriesMasterId")
        if let o = occ.first {
            var sd = EventDraft(o); sd.start = o.start.addingTimeInterval(1800); sd.end = o.end.addingTimeInterval(1800); sd.location = "Room Matterhorn"
            try await sync.editSeries(occurrenceId: o.id, to: sd)
            let after = try series()
            check(!after.isEmpty && after.allSatisfy { $0.location == "Room Matterhorn" && Calendar.current.component(.minute, from: $0.start) == 30 },
                  "series edit: every occurrence moved 30 min and got the new location")
            var bad = EventDraft(o); bad.start = o.start.addingTimeInterval(86400); bad.end = o.end.addingTimeInterval(86400)
            var refused = false
            do { try await sync.editSeries(occurrenceId: after[0].id, to: bad) } catch SyncEngine.SeriesError.changesDay { refused = true }
            check(refused, "moving a whole series to another day is refused (pattern change → Outlook)")
            try await sync.removeSeries(occurrenceId: after[0].id, mode: .cancel, comment: "spike")
            check(try series().isEmpty, "series cancel removes every occurrence")
        }
        var rd = EventDraft(calendarId: "cal-me", subject: "Spike: daily", start: start.addingTimeInterval(3600 * 3),
                            end: start.addingTimeInterval(3600 * 3 + 900))
        rd.repeats = .daily
        let rj = rd.graphJSON()
        let pat = (rj["recurrence"] as? [String: Any])?["pattern"] as? [String: Any]
        check(pat?["type"] as? String == "daily", "new repeating event → patternedRecurrence in POST")
        _ = try await sync.create(rd)
        var daily: [CalendarEvent] = []
        for _ in 0..<40 {   // kick → POST → resync runs in the background (fixture latency 120 ms/call)
            try await Task.sleep(for: .milliseconds(100))
            daily = try store.events(from: w.start, to: w.end, calendarIds: ids).filter { $0.subject == "Spike: daily" }
            if daily.count > 1 { break }
        }
        check(daily.count > 1 && daily.allSatisfy { $0.seriesMasterId != nil && !$0.id.hasPrefix("local-") },
              "repeating create: master not cached, occurrences arrive by sync (\(daily.count))")
    } catch { failures += 1; print("  ✗ write path threw \(error)") }
}
