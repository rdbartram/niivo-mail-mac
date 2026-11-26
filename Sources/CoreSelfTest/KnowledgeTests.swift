import Foundation
import CryptoKit
import CalendarCore
import MailCore

// PEOPLE: knowledge layer (docs/INBOX-INTELLIGENCE-PLAN.md Phase 2). A synthetic DE/EN/FR/IT corpus with personas
// and distractors (opposing counsel only in Cc, a law firm's assistant, a newsletter-only architect, a second anchored
// group and unanchored threads in the right month, protected / unknown-label / private rows carrying role words).
// `.example` domains only; nothing here prints names, subjects or addresses from the corpus in a failure path
// beyond the persona keys the test itself made up.

struct KnowledgeCorpus {
    var messages: [MailMessage] = []
    var bodies: [String: String] = [:]
}

@MainActor
func makeKnowledgeCorpus(now: Date) -> KnowledgeCorpus {
    let L = FixtureCalendarService.labels
    let protected = L[3].id
    var c = KnowledgeCorpus()
    let me = EmailAddress(name: "Alex Owner", address: "owner@niivo-test.example")
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 10) -> Date { utc.date(from: DateComponents(year: y, month: m, day: day, hour: h))! }
    var n = 0
    func mail(_ conv: String, from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], _ subject: String, _ date: Date,
              body: String? = nil, atts: [String] = [], label: String? = nil, priv: Bool = false) {
        n += 1
        let id = "k\(n)"
        let mine = from.address == me.address
        let m = MailMessage(id: id, folderId: mine ? "sent" : "inbox", conversationId: conv, subject: subject, from: from,
                            toRecipients: to, ccRecipients: cc, received: date, preview: String((body ?? subject).prefix(120)),
                            hasAttachments: !atts.isEmpty,
                            attachments: atts.enumerated().map { AttachmentInfo(id: "\(id)-a\($0.offset)", name: $0.element, contentType: "application/pdf", size: 1000) },
                            labelId: label, isPrivate: priv)
        c.messages.append(m)
        if let body { c.bodies[id] = body }
    }
    let andrea = EmailAddress(name: "Andrea Muster", address: "andrea.muster@muster-partner.example")
    let andreaPriv = EmailAddress(name: "Andrea Muster", address: "andrea.muster@gmail.example")
    let petra = EmailAddress(name: "Petra Vogel", address: "petra.vogel@muster-partner.example")
    let marc = EmailAddress(name: "Marc Gegner", address: "m.gegner@kanzlei-gegner.example")
    let giulia = EmailAddress(name: "Giulia Rossi", address: "giulia.rossi@studiorossi.example")
    let thomas = EmailAddress(name: "Thomas Keller", address: "t.keller@keller-ag.example")
    let news = EmailAddress(name: "Architektur Forum", address: "news@architektur-forum.example")
    let list = EmailAddress(name: "Forum Mitglieder", address: "mitglieder@architektur-forum.example")
    let beat = EmailAddress(name: "Beat Zahner", address: "beat.zahner@zahner-treuhand.example")
    let claire = EmailAddress(name: "Claire Dubois", address: "c.dubois@etude-dubois.example")
    let hans = EmailAddress(name: "Hans Geheim", address: "hans@geheim.example")
    let ursula = EmailAddress(name: "Ursula Privat", address: "ursula@privat-recht.example")
    let otto = EmailAddress(name: "Otto Unbekannt", address: "otto@unbekannt.example")
    let franci = EmailAddress(name: "Francesca Bianchi", address: "franci@fornitore-bianchi.example")

    let andreaSig = "Guten Tag\n\nAnbei das Dokument.\n\nFreundliche Grüsse\nlic. iur. Andrea Muster\nRechtsanwältin\nMuster & Partner"
    // My lawyer (signature only, two addresses).
    mail("L1", from: me, to: [andrea], "Mandat Erbschaft", d(2026, 3, 4))
    mail("L1", from: andrea, to: [me], "AW: Mandat Erbschaft", d(2026, 3, 5), body: andreaSig)
    mail("L2", from: marc, to: [andrea], cc: [me], "Vergleichsverhandlung", d(2026, 6, 10),
         body: "Sehr geehrte Frau Kollegin\n\nMit freundlichen Grüssen\nMarc Gegner\nRechtsanwalt")
    mail("L2", from: andrea, to: [me], cc: [marc], "AW: Vergleichsverhandlung", d(2026, 6, 11), body: andreaSig)
    mail("L2", from: me, to: [andrea], "AW: Vergleichsverhandlung", d(2026, 6, 12))
    mail("L3", from: andreaPriv, to: [me], "Vollmacht unterzeichnet", d(2026, 9, 2), body: andreaSig)
    mail("L4", from: me, to: [andrea], "Rückfrage Erbteilung", d(2026, 10, 14))
    mail("L4", from: andrea, to: [me], "AW: Rückfrage Erbteilung", d(2026, 10, 15), body: andreaSig)
    // The law firm's assistant (same domain, more mail, I reply to her).
    let petraSig = "Gerne bestätige ich den Termin.\n\nPetra Vogel\nAnwaltsassistentin\nMuster & Partner"
    for (i, day) in [3, 9, 17, 24, 30].enumerated() {
        mail("P\(i)", from: petra, to: [me], i == 0 ? "Mandat Erbschaft: Unterlagen" : "Terminbestätigung \(i)", d(2026, 5, day), body: petraSig)
        mail("P\(i)", from: me, to: [petra], "AW: Terminbestätigung \(i)", d(2026, 5, day, 14))
    }
    // An Italian avvocata (fewer exchanges).
    mail("I1", from: giulia, to: [me], "Ricorso contratto", d(2026, 4, 2), body: "Cordiali saluti\nAvv. Giulia Rossi\nAvvocato")
    mail("I1", from: me, to: [giulia], "R: Ricorso contratto", d(2026, 4, 3))
    // My architect: the Feb project (6 conversations, anchored), a second anchored group, unanchored Feb threads.
    let thomasSig = "Beste Grüsse\nThomas Keller\ndipl. Architekt ETH SIA\nKeller AG"
    let seeblick: [(String, Int, [String])] = [
        ("Projekt Seeblick – Vorprojekt", 3, ["Seeblick_Vorprojekt.pdf"]), ("Projekt Seeblick: Grundriss EG", 9, ["Seeblick_Grundriss_v3.pdf"]),
        ("Bestellung PO 4500123456 Projekt Seeblick", 12, []), ("AW: Projekt Seeblick Baueingabe", 18, []),
        ("Projekt Seeblick – Kostenschätzung", 24, ["Seeblick_Kosten.xlsx"]),
    ]
    for (i, s) in seeblick.enumerated() {
        mail("S\(i)", from: thomas, to: [me], s.0, d(2026, 2, s.1), body: thomasSig, atts: s.2)
        mail("S\(i)", from: me, to: [thomas], "AW: " + s.0, d(2026, 2, s.1, 15))
    }
    mail("S5", from: thomas, to: [me], "Projekt Seeblick Teilrechnung PO 4500123456", d(2026, 3, 2), body: thomasSig)
    mail("G1", from: thomas, to: [me], "Umbau Garage Plan", d(2026, 2, 6), body: thomasSig, atts: ["Garage_Plan.pdf"])
    mail("G2", from: me, to: [thomas], "Umbau Garage Plan – Rückmeldung", d(2026, 2, 20), atts: ["Garage_Plan.pdf"])
    mail("U1", from: thomas, to: [me], "Kurze Frage", d(2026, 2, 10), body: thomasSig)
    mail("U2", from: me, to: [thomas], "Termin nächste Woche", d(2026, 2, 16))
    mail("T9", from: thomas, to: [me], "Weihnachtsessen", d(2026, 11, 2), body: thomasSig)
    // A newsletter-only architecture forum (never direct).
    for m in [1, 2, 3] { mail("N\(m)", from: news, to: [list], "Newsletter: Projekt Glasturm \(m)", d(2026, 2, 5 + m * 6), body: "Architektur Forum\nArchitekt Redaktion") }
    // Treuhänder: Jahresabschluss every March.
    for y in [2025, 2026] {
        mail("B\(y)", from: beat, to: [me], "Jahresabschluss \(y - 1)", d(y, 3, 15))
        mail("B\(y)", from: me, to: [beat], "AW: Jahresabschluss \(y - 1)", d(y, 3, 16))
    }
    // Notaire (FR), one signature message.
    mail("C1", from: me, to: [claire], "Vente appartement", d(2026, 7, 1))
    mail("C1", from: claire, to: [me], "RE: Vente appartement", d(2026, 7, 2), body: "Bien à vous\nMe Claire Dubois\nNotaire")
    // Role words ONLY in restricted mail: protected (known label, metadata only), unknown label, private.
    mail("H1", from: hans, to: [me], "Mandat Vollmacht Rechtsanwalt PO 9900112233", d(2026, 8, 1), body: "Hans Geheim\nRechtsanwalt", label: protected)
    mail("H1", from: me, to: [hans], "AW: Mandat Vollmacht", d(2026, 8, 2), label: protected)
    mail("H2", from: ursula, to: [me], "Rechtsanwältin Mandat", d(2026, 8, 5), body: "Ursula\nRechtsanwältin", priv: true)
    mail("H3", from: otto, to: [me], "Baueingabe Architekt", d(2026, 8, 6), body: "Otto\nArchitekt", label: FixtureCalendarService.orphanLabelId)
    // Franci: the offer I agreed.
    mail("O1", from: me, to: [franci], "Offerte Gerüstbau", d(2026, 10, 20))
    mail("O1", from: franci, to: [me], "AW: Offerte Gerüstbau – einverstanden", d(2026, 10, 21))
    mail("O2", from: franci, to: [me], "Lieferung Holz", d(2026, 10, 25))
    _ = now
    return c
}

