import Foundation

// TRIAGE2: L3, one item = one conversation (plan §4.4). The JSON path is used on both tiers: `@Generable` is a
// macro and macros don't compile with this toolchain (see the report / BACKLOG).

/// One conversation for the LLM: the newest inbound message plus ≤ 2 earlier ones (incl. my last sent), oldest first.
public struct ThreadItem: Sendable {
    public var conversationId: String
    public var messages: [MailMessage]
    public var mailbox: String
    /// Content-free facts as `Context:` lines (ours, never mail text).
    public var context: [String]
    public init(conversationId: String, messages: [MailMessage], mailbox: String, context: [String]) {
        self.conversationId = conversationId; self.messages = messages; self.mailbox = mailbox; self.context = context
    }

    /// Picks the messages for a thread: newest inbound + up to two earlier (my last sent first).
    public static func pick(_ all: [MailMessage], isMine: (MailMessage) -> Bool) -> [MailMessage] {
        let ms = all.filter { !$0.isDraft }.sorted { $0.received < $1.received }
        guard let iLast = ms.lastIndex(where: { !isMine($0) }) ?? ms.indices.last else { return [] }
        var picked = [ms[iLast]]
        if let mine = ms.indices.last(where: { isMine(ms[$0]) && $0 != iLast }) { picked.append(ms[mine]) }
        if let other = ms.indices.last(where: { $0 != iLast && !picked.contains(ms[$0]) }) { picked.append(ms[other]) }
        return picked.sorted { $0.received < $1.received }
    }

