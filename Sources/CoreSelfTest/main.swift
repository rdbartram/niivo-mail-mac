import Foundation
import CryptoKit
import CalendarCore

// Stand-in for `swift test` (crashes under Command Line Tools 6.4). Run: swift run CoreSelfTest [--bench]
var failures = 0
@MainActor func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if cond { print("  ✓ \(msg)") } else { failures += 1; print("  ✗ \(msg)  (line \(line))") }
}
func section(_ s: String) { print("\n▸ \(s)") }

let cipher = AESGCMCipher(key: SymmetricKey(size: .bits256))
func mkStore() throws -> LocalStore { try LocalStore(url: nil, cipher: cipher) }
let t0 = ISO8601DateFormatter().date(from: "2026-11-16T08:00:00Z")!
func ev(_ id: String, _ startMin: Int, _ dur: Int, cal: String = "c1", label: String? = nil,
        sens: LegacySensitivity = .normal) -> CalendarEvent {
    CalendarEvent(id: id, calendarId: cal, subject: "S-\(id)", start: t0.addingTimeInterval(Double(startMin * 60)),
                  end: t0.addingTimeInterval(Double((startMin + dur) * 60)), attendees: [.init(name: "A", address: "a@x", response: "none")],
                  bodyPreview: "body", legacySensitivity: sens, labelId: label, changeKey: "ck-1")
}

// MARK: Store
section("LocalStore")
do {
    let s = try mkStore()
    try s.upsert(events: [ev("a", 0, 60), ev("b", 120, 30), ev("c", 30, 30, cal: "c2"), ev("long", -3000, 6000)])
    let r = try s.events(from: t0, to: t0.addingTimeInterval(3600), calendarIds: ["c1", "c2"])
    check(Set(r.map(\.id)) == ["a", "c", "long"], "range query returns overlapping events incl. multi-day (\(r.map(\.id)))")
    let only1 = try s.events(from: t0, to: t0.addingTimeInterval(86400), calendarIds: ["c1"])
    check(!only1.contains { $0.calendarId == "c2" }, "calendar filter respected")
    try s.upsert(events: [ev("a", 10, 60)])
    check(try s.event(id: "a")?.start == t0.addingTimeInterval(600), "upsert updates in place")
    try s.replaceEvents(calendarId: "c1", window: DateInterval(start: t0, duration: 86400), with: [ev("z", 5, 10)])
    let after = try s.events(from: t0, to: t0.addingTimeInterval(86400), calendarIds: ["c1", "c2"]).map(\.id)
    check(Set(after) == ["z", "c"], "replaceWindow swaps a calendar's window atomically, other calendars untouched (\(after))")
    try s.setValue("link-1", for: "delta:x"); check(try s.value(for: "delta:x") == "link-1", "kv round-trips")
    let wrong = AESGCMCipher(key: SymmetricKey(size: .bits256))
    let other = try LocalStore(url: nil, cipher: wrong)
    _ = other
    check((try? cipher.open(wrong.seal(Data("x".utf8)))) == nil, "payload sealed with another key cannot be opened (crypto-shred on sign-out)")
} catch { failures += 1; print("  ✗ store threw \(error)") }

