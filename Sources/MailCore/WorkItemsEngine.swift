import Foundation
import CryptoKit
import SQLite3

// WORK ITEMS (docs/SUITE.md, When / Deep): the per-account store of loop work items and the suggestions behind them.
//
// * Storage: one sealed table `work_item(key, payload)`; key = 4-byte account tag + type byte (1 item, 2 dismissed
//   suggestion) + HMAC (HKDF info "work-items-v1"); payloads padded to 1 KB buckets. On disk: item ids, loop ids, kind,
//   minutes, due, criteria, state, slot (times + event id), source ids (promise id / conversation id, never message
//   ids) and the title only when the user typed it or every source may keep offline details. A dismissed suggestion is a
//   keyed hash of its source, never text. User data: survives `resetHeaders` (memory is dropped and re-read), goes with
//   `wipe`.
// * Titles derived from mail are re-resolved at read time for the user tier (a source that turned protected hides its
//   title even when an older copy is on disk); a derived title that wasn't allowed on disk lives in memory and is
//   re-derived from its source after a restart.
// * Suggestions: the loop's open promises (promised / asked of me) and its needs-reply conversations, minus anything that
//   already became an item (any state) or was dismissed. Nothing is stored until `accept`.

public final class WorkItemsEngine: @unchecked Sendable {
    public struct Config: Sendable {
        public var account: String
        public init(account: String) { self.account = account }
    }

    struct Row: Codable, Hashable {
        var id: String
        var loop: String
        var title: String?
        var titleUser: Bool
        var titleOnDisk: Bool
        var kind: WorkItemKind
        var minutes: Int
        var due: Date?
        var criteria: [DoneCriterion]
        var state: WorkItemState
        var slot: WorkSlot?
        var movingFrom: WorkSlot?
        var source: WorkItemSource?
        var deferred: Date?
        var created: Date
        var updated: Date
    }
    struct Dismissed: Codable, Hashable { var hash: String; var at: Date }

    struct Rows {
        var items: [String: Row] = [:]
        /// keyed hashes of dismissed sources
        var dismissed: Set<String> = []
    }
    enum Op { case put(Row), delete(String), putDismissed(Dismissed) }

    let store: MailStore
    public let knowledge: KnowledgeEngine
    /// Where promise-backed titles come from (the account's ledger; nil = no promise suggestions).
    public var promises: PromiseLedger? {
        get { lock.withLock { ledger } }
        set { lock.withLock { ledger = newValue } }
    }
    private var ledger: PromiseLedger?
    private let key: SymmetricKey
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var config: Config
    private var rows: Rows?
    private var gen = 0

    public var account: String { lock.withLock { config.account } }
    public var generation: Int { lock.withLock { gen } }
    static let bucket = 1024
    static let maxTitle = 200
    static let maxCriteria = 8

