import Foundation

// Hybrid local search: BM25 over the blind index + on-device semantic vectors, fused with reciprocal rank fusion,
// boosted by recency and (for the user only) graph proximity, with facets. Query language (compatible with
// mail_search's filters): free words, "quoted words", from: to: has:attachment label: before: after: company:
// project: folder: in: is:unread is:read.

// MARK: - Query

public struct SearchQuery: Sendable, Hashable {
    public var words: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    public var companies: [String] = []
    public var projects: [String] = []
    public var labels: [String] = []
    public var folder: String?
    public var hasAttachment: Bool?
    public var isUnread: Bool?
    public var after: Date?
    public var before: Date?
    /// The last word matches as a prefix (typing) unless the raw query ended with a space.
    public var prefixLast = true
    /// SEARCHQ: quoted multi-word phrases (folded), e.g. "Projekt Phoenix" → "projekt phoenix". Natural mode boosts them.
    public var phrases: [String] = []
    /// SEARCHQ: words an AI parse added (keywords / translations). Natural mode scores them as optional concepts:
    /// they can lift a match but never lower coverage.
    public var hintWords: [String] = []
    /// SEARCHBOX-HOOK: `subject:` words (strict; folded tokens, matched as prefixes of subject words) and `category:`
    /// names (strict, case-insensitive). Only checked where the persist policy lets the subject be searched.
    public var subjectWords: [String] = []
    public var categories: [String] = []
    public init() {}

    public var text: String { words.joined(separator: " ") }
    public var hasFilters: Bool {
        !from.isEmpty || !to.isEmpty || !companies.isEmpty || !projects.isEmpty || !labels.isEmpty || folder != nil
            || hasAttachment != nil || isUnread != nil || after != nil || before != nil
            || !subjectWords.isEmpty || !categories.isEmpty   // SEARCHBOX-HOOK
    }
    public var isEmpty: Bool { words.isEmpty && !hasFilters }

    /// Dates: yyyy-MM-dd, ISO-8601 date-time, or relative "7d" / "2w" / "3m" / "1y" (before:/after: now − n).
    public static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> SearchQuery {
        var q = SearchQuery()
        q.prefixLast = !raw.hasSuffix(" ")
        let segs = raw.split(separator: "\"", omittingEmptySubsequences: false)
        for (i, seg) in segs.enumerated() where i % 2 == 1 {
            if segs[i - 1].last == ":" { continue }   // SEARCHBOX-HOOK: from:"Anna Meier" is an operator value, not a phrase
            let f = SearchText.phraseForm(String(seg)); if f.contains(" ") { q.phrases.append(f) }
        }
        for tok in split(raw) {
            guard let c = tok.firstIndex(of: ":"), c != tok.startIndex else { q.words.append(tok); continue }
            let k = tok[..<c].lowercased(), v = String(tok[tok.index(after: c)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !v.isEmpty else { q.words.append(tok); continue }
            switch k {
            case "from": q.from.append(v.lowercased())
            case "to", "cc": q.to.append(v.lowercased())
            case "company", "org": q.companies.append(v.lowercased())
            case "project", "topic": q.projects.append(v)
            case "label": q.labels.append(v.lowercased())
            // SEARCHBOX-HOOK: Gmail / Outlook operator names for the main search box.
            case "subject": let ts = BlindIndex.tokenize(v); if ts.isEmpty { q.words.append(tok) } else { q.subjectWords += ts }
            case "category": q.categories.append(v.lowercased())
            case "hasattachment", "hasattachments": let y = ["yes", "true", "1"].contains(v.lowercased()); q.hasAttachment = y
            case "isread": q.isUnread = !["yes", "true", "1"].contains(v.lowercased())
            case "older_than", "older": if let d = date(v, now: now, calendar: calendar) { q.before = d } else { q.words.append(tok) }
            case "newer_than", "newer": if let d = date(v, now: now, calendar: calendar) { q.after = d } else { q.words.append(tok) }
            case "folder", "in": q.folder = v
            case "has": if v.lowercased().hasPrefix("attach") { q.hasAttachment = true } else if v.lowercased() == "noattachment" { q.hasAttachment = false } else { q.words.append(tok) }
            case "is": if v.lowercased() == "unread" { q.isUnread = true } else if v.lowercased() == "read" { q.isUnread = false } else { q.words.append(tok) }
            case "before": if let d = date(v, now: now, calendar: calendar) { q.before = d } else { q.words.append(tok) }
            case "after", "since": if let d = date(v, now: now, calendar: calendar) { q.after = d } else { q.words.append(tok) }
            default: q.words.append(tok)   // e.g. a URL or "re:" stays a word
            }
        }
        return q
    }

    static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); continue }
            if ch.isWhitespace && !quoted { if !cur.isEmpty { out.append(cur); cur = "" } } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func date(_ v: String, now: Date, calendar: Calendar) -> Date? {
        if let n = Int(v.dropLast()), n >= 0, let u = v.last {
            switch u {
            case "d": return calendar.date(byAdding: .day, value: -n, to: now)
            case "w": return calendar.date(byAdding: .day, value: -7 * n, to: now)
            case "m": return calendar.date(byAdding: .month, value: -n, to: now)
            case "y": return calendar.date(byAdding: .year, value: -n, to: now)
            default: break
            }
        }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: v) { return d }
        return ISO8601DateFormatter().date(from: v)
    }

    /// From the AI natural-language parser.
    public init(_ a: AISearchQuery) {
        words = a.terms.flatMap { $0.split(separator: " ").map(String.init) }
        if let f = a.from { from = [f.lowercased()] }
        after = a.after; before = a.before; hasAttachment = a.hasAttachments; folder = a.folder
        prefixLast = false
    }
}

