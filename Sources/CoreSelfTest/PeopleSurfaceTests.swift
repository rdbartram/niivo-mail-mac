import Foundation
import CryptoKit
import CalendarCore
import MailCore

// PEOPLE2-HOOK: People surface logic (MailCore/PeopleSurface.swift, PeopleNotes.swift). Reuses the knowledge corpus
// (`.example` domains, made-up personas). Failure lines print counts and persona keys only.

private final class StubLoops: LoopSource {
    var byAddress: [String: [LoopSummary]] = [:]
    var account = "acct-A"
    func loops(involving address: String, account: String) -> [LoopSummary] {
        account == self.account ? (byAddress[address] ?? []) : []
    }
}

private final class StubOneNote: OneNoteService, @unchecked Sendable {
    let lock = NSLock()
    var notebooks: [String: String] = [:]
    var sections: [String: String] = [:]
    var pages: [(section: String, html: String)] = []
    var calls: [String] = []
    var failPages = false
    func findNotebook(named: String) async throws -> String? { lock.withLock { calls.append("findNB"); return notebooks[named] } }
    func createNotebook(named: String) async throws -> String { lock.withLock { calls.append("createNB"); notebooks[named] = "nb1"; return "nb1" } }
    func findSection(named: String, notebookId: String) async throws -> String? { lock.withLock { calls.append("findS"); return sections[notebookId + "/" + named] } }
    func createSection(named: String, notebookId: String) async throws -> String {
        lock.withLock { calls.append("createS:" + named); let id = "s\(sections.count + 1)"; sections[notebookId + "/" + named] = id; return id }
    }
    func createPage(sectionId: String, html: String) async throws -> OneNotePageRef {
        try lock.withLock {
            if failPages { throw MailServiceError.forbidden }
            pages.append((sectionId, html))
            return OneNotePageRef(id: "page\(pages.count)", webUrl: URL(string: "https://onenote.example/p\(pages.count)"),
                                  clientUrl: URL(string: "onenote:https://onenote.example/p\(pages.count)"))
        }
    }
}

