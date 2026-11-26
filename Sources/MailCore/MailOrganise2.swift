import Foundation

// Organisation, part 2: Favourites, Ignore conversation, Reply later / Set aside trays, VIPs, Quick Steps and the
// filtered (virtual) lists they open. Pure planners + sealed stores, no UI, no network, so CoreSelfTest covers them.
// Everything persisted here goes through `MailStore.setSealed` (encrypted with the cache key, wiped with the store).

// MARK: - Filtered lists

public enum MailFilterQuery {
    /// Bounded scan of the cached headers of one mailbox (newest `perFolder` per folder), filtered, newest first.
    public static func rows(store: MailStore, mailbox: String, excluded: Set<WellKnownFolder>, perFolder: Int = 1_000,
                            limit: Int = 500, match: (MailMessage) -> Bool) -> [MailMessage] {
        let folders = ((try? store.folders(mailbox: mailbox)) ?? []).filter { f in f.wellKnown.map { !excluded.contains($0) } ?? true }
        let pages = folders.map { f in ((try? store.messages(folderId: f.id, limit: perFolder)) ?? []).filter(match) }
        return UnifiedInbox.merge(pages, limit: limit)
    }

    /// "Mail with this person": From, To or Cc. Sent Items stay in (what you wrote to them is half the conversation).
    public static let personExcluded: Set<WellKnownFolder> = [.deleteditems, .junkemail, .drafts, .outbox]

    public static func involves(_ m: MailMessage, _ address: String) -> Bool {
        let a = address.lowercased()
        return m.from?.address.lowercased() == a || m.toRecipients.contains { $0.address.lowercased() == a }
            || m.ccRecipients.contains { $0.address.lowercased() == a }
    }

