import Foundation
import CalendarCore
import MailCore

// mail_search (filters), people_history, project_context. Same gate + untrusted rendering as every other tool.
extension MCPServer {
    func folderByName(_ name: String, mailbox: String) -> MailFolder? {
        let n = name.lowercased()
        let fs = (try? backend.store.folders(mailbox: mailbox)) ?? []
        return fs.first { $0.wellKnown?.rawValue == n || $0.id == name } ?? fs.first { $0.displayName.lowercased() == n }
            ?? fs.first { $0.displayName.lowercased().contains(n) }
    }

    /// A folder's headers are only in the store once the folder has been opened (synced) once.
    func ensureOpened(_ f: MailFolder) async {
        guard !openedFolders.contains(f.id) else { return }
        openedFolders.insert(f.id)
        if f.wellKnown != .inbox { await backend.sync.openFolder(f.id) }
    }

    /// Recipient filters may only look at recipients the gate would show (full exposure).
    func recipientsVisible(_ m: MailMessage, mailbox: String) -> [EmailAddress] {
        guard let (_, ex) = gate.mail(m, mailbox: mailbox), ex == .full else { return [] }
        return m.toRecipients + m.ccRecipients
    }

    func mailSearch(_ a: Args) async throws -> ToolOutput {
        let q = try a.string("query", max: 200)?.trimmingCharacters(in: .whitespaces) ?? ""
        let limit = try a.int("limit", default: 10, range: 1...25)
        let mb = try await resolveMailbox(a.string("mailbox", max: 254))
        let from = try a.string("from", max: 254)?.lowercased(), to = try a.string("to", max: 254)?.lowercased()
        let after = try a.date("after", required: false), before = try a.date("before", required: false)
        let folderName = try a.string("folder", max: 120)
        let hasAtt = try a.bool("has_attachments"), unread = try a.bool("is_unread")
        let labelName = try a.string("label", max: 120)?.lowercased()
        let folder = try folderName.map { n -> MailFolder in
            guard let f = folderByName(n, mailbox: mb) else { throw ToolFailure("Unknown folder.", "error:unknown-folder") }
            return f
        }
        let text = [q, from ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        var rows: [MailMessage]
        if text.isEmpty {
            // Filter-only: newest headers of the folder (default Inbox), keyset-paged locally.
            let f = try folder ?? backend.store.folder(wellKnown: .inbox, mailbox: mb)
            guard let f else { throw ToolFailure("Give a query or a folder.", "error:invalid-args") }
            await ensureOpened(f)
            rows = (try? backend.store.messages(folderId: f.id, limit: 500)) ?? []
        } else {
            rows = await backend.sync.search(text, mailbox: mb, limit: min(100, limit * 4), includeServer: true)
            let unknown = rows.filter { (try? backend.store.message(id: $0.id, includeBody: false)) == nil }
            if !unknown.isEmpty { try? backend.store.upsert(messages: unknown) }
        }
        let labels = backend.engine.availableLabels()
        rows = rows.filter { m in
            if let after, m.received < after { return false }
            if let before, m.received >= before { return false }
            if let folder, m.folderId != folder.id { return false }
            if let hasAtt, m.hasAttachments != hasAtt { return false }
            if let unread, m.isRead == unread { return false }
            if let from, !(((m.from?.address ?? "") + " " + (m.from?.name ?? "")).lowercased().contains(from)) { return false }
            if let to, !recipientsVisible(m, mailbox: mb).contains(where: { ($0.address + " " + $0.name).lowercased().contains(to) }) { return false }
            if let labelName {
                guard let id = m.labelId?.lowercased(), let l = labels.first(where: { $0.id.lowercased() == id }),
                      l.name.lowercased().contains(labelName) else { return false }
            }
            return true
        }
        // Gate BEFORE the limit so restricted rows don't eat result slots, then cap.
        let g = gateList(rows, mailbox: mb)
        let items = Array(g.items.prefix(limit)), ids = Array(g.ids.prefix(limit))
        let meta = g.meta
        return ToolOutput(payload: ["mailbox": .string(mb), "messages": .array(items), "restricted_not_shown": .int(g.hidden),
                                    "notice": restrictedNotice(g.hidden)],
                          ids: ids, shown: items.count, restricted: g.hidden,
                          decision: decision(shown: items.count, meta: min(meta, items.count), hidden: g.hidden))
    }

    /// Owner-sent: in Sent Items, or from the signed-in user / the shared mailbox itself.
    func isOwnerSent(_ m: MailMessage, mailbox: String) -> Bool {
        let f = m.from?.address.lowercased() ?? ""
        if f == backend.me.address.lowercased() || (mailbox != "me" && f == mailbox.lowercased()) { return true }
        return (try? backend.store.folder(id: m.folderId))??.wellKnown == .sentitems
    }

    func peopleHistory(_ a: Args) async throws -> ToolOutput {
        let addr = try a.required("address", max: 254).trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.validAddress(addr) else { throw ToolFailure("'address' must be an email address.", "error:invalid-args") }
        let mb = try await resolveMailbox(a.string("mailbox", max: 254))
        let n = try a.int("recent", default: 6, range: 0...15)
        if let sent = try? backend.store.folder(wellKnown: .sentitems, mailbox: mb) { await ensureOpened(sent) }
        // Candidates from exact blind tokens (f:addr / r:addr), not a bounded Sent scan. Recipients only count
        // where the gate shows them (full exposure).
        let store = backend.store
        let received = store.messages(matching: [.from(addr)], mailbox: mb, limit: 2_000).filter { !isOwnerSent($0, mailbox: mb) }
        let sent = store.messages(matching: [.recipient(addr)], mailbox: mb, limit: 2_000).filter { m in
            isOwnerSent(m, mailbox: mb) && recipientsVisible(m, mailbox: mb).contains { $0.address.lowercased() == addr }
        }
        let h = PeopleHistory.compute(address: addr, received: received, sent: sent, internalDomains: backend.internalDomains,
                                      lastN: n, visible: { [gate] m in gate.mail(m, mailbox: mb) != nil },
                                      triage: { self.triageDecision(conversationId: $0, mailbox: mb) })   // TRIAGE2-HOOK
        func render(_ m: MailMessage) -> JSON {
            guard let (r, ex) = gate.mail(m, mailbox: mb) else { return .null }
            return self.render(r, ex, mailbox: mb)
        }
        let visible = (received + sent).compactMap { m in gate.mail(m, mailbox: mb).map { (m, $0.0, $0.1) } }
        let recent = h.recent.map { e -> JSON in ["direction": .string(e.fromThem ? "from_them" : "from_me"), "message": render(e.message)] }
        var payload: [String: JSON] = [
            "address": .string(h.address), "internal": .bool(h.isInternal),
            "first_contact": .date(h.firstContact), "last_contact": .date(h.lastContact),
            "received": .int(h.receivedCount), "sent": .int(h.sentCount),
            "by_month": .array(h.byMonth.prefix(12).map { ["month": .string($0.month), "received": .int($0.received), "sent": .int($0.sent)] }),
            "median_reply_minutes": h.medianReplyMinutes.map { .int($0) } ?? .null,
            "awaiting_me": .array(h.awaitingMe.prefix(5).map(render)), "awaiting_them": .array(h.awaitingThem.prefix(5).map(render)),
            "recent": .array(recent), "restricted_not_shown": .int(h.restricted), "notice": restrictedNotice(h.restricted),
            "scope": "Cached headers in this mailbox (local encrypted index: messages from them, and your sent messages to them).",
        ]
        if let d = MailDomains.companyKey(for: addr) {
            payload["company"] = ["domain": .string(Untrusted.line(d, max: 254)),
                                  "name": .string(Untrusted.line(companyName(d, from: visible.map(\.1)), max: 120))]
        }
        payload["related_people"] = .array(relatedPeople(addr, mailbox: mb).map {
            ["address": .string(Untrusted.line($0.0, max: 254)), "shared_messages": .int($0.1)]
        })
        payload["projects"] = .array(projectsOf(visible, mailbox: mb).prefix(10).map {
            ["project": .string(Untrusted.line($0.id, max: 200)), "name": .string(Untrusted.line($0.name, max: 120)), "messages": .int($0.count)]
        })
        let ids = h.recent.map(\.message.id)
        return ToolOutput(payload: .object(payload), ids: ids, shown: h.receivedCount + h.sentCount, restricted: h.restricted,
                          decision: "ok:people,shown=\(h.receivedCount + h.sentCount),hidden=\(h.restricted)")
    }

    /// Graph neighbours, each re-verified against messages the gate shows in full (both addresses visible).
    func relatedPeople(_ addr: String, mailbox mb: String, limit: Int = 8) -> [(String, Int)] {
        guard let g = backend.store.graph else { return [] }
        var out: [(String, Int)] = []
        for nb in g.neighbours(of: addr, limit: 20) where !g.isOwner(nb.address, mailbox: mb) {
            let st = backend.store
            var seen = Set<String>(), shared = 0
            for pair in [[SearchToken.from(addr), .recipient(nb.address)], [.from(nb.address), .recipient(addr)], [.recipient(addr), .recipient(nb.address)]] {
                for m in st.messages(matching: pair, mailbox: mb, limit: 200) where seen.insert(m.id).inserted {
                    guard let (_, ex) = gate.mail(m, mailbox: mb), ex == .full else { continue }
                    shared += 1
                }
            }
            if shared > 0 { out.append((nb.address, shared)) }
        }
        return Array(out.sorted { ($0.1, $1.0) > ($1.1, $0.0) }.prefix(limit))
    }

    /// Projects (categories, user folders, topics) of gated messages. Topics come from the subject, so they only
    /// count where the caller sees the real subject.
    func projectsOf(_ visible: [(MailMessage, MailMessage, Exposure)], mailbox: String) -> [(id: String, name: String, count: Int)] {
        let g = backend.store.graph
        let topicIds = Set(g?.topics(limit: 2_000).map(\.id) ?? [])
        var counts: [String: Int] = [:], names: [String: String] = [:], convCache: [String: [String]] = [:]
        for (m, r, _) in visible {
            var ids = Set<String>()
            for c in r.categories { ids.insert("cat:" + c.lowercased()); names["cat:" + c.lowercased()] = c }
            if let f = try? backend.store.folder(id: m.folderId), f.wellKnown == nil { ids.insert("fld:" + f.id); names["fld:" + f.id] = f.displayName }
            if let g, r.subject == m.subject {
                let ts = convCache[m.conversationId] ?? (g.conversation(m.conversationId)?.terms.map { "t:" + $0 }.filter { topicIds.contains($0) } ?? [])
                convCache[m.conversationId] = ts
                // The conversation's terms come from its first message; keep only terms this subject shows.
                let own = Set(BlindIndex.tokenize(r.subject))
                for t in ts where own.contains(String(t.dropFirst(2))) { ids.insert(t); names[t] = String(t.dropFirst(2)) }
            }
            for i in ids { counts[i, default: 0] += 1 }
        }
        return counts.map { (id: $0.key, name: names[$0.key] ?? g?.projectName($0.key) ?? $0.key, count: $0.value) }
            .sorted { ($0.count, $1.id) > ($1.count, $0.id) }
    }

    /// Organisation name from display names the caller can see ("… | Acme AG"), else from the domain.
    func companyName(_ domain: String, from msgs: [MailMessage]) -> String {
        var names: [String: Int] = [:]
        for m in msgs {
            for a in [m.from].compactMap({ $0 }) + m.toRecipients + m.ccRecipients
            where MailDomains.companyKey(for: a.address) == domain {
                if let o = MailDomains.orgName(fromDisplayName: a.name) { names[o, default: 0] += 1 }
            }
        }
        return names.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? MailDomains.name(fromDomain: domain)
    }

    func projectContext(_ a: Args) async throws -> ToolOutput {
        let mb = try await resolveMailbox(a.string("mailbox", max: 254))
        let keyword = try a.string("keyword", max: 200), category = try a.string("category", max: 120)
        let folderName = try a.string("folder", max: 120), conv = try a.string("conversation_id", max: 500)
        let projectArg = try a.string("project", max: 200)
        guard keyword != nil || category != nil || folderName != nil || conv != nil || projectArg != nil else {
            throw ToolFailure("Give project, keyword, category, folder or conversation_id.", "error:invalid-args")
        }
        let store = backend.store
        var rows: [MailMessage] = []
        var resolved: GraphProject?
        if let projectArg {
            guard let p = store.graph?.resolveProject(projectArg).first else { throw ToolFailure("Unknown project.", "error:unknown-project") }
            resolved = p
            switch p.kind {
            case .category: rows += store.messages(matching: [.category(String(p.id.dropFirst(4)))], mailbox: mb, limit: 1_000)
            case .folder: rows += (try? store.messages(folderId: String(p.id.dropFirst(4)), limit: 500)) ?? []
            case .topic: rows += store.messages(matching: [.term(String(p.id.dropFirst(2)))], mailbox: mb, limit: 1_000)
            }
        }
        if let conv { rows += (try? store.conversation(id: conv, limit: 200)) ?? [] }
        if let keyword, !keyword.isEmpty { rows += await backend.sync.search(keyword, mailbox: mb, limit: 100, includeServer: false) }
        if let folderName {
            guard let f = folderByName(folderName, mailbox: mb) else { throw ToolFailure("Unknown folder.", "error:unknown-folder") }
            await ensureOpened(f)
            rows += (try? store.messages(folderId: f.id, limit: 300)) ?? []
        }
        if let category {
            for wk in [WellKnownFolder.inbox, .sentitems, .archive] {
                guard let f = try? store.folder(wellKnown: wk, mailbox: mb) else { continue }
                await ensureOpened(f)
            }
            rows += store.messages(matching: [.category(category)], mailbox: mb, limit: 1_000)
        }
        var seen = Set<String>(), hidden = 0
        var visible: [(MailMessage, MailMessage, Exposure)] = []
        for m in rows where seen.insert(m.id).inserted {
            if let mbx = Optional(store.mailbox(forFolder: m.folderId)), mbx != mb { continue }
            guard let (r, ex) = gate.mail(m, mailbox: mb) else { hidden += 1; continue }
            visible.append((m, r, ex))
        }
        // A graph name that resolved only through mail the caller can't see must not confirm it exists.
        if resolved != nil && visible.isEmpty { throw ToolFailure("Unknown project.", "error:unknown-project") }
        var people: [String: Int] = [:], companies: [String: Int] = [:]
        for (m, _, ex) in visible {
            var addrs = [m.from?.address.lowercased()].compactMap { $0 }
            if ex == .full { addrs += (m.toRecipients + m.ccRecipients).map { $0.address.lowercased() } }
            for p in Set(addrs) where !p.isEmpty && !(store.graph?.isOwner(p, mailbox: mb) ?? false) && p != backend.me.address.lowercased() {
                people[p, default: 0] += 1
                if let d = MailDomains.companyKey(for: p) { companies[d, default: 0] += 1 }
            }
        }
        let threads = Dictionary(grouping: visible, by: { $0.0.conversationId }).map { (id, ms) -> (Date, JSON) in
            let newest = ms.max { $0.0.received < $1.0.received }!
            return (newest.0.received, ["conversation_id": .string(id), "messages": .int(ms.count), "last_activity": .date(newest.0.received),
                                        "latest": render(newest.1, newest.2, mailbox: mb)])
        }.sorted { $0.0 > $1.0 }
        var payload: [String: JSON] = [
            "threads": .array(threads.prefix(10).map(\.1)), "thread_count": .int(threads.count),
            "participants": .array(people.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(10).map { ["address": .string(Untrusted.line($0.key, max: 254)), "messages": .int($0.value)] }),
            "companies": .array(companies.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(8).map {
                ["domain": .string(Untrusted.line($0.key, max: 254)), "messages": .int($0.value)]
            }),
            "last_activity": .date(threads.first?.0), "restricted_not_shown": .int(hidden), "notice": restrictedNotice(hidden),
        ]
        if let resolved {
            // Topic: the bare term (a cluster co-term may come from hidden mail). Category/folder: the visible name.
            let name = resolved.kind == .topic ? String(resolved.id.dropFirst(2)) : resolved.name
            payload["project"] = ["id": .string(Untrusted.line(resolved.id, max: 200)), "kind": .string(resolved.kind.rawValue),
                                  "name": .string(Untrusted.line(name, max: 120))]
        }
        payload["related_projects"] = .array(projectsOf(visible, mailbox: mb).filter { $0.id != resolved?.id }.prefix(6).map {
            ["project": .string(Untrusted.line($0.id, max: 200)), "name": .string(Untrusted.line($0.name, max: 120)), "messages": .int($0.count)]
        })
        return ToolOutput(payload: .object(payload), ids: visible.prefix(50).map(\.0.id), shown: visible.count, restricted: hidden,
                          decision: "ok:project,shown=\(visible.count),hidden=\(hidden)")
    }
}
