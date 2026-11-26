import Foundation
import CryptoKit
import CalendarCore
import MailCore

// Message-list organisation: bulk plans, undo id remap after a Graph move, sweep, master categories, smart views,
// search scope across mailboxes, unified inbox ordering, search memory.

@MainActor
func runOrganiseTests() async {
    organiseBulkTests()
    await organiseUndoRemapTests()
    await organiseGraphShapeTests()
    organiseSweepAndSmartTests()
    await organiseSearchScopeTests()
    organiseUnifiedInboxTests()
}

private func om(_ id: String, folder: String, read: Bool = false, flagged: Bool = false, cats: [String] = [],
                from: String = "a@contoso.example", to: [String] = [], received: Date = Date(timeIntervalSince1970: 1_800_000_000),
                attach: Bool = false, due: Date? = nil) -> MailMessage {
    MailMessage(id: id, folderId: folder, conversationId: "c-\(id)", subject: "S \(id)", from: EmailAddress(name: "A", address: from),
                toRecipients: to.map { EmailAddress(name: "", address: $0) }, received: received, isRead: read,
                flag: FollowUpFlag(status: flagged ? .flagged : .notFlagged, due: due), categories: cats, hasAttachments: attach)
}

@MainActor
func organiseBulkTests() {
    section("Organise: bulk plans")
    let wk: (WellKnownFolder, String) -> String? = { w, mb in
        switch w { case .archive: "\(mb)-archive"; case .deleteditems: "\(mb)-deleted"; default: nil }
    }
    let t = [
        BulkTarget(message: om("1", folder: "me-inbox", read: false, cats: ["Finance"]), mailbox: "me"),
        BulkTarget(message: om("2", folder: "me-inbox", read: true, flagged: true), mailbox: "me"),
        BulkTarget(message: om("3", folder: "me-archive", read: false), mailbox: "me"),
        BulkTarget(message: om("4", folder: "sh-inbox", read: false), mailbox: "shared@contoso.example"),
    ]
    let read = BulkPlanner.plan(.markRead(true), targets: t, folder: wk)
    check(read.steps.map(\.messageId) == ["1", "3", "4"] && read.skipped == 1 && !read.removesFromList, "mark read skips already-read")
    let arch = BulkPlanner.plan(.archive, targets: t, folder: wk)
    check(arch.steps.count == 3 && arch.skipped == 1 && arch.removesFromList, "archive skips the one already in Archive")
    check(arch.steps.first { $0.messageId == "4" }?.action == .move(toFolderId: "shared@contoso.example-archive"),
          "archive uses each message's own mailbox Archive")
    let move = BulkPlanner.plan(.move(folderId: "me-projects", mailbox: "me"), targets: t, folder: wk)
    check(move.steps.map(\.messageId) == ["1", "2", "3"] && move.skipped == 1, "move skips the other mailbox (Graph can't cross)")
    let add = BulkPlanner.plan(.addCategory("finance"), targets: t, folder: wk)
    check(add.steps.count == 3 && !add.steps.contains { $0.messageId == "1" }, "add category is case-insensitive and skips holders")
    check(add.steps.first?.action == .categorize(["Finance"]) || add.steps.contains { $0.action == .categorize(["finance"]) },
          "add category appends to the existing list")
    let rem = BulkPlanner.plan(.removeCategory("Finance"), targets: t, folder: wk)
    check(rem.steps == [BulkStep(messageId: "1", action: .categorize([]))], "remove category touches only holders")
    let flag = BulkPlanner.plan(.flag(BulkPlanner.shouldFlag(t.map(\.message))), targets: t, folder: wk)
    check(flag.steps.count == 3 && flag.skipped == 1, "flag toggle: mixed selection flags the rest")
    check(BulkPlanner.shouldMarkRead(t.map(\.message)), "mixed selection marks read")
    let del = BulkPlanner.plan(.delete, targets: [BulkTarget(message: om("9", folder: "me-deleted"), mailbox: "me")], folder: wk)
    check(del.steps.isEmpty && del.skipped == 1, "delete skips messages already in Deleted Items")
    check(BulkPlanner.describe(.archive, count: 3) == "Archived 3 messages", "bulk toast text")
}

