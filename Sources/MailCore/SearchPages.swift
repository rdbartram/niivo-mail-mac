import Foundation

// View-models for the search UI's person / company / project pages (SearchViews.swift). UI-free and computed from
// the local cache for the USER (persist policy applies; this is not an AI path — the tools have their own gated
// versions in OfficeTools). Bounded: every list is capped, every lookup is an exact blind-token query.

public struct ThreadSummary: Sendable, Hashable, Identifiable {
    public var conversationId: String
    public var latest: MailMessage
    public var count: Int
    /// The newest message is from the other side (you owe a reply) / from you (they owe one).
    public var awaitingMe: Bool
    public var id: String { conversationId }
}

public struct PersonRef: Sendable, Hashable, Identifiable {
    public var address: String
    public var name: String
    public var count: Int
    public var id: String { address }
}

public struct CompanyRef: Sendable, Hashable, Identifiable {
    public var domain: String
    public var name: String
    public var count: Int
    public var id: String { domain }
}

public struct PersonPage: Sendable, Hashable {
    public var address: String
    public var name: String
    public var isInternal: Bool
    public var company: CompanyRef?
    public var received: Int
    public var sent: Int
    public var firstContact: Date?
    public var lastContact: Date?
    /// "yyyy-MM" → (received, sent), newest first, ≤ 12.
    public var months: [MonthCount]
    public var openThreads: [ThreadSummary]
    public var recent: [MailMessage]
    public var relatedPeople: [PersonRef]
    public var projects: [GraphProject]
}

public struct MonthCount: Sendable, Hashable, Identifiable {
    public var month: String
    public var received: Int
    public var sent: Int
    public var id: String { month }
}

public struct CompanyPage: Sendable, Hashable {
    public var domain: String
    public var name: String
    public var isInternal: Bool
    public var people: [PersonRef]
    public var threads: [ThreadSummary]
    public var openThreads: [ThreadSummary]
    public var lastActivity: Date?
    public var messageCount: Int
    public var projects: [GraphProject]
}

public struct ProjectPage: Sendable, Hashable {
    public var project: GraphProject
    public var threads: [ThreadSummary]
    public var people: [PersonRef]
    public var companies: [CompanyRef]
    public var lastActivity: Date?
    public var messageCount: Int
}

public enum SearchPages {
    static func threads(_ msgs: [MailMessage], store: MailStore, owner: (MailMessage) -> Bool, limit: Int = 15) -> [ThreadSummary] {
        Dictionary(grouping: msgs, by: \.conversationId).compactMap { id, ms -> ThreadSummary? in
            guard let newest = ms.max(by: { $0.received < $1.received }) else { return nil }
            return ThreadSummary(conversationId: id, latest: newest, count: ms.count, awaitingMe: !owner(newest))
        }.sorted { $0.latest.received > $1.latest.received }.prefix(limit).map { $0 }
    }

    static func ownerSent(_ store: MailStore, mailbox: String) -> (MailMessage) -> Bool {
        let sentIds = Set(((try? store.folders(mailbox: mailbox)) ?? []).filter { $0.wellKnown == .sentitems }.map(\.id))
        let owners = store.graph?.owners ?? []
        return { m in sentIds.contains(m.folderId) || owners.contains(m.from?.address.lowercased() ?? "") }
    }

