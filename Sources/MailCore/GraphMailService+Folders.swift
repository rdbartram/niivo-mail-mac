import Foundation

/// Folder tree + folder management over Graph v1.0 `mailFolder`.
///  * Tree: `/mailFolders` (top level) then `/mailFolders/{id}/childFolders` per folder with `childFolderCount > 0`,
///    level by level, every page (`@odata.nextLink`). The per-mailbox limiter caps parallelism at 4.
///  * create `POST /mailFolders` | `POST /mailFolders/{id}/childFolders`; rename `PATCH /mailFolders/{id}`
///    (`displayName`); move `POST /mailFolders/{id}/move` (`destinationId`); delete `DELETE /mailFolders/{id}`
///    (documented: the folder goes to Deleted Items).
///  * UNVERIFIED: `msgfolderroot` accepted as a folder-move `destinationId` (well-known names are accepted for
///    message moves; the folder-move page wasn't fetched for this).
///  * UNVERIFIED: a folder keeps its id across move / delete-to-Deleted-Items (EWS ids are stable for folders; the
///    store re-reads the tree after every change, so a new id only costs a refresh).
///  * UNVERIFIED: `DELETE /messages/{id}` from Junk lands in Deleted Items, from Deleted Items in Recoverable Items.
extension GraphMailService {
    // MARK: Tree

    /// Every folder below `roots` (any depth), parents before children.
    func childFolderTree(of roots: [GMFolder], mailbox: String) async throws -> [GMFolder] {
        var out: [GMFolder] = [], seen = Set(roots.map(\.id))
        var level = roots.filter { ($0.childFolderCount ?? 0) > 0 }.map(\.id)
        while !level.isEmpty {
            let pages = try await withThrowingTaskGroup(of: (Int, [GMFolder]).self) { group in
                for (i, id) in level.enumerated() {
                    group.addTask { (i, try await self.childFolders(of: id, mailbox: mailbox)) }
                }
                var r: [(Int, [GMFolder])] = []
                for try await x in group { r.append(x) }
                return r.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
            var next: [String] = []
            for c in pages where seen.insert(c.id).inserted {
                out.append(c)
                if (c.childFolderCount ?? 0) > 0 { next.append(c.id) }
            }
            level = next
        }
        return out
    }

    func childFolders(of id: String, mailbox: String) async throws -> [GMFolder] {
        var out: [GMFolder] = []
        var next: URL? = url("\(p(mailbox))/mailFolders/\(id)/childFolders", ["$top": "100", "$select": Self.folderSelect])
        while let u = next {
            let page: GMPage<GMFolder> = try await get(u, mailbox: mailbox)
            out += page.value; next = page.nextLink.flatMap(URL.init(string:))
        }
        return out
    }

    // MARK: CRUD

    private func refuseWellKnown(_ id: String, mailbox: String) throws {
        let known = lock.withLock { wellKnownIds[mailbox] ?? [] }
        if known.contains(id) || WellKnownFolder(rawValue: id.lowercased()) != nil || id.lowercased() == "msgfolderroot" {
            throw MailFolderError.protected
        }
    }

    private func model(_ g: GMFolder, parentId: String?, mailbox: String) -> MailFolder {
        MailFolder(id: g.id, displayName: g.displayName ?? "", parentId: parentId, wellKnown: nil,
                   unreadCount: g.unreadItemCount ?? 0, totalCount: g.totalItemCount ?? 0, mailbox: mailbox)
    }

    private func mapConflict<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch MailServiceError.conflict { throw MailFolderError.nameTaken }
        catch MailServiceError.offline { throw MailFolderError.offline }
        catch MailServiceError.http(400, let m) where m.contains("ErrorFolderExists") { throw MailFolderError.nameTaken }
    }

    public func createFolder(displayName: String, parentId: String?, mailbox: String) async throws -> MailFolder {
        guard let name = FolderTree.cleanName(displayName) else { throw MailFolderError.invalidName }
        let path = parentId.map { "\(p(mailbox))/mailFolders/\($0)/childFolders" } ?? "\(p(mailbox))/mailFolders"
        let g: GMFolder = try await mapConflict {
            try await send(url(path), method: "POST", mailbox: mailbox, json: ["displayName": name, "isHidden": false])
        }
        return model(g, parentId: parentId, mailbox: mailbox)
    }