    public static func hasCategory(_ m: MailMessage, _ name: String) -> Bool {
        m.categories.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - Favourites

/// One pinned entry in the sidebar's Favourites section. Order is the user's (drag to reorder).
public enum FavouriteItem: Codable, Sendable, Hashable, Identifiable {
    case folder(id: String, mailbox: String)
    case group(id: String, name: String)
    case person(address: String, name: String)
    case category(String)
    case smart(SmartView)
    case vip
    case tray(MailTray)

    public var id: String {
        switch self {
        case .folder(let id, _): "folder:" + id
        case .group(let id, _): "group:" + id
        case .person(let a, _): "person:" + a.lowercased()
        case .category(let c): "category:" + c.lowercased()
        case .smart(let s): "smart:" + s.rawValue
        case .vip: "vip"
        case .tray(let t): "tray:" + t.rawValue
        }
    }
}

public struct FavouritesList: Codable, Sendable, Hashable {
    public static let key = "favourites.v1"
    public var items: [FavouriteItem] = []
    public init(items: [FavouriteItem] = []) { self.items = items }

    public func contains(_ i: FavouriteItem) -> Bool { items.contains { $0.id == i.id } }
    public mutating func add(_ i: FavouriteItem) { if !contains(i) { items.append(i) } }
    public mutating func remove(_ i: FavouriteItem) { items.removeAll { $0.id == i.id } }
    public mutating func set(_ i: FavouriteItem, _ on: Bool) { if on { add(i) } else { remove(i) } }

    /// Move the item with `id` so it sits before `beforeId` (nil = to the end). Unknown ids are a no-op.
    public mutating func move(_ id: String, before beforeId: String?) {
        guard id != beforeId, let from = items.firstIndex(where: { $0.id == id }) else { return }
        let it = items.remove(at: from)
        if let b = beforeId, let to = items.firstIndex(where: { $0.id == b }) { items.insert(it, at: to) } else { items.append(it) }
    }

    /// Drop folder favourites that no longer exist, but only for mailboxes whose folder list is loaded (a shared
    /// mailbox that hasn't synced yet keeps its pins). Groups, people, categories etc. are never pruned here.
    public mutating func prune(knownFolders: Set<String>, loadedMailboxes: Set<String>) {
        items.removeAll { i in
            if case .folder(let id, let mb) = i { return loadedMailboxes.contains(mb) && !knownFolders.contains(id) }
            return false
        }
    }

    /// Load (sealed); on first run migrate the old folder-only pins (`legacyFolders` = (id, mailbox)).
    public static func load(_ store: MailStore, legacyFolders: [(String, String)] = []) -> (list: FavouritesList, migrated: Bool) {
        if let l = store.sealed(FavouritesList.self, for: key) { return (l, false) }
        // First run: old folder pins + the two trays, so Reply Later / Set Aside are in the sidebar from day one.
        let l = FavouritesList(items: legacyFolders.map { .folder(id: $0.0, mailbox: $0.1) } + MailTray.allCases.map { .tray($0) })
        l.persist(store)
        return (l, !legacyFolders.isEmpty)
    }
    public func persist(_ store: MailStore) { try? store.setSealed(self, for: Self.key) }
}

// MARK: - Trays (HEY's Reply Later / Set Aside, as an Outlook category + flag so it survives in Outlook)

public enum MailTray: String, Codable, Sendable, CaseIterable, Identifiable {
    case replyLater, setAside
    public var id: String { rawValue }
    /// The Outlook category name (visible in every Outlook client).
    public var category: String { self == .replyLater ? "Reply Later" : "Set Aside" }
    public var title: String { category }
    public var symbol: String { self == .replyLater ? "arrowshape.turn.up.left.circle" : "tray.and.arrow.down" }
    /// Outlook preset colour for the master category (created on first use if missing).
    public var colour: CategoryColor { CategoryColor(self == .replyLater ? "preset1" : "preset8") }

    /// Actions to put a message in (or take it out of) the tray. Categories are folded into ONE `categorize` (it
    /// replaces the array). Taking it out clears the flag only when no other tray still holds the message.
    public static func plan(_ tray: MailTray, message m: MailMessage, on: Bool) -> [MailAction] {
        var out: [MailAction] = []
        let has = MailFilterQuery.hasCategory(m, tray.category)
        if on {
            if !has { out.append(.categorize(m.categories + [tray.category])) }
            if m.flag.status != .flagged { out.append(.flag(FollowUpFlag(status: .flagged))) }
        } else {
            guard has else { return [] }
            let kept = m.categories.filter { $0.caseInsensitiveCompare(tray.category) != .orderedSame }
            out.append(.categorize(kept))
            let otherTray = MailTray.allCases.contains { $0 != tray && MailFilterQuery.hasCategory(m, $0.category) }
            if !otherTray && m.flag.status == .flagged { out.append(.flag(FollowUpFlag(status: .notFlagged))) }
        }
        return out
    }

    public func holds(_ m: MailMessage) -> Bool { MailFilterQuery.hasCategory(m, category) }
}

// MARK: - Ignore conversation

/// Ignored conversations (Outlook's Ignore). Graph has no rule predicate for a conversation (Learn,
/// messageRulePredicates), so this is client-side: the set is sealed in the store and every sync delta moves new
/// arrivals of an ignored conversation to Deleted Items. Works only while niivo runs (or on its next sync).
public struct IgnoredConversations: Codable, Sendable, Hashable {
    public static let key = "ignoredConversations.v1"
    /// conversation key → when it was ignored. Only messages received after that are swept, so an undo (or a manual
    /// restore from Deleted Items) of older messages isn't undone again by the next sync.
    public var since: [String: Date] = [:]
    public var keys: Set<String> { Set(since.keys) }
    public init() {}

    static func k(_ conversationId: String, _ mailbox: String) -> String { mailbox.lowercased() + "|" + conversationId }
    public func contains(_ conversationId: String, mailbox: String) -> Bool { since[Self.k(conversationId, mailbox)] != nil }
    public mutating func ignore(_ conversationId: String, mailbox: String, at: Date = Date()) {
        guard !conversationId.isEmpty else { return }
        since[Self.k(conversationId, mailbox)] = at
    }
    public mutating func stop(_ conversationId: String, mailbox: String) { since[Self.k(conversationId, mailbox)] = nil }

    /// Folders never swept: already deleted, own items and junk.
    public static let untouched: Set<WellKnownFolder> = [.deleteditems, .sentitems, .drafts, .outbox, .junkemail]

    /// Steps moving messages of ignored conversations to Deleted Items (`.delete` = soft delete). Messages already in
    /// an untouched folder are left alone, so the sweep doesn't re-trigger on its own move.
    public func sweep(_ targets: [BulkTarget], folder: (WellKnownFolder, String) -> String?) -> [BulkStep] {
        targets.compactMap { t in
            let m = t.message
            guard !m.isDraft, let at = since[Self.k(m.conversationId, t.mailbox)], m.received >= at.addingTimeInterval(-60) else { return nil }
            if Self.untouched.contains(where: { folder($0, t.mailbox) == m.folderId }) { return nil }
            return BulkStep(messageId: m.id, action: .delete)
        }
    }

    public static func load(_ store: MailStore) -> IgnoredConversations { store.sealed(Self.self, for: key) ?? IgnoredConversations() }
    public func persist(_ store: MailStore) { try? store.setSealed(self, for: Self.key) }
}

// MARK: - VIPs

/// VIP senders (lower-cased addresses), sealed in the mail store. Thread-safe and synchronous, so the notification
/// agent can call `contains` from anywhere. Use `VIPStore.shared(for:)` (one instance per store) or `VIPStore.current`
/// (the store of the signed-in session; an empty in-memory list before sign-in).
public final class VIPStore: @unchecked Sendable {
    public static let key = "vips.v1"
    private let lock = NSLock()
    private var set: Set<String>
    private let store: MailStore?

    /// `store == nil` → memory only (tests, before sign-in).
    public init(store: MailStore?) {
        self.store = store
        set = store.flatMap { $0.sealed([String].self, for: Self.key) }.map { Set($0.map { $0.lowercased() }) } ?? []
    }

    public func contains(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: .whitespaces).lowercased()
        lock.lock(); defer { lock.unlock() }
        return !a.isEmpty && set.contains(a)
    }
    public var all: [String] { lock.lock(); defer { lock.unlock() }; return set.sorted() }
    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return set.isEmpty }

