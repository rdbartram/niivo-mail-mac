import Foundation
import CryptoKit
import SQLite3

// LOOPS (docs/SUITE.md, suite step 1): the per-account loop store and proposal engine.
//
// * Storage: one sealed table `loop_row(key, payload)`; key = 4-byte account tag + type byte (1 loop, 2 membership,
//   3 "not this loop") + HMAC (HKDF info "loops-v1"); payloads padded to 1 KB buckets. On disk: loop ids, states, due
//   dates, conversation ids, user titles, keyed anchor hashes. Never message ids (Graph ids change on move), never
//   anchor text, and a derived (seeded) title only when every source message may keep offline details; otherwise it
//   lives in memory and the next seed pass restores it. User data: survives `resetHeaders`, goes with `wipe`.
// * Proposals (user tier) draw only on anchors (StoryAnchors) read from text-visible messages, following the linking
//   rules of docs/INBOX-INTELLIGENCE-PLAN.md §5.3: `id` and `proj` link alone; `att` needs a shared (non-owner) person
//   or organisation; `stem` needs that plus ≤ 21 days. Shared people, organisations or time alone never propose
//   anything. Bulk / notification conversations link only through an `id`. `id` anchors seen in > 10 conversations
//   are ignored (footer customer numbers).
// * Protected sources contribute metadata only: no anchors, no titles, no proposal. Loops never span accounts: every
//   key carries the account tag and each engine reads only its own namespace.
// * Seeding: knowledge matters (people with a direct exchange) become SUGGESTED loops with proposed memberships;
//   an anchor that already seeded (or belongs to) any loop, in any state, is never seeded again, so a rejected or
//   archived suggestion stays gone.
// * Logs: `[Loops] open= confirmed= suggested= proposalsShown= accepted=` (counts only).

public struct LoopMemberInfo: Sendable, Hashable, Identifiable {
    public var conversationId: String
    public var origin: LoopOrigin
    /// The anchor behind a proposed membership, when the conversation's text is visible for the tier.
    public var reason: LoopReason?
    /// nil when no message of the conversation is visible for the tier (the member still counts).
    public var thread: KnowledgeThread?
    public var id: String { conversationId }
}

public struct LoopDetail: Sendable, Hashable {
    public var summary: LoopSummary
    public var members: [LoopMemberInfo]
    /// Non-generic attachments from text-visible member messages, newest first.
    public var files: [KnowledgeFile]
    /// Open promises in the member conversations (as the promise source redacts them).
    public var promises: [TodayPromise]
    /// Member threads, newest activity first.
    public var timeline: [KnowledgeThread]
}

public final class LoopsEngine: @unchecked Sendable, LoopSource {
    public struct Config: Sendable {
        public var account: String
        public var owners: Set<String>
        public init(account: String, owners: Set<String>) {
            self.account = account; self.owners = Set(owners.map { $0.lowercased() })
        }
    }

    struct Def: Codable, Hashable {
        var id: String
        var title: String?
        var titleUser: Bool
        /// The conversation a derived title came from (its visibility decides whether the title shows).
        var titleConv: String?
        var titleOnDisk: Bool
        var state: LoopState
        var due: Date?
        var created: Date
        var updated: Date
        var suggested: Bool
        /// Keyed hashes of the anchors this loop was seeded from / merged with (seed suppression only).
        var anchors: [String]
    }
    struct Member: Codable, Hashable { var loop: String; var conv: String; var origin: LoopOrigin; var at: Date }
    struct Negative: Codable, Hashable { var loop: String; var conv: String; var at: Date }

    struct Rows {
        var defs: [String: Def] = [:]
        /// conversation → membership (a conversation is in at most one loop)
        var members: [String: Member] = [:]
        /// "loop|conversation"
        var negatives: [String: Negative] = [:]
        func byLoop() -> [String: [Member]] { Dictionary(grouping: members.values, by: \.loop) }
    }

    /// Per knowledge snapshot, user tier: what each conversation may link with.
    struct Index {
        var generation = Int.min
        var anchors: [String: [StoryAnchor]] = [:]
        var df: [String: Int] = [:]
        var people: [String: Set<String>] = [:]
        var orgs: [String: Set<String>] = [:]
        var last: [String: Date] = [:]
        var bulk: Set<String> = []
        /// The newest message of the conversation is mine.
        var lastMine: Set<String> = []
    }

