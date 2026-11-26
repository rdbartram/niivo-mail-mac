import Foundation
import CryptoKit
import CalendarCore
import MailCore

// WHEN / DEEP (docs/SUITE.md): loop work items (sealed store, suggestions, label rules), the slot finder (buffers,
// overlaps, mornings, due dates, DST) and the confirm-gated focus block. Synthetic corpus only (`.example` domains);
// failure lines print only ids / counts the test made up.

/// Records writes; nothing reaches a calendar.
actor RecordingFocusWriter: FocusBlockWriter {
    var created: [EventDraft] = []
    var removed: [String] = []
    func createFocusBlock(_ draft: EventDraft) async throws -> String { created.append(draft); return "local-\(created.count)" }
    func removeFocusBlock(eventId: String) async throws {
        guard !eventId.hasPrefix("gone") else { throw FocusBlockError.notFound }
        removed.append(eventId)
    }
}

@MainActor
func runWorkItemsTests() async {
    section("Work items: suggestions, accept, label rules, sealed store, states (When / Deep)")
    let L = FixtureCalendarService.labels
    let protected = L[3].id, noOffline = L[1].id
    let now = ISO8601DateFormatter().date(from: "2026-11-19T08:41:00Z")!   // Thu 09:41 Zurich
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let eng = CachedLabelPolicyEngine(labels: L, synced: true)
    let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
    let me = EmailAddress(name: "Alex Owner", address: "owner@niivo-test.example")
    let anna = EmailAddress(name: "Anna Smith", address: "anna@kunde-wi.example")
    var n = 0
    func mail(_ conv: String, _ from: EmailAddress, _ to: EmailAddress, _ subject: String, _ text: String, hours: Double, label: String? = nil) -> MailMessage {
        n += 1
        let mine = from.address == me.address
        return MailMessage(id: "wi\(n)", folderId: mine ? "sent" : "inbox", conversationId: conv, subject: subject, from: from,
                           toRecipients: [to], received: now.addingTimeInterval(hours * 3600), preview: text, labelId: label)
    }
    let corpus: [MailMessage] = [
        mail("w1", anna, me, "Offer for next year", "Hello, what about the offer?", hours: -30),
        mail("w1", me, anna, "AW: Offer for next year", "Hi Anna, I'll send you the revised offer by Friday.", hours: -29),
        mail("w2", anna, me, "Notice period", "Can we talk about the notice period?", hours: -5),
        mail("w3", anna, me, "Vertragsentwurf", "Hallo, wie geht es?", hours: -8, label: noOffline),          // no offline details
        mail("w5", anna, me, "Unterlagen", "Hallo, wo sind die Papiere?", hours: -8),
        mail("w5", me, anna, "AW: Unterlagen", "Ich schicke dir bis Freitag die Unterlagen.", hours: -7),   // text memory-only (below)
        mail("w4", anna, me, "Vollmacht geheim", "Bitte unterschreiben.", hours: -6, label: protected),
    ]
    let store: MailStore
    do {
        store = try MailStore(url: nil, key: SymmetricKey(size: .bits256))
        store.setPersistPolicy { m, mb in
            var p = MailContentPolicy.policy(for: m, mailbox: mb, engine: eng)
            if m.labelId == noOffline { p.allowOfflineDetails = false }
            return p
        }
        try store.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox),
                                    MailFolder(id: "sent", displayName: "Sent", wellKnown: .sentitems)], mailbox: "me")
        try store.upsert(messages: corpus)
    } catch { check(false, "work items store threw \(error)"); return }
    let k = store.enableKnowledge(KnowledgeEngine.Config(account: "acct-A", owners: [me.address], internalDomains: ["niivo-test.example"], gate: gate))
    k.refresh(now: now)
    let ledger = store.enablePromises(PromiseLedger.Config(account: "acct-A", owners: [me.address],
        exposure: { m, mb in gate.exposure(m, mailbox: mb, tier: .onDevice) },
        persistText: { m, mb in m.conversationId != "w5" && MailContentPolicy.policy(for: m, mailbox: mb, engine: eng).allowOfflineDetails }, calendar: utc))
    ledger.refresh(now: now)
    let loops = store.enableLoops(LoopsEngine.Config(account: "acct-A", owners: [me.address]), knowledge: k)
    let loopId = loops.createLoop(title: "Proposal for next year", conversations: ["w1", "w2", "w3", "w4", "w5"], now: now)
    let work = store.enableWorkItems(.init(account: "acct-A"), knowledge: k, promises: ledger)
    let convs = loops.conversations(inLoop: loopId)
    check(convs == ["w1", "w2", "w3", "w4", "w5"], "loop conversations for suggestions (\(convs.count))")
    let needs: Set<String> = ["w2", "w3", "w4"]

    // Suggestions only: nothing stored until accepted.
    let sug = work.suggestions(loopId: loopId, conversations: convs, needsReply: needs)
    let pW1 = sug.first { if case .promise = $0.source { $0.title?.contains("revised offer") == true } else { false } }
    let pW3 = sug.first { if case .promise = $0.source { $0.title?.contains("Unterlagen") == true } else { false } }
    let rW2 = sug.first { $0.source == .conversation(id: "w2") }
    let rW3 = sug.first { $0.source == .conversation(id: "w3") }
    let rW4 = sug.first { $0.source == .conversation(id: "w4") }
    check(pW1 != nil && pW3 != nil, "suggest: open promises in the loop's conversations become suggestions (\(sug.count) total)")
    check(rW2?.title == "Reply: Notice period" && rW2?.kind == .reply && rW2?.criteria == ["Reply sent"], "suggest: a needs-reply conversation becomes a reply item with a 'done when'")
    check(rW4 != nil && rW4?.title == nil, "suggest: a protected conversation gives a suggestion without a title (metadata only)")
    check(!sug.contains { $0.source == .conversation(id: "w1") }, "suggest: a conversation that doesn't need a reply isn't suggested")
    check(work.debugRowCounts().items == 0 && work.allItems().isEmpty, "suggest: nothing is stored until the user accepts")

    // Accept.
    guard let pW1, let pW3, let rW3, let rW4 else { check(false, "suggestions missing"); return }
    let a1 = work.accept(pW1, now: now)
    check(a1 != nil && work.accept(pW1, now: now) == nil, "accept: a suggestion becomes one item; accepting again does nothing")
    check(!work.suggestions(loopId: loopId, conversations: convs, needsReply: needs).contains { $0.id == pW1.id }, "accept: an accepted source isn't suggested again")
    let i1 = work.item(id: a1 ?? "-")
    check(i1?.state == .open && i1?.titleUser == false && i1?.kind == .promise && i1?.due != nil, "accept: open, derived (not user) title, promise kind, due from the promise")
    let a3 = work.accept(pW3, now: now) ?? "-", r3 = work.accept(rW3, now: now) ?? "-"
    check(work.item(id: a3)?.title?.contains("Unterlagen") == true && work.item(id: r3)?.title == "Reply: Vertragsentwurf",
          "label rule: titles from no-offline mail show in memory")
    check(store.debugWorkItemPlaintextContains("revised offer"), "label rule: a title whose sources allow offline details is on disk")
    check(!store.debugWorkItemPlaintextContains("Unterlagen") && !store.debugWorkItemPlaintextContains("Vertragsentwurf"),
          "label rule: a title from no-offline mail (promise text, subject) is never on disk")
    let fresh = store.makeWorkItemsEngine(.init(account: "acct-A"), knowledge: k, promises: ledger)
    check(fresh.item(id: a3)?.title?.contains("Unterlagen") == true && fresh.item(id: r3)?.title == "Reply: Vertragsentwurf",
          "label rule: after a restart a memory-only title is re-derived from its (visible) source")
    let freshNoLedger = store.makeWorkItemsEngine(.init(account: "acct-A"), knowledge: k, promises: nil)
    check(freshNoLedger.item(id: a3)?.title == nil && freshNoLedger.item(id: a1 ?? "-")?.title?.contains("revised offer") == true,
          "label rule: with the source unavailable only an allowed on-disk title shows")

    // Dismiss / not mine.
    work.dismiss(rW4, now: now)
    check(!work.suggestions(loopId: loopId, conversations: convs, needsReply: needs).contains { $0.id == rW4.id }
          && store.makeWorkItemsEngine(.init(account: "acct-A"), knowledge: k, promises: ledger).suggestions(loopId: loopId, conversations: convs, needsReply: needs).allSatisfy { $0.id != rW4.id },
          "dismiss: the suggestion never comes back (also after a restart)")
    check(work.debugRowCounts().dismissed == 1 && !store.debugWorkItemPlaintextContains("\"w4\""), "dismiss: stored as a keyed hash, not the conversation id")
    work.remove(r3, now: now)
    check(work.item(id: r3) == nil && !work.suggestions(loopId: loopId, conversations: convs, needsReply: needs).contains { $0.id == rW3.id },
          "not mine: the item goes and its source isn't suggested again")

    // A done reply item stops suppressing its conversation (it may need a reply again); a promise item doesn't.
    let r2 = work.accept(work.suggestions(loopId: loopId, conversations: convs, needsReply: needs).first { $0.source == .conversation(id: "w2") }!, now: now) ?? "-"
    work.markDone(r2, now: now)
    check(work.suggestions(loopId: loopId, conversations: convs, needsReply: needs).contains { $0.source == .conversation(id: "w2") },
          "done reply: the conversation can be suggested again when it needs a reply again")
    work.markDone(a1 ?? "-", now: now)
    check(!work.suggestions(loopId: loopId, conversations: convs, needsReply: needs).contains { $0.id == pW1.id }, "done promise: never suggested again")
    work.reopen(a1 ?? "-", now: now)

    // Renames follow the loops rule.
    let shown = work.item(id: a3)?.title ?? ""
    work.rename(a3, to: shown, now: now)
    check(work.item(id: a3)?.titleUser == false && !store.debugWorkItemPlaintextContains("Unterlagen"), "rename: return on an unchanged derived title stores nothing")
    work.rename(a3, to: "Send the contract papers", now: now)
    check(work.item(id: a3)?.titleUser == true && store.debugWorkItemPlaintextContains("Send the contract papers"), "rename: a typed title is the user's own (on disk)")

    // A user item, criteria, states.
    let dueFri = ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")!
    let memo = work.add(loopId: loopId, title: "Decide on notice period", kind: .doc, minutes: 50, due: dueFri,
                        criteria: ["Proposal read", "Notice period decided"], now: now)
    check(work.toPlace(now: now, loopId: loopId).map(\.id).contains(memo), "add: a user item is waiting to be placed")
    guard let crit = work.item(id: memo)?.criteria.first?.id else { check(false, "criteria missing"); return }
    work.toggleCriterion(memo, crit, now: now)
    work.addCriterion(memo, "Reply sent", now: now)
    check(work.item(id: memo)?.criteriaDone == 1 && work.item(id: memo)?.criteria.count == 3, "done when: tick and add criteria")
    let slot = WorkSlot(start: now.addingTimeInterval(1800), end: now.addingTimeInterval(1800 + 3000), eventId: "local-1")
    work.schedule(memo, slot: slot, now: now)
    check(work.item(id: memo)?.state == .scheduled && work.placed(now: now).contains { $0.id == memo } && !work.toPlace(now: now).contains { $0.id == memo },
          "schedule: scheduled, out of the When queue")
    work.remapEvent(memo, from: "local-1", to: "AAMk-real", now: now)
    check(work.item(id: memo)?.slot?.eventId == "AAMk-real", "schedule: the local event id is replaced by Exchange's id")
    work.reschedule(memo, now: now)
    check(work.item(id: memo)?.state == .open && work.item(id: memo)?.movingFrom?.eventId == "AAMk-real" && work.item(id: memo)?.slot == nil,
          "reschedule: a future block is remembered for replacement")
    work.remapEvent(memo, from: "AAMk-real", to: "AAMk-real2", now: now)
    check(work.item(id: memo)?.movingFrom?.eventId == "AAMk-real2", "reschedule: the block being replaced follows an id remap")
    let past = WorkSlot(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), eventId: "AAMk-past")
    work.schedule(memo, slot: past, now: now)
    check(work.toPlace(now: now).first?.id == memo && !work.placed(now: now).contains { $0.id == memo } && work.item(id: memo)?.isMissed(now: now) == true,
          "missed block: a scheduled item whose block passed without work is back first in When")
    work.schedule(memo, slot: slot, now: now)
    work.start(memo, now: now)
    check(work.item(id: memo)?.state == .inProgress && work.item(id: memo)?.movingFrom == nil, "deep: started → in progress")
    work.needMoreTime(memo, extraMinutes: 25, now: now)
    check(work.item(id: memo)?.state == .open && work.item(id: memo)?.slot == nil && work.item(id: memo)?.minutes == 25,
          "need more time: back to When with the new estimate; the worked block isn't marked for removal")
    work.postpone(memo, until: now.addingTimeInterval(86_400), now: now)
    check(!work.toPlace(now: now).contains { $0.id == memo } && work.toPlace(now: now.addingTimeInterval(90_000)).contains { $0.id == memo },
          "later / park: out of the queue until the given time")
    check(!work.allDone(loopId: loopId), "all done: not while items are open")
    for x in work.items(loopId: loopId) { work.markDone(x.id, now: now) }
    check(work.allDone(loopId: loopId) && !work.allDone(loopId: "no-such-loop"), "all done: every item done → offer to close the loop")

    // Isolation, buckets, header reset, wipe.
    let other = store.makeWorkItemsEngine(.init(account: "acct-B"), knowledge: k, promises: ledger)
    check(other.allItems().isEmpty && other.debugRowCounts().items == 0, "isolation: another account sees no work items")
    let sizes = store.debugWorkItemPayloadSizes()
    check(!sizes.isEmpty && Set(sizes).count == 1, "storage: sealed, bucket-padded payloads (one size: \(Set(sizes).count))")
    let before = work.allItems().count
    try? store.resetHeaders()
    check(work.allItems().count == before && before > 0, "header reset: work items survive (user data)")
    try? store.wipe()
    check(work.allItems().isEmpty && work.debugRowCounts() == (0, 0), "wipe: work items and dismissals are removed")

    runSlotFinderTests()
    await runFocusBlockTests()
}