    public func set(_ address: String, _ on: Bool) {
        let a = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard a.contains("@") else { return }
        lock.lock()
        if on { set.insert(a) } else { set.remove(a) }
        let snapshot = set.sorted()
        lock.unlock()
        try? store?.setSealed(snapshot, for: Self.key)
    }
    public func add(_ address: String) { set(address, true) }
    public func remove(_ address: String) { set(address, false) }

    // One instance per store so the app, the list and the notifier never diverge.
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var byStore: [ObjectIdentifier: VIPStore] = [:]
        var current: VIPStore?
        let empty = VIPStore(store: nil)
    }
    private static let registry = Registry()

    /// The shared instance for `store`; also becomes `current`.
    public static func shared(for store: MailStore) -> VIPStore {
        let r = registry
        r.lock.lock(); defer { r.lock.unlock() }
        let k = ObjectIdentifier(store)
        let v = r.byStore[k] ?? VIPStore(store: store)
        r.byStore[k] = v
        r.current = v
        return v
    }
    /// The signed-in session's VIPs (empty, memory-only before the mail store opens).
    public static var current: VIPStore { registry.lock.lock(); defer { registry.lock.unlock() }; return registry.current ?? registry.empty }
    /// Sign-out / wipe: forget the instances (the sealed data goes with the store).
    public static func reset() { registry.lock.lock(); registry.byStore = [:]; registry.current = nil; registry.lock.unlock() }
}

// MARK: - Quick Steps

public enum QuickStepAction: Codable, Sendable, Hashable, Identifiable {
    case move(folderId: String, mailbox: String, folderName: String)
    case categorise(String)
    case flag(Bool)
    case markRead(Bool)
    case archive
    case delete
    case tray(MailTray)
    case replyWithTemplate(templateId: UUID, name: String)

    public var id: String { title }
    public var title: String {
        switch self {
        case .move(_, _, let n): "Move to \(n)"
        case .categorise(let c): "Categorise: \(c)"
        case .flag(let b): b ? "Flag" : "Clear flag"
        case .markRead(let b): b ? "Mark as read" : "Mark as unread"
        case .archive: "Archive"
        case .delete: "Delete"
        case .tray(let t): t.title
        case .replyWithTemplate(_, let n): "Reply with “\(n)”"
        }
    }
    /// Move / archive / delete change the message id on the server, so they run last and only one is allowed.
    public var isTerminal: Bool { switch self { case .move, .archive, .delete: true; default: false } }
}

