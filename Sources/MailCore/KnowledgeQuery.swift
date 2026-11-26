import Foundation

// PEOPLE: query understanding and answering for the knowledge layer (docs/INBOX-INTELLIGENCE-PLAN.md §6.3–6.4).
// Deterministic, DE/EN/FR/IT. "mails from my lawyer" → role + possessive → person (ranked by MY relationship with
// them: I write to them, they write to me directly; Cc-only people such as opposing counsel never qualify);
// "that project in Feb for that architect" → role → person, Feb → the most recent past February (soft ±25 %),
// "that project" → an INTERIM MATTER: their conversations in the window grouped by anchors (StoryAnchors), the
// largest anchored group wins, unanchored conversations are "also in that period". Never similarity alone.
// The answer is a card (person or matter, key threads, files, dates, why, citations = message ids) plus the
// search hand-off (per-address from:/to: queries with the soft window and the leftover words as hints).
// Everything in an answer comes from `engine.view(tier)` and is re-gated per message at read time.

public struct KnowledgeFrame: Sendable, Hashable {
    public enum Intent: String, Sendable, Hashable { case mails, details, files, who, agreement }
    public var roles: [KnowledgeRole] = []
    public var possessive = false
    /// "that / jenes / ce / quel" before a noun: resolve from context, not as a keyword.
    public var vague = false
    /// A project noun ("project / Projekt / projet / progetto / Fall / dossier …") is asked about.
    public var matter = false
    /// Explicit anchors in the question ("PO 4500123456", "Projekt Seeblick").
    public var anchors: [StoryAnchor] = []
    /// Hard window (as said) and the soft one (±25 %, used for matching).
    public var window: DateInterval?
    public var softWindow: DateInterval?
    public var intent: Intent = .mails
    /// Words left over: person names (resolved against the gazetteer) or topic hints.
    public var rest: [String] = []
    public var isKnowledge: Bool { !roles.isEmpty || matter || intent == .agreement || intent == .who || !anchors.isEmpty && intent == .details }
}

public struct KnowledgeThread: Sendable, Hashable, Identifiable {
    public var id: String
    /// Empty when the subject isn't visible to the caller (the row still counts, without text).
    public var subject: String
    public var first: Date
    public var last: Date
    public var count: Int
    public var messageIds: [String]
    public var latestId: String { messageIds.last ?? id }
}

public struct KnowledgeFile: Sendable, Hashable, Identifiable {
    public var name: String
    public var messageId: String
    public var attachmentId: String
    public var date: Date
    public var id: String { messageId + "|" + attachmentId }
}

public struct KnowledgeMatter: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var anchor: StoryAnchor
    /// Other anchors of the members (key IDs, project names, files), visible text only.
    public var keys: [String]
    public var threads: [KnowledgeThread]
    public var files: [KnowledgeFile]
    public var people: [String]
    public var first: Date
    public var last: Date
    public var messageIds: [String] { threads.flatMap(\.messageIds) }
}

public struct KnowledgeCandidate: Sendable, Hashable, Identifiable {
    public var key: String
    public var name: String
    public var score: Double
    public var userAsserted: Bool
    public var id: String { key }
}

public struct KnowledgeAnswer: Sendable {
    public enum Kind: Sendable, Hashable { case person, matter, none }
    public var kind: Kind
    public var frame: KnowledgeFrame
    public var headline: String
    public var why: [String] = []
    public var person: KnowledgePerson?
    /// Disambiguation chips (close runners-up), never a silent guess.
    public var candidates: [KnowledgeCandidate] = []
    public var matter: KnowledgeMatter?
    public var otherMatters: [KnowledgeMatter] = []
    public var threads: [KnowledgeThread] = []
    public var alsoInPeriod: [KnowledgeThread] = []
    public var files: [KnowledgeFile] = []
    public var first: Date?
    public var last: Date?
    /// Message ids every line of the card rests on.
    public var citations: [String] = []
    /// Search hand-off.
    public var addresses: [String] = []
    public var hints: [String] = []
}

