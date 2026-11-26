import Foundation

// App lifecycle and system integration, the testable half: mailto: parsing (RFC 6068), CAE claims challenges,
// Retry-After, the sync-status summary, notification filters and the background sync cadence. The AppKit half lives
// in CompliantCalendar/AppLifecycle.swift.

// MARK: - mailto: (RFC 6068)

/// A parsed `mailto:` link. Only `to`, `cc`, `bcc`, `subject` and `body` are honoured; every other header
/// (`in-reply-to`, `attach`, `from`…) is ignored, so a link can't attach files or forge threading.
/// `+` is a literal plus (RFC 6068 §5: unlike forms, it doesn't mean a space).
public struct MailtoLink: Equatable, Sendable {
    public var to: [String] = []
    public var cc: [String] = []
    public var bcc: [String] = []
    public var subject = ""
    public var body = ""

    public init(to: [String] = [], cc: [String] = [], bcc: [String] = [], subject: String = "", body: String = "") {
        self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject; self.body = body
    }

    public static let maxRecipients = 500
    public static let maxSubject = 998
    public static let maxBody = 200_000

    public var isEmpty: Bool { to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty && body.isEmpty }

    public static func parse(_ url: URL) -> MailtoLink? { parse(url.absoluteString) }

    public static func parse(_ raw: String) -> MailtoLink? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > 6, s.prefix(7).lowercased() == "mailto:" else { return nil }
        var rest = String(s.dropFirst(7))
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }   // a fragment is never part of it
        let path: Substring, query: Substring
        if let q = rest.firstIndex(of: "?") { path = rest[..<q]; query = rest[rest.index(after: q)...] }
        else { path = rest[...]; query = "" }
        var link = MailtoLink()
        link.to = addresses(String(path))
        var sawSubject = false, sawBody = false
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decode(String(kv[0])).lowercased()
            let value = kv.count > 1 ? String(kv[1]) : ""
            switch key {
            case "to": link.to += addresses(value)
            case "cc": link.cc += addresses(value)
            case "bcc": link.bcc += addresses(value)
            case "subject" where !sawSubject:
                sawSubject = true
                // One line: CR / LF / other controls in a subject would be header injection.
                let flat = decode(value).unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
                link.subject = String(flat.prefix(maxSubject))
            case "body" where !sawBody:
                sawBody = true
                let b = decode(value).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                link.body = String(b.prefix(maxBody))
            default: continue
            }
        }
        link.to = dedupe(link.to); link.cc = dedupe(link.cc); link.bcc = dedupe(link.bcc)
        return link
    }

    /// Comma-separated addr-specs, each percent-decoded. `Name <a@b>` is tolerated (the address is taken).
    static func addresses(_ s: String) -> [String] {
        // Split on the raw comma first: an encoded %2C belongs to the address (or display name), not the list.
        s.split(separator: ",").compactMap { part -> String? in
            var a = decode(String(part)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let lt = a.lastIndex(of: "<"), let gt = a.lastIndex(of: ">"), lt < gt {
                a = String(a[a.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            }
            guard a.contains("@"), !a.hasPrefix("@"), !a.hasSuffix("@"),
                  a.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  a.count <= 320 else { return nil }
            return a
        }
    }

    /// Lenient percent-decoding: valid %XX sequences (UTF-8) decode, a stray `%` stays as it is.
    static func decode(_ s: String) -> String {
        if let d = s.removingPercentEncoding { return d }
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: c - 48; case 65...70: c - 55; case 97...102: c - 87; default: nil }
        }
        while i < u.count {
            if u[i] == 37, i + 2 < u.count, let h = hex(u[i + 1]), let l = hex(u[i + 2]) { bytes.append(h << 4 | l); i += 3 }
            else { bytes.append(u[i]); i += 1 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func dedupe(_ xs: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for x in xs where seen.insert(x.lowercased()).inserted { out.append(x) }
        return Array(out.prefix(maxRecipients))
    }
}

// MARK: - CAE claims challenge

/// Graph's Continuous Access Evaluation / Conditional Access challenge: `401` + `WWW-Authenticate: Bearer …,
/// error="insufficient_claims", claims="<base64 JSON>"` (Learn: "Claims challenges, claims requests and client
/// capabilities"). The decoded JSON goes into MSAL's claims request.
public enum ClaimsChallenge {
    /// The decoded claims JSON, or nil when the header isn't a claims challenge. Accepts several headers (one per
    /// challenge) or one header holding several comma-separated challenges.
    public static func claims(fromWWWAuthenticate headers: [String]) -> String? {
        // `value(forHTTPHeaderField:)` comma-joins repeated headers, so split into one challenge per auth scheme;
        // `error` and `claims` must come from the same challenge.
        for h in headers.flatMap(challenges) {
            let p = parameters(h)
            guard p["error"]?.lowercased() == "insufficient_claims", let raw = p["claims"], !raw.isEmpty else { continue }
            if let json = decodeClaims(raw) { return json }
        }
        return nil
    }

    public static func claims(fromWWWAuthenticate header: String?) -> String? {
        header.flatMap { claims(fromWWWAuthenticate: [$0]) }
    }

    /// One string per challenge: a new challenge starts at an auth-scheme token (`Bearer`, `PoP`, …) that is not
    /// inside a quoted value.
    static func challenges(_ h: String) -> [String] {
        let schemes: Set<String> = ["bearer", "pop", "basic", "digest", "negotiate", "ntlm"]
        var out: [String] = [], cur = "", inQuote = false, escaped = false, word = ""
        func flushWord() {
            if schemes.contains(word.lowercased()), !cur.isEmpty {
                let before = String(cur.dropLast(word.count))
                if before.trimmingCharacters(in: .whitespaces).isEmpty || before.trimmingCharacters(in: .whitespaces).hasSuffix(",") {
                    let t = before.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                    if !t.isEmpty { out.append(t) }
                    cur = word
                }
            }
            word = ""
        }
        for ch in h {
            if inQuote {
                cur.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inQuote = false }
                continue
            }
            if ch == "\"" { inQuote = true; word = ""; cur.append(ch); continue }
            if ch.isLetter { word.append(ch); cur.append(ch); continue }
            if ch == " " || ch == "\t" { flushWord() } else { word = "" }
            cur.append(ch)
        }
        let t = cur.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        if !t.isEmpty { out.append(t) }
        return out
    }

    /// `name="quoted"` and `name=token` auth-params (RFC 7235), lower-cased names, within one challenge. First wins.
    static func parameters(_ h: String) -> [String: String] {
        var out: [String: String] = [:]
        let quoted = try! NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_\-]*)\s*=\s*"((?:[^"\\]|\\.)*)""#)
        let token = try! NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_\-]*)\s*=\s*([^\s",]+)"#)
        let ns = h as NSString
        var covered: [NSRange] = []
        for m in quoted.matches(in: h, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1)).lowercased()
            if out[k] == nil { out[k] = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: #"\""#, with: "\"") }
            covered.append(m.range)
        }
        for m in token.matches(in: h, range: NSRange(location: 0, length: ns.length))
        where !covered.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let k = ns.substring(with: m.range(at: 1)).lowercased()
            if out[k] == nil { out[k] = ns.substring(with: m.range(at: 2)) }
        }
        return out
    }

    /// Base64 (standard or URL-safe, padding optional) → JSON; raw JSON is passed through. Must parse as a JSON object.
    static func decodeClaims(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let candidate: String?
        if t.hasPrefix("{") { candidate = t }
        else {
            var b = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            candidate = Data(base64Encoded: b).flatMap { String(data: $0, encoding: .utf8) }
        }
        guard let c = candidate, let d = c.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: d)) is [String: Any] else { return nil }
        return c
    }
}

