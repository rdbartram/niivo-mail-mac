import Foundation
import CryptoKit
import CalendarCore
import MailCore

final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MailChange] = []
    func add(_ c: MailChange) { lock.withLock { items.append(c) } }
    var all: [MailChange] { lock.withLock { items } }
}

typealias FX = FixtureMailService

func mailEngine() -> CachedLabelPolicyEngine { CachedLabelPolicyEngine(labels: FixtureCalendarService.labels, synced: true) }
func mailStore(_ url: URL? = nil, cap: Int = 500 * 1024 * 1024) throws -> MailStore {
    try MailStore(url: url, key: SymmetricKey(size: .bits256), bodyCacheLimit: cap)
}

@MainActor
func runMailTests() async {
    await mailFixtureTests()
    await mailSendTests()
    await mailWindowTests()
    mailPolicyTests()
    await mailRulesAndOOFTests()
    mailStoreTests()
    await runMailGraphStubTests()
    await runMailBenchmark()
}

@MainActor
func mailFixtureTests() async {
    section("Mail: fixture sync, persist rule, optimistic actions")
    do {
        let svc = FX()
        let store = try mailStore()
        let engine = mailEngine()
        let log = ChangeLog()
        let sync = MailSync(service: svc, store: store, compliance: engine, mailboxes: FX.mailboxes, onChange: { log.add($0) })
        await sync.syncNow()
        let st = await sync.status
        check(st.phase == .idle, "fixture sync completes")
        let inbox = FX.folderId("me", .inbox), sent = FX.folderId("me", .sentitems), archive = FX.folderId("me", .archive)
        check(try store.messageCount(folderId: inbox) > 60, "inbox headers synced (\(try store.messageCount(folderId: inbox)))")
        check(try store.messageCount(folderId: sent) > 5, "Sent synced (always-live folder)")
        check(try store.messageCount(folderId: archive) == 0, "Archive not synced until opened")
        check(try store.messageCount(folderId: FX.folderId(FX.sharedMailbox, .inbox)) == 0, "shared mailbox not synced until opened/pinned")
        check(try store.unreadCount(folderId: inbox) == (try await svc.folders(mailbox: "me")).first { $0.id == inbox }!.unreadCount,
              "unread count comes from the server folder record")
        check(try store.body(messageId: FX.Special.general) == nil, "headers only: no body cached by sync")

        // Persist rule.
        let hc = try store.message(id: FX.Special.highlyConfidential)
        check(hc != nil && hc?.preview == nil && hc?.toRecipients.isEmpty == true && hc?.attachments.isEmpty == true,
              "protected label → preview/recipients/attachment names not persisted")
        check(hc?.labelId == FX.labelHighlyConfidential && hc?.hasAttachments == true, "protected label → label id + flags kept")
        let orphan = try store.message(id: FX.Special.orphanLabel)
        check(orphan?.preview == nil && orphan?.toRecipients.isEmpty == true, "unknown label → fail closed (not persisted)")
        let gen = try store.message(id: FX.Special.general)
        check(gen?.preview != nil && gen?.toRecipients.isEmpty == false, "General label keeps details")
        let full = try await sync.fetchBody(id: FX.Special.highlyConfidential)
        check(try full.body != nil && (store.body(messageId: FX.Special.highlyConfidential)) == nil,
              "protected body shown on demand but never cached")
        _ = try await sync.fetchBody(id: FX.Special.general)
        check(try store.body(messageId: FX.Special.general) != nil, "unprotected body cached in LRU after open")
        check(try store.search("board").isEmpty, "protected subject not in blind index")
        check(try store.search("alex").contains { $0.id == FX.Special.highlyConfidential }, "protected item still findable by sender")
        check(try store.search("budget review").count >= 1, "blind index multi-term search")
        check(try store.search("budg").count >= 1, "blind index prefix search")

        // Delegate principal: private item on a delegated mailbox is redacted at rest.
        await sync.openMailbox(FX.principal)
        let pInbox = FX.folderId(FX.principal, .inbox)
        check(try store.messageCount(folderId: pInbox) == 5, "opened delegated mailbox synced")
        let priv = try store.messages(folderId: pInbox, limit: 50).first { $0.isPrivate }
        check(priv != nil && priv?.subject == "" && priv?.preview == nil, "private item in delegated mailbox: subject/body redacted at rest")

        // Optimistic markRead offline → flush online.
        let target = try store.messages(folderId: inbox, limit: 200).first { !$0.isRead && $0.labelId == nil }!
        let unreadBefore = try store.unreadCount(folderId: inbox)
        svc.simulateOffline = true
        try await sync.perform(.markRead(true), on: target.id)
        let local = try store.message(id: target.id)
        check(local?.isRead == true && local?.pendingSync == true, "markRead applied locally at once (pendingSync)")
        check(try store.outbox().count == 1, "offline → intent kept in encrypted outbox")
        check(try store.unreadCount(folderId: inbox) == unreadBefore - 1, "optimistic unread count adjusted")
        check(svc.serverMessage(target.id)?.isRead == false, "server untouched while offline")
        svc.simulateOffline = false
        await sync.flush()
        check(try store.outbox().isEmpty && svc.serverMessage(target.id)?.isRead == true, "flush delivered markRead")
        check(try store.message(id: target.id)?.pendingSync == false, "pendingSync cleared after flush")

        // Move / delete / snooze / wake.
        let a = try store.messages(folderId: inbox, limit: 200).filter { $0.labelId == nil && !$0.isPrivate }
        try await sync.perform(.move(toFolderId: FX.projectsFolderId), on: a[0].id)
        check(try store.message(id: a[0].id)?.folderId == FX.projectsFolderId && svc.serverMessage(a[0].id)?.folderId == FX.projectsFolderId,
              "move applied locally and on server")
        try await sync.perform(.delete, on: a[1].id)
        check(try svc.serverMessage(a[1].id)?.folderId == FX.folderId("me", .deleteditems)
              && (store.message(id: a[1].id))?.folderId == FX.folderId("me", .deleteditems), "delete → Deleted Items (soft)")
        let wake = Date().addingTimeInterval(3600)
        try await sync.perform(.snooze(until: wake), on: a[2].id)
        let snoozed = try store.message(id: a[2].id)
        check(snoozed?.folderId == FX.folderId("me", .snoozed) && snoozed?.snoozedUntil == wake, "snooze → Snoozed folder + wake time")
        await sync.syncNow()
        check(try store.message(id: a[2].id)?.snoozedUntil == wake, "server sync keeps local wake time")
        check(try store.message(id: a[1].id) != nil, "delta @removed from source folder doesn't delete the moved row")
        await sync.wakeSnoozed(now: Date())
        check(try store.message(id: a[2].id)?.folderId == FX.folderId("me", .snoozed), "not woken before its time")
        await sync.wakeSnoozed(now: wake.addingTimeInterval(1))
        let woke = try store.message(id: a[2].id)
        check(woke?.folderId == inbox && woke?.snoozedUntil == nil && svc.serverMessage(a[2].id)?.folderId == inbox, "wakeSnoozed → back to Inbox")

        // Conversation + keyset paging.
        let conv = try store.conversation(id: FX.Special.thread)
        check(conv.count >= 3 && zip(conv, conv.dropFirst()).allSatisfy { $0.received <= $1.received }, "conversation across Inbox+Sent, oldest first")
        var seen = Set<String>(), cursor: MailCursor?
        while true {
            let page = try store.messages(folderId: inbox, before: cursor, limit: 7)
            guard let last = page.last else { break }
            for m in page { seen.insert(m.id) }
            cursor = MailCursor(received: last.received, id: last.id)
        }
        check(seen.count == (try store.messageCount(folderId: inbox)), "keyset paging visits every row exactly once")
    } catch { check(false, "mail fixture tests threw \(error)") }
}

