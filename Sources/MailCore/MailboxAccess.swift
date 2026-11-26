import Foundation

// MARK: - Additional mailboxes (shared / delegated / other user): address rules, errors, persisted list

/// Address typed into "Add mailbox…". It ends up in a Graph URL path (`/users/{address}/…`) and is used as the
/// mailbox key everywhere, so it is trimmed, lower-cased and must be a plain address (no path characters).
public enum MailboxAddress {
    public static func normalise(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // "Name <addr>" pasted from a header.
        if let lt = s.lastIndex(of: "<"), s.hasSuffix(">") { s = String(s[s.index(after: lt)..<s.index(before: s.endIndex)]) }
        s = s.trimmingCharacters(in: .whitespaces)
        guard s.count <= 254, s != "me",
              s.range(of: #"^[a-z0-9._+'-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$"#, options: .regularExpression) != nil,
              !s.contains(".."), !s.hasPrefix(".") else { return nil }
        return s
    }
}

/// Why a mailbox can't be opened. 403 and 404 are told apart because the fix differs (ask for permission vs check
/// the address). Exchange can answer 404 for a mailbox that exists but isn't shared with you, so the 404 text says so.
public enum MailboxAccessError: Error, Sendable, Equatable {
    case invalidAddress, forbidden, notFound, offline, needsSignIn, other(Int)

    public init(_ error: Error) {
        if let e = error as? MailboxAccessError { self = e; return }
        switch error as? MailServiceError {
        case .forbidden?: self = .forbidden
        case .notFound?: self = .notFound
        case .offline?: self = .offline
        case .sendAsDenied?: self = .forbidden
        case .http(401, _)?: self = .needsSignIn
        case .http(403, _)?: self = .forbidden
        case .http(404, _)?: self = .notFound
        case .http(let c, _)?: self = .other(c)
        default: self = .other(0)
        }
    }

    /// Content-free code for logs.
    public var code: String {
        switch self {
        case .invalidAddress: "invalid"; case .forbidden: "403"; case .notFound: "404"; case .offline: "offline"
        case .needsSignIn: "401"; case .other(let c): "http \(c)"
        }
    }

    public var message: String {
        switch self {
        case .invalidAddress: "Enter a full email address, for example support@contoso.com."
        case .forbidden: "You don't have permission to open this mailbox. Ask its owner or an Exchange admin for Full Access, or for permission on its folders."
        case .notFound: "No mailbox was found at this address, or it isn't shared with you. Check the spelling."
        case .offline: "You're offline. Try again when you're connected."
        case .needsSignIn: "Your sign-in has expired. Sign in again, then retry."
        case .other(let c): c == 0 ? "The mailbox couldn't be opened." : "Exchange refused the request (HTTP \(c))."
        }
    }
}

/// How the added mailbox is used: decides the From identity it offers.
public enum MailboxAccessKind: String, Codable, Sendable, CaseIterable, Hashable {
    case shared, delegate, readOnly
    public var title: String {
        switch self { case .shared: "Shared mailbox (send as)"; case .delegate: "Delegate (send on behalf)"; case .readOnly: "Read only" }
    }
    public func identity(address: String, name: String) -> SendIdentity? {
        switch self {
        case .shared: SendIdentity(address: address, name: name, mailbox: address, mode: .sendAs)
        case .delegate: SendIdentity(address: address, name: name, mailbox: address, mode: .sendOnBehalf)
        case .readOnly: nil
        }
    }
}

/// The persisted mailbox list. Config-declared mailboxes (AppConfig shared/delegated) plus the ones added in the app,
/// minus the ones removed, in the user's order. "me" always first.
public enum MailboxList {
    public static func compose(configured: [String], settings s: MailSettings) -> [String] {
        // Config entries keep their spelling (it is the key for their cache, pins and identities); comparisons are
        // case-insensitive.
        let removed = Set((s.removedMailboxes ?? []).map { $0.lowercased() })
        var out: [String] = []
        for mb in configured + (s.addedMailboxes ?? [])
        where mb.lowercased() != "me" && !removed.contains(mb.lowercased()) && !out.contains(where: { $0.lowercased() == mb.lowercased() }) {
            out.append(mb)
        }
        let order = (s.mailboxOrder ?? []).map { $0.lowercased() }
        let rank = { (mb: String) in order.firstIndex(of: mb.lowercased()) ?? Int.max }
        out = out.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        return ["me"] + out
    }
}

public extension MailSettings {
    func isCollapsed(_ mailbox: String) -> Bool { (collapsedMailboxes ?? []).contains(mailbox) }

    mutating func setCollapsed(_ mailbox: String, _ on: Bool) {
        var c = collapsedMailboxes ?? []
        c.removeAll { $0 == mailbox }
        if on { c.append(mailbox) }
        collapsedMailboxes = c
    }

