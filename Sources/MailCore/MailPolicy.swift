import Foundation
import CalendarCore

// MARK: - Content policy for mail (label-keyed core shared with calendar)

/// Decides what the UI / cache may do with one message. Thin mapping onto
/// `CachedLabelPolicyEngine.policy(labelId:isPrivate:access:)` so mail and calendar enforce identical rules.
public enum MailContentPolicy {
    /// "me" → own mailbox; any other mailbox address is treated as delegated access.
    public static func access(forMailbox mailbox: String) -> CalendarAccess {
        mailbox == "me" ? .own : .delegated
    }

    /// Same usage-rights resolution as calendar items (item licence → label rights → fallback); see
    /// `CachedLabelPolicyEngine.policy(labelId:isPrivate:access:itemId:)`.
    public static func policy(for m: MailMessage, mailbox: String = "me", engine: CachedLabelPolicyEngine) -> ContentPolicy {
        engine.policy(labelId: m.labelId, isPrivate: m.isPrivate, access: access(forMailbox: mailbox), itemId: m.id)
    }

    /// Conservative policy used when no engine is wired: anything labelled is treated as an unknown label (no
    /// copy/export/print, not cacheable); private loses copy/export and isn't cacheable.
    public static func failClosed(for m: MailMessage) -> ContentPolicy {
        var p = ContentPolicy.open
        if let l = m.labelId, !l.isEmpty {
            p.labelState = .unknown(id: l.lowercased())
            p.rights = .unknownLabel; p.rightsSource = .unknownLabel
            p.allowOfflineDetails = false; p.preventScreenCapture = true
        }
        if m.isPrivate { p.allowOfflineDetails = false; p.rights.subtract([.extract, .export]) }
        return p
    }

    /// Persist rule (same as calendar `SyncEngine.sanitizeForCache`): protected/unknown label or redacted private
    /// item → body, preview, recipients and attachment names never land on disk. Label id, flags and dates stay.
    public static func sanitizeForCache(_ m: MailMessage, policy: ContentPolicy) -> MailMessage {
        var m = m
        if !policy.allowOfflineDetails {
            m.body = nil
            m.preview = nil
            m.toRecipients = []
            m.ccRecipients = []
            m.attachments = []
        }
        if policy.redactDetails {
            m.subject = ""
        }
        return m
    }
}

// MARK: - Usage-rights gate for mail actions

/// Reply / Reply all / Forward follow the item's usage rights (REPLY, REPLYALL, FORWARD), as in Outlook: a
/// "Do Not Forward" message grants no FORWARD (https://learn.microsoft.com/purview/ai-m365-copilot-considerations#copilot-honors-existing-protection-with-the-extract-usage-right),
/// and the rights are defined at https://learn.microsoft.com/purview/rights-management-usage-rights#usage-rights-and-descriptions.
/// One decision used by the reader, list menu, triage keys and the composer.
public enum MailActionRights {
    public static let deniedReason = "Not allowed by the sensitivity label"

    /// May the user start a draft of this kind from a message with this policy? `.new` is always allowed.
    public static func allows(_ kind: MailDraft.Kind, policy: ContentPolicy) -> Bool {
        switch kind {
        case .new: true
        case .reply: policy.allowReply
        case .replyAll: policy.allowReplyAll
        case .forward: policy.allowForward
        }
    }

    /// Tooltip: the normal help text, or the label reason when the action is denied.
    public static func help(_ kind: MailDraft.Kind, policy: ContentPolicy, otherwise: String) -> String {
        allows(kind, policy: policy) ? otherwise : deniedReason
    }
}

/// Persist-time policy hook: (message, mailbox) → policy. Injected into `MailStore`.
public typealias MailPersistPolicy = @Sendable (MailMessage, String) -> ContentPolicy

// MARK: - Reply/forward label floor

