import Foundation
import CryptoKit
import CalendarCore
import MailCore

// TRIAGE2: conversation state (docs/INBOX-INTELLIGENCE-PLAN.md Phase 1). Synthetic DE/EN/FR/IT threads with gold
// states; nothing here prints subjects, senders or bodies.

/// Throws `contextOverflow` for batches with more than `maxThreads` threads; otherwise answers "reply" for each.
final class OverflowProvider: AIProvider, @unchecked Sendable {
    let id: AIProviderID = .onDevice
    let tier: AITier = .onDevice
    let model = "fake-overflow"
    let maxThreads: Int
    let failAll: Bool
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    init(maxThreads: Int, failAll: Bool = false) { self.maxThreads = maxThreads; self.failAll = failAll }
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        lock.withLock { _calls += 1 }
        if failAll { throw AIProviderError.guardrail }
        let n = Set(user.components(separatedBy: "role=thread").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) })
        if n.count > maxThreads { throw AIProviderError.contextOverflow }
        return "[" + n.sorted().map { "{\"t\":\($0),\"state\":\"reply\",\"ask\":\"Send it\",\"why\":\"asked\"}" }.joined(separator: ",") + "]"
    }
}

final class AIFailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var c: [AIFailureKind: Int] = [:]
    func add(_ k: AIFailureKind, _ n: Int) { lock.withLock { c[k, default: 0] += n } }
    func count(_ k: AIFailureKind) -> Int { lock.withLock { c[k] ?? 0 } }
}

