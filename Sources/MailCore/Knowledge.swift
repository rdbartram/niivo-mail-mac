import Foundation
import CryptoKit
import SQLite3
import CalendarCore

// PEOPLE: the local knowledge layer, "Work IQ but local" (docs/INBOX-INTELLIGENCE-PLAN.md §6, Phase 2).
// * One engine per store and account. It reads cached headers in a window (and, for signatures, bodies already in the
//   cache whose on-device exposure is content) into an in-memory snapshot: people (address sets), organisations
//   (registrable domains, free-mail excluded) and per-message evidence. Every piece of evidence keeps its message id.
// * The gate disposes at READ time (§6.5): `view(tier)` re-evaluates every source message through the current label
//   policy. Private / unknown-label / redacted rows contribute nothing (not even counts); metadata-only rows
//   contribute addresses, domains and counts only; text kinds (signature, subject, attachment names, invoice
//   direction) need content on the tier. A person seen only through restricted mail doesn't exist in the view.
// * Sealed tables (`kn_entity`, `kn_fact`; keys = 4-byte account tag + type byte + HMAC, HKDF info "knowledge-v1";
//   payloads padded to a 512-byte bucket). User corrections are facts with source = user and survive rebuilds and
//   `resetHeaders`; derived entities/facts are a cache rewritten after each build. A derived fact whose evidence is
//   text from a message without `allowOfflineDetails` is never written (memory only).
// * Matters are NOT stored: they're grouped at query time from anchors (StoryAnchors.swift, KnowledgeQuery.swift).
// * Logs: counts only (`[Knowledge] people=… orgs=… roles=… matters=…`).

public enum KnowledgeTier: Sendable, Hashable {
    /// The signed-in user's own deterministic answers in the app (no model involved).
    case user
    /// Something an AI tier will see (MCP / in-app agent / summary prompt).
    case ai(AITier)
}

public struct KnowledgeEvidence: Sendable, Hashable, Codable {
    public var kind: KnowledgeEvidenceKind
    /// Source message (nil for directory / user evidence).
    public var messageId: String?
    /// The matched cue word (folded lexicon entry, never mail text).
    public var cue: String?
    public init(kind: KnowledgeEvidenceKind, messageId: String? = nil, cue: String? = nil) { self.kind = kind; self.messageId = messageId; self.cue = cue }
}

public struct KnowledgeRoleFact: Sendable, Hashable {
    public var role: KnowledgeRole
    public var confidence: Double
    public var asserted: Bool
    public var userAsserted: Bool
    public var evidence: [KnowledgeEvidence]
    public var kinds: [KnowledgeEvidenceKind] { Array(Set(evidence.map(\.kind))).sorted { $0.rawValue < $1.rawValue } }
}

public struct KnowledgePerson: Sendable, Hashable, Identifiable {
    public var key: String
    public var name: String
    public var addresses: [String]
    public var org: String?
    public var isInternal: Bool
    public var received = 0
    public var sent = 0
    /// I wrote to them in To / they wrote to me with me in To (visible recipients only).
    public var directTo = 0
    public var directFrom = 0
    public var first: Date?
    public var last: Date?
    public var conversations: Set<String> = []
    /// Visible messages they're part of (from / to / cc), newest first.
    public var messageIds: [String] = []
    public var roles: [KnowledgeRoleFact] = []
    /// A title line / directory title says support staff ("Anwaltsassistentin").
    public var supportStaff = false
    public var id: String { key }
    public var count: Int { received + sent }
    public func role(_ r: KnowledgeRole) -> KnowledgeRoleFact? { roles.first { $0.role == r } }
    /// Best role (user-asserted first, then asserted by confidence).
    public var primaryRole: KnowledgeRoleFact? {
        roles.filter { $0.asserted }.max { ($0.userAsserted ? 2 : 0, $0.confidence) < ($1.userAsserted ? 2 : 0, $1.confidence) }
    }
}

