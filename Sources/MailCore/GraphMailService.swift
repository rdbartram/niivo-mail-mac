import Foundation
import CalendarCore

/// Microsoft Graph v1.0 mail client. Same init shape as `GraphCalendarService` (token closure + URLSession) so the
/// URLProtocol stub pattern works.
///
/// Fetched from learn.microsoft.com (2026-11-19) and followed:
///  * message delta `/mailFolders/{id}/messages/delta`: `$select`, `$top`, `$expand`, `$filter=receivedDateTime ge …`
///    (filtered delta returns at most 5,000 items), `Prefer: odata.maxpagesize`, nextLink/deltaLink tokens.
///  * createReply/createReplyAll/createForward: set `comment` OR body, not both → create empty, PATCH body later.
///  * Sending from another mailbox (Mail.Send.Shared): Send As via `/users/{shared}` → shared Sent Items (needs Full
///    Access too); Send on Behalf via `/me` with `from`; refusal = `ErrorSendAsDenied`; Graph cannot list grants.
///  * messageRulePredicates / messageRuleActions property names; `PATCH /me/mailboxSettings` automaticRepliesSetting.
/// Everything else here is marked `UNVERIFIED:` at the call site or below:
///  * UNVERIFIED: messageRule endpoint paths + top-level properties (sequence/isEnabled/hasError/isReadOnly) — standard
///    Graph shape, page not fetched.
///  * UNVERIFIED: well-known names accepted as move `destinationId`; Snoozed folder `$filter`/POST at msgfolderroot.
///  * UNVERIFIED: `$search` escaping rules for messages (fetched rules were the directory-object section).
///  * UNVERIFIED: v1.0 `mailFolder` lacking `wellKnownName` — inferred (the property appeared on `mailboxFolder`);
///    resolving via `GET /mailFolders/{wellKnownName}` works either way.
///  * Delegated OOF writes to another mailbox: docs list `PATCH /users/{id}/mailboxSettings` with delegated
///    MailboxSettings.ReadWrite but no `.Shared` scope — inconclusive, so refused conservatively (`.forbidden`).
public final class GraphMailService: MailService, @unchecked Sendable {
    public typealias TokenProvider = @Sendable () async throws -> String

    private let token: TokenProvider
    let session: URLSession   // internal: GraphMailService+Attachments.swift (upload-session PUTs)
    private let throttle: ThrottleMonitor?
    private let limiter = MailboxLimiter(limit: MailSync.perMailboxConcurrency)
    private let base = URL(string: "https://graph.microsoft.com/v1.0")!
    /// UNVERIFIED path, off by default: write msip_labels on outgoing drafts as an extended property.
    public let writeLabelProperty: Bool
    /// Default initial window when `since` is nil.
    public let defaultWindowDays: Int
    /// ACCOUNTS-HOOK: the owning account's tenant. Labels are parsed against it, never against another account's
    /// (docs/ACCOUNTS.md A9). nil = default account → the `MIPMetadata.homeTenantId` shim.
    public let accountTenant: String?
    var labelTenant: String? { MIPMetadata.tenant(forAccount: accountTenant) }
    let lock = NSLock()
    var snoozedFolder: [String: String] = [:]
    /// Mailbox → well-known folder ids from the last `folders(mailbox:)` (folder CRUD refuses them).
    var wellKnownIds: [String: Set<String>] = [:]
    /// Mailbox → msgfolderroot id (top-level folders' parentFolderId), mapped to `parentId == nil`.
    var rootIds: [String: String?] = [:]
    private var draftFrom: [String: String] = [:]
    /// Per server draft: quoted history from createReply/createForward (so a PATCH can rebuild the body) and the
    /// server ids of attachments already uploaded (so autosave doesn't re-upload them). Memory only.
    private var draftCarry: [String: DraftCarry] = [:]
    private var draftUploads: [String: [UUID: String]] = [:]

    static let labelProp = MIPMetadata.extendedPropertyId
    /// PidTagDeferredSendTime as a Graph single-value extended property id.
    public static let deferredSendProp = "SystemTime 0x3FEF"
    static let select = "id,subject,from,sender,toRecipients,ccRecipients,receivedDateTime,sentDateTime,bodyPreview,isRead,isDraft,importance,inferenceClassification,flag,categories,hasAttachments,conversationId,changeKey,webLink,parentFolderId"
    /// `message` has no `sensitivity` property (only `event` does; $select'ing it is a 400 on every message request),
    /// so the Outlook private flag comes from MAPI PR_SENSITIVITY (0x0036; 2 = private) next to the label header.
    static let sensitivityProp = "Integer 0x0036"
    static let expandLabel = "singleValueExtendedProperties($filter=id eq '\(labelProp)' or id eq '\(sensitivityProp)')"
    /// Message *delta* rejects an `or` inside the extended-property filter (400 "Parsing OData Select and Expand failed:
    /// Value cannot be null (initialState)", live 2026-11-19), so delta asks for the label only; the private flag is
    /// then re-decided from the full message when it is opened (fetchBody) and on list/search pages.
    static let expandLabelOnly = "singleValueExtendedProperties($filter=id eq '\(labelProp)')"

    public init(token: @escaping TokenProvider, session: URLSession = .shared, throttle: ThrottleMonitor? = nil,
                writeLabelProperty: Bool = false, defaultWindowDays: Int = 90, accountTenant: String? = nil) {
        self.accountTenant = accountTenant?.lowercased()
        self.token = token; self.session = session; self.throttle = throttle
        self.writeLabelProperty = writeLabelProperty; self.defaultWindowDays = defaultWindowDays
    }

    func p(_ mailbox: String) -> String { mailbox == "me" ? "me" : "users/\(mailbox)" }
    func url(_ path: String, _ q: [String: String] = [:]) -> URL { base.appending(path: path).mailQuery(q) }

    // MARK: Identity + folders

    public func me() async throws -> EmailAddress {
        let m: GMMe = try await get(url("me", ["$select": "displayName,mail,userPrincipalName"]), mailbox: "me")
        return EmailAddress(name: m.displayName ?? "", address: m.mail ?? m.userPrincipalName ?? "")
    }

    static let folderSelect = "id,displayName,parentFolderId,unreadItemCount,totalItemCount,childFolderCount"
    static let wellKnownNames: [WellKnownFolder] = [.inbox, .drafts, .sentitems, .deleteditems, .archive, .junkemail, .outbox]