@MainActor
func runSlotFinderTests() {
    section("Slot finder: buffers, overlaps, mornings, due dates, weekends, DST")
    var zh = Calendar(identifier: .gregorian); zh.timeZone = TimeZone(identifier: "Europe/Zurich")!
    func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date { zh.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))! }
    func iv(_ a: Date, _ b: Date) -> DateInterval { DateInterval(start: a, end: b) }
    func hm(_ d: Date) -> String { let c = zh.dateComponents([.hour, .minute], from: d); return String(format: "%02d:%02d", c.hour!, c.minute!) }
    let thu = at(2026, 11, 19, 9, 41)
    let fri = at(2026, 11, 20, 0)

    // Wireframe: busy until 10:00, next at 11:10 → "Thu 10:10 to 11:00".
    var p = SlotFinder.propose(minutes: 50, due: fri, busy: [iv(at(2026, 11, 19, 8, 30), at(2026, 11, 19, 10)), iv(at(2026, 11, 19, 11, 10), at(2026, 11, 19, 12))],
                               now: thu, calendar: zh)
    check(p.slots.first == iv(at(2026, 11, 19, 10, 10), at(2026, 11, 19, 11)) && p.slots.count == 3 && !p.nothingBeforeDue,
          "first slot after a 10-min buffer: Thu 10:10–11:00 (\(p.slots.first.map { hm($0.start) } ?? "-"))")
    // Buffers on both sides of every blocker.
    let busy1 = [iv(at(2026, 11, 19, 8, 30), at(2026, 11, 19, 10)), iv(at(2026, 11, 19, 11, 10), at(2026, 11, 19, 12))]
    let allSlots = SlotFinder.propose(minutes: 30, due: nil, busy: busy1, now: thu, calendar: zh, count: 20).slots
    check(allSlots.allSatisfy { s in busy1.allSatisfy { b in s.end.addingTimeInterval(600) <= b.start || s.start >= b.end.addingTimeInterval(600) } },
          "no slot within 10 minutes of a meeting (\(allSlots.count) checked)")
    // Overlapping busy merges.
    p = SlotFinder.propose(minutes: 30, due: nil, busy: [iv(at(2026, 11, 19, 8, 30), at(2026, 11, 19, 13)), iv(at(2026, 11, 19, 13), at(2026, 11, 19, 14)),
                                                         iv(at(2026, 11, 19, 13, 30), at(2026, 11, 19, 15))], now: thu, calendar: zh)
    check(p.slots.first?.start == at(2026, 11, 19, 15, 10), "overlapping meetings merge: first slot 15:10 (\(p.slots.first.map { hm($0.start) } ?? "-"))")
    // Mornings for deep work (due later), earliest for short work.
    let pmOnly = [iv(at(2026, 11, 19, 8, 30), at(2026, 11, 19, 13))]
    p = SlotFinder.propose(minutes: 50, due: at(2026, 11, 27, 0), busy: pmOnly, now: thu, calendar: zh)
    check(p.slots.first?.start == at(2026, 11, 20, 8, 30), "deep work prefers a morning: Fri 08:30 over Thu afternoon")
    p = SlotFinder.propose(minutes: 20, due: at(2026, 11, 27, 0), busy: pmOnly, now: thu, calendar: zh)
    check(p.slots.first?.start == at(2026, 11, 19, 13, 10), "short work takes the earliest slot: Thu 13:10")
    // Before due beats morning.
    p = SlotFinder.propose(minutes: 50, due: at(2026, 11, 19, 0), busy: pmOnly, now: thu, calendar: zh)
    check(p.slots.first?.start == at(2026, 11, 19, 13, 10) && !p.nothingBeforeDue, "due today: today's afternoon beats tomorrow's morning")
    // Nothing free before due → say so, still offer later slots.
    p = SlotFinder.propose(minutes: 50, due: at(2026, 11, 19, 0), busy: [iv(at(2026, 11, 19, 8), at(2026, 11, 19, 17))], now: thu, calendar: zh)
    check(p.nothingBeforeDue && p.slots.count == 3 && p.slots.allSatisfy { $0.start >= at(2026, 11, 20, 0) }, "nothing free before due: flagged, later slots offered")
    // Rounding: now 09:41 on a free morning → 09:45.
    p = SlotFinder.propose(minutes: 30, due: nil, busy: [], now: thu, calendar: zh)
    check(p.slots.first?.start == at(2026, 11, 19, 9, 45), "now 09:41 → first slot 09:45 (\(p.slots.first.map { hm($0.start) } ?? "-"))")
    // Focus blocks block like meetings.
    p = SlotFinder.propose(minutes: 30, due: nil, busy: [], focus: [iv(at(2026, 11, 19, 9, 45), at(2026, 11, 19, 12))], now: thu, calendar: zh)
    check(p.slots.first?.start == at(2026, 11, 19, 12, 10), "existing focus blocks are kept clear (12:10)")
    // Weekend skipped; end of Friday too short.
    p = SlotFinder.propose(minutes: 50, due: nil, busy: [], now: at(2026, 11, 20, 16, 30), calendar: zh)
    check(p.slots.first?.start == at(2026, 11, 23, 8, 30), "Fri 16:30 + 50 min doesn't fit: Monday 08:30, weekend skipped")
    // DST end (Sun 25 Oct 2026) and start (Sun 29 Mar 2026): 08:30 local on both sides.
    p = SlotFinder.propose(minutes: 50, due: nil, busy: [], now: at(2026, 10, 23, 16, 30), calendar: zh)
    check(p.slots.first.map { hm($0.start) } == "08:30" && p.slots.first.map { zh.component(.day, from: $0.start) } == 26,
          "DST end: Fri 23 Oct → Mon 26 Oct 08:30 local")
    let dstStart = SlotFinder.propose(minutes: 50, due: nil, busy: [], now: at(2026, 3, 27, 16, 30), calendar: zh, count: 2)
    check(dstStart.slots.map { hm($0.start) } == ["08:30", "08:30"] && dstStart.slots.map { zh.component(.day, from: $0.start) } == [30, 31],
          "DST start: Fri 27 Mar → Mon 30 Mar 08:30 local, then the next morning (deep work)")
    let short = SlotFinder.propose(minutes: 20, due: nil, busy: [], now: at(2026, 3, 30, 8, 0), calendar: zh, count: 2)
    check(short.slots.map { hm($0.start) } == ["08:30", "12:00"], "a long free day offers a morning and an afternoon start")
    // Working hours configurable; too long for a day.
    p = SlotFinder.propose(minutes: 30, due: nil, busy: [], hours: SlotHours(startMinute: 7 * 60, endMinute: 12 * 60), now: at(2026, 11, 19, 11, 45), calendar: zh)
    check(p.slots.first?.start == at(2026, 11, 20, 7), "configurable hours: 07:00–12:00 → next day 07:00")
    p = SlotFinder.propose(minutes: 9 * 60, due: nil, busy: [], now: thu, calendar: zh)
    check(p.tooLong && p.slots.isEmpty, "longer than a working day: says so, no slot")
    // Events → busy: free and cancelled don't block; an all-day busy item blocks the day.
    let evs = [CalendarEvent(id: "a", calendarId: "c", subject: "S", start: at(2026, 11, 19, 0), end: at(2026, 11, 20, 0), isAllDay: true),
               CalendarEvent(id: "f", calendarId: "c", subject: "S", start: at(2026, 11, 20, 8), end: at(2026, 11, 20, 17), showAs: .free),
               CalendarEvent(id: "x", calendarId: "c", subject: "S", start: at(2026, 11, 20, 8), end: at(2026, 11, 20, 12), isCancelled: true)]
    p = SlotFinder.propose(minutes: 30, due: nil, busy: SlotFinder.busy(from: evs, calendar: zh), now: thu, calendar: zh)
    check(p.slots.first?.start == at(2026, 11, 20, 8, 30), "all-day busy blocks Thu; free / cancelled Fri items don't")
    check(SlotFinder.busy(from: evs, excluding: ["a"], calendar: zh).isEmpty, "the item's own block can be excluded (reschedule)")
}

