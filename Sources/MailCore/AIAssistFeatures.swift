import Foundation
import CalendarCore

/// Pure orchestration: route → gate (prompt builder) → provider → defensive parse → audit. No UI, no state.
public struct AIAssistant: Sendable {
    public var settings: AIAssistSettings
    public var gate: AIGatePolicy
    public var cloud: (any AIProvider)?
    public var onDevice: (any AIProvider)?
    public var audit: @Sendable (AIAuditRecord) -> Void
    public var now: @Sendable () -> Date

    public init(settings: AIAssistSettings, gate: AIGatePolicy, cloud: (any AIProvider)?, onDevice: (any AIProvider)?,
                audit: @escaping @Sendable (AIAuditRecord) -> Void, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings; self.gate = gate; self.cloud = cloud; self.onDevice = onDevice
        self.audit = audit; self.now = now
    }

    public var isEnabled: Bool { AIFeature.allCases.contains { route($0) != nil } }
    /// Content features (drafting etc.) possible at all on the routed tier.
    public func canUseContent(_ f: AIFeature) -> Bool {
        guard let p = route(f) else { return false }
        return gate.access(for: p.tier) == .followLabels
    }

    /// Provider for a feature, or nil (AI off, nothing configured, or policy forbids every candidate).
    public func route(_ f: AIFeature) -> (any AIProvider)? {
        var candidates: [any AIProvider] = []
        switch settings.choice {
        case .off: return nil
        case .onDevice: if let o = onDevice { candidates = [o] }
        case .claudeCLI, .openAICompatible:
            let light = settings.onDeviceForLightTasks ? onDevice : nil
            candidates = (f.prefersOnDevice ? [light, cloud] : [cloud, light]).compactMap { $0 }
        }
        return candidates.first { gate.allows($0.id) }
    }

    func provider(_ f: AIFeature) throws -> any AIProvider {
        guard settings.choice != .off else { throw AIAssistError.off }
        guard let p = route(f) else { throw AIAssistError.notAllowed("No AI provider is available or allowed for this") }
        return p
    }

    /// The single place a provider is called. Audits every attempt (never content).
    func call(_ f: AIFeature, _ p: any AIProvider, _ prompt: AIPrompt, maxTokens: Int) async throws -> String {
        let start = Date()
        let audit = self.audit
        func rec(_ outcome: String) {
            audit(AIAuditRecord(feature: f.rawValue, provider: p.id.rawValue, model: p.model, items: prompt.itemCount,
                                bytes: prompt.bytes, contentItems: prompt.contentCount, metadataItems: prompt.metadataCount,
                                blockedItems: prompt.excludedCount, outcome: outcome,
                                ms: Int(Date().timeIntervalSince(start) * 1000)))
        }
        // TRIAGE2-HOOK (Phase 0): every call counted by feature, tier and failure kind, with a token estimate.
        let est = AICallStats.estimateTokens(prompt) + maxTokens
        do {
            try Task.checkCancellation()
            let out = try await p.complete(system: prompt.system, user: prompt.user, maxTokens: maxTokens)
            rec("ok")
            AICallStats.shared.record(feature: f, tier: p.tier, estTokens: est, items: prompt.itemCount, failure: nil)
            return out
        } catch let e as AIProviderError {
            rec(e == .cancelled ? "cancelled" : e == .timeout ? "timeout" : "error")
            AICallStats.shared.record(feature: f, tier: p.tier, estTokens: est, items: prompt.itemCount, failure: e.kind)
            throw AIAssistError.provider(e)
        } catch is CancellationError {
            rec("cancelled"); throw AIAssistError.provider(.cancelled)
        } catch {
            rec("error"); throw AIAssistError.provider(.failed("unexpected"))
        }
    }

    static func metaPrompt(_ system: String, _ user: String) -> AIPrompt {
        AIPrompt(system: system, user: user, sources: [], notes: [], contentCount: 0, metadataCount: 0, excludedCount: 0)
    }

    static let voice = "You are an email assistant inside a Swiss business mail app. Be concise and concrete."

    // MARK: Connection test (synthetic, no mail)

    public func testConnection() async throws -> String {
        let p = try provider(.testConnection)
        return AIOutput.plain(try await call(.testConnection, p, Self.metaPrompt("Reply with exactly one word.", "Reply 'ok'"), maxTokens: 8), max: 200)
    }