    enum Op { case putDef(Def), deleteDef(String), putMember(Member), deleteMember(String), putNeg(Negative), deleteNeg(String, String) }

    let store: MailStore
    public let knowledge: KnowledgeEngine
    private let key: SymmetricKey
    private let lock = NSLock()
    /// Serialises edits end to end (memory + disk), so a background seed and a user action land on disk in the same
    /// order as in memory. Never taken by `wipe()` (which runs under the store lock).
    private let writeLock = NSLock()
    private var config: Config
    private var rows: Rows?
    private var idx: Index?
    private var lastBest: [String: String] = [:]
    private var shown: Set<String> = []
    private var acceptedCount = 0
    private var gen = 0

    public var account: String { lock.withLock { config.account } }
    /// Bumps on every edit (UI revision).
    public var generation: Int { lock.withLock { gen } }
    static let bucket = 1024
    static let maxTitle = 200

    init(store: MailStore, indexKey: SymmetricKey, knowledge: KnowledgeEngine, config: Config) {
        self.store = store; self.knowledge = knowledge; self.config = config
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: indexKey, salt: Data("compliant-office.mail".utf8), info: Data("loops-v1".utf8), outputByteCount: 32)
    }

    public func configure(_ c: Config) {
        lock.withLock {
            if c.account != config.account { rows = nil; lastBest = [:]; shown = []; acceptedCount = 0 }
            config = c; idx = nil; gen += 1
        }
    }
    /// Labels / policy changed: proposals and titles are re-evaluated (the stored loops stay).
    public func policyChanged() { lock.withLock { idx = nil; gen += 1 } }
    /// Called under the store lock (MailStore.wipe): memory only, never the store.
    func wipe() { lock.withLock { rows = nil; idx = nil; lastBest = [:]; shown = []; acceptedCount = 0; gen += 1 } }

    // MARK: Keys and rows

    private func tag(_ account: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data("a|\(account)".utf8), using: key).prefix(4)) }
    private func rowKey(_ account: String, _ type: UInt8, _ s: String) -> Data {
        tag(account) + Data([type]) + Data(HMAC<SHA256>.authenticationCode(for: Data("\(type)|\(account)|\(s)".utf8), using: key).prefix(16))
    }
    func anchorHash(_ a: StoryAnchor, account: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("anchor|\(account)|\(a.key)".utf8), using: key).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func seal<T: Encodable>(_ v: T) -> Data? {
        guard var d = try? JSONEncoder().encode(v) else { return nil }
        d.append(Data(repeating: 0x20, count: ((d.count / Self.bucket) + 1) * Self.bucket - d.count))
        return try? store.sealData(d)
    }

    private func loaded() -> Rows {
        if let r = lock.withLock({ rows }) { return r }
        let acct = account
        let prefix = tag(acct)
        let raw = (try? store.query("SELECT key, payload FROM loop_row WHERE substr(key,1,4)=?", [.blob(prefix)]) { s in
            (KnowledgeEngine.blob(s, 0), KnowledgeEngine.blob(s, 1))
        }) ?? []
        var r = Rows()
        let dec = JSONDecoder()
        for (k, p) in raw {
            guard k.count > 4, let plain = try? store.openData(p) else { continue }
            switch k[k.startIndex + 4] {
            case 1: if let d = try? dec.decode(Def.self, from: plain) { r.defs[d.id] = d }
            case 2: if let m = try? dec.decode(Member.self, from: plain) { r.members[m.conv] = m }
            case 3: if let n = try? dec.decode(Negative.self, from: plain) { r.negatives[n.loop + "|" + n.conv] = n }
            default: break
            }
        }
        r.members = r.members.filter { r.defs[$0.value.loop] != nil }
        return lock.withLock {
            if rows == nil, config.account == acct { rows = r }
            return rows ?? r
        }
    }

    /// Mutates the in-memory rows under the lock, then writes the ops outside it (never call the store under the lock).
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
            case .putDef(var d):
                if !d.titleUser && !d.titleOnDisk { d.title = nil }
                if let s = seal(d) { try? store.run("INSERT OR REPLACE INTO loop_row(key,payload) VALUES(?,?)", [.blob(rowKey(acct, 1, d.id)), .blob(s)]) }
            case .deleteDef(let id):
                try? store.run("DELETE FROM loop_row WHERE key=?", [.blob(rowKey(acct, 1, id))])
            case .putMember(let m):
                if let s = seal(m) { try? store.run("INSERT OR REPLACE INTO loop_row(key,payload) VALUES(?,?)", [.blob(rowKey(acct, 2, m.conv)), .blob(s)]) }
            case .deleteMember(let c):
                try? store.run("DELETE FROM loop_row WHERE key=?", [.blob(rowKey(acct, 2, c))])
            case .putNeg(let n):
                if let s = seal(n) { try? store.run("INSERT OR REPLACE INTO loop_row(key,payload) VALUES(?,?)", [.blob(rowKey(acct, 3, n.loop + "|" + n.conv)), .blob(s)]) }
            case .deleteNeg(let l, let c):
                try? store.run("DELETE FROM loop_row WHERE key=?", [.blob(rowKey(acct, 3, l + "|" + c))])
            }
        }
        return out
    }

    // MARK: Index (user tier)

    func index() -> Index {
        let g = knowledge.snapshotGeneration
        if let i = lock.withLock({ idx }), i.generation == g { return i }
        let owners = lock.withLock { config.owners }
        let ownerOrgs = Set(owners.compactMap { MailDomains.companyKey(for: $0) })
        var i = Index(); i.generation = g
        let byConv = Dictionary(grouping: knowledge.messages(tier: .user), by: { $0.m.conversationId })
        for (cid, xs) in byConv {
            let a = KnowledgeAsk.anchors(xs, engine: knowledge, tier: .user)
            i.anchors[cid] = a
            for x in a { i.df[x.key, default: 0] += 1 }
            var ps = Set<String>()
            for x in xs { for e in KnowledgeEngine.addresses(x.m) { let k = e.address.lowercased(); if !k.isEmpty, !owners.contains(k) { ps.insert(k) } } }
            i.people[cid] = ps
            i.orgs[cid] = Set(ps.compactMap { MailDomains.companyKey(for: $0) }).subtracting(ownerOrgs)
            i.last[cid] = xs.map(\.m.received).max()
            if xs.max(by: { $0.m.received < $1.m.received })?.mine == true { i.lastMine.insert(cid) }
            let inbound = xs.filter { !$0.mine }
            if !inbound.isEmpty, inbound.allSatisfy({ let c = ChannelClassifier.classify($0.m); return c != .person && c != .calendar }) {
                i.bulk.insert(cid)
            }
        }
        lock.withLock { idx = i }
        return i
    }

    static func shares(_ a: String, _ b: String, _ i: Index) -> Bool {
        !(i.people[a] ?? []).isDisjoint(with: i.people[b] ?? []) || !(i.orgs[a] ?? []).isDisjoint(with: i.orgs[b] ?? [])
    }

    static let stemDays: TimeInterval = 21 * 86_400
    static func weight(_ k: StoryAnchor.Kind) -> Double { switch k { case .id: 1.0; case .proj: 0.9; case .att: 0.7; case .stem: 0.5 } }

    /// The strongest linking anchor between conversation `c` and the loop's conversations (§5.3), or nil.
    static func evidence(_ c: String, _ loopConvs: [String], _ i: Index) -> StoryAnchor? {
        let ca = i.anchors[c] ?? []
        guard !ca.isEmpty, !loopConvs.isEmpty else { return nil }
        let bulk = i.bulk.contains(c)
        var best: StoryAnchor?
        for a in ca {
            if a.kind == .id, (i.df[a.key] ?? 0) > 10 { continue }
            if bulk, a.kind != .id { continue }
            let holders = loopConvs.filter { (i.anchors[$0] ?? []).contains(a) && (a.kind == .id || !i.bulk.contains($0)) }
            guard !holders.isEmpty else { continue }
            switch a.kind {
            case .id, .proj: break
            case .att: guard holders.contains(where: { shares(c, $0, i) }) else { continue }
            case .stem:
                guard holders.contains(where: { h in
                    shares(c, h, i) && abs((i.last[c] ?? .distantPast).timeIntervalSince(i.last[h] ?? .distantFuture)) <= stemDays
                }) else { continue }
            }
            if best.map({ weight(a.kind) > weight($0.kind) }) ?? true { best = a }
        }
        return best
    }

    // MARK: Summaries

    private func resolvedTitle(_ d: Def, members: [Member], tier: KnowledgeTier) -> String? {
        guard let t = d.title, !t.isEmpty else { return nil }
        if case .ai = tier {
            // An AI tier sees a loop title only when every member conversation is text-visible for it.
            let all = members.allSatisfy { m in knowledge.conversation(m.conv, tier: tier).contains { knowledge.textVisible($0.m.id, tier: tier) } }
            guard all else { return nil }
        }
        if d.titleUser { return t }
        guard let tc = d.titleConv else { return nil }
        return knowledge.conversation(tc, tier: tier).contains { knowledge.textVisible($0.m.id, tier: tier) } ? t : nil
    }

    private func summary(_ d: Def, _ members: [Member], _ i: Index) -> LoopSummary {
        let convs = members.map(\.conv)
        let people = Set(convs.flatMap { i.people[$0] ?? [] })
        let orgs = Set(convs.flatMap { i.orgs[$0] ?? [] })
        let confirmed = members.filter { $0.origin.isConfirmed }.count
        let newest = convs.max { (i.last[$0] ?? .distantPast, $0) < (i.last[$1] ?? .distantPast, $1) }
        let waiting: LoopWaitingOn = d.state != .open ? .none : newest.map { i.lastMine.contains($0) ? .them : .me } ?? .none
        return LoopSummary(id: d.id, title: resolvedTitle(d, members: members, tier: .user), state: d.state, due: d.due,
                           confirmed: !d.suggested, conversationCount: members.count, confirmedCount: confirmed,
                           people: people.sorted(), organisations: orgs.sorted(),
                           lastActivity: convs.compactMap { i.last[$0] }.max(), created: d.created, waitingOn: waiting)
    }

    private func summaries(includeSuggested: Bool, where pred: (LoopSummary) -> Bool = { _ in true }) -> [LoopSummary] {
        let r = loaded(), i = index()
        let by = r.byLoop()
        return r.defs.values.filter { includeSuggested || !$0.suggested }
            .map { summary($0, by[$0.id] ?? [], i) }.filter(pred)
            .sorted { a, b in
                let sa = a.state == .open ? 0 : 1, sb = b.state == .open ? 0 : 1
                if sa != sb { return sa < sb }
                return (a.lastActivity ?? a.created, a.id) > (b.lastActivity ?? b.created, b.id)
            }
    }

    // MARK: LoopSource

    public func loops(includeSuggested: Bool) -> [LoopSummary] { summaries(includeSuggested: includeSuggested) }

    public func loop(id: String) -> LoopSummary? {
        let r = loaded()
        guard let d = r.defs[id] else { return nil }
        return summary(d, r.byLoop()[id] ?? [], index())
    }

    public func confirmedLoop(forConversation cid: String) -> LoopSummary? {
        let r = loaded()
        guard let m = r.members[cid], m.origin.isConfirmed, let d = r.defs[m.loop] else { return nil }
        return summary(d, r.byLoop()[d.id] ?? [], index())
    }

    /// The loop a conversation is in (confirmed or proposed), with its origin.
    public func membership(forConversation cid: String) -> (loopId: String, origin: LoopOrigin)? {
        guard let m = loaded().members[cid] else { return nil }
        return (m.loop, m.origin)
    }

    /// WHEN-HOOK: the loop's member conversation ids (any origin), for work-item suggestions.
    public func conversations(inLoop loopId: String) -> [String] { loaded().members.values.filter { $0.loop == loopId }.map(\.conv).sorted() }

    /// Conversation id → confirmed loop id (one pass; for list-row chips).
    public func confirmedMap() -> [String: String] {
        let r = loaded()
        var out: [String: String] = [:]
        for m in r.members.values where m.origin.isConfirmed && r.defs[m.loop] != nil { out[m.conv] = m.loop }
        return out
    }

    public func loops(withPeople addresses: [String], includeSuggested: Bool) -> [LoopSummary] {
        let set = Set(addresses.map { $0.lowercased() })
        return summaries(includeSuggested: includeSuggested) { !set.isDisjoint(with: $0.people) }
    }

    public func loops(withOrganisation domain: String, includeSuggested: Bool) -> [LoopSummary] {
        let d = domain.lowercased()
        return summaries(includeSuggested: includeSuggested) { $0.organisations.contains(d) }
    }

    // MARK: Proposals

    public func propose(conversationId cid: String) -> LoopProposal {
        let r = loaded(), i = index()
        let by = r.byLoop()
        var p = LoopProposal(conversationId: cid)
        if let m = r.members[cid], m.origin.isConfirmed, let d = r.defs[m.loop] { p.confirmedLoop = summary(d, by[d.id] ?? [], i) }
        var cands: [LoopCandidate] = []
        for d in r.defs.values where d.state == .open && d.id != p.confirmedLoop?.id {
            if r.negatives[d.id + "|" + cid] != nil { continue }
            let others = (by[d.id] ?? []).filter { $0.conv != cid }
            guard let a = Self.evidence(cid, others.map(\.conv), i) else { continue }
            let same = others.contains { $0.origin.isConfirmed && Self.shares(cid, $0.conv, i) && (i.anchors[$0.conv] ?? []).contains(a) }
            let score = Self.weight(a.kind) + (same ? 0.2 : 0) + (d.suggested ? 0 : 0.05)
            cands.append(LoopCandidate(loop: summary(d, by[d.id] ?? [], i),
                                       reason: LoopReason(kind: a.kind, anchorText: a.display, samePeople: same), score: score))
        }
        cands.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return (a.loop.lastActivity ?? a.loop.created, a.loop.id) > (b.loop.lastActivity ?? b.loop.created, b.loop.id)
        }
        p.best = cands.first
        p.alternatives = Array(cands.dropFirst().prefix(2))
        p.newTitle = newTitle(cid)
        lock.withLock { lastBest[cid] = p.best?.loop.id }
        return p
    }

    /// The conversation's stripped subject, only from a message whose text is visible AND may be kept offline (so a
    /// user who just presses return never persists label-gated text as their own title).
    func newTitle(_ cid: String) -> String? {
        let xs = knowledge.conversation(cid, tier: .user).sorted { $0.m.received < $1.m.received }
        for x in xs where knowledge.textVisible(x.m.id, tier: .user) && knowledge.persistable(x.m.id) {
            let s = StoryAnchors.strippedSubject(x.m.subject).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return String(s.prefix(80)) }
        }
        return nil
    }

    /// Signal showed a proposal for this conversation (counted once per conversation per session).
    public func noteProposalShown(_ cid: String) { lock.withLock { _ = shown.insert(cid) } }

    // MARK: Seeding

    /// Knowledge matters → suggested loops. Idempotent; returns how many loops it created.
    @discardableResult
    public func seed(now: Date = Date()) -> Int {
        let i = index()
        _ = loaded()
        let acct = account
        let v = knowledge.view(.user)
        let people = v.people.values.filter { $0.directTo + $0.directFrom > 0 && $0.conversations.count >= 2 }.sorted { $0.key < $1.key }
        var matters: [(KnowledgeMatter, String, Bool)] = []   // matter, anchor hash, title may go to disk
        var seen = Set<String>()
        for p in people {
            for m in KnowledgeAsk.allMatters(for: p, engine: knowledge, tier: .user) {
                if m.anchor.kind == .id, (i.df[m.anchor.key] ?? 0) > 10 { continue }
                let h = anchorHash(m.anchor, account: acct)
                guard seen.insert(h).inserted else { continue }
                let onDisk = m.messageIds.allSatisfy { !knowledge.textVisible($0, tier: .user) || knowledge.persistable($0) }
                matters.append((m, h, onDisk))
            }
        }
        return edit { r, ops in
            var known: [String: String] = [:]   // anchor hash → loop id
            for d in r.defs.values { for h in d.anchors { known[h] = d.id } }
            var created = 0
            for (m, h, onDisk) in matters {
                if let id = known[h] {
                    // Restore a derived title that wasn't allowed on disk.
                    if var d = r.defs[id], !d.titleUser, d.title == nil, d.titleConv != nil { d.title = m.title; r.defs[id] = d }
                    continue
                }
                let convs = m.threads.map(\.id).filter { r.members[$0] == nil && (m.anchor.kind == .id || !i.bulk.contains($0)) }
                guard convs.count >= 2 else { continue }
                let id = UUID().uuidString.lowercased()
                let d = Def(id: id, title: String(m.title.prefix(Self.maxTitle)), titleUser: false,
                            titleConv: m.threads.first { !$0.subject.isEmpty }?.id, titleOnDisk: onDisk, state: .open, due: nil,
                            created: now, updated: now, suggested: true, anchors: [h])
                r.defs[id] = d; ops.append(.putDef(d)); known[h] = id
                for c in convs {
                    let mem = Member(loop: id, conv: c, origin: .proposed(kind: m.anchor.kind, evidence: h), at: now)
                    r.members[c] = mem; ops.append(.putMember(mem))
                }
                created += 1
            }
            return created
        }
    }

    // MARK: Edits (user actions win)

    private func touch(_ r: inout Rows, _ ops: inout [Op], _ id: String, now: Date, _ f: (inout Def) -> Void) {
        guard var d = r.defs[id] else { return }
        f(&d); d.updated = now
        r.defs[id] = d; ops.append(.putDef(d))
    }

    /// "New loop": a confirmed loop with the user's title and these conversations.
    @discardableResult
    public func createLoop(title: String, conversations: [String], due: Date? = nil, now: Date = Date()) -> String {
        let id = UUID().uuidString.lowercased()
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitle))
        edit { r, ops in
            let d = Def(id: id, title: t.isEmpty ? nil : t, titleUser: true, titleConv: nil, titleOnDisk: true, state: .open, due: due,
                        created: now, updated: now, suggested: false, anchors: [])
            r.defs[id] = d; ops.append(.putDef(d))
            for c in conversations { place(&r, &ops, c, id, now: now) }
        }
        return id
    }

    private func place(_ r: inout Rows, _ ops: inout [Op], _ cid: String, _ loop: String, now: Date) {
        let m = Member(loop: loop, conv: cid, origin: .confirmed, at: now)
        r.members[cid] = m; ops.append(.putMember(m))
        if r.negatives.removeValue(forKey: loop + "|" + cid) != nil { ops.append(.deleteNeg(loop, cid)) }
    }

    /// Assign (confirm) a conversation to a loop. Moves it out of any other loop; confirms a suggested loop.
    public func assign(_ cid: String, to loopId: String, now: Date = Date()) {
        let wasBest = lock.withLock { lastBest.removeValue(forKey: cid) == loopId }
        edit { r, ops in
            guard r.defs[loopId] != nil else { return }
            place(&r, &ops, cid, loopId, now: now)
            touch(&r, &ops, loopId, now: now) { $0.suggested = false; if $0.state != .open { $0.state = .open } }
        }
        if wasBest { lock.withLock { acceptedCount += 1 } }
    }

    /// "Not this loop": a negative memory (the same proposal never comes back) and the membership goes.
    public func notThisLoop(_ cid: String, loopId: String, now: Date = Date()) {
        edit { r, ops in
            if r.members[cid]?.loop == loopId { r.members[cid] = nil; ops.append(.deleteMember(cid)) }
            let n = Negative(loop: loopId, conv: cid, at: now)
            r.negatives[loopId + "|" + cid] = n; ops.append(.putNeg(n))
        }
        lock.withLock { if lastBest[cid] == loopId { lastBest[cid] = nil } }
    }

    /// Accept a suggested loop as a whole: it and all its proposed memberships become confirmed.
    public func acceptSuggestion(_ loopId: String, now: Date = Date()) {
        edit { r, ops in
            guard r.defs[loopId] != nil else { return }
            for m in r.members.values where m.loop == loopId && !m.origin.isConfirmed { place(&r, &ops, m.conv, loopId, now: now) }
            touch(&r, &ops, loopId, now: now) { $0.suggested = false }
        }
    }

    public func rename(_ loopId: String, to title: String, now: Date = Date()) {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitle))
        guard !t.isEmpty else { return }
        edit { r, ops in
            // Return on an unchanged derived title is not a rename: it must not turn gated text into a stored user title.
            if let d = r.defs[loopId], !d.titleUser, d.title == t { return }
            touch(&r, &ops, loopId, now: now) { $0.title = t; $0.titleUser = true; $0.titleOnDisk = true; $0.titleConv = nil; $0.suggested = false }
        }
    }

    public func setState(_ loopId: String, _ s: LoopState, now: Date = Date()) {
        edit { r, ops in touch(&r, &ops, loopId, now: now) { $0.state = s } }
    }

    public func setDue(_ loopId: String, _ due: Date?, now: Date = Date()) {
        edit { r, ops in touch(&r, &ops, loopId, now: now) { $0.due = due } }
    }

    /// Merge two loops; the older id survives (same age: the first argument) (members, anchors and "not this loop" memories move to it). A user title
    /// wins over a derived one. Returns the surviving id.
    @discardableResult
    public func merge(_ a: String, _ b: String, now: Date = Date()) -> String? {
        guard a != b else { return a }
        return edit { r, ops -> String? in
            guard let da = r.defs[a], let db = r.defs[b] else { return nil }
            let (keep, gone) = da.created <= db.created ? (da, db) : (db, da)   // older survives; a tie keeps the first
            for m in r.members.values where m.loop == gone.id {
                let moved = Member(loop: keep.id, conv: m.conv, origin: m.origin, at: m.at)
                r.members[m.conv] = moved; ops.append(.putMember(moved))
            }
            for (k, n) in r.negatives where n.loop == gone.id {
                r.negatives[k] = nil; ops.append(.deleteNeg(n.loop, n.conv))
                if r.members[n.conv]?.loop == keep.id { continue }   // a member of the survivor stays one
                let nn = Negative(loop: keep.id, conv: n.conv, at: n.at)
                r.negatives[keep.id + "|" + n.conv] = nn; ops.append(.putNeg(nn))
            }
            r.defs[gone.id] = nil; ops.append(.deleteDef(gone.id))
            touch(&r, &ops, keep.id, now: now) { d in
                d.anchors = Array(Set(d.anchors + gone.anchors)).sorted()
                if !d.titleUser, gone.titleUser { d.title = gone.title; d.titleUser = true; d.titleOnDisk = true; d.titleConv = nil }
                d.suggested = d.suggested && gone.suggested
                if let g = gone.due { d.due = min(d.due ?? g, g) }
            }
            return keep.id
        }
    }

    /// Split: these conversations leave the loop for a new, confirmed loop. Cannot-link both ways ("not this loop"
    /// between the moved conversations and the old loop, and between the remaining ones and the new loop).
    @discardableResult
    public func split(_ loopId: String, conversations: [String], title: String, now: Date = Date()) -> String? {
        let moving = Set(conversations)
        let id = UUID().uuidString.lowercased()
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitle))
        return edit { r, ops -> String? in
            guard r.defs[loopId] != nil else { return nil }
            let members = r.members.values.filter { $0.loop == loopId }
            guard members.contains(where: { moving.contains($0.conv) }) else { return nil }
            let d = Def(id: id, title: t.isEmpty ? nil : t, titleUser: true, titleConv: nil, titleOnDisk: true, state: .open, due: nil,
                        created: now, updated: now, suggested: false, anchors: [])
            r.defs[id] = d; ops.append(.putDef(d))
            for m in members {
                if moving.contains(m.conv) {
                    place(&r, &ops, m.conv, id, now: now)
                    let n = Negative(loop: loopId, conv: m.conv, at: now); r.negatives[loopId + "|" + m.conv] = n; ops.append(.putNeg(n))
                } else {
                    let n = Negative(loop: id, conv: m.conv, at: now); r.negatives[id + "|" + m.conv] = n; ops.append(.putNeg(n))
                }
            }
            touch(&r, &ops, loopId, now: now) { $0.suggested = false }
            return id
        }
    }

    // MARK: Detail (the loop page)

    public func detail(_ id: String, tier: KnowledgeTier = .user, promises: PromiseSource? = nil, now: Date = Date()) -> LoopDetail? {
        let r = loaded(), i = index()
        guard let d = r.defs[id] else { return nil }
        let members = (r.byLoop()[id] ?? []).sorted { (i.last[$0.conv] ?? .distantPast, $0.conv) > (i.last[$1.conv] ?? .distantPast, $1.conv) }
        var s = summary(d, members, i)
        s.title = resolvedTitle(d, members: members, tier: tier)
        let acct = account
        var infos: [LoopMemberInfo] = []
        var threads: [KnowledgeThread] = []
        var ids: [String] = []
        for m in members {
            let xs = knowledge.conversation(m.conv, tier: tier)
            let t = KnowledgeAsk.threadList(xs, engine: knowledge, tier: tier).first
            if let t { threads.append(t); ids += t.messageIds }
            var reason: LoopReason?
            if case .proposed(let kind, let ev) = m.origin {
                let visible = KnowledgeAsk.anchors(xs, engine: knowledge, tier: tier).first { anchorHash($0, account: acct) == ev }
                reason = LoopReason(kind: kind, anchorText: visible?.display, samePeople: false)
            }
            infos.append(LoopMemberInfo(conversationId: m.conv, origin: m.origin, reason: reason, thread: t))
        }
        if case .ai = tier {
            // AI tiers see recipients only where the message content is exposed to them.
            let gate = knowledge.gatePolicy
            let owners = lock.withLock { config.owners }
            var ps = Set<String>()
            for m in members {
                for x in knowledge.conversation(m.conv, tier: tier)
                where KnowledgeEngine.access(x.m, mailbox: x.mailbox, tier: tier, gate: gate).recipients {
                    for e in KnowledgeEngine.addresses(x.m) { let k = e.address.lowercased(); if !owners.contains(k) { ps.insert(k) } }
                }
            }
            s.people = ps.sorted()
            s.organisations = Set(ps.compactMap { MailDomains.companyKey(for: $0) }).sorted()
        }
        let convs = Set(members.map(\.conv))
        let ps = (promises?.promisesDue(before: now.addingTimeInterval(3650 * 86_400)) ?? []).filter { $0.conversationId.map(convs.contains) ?? false }
        return LoopDetail(summary: s, members: infos, files: KnowledgeAsk.files(in: ids, engine: knowledge, tier: tier), promises: ps,
                          timeline: threads.sorted { ($0.last, $0.id) > ($1.last, $1.id) })
    }

    // MARK: Diagnostic (counts only)

    public func diagnostic() -> String {
        let r = loaded()
        let open = r.defs.values.filter { $0.state == .open }.count
        let confirmed = r.defs.values.filter { !$0.suggested }.count
        let suggested = r.defs.values.filter { $0.suggested }.count
        let (s, a) = lock.withLock { (shown.count, acceptedCount) }
        return "[Loops] open=\(open) confirmed=\(confirmed) suggested=\(suggested) proposalsShown=\(s) accepted=\(a)"
    }

    /// Tests: rows in this account's namespace by type (1 loops, 2 memberships, 3 negatives).
    public func debugRowCounts() -> (loops: Int, members: Int, negatives: Int) {
        let acct = account
        func n(_ t: UInt8) -> Int { Int(((try? store.scalarInt("SELECT COUNT(*) FROM loop_row WHERE substr(key,1,5)=?", [.blob(tag(acct) + Data([t]))])) ?? nil) ?? 0) }
        return (n(1), n(2), n(3))
    }
}

extension MailStore {
    /// LOOPS-HOOK: attach (or reconfigure) the loops engine for this store's account, on top of its knowledge engine.
    @discardableResult
    public func enableLoops(_ config: LoopsEngine.Config, knowledge: KnowledgeEngine) -> LoopsEngine {
        locked {
            if let l = loops, l.knowledge === knowledge { l.configure(config); return l }
            let l = LoopsEngine(store: self, indexKey: indexKey, knowledge: knowledge, config: config)
            loops = l
            return l
        }
    }

    /// Tests: a second engine on the same store (fresh memory: reads back from disk; or another account).
    public func makeLoopsEngine(_ config: LoopsEngine.Config, knowledge: KnowledgeEngine) -> LoopsEngine {
        LoopsEngine(store: self, indexKey: indexKey, knowledge: knowledge, config: config)
    }

    /// Tests: sealed payload sizes in `loop_row` (bucket size classes only).
    public func debugLoopPayloadSizes() -> [Int] {
        (try? query("SELECT length(payload) FROM loop_row") { Int(sqlite3_column_int64($0, 0)) }) ?? []
    }
}
