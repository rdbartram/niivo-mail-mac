import Foundation

// SEARCHQ: natural-language matching for Ask / Enter (docs/SEARCH-QUALITY.md).
// Differences to `.all`: each query concept is a group of alternatives (as typed, ß/ss + Umlaut variants, DE/EN/FR/IT
// lexicon synonyms, compound heads), groups are OR-ed and scored with coverage-weighted BM25, words without any
// posting fall back to typo recovery (3-char prefix candidates verified by edit distance), stopwords and time /
// attachment / sender phrases become hints. Same filters, same gate, same visibility rules as `.all`:
//  * `.ai` callers: a group only counts on an item if one of its alternatives is VISIBLE to that caller (sender +
//    unwithheld subject for metadata items; full items also through indexed preview / cached-body terms).
//  * Semantic hits count only on `.full` items (unchanged).

extension SearchEngine {
    /// Fusion weights for natural mode. The keyword score is normalised to the best candidate (1.0); the others add.
    public struct NaturalWeights: Sendable {
        /// Semantic cosine above `semanticFloor`, scaled to [0, 1] over (floor, 1].
        /// Bench (docs/SEARCH-QUALITY.md): Apple's sentence vectors add noise on top of the lexicon at 0.3/0.3;
        /// 0.1 over a 0.5 floor is neutral-to-positive, so they only break near-ties.
        public var semantic = 0.1
        public var semanticFloor: Float = 0.5
        public var sender = 0.3
        public var attachment = 0.15
        public var phrase = 0.5
        public var recency = 0.1
        public var proximity = 0.05
        /// Semantic-only items (no keyword group matched) are admitted only when NO item matched a keyword group,
        /// and then need at least this cosine and this rank.
        public var semanticOnlyMinScore: Float = 0.5
        public var semanticOnlyMaxRank = 10
        public init() {}
    }

