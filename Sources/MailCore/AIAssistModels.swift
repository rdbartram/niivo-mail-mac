import Foundation
import CryptoKit
import CalendarCore

// MARK: - Settings (UserDefaults JSON; the API key is NOT here, it lives in the Keychain)

public enum AIProviderChoice: String, Codable, Sendable, CaseIterable {
    case off, onDevice, claudeCLI, openAICompatible
    public var title: String {
        switch self { case .off: "Off"; case .onDevice: "On-device only"; case .claudeCLI: "Claude CLI"; case .openAICompatible: "OpenAI-compatible" }
    }
}

public struct AIAssistSettings: Codable, Sendable, Hashable {
    /// Off by default.
    public var choice: AIProviderChoice = .off
    /// With a cloud provider chosen: still use the on-device model (when available) for triage, summaries, intents.
    public var onDeviceForLightTasks = true
    public var claudeModel = "sonnet"
    /// Override for the `claude` binary; nil → `ClaudeCLIProvider.locate()`.
    public var claudePath: String?
    public var openAI = OpenAIConfig()
    public var precomputeTriage = true
    public var preSendCheck = true
    // TRIAGE2-HOOK: optionals so settings saved by older builds still decode.
    /// Conversation triage (rules always, AI only for the uncertain band). nil = on. false = the old per-message path.
    public var conversationTriage: Bool?
    /// Owner decision 1: N working days without an answer (To recipients) → waiting. nil = 3.
    public var waitingDays: Int?
    public var usesConversationTriage: Bool { conversationTriage ?? true }
    public var triageSettings: TriageSettings { TriageSettings(waitingDays: max(1, min(15, waitingDays ?? 3))) }
    public init() {}
}

// MARK: - Features + audit

public enum AIFeature: String, Sendable, CaseIterable {
    case triage, summarise, draftReply, rewrite, preSend, nlSearch, ask, bulkPlan, testConnection
    /// Light work goes on-device first.
    public var prefersOnDevice: Bool {
        switch self { case .triage, .summarise, .nlSearch, .bulkPlan, .preSend: true; default: false }
    }
}

/// One AI call, content-free: feature, provider, model, counts, bytes, outcome, duration.
public struct AIAuditRecord: Sendable, Equatable {
    public var feature: String
    public var provider: String
    public var model: String
    public var items: Int
    public var bytes: Int
    public var contentItems: Int
    public var metadataItems: Int
    public var blockedItems: Int
    public var outcome: String
    public var ms: Int
    /// `AuditLog`-safe token (charset `[A-Za-z0-9._:,=+/-]`).
    public var decision: String {
        let model = String(model.map { $0.isLetter || $0.isNumber || ".-:".contains($0) ? $0 : "." }.prefix(40))
        return "\(outcome):provider=\(provider),model=\(model),items=\(items),bytes=\(bytes),content=\(contentItems),meta=\(metadataItems),blocked=\(blockedItems),ms=\(ms)"
    }
}

public enum AIAssistError: Error, Sendable, Equatable, CustomStringConvertible {
    case off
    case notAllowed(String)
    case provider(AIProviderError)
    public var description: String {
        switch self {
        case .off: "AI is off"
        case .notAllowed(let s): s
        case .provider(let e): e.description
        }
    }
}

// MARK: - Results

public enum AITriageTag: String, Codable, Sendable, CaseIterable {
    case replyNeeded, waitingOnThem, fyi, bulk
    public var title: String {
        switch self { case .replyNeeded: "Reply needed"; case .waitingOnThem: "Waiting on them"; case .fyi: "FYI"; case .bulk: "Newsletter / bulk" }
    }
}

