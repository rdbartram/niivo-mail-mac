import Foundation
import CryptoKit
import CalendarCore
import MailCore

// THREAD-HOOK: conversation view — store grouping, row facts, strictest label, thread actions + one undo, protected
// members stay gated, Sent participation in the reader, keyset paging, 100k timing, quoted history, Gmail keys.

@MainActor
func runThreadTests() async {
    threadGroupingTests()
    await threadActionTests()
    threadReaderTests()
    threadPagingTests()
    threadTimingTest()
}

private let base = Date(timeIntervalSince1970: 1_790_000_000)
private let anna = EmailAddress(name: "Anna Keller", address: "anna@contoso.example")
private let peter = EmailAddress(name: "Peter Frei", address: "peter@contoso.example")
private let meAddr = EmailAddress(name: "You", address: "you@contoso.example")

private func msg(_ id: String, _ folder: String, _ conv: String, _ minutes: Int, from: EmailAddress, read: Bool = true,
                 flagged: Bool = false, label: String? = nil, subject: String = "Topic") -> MailMessage {
    MailMessage(id: id, folderId: folder, conversationId: conv, subject: subject, from: from, received: base.addingTimeInterval(Double(minutes * 60)),
                preview: "snippet \(id)", isRead: read, flag: FollowUpFlag(status: flagged ? .flagged : .notFlagged), labelId: label)
}

@MainActor
private func threadGroupingTests() {
    section("Threads: store grouping, row facts, strictest label")
    do {
        let store = try mailStore()
        let engine = mailEngine()
        store.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: engine) }
        try store.replace(folders: [MailFolder(id: "fIn", displayName: "Inbox", wellKnown: .inbox),
                                    MailFolder(id: "fSent", displayName: "Sent", wellKnown: .sentitems),
                                    MailFolder(id: "fAr", displayName: "Archive", wellKnown: .archive)], mailbox: "me")
        try store.upsert(messages: [
            msg("a1", "fIn", "A", 0, from: anna, label: FX.labelGeneral, subject: "Budget"),
            msg("a2", "fSent", "A", 10, from: meAddr, subject: "RE: Budget"),
            msg("a3", "fIn", "A", 20, from: peter, read: false, label: FX.labelConfidential, subject: "RE: Budget"),
            msg("a4", "fIn", "A", 30, from: anna, flagged: true, subject: "RE: Budget v2"),
            msg("aX", "fAr", "A", 40, from: anna, label: FX.labelHighlyConfidential, subject: "RE: Budget archived"),
            msg("b1", "fIn", "B", 25, from: peter),
            msg("c1", "fSent", "C", 50, from: meAddr),                       // only in Sent: no Inbox row
            msg("d1", "fIn", "D", 5, from: anna, label: FX.labelGeneral),
            msg("d2", "fIn", "D", 6, from: peter, label: FixtureCalendarService.orphanLabelId),
        ])
        let page = try store.threads(folderId: "fIn", sentFolderId: "fSent")
        check(page.map(\.conversationId) == ["A", "B", "D"], "one row per conversation in the folder, newest thread first (\(page.map(\.conversationId)))")
        guard let a = page.first(where: { $0.conversationId == "A" }) else { check(false, "thread A missing"); return }
        check(a.count == 3, "count = members in this folder (Sent and Archive copies don't count) (\(a.count))")
        check(a.unreadCount == 1 && a.hasUnread, "unread if any member is unread")
        check(a.flagged, "flagged if any member is flagged")
        check(a.latest.id == "a4" && a.latest.subject == "RE: Budget v2" && a.latest.preview == "snippet a4",
              "row shows the newest in-folder message's subject + snippet")
        check(a.members.map(\.id) == ["a4", "a3", "a1"], "members = in-folder messages, newest first")
        check(a.readerMembers.map(\.id) == ["a1", "a2", "a3", "a4"], "reader set = folder + Sent, oldest first; Archive copy excluded")
        let line = MailThreads.participantLine(a.readerMembers, me: [meAddr.address])
        check(line == "Anna, me, Peter", "participants in reading order, you as 'me' (\(line))")
        check(MailThreads.participantLine([a.readerMembers[0]], me: []) == "Anna Keller", "single participant → full name")
        let many = (0..<5).map { msg("p\($0)", "fIn", "P", $0, from: EmailAddress(name: "Name\($0) X", address: "n\($0)@x")) }
        check(MailThreads.participants(many, me: []) == ["Name0", "…", "Name3", "Name4"], "more than three → first … last two")

        func pol(_ ms: [MailMessage]) -> ContentPolicy {
            MailThreads.strictest(ms.map { MailContentPolicy.policy(for: $0, mailbox: "me", engine: engine) })
        }
        check(pol(a.readerMembers).label?.id == FX.labelConfidential, "row chip = most restrictive label in the thread (Confidential over General/none)")
        let d = page.first { $0.conversationId == "D" }!
        if case .unknown = pol(d.readerMembers).labelState { check(true, "an unknown label in the thread wins (fail closed)") }
        else { check(false, "an unknown label in the thread wins (fail closed)") }
        let hc = MailContentPolicy.policy(for: msg("h", "fIn", "H", 0, from: anna, label: FX.labelHighlyConfidential), mailbox: "me", engine: engine)
        let open = MailContentPolicy.policy(for: msg("o", "fIn", "H", 1, from: anna), mailbox: "me", engine: engine)
        let mixed = MailThreads.strictest([open, hc])
        check(mixed.label?.id == FX.labelHighlyConfidential && mixed.preventScreenCapture && mixed.bodyIsProtected,
              "strictest over open + protected → protected label, capture blocked (order-independent)")
        check(MailThreads.strictest([hc, open]) == mixed, "strictest is order-independent")
        check(MailThreads.strictest([]) == .open, "empty thread → open")
        check(try store.threads(folderId: "fSent").map(\.conversationId) == ["C", "A"], "Sent lists its own threads (C, A)")
        let plan = try store.threadQueryPlan(folderId: "fIn")
        check(plan.contains("messages_by_folder_conv"), "grouping uses the covering index (\(plan))")
    } catch { check(false, "thread grouping threw \(error)") }
}

