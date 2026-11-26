import Foundation
import CalendarCore

// Reader extras (meeting invites, headers / source, junk reporting, unsubscribe, print + source gates).
// Separate from `MailService` (like `MailAttachmentFetching`) so other services and stubs don't change.
//
// Verified on Microsoft Learn (2026-11-20):
//  * eventMessage: `meetingMessageType` = none | meetingRequest | meetingCancelled | meetingAccepted |
//    meetingTenativelyAccepted (sic; eventMessageRequest's page spells it meetingTentativelyAccepted — both accepted) |
//    meetingDeclined; `startDateTime`/`endDateTime` (dateTimeTimeZone), `location`, `isAllDay`, `isOutOfDate`.
//    The calendar event comes from the `event` navigation property with a type cast:
//    GET /me/messages/{id}?$expand=microsoft.graph.eventMessage/event
//    https://learn.microsoft.com/graph/api/eventmessage-get?view=graph-rest-1.0#example-2
//  * internetMessageHeaders (name/value) on message; MIME via GET /messages/{id}/$value.
//    https://learn.microsoft.com/graph/outlook-get-mime-message
//  * POST /me/messages/{id}/reportMessage { "IsMessageMoveRequested": Bool, "ReportAction": junk|notJunk|phish }
//    → 200 + message. Promoted to v1.0 in November 2026 (markAsJunk/markAsNotJunk beta are deprecated).
//    https://learn.microsoft.com/graph/api/message-reportmessage?view=graph-rest-1.0
//  * Graph has no blocked-senders list (mailboxSettings has none; only the deprecated beta markAsJunk added to it).
//    "Block sender" is therefore an inbox rule moving that sender to Junk (`BlockSender.rule`), and the UI says so.
// UNVERIFIED:
//  * `$select` with type-cast derived properties (`microsoft.graph.eventMessage/meetingMessageType`) and a nested
//    `$select` inside the cast `$expand`. On a 400 the documented form (cast `$expand` only, no `$select`) is used.
//  * That the cast `$expand` is ignored (not a 400) on a plain message — a 400 there also falls back, and a plain
//    message in the fallback is recognised by the missing `@odata.type` / `meetingMessageType`.
//  * Whether reportMessage also adds the sender to the blocked list (the page doesn't say). Fallback when the action
//    isn't there (404/400/405/501): a plain move to Junk / Inbox.

// MARK: - Models

public enum MeetingMessageKind: String, Sendable, Hashable {
    case request, cancelled, accepted, tentativelyAccepted, declined, other

    public static func from(graph s: String?) -> MeetingMessageKind? {
        switch s {
        case "meetingRequest": .request
        case "meetingCancelled": .cancelled
        case "meetingAccepted": .accepted
        case "meetingTenativelyAccepted", "meetingTentativelyAccepted": .tentativelyAccepted
        case "meetingDeclined": .declined
        case "none": .other
        default: nil
        }
    }
}

/// What the invite card shows. Times are absolute instants (UTC parsed).
public struct MeetingInvite: Sendable, Hashable {
    public var kind: MeetingMessageKind
    /// The event in the user's calendar (nil when Exchange hasn't created one, or it was already removed).
    public var eventId: String?
    public var subject: String
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool
    public var location: String?
    public var organizer: EmailAddress?
    /// Graph `responseStatus.response` on the event: none | organizer | tentativelyAccepted | accepted | declined | notResponded.
    public var myResponse: String?
    public var allowNewTimeProposals: Bool
    public var responseRequested: Bool
    public var isOutOfDate: Bool
    public var eventCancelled: Bool
    public var isOrganizer: Bool