public struct QuickStep: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var actions: [QuickStepAction]
    /// ^⇧1…9 (nil = none).
    public var shortcut: Int?
    public init(id: UUID = UUID(), name: String, actions: [QuickStepAction], shortcut: Int? = nil) {
        self.id = id; self.name = name; self.actions = actions; self.shortcut = shortcut
    }
}

public struct QuickStepLibrary: Codable, Sendable, Hashable {
    public static let key = "quickSteps.v1"
    public var steps: [QuickStep] = []
    public init(steps: [QuickStep] = []) { self.steps = steps }

    public func step(shortcut n: Int) -> QuickStep? { steps.first { $0.shortcut == n } }

    /// Editor validation: messages to show (empty = valid).
    public func problems(_ s: QuickStep) -> [String] {
        var out: [String] = []
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Give the Quick Step a name") }
        if s.actions.isEmpty { out.append("Add at least one action") }
        if s.actions.filter(\.isTerminal).count > 1 { out.append("Use only one of Move, Archive or Delete") }
        if s.actions.filter({ if case .replyWithTemplate = $0 { true } else { false } }).count > 1 { out.append("Use only one reply") }
        if let n = s.shortcut {
            if !(1...9).contains(n) { out.append("Shortcut must be ^⇧1 to ^⇧9") }
            else if steps.contains(where: { $0.shortcut == n && $0.id != s.id }) { out.append("^⇧\(n) is already used") }
        }
        return out
    }

    public mutating func upsert(_ s: QuickStep) {
        if let i = steps.firstIndex(where: { $0.id == s.id }) { steps[i] = s } else { steps.append(s) }
    }
    public mutating func remove(_ id: UUID) { steps.removeAll { $0.id == id } }

    public static func load(_ store: MailStore) -> QuickStepLibrary { store.sealed(Self.self, for: key) ?? QuickStepLibrary() }
    public func persist(_ store: MailStore) { try? store.setSealed(self, for: Self.key) }
}

public struct QuickStepPlan: Sendable, Hashable {
    /// Ordered steps across all targets: per message, state changes first, the terminal move last.
    public var steps: [BulkStep]
    /// Reply with a template: only for a single target (opened before the steps run).
    public var reply: (messageId: String, templateId: UUID)? { replyMessageId.flatMap { m in replyTemplate.map { (m, $0) } } }
    public var replyMessageId: String?
    public var replyTemplate: UUID?
    public var removesFromList: Bool
    public var skippedReply: Bool
}

public enum QuickStepPlanner {
    /// Undo order for a multi-step action: state inverses newest first, then the move(s) back — so state inverses
    /// hit the id after one server move (MailSync.undo remaps it) and the move back runs last.
    public static func undoOrder(state: [BulkStep], moves: [BulkStep]) -> [BulkStep] { state.reversed() + moves }

    public static func plan(_ s: QuickStep, targets: [BulkTarget], folder: (WellKnownFolder, String) -> String?) -> QuickStepPlan {
        var steps: [BulkStep] = []
        var removes = false
        for t in targets {
            let m = t.message
            var cats = m.categories
            var flagged: Bool?
            var read: Bool?
            var terminal: MailAction?
            for a in s.actions {
                switch a {
                case .categorise(let c): if !cats.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) { cats.append(c) }
                case .tray(let tr): if !cats.contains(where: { $0.caseInsensitiveCompare(tr.category) == .orderedSame }) { cats.append(tr.category) }; flagged = true
                case .flag(let b): flagged = b
                case .markRead(let b): read = b
                case .archive:
                    if let a = folder(.archive, t.mailbox), a != m.folderId { terminal = .move(toFolderId: a) }
                case .delete:
                    if folder(.deleteditems, t.mailbox) != m.folderId { terminal = .delete }
                case .move(let fid, let mb, _):
                    if mb == t.mailbox, fid != m.folderId { terminal = .move(toFolderId: fid) }
                case .replyWithTemplate: break
                }
            }
            if cats != m.categories { steps.append(BulkStep(messageId: m.id, action: .categorize(cats))) }
            if let f = flagged, f != (m.flag.status == .flagged) {
                steps.append(BulkStep(messageId: m.id, action: .flag(FollowUpFlag(status: f ? .flagged : .notFlagged))))
            }
            if let r = read, r != m.isRead { steps.append(BulkStep(messageId: m.id, action: .markRead(r))) }
            if let terminal { steps.append(BulkStep(messageId: m.id, action: terminal)); removes = true }
        }
        var replyId: String?, tpl: UUID?, skipped = false
        for a in s.actions { if case .replyWithTemplate(let id, _) = a { tpl = id } }
        if tpl != nil { if targets.count == 1 { replyId = targets[0].message.id } else { skipped = true; tpl = nil } }
        return QuickStepPlan(steps: steps, replyMessageId: replyId, replyTemplate: tpl, removesFromList: removes, skippedReply: skipped)
    }
}

