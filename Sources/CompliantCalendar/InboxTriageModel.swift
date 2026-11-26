import SwiftUI
import MailCore
import CalendarCore

// TRIAGE2: app side of conversation triage (docs/INBOX-INTELLIGENCE-PLAN.md Phase 1).
// * A loop (every 3 s while mail is open) refreshes dirty conversations off the main actor and publishes one
//   decision per conversation. No `onChange(prefix(30))` trigger, no top-30 limit: every conversation in the window.
// * L3 runs only for the uncertain band and for needsReply without an ask line, visible rows first, through the
//   normal AI gate and tier routing. Rows keep their rule state whatever happens to the AI call.
// * Logs are content-free counts (`[Triage] …`, `[AI] triage threads …`).

@MainActor @Observable
final class InboxTriageModel {
    @ObservationIgnored weak var ai: AIAssistModel?
    /// Conversation id → decision (in scope only). The UI reads this.
    private(set) var decisions: [String: TriageDecision] = [:]
    var status: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var l3: Task<Void, Never>?
    @ObservationIgnored private var lastGen = -1
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var configKey = ""
    @ObservationIgnored private var configGateKey = ""
    @ObservationIgnored private var l3Tried: [String: UInt64] = [:]
    @ObservationIgnored private var lastLog = ""
    /// H0 shadow counter (Phase 0): the legacy cache key per visible message id; a change for the same id is a
    /// tag the old path would have orphaned.
    @ObservationIgnored private var legacyKeys: [String: String] = [:]
    @ObservationIgnored private var h0Changed = 0
    @ObservationIgnored private var h0Seen = 0

    init(ai: AIAssistModel) { self.ai = ai }

    var enabled: Bool { ai?.settings.usesConversationTriage ?? false }
    var engine: InboxTriageEngine? { ai?.mail?.store?.triage }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Lock / wipe / settings change: memory goes; the sealed tables stay with the store. The loop keeps running
    /// (its tick does nothing while locked or off), because `.task` won't start it again.
    func reset() {
        l3?.cancel(); l3 = nil
        decisions = [:]; lastGen = -1; configKey = ""; l3Tried = [:]; legacyKeys = [:]
    }

    /// Mail ▸ Re-triage: recompute everything and let L3 try the uncertain rows again (overrides stay).
    func rerun() {
        l3Tried = [:]; lastGen = -1
        engine?.policyChanged()
        ai?.mail?.toast(MailToast(text: "Re-triaging conversations…", symbol: "sparkles"))
        Task { await tick() }
    }

    // MARK: Engine configuration (per account)

    private func configure() -> InboxTriageEngine? {
        guard let ai, let mail = ai.mail, mail.started, let store = mail.store else { return nil }
        let t = ai.trustPolicy
        var od = AIOrgAccess(trustRawValue: t.effectiveOnDeviceAIAccess.rawValue)
        // Interpretation: these are local rules, not a model. With on-device AI switched off they still use
        // metadata (direction, To/Cc) but never read text for cues.
        if od == .off { od = .metadataOnly }
        let gate = AIGatePolicy(engine: mail.compliance, cloudAccess: .off, onDeviceAccess: od)
        let me = mail.me?.address.lowercased() ?? ""
        // Shared / delegated mailboxes count as "me" in their own threads (else mail to them reads as Bcc/list → FYI).
        let owners = Set([me] + mail.settings.identities.map { $0.address.lowercased() }
                         + mail.mailboxes.filter { $0 != "me" }.map { $0.lowercased() }).subtracting([""])
        let first = mail.me?.name.split(separator: " ").first.map(String.init)
        let account = ai.app?.auth?.accountKey ?? "default"
        let route = ai.assistant?.route(.triage).map { "\($0.tier.rawValue)" } ?? "none"
        let gateKey = [account, "\(od)", "\(mail.compliance.availableLabels().count)", route, "\(ai.trustPolicy.allowOfflineBodies)"].joined(separator: "|")
        let key = [gateKey, owners.sorted().joined(separator: ","), first ?? "", "\(ai.settings.triageSettings.waitingDays)"].joined(separator: "|")
        if let e = store.triage, key == configKey { return e }
        let cfg = InboxTriageEngine.Config(account: account, owners: owners, internalDomains: mail.settings.internalDomains,
                                           firstName: first, exposure: { m, mb in gate.exposure(m, mailbox: mb, tier: .onDevice) },
                                           settings: ai.settings.triageSettings)
        let fresh = store.triage == nil
        let e = store.enableInboxTriage(cfg)
        if !fresh { e.policyChanged() }
        // Access, labels, provider/tier or offline policy changed: stored L3 results (incl. ask text) go (plan §3).
        if !configKey.isEmpty, gateKey != configGateKey { e.dropVerdicts(); l3Tried = [:] }
        configKey = key; configGateKey = gateKey
        return e
    }