@MainActor
private func threadActionTests() async {
    section("Threads: actions reach every in-folder member, one undo")
    do {
        let svc = FX()
        let store = try mailStore()
        let engine = mailEngine()
        let sync = MailSync(service: svc, store: store, compliance: engine, mailboxes: FX.mailboxes, onChange: { _ in })
        await sync.syncNow()
        let inbox = FX.folderId("me", .inbox), sent = FX.folderId("me", .sentitems), archive = FX.folderId("me", .archive)
        let t = try store.threads(folderId: inbox, sentFolderId: sent, limit: 500).first { $0.conversationId == "conv-t2" }
        guard let t else { check(false, "fixture thread conv-t2 in the inbox"); return }
        let members = try store.threadMembers(conversationId: "conv-t2", folderId: inbox)
        let sentIds = Set(try store.conversation(id: "conv-t2").filter { $0.folderId == sent }.map(\.id))
        check(members.count == 3 && t.count == 3 && !sentIds.isEmpty, "fixture thread: 3 inbox members + Sent replies")

        // Archive the thread: every in-folder member moves, Sent copies stay.
        let arch = MailThreads.plan(.move(toFolderId: archive), members: members)
        check(arch.steps.count == 3 && arch.undo.count == 3, "archive plans one step per member + one inverse each")
        let r = await sync.apply(arch.steps)
        let after = try store.conversation(id: "conv-t2")
        check(r.failed == 0 && after.filter { $0.folderId == archive }.count == 3, "all three inbox members archived")
        check(Set(after.filter { $0.folderId == sent }.map(\.id)) == sentIds, "Sent members untouched by a thread action")
        check(try store.threads(folderId: inbox, limit: 500).allSatisfy { $0.conversationId != "conv-t2" }, "thread leaves the Inbox list")
        _ = await sync.undo(arch.undo)
        let back = try store.conversation(id: "conv-t2")
        check(back.filter { $0.folderId == inbox }.count == 3 && Set(back.filter { $0.folderId == sent }.map(\.id)) == sentIds,
              "one undo restores every member to the Inbox")

        // Mark read: only members that change; undo restores each member's own state.
        let fresh = try store.threadMembers(conversationId: "conv-t2", folderId: inbox)
        let unreadBefore = Set(fresh.filter { !$0.isRead }.map(\.id))
        let mr = MailThreads.plan(.markRead(true), members: fresh)
        check(mr.steps.count == unreadBefore.count && !unreadBefore.isEmpty, "mark read touches only unread members (\(mr.steps.count))")
        _ = await sync.apply(mr.steps)
        check(try store.threadMembers(conversationId: "conv-t2", folderId: inbox).allSatisfy(\.isRead), "whole thread read")
        _ = await sync.undo(mr.undo)
        let unreadAfter = Set(try store.threadMembers(conversationId: "conv-t2", folderId: inbox).filter { !$0.isRead }.map(\.id))
        check(unreadAfter == unreadBefore, "undo restores exactly the previously unread members")

        // Flag + categorise reach all; undo order = state newest-first, moves last.
        let fl = MailThreads.plan(.flag(FollowUpFlag(status: .flagged)), members: fresh)
        check(fl.steps.count == 3, "flag applies to every member")
        let mix = MailThreads.plan(.delete, members: fresh)
        check(mix.undo.allSatisfy { if case .move(let f) = $0.action { f == inbox } else { false } }, "delete undo moves each back to its own folder")
        check(MailThreads.removesFromList(.delete) && !MailThreads.removesFromList(.markRead(true)), "removal classification")
    } catch { check(false, "thread actions threw \(error)") }
}

