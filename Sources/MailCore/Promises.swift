import Foundation

// PROMISES: the promises ledger (docs/RETHINK.md §3–§4).
//
// * Extraction is pure and rule-based (DE/EN/FR/IT): commitments from the user's SENT mail ("I'll send it Friday",
//   "ich schicke dir bis Freitag", "je t'envoie demain", "ti mando entro lunedì") and explicit requests with a
//   deadline in RECEIVED direct mail ("owed by you").
// * Text is read only where the label gate gives the on-device tier `.content` (the ledger checks that; this file
//   never sees anything else). Quoted history and signatures are zoned out first, quoted spans ("…", «…») are
//   ignored, hypotheticals, questions and out-of-office lines are skipped.
// * Due dates are resolved by our own rules against the sent time (relative words, weekdays, Swiss/European
//   numeric dates, month names), never `NSDataDetector` (locale-dependent).
// * Uncertain candidates (present tense without a time anchor, "let me…", hedges) are kept but flagged.

public enum PromiseKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// From the user's sent mail: something the user said they'd do.
    case promised
    /// From received direct mail: an explicit request to the user with a deadline ("owed by you").
    case asked
    public var title: String {
        switch self { case .promised: "You promised"; case .asked: "Asked of you" }
    }
}

public enum PromiseState: String, Codable, Sendable, CaseIterable, Hashable { case open, done, dismissed }
public enum PromiseOrigin: String, Codable, Sendable, Hashable { case rule, llm }
/// Why a promise was closed (content-free).
public enum PromiseCompletion: String, Codable, Sendable, Hashable, CaseIterable {
    case user, attachment, attachedMarker, ai, policy
    public var isAuto: Bool { self == .attachment || self == .attachedMarker }
}

/// One candidate found in one message (pure extractor output).
public struct PromiseCandidate: Sendable, Hashable {
    public var kind: PromiseKind
    /// The verb phrase, ≤ 80 characters, de-quoted.
    public var text: String
    /// Start of the due day (in the extractor's calendar), when one is stated.
    public var due: Date?
    /// false = uncertain (no time anchor, present tense, hedge).
    public var certain: Bool
    public init(kind: PromiseKind, text: String, due: Date?, certain: Bool) {
        self.kind = kind; self.text = text; self.due = due; self.certain = certain
    }
}

/// A ledger row.
public struct Promise: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: PromiseKind
    public var conversationId: String
    public var sourceMessageId: String
    public var mailbox: String
    /// nil when the source's label doesn't allow details offline and the text isn't in memory (yet).
    public var text: String?
    public var counterpartName: String?
    public var counterpartAddress: String?
    public var due: Date?
    /// The source message's time.
    public var createdAt: Date
    public var state: PromiseState
    public var certain: Bool
    public var origin: PromiseOrigin
    public var completion: PromiseCompletion?
    public var closedAt: Date?
    public var snoozedUntil: Date?
    /// The day the morning reminder went out.
    public var remindedOn: Date?
    /// Whether text / counterpart may be written to disk (source allows offline details).
    public var persistText: Bool

    public init(id: String, kind: PromiseKind, conversationId: String, sourceMessageId: String, mailbox: String, text: String?,
                counterpartName: String? = nil, counterpartAddress: String? = nil, due: Date?, createdAt: Date,
                state: PromiseState = .open, certain: Bool = true, origin: PromiseOrigin = .rule, completion: PromiseCompletion? = nil,
                closedAt: Date? = nil, snoozedUntil: Date? = nil, remindedOn: Date? = nil, persistText: Bool = true) {
        self.id = id; self.kind = kind; self.conversationId = conversationId; self.sourceMessageId = sourceMessageId
        self.mailbox = mailbox; self.text = text; self.counterpartName = counterpartName; self.counterpartAddress = counterpartAddress
        self.due = due; self.createdAt = createdAt; self.state = state; self.certain = certain; self.origin = origin
        self.completion = completion; self.closedAt = closedAt; self.snoozedUntil = snoozedUntil; self.remindedOn = remindedOn
        self.persistText = persistText
    }

    public func isSnoozed(now: Date) -> Bool { (snoozedUntil ?? .distantPast) > now }
    /// The due day has passed (due is the start of the due day).
    public func isOverdue(now: Date, calendar: Calendar = .current) -> Bool {
        guard state == .open, let due, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: due)) else { return false }
        return now >= end
    }
    public func isDueToday(now: Date, calendar: Calendar = .current) -> Bool {
        guard let due else { return false }
        return calendar.isDate(due, inSameDayAs: now)
    }
    public var counterpart: String? {
        if let n = counterpartName, !n.isEmpty { return n }
        return counterpartAddress
    }

    /// Stable across re-scans and folder moves: conversation + sent second + direction + phrase.
    public static func makeId(conversationId: String, sentAt: Date, kind: PromiseKind, text: String) -> String {
        let h = ConversationFactsBuilder.fnv([conversationId, "\(Int(sentAt.timeIntervalSince1970))", kind.rawValue, text.lowercased()])
        return String(format: "%016llx", h)
    }
}