public enum KnowledgeQuery {
    static let possessives: Set<String> = ["my", "mein", "meine", "meinem", "meinen", "meiner", "meines", "mon", "ma", "mes",
                                           "mio", "mia", "miei", "mie", "our", "unser", "unsere", "unserem", "unseren", "notre", "nos",
                                           "nostro", "nostra"]
    static let vagueWords: Set<String> = ["that", "this", "those", "jenes", "jener", "jenem", "jene", "jenen", "dieses", "diesem",
                                          "dieser", "diese", "ce", "cet", "cette", "ces", "quel", "quella", "quello", "quei", "questo", "questa"]
    static let matterNouns: Set<String> = ["project", "projects", "projekt", "projekte", "projekts", "projet", "projets", "progetto",
                                           "progetti", "matter", "fall", "case", "dossier", "auftrag", "sache", "thing", "ding", "affaire",
                                           "pratica", "bauprojekt", "bau", "umbau", "neubau", "chantier", "cantiere", "mandat", "mandate", "deal"]
    static let intentWords: [String: KnowledgeFrame.Intent] = [
        "details": .details, "detail": .details, "happened": .details, "passiert": .details, "worum": .details, "summary": .details,
        "zusammenfassung": .details, "resume": .details, "riassunto": .details, "dettagli": .details, "details?": .details,
        "files": .files, "file": .files, "attachments": .files, "attachment": .files, "anhang": .files, "anhange": .files,
        "dateien": .files, "datei": .files, "documents": .files, "dokumente": .files, "fichiers": .files, "pieces": .files,
        "allegati": .files, "documenti": .files, "plane": .files, "plans": .files, "piani": .files,
        "who": .who, "wer": .who, "qui": .who, "chi": .who,
        "agree": .agreement, "agreed": .agreement, "vereinbart": .agreement, "abgemacht": .agreement, "vereinbaren": .agreement,
        "abgesprochen": .agreement, "convenu": .agreement, "convenus": .agreement, "accord": .agreement, "concordato": .agreement,
        "accordo": .agreement, "concordati": .agreement,
    ]
    static let scaffolding: Set<String> = ["show", "me", "zeig", "zeige", "mir", "all", "alle", "what", "was", "did", "i", "ich", "we",
                                           "wir", "with", "mit", "avec", "con", "about", "uber", "sur", "su", "for", "fur", "pour", "per",
                                           "from", "von", "vom", "de", "du", "des", "da", "dal", "dalla", "di", "del", "della", "back",
                                           "in", "im", "en", "a", "au", "the", "der", "die", "das", "dem", "den", "le", "la", "les", "il",
                                           "lo", "l", "gli", "un", "une", "una", "ein", "eine", "einem", "mails", "mail", "emails", "email",
                                           "e", "nachrichten", "messages", "message", "courriels", "posta", "is", "ist", "est", "e'",
                                           "who's", "whos", "which", "welche", "welcher", "quels", "quelle", "quali", "did", "habe", "hab",
                                           "hat", "ai", "j", "ho", "had", "have", "please", "bitte", "stp", "find", "finde", "trouve",
                                           "trova", "mostra", "montre", "and", "und", "et", "ed", "or", "oder", "ou", "o", "to", "an",
                                           "zu", "on", "at", "auf", "of", "ago", "vor", "fa", "il", "y", "einen", "dass", "que", "che", "s"]

    static let months: [String: Int] = {
        let t: [[String]] = [
            ["jan", "january", "januar", "janner", "janvier", "gennaio", "genn"],
            ["feb", "february", "februar", "febr", "fevrier", "fev", "febbraio"],
            ["mar", "march", "marz", "mars", "marzo"],
            ["apr", "april", "avril", "aprile"],
            ["may", "mai", "maggio"],
            ["jun", "june", "juni", "juin", "giugno"],
            ["jul", "july", "juli", "juillet", "luglio"],
            ["aug", "august", "aout", "agosto"],
            ["sep", "sept", "september", "septembre", "settembre"],
            ["oct", "october", "okt", "oktober", "octobre", "ott", "ottobre"],
            ["nov", "november", "novembre"],
            ["dec", "december", "dez", "dezember", "decembre", "dic", "dicembre"],
        ]
        var m: [String: Int] = [:]
        for (i, ws) in t.enumerated() { for w in ws { m[w] = i + 1 } }
        return m
    }()
    static let seasons: [String: Int] = ["spring": 3, "fruhling": 3, "fruhjahr": 3, "printemps": 3, "primavera": 3,
                                         "summer": 6, "sommer": 6, "ete": 6, "estate": 6,
                                         "autumn": 9, "fall": 9, "herbst": 9, "automne": 9, "autunno": 9,
                                         "winter": 12, "hiver": 12, "inverno": 12]
    static let early: Set<String> = ["anfang", "early", "debut", "inizio", "beginning", "start"]
    static let middle: Set<String> = ["mitte", "mid", "middle", "mi", "meta", "milieu"]
    static let late: Set<String> = ["ende", "late", "end", "fin", "fine"]
    static let lastWords: Set<String> = ["last", "letztes", "letzten", "letzte", "vergangenes", "vergangenen", "derniere", "dernier",
                                         "passee", "scorso", "scorsa", "previous", "vorigen", "voriges"]
    static let yearWords: Set<String> = ["year", "jahr", "jahres", "annee", "an", "anno"]
    static let monthUnit: Set<String> = ["months", "month", "monaten", "monate", "monat", "mois", "mesi", "mese"]

