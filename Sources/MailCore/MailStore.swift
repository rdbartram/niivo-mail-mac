import Foundation
import SQLite3
import CryptoKit
import CalendarCore

/// What the mail outbox carries: a user action on a message, or a send of an existing draft.
public enum MailOutboxOp: Codable, Sendable, Hashable {
    case action(MailAction)
    /// `sendAt` = client-side scheduled send time (nil = now).
    case send(sendAt: Date?)
}

public struct MailOutboxEntry: Sendable, Hashable {
    public var seq: Int64
    public var messageId: String
    public var mailbox: String
    public var op: MailOutboxOp
    public var attempts: Int
}

/// Encrypted local mail cache, built for 1M+ headers across several mailboxes.
///
/// Layout:
///  * `messages` — one row per header. Plaintext index columns only (ids, folder, mailbox, dates, read/flag);
///    subject/sender/preview live in the AES-GCM sealed payload. Bodies are NEVER in this table.
///    Indexes: (folder_id, received DESC, id DESC) for keyset paging, (conversation_id, received), (mailbox, received).
///  * `bodies` — size-capped LRU of sealed bodies; `last_access` and `size` tracked in SQLite, evicted oldest-first.
///  * `tokens` — blind search index: truncated HMAC-SHA256(indexKey, token) → message rowid. No plaintext terms.
///  * `kv`, `outbox` — delta links / settings / backfill cursors, and queued intents (sealed).
///
/// The persist rule is enforced HERE on every write path: protected/unknown label (or redacted private) → no body,
/// preview, recipients or attachment names are written, and only sender tokens are indexed.
public final class MailStore: @unchecked Sendable {
    var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let cipher: PayloadCipher
    let indexKey: SymmetricKey
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var persistPolicy: MailPersistPolicy?
    var folderMailbox: [String: String] = [:]
    /// SEARCH: communication graph + semantic index, maintained on every write path once enabled.
    public internal(set) var graph: CommGraph?
    public internal(set) var semantic: SemanticIndex?
    /// STORIES: related-message clustering (StoryEngine.swift), maintained like the semantic index.
    public internal(set) var stories: StoryEngine?
    /// TRIAGE2-HOOK: conversation triage engine (write paths mark conversations dirty).
    public internal(set) var triage: InboxTriageEngine?
    /// PROMISES-HOOK: promises ledger (write paths mark conversations dirty).
    public internal(set) var promises: PromiseLedger?
    /// PEOPLE-HOOK: local knowledge layer (Knowledge.swift), per account.
    public internal(set) var knowledge: KnowledgeEngine?
    /// LOOPS-HOOK: loops (LoopsEngine.swift), per account.
    public internal(set) var loops: LoopsEngine?
    /// WHEN-HOOK: loop work items (WorkItemsEngine.swift), per account.
    public internal(set) var workItems: WorkItemsEngine?
    /// Rows above this rid haven't been visited by the graph backfill yet (the backfill counts them, not the diff).
    var graphBackfillCursor: Int64 = .max
    /// SEARCH: bumped on every committed write; invalidates the df / corpus caches.
    var searchGeneration = 0
    var dfCache: [Data: Int] = [:]
    var dfGeneration = -1
    var statsCache: (at: Date, v: (n: Int, avgMeta: Double, avgPreview: Double))?
    var persistPolicyValue: MailPersistPolicy? { lock.lock(); defer { lock.unlock() }; return persistPolicy }
    func bumpSearchGeneration() { lock.lock(); searchGeneration &+= 1; lock.unlock() }
    private var accessClock: Int64 = 0
    /// Body LRU cap in bytes (sealed size).
    public private(set) var bodyCacheLimit: Int

    public let url: URL?