// MARK: Compliance
section("Compliance engine")
do {
    let labels = FixtureCalendarService.labels
    let eng = CachedLabelPolicyEngine(labels: labels, synced: true)
    let own = ComplianceContext(calendarAccess: .own), shared = ComplianceContext(calendarAccess: .shared)

    let p0 = eng.policy(for: ev("u", 0, 30), context: own)
    check(p0 == .open, "unlabelled item → open")
    let pGen = eng.policy(for: ev("g", 0, 30, label: labels[1].id), context: own)
    check(pGen.allowCopy && !pGen.preventScreenCapture, "General → copy allowed")
    let pConf = eng.policy(for: ev("c", 0, 30, label: labels[2].id.uppercased()), context: own)
    check(pConf.allowCopy && pConf.headerMarking != nil && pConf.allowOfflineDetails,
          "Confidential (case-insensitive id, unencrypted) → copy allowed by usage rights, header marking, offline OK")
    let pHC = eng.policy(for: ev("h", 0, 30, label: labels[3].id), context: own)
    check(pHC.bodyIsProtected && pHC.preventScreenCapture && !pHC.allowOfflineDetails && pHC.watermark != nil,
          "Highly Confidential (protected) → body protected, no capture, not cached, watermark")
    let pUnknown = eng.policy(for: ev("x", 0, 30, label: FixtureCalendarService.orphanLabelId), context: own)
    if case .unknown = pUnknown.labelState { check(!pUnknown.allowCopy && pUnknown.preventScreenCapture && !pUnknown.allowOfflineDetails, "unknown label → fail closed") }
    else { check(false, "unknown label state") }
    let unsynced = CachedLabelPolicyEngine()
    check(!unsynced.policy(for: ev("y", 0, 30, label: labels[1].id), context: own).allowCopy, "no policy synced yet → labelled items fail closed")
    let pPrivShared = eng.policy(for: ev("p", 0, 30, sens: .private), context: shared)
    check(pPrivShared.redactDetails && !pPrivShared.allowOfflineDetails, "legacy private on shared calendar → redacted")
    check(!eng.policy(for: ev("p", 0, 30, sens: .private), context: own).redactDetails, "legacy private on own calendar → visible")

    let clean = SyncEngine.sanitizeForCache(ev("h", 0, 30, label: labels[3].id), policy: pHC)
    check(clean.bodyPreview == nil && clean.attendees.isEmpty && clean.subject == "S-h", "sanitize strips body/attendees before disk, keeps subject")
    let red = SyncEngine.sanitizeForCache(ev("p", 0, 30, sens: .private), policy: pPrivShared)
    check(red.subject.isEmpty, "sanitize drops subject of redacted private item")
    check(pGen.merged(with: pHC).preventScreenCapture && !pGen.merged(with: pHC).allowCopy, "merge keeps strictest controls")
}

// MARK: MIP metadata
section("MIP metadata parsing")
let raw = "MSIP_Label_A1F0C4E2-0000-4000-8000-000000000003_Enabled=true; MSIP_Label_A1F0C4E2-0000-4000-8000-000000000003_SiteId=72f988bf; MSIP_Label_A1F0C4E2-0000-4000-8000-000000000003_Method=Standard"
check(MIPMetadata.activeLabelId(in: raw) == "a1f0c4e2-0000-4000-8000-000000000003", "extracts enabled label GUID")
check(MIPMetadata.activeLabelId(in: "MSIP_Label_abc_Enabled=false") == nil, "ignores disabled label")
do {
    let ours = "MSIP_Label_aaaa-1_Enabled=true; MSIP_Label_aaaa-1_SiteId=home-t; MSIP_Label_aaaa-1_Method=Standard"
    let theirs = "MSIP_Label_bbbb-2_Enabled=true; MSIP_Label_bbbb-2_SiteId=other-t; MSIP_Label_bbbb-2_Method=Privileged"
    check(MIPMetadata.activeLabelId(in: theirs, homeTenant: "home-t") == nil, "another organisation's label is ignored (SiteId ≠ home tenant)")
    check(MIPMetadata.activeLabelId(in: theirs + "; " + ours, homeTenant: "HOME-T") == "aaaa-1", "our label picked when both orgs labelled the mail")
    check(MIPMetadata.activeLabelId(in: theirs, homeTenant: nil) == "bbbb-2", "tenant unknown: previous behaviour (first enabled)")
}

// MARK: Time parsing
section("Graph time parsing")
check(GraphTime.parse("2026-11-18T09:30:00.0000000", allDay: false) == ISO8601DateFormatter().date(from: "2026-11-18T09:30:00Z"), "timed = UTC instant")
let ad = GraphTime.parse("2026-11-18T00:00:00.0000000", allDay: true)!
check(Calendar.current.component(.hour, from: ad) == 0 && Calendar.current.component(.day, from: ad) == 18, "all-day anchored at local midnight")

