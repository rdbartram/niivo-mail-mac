import Foundation
import CalendarCore
import MailCore

/// COMPOSE2: draft autosave = one server draft (exact request sequence), reply history carried byte-for-byte.
@MainActor
func runComposeDraftTests() async {
    section("Compose 2: autosave in place, quoted history, reopen")
    let history = #"<div id=\"divRplyFwdMsg\"><b>From:</b> Zoé<br>Sent: Monday</div><div>Original text &amp; more</div>"#
    let shell = "<html><head><meta charset=\\\"utf-8\\\"></head><body><br>\(history)</body></html>"
    MailStub.log = []
    MailStub.handler = { req, body in
        let path = req.url!.path, m = req.httpMethod ?? "GET"
        switch (m, path) {
        case ("POST", "/v1.0/me/messages"): return (201, [:], gmsg("d1", folder: "drafts"))
        case ("PATCH", "/v1.0/me/messages/d1"): return (200, [:], gmsg("d1", folder: "drafts"))
        case ("POST", "/v1.0/me/messages/d1/attachments"):
            let name = ((try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any])?["name"] as? String ?? "x"
            return (201, [:], #"{"id":"att-\#(name)","name":"\#(name)","contentType":"text/plain","size":1,"isInline":false}"#)
        case ("GET", "/v1.0/me/messages/d1/attachments"):
            return (200, [:], #"{"value":[{"id":"att-srv-e","name":"e.txt"},{"id":"att-a.txt","name":"a.txt"}]}"#)
        case ("DELETE", let p) where p.hasPrefix("/v1.0/me/messages/d1/attachments/"): return (204, [:], "")
        case ("POST", "/v1.0/me/messages/d1/send"): return (202, [:], "")
        case ("POST", "/v1.0/me/messages/orig/createReply"):
            return (201, [:], #"{"id":"r1","body":{"contentType":"html","content":"\#(shell)"},"parentFolderId":"drafts"}"#)
        case ("PATCH", "/v1.0/me/messages/r1"): return (200, [:], gmsg("r1", folder: "drafts"))
        case ("GET", "/v1.0/me/messages/r1"):
            // A fresh service (restart / other client) finds the history in the saved body.
            let saved = shell.replacingOccurrences(of: "<body>", with: #"<body><div id=\"niivo-compose\"><p>old</p></div>"#)
            return (200, [:], #"{"id":"r1","body":{"contentType":"html","content":"\#(saved)"}}"#)
        default: return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let svc = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
    func json(_ d: Data?) -> [String: Any] { (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
    func bodyOf(_ c: MailStub.Captured) -> String { ((json(c.body)["body"] as? [String: Any])?["content"] as? String) ?? "" }
    do {
        let store = try mailStore()
        let sync = MailSync(service: svc, store: store, compliance: mailEngine(), onChange: { _ in })
        let s = DraftSession()
        let e = OutgoingAttachment(name: "e.txt", contentType: "text/plain", data: Data("e".utf8))
        let a = OutgoingAttachment(name: "a.txt", contentType: "text/plain", data: Data("a".utf8))
        let b = OutgoingAttachment(name: "b.txt", contentType: "text/plain", data: Data("b".utf8))
        var d = MailDraft(kind: .new, to: [EmailAddress(name: "B", address: "b@contoso.example")], subject: "Plan",
                          bodyHTML: RichHTML.html(RichDoc.plain("one")))
        d.attachments = [e]
        try await s.save(d, sync: sync)                         // 1 create (e embedded)
        try await s.save(d, sync: sync)                         //   unchanged: nothing
        d.bodyHTML = RichHTML.html(RichDoc.plain("one two"))
        try await s.save(d, sync: sync)                         // 2 PATCH
        d.attachments = [e, a]
        try await s.save(d, sync: sync)                         // 3 PATCH + POST a
        d.attachments = [a, b]
        try await s.save(d, sync: sync)                         // 4 PATCH + GET list (e by name) + DELETE e + POST b
        d.attachments = [b]
        try await s.save(d, sync: sync)                         // 5 PATCH + DELETE a
        let (id, mb) = try await s.prepareSend(d, sync: sync)   //   unchanged: nothing
        _ = await sync.queueSend(draftId: id, mailbox: mb, undoSeconds: 0)
        await sync.waitForPendingSends()                        // 6 POST send
        // waitForPendingSends returns once the send has left the queue; the POST may still be in flight.
        for _ in 0..<100 where !MailStub.captured().contains(where: { $0.path.hasSuffix("/send") }) { try? await Task.sleep(for: .milliseconds(20)) }
        let log = MailStub.captured()
        let seq = log.map { "\($0.method) \($0.path.replacingOccurrences(of: "/v1.0/me/messages", with: ""))" }
        let expected = ["POST ", "PATCH /d1", "PATCH /d1", "POST /d1/attachments", "PATCH /d1", "GET /d1/attachments",
                        "DELETE /d1/attachments/att-srv-e", "POST /d1/attachments", "PATCH /d1", "DELETE /d1/attachments/att-a.txt",
                        "POST /d1/send"]
        check(seq == expected, "autosave ×6 + attachment add/remove + send: exact request sequence (\(seq))")
        check(s.draftId == "d1" && !log.contains { $0.method == "DELETE" && !$0.path.contains("/attachments/") }
              && log.filter { $0.method == "POST" && $0.path == "/v1.0/me/messages" }.count == 1,
              "one server draft id throughout; no draft deleted or re-created")
        check(log.first { $0.method == "GET" }?.query.removingPercentEncoding == "$select=id,name",
              "attachment lookup is a real $select query (not an encoded path)")
        check(json(log[1].body)["attachments"] == nil && log.filter { $0.path.hasSuffix("/attachments") && $0.method == "POST" }
              .map { json($0.body)["name"] as? String ?? "" } == ["a.txt", "b.txt"], "each attachment uploaded once, never re-uploaded by a later save")

        // Reply: one createReply, then PATCHes; history byte-identical, our region exactly once.
        MailStub.log = []
        let r = DraftSession()
        var rd = MailDraft(kind: .reply, replyTo: "orig", bodyHTML: RichHTML.html(RichDoc.plain("Thanks")))
        try await r.save(rd, sync: sync)
        rd.bodyHTML = RichHTML.html(RichDoc.plain("Thanks, Zoé"))
        try await r.save(rd, sync: sync)
        rd.bodyHTML = RichHTML.html(RichDoc.plain("Thanks, Zoé — see you"))
        try await r.save(rd, sync: sync)
        let rlog = MailStub.captured()
        let patches = rlog.filter { $0.method == "PATCH" }.map(bodyOf)
        let plainShell = shell.replacingOccurrences(of: "\\\"", with: "\"")
        let plainHistory = history.replacingOccurrences(of: "\\\"", with: "\"")
        check(rlog.filter { $0.path.hasSuffix("createReply") }.count == 1 && patches.count == 3 && r.draftId == "r1",
              "reply: one createReply, every later save PATCHes the same draft")
        check(patches.allSatisfy { p in
            p.components(separatedBy: "id=\"niivo-compose\"").count == 2
                && DraftCarry.split(p).map { $0.carry.historyDocument == plainShell } == true
        }, "reply: each PATCH has our region once and the createReply history byte-for-byte")
        check(patches.last.map { $0.hasSuffix(plainHistory + "</body></html>") && $0.contains("see you") } == true,
              "reply: history stays below the user's text")
        check(svc.draftHistory(id: "r1") == plainShell && sync.draftHistory?.draftHistory(id: "r1") == plainShell,
              "the service exposes the carried history for the collapsed view")

        // A fresh service doesn't know the history: it recovers it from the saved body (GET), no second createReply.
        MailStub.log = []
        let svc2 = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
        var again = rd; again.existingId = "r1"; again.bodyHTML = RichHTML.html(RichDoc.plain("resumed"))
        _ = try await svc2.saveDraft(again, mailbox: "me")
        let l2 = MailStub.captured()
        let p2 = l2.first { $0.method == "PATCH" }.map(bodyOf) ?? ""
        check(l2.map(\.method) == ["GET", "PATCH"] && !l2.contains { $0.path.hasSuffix("createReply") }
              && p2.contains("resumed") && !p2.contains("<p style=\"margin:0\">old</p>") && p2.hasSuffix(plainHistory + "</body></html>")
              && p2.components(separatedBy: "id=\"niivo-compose\"").count == 2,
              "unknown history: GET the draft, carry it verbatim, PATCH in place (\(l2.map { $0.method + " " + $0.path }))")
    } catch { check(false, "compose draft stub threw \(error)") }
    MailStub.handler = nil

    // Splitting a saved body: our marker, or Outlook's reply header when the marker is gone.
    let marked = #"<html><body><div id="niivo-compose"><p>Hi</p></div><hr><div id="divRplyFwdMsg">From: X</div><p>old</p></body></html>"#
    let m1 = DraftCarry.split(marked)
    check(m1?.editable == "<p>Hi</p>" && m1?.carry.suffix == #"<hr><div id="divRplyFwdMsg">From: X</div><p>old</p></body></html>"#,
          "split: our region is editable, everything else carried")
    let bare = #"<html><body><p>Hi</p><div style="x"><hr style="y"></div><div id="x_divRplyFwdMsg">From: X</div><p>old</p></body></html>"#
    let m2 = DraftCarry.split(bare)
    check(m2?.editable == "<p>Hi</p>" && m2?.carry.suffix.hasPrefix(#"<div style="x"><hr"#) == true
          && m2.map { $0.carry.wrap($0.editable) } == bare, "split without our marker: Outlook's reply header (+ its <hr>) starts the history")
    check(DraftCarry.split("<html><body><p>just text</p></body></html>") == nil, "no history recognised → nothing carried")
    check(DraftCarry.shell("<html><body></body></html>").hasHistory == false && DraftCarry.shell(marked).hasHistory,
          "empty shell has no history")

    // Fixture service honours existingId (no duplicate drafts in demo mode).
    do {
        let fx = FixtureMailService()
        let first = try await fx.saveDraft(MailDraft(kind: .new, subject: "fx1", bodyHTML: "<p>a</p>"), mailbox: "me")
        var upd = MailDraft(kind: .new, subject: "fx2", bodyHTML: "<p>b</p>"); upd.existingId = first.id
        let second = try await fx.saveDraft(upd, mailbox: "me")
        let reread = try await fx.message(id: first.id, mailbox: "me")
        check(second.id == first.id && reread.subject == "fx2", "fixtures: a save with existingId updates the same draft")
        // Reopened reply (kind .new, the editor carries the history): the history is not added a second time.
        let rep = try await fx.saveDraft(MailDraft(kind: .reply, replyTo: FX.Special.general, bodyHTML: RichHTML.html(RichDoc.plain("r"))), mailbox: "me")
        let split = DraftCarry.split(rep.body ?? "")
        var reopen = MailDraft(kind: .new, bodyHTML: split.map { $0.carry.wrap(RichHTML.html(RichDoc.plain("r2"))) } ?? ""); reopen.existingId = rep.id
        let again = try await fx.saveDraft(reopen, mailbox: "me")
        check(split != nil && (again.body ?? "").components(separatedBy: "divRplyFwdMsg").count == 2 && again.body?.contains("r2") == true,
              "fixtures: a reopened reply keeps exactly one copy of its history")
    } catch { check(false, "fixture existingId threw \(error)") }
}
