import Foundation
import SQLite3
import CryptoKit
import CalendarCore

// Search-side schema of the MailStore: BM25 counts on the blind index, graph enable/backfill, keyword candidates.
//
// On disk (all in the same SQLite file):
//  * tokens.w   — per (blind token, row): term frequency, low nibble = sender+subject, high nibble = preview (≤ 15 each)
//  * messages.dl — per row: token count, low 16 bits = sender+subject, high = preview
//  * g_node     — CommGraph nodes, HMAC key + kind + AES-GCM payload
//  * vecs / vec_pending — SemanticIndex (sealed int8 vectors; padded markers for rows that may not be embedded)
// Document frequency is the row count per token hash, which the blind index already exposes; it's computed with
// COUNT(*) on the (h, rid) primary key and cached in memory, never written separately.

enum SearchIndexVersion {
    static let key = "search-index-version"
    /// 2 = weighted tokens (w), doc length (dl), exact filter tokens (f:, r:, d:, c:, x:att).
    /// 3 (SEARCHQ) = every preview term, compound heads, attachment names, cached-body terms.
    static let current = "3"
    static let reindexCursorKey = "search-reindex-cursor"
    static let graphVersionKey = "graph-version"
    static let graphCursorKey = "graph-backfill-cursor"
}

public struct KeywordHit: Sendable, Hashable {
    public var rid: Int64
    public var received: Int64
    /// Per scored term: (sender+subject tf, preview tf).
    public var tf: [(meta: Int, preview: Int)]
    public var dlMeta: Int
    public var dlPreview: Int
    public static func == (a: Self, b: Self) -> Bool { a.rid == b.rid }
    public func hash(into h: inout Hasher) { h.combine(rid) }
}

extension MailStore {
    func migrateSearchSchema() throws {
        func columns(_ table: String) throws -> Set<String> {
            Set(try query("PRAGMA table_info(\(table))") { storeText($0, 1) })
        }
        if !(try columns("tokens")).contains("w") { try exec("ALTER TABLE tokens ADD COLUMN w INTEGER NOT NULL DEFAULT 1") }
        if !(try columns("messages")).contains("dl") { try exec("ALTER TABLE messages ADD COLUMN dl INTEGER NOT NULL DEFAULT 0") }
        if try value(for: SearchIndexVersion.key) == nil {
            // Empty store → already current. Rows from an older build → resumable reindex (`reindexStep`).
            if (try scalarInt("SELECT COUNT(*) FROM messages") ?? 0) == 0 { try setValue(SearchIndexVersion.current, for: SearchIndexVersion.key) }
            else { try setValue("0", for: SearchIndexVersion.reindexCursorKey) }
        }
    }

    func searchAfterWipe() throws {
        try setValue(SearchIndexVersion.current, for: SearchIndexVersion.key)
        if graph != nil { try setValue(CommGraph.version, for: SearchIndexVersion.graphVersionKey) }
        if stories != nil { try setValue(StoryEngine.version, for: StoryEngine.versionKey) }   // STORIES
        graphBackfillCursor = .max
    }

    /// The row is about to go: take its contribution out of the graph and drop its vector (inside a transaction).
    func forgetIndexed(rid: Int64) throws {
        if let graph, rid <= graphBackfillCursor,
           let row = try query("SELECT mailbox, payload FROM messages WHERE rid=?", [.int(rid)], { s in (storeText(s, 0), storeBlob(s, 1)) }).first,
           let m = try? unseal(MailMessage.self, row.1) {
            graph.change(old: m, new: nil, oldMailbox: row.0, newMailbox: row.0)
        }
        try semantic?.remove(rid: rid)
        try stories?.remove(rid: rid)   // STORIES
    }

    // MARK: Graph