// MARK: Layout
section("Overlap layout")
let placed = DayLayout.place([ev("1", 0, 60), ev("2", 30, 60), ev("3", 45, 30), ev("4", 120, 30)], day: t0)
let byId = Dictionary(uniqueKeysWithValues: placed.map { ($0.event.id, $0) })
check(byId["1"]?.columns == 3 && byId["2"]?.columns == 3 && byId["3"]?.column == 2, "3-way overlap → 3 columns")
check(byId["4"]?.columns == 1 && byId["4"]?.column == 0, "later non-overlapping event gets full width")

// MARK: Sync + outbox (offline edit, conflict)
section("Sync engine, offline outbox, conflict")
do {
    let svc = FixtureCalendarService(anchor: t0, eventsPerCalendarPerWeek: 3, weeks: 0...1)
    let store = try mkStore()
    let eng = CachedLabelPolicyEngine()
    let sync = SyncEngine(service: svc, store: store, compliance: eng, onChange: { _ in })
    await sync.syncNow()
    let n = try store.eventCount()
    check(n > 0, "initial sync populated store (\(n) events)")
    check(try eng.isPolicySynced && !store.labels().isEmpty, "label policy cached for offline use")

    // Cached protected items have no body on disk.
    let all = try store.events(from: t0.addingTimeInterval(-86400 * 30), to: t0.addingTimeInterval(86400 * 30),
                               calendarIds: Set(FixtureCalendarService.calendars.map(\.id)))
    let hc = all.filter { $0.labelId == FixtureCalendarService.labels[3].id }
    check(!hc.isEmpty && hc.allSatisfy { $0.bodyPreview == nil && $0.attendees.isEmpty }, "protected items persisted without body/attendees (\(hc.count))")

    // Offline edit is queued, applied locally, flushed on reconnect.
    svc.simulateOffline = true
    let target = all.first { $0.calendarId == "cal-me" }!
    try await sync.move(eventId: target.id, to: target.start.addingTimeInterval(3600), end: target.end.addingTimeInterval(3600))
    try await Task.sleep(for: .milliseconds(50))
    check(try store.event(id: target.id)?.pendingSync == true, "offline move applied optimistically")
    check(try await sync.pendingCount() == 1, "edit waiting in outbox")
    await sync.syncNow()
    if case .offline = await sync.status { check(true, "status reports offline") } else { check(false, "status offline") }
    svc.simulateOffline = false
    await sync.syncNow()
    check(try await sync.pendingCount() == 0, "outbox drained after reconnect")
    check(try store.event(id: target.id)?.start == target.start.addingTimeInterval(3600), "server accepted the move")

    // Conflict: server changed since our edit → server wins, conflict reported.
    let t2 = try store.event(id: target.id)!
    svc.simulateOffline = true
    try await sync.move(eventId: t2.id, to: t2.start.addingTimeInterval(1800), end: t2.end.addingTimeInterval(1800))
    svc.serverSideEdit(eventId: t2.id)
    svc.simulateOffline = false
    await sync.syncNow()
    check(await sync.conflicts.contains(t2.id), "If-Match conflict detected and surfaced")
    check(try store.event(id: t2.id)?.subject.contains("moved by organiser") == true, "server copy wins after conflict")
} catch { failures += 1; print("  ✗ sync threw \(error)") }

// MARK: Two offline edits to the same event
section("Two offline edits to one event")
do {
    let svc = FixtureCalendarService(anchor: t0, eventsPerCalendarPerWeek: 3, weeks: 0...0)
    let store = try mkStore()
    let sync = SyncEngine(service: svc, store: store, compliance: CachedLabelPolicyEngine(), onChange: { _ in })
    await sync.syncNow()
    let e = try store.events(from: t0.addingTimeInterval(-86400 * 7), to: t0.addingTimeInterval(86400 * 14),
                             calendarIds: ["cal-me"]).first { !$0.isAllDay }!
    svc.simulateOffline = true
    try await sync.move(eventId: e.id, to: e.start.addingTimeInterval(1800), end: e.end.addingTimeInterval(1800))
    try await sync.move(eventId: e.id, to: e.start.addingTimeInterval(7200), end: e.end.addingTimeInterval(7200))
    try await Task.sleep(for: .milliseconds(50))
    check(try await sync.pendingCount() == 1, "second edit coalesced into one queued PATCH")
    svc.simulateOffline = false
    await sync.syncNow()
    check(try await sync.pendingCount() == 0, "queue drained")
    check(await sync.conflicts.isEmpty, "no false conflict from our own first write")
    check(try store.event(id: e.id)?.start == e.start.addingTimeInterval(7200), "latest position wins on the server")
} catch { failures += 1; print("  ✗ double-move threw \(error)") }

