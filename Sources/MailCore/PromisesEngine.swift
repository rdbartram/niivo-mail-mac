import Foundation
import CryptoKit
import SQLite3

// PROMISES: the per-store (= per account) promises ledger.
// * Table `promise_item(key, payload)`: key = account tag (4) + HMAC(conversation) (16) + HMAC(promise id) (8);
//   payload sealed and padded to one 2 KB bucket. Insert-if-absent: done / dismissed survive re-scans.
// * Text and counterpart go to disk only where the source message allows offline details; otherwise they live in
//   memory and are re-derived on the next pass.
// * Text is read only where `exposure` (the on-device label gate) is `.content`. When the gate tightens, open rows
//   from a message that is no longer `.content` are removed.
// * Auto-complete: a later message from the user in the conversation with an attachment, or "attached / anbei /
//   ci-joint / in allegato" (read only where the gate allows).

public final class PromiseLedger: @unchecked Sendable, PromiseSource {
    public struct Config: Sendable {
        public var account: String
        public var owners: Set<String>
        public var exposure: @Sendable (MailMessage, String) -> AIExposure
        /// May text / counterpart of this message be written to disk (allowOfflineDetails)?
        public var persistText: @Sendable (MailMessage, String) -> Bool
        public var windowDays: Int
        public var calendar: Calendar
        public init(account: String, owners: Set<String>, exposure: @escaping @Sendable (MailMessage, String) -> AIExposure,
                    persistText: @escaping @Sendable (MailMessage, String) -> Bool = { _, _ in true }, windowDays: Int = 30,
                    calendar: Calendar = .current) {
            self.account = account; self.owners = Set(owners.map { $0.lowercased() }); self.exposure = exposure
            self.persistText = persistText; self.windowDays = windowDays; self.calendar = calendar
        }
    }

    public struct Stats: Sendable, Hashable { public var extracted = 0, open = 0, overdue = 0, autoDone = 0 }

    let store: MailStore
    private let key: SymmetricKey
    private let lock = NSLock()
    private var config: Config
    private var dirty: Set<String> = []
    private var full = true
    /// Memory-only text (labels that forbid offline details): promise id → (text, name, address).
    private var mem: [String: (String?, String?, String?)] = [:]
    private var gen = 0
    public var generation: Int { lock.withLock { gen } }
    public var account: String { lock.withLock { config.account } }

    static let attachedMarkers = "\\b(attached|attachment|anbei|im anhang|beiliegend|angehängt|ci-joint|ci-jointe|pièce jointe|pièces jointes|in allegato|allegato|allegati)\\b"
    static let bucket = 2048

    init(store: MailStore, indexKey: SymmetricKey, config: Config) {
        self.store = store
        self.key = HKDF<SHA256>.deriveKey(inputKeyMaterial: indexKey, salt: Data("compliant-office.mail".utf8), info: Data("promises-v1".utf8), outputByteCount: 32)
        self.config = config
    }

    // Called from MailStore write paths under the store lock: never call the store here.
    func touch(_ cid: String) { lock.withLock { _ = dirty.insert(cid) } }
    func markAllDirty() { lock.withLock { full = true; gen += 1 } }
    func wipe() { lock.withLock { full = true; dirty = []; mem = [:]; gen += 1 } }

    public func configure(_ c: Config) {
        lock.withLock {
            if c.account != config.account || c.owners != config.owners { mem = [:] }
            config = c; full = true; gen += 1
        }
    }
    /// Labels / policy / tier changed: re-check every conversation (rows whose source lost `.content` go).
    public func policyChanged() { lock.withLock { full = true; gen += 1 } }

    // MARK: Keys and rows

    func tag() -> Data { TriageKeys.accountTag(account, key: key) }
    func convPrefix(_ cid: String) -> Data { TriageKeys.conversation(cid, account: account, key: key) }
    func rowKey(_ p: Promise) -> Data {
        convPrefix(p.conversationId) + Data(HMAC<SHA256>.authenticationCode(for: Data("p|\(account)|\(p.id)".utf8), using: key).prefix(8))
    }

    func put(_ p: Promise) {
        var disk = p
        if !p.persistText { disk.text = nil; disk.counterpartName = nil; disk.counterpartAddress = nil }
        guard var d = try? JSONEncoder().encode(disk), d.count <= Self.bucket else { return }
        d.append(Data(repeating: 0x20, count: Self.bucket - d.count))
        guard let sealed = try? store.sealData(d) else { return }
        try? store.run("INSERT OR REPLACE INTO promise_item(key,payload) VALUES(?,?)", [.blob(rowKey(p)), .blob(sealed)])
        if !p.persistText { lock.withLock { mem[p.id] = (p.text, p.counterpartName, p.counterpartAddress) } }
    }

