import Foundation

// Message-list organisation: bulk plans, sweep, smart views, unified inbox, search scope + memory.
// Pure planners (no UI, no network) so CoreSelfTest can check them; the app wires them in MailBulk.swift.

// MARK: - Bulk

/// One bulk operation over a multi-selection.
public enum BulkOp: Sendable, Hashable {
    case markRead(Bool)
    case flag(Bool)
    case archive
    case delete
    /// Graph `move` can't cross mailboxes: targets in another mailbox are skipped.
    case move(folderId: String, mailbox: String)
    case addCategory(String)
    case removeCategory(String)
    case snooze(Date)
}

public struct BulkTarget: Sendable, Hashable {
    public var message: MailMessage
    public var mailbox: String
    public init(message: MailMessage, mailbox: String) { self.message = message; self.mailbox = mailbox }
}

public struct BulkStep: Sendable, Hashable {
    public var messageId: String
    public var action: MailAction
    public init(messageId: String, action: MailAction) { self.messageId = messageId; self.action = action }
}

public struct BulkPlan: Sendable, Hashable {
    public var steps: [BulkStep]
    /// Targets left alone (already in that state / folder, or in another mailbox).
    public var skipped: Int
    public var removesFromList: Bool
}

public enum BulkPlanner {
    /// `folder(wellKnown, mailbox)` resolves Archive / Deleted Items for each target's own mailbox.
    public static func plan(_ op: BulkOp, targets: [BulkTarget],
                            folder: (WellKnownFolder, String) -> String?) -> BulkPlan {
        var steps: [BulkStep] = []
        var skipped = 0
        for t in targets {
            let m = t.message
            let action: MailAction?
            switch op {
            case .markRead(let b): action = m.isRead == b ? nil : .markRead(b)
            case .flag(let on):
                let flagged = m.flag.status == .flagged
                action = flagged == on ? nil : .flag(FollowUpFlag(status: on ? .flagged : .notFlagged))
            case .archive:
                if let a = folder(.archive, t.mailbox), a != m.folderId { action = .move(toFolderId: a) } else { action = nil }
            case .delete:
                action = folder(.deleteditems, t.mailbox) == m.folderId ? nil : .delete
            case .move(let fid, let mb):
                action = (mb != t.mailbox || m.folderId == fid) ? nil : .move(toFolderId: fid)
            case .addCategory(let c):
                action = m.categories.contains { $0.caseInsensitiveCompare(c) == .orderedSame } ? nil : .categorize(m.categories + [c])
            case .removeCategory(let c):
                let kept = m.categories.filter { $0.caseInsensitiveCompare(c) != .orderedSame }
                action = kept.count == m.categories.count ? nil : .categorize(kept)
            case .snooze(let d): action = .snooze(until: d)
            }
            if let action { steps.append(BulkStep(messageId: m.id, action: action)) } else { skipped += 1 }
        }
        let removes: Bool
        switch op { case .archive, .delete, .move, .snooze: removes = true; default: removes = false }
        return BulkPlan(steps: steps, skipped: skipped, removesFromList: removes)
    }

    /// Toggle semantics for a selection: mark read unless every message is already read (Outlook's rule).
    public static func shouldMarkRead(_ ms: [MailMessage]) -> Bool { !ms.allSatisfy(\.isRead) }
    public static func shouldFlag(_ ms: [MailMessage]) -> Bool { !ms.allSatisfy { $0.flag.status == .flagged } }

    public static func describe(_ op: BulkOp, count: Int, folderName: String? = nil) -> String {
        let n = count == 1 ? "1 message" : "\(count) messages"
        switch op {
        case .markRead(let b): return "Marked \(n) as \(b ? "read" : "unread")"
        case .flag(let on): return on ? "Flagged \(n)" : "Cleared the flag on \(n)"
        case .archive: return "Archived \(n)"
        case .delete: return "Deleted \(n)"
        case .move: return "Moved \(n)\(folderName.map { " to \($0)" } ?? "")"
        case .addCategory(let c): return "Added \(c) to \(n)"
        case .removeCategory(let c): return "Removed \(c) from \(n)"
        case .snooze: return "Snoozed \(n)"
        }
    }
}

// MARK: - Sweep

public enum SweepMode: Sendable, Hashable {
    /// Every message from the sender.
    case all
    /// All but the newest message from the sender.
    case keepLatest
    /// Messages from the sender older than N days.
    case olderThan(days: Int)
}

public enum SweepAction: Sendable, Hashable {
    case delete
    case move(folderId: String, folderName: String)
}

public enum Sweep {
    /// Messages the sweep would act on, newest first. Matching is on the From address (case-insensitive).
    public static func select(_ messages: [MailMessage], sender: String, mode: SweepMode, now: Date = Date()) -> [MailMessage] {
        let addr = sender.lowercased()
        let mine = messages.filter { $0.from?.address.lowercased() == addr && !$0.isDraft }
            .sorted { ($0.received, $0.id) > ($1.received, $1.id) }
        switch mode {
        case .all: return mine
        case .keepLatest: return Array(mine.dropFirst())
        case .olderThan(let d):
            let cut = now.addingTimeInterval(-Double(max(d, 0)) * 86_400)
            return mine.filter { $0.received < cut }
        }
    }

