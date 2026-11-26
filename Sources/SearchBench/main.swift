import Foundation
import CryptoKit
import CalendarCore
import MailCore

// Search quality bench (docs/SEARCH-QUALITY.md). Synthetic corpus only, in-memory store, nothing touches real mail.
//   swift run -c release SearchBench                 all configs, bodies 0 %
//   swift run -c release SearchBench --bodies 50     simulate 50 % of messages opened (body + attachment names cached)
//   swift run -c release SearchBench --only hub,ask  run some configs
//   swift run -c release SearchBench --detail ask    per-query top 5 for one config
// Metrics: nDCG@10 (gain 2^g − 1), MRR (first grade ≥ 1), recall@20 (grade ≥ 1), p50/p95 latency over 3 rounds.

let args = CommandLine.arguments
func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let bodiesPct = Int(arg("--bodies") ?? "0") ?? 0
let only = arg("--only").map { Set($0.split(separator: ",").map(String.init)) }
let detail = arg("--detail")
let now = Date()
let corpus = buildCorpus(now: now)

enum Emb: String { case none, apple, contextual }

func makeStore(_ emb: Emb) throws -> MailStore {
    let store = try MailStore(url: nil, key: SymmetricKey(size: .bits256))
    store.setPersistPolicy { m, _ in MailContentPolicy.failClosed(for: m) }
    try store.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox),
                                MailFolder(id: "sent", displayName: "Sent Items", wellKnown: .sentitems)], mailbox: "me")
    _ = try store.enableCommGraph(owners: [BenchCorpus.me.address], internalDomains: ["niivo.example"])
    let embedder: TextEmbedder? = switch emb {
    case .none: nil
    case .apple: AppleSentenceEmbedder()
    case .contextual: makeContextualEmbedder()
    }
    store.enableSemanticIndex(embedder: embedder, windowDays: 365, policy: { m, _ in
        let p = MailContentPolicy.failClosed(for: m); return p.allowOfflineDetails && !m.isPrivate
    })
    try store.upsert(messages: corpus.messages)
    // "Opened" messages: body + attachment names arrive like a reader fetch would deliver them.
    if bodiesPct > 0 {
        var opened: [MailMessage] = []
        for m in corpus.messages {
            var h: UInt32 = 2166136261; for b in m.id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
            guard Int(h % 100) < bodiesPct, let o = corpus.opened[m.id] else { continue }
            var mm = m; mm.body = o.body; mm.attachments = o.attachments
            opened.append(mm)
        }
        try store.upsert(messages: opened)
    }
    while try !store.graphBackfillStep() {}
    while try !store.reindexStep() {}
    if let s = store.semantic { while try s.catchUp(maxItems: 512) > 0 {} }
    return store
}

struct Config { var name: String; var emb: Emb; var run: (MailStore, String) -> [String] }

var configs: [Config] = [
    Config(name: "legacy", emb: .none) { s, q in ((try? s.search(q, mailbox: "me", limit: 50)) ?? []).map(\.id) },
    Config(name: "hub-nosem", emb: .none) { s, q in
        var o = SearchEngine.Options(mailbox: "me", limit: 50); o.now = now; o.semantic = false
        return SearchEngine(store: s).search(q, o).hits.map(\.id)
    },
    Config(name: "hub", emb: .apple) { s, q in
        var o = SearchEngine.Options(mailbox: "me", limit: 50); o.now = now
        return SearchEngine(store: s).search(q, o).hits.map(\.id)
    },
]
configs += extraConfigs()

func dcg(_ grades: [Int]) -> Double { grades.enumerated().reduce(0) { $0 + (pow(2, Double($1.1)) - 1) / log2(Double($1.0) + 2) } }

struct Score { var ndcg = 0.0, mrr = 0.0, recall = 0.0, n = 0
    mutating func add(_ o: Score) { ndcg += o.ndcg; mrr += o.mrr; recall += o.recall; n += o.n }
    var line: String { n == 0 ? "-" : String(format: "%.3f / %.3f / %.3f", ndcg / Double(n), mrr / Double(n), recall / Double(n)) }
}

func evaluate(_ ids: [String], _ q: BenchQuery) -> Score {
    let grades = ids.prefix(10).map { q.qrels[$0] ?? 0 }
    let ideal = dcg(q.qrels.values.sorted(by: >).prefix(10).map { $0 })
    let rr = ids.firstIndex { (q.qrels[$0] ?? 0) > 0 }.map { 1 / Double($0 + 1) } ?? 0
    let rel = q.qrels.filter { $0.value > 0 }.keys
    let found = Set(ids.prefix(20)).intersection(rel).count
    return Score(ndcg: ideal > 0 ? dcg(grades) / ideal : 0, mrr: rr, recall: Double(found) / Double(max(1, rel.count)), n: 1)
}

var stores: [Emb: MailStore] = [:]
print("SearchBench: \(corpus.messages.count) messages, \(corpus.queries.count) queries (\(corpus.queries.filter(\.holdout).count) held out), bodies cached \(bodiesPct) %")
print("config | all nDCG@10 / MRR / R@20 | dev | holdout | p50 ms | p95 ms | privacy")
var perCat: [(String, [BenchQuery.Category: Score])] = []
for cfg in configs where only == nil || only!.contains(cfg.name) {
    let store: MailStore
    do {
        if let s = stores[cfg.emb] { store = s } else { let t = Date(); store = try makeStore(cfg.emb); stores[cfg.emb] = store
            FileHandle.standardError.write(Data("[\(cfg.emb.rawValue) store built in \(Int(Date().timeIntervalSince(t) * 1000)) ms, vectors \(store.semantic?.vectorCount ?? 0)]\n".utf8)) }
    } catch { print("\(cfg.name): store failed \(error)"); continue }
    var all = Score(), dev = Score(), hold = Score(), lat: [Double] = [], leaks = 0
    var cats: [BenchQuery.Category: Score] = [:]
    _ = cfg.run(store, "warm up")
    for round in 0..<3 {
        for q in corpus.queries {
            let t = Date()
            let ids = cfg.run(store, q.text)
            lat.append(Date().timeIntervalSince(t) * 1000)
            guard round == 0 else { continue }
            let s = evaluate(ids, q)
            all.add(s); if q.holdout { hold.add(s) } else { dev.add(s) }
            cats[q.category, default: Score()].add(s)
            leaks += ids.filter { corpus.protectedIds.contains($0) }.count
            if detail == cfg.name {
                let top = ids.prefix(5).map { "\($0)(\(q.qrels[$0] ?? 0))" }.joined(separator: " ")
                print(String(format: "  %.2f  %@ → %@", s.ndcg, q.text, top))
            }
        }
    }
    lat.sort()
    let p50 = lat[lat.count / 2], p95 = lat[min(lat.count - 1, Int(Double(lat.count) * 0.95))]
    print("\(cfg.name) | \(all.line) | \(dev.line) | \(hold.line) | \(String(format: "%.1f", p50)) | \(String(format: "%.1f", p95)) | \(leaks == 0 ? "ok" : "LEAK \(leaks)")")
    perCat.append((cfg.name, cats))
}
print("\nnDCG@10 per category (n queries):")
print("category | " + perCat.map(\.0).joined(separator: " | "))
for c in BenchQuery.Category.allCases {
    let n = corpus.queries.filter { $0.category == c }.count
    print("\(c.rawValue) (\(n)) | " + perCat.map { pc in pc.1[c].map { String(format: "%.3f", $0.ndcg / Double($0.n)) } ?? "-" }.joined(separator: " | "))
}
