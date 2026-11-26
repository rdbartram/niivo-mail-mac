import Foundation
import CryptoKit
import CalendarCore

// TRIAGE2: conversation state ("who acts next"), docs/INBOX-INTELLIGENCE-PLAN.md §3–§4, Phase 1.
//
// L0 `ConversationFacts` (metadata + lexical cue BITS, never text) → L1 `TriageRules.decide` (pure, total: every
// conversation gets a state) → optional L3 verdict per thread (`AIAssistant.triageThreads`). No scorer yet (Phase 3):
// undecided cases show a low-confidence state (a dot, no badge).

public enum ConversationState: String, Codable, Sendable, CaseIterable, Hashable {
    case needsReply, waiting, fyi, done
    public var title: String {
        switch self { case .needsReply: "Reply needed"; case .waiting: "Waiting"; case .fyi: "FYI"; case .done: "Done" }
    }
    /// The legacy tag the old UI paths use.
    public var legacyTag: AITriageTag {
        switch self { case .needsReply: .replyNeeded; case .waiting: .waitingOnThem; case .fyi, .done: .fyi }
    }
}

/// Channel axis (plan §3.1): who sends this kind of mail. Bulk is a channel, not an action state.
public enum TriageChannel: String, Codable, Sendable, CaseIterable, Hashable { case person, bulk, notification, calendar, automated }
public enum TriageRole: String, Codable, Sendable, Hashable { case to, cc, bccOrList, unknown }
public enum TriageConfidence: Int, Codable, Sendable, Hashable, Comparable {
    case low = 0, medium = 1, high = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}
public enum TriageSource: String, Codable, Sendable, Hashable { case rule, llm, user }
public enum TriageMeeting: String, Codable, Sendable, Hashable { case requestUnanswered, requestAnswered, response, cancelled }
public enum SenderOverrideKind: String, Codable, Sendable, Hashable, CaseIterable { case neverNeedsReply, bulk, person }

/// Content-free reason codes (logs, hover text, scoring).
public enum TriageReason: String, Codable, Sendable, CaseIterable, Hashable {
    case channel, rsvp, meetingResponse, meetingDone
    case mineAsked, mineUnanswered, mineClosed, mineFYI, mineRecent, mineNoDirect
    case bccOrList, ccBroadcast, ccAddressed, ccPlain
    case directAsk, broadcastAsk, closer, directNoCue, inboundUndecided
    case restrictedInbound, restrictedMine, archived
    case override, senderOverride, prior, llm
}

// MARK: - Lexical cues (bits only; scanned only where the on-device exposure is `content`)

public struct TriageCues: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let question = TriageCues(rawValue: 1 << 0)
    public static let request = TriageCues(rawValue: 1 << 1)
    public static let deadline = TriageCues(rawValue: 1 << 2)
    public static let closer = TriageCues(rawValue: 1 << 3)
    public static let fyiMarker = TriageCues(rawValue: 1 << 4)
    public static let addressedByName = TriageCues(rawValue: 1 << 5)
    public static let short = TriageCues(rawValue: 1 << 6)
    public var asks: Bool { !intersection([.question, .request]).isEmpty }
}

public enum TriageCueScanner {
    /// Requests, DE/EN/FR/IT (lower-case, matched at a word start).
    static let requests = [
        "bitte", "könnten sie", "können sie", "könntest du", "kannst du", "würden sie", "würdest du", "ich bitte",
        "um rückmeldung", "ihre rückmeldung", "deine rückmeldung", "freigabe", "wären sie so",
        "please", "could you", "can you", "would you", "let me know", "kindly", "need your", "your approval", "asap",
        "merci de", "pourriez-vous", "pouvez-vous", "pourrais-tu", "peux-tu", "veuillez", "s'il vous plaît", "svp",
        "per favore", "potrebbe", "potresti", "puoi", "la prego", "cortesemente", "gentilmente", "mi faccia sapere",
    ]
    static let deadlines = [
        "bis morgen", "spätestens", "frist", "bis ende", "deadline", "by tomorrow", "by friday", "by monday",
        "no later than", "au plus tard", "avant le", "entro", "scadenza",
    ]
    static let closers = [
        "danke", "vielen dank", "besten dank", "merci", "grazie", "thanks", "thank you", "perfekt", "alles klar",
        "parfait", "perfetto", "noted", "erledigt", "d'accord", "va bene", "bien reçu", "ricevuto",
    ]
    static let fyi = [
        "fyi", "zur info", "zur kenntnis", "zu ihrer information", "zu deiner information", "nur zur info",
        "pour info", "pour information", "pour votre information", "pour ton information",
        "per conoscenza", "per info", "per vostra informazione", "per tua informazione", "just so you know", "for your information",
    ]

