import Foundation

// Meeting responses (accept / tentative / decline, propose a new time) for the mail invite card and the calendar
// inspector. A standalone client with its own token closure, so GraphCalendarService stays untouched.
//
// Verified on Microsoft Learn (2026-11-20):
//  * POST /me/events/{id}/accept | tentativelyAccept | decline, body { comment, sendResponse } → 202, no body.
//    https://learn.microsoft.com/graph/api/event-tentativelyaccept?view=graph-rest-1.0
//  * proposedNewTime (timeSlot { start, end } of dateTimeTimeZone) only on tentativelyAccept and decline; 400 when
//    the event's allowNewTimeProposals is false or sendResponse is false. Validated here before any request.
//  * DELETE /me/events/{id} removes an event (used for "Remove from calendar" on a cancelled meeting).
// UNVERIFIED: the calendar-scoped path `/users/{x}/calendars/{cal}/events/{id}/accept` for delegated calendars
// (the documented paths are /me/events/{id}, /users/{id}/events/{id}, /me/calendars/{id}/events/{id}); mirrors the
// addressing `GraphCalendarService.remove` already uses for decline.

public enum InviteResponse: String, Sendable, Hashable, CaseIterable {
    case accept
    case tentativelyAccept
    case decline

    public var title: String {
        switch self { case .accept: "Accept"; case .tentativelyAccept: "Tentative"; case .decline: "Decline" }
    }
    /// Value of Graph's `responseStatus.response` once this response is applied.
    public var responseStatus: String {
        switch self { case .accept: "accepted"; case .tentativelyAccept: "tentativelyAccepted"; case .decline: "declined" }
    }
}

public struct InviteReply: Sendable, Hashable {
    public var response: InviteResponse
    public var comment: String?
    /// false = respond silently (the organiser isn't told).
    public var sendResponse: Bool
    public var proposedStart: Date?
    public var proposedEnd: Date?

    public init(_ response: InviteResponse, comment: String? = nil, sendResponse: Bool = true,
                proposedStart: Date? = nil, proposedEnd: Date? = nil) {
        self.response = response; self.comment = comment; self.sendResponse = sendResponse
        self.proposedStart = proposedStart; self.proposedEnd = proposedEnd
    }

    public enum Invalid: Error, Equatable, Sendable {
        /// Graph only takes proposedNewTime on tentativelyAccept / decline.
        case proposalNotWithAccept
        /// proposedNewTime needs sendResponse = true (400 otherwise).
        case proposalNeedsResponse
        /// The organiser turned off new time proposals (400 otherwise).
        case proposalsNotAllowed
        case proposalEndNotAfterStart
        case proposalIncomplete
    }

    public var hasProposal: Bool { proposedStart != nil || proposedEnd != nil }

    /// Checks the documented 400 cases locally, so nothing is sent that Graph would refuse.
    public func validate(allowNewTimeProposals: Bool) throws {
        guard hasProposal else { return }
        guard let s = proposedStart, let e = proposedEnd else { throw Invalid.proposalIncomplete }
        if response == .accept { throw Invalid.proposalNotWithAccept }
        if !sendResponse { throw Invalid.proposalNeedsResponse }
        if !allowNewTimeProposals { throw Invalid.proposalsNotAllowed }
        if e <= s { throw Invalid.proposalEndNotAfterStart }
    }

    /// Request body. `comment` is omitted when empty; proposedNewTime in UTC wall time.
    public func json() -> [String: Any] {
        var j: [String: Any] = ["sendResponse": sendResponse]
        if let c = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { j["comment"] = c }
        if let s = proposedStart, let e = proposedEnd {
            j["proposedNewTime"] = ["start": GraphTime.json(s, allDay: false), "end": GraphTime.json(e, allDay: false)]
        }
        return j
    }

    public static func describe(_ e: Invalid) -> String {
        switch e {
        case .proposalNotWithAccept: "A new time can only be proposed with Tentative or Decline."
        case .proposalNeedsResponse: "Proposing a new time sends a response to the organiser; it can't be silent."
        case .proposalsNotAllowed: "The organiser doesn't allow new time proposals for this meeting."
        case .proposalEndNotAfterStart: "The proposed end must be after the start."
        case .proposalIncomplete: "Pick both a start and an end for the proposed time."
        }
    }
}