    // MARK: Tick

    func tick() async {
        guard enabled, let ai, let mail = ai.mail, !(ai.app?.trust.hidesContent ?? false), let engine = configure() else { return }
        let n = await Task.detached(priority: .utility) { engine.refresh() }.value
        let gen = engine.generation
        // Time-based states (N-day waiting, nudges) need a re-read now and then even without changes.
        guard gen != lastGen || n > 0 || Date().timeIntervalSince(lastPublish) > 60 else { return }
        lastGen = gen; lastPublish = Date()
        let ds = await Task.detached(priority: .utility) { engine.decisions() }.value
        decisions = ds
        TodayModel.shared.triageChanged(mail)   // TODAY-HOOK
        shadowH0(mail)
        log(ds)
        scheduleL3()
    }

    private func log(_ ds: [String: TriageDecision]) {
        var by: [ConversationState: Int] = [:]
        var badge = 0, maybe = 0, restricted = 0, llm = 0, user = 0
        for d in ds.values {
            by[d.state, default: 0] += 1
            if d.showsBadge { badge += 1 }; if d.isMaybe { maybe += 1 }; if d.restricted { restricted += 1 }
            if d.source == .llm { llm += 1 }; if d.source == .user { user += 1 }
        }
        let listed = Set((ai?.mail?.visibleRows ?? []).map(\.message.conversationId))
        let untagged = listed.filter { ds[$0] == nil }.count
        let line = "conversations=\(ds.count) " + ConversationState.allCases.map { "\($0.rawValue)=\(by[$0] ?? 0)" }.joined(separator: " ")
            + " badge=\(badge) maybe=\(maybe) restricted=\(restricted) llm=\(llm) user=\(user) listedUntagged=\(untagged)/\(listed.count)"
            + " h0 legacyKeyChanged=\(h0Changed)/\(h0Seen)"
        guard line != lastLog else { return }
        lastLog = line
        FileHandle.standardError.write(Data("[Triage] \(line)\n".utf8))
    }

    /// H0: would the legacy key (id + changeKey + label + exposure + tier) have changed for the same message id?
    private func shadowH0(_ mail: MailModel) {
        guard let ai, let g = ai.lastGate else { return }
        let tier = ai.assistant?.route(.triage)?.tier ?? .onDevice
        for r in mail.isInbox ? mail.visibleRows.prefix(30) : [] {
            let k = AICacheKey.triage(r.message, exposure: g.exposure(r.message, mailbox: r.mailbox, tier: tier), tier: tier)
            if let old = legacyKeys[r.id] { h0Seen += 1; if old != k { h0Changed += 1 } }
            legacyKeys[r.id] = k
        }
    }

    // MARK: Reads for the UI

    func decision(for row: MailRow) -> TriageDecision? { decisions[row.message.conversationId] }

    func display(for row: MailRow) -> TriageDisplay? {
        decision(for: row).map { TriageDisplay.from($0) }
    }

    // MARK: Corrections (one click; the training tool uses the same engine call)

    func correct(_ row: MailRow, to state: ConversationState) {
        guard let e = engine else { return }
        e.correct(conversationId: row.message.conversationId, to: state)
        republish(row.message.conversationId)
    }

    /// Reply needed → Waiting → None (FYI) → Reply needed.
    func cycle(_ row: MailRow) {
        let cur = decision(for: row)
        let next: ConversationState = switch (cur?.showsBadge ?? false) ? cur!.state : .fyi {
        case .needsReply: .waiting
        case .waiting: .fyi
        default: .needsReply
        }
        correct(row, to: next)
    }

    func neverFromSender(_ row: MailRow) {
        guard let e = engine, let a = row.message.from?.address else { return }
        e.setSenderOverride(a, .neverNeedsReply)
        republish()
    }

    func clearOverride(_ row: MailRow) {
        engine?.clearOverride(conversationId: row.message.conversationId)
        republish(row.message.conversationId)
    }

