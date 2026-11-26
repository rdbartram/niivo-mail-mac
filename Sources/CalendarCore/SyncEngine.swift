import Foundation

/// The only component that talks to the network. The UI never awaits it to render — it renders the store,
/// and the engine posts `onChange` whenever the store moved.
public actor SyncEngine {
    public enum Status: Sendable, Equatable {
        case idle(lastSync: Date?)
        case syncing
        case offline(lastSync: Date?)
        case error(String)
    }

    private let service: CalendarService
    private let store: LocalStore
    private let compliance: CachedLabelPolicyEngine
    private let onChange: @Sendable (Status) -> Void
    public private(set) var status: Status = .idle(lastSync: nil)
    public private(set) var conflicts: [String] = []

    public init(service: CalendarService, store: LocalStore, compliance: CachedLabelPolicyEngine,
                onChange: @escaping @Sendable (Status) -> Void) {
        self.service = service; self.store = store; self.compliance = compliance; self.onChange = onChange
        // Label policy is usable offline from the last sync.
        if let labels = try? store.labels(), !labels.isEmpty {
            compliance.update(labels: labels, synced: true)
        }
    }

    /// Rolling window synced to the device. Anchored to the month so delta tokens stay valid all month.
    public static func syncWindow(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let month = calendar.dateInterval(of: .month, for: now)!.start
        let start = calendar.date(byAdding: .month, value: -1, to: month)!
        let end = calendar.date(byAdding: .month, value: 7, to: month)!
        return DateInterval(start: start, end: end)
    }

    private func set(_ s: Status) { status = s; onChange(s) }

    private var lastSync: Date? {
        (try? store.value(for: "lastSync")).flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:))
    }

    // MARK: Full pass

    /// Why the last label-policy fetch failed (nil when it succeeded). Calendar sync continues regardless.
    public private(set) var labelSyncIssue: String?

    public func syncNow() async {
        set(.syncing)
        do {
            try await flushOutbox()
            // Labels first: events are sanitised for the cache using the current policy.
            // Non-fatal: VERIFIED against a test tenant, the label list can 403/404 for a normal user
            // (no labels published to them, or licensing). The calendar must still sync; labelled items then
            // stay fail-closed because their IDs are unknown. Keep the last good label set if we had one.
            do {
                let labels = try await service.sensitivityLabels()
                try store.replace(labels: labels)
                compliance.update(labels: labels, synced: true)
                labelSyncIssue = nil
            } catch ServiceError.offline {
                throw ServiceError.offline
            } catch {
                compliance.update(labels: (try? store.labels()) ?? [], synced: false)
                labelSyncIssue = String(describing: error)
            }

            let calendars = try await service.listCalendars()
            try store.upsert(calendars: calendars)

            let window = Self.syncWindow()
            var issues: [String: String] = [:]
            try await withThrowingTaskGroup(of: (CalendarInfo, SyncBatch?, String?).self) { group in
                for cal in calendars {
                    let link = try store.value(for: deltaKey(cal, window))
                    group.addTask { [service] in
                        do {
                            do { return (cal, try await service.sync(calendar: cal, window: window, deltaLink: link), nil) }
                            catch ServiceError.syncStateInvalid {
                                return (cal, try await service.sync(calendar: cal, window: window, deltaLink: nil), nil)
                            }
                        } catch ServiceError.offline {
                            throw ServiceError.offline
                        } catch where Self.isolatesFailures(cal) {
                            // Shared-by-address / group calendars: one refused calendar (revoked share, group token
                            // needing consent) keeps its cache and doesn't fail the whole round.
                            return (cal, nil, String(describing: CalendarSourceError(error)))
                        }
                    }
                }
                for try await (cal, batch, issue) in group {
                    if let batch { try apply(batch, to: cal, window: window) }
                    if let issue { issues[cal.id] = issue }
                    onChange(.syncing) // progressive paint: each calendar shows up as it lands
                }
            }
            calendarIssues = issues
            // Drop calendars that disappeared (unshared, delegation revoked) — and their cached data.
            let live = Set(calendars.map(\.id))
            for stale in try knownCalendarIds().subtracting(live) { try store.deleteEvents(calendarId: stale) }
            try store.setValue(live.sorted().joined(separator: ","), for: "knownCalendars")
            try store.setValue(String(Date.now.timeIntervalSince1970), for: "lastSync")
            set(.idle(lastSync: .now))
        } catch ServiceError.offline {
            set(.offline(lastSync: lastSync))
        } catch {
            set(.error(String(describing: error)))
        }
    }

    /// Per-calendar sync problems from the last round (calendar id → reason). Shared / group calendars only.
    public private(set) var calendarIssues: [String: String] = [:]

    /// Own and delegated calendars fail the round as before (a broken primary must be loud); shared and group
    /// calendars are isolated.
    static func isolatesFailures(_ cal: CalendarInfo) -> Bool { cal.access == .shared || cal.isGroup }

    private func knownCalendarIds() throws -> Set<String> {
        Set(try store.value(for: "knownCalendars")?.split(separator: ",").map(String.init) ?? [])
    }

    private func deltaKey(_ cal: CalendarInfo, _ w: DateInterval) -> String {
        "delta:\(cal.id):\(Int(w.start.timeIntervalSince1970))"
    }

    func apply(_ batch: SyncBatch, to cal: CalendarInfo, window: DateInterval) throws {
        let ctx = ComplianceContext(calendarAccess: cal.access)
        // Local intent wins until Exchange acknowledges it: don't let a sync overwrite a pending edit, drop a
        // not-yet-POSTed create (replaceWindow), or resurrect something we deleted.
        let queue = try store.outbox()
        let deleted = Set(queue.filter { $0.kind == .delete }.map(\.eventId))
        let edited = Set(queue.filter { $0.kind == .update }.map(\.eventId))
        let keep = try queue.filter { $0.kind != .delete && $0.calendarId == cal.id }.compactMap { try store.event(id: $0.eventId) }
        let cleaned = batch.upserts
            .filter { !deleted.contains($0.id) && !edited.contains($0.id) }
            .map { Self.sanitizeForCache($0, policy: compliance.policy(for: $0, context: ctx)) }
        defer {
            try? store.upsert(events: keep)
            try? store.deleteEvents(ids: Array(deleted))
        }
        switch batch.mode {
        case .delta:
            try store.upsert(events: cleaned)
            try store.deleteEvents(ids: batch.removedIds)
            try store.setValue(batch.deltaLink, for: deltaKey(cal, window))
        case .replaceWindow:
            try store.replaceEvents(calendarId: cal.id, window: window, with: cleaned)
        }
        var known = try knownCalendarIds(); known.insert(cal.id)
        try store.setValue(known.sorted().joined(separator: ","), for: "knownCalendars")
    }

    /// Enforce "may this be stored offline" BEFORE it touches disk. Encrypted-at-rest is not enough for
    /// protected content: a label that forbids offline access must mean the bytes never land.
    public static func sanitizeForCache(_ e: CalendarEvent, policy: ContentPolicy) -> CalendarEvent {
        var e = e
        if !policy.allowOfflineDetails {
            e.bodyPreview = nil
            e.attendees = []
        }
        if policy.redactDetails {
            e.subject = ""
            e.location = nil
            e.onlineMeetingURL = nil
            e.categories = nil   // user-chosen text: as revealing as a subject
        }
        return e
    }

    // MARK: Offline edits (outbox)

    /// Move/resize an event. Applied locally at once (optimistic), queued for Exchange.
    public func move(eventId: String, to start: Date, end: Date) async throws {
        guard let e = try store.event(id: eventId) else { return }
        var d = EventDraft(e); d.start = start; d.end = end
        try await edit(eventId: eventId, to: d)
    }

    /// Ids Exchange assigned to items created offline (local id → server id), so the UI can follow its selection.
    public private(set) var remappedIds: [String: String] = [:]

    /// New event: shown at once with a local id, POSTed when online. Returns the local id.
    @discardableResult
    public func create(_ d: EventDraft) async throws -> String {
        let id = "local-\(UUID().uuidString)"
        let e = d.applied(to: CalendarEvent(id: id, calendarId: d.calendarId, subject: d.subject, start: d.start, end: d.end,
                                            isOrganizer: true))
        try store.upsert(events: [e])
        _ = try store.enqueue(kind: .create, eventId: id, calendarId: d.calendarId,
                              body: try JSONSerialization.data(withJSONObject: d.graphJSON()), ifMatch: nil)
        kick()
        return id
    }

    /// Edit fields. Pending creates have their POST body rewritten; existing events get one merged PATCH.
    public func edit(eventId: String, to d: EventDraft) async throws {
        guard let e = try store.event(id: eventId) else { return }
        let before = EventDraft(e)
        try store.upsert(events: [d.applied(to: e)])
        let queued = try store.outbox().filter { $0.eventId == eventId }
        if let create = queued.first(where: { $0.kind == .create }) {
            var full = try JSONSerialization.jsonObject(with: create.body) as? [String: Any] ?? [:]
            full.merge(d.graphJSON()) { _, new in new }
            try store.replaceOutboxBody(seq: create.seq, body: try JSONSerialization.data(withJSONObject: full))
        } else {
            var patch = queued.first(where: { $0.kind == .update })
                .flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] } ?? [:]
            let delta = d.graphJSON(changedFrom: before)
            guard !delta.isEmpty || !patch.isEmpty else { return }
            patch.merge(delta) { _, new in new }
            try store.enqueueOrCoalesceUpdate(eventId: eventId, calendarId: e.calendarId,
                                              body: try JSONSerialization.data(withJSONObject: patch), ifMatch: e.changeKey)
        }
        kick()
    }

    /// Delete / cancel / decline. Removed locally at once; a tombstone keeps sync from resurrecting it.
    public func remove(eventId: String, mode: RemoveMode, comment: String? = nil) async throws {
        guard let e = try store.event(id: eventId) else { return }
        let queued = try store.outbox().filter { $0.eventId == eventId }
        try store.deleteEvents(ids: [eventId])
        for q in queued { try store.removeOutbox(seq: q.seq) }
        // Never reached Exchange: dropping the queued create is the whole delete.
        if queued.contains(where: { $0.kind == .create }) { onChange(status); return }
        let body = try JSONSerialization.data(withJSONObject: ["mode": mode.rawValue, "comment": comment ?? ""])
        _ = try store.enqueue(kind: .delete, eventId: eventId, calendarId: e.calendarId, body: body, ifMatch: e.changeKey)
        kick()
    }

    private func kick() {
        onChange(status)
        Task {
            try? await self.flushOutbox()
            if self.needsResync { self.needsResync = false; await self.syncNow() }
            self.onChange(self.status)
        }
    }

    /// Set when a write changed things the cache can't derive locally (a new series, a series edit).
    private var needsResync = false

    // MARK: Recurring series (online only: the series master is never cached)

    public enum SeriesError: Error, Equatable { case notASeries, changesDay, offline }

    private func calendarInfo(_ id: String) throws -> CalendarInfo? { try store.calendars().first { $0.id == id } }

    /// Edit every occurrence: PATCH the series master. Time changes shift the series' time of day; moving the
    /// whole series to another weekday changes its pattern and is left to Outlook in the spike.
    public func editSeries(occurrenceId: String, to d: EventDraft) async throws {
        guard let occ = try store.event(id: occurrenceId), let mid = occ.seriesMasterId,
              let cal = try calendarInfo(occ.calendarId) else { throw SeriesError.notASeries }
        let c = Calendar.current
        guard c.isDate(d.start, inSameDayAs: occ.start) else { throw SeriesError.changesDay }
        let master: CalendarEvent
        do { master = try await service.fetch(calendar: cal, eventId: mid) } catch ServiceError.offline { throw SeriesError.offline }
        var target = d
        target.start = master.start.addingTimeInterval(d.start.timeIntervalSince(occ.start))
        target.end = target.start.addingTimeInterval(d.end.timeIntervalSince(d.start))
        target.calendarId = cal.id
        let patch = target.graphJSON(changedFrom: EventDraft(master))
        guard !patch.isEmpty else { return }
        _ = try await service.update(calendar: cal, eventId: mid, patch: try JSONSerialization.data(withJSONObject: patch),
                                     ifMatch: master.changeKey)
        try store.setValue(nil, for: deltaKey(cal, Self.syncWindow()))
        await syncNow()
    }

    /// Delete / cancel / decline the whole series.
    public func removeSeries(occurrenceId: String, mode: RemoveMode, comment: String? = nil) async throws {
        guard let occ = try store.event(id: occurrenceId), let mid = occ.seriesMasterId,
              let cal = try calendarInfo(occ.calendarId) else { throw SeriesError.notASeries }
        do { try await service.remove(calendar: cal, eventId: mid, mode: mode, comment: comment, ifMatch: nil) }
        catch ServiceError.offline { throw SeriesError.offline }
        // Optimistic: drop every cached occurrence of the series, then re-read.
        let siblings = try store.events(from: Self.syncWindow().start, to: Self.syncWindow().end,
                                        calendarIds: Set(try store.calendars().map(\.id))).filter { $0.seriesMasterId == mid }.map(\.id)
        try store.deleteEvents(ids: siblings)
        try store.setValue(nil, for: deltaKey(cal, Self.syncWindow()))
        await syncNow()
    }

    public func pendingCount() throws -> Int { try store.outbox().count }

    private var isFlushing = false

    /// Serialised: actor re-entrancy means a `move` (or another flush) can run while a PATCH is in flight.
    func flushOutbox() async throws {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        // Re-run while items were re-keyed mid-flight (a newer edit coalesced in during the PATCH).
        for _ in 0..<12 where try await !flushPass() {}
    }

    /// Returns true when nothing was re-keyed (queue drained, or blocked until next sync).
    private func flushPass() async throws -> Bool {
        let calendars = Dictionary(uniqueKeysWithValues: try store.calendars().map { ($0.id, $0) })
        var rekeyed = false
        for item in try store.outbox() {
            guard let cal = calendars[item.calendarId] else { try store.removeOutbox(seq: item.seq); continue }
            do {
                switch item.kind {
                case .create:
                    let posted = try await service.create(calendar: cal, body: item.body)
                    let isSeries = ((try? JSONSerialization.jsonObject(with: item.body)) as? [String: Any])?["recurrence"] != nil
                    if isSeries {
                        // Exchange returned the series master; its occurrences arrive with the next sync.
                        try store.deleteEvents(ids: [item.eventId])
                        try store.removeOutbox(seq: item.seq)
                        try store.setValue(nil, for: deltaKey(cal, Self.syncWindow()))
                        remappedIds[item.eventId] = posted.id
                        needsResync = true
                        return false
                    }
                    // VERIFIED (real tenant): Exchange bumps the changeKey right after a create, so a quick follow-up
                    // edit would 412. Re-read once to adopt the settled key.
                    let server = (try? await service.fetch(calendar: cal, eventId: posted.id)) ?? posted
                    let policy = compliance.policy(for: server, context: .init(calendarAccess: cal.access))
                    try store.deleteEvents(ids: [item.eventId])
                    try store.upsert(events: [Self.sanitizeForCache(server, policy: policy)])
                    try store.removeOutbox(seq: item.seq)
                    try store.remapOutbox(from: item.eventId, to: server.id)
                    remappedIds[item.eventId] = server.id
                    return false   // queued follow-ups now carry the real id: re-read the queue
                case .delete:
                    let o = try JSONSerialization.jsonObject(with: item.body) as? [String: Any] ?? [:]
                    let mode = RemoveMode(rawValue: o["mode"] as? String ?? "") ?? .delete
                    let comment = (o["comment"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    try await service.remove(calendar: cal, eventId: item.eventId, mode: mode, comment: comment, ifMatch: item.ifMatch)
                    try store.removeOutbox(seq: item.seq)
                case .update:
                    let server = try await service.update(calendar: cal, eventId: item.eventId, patch: item.body, ifMatch: item.ifMatch)
                    if try store.completeOutbox(seq: item.seq, rev: item.rev, newIfMatch: server.changeKey) {
                        let policy = compliance.policy(for: server, context: .init(calendarAccess: cal.access))
                        try store.upsert(events: [Self.sanitizeForCache(server, policy: policy)])
                    } else {
                        // A newer local edit is queued: keep it on screen, adopt the server's changeKey.
                        if var local = try store.event(id: item.eventId) {
                            local.changeKey = server.changeKey
                            try store.upsert(events: [local])
                        }
                        rekeyed = true
                    }
                }
            } catch ServiceError.conflict {
                // Server changed underneath us: server wins, user is told. Sync skipped the server copy while our
                // edit was pending, so drop this calendar's delta link to force a full re-read.
                conflicts.append(item.eventId)
                try store.removeOutbox(seq: item.seq)
                try store.setValue(nil, for: deltaKey(cal, Self.syncWindow()))
            } catch ServiceError.offline {
                throw ServiceError.offline   // keep queue intact, try again later
            } catch {
                try store.bumpOutbox(seq: item.seq)
            }
        }
        return !rekeyed
    }

    // MARK: Sign-out

    public func wipe() throws { try store.wipe() }
}
