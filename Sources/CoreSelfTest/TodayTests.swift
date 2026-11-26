import Foundation
import MailCore

// TODAY-HOOK: Today / Flow / calm notifications (docs/RETHINK.md §4). Synthetic ids only; nothing prints mail data.

@MainActor
func runTodayTests() {
    section("Today: scorer, sections, redaction, calm notifications, Flow")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func dec(_ s: ConversationState, _ c: TriageConfidence, ago: TimeInterval = 3_600, snoozed: Bool = false,
             restricted: Bool = false, ask: String? = nil) -> TriageDecision {
        TriageDecision(state: s, confidence: c, reason: .directAsk, since: now.addingTimeInterval(-ago), snoozed: snoozed,
                       ask: ask, restricted: restricted)
    }

    // Scorer ordering.
    let vip = TodayScorer.score(TodaySignals(vip: true, role: .to, confidence: .medium))
    let direct = TodayScorer.score(TodaySignals(role: .to, confidence: .high))
    let cc = TodayScorer.score(TodaySignals(role: .cc, confidence: .high))
    let deadline = TodayScorer.score(TodaySignals(role: .to, deadline: true, confidence: .high))
    check(vip > direct && direct > cc, "VIP > direct To > Cc")
    check(deadline > direct, "a deadline cue ranks above the same mail without one")
    check(TodayScorer.score(TodaySignals(role: .to, ageDays: 3)) > TodayScorer.score(TodaySignals(role: .to, ageDays: 0)), "older ranks higher")
    check(TodayScorer.score(TodaySignals(role: .to, ageDays: 400)) - TodayScorer.score(TodaySignals(role: .to, ageDays: 0)) <= TodayScorer.maxAgeBonus,
          "the age bonus is capped")
    check(TodayScorer.score(TodaySignals(role: .to, ageDays: 400)) < TodayScorer.score(TodaySignals(vip: true, role: .to)),
          "age never beats a fresh VIP ask")
    check(TodayScorer.score(TodaySignals(role: .to, confidence: .high)) > TodayScorer.score(TodaySignals(role: .to, confidence: .low)),
          "confidence counts")
    check(TodayScorer.score(TodaySignals(role: .to, internalSender: false)) > TodayScorer.score(TodaySignals(role: .to, internalSender: true)),
          "external ranks above internal")
    let chips = TodayScorer.reasons(TodaySignals(vip: true, role: .to, deadline: true, ageDays: 3))
    check(chips.first == .vip && chips.contains(.deadline) && chips.count <= 4, "chips: strongest first, at most four")

    // Section assignment.
    check(TodaySections.section(for: dec(.needsReply, .high), now: now) == .needsYou, "needs reply, high → Needs you")
    check(TodaySections.section(for: dec(.needsReply, .low), now: now) == .maybe, "needs reply, low → maybe")
    check(TodaySections.section(for: dec(.needsReply, .high, snoozed: true), now: now) == .none, "snoozed → hidden")
    check(TodaySections.section(for: dec(.waiting, .medium), now: now) == .waiting, "waiting with a badge → Waiting")
    check(TodaySections.section(for: dec(.waiting, .low), now: now) == .none, "waiting without a badge → hidden")
    check(TodaySections.section(for: dec(.fyi, .high), now: now) == .fyi, "recent FYI → digest")
    check(TodaySections.section(for: dec(.fyi, .high, ago: 3 * 86_400), now: now) == .none, "old FYI → not in the digest")
    check(TodaySections.section(for: dec(.done, .high), now: now) == .none, "done → hidden")

    // Plan: ranking, cap, maybes only in the room left.
    var inputs: [TodayInput] = []
    inputs.append(TodayInput(conversationId: "c-cc", decision: dec(.needsReply, .medium), signals: TodaySignals(role: .cc)))
    inputs.append(TodayInput(conversationId: "c-vip", decision: dec(.needsReply, .medium), signals: TodaySignals(vip: true, role: .to)))
    inputs.append(TodayInput(conversationId: "c-maybe", decision: dec(.needsReply, .low), signals: TodaySignals(vip: true, role: .to, confidence: .low)))
    inputs.append(TodayInput(conversationId: "c-wait", decision: dec(.waiting, .high), signals: TodaySignals(ageDays: 4)))
    inputs.append(TodayInput(conversationId: "c-fyi", decision: dec(.fyi, .high), signals: TodaySignals()))
    inputs.append(TodayInput(conversationId: "c-done", decision: dec(.done, .high), signals: TodaySignals()))
    var p = TodayPlanner.plan(inputs, now: now)
    check(p.needsYou.map(\.conversationId) == ["c-vip", "c-cc", "c-maybe"], "confident by score, then the maybe (even a VIP maybe)")
    check(p.needsYou.last?.maybe == true && p.waiting.map(\.conversationId) == ["c-wait"] && p.fyi.map(\.conversationId) == ["c-fyi"],
          "waiting and FYI sections")
    check(p.diagnostic == "[Today] needs=2 waiting=1 fyi=1 shown=3 maybe=1 hidden=0", "diagnostic line is counts only")
    p = TodayPlanner.plan(inputs, now: now, cap: 2)
    check(p.needsYou.count == 2 && !p.needsYou.contains(where: \.maybe) && p.hidden == 1, "no room → the maybe stays out")
    let many = (0..<20).map { TodayInput(conversationId: "n\($0)", decision: dec(.needsReply, .high), signals: TodaySignals(role: .to, ageDays: $0 % 5)) }
    check(TodayPlanner.plan(many, now: now).needsYou.count == TodayPlanner.cap, "at most 15 cards")
    let restricted = TodayPlanner.plan([TodayInput(conversationId: "r", decision: dec(.needsReply, .medium, restricted: true),
                                                  signals: TodaySignals(vip: true, role: .to))], now: now)
    check(restricted.needsYou.first?.reasons.isEmpty == true, "restricted conversation: no chips")

    // Redaction of the ask.
    let open = TodayCardText.make(sender: "A", subject: "S", ask: "Send the plan", redactDetails: false, allowOfflineDetails: true)
    check(open.isAsk && open.line == "Send the plan" && open.showsDetails, "open row: the ask line")
    let notStored = TodayCardText.make(sender: "A", subject: "S", ask: "Send the plan", redactDetails: false, allowOfflineDetails: false)
    check(!notStored.isAsk && notStored.line == "S", "label forbids content: subject instead of the ask")
    let priv = TodayCardText.make(sender: "A", subject: "S", ask: "Send the plan", redactDetails: true, allowOfflineDetails: true)
    check(priv.sender == "Private" && priv.line == "Private message" && !priv.showsDetails, "protected row: metadata only")

    // Calm notifications.
    check(TodayNotificationFilter.allows(decision: dec(.needsReply, .medium), fromVIP: false, triageActive: true), "needs you, medium → notify")
    check(!TodayNotificationFilter.allows(decision: dec(.needsReply, .low), fromVIP: false, triageActive: true), "low confidence → quiet")
    check(!TodayNotificationFilter.allows(decision: dec(.fyi, .high), fromVIP: false, triageActive: true), "FYI → quiet")
    check(TodayNotificationFilter.allows(decision: dec(.fyi, .high), fromVIP: true, triageActive: true), "VIP → notify")
    check(!TodayNotificationFilter.allows(decision: nil, fromVIP: false, triageActive: true), "no decision yet → quiet")
    check(TodayNotificationFilter.allows(decision: nil, fromVIP: false, triageActive: false), "triage off → passes (never mutes all)")
    check(MailNotificationSettings().needsYouOnly, "new installs: Needs-you only is on")
    let old = try? JSONDecoder().decode(MailNotificationSettings.self, from: Data(#"{"enabled":true}"#.utf8))
    check(old?.needsYouOnly == false, "existing stored settings: off")
    if let d = try? JSONEncoder().encode(MailNotificationSettings(needsYouOnly: true)),
       let back = try? JSONDecoder().decode(MailNotificationSettings.self, from: d) {
        check(back.needsYouOnly, "the switch round-trips")
    } else { check(false, "the switch round-trips") }
    check(VirtualFolder(id: VirtualFolder.today.id) == .today, "Today's virtual id round-trips")

    // Flow.
    var f = TodayFlow(items: ["a", "b", "c"])
    check(f.current == "a" && f.position == (1, 3), "Flow starts at 1 of 3")
    f.next(); check(f.current == "b" && f.position == (2, 3), "J → 2 of 3")
    f.previous(); check(f.current == "a", "K → back")
    f.previous(); check(f.current == "a", "K at the start stays")
    f.handleCurrent(); check(f.current == "b", "an action moves on")
    f.previous(); check(f.current == "a", "K can look back at a handled one")
    f.next(); f.handleCurrent(); f.next()
    check(f.finished && f.current == nil && f.summary == (2, 1), "past the end → You're clear, quiet summary")
    f.previous(); check(!f.finished && f.current == "c", "K from the end → the last item")
    var g = TodayFlow(items: ["a", "b", "c"], start: "b")
    g.handleCurrent(); g.previous(); g.next(); check(g.current == "c", "J skips handled items")
    check(TodayFlow(items: []).finished, "empty Flow is clear at once")
}