// MARK: - Virtual list ids for the new lists

/// Additional virtual lists (opened from Favourites / trays / VIPs). Encoded in `selectedFolderId` like `VirtualFolder`.
public enum FilterList: Sendable, Hashable {
    case person(address: String, mailbox: String)
    case category(String, mailbox: String)
    case vip(mailbox: String)
    case tray(MailTray, mailbox: String)

    public static let prefix = VirtualFolder.prefix + "list:"
    public var id: String {
        switch self {
        case .person(let a, let mb): Self.prefix + "person:\(mb):\(a.lowercased())"
        case .category(let c, let mb): Self.prefix + "category:\(mb):\(c)"
        case .vip(let mb): Self.prefix + "vip:\(mb):"
        case .tray(let t, let mb): Self.prefix + "tray:\(mb):\(t.rawValue)"
        }
    }
    public init?(id: String) {
        guard id.hasPrefix(Self.prefix) else { return nil }
        let parts = id.dropFirst(Self.prefix.count).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let mb = parts[1], rest = parts[2]
        switch parts[0] {
        case "person" where !rest.isEmpty: self = .person(address: rest, mailbox: mb)
        case "category" where !rest.isEmpty: self = .category(rest, mailbox: mb)
        case "vip": self = .vip(mailbox: mb)
        case "tray": guard let t = MailTray(rawValue: rest) else { return nil }; self = .tray(t, mailbox: mb)
        default: return nil
        }
    }
    public var title: String {
        switch self {
        case .person(let a, _): a
        case .category(let c, _): c
        case .vip: "VIPs"
        case .tray(let t, _): t.title
        }
    }
    public var symbol: String {
        switch self {
        case .person: "person.crop.circle"
        case .category: "tag"
        case .vip: "star"
        case .tray(let t, _): t.symbol
        }
    }
    public var mailbox: String {
        switch self { case .person(_, let mb), .category(_, let mb), .vip(let mb), .tray(_, let mb): mb }
    }

    /// Rows of the list (bounded scan of cached headers). `vips` decides VIP membership.
    public func rows(store: MailStore, vips: (String) -> Bool, perFolder: Int = 1_000, limit: Int = 500) -> [MailMessage] {
        switch self {
        case .person(let a, let mb):
            return MailFilterQuery.rows(store: store, mailbox: mb, excluded: MailFilterQuery.personExcluded, perFolder: perFolder,
                                        limit: limit) { MailFilterQuery.involves($0, a) }
        case .category(let c, let mb):
            return MailFilterQuery.rows(store: store, mailbox: mb, excluded: SmartViewQuery.excluded, perFolder: perFolder,
                                        limit: limit) { MailFilterQuery.hasCategory($0, c) }
        case .vip(let mb):
            return MailFilterQuery.rows(store: store, mailbox: mb, excluded: SmartViewQuery.excluded, perFolder: perFolder,
                                        limit: limit) { m in m.from.map { vips($0.address) } ?? false }
        case .tray(let t, let mb):
            return MailFilterQuery.rows(store: store, mailbox: mb, excluded: SmartViewQuery.excluded, perFolder: perFolder,
                                        limit: limit) { t.holds($0) }
        }
    }
}

// ORG2-HOOK: the notification agent asks VIPs through this protocol (AppLifecycle.swift).
extension VIPStore: MailVIPLookup {}