public enum MailLabelFloor {
    /// A reply/forward may not carry a lower-priority label than the message it answers.
    /// * original unlabelled → draft unchanged
    /// * original label unknown to the policy (can't compare) → inherit the original's label (fail closed)
    /// * draft unlabelled, or draft label unknown → inherit the original's label
    /// * draft label is a group header (a parent with sub-labels, not appliable) → inherit the original's label
    /// * both known and draft rank < original rank → bumped to the original's label
    /// Ranks are `LabelTree.floorRank`: higher = more sensitive, sub-labels compare on their parent's priority
    /// (Microsoft treats sub-labels of one parent as equal for downgrade), so a sibling swap is allowed.
    /// The original's label a reply/forward may inherit. An unknown id is still inherited (fail closed: it may be ours
    /// and the tree not synced) — except a SiteId-less id outside our tree, which stamped with our SiteId would turn
    /// another organisation's label into one of ours (LabelProvenance.swift). Foreign SiteIds never get this far.
    public static func inheritableLabel(_ original: MailMessage?, tree: LabelTree) -> String? {
        guard let id = original?.labelId?.lowercased(), !id.isEmpty else { return nil }
        if original?.labelOrigin == .noSite, tree.floorRank(id) == nil { return nil }
        return id
    }

    public static func enforce(_ draft: MailDraft, original: MailMessage?, engine: CachedLabelPolicyEngine) -> MailDraft {
        guard draft.kind != .new, let orig = inheritableLabel(original, tree: engine.labelTree()) else { return draft }
        var d = draft
        let tree = engine.labelTree()
        guard let origRank = tree.floorRank(orig) else { d.labelId = orig; return d }
        guard let mine = d.labelId?.lowercased(), !mine.isEmpty, tree.isSelectable(mine),
              let myRank = tree.floorRank(mine) else { d.labelId = orig; return d }
        if myRank < origRank { d.labelId = orig }
        return d
    }
}

// MARK: - HTML sanitiser

/// Regex-based sanitiser for rendering mail HTML in a JavaScript-off web view. Defence in depth, not a parser:
/// the renderer must ALSO run with JS disabled and a content-blocking rule list.
/// Known gaps (documented): CSS `url(...)` in inline styles / <style> blocks is not rewritten.
public enum HTMLSanitizer {
    public static let blockedImagePlaceholder = "data:image/gif;base64,R0lGODlhAQABAAAAACw="

