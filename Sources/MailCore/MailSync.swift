import Foundation
import CalendarCore

public enum MailSyncPhase: Sendable, Equatable { case idle, syncing, offline, error(String) }

public struct MailSyncStatus: Sendable, Equatable {
    public var phase: MailSyncPhase = .idle
    public var lastSync: Date?
    /// Mailbox → throttled-until (429/503 Retry-After seen during the last pass).
    public var throttledUntil: [String: Date] = [:]
    /// Human-readable notes for the status bar (no message content), e.g. late scheduled sends.
    public var notes: [String] = []
    /// Mailbox → why its last sync failed (403 no permission, 404 not found…). Cleared on the next success.
    public var mailboxErrors: [String: String] = [:]
    // LIFECYCLE-HOOK: Graph refused the token. `claimsChallenge` = the decoded CAE / Conditional Access claims JSON
    // (re-acquire with them); `authRequired` = a plain 401. Cleared after a pass that saw neither, or on re-auth.
    public var authRequired = false
    public var claimsChallenge: String?
    public init() {}
}

public enum MailChange: Sendable, Equatable {
    case status(MailSyncStatus)
    case messages(ids: [String])
    case folders(mailbox: String)
    case sendQueued(UUID, at: Date)
    case sendScheduled(draftId: String, at: Date)
    case sendCancelled(UUID)
    case sent(draftId: String)
    case sendFailed(draftId: String, reason: String)
    /// Client-side scheduled sends that became due while the app was closed/asleep went out now.
    case lateScheduledSends(count: Int)
}

/// Shared between the Graph client (records 429/503 Retry-After) and MailSync (reports it in status).
public final class ThrottleMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var until: [String: Date] = [:]
    private var count = 0
    public init() {}
    public func record(mailbox: String, retryAfter: TimeInterval) {
        lock.withLock {
            count += 1
            until[mailbox] = max(until[mailbox] ?? .distantPast, Date().addingTimeInterval(retryAfter))
        }
    }
    public var events: Int { lock.withLock { count } }
    /// Mailboxes throttled within the last pass (kept until read via `drain`).
    public func drain() -> [String: Date] { lock.withLock { let u = until; until = [:]; return u } }

    // LIFECYCLE-HOOK: 401s seen by the Graph client (claims = decoded CAE challenge, nil = plain 401).
    private var auth: (seen: Bool, claims: String?) = (false, nil)
    public func recordUnauthorized(claims: String?) {
        lock.withLock { auth = (true, claims ?? auth.claims) }
    }
    public func drainAuth() -> (seen: Bool, claims: String?) { lock.withLock { let a = auth; auth = (false, nil); return a } }
}

