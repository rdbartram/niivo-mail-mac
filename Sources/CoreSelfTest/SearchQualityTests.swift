import Foundation
import CryptoKit
import CalendarCore
import MailCore
import TrustCore

// SEARCHQ: pure logic behind natural-mode search (variants, lexicon, understanding, fusion, body text) and its
// privacy rules (protected rows never match on content, AI metadata callers only on visible words). Synthetic data.

@MainActor
func runSearchQualityTests() async {
    section("Search quality: variants, lexicon, understanding, fusion")
    check(BlindIndex.tokenize("Straße") == ["strasse"] && SearchText.variants("Bahnhofstraße") == ["bahnhofstrasse"], "ß folds to ss in the tokenizer (no extra variant needed)")
    check(SearchText.variants("Aenderung").contains("anderung") && SearchText.variants("Zuercher").contains("zurcher"), "digraph → Umlaut (folded) variants")
    check(SearchText.variants("Müller").contains("mueller") && SearchText.variants("Müller").first == "muller", "Umlaut → digraph variant, folded form first")
    check(SearchText.editDistance("rechnug", "rechnung") == 1 && SearchText.editDistance("wartungsvertarg", "wartungsvertrag") == 1
          && SearchText.editDistance("abc", "xyz", limit: 1) == 2, "edit distance (transposition = 1, early exit above limit)")
    check(SearchText.closeMatch("zahlungserinnerung", "zahlungserinn") && SearchText.closeMatch("serverumzug", "serverumzg")
          && !SearchText.closeMatch("rechtsdienst", "rechnug") && !SearchText.closeMatch("bus", "bud"), "typo / truncation match, short words not corrected")
    check(Set(SearchLexicon.synonyms(of: "invoice")).isSuperset(of: ["rechnung", "facture", "fattura"]) && !SearchLexicon.synonyms(of: "invoice").contains("invoice"),
          "lexicon: invoice ↔ Rechnung / facture / fattura")
    check(SearchLexicon.heads(of: "serverumzug") == ["umzug"] && SearchLexicon.heads(of: "mietvertrag") == ["vertrag"] && SearchLexicon.heads(of: "vertrag").isEmpty,
          "compound heads (only for real compounds)")

    let now = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!   // a Thursday
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Zurich")!
    let nq = NaturalQuery.interpret("what did Anna send about the audit", prefixLast: false, now: now, calendar: cal)
    check(nq.groups.map(\.original) == ["anna", "audit"] && nq.senderWords == ["anna"] && nq.groups[1].alternatives.contains { $0.term == "revision" },
          "understanding: stopwords dropped, sender hint, audit ↔ Revision (\(nq.groups.map(\.original)))")
    let lw = NaturalQuery.interpret("last week's offer", prefixLast: false, now: now, calendar: cal)
    check(lw.groups.map(\.original) == ["offer"] && lw.after != nil && lw.before != nil && lw.before! <= now && now.timeIntervalSince(lw.after!) < 12 * 86_400,
          "understanding: 'last week' → previous calendar week, not a word")
    let pdf = NaturalQuery.interpret("the PDF contract", prefixLast: false, now: now)
    check(pdf.wantsAttachment && pdf.groups.first { $0.original == "pdf" }?.optional == true && pdf.groups.contains { $0.original == "contract" && !$0.optional },
          "understanding: 'PDF' is an attachment hint + optional word")
    check(NaturalQuery.interpret("invoice", prefixLast: false, expand: false).groups.first?.alternatives.count == 1, "expansions off → the word only")

    let w = SearchEngine.NaturalWeights()
    check(SearchFusion.keywordScore(bm25: 5, matched: 2, required: 2) > SearchFusion.keywordScore(bm25: 9, matched: 1, required: 2),
          "fusion: full coverage beats a higher-tf partial match")
    check(SearchFusion.rrf([(1, 1), (nil, 1)]) > SearchFusion.rrf([(2, 1), (nil, 1)]) && SearchFusion.rrf([(nil, 1)]) == 0, "rrf: rank order, missing lists add nothing")
    check(SearchFusion.natural(keyword: 1, semantic: nil, sender: false, attachment: false, phrase: false, ageDays: 200, w: w)
          > SearchFusion.natural(keyword: 0.6, semantic: nil, sender: false, attachment: false, phrase: false, ageDays: 0, w: w),
          "fusion: recency only breaks near-ties, it can't lift a weak match over a strong one")
    check(SearchFusion.natural(keyword: 0.5, semantic: 0.4, sender: false, attachment: false, phrase: false, ageDays: 0, w: w)
          == SearchFusion.natural(keyword: 0.5, semantic: nil, sender: false, attachment: false, phrase: false, ageDays: 0, w: w),
          "fusion: semantic below its floor adds nothing")
    let body = SearchText.indexableBody("<html><style>p{x}</style><p>Kündigungsfrist&nbsp;sechs Monate</p><p>-----Original Message-----</p><p>alte Mail</p></html>", isHTML: true)
    check(body.contains("Kündigungsfrist sechs Monate") && !body.contains("alte Mail") && !body.contains("p{x}"), "body text: markup, entities and quoted history stripped")
    var nat = SearchQuery.natural(raw: "Rechnung von Fabrikam", ai: AISearchQuery(terms: ["invoice", "Rechnung"], from: "Fabrikam", hasAttachments: true, fromAI: true))
    check(nat.words.filter { $0.lowercased() == "rechnung" }.count == 1 && nat.hintWords == ["invoice"] && nat.hasAttachment == true && nat.from.isEmpty,
          "AI parse: new keywords become optional hints (no duplicates), flags merge; sender stays a word, not a filter")
    var hinted = NaturalQuery.interpret("Rechnung", prefixLast: false); hinted.addHints(["invoice", "Zahlung"], expand: true)
    check(hinted.groups.count == 2 && hinted.groups[1].original == "zahlung" && hinted.groups[1].optional,
          "hints: words already covered by the user's concepts are skipped; new ones are optional")
    nat = SearchQuery.natural(raw: "x", ai: .plain("x"))
    check(nat.words == ["x"] && !nat.prefixLast, "plain fallback: the user's words")

    section("Search quality: natural mode end-to-end + privacy")
    do {
        let s = try MailStore(url: nil, key: SymmetricKey(size: .bits256))
        let eng = mailEngine()
        let L = FixtureCalendarService.labels
        s.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) }
        try s.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox)], mailbox: "me")
        let base = Date().addingTimeInterval(-5 * 86_400)
        func mk(_ id: String, _ subject: String, _ from: String, _ preview: String, day: Double = 0, label: String? = nil, att: Bool = false) -> MailMessage {
            MailMessage(id: id, folderId: "inbox", conversationId: id, subject: subject, from: EmailAddress(name: from, address: from.lowercased().replacingOccurrences(of: " ", with: ".") + "@fabrikam-test.example"),
                        received: base.addingTimeInterval(day * 86_400), preview: preview, hasAttachments: att, labelId: label)
        }
        try s.upsert(messages: [
            mk("q1", "Rechnung RE-1 Serverschränke", "Anna Meier", "Anbei die Rechnung", day: 1, att: true),
            mk("q2", "Lieferverzögerung", "Peter Muster", "Lieferung später", day: 2),
            mk("q3", "Mietvertrag Bahnhofstraße", "Nina Graf", "Nachtrag zur Miete", day: 3),
            mk("q4", "Wochenangebote", "Shop", "Rabatte", day: 4),
            mk("p1", "Rechnung Fabrikam geheim", "Legal Desk", "Rechnung Vergleich", day: 4, label: L[3].id),   // protected: content never indexed
            mk("c1", "Pricing invoice draft", "Anna Meier", "invoice adjustments hidden", day: 4, label: L[2].id),  // confidential
        ])
        let e = SearchEngine(store: s)
        var o = SearchEngine.Options(mailbox: "me"); o.match = .natural; o.semantic = false
        let inv = e.search("invoice from Fabrikam ", o)
        check(Set(inv.hits.prefix(2).map(\.id)) == ["q1", "c1"], "natural: 'invoice from Fabrikam' ranks the German Rechnung with the English invoice (\(inv.hits.map(\.id)))")
        check(e.search("Rechnug ", o).hits.first?.id == "q1" && e.search("Bahnhofstrasse ", o).hits.first?.id == "q3", "natural: typo and ß/ss")
        check(!e.search("Rechnung Vergleich geheim ", o).hits.contains { $0.id == "p1" } && !e.search("Rechnug ", o).hits.contains { $0.id == "p1" },
              "natural: a protected row never matches on its subject/preview (also not via typo recovery)")
        var strict = SearchEngine.Options(mailbox: "me"); strict.semantic = false
        check(e.search("invoice from Fabrikam ", strict).hits.isEmpty, "default (.all) unchanged: every word required")
        let meta: SearchCaller = .ai { m, mb in
            let p = AIAccessPolicy(engine: eng, aiMaxPriority: 2)
            guard let r = p.redactForAI(m, mailbox: mb) else { return nil }
            return (r, p.level(for: m, mailbox: mb) == .full ? .full : .metadata)
        }
        var oa = o; oa.caller = meta
        let ai = e.search("adjustments hidden ", oa)
        check(!ai.hits.contains { $0.id == "c1" } && !e.search("geheim ", oa).hits.contains { $0.id == "p1" },
              "natural, AI metadata caller: hidden preview words and protected subjects never match")
        check(e.search("pricing ", oa).hits.contains { $0.id == "c1" && $0.exposure == .metadata && $0.message.preview == nil },
              "natural, AI metadata caller: still matches on the visible subject, returned redacted")
        // Cached body joins the index (v3) — but only where offline details are allowed.
        var opened = mk("q2", "Lieferverzögerung", "Peter Muster", "Lieferung später", day: 2)
        opened.body = "<html><head><style>.fancyclass{color:red}</style></head><body><p>Neuer Liefertermin KW 47, Kündigungsfrist unverändert</p></body></html>"
        opened.bodyIsHTML = true
        var prot = mk("p1", "Rechnung Fabrikam geheim", "Legal Desk", "Rechnung Vergleich", day: 4, label: L[3].id); prot.body = "Kündigungsfrist geheim"
        try s.upsert(messages: [opened, prot])
        let kf = e.search("Kündigungsfrist ", o)
        check(kf.hits.map(\.id) == ["q2"], "cached body is searchable; a protected body never is (\(kf.hits.map(\.id)))")
        try s.upsert(message: mk("q2", "Lieferverzögerung", "Peter Muster", "Lieferung später", day: 2))   // header-only delta
        check(e.search("Kündigungsfrist ", o).hits.map(\.id) == ["q2"] && e.search("fancyclass ", o).hits.isEmpty,
              "a header-only delta (no HTML flag) keeps the cached body's terms, never its markup")
    } catch { check(false, "natural search threw \(error)") }
}