// MARK: File-backed cache
section("File-backed encrypted cache")
do {
    let dir = FileManager.default.temporaryDirectory.appending(path: "cc-selftest-\(UUID().uuidString)")
    let url = dir.appending(path: "cache.sqlite")
    let key = SymmetricKey(size: .bits256)
    do {
        let s = try LocalStore(url: url, cipher: AESGCMCipher(key: key))
        try s.upsert(events: [ev("persist", 0, 60)])
        try s.setValue("link", for: "delta:x")
    }
    let reopened = try LocalStore(url: url, cipher: AESGCMCipher(key: key))
    check(try reopened.event(id: "persist")?.subject == "S-persist", "reopen with same key reads cached event")
    check(try reopened.value(for: "delta:x") == "link", "delta link survives restart")
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    check(perms == 0o600, "cache file mode 0600 (got \(String(perms ?? 0, radix: 8)))")
    let raw = try Data(contentsOf: url)
    check(raw.range(of: Data("S-persist".utf8)) == nil, "subject not present in plaintext on disk")
    let wrong = try LocalStore(url: url, cipher: AESGCMCipher(key: SymmetricKey(size: .bits256)))
    check((try? wrong.event(id: "persist")) == nil, "other key (after sign-out key destruction) cannot read it")
    try? FileManager.default.removeItem(at: dir)
} catch { failures += 1; print("  ✗ file cache threw \(error)") }