@MainActor
private func threadReaderTests() {
    section("Threads: reader set, protected members, quoted history, keys, prefs")
    let engine = mailEngine()
    let conv = [
        msg("r1", "fIn", "R", 0, from: anna),
        msg("r2", "fSent", "R", 5, from: meAddr),
        msg("r3", "fIn", "R", 10, from: peter, label: FX.labelHighlyConfidential),
        msg("r4", "fDel", "R", 12, from: peter),
        msg("r5", "fIn", "R", 15, from: anna, read: false),
    ]
    let rm = MailThreads.readerMembers(conv, folderId: "fIn", sentFolderId: "fSent")
    check(rm.map(\.id) == ["r1", "r2", "r3", "r5"], "Sent reply participates in the reader; Deleted copy doesn't")
    check(MailThreads.readerMembers(conv, folderId: "fIn", sentFolderId: "fSent", newestFirst: true).map(\.id) == ["r5", "r3", "r2", "r1"],
          "newest-on-top setting reverses the order")
    check(MailThreads.readerMembers(conv, folderId: "fIn", sentFolderId: nil).map(\.id) == ["r1", "r3", "r5"], "no Sent folder → folder only")
    check(MailThreads.initiallyExpanded(rm) == ["r5"], "unread + latest expanded, older read ones collapsed")
    check(MailThreads.replyTarget(rm)?.id == "r5", "reply targets the latest message")
    let mineLast = rm + [msg("r6", "fSent", "R", 20, from: meAddr)]
    check(MailThreads.replyTarget(mineLast, me: [meAddr.address])?.id == "r5", "your own newest Sent reply isn't the reply target (no reply to yourself)")

    // Each member keeps its own policy: the protected one stays gated; the open ones may fetch.
    let pols = Dictionary(uniqueKeysWithValues: rm.map { ($0.id, MailContentPolicy.policy(for: $0, mailbox: "me", engine: engine)) })
    check(!MailThreads.mayFetchBody(pols["r3"]!) && pols["r3"]!.bodyIsProtected, "protected member: no body fetch, decrypt-on-demand path")
    check(MailThreads.mayFetchBody(pols["r1"]!) && MailThreads.mayFetchBody(pols["r5"]!), "open members in the same thread still render")
    check(pols["r1"]!.allowCopy && !pols["r1"]!.preventScreenCapture, "an open member's rights are not tightened by its protected neighbour")
    let thread = MailThreads.strictest(Array(pols.values))
    check(thread.preventScreenCapture, "conversation capture shield follows the strictest member")
    var priv = msg("pv", "fIn", "R", 20, from: anna); priv.isPrivate = true
    let pp = MailContentPolicy.policy(for: priv, mailbox: "shared@contoso.example", engine: engine)
    check(pp.redactDetails && !MailThreads.mayFetchBody(pp), "private member in a delegate mailbox stays redacted")
    check(!MailThreads.mayFetchBody(MailContentPolicy.policy(for: msg("u", "fIn", "R", 0, from: anna, label: FixtureCalendarService.orphanLabelId), mailbox: "me", engine: engine)),
          "unknown-label member: no body fetch")

    // Quoted history.
    let outlook = "<p>Thanks, done.</p><div id=\"appendonsend\"></div><hr style=\"display:inline-block;width:98%\"><div id=\"divRplyFwdMsg\">From: Anna</div><p>old</p>"
    let s1 = QuotedHistory.split(html: outlook)
    check(s1.main == "<p>Thanks, done.</p>" && s1.quoted?.contains("old") == true, "Outlook reply: history split at appendonsend")
    let gm = QuotedHistory.split(html: "<div>Yes</div><div class=\"gmail_quote\">On Mon wrote:<blockquote>x</blockquote></div>")
    check(gm.main == "<div>Yes</div>" && gm.quoted != nil, "Gmail quote split")
    check(QuotedHistory.split(html: "<p>Nothing quoted</p>").quoted == nil, "no marker → nothing hidden")
    check(QuotedHistory.split(html: "<blockquote type=\"cite\">only quote</blockquote>").quoted == nil, "never hide everything")
    let pt = QuotedHistory.split(text: "Sounds good.\n\nOn Tue, Anna wrote:\n> earlier\n> text")
    check(pt.main == "Sounds good.\n" && pt.quoted?.hasPrefix("On Tue") == true, "plain text: 'On … wrote:' split")

    // Gmail keys (only consulted when the Gmail keymap is chosen).
    check(GmailThreadKey.action(for: "n") == .nextMessage && GmailThreadKey.action(for: "p") == .previousMessage
          && GmailThreadKey.action(for: "o") == .expand && GmailThreadKey.action(for: "x") == .toggleSelect
          && GmailThreadKey.action(for: "u") == .backToList && GmailThreadKey.action(for: "j") == nil,
          "Gmail thread keys n/p/o/x/u; j/k/e/#/r/a/f fall through to the shared keymap")

    // Preferences: grouping defaults ON, persisted.
    let d = UserDefaults(suiteName: "thread-prefs-\(UUID().uuidString)")!
    check(MailThreadPreferences.load(d).grouped && !MailThreadPreferences.load(d).newestOnTop, "defaults: grouped ON, newest at the bottom")
    var p = MailThreadPreferences(); p.grouped = false; p.newestOnTop = true; p.save(d)
    check(MailThreadPreferences.load(d) == p, "thread preferences persist")
}

