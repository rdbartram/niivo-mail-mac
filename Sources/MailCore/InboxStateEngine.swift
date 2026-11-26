import Foundation
import CryptoKit
import SQLite3

// TRIAGE2: the per-store (= per account) conversation triage engine (plan §4.5).
// * Scope: every conversation with a message in the window (default 30 days), all mailboxes. Inbox members,
//   mine-last threads (incl. threads I started) and archived waiting threads are what the UI lists.
// * Store write paths mark conversations dirty (`touch`); `refresh` recomputes facts for dirty ones only (a full
//   pass on first use and after `resetHeaders`). Read and flag changes recompute facts but keep the signature, so
//   overrides and L3 results stay.
// * Tables (sealed, padded to a fixed bucket, keys = HMAC(account, id)): `conv_state` (L3 verdicts by signature),
//   `triage_override`, `sender_override` (explicit + correction counts), `triage_truth` (training answers).
//   `wipe()` clears them; `resetHeaders()` keeps them.

public final class InboxTriageEngine: @unchecked Sendable {
    public struct Config: Sendable {
        public var account: String
        /// The user's addresses (own + identities + shared mailbox addresses that count as "me").
        public var owners: Set<String>
        public var internalDomains: Set<String>
        public var firstName: String?
        /// On-device exposure (label gate). Cues only where `.content`.
        public var exposure: @Sendable (MailMessage, String) -> AIExposure
        public var meeting: @Sendable (MailMessage) -> TriageMeeting?
        public var settings: TriageSettings
        public var windowDays: Int
        public init(account: String, owners: Set<String>, internalDomains: Set<String> = [], firstName: String? = nil,
                    exposure: @escaping @Sendable (MailMessage, String) -> AIExposure,
                    meeting: @escaping @Sendable (MailMessage) -> TriageMeeting? = { _ in nil },
                    settings: TriageSettings = .init(), windowDays: Int = 30) {
            self.account = account; self.owners = Set(owners.map { $0.lowercased() }); self.internalDomains = internalDomains
            self.firstName = firstName; self.exposure = exposure; self.meeting = meeting; self.settings = settings
            self.windowDays = windowDays
        }
    }

    struct StoredVerdict: Codable { var signature: UInt64; var verdict: ThreadVerdict; var tier: String; var pad: String? }

    let store: MailStore
    private let key: SymmetricKey
    private let lock = NSLock()
    private var config: Config
    private var dirty: Set<String> = []
    private var full = true
    private var facts: [String: ConversationFacts] = [:]
    /// L3 verdicts held in memory only (text not allowed on disk), by conversation id.
    private var memVerdicts: [String: (UInt64, ThreadVerdict)] = [:]
    private var gen = 0
    /// Bumped whenever decisions may have changed (UI refresh hint).
    public var generation: Int { lock.withLock { gen } }
    public var account: String { lock.withLock { config.account } }
    public var settings: TriageSettings { lock.withLock { config.settings } }

    init(store: MailStore, indexKey: SymmetricKey, config: Config) {
        self.store = store; self.key = TriageKeys.derive(fromIndexKey: indexKey); self.config = config
    }

    // MARK: Dirty tracking (called from MailStore write paths, under the store lock: never call the store here)

    func touch(_ conversationId: String) { lock.withLock { _ = dirty.insert(conversationId) } }
    func markAllDirty() { lock.withLock { full = true; facts = [:]; memVerdicts = [:]; gen += 1 } }
    func wipe() { lock.withLock { full = true; facts = [:]; memVerdicts = [:]; dirty = []; gen += 1 } }

    public func configure(_ c: Config) {
        lock.withLock {
            let changed = c.account != config.account || c.owners != config.owners || c.windowDays != config.windowDays
                || c.firstName != config.firstName
            config = c
            if changed { full = true; facts = [:]; memVerdicts = [:] }
            gen += 1
        }
    }

    /// Exposure rules changed (label sync, policy, tier): recompute every conversation.
    public func policyChanged() { lock.withLock { full = true; memVerdicts = [:]; gen += 1 } }

    // MARK: Refresh

