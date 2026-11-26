import Foundation

/// Online-meeting providers we recognise. Only Teams populates Graph's `onlineMeeting.joinUrl`;
/// every other provider's link lives in the location or the body, so we extract it.
public enum MeetingProvider: String, Sendable, CaseIterable {
    case teams, zoom, googleMeet, webex, goTo, chime, whereby, jitsi, skype, other

    public var displayName: String {
        switch self {
        case .teams: "Microsoft Teams"
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .webex: "Webex"
        case .goTo: "GoTo Meeting"
        case .chime: "Amazon Chime"
        case .whereby: "Whereby"
        case .jitsi: "Jitsi Meet"
        case .skype: "Skype"
        case .other: "Online meeting"
        }
    }

    /// Hosts (suffix match) → provider. Order matters only for readability; hosts don't overlap.
    static let hostTable: [(String, MeetingProvider)] = [
        ("teams.microsoft.com", .teams), ("teams.live.com", .teams), ("teams.microsoft.us", .teams),
        ("zoom.us", .zoom), ("zoomgov.com", .zoom),
        ("meet.google.com", .googleMeet),
        ("webex.com", .webex),
        ("gotomeeting.com", .goTo), ("goto.com", .goTo), ("gotomeet.me", .goTo),
        ("chime.aws", .chime),
        ("whereby.com", .whereby),
        ("meet.jit.si", .jitsi), ("8x8.vc", .jitsi),
        ("join.skype.com", .skype),
    ]

    public init(url: URL) {
        let host = (url.host ?? "").lowercased()
        self = Self.hostTable.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1 ?? .other
    }
}

public enum MeetingLink {
    private static let urlPattern = try! NSRegularExpression(pattern: #"https://[^\s"'<>\)\]]+"#, options: [.caseInsensitive])

    /// Best join link for an event: Graph's Teams joinUrl, else a recognised provider link in the location,
    /// else in the body (HTML or text). Unrecognised links are ignored — a random https URL in a body isn't a
    /// meeting. Only the URL is kept; the body itself is never stored by callers for restricted items.
    public static func extract(joinUrl: String?, location: String?, body: String?) -> URL? {
        if let j = joinUrl, let u = URL(string: j) { return u }
        for text in [location, body].compactMap({ $0 }) {
            if let u = firstProviderURL(in: text) { return u }
        }
        return nil
    }

    static func firstProviderURL(in text: String) -> URL? {
        // Outlook/Google bodies are HTML: entity-encoded ampersands break query strings (Zoom pwd=…).
        let t = text.replacingOccurrences(of: "&amp;", with: "&")
        let ns = t as NSString
        for m in urlPattern.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range)
            while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
            guard let u = URL(string: s), MeetingProvider(url: u) != .other, isJoinLink(u) else { continue }
            return u
        }
        return nil
    }

    /// Filters out provider marketing/help links that appear in invite footers ("Learn more", "Download").
    static func isJoinLink(_ u: URL) -> Bool {
        let p = u.path.lowercased()
        switch MeetingProvider(url: u) {
        case .teams: return p.contains("meetup-join") || p.hasPrefix("/meet/") || p.contains("/l/meet")
        case .zoom: return p.hasPrefix("/j/") || p.hasPrefix("/my/") || p.hasPrefix("/w/") || p.hasPrefix("/s/")
        case .googleMeet: return p.count > 4 && !p.hasPrefix("/_")
        case .webex: return p.contains("/meet") || p.contains("j.php") || p.contains("/join")
        case .goTo: return !p.isEmpty && p != "/" && !p.contains("download") && !p.contains("install")
        default: return !p.isEmpty && p != "/"
        }
    }

    /// Native-client URL when the provider has one: Teams (msteams:) and Zoom (zoommtg:). Others: nil → https.
    public static func nativeURL(for url: URL) -> URL? {
        switch MeetingProvider(url: url) {
        case .teams:
            guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            c.scheme = "msteams"; c.host = nil
            return c.url
        case .zoom:
            // https://<sub>.zoom.us/j/<id>?pwd=<pwd> → zoommtg://zoom.us/join?action=join&confno=<id>&pwd=<pwd>
            let parts = url.path.split(separator: "/")
            guard parts.count >= 2, parts[0] == "j" || parts[0] == "w" else { return nil }
            var c = URLComponents(); c.scheme = "zoommtg"; c.host = url.host ?? "zoom.us"; c.path = "/join"
            var q = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(parts[1]))]
            if let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" })?.value {
                q.append(URLQueryItem(name: "pwd", value: pwd))
            }
            c.queryItems = q
            return c.url
        default:
            return nil
        }
    }
}