    /// Remember an added mailbox (and offer its From identity unless one exists for it already).
    mutating func addMailbox(_ mailbox: String, identity: SendIdentity?) {
        var a = addedMailboxes ?? []
        if !a.contains(mailbox) { a.append(mailbox) }
        addedMailboxes = a
        removedMailboxes = (removedMailboxes ?? []).filter { $0.lowercased() != mailbox.lowercased() }
        if let identity, !identities.contains(where: { $0.mailbox == mailbox }) { identities.append(identity) }
    }

    /// Forget a mailbox. `configured` → it comes from AppConfig, so it is remembered as removed (else it would be
    /// back on the next launch). Its From identities go too: you can't send from a mailbox you removed.
    mutating func removeMailbox(_ mailbox: String, configured: Bool) {
        let key = mailbox.lowercased()
        addedMailboxes = (addedMailboxes ?? []).filter { $0.lowercased() != key }
        if configured {
            var r = removedMailboxes ?? []
            if !r.contains(where: { $0.lowercased() == key }) { r.append(mailbox) }
            removedMailboxes = r
        }
        mailboxOrder = (mailboxOrder ?? []).filter { $0.lowercased() != key }
        collapsedMailboxes = (collapsedMailboxes ?? []).filter { $0 != mailbox }
        identities.removeAll { $0.mailbox.lowercased() == key }
        pinnedMailboxes.remove(mailbox)
        windows[mailbox] = nil
    }

    /// Move a mailbox up (-1) or down (+1) among the non-own mailboxes in `current` (the displayed list).
    mutating func moveMailbox(_ mailbox: String, by delta: Int, current: [String]) {
        var list = current.filter { $0 != "me" }
        guard let i = list.firstIndex(of: mailbox) else { return }
        let j = min(max(i + delta, 0), list.count - 1)
        guard i != j else { return }
        list.remove(at: i); list.insert(mailbox, at: j)
        mailboxOrder = list
    }
}

// MARK: - Directory lookup + access check

public struct MailboxValidation: Sendable, Equatable {
    public var address: String
    public var displayName: String
    public init(address: String, displayName: String) { self.address = address; self.displayName = displayName }
}

public protocol MailboxDirectory: Sendable {
    /// People / directory suggestions for a partial name or address. Best effort: callers fall back to the typed text.
    func search(_ query: String) async throws -> [EmailAddress]
    /// Can the signed-in user open this mailbox? `GET /users/{address}/mailFolders/inbox`. Throws `MailboxAccessError`.
    func validate(mailbox: String) async throws -> MailboxValidation
}

/// Graph implementation.
///  * Lookup: `GET /me/people?$search=` (People.Read) and `GET /users?$search="displayName:…" OR "mail:…"` with
///    `ConsistencyLevel: eventual` (User.ReadBasic.All). Both on the *directory* token, which is optional: without
///    consent the lookup is empty and the typed address still works (Graph can't list the mailboxes you can reach).
///  * Access check: `GET /users/{address}/mailFolders/inbox?$select=id` on the *mail* token (Mail.ReadWrite.Shared).
///    200 → reachable, 403 → no permission, 404 → not found / not shared.
public final class GraphMailboxDirectory: MailboxDirectory, @unchecked Sendable {
    private let mail: GraphHTTP
    private let directory: GraphHTTP?

    public init(mailToken: @escaping GraphHTTP.TokenProvider, directoryToken: GraphHTTP.TokenProvider?,
                session: URLSession = .shared) {
        mail = GraphHTTP(token: mailToken, session: session)
        directory = directoryToken.map { GraphHTTP(token: $0, session: session) }
    }

    public func search(_ query: String) async throws -> [EmailAddress] {
        let q = query.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, let directory else { return [] }
        async let people: [EmailAddress]? = try? {
            let page: GHPage<GHPerson> = try await directory.get(directory.url("me/people",
                ["$search": "\"\(q)\"", "$top": "8", "$select": "displayName,scoredEmailAddresses,userPrincipalName"]))
            return page.value.compactMap { p in
                (p.scoredEmailAddresses?.first?.address ?? p.userPrincipalName).map { EmailAddress(name: p.displayName ?? "", address: $0) }
            }
        }()
        async let users: [EmailAddress]? = try? {
            let page: GHPage<GHUser> = try await directory.get(directory.url("users",
                ["$search": "\"displayName:\(q)\" OR \"mail:\(q)\"", "$top": "8", "$select": "displayName,mail,userPrincipalName"]),
                headers: ["ConsistencyLevel": "eventual"])
            return page.value.compactMap { u in (u.mail ?? u.userPrincipalName).map { EmailAddress(name: u.displayName ?? "", address: $0) } }
        }()
        var out: [EmailAddress] = []
        for a in (await people ?? []) + (await users ?? []) where !out.contains(where: { $0.address.lowercased() == a.address.lowercased() }) {
            out.append(a)
        }
        return out
    }