    /// Attach the communication graph. `owners`: the signed-in address + shared mailbox addresses. Rows already in
    /// the store are counted by `graphBackfillStep` (resumable); new writes are diffed immediately.
    @discardableResult
    public func enableCommGraph(owners: Set<String>, internalDomains: Set<String>) throws -> CommGraph {
        try locked {
            if let g = graph { g.setOwners(owners, internalDomains: internalDomains); return g }
            let g = CommGraph(store: self, indexKey: indexKey, owners: owners, internalDomains: internalDomains)
            graph = g
            if try value(for: SearchIndexVersion.graphVersionKey) == CommGraph.version {
                graphBackfillCursor = .max
            } else if (try scalarInt("SELECT COUNT(*) FROM messages") ?? 0) == 0 {
                try exec("DELETE FROM g_node")
                try setValue(CommGraph.version, for: SearchIndexVersion.graphVersionKey)
                graphBackfillCursor = .max
            } else {
                if try value(for: SearchIndexVersion.graphCursorKey) == nil { try exec("DELETE FROM g_node") }
                graphBackfillCursor = Int64(try value(for: SearchIndexVersion.graphCursorKey) ?? "0") ?? 0
            }
            return g
        }
    }

    public var graphBackfillDone: Bool { locked { graph != nil && graphBackfillCursor == .max } }

    /// Count up to `maxRows` not-yet-visited rows into the graph. Returns true when the graph is complete.
    @discardableResult
    public func graphBackfillStep(maxRows: Int = 5_000) throws -> Bool {
        var done = false
        try transaction {
            guard let graph, graphBackfillCursor != .max else { done = true; return }
            let rows = try query("SELECT rid, mailbox, payload FROM messages WHERE rid > ? ORDER BY rid LIMIT ?",
                                 [.int(graphBackfillCursor), .int(Int64(maxRows))]) { s in
                (sqlite3_column_int64(s, 0), storeText(s, 1), storeBlob(s, 2))
            }
            for (rid, mb, payload) in rows {
                if let m = try? unseal(MailMessage.self, payload) { graph.change(old: nil, new: m, oldMailbox: mb, newMailbox: mb) }
                graphBackfillCursor = rid
            }
            try graph.flush()
            if rows.count < maxRows {
                graphBackfillCursor = .max
                try setValue(nil, for: SearchIndexVersion.graphCursorKey)
                try setValue(CommGraph.version, for: SearchIndexVersion.graphVersionKey)
                done = true
            } else {
                try setValue(String(graphBackfillCursor), for: SearchIndexVersion.graphCursorKey)
            }
        }
        return done
    }

    /// Full rebuild (e.g. owners changed). Resumable through `graphBackfillStep`.
    public func rebuildCommGraph() throws {
        try transaction {
            guard let graph else { return }
            graph.wipe()
            try exec("DELETE FROM g_node")
            try setValue(nil, for: SearchIndexVersion.graphVersionKey)
            try setValue("0", for: SearchIndexVersion.graphCursorKey)
            graphBackfillCursor = 0
        }
    }

    // MARK: Semantic

    @discardableResult
    public func enableSemanticIndex(embedder: TextEmbedder?, windowDays: Int = 90, policy: SemanticIndex.EmbedPolicy?) -> SemanticIndex {
        locked {
            if let s = semantic { s.configure(embedder: embedder, windowDays: windowDays, policy: policy); return s }
            let s = SemanticIndex(store: self)
            s.configure(embedder: embedder, windowDays: windowDays, policy: policy)
            semantic = s
            return s
        }
    }

    // MARK: BM25 index maintenance

    public var searchIndexCurrent: Bool { (try? value(for: SearchIndexVersion.key)) == SearchIndexVersion.current }