@MainActor
func runFocusBlockTests() async {
    section("Focus block: own calendar only, tentative, nobody invited, written only after confirm")
    let cals = [CalendarInfo(id: "boss", name: "Boss", ownerName: "B", ownerAddress: "b@x.example", mailboxPath: "/users/b", access: .delegated, canEdit: true, hexColor: nil, isDefault: true),
                CalendarInfo(id: "grp", name: "Team", ownerName: "G", ownerAddress: "g@x.example", mailboxPath: "/groups/1", access: .own, canEdit: true, hexColor: nil),
                CalendarInfo(id: "mine2", name: "Other", ownerName: "Me", ownerAddress: "me@x.example", mailboxPath: "/me", access: .own, canEdit: true, hexColor: nil),
                CalendarInfo(id: "mine", name: "Calendar", ownerName: "Me", ownerAddress: "me@x.example", mailboxPath: "/me", access: .own, canEdit: true, hexColor: nil, isDefault: true)]
    check(FocusBlockPlan.ownCalendar(cals)?.id == "mine", "calendar: the owner's own default calendar, never a principal's or a group's")
    check(FocusBlockPlan.ownCalendar(Array(cals.prefix(2))) == nil, "calendar: no own calendar → nothing to write to")
    check(FocusBlockPlan.subject(userTitle: nil) == "Focus block" && FocusBlockPlan.subject(userTitle: "Decision memo") == "Focus: Decision memo",
          "subject: neutral unless the user typed the title")
    let slot = DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 3000)
    let plan = FocusBlockPlan(calendarId: "mine", subject: FocusBlockPlan.subject(userTitle: nil), slot: slot, replacing: "old-1")
    let j = plan.draft.graphJSON()
    check((j["attendees"] as? [Any])?.isEmpty == true && j["showAs"] as? String == "tentative" && j["isOnlineMeeting"] == nil && j["body"] == nil,
          "draft: no attendees, tentative, no Teams link, no body")
    let w = RecordingFocusWriter()
    let pending = PendingFocusBlock(workItemId: "wi", plan: plan)
    check(await w.created.isEmpty, "confirm gate: picking a slot writes nothing")
    let res = try? await pending.confirm(using: w)
    let id = res?.eventId
    let created = await w.created, removed = await w.removed
    check(id == "local-1" && created.count == 1 && created.first?.attendees.isEmpty == true && created.first?.calendarId == "mine",
          "confirm: exactly one tentative block on my calendar")
    check(removed == ["old-1"] && res?.replacedRemoved == true, "confirm: a rescheduled block replaces the old one (delete, no attendees to notify)")
    var gonePlan = plan; gonePlan.replacing = "gone-1"; gonePlan.labelId = "lbl"; gonePlan.labelHeader = "MSIP_Label_x"
    let res2 = try? await PendingFocusBlock(workItemId: "wi", plan: gonePlan).confirm(using: w)
    let createdNow = await w.created.count
    check(res2?.replacedRemoved == false && createdNow == 2,"confirm: an old block that can't be removed is reported, not hidden")
    check(gonePlan.draft.labelId == "lbl" && (gonePlan.draft.graphJSON()["singleValueExtendedProperties"] as? [Any])?.count == 1,
          "draft: the default meeting label is stamped like the event editor's")
}
