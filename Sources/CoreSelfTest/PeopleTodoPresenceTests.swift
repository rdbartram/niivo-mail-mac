import Foundation
import CalendarCore
import MailCore

/// People (contacts CRUD shapes, merge), To Do (create with linkedResource, label-aware title, patch) and presence
/// (650-id batching, TTL cache, internal-only resolution) against the URLProtocol stub. Synthetic data only.
@MainActor
func runPeopleTodoPresenceTests() async {
    section("People / To Do / presence (stub)")
    MailStub.log = []
    MailStub.handler = { req, body in
        let u = req.url!, path = u.path, q = u.query ?? ""
        switch (req.httpMethod ?? "GET", path) {
        case ("GET", "/v1.0/me/contacts"):
            return (200, [:], #"{"value":[{"id":"c1","parentFolderId":"f1","displayName":"Marie Curie","emailAddresses":[{"name":"Marie","address":"Marie@Fabrikam.example"}],"businessPhones":["+41 1"],"jobTitle":"Scientist"}]}"#)
        case ("GET", "/v1.0/users/shared@contoso.example/contacts"):
            return (200, [:], #"{"value":[{"id":"s1","displayName":"Shared One","emailAddresses":[]}]}"#)
        case ("POST", "/v1.0/me/contacts"), ("POST", "/v1.0/me/contactFolders/f1/contacts"):
            let o = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:]
            return (201, [:], #"{"id":"new1","displayName":"\#(o["displayName"] as? String ?? "")","emailAddresses":[]}"#)
        case ("PATCH", "/v1.0/me/contacts/c1"):
            return (200, [:], #"{"id":"c1","displayName":"Marie S. Curie","emailAddresses":[]}"#)
        case ("DELETE", "/v1.0/me/contacts/c1"):
            return (204, [:], "")
        case ("GET", "/v1.0/users"):
            if q.contains("mail%20in") || q.contains("mail in") {
                // 15 per request; every internal address resolves except "ghost".
                let o = q.removingPercentEncoding ?? q
                let addrs = o.components(separatedBy: "'").filter { $0.contains("@") && !$0.hasPrefix("ghost") }
                let rows = addrs.map { #"{"id":"id-\#($0.split(separator: "@")[0])","mail":"\#($0)"}"# }
                return (200, [:], #"{"value":[\#(rows.joined(separator: ","))]}"#)
            }
            return (200, [:], #"{"value":[]}"#)
        case ("GET", "/v1.0/me/people"):
            return (200, [:], #"{"value":[{"id":"u-in","displayName":"In","scoredEmailAddresses":[{"address":"in@contoso.example"}],"personType":{"class":"Person","subclass":"OrganizationUser"}},{"id":"x-out","displayName":"Out","scoredEmailAddresses":[{"address":"out@fabrikam.example"}],"personType":{"class":"Person","subclass":"ImplicitContact"}}]}"#)
        case ("GET", "/v1.0/users/u1/manager"):
            return (403, [:], #"{"error":{"code":"Authorization_RequestDenied"}}"#)
        case ("GET", "/v1.0/users/u1/photos/96x96/$value"):
            return (404, [:], #"{"error":{"code":"ImageNotFound"}}"#)
        case ("POST", "/v1.0/me/todo/lists/L1/tasks"):
            return (201, [:], #"{"id":"T1","title":"x","status":"notStarted","isReminderOn":false}"#)
        case ("PATCH", "/v1.0/me/todo/lists/L1/tasks/T1"):
            return (200, [:], #"{"id":"T1","title":"x","status":"completed","dueDateTime":{"dateTime":"2026-11-25T00:00:00.0000000","timeZone":"UTC"}}"#)
        case ("GET", "/v1.0/me/todo/lists"):
            return (200, [:], #"{"value":[{"id":"L1","displayName":"Tasks","wellknownListName":"defaultList"},{"id":"L2","displayName":"Flagged email","wellknownListName":"flaggedEmails"}]}"#)
        case ("POST", "/v1.0/communications/getPresencesByUserId"):
            let o = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:]
            let ids = o["ids"] as? [String] ?? []
            let rows = ids.map { #"{"id":"\#($0)","availability":"Busy","activity":"InAMeeting"}"# }
            return (200, [:], #"{"value":[\#(rows.joined(separator: ","))]}"#)
        default:
            return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let session = URLSession(configuration: cfg)
    func bodyJSON(_ c: MailStub.Captured?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: c?.body ?? Data())) as? [String: Any] ?? [:]
    }

    // Contacts CRUD
    let people = GraphPeopleService(token: { "people-t" }, session: session, photoSession: session)
    do {
        let mine = try await people.contacts(folderId: nil, owner: nil)
        check(mine.count == 1 && mine[0].primaryAddress == "Marie@Fabrikam.example" && mine[0].folderId == "f1" && mine[0].owner == nil,
              "contacts decoded (address, folder)")
        check(MailStub.captured().contains { $0.path == "/v1.0/me/contacts" && $0.query.contains("select=") }, "contacts asked with $select")
        let shared = try await people.contacts(folderId: nil, owner: "shared@contoso.example")
        check(shared.first?.owner == "shared@contoso.example", "shared contacts via /users/{id}/contacts, owner kept")
        var draft = Contact(givenName: "Grace", surname: "Hopper", emails: [EmailAddress(name: "Grace", address: "grace@x.example")])
        draft.mobilePhone = nil
        let made = try await people.createContact(draft, folderId: "f1")
        let sent = bodyJSON(MailStub.captured().last { $0.method == "POST" && $0.path.hasSuffix("/contacts") })
        check(made.id == "new1" && sent["displayName"] as? String == "Grace Hopper" && sent["givenName"] as? String == "Grace"
              && ((sent["emailAddresses"] as? [[String: String]])?.first?["address"]) == "grace@x.example"
              && sent["mobilePhone"] is NSNull,
              "create: POST into the folder, display name derived, emails shape, cleared fields null")
        var edit = mine[0]; edit.displayName = "Marie S. Curie"
        let upd = try await people.updateContact(edit)
        check(upd.displayName == "Marie S. Curie" && MailStub.captured().contains { $0.method == "PATCH" && $0.path == "/v1.0/me/contacts/c1" },
              "update: PATCH /me/contacts/{id}")
        try await people.deleteContact(id: "c1")
        check(MailStub.captured().contains { $0.method == "DELETE" && $0.path == "/v1.0/me/contacts/c1" }, "delete: DELETE /me/contacts/{id}")
        do { _ = try await people.updateContact(shared[0]); check(false, "shared contact edit should be refused") }
        catch { check(true, "shared (other user's) contact is read-only here") }
        let mgr = try await people.manager(userId: "u1")
        check(mgr == nil, "manager 403 → nil (not an error)")
        let rel = try await people.relevantPeople(top: 10)
        check(rel.map(\.id) == ["u-in"], "/me/people: only OrganizationUser rows count as directory people (external dropped)")
        let photo = try await people.photo(userId: "u1")
        check(photo == nil, "photo 404 → no photo")
    } catch { check(false, "contacts threw \(error)") }

    // Merge
    var node = PersonNode(address: "ada@contoso.example"); node.names = ["Ada L": 3]; node.isInternal = true
    var news = PersonNode(address: "news@shop.example"); news.bulk = 5
    let merged = PeopleMerge.merge(
        contacts: [Contact(id: "c9", displayName: "Ada Lovelace", emails: [EmailAddress(name: "", address: "ADA@contoso.example")])],
        directory: [DirectoryPerson(id: "u-ada", displayName: "Ada (dir)", mail: "ada@contoso.example", jobTitle: "Head")],
        correspondents: [node, news])
    check(merged.count == 1 && merged[0].displayName == "Ada Lovelace" && merged[0].directoryId == "u-ada"
          && merged[0].sources == [.contact, .directory, .correspondent] && merged[0].jobTitle == "Head",
          "merge: one row per address, contact name wins, directory id kept, bulk senders dropped")

    // To Do: create from a message (label-aware), patch shapes
    let todo = GraphTodoService(token: { "todo-t" }, session: session)
    let link = URL(string: "https://outlook.office365.com/owa/?ItemID=abc")!
    let msg = MailMessage(id: "m1", folderId: "inbox", conversationId: "c", subject: "Budget 2027 — secret numbers",
                          from: EmailAddress(name: "A", address: "a@x.example"), toRecipients: [], received: Date(),
                          preview: "PREVIEW-SECRET", body: "BODY-SECRET", webLink: link)
    var open = ContentPolicy.open
    check(TodoFromMail.title(subject: msg.subject, policy: open) == msg.subject, "unlabelled: task title = subject")
    open.allowOfflineDetails = false
    check(TodoFromMail.title(subject: msg.subject, policy: open) == TodoFromMail.confidentialTitle, "no offline details → confidential title")
    var redacted = ContentPolicy.open; redacted.redactDetails = true
    check(TodoFromMail.title(subject: msg.subject, policy: redacted) == TodoFromMail.confidentialTitle, "redacted (private) → confidential title")
    let labelled = MailMessage(id: "m2", folderId: "inbox", conversationId: "c", subject: "Labelled", from: nil, toRecipients: [],
                               received: Date(), labelId: "a1f0c4e2-0000-4000-8000-0000000000ff")
    check(TodoFromMail.title(subject: labelled.subject, policy: MailContentPolicy.failClosed(for: labelled)) == TodoFromMail.confidentialTitle,
          "unknown label (fail closed) → confidential title")
    do {
        let d = TodoFromMail.draft(for: msg, policy: open, due: nil)
        _ = try await todo.create(listId: "L1", d)
        let o = bodyJSON(MailStub.captured().last { $0.method == "POST" && $0.path == "/v1.0/me/todo/lists/L1/tasks" })
        let lr = (o["linkedResources"] as? [[String: Any]])?.first ?? [:]
        let raw = String(data: MailStub.captured().last { $0.path == "/v1.0/me/todo/lists/L1/tasks" }?.body ?? Data(), encoding: .utf8) ?? ""
        check(o["title"] as? String == TodoFromMail.confidentialTitle && lr["displayName"] as? String == TodoFromMail.confidentialTitle
              && lr["webUrl"] as? String == link.absoluteString && lr["externalId"] as? String == "m1"
              && lr["applicationName"] as? String == TodoFromMail.applicationName,
              "create: linkedResource with webLink + message id, same label-aware title on task and link")
        check(!raw.contains("SECRET") && !raw.contains("Budget"), "no subject, preview or body leaves a confidential message")
        var nolink = msg; nolink.webLink = nil
        let d2 = TodoFromMail.draft(for: nolink, policy: .open)
        check(d2.linked.first?.webUrl == nil && d2.linked.first?.externalId == "m1" && d2.title == msg.subject,
              "no webLink → link carries the message id only")
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15))!
        let t = try await todo.update(listId: "L1", taskId: "T1", TodoPatch(status: .completed, due: .some(due), reminder: .some(nil)))
        let p = bodyJSON(MailStub.captured().last { $0.method == "PATCH" })
        check(p["status"] as? String == "completed" && (p["dueDateTime"] as? [String: String])?["dateTime"] == "2026-11-25T00:00:00.0000000"
              && p["reminderDateTime"] is NSNull && p["isReminderOn"] as? Bool == false,
              "patch: status, due date as dateTimeTimeZone, reminder cleared")
        check(t.isCompleted && t.due != nil, "patched task decoded")
        let lists = try await todo.lists()
        check(lists.map(\.kind) == [.defaultList, .flaggedEmails], "lists: well-known kinds (Flagged email list recognised)")
    } catch { check(false, "todo threw \(error)") }

    // Presence: batching, cache, internal resolution
    let presence = GraphPresenceService(token: { "presence-t" }, session: session)
    do {
        let ids = (0..<1301).map { "id\($0)" } + ["id0", "id1"]
        MailStub.log = []
        let got = try await presence.presences(ids: ids)
        let sizes = MailStub.captured().filter { $0.path == "/v1.0/communications/getPresencesByUserId" }
            .map { (bodyJSON($0)["ids"] as? [String])?.count ?? -1 }
        check(sizes == [650, 650, 1] && got.count == 1301, "1,301 ids (+2 duplicates) → 650/650/1, deduplicated (\(sizes))")
        check(got.first?.availability == .busy && got.first?.label == "In a meeting", "availability + activity decoded")
    } catch { check(false, "presence threw \(error)") }
    let clock = PresenceClock(fixed: Date(timeIntervalSince1970: 1_800_000_000))
    let cache = PresenceCache(service: presence, resolve: { try await people.directoryIds(addresses: $0) }, clock: clock,
                              ttl: 60, minInterval: 5)
    do {
        MailStub.log = []
        let addrs = (0..<20).map { "p\($0)@contoso.example" } + ["ghost@contoso.example"]
        let r1 = try await cache.lookup(addrs)
        let resolves = MailStub.captured().filter { $0.path == "/v1.0/users" }.count
        let posts = MailStub.captured().filter { $0.path.hasSuffix("getPresencesByUserId") }.count
        check(r1.count == 20 && r1["ghost@contoso.example"] == nil && resolves == 2 && posts == 1,
              "first lookup: 21 addresses resolved in chunks of 15 (\(resolves)), one presence POST, miss absent")
        clock.advance(10)
        _ = try await cache.lookup(addrs)
        check(MailStub.captured().count == resolves + posts, "within TTL: no network (miss negative-cached)")
        clock.advance(1)
        _ = try await cache.lookup(addrs)   // 11 s after the first round, before TTL
        clock.advance(55)                   // 66 s: stale
        let r3 = try await cache.lookup(addrs)
        let posts2 = MailStub.captured().filter { $0.path.hasSuffix("getPresencesByUserId") }.count
        let resolves2 = MailStub.captured().filter { $0.path == "/v1.0/users" }.count
        check(posts2 == 2 && resolves2 == resolves && r3.count == 20, "after TTL: one refresh POST, ids not resolved again")
        let r4 = try await cache.lookup(addrs + ["new@contoso.example"])
        check(r4.count == 20 && MailStub.captured().filter { $0.path.hasSuffix("getPresencesByUserId") }.count == 2,
              "rate limit: a new address within minInterval waits for the next round")
        let rounds = await cache.rounds
        check(rounds == 2, "two network rounds in total (\(rounds))")
    } catch { check(false, "presence cache threw \(error)") }
}
