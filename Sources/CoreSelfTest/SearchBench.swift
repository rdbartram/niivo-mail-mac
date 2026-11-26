import Foundation
import CryptoKit
import CalendarCore
import MailCore

// CC_BENCH=1: graph build, keyword / semantic / hybrid latency and disk size at 500k synthetic headers.
// Own corpus + RNG (the MailGraphTests bench is left untouched so its numbers stay comparable).

/// Bench query embedder: returns a cluster centroid instantly so latency measures the index, not NLEmbedding.
struct CentroidEmbedder: TextEmbedder {
    let centroids: [[Float]]
    func embed(_ text: String) -> EmbeddedText? { nil }
    func embedQuery(_ text: String, spaces: Set<UInt8>) -> [EmbeddedText] {
        var h: UInt32 = 2166136261; for b in text.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return [EmbeddedText(space: 1, vector: centroids[Int(h % UInt32(centroids.count))])]
    }
}

@MainActor
func runSearchBenchmark() async {
    let env = ProcessInfo.processInfo.environment
    guard env["CC_BENCH"] == "1" || env["CC_SEARCH_BENCH"] == "1" else { return }
    section("Search benchmark: graph + BM25 + semantic at 500k headers (temp DB, deleted afterwards) — timings on stderr")
    func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    do {
        let dir = FileManager.default.temporaryDirectory.appending(path: "searchbench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "bench.sqlite")
        func diskMB() -> Double {
            var b = 0
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                b += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            return Double(b) / 1e6
        }
        let store = try MailStore(url: url, key: SymmetricKey(size: .bits256))
        let eng = mailEngine()
        store.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) }
        var folders = (0..<18).map { MailFolder(id: "f\($0)", displayName: "Folder \($0)") }
        folders.append(MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox))
        folders.append(MailFolder(id: "sent", displayName: "Sent", wellKnown: .sentitems))
        try store.replace(folders: folders, mailbox: "me")

        var rnd: UInt64 = 0x5EED
        func r(_ k: Int) -> Int { rnd = rnd &* 6364136223846793005 &+ 1442695040888963407; return Int((rnd >> 33) % UInt64(k)) }
        func zipf(_ k: Int) -> Int { let u = Double(r(1_000_000) + 1) / 1_000_001; return min(k - 1, Int(pow(Double(k), u)) - 1) }
        let vocab = (0..<400).map { "w\(String($0, radix: 36))x" }   // synthetic words
        let domains = (0..<300).map { $0 % 10 == 0 ? "gmail.com" : "org\($0).example" }
        let people = (0..<3_000).map { i in EmailAddress(name: "P\(i) | Org\(i % 300)", address: "p\(i)@\(domains[i % 300])") }
        let owner = EmailAddress(name: "Owner", address: "owner@bench.example")
        let n = Int(env["CC_SEARCH_N"] ?? "") ?? 500_000
        let t0 = Date().addingTimeInterval(-Double(n) * 120)
        var batch: [MailMessage] = []
        var start = Date()
        for i in 0..<n {
            let sent = r(10) == 0
            let p = people[zipf(people.count)]
            let subj = (0..<3).map { _ in vocab[zipf(vocab.count)] }.joined(separator: " ")
            let prev = (0..<8).map { _ in vocab[zipf(vocab.count)] }.joined(separator: " ")
            var cc: [EmailAddress] = []
            for _ in 0..<r(3) { cc.append(people[zipf(people.count)]) }
            let m = MailMessage(id: "SB\(String(format: "%09d", i))", folderId: sent ? "sent" : (r(3) == 0 ? "f\(r(18))" : "inbox"),
                                conversationId: "sc\(i / 3)", subject: subj, from: sent ? owner : p,
                                toRecipients: sent ? [p] : [owner], ccRecipients: cc,
                                received: t0.addingTimeInterval(Double(i) * 120), preview: prev, isRead: true,
                                categories: r(20) == 0 ? ["Cat\(r(12))"] : [], hasAttachments: r(7) == 0)
            batch.append(m)
            if batch.count == 10_000 { try store.upsert(messages: batch); batch.removeAll(keepingCapacity: true) }
        }
        try store.upsert(messages: batch); batch.removeAll()
        let insertS = Date().timeIntervalSince(start)
        store.checkpoint()
        let mbBase = diskMB()
        err(String(format: "  [search-bench] insert %d headers (weighted tokens, no graph): %.1f s (%.0f/s), disk %.0f MB", n, insertS, Double(n) / insertS, mbBase))

        // Graph build over the existing store (= the backfill an existing user gets once).
        start = Date()
        let g = try store.enableCommGraph(owners: [owner.address], internalDomains: ["bench.example"])
        while try !store.graphBackfillStep(maxRows: 20_000) {}
        let graphS = Date().timeIntervalSince(start)
        store.checkpoint()
        let mbGraph = diskMB()
        err(String(format: "  [search-bench] graph build (backfill) over %d rows: %.1f s (%.0f rows/s); %d nodes; +%.0f MB", n, graphS, Double(n) / graphS, g.nodeCount, mbGraph - mbBase))

        // Incremental: a 1,000-message delta (new rows + 200 read-state re-upserts) with graph attached.
        var delta: [MailMessage] = []
        for i in 0..<800 {
            let p = people[zipf(people.count)]
            delta.append(MailMessage(id: "SD\(i)", folderId: "inbox", conversationId: "sd\(i / 2)", subject: vocab[zipf(400)] + " " + vocab[zipf(400)],
                                     from: p, toRecipients: [owner], received: Date().addingTimeInterval(Double(-i)), preview: vocab[zipf(400)]))
        }
        for i in 0..<200 {
            if var m = try store.message(id: "SB\(String(format: "%09d", n - 1 - i))", includeBody: false) { m.isRead = false; delta.append(m) }
        }
        start = Date()
        try store.upsert(messages: delta)
        let deltaMs = Date().timeIntervalSince(start) * 1000
        err(String(format: "  [search-bench] incremental delta of 1,000 (800 new, 200 flag changes) incl. graph diff: %.0f ms", deltaMs))

        func timed(_ k: Int, _ body: () throws -> Void) rethrows -> (Double, Double) {
            var ts: [Double] = []
            for _ in 0..<k { let s = Date(); try body(); ts.append(Date().timeIntervalSince(s) * 1000) }
            ts.sort(); return (ts[ts.count / 2], ts[min(ts.count - 1, ts.count * 95 / 100)])
        }
        let engine = SearchEngine(store: store)
        var qi = 0
        let queries = (0..<40).map { _ in vocab[zipf(60)] + " " + vocab[zipf(120)] + " " }
        var kwHits = 0
        var stage: [String: Double] = [:]
        start = Date(); _ = engine.search(queries[0], .init(mailbox: "me", limit: 25)); let firstQ = Date().timeIntervalSince(start) * 1000
        let kw = timed(40) { qi += 1; let r = engine.search(queries[qi % 40], .init(mailbox: "me", limit: 25)); kwHits = r.total
            for (k, v) in r.timings { stage[k, default: 0] += v / 40 } }
        err(String(format: "  [search-bench] first query after open (stats + df cold): %.0f ms; keyword stage means: ", firstQ)
            + stage.sorted { $0.key < $1.key }.map { String(format: "%@ %.1f", $0.key, $0.value) }.joined(separator: ", ") + " ms")
        let kwRare = timed(30) { qi += 1; _ = engine.search(vocab[300 + qi % 90] + " ", .init(mailbox: "me", limit: 25)) }
        let filt = timed(30) { qi += 1; _ = engine.search("company:org\(1 + qi % 250).example after:90d", .init(mailbox: "me", limit: 25)) }
        let graphQ = timed(30) { qi += 1; _ = g.person(people[qi % 500].address); _ = g.neighbours(of: people[qi % 500].address) }
        err(String(format: "  [search-bench] keyword BM25 + facets (2 common terms, %d matches, pool ≤ %d): p50 %.1f ms, p95 %.1f ms", kwHits, SearchEngine.keywordPool, kw.0, kw.1))
        err(String(format: "  [search-bench] keyword rare term: p50 %.1f ms, p95 %.1f ms; company: + after: filter: p50 %.1f ms, p95 %.1f ms", kwRare.0, kwRare.1, filt.0, filt.1))
        // SEARCHQ-HOOK: natural mode (OR of concept groups; typed = last word as a 3-char prefix posting), no vectors yet.
        var nat = SearchEngine.Options(mailbox: "me", limit: 25); nat.match = .natural
        let natTyped = timed(40) { qi += 1; _ = engine.search(String(queries[qi % 40].dropLast()), nat) }
        let natDone = timed(40) { qi += 1; _ = engine.search(queries[qi % 40], nat) }
        err(String(format: "  [search-bench] natural mode at %d: typed (prefix) p50 %.1f ms, p95 %.1f ms; submitted p50 %.1f ms, p95 %.1f ms", n, natTyped.0, natTyped.1, natDone.0, natDone.1))
        // SEARCHBOX-HOOK: the main search box itself (MailSearchBox.local, mailbox scope): typed = natural, no embedding.
        func box(_ t: String, typing: Bool, folder: Bool = false) -> MailSearchBox.Request {
            .init(text: t, scope: folder ? .folder : .mailbox, mailbox: "me", folderId: "inbox", allMailboxes: ["me"], limit: 100, typing: typing)
        }
        // Keystroke prefixes of each query ("w1", "w1x", "w1x w2" …), like the debounced box sees them.
        let keystrokes = queries.flatMap { q -> [String] in let t = String(q.dropLast()); return (3...t.count).map { String(t.prefix($0)) }.filter { !$0.hasSuffix(" ") } }
        var ki = 0
        let boxTyped = timed(120) { ki += 7; _ = MailSearchBox.local(box(keystrokes[ki % keystrokes.count], typing: true), store: store) }
        let boxOps = timed(40) { qi += 1; _ = MailSearchBox.local(box(String(queries[qi % 40].dropLast()) + " is:unread after:90d", typing: true), store: store) }
        let boxFrom = timed(40) { qi += 1; _ = MailSearchBox.local(box(vocab[zipf(60)] + " from:" + people[qi % 500].address, typing: true), store: store) }
        let boxFolder = timed(40) { qi += 1; _ = MailSearchBox.local(box(String(queries[qi % 40].dropLast()), typing: true, folder: true), store: store) }
        let boxEnter = timed(40) { qi += 1; _ = MailSearchBox.local(box(queries[qi % 40], typing: false), store: store) }
        err(String(format: "  [search-bench] main box at %d: typed keystrokes p50 %.1f ms, p95 %.1f ms; + is:unread after:90d p95 %.1f ms; + from: p95 %.1f ms; folder scope p95 %.1f ms; ↩ p50 %.1f ms, p95 %.1f ms",
                   n, boxTyped.0, boxTyped.1, boxOps.1, boxFrom.1, boxFolder.1, boxEnter.0, boxEnter.1))
        err(String(format: "  [search-bench] graph person + neighbours lookup: p50 %.2f ms", graphQ.0))

        // Semantic: synthetic clustered 512-d vectors (NLEmbedding at ~3.5 ms/item would take ~30 min for 500k).
        let dim = 512, clusters = 64
        var centroids: [[Float]] = []
        for _ in 0..<clusters { centroids.append((0..<dim).map { _ in Float(r(2001) - 1000) / 1000 }) }
        let sem = store.enableSemanticIndex(embedder: CentroidEmbedder(centroids: centroids), windowDays: 100_000, policy: nil)
        func vecFor(_ i: Int) -> [Float] { let c = centroids[i % clusters]; return c.map { $0 + Float(r(801) - 400) / 1000 } }
        func load(_ range: Range<Int>) throws {
            var items: [(messageId: String, embedded: EmbeddedText?)] = []
            for i in range {
                items.append(("SB\(String(format: "%09d", i))", EmbeddedText(space: 1, vector: vecFor(i))))
                if items.count == 10_000 { try sem.putBulk(items); items.removeAll() }
            }
            try sem.putBulk(items)
        }
        start = Date()
        try load(0..<50_000)
        let vec50Load = Date().timeIntervalSince(start)
        sem.dropMemory()
        start = Date(); _ = sem.vectorCount; let cold50 = Date().timeIntervalSince(start) * 1000
        let sem50 = timed(30) { qi += 1; _ = sem.search(vectors: [EmbeddedText(space: 1, vector: vecFor(qi))], mailbox: "me", k: 200, minScore: 0) }
        err(String(format: "  [search-bench] semantic 50k vectors: write %.1f s; cold load (decrypt all) %.0f ms; brute-force top-200 p50 %.1f ms, p95 %.1f ms", vec50Load, cold50, sem50.0, sem50.1))
        start = Date()
        try load(50_000..<n)
        let vecLoad = Date().timeIntervalSince(start)
        store.checkpoint()
        let mbVec = diskMB()
        sem.dropMemory()
        start = Date(); let vc = sem.vectorCount; let cold = Date().timeIntervalSince(start) * 1000
        let semQ = timed(30) { qi += 1; _ = sem.search(vectors: [EmbeddedText(space: 1, vector: vecFor(qi))], mailbox: "me", k: 200, minScore: 0) }
        err(String(format: "  [search-bench] semantic %d vectors: write %.1f s; +%.0f MB on disk; cold load %.0f ms; top-200 p50 %.1f ms, p95 %.1f ms", vc, vecLoad, mbVec - mbGraph, cold, semQ.0, semQ.1))
        let hyb = timed(30) { qi += 1; _ = engine.search(queries[qi % 40], .init(mailbox: "me", limit: 25)) }
        err(String(format: "  [search-bench] hybrid (BM25 + semantic + RRF + facets) at 500k: p50 %.1f ms, p95 %.1f ms", hyb.0, hyb.1))
        err(String(format: "  [search-bench] disk: base %.0f MB, + graph %.0f MB, + vectors %.0f MB = %.0f MB (%.0f bytes/header)",
                   mbBase, mbGraph - mbBase, mbVec - mbGraph, mbVec, mbVec * 1e6 / Double(n)))

        // Real on-device embedding throughput (what catchUp costs per item).
        if let apple = AppleSentenceEmbedder() {
            let texts = (0..<300).map { i in "Projekt \(vocab[i % 400]) Budget review for the migration of site \(i). Notes follow." }
            start = Date(); var ok = 0
            for t in texts where apple.embed(t) != nil { ok += 1 }
            let per = Date().timeIntervalSince(start) * 1000 / Double(texts.count)
            start = Date(); _ = apple.embedQuery("budget review", spaces: [1, 2]); let qms = Date().timeIntervalSince(start) * 1000
            err(String(format: "  [search-bench] NLEmbedding: %.2f ms per document (%d/%d embedded), query in 2 spaces %.1f ms; languages %@",
                       per, ok, texts.count, qms, AppleSentenceEmbedder.availableLanguages().map { "\($0.language)/\($0.dimension)" }.joined(separator: ",")))
        }
        check(kw.1 < 100 && semQ.1 < 100, "search p95 under 100 ms (MAIL-PLAN target) at \(n) (keyword \(String(format: "%.0f", kw.1)), semantic \(String(format: "%.0f", semQ.1)))")
    } catch { check(false, "search benchmark threw \(error)") }
}