@MainActor
func runInboxStateTests() async {
    section("Inbox triage: conversation state (rules, cues, overrides, privacy, scoring)")
    let L = FixtureCalendarService.labels
    let eng = CachedLabelPolicyEngine(labels: L, synced: true)
    let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let now = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!   // a Wednesday
    let me = EmailAddress(name: "Alex Muster", address: "owner@niivo-test.example")
    let roles: [String: WellKnownFolder] = ["inbox": .inbox, "sent": .sentitems, "archive": .archive, "deleted": .deleteditems, "drafts": .drafts]

    struct TM {
        var mine = false
        var cc = false          // I'm in Cc (inbound)
        var bcc = false         // not in To/Cc (inbound)
        var others = 0
        var noTo = false        // outbound with nobody in To
        var text: String?
        var hours: Double       // hours before `now`
        var folder: String? = nil
        var label: String? = nil
        var priv = false
        var from: String = "anna@kunde.example"
        var subject = "Projekt"
        var sender: String? = nil
        var draft = false
    }
    func mk(_ cid: String, _ i: Int, _ t: TM, base: Date? = nil) -> MailMessage {
        let otherAddrs = (0..<t.others).map { EmailAddress(name: "O\($0)", address: "o\($0)@kunde.example") }
        var to: [EmailAddress] = [], cc: [EmailAddress] = []
        if t.mine {
            if t.noTo { cc = [EmailAddress(name: "A", address: t.from)] + otherAddrs } else { to = [EmailAddress(name: "A", address: t.from)] + otherAddrs }
        } else if t.bcc { to = [EmailAddress(name: "List", address: "all@kunde.example")] + otherAddrs }
        else if t.cc { to = otherAddrs.isEmpty ? [EmailAddress(name: "B", address: "b@kunde.example")] : otherAddrs; cc = [me] }
        else { to = [me] + otherAddrs }
        return MailMessage(id: "\(cid)-\(i)", folderId: t.folder ?? (t.mine ? "sent" : "inbox"), conversationId: cid, subject: t.subject,
                           from: t.mine ? me : EmailAddress(name: "Anna", address: t.from), toRecipients: to, ccRecipients: cc,
                           received: (base ?? now).addingTimeInterval(-t.hours * 3_600), preview: t.text, isDraft: t.draft,
                           labelId: t.label, isPrivate: t.priv, sender: t.sender.map { EmailAddress(name: "ESP", address: $0) })
    }
    let meetings: [String: TriageMeeting] = ["invite-open": .requestUnanswered, "invite-answered": .requestAnswered, "invite-response": .response]
    let senders: [String: SenderOverrideKind] = ["robot@hr.example": .neverNeedsReply]
    let inp = TriageInputs(account: "acct-A", isMine: { $0.from?.address == "owner@niivo-test.example" || $0.folderId == "sent" },
                           myAddresses: [me.address], internalDomains: ["niivo-test.example"], firstName: "Alex",
                           folderRole: { roles[$0] }, exposure: { gate.exposure($0, mailbox: "me", tier: .onDevice) },
                           meeting: { meetings[$0.conversationId] }, senderOverride: { senders[$0] })

    // MARK: Corpus (gold = who acts next at `now`)
    let HC = L[3].id, viewOnly = L[4].id, orphan = FixtureCalendarService.orphanLabelId
    let corpus: [(id: String, gold: ConversationState, msgs: [TM])] = [
        ("de-ask", .needsReply, [TM(text: "Hallo Alex, könnten Sie mir die Offerte schicken?", hours: 2)]),
        ("en-ask", .needsReply, [TM(text: "Hi Alex, could you review the attached plan?", hours: 3)]),
        ("fr-ask", .needsReply, [TM(text: "Bonjour, pourriez-vous confirmer la date de livraison ?", hours: 4)]),
        ("it-ask", .needsReply, [TM(text: "Buongiorno, potrebbe inviarmi il contratto firmato?", hours: 5)]),
        ("de-cc-broadcast", .fyi, [TM(cc: true, others: 5, text: "Zur Info: das Protokoll ist abgelegt.", hours: 6)]),
        ("en-cc-named", .needsReply, [TM(cc: true, others: 1, text: "Alex, can you check the numbers?", hours: 7)]),
        ("de-newsletter", .fyi, [TM(text: "Unsere Neuheiten im November", hours: 8, from: "newsletter@shop.example")]),
        ("en-notification", .fyi, [TM(text: "Build 4411 failed", hours: 9, from: "notifications@tickets.example")]),
        ("de-autoreply", .fyi, [TM(text: "Ich bin bis Montag abwesend.", hours: 10, subject: "Automatische Antwort: Projekt")]),
        ("fr-autoreply", .fyi, [TM(text: "Je suis absent.", hours: 11, subject: "Réponse automatique : Projet")]),
        ("invite-open", .needsReply, [TM(text: "Workshop", hours: 12)]),
        ("invite-answered", .done, [TM(text: "Workshop", hours: 13)]),
        ("invite-response", .fyi, [TM(text: "Accepted", hours: 14)]),
        ("de-my-reply-done", .done, [TM(text: "Können Sie das prüfen?", hours: 30), TM(mine: true, text: "Erledigt, danke.", hours: 20)]),
        ("de-my-reply-asks", .waiting, [TM(text: "Wann passt es?", hours: 30), TM(mine: true, text: "Passt Dienstag um 10 Uhr?", hours: 20)]),
        ("de-new-inbound", .needsReply, [TM(text: "Können Sie das prüfen?", hours: 50), TM(mine: true, text: "Erledigt.", hours: 40),
                                         TM(text: "Danke. Bitte schicken Sie noch die Rechnung.", hours: 2)]),
        ("de-closer", .done, [TM(text: "Bitte um Rückmeldung", hours: 50), TM(mine: true, text: "Hier die Zahlen, alles da.", hours: 40),
                              TM(text: "Vielen Dank!", hours: 3)]),
        ("en-closer", .done, [TM(mine: true, text: "Here you go, the signed copy is attached.", hours: 40), TM(text: "Thanks!", hours: 3)]),
        ("it-closer", .done, [TM(mine: true, text: "Ecco il documento.", hours: 40), TM(text: "Grazie mille, perfetto.", hours: 3)]),
        ("en-unanswered-5d", .waiting, [TM(mine: true, text: "Here are the Q3 figures for the board pack.", hours: 24 * 7)]),
        ("en-unanswered-1d", .done, [TM(mine: true, text: "Here are the Q3 figures for the board pack.", hours: 20)]),
        ("de-cc-only-send", .done, [TM(mine: true, noTo: true, text: "Hier das Protokoll vom Montag.", hours: 24 * 8)]),
        ("de-fyi-send", .done, [TM(mine: true, text: "Zur Info: das Protokoll vom Montag.", hours: 24 * 8)]),
        ("de-forward", .done, [TM(mine: true, text: "Siehe unten.", hours: 24 * 8, subject: "WG: Offerte")]),
        ("en-started-ask", .waiting, [TM(mine: true, text: "Can you send the invoice for October?", hours: 20)]),
        ("it-started-ask", .waiting, [TM(mine: true, text: "Mi può mandare la fattura per favore?", hours: 20)]),
        ("en-list", .fyi, [TM(bcc: true, others: 3, text: "Office closed on Friday.", hours: 15)]),
        ("de-to-many-ask", .needsReply, [TM(others: 5, text: "Bitte tragt euch bis Freitag in die Liste ein.", hours: 16)]),
        ("en-no-cue", .fyi, [TM(text: "Here is the document from yesterday's meeting.", hours: 17)]),
        ("fr-pour-info", .fyi, [TM(text: "Pour info, voici le planning de décembre.", hours: 18)]),
        ("it-deadline", .needsReply, [TM(text: "Il preventivo va confermato entro venerdì.", hours: 19)]),
        ("de-deadline", .needsReply, [TM(text: "Die Unterlagen brauchen wir spätestens Montag.", hours: 21)]),
        ("en-cc-plain", .fyi, [TM(cc: true, others: 1, text: "Sharing the latest draft with the team.", hours: 22)]),
        ("fr-closer", .done, [TM(mine: true, text: "Voici le devis.", hours: 40), TM(text: "Merci, bien reçu.", hours: 3)]),
        ("en-esp", .fyi, [TM(text: "Your weekly digest", hours: 23, from: "team@brand.example", sender: "bounce@mcsv.net")]),
        ("en-sender-never", .fyi, [TM(text: "Can you approve the timesheet?", hours: 24, from: "robot@hr.example")]),
        ("de-archived", .done, [TM(text: "Können Sie das prüfen?", hours: 26, folder: "archive")]),
        ("de-archived-waiting", .waiting, [TM(text: "Hallo", hours: 60, folder: "archive"), TM(mine: true, text: "Haben Sie die Pläne erhalten?", hours: 30)]),
        // Protected / private: metadata-only or direction-only behaviour
        ("hc-inbound", .needsReply, [TM(text: "Können Sie das vertraulich prüfen?", hours: 2, label: HC)]),
        ("orphan-inbound", .needsReply, [TM(text: "Bitte prüfen", hours: 2, label: orphan)]),
        ("private-inbound", .needsReply, [TM(text: "Privat: kannst du?", hours: 2, priv: true)]),
        ("orphan-mine-6d", .waiting, [TM(mine: true, text: "Bitte bestätigen", hours: 24 * 8, label: orphan)]),
        ("viewonly-inbound", .needsReply, [TM(text: "Können Sie unterschreiben?", hours: 2, label: viewOnly)]),
    ]
    var factsBy: [String: ConversationFacts] = [:]
    var decided: [String: TriageDecision] = [:]
    var wrong: [String] = []
    for t in corpus {
        let ms = t.msgs.enumerated().map { mk(t.id, $0.offset, $0.element) }
        guard let f = ConversationFactsBuilder.build(conversationId: t.id, messages: ms, inputs: inp) else { wrong.append("\(t.id):nil"); continue }
        factsBy[t.id] = f
        let d = TriageRules.decide(f, sender: f.senderAddress.flatMap { senders[$0] }.map { SenderPrior(explicit: $0) }, now: now, calendar: utc)
        decided[t.id] = d
        if d.state != t.gold { wrong.append(t.id) }
    }
    check(corpus.count >= 40, "fixture corpus has ≥ 40 threads in DE/EN/FR/IT (\(corpus.count))")
    check(decided.count == corpus.count, "every thread gets a state (never untagged)")
    // Known rule limit without L3 / a scorer: a direct mail with nothing asked stays a low-confidence "maybe reply".
    check(Set(wrong) == ["en-no-cue"], "rules-only states match gold except the documented undecided case \(wrong.sorted())")
    let snap0 = TriageSnapshot(tag: Data([1]), at: now)
    let rows = corpus.map { t in TriageTruthRow(truth: TriageTruth(truth: t.gold, predicted: decided[t.id]!.state, predictedConfidence: decided[t.id]!.confidence,
                                                                   eventSignature: 1, answeredAt: now, snapshot: snap0)) }
    let sc = TriageScoring.score(rows, coverage: 1, missedLatest: 0)
    let nr = sc.perState[.needsReply]!
    check(nr.precision >= 0.75 && nr.recall >= 0.6, "rules-only needsReply P ≥ 0.75, R ≥ 0.60 on fixtures (P=\(String(format: "%.2f", nr.precision)) R=\(String(format: "%.2f", nr.recall)))")
    print("  [TriageScore] fixtures " + sc.line)

    check(decided["de-to-many-ask"]?.confidence == .medium && decided["de-ask"]?.confidence == .high, "R8: To + ≤ 2 others + ask → high; many recipients → medium")
    check(decided["invite-open"]?.reason == .rsvp && decided["invite-open"]?.hard == true, "R2: unanswered invite → needsReply (RSVP), hard rule")
    check(decided["en-unanswered-5d"]?.reason == .mineUnanswered && decided["en-unanswered-5d"]?.showsBadge == true, "N working days unanswered (To) → waiting with a badge")
    check(decided["en-unanswered-1d"]?.showsBadge == false, "under N days, nothing asked → not waiting")
    check(decided["de-cc-only-send"]?.reason == .mineNoDirect, "a Cc-only send never counts as waiting")
    check(decided["de-fyi-send"]?.reason == .mineFYI && decided["de-forward"]?.reason == .mineFYI, "plain FYI sends (marker, forward) never count as waiting")
    for id in ["hc-inbound", "orphan-inbound", "private-inbound", "viewonly-inbound"] {
        check(factsBy[id]!.inboundCues == nil && !decided[id]!.showsBadge, "\(id): no cue bits from protected/private text, no badge")
    }
    check(factsBy["orphan-inbound"]!.restricted && factsBy["private-inbound"]!.restricted && decided["orphan-inbound"]!.isMaybe,
          "excluded rows: direction-only state shown as a dot (maybe)")
    check(factsBy["hc-inbound"]!.exposure == .metadata && factsBy["hc-inbound"]!.myRole == .to && decided["hc-inbound"]!.reason == .inboundUndecided,
          "metadata-exposed rows keep L0 facts (role) but no cues")
    check(decided["orphan-mine-6d"]!.reason == .restrictedMine && !decided["orphan-mine-6d"]!.showsBadge, "excluded mine-last → waiting without a badge")
    check(decided["en-sender-never"]?.reason == .senderOverride, "R11: never reply needed from this sender")
    check(factsBy["de-archived"]!.hasInboxMember == false && decided["de-archived-waiting"]?.state == .waiting, "archived inbound → done; archived waiting stays waiting")
    check(ConversationFactsBuilder.build(conversationId: "d", messages: [mk("d", 0, TM(text: "x", hours: 1, draft: true)),
                                                                         mk("d", 1, TM(text: "y", hours: 1, folder: "deleted"))], inputs: inp) == nil,
          "drafts and deleted items don't count")

    // MARK: Cues (bits only)
    let qDE = TriageCueScanner.scan("Könnten Sie bitte antworten\n\nAm 1.11.2026 schrieb Anna Muster:\n> Wer kommt?", isHTML: false, firstName: nil)
    check(qDE.contains(.request) && !qDE.contains(.question), "cues ignore quoted history (the '?' is in the quote)")
    check(TriageCueScanner.scan("Merci, parfait !", isHTML: false, firstName: nil).contains(.closer), "FR closer")
    check(!TriageCueScanner.scan("Danke, können Sie noch die Pläne schicken?", isHTML: false, firstName: nil).contains(.closer), "a thank-you with a question isn't a closer")
    check(TriageCueScanner.scan("<p>Alex, per favore</p>", isHTML: true, firstName: "Alex").isSuperset(of: [.request, .addressedByName]), "IT request + addressed by name (HTML)")

    // MARK: Transitions with the engine (store-backed, per account)
    let store = try! MailStore(url: nil, key: SymmetricKey(size: .bits256), persistPolicy: { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) })
    try? store.replace(folders: roles.map { MailFolder(id: $0.key, displayName: $0.key, wellKnown: $0.value) }, mailbox: "me")
    func cfg(_ account: String) -> InboxTriageEngine.Config {
        .init(account: account, owners: [me.address], internalDomains: ["niivo-test.example"], firstName: "Alex",
              exposure: { m, mb in gate.exposure(m, mailbox: mb, tier: .onDevice) })
    }
    let engine = store.enableInboxTriage(cfg("acct-A"))
    let live = Date()
    func at(_ id: String, _ i: Int, _ t: TM) -> MailMessage { mk(id, i, t, base: live) }
    let q = at("s1", 0, TM(text: "Können Sie mir die Pläne schicken?", hours: 2))
    try? store.upsert(messages: [q])
    engine.refresh(now: live)
    check(engine.decision(for: "s1", now: live)?.state == .needsReply, "new inbound question → needsReply")
    let sig0 = engine.facts(for: "s1")!.signature
    var read = q; read.isRead = true; read.flag = FollowUpFlag(status: .flagged); read.changeKey = "ck-2"
    try? store.upsert(messages: [read])
    engine.refresh(now: live)
    check(engine.facts(for: "s1")!.signature == sig0 && engine.decision(for: "s1", now: live)?.state == .needsReply,
          "read / flag / changeKey change keeps the signature and the state (no orphaning)")
    engine.storeVerdict(ThreadVerdict(state: .needsReply, ask: "Send the plans", why: "asked"), conversationId: "s1", tier: .onDevice, persistText: true)
    try? store.upsert(messages: [q])
    engine.refresh(now: live)
    check(engine.decision(for: "s1", now: live)?.ask == "Send the plans", "L3 ask line cached by signature survives a sync of the same message")
    try? store.upsert(messages: [at("s1", 1, TM(mine: true, text: "Anbei die Pläne.", hours: 1))])
    engine.refresh(now: live)
    let afterReply = engine.decision(for: "s1", now: live)
    check(afterReply?.state != .needsReply && afterReply?.showsBadge == false, "my reply clears “Reply needed” within one refresh")
    try? store.upsert(messages: [at("s1", 2, TM(text: "Danke! Und bitte noch die Rechnung?", hours: 0.5))])
    engine.refresh(now: live)
    check(engine.decision(for: "s1", now: live)?.state == .needsReply, "a new inbound after my reply reopens needsReply")
    check(engine.decision(for: "s1", now: live)?.ask == nil, "the cached ask from an older signature isn't reused")

    try? store.upsert(messages: [at("s2", 0, TM(text: "Here is the document from yesterday.", hours: 3))])
    engine.refresh(now: live)
    check(engine.decision(for: "s2", now: live)?.isMaybe == true, "undecided inbound → maybe (low)")
    engine.correct(conversationId: "s2", to: .fyi, now: live)
    check(engine.decision(for: "s2", now: live)?.state == .fyi && engine.decision(for: "s2", now: live)?.source == .user, "override applies at once")
    var s2r = at("s2", 0, TM(text: "Here is the document from yesterday.", hours: 3)); s2r.isRead = true
    try? store.upsert(messages: [s2r])
    engine.refresh(now: live)
    check(engine.decision(for: "s2", now: live)?.source == .user, "override sticks across read/flag")
    try? store.upsert(messages: [at("s2", 1, TM(text: "And the second version.", hours: 1))])
    engine.refresh(now: live)
    let s2 = engine.decision(for: "s2", now: live)
    // TRIAGE3 (deliberate change): an expired override is no longer a prior; the state machine decides again.
    check(s2?.source == .rule && s2?.reason != .prior && s2?.state == .needsReply, "after the next inbound the override expires (no stale prior)")
    try? store.upsert(messages: [at("s2", 2, TM(text: "Could you sign it by Friday?", hours: 0.2))])
    engine.refresh(now: live)
    check(engine.decision(for: "s2", now: live)?.state == .needsReply, "a clear ask beats the stale override")

    // Training answers: prediction with the override ignored; skipped and stale rows aren't scored.
    try? store.upsert(messages: [at("s3", 0, TM(text: "Bitte um Freigabe.", hours: 4))])
    engine.refresh(now: live)
    engine.recordTruth(conversationId: "s3", truth: .fyi, wrongSenderType: true, now: live)
    engine.recordTruth(conversationId: "s2", truth: nil, wrongSenderType: false, now: live)
    let tr = engine.truthRows()
    check(tr.count == 2 && tr.contains { $0.truth.truth == .fyi && $0.truth.predicted == .needsReply }, "truth stores the un-overridden prediction")
    check(engine.decision(for: "s3", now: live)?.state == .fyi, "a training answer applies as an override (like the one-click correction)")
    try? store.upsert(messages: [at("s3", 1, TM(mine: true, text: "Freigegeben.", hours: 1))])
    engine.refresh(now: live)
    let sc2 = TriageScoring.score(engine.truthRows(), coverage: 1, missedLatest: 0)
    check(sc2.stale == 0 && sc2.skipped == 1 && sc2.labelled == 1 && sc2.movedOn == 1 && sc2.wrongSenderType == 1,
          "skipped rows are left out; an answer whose thread moved on is still scored, as of its snapshot")
    engine.clearTruths()

    // Live re-prediction: Score re-runs the rules as of each snapshot, so a settings/rule change moves the score.
    try? store.upsert(messages: [at("s4", 0, TM(mine: true, text: "Anbei der Bericht.", hours: 24 * 6))])
    engine.refresh(now: live)
    engine.recordTruth(conversationId: "s4", truth: .waiting, wrongSenderType: false, now: live)
    let live1 = TriageScoring.score(engine.truthRows(repredict: true), coverage: 1, missedLatest: 0)
    store.enableInboxTriage(InboxTriageEngine.Config(account: "acct-A", owners: [me.address], internalDomains: ["niivo-test.example"], firstName: "Alex",
                                                     exposure: { m, mb in gate.exposure(m, mailbox: mb, tier: .onDevice) },
                                                     settings: TriageSettings(waitingDays: 10)))
    engine.refresh(now: live)
    let live2 = TriageScoring.score(engine.truthRows(repredict: true), coverage: 1, missedLatest: 0)
    let stored = TriageScoring.score(engine.truthRows(), coverage: 1, missedLatest: 0)
    check(live1.labelled == 1 && live1.accuracy == 1 && live2.labelled == 1 && live2.accuracy == 0 && stored.accuracy == 1,
          "re-running Score re-predicts: N 3 → 10 days turns the waiting answer into a miss (stored prediction unchanged)")
    store.enableInboxTriage(cfg("acct-A"))
    engine.refresh(now: live)

    // MARK: TRIAGE3: truth pinned in time (as-of prediction, override expiry, migration)
    // Pure as-of: the facts up to the snapshot message, nothing later.
    let dni = corpus.first { $0.id == "de-new-inbound" }!
    let dniMs = dni.msgs.enumerated().map { mk(dni.id, $0.offset, $0.element) }
    func asOfState(_ i: Int, inbox: Bool? = nil, _ ms: [MailMessage]? = nil) -> ConversationState? {
        let ms = ms ?? dniMs
        return ConversationFactsBuilder.build(conversationId: dni.id, messages: ms, inputs: inp, asOf: TriageSnapshot(tag: Data(), at: ms[i].received),
                                              isSnapshot: { $0.id == ms[i].id }, inboxAtSnapshot: inbox)
            .map { TriageRules.decide($0, now: now, calendar: utc).state }
    }
    check(asOfState(0) == .needsReply && asOfState(1) == .done && asOfState(2) == .needsReply,
          "as-of facts: each snapshot sees only the messages up to it (ask → my reply → new ask)")
    let archivedMs = dniMs.map { m -> MailMessage in var m = m; if m.folderId == "inbox" { m.folderId = "archive" }; return m }
    check(asOfState(0, archivedMs) == .done && asOfState(0, inbox: true, archivedMs) == .needsReply,
          "as-of uses the inbox membership stored with the answer, not today's folders (archived after replying)")
    check(ConversationFactsBuilder.asOf(dniMs, at: dniMs[1].received, isSnapshot: { _ in false }).count == 2,
          "a moved snapshot message (new id) is found by its received time")

    // A thread you replied to later: as of the snapshot = needs reply, live = done, scored correct.
    try? store.upsert(messages: [at("t1", 0, TM(text: "Können Sie mir das Angebot schicken?", hours: 5))])
    engine.refresh(now: live)
    let t1Snap = engine.snapshot(of: engine.facts(for: "t1")!)
    engine.recordTruth(conversationId: "t1", asOf: t1Snap, truth: .needsReply, wrongSenderType: false, now: live)
    check(engine.decision(for: "t1", now: live)?.source == .user, "an answer on the newest message applies as a live override")
    check(engine.answeredIds().contains("t1"), "answered as of its newest message → not sampled again")
    var t1Archived = at("t1", 0, TM(text: "Können Sie mir das Angebot schicken?", hours: 5)); t1Archived.folderId = "archive"
    try? store.upsert(messages: [at("t1", 1, TM(mine: true, text: "Anbei das Angebot.", hours: 1)), t1Archived])
    engine.refresh(now: live)
    let t1Live = engine.decision(for: "t1", now: live)
    check(t1Live?.source != .user && t1Live?.state != .needsReply, "my reply expires the override; live state is no longer needsReply")
    let t1Row = engine.truthRows(repredict: true).first { $0.truth.snapshot == t1Snap }
    check(t1Row?.movedOn == true && t1Row?.predictedAsOf == .needsReply, "as-of-snapshot prediction is needsReply (reply and archive came later)")
    let t1Score = TriageScoring.score(t1Row.map { [$0] } ?? [], coverage: 1, missedLatest: 0)
    check(t1Score.labelled == 1 && t1Score.accuracy == 1 && t1Score.movedOn == 1, "scored correct as of the snapshot, not an error")
    check(!engine.answeredIds().contains("t1"), "a conversation that moved on can be asked again, as of the new message")

    // One-click correction: expires on a new inbound message, and on my reply.
    try? store.upsert(messages: [at("t2", 0, TM(text: "Here is the document from yesterday.", hours: 4))])
    engine.refresh(now: live)
    let t2Old = engine.snapshot(of: engine.facts(for: "t2")!)
    engine.correct(conversationId: "t2", to: .done, now: live)
    check(engine.decision(for: "t2", now: live)?.source == .user && engine.override(conversationId: "t2")?.snapshot == t2Old,
          "a one-click correction is pinned to the newest message")
    try? store.upsert(messages: [at("t2", 1, TM(text: "Could you sign it by Friday?", hours: 2))])
    engine.refresh(now: live)
    check(engine.decision(for: "t2", now: live)?.source == .rule && engine.decision(for: "t2", now: live)?.state == .needsReply,
          "a new inbound message expires the correction (Done → needsReply again)")
    engine.recordTruth(conversationId: "t2", asOf: t2Old, truth: .fyi, wrongSenderType: false, now: live)
    check(engine.decision(for: "t2", now: live)?.source == .rule, "an answer about an older snapshot is kept as truth but never becomes an override")
    engine.correct(conversationId: "t2", to: .fyi, now: live)
    check(engine.decision(for: "t2", now: live)?.state == .fyi, "a correction on the new newest message applies")
    try? store.upsert(messages: [at("t2", 2, TM(mine: true, text: "Signed, attached.", hours: 1))])
    engine.refresh(now: live)
    check(engine.decision(for: "t2", now: live)?.source == .rule, "my reply expires the correction")

    // Migration of pre-snapshot rows.
    try? store.upsert(messages: [at("m1", 0, TM(text: "Bitte um Rückmeldung zum Plan.", hours: 6))])
    try? store.upsert(messages: [at("m2", 0, TM(text: "Wann passt Ihnen der Termin?", hours: 7))])
    engine.refresh(now: live)
    let m1f = engine.facts(for: "m1")!, m2sig = engine.facts(for: "m2")!.eventSignature, m2at = engine.facts(for: "m2")!.latest
    func legacy(_ t: ConversationState, _ sig: UInt64) -> TriageTruth {
        TriageTruth(truth: t, predicted: .needsReply, predictedConfidence: .high, eventSignature: sig, answeredAt: live)
    }
    engine.debugRecordLegacyTruth(conversationId: "m1", legacy(.needsReply, m1f.eventSignature))
    engine.debugRecordLegacyTruth(conversationId: "m2", legacy(.needsReply, m2sig))
    engine.debugRecordLegacyTruth(conversationId: "t2", legacy(.fyi, 0xdead_beef))
    // Reply, then archive: a migrated row has no inbox bit, so it must not be re-predicted with today's folders.
    try? store.upsert(messages: [at("m2", 1, TM(mine: true, text: "Dienstag passt.", hours: 2)),
                                 at("m2", 0, TM(text: "Wann passt Ihnen der Termin?", hours: 7, folder: "archive"))])
    engine.refresh(now: live)
    let mig = engine.truthRows(repredict: true)
    let m1Row = mig.first { $0.truth.snapshot?.at == m1f.latest && $0.truth.eventSignature == m1f.eventSignature }
    let m2Row = mig.first { $0.truth.snapshot?.at == m2at && $0.truth.eventSignature == m2sig }
    check(m1Row?.pinned == true && m1Row?.movedOn == false, "migration: an old answer with no event since is pinned to the then-newest message")
    check(m2Row?.pinned == true && m2Row?.movedOn == true && m2Row?.predictedAsOf == .needsReply,
          "migration: an old answer is pinned to the message whose prefix matches its event signature (reply came later)")
    let migScore = TriageScoring.score(mig.filter { $0.truth.answeredAt == live && $0.truth.predicted == .needsReply && $0.truth.predictedConfidence == .high
                                                     && [m1f.eventSignature, m2sig, 0xdead_beef].contains($0.truth.eventSignature) },
                                       coverage: 1, missedLatest: 0)
    check(migScore.stale == 1 && migScore.labelled == 2, "migration: an underivable old answer is dropped from scoring (unpinned)")
    check(engine.answeredIds().contains("m1") && !engine.answeredIds().contains("m2"), "migrated answers count as answered only as of their snapshot")
    try? store.upsert(messages: [at("m3", 0, TM(text: "Here is the agenda.", hours: 3))])
    engine.refresh(now: live)
    engine.debugRecordLegacyOverride(conversationId: "m3", to: .done, now: live)
    check(engine.decision(for: "m3", now: live)?.source == .user, "migration: an old override with no event since stays live")
    try? store.upsert(messages: [at("m3", 1, TM(text: "Can you comment by Monday?", hours: 1))])
    engine.refresh(now: live)
    check(engine.decision(for: "m3", now: live)?.source == .rule && engine.decision(for: "m3", now: live)?.state == .needsReply,
          "migration: an old override expires with the next message")

    // Shared / delegated mailbox address counts as "me" (else To: shared@ reads as Bcc/list → hard FYI).
    let shared = EmailAddress(name: "Support", address: "support@niivo-test.example")
    let sm = MailMessage(id: "sh-0", folderId: "inbox", conversationId: "sh", subject: "Frage", from: EmailAddress(name: "Anna", address: "anna@kunde.example"),
                         toRecipients: [shared], ccRecipients: [], received: now.addingTimeInterval(-3_600), preview: "Können Sie mir helfen?")
    var inpShared = inp; inpShared.myAddresses = [me.address, shared.address]
    let fNo = ConversationFactsBuilder.build(conversationId: "sh", messages: [sm], inputs: inp)
    let fYes = ConversationFactsBuilder.build(conversationId: "sh", messages: [sm], inputs: inpShared)
    check(fNo?.myRole == .bccOrList && fYes?.myRole == .to, "shared mailbox address in owners → To, not Bcc/list")

    // Per-account isolation (same store file, other account namespace).
    let countsA = engine.learningCounts()
    store.enableInboxTriage(cfg("acct-B"))
    engine.refresh(now: live)
    check(engine.override(conversationId: "s2") == nil && engine.truthRows().isEmpty && engine.learningCounts().overrides == 0,
          "overrides, priors and truth are per account (account B sees none of A's)")
    engine.correct(conversationId: "s1", to: .done, now: live)
    store.enableInboxTriage(cfg("acct-A"))
    engine.refresh(now: live)
    check(engine.learningCounts() == countsA && engine.decision(for: "s1", now: live)?.source != .user, "account A unaffected by B's correction")

    let sizes = Set(store.debugTriagePayloadSizes())
    check(sizes.count == 1, "triage payloads are padded to one sealed size (\(sizes.sorted()))")
    try? store.resetHeaders()
    check(engine.learningCounts().overrides > 0 && engine.learningCounts().truths > 0, "resetHeaders keeps overrides and ground truth")
    try? store.wipe()
    check(engine.learningCounts() == .init(overrides: 0, senders: 0, truths: 0), "wipe clears every triage table")

    let f5 = factsBy["en-unanswered-5d"]!
    check(!TriageRules.decide(f5, settings: TriageSettings(waitingDays: 10), now: now, calendar: utc).showsBadge, "waiting days is a setting (N = 10 → not yet waiting)")
    check(TriageRules.workingDays(from: ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!, to: now, calendar: utc) == 3,
          "working days skip the weekend (Fri → Wed = 3)")

    // MARK: L3: per-item fallback, partial JSON, hard rules, halving retry, gate
    let partial = AIAssistant.parseThreadVerdicts("[{\"t\":1,\"state\":\"done\"},{\"t\":9,\"state\":\"reply\"},{\"t\":2,\"state\":\"bogus\"}]",
                                                  threads: [1: "a", 2: "b"])
    check(partial.count == 1 && partial["a"]?.state == .done, "partial / malformed JSON keeps valid items only (others keep L1)")
    check(TriageRules.merge(decided["de-newsletter"]!, llm: ThreadVerdict(state: .needsReply, ask: "x")).state == .fyi, "hard rule R1 can't be flipped to needsReply by the LLM")
    check(TriageRules.merge(decided["en-no-cue"]!, llm: ThreadVerdict(state: .fyi)).state == .fyi, "L3 decides the undecided band")
    check(TriageRules.merge(decided["orphan-inbound"]!, llm: ThreadVerdict(state: .fyi)).state == .needsReply, "restricted rows never take an LLM verdict")
    var s = AIAssistSettings(); s.choice = .onDevice
    let items = (1...4).map { ThreadItem(conversationId: "c\($0)", messages: [mk("c\($0)", 0, TM(text: "Bitte prüfen?", hours: 1))], mailbox: "me", context: ["User is in: To"]) }
    let ovf = OverflowProvider(maxThreads: 2)
    let kinds = AIFailureLog()
    let res = await AIAssistant(settings: s, gate: gate, cloud: nil, onDevice: ovf, audit: { _ in })
        .triageThreadsResilient(items, contextTokens: 100_000, failures: { k, n in kinds.add(k, n) })
    check(res.count == 4 && kinds.count(.contextOverflow) == 4 && ovf.calls == 3, "context overflow → halve the batch and retry once (1 + 2 calls)")
    let bad = OverflowProvider(maxThreads: 9, failAll: true)
    let kinds2 = AIFailureLog()
    let res2 = await AIAssistant(settings: s, gate: gate, cloud: nil, onDevice: bad, audit: { _ in })
        .triageThreadsResilient(items, contextTokens: 100_000, failures: { k, n in kinds2.add(k, n) })
    check(res2.isEmpty && kinds2.count(.guardrail) == 4, "a failed batch returns nothing (rows keep their L1 state), counted as guardrail")
    check(ThreadBatcher.batches(items, budget: 900, perMessageChars: 600, maxItems: 6).count > 1, "token-budgeted batches split under a small context")
    let protectedItem = ThreadItem(conversationId: "p", messages: [mk("p", 0, TM(text: "SECRET-TEXT", hours: 1, label: orphan))], mailbox: "me", context: [])
    let spy = FakeProvider(id: .onDevice, tier: .onDevice) { _ in "[]" }
    _ = try? await AIAssistant(settings: s, gate: gate, cloud: nil, onDevice: spy, audit: { _ in }).triageThreads([protectedItem])
    check(spy.calls.isEmpty, "an excluded thread never reaches the model")

    // MARK: Phase 0 counters
    check(AIProviderError.contextOverflow.kind == .contextOverflow && AIProviderError.guardrail.kind == .guardrail
          && AIProviderError.unavailable("x").kind == .unavailable && AIProviderError.badOutput.kind == .parse, "provider errors map to failure kinds")
    let st = AICallStats.shared.entry(.triage)
    check(st.failures[.contextOverflow, default: 0] >= 1 && st.onDevice >= 1 && st.maxEstTokens > 0, "call stats count failures by kind, tier and token estimate")
    let statLine = AICallStats.shared.line(.triage, contextTokens: 4096)
    check(!statLine.contains("SECRET") && !statLine.contains("@") && statLine.contains("ctx=4096"), "stats line is content-free")

    // MARK: Scoring maths
    func row(_ t: ConversationState?, _ p: ConversationState) -> TriageTruthRow {
        TriageTruthRow(truth: TriageTruth(truth: t, predicted: p, predictedConfidence: .high, eventSignature: 7, answeredAt: now, snapshot: snap0))
    }
    let s3 = TriageScoring.score([row(.needsReply, .needsReply), row(.needsReply, .fyi), row(.fyi, .needsReply), row(.fyi, .fyi),
                                  row(.waiting, .waiting), row(nil, .done)], coverage: 0.5, missedLatest: 2)
    check(s3.labelled == 5 && s3.skipped == 1 && abs(s3.accuracy - 0.6) < 1e-9, "accuracy over labelled rows (3/5)")
    check(abs(s3.perState[.needsReply]!.precision - 0.5) < 1e-9 && abs(s3.perState[.needsReply]!.recall - 0.5) < 1e-9
          && abs(s3.perState[.waiting]!.f1 - 1) < 1e-9 && s3.confusion[.fyi]?[.needsReply] == 1, "P / R / F1 and confusion matrix")
    check(s3.line.contains("coverage=0.50 missedLatest=2") && !s3.line.contains("@"), "score line is content-free counts")
    let cov = TriageScoring.coverage(listed: ["a", "b", "c", "d"], hasState: { $0 != "b" }, latest: 2)
    check(cov.coverage == 0.75 && cov.missedLatest == 1, "coverage and missed-latest")
    let samp = TriageSampler.stratify(corpus.map { ($0.id, decided[$0.id]!, factsBy[$0.id]!.latest) }, n: 10)
    let sampStates = Set(samp.compactMap { decided[$0] }.map { $0.confidence == .low ? "low" : $0.state.rawValue })
    check(samp.count == 10 && sampStates.isSuperset(of: ["low", "needsReply", "waiting", "fyi", "done"]), "training sample is stratified across states + uncertain")
}