    /// Interprets a question. `calendar` decides month boundaries (the user's time zone).
    public static func interpret(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> KnowledgeFrame {
        var f = KnowledgeFrame()
        f.anchors = StoryAnchors.ids(in: text) + StoryAnchors.projects(in: text)
        let rawWords = text.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.map(String.init)
        let ws = rawWords.map { KnowledgeLexicon.fold($0).replacingOccurrences(of: "’", with: "'") }
            .map { $0.hasPrefix("l'") || $0.hasPrefix("d'") ? String($0.dropFirst(2)) : $0 }
        var used = Array(repeating: false, count: ws.count)
        let anchorWords = Set(f.anchors.flatMap { KnowledgeLexicon.words($0.display) })
        var cal = calendar; cal.firstWeekday = 2
        let y = cal.component(.year, from: now), mo = cal.component(.month, from: now)
        func monthStart(_ year: Int, _ month: Int) -> Date { cal.date(from: DateComponents(year: year, month: month, day: 1))! }
        func setWindow(_ a: Date, _ b: Date) { f.window = DateInterval(start: a, end: max(a, b)) }

        for (i, w) in ws.enumerated() {
            if possessives.contains(w) { f.possessive = true; used[i] = true; continue }
            if vagueWords.contains(w) { f.vague = true; used[i] = true; continue }
            if let r = role(w) { if !f.roles.contains(r) { f.roles.append(r) }; used[i] = true; continue }
            if matterNouns.contains(w) && !(w == "fall" && i + 1 < ws.count && Int(ws[i + 1]) != nil) {
                // "fall" is also autumn: a season only after "last" / "im" style words is handled below.
                if w == "fall", i > 0, lastWords.contains(ws[i - 1]) || ["in", "im", "this"].contains(ws[i - 1]) { } else { f.matter = true; used[i] = true; continue }
            }
            if let it = intentWords[w] { if f.intent == .mails || it == .agreement { f.intent = it }; used[i] = true; continue }
            if anchorWords.contains(w) { used[i] = true; continue }
        }
        // Time.
        for i in ws.indices where !used[i] {
            let w = ws[i]
            let prev = i > 0 ? ws[i - 1] : "", next = i + 1 < ws.count ? ws[i + 1] : ""
            if let m = months[w], !(w == "mar" || w == "may" || w == "mai") || i > 0 || ws.count <= 3 {
                var year = m <= mo ? y : y - 1
                if let yy = Int(next), (2000...2099).contains(yy) { year = yy; used[i + 1] = true }
                var a = monthStart(year, m), b = cal.date(byAdding: .month, value: 1, to: a)!
                let len = b.timeIntervalSince(a)
                if early.contains(prev) { b = a.addingTimeInterval(len / 3); used[i - 1] = true }
                else if middle.contains(prev) { a = a.addingTimeInterval(len / 3); b = a.addingTimeInterval(len / 3); used[i - 1] = true }
                else if late.contains(prev) { a = a.addingTimeInterval(2 * len / 3); used[i - 1] = true }
                setWindow(a, b); used[i] = true
            } else if let s = seasons[w] {
                var year = y
                var a = monthStart(s == 12 ? year - 1 : year, s == 12 ? 12 : s)
                if a > now { year -= 1; a = monthStart(s == 12 ? year - 1 : year, s) }
                if lastWords.contains(prev), cal.date(byAdding: .month, value: 3, to: a)! > now { year -= 1; a = monthStart(s == 12 ? year - 1 : year, s); used[i - 1] = true }
                setWindow(a, cal.date(byAdding: .month, value: 3, to: a)!); used[i] = true
            } else if w.count == 2, w.hasPrefix("q"), let q = Int(w.dropFirst()), (1...4).contains(q) {
                var year = y
                if let yy = Int(next), (2000...2099).contains(yy) { year = yy; used[i + 1] = true }
                else if monthStart(y, 3 * q - 2) > now { year -= 1 }
                let a = monthStart(year, 3 * q - 2); setWindow(a, cal.date(byAdding: .month, value: 3, to: a)!); used[i] = true
            } else if let n = Int(w), (1...36).contains(n), monthUnit.contains(next) {
                let c = cal.date(byAdding: .month, value: -n, to: now)!
                let a = monthStart(cal.component(.year, from: c), cal.component(.month, from: c))
                setWindow(a, cal.date(byAdding: .month, value: 1, to: a)!); used[i] = true; used[i + 1] = true
            } else if yearWords.contains(w), lastWords.contains(prev) {
                setWindow(monthStart(y - 1, 1), monthStart(y, 1)); used[i] = true; used[i - 1] = true
            } else if let yy = Int(w), (2000...2099).contains(yy), f.window == nil {
                setWindow(monthStart(yy, 1), monthStart(yy + 1, 1)); used[i] = true
            }
        }
        if let w = f.window {
            let margin = max(w.duration * 0.25, 3 * 86_400)
            f.softWindow = DateInterval(start: w.start.addingTimeInterval(-margin), end: w.end.addingTimeInterval(margin))
        }
        // "files from the architect" style: a files intent on its own word.
        for (i, w) in ws.enumerated() where !used[i] {
            if scaffolding.contains(w) || SearchLexicon.stopwords.contains(w) || lastWords.contains(w) || early.contains(w) || middle.contains(w) || late.contains(w) { continue }
            if w.count < 2 { continue }
            f.rest.append(w)
        }
        if f.intent == .mails, f.matter { f.intent = .details }
        return f
    }

    /// Role from a query noun, inflections tolerated ("Anwalts", "Architekten", "avocats").
    static func role(_ w: String) -> KnowledgeRole? {
        if let r = KnowledgeLexicon.queryNouns[w] { return r }
        for suf in ["en", "es", "n", "s", "e", "i"] where w.hasSuffix(suf) && w.count > suf.count + 3 {
            if let r = KnowledgeLexicon.queryNouns[String(w.dropLast(suf.count))] { return r }
        }
        return nil
    }
}

// MARK: - Answering

public enum KnowledgeAsk {
    /// nil: not a knowledge question (the box runs its normal search).
    public static func answer(_ text: String, engine: KnowledgeEngine, tier: KnowledgeTier = .user, now: Date = Date(),
                              calendar: Calendar = .current) -> KnowledgeAnswer? {
        var f = KnowledgeQuery.interpret(text, now: now, calendar: calendar)
        let view = engine.view(tier)
        // Names: leftover words that match someone; the rest are topic hints.
        var names: [KnowledgePerson] = [], hints: [String] = []
        for w in f.rest {
            let ps = matchName(w, view)
            if ps.isEmpty { hints.append(w) } else { names.append(contentsOf: ps.filter { p in !names.contains { $0.key == p.key } }) }
        }
        let personQuestion = !names.isEmpty && (f.intent == .agreement || f.intent == .details || f.intent == .files || f.matter || f.vague)
        guard f.isKnowledge || personQuestion else { return nil }
        f.rest = hints
        var a = KnowledgeAnswer(kind: .none, frame: f, headline: "")
        a.hints = hints

        // 1. Who: role → ranked candidates; names → people.
        var ranked: [KnowledgeCandidate] = []
        if let r = f.roles.first {
            ranked = candidates(for: r, view: view, now: now, requireDirect: f.possessive || f.vague || true)
        }
        let named = names.sorted { ($0.count, $1.key) > ($1.count, $0.key) }.map {
            KnowledgeCandidate(key: $0.key, name: $0.name, score: Double($0.count), userAsserted: false)
        }
        let pool = f.roles.isEmpty ? named : (named.isEmpty ? ranked : ranked.filter { r in named.contains { $0.key == r.key } })
        guard !pool.isEmpty else {
            a.headline = noAnswerHeadline(f)
            a.candidates = Array(weakCandidates(f, view: view).prefix(3))
            return a
        }

        // 2. Matter: the first candidate (in rank order, up to 3) with an anchored group in the window.
        if f.matter || !f.anchors.isEmpty {
            for c in pool.prefix(3) {
                guard let p = view.people[c.key] else { continue }
                let (ms, also) = matters(for: p, frame: f, engine: engine, tier: tier)
                if let best = ms.first {
                    a.kind = .matter; a.person = p; a.matter = best; a.otherMatters = Array(ms.dropFirst().prefix(3))
                    a.alsoInPeriod = also
                    a.threads = best.threads; a.files = best.files; a.first = best.first; a.last = best.last
                    a.headline = best.title
                    a.why = [whoLine(p, role: f.roles.first)] + whyLines(p, role: f.roles.first)
                        + ["Grouped by \(anchorKind(best.anchor)) shared by \(best.threads.count) conversations"]
                    a.citations = best.messageIds
                    a.candidates = pool.filter { $0.key != c.key }.prefix(3).map { $0 }
                    a.addresses = p.addresses
                    return a
                }
            }
            // No anchored group: honest, with the best matches in the period.
            let p = pool.first.flatMap { view.people[$0.key] }
            a.person = p
            a.headline = "No project found" + (f.window.map { " " + periodText($0, calendar: calendar) } ?? "")
                + (p.map { " with \($0.name)" } ?? "")
            if let p { a.alsoInPeriod = threads(of: p, window: f.softWindow, hints: [], engine: engine, tier: tier) }
            a.candidates = Array(pool.dropFirst().prefix(3))
            a.addresses = p?.addresses ?? []
            a.citations = a.alsoInPeriod.flatMap(\.messageIds)
            return a
        }

        // 3. Person card ("mails from my lawyer", "what did I agree with Franci about the offer").
        guard let top = pool.first, let p = view.people[top.key] else { a.headline = noAnswerHeadline(f); return a }
        a.kind = .person
        a.person = p
        a.candidates = closeRunnersUp(pool)
        a.headline = whoLine(p, role: f.roles.first)
        a.why = whyLines(p, role: f.roles.first)
        a.threads = threads(of: p, window: f.softWindow, hints: f.intent == .agreement || f.intent == .details ? hints : [], engine: engine, tier: tier)
        if a.threads.isEmpty, !hints.isEmpty { a.threads = threads(of: p, window: f.softWindow, hints: [], engine: engine, tier: tier) }
        a.files = files(in: a.threads.flatMap(\.messageIds), engine: engine, tier: tier)
        a.first = p.first; a.last = p.last
        a.citations = Array(a.threads.prefix(8).flatMap(\.messageIds))
        a.addresses = p.addresses
        return a
    }