// MARK: - Display helpers

public enum PromiseDisplay {
    /// "by Fri" / "by 3 Dec" / "today" / "2 d overdue".
    public static func dueShort(_ p: Promise, now: Date, calendar: Calendar = .current) -> String? {
        guard let due = p.due else { return nil }
        if p.isOverdue(now: now, calendar: calendar) {
            let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: due), to: calendar.startOfDay(for: now)).day ?? 1)
            return "\(days) d overdue"
        }
        if calendar.isDate(due, inSameDayAs: now) { return "today" }
        if let t = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)), calendar.isDate(due, inSameDayAs: t) { return "by tomorrow" }
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_GB")
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: due).day ?? 99
        f.dateFormat = days < 7 ? "EEE" : "d MMM"
        return "by " + f.string(from: due)
    }

    /// Reader line: "You promised: Send the offer · by Fri".
    public static func readerLine(_ p: Promise, now: Date, calendar: Calendar = .current) -> String {
        let what = p.text ?? "a promise in a protected message"
        let due = dueShort(p, now: now, calendar: calendar).map { " · " + $0 } ?? ""
        return "\(p.kind.title): \(what)\(due)"
    }
}

// MARK: - Extraction (pure)

/// Compiled patterns, shared (NSRegularExpression is immutable and safe to share for matching).
final class PromiseRegex: @unchecked Sendable {
    static let shared = PromiseRegex()
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]
    func re(_ p: String) -> NSRegularExpression? {
        lock.withLock {
            if let r = cache[p] { return r }
            let r = try? NSRegularExpression(pattern: p, options: [.caseInsensitive])
            cache[p] = r
            return r
        }
    }
    func matches(_ p: String, _ s: String) -> [(range: NSRange, groups: [String?])] {
        guard let r = re(p) else { return [] }
        let ns = s as NSString
        return r.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (m.range, (0..<m.numberOfRanges).map { i in
                let g = m.range(at: i)
                return g.location == NSNotFound ? nil : ns.substring(with: g)
            })
        }
    }
    func first(_ p: String, _ s: String) -> (range: NSRange, groups: [String?])? { matches(p, s).first }
    func has(_ p: String, _ s: String) -> Bool {
        guard let r = re(p) else { return false }
        return r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

public enum PromiseExtractor {
    static let rx = PromiseRegex.shared

    /// `raw` is a body or preview (HTML allowed). At most 5 candidates per message, de-duplicated.
    public static func extract(_ raw: String, isHTML: Bool, kind: PromiseKind, sentAt: Date, calendar: Calendar = .current) -> [PromiseCandidate] {
        var text = AIUntrustedText.body(raw, isHTML: isHTML)
        text = AIUntrustedText.stripQuotedAndSignature(text)
        var out: [PromiseCandidate] = []
        var seen = Set<String>()
        for s in sentences(text) {
            let c = kind == .promised ? promise(in: s, sentAt: sentAt, calendar: calendar) : request(in: s, sentAt: sentAt, calendar: calendar)
            guard let c, seen.insert(c.text.lowercased()).inserted else { continue }
            out.append(c)
            if out.count >= 5 { break }
        }
        return out
    }

    // MARK: Zoning

    /// Typographic apostrophes → ASCII, quoted spans removed ("…", “…”, „…“, «…», »…«, ‹…›).
    static func dequote(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        for p in ["\"[^\"\\n]{1,300}\"", "“[^”\\n]{1,300}”", "„[^“”\\n]{1,300}[“”]", "«[^»\\n]{1,300}»", "»[^«\\n]{1,300}«", "‹[^›\\n]{1,300}›"] {
            t = t.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        return t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }

    /// Lines → sentences (split after . ! ? ; and a space, never after a digit: "21.11. schicke" stays together).
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let chars = Array(dequote(String(line)))
            var cur = ""
            for (i, ch) in chars.enumerated() {
                cur.append(ch)
                let end = ".!?;".contains(ch) && i + 1 < chars.count && chars[i + 1] == " "
                    && !(ch == "." && i > 0 && chars[i - 1].isNumber)
                if end { out.append(cur); cur = "" }
            }
            out.append(cur)
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 6 && $0.count <= 500 }
    }

    // MARK: Promises (sent mail)

    static let ooo = ["out of office", "out of the office", "on holiday", "on vacation", "on leave", "away from", "be away", "be out",
                      "abwesend", "nicht im büro", "ferien", "urlaub", "nicht erreichbar", "ausser haus", "außer haus",
                      "absent", "absente", "en congé", "en vacances", "hors du bureau",
                      "assente", "fuori ufficio", "in ferie", "non raggiungibile"]
    static let softeners = ["if possible", "if needed", "wenn möglich", "falls möglich", "falls nötig", "si possible", "se possibile"]
    static let hypothetical = "\\b(if|unless|in case|would|could i|should i|might|falls|wenn|sofern|würde|würden|könnte|könnten|hätte|ob ich|si|s'il|s'ils|pourrais|voudrais|ferais|enverrais|se|qualora|nel caso|potrei|farei|manderei)\\b"
    static let deliveredNow = "\\b(anbei|beiliegend|im anhang|hiermit|angehängt|in der beilage|ci-joint|ci-jointe|en pièce jointe|en annexe|voici|in allegato|allegato|allegata|ecco|qui di seguito|attached|enclosed|here is|here's|here are)\\b"
    static let hedges = "\\b(try|probably|maybe|perhaps|hopefully|versuche|versuchen|vielleicht|wahrscheinlich|hoffentlich|essayer|essaierai|peut-être|probablement|cercherò|proverò|forse|probabilmente)\\b"
    static let timeAnchor = "\\b(gleich|später|nachher|zeitnah|umgehend|baldmöglichst|sobald|asap|noch heute|tout de suite|plus tard|dès que|rapidement|subito|più tardi|appena|al più presto|shortly|later today|soon)\\b"

    struct Trigger: Sendable { var pattern: String; var future: Bool }
    static let triggers: [Trigger] = [
        // EN
        Trigger(pattern: "\\b(?:i'll|i will|we'll|we will|i'm going to|i am going to|we're going to|we are going to|i shall)\\s+(?:(?:also|just|quickly|then|definitely|certainly|still|now)\\s+)?(\\w+)(?:\\s+(\\w+))?", future: true),
        Trigger(pattern: "\\blet me\\s+(check|get back|look|see|confirm|find out|ask|send|sort)\\b", future: false),
        // DE
        Trigger(pattern: "\\b(?:ich werde|wir werden|werde ich|werden wir)\\b", future: true),
        Trigger(pattern: "\\b(?:ich|wir)\\s+(?:dir|ihnen|euch|ihr|ihm|es|das|sie|mich|uns)?\\s*(?:schicke|schick|sende|melde|kümmere|liefere|prüfe|kläre|leite|rufe|gebe|mache|erledige|bereite|erstelle|übernehme|organisiere|reiche|besorge|schicken|senden|melden|kümmern|liefern|prüfen|klären|erledigen)\\b", future: false),
        Trigger(pattern: "\\b(?:schicke|schick|sende|melde|kümmere|liefere|prüfe|kläre|leite|rufe|gebe|mache|erledige|bereite|erstelle|übernehme|organisiere|reiche|besorge)\\s+ich\\b", future: false),
        // FR
        Trigger(pattern: "\\b(?:je vais|nous allons)\\s+(?:vous\\s+|te\\s+|t'|l'|le\\s+|la\\s+|les\\s+|lui\\s+|leur\\s+)*(\\w+)", future: true),
        Trigger(pattern: "\\b(?:je\\s+(?:(?:vous|te|t'|le|la|les|l'|lui|leur|en|y)\\s*)*|j')(\\w+rai)\\b", future: true),
        Trigger(pattern: "\\bje\\s+(?:(?:vous|te|t'|le|la|les|l'|lui|leur)\\s*)*(?:envoie|transmets|m'occupe|reviens|rappelle|confirme|prépare|regarde|vérifie|fais|recontacte|renvoie|transfère)\\b", future: false),
        Trigger(pattern: "\\bon va\\s+(\\w+)", future: false),
        // IT
        Trigger(pattern: "(?:^|\\s)(?:(?:te|ti|le|vi|ve|gli|glie|lo|la|li|ne|ce|ci)\\s+)*(\\w+rò)\\b", future: true),
        Trigger(pattern: "\\b(?:ti|le|vi|gli)\\s+(?:mando|invio|giro|inoltro|scrivo|chiamo|richiamo|faccio sapere|confermo|preparo)\\b", future: false),
        Trigger(pattern: "\\b(?:mi occupo|mi faccio sentire|provvedo)\\b", future: false),
    ]
    /// Verbs after a future trigger that make it a state, not an action ("I'll be out", "je serai", "sarò").
    static let stateVerbs: Set<String> = ["be", "need", "not", "never", "have", "être", "serai", "essere", "sarò"]

    static func promise(in sentence: String, sentAt: Date, calendar: Calendar) -> PromiseCandidate? {
        var s = sentence
        if s.hasSuffix("?") { return nil }   // "Shall I send it Friday?"
        let low = s.lowercased()
        if ooo.contains(where: { low.contains($0) }) { return nil }
        for w in softeners { s = s.replacingOccurrences(of: w, with: " ", options: .caseInsensitive) }
        if rx.has(hypothetical, s) { return nil }
        var best: (range: NSRange, groups: [String?], t: Trigger)?
        for t in triggers {
            for m in rx.matches(t.pattern, s) where best == nil || m.range.location < best!.range.location {
                best = (m.range, m.groups, t)
            }
        }
        guard let b = best else { return nil }
        let next = (b.groups.count > 1 ? b.groups[1] : nil)?.lowercased()
        if let w = next, stateVerbs.contains(w) {
            // "I'll be sending" and "I'll have it ready" are still actions; "I'll be out", "I'll need", "je serai" aren't.
            let after = (b.groups.count > 2 ? b.groups[2] : nil)?.lowercased() ?? ""
            let ok = (w == "be" && after.hasSuffix("ing")) || (w == "have" && !after.isEmpty && after != "to")
            if !ok { return nil }
        }
        // German "werde … sein" is a state.
        if low.range(of: "\\bsein[.!]?$", options: .regularExpression) != nil, rx.has("\\b(werde|werden)\\b", s) { return nil }
        // A delivery now ("ich schicke dir anbei") isn't a promise.
        if let d = rx.first(deliveredNow, s), !b.t.future || d.range.location < b.range.location { return nil }
        let due = PromiseDates.resolve(s, sentAt: sentAt, calendar: calendar)
        let hedged = rx.has(hedges, s)
        let certain = !hedged && (due != nil || b.t.future || rx.has(timeAnchor, s))
        let text = phrase(s, from: b.range)
        guard text.count >= 4 else { return nil }
        return PromiseCandidate(kind: .promised, text: text, due: due, certain: certain)
    }

    // MARK: Requests (received direct mail)

    static let requestPattern: String = {
        let words = TriageCueScanner.requests + ["we need", "i need", "brauchen wir", "benötigen wir", "ich brauche", "ich benötige",
                                                 "nous avons besoin", "j'ai besoin", "abbiamo bisogno", "ho bisogno", "send me", "schicken sie mir",
                                                 "schick mir", "envoyez-moi", "envoie-moi", "mandami", "mi mandi", "inviami"]
        return "\\b(" + words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")"
    }()
    static let notARequest = "\\b(please find|please note|please see|bitte beachten|bitte finden|veuillez trouver|veuillez noter|in allegato|si prega di notare)\\b"

    static func request(in sentence: String, sentAt: Date, calendar: Calendar) -> PromiseCandidate? {
        var s = sentence
        for w in softeners { s = s.replacingOccurrences(of: w, with: " ", options: .caseInsensitive) }
        guard !rx.has(notARequest, s), let cue = rx.first(requestPattern, s),
              let due = PromiseDates.resolve(s, sentAt: sentAt, calendar: calendar) else { return nil }
        let text = phrase(s, from: cue.range)
        guard text.count >= 4 else { return nil }
        return PromiseCandidate(kind: .asked, text: text, due: due, certain: true)
    }

    // MARK: Phrase

    /// From the trigger when a greeting / clause precedes it ("Hi Anna, I'll…"), else the whole sentence; quote marks
    /// removed, ≤ 80 characters on a word boundary.
    static func phrase(_ s: String, from r: NSRange) -> String {
        let ns = s as NSString
        let before = ns.substring(to: min(r.location, ns.length))
        var t = (before.contains(",") || before.count > 40) ? ns.substring(from: min(r.location, ns.length)) : s
        t = t.replacingOccurrences(of: "[\"“”„«»‹›]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;:!?-–")))
        if let f = t.first { t = f.uppercased() + t.dropFirst() }
        if t.count > 80 {
            var cut = String(t.prefix(79))
            if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > 40 { cut = String(cut[..<sp]) }
            t = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
        }
        return t
    }
}