    init(store: MailStore, indexKey: SymmetricKey, knowledge: KnowledgeEngine, promises: PromiseLedger?, config: Config) {
        self.store = store; self.knowledge = knowledge; self.ledger = promises; self.config = config
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: indexKey, salt: Data("compliant-office.mail".utf8), info: Data("work-items-v1".utf8), outputByteCount: 32)
    }

    public func configure(_ c: Config) {
        lock.withLock { if c.account != config.account { rows = nil }; config = c; gen += 1 }
    }
    /// Called under the store lock (MailStore.wipe): memory only.
    func wipe() { lock.withLock { rows = nil; gen += 1 } }
    /// Called under the store lock (MailStore.resetHeaders): memory only; items re-read from disk, titles re-derived.
    func markAllDirty() { lock.withLock { rows = nil; gen += 1 } }

    // MARK: Keys and rows

    private func tag(_ account: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data("a|\(account)".utf8), using: key).prefix(4)) }
    private func rowKey(_ account: String, _ type: UInt8, _ s: String) -> Data {
        tag(account) + Data([type]) + Data(HMAC<SHA256>.authenticationCode(for: Data("\(type)|\(account)|\(s)".utf8), using: key).prefix(16))
    }
    func sourceHash(_ s: WorkItemSource, account: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("src|\(account)|\(s.key)".utf8), using: key).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func seal<T: Encodable>(_ v: T) -> Data? {
        guard var d = try? JSONEncoder().encode(v) else { return nil }
        d.append(Data(repeating: 0x20, count: ((d.count / Self.bucket) + 1) * Self.bucket - d.count))
        return try? store.sealData(d)
    }

    private func loaded() -> Rows {
        if let r = lock.withLock({ rows }) { return r }
        let acct = account
        let raw = (try? store.query("SELECT key, payload FROM work_item WHERE substr(key,1,4)=?", [.blob(tag(acct))]) { s in
            (KnowledgeEngine.blob(s, 0), KnowledgeEngine.blob(s, 1))
        }) ?? []
        var r = Rows()
        let dec = JSONDecoder()
        for (k, p) in raw {
            guard k.count > 4, let plain = try? store.openData(p) else { continue }
            switch k[k.startIndex + 4] {
            case 1: if let x = try? dec.decode(Row.self, from: plain) { r.items[x.id] = x }
            case 2: if let x = try? dec.decode(Dismissed.self, from: plain) { r.dismissed.insert(x.hash) }
            default: break
            }
        }
        return lock.withLock {
            if rows == nil, config.account == acct { rows = r }
            return rows ?? r
        }
    }

    @discardableResult
    private func edit<T>(_ body: (inout Rows, inout [Op]) -> T) -> T {
        writeLock.lock(); defer { writeLock.unlock() }
        _ = loaded()
        var ops: [Op] = []
        let (out, acct): (T, String) = lock.withLock {
            var r = rows ?? Rows()
            let out = body(&r, &ops)
            rows = r
            if !ops.isEmpty { gen += 1 }
            return (out, config.account)
        }
        for op in ops {
            switch op {
            case .put(var x):
                if !x.titleUser && !x.titleOnDisk { x.title = nil }   // label rule: gated derived text stays in memory
                if let s = seal(x) { try? store.run("INSERT OR REPLACE INTO work_item(key,payload) VALUES(?,?)", [.blob(rowKey(acct, 1, x.id)), .blob(s)]) }
            case .delete(let id):
                try? store.run("DELETE FROM work_item WHERE key=?", [.blob(rowKey(acct, 1, id))])
            case .putDismissed(let d):
                if let s = seal(d) { try? store.run("INSERT OR REPLACE INTO work_item(key,payload) VALUES(?,?)", [.blob(rowKey(acct, 2, d.hash)), .blob(s)]) }
            }
        }
        return out
    }

    // MARK: Titles (user tier)

    /// The title a source gives right now, and whether it may go to disk. nil text = not visible.
    func derive(_ s: WorkItemSource) -> (text: String?, onDisk: Bool, kind: WorkItemKind, due: Date?)? {
        switch s {
        case .promise(let id):
            guard let p = promises?.promise(id: id) else { return nil }
            let t = p.text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitle)) }
            return (t?.isEmpty == false ? t : nil, p.persistText, .promise, p.due)
        case .conversation(let cid):
            let xs = knowledge.conversation(cid, tier: .user)
            guard !xs.isEmpty else { return nil }
            let visible = xs.filter { knowledge.textVisible($0.m.id, tier: .user) }
            let newest = visible.max { $0.m.received < $1.m.received }
            let subj = newest.map { StoryAnchors.strippedSubject($0.m.subject).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let onDisk = visible.allSatisfy { knowledge.persistable($0.m.id) }
            return (subj.isEmpty ? nil : String(("Reply: " + subj).prefix(Self.maxTitle)), onDisk, .reply, nil)
        }
    }

    private func resolved(_ x: Row) -> WorkItem {
        var title: String?
        if x.titleUser { title = x.title }
        else if let s = x.source, let d = derive(s) { title = d.text }      // re-checked against the label gate every read
        else if x.source == nil || x.titleOnDisk { title = x.title }        // source gone: only an allowed on-disk copy
        return WorkItem(id: x.id, loopId: x.loop, title: title, titleUser: x.titleUser, kind: x.kind, minutes: x.minutes, due: x.due,
                        criteria: x.criteria, state: x.state, slot: x.slot, movingFrom: x.movingFrom, source: x.source,
                        deferredUntil: x.deferred, created: x.created, updated: x.updated)
    }

    // MARK: Reads

    public func item(id: String) -> WorkItem? { loaded().items[id].map(resolved) }

    /// A loop's items: open work first (by due, then created), done last.
    public func items(loopId: String) -> [WorkItem] {
        Self.ordered(loaded().items.values.filter { $0.loop == loopId }.map(resolved))
    }

    public func allItems() -> [WorkItem] { Self.ordered(loaded().items.values.map(resolved)) }

    /// When's queue: open (unplaced) items that aren't deferred, plus scheduled ones whose block passed without work
    /// starting (missed), optionally for one loop. Missed items come first.
    public func toPlace(now: Date = Date(), loopId: String? = nil) -> [WorkItem] {
        let xs = allItems().filter { ($0.state == .open || $0.isMissed(now: now)) && !$0.isDeferred(now: now) && (loopId == nil || $0.loopId == loopId) }
        return xs.filter { $0.isMissed(now: now) } + xs.filter { !$0.isMissed(now: now) }
    }

    /// Focus blocks still ahead or running (scheduled / in progress with a slot; missed ones excluded), by start.
    public func placed(now: Date = Date()) -> [WorkItem] {
        allItems().filter { ($0.state == .scheduled || $0.state == .inProgress) && $0.slot != nil && !$0.isMissed(now: now) }
            .sorted { ($0.slot!.start, $0.id) < ($1.slot!.start, $1.id) }
    }

    /// Every item of the loop is done (and there is at least one): the moment to offer closing the loop.
    public func allDone(loopId: String) -> Bool {
        let xs = loaded().items.values.filter { $0.loop == loopId }
        return !xs.isEmpty && xs.allSatisfy { $0.state == .done }
    }

    static func ordered(_ xs: [WorkItem]) -> [WorkItem] {
        func rank(_ s: WorkItemState) -> Int { switch s { case .inProgress: 0; case .scheduled: 1; case .open: 2; case .done: 3 } }
        return xs.sorted { a, b in
            if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
            if a.state == .scheduled, let sa = a.slot?.start, let sb = b.slot?.start, sa != sb { return sa < sb }
            return (a.due ?? .distantFuture, a.created, a.id) < (b.due ?? .distantFuture, b.created, b.id)
        }
    }

    // MARK: Suggestions

    /// Suggestions for a loop: open promises in its conversations and conversations that need a reply. Never stored.
    public func suggestions(loopId: String, conversations: [String], needsReply: Set<String>) -> [WorkItemSuggestion] {
        let r = loaded()
        let acct = account
        let taken = Self.suppressing(r, acct, sourceHash)
        func free(_ s: WorkItemSource) -> Bool { let h = sourceHash(s, account: acct); return !taken.contains(h) && !r.dismissed.contains(h) }
        var out: [WorkItemSuggestion] = []
        let convs = Set(conversations)
        if let ledger = promises {
            for c in conversations.sorted() {
                for p in ledger.promises(conversationId: c) where p.state == .open && convs.contains(p.conversationId) {
                    let s = WorkItemSource.promise(id: p.id)
                    guard free(s) else { continue }
                    let d = derive(s)
                    out.append(WorkItemSuggestion(loopId: loopId, source: s, kind: .promise, title: d?.text, minutes: WorkItemKind.promise.defaultMinutes,
                                                  due: p.due, criteria: [p.kind == .asked ? "Request answered" : "Promise kept"]))
                }
            }
        }
        for c in conversations.sorted() where needsReply.contains(c) {
            let s = WorkItemSource.conversation(id: c)
            guard free(s) else { continue }
            out.append(WorkItemSuggestion(loopId: loopId, source: s, kind: .reply, title: derive(s)?.text, minutes: WorkItemKind.reply.defaultMinutes,
                                          due: nil, criteria: ["Reply sent"]))
        }
        return out.sorted { ($0.due ?? .distantFuture, $0.kind.rawValue, $0.id) < ($1.due ?? .distantFuture, $1.kind.rawValue, $1.id) }
    }

    /// Sources that may not be suggested again: every item's source, except a DONE reply item (the same conversation may
    /// need a reply again later). Dismissals are separate and always suppress.
    static func suppressing(_ r: Rows, _ acct: String, _ hash: (WorkItemSource, String) -> String) -> Set<String> {
        Set(r.items.values.filter { !($0.kind == .reply && $0.state == .done) }.compactMap { $0.source.map { hash($0, acct) } })
    }

    /// The user accepts a suggestion: it becomes an open item (derived title, never a user title). Returns the item id,
    /// or nil when that source is already an item or dismissed.
    @discardableResult
    public func accept(_ s: WorkItemSuggestion, now: Date = Date()) -> String? {
        let d = derive(s.source)
        let acct = account
        let h = sourceHash(s.source, account: acct)
        let id = UUID().uuidString.lowercased()
        return edit { r, ops -> String? in
            if r.dismissed.contains(h) || Self.suppressing(r, acct, sourceHash).contains(h) { return nil }
            let x = Row(id: id, loop: s.loopId, title: d?.text, titleUser: false, titleOnDisk: d?.onDisk ?? false, kind: s.kind,
                        minutes: max(5, s.minutes), due: s.due ?? d?.due, criteria: s.criteria.prefix(Self.maxCriteria).map { DoneCriterion(text: $0) },
                        state: .open, slot: nil, movingFrom: nil, source: s.source, deferred: nil, created: now, updated: now)
            r.items[id] = x; ops.append(.put(x))
            return id
        }
    }

    /// "Not this": the suggestion never comes back (keyed hash of its source on disk).
    public func dismiss(_ s: WorkItemSuggestion, now: Date = Date()) {
        let h = sourceHash(s.source, account: account)
        edit { r, ops in
            guard r.dismissed.insert(h).inserted else { return }
            ops.append(.putDismissed(Dismissed(hash: h, at: now)))
        }
    }

    // MARK: Edits

    /// A work item the user writes themselves (a user title: may name the calendar block).
    @discardableResult
    public func add(loopId: String, title: String, kind: WorkItemKind = .task, minutes: Int? = nil, due: Date? = nil,
                    criteria: [String] = [], now: Date = Date()) -> String {
        let id = UUID().uuidString.lowercased()
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitle))
        edit { r, ops in
            let x = Row(id: id, loop: loopId, title: t.isEmpty ? nil : t, titleUser: !t.isEmpty, titleOnDisk: true, kind: kind,
                        minutes: max(5, minutes ?? kind.defaultMinutes), due: due,
                        criteria: criteria.prefix(Self.maxCriteria).map { DoneCriterion(text: String($0.prefix(Self.maxTitle))) },
                        state: .open, slot: nil, movingFrom: nil, source: nil, deferred: nil, created: now, updated: now)
            r.items[id] = x; ops.append(.put(x))
        }
        return id
    }

    private func touch(_ id: String, now: Date, _ f: (inout Row) -> Void) {
        edit { r, ops in
            guard var x = r.items[id] else { return }
            let before = x
            f(&x)
            guard x != before else { return }
            x.updated = now
            r.items[id] = x; ops.append(.put(x))
        }
    }

    /// Return on an unchanged derived title is not a rename (gated text must not become a stored user title).
    public func rename(_ id: String, to title: String, now: Date = Date()) {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitle))
        guard !t.isEmpty else { return }
        let shown = item(id: id)?.title
        touch(id, now: now) { x in
            if !x.titleUser, shown == t { return }
            x.title = t; x.titleUser = true; x.titleOnDisk = true
        }
    }

    public func setMinutes(_ id: String, _ minutes: Int, now: Date = Date()) { touch(id, now: now) { $0.minutes = min(8 * 60, max(5, minutes)) } }
    public func setDue(_ id: String, _ due: Date?, now: Date = Date()) { touch(id, now: now) { $0.due = due } }
    public func setKind(_ id: String, _ kind: WorkItemKind, now: Date = Date()) { touch(id, now: now) { $0.kind = kind } }

    public func addCriterion(_ id: String, _ text: String, now: Date = Date()) {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitle))
        guard !t.isEmpty else { return }
        touch(id, now: now) { x in if x.criteria.count < Self.maxCriteria { x.criteria.append(DoneCriterion(text: t)) } }
    }
    public func toggleCriterion(_ id: String, _ criterion: String, now: Date = Date()) {
        touch(id, now: now) { x in if let i = x.criteria.firstIndex(where: { $0.id == criterion }) { x.criteria[i].done.toggle() } }
    }
    public func removeCriterion(_ id: String, _ criterion: String, now: Date = Date()) {
        touch(id, now: now) { $0.criteria.removeAll { $0.id == criterion } }
    }

    /// A confirmed focus block: the item is scheduled in that slot (the block it replaced is gone).
    public func schedule(_ id: String, slot: WorkSlot, now: Date = Date()) {
        touch(id, now: now) { x in x.slot = slot; x.movingFrom = nil; x.deferred = nil; if x.state != .inProgress { x.state = .scheduled } }
    }
    /// "Reschedule": back to When; the current block is remembered so the next confirmed one replaces it.
    public func reschedule(_ id: String, now: Date = Date()) {
        touch(id, now: now) { x in
            if let s = x.slot, s.start > now { x.movingFrom = s }
            x.slot = nil; x.state = .open; x.deferred = nil
        }
    }
    /// "Need more time": back to When for another block; the block just worked stays on the calendar.
    public func needMoreTime(_ id: String, extraMinutes: Int? = nil, now: Date = Date()) {
        touch(id, now: now) { x in
            x.slot = nil; x.movingFrom = nil; x.state = .open; x.deferred = nil
            if let m = extraMinutes { x.minutes = min(8 * 60, max(5, m)) }
        }
    }
    public func start(_ id: String, now: Date = Date()) { touch(id, now: now) { if $0.state != .done { $0.state = .inProgress } } }
    public func markDone(_ id: String, now: Date = Date()) { touch(id, now: now) { $0.state = .done; $0.deferred = nil } }
    public func reopen(_ id: String, now: Date = Date()) { touch(id, now: now) { $0.state = $0.slot == nil ? .open : .scheduled } }
    /// "Later" (When) / "Park" (Deep): out of the queue until `until`; a planned block stays planned unless `unplace`.
    public func postpone(_ id: String, until: Date, unplace: Bool = false, now: Date = Date()) {
        touch(id, now: now) { x in
            x.deferred = until
            if unplace || x.state == .inProgress { x.slot = nil; x.state = .open }
        }
    }
    /// "Not mine": the item goes; a suggestion-born item's source is dismissed so it doesn't come back.
    public func remove(_ id: String, now: Date = Date()) {
        let acct = account
        edit { r, ops in
            guard let x = r.items.removeValue(forKey: id) else { return }
            ops.append(.delete(id))
            if let s = x.source {
                let h = sourceHash(s, account: acct)
                if r.dismissed.insert(h).inserted { ops.append(.putDismissed(Dismissed(hash: h, at: now))) }
            }
        }
    }
    /// A focus block's id changed (Exchange assigned the real one after the local create): the slot and the block being
    /// replaced follow it.
    public func remapEvent(_ id: String, from old: String, to eventId: String, now: Date = Date()) {
        touch(id, now: now) { x in
            if x.slot?.eventId == old { x.slot?.eventId = eventId }
            if x.movingFrom?.eventId == old { x.movingFrom?.eventId = eventId }
        }
    }

    // MARK: Diagnostic (counts only)

    public func counts(now: Date = Date()) -> (open: Int, toPlace: Int, scheduled: Int, inProgress: Int, done: Int) {
        let xs = loaded().items.values
        return (xs.filter { $0.state == .open }.count, xs.filter { $0.state == .open && ($0.deferred ?? .distantPast) <= now }.count,
                xs.filter { $0.state == .scheduled }.count, xs.filter { $0.state == .inProgress }.count, xs.filter { $0.state == .done }.count)
    }

    /// Tests: rows in this account's namespace (1 items, 2 dismissed).
    public func debugRowCounts() -> (items: Int, dismissed: Int) {
        let acct = account
        func n(_ t: UInt8) -> Int { Int(((try? store.scalarInt("SELECT COUNT(*) FROM work_item WHERE substr(key,1,5)=?", [.blob(tag(acct) + Data([t]))])) ?? nil) ?? 0) }
        return (n(1), n(2))
    }
}

