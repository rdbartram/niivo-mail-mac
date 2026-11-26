import Foundation
import CalendarCore

// PEOPLE2: pure logic behind the People surface (directory, person page, organisation / place panels). The app
// (CompliantCalendar/PeopleSurfaceViews.swift) supplies the inputs; everything here is testable from CoreSelfTest.
//
// * Directory: people, organisations and places from the knowledge view (user tier), sorted by most recent contact,
//   each with an open count (loops through `LoopSource` when one is wired; otherwise open triage conversations).
// * Who owes whom: from conversation triage (needs reply / waiting) on conversations with that person, one account.
// * History: MAIL / MEETING / NOTE (TEAMS later), newest first; a protected item keeps its date and kind, never a title.
// * Empty state: one reason, shared by the page text and the counts-only `[People]` log line.

public enum PeopleHistoryKind: String, Sendable, Hashable, Codable, CaseIterable {
    case mail = "MAIL", meeting = "MEETING", note = "NOTE", teams = "TEAMS"
    var order: Int { switch self { case .mail: 0; case .meeting: 1; case .note: 2; case .teams: 3 } }
}

/// One candidate history entry before merging. `visible == false` → only kind and date may be shown.
public struct PeopleHistoryInput: Sendable, Hashable {
    public var kind: PeopleHistoryKind
    /// What opening the item needs: message id, event id or note page id.
    public var ref: String
    public var date: Date
    public var title: String
    public var visible: Bool
    /// Items with the same group collapse to the newest (a mail conversation is one line).
    public var group: String?
    public var link: URL?
    public init(kind: PeopleHistoryKind, ref: String, date: Date, title: String, visible: Bool, group: String? = nil, link: URL? = nil) {
        self.kind = kind; self.ref = ref; self.date = date; self.title = title; self.visible = visible; self.group = group; self.link = link
    }
}

public struct PeopleHistoryItem: Sendable, Hashable, Identifiable {
    public var kind: PeopleHistoryKind
    public var ref: String
    public var date: Date
    /// nil = protected by its label / private: show metadata only.
    public var title: String?
    public var link: URL?
    public var id: String { kind.rawValue + "|" + ref }
}

/// One conversation with the person, as triage sees it (the app maps `ConversationFacts` + `TriageDecision`).
public struct PeopleConversation: Sendable, Hashable {
    public var conversationId: String
    public var account: String
    public var state: ConversationState
    /// The last inbound sender.
    public var senderAddress: String?
    public var lastFromMe: Bool
    public var latestMessageId: String
    public var since: Date?
    public init(conversationId: String, account: String, state: ConversationState, senderAddress: String?, lastFromMe: Bool,
                latestMessageId: String, since: Date? = nil) {
        self.conversationId = conversationId; self.account = account; self.state = state; self.senderAddress = senderAddress
        self.lastFromMe = lastFromMe; self.latestMessageId = latestMessageId; self.since = since
    }
}

public struct PeopleOwes: Sendable, Hashable {
    /// I wrote last and the conversation is Waiting.
    public var theyOwe = 0
    /// They wrote last to me and it needs my reply.
    public var youOwe = 0
    public var theyOweSince: Date?
    public var youOweSince: Date?
    /// My latest message in the most recent Waiting conversation (Reply all goes back to its recipients).
    public var nudgeMessageId: String?
    public var none: Bool { theyOwe == 0 && youOwe == 0 }
    public init() {}
}

public struct PeopleOpenCount: Sendable, Hashable {
    public var count: Int
    /// true = counted through `LoopSource`; false = open triage conversations (needs reply + waiting).
    public var fromLoops: Bool
    public init(count: Int, fromLoops: Bool) { self.count = count; self.fromLoops = fromLoops }
}

public struct PeopleDirectoryRow: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var address: String
    public var org: String?
    public var orgName: String?
    public var place: String?
    public var first: Date?
    public var last: Date?
    public var isInternal: Bool
    public var open: PeopleOpenCount
}

public struct PeopleOrgRow: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var people: Int
    public var isInternal: Bool
    public var open: Int
    public var last: Date?
}

public struct PeoplePlaceRow: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var people: Int
    public var open: Int
}

public struct PeopleDirectory: Sendable {
    public var people: [PeopleDirectoryRow] = []
    public var orgs: [PeopleOrgRow] = []
    public var places: [PeoplePlaceRow] = []
    public var openTotal: Int { people.reduce(0) { $0 + $1.open.count } }
    public init() {}
}