@MainActor
func runKnowledgeTests() async {
    section("Knowledge: roles, interim matters, Ask, corrections, gate (Phase 2)")
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let now = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
    let eng = CachedLabelPolicyEngine(labels: FixtureCalendarService.labels, synced: true)
    let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
    let me = "owner@niivo-test.example"
    let corpus = makeKnowledgeCorpus(now: now)
    let store: MailStore
    do {
        store = try MailStore(url: nil, key: SymmetricKey(size: .bits256))
        store.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) }
        try store.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox), MailFolder(id: "sent", displayName: "Sent", wellKnown: .sentitems)], mailbox: "me")
        try store.upsert(messages: corpus.messages)
        for (id, b) in corpus.bodies { try store.putBody(messageId: id, body: b) }
    } catch { check(false, "knowledge store threw \(error)"); return }
    let cfg = KnowledgeEngine.Config(account: "acct-A", owners: [me], internalDomains: ["niivo-test.example"], gate: gate)
    let k = store.enableKnowledge(cfg)
    k.refresh(now: now)
    let v = k.view(.user)
    func key(_ a: String) -> String? { v.byAddress[a] }

    // Anchors (pure).
    check(StoryAnchors.ids(in: "Bestellung PO 4500123456").contains { $0.value == "4500123456" }, "anchors: PO number")
    check(StoryAnchors.ids(in: "Termin 12.03.2026").isEmpty, "anchors: a date is not a reference number")
    check(StoryAnchors.attachment(AttachmentInfo(id: "x", name: "image001.png", contentType: "image/png", size: 1)) == nil, "anchors: image001.png is generic")
    check(StoryAnchors.attachment(AttachmentInfo(id: "x", name: "Seeblick_Grundriss_v3.pdf", contentType: "", size: 1))?.value == "seeblick grundriss", "anchors: attachment normalised")
    check(StoryAnchors.stem("AW: Kurze Frage") == nil && StoryAnchors.stem("Termin nächste Woche") == nil, "anchors: generic subjects make no stem")
    check(StoryAnchors.projects(in: "Projekt Seeblick – Vorprojekt").first?.value == "seeblick", "anchors: project name")

    // Time phrases (4 languages).
    func win(_ q: String) -> String {
        guard let w = KnowledgeQuery.interpret(q, now: now, calendar: utc).window else { return "-" }
        let f = DateFormatter(); f.calendar = utc; f.timeZone = utc.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: w.start) + "/" + f.string(from: w.end)
    }
    let times: [(String, String)] = [
        ("back in Feb", "2026-02-01/2026-03-01"), ("im Februar", "2026-02-01/2026-03-01"), ("en février", "2026-02-01/2026-03-01"),
        ("a febbraio", "2026-02-01/2026-03-01"), ("in December", "2025-12-01/2026-01-01"), ("im März 2025", "2025-03-01/2025-04-01"),
        ("last summer", "2026-06-01/2026-09-01"), ("letzten Sommer", "2026-06-01/2026-09-01"), ("Q3", "2026-07-01/2026-10-01"),
        ("vor 2 Monaten", "2026-09-01/2026-10-01"), ("2 months ago", "2026-09-01/2026-10-01"), ("letztes Jahr", "2025-01-01/2026-01-01"),
        ("l'été", "2026-06-01/2026-09-01"), ("2025", "2025-01-01/2026-01-01"),
    ]
    let badTimes = times.filter { win($0.0) != $0.1 }.map { "\($0.0)→\(win($0.0))" }
    check(badTimes.isEmpty, "time phrases parse (\(times.count - badTimes.count)/\(times.count)) \(badTimes)")
    let early = KnowledgeQuery.interpret("Anfang März", now: now, calendar: utc).window
    check(early.map { $0.duration < 12 * 86_400 && utc.component(.month, from: $0.start) == 3 } ?? false, "Anfang März → the first third of March")

    // Entities and roles.
    check(key("andrea.muster@gmail.example") != nil && key("andrea.muster@gmail.example") == key("andrea.muster@muster-partner.example"),
          "one person with two addresses (same full name, one free-mail)")
    check(v.people[key("beat.zahner@zahner-treuhand.example") ?? ""]?.org == "zahner-treuhand.example" && v.orgs["gmail.example"] == nil,
          "organisations from domains, free-mail excluded")
    func asserted(_ a: String, _ r: KnowledgeRole) -> Bool { v.person(address: a)?.role(r)?.asserted == true }
    let gold: [(String, KnowledgeRole, Bool)] = [
        ("andrea.muster@muster-partner.example", .lawyer, true), ("m.gegner@kanzlei-gegner.example", .lawyer, true),
        ("giulia.rossi@studiorossi.example", .lawyer, true), ("t.keller@keller-ag.example", .architect, true),
        ("beat.zahner@zahner-treuhand.example", .accountant, true), ("c.dubois@etude-dubois.example", .notary, true),
        ("petra.vogel@muster-partner.example", .lawyer, false),
        ("hans@geheim.example", .lawyer, false),
    ]
    let wrong = gold.filter { asserted($0.0, $0.1) != $0.2 }.map { "\($0.1.id)@\($0.0.prefix(6))" }
    check(wrong.isEmpty, "persona roles (\(gold.count - wrong.count)/\(gold.count) right) \(wrong)")
    check(v.person(address: "petra.vogel@muster-partner.example")?.supportStaff == true, "the law firm's assistant is support staff, not a lawyer")

    // Privacy: restricted rows contribute no text-derived facts; private / unknown-label rows contribute nothing.
    let hans = v.person(address: "hans@geheim.example")
    check(hans != nil && (hans?.roles.isEmpty ?? false), "protected-only person: known by metadata, no role at all")
    check(v.person(address: "ursula@privat-recht.example") == nil && v.person(address: "otto@unbekannt.example") == nil,
          "private and unknown-label senders don't exist in the view")
    let allEvidence = v.people.values.flatMap { $0.roles.flatMap(\.evidence) }.compactMap(\.messageId)
    let restrictedIds = Set(corpus.messages.filter { $0.labelId != nil || $0.isPrivate }.map(\.id))
    check(!allEvidence.contains { restrictedIds.contains($0) }, "no fact cites a protected / private / unknown-label message")
    let leak = KnowledgeAsk.answer("mails from my lawyer", engine: k, now: now, calendar: utc)?.citations.contains { restrictedIds.contains($0) } ?? true
    check(!leak, "answers cite no restricted message")
    let cloudView = k.view(.ai(.cloud))
    check(cloudView.person(address: "hans@geheim.example")?.roles.isEmpty ?? true, "cloud tier: protected-only person has no role either")

    // "my X": top-1 over DE/EN/FR/IT phrasings.
    func top(_ q: String) -> String? { KnowledgeAsk.answer(q, engine: k, now: now, calendar: utc)?.person?.key }
    let andreaKey = key("andrea.muster@muster-partner.example")
    let lawyerQs = ["mails from my lawyer", "Mails von meinem Anwalt", "les mails de mon avocat", "le mail del mio avvocato", "who is my lawyer"]
    let lawyerHits = lawyerQs.filter { top($0) == andreaKey }.count
    check(lawyerHits == lawyerQs.count, "\"my lawyer\" → the right person top-1 (\(lawyerHits)/\(lawyerQs.count)); never opposing counsel or the assistant")
    check(top("ma notaire") == key("c.dubois@etude-dubois.example") && top("mein Treuhänder") == key("beat.zahner@zahner-treuhand.example")
          && top("who is my architect") == key("t.keller@keller-ag.example"), "my notary / Treuhänder / architect top-1")
    let lawyerAns = KnowledgeAsk.answer("mails from my lawyer", engine: k, now: now, calendar: utc)
    check(lawyerAns?.kind == .person && (lawyerAns?.why.contains { $0.hasPrefix("signature") } ?? false) && !(lawyerAns?.citations.isEmpty ?? true),
          "person card: why (signature) with citations")

    // Matter: "that project in Feb for that architect".
    let matterQs = ["that project in Feb for that architect", "Feb architect project", "das Projekt im Februar mit dem Architekten",
                    "le projet de février avec l'architecte", "il progetto di febbraio con l'architetto"]
    let seeblickConvs: Set<String> = ["S0", "S1", "S2", "S3", "S4", "S5"]
    var matterHits = 0
    for q in matterQs {
        guard let a = KnowledgeAsk.answer(q, engine: k, now: now, calendar: utc), a.kind == .matter, let m = a.matter else { continue }
        if m.anchor.value == "seeblick" && Set(m.threads.map(\.id)) == seeblickConvs { matterHits += 1 }
    }
    check(matterHits == matterQs.count, "Feb architect project → the right matter top-1 (\(matterHits)/\(matterQs.count))")
    if let a = KnowledgeAsk.answer("that project in Feb for that architect", engine: k, now: now, calendar: utc), let m = a.matter {
        check(!m.threads.contains { ["U1", "U2", "G1", "G2"].contains($0.id) }, "unanchored and other-project threads stay out of the matter")
        check(a.alsoInPeriod.contains { $0.id == "U1" } && a.otherMatters.contains { $0.anchor.value == "garage" }, "they're shown as 'also in that period' / other matters")
        check(m.keys.contains { $0.contains("4500123456") } && m.files.contains { $0.name.hasPrefix("Seeblick_Grundriss") }, "matter card: key ids and files")
        check(m.title == "Project Seeblick", "matter title from the project anchor")
    } else { check(false, "matter answer present") }

    // Agreement with a named person, topic as hint.
    let franci = KnowledgeAsk.answer("what did I agree with Franci about the offer", engine: k, now: now, calendar: utc)
    check(franci?.person?.key == key("franci@fornitore-bianchi.example") && franci?.threads.map(\.id) == ["O1"],
          "\"what did I agree with Franci about the offer\" → Franci, the offer thread only")

    // Honest no-answer, and ordinary searches stay ordinary.
    let none = KnowledgeAsk.answer("mails from my insurance", engine: k, now: now, calendar: utc)
    check(none?.kind == KnowledgeAnswer.Kind.none && (none?.headline.hasPrefix("No") ?? false), "no answer: says so honestly")
    check(KnowledgeAsk.answer("invoice Fabrikam", engine: k, now: now, calendar: utc) == nil, "a plain keyword search isn't hijacked")

    // Search hand-off: from/to the resolved person, no restricted rows.
    if let a = lawyerAns {
        let res = KnowledgeAsk.search(a, store: store, mailbox: "me", now: now)
        let addrs = Set(a.addresses)
        let involved = res.allSatisfy { m in ([m.from?.address ?? ""] + (m.toRecipients + m.ccRecipients).map(\.address)).contains { addrs.contains($0.lowercased()) } }
        check(res.count >= 7 && involved && !res.contains { restrictedIds.contains($0.id) }, "hand-off search: \(res.count) mails from/to the lawyer only")
    }
    let matterAns = KnowledgeAsk.answer("Feb architect project", engine: k, now: now, calendar: utc)
    if let a = matterAns {
        let res = KnowledgeAsk.search(a, store: store, mailbox: "me", now: now)
        check(Set(res.prefix(a.matter?.messageIds.count ?? 0).map(\.conversationId)) == seeblickConvs, "hand-off search: matter members first")
    }

    // Corrections (stored as facts with source = user) both ways.
    k.setRole(.lawyer, for: "andrea.muster@muster-partner.example", isRole: false, now: now)
    check(top("my lawyer") == key("giulia.rossi@studiorossi.example"), "\"Not my lawyer\" promotes the next candidate")
    k.setRole(.lawyer, for: "petra.vogel@muster-partner.example", isRole: true, now: now)
    check(top("my lawyer") == key("petra.vogel@muster-partner.example"), "\"This is my lawyer\" overrides the inferred role")
    check(k.debugPersisted().userFacts == 2, "corrections are sealed facts (\(k.debugPersisted().userFacts))")

    // Per-account isolation on one store.
    let kB = store.makeKnowledgeEngine(KnowledgeEngine.Config(account: "acct-B", owners: [me], gate: gate))
    kB.refresh(now: now)
    check(kB.userFacts().isEmpty && KnowledgeAsk.answer("my lawyer", engine: kB, now: now, calendar: utc)?.person?.key == andreaKey,
          "per account: another account sees none of these corrections")
    k.clearRole(.lawyer, for: "andrea.muster@muster-partner.example"); k.clearRole(.lawyer, for: "petra.vogel@muster-partner.example")
    check(top("my lawyer") == andreaKey && k.debugPersisted().userFacts == 0, "clearing corrections restores the inferred answer")

    // Persistence: derived rows sealed; nothing from restricted mail.
    let persisted = k.debugPersistedRoles()
    check(persisted.contains { $0.hasSuffix("|lawyer") } && !persisted.contains { $0.hasPrefix("hans@") }, "derived role facts persisted, none for the protected-only person")
    let sizes = store.debugKnowledgePayloadSizes()
    check(!sizes.isEmpty && sizes.allSatisfy { $0 % 512 == 28 }, "sealed payloads (\(Set(sizes).count) size classes)")

    // Relabel: the gate is re-checked at read time.
    if var m = corpus.messages.first(where: { $0.from?.address == "c.dubois@etude-dubois.example" }) {
        m.labelId = FixtureCalendarService.labels[3].id
        try? store.upsert(message: m)
        k.refresh(now: now)
        check(k.view(.user).person(address: "c.dubois@etude-dubois.example")?.role(.notary) == nil, "relabelled to protected → the notary fact disappears")
    }
    let diag = KnowledgeAsk.diagnostic(k)
    check(diag.hasPrefix("[Knowledge] people=") && diag.contains("matters=") && !diag.contains("@"), "diagnostic is counts only")
}
