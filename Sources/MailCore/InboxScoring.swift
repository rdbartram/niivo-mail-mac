import Foundation

// TRIAGE2: Phase 0 counters and the owner's triage scoring (plan §8.3, Phase 1 training tool). Counts only: no
// subjects, names, addresses or ids ever reach these types' log lines.

/// Process-wide AI call counters (Phase 0, H1–H3): per feature, routed tier, failure kind and token estimate.
public final class AICallStats: @unchecked Sendable {
    public static let shared = AICallStats()
    private let lock = NSLock()
    public struct Entry: Sendable, Hashable {
        public var calls = 0, ok = 0, items = 0
        public var onDevice = 0, cloud = 0
        public var failures: [AIFailureKind: Int] = [:]
        public var maxEstTokens = 0, sumEstTokens = 0
    }
    private var entries: [String: Entry] = [:]

    /// Characters / 4 — a deliberate over-estimate for DE/FR/IT; compared with the model's context size in the log.
    public static func estimateTokens(_ p: AIPrompt) -> Int { (p.system.count + p.user.count + 3) / 4 }

    public func record(feature: AIFeature, tier: AITier, estTokens: Int, items: Int, failure: AIFailureKind?) {
        lock.withLock {
            var e = entries[feature.rawValue] ?? Entry()
            e.calls += 1; e.items += items
            if tier == .onDevice { e.onDevice += 1 } else { e.cloud += 1 }
            if let failure { e.failures[failure, default: 0] += 1 } else { e.ok += 1 }
            e.maxEstTokens = max(e.maxEstTokens, estTokens); e.sumEstTokens += estTokens
            entries[feature.rawValue] = e
        }
    }

    public func entry(_ f: AIFeature) -> Entry { lock.withLock { entries[f.rawValue] ?? Entry() } }
    public func reset() { lock.withLock { entries = [:] } }

    /// One content-free line, e.g. `calls=4 ok=2 onDevice=4 cloud=0 fail[contextOverflow=2] estTok max=5210 avg=4100 ctx=4096`.
    public func line(_ f: AIFeature, contextTokens: Int?) -> String {
        let e = entry(f)
        let fails = AIFailureKind.allCases.compactMap { k in e.failures[k].map { "\(k.rawValue)=\($0)" } }.joined(separator: ",")
        return "calls=\(e.calls) ok=\(e.ok) items=\(e.items) onDevice=\(e.onDevice) cloud=\(e.cloud) fail[\(fails)] "
            + "estTok max=\(e.maxEstTokens) avg=\(e.calls > 0 ? e.sumEstTokens / e.calls : 0) ctx=\(contextTokens.map(String.init) ?? "n/a")"
    }
}

// MARK: - Ground truth and scoring

/// One answer from the training tool. Stored sealed, per account, keyed by the conversation HMAC + a tag of the
/// snapshot time (TRIAGE3: "who acts next" is a judgement as of the newest message the user saw).
public struct TriageTruth: Codable, Sendable, Hashable {
    /// nil = skipped.
    public var truth: ConversationState?
    /// What the app predicted as of the snapshot, with the conversation's own override ignored (so answers can't
    /// score themselves).
    public var predicted: ConversationState
    public var predictedConfidence: TriageConfidence
    /// The conversation's event signature when answered (pre-snapshot rows are migrated with it).
    public var eventSignature: UInt64
    public var wrongSenderType: Bool
    public var answeredAt: Date
    /// TRIAGE3: the newest message the user saw. nil = answered before snapshots and not derivable: not scored.
    public var snapshot: TriageSnapshot?
    /// TRIAGE3: inbox membership when answered (as-of prediction uses it instead of today's folders).
    public var inboxAtSnapshot: Bool?
    public init(truth: ConversationState?, predicted: ConversationState, predictedConfidence: TriageConfidence,
                eventSignature: UInt64, wrongSenderType: Bool = false, answeredAt: Date,
                snapshot: TriageSnapshot? = nil, inboxAtSnapshot: Bool? = nil) {
        self.truth = truth; self.predicted = predicted; self.predictedConfidence = predictedConfidence
        self.eventSignature = eventSignature; self.wrongSenderType = wrongSenderType; self.answeredAt = answeredAt
        self.snapshot = snapshot; self.inboxAtSnapshot = inboxAtSnapshot
    }
}

/// TRIAGE3: one answer ready for scoring: the prediction as of its snapshot, and whether the conversation has moved on
/// (newer messages) since. Moving on never makes an answer wrong; only unpinned (pre-snapshot) answers are left out.
public struct TriageTruthRow: Sendable, Hashable {
    public var truth: TriageTruth
    public var predictedAsOf: ConversationState
    public var movedOn: Bool
    public var pinned: Bool { truth.snapshot != nil }
    public init(truth: TriageTruth, predictedAsOf: ConversationState? = nil, movedOn: Bool = false) {
        self.truth = truth; self.predictedAsOf = predictedAsOf ?? truth.predicted; self.movedOn = movedOn
    }
}