runRightsTests()
runLabelTreeTests()
await runGraphStubTests()
runMeetingLinkTests()
runAlertTests()
runFreeTimeTests()
await runWriteTests()
await runCalendarFeatureTests()   // CALENDAR: sources, groups, responses, rooms, categories, ICS, month/agenda
await runMailTests()
await runMailFolderTests()
await runComposerTests()
await runComposeDraftTests()   // COMPOSE2: autosave in place, quoted history
await runComposeExtrasTests()   // COMPOSE2: send later, reply settings, Save All, reply with meeting
await runComposeAssistTests()   // COMPOSE: autocomplete, MailTips, From, templates, table/rule, reopened drafts
runRTFBodyTests()
await runTrustTests()
runUpdatePolicyTests()   // UPDATE-HOOK
await runTrustEnforcementTests()   // TRUST-WIRING: per-account session state, decision → action, per-account wipe, signed policy delivery
await runMCPTests()
await runAIAssistTests()
await runVoiceTests()   // VOICE: layered voice prompts, signature rules
await runVoiceLearnTests()   // VOICE2-HOOK: learn voice, nudges, signature import
await runAgentToolsTests()
await runProtectedContentTests()
await runProtectedOpenTests()
await runPurviewTests()   // PURVIEW: label policy, msip_labels, encrypt gate, attachment rights
await runPurviewWireTests()   // PURVIEW: stamp on the draft POST
await runPurviewStampRejectionTests()   // PURVIEW: rejected stamp never breaks saving
await runSearchTests()   // SEARCH
await runSearchQualityTests()   // SEARCHQ-HOOK: natural-mode search logic + privacy
await runSearchBoxTests()   // SEARCHBOX-HOOK: main search box (operators, scope, sort, suggestions, privacy)
await runReaderExtrasTests()   // READER: cid images, attachment rights, notifications
await runReaderGraphTests()   // READER2: invites, junk, source, print gates, unsubscribe
runAttachmentPreviewTests()   // PREVIEW-HOOK: inline attachment previews (gate, renderer mapping, scratch cleanup)
await runMailboxGroupsTests()   // MAILBOXES + GROUPS
await runDriveTests()   // ONEDRIVE cloud attachments
await runPeopleTodoPresenceTests()   // PEOPLE + TO DO + PRESENCE
await runSearchBenchmark()   // SEARCH (CC_BENCH=1)
await runStoryTests()   // STORIES
runLifecycleTests()   // LIFECYCLE: mailto, CAE claims, Retry-After, sync health, notification filters, cadence
await runOrganiseTests()   // ORGANISE: bulk, undo remap, sweep, categories, smart views, scope, unified inbox
await runOrg2Tests()   // ORG2-HOOK: favourites, ignore, trays, VIPs, quick steps, groups manage, find a time
await runA11yTests()   // A11Y: view prefs, pane cycle, String Catalog, regional formats
runLabelProvenanceTests()   // LABELS: foreign tenants, provenance, display rule, census
await runAccountsTests()   // ACCOUNTS-HOOK: multiple accounts (docs/ACCOUNTS.md)
runListLayoutTests()   // LIST: Gmail-style rows, badges, density, clean list
runComposeLayoutTests()   // COMPOSE-LAYOUT: pane takeover, compact header, inline AI, list label marks
await runThreadTests()   // THREAD-HOOK: conversation view (grouping, actions + undo, gating, paging, timing)
await runInboxStateTests()   // TRIAGE2-HOOK: conversation triage state (docs/INBOX-INTELLIGENCE-PLAN.md Phase 1)
await runPromisesTests()   // PROMISES-HOOK: promises ledger
await runKnowledgeTests()   // PEOPLE-HOOK: knowledge layer (plan Phase 2)
await runLoopsTests()   // LOOPS-HOOK: loops (docs/SUITE.md step 1)
await runWorkItemsTests()   // WHEN-HOOK / DEEP-HOOK: work items, slot finder, focus blocks (docs/SUITE.md)
await runPeopleSurfaceTests()   // PEOPLE2-HOOK: People surface (directory, owes, history, notes)
runTodayTests()   // TODAY-HOOK: Today, Flow, calm notifications (docs/RETHINK.md §4)
runDeskTests()   // DESK-HOOK: Desk state (docs/SUITE.md)
await runStoryBenchmark()   // STORIES (CC_STORY_BENCH=1)

// MARK: Benchmark
if CommandLine.arguments.contains("--bench") {
    section("Benchmark (in-memory store, encrypted payloads)")
    let s = try mkStore()
    let cals = (0..<6).map { "cal\($0)" }
    var batch: [CalendarEvent] = []
    for i in 0..<20_000 {
        batch.append(ev("e\(i)", (i / cals.count) * 90 % (60 * 24 * 365), 30 + (i % 4) * 15, cal: cals[i % cals.count]))
    }
    var t = Date()
    try s.upsert(events: batch)
    print("  insert 20,000 events: \(Int(Date().timeIntervalSince(t) * 1000)) ms")
    let weekStart = t0.addingTimeInterval(86400 * 30)
    var times: [Double] = []
    var count = 0
    for k in 0..<200 {
        t = Date()
        let r = try s.events(from: weekStart.addingTimeInterval(Double(k % 20) * 86400 * 7),
                             to: weekStart.addingTimeInterval(Double(k % 20 + 1) * 86400 * 7), calendarIds: Set(cals))
        count = r.count
        times.append(Date().timeIntervalSince(t) * 1000)
    }
    times.sort()
    print(String(format: "  week query (%d events, decrypt+decode): p50 %.2f ms, p95 %.2f ms", count, times[100], times[190]))
    let wk = try s.events(from: weekStart, to: weekStart.addingTimeInterval(86400 * 7), calendarIds: Set(cals))
    t = Date()
    for _ in 0..<200 { for d in 0..<7 { _ = DayLayout.place(wk, day: weekStart.addingTimeInterval(Double(d) * 86400)) } }
    print(String(format: "  layout 7 days: %.3f ms", Date().timeIntervalSince(t) * 1000 / 200))
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