    /// Recomputes dirty conversations (or everything in the window). Returns the number recomputed. Safe off the
    /// main thread.
    @discardableResult
    public func refresh(now: Date = Date()) -> Int {
        let (cfg, isFull, ids) = lock.withLock { () -> (Config, Bool, Set<String>) in
            let r = (config, full, dirty); full = false; dirty = []; return r
        }
        let cutoff = Int64(now.addingTimeInterval(-Double(cfg.windowDays) * 86_400).timeIntervalSince1970)
        var todo: [String]
        if isFull {
            todo = (try? store.query("SELECT DISTINCT conversation_id FROM messages WHERE received >= ?", [.int(cutoff)]) { s in
                sqlite3_column_text(s, 0).map { String(cString: $0) } ?? "" }) ?? []
        } else { todo = Array(ids) }
        todo = todo.filter { !$0.isEmpty }
        guard isFull || !todo.isEmpty else { return 0 }
        let inputs = makeInputs(cfg)
        var out: [String: ConversationFacts?] = [:]
        for cid in todo {
            let ms = (try? store.conversation(id: cid, limit: 200)) ?? []
            let inWindow = ms.contains { Int64($0.received.timeIntervalSince1970) >= cutoff }
            out[cid] = inWindow ? ConversationFactsBuilder.build(conversationId: cid, messages: ms, inputs: inputs) : nil
        }
        lock.withLock {
            if isFull { facts = [:] }
            for (cid, f) in out { facts[cid] = f ?? nil }
            gen += 1
        }
        return todo.count
    }

    func folderRoles() -> [String: WellKnownFolder] {
        var roleMap: [String: WellKnownFolder] = [:]
        for f in (try? store.folders()) ?? [] { if let w = f.wellKnown { roleMap[f.id] = w } }
        return roleMap
    }

    static func isMine(store: MailStore, owners: Set<String>, roles: [String: WellKnownFolder]) -> @Sendable (MailMessage) -> Bool {
        { m in
            let mb = store.mailbox(forFolder: m.folderId)
            let f = m.from?.address.lowercased() ?? ""
            if owners.contains(f) || (mb != "me" && f == mb.lowercased()) { return true }
            return roles[m.folderId] == .sentitems
        }
    }

    func makeInputs(_ cfg: Config) -> TriageInputs {
        let store = self.store
        let owners = cfg.owners
        let exposure = cfg.exposure
        let senderPriors = allSenderPriors()
        let key = self.key, account = cfg.account
        // One folder snapshot per refresh (no per-message folder query).
        let roles = folderRoles()
        return TriageInputs(
            account: cfg.account,
            isMine: Self.isMine(store: store, owners: owners, roles: roles),
            myAddresses: owners, internalDomains: cfg.internalDomains, firstName: cfg.firstName,
            folderRole: { roles[$0] },
            exposure: { m in exposure(m, store.mailbox(forFolder: m.folderId)) },
            text: { m in
                if let b = try? store.body(messageId: m.id, touch: false) { return (b, m.bodyIsHTML || b.contains("</")) }
                return m.preview.map { ($0, false) }
            },
            meeting: cfg.meeting,
            senderOverride: { addr in senderPriors[TriageKeys.sender(addr, account: account, key: key)]?.explicit })
    }

    // MARK: Reads

    public func facts(for conversationId: String) -> ConversationFacts? { lock.withLock { facts[conversationId] } }
    public func allFacts() -> [ConversationFacts] { lock.withLock { Array(facts.values) } }

    /// Conversations the UI lists: an inbox member, or mine last (Sent), or archived waiting.
    public static func inScope(_ f: ConversationFacts, _ d: TriageDecision) -> Bool {
        f.hasInboxMember || f.lastFromMe || d.state == .waiting
    }

    /// Full decision (rules + overrides + priors + L3) for one conversation.
    public func decision(for conversationId: String, now: Date = Date(), ignoreOverride: Bool = false) -> TriageDecision? {
        guard let f = facts(for: conversationId) else { return nil }
        return decide(f, now: now, ignoreOverride: ignoreOverride)
    }

    /// `ignoreOverride` also drops the learned sender counts (an explicit sender setting stays): the training
    /// answers feed both, so a prediction for scoring must not see them.
    public func decide(_ f: ConversationFacts, now: Date = Date(), ignoreOverride: Bool = false) -> TriageDecision {
        let s = settings
        let o = ignoreOverride ? nil : override(conversationId: f.conversationId)
        let p = f.senderAddress.map { a -> SenderPrior in
            let sp = senderPrior(a)
            return ignoreOverride ? SenderPrior(explicit: sp.explicit) : sp
        }
        var d = TriageRules.decide(f, override: o, sender: p, settings: s, now: now)
        if !f.restricted, let v = verdict(f) { d = TriageRules.merge(d, llm: v) }
        return d
    }

