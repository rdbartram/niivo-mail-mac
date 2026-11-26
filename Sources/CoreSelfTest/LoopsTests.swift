import Foundation
import CryptoKit
import CalendarCore
import MailCore

// LOOPS (docs/SUITE.md step 1): loops as first-class objects. A synthetic DE/EN/FR/IT corpus (`.example` domains);
// phase 1 seeds loops from knowledge matters, phase 2 adds new conversations and checks the proposals. Failure lines
// print only ids / counts the test made up.

@MainActor
func runLoopsTests() async {
    section("Loops: proposals, seeding, confirm / merge / split / not this loop, isolation, protected sources (suite step 1)")
    let L = FixtureCalendarService.labels
    let protected = L[3].id, noOffline = L[1].id   // "General" with offline details forced off
    let now = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    func d(_ m: Int, _ day: Int, _ h: Int = 10) -> Date { utc.date(from: DateComponents(year: 2026, month: m, day: day, hour: h))! }
    let eng = CachedLabelPolicyEngine(labels: L, synced: true)
    let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
    let me = EmailAddress(name: "Alex Owner", address: "owner@niivo-test.example")
    let thomas = EmailAddress(name: "Thomas Keller", address: "t.keller@keller-ag.example")
    let anna = EmailAddress(name: "Anna Smith", address: "anna@acme-trading.example")
    let bob = EmailAddress(name: "Bob Jones", address: "bob@acme-trading.example")
    let claire = EmailAddress(name: "Claire Dubois", address: "c.dubois@etude-dubois.example")
    let giulia = EmailAddress(name: "Giulia Rossi", address: "giulia@studiorossi.example")
    let fritz = EmailAddress(name: "Fritz Heiz", address: "fritz@heiztech.example")
    let stranger = EmailAddress(name: "Sam Other", address: "sam@unrelated.example")
    let news = EmailAddress(name: "Forum", address: "news@architektur-forum.example")
    let list = EmailAddress(name: "Forum Mitglieder", address: "mitglieder@architektur-forum.example")
    let marta = EmailAddress(name: "Marta Neri", address: "marta@studio-neri.example")

    var n = 0
    func mail(_ conv: String, _ from: EmailAddress, _ to: [EmailAddress], _ subject: String, _ date: Date, atts: [String] = [],
              label: String? = nil) -> MailMessage {
        n += 1
        let id = "lp\(n)"
        let mine = from.address == me.address
        return MailMessage(id: id, folderId: mine ? "sent" : "inbox", conversationId: conv, subject: subject, from: from,
                           toRecipients: to, received: date, preview: subject, hasAttachments: !atts.isEmpty,
                           attachments: atts.enumerated().map { AttachmentInfo(id: "\(id)-a\($0.offset)", name: $0.element, contentType: "application/pdf", size: 1000) },
                           labelId: label)
    }
    func pair(_ c: String, _ who: EmailAddress, _ s: String, _ date: Date, atts: [String] = [], label: String? = nil) -> [MailMessage] {
        [mail(c, who, [me], s, date, atts: atts, label: label), mail(c, me, [who], "AW: " + s, date.addingTimeInterval(3600), label: label)]
    }
    // Phase 1: the history the seed sees.
    var p1: [MailMessage] = []
    p1 += pair("S0", thomas, "Projekt Seeblick – Vorprojekt", d(2, 3))                       // DE, project name
    p1 += pair("S1", thomas, "Projekt Seeblick: Grundriss EG", d(2, 9), atts: ["Seeblick_Grundriss_v3.pdf"])
    p1 += pair("G1", thomas, "Umbau Garage", d(2, 6), atts: ["Garage_Plan.pdf"])               // shared file
    p1 += pair("G2", thomas, "Garage Rückmeldung", d(2, 20), atts: ["Garage_Plan.pdf"])
    p1 += pair("U1", thomas, "Kurze Frage", d(2, 10))                                          // no anchor
    p1 += pair("E1", anna, "Order confirmation PO 4500123456", d(3, 2))                         // EN, reference number
    p1 += pair("E2", anna, "Delivery schedule PO 4500123456", d(3, 9))
    p1 += pair("F1", claire, "Dossier 2026-0417 vente appartement", d(4, 1))                   // FR, dossier number
    p1 += pair("F2", claire, "Dossier 2026-0417 projet d'acte", d(4, 8))
    p1 += pair("I0", giulia, "Grazie mille", d(5, 1))   // a plain exchange (the store keeps no recipients for no-offline mail)
    p1 += pair("I1", giulia, "Progetto Monte – preventivo", d(5, 4), label: noOffline)          // IT, no offline details
    p1 += pair("I2", giulia, "Progetto Monte sopralluogo", d(5, 12), label: noOffline)
    for k in 1...3 { p1.append(mail("N\(k)", news, [list], "Newsletter: Projekt Glasturm \(k)", d(3, k * 5))) }   // bulk only
    let store: MailStore
    do {
        store = try MailStore(url: nil, key: SymmetricKey(size: .bits256))
        store.setPersistPolicy { m, mb in
            var p = MailContentPolicy.policy(for: m, mailbox: mb, engine: eng)
            if m.labelId == noOffline { p.allowOfflineDetails = false }
            return p
        }
        try store.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox),
                                    MailFolder(id: "sent", displayName: "Sent", wellKnown: .sentitems)], mailbox: "me")
        try store.upsert(messages: p1)
    } catch { check(false, "loops store threw \(error)"); return }
    let k = store.enableKnowledge(KnowledgeEngine.Config(account: "acct-A", owners: [me.address], internalDomains: ["niivo-test.example"], gate: gate))
    k.refresh(now: now)
    let cfgA = LoopsEngine.Config(account: "acct-A", owners: [me.address])
    let loops = store.enableLoops(cfgA, knowledge: k)

    // Seeding: knowledge matters become SUGGESTED loops; bulk-only anchors don't.
    let seeded = loops.seed(now: now)
    let all0 = loops.loops(includeSuggested: true)
    check(seeded >= 4 && all0.allSatisfy { !$0.confirmed }, "seed: \(seeded) suggested loops from knowledge matters, none confirmed")
    check(loops.loops(includeSuggested: false).isEmpty, "seed: suggested loops are hidden when only confirmed ones are asked for")
    func loopOf(_ cid: String) -> String? { loops.membership(forConversation: cid)?.loopId }
    check(loopOf("S0") != nil && loopOf("S0") == loopOf("S1"), "seed: the Seeblick project (DE) is one loop")
    check(loopOf("E1") != nil && loopOf("E1") == loopOf("E2"), "seed: the PO number (EN) is one loop")
    check(loopOf("F1") != nil && loopOf("F1") == loopOf("F2"), "seed: the dossier number (FR) is one loop")
    check(loopOf("G1") != nil && loopOf("G1") == loopOf("G2"), "seed: the shared file is one loop")
    check(loopOf("N1") == nil && loopOf("N2") == nil, "seed: newsletter threads (no direct exchange) never seed a loop")
    check(loopOf("U1") == nil, "seed: an unanchored thread joins nothing")
    if case .proposed(let kind, let ev)? = loops.membership(forConversation: "S0")?.origin {
        check(kind == .proj && !ev.isEmpty && !ev.lowercased().contains("seeblick"), "seed: membership records proposed(kind, keyed evidence), no anchor text")
    } else { check(false, "seed: membership records proposed(kind, keyed evidence)") }
    check(loops.confirmedLoop(forConversation: "S0") == nil, "seed: proposed memberships show no confirmed chip")
    check(loops.seed(now: now) == 0 && loops.loops(includeSuggested: true).count == all0.count, "seed is idempotent")
    let seeblick = loopOf("S0") ?? "-", acme = loopOf("E1") ?? "-", dossier = loopOf("F1") ?? "-", monte = loopOf("I1")
    check(loops.loop(id: seeblick)?.title == "Project Seeblick", "seed: title from the matter (project name)")

    // Phase 2: new conversations arrive.
    var p2: [MailMessage] = []
    p2 += pair("S9", thomas, "Projekt Seeblick Baueingabe Rückfragen", d(11, 10))               // proj → Seeblick
    p2 += pair("E3", bob, "Invoice for PO 4500123456", d(11, 11))                              // id links alone (other person)
    p2 += pair("F3", claire, "Dossier 2026-0417 signature", d(11, 12))                          // FR id
    p2 += pair("I3", giulia, "Progetto Monte varianti", d(11, 13), label: noOffline)            // IT proj
    p2 += pair("G3", stranger, "Plans", d(11, 14), atts: ["Garage_Plan.pdf"])                   // att, nobody shared → no
    p2 += pair("G4", thomas, "Plan Update", d(11, 14), atts: ["Garage_Plan.pdf"])               // att + same person → yes
    p2 += pair("U2", thomas, "Termin nächste Woche", d(2, 12))                                  // same person + month, no anchor
    p2.append(mail("H1", thomas, [me], "Projekt Seeblick PO 4500123456 Vollmacht", d(11, 15), label: protected))   // protected
    p2 += pair("K1", fritz, "Heizungsersatz Wärmepumpe Bodenplatte", d(9, 1))                   // stem tests
    p2 += pair("K2", fritz, "Heizungsersatz Wärmepumpe Bodenplatte Termine", d(9, 11))
    p2 += pair("K3", fritz, "Heizungsersatz Wärmepumpe Bodenplatte Abnahme", d(11, 15))
    p2 += pair("K4", marta, "Heizungsersatz Wärmepumpe Bodenplatte", d(9, 5))                   // stem, other person
    p2.append(mail("N4", news, [list], "Newsletter: Projekt Seeblick Rundgang", d(11, 16)))      // bulk: proj never links
    do { try store.upsert(messages: p2) } catch { check(false, "phase 2 upsert threw \(error)"); return }
    k.refresh(now: now)

    func best(_ cid: String) -> String? { loops.propose(conversationId: cid).best?.loop.id }
    let pS9 = loops.propose(conversationId: "S9")
    check(pS9.best?.loop.id == seeblick && pS9.best?.reason.kind == .proj && pS9.best?.reason.anchorText == "Seeblick",
          "propose (DE): project name → Seeblick, with the reason")
    check(pS9.newTitle == "Projekt Seeblick Baueingabe Rückfragen", "propose: a new-loop title from the subject stem")
    check(best("E3") == acme && loops.propose(conversationId: "E3").best?.reason.kind == .id, "propose (EN): a reference number links alone, even from another person")
    check(best("F3") == dossier, "propose (FR): dossier number → the dossier loop")
    if let monte { check(best("I3") == monte, "propose (IT): progetto → the Monte loop") }
    else { check(false, "propose (IT): the Monte loop was seeded") }
    let garage = loopOf("G1")
    check(best("G3") == nil, "propose: a shared file without a shared person or organisation proposes nothing")
    check(best("G4") == garage && loops.propose(conversationId: "G4").best?.reason.kind == .att, "propose: shared file + same person → the file loop")
    check(best("U1") == nil && best("U2") == nil, "propose: same people, same month, no shared anchor → nothing (never similarity alone)")
    check(best("N4") == nil, "propose: a newsletter naming the project doesn't link (bulk links only through a reference number)")
    let pH1 = loops.propose(conversationId: "H1")
    check(pH1.best == nil && pH1.alternatives.isEmpty && pH1.newTitle == nil,
          "protected: a protected conversation (PO + project in its subject) yields no anchor, proposal or title")
    check(pS9.alternatives.count <= 2, "propose: at most two alternatives")
    // Stem: shared person + ≤ 21 days only.
    let heat = loops.createLoop(title: "Heating", conversations: ["K1"], now: now)
    let pK2 = loops.propose(conversationId: "K2")
    check(pK2.best?.loop.id == heat && pK2.best?.reason.kind == .stem && pK2.best?.reason.samePeople == true,
          "propose: subject stem + same person within 21 days → the loop (confirmed members, same people)")
    check(best("K3") == nil, "propose: the same stem more than 21 days later proposes nothing")
    check(best("K4") == nil, "propose: the same stem from someone else proposes nothing")
    // Alternatives: E3 also matches a second loop with the same PO.
    let poAlt = loops.createLoop(title: "Customs paperwork", conversations: [], now: now)
    loops.assign("E2", to: poAlt, now: now)   // E2 leaves the Acme loop (one loop per conversation)
    let pE3 = loops.propose(conversationId: "E3")
    check(Set([pE3.best?.loop.id] + pE3.alternatives.map(\.loop.id)) == Set([acme, poAlt]), "propose: the best loop plus an alternative")
    loops.assign("E2", to: acme, now: now)
    loops.setState(poAlt, .archived, now: now)

    // Confirm, not this loop, rename, merge, split: persisted (read back through a fresh engine).
    loops.noteProposalShown("S9")
    loops.assign("S9", to: seeblick, now: now)
    check(loops.confirmedLoop(forConversation: "S9")?.id == seeblick && loops.loop(id: seeblick)?.confirmed == true,
          "assign: confirmed membership; the suggested loop becomes confirmed")
    check(loops.diagnostic() == "[Loops] open=\(loops.loops(includeSuggested: true).filter { $0.state == .open }.count) confirmed=\(loops.loops(includeSuggested: false).count) suggested=\(loops.loops(includeSuggested: true).filter { !$0.confirmed }.count) proposalsShown=1 accepted=1",
          "diagnostic: counts only (\(loops.diagnostic()))")
    _ = loops.propose(conversationId: "F3")
    loops.notThisLoop("F3", loopId: dossier, now: now)
    check(best("F3") == nil, "not this loop: the same proposal doesn't come back")
    loops.rename(acme, to: "Acme order", now: now)
    loops.setDue(acme, d(12, 1), now: now)
    let merged = loops.merge(acme, dossier, now: now)
    check(merged == acme && loops.loop(id: dossier) == nil && loopOf("F1") == acme && loopOf("E1") == acme,
          "merge: the older loop survives with both loops' conversations")
    check(best("F3") != acme, "merge: a 'not this loop' memory moves to the surviving loop")
    let split = loops.split(acme, conversations: ["F1", "F2"], title: "Apartment sale", now: now)
    check(split != nil && loopOf("F1") == split && loopOf("E1") == acme, "split: the chosen conversations move to a new loop")
    check(best("F1") != acme, "split: moved conversations are never proposed back to the old loop")
    loops.setState(seeblick, .done, now: now)

    let fresh = store.makeLoopsEngine(cfgA, knowledge: k)
    check(fresh.confirmedLoop(forConversation: "S9")?.id == seeblick, "persisted: a confirmed membership survives a fresh engine")
    check(fresh.loop(id: acme)?.title == "Acme order" && fresh.loop(id: acme)?.due == d(12, 1), "persisted: rename and due date")
    check(fresh.loop(id: seeblick)?.state == .done, "persisted: state")
    check(fresh.propose(conversationId: "F3").best?.loop.id != acme, "persisted: 'not this loop' (moved by the merge) survives")
    check(fresh.membership(forConversation: "F1")?.loopId == split && fresh.loop(id: dossier) == nil, "persisted: merge and split")
    check(fresh.propose(conversationId: "S1").best?.loop.id != seeblick, "a done loop isn't proposed")
    // Reject a suggestion; the next seed pass must not bring it back.
    if let garage {
        loops.setState(garage, .archived, now: now)
        for c in ["G1", "G2"] { loops.notThisLoop(c, loopId: garage, now: now) }
    }
    _ = fresh.seed(now: now)
    let again = store.makeLoopsEngine(cfgA, knowledge: k)
    check(again.membership(forConversation: "G1") == nil && again.membership(forConversation: "G2") == nil && again.loop(id: dossier) == nil
          && again.membership(forConversation: "F3") == nil,
          "seed again: rejected / archived / merged suggestions stay gone")
    check(loops.propose(conversationId: "G4").best == nil, "seed again: an archived loop is not proposed")

    // Derived titles: on disk only where every source may keep offline details.
    if let monte {
        let monteVisible = fresh.loop(id: monte)?.title
        let reread = store.makeLoopsEngine(cfgA, knowledge: k)
        let before = reread.loop(id: monte)?.title
        reread.seed(now: now)
        check(before == nil && monteVisible == "Project Monte" && reread.loop(id: monte)?.title == "Project Monte",
              "title: a derived title from mail without offline details isn't on disk; the next seed pass restores it in memory")
        reread.rename(monte, to: "Project Monte")   // the loop page's title field submitted unchanged
        check(store.makeLoopsEngine(cfgA, knowledge: k).loop(id: monte).map { $0.title == nil && !$0.confirmed } == true,
              "title: return on an unchanged derived title stores nothing and confirms nothing")
    }

    // Protected sources contribute metadata only.
    loops.assign("H1", to: seeblick, now: now)
    let det = loops.detail(seeblick)
    let h1 = det?.members.first { $0.conversationId == "H1" }
    check(h1 != nil && (h1?.thread?.subject ?? "") == "" && !(det?.files.contains { $0.messageId.hasPrefix("lp") && $0.name.contains("Vollmacht") } ?? true),
          "protected: a protected member shows no subject or files on the loop page")
    check(det?.summary.people.contains(thomas.address) == true, "protected: people still come from metadata")
    check(loops.detail(seeblick, tier: .ai(.cloud))?.summary.title == nil, "protected: an AI tier doesn't see the loop title when a member is protected for it")
    check(det?.summary.title == "Project Seeblick", "user tier: the title still shows (its source is visible)")
    check(loops.loops(withPeople: [thomas.address, "nobody@x.example"], includeSuggested: true).contains { $0.id == seeblick }
          && loops.loops(withOrganisation: "keller-ag.example", includeSuggested: true).contains { $0.id == seeblick },
          "LoopSource: loops by person (several addresses) and by organisation")
    check(!loops.loops(withOrganisation: "niivo-test.example", includeSuggested: true).contains { $0.id == seeblick },
          "LoopSource: the owner's own organisation never counts")

    let involving = loops.loops(involving: thomas.address, account: "acct-A")
    check(involving.contains { $0.id == seeblick } && loops.loops(involving: thomas.address, account: "acct-B").isEmpty,
          "LoopSource (People page): loops(involving:account:) for this account only")
    check(involving.first { $0.id == seeblick }?.waitingOn == .me, "LoopSource: their message is the newest → waiting on me")
    // Per-account isolation.
    let other = store.makeLoopsEngine(LoopsEngine.Config(account: "acct-B", owners: [me.address]), knowledge: k)
    let rowsB = other.debugRowCounts()
    check(other.loops(includeSuggested: true).isEmpty && rowsB.loops == 0 && rowsB.members == 0 && other.confirmedLoop(forConversation: "S9") == nil,
          "isolation: another account sees none of these loops or memberships")
    check(other.propose(conversationId: "S9").best == nil, "isolation: proposals never reach another account's loops")
    let otherLoop = other.createLoop(title: "B only", conversations: ["E1"], now: now)
    check(loops.loop(id: otherLoop) == nil && loops.membership(forConversation: "E1")?.loopId == acme
          && store.makeLoopsEngine(cfgA, knowledge: k).membership(forConversation: "E1")?.loopId == acme,
          "isolation: a loop in account B doesn't touch account A's memberships")
    let sizes = store.debugLoopPayloadSizes()
    check(!sizes.isEmpty && Set(sizes.map { $0 % 1024 }).count == 1, "storage: sealed, bucket-padded payloads (one size class mod 1 KB)")

    // Wipe drops everything; a header reset keeps loops.
    try? store.resetHeaders()
    check(store.makeLoopsEngine(cfgA, knowledge: k).loop(id: acme) != nil, "header reset: loops survive (user data)")
    try? store.wipe()
    check(store.makeLoopsEngine(cfgA, knowledge: k).loops(includeSuggested: true).isEmpty, "wipe: loops are removed")
}