public struct KnowledgeOrg: Sendable, Hashable, Identifiable {
    public var domain: String
    public var name: String
    public var people: [String]
    public var roles: [KnowledgeRole]
    public var count: Int
    public var id: String { domain }
}

/// One tier's view of the knowledge (everything already gated).
public struct KnowledgeView: Sendable {
    public var people: [String: KnowledgePerson] = [:]
    public var orgs: [String: KnowledgeOrg] = [:]
    /// address → person key
    public var byAddress: [String: String] = [:]
    public func person(address: String) -> KnowledgePerson? { byAddress[address.lowercased()].flatMap { people[$0] } }
    public var roleCount: Int { people.values.reduce(0) { $0 + $1.roles.filter(\.asserted).count } }
}

/// A user correction (§6.6). `sameAs` merges two addresses.
public struct KnowledgeUserFact: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case isRole, notRole, sameAs }
    public var kind: Kind
    public var address: String
    public var role: KnowledgeRole?
    public var other: String?
    public var at: Date
    public init(kind: Kind, address: String, role: KnowledgeRole? = nil, other: String? = nil, at: Date = Date()) {
        self.kind = kind; self.address = address.lowercased(); self.role = role; self.other = other?.lowercased(); self.at = at
    }
}

public final class KnowledgeEngine: @unchecked Sendable {
    public struct Config: Sendable {
        public var account: String
        public var owners: Set<String>
        public var internalDomains: Set<String>
        public var gate: AIGatePolicy
        /// Directory facts already in memory (PeopleHub); never fetched for this.
        public var directory: @Sendable (String) -> VoiceDirectoryFacts?
        public var windowDays: Int
        public init(account: String, owners: Set<String>, internalDomains: Set<String> = [], gate: AIGatePolicy,
                    directory: @escaping @Sendable (String) -> VoiceDirectoryFacts? = { _ in nil }, windowDays: Int = 730) {
            self.account = account; self.owners = Set(owners.map { $0.lowercased() }); self.internalDomains = internalDomains
            self.gate = gate; self.directory = directory; self.windowDays = windowDays
        }
    }

    /// One cached header (no body) with what the build derived from it.
    public struct Msg: Sendable {
        public var m: MailMessage
        public var mailbox: String
        public var mine: Bool
        /// Signature roles found in its cached body (memory only).
        var signature: [(KnowledgeRole, String)] = []
        var supportSignature = false
    }

    struct Snapshot {
        var msgs: [String: Msg] = [:]
        var order: [String] = []
        /// person key → addresses (after merging)
        var groups: [String: Set<String>] = [:]
        var byAddress: [String: String] = [:]
        var names: [String: [String: Int]] = [:]
        /// conversation id → message ids, newest first (LOOPS-HOOK)
        var byConv: [String: [String]] = [:]
        var generation = -1
    }

    let store: MailStore
    private let key: SymmetricKey
    private let lock = NSLock()
    private var config: Config
    private var snap = Snapshot()
    private var views: [KnowledgeTier: KnowledgeView] = [:]
    private var dirtyAll = true
    public var account: String { lock.withLock { config.account } }
    public var owners: Set<String> { lock.withLock { config.owners } }