    /// Every in-scope conversation → decision. Total: every listed conversation has a state.
    public func decisions(now: Date = Date()) -> [String: TriageDecision] {
        var out: [String: TriageDecision] = [:]
        for f in allFacts() {
            let d = decide(f, now: now)
            if Self.inScope(f, d) { out[f.conversationId] = d }
        }
        return out
    }

    // MARK: L3 verdicts

    func verdict(_ f: ConversationFacts) -> ThreadVerdict? {
        if let (sig, v) = lock.withLock({ memVerdicts[f.conversationId] }), sig == f.signature { return v }
        guard let s: StoredVerdict = get("conv_state", convKey(f.conversationId)), s.signature == f.signature else { return nil }
        return s.verdict
    }

    /// `persistText`: only when every message that went in as content allows offline details (and the device policy
    /// allows offline bodies). Otherwise ask/why live in memory only and the disk keeps the state alone.
    public func storeVerdict(_ v: ThreadVerdict, conversationId: String, tier: AITier, persistText: Bool) {
        guard let f = facts(for: conversationId), !f.restricted else { return }
        lock.withLock { memVerdicts[conversationId] = (f.signature, v) }
        var disk = v
        if !persistText { disk.ask = nil; disk.why = nil }
        put("conv_state", convKey(conversationId), StoredVerdict(signature: f.signature, verdict: disk, tier: tier.rawValue, pad: nil))
        lock.withLock { gen += 1 }
    }

    /// Policy or tier change: L3 results go, L1 states stay.
    public func dropVerdicts() {
        try? store.run("DELETE FROM conv_state WHERE substr(key,1,4)=?", [.blob(TriageKeys.accountTag(account, key: key))])
        lock.withLock { memVerdicts = [:]; gen += 1 }
    }

    // MARK: Overrides and corrections (one-click correction and the training tool share this path)

    public func override(conversationId: String) -> ConversationOverride? { get("triage_override", convKey(conversationId)) }

    /// Pinned to the newest message (TRIAGE3): live while that's still the newest, expired by the next inbound message
    /// or my reply (then the state machine decides again). Also counts toward the sender's prior.
    /// `asOf`: the snapshot the user was looking at; if a newer message arrived meanwhile, nothing is applied (the
    /// correction would already be stale). nil = the engine's newest now.
    /// TODAY-HOOK: `learn: false` = "handled" (Today's Done / Mark all done), not "misclassified": no sender prior.
    public func correct(conversationId: String, to state: ConversationState, now: Date = Date(), learn: Bool = true,
                        asOf: TriageSnapshot? = nil) {
        guard let f = facts(for: conversationId) else { return }
        if let asOf, !f.isCurrent(asOf) { return }
        put("triage_override", convKey(conversationId),
            ConversationOverride(state: state, setAt: now, eventSignature: f.eventSignature, snapshot: snapshot(of: f)))
        if learn, let a = f.senderAddress, !f.lastFromMe {
            var p = senderPrior(a)
            p.counts[state.rawValue, default: 0] += 1
            put("sender_override", senderKey(a), p)
        }
        lock.withLock { gen += 1 }
    }

    public func clearOverride(conversationId: String) {
        try? store.run("DELETE FROM triage_override WHERE key=?", [.blob(convKey(conversationId))])
        lock.withLock { gen += 1 }
    }

    public func senderPrior(_ address: String) -> SenderPrior { get("sender_override", senderKey(address)) ?? SenderPrior() }

    /// "Never reply needed from this sender" (R11), or a channel move (bulk / person). nil clears it.
    public func setSenderOverride(_ address: String, _ kind: SenderOverrideKind?) {
        var p = senderPrior(address)
        p.explicit = kind
        put("sender_override", senderKey(address), p)
        if kind == .bulk || kind == .person { lock.withLock { full = true } }   // channel changes need fresh facts
        lock.withLock { gen += 1 }
    }

    func allSenderPriors() -> [Data: SenderPrior] {
        var out: [Data: SenderPrior] = [:]
        for (k, v) in all("sender_override", SenderPrior.self) { out[k] = v }
        return out
    }