@MainActor
func mailSendTests() async {
    section("Mail: drafts, undo send, send later, identities, label floor")
    do {
        let svc = FX()
        let store = try mailStore()
        let engine = mailEngine()
        let log = ChangeLog()
        let sync = MailSync(service: svc, store: store, compliance: engine, mailboxes: FX.mailboxes, onChange: { log.add($0) })
        await sync.syncNow()
        let to = [EmailAddress(name: "Jordan Lee", address: "jordan@fabrikam.example")]

        // Undo.
        let t1 = try await sync.queueSend(MailDraft(to: to, subject: "Undo me", bodyHTML: "<p>x</p>"), undoSeconds: 0.2)
        check(await sync.undoSend(t1), "undoSend within window → true")
        try await Task.sleep(for: .milliseconds(350))
        check(svc.sentLog.isEmpty, "undone send never reached the server")
        check(await sync.undoSend(t1) == false, "second undo → false")

        // Send after window.
        _ = try await sync.queueSend(MailDraft(to: to, subject: "Send me", bodyHTML: "<p>y</p>"), undoSeconds: 0.1)
        await sync.waitForPendingSends()
        let sentId = svc.sentLog.last?.id
        check(svc.sentLog.count == 1 && sentId.flatMap { svc.serverMessage($0) }?.folderId == FX.folderId("me", .sentitems),
              "send after undo window lands in Sent (server)")
        check(sentId.flatMap { try? store.message(id: $0) }?.folderId == FX.folderId("me", .sentitems), "Sent folder resynced locally")

        // Client-side send later (default; serverDeferredSend off).
        let later = Date().addingTimeInterval(0.6)
        _ = try await sync.queueSend(MailDraft(to: to, subject: "Later", bodyHTML: "<p>z</p>", sendAt: later), undoSeconds: 0.05)
        await sync.waitForPendingSends()
        check(try svc.sentLog.count == 1 && (store.outbox()).count == 1, "send-later: draft kept, intent in outbox, not sent early")
        await sync.flush()
        check(svc.sentLog.count == 1, "flush before due time doesn't send")
        try await Task.sleep(for: .milliseconds(700))
        await sync.flush()
        check(try svc.sentLog.count == 2 && svc.sentLog.last?.sendAt == nil && (store.outbox()).isEmpty, "due scheduled send goes out (client-side)")
        // Became due while the app was closed → goes out on launch with a status note.
        let d = try await sync.saveDraft(MailDraft(to: to, subject: "Overdue", bodyHTML: "<p>o</p>"))
        try store.enqueue(messageId: d.id, mailbox: "me", op: .send(sendAt: Date().addingTimeInterval(-600)))
        await sync.syncNow()
        check(svc.sentLog.contains { $0.id == d.id }, "overdue scheduled send sent on next launch/wake")
        let st171 = await sync.status
        check(log.all.contains(.lateScheduledSends(count: 1)) && st171.notes.contains { $0.contains("late") },
              "late send reported in status")
        // Server deferred send path (UNVERIFIED on Graph) behind the flag.
        var s = await sync.settings; s.serverDeferredSend = true
        try await sync.update(settings: s)
        let at = Date().addingTimeInterval(3600)
        _ = try await sync.queueSend(MailDraft(to: to, subject: "Deferred", bodyHTML: "<p>d</p>", sendAt: at), undoSeconds: 0.05)
        await sync.waitForPendingSends()
        check(svc.sentLog.last?.sendAt == at, "serverDeferredSend flag → sendAt handed to the service")

        // Identities.
        let sharedId = SendIdentity(address: FX.sharedMailbox, name: "Support", mailbox: FX.sharedMailbox, mode: .sendAs)
        _ = try await sync.queueSend(MailDraft(to: to, subject: "As support", bodyHTML: "<p>s</p>", from: sharedId), undoSeconds: 0.05)
        await sync.waitForPendingSends()
        let asId = svc.sentLog.last!
        check(asId.mailbox == FX.sharedMailbox && svc.serverMessage(asId.id)?.folderId == FX.folderId(FX.sharedMailbox, .sentitems)
              && svc.serverMessage(asId.id)?.from?.address == FX.sharedMailbox, "Send As → created + sent in shared mailbox, lands in its Sent Items")
        let samId = SendIdentity(address: FX.principal, name: "Sam Rivera", mailbox: "me", mode: .sendOnBehalf)
        let ob = try await sync.saveDraft(MailDraft(to: to, subject: "On behalf", bodyHTML: "<p>b</p>", from: samId))
        check(ob.folderId == FX.folderId("me", .drafts) && ob.from?.address == FX.principal && ob.sender?.address == FX.me.address,
              "Send on Behalf → draft in own mailbox, from = principal, sender = me")
        do {
            _ = try await sync.saveDraft(MailDraft(to: to, subject: "Nope", from: SendIdentity(address: "ceo@fabrikam.example", name: "CEO",
                                                                                                 mailbox: "ceo@fabrikam.example", mode: .sendAs)))
            check(false, "unauthorised identity should fail")
        } catch MailServiceError.sendAsDenied(let a) { check(a == "ceo@fabrikam.example", "unauthorised identity → sendAsDenied") }
        await sync.openMailbox(FX.sharedMailbox)
        let rep = try await sync.saveDraft(MailDraft(kind: .reply, replyTo: FX.Special.sharedInbox, bodyHTML: "<p>On it</p>"))
        check(rep.folderId == FX.folderId(FX.sharedMailbox, .drafts) && rep.conversationId == "conv-sh-0",
              "reply to a shared-mailbox message stays in that mailbox (threaded)")
        check(rep.body?.hasPrefix("<p>On it</p>") == true && rep.body?.contains("divRplyFwdMsg") == true, "reply keeps quoted history below user text")

        // Label floor.
        let conf = FX.labelConfidential, gen = FX.labelGeneral, hcl = FX.labelHighlyConfidential
        let r1 = await sync.enforceLabelFloor(MailDraft(kind: .reply, replyTo: FX.Special.confidential, labelId: gen))
        check(r1.labelId == conf, "reply label below original → bumped to original")
        let r2 = await sync.enforceLabelFloor(MailDraft(kind: .forward, replyTo: FX.Special.confidential))
        check(r2.labelId == conf, "unlabelled forward inherits original label")
        let r3 = await sync.enforceLabelFloor(MailDraft(kind: .reply, replyTo: FX.Special.confidential, labelId: hcl))
        check(r3.labelId == hcl, "higher label on reply is kept")
        let r4 = await sync.enforceLabelFloor(MailDraft(kind: .reply, replyTo: FX.Special.orphanLabel, labelId: gen))
        check(r4.labelId == FixtureCalendarService.orphanLabelId, "original with unknown label → inherited (fail closed)")
        let r5 = await sync.enforceLabelFloor(MailDraft(kind: .new, labelId: gen))
        check(r5.labelId == gen, "new message label untouched")
        let saved = try await sync.saveDraft(MailDraft(kind: .replyAll, replyTo: FX.Special.confidential, labelId: gen))
        check(saved.labelId == conf, "saveDraft applies the floor before reaching the server")
    } catch { check(false, "mail send tests threw \(error)") }
}