public struct AITriage: Codable, Sendable, Hashable {
    public var tag: AITriageTag
    /// "What this wants from you", one line. nil for rule-based results.
    public var ask: String?
    public var aiGenerated: Bool
    /// The model's one-line reason for the tag (testing / "why this tag?"). nil for rule-based results.
    public var why: String?
    /// The context lines the model was given for this message (ours, never mail text).
    public var context: [String]?
    public init(tag: AITriageTag, ask: String?, aiGenerated: Bool, why: String? = nil, context: [String]? = nil) {
        self.tag = tag; self.ask = ask; self.aiGenerated = aiGenerated; self.why = why; self.context = context
    }
}

/// Context the triage model gets per message, built from the local store: where the user is on the recipient
/// list, whether they already answered, who spoke last. Our own facts only — never mail text.
public enum TriageContext {
    public static func lines(for m: MailMessage, me: [String], thread: [MailMessage]) -> [String] {
        let mine = Set(me.map { $0.lowercased() })
        func isMe(_ a: EmailAddress?) -> Bool { a.map { mine.contains($0.address.lowercased()) } ?? false }
        var out: [String] = []
        let inTo = m.toRecipients.contains { isMe($0) }, inCc = m.ccRecipients.contains { isMe($0) }
        let others = (m.toRecipients + m.ccRecipients).filter { !isMe($0) }.count
        out.append("User is in: \(inTo ? "To" : inCc ? "Cc" : "neither To nor Cc (Bcc or a list)"); other recipients: \(others)")
        if isMe(m.from) { out.append("Sent by the user") }
        let domains = Set(me.compactMap { $0.split(separator: "@").last.map { $0.lowercased() } })
        if let d = m.from?.address.split(separator: "@").last.map({ $0.lowercased() }), !isMe(m.from) {
            out.append("Sender is \(domains.contains(d) ? "internal (same organisation)" : "external")")
        }
        let t = thread.filter { !$0.isDraft }
        if t.count > 1 {
            let repliedAfter = t.contains { isMe($0.from) && $0.received > m.received }
            let last = t.max { $0.received < $1.received }
            out.append("Thread: \(t.count) messages; user replied after this one: \(repliedAfter ? "yes" : "no"); last message is from \(isMe(last?.from) ? "the user" : "someone else")")
        } else {
            out.append("Thread: first message")
        }
        return out
    }
}

public enum AIReplyIntent: Int, Sendable, CaseIterable, Identifiable {
    case confirm = 1, decline, proposeTime, askInfo, delegate
    public var id: Int { rawValue }
    public var title: String {
        switch self { case .confirm: "Yes / confirm"; case .decline: "Decline"; case .proposeTime: "Propose a time"; case .askInfo: "Ask for more info"; case .delegate: "Delegate to…" }
    }
    var instruction: String {
        switch self {
        case .confirm: "Confirm / agree to what they asked, briefly."
        case .decline: "Decline politely and briefly; keep the relationship warm."
        case .proposeTime: "Propose the meeting times listed under 'Available slots' (all of them, as a short list) and ask which suits."
        case .askInfo: "Ask for the specific missing information needed to act."
        case .delegate: "Say the matter is being handed to the colleague named in the instruction, who is copied in."
        }
    }
}

public enum AITone: String, Codable, Sendable, CaseIterable { case neutral, friendly, formal, brief }
public enum AILength: String, Codable, Sendable, CaseIterable { case short, medium, long }
public enum AILanguage: String, Codable, Sendable, CaseIterable {
    case auto, de, fr, it, en
    public var title: String {
        switch self { case .auto: "Auto (match the email)"; case .de: "Deutsch"; case .fr: "Français"; case .it: "Italiano"; case .en: "English" }
    }
    var instruction: String {
        switch self {
        case .auto: "Write in the language of the email being answered (Swiss German customers: Standard German with Swiss spelling, ss not ß)."
        case .de: "Write in Standard German with Swiss spelling (ss, not ß)."
        case .fr: "Write in French."
        case .it: "Write in Italian."
        case .en: "Write in British English."
        }
    }
}

