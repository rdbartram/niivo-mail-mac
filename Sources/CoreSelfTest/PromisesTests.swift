import Foundation
import CryptoKit
import CalendarCore
import MailCore
import OfficeTools

// PROMISES: extraction (DE/EN/FR/IT), due dates, the sealed ledger, auto-complete, isolation, gate. Synthetic only;
// nothing here prints a phrase, subject or address.

final class PromiseGateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _tight = false
    var tight: Bool { get { lock.withLock { _tight } } set { lock.withLock { _tight = newValue } } }
}

@MainActor
func runPromisesTests() async {
    section("Promises ledger: extraction, due dates, store, auto-complete, isolation, gate")
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let iso = ISO8601DateFormatter()
    let sent = iso.date(from: "2026-11-18T12:00:00Z")!   // a Wednesday
    func day(_ s: String) -> Date { iso.date(from: s + "T00:00:00Z")! }
    func P(_ s: String) -> [PromiseCandidate] { PromiseExtractor.extract(s, isHTML: false, kind: .promised, sentAt: sent, calendar: utc) }
    func A(_ s: String) -> [PromiseCandidate] { PromiseExtractor.extract(s, isHTML: false, kind: .asked, sentAt: sent, calendar: utc) }

    // MARK: Positives (sent mail), with due dates
    let positives: [(String, String?, Bool)] = [
        ("Hi Anna, I'll send you the revised offer by Friday.", "2026-11-20", true),
        ("We will review the contract next week.", "2026-11-27", true),
        ("I'm going to call the supplier tomorrow.", "2026-11-19", true),
        ("I'll be sending the minutes on 3 December.", "2026-12-03", true),
        ("As discussed on 12.11., I'll send the plan by Friday.", "2026-11-20", true),
        ("I will share the slides by end of month.", "2026-11-30", true),
        ("ich schicke dir bis Freitag die Unterlagen", "2026-11-20", true),
        ("Morgen schicke ich Ihnen die Offerte.", "2026-11-19", true),
        ("Ich werde mich bis 21.11. melden.", "2026-11-21", true),
        ("Ich kläre das in 3 Tagen mit der Buchhaltung.", "2026-11-21", true),
        ("Wir werden die Rechnung bis 3.1. korrigieren.", "2027-01-03", true),
        ("je t'envoie demain le planning", "2026-11-19", true),
        ("Je vous enverrai le devis vendredi.", "2026-11-20", true),
        ("Je vais vérifier la facture après-demain.", "2026-11-20", true),
        ("ti mando entro lunedì il contratto", "2026-11-23", true),
        ("Le manderò il preventivo domani.", "2026-11-19", true),
        ("I'll get back to you.", nil, true),
        ("Let me check with finance.", nil, false),
        ("Ich melde mich.", nil, false),
    ]
    for (s, due, certain) in positives {
        let c = P(s)
        check(c.count == 1 && c[0].kind == .promised && c[0].due == due.map(day) && c[0].certain == certain,
              "promise found with due/certainty (\(c.first?.due.map { iso.string(from: $0).prefix(10) } ?? "none"), n=\(c.count))")
    }
    check(P("Hi Anna, I'll send you the revised offer by Friday.").first?.text == "I'll send you the revised offer by Friday",
          "phrase starts at the commitment (greeting dropped, punctuation trimmed)")
    let long = P("I'll send you the complete revised offer including the detailed breakdown of all hardware licences and services by Friday.")
    check(long.first.map { $0.text.count <= 80 && $0.text.hasSuffix("…") } ?? false, "phrase capped at 80 characters")
    check(P("I'll send “the final version” on Friday.").first.map { !$0.text.contains("“") } ?? false, "phrase is de-quoted")

    // MARK: Negatives
    let negatives = [
        "I'll be out of office until Monday.", "If you need it, I'll send it Friday.", "Shall I send it Friday?",
        "He said \"I'll send it Friday\" but nothing came.", "I'll need your input by Friday.",
        "Ich bin bis Montag abwesend.", "Anbei schicke ich dir die Offerte.", "Falls nötig, würde ich das prüfen.",
        "Ich werde morgen im Büro sein.", "Je serai absent demain.", "Sarò fuori ufficio fino a lunedì.",
        "Thanks for the update, see you next week.", "Guten Morgen Anna, danke für die Zahlen.",
        "Hi Anna\n\nThanks.\n\nOn Tue, 17 Nov 2026 Anna wrote:\n> I'll send it Friday",
    ]
    for s in negatives { check(P(s).isEmpty, "no promise in a hypothetical / quoted / out-of-office / delivered-now sentence") }

    // MARK: Requests (received direct mail): explicit request + deadline
    let asks: [(String, String)] = [
        ("Hallo Alex, könnten Sie mir bis Freitag die Offerte schicken?", "2026-11-20"),
        ("Could you send the invoice by 21.11.?", "2026-11-21"),
        ("Pourriez-vous confirmer la date avant le 3 décembre ?", "2026-12-03"),
        ("Potrebbe inviarmi il contratto entro venerdì?", "2026-11-20"),
        ("Die Unterlagen brauchen wir spätestens Montag.", "2026-11-23"),
    ]
    for (s, due) in asks {
        let c = A(s)
        check(c.count == 1 && c[0].kind == .asked && c[0].due == day(due), "request with deadline → owed by you")
    }
    check(A("Hallo Alex, könnten Sie mir bis Freitag die Offerte schicken?").first?.text.hasPrefix("Könnten Sie") == true, "request phrase starts at the ask")
    check(A("Could you review the plan?").isEmpty, "a request without a deadline isn't stored")
    check(A("Please find attached the report for Friday.").isEmpty, "'please find attached' isn't a request")

    // MARK: Date resolution
    func R(_ s: String) -> Date? { PromiseDates.resolve(s, sentAt: sent, calendar: utc) }
    check(R("bis übermorgen") == day("2026-11-20") && R("dopodomani") == day("2026-11-20"), "day after tomorrow (DE/IT), not tomorrow")
    check(R("am 21.11.2026") == day("2026-11-21") && R("le 21/11/2026") == day("2026-11-21") && R("2026-11-21") == day("2026-11-21"), "numeric European / ISO formats")
    check(R("December 3rd") == day("2026-12-03") && R("il 3 dicembre") == day("2026-12-03"), "month names (EN/IT)")
    check(R("bis Ende Woche") == day("2026-11-20") && R("la semaine prochaine") == day("2026-11-27"), "end of week / next week")
    check(R("heute") == day("2026-11-18") && R("on 31.02.") == nil, "today; an impossible date is ignored")
    check(R("bis Mittwoch") == day("2026-11-25"), "same weekday as the sent day → next week")

    // MARK: Ledger (store-backed)
    let L = FixtureCalendarService.labels
    let eng = CachedLabelPolicyEngine(labels: L, synced: true)
    let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
    let store = try! MailStore(url: nil, key: SymmetricKey(size: .bits256), persistPolicy: { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) })
    try? store.replace(folders: [MailFolder(id: "inbox", displayName: "inbox", wellKnown: .inbox), MailFolder(id: "sent", displayName: "sent", wellKnown: .sentitems)], mailbox: "me")
    let me = EmailAddress(name: "Alex Muster", address: "owner@niivo-test.example")
    let anna = EmailAddress(name: "Anna", address: "anna@kunde.example")
    let flag = PromiseGateFlag()
    func cfg(_ account: String) -> PromiseLedger.Config {
        .init(account: account, owners: [me.address], exposure: { m, mb in flag.tight ? .metadata : gate.exposure(m, mailbox: mb, tier: .onDevice) },
              persistText: { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng).allowOfflineDetails }, calendar: utc)
    }
    func mine(_ cid: String, _ i: Int, _ text: String, hours: Double, attach: Bool = false, label: String? = nil, priv: Bool = false) -> MailMessage {
        MailMessage(id: "\(cid)-\(i)", folderId: "sent", conversationId: cid, subject: "Projekt", from: me, toRecipients: [anna],
                    received: sent.addingTimeInterval(hours * 3_600), preview: text, hasAttachments: attach, labelId: label, isPrivate: priv)
    }
    func inbound(_ cid: String, _ i: Int, _ text: String, from: EmailAddress = anna, cc: Bool = false, others: Int = 0) -> MailMessage {
        let o = (0..<others).map { EmailAddress(name: "O\($0)", address: "o\($0)@kunde.example") }
        return MailMessage(id: "\(cid)-\(i)", folderId: "inbox", conversationId: cid, subject: "Projekt", from: from,
                           toRecipients: cc ? o : [me] + o, ccRecipients: cc ? [me] : [], received: sent, preview: text)
    }
    let ledger = store.enablePromises(cfg("acct-A"))
    try? store.upsert(messages: [mine("p1", 0, "Hi Anna, I'll send you the revised offer by Friday.", hours: 0),
                                 mine("p2", 0, "Ich schicke dir bis Freitag die Unterlagen.", hours: 0),
                                 mine("p3", 0, "Je vous enverrai le devis vendredi.", hours: 0),
                                 inbound("p4", 0, "Hallo Alex, könnten Sie mir bis Freitag die Offerte schicken?"),
                                 inbound("p5", 0, "Please send the form by Friday.", from: EmailAddress(name: "Shop", address: "newsletter@shop.example")),
                                 inbound("p6", 0, "Could you send the figures by Friday?", cc: true, others: 4),
                                 mine("p7", 0, "I'll send it Friday.", hours: 0, label: L[3].id),
                                 mine("p8", 0, "I'll send it Friday.", hours: 0, priv: true),
                                 mine("p9", 0, "Ti mando entro lunedì il contratto.", hours: 0)])
    let found = ledger.refresh(now: sent.addingTimeInterval(3_600))
    check(found == 5 && ledger.open(now: sent).count == 5, "five promises extracted (\(found)): newsletter, Cc broadcast, protected and private skipped")
    check(ledger.promises(conversationId: "p4").first?.kind == .asked && ledger.promises(conversationId: "p1").first?.kind == .promised, "sent → promised, direct request → asked")
    check(ledger.promises(conversationId: "p7").isEmpty && ledger.promises(conversationId: "p8").isEmpty, "protected-label and private rows are skipped (no text read)")
    check(ledger.promises(conversationId: "p1").first?.counterpartAddress == anna.address, "counterpart = the To recipient")
    check(ledger.refresh(now: sent) == 0 && ledger.all().count == 5, "a re-scan adds nothing (insert-if-absent)")

    let fri = iso.date(from: "2026-11-20T09:00:00Z")!, mon = iso.date(from: "2026-11-23T09:00:00Z")!
    let src: any PromiseSource = ledger
    check(src.promisesDue(before: .distantFuture).count == 5, "PromiseSource (Today): every open promise before a far date")
    let endFri = iso.date(from: "2026-11-21T00:00:00Z")!
    check(ledger.promisesDue(before: endFri, now: fri).count == 4 && ledger.promisesDue(before: endFri, now: fri).allSatisfy { $0.title.hasPrefix("You promised") || $0.title.hasPrefix("Asked of you") },
          "PromiseSource: due by the end of Friday, titled by kind")
    check(ledger.promisesDue(before: iso.date(from: "2026-11-19T00:00:00Z")!, now: sent).isEmpty, "nothing due on the sent day")
    check(ledger.stats(now: mon).overdue == 4, "overdue after the due day")

    // Auto-complete
    try? store.upsert(messages: [mine("p1", 1, "Here you go.", hours: 5, attach: true), mine("p2", 1, "Anbei die Unterlagen.", hours: 5),
                                 mine("p3", 1, "Merci, à bientôt.", hours: 5)])
    ledger.refresh(now: sent.addingTimeInterval(6 * 3_600))
    check(ledger.promises(conversationId: "p1").first?.completion == .attachment, "auto-done: a later send with an attachment")
    check(ledger.promises(conversationId: "p2").first?.completion == .attachedMarker, "auto-done: a later send saying 'anbei'")
    check(ledger.promises(conversationId: "p3").first?.state == .open, "a later send without attachment / marker leaves it open")
    check(ledger.stats(now: mon).autoDone == 2, "autoDone counted")

    // User actions survive re-scans
    let p3 = ledger.promises(conversationId: "p3")[0].id
    ledger.dismiss(p3)
    ledger.policyChanged(); ledger.refresh(now: sent)
    check(ledger.promise(id: p3)?.state == .dismissed && ledger.all().count == 5, "dismissed stays dismissed after a full re-scan")
    let p9 = ledger.promises(conversationId: "p9")[0].id
    ledger.snooze(p9, until: mon)
    check(!ledger.open(now: fri).contains { $0.id == p9 } && ledger.open(now: mon.addingTimeInterval(60)).contains { $0.id == p9 }, "snooze hides until the date")
    ledger.markDone(p9)
    check(ledger.promise(id: p9)?.completion == .user, "marked done by the user")
    check(Set(store.debugPromisePayloadSizes()).count == 1, "promise payloads are padded to one sealed size")
    check(ledger.diagnostic(now: mon).hasPrefix("[Promises] extracted=5 open="), "diagnostic line is counts only")

    // Per-account isolation (same store, other namespace)
    store.enablePromises(cfg("acct-B")); ledger.refresh(now: sent)
    check(ledger.all().count == 5 && ledger.promise(id: p3)?.state == .open, "account B: own rows only (A's dismiss not visible)")
    store.enablePromises(cfg("acct-A")); ledger.refresh(now: sent)
    check(ledger.promise(id: p3)?.state == .dismissed, "account A's dismiss unaffected by B")

    // Gate tightening: open rows from messages no longer readable go
    flag.tight = true; ledger.policyChanged(); ledger.refresh(now: sent)
    check(ledger.open(now: sent).isEmpty, "gate tightened → open promises from now-unreadable messages removed")
    flag.tight = false
    try? store.wipe()
    check(store.debugPromisePayloadSizes().isEmpty, "wipe clears the ledger")

    // AI refine (plain JSON, defensive)
    let rf = AIAssistant.parsePromiseRefinements("```json\n[{\"p\":1,\"keep\":false},{\"p\":2,\"keep\":true,\"text\":\"Send the plan\",\"due\":\"2026-11-20\"},{\"p\":9,\"keep\":true},{\"p\":3}]\n```",
                                                 items: [1: "a", 2: "b", 3: "c"], calendar: utc)
    check(rf.count == 2 && rf["a"]?.keep == false && rf["b"]?.due == day("2026-11-20") && rf["b"]?.text == "Send the plan", "AI refine: parsed; unknown / malformed items keep the rule result")

    // MCP: read-only promises_open (fixture backend, gate-filtered)
    var sc = ServerConfig(); sc.allowDrafts = false; sc.allowTriage = false
    if let b = try? await Backend.make(sc) {
        let srv = MCPServer.agent(backend: b, audit: AuditSink.make(fixtures: true, path: nil))
        let r = await srv.callTool("promises_open", argumentsJSON: "{}")
        let o = ((try? JSONSerialization.jsonObject(with: Data(r.text.utf8))) as? [String: Any]) ?? [:]
        check(!r.isError && o["promises"] is [Any] && !r.text.contains(FixtureMailService.Special.privateMsg), "promises_open: a list, private items never returned")
    } else { check(false, "fixture backend for promises_open") }
}