@MainActor
func organiseUndoRemapTests() async {
    section("Organise: undo after a Graph move follows the new id")
    MailStub.lock.withLock { MailStub.log.removeAll() }
    MailStub.handler = { req, _ in
        switch (req.httpMethod ?? "GET", req.url!.path) {
        case ("POST", "/v1.0/me/messages/A/move"): return (201, [:], gmsg("B", folder: "fAr"))
        case ("POST", "/v1.0/me/messages/B/move"): return (201, [:], gmsg("C", folder: "fIn"))
        case ("POST", "/v1.0/me/messages/X/move"): return (201, [:], gmsg("X2", folder: "fAr"))
        case ("POST", "/v1.0/me/messages/Y/move"): return (201, [:], gmsg("Y2", folder: "fAr"))
        case ("POST", "/v1.0/me/messages/X2/move"): return (201, [:], gmsg("X3", folder: "fIn"))
        case ("POST", "/v1.0/me/messages/Y2/move"): return (201, [:], gmsg("Y3", folder: "fIn"))
        default: return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let svc = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
    do {
        let store = try mailStore()
        try store.upsert(folder: MailFolder(id: "fIn", displayName: "Inbox", wellKnown: .inbox, mailbox: "me"))
        try store.upsert(folder: MailFolder(id: "fAr", displayName: "Archive", wellKnown: .archive, mailbox: "me"))
        for id in ["A", "X", "Y"] { try store.upsert(message: om(id, folder: "fIn")) }
        let sync = MailSync(service: svc, store: store, compliance: mailEngine(), onChange: { _ in })
        try await sync.perform(.move(toFolderId: "fAr"), on: "A")
        let idAfterMove = await sync.currentId("A")
        check(idAfterMove == "B", "move response's new id is recorded (A → B)")
        let oldGone = try store.message(id: "A", includeBody: false) == nil
        let newFolder = try store.message(id: "B", includeBody: false)?.folderId
        check(oldGone && newFolder == "fAr", "store re-keyed to the moved id")
        // What MailModel.undo does: the entry still holds "A".
        let r = await sync.undo([BulkStep(messageId: "A", action: .move(toFolderId: "fIn"))])
        check(r.done == 1 && r.failed == 0, "undo succeeds instead of 404 on the stale id")
        let posts = MailStub.captured().filter { $0.method == "POST" }.map(\.path)
        check(posts == ["/v1.0/me/messages/A/move", "/v1.0/me/messages/B/move"], "undo moves the NEW id back (\(posts.count) POSTs)")
        let cFolder = try store.message(id: "C", includeBody: false)?.folderId
        let idAfterUndo = await sync.currentId("A")
        check(cFolder == "fIn" && idAfterUndo == "C", "chain followed: A → B → C, back in the Inbox")
        // Grouped bulk undo: two moved messages, one ⌘Z.
        let moved = await sync.apply([BulkStep(messageId: "X", action: .move(toFolderId: "fAr")),
                                      BulkStep(messageId: "Y", action: .move(toFolderId: "fAr"))])
        check(moved.done == 2, "bulk apply moves both")
        let u = await sync.undo([BulkStep(messageId: "X", action: .move(toFolderId: "fIn")), BulkStep(messageId: "Y", action: .move(toFolderId: "fIn"))])
        let x3 = try store.message(id: "X3", includeBody: false)?.folderId, y3 = try store.message(id: "Y3", includeBody: false)?.folderId
        check(u.done == 2 && x3 == "fIn" && y3 == "fIn", "grouped undo restores every message of a bulk move")
    } catch { check(false, "undo remap threw \(error)") }
}

@MainActor
func organiseGraphShapeTests() async {
    section("Organise: master categories, mentions, sweep rule request shapes")
    MailStub.lock.withLock { MailStub.log.removeAll() }
    MailStub.handler = { req, _ in
        let path = req.url!.path, m = req.httpMethod ?? "GET"
        switch (m, path) {
        case ("GET", "/v1.0/me/outlook/masterCategories"):
            return (200, [:], #"{"value":[{"id":"c1","displayName":"Finance","color":"preset4"},{"id":"c2","displayName":"Odd","color":"none"}]}"#)
        case ("POST", "/v1.0/me/outlook/masterCategories"), ("POST", "/v1.0/users/support@contoso.example/outlook/masterCategories"):
            return (201, [:], #"{"id":"c3","displayName":"Legal","color":"preset7"}"#)
        case ("PATCH", "/v1.0/me/outlook/masterCategories/c1"): return (200, [:], #"{"id":"c1","displayName":"Finance","color":"preset15"}"#)
        case ("DELETE", "/v1.0/me/outlook/masterCategories/c2"): return (204, [:], "")
        case ("GET", "/beta/me/messages"): return (200, [:], #"{"value":[{"id":"m1"},{"id":"m2"}]}"#)
        case ("POST", "/v1.0/me/mailFolders/inbox/messageRules"):
            return (201, [:], #"{"id":"r1","displayName":"Sweep","sequence":1,"isEnabled":true,"conditions":{},"actions":{"delete":true},"hasError":false,"isReadOnly":false}"#)
        default: return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let svc = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
    func json(_ d: Data?) -> [String: Any] { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
    do {
        let list = try await svc.masterCategories(mailbox: "me")
        check(list.count == 2 && list[0].color.raw == "preset4" && list[0].color.name == "Green" && list[1].color.hex == nil,
              "list decodes presets (preset4 = Green, none = no colour)")
        let created = try await svc.createCategory(displayName: "Legal", color: CategoryColor("preset7"), mailbox: "me")
        let post = MailStub.captured().last!
        check(post.method == "POST" && json(post.body)["displayName"] as? String == "Legal" && json(post.body)["color"] as? String == "preset7"
              && created.id == "c3", "create POSTs displayName + color")
        _ = try await svc.setCategoryColor(id: "c1", color: CategoryColor("preset15"), mailbox: "me")
        let patch = MailStub.captured().last!
        check(patch.method == "PATCH" && json(patch.body).keys.sorted() == ["color"], "recolour PATCHes only color (displayName is read-only)")
        try await svc.deleteCategory(id: "c2", mailbox: "me")
        check(MailStub.captured().last?.method == "DELETE" && MailStub.captured().last?.path == "/v1.0/me/outlook/masterCategories/c2",
              "delete hits the category")
        _ = try await svc.createCategory(displayName: "Legal", color: CategoryColor("preset7"), mailbox: "support@contoso.example")
        check(MailStub.captured().last?.path == "/v1.0/users/support@contoso.example/outlook/masterCategories", "other mailbox → /users/{id}")
        let ids = try await svc.mentionedMessageIds(mailbox: "me", top: 50)
        let q = MailStub.captured().last!.query.removingPercentEncoding ?? ""
        check(ids == ["m1", "m2"] && q.contains("mentionsPreview/isMentioned eq true") && q.contains("$select=id"),
              "mentions: beta filter, ids only")
        // Sweep "always" → messageRule.
        let rule = Sweep.rule(sender: EmailAddress(name: "N", address: "news@fabrikam.example"), mode: .all, action: .delete)!
        _ = try await svc.saveRule(rule, mailbox: "me")
        let rb = json(MailStub.captured().last!.body)
        let from = ((rb["conditions"] as? [String: Any])?["fromAddresses"] as? [[String: Any]])?.first?["emailAddress"] as? [String: Any]
        check(from?["address"] as? String == "news@fabrikam.example" && (rb["actions"] as? [String: Any])?["delete"] as? Bool == true,
              "sweep rule POST: fromAddresses + delete")
    } catch { check(false, "graph shapes threw \(error)") }
    // Rename = create + retag + delete (displayName can't change).
    let msgs = [om("1", folder: "f", cats: ["Finance", "VIP"]), om("2", folder: "f", cats: ["VIP"]), om("3", folder: "f", cats: ["finance", "Legal"])]
    let steps = MasterCategories.retag(msgs, from: "Finance", to: "Legal")
    check(steps == [BulkStep(messageId: "1", action: .categorize(["Legal", "VIP"])), BulkStep(messageId: "3", action: .categorize(["Legal"]))],
          "rename re-tags holders only, de-duplicated")
    let existing = [OutlookCategory(id: "1", displayName: "Finance", color: .none)]
    check((try? MasterCategories.validate(name: " finance ", existing: existing)) == nil, "duplicate name refused (case-insensitive)")
    check((try? MasterCategories.validate(name: "  New  ", existing: existing)) == "New", "name trimmed")
    check(MasterCategories.hex(for: "FINANCE", in: [OutlookCategory(id: "1", displayName: "Finance", color: CategoryColor("preset0"))]) != nil,
          "row colour comes from the master list")
}

@MainActor
func organiseSweepAndSmartTests() {
    section("Organise: sweep selection, smart views, virtual ids, search memory")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day = 86_400.0
    let msgs = [om("n", folder: "f", from: "News@x.example", received: now - 1 * day),
                om("o", folder: "f", from: "news@x.example", received: now - 20 * day),
                om("p", folder: "f", from: "news@x.example", received: now - 40 * day),
                om("q", folder: "f", from: "other@x.example", received: now)]
    check(Sweep.select(msgs, sender: "news@x.example", mode: .all, now: now).map(\.id) == ["n", "o", "p"], "sweep all: sender only, case-insensitive")
    check(Sweep.select(msgs, sender: "news@x.example", mode: .keepLatest, now: now).map(\.id) == ["o", "p"], "sweep keeps the latest")
    check(Sweep.select(msgs, sender: "news@x.example", mode: .olderThan(days: 10), now: now).map(\.id) == ["o", "p"], "sweep older than N days")
    check(Sweep.rule(sender: EmailAddress(name: "", address: "n@x"), mode: .keepLatest, action: .delete) == nil,
          "no rule for keep-latest (messageRule has no such predicate)")
    let mv = Sweep.rule(sender: EmailAddress(name: "", address: "n@x"), mode: .all, action: .move(folderId: "f9", folderName: "News"))
    check(mv?.actions.moveToFolder == "f9" && mv?.conditions.fromAddresses.first?.address == "n@x", "move rule shape")

    let me: Set<String> = ["you@contoso.example"]
    let a = om("a", folder: "f", read: false, flagged: true, to: ["You@contoso.example"], attach: true, due: now)
    let b = om("b", folder: "f", read: true, to: ["x@y"])
    check(SmartView.unread.matches(a, me: me) && !SmartView.unread.matches(b, me: me), "unread")
    check(SmartView.toMe.matches(a, me: me) && !SmartView.toMe.matches(b, me: me), "to me (direct To, case-insensitive)")
    check(SmartView.attachments.matches(a, me: me) && SmartView.flagged.matches(a, me: me), "attachments + flagged")
    check(SmartView.dueToday.matches(a, me: me, now: now) && !SmartView.dueToday.matches(b, me: me, now: now), "due today")
    check(SmartView.mentions.matches(a, me: me, mentioned: ["a"]) && !SmartView.mentions.matches(b, me: me, mentioned: ["a"]),
          "mentions come from the server id set only")
    for v in [VirtualFolder.unifiedInbox, .smart(.toMe, mailbox: "support@contoso.example")] {
        check(VirtualFolder(id: v.id) == v, "virtual id round-trips (\(v.title))")
    }
    check(VirtualFolder(id: "AAMkAGI2") == nil, "a Graph folder id is never virtual")

    var mem = SearchMemory()
    for q in ["in", "inv", "invoice", "budget"] { mem.remember(q) }
    check(mem.recent == ["budget", "invoice"], "typing collapses into one recent entry (\(mem.recent))")
    for i in 0..<15 { mem.remember("query number \(i) x\(i)") ; mem.remember("zz\(i)") }
    check(mem.recent.count == SearchMemory.maxRecent, "recent capped at \(SearchMemory.maxRecent)")
    mem.save(.init(name: "Invoices", query: "invoice", scope: .allMailboxes))
    if let store = try? mailStore() {
        mem.persist(store)
        let back = SearchMemory.load(store)
        check(back == mem, "search memory round-trips through the sealed store")
        check(((try? store.value(for: SearchMemory.key)) ?? nil).map { !$0.contains("invoice") } ?? false, "stored sealed, not plaintext")
    }
}

@MainActor
func organiseSearchScopeTests() async {
    section("Organise: search scope across mailboxes")
    do {
        let svc = FX()
        let store = try mailStore()
        let sync = MailSync(service: svc, store: store, compliance: mailEngine(), mailboxes: FX.mailboxes, onChange: { _ in })
        await sync.syncNow()
        let shared = try await svc.message(id: FX.Special.sharedInbox, mailbox: FX.sharedMailbox)
        guard let word = shared.subject.split(separator: " ").map(String.init).first(where: { $0.count > 3 }) else {
            check(false, "fixture shared message"); return
        }
        // Before the shared mailbox is opened its folders aren't cached: server hits can't be attributed.
        let early = await sync.search(word, scope: .allMailboxes, mailbox: "me", folderId: nil, allMailboxes: FX.mailboxes)
        check(!early.messages.contains { $0.id == FX.Special.sharedInbox } && early.unattributed > 0,
              "unopened mailbox: hits dropped and counted, never attributed to the wrong mailbox")
        await sync.openMailbox(FX.sharedMailbox)
        let mine = await sync.search(word, scope: .mailbox, mailbox: "me", folderId: nil, allMailboxes: FX.mailboxes)
        check(!mine.messages.contains { $0.id == FX.Special.sharedInbox }, "this mailbox: shared hit excluded")
        let all = await sync.search(word, scope: .allMailboxes, mailbox: "me", folderId: nil, allMailboxes: FX.mailboxes)
        check(all.messages.contains { $0.id == FX.Special.sharedInbox }, "all mailboxes: shared hit included")
        check(all.messages.allSatisfy { m in FX.mailboxes.contains(store.mailbox(forFolder: m.folderId)) }, "every hit has a known mailbox")
        check(zip(all.messages, all.messages.dropFirst()).allSatisfy { $0.received >= $1.received }, "merged newest first")
        check(Set(all.messages.map(\.id)).count == all.messages.count, "no duplicates across mailboxes")
        let inbox = FX.folderId(FX.sharedMailbox, .inbox)
        let folder = await sync.search(word, scope: .folder, mailbox: FX.sharedMailbox, folderId: inbox, allMailboxes: FX.mailboxes)
        check(!folder.messages.isEmpty && folder.messages.allSatisfy { $0.folderId == inbox }, "this folder: only that folder")
        check(GroupSearch.match([GroupConversation(id: "g", topic: "Quarterly Budget review", preview: "secret", lastDelivered: nil,
                                                   hasAttachments: false, senders: [])], query: "budget quarterly").count == 1
              && GroupSearch.match([GroupConversation(id: "g", topic: "Other", preview: "budget", lastDelivered: nil,
                                                      hasAttachments: false, senders: [])], query: "budget").isEmpty,
              "groups match topics only, never previews")
    } catch { check(false, "search scope threw \(error)") }
}

@MainActor
func organiseUnifiedInboxTests() {
    section("Organise: unified inbox keyset merge")
    do {
        let store = try mailStore()
        try store.upsert(folder: MailFolder(id: "in1", displayName: "Inbox", wellKnown: .inbox, mailbox: "me"))
        try store.upsert(folder: MailFolder(id: "in2", displayName: "Inbox", wellKnown: .inbox, mailbox: "support@contoso.example"))
        try store.upsert(folder: MailFolder(id: "arc", displayName: "Archive", wellKnown: .archive, mailbox: "me"))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var all: [MailMessage] = []
        for i in 0..<37 {   // same-second ties across mailboxes on purpose
            let m = om(String(format: "m%02d", i), folder: i % 3 == 0 ? "in2" : "in1", received: base - Double(i / 2) * 60)
            all.append(m)
        }
        try store.upsert(messages: all + [om("zz-archived", folder: "arc", received: base + 999)])
        let inboxes = UnifiedInbox.inboxes(store: store, mailboxes: ["me", "support@contoso.example"])
        check(Set(inboxes) == ["in1", "in2"], "inboxes of every mailbox")
        var paged: [MailMessage] = []
        var cursor: MailCursor?
        repeat {
            let p = UnifiedInbox.page(store: store, folderIds: inboxes, before: cursor, limit: 10)
            paged += p
            cursor = p.last.map { MailCursor(received: $0.received, id: $0.id) }
            if p.count < 10 { break }
        } while true
        let expected = all.sorted { (Int64($0.received.timeIntervalSince1970), $0.id) > (Int64($1.received.timeIntervalSince1970), $1.id) }.map(\.id)
        check(paged.map(\.id) == expected, "paged merge equals the global newest-first order (\(paged.count)/\(expected.count))")
        check(!paged.contains { $0.id == "zz-archived" }, "non-inbox folders excluded")
        let smart = SmartViewQuery.rows(store: store, view: .unread, mailbox: "me", me: [])
        check(smart.count == all.filter { $0.folderId == "in1" }.count + 1 && smart.contains { $0.id == "zz-archived" },
              "smart view scans every non-excluded folder of the mailbox")
    } catch { check(false, "unified inbox threw \(error)") }
}