    public func renameFolder(id: String, displayName: String, mailbox: String) async throws -> MailFolder {
        try refuseWellKnown(id, mailbox: mailbox)
        guard let name = FolderTree.cleanName(displayName) else { throw MailFolderError.invalidName }
        let g: GMFolder = try await mapConflict {
            try await send(url("\(p(mailbox))/mailFolders/\(id)"), method: "PATCH", mailbox: mailbox, json: ["displayName": name])
        }
        return model(g, parentId: parentOf(g, mailbox: mailbox), mailbox: mailbox)
    }

    public func moveFolder(id: String, toParentId: String?, mailbox: String) async throws -> MailFolder {
        try refuseWellKnown(id, mailbox: mailbox)
        if toParentId == id { throw MailFolderError.invalidDestination }
        let g: GMFolder = try await mapConflict {
            try await send(url("\(p(mailbox))/mailFolders/\(id)/move"), method: "POST", mailbox: mailbox,
                           json: ["destinationId": toParentId ?? "msgfolderroot"])
        }
        return model(g, parentId: toParentId, mailbox: mailbox)
    }

    public func deleteFolder(id: String, mailbox: String) async throws {
        try refuseWellKnown(id, mailbox: mailbox)
        let _: GMEmpty = try await mapConflict {
            try await send(url("\(p(mailbox))/mailFolders/\(id)"), method: "DELETE", mailbox: mailbox, json: nil)
        }
    }

    /// Top-level folders report msgfolderroot as their parent; that maps to nil.
    private func parentOf(_ g: GMFolder, mailbox: String) -> String? {
        let root = lock.withLock { rootIds[mailbox] ?? nil }
        guard let pid = g.parentFolderId, pid != root else { return nil }
        return pid
    }

    // MARK: Bulk

    public func markAllRead(folderId: String, mailbox: String) async throws -> Int {
        let ids = try await messageIds(folderId, mailbox: mailbox, filter: "isRead eq false")
        return try await batch(ids, mailbox: mailbox) { id in
            ["method": "PATCH", "url": "/\(p(mailbox))/messages/\(id)", "headers": ["Content-Type": "application/json"],
             "body": ["isRead": true]]
        }
    }

    public func emptyFolder(folderId: String, mailbox: String) async throws -> Int {
        // All ids first, then delete: paging a nextLink while deleting from the same folder skips items.
        let ids = try await messageIds(folderId, mailbox: mailbox, filter: nil)
        let n = try await batch(ids, mailbox: mailbox) { id in ["method": "DELETE", "url": "/\(p(mailbox))/messages/\(id)"] }
        for c in try await childFolders(of: folderId, mailbox: mailbox) {
            let _: GMEmpty = try await send(url("\(p(mailbox))/mailFolders/\(c.id)"), method: "DELETE", mailbox: mailbox, json: nil)
        }
        return n
    }

    private func messageIds(_ folderId: String, mailbox: String, filter: String?) async throws -> [String] {
        var q = ["$select": "id", "$top": "100"]
        if let filter { q["$filter"] = filter }
        var out: [String] = []
        var next: URL? = url("\(p(mailbox))/mailFolders/\(folderId)/messages", q)
        while let u = next {
            let page: GMPage<GMFolder> = try await get(u, mailbox: mailbox)   // only `id` is read
            out += page.value.map(\.id); next = page.nextLink.flatMap(URL.init(string:))
        }
        return out
    }

    /// `$batch`, 20 sub-requests per call. Returns the number that succeeded; throws `.partial` if any failed.
    private func batch(_ ids: [String], mailbox: String, _ make: (String) -> [String: Any]) async throws -> Int {
        var done = 0, failed = 0, start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 20, ids.count)]); start += 20
            let reqs: [[String: Any]] = chunk.enumerated().map { i, id in
                var r = make(id); r["id"] = "\(i)"; return r
            }
            let resp: GMBatch = try await send(url("$batch"), method: "POST", mailbox: mailbox, json: ["requests": reqs])
            let ok = resp.responses.filter { (200..<300).contains($0.status) }.count
            done += ok; failed += chunk.count - ok
        }
        if failed > 0 { throw MailFolderError.partial(done: done, failed: failed) }
        return done
    }
}