    /// `raw` is a body or preview (HTML allowed). Quoted history and signatures are stripped first (zoning).
    public static func scan(_ raw: String, isHTML: Bool, firstName: String?, sentAt: Date? = nil) -> TriageCues {
        var text = AIUntrustedText.body(raw, isHTML: isHTML)
        text = AIUntrustedText.stripQuotedAndSignature(text)
        let l = " " + text.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        var c: TriageCues = []
        if text.contains("?") { c.insert(.question) }
        func has(_ words: [String]) -> Bool {
            words.contains { w in
                var from = l.startIndex
                while let r = l.range(of: w, range: from..<l.endIndex) {
                    if !l[l.index(before: r.lowerBound)].isLetter { return true }
                    from = r.upperBound
                }
                return false
            }
        }
        if has(requests) { c.insert(.request) }
        if has(deadlines) { c.insert(.deadline) }
        else if let sentAt, let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = text as NSString
            if d.matches(in: text, range: NSRange(location: 0, length: min(ns.length, 2_000)))
                .contains(where: { ($0.date ?? .distantPast) > sentAt.addingTimeInterval(3_600) }) {
                c.insert(.deadline)
            }
        }
        if has(fyi) { c.insert(.fyiMarker) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 200 { c.insert(.short) }
        if trimmed.count < 140, has(closers), !c.asks { c.insert(.closer) }
        if let n = firstName?.lowercased(), n.count >= 2 {
            let head = trimmed.split(separator: "\n").prefix(2).joined(separator: " ").lowercased()
            if head.range(of: "\\b" + NSRegularExpression.escapedPattern(for: n) + "\\b", options: .regularExpression) != nil {
                c.insert(.addressedByName)
            }
        }
        return c
    }
}

// MARK: - Channel

public enum ChannelClassifier {
    static let autoReplyPrefixes = [
        "automatische antwort", "abwesenheitsnotiz", "abwesend", "out of office", "automatic reply", "auto-reply", "autoreply",
        "réponse automatique", "risposta automatica", "fuori sede", "undeliverable", "unzustellbar",
        "delivery status notification", "non remis", "non recapitabile", "read:", "gelesen:", "lu :", "lu:", "letto:",
    ]
    static let automatedLocals: Set<String> = ["mailer-daemon", "postmaster", "bounce", "bounces"]
    static let espMarkers = ["mailchimp", "mcsv.net", "rsgsv.net", "sendgrid", "mailgun", "amazonses", "mandrillapp",
                             "sparkpostmail", "hubspot", "exacttarget", "mktomail", "createsend", "cmail", "sendinblue",
                             "brevo", "mailjet", "constantcontact", "klaviyo"]

    /// Keeps `SplitInbox.bucket` for the tabs and adds auto-reply subjects, `sender ≠ from` via an ESP, bounces and
    /// sender overrides (R11).
    public static func classify(_ m: MailMessage, senderOverride: SenderOverrideKind? = nil, meeting: TriageMeeting? = nil) -> TriageChannel {
        switch senderOverride { case .bulk?: return .bulk; case .person?: return .person; default: break }
        if meeting != nil { return .calendar }
        let subj = m.subject.lowercased().trimmingCharacters(in: .whitespaces)
        if autoReplyPrefixes.contains(where: { subj.hasPrefix($0) }) { return .automated }
        let local = (m.from?.address ?? "").lowercased().split(separator: "@").first.map(String.init) ?? ""
        if automatedLocals.contains(local) { return .automated }
        if let s = m.sender?.address.lowercased(), let f = m.from?.address.lowercased(), s != f,
           espMarkers.contains(where: { s.contains($0) }) { return .bulk }
        switch SplitInbox.bucket(for: m) {
        case .notifications: return .notification
        case .newsletters: return .bulk
        default: return .person
        }
    }
}

// MARK: - L0 facts

