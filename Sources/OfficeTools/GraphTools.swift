import Foundation
import CalendarCore
import MailCore

// search (ranked, faceted) and company_context. The graph only proposes candidates; every number and item returned
// is recomputed from messages that passed the AI gate (recipient-derived facts only from full-exposure messages).
extension MCPServer {

    /// The gate as a SearchEngine caller.
    var searchCaller: SearchCaller {
        let g = gate
        return .ai { m, mb in
            guard let (r, ex) = g.mail(m, mailbox: mb) else { return nil }
            return (r, ex == .full ? .full : .metadata)
        }
    }

    func searchTool(_ a: Args) async throws -> ToolOutput {
        let q = try a.required("query", max: 300).trimmingCharacters(in: .whitespaces)
        let limit = try a.int("limit", default: 10, range: 1...25)
        let mb = try await resolveMailbox(a.string("mailbox", max: 254))
        let wantFacets = try a.bool("facets") ?? true
        let semantic = try a.bool("semantic") ?? true
        let parsed = SearchQuery.parse(q + " ")   // complete words: no prefix matching for tools
        guard !parsed.isEmpty else { throw ToolFailure("Give search words or filters.", "error:invalid-args") }
        if let f = parsed.folder, let folder = folderByName(f, mailbox: mb) { await ensureOpened(folder) }
        // Embed what arrived since the last call (folders opened on demand), bounded so the call stays quick.
        if semantic, let sem = backend.store.semantic { _ = try? sem.catchUp(maxItems: 64) }
        var o = SearchEngine.Options(mailbox: mb, limit: limit, caller: searchCaller)
        o.semantic = semantic
        // SEARCHQ-HOOK: agents ask in natural language too ("invoice from X last week"): relaxed matching with
        // DE/EN/FR/IT expansions unless the caller asks for every word ("match": "all").
        if (try a.string("match", max: 10)) != "all" { o.match = .natural }
        let labels = backend.engine.availableLabels()
        o.labelName = { id in labels.first { $0.id.lowercased() == id.lowercased() }?.name }
        let r = SearchEngine(store: backend.store).search(parsed, o)
        let items: [JSON] = r.hits.map { h in
            var j = render(h.message, h.exposure == .full ? .full : .metadata, mailbox: mb)
            if case .object(var obj) = j {
                obj["rank"] = ["score": .double((h.score * 10_000).rounded() / 10_000),
                               "keyword_rank": h.keywordRank.map { .int($0) } ?? .null,
                               "semantic_rank": h.semanticRank.map { .int($0) } ?? .null]
                j = .object(obj)
            }
            return j
        }
        let meta = r.hits.filter { $0.exposure == .metadata }.count
        var payload: [String: JSON] = [
            "mailbox": .string(mb), "results": .array(items), "total_matches": .int(r.total),
            "total_is_capped": .bool((o.match == .all && r.keywordCandidates >= SearchEngine.keywordPool) || r.total >= SearchEngine.decryptPool),
            "semantic_used": .bool(r.usedSemantic), "restricted_not_shown": .int(r.restricted), "notice": restrictedNotice(r.restricted),
            "scope": "Local encrypted cache of this mailbox (headers in the cache window). Ranked: BM25 + on-device semantic match (content-visible items only), fused, with recency.",
        ]
        if wantFacets { payload["facets"] = facetsJSON(r.facets) }
        return ToolOutput(payload: .object(payload), ids: r.hits.map(\.id), shown: items.count, restricted: r.restricted,
                          decision: decision(shown: items.count, meta: meta, hidden: r.restricted))
    }

    func facetsJSON(_ f: SearchFacets) -> JSON {
        func list(_ v: [FacetValue]) -> JSON {
            .array(v.map { x in
                var o: [String: JSON] = ["value": .string(Untrusted.line(x.key, max: 254)), "label": .string(Untrusted.line(x.label, max: 120)), "count": .int(x.count)]
                if let r = x.refinement { o["refine"] = .string(Untrusted.line(r, max: 300)) }
                return .object(o)
            })
        }
        return ["people": list(f.people), "companies": list(f.companies), "projects": list(f.projects), "date": list(f.dates),
                "attachments": list(f.attachments), "labels": list(f.labels), "folders": list(f.folders), "mailboxes": list(f.mailboxes)]
    }

