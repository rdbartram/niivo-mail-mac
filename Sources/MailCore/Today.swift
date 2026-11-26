import Foundation

// TODAY (docs/RETHINK.md §4): the "what needs me" home built on the conversation triage state. Everything here is
// pure and content-free: signals are our own facts (direction, To/Cc, cue bits, age, confidence, VIP), never mail text.
// The app (TodayModel.swift) feeds it decisions + facts and renders the plan; CoreSelfTest checks it.

// MARK: - Signals and score

/// Why a card ranks where it does (shown as chips; content-free).
public enum TodayReason: String, Sendable, Hashable, CaseIterable {
    case vip, direct, cc, deadline, flagDue, aged, external, internalSender
    public var title: String {
        switch self {
        case .vip: "VIP"
        case .direct: "To you"
        case .cc: "Cc"
        case .deadline: "Deadline"
        case .flagDue: "Flag due"
        case .aged: "Waiting on you"
        case .external: "External"
        case .internalSender: "Internal"
        }
    }
}

public struct TodaySignals: Sendable, Hashable {
    /// VIP or a favourite person.
    public var vip: Bool
    public var role: TriageRole
    public var deadline: Bool
    public var flagDue: Bool
    /// Working days since the last inbound (needs you) or my last send (waiting).
    public var ageDays: Int
    public var confidence: TriageConfidence
    public var internalSender: Bool
    public init(vip: Bool = false, role: TriageRole = .unknown, deadline: Bool = false, flagDue: Bool = false, ageDays: Int = 0,
                confidence: TriageConfidence = .medium, internalSender: Bool = false) {
        self.vip = vip; self.role = role; self.deadline = deadline; self.flagDue = flagDue; self.ageDays = ageDays
        self.confidence = confidence; self.internalSender = internalSender
    }

    /// From the triage facts (cue bits are only present where the label gate allowed reading the text).
    public static func from(_ f: ConversationFacts?, decision d: TriageDecision, vip: Bool, now: Date, calendar: Calendar = .current) -> TodaySignals {
        let age = d.since.map { TriageRules.workingDays(from: $0, to: now, calendar: calendar) } ?? 0
        let flagDue: Bool = { if case .flagDue? = d.nudge { true } else { false } }()
        return TodaySignals(vip: vip, role: f?.myRole ?? .unknown, deadline: f?.inboundCues?.contains(.deadline) ?? false,
                            flagDue: flagDue, ageDays: age, confidence: d.confidence, internalSender: f?.senderInternal ?? false)
    }
}

public enum TodayScorer {
    /// Ageing adds up to this much (a mail ignored for days rises, but never above a VIP's fresh ask).
    public static let maxAgeBonus = 20.0
    public static func score(_ s: TodaySignals) -> Double {
        var x = 0.0
        if s.vip { x += 40 }
        switch s.role { case .to: x += 20; case .cc: x -= 10; case .bccOrList: x -= 20; case .unknown: break }
        if s.deadline { x += 25 }
        if s.flagDue { x += 15 }
        x += min(maxAgeBonus, Double(max(0, s.ageDays)) * 4)
        switch s.confidence { case .high: x += 10; case .medium: x += 5; case .low: break }
        if !s.internalSender { x += 6 }   // clients and partners wait on you; colleagues can ask again
        return x
    }

    /// At most four chips, strongest first.
    public static func reasons(_ s: TodaySignals) -> [TodayReason] {
        var r: [TodayReason] = []
        if s.vip { r.append(.vip) }
        if s.deadline { r.append(.deadline) }
        if s.flagDue { r.append(.flagDue) }
        if s.role == .to { r.append(.direct) } else if s.role == .cc { r.append(.cc) }
        if s.ageDays >= 2 { r.append(.aged) }
        r.append(s.internalSender ? .internalSender : .external)
        return Array(r.prefix(4))
    }
}

// MARK: - Sections and plan

public enum TodaySection: String, Sendable, Hashable { case needsYou, maybe, waiting, fyi, none }