// MARK: - Retry-After

public enum RetryAfter {
    public static let maxWait: TimeInterval = 3600

    /// Seconds to wait: `Retry-After` as delta-seconds or an HTTP-date (RFC 9110 §10.2.3), clamped to 0…1 h;
    /// `fallback` when absent or unreadable.
    public static func seconds(_ header: String?, now: Date = Date(), fallback: TimeInterval) -> TimeInterval {
        guard let h = header?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return fallback }
        if let n = Double(h), n.isFinite { return min(max(0, n), maxWait) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: h) { return min(max(0, d.timeIntervalSince(now)), maxWait) }
        }
        return fallback
    }
}

// MARK: - Sync status summary

/// One line for the sidebar footer and the menu bar: the most actionable state wins.
public enum MailSyncHealth: Equatable, Sendable {
    case ok(lastSync: Date?)
    case syncing
    case offline
    case throttled(until: Date)
    /// Graph answered 401: the token is no longer accepted (sign in again).
    case authRequired
    /// CAE / Conditional Access claims challenge: re-authenticate with the claims.
    case claimsChallenge
    case error(String)

    /// Needs the user (a button, not just a status).
    public var needsSignIn: Bool { self == .authRequired || self == .claimsChallenge }

    public var title: String {
        switch self {
        case .ok: "Up to date"
        case .syncing: "Syncing"
        case .offline: "Offline — showing cached mail"
        case .throttled(let u): "Exchange is throttling — retrying \(u.formatted(date: .omitted, time: .shortened))"
        case .authRequired: "Sign-in required"
        case .claimsChallenge: "Your organisation asks you to sign in again"
        case .error: "Sync error"
        }
    }
}