    /// Re-tokenise rows written by an older build (resumable, newest rows last). Returns true when current.
    @discardableResult
    public func reindexStep(maxRows: Int = 5_000) throws -> Bool {
        if searchIndexCurrent { return true }
        var done = false
        try transaction {
            let cursor = Int64(try value(for: SearchIndexVersion.reindexCursorKey) ?? "0") ?? 0
            let rows = try query("SELECT rid, payload FROM messages WHERE rid > ? ORDER BY rid LIMIT ?", [.int(cursor), .int(Int64(maxRows))]) { s in
                (sqlite3_column_int64(s, 0), storeBlob(s, 1))
            }
            let del = try prepare("DELETE FROM tokens WHERE rid=?"); defer { sqlite3_finalize(del) }
            let ins = try prepare("INSERT OR IGNORE INTO tokens(h,rid,w) VALUES(?,?,?)"); defer { sqlite3_finalize(ins) }
            var last = cursor
            for (rid, payload) in rows {
                last = rid
                guard let m = try? unseal(MailMessage.self, payload) else { continue }
                let pol = persistablePolicy(m)
                let details = pol.allowOfflineDetails && !pol.redactDetails
                let ix = BlindIndex.weighted(for: m, details: details, key: indexKey, body: details ? indexBody(m.id) : nil)
                try bindAndStep(del, [.int(rid)])
                for (h, w) in ix.tokens { try bindAndStep(ins, [.blob(h), .int(rid), .int(Int64(w))]) }
                try run("UPDATE messages SET dl=? WHERE rid=?", [.int(ix.dl), .int(rid)])
            }
            if rows.count < maxRows {
                try setValue(nil, for: SearchIndexVersion.reindexCursorKey)
                try setValue(SearchIndexVersion.current, for: SearchIndexVersion.key)
                done = true
            } else { try setValue(String(last), for: SearchIndexVersion.reindexCursorKey) }
        }
        bumpSearchGeneration()
        return done
    }

    // MARK: Keyword candidates (BM25 inputs)

    /// Newest-first rows matching EVERY hash in `scored` + `filters`, with term frequencies of `scored`.
    /// Bounded by `limit` (BM25 is then computed over these candidates by the caller).
    func keywordCandidates(scored: [Data], filters: [Data], mailbox: String?, folderId: String?,
                           after: Date?, before: Date?, limit: Int) throws -> [KeywordHit] {
        let all = scored + filters
        var where_: [String] = [], params: [Bind] = []
        func addBounds() {
            if let mailbox { where_.append("m.mailbox=?"); params.append(.text(mailbox)) }
            if let folderId { where_.append("m.folder_id=?"); params.append(.text(folderId)) }
            if let after { where_.append("m.received>=?"); params.append(.int(Int64(after.timeIntervalSince1970))) }
            if let before { where_.append("m.received<?"); params.append(.int(Int64(before.timeIntervalSince1970))) }
        }
        if all.isEmpty {
            addBounds()
            let sql = "SELECT m.rid, m.received, m.dl FROM messages m\(mailbox != nil ? " INDEXED BY messages_by_mailbox" : "")"
                + (where_.isEmpty ? "" : " WHERE " + where_.joined(separator: " AND ")) + " ORDER BY m.received DESC LIMIT ?"
            params.append(.int(Int64(limit)))
            return try query(sql, params) { s in
                let dl = sqlite3_column_int64(s, 2)
                return KeywordHit(rid: sqlite3_column_int64(s, 0), received: sqlite3_column_int64(s, 1), tf: [],
                                  dlMeta: Int(dl & 0xFFFF), dlPreview: Int(dl >> 16))
            }
        }
        // Drive from the narrowest hash.
        let dfs = all.map { documentFrequency($0) }
        guard let minDf = dfs.min(), minDf > 0 else { return [] }
        let driver = dfs.firstIndex(of: minDf)!
        var order = [driver] + all.indices.filter { $0 != driver }
        order = order.map { $0 }
        var sql = "SELECT t0.rid, m.received, m.dl"
        for (j, i) in order.enumerated() where i < scored.count { sql += ", t\(j).w AS w\(i)" }
        sql += " FROM tokens t0"
        for j in 1..<max(1, order.count) where order.count > 1 {
            sql += " JOIN tokens t\(j) ON t\(j).h=? AND t\(j).rid=t0.rid"
            params.append(.blob(all[order[j]]))
        }
        sql += " JOIN messages m ON m.rid=t0.rid WHERE t0.h=?"
        params.append(.blob(all[order[0]]))
        addBounds()
        if !where_.isEmpty { sql += " AND " + where_.joined(separator: " AND ") }
        sql += " ORDER BY m.received DESC LIMIT ?"
        params.append(.int(Int64(limit)))
        // Column order of the w's follows `order`; map back to scored index.
        let scoredCols = order.enumerated().filter { $0.element < scored.count }
        return try query(sql, params) { s in
            var tf = Array(repeating: (meta: 0, preview: 0), count: scored.count)
            for (c, (_, i)) in scoredCols.enumerated() {
                let w = Int(sqlite3_column_int64(s, Int32(3 + c)))
                tf[i] = (w & 0xF, w >> 4)
            }
            let dl = sqlite3_column_int64(s, 2)
            return KeywordHit(rid: sqlite3_column_int64(s, 0), received: sqlite3_column_int64(s, 1), tf: tf,
                              dlMeta: Int(dl & 0xFFFF), dlPreview: Int(dl >> 16))
        }
    }