    /// Settings → AI → Reset learning: overrides and sender priors go; ground truth stays.
    public func resetLearning() {
        let tag = TriageKeys.accountTag(account, key: key)
        try? store.run("DELETE FROM triage_override WHERE substr(key,1,4)=?", [.blob(tag)])
        try? store.run("DELETE FROM sender_override WHERE substr(key,1,4)=?", [.blob(tag)])
        lock.withLock { full = true; gen += 1 }
    }

    public struct LearningCounts: Sendable, Hashable {
        public var overrides: Int; public var senders: Int; public var truths: Int
        public init(overrides: Int, senders: Int, truths: Int) { self.overrides = overrides; self.senders = senders; self.truths = truths }
    }
    public func learningCounts() -> LearningCounts {
        let tag = TriageKeys.accountTag(account, key: key)
        func n(_ t: String) -> Int { Int(((try? store.scalarInt("SELECT COUNT(*) FROM \(t) WHERE substr(key,1,4)=?", [.blob(tag)])) ?? nil) ?? 0) }
        return LearningCounts(overrides: n("triage_override"), senders: n("sender_override"), truths: n("triage_truth"))
    }

    // MARK: Ground truth (training tool)

    // TRIAGE3: "who acts next" is a judgement as of a snapshot (the newest message the user saw). Answers are keyed by
    // conversation + snapshot time and scored against the prediction recomputed from the messages up to the snapshot,
    // so a later reply or inbound message never turns a right answer into a miss.

    /// The snapshot for a conversation's current newest counted message.
    public func snapshot(of f: ConversationFacts) -> TriageSnapshot { TriageSnapshot(tag: messageTag(f.latestMessageId), at: f.latest) }
    public func snapshot(of m: MailMessage) -> TriageSnapshot { TriageSnapshot(tag: messageTag(m.id), at: m.received) }
    func messageTag(_ id: String) -> Data { TriageKeys.message(id, account: account, key: key) }
    func truthKey(_ cid: String, _ s: TriageSnapshot) -> Data { TriageKeys.truth(cid, snapshotAt: s.at, account: account, key: key) }

    /// TRIAGE3-HOOK: the conversation as the engine counts it (no drafts, deleted, junk, outbox), oldest first, with
    /// which messages are mine. The trainer shows exactly this.
    public func countedThread(conversationId: String) -> [(message: MailMessage, mine: Bool)] {
        let roles = folderRoles()
        let mine = Self.isMine(store: store, owners: lock.withLock { config.owners }, roles: roles)
        let ms = ConversationFactsBuilder.counted((try? store.conversation(id: conversationId, limit: 200)) ?? [], folderRole: { roles[$0] })
        return ms.map { ($0, mine($0)) }
    }

    /// The prediction as of `s` (rules + any L3 verdict cached for that state; no override, no learned sender counts),
    /// evaluated at `clock`. nil when nothing of the conversation is left.
    public func prediction(conversationId: String, asOf s: TriageSnapshot, inboxAtSnapshot: Bool?, clock: Date) -> TriageDecision? {
        prediction(conversationId: conversationId, current: facts(for: conversationId), asOf: s, inboxAtSnapshot: inboxAtSnapshot,
                   clock: clock, inputs: nil)
    }

    func prediction(conversationId cid: String, current: ConversationFacts?, asOf s: TriageSnapshot, inboxAtSnapshot: Bool?,
                    clock: Date, inputs: TriageInputs?) -> TriageDecision? {
        if var f = current, f.isCurrent(s) {
            if let inboxAtSnapshot { f.hasInboxMember = inboxAtSnapshot }
            return decide(f, now: clock, ignoreOverride: true)
        }
        let inp = inputs ?? makeInputs(lock.withLock { config })
        let tag = s.tag
        guard let f = ConversationFactsBuilder.build(conversationId: cid, messages: (try? store.conversation(id: cid, limit: 200)) ?? [],
                                                     inputs: inp, asOf: s, isSnapshot: { [self] in messageTag($0.id) == tag },
                                                     inboxAtSnapshot: inboxAtSnapshot) else { return nil }
        return decide(f, now: clock, ignoreOverride: true)
    }

