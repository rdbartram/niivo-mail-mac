import Foundation

// LOOPS (docs/SUITE.md, suite step 1): a Loop is a named matter or project the user works on. It holds member
// conversations (each with where the membership came from), the people and organisations those derive, and items
// (mails, files, promises; later docs, sheets and tickets). Loops are per account and never span accounts.
//
// This file holds the plain value types and the read-only `LoopSource` protocol other surfaces (Signal, the People
// page, When, Deep) read. The engine that proposes, stores and edits loops is `LoopsEngine.swift`.
//
// Label rule: every text a summary carries (title, anchor text) is already resolved for the tier the caller asked
// for; it's nil when no source allows that text. Protected sources contribute metadata only (addresses, counts,
// dates), never text, anchors or titles.

public enum LoopState: String, Codable, Sendable, Hashable, CaseIterable { case open, done, archived }

/// Whose move it is in a loop (People page: "they owe you a reply" / "waiting on them").
public enum LoopWaitingOn: String, Sendable, Hashable, Codable { case me, them, none }

/// Where a membership came from.
public enum LoopOrigin: Sendable, Hashable, Codable {
    /// Proposed by the engine from a shared anchor. `evidence` is a keyed hash of the anchor (never the anchor text);
    /// the text is re-derived at read time only where the label gate allows it.
    case proposed(kind: StoryAnchor.Kind, evidence: String)
    /// The user put the conversation in the loop.
    case confirmed

    public var isConfirmed: Bool { if case .confirmed = self { true } else { false } }
}

/// The channel an item came in on. Mail now; Teams later (Signal's "Now" card shows it).
public enum SignalChannel: String, Codable, Sendable, Hashable, CaseIterable {
    case mail, teams
    public var title: String { switch self { case .mail: "Mail"; case .teams: "Teams" } }
}

/// One loop as other surfaces see it (read-only, resolved for one tier).
public struct LoopSummary: Sendable, Hashable, Identifiable {
    public var id: String
    /// nil when no source allows the title for the tier asked (the UI shows a neutral "Loop").
    public var title: String?
    public var state: LoopState
    public var due: Date?
    /// At least one membership was confirmed by the user, or the user created / named the loop. Seeded loops stay
    /// "suggested" (false) until then.
    public var confirmed: Bool
    public var conversationCount: Int
    public var confirmedCount: Int
    /// Lower-cased addresses of the people in the member conversations (owners excluded; metadata-visible only).
    public var people: [String]
    /// Registrable domains of those people (free-mail excluded).
    public var organisations: [String]
    public var lastActivity: Date?
    public var created: Date
    /// From the newest member conversation's direction (metadata): my message last → them, theirs → me.
    public var waitingOn: LoopWaitingOn
    public init(id: String, title: String?, state: LoopState, due: Date?, confirmed: Bool, conversationCount: Int,
                confirmedCount: Int, people: [String], organisations: [String], lastActivity: Date?, created: Date,
                waitingOn: LoopWaitingOn = .none) {
        self.id = id; self.title = title; self.state = state; self.due = due; self.confirmed = confirmed
        self.conversationCount = conversationCount; self.confirmedCount = confirmedCount; self.people = people
        self.organisations = organisations; self.lastActivity = lastActivity; self.created = created; self.waitingOn = waitingOn
    }
    /// The People surface's stand-in initialiser (stubs and tests): a free-form state string.
    public init(id: String, title: String?, state: String, due: Date? = nil, waitingOn: LoopWaitingOn = .none) {
        let s: LoopState = ["done", "closed", "dismissed"].contains(state.lowercased()) ? .done : state.lowercased() == "archived" ? .archived : .open
        self.init(id: id, title: title, state: s, due: due, confirmed: true, conversationCount: 0, confirmedCount: 0, people: [],
                  organisations: [], lastActivity: nil, created: .distantPast, waitingOn: waitingOn)
    }
    public var isOpen: Bool { state == .open }
}