@MainActor
func mailWindowTests() async {
    section("Mail: cache window, backfill, prune")
    do {
        let svc = FX()
        let store = try mailStore()
        let sync = MailSync(service: svc, store: store, compliance: mailEngine(), pageSize: 4, onChange: { _ in })
        await sync.syncNow()
        let archive = FX.folderId("me", .archive)
        await sync.openFolder(archive)
        let recent = try store.messageCount(folderId: archive)
        check(recent == 15, "opened folder syncs headers inside the live window only (\(recent))")
        try await sync.setWindow(.years(1), for: "me")
        let first = await sync.backfill(mailbox: "me", maxPages: 1)
        check(try !first && (store.value(for: "backfill:\(archive)")) != nil, "backfill pages newest-first with a persisted cursor")
        var done = false
        for _ in 0..<20 where !done { done = await sync.backfill(mailbox: "me", maxPages: 1) }
        let prog = await sync.backfillProgress(mailbox: "me")
        let old = try store.messages(folderId: archive, limit: 100).filter { $0.id.hasPrefix("msg-old-") }.count
        check(done && prog.done && old == 5, "backfill resumes to the 1-year cutoff and stops (\(old) old)")
        check(prog.oldestCached.map { $0 < Date().addingTimeInterval(-300 * 86400) } == true, "progress reports oldest cached date")
        try await sync.setWindow(.days(30), for: "me")
        check(try store.messages(folderId: archive, limit: 100).allSatisfy { !$0.id.hasPrefix("msg-old-") }, "shrinking the window prunes older headers")
        check(try store.search("old").isEmpty, "pruned headers leave no index tokens")
        let reloaded = try store.settings()
        check(reloaded.window(for: "me") == .days(30) && reloaded.window(for: FX.sharedMailbox) == .days(30),
              "settings persisted in sealed kv (per-mailbox window)")
        check(CacheWindow.presets.count == 6 && CacheWindow.everything.cutoff() == nil, "window presets incl. everything")
        let older = try await sync.loadOlder(folderId: archive, count: 3)
        check(older.count == 3 && older.allSatisfy { $0.id.hasPrefix("msg-old-") }, "load older on demand (server keyset page)")
        let merged = await sync.search("old", mailbox: "me", limit: 50)
        check(merged.count >= 3, "search: local index + server $search merged")
    } catch { check(false, "mail window tests threw \(error)") }
}