// MARK: - Results

public enum SearchExposure: String, Sendable, Hashable { case full, metadata }

/// Who is asking. `.user` sees what the cache holds; `.ai` sees what its gate returns (nil = hidden), and content
/// signals (preview terms, vectors, recipients, withheld subjects) only count on items that are `.full` for it.
public enum SearchCaller: Sendable {
    case user
    case ai(@Sendable (MailMessage, String) -> (MailMessage, SearchExposure)?)
}

public struct SearchHit: Sendable, Hashable, Identifiable {
    public var message: MailMessage
    public var mailbox: String
    public var score: Double
    public var keywordRank: Int?
    public var semanticRank: Int?
    /// `.ai` callers: what the gate allowed (the message above is already redacted). `.user`: `.full`.
    public var exposure: SearchExposure
    public var id: String { message.id }
}

public struct FacetValue: Sendable, Hashable, Identifiable {
    public var key: String
    public var label: String
    public var count: Int
    public var id: String { key }
    /// The query operator that narrows to this value ("from:anna@x", "has:attachment", …).
    public var refinement: String?
}

public struct SearchFacets: Sendable, Hashable {
    public var people: [FacetValue] = []
    public var companies: [FacetValue] = []
    public var projects: [FacetValue] = []
    public var dates: [FacetValue] = []
    public var attachments: [FacetValue] = []
    public var labels: [FacetValue] = []
    public var folders: [FacetValue] = []
    public var mailboxes: [FacetValue] = []
    public var isEmpty: Bool { people.isEmpty && companies.isEmpty && projects.isEmpty && dates.isEmpty }
}

public struct SearchResult: Sendable {
    public var hits: [SearchHit]
    public var facets: SearchFacets
    /// Matching items after filters and the gate (before `limit`).
    public var total: Int
    /// `.ai`: candidates the gate hid (counted only).
    public var restricted: Int
    public var usedSemantic: Bool
    public var keywordCandidates: Int
    public var semanticCandidates: Int
    /// Stage timings in ms (keyword, semantic, decrypt, fuse, facets) for benches.
    public var timings: [String: Double] = [:]
}

