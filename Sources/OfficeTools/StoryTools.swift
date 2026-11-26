import Foundation
import CalendarCore
import MailCore

// story_context: the messages related to one message across conversations, folders and mailboxes (StoryEngine).
// Same rule as the other graph tools: the story index only proposes members; every member returned passed the AI
// gate for its own mailbox, hidden ones are only counted, and the title is built from full-exposure subjects only
// (never the on-device model's title, which may have read content this caller may not see).
extension MCPServer {

    func storyContext(_ a: Args) async throws -> ToolOutput {
        let mid = try a.string("message_id", max: 500), conv = try a.string("conversation_id", max: 500)
        guard mid != nil || conv != nil else { throw ToolFailure("Give message_id or conversation_id.", "error:invalid-args") }
        let limit = try a.int("limit", default: 15, range: 1...40)
        let store = backend.store
        let unknown = ToolFailure("Unknown message.", "error:unknown-message")
        guard let stories = store.stories else { throw ToolFailure("Related-message stories aren't available.", "error:unavailable") }
        // Vectors first (linking waits for them), then link what arrived since the last call. Bounded.
        if let sem = store.semantic { _ = try? sem.catchUp(maxItems: 64) }
        _ = try? stories.catchUp(maxItems: 64)
        var seed: MailMessage?
        if let mid { seed = try? store.message(id: mid, includeBody: false) }
        if seed == nil, let conv { seed = ((try? store.conversation(id: conv, limit: 200)) ?? []).max { $0.received < $1.received } }
        guard let seed else { throw unknown }
        // A seed the caller may not see is indistinguishable from an unknown id.
        guard gate.mail(seed, mailbox: store.mailbox(forFolder: seed.folderId)) != nil else { throw unknown }

        let snap = stories.story(messageId: seed.id, limit: 80)
        let members = snap?.members ?? [StoryMember(message: seed, mailbox: store.mailbox(forFolder: seed.folderId))]
        var hidden = 0
        var visible: [(StoryMember, MailMessage, Exposure)] = []
        for m in members {
            guard let (r, ex) = gate.mail(m.message, mailbox: m.mailbox) else { hidden += 1; continue }
            visible.append((m, r, ex))
        }
        visible.sort { $0.0.message.received > $1.0.message.received }
        let title = StoryTitles.fallback(subjects: visible.filter { $0.2 == .full }.map(\.1.subject)) ?? "Related messages"
        var people: [String: (name: String, n: Int)] = [:]
        for (m, r, _) in visible {
            guard let f = r.from, !f.address.isEmpty, !isOwnerSent(r, mailbox: m.mailbox) else { continue }
            let k = f.address.lowercased()
            people[k] = (people[k]?.name.isEmpty == false ? people[k]!.name : f.name, (people[k]?.n ?? 0) + 1)
        }
        let shown = Array(visible.prefix(limit))
        let items: [JSON] = shown.map { v in
            var j = render(v.1, v.2, mailbox: v.0.mailbox)
            if case .object(var o) = j {
                o["is_seed"] = .bool(v.0.message.id == seed.id)
                o["mailbox"] = .string(Untrusted.line(v.0.mailbox, max: 254))
                j = .object(o)
            }
            return j
        }
        let meta = shown.filter { $0.2 == .metadata }.count
        let payload: JSON = [
            "story_id": .string(snap?.id ?? ""),
            "title": .string(Untrusted.line(title, max: 120)),
            "messages": .array(items),
            "message_count": .int(visible.count),
            "conversation_count": .int(Set(visible.map(\.0.message.conversationId)).count),
            "mailboxes": .array(Array(Set(visible.map(\.0.mailbox))).sorted().map { .string(Untrusted.line($0, max: 254)) }),
            "participants": .array(people.sorted { ($0.value.n, $1.key) > ($1.value.n, $0.key) }.prefix(10).map {
                ["address": .string(Untrusted.line($0.key, max: 254)), "name": .string(Untrusted.line($0.value.name, max: 100)), "messages": .int($0.value.n)]
            }),
            "first_activity": .date(visible.last?.0.message.received), "last_activity": .date(visible.first?.0.message.received),
            "indexed": .bool(snap != nil),
            "restricted_not_shown": .int(hidden), "notice": restrictedNotice(hidden),
            "scope": "Local encrypted cache, all opened mailboxes. Related = linked on this Mac by participants, time, shared rare terms/names/dates/attachment names and on-device semantic similarity; protected/private items link by metadata only.",
        ]
        return ToolOutput(payload: payload, ids: shown.map(\.0.message.id), shown: shown.count, restricted: hidden,
                          decision: decision(shown: shown.count, meta: meta, hidden: hidden))
    }
}
