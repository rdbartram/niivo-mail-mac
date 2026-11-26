import Foundation
import CalendarCore
import MailCore

/// Reader extras against the Graph stub: invite read + response shapes, junk report, headers / MIME, print and source
/// gates, unsubscribe parsing (no automatic egress), block-sender rule shape. All fixtures synthetic.
@MainActor
func runReaderGraphTests() async {
    section("Reader: meeting invites, junk, source, print gates, unsubscribe (Graph stub)")
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let session = URLSession(configuration: cfg)
    let svc = GraphMailService(token: { "t" }, session: session)
    func json(_ d: Data?) -> [String: Any] { (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }

    let invite = #"""
    {"@odata.type":"#microsoft.graph.eventMessageRequest","id":"inv1","subject":"Planning",
     "meetingMessageType":"meetingRequest","isOutOfDate":false,
     "startDateTime":{"dateTime":"2026-12-01T09:00:00.0000000","timeZone":"UTC"},
     "endDateTime":{"dateTime":"2026-12-01T10:00:00.0000000","timeZone":"UTC"},
     "internetMessageHeaders":[{"name":"List-Unsubscribe","value":"<https://lists.contoso.example/u/1>"}],
     "event":{"id":"ev1","subject":"Planning","isAllDay":false,"isCancelled":false,"isOrganizer":false,
       "allowNewTimeProposals":false,"responseRequested":true,
       "start":{"dateTime":"2026-12-01T09:00:00.0000000","timeZone":"UTC"},
       "end":{"dateTime":"2026-12-01T10:00:00.0000000","timeZone":"UTC"},
       "location":{"displayName":"Room 4"},"organizer":{"emailAddress":{"name":"Org","address":"org@contoso.example"}},
       "responseStatus":{"response":"notResponded"}}}
    """#
    let cancelled = ##"{"@odata.type":"#microsoft.graph.eventMessage","id":"c1","meetingMessageType":"meetingCancelled","event":{"id":"ev2","isCancelled":true}}"##
    let plain = #"{"id":"p1","subject":"Hello","internetMessageHeaders":[]}"#
    let leanFails = Once()

    MailStub.handler = { req, body in
        let path = req.url!.path, q = req.url!.query ?? "", m = req.httpMethod ?? "GET"
        switch (m, path) {
        case ("GET", "/v1.0/me/messages/inv1"): return (200, [:], invite)
        case ("GET", "/v1.0/me/messages/c1"): return (200, [:], cancelled)
        case ("GET", "/v1.0/me/messages/p1"): return (200, [:], plain)
        case ("GET", "/v1.0/me/messages/lean400"):
            if q.contains("select") && leanFails.first("x") { return (400, [:], #"{"error":{"code":"BadRequest"}}"#) }
            if q.contains("internetMessageHeaders") { return (200, [:], #"{"internetMessageHeaders":[{"name":"X-A","value":"1"}]}"#) }
            return (200, [:], invite.replacingOccurrences(of: "\"inv1\"", with: "\"lean400\""))
        case ("GET", "/v1.0/me/messages/h1"): return (200, [:], #"{"internetMessageHeaders":[{"name":"Received","value":"x"}]}"#)
        case ("GET", "/v1.0/me/messages/h1/$value"): return (200, [:], "MIME-Version: 1.0\r\nSubject: synthetic\r\n\r\nbody")
        case ("POST", "/v1.0/me/messages/j1/reportMessage"): return (200, [:], gmsg("j1", folder: "junk-id"))
        case ("POST", "/v1.0/me/messages/j2/reportMessage"): return (404, [:], #"{"error":{"code":"ResourceNotFound"}}"#)
        case ("POST", "/v1.0/me/messages/j2/move"): return (201, [:], gmsg("j2b", folder: "junk-id"))
        case ("POST", let p) where p.hasSuffix("/accept") || p.hasSuffix("/tentativelyAccept") || p.hasSuffix("/decline"):
            return (202, [:], "")
        case ("DELETE", "/v1.0/me/events/gone"): return (404, [:], #"{"error":{"code":"ErrorItemNotFound"}}"#)
        case ("DELETE", _): return (204, [:], "")
        case ("POST", "/u/1"):
            return (String(data: body ?? Data(), encoding: .utf8) == "List-Unsubscribe=One-Click" ? 200 : 400, [:], "")
        default: return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }

    // Invites
    MailStub.log = []
    do {
        let info = try await svc.readerInfo(messageId: "inv1", mailbox: "me")
        let inv = info.invite
        check(inv?.kind == .request && inv?.eventId == "ev1" && inv?.location == "Room 4" && inv?.organizer?.address == "org@contoso.example",
              "eventMessageRequest → invite card model (kind, event id, location, organiser)")
        check(inv?.start == ISO8601DateFormatter().date(from: "2026-12-01T09:00:00Z") && inv?.canRespond == true && inv?.allowNewTimeProposals == false,
              "event times parsed as UTC; respondable; allowNewTimeProposals read")
        check(info.headers.first?.name == "List-Unsubscribe", "headers ride in the same request")
        let q = MailStub.captured().first?.query.removingPercentEncoding ?? ""
        check(q.contains("$expand=microsoft.graph.eventMessage/event") && q.contains("microsoft.graph.eventMessage/meetingMessageType"),
              "invite read uses the type-cast $expand (Learn eventmessage-get example 2)")
        let c = try await svc.readerInfo(messageId: "c1", mailbox: "me").invite
        check(c?.kind == .cancelled && c?.canRemoveFromCalendar == true && c?.canRespond == false, "cancellation → Remove from calendar only")
        let p = try await svc.readerInfo(messageId: "p1", mailbox: "me").invite
        check(p == nil, "plain message → no invite card")
        check(MeetingMessageKind.from(graph: "meetingTenativelyAccepted") == .tentativelyAccepted
              && MeetingMessageKind.from(graph: "meetingTentativelyAccepted") == .tentativelyAccepted, "both documented spellings of tentative")
    } catch { check(false, "invite read threw \(error)") }

    // Responses (calendar side)
    MailStub.log = []
    let responder = GraphInviteResponder(token: { "t" }, session: session)
    do {
        try await responder.respond(mailboxPath: "me", calendarId: nil, eventId: "ev1", reply: InviteReply(.accept, comment: " See you "))
        var cap = MailStub.captured().last
        let a = json(cap?.body)
        check(cap?.method == "POST" && cap?.path == "/v1.0/me/events/ev1/accept" && a["sendResponse"] as? Bool == true
              && a["comment"] as? String == "See you" && a["proposedNewTime"] == nil, "accept: POST /events/{id}/accept {comment, sendResponse}")
        try await responder.respond(mailboxPath: "/users/boss@contoso.example", calendarId: "cal1", eventId: "ev9",
                                    reply: InviteReply(.decline, sendResponse: false))
        cap = MailStub.captured().last
        let d = json(cap?.body)
        check(cap?.path == "/v1.0/users/boss@contoso.example/calendars/cal1/events/ev9/decline" && d["sendResponse"] as? Bool == false
              && d["comment"] == nil, "silent decline on a delegated calendar: calendar-scoped path, empty comment omitted")
        let s = ISO8601DateFormatter().date(from: "2026-12-02T13:00:00Z")!
        let prop = InviteReply(.tentativelyAccept, proposedStart: s, proposedEnd: s.addingTimeInterval(1800))
        try prop.validate(allowNewTimeProposals: true)
        try await responder.respond(mailboxPath: "me", calendarId: nil, eventId: "ev1", reply: prop)
        cap = MailStub.captured().last
        let t = json(cap?.body)
        let pnt = t["proposedNewTime"] as? [String: Any]
        let st = pnt?["start"] as? [String: String], en = pnt?["end"] as? [String: String]
        check(cap?.path == "/v1.0/me/events/ev1/tentativelyAccept" && st?["dateTime"] == "2026-12-02T13:00:00" && st?["timeZone"] == "UTC"
              && en?["dateTime"] == "2026-12-02T13:30:00" && t["sendResponse"] as? Bool == true,
              "propose: tentativelyAccept with proposedNewTime {start,end} in UTC")
    } catch { check(false, "respond threw \(error)") }
    let before = MailStub.captured().count
    let s0 = Date(), e0 = Date().addingTimeInterval(600)
    func invalid(_ r: InviteReply, allow: Bool) -> InviteReply.Invalid? {
        do { try r.validate(allowNewTimeProposals: allow); return nil } catch { return error as? InviteReply.Invalid }
    }
    check(invalid(InviteReply(.accept, proposedStart: s0, proposedEnd: e0), allow: true) == .proposalNotWithAccept, "no proposal with accept")
    check(invalid(InviteReply(.decline, sendResponse: false, proposedStart: s0, proposedEnd: e0), allow: true) == .proposalNeedsResponse,
          "proposal requires sendResponse (documented 400)")
    check(invalid(InviteReply(.tentativelyAccept, proposedStart: s0, proposedEnd: e0), allow: false) == .proposalsNotAllowed,
          "proposal refused when allowNewTimeProposals is false (documented 400)")
    check(invalid(InviteReply(.decline, proposedStart: e0, proposedEnd: s0), allow: true) == .proposalEndNotAfterStart, "end after start")
    check(MailStub.captured().count == before, "validation sends nothing")
    do {
        try await responder.removeEvent(mailboxPath: "me", calendarId: nil, eventId: "ev2")
        check(MailStub.captured().last?.method == "DELETE" && MailStub.captured().last?.path == "/v1.0/me/events/ev2", "Remove from calendar: DELETE /events/{id}")
        try await responder.removeEvent(mailboxPath: "me", calendarId: nil, eventId: "gone")
        check(true, "remove of an already-deleted event is satisfied (404 swallowed)")
    } catch { check(false, "remove threw \(error)") }

    // Conflicts
    let base = ISO8601DateFormatter().date(from: "2026-12-01T09:00:00Z")!
    let evs = [CalendarEvent(id: "self", calendarId: "c", subject: "Planning", start: base, end: base.addingTimeInterval(3600), showAs: .tentative),
               CalendarEvent(id: "a", calendarId: "c", subject: "Overlap", start: base.addingTimeInterval(1800), end: base.addingTimeInterval(5400)),
               CalendarEvent(id: "b", calendarId: "c", subject: "Free", start: base, end: base.addingTimeInterval(3600), showAs: .free),
               CalendarEvent(id: "x", calendarId: "c", subject: "Cancelled", start: base, end: base.addingTimeInterval(3600), isCancelled: true),
               CalendarEvent(id: "z", calendarId: "c", subject: "After", start: base.addingTimeInterval(3600), end: base.addingTimeInterval(7200))]
    check(InviteConflicts.conflicts(start: base, end: base.addingTimeInterval(3600), in: evs, excludingEventId: "self").map(\.id) == ["a"],
          "conflicts: overlapping busy only (own copy, free, cancelled, back-to-back excluded)")

    // Junk
    MailStub.log = []
    do {
        let moved = try await svc.report(.junk, messageId: "j1", mailbox: "me", move: true)
        let b = json(MailStub.captured().last?.body)
        check(MailStub.captured().last?.path == "/v1.0/me/messages/j1/reportMessage" && b["ReportAction"] as? String == "junk"
              && b["IsMessageMoveRequested"] as? Bool == true && moved?.folderId == "junk-id",
              "report junk: POST reportMessage {IsMessageMoveRequested, ReportAction}")
        check(GraphMailService.reportJSON(.notJunk, move: false)["ReportAction"] as? String == "notJunk"
              && GraphMailService.reportJSON(.phish, move: true)["ReportAction"] as? String == "phish", "notJunk / phish action values")
        let fb = try await svc.report(.junk, messageId: "j2", mailbox: "me", move: true)
        let mv = MailStub.captured().last
        check(mv?.path == "/v1.0/me/messages/j2/move" && json(mv?.body)["destinationId"] as? String == "junkemail" && fb?.id == "j2b",
              "reportMessage unavailable → plain move to Junk")
    } catch { check(false, "report threw \(error)") }
    if let r = BlockSender.rule(for: " Spam@Bulk.example ", junkFolderId: "junk-id") {
        let j = GraphMailService.ruleJSON(r)
        let cond = j["conditions"] as? [String: Any], act = j["actions"] as? [String: Any]
        let from = (cond?["fromAddresses"] as? [[String: Any]])?.first?["emailAddress"] as? [String: Any]
        check(from?["address"] as? String == "spam@bulk.example" && act?["moveToFolder"] as? String == "junk-id"
              && act?["stopProcessingRules"] as? Bool == true, "block sender = inbox rule: from → move to Junk, stop processing")
    } else { check(false, "block rule built") }
    check(BlockSender.rule(for: "not an address", junkFolderId: "j") == nil, "block refuses a non-address")

    // Headers + MIME
    do {
        let h = try await svc.internetHeaders(messageId: "h1", mailbox: "me")
        check(h == [MessageHeader(name: "Received", value: "x")] && MailStub.captured().last?.query.contains("internetMessageHeaders") == true,
              "headers via $select=internetMessageHeaders")
        let mime = try await svc.mimeSource(messageId: "h1", mailbox: "me")
        check(String(decoding: mime, as: UTF8.self).hasPrefix("MIME-Version") && MailStub.captured().last?.path == "/v1.0/me/messages/h1/$value",
              "MIME via GET /messages/{id}/$value")
    } catch { check(false, "source threw \(error)") }

    // Gates
    let open = ContentPolicy.open
    var noPrint = open; noPrint.rights = [.view, .extract, .export]
    var noExport = open; noExport.labelState = .labeled(FixtureCalendarService.labels[3]); noExport.rights = [.view, .extract, .print]
    var prot = open; prot.bodyIsProtected = true
    var unknown = open; unknown.labelState = .unknown(id: "nope")
    var priv = open; priv.redactDetails = true
    check(ReaderGates.print(open, devicePrint: true) == nil, "print allowed: unlabelled + device allows")
    check(ReaderGates.print(open, devicePrint: false) != nil, "print blocked by device trust policy")
    check(ReaderGates.print(noPrint, devicePrint: true) != nil, "print blocked without the PRINT right")
    check(ReaderGates.print(prot, devicePrint: true) != nil && ReaderGates.print(unknown, devicePrint: true) != nil
          && ReaderGates.print(priv, devicePrint: true) != nil, "print refused for encrypted / unknown label / private")
    check(ReaderGates.print(noExport, devicePrint: true) == nil, "labelled with PRINT may print")
    check(ReaderGates.source(open) == nil && ReaderGates.source(noExport) != nil && ReaderGates.source(prot) != nil
          && ReaderGates.source(unknown) != nil && ReaderGates.source(priv) != nil, "source: never for protected / unknown / private / no EXPORT")
    var noCopy = open; noCopy.rights = [.view, .export, .print]
    check(ReaderGates.source(noCopy) != nil, "source needs EXTRACT too")
    check(ReaderGates.saveEML(open, deviceCopyOut: true) == nil && ReaderGates.saveEML(open, deviceCopyOut: false) != nil,
          ".eml: source gate + device copy-out")
    let doc = PrintDocument.html(bodyHTML: "<p>body</p>", subject: "<Q3>", from: "A", to: "B", date: "D",
                                 headerMarking: "CONFIDENTIAL", footerMarking: "Internal only", watermark: "ryan@contoso.example")
    check(doc.contains("mk-h\">CONFIDENTIAL") && doc.contains("mk-f\">Internal only") && doc.contains("ryan@contoso.example")
          && doc.contains("&lt;Q3&gt;") && doc.contains("script-src 'none'") && !doc.contains("img-src *"),
          "print document carries header/footer markings + watermark, escapes text, no remote images")
    let bare = PrintDocument.html(bodyHTML: "x", subject: "s", from: "", to: "", date: "", headerMarking: nil, footerMarking: nil, watermark: nil)
    check(!bare.contains("class=\"mk") && !bare.contains("class=\"wm\""), "no markings when the label has none")

    // Unsubscribe: parsing is pure; the POST needs the confirmed host
    let n0 = MailStub.captured().count
    let u = ListUnsubscribe.parse([MessageHeader(name: "list-unsubscribe",
                                                 value: "<mailto:leave@lists.contoso.example?subject=bye>,\r\n <http://insecure.example/u>, <https://user:pw@evil.example/u>, <https://lists.contoso.example/u/1>"),
                                   MessageHeader(name: "List-Unsubscribe-Post", value: "List-Unsubscribe=One-Click")])
    check(u?.mailto.count == 1 && u?.https.map(\.host) == ["lists.contoso.example"] && u?.oneClick == true,
          "List-Unsubscribe parsed: mailto + https; http and credentialled URLs dropped; one-click detected")
    check(ListUnsubscribe.parse([MessageHeader(name: "List-Unsubscribe", value: "<https://a.example/u>")])?.oneClickURL == nil,
          "no List-Unsubscribe-Post → no one-click")
    check(ListUnsubscribe.parse([MessageHeader(name: "Subject", value: "x")]) == nil, "no header → no Unsubscribe button")
    let d = u?.mailto.first.flatMap(ListUnsubscribe.draft(from:))
    check(d?.to == "leave@lists.contoso.example" && d?.subject == "bye", "mailto → draft fields (user sends it)")
    check(MailStub.captured().count == n0, "parsing and drafting make no request (no automatic egress)")
    let target = URL(string: "https://lists.contoso.example/u/1")!
    do { try await Unsubscriber.oneClick(target, confirmedHost: "other.example", session: session); check(false, "unconfirmed host refused") }
    catch { check(error as? Unsubscriber.Refused == .hostNotConfirmed, "one-click refused unless the user confirmed that host") }
    do { try await Unsubscriber.oneClick(URL(string: "http://lists.contoso.example/u/1")!, confirmedHost: "lists.contoso.example", session: session); check(false, "http refused") }
    catch { check(error as? Unsubscriber.Refused == .notHTTPS, "one-click is https only") }
    check(MailStub.captured().count == n0, "refused one-clicks send nothing")
    do {
        try await Unsubscriber.oneClick(target, confirmedHost: "Lists.Contoso.Example", session: session)
        let c = MailStub.captured().last
        check(c?.method == "POST" && c?.path == "/u/1" && String(data: c?.body ?? Data(), encoding: .utf8) == "List-Unsubscribe=One-Click",
              "confirmed one-click: RFC 8058 POST body")
    } catch { check(false, "one-click threw \(error)") }

    // Last: a 400 on the lean form switches to the documented form (process-wide).
    MailStub.log = []
    do {
        let info = try await svc.readerInfo(messageId: "lean400", mailbox: "me")
        let qs = MailStub.captured().map { $0.query.removingPercentEncoding ?? "" }
        check(info.invite?.eventId == "ev1" && qs.count == 3 && qs[1] == "$expand=microsoft.graph.eventMessage/event"
              && info.headers.first?.name == "X-A", "lean $select refused → documented $expand + separate headers GET")
    } catch { check(false, "lean fallback threw \(error)") }
}
