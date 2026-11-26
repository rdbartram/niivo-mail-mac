import Foundation
import CalendarCore

// New-mail notifications: settings, text from the content policy (never from the raw message alone) and burst
// summarising. A system notification can show on a locked screen, stay in Notification Centre and be mirrored to
// other devices, so it follows the same rule as the calendar's AlertComposer, only stricter: any label is generic.

/// Persisted in `MailSettings.notifications` (sealed with the rest of the settings).
public struct MailNotificationSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Only Focused Inbox mail.
    public var focusedOnly: Bool
    /// Mailboxes whose Inbox notifies ("me" or a shared / delegated address).
    public var mailboxes: Set<String>
    /// Unread Inbox count on the Dock icon (same mailboxes).
    public var dockBadge: Bool
    // LIFECYCLE-HOOK: filters + menu bar count (AppLifecycle.swift). Optional in the stored form, so older sealed
    // settings still decode.
    /// Only mail from VIPs (the organisation feature's VIP list; ignored while there is none).
    public var vipOnly: Bool
    /// Non-Inbox folders that also notify (folder ids, any mailbox).
    public var folderIds: Set<String>
    /// Per-mailbox override of the global Focused / VIP switches.
    public var mailboxRules: [String: MailNotificationRule]
    /// Unread Inbox count next to the menu bar item (same mailboxes as the Dock badge).
    public var menuBarCount: Bool
    /// TODAY-HOOK: calm notifications (TodayNotificationFilter). ON for anyone who sets notifications up from now on
    /// (no stored settings = notifications were never on); stored settings from before this switch decode as OFF.
    public var needsYouOnly: Bool
    public init(enabled: Bool = false, focusedOnly: Bool = false, mailboxes: Set<String> = ["me"], dockBadge: Bool = false,
                vipOnly: Bool = false, folderIds: Set<String> = [], mailboxRules: [String: MailNotificationRule] = [:],
                menuBarCount: Bool = false, needsYouOnly: Bool = true) {
        self.enabled = enabled; self.focusedOnly = focusedOnly; self.mailboxes = mailboxes; self.dockBadge = dockBadge
        self.vipOnly = vipOnly; self.folderIds = folderIds; self.mailboxRules = mailboxRules; self.menuBarCount = menuBarCount
        self.needsYouOnly = needsYouOnly
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, focusedOnly, mailboxes, dockBadge, vipOnly, folderIds, mailboxRules, menuBarCount, needsYouOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        focusedOnly = try c.decodeIfPresent(Bool.self, forKey: .focusedOnly) ?? false
        mailboxes = try c.decodeIfPresent(Set<String>.self, forKey: .mailboxes) ?? ["me"]
        dockBadge = try c.decodeIfPresent(Bool.self, forKey: .dockBadge) ?? false
        vipOnly = try c.decodeIfPresent(Bool.self, forKey: .vipOnly) ?? false
        folderIds = try c.decodeIfPresent(Set<String>.self, forKey: .folderIds) ?? []
        mailboxRules = (try? c.decodeIfPresent([String: MailNotificationRule].self, forKey: .mailboxRules)) ?? [:]
        menuBarCount = try c.decodeIfPresent(Bool.self, forKey: .menuBarCount) ?? false
        needsYouOnly = try c.decodeIfPresent(Bool.self, forKey: .needsYouOnly) ?? false   // TODAY-HOOK: existing users: off
    }
}

public enum MailNotificationText {
    public struct Text: Equatable, Sendable {
        public var title: String
        public var subtitle: String
        public var body: String
        public var restricted: Bool
    }

    public static let confidentialTitle = "New confidential message"
    public static let previewLimit = 120

    /// Labelled (any label, known or not), private, encrypted or capture-protected → generic text.
    public static func isRestricted(_ m: MailMessage, policy p: ContentPolicy) -> Bool {
        if m.isPrivate || p.redactDetails || p.bodyIsProtected || p.preventScreenCapture { return true }
        if let l = m.labelId, !l.isEmpty { return true }
        if case .unlabeled = p.labelState { return false }
        return true
    }

