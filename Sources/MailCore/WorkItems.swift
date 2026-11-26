import Foundation

// WORK ITEMS (docs/SUITE.md, When v0-4 / Deep v0-5): a loop's pieces of work. Each has a title, a kind, an estimated
// duration, a due date, "done when" criteria (a short checklist), a state and, once placed, a slot on the calendar.
// Suggestions come from the loop's open promises and needs-reply conversations, but stay suggestions until the user
// accepts one (same rule as loops: never auto-commit). The store is `WorkItemsEngine.swift`.
//
// Label rule: titles derived from mail (a promise's text, a conversation's subject) are resolved for the user tier at
// read time and are nil when the source isn't text-visible; they're on disk only when every source may keep offline
// details. A title the user typed is theirs and always kept.

public enum WorkItemKind: String, Codable, Sendable, Hashable, CaseIterable {
    case reply, doc, sheet, ticket, task, promise
    /// Mono tag on rows ("MAIL", "DOC" …; the UI localises).
    public var tag: String {
        switch self { case .reply: "Mail"; case .doc: "Doc"; case .sheet: "Sheet"; case .ticket: "Ticket"; case .task: "Task"; case .promise: "Promise" }
    }
    /// A sensible first estimate (minutes).
    public var defaultMinutes: Int {
        switch self { case .reply: 20; case .promise: 30; case .task: 30; case .ticket: 30; case .sheet: 50; case .doc: 50 }
    }
}

public enum WorkItemState: String, Codable, Sendable, Hashable, CaseIterable { case open, scheduled, inProgress, done }

/// Where a work item came from (on disk: ids only, never message ids, which change on move).
public enum WorkItemSource: Codable, Sendable, Hashable {
    case promise(id: String)
    case conversation(id: String)
    /// Stable key for "already suggested / dismissed" bookkeeping.
    public var key: String {
        switch self { case .promise(let id): "p|" + id; case .conversation(let id): "c|" + id }
    }
    public var conversationId: String? { if case .conversation(let c) = self { c } else { nil } }
}

/// A placed block on the owner's calendar.
public struct WorkSlot: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date
    /// The focus block's event id (nil until the calendar write is confirmed and done).
    public var eventId: String?
    public init(start: Date, end: Date, eventId: String? = nil) { self.start = start; self.end = end; self.eventId = eventId }
    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

public struct DoneCriterion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var done: Bool
    public init(id: String = UUID().uuidString.lowercased(), text: String, done: Bool = false) {
        self.id = id; self.text = text; self.done = done
    }
}

/// One work item as the surfaces see it (title resolved for the user tier).
public struct WorkItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var loopId: String
    /// nil when the title came from mail that isn't text-visible now (the UI shows a neutral "Work item").
    public var title: String?
    /// The user typed (or edited) the title: only then may it become a calendar subject.
    public var titleUser: Bool
    public var kind: WorkItemKind
    public var minutes: Int
    public var due: Date?
    public var criteria: [DoneCriterion]
    public var state: WorkItemState
    public var slot: WorkSlot?
    /// The block this item had before "Reschedule": the next confirmed block replaces it (it's removed then).
    public var movingFrom: WorkSlot?
    public var source: WorkItemSource?
    /// "Later" / "Park": not offered for placing before this time.
    public var deferredUntil: Date?
    public var created: Date
    public var updated: Date

    public var criteriaDone: Int { criteria.filter(\.done).count }
    public func isDeferred(now: Date) -> Bool { (deferredUntil ?? .distantPast) > now }
    /// Scheduled, but its block is over and work never started: it goes back to When.
    public func isMissed(now: Date) -> Bool { state == .scheduled && (slot?.end ?? .distantFuture) <= now }
}

public struct WorkItemSuggestion: Sendable, Hashable, Identifiable {
    public var loopId: String
    public var source: WorkItemSource
    public var kind: WorkItemKind
    /// nil when the source text isn't visible for the user tier.
    public var title: String?
    public var minutes: Int
    public var due: Date?
    public var criteria: [String]
    public var id: String { source.key }
}