    func searchNatural(_ q: SearchQuery, _ o: Options) -> SearchResult {
        let empty = SearchResult(hits: [], facets: SearchFacets(), total: 0, restricted: 0, usedSemantic: false, keywordCandidates: 0, semanticCandidates: 0)
        guard let prep = prepareFilters(q, o) else { return empty }
        let key = store.indexKey, now = o.now, w = o.weights
        var nq = NaturalQuery.interpret(q.words.joined(separator: " "), prefixLast: q.prefixLast, expand: o.expand, now: now)
        nq.phrases += q.phrases
        nq.addHints(q.hintWords, expand: o.expand)
        let groups = nq.groups
        let required = groups.filter { !$0.optional }.count
        guard !groups.isEmpty else {
            // Only scaffolding / hints: fall back to the operator search with the hints as operators.
            var q2 = q; q2.words = []
            if q2.after == nil { q2.after = nq.after }; if q2.before == nil { q2.before = nq.before }
            if q2.isEmpty { return empty }
            var o2 = o; o2.match = .all
            return search(q2, o2)
        }
        var clock = Date(), timings: [String: Double] = [:]
        func lap(_ k: String) { timings[k] = Date().timeIntervalSince(clock) * 1000; clock = Date() }

        // 1. Postings per alternative (hard bounds: explicit operators only; natural dates are soft, see step 4).
        let stats = store.corpusStats()
        let n = Double(max(stats.n, 1))
        struct Acc { var received: Int64; var dl: Int64; var best: [Int: (meta: Int, prev: Int, idf: Double, kind: SearchTermGroup.Kind, alt: String)] = [:] }
        var acc: [Int64: Acc] = [:]
        var fuzzy: Set<Int> = []
        var pool = 0
        for (gi, g) in groups.enumerated() {
            var anyHit = false
            for (alt, kind) in g.alternatives {
                let h = BlindIndex.termHash(alt, prefix: g.prefix && kind == .word, key: key)
                let df = store.documentFrequency(h)
                guard df > 0 else { continue }
                anyHit = true
                let idf = log(1 + (n - Double(df) + 0.5) / (Double(df) + 0.5))
                // Expansions read fewer postings (newest first): bounds the OR fan-out on large mailboxes.
                let rows = (try? store.postings(h, filters: prep.filters, mailbox: o.mailbox, folderId: prep.folderId,
                                                after: q.after, before: q.before, limit: kind == .synonym ? Self.keywordPool / 3 : Self.keywordPool)) ?? []
                pool += rows.count
                for r in rows {
                    var a = acc[r.rid] ?? Acc(received: r.received, dl: r.dl)
                    let cand = (meta: r.w & 0xF, prev: r.w >> 4, idf: idf, kind: kind, alt: alt)
                    if let old = a.best[gi], Self.contrib(old, stats) >= Self.contrib(cand, stats) {} else { a.best[gi] = cand }
                    acc[r.rid] = a
                }
            }
            // Typo / truncated-word recovery: no alternative exists anywhere → candidates by 3-char prefix, verified
            // after decrypt (edit distance within budget, or the word is the start of a longer one).
            if !anyHit, !g.prefix, g.original.count >= 4 {
                fuzzy.insert(gi)
                let h = BlindIndex.termHash(g.original, prefix: true, key: key)
                let df = store.documentFrequency(h)
                guard df > 0 else { continue }
                let idf = log(1 + (n - Double(df) / 4 + 0.5) / (Double(df) / 4 + 0.5))
                for r in (try? store.postings(h, filters: prep.filters, mailbox: o.mailbox, folderId: prep.folderId,
                                              after: q.after, before: q.before, limit: Self.keywordPool)) ?? [] {
                    var a = acc[r.rid] ?? Acc(received: r.received, dl: r.dl)
                    if a.best[gi] == nil { a.best[gi] = (meta: r.w & 0xF, prev: r.w >> 4, idf: idf, kind: .synonym, alt: g.original) }
                    acc[r.rid] = a
                }
            }
        }
        func score(_ a: Acc, groupsOK: Set<Int>? = nil, metaOnly: Bool = false) -> (Double, Int) {
            var s = 0.0, matched = 0
            for (gi, b) in a.best where groupsOK?.contains(gi) ?? true {
                let c = Self.contrib(b, stats, dl: a.dl, metaOnly: metaOnly)
                guard c > 0 else { continue }
                s += c * SearchTermGroup.weight(b.kind) * (groups[gi].optional ? 0.5 : 1)
                if !groups[gi].optional { matched += 1 }
            }
            return (SearchFusion.keywordScore(bm25: s, matched: matched, required: required), matched)
        }
        let ranked = acc.map { ($0.key, score($0.value).0, $0.value.received) }.sorted { ($0.1, $0.2) > ($1.1, $1.2) }
        let kwTop = Array(ranked.prefix(Self.decryptPool))
        lap("keyword")

        // 2. Semantic (content words only; scaffolding would pull towards "mail-ish" mail).
        var semHits: [(rid: Int64, score: Float)] = []
        let semText = groups.filter { !$0.optional }.map(\.original).joined(separator: " ")
        if o.semantic, !semText.isEmpty, let sem = store.semantic, sem.embedder != nil {
            semHits = sem.search(semText, mailbox: o.mailbox, k: 100)
        }
        lap("semantic")

        // 3. Decrypt, structural post-filters, gate, visibility re-check.
        let rows = (try? store.rows(rids: Array(Set(kwTop.map(\.0) + semHits.map(\.rid))))) ?? [:]
        var restricted = 0
        struct Cand { var m: MailMessage; var shown: MailMessage; var mb: String; var ex: SearchExposure; var kw: Double?; var matched = 0; var sem: Float? }
        var cands: [Int64: Cand] = [:]
        let post = prep.post, folderId = prep.folderId
        // Prefix / typo candidates are unverified until decrypted: a hidden one isn't counted as "restricted".
        func verified(_ rid: Int64) -> Bool { acc[rid]?.best.keys.contains { !fuzzy.contains($0) && !groups[$0].prefix } ?? false }
        func admit(_ rid: Int64, keyword: Bool) -> Cand? {
            guard let (m, mb) = rows[rid] else { return nil }
            switch o.caller {
            case .user:
                guard post.matchesStructure(m, folderId: folderId, labelName: o.labelName) else { return nil }
                return Cand(m: m, shown: m, mb: mb, ex: .full)
            case .ai(let gate):
                guard let (r, ex) = gate(m, mb) else {
                    var bare = m; bare.toRecipients = []; bare.ccRecipients = []
                    if keyword, verified(rid), q.to.isEmpty, post.matchesStructure(bare, folderId: folderId, labelName: o.labelName) { restricted += 1 }
                    return nil
                }
                guard post.matchesStructure(m, folderId: folderId, labelName: o.labelName) else { return nil }
                if !q.to.isEmpty && ex != .full { return nil }
                if !post.domains.isEmpty && !post.domainMatches(r, recipients: ex == .full) { return nil }
                if !post.strictTextMatches(r, subjectVisible: r.subject == m.subject, contentVisible: ex == .full) { return nil }   // SEARCHBOX-HOOK
                return Cand(m: m, shown: r, mb: mb, ex: ex)
            }
        }
        for (rid, _, _) in kwTop {
            guard var c = admit(rid, keyword: true), let a = acc[rid] else { continue }
            // Only what the index may hold for this row: a row whose details stay off disk is matched on its sender only.
            let pol = store.persistablePolicy(c.m)
            let indexed = pol.allowOfflineDetails && !pol.redactDetails
            let visible = Self.visibleTokens(c.shown, details: c.ex == .full && indexed, subject: indexed)
            var ok = Set<Int>()
            for gi in a.best.keys {
                let g = groups[gi]
                if fuzzy.contains(gi) {
                    if visible.contains(where: { SearchText.closeMatch($0, g.original) }) { ok.insert(gi) }
                } else if g.prefix {
                    if visible.contains(where: { $0.hasPrefix(g.original) || SearchText.closeMatch($0, g.original) })
                        || g.alternatives.dropFirst().contains(where: { visible.contains($0.term) }) { ok.insert(gi) }
                } else if case .user = o.caller {
                    ok.insert(gi)   // the user sees everything the index holds (incl. cached-body terms)
                } else if c.ex == .full || g.alternatives.contains(where: { visible.contains($0.term) }) {
                    // .ai full: indexed preview/body terms are content it may see; metadata: only visible words.
                    if c.ex == .full || visible.contains(a.best[gi]!.alt) { ok.insert(gi) }
                }
            }
            let (s, matched) = score(a, groupsOK: ok, metaOnly: c.ex != .full)
            guard s > 0 else { continue }
            c.kw = s; c.matched = matched
            cands[rid] = c
        }
        for s in semHits {
            guard var c = cands[s.rid] ?? admit(s.rid, keyword: false), c.ex == .full else { continue }
            guard post.matchesTokens(c.m) else { continue }
            c.sem = s.score
            cands[s.rid] = c
        }
        // 4. Soft natural dates ("last week", "gestern"): keep only items inside, unless nothing is.
        if nq.after != nil || nq.before != nil {
            let inside = cands.filter { e in (nq.after.map { e.value.m.received >= $0 } ?? true) && (nq.before.map { e.value.m.received < $0 } ?? true) }
            if !inside.isEmpty { cands = inside }
        }
        lap("decrypt")

        // 5. Fusion: weighted RRF(keyword, semantic) + sender / attachment / phrase hints + recency (+ proximity, user).
        let kwOrder = cands.filter { $0.value.kw != nil }.sorted { ($0.value.kw!, $0.value.m.received) > ($1.value.kw!, $1.value.m.received) }.map(\.key)
        let semOrder = cands.filter { $0.value.sem != nil }.sorted { $0.value.sem! > $1.value.sem! }.map(\.key)
        let kwRank = Dictionary(uniqueKeysWithValues: kwOrder.enumerated().map { ($1, $0 + 1) })
        let semRank = Dictionary(uniqueKeysWithValues: semOrder.enumerated().map { ($1, $0 + 1) })
        let isUser: Bool = { if case .user = o.caller { return true }; return false }()
        let maxKw = cands.values.compactMap(\.kw).max() ?? 1
        var hits: [SearchHit] = []
        for (rid, c) in cands {
            let kr = kwRank[rid], sr = semRank[rid]
            if kr == nil {   // semantic-only: a fallback when no keyword matched, and only confident, high-ranked ones
                guard kwRank.isEmpty, let sr, sr <= w.semanticOnlyMaxRank, (c.sem ?? 0) >= w.semanticOnlyMinScore else { continue }
            }
            let shown = c.shown
            var senderHit = false
            if !nq.senderWords.isEmpty, let f = shown.from {
                let st = Set(BlindIndex.tokenize(f.name) + BlindIndex.tokenize(f.address))
                senderHit = nq.senderWords.contains { sw in st.contains(sw) || SearchText.variants(sw).contains(where: st.contains) }
            }
            var phraseHit = false
            if !nq.phrases.isEmpty {
                let text = SearchText.phraseForm(shown.subject + " " + (c.ex == .full ? (shown.preview ?? "") : ""))
                phraseHit = nq.phrases.contains { text.contains($0) }
            }
            let s = SearchFusion.natural(keyword: (c.kw ?? 0) / max(maxKw, 1e-9), semantic: c.sem, sender: senderHit,
                                         attachment: nq.wantsAttachment && shown.hasAttachments, phrase: phraseHit,
                                         ageDays: now.timeIntervalSince(c.m.received) / 86_400, w: w)
            hits.append(SearchHit(message: shown, mailbox: c.mb, score: s, keywordRank: kr, semanticRank: sr, exposure: c.ex))
        }
        hits.sort { ($0.score, $0.message.received, $0.id) > ($1.score, $1.message.received, $1.id) }
        if isUser, let g = store.graph {
            var prox: [String: Double] = [:]
            for i in hits.indices.prefix(60) {
                guard let a = hits[i].message.from?.address.lowercased() else { continue }
                let p = prox[a] ?? g.proximity(a, now: now); prox[a] = p
                hits[i].score += w.proximity * p
            }
            let head = min(60, hits.count)
            hits.replaceSubrange(0..<head, with: hits[0..<head].sorted { ($0.score, $0.message.received, $0.id) > ($1.score, $1.message.received, $1.id) })
        }
        lap("fuse")
        let facets = Self.facets(hits, original: Dictionary(cands.values.map { ($0.m.id, $0.m) }, uniquingKeysWith: { a, _ in a }),
                                 graph: store.graph, limit: o.facetLimit, now: now, labelName: o.labelName, store: store, userNames: isUser)
        lap("facets")
        return SearchResult(hits: Array(hits.prefix(o.limit)), facets: facets, total: hits.count, restricted: restricted,
                            usedSemantic: !semHits.isEmpty, keywordCandidates: pool, semanticCandidates: semHits.count, timings: timings)
    }

