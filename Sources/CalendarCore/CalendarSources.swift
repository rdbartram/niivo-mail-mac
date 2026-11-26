import Foundation

/// The incremental-consent set a Graph request needs. Each set is its own MSAL silent token, so an unconsented
/// optional set (groups, places) never breaks the calendar token, which keeps its original scopes.
public enum GraphScope: Sendable, Hashable {
    /// `Auth.calendarScopes` (Calendars.ReadWrite.Shared, …). Unchanged.
    case calendar
    /// `/me/memberOf` group list (GroupMember.Read.All).
    case groupMembership
    /// `/groups/{id}/calendar…` read + write (Learn: Group.Read.All least privileged for calendarView;
    /// Group.ReadWrite.All for create/update/delete). The app asks for Group.ReadWrite.All (admin-consented).
    case groupCalendar
    /// `/places/…` room lists and rooms (Place.Read.All).
    case places
    /// `/me/outlook/masterCategories` (MailboxSettings.Read; the mail set's MailboxSettings.ReadWrite covers it).
    case mailboxSettings
}

/// A calendar the user added by hand: another person's (or a shared/resource mailbox's) calendars by address, or a
/// Microsoft 365 group calendar. Persisted sealed in the calendar store (`CalendarSources.storeKey`).
public enum CalendarSource: Codable, Sendable, Hashable, Identifiable {
    case user(address: String)
    case group(id: String, name: String, mail: String?)

    public var id: String {
        switch self {
        case .user(let a): "user:" + a.lowercased()
        case .group(let id, _, _): "group:" + id
        }
    }
    public var displayName: String {
        switch self {
        case .user(let a): a
        case .group(_, let n, _): n
        }
    }
    /// Graph mailbox path of the calendars this source yields.
    public var mailboxPath: String {
        switch self {
        case .user(let a): "/users/" + a.lowercased()
        case .group(let id, _, _): "/groups/" + id
        }
    }
}

public enum CalendarSources {
    public static let storeKey = "calendarSources"

    /// Parses "Name <addr>" or a bare address. nil when it isn't an address.
    public static func address(from text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lt = t.firstIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt { t = String(t[t.index(after: lt)..<gt]) }
        t = t.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = t.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !t.contains(" "), !t.contains("/") else { return nil }
        return t
    }

    /// Adds without duplicates (same address / group id).
    public static func adding(_ s: CalendarSource, to list: [CalendarSource]) -> [CalendarSource] {
        list.contains { $0.id == s.id } ? list : list + [s]
    }

    /// Calendars that came from a source (to remove them with it).
    public static func calendars(of s: CalendarSource, in cals: [CalendarInfo]) -> [CalendarInfo] {
        cals.filter { $0.mailboxPath.lowercased() == s.mailboxPath.lowercased() && $0.access == .shared }
    }
}

/// Why an added calendar can't be shown. 403 and 404 are kept apart on purpose: "not shared with you" is a
/// different conversation from "no such mailbox".
public enum CalendarSourceError: Error, Equatable, Sendable {
    /// 403: the mailbox exists but its calendar isn't shared with you (or not at a level Graph can read).
    case noAccess
    /// 404: no such user / group / mailbox (or not visible in this tenant).
    case notFound
    /// The scope set isn't consented / the token needs interaction (groups).
    case needsConsent
    case offline
    case other(String)

    public init(_ error: Error) {
        switch error {
        case let e as CalendarSourceError: self = e
        case ServiceError.http(403, _): self = .noAccess
        case ServiceError.http(404, _): self = .notFound
        case ServiceError.unauthorized: self = .needsConsent
        case ServiceError.offline: self = .offline
        case ServiceError.http(let c, _): self = .other("HTTP \(c)")
        default:
            // MSAL interaction-required (and similar) arrives as an NSError from the token provider.
            let ns = error as NSError
            self = ns.domain.contains("MSAL") || ns.domain == "Auth" ? .needsConsent : .other("\(ns.domain) \(ns.code)")
        }
    }

    /// User-facing text (British English, no tenant data).
    public var message: String {
        switch self {
        case .noAccess: "That calendar isn’t shared with you. Ask its owner to share it, then try again."
        case .notFound: "No mailbox or group with that address was found."
        case .needsConsent: "Access to this calendar needs consent. Grant access and try again."
        case .offline: "You’re offline. Try again when connected."
        case .other(let s): "The calendar couldn’t be added (\(s))."
        }
    }
}

/// A Microsoft 365 group the user belongs to.
public struct GroupRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var mail: String?
    public init(id: String, name: String, mail: String?) { self.id = id; self.name = name; self.mail = mail }
}

// MARK: - Sealed values in the calendar store

public extension LocalStore {
    /// JSON → sealed with the store's cipher → base64 in `kv`. Settings that name people or groups never sit in
    /// plaintext (the plain `value(for:)` is for delta links and timestamps).
    func setSealed<T: Encodable>(_ v: T?, for key: String) throws {
        guard let v else { try setValue(nil, for: key); return }
        try setValue(try sealData(JSONEncoder().encode(v)).base64EncodedString(), for: key)
    }
    func sealed<T: Decodable>(_ t: T.Type, for key: String) -> T? {
        guard let s = try? value(for: key), let d = Data(base64Encoded: s), let plain = try? openData(d) else { return nil }
        return try? JSONDecoder().decode(t, from: plain)
    }
    func calendarSources() -> [CalendarSource] { sealed([CalendarSource].self, for: CalendarSources.storeKey) ?? [] }
    func setCalendarSources(_ s: [CalendarSource]) throws { try setSealed(s, for: CalendarSources.storeKey) }
}