@MainActor
func mailPolicyTests() {
    section("Mail: sanitiser, AI access policy, split inbox")
    let html = "<p onclick=\"steal()\">Hello</p><script>alert(1)</script><a href=\"javascript:alert(1)\">x</a><iframe src=\"https://e.example\"></iframe><img src=\"https://tracker.example/p.gif\"><img src='http://t2.example/a.png' alt=a><img src=\"cid:logo\">"
    let (clean, blocked) = HTMLSanitizer.sanitize(html)
    check(!clean.lowercased().contains("<script") && !clean.contains("alert(1)</"), "script element removed")
    check(!clean.contains("onclick") && !clean.contains("javascript:"), "event handlers + javascript: URLs removed")
    check(!clean.contains("<iframe"), "iframe removed")
    check(blocked == 2 && !clean.contains("tracker.example") && !clean.contains("t2.example") && clean.contains("cid:logo"),
          "remote images blocked (\(blocked)), inline cid kept")
    let (allowed, n) = HTMLSanitizer.sanitize(html, allowRemote: true)
    check(n == 0 && allowed.contains("tracker.example") && !allowed.contains("<script"), "allowRemote keeps images, still strips script")

    let engine = mailEngine()
    let ai = AIAccessPolicy(engine: engine)
    func m(_ label: String?, priv: Bool = false) -> MailMessage {
        MailMessage(id: "x", folderId: "f", conversationId: "c", subject: "S", from: .init(name: "A", address: "a@contoso.example"),
                    toRecipients: [.init(name: "B", address: "b@contoso.example")], received: Date(), preview: "p", body: "b",
                    attachments: [.init(id: "1", name: "n", contentType: "t", size: 1)], labelId: label, isPrivate: priv)
    }
    let L = FixtureCalendarService.labels
    check(ai.level(for: m(nil)) == .full && ai.redactForAI(m(nil))?.body == "b", "unlabelled → full")
    check(ai.level(for: m(L[1].id)) == .full, "General (priority 1) → full")
    let conf = ai.redactForAI(m(L[2].id))
    check(ai.level(for: m(L[2].id)) == .metadataOnly && conf?.body == nil && conf?.preview == nil && conf?.toRecipients.isEmpty == true
          && conf?.attachments.isEmpty == true && conf?.subject == "S", "Confidential (≥ aiMaxPriority) → metadata only")
    let prot = ai.redactForAI(m(L[3].id))
    check(prot?.subject == AIAccessPolicy.protectedSubject && prot?.body == nil, "protected → metadata only, subject replaced")
    check(ai.level(for: m(FixtureCalendarService.orphanLabelId)) == .hidden && ai.redactForAI(m(FixtureCalendarService.orphanLabelId)) == nil,
          "unknown label → hidden")
    check(ai.level(for: m(nil, priv: true)) == .hidden, "private (even own mailbox) → hidden")
    check(AIAccessPolicy(engine: engine, aiMaxPriority: 3).level(for: m(L[2].id)) == .full, "threshold configurable")
    check(AIAccessPolicy(engine: CachedLabelPolicyEngine()).level(for: m(L[1].id)) == .hidden, "labels not synced → labelled mail hidden")

    func mk(_ addr: String, focus: Focus = .focused, cats: [String] = []) -> MailMessage {
        MailMessage(id: addr, folderId: "f", conversationId: "c", subject: "", from: .init(name: "", address: addr), received: Date(),
                    focus: focus, categories: cats)
    }
    check(SplitInbox.bucket(for: mk("alex@contoso.example")) == .important, "person + focused → important")
    check(SplitInbox.bucket(for: mk("alex@contoso.example", focus: .other)) == .other, "person + other → other")
    check(SplitInbox.bucket(for: mk("newsletter@news.northwind.example")) == .newsletters, "newsletter@ → newsletters")
    check(SplitInbox.bucket(for: mk("noreply@shop.example")) == .newsletters, "noreply@ unknown domain → newsletters")
    check(SplitInbox.bucket(for: mk("someone@x.example", cats: ["Newsletter"])) == .newsletters, "category → newsletters")
    check(SplitInbox.bucket(for: mk("notifications@devops.fabrikam.example")) == .notifications, "notifications@ SaaS → notifications")
    check(SplitInbox.bucket(for: mk("no-reply@tickets.example")) == .notifications, "no-reply@ known SaaS → notifications")
    check(SplitInbox.bucket(for: mk("alerts@status.example", focus: .other)) == .notifications, "alerts@ status page → notifications")
}

