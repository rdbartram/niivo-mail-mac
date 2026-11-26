import Foundation
import CryptoKit
import CalendarCore
import MailCore

/// One wording for "hidden by policy" and "doesn't exist", so errors can't be used to probe for restricted ids.
let notAvailable = "That message isn't available to AI (it doesn't exist or the organisation's policy restricts it)."
let replyRefused = "That message isn't available to AI in full (it doesn't exist or the organisation's policy restricts it), so a reply or forward draft can't be created here. Reply in the niivo mail app instead."
let draftNote = "Draft only. Nothing was sent. A human must review and send it in the niivo mail app; this server cannot send mail."

extension MCPServer {

    // MARK: Helpers

    func restrictedNotice(_ n: Int) -> JSON {
        n == 0 ? .null : .string(n == 1 ? "1 restricted item not shown" : "\(n) restricted items not shown")
    }

    func decision(shown: Int, meta: Int, hidden: Int) -> String { "ok:full=\(shown - meta),meta=\(meta),hidden=\(hidden)" }

    func resolveMailbox(_ s: String?) async throws -> String {
        let all = await backend.mailboxes
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
              s.lowercased() != "me", s.lowercased() != backend.me.address.lowercased() else { return "me" }
        if let m = all.first(where: { $0.lowercased() == s.lowercased() }) { return m }
        throw ToolFailure("Unknown mailbox. Available: \(all.joined(separator: ", ")).", "error:unknown-mailbox")
    }

    func label(_ id: String?) -> JSON {
        guard let id = id?.lowercased(), !id.isEmpty,
              let l = backend.engine.availableLabels().first(where: { $0.id.lowercased() == id }) else { return .null }
        return ["id": .string(l.id), "name": .string(l.name), "priority": .int(l.priority), "protected": .bool(l.hasProtection)]
    }

    func address(_ a: EmailAddress?) -> JSON {
        guard let a else { return .null }
        return ["name": .string(Untrusted.line(a.name, max: 100)), "address": .string(Untrusted.line(a.address, max: 254))]
    }

    func isExternal(_ a: EmailAddress?) -> JSON {
        guard let addr = a?.address.lowercased(), let domain = addr.split(separator: "@").last,
              !backend.internalDomains.isEmpty else { return .null }
        return .bool(!backend.internalDomains.contains(String(domain)))
    }

    /// Render one gated message. `body` only for `.full`.
    func render(_ m: MailMessage, _ exposure: Exposure, mailbox: String, body: (text: String, truncated: Bool)? = nil) -> JSON {
        var o: [String: JSON] = [
            "id": .string(m.id), "conversation_id": .string(m.conversationId), "folder_id": .string(m.folderId),
            "mailbox": .string(mailbox), "received": .date(m.received),
            "from": address(m.from), "external_sender": isExternal(m.from),
            "subject": Untrusted.wrap(Untrusted.line(m.subject), note: Untrusted.emailNote),
            "is_read": .bool(m.isRead), "is_draft": .bool(m.isDraft), "importance": .string(m.importance.rawValue),
            "flag": ["status": .string(m.flag.status.rawValue), "due": .date(m.flag.due)],
            "has_attachments": .bool(m.hasAttachments), "label": label(m.labelId), "access": .string(exposure.rawValue),
        ]
        if let s = m.snoozedUntil { o["snoozed_until"] = .date(s) }
        if !m.categories.isEmpty { o["categories"] = .array(m.categories.map { .string(Untrusted.line($0, max: 60)) }) }
        if let sender = m.sender, sender.address.lowercased() != m.from?.address.lowercased() { o["sender"] = address(sender) }
        if exposure == .full {
            o["to"] = .array(m.toRecipients.map(address))
            o["cc"] = .array(m.ccRecipients.map(address))
            if body == nil, let p = m.preview, !p.isEmpty { o["preview"] = Untrusted.wrap(Untrusted.line(p, max: 300), note: Untrusted.emailNote) }
            let files = m.attachments.filter { !$0.isInline }
            if !files.isEmpty {
                o["attachments"] = .array(files.map {
                    ["name": .string(Untrusted.line($0.name, max: 120)), "content_type": .string(Untrusted.line($0.contentType, max: 80)),
                     "size": .int($0.size)]
                })
            }
            if let body {
                o["body"] = Untrusted.wrap(body.text, note: Untrusted.emailNote)
                o["body_truncated"] = .bool(body.truncated)
            }
        }
        return .object(o)
    }

