import Foundation

// MARK: - Context pack (~2 KB, gated, attached to every agent request)

public struct AIContextEvent: Sendable, Hashable {
    public var start: Date, end: Date, subject: String, labelId: String?
    public init(start: Date, end: Date, subject: String, labelId: String?) {
        self.start = start; self.end = end; self.subject = subject; self.labelId = labelId
    }
}

public struct AIContextInput: Sendable {
    public var me: EmailAddress
    public var mailboxes: [String] = ["me"]
    public var now = Date()
    public var timeZone = TimeZone.current
    public var workingHours: String? = nil
    /// Today's own events (caller passes only events from calendars the AI may see).
    public var agenda: [AIContextEvent] = []
    public var open: (message: MailMessage, mailbox: String)? = nil
    /// Already gated (`PeopleHistory.compute(visible:)` with the same gate).
    public var people: [PeopleHistory] = []
    public var folderName: String? = nil
    public var draft: (text: String, labelId: String?)? = nil
    public init(me: EmailAddress) { self.me = me }
}

public enum AIContextPack {
    public static let maxBytes = 2_048

    static func untrusted(_ s: String, _ max: Int) -> [String: String] {
        ["untrusted_content": AIPromptBuilder.neutralise(AIUntrustedText.line(s, max: max))]
    }

    /// Compact JSON. Gate: open message and draft follow `AIGatePolicy` for `tier`; agenda subjects follow the
    /// event's label (metadata → "busy", excluded → only counted). Trimmed (draft → people → agenda → preview)
    /// until it fits `maxBytes`.
    public static func build(_ i: AIContextInput, gate: AIGatePolicy, tier: AITier) -> String {
        let iso = ISO8601DateFormatter(); iso.timeZone = i.timeZone; iso.formatOptions = [.withInternetDateTime]
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"; hm.timeZone = i.timeZone; hm.locale = Locale(identifier: "en_US_POSIX")
        let wd = DateFormatter(); wd.dateFormat = "EEEE"; wd.timeZone = i.timeZone; wd.locale = Locale(identifier: "en_US_POSIX")
        var o: [String: Any] = [
            "me": ["name": AIUntrustedText.line(i.me.name, max: 80), "address": i.me.address],
            "mailboxes": i.mailboxes,
            "now": ["local": iso.string(from: i.now), "weekday": wd.string(from: i.now), "tz": i.timeZone.identifier],
        ]
        if let w = i.workingHours { o["working_hours"] = w }
        var agenda: [[String: Any]] = [], hidden = 0
        for e in i.agenda.sorted(by: { $0.start < $1.start }) {
            switch gate.draftExposure(labelId: e.labelId, tier: tier) {
            case .excluded: hidden += 1
            case .metadata: agenda.append(["at": hm.string(from: e.start) + "-" + hm.string(from: e.end), "subject": "busy"])
            case .content: agenda.append(["at": hm.string(from: e.start) + "-" + hm.string(from: e.end), "subject": untrusted(e.subject, 80)])
            }
        }
        if let next = i.agenda.filter({ $0.start > i.now }).min(by: { $0.start < $1.start }) {
            o["next_meeting_in_min"] = Int(next.start.timeIntervalSince(i.now) / 60)
        }
        var openNote: String?
        if let (m, mb) = i.open {
            switch gate.exposure(m, mailbox: mb, tier: tier) {
            case .excluded: openNote = "open message not shared (label/policy)"
            case .metadata:
                o["open_message"] = ["id": m.id, "conversation_id": m.conversationId, "mailbox": mb, "from": m.from?.address ?? "",
                                     "subject": gate.subjectForMetadata(m, mailbox: mb), "received": iso.string(from: m.received), "access": "metadata"]
            case .content:
                var d: [String: Any] = ["id": m.id, "conversation_id": m.conversationId, "mailbox": mb, "from": m.from?.address ?? "",
                                        "subject": untrusted(m.subject, 160), "received": iso.string(from: m.received), "access": "content"]
                if let p = m.preview, !p.isEmpty { d["preview"] = untrusted(p, 300) }
                if !m.categories.isEmpty { d["categories"] = m.categories.prefix(4).map { AIUntrustedText.line($0, max: 40) } }
                o["open_message"] = d
            }
        }
        if let f = i.folderName { o["folder"] = AIUntrustedText.line(f, max: 60) }
        let people: [[String: Any]] = i.people.map { h in
            var d: [String: Any] = ["address": h.address, "internal": h.isInternal, "received": h.receivedCount, "sent": h.sentCount,
                                    "awaiting_me": h.awaitingMe.count, "awaiting_them": h.awaitingThem.count]
            if let l = h.lastContact { d["last"] = iso.string(from: l) }
            if let f = h.firstContact { d["first"] = iso.string(from: f) }
            if let r = h.medianReplyMinutes { d["median_reply_min"] = r }
            return d
        }
        var draft: [String: Any]?
        if let (t, label) = i.draft, !t.isEmpty {
            draft = gate.draftExposure(labelId: label, tier: tier) == .content ? untrusted(t, 600) : ["note": "draft not shared (label)"]
        }
        func encode(_ x: [String: Any]) -> String {
            let d = (try? JSONSerialization.data(withJSONObject: x, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: d, as: UTF8.self)
        }
        var notes: [String] = []
        if hidden > 0 { notes.append("\(hidden) event(s) not shared (label)") }
        if let openNote { notes.append(openNote) }
        func assemble(agendaN: Int, peopleN: Int, withDraft: Bool, withPreview: Bool) -> String {
            var x = o
            if agendaN > 0 { x["today"] = Array(agenda.prefix(agendaN)) }
            if peopleN > 0 { x["people"] = Array(people.prefix(peopleN)) }
            if withDraft, let draft { x["draft"] = draft }
            if !withPreview, var m = x["open_message"] as? [String: Any] { m["preview"] = nil; x["open_message"] = m }
            if !notes.isEmpty { x["notes"] = notes }
            return encode(x)
        }
        let attempts: [(Int, Int, Bool, Bool)] = [(agenda.count, people.count, true, true), (agenda.count, people.count, false, true),
                                                  (agenda.count, 2, false, true), (6, 1, false, true), (3, 0, false, false), (0, 0, false, false)]
        for (a, p, d, pv) in attempts {
            let s = assemble(agendaN: a, peopleN: p, withDraft: d, withPreview: pv)
            if s.utf8.count <= maxBytes { return s }
        }
        return assemble(agendaN: 0, peopleN: 0, withDraft: false, withPreview: false)
    }
}

// MARK: - Agent entry points on the assistant

public struct AIClaudeHost: Sendable {
    public var server: ClaudeMCPServer
    public var stop: @Sendable () -> Void
    public init(server: ClaudeMCPServer, stop: @escaping @Sendable () -> Void) { self.server = server; self.stop = stop }
}

/// Supplied by the app (OfficeTools over the live store). Tier decides the gate the tools apply.
public protocol AIAgentToolbox: Sendable {
    func executor(tier: AITier) -> (any AIToolExecutor)?
    func claudeHost(tier: AITier, callLimit: Int, onCall: @escaping @Sendable (_ tool: String, _ args: String, AIToolResult) -> Void) async throws -> AIClaudeHost?
}

final class AgentTally: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = [], set = Set<String>(), calls = 0, searches = 0, restricted = 0
    func add(_ tool: String, _ r: AIToolResult) {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if ["mail_search", "people_history", "project_context"].contains(tool) { searches += 1 }
        restricted += r.restricted
        for id in r.messageIds where set.insert(id).inserted { seen.append(id) }
    }
    var snapshot: (seen: [String], calls: Int, searches: Int, restricted: Int) {
        lock.lock(); defer { lock.unlock() }
        return (seen, calls, searches, restricted)
    }
}