    public static func sanitize(_ html: String, allowRemote: Bool = false) -> (html: String, blockedRemoteCount: Int) {
        var s = html
        // Whole elements whose content must go.
        for tag in ["script", "iframe", "object", "embed", "frameset", "frame", "applet", "noscript"] {
            s = replace(s, "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", "")
            s = replace(s, "<\(tag)\\b[^>]*/?>", "")       // unclosed / self-closing leftovers
            s = replace(s, "</\(tag)\\s*>", "")
        }
        // Remote stylesheets / refresh redirects / base-href tricks.
        s = replace(s, "<(link|meta|base)\\b[^>]*>", "")
        // Event handler attributes (onload=, onclick=, ...).
        s = replace(s, "\\s+on[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", "")
        // javascript:/vbscript: URLs in any attribute value.
        s = replace(s, "(\\s[a-zA-Z-]+)\\s*=\\s*([\"']?)\\s*(javascript|vbscript):[^\"'>]*\\2", "$1=\"#\"")
        guard !allowRemote else { return (s, 0) }

        // Remote images: rewrite src/srcset on <img> to a placeholder, keep the URL out of the DOM.
        var count = 0
        let imgRe = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
        let srcRe = try! NSRegularExpression(pattern: "\\s(src|srcset)\\s*=\\s*([\"']?)\\s*https?://[^\"'\\s>]*\\2", options: [.caseInsensitive])
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in imgRe.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let tag = ns.substring(with: m.range)
            let tns = tag as NSString
            let hits = srcRe.matches(in: tag, range: NSRange(location: 0, length: tns.length))
            if hits.isEmpty { out += tag } else {
                count += 1
                var rewritten = srcRe.stringByReplacingMatches(in: tag, range: NSRange(location: 0, length: tns.length),
                                                               withTemplate: "")
                rewritten = rewritten.replacingOccurrences(of: "<img", with: "<img src=\"\(blockedImagePlaceholder)\" data-remote-blocked=\"1\"",
                                                           options: [.caseInsensitive, .anchored])
                out += rewritten
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return (out, count)
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}

// MARK: - AI access policy (MCP egress gate)

/// What an AI client (the MCP server) may see of a message. MCP is an egress path around Purview, so this
/// fails closed: anything we can't positively classify as low-sensitivity is reduced or hidden.
public struct AIAccessPolicy: Sendable {
    public enum Level: String, Sendable, Hashable {
        /// Everything incl. body (body must still be wrapped as untrusted content by the caller).
        case full
        /// Subject/from/date/flags only — no body, preview, recipients or attachment names.
        case metadataOnly
        /// Only "a restricted message exists".
        case hidden
    }

    public static let protectedSubject = "Protected message"

    public let engine: CachedLabelPolicyEngine
    /// Label priority at or above which only metadata is exposed. Default 2 = Confidential and up (fixture scale).
    public var aiMaxPriority: Int

    public init(engine: CachedLabelPolicyEngine, aiMaxPriority: Int = 2) {
        self.engine = engine; self.aiMaxPriority = aiMaxPriority
    }

    /// Order: private / unknown → hidden. Then Copilot's usage-rights rule: encrypted content needs VIEW + EXTRACT
    /// (`ContentPolicy.aiMayReadContent`), otherwise metadata only
    /// (https://learn.microsoft.com/copilot/plan/architecture-data-protection-auditing#how-microsoft-copilot-works-with-sensitivity-labels-and-encryption).
    /// Then the admin AI setting `aiMaxPriority` applies to every label; it is not a usage right and can only restrict.
    public func level(for m: MailMessage, mailbox: String = "me") -> Level {
        // Private is checked here directly: the engine only restricts private items on non-own mailboxes.
        if m.isPrivate { return .hidden }
        let p = MailContentPolicy.policy(for: m, mailbox: mailbox, engine: engine)
        switch p.labelState {
        case .unknown: return .hidden
        case .unlabeled:
            if p.redactDetails { return .hidden }
            return p.aiMayReadContent ? .full : .metadataOnly
        case .labeled(let l):
            if p.redactDetails { return .hidden }
            if !p.aiMayReadContent { return .metadataOnly }
            if l.priority >= aiMaxPriority { return .metadataOnly }
            return .full
        }
    }

    /// nil → hidden (caller may say "a restricted message exists" without any detail).
    public func redactForAI(_ m: MailMessage, mailbox: String = "me") -> MailMessage? {
        switch level(for: m, mailbox: mailbox) {
        case .hidden: return nil
        case .full: return m
        case .metadataOnly:
            var r = m
            r.body = nil; r.preview = nil; r.toRecipients = []; r.ccRecipients = []; r.attachments = []
            r.webLink = nil
            // Encrypted and no EXTRACT for this user: even the subject is withheld (Copilot returns a link only).
            if !MailContentPolicy.policy(for: m, mailbox: mailbox, engine: engine).aiMayReadContent {
                r.subject = Self.protectedSubject
            }
            return r
        }
    }
}

// MARK: - Split inbox

public enum InboxBucket: String, Sendable, CaseIterable, Codable {
    case important, other, newsletters, notifications
}

/// Pure heuristic classifier (Graph doesn't expose List-Unsubscribe in the default $select).
public enum SplitInbox {
    /// SaaS-ish senders whose automated mail is "notifications" rather than newsletters.
    public static let notificationDomains: Set<String> = [
        "devops.fabrikam.example", "tickets.example", "status.example", "ci.contoso.example",
    ]
    static let notificationLocals: Set<String> = ["notifications", "notification", "no-reply", "alerts", "alert"]
    static let newsletterLocals: Set<String> = ["noreply", "newsletter", "newsletters", "news", "digest", "marketing", "updates"]
    static let newsletterCategories: Set<String> = ["newsletter", "newsletters", "marketing"]

    public static func bucket(for m: MailMessage) -> InboxBucket {
        let addr = (m.from?.address ?? "").lowercased()
        let parts = addr.split(separator: "@", maxSplits: 1).map(String.init)
        let local = parts.first ?? "", domain = parts.count > 1 ? parts[1] : ""
        let knownSaaS = notificationDomains.contains(domain) || notificationDomains.contains { domain.hasSuffix("." + $0) }

        if notificationLocals.contains(local) && (knownSaaS || local.hasPrefix("notification")) { return .notifications }
        if knownSaaS && (local == "noreply" || local == "no-reply") { return .notifications }
        if newsletterLocals.contains(local) || local == "no-reply"
            || m.categories.contains(where: { newsletterCategories.contains($0.lowercased()) }) {
            return .newsletters
        }
        return m.focus == .focused ? .important : .other
    }

    public static func split(_ messages: [MailMessage]) -> [InboxBucket: [MailMessage]] {
        Dictionary(grouping: messages, by: bucket(for:))
    }
}