// MARK: - Due dates (relative to the sent time; Swiss/European formats)

public enum PromiseDates {
    static let rx = PromiseRegex.shared

    static let months: [(String, Int)] = [
        ("january|januar|jänner|janvier|gennaio|jan", 1), ("february|februar|février|fevrier|febbraio|févr|feb", 2),
        ("march|märz|maerz|mars|marzo|mar", 3), ("april|avril|aprile|apr", 4), ("may|mai|maggio", 5),
        ("june|juni|juin|giugno|jun", 6), ("july|juli|juillet|luglio|jul", 7), ("august|août|aout|agosto|aug", 8),
        ("september|septembre|settembre|sept|sep", 9), ("october|oktober|octobre|ottobre|oct|okt", 10),
        ("november|novembre|nov", 11), ("december|dezember|décembre|decembre|dicembre|dec|dez|déc", 12),
    ]
    static let weekdays: [(String, Int)] = [
        ("monday|montag|lundi|lunedì|lunedi", 2), ("tuesday|dienstag|mardi|martedì|martedi", 3),
        ("wednesday|mittwoch|mercredi|mercoledì|mercoledi", 4), ("thursday|donnerstag|jeudi|giovedì|giovedi", 5),
        ("friday|freitag|vendredi|venerdì|venerdi", 6), ("saturday|samstag|samedi|sabato", 7), ("sunday|sonntag|dimanche|domenica", 1),
    ]
    static let numberWords: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "einem": 1, "zwei": 2, "drei": 3,
                                             "vier": 4, "fünf": 5, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5,
                                             "due": 2, "tre": 3, "quattro": 4, "cinque": 5]

    static func month(_ name: String) -> Int? {
        let n = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return months.first { $0.0.split(separator: "|").contains { String($0) == n } }?.1
    }

    /// The earliest stated due day on or after the sent day, as the start of that day; nil when none.
    public static func resolve(_ s: String, sentAt: Date, calendar: Calendar = .current) -> Date? {
        let day0 = calendar.startOfDay(for: sentAt)
        func add(_ n: Int) -> Date? { calendar.date(byAdding: .day, value: n, to: day0) }
        func ymd(_ year: Int?, _ m: Int, _ d: Int) -> Date? {
            guard (1...12).contains(m), (1...31).contains(d) else { return nil }
            let year0 = calendar.component(.year, from: sentAt)
            let y = year.map { $0 < 100 ? 2000 + $0 : $0 } ?? year0
            guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)), calendar.component(.day, from: date) == d else { return nil }
            if year == nil, date < day0 {   // "3.1." written in December → next January
                return calendar.date(from: DateComponents(year: y + 1, month: m, day: d)).map { calendar.startOfDay(for: $0) }
            }
            return calendar.startOfDay(for: date)
        }
        func thisFriday() -> Date? {
            (0...6).lazy.compactMap { add($0) }.first { calendar.component(.weekday, from: $0) == 6 }
        }
        var hits: [(NSRange, Date)] = []
        func scan(_ p: String, _ make: ([String?]) -> Date?) {
            for m in rx.matches(p, s) { if let d = make(m.groups) { hits.append((m.range, d)) } }
        }
        func int(_ g: String?) -> Int? { g.flatMap { Int($0) } }
        let monthAlt = months.map(\.0).joined(separator: "|")
        // Numeric: 21.11. / 21.11.2026 / 21.11.26 / 21/11/2026 / 2026-11-21
        scan("\\b(\\d{1,2})\\.\\s?(\\d{1,2})\\.(?:\\s?(\\d{4}|\\d{2})\\b)?") { g in ymd(int(g[3]), int(g[2]) ?? 0, int(g[1]) ?? 0) }
        scan("\\b(\\d{1,2})/(\\d{1,2})/(\\d{4}|\\d{2})\\b") { g in ymd(int(g[3]), int(g[2]) ?? 0, int(g[1]) ?? 0) }
        scan("\\b(\\d{4})-(\\d{2})-(\\d{2})\\b") { g in ymd(int(g[1]), int(g[2]) ?? 0, int(g[3]) ?? 0) }
        // Month names: "21. November", "3 décembre", "il 3 dicembre", "3rd of December", "December 3"
        scan("\\b(\\d{1,2})(?:\\.|er|st|nd|rd|th)?\\s+(?:of\\s+)?(\(monthAlt))\\b\\.?(?:\\s+(\\d{4}))?") { g in
            month(g[2] ?? "").flatMap { ymd(int(g[3]), $0, int(g[1]) ?? 0) }
        }
        scan("\\b(\(monthAlt))\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b(?:,?\\s+(\\d{4}))?") { g in
            month(g[1] ?? "").flatMap { ymd(int(g[3]), $0, int(g[2]) ?? 0) }
        }
        // Relative words
        scan("\\b(?:today|tonight|heute|aujourd'hui|oggi|stasera|ce soir|end of (?:the )?day|eod|cob)\\b") { _ in add(0) }
        scan("\\b(?:tomorrow|demain|domani)\\b") { _ in add(1) }
        scan("(?<!guten )(?<!am )(?<!heute )(?<!jeden )\\bmorgen\\b") { _ in add(1) }
        scan("(?:\\bthe day after tomorrow\\b|\\bübermorgen\\b|\\baprès-demain\\b|\\bapres-demain\\b|\\bdopodomani\\b)") { _ in add(2) }
        scan("\\b(?:next week|nächste[nr]? woche|kommende[nr]? woche|(?:la )?semaine prochaine|(?:la )?prossima settimana|(?:la )?settimana prossima)\\b") { _ in
            thisFriday().flatMap { calendar.date(byAdding: .day, value: 7, to: $0) }
        }
        scan("\\b(?:this week|end of (?:the )?week|diese woche|dieser woche|ende (?:der |dieser )?woche|cette semaine|fin de (?:la )?semaine|questa settimana|fine settimana|entro la settimana|in settimana)\\b") { _ in thisFriday() }
        scan("\\b(?:end of (?:the )?month|ende (?:des )?monats|ende monat|monatsende|fin du mois|fin de mois|fine (?:del )?mese)\\b") { _ in
            calendar.dateInterval(of: .month, for: sentAt).flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) }.map { calendar.startOfDay(for: $0) }
        }
        let nw = numberWords.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        scan("\\b(?:in|within|dans|tra|fra|entro)\\s+(\\d{1,2}|\(nw))\\s+(?:days|tagen|jours|giorni)\\b") { g in
            let w = (g[1] ?? "").lowercased()
            return (Int(w) ?? numberWords[w]).flatMap { $0 <= 60 ? add($0) : nil }
        }
        for (names, wd) in weekdays {
            scan("\\b(?:\(names))\\b") { _ in (1...7).lazy.compactMap { add($0) }.first { calendar.component(.weekday, from: $0) == wd } }
        }
        // A match inside a longer one ("demain" in "après-demain") doesn't count.
        let kept = hits.filter { h in
            !hits.contains { o in o.0.length > h.0.length && NSIntersectionRange(o.0, h.0) == h.0 }
        }
        return kept.map(\.1).filter { $0 >= day0 }.min()
    }
}