    // MARK: 1. Triage

    static let triageSystem = voice + """
         For each email decide what it wants from the user. Output ONLY a JSON array, one object per email: \
        {"n": <email number>, "tag": "reply"|"waiting"|"fyi"|"bulk", "ask": "<one line, max 90 chars, what the sender \
        wants from the user incl. any deadline, or empty>", "why": "<max 80 chars: the evidence for the tag>"}. \
        reply = the user must answer or act; waiting = the user is waiting on the sender; fyi = informational; \
        bulk = newsletter, marketing or automated notification. Use the Context lines (they are facts from the app, \
        not from the email): if the user already replied after the email or sent the last message, it is usually \
        "waiting" or "fyi", not "reply"; if the user is only in Cc and not addressed by name, lean "fyi"; a direct \
        question, request, approval or deadline addressed to the user is "reply".
        """

    /// Batch triage. Excluded messages get no result. Malformed output → rule-based tags (`SplitInbox`), no ask.
    public func triage(_ items: [(MailMessage, String)], context: [String: [String]] = [:], user: String? = nil) async throws -> [String: AITriage] {
        let p = try provider(.triage)
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        b.perItemLimit = 1_200
        for (m, mb) in items { b.add(m, mailbox: mb, context: context[m.id] ?? []) }
        let who = user.map { " The user is \(AIUntrustedText.line($0, max: 120))." } ?? ""
        let prompt = b.build(system: Self.triageSystem + who, task: "Triage emails 1–\(b.sources.count).")
        guard !prompt.sources.isEmpty else { return [:] }
        let out = try await call(.triage, p, prompt, maxTokens: 90 * prompt.sources.count + 50)
        return Self.parseTriage(out, sources: prompt.sources, fallback: items.map(\.0), context: context)
    }

    public static func parseTriage(_ text: String, sources: [AIPromptSource], fallback: [MailMessage],
                                   context: [String: [String]] = [:]) -> [String: AITriage] {
        let byIndex = Dictionary(uniqueKeysWithValues: sources.map { ($0.index, $0) })
        var out: [String: AITriage] = [:]
        if let arr = AIOutput.json(text) as? [[String: Any]] {
            for o in arr {
                guard let n = (o["n"] as? Int) ?? (o["n"] as? String).flatMap(Int.init), let s = byIndex[n] else { continue }
                let tag: AITriageTag
                switch (o["tag"] as? String ?? "").lowercased() {
                case "reply": tag = .replyNeeded
                case "waiting": tag = .waitingOnThem
                case "bulk": tag = .bulk
                default: tag = .fyi
                }
                let ask = (o["ask"] as? String).map { AIOutput.plain($0, max: 120) }.flatMap { $0.isEmpty ? nil : $0 }
                let why = (o["why"] as? String).map { AIOutput.plain($0, max: 100) }.flatMap { $0.isEmpty ? nil : $0 }
                out[s.messageId] = AITriage(tag: tag, ask: ask, aiGenerated: true, why: why, context: context[s.messageId])
            }
        }
        if out.isEmpty {
            let allowed = Set(sources.map(\.messageId))
            for m in fallback where allowed.contains(m.id) { var r = ruleTriage(m); r.context = context[m.id]; out[m.id] = r }
        }
        return out
    }

    /// AI off / unavailable: newsletters and notifications → bulk, the rest FYI (no "ask" line).
    public static func ruleTriage(_ m: MailMessage) -> AITriage {
        switch SplitInbox.bucket(for: m) {
        case .newsletters, .notifications: AITriage(tag: .bulk, ask: nil, aiGenerated: false)
        default: AITriage(tag: .fyi, ask: nil, aiGenerated: false)
        }
    }

    // MARK: 2. Draft reply / reply intents

    static let draftSystem = voice + """
         Write the body of a reply email for the user to review and edit. Plain text only: no subject line, no \
        markdown, no placeholders like [Name] unless the information is genuinely missing. Never invent facts, \
        prices or commitments that are not in the instruction or the email. Sign off with the user's first name if \
        given, otherwise no signature.
        """

