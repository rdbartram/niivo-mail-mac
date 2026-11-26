import Foundation
import CalendarCore

// Contract for the Mail module. Shapes follow Microsoft Graph `message` / `mailFolder` closely so the Graph client is
// a thin mapping, but they are app-owned types: the UI, the store, the sync engine and the MCP server only see these.

public struct EmailAddress: Codable, Sendable, Hashable {
    public var name: String
    public var address: String
    public init(name: String, address: String) { self.name = name; self.address = address }
    public var display: String { name.isEmpty ? address : name }
}

public enum WellKnownFolder: String, Codable, Sendable, CaseIterable {
    case inbox, drafts, sentitems, deleteditems, archive, junkemail, outbox
    /// Client-side snooze target (Graph has no snooze). Created on first use as a normal folder.
    case snoozed
}

public struct MailFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var parentId: String?
    public var wellKnown: WellKnownFolder?
    public var unreadCount: Int
    public var totalCount: Int
    /// Mailbox this folder lives in: "me" or a shared/delegated mailbox address.
    public var mailbox: String
    public init(id: String, displayName: String, parentId: String? = nil, wellKnown: WellKnownFolder? = nil,
                unreadCount: Int = 0, totalCount: Int = 0, mailbox: String = "me") {
        self.id = id; self.displayName = displayName; self.parentId = parentId; self.wellKnown = wellKnown
        self.unreadCount = unreadCount; self.totalCount = totalCount; self.mailbox = mailbox
    }
}

public enum Importance: String, Codable, Sendable { case low, normal, high }
/// Graph `inferenceClassification`: Outlook's Focused Inbox.
public enum Focus: String, Codable, Sendable { case focused, other }

public struct FollowUpFlag: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case notFlagged, flagged, complete }
    public var status: Status
    public var due: Date?
    public init(status: Status = .notFlagged, due: Date? = nil) { self.status = status; self.due = due }
}

public struct AttachmentInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var contentType: String
    public var size: Int
    public var isInline: Bool
    public init(id: String, name: String, contentType: String, size: Int, isInline: Bool = false) {
        self.id = id; self.name = name; self.contentType = contentType; self.size = size; self.isInline = isInline
    }
}

public struct MailMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var folderId: String
    public var conversationId: String
    public var subject: String
    public var from: EmailAddress?
    public var toRecipients: [EmailAddress]
    public var ccRecipients: [EmailAddress]
    public var received: Date
    public var sent: Date?
    public var preview: String?
    /// HTML or text body. nil until fetched, and never persisted for protected/unknown labels.
    public var body: String?
    public var bodyIsHTML: Bool
    public var isRead: Bool
    public var isDraft: Bool
    public var importance: Importance
    public var focus: Focus
    public var flag: FollowUpFlag
    public var categories: [String]
    public var hasAttachments: Bool
    public var attachments: [AttachmentInfo]
    /// Purview label GUID from `msip_labels`, if any.
    public var labelId: String?
    /// Where `labelId` came from (LabelProvenance.swift). nil on rows cached before it existed = not proven ours.
    public var labelOrigin: LabelOrigin?
    /// Outlook legacy sensitivity == private.
    public var isPrivate: Bool
    public var changeKey: String?
    public var webLink: URL?
    /// Local-only state.
    public var pendingSync: Bool
    public var snoozedUntil: Date?
    public var scheduledSend: Date?
    /// Graph `sender`: who actually sent it (differs from `from` for send-on-behalf). Optional for old payloads.
    public var sender: EmailAddress?

    public init(id: String, folderId: String, conversationId: String, subject: String, from: EmailAddress?,
                toRecipients: [EmailAddress] = [], ccRecipients: [EmailAddress] = [], received: Date,
                sent: Date? = nil, preview: String? = nil, body: String? = nil, bodyIsHTML: Bool = false,
                isRead: Bool = false, isDraft: Bool = false, importance: Importance = .normal,
                focus: Focus = .focused, flag: FollowUpFlag = .init(), categories: [String] = [],
                hasAttachments: Bool = false, attachments: [AttachmentInfo] = [], labelId: String? = nil,
                isPrivate: Bool = false, changeKey: String? = nil, webLink: URL? = nil, pendingSync: Bool = false,
                snoozedUntil: Date? = nil, scheduledSend: Date? = nil, sender: EmailAddress? = nil) {
        self.id = id; self.folderId = folderId; self.conversationId = conversationId; self.subject = subject
        self.from = from; self.toRecipients = toRecipients; self.ccRecipients = ccRecipients
        self.received = received; self.sent = sent; self.preview = preview; self.body = body
        self.bodyIsHTML = bodyIsHTML; self.isRead = isRead; self.isDraft = isDraft; self.importance = importance
        self.focus = focus; self.flag = flag; self.categories = categories; self.hasAttachments = hasAttachments
        self.attachments = attachments; self.labelId = labelId; self.isPrivate = isPrivate
        self.changeKey = changeKey; self.webLink = webLink; self.pendingSync = pendingSync
        self.snoozedUntil = snoozedUntil; self.scheduledSend = scheduledSend; self.sender = sender
    }

    /// Label + provenance together (one helper, so they can't diverge).
    public mutating func applyLabel(_ r: LabelReading) { labelId = r.labelId; labelOrigin = r.origin }
    /// Takes the authoritative label from a freshly fetched copy of the same message.
    public mutating func adoptLabel(of full: MailMessage) { labelId = full.labelId; labelOrigin = full.labelOrigin }
}