    init(store: MailStore, indexKey: SymmetricKey, config: Config) {
        self.store = store; self.config = config
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: indexKey, salt: Data("compliant-office.mail".utf8), info: Data("knowledge-v1".utf8), outputByteCount: 32)
    }

    public func configure(_ c: Config) { lock.withLock { config = c; views = [:]; dirtyAll = true } }
    /// Labels / policy / tier changed: every view is recomputed (the snapshot keeps its headers).
    public func policyChanged() { lock.withLock { views = [:] } }
    func markAllDirty() { lock.withLock { dirtyAll = true; views = [:] } }
    func wipe() { lock.withLock { snap = Snapshot(); views = [:]; dirtyAll = true } }

    // MARK: Build

    /// Rebuilds the snapshot when the store changed since the last build. Safe off the main thread.
    @discardableResult
    public func refresh(now: Date = Date()) -> Bool {
        let gen = store.locked { store.searchGeneration }
        let (cfg, need) = lock.withLock { (config, dirtyAll || snap.generation != gen) }
        guard need else { return false }
        let s = build(cfg, now: now, generation: gen)
        lock.withLock { snap = s; views = [:]; dirtyAll = false }
        persistDerived()
        return true
    }

    func build(_ cfg: Config, now: Date, generation: Int) -> Snapshot {
        var s = Snapshot(); s.generation = generation
        let cutoff = Int64(now.addingTimeInterval(-Double(cfg.windowDays) * 86_400).timeIntervalSince1970)
        var roles: [String: WellKnownFolder] = [:]
        for f in (try? store.folders()) ?? [] { if let w = f.wellKnown { roles[f.id] = w } }
        let rows: [(MailMessage, String)] = (try? store.query("SELECT payload, mailbox FROM messages WHERE received >= ? ORDER BY received DESC LIMIT 200000",
                                                               [.int(cutoff)]) { st in
            (try store.unseal(MailMessage.self, Self.blob(st, 0)), sqlite3_column_text(st, 1).map { String(cString: $0) } ?? "me")
        }) ?? []
        let owners = cfg.owners
        func isMine(_ m: MailMessage, _ mb: String) -> Bool {
            let f = m.from?.address.lowercased() ?? ""
            return owners.contains(f) || (mb != "me" && f == mb.lowercased()) || roles[m.folderId] == .sentitems
        }
        var od = cfg.gate
        if od.onDeviceAccess == .off { od.onDeviceAccess = .metadataOnly }   // local rules: never text, still metadata
        for (m, mb) in rows where !m.isDraft {
            var x = Msg(m: m, mailbox: mb, mine: isMine(m, mb))
            if !x.mine, od.exposure(m, mailbox: mb, tier: .onDevice) == .content,
               let body = try? store.body(messageId: m.id, touch: false) {
                for line in Self.signatureLines(body, isHTML: m.bodyIsHTML || body.contains("</")) {
                    if KnowledgeLexicon.isSupportTitle(line) { x.supportSignature = true; continue }
                    x.signature += KnowledgeLexicon.rolesInTitle(line)
                }
            }
            s.msgs[m.id] = x
            s.order.append(m.id)
            s.byConv[m.conversationId, default: []].append(m.id)   // LOOPS-HOOK
            for a in Self.addresses(m) where !owners.contains(a.address.lowercased()) {
                let k = a.address.lowercased()
                guard !k.isEmpty else { continue }
                if !a.name.isEmpty, !a.name.contains("@"), !m.isPrivate { s.names[k, default: [:]][a.name, default: 0] += 1 }
                else if s.names[k] == nil { s.names[k] = [:] }
            }
        }
        // Identity: one person per address, merged when the full name matches (≥ 2 words) and the domains agree or
        // one side is free-mail; plus the user's "same person" facts.
        var parent: [String: String] = [:]
        func find(_ a: String) -> String { var x = a; while let p = parent[x], p != x { x = p }; return x }
        func union(_ a: String, _ b: String) { let ra = find(a), rb = find(b); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
        for a in s.names.keys { parent[a] = a }
        var byName: [String: [String]] = [:]
        for (a, ns) in s.names {
            guard let n = ns.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { continue }
            let f = KnowledgeLexicon.words(n).filter { $0.count >= 2 }
            guard f.count >= 2 else { continue }
            byName[f.sorted().joined(separator: " "), default: []].append(a)
        }
        for (_, as_) in byName where as_.count > 1 {
            let sorted = as_.sorted()
            for b in sorted.dropFirst() {
                let ka = MailDomains.companyKey(for: sorted[0]), kb = MailDomains.companyKey(for: b)
                if ka == kb || ka == nil || kb == nil { union(sorted[0], b) }
            }
        }
        for f in userFacts() where f.kind == .sameAs {
            if let o = f.other, parent[f.address] != nil, parent[o] != nil { union(f.address, o) }
        }
        for a in s.names.keys { let r = find(a); s.groups[r, default: []].insert(a); s.byAddress[a] = r }
        return s
    }

    static func addresses(_ m: MailMessage) -> [EmailAddress] { (m.from.map { [$0] } ?? []) + m.toRecipients + m.ccRecipients }

    /// The last lines of the newest (non-quoted) part of a body: where a signature's title line lives.
    public static func signatureLines(_ body: String, isHTML: Bool) -> [String] {
        let text = isHTML ? AIUntrustedText.plainText(fromHTML: body) : body
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if let q = lines.firstIndex(where: { SignatureLearn.isQuoteHeader($0) || $0.hasPrefix(">") }) { lines = Array(lines[..<q]) }
        return Array(lines.filter { !$0.isEmpty }.suffix(8)).filter { $0.count <= 80 }
    }

    static func blob(_ s: OpaquePointer?, _ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(s, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }

    // MARK: Gate (read time)

    struct Access { var meta: Bool; var text: Bool; var recipients: Bool }

    /// §6.5 rules 1–2 for one source message, evaluated now.
    static func access(_ m: MailMessage, mailbox: String, tier: KnowledgeTier, gate: AIGatePolicy) -> Access {
        switch tier {
        case .user:
            let none = Access(meta: false, text: false, recipients: false)
            if m.isPrivate { return none }
            let p = MailContentPolicy.policy(for: m, mailbox: mailbox, engine: gate.engine)
            if p.redactDetails { return none }
            if case .unknown = p.labelState { return none }
            var od = gate
            if od.onDeviceAccess == .off { od.onDeviceAccess = .metadataOnly }
            return Access(meta: true, text: od.exposure(m, mailbox: mailbox, tier: .onDevice) == .content, recipients: true)
        case .ai(let t):
            let ex = gate.exposure(m, mailbox: mailbox, tier: t)
            return Access(meta: ex != .excluded, text: ex == .content, recipients: ex == .content)
        }
    }

    /// May this message's text (subject, attachment names) be shown / used for `tier` right now?
    public func textVisible(_ id: String, tier: KnowledgeTier) -> Bool {
        let (x, gate) = lock.withLock { (snap.msgs[id], config.gate) }
        guard let x else { return false }
        return Self.access(x.m, mailbox: x.mailbox, tier: tier, gate: gate).text
    }

    /// The cached header behind a fact (nil when unknown or not even metadata-visible for `tier`).
    public func message(_ id: String, tier: KnowledgeTier) -> Msg? {
        let (x, gate) = lock.withLock { (snap.msgs[id], config.gate) }
        guard let x, Self.access(x.m, mailbox: x.mailbox, tier: tier, gate: gate).meta else { return nil }
        return x
    }

    /// All visible messages (newest first) for `tier`: the matter grouping input.
    public func messages(tier: KnowledgeTier) -> [Msg] {
        let (s, gate) = lock.withLock { (snap, config.gate) }
        return s.order.compactMap { s.msgs[$0] }.filter { Self.access($0.m, mailbox: $0.mailbox, tier: tier, gate: gate).meta }
    }

    /// LOOPS-HOOK: one conversation's messages visible (metadata) for `tier`, newest first.
    public func conversation(_ cid: String, tier: KnowledgeTier) -> [Msg] {
        let (msgs, gate) = lock.withLock { ((snap.byConv[cid] ?? []).compactMap { snap.msgs[$0] }, config.gate) }
        return msgs.filter { Self.access($0.m, mailbox: $0.mailbox, tier: tier, gate: gate).meta }
    }
    /// LOOPS-HOOK: the store generation the snapshot was built from (-1 before the first build).
    public var snapshotGeneration: Int { lock.withLock { snap.generation } }
    /// LOOPS-HOOK: conversation ids in the snapshot window.
    public var conversationIds: [String] { lock.withLock { Array(snap.byConv.keys) } }

    /// LOOPS-HOOK: the label gate and internal domains the engine runs with (for derived layers on top of it).
    public var gatePolicy: AIGatePolicy { lock.withLock { config.gate } }
    public var internalDomains: Set<String> { lock.withLock { config.internalDomains } }
    /// LOOPS-HOOK: may text derived from this message be written to disk (allowOfflineDetails, not redacted)?
    public func persistable(_ id: String) -> Bool {
        guard let x = lock.withLock({ snap.msgs[id] }) else { return false }
        let pol = store.persistablePolicy(x.m)
        return pol.allowOfflineDetails && !pol.redactDetails
    }

    // MARK: Views

    public func view(_ tier: KnowledgeTier) -> KnowledgeView {
        if let v = lock.withLock({ views[tier] }) { return v }
        let (s, cfg) = lock.withLock { (snap, config) }
        let v = makeView(s, cfg, tier: tier, user: userFacts())
        lock.withLock { if snap.generation == s.generation { views[tier] = v } }
        return v
    }

    static let professional: Set<KnowledgeRole> = [.lawyer, .notary, .architect, .accountant, .taxAdvisor, .doctor]

    func makeView(_ s: Snapshot, _ cfg: Config, tier: KnowledgeTier, user: [KnowledgeUserFact]) -> KnowledgeView {
        var people: [String: KnowledgePerson] = [:]
        var ev: [String: [KnowledgeRole: [KnowledgeEvidence]]] = [:]
        var supportBySig: Set<String> = []
        let owners = cfg.owners
        func person(_ k: String) -> KnowledgePerson {
            if let p = people[k] { return p }
            let addrs = (s.groups[k] ?? [k]).sorted()
            let names = addrs.flatMap { (s.names[$0] ?? [:]).map { ($0.key, $0.value) } }
            let name = Dictionary(names, uniquingKeysWith: +).max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? k
            let org = addrs.lazy.compactMap { MailDomains.companyKey(for: $0) }.first
            return KnowledgePerson(key: k, name: name, addresses: addrs, org: org,
                                   isInternal: addrs.contains { MailDomains.isInternal($0, internalDomains: cfg.internalDomains) })
        }
        func add(_ k: String, _ r: KnowledgeRole, _ e: KnowledgeEvidence) { ev[k, default: [:]][r, default: []].append(e) }
        for id in s.order {
            guard let x = s.msgs[id] else { continue }
            let acc = Self.access(x.m, mailbox: x.mailbox, tier: tier, gate: cfg.gate)
            guard acc.meta else { continue }
            let m = x.m
            let from = m.from?.address.lowercased() ?? ""
            var involved: [(String, Bool)] = []   // (person key, in To)
            if !x.mine, let k = s.byAddress[from] { involved.append((k, false)) }
            if acc.recipients {
                for r in m.toRecipients where !owners.contains(r.address.lowercased()) { if let k = s.byAddress[r.address.lowercased()] { involved.append((k, true)) } }
                for r in m.ccRecipients where !owners.contains(r.address.lowercased()) { if let k = s.byAddress[r.address.lowercased()] { involved.append((k, false)) } }
            }
            let meInTo = m.toRecipients.contains { owners.contains($0.address.lowercased()) }
            for (k, inTo) in involved {
                var p = person(k)
                if p.messageIds.last != id {
                    p.messageIds.append(id)
                    p.conversations.insert(m.conversationId)
                    p.first = min(p.first ?? m.received, m.received); p.last = max(p.last ?? m.received, m.received)
                    if x.mine { p.sent += 1 } else if s.byAddress[from] == k { p.received += 1 }
                    if !x.mine && s.byAddress[from] == k && acc.recipients && meInTo { p.directFrom += 1 }
                }
                if x.mine && inTo { p.directTo += 1 }
                people[k] = p
            }
            // Evidence from this message.
            if !x.mine, let k = s.byAddress[from] {
                if acc.text {
                    for (r, cue) in x.signature { add(k, r, KnowledgeEvidence(kind: .signature, messageId: id, cue: cue)) }
                    if x.supportSignature { supportBySig.insert(k) }
                    for (r, cue) in KnowledgeLexicon.rolesInSubject(m.subject) { add(k, r, KnowledgeEvidence(kind: .subject, messageId: id, cue: cue)) }
                    for a in m.attachments where !a.isInline {
                        for (r, cue) in KnowledgeLexicon.rolesInSubject(a.name) { add(k, r, KnowledgeEvidence(kind: .attachment, messageId: id, cue: cue)) }
                    }
                    if KnowledgeLexicon.isInvoice(m.subject) { add(k, .supplier, KnowledgeEvidence(kind: .invoice, messageId: id, cue: "invoice")) }
                }
                // Organisation name / domain of their own address (metadata).
                if let d = MailDomains.companyKey(for: from) {
                    let orgText = d + " " + (MailDomains.orgName(fromDisplayName: m.from?.name ?? "") ?? "")
                    for (r, cue) in KnowledgeLexicon.rolesInOrg(orgText) { add(k, r, KnowledgeEvidence(kind: .domain, messageId: id, cue: cue)) }
                }
            }
            if x.mine, acc.text, acc.recipients, KnowledgeLexicon.isOffer(m.subject) || KnowledgeLexicon.isInvoice(m.subject) {
                for r in m.toRecipients { if let k = s.byAddress[r.address.lowercased()] { add(k, .customer, KnowledgeEvidence(kind: .invoice, messageId: id, cue: "offer")) } }
            }
        }
        // Directory, internal, user facts, then combine.
        var userBy: [String: [KnowledgeUserFact]] = [:]
        for f in user { if let k = s.byAddress[f.address], people[k] != nil { userBy[k, default: []].append(f) } }
        for (k, var p) in people {
            var dirSupport = false
            for a in p.addresses {
                guard let d = cfg.directory(a), let t = d.title, !t.isEmpty else { continue }
                if KnowledgeLexicon.isSupportTitle(t) { dirSupport = true }
                for (r, cue) in KnowledgeLexicon.rolesInTitle(t) { add(k, r, KnowledgeEvidence(kind: .directory, cue: cue)) }
            }
            if p.isInternal { add(k, .colleague, KnowledgeEvidence(kind: .directory, cue: "internal")) }
            p.supportStaff = dirSupport || supportBySig.contains(k)
            var facts: [KnowledgeRoleFact] = []
            for (r, es) in ev[k] ?? [:] {
                // Support staff at a firm: the firm's domain / subjects don't make them the professional (§6.2).
                let use = p.supportStaff && Self.professional.contains(r) ? es.filter { $0.kind == .directory || $0.kind == .signature } : es
                guard !use.isEmpty else { continue }
                let kinds = Dictionary(use.map { ($0.kind, 1) }, uniquingKeysWith: +)
                facts.append(KnowledgeRoleFact(role: r, confidence: KnowledgeScore.combine(kinds), asserted: KnowledgeScore.isAsserted(kinds),
                                               userAsserted: false, evidence: use))
            }
            for f in (userBy[k] ?? []).sorted(by: { $0.at < $1.at }) {
                guard let r = f.role else { continue }
                facts.removeAll { $0.role == r }   // `.notRole`: gone (−∞) until the user says otherwise
                if f.kind == .isRole {
                    facts.append(KnowledgeRoleFact(role: r, confidence: 1, asserted: true, userAsserted: true, evidence: [KnowledgeEvidence(kind: .user)]))
                }
            }
            p.roles = facts.sorted { ($0.confidence, $1.role) > ($1.confidence, $0.role) }
            people[k] = p
        }
        var orgs: [String: KnowledgeOrg] = [:]
        for p in people.values {
            guard let d = p.org else { continue }
            var o = orgs[d] ?? KnowledgeOrg(domain: d, name: MailDomains.name(fromDomain: d), people: [],
                                            roles: KnowledgeLexicon.rolesInOrg(d).map(\.0), count: 0)
            o.people.append(p.key); o.count += p.count
            orgs[d] = o
        }
        var byAddress: [String: String] = [:]
        for p in people.values { for a in p.addresses { byAddress[a] = p.key } }
        return KnowledgeView(people: people, orgs: orgs, byAddress: byAddress)
    }

    // MARK: Corrections (§6.6)

    public func setRole(_ role: KnowledgeRole, for address: String, isRole: Bool, now: Date = Date()) {
        let f = KnowledgeUserFact(kind: isRole ? .isRole : .notRole, address: address, role: role, at: now)
        put(userKey("r|\(f.address)|\(role.id)"), f)
        lock.withLock { views = [:] }
    }

    public func clearRole(_ role: KnowledgeRole, for address: String) {
        try? store.run("DELETE FROM kn_fact WHERE key=?", [.blob(userKey("r|\(address.lowercased())|\(role.id)"))])
        lock.withLock { views = [:] }
    }

    public func setSamePerson(_ a: String, _ b: String, now: Date = Date()) {
        let f = KnowledgeUserFact(kind: .sameAs, address: a, other: b, at: now)
        put(userKey("s|\(f.address)|\(f.other ?? "")"), f)
        lock.withLock { dirtyAll = true; views = [:] }
    }

    public func userFacts() -> [KnowledgeUserFact] { all(type: 2) }

    // PEOPLE2-HOOK: the People surface's empty-state reason needs "seen in the window at all" (any label) apart from
    // "visible in the user view", and the look-back window for "client since".
    public func knows(address: String) -> Bool { lock.withLock { snap.byAddress[address.lowercased()] != nil } }
    public var windowDays: Int { lock.withLock { config.windowDays } }
    /// Has a build run since this engine was made (false = the snapshot is still empty).
    public var isBuilt: Bool { lock.withLock { snap.generation >= 0 } }

    // NOTES-HOOK: sealed per-account index of OneNote notes logged from a person page (PeopleNotes.swift). Page id,
    // address, title, time and links only; the note text stays in OneNote.
    public func putNote(_ r: PeopleNoteRecord) {
        put(tag() + Data([3]) + Data(HMAC<SHA256>.authenticationCode(for: Data("n|\(account)|\(r.pageId)".utf8), using: key).prefix(16)), r)
    }
    public func notes(address: String? = nil) -> [PeopleNoteRecord] {
        let rows: [PeopleNoteRecord] = all(type: 3)
        guard let a = address?.lowercased() else { return rows }
        return rows.filter { $0.address == a }
    }

    // MARK: Sealed rows

    private func tag() -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data("a|\(account)".utf8), using: key).prefix(4)) }
    private func userKey(_ s: String) -> Data {
        tag() + Data([2]) + Data(HMAC<SHA256>.authenticationCode(for: Data("u|\(account)|\(s)".utf8), using: key).prefix(16))
    }
    private func derivedKey(_ table: String, _ s: String) -> Data {
        tag() + Data([1]) + Data(HMAC<SHA256>.authenticationCode(for: Data("\(table)|\(account)|\(s)".utf8), using: key).prefix(16))
    }

    static let bucket = 512
    private func put<T: Encodable>(_ k: Data, _ v: T, table: String = "kn_fact") {
        guard var d = try? JSONEncoder().encode(v) else { return }
        d.append(Data(repeating: 0x20, count: ((d.count / Self.bucket) + 1) * Self.bucket - d.count))
        guard let sealed = try? store.sealData(d) else { return }
        try? store.run("INSERT OR REPLACE INTO \(table)(key,payload) VALUES(?,?)", [.blob(k), .blob(sealed)])
    }

    private func all<T: Decodable>(type: UInt8, table: String = "kn_fact") -> [T] {
        let prefix = tag() + Data([type])
        let rows = ((try? store.query("SELECT payload FROM \(table) WHERE substr(key,1,5)=?", [.blob(prefix)]) { s in Self.blob(s, 0) }) ?? [])
        return rows.compactMap { d in (try? store.openData(d)).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    }

    struct StoredPerson: Codable { var addresses: [String]; var name: String; var org: String?; var received: Int; var sent: Int; var first: Date?; var last: Date? }
    struct StoredRole: Codable { var person: String; var role: String; var confidence: Double; var asserted: Bool; var evidence: [KnowledgeEvidence] }

    /// The derived cache (user tier): entities always (metadata); a role fact only if every text-derived evidence
    /// item comes from a message that may keep offline details (§6.5 rule 3). Others stay in memory.
    func persistDerived() {
        let v = view(.user)
        let prefix = tag() + Data([1])
        try? store.run("DELETE FROM kn_entity WHERE substr(key,1,5)=?", [.blob(prefix)])
        try? store.run("DELETE FROM kn_fact WHERE substr(key,1,5)=?", [.blob(prefix)])
        for p in v.people.values {
            put(derivedKey("p", p.key), StoredPerson(addresses: p.addresses, name: p.name, org: p.org, received: p.received, sent: p.sent,
                                                    first: p.first, last: p.last), table: "kn_entity")
            for r in p.roles where !r.userAsserted {
                let ok = r.evidence.allSatisfy { e in
                    guard e.kind.requires == .content, let id = e.messageId else { return true }
                    guard let x = lock.withLock({ snap.msgs[id] }) else { return false }
                    let pol = store.persistablePolicy(x.m)
                    return pol.allowOfflineDetails && !pol.redactDetails
                }
                guard ok else { continue }
                put(derivedKey("r", p.key + "|" + r.role.id), StoredRole(person: p.key, role: r.role.id, confidence: r.confidence,
                                                                         asserted: r.asserted, evidence: r.evidence))
            }
        }
    }

    /// Tests / diagnostics: rows in this account's namespace.
    public func debugPersisted() -> (entities: Int, derivedFacts: Int, userFacts: Int) {
        func n(_ t: String, _ type: UInt8) -> Int {
            Int(((try? store.scalarInt("SELECT COUNT(*) FROM \(t) WHERE substr(key,1,5)=?", [.blob(tag() + Data([type]))])) ?? nil) ?? 0)
        }
        return (n("kn_entity", 1), n("kn_fact", 1), n("kn_fact", 2))
    }

    /// Tests: persisted derived "personKey|role" pairs (what reached the disk).
    public func debugPersistedRoles() -> [String] {
        let rows: [StoredRole] = all(type: 1)
        return rows.map { $0.person + "|" + $0.role }.sorted()
    }
}

extension MailStore {
    /// PEOPLE-HOOK: attach (or reconfigure) the knowledge engine for this store's account.
    @discardableResult
    public func enableKnowledge(_ config: KnowledgeEngine.Config) -> KnowledgeEngine {
        locked {
            if let k = knowledge { k.configure(config); return k }
            let k = KnowledgeEngine(store: self, indexKey: indexKey, config: config)
            knowledge = k
            return k
        }
    }

    /// Tests: sealed payload sizes in the knowledge tables (one bucket size class).
    public func debugKnowledgePayloadSizes() -> [Int] {
        ["kn_entity", "kn_fact"].flatMap { t in (try? query("SELECT length(payload) FROM \(t)") { Int(sqlite3_column_int64($0, 0)) }) ?? [] }
    }

    /// Tests: a second engine on the same store under another account (per-account isolation).
    public func makeKnowledgeEngine(_ config: KnowledgeEngine.Config) -> KnowledgeEngine {
        KnowledgeEngine(store: self, indexKey: indexKey, config: config)
    }
}
