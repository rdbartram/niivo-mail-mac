import Foundation
import CryptoKit
import CalendarCore
import MailCore

/// Fixture mail service that refuses one mailbox (403), to check a failing mailbox doesn't stop the others.
final class DenyingMailService: MailService, @unchecked Sendable {
    let inner = FixtureMailService()
    let denied: String
    init(denied: String) { self.denied = denied }
    private func gate(_ mb: String) throws { if mb == denied { throw MailServiceError.forbidden } }
    func me() async throws -> EmailAddress { try await inner.me() }
    func folders(mailbox: String) async throws -> [MailFolder] { try gate(mailbox); return try await inner.folders(mailbox: mailbox) }
    func delta(folder: MailFolder, deltaLink: String?, top: Int, since: Date?) async throws -> MailDelta {
        try gate(folder.mailbox); return try await inner.delta(folder: folder, deltaLink: deltaLink, top: top, since: since)
    }
    func page(folder: MailFolder, before: MailCursor?, top: Int) async throws -> [MailMessage] {
        try gate(folder.mailbox); return try await inner.page(folder: folder, before: before, top: top)
    }
    func message(id: String, mailbox: String) async throws -> MailMessage { try gate(mailbox); return try await inner.message(id: id, mailbox: mailbox) }
    func apply(_ action: MailAction, messageId: String, mailbox: String) async throws -> MailMessage? {
        try await inner.apply(action, messageId: messageId, mailbox: mailbox)
    }
    func saveDraft(_ draft: MailDraft, mailbox: String) async throws -> MailMessage { try await inner.saveDraft(draft, mailbox: mailbox) }
    func send(draftId: String, mailbox: String, sendAt: Date?) async throws { try await inner.send(draftId: draftId, mailbox: mailbox, sendAt: sendAt) }
    func search(_ query: String, mailbox: String, top: Int) async throws -> [MailMessage] { try await inner.search(query, mailbox: mailbox, top: top) }
    func rules(mailbox: String) async throws -> [MailRule] { try await inner.rules(mailbox: mailbox) }
    func saveRule(_ rule: MailRule, mailbox: String) async throws -> MailRule { try await inner.saveRule(rule, mailbox: mailbox) }
    func deleteRule(id: String, mailbox: String) async throws { try await inner.deleteRule(id: id, mailbox: mailbox) }
    func automaticReplies(mailbox: String) async throws -> AutomaticReplies { try await inner.automaticReplies(mailbox: mailbox) }
    func setAutomaticReplies(_ replies: AutomaticReplies, mailbox: String) async throws -> AutomaticReplies {
        try await inner.setAutomaticReplies(replies, mailbox: mailbox)
    }
    func regionalSettings(mailbox: String) async throws -> MailboxRegionalSettings { try await inner.regionalSettings(mailbox: mailbox) }
    func createFolder(displayName: String, parentId: String?, mailbox: String) async throws -> MailFolder { try gate(mailbox); return try await inner.createFolder(displayName: displayName, parentId: parentId, mailbox: mailbox) }
    func renameFolder(id: String, displayName: String, mailbox: String) async throws -> MailFolder { try gate(mailbox); return try await inner.renameFolder(id: id, displayName: displayName, mailbox: mailbox) }
    func moveFolder(id: String, toParentId: String?, mailbox: String) async throws -> MailFolder { try gate(mailbox); return try await inner.moveFolder(id: id, toParentId: toParentId, mailbox: mailbox) }
    func deleteFolder(id: String, mailbox: String) async throws { try gate(mailbox); try await inner.deleteFolder(id: id, mailbox: mailbox) }
    func markAllRead(folderId: String, mailbox: String) async throws -> Int { try gate(mailbox); return try await inner.markAllRead(folderId: folderId, mailbox: mailbox) }
    func addAttachment(_ attachment: OutgoingAttachment, toDraft draftId: String, mailbox: String) async throws -> AttachmentInfo { try gate(mailbox); return try await inner.addAttachment(attachment, toDraft: draftId, mailbox: mailbox) }
    func emptyFolder(folderId: String, mailbox: String) async throws -> Int { try gate(mailbox); return try await inner.emptyFolder(folderId: folderId, mailbox: mailbox) }
}

final class Flags: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String: Int] = [:]
    func hit(_ k: String) { lock.withLock { v[k, default: 0] += 1 } }
    func count(_ k: String) -> Int { lock.withLock { v[k] ?? 0 } }
}

