import Foundation
import CryptoKit
import CalendarCore
import MailCore
import TrustCore
import OfficeTools

// CommGraph, BM25, semantic index, fusion, facets, gating, no-plaintext-on-disk, tool parity. Synthetic data only;
// nothing here prints subjects, senders or bodies.

/// Deterministic stand-in for NLEmbedding: concept words light up one dimension, everything else adds hashed noise.
struct StubEmbedder: TextEmbedder {
    static let concepts: [[String]] = [["invoice", "bill", "payment", "overdue", "rechnung"], ["football", "training", "match"],
                                       ["server", "outage", "incident", "downtime"]]
    func vec(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: 64)
        for w in BlindIndex.tokenize(text) {
            if let c = Self.concepts.firstIndex(where: { $0.contains(w) }) { v[c] += 4 }
            else { var h: UInt32 = 2166136261; for b in w.utf8 { h = (h ^ UInt32(b)) &* 16777619 }; v[8 + Int(h % 56)] += 0.3 }
        }
        return v
    }
    func embed(_ text: String) -> EmbeddedText? { EmbeddedText(space: 1, vector: vec(text)) }
    func embedQuery(_ text: String, spaces: Set<UInt8>) -> [EmbeddedText] { spaces.contains(1) ? [EmbeddedText(space: 1, vector: vec(text))] : [] }
}