public struct TriageScore: Sendable, Hashable {
    public struct PRF: Sendable, Hashable { public var precision: Double; public var recall: Double; public var f1: Double; public var support: Int }
    public var labelled: Int
    public var skipped: Int
    /// TRIAGE3: answers saved before snapshots whose snapshot couldn't be derived (left out).
    public var stale: Int
    /// TRIAGE3: scored answers whose conversation has newer messages since (scored as of the snapshot).
    public var movedOn: Int
    public var wrongSenderType: Int
    /// confusion[truth][predicted]
    public var confusion: [ConversationState: [ConversationState: Int]]
    public var perState: [ConversationState: PRF]
    public var accuracy: Double
    /// % of inbox conversations with a displayed state (the UI map), and the newest ones without one.
    public var coverage: Double
    public var missedLatest: Int

    /// Content-free one-liner (`[TriageScore] …`).
    public var line: String {
        func f(_ d: Double) -> String { String(format: "%.2f", d) }
        var s = "n=\(labelled) skipped=\(skipped) unpinned=\(stale) movedOn=\(movedOn) wrongSender=\(wrongSenderType) acc=\(f(accuracy))"
        for st in ConversationState.allCases { if let p = perState[st] { s += " \(st.rawValue)[P=\(f(p.precision)) R=\(f(p.recall)) F1=\(f(p.f1)) n=\(p.support)]" } }
        let cm = ConversationState.allCases.map { t in ConversationState.allCases.map { "\(confusion[t]?[$0] ?? 0)" }.joined(separator: ",") }.joined(separator: "|")
        s += " confusion[t→p nr,w,f,d]=\(cm) coverage=\(f(coverage)) missedLatest=\(missedLatest)"
        return s
    }
}

public enum TriageScoring {
    /// TRIAGE3: each answer against the prediction as of its snapshot. Later messages don't count against it;
    /// unpinned (pre-snapshot, not derivable) answers are left out.
    public static func score(_ rows: [TriageTruthRow], coverage: Double, missedLatest: Int) -> TriageScore {
        var confusion: [ConversationState: [ConversationState: Int]] = [:]
        var labelled = 0, skipped = 0, stale = 0, moved = 0, wrong = 0, correct = 0
        for r in rows {
            let t = r.truth
            if t.wrongSenderType { wrong += 1 }
            guard let truth = t.truth else { skipped += 1; continue }
            guard r.pinned else { stale += 1; continue }
            labelled += 1
            if r.movedOn { moved += 1 }
            confusion[truth, default: [:]][r.predictedAsOf, default: 0] += 1
            if truth == r.predictedAsOf { correct += 1 }
        }
        var per: [ConversationState: TriageScore.PRF] = [:]
        for s in ConversationState.allCases {
            let tp = confusion[s]?[s] ?? 0
            let predicted = ConversationState.allCases.reduce(0) { $0 + (confusion[$1]?[s] ?? 0) }
            let support = confusion[s]?.values.reduce(0, +) ?? 0
            let p = predicted > 0 ? Double(tp) / Double(predicted) : 0
            let r = support > 0 ? Double(tp) / Double(support) : 0
            per[s] = .init(precision: p, recall: r, f1: p + r > 0 ? 2 * p * r / (p + r) : 0, support: support)
        }
        return TriageScore(labelled: labelled, skipped: skipped, stale: stale, movedOn: moved, wrongSenderType: wrong, confusion: confusion,
                           perState: per, accuracy: labelled > 0 ? Double(correct) / Double(labelled) : 0,
                           coverage: coverage, missedLatest: missedLatest)
    }

    /// Coverage over the inbox conversations the UI lists, and how many of the newest `latest` have no state.
    public static func coverage(listed: [String], hasState: (String) -> Bool, latest: Int = 30) -> (coverage: Double, missedLatest: Int) {
        guard !listed.isEmpty else { return (1, 0) }
        let n = listed.filter(hasState).count
        return (Double(n) / Double(listed.count), listed.prefix(latest).filter { !hasState($0) }.count)
    }
}

// MARK: - Stratified training sample

public enum TriageSampler {
    /// Up to `n` conversation ids: a share from each predicted state plus the uncertain ones, newest first within
    /// a stratum, interleaved so a short session still covers every state. Deterministic for a given input.
    public static func stratify(_ items: [(id: String, decision: TriageDecision, latest: Date)], n: Int = 100,
                                exclude: Set<String> = []) -> [String] {
        let pool = items.filter { !exclude.contains($0.id) }.sorted { $0.latest > $1.latest }
        var strata: [[String]] = [
            pool.filter { $0.decision.confidence == .low }.map(\.id),
            pool.filter { $0.decision.confidence > .low && $0.decision.state == .needsReply }.map(\.id),
            pool.filter { $0.decision.confidence > .low && $0.decision.state == .waiting }.map(\.id),
            pool.filter { $0.decision.confidence > .low && $0.decision.state == .fyi }.map(\.id),
            pool.filter { $0.decision.confidence > .low && $0.decision.state == .done }.map(\.id),
        ]
        var out: [String] = []
        while out.count < n, strata.contains(where: { !$0.isEmpty }) {
            for i in strata.indices where !strata[i].isEmpty && out.count < n { out.append(strata[i].removeFirst()) }
        }
        return out
    }
}