    /// SEARCHQ: one scored hash's postings (newest first, bounded), restricted to rows carrying every `filters` hash.
    /// Natural mode ORs these per query concept instead of intersecting all terms.
    func postings(_ h: Data, filters: [Data], mailbox: String?, folderId: String?, after: Date?, before: Date?,
                  limit: Int) throws -> [(rid: Int64, received: Int64, dl: Int64, w: Int)] {
        var sql: String, params: [Bind] = []
        // SEARCHBOX-HOOK: a selective filter (from:, category:, subject: …) drives the join when it has fewer rows than
        // the term: "invoice from:anna@x" walks Anna's rows, not every "invoice" posting (docs/SEARCH-QUALITY.md).
        let fdf = filters.map { documentFrequency($0) }
        if let d = fdf.indices.min(by: { fdf[$0] < fdf[$1] }), fdf[d] < documentFrequency(h) {
            sql = "SELECT t0.rid, m.received, m.dl, t0.w FROM tokens d0 CROSS JOIN tokens t0 ON t0.h=? AND t0.rid=d0.rid"
            params.append(.blob(h))
            for (j, f) in filters.enumerated() where j != d { sql += " JOIN tokens f\(j) ON f\(j).h=? AND f\(j).rid=d0.rid"; params.append(.blob(f)) }
            sql += " JOIN messages m ON m.rid=d0.rid WHERE d0.h=?"; params.append(.blob(filters[d]))
        } else {
            sql = "SELECT t0.rid, m.received, m.dl, t0.w FROM tokens t0"
            for (j, f) in filters.enumerated() { sql += " JOIN tokens f\(j) ON f\(j).h=? AND f\(j).rid=t0.rid"; params.append(.blob(f)) }
            sql += " JOIN messages m ON m.rid=t0.rid WHERE t0.h=?"; params.append(.blob(h))
        }
        if let mailbox { sql += " AND m.mailbox=?"; params.append(.text(mailbox)) }
        if let folderId { sql += " AND m.folder_id=?"; params.append(.text(folderId)) }
        if let after { sql += " AND m.received>=?"; params.append(.int(Int64(after.timeIntervalSince1970))) }
        if let before { sql += " AND m.received<?"; params.append(.int(Int64(before.timeIntervalSince1970))) }
        sql += " ORDER BY m.received DESC LIMIT ?"; params.append(.int(Int64(limit)))
        return try query(sql, params) { s in
            (sqlite3_column_int64(s, 0), sqlite3_column_int64(s, 1), sqlite3_column_int64(s, 2), Int(sqlite3_column_int64(s, 3)))
        }
    }

    /// Rows by rid (sealed payloads opened), with their mailbox.
    func rows(rids: [Int64]) throws -> [Int64: (MailMessage, String)] {
        var out: [Int64: (MailMessage, String)] = [:]
        var i = 0
        while i < rids.count {
            let chunk = Array(rids[i..<min(i + 400, rids.count)])
            let sql = "SELECT rid, mailbox, payload FROM messages WHERE rid IN (" + chunk.map { _ in "?" }.joined(separator: ",") + ")"
            for (rid, mb, d) in try query(sql, chunk.map { .int($0) }, { s in (sqlite3_column_int64(s, 0), storeText(s, 1), storeBlob(s, 2)) }) {
                if let m = try? unseal(MailMessage.self, d) { out[rid] = (m, mb) }
            }
            i += 400
        }
        return out
    }