extension MailStore {
    /// WHEN-HOOK: attach (or reconfigure) the work-items engine for this store's account.
    @discardableResult
    public func enableWorkItems(_ config: WorkItemsEngine.Config, knowledge: KnowledgeEngine, promises: PromiseLedger?) -> WorkItemsEngine {
        locked {
            if let w = workItems, w.knowledge === knowledge { w.configure(config); w.promises = promises; return w }
            let w = WorkItemsEngine(store: self, indexKey: indexKey, knowledge: knowledge, promises: promises, config: config)
            workItems = w
            return w
        }
    }

    /// Tests: a second engine on the same store (fresh memory, or another account).
    public func makeWorkItemsEngine(_ config: WorkItemsEngine.Config, knowledge: KnowledgeEngine, promises: PromiseLedger?) -> WorkItemsEngine {
        WorkItemsEngine(store: self, indexKey: indexKey, knowledge: knowledge, promises: promises, config: config)
    }

    /// Tests: sealed payload sizes in `work_item` and whether any payload decrypts to contain `needle`.
    public func debugWorkItemPayloadSizes() -> [Int] {
        (try? query("SELECT length(payload) FROM work_item") { Int(sqlite3_column_int64($0, 0)) }) ?? []
    }
    public func debugWorkItemPlaintextContains(_ needle: String) -> Bool {
        let rows = (try? query("SELECT payload FROM work_item") { KnowledgeEngine.blob($0, 0) }) ?? []
        return rows.contains { (try? openData($0)).flatMap { String(data: $0, encoding: .utf8) }?.contains(needle) ?? false }
    }
}