    /// One alternative's BM25 contribution (sender+subject counts double, like `.all`).
    static func contrib(_ b: (meta: Int, prev: Int, idf: Double, kind: SearchTermGroup.Kind, alt: String),
                        _ stats: (n: Int, avgMeta: Double, avgPreview: Double), dl: Int64 = 0, metaOnly: Bool = false) -> Double {
        let f = Double(2 * b.meta + (metaOnly ? 0 : b.prev))
        guard f > 0 else { return 0 }
        let len = Double(2 * Int(dl & 0xFFFF) + (metaOnly ? 0 : Int(dl >> 16)))
        let avg = 2 * stats.avgMeta + (metaOnly ? 0 : stats.avgPreview)
        return b.idf * f * (k1 + 1) / (f + k1 * (1 - b_ + b_ * (dl == 0 ? 1 : len / max(avg, 1))))
    }
    static var b_: Double { b }

    /// Words the caller can see on the (possibly redacted) message.
    static func visibleTokens(_ m: MailMessage, details: Bool, subject: Bool = true) -> Set<String> {
        var v = Set<String>()
        if let f = m.from { v.formUnion(BlindIndex.tokenize(f.name)); v.formUnion(BlindIndex.tokenize(f.address)) }
        if subject { v.formUnion(BlindIndex.tokenize(m.subject)) }
        if details {
            if let p = m.preview { v.formUnion(BlindIndex.tokenize(p)) }
            for a in m.attachments where !a.isInline { v.formUnion(BlindIndex.tokenize(a.name)) }
        }
        for t in v { for h in SearchLexicon.heads(of: t) { v.insert(h) } }
        return v
    }
}