/// Why a loop is proposed for a conversation (content-free structure; the UI formats it).
public struct LoopReason: Sendable, Hashable {
    public var kind: StoryAnchor.Kind
    /// The shared anchor as written, only when the conversation's text is visible for the tier.
    public var anchorText: String?
    /// The loop's confirmed members share a (non-owner) person or organisation with this conversation as well.
    public var samePeople: Bool
    public init(kind: StoryAnchor.Kind, anchorText: String?, samePeople: Bool) {
        self.kind = kind; self.anchorText = anchorText; self.samePeople = samePeople
    }
}

public struct LoopCandidate: Sendable, Hashable, Identifiable {
    public var loop: LoopSummary
    public var reason: LoopReason
    public var score: Double
    public var id: String { loop.id }
}

/// The proposal for one conversation: the best existing loop (with a reason), up to two alternatives and a suggested
/// title for a new loop. Never from similarity alone: every candidate shares an anchor with the conversation.
public struct LoopProposal: Sendable, Hashable {
    public var conversationId: String
    public var best: LoopCandidate?
    public var alternatives: [LoopCandidate]
    /// nil when the conversation's subject may not be used (protected / redacted) or may not be kept offline: the
    /// "New loop" field then starts empty, so a gated subject never becomes a persisted "user" title.
    public var newTitle: String?
    /// The conversation is already confirmed in this loop (no proposal needed).
    public var confirmedLoop: LoopSummary?
    public init(conversationId: String, best: LoopCandidate? = nil, alternatives: [LoopCandidate] = [], newTitle: String? = nil,
                confirmedLoop: LoopSummary? = nil) {
        self.conversationId = conversationId; self.best = best; self.alternatives = alternatives; self.newTitle = newTitle
        self.confirmedLoop = confirmedLoop
    }
}

/// LOOPS-HOOK: read-only access to one account's loops. Signal, the People page and later When / Deep read loops
/// through this; only `LoopsEngine` writes. Titles are resolved for the user tier (the signed-in user's own view).
/// Every requirement has a default, so a stub (People surface tests) implements only what it needs; LoopsEngine
/// implements all of them. Implementations must be safe to read from any thread.
public protocol LoopSource: AnyObject {
    /// People surface: loops (any state, suggested ones included: check `confirmed`) whose conversations include this
    /// address, for this account only.
    func loops(involving address: String, account: String) -> [LoopSummary]
    /// The account these loops belong to (loops never span accounts).
    var account: String { get }
    /// All loops (open first, then by last activity). `includeSuggested == false` drops seeded loops nobody has
    /// confirmed yet.
    func loops(includeSuggested: Bool) -> [LoopSummary]
    func loop(id: String) -> LoopSummary?
    /// The loop a conversation is CONFIRMED in (nil for proposed-only memberships).
    func confirmedLoop(forConversation conversationId: String) -> LoopSummary?
    /// Loops whose member conversations include any of these addresses (one person can have several addresses).
    func loops(withPeople addresses: [String], includeSuggested: Bool) -> [LoopSummary]
    /// Loops with people from this registrable domain.
    func loops(withOrganisation domain: String, includeSuggested: Bool) -> [LoopSummary]
}

public extension LoopSource {
    var account: String { "" }
    func loops(involving address: String, account: String) -> [LoopSummary] {
        account == self.account ? loops(withPeople: [address], includeSuggested: true) : []
    }
    func loops(includeSuggested: Bool) -> [LoopSummary] { [] }
    func loop(id: String) -> LoopSummary? { nil }
    func confirmedLoop(forConversation conversationId: String) -> LoopSummary? { nil }
    func loops(withPeople addresses: [String], includeSuggested: Bool) -> [LoopSummary] { [] }
    func loops(withOrganisation domain: String, includeSuggested: Bool) -> [LoopSummary] { [] }
}