public struct ConversationFacts: Sendable, Hashable {
    public var conversationId: String
    public var account: String
    public var lastInboundAt: Date?
    public var lastOutboundAt: Date?
    public var lastFromMe: Bool
    public var repliedAfterLastInbound: Bool
    public var iStarted: Bool
    /// The user's place on the last inbound message. `.unknown` when recipients were withheld (protected labels).
    public var myRole: TriageRole
    /// Other recipients on the last inbound (nil = unknown).
    public var otherRecipients: Int?
    /// To-recipients other than me on my last outbound (nil = unknown). Owner decision 1: N-day waiting is To only.
    public var myDirectRecipients: Int?
    public var inboundCount: Int
    public var outboundCount: Int
    public var senderInternal: Bool
    /// Lower-cased address of the last inbound sender (memory only; persisted only as an HMAC).
    public var senderAddress: String?
    public var channel: TriageChannel
    public var meeting: TriageMeeting?
    public var flagged: Bool
    public var flagDue: Date?
    public var snoozedUntil: Date?
    public var hasInboxMember: Bool
    /// Cue bits of the last inbound / my last outbound. nil = not allowed (gate) or no text.
    public var inboundCues: TriageCues?
    public var outboundCues: TriageCues?
    /// My last outbound is a forward (FW/WG/TR/I prefix).
    public var outboundIsForward: Bool
    /// On-device exposure of the newest message: `.excluded` → direction-only rules (plan §4.5).
    public var exposure: AIExposure
    public var latestMessageId: String
    public var latest: Date
    /// Changes only with an inbound or outbound event (not read, flag or move): overrides stick until it changes.
    public var eventSignature: UInt64
    /// L3 cache key: event signature + inbox membership + exposure.
    public var signature: UInt64

    public var restricted: Bool { exposure == .excluded }

    /// TRIAGE3: true when no counted message is newer than `s` (the snapshot is still the newest). By date, not id:
    /// Graph ids change when a message moves (archive), the received time doesn't.
    public func isCurrent(_ s: TriageSnapshot) -> Bool { latest <= s.at.addingTimeInterval(0.001) }
}

/// TRIAGE3: "as of the newest message the user saw". `tag` is a keyed hash of that message's id (never the raw id);
/// `at` its received time. Training answers and overrides are pinned to one.
public struct TriageSnapshot: Codable, Sendable, Hashable {
    public var tag: Data
    public var at: Date
    public init(tag: Data, at: Date) { self.tag = tag; self.at = at }
}

/// Everything the builder needs from the app or tool, as closures (pure and testable).
public struct TriageInputs: Sendable {
    public var account: String
    public var isMine: @Sendable (MailMessage) -> Bool
    public var myAddresses: Set<String>
    public var internalDomains: Set<String>
    public var firstName: String?
    public var folderRole: @Sendable (String) -> WellKnownFolder?
    /// On-device exposure of a message (the label gate). Cues are scanned only for `.content`.
    public var exposure: @Sendable (MailMessage) -> AIExposure
    /// Body (cached) or preview for cue scanning: (text, isHTML).
    public var text: @Sendable (MailMessage) -> (String, Bool)?
    public var meeting: @Sendable (MailMessage) -> TriageMeeting?
    public var senderOverride: @Sendable (String) -> SenderOverrideKind?

    public init(account: String, isMine: @escaping @Sendable (MailMessage) -> Bool, myAddresses: Set<String>,
                internalDomains: Set<String> = [], firstName: String? = nil,
                folderRole: @escaping @Sendable (String) -> WellKnownFolder? = { _ in nil },
                exposure: @escaping @Sendable (MailMessage) -> AIExposure = { _ in .content },
                text: @escaping @Sendable (MailMessage) -> (String, Bool)? = { m in m.body.map { ($0, m.bodyIsHTML) } ?? m.preview.map { ($0, false) } },
                meeting: @escaping @Sendable (MailMessage) -> TriageMeeting? = { _ in nil },
                senderOverride: @escaping @Sendable (String) -> SenderOverrideKind? = { _ in nil }) {
        self.account = account; self.isMine = isMine; self.myAddresses = Set(myAddresses.map { $0.lowercased() })
        self.internalDomains = Set(internalDomains.map { $0.lowercased() }); self.firstName = firstName
        self.folderRole = folderRole; self.exposure = exposure; self.text = text; self.meeting = meeting
        self.senderOverride = senderOverride
    }
}

public enum ConversationFactsBuilder {
    static let ignoredFolders: Set<WellKnownFolder> = [.drafts, .deleteditems, .junkemail, .outbox]
    nonisolated(unsafe) static let forwardPrefix = try! NSRegularExpression(pattern: "^\\s*(fw|fwd|wg|tr|i)\\s*:", options: .caseInsensitive)

