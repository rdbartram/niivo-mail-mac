import Foundation
import CalendarCore
import MailCore

/// LIFECYCLE: mailto parsing, claims challenges, Retry-After, sync health, notification filters, background cadence.
@MainActor
func runLifecycleTests() {
    section("mailto: (RFC 6068)")
    do {
        let a = MailtoLink.parse("mailto:chris@example.com")
        check(a?.to == ["chris@example.com"] && a?.subject == "" && a?.cc == [], "plain address")
        let b = MailtoLink.parse("mailto:a@x.example,b@y.example?cc=c@z.example&bcc=d@z.example&subject=Hello%20there&body=Line%201%0D%0ALine%202")
        check(b?.to == ["a@x.example", "b@y.example"], "multiple to in the path")
        check(b?.cc == ["c@z.example"] && b?.bcc == ["d@z.example"], "cc + bcc headers")
        check(b?.subject == "Hello there", "percent-encoded subject")
        check(b?.body == "Line 1\nLine 2", "CRLF in the body becomes a newline")
        let c = MailtoLink.parse("MAILTO:?To=a@x.example&to=b@y.example,%20c@y.example&SUBJECT=1+1")
        check(c?.to == ["a@x.example", "b@y.example", "c@y.example"], "empty path, to= headers, case-insensitive names")
        check(c?.subject == "1+1", "+ stays a plus (not a space)")
        let d = MailtoLink.parse("mailto:%22not%40me%22@example.org")
        check(d?.to == ["\"not@me\"@example.org"], "encoded quoted local part (RFC 6068 example)")
        let e = MailtoLink.parse("mailto:list@example.org?In-Reply-To=%3C3469A91.D10AF4C@example.com%3E&attach=/etc/passwd&subject=a%0D%0ABcc:%20evil@x.example")
        check(e?.to == ["list@example.org"] && e?.bcc == [] && e?.subject == "a  Bcc: evil@x.example", "unknown headers ignored; subject newlines can't inject")
        let f = MailtoLink.parse("mailto:a%2Cb@x.example?cc=Sam%20Rivera%20%3Csam@x.example%3E")
        check(f?.to == ["a,b@x.example"], "encoded comma stays inside the address (split before decode)")
        check(f?.cc == ["sam@x.example"], "Name <addr> tolerated")
        let g = MailtoLink.parse("mailto:a@x.example?subject=100%&body=%E2%9C%93%20done")
        check(g?.subject == "100%" && g?.body == "✓ done", "stray % kept; UTF-8 decoded")
        check(MailtoLink.parse("https://example.com") == nil && MailtoLink.parse("mailto:")?.isEmpty == true, "non-mailto rejected; bare mailto: → empty composer")
        let h = MailtoLink.parse("mailto:a@x.example,A@X.example,not-an-address?subject=x&subject=y")
        check(h?.to == ["a@x.example"] && h?.subject == "x", "dedupe (case-insensitive), junk dropped, first subject wins")
    }

    section("CAE claims challenge")
    do {
        let b64 = "eyJhY2Nlc3NfdG9rZW4iOnsiYWNycyI6eyJlc3NlbnRpYWwiOnRydWUsInZhbHVlIjoiY3AxIn19fQ=="
        let learn = #"Bearer realm="", authorization_uri="https://login.microsoftonline.com/common/oauth2/authorize", error="insufficient_claims", claims="\#(b64)""#
        check(ClaimsChallenge.claims(fromWWWAuthenticate: learn) == #"{"access_token":{"acrs":{"essential":true,"value":"cp1"}}}"#,
              "Learn example decodes to the claims JSON")
        let unpadded = learn.replacingOccurrences(of: "==\"", with: "\"")
        check(ClaimsChallenge.claims(fromWWWAuthenticate: unpadded) != nil, "base64 without padding")
        check(ClaimsChallenge.claims(fromWWWAuthenticate: #"Bearer error="invalid_token", claims="\#(b64)""#) == nil, "not insufficient_claims → nil")
        check(ClaimsChallenge.claims(fromWWWAuthenticate: #"Bearer realm="", error="insufficient_claims""#) == nil, "no claims → nil")
        check(ClaimsChallenge.claims(fromWWWAuthenticate: nil as String?) == nil, "no header → nil")
        // value(forHTTPHeaderField:) comma-joins repeated headers: error and claims must come from the same challenge.
        let joined = #"Bearer realm="", error="insufficient_claims", claims="\#(b64)", PoP realm="", error="invalid_token""#
        check(ClaimsChallenge.claims(fromWWWAuthenticate: joined) != nil, "joined challenges: a later scheme doesn't overwrite error")
        let wrongPair = #"Bearer error="invalid_token", Bearer claims="\#(b64)""#
        check(ClaimsChallenge.claims(fromWWWAuthenticate: wrongPair) == nil, "error and claims from different challenges don't pair")
        check(ClaimsChallenge.claims(fromWWWAuthenticate: #"Bearer error="insufficient_claims", claims="bm90IGpzb24=""#) == nil,
              "claims that aren't a JSON object → nil")
    }

    section("Retry-After")
    do {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        check(RetryAfter.seconds("120", now: now, fallback: 2) == 120, "delta-seconds")
        check(RetryAfter.seconds(nil, now: now, fallback: 4) == 4 && RetryAfter.seconds("soon", now: now, fallback: 8) == 8, "missing / junk → fallback")
        check(RetryAfter.seconds("-5", now: now, fallback: 1) == 0 && RetryAfter.seconds("99999", now: now, fallback: 1) == 3600, "clamped to 0…1 h")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = f.string(from: now.addingTimeInterval(90))
        check(abs(RetryAfter.seconds(date, now: now, fallback: 1) - 90) < 1, "HTTP-date (\(date))")
        check(RetryAfter.seconds(f.string(from: now.addingTimeInterval(-60)), now: now, fallback: 1) == 0, "HTTP-date in the past → 0")
        let m = ThrottleMonitor()
        m.recordUnauthorized(claims: nil)
        m.recordUnauthorized(claims: "{\"x\":1}")
        m.recordUnauthorized(claims: nil)
        let a = m.drainAuth()
        check(a.seen && a.claims == "{\"x\":1}" && !m.drainAuth().seen, "401s are kept (claims sticky) until drained")
    }

    section("Sync status summary")
    do {
        let now = Date()
        var s = MailSyncStatus()
        check(s.health(now: now) == .ok(lastSync: nil), "idle → ok")
        s.phase = .syncing; check(s.health(now: now) == .syncing, "syncing")
        s.throttledUntil = ["me": now.addingTimeInterval(60)]
        check(s.health(now: now) == .throttled(until: now.addingTimeInterval(60)), "429 Retry-After in the future → throttled")
        s.throttledUntil = ["me": now.addingTimeInterval(-60)]
        check(s.health(now: now) == .syncing, "expired throttle no longer shown")
        s.phase = .offline; check(s.health(now: now) == .offline, "offline")
        s.authRequired = true; check(s.health(now: now) == .authRequired && s.health(now: now).needsSignIn, "401 → sign-in required (beats offline)")
        s.claimsChallenge = "{}"; check(s.health(now: now) == .claimsChallenge, "claims challenge wins")
        var e = MailSyncStatus(); e.phase = .error("boom"); check(e.health(now: now) == .error("boom"), "error")
    }

    section("Notification filters")
    do {
        struct VIPs: MailVIPLookup { let set: Set<String>; func contains(_ a: String) -> Bool { set.contains(a.lowercased()) } }
        let vip = VIPs(set: ["boss@contoso.example"])
        func m(_ from: String = "someone@x.example", folder: String = "inbox", read: Bool = false, focus: Focus = .focused,
               draft: Bool = false) -> MailMessage {
            MailMessage(id: UUID().uuidString, folderId: folder, conversationId: "c", subject: "s",
                        from: EmailAddress(name: "", address: from), received: Date(), isRead: read, isDraft: draft, focus: focus)
        }
        var s = MailNotificationSettings(enabled: true)
        func ok(_ msg: MailMessage, _ mb: String = "me", inbox: Bool = true, vip v: MailVIPLookup? = vip) -> Bool {
            MailNotificationFilter.shouldNotify(msg, mailbox: mb, isInbox: inbox, settings: s, vip: v)
        }
        check(ok(m()) && !ok(m(read: true)) && !ok(m(draft: true)), "unread Inbox notifies; read / drafts don't")
        check(!ok(m(), "support@x.example"), "mailbox not chosen → no")
        check(!ok(m(folder: "projects"), inbox: false), "other folders off by default")
        s.folderIds = ["projects"]
        check(ok(m(folder: "projects"), inbox: false), "per-folder opt-in")
        s.focusedOnly = true
        check(!ok(m(focus: .other)) && ok(m(focus: .focused)), "Focused only")
        check(ok(m(folder: "projects", focus: .other), inbox: false), "Focused rule doesn't apply to opted-in folders")
        s.vipOnly = true
        check(!ok(m()) && ok(m("Boss@Contoso.example", focus: .other)), "VIPs only (case-insensitive, beats Focused)")
        check(ok(m(), vip: nil), "no VIP list → VIP filter off, never mute-all")
        s.mailboxes = ["me", "support@x.example"]
        s.mailboxRules = ["support@x.example": .all]
        check(ok(m(focus: .other), "support@x.example") && !ok(m(focus: .other)), "per-mailbox rule overrides the global switches")
        check(MailNotificationFilter.rule(for: "me", settings: s) == .vip, "global rule resolution")
        s.enabled = false
        check(!ok(m()), "disabled → nothing")

        let legacy = #"{"enabled":true,"focusedOnly":true,"mailboxes":["me"],"dockBadge":true}"#
        let dec = try? JSONDecoder().decode(MailNotificationSettings.self, from: Data(legacy.utf8))
        check(dec?.enabled == true && dec?.dockBadge == true && dec?.vipOnly == false && dec?.folderIds.isEmpty == true
              && dec?.menuBarCount == false, "settings sealed before the filters still decode")
        var full = MailNotificationSettings(enabled: true, vipOnly: true, folderIds: ["f"], mailboxRules: ["me": .focused], menuBarCount: true)
        full.focusedOnly = true
        let rt = (try? JSONEncoder().encode(full)).flatMap { try? JSONDecoder().decode(MailNotificationSettings.self, from: $0) }
        check(rt == full, "new settings round-trip")
        let locked = MailNotificationText.locked(mailboxTitle: nil)
        check(locked.restricted && locked.title == "New message" && locked.subtitle.isEmpty, "locked → nothing from the message")
    }

    section("Background sync cadence")
    do {
        let now = Date()
        typealias C = BackgroundSyncCadence
        check((1...9).allSatisfy { C.work(tick: $0, windowsVisible: true, throttledUntil: nil, now: now) == .quick }, "window open → Inbox every 30 s")
        check(C.work(tick: 10, windowsVisible: true, throttledUntil: nil, now: now) == .full
              && C.work(tick: 10, windowsVisible: false, throttledUntil: nil, now: now) == .full, "full pass every 5 min either way")
        let closed = (1...9).map { C.work(tick: $0, windowsVisible: false, throttledUntil: nil, now: now) }
        check(closed.filter { $0 == .quick }.count == 2 && closed[3] == .quick && closed[0] == .none, "windows closed → Inbox every 2 min")
        check(C.work(tick: 10, windowsVisible: true, throttledUntil: now.addingTimeInterval(30), now: now) == .none, "nothing while throttled")
        check(C.work(tick: 4, windowsVisible: true, throttledUntil: now.addingTimeInterval(-1), now: now) == .quick, "throttle over → resumes")
    }
}
