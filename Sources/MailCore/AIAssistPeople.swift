import Foundation

/// History with one correspondent, computed locally from cached headers (no bodies). `visible` is the AI gate:
/// messages it rejects are left out of every statistic and only counted in `restricted`.
public struct PeopleHistory: Sendable, Hashable {
    public var address: String
    public var isInternal: Bool
    public var firstContact: Date?
    public var lastContact: Date?
    public var receivedCount: Int
    public var sentCount: Int
    /// "yyyy-MM" → (received, sent), newest month first.
    public var byMonth: [(month: String, received: Int, sent: Int)]
    /// Conversations whose newest message came from them (you owe a reply), newest first. Last 30 days.
    public var awaitingMe: [MailMessage]
    /// Conversations whose newest message came from you (they owe a reply). Last 30 days.
    public var awaitingThem: [MailMessage]
    /// Median minutes between their message and your next reply in the same conversation.
    public var medianReplyMinutes: Int?
    /// Last N exchanges, both directions, newest first.
    public var recent: [(message: MailMessage, fromThem: Bool)]
    public var restricted: Int

    public static func == (a: Self, b: Self) -> Bool { a.address == b.address && a.receivedCount == b.receivedCount && a.sentCount == b.sentCount && a.lastContact == b.lastContact }
    public func hash(into h: inout Hasher) { h.combine(address); h.combine(receivedCount); h.combine(sentCount) }

    /// TRIAGE2-HOOK: rules over (message, fromThem) pairs. Metadata only (no cue bits): this path can't tell which
    /// tier the result goes to, so it never reads text.
    static func localDecision(_ asc: [(MailMessage, Bool)], now: Date, calendar: Calendar) -> TriageDecision? {
        let mine = Set(asc.filter { !$0.1 }.map(\.0.id))
        let inbound = Set(asc.filter(\.1).map(\.0.folderId))
        let owners = Set(asc.filter { !$0.1 }.compactMap { $0.0.from?.address.lowercased() })
        let inputs = TriageInputs(account: "local", isMine: { mine.contains($0.id) }, myAddresses: owners,
                                  folderRole: { inbound.contains($0) ? .inbox : nil }, exposure: { _ in .metadata })
        guard let f = ConversationFactsBuilder.build(conversationId: asc.first?.0.conversationId ?? "", messages: asc.map(\.0), inputs: inputs) else { return nil }
        return TriageRules.decide(f, now: now, calendar: calendar)
    }

    public static func isInternal(_ address: String, internalDomains: Set<String>) -> Bool {
        let d = address.lowercased().split(separator: "@").last.map(String.init) ?? ""
        return internalDomains.contains { d == $0.lowercased() || d.hasSuffix("." + $0.lowercased()) }
    }

    /// Candidate headers from the store: the blind index (sender tokens) for received mail, the Sent folder for
    /// sent mail (recipients aren't indexed). Bounded: `sentScan` rows of Sent, 500 search hits.
    /// `recipients` must return only what the gate lets the AI see (full exposure), so metadata-only messages never
    /// match on their (withheld) recipients.
    public static func candidates(store: MailStore, mailbox: String, address: String, sentScan: Int = 2_000,
                                  recipients: (MailMessage) -> [EmailAddress]) -> (received: [MailMessage], sent: [MailMessage]) {
        let a = address.lowercased()
        let received = ((try? store.search(address, mailbox: mailbox, limit: 500)) ?? []).filter { $0.from?.address.lowercased() == a }
        var sent: [MailMessage] = []
        if let f = try? store.folder(wellKnown: .sentitems, mailbox: mailbox) {
            sent = ((try? store.messages(folderId: f.id, limit: sentScan)) ?? [])
                .filter { recipients($0).contains { $0.address.lowercased() == a } }
        }
        return (received, sent)
    }

    public static func compute(address: String, received: [MailMessage], sent: [MailMessage], internalDomains: Set<String>,
                               now: Date = Date(), lastN: Int = 6, calendar: Calendar = .current,
                               visible: (MailMessage) -> Bool,
                               triage: ((String) -> TriageDecision?)? = nil) -> PeopleHistory {
        let r = received.filter(visible), s = sent.filter(visible)
        let restricted = (received.count - r.count) + (sent.count - s.count)
        let all = (r.map { ($0, true) } + s.map { ($0, false) }).sorted { $0.0.received > $1.0.received }
        var months: [String: (Int, Int)] = [:]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        for (m, them) in all {
            let k = f.string(from: m.received)
            var v = months[k] ?? (0, 0)
            if them { v.0 += 1 } else { v.1 += 1 }
            months[k] = v
        }
        var awaitingMe: [MailMessage] = [], awaitingThem: [MailMessage] = []
        var replyDeltas: [Double] = []
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        for (_, msgs) in Dictionary(grouping: all, by: { $0.0.conversationId }) {
            let asc = msgs.sorted { $0.0.received < $1.0.received }
            for i in asc.indices where asc[i].1 {
                if let next = asc[(i + 1)...].first(where: { !$0.1 }) { replyDeltas.append(next.0.received.timeIntervalSince(asc[i].0.received)) }
            }
            // TRIAGE2-HOOK: "awaiting" reads the conversation state (plan §1.1 #10): awaiting me = needsReply, awaiting
            // them = waiting with a badge (asked something, or N working days unanswered). Without a `triage` source
            // the same rules run over these visible messages (received = inbox, sent = mine).
            if let last = asc.last, last.0.received >= cutoff {
                let d = triage?(last.0.conversationId) ?? Self.localDecision(asc, now: now, calendar: calendar)
                if d?.state == .needsReply { awaitingMe.append(last.0) }
                else if d?.state == .waiting, d?.showsBadge == true { awaitingThem.append(last.0) }
            }
        }
        replyDeltas.sort()
        let median = replyDeltas.isEmpty ? nil : Int(replyDeltas[replyDeltas.count / 2] / 60)
        return PeopleHistory(address: address.lowercased(), isInternal: isInternal(address, internalDomains: internalDomains),
                             firstContact: all.last?.0.received, lastContact: all.first?.0.received,
                             receivedCount: r.count, sentCount: s.count,
                             byMonth: months.sorted { $0.key > $1.key }.map { ($0.key, $0.value.0, $0.value.1) },
                             awaitingMe: awaitingMe.sorted { $0.received > $1.received },
                             awaitingThem: awaitingThem.sorted { $0.received > $1.received },
                             medianReplyMinutes: median, recent: Array(all.prefix(lastN)).map { ($0.0, $0.1) }, restricted: restricted)
    }
}