    public static func action(_ a: SweepAction) -> MailAction {
        switch a { case .delete: .delete; case .move(let fid, _): .move(toFolderId: fid) }
    }

    /// "Always do this" → a server inbox rule. Only for `.all`: `messageRule` has no age or keep-latest predicate.
    public static func rule(sender: EmailAddress, mode: SweepMode, action: SweepAction) -> MailRule? {
        guard mode == .all, !sender.address.isEmpty else { return nil }
        let from = EmailAddress(name: sender.name, address: sender.address)
        switch action {
        case .delete:
            return MailRule(displayName: "Sweep: delete messages from \(sender.address)",
                            conditions: RuleConditions(fromAddresses: [from]),
                            actions: RuleActions(delete: true, stopProcessingRules: true))
        case .move(let fid, let name):
            return MailRule(displayName: "Sweep: move messages from \(sender.address) to \(name)",
                            conditions: RuleConditions(fromAddresses: [from]),
                            actions: RuleActions(moveToFolder: fid, stopProcessingRules: true))
        }
    }
}

// MARK: - Smart views (Outlook favourite filters)

public enum SmartView: String, CaseIterable, Codable, Sendable, Identifiable {
    case unread, flagged, toMe, attachments, mentions, dueToday
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .unread: "Unread"
        case .flagged: "Flagged"
        case .toMe: "To me"
        case .attachments: "Has attachments"
        case .mentions: "Mentions me"
        case .dueToday: "Due today"
        }
    }
    public var symbol: String {
        switch self {
        case .unread: "envelope.badge"
        case .flagged: "flag"
        case .toMe: "person"
        case .attachments: "paperclip"
        case .mentions: "at"
        case .dueToday: "calendar.badge.clock"
        }
    }

    /// `me` = lower-cased addresses that count as "me" (own + the mailbox being viewed).
    /// `mentioned` = ids the server reported as mentioning the user (beta `mentionsPreview`; empty if unavailable).
    public func matches(_ m: MailMessage, me: Set<String>, mentioned: Set<String> = [], now: Date = Date(),
                        calendar: Calendar = .current) -> Bool {
        switch self {
        case .unread: return !m.isRead
        case .flagged: return m.flag.status == .flagged
        case .toMe: return m.toRecipients.contains { me.contains($0.address.lowercased()) }
        case .attachments: return m.hasAttachments
        case .mentions: return mentioned.contains(m.id)
        case .dueToday:
            guard m.flag.status == .flagged, let due = m.flag.due else { return false }
            return calendar.isDate(due, inSameDayAs: now) || due < now   // overdue counts, as in Outlook's To Do
        }
    }
}

/// Virtual list ids carried in `selectedFolderId` (never a Graph folder id: those never contain ":" + this prefix).
public enum VirtualFolder: Sendable, Hashable {
    case unifiedInbox
    case smart(SmartView, mailbox: String)
    /// ORG2-HOOK: person / category / VIP / tray lists (MailOrganise2.swift).
    case list(FilterList)
    /// PROMISES-HOOK: the promises ledger (its own list view, no server folder).
    case promises
    /// TODAY-HOOK: the Today home (docs/RETHINK.md §4); its rows are the cards' conversations (TodayModel).
    case today

    public static let prefix = "niivo-virtual:"
    public var id: String {
        switch self {
        case .today: Self.prefix + "today"
        case .unifiedInbox: Self.prefix + "unified"
        case .smart(let v, let mb): Self.prefix + "smart:\(v.rawValue):\(mb)"
        case .list(let l): l.id
        case .promises: Self.prefix + "promises"
        }
    }
    public init?(id: String) {
        guard id.hasPrefix(Self.prefix) else { return nil }
        if let l = FilterList(id: id) { self = .list(l); return }
        let rest = id.dropFirst(Self.prefix.count)
        if rest == "unified" { self = .unifiedInbox; return }
        if rest == "promises" { self = .promises; return }   // PROMISES-HOOK
        if rest == "today" { self = .today; return }   // TODAY-HOOK
        let parts = rest.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "smart", let v = SmartView(rawValue: parts[1]) else { return nil }
        self = .smart(v, mailbox: parts[2])
    }
    public var title: String {
        switch self {
        case .unifiedInbox: "All Inboxes"
        case .today: "Today"
        case .smart(let v, _): v.title
        case .list(let l): l.title
        case .promises: "Promises"
        }
    }
}

// MARK: - Unified inbox (keyset merge)

public enum UnifiedInbox {
    /// Same order as `MailStore.messages(folderId:before:limit:)`: received (whole seconds) desc, then id desc.
    static func key(_ m: MailMessage) -> (Int64, String) { (Int64(m.received.timeIntervalSince1970), m.id) }