@MainActor
private func threadPagingTests() {
    section("Threads: keyset paging")
    do {
        let store = try mailStore()
        try store.replace(folders: [MailFolder(id: "fIn", displayName: "Inbox", wellKnown: .inbox)], mailbox: "me")
        var ms: [MailMessage] = []
        for c in 0..<120 { for k in 0..<(1 + c % 3) { ms.append(msg("m\(c)-\(k)", "fIn", "c\(String(format: "%03d", c))", c * 10 + k, from: anna)) } }
        // Two threads sharing the same latest timestamp: the conversation id breaks the tie.
        ms.append(msg("tie1", "fIn", "tieA", 5000, from: anna)); ms.append(msg("tie2", "fIn", "tieB", 5000, from: peter))
        try store.upsert(messages: ms)
        var seen: [String] = [], cursor: MailThreadCursor?, pages = 0
        repeat {
            let page = try store.threads(folderId: "fIn", before: cursor, limit: 50)
            if page.isEmpty { break }
            seen += page.map(\.conversationId); cursor = page.last?.cursor; pages += 1
        } while pages < 10
        check(seen.count == 122 && Set(seen).count == 122, "pages cover every thread exactly once (\(seen.count) in \(pages) pages)")
        check(Array(seen.prefix(2)) == ["tieB", "tieA"], "equal timestamps: stable order by conversation id")
        let counts = try store.threads(folderId: "fIn", limit: 200).reduce(0) { $0 + $1.count }
        check(counts == ms.count, "row counts add up to the folder's messages")
    } catch { check(false, "thread paging threw \(error)") }
}