@MainActor
func runMailboxGroupsTests() async {
    section("Additional mailboxes: address rules, persisted list, settings back-compat")
    check(MailboxAddress.normalise("  Support@Contoso.COM ") == "support@contoso.com", "address trimmed + lower-cased")
    check(MailboxAddress.normalise("Contoso Support <support@contoso.com>") == "support@contoso.com", "Name <addr> accepted")
    check(MailboxAddress.normalise("support") == nil && MailboxAddress.normalise("me") == nil, "bare words refused")
    check(MailboxAddress.normalise("a/b@contoso.com") == nil && MailboxAddress.normalise("x@contoso.com/../me") == nil
          && MailboxAddress.normalise("x%40y@contoso.com") == nil, "path characters refused (address goes into a URL path)")

    // Settings sealed before the new fields existed must still decode (else every setting would reset).
    do {
        let old = MailSettings(pinnedMailboxes: ["support@contoso.example"],
                               identities: [SendIdentity(address: "you@contoso.example", name: "You")])
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        for k in ["addedMailboxes", "mailboxOrder", "collapsedMailboxes", "removedMailboxes"] { obj[k] = nil }
        let back = try JSONDecoder().decode(MailSettings.self, from: JSONSerialization.data(withJSONObject: obj))
        check(back.identities.count == 1 && back.pinnedMailboxes == ["support@contoso.example"] && back.addedMailboxes == nil,
              "pre-change settings blob decodes with identities + pins intact")
    } catch { check(false, "settings back-compat threw \(error)") }

    var s = MailSettings()
    s.addMailbox("a@contoso.example", identity: MailboxAccessKind.shared.identity(address: "a@contoso.example", name: "A"))
    s.addMailbox("b@contoso.example", identity: MailboxAccessKind.delegate.identity(address: "b@contoso.example", name: "B"))
    s.addMailbox("c@contoso.example", identity: MailboxAccessKind.readOnly.identity(address: "c@contoso.example", name: "C"))
    var list = MailboxList.compose(configured: ["cfg@contoso.example"], settings: s)
    check(list == ["me", "cfg@contoso.example", "a@contoso.example", "b@contoso.example", "c@contoso.example"], "configured + added, me first (\(list))")
    check(s.identities.contains { $0.mailbox == "a@contoso.example" && $0.mode == .sendAs }
          && s.identities.contains { $0.mailbox == "b@contoso.example" && $0.mode == .sendOnBehalf }
          && !s.identities.contains { $0.mailbox == "c@contoso.example" }, "added mailbox offers its From identity (shared/delegate; none for read-only)")
    s.moveMailbox("c@contoso.example", by: -1, current: list)
    s.moveMailbox("c@contoso.example", by: -1, current: MailboxList.compose(configured: ["cfg@contoso.example"], settings: s))
    list = MailboxList.compose(configured: ["cfg@contoso.example"], settings: s)
    check(list == ["me", "cfg@contoso.example", "c@contoso.example", "a@contoso.example", "b@contoso.example"], "reorder persists (\(list))")
    s.setCollapsed("a@contoso.example", true)
    check(s.isCollapsed("a@contoso.example") && !s.isCollapsed("me"), "collapse persists per mailbox")
    s.pinnedMailboxes.insert("cfg@contoso.example")
    s.removeMailbox("cfg@contoso.example", configured: true)
    s.removeMailbox("a@contoso.example", configured: false)
    list = MailboxList.compose(configured: ["cfg@contoso.example"], settings: s)
    check(list == ["me", "c@contoso.example", "b@contoso.example"] && !s.pinnedMailboxes.contains("cfg@contoso.example")
          && !s.identities.contains { $0.mailbox == "a@contoso.example" }, "removed mailboxes stay removed (config one too), identity + pin gone (\(list))")
    s.addMailbox("cfg@contoso.example", identity: nil)
    check(MailboxList.compose(configured: ["cfg@contoso.example"], settings: s).contains("cfg@contoso.example"), "re-adding a removed config mailbox brings it back")
    // Config entries keep their spelling (cache / pin / identity key); case-insensitive everywhere else.
    var mc = MailSettings()
    mc.addMailbox("desk@contoso.example", identity: nil)
    check(MailboxList.compose(configured: ["Desk@Contoso.example", "Boss@Contoso.example"], settings: mc) == ["me", "Desk@Contoso.example", "Boss@Contoso.example"],
          "mixed-case config entry kept as written, not duplicated by a lower-case add")
    mc.identities = [SendIdentity(address: "Boss@Contoso.example", name: "Boss", mailbox: "Boss@Contoso.example", mode: .sendOnBehalf)]
    mc.removeMailbox("Boss@Contoso.example", configured: true)
    check(MailboxList.compose(configured: ["Desk@Contoso.example", "Boss@Contoso.example"], settings: mc) == ["me", "Desk@Contoso.example"]
          && mc.identities.isEmpty, "mixed-case config mailbox removal sticks, its identity goes")
    do {
        let data = try JSONEncoder().encode(s)
        check(try JSONDecoder().decode(MailSettings.self, from: data) == s, "new fields round-trip")
    } catch { check(false, "settings encode threw \(error)") }

    section("Additional mailboxes: access check 403 vs 404, directory lookup (stub)")
    let flags = Flags()
    MailStub.log = []
    MailStub.handler = { req, _ in
        let path = req.url!.path
        switch path {
        case "/v1.0/users/shared@contoso.example/mailFolders/inbox": return (200, [:], #"{"id":"inbox-x"}"#)
        case "/v1.0/users/shared@contoso.example": return (200, [:], #"{"displayName":"Shared Desk","mail":"shared@contoso.example"}"#)
        case "/v1.0/users/locked@contoso.example/mailFolders/inbox": return (403, [:], #"{"error":{"code":"ErrorAccessDenied","message":"secret text"}}"#)
        case "/v1.0/users/nobody@contoso.example/mailFolders/inbox": return (404, [:], #"{"error":{"code":"ErrorInvalidUser"}}"#)
        case "/v1.0/users":
            if req.value(forHTTPHeaderField: "ConsistencyLevel") == "eventual" { flags.hit("cl") }
            return (200, [:], #"{"value":[{"displayName":"Shared Desk","mail":"shared@contoso.example"}]}"#)
        case "/v1.0/me/people":
            return (200, [:], #"{"value":[{"displayName":"Shared Desk","scoredEmailAddresses":[{"address":"Shared@contoso.example"}]},{"displayName":"Alex","scoredEmailAddresses":[{"address":"alex@contoso.example"}]}]}"#)
        default: return (500, [:], "{}")
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let session = URLSession(configuration: cfg)
    let dir = GraphMailboxDirectory(mailToken: { "mail-t" }, directoryToken: { "dir-t" }, session: session)
    do {
        let v = try await dir.validate(mailbox: " Shared@Contoso.example ")
        check(v.address == "shared@contoso.example" && v.displayName == "Shared Desk", "200 → mailbox reachable, display name looked up")
    } catch { check(false, "validate shared threw \(error)") }
    do { _ = try await dir.validate(mailbox: "locked@contoso.example"); check(false, "403 should throw") }
    catch { check(error as? MailboxAccessError == .forbidden && (error as? MailboxAccessError)?.message.contains("permission") == true,
                  "403 → 'no permission' (not 'not found')") }
    do { _ = try await dir.validate(mailbox: "nobody@contoso.example"); check(false, "404 should throw") }
    catch { check(error as? MailboxAccessError == .notFound && (error as? MailboxAccessError)?.message.contains("isn't shared") == true,
                  "404 → 'not found or not shared with you'") }
    let before = MailStub.captured().count
    do { _ = try await dir.validate(mailbox: "not an address"); check(false, "invalid should throw") }
    catch { check(error as? MailboxAccessError == .invalidAddress && MailStub.captured().count == before, "invalid address refused before any request") }
    let found = (try? await dir.search("shar")) ?? []
    check(found.count == 2 && found.first?.address.lowercased() == "shared@contoso.example", "people + directory merged, de-duplicated (\(found.count))")
    check(flags.count("cl") == 1, "directory $search sent with ConsistencyLevel: eventual")
    check(MailStub.captured().contains { $0.path == "/v1.0/users" && $0.query.contains("%22displayName:shar%22") }, "$search value double-quoted")
    let noDir = GraphMailboxDirectory(mailToken: { "mail-t" }, directoryToken: nil, session: session)
    check(((try? await noDir.search("shar")) ?? ["x"].map { EmailAddress(name: "", address: $0) }).isEmpty, "no directory consent → empty lookup, typed address still works")

    section("Additional mailboxes: remove purges the cache; a 403 mailbox doesn't stop the others")
    do {
        let shared = FixtureMailService.sharedMailbox, principal = FixtureMailService.principal
        let svc = DenyingMailService(denied: principal)
        let store = try mailStore()
        var st = MailSettings()
        st.pinnedMailboxes = [shared, principal]
        let sync = MailSync(service: svc, store: store, compliance: mailEngine(), mailboxes: FixtureMailService.mailboxes,
                            settings: st, onChange: { _ in })
        await sync.syncNow()
        let status = await sync.status
        check(status.phase == .idle, "pass completes despite one refused mailbox (\(status.phase))")
        check(status.mailboxErrors[principal] == MailboxAccessError.forbidden.message && status.mailboxErrors[shared] == nil,
              "403 recorded on that mailbox only")
        let sharedFolders = try store.folders(mailbox: shared)
        let sharedCount = try sharedFolders.reduce(0) { $0 + (try store.messageCount(folderId: $1.id)) }
        check(!sharedFolders.isEmpty && sharedCount > 0, "other shared mailbox still synced (\(sharedCount))")
        await sync.openMailbox(shared)
        try await sync.removeMailbox(shared)
        let left = try sharedFolders.reduce(0) { $0 + (try store.messageCount(folderId: $1.id)) }
        check(try store.folders(mailbox: shared).isEmpty && left == 0, "remove → folders + headers purged")
        check(try store.value(for: "openedMailbox:\(shared)") == nil && sharedFolders.allSatisfy { (try? store.value(for: "mdelta:\($0.id)")) ?? nil == nil },
              "remove → opened + delta keys cleared (re-add starts clean)")
        let mbs = await sync.mailboxes, pins = await sync.settings.pinnedMailboxes
        check(!mbs.contains(shared) && !pins.contains(shared), "remove → out of the sync set and unpinned")
        await sync.reorder(mailboxes: [principal])
        check(await sync.mailboxes.first == "me", "reorder keeps me first")
    } catch { check(false, "mailbox remove threw \(error)") }

    section("Microsoft 365 Groups: Graph client against canned JSON (labels, fail closed, explicit send)")
    let guid = FixtureCalendarService.labels[2].id
    MailStub.log = []
    MailStub.handler = { req, body in
        let path = req.url!.path, q = req.url!.query ?? "", m = req.httpMethod ?? "GET"
        switch (m, path) {
        case ("GET", "/v1.0/me/memberOf/microsoft.graph.group"):
            if req.value(forHTTPHeaderField: "ConsistencyLevel") == "eventual" { flags.hit("gcl") }
            return (200, [:], #"{"value":[{"id":"g2","displayName":"Zeta"},{"id":"g1","displayName":"Alpha","mail":"alpha@contoso.example"}]}"#)
        case ("GET", "/v1.0/groups/g1"): return (200, [:], #"{"id":"g1","unseenCount":3}"#)
        case ("GET", "/v1.0/groups/g1/conversations"):
            return (200, [:], #"{"value":[{"id":"c1","topic":"T","preview":"p","lastDeliveredDateTime":"2026-11-18T09:00:00Z","hasAttachments":false,"uniqueSenders":["A"]}]}"#)
        case ("GET", "/v1.0/groups/g1/conversations/c1/threads"): return (200, [:], #"{"value":[{"id":"t1","topic":"T"}]}"#)
        case ("GET", "/v1.0/groups/g1/threads/t1/posts"):
            return (200, [:], #"{"value":[{"id":"p1","receivedDateTime":"2026-11-18T09:00:00Z","body":{"contentType":"html","content":"<p>x</p>"},"from":{"emailAddress":{"name":"A","address":"a@contoso.example"}},"singleValueExtendedProperties":[{"id":"String {00020386-0000-0000-c000-000000000046} Name msip_labels","value":"MSIP_Label_\#(guid)_Enabled=true; MSIP_Label_\#(guid)_SiteId=t"}]},{"id":"p2","receivedDateTime":"2026-11-18T10:00:00Z","body":{"contentType":"html","content":"<p>y</p>"}}]}"#)
        case ("GET", "/v1.0/groups/g1/threads/t2/posts"):
            if q.contains("expand") { return (400, [:], #"{"error":{"code":"BadRequest"}}"#) }
            return (200, [:], #"{"value":[{"id":"p3","body":{"contentType":"html","content":"<p>z</p>"}},{"id":"p4","body":{"contentType":"text","content":"w"}}]}"#)
        case ("GET", "/v1.0/groups/g1/threads/t2/posts/p3"): return (200, [:], #"{"id":"p3","singleValueExtendedProperties":[]}"#)
        case ("GET", "/v1.0/groups/g1/threads/t2/posts/p4"): return (500, [:], #"{"error":{"code":"Internal"}}"#)
        case ("POST", "/v1.0/groups/g1/threads/t1/reply"):
            flags.hit("reply")
            let ok = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]).flatMap { ($0["post"] as? [String: Any])?["body"] as? [String: Any] }?["contentType"] as? String == "html"
            if ok { flags.hit("replyShape") }
            return (202, [:], "")
        case ("POST", "/v1.0/groups/g1/threads/t9/reply"):
            flags.hit("reply503")
            return (503, ["Retry-After": "0"], #"{"error":{"code":"ServiceUnavailable"}}"#)
        case ("POST", "/v1.0/groups/g1/conversations"):
            let o = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            if o?["topic"] as? String == "Hello", let th = o?["threads"] as? [[String: Any]], (th.first?["posts"] as? [[String: Any]])?.count == 1 { flags.hit("newShape") }
            return (201, [:], #"{"id":"c-new"}"#)
        default: return (404, [:], #"{"error":{"code":"NotFound"}}"#)
        }
    }
    let gsvc = GraphGroupsService(readToken: { "r" }, writeToken: { "w" }, session: session)
    let engine = mailEngine()
    do {
        let groups = try await gsvc.myGroups()
        check(groups.map(\.displayName) == ["Alpha", "Zeta"], "memberships listed, sorted by name")
        check(flags.count("gcl") == 1 && MailStub.captured().contains { $0.query.contains("groupTypes/any") && $0.query.contains("$count=true") },
              "Unified filter sent as an advanced query ($count + ConsistencyLevel)")
        check(try await gsvc.unseenCount(groupId: "g1") == 3, "unseenCount read per group")
        let conv = try await gsvc.conversations(groupId: "g1", top: 50)
        check(conv.first?.topic == "T", "conversations decoded")
        let posts = try await gsvc.posts(groupId: "g1", threadId: "t1")
        check(MailStub.captured().contains { $0.path.hasSuffix("/threads/t1/posts") && $0.query.contains("singleValueExtendedProperties") },
              "posts requested with the msip_labels expand")
        check(posts.first(where: { $0.id == "p1" })?.label == .label(guid) && posts.first(where: { $0.id == "p2" })?.label == GroupPostLabel.none,
              "label read from the post; absent property = unlabelled")
        let p1 = posts.first { $0.id == "p1" }!
        check(GroupPostPolicy.policy(for: p1, engine: engine).labelState != .unlabeled, "labelled post goes through the label policy")
        check(GroupPostPolicy.replyRefusal(posts: posts, engine: engine) == GroupPostPolicy.labelledReplyReason, "reply to a labelled thread refused")
        check(GroupPostPolicy.replyRefusal(posts: posts.filter { $0.id == "p2" }, engine: engine) == nil, "reply to an unlabelled thread allowed")
        let fb = try await gsvc.posts(groupId: "g1", threadId: "t2")
        check(fb.first(where: { $0.id == "p3" })?.label == GroupPostLabel.none && fb.first(where: { $0.id == "p4" })?.label == .unknown,
              "expand refused → per-post label fetch; unreadable → unknown")
        let pol4 = GroupPostPolicy.policy(for: fb.first { $0.id == "p4" }!, engine: engine)
        if case .unknown = pol4.labelState { check(!pol4.allowCopy && !pol4.allowOfflineDetails && pol4.preventScreenCapture, "unknown post label fails closed") }
        else { check(false, "unknown post label should be .unknown") }
        check(GroupPostPolicy.replyRefusal(posts: fb, engine: engine) != nil, "reply refused while a label is unreadable")
        check(fb.first { $0.id == "p4" }?.bodyIsHTML == false, "text body kept as text")
    } catch { check(false, "groups read threw \(error)") }
    do {
        try await gsvc.reply(groupId: "g1", threadId: "t1", html: "<p>hi</p>")
        check(flags.count("reply") == 1 && flags.count("replyShape") == 1, "reply → one POST {post:{body:{contentType:html}}} (stub only)")
        try await gsvc.newConversation(groupId: "g1", topic: "Hello", html: "<p>hi</p>")
        check(flags.count("newShape") == 1, "new conversation → POST {topic, threads:[{posts:[…]}]} (stub only)")
    } catch { check(false, "groups write threw \(error)") }
    do { try await gsvc.reply(groupId: "g1", threadId: "t9", html: "<p>hi</p>"); check(false, "503 reply should throw") }
    catch { check(flags.count("reply503") == 1, "a 503 on a post is not retried (it may have been applied)") }
    MailStub.handler = nil

    section("Microsoft 365 Groups: fixtures never send anywhere")
    do {
        let fx = FixtureGroupsService()
        let gs = try await fx.myGroups()
        let posts = try await fx.posts(groupId: FixtureGroupsService.projectGroup, threadId: "th-conv-pf-3")
        check(!gs.isEmpty && posts.first?.label == .unknown, "fixture groups include an unreadable-label post")
        try await fx.reply(groupId: FixtureGroupsService.projectGroup, threadId: "th-conv-pf-1", html: "<p>x</p>")
        check(fx.sent.count == 1, "fixture reply recorded in memory")
    } catch { check(false, "fixture groups threw \(error)") }
}