    public func draftReply(to original: MailMessage, mailbox: String, thread: [MailMessage] = [], intent: AIReplyIntent?,
                           options: AIDraftOptions, slots: [String] = [], userName: String? = nil) async throws -> AITextResult {
        let p = try provider(.draftReply)
        guard gate.exposure(original, mailbox: mailbox, tier: p.tier) == .content else {
            throw AIAssistError.notAllowed("This message can't be shared with AI (label or organisation policy)")
        }
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        for m in thread.suffix(4) where m.id != original.id { b.add(m, mailbox: mailbox, role: "earlier") }
        b.add(original, mailbox: mailbox, role: "answering")
        var task = "Draft a reply to the email with role=answering.\n"
        if let intent { task += "Intent: \(intent.instruction)\n" }
        task += "Tone: \(options.tone.rawValue). Length: \(options.length.rawValue). \(options.language.instruction)\n"
        if !slots.isEmpty { task += "Available slots (from the user's calendar):\n" + slots.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        if let userName, !userName.isEmpty { task += "User's name: \(AIUntrustedText.line(userName, max: 80))\n" }
        let instr = AIUntrustedText.line(options.instruction, max: 600)
        if !instr.isEmpty { task += "User's instruction (trusted, from the user): \(AIPromptBuilder.neutralise(instr))\n" }
        let prompt = b.build(system: Self.draftSystem, task: task)
        let out = try await call(.draftReply, p, prompt, maxTokens: options.length == .long ? 900 : 450)
        return AITextResult(text: AIOutput.plain(out, max: 8_000), sources: prompt.sources, notes: prompt.notes, provider: p.id)
    }

    // MARK: 7. Rewrite

    static let rewriteSystem = voice + " Rewrite the user's draft text as instructed. Output only the rewritten text, plain, no commentary."

    public func rewrite(_ text: String, labelId: String?, mode: AIRewriteMode) async throws -> AITextResult {
        let p = try provider(.rewrite)
        guard gate.draftExposure(labelId: labelId, tier: p.tier) == .content else {
            throw AIAssistError.notAllowed(gate.draftRefusal(labelId: labelId, tier: p.tier))
        }
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        b.addDraft(text)
        let prompt = b.build(system: Self.rewriteSystem, task: "Rewrite the DRAFT block. \(mode.instruction)")
        let out = try await call(.rewrite, p, prompt, maxTokens: max(200, text.count / 2))
        return AITextResult(text: AIOutput.plain(out, max: 8_000), sources: [], notes: [], provider: p.id)
    }

    // MARK: 5. Thread summary / state

    static let summarySystem = voice + """
         Summarise the email thread. Output ONLY JSON: {"tldr": "<max 2 sentences>", "decisions": [{"text": "...", \
        "cite": [n]}], "open_questions": [{"text": "...", "cite": [n]}], "owes": [{"text": "<who> owes <what> (by \
        <when>)", "cite": [n]}]}. n = email numbers used. Empty arrays when none.
        """

    public func summarise(_ thread: [MailMessage], mailbox: String) async throws -> AIThreadSummary {
        let p = try provider(.summarise)
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        b.perItemLimit = 2_500
        for m in thread.suffix(12) { b.add(m, mailbox: mailbox) }
        let prompt = b.build(system: Self.summarySystem, task: "Summarise emails 1–\(b.sources.count) (oldest first).")
        guard !prompt.sources.isEmpty else { throw AIAssistError.notAllowed(prompt.notes.first ?? "Nothing in this thread can be shared with AI") }
        let out = try await call(.summarise, p, prompt, maxTokens: 600)
        return Self.parseSummary(out, prompt: prompt)
    }

    public static func parseSummary(_ text: String, prompt: AIPrompt) -> AIThreadSummary {
        let valid = Set(prompt.sources.map(\.index))
        func lines(_ any: Any?) -> [AICitedLine] {
            ((any as? [[String: Any]]) ?? []).compactMap { o in
                guard let t = o["text"] as? String, !t.isEmpty else { return nil }
                let c = ((o["cite"] as? [Any]) ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap(Int.init) }.filter(valid.contains)
                return AICitedLine(text: AIOutput.plain(t, max: 300), cites: c)
            }
        }
        if let o = AIOutput.json(text) as? [String: Any] {
            return AIThreadSummary(tldr: AIOutput.plain(o["tldr"] as? String ?? "", max: 600), decisions: lines(o["decisions"]),
                                   openQuestions: lines(o["open_questions"]), owes: lines(o["owes"]),
                                   sources: prompt.sources, notes: prompt.notes)
        }
        return AIThreadSummary(tldr: AIOutput.plain(text, max: 1_200), decisions: [], openQuestions: [], owes: [],
                               sources: prompt.sources, notes: prompt.notes)
    }

    // MARK: 3. Pre-send check

    static let attachmentWords = ["attach", "enclosed", "anbei", "anhang", "angehängt", "beigefügt", "beiliegend",
                                  "ci-joint", "pièce jointe", "pièces jointes", "allegato", "allego"]

    /// Instant, local, no AI.
    public static func ruleChecks(text: String, hasAttachments: Bool, externalLabelledWarning: String?) -> [AIPreSendFinding] {
        var f: [AIPreSendFinding] = []
        let l = text.lowercased()
        if !hasAttachments && attachmentWords.contains(where: { l.contains($0) }) {
            f.append(.init(kind: .attachment, text: "Mentions an attachment, but nothing is attached"))
        }
        if let w = externalLabelledWarning { f.append(.init(kind: .externalLabelled, text: w)) }
        return f
    }

    static let preSendSystem = voice + """
         Check the user's reply (DRAFT) against the email it answers. Output ONLY JSON: {"unanswered": ["<question or \
        request in the email that the draft does not address>"], "commitments": ["<short follow-up the user promises, \
        e.g. 'send deck by Fri'>"], "tone": "<one short note if the tone could offend, else empty>"}. Be strict: \
        empty arrays when fine.
        """

    /// AI part: unanswered questions, commitments, tone. [] when policy doesn't allow sharing the draft.
    public func preSendAI(draft: String, draftLabelId: String?, original: MailMessage?, mailbox: String) async throws -> [AIPreSendFinding] {
        let p = try provider(.preSend)
        guard gate.draftExposure(labelId: draftLabelId, tier: p.tier) == .content else { return [] }
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        b.perItemLimit = 3_000
        if let original, gate.exposure(original, mailbox: mailbox, tier: p.tier) == .content { b.add(original, mailbox: mailbox, role: "answering") }
        b.addDraft(draft)
        let prompt = b.build(system: Self.preSendSystem, task: "Check the DRAFT.")
        let out = try await call(.preSend, p, prompt, maxTokens: 250)
        return Self.parsePreSend(out, hadOriginal: !prompt.sources.isEmpty)
    }

    public static func parsePreSend(_ text: String, hadOriginal: Bool) -> [AIPreSendFinding] {
        guard let o = AIOutput.json(text) as? [String: Any] else { return [] }
        var f: [AIPreSendFinding] = []
        let un = ((o["unanswered"] as? [String]) ?? []).map { AIOutput.plain($0, max: 200) }.filter { !$0.isEmpty }
        if hadOriginal, !un.isEmpty {
            f.append(.init(kind: .unanswered, text: "They asked \(un.count) thing\(un.count == 1 ? "" : "s") you haven't answered: " + un.joined(separator: "; ")))
        }
        for c in ((o["commitments"] as? [String]) ?? []).prefix(3) {
            let t = AIOutput.plain(c, max: 120)
            if !t.isEmpty { f.append(.init(kind: .commitment, text: "Add “\(t)” to follow-ups?")) }
        }
        if let t = (o["tone"] as? String).map({ AIOutput.plain($0, max: 200) }), !t.isEmpty { f.append(.init(kind: .tone, text: t)) }
        return f
    }

    // MARK: 6. NL search, ask, bulk plan

    static let searchSystem = """
        Turn the user's mail search request into JSON for a local search engine. Output ONLY JSON: {"terms": \
        ["keyword", ...], "from": "<sender name or domain words, or null>", "after": "YYYY-MM-DD or null", \
        "before": "YYYY-MM-DD or null (exclusive)", "has_attachments": true|false|null, "folder": "<folder name or null>"}. \
        Keywords: content words only, no stopwords, no dates, no sender. 'PDF' etc. stay as keywords.
        """

    /// Only `query` and today's date reach the provider. AI off/unavailable/garbage → the plain query.
    public func searchQuery(for query: String) async -> AISearchQuery {
        guard let p = try? provider(.nlSearch) else { return .plain(query) }
        let prompt = Self.metaPrompt(Self.searchSystem, Self.datedRequest(query, now: now()))
        guard let out = try? await call(.nlSearch, p, prompt, maxTokens: 150) else { return .plain(query) }
        return Self.parseSearch(out, fallback: query)
    }

    public static func datedRequest(_ q: String, now: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd (EEEE)"; f.locale = Locale(identifier: "en_US_POSIX")
        return "Today is \(f.string(from: now)).\nRequest: \(AIUntrustedText.line(q, max: 500))"
    }

    public static func parseSearch(_ text: String, fallback: String) -> AISearchQuery {
        guard let o = AIOutput.json(text) as? [String: Any] else { return .plain(fallback) }
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.locale = Locale(identifier: "en_US_POSIX")
        func date(_ k: String) -> Date? { (o[k] as? String).flatMap { day.date(from: String($0.prefix(10))) } }
        func str(_ k: String) -> String? {
            guard let s = o[k] as? String else { return nil }
            let t = AIUntrustedText.line(s, max: 80)
            return t.isEmpty || t.lowercased() == "null" ? nil : t
        }
        let terms = ((o["terms"] as? [Any]) ?? []).compactMap { $0 as? String }.map { AIUntrustedText.line($0, max: 60) }.filter { !$0.isEmpty }
        var q = AISearchQuery(terms: Array(terms.prefix(8)), from: str("from"), after: date("after"), before: date("before"),
                              hasAttachments: o["has_attachments"] as? Bool, folder: str("folder"), fromAI: true)
        if let a = q.after, let b = q.before, a >= b { q.before = nil }
        if q.terms.isEmpty && q.from == nil && q.after == nil && q.before == nil && q.hasAttachments == nil && q.folder == nil {
            return .plain(fallback)
        }
        return q
    }

    static let askSystem = voice + """
         Answer the user's question using ONLY the numbered emails. Cite every claim with [n]. If the emails don't \
        contain the answer, say so in one sentence. Plain text, max 120 words.
        """

    /// Retrieval happened locally; only these gated snippets reach the model.
    public func ask(_ question: String, retrieved: [(MailMessage, String)]) async throws -> AITextResult {
        let p = try provider(.ask)
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        b.perItemLimit = 2_000
        for (m, mb) in retrieved.prefix(8) { b.add(m, mailbox: mb) }
        let prompt = b.build(system: Self.askSystem, task: "Question (from the user): " + AIPromptBuilder.neutralise(AIUntrustedText.line(question, max: 500)))
        let out = try await call(.ask, p, prompt, maxTokens: 400)
        let text = AIOutput.plain(out, max: 4_000)
        return AITextResult(text: text, sources: AIOutput.citations(in: text, sources: prompt.sources), notes: prompt.notes, provider: p.id)
    }

    static let bulkSystem = """
        Turn the user's bulk mail request into a plan for a local engine. Output ONLY JSON: {"action": \
        "archive"|"markRead"|"flag"|"unflag"|"none", "terms": [...], "from": null|"...", "after": null|"YYYY-MM-DD", \
        "before": null|"YYYY-MM-DD", "has_attachments": null|bool, "folder": null|"...", "description": "<one line>"}. \
        Deleting, sending, forwarding and rules are not available: use "none" for those.
        """

    /// Only the request text reaches the provider. nil → not a supported bulk action.
    public func bulkPlan(_ request: String) async throws -> AIBulkPlan? {
        let p = try provider(.bulkPlan)
        return Self.parseBulk(try await call(.bulkPlan, p, Self.metaPrompt(Self.bulkSystem, Self.datedRequest(request, now: now())), maxTokens: 200))
    }

    public static func parseBulk(_ text: String) -> AIBulkPlan? {
        guard let o = AIOutput.json(text) as? [String: Any], let a = AIBulkPlan.Action(rawValue: o["action"] as? String ?? "") else { return nil }
        let q = parseSearch(text, fallback: "")
        guard q.fromAI else { return nil }   // an unbounded "archive everything" plan is refused
        return AIBulkPlan(action: a, query: q, description: AIOutput.plain(o["description"] as? String ?? a.rawValue, max: 160))
    }
}