// MARK: - Engine

public final class SearchEngine: @unchecked Sendable {
    public struct Options: Sendable {
        public var mailbox: String?
        public var limit = 50
        public var facetLimit = 8
        public var semantic = true
        public var caller: SearchCaller = .user
        public var now = Date()
        /// Label id → display name (nil = unknown label).
        public var labelName: @Sendable (String) -> String? = { _ in nil }
        /// SEARCHQ: `.all` = every word required (type-ahead, MCP, bulk); `.natural` = relaxed matching with
        /// DE/EN/FR/IT expansions, typo recovery, time/attachment/sender hints (Ask / Enter).
        public var match: MatchMode = .all
        /// Natural mode: expand words with the business lexicon (variants ß/ss, Umlaut digraphs always apply).
        public var expand = true
        public var weights = NaturalWeights()
        /// SEARCHBOX-HOOK: restrict to one folder (main-box "This folder" scope), applied before the limit.
        public var folderId: String?
        /// SEARCHBOX-HOOK: "quoted phrases" must occur (main box). Off: natural mode only boosts them (Ask / SearchHub).
        public var strictPhrases = false
        public init(mailbox: String? = nil, limit: Int = 50, caller: SearchCaller = .user) {
            self.mailbox = mailbox; self.limit = limit; self.caller = caller
        }
    }

    public enum MatchMode: Sendable, Hashable { case all, natural }
    public static let keywordPool = 3_000
    public static let decryptPool = 400
    static let k1 = 1.2, b = 0.75, rrfK = 60.0

    public let store: MailStore
    public init(store: MailStore) { self.store = store }

    public func search(_ raw: String, _ o: Options) -> SearchResult { search(SearchQuery.parse(raw, now: o.now), o) }