    public init(kind: MeetingMessageKind, eventId: String? = nil, subject: String = "", start: Date? = nil, end: Date? = nil,
                isAllDay: Bool = false, location: String? = nil, organizer: EmailAddress? = nil, myResponse: String? = nil,
                allowNewTimeProposals: Bool = true, responseRequested: Bool = true, isOutOfDate: Bool = false,
                eventCancelled: Bool = false, isOrganizer: Bool = false) {
        self.kind = kind; self.eventId = eventId; self.subject = subject; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.location = location; self.organizer = organizer; self.myResponse = myResponse
        self.allowNewTimeProposals = allowNewTimeProposals; self.responseRequested = responseRequested
        self.isOutOfDate = isOutOfDate; self.eventCancelled = eventCancelled; self.isOrganizer = isOrganizer
    }

    /// Accept / Tentative / Decline make sense: a live request in an invitee's mailbox with an event behind it.
    public var canRespond: Bool { kind == .request && eventId != nil && !isOutOfDate && !eventCancelled && !isOrganizer }
    /// "Remove from calendar": a cancellation whose event is still in the calendar.
    public var canRemoveFromCalendar: Bool { kind == .cancelled && eventId != nil }
}

public struct MessageHeader: Sendable, Hashable, Codable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public enum JunkReport: String, Sendable, Hashable {
    case junk, notJunk, phish
}

/// One reader round trip: the invite (nil = not a meeting message) and the internet headers (for List-Unsubscribe).
public struct ReaderInfo: Sendable, Hashable {
    public var invite: MeetingInvite?
    public var headers: [MessageHeader]
    public init(invite: MeetingInvite?, headers: [MessageHeader]) { self.invite = invite; self.headers = headers }
}

public protocol MailReaderServicing: Sendable {
    /// Invite + headers, in one request where Graph allows it.
    func readerInfo(messageId: String, mailbox: String) async throws -> ReaderInfo
    /// nil = not a meeting message.
    func meetingInvite(messageId: String, mailbox: String) async throws -> MeetingInvite?
    func internetHeaders(messageId: String, mailbox: String) async throws -> [MessageHeader]
    /// Raw MIME (`$value`). Memory only; callers gate it with `ReaderGates.source` first.
    func mimeSource(messageId: String, mailbox: String) async throws -> Data
    /// Report junk / not junk / phishing; `move` = take it out of the current folder. Returns the moved message.
    func report(_ action: JunkReport, messageId: String, mailbox: String, move: Bool) async throws -> MailMessage?
}

public extension MailSync {
    /// The service's reader endpoint, if it has one (Graph, fixtures).
    nonisolated var readerService: MailReaderServicing? { service as? MailReaderServicing }
}

// MARK: - Graph

final class InviteProbeMode: @unchecked Sendable {
    static let shared = InviteProbeMode()
    private let lock = NSLock()
    private var _lean = true
    /// false once the lean `$select` form got a 400: use the documented form from then on.
    var lean: Bool { get { lock.withLock { _lean } } set { lock.withLock { _lean = newValue } } }
}

struct GMEventMessage: Decodable {
    struct Loc: Decodable { var displayName: String? }
    struct Resp: Decodable { var response: String? }
    struct Ev: Decodable {
        var id: String
        var subject: String?
        var start: GMDateTimeTZ?; var end: GMDateTimeTZ?
        var isAllDay: Bool?
        var location: Loc?
        var organizer: GMAddr?
        var responseStatus: Resp?
        var allowNewTimeProposals: Bool?
        var responseRequested: Bool?
        var isCancelled: Bool?
        var isOrganizer: Bool?
    }
    var odataType: String?
    var subject: String?
    var meetingMessageType: String?
    var startDateTime: GMDateTimeTZ?; var endDateTime: GMDateTimeTZ?
    var isAllDay: Bool?
    var isOutOfDate: Bool?
    var location: Loc?
    var event: Ev?
    var internetMessageHeaders: [GMHeaders.H]?
    enum CodingKeys: String, CodingKey {
        case odataType = "@odata.type", subject, meetingMessageType, startDateTime, endDateTime, isAllDay, isOutOfDate, location, event,
             internetMessageHeaders
    }
    var headers: [MessageHeader] {
        (internetMessageHeaders ?? []).compactMap { x in x.name.map { MessageHeader(name: $0, value: x.value ?? "") } }
    }

