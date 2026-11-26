import Foundation

public extension MailStore {
    /// Drop folder rows and every cached header in them (folder removed for good on the server).
    func removeFolders(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        var msgIds: [String] = []
        for id in ids { msgIds += try messages(folderId: id, limit: 1_000_000).map(\.id) }
        try deleteMessages(ids: msgIds)
        try transaction {
            for id in ids { try run("DELETE FROM folders WHERE id=?", [.text(id)]); folderMailbox[id] = nil }
        }
    }

    /// Optimistic "mark all as read": every cached unread header in the folder → read, unread count → 0.
    /// Returns the ids changed (to revert on failure).
    func markAllReadLocally(folderId: String) throws -> [String] {
        let unread = try messages(folderId: folderId, limit: 1_000_000).filter { !$0.isRead }
        try upsert(messages: unread.map { var m = $0; m.isRead = true; return m })
        if var f = try folder(id: folderId) { f.unreadCount = 0; try upsert(folder: f) }
        return unread.map(\.id)
    }

    /// Undo of `markAllReadLocally` (server refused / offline).
    func markUnreadLocally(ids: [String], folderId: String, unreadCount: Int) throws {
        let ms = try ids.compactMap { try message(id: $0, includeBody: false) }
        try upsert(messages: ms.map { var m = $0; m.isRead = false; return m })
        if var f = try folder(id: folderId) { f.unreadCount = unreadCount; try upsert(folder: f) }
    }
}
