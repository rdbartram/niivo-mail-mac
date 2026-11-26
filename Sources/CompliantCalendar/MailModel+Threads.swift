import Foundation
import CalendarCore
import MailCore

// THREAD-HOOK: conversation view — model side. The list pages threads from the store (SQL GROUP BY per folder,
// MailThreads.swift); actions on a thread row expand to every member in the folder with one ⌘Z; the reader set is
// folder + Sent Items. Decisions live in MailCore (CoreSelfTest: ThreadTests.swift).

extension MailModel {
    /// Store-grouped list: grouping on, a real folder (virtual lists keep the client-side grouping), no search.
    var usesThreadPage: Bool {
        guard groupConversations, let fid = selectedFolderId, VirtualFolder(id: fid) == nil else { return false }
        // Drafts / Outbox list every item on its own (each opens its own composer; scheduled sends live there).
        return selectedFolder?.wellKnown != .drafts && selectedFolder?.wellKnown != .outbox
    }

    /// Your own addresses (identities + signed-in user), lowercased — "me" in participant lines.
    var meAddresses: Set<String> {
        Set(settings.identities.map { $0.address.lowercased() } + [me?.address.lowercased()].compactMap { $0 })
    }

    func sentFolderId(forFolder folderId: String) -> String? {
        guard let store else { return nil }
        return ((try? store.folder(wellKnown: .sentitems, mailbox: store.mailbox(forFolder: folderId))) ?? nil)?.id
    }

    /// One thread page; records the summaries + strictest row policy. Returns each thread's representative (newest
    /// in-folder message) with the thread's read / flag state folded in, so filters and row actions see the thread.
    func threadPage(store: MailStore, folderId: String, before: MailThreadCursor?, limit: Int, replace: Bool) -> [MailMessage] {
        let page: [MailThreadSummary]
        do { page = try store.threads(folderId: folderId, sentFolderId: sentFolderId(forFolder: folderId), before: before, limit: limit) }
        catch {
            FileHandle.standardError.write(Data("[Mail] thread query failed: \(String(describing: error).prefix(160))\n".utf8))
            page = []
        }
        if replace { threadSummaries = [:]; threadPolicies = [:] }
        let mb = store.mailbox(forFolder: folderId)
        for t in page {
            threadSummaries[t.conversationId] = t
            threadPolicies[t.conversationId] = MailThreads.strictest(t.readerMembers.map { policy(for: $0, mailbox: mb) })
        }
        return page.map { t in
            var m = t.latest
            m.isRead = !t.hasUnread
            if t.flagged, m.flag.status != .flagged { m.flag.status = .flagged }
            return m
        }
    }

    func threadRows(_ msgs: [MailMessage]) -> [MailRow] {
        msgs.map { m in
            let mb = store?.mailbox(forFolder: m.folderId) ?? "me"
            // A one-message conversation is an ordinary row (MessageRowView); the label is still the strictest.
            let t = threadSummaries[m.conversationId].flatMap { $0.readerMembers.count > 1 ? $0 : nil }
            return MailRow(message: m, mailbox: mb, count: t?.count ?? 1,
                           policy: threadPolicies[m.conversationId] ?? policy(for: m, mailbox: mb), thread: t)
        }
    }

    /// The thread row for a row id (only while the list is store-grouped).
    func threadSummary(forRowId id: String?) -> MailThreadSummary? {
        guard usesThreadPage, searchResults == nil, let id else { return nil }
        return threadSummaries.values.first { $0.latest.id == id }
    }

    /// New mail in the open thread changes its row id: keep the selection on the thread.
    func repointThreadSelection() {
        guard usesThreadPage, let id = selectedMessageId, !rows.contains(where: { $0.id == id }),
              let conv = (try? store?.message(id: id, includeBody: false))??.conversationId,
              let row = rows.first(where: { $0.conversationId == conv }) else { return }
        selectedMessageId = row.id
    }