    func gateList(_ rows: [MailMessage], mailbox: String) -> (items: [JSON], ids: [String], hidden: Int, meta: Int) {
        var items: [JSON] = [], ids: [String] = [], hidden = 0, meta = 0
        for m in rows {
            guard let (r, ex) = gate.mail(m, mailbox: mailbox) else { hidden += 1; continue }
            if ex == .metadata { meta += 1 }
            items.append(render(r, ex, mailbox: mailbox)); ids.append(m.id)
        }
        return (items, ids, hidden, meta)
    }

    // Sealed keyset cursor: neither the id nor the date of the last (possibly hidden) row leaks.
    func sealCursor(_ c: MailCursor, folder: String) -> String? {
        let j: JSON = ["f": .string(folder), "r": .double(c.received.timeIntervalSince1970), "i": .string(c.id)]
        guard let box = try? AES.GCM.seal(Data(j.encoded.utf8), using: cursorKey).combined else { return nil }
        return box.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    func openCursor(_ s: String, folder: String) throws -> MailCursor {
        let b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let d = Data(base64Encoded: b64), let box = try? AES.GCM.SealedBox(combined: d),
              let plain = try? AES.GCM.open(box, using: cursorKey), let j = JSON.parse(String(decoding: plain, as: UTF8.self)),
              j["f"]?.string == folder, let id = j["i"]?.string else {
            throw ToolFailure("Invalid or expired before_cursor (valid for this folder and server session only).", "error:invalid-cursor")
        }
        let r: Double
        switch j["r"] {
        case .double(let x): r = x
        case .int(let x): r = Double(x)
        default: throw ToolFailure("Invalid before_cursor.", "error:invalid-cursor")
        }
        return MailCursor(received: Date(timeIntervalSince1970: r), id: id)
    }

    func header(_ id: String) -> (MailMessage, String)? {
        guard let m = try? backend.store.message(id: id, includeBody: false) else { return nil }
        return (m, backend.store.mailbox(forFolder: m.folderId))
    }

    static func validAddress(_ s: String) -> Bool {
        s.count <= 254 && s.range(of: "^[^\\s@<>\"(),;:]+@[^\\s@<>\"(),;:]+\\.[^\\s@<>\"(),;:]+$", options: .regularExpression) != nil
    }

    // MARK: Read tools

    func mailListFolders(_ a: Args) async throws -> ToolOutput {
        let mb = try await resolveMailbox(a.string("mailbox", max: 254))
        let folders = (try? backend.store.folders(mailbox: mb)) ?? []
        let items: [JSON] = folders.map {
            ["id": .string($0.id), "name": .string(Untrusted.line($0.displayName, max: 120)),
             "well_known": .str($0.wellKnown?.rawValue), "unread": .int($0.unreadCount), "total": .int($0.totalCount),
             "parent_id": .str($0.parentId)]
        }
        return ToolOutput(payload: ["mailbox": .string(mb), "folders": .array(items)], ids: folders.map(\.id), shown: items.count)
    }

    func mailListMessages(_ a: Args) async throws -> ToolOutput {
        let folderArg = try a.required("folder", max: 512)
        let limit = try a.int("limit", default: 25, range: 1...50)
        let unreadOnly = try a.bool("unread_only") ?? false
        let mbArg = try a.string("mailbox", max: 254)
        var mb = try await resolveMailbox(mbArg)
        let folder: MailFolder
        if let w = WellKnownFolder(rawValue: folderArg.lowercased()) {
            guard let f = try? backend.store.folder(wellKnown: w, mailbox: mb) else {
                throw ToolFailure("No \(w.rawValue) folder in that mailbox (yet).", "error:unknown-folder")
            }
            folder = f
        } else {
            guard let f = try? backend.store.folder(id: folderArg) else { throw ToolFailure("Unknown folder id.", "error:unknown-folder") }
            if mbArg != nil, f.mailbox != mb { throw ToolFailure("That folder belongs to another mailbox.", "error:unknown-folder") }
            folder = f; mb = f.mailbox
        }
        if !openedFolders.contains(folder.id) {
            openedFolders.insert(folder.id)
            await backend.sync.openFolder(folder.id)
        }
        let before = try a.string("before_cursor", max: 2_000).map { try openCursor($0, folder: folder.id) }
        var rows = (try? backend.store.messages(folderId: folder.id, before: before, limit: limit)) ?? []
        if rows.count < limit {   // end of the local window → one server page of older headers
            _ = try? await backend.sync.loadOlder(folderId: folder.id, count: limit)
            rows = (try? backend.store.messages(folderId: folder.id, before: before, limit: limit)) ?? rows
        }
        let next = rows.count == limit
            ? rows.last.flatMap { sealCursor(MailCursor(received: $0.received, id: $0.id), folder: folder.id) } : nil
        let g = gateList(unreadOnly ? rows.filter { !$0.isRead } : rows, mailbox: mb)
        return ToolOutput(payload: [
            "mailbox": .string(mb), "folder_id": .string(folder.id), "messages": .array(g.items),
            "restricted_not_shown": .int(g.hidden), "notice": restrictedNotice(g.hidden), "next_cursor": .str(next),
        ], ids: g.ids, shown: g.items.count, restricted: g.hidden, decision: decision(shown: g.items.count, meta: g.meta, hidden: g.hidden))
    }

    func mailGetMessage(_ a: Args) async throws -> ToolOutput {
        let id = try a.required("id", max: 512)
        guard let (h, mb) = header(id), let ex = gate.mailExposure(h, mailbox: mb) else {
            throw ToolFailure(notAvailable, "refused:not-available")
        }
        var msg = h
        if ex == .full {
            // The body is fetched only when the header already allows it, then re-gated on the fetched copy.
            guard let full = try? await backend.sync.fetchBody(id: id) else {
                throw ToolFailure("The message body couldn't be loaded (offline?).", "error:fetch")
            }
            msg = full
        }
        guard let (r, ex2) = gate.mail(msg, mailbox: mb) else { throw ToolFailure(notAvailable, "refused:not-available") }
        let body = ex2 == .full ? r.body.map { Untrusted.body($0, isHTML: r.bodyIsHTML) } : nil
        return ToolOutput(payload: ["message": render(r, ex2, mailbox: mb, body: body)], ids: [id], shown: 1,
                          decision: "ok:\(ex2.rawValue)")
    }

    func mailGetThread(_ a: Args) async throws -> ToolOutput {
        let cid = try a.required("conversation_id", max: 512)
        let all = ((try? backend.store.conversation(id: cid, limit: 200)) ?? []).sorted { $0.received < $1.received }
        var items: [JSON] = [], ids: [String] = [], hidden = 0, meta = 0
        for h in all.suffix(25) {
            let mb = backend.store.mailbox(forFolder: h.folderId)
            guard let ex = gate.mailExposure(h, mailbox: mb) else { hidden += 1; continue }
            var msg = h
            if ex == .full, let full = try? await backend.sync.fetchBody(id: h.id) { msg = full }
            guard let (r, ex2) = gate.mail(msg, mailbox: mb) else { hidden += 1; continue }
            if ex2 == .metadata { meta += 1 }
            let body = ex2 == .full ? r.body.map { Untrusted.body($0, isHTML: r.bodyIsHTML) } : nil
            items.append(render(r, ex2, mailbox: mb, body: body)); ids.append(h.id)
        }
        return ToolOutput(payload: ["conversation_id": .string(cid), "messages": .array(items),
                                    "older_not_included": .int(max(0, all.count - 25)),
                                    "restricted_not_shown": .int(hidden), "notice": restrictedNotice(hidden)],
                          ids: ids, shown: items.count, restricted: hidden,
                          decision: decision(shown: items.count, meta: meta, hidden: hidden))
    }

    // MARK: Draft (never sends)

    func mailCreateDraft(_ a: Args) async throws -> ToolOutput {
        guard let kind = MailDraft.Kind(rawValue: try a.string("kind", max: 16) ?? "new") else {
            throw ToolFailure("'kind' must be new, reply, replyAll or forward.", "error:invalid-args")
        }
        let to = try a.strings("to", maxItems: 50) ?? []
        let cc = try a.strings("cc", maxItems: 50) ?? []
        guard (to + cc).allSatisfy(Self.validAddress) else { throw ToolFailure("Invalid email address in to/cc.", "error:invalid-args") }
        let subject = Untrusted.stripInvisible(try a.string("subject", max: 255) ?? "").replacingOccurrences(of: "\n", with: " ")
        let bodyText = Untrusted.stripInvisible(try a.string("body_text", max: 20_000) ?? "")
        let replyTo = try a.string("reply_to_id", max: 512)

        var auditIds: [String] = []
        if kind != .new {
            guard let rid = replyTo else { throw ToolFailure("'reply_to_id' is required for \(kind.rawValue).", "error:invalid-args") }
            // Refused unless the AI may see the original in full (hidden, metadata-only and unknown ids all fail).
            guard let (orig, mb) = header(rid), gate.mailExposure(orig, mailbox: mb) == .full else {
                throw ToolFailure(replyRefused, "refused:reply-to-restricted")
            }
            // Usage rights: REPLY / REPLYALL / FORWARD, same gate as the app.
            guard MailActionRights.allows(kind, policy: MailContentPolicy.policy(for: orig, mailbox: mb, engine: backend.engine)) else {
                throw ToolFailure("\(MailActionRights.deniedReason): a \(kind.rawValue) draft can't be created for that message.",
                                  "refused:label-rights")
            }
            auditIds.append(rid)
        }
        var from: SendIdentity?
        if let fid = try a.string("from_identity", max: 254) {
            guard let match = backend.identities.first(where: { $0.address.lowercased() == fid.lowercased() }) else {
                throw ToolFailure("Unknown from_identity. Configured: \(backend.identities.map(\.address).joined(separator: ", ")).", "error:unknown-identity")
            }
            from = match
        }
        let html = "<div>" + bodyText
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>") + "</div>"
        let draft = MailDraft(kind: kind, replyTo: replyTo,
                              to: to.map { EmailAddress(name: "", address: $0) }, cc: cc.map { EmailAddress(name: "", address: $0) },
                              subject: subject, bodyHTML: html, from: from)
        // MailSync.saveDraft applies MailSync.enforceLabelFloor (a reply/forward can't go below the original's
        // label) and only creates a draft. There is no send/queueSend call anywhere in this server.
        let floor = await backend.sync.enforceLabelFloor(draft)
        let saved: MailMessage
        do { saved = try await backend.sync.saveDraft(draft) }
        catch MailServiceError.sendAsDenied { throw ToolFailure("That identity isn't allowed to send as/on behalf here.", "error:send-as-denied") }
        catch { throw ToolFailure("The draft couldn't be created (offline, or the original isn't in that mailbox).", "error:draft-failed") }
        // Tag it so the reviewing human can tell it was AI-authored (best effort).
        try? await backend.sync.perform(.categorize(saved.categories + ["AI draft"]), on: saved.id)
        auditIds.insert(saved.id, at: 0)
        let mailbox = await backend.sync.draftMailbox(for: draft)
        return ToolOutput(payload: [
            "draft_id": .string(saved.id), "status": "draft", "is_draft": .bool(saved.isDraft), "kind": .string(kind.rawValue),
            "mailbox": .string(mailbox), "label": label(saved.labelId ?? floor.labelId), "category": "AI draft",
            "note": .string(draftNote),
        ], ids: auditIds, shown: 1, decision: "ok:draft-created")
    }

    // MARK: Triage (reversible; removed by --allow-triage=false / --read-only)

    func triageTarget(_ a: Args) throws -> String {
        let id = try a.required("id", max: 512)
        guard let (h, mb) = header(id), gate.mailExposure(h, mailbox: mb) != nil else {
            throw ToolFailure(notAvailable, "refused:not-available")
        }
        return id
    }

    func apply(_ action: MailAction, id: String, what: String) async throws -> ToolOutput {
        do { try await backend.sync.perform(action, on: id) }
        catch { throw ToolFailure("The change couldn't be applied (offline, or the message moved).", "error:triage-failed") }
        return ToolOutput(payload: ["id": .string(id), "applied": .string(what), "note": "Reversible; synced to Exchange."],
                          ids: [id], shown: 1, decision: "ok:\(what)")
    }

    func mailFlag(_ a: Args) async throws -> ToolOutput {
        let id = try triageTarget(a)
        guard let st = FollowUpFlag.Status(rawValue: try a.required("status", max: 16)) else {
            throw ToolFailure("'status' must be notFlagged, flagged or complete.", "error:invalid-args")
        }
        let due = try a.date("due", required: false)
        return try await apply(.flag(FollowUpFlag(status: st, due: st == .flagged ? due : nil)), id: id, what: "flag-\(st.rawValue)")
    }

    func mailMarkRead(_ a: Args) async throws -> ToolOutput {
        let id = try triageTarget(a)
        guard let read = try a.bool("read") else { throw ToolFailure("'read' is required.", "error:invalid-args") }
        return try await apply(.markRead(read), id: id, what: read ? "mark-read" : "mark-unread")
    }

    func mailSnooze(_ a: Args) async throws -> ToolOutput {
        let id = try triageTarget(a)
        guard let until = try a.date("until"), until > Date() else {
            throw ToolFailure("'until' must be in the future.", "error:invalid-args")
        }
        return try await apply(.snooze(until: until), id: id, what: "snooze")
    }
}