    public func search(_ q: SearchQuery, _ o: Options) -> SearchResult {
        let empty = SearchResult(hits: [], facets: SearchFacets(), total: 0, restricted: 0, usedSemantic: false, keywordCandidates: 0, semanticCandidates: 0)
        guard !q.isEmpty else { return empty }
        let key = store.indexKey
        let graph = store.graph

        // 1. Filters → exact blind tokens where possible, post-filters otherwise.
        // SEARCHQ: natural mode (relaxed matching, expansions, hints) has its own keyword stage.
        if o.match == .natural, !(q.words.isEmpty && q.hintWords.isEmpty) { return searchNatural(q, o) }
        guard let prep = prepareFilters(q, o) else { return empty }
        let filters = prep.filters, folderId = prep.folderId
        var post = prep.post

        // 2. Free words → scored terms (last one as prefix while typing).
        let terms = BlindIndex.tokenize(q.text)
        let prefixLast = q.prefixLast && (terms.last?.count ?? 0) >= BlindIndex.prefixLength
        let scored = terms.enumerated().map { i, t in BlindIndex.termHash(t, prefix: i == terms.count - 1 && prefixLast, key: key) }
        post.words = terms; post.prefixLast = prefixLast

        // 3. Keyword candidates + BM25.
        var clock = Date(), timings: [String: Double] = [:]
        func lap(_ k: String) { timings[k] = Date().timeIntervalSince(clock) * 1000; clock = Date() }
        let pool = (try? store.keywordCandidates(scored: scored, filters: filters, mailbox: o.mailbox, folderId: folderId,
                                                  after: q.after, before: q.before, limit: Self.keywordPool)) ?? []
        let stats = store.corpusStats()
        let idf = scored.map { h -> Double in
            let df = Double(store.documentFrequency(h)), n = Double(max(stats.n, 1))
            return log(1 + (n - df + 0.5) / (df + 0.5))
        }
        func bm25(_ h: KeywordHit, metaOnly: Bool) -> Double {
            guard !h.tf.isEmpty else { return 0 }
            let dl = Double(2 * h.dlMeta + (metaOnly ? 0 : h.dlPreview))
            let avg = 2 * stats.avgMeta + (metaOnly ? 0 : stats.avgPreview)
            var s = 0.0
            for (i, tf) in h.tf.enumerated() {
                let f = Double(2 * tf.meta + (metaOnly ? 0 : tf.preview))
                guard f > 0 else { continue }
                s += idf[i] * f * (Self.k1 + 1) / (f + Self.k1 * (1 - Self.b + Self.b * dl / max(avg, 1)))
            }
            return s
        }
        let ranked = terms.isEmpty ? pool : pool.sorted { (bm25($0, metaOnly: false), $0.received) > (bm25($1, metaOnly: false), $1.received) }
        let kwTop = Array(ranked.prefix(Self.decryptPool))
        lap("keyword")

        // 4. Semantic candidates (free text only).
        var semHits: [(rid: Int64, score: Float)] = []
        if o.semantic, !q.text.isEmpty, let sem = store.semantic, sem.embedder != nil {
            semHits = sem.search(q.text, mailbox: o.mailbox, k: 200)
        }
        lap("semantic")

        // 5. Decrypt, post-filter, gate.
        let rows = (try? store.rows(rids: Array(Set(kwTop.map(\.rid) + semHits.map(\.rid))))) ?? [:]
        var restricted = 0
        struct Cand { var m: MailMessage; var shown: MailMessage; var mb: String; var ex: SearchExposure; var kw: Double?; var sem: Float? }
        var cands: [Int64: Cand] = [:]
        func admit(_ rid: Int64, keyword: Bool) -> Cand? {
            if let c = cands[rid] { return c }
            guard let (m, mb) = rows[rid] else { return nil }
            switch o.caller {
            case .user:
                guard post.matchesStructure(m, folderId: folderId, labelName: o.labelName) else { return nil }
                return Cand(m: m, shown: m, mb: mb, ex: .full, kw: nil, sem: nil)
            case .ai(let gate):
                guard let (r, ex) = gate(m, mb) else {
                    // Count a hidden row only on what an AI caller could filter by anyway: never on its recipients.
                    var bare = m; bare.toRecipients = []; bare.ccRecipients = []
                    if keyword, q.to.isEmpty, post.matchesStructure(bare, folderId: folderId, labelName: o.labelName) { restricted += 1 }
                    return nil
                }
                guard post.matchesStructure(m, folderId: folderId, labelName: o.labelName) else { return nil }
                // Recipient filters may only look at what the caller can see.
                if !q.to.isEmpty && ex != .full { return nil }
                if !post.domains.isEmpty && !post.domainMatches(r, recipients: ex == .full) { return nil }
                if !post.strictTextMatches(r, subjectVisible: r.subject == m.subject, contentVisible: ex == .full) { return nil }   // SEARCHBOX-HOOK
                return Cand(m: m, shown: r, mb: mb, ex: ex, kw: nil, sem: nil)
            }
        }
        for h in kwTop {
            guard var c = admit(h.rid, keyword: true) else { continue }
            // Words must be visible to the caller: for .ai metadata items, only sender + (unwithheld) subject count.
            guard post.wordsMatch(c.shown, details: c.ex == .full) else { continue }
            c.kw = terms.isEmpty ? 0 : bm25(h, metaOnly: c.ex != .full)
            if !terms.isEmpty && c.kw == 0 { continue }
            cands[h.rid] = c
        }
        for s in semHits {
            guard var c = cands[s.rid] ?? admit(s.rid, keyword: false), c.ex == .full else { continue }
            guard post.matchesTokens(c.m) else { continue }
            c.sem = s.score
            cands[s.rid] = c
        }

        lap("decrypt")
        // 6. Fusion: RRF(BM25, semantic) + recency + proximity (user only: proximity is computed over all cached
        //    mail, so it's not used to order what an AI caller sees).
        let kwOrder = cands.filter { $0.value.kw != nil }.sorted { ($0.value.kw!, $0.value.m.received) > ($1.value.kw!, $1.value.m.received) }.map(\.key)
        let semOrder = cands.filter { $0.value.sem != nil }.sorted { $0.value.sem! > $1.value.sem! }.map(\.key)
        let kwRank = Dictionary(uniqueKeysWithValues: kwOrder.enumerated().map { ($1, $0 + 1) })
        let semRank = Dictionary(uniqueKeysWithValues: semOrder.enumerated().map { ($1, $0 + 1) })
        let isUser: Bool = { if case .user = o.caller { return true }; return false }()
        let now = o.now
        var hits: [SearchHit] = cands.map { rid, c in
            let kr = kwRank[rid], sr = semRank[rid]
            var s = 0.0
            if let kr { s += 1 / (Self.rrfK + Double(kr)) }
            if let sr { s += 1 / (Self.rrfK + Double(sr)) }
            let ageDays = max(0, now.timeIntervalSince(c.m.received) / 86_400)
            let recency = exp(-ageDays / 30)
            s += (terms.isEmpty ? 1.0 : 0.25) / (Self.rrfK + 1) * recency
            return SearchHit(message: c.shown, mailbox: c.mb, score: s, keywordRank: kr, semanticRank: sr, exposure: c.ex)
        }
        hits.sort { ($0.score, $0.message.received, $0.id) > ($1.score, $1.message.received, $1.id) }
        // Graph proximity (user only) re-orders the head: decoding person nodes is the expensive part, so only the top 60.
        if isUser, let g = graph {
            var prox: [String: Double] = [:]
            for i in hits.indices.prefix(60) {
                guard let a = hits[i].message.from?.address.lowercased() else { continue }
                let p = prox[a] ?? g.proximity(a, now: now); prox[a] = p
                hits[i].score += 0.25 / (Self.rrfK + 1) * p
            }
            let head = min(60, hits.count)
            hits.replaceSubrange(0..<head, with: hits[0..<head].sorted { ($0.score, $0.message.received, $0.id) > ($1.score, $1.message.received, $1.id) })
        }
        lap("fuse")

        // 7. Facets over everything that matched (after the gate).
        let facets = Self.facets(hits,
                                 original: Dictionary(cands.values.map { ($0.m.id, $0.m) }, uniquingKeysWith: { a, _ in a }),
                                 graph: graph, limit: o.facetLimit, now: now, labelName: o.labelName, store: store, userNames: isUser)
        lap("facets")
        return SearchResult(hits: Array(hits.prefix(o.limit)), facets: facets, total: hits.count, restricted: restricted,
                            usedSemantic: !semHits.isEmpty, keywordCandidates: pool.count, semanticCandidates: semHits.count, timings: timings)
    }