    /// Triage on a thread row: every member in the folder, one toast, one ⌘Z. False when `id` isn't a thread row.
    func triageThread(_ action: MailAction, id: String?, text: String?) -> Bool {
        guard let t = threadSummary(forRowId: id), let store, let sync else { return false }
        let folder = t.latest.folderId
        let members = (try? store.threadMembers(conversationId: t.conversationId, folderId: folder)) ?? t.members
        guard members.count > 1 else { return false }   // a one-message thread takes the ordinary path
        let plan = MailThreads.plan(action, members: members)
        guard !plan.steps.isEmpty else { return true }
        if MailThreads.removesFromList(action) {
            let rowId = t.latest.id
            if selectedMessageId == rowId {
                let v = visibleRows
                if let i = v.firstIndex(where: { $0.id == rowId }) {
                    selectedMessageId = i + 1 < v.count ? v[i + 1].id : (i > 0 ? v[i - 1].id : nil)
                }
            }
            threadSummaries[t.conversationId] = nil
            dropRows([rowId])
        }
        let label = (text ?? TriageUndo.describe(action)) + " · " + L("conversation (%d)", plan.steps.count)
        pushUndo(UndoEntry(steps: plan.undo, text: label))
        toast(MailToast(text: label, symbol: "checkmark", action: .undoTriage))
        let steps = plan.steps
        Task {
            let r = await sync.apply(steps)
            if r.failed > 0 { toast(MailToast(text: L("Couldn't apply that change"), symbol: "exclamationmark.triangle", isError: true)) }
        }
        return true
    }

    /// Bulk targets with thread rows expanded to all their in-folder members (each with its own before-state).
    func expandThreadTargets(_ rows: [MailRow]) -> [BulkTarget] {
        rows.flatMap { r -> [BulkTarget] in
            guard usesThreadPage, let t = r.thread, t.count > 1, let store,
                  let ms = try? store.threadMembers(conversationId: t.conversationId, folderId: t.latest.folderId), !ms.isEmpty
            else { return [BulkTarget(message: r.message, mailbox: r.mailbox)] }
            return ms.map { BulkTarget(message: $0, mailbox: r.mailbox) }
        }
    }

    /// Ordered steps (Quick Steps, trays) with thread rows expanded to every member (MailOrg2.applySteps).
    func expandThreadSteps(_ steps: [BulkStep], rows: [MailRow]) -> ([BulkStep], [MailRow]) {
        guard usesThreadPage, let store else { return (steps, rows) }
        var outSteps: [BulkStep] = [], outRows = rows
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var added = Set<String>()
        for s in steps {
            guard let r = byId[s.messageId], let t = r.thread, t.count > 1,
                  let ms = try? store.threadMembers(conversationId: t.conversationId, folderId: t.latest.folderId) else { outSteps.append(s); continue }
            for m in ms {
                outSteps.append(BulkStep(messageId: m.id, action: s.action))
                if m.id != r.id, added.insert(m.id).inserted {
                    outRows.append(MailRow(message: m, mailbox: r.mailbox, count: 1, policy: policy(for: m, mailbox: r.mailbox)))
                } else if m.id == r.id, let i = outRows.firstIndex(where: { $0.id == r.id }) {
                    outRows[i].message = m   // the real before-state, not the folded thread state
                }
            }
        }
        return (outSteps, outRows)
    }

    /// Reader set for an opened message: folder + Sent of its mailbox (Gmail order unless "newest on top").
    func readerThread(for header: MailMessage) -> [MailMessage] {
        guard let store else { return [] }
        let conv = (try? store.conversation(id: header.conversationId, limit: MailThreads.memberCap)) ?? []
        guard groupConversations else { return conv.sorted { $0.received < $1.received } }
        let set = MailThreads.readerMembers(conv, folderId: header.folderId, sentFolderId: sentFolderId(forFolder: header.folderId))
        return set.isEmpty ? [header] : set
    }
}

extension MailModel {
    /// THREAD-HOOK: a changed message of the open conversation (new arrival, your sent reply) rebuilds the reader set.
    func refreshedReaderThread(changed ids: [String]) -> [MailMessage]? {
        guard let r = reader, let store, groupConversations else { return nil }
        let conv = r.header.conversationId
        let known = Set(r.thread.map(\.id))
        let touches = ids.prefix(200).contains { id in
            known.contains(id) || ((try? store.message(id: id, includeBody: false)) ?? nil)?.conversationId == conv
        }
        guard touches else { return nil }
        let t = readerThread(for: r.header)
        return t != r.thread ? t : nil
    }
}