    func rows(prefix: Data) -> [(Data, Promise)] {
        let all = (try? store.query("SELECT key, payload FROM promise_item") { s in (InboxTriageEngine.blob(s, 0), InboxTriageEngine.blob(s, 1)) }) ?? []
        let m = lock.withLock { mem }
        return all.filter { $0.0.prefix(prefix.count) == prefix }.compactMap { k, d in
            guard let plain = try? store.openData(d), var p = try? JSONDecoder().decode(Promise.self, from: plain) else { return nil }
            if p.text == nil, let t = m[p.id] { p.text = t.0; p.counterpartName = t.1; p.counterpartAddress = t.2 }
            return (k, p)
        }
    }

    func delete(_ k: Data) { try? store.run("DELETE FROM promise_item WHERE key=?", [.blob(k)]) }

    // MARK: Refresh

    /// Extracts from dirty conversations (or every conversation in the window). Returns new promises found.
    @discardableResult
    public func refresh(now: Date = Date()) -> Int {
        let (cfg, isFull, ids) = lock.withLock { () -> (Config, Bool, Set<String>) in
            let r = (config, full, dirty); full = false; dirty = []; return r
        }
        let cutoff = now.addingTimeInterval(-Double(cfg.windowDays) * 86_400)
        var todo = Array(ids)
        if isFull {
            todo = (try? store.query("SELECT DISTINCT conversation_id FROM messages WHERE received >= ?", [.int(Int64(cutoff.timeIntervalSince1970))]) { s in
                sqlite3_column_text(s, 0).map { String(cString: $0) } ?? "" }) ?? []
        }
        var roles: [String: WellKnownFolder] = [:]
        for f in (try? store.folders()) ?? [] { if let w = f.wellKnown { roles[f.id] = w } }
        var found = 0
        for cid in todo where !cid.isEmpty { found += refresh(conversation: cid, cfg: cfg, roles: roles, cutoff: cutoff) }
        lock.withLock { gen += 1 }
        return found
    }