/// Why a person page shows nothing. The page text and the `[People]` log line both come from this.
public enum PeopleEmptyReason: String, Sendable, Hashable {
    case locked, mailNotStarted, noSelection, ownAddress, noMailInWindow, hiddenByLabels
}

public enum PeopleSurface {
    // MARK: Directory

    public static func directory(view: KnowledgeView, open: (KnowledgePerson) -> PeopleOpenCount,
                                 place: (KnowledgePerson) -> String?, query: String = "") -> PeopleDirectory {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var d = PeopleDirectory()
        var rows: [PeopleDirectoryRow] = []
        for p in view.people.values {
            let orgName = p.org.map { view.orgs[$0]?.name ?? MailDomains.name(fromDomain: $0) }
            let r = PeopleDirectoryRow(id: p.key, name: p.name, address: p.addresses.first ?? p.key, org: p.org, orgName: orgName,
                                       place: place(p), first: p.first, last: p.last, isInternal: p.isInternal, open: open(p))
            rows.append(r)
        }
        let all = rows
        if !q.isEmpty {
            rows = rows.filter { r in
                r.name.lowercased().contains(q) || r.address.contains(q) || (r.orgName?.lowercased().contains(q) ?? false)
                    || (r.place?.lowercased().contains(q) ?? false)
            }
        }
        d.people = rows.sorted(by: recent)
        // Organisations and places count over the whole directory (search narrows them by name only).
        var orgs: [String: PeopleOrgRow] = [:]
        for r in all {
            guard let o = r.org else { continue }
            var x = orgs[o] ?? PeopleOrgRow(id: o, name: r.orgName ?? o, people: 0, isInternal: false, open: 0, last: nil)
            x.people += 1; x.open += r.open.count; x.isInternal = x.isInternal || r.isInternal
            x.last = [x.last, r.last].compactMap { $0 }.max()
            orgs[o] = x
        }
        d.orgs = orgs.values.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.id.contains(q) }
            .sorted { ($0.last ?? .distantPast, $1.name) > ($1.last ?? .distantPast, $0.name) }
        var places: [String: PeoplePlaceRow] = [:]
        for r in all {
            guard let p = r.place?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { continue }
            var x = places[p] ?? PeoplePlaceRow(name: p, people: 0, open: 0)
            x.people += 1; x.open += r.open.count
            places[p] = x
        }
        d.places = places.values.filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted { ($0.people, $1.name) > ($1.people, $0.name) }
        return d
    }

    /// Most recent contact first; never-contacted last; ties by name then key (stable).
    static func recent(_ a: PeopleDirectoryRow, _ b: PeopleDirectoryRow) -> Bool {
        let x = a.last ?? .distantPast, y = b.last ?? .distantPast
        if x != y { return x > y }
        if a.name != b.name { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        return a.id < b.id
    }

    // MARK: Open counts

    /// Open loops through a `LoopSource` (every address of the person, deduplicated, open only).
    public static func loops(_ source: LoopSource, addresses: [String], account: String) -> [LoopSummary] {
        var seen: Set<String> = [], out: [LoopSummary] = []
        for a in addresses {
            for l in source.loops(involving: a.lowercased(), account: account) where l.isOpen && seen.insert(l.id).inserted { out.append(l) }
        }
        return out.sorted { ($0.due ?? .distantFuture, $0.id) < ($1.due ?? .distantFuture, $1.id) }
    }

    // MARK: Who owes whom

    /// Only conversations of `account` that are with this person count. Needs reply counts only when they were the
    /// last inbound sender (someone else in the thread asking doesn't make me owe *them*).
    public static func owes(addresses: Set<String>, conversations: Set<String>, account: String,
                            states: [PeopleConversation]) -> PeopleOwes {
        let mine = Set(addresses.map { $0.lowercased() })
        var o = PeopleOwes()
        var nudgeAt: Date?
        for c in states where c.account == account && conversations.contains(c.conversationId) {
            switch c.state {
            case .needsReply:
                guard let s = c.senderAddress?.lowercased(), mine.contains(s), !c.lastFromMe else { continue }
                o.youOwe += 1
                o.youOweSince = [o.youOweSince, c.since].compactMap { $0 }.min()
            case .waiting:
                guard c.lastFromMe else { continue }
                o.theyOwe += 1
                o.theyOweSince = [o.theyOweSince, c.since].compactMap { $0 }.min()
                if nudgeAt == nil || (c.since ?? .distantPast) > nudgeAt! { nudgeAt = c.since ?? .distantPast; o.nudgeMessageId = c.latestMessageId }
            case .fyi, .done: continue
            }
        }
        return o
    }

    // MARK: History

    /// Newest first; a group collapses to its newest item; protected items lose their title (metadata only).
    public static func history(_ inputs: [PeopleHistoryInput], limit: Int = 60) -> [PeopleHistoryItem] {
        var best: [String: PeopleHistoryInput] = [:]
        for i in inputs {
            let k = i.kind.rawValue + "|" + (i.group ?? i.ref)
            if let b = best[k], (b.date, b.ref) >= (i.date, i.ref) { continue }
            best[k] = i
        }
        let sorted = best.values.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            if a.kind != b.kind { return a.kind.order < b.kind.order }
            return a.ref < b.ref
        }
        return sorted.prefix(limit).map { i in
            PeopleHistoryItem(kind: i.kind, ref: i.ref, date: i.date, title: i.visible ? i.title : nil, link: i.link)
        }
    }

    /// Mail lines for a person from the knowledge engine (user tier): metadata-visible messages only, the subject only
    /// where its text is visible.
    public static func mailInputs(_ p: KnowledgePerson, engine: KnowledgeEngine) -> [PeopleHistoryInput] {
        p.messageIds.compactMap { id in
            guard let x = engine.message(id, tier: .user) else { return nil }
            return PeopleHistoryInput(kind: .mail, ref: id, date: x.m.received, title: x.m.subject,
                                      visible: engine.textVisible(id, tier: .user), group: x.m.conversationId)
        }
    }

    /// Meetings with any of these addresses; `redact` = the event's label hides details.
    public static func meetingInputs(_ events: [CalendarEvent], addresses: Set<String>, redact: (CalendarEvent) -> Bool) -> [PeopleHistoryInput] {
        let set = Set(addresses.map { $0.lowercased() })
        return events.filter { e in !e.isCancelled && e.attendees.contains { set.contains($0.address.lowercased()) } }
            .map { e in PeopleHistoryInput(kind: .meeting, ref: e.id, date: e.start, title: e.subject, visible: !redact(e)) }
    }

    public static func noteInputs(_ notes: [PeopleNoteRecord]) -> [PeopleHistoryInput] {
        notes.map { n in
            PeopleHistoryInput(kind: .note, ref: n.pageId, date: n.at, title: n.title, visible: true,
                               link: (n.clientUrl ?? n.webUrl).flatMap(URL.init(string:)))
        }
    }

    /// The next meeting with them (not cancelled, starting now or later).
    public static func nextMeeting(_ events: [CalendarEvent], addresses: Set<String>, now: Date) -> CalendarEvent? {
        let set = Set(addresses.map { $0.lowercased() })
        return events.filter { e in !e.isCancelled && e.end > now && e.attendees.contains { set.contains($0.address.lowercased()) } }
            .min { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    // MARK: Header facts

    /// "client since <year>": the year of first contact. `atWindowEdge` = first contact is within two weeks of the
    /// engine's look-back window, so the real start may be earlier ("since before …").
    public static func since(first: Date?, now: Date, windowDays: Int, calendar: Calendar = .current) -> (year: Int, atWindowEdge: Bool)? {
        guard let first else { return nil }
        let edge = now.addingTimeInterval(-Double(windowDays) * 86_400 + 14 * 86_400)
        return (calendar.component(.year, from: first), first <= edge)
    }

    // MARK: Empty state + diagnostic

    public static func emptyReason(address: String?, locked: Bool, mailStarted: Bool, owners: Set<String>,
                                   known: Bool, visible: Bool) -> PeopleEmptyReason? {
        if locked { return .locked }
        if !mailStarted { return .mailNotStarted }
        guard let a = address?.lowercased(), !a.isEmpty else { return .noSelection }
        if owners.contains(a) { return .ownAddress }
        if visible { return nil }
        return known ? .hiddenByLabels : .noMailInWindow
    }

    /// Counts only: `[People] directory=N open=M personPage=ok|empty(reason)|none`.
    public static func diagnostic(directory: Int, open: Int, page: PeopleEmptyReason?, pageShown: Bool) -> String {
        let p = !pageShown ? "none" : page.map { "empty(\($0.rawValue))" } ?? "ok"
        return "[People] directory=\(directory) open=\(open) personPage=\(p)"
    }
}