    static func projects(of msgs: [MailMessage], graph: CommGraph?, limit: Int = 8) -> [GraphProject] {
        guard let graph else { return [] }
        var counts: [String: Int] = [:], convSeen = Set<String>()
        for m in msgs where convSeen.insert(m.conversationId).inserted {
            for p in graph.projectIds(conversation: m.conversationId) { counts[p, default: 0] += 1 }
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map { k, v in
            GraphProject(id: k, kind: k.hasPrefix("cat:") ? .category : k.hasPrefix("fld:") ? .folder : .topic,
                         name: graph.projectName(k), conversations: v, lastActivity: .distantPast)
        }
    }

    public static func person(_ address: String, store: MailStore, mailbox: String = "me", now: Date = Date()) -> PersonPage {
        let a = address.lowercased()
        let isOwner = ownerSent(store, mailbox: mailbox)
        let received = store.messages(matching: [.from(a)], mailbox: mailbox, limit: 2_000).filter { !isOwner($0) }
        let sent = store.messages(matching: [.recipient(a)], mailbox: mailbox, limit: 2_000).filter(isOwner)
        let all = (received + sent).sorted { $0.received > $1.received }
        let g = store.graph
        let node = g?.person(a)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.locale = Locale(identifier: "en_US_POSIX")
        var months: [String: (Int, Int)] = [:]
        for m in received { months[f.string(from: m.received), default: (0, 0)].0 += 1 }
        for m in sent { months[f.string(from: m.received), default: (0, 0)].1 += 1 }
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let threads = threads(all, store: store, owner: isOwner, limit: 50)
        let related = (g?.neighbours(of: a, limit: 8) ?? []).map { nb in
            PersonRef(address: nb.address, name: g?.person(nb.address)?.displayName ?? nb.address, count: nb.count)
        }
        let company = MailDomains.companyKey(for: a).map { d in
            CompanyRef(domain: d, name: g?.company(d)?.displayName ?? MailDomains.name(fromDomain: d), count: g?.company(d)?.total.n ?? 0)
        }
        return PersonPage(address: a, name: node?.displayName ?? (received.first?.from?.name ?? a),
                          isInternal: MailDomains.isInternal(a, internalDomains: g?.internalDomains ?? []),
                          company: company, received: received.count, sent: sent.count,
                          firstContact: all.last?.received, lastContact: all.first?.received,
                          months: months.sorted { $0.key > $1.key }.prefix(12).map { MonthCount(month: $0.key, received: $0.value.0, sent: $0.value.1) },
                          openThreads: threads.filter { $0.latest.received >= cutoff },
                          recent: Array(all.prefix(10)), relatedPeople: related, projects: projects(of: all, graph: g))
    }

    public static func company(_ domain: String, store: MailStore, mailbox: String = "me", now: Date = Date()) -> CompanyPage {
        let d = domain.lowercased()
        let g = store.graph
        let isOwner = ownerSent(store, mailbox: mailbox)
        let msgs = store.messages(matching: [.domain(d)], mailbox: mailbox, limit: 2_000)
        var people: [String: (String, Int)] = [:]
        for m in msgs {
            for a in [m.from].compactMap({ $0 }) + m.toRecipients + m.ccRecipients where MailDomains.companyKey(for: a.address) == d {
                let k = a.address.lowercased()
                people[k] = (people[k]?.0.isEmpty == false ? people[k]!.0 : a.name, (people[k]?.1 ?? 0) + 1)
            }
        }
        let threads = threads(msgs, store: store, owner: isOwner, limit: 50)
        let node = g?.company(d)
        return CompanyPage(domain: d, name: node?.displayName ?? MailDomains.name(fromDomain: d),
                           isInternal: MailDomains.isInternal("x@" + d, internalDomains: g?.internalDomains ?? []),
                           people: people.sorted { ($0.value.1, $1.key) > ($1.value.1, $0.key) }.prefix(20).map {
                               PersonRef(address: $0.key, name: $0.value.0.isEmpty ? $0.key : $0.value.0, count: $0.value.1)
                           },
                           threads: Array(threads.prefix(15)),
                           openThreads: threads.filter { $0.latest.received >= now.addingTimeInterval(-30 * 86_400) },
                           lastActivity: msgs.first?.received, messageCount: msgs.count, projects: projects(of: msgs, graph: g))
    }

    public static func project(_ id: String, store: MailStore, mailbox: String = "me") -> ProjectPage? {
        guard let g = store.graph, let p = g.resolveProject(id).first else { return nil }
        let msgs: [MailMessage]
        switch p.kind {
        case .category: msgs = store.messages(matching: [.category(String(p.id.dropFirst(4)))], mailbox: mailbox, limit: 1_000)
        case .folder: msgs = (try? store.messages(folderId: String(p.id.dropFirst(4)), limit: 1_000)) ?? []
        case .topic: msgs = store.messages(matching: [.term(String(p.id.dropFirst(2)))], mailbox: mailbox, limit: 1_000)
        }
        let isOwner = ownerSent(store, mailbox: mailbox)
        var people: [String: (String, Int)] = [:], companies: [String: Int] = [:]
        for m in msgs {
            for a in [m.from].compactMap({ $0 }) + m.toRecipients + m.ccRecipients {
                let k = a.address.lowercased()
                guard !k.isEmpty, !g.isOwner(k, mailbox: mailbox) else { continue }
                people[k] = (people[k]?.0.isEmpty == false ? people[k]!.0 : a.name, (people[k]?.1 ?? 0) + 1)
                if let d = MailDomains.companyKey(for: k) { companies[d, default: 0] += 1 }
            }
        }
        return ProjectPage(project: p, threads: threads(msgs, store: store, owner: isOwner, limit: 20),
                           people: people.sorted { ($0.value.1, $1.key) > ($1.value.1, $0.key) }.prefix(15).map {
                               PersonRef(address: $0.key, name: $0.value.0.isEmpty ? $0.key : $0.value.0, count: $0.value.1)
                           },
                           companies: companies.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(10).map {
                               CompanyRef(domain: $0.key, name: g.company($0.key)?.displayName ?? MailDomains.name(fromDomain: $0.key), count: $0.value)
                           },
                           lastActivity: msgs.first?.received, messageCount: msgs.count)
    }
}
