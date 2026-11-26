import Foundation
import CalendarCore
import MailCore

private func gfolder(_ id: String, _ name: String, parent: String, kids: Int = 0, unread: Int = 0) -> String {
    #"{"id":"\#(id)","displayName":"\#(name)","parentFolderId":"\#(parent)","unreadItemCount":\#(unread),"totalItemCount":5,"childFolderCount":\#(kids)}"#
}

private func jsonBody(_ d: Data?) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: d ?? Data())) as? [String: Any]) ?? [:] }

private func fld(_ s: MailStore, _ id: String) -> MailFolder? { (try? s.folder(id: id)) ?? nil }

@MainActor
func runMailFolderTests() async {
    section("Mail folders: recursive tree (paging), CRUD request shapes, well-known protection, store updates")
    let host = "https://graph.microsoft.com/v1.0"
    MailStub.lock.withLock { MailStub.log.removeAll() }
    MailStub.handler = { req, body in
        let path = req.url!.path, q = req.url!.query ?? "", m = req.httpMethod ?? "GET"
        let b = String(data: body ?? Data(), encoding: .utf8) ?? ""
        switch (m, path) {
        case ("GET", "/v1.0/me/mailFolders"):
            return (200, [:], #"{"value":[\#(gfolder("inbox-id", "Inbox", parent: "root", kids: 1, unread: 3)),\#(gfolder("proj", "Projects", parent: "root", kids: 2)),\#(gfolder("trash-id", "Deleted Items", parent: "root"))]}"#)
        case ("POST", "/v1.0/$batch") where b.contains("PATCH"):
            let n = (jsonBody(body)["requests"] as? [[String: Any]])?.count ?? 0
            return (200, [:], #"{"responses":[\#((0..<n).map { #"{"id":"\#($0)","status":200,"body":{"id":"x"}}"# }.joined(separator: ","))]}"#)
        case ("POST", "/v1.0/$batch"):
            return (200, [:], #"{"responses":[{"id":"0","status":200,"body":{"id":"inbox-id"}},{"id":"3","status":200,"body":{"id":"trash-id"}}]}"#)
        case ("GET", "/v1.0/me/mailFolders/inbox-id/childFolders"):
            return (200, [:], #"{"value":[\#(gfolder("sub1", "Clients", parent: "inbox-id", kids: 1))]}"#)
        case ("GET", "/v1.0/me/mailFolders/sub1/childFolders"):
            return (200, [:], #"{"value":[\#(gfolder("deep", "Acme", parent: "sub1"))]}"#)
        case ("GET", "/v1.0/me/mailFolders/proj/childFolders"):
            if q.contains("skiptoken=c2") { return (200, [:], #"{"value":[\#(gfolder("b", "Beta", parent: "proj"))]}"#) }
            return (200, [:], #"{"value":[\#(gfolder("a", "Alpha", parent: "proj"))],"@odata.nextLink":"\#(host)/me/mailFolders/proj/childFolders?$skiptoken=c2"}"#)
        case ("POST", "/v1.0/me/mailFolders"):
            if b.contains("Dup") { return (409, [:], #"{"error":{"code":"ErrorFolderExists"}}"#) }
            return (201, [:], gfolder("new-top", "Top", parent: "root"))
        case ("POST", "/v1.0/me/mailFolders/proj/childFolders"):
            return (201, [:], gfolder("new-sub", "Sub", parent: "proj"))
        case ("PATCH", "/v1.0/me/mailFolders/a"):
            return (200, [:], gfolder("a", "Alpha 2", parent: "proj"))
        case ("POST", "/v1.0/me/mailFolders/b/move"):
            let dest = jsonBody(body)["destinationId"] as? String ?? ""
            return (200, [:], gfolder("b", "Beta", parent: dest == "msgfolderroot" ? "root" : dest))
        case ("DELETE", "/v1.0/me/mailFolders/a"):
            return (204, [:], "")
        case ("GET", "/v1.0/me/mailFolders/inbox-id/messages"):
            return (200, [:], #"{"value":[{"id":"u1"},{"id":"u2"}]}"#)
        default:
            return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let svc = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
    func reqs() -> [MailStub.Captured] { MailStub.captured() }
    func clear() { MailStub.lock.withLock { MailStub.log.removeAll() } }
    do {
        let tree = try await svc.folders(mailbox: "me")
        let byId = Dictionary(tree.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        check(byId["deep"]?.parentId == "sub1" && byId["sub1"]?.parentId == "inbox-id" && byId["inbox-id"]?.parentId == nil,
              "tree loads nested children at any depth (Inbox › Clients › Acme), top level → parentId nil")
        check(byId["a"] != nil && byId["b"] != nil, "childFolders paging follows @odata.nextLink")
        check(!reqs().contains { $0.path.hasSuffix("/trash-id/childFolders") || $0.path.hasSuffix("/deep/childFolders") },
              "childFolders only asked for folders with childFolderCount > 0")
        check(byId["inbox-id"]?.wellKnown == .inbox && byId["trash-id"]?.wellKnown == .deleteditems && byId["proj"]?.wellKnown == nil,
              "well-known folders resolved alongside the tree")
        let rows = FolderTree.rows(tree, expanded: ["inbox-id"])
        check(rows.map(\.id).contains("sub1") && !rows.map(\.id).contains("deep") && rows.first { $0.id == "sub1" }?.depth == 1
              && rows.first { $0.id == "sub1" }?.hasChildren == true && !rows.map(\.id).contains("a"),
              "sidebar rows: only expanded parents show children, with depth")

        let store = try mailStore()
        let sync = MailSync(service: svc, store: store, compliance: mailEngine(), onChange: { _ in })
        await sync.refreshFolderTree("me")
        check(try store.folders(mailbox: "me").count == tree.count && fld(store, "deep")?.parentId == "sub1",
              "store holds the whole tree with parent ids")

        clear()
        let top = try await sync.createFolder(name: "  Top ", parentId: nil, mailbox: "me")
        let c1 = reqs().first
        check(c1?.method == "POST" && c1?.path == "/v1.0/me/mailFolders" && jsonBody(c1?.body)["displayName"] as? String == "Top"
              && top.parentId == nil && fld(store, "new-top") != nil, "create top-level: POST /mailFolders {displayName}, stored")
        clear()
        let sub = try await sync.createFolder(name: "Sub", parentId: "proj", mailbox: "me")
        check(reqs().first?.path == "/v1.0/me/mailFolders/proj/childFolders" && sub.parentId == "proj"
              && fld(store, "new-sub")?.parentId == "proj", "create sub-folder: POST /mailFolders/{id}/childFolders, stored under parent")
        do { _ = try await sync.createFolder(name: "Dup", parentId: nil, mailbox: "me"); check(false, "409 → nameTaken") }
        catch { check(error as? MailFolderError == .nameTaken, "create: Graph 409 → 'a folder with that name already exists'") }

        clear()
        try await sync.renameFolder(id: "a", to: "Alpha 2")
        let r1 = reqs().first
        check(r1?.method == "PATCH" && r1?.path == "/v1.0/me/mailFolders/a" && jsonBody(r1?.body)["displayName"] as? String == "Alpha 2"
              && fld(store, "a")?.displayName == "Alpha 2" && fld(store, "a")?.parentId == "proj",
              "rename: PATCH /mailFolders/{id} {displayName}, store updated, parent kept")

        clear()
        try await sync.moveFolder(id: "b", toParentId: "inbox-id")
        let mv = reqs().first
        check(mv?.method == "POST" && mv?.path == "/v1.0/me/mailFolders/b/move" && jsonBody(mv?.body)["destinationId"] as? String == "inbox-id"
              && fld(store, "b")?.parentId == "inbox-id", "move: POST /mailFolders/{id}/move {destinationId}, store re-parented")
        clear()
        try await sync.moveFolder(id: "b", toParentId: nil)
        check(jsonBody(reqs().first?.body)["destinationId"] as? String == "msgfolderroot" && fld(store, "b")?.parentId == nil,
              "move to top level → destinationId msgfolderroot, parentId nil")

        clear()
        for (label, op) in [("rename", { try await sync.renameFolder(id: "inbox-id", to: "X") }),
                            ("move", { try await sync.moveFolder(id: "trash-id", toParentId: "proj") }),
                            ("delete", { try await sync.deleteFolder(id: "inbox-id") })] as [(String, () async throws -> Void)] {
            do { try await op(); check(false, "\(label) of a well-known folder refused") }
            catch { check(error as? MailFolderError == .protected, "\(label) of a well-known folder refused (.protected)") }
        }
        do { _ = try await svc.renameFolder(id: "inbox-id", displayName: "X", mailbox: "me"); check(false, "service refuses well-known id") }
        catch { check(error as? MailFolderError == .protected, "Graph client also refuses well-known ids / names") }
        do { try await sync.moveFolder(id: "proj", toParentId: "new-sub"); check(false, "move into own sub-folder refused") }
        catch { check(error as? MailFolderError == .invalidDestination, "move into its own sub-folder refused") }
        check(reqs().isEmpty, "refused folder operations send no request")
        check(fld(store, "inbox-id")?.displayName == "Inbox", "store untouched by refused operations")

        clear()
        try await sync.deleteFolder(id: "a")
        check(reqs().first.map { $0.method == "DELETE" && $0.path == "/v1.0/me/mailFolders/a" } == true, "delete: DELETE /mailFolders/{id}")

        clear()
        try store.upsert(message: MailMessage(id: "u1", folderId: "inbox-id", conversationId: "c", subject: "s", from: nil, received: Date()))
        let n = try await sync.markAllRead(folderId: "inbox-id")
        let batch = reqs().first { $0.path == "/v1.0/$batch" }
        let sub0 = (jsonBody(batch?.body)["requests"] as? [[String: Any]])?.first
        check(n == 2 && sub0?["method"] as? String == "PATCH" && (sub0?["url"] as? String)?.hasSuffix("/messages/u1") == true
              && (sub0?["body"] as? [String: Any])?["isRead"] as? Bool == true
              && reqs().first?.query.contains("isRead") == true,
              "mark all as read: unread ids listed, $batch PATCH {isRead:true}")
        check(((try? store.message(id: "u1")) ?? nil)?.isRead == true && fld(store, "inbox-id")?.unreadCount == 0,
              "mark all as read: store updated optimistically (unread → 0)")
    } catch { failures += 1; print("  ✗ folder Graph tests threw \(error)") }

    // Fixture: delete → Deleted Items, delete again → gone, empty.
    do {
        let fx = FixtureMailService()
        let store = try mailStore()
        let sync = MailSync(service: fx, store: store, compliance: mailEngine(), onChange: { _ in })
        await sync.refreshFolderTree("me")
        let trash = FixtureMailService.folderId("me", .deleteditems)
        let f = try await sync.createFolder(name: "Old", parentId: nil, mailbox: "me")
        let child = try await sync.createFolder(name: "Older", parentId: f.id, mailbox: "me")
        try await sync.deleteFolder(id: f.id)
        check(fld(store, f.id)?.parentId == trash && fld(store, child.id)?.parentId == f.id,
              "fixture: delete moves the folder (with its sub-tree) into Deleted Items")
        try await sync.deleteFolder(id: child.id)
        check(fld(store, child.id) == nil, "fixture: delete inside Deleted Items removes it")
        _ = try await sync.emptyFolder(folderId: trash)
        let fxTree = try await fx.folders(mailbox: "me")
        check(fld(store, f.id) == nil && fxTree.allSatisfy { $0.parentId != trash },
              "empty Deleted Items removes its sub-folders too")
        do { _ = try await sync.emptyFolder(folderId: FixtureMailService.folderId("me", .inbox)); check(false, "empty Inbox refused") }
        catch { check(error as? MailFolderError == .protected, "empty is only for Deleted Items / Junk") }
        fx.simulateOffline = true
        do { try await sync.renameFolder(id: FixtureMailService.projectsFolderId, to: "P2"); check(false, "offline rename") }
        catch { check(error as? MailFolderError == .offline && fld(store, FixtureMailService.projectsFolderId)?.displayName == "Projects",
                      "offline: clear error, optimistic rename reverted") }
    } catch { failures += 1; print("  ✗ folder fixture tests threw \(error)") }
}