public struct AIDraftOptions: Sendable, Hashable {
    public var tone: AITone
    public var length: AILength
    public var language: AILanguage
    /// The user's own instruction ("decline politely, propose next Tuesday").
    public var instruction: String
    public init(tone: AITone = .neutral, length: AILength = .short, language: AILanguage = .auto, instruction: String = "") {
        self.tone = tone; self.length = length; self.language = language; self.instruction = instruction
    }
}

public enum AIRewriteMode: String, Sendable, CaseIterable, Identifiable {
    case polish, shorten, formal, friendly, toGerman, toFrench, toItalian, toEnglish
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .polish: "Polish"; case .shorten: "Shorten"; case .formal: "More formal"; case .friendly: "Friendlier"
        case .toGerman: "Translate to German"; case .toFrench: "Translate to French"; case .toItalian: "Translate to Italian"; case .toEnglish: "Translate to English"
        }
    }
    var instruction: String {
        switch self {
        case .polish: "Fix grammar and flow; keep meaning, length and voice."
        case .shorten: "Make it about half as long; keep every fact and request."
        case .formal: "Make it more formal and polite."
        case .friendly: "Make it warmer and friendlier, still professional."
        case .toGerman: "Translate into Standard German with Swiss spelling (ss, not ß)."
        case .toFrench: "Translate into French."
        case .toItalian: "Translate into Italian."
        case .toEnglish: "Translate into British English."
        }
    }
}

public struct AITextResult: Sendable, Hashable {
    public var text: String
    public var sources: [AIPromptSource]
    public var notes: [String]
    public var provider: AIProviderID
}

public struct AICitedLine: Sendable, Hashable {
    public var text: String; public var cites: [Int]
    public init(text: String, cites: [Int]) { self.text = text; self.cites = cites }
}

public struct AIThreadSummary: Sendable, Hashable {
    public var tldr: String
    public var decisions: [AICitedLine]
    public var openQuestions: [AICitedLine]
    public var owes: [AICitedLine]
    public var sources: [AIPromptSource]
    public var notes: [String]
    public init(tldr: String, decisions: [AICitedLine], openQuestions: [AICitedLine], owes: [AICitedLine], sources: [AIPromptSource], notes: [String]) {
        self.tldr = tldr; self.decisions = decisions; self.openQuestions = openQuestions; self.owes = owes; self.sources = sources; self.notes = notes
    }
}

public struct AIPreSendFinding: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case attachment, unanswered, commitment, tone, externalLabelled }
    public var kind: Kind
    public var text: String
    public var id: String { kind.rawValue + ":" + text }
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

/// Local search derived from natural language. Only the user's words went to the provider.
public struct AISearchQuery: Sendable, Hashable {
    public var terms: [String]
    public var from: String?
    public var after: Date?
    public var before: Date?
    public var hasAttachments: Bool?
    public var folder: String?
    public var fromAI: Bool
    public init(terms: [String] = [], from: String? = nil, after: Date? = nil, before: Date? = nil,
                hasAttachments: Bool? = nil, folder: String? = nil, fromAI: Bool = false) {
        self.terms = terms; self.from = from; self.after = after; self.before = before
        self.hasAttachments = hasAttachments; self.folder = folder; self.fromAI = fromAI
    }
    public static func plain(_ q: String) -> AISearchQuery {
        let t = q.trimmingCharacters(in: .whitespaces)
        return AISearchQuery(terms: t.isEmpty ? [] : [t])
    }

    /// Text for the blind index / server search (terms AND sender tokens).
    public var textQuery: String { (terms + [from].compactMap { $0 }).joined(separator: " ").trimmingCharacters(in: .whitespaces) }

