import Foundation

// Deterministic, on-device query understanding for natural-language search (no model, no network):
// spelling variants (ß/ss, Umlaut digraphs), a DE/EN/FR/IT business lexicon, stopwords, time phrases, attachment
// and sender hints, and a small edit distance for typo recovery. Pure functions, covered by CoreSelfTest.

public enum SearchText {
    /// Folded tokens a raw query word may be written as in mail: as typed and Umlaut ↔ digraph (ae/oe/ue). ß needs
    /// no variant: the tokenizer's case folding already maps it to "ss".
    public static func variants(_ raw: String) -> [String] {
        var forms: [String] = [raw]
        let low = raw.lowercased()
        if low.contains(where: { "äöü".contains($0) }) {
            forms.append(low.replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe").replacingOccurrences(of: "ü", with: "ue"))
        }
        // Digraph → Umlaut (folded to the plain vowel by the tokenizer): "Aenderung" → "anderung", "Zuercher" → "zurcher".
        if low.count > 3, low.contains("ae") || low.contains("oe") || low.contains("ue") {
            forms.append(low.replacingOccurrences(of: "ae", with: "a").replacingOccurrences(of: "oe", with: "o").replacingOccurrences(of: "ue", with: "u"))
        }
        var seen = Set<String>(), out: [String] = []
        for f in forms { for t in BlindIndex.tokenize(f) where seen.insert(t).inserted { out.append(t) } }
        return out
    }

    /// Optimal-string-alignment distance (adjacent transposition = 1), early exit above `limit`.
    public static func editDistance(_ a: String, _ b: String, limit: Int = 2) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var pp = [Int](repeating: 0, count: y.count + 1), prev = Array(0...y.count), cur = prev
        for i in 1...x.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { cur[j] = min(cur[j], pp[j - 2] + 1) }
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            pp = prev; prev = cur
        }
        return prev[y.count]
    }

    /// Typo recovery match: within the edit budget, or `word` (≥ 4 letters) is the start of `token`.
    public static func closeMatch(_ token: String, _ word: String) -> Bool {
        if word.count >= 4, token.count > word.count, token.hasPrefix(word) { return true }
        let budget = typoBudget(word)
        return budget > 0 && abs(token.count - word.count) <= budget && editDistance(token, word, limit: budget) <= budget
    }

    /// Typo budget for a word of this length (short words aren't corrected: too many neighbours).
    public static func typoBudget(_ t: String) -> Int { t.count >= 8 ? 2 : t.count >= 5 ? 1 : 0 }

    /// Body characters considered for the index (after stripping markup and quoted history).
    public static let bodyIndexChars = 4_000

    /// Plain text of a body for indexing: tags/styles/scripts removed, entities decoded (common ones), the quoted
    /// reply history cut ("-----Original Message-----", "Von:", "From:" header blocks, "> " lines), bounded.
    public static func indexableBody(_ body: String, isHTML: Bool, limit: Int = bodyIndexChars) -> String {
        var s = String(body.prefix(limit * 6))
        // The flag comes from whichever header row is being indexed (a delta may not carry it): sniff markup too.
        if isHTML || s.range(of: "<(html|body|div|p|br|span|table|style|head)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            for tag in ["style", "script", "head"] {
                s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
            }
            s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</tr>", with: "\n", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            for (e, r) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                           ("&auml;", "ä"), ("&ouml;", "ö"), ("&uuml;", "ü"), ("&Auml;", "Ä"), ("&Ouml;", "Ö"), ("&Uuml;", "Ü"), ("&szlig;", "ß")] {
                s = s.replacingOccurrences(of: e, with: r)
            }
        }
        var out: [Substring] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-----Original") || t.hasPrefix("-----Ursprüngliche") || t.hasPrefix("________________") { break }
            if (t.hasPrefix("From:") || t.hasPrefix("Von:") || t.hasPrefix("De :") || t.hasPrefix("Da:")) && out.count > 2 { break }
            if t.hasPrefix(">") { continue }
            out.append(line)
        }
        return String(out.joined(separator: "\n").prefix(limit))
    }

    /// Folded, whitespace-collapsed text for phrase matching.
    public static func phraseForm(_ s: String) -> String { BlindIndex.tokenize(s).joined(separator: " ") }
}