    func refresh(conversation cid: String, cfg: Config, roles: [String: WellKnownFolder], cutoff: Date) -> Int {
        let skip: Set<WellKnownFolder> = [.drafts, .deleteditems, .junkemail, .outbox]
        let ms = ((try? store.conversation(id: cid, limit: 200)) ?? [])
            .filter { !$0.isDraft && !(roles[$0.folderId].map { skip.contains($0) } ?? false) }
            .sorted { $0.received < $1.received }
        let owners = cfg.owners
        func mb(_ m: MailMessage) -> String { store.mailbox(forFolder: m.folderId) }
        func isMine(_ m: MailMessage) -> Bool {
            let f = m.from?.address.lowercased() ?? "", box = mb(m)
            return owners.contains(f) || (box != "me" && f == box.lowercased()) || roles[m.folderId] == .sentitems
        }
        func isMe(_ a: EmailAddress) -> Bool { owners.contains(a.address.lowercased()) }
        func text(_ m: MailMessage) -> (String, Bool)? {
            if let b = try? store.body(messageId: m.id, touch: false) { return (b, m.bodyIsHTML || b.contains("</")) }
            return m.preview.map { ($0, false) }
        }
        let prefix = convPrefix(cid)
        var existing = Dictionary(rows(prefix: prefix).map { ($0.1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byId = Dictionary(ms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Gate tightening: open rows whose source is no longer content go.
        for (id, (k, p)) in existing where p.state == .open {
            if let m = byId[p.sourceMessageId], cfg.exposure(m, mb(m)) != .content { delete(k); existing[id] = nil }
        }
        var found = 0
        for m in ms where m.received >= cutoff {
            let box = mb(m)
            guard cfg.exposure(m, box) == .content, let (t, html) = text(m) else { continue }
            let mine = isMine(m)
            let counterpart: EmailAddress?
            if mine {
                guard let to = m.toRecipients.first(where: { !isMe($0) }) else { continue }
                counterpart = to
            } else {
                // Direct only: the user in To, few others, a person (not a newsletter / notification).
                let others = (m.toRecipients + m.ccRecipients).filter { !isMe($0) }.count
                guard m.toRecipients.contains(where: isMe), others <= 2, ChannelClassifier.classify(m) == .person else { continue }
                counterpart = m.from
            }
            let persist = cfg.persistText(m, box)
            for c in PromiseExtractor.extract(t, isHTML: html, kind: mine ? .promised : .asked, sentAt: m.received, calendar: cfg.calendar) {
                let id = Promise.makeId(conversationId: cid, sentAt: m.received, kind: c.kind, text: c.text)
                if let (_, old) = existing[id] {
                    if !old.persistText, old.text == nil { lock.withLock { mem[id] = (c.text, counterpart.map { String($0.name.prefix(60)) }, counterpart.map { String($0.address.prefix(254)) }) } }
                    continue
                }
                let p = Promise(id: id, kind: c.kind, conversationId: cid, sourceMessageId: m.id, mailbox: box, text: c.text,
                                counterpartName: counterpart.map { String($0.name.prefix(60)) }, counterpartAddress: counterpart.map { String($0.address.prefix(254)) },
                                due: c.due, createdAt: m.received, certain: c.certain, persistText: persist)
                put(p); existing[id] = (rowKey(p), p); found += 1
            }
        }
        // Auto-complete: a later message from the user with an attachment or an "attached" marker.
        for (_, (_, p)) in existing where p.state == .open {
            for m in ms where m.received > p.createdAt && isMine(m) {
                var how: PromiseCompletion?
                if m.hasAttachments { how = .attachment }
                else if cfg.exposure(m, mb(m)) == .content, let (t, html) = text(m) {
                    let body = AIUntrustedText.stripQuotedAndSignature(AIUntrustedText.body(t, isHTML: html))
                    if PromiseRegex.shared.has(Self.attachedMarkers, body) { how = .attachedMarker }
                }
                if let how {
                    var q = p; q.state = .done; q.completion = how; q.closedAt = m.received
                    put(q); break
                }
            }
        }
        return found
    }

    // MARK: Reads

    public func all() -> [Promise] { rows(prefix: tag()).map(\.1) }
    public func promises(conversationId: String) -> [Promise] { rows(prefix: convPrefix(conversationId)).map(\.1) }
    public func promise(id: String) -> Promise? { all().first { $0.id == id } }

    /// Open, un-snoozed, by due date (undated last).
    public func open(now: Date = Date()) -> [Promise] {
        all().filter { $0.state == .open && !$0.isSnoozed(now: now) }
            .sorted { ($0.due ?? .distantFuture, $0.createdAt) < ($1.due ?? .distantFuture, $1.createdAt) }
    }

    public func stats(now: Date = Date()) -> Stats {
        let a = all(), cal = lock.withLock { config.calendar }
        var s = Stats()
        s.extracted = a.count
        s.open = a.filter { $0.state == .open }.count
        s.overdue = a.filter { $0.isOverdue(now: now, calendar: cal) }.count
        s.autoDone = a.filter { $0.completion?.isAuto ?? false }.count
        return s
    }

    /// `[Promises] extracted=… open=… overdue=… autoDone=…` (counts only).
    public func diagnostic(now: Date = Date()) -> String {
        let s = stats(now: now)
        return "[Promises] extracted=\(s.extracted) open=\(s.open) overdue=\(s.overdue) autoDone=\(s.autoDone)"
    }

    /// TODAY-HOOK (`PromiseSource`, Today.swift): open, un-snoozed promises due before `before` (today + overdue when
    /// Today passes tomorrow). Protected rows (text not stored / not readable) get a generic title.
    public func promisesDue(before: Date) -> [TodayPromise] { promisesDue(before: before, now: Date()) }
    public func promisesDue(before: Date, now: Date) -> [TodayPromise] {
        open(now: now).filter { ($0.due ?? .distantFuture) < before }.map { p in
            TodayPromise(id: p.id, title: "\(p.kind.title): \(p.text ?? "a promise in a protected message")",
                         due: p.due, conversationId: p.conversationId)
        }
    }

    // MARK: User actions

    func update(_ id: String, _ f: (inout Promise) -> Void) {
        guard var p = promise(id: id) else { return }
        f(&p); put(p)
        lock.withLock { gen += 1 }
    }
    public func markDone(_ id: String, now: Date = Date()) { update(id) { $0.state = .done; $0.completion = .user; $0.closedAt = now } }
    public func dismiss(_ id: String, now: Date = Date()) { update(id) { $0.state = .dismissed; $0.completion = .user; $0.closedAt = now } }
    public func reopen(_ id: String) { update(id) { $0.state = .open; $0.completion = nil; $0.closedAt = nil; $0.snoozedUntil = nil } }
    public func snooze(_ id: String, until: Date) { update(id) { $0.snoozedUntil = until } }
    public func markReminded(_ id: String, on day: Date) { update(id) { $0.remindedOn = day } }
    /// AI refinement of an uncertain candidate: drop it, or confirm (optionally a cleaner phrase / a due date).
    public func refine(_ id: String, keep: Bool, text: String?, due: Date?) {
        update(id) { p in
            p.origin = .llm
            if !keep { p.state = .dismissed; p.completion = .ai; return }
            p.certain = true
            if let text, !text.isEmpty { p.text = String(text.prefix(80)) }
            if p.due == nil, let due { p.due = due }
        }
    }
    /// Open rule candidates the AI pass may look at.
    public func uncertain() -> [Promise] { all().filter { $0.state == .open && !$0.certain && $0.origin == .rule } }
}

extension MailStore {
    /// PROMISES-HOOK: attach (or reconfigure) the promises ledger for this store's account.
    @discardableResult
    public func enablePromises(_ config: PromiseLedger.Config) -> PromiseLedger {
        locked {
            if let p = promises { p.configure(config); return p }
            let p = PromiseLedger(store: self, indexKey: indexKey, config: config)
            promises = p
            return p
        }
    }

    /// Diagnostics/tests: sealed payload sizes of the promise table (should be one size).
    public func debugPromisePayloadSizes() -> [Int] {
        (try? query("SELECT length(payload) FROM promise_item") { Int(sqlite3_column_int64($0, 0)) }) ?? []
    }
}