public enum TodaySections {
    /// Snoozed and done never show; needs-reply splits by confidence; waiting only with a badge (medium+);
    /// FYI only while it's recent (the digest is "today's" FYI, not the archive of everything ever).
    public static func section(for d: TriageDecision, now: Date, fyiWindow: TimeInterval = 86_400) -> TodaySection {
        if d.snoozed { return .none }
        switch d.state {
        case .needsReply: return d.confidence >= .medium ? .needsYou : .maybe
        case .waiting: return d.showsBadge ? .waiting : .none
        case .fyi: return now.timeIntervalSince(d.since ?? .distantPast) <= fyiWindow ? .fyi : .none
        case .done: return .none
        }
    }
}

public struct TodayInput: Sendable, Hashable {
    public var conversationId: String
    public var decision: TriageDecision
    public var signals: TodaySignals
    public init(conversationId: String, decision: TriageDecision, signals: TodaySignals) {
        self.conversationId = conversationId; self.decision = decision; self.signals = signals
    }
}

public struct TodayItem: Sendable, Hashable, Identifiable {
    public var id: String { conversationId }
    public var conversationId: String
    public var section: TodaySection
    public var score: Double
    public var reasons: [TodayReason]
    public var ageDays: Int
    public var maybe: Bool { section == .maybe }
    public var decision: TriageDecision
}

public struct TodayPlan: Sendable, Hashable {
    /// Confident first (by score), then "maybe" cards in the room the confident ones leave under the cap.
    public var needsYou: [TodayItem] = []
    public var waiting: [TodayItem] = []
    public var fyi: [TodayItem] = []
    /// Needs-you cards that didn't fit (confident beyond the cap, or maybes without room).
    public var hidden = 0
    public var counts: (needs: Int, maybe: Int, waiting: Int, fyi: Int) = (0, 0, 0, 0)
    public init() {}
    public static func == (a: TodayPlan, b: TodayPlan) -> Bool {
        a.needsYou == b.needsYou && a.waiting == b.waiting && a.fyi == b.fyi && a.hidden == b.hidden
    }
    public func hash(into h: inout Hasher) { h.combine(needsYou); h.combine(waiting); h.combine(fyi); h.combine(hidden) }

    /// Content-free diagnostic line (counts only).
    public var diagnostic: String {
        "[Today] needs=\(counts.needs) waiting=\(counts.waiting) fyi=\(counts.fyi) shown=\(needsYou.count) maybe=\(counts.maybe) hidden=\(hidden)"
    }
}

public enum TodayPlanner {
    /// RETHINK §4: 5–15 cards. The cap is the upper bound; there's no padding up to the lower one.
    public static let cap = 15

    public static func plan(_ inputs: [TodayInput], now: Date, cap: Int = cap) -> TodayPlan {
        var p = TodayPlan()
        var needs: [TodayItem] = [], maybes: [TodayItem] = []
        for i in inputs {
            let s = TodaySections.section(for: i.decision, now: now)
            guard s != .none else { continue }
            let item = TodayItem(conversationId: i.conversationId, section: s, score: TodayScorer.score(i.signals),
                                 reasons: i.decision.restricted ? [] : TodayScorer.reasons(i.signals), ageDays: i.signals.ageDays,
                                 decision: i.decision)
            switch s {
            case .needsYou: needs.append(item)
            case .maybe: maybes.append(item)
            case .waiting: p.waiting.append(item)
            case .fyi: p.fyi.append(item)
            case .none: break
            }
        }
        // Ties: older first (it has waited longer), then id (stable).
        func order(_ a: TodayItem, _ b: TodayItem) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.ageDays != b.ageDays { return a.ageDays > b.ageDays }
            return a.conversationId < b.conversationId
        }
        needs.sort(by: order); maybes.sort(by: order)
        p.waiting.sort { ($0.ageDays, $1.conversationId) > ($1.ageDays, $0.conversationId) }
        p.fyi.sort { ($0.decision.since ?? .distantPast, $1.conversationId) > ($1.decision.since ?? .distantPast, $0.conversationId) }
        let shownNeeds = Array(needs.prefix(cap))
        let room = max(0, cap - shownNeeds.count)
        p.needsYou = shownNeeds + maybes.prefix(room)
        p.hidden = needs.count + maybes.count - p.needsYou.count
        p.counts = (needs.count, maybes.count, p.waiting.count, p.fyi.count)
        return p
    }
}

