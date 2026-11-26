import Foundation
import CalendarCore
import MailCore

extension MCPServer {

    func window(_ a: Args, maxDays: Int, tz: TimeZone = .current) throws -> DateInterval {
        guard let from = try a.date("from", tz: tz), let to = try a.date("to", tz: tz) else {
            throw ToolFailure("'from' and 'to' are required.", "error:invalid-args")
        }
        guard to > from else { throw ToolFailure("'to' must be after 'from'.", "error:invalid-args") }
        guard to.timeIntervalSince(from) <= Double(maxDays) * 86400 else {
            throw ToolFailure("The window may span at most \(maxDays) days.", "error:invalid-args")
        }
        return DateInterval(start: from, end: to)
    }

    /// Raw events (ungated) per calendar. Callers MUST gate before returning anything but busy times.
    func rawEvents(_ w: DateInterval, calendars: [CalendarInfo]) async -> (events: [(CalendarEvent, CalendarInfo)], failed: Int) {
        var out: [(CalendarEvent, CalendarInfo)] = [], failed = 0
        for c in calendars {
            guard let batch = try? await backend.calendar.sync(calendar: c, window: w, deltaLink: nil) else { failed += 1; continue }
            for e in batch.upserts where e.end > w.start && e.start < w.end { out.append((e, c)) }
        }
        return (out.sorted { $0.0.start < $1.0.start }, failed)
    }

    func calendarListEvents(_ a: Args) async throws -> ToolOutput {
        let w = try window(a, maxDays: 62)
        var cals = backend.calendars
        if let ids = try a.strings("calendar_ids", maxItems: 50) {
            cals = cals.filter { ids.contains($0.id) }
            if cals.isEmpty { throw ToolFailure("None of those calendar ids is known.", "error:unknown-calendar") }
        }
        let (raw, failed) = await rawEvents(w, calendars: cals)
        var items: [JSON] = [], ids: [String] = [], hidden = 0, meta = 0, capped = 0
        for (e, c) in raw {
            guard let (r, ex) = gate.event(e, access: c.access) else { hidden += 1; continue }
            if items.count >= 200 { capped += 1; continue }
            if ex == .metadata { meta += 1 }
            var o: [String: JSON] = [
                "id": .string(r.id), "calendar_id": .string(c.id), "calendar_name": .string(Untrusted.line(c.name, max: 120)),
                "calendar_access": .string(c.access.rawValue), "start": .date(r.start), "end": .date(r.end),
                "all_day": .bool(r.isAllDay), "show_as": .string(r.showAs.rawValue), "is_cancelled": .bool(r.isCancelled),
                "label": label(r.labelId), "access": .string(ex.rawValue),
                "subject": Untrusted.wrap(Untrusted.line(r.subject), note: Untrusted.eventNote),
            ]
            if let org = r.organizer, !org.isEmpty {
                o["organizer"] = Untrusted.wrap(Untrusted.line(org, max: 200), note: Untrusted.eventNote)
            }
            if ex == .full {
                if let loc = r.location, !loc.isEmpty {
                    o["location"] = Untrusted.wrap(Untrusted.line(loc, max: 300), note: Untrusted.eventNote)
                }
                o["attendees"] = .array(r.attendees.prefix(100).map {
                    ["address": .string(Untrusted.line($0.address, max: 254)), "response": .string(Untrusted.line($0.response, max: 30))]
                })
                if let p = r.bodyPreview, !p.isEmpty {
                    o["preview"] = Untrusted.wrap(Untrusted.body(p, isHTML: false).text, note: Untrusted.eventNote)
                }
                o["has_online_meeting"] = .bool(r.onlineMeetingURL != nil)
            }
            items.append(.object(o)); ids.append(r.id)
        }
        return ToolOutput(payload: [
            "from": .date(w.start), "to": .date(w.end), "events": .array(items),
            "restricted_not_shown": .int(hidden), "notice": restrictedNotice(hidden),
            "not_included_over_limit": .int(capped), "calendars_unavailable": .int(failed),
        ], ids: ids, shown: items.count, restricted: hidden, decision: decision(shown: items.count, meta: meta, hidden: hidden))
    }