    /// Records an answer as of `asOf` (the snapshot the user saw; nil = the newest now) and, while that snapshot is
    /// still the newest message, applies it as a correction pinned to it. The prediction is taken as of the snapshot
    /// with the override ignored.
    public func recordTruth(conversationId: String, asOf: TriageSnapshot? = nil, truth: ConversationState?, wrongSenderType: Bool,
                            now: Date = Date()) {
        guard let f = facts(for: conversationId) else { return }
        let s = asOf ?? snapshot(of: f)
        let pred = prediction(conversationId: conversationId, current: f, asOf: s, inboxAtSnapshot: f.hasInboxMember, clock: now, inputs: nil)
            ?? decide(f, now: now, ignoreOverride: true)
        put("triage_truth", truthKey(conversationId, s),
            TriageTruth(truth: truth, predicted: pred.state, predictedConfidence: pred.confidence, eventSignature: f.eventSignature,
                        wrongSenderType: wrongSenderType, answeredAt: now, snapshot: s, inboxAtSnapshot: f.hasInboxMember))
        if let truth { correct(conversationId: conversationId, to: truth, now: now, asOf: s) }
    }

    /// Every answer, ready for scoring. Matched by HMAC key prefix, so no conversation id is stored with the truth.
    /// `repredict`: recompute the prediction as of each snapshot with today's rules and settings (clock = when it was
    /// answered), so re-running Score after a rule change shows the change; otherwise the stored prediction.
    /// Conversations no longer in the window keep their stored prediction (it was taken as of the same snapshot).
    public func truthRows(repredict: Bool = false) -> [TriageTruthRow] {
        migrateLegacyTruths()
        let byKey = Dictionary(allFacts().map { (convKey($0.conversationId), $0) }, uniquingKeysWith: { a, _ in a })
        var inputs: TriageInputs?
        return all("triage_truth", TriageTruth.self).map { k, t in
            guard let s = t.snapshot, let f = byKey[Data(k.prefix(20))] else { return TriageTruthRow(truth: t) }
            var pred = t.predicted
            // Migrated rows carry no inbox bit: once moved on, today's folders (archived after replying) would turn the
            // old state into "archived → done", so they keep the prediction taken when they were answered.
            if repredict, t.inboxAtSnapshot != nil || f.isCurrent(s) {
                if inputs == nil, !f.isCurrent(s) { inputs = makeInputs(lock.withLock { config }) }
                pred = prediction(conversationId: f.conversationId, current: f, asOf: s, inboxAtSnapshot: t.inboxAtSnapshot,
                                  clock: t.answeredAt, inputs: inputs)?.state ?? t.predicted
            }
            return TriageTruthRow(truth: t, predictedAsOf: pred, movedOn: !f.isCurrent(s))
        }
    }

    /// Pre-snapshot answers (bare conversation key, no snapshot): pinned to the newest message when they were saved,
    /// found as the prefix of the conversation whose event signature matches the stored one, then re-keyed. Rows
    /// that can't be derived (conversation gone or out of the window, or no prefix matches) stay as they are and aren't scored.
    /// Pre-snapshot overrides need no rewrite: they stay live only while the event signature is unchanged
    /// (`ConversationOverride.isLive`). Plan "Build status (TRIAGE3)".
    func migrateLegacyTruths() {
        let legacy = all("triage_truth", TriageTruth.self).filter { $0.0.count == 20 && $0.1.snapshot == nil }
        guard !legacy.isEmpty else { return }
        let byKey = Dictionary(allFacts().map { (convKey($0.conversationId), $0) }, uniquingKeysWith: { a, _ in a })
        let inputs = makeInputs(lock.withLock { config })
        for (k, var t) in legacy {
            guard let f = byKey[k] else { continue }
            let m: MailMessage?
            if f.eventSignature == t.eventSignature {
                m = nil
            } else {
                let counted = ConversationFactsBuilder.counted((try? store.conversation(id: f.conversationId, limit: 200)) ?? [],
                                                               folderRole: inputs.folderRole)
                guard let hit = ConversationFactsBuilder.message(withEventSignature: t.eventSignature, in: counted, inputs: inputs) else { continue }
                m = hit
            }
            let s = m.map { snapshot(of: $0) } ?? snapshot(of: f)
            t.snapshot = s
            put("triage_truth", truthKey(f.conversationId, s), t)
            try? store.run("DELETE FROM triage_truth WHERE key=?", [.blob(k)])
        }
    }