/// Local-first mail sync. The UI renders the store; this actor is the only writer of server state.
///
/// Scheduling (huge mailboxes + several shared ones):
///  * priority: own Inbox → other own folders (Sent always, others once opened) → pinned/opened shared mailboxes;
///  * ≤ 4 concurrent folder syncs per mailbox (Exchange's per-mailbox concurrency limit; the Graph client also
///    enforces it per mailbox);
///  * headers only, inside the live window (min(cache window, `liveWindowDays`)); bodies are lazy (LRU);
///  * older history inside the cache window is backfilled newest-first with a persisted, resumable cursor;
///  * shared mailboxes sync lazily: first `openMailbox`, or when pinned in settings.
public actor MailSync {
    let service: MailService
    let store: MailStore
    private let compliance: CachedLabelPolicyEngine
    let onChange: @Sendable (MailChange) -> Void
    private let throttle: ThrottleMonitor?
    private let clock: @Sendable () -> Date
    public private(set) var mailboxes: [String]
    public private(set) var status = MailSyncStatus()
    public private(set) var settings: MailSettings
    public let pageSize: Int
    public static let perMailboxConcurrency = 4
    public static let maxAttempts = 5

    private struct PendingSend { var task: Task<Void, Never>; var draftId: String; var mailbox: String; var sendAt: Date? }
    private var pendingSends: [UUID: PendingSend] = [:]
    private var isFlushing = false
    /// Old → new message id after a server move (Exchange gives a moved message a new id). Bounded; see `currentId`.
    private var idRemap: [String: String] = [:]
    private var remapOrder: [String] = []
    private var oof: [String: AutomaticReplies] = [:]

    public init(service: MailService, store: MailStore, compliance: CachedLabelPolicyEngine, mailboxes: [String] = ["me"],
                settings: MailSettings? = nil, throttle: ThrottleMonitor? = nil, pageSize: Int = 100,
                clock: @escaping @Sendable () -> Date = { Date() },
                onChange: @escaping @Sendable (MailChange) -> Void) {
        self.service = service; self.store = store; self.compliance = compliance; self.onChange = onChange
        self.throttle = throttle; self.clock = clock; self.pageSize = pageSize
        self.mailboxes = mailboxes.contains("me") ? mailboxes : ["me"] + mailboxes
        if let settings { self.settings = settings; try? store.save(settings: settings) }
        else { self.settings = (try? store.settings()) ?? MailSettings() }
        store.setPersistPolicy { [compliance] m, mailbox in
            MailContentPolicy.policy(for: m, mailbox: mailbox, engine: compliance)
        }
        try? store.setBodyCacheLimit(self.settings.bodyCacheBytes)
    }

    private func setPhase(_ p: MailSyncPhase) {
        status.phase = p
        if p == .idle { status.lastSync = clock() }
        onChange(.status(status))
    }

    private func note(_ s: String) {
        status.notes.append(s); if status.notes.count > 20 { status.notes.removeFirst() }
        FileHandle.standardError.write(Data("[MailSync] \(s)\n".utf8))   // content-free status text only
    }

    // MARK: Settings / mailboxes

    public func update(settings s: MailSettings) throws {
        let old = settings
        settings = s
        try store.save(settings: s)
        try store.setBodyCacheLimit(s.bodyCacheBytes)
        for mb in Set(Array(old.windows.keys) + Array(s.windows.keys) + mailboxes) where old.window(for: mb) != s.window(for: mb) {
            try applyWindowChange(mailbox: mb, from: old.window(for: mb), to: s.window(for: mb))
        }
    }

    /// Per-mailbox cache window. Shrinking prunes local headers + tokens outside it (bodies stay in the LRU);
    /// growing re-opens backfill.
    public func setWindow(_ w: CacheWindow, for mailbox: String) throws {
        var s = settings
        s.windows[mailbox] = w
        try update(settings: s)
    }

    private func applyWindowChange(mailbox: String, from old: CacheWindow, to new: CacheWindow) throws {
        let now = clock()
        let oc = old.cutoff(now: now), nc = new.cutoff(now: now)
        if let nc, oc == nil || nc > oc! {
            let n = try store.prune(mailbox: mailbox, before: nc)
            note("Cache window shrunk for a mailbox: \(n) header(s) pruned")
        }
        if let oc, nc == nil || nc! < oc {
            for f in try store.folders(mailbox: mailbox) { try store.setValue(nil, for: backfillKey(f.id)) }
        }
        onChange(.folders(mailbox: mailbox))
    }

    public func addMailbox(_ mailbox: String) { if !mailboxes.contains(mailbox) { mailboxes.append(mailbox) } }

    public func pin(mailbox: String, _ pinned: Bool = true) throws {
        addMailbox(mailbox)
        var s = settings
        if pinned { s.pinnedMailboxes.insert(mailbox) } else { s.pinnedMailboxes.remove(mailbox) }
        try update(settings: s)
    }

    /// First open of a shared/delegated mailbox: fetch its folder list and live-sync it.
    public func openMailbox(_ mailbox: String) async {
        addMailbox(mailbox)
        try? store.setValue("1", for: "openedMailbox:\(mailbox)")
        do { try await syncMailbox(mailbox); clearMailboxError(mailbox) }
        catch MailServiceError.offline { handle(MailServiceError.offline) }
        catch where mailbox != "me" { recordMailboxError(mailbox, error) }
        catch { handle(error) }
        refreshThrottle()
        if status.phase == .syncing { setPhase(.idle) }
    }

    private func recordMailboxError(_ mailbox: String, _ error: Error) {
        let e = MailboxAccessError(error)
        status.mailboxErrors[mailbox] = e.message
        note("A mailbox couldn't be synced (\(e.code))")
        onChange(.status(status))
    }

    private func clearMailboxError(_ mailbox: String) {
        if status.mailboxErrors.removeValue(forKey: mailbox) != nil { onChange(.status(status)) }
    }

    /// Remove a shared/delegated mailbox: it leaves the sync set and is unpinned, and its local cache is purged
    /// (headers, tokens, bodies, folder rows, delta/backfill/opened keys), so a later re-add starts clean instead of
    /// resuming from a stale delta link. "me" can't be removed.
    public func removeMailbox(_ mailbox: String) throws {
        guard mailbox != "me" else { return }
        mailboxes.removeAll { $0 == mailbox }
        for f in try store.folders(mailbox: mailbox) {
            while true {
                let ids = try store.messages(folderId: f.id, limit: 500).map(\.id)
                if ids.isEmpty { break }
                try store.deleteMessages(ids: ids, folderId: f.id)
            }
            try store.setValue(nil, for: deltaKey(f.id))
            try store.setValue(nil, for: backfillKey(f.id))
            try store.setValue(nil, for: "opened:\(f.id)")
        }
        try store.prune(mailbox: mailbox, before: .distantFuture)   // rows not reachable through a folder row
        try store.replace(folders: [], mailbox: mailbox)
        try store.setValue(nil, for: "openedMailbox:\(mailbox)")
        var s = settings
        s.pinnedMailboxes.remove(mailbox)
        s.windows[mailbox] = nil
        try update(settings: s)
        status.mailboxErrors[mailbox] = nil
        onChange(.folders(mailbox: mailbox))
    }

    /// Sidebar order of the non-own mailboxes ("me" stays first). Unknown entries are ignored.
    public func reorder(mailboxes order: [String]) {
        let rest = mailboxes.filter { $0 != "me" }
        mailboxes = ["me"] + order.filter { rest.contains($0) } + rest.filter { !order.contains($0) }
    }

    /// First open of a non-default folder: it joins the live set and syncs now.
    public func openFolder(_ folderId: String) async {
        try? store.setValue("1", for: "opened:\(folderId)")
        guard let f = try? store.folder(id: folderId) else { return }
        await syncFolders([f], mailbox: f.mailbox)
        refreshThrottle()
    }

    // MARK: Sync pass

    /// Quick Inbox delta (no status change, no backfill): new mail within ~30 s without a push backend.
    /// One small request when nothing changed; Graph allows 10,000 per 10 min per app per mailbox.
    public func quickInbox() async {
        guard status.phase != .syncing, (status.throttledUntil["me"] ?? .distantPast) < Date(),
              let inbox = try? store.folder(wellKnown: .inbox, mailbox: "me") else { return }
        await syncFolders([inbox], mailbox: "me")
        refreshThrottle()   // LIFECYCLE-HOOK: surface a 401 / claims challenge within a tick, not the next full pass
    }

    public func syncNow() async {
        setPhase(.syncing)
        await flush()                                   // launch/wake: due scheduled sends go out first
        do {
            try await syncMailbox("me")
            for mb in mailboxes where mb != "me" && isActive(mailbox: mb) {
                // One unreachable mailbox (permission withdrawn, deleted) must not stop the others syncing.
                do { try await syncMailbox(mb); clearMailboxError(mb) }
                catch MailServiceError.offline { throw MailServiceError.offline }
                catch { recordMailboxError(mb, error) }
            }
            for mb in mailboxes where mb == "me" || isActive(mailbox: mb) {
                _ = await backfill(mailbox: mb, maxPages: 1)   // low priority, after live sync
            }
            refreshThrottle(passSucceeded: true)
            if status.phase == .syncing { setPhase(.idle) }
        } catch {
            refreshThrottle()
            handle(error)
        }
    }

    /// LIFECYCLE-HOOK: re-authenticated (with the claims, if any): clear the sign-in state; the caller syncs again.
    public func clearAuthChallenge() {
        guard status.authRequired || status.claimsChallenge != nil else { return }
        status.authRequired = false; status.claimsChallenge = nil
        onChange(.status(status))
    }

    private func handle(_ error: Error) {
        if let e = error as? MailServiceError, e == .offline { setPhase(.offline) }
        else {
            FileHandle.standardError.write(Data("[MailSync] pass failed: \(String(describing: error).prefix(200))\n".utf8))
            setPhase(.error(String(describing: error).prefix(200).description))
        }
    }

    private func refreshThrottle(passSucceeded: Bool = false) {
        guard let throttle else { return }
        // LIFECYCLE-HOOK: 401 / claims challenge → status (the UI offers "Sign in again"); a clean full pass clears it.
        let a = throttle.drainAuth()
        if a.seen {
            let changed = !status.authRequired || (a.claims != nil && status.claimsChallenge != a.claims)
            status.authRequired = true
            if let c = a.claims { status.claimsChallenge = c }
            if changed { note(a.claims != nil ? "Sign-in needed: claims challenge" : "Sign-in needed: token refused"); onChange(.status(status)) }
        } else if passSucceeded, status.authRequired || status.claimsChallenge != nil {
            status.authRequired = false; status.claimsChallenge = nil
            onChange(.status(status))
        }
        let t = throttle.drain()
        if !t.isEmpty {
            status.throttledUntil.merge(t) { max($0, $1) }
            note("Throttled by Exchange (\(t.count) mailbox(es)); backing off")
            onChange(.status(status))
        }
    }

    private func isActive(mailbox: String) -> Bool {
        settings.pinnedMailboxes.contains(mailbox) || ((try? store.value(for: "openedMailbox:\(mailbox)")) ?? nil) != nil
    }

    /// Folders that take part in live sync: Inbox + Sent always, the rest once opened (or already tracking).
    private func liveFolders(_ mailbox: String) throws -> [MailFolder] {
        try store.folders(mailbox: mailbox).filter { f in
            if f.wellKnown == .inbox || f.wellKnown == .sentitems { return true }
            if f.id.hasPrefix("local-") { return false }
            return (try? store.value(for: "opened:\(f.id)")) ?? nil != nil || (try? store.value(for: deltaKey(f.id))) ?? nil != nil
        }
    }

    private func syncMailbox(_ mailbox: String) async throws {
        let folders = try await service.folders(mailbox: mailbox)
        guard mailboxes.contains(mailbox) else { return }   // removed while the request was in flight
        let placeholders = try store.folders(mailbox: mailbox).filter { $0.id.hasPrefix("local-") }
        try store.replace(folders: folders, mailbox: mailbox)
        for p in placeholders {
            if let real = folders.first(where: { $0.wellKnown == p.wellKnown }) { try store.moveAll(fromFolder: p.id, toFolder: real.id) }
            else { try store.upsert(folder: p) }
        }
        onChange(.folders(mailbox: mailbox))
        let live = try liveFolders(mailbox)
        // Priority: Inbox alone first, then the rest with a per-mailbox concurrency cap.
        let inbox = live.filter { $0.wellKnown == .inbox }
        await syncFolders(inbox, mailbox: mailbox)
        if case .offline = status.phase { throw MailServiceError.offline }
        await syncFolders(live.filter { $0.wellKnown != .inbox }, mailbox: mailbox)
        if case .offline = status.phase { throw MailServiceError.offline }
    }

    private func liveSince(_ mailbox: String) -> Date? {
        let now = clock()
        let live = Calendar.current.date(byAdding: .day, value: -settings.liveWindowDays, to: now)!
        guard let c = settings.window(for: mailbox).cutoff(now: now) else { return live }
        return max(c, live)
    }

    private func syncFolders(_ folders: [MailFolder], mailbox: String) async {
        guard !folders.isEmpty else { return }
        let svc = service, top = pageSize, since = liveSince(mailbox)
        var links: [String: String?] = [:]
        for f in folders { links[f.id] = (try? store.value(for: deltaKey(f.id))) ?? nil }
        let snapshot = links
        await withTaskGroup(of: (MailFolder, Result<MailDelta, Error>).self) { group in
            var queue = folders[...]
            func launch(_ f: MailFolder) {
                let link = snapshot[f.id] ?? nil
                group.addTask {
                    do { return (f, .success(try await svc.delta(folder: f, deltaLink: link, top: top, since: since))) }
                    catch MailServiceError.http(410, _) {
                        do { return (f, .success(try await svc.delta(folder: f, deltaLink: nil, top: top, since: since))) }
                        catch { return (f, .failure(error)) }
                    } catch { return (f, .failure(error)) }
                }
            }
            for _ in 0..<Self.perMailboxConcurrency { if let f = queue.popFirst() { launch(f) } }
            while let (folder, result) = await group.next() {
                switch result {
                case .success(let d): apply(d, folder: folder)
                case .failure(let e):
                    if let me = e as? MailServiceError, me == .offline { status.phase = .offline }
                    else { note("Folder sync failed (\(String(describing: e).prefix(300)))") }
                }
                if let f = queue.popFirst() { launch(f) }
            }
        }
    }

    private func apply(_ d: MailDelta, folder: MailFolder) {
        guard mailboxes.contains(folder.mailbox) else { return }   // mailbox removed while the delta was in flight
        do {
            let merged = try mergeServer(d.upserts)
            try store.upsert(messages: merged)
            try store.deleteMessages(ids: d.removedIds, folderId: folder.id)
            try store.setValue(d.deltaLink, for: deltaKey(folder.id))
            if !merged.isEmpty || !d.removedIds.isEmpty { onChange(.messages(ids: merged.map(\.id) + d.removedIds)) }
        } catch { note("Store write failed: \(type(of: error)) \(String(describing: error).prefix(160))") }
    }

    /// Server headers merged with local-only state; rows with queued local intent are left alone.
    private func mergeServer(_ incoming: [MailMessage]) throws -> [MailMessage] {
        var out: [MailMessage] = []
        out.reserveCapacity(incoming.count)
        for var m in incoming {
            if let local = try store.message(id: m.id, includeBody: false) {
                if local.pendingSync { continue }
                m.snoozedUntil = local.snoozedUntil
                m.scheduledSend = m.scheduledSend ?? local.scheduledSend
                // Delta / list pages carry no attachment list; keep the one the full message brought (reader chips,
                // inline images). Drafts can change theirs, so they take whatever the server sent.
                if m.attachments.isEmpty && !m.isDraft { m.attachments = local.attachments }
            }
            out.append(m)
        }
        return out
    }

    private func deltaKey(_ folderId: String) -> String { "mdelta:\(folderId)" }
    private func backfillKey(_ folderId: String) -> String { "backfill:\(folderId)" }

    // MARK: Older mail (on demand + background backfill)

    /// "Load older" in a folder: one server page strictly older than the oldest cached header.
    public func loadOlder(folderId: String, count: Int? = nil) async throws -> [MailMessage] {
        guard let f = try store.folder(id: folderId) else { throw MailServiceError.notFound }
        let rows = try await service.page(folder: f, before: try store.oldestCursor(folderId: folderId), top: count ?? pageSize)
        let merged = try mergeServer(rows)
        try store.upsert(messages: merged)
        onChange(.messages(ids: merged.map(\.id)))
        return merged
    }

    /// Backfill history inside the mailbox's cache window, newest first, resumable. Returns true when complete.
    @discardableResult
    public func backfill(mailbox: String, maxPages: Int = .max) async -> Bool {
        let cutoff = settings.window(for: mailbox).cutoff(now: clock())
        var allDone = true
        guard let folders = try? liveFolders(mailbox) else { return false }
        for f in folders {
            if ((try? store.value(for: backfillKey(f.id))) ?? nil) == "done" { continue }
            var pages = 0
            var done = false
            while pages < maxPages {
                let stored = ((try? store.value(for: backfillKey(f.id))) ?? nil).flatMap { Data(base64Encoded: $0) }
                    .flatMap { try? JSONDecoder().decode(MailCursor.self, from: $0) }
                let cursor = stored ?? (try? store.oldestCursor(folderId: f.id)) ?? nil
                let rows: [MailMessage]
                do { rows = try await service.page(folder: f, before: cursor, top: pageSize) }
                catch { allDone = false; if let e = error as? MailServiceError, e == .offline { return false }; break }
                let keep = rows.filter { cutoff == nil || $0.received >= cutoff! }
                if let merged = try? mergeServer(keep), !merged.isEmpty { try? store.upsert(messages: merged) }
                pages += 1
                if rows.count < pageSize || keep.count < rows.count || rows.isEmpty {
                    done = true
                    try? store.setValue("done", for: backfillKey(f.id))
                    break
                }
                let last = rows[rows.count - 1]
                let c = MailCursor(received: last.received, id: last.id)
                try? store.setValue((try? JSONEncoder().encode(c))?.base64EncodedString(), for: backfillKey(f.id))
                await Task.yield()
            }
            if !done { allDone = false }
        }
        return allDone
    }

    public func backfillProgress(mailbox: String) -> (oldestCached: Date?, done: Bool) {
        guard let folders = try? liveFolders(mailbox) else { return (nil, false) }
        let oldest = folders.compactMap { try? store.oldestCursor(folderId: $0.id) }.map(\.received).min()
        let done = folders.allSatisfy { ((try? store.value(for: backfillKey($0.id))) ?? nil) == "done" }
        return (oldest, done)
    }

    // MARK: Bodies (lazy)

    /// Header + body. Cached body if present; else fetched and put in the LRU (unless the policy forbids caching —
    /// then it is returned for display only).
    public func fetchBody(id: String) async throws -> MailMessage {
        if let m = try store.message(id: id), m.body != nil { return m }
        let local = try store.message(id: id, includeBody: false)
        let mailbox = local.map { store.mailbox(forFolder: $0.folderId) } ?? "me"
        var full = try await service.message(id: id, mailbox: mailbox)
        if let local { full.snoozedUntil = local.snoozedUntil; full.pendingSync = local.pendingSync }
        if local?.pendingSync != true { try store.upsert(message: full) }
        else if let b = full.body { try store.putBody(messageId: id, body: b) }
        return full
    }

    // MARK: Optimistic actions + outbox

    public func perform(_ action: MailAction, on messageId: String) async throws {
        guard var m = try store.message(id: messageId, includeBody: false) else { throw MailServiceError.notFound }
        let mailbox = store.mailbox(forFolder: m.folderId)
        let from = m.folderId
        switch action {
        case .markRead(let b):
            if m.isRead != b { try store.adjustCounts(folderId: from, unread: b ? -1 : 1) }
            m.isRead = b
        case .flag(let f): m.flag = f
        case .categorize(let c): m.categories = c
        case .move(let to): m.folderId = to
        case .delete: m.folderId = try localFolder(.deleteditems, mailbox: mailbox)
        case .snooze(let until): m.folderId = try localFolder(.snoozed, mailbox: mailbox); m.snoozedUntil = until
        case .unsnooze: m.folderId = try localFolder(.inbox, mailbox: mailbox); m.snoozedUntil = nil
        }
        if m.folderId != from {
            try store.adjustCounts(folderId: from, unread: m.isRead ? 0 : -1, total: -1)
            try store.adjustCounts(folderId: m.folderId, unread: m.isRead ? 0 : 1, total: 1)
        }
        m.pendingSync = true
        try store.upsert(message: m)
        try store.enqueue(messageId: messageId, mailbox: mailbox, op: .action(action))
        onChange(.messages(ids: [messageId]))
        await flush()
    }

    /// The id a message has now, following server-move remaps (A→B→C). Undo entries hold the id the message had
    /// when the action was taken; by the time ⌘Z runs the move may have flushed and re-keyed the store.
    public func currentId(_ id: String) -> String {
        var cur = id, hops = 0
        while let n = idRemap[cur], n != cur, hops < 32 { cur = n; hops += 1 }
        return cur
    }

    private func noteRemap(_ old: String, to new: String) {
        idRemap[old] = new
        remapOrder.append(old)
        if remapOrder.count > 2_000 {   // undo depth is bounded; drop the oldest remaps only
            for k in remapOrder.prefix(500) { idRemap.removeValue(forKey: k) }
            remapOrder.removeFirst(500)
        }
    }

    /// Folder id for a well-known target; a local placeholder until the server folder is known (e.g. Snoozed).
    private func localFolder(_ w: WellKnownFolder, mailbox: String) throws -> String {
        if let f = try store.folder(wellKnown: w, mailbox: mailbox) { return f.id }
        let id = "local-\(w.rawValue):\(mailbox)"
        try store.upsert(folder: MailFolder(id: id, displayName: w == .snoozed ? "Snoozed" : w.rawValue, wellKnown: w, mailbox: mailbox))
        return id
    }

    /// Drain the outbox (re-reading it until empty, so intents queued mid-flush and id changes are honoured).
    /// Offline → stop, keep queued. Client-side scheduled sends that aren't due are skipped.
    public func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        var late = 0
        var done = Set<Int64>()          // processed or deliberately skipped this flush
        pass: while true {
            guard let items = try? store.outbox(), let item = items.first(where: { !done.contains($0.seq) }) else { break }
            done.insert(item.seq)
            do {
                switch item.op {
                case .action(let action):
                    let server = try await service.apply(action, messageId: item.messageId, mailbox: item.mailbox)
                    try store.removeOutbox(seq: item.seq)
                    // The local header is authoritative for content: a PATCH/move response has no msip_labels and may
                    // carry body/recipients — taking it wholesale would drop the label and bypass the persist rule.
                    if var local = try store.message(id: item.messageId, includeBody: false) {
                        if let server {
                            local.id = server.id
                            if !server.folderId.isEmpty { local.folderId = server.folderId }
                            local.changeKey = server.changeKey ?? local.changeKey
                        }
                        local.pendingSync = try store.pendingOutboxCount(messageId: item.messageId) > 0
                        try store.replace(messageId: item.messageId, with: local)   // re-keys queued items on id change
                        if local.id != item.messageId { noteRemap(item.messageId, to: local.id) }
                        onChange(.messages(ids: [local.id]))
                    }
                case .send(let sendAt):
                    let now = clock()
                    if let sendAt, sendAt > now { continue pass }          // not due yet
                    try await service.send(draftId: item.messageId, mailbox: item.mailbox, sendAt: nil)
                    try store.removeOutbox(seq: item.seq)
                    try store.deleteMessages(ids: [item.messageId])
                    if let sendAt, now.timeIntervalSince(sendAt) > 60 { late += 1 }
                    onChange(.sent(draftId: item.messageId))
                }
            } catch MailServiceError.offline {
                if status.phase != .syncing { setPhase(.offline) } else { status.phase = .offline }
                break pass
            } catch MailServiceError.notFound {
                try? store.removeOutbox(seq: item.seq)
                if var m = try? store.message(id: item.messageId, includeBody: false), (try? store.pendingOutboxCount(messageId: m.id)) == 0 {
                    m.pendingSync = false; try? store.upsert(message: m)
                }
            } catch {
                try? store.bumpOutbox(seq: item.seq)
                if item.attempts + 1 >= Self.maxAttempts {
                    try? store.removeOutbox(seq: item.seq)
                    if var m = try? store.message(id: item.messageId, includeBody: false) { m.pendingSync = false; try? store.upsert(message: m) }
                    note("A queued change was dropped after \(Self.maxAttempts) attempts")
                    if case .send = item.op { onChange(.sendFailed(draftId: item.messageId, reason: String(describing: error).prefix(120).description)) }
                }
            }
        }
        if late > 0 {
            note("\(late) scheduled send(s) went out late (app was closed or asleep when due)")
            onChange(.lateScheduledSends(count: late))
            onChange(.status(status))
        }
    }

    // MARK: Snooze

    /// Move snoozed messages whose time has come back to the Inbox.
    public func wakeSnoozed(now: Date? = nil) async {
        guard let due = try? store.snoozedDue(at: now ?? clock()) else { return }
        for m in due { try? await perform(.unsnooze, on: m.id) }
    }

    // MARK: Drafts + send (undo window, send later)

    /// Reply/forward may not carry a lower-priority label than the original.
    public func enforceLabelFloor(_ draft: MailDraft) -> MailDraft {
        let original = draft.replyTo.flatMap { try? store.message(id: $0, includeBody: false) }
        return MailLabelFloor.enforce(draft, original: original, engine: compliance)
    }

    /// Where the draft is created: Send As → the shared mailbox; reply/forward → the original's mailbox;
    /// Send on Behalf → own mailbox with `from` = principal.
    public func draftMailbox(for draft: MailDraft) -> String {
        if let f = draft.from, f.mode == .sendAs { return f.mailbox }
        // COMPOSE2: an existing (e.g. reopened) draft stays where it lives, whatever its kind.
        if let id = draft.existingId, let d = try? store.message(id: id, includeBody: false) { return store.mailbox(forFolder: d.folderId) }
        if draft.kind != .new, let id = draft.replyTo, let o = try? store.message(id: id, includeBody: false) {
            return store.mailbox(forFolder: o.folderId)
        }
        return "me"
    }

    public func saveDraft(_ draft: MailDraft) async throws -> MailMessage {
        let d = enforceLabelFloor(draft)
        let mb = draftMailbox(for: d)
        let saved = try await service.saveDraft(d, mailbox: mb)
        if try store.folder(id: saved.folderId) == nil {   // mailbox not opened yet: remember where the draft lives
            try store.upsert(folder: MailFolder(id: saved.folderId, displayName: "Drafts", wellKnown: .drafts, mailbox: mb))
        }
        var local = saved
        local.scheduledSend = d.sendAt
        try store.upsert(message: local)
        onChange(.messages(ids: [saved.id]))
        return saved
    }

    /// Save the draft, then send after `undoSeconds` unless `undoSend` is called. Returns the undo token.
    public func queueSend(_ draft: MailDraft, undoSeconds: TimeInterval = 10) async throws -> UUID {
        let saved = try await saveDraft(draft)
        return queueSend(draftId: saved.id, mailbox: draftMailbox(for: draft), sendAt: draft.sendAt, undoSeconds: undoSeconds)
    }

    public func queueSend(draftId: String, mailbox: String, sendAt: Date? = nil, undoSeconds: TimeInterval = 10) -> UUID {
        let token = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(undoSeconds * 1000)))
            if Task.isCancelled { return }
            await self?.fireSend(token)
        }
        pendingSends[token] = PendingSend(task: task, draftId: draftId, mailbox: mailbox, sendAt: sendAt)
        onChange(.sendQueued(token, at: clock().addingTimeInterval(undoSeconds)))
        return token
    }

    /// Cancel within the undo window. The draft stays in Drafts.
    public func undoSend(_ token: UUID) -> Bool {
        guard let p = pendingSends.removeValue(forKey: token) else { return false }
        p.task.cancel()
        onChange(.sendCancelled(token))
        return true
    }

    /// Tests / shutdown: wait for every undo window to elapse and its send to finish.
    public func waitForPendingSends() async {
        while let p = pendingSends.values.first { await p.task.value }
    }

    public var pendingSendCount: Int { pendingSends.count }

    private func fireSend(_ token: UUID) async {
        guard let p = pendingSends.removeValue(forKey: token) else { return }   // undone meanwhile
        if let at = p.sendAt, at > clock(), !settings.serverDeferredSend {
            // Client-side send later: draft stays on the server, intent sealed in the outbox, sent when due
            // (or on next launch/wake if the Mac was off).
            _ = try? store.enqueue(messageId: p.draftId, mailbox: p.mailbox, op: .send(sendAt: at))
            markScheduled(p.draftId, at: at)
            onChange(.sendScheduled(draftId: p.draftId, at: at))
            return
        }
        do {
            // serverDeferredSend: UNVERIFIED Exchange deferred send (PidTagDeferredSendTime) via Graph.
            let deferred = settings.serverDeferredSend ? p.sendAt.flatMap { $0 > clock() ? $0 : nil } : nil
            try await service.send(draftId: p.draftId, mailbox: p.mailbox, sendAt: deferred)
            try? store.deleteMessages(ids: [p.draftId])
            if let deferred {
                // Held by Exchange until then (COMPOSE2): scheduled, not sent. Where it waits (Outbox / Drafts) is
                // UNVERIFIED, so both are re-synced and the item keeps its time for the list and Cancel.
                onChange(.sendScheduled(draftId: p.draftId, at: deferred))
                await syncHeld(mailbox: p.mailbox)
            } else {
                onChange(.sent(draftId: p.draftId))
                await syncSent(mailbox: p.mailbox)
            }
        } catch let refused as DeferredSendRefused {
            // Nothing was sent: fall back to client-side send later (COMPOSE2).
            if let at = p.sendAt {
                _ = try? store.enqueue(messageId: p.draftId, mailbox: p.mailbox, op: .send(sendAt: at))
                markScheduled(p.draftId, at: at)
                onChange(.sendScheduled(draftId: p.draftId, at: at))
            }
            _ = refused
        } catch MailServiceError.offline {
            _ = try? store.enqueue(messageId: p.draftId, mailbox: p.mailbox, op: .send(sendAt: nil))
            onChange(.sendFailed(draftId: p.draftId, reason: "offline — queued"))
        } catch {
            onChange(.sendFailed(draftId: p.draftId, reason: String(describing: error).prefix(120).description))
        }
    }

    /// The draft row shows its send time (list, reader: Cancel Scheduled Send).
    private func markScheduled(_ id: String, at: Date) {
        guard var m = try? store.message(id: id, includeBody: false) else { return }
        m.scheduledSend = at
        try? store.replace(messageId: id, with: m)
        onChange(.messages(ids: [id]))
    }

    private func syncHeld(mailbox: String) async {
        let held = [WellKnownFolder.outbox, .drafts].compactMap { try? store.folder(wellKnown: $0, mailbox: mailbox) }
        if !held.isEmpty { await syncFolders(held, mailbox: mailbox) }
    }

    /// COMPOSE2: cancel a scheduled send. Client-side (sealed outbox entry) → the entry is removed and the draft stays
    /// in Drafts. Server-held (deferred send) → moved back to Drafts — UNVERIFIED that Exchange allows moving a
    /// submitted item; a refusal is thrown to the caller. Returns true when it was client-side.
    @discardableResult
    public func cancelScheduledSend(id: String) async throws -> Bool {
        let queued = ((try? store.outbox()) ?? []).filter {
            if case .send = $0.op { return $0.messageId == id } else { return false }
        }
        if !queued.isEmpty {
            for q in queued { try? store.removeOutbox(seq: q.seq) }
            if var m = try store.message(id: id, includeBody: false) {
                m.scheduledSend = nil; m.pendingSync = false
                try store.replace(messageId: id, with: m)
            }
            onChange(.messages(ids: [id]))
            return true
        }
        guard let m = try store.message(id: id, includeBody: false) else { throw MailServiceError.notFound }
        let mb = store.mailbox(forFolder: m.folderId)
        guard let drafts = try store.folder(wellKnown: .drafts, mailbox: mb) else { throw MailServiceError.notFound }
        // Straight to the server (not the optimistic outbox): a refusal must reach the user, the item may still go.
        let server = try await service.apply(.move(toFolderId: drafts.id), messageId: id, mailbox: mb)
        var local = m
        local.folderId = drafts.id; local.scheduledSend = nil
        if let server { local.id = server.id; local.changeKey = server.changeKey ?? local.changeKey }
        try store.replace(messageId: id, with: local)
        if local.id != id { noteRemap(id, to: local.id) }
        onChange(.messages(ids: [local.id]))
        return false
    }

    private func syncSent(mailbox: String) async {
        guard let sent = try? store.folder(wellKnown: .sentitems, mailbox: mailbox) else { return }
        await syncFolders([sent], mailbox: mailbox)
    }

    // MARK: Search

    /// Local blind index first, then server `$search` for older content; merged newest-first, de-duplicated.
    public func search(_ text: String, mailbox: String = "me", limit: Int = 50, includeServer: Bool = true) async -> [MailMessage] {
        var seen = Set<String>()
        var out = ((try? store.search(text, mailbox: mailbox, limit: limit)) ?? []).filter { seen.insert($0.id).inserted }
        if includeServer { out += await serverSearch(text, mailbox: mailbox, limit: limit, known: seen).map { store.persistable($0) } }
        return Array(out.sorted { $0.received > $1.received }.prefix(limit))
    }

    /// Server `$search` hits not in `known` (raw, as Graph returned them; callers sanitise with `store.persistable`).
    /// SEARCHBOX-HOOK: shared by `search` and the main search box (`boxServerHits`).
    public func serverSearch(_ text: String, mailbox: String, limit: Int, known: Set<String>) async -> [MailMessage] {
        guard let remote = try? await service.search(text, mailbox: mailbox, top: limit) else { return [] }
        var seen = known, out: [MailMessage] = [], fresh: [MailMessage] = []
        for m in remote where seen.insert(m.id).inserted {
            out.append(m)
            if (try? store.message(id: m.id, includeBody: false)) == nil { fresh.append(m) }
        }
        // Server-only hits go into the store (sanitised by the persist policy) so the reader can open them;
        // rows already cached keep their local state (pending actions, snooze).
        if !fresh.isEmpty { try? store.upsert(messages: fresh) }
        return out
    }

    // MARK: Attachments (memory only: never written to the store)

    /// The service's attachment endpoint, if it has one (Graph, fixtures).
    nonisolated public var attachments: MailAttachmentFetching? { service as? MailAttachmentFetching }
    /// COMPOSE2: quoted history of a reply/forward draft, as the service carries it (display only).
    nonisolated public var draftHistory: DraftHistoryProviding? { service as? DraftHistoryProviding }

    // MARK: Rules

    public func rules(mailbox: String = "me") async throws -> [MailRule] { try await service.rules(mailbox: mailbox) }

    /// Validates (external forward block, permanent-delete confirmation) then saves. Returns rule + warnings.
    public func saveRule(_ rule: MailRule, mailbox: String = "me", confirmPermanentDelete: Bool = false) async throws -> (MailRule, [String]) {
        if rule.isReadOnly { throw RulePolicyError.readOnly }
        if rule.actions.permanentDelete == true && !confirmPermanentDelete { throw RulePolicyError.permanentDeleteNotConfirmed }
        let warnings = try RulePolicy.validate(rule, internalDomains: settings.internalDomains,
                                               blockExternalForward: settings.blockExternalForward)
        return (try await service.saveRule(rule, mailbox: mailbox), warnings)
    }

    public func deleteRule(id: String, mailbox: String = "me") async throws { try await service.deleteRule(id: id, mailbox: mailbox) }

    public func reorderRules(ids: [String], mailbox: String = "me") async throws -> [MailRule] {
        try await service.reorderRules(ids: ids, mailbox: mailbox)
    }

    // MARK: Automatic replies

    @discardableResult
    public func refreshAutomaticReplies(mailbox: String = "me") async throws -> AutomaticReplies {
        let r = try await service.automaticReplies(mailbox: mailbox)
        oof[mailbox] = r
        return r
    }

    public func setAutomaticReplies(_ r: AutomaticReplies, mailbox: String = "me") async throws -> AutomaticReplies {
        let saved = try await service.setAutomaticReplies(r, mailbox: mailbox)
        oof[mailbox] = saved
        return saved
    }

    /// For the "Automatic replies are on until …" banner (own mailbox).
    public var oofActive: Bool { oof["me"]?.isActive(at: clock()) ?? false }
    public var oofUntil: Date? { oofActive && oof["me"]?.status == .scheduled ? oof["me"]?.end : nil }
    public func automaticRepliesActive(mailbox: String) -> Bool { oof[mailbox]?.isActive(at: clock()) ?? false }

    public func regionalSettings(mailbox: String = "me") async throws -> MailboxRegionalSettings {
        try await service.regionalSettings(mailbox: mailbox)
    }
}