    /// One conversation only (corrections, training answers): no full pass on the main actor.
    func republish(_ cid: String) {
        guard let e = engine else { return }
        decisions[cid] = e.scopedDecision(for: cid)
        if let mail = ai?.mail { TodayModel.shared.triageChanged(mail) }   // TODAY-HOOK
    }

    func republish() {
        guard let e = engine else { return }
        decisions = e.decisions()
        lastGen = e.generation
    }

    // MARK: Briefing (by conversation, ordered by ball and age)

    struct Group: Identifiable { var id: String { title }; var tag: AITriageTag; var title: String; var rows: [MailRow] }

    func briefing() -> [Group] {
        guard let mail = ai?.mail, let store = mail.store else { return [] }
        let visible = Dictionary(mail.visibleRows.map { ($0.message.conversationId, $0) }, uniquingKeysWith: { a, _ in a })
        func row(_ cid: String) -> MailRow? {
            if let r = visible[cid] { return r }
            guard let m = ((try? store.conversation(id: cid, limit: 200)) ?? []).last(where: { !$0.isDraft }) else { return nil }
            let mb = store.mailbox(forFolder: m.folderId)
            return MailRow(message: m, mailbox: mb, count: 1, policy: mail.policy(for: m, mailbox: mb))
        }
        let ds = decisions.filter { !$0.value.snoozed }.sorted { ($0.value.since ?? .distantPast) > ($1.value.since ?? .distantPast) }
        var reply: [MailRow] = [], follow: [MailRow] = [], waiting: [MailRow] = [], fyi: [MailRow] = [], bulk: [MailRow] = []
        let today = Calendar.current.startOfDay(for: .now)
        for (cid, d) in ds {
            switch d.state {
            case .needsReply where d.showsBadge: if let r = row(cid) { reply.append(r) }
            case .waiting where d.showsBadge:
                if let r = row(cid) { if case .followUp? = d.nudge { follow.append(r) } else { waiting.append(r) } }
            case .fyi where (d.since ?? .distantPast) >= today:
                if let r = visible[cid] { if d.channel == .person { fyi.append(r) } else { bulk.append(r) } }
            default: break
            }
        }
        return [Group(tag: .replyNeeded, title: "Reply needed", rows: reply), Group(tag: .waitingOnThem, title: "Follow up?", rows: follow),
                Group(tag: .waitingOnThem, title: "Waiting", rows: waiting), Group(tag: .fyi, title: "FYI today", rows: fyi),
                Group(tag: .bulk, title: "Newsletters & notifications today", rows: bulk)].filter { !$0.rows.isEmpty }
    }

    // MARK: L3 (uncertain band + ask lines), visible rows first