    public func folders(mailbox: String) async throws -> [MailFolder] {
        var raw: [GMFolder] = []
        var next: URL? = url("\(p(mailbox))/mailFolders", ["$top": "100", "$select": Self.folderSelect])
        while let u = next {
            let page: GMPage<GMFolder> = try await get(u, mailbox: mailbox)
            raw += page.value; next = page.nextLink.flatMap(URL.init(string:))
        }
        raw += try await childFolderTree(of: raw, mailbox: mailbox)   // any depth (GraphMailService+Folders)
        // Well-known ids via one $batch (v1.0 mailFolder has no wellKnownName property).
        let reqs = Self.wellKnownNames.enumerated().map { i, w in
            ["id": "\(i)", "method": "GET", "url": "/\(p(mailbox))/mailFolders/\(w.rawValue)?$select=id"]
        }
        let resp: GMBatch = try await send(url("$batch"), method: "POST", mailbox: mailbox,
                                           json: ["requests": reqs])
        var known: [String: WellKnownFolder] = [:]
        for r in resp.responses where r.status == 200 {
            if let i = Int(r.id), i < Self.wellKnownNames.count, let id = r.body?.id { known[id] = Self.wellKnownNames[i] }
        }
        let topLevelParent = raw.first(where: { known[$0.id] == .inbox })?.parentFolderId
        lock.withLock { wellKnownIds[mailbox] = Set(known.keys); rootIds[mailbox] = topLevelParent }
        return raw.map { f in
            var w = known[f.id]
            if w == nil, f.displayName == "Snoozed", f.parentFolderId == topLevelParent { w = .snoozed }
            if w == .snoozed { lock.withLock { snoozedFolder[mailbox] = f.id } }
            return MailFolder(id: f.id, displayName: f.displayName ?? "", parentId: f.parentFolderId == topLevelParent ? nil : f.parentFolderId,
                              wellKnown: w, unreadCount: f.unreadItemCount ?? 0, totalCount: f.totalItemCount ?? 0, mailbox: mailbox)
        }
    }

    // MARK: Sync

    public func delta(folder: MailFolder, deltaLink: String?, top: Int, since: Date?) async throws -> MailDelta {
        do { return try await deltaRound(folder, deltaLink: deltaLink, top: top, since: since) }
        catch MailServiceError.http(410, _) where deltaLink != nil {
            return try await deltaRound(folder, deltaLink: nil, top: top, since: since)   // sync state expired → restart
        }
    }

    private func deltaRound(_ folder: MailFolder, deltaLink: String?, top: Int, since: Date?) async throws -> MailDelta {
        let start = since ?? Calendar.current.date(byAdding: .day, value: -defaultWindowDays, to: Date())!
        // $expand on message delta is documented as supported; UNVERIFIED against a tenant that the msip_labels
        // extended property comes back on delta pages (fallback would be a $batch like the calendar client).
        // No $expand on message delta: Graph 400s it ("Parsing OData Select and Expand failed … initialState", live
        // 2026-11-19). Labels + private flag are fetched for the changed items afterwards ($batch, 20 per call).
        var next: URL = deltaLink.flatMap(URL.init(string:)) ?? url("\(p(folder.mailbox))/mailFolders/\(folder.id)/messages/delta", [
            "$select": Self.select,
            "$filter": "receivedDateTime ge \(Self.iso(start))",
        ])
        var ups: [MailMessage] = [], removed: [String] = [], partial: [String] = []
        while true {
            let page: GMPage<GMMessage> = try await get(next, mailbox: folder.mailbox, prefer: ["odata.maxpagesize=\(top)"])
            for m in page.value {
                if m.removed != nil { removed.append(m.id); continue }
                // Delta can return an item with only some properties (seen live: no receivedDateTime → shown as 1970).
                if m.receivedDateTime == nil && m.sentDateTime == nil { partial.append(m.id); continue }
                if let mm = m.toModel(defaultFolder: folder.id, tenant: labelTenant) { ups.append(mm) }
            }
            if let n = page.nextLink, let u = URL(string: n) { next = u; continue }
            ups += await fetchFull(partial, mailbox: folder.mailbox, defaultFolder: folder.id)
            await enrichLabels(&ups, mailbox: folder.mailbox)
            return MailDelta(upserts: ups, removedIds: removed, deltaLink: page.deltaLink)
        }
    }