    /// Context lines from facts (content-free).
    public static func contextLines(_ f: ConversationFacts, rule: TriageDecision) -> [String] {
        var out: [String] = []
        let role: String = switch f.myRole { case .to: "To"; case .cc: "Cc"; case .bccOrList: "neither To nor Cc (Bcc or a list)"; case .unknown: "unknown" }
        out.append("User is in: \(role); other recipients: \(f.otherRecipients.map(String.init) ?? "unknown")")
        out.append("Thread: \(f.inboundCount) from others, \(f.outboundCount) from the user; the user \(f.iStarted ? "started" : "didn't start") it")
        out.append("Last message is from \(f.lastFromMe ? "the user" : "someone else")\(f.repliedAfterLastInbound ? "; the user already replied" : "")")
        if !f.lastFromMe { out.append("Sender is \(f.senderInternal ? "internal (same organisation)" : "external")") }
        out.append("Rule hint: \(rule.state.rawValue) (\(rule.confidence == .low ? "uncertain" : "fairly sure"))")
        return out
    }
}

public enum ThreadBatcher {
    /// Splits items into batches that fit `budget` tokens (chars / 4), leaving `perItemOutput` per item.
    public static func batches(_ items: [ThreadItem], budget: Int, perItemOutput: Int = 60, perMessageChars: Int, maxItems: Int) -> [[ThreadItem]] {
        var out: [[ThreadItem]] = [], cur: [ThreadItem] = [], used = 400   // system prompt + framing
        for it in items {
            let cost = (it.messages.count * (perMessageChars + 220) + it.context.joined().count + 200) / 4 + perItemOutput
            if !cur.isEmpty && (used + cost > budget || cur.count >= maxItems) { out.append(cur); cur = []; used = 400 }
            cur.append(it); used += cost
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

extension AIAssistant {
    static let threadTriageSystem = voice + """
         Each numbered thread below is one email conversation. For each thread decide who acts next. Output ONLY a \
        JSON array, one object per thread: {"t": <thread number>, "state": "reply"|"waiting"|"fyi"|"done", \
        "ask": "<one line, max 90 chars, what the user must do incl. any deadline, or empty>", "why": "<max 80 chars>"}. \
        reply = the user must answer or act; waiting = the user asked something and waits for the others; fyi = \
        informational, nothing to do; done = the thread is closed (thanks, confirmation, answered). The Context lines \
        are facts from the app, not from the email.
        """

    /// Per-thread L3. Missing items are simply absent (the caller keeps the L1 state for them).
    public func triageThreads(_ items: [ThreadItem], user: String? = nil) async throws -> [String: ThreadVerdict] {
        let p = try provider(.triage)
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        b.perItemLimit = p.tier == .onDevice ? 600 : 1_200
        var threadOf: [Int: Int] = [:]   // source index → thread number
        var numbered: [(Int, ThreadItem)] = []
        for it in items {
            let n = numbered.count + 1
            var added = false
            for (k, m) in it.messages.enumerated() {
                let ctx = k == it.messages.count - 1 ? it.context : []
                if let idx = b.add(m, mailbox: it.mailbox, role: "thread\(n)", context: ctx) { threadOf[idx] = n; added = true }
            }
            if added { numbered.append((n, it)) }
        }
        guard !numbered.isEmpty else { return [:] }
        let who = user.map { " The user is \(AIUntrustedText.line($0, max: 120))." } ?? ""
        let prompt = b.build(system: Self.threadTriageSystem + who,
                             task: "Messages are tagged role=threadN. Decide threads 1–\(numbered.count).")
        let out = try await call(.triage, p, prompt, maxTokens: 70 * numbered.count + 40)
        return Self.parseThreadVerdicts(out, threads: Dictionary(uniqueKeysWithValues: numbered.map { ($0.0, $0.1.conversationId) }))
    }

    /// Defensive parse: unknown numbers and malformed objects are skipped (partial output keeps the rest).
    public static func parseThreadVerdicts(_ text: String, threads: [Int: String]) -> [String: ThreadVerdict] {
        guard let arr = AIOutput.json(text) as? [[String: Any]] else { return [:] }
        var out: [String: ThreadVerdict] = [:]
        for o in arr {
            guard let n = (o["t"] as? Int) ?? (o["t"] as? String).flatMap(Int.init), let cid = threads[n] else { continue }
            let state: ConversationState
            switch (o["state"] as? String ?? "").lowercased() {
            case "reply", "needsreply": state = .needsReply
            case "waiting": state = .waiting
            case "done": state = .done
            case "fyi": state = .fyi
            default: continue
            }
            let ask = (o["ask"] as? String).map { AIOutput.plain($0, max: 120) }.flatMap { $0.isEmpty ? nil : $0 }
            let why = (o["why"] as? String).map { AIOutput.plain($0, max: 100) }.flatMap { $0.isEmpty ? nil : $0 }
            out[cid] = ThreadVerdict(state: state, ask: ask, why: why)
        }
        return out
    }

    /// Batches by token budget; on a context overflow halves the batch and retries once; any other failure keeps
    /// the L1 state (empty result for that batch). Failures are counted by kind in `failures`.
    public func triageThreadsResilient(_ items: [ThreadItem], user: String? = nil, contextTokens: Int?,
                                       failures: @Sendable (AIFailureKind, Int) -> Void = { _, _ in }) async -> [String: ThreadVerdict] {
        guard let p = route(.triage) else { return [:] }
        let onDevice = p.tier == .onDevice
        let budget = onDevice ? (contextTokens ?? 4_096) : 24_000
        let batches = ThreadBatcher.batches(items, budget: budget, perMessageChars: onDevice ? 600 : 1_200, maxItems: onDevice ? 6 : 12)
        var out: [String: ThreadVerdict] = [:]
        for batch in batches {
            if Task.isCancelled { break }
            do { out.merge(try await triageThreads(batch, user: user)) { a, _ in a } }
            catch AIAssistError.provider(let e) where e.kind == .contextOverflow && batch.count > 1 {
                failures(.contextOverflow, batch.count)
                let half = batch.count / 2
                for part in [Array(batch[..<half]), Array(batch[half...])] {
                    do { out.merge(try await triageThreads(part, user: user)) { a, _ in a } }
                    catch AIAssistError.provider(let e) { failures(e.kind, part.count) }
                    catch { failures(.other, part.count) }
                }
            } catch AIAssistError.provider(let e) { failures(e.kind, batch.count) }
            catch { failures(.other, batch.count) }
        }
        return out
    }
}
