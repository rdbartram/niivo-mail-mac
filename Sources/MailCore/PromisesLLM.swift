import Foundation

// PROMISES: optional on-device pass over UNCERTAIN rule candidates only (plain JSON; `@Generable` is a macro and
// macros don't compile with this toolchain). Candidates are referred to by number: the Context line carries app
// facts (kind), never mail text. Cloud tiers are refused without a call.

public struct PromiseRefineItem: Sendable {
    public var promiseId: String
    public var kind: PromiseKind
    public var message: MailMessage
    public var mailbox: String
    public init(promiseId: String, kind: PromiseKind, message: MailMessage, mailbox: String) {
        self.promiseId = promiseId; self.kind = kind; self.message = message; self.mailbox = mailbox
    }
}

public struct PromiseRefinement: Sendable, Hashable {
    public var keep: Bool
    public var text: String?
    public var due: Date?
}

extension AIAssistant {
    static let promiseRefineSystem = """
        Each numbered email below (role=pN) was written by or to the user. The app thinks message pN may contain a \
        commitment (kind=promised: the USER says they will do something) or a request to the user with a deadline \
        (kind=asked). Decide if that is really so. Hypotheticals, quoted text, out-of-office notes, third-party \
        promises and things already done are NOT commitments. Output ONLY a JSON array, one object per message: \
        {"p": <number>, "keep": true|false, "text": "<the commitment as a short verb phrase, max 80 chars, or empty>", \
        "due": "<YYYY-MM-DD or empty>"}.
        """

    /// On-device only; returns promise id → refinement (missing items keep the rule result).
    public func refinePromises(_ items: [PromiseRefineItem], calendar: Calendar = .current) async throws -> [String: PromiseRefinement] {
        let p = try provider(.triage)
        guard p.tier == .onDevice else { throw AIAssistError.notAllowed("Promise refinement runs on-device only") }
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        b.perItemLimit = 600
        var numbered: [Int: String] = [:]
        for it in items.prefix(6) {
            let n = numbered.count + 1
            if b.add(it.message, mailbox: it.mailbox, role: "p\(n)", context: ["Candidate kind: \(it.kind.rawValue)"]) != nil { numbered[n] = it.promiseId }
        }
        let prompt = b.build(system: Self.promiseRefineSystem, task: "Decide messages p1–p\(max(1, numbered.count)).")
        guard !numbered.isEmpty, prompt.contentCount > 0 else { return [:] }
        let out = try await call(.triage, p, prompt, maxTokens: 60 * numbered.count + 40)
        return Self.parsePromiseRefinements(out, items: numbered, calendar: calendar)
    }

    /// Defensive parse: unknown numbers / malformed objects skipped; text clamped to 80; bad dates ignored.
    public static func parsePromiseRefinements(_ text: String, items: [Int: String], calendar: Calendar = .current) -> [String: PromiseRefinement] {
        guard let arr = AIOutput.json(text) as? [[String: Any]] else { return [:] }
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var out: [String: PromiseRefinement] = [:]
        for o in arr {
            guard let n = (o["p"] as? Int) ?? (o["p"] as? String).flatMap(Int.init), let id = items[n], let keep = o["keep"] as? Bool else { continue }
            let t = (o["text"] as? String).map { String(AIUntrustedText.line(AIOutput.plain($0, max: 200), max: 200).prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 }
            let due = (o["due"] as? String).flatMap { f.date(from: $0) }.map { calendar.startOfDay(for: $0) }
            out[id] = PromiseRefinement(keep: keep, text: t, due: due)
        }
        return out
    }
}