    // MARK: Candidates

    /// People with role `r`, ranked by MY relationship: user-asserted first, then asserted, then confidence, then
    /// how much I write to them (To) over what they send, then recency. `requireDirect`: Cc-only people never count.
    public static func candidates(for r: KnowledgeRole, view: KnowledgeView, now: Date, requireDirect: Bool = true) -> [KnowledgeCandidate] {
        var out: [KnowledgeCandidate] = []
        for p in view.people.values {
            guard let fact = p.role(r) else { continue }
            if !fact.userAsserted {
                if requireDirect && p.directTo + p.directFrom == 0 { continue }
                if p.supportStaff && KnowledgeEngine.professional.contains(r) { continue }
            }
            let days = p.last.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 365
            let s = (fact.userAsserted ? 100 : 0) + (fact.asserted ? 10 : 0) + fact.confidence * 5
                + log1p(2 * Double(p.directTo) + Double(p.directFrom)) + exp(-days / 180)
            out.append(KnowledgeCandidate(key: p.key, name: p.name, score: s, userAsserted: fact.userAsserted))
        }
        return out.sorted { ($0.score, $1.key) > ($1.score, $0.key) }
    }

    static func closeRunnersUp(_ pool: [KnowledgeCandidate]) -> [KnowledgeCandidate] {
        guard let top = pool.first else { return [] }
        return Array(pool.dropFirst().filter { $0.score >= top.score * 0.85 || pool.count <= 4 }.prefix(3))
    }