    func toModel() -> MeetingInvite? {
        let isEventMessage = (odataType ?? "").lowercased().contains("eventmessage")
        guard let kind = MeetingMessageKind.from(graph: meetingMessageType) ?? (isEventMessage ? .other : nil) else { return nil }
        let e = event
        let loc = e?.location?.displayName ?? location?.displayName
        return MeetingInvite(
            kind: kind, eventId: e?.id, subject: e?.subject ?? subject ?? "",
            start: GraphMailService.parseDTZ(e?.start) ?? GraphMailService.parseDTZ(startDateTime),
            end: GraphMailService.parseDTZ(e?.end) ?? GraphMailService.parseDTZ(endDateTime),
            isAllDay: e?.isAllDay ?? isAllDay ?? false,
            location: (loc?.isEmpty ?? true) ? nil : loc,
            organizer: GMMessage.addr(e?.organizer), myResponse: e?.responseStatus?.response,
            allowNewTimeProposals: e?.allowNewTimeProposals ?? true, responseRequested: e?.responseRequested ?? true,
            isOutOfDate: isOutOfDate ?? false, eventCancelled: e?.isCancelled ?? false, isOrganizer: e?.isOrganizer ?? false)
    }
}

struct GMHeaders: Decodable {
    struct H: Decodable { var name: String?; var value: String? }
    var internetMessageHeaders: [H]?
}

extension GraphMailService: MailReaderServicing {
    static let inviteLeanSelect = ["meetingMessageType", "startDateTime", "endDateTime", "isAllDay", "isOutOfDate", "location"]
        .map { "microsoft.graph.eventMessage/\($0)" }.joined(separator: ",") + ",subject,internetMessageHeaders"
    static let inviteEventSelect = "id,subject,start,end,isAllDay,location,organizer,responseStatus,allowNewTimeProposals,responseRequested,isCancelled,isOrganizer"