    /// Post-filters the local index can't express. `folderName` = display name of the message's folder.
    public func matches(_ m: MailMessage, folderName: String?) -> Bool {
        if let a = after, m.received < a { return false }
        if let b = before, m.received >= b { return false }
        if let h = hasAttachments, m.hasAttachments != h { return false }
        if let f = from?.lowercased(), !f.isEmpty {
            let hay = ((m.from?.name ?? "") + " " + (m.from?.address ?? "")).lowercased()
            if !f.split(separator: " ").allSatisfy({ hay.contains($0) }) { return false }
        }
        if let want = folder?.lowercased(), !want.isEmpty {
            guard let have = folderName?.lowercased(), have.contains(want) || want.contains(have) else { return false }
        }
        return true
    }

    public var summary: String {
        var p: [String] = []
        if !terms.isEmpty { p.append("“\(terms.joined(separator: " "))”") }
        if let f = from { p.append("from \(f)") }
        let df = Date.FormatStyle(date: .abbreviated, time: .omitted)
        if let a = after { p.append("after \(a.formatted(df))") }
        if let b = before { p.append("before \(b.formatted(df))") }
        if hasAttachments == true { p.append("with attachments") }
        if let f = folder { p.append("in \(f)") }
        return p.joined(separator: " · ")
    }
}

public struct AIBulkPlan: Sendable, Hashable {
    public enum Action: String, Sendable, CaseIterable { case archive, markRead, flag, unflag }
    public var action: Action
    public var query: AISearchQuery
    public var description: String
    public init(action: Action, query: AISearchQuery, description: String) { self.action = action; self.query = query; self.description = description }
}

// MARK: - Propose a time (our own calendar, no AI)

public enum AISlots {
    /// Up to `count` free slots of `minutes` in working hours over the next `days` working days, spread one per day
    /// first, never in the past. `events` = the user's own calendars (busy blocks).
    public static func propose(events: [CalendarEvent], from now: Date, days: Int = 5, workStart: Int = 9 * 60,
                               workEnd: Int = 17 * 60, minutes: Int = 30, count: Int = 3,
                               calendar: Calendar = .current) -> [DateInterval] {
        var first: [DateInterval] = [], extra: [DateInterval] = []
        var day = calendar.startOfDay(for: now), checked = 0, guardDays = 0
        while checked < days && guardDays < 21 {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day)!; guardDays += 1 }
            if calendar.isDateInWeekend(day) { continue }
            checked += 1
            let nowMin = calendar.isDate(day, inSameDayAs: now) ? Int(now.timeIntervalSince(day) / 60) + 30 : 0
            let from = max(workStart, (nowMin + 29) / 30 * 30)
            guard from < workEnd else { continue }
            var isFirst = true
            for (a, b) in FreeTime.gaps(events, day: day, from: from, to: workEnd, minGap: minutes, calendar: calendar) {
                var s = (a + 29) / 30 * 30
                while s + minutes <= b {
                    let iv = DateInterval(start: day.addingTimeInterval(Double(s * 60)), duration: Double(minutes * 60))
                    if isFirst { first.append(iv); isFirst = false } else { extra.append(iv) }
                    s += 60
                }
            }
        }
        return Array((first + extra).prefix(count)).sorted { $0.start < $1.start }
    }

    public static func describe(_ slots: [DateInterval], timeZone: TimeZone = .current) -> [String] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.timeZone = timeZone
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        let t = DateFormatter(); t.locale = f.locale; t.timeZone = timeZone; t.dateFormat = "HH:mm"
        return slots.map { "\(f.string(from: $0.start))–\(t.string(from: $0.end)) (\(timeZone.identifier))" }
    }
}

// MARK: - Encrypted cache key (results live in the sealed MailStore kv table)

public enum AICacheKey {
    /// Keyed by message id + changeKey + label + gate decision + tier: an edit, label change or policy change misses.
    public static func triage(_ m: MailMessage, exposure: AIExposure, tier: AITier) -> String {
        let raw = "\(m.id)|\(m.changeKey ?? "")|\(m.labelId ?? "")|\(exposure.rawValue)|\(tier.rawValue)"
        return "ai.triage:" + SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