@MainActor
func runSearchTests() async {
    section("CommGraph: nodes, edges, company grouping, free-mail exclusion")
    let L = FixtureCalendarService.labels
    let me = "owner@niivo-test.example"
    let base = Date().addingTimeInterval(-10 * 86_400)
    func mk(_ id: String, folder: String = "inbox", conv: String? = nil, subject: String, from: (String, String),
            to: [(String, String)] = [(me, "Owner")], cc: [(String, String)] = [], preview: String? = nil, day: Double = 0,
            label: String? = nil, cats: [String] = [], att: Bool = false, priv: Bool = false) -> MailMessage {
        MailMessage(id: id, folderId: folder, conversationId: conv ?? "c-" + id, subject: subject,
                    from: EmailAddress(name: from.1, address: from.0),
                    toRecipients: to.map { EmailAddress(name: $0.1, address: $0.0) }, ccRecipients: cc.map { EmailAddress(name: $0.1, address: $0.0) },
                    received: base.addingTimeInterval(day * 86_400), preview: preview, categories: cats, hasAttachments: att,
                    labelId: label, isPrivate: priv)
    }
    func newStore(url: URL? = nil, embedder: TextEmbedder? = StubEmbedder()) throws -> MailStore {
        let s = try MailStore(url: url, key: SymmetricKey(size: .bits256))
        let eng = mailEngine()
        s.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) }
        try s.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox),
                                MailFolder(id: "sent", displayName: "Sent Items", wellKnown: .sentitems),
                                MailFolder(id: "junk", displayName: "Junk", wellKnown: .junkemail),
                                MailFolder(id: "proj", displayName: "Kestrel Programme")], mailbox: "me")
        try s.enableCommGraph(owners: [me], internalDomains: ["niivo-test.example"])
        let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
        s.enableSemanticIndex(embedder: embedder, windowDays: 90, policy: { m, mb in gate.exposure(m, mailbox: mb, tier: .onDevice) == .content })
        return s
    }
    let anna = ("anna.meier@acme-industries.example", "Anna Meier | Acme AG"), bob = ("bob@acme-industries.example", "Bob Frei")
    let carl = ("carl.private@gmail.example", "Carl"), mia = ("mia@ops.fabrikam.co.uk", "Mia Keller")
    let colleague = ("lea@niivo-test.example", "Lea")
    let corpus: [MailMessage] = [
        mk("m1", conv: "k1", subject: "Kestrel rollout plan", from: anna, cc: [bob], preview: "The invoice is overdue", day: 1, cats: ["Kestrel"]),
        mk("m2", folder: "sent", conv: "k1", subject: "RE: Kestrel rollout plan", from: (me, "Owner"), to: [anna], cc: [bob], preview: "Will pay", day: 2, cats: ["Kestrel"]),
        mk("m3", folder: "sent", subject: "Weekend", from: (me, "Owner"), to: [carl], preview: "football training saturday", day: 3),
        mk("m4", conv: "u1", subject: "UID Abgleich Lieferanten", from: mia, preview: "server outage last night", day: 4, att: true),
        mk("m5", conv: "u2", subject: "UID Abgleich Kunden", from: mia, day: 5),
        mk("m6", folder: "proj", conv: "u3", subject: "UID Abgleich Partner", from: colleague, day: 6),
        mk("m7", folder: "junk", subject: "You won", from: ("spam@junk-sender.example", "Spam"), day: 6),
        mk("m8", subject: "Weekly digest", from: ("newsletter@shop-news.example", "Shop"), day: 7),
        mk("m9", subject: "Board numbers secret", from: anna, cc: [bob], preview: "quarterly payment figures", day: 8, label: L[3].id),
        mk("m10", subject: "Pricing draft", from: anna, preview: "invoice adjustments", day: 8.5, label: L[2].id),
    ]
    var storeOpt: MailStore?
    do { storeOpt = try newStore() } catch { check(false, "store opens (\(error))") }
    guard let store = storeOpt, let g = store.graph else { return }
    do { try store.upsert(messages: corpus) } catch { check(false, "upsert threw \(error)") }
    let pa = g.person(anna.0)
    check(pa?.fromThem.n == 3 && pa?.toThem.n == 1, "person: received 3 from Anna (m1,m9,m10), sent 1 to her (\(pa?.fromThem.n ?? -1)/\(pa?.toThem.n ?? -1))")
    check(pa?.company == "acme-industries.example" && pa?.isInternal == false, "person → company by registrable domain, external")
    check(pa?.neighbours[bob.0] != nil && g.person(bob.0)?.neighbours[anna.0] != nil, "person↔person edge from cc (both directions)")
    check(g.person(bob.0)?.neighbours[anna.0]?.n == 2, "edge weight counts both messages where details are cached (protected m9 adds none)")
    let acme = g.company("acme-industries.example")
    check(acme?.displayName == "Acme AG" && acme?.people[anna.0] != nil, "company name from display-name metadata ('… | Acme AG')")
    check(g.person(carl.0)?.company == nil && g.company("gmail.example") == nil, "free-mail domain (gmail.example) is never a company")
    check(g.company("fabrikam.co.uk") != nil && g.company("ops.fabrikam.co.uk") == nil, "multi-part suffix: ops.fabrikam.co.uk → fabrikam.co.uk")
    check(g.person("spam@junk-sender.example") == nil, "junk folder doesn't count")
    check(g.person("newsletter@shop-news.example")?.bulk == 1 && g.company("shop-news.example") == nil, "newsletter sender: bulk only, no company")
    check(g.person(me) == nil, "owner has no node (ego-centric graph)")
    check(g.person(colleague.0)?.isInternal == true, "internal domain → internal")
    let cat = g.project("cat:kestrel")
    check(cat?.conversations == 1 && cat?.messages.n == 2 && cat?.people[anna.0] != nil, "category project: 1 conversation, 2 messages, people")
    check(g.project("fld:proj")?.name == "Kestrel Programme", "user folder project named after the folder")
    let topics = g.topics()
    check(topics.contains { $0.id == "t:uid" || $0.id == "t:abgleich" } && topics.first { $0.id == "t:uid" || $0.id == "t:abgleich" }?.name.contains("·") == true,
          "recurring subject terms form a topic cluster with a fallback name from the top terms")
    check(g.resolveProject("kestrel").contains { $0.id == "cat:kestrel" } && g.resolveCompany("acme").first?.domain == "acme-industries.example",
          "resolve project/company by name")

    section("CommGraph: incremental update (diff, not rebuild)")
    do {
        let before = g.person(anna.0)
        try store.upsert(messages: corpus)
        check(g.person(anna.0) == before, "re-upsert of unchanged rows leaves weights identical")
        var read = corpus[0]; read.isRead = true; read.flag = FollowUpFlag(status: .flagged)
        try store.upsert(message: read)
        check(g.person(anna.0) == before, "read/flag change doesn't double count")
        var moved = corpus[0]; moved.folderId = "proj"
        try store.upsert(message: moved)
        check(g.project("fld:proj")?.messages.n == 2 && g.person(anna.0)?.fromThem.n == 3, "move into a user folder → folder project gains the message, counts stable")
        try store.deleteMessages(ids: ["m3"])
        check(g.person(carl.0) == nil, "delete removes the only contribution → node gone")
        try store.upsert(message: corpus[2])
        check(g.person(carl.0)?.toThem.n == 1, "re-add restores it")
        let n0 = g.meta.messages
        try store.prune(mailbox: "me", before: base.addingTimeInterval(1.5 * 86_400))
        check(g.meta.messages == n0 - 1 && g.person(anna.0)?.fromThem.n == 2, "prune (cache window shrink) removes pruned rows from the graph")
        try store.upsert(message: moved)
        // Relabel m1 to protected → recipients no longer cached → the cc edge from m1 goes away.
        var prot = moved; prot.labelId = L[3].id
        try store.upsert(message: prot)
        check(g.person(bob.0)?.neighbours[anna.0]?.n == 1, "relabel to protected: recipient-derived edge removed (only m2 left)")
    } catch { check(false, "incremental threw \(error)") }

    // Backfill: a store with rows written before the graph was enabled.
    do {
        let s2 = try MailStore(url: nil, key: SymmetricKey(size: .bits256))
        let eng = mailEngine()
        s2.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) }
        try s2.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox), MailFolder(id: "sent", displayName: "Sent", wellKnown: .sentitems),
                                 MailFolder(id: "junk", displayName: "Junk", wellKnown: .junkemail), MailFolder(id: "proj", displayName: "Kestrel Programme")], mailbox: "me")
        try s2.upsert(messages: Array(corpus.prefix(6)))
        let g2 = try s2.enableCommGraph(owners: [me], internalDomains: ["niivo-test.example"])
        try s2.upsert(messages: Array(corpus.suffix(4)))   // arrives while the backfill hasn't run
        while try !s2.graphBackfillStep(maxRows: 3) {}
        check(g2.person(anna.0)?.fromThem.n == 3 && g2.person(anna.0)?.toThem.n == 1 && s2.graphBackfillDone,
              "resumable backfill + concurrent writes count every row exactly once")
    } catch { check(false, "backfill threw \(error)") }

    // Reindex: rows written by an older build (no weights / filter tokens) are re-tokenised, resumably.
    do {
        let s = try newStore(embedder: nil)
        try s.upsert(messages: corpus)
        try s.setValue("1", for: "search-index-version"); try s.setValue("0", for: "search-reindex-cursor")
        check(!s.searchIndexCurrent, "older index version detected")
        var steps = 0
        while try !s.reindexStep(maxRows: 3) { steps += 1 }
        check(s.searchIndexCurrent && steps >= 2 && s.messages(matching: [.from(anna.0)], mailbox: "me").count == 3,
              "reindex completes in resumable steps; exact tokens work afterwards")
    } catch { check(false, "reindex threw \(error)") }

    section("Semantic index: gate, int8 vectors, padded markers")
    do {
        let s = try newStore()
        try s.upsert(messages: corpus)
        guard let sem = s.semantic else { check(false, "semantic attached"); return }
        while try sem.catchUp(maxItems: 4) > 0 {}
        // Embeddable: unlabelled + General/Confidential (on-device sees labelled-unencrypted content); NOT the
        // protected m9 and not private items. Junk m7 is embedded too (search covers every folder).
        check(sem.vectorCount == corpus.count - 1, "every row except the protected one has a vector (\(sem.vectorCount)/\(corpus.count))")
        check(sem.vectorRowCount == corpus.count && sem.pendingCount == 0, "the protected row has a same-size marker row; nothing pending")
        let top = SearchEngine(store: s).search("bill payment ", .init(mailbox: "me", limit: 5))
        check(top.usedSemantic && top.hits.contains { $0.id == "m1" } && !top.hits.contains { $0.id == "m9" },
              "semantic: 'bill payment' finds the 'invoice overdue' mail (no shared word), never the protected one")
        var priv = corpus[3]; priv.isPrivate = true
        try s.upsert(message: priv)
        while try sem.catchUp() > 0 {}
        check(sem.vectorCount == corpus.count - 2, "marking an item private removes its vector")
        try s.wipe()
        check(sem.vectorCount == 0 && s.graph?.person(anna.0) == nil, "wipe clears vectors and graph")
    } catch { check(false, "semantic threw \(error)") }

    section("BM25 ranking, fusion, facets")
    do {
        let s = try newStore(embedder: nil)
        var docs: [MailMessage] = []
        docs.append(mk("b1", subject: "Kestrel kestrel budget", from: anna, day: 1))
        docs.append(mk("b2", subject: "Quarterly notes", from: bob, preview: "mentions kestrel once among many other words here", day: 2))
        for i in 0..<20 { docs.append(mk("n\(i)", subject: "Budget item \(i)", from: colleague, day: 3)) }
        try s.upsert(messages: docs)
        let e = SearchEngine(store: s)
        let r = e.search("kestrel ", .init(mailbox: "me"))
        check(r.hits.map(\.id) == ["b1", "b2"], "BM25: subject tf 2 outranks a single preview mention (\(r.hits.map(\.id)))")
        let r2 = e.search("kestrel budget ", .init(mailbox: "me"))
        check(r2.hits.first?.id == "b1" && r2.hits.count == 1, "AND semantics kept: both words required")
        let r3 = e.search("budget ", .init(mailbox: "me"))
        check(r3.hits.count == 21 && r3.facets.people.first?.count == 20, "facets: person counts over all matches (\(r3.facets.people.first?.count ?? -1))")
        check(r3.facets.companies.contains { $0.key == "acme-industries.example" } && !r3.facets.companies.contains { $0.key.contains("gmail") },
              "company facet by registrable domain")
        check(r3.facets.dates.reduce(0) { $0 + $1.count } == 21, "date-bucket facet covers every match")
        let r4 = e.search("budget from:" + anna.0, .init(mailbox: "me"))
        check(r4.hits.map(\.id) == ["b1"], "from: operator (exact address token)")
        let r5 = e.search("company:acme-industries.example", .init(mailbox: "me"))
        check(Set(r5.hits.map(\.id)) == ["b1", "b2"], "company: operator (filter-only query)")
        let idfRare = e.search("quarterly ", .init(mailbox: "me"))
        check(idfRare.hits.first?.id == "b2", "rare subject term ranks its document")

        let s2 = try newStore()
        try s2.upsert(messages: corpus)
        while try s2.semantic!.catchUp() > 0 {}
        let e2 = SearchEngine(store: s2)
        let fused = e2.search("invoice ", .init(mailbox: "me"))
        let both = fused.hits.prefix(2)
        check(Set(both.map(\.id)) == ["m1", "m10"] && both.allSatisfy { $0.keywordRank != nil && $0.semanticRank != nil },
              "fusion: items matched by keyword AND semantic rank above single-signal hits (\(fused.hits.map(\.id)))")
        let semOnly = e2.search("bill ", .init(mailbox: "me"))
        check(semOnly.hits.contains { $0.id == "m1" && $0.keywordRank == nil && $0.semanticRank != nil }, "fusion admits semantic-only hits")
        let att = e2.search("has:attachment", .init(mailbox: "me"))
        check(att.hits.map(\.id) == ["m4"], "has:attachment")
        let proj = e2.search("project:kestrel", .init(mailbox: "me"))
        check(Set(proj.hits.map(\.id)) == ["m1", "m2"], "project: operator via the graph (category)")
        let topic = e2.search("project:t:uid", .init(mailbox: "me"))
        check(topic.hits.count == 3, "project: topic term (\(topic.hits.count))")
        check(fused.facets.projects.contains { $0.key == "cat:kestrel" }, "project facet")

        section("Search gating (AI callers)")
        let eng = mailEngine()
        let meta: SearchCaller = .ai { m, mb in
            let p = AIAccessPolicy(engine: eng, aiMaxPriority: 2)
            guard let r = p.redactForAI(m, mailbox: mb) else { return nil }
            return (r, p.level(for: m, mailbox: mb) == .full ? .full : .metadata)
        }
        let aiR = e2.search("invoice ", .init(mailbox: "me", caller: meta))
        check(!aiR.hits.contains { $0.id == "m10" }, "AI (cloud): Confidential item isn't matched on its preview-only word")
        check(aiR.hits.allSatisfy { $0.semanticRank == nil || $0.exposure == .full }, "AI: semantic rank only on full-exposure items")
        let aiSubj = e2.search("pricing ", .init(mailbox: "me", caller: meta))
        check(aiSubj.hits.map(\.id) == ["m10"] && aiSubj.hits.first?.exposure == .metadata && aiSubj.hits.first?.message.preview == nil,
              "AI: metadata item still matches on its subject, comes back redacted")
        let aiBoard = e2.search("board ", .init(mailbox: "me", caller: meta))
        check(aiBoard.hits.allSatisfy { $0.message.subject != "Board numbers secret" }, "AI: protected item never shows its subject")
        let aiFacet = e2.search("from:" + anna.0, .init(mailbox: "me", caller: meta))
        check(!aiFacet.facets.people.contains { $0.key == bob.0 && $0.count > 1 }, "AI facets: recipients only from full-exposure items")
        let off: SearchCaller = .ai { _, _ in nil }
        let none = e2.search("kestrel ", .init(mailbox: "me", caller: off))
        check(none.hits.isEmpty && none.restricted > 0 && none.facets.people.isEmpty, "AI off: no hits, no facets, only a restricted count")
    } catch { check(false, "ranking threw \(error)") }

    section("No plaintext on disk (graph, tokens, vectors)")
    do {
        let dir = FileManager.default.temporaryDirectory.appending(path: "searchtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "m.sqlite")
        let s = try newStore(url: url)
        try s.upsert(messages: corpus)
        while try s.semantic!.catchUp() > 0 {}
        _ = s.graph?.topics()
        var bytes = Data()
        for suffix in ["", "-wal", "-shm"] { if let d = try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) { bytes.append(d) } }
        let needles = ["anna", "Anna Meier", "acme-industries", "Acme AG", "fabrikam", "gmail", "Kestrel", "kestrel", "abgleich", "Abgleich",
                       "lieferanten", "rollout", "invoice", "overdue", "football", "Bob Frei", "newsletter", "Programme", "uid · ", "carl"]
        let found = needles.filter { n in bytes.range(of: Data(n.utf8)) != nil || bytes.range(of: Data(n.lowercased().utf8)) != nil }
        check(bytes.count > 10_000 && found.isEmpty, "sqlite + WAL contain none of the fixture names, domains, categories or subject words (\(found.count) found)")
    } catch { check(false, "disk scan threw \(error)") }

    section("Tools: search / company_context / graph-backed people & project (in-process = MCP)")
    var c = ServerConfig(); c.allowDrafts = false; c.allowTriage = false
    guard let b = try? await Backend.make(c) else { check(false, "fixture backend"); return }
    let srv = MCPServer.agent(backend: b, audit: AuditSink.make(fixtures: true, path: nil))
    check(srv.toolNames.contains("search") && srv.toolNames.contains("company_context"), "agent server offers search + company_context")
    func o(_ s: String) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]) ?? [:] }
    let sr = await srv.callTool("search", argumentsJSON: "{\"query\":\"from:alex@contoso.example\"}")
    let so = o(sr.text)
    check(!sr.isError && ((so["results"] as? [Any])?.count ?? 0) > 0 && so["facets"] != nil, "search tool: results + facets")
    check(!sr.text.contains(FixtureMailService.Special.privateMsg), "search tool: private item never returned")
    let cc = await srv.callTool("company_context", argumentsJSON: "{\"company\":\"fabrikam.example\"}")
    let co = o(cc.text)
    check(!cc.isError && ((co["people"] as? [Any])?.count ?? 0) > 0 && co["open_items"] != nil, "company_context: people + open items")
    check(await srv.callTool("company_context", argumentsJSON: "{\"company\":\"gmail.example\"}").isError, "company_context refuses a free-mail domain")
    // The private fixture's subject words exist only on hidden mail: the graph must not confirm them as a project.
    let pm = await srv.callTool("project_context", argumentsJSON: "{\"project\":\"matter\"}")
    check(pm.isError && !pm.text.contains("matter\",") && pm.messageIds.isEmpty, "project_context: a project known only from hidden mail is 'unknown'")
    let toHidden = o(await srv.callTool("search", argumentsJSON: "{\"query\":\"to:you@contoso.example personal\"}").text)
    check((toHidden["restricted_not_shown"] as? Int ?? 0) == 0, "search: to: filter never counts hidden rows (no recipient oracle)")
    let ph = o(await srv.callTool("people_history", argumentsJSON: "{\"address\":\"jordan@fabrikam.example\"}").text)
    check(ph["company"] != nil && ph["related_people"] != nil && ph["projects"] != nil, "people_history carries company, related people, projects")
    var cOff = ServerConfig(); cOff.allowDrafts = false; cOff.allowTriage = false; cOff.aiAccessOverride = .off
    if let bo = try? await Backend.make(cOff) {
        let so2 = MCPServer.agent(backend: bo, audit: AuditSink.make(fixtures: true, path: nil))
        let r1 = await so2.callTool("search", argumentsJSON: "{\"query\":\"budget\"}")
        let r2 = await so2.callTool("company_context", argumentsJSON: "{\"company\":\"fabrikam.example\"}")
        check(r1.isError && r2.isError && r1.messageIds.isEmpty, "AI off: search + company_context refuse")
    }
    let stdio = MCPServer(config: ServerConfig(), backend: b, audit: AuditSink.make(fixtures: true, path: nil))
    let readOnly = Set(stdio.toolNames).subtracting(["mail_create_draft", "mail_flag", "mail_mark_read", "mail_snooze"])
    check(readOnly == Set(srv.toolNames), "parity: MCP read tools == in-app agent tools (\(srv.toolNames.count))")
}
