import Foundation

// Scoped list search: this folder / this mailbox / all mailboxes (own + added). Groups are matched separately
// (GroupSearch in MailOrganise.swift) because Graph has no $search on group conversations.

public struct ScopedSearchResult: Sendable {
    public var messages: [MailMessage]
    /// Server hits dropped because their folder isn't cached for that mailbox (open the mailbox once to include them):
    /// without the folder we can't attribute the hit to the right mailbox, so its policy and reader path would be wrong.
    public var unattributed: Int
    public init(messages: [MailMessage], unattributed: Int) { self.messages = messages; self.unattributed = unattributed }   // SEARCHBOX-HOOK
}

extension MailSync {
    /// Search over a scope: one folder, one mailbox, or several mailboxes (merged newest first, de-duplicated).
    public func search(_ text: String, scope: MailSearchScope, mailbox: String, folderId: String?, allMailboxes: [String],
                       limit: Int = 100, includeServer: Bool = true) async -> ScopedSearchResult {
        let boxes = SearchScopePlan.mailboxes(scope: scope, current: mailbox, all: allMailboxes)
        var pages: [[MailMessage]] = []
        var dropped = 0
        for mb in boxes {
            let hits = await search(text, mailbox: mb, limit: limit, includeServer: includeServer)
            var kept: [MailMessage] = []
            for m in hits {
                let known = ((try? store.folder(id: m.folderId)) ?? nil) != nil
                if !known || store.mailbox(forFolder: m.folderId) != mb { dropped += 1; continue }
                if scope == .folder, let folderId, m.folderId != folderId { continue }
                kept.append(m)
            }
            pages.append(kept)
        }
        return ScopedSearchResult(messages: SearchMerge.newestFirst(pages, limit: limit), unattributed: dropped)
    }
}

public enum SearchMerge {
    /// Newest first by received date (search results aren't keyset-ordered), de-duplicated.
    public static func newestFirst(_ pages: [[MailMessage]], limit: Int) -> [MailMessage] {
        var seen = Set<String>()
        return Array(pages.joined().sorted { ($0.received, $0.id) > ($1.received, $1.id) }
            .filter { seen.insert($0.id).inserted }.prefix(limit))
    }
}