    /// TRIAGE3 test seam: writes an answer the way pre-snapshot builds did (bare conversation key, no snapshot).
    public func debugRecordLegacyTruth(conversationId: String, _ t: TriageTruth) {
        var t = t; t.snapshot = nil; t.inboxAtSnapshot = nil
        put("triage_truth", convKey(conversationId), t)
    }
    /// TRIAGE3 test seam: a pre-snapshot override (no snapshot) at the conversation's current event signature.
    public func debugRecordLegacyOverride(conversationId: String, to state: ConversationState, now: Date) {
        guard let f = facts(for: conversationId) else { return }
        put("triage_override", convKey(conversationId), ConversationOverride(state: state, setAt: now, eventSignature: f.eventSignature))
        lock.withLock { gen += 1 }
    }

    /// One conversation's display decision (nil = out of scope), for a cheap republish after a correction.
    public func scopedDecision(for conversationId: String, now: Date = Date()) -> TriageDecision? {
        guard let f = facts(for: conversationId) else { return nil }
        let d = decide(f, now: now)
        return Self.inScope(f, d) ? d : nil
    }

    /// Conversation ids already answered as of their current newest message (so the sampler skips them). TRIAGE3: a
    /// conversation that has moved on since its answer can be asked again, as of the new message.
    public func answeredIds() -> Set<String> {
        migrateLegacyTruths()
        var latestAnswered: [Data: Date] = [:]
        for (k, t) in all("triage_truth", TriageTruth.self) {
            guard let s = t.snapshot else { continue }
            let p = Data(k.prefix(20))
            latestAnswered[p] = max(latestAnswered[p] ?? .distantPast, s.at)
        }
        return Set(allFacts().filter { f in
            latestAnswered[convKey(f.conversationId)].map { f.isCurrent(TriageSnapshot(tag: Data(), at: $0)) } ?? false
        }.map(\.conversationId))
    }

    public func clearTruths() {
        try? store.run("DELETE FROM triage_truth WHERE substr(key,1,4)=?", [.blob(TriageKeys.accountTag(account, key: key))])
        lock.withLock { gen += 1 }
    }

    // MARK: Sealed rows (padded to a 512-byte bucket so sizes don't reveal which rows carry text)

    func convKey(_ id: String) -> Data { TriageKeys.conversation(id, account: account, key: key) }
    func senderKey(_ a: String) -> Data { TriageKeys.sender(a, account: account, key: key) }

    static let bucket = 512
    func put<T: Encodable>(_ table: String, _ k: Data, _ v: T) {
        guard var d = try? JSONEncoder().encode(v) else { return }
        let target = ((d.count / Self.bucket) + 1) * Self.bucket
        d.append(Data(repeating: 0x20, count: target - d.count))   // JSON allows trailing whitespace
        guard let sealed = try? store.sealData(d) else { return }
        try? store.run("INSERT OR REPLACE INTO \(table)(key,payload) VALUES(?,?)", [.blob(k), .blob(sealed)])
    }

    func get<T: Decodable>(_ table: String, _ k: Data) -> T? {
        guard let d = (try? store.query("SELECT payload FROM \(table) WHERE key=?", [.blob(k)], { s in Self.blob(s, 0) }))?.first,
              let plain = try? store.openData(d) else { return nil }
        return try? JSONDecoder().decode(T.self, from: plain)
    }

    func all<T: Decodable>(_ table: String, _ t: T.Type) -> [(Data, T)] {
        // Only this account's namespace (keys start with the account tag).
        let tag = TriageKeys.accountTag(account, key: key)
        let rows = ((try? store.query("SELECT key, payload FROM \(table)") { s in (Self.blob(s, 0), Self.blob(s, 1)) }) ?? [])
            .filter { $0.0.prefix(4) == tag }
        return rows.compactMap { k, d in (try? store.openData(d)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }.map { (k, $0) } }
    }

    static func blob(_ s: OpaquePointer?, _ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(s, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }
}

extension MailStore {
    /// Diagnostics/tests: sealed payload sizes across the triage tables (should be one bucket).
    public func debugTriagePayloadSizes() -> [Int] {
        ["conv_state", "triage_override", "sender_override", "triage_truth"].flatMap { t in
            (try? query("SELECT length(payload) FROM \(t)") { Int(sqlite3_column_int64($0, 0)) }) ?? []
        }
    }

    /// TRIAGE2-HOOK: attach (or reconfigure) the conversation triage engine for this store's account.
    @discardableResult
    public func enableInboxTriage(_ config: InboxTriageEngine.Config) -> InboxTriageEngine {
        locked {
            if let t = triage { t.configure(config); return t }
            let t = InboxTriageEngine(store: self, indexKey: indexKey, config: config)
            triage = t
            return t
        }
    }
}