    /// Operators → exact blind filter tokens where possible, post-filters otherwise. nil: nothing can match.
    func prepareFilters(_ q: SearchQuery, _ o: Options) -> (filters: [Data], post: PostFilter, folderId: String?)? {
        let key = store.indexKey
        let graph = store.graph
        var filters: [Data] = []
        var post = PostFilter(q: q)
        // SEARCHBOX-HOOK: strict subject / category / phrase filters — exact blind tokens first (only rows whose
        // details are indexed can carry subject or preview terms), then verified on what the policy lets be searched.
        post.store = store
        post.strictPhrases = o.strictPhrases
        for w in q.subjectWords { filters.append(BlindIndex.termHash(w, prefix: w.count >= BlindIndex.prefixLength, key: key)) }
        for c in q.categories { filters.append(BlindIndex.filterHash("c:" + c, key: key)) }
        if o.strictPhrases { for p in q.phrases { for t in Set(p.split(separator: " ").map(String.init)) { filters.append(BlindIndex.termHash(t, prefix: false, key: key)) } } }
        for f in q.from {
            if f.contains("@") { filters.append(BlindIndex.filterHash("f:" + f, key: key)) }
            else { for t in BlindIndex.tokenize(f) { filters.append(BlindIndex.termHash(t, prefix: false, key: key)) } }
        }
        for t in q.to where t.contains("@") { filters.append(BlindIndex.filterHash("r:" + t, key: key)) }
        var domains: Set<String> = []
        for c in q.companies {
            let resolved = graph?.resolveCompany(c).map(\.domain) ?? []
            let ds = resolved.isEmpty ? (c.contains(".") ? [MailDomains.registrable(c)] : []) : resolved
            guard !ds.isEmpty else { return nil }
            domains.formUnion(ds.prefix(5))
        }
        post.domains = domains
        if domains.count == 1 { filters.append(BlindIndex.filterHash("d:" + domains.first!, key: key)) }
        var folderId: String? = o.folderId   // SEARCHBOX-HOOK
        if let p = q.projects.first {
            guard let pr = graph?.resolveProject(p).first else { return nil }
            switch pr.kind {
            case .category: filters.append(BlindIndex.filterHash("c:" + String(pr.id.dropFirst(4)), key: key)); post.category = String(pr.id.dropFirst(4))
            case .folder: let f = String(pr.id.dropFirst(4)); if folderId != nil && folderId != f { return nil }; folderId = f
            case .topic: filters.append(BlindIndex.termHash(String(pr.id.dropFirst(2)), prefix: false, key: key)); post.topicTerm = String(pr.id.dropFirst(2))
            }
        }
        if let fname = q.folder {
            let fs = (try? store.folders(mailbox: o.mailbox)) ?? []
            let n = fname.lowercased()
            guard let f = fs.first(where: { $0.id == fname || $0.wellKnown?.rawValue == n }) ?? fs.first(where: { $0.displayName.lowercased() == n })
                    ?? fs.first(where: { $0.displayName.lowercased().contains(n) }) else { return nil }
            if folderId != nil && folderId != f.id { return nil }
            folderId = f.id
        }
        if q.hasAttachment == true { filters.append(BlindIndex.filterHash("x:att", key: key)) }

        return (filters, post, folderId)
    }