// MARK: - Card text (labels and redaction exactly as the list)

public struct TodayCardText: Sendable, Hashable {
    public var sender: String
    public var line: String
    /// The line is the AI's ask (not the subject).
    public var isAsk: Bool
    /// Chips, avatar and ask are allowed (the list drops triage details for redacted rows).
    public var showsDetails: Bool

    /// - redactDetails / allowOfflineDetails: the conversation's strictest policy (as the list's thread row).
    public static func make(sender: String?, subject: String, ask: String?, redactDetails: Bool, allowOfflineDetails: Bool) -> TodayCardText {
        if redactDetails { return TodayCardText(sender: "Private", line: "Private message", isAsk: false, showsDetails: false) }
        let who = (sender?.isEmpty ?? true) ? "(no sender)" : sender!
        if allowOfflineDetails, let a = ask?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            return TodayCardText(sender: who, line: a, isAsk: true, showsDetails: true)
        }
        return TodayCardText(sender: who, line: subject.isEmpty ? "(no subject)" : subject, isAsk: false, showsDetails: true)
    }
}

// MARK: - Calm notifications

public enum TodayNotificationFilter {
    /// "Notify only for Needs-you": new inbound mail the triage puts in Needs you with at least medium confidence, or
    /// from a VIP. `triageActive == false` (conversation triage off / not running) passes everything: the switch
    /// never silently mutes all mail. A conversation without a decision yet is held back (calm by default; the app
    /// refreshes the engine before asking, so this is the rare "not in the window" case).
    public static func allows(decision: TriageDecision?, fromVIP: Bool, triageActive: Bool) -> Bool {
        guard triageActive else { return true }
        if fromVIP { return true }
        guard let d = decision else { return false }
        return d.state == .needsReply && d.confidence >= .medium && !d.snoozed
    }
}

// MARK: - Flow mode (one conversation at a time)

public struct TodayFlow: Sendable, Hashable {
    /// Conversation ids, fixed when Flow starts (so "3 of 9" stays stable while items get handled).
    public private(set) var items: [String]
    public private(set) var index: Int
    public private(set) var handled: Set<String> = []
    public private(set) var finished = false

    public init(items: [String], start: String? = nil) {
        self.items = items
        index = start.flatMap { items.firstIndex(of: $0) } ?? 0
        finished = items.isEmpty
    }

    public var current: String? { finished || items.isEmpty ? nil : items[index] }
    /// "3 of 9" (1-based).
    public var position: (Int, Int) { (min(index + 1, items.count), items.count) }

    /// J: the next item still open; past the last one → finished ("You're clear").
    public mutating func next() {
        guard !finished else { return }
        var j = index + 1
        while j < items.count, handled.contains(items[j]) { j += 1 }
        if j >= items.count { finished = true } else { index = j }
    }

    /// K: the previous item (handled ones included, so you can look back); from "You're clear" back to the last.
    public mutating func previous() {
        if finished { finished = items.isEmpty; index = max(0, items.count - 1); return }
        index = max(0, index - 1)
    }

    /// R/S/D/E/Z on the current item: mark it handled and move on.
    public mutating func handleCurrent(advance: Bool = true) {
        guard let c = current else { return }
        handled.insert(c)
        if advance { next() }
    }

    /// The quiet summary at the end.
    public var summary: (handled: Int, skipped: Int) { (handled.count, items.count - handled.count) }
}

// MARK: - Promises (another builder implements the source)

/// A commitment from the promises ledger (RETHINK §4 "Your promises due"). Content-free fields only; `title` is shown
/// under the same label rules as the list (the source must redact protected rows itself).
public struct TodayPromise: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var due: Date?
    public var conversationId: String?
    public init(id: String, title: String, due: Date?, conversationId: String?) {
        self.id = id; self.title = title; self.due = due; self.conversationId = conversationId
    }
}

/// TODAY-HOOK: the promises ledger plugs in here. Until it exists, Today shows an empty "Promises due" section.
public protocol PromiseSource: Sendable {
    func promisesDue(before: Date) -> [TodayPromise]
}
