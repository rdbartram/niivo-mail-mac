import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String { if case .sqlite(let m) = self { return m }; return "store" }
}

/// A queued local mutation waiting to reach Exchange.
public struct OutboxItem: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case update, create, delete }
    public var seq: Int64
    public var kind: Kind
    public var eventId: String
    public var calendarId: String
    /// Graph PATCH/POST body (JSON). Sealed at rest like everything else.
    public var body: Data
    /// changeKey we based the edit on — sent as If-Match so we never silently clobber a server edit.
    public var ifMatch: String?
    public var attempts: Int
    /// Bumped each time a newer local edit is coalesced into this item.
    public var rev: Int
}

/// Local-first store. The UI reads ONLY from here; the sync engine is the only writer of server state.
/// SQLite in WAL mode: readers never block on the writer, a week query is a single indexed range scan.
public final class LocalStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let cipher: PayloadCipher
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Longest event duration in the store; bounds the range scan so we can use the `start` index.
    private var maxSpan: Int64 = 86_400

    public let url: URL?

    /// `url == nil` → in-memory (tests, benchmarks).
    public init(url: URL?, cipher: PayloadCipher) throws {
        self.url = url
        self.cipher = cipher
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
        PRAGMA mmap_size=134217728;
        CREATE TABLE IF NOT EXISTS calendars(id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS events(
            id TEXT PRIMARY KEY,
            calendar_id TEXT NOT NULL,
            start INTEGER NOT NULL,
            end INTEGER NOT NULL,
            label_id TEXT,
            payload BLOB NOT NULL
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS events_by_start ON events(start, calendar_id);
        CREATE INDEX IF NOT EXISTS events_by_cal ON events(calendar_id);
        CREATE TABLE IF NOT EXISTS labels(id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS outbox(
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL, event_id TEXT NOT NULL, calendar_id TEXT NOT NULL,
            body BLOB NOT NULL, if_match TEXT, attempts INTEGER NOT NULL DEFAULT 0,
            rev INTEGER NOT NULL DEFAULT 0
        );
        """)
        if let s = try scalarInt("SELECT MAX(end - start) FROM events"), s > 0 { maxSpan = max(s, 86_400) }
        if let url { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: - Calendars

    public func upsert(calendars: [CalendarInfo]) throws {
        try transaction {
            try exec("DELETE FROM calendars")
            for c in calendars {
                try run("INSERT INTO calendars(id,payload) VALUES(?,?)", [.text(c.id), .blob(try seal(c))])
            }
        }
    }

    public func calendars() throws -> [CalendarInfo] {
        try query("SELECT payload FROM calendars") { stmt in try self.unseal(CalendarInfo.self, blob(stmt, 0)) }
    }

    // MARK: - Events

    public func upsert(events: [CalendarEvent]) throws {
        guard !events.isEmpty else { return }
        try transaction { try upsertRows(events) }
    }

    private func upsertRows(_ events: [CalendarEvent]) throws {
        guard !events.isEmpty else { return }
        do {
            let stmt = try prepare("""
            INSERT INTO events(id,calendar_id,start,end,label_id,payload) VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET calendar_id=excluded.calendar_id, start=excluded.start,
              end=excluded.end, label_id=excluded.label_id, payload=excluded.payload
            """)
            defer { sqlite3_finalize(stmt) }
            for e in events {
                let s = Int64(e.start.timeIntervalSince1970), en = Int64(e.end.timeIntervalSince1970)
                maxSpan = max(maxSpan, en - s)
                try bindAndStep(stmt, [.text(e.id), .text(e.calendarId), .int(s), .int(en),
                                       e.labelId.map { .text($0) } ?? .null, .blob(try seal(e))])
            }
        }
    }

    public func deleteEvents(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids { try run("DELETE FROM events WHERE id=?", [.text(id)]) }
        }
    }

    /// Atomically replace one calendar's events inside a window (snapshot sync for non-delta calendars).
    public func replaceEvents(calendarId: String, window: DateInterval, with events: [CalendarEvent]) throws {
        try transaction {
            try run("DELETE FROM events WHERE calendar_id=? AND start < ? AND end > ?",
                    [.text(calendarId), .int(Int64(window.end.timeIntervalSince1970)),
                     .int(Int64(window.start.timeIntervalSince1970))])
            try upsertRows(events)
        }
    }

    public func deleteEvents(calendarId: String) throws {
        try run("DELETE FROM events WHERE calendar_id=?", [.text(calendarId)])
    }

    public func event(id: String) throws -> CalendarEvent? {
        try query("SELECT payload FROM events WHERE id=?", [.text(id)]) { stmt in
            try self.unseal(CalendarEvent.self, blob(stmt, 0))
        }.first
    }

    /// Events overlapping [from, to) for the given calendars, ordered by start.
    public func events(from: Date, to: Date, calendarIds: Set<String>) throws -> [CalendarEvent] {
        let a = Int64(from.timeIntervalSince1970), b = Int64(to.timeIntervalSince1970)
        let rows = try query(
            "SELECT calendar_id, payload FROM events WHERE start >= ? AND start < ? AND end > ? ORDER BY start",
            [.int(a - maxSpan), .int(b), .int(a)]
        ) { stmt -> (String, Data) in (text(stmt, 0), blob(stmt, 1)) }
        var out: [CalendarEvent] = []
        out.reserveCapacity(rows.count)
        for (cal, payload) in rows where calendarIds.contains(cal) {
            out.append(try unseal(CalendarEvent.self, payload))
        }
        return out
    }

    public func eventCount() throws -> Int { Int(try scalarInt("SELECT COUNT(*) FROM events") ?? 0) }

    // MARK: - Labels

    public func replace(labels: [SensitivityLabel]) throws {
        try transaction {
            try exec("DELETE FROM labels")
            for l in labels { try run("INSERT INTO labels(id,payload) VALUES(?,?)", [.text(l.id), .blob(try seal(l))]) }
        }
    }

    public func labels() throws -> [SensitivityLabel] {
        try query("SELECT payload FROM labels") { stmt in try self.unseal(SensitivityLabel.self, blob(stmt, 0)) }
    }

    // MARK: - Key/value (delta links, sync timestamps)

    public func setValue(_ value: String?, for key: String) throws {
        if let value {
            try run("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    [.text(key), .text(value)])
        } else {
            try run("DELETE FROM kv WHERE key=?", [.text(key)])
        }
    }

    public func value(for key: String) throws -> String? {
        try query("SELECT value FROM kv WHERE key=?", [.text(key)]) { stmt in text(stmt, 0) }.first
    }

    // MARK: - Outbox

    @discardableResult
    public func enqueue(kind: OutboxItem.Kind, eventId: String, calendarId: String, body: Data, ifMatch: String?) throws -> Int64 {
        try run("INSERT INTO outbox(kind,event_id,calendar_id,body,if_match) VALUES(?,?,?,?,?)",
                [.text(kind.rawValue), .text(eventId), .text(calendarId), .blob(try cipher.seal(body)),
                 ifMatch.map { .text($0) } ?? .null])
        return sqlite3_last_insert_rowid(db)
    }

    /// One pending update per event: a second offline edit replaces the queued body (keeping the ORIGINAL
    /// If-Match, still the server version both edits were based on) instead of queueing a second PATCH that
    /// would 412 against our own first write.
    public func enqueueOrCoalesceUpdate(eventId: String, calendarId: String, body: Data, ifMatch: String?) throws {
        let existing = try query("SELECT seq FROM outbox WHERE kind='update' AND event_id=? ORDER BY seq LIMIT 1",
                                 [.text(eventId)]) { s in sqlite3_column_int64(s, 0) }.first
        if let seq = existing {
            try run("UPDATE outbox SET body=?, rev=rev+1 WHERE seq=?", [.blob(try cipher.seal(body)), .int(seq)])
        } else {
            try enqueue(kind: .update, eventId: eventId, calendarId: calendarId, body: body, ifMatch: ifMatch)
        }
    }

    /// Mark an item sent. Returns false if a newer edit was coalesced in while it was in flight; the item then
    /// stays queued, re-keyed to the server's new changeKey so the follow-up PATCH doesn't 412.
    public func completeOutbox(seq: Int64, rev: Int, newIfMatch: String?) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try run("DELETE FROM outbox WHERE seq=? AND rev=?", [.int(seq), .int(Int64(rev))])
        if sqlite3_changes(db) > 0 { return true }
        try run("UPDATE outbox SET if_match=?, attempts=0 WHERE seq=?", [newIfMatch.map { .text($0) } ?? .null, .int(seq)])
        return false
    }

    /// A create's id is local until Exchange assigns one; later queued edits/deletes follow the new id.
    public func remapOutbox(from old: String, to new: String) throws {
        try run("UPDATE outbox SET event_id=? WHERE event_id=?", [.text(new), .text(old)])
    }

    public func replaceOutboxBody(seq: Int64, body: Data) throws {
        try run("UPDATE outbox SET body=?, rev=rev+1 WHERE seq=?", [.blob(try cipher.seal(body)), .int(seq)])
    }

    public func outbox() throws -> [OutboxItem] {
        try query("SELECT seq,kind,event_id,calendar_id,body,if_match,attempts,rev FROM outbox ORDER BY seq") { s in
            OutboxItem(seq: sqlite3_column_int64(s, 0), kind: .init(rawValue: text(s, 1)) ?? .update,
                       eventId: text(s, 2), calendarId: text(s, 3), body: try self.cipher.open(blob(s, 4)),
                       ifMatch: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : text(s, 5),
                       attempts: Int(sqlite3_column_int(s, 6)), rev: Int(sqlite3_column_int(s, 7)))
        }
    }

    public func removeOutbox(seq: Int64) throws { try run("DELETE FROM outbox WHERE seq=?", [.int(seq)]) }
    public func bumpOutbox(seq: Int64) throws { try run("UPDATE outbox SET attempts=attempts+1 WHERE seq=?", [.int(seq)]) }

    /// Sign-out: drop everything. The caller also destroys the Keychain key.
    public func wipe() throws {
        try exec("DELETE FROM events; DELETE FROM calendars; DELETE FROM labels; DELETE FROM kv; DELETE FROM outbox; VACUUM;")
    }

    // MARK: - SQLite plumbing

    enum Bind { case text(String), int(Int64), blob(Data), null }

    private func seal<T: Encodable>(_ v: T) throws -> Data { try cipher.seal(encoder.encode(v)) }
    private func unseal<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T { try decoder.decode(t, from: cipher.open(d)) }
    /// Raw seal/open with the store cipher (sealed kv settings, CalendarSources.swift).
    func sealData(_ d: Data) throws -> Data { try cipher.seal(d) }
    func openData(_ d: Data) throws -> Data { try cipher.open(d) }

    private func errmsg() -> String { String(cString: sqlite3_errmsg(db)) }

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "exec"; sqlite3_free(err)
            throw StoreError.sqlite(m)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw StoreError.sqlite(errmsg()) }
        return stmt
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ stmt: OpaquePointer?, _ params: [Bind]) {
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

    private func bindAndStep(_ stmt: OpaquePointer?, _ params: [Bind]) throws {
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
        bind(stmt, params)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sqlite(errmsg()) }
    }

    private func run(_ sql: String, _ params: [Bind] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }
        try bindAndStep(stmt, params)
    }

    private func query<T>(_ sql: String, _ params: [Bind] = [], _ row: (OpaquePointer?) throws -> T) throws -> [T] {
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

    private func scalarInt(_ sql: String) throws -> Int64? {
        try query(sql) { s in sqlite3_column_type(s, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 0) }.first ?? nil
    }
}

private func text(_ s: OpaquePointer?, _ i: Int32) -> String {
    sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
}

private func blob(_ s: OpaquePointer?, _ i: Int32) -> Data {
    let n = Int(sqlite3_column_bytes(s, i))
    guard n > 0, let p = sqlite3_column_blob(s, i) else { return Data() }
    return Data(bytes: p, count: n)
}