    public func validate(mailbox raw: String) async throws -> MailboxValidation {
        guard let addr = MailboxAddress.normalise(raw) else { throw MailboxAccessError.invalidAddress }
        do {
            let _: GHId = try await mail.get(mail.url("users/\(addr)/mailFolders/inbox", ["$select": "id"]))
        } catch { throw MailboxAccessError(error) }
        // Display name: best effort on the directory token.
        var name = ""
        if let directory, let u: GHUser = try? await directory.get(directory.url("users/\(addr)", ["$select": "displayName,mail,userPrincipalName"])) {
            name = u.displayName ?? ""
        }
        return MailboxValidation(address: addr, displayName: name)
    }
}

/// Synthetic directory for fixtures and the self-test. `noaccess@contoso.example` answers 403; anything not in the
/// fixture people list answers 404.
public final class FixtureMailboxDirectory: MailboxDirectory, @unchecked Sendable {
    public static let forbiddenMailbox = "noaccess@contoso.example"
    public init() {}
    private var known: [EmailAddress] {
        [EmailAddress(name: "Contoso Support", address: FixtureMailService.sharedMailbox),
         EmailAddress(name: "Sam Rivera", address: FixtureMailService.principal),
         EmailAddress(name: "No Access Mailbox", address: Self.forbiddenMailbox)] + FixtureMailService.people
    }
    public func search(_ query: String) async throws -> [EmailAddress] {
        let q = query.lowercased()
        guard q.count >= 2 else { return [] }
        return known.filter { $0.address.lowercased().contains(q) || $0.name.lowercased().contains(q) }.prefix(8).map { $0 }
    }
    public func validate(mailbox raw: String) async throws -> MailboxValidation {
        guard let addr = MailboxAddress.normalise(raw) else { throw MailboxAccessError.invalidAddress }
        if addr == Self.forbiddenMailbox { throw MailboxAccessError.forbidden }
        guard let p = known.first(where: { $0.address.lowercased() == addr }) else { throw MailboxAccessError.notFound }
        return MailboxValidation(address: addr, displayName: p.name)
    }
}

// MARK: - Small Graph HTTP client shared by the mailbox directory and the groups service

/// Minimal Graph v1.0 client (same token-closure + URLSession shape as `GraphMailService`, so the URLProtocol stub
/// works). Errors map onto `MailServiceError`; only the Graph error *code* is kept, never the message text.
/// `idempotent: false` (POSTs that create content) retries on 429 only — a 503/504 may have been applied.
public struct GraphHTTP: Sendable {
    public typealias TokenProvider = @Sendable () async throws -> String
    let token: TokenProvider
    let session: URLSession
    let base = URL(string: "https://graph.microsoft.com/v1.0")!

    public init(token: @escaping TokenProvider, session: URLSession) { self.token = token; self.session = session }

    func url(_ path: String, _ q: [String: String] = [:]) -> URL { base.appending(path: path).mailQuery(q) }

    func get<T: Decodable>(_ url: URL, headers: [String: String] = [:], prefer: [String] = []) async throws -> T {
        let data = try await send(url, method: "GET", body: nil, headers: headers, prefer: prefer, idempotent: true)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw MailServiceError.http(200, "decode") }
    }

    @discardableResult
    func send(_ url: URL, method: String, body: Data?, headers: [String: String] = [:], prefer: [String] = [],
              idempotent: Bool) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("niivo-mail/0.1", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if !prefer.isEmpty { req.setValue(prefer.joined(separator: ", "), forHTTPHeaderField: "Prefer") }
        for attempt in 0..<4 {
            let data: Data, resp: URLResponse
            do { (data, resp) = try await session.data(for: req) }
            catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                           .cannotFindHost, .dataNotAllowed].contains(e.code) {
                throw MailServiceError.offline
            }
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            switch status {
            case 200..<300: return data
            case 429, 503, 504:
                if status != 429 && !idempotent { throw MailServiceError.http(status, "not retried") }
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt))
                try await Task.sleep(for: .milliseconds(Int(min(wait, 30) * 1000)))
            default:
                let code = (try? JSONDecoder().decode(GHError.self, from: data))?.error?.code ?? ""
                switch status {
                case 401: throw MailServiceError.http(401, code)
                case 403: throw MailServiceError.forbidden
                case 404: throw MailServiceError.notFound
                case 409, 412: throw MailServiceError.conflict
                default: throw MailServiceError.http(status, code)
                }
            }
        }
        throw MailServiceError.http(429, "throttled")
    }
}

struct GHError: Decodable { struct E: Decodable { var code: String? }; var error: E? }
struct GHId: Decodable { var id: String }
struct GHPage<T: Decodable>: Decodable {
    var value: [T]; var nextLink: String?
    enum CodingKeys: String, CodingKey { case value, nextLink = "@odata.nextLink" }
}
struct GHUser: Decodable { var displayName: String?; var mail: String?; var userPrincipalName: String? }
struct GHPerson: Decodable {
    struct A: Decodable { var address: String? }
    var displayName: String?; var scoredEmailAddresses: [A]?; var userPrincipalName: String?
}