    // MARK: Facets

    static func facets(_ hits: [SearchHit], original: [String: MailMessage], graph: CommGraph?, limit: Int, now: Date,
                       labelName: (String) -> String?, store: MailStore, userNames: Bool = true) -> SearchFacets {
        var people: [String: (String, Int)] = [:], companies: [String: Int] = [:], projects: [String: Int] = [:]
        var dates: [String: Int] = [:], att = (0, 0), labels: [String: Int] = [:], folders: [String: Int] = [:], mboxes: [String: Int] = [:]
        let topicIds = Set(graph?.topics(limit: 2_000).map(\.id) ?? [])
        var convProjects: [String: [String]] = [:]
        let folderNames = Dictionary(((try? store.folders()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for h in hits {
            let m = h.message, full = h.exposure == .full
            var addrs: [EmailAddress] = m.from.map { [$0] } ?? []
            if full { addrs += m.toRecipients + m.ccRecipients }
            var seenP = Set<String>(), seenC = Set<String>()
            for a in addrs {
                let k = a.address.lowercased()
                guard !k.isEmpty, seenP.insert(k).inserted else { continue }
                if let g = graph, g.isOwner(k, mailbox: h.mailbox) { continue }
                people[k] = (a.name.isEmpty ? k : a.name, (people[k]?.1 ?? 0) + 1)
                if let d = MailDomains.companyKey(for: k), seenC.insert(d).inserted { companies[d, default: 0] += 1 }
            }
            var pids = Set(m.categories.map { "cat:" + $0.lowercased() })
            if let f = folderNames[m.folderId], f.wellKnown == nil { pids.insert("fld:" + f.id) }
            // Topics come from the subject: only when the caller sees the real subject.
            if let g = graph, convProjects.count < 200 || convProjects[m.conversationId] != nil, original[m.id]?.subject == m.subject {
                let ps = convProjects[m.conversationId] ?? (g.conversation(m.conversationId)?.terms.map { "t:" + $0 }.filter { topicIds.contains($0) } ?? [])
                convProjects[m.conversationId] = ps
                let own = Set(BlindIndex.tokenize(m.subject))
                pids.formUnion(ps.filter { own.contains(String($0.dropFirst(2))) })
            }
            for p in pids { projects[p, default: 0] += 1 }
            let age = now.timeIntervalSince(m.received) / 86_400
            let bucket = age < 1 ? "today" : age < 7 ? "week" : age < 31 ? "month" : age < 366 ? "year" : "older"
            dates[bucket, default: 0] += 1
            if m.hasAttachments { att.0 += 1 } else { att.1 += 1 }
            labels[m.labelId.map { labelName($0) ?? "Restricted label" } ?? "No label", default: 0] += 1
            folders[folderNames[m.folderId]?.displayName ?? "Other", default: 0] += 1
            mboxes[h.mailbox, default: 0] += 1
        }
        func top(_ d: [String: Int], _ label: (String) -> String, _ refine: (String) -> String?) -> [FacetValue] {
            d.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map { FacetValue(key: $0.key, label: label($0.key), count: $0.value, refinement: refine($0.key)) }
        }
        var f = SearchFacets()
        f.people = people.sorted { ($0.value.1, $1.key) > ($1.value.1, $0.key) }.prefix(limit).map {
            FacetValue(key: $0.key, label: $0.value.0, count: $0.value.1, refinement: "from:" + $0.key)
        }
        f.companies = top(companies, { d in (userNames ? graph?.company(d)?.displayName : nil) ?? MailDomains.name(fromDomain: d) }, { "company:" + $0 })
        // Topic labels for AI callers are the bare (visible) term: the cluster's co-term may come from mail they can't see.
        f.projects = top(projects, { p in p.hasPrefix("t:") && !userNames ? String(p.dropFirst(2)) : (graph?.projectName(p) ?? p) }, { "project:" + $0 })
        let order = ["today", "week", "month", "year", "older"]
        let names = ["today": "Today", "week": "Last 7 days", "month": "Last 30 days", "year": "Last year", "older": "Older"]
        let days = ["today": "1d", "week": "7d", "month": "31d", "year": "1y"]
        f.dates = order.compactMap { k in dates[k].map { FacetValue(key: k, label: names[k]!, count: $0, refinement: days[k].map { "after:" + $0 }) } }
        if att.0 > 0 { f.attachments.append(FacetValue(key: "yes", label: "Has attachment", count: att.0, refinement: "has:attachment")) }
        if att.1 > 0 { f.attachments.append(FacetValue(key: "no", label: "No attachment", count: att.1, refinement: nil)) }
        f.labels = top(labels, { $0 }, { $0 == "No label" ? nil : "label:\"" + $0 + "\"" })
        f.folders = top(folders, { $0 }, { "folder:\"" + $0 + "\"" })
        f.mailboxes = top(mboxes, { $0 == "me" ? "My mailbox" : $0 }, { _ in nil })
        return f
    }
}

// MARK: - Post filters (on decrypted rows)

struct PostFilter {
    let q: SearchQuery
    var domains: Set<String> = []
    var category: String?
    var topicTerm: String?
    var words: [String] = []
    var prefixLast = false
    /// SEARCHBOX-HOOK: persist policy source for the strict subject / phrase checks; nil = no strict text checks pass.
    var store: MailStore?
    var strictPhrases = false
    init(q: SearchQuery) { self.q = q }

    /// SEARCHBOX-HOOK: `subject:` words and (strict) quoted phrases, on what may be searched for this row: a row whose
    /// details stay off disk (protected, private, no offline details) never matches on subject, preview or body.
    func strictTextMatches(_ m: MailMessage, subjectVisible: Bool = true, contentVisible: Bool = true) -> Bool {
        let phrases = strictPhrases ? q.phrases : []
        guard !q.subjectWords.isEmpty || !phrases.isEmpty else { return true }
        guard let store else { return false }
        let pol = store.persistablePolicy(m)
        let indexed = pol.allowOfflineDetails && !pol.redactDetails
        guard indexed, subjectVisible else { return false }
        let subj = BlindIndex.tokenize(m.subject)
        for w in q.subjectWords where !subj.contains(where: { $0.hasPrefix(w) }) { return false }
        guard !phrases.isEmpty else { return true }
        let text = " " + SearchText.phraseForm(m.subject + " " + (contentVisible ? (m.preview ?? "") : "")) + " "
        for p in phrases where !text.contains(" " + p + " ") {
            // Adjacency is checked on the cached body too (it's on disk only where the policy allows offline details).
            guard contentVisible, let body = store.indexBody(m.id),
                  (" " + SearchText.phraseForm(SearchText.indexableBody(body, isHTML: m.bodyIsHTML)) + " ").contains(" " + p + " ") else { return false }
        }
        return true
    }

    /// Structural filters every candidate (keyword or semantic) must pass.
    func matchesStructure(_ m: MailMessage, folderId: String?, labelName: (String) -> String?) -> Bool {
        if let a = q.after, m.received < a { return false }
        if let b = q.before, m.received >= b { return false }
        if let h = q.hasAttachment, m.hasAttachments != h { return false }
        if let u = q.isUnread, m.isRead == u { return false }
        if let folderId, m.folderId != folderId { return false }
        for f in q.from {
            let hay = ((m.from?.address ?? "") + " " + (m.from?.name ?? "")).lowercased()
            if f.contains("@") ? m.from?.address.lowercased() != f : !BlindIndex.tokenize(f).allSatisfy({ hay.contains($0) }) { return false }
        }
        for t in q.to {
            let rs = (m.toRecipients + m.ccRecipients).map { ($0.address + " " + $0.name).lowercased() }
            if !rs.contains(where: { $0.contains(t) }) { return false }
        }
        if !domains.isEmpty && !domainMatches(m, recipients: true) { return false }
        if let c = category, !m.categories.contains(where: { $0.lowercased() == c }) { return false }
        for c in q.categories where !m.categories.contains(where: { $0.lowercased() == c }) { return false }   // SEARCHBOX-HOOK
        if !strictTextMatches(m) { return false }   // SEARCHBOX-HOOK
        for l in q.labels {
            guard let id = m.labelId, let n = labelName(id)?.lowercased(), n.contains(l) else { return false }
        }
        return true
    }

    func domainMatches(_ m: MailMessage, recipients: Bool) -> Bool {
        var addrs = [m.from?.address ?? ""]
        if recipients { addrs += (m.toRecipients + m.ccRecipients).map(\.address) }
        return addrs.contains { a in MailDomains.companyKey(for: a).map(domains.contains) ?? false }
    }

    /// Token-level filters (for semantic hits, which didn't come through the token join).
    func matchesTokens(_ m: MailMessage) -> Bool {
        if let t = topicTerm, !BlindIndex.tokenize(m.subject).contains(t) { return false }
        return true
    }

    /// The free words must occur in what the caller can see (prefix for the last one while typing).
    func wordsMatch(_ shown: MailMessage, details: Bool) -> Bool {
        guard !words.isEmpty else { return true }
        var visible = Set<String>()
        if let f = shown.from { visible.formUnion(BlindIndex.tokenize(f.name)); visible.formUnion(BlindIndex.tokenize(f.address)) }
        visible.formUnion(BlindIndex.tokenize(shown.subject))
        if details, let p = shown.preview { visible.formUnion(BlindIndex.tokenize(p).prefix(BlindIndex.maxPreviewTokens)) }
        for (i, w) in words.enumerated() {
            if i == words.count - 1 && prefixLast { if !visible.contains(where: { $0.hasPrefix(w) }) { return false } }
            else if !visible.contains(w) { return false }
        }
        return true
    }
}