    static func weakCandidates(_ f: KnowledgeFrame, view: KnowledgeView) -> [KnowledgeCandidate] {
        guard let r = f.roles.first else { return [] }
        return view.people.values.filter { $0.role(r) != nil }.sorted { ($0.count, $1.key) > ($1.count, $0.key) }
            .map { KnowledgeCandidate(key: $0.key, name: $0.name, score: Double($0.count), userAsserted: false) }
    }

    static func matchName(_ w: String, _ view: KnowledgeView) -> [KnowledgePerson] {
        guard w.count >= 3, Int(w) == nil else { return [] }
        return view.people.values.filter { p in
            KnowledgeLexicon.words(p.name).contains { $0.hasPrefix(w) && (w.count >= 4 || $0 == w) }
                || p.addresses.contains { KnowledgeLexicon.words(String($0.split(separator: "@").first ?? "")).contains { $0 == w || ($0.hasPrefix(w) && w.count >= 4) } }
        }
    }

    // MARK: Threads, files, matters

    static func visibleSubject(_ x: KnowledgeEngine.Msg, engine: KnowledgeEngine, tier: KnowledgeTier) -> String {
        engine.textVisible(x.m.id, tier: tier) ? StoryAnchors.strippedSubject(x.m.subject) : ""
    }

    static func threadList(_ msgs: [KnowledgeEngine.Msg], engine: KnowledgeEngine, tier: KnowledgeTier) -> [KnowledgeThread] {
        var out: [KnowledgeThread] = []
        for (cid, xs) in Dictionary(grouping: msgs, by: { $0.m.conversationId }) {
            let asc = xs.sorted { $0.m.received < $1.m.received }
            let subj = asc.lazy.map { visibleSubject($0, engine: engine, tier: tier) }.first { !$0.isEmpty } ?? ""
            out.append(KnowledgeThread(id: cid, subject: subj, first: asc.first!.m.received, last: asc.last!.m.received,
                                       count: asc.count, messageIds: asc.map(\.m.id)))
        }
        return out.sorted { ($0.last, $0.id) > ($1.last, $1.id) }
    }