    /// Busy blocks only (no subjects): other people via getSchedule; the user's own address via own calendars
    /// (busy times of every own event, including restricted ones — times only, never content).
    func busy(_ addresses: [String], _ w: DateInterval) async -> (busy: [String: [FreeBusySlot]], unavailable: [String]) {
        let mine = Set([backend.me.address.lowercased(), "me"])
        let others = addresses.filter { !mine.contains($0.lowercased()) }
        var out: [String: [FreeBusySlot]] = [:]
        var unavailable: [String] = []
        if !others.isEmpty {
            let fb = (try? await backend.calendar.freeBusy(for: others, window: w)) ?? [:]
            for a in others {
                if let s = fb[a.lowercased()] { out[a.lowercased()] = s.filter { $0.status != .free } } else { unavailable.append(a) }
            }
        }
        if addresses.contains(where: { mine.contains($0.lowercased()) }) {
            let own = backend.calendars.filter { $0.access == .own }
            out[backend.me.address.isEmpty ? "me" : backend.me.address.lowercased()] = await rawEvents(w, calendars: own).events
                .filter { !$0.0.isCancelled && $0.0.showAs != .free }
                .map { FreeBusySlot(start: $0.0.start, end: $0.0.end, status: $0.0.showAs) }
        }
        return (out, unavailable)
    }

    func validated(_ addrs: [String]) throws -> [String] {
        let list = addrs.map { $0.trimmingCharacters(in: .whitespaces) }
        for x in list where !(Self.validAddress(x) || x.lowercased() == "me") {
            throw ToolFailure("Invalid email address in 'addresses'.", "error:invalid-args")
        }
        guard !list.isEmpty else { throw ToolFailure("'addresses' must not be empty.", "error:invalid-args") }
        return list
    }

    func calendarFreeBusy(_ a: Args) async throws -> ToolOutput {
        let addrs = try validated(try a.strings("addresses", maxItems: 20) ?? [])
        let w = try window(a, maxDays: 31)
        let (b, unavailable) = await busy(addrs, w)
        var obj: [String: JSON] = [:]
        for (k, slots) in b {
            obj[k] = .array(slots.map { ["start": .date($0.start), "end": .date($0.end), "status": .string($0.status.rawValue)] })
        }
        return ToolOutput(payload: ["from": .date(w.start), "to": .date(w.end), "busy": .object(obj),
                                    "unavailable": .array(unavailable.map { .string($0) })],
                          shown: b.count, decision: "ok:free-busy")
    }

    func calendarFindFreeSlots(_ a: Args) async throws -> ToolOutput {
        var addrs = try validated(try a.strings("addresses", maxItems: 20) ?? [])
        let duration = try a.int("duration_minutes", range: 5...480)
        let ws = try a.int("work_start_hour", default: 9, range: 0...23)
        let we = try a.int("work_end_hour", default: 17, range: 1...24)
        guard we > ws else { throw ToolFailure("work_end_hour must be after work_start_hour.", "error:invalid-args") }
        let maxResults = try a.int("max_results", default: 10, range: 1...50)
        let includeMe = try a.bool("include_me") ?? true
        let weekends = try a.bool("include_weekends") ?? false
        var tz = TimeZone.current
        if let name = try a.string("time_zone", max: 64) {
            guard let t = TimeZone(identifier: name) else { throw ToolFailure("Unknown time_zone.", "error:invalid-args") }
            tz = t
        }
        let w = try window(a, maxDays: 31, tz: tz)
        let mine = Set([backend.me.address.lowercased(), "me"])
        if includeMe, !addrs.contains(where: { mine.contains($0.lowercased()) }) { addrs.append("me") }
        let (b, unavailable) = await busy(addrs, w)
        let blocking = b.values.flatMap { $0 }.enumerated().map { i, s in
            CalendarEvent(id: "busy-\(i)", calendarId: "busy", subject: "", start: s.start, end: s.end, showAs: s.status)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var slots: [JSON] = []
        var day = cal.startOfDay(for: w.start)
        while day < w.end && slots.count < maxResults {
            let current = day
            day = cal.date(byAdding: .day, value: 1, to: day)!
            if !weekends && cal.isDateInWeekend(current) { continue }
            for (s, e) in FreeTime.gaps(blocking, day: current, from: ws * 60, to: we * 60, minGap: duration, calendar: cal) {
                var start = cal.date(byAdding: .minute, value: s, to: current)!
                let end = min(cal.date(byAdding: .minute, value: e, to: current)!, w.end)
                if start < w.start {   // round the window start up to the next quarter hour
                    start = current.addingTimeInterval((w.start.timeIntervalSince(current) / 900).rounded(.up) * 900)
                }
                guard end.timeIntervalSince(start) >= Double(duration * 60) else { continue }
                slots.append(["start": .date(start), "end": .date(start.addingTimeInterval(Double(duration * 60))),
                              "free_until": .date(end)])
                if slots.count >= maxResults { break }
            }
        }
        return ToolOutput(payload: ["duration_minutes": .int(duration), "time_zone": .string(tz.identifier),
                                    "slots": .array(slots), "unavailable": .array(unavailable.map { .string($0) }),
                                    "note": "Computed from busy times only; no event content was used."],
                          shown: slots.count, decision: "ok:free-slots")
    }
}
