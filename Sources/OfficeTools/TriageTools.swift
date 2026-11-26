import Foundation
import CalendarCore
import MailCore

// TRIAGE2-HOOK: the MCP "awaiting me / awaiting them" lists read the conversation state (plan §1.1 #10) instead
// of "who sent the newest message". The MCP process has its own store, so it runs the same L0/L1 rules on it
// (no LLM, no app overrides). Cue bits are scanned only where this server's gate shows the message in full: a
// state derived from text reaches the client, so it follows the client's tier.
extension MCPServer {
    func triageDecision(conversationId: String, mailbox mb: String, now: Date = Date()) -> TriageDecision? {
        let store = backend.store
        // Only messages this server's gate shows at all: a hidden newer message must not decide whether a visible
        // thread is listed (or which way).
        let ms = ((try? store.conversation(id: conversationId, limit: 200)) ?? []).filter { gate.mail($0, mailbox: mb) != nil }
        guard !ms.isEmpty else { return nil }
        var exposure: [String: AIExposure] = [:]
        var mine: Set<String> = []
        var roles: [String: WellKnownFolder] = [:]
        for m in ms {
            switch gate.mail(m, mailbox: mb)?.1 { case .full?: exposure[m.id] = .content; case .metadata?: exposure[m.id] = .metadata; case nil: exposure[m.id] = .excluded }
            if isOwnerSent(m, mailbox: mb) { mine.insert(m.id) }
            if roles[m.folderId] == nil, let w = ((try? store.folder(id: m.folderId)) ?? nil)?.wellKnown { roles[m.folderId] = w }
        }
        let (exp, mineIds, folderRoles) = (exposure, mine, roles)
        let owners = Set([backend.me.address.lowercased()] + (mb == "me" ? [] : [mb.lowercased()])).subtracting([""])
        let inputs = TriageInputs(account: backend.accountId, isMine: { mineIds.contains($0.id) }, myAddresses: owners,
                                  internalDomains: backend.internalDomains, folderRole: { folderRoles[$0] },
                                  exposure: { exp[$0.id] ?? .excluded })
        guard let f = ConversationFactsBuilder.build(conversationId: conversationId, messages: ms, inputs: inputs) else { return nil }
        return TriageRules.decide(f, now: now)
    }
}
