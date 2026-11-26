import Foundation

/// Folder management: validated locally first (well-known folders never reach the network), applied optimistically
/// to the store, reverted when the server refuses. Online-only (not queued in the outbox): a created folder needs
/// its server id before anything can go into it; offline surfaces as `MailFolderError.offline`.
public extension MailSync {
    func createFolder(name: String, parentId: String?, mailbox: String) async throws -> MailFolder {
        guard FolderTree.cleanName(name) != nil else { throw MailFolderError.invalidName }
        if let parentId {
            guard let parent = try store.folder(id: parentId) else { throw MailServiceError.notFound }
            guard parent.mailbox == mailbox else { throw MailFolderError.invalidDestination }
        }
        let f = try await online { try await service.createFolder(displayName: name, parentId: parentId, mailbox: mailbox) }
        try store.upsert(folder: f)
        onChange(.folders(mailbox: mailbox))
        return f
    }

    func renameFolder(id: String, to name: String) async throws {
        let f = try mutableFolder(id)
        guard let clean = FolderTree.cleanName(name) else { throw MailFolderError.invalidName }
        guard clean != f.displayName else { return }
        var optimistic = f; optimistic.displayName = clean
        try await optimisticFolder(optimistic, revert: f) {
            var r = try await self.service.renameFolder(id: id, displayName: clean, mailbox: f.mailbox)
            r.parentId = f.parentId; r.unreadCount = f.unreadCount; r.totalCount = f.totalCount
            return r
        }
    }

    /// `toParentId == nil` → top level.
    func moveFolder(id: String, toParentId: String?) async throws {
        let f = try mutableFolder(id)
        let all = try store.folders(mailbox: f.mailbox)
        let dest = try toParentId.map { pid -> MailFolder in
            guard let d = try store.folder(id: pid) else { throw MailServiceError.notFound }
            return d
        }
        guard FolderTree.canMove(f, to: dest, in: all) else { throw MailFolderError.invalidDestination }
        var optimistic = f; optimistic.parentId = toParentId
        try await optimisticFolder(optimistic, revert: f) {
            var r = try await self.service.moveFolder(id: id, toParentId: toParentId, mailbox: f.mailbox)
            r.parentId = toParentId; r.unreadCount = f.unreadCount; r.totalCount = f.totalCount
            return r
        }
    }

    /// To Deleted Items (the sub-tree goes with it); already inside Deleted Items → removed for good.
    func deleteFolder(id: String) async throws {
        let f = try mutableFolder(id)
        let all = try store.folders(mailbox: f.mailbox)
        let trash = try store.folder(wellKnown: .deleteditems, mailbox: f.mailbox)
        let inTrash = trash.map { FolderTree.descendants(of: $0.id, in: all).contains(id) } ?? false
        if inTrash || trash == nil {
            try await online { try await service.deleteFolder(id: id, mailbox: f.mailbox) }
            try store.removeFolders(ids: FolderTree.descendants(of: id, in: all).union([id]))
            onChange(.folders(mailbox: f.mailbox))
        } else {
            var moved = f; moved.parentId = trash?.id
            let optimistic = moved
            try await optimisticFolder(optimistic, revert: f) {
                try await self.service.deleteFolder(id: id, mailbox: f.mailbox)
                return optimistic
            }
        }
        await refreshFolderTree(f.mailbox)
    }

    /// Returns how many messages the server marked read.
    @discardableResult
    func markAllRead(folderId: String) async throws -> Int {
        guard let f = try store.folder(id: folderId) else { throw MailServiceError.notFound }
        let changed = try store.markAllReadLocally(folderId: folderId)
        onChange(.messages(ids: changed)); onChange(.folders(mailbox: f.mailbox))
        do {
            return try await online { try await service.markAllRead(folderId: folderId, mailbox: f.mailbox) }
        } catch {
            if case MailFolderError.partial = error {} else {
                try? store.markUnreadLocally(ids: changed, folderId: folderId, unreadCount: f.unreadCount)
                onChange(.messages(ids: changed)); onChange(.folders(mailbox: f.mailbox))
            }
            throw error
        }
    }

    /// Deleted Items / Junk only. Returns how many messages were deleted.
    @discardableResult
    func emptyFolder(folderId: String) async throws -> Int {
        guard let f = try store.folder(id: folderId) else { throw MailServiceError.notFound }
        guard f.canEmpty else { throw MailFolderError.protected }
        let all = try store.folders(mailbox: f.mailbox)
        var partial: Error?
        var n = 0
        do { n = try await online { try await service.emptyFolder(folderId: folderId, mailbox: f.mailbox) } }
        catch MailFolderError.partial(let d, let x) { partial = MailFolderError.partial(done: d, failed: x); n = d }
        let ids = try store.messages(folderId: folderId, limit: 1_000_000).map(\.id)
        try store.deleteMessages(ids: ids, folderId: folderId)
        try store.removeFolders(ids: FolderTree.descendants(of: folderId, in: all))
        var g = f; g.unreadCount = 0; g.totalCount = 0
        try store.upsert(folder: g)
        onChange(.messages(ids: ids)); onChange(.folders(mailbox: f.mailbox))
        if let partial { await refreshFolderTree(f.mailbox); throw partial }
        return n
    }

    /// Re-read the tree from the server (ids may change on move/delete). Keeps local placeholders. Best effort.
    func refreshFolderTree(_ mailbox: String) async {
        guard let fresh = try? await service.folders(mailbox: mailbox),
              let placeholders = try? store.folders(mailbox: mailbox).filter({ $0.id.hasPrefix("local-") }) else { return }
        try? store.replace(folders: fresh, mailbox: mailbox)
        for p in placeholders where !fresh.contains(where: { $0.wellKnown == p.wellKnown }) { try? store.upsert(folder: p) }
        onChange(.folders(mailbox: mailbox))
    }

    // MARK: Internals

    private func mutableFolder(_ id: String) throws -> MailFolder {
        guard let f = try store.folder(id: id) else { throw MailServiceError.notFound }
        if f.isProtected || f.id.hasPrefix("local-") { throw MailFolderError.protected }
        return f
    }

    private func online<T: Sendable>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() } catch MailServiceError.offline { throw MailFolderError.offline }
    }

    private func optimisticFolder(_ optimistic: MailFolder, revert: MailFolder,
                                  _ op: @Sendable () async throws -> MailFolder) async throws {
        try store.upsert(folder: optimistic)
        onChange(.folders(mailbox: revert.mailbox))
        do {
            let r = try await online(op)
            if r.id != revert.id { try store.removeFolders(ids: [revert.id]) }
            try store.upsert(folder: r)
            onChange(.folders(mailbox: revert.mailbox))
        } catch {
            try? store.upsert(folder: revert)
            onChange(.folders(mailbox: revert.mailbox))
            throw error
        }
    }
}
