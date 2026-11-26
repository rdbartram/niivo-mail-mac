import Foundation
import SQLite3
import CalendarCore
import NaturalLanguage

// MARK: - Embedders

/// One text embedded in one vector space (NLEmbedding spaces are per language and not comparable across languages).
public struct EmbeddedText: Sendable, Hashable {
    public var space: UInt8
    public var vector: [Float]
    public init(space: UInt8, vector: [Float]) { self.space = space; self.vector = vector }
}

public protocol TextEmbedder: Sendable {
    /// Document vector (nil → can't embed, e.g. language not supported).
    func embed(_ text: String) -> EmbeddedText?
    /// Query vectors, one per space that should be searched.
    func embedQuery(_ text: String, spaces: Set<UInt8>) -> [EmbeddedText]
}

/// Apple on-device sentence embeddings (`NLEmbedding.sentenceEmbedding(for:)`). Checked on macOS 27.0.1:
/// en (512-d) and de, fr, it, pt (640-d) are present; es, nl, … are not. Each language is its own space, so a German
/// query only matches German mail semantically (BM25 still matches across languages on shared terms).
public final class AppleSentenceEmbedder: TextEmbedder, @unchecked Sendable {
    public static let candidates: [(NLLanguage, UInt8)] = [(.english, 1), (.german, 2), (.french, 3), (.italian, 4), (.portuguese, 5)]
    private let lock = NSLock()
    private var models: [UInt8: NLEmbedding] = [:]
    private let languages: [NLLanguage: UInt8]

    public init?() {
        var l: [NLLanguage: UInt8] = [:]
        for (lang, id) in Self.candidates where NLEmbedding.sentenceEmbedding(for: lang) != nil { l[lang] = id }
        guard !l.isEmpty else { return nil }
        languages = l
    }

    /// Languages with an on-device sentence model, and their dimension.
    public static func availableLanguages() -> [(language: String, dimension: Int)] {
        candidates.compactMap { c in NLEmbedding.sentenceEmbedding(for: c.0).map { (c.0.rawValue, $0.dimension) } }
    }

    private func model(_ space: UInt8) -> NLEmbedding? {
        lock.lock(); defer { lock.unlock() }
        if let m = models[space] { return m }
        guard let lang = languages.first(where: { $0.value == space })?.key, let m = NLEmbedding.sentenceEmbedding(for: lang) else { return nil }
        models[space] = m
        return m
    }

    func space(for text: String) -> UInt8? {
        let r = NLLanguageRecognizer()
        r.languageConstraints = Array(languages.keys)
        r.processString(text)
        return r.dominantLanguage.flatMap { languages[$0] } ?? languages[.english]
    }

    private func vector(_ text: String, _ space: UInt8) -> [Float]? {
        guard let m = model(space) else { return nil }
        lock.lock(); defer { lock.unlock() }   // NLEmbedding isn't documented as thread-safe
        return m.vector(for: text)?.map(Float.init)
    }

    public func embed(_ text: String) -> EmbeddedText? {
        guard let s = space(for: text), let v = vector(text, s) else { return nil }
        return EmbeddedText(space: s, vector: v)
    }

    public func embedQuery(_ text: String, spaces: Set<UInt8>) -> [EmbeddedText] {
        spaces.sorted().compactMap { s in vector(text, s).map { EmbeddedText(space: s, vector: $0) } }
    }
}

// MARK: - Semantic index

/// Encrypted int8 vectors for subject + preview, maintained beside the blind index.
///
/// * Only rows the embed policy allows (the app passes the on-device AI gate: `exposure(.onDevice) == .content`) and
///   only inside the semantic window are embedded. Default policy = nil → nothing is embedded (fail closed).
/// * `vecs(rid, payload)`: payload = AES-GCM(space u8 · scale f32 · 640 × int8). Rows the policy refuses get a
///   marker of the SAME sealed size, so the file doesn't reveal which rows were embeddable.
/// * Embedding runs in `catchUp` (background, outside the store lock); writes only queue the row in `vec_pending`.
/// * Search is brute-force cosine over an in-memory int8 matrix loaded on first use and dropped on lock/wipe.
public final class SemanticIndex: @unchecked Sendable {
    public typealias EmbedPolicy = @Sendable (MailMessage, String) -> Bool
    public static let dimension = 640
    static let payloadBytes = 1 + 4 + dimension

    unowned let store: MailStore
    public private(set) var embedder: TextEmbedder?
    var policy: EmbedPolicy?
    public private(set) var windowDays = 90
    private var matrix: Matrix?
    /// Per-rid change counter so a vector computed from a stale row isn't written.
    private var pendingGen: Int64 = 0

    init(store: MailStore) { self.store = store }