@MainActor
func mailRulesAndOOFTests() async {
    section("Mail: inbox rules + automatic replies")
    do {
        let svc = FX()
        let store = try mailStore()
        var settings = MailSettings(); settings.internalDomains = ["contoso.example"]
        let sync = MailSync(service: svc, store: store, compliance: mailEngine(), settings: settings, onChange: { _ in })
        let rules = try await sync.rules()
        check(rules.count == 4 && rules.contains { !$0.isEnabled } && rules.contains { $0.hasError }, "fixture rules incl. disabled + in-error")
        let ext = rules.first { $0.id == "rule-b" }!
        do { _ = try RulePolicy.validate(ext, internalDomains: ["contoso.example"]); check(false, "external forward should be blocked") }
        catch RulePolicyError.externalForwardBlocked(let a) { check(a == ["books@external-accounting.example"], "external forward blocked by default") }
        let warn = try RulePolicy.validate(ext, internalDomains: ["contoso.example"], blockExternalForward: false)
        check(warn.contains { $0.contains("outside") }, "external forward → warning when not blocked")
        check(try RulePolicy.validate(MailRule(displayName: "x", actions: .init(forwardTo: [.init(name: "", address: "a@sub.contoso.example")])),
                                      internalDomains: ["contoso.example"]).isEmpty == false, "internal subdomain forward allowed (warns: no conditions)")
        do { _ = try await sync.saveRule(ext); check(false, "saveRule should enforce policy") }
        catch RulePolicyError.externalForwardBlocked { check(true, "MailSync.saveRule enforces the external-forward block") }

        let msg = MailMessage(id: "m", folderId: "f", conversationId: "c", subject: "", from: .init(name: "Mia Keller", address: "mia@fabrikam.example"), received: Date())
        let sug = MailRule.suggested(from: msg, toFolderId: FX.projectsFolderId, folderName: "Projects")!
        check(sug.conditions.fromAddresses.first?.address == "mia@fabrikam.example" && sug.actions.moveToFolder == FX.projectsFolderId
              && sug.actions.stopProcessingRules == true, "suggested rule from a message (move from sender)")
        var (created, _) = try await sync.saveRule(sug)
        let rl328 = try await sync.rules()
        check(created.id != nil && rl328.count == 5, "rule create (POST) round-trip")
        created.displayName = "Renamed"
        let (patched, _) = try await sync.saveRule(created)
        let rl331 = try await sync.rules()
        check(patched.displayName == "Renamed" && rl331.count == 5, "rule update (PATCH) round-trip")
        let order = [created.id!, "rule-a", "rule-b", "rule-c", "rule-d"]
        let re = try await sync.reorderRules(ids: order)
        let rl334 = try await sync.rules()
        check(re.map(\.id!) == order && rl334.map(\.id!) == order, "reorder rules by sequence")
        do { _ = try await sync.saveRule(MailRule(displayName: "purge", actions: .init(permanentDelete: true))); check(false, "permanentDelete gate") }
        catch RulePolicyError.permanentDeleteNotConfirmed { check(true, "permanentDelete requires explicit confirm") }
        let (pd, w) = try await sync.saveRule(MailRule(displayName: "purge", conditions: .init(subjectContains: ["spam"]),
                                                       actions: .init(permanentDelete: true)), confirmPermanentDelete: true)
        check(pd.id != nil && w.contains { $0.contains("Permanently") }, "confirmed permanentDelete saved with warning")
        try await sync.deleteRule(id: pd.id!)
        check((try await sync.rules()).count == 5, "rule delete")

        // OOF.
        let me0 = try await sync.refreshAutomaticReplies()
        let oof345 = await sync.oofActive
        check(me0.status == .disabled && oof345 == false, "own automatic replies off by default")
        let end = Date().addingTimeInterval(86400)
        let set = AutomaticReplies(status: .scheduled, start: Date().addingTimeInterval(-3600), end: end, timeZone: "Europe/Zurich",
                                   internalReplyHTML: "<p>Away</p>", externalReplyHTML: "<p>Away</p>", externalAudience: .all)
        let got = try await sync.setAutomaticReplies(set)
        let back = try await sync.refreshAutomaticReplies()
        check(got == set && back == set, "automatic replies set/get round-trip")
        let oa352 = await sync.oofActive, ou352 = await sync.oofUntil
        check(oa352 && ou352 == end, "scheduled window active → banner until end")
        let sam = try await sync.refreshAutomaticReplies(mailbox: FX.principal)
        let sa354 = await sync.automaticRepliesActive(mailbox: FX.principal)
        check(sam.status == .scheduled && !sa354
              && sam.isActive(at: sam.start!.addingTimeInterval(60)), "delegate's scheduled OOF: future window evaluated correctly")
        do { _ = try await sync.setAutomaticReplies(set, mailbox: FX.principal); check(false, "delegate OOF write should be refused") }
        catch MailServiceError.forbidden { check(true, "setting another mailbox's automatic replies → forbidden") }
        let reg = try await sync.regionalSettings()
        check(reg.timeZone != nil && reg.workingHours?.daysOfWeek.count == 5, "mailbox time zone + working hours read")
    } catch { check(false, "rules/OOF tests threw \(error)") }
}