    func companyContext(_ a: Args) async throws -> ToolOutput {
        let q = try a.required("company", max: 254).trimmingCharacters(in: .whitespaces).lowercased()
        let mb = try await resolveMailbox(a.string("mailbox", max: 254))
        if let sent = try? backend.store.folder(wellKnown: .sentitems, mailbox: mb) { await ensureOpened(sent) }
        let store = backend.store
        // Domain: given directly (or via an address), else resolved by name through the graph.
        var domain: String?
        if q.contains("@") { domain = MailDomains.companyKey(for: q) }
        else if q.contains(".") { domain = MailDomains.isFreeMail(registrable: MailDomains.registrable(q)) ? nil : MailDomains.registrable(q) }
        else { domain = store.graph?.resolveCompany(q).first?.domain }
        guard let domain else {
            throw ToolFailure("Unknown company. Give its domain (e.g. contoso.com) or an address; free-mail domains aren't companies.", "error:unknown-company")
        }
        let rows = store.messages(matching: [.domain(domain)], mailbox: mb, limit: 2_000)
        var hidden = 0
        var visible: [(MailMessage, MailMessage, Exposure)] = []
        for m in rows {
            guard let (r, ex) = gate.mail(m, mailbox: mb) else { hidden += 1; continue }
            // Recipient-only matches count only when the caller may see recipients.
            let fromMatch = MailDomains.companyKey(for: m.from?.address ?? "") == domain
            if !fromMatch && ex != .full { continue }
            visible.append((m, r, ex))
        }
        if visible.isEmpty {
            throw ToolFailure("Unknown company. Give its domain (e.g. contoso.com) or an address; free-mail domains aren't companies.", "error:unknown-company")
        }
        var people: [String: (name: String, n: Int, last: Date)] = [:]
        for (m, _, ex) in visible {
            var addrs = [m.from].compactMap { $0 }
            if ex == .full { addrs += m.toRecipients + m.ccRecipients }
            for p in addrs where MailDomains.companyKey(for: p.address) == domain {
                let k = p.address.lowercased()
                let cur = people[k]
                people[k] = (cur?.name.isEmpty == false ? cur!.name : p.name, (cur?.n ?? 0) + 1, max(cur?.last ?? .distantPast, m.received))
            }
        }
        let byConv = Dictionary(grouping: visible, by: { $0.0.conversationId })
        let threads = byConv.map { (id, ms) -> (Date, JSON) in
            let newest = ms.max { $0.0.received < $1.0.received }!
            return (newest.0.received, ["conversation_id": .string(id), "messages": .int(ms.count), "last_activity": .date(newest.0.received),
                                        "latest": render(newest.1, newest.2, mailbox: mb)])
        }.sorted { $0.0 > $1.0 }
        // Open items: last 30 days, by conversation state (TRIAGE2-HOOK): needsReply → awaiting you; waiting with a
        // badge (asked something, or unanswered for N working days) → awaiting them; flagged.
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        var awaitingMe: [JSON] = [], awaitingThem: [JSON] = []
        for (cid, ms) in byConv {
            guard let newest = ms.max(by: { $0.0.received < $1.0.received }), newest.0.received >= cutoff,
                  let d = triageDecision(conversationId: cid, mailbox: mb) else { continue }
            if d.state == .needsReply { awaitingMe.append(render(newest.1, newest.2, mailbox: mb)) }
            else if d.state == .waiting, d.showsBadge { awaitingThem.append(render(newest.1, newest.2, mailbox: mb)) }
        }
        let flagged = visible.filter { $0.0.flag.status == .flagged }.sorted { $0.0.received > $1.0.received }.prefix(5).map { render($0.1, $0.2, mailbox: mb) }
        let internalCo = MailDomains.isInternal("x@" + domain, internalDomains: backend.internalDomains)
        let payload: JSON = [
            "domain": .string(Untrusted.line(domain, max: 254)),
            "name": .string(Untrusted.line(companyName(domain, from: visible.map(\.1)), max: 120)),
            "internal": .bool(internalCo),
            "people": .array(people.sorted { ($0.value.n, $1.key) > ($1.value.n, $0.key) }.prefix(15).map {
                ["address": .string(Untrusted.line($0.key, max: 254)), "name": .string(Untrusted.line($0.value.name, max: 100)),
                 "messages": .int($0.value.n), "last_contact": .date($0.value.last)]
            }),
            "threads": .array(threads.prefix(10).map(\.1)), "thread_count": .int(threads.count),
            "messages": .int(visible.count), "last_activity": .date(threads.first?.0),
            "open_items": ["awaiting_me": .array(Array(awaitingMe.prefix(5))), "awaiting_them": .array(Array(awaitingThem.prefix(5))),
                           "flagged": .array(Array(flagged))],
            "projects": .array(projectsOf(visible, mailbox: mb).prefix(8).map {
                ["project": .string(Untrusted.line($0.id, max: 200)), "name": .string(Untrusted.line($0.name, max: 120)), "messages": .int($0.count)]
            }),
            "restricted_not_shown": .int(hidden), "notice": restrictedNotice(hidden),
            "scope": "Cached headers in this mailbox from or (where details may be shown) to addresses at this domain.",
        ]
        return ToolOutput(payload: payload, ids: visible.prefix(50).map(\.0.id), shown: visible.count, restricted: hidden,
                          decision: "ok:company,shown=\(visible.count),hidden=\(hidden)")
    }
}