extension MailSyncStatus {
    public func health(now: Date = Date()) -> MailSyncHealth {
        if claimsChallenge != nil { return .claimsChallenge }
        if authRequired { return .authRequired }
        if phase == .offline { return .offline }
        if let until = throttledUntil.values.max(), until > now { return .throttled(until: until) }
        switch phase {
        case .error(let m): return .error(m)
        case .syncing: return .syncing
        default: return .ok(lastSync: lastSync)
        }
    }
}

// MARK: - Notification filters

/// VIP membership for the "VIPs only" filter. The organisation feature's VIP list conforms; nil means "no VIP list",
/// and then the VIP filter isn't applied (it never silently mutes everything).
public protocol MailVIPLookup {
    func contains(_ address: String) -> Bool
}

public enum MailNotificationRule: String, Codable, Sendable, CaseIterable, Hashable {
    case all, focused, vip
    public var title: String {
        switch self { case .all: "All new mail"; case .focused: "Focused only"; case .vip: "VIPs only" }
    }
}

public enum MailNotificationFilter {
    /// Effective rule for a mailbox: its own override, else the global switches (VIPs only beats Focused only).
    public static func rule(for mailbox: String, settings s: MailNotificationSettings) -> MailNotificationRule {
        if let r = s.mailboxRules[mailbox] { return r }
        return s.vipOnly ? .vip : (s.focusedOnly ? .focused : .all)
    }

    /// Should this new, unseen message notify? (`MailArrivalTracker` decides "new"; this decides "wanted".)
    /// - isInbox: the message's folder is the mailbox's Inbox. Other folders notify only when listed in `folderIds`,
    ///   and the Focused rule applies to the Inbox only (other folders have no Focused/Other split).
    public static func shouldNotify(_ m: MailMessage, mailbox: String, isInbox: Bool,
                                    settings s: MailNotificationSettings, vip: MailVIPLookup?) -> Bool {
        guard s.enabled, s.mailboxes.contains(mailbox), !m.isDraft, !m.isRead else { return false }
        guard isInbox || s.folderIds.contains(m.folderId) else { return false }
        switch rule(for: mailbox, settings: s) {
        case .all: return true
        case .focused: return !isInbox || m.focus == .focused
        case .vip:
            guard let vip else { return true }
            let addrs = [m.from?.address, m.sender?.address].compactMap { $0?.lowercased() }
            return addrs.contains { vip.contains($0) }
        }
    }
}

// MARK: - Background cadence

/// The sync clock ticks every 30 s. With a window open: Inbox delta every tick, the open folder too. With every window
/// closed (menu bar only): Inbox delta every 2 min. A full pass every 5 min either way. Nothing while throttled.
public enum BackgroundSyncCadence {
    public static let tick: TimeInterval = 30

    public enum Work: Equatable, Sendable { case none, quick, full }

    public static func work(tick n: Int, windowsVisible: Bool, throttledUntil: Date?, now: Date = Date()) -> Work {
        if let t = throttledUntil, t > now { return .none }
        if n % 10 == 0 { return .full }
        if windowsVisible || n % 4 == 0 { return .quick }
        return .none
    }
}