    func configure(embedder: TextEmbedder?, windowDays: Int, policy: EmbedPolicy?) {
        store.locked { self.embedder = embedder; self.windowDays = windowDays; self.policy = policy }
    }

    // MARK: Write path (inside the store transaction)

    static func contentChanged(_ a: MailMessage, _ b: MailMessage) -> Bool {
        a.subject != b.subject || a.preview != b.preview || a.labelId != b.labelId || a.isPrivate != b.isPrivate
            || a.received != b.received || a.folderId != b.folderId
    }

    func rowChanged(rid: Int64, old: MailMessage?, new: MailMessage, mailbox: String) throws {
        if let old, !Self.contentChanged(old, new) { return }
        try remove(rid: rid)
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        guard new.received >= cutoff else { return }
        pendingGen += 1
        try store.run("INSERT INTO vec_pending(rid) VALUES(?) ON CONFLICT(rid) DO NOTHING", [.int(rid)])
        pendingVersion[rid] = pendingGen
    }
    private var pendingVersion: [Int64: Int64] = [:]

    func remove(rid: Int64) throws {
        try store.run("DELETE FROM vecs WHERE rid=?", [.int(rid)])
        try store.run("DELETE FROM vec_pending WHERE rid=?", [.int(rid)])
        pendingVersion.removeValue(forKey: rid)
        matrix?.remove(rid)
    }

    func wipe() { matrix = nil; pendingVersion = [:] }
    /// Drop the decrypted in-memory matrix (app lock, rollback). Reloaded on the next query.
    public func dropMemory() { store.locked { matrix = nil } }

    /// Labels / AI policy changed: forget every vector and queue the rows inside the window again.
    public func reset(now: Date = Date()) throws {
        try store.transaction {
            try store.exec("DELETE FROM vecs; DELETE FROM vec_pending;")
            let cutoff = Int64(now.addingTimeInterval(-Double(windowDays) * 86_400).timeIntervalSince1970)
            try store.run("INSERT INTO vec_pending(rid) SELECT rid FROM messages WHERE received >= ?", [.int(cutoff)])
            matrix = nil; pendingVersion = [:]
        }
    }

    public var pendingCount: Int { Int((try? store.scalarInt("SELECT COUNT(*) FROM vec_pending")) ?? 0 ?? 0) }
    public var vectorRowCount: Int { Int((try? store.scalarInt("SELECT COUNT(*) FROM vecs")) ?? 0 ?? 0) }

    // MARK: Background embedding