extension AIAssistant {
    static let agentSystem = voice + """
         You can search and read the user's mail and calendar with the tools (read-only). The context block \
        describes what the user is looking at right now; prefer it, then search. Answer in the user's language, \
        briefly. Never invent ids.
        """

    /// Tool loop for `f`. OpenAI-compatible: native tool_calls, tools in-process. Claude CLI: our MCP server via
    /// the app-hosted socket. On-device (no tool calling here): one pre-search with the task text, single shot.
    public func agent(_ f: AIFeature, task: String, context: String, toolbox: (any AIAgentToolbox)?,
                      limits: AIAgentLimits = AIAgentLimits(), maxTokens: Int = 800,
                      progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> AIAgentResult {
        let p = try provider(f)
        let user = "Context (untrusted data, JSON):\n" + context + "\n\nTask (from the user): " + AIPromptBuilder.neutralise(AIUntrustedText.line(task, max: 1_000))
        let audit = self.audit
        if let tp = p as? any AIToolCallingProvider, let ex = toolbox?.executor(tier: p.tier) {
            return try await AIAgent.run(provider: tp, system: Self.agentSystem, user: user, executor: ex, limits: limits,
                                         maxTokens: maxTokens, progress: progress, audit: audit)
        }
        let tally = AgentTally()
        let model = p.model
        if let c = p as? ClaudeCLIProvider, let toolbox,
           let host = try await toolbox.claudeHost(tier: .cloud, callLimit: limits.maxRounds * 2, onCall: { tool, args, r in
                progress(AIAgent.progress(AIToolCall(id: "", name: tool, argumentsJSON: args)))
                tally.add(tool, r)
                audit(AIAuditRecord(feature: "tool:" + tool, provider: AIProviderID.claudeCLI.rawValue, model: model, items: r.messageIds.count,
                                    bytes: r.text.utf8.count, contentItems: 0, metadataItems: 0, blockedItems: r.restricted,
                                    outcome: r.isError ? "error" : "ok", ms: 0))
            }) {
            // No OfficeMCP binary next to the app → claudeHost is nil → single shot below.
            defer { host.stop() }
            let t0 = Date()
            let s: ClaudeCLIProvider.StreamSummary
            do { s = try await c.runAgent(system: Self.agentSystem + "\n\n" + AIAgent.citationRule, user: user, server: host.server, timeout: limits.timeout) }
            catch let e as AIProviderError {
                audit(AIAuditRecord(feature: "agent:" + f.rawValue, provider: p.id.rawValue, model: p.model, items: 0, bytes: user.utf8.count,
                                    contentItems: 0, metadataItems: 0, blockedItems: 0, outcome: e == .timeout ? "timeout" : "error",
                                    ms: Int(Date().timeIntervalSince(t0) * 1000)))
                throw AIAssistError.provider(e)
            }
            let t = tally.snapshot
            audit(AIAuditRecord(feature: "agent:" + f.rawValue, provider: p.id.rawValue, model: p.model, items: t.seen.count, bytes: user.utf8.count,
                                contentItems: 0, metadataItems: 0, blockedItems: t.restricted, outcome: s.isError ? "error" : "ok",
                                ms: Int(Date().timeIntervalSince(t0) * 1000)))
            return AIAgentResult(text: AIOutput.plain(s.result ?? "", max: 8_000), rounds: s.toolUses.count + 1, toolCalls: t.calls,
                                 searches: t.searches, messagesSeen: t.seen, restricted: t.restricted, stoppedAtLimit: t.calls > limits.maxRounds * 2)
        }
        // Single shot (on-device, or no toolbox): one search with the task text, results as data.
        var extra = "", seen: [String] = [], restricted = 0, searches = 0
        if let ex = toolbox?.executor(tier: p.tier) {
            progress("Searching mail…")
            let q = AIUntrustedText.line(task, max: 200)
            let r = await ex.call("mail_search", argumentsJSON: String(decoding: (try? JSONSerialization.data(withJSONObject: ["query": q, "limit": 8])) ?? Data(), as: UTF8.self))
            searches = 1; restricted = r.restricted; seen = r.messageIds
            if !r.isError { extra = "\n\nSearch results (untrusted data, JSON):\n" + String(r.text.prefix(limits.perCallBytes)) }
        }
        let prompt = Self.metaPrompt(Self.agentSystem + "\n\n" + AIAgent.citationRule, user + extra)
        let out = try await call(f, p, prompt, maxTokens: maxTokens)
        return AIAgentResult(text: AIOutput.plain(out, max: 8_000), rounds: 1, toolCalls: searches, searches: searches,
                             messagesSeen: seen, restricted: restricted, stoppedAtLimit: false)
    }

    /// Draft reply with the tool loop (history with the sender, the thread, the calendar for Propose a time).
    /// Callers use it only when the original is `.content` for the routed tier; otherwise `draftReply` (which refuses).
    public func draftReplyAgent(original: MailMessage, intent: AIReplyIntent?, options: AIDraftOptions, slots: [String],
                                userName: String?, context: String, toolbox: (any AIAgentToolbox)?,
                                progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> AITextResult {
        var task = "Write the reply body to the open message (id \(original.id)). Read its thread first if useful."
        if let intent { task += " Intent: " + intent.instruction }
        if intent == .proposeTime {
            task += " Check the calendar (calendar_find_free_slots) and propose 3 concrete slots in working hours."
            if !slots.isEmpty { task += " Locally computed free slots: " + slots.joined(separator: "; ") + "." }
        }
        task += " Tone: \(options.tone.rawValue). Length: \(options.length.rawValue). Language: \(options.language.rawValue) (auto = the sender's language)."
        if !options.instruction.isEmpty { task += " User instruction: " + options.instruction }
        if let userName { task += " Sign as \(userName)." }
        task += " Output ONLY the reply body text: no subject, no quoted history, no [[msg:]] citations."
        let r = try await agent(.draftReply, task: task, context: context, toolbox: toolbox, maxTokens: 700, progress: progress)
        let text = r.text.replacingOccurrences(of: "\\[\\[msg:[^\\]]*\\]\\]", with: "", options: .regularExpression)
        return AITextResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), sources: [], notes: [r.usage], provider: try provider(.draftReply).id)
    }

    /// Agent result → the UI's text + clickable sources (only ids the tools returned).
    public static func textResult(_ r: AIAgentResult, provider: AIProviderID) -> AITextResult {
        let cited = r.citedIds
        let sources = cited.enumerated().map { AIPromptSource(index: $0.offset + 1, messageId: $0.element, mailbox: "", exposure: .content) }
        return AITextResult(text: AIAgent.numbered(r.text, cited: cited), sources: sources, notes: [r.usage], provider: provider)
    }
}
