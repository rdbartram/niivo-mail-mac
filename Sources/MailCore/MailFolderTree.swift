import Foundation

/// Why a folder operation was refused before (or instead of) reaching the server.
public enum MailFolderError: Error, Sendable, Equatable {
    /// Inbox, Sent Items, Drafts, Deleted Items, Archive, Junk, Outbox and Snoozed can't be renamed, moved or deleted.
    case protected
    case invalidName
    /// Into itself, one of its own sub-folders, or another mailbox.
    case invalidDestination
    /// Graph 409: a sibling with that name exists.
    case nameTaken
    /// Folder changes need a connection (they are not queued in the outbox: create needs the server id).
    case offline
    /// A bulk operation ($batch) where some items failed.
    case partial(done: Int, failed: Int)

    public var userText: String {
        switch self {
        case .protected: "Built-in folders can't be renamed, moved or deleted"
        case .invalidName: "Folder names can't be empty"
        case .invalidDestination: "A folder can't move into itself, one of its sub-folders or another mailbox"
        case .nameTaken: "A folder with that name already exists here"
        case .offline: "You're offline. Folder changes need a connection."
        case .partial(let d, let f): "\(d) done, \(f) couldn't be changed. Try again."
        }
    }
}

public extension MailFolder {
    /// Well-known folders (incl. the client-side Snoozed folder) are fixed.
    var isProtected: Bool { wellKnown != nil }
    /// "Empty folder" is offered for Deleted Items and Junk only.
    var canEmpty: Bool { wellKnown == .deleteditems || wellKnown == .junkemail }
}

/// One visible sidebar row of a folder tree.
public struct FolderTreeRow: Sendable, Hashable, Identifiable {
    public var folder: MailFolder
    public var depth: Int
    public var hasChildren: Bool
    public var isExpanded: Bool
    public var id: String { folder.id }
}

/// Pure tree helpers over a mailbox's flat folder list (`parentId == nil` = top level).
public enum FolderTree {
    public static func children(_ folders: [MailFolder]) -> [String: [MailFolder]] {
        let ids = Set(folders.map(\.id))
        var out: [String: [MailFolder]] = [:]
        // Orphans (parent unknown locally) show at the top level rather than vanish.
        for f in folders { out[f.parentId.flatMap { ids.contains($0) ? $0 : nil } ?? "", default: []].append(f) }
        return out
    }

    /// Depth-first rows; children only under expanded parents. `order` sorts siblings.
    public static func rows(_ folders: [MailFolder], expanded: Set<String>,
                            order: (MailFolder, MailFolder) -> Bool = { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
        -> [FolderTreeRow] {
        let kids = children(folders)
        var out: [FolderTreeRow] = [], seen = Set<String>()
        func walk(_ parent: String, _ depth: Int) {
            for f in (kids[parent] ?? []).sorted(by: order) where seen.insert(f.id).inserted {
                let has = !(kids[f.id] ?? []).isEmpty, open = expanded.contains(f.id)
                out.append(FolderTreeRow(folder: f, depth: depth, hasChildren: has, isExpanded: open))
                if has && open { walk(f.id, depth + 1) }
            }
        }
        walk("", 0)
        return out
    }

    /// All sub-folder ids (any depth).
    public static func descendants(of id: String, in folders: [MailFolder]) -> Set<String> {
        let kids = children(folders)
        var out = Set<String>(), stack = [id]
        while let n = stack.popLast() {
            for c in kids[n] ?? [] where out.insert(c.id).inserted { stack.append(c.id) }
        }
        return out
    }

    /// Ancestor ids, nearest first (for expanding the path to a folder).
    public static func ancestors(of id: String, in folders: [MailFolder]) -> [String] {
        let byId = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = [], cur = byId[id]?.parentId
        while let c = cur, byId[c] != nil, !out.contains(c) { out.append(c); cur = byId[c]?.parentId }
        return out
    }

    /// Whether `folder` may move under `parent` (nil = top level).
    public static func canMove(_ folder: MailFolder, to parent: MailFolder?, in folders: [MailFolder]) -> Bool {
        guard !folder.isProtected else { return false }
        guard let parent else { return folder.parentId != nil }
        if parent.mailbox != folder.mailbox || parent.id == folder.id || parent.id == folder.parentId { return false }
        return !descendants(of: folder.id, in: folders).contains(parent.id)
    }

    public static func cleanName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