    static func fnv(_ parts: [String]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for p in parts {
            for b in p.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
            h ^= 0xff; h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    /// TRIAGE3-HOOK: the messages that count (no drafts, deleted, junk or outbox), oldest first. The trainer shows
    /// exactly these, so its "newest" is the engine's.
    public static func counted(_ messages: [MailMessage], folderRole: (String) -> WellKnownFolder?) -> [MailMessage] {
        messages.filter { m in
            !m.isDraft && !(folderRole(m.folderId).map { ignoredFolders.contains($0) } ?? false)
        }.sorted { ($0.received, $0.id) < ($1.received, $1.id) }
    }

    /// TRIAGE3: the counted messages up to and including the snapshot message (found by `isSnapshot`; if it's gone or
    /// was moved to a new id, by received time ≤ the snapshot's).
    public static func asOf(_ counted: [MailMessage], at: Date, isSnapshot: (MailMessage) -> Bool) -> [MailMessage] {
        if let i = counted.lastIndex(where: isSnapshot) { return Array(counted[...i]) }
        return counted.filter { $0.received <= at.addingTimeInterval(0.001) }
    }

    /// Changes only with an inbound or outbound event (count + last three events), over counted messages.
    static func eventSignature(_ ms: [MailMessage], isMine: (MailMessage) -> Bool) -> UInt64 {
        fnv(["\(ms.count)"] + ms.map { "\(Int($0.received.timeIntervalSince1970))\(isMine($0) ? "o" : "i")" }.suffix(3))
    }

    /// TRIAGE3 migration of a pre-snapshot answer: the counted message whose prefix has `sig` (the newest message when
    /// the answer was saved), or nil when no prefix matches (then it can't be pinned).
    public static func message(withEventSignature sig: UInt64, in counted: [MailMessage], inputs: TriageInputs) -> MailMessage? {
        for k in stride(from: counted.count, through: 1, by: -1)
        where eventSignature(Array(counted.prefix(k)), isMine: inputs.isMine) == sig { return counted[k - 1] }
        return nil
    }

    /// TRIAGE3: facts as of a snapshot: only the messages up to it count. `inboxAtSnapshot` (stored with the answer)
    /// replaces today's inbox membership, so archiving after replying doesn't turn the old state into "archived".
    /// Read / flag / snooze and meeting state are today's (documented limit); so is the label gate.
    public static func build(conversationId: String, messages: [MailMessage], inputs: TriageInputs, asOf s: TriageSnapshot,
                             isSnapshot: (MailMessage) -> Bool, inboxAtSnapshot: Bool?) -> ConversationFacts? {
        let ms = asOf(counted(messages, folderRole: inputs.folderRole), at: s.at, isSnapshot: isSnapshot)
        guard var f = build(conversationId: conversationId, messages: ms, inputs: inputs) else { return nil }
        if let inboxAtSnapshot { f.hasInboxMember = inboxAtSnapshot }
        return f
    }

    /// nil when nothing in the conversation counts (only drafts, deleted or junk).
    public static func build(conversationId: String, messages: [MailMessage], inputs: TriageInputs) -> ConversationFacts? {
        let ms = counted(messages, folderRole: inputs.folderRole)
        guard let newest = ms.last else { return nil }
        let mine = ms.map(inputs.isMine)
        let lastIn = ms.indices.last { !mine[$0] }, lastOut = ms.indices.last { mine[$0] }
        let me = inputs.myAddresses
        func isMe(_ a: EmailAddress) -> Bool { me.contains(a.address.lowercased()) }

        var role: TriageRole = .unknown, others: Int?
        var senderInternal = false, inCues: TriageCues?, sender: String?, channel: TriageChannel = .person
        var meeting: TriageMeeting?
        if let i = lastIn {
            let m = ms[i]
            let exp = inputs.exposure(m)
            let recipients = m.toRecipients + m.ccRecipients
            if recipients.isEmpty {
                role = exp == .content ? .bccOrList : .unknown
                others = exp == .content ? 0 : nil
            } else {
                role = m.toRecipients.contains(where: isMe) ? .to : m.ccRecipients.contains(where: isMe) ? .cc : .bccOrList
                others = recipients.filter { !isMe($0) }.count
            }
            sender = m.from?.address.lowercased()
            let d = sender?.split(separator: "@").last.map(String.init) ?? ""
            senderInternal = !d.isEmpty && inputs.internalDomains.contains { d == $0 || d.hasSuffix("." + $0) }
            if exp == .content, let (t, html) = inputs.text(m) {
                inCues = TriageCueScanner.scan(t, isHTML: html, firstName: inputs.firstName, sentAt: m.received)
            }
            meeting = inputs.meeting(m)
            channel = ChannelClassifier.classify(m, senderOverride: sender.flatMap(inputs.senderOverride), meeting: meeting)
        }
        var outCues: TriageCues?, direct: Int?, forward = false
        if let o = lastOut {
            let m = ms[o]
            forward = forwardPrefix.firstMatch(in: m.subject, range: NSRange(location: 0, length: (m.subject as NSString).length)) != nil
            let exp = inputs.exposure(m)
            if m.toRecipients.isEmpty && m.ccRecipients.isEmpty { direct = exp == .content ? 0 : nil }
            else { direct = m.toRecipients.filter { !isMe($0) }.count }
            if exp == .content, let (t, html) = inputs.text(m) {
                outCues = TriageCueScanner.scan(t, isHTML: html, firstName: nil, sentAt: m.received)
            }
        }
        let inbox = ms.contains { inputs.folderRole($0.folderId) == .inbox }
        let lastFromMe = mine.last ?? false
        let exp = inputs.exposure(newest)
        let eventSig = eventSignature(ms, isMine: inputs.isMine)
        let sig = fnv(["\(eventSig)", inbox ? "inbox" : "-", exp.rawValue])
        return ConversationFacts(
            conversationId: conversationId, account: inputs.account,
            lastInboundAt: lastIn.map { ms[$0].received }, lastOutboundAt: lastOut.map { ms[$0].received },
            lastFromMe: lastFromMe,
            repliedAfterLastInbound: lastIn.map { i in lastOut.map { $0 > i } ?? false } ?? false,
            iStarted: mine.first ?? false, myRole: role, otherRecipients: others, myDirectRecipients: direct,
            inboundCount: mine.filter { !$0 }.count, outboundCount: mine.filter { $0 }.count,
            senderInternal: senderInternal, senderAddress: sender, channel: channel, meeting: meeting,
            flagged: ms.contains { $0.flag.status == .flagged }, flagDue: ms.compactMap(\.flag.due).max(),
            snoozedUntil: ms.compactMap(\.snoozedUntil).max(), hasInboxMember: inbox,
            inboundCues: inCues, outboundCues: outCues, outboundIsForward: forward, exposure: exp,
            latestMessageId: newest.id, latest: newest.received, eventSignature: eventSig, signature: sig)
    }
}

// MARK: - Decisions, overrides, priors

public struct TriageSettings: Sendable, Hashable, Codable {
    /// Owner decision 1: a sent thread without an answer for N working days (To recipients) is "waiting".
    public var waitingDays: Int
    /// "Received 3 d ago" nudge on needsReply.
    public var nudgeDays: Int
    public init(waitingDays: Int = 3, nudgeDays: Int = 3) { self.waitingDays = waitingDays; self.nudgeDays = nudgeDays }
}

public enum TriageNudge: Codable, Sendable, Hashable {
    case received(days: Int), followUp(days: Int), flagDue
}

public struct TriageDecision: Codable, Sendable, Hashable {
    public var state: ConversationState
    public var confidence: TriageConfidence
    public var source: TriageSource
    public var reason: TriageReason
    public var channel: TriageChannel
    public var since: Date?
    public var snoozed: Bool
    public var nudge: TriageNudge?
    public var ask: String?
    public var why: String?
    /// R1, R2, R5, R6, R10, R11 and every mine-last rule: the LLM can't flip these.
    public var hard: Bool
    /// The newest message is excluded for the on-device tier: direction only, never L3, never text.
    public var restricted: Bool

    public init(state: ConversationState, confidence: TriageConfidence, source: TriageSource = .rule, reason: TriageReason,
                channel: TriageChannel = .person, since: Date? = nil, snoozed: Bool = false, nudge: TriageNudge? = nil,
                ask: String? = nil, why: String? = nil, hard: Bool = false, restricted: Bool = false) {
        self.state = state; self.confidence = confidence; self.source = source; self.reason = reason
        self.channel = channel; self.since = since; self.snoozed = snoozed; self.nudge = nudge; self.ask = ask
        self.why = why; self.hard = hard; self.restricted = restricted
    }

    /// One badge at most (plan §3.1): reply needed or waiting, never for low confidence.
    public var showsBadge: Bool { (state == .needsReply || state == .waiting) && confidence >= .medium }
    /// "Maybe" dot: an action state at low confidence.
    public var isMaybe: Bool { (state == .needsReply || state == .waiting) && confidence == .low }
}

public struct ConversationOverride: Codable, Sendable, Hashable {
    public var state: ConversationState
    public var setAt: Date
    public var eventSignature: UInt64
    /// TRIAGE3: the newest message when it was set. Live only while that's still the newest. nil = saved before
    /// snapshots: then live while the event signature is unchanged (= pinned to the newest message at save time).
    public var snapshot: TriageSnapshot?
    public init(state: ConversationState, setAt: Date, eventSignature: UInt64, snapshot: TriageSnapshot? = nil) {
        self.state = state; self.setAt = setAt; self.eventSignature = eventSignature; self.snapshot = snapshot
    }

    /// TRIAGE3: R10 liveness. A new inbound message or my reply (a newer counted message) expires it.
    public func isLive(for f: ConversationFacts) -> Bool {
        if let snapshot { return f.isCurrent(snapshot) }
        return eventSignature == f.eventSignature
    }
}

/// Per sender (per account): an explicit override plus correction counts (the Beta prior's inputs, Phase 3).
public struct SenderPrior: Codable, Sendable, Hashable {
    public var explicit: SenderOverrideKind?
    public var counts: [String: Int]
    public init(explicit: SenderOverrideKind? = nil, counts: [String: Int] = [:]) { self.explicit = explicit; self.counts = counts }
    public var total: Int { counts.values.reduce(0, +) }
    /// A clear majority of ≥ 2 corrections, else nil.
    public var majority: ConversationState? {
        guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= 2,
              Double(best.value) >= Double(total) * 2 / 3 else { return nil }
        return ConversationState(rawValue: best.key)
    }
}

public enum TriageRules {
    /// Weekdays elapsed between two instants (Mon–Fri; holidays aren't modelled).
    public static func workingDays(from a: Date, to b: Date, calendar: Calendar = .current) -> Int {
        guard b > a else { return 0 }
        var n = 0, d = calendar.startOfDay(for: a)
        let end = calendar.startOfDay(for: b)
        var guardCount = 0
        while d < end, guardCount < 800 {
            guardCount += 1
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? end
            if !calendar.isDateInWeekend(d) { n += 1 }
        }
        return n
    }

    /// L1 (plan §4.2) with the owner's Phase 1 decisions. Total: always returns a state.
    public static func base(_ f: ConversationFacts, settings: TriageSettings = .init(), now: Date, calendar: Calendar = .current) -> TriageDecision {
        let ch = f.channel
        func d(_ s: ConversationState, _ c: TriageConfidence, _ r: TriageReason, hard: Bool = false, since: Date? = nil) -> TriageDecision {
            TriageDecision(state: s, confidence: c, reason: r, channel: ch, since: since, hard: hard, restricted: f.restricted)
        }
        // Calendar (R2): an unanswered invite needs an RSVP; answered → done; responses to my invites → fyi.
        if let m = f.meeting, !f.lastFromMe {
            switch m {
            case .requestUnanswered: return d(.needsReply, .high, .rsvp, hard: true, since: f.lastInboundAt)
            case .requestAnswered, .cancelled: return d(.done, .high, .meetingDone, hard: true, since: f.lastInboundAt)
            case .response: return d(.fyi, .high, .meetingResponse, hard: true, since: f.lastInboundAt)
            }
        }
        if f.lastFromMe {
            let since = f.lastOutboundAt
            let days = since.map { workingDays(from: $0, to: now, calendar: calendar) } ?? 0
            if f.restricted {   // direction only (recipients and text withheld): never a badge
                return d(days >= settings.waitingDays ? .waiting : .done, .low, .restrictedMine, hard: true, since: since)
            }
            if let c = f.outboundCues, c.asks { return d(.waiting, .high, .mineAsked, hard: true, since: since) }   // R3
            // "Plain FYI" (owner decision 1: never waiting): an FYI marker or closer, a forward with no ask, or a send
            // with nobody in To.
            let plainFYI = (f.outboundCues.map { !$0.intersection([.fyiMarker, .closer]).isEmpty } ?? false)
                || (f.outboundIsForward && (f.outboundCues.map { !$0.asks } ?? false))
                || f.myDirectRecipients == 0
            if plainFYI { return d(.done, .medium, f.myDirectRecipients == 0 ? .mineNoDirect : .mineFYI, hard: true, since: since) }
            if f.inboundCount >= 2, let c = f.outboundCues, c.contains(.short) {   // R4: a short answer deep in a thread
                return d(.done, .medium, .mineClosed, hard: true, since: since)
            }
            if days >= settings.waitingDays, (f.myDirectRecipients ?? 0) > 0 {
                return d(.waiting, .medium, .mineUnanswered, hard: true, since: since)
            }
            // Owner decision 1: not "waiting" until it asked something or N working days passed.
            return d(.done, .low, .mineRecent, hard: true, since: since)
        }
        let since = f.lastInboundAt
        if !f.hasInboxMember { return d(.done, .medium, .archived, since: since) }
        if ch == .bulk || ch == .notification || ch == .automated { return d(.fyi, .high, .channel, hard: true, since: since) }   // R1
        if f.restricted { return d(.needsReply, .low, .restrictedInbound, since: since) }
        if f.repliedAfterLastInbound { return d(.done, .medium, .closer, hard: true, since: since) }   // R5
        switch f.myRole {
        case .bccOrList: return d(.fyi, .high, .bccOrList, hard: true, since: since)   // R6
        case .cc:
            if let c = f.inboundCues, c.contains(.addressedByName), c.asks { return d(.needsReply, .medium, .ccAddressed, since: since) }
            if (f.otherRecipients ?? 0) >= 3 { return d(.fyi, .high, .ccBroadcast, since: since) }   // R7
            return d(.fyi, .medium, .ccPlain, since: since)
        case .to, .unknown:
            guard let c = f.inboundCues else { return d(.needsReply, .low, .inboundUndecided, since: since) }
            if c.contains(.closer) { return d(.done, .medium, .closer, since: since) }   // R9
            if c.asks || c.contains(.deadline) {
                if (f.otherRecipients ?? 0) <= 2 { return d(.needsReply, .high, .directAsk, since: since) }   // R8
                return d(.needsReply, .medium, .broadcastAsk, since: since)
            }
            if c.contains(.fyiMarker) { return d(.fyi, .medium, .directNoCue, since: since) }
            return d(.needsReply, .low, .directNoCue, since: since)   // undecided: "maybe reply"
        }
    }

    /// L1 + overrides (R10, R11), priors, snooze overlay and nudges.
    public static func decide(_ f: ConversationFacts, override: ConversationOverride? = nil, sender: SenderPrior? = nil,
                              settings: TriageSettings = .init(), now: Date, calendar: Calendar = .current) -> TriageDecision {
        var r = base(f, settings: settings, now: now, calendar: calendar)
        if let o = override, o.isLive(for: f) {   // R10: sticky while its snapshot is the newest message (TRIAGE3)
            r.state = o.state; r.confidence = .high; r.source = .user; r.reason = .override; r.hard = true
        } else if sender?.explicit == .neverNeedsReply, r.state == .needsReply, !f.lastFromMe {   // R11
            r.state = .fyi; r.confidence = .high; r.reason = .senderOverride; r.hard = true
        } else if r.confidence == .low {
            // The sender's corrections act as a prior (plan §3.2). TRIAGE3: an expired conversation override doesn't:
            // it judged an older message, so the state machine takes over again.
            let prior = f.lastFromMe ? nil : sender?.majority
            if let p = prior, p != r.state, f.lastFromMe ? p != .needsReply : p != .waiting {
                r.state = p; r.reason = .prior
            }
        }
        r.snoozed = (f.snoozedUntil ?? .distantPast) > now
        if let due = f.flagDue, due <= now, r.state == .needsReply || r.state == .waiting { r.nudge = .flagDue }
        else if let s = r.since, r.confidence >= .medium {
            let days = workingDays(from: s, to: now, calendar: calendar)
            if r.state == .needsReply, days >= settings.nudgeDays { r.nudge = .received(days: days) }
            if r.state == .waiting, days >= settings.waitingDays { r.nudge = .followUp(days: days) }
        }
        return r
    }

    /// L3 merge: hard rules and user overrides win; the LLM decides the rest and writes the ask line.
    public static func merge(_ rule: TriageDecision, llm: ThreadVerdict) -> TriageDecision {
        var r = rule
        if rule.source == .user || rule.restricted { return r }
        if rule.hard {
            if llm.state == rule.state { r.ask = llm.ask; r.why = llm.why }
            return r
        }
        r.state = llm.state; r.confidence = .medium; r.source = .llm; r.reason = .llm
        r.ask = llm.state == .needsReply ? llm.ask : nil; r.why = llm.why
        return r
    }
}

/// One L3 answer per thread.
public struct ThreadVerdict: Codable, Sendable, Hashable {
    public var state: ConversationState
    public var ask: String?
    public var why: String?
    public init(state: ConversationState, ask: String? = nil, why: String? = nil) { self.state = state; self.ask = ask; self.why = why }
}

// MARK: - Display (row badge, hover text)

public struct TriageDisplay: Sendable, Hashable {
    public var badge: ListRowBadge?
    public var title: String
    public var ask: String?
    public var maybe: Bool
    public var explain: String
    public var state: ConversationState

    public init(badge: ListRowBadge?, title: String, ask: String?, maybe: Bool, explain: String, state: ConversationState) {
        self.badge = badge; self.title = title; self.ask = ask; self.maybe = maybe; self.explain = explain; self.state = state
    }

    public static func from(_ d: TriageDecision, now: Date = Date(), calendar: Calendar = .current) -> TriageDisplay {
        var title = d.state.title
        if d.state == .waiting, let s = d.since {
            let days = TriageRules.workingDays(from: s, to: now, calendar: calendar)
            if days > 0 { title += " · \(days) d" }
        }
        let badge: ListRowBadge? = d.showsBadge ? (d.state == .needsReply ? .replyNeeded : .waiting) : nil
        return TriageDisplay(badge: badge, title: title, ask: d.ask, maybe: d.isMaybe, explain: explain(d), state: d.state)
    }

    /// Content-free reason (our own facts, never mail text, except the model's own "why" when it's shown).
    public static func explain(_ d: TriageDecision) -> String {
        let r: String = switch d.reason {
        case .channel: "Newsletter, notification or automatic reply"
        case .rsvp: "An invitation you haven't answered"
        case .meetingResponse: "A response to your invitation"
        case .meetingDone: "Invitation already answered or cancelled"
        case .mineAsked: "You sent the last message and asked something"
        case .mineUnanswered: "You sent the last message and nobody has answered for a few working days"
        case .mineClosed: "Your short reply closed the thread"
        case .mineFYI: "You sent the last message, for information"
        case .mineNoDirect: "You sent the last message with nobody in To"
        case .mineRecent: "You sent the last message recently"
        case .bccOrList: "You're in Bcc or on a list"
        case .ccBroadcast: "You're in Cc with several others"
        case .ccAddressed: "You're in Cc but addressed by name with a question"
        case .ccPlain: "You're in Cc"
        case .directAsk: "You're in To and they asked something"
        case .broadcastAsk: "A question to several people, you included"
        case .closer: "A thank-you, a confirmation or your reply closed the thread"
        case .directNoCue: "Addressed to you, nothing asked"
        case .inboundUndecided: "Addressed to you; the content isn't available to decide"
        case .restrictedInbound: "Protected or private: decided from direction only"
        case .restrictedMine: "Protected or private: you sent the last message"
        case .archived: "Archived"
        case .override: "Set by you"
        case .senderOverride: "You chose never “Reply needed” for this sender"
        case .prior: "From your earlier corrections"
        case .llm: "AI"
        }
        var s = r
        switch d.nudge {
        case .received(let n)?: s += "\nReceived \(n) working days ago"
        case .followUp(let n)?: s += "\nFollow up? Sent \(n) working days ago"
        case .flagDue?: s += "\nFlag due"
        case nil: break
        }
        if let w = d.why { s += "\nWhy: \(w)" }
        if d.confidence == .low { s += "\n(low confidence)" }
        return s
    }
}

// MARK: - Keys (per account HMAC: conversation ids and addresses never appear in the triage tables)

public enum TriageKeys {
    public static func derive(fromIndexKey k: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: Data("compliant-office.mail".utf8), info: Data("triage-v1".utf8), outputByteCount: 32)
    }
    /// 4-byte account namespace that prefixes every key, so one account's rows can be listed without another's.
    public static func accountTag(_ account: String, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("a|\(account)".utf8), using: key).prefix(4))
    }
    public static func conversation(_ id: String, account: String, key: SymmetricKey) -> Data {
        accountTag(account, key: key) + Data(HMAC<SHA256>.authenticationCode(for: Data("c|\(account)|\(id)".utf8), using: key).prefix(16))
    }
    /// TRIAGE3: a message id inside sealed payloads (snapshot tag), 8 bytes.
    public static func message(_ id: String, account: String, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("m|\(account)|\(id)".utf8), using: key).prefix(8))
    }
    /// TRIAGE3: a training answer's key = the conversation key + a tag of the snapshot time, so a conversation can carry
    /// answers for several snapshots and the 20-byte prefix still finds them (pre-snapshot rows are the bare 20 bytes).
    public static func truth(_ id: String, snapshotAt: Date, account: String, key: SymmetricKey) -> Data {
        let ms = Int64((snapshotAt.timeIntervalSince1970 * 1000).rounded())
        return conversation(id, account: account, key: key)
            + Data(HMAC<SHA256>.authenticationCode(for: Data("t|\(account)|\(id)|\(ms)".utf8), using: key).prefix(8))
    }
    public static func sender(_ address: String, account: String, key: SymmetricKey) -> Data {
        accountTag(account, key: key) + Data(HMAC<SHA256>.authenticationCode(for: Data("s|\(account)|\(address.lowercased())".utf8), using: key).prefix(16))
    }
}