/// Sends meeting responses. Graph and fixtures conform.
public protocol InviteResponding: Sendable {
    /// `mailboxPath` is "me" or "users/{upn}" (a leading "/" is tolerated). `calendarId` addresses the event through
    /// its calendar (delegated calendars); nil = the mailbox's event collection.
    func respond(mailboxPath: String, calendarId: String?, eventId: String, reply: InviteReply) async throws
    /// DELETE the event (a cancelled meeting the user removes from their calendar).
    func removeEvent(mailboxPath: String, calendarId: String?, eventId: String) async throws
}

public final class GraphInviteResponder: InviteResponding, @unchecked Sendable {
    public typealias TokenProvider = @Sendable () async throws -> String
    private let token: TokenProvider
    private let session: URLSession
    private let base = URL(string: "https://graph.microsoft.com/v1.0")!

    public init(token: @escaping TokenProvider, session: URLSession = .shared) {
        self.token = token; self.session = session
    }

    func eventURL(_ mailboxPath: String, _ calendarId: String?, _ eventId: String) -> URL {
        var root = mailboxPath.hasPrefix("/") ? String(mailboxPath.dropFirst()) : mailboxPath
        if root.isEmpty { root = "me" }
        if let calendarId { return base.appending(path: "\(root)/calendars/\(calendarId)/events/\(eventId)") }
        return base.appending(path: "\(root)/events/\(eventId)")
    }

    public func respond(mailboxPath: String, calendarId: String?, eventId: String, reply: InviteReply) async throws {
        let url = eventURL(mailboxPath, calendarId, eventId).appending(path: reply.response.rawValue)
        try await send(url, method: "POST", body: try JSONSerialization.data(withJSONObject: reply.json(), options: [.sortedKeys]))
    }

    public func removeEvent(mailboxPath: String, calendarId: String?, eventId: String) async throws {
        do { try await send(eventURL(mailboxPath, calendarId, eventId), method: "DELETE", body: nil) }
        catch ServiceError.http(404, _) { return }   // already gone
    }

    private func send(_ url: URL, method: String, body: Data?) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.setValue("niivo-mail/0.1", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<4 {
            let data: Data, resp: URLResponse
            do { (data, resp) = try await session.data(for: req) }
            catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                           .cannotFindHost, .dataNotAllowed].contains(e.code) {
                throw ServiceError.offline
            }
            let http = resp as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200..<300: return
            case 401, 403: throw ServiceError.unauthorized
            case 409, 412: throw ServiceError.conflict
            case 429, 503, 504:
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt))
                try await Task.sleep(for: .milliseconds(Int(min(wait, 30) * 1000)))
            case let c: throw ServiceError.http(c, String((String(data: data, encoding: .utf8) ?? "").prefix(200)))
            }
        }
        throw ServiceError.http(429, "throttled")
    }
}

/// Fixture mode: records what would have been sent; nothing leaves the Mac.
public final class FixtureInviteResponder: InviteResponding, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [(String, InviteReply?)] = []
    public init() {}
    public var log: [(String, InviteReply?)] { lock.withLock { _log } }
    public func respond(mailboxPath: String, calendarId: String?, eventId: String, reply: InviteReply) async throws {
        lock.withLock { _log.append((eventId, reply)) }
    }
    public func removeEvent(mailboxPath: String, calendarId: String?, eventId: String) async throws {
        lock.withLock { _log.append((eventId, nil)) }
    }
}

/// Conflicts between a proposed slot and the user's own calendar (cancelled and free items never conflict).
public enum InviteConflicts {
    public static func conflicts(start: Date, end: Date, isAllDay: Bool = false, in events: [CalendarEvent],
                                 excludingEventId: String? = nil, calendar: Calendar = .current) -> [CalendarEvent] {
        let s = isAllDay ? calendar.startOfDay(for: start) : start
        let e = isAllDay ? max(end, calendar.date(byAdding: .day, value: 1, to: s)!) : end
        return events.filter { ev in
            ev.id != excludingEventId && !ev.isCancelled && ev.showAs != .free && ev.start < e && ev.end > s
        }
        .sorted { $0.start < $1.start }
    }
}