    static func personMessages(_ p: KnowledgePerson, engine: KnowledgeEngine, tier: KnowledgeTier) -> [KnowledgeEngine.Msg] {
        p.messageIds.compactMap { engine.message($0, tier: tier) }
    }

    public static func threads(of p: KnowledgePerson, window: DateInterval?, hints: [String], engine: KnowledgeEngine, tier: KnowledgeTier) -> [KnowledgeThread] {
        var ms = personMessages(p, engine: engine, tier: tier)
        if let w = window { ms = ms.filter { w.contains($0.m.received) } }
        var ts = threadList(ms, engine: engine, tier: tier)
        if !hints.isEmpty {
            let alts = hints.flatMap { [$0] + SearchLexicon.synonyms(of: $0).map(KnowledgeLexicon.fold) }
            ts = ts.filter { t in
                let ws = KnowledgeLexicon.words(t.subject)
                return alts.contains { a in ws.contains { $0.hasPrefix(a) || a.hasPrefix($0) && $0.count >= 4 } }
            }
        }
        return ts
    }

    public static func files(in ids: [String], engine: KnowledgeEngine, tier: KnowledgeTier) -> [KnowledgeFile] {
        var out: [KnowledgeFile] = [], seen = Set<String>()
        for id in ids {
            guard engine.textVisible(id, tier: tier), let x = engine.message(id, tier: tier) else { continue }
            for a in x.m.attachments where !a.isInline && StoryAnchors.attachment(a) != nil && seen.insert(a.name.lowercased()).inserted {
                out.append(KnowledgeFile(name: a.name, messageId: id, attachmentId: a.id, date: x.m.received))
            }
        }
        return out.sorted { ($0.date, $0.name) > ($1.date, $1.name) }
    }