    /// Merge newest-first pages (one per source) into one newest-first page of at most `limit`, de-duplicated.
    public static func merge(_ pages: [[MailMessage]], limit: Int) -> [MailMessage] {
        var seen = Set<String>()
        return Array(pages.joined().sorted { key($0) > key($1) }.filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    /// One page across several folders, strictly older than `before`. Each source is asked for `limit` rows, so
    /// the merged page is exact (no source can contribute a row that sorts above another source's skipped one).
    public static func page(store: MailStore, folderIds: [String], before: MailCursor?, limit: Int) -> [MailMessage] {
        merge(folderIds.map { (try? store.messages(folderId: $0, before: before, limit: limit)) ?? [] }, limit: limit)
    }

    /// Inbox folder ids of the given mailboxes (those whose folder list is cached).
    public static func inboxes(store: MailStore, mailboxes: [String]) -> [String] {
        mailboxes.compactMap { try? store.folder(wellKnown: .inbox, mailbox: $0)?.id }
    }
}

// MARK: - Smart view rows

public enum SmartViewQuery {
    /// Folders a mailbox-wide smart view looks in (Outlook's favourite filters skip these).
    public static let excluded: Set<WellKnownFolder> = [.deleteditems, .junkemail, .drafts, .sentitems, .outbox, .snoozed]

    /// Bounded scan of the cached headers (newest `perFolder` of each folder), filtered and merged newest first.
    public static func rows(store: MailStore, view: SmartView, mailbox: String, me: Set<String>, mentioned: Set<String> = [],
                            perFolder: Int = 1_000, limit: Int = 500, now: Date = Date()) -> [MailMessage] {
        let folders = ((try? store.folders(mailbox: mailbox)) ?? []).filter { f in f.wellKnown.map { !excluded.contains($0) } ?? true }
        let pages = folders.map { f in
            ((try? store.messages(folderId: f.id, limit: perFolder)) ?? []).filter { view.matches($0, me: me, mentioned: mentioned, now: now) }
        }
        return UnifiedInbox.merge(pages, limit: limit)
    }
}

// MARK: - Search scope + memory

public enum MailSearchScope: String, CaseIterable, Codable, Sendable, Identifiable {
    case folder, mailbox, allMailboxes
    public var id: String { rawValue }
    public var title: String {
        switch self { case .folder: "This folder"; case .mailbox: "This mailbox"; case .allMailboxes: "All mailboxes" }
    }
}

/// Recent (last 10, most recent first) and saved searches. Local only, sealed in the mail store (`searchMemory`).
public struct SearchMemory: Codable, Sendable, Hashable {
    public struct Saved: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        public var name: String
        public var query: String
        public var scope: MailSearchScope
        public var includeGroups: Bool
        public init(id: UUID = UUID(), name: String, query: String, scope: MailSearchScope, includeGroups: Bool = false) {
            self.id = id; self.name = name; self.query = query; self.scope = scope; self.includeGroups = includeGroups
        }
    }
    public var recent: [String] = []
    public var saved: [Saved] = []
    public static let maxRecent = 10
    public static let key = "searchMemory"
    public init(recent: [String] = [], saved: [Saved] = []) { self.recent = recent; self.saved = saved }

    public mutating func remember(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return }
        // Search-as-you-type: a query that extends (or trims) the newest entry replaces it instead of piling up.
        if let first = recent.first?.lowercased(), t.lowercased().hasPrefix(first) || first.hasPrefix(t.lowercased()) {
            recent.removeFirst()
        }
        recent.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        recent.insert(t, at: 0)
        if recent.count > Self.maxRecent { recent.removeLast(recent.count - Self.maxRecent) }
    }
    public mutating func save(_ s: Saved) { saved.removeAll { $0.id == s.id }; saved.append(s) }
    public mutating func removeSaved(_ id: UUID) { saved.removeAll { $0.id == id } }

    public static func load(_ store: MailStore) -> SearchMemory { store.sealed(SearchMemory.self, for: key) ?? SearchMemory() }
    public func persist(_ store: MailStore) { try? store.setSealed(self, for: Self.key) }
}

/// Which mailboxes a scoped search runs over.
public enum SearchScopePlan {
    public static func mailboxes(scope: MailSearchScope, current: String, all: [String]) -> [String] {
        switch scope {
        case .folder, .mailbox: [current]
        case .allMailboxes:
            all.contains(current) ? all : [current] + all
        }
    }
}

/// Groups toggle: matches loaded group conversation *topics* (never previews — a post's label isn't known until
/// it's opened). Graph has no `$search` on group conversations.
public enum GroupSearch {
    public static func match(_ conversations: [GroupConversation], query: String) -> [GroupConversation] {
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        return conversations.filter { c in let t = c.topic.lowercased(); return terms.allSatisfy { t.contains($0) } }
    }
}
