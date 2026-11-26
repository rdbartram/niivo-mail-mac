import Foundation
import CryptoKit
import SQLite3
import CalendarCore

/// Local, encrypted, incrementally maintained communication graph over the mail cache.
///
/// * Lives in the MailStore's SQLite file, table `g_node(k, kind, payload)`: `k` is a truncated HMAC of
///   (kind, natural key) under a key derived from the blind-index key, `payload` is the AES-GCM sealed node
///   (JSON). Adjacency (person↔person) is inside the sealed person payload, so no edge rows reveal topology.
/// * Fed by the store's write paths (`upsert`, `deleteMessages`, `prune`, `replace`, `moveAll`, `wipe`) with
///   the message AFTER the persist rule (`MailContentPolicy.sanitizeForCache`): recipients of protected /
///   unknown-label mail are never on disk, so they never reach the graph either. Metadata only (from, to, cc,
///   date, conversation, folder, categories, subject terms); no body or preview is read.
/// * Every write is a diff (old row → new row), so read/flag/move re-upserts don't double count.
/// * The graph is NOT an AI gate. Tools only use it to propose candidates and recompute every number they return
///   from messages that passed the AI gate (see OfficeTools/GraphTools.swift).
public final class CommGraph: @unchecked Sendable {
    public static let version = "1"
    static let neighbourCap = 200
    static let peopleCap = 500
    static let projectPeopleCap = 200
    static let recentCap = 200
    static let projectCapPerPerson = 40
    static let smallMessage = 8

    unowned let store: MailStore
    let key: SymmetricKey
    /// Lower-cased addresses of the mailbox owner(s) (signed-in user, shared mailboxes).
    public private(set) var owners: Set<String>
    public private(set) var internalDomains: Set<String>
    private var folders: [String: MailFolder] = [:]
    private var batch = Batch()
    private var generation = 0