    /// Anchors of one conversation from what the caller may read (subject + attachment names of text-visible rows).
    static func anchors(_ xs: [KnowledgeEngine.Msg], engine: KnowledgeEngine, tier: KnowledgeTier) -> [StoryAnchor] {
        var out: [StoryAnchor] = []
        for x in xs where engine.textVisible(x.m.id, tier: tier) {
            out += StoryAnchors.anchors(subject: x.m.subject, preview: nil, attachments: x.m.attachments)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.key).inserted }
    }

    /// Interim matters (§6.4): the person's conversations in the soft window, grouped by anchors (assignment, no
    /// bridging). Ranked by explicit anchors in the question, then size. Unanchored conversations come back as "also".
    public static func matters(for p: KnowledgePerson, frame f: KnowledgeFrame, engine: KnowledgeEngine,
                               tier: KnowledgeTier) -> (matters: [KnowledgeMatter], also: [KnowledgeThread]) {
        var ms = personMessages(p, engine: engine, tier: tier)
        if let w = f.softWindow {
            let convs = Set(ms.filter { w.contains($0.m.received) }.map(\.m.conversationId))
            ms = ms.filter { convs.contains($0.m.conversationId) }
        }
        let byConv = Dictionary(grouping: ms, by: { $0.m.conversationId })
        var anchorsBy: [String: [StoryAnchor]] = [:]
        for (cid, xs) in byConv { anchorsBy[cid] = anchors(xs, engine: engine, tier: tier) }
        let groups = StoryAnchors.group(anchorsBy)
        var out: [KnowledgeMatter] = []
        for g in groups {
            let xs = g.members.flatMap { byConv[$0] ?? [] }
            let ts = threadList(xs, engine: engine, tier: tier)
            var keys: [String] = []
            for k in g.members.flatMap({ anchorsBy[$0] ?? [] }) where k != g.anchor && k.kind != .stem && !keys.contains(k.display) { keys.append(k.display) }
            let proj = g.members.flatMap { anchorsBy[$0] ?? [] }.first { $0.kind == .proj }
            let title = proj.map { "Project " + $0.display } ?? (g.anchor.kind == .stem ? (ts.first?.subject ?? g.anchor.display) : g.anchor.display)
            out.append(KnowledgeMatter(id: g.anchor.key, title: title, anchor: g.anchor, keys: Array(keys.prefix(6)), threads: ts,
                                       files: files(in: xs.map(\.m.id), engine: engine, tier: tier), people: [p.key],
                                       first: ts.map(\.first).min() ?? Date(), last: ts.map(\.last).max() ?? Date()))
        }
        let wanted = Set(f.anchors.map(\.value))
        out.sort { a, b in
            let ha = byConvAnchors(a, anchorsBy).contains { wanted.contains($0.value) }, hb = byConvAnchors(b, anchorsBy).contains { wanted.contains($0.value) }
            return (ha ? 1 : 0, a.threads.count, a.last) > (hb ? 1 : 0, b.threads.count, b.last)
        }
        let inMatters = Set(out.flatMap { $0.threads.map(\.id) })
        let also = threadList(ms.filter { !inMatters.contains($0.m.conversationId) }, engine: engine, tier: tier)
        return (out, also)
    }

    static func byConvAnchors(_ m: KnowledgeMatter, _ by: [String: [StoryAnchor]]) -> [StoryAnchor] { m.threads.flatMap { by[$0.id] ?? [] } }

    /// Every anchored matter of a person (person page), newest first.
    public static func allMatters(for p: KnowledgePerson, engine: KnowledgeEngine, tier: KnowledgeTier) -> [KnowledgeMatter] {
        matters(for: p, frame: KnowledgeFrame(), engine: engine, tier: tier).matters.sorted { $0.last > $1.last }
    }

    // MARK: Lines (no mail text unless gate-visible; cue words are lexicon entries)

    static func whoLine(_ p: KnowledgePerson, role: KnowledgeRole?) -> String {
        let org = p.org.map { " (\(MailDomains.name(fromDomain: $0)))" } ?? ""
        if let r = role { return "Your \(r.title.lowercased()): \(p.name)\(org)" }
        return p.name + org
    }

