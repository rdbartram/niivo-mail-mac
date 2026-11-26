import Foundation
import CalendarCore
import MailCore

// PROMISES-HOOK: `promises_open` (read-only). Gated like the triage tools: text is read only from messages this
// server's gate shows in full (`.full` → content), and the phrase reaching the client is untrusted-wrapped. When
// the store carries the app's ledger (in-app agent), its states (done / dismissed / snoozed) apply; otherwise the
// same rules run on the server's own cache (last 30 days of Sent + Inbox, auto-complete included, no app states).
extension MCPServer {
    /// The message, when this server's gate shows it in full (text may be read); else nil.
    func promiseReadable(_ id: String, mailbox mb: String) -> MailMessage? {
        guard let m = (try? backend.store.message(id: id, includeBody: false)) ?? nil,
              let (_, ex) = gate.mail(m, mailbox: mb), ex == .full else { return nil }
        return m
    }

    func promisesOpen(_ a: Args) async throws -> ToolOutput {
        let mb = try await resolveMailbox(a.string("mailbox", max: 254))
        let limit = try a.int("limit", default: 20, range: 1...50)
        let store = backend.store
        let now = Date(), cal = Calendar.current
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        var folders: [MailFolder] = []
        for wk in [WellKnownFolder.sentitems, .inbox] {
            if let f = (try? store.folder(wellKnown: wk, mailbox: mb)) ?? nil { await ensureOpened(f); folders.append(f) }
        }
        var hidden = 0
        var promises: [Promise] = []
        func full(_ id: String) -> MailMessage? { promiseReadable(id, mailbox: mb) }
        if let ledger = store.promises, ledger.account == backend.accountId {
            promises = ledger.open(now: now).filter { $0.mailbox == mb }
        } else {
            for f in folders {
                for m in (try? store.messages(folderId: f.id, limit: 300)) ?? [] where m.received >= cutoff {
                    guard full(m.id) != nil else { hidden += 1; continue }
                    let mine = isOwnerSent(m, mailbox: mb)
                    if !mine, !m.toRecipients.contains(where: { $0.address.lowercased() == backend.me.address.lowercased() }) { continue }
                    if !mine, ChannelClassifier.classify(m) != .person || (m.toRecipients + m.ccRecipients).count > 3 { continue }
                    guard let raw = (try? store.body(messageId: m.id, touch: false)) ?? m.preview else { continue }
                    for c in PromiseExtractor.extract(raw, isHTML: raw.contains("</"), kind: mine ? .promised : .asked, sentAt: m.received) {
                        let cp = mine ? m.toRecipients.first : m.from
                        promises.append(Promise(id: Promise.makeId(conversationId: m.conversationId, sentAt: m.received, kind: c.kind, text: c.text),
                                                kind: c.kind, conversationId: m.conversationId, sourceMessageId: m.id, mailbox: mb, text: c.text,
                                                counterpartAddress: cp?.address, due: c.due, createdAt: m.received, certain: c.certain))
                    }
                }
            }
            // Auto-complete against later visible sends in the same conversation.
            promises = promises.filter { p in
                let later = ((try? store.conversation(id: p.conversationId, limit: 200)) ?? []).filter {
                    $0.received > p.createdAt && isOwnerSent($0, mailbox: mb) && full($0.id) != nil
                }
                return !later.contains { $0.hasAttachments }
            }
        }
        let shown = promises.filter { full($0.sourceMessageId) != nil }
        hidden += promises.count - shown.count
        let sorted = shown.sorted { ($0.due ?? .distantFuture, $0.createdAt) < ($1.due ?? .distantFuture, $1.createdAt) }.prefix(limit)
        let items: [JSON] = sorted.map { p in
            var o: [String: JSON] = ["kind": .string(p.kind == .promised ? "you_promised" : "asked_of_you"),
                                     "text": .string(Untrusted.line(p.text ?? "", max: 120)),
                                     "conversation_id": .string(p.conversationId), "message_id": .string(p.sourceMessageId),
                                     "overdue": .bool(p.isOverdue(now: now, calendar: cal)), "certain": .bool(p.certain),
                                     "since": .date(p.createdAt)]
            if let d = p.due { o["due"] = .date(d) }
            if let c = p.counterpartAddress { o["counterpart"] = .string(Untrusted.line(c, max: 254)) }
            return .object(o)
        }
        let payload: JSON = ["promises": .array(items), "count": .int(items.count), "restricted_not_shown": .int(hidden),
                             "notice": restrictedNotice(hidden),
                             "scope": "Open commitments from your sent mail and requests with a deadline addressed to you (last 30 days), oldest due first."]
        return ToolOutput(payload: payload, ids: sorted.map(\.sourceMessageId), shown: items.count, restricted: hidden,
                          decision: "ok:promises,shown=\(items.count),hidden=\(hidden)")
    }
}