    public static func deriveKey(fromIndexKey k: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: Data("compliant-office.mail".utf8),
                               info: Data("comm-graph-v1".utf8), outputByteCount: 32)
    }

    init(store: MailStore, indexKey: SymmetricKey, owners: Set<String>, internalDomains: Set<String>) {
        self.store = store
        self.key = Self.deriveKey(fromIndexKey: indexKey)
        self.owners = Set(owners.map { $0.lowercased() })
        self.internalDomains = Set(internalDomains.map { $0.lowercased() })
    }

    func setOwners(_ o: Set<String>, internalDomains d: Set<String>) {
        owners = Set(o.map { $0.lowercased() }); internalDomains = Set(d.map { $0.lowercased() })
    }

    // MARK: Keys

    func nodeKey(_ kind: GraphNodeKind, _ id: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("\(kind.rawValue):\(id)".utf8), using: key).prefix(16))
    }

    // MARK: Contributions

    /// What one cached message contributes. nil → not counted (drafts, junk, deleted items, outbox).
    struct Contribution: Equatable {
        var mailbox: String
        var ownerSent: Bool
        var from: EmailAddress?
        var recipients: [EmailAddress]
        var ts: Int64
        var conversation: String
        var categories: [String]
        var folder: String?
        var terms: [String]
        var bulk: Bool
    }

    func folderChanged(_ f: MailFolder) { folders[f.id] = f }
    func folderInfo(_ id: String) -> MailFolder? {
        if let f = folders[id] { return f }
        if folders.isEmpty { for f in (try? store.folders()) ?? [] { folders[f.id] = f } }
        return folders[id]
    }

    func contribution(_ m: MailMessage, mailbox: String) -> Contribution? {
        let f = folderInfo(m.folderId)
        if m.isDraft { return nil }
        if let wk = f?.wellKnown, [.drafts, .junkemail, .deleteditems, .outbox].contains(wk) { return nil }
        let from = m.from.map { EmailAddress(name: $0.name, address: $0.address.lowercased()) }
        let fromAddr = from?.address ?? ""
        let ownerSent = f?.wellKnown == .sentitems || owners.contains(fromAddr) || (mailbox != "me" && fromAddr == mailbox.lowercased())
        var seen = Set<String>(), rec: [EmailAddress] = []
        for r in m.toRecipients + m.ccRecipients {
            let a = r.address.lowercased()
            guard !a.isEmpty, seen.insert(a).inserted else { continue }
            rec.append(EmailAddress(name: r.name, address: a))
        }
        let bucket = SplitInbox.bucket(for: m)
        return Contribution(mailbox: mailbox, ownerSent: ownerSent, from: from, recipients: rec,
                            ts: Int64(m.received.timeIntervalSince1970), conversation: m.conversationId,
                            categories: Array(Set(m.categories.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted(),
                            folder: (f != nil && f?.wellKnown == nil) ? m.folderId : nil,
                            terms: SubjectTerms.terms(m.subject),
                            bulk: !ownerSent && (bucket == .newsletters || bucket == .notifications))
    }

    public func isOwner(_ a: String, mailbox: String) -> Bool { owners.contains(a) || (mailbox != "me" && a == mailbox.lowercased()) }

    /// Diff one row (inside the store's transaction).
    func change(old: MailMessage?, new: MailMessage?, oldMailbox: String, newMailbox: String) {
        let o = old.flatMap { contribution($0, mailbox: oldMailbox) }
        let n = new.flatMap { contribution($0, mailbox: newMailbox) }
        if o == n { return }
        if let o { apply(o, sign: -1) }
        if let n { apply(n, sign: 1) }
    }

    private func apply(_ c: Contribution, sign: Int) {
        var meta = batch.meta(self)
        meta.messages = max(0, meta.messages + sign)

        // Conversation (its terms are fixed by the first message seen).
        var conv = batch.conv(self, c.conversation) ?? ConversationNode(id: c.conversation, mailbox: c.mailbox)
        let firstInConv = conv.messages.n == 0
        conv.messages.add(c.ts, sign: sign)
        let participants = participantsOf(c)
        for p in participants { conv.people.bump(p, sign, cap: 30) }
        var newProjects: Set<String> = [], goneProjects: Set<String> = []
        func track(_ dict: inout [String: Int], _ k: String) {
            let before = dict[k] ?? 0
            dict.bump(k, sign, cap: 20)
            let after = dict[k] ?? 0
            if before == 0 && after > 0 { newProjects.insert(k) } else if before > 0 && after == 0 { goneProjects.insert(k) }
        }
        let projectIds = c.categories.map { "cat:" + $0.lowercased() } + (c.folder.map { ["fld:" + $0] } ?? [])
        for pid in projectIds { if pid.hasPrefix("cat:") { track(&conv.categories, pid) } else { track(&conv.folders, pid) } }
        if sign > 0 && firstInConv {
            conv.terms = c.terms
            meta.conversations += 1
            for t in c.terms {
                var tn = batch.term(self, t) ?? TermNode(term: t)
                tn.conversations += 1
                tn.last = max(tn.last, c.ts)
                for o in c.terms where o != t { tn.co.bump(o, 1, cap: 12) }
                batch.put(term: tn, self)
            }
        }
        let convTerms = conv.terms
        if sign < 0 && conv.messages.n == 0 {
            meta.conversations = max(0, meta.conversations - 1)
            for t in conv.terms {
                guard var tn = batch.term(self, t) else { continue }
                tn.conversations -= 1
                for o in conv.terms where o != t { tn.co.bump(o, -1, cap: 12) }
                batch.put(term: tn, self)
            }
            batch.remove(conv: c.conversation, self)
        } else {
            batch.put(conv: conv, self)
        }
        batch.put(meta: meta, self)

        // Projects (category / folder): incrementally maintained nodes.
        let companies = Set(participants.compactMap { MailDomains.companyKey(for: $0) })
        for pid in projectIds {
            var p = batch.project(self, pid) ?? ProjectNode(id: pid, kind: pid.hasPrefix("cat:") ? .category : .folder,
                                                            name: projectName(pid, c: c))
            p.messages.add(c.ts, sign: sign)
            if newProjects.contains(pid) { p.conversations += 1; p.recent.removeAll { $0 == c.conversation }; p.recent.insert(c.conversation, at: 0) }
            if goneProjects.contains(pid) { p.conversations = max(0, p.conversations - 1); p.recent.removeAll { $0 == c.conversation } }
            if sign > 0, let i = p.recent.firstIndex(of: c.conversation), i > 0 { p.recent.remove(at: i); p.recent.insert(c.conversation, at: 0) }
            if p.recent.count > Self.recentCap { p.recent.removeLast(p.recent.count - Self.recentCap) }
            for a in participants { p.people.bump(a, sign, cap: Self.projectPeopleCap) }
            for d in companies { p.companies.bump(d, sign, cap: 100) }
            p.mailboxes.bump(c.mailbox, sign, cap: 20)
            if p.messages.n == 0 { batch.remove(project: pid, self) } else { batch.put(project: p, self) }
        }
        // Topic ids are attached to people/companies (the term node is the topic).
        let personProjects = projectIds + convTerms.map { "t:" + $0 }

        // People + companies.
        if c.bulk {
            if let f = c.from {
                var p = batch.person(self, f.address) ?? PersonNode(address: f.address)
                p.bulk = max(0, p.bulk + sign)
                bumpName(&p, f.name, sign)
                p.mailboxes.bump(c.mailbox, sign, cap: 20)
                batch.put(person: p, self)
            }
            return
        }
        func touch(_ a: EmailAddress, them: Bool) {
            var p = batch.person(self, a.address) ?? PersonNode(address: a.address)
            if them { p.fromThem.add(c.ts, sign: sign) } else { p.toThem.add(c.ts, sign: sign) }
            bumpName(&p, a.name, sign)
            p.isInternal = MailDomains.isInternal(a.address, internalDomains: internalDomains)
            p.company = MailDomains.companyKey(for: a.address)
            p.mailboxes.bump(c.mailbox, sign, cap: 20)
            for pid in personProjects { p.projects.bump(pid, sign, cap: Self.projectCapPerPerson) }
            batch.put(person: p, self)
            guard let d = p.company else { return }
            var co = batch.company(self, d) ?? CompanyNode(domain: d)
            if them { co.fromThem.add(c.ts, sign: sign) } else { co.toThem.add(c.ts, sign: sign) }
            co.people.bump(a.address, sign, cap: Self.peopleCap)
            co.isInternal = p.isInternal
            if let org = MailDomains.orgName(fromDisplayName: a.name) { co.names.bump(org, sign, cap: 8) }
            for pid in personProjects { co.projects.bump(pid, sign, cap: Self.projectCapPerPerson) }
            if co.total.n == 0 { batch.remove(company: d, self) } else { batch.put(company: co, self) }
        }
        if c.ownerSent {
            for r in c.recipients where !isOwner(r.address, mailbox: c.mailbox) { touch(r, them: false) }
        } else if let f = c.from, !f.address.isEmpty, !isOwner(f.address, mailbox: c.mailbox) {
            touch(f, them: true)
        }
        // Person ↔ person co-communication.
        let ps = participants
        if ps.count <= Self.smallMessage {
            for i in ps.indices { for j in ps.indices where j != i { link(ps[i], ps[j], c.ts, sign) } }
        } else if let f = c.from?.address, !isOwner(f, mailbox: c.mailbox) {
            for r in c.recipients.prefix(20) where !isOwner(r.address, mailbox: c.mailbox) && r.address != f {
                link(f, r.address, c.ts, sign); link(r.address, f, c.ts, sign)
            }
        }
        // Names for people seen only as cc / co-recipients (display hint; counts come from the tallies).
        if sign > 0 {
            for a in [c.from].compactMap({ $0 }) + c.recipients where participants.contains(a.address) && !a.name.isEmpty {
                if var p = batch.person(self, a.address), p.names.isEmpty { bumpName(&p, a.name, 1); batch.put(person: p, self) }
            }
        }
    }

    private func participantsOf(_ c: Contribution) -> [String] {
        if c.bulk { return [] }
        var out: [String] = [], seen = Set<String>()
        for a in [c.from?.address].compactMap({ $0 }) + c.recipients.map(\.address)
        where !a.isEmpty && !isOwner(a, mailbox: c.mailbox) && seen.insert(a).inserted { out.append(a) }
        return out
    }

    private func link(_ a: String, _ b: String, _ ts: Int64, _ sign: Int) {
        var p = batch.person(self, a) ?? PersonNode(address: a)
        if p.company == nil { p.company = MailDomains.companyKey(for: a) }
        p.isInternal = MailDomains.isInternal(a, internalDomains: internalDomains)
        var t = p.neighbours[b] ?? Tally()
        t.add(ts, sign: sign)
        if t.isEmpty { p.neighbours.removeValue(forKey: b) } else { p.neighbours[b] = t }
        if p.neighbours.count > Self.neighbourCap,
           let victim = p.neighbours.min(by: { $0.value.weight(at: ts) < $1.value.weight(at: ts) })?.key, victim != b {
            p.neighbours.removeValue(forKey: victim)
        }
        batch.put(person: p, self)
    }

    private func bumpName(_ p: inout PersonNode, _ name: String, _ sign: Int) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.lowercased() != p.address else { return }
        p.names.bump(n, sign, cap: 5)
    }

    private func projectName(_ pid: String, c: Contribution) -> String {
        if pid.hasPrefix("cat:") { return c.categories.first { "cat:" + $0.lowercased() == pid } ?? String(pid.dropFirst(4)) }
        return folderInfo(String(pid.dropFirst(4)))?.displayName ?? "Folder"
    }

    // MARK: Batch flush (end of each store write, inside its transaction)

    func flush() throws {
        guard batch.dirty else { return }
        let stmt = try store.prepare("INSERT INTO g_node(k,kind,payload) VALUES(?,?,?) ON CONFLICT(k) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(stmt) }
        let del = try store.prepare("DELETE FROM g_node WHERE k=?"); defer { sqlite3_finalize(del) }
        for (k, entry) in batch.entries {
            if entry.kind == .person, entry.state != .clean { egoCache.removeValue(forKey: k) }
            switch entry.state {
            case .clean: continue
            case .deleted: try store.bindAndStep(del, [.blob(k)])
            case .dirty: try store.bindAndStep(stmt, [.blob(k), .int(Int64(entry.kind.rawValue)), .blob(try entry.seal(store))])
            }
        }
        batch = Batch()
        generation += 1
    }

    func discardBatch() { batch = Batch() }
    func wipe() { batch = Batch(); folders = [:]; egoCache = [:]; generation += 1 }
    /// person key → me↔X tally (decoding a person node is the costly part of ranking; this survives writes that
    /// don't touch that person).
    private var egoCache: [Data: Tally] = [:]

    // MARK: Reads

    func load<T: Decodable>(_ t: T.Type, _ k: Data) -> T? {
        guard let d = try? store.query("SELECT payload FROM g_node WHERE k=?", [.blob(k)], { s in storeBlob(s, 0) }).first else { return nil }
        return try? store.unseal(t, d)
    }

    public func person(_ address: String) -> PersonNode? { load(PersonNode.self, nodeKey(.person, address.lowercased())) }
    public func company(_ domain: String) -> CompanyNode? { load(CompanyNode.self, nodeKey(.company, domain.lowercased())) }
    public func project(_ id: String) -> ProjectNode? { load(ProjectNode.self, nodeKey(.project, id)) }
    public func conversation(_ id: String) -> ConversationNode? { load(ConversationNode.self, nodeKey(.conversation, id)) }
    public func term(_ t: String) -> TermNode? { load(TermNode.self, nodeKey(.term, t)) }
    public var meta: GraphMeta { load(GraphMeta.self, nodeKey(.meta, "meta")) ?? GraphMeta() }
    public var nodeCount: Int { Int((try? store.scalarInt("SELECT COUNT(*) FROM g_node")) ?? 0 ?? 0) }

    /// All nodes of one kind (decrypts each). Bounded by the cache contents; cached until the next write.
    func all<T: Decodable>(_ kind: GraphNodeKind, _ t: T.Type) -> [T] {
        let rows = (try? store.query("SELECT payload FROM g_node WHERE kind=?", [.int(Int64(kind.rawValue))], { s in storeBlob(s, 0) })) ?? []
        return rows.compactMap { try? store.unseal(t, $0) }
    }

    private var peopleCache: (Int, [PersonNode])?
    private var companyCache: (Int, [CompanyNode])?
    private var projectCache: (Int, [ProjectNode])?
    private var termCache: (Int, [TermNode])?

    public func people() -> [PersonNode] {
        store.locked {
            if let c = peopleCache, c.0 == generation { return c.1 }
            let v = all(.person, PersonNode.self); peopleCache = (generation, v); return v
        }
    }
    public func companies() -> [CompanyNode] {
        store.locked {
            if let c = companyCache, c.0 == generation { return c.1 }
            let v = all(.company, CompanyNode.self); companyCache = (generation, v); return v
        }
    }
    /// Category and folder projects.
    public func projectNodes() -> [ProjectNode] {
        store.locked {
            if let c = projectCache, c.0 == generation { return c.1 }
            let v = all(.project, ProjectNode.self); projectCache = (generation, v); return v
        }
    }
    func terms() -> [TermNode] {
        store.locked {
            if let c = termCache, c.0 == generation { return c.1 }
            let v = all(.term, TermNode.self); termCache = (generation, v); return v
        }
    }

    /// Recurring subject terms that make a topic: in ≥ 3 conversations, but not in more than 3 % of them (or 30).
    public func isTopic(_ t: TermNode, meta m: GraphMeta? = nil) -> Bool {
        let total = (m ?? meta).conversations
        return t.conversations >= 3 && Double(t.conversations) <= max(30, Double(total) * 0.03)
    }

    /// Topic clusters: a topic term plus its strongest co-term (≥ 50 % of its conversations) → "budget · forecast".
    /// Fallback name only: on-device naming of clusters isn't built (the model reports modelNotReady on this Mac).
    public func topics(limit: Int = 50) -> [GraphProject] {
        let m = meta
        let ts = terms().filter { isTopic($0, meta: m) }
        var out: [GraphProject] = [], used = Set<String>()
        for t in ts.sorted(by: { ($0.conversations, $0.last, $0.term) > ($1.conversations, $1.last, $1.term) }) where !used.contains(t.term) {
            used.insert(t.term)
            var name = t.term
            if let best = t.co.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), Double(best.value) >= Double(t.conversations) * 0.5,
               !used.contains(best.key) {
                name += " · " + best.key; used.insert(best.key)
            }
            out.append(GraphProject(id: "t:" + t.term, kind: .topic, name: name, conversations: t.conversations,
                                    lastActivity: Date(timeIntervalSince1970: Double(t.last))))
            if out.count == limit { break }
        }
        return out
    }

    func listed(_ p: ProjectNode) -> GraphProject {
        GraphProject(id: p.id, kind: p.kind, name: p.name, conversations: p.conversations,
                     lastActivity: Date(timeIntervalSince1970: Double(p.messages.last)))
    }

    /// Category + folder projects and topics, newest activity first.
    public func projects(limit: Int = 100) -> [GraphProject] {
        Array((projectNodes().map(listed) + topics(limit: limit)).sorted { $0.lastActivity > $1.lastActivity }.prefix(limit))
    }

    /// Resolve a user-typed project: id ("cat:x", "fld:id", "t:term"), category or folder name, or a topic term.
    public func resolveProject(_ q: String) -> [GraphProject] {
        let s = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return [] }
        let nodes = projectNodes()
        if let exact = nodes.first(where: { $0.id == q || $0.id.lowercased() == s }) { return [listed(exact)] }
        var out = nodes.filter { $0.name.lowercased() == s }.map(listed)
        if out.isEmpty { out = nodes.filter { $0.name.lowercased().contains(s) }.map(listed) }
        let term = s.hasPrefix("t:") ? String(s.dropFirst(2)) : (BlindIndex.tokenize(s).first ?? s)
        if let t = self.term(term), t.conversations > 0 {
            out.append(GraphProject(id: "t:" + t.term, kind: .topic, name: projectName("t:" + t.term), conversations: t.conversations,
                                    lastActivity: Date(timeIntervalSince1970: Double(t.last))))
        }
        return out
    }

    /// Resolve a company by domain, address or organisation name.
    public func resolveCompany(_ q: String) -> [CompanyNode] {
        let s = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return [] }
        if s.contains("@") { return MailDomains.companyKey(for: s).flatMap { company($0) }.map { [$0] } ?? [] }
        if s.contains("."), let c = company(MailDomains.registrable(s)) { return [c] }
        return companies().filter { c in
            c.domain.hasPrefix(s) || c.displayName.lowercased().contains(s) || c.names.keys.contains { $0.lowercased().contains(s) }
        }.sorted { ($0.total.n, $0.domain) > ($1.total.n, $1.domain) }
    }

    /// 0…1: how close a correspondent is to the owner (decayed message weight, both directions).
    public func proximity(_ address: String, now: Date = Date()) -> Double {
        let k = nodeKey(.person, address.lowercased())
        let t: Tally = store.locked {
            if let t = egoCache[k] { return t }
            let t = load(PersonNode.self, k)?.total ?? Tally()
            if egoCache.count > 50_000 { egoCache = [:] }
            egoCache[k] = t
            return t
        }
        return 1 - exp(-t.weight(at: Int64(now.timeIntervalSince1970)) / 4)
    }

    /// Strongest co-correspondents of a person.
    public func neighbours(of address: String, limit: Int = 10, now: Date = Date()) -> [(address: String, weight: Double, count: Int)] {
        guard let p = person(address) else { return [] }
        let t = Int64(now.timeIntervalSince1970)
        return Array(p.neighbours.map { ($0.key, $0.value.weight(at: t), $0.value.n) }
            .sorted { ($0.1, $0.2, $0.0) > ($1.1, $1.2, $1.0) }.prefix(limit)).map { (address: $0.0, weight: $0.1, count: $0.2) }
    }

    /// Projects of a conversation: its categories, user folders and topic terms.
    public func projectIds(conversation id: String) -> [String] {
        guard let c = conversation(id) else { return [] }
        let m = meta
        let topics = c.terms.compactMap { t -> String? in term(t).flatMap { isTopic($0, meta: m) ? "t:" + $0.term : nil } }
        return Array(c.categories.keys).sorted() + Array(c.folders.keys).sorted() + topics
    }

    public func projectName(_ id: String) -> String {
        if id.hasPrefix("t:") { return topics(limit: 1_000).first { $0.id == id }?.name ?? String(id.dropFirst(2)) }
        return project(id)?.name ?? id
    }

    // MARK: Batch

    struct Batch {
        enum State { case clean, dirty, deleted }
        struct Entry {
            var kind: GraphNodeKind
            var value: Any?
            var state: State
            func seal(_ s: MailStore) throws -> Data {
                switch value {
                case let v as PersonNode: return try s.seal(v)
                case let v as CompanyNode: return try s.seal(v)
                case let v as ProjectNode: return try s.seal(v)
                case let v as ConversationNode: return try s.seal(v)
                case let v as TermNode: return try s.seal(v)
                case let v as GraphMeta: return try s.seal(v)
                default: throw StoreError.sqlite("graph: unknown node")
                }
            }
        }
        var entries: [Data: Entry] = [:]
        var dirty = false

        mutating func get<T: Decodable>(_ g: CommGraph, _ kind: GraphNodeKind, _ id: String, _ t: T.Type) -> T? {
            let k = g.nodeKey(kind, id)
            if let e = entries[k] { return e.state == .deleted ? nil : e.value as? T }
            let v = g.load(t, k)
            entries[k] = Entry(kind: kind, value: v, state: .clean)
            return v
        }
        mutating func set(_ g: CommGraph, _ kind: GraphNodeKind, _ id: String, _ v: Any) {
            entries[g.nodeKey(kind, id)] = Entry(kind: kind, value: v, state: .dirty); dirty = true
        }
        mutating func del(_ g: CommGraph, _ kind: GraphNodeKind, _ id: String) {
            entries[g.nodeKey(kind, id)] = Entry(kind: kind, value: nil, state: .deleted); dirty = true
        }

        mutating func meta(_ g: CommGraph) -> GraphMeta { get(g, .meta, "meta", GraphMeta.self) ?? GraphMeta() }
        mutating func put(meta: GraphMeta, _ g: CommGraph) { set(g, .meta, "meta", meta) }
        mutating func conv(_ g: CommGraph, _ id: String) -> ConversationNode? { get(g, .conversation, id, ConversationNode.self) }
        mutating func put(conv: ConversationNode, _ g: CommGraph) { set(g, .conversation, conv.id, conv) }
        mutating func remove(conv id: String, _ g: CommGraph) { del(g, .conversation, id) }
        mutating func term(_ g: CommGraph, _ t: String) -> TermNode? { get(g, .term, t, TermNode.self) }
        mutating func put(term: TermNode, _ g: CommGraph) {
            if term.conversations <= 0 { del(g, .term, term.term) } else { set(g, .term, term.term, term) }
        }
        mutating func project(_ g: CommGraph, _ id: String) -> ProjectNode? { get(g, .project, id, ProjectNode.self) }
        mutating func put(project: ProjectNode, _ g: CommGraph) { set(g, .project, project.id, project) }
        mutating func remove(project id: String, _ g: CommGraph) { del(g, .project, id) }
        mutating func person(_ g: CommGraph, _ a: String) -> PersonNode? { get(g, .person, a, PersonNode.self) }
        mutating func put(person: PersonNode, _ g: CommGraph) {
            if person.fromThem.n == 0 && person.toThem.n == 0 && person.bulk == 0 && person.neighbours.isEmpty { del(g, .person, person.address) }
            else { set(g, .person, person.address, person) }
        }
        mutating func company(_ g: CommGraph, _ d: String) -> CompanyNode? { get(g, .company, d, CompanyNode.self) }
        mutating func put(company: CompanyNode, _ g: CommGraph) { set(g, .company, company.domain, company) }
        mutating func remove(company d: String, _ g: CommGraph) { del(g, .company, d) }
    }
}

/// A project as listed in the UI / tools.
public struct GraphProject: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ProjectKind
    public var name: String
    public var conversations: Int
    public var lastActivity: Date
}