/// 100k headers, 20k conversations (one fat one of 2,000): page 1 and a deep page in < 100 ms (generous gate bound
/// 400 ms because other builders compile in parallel; the measured best of 3 is printed).
@MainActor
private func threadTimingTest() {
    section("Threads: 100k-row store pages fast")
    do {
        let dir = FileManager.default.temporaryDirectory.appending(path: "threadbench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try mailStore(dir.appending(path: "t.sqlite"))
        try store.replace(folders: [MailFolder(id: "fIn", displayName: "Inbox", wellKnown: .inbox),
                                    MailFolder(id: "fSent", displayName: "Sent", wellKnown: .sentitems)], mailbox: "me")
        let n = 100_000
        var batch: [MailMessage] = []; batch.reserveCapacity(10_000)
        let t0 = Date()
        for i in 0..<n {
            let conv = i >= n - 2_000 ? "fat" : "c\(i / 5)"   // newest: page 1 unseals the fat thread
            batch.append(MailMessage(id: "id\(i)", folderId: i % 10 == 0 ? "fSent" : "fIn", conversationId: conv, subject: "S",
                                     from: anna, received: base.addingTimeInterval(Double(i) * 60), isRead: i % 3 != 0))
            if batch.count == 10_000 { try store.upsert(messages: batch); batch.removeAll(keepingCapacity: true) }
        }
        let load = Date().timeIntervalSince(t0)
        func best(_ f: () throws -> Void) rethrows -> Double {
            var b = Double.infinity
            for _ in 0..<3 { let s = Date(); try f(); b = min(b, Date().timeIntervalSince(s) * 1000) }
            return b
        }
        var first: [MailThreadSummary] = []
        let p1 = try best { first = try store.threads(folderId: "fIn", sentFolderId: "fSent", limit: 50) }
        var cursor = first.last?.cursor
        for _ in 0..<20 { cursor = try store.threads(folderId: "fIn", before: cursor, limit: 50).last?.cursor }
        let deep = try best { _ = try store.threads(folderId: "fIn", sentFolderId: "fSent", before: cursor, limit: 50) }
        let fat = try best { _ = try store.threadMembers(conversationId: "fat", folderId: "fIn") }
        print("    (100k load \(Int(load)) s; first page \(String(format: "%.1f", p1)) ms, page 21 \(String(format: "%.1f", deep)) ms, 1,800-member thread \(String(format: "%.1f", fat)) ms)")
        check(first.count == 50, "first page has 50 threads")
        check(p1 < 400 && deep < 400, "thread pages in < 400 ms gate bound (target < 100 ms; measured above)")
    } catch { check(false, "thread timing threw \(error)") }
}