    /// Derive the blind-index HMAC key from the cache key (HKDF), so destroying the Keychain key also kills the index.
    public static func deriveIndexKey(from cacheKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: cacheKey, salt: Data("compliant-office.mail".utf8),
                               info: Data("blind-index-v1".utf8), outputByteCount: 32)
    }

    /// Convenience: AES-GCM payload cipher + HKDF-derived index key from one cache key.
    public convenience init(url: URL?, key: SymmetricKey, persistPolicy: MailPersistPolicy? = nil,
                            bodyCacheLimit: Int = 500 * 1024 * 1024) throws {
        try self.init(url: url, cipher: AESGCMCipher(key: key), indexKey: Self.deriveIndexKey(from: key),
                      persistPolicy: persistPolicy, bodyCacheLimit: bodyCacheLimit)
    }

    /// `url == nil` → in-memory.
    public init(url: URL?, cipher: PayloadCipher, indexKey: SymmetricKey, persistPolicy: MailPersistPolicy? = nil,
                bodyCacheLimit: Int = 500 * 1024 * 1024) throws {
        self.url = url
        self.cipher = cipher
        self.indexKey = indexKey
        self.persistPolicy = persistPolicy
        self.bodyCacheLimit = bodyCacheLimit
        let path = url?.path ?? ":memory:"
        if let dir = url?.deletingLastPathComponent() {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { throw StoreError.sqlite("open failed") }
        try exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA temp_store=MEMORY;
        PRAGMA mmap_size=268435456;
        PRAGMA cache_size=-65536;
        CREATE TABLE IF NOT EXISTS folders(id TEXT PRIMARY KEY, mailbox TEXT NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS messages(
            rid INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            folder_id TEXT NOT NULL,
            mailbox TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            received INTEGER NOT NULL,
            is_read INTEGER NOT NULL,
            flagged INTEGER NOT NULL,
            snoozed_until INTEGER,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS messages_by_folder ON messages(folder_id, received DESC, id DESC);
        CREATE INDEX IF NOT EXISTS messages_by_conv ON messages(conversation_id, received);
        CREATE INDEX IF NOT EXISTS messages_by_folder_conv ON messages(folder_id, conversation_id, received, is_read, flagged);   -- THREAD-HOOK: grouped list (MailThreads.swift)
        CREATE INDEX IF NOT EXISTS messages_by_mailbox ON messages(mailbox, received);
        CREATE INDEX IF NOT EXISTS messages_by_snooze ON messages(snoozed_until) WHERE snoozed_until IS NOT NULL;
        CREATE TABLE IF NOT EXISTS tokens(h BLOB NOT NULL, rid INTEGER NOT NULL, PRIMARY KEY(h, rid)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS tokens_by_rid ON tokens(rid);
        CREATE TABLE IF NOT EXISTS bodies(message_id TEXT PRIMARY KEY, size INTEGER NOT NULL,
                                          last_access INTEGER NOT NULL, payload BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS bodies_lru ON bodies(last_access);
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS g_node(k BLOB PRIMARY KEY, kind INTEGER NOT NULL, payload BLOB NOT NULL) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS g_node_by_kind ON g_node(kind);
        CREATE TABLE IF NOT EXISTS vecs(rid INTEGER PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS vec_pending(rid INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS story_feat(rid INTEGER PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS story_pending(rid INTEGER PRIMARY KEY);
        -- TRIAGE2-HOOK: conversation triage, per account (HMAC keys, sealed fixed-size payloads; InboxStateEngine.swift)
        CREATE TABLE IF NOT EXISTS conv_state(key BLOB PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS triage_override(key BLOB PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS sender_override(key BLOB PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS triage_truth(key BLOB PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID;
        -- PROMISES-HOOK: promises ledger, per account (HMAC keys, sealed fixed-size payloads; PromisesEngine.swift)
        CREATE TABLE IF NOT EXISTS promise_item(key BLOB PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS kn_entity(key BLOB PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID;   -- PEOPLE-HOOK: knowledge layer
        CREATE TABLE IF NOT EXISTS kn_fact(key BLOB PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID;     -- PEOPLE-HOOK
        CREATE TABLE IF NOT EXISTS loop_row(key BLOB PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID;    -- LOOPS-HOOK: loops (user data)
        CREATE TABLE IF NOT EXISTS work_item(key BLOB PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID;   -- WHEN-HOOK: loop work items (user data)
        CREATE TABLE IF NOT EXISTS outbox(
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id TEXT NOT NULL, mailbox TEXT NOT NULL,
            action BLOB NOT NULL, attempts INTEGER NOT NULL DEFAULT 0
        );
        """)
        try migrateSearchSchema()
        for f in (try? folders()) ?? [] { folderMailbox[f.id] = f.mailbox }
        accessClock = ((try? scalarInt("SELECT MAX(last_access) FROM bodies")) ?? nil) ?? 0
        if let url { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }

    deinit { sqlite3_close_v2(db) }

    public func setPersistPolicy(_ p: MailPersistPolicy?) {
        lock.lock(); defer { lock.unlock() }
        persistPolicy = p
    }

    private func policy(for m: MailMessage) -> ContentPolicy {
        lock.lock(); let p = persistPolicy; let mb = folderMailbox[m.folderId] ?? "me"; lock.unlock()
        return p?(m, mb) ?? MailContentPolicy.failClosed(for: m)
    }

    /// Apply the persist rule (exposed so callers/tests can see exactly what would be written).
    public func persistable(_ m: MailMessage) -> MailMessage {
        MailContentPolicy.sanitizeForCache(m, policy: policy(for: m))
    }

    // MARK: Folders

    /// Replace one mailbox's folder list (server counts come with it: `unreadItemCount` / `totalItemCount`).
    public func replace(folders: [MailFolder], mailbox: String) throws {
        try transaction {
            try run("DELETE FROM folders WHERE mailbox=?", [.text(mailbox)])
            for f in folders { try upsertFolderRow(f) }
        }
    }

    public func upsert(folder f: MailFolder) throws { try transaction { try upsertFolderRow(f) } }

    private func upsertFolderRow(_ f: MailFolder) throws {
        try run("INSERT INTO folders(id,mailbox,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET mailbox=excluded.mailbox, payload=excluded.payload",
                [.text(f.id), .text(f.mailbox), .blob(try seal(f))])
        folderMailbox[f.id] = f.mailbox
        graph?.folderChanged(f)   // SEARCH
    }

    public func folders(mailbox: String? = nil) throws -> [MailFolder] {
        let rows: [MailFolder]
        if let mailbox {
            rows = try query("SELECT payload FROM folders WHERE mailbox=?", [.text(mailbox)]) { s in try self.unseal(MailFolder.self, blob(s, 0)) }
        } else {
            rows = try query("SELECT payload FROM folders") { s in try self.unseal(MailFolder.self, blob(s, 0)) }
        }
        return rows.sorted { ($0.wellKnown == nil ? 1 : 0, $0.displayName) < ($1.wellKnown == nil ? 1 : 0, $1.displayName) }
    }

    public func folder(id: String) throws -> MailFolder? {
        try query("SELECT payload FROM folders WHERE id=?", [.text(id)]) { s in try self.unseal(MailFolder.self, blob(s, 0)) }.first
    }

    public func folder(wellKnown: WellKnownFolder, mailbox: String = "me") throws -> MailFolder? {
        try folders(mailbox: mailbox).first { $0.wellKnown == wellKnown }
    }

    public func mailbox(forFolder id: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return folderMailbox[id] ?? "me"
    }

    /// Unread count as reported by the server (folder record), adjusted locally by optimistic read/unread.
    public func unreadCount(folderId: String) throws -> Int { try folder(id: folderId)?.unreadCount ?? 0 }

    /// Optimistic count adjustment (server value replaces it on the next folder refresh).
    public func adjustCounts(folderId: String, unread: Int = 0, total: Int = 0) throws {
        guard var f = try folder(id: folderId) else { return }
        f.unreadCount = max(0, f.unreadCount + unread); f.totalCount = max(0, f.totalCount + total)
        try upsert(folder: f)
    }

    // MARK: Messages (headers)

    /// Upsert headers. A body on the input goes to the body LRU (if the policy allows), never into the header row.
    public func upsert(messages: [MailMessage]) throws {
        guard !messages.isEmpty else { return }
        var bodies: [(String, String)] = []
        try transaction {
            let stmt = try prepare("""
            INSERT INTO messages(id,folder_id,mailbox,conversation_id,received,is_read,flagged,snoozed_until,payload,dl)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET folder_id=excluded.folder_id, mailbox=excluded.mailbox,
              conversation_id=excluded.conversation_id, received=excluded.received, is_read=excluded.is_read,
              flagged=excluded.flagged, snoozed_until=excluded.snoozed_until, payload=excluded.payload, dl=excluded.dl
            RETURNING rid
            """)
            defer { sqlite3_finalize(stmt) }
            let delTok = try prepare("DELETE FROM tokens WHERE rid=?"); defer { sqlite3_finalize(delTok) }
            let insTok = try prepare("INSERT OR IGNORE INTO tokens(h,rid,w) VALUES(?,?,?)"); defer { sqlite3_finalize(insTok) }
            let observed = graph != nil || semantic != nil || stories != nil
            let oldRow = observed ? try prepare("SELECT rid, mailbox, payload FROM messages WHERE id=?") : nil
            defer { if let oldRow { sqlite3_finalize(oldRow) } }
            for raw in messages {
                let pol = policy(for: raw)
                var m = MailContentPolicy.sanitizeForCache(raw, policy: pol)
                if let b = m.body, pol.allowOfflineDetails { bodies.append((m.id, b)) }
                m.body = nil
                let mb = folderMailbox[m.folderId] ?? "me"
                // SEARCH: previous version of the row, for the graph / vector diff.
                var old: (rid: Int64, mailbox: String, msg: MailMessage)?
                if let oldRow {
                    sqlite3_reset(oldRow); sqlite3_clear_bindings(oldRow); bind(oldRow, [.text(m.id)])
                    if sqlite3_step(oldRow) == SQLITE_ROW, let om = try? unseal(MailMessage.self, blob(oldRow, 2)) {
                        old = (sqlite3_column_int64(oldRow, 0), text(oldRow, 1), om)
                    }
                }
                // SEARCHQ-HOOK: cached body terms join the index (the incoming body, else the one already cached).
                let details = pol.allowOfflineDetails && !pol.redactDetails
                let ix = BlindIndex.weighted(for: m, details: details, key: indexKey,
                                             body: details ? (raw.body ?? indexBody(m.id)) : nil)
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bind(stmt, [.text(m.id), .text(m.folderId), .text(mb), .text(m.conversationId),
                            .int(Int64(m.received.timeIntervalSince1970)), .int(m.isRead ? 1 : 0),
                            .int(m.flag.status == .flagged ? 1 : 0),
                            m.snoozedUntil.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null,
                            .blob(try seal(m)), .int(ix.dl)])
                guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.sqlite(errmsg()) }
                let rid = sqlite3_column_int64(stmt, 0)
                _ = sqlite3_step(stmt)
                try bindAndStep(delTok, [.int(rid)])
                for (h, w) in ix.tokens { try bindAndStep(insTok, [.blob(h), .int(rid), .int(Int64(w))]) }
                if let graph, rid <= graphBackfillCursor || old != nil && old!.rid <= graphBackfillCursor {
                    graph.change(old: old?.msg, new: m, oldMailbox: old?.mailbox ?? mb, newMailbox: mb)
                }
                try semantic?.rowChanged(rid: rid, old: old?.msg, new: m, mailbox: mb)
                try stories?.rowChanged(rid: rid, old: old?.msg, new: m, mailbox: mb)   // STORIES
                triage?.touch(m.conversationId)   // TRIAGE2-HOOK
                if let oc = old?.msg.conversationId, oc != m.conversationId { triage?.touch(oc); promises?.touch(oc) }
                promises?.touch(m.conversationId)   // PROMISES-HOOK
            }
            try graph?.flush()
        }
        for (id, b) in bodies { try putBody(messageId: id, body: b) }
    }

    public func upsert(message: MailMessage) throws { try upsert(messages: [message]) }

    /// Remove headers (+ their tokens and cached bodies). With `folderId`, only rows still in that folder are
    /// removed — a delta `@removed` from the source folder must not delete a row the destination already upserted.
    public func deleteMessages(ids: [String], folderId: String? = nil) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids {
                let rid: Int64?
                if let folderId {
                    rid = try query("SELECT rid FROM messages WHERE id=? AND folder_id=?", [.text(id), .text(folderId)]) { sqlite3_column_int64($0, 0) }.first
                } else {
                    rid = try query("SELECT rid FROM messages WHERE id=?", [.text(id)]) { sqlite3_column_int64($0, 0) }.first
                }
                guard let rid else { continue }
                if let triage, let c = try query("SELECT conversation_id FROM messages WHERE rid=?", [.int(rid)], { s in
                    sqlite3_column_text(s, 0).map { String(cString: $0) } ?? "" }).first { triage.touch(c) }   // TRIAGE2-HOOK
                try forgetIndexed(rid: rid)   // SEARCH
                try run("DELETE FROM tokens WHERE rid=?", [.int(rid)])
                try run("DELETE FROM messages WHERE rid=?", [.int(rid)])
                try run("DELETE FROM bodies WHERE message_id=?", [.text(id)])
            }
            try graph?.flush()
        }
    }

    /// Server assigned a new id (e.g. after a move). Replaces the row and re-points queued outbox items.
    public func replace(messageId old: String, with new: MailMessage) throws {
        let cachedBody = old != new.id ? try body(messageId: old, touch: false) : nil
        try transaction {
            if old != new.id { try deleteMessages(ids: [old]) }
            var n = new
            if n.body == nil, let cachedBody { n.body = cachedBody }
            try upsert(messages: [n])
            if old != new.id { try run("UPDATE outbox SET message_id=? WHERE message_id=?", [.text(new.id), .text(old)]) }
        }
    }

    /// Header + cached body (if any; touching the LRU).
    public func message(id: String, includeBody: Bool = true) throws -> MailMessage? {
        guard var m = try query("SELECT payload FROM messages WHERE id=?", [.text(id)], { s in try self.unseal(MailMessage.self, blob(s, 0)) }).first
        else { return nil }
        if includeBody { m.body = try body(messageId: id) }
        return m
    }

    /// Keyset page, newest first: rows strictly older than `before` (received, id). No OFFSET.
    public func messages(folderId: String, before: MailCursor? = nil, limit: Int = 50) throws -> [MailMessage] {
        if let before {
            let t = Int64(before.received.timeIntervalSince1970)
            return try query("""
                SELECT payload FROM messages WHERE folder_id=? AND (received < ? OR (received = ? AND id < ?))
                ORDER BY received DESC, id DESC LIMIT ?
                """, [.text(folderId), .int(t), .int(t), .text(before.id), .int(Int64(limit))]) { s in try self.unseal(MailMessage.self, blob(s, 0)) }
        }
        return try query("SELECT payload FROM messages WHERE folder_id=? ORDER BY received DESC, id DESC LIMIT ?",
                         [.text(folderId), .int(Int64(limit))]) { s in try self.unseal(MailMessage.self, blob(s, 0)) }
    }

    /// Oldest first (reading order).
    public func conversation(id: String, limit: Int = 500) throws -> [MailMessage] {
        try query("SELECT payload FROM messages WHERE conversation_id=? ORDER BY received ASC LIMIT ?",
                  [.text(id), .int(Int64(limit))]) { s in try self.unseal(MailMessage.self, blob(s, 0)) }
    }

    /// Oldest cached header in a folder (the backfill / load-older cursor).
    public func oldestCursor(folderId: String) throws -> MailCursor? {
        try query("SELECT received, id FROM messages WHERE folder_id=? ORDER BY received ASC, id ASC LIMIT 1", [.text(folderId)]) { s in
            MailCursor(received: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0))), id: text(s, 1))
        }.first
    }

    /// Content-free label census over every cached header (LabelProvenance.swift). Counts only.
    public func labelCensus(known: Set<String>) throws -> LabelCensus {
        var c = LabelCensus()
        _ = try query("SELECT payload FROM messages") { s -> Bool in
            let m = try self.unseal(MailMessage.self, blob(s, 0))
            c.add(labelId: m.labelId, origin: m.labelOrigin, known: known)
            return true
        }
        return c
    }

    public func messageCount(folderId: String? = nil) throws -> Int {
        if let folderId { return Int(try scalarInt("SELECT COUNT(*) FROM messages WHERE folder_id=?", [.text(folderId)]) ?? 0) }
        return Int(try scalarInt("SELECT COUNT(*) FROM messages") ?? 0)
    }

    /// Snoozed messages whose wake time has come (partial index).
    public func snoozedDue(at now: Date, limit: Int = 500) throws -> [MailMessage] {
        try query("SELECT payload FROM messages WHERE snoozed_until IS NOT NULL AND snoozed_until <= ? LIMIT ?",
                  [.int(Int64(now.timeIntervalSince1970)), .int(Int64(limit))]) { s in try self.unseal(MailMessage.self, blob(s, 0)) }
    }

    /// Re-home messages from one folder id to another (local snooze placeholder → real server folder).
    public func moveAll(fromFolder: String, toFolder: String) throws {
        while true {
            let rows = try messages(folderId: fromFolder, limit: 500)
            if rows.isEmpty { break }
            try upsert(messages: rows.map { var m = $0; m.folderId = toFolder; return m })
        }
    }

    /// Cache-window shrink: drop headers (+ tokens) of `mailbox` received before `cutoff`. Bodies stay in the LRU.
    @discardableResult
    public func prune(mailbox: String, before cutoff: Date) throws -> Int {
        let t = Int64(cutoff.timeIntervalSince1970)
        var n = 0
        try transaction {
            if graph != nil || semantic != nil || stories != nil {   // SEARCH: graph/vector diff needs the rows
                let rids = try query("SELECT rid FROM messages WHERE mailbox=? AND received < ?", [.text(mailbox), .int(t)]) { sqlite3_column_int64($0, 0) }
                for rid in rids { try forgetIndexed(rid: rid) }
                try graph?.flush()
            }
            try run("DELETE FROM tokens WHERE rid IN (SELECT rid FROM messages WHERE mailbox=? AND received < ?)", [.text(mailbox), .int(t)])
            try run("DELETE FROM messages WHERE mailbox=? AND received < ?", [.text(mailbox), .int(t)])
            n = Int(sqlite3_changes(db))
        }
        return n
    }

    // MARK: Blind-index search

    /// Local search via the blind token index. Every query term must match (AND); the last term also matches as a
    /// prefix (≥ 3 chars) and is verified against the decrypted candidate. Newest first.
    public func search(_ text: String, mailbox: String? = nil, limit: Int = 50) throws -> [MailMessage] {
        let terms = BlindIndex.tokenize(text)
        guard let last = terms.last else { return [] }
        let prefixLast = !text.hasSuffix(" ") && last.count >= BlindIndex.prefixLength
        var hashes: [Data] = []
        for (i, t) in terms.enumerated() {
            if i == terms.count - 1 && prefixLast { hashes.append(BlindIndex.hmac("p:" + String(t.prefix(BlindIndex.prefixLength)), key: indexKey)) }
            else { hashes.append(BlindIndex.hmac("t:" + t, key: indexKey)) }
        }
        let inter = hashes.map { _ in "SELECT rid FROM tokens WHERE h=?" }.joined(separator: " INTERSECT ")
        // Planner hint: for broad terms (many candidates) walk the (mailbox, received) index newest-first and stop
        // at LIMIT instead of sorting the whole candidate set; for selective terms sort the small set.
        let narrowest = try hashes.map { try scalarInt("SELECT COUNT(*) FROM tokens WHERE h=?", [.blob($0)]) ?? 0 }.min() ?? 0
        let walk = mailbox != nil && narrowest > 2_000
        var sql = "SELECT payload FROM messages\(walk ? " INDEXED BY messages_by_mailbox" : "") WHERE rid IN (\(inter))"
        var params: [Bind] = hashes.map { .blob($0) }
        if let mailbox { sql += " AND mailbox=?"; params.append(.text(mailbox)) }
        sql += " ORDER BY received DESC LIMIT ?"
        params.append(.int(Int64(prefixLast ? limit * 4 : limit)))
        let rows = try query(sql, params) { s in try self.unseal(MailMessage.self, blob(s, 0)) }
        guard prefixLast else { return Array(rows.prefix(limit)) }
        return Array(rows.lazy.filter { m in
            BlindIndex.terms(for: m, details: true).contains { $0.hasPrefix(last) }
        }.prefix(limit))
    }

    public func tokenRowCount() throws -> Int { Int(try scalarInt("SELECT COUNT(*) FROM tokens") ?? 0) }

    // MARK: Body LRU

    /// Cache a body (sealed). Refused when the message's policy forbids offline details. Evicts LRU-first.
    public func putBody(messageId: String, body: String) throws {
        if let header = try message(id: messageId, includeBody: false) {
            guard policy(for: header).allowOfflineDetails else { return }
        }
        let sealed = try cipher.seal(Data(body.utf8))
        try transaction {
            try run("INSERT INTO bodies(message_id,size,last_access,payload) VALUES(?,?,?,?) ON CONFLICT(message_id) DO UPDATE SET size=excluded.size, last_access=excluded.last_access, payload=excluded.payload",
                    [.text(messageId), .int(Int64(sealed.count)), .int(tick()), .blob(sealed)])
            try evictBodies()
        }
    }

    public func body(messageId: String, touch: Bool = true) throws -> String? {
        guard let d = try query("SELECT payload FROM bodies WHERE message_id=?", [.text(messageId)], { s in blob(s, 0) }).first else { return nil }
        if touch { try run("UPDATE bodies SET last_access=? WHERE message_id=?", [.int(tick()), .text(messageId)]) }
        return String(data: try cipher.open(d), encoding: .utf8)
    }

    public func bodyCacheBytes() throws -> Int { Int(try scalarInt("SELECT COALESCE(SUM(size),0) FROM bodies") ?? 0) }
    public func bodyCount() throws -> Int { Int(try scalarInt("SELECT COUNT(*) FROM bodies") ?? 0) }

    public func setBodyCacheLimit(_ bytes: Int) throws {
        lock.lock(); bodyCacheLimit = bytes; lock.unlock()
        try transaction { try evictBodies() }
    }

    private func evictBodies() throws {
        var total = Int(try scalarInt("SELECT COALESCE(SUM(size),0) FROM bodies") ?? 0)
        while total > bodyCacheLimit {
            let victims = try query("SELECT message_id, size FROM bodies ORDER BY last_access ASC LIMIT 64") { s in (text(s, 0), Int(sqlite3_column_int64(s, 1))) }
            if victims.isEmpty { break }
            for (id, size) in victims where total > bodyCacheLimit {
                try run("DELETE FROM bodies WHERE message_id=?", [.text(id)])
                total -= size
            }
        }
    }

    private func tick() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        accessClock = max(accessClock + 1, Int64(Date().timeIntervalSince1970 * 1000))
        return accessClock
    }

    // MARK: Key/value + settings

    public func setValue(_ value: String?, for key: String) throws {
        if let value {
            try run("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
        } else {
            try run("DELETE FROM kv WHERE key=?", [.text(key)])
        }
    }

    public func value(for key: String) throws -> String? {
        try query("SELECT value FROM kv WHERE key=?", [.text(key)]) { s in text(s, 0) }.first
    }

    /// Settings are sealed (they include identity addresses).
    public func settings() throws -> MailSettings {
        guard let v = try value(for: "settings"), let d = Data(base64Encoded: v) else { return MailSettings() }
        return (try? unseal(MailSettings.self, d)) ?? MailSettings()   // unreadable/old schema → defaults
    }

    public func save(settings: MailSettings) throws {
        try setValue(try seal(settings).base64EncodedString(), for: "settings")
    }

    // AI-HOOK: sealed kv for AI results (triage cache). Cleared with the store on wipe/sign-out.
    public func setSealed<T: Encodable>(_ v: T?, for key: String) throws {
        try setValue(try v.map { try seal($0).base64EncodedString() }, for: key)
    }

    public func sealed<T: Decodable>(_ t: T.Type, for key: String) -> T? {
        guard let v = try? value(for: key), let d = Data(base64Encoded: v) else { return nil }
        return try? unseal(t, d)
    }

    // MARK: Outbox

    @discardableResult
    public func enqueue(messageId: String, mailbox: String, op: MailOutboxOp) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try run("INSERT INTO outbox(message_id,mailbox,action) VALUES(?,?,?)",
                [.text(messageId), .text(mailbox), .blob(try seal(op))])
        return sqlite3_last_insert_rowid(db)
    }

    public func outbox() throws -> [MailOutboxEntry] {
        try query("SELECT seq,message_id,mailbox,action,attempts FROM outbox ORDER BY seq") { s in
            MailOutboxEntry(seq: sqlite3_column_int64(s, 0), messageId: text(s, 1), mailbox: text(s, 2),
                            op: try self.unseal(MailOutboxOp.self, blob(s, 3)), attempts: Int(sqlite3_column_int(s, 4)))
        }
    }

    public func pendingOutboxCount(messageId: String) throws -> Int {
        Int(try scalarInt("SELECT COUNT(*) FROM outbox WHERE message_id=?", [.text(messageId)]) ?? 0)
    }

    public func removeOutbox(seq: Int64) throws { try run("DELETE FROM outbox WHERE seq=?", [.int(seq)]) }
    public func bumpOutbox(seq: Int64) throws { try run("UPDATE outbox SET attempts=attempts+1 WHERE seq=?", [.int(seq)]) }
    public func remapOutbox(from old: String, to new: String) throws {
        try run("UPDATE outbox SET message_id=? WHERE message_id=?", [.text(new), .text(old)])
    }

    /// Sign-out / selective wipe.
    public func wipe() throws {
        try exec("DELETE FROM messages; DELETE FROM tokens; DELETE FROM bodies; DELETE FROM folders; DELETE FROM kv; DELETE FROM outbox; DELETE FROM g_node; DELETE FROM vecs; DELETE FROM vec_pending; DELETE FROM story_feat; DELETE FROM story_pending; DELETE FROM conv_state; DELETE FROM triage_override; DELETE FROM sender_override; DELETE FROM triage_truth; DELETE FROM promise_item; DELETE FROM kn_entity; DELETE FROM kn_fact; DELETE FROM loop_row; DELETE FROM work_item; VACUUM;")   // TRIAGE2-HOOK; PROMISES-HOOK; PEOPLE-HOOK
        lock.lock(); folderMailbox = [:]; graph?.wipe(); semantic?.wipe(); stories?.wipe(); triage?.wipe(); promises?.wipe(); knowledge?.wipe(); loops?.wipe(); workItems?.wipe(); lock.unlock()   // PROMISES-HOOK; PEOPLE-HOOK; LOOPS-HOOK; WHEN-HOOK
        try? searchAfterWipe()   // SEARCH
    }

    /// Drop cached headers/bodies/index and the delta + backfill cursors so the next sync re-reads everything in the
    /// window. Keeps settings, folders and the outbox (used when header parsing changes, e.g. label rules).
    public func resetHeaders() throws {
        try exec("DELETE FROM messages; DELETE FROM tokens; DELETE FROM bodies; DELETE FROM g_node; DELETE FROM vecs; DELETE FROM vec_pending; DELETE FROM story_feat; DELETE FROM story_pending; DELETE FROM kv WHERE key LIKE 'mdelta:%' OR key LIKE 'backfill:%' OR key LIKE 'opened:%';")
        lock.lock(); graph?.wipe(); semantic?.wipe(); stories?.wipe(); triage?.markAllDirty(); promises?.markAllDirty(); knowledge?.markAllDirty(); workItems?.markAllDirty(); lock.unlock()   // TRIAGE2-HOOK; PROMISES-HOOK; PEOPLE-HOOK; WHEN-HOOK: overrides, corrections, work items survive
        try? searchAfterWipe()   // SEARCH
    }

    /// Bulk-load helper (benchmarks, backfill): batched transactions.
    public func bulkUpsert(_ messages: [MailMessage], batch: Int = 5_000) throws {
        var i = 0
        while i < messages.count {
            try upsert(messages: Array(messages[i..<min(i + batch, messages.count)]))
            i += batch
        }
    }

    public func checkpoint() { try? exec("PRAGMA wal_checkpoint(TRUNCATE);") }

    // MARK: SQLite plumbing

    enum Bind { case text(String), int(Int64), blob(Data), null }

    func seal<T: Encodable>(_ v: T) throws -> Data { try cipher.seal(encoder.encode(v)) }
    func unseal<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T { try decoder.decode(t, from: cipher.open(d)) }
    func sealData(_ d: Data) throws -> Data { try cipher.seal(d) }
    func openData(_ d: Data) throws -> Data { try cipher.open(d) }
    /// SEARCH: run `body` under the store lock (graph / semantic caches share it).
    func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    func errmsg() -> String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "exec"; sqlite3_free(err)
            throw StoreError.sqlite(m)
        }
    }

    /// Re-entrant: nested calls run inside the outer transaction.
    private var txDepth = 0
    func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if txDepth > 0 { txDepth += 1; defer { txDepth -= 1 }; try body(); return }
        try exec("BEGIN IMMEDIATE")
        txDepth = 1
        do { try body(); txDepth = 0; try exec("COMMIT"); searchGeneration &+= 1 } catch {
            txDepth = 0; try? exec("ROLLBACK")
            graph?.discardBatch(); semantic?.dropMemory(); stories?.dropMemory()   // SEARCH: in-memory state follows the rollback
            throw error
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw StoreError.sqlite(errmsg()) }
        return stmt
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func bind(_ stmt: OpaquePointer?, _ params: [Bind]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), Self.transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    func bindAndStep(_ stmt: OpaquePointer?, _ params: [Bind]) throws {
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
        bind(stmt, params)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sqlite(errmsg()) }
    }

    func run(_ sql: String, _ params: [Bind] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }
        try bindAndStep(stmt, params)
    }

    func query<T>(_ sql: String, _ params: [Bind] = [], _ row: (OpaquePointer?) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try row(stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw StoreError.sqlite(errmsg()) }
        }
        return out
    }

    func scalarInt(_ sql: String, _ params: [Bind] = []) throws -> Int64? {
        try query(sql, params) { s in sqlite3_column_type(s, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 0) }.first ?? nil
    }
}

/// Blind token index: lowercase + diacritic-folded tokens of subject, sender and preview, plus a 3-char prefix
/// per token; stored only as truncated HMAC-SHA256 under a key derived from the cache key.
public enum BlindIndex {
    public static let prefixLength = 3
    /// 16 of 32 HMAC bytes: collision odds negligible at mailbox scale, halves the index.
    static let hashBytes = 16
    /// SEARCHQ: was 24 (only the first 24 distinct preview words were searchable). Graph previews are ≤ 255 chars.
    static let maxPreviewTokens = 64
    /// Cached-body terms indexed per message (SEARCHQ), from the first `SearchText.bodyIndexChars` of stripped text.
    static let maxBodyTokens = 600

    public static func tokenize(_ s: String) -> [String] {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { cur.append(ch) }
            else if !cur.isEmpty { if cur.count >= 2 { out.append(String(cur)) }; cur = String.UnicodeScalarView() }
        }
        if cur.count >= 2 { out.append(String(cur)) }
        return out
    }

    /// Plain terms for a message (used to verify prefix candidates in memory, never stored).
    static func terms(for m: MailMessage, details: Bool) -> Set<String> {
        var t = Set<String>()
        if let f = m.from { t.formUnion(tokenize(f.name)); t.formUnion(tokenize(f.address)) }
        if details {
            t.formUnion(tokenize(m.subject))
            if let p = m.preview { t.formUnion(tokenize(p).prefix(maxPreviewTokens)) }
        }
        return t
    }

    static func hashes(for m: MailMessage, details: Bool, key: SymmetricKey) -> Set<Data> {
        var out = Set<Data>()
        for term in terms(for: m, details: details) {
            out.insert(hmac("t:" + term, key: key))
            if term.count >= prefixLength { out.insert(hmac("p:" + String(term.prefix(prefixLength)), key: key)) }
        }
        return out
    }

    static func hmac(_ s: String, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: key).prefix(hashBytes))
    }
}

private func text(_ s: OpaquePointer?, _ i: Int32) -> String {
    sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
}

func storeBlob(_ s: OpaquePointer?, _ i: Int32) -> Data { blob(s, i) }
func storeText(_ s: OpaquePointer?, _ i: Int32) -> String { text(s, i) }

private func blob(_ s: OpaquePointer?, _ i: Int32) -> Data {
    let n = Int(sqlite3_column_bytes(s, i))
    guard n > 0, let p = sqlite3_column_blob(s, i) else { return Data() }
    return Data(bytes: p, count: n)
}