@MainActor
func mailStoreTests() {
    section("Mail store: encryption at rest, body LRU, blind index")
    do {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mailstore-\(UUID().uuidString)")
        let url = dir.appending(path: "mail.sqlite")
        let key = SymmetricKey(size: .bits256)
        let s = try MailStore(url: url, key: key, bodyCacheLimit: 4_000)
        s.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: mailEngine()) }
        try s.replace(folders: [MailFolder(id: "f1", displayName: "Inbox", wellKnown: .inbox)], mailbox: "me")
        let m = MailMessage(id: "p1", folderId: "f1", conversationId: "c1", subject: "Zürich offsite plan", from: .init(name: "Élodie", address: "elodie@fabrikam.example"),
                            received: Date(), preview: "Kickoff agenda", body: String(repeating: "Z", count: 1500))
        try s.upsert(message: m)
        check(try s.search("zurich").first?.id == "p1" && (try s.search("elodie")).first?.id == "p1", "diacritic-folded tokens match")
        check(try s.search("kick").first?.id == "p1", "preview prefix match")
        for i in 0..<4 {
            try s.upsert(message: MailMessage(id: "b\(i)", folderId: "f1", conversationId: "c", subject: "B", from: nil, received: Date()))
            try s.putBody(messageId: "b\(i)", body: String(repeating: "x", count: 1400))
        }
        check(try s.bodyCacheBytes() <= 4_000 && (try s.body(messageId: "b3")) != nil && (try s.body(messageId: "p1")) == nil,
              "body LRU evicts oldest to stay under the cap (\(try s.bodyCacheBytes()) B)")
        s.checkpoint()
        var raw = Data()
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { raw += (try? Data(contentsOf: f)) ?? Data() }
        check(raw.range(of: Data("offsite".utf8)) == nil && raw.range(of: Data("zurich".utf8)) == nil && raw.range(of: Data("Kickoff".utf8)) == nil,
              "no subject/preview/token plaintext on disk (DB + WAL)")
        let other = try MailStore(url: url, key: SymmetricKey(size: .bits256))
        check(try (try? other.message(id: "p1")) == nil && (other.search("zurich")).isEmpty, "other key: payload unreadable, index useless")
        try? FileManager.default.removeItem(at: dir)
    } catch { check(false, "mail store tests threw \(error)") }
}