    public static func whyLines(_ p: KnowledgePerson, role: KnowledgeRole?) -> [String] {
        var out: [String] = []
        if let r = role, let f = p.role(r) {
            if f.userAsserted { out.append("You marked them as your \(r.title.lowercased())") }
            for k in f.kinds where k != .user {
                let cue = f.evidence.first { $0.kind == k }?.cue
                let n = f.evidence.filter { $0.kind == k }.count
                out.append(k.title + (cue.map { " ‘\($0)’" } ?? "") + (n > 1 ? " ×\(n)" : ""))
            }
        }
        out.append("\(p.count) mails")
        if p.directTo > 0 { out.append("you write to them") }
        return out
    }

    static func anchorKind(_ a: StoryAnchor) -> String {
        switch a.kind { case .id: "a reference number"; case .proj: "a project name"; case .att: "a file"; case .stem: "a subject" }
    }

    static func noAnswerHeadline(_ f: KnowledgeFrame) -> String {
        if let r = f.roles.first { return "No \(r.title.lowercased()) found in your mail" + (f.possessive ? " that you deal with directly" : "") }
        return "No answer found"
    }

    static func periodText(_ w: DateInterval, calendar: Calendar) -> String {
        let df = DateFormatter(); df.calendar = calendar; df.timeZone = calendar.timeZone; df.locale = Locale(identifier: "en_GB")
        df.dateFormat = "MMM yyyy"
        let end = w.end.addingTimeInterval(-1)
        let a = df.string(from: w.start), b = df.string(from: end)
        return "in " + (a == b ? a : a + "–" + b)
    }

    // MARK: Search hand-off

    /// Per-address `from:` and `to:` queries (exact blind filters, so old mail isn't lost to the newest-rows pool),
    /// the soft window as hard bounds, leftover words as hints.
    public static func handoff(_ a: KnowledgeAnswer) -> [SearchQuery] {
        var out: [SearchQuery] = []
        for addr in a.addresses {
            for dir in 0..<2 {
                var q = SearchQuery()
                if dir == 0 { q.from = [addr] } else { q.to = [addr] }
                q.after = a.frame.softWindow?.start; q.before = a.frame.softWindow?.end
                q.hintWords = a.kind == .person && (a.frame.intent == .agreement || a.frame.intent == .details) ? a.hints : []
                q.prefixLast = false
                out.append(q)
            }
        }
        return out
    }

    /// Runs the hand-off on the existing engine (natural ranking, same gate for `caller`), matter members first.
    public static func search(_ a: KnowledgeAnswer, store: MailStore, mailbox: String?, limit: Int = 100, now: Date = Date(),
                              caller: SearchCaller = .user) -> [MailMessage] {
        let engine = SearchEngine(store: store)
        var hits: [SearchHit] = []
        for q in handoff(a) {
            var o = SearchEngine.Options(mailbox: mailbox, limit: limit, caller: caller)
            o.match = .natural; o.semantic = false; o.now = now
            hits += engine.search(q, o).hits
        }
        var seen = Set<String>(), out: [MailMessage] = []
        let first = Set(a.matter?.messageIds ?? [])
        if !first.isEmpty {
            for id in a.matter!.messageIds.reversed() {
                guard let h = hits.first(where: { $0.id == id }) ?? (try? store.message(id: id, includeBody: false)).flatMap({ $0 }).map({
                    SearchHit(message: $0, mailbox: mailbox ?? "me", score: 0, keywordRank: nil, semanticRank: nil, exposure: .full) }),
                      seen.insert(id).inserted else { continue }
                if case .user = caller { out.append(h.message) } else if hits.contains(where: { $0.id == id }) { out.append(h.message) }
            }
        }
        for h in hits.sorted(by: { ($0.score, $0.message.received, $0.id) > ($1.score, $1.message.received, $1.id) }) where seen.insert(h.id).inserted {
            out.append(h.message)
        }
        return Array(out.prefix(limit))
    }

    // MARK: Diagnostic (counts only)

    public static func diagnostic(_ engine: KnowledgeEngine, tier: KnowledgeTier = .user) -> String {
        let v = engine.view(tier)
        var matters = 0
        for p in v.people.values where p.directTo + p.directFrom > 0 && p.conversations.count >= 2 {
            matters += allMatters(for: p, engine: engine, tier: tier).count
        }
        return "[Knowledge] people=\(v.people.count) orgs=\(v.orgs.count) roles=\(v.roleCount) matters=\(matters)"
    }
}