    /// Embed up to `maxItems` queued rows. The embedder runs outside the store lock. Returns rows processed.
    @discardableResult
    public func catchUp(maxItems: Int = 256, now: Date = Date()) throws -> Int {
        let (emb, pol, window) = store.locked { (embedder, policy, windowDays) }
        let batch: [(Int64, Int64, MailMessage?, String)] = try store.locked {
            let rids = try store.query("SELECT rid FROM vec_pending LIMIT ?", [.int(Int64(maxItems))]) { sqlite3_column_int64($0, 0) }
            let rows = try store.rows(rids: rids)
            return rids.map { ($0, pendingVersion[$0] ?? 0, rows[$0]?.0, rows[$0]?.1 ?? "me") }
        }
        guard !batch.isEmpty else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(window) * 86_400)
        var out: [(Int64, Int64, String, EmbeddedText?)] = []
        for (rid, gen, m, mb) in batch {
            var e: EmbeddedText?
            if let m, let emb, let pol, m.received >= cutoff, pol(m, mb) {
                e = emb.embed(Self.text(of: m))
            }
            out.append((rid, gen, mb, e))
        }
        try store.transaction {
            for (rid, gen, mb, e) in out {
                // Row changed or vanished meanwhile → leave it for the next round (or it's gone).
                guard (pendingVersion[rid] ?? 0) == gen,
                      try store.scalarInt("SELECT COUNT(*) FROM vec_pending WHERE rid=?", [.int(rid)]) == 1 else { continue }
                try put(rid: rid, embedded: e, mailbox: mb)
            }
        }
        return out.count
    }

    static func text(of m: MailMessage) -> String {
        let s = SubjectTerms.normalisedSubject(m.subject)
        guard let p = m.preview, !p.isEmpty else { return s }
        return s + ". " + String(p.prefix(400))
    }

    /// Store one vector (nil → padded marker). Public for benches/tests that bring their own vectors.
    public func put(messageId: String, embedded e: EmbeddedText?) throws {
        guard let rid = store.rid(forMessageId: messageId) else { return }
        let mb = (try? store.query("SELECT mailbox FROM messages WHERE rid=?", [.int(rid)]) { storeText($0, 0) })?.first ?? "me"
        try store.transaction { try put(rid: rid, embedded: e, mailbox: mb) }
    }

    /// Many vectors in one transaction (benches / tests).
    public func putBulk(_ items: [(messageId: String, embedded: EmbeddedText?)]) throws {
        try store.transaction {
            for (id, e) in items {
                guard let row = try store.query("SELECT rid, mailbox FROM messages WHERE id=?", [.text(id)], { s in (sqlite3_column_int64(s, 0), storeText(s, 1)) }).first
                else { continue }
                try put(rid: row.0, embedded: e, mailbox: row.1)
            }
        }
    }

    func put(rid: Int64, embedded e: EmbeddedText?, mailbox: String) throws {
        var payload = Data(count: Self.payloadBytes)
        var q: [Int8]? = nil, scale: Float = 0, space: UInt8 = 0
        if let e, let (qq, s) = Self.quantise(e.vector) {
            q = qq; scale = s; space = e.space
            payload[0] = space
            withUnsafeBytes(of: scale.bitPattern.littleEndian) { payload.replaceSubrange(1..<5, with: $0) }
            qq.withUnsafeBytes { payload.replaceSubrange(5..<(5 + qq.count), with: $0) }
        }
        try store.run("INSERT INTO vecs(rid,payload) VALUES(?,?) ON CONFLICT(rid) DO UPDATE SET payload=excluded.payload",
                      [.int(rid), .blob(try store.sealData(payload))])
        try store.run("DELETE FROM vec_pending WHERE rid=?", [.int(rid)])
        pendingVersion.removeValue(forKey: rid)
        if let q { matrix?.upsert(rid: rid, space: space, scale: scale, mailbox: mailbox, q: q) } else { matrix?.remove(rid) }
    }

    /// L2-normalise, then symmetric int8 (scale = max|x| / 127). Pads to `dimension`.
    static func quantise(_ v: [Float]) -> ([Int8], Float)? {
        guard !v.isEmpty, v.count <= dimension else { return nil }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        let u = v.map { $0 / norm }
        let mx = u.reduce(0) { max($0, abs($1)) }
        guard mx > 0 else { return nil }
        let s = mx / 127
        var q = u.map { Int8(max(-127, min(127, ($0 / s).rounded()))) }
        if q.count < dimension { q += Array(repeating: 0, count: dimension - q.count) }
        return (q, s)
    }

    // MARK: Query

    public var vectorCount: Int { store.locked { (try? loadMatrix())?.count ?? 0 } }

    private func loadMatrix() throws -> Matrix {
        if let m = matrix { return m }
        let m = Matrix()
        let rows = try store.query("SELECT v.rid, v.payload, m.mailbox FROM vecs v JOIN messages m ON m.rid=v.rid") { s in
            (sqlite3_column_int64(s, 0), storeBlob(s, 1), storeText(s, 2))
        }
        for (rid, sealed, mb) in rows {
            guard let p = try? store.openData(sealed), p.count == Self.payloadBytes, p[0] != 0 else { continue }
            let scale = Float(bitPattern: UInt32(littleEndian: p.subdata(in: 1..<5).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            let q = p.subdata(in: 5..<Self.payloadBytes).withUnsafeBytes { Array($0.bindMemory(to: Int8.self)) }
            m.upsert(rid: rid, space: p[0], scale: scale, mailbox: mb, q: q)
        }
        matrix = m
        return m
    }

    /// Top-k rows by cosine (≥ `minScore`), optionally restricted to one mailbox.
    public func search(_ text: String, mailbox: String?, k: Int = 200, minScore: Float = 0.2) -> [(rid: Int64, score: Float)] {
        let (emb, spaces) = store.locked { (embedder, (try? loadMatrix())?.spaces ?? []) }
        guard let emb, !spaces.isEmpty else { return [] }
        return search(vectors: emb.embedQuery(text, spaces: spaces), mailbox: mailbox, k: k, minScore: minScore)
    }

    public func search(vectors: [EmbeddedText], mailbox: String?, k: Int = 200, minScore: Float = 0.2) -> [(rid: Int64, score: Float)] {
        store.locked {
            guard let m = try? loadMatrix() else { return [] }
            var best: [(Int64, Float)] = []
            for v in vectors {
                guard let (q, qs) = Self.quantise(v.vector) else { continue }
                best += m.top(q: q, qScale: qs, space: v.space, mailbox: mailbox, k: k, minScore: minScore)
            }
            var seen = Set<Int64>()
            return best.sorted { $0.1 > $1.1 }.filter { seen.insert($0.0).inserted }.prefix(k).map { (rid: $0.0, score: $0.1) }
        }
    }

    // MARK: Stories (StoryEngine scores candidates with stored vectors; never re-embeds)

    func storyHasVector(_ rid: Int64) -> Bool { store.locked { (try? loadMatrix())?.index[rid] != nil } }

    /// Cosine of two stored rows (nil: either has no vector, or they're in different language spaces).
    func storyCosine(_ a: Int64, _ b: Int64) -> Float? {
        store.locked {
            guard let m = try? loadMatrix(), let i = m.index[a], let j = m.index[b], m.space[i] == m.space[j] else { return nil }
            return m.dot(i, j)
        }
    }

    /// Top-k of `among` by cosine to `rid` (≥ minScore).
    func storyNearest(to rid: Int64, among: [Int64], k: Int, minScore: Float) -> [(Int64, Float)] {
        store.locked {
            guard let m = try? loadMatrix(), let i = m.index[rid] else { return [] }
            var out: [(Int64, Float)] = []
            for r in among {
                guard let j = m.index[r], m.space[j] == m.space[i] else { continue }
                let s = m.dot(i, j)
                if s >= minScore { out.append((r, s)) }
            }
            return Array(out.sorted { $0.1 > $1.1 }.prefix(k))
        }
    }

    // MARK: In-memory matrix

    final class Matrix {
        var rids: [Int64] = []
        var space: [UInt8] = []
        var scale: [Float] = []
        var mbox: [UInt16] = []
        var data: [Int8] = []
        var index: [Int64: Int] = [:]
        var mailboxes: [String] = []
        var mailboxIndex: [String: UInt16] = [:]
        var count: Int { rids.count }
        var spaces: Set<UInt8> { Set(space) }

        func mb(_ s: String) -> UInt16 {
            if let i = mailboxIndex[s] { return i }
            let i = UInt16(mailboxes.count); mailboxes.append(s); mailboxIndex[s] = i; return i
        }

        func upsert(rid: Int64, space s: UInt8, scale sc: Float, mailbox: String, q: [Int8]) {
            let d = SemanticIndex.dimension
            if let i = index[rid] {
                space[i] = s; scale[i] = sc; mbox[i] = mb(mailbox)
                data.replaceSubrange((i * d)..<((i + 1) * d), with: q.prefix(d))
                return
            }
            index[rid] = rids.count
            rids.append(rid); space.append(s); scale.append(sc); mbox.append(mb(mailbox))
            data.append(contentsOf: q.prefix(d))
        }

        func dot(_ i: Int, _ j: Int) -> Float {
            let d = SemanticIndex.dimension
            var acc: Int32 = 0
            data.withUnsafeBufferPointer { db in
                let a = i * d, b = j * d
                for k in 0..<d { acc &+= Int32(db[a + k]) &* Int32(db[b + k]) }
            }
            return Float(acc) * scale[i] * scale[j]
        }

        func remove(_ rid: Int64) {
            guard let i = index.removeValue(forKey: rid) else { return }
            let last = rids.count - 1, d = SemanticIndex.dimension
            if i != last {
                rids[i] = rids[last]; space[i] = space[last]; scale[i] = scale[last]; mbox[i] = mbox[last]
                for j in 0..<d { data[i * d + j] = data[last * d + j] }
                index[rids[i]] = i
            }
            rids.removeLast(); space.removeLast(); scale.removeLast(); mbox.removeLast()
            data.removeLast(d)
        }

        func top(q: [Int8], qScale: Float, space s: UInt8, mailbox: String?, k: Int, minScore: Float) -> [(Int64, Float)] {
            let d = SemanticIndex.dimension
            let want: UInt16? = mailbox.map { mailboxIndex[$0] ?? UInt16.max }
            var heap: [(Int64, Float)] = []
            heap.reserveCapacity(k + 1)
            var floor = minScore
            data.withUnsafeBufferPointer { db in
                q.withUnsafeBufferPointer { qb in
                    for i in 0..<rids.count where space[i] == s && (want == nil || mbox[i] == want!) {
                        let base = i * d
                        var acc: Int32 = 0
                        var j = 0
                        // 4-way unrolled int8 dot product (auto-vectorised in release builds).
                        while j < d {
                            acc &+= Int32(db[base + j]) &* Int32(qb[j]) &+ Int32(db[base + j + 1]) &* Int32(qb[j + 1])
                                &+ Int32(db[base + j + 2]) &* Int32(qb[j + 2]) &+ Int32(db[base + j + 3]) &* Int32(qb[j + 3])
                            j += 4
                        }
                        let score = Float(acc) * scale[i] * qScale
                        guard score >= floor else { continue }
                        heap.append((rids[i], score))
                        if heap.count > k * 2 {
                            heap.sort { $0.1 > $1.1 }; heap.removeLast(heap.count - k); floor = max(floor, heap.last!.1)
                        }
                    }
                }
            }
            return Array(heap.sorted { $0.1 > $1.1 }.prefix(k))
        }
    }
}