/// How a draft is sent relative to the signed-in user.
public enum SendMode: String, Codable, Sendable, Hashable { case selfSend, sendAs, sendOnBehalf }

/// A "From" choice. Graph cannot list Send As / Send on Behalf grants (EXO PowerShell only, e.g.
/// Get-RecipientPermission / Get-Mailbox GrantSendOnBehalfTo), so identities come from config + opened mailboxes.
public struct SendIdentity: Codable, Sendable, Hashable {
    public var address: String
    public var name: String
    /// Mailbox the draft is created in: "me" or the shared mailbox address.
    public var mailbox: String
    public var mode: SendMode
    public init(address: String, name: String, mailbox: String = "me", mode: SendMode = .selfSend) {
        self.address = address; self.name = name; self.mailbox = mailbox; self.mode = mode
    }
    public var emailAddress: EmailAddress { EmailAddress(name: name, address: address) }
}

/// Keyset cursor for paging a folder newest → oldest. No OFFSET anywhere.
public struct MailCursor: Codable, Sendable, Hashable {
    public var received: Date
    public var id: String
    public init(received: Date, id: String) { self.received = received; self.id = id }
}

/// How much header history a mailbox keeps locally. Bodies are governed separately by the LRU size cap.
public enum CacheWindow: Codable, Sendable, Hashable {
    case days(Int), years(Int), everything
    public static let presets: [CacheWindow] = [.days(30), .days(90), .years(1), .years(2), .years(5), .everything]
    public static let `default`: CacheWindow = .days(90)
    /// Oldest received date kept; nil = everything.
    public func cutoff(now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .days(let d): return calendar.date(byAdding: .day, value: -d, to: now)
        case .years(let y): return calendar.date(byAdding: .year, value: -y, to: now)
        case .everything: return nil
        }
    }
}

