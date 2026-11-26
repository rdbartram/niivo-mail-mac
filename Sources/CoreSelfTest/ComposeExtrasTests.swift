import Foundation
import CalendarCore
import MailCore

/// COMPOSE2: send later (server-side + fallback + cancel), reply settings, signature "None", Save All names, meeting.
@MainActor
func runComposeExtrasTests() async {
    section("Compose 2: send later, reply settings, Save All, reply with meeting")
    let at = Date().addingTimeInterval(3600)
    let refuse = Once()
    MailStub.log = []
    MailStub.handler = { req, _ in
        let path = req.url!.path, m = req.httpMethod ?? "GET"
        switch (m, path) {
        case ("PATCH", "/v1.0/me/messages/d9"): return (200, [:], gmsg("d9", folder: "drafts"))
        case ("PATCH", "/v1.0/me/messages/d8"):
            _ = refuse.first("d8")
            return (400, [:], #"{"error":{"code":"ErrorInvalidProperty"}}"#)
        case ("POST", let p) where p.hasSuffix("/send"): return (202, [:], "")
        case ("POST", "/v1.0/me/messages/orig/createReply"):
            return (201, [:], #"{"id":"r5","body":{"contentType":"html","content":"<html><body><div id=\"divRplyFwdMsg\">From: X</div></body></html>"},"parentFolderId":"drafts"}"#)
        case ("PATCH", "/v1.0/me/messages/r5"): return (200, [:], gmsg("r5", folder: "drafts"))
        case ("PATCH", "/v1.0/me/messages/d7"): return (200, [:], gmsg("d7", folder: "drafts"))
        case ("POST", "/v1.0/me/messages/h1/move"): return (201, [:], gmsg("h1b", folder: "drafts-id"))
        default: return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let svc = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
    func json(_ d: Data?) -> [String: Any] { (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
    func settle(_ ok: @escaping () -> Bool) async { for _ in 0..<100 where !ok() { try? await Task.sleep(for: .milliseconds(20)) } }
    do {
        var s = MailSettings(); s.serverDeferredSend = true
        let changes = ChangeLog()
        let store = try mailStore()
        let sync = MailSync(service: svc, store: store, compliance: mailEngine(), settings: s, onChange: { changes.add($0) })
        _ = await sync.queueSend(draftId: "d9", mailbox: "me", sendAt: at, undoSeconds: 0)
        await settle { changes.all.contains { if case .sendScheduled("d9", _) = $0 { return true }; return false } }
        let log = MailStub.captured()
        let prop = (json(log.first { $0.method == "PATCH" }?.body)["singleValueExtendedProperties"] as? [[String: Any]])?.first
        check(log.map { "\($0.method) \($0.path)" } == ["PATCH /v1.0/me/messages/d9", "POST /v1.0/me/messages/d9/send"]
              && prop?["id"] as? String == "SystemTime 0x3FEF" && prop?["value"] as? String == ISO8601DateFormatter().string(from: at),
              "server send later: PidTagDeferredSendTime (SystemTime 0x3FEF) PATCHed, then /send")
        check(!changes.all.contains { if case .sent("d9") = $0 { return true }; return false },
              "server send later is reported as scheduled, not sent")

        // Refused property → nothing sent, client outbox instead.
        MailStub.log = []
        _ = await sync.queueSend(draftId: "d8", mailbox: "me", sendAt: at, undoSeconds: 0)
        await settle { changes.all.contains { if case .sendScheduled("d8", _) = $0 { return true }; return false } }
        let queued = ((try? store.outbox()) ?? []).filter { $0.messageId == "d8" }
        check(!MailStub.captured().contains { $0.path.hasSuffix("/send") } && queued.count == 1,
              "refused deferred-send PATCH: no /send (no double send risk), queued in the client outbox")
        let wasLocal = try await sync.cancelScheduledSend(id: "d8")
        check(wasLocal && ((try? store.outbox()) ?? []).filter { $0.messageId == "d8" }.isEmpty,
              "cancel a client-side scheduled send: the queued send is removed (the draft stays in Drafts)")

        // The scheduled row carries its time (the reader offers Cancel); server-held cancel = a real move request.
        try store.upsert(folder: MailFolder(id: "drafts-id", displayName: "Drafts", wellKnown: .drafts, mailbox: "me"))
        try store.upsert(folder: MailFolder(id: "outbox-id", displayName: "Outbox", wellKnown: .outbox, mailbox: "me"))
        try store.upsert(message: MailMessage(id: "d5", folderId: "drafts-id", conversationId: "c5", subject: "later", from: nil, received: Date(), isDraft: true))
        try store.upsert(message: MailMessage(id: "h1", folderId: "outbox-id", conversationId: "c6", subject: "held", from: nil, received: Date()))
        _ = await sync.queueSend(draftId: "d5", mailbox: "me", sendAt: at, undoSeconds: 0)   // PATCH refused (404) → client outbox
        await settle { ((try? store.message(id: "d5", includeBody: false)) ?? nil)?.scheduledSend != nil }
        check(((try? store.message(id: "d5", includeBody: false)) ?? nil)?.scheduledSend == at, "a client-side scheduled draft shows its send time")
        MailStub.log = []
        let heldLocal = try await sync.cancelScheduledSend(id: "h1")
        let moved = ((try? store.message(id: "h1b", includeBody: false)) ?? nil)
        check(!heldLocal && MailStub.captured().map { "\($0.method) \($0.path)" } == ["POST /v1.0/me/messages/h1/move"]
              && (json(MailStub.captured().first?.body)["destinationId"] as? String) == "drafts-id" && moved?.folderId == "drafts-id",
              "cancel a server-held send: moved back to Drafts by a direct request (a refusal reaches the user)")

        // Reopened draft: no request while loading, none for an unchanged save after load, one PATCH for an edit.
        MailStub.log = []
        let reopened = DraftSession(draftId: "d7", loading: true)
        let base = MailDraft(kind: .new, to: [EmailAddress(name: "B", address: "b@contoso.example")], subject: "r", bodyHTML: "<p>x</p>")
        let skipped = try await reopened.save(base, sync: sync)
        reopened.markLoaded(base)
        try await reopened.save(base, sync: sync)
        var edited = base; edited.subject = "r2"
        try await reopened.save(edited, sync: sync)
        check(!skipped && MailStub.captured().map { "\($0.method) \($0.path)" } == ["PATCH /v1.0/me/messages/d7"],
              "reopened draft: nothing while loading, nothing for open + close untouched, one PATCH after an edit")

        // A reopened draft in a shared mailbox is saved and sent there, whatever its kind.
        try store.upsert(folder: MailFolder(id: "sh-drafts", displayName: "Drafts", wellKnown: .drafts, mailbox: "shared@contoso.example"))
        try store.upsert(message: MailMessage(id: "d6", folderId: "sh-drafts", conversationId: "c7", subject: "s", from: nil, received: Date(), isDraft: true))
        var shared = MailDraft(kind: .new); shared.existingId = "d6"
        check(await sync.draftMailbox(for: shared) == "shared@contoso.example", "draftMailbox follows an existing draft's mailbox")

        // Reply without history: the createReply body is dropped, only our part goes out.
        MailStub.log = []
        var r = MailDraft(kind: .reply, replyTo: "orig", bodyHTML: RichHTML.html(RichDoc.plain("Short")))
        r.omitHistory = true
        _ = try await svc.saveDraft(r, mailbox: "me")
        let body = ((json(MailStub.captured().first { $0.method == "PATCH" }?.body)["body"] as? [String: Any])?["content"] as? String) ?? ""
        check(body.contains("Short") && !body.contains("divRplyFwdMsg") && body.hasSuffix("</body></html>"),
              "reply without history: only the user's part (document kept well-formed)")
    } catch { check(false, "compose extras stub threw \(error)") }
    MailStub.handler = nil

    // Preferences: default reply-all, history setting, explicit "None" signature per identity; old encodings decode.
    let sig = MailSignature(name: "Full", html: "<p>R.</p>")
    var prefs = ComposerPreferences(signatures: [sig], newMailDefaults: [ComposerPreferences.anyIdentity: sig.id])
    prefs.newMailDefaults["support@contoso.example"] = ComposerPreferences.noSignature
    prefs.defaultReplyAll = true; prefs.replyHistory = .omit
    check(prefs.defaultSignature(identity: "Support@contoso.example", reply: false) == nil
          && prefs.defaultSignature(identity: "you@contoso.example", reply: false)?.id == sig.id,
          "an identity can choose no signature over the any-identity default")
    let round = (try? JSONEncoder().encode(prefs)).flatMap { try? JSONDecoder().decode(ComposerPreferences.self, from: $0) }
    let old = try? JSONDecoder().decode(ComposerPreferences.self, from: Data(#"{"signatures":[],"liveMarkdown":true}"#.utf8))
    check(round == prefs && old?.defaultReplyAll == false && old?.replyHistory == .include,
          "reply settings round-trip; older preferences decode with Outlook's defaults (reply, include history)")

    // Save All names.
    check(AttachmentFiles.uniqueNames(["a.pdf", "A.pdf", "../x/a.pdf", "b"], existing: ["a.pdf"]) == ["a 2.pdf", "A 3.pdf", "a 4.pdf", "b"],
          "Save All: safe names, never overwriting (case-insensitive), order kept")

    // Reply with meeting.
    let m = MailMessage(id: "m1", folderId: "inbox", conversationId: "c", subject: "RE: Fw: Budget 2027",
                        from: EmailAddress(name: "Zoé", address: "zoe@contoso.example"),
                        toRecipients: [EmailAddress(name: "Me", address: "me@contoso.example"), EmailAddress(name: "Leo", address: "leo@contoso.example")],
                        ccRecipients: [EmailAddress(name: "Leo again", address: "LEO@contoso.example"), EmailAddress(name: "Sam", address: "sam@contoso.example")],
                        received: Date(), webLink: URL(string: "https://outlook.office.com/owa/?ItemID=x"))
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let ev = MeetingFromMail.draft(from: m, mine: ["ME@contoso.example"], calendarId: "cal", start: start, redact: false)
    check(ev.subject == "Budget 2027" && ev.isOnlineMeeting && ev.end == start.addingTimeInterval(1800)
          && ev.attendees.map { "\($0.address):\($0.type ?? "")" } == ["zoe@contoso.example:required", "leo@contoso.example:required", "sam@contoso.example:optional"]
          && ev.notes.contains("https://outlook.office.com/owa/?ItemID=x"),
          "reply with meeting: thread people (me out, de-duplicated, Cc optional), subject without prefixes, Teams on, link back")
    let priv = MeetingFromMail.draft(from: m, mine: [], calendarId: "cal", start: start, redact: true)
    check(priv.subject.isEmpty && priv.notes.isEmpty, "reply with meeting from a private message: no subject, no link")
}