    public func readerInfo(messageId: String, mailbox: String) async throws -> ReaderInfo {
        let path = "\(p(mailbox))/messages/\(messageId)"
        if InviteProbeMode.shared.lean {
            do {
                let m: GMEventMessage = try await get(url(path, [
                    "$select": Self.inviteLeanSelect,
                    "$expand": "microsoft.graph.eventMessage/event($select=\(Self.inviteEventSelect))",
                ]), mailbox: mailbox, prefer: [#"outlook.timezone="UTC""#])
                return ReaderInfo(invite: m.toModel(), headers: m.headers)
            } catch MailServiceError.http(400, _) {
                InviteProbeMode.shared.lean = false
            }
        }
        return ReaderInfo(invite: try await meetingInvite(messageId: messageId, mailbox: mailbox),
                          headers: try await internetHeaders(messageId: messageId, mailbox: mailbox))
    }

    /// Documented form (Learn example 2): the cast `$expand` only.
    public func meetingInvite(messageId: String, mailbox: String) async throws -> MeetingInvite? {
        do {
            let m: GMEventMessage = try await get(url("\(p(mailbox))/messages/\(messageId)", ["$expand": "microsoft.graph.eventMessage/event"]),
                                                  mailbox: mailbox, prefer: [#"outlook.timezone="UTC""#])
            return m.toModel()
        } catch MailServiceError.http(400, _) {
            return nil   // a plain message refusing the cast expand: not an invite
        }
    }

    public func internetHeaders(messageId: String, mailbox: String) async throws -> [MessageHeader] {
        let h: GMHeaders = try await get(url("\(p(mailbox))/messages/\(messageId)", ["$select": "internetMessageHeaders"]), mailbox: mailbox)
        return (h.internetMessageHeaders ?? []).compactMap { x in
            guard let n = x.name else { return nil }
            return MessageHeader(name: n, value: x.value ?? "")
        }
    }

    public func mimeSource(messageId: String, mailbox: String) async throws -> Data {
        try await rawGET(url("\(p(mailbox))/messages/\(messageId)/$value"), mailbox: mailbox)
    }

    public static func reportJSON(_ action: JunkReport, move: Bool) -> [String: Any] {
        ["IsMessageMoveRequested": move, "ReportAction": action.rawValue]
    }

    public func report(_ action: JunkReport, messageId: String, mailbox: String, move: Bool) async throws -> MailMessage? {
        let item = "\(p(mailbox))/messages/\(messageId)"
        do {
            let m: GMMessage = try await send(url("\(item)/reportMessage"), method: "POST", mailbox: mailbox,
                                              json: Self.reportJSON(action, move: move))
            return m.toModel(defaultFolder: "", tenant: labelTenant)
        } catch MailServiceError.notFound {
            return try await reportFallback(action, messageId: messageId, mailbox: mailbox, move: move)
        } catch MailServiceError.http(let c, _) where [400, 405, 501].contains(c) {
            return try await reportFallback(action, messageId: messageId, mailbox: mailbox, move: move)
        }
    }

    private func reportFallback(_ action: JunkReport, messageId: String, mailbox: String, move: Bool) async throws -> MailMessage? {
        guard move else { return nil }
        return try await apply(.move(toFolderId: action == .notJunk ? "inbox" : "junkemail"), messageId: messageId, mailbox: mailbox)
    }
}

// MARK: - Fixtures

extension FixtureMailService: MailReaderServicing {
    public func readerInfo(messageId: String, mailbox: String) async throws -> ReaderInfo {
        ReaderInfo(invite: try await meetingInvite(messageId: messageId, mailbox: mailbox),
                   headers: try await internetHeaders(messageId: messageId, mailbox: mailbox))
    }

    public func meetingInvite(messageId: String, mailbox: String) async throws -> MeetingInvite? {
        // Synthetic: ids containing "invite" (or every 7th fixture message) are meeting requests, "cancel" cancellations.
        let lower = messageId.lowercased()
        let bucket = messageId.utf8.reduce(0) { $0 + Int($1) } % 7
        let start = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
        if lower.contains("invite") || bucket == 1 {
            return MeetingInvite(kind: .request, eventId: "fx-ev-\(messageId)", subject: "Synthetic planning session",
                                 start: start, end: start.addingTimeInterval(3600), location: "Room 1 (fixture)",
                                 organizer: EmailAddress(name: "Priya Shah", address: "priya.shah@contoso.example"),
                                 myResponse: "notResponded")
        }
        if lower.contains("cancel") {
            return MeetingInvite(kind: .cancelled, eventId: "fx-ev-\(messageId)", subject: "Synthetic cancelled sync",
                                 start: start, end: start.addingTimeInterval(1800), eventCancelled: true)
        }
        return nil
    }

    public func internetHeaders(messageId: String, mailbox: String) async throws -> [MessageHeader] {
        var h = [MessageHeader(name: "Received", value: "from mx.contoso.example by fixture; synthetic"),
                 MessageHeader(name: "Message-ID", value: "<\(messageId)@fixture.example>")]
        if messageId.utf8.reduce(0, { $0 + Int($1) }) % 3 == 0 {   // a third of fixture mail is "bulk"
            h += [MessageHeader(name: "List-Unsubscribe", value: "<mailto:unsubscribe@news.contoso.example?subject=unsubscribe>, <https://news.contoso.example/u/fixture>"),
                  MessageHeader(name: "List-Unsubscribe-Post", value: "List-Unsubscribe=One-Click")]
        }
        return h
    }

    public func mimeSource(messageId: String, mailbox: String) async throws -> Data {
        Data("MIME-Version: 1.0\r\nMessage-ID: <\(messageId)@fixture.example>\r\nSubject: Synthetic fixture\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSynthetic fixture body. No real content.\r\n".utf8)
    }

    public func report(_ action: JunkReport, messageId: String, mailbox: String, move: Bool) async throws -> MailMessage? {
        guard move else { return nil }
        return try await apply(.move(toFolderId: action == .notJunk ? "inbox" : "junkemail"), messageId: messageId, mailbox: mailbox)
    }
}

// MARK: - Block sender (inbox rule; Graph has no blocked-senders API)

public enum BlockSender {
    /// "Block <address>": an inbox rule moving everything from that sender to Junk, stopping further rules.
    public static func rule(for address: String, junkFolderId: String) -> MailRule? {
        let a = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard a.contains("@"), !a.contains(" ") else { return nil }
        return MailRule(displayName: "Block \(a)",
                        conditions: RuleConditions(fromAddresses: [EmailAddress(name: "", address: a)]),
                        actions: RuleActions(moveToFolder: junkFolderId, stopProcessingRules: true))
    }
}

// MARK: - Gates (print / source / .eml)

/// Every reader egress (paper, source view, file) is decided here, from the label's rights AND the device policy.
/// Returns nil when allowed, else the reason shown to the user.
public enum ReaderGates {
    public static func print(_ p: ContentPolicy, devicePrint: Bool) -> String? {
        if p.redactDetails { return "This message is private." }
        if case .unknown = p.labelState { return "This message's label isn't in your synced policy, so it can't be printed." }
        if p.bodyIsProtected { return "Printing encrypted mail isn't supported yet." }
        if !p.allowPrint { return "The sensitivity label doesn't allow printing." }
        if !devicePrint { return "Printing is blocked by this Mac's trust policy." }
        return nil
    }

    /// Headers + MIME. Never for private, unknown-label or encrypted mail; labelled mail needs EXPORT and EXTRACT.
    public static func source(_ p: ContentPolicy) -> String? {
        if p.redactDetails { return "This message is private." }
        if case .unknown = p.labelState { return "This message's label isn't in your synced policy." }
        if p.bodyIsProtected { return "The source of encrypted mail isn't shown." }
        if !(p.allowExport && p.allowCopy) { return "The sensitivity label doesn't allow exporting or copying this message." }
        return nil
    }

    /// Save as .eml: the source gate plus the device's copy-out rule (a file leaves the app).
    public static func saveEML(_ p: ContentPolicy, deviceCopyOut: Bool) -> String? {
        if let r = source(p) { return r }
        if !deviceCopyOut { return "Saving files is blocked by this Mac's trust policy." }
        return nil
    }
}

// MARK: - Print document

public enum PrintDocument {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A printable page: header block (subject / from / to / date) above the already-sanitised body, the label's
    /// header marking first, its footer marking last, and its watermark as a fixed overlay (repeated on every page by
    /// WebKit's print layout — UNVERIFIED on paper). `bodyHTML` must be the reader's sanitised fragment.
    public static func html(bodyHTML: String, subject: String, from: String, to: String, date: String,
                            headerMarking: String?, footerMarking: String?, watermark: String?) -> String {
        var top = ""
        if let h = headerMarking, !h.isEmpty { top += "<div class=\"mk mk-h\">\(esc(h))</div>" }
        let meta = """
        <div class="meta"><div class="subj">\(esc(subject.isEmpty ? "(no subject)" : subject))</div>
        <div><b>From:</b> \(esc(from))</div>\(to.isEmpty ? "" : "<div><b>To:</b> \(esc(to))</div>")<div><b>Date:</b> \(esc(date))</div></div>
        """
        var bottom = ""
        if let f = footerMarking, !f.isEmpty { bottom += "<div class=\"mk mk-f\">\(esc(f))</div>" }
        var wm = ""
        if let w = watermark, !w.isEmpty {
            wm = "<div class=\"wm\" aria-hidden=\"true\">" + String(repeating: "<span>\(esc(w))</span>", count: 12) + "</div>"
        }
        let csp = "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; font-src data:; img-src data: cid:; style-src 'unsafe-inline'"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>
        html,body{margin:0;padding:0;background:#fff;color:#111;font:12pt -apple-system,system-ui,sans-serif;line-height:1.45;word-wrap:break-word}
        .meta{border-bottom:1px solid #999;padding-bottom:8px;margin-bottom:12px;font-size:10pt}
        .subj{font-size:15pt;font-weight:600;margin-bottom:4px}
        .mk{font-weight:600;text-align:center;font-size:10pt;padding:4px 0}
        .mk-h{border-bottom:1px solid #c00;color:#c00;margin-bottom:8px}
        .mk-f{border-top:1px solid #c00;color:#c00;margin-top:12px}
        img{max-width:100%;height:auto} table{max-width:100%}
        .wm{position:fixed;inset:0;display:flex;flex-wrap:wrap;align-content:space-around;justify-content:space-around;
            pointer-events:none;opacity:.12;transform:rotate(-30deg);font-size:28pt;font-weight:700;color:#000;z-index:9999}
        .wm span{padding:40px}
        </style></head><body>\(top)\(meta)<div class="body">\(bodyHTML)</div>\(bottom)\(wm)</body></html>
        """
    }
}

// MARK: - Unsubscribe (RFC 2369 List-Unsubscribe, RFC 8058 one-click)

public struct ListUnsubscribe: Sendable, Hashable {
    public var mailto: [URL]
    public var https: [URL]
    /// RFC 8058: List-Unsubscribe-Post: List-Unsubscribe=One-Click plus an https URI.
    public var oneClick: Bool

    public var isEmpty: Bool { mailto.isEmpty && https.isEmpty }
    /// The one-click target (first https URI), only when the sender declared one-click.
    public var oneClickURL: URL? { oneClick ? https.first : nil }

    /// Pure parsing: no network, no side effects. http (not https) URIs are ignored; so are credentials in URLs.
    public static func parse(_ headers: [MessageHeader]) -> ListUnsubscribe? {
        func value(_ n: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.value
        }
        guard let raw = value("List-Unsubscribe") else { return nil }
        var mailto: [URL] = [], https: [URL] = []
        let unfolded = raw.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        var rest = Substring(unfolded)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let uri = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: close)...]
            guard let u = URL(string: uri), let scheme = u.scheme?.lowercased() else { continue }
            if scheme == "mailto" { mailto.append(u) }
            else if scheme == "https", u.host != nil, u.user == nil, u.password == nil { https.append(u) }
        }
        let post = (value("List-Unsubscribe-Post") ?? "").replacingOccurrences(of: " ", with: "")
        let oneClick = post.caseInsensitiveCompare("List-Unsubscribe=One-Click") == .orderedSame && !https.isEmpty
        let r = ListUnsubscribe(mailto: mailto, https: https, oneClick: oneClick)
        return r.isEmpty ? nil : r
    }

    /// A mailto: unsubscribe becomes a draft the user reviews and sends — never sent automatically.
    public struct MailtoDraft: Sendable, Hashable {
        public var to: String
        public var subject: String
        public var body: String
    }

    public static func draft(from mailto: URL) -> MailtoDraft? {
        guard mailto.scheme?.lowercased() == "mailto",
              let c = URLComponents(url: mailto, resolvingAgainstBaseURL: false) else { return nil }
        let to = c.path.removingPercentEncoding ?? c.path
        guard to.contains("@") else { return nil }
        let q = c.queryItems ?? []
        func item(_ n: String) -> String? { q.first { $0.name.lowercased() == n }?.value }
        return MailtoDraft(to: to, subject: item("subject") ?? "unsubscribe", body: item("body") ?? "")
    }
}

/// RFC 8058 one-click POST. Only callable with the host the user confirmed in a dialog naming it; https only; no
/// cookies, credentials or cache (ephemeral session). This is an egress: nothing calls it without that confirmation.
public enum Unsubscriber {
    public enum Refused: Error, Equatable, Sendable { case notHTTPS, hostNotConfirmed, failed(Int) }

    public static func ephemeralSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil; c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }

    public static func oneClick(_ url: URL, confirmedHost: String, session: URLSession = ephemeralSession()) async throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { throw Refused.notHTTPS }
        guard let host = url.host?.lowercased(), host == confirmedHost.lowercased() else { throw Refused.hostNotConfirmed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("niivo-mail/0.1", forHTTPHeaderField: "User-Agent")
        req.httpShouldHandleCookies = false
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Refused.failed(code) }
    }
}