    func rid(forMessageId id: String) -> Int64? {
        (try? query("SELECT rid FROM messages WHERE id=?", [.text(id)]) { sqlite3_column_int64($0, 0) })?.first
    }

    /// Row count per token hash (= document frequency). Cached per write generation.
    func documentFrequency(_ h: Data) -> Int {
        locked {
            if dfGeneration != searchGeneration { dfCache = [:]; dfGeneration = searchGeneration }
            if let v = dfCache[h] { return v }
            let v = Int((try? scalarInt("SELECT COUNT(*) FROM tokens WHERE h=?", [.blob(h)])) ?? 0 ?? 0)
            dfCache[h] = v
            return v
        }
    }

    /// N and average field lengths (cached for 60 s or until the row count moves by > 1 %).
    func corpusStats() -> (n: Int, avgMeta: Double, avgPreview: Double) {
        locked {
            if let c = statsCache, Date().timeIntervalSince(c.at) < 300 { return c.v }
            // N exactly; average lengths from the newest 20k rows (a full scan of a 1M-row table under the lock is
            // the kind of stall the 5-minute cache would otherwise hide).
            let n = Int((try? scalarInt("SELECT COUNT(*) FROM messages")) ?? 0 ?? 0)
            let r = (try? query("SELECT AVG(dl & 65535), AVG(dl >> 16) FROM (SELECT dl FROM messages ORDER BY rid DESC LIMIT 20000)") { s in
                (n, sqlite3_column_double(s, 0), sqlite3_column_double(s, 1))
            })?.first ?? (0, 0, 0)
            let v = (r.0, max(1, r.1), max(1, r.2))
            statsCache = (Date(), v)
            return v
        }
    }

    /// Cached body for the index (SEARCHQ), without touching the LRU order. nil when not cached.
    func indexBody(_ id: String) -> String? { try? body(messageId: id, touch: false) }

    func persistablePolicy(_ m: MailMessage) -> ContentPolicy {
        let p = persistPolicyValue
        let mb = folderMailbox[m.folderId] ?? "me"
        return p?(m, mb) ?? MailContentPolicy.failClosed(for: m)
    }
}

// MARK: - Weighted blind tokens

extension BlindIndex {
    /// Filter tokens (exact, not scored): sender address, recipient addresses, sender/recipient company domains,
    /// categories, attachments. Recipients only exist on rows whose details may be persisted.
    static func filterTerms(for m: MailMessage, details: Bool) -> [String] {
        var out: [String] = []
        if let f = m.from?.address.lowercased(), !f.isEmpty {
            out.append("f:" + f)
            if let d = MailDomains.companyKey(for: f) { out.append("d:" + d) }
        }
        if details {
            for r in m.toRecipients + m.ccRecipients {
                let a = r.address.lowercased()
                guard !a.isEmpty else { continue }
                out.append("r:" + a)
                if let d = MailDomains.companyKey(for: a) { out.append("d:" + d) }
            }
        }
        for c in m.categories where !c.isEmpty { out.append("c:" + c.lowercased()) }
        if m.hasAttachments { out.append("x:att") }
        return out
    }