/// Per-account mail settings, persisted (sealed JSON) in the mail store's kv table.
public struct MailSettings: Codable, Sendable, Hashable {
    /// Per-mailbox header window; mailboxes without an entry use `defaultWindow` (own) / `sharedDefaultWindow`.
    public var windows: [String: CacheWindow]
    public var defaultWindow: CacheWindow
    public var sharedDefaultWindow: CacheWindow
    /// Live delta never reaches further back than this (Graph caps a filtered delta at 5,000 items); older
    /// history within the window comes from backfill paging.
    public var liveWindowDays: Int
    /// Size cap for the encrypted body LRU.
    public var bodyCacheBytes: Int
    /// Shared/delegated mailboxes synced in the background (others sync on first open).
    public var pinnedMailboxes: Set<String>
    /// Configured From identities (Graph can't enumerate send grants).
    public var identities: [SendIdentity]
    /// UNVERIFIED path: Exchange deferred send via PidTagDeferredSendTime (0x3FEF) is documented for EWS/add-ins
    /// only. false (default) → send-later is client-side (draft stays on the server, MailSync sends when due).
    public var serverDeferredSend: Bool = false
    /// UNVERIFIED: write the label as the msip_labels extended property on outgoing drafts. Graph has no label
    /// property and msip_labels can't be set as an internetMessageHeader. Off by default.
    public var writeLabelProperty: Bool = false
    /// Refuse rules that forward/redirect outside `internalDomains`.
    public var blockExternalForward: Bool = true
    public var internalDomains: Set<String> = []
    /// New-mail notifications + Dock badge (nil = never configured = off). Optional so older payloads still decode.
    public var notifications: MailNotificationSettings?
    /// Senders whose remote images always load (lower-cased addresses). Never honoured for labelled mail.
    public var remoteImageSenders: [String]?
    /// Additional mailboxes (shared / delegated / other user) the user added with "Add mailbox…", in sidebar order.
    /// Optional (like the next three) so settings sealed before these existed still decode — a missing key on a
    /// non-optional field would fail the whole decode and reset every setting. Accessors: MailboxList.swift.
    public var addedMailboxes: [String]?
    /// Sidebar order of the non-own mailboxes ("me" is always first).
    public var mailboxOrder: [String]?
    /// Mailboxes whose sidebar section is collapsed.
    public var collapsedMailboxes: [String]?
    /// Config-declared mailboxes (AppConfig shared/delegated) the user removed: stay removed across launches.
    public var removedMailboxes: [String]?
    public init(windows: [String: CacheWindow] = [:], defaultWindow: CacheWindow = .default,
                sharedDefaultWindow: CacheWindow = .days(30), liveWindowDays: Int = 90,
                bodyCacheBytes: Int = 500 * 1024 * 1024, pinnedMailboxes: Set<String> = [], identities: [SendIdentity] = []) {
        self.windows = windows; self.defaultWindow = defaultWindow; self.sharedDefaultWindow = sharedDefaultWindow
        self.liveWindowDays = liveWindowDays; self.bodyCacheBytes = bodyCacheBytes
        self.pinnedMailboxes = pinnedMailboxes; self.identities = identities
    }
    public func window(for mailbox: String) -> CacheWindow {
        windows[mailbox] ?? (mailbox == "me" ? defaultWindow : sharedDefaultWindow)
    }
}

/// Something the user writes. Reply/forward keep `replyTo` so the Graph reply endpoints preserve threading.
public struct MailDraft: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case new, reply, replyAll, forward }
    public var kind: Kind
    public var replyTo: String?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var bodyHTML: String
    public var importance: Importance
    /// Label to apply. A reply/forward may not go below the original's label priority.
    public var labelId: String?
    /// Send later (Exchange deferred send). nil = now (after the undo window).
    public var sendAt: Date?
    /// From identity. nil = the signed-in user.
    public var from: SendIdentity?
    /// Backing store for `attachments` (ComposerAttachments.swift); optional so older encodings still decode.
    var _attachments: [OutgoingAttachment]?
    /// Server draft this save updates in place (PATCH) instead of creating a new one. Set by the caller at save
    /// time only, never part of the composer's own draft value.
    public var existingId: String?
    /// COMPOSE2: reply / forward without the quoted history (Exchange's createReply body is dropped). nil = include.
    public var omitHistory: Bool?
    /// PURVIEW-HOOK: the msip_labels value to stamp (LabelMetadata). nil = nothing stamped (no label, no tenant, or
    /// the kill switch). Optional so older encodings still decode.
    public var labelHeader: String?
    public init(kind: Kind = .new, replyTo: String? = nil, to: [EmailAddress] = [], cc: [EmailAddress] = [],
                bcc: [EmailAddress] = [], subject: String = "", bodyHTML: String = "", importance: Importance = .normal,
                labelId: String? = nil, sendAt: Date? = nil, from: SendIdentity? = nil) {
        self.kind = kind; self.replyTo = replyTo; self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject
        self.bodyHTML = bodyHTML; self.importance = importance; self.labelId = labelId; self.sendAt = sendAt
        self.from = from
    }
}

/// One user intent on an existing message. Applied optimistically, queued in the encrypted outbox, flushed to Graph.
public enum MailAction: Codable, Sendable, Hashable {
    case markRead(Bool)
    case flag(FollowUpFlag)
    case categorize([String])
    case move(toFolderId: String)
    case delete                       // → Deleted Items (soft)
    case snooze(until: Date)          // → Snoozed folder + local wake-up
    case unsnooze                     // → back to Inbox
}

public struct MailDelta: Sendable {
    public var upserts: [MailMessage]
    public var removedIds: [String]
    public var deltaLink: String?
    public init(upserts: [MailMessage], removedIds: [String], deltaLink: String?) {
        self.upserts = upserts; self.removedIds = removedIds; self.deltaLink = deltaLink
    }
}