public enum SearchLexicon {
    /// Function words + question scaffolding (EN/DE/FR/IT), folded. Never scored in natural mode.
    public static let stopwords: Set<String> = Set("""
        the an and or of to in on at for with from by about what which who whom when where why how did does do done \
        is are was were be been has have had me my mine my we our you your it its this that these those there here \
        send sent say said write wrote tell told show find get got any some all thing things stuff something mail mails \
        email emails message messages please can could would should will just also again re aw fw fwd wg \
        der die das den dem des ein eine einen einem einer und oder von vom zu zum zur mit im am an auf fur uber \
        was wer wem wen wann wo wie warum hat haben hatte ist sind war waren mir mich ich du dir wir uns ihr sie es \
        bitte noch schon nur auch etwas sache geschickt gesendet geschrieben gesagt zeige finde \
        le la les un une et ou du au aux pour par avec sur dans que qui quoi est sont ai mon ma mes ce cette \
        il lo gli di da del della per con su che chi cosa sono mio mia questo questa
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// Business vocabulary groups across DE/EN/FR/IT (folded). A word expands to the other members of its groups.
    /// Generic on purpose (not tuned to any one mailbox).
    public static let groups: [[String]] = [
        ["invoice", "invoices", "rechnung", "rechnungen", "facture", "factures", "fattura", "fatture", "bill", "billing", "faktura"],
        ["offer", "offers", "quote", "quotes", "quotation", "proposal", "offerte", "offerten", "angebot", "angebote", "offre", "offres", "offerta"],
        ["contract", "contracts", "agreement", "vertrag", "vertrage", "vereinbarung", "contrat", "contratto"],
        ["audit", "audits", "auditor", "auditors", "revision", "revisor", "revisoren", "prufung", "revisione", "verifica"],
        ["meeting", "meetings", "sitzung", "besprechung", "reunion", "riunione", "seance"],
        ["board", "verwaltungsrat", "vr", "conseil", "cda"],
        ["agenda", "traktanden", "traktandenliste", "tagesordnung", "ordine"],
        ["vacation", "vacations", "holiday", "holidays", "leave", "ferien", "urlaub", "abwesenheit", "abwesend", "absence", "absent", "vacances", "conge", "vacanze", "ooo"],
        ["move", "moving", "relocation", "relocate", "migration", "migrate", "umzug", "zugeln", "demenagement", "trasloco", "migrazione"],
        ["datacenter", "datacentre", "rechenzentrum", "rz", "colocation", "colo"],
        ["delivery", "deliveries", "lieferung", "lieferungen", "livraison", "consegna", "shipment"],
        ["delay", "delayed", "late", "verzogerung", "verspatung", "verzogert", "retard", "ritardo"],
        ["application", "applications", "applicant", "bewerbung", "bewerbungen", "candidature", "candidatura"],
        ["job", "position", "vacancy", "stelle", "stelleninserat", "poste", "posizione"],
        ["cv", "resume", "lebenslauf", "curriculum"],
        ["expenses", "expense", "spesen", "spesenabrechnung", "frais", "spese"],
        ["vat", "mwst", "mehrwertsteuer", "tva", "iva"],
        ["question", "questions", "query", "inquiry", "frage", "fragen", "ruckfrage", "domanda"],
        ["warning", "warnung", "alert", "achtung", "avertissement", "avviso"],
        ["security", "sicherheit", "securite", "sicurezza"],
        ["incident", "vorfall", "sicherheitsvorfall", "incidente"],
        ["account", "accounts", "konto", "benutzerkonto", "compte"],
        ["blocked", "locked", "disabled", "gesperrt", "sperren", "bloque", "bloccato"],
        ["compromised", "hacked", "kompromittiert", "gehackt", "compromis", "compromesso"],
        ["plan", "planning", "schedule", "planung", "planification", "pianificazione"],
        ["report", "reports", "bericht", "rapport", "rapporto"],
        ["minutes", "protokoll", "verbale"],
        ["reminder", "erinnerung", "mahnung", "zahlungserinnerung", "rappel", "sollecito", "promemoria"],
        ["payment", "payments", "zahlung", "paiement", "pagamento"],
        ["network", "netzwerk", "reseau", "rete"],
        ["problem", "problems", "issue", "issues", "probleme", "problemi", "storung"],
        ["documents", "document", "docs", "unterlagen", "dokumente", "documenti"],
        ["licence", "licences", "license", "licenses", "lizenz", "lizenzen", "licenza", "licenze"],
        ["maintenance", "wartung", "entretien", "manutenzione"],
        ["rent", "rental", "miete", "loyer", "affitto"],
        ["lease", "tenancy", "mietvertrag"],
        ["change", "changes", "amendment", "anderung", "anderungen", "nachtrag", "modification", "modifica"],
        ["open", "outstanding", "offen", "offene", "pendent", "ouvert", "aperto"],
        ["points", "items", "punkte", "pendenzen"],
        ["signed", "signature", "unterschrift", "unterschrieben", "unterzeichnet", "signe", "firmato", "countersigned"],
        ["order", "orders", "purchase", "bestellung", "commande", "ordine"],
        ["budget", "budgets", "budjet", "preventivo"],
        ["server", "servers", "serveur", "serveurs"],
        ["kickoff", "kick", "start", "launch", "auftakt"],
        ["password", "passwort", "kennwort", "mot", "parola"],
        ["january", "januar", "janvier", "gennaio"], ["february", "februar", "fevrier", "febbraio"],
        ["march", "marz", "mars", "marzo"], ["april", "avril", "aprile"], ["may", "mai", "maggio"],
        ["june", "juni", "juin", "giugno"], ["july", "juli", "juillet", "luglio"], ["august", "aout", "agosto"],
        ["september", "septembre", "settembre"], ["october", "oktober", "octobre", "ottobre"],
        ["november", "novembre"], ["december", "dezember", "decembre", "dicembre"],
    ]

    static let index: [String: [String]] = {
        var d: [String: [String]] = [:]
        for g in groups { for w in g { d[w, default: []] += g.filter { $0 != w } } }
        return d.mapValues { Array(Set($0)).sorted() }
    }()

    /// Other members of the word's groups (folded), never the word itself.
    public static func synonyms(of t: String) -> [String] { index[t] ?? [] }

    /// German compound heads indexed as their own term ("serverumzug" → "umzug", "mietvertrag" → "vertrag").
    /// Heads come from the lexicon (≥ 5 letters, modifier ≥ 3 letters), plus a few frequent business heads.
    public static let compoundHeads: [String] = [
        "abrechnung", "bericht", "vertrag", "sitzung", "erinnerung", "umzug", "rechnung", "offerte", "angebot", "planung",
        "protokoll", "konto", "liste", "termin", "anfrage", "auftrag", "bestellung", "lieferung", "vorfall", "prufung",
        "wartung", "zahlung", "anderung", "verzogerung", "bewerbung", "unterlagen", "lizenzen", "spesen", "revision",
    ].sorted { $0.count > $1.count }

    /// Compound heads of one folded token (empty when the token isn't a compound of a known head).
    public static func heads(of t: String) -> [String] {
        guard t.count >= 8 else { return [] }
        for h in compoundHeads where t.count >= h.count + 3 && t.hasSuffix(h) {
            // "zahlungserinnerung" → "erinnerung"; strip a linking -s- / -n- only for the modifier, keep the head.
            return [h]
        }
        return []
    }

    static let attachmentWords: Set<String> = ["pdf", "attachment", "attachments", "attached", "anhang", "anhange", "beilage",
                                               "angehangt", "allegato", "allegati", "jointe", "docx", "xlsx", "excel", "pptx", "datei", "file"]
    static let fileTypeWords: Set<String> = ["pdf", "docx", "xlsx", "pptx", "excel", "word"]
}

/// One query concept: alternatives (folded tokens) any of which satisfies it.
public struct SearchTermGroup: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case word, variant, synonym }
    public var original: String
    public var alternatives: [(term: String, kind: Kind)]
    /// The last word while typing: matched as a prefix (p: hash + in-memory verify).
    public var prefix: Bool
    /// Optional groups add score but don't count against coverage (file-type words, weak hints).
    public var optional: Bool
    public static func == (a: Self, b: Self) -> Bool { a.original == b.original && a.prefix == b.prefix && a.optional == b.optional && a.alternatives.map(\.term) == b.alternatives.map(\.term) }
    public func hash(into h: inout Hasher) { h.combine(original); h.combine(prefix) }
    public static func weight(_ k: Kind) -> Double { switch k { case .word, .variant: 1.0; case .synonym: 0.6 } }
}

/// Deterministic interpretation of a free-text query (natural mode).
public struct NaturalQuery: Sendable, Hashable {
    public var groups: [SearchTermGroup] = []
    public var after: Date?
    public var before: Date?
    /// Words that hinted at an attachment ("pdf", "Anhang", …): a soft preference, not a filter.
    public var wantsAttachment = false
    /// Words that name the sender ("from X", "what did X send", "von X"): boost, not filter.
    public var senderWords: [String] = []
    public var phrases: [String] = []
    /// Words that were only scaffolding (stopwords / time phrase), kept for the UI.
    public var dropped: [String] = []

    /// One concept: the word, its spelling variants, lexicon synonyms and compound-head synonyms (≤ 16).
    static func group(raw: String, token t: String, expand: Bool, optional: Bool = false) -> SearchTermGroup? {
        var alts: [(String, SearchTermGroup.Kind)] = [(t, .word)]
        var seen: Set<String> = [t]
        if BlindIndex.tokenize(raw).count == 1 { for v in SearchText.variants(raw) where seen.insert(v).inserted { alts.append((v, .variant)) } }
        if expand {
            for base in alts.map(\.0) { for s in SearchLexicon.synonyms(of: base) where seen.insert(s).inserted { alts.append((s, .synonym)) } }
            for h in SearchLexicon.heads(of: t) { for s in [h] + SearchLexicon.synonyms(of: h) where seen.insert(s).inserted { alts.append((s, .synonym)) } }
        }
        return SearchTermGroup(original: t, alternatives: Array(alts.prefix(16)), prefix: false, optional: optional)
    }

    /// Optional concepts for AI-added words not already covered by the user's own words.
    public mutating func addHints(_ words: [String], expand: Bool) {
        var covered = Set(groups.flatMap { $0.alternatives.map(\.term) })
        for w in words {
            for t in BlindIndex.tokenize(w) where !SearchLexicon.stopwords.contains(t) && !covered.contains(t) {
                guard let g = Self.group(raw: w, token: t, expand: expand, optional: true) else { continue }
                covered.formUnion(g.alternatives.map(\.term))
                groups.append(g)
            }
        }
    }

    public static func interpret(_ raw: String, prefixLast: Bool, expand: Bool = true, now: Date = Date(), calendar: Calendar = .current) -> NaturalQuery {
        var nq = NaturalQuery()
        // Quoted phrases.
        let parts = raw.split(separator: "\"", omittingEmptySubsequences: false)
        for (i, s) in parts.enumerated() where i % 2 == 1 {
            let f = SearchText.phraseForm(String(s)); if f.contains(" ") { nq.phrases.append(f) }
        }
        // Raw words (before folding: variants need the original spelling).
        let rawWords = raw.split(whereSeparator: { $0.isWhitespace || $0 == "\"" }).map { String($0) }
        var words: [(raw: String, tok: String)] = []
        for w in rawWords { for t in BlindIndex.tokenize(w) { words.append((w, t)) } }
        var used = Array(repeating: false, count: words.count)
        let toks = words.map(\.tok)

        // Time phrases.
        var cal = calendar; cal.firstWeekday = 2
        let today = cal.startOfDay(for: now)
        let week = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let month = cal.dateInterval(of: .month, for: now)?.start ?? today
        func mark(_ i: Int, _ n: Int) { for k in i..<min(i + n, used.count) { used[k] = true } }
        for i in toks.indices {
            let a = toks[i], b = i + 1 < toks.count ? toks[i + 1] : ""
            let lastW = ["last", "letzte", "letzter", "letzten", "vergangene", "vergangenen", "previous", "scorsa", "scorso", "derniere", "dernier"]
            let thisW = ["this", "diese", "dieser", "diesen", "cette", "ce", "questa", "questo"]
            let weekW = ["week", "woche", "semaine", "settimana"], monthW = ["month", "monat", "mois", "mese"]
            if ["today", "heute", "aujourd", "oggi"].contains(a) { nq.after = today; mark(i, 1) }
            else if ["yesterday", "gestern", "ieri"].contains(a) { nq.after = cal.date(byAdding: .day, value: -1, to: today); nq.before = today; mark(i, 1) }
            else if lastW.contains(a) && weekW.contains(b) { nq.after = cal.date(byAdding: .day, value: -7, to: week); nq.before = week; mark(i, 2) }
            else if weekW.contains(a) && lastW.contains(b) { nq.after = cal.date(byAdding: .day, value: -7, to: week); nq.before = week; mark(i, 2) }
            else if thisW.contains(a) && weekW.contains(b) { nq.after = week; mark(i, 2) }
            else if lastW.contains(a) && monthW.contains(b) { nq.after = cal.date(byAdding: .month, value: -1, to: month); nq.before = month; mark(i, 2) }
            else if monthW.contains(a) && lastW.contains(b) { nq.after = cal.date(byAdding: .month, value: -1, to: month); nq.before = month; mark(i, 2) }
            else if thisW.contains(a) && monthW.contains(b) { nq.after = month; mark(i, 2) }
            else if ["recently", "recent", "kurzlich", "neulich", "lately"].contains(a) { nq.after = cal.date(byAdding: .day, value: -14, to: today); mark(i, 1) }
        }
        // Sender hints: "from X", "von X", "what did X send/say/write", "X sent".
        let fromW: Set<String> = ["from", "von", "vom", "de", "da", "by"]
        let verbW: Set<String> = ["send", "sent", "say", "said", "write", "wrote", "schicken", "geschickt", "geschrieben", "share", "shared"]
        for i in toks.indices where !used[i] {
            if fromW.contains(toks[i]), i + 1 < toks.count, !SearchLexicon.stopwords.contains(toks[i + 1]) { nq.senderWords.append(toks[i + 1]) }
            if ["did", "has", "hat"].contains(toks[i]) {
                var j = i + 1, names: [String] = []
                while j < toks.count, !verbW.contains(toks[j]), names.count < 3 { names.append(toks[j]); j += 1 }
                if j < toks.count, !names.isEmpty { nq.senderWords += names.filter { !SearchLexicon.stopwords.contains($0) } }
            }
        }
        // Content groups.
        for (i, w) in words.enumerated() where !used[i] {
            let t = w.tok
            if SearchLexicon.attachmentWords.contains(t) {
                nq.wantsAttachment = true
                if SearchLexicon.fileTypeWords.contains(t) { nq.groups.append(SearchTermGroup(original: t, alternatives: [(t, .word)], prefix: false, optional: true)) }
                else { nq.dropped.append(t) }
                continue
            }
            if SearchLexicon.stopwords.contains(t) && !(prefixLast && i == words.count - 1 && words.count == 1) { nq.dropped.append(t); continue }
            let isLast = i == words.count - 1
            if var g = group(raw: w.raw, token: t, expand: expand) {
                g.prefix = prefixLast && isLast && t.count >= BlindIndex.prefixLength
                nq.groups.append(g)
            }
        }
        // Everything was scaffolding ("what did Anna send") → the sender words are the content.
        if nq.groups.allSatisfy(\.optional), !nq.senderWords.isEmpty {
            for s in nq.senderWords { nq.groups.append(SearchTermGroup(original: s, alternatives: [(s, .word)], prefix: false, optional: false)) }
        }
        if let a = nq.after, let b = nq.before, a >= b { nq.before = nil }
        return nq
    }
}

/// Score fusion for natural mode (pure; CoreSelfTest pins the ordering rules).
public enum SearchFusion {
    public static let rrfK = 60.0
    /// Weighted reciprocal rank fusion: Σ wᵢ / (k + rankᵢ) over the lists a document appears in (ranks 1-based).
    public static func rrf(_ ranks: [(rank: Int?, weight: Double)], k: Double = rrfK) -> Double {
        ranks.reduce(0) { acc, r in r.rank.map { acc + r.weight / (k + Double($0)) } ?? acc }
    }
    /// Coverage-weighted keyword score: documents matching more of the query's concepts outrank higher-tf partials.
    public static func keywordScore(bm25: Double, matched: Int, required: Int) -> Double {
        guard required > 0 else { return bm25 }
        let c = Double(min(matched, required)) / Double(required)
        return bm25 * c * c * (matched >= required ? 2 : 1)
    }
    /// Natural-mode score: normalised keyword score + scaled semantic cosine + hint bonuses + recency.
    public static func natural(keyword: Double, semantic: Float?, sender: Bool, attachment: Bool, phrase: Bool, ageDays: Double,
                               w: SearchEngine.NaturalWeights) -> Double {
        var s = keyword
        if let c = semantic, c > w.semanticFloor { s += w.semantic * Double((c - w.semanticFloor) / (1 - w.semanticFloor)) }
        if sender { s += w.sender }
        if attachment { s += w.attachment }
        if phrase { s += w.phrase }
        return s + w.recency * recency(ageDays: ageDays)
    }

    /// Exponential recency prior in [0, 1] (half-life `halfLifeDays`).
    public static func recency(ageDays: Double, halfLifeDays: Double = 30) -> Double { exp(-max(0, ageDays) * log(2) / halfLifeDays) }
}

extension SearchQuery {
    /// SEARCHQ: query for natural-mode retrieval behind Ask / ⌥↩. The user's own words drive matching (the
    /// deterministic understanding handles stopwords, dates, hints); an AI parse — which only ever saw the user's
    /// words, never mail — adds its keywords (often translations) and its explicit dates / attachment flag.
    /// The AI sender guess stays a word (scored on sender fields), not a hard filter.
    public static func natural(raw: String, ai: AISearchQuery?, now: Date = Date()) -> SearchQuery {
        var q = SearchQuery.parse(raw.trimmingCharacters(in: .whitespaces) + " ", now: now)
        guard let ai, ai.fromAI else { return q }
        var have = Set(q.words.flatMap { BlindIndex.tokenize($0) })
        for t in ai.terms + [ai.from].compactMap({ $0 }) {
            for w in t.split(separator: " ").map(String.init) where BlindIndex.tokenize(w).contains(where: { have.insert($0).inserted }) {
                q.hintWords.append(w)
            }
        }
        if q.after == nil { q.after = ai.after }
        if q.before == nil { q.before = ai.before }
        if ai.hasAttachments == true, q.hasAttachment == nil { q.hasAttachment = true }
        q.prefixLast = false
        return q
    }
}