    /// Full header fields for items delta returned incomplete ($batch, 20 per call). Items that still come back
    /// without a date are dropped rather than stored as 1970; the next pass or history paging brings them.
    private func fetchFull(_ ids: [String], mailbox: String, defaultFolder: String) async -> [MailMessage] {
        var out: [MailMessage] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 20, ids.count)]); start += 20
            let reqs = chunk.enumerated().map { i, id in
                ["id": "\(i)", "method": "GET", "url": "/\(p(mailbox))/messages/\(id)?$select=\(Self.select)"]
            }
            guard let resp: GMMessageBatch = try? await send(url("$batch"), method: "POST", mailbox: mailbox, json: ["requests": reqs])
            else { continue }
            for r in resp.responses where r.status == 200 {
                guard let m = r.body, m.receivedDateTime != nil || m.sentDateTime != nil,
                      let mm = m.toModel(defaultFolder: defaultFolder, tenant: labelTenant) else { continue }
                out.append(mm)
            }
        }
        return out
    }

    /// msip_labels + PR_SENSITIVITY for messages that came without them (delta). Best effort per item: a failed
    /// sub-request keeps what the item had. Fails closed where it matters: the reader re-decides from the full message.
    private func enrichLabels(_ msgs: inout [MailMessage], mailbox: String) async {
        guard !msgs.isEmpty else { return }
        var at: [String: Int] = [:]
        for (i, m) in msgs.enumerated() { at[m.id] = i }
        let ids = msgs.map(\.id)
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 20, ids.count)]); start += 20
            let reqs = chunk.enumerated().map { i, id in
                ["id": "\(i)", "method": "GET",
                 "url": "/\(p(mailbox))/messages/\(id)?$select=id&$expand=\(Self.expandLabel)"]
            }
            guard let resp: GMPropBatch = try? await send(url("$batch"), method: "POST", mailbox: mailbox, json: ["requests": reqs])
            else { continue }
            for r in resp.responses where r.status == 200 {
                guard let n = Int(r.id), n < chunk.count, let i = at[chunk[n]] else { continue }
                let props = r.body?.singleValueExtendedProperties ?? []
                let probe = GMMessage(id: chunk[n], singleValueExtendedProperties: props)
                msgs[i].applyLabel(probe.labelReading(tenant: labelTenant))
                msgs[i].isPrivate = probe.privateFromProps
            }
        }
    }

    public func page(folder: MailFolder, before: MailCursor?, top: Int) async throws -> [MailMessage] {
        var q = ["$select": Self.select, "$expand": Self.expandLabel, "$orderby": "receivedDateTime desc", "$top": "\(top)"]
        // Keyset on the server: `lt` the oldest cached second. Messages sharing that exact second with the cursor
        // can be skipped (Graph has no id tiebreak); acceptable for history paging.
        if let before { q["$filter"] = "receivedDateTime lt \(Self.iso(before.received))" }
        let page: GMPage<GMMessage> = try await get(url("\(p(folder.mailbox))/mailFolders/\(folder.id)/messages", q), mailbox: folder.mailbox)
        return page.value.compactMap { $0.toModel(defaultFolder: folder.id, tenant: labelTenant) }
    }

    public func message(id: String, mailbox: String) async throws -> MailMessage {
        let m: GMMessage = try await get(url("\(p(mailbox))/messages/\(id)", [
            "$select": Self.select + ",body",
            // UNVERIFIED: two $expand clauses (attachments + extended property) in one request.
            "$expand": "attachments($select=id,name,contentType,size,isInline),\(Self.expandLabel)",
        ]), mailbox: mailbox, prefer: [#"outlook.body-content-type="html""#])
        guard let mm = m.toModel(defaultFolder: "", tenant: labelTenant) else { throw MailServiceError.http(500, "bad message") }
        return mm
    }

    // MARK: Actions

    public func apply(_ action: MailAction, messageId: String, mailbox: String) async throws -> MailMessage? {
        let item = "\(p(mailbox))/messages/\(messageId)"
        func move(_ dest: String) async throws -> MailMessage? {
            // move returns the message in the destination folder — its id can change; callers re-key on it.
            let m: GMMessage = try await send(url("\(item)/move"), method: "POST", mailbox: mailbox, json: ["destinationId": dest])
            return m.toModel(defaultFolder: dest, tenant: labelTenant)
        }
        switch action {
        case .markRead(let b): return try await patch(item, ["isRead": b], mailbox: mailbox)
        case .flag(let f): return try await patch(item, ["flag": Self.flagJSON(f)], mailbox: mailbox)
        case .categorize(let c): return try await patch(item, ["categories": c], mailbox: mailbox)
        case .move(let to): return try await move(to)
        case .delete: return try await move("deleteditems")      // soft delete (well-known name accepted as destinationId)
        case .snooze: return try await move(try await ensureSnoozedFolder(mailbox))   // Graph has no snooze
        case .unsnooze: return try await move("inbox")
        }
    }

    private func patch(_ path: String, _ body: [String: Any], mailbox: String) async throws -> MailMessage? {
        let m: GMMessage = try await send(url(path), method: "PATCH", mailbox: mailbox, json: body)
        return m.toModel(defaultFolder: "", tenant: labelTenant)
    }

    /// Top-level "Snoozed" folder under msgfolderroot (POST /mailFolders creates at the root).
    private func ensureSnoozedFolder(_ mailbox: String) async throws -> String {
        if let id = lock.withLock({ snoozedFolder[mailbox] }) { return id }
        let found: GMPage<GMFolder> = try await get(url("\(p(mailbox))/mailFolders",
                                                        ["$filter": "displayName eq 'Snoozed'", "$select": "id"]), mailbox: mailbox)
        let id: String
        if let f = found.value.first { id = f.id } else {
            let created: GMFolder = try await send(url("\(p(mailbox))/mailFolders"), method: "POST", mailbox: mailbox,
                                                   json: ["displayName": "Snoozed", "isHidden": false])
            id = created.id
        }
        lock.withLock { snoozedFolder[mailbox] = id }
        return id
    }

    // MARK: Drafts + send

    public func saveDraft(_ draft: MailDraft, mailbox: String) async throws -> MailMessage {
        let mbPath = p(mailbox)
        var fields: [String: Any] = ["importance": draft.importance.rawValue]
        if !draft.to.isEmpty || draft.kind == .new { fields["toRecipients"] = draft.to.map(Self.recipient) }
        if !draft.cc.isEmpty || draft.kind == .new { fields["ccRecipients"] = draft.cc.map(Self.recipient) }
        if !draft.bcc.isEmpty { fields["bccRecipients"] = draft.bcc.map(Self.recipient) }
        if !draft.subject.isEmpty || draft.kind == .new { fields["subject"] = draft.subject }
        if let f = draft.from, f.mode != .selfSend { fields["from"] = Self.recipient(f.emailAddress) }
        if let h = draft.labelHeader, let l = draft.labelId,   // PURVIEW-HOOK: full MIP metadata (LabelMetadata)
           h.lowercased().contains("msip_label_\(l.lowercased())_") {   // stale after a floor bump → legacy path
            fields["singleValueExtendedProperties"] = [["id": Self.labelProp, "value": h]]
        } else if writeLabelProperty, let l = draft.labelId {
            // UNVERIFIED: Graph has no label property; msip_labels as a named extended property is unproven
            // (no SiteId/Method stamp, no encryption — MIP SDK needed for that). Behind MailSettings.writeLabelProperty.
            fields["singleValueExtendedProperties"] = [["id": Self.labelProp, "value": "MSIP_Label_\(l)_Enabled=true; MSIP_Label_\(l)_Method=Standard"]]
        }
        if let eid = draft.existingId, let m = try await updateDraft(eid, draft: draft, fields: fields, mailbox: mailbox) {
            return m
        }
        let created: GMMessage
        let embedded = draft.kind == .new ? AttachmentUpload.embeddable(draft.attachments) : []
        do {
            switch draft.kind {
            case .new:
                fields["body"] = ["contentType": "HTML", "content": draft.bodyHTML]
                if !embedded.isEmpty { fields["attachments"] = embedded.map(Self.fileAttachmentJSON) }   // UNVERIFIED: attachments in the create POST
                created = try await sendStamped(url("\(mbPath)/messages"), method: "POST", mailbox: mailbox, fields: fields,   // PURVIEW-HOOK
                                         prefer: [#"outlook.body-content-type="html""#])
            case .reply, .replyAll, .forward:
                guard let orig = draft.replyTo else { throw MailServiceError.notFound }
                let op = draft.kind == .reply ? "createReply" : draft.kind == .replyAll ? "createReplyAll" : "createForward"
                let shell: GMMessage = try await send(url("\(mbPath)/messages/\(orig)/\(op)"), method: "POST", mailbox: mailbox,
                                                      json: [:], prefer: [#"outlook.body-content-type="html""#])
                var carry = DraftCarry.shell(shell.body?.content ?? "")
                if draft.omitHistory == true { carry = carry.withoutHistory }   // COMPOSE2: reply without history
                lock.withLock { draftCarry[shell.id] = carry }
                fields["body"] = ["contentType": "HTML", "content": carry.wrap(draft.bodyHTML)]
                created = try await sendStamped(url("\(mbPath)/messages/\(shell.id)"), method: "PATCH", mailbox: mailbox, fields: fields,
                                         prefer: [#"outlook.body-content-type="html""#])
            }
        } catch MailServiceError.forbidden where draft.from != nil && draft.from?.mode != .selfSend {
            throw MailServiceError.sendAsDenied(draft.from!.address)
        }
        if let f = draft.from { lock.withLock { draftFrom[created.id] = f.address } }
        let embeddedIds = Set(embedded.map(\.id))
        do {
            var uploaded: [UUID: String] = [:]
            for a in embedded { uploaded[a.id] = "?" + a.name }   // server id unknown: "?name", resolved by name on removal
            for a in draft.attachments where !embeddedIds.contains(a.id) {
                uploaded[a.id] = try await addAttachment(a, toDraft: created.id, mailbox: mailbox).id
            }
            let up = uploaded
            lock.withLock { draftUploads[created.id] = up }
        } catch {
            // Don't orphan a half-attached draft: the caller retries with a fresh one.
            let _: GMEmpty? = try? await send(url("\(mbPath)/messages/\(created.id)"), method: "DELETE", mailbox: mailbox, json: nil)
            throw error
        }
        guard var m = created.toModel(defaultFolder: "", tenant: labelTenant) else { throw MailServiceError.http(500, "bad draft") }
        if m.labelId == nil, let l = draft.labelId { m.labelId = l; m.labelOrigin = .home }   // our own stamp
        return m
    }

    /// PATCH an existing server draft: header fields + body, upload only new attachments, delete removed ones.
    /// nil → the caller creates a fresh draft (draft gone, or a reply whose quoted history isn't known here).
    private func updateDraft(_ id: String, draft: MailDraft, fields base: [String: Any], mailbox: String) async throws -> MailMessage? {
        let mbPath = p(mailbox)
        var fields = base
        switch draft.kind {
        case .new:
            fields["body"] = ["contentType": "HTML", "content": draft.bodyHTML]
        case .reply, .replyAll, .forward:
            // History known from createReply (this session) or recovered from the saved body: never a second createReply.
            var carry = lock.withLock { draftCarry[id] }
            if carry == nil {
                struct B: Decodable { var body: GMMessage.Body? }
                do {
                    let saved: B = try await send(url("\(mbPath)/messages/\(id)", ["$select": "body"]), method: "GET", mailbox: mailbox,
                                                  json: nil, prefer: [#"outlook.body-content-type="html""#])
                    let html = saved.body?.content ?? ""
                    carry = DraftCarry.split(html)?.carry ?? DraftCarry.shell(html.isEmpty ? "" : html)
                } catch MailServiceError.notFound { return nil }
                catch MailServiceError.http(404, _) { return nil }
                let c = carry
                lock.withLock { draftCarry[id] = c }
            }
            fields["body"] = ["contentType": "HTML", "content": carry!.wrap(draft.bodyHTML)]
        }
        let updated: GMMessage
        do {
            updated = try await sendStamped(url("\(mbPath)/messages/\(id)"), method: "PATCH", mailbox: mailbox, fields: fields,   // PURVIEW-HOOK
                                     prefer: [#"outlook.body-content-type="html""#])
        } catch MailServiceError.notFound { return nil }
        catch MailServiceError.http(404, _) { return nil }
        if let f = draft.from { lock.withLock { draftFrom[id] = f.address } }
        var uploaded = lock.withLock { draftUploads[id] } ?? [:]
        let wanted = Set(draft.attachments.map(\.id))
        // Removed since the last save.
        let removed = uploaded.filter { !wanted.contains($0.key) }
        if !removed.isEmpty {
            var serverIds = removed.values.filter { !$0.hasPrefix("?") }
            let names = Set(removed.values.filter { $0.hasPrefix("?") }.map { String($0.dropFirst()) })
            if !names.isEmpty {   // embedded at create time: look the ids up by name
                struct L: Decodable { struct A: Decodable { var id: String; var name: String? }; var value: [A] }
                if let l: L = try? await send(url("\(mbPath)/messages/\(id)/attachments", ["$select": "id,name"]), method: "GET", mailbox: mailbox, json: nil) {
                    serverIds += l.value.filter { names.contains($0.name ?? "") }.map(\.id)
                }
            }
            for sid in serverIds {
                let _: GMEmpty? = try? await send(url("\(mbPath)/messages/\(id)/attachments/\(sid)"), method: "DELETE", mailbox: mailbox, json: nil)
            }
            for k in removed.keys { uploaded[k] = nil }
            let up = uploaded
            lock.withLock { draftUploads[id] = up }
        }
        for a in draft.attachments where uploaded[a.id] == nil {
            // Recorded after each upload: a later failure must not make the retry upload this one again.
            let sid = try await addAttachment(a, toDraft: id, mailbox: mailbox).id
            uploaded[a.id] = sid
            lock.withLock { draftUploads[id, default: [:]][a.id] = sid }
        }
        guard var m = updated.toModel(defaultFolder: "", tenant: labelTenant) else { throw MailServiceError.http(500, "bad draft") }
        if m.labelId == nil, let l = draft.labelId { m.labelId = l; m.labelOrigin = .home }   // our own stamp
        return m
    }

    /// Insert the user's HTML at the top of the quoted body (inside <body> when present).
    static func prepend(_ html: String, to quoted: String) -> String { DraftCarry.shell(quoted).wrap(html) }

    /// COMPOSE2: the quoted history this service carries for a reply/forward draft (display only).
    public func draftHistory(id: String) -> String? { lock.withLock { draftCarry[id] }?.historyDocument }

    public func send(draftId: String, mailbox: String, sendAt: Date?) async throws {
        let item = "\(p(mailbox))/messages/\(draftId)"
        let fromAddr = lock.withLock { draftFrom[draftId] } ?? mailbox
        do {
            if let sendAt {
                // PidTagDeferredSendTime (0x3FEF, PT_SYSTIME): Learn documents it for EWS (CreateItem + ExtendedProperty
                // 0x3FEF0040, "Send email messages by using EWS") and MAPI ("earlier than now → sent immediately"). Through
                // Graph as `SystemTime 0x3FEF` it is UNVERIFIED, as is the folder Exchange holds it in. Only used when
                // MailSettings.serverDeferredSend is on. A refused PATCH → DeferredSendRefused (nothing sent yet), so the
                // caller can fall back to the client outbox without risking a double send.
                do {
                    let _: GMMessage = try await send(url(item), method: "PATCH", mailbox: mailbox,
                                                      json: ["singleValueExtendedProperties": [["id": Self.deferredSendProp, "value": Self.iso(sendAt)]]])
                } catch MailServiceError.offline { throw MailServiceError.offline }
                catch { throw DeferredSendRefused(reason: String(describing: error).prefix(120).description) }
            }
            let _: GMEmpty = try await send(url("\(item)/send"), method: "POST", mailbox: mailbox, json: nil)
            lock.withLock { _ = draftFrom.removeValue(forKey: draftId) }
        } catch MailServiceError.forbidden where fromAddr != "me" {
            throw MailServiceError.sendAsDenied(fromAddr)
        }
    }

    public func search(_ query: String, mailbox: String, top: Int) async throws -> [MailMessage] {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // $search results are sorted by sent date server-side; no $orderby/$filter allowed alongside.
        let page: GMPage<GMMessage> = try await get(url("\(p(mailbox))/messages", [
            // UNVERIFIED: $expand alongside $search. Needed so hits carry their label (else AIAccessPolicy would rate
            // them unlabelled); if Graph rejects the combination, fall back to a $batch label fetch per hit.
            "$search": "\"\(escaped)\"", "$select": Self.select, "$top": "\(min(top, 1000))", "$expand": Self.expandLabel,
        ]), mailbox: mailbox)
        return page.value.compactMap { $0.toModel(defaultFolder: "", tenant: labelTenant) }
    }

    // MARK: Rules

    public func rules(mailbox: String) async throws -> [MailRule] {
        let page: GMPage<GMRule> = try await get(url("\(p(mailbox))/mailFolders/inbox/messageRules"), mailbox: mailbox)
        return page.value.map { $0.toModel() }.sorted { $0.sequence < $1.sequence }
    }

    public func saveRule(_ rule: MailRule, mailbox: String) async throws -> MailRule {
        let path = "\(p(mailbox))/mailFolders/inbox/messageRules"
        let r: GMRule
        if let id = rule.id {
            r = try await send(url("\(path)/\(id)"), method: "PATCH", mailbox: mailbox, json: Self.ruleJSON(rule))
        } else {
            r = try await send(url(path), method: "POST", mailbox: mailbox, json: Self.ruleJSON(rule))
        }
        return r.toModel()
    }

    public func deleteRule(id: String, mailbox: String) async throws {
        let _: GMEmpty = try await send(url("\(p(mailbox))/mailFolders/inbox/messageRules/\(id)"), method: "DELETE", mailbox: mailbox, json: nil)
    }

    /// Exact Graph `messageRule` shape (empty collections / nil values omitted).
    public static func ruleJSON(_ r: MailRule) -> [String: Any] {
        var o: [String: Any] = ["displayName": r.displayName, "sequence": r.sequence, "isEnabled": r.isEnabled,
                                "conditions": predicatesJSON(r.conditions), "actions": actionsJSON(r.actions)]
        if let e = r.exceptions { o["exceptions"] = predicatesJSON(e) }
        return o
    }

    static func predicatesJSON(_ c: RuleConditions) -> [String: Any] {
        var o: [String: Any] = [:]
        if !c.fromAddresses.isEmpty { o["fromAddresses"] = c.fromAddresses.map(recipient) }
        if !c.sentToAddresses.isEmpty { o["sentToAddresses"] = c.sentToAddresses.map(recipient) }
        for (k, v) in [("subjectContains", c.subjectContains), ("bodyContains", c.bodyContains),
                       ("senderContains", c.senderContains), ("headerContains", c.headerContains)] where !v.isEmpty { o[k] = v }
        if let i = c.importance { o["importance"] = i.rawValue }
        for (k, v) in [("hasAttachments", c.hasAttachments), ("sentToMe", c.sentToMe), ("sentOnlyToMe", c.sentOnlyToMe),
                       ("sentCcMe", c.sentCcMe), ("isMeetingRequest", c.isMeetingRequest)] { if let v { o[k] = v } }
        if let s = c.withinSizeRange { o["withinSizeRange"] = ["minimumSize": s.minimumSize, "maximumSize": s.maximumSize] }
        return o
    }

    static func actionsJSON(_ a: RuleActions) -> [String: Any] {
        var o: [String: Any] = [:]
        if let v = a.moveToFolder { o["moveToFolder"] = v }
        if let v = a.copyToFolder { o["copyToFolder"] = v }
        for (k, v) in [("delete", a.delete), ("permanentDelete", a.permanentDelete), ("markAsRead", a.markAsRead),
                       ("stopProcessingRules", a.stopProcessingRules)] { if let v { o[k] = v } }
        if let i = a.markImportance { o["markImportance"] = i.rawValue }
        if !a.assignCategories.isEmpty { o["assignCategories"] = a.assignCategories }
        for (k, v) in [("forwardTo", a.forwardTo), ("forwardAsAttachmentTo", a.forwardAsAttachmentTo), ("redirectTo", a.redirectTo)]
        where !v.isEmpty { o[k] = v.map(recipient) }
        return o
    }

    // MARK: Automatic replies + regional settings

    public func automaticReplies(mailbox: String) async throws -> AutomaticReplies {
        // Other users' mailboxSettings need app permissions (delegated MailboxSettings.Read has no .Shared variant);
        // a 403 maps to `.forbidden`. UNVERIFIED for delegated reads of a shared mailbox.
        let s: GMMailboxSettings = try await get(url("\(p(mailbox))/mailboxSettings", ["$select": "automaticRepliesSetting"]), mailbox: mailbox)
        return s.automaticRepliesSetting?.toModel() ?? AutomaticReplies()
    }

    public func setAutomaticReplies(_ r: AutomaticReplies, mailbox: String) async throws -> AutomaticReplies {
        // Delegated MailboxSettings.ReadWrite covers only the signed-in user; there is no delegated .Shared scope,
        // so writing another mailbox's automatic replies needs app permissions or EXO. Refuse up front.
        guard mailbox == "me" else { throw MailServiceError.forbidden }
        var a: [String: Any] = ["status": r.status.rawValue, "externalAudience": r.externalAudience.rawValue,
                                "internalReplyMessage": r.internalReplyHTML, "externalReplyMessage": r.externalReplyHTML]
        if let s = r.start { a["scheduledStartDateTime"] = ["dateTime": Self.graphLocal(s), "timeZone": "UTC"] }
        if let e = r.end { a["scheduledEndDateTime"] = ["dateTime": Self.graphLocal(e), "timeZone": "UTC"] }
        let s: GMMailboxSettings = try await send(url("me/mailboxSettings"), method: "PATCH", mailbox: mailbox,
                                                  json: ["automaticRepliesSetting": a])
        var out = s.automaticRepliesSetting?.toModel() ?? r
        if out.timeZone.isEmpty { out.timeZone = r.timeZone }
        return out
    }

    public func regionalSettings(mailbox: String) async throws -> MailboxRegionalSettings {
        let s: GMMailboxSettings = try await get(url("\(p(mailbox))/mailboxSettings", ["$select": "timeZone,workingHours,dateFormat,timeFormat,language"]), mailbox: mailbox)
        return MailboxRegionalSettings(timeZone: s.timeZone, workingHours: s.workingHours.map {
            WorkingHours(daysOfWeek: $0.daysOfWeek ?? [], startTime: $0.startTime ?? "", endTime: $0.endTime ?? "", timeZone: $0.timeZone?.name ?? "")
        }, dateFormat: s.dateFormat, timeFormat: s.timeFormat, locale: s.language?.locale)   // A11Y-HOOK
    }

    // MARK: HTTP

    func get<T: Decodable>(_ url: URL, mailbox: String, prefer: [String] = []) async throws -> T {
        try await send(url, method: "GET", mailbox: mailbox, json: nil, prefer: prefer)
    }

    func send<T: Decodable>(_ url: URL, method: String, mailbox: String, json: Any?, prefer: [String] = []) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) }
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("niivo-mail/0.1", forHTTPHeaderField: "User-Agent")
        if !prefer.isEmpty { req.setValue(prefer.joined(separator: ", "), forHTTPHeaderField: "Prefer") }

        await limiter.acquire(mailbox)
        defer { Task { await limiter.release(mailbox) } }
        for attempt in 0..<5 {
            let data: Data, resp: URLResponse
            do { (data, resp) = try await session.data(for: req) }
            catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                           .cannotFindHost, .dataNotAllowed].contains(e.code) {
                throw MailServiceError.offline
            }
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            switch status {
            case 200..<300:
                if T.self == GMEmpty.self { return GMEmpty() as! T }
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch { throw MailServiceError.http(status, "decode") }
            case 429, 503, 504:
                let wait = RetryAfter.seconds(http?.value(forHTTPHeaderField: "Retry-After"), fallback: pow(2, Double(attempt)))   // LIFECYCLE-HOOK: HTTP-date too
                throttle?.record(mailbox: mailbox, retryAfter: wait)
                try await Task.sleep(for: .milliseconds(Int(min(wait, 30) * 1000)))
            default:
                let msg = String(data: data, encoding: .utf8) ?? ""
                if msg.contains("ErrorSendAsDenied") { throw MailServiceError.sendAsDenied(mailbox) }
                switch status {
                case 401:   // LIFECYCLE-HOOK: CAE claims challenge / refused token → sync status (still .forbidden to callers)
                    throttle?.recordUnauthorized(claims: ClaimsChallenge.claims(fromWWWAuthenticate: http?.value(forHTTPHeaderField: "WWW-Authenticate")))
                    throw MailServiceError.forbidden
                case 403: throw MailServiceError.forbidden
                case 404: throw MailServiceError.notFound
                case 409, 412: throw MailServiceError.conflict
                default:
                    if msg.contains("SyncStateNotFound") || msg.contains("syncStateNotFound") { throw MailServiceError.http(410, "sync state") }
                    throw MailServiceError.http(status, String(msg.prefix(200)))
                }
            }
        }
        throw MailServiceError.http(429, "throttled")
    }

    /// Attachment bytes (GraphMailService+Inline.swift): GET returning the raw body. Never cached: with the default
    /// shared session (whose URLCache can write to disk) an ephemeral session without a cache is used instead.
    func rawGET(_ url: URL, mailbox: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        req.setValue("niivo-mail/0.1", forHTTPHeaderField: "User-Agent")
        let s = session === URLSession.shared ? Self.noCacheSession : session
        await limiter.acquire(mailbox)
        defer { Task { await limiter.release(mailbox) } }
        for attempt in 0..<5 {
            let data: Data, resp: URLResponse
            do { (data, resp) = try await s.data(for: req) }
            catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                           .cannotFindHost, .dataNotAllowed].contains(e.code) {
                throw MailServiceError.offline
            }
            let http = resp as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200..<300: return data
            case 429, 503, 504:
                let wait = RetryAfter.seconds(http?.value(forHTTPHeaderField: "Retry-After"), fallback: pow(2, Double(attempt)))   // LIFECYCLE-HOOK: HTTP-date too
                throttle?.record(mailbox: mailbox, retryAfter: wait)
                try await Task.sleep(for: .milliseconds(Int(min(wait, 30) * 1000)))
            case 401:   // LIFECYCLE-HOOK
                throttle?.recordUnauthorized(claims: ClaimsChallenge.claims(fromWWWAuthenticate: http?.value(forHTTPHeaderField: "WWW-Authenticate")))
                throw MailServiceError.forbidden
            case 403: throw MailServiceError.forbidden
            case 404: throw MailServiceError.notFound
            case let c: throw MailServiceError.http(c, "attachment")
            }
        }
        throw MailServiceError.http(429, "throttled")
    }
    static let noCacheSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    // MARK: Helpers

    static func recipient(_ e: EmailAddress) -> [String: Any] { ["emailAddress": ["name": e.name, "address": e.address]] }

    static func flagJSON(_ f: FollowUpFlag) -> [String: Any] {
        var o: [String: Any] = ["flagStatus": f.status.rawValue]
        if let d = f.due { o["dueDateTime"] = ["dateTime": graphLocal(d), "timeZone": "UTC"] }
        return o
    }

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    /// Graph `dateTimeTimeZone.dateTime` (no zone suffix).
    static func graphLocal(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: d)
    }
    static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
    /// dateTimeTimeZone → Date. UTC and IANA zones handled; Windows zone names (e.g. "W. Europe Standard Time")
    /// fall back to UTC — UNVERIFIED mapping, send `Prefer: outlook.timezone="UTC"` where the API honours it.
    static func parseDTZ(_ dt: GMDateTimeTZ?) -> Date? {
        guard let dt, let raw = dt.dateTime else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(identifier: dt.timeZone ?? "UTC") ?? TimeZone(identifier: "UTC")
        return f.date(from: String(raw.prefix(19)))
    }
}

/// Per-mailbox request concurrency cap (Exchange allows 4 concurrent requests per mailbox).
actor MailboxLimiter {
    private let limit: Int
    private var inFlight: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    init(limit: Int) { self.limit = limit }
    func acquire(_ mb: String) async {
        if inFlight[mb, default: 0] < limit { inFlight[mb, default: 0] += 1; return }
        await withCheckedContinuation { waiters[mb, default: []].append($0) }
    }
    func release(_ mb: String) {
        if var w = waiters[mb], !w.isEmpty { let c = w.removeFirst(); waiters[mb] = w; c.resume() }
        else { inFlight[mb, default: 1] -= 1 }
    }
}

// MARK: - DTOs

struct GMEmpty: Decodable {}
struct GMMe: Decodable { var displayName: String?; var mail: String?; var userPrincipalName: String? }
struct GMPage<T: Decodable>: Decodable {
    var value: [T]; var nextLink: String?; var deltaLink: String?
    enum CodingKeys: String, CodingKey { case value, nextLink = "@odata.nextLink", deltaLink = "@odata.deltaLink" }
}
struct GMFolder: Decodable {
    var id: String; var displayName: String?; var parentFolderId: String?
    var unreadItemCount: Int?; var totalItemCount: Int?; var childFolderCount: Int?
}
struct GMBatch: Decodable {
    struct R: Decodable {
        struct B: Decodable { var id: String? }
        var id: String; var status: Int; var body: B?
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            id = try c.decode(String.self, forKey: .id); status = try c.decode(Int.self, forKey: .status)
            body = status == 200 ? try? c.decode(B.self, forKey: .body) : nil
        }
        enum K: String, CodingKey { case id, status, body }
    }
    var responses: [R]
}
struct GMAddr: Codable { struct E: Codable { var name: String?; var address: String? }; var emailAddress: E? }
struct GMDateTimeTZ: Codable { var dateTime: String?; var timeZone: String? }

struct GMMessage: Decodable {
    struct Flag: Decodable { var flagStatus: String?; var dueDateTime: GMDateTimeTZ? }
    struct Body: Decodable { var contentType: String?; var content: String? }
    struct Att: Decodable { var id: String; var name: String?; var contentType: String?; var size: Int?; var isInline: Bool? }
    struct Prop: Decodable { var id: String; var value: String? }
    struct Removed: Decodable { var reason: String? }
    var id: String
    var subject: String?
    var from: GMAddr?; var sender: GMAddr?
    var toRecipients: [GMAddr]?; var ccRecipients: [GMAddr]?
    var receivedDateTime: String?; var sentDateTime: String?
    var bodyPreview: String?; var body: Body?
    var isRead: Bool?; var isDraft: Bool?
    var importance: String?; var inferenceClassification: String?
    var flag: Flag?; var categories: [String]?
    var hasAttachments: Bool?; var attachments: [Att]?
    var conversationId: String?; var changeKey: String?; var webLink: String?; var parentFolderId: String?
    var singleValueExtendedProperties: [Prop]?
    var removed: Removed?
    enum CodingKeys: String, CodingKey {
        case id, subject, from, sender, toRecipients, ccRecipients, receivedDateTime, sentDateTime, bodyPreview, body, isRead,
             isDraft, importance, inferenceClassification, flag, categories, hasAttachments, attachments, conversationId,
             changeKey, webLink, parentFolderId, singleValueExtendedProperties, removed = "@removed"
    }

    static func addr(_ a: GMAddr?) -> EmailAddress? {
        guard let e = a?.emailAddress, let ad = e.address else { return nil }
        return EmailAddress(name: e.name ?? "", address: ad)
    }

    init(id: String, singleValueExtendedProperties: [Prop]) { self.id = id; self.singleValueExtendedProperties = singleValueExtendedProperties }

    var labelFromProps: String? { labelReading(tenant: MIPMetadata.homeTenantId).labelId }
    func labelReading(tenant: String?) -> LabelReading {
        MIPMetadata.read(singleValueExtendedProperties?.first(where: { $0.id.lowercased().contains("msip_labels") })?.value,
                         homeTenant: tenant)
    }
    /// Graph echoes the id normalised ("Integer 0x36"), so compare the parsed tag, not the string.
    var privateFromProps: Bool {
        singleValueExtendedProperties?.contains(where: { p in
            let parts = p.id.lowercased().split(separator: " ")
            return parts.count == 2 && parts[0] == "integer" && UInt32(parts[1].replacingOccurrences(of: "0x", with: ""), radix: 16) == 0x36
                && p.value?.trimmingCharacters(in: .whitespaces) == "2"
        }) ?? false
    }

    func toModel(defaultFolder: String, tenant: String? = MIPMetadata.homeTenantId) -> MailMessage? {
        let received = GraphMailService.parseISO(receivedDateTime) ?? GraphMailService.parseISO(sentDateTime) ?? Date(timeIntervalSince1970: 0)
        let reading = labelReading(tenant: tenant), isPrivate = privateFromProps
        var m = MailMessage(
            id: id, folderId: parentFolderId ?? defaultFolder, conversationId: conversationId ?? id, subject: subject ?? "",
            from: Self.addr(from), toRecipients: (toRecipients ?? []).compactMap(Self.addr),
            ccRecipients: (ccRecipients ?? []).compactMap(Self.addr), received: received,
            sent: GraphMailService.parseISO(sentDateTime), preview: bodyPreview, body: body?.content,
            bodyIsHTML: (body?.contentType ?? "html").lowercased() == "html", isRead: isRead ?? false, isDraft: isDraft ?? false,
            importance: Importance(rawValue: importance ?? "") ?? .normal,
            focus: inferenceClassification == "other" ? .other : .focused,
            flag: FollowUpFlag(status: FollowUpFlag.Status(rawValue: flag?.flagStatus ?? "") ?? .notFlagged,
                               due: GraphMailService.parseDTZ(flag?.dueDateTime)),
            categories: categories ?? [], hasAttachments: hasAttachments ?? false,
            attachments: (attachments ?? []).map { AttachmentInfo(id: $0.id, name: $0.name ?? "", contentType: $0.contentType ?? "",
                                                                   size: $0.size ?? 0, isInline: $0.isInline ?? false) },
            labelId: reading.labelId, isPrivate: isPrivate, changeKey: changeKey,
            webLink: webLink.flatMap(URL.init(string:)), sender: Self.addr(sender))
        m.labelOrigin = reading.origin
        return m
    }
}

struct GMMessageBatch: Decodable {
    struct R: Decodable { var id: String; var status: Int; var body: GMMessage? }
    var responses: [R]
}

struct GMPropBatch: Decodable {
    struct Body: Decodable { var id: String?; var singleValueExtendedProperties: [GMMessage.Prop]? }
    struct R: Decodable { var id: String; var status: Int; var body: Body? }
    var responses: [R]
}

struct GMRule: Decodable {
    struct Size: Decodable { var minimumSize: Int?; var maximumSize: Int? }
    struct Pred: Decodable {
        var fromAddresses: [GMAddr]?; var sentToAddresses: [GMAddr]?
        var subjectContains: [String]?; var bodyContains: [String]?; var senderContains: [String]?; var headerContains: [String]?
        var importance: String?; var hasAttachments: Bool?; var sentToMe: Bool?; var sentOnlyToMe: Bool?; var sentCcMe: Bool?
        var isMeetingRequest: Bool?; var withinSizeRange: Size?
        func toModel() -> RuleConditions {
            RuleConditions(fromAddresses: (fromAddresses ?? []).compactMap(GMMessage.addr),
                           sentToAddresses: (sentToAddresses ?? []).compactMap(GMMessage.addr),
                           subjectContains: subjectContains ?? [], bodyContains: bodyContains ?? [], senderContains: senderContains ?? [],
                           headerContains: headerContains ?? [], importance: importance.flatMap(Importance.init(rawValue:)),
                           hasAttachments: hasAttachments, sentToMe: sentToMe, sentOnlyToMe: sentOnlyToMe, sentCcMe: sentCcMe,
                           isMeetingRequest: isMeetingRequest,
                           withinSizeRange: withinSizeRange.map { SizeRange(minimumSize: $0.minimumSize ?? 0, maximumSize: $0.maximumSize ?? 0) })
        }
    }
    struct Act: Decodable {
        var moveToFolder: String?; var copyToFolder: String?; var delete: Bool?; var permanentDelete: Bool?; var markAsRead: Bool?
        var markImportance: String?; var assignCategories: [String]?; var forwardTo: [GMAddr]?; var forwardAsAttachmentTo: [GMAddr]?
        var redirectTo: [GMAddr]?; var stopProcessingRules: Bool?
    }
    var id: String; var displayName: String?; var sequence: Int?; var isEnabled: Bool?
    var conditions: Pred?; var actions: Act?; var exceptions: Pred?; var hasError: Bool?; var isReadOnly: Bool?
    func toModel() -> MailRule {
        let a = actions
        return MailRule(id: id, displayName: displayName ?? "", sequence: sequence ?? 0, isEnabled: isEnabled ?? true,
                        conditions: conditions?.toModel() ?? .init(),
                        actions: RuleActions(moveToFolder: a?.moveToFolder, copyToFolder: a?.copyToFolder, delete: a?.delete,
                                             permanentDelete: a?.permanentDelete, markAsRead: a?.markAsRead,
                                             markImportance: a?.markImportance.flatMap(Importance.init(rawValue:)),
                                             assignCategories: a?.assignCategories ?? [],
                                             forwardTo: (a?.forwardTo ?? []).compactMap(GMMessage.addr),
                                             forwardAsAttachmentTo: (a?.forwardAsAttachmentTo ?? []).compactMap(GMMessage.addr),
                                             redirectTo: (a?.redirectTo ?? []).compactMap(GMMessage.addr),
                                             stopProcessingRules: a?.stopProcessingRules),
                        exceptions: exceptions?.toModel(), hasError: hasError ?? false, isReadOnly: isReadOnly ?? false)
    }
}

struct GMMailboxSettings: Decodable {
    struct ARS: Decodable {
        var status: String?; var externalAudience: String?
        var scheduledStartDateTime: GMDateTimeTZ?; var scheduledEndDateTime: GMDateTimeTZ?
        var internalReplyMessage: String?; var externalReplyMessage: String?
        func toModel() -> AutomaticReplies {
            AutomaticReplies(status: AutomaticReplies.Status(rawValue: status ?? "") ?? .disabled,
                             start: GraphMailService.parseDTZ(scheduledStartDateTime), end: GraphMailService.parseDTZ(scheduledEndDateTime),
                             timeZone: scheduledStartDateTime?.timeZone ?? "UTC",
                             internalReplyHTML: internalReplyMessage ?? "", externalReplyHTML: externalReplyMessage ?? "",
                             externalAudience: AutomaticReplies.Audience(rawValue: externalAudience ?? "") ?? .none)
        }
    }
    struct WH: Decodable { struct TZ: Decodable { var name: String? }; var daysOfWeek: [String]?; var startTime: String?; var endTime: String?; var timeZone: TZ? }
    var automaticRepliesSetting: ARS?
    var timeZone: String?
    var workingHours: WH?
    // A11Y-HOOK: regional formats (Learn: mailboxSettings.dateFormat / timeFormat / language → localeInfo).
    struct Lang: Decodable { var locale: String? }
    var dateFormat: String?
    var timeFormat: String?
    var language: Lang?
}

extension URL {
    /// Query builder that percent-encodes values (spaces, quotes, `$`-params) the way Graph expects.
    func mailQuery(_ q: [String: String]) -> URL {
        guard !q.isEmpty else { return self }
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
}
extension GraphMailService: DraftHistoryProviding {}