    /// Token hash → packed tf (low nibble sender+subject(+attachment names), high nibble preview(+cached body)), plus
    /// packed doc length. SEARCHQ: v3 indexes every preview term, German compound heads ("serverumzug" → "umzug"),
    /// attachment names and the first `bodyIndexChars` of a cached body — all only when `details` (the persist policy
    /// allows offline details), so nothing the policy keeps off disk becomes searchable.
    static func weighted(for m: MailMessage, details: Bool, key: SymmetricKey, body: String? = nil) -> (tokens: [Data: UInt8], dl: Int64) {
        var metaTf: [String: Int] = [:], prevTf: [String: Int] = [:]
        var metaLen = 0, prevLen = 0
        func addMeta(_ ts: [String]) { for t in ts { metaTf[t, default: 0] += 1; metaLen += 1; for h in SearchLexicon.heads(of: t) { metaTf[h, default: 0] += 1 } } }
        func addPrev(_ ts: [String]) { for t in ts { prevTf[t, default: 0] += 1; prevLen += 1; for h in SearchLexicon.heads(of: t) { prevTf[h, default: 0] += 1 } } }
        if let f = m.from { addMeta(tokenize(f.name) + tokenize(f.address)) }
        if details {
            addMeta(tokenize(m.subject))
            addMeta(m.attachments.filter { !$0.isInline }.prefix(10).flatMap { tokenize($0.name) })
            if let p = m.preview { addPrev(Array(tokenize(p).prefix(maxPreviewTokens))) }
            if let body, !body.isEmpty { addPrev(Array(tokenize(SearchText.indexableBody(body, isHTML: m.bodyIsHTML)).prefix(maxBodyTokens))) }
        }
        var acc: [Data: (Int, Int)] = [:]
        for (t, n) in metaTf {
            acc[hmac("t:" + t, key: key), default: (0, 0)].0 += n
            if t.count >= prefixLength { acc[hmac("p:" + String(t.prefix(prefixLength)), key: key), default: (0, 0)].0 += n }
        }
        for (t, n) in prevTf {
            acc[hmac("t:" + t, key: key), default: (0, 0)].1 += n
            if t.count >= prefixLength { acc[hmac("p:" + String(t.prefix(prefixLength)), key: key), default: (0, 0)].1 += n }
        }
        var out: [Data: UInt8] = [:]
        for (h, (a, b)) in acc { out[h] = UInt8(min(15, a) | (min(15, b) << 4)) }
        for t in filterTerms(for: m, details: details) { out[hmac(t, key: key)] = 0 }
        return (out, Int64(min(65_535, metaLen)) | (Int64(min(65_535, prevLen)) << 16))
    }

    /// Hash of a scored query term or prefix.
    static func termHash(_ t: String, prefix: Bool, key: SymmetricKey) -> Data {
        prefix ? hmac("p:" + String(t.prefix(prefixLength)), key: key) : hmac("t:" + t, key: key)
    }
    static func filterHash(_ t: String, key: SymmetricKey) -> Data { hmac(t, key: key) }
}

extension Array where Element == String {
    /// First `n` distinct elements in order (same set as `Array(tokenize(p)).prefix(n)` over a Set union).
    func uniquedPrefix(_ n: Int) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for e in self where seen.insert(e).inserted { out.append(e); if out.count == n { break } }
        return out
    }
}

// MARK: - Exact token lookups (people / company / project context)

/// One exact blind-index token. `recipient` / `domain`-via-recipient only exist on rows whose details are cached.
public enum SearchToken: Sendable, Hashable {
    case from(String), recipient(String), domain(String), category(String), term(String), attachment
    var hashInput: String {
        switch self {
        case .from(let a): "f:" + a.lowercased()
        case .recipient(let a): "r:" + a.lowercased()
        case .domain(let d): "d:" + d.lowercased()
        case .category(let c): "c:" + c.lowercased()
        case .term(let t): "t:" + (BlindIndex.tokenize(t).first ?? t.lowercased())
        case .attachment: "x:att"
        }
    }
}

extension MailStore {
    /// Newest-first headers carrying EVERY token, optionally in one mailbox. Bounded by `limit`.
    public func messages(matching tokens: [SearchToken], mailbox: String?, limit: Int = 1_000) -> [MailMessage] {
        guard !tokens.isEmpty else { return [] }
        let hs = tokens.map { BlindIndex.filterHash($0.hashInput, key: indexKey) }
        guard let hits = try? keywordCandidates(scored: [], filters: hs, mailbox: mailbox, folderId: nil, after: nil, before: nil, limit: limit),
              let rows = try? rows(rids: hits.map(\.rid)) else { return [] }
        return hits.compactMap { rows[$0.rid]?.0 }
    }

    /// How many cached headers carry the token (document frequency; counts only).
    public func count(matching token: SearchToken) -> Int { documentFrequency(BlindIndex.filterHash(token.hashInput, key: indexKey)) }
}