    private func scheduleL3() {
        guard l3 == nil, let ai, ai.settings.precomputeTriage, let a = ai.assistant, let p = a.route(.triage),
              let mail = ai.mail, let store = mail.store, let engine else { return }
        let visibleOrder = mail.visibleRows.map(\.message.conversationId)
        var rank: [String: Int] = [:]
        for (i, c) in visibleOrder.enumerated() where rank[c] == nil { rank[c] = i }
        var candidates: [(String, ConversationFacts, TriageDecision)] = []
        for (cid, d) in decisions where !d.restricted && d.source == .rule && !d.hard {
            guard d.confidence == .low || (d.state == .needsReply && d.ask == nil),
                  let f = engine.facts(for: cid), l3Tried[cid] != f.signature, !f.lastFromMe else { continue }
            candidates.append((cid, f, d))
        }
        // needsReply ask lines for hard-decided rows too (the LLM only adds text there, it can't change the state).
        for (cid, d) in decisions where !d.restricted && d.source == .rule && d.hard && d.state == .needsReply && d.ask == nil {
            if let f = engine.facts(for: cid), l3Tried[cid] != f.signature { candidates.append((cid, f, d)) }
        }
        guard !candidates.isEmpty else { return }
        candidates.sort { (rank[$0.0] ?? Int.max, $1.1.latest) < (rank[$1.0] ?? Int.max, $0.1.latest) }
        let batch = Array(candidates.prefix(p.tier == .onDevice ? 12 : 24))
        let owners = Set(([mail.me?.address] + mail.settings.identities.map(\.address)).compactMap { $0?.lowercased() })
        var items: [ThreadItem] = [], persistOK: [String: Bool] = [:]
        let allowOffline = ai.trustPolicy.allowOfflineBodies
        for (cid, f, d) in batch {
            l3Tried[cid] = f.signature
            let all = (try? store.conversation(id: cid, limit: 200)) ?? []
            let picked = ThreadItem.pick(all) { m in
                owners.contains(m.from?.address.lowercased() ?? "") || ((try? store.folder(id: m.folderId)) ?? nil)?.wellKnown == .sentitems
            }.map { m -> MailMessage in var m = m; if m.body == nil, let b = try? store.body(messageId: m.id, touch: false) { m.body = b }; return m }
            guard let last = picked.last else { continue }
            let mb = store.mailbox(forFolder: last.folderId)
            persistOK[cid] = allowOffline && picked.allSatisfy { m in
                a.gate.exposure(m, mailbox: mb, tier: p.tier) != .content
                    || MailContentPolicy.policy(for: m, mailbox: mb, engine: a.gate.engine).allowOfflineDetails
            }
            // The rule hint comes from cue bits read under the on-device gate: for the cloud it only goes along when
            // every message is content for the cloud tier too.
            var ctxLines = ThreadItem.contextLines(f, rule: d)
            if p.tier != .onDevice, !picked.allSatisfy({ a.gate.exposure($0, mailbox: mb, tier: p.tier) == .content }) {
                ctxLines.removeAll { $0.hasPrefix("Rule hint") }
            }
            items.append(ThreadItem(conversationId: cid, messages: picked, mailbox: mb, context: ctxLines))
        }
        let user = mail.me.map { "\($0.name) <\($0.address)>" }
        let ctx = p.tier == .onDevice ? OnDeviceProvider.contextTokens : nil
        let tier = p.tier
        l3 = Task { [weak self] in
            let fails = TriageFailureTally()
            let res = await a.triageThreadsResilient(items, user: user, contextTokens: ctx, failures: { k, n in fails.add(k, n) })
            for (cid, v) in res { engine.storeVerdict(v, conversationId: cid, tier: tier, persistText: persistOK[cid] ?? false) }
            let line = "triage threads=\(items.count) answered=\(res.count) keptRule=\(items.count - res.count) route=\(tier.rawValue) "
                + "fail[\(fails.summary)] | " + AICallStats.shared.line(.triage, contextTokens: ctx)
            FileHandle.standardError.write(Data("[AI] \(line)\n".utf8))
            guard let self else { return }
            self.l3 = nil
            self.republish()
        }
    }

    // MARK: Training-tool support

    /// Inbox conversations the list shows (newest first) for coverage / missed-latest.
    func listedInboxConversations() -> [String] {
        guard let mail = ai?.mail, let store = mail.store, let inbox = try? store.folder(wellKnown: .inbox, mailbox: "me") else { return [] }
        // Scoped to the engine's window (30 days): older conversations aren't tracked, so they'd only read as gaps.
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        var seen = Set<String>(), out: [String] = []
        for m in (try? store.messages(folderId: inbox.id, limit: 500)) ?? [] where m.received >= cutoff && seen.insert(m.conversationId).inserted {
            out.append(m.conversationId)
        }
        return out
    }
}

final class TriageFailureTally: @unchecked Sendable {
    private let lock = NSLock()
    private var c: [AIFailureKind: Int] = [:]
    func add(_ k: AIFailureKind, _ n: Int) { lock.withLock { c[k, default: 0] += n } }
    var summary: String { lock.withLock { AIFailureKind.allCases.compactMap { k in c[k].map { "\(k.rawValue)=\($0)" } }.joined(separator: ",") } }
}

// MARK: - AIAssistModel bridge (old per-message path stays behind `conversationTriage == false`)

extension AIAssistModel {
    /// One entry point for the row badge, ask line and hover text (TRIAGE2-HOOK).
    func display(for row: MailRow) -> TriageDisplay? {
        if preview == nil, settings.usesConversationTriage { return inbox.display(for: row) }
        guard let t = triage(for: row) else { return nil }
        let badge: ListRowBadge? = t.tag == .replyNeeded ? .replyNeeded : t.tag == .waitingOnThem ? .waiting : nil
        let state: ConversationState = t.tag == .replyNeeded ? .needsReply : t.tag == .waitingOnThem ? .waiting : .fyi
        return TriageDisplay(badge: badge, title: t.tag.title, ask: t.ask, maybe: false, explain: AIRowLine.explain(t), state: state)
    }

    var usesConversationTriage: Bool { preview == nil && settings.usesConversationTriage }
}