public enum MailServiceError: Error, Sendable, Equatable {
    case notFound, conflict, offline, forbidden, http(Int, String)
    /// Exchange refused Send As / Send on Behalf for this address (Graph `ErrorSendAsDenied`).
    case sendAsDenied(String)
}

/// Backend boundary: GraphMailService (real) and FixtureMailService (synthetic) implement this.
public protocol MailService: Sendable {
    func me() async throws -> EmailAddress
    func folders(mailbox: String) async throws -> [MailFolder]
    /// Incremental sync of one folder (headers only, no bodies). `deltaLink == nil` → initial round limited to
    /// messages received at/after `since` (nil = service default). `top` = page size.
    func delta(folder: MailFolder, deltaLink: String?, top: Int, since: Date?) async throws -> MailDelta
    /// Older headers on demand, newest first, strictly older than `before` (keyset; nil = newest).
    func page(folder: MailFolder, before: MailCursor?, top: Int) async throws -> [MailMessage]
    /// Full message incl. body (and `labelId` from msip_labels).
    func message(id: String, mailbox: String) async throws -> MailMessage
    func apply(_ action: MailAction, messageId: String, mailbox: String) async throws -> MailMessage?
    /// Creates a draft (new, or via createReply/createReplyAll/createForward). Returns the server draft.
    func saveDraft(_ draft: MailDraft, mailbox: String) async throws -> MailMessage
    /// Adds one attachment to an existing draft (< 3 MB: POST …/attachments; larger: upload session). `saveDraft`
    /// already attaches `draft.attachments`; this is for callers adding to a draft they hold the id of.
    func addAttachment(_ attachment: OutgoingAttachment, toDraft draftId: String, mailbox: String) async throws -> AttachmentInfo
    /// Sends an existing draft. `sendAt` → deferred send.
    func send(draftId: String, mailbox: String, sendAt: Date?) async throws
    /// Free text search on the server (Graph `$search`).
    func search(_ query: String, mailbox: String, top: Int) async throws -> [MailMessage]

    // Server-side inbox rules (`/mailFolders/inbox/messageRules`).
    func rules(mailbox: String) async throws -> [MailRule]
    /// POST when `rule.id == nil`, else PATCH.
    func saveRule(_ rule: MailRule, mailbox: String) async throws -> MailRule
    func deleteRule(id: String, mailbox: String) async throws
    // Automatic replies + regional settings (`/mailboxSettings`). Other mailboxes → `.forbidden` on write.
    func automaticReplies(mailbox: String) async throws -> AutomaticReplies
    func setAutomaticReplies(_ replies: AutomaticReplies, mailbox: String) async throws -> AutomaticReplies
    func regionalSettings(mailbox: String) async throws -> MailboxRegionalSettings

    // Folder management (`/mailFolders`). Well-known folders are refused with `MailFolderError.protected`.
    /// `parentId == nil` → top level (under msgfolderroot).
    func createFolder(displayName: String, parentId: String?, mailbox: String) async throws -> MailFolder
    func renameFolder(id: String, displayName: String, mailbox: String) async throws -> MailFolder
    /// `toParentId == nil` → top level.
    func moveFolder(id: String, toParentId: String?, mailbox: String) async throws -> MailFolder
    /// The folder and its contents go to Deleted Items (a folder already in Deleted Items is removed).
    func deleteFolder(id: String, mailbox: String) async throws
    /// Marks every unread message in the folder read; returns how many changed.
    func markAllRead(folderId: String, mailbox: String) async throws -> Int
    /// Deletes every message and sub-folder in the folder (Deleted Items / Junk); returns how many messages.
    func emptyFolder(folderId: String, mailbox: String) async throws -> Int
}

public extension MailService {
    /// Re-number rules in the given order (sequence 1...n) — one PATCH per rule whose sequence changes.
    func reorderRules(ids: [String], mailbox: String) async throws -> [MailRule] {
        var byId = Dictionary(try await rules(mailbox: mailbox).compactMap { r in r.id.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        var out: [MailRule] = []
        for (i, id) in ids.enumerated() {
            guard var r = byId.removeValue(forKey: id) else { throw MailServiceError.notFound }
            if r.sequence != i + 1 { r.sequence = i + 1; r = try await saveRule(r, mailbox: mailbox) }
            out.append(r)
        }
        return out
    }

    /// Original contract shape: initial round uses the service's default window.
    func delta(folder: MailFolder, deltaLink: String?, top: Int) async throws -> MailDelta {
        try await delta(folder: folder, deltaLink: deltaLink, top: top, since: nil)
    }
}