    /// - mailboxTitle: shown for shared / delegated mailboxes ("In Contoso Support"); nil for your own.
    /// - confirmed: label + private flag were re-read from the full message. Delta headers get them from a best-effort
    ///   `$batch`, so an unconfirmed header could be a labelled message without its label: generic text then.
    public static func compose(_ m: MailMessage, policy p: ContentPolicy, mailboxTitle: String?, confirmed: Bool) -> Text {
        let place = mailboxTitle.map { "In \($0)" }
        if !confirmed || isRestricted(m, policy: p) {
            return Text(title: confidentialTitle, subtitle: "",
                        body: place ?? "Open niivo mail to read it", restricted: true)
        }
        let sender = m.from.map { $0.display.isEmpty ? $0.address : $0.display } ?? "New message"
        let subject = m.subject.isEmpty ? "(no subject)" : m.subject
        var body = ""
        if p.allowOfflineDetails, let pv = m.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !pv.isEmpty {
            let flat = pv.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            body = flat.count > previewLimit ? String(flat.prefix(previewLimit - 1)) + "…" : flat
        }
        if let place { body = body.isEmpty ? place : "\(place) · \(body)" }
        return Text(title: sender, subtitle: subject, body: body, restricted: false)
    }

    /// LIFECYCLE-HOOK: the app is locked. Nothing from the message, whatever its label (the lock exists to hide
    /// content); only the mailbox it arrived in.
    public static func locked(mailboxTitle: String?) -> Text {
        Text(title: "New message", subtitle: "", body: mailboxTitle.map { "In \($0)" } ?? "Unlock niivo mail to read it",
             restricted: true)
    }

    /// Burst summary: a count only, never a sender or subject.
    public static func summary(count: Int, mailboxTitles: [String]) -> Text {
        let titles = Array(Set(mailboxTitles)).sorted()
        let body: String
        switch titles.count {
        case 0: body = "Inbox"
        case 1: body = "Inbox · \(titles[0])"
        default: body = "Inbox · \(titles.count) mailboxes"
        }
        return Text(title: "\(count) new message\(count == 1 ? "" : "s")", subtitle: "", body: body, restricted: true)
    }
}

/// Rate limit: at most `maxSingles` individual notifications per `window`; a batch that doesn't fit becomes one summary.
public enum MailNotificationPlanner {
    public enum Plan: Equatable, Sendable {
        case none
        case singles(Int)
        case summary(Int)
    }

    public static let maxSingles = 3
    public static let window: TimeInterval = 60

    /// - recent: when the last individual notifications were posted.
    public static func plan(newCount: Int, recent: [Date], now: Date,
                            maxSingles: Int = maxSingles, window: TimeInterval = window) -> Plan {
        guard newCount > 0 else { return .none }
        let used = recent.filter { now.timeIntervalSince($0) < window }.count
        let room = max(0, maxSingles - used)
        return newCount <= room ? .singles(newCount) : .summary(newCount)
    }
}

/// Which changed messages are "new mail" worth a notification. Initial sync and backfill never notify: a mailbox's
/// first sighting only seeds its watermark, and only mail newer than the watermark (and recent) counts.
public struct MailArrivalTracker: Sendable {
    public private(set) var watermarks: [String: Date] = [:]
    public private(set) var notified: Set<String> = []
    /// Mail older than this (relative to now) never notifies, e.g. after a cache reset re-delivers everything.
    public var maxAge: TimeInterval = 2 * 3600

    public init() {}

    public mutating func seed(mailbox: String, newest: Date?, now: Date) {
        watermarks[mailbox] = max(newest ?? now, watermarks[mailbox] ?? .distantPast)
    }

    public func isSeeded(_ mailbox: String) -> Bool { watermarks[mailbox] != nil }

    /// Candidates already filtered to Inbox / unread / not draft. Returns the ones to announce and advances watermarks.
    public mutating func arrivals(_ candidates: [(message: MailMessage, mailbox: String)], now: Date) -> [(message: MailMessage, mailbox: String)] {
        var out: [(message: MailMessage, mailbox: String)] = []
        for mb in Set(candidates.map(\.mailbox)) where watermarks[mb] == nil {
            seed(mailbox: mb, newest: candidates.filter { $0.mailbox == mb }.map(\.message.received).max(), now: now)
        }
        var newMarks = watermarks
        for c in candidates {
            guard let w = watermarks[c.mailbox], c.message.received > w,
                  now.timeIntervalSince(c.message.received) < maxAge, !notified.contains(c.message.id) else { continue }
            notified.insert(c.message.id)
            out.append(c)
            newMarks[c.mailbox] = max(newMarks[c.mailbox] ?? w, c.message.received)
        }
        watermarks = newMarks
        if notified.count > 5_000 { notified = Set(out.map(\.message.id)) }
        return out
    }
}