@MainActor
func runPeopleSurfaceTests() async {
    section("People surface: directory, who owes whom, history, empty state, notes (PEOPLE2)")
    let now = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
    let eng = CachedLabelPolicyEngine(labels: FixtureCalendarService.labels, synced: true)
    let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
    let me = "owner@niivo-test.example"
    let corpus = makeKnowledgeCorpus(now: now)
    let store: MailStore
    do {
        store = try MailStore(url: nil, key: SymmetricKey(size: .bits256))
        store.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) }
        try store.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox), MailFolder(id: "sent", displayName: "Sent", wellKnown: .sentitems)], mailbox: "me")
        try store.upsert(messages: corpus.messages)
        for (id, b) in corpus.bodies { try store.putBody(messageId: id, body: b) }
    } catch { check(false, "people store threw \(error)"); return }
    let k = store.enableKnowledge(KnowledgeEngine.Config(account: "acct-A", owners: [me], internalDomains: ["niivo-test.example"], gate: gate))
    check(!k.isBuilt, "a fresh engine reports it hasn't built yet (the page waits for refresh instead of showing empty)")
    k.refresh(now: now)
    check(k.isBuilt, "built after refresh")
    let v = k.view(.user)
    let thomasA = "t.keller@keller-ag.example", andreaA = "andrea.muster@muster-partner.example", petraA = "petra.vogel@muster-partner.example"
    guard let thomas = v.person(address: thomasA), let andrea = v.person(address: andreaA) else { check(false, "corpus personas resolve"); return }

    // Directory: counts, sort by recent contact, orgs, places, search, LoopSource vs triage fallback.
    let loops = StubLoops()
    loops.byAddress[thomasA] = [LoopSummary(id: "l1", title: "Proposal", state: "open", due: now, waitingOn: .them),
                                LoopSummary(id: "l2", title: "Old", state: "done")]
    loops.byAddress[andreaA] = [LoopSummary(id: "l3", title: "Will", state: "open", waitingOn: .me)]
    loops.byAddress["andrea.muster@gmail.example"] = [LoopSummary(id: "l3", title: "Will", state: "open", waitingOn: .me)]
    let places = [thomasA: "Zürich", andreaA: "Zürich", petraA: "Bern"]
    func dir(_ q: String = "") -> PeopleDirectory {
        PeopleSurface.directory(view: v, open: { p in
            PeopleOpenCount(count: PeopleSurface.loops(loops, addresses: p.addresses, account: "acct-A").count, fromLoops: true)
        }, place: { p in p.addresses.lazy.compactMap { places[$0] }.first }, query: q)
    }
    let d = dir()
    check(d.people.count == v.people.count && d.people.count > 5, "directory lists every visible person (\(d.people.count))")
    check(zip(d.people, d.people.dropFirst()).allSatisfy { ($0.last ?? .distantPast) >= ($1.last ?? .distantPast) }, "directory sorted by most recent contact")
    check(d.people.first { $0.id == thomas.key }?.open.count == 1, "loop count: open loops only (done one excluded)")
    check(d.people.first { $0.id == andrea.key }?.open.count == 1, "loop count: the same loop via two addresses counts once")
    check(d.openTotal == 2, "open total = sum of rows (\(d.openTotal))")
    let mp = d.orgs.first { $0.id.contains("muster-partner") }
    check(mp?.people == 2 && mp?.open == 1, "organisation: people count and loops (\(mp?.people ?? -1), \(mp?.open ?? -1))")
    check(d.places.first { $0.name == "Zürich" }?.people == 2 && d.places.first { $0.name == "Bern" }?.people == 1, "places: people count per office location")
    check(dir("keller").people.map(\.id) == [thomas.key], "search narrows people by name / address / organisation")
    check(!d.people.contains { $0.address.contains("unbekannt") || $0.address.contains("privat") },
          "unknown-label / private correspondents never enter the directory")

    // Who owes whom (one account, sender must be this person).
    let conv = andrea.conversations
    let L1 = conv.first { $0 == "L1" } ?? "L1", L4 = "L4", L2 = "L2"
    let states = [
        PeopleConversation(conversationId: L4, account: "acct-A", state: .needsReply, senderAddress: andreaA, lastFromMe: false, latestMessageId: "x1", since: now.addingTimeInterval(-86_400)),
        PeopleConversation(conversationId: L2, account: "acct-A", state: .needsReply, senderAddress: "m.gegner@kanzlei-gegner.example", lastFromMe: false, latestMessageId: "x2"),
        PeopleConversation(conversationId: L1, account: "acct-A", state: .waiting, senderAddress: andreaA, lastFromMe: true, latestMessageId: "mine-1", since: now.addingTimeInterval(-3 * 86_400)),
        PeopleConversation(conversationId: L1, account: "acct-B", state: .waiting, senderAddress: andreaA, lastFromMe: true, latestMessageId: "other-acct"),
        PeopleConversation(conversationId: "unrelated", account: "acct-A", state: .waiting, senderAddress: andreaA, lastFromMe: true, latestMessageId: "x3"),
    ]
    let o = PeopleSurface.owes(addresses: Set(andrea.addresses), conversations: conv, account: "acct-A", states: states)
    check(o.youOwe == 1, "you owe them: needs reply only where they were the last sender (\(o.youOwe))")
    check(o.theyOwe == 1 && o.nudgeMessageId == "mine-1", "they owe you: waiting on my last message; nudge replies to it")
    check(conv.contains(L1) && conv.contains(L4), "fixture conversations belong to the person")
    let oB = PeopleSurface.owes(addresses: Set(andrea.addresses), conversations: conv, account: "acct-B", states: states)
    check(oB.youOwe == 0 && oB.theyOwe == 1 && oB.nudgeMessageId == "other-acct", "per-account: another account's triage never leaks in")
    check(PeopleSurface.owes(addresses: Set(andrea.addresses), conversations: conv, account: "acct-A",
                             states: [PeopleConversation(conversationId: L4, account: "acct-A", state: .fyi, senderAddress: andreaA, lastFromMe: false, latestMessageId: "y")]).none,
          "FYI / done conversations owe nothing")

    // History: merge order, grouping, redaction.
    let t = { (h: Double) in now.addingTimeInterval(-h * 3600) }
    let merged = PeopleSurface.history([
        PeopleHistoryInput(kind: .mail, ref: "m1", date: t(50), title: "Old in thread", visible: true, group: "c1"),
        PeopleHistoryInput(kind: .mail, ref: "m2", date: t(2), title: "Newest in thread", visible: true, group: "c1"),
        PeopleHistoryInput(kind: .meeting, ref: "e1", date: t(10), title: "Secret board", visible: false),
        PeopleHistoryInput(kind: .note, ref: "n1", date: t(10), title: "Note", visible: true),
        PeopleHistoryInput(kind: .mail, ref: "m3", date: t(30), title: "Hidden subject", visible: false, group: "c2"),
    ])
    check(merged.map(\.ref) == ["m2", "e1", "n1", "m3"], "history: newest first, a conversation is one line (its newest), ties by kind (\(merged.map(\.ref)))")
    check(merged.first { $0.ref == "e1" }?.title == nil && merged.first { $0.ref == "m3" }?.title == nil, "history: protected items keep kind and date, never a title")
    check(merged.first { $0.ref == "m2" }?.title == "Newest in thread", "history: visible items keep their title")
    let mailIn = PeopleSurface.mailInputs(thomas, engine: k)
    check(!mailIn.isEmpty && mailIn.allSatisfy { k.message($0.ref, tier: .user) != nil }, "mail history only from metadata-visible messages (\(mailIn.count))")
    if let h = v.person(address: "hans@geheim.example") {
        let hm = PeopleSurface.history(PeopleSurface.mailInputs(h, engine: k))
        check(!hm.isEmpty && hm.allSatisfy { $0.title == nil }, "protected-only person: history lines are metadata only (no subject)")
    } else { check(false, "protected-only person is known by metadata") }
    let evs = [
        CalendarEvent(id: "ev-past", calendarId: "c", subject: "Review", start: t(48), end: t(47), attendees: [.init(name: "T", address: thomasA, response: "accepted")]),
        CalendarEvent(id: "ev-next", calendarId: "c", subject: "Board", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000),
                      attendees: [.init(name: "T", address: thomasA.uppercased(), response: "none")], labelId: FixtureCalendarService.labels[3].id),
        CalendarEvent(id: "ev-cancel", calendarId: "c", subject: "X", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200),
                      attendees: [.init(name: "T", address: thomasA, response: "none")], isCancelled: true),
    ]
    let meet = PeopleSurface.meetingInputs(evs, addresses: [thomasA], redact: { $0.labelId != nil })
    check(meet.count == 2 && meet.first { $0.ref == "ev-next" }?.visible == false, "meetings: cancelled dropped, labelled meeting is metadata only")
    check(PeopleSurface.nextMeeting(evs, addresses: [thomasA], now: now)?.id == "ev-next", "next meeting: soonest upcoming, not cancelled, address case-insensitive")

    // Header facts.
    let s1 = PeopleSurface.since(first: ISO8601DateFormatter().date(from: "2025-05-01T00:00:00Z"), now: now, windowDays: 730)
    check(s1?.year == 2025 && s1?.atWindowEdge == false, "client since: year of first contact")
    let s2 = PeopleSurface.since(first: now.addingTimeInterval(-729 * 86_400), now: now, windowDays: 730)
    check(s2?.atWindowEdge == true, "client since: first contact at the window edge is marked (real start may be earlier)")

    // Empty-state reason (and the diagnostic line).
    func reason(_ a: String?, locked: Bool = false, started: Bool = true) -> PeopleEmptyReason? {
        PeopleSurface.emptyReason(address: a, locked: locked, mailStarted: started, owners: k.owners,
                                  known: a.map { k.knows(address: $0) } ?? false, visible: a.flatMap { v.person(address: $0) } != nil)
    }
    check(reason(thomasA) == nil, "empty reason: visible person → page shows")
    check(reason("otto@unbekannt.example") == .hiddenByLabels && reason("ursula@privat-recht.example") == .hiddenByLabels, "empty reason: mail exists but labels / private hide it")
    check(reason("nobody@nowhere.example") == .noMailInWindow, "empty reason: no mail in the window")
    check(reason(me) == .ownAddress && reason(nil) == .noSelection, "empty reason: own address / nothing selected")
    check(reason(thomasA, started: false) == .mailNotStarted && reason(thomasA, locked: true) == .locked, "empty reason: mail not started / locked")
    let line = PeopleSurface.diagnostic(directory: d.people.count, open: d.openTotal, page: .hiddenByLabels, pageShown: true)
    check(line == "[People] directory=\(d.people.count) open=2 personPage=empty(hiddenByLabels)", "diagnostic line: counts and reason only")
    check(PeopleSurface.diagnostic(directory: 3, open: 0, page: nil, pageShown: true).hasSuffix("personPage=ok"), "diagnostic line: ok")
    check(!line.contains("@") && !line.contains("Keller"), "diagnostic line carries no names or addresses")

    // Notes (OneNote stub; never the tenant).
    check(PeopleNotes.sectionName(org: "Muster & Partner / Zürich") == "Muster Partner Zürich", "section name: OneNote-forbidden characters dropped")
    check(PeopleNotes.sectionName(org: nil) == "People" && PeopleNotes.sectionName(org: "  ") == "People", "section name: People without an organisation")
    check(PeopleNotes.sectionName(org: String(repeating: "a", count: 80)).count == 50, "section name: ≤ 50 characters")
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    check(PeopleNotes.pageTitle(person: "Thomas Keller", date: now, calendar: utc) == "Thomas Keller · 2026-11-20", "page title: <Person> · <date>")
    let html = PeopleNotes.html(title: "A <b>&", text: "line 1\n<script>x</script>", address: thomasA, at: now)
    check(!html.contains("<script>") && html.contains("&lt;script&gt;") && html.contains("<title>A &lt;b&gt;&amp;</title>"), "note HTML escapes the title and the text")
    let one = StubOneNote()
    do {
        let r1 = try await PeopleNotes.log(one, person: "Thomas Keller", address: thomasA.uppercased(), org: "Keller AG", text: "Called about the offer", at: now, calendar: utc)
        let r2 = try await PeopleNotes.log(one, person: "Thomas Keller", address: thomasA, org: "Keller AG", text: "Second", at: now, calendar: utc)
        check(one.calls.filter { $0 == "createNB" }.count == 1 && one.calls.filter { $0.hasPrefix("createS") }.count == 1,
              "notebook and section are created once, then found")
        check(r1.address == thomasA && r1.pageId != r2.pageId && r1.clientUrl?.hasPrefix("onenote:") == true, "note record: page id, lowercased address, client link")
        k.putNote(r1); k.putNote(r2)
        check(k.notes(address: thomasA).count == 2 && k.notes(address: andreaA).isEmpty, "note index: per person")
        let other = store.makeKnowledgeEngine(KnowledgeEngine.Config(account: "acct-B", owners: [me], gate: gate))
        check(other.notes().isEmpty, "note index: per account (another account sees none)")
        let noteIn = PeopleSurface.noteInputs(k.notes(address: thomasA))
        check(noteIn.count == 2 && noteIn.allSatisfy { $0.kind == .note && $0.link != nil }, "note history items link to OneNote")
        check(!store.debugKnowledgePayloadSizes().isEmpty, "note index rows are sealed knowledge rows")
        one.failPages = true
        do { _ = try await PeopleNotes.log(one, person: "X", address: "x@y.example", org: nil, text: "t", at: now); check(false, "consent failure surfaces") }
        catch { check(error as? MailServiceError == .forbidden, "a refused page create surfaces as an error (the app offers Connect OneNote)") }
    } catch { check(false, "notes threw \(error)") }
}
