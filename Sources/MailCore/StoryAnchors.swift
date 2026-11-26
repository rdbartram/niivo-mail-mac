import Foundation

// PEOPLE: anchors that may tie conversations into one matter (docs/INBOX-INTELLIGENCE-PLAN.md §5.3, brought forward
// for Phase 2's interim matters). Pure and deterministic. Anchors are the ONLY thing that links: similarity, shared
// people and time alone never do.
//   id:   reference numbers ("PO 4500123456", "Ref. 2026-0417", "Dossier 12/345", "#48213")
//   proj: project names ("Projekt Seeblick", "project Phoenix", "projet Lac", "progetto Monte")
//   att:  non-generic attachment names, normalised ("Seeblick_Grundriss_v3.pdf" → "seeblick grundriss")
//   stem: a subject stem with ≥ 2 rare terms once reply prefixes and generic words are gone

public struct StoryAnchor: Sendable, Hashable, Codable, Comparable {
    public enum Kind: String, Sendable, Hashable, Codable, Comparable {
        case id, proj, att, stem
        public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
        /// Strength order (id strongest).
        var rank: Int { switch self { case .id: 0; case .proj: 1; case .att: 2; case .stem: 3 } }
    }
    public var kind: Kind
    /// Normalised value (the comparison key).
    public var value: String
    /// As written, for display (only shown when the source text is visible to the caller).
    public var display: String
    public init(kind: Kind, value: String, display: String) { self.kind = kind; self.value = value; self.display = display }
    public var key: String { kind.rawValue + ":" + value }
    public static func < (a: Self, b: Self) -> Bool { (a.kind, a.value) < (b.kind, b.value) }
    public static func == (a: Self, b: Self) -> Bool { a.kind == b.kind && a.value == b.value }
    public func hash(into h: inout Hasher) { h.combine(kind); h.combine(value) }
}

public enum StoryAnchors {
    /// Generic subjects / words that never make a stem or a project name (DE/EN/FR/IT).
    public static let generic: Set<String> = Set("""
    re aw wg fw fwd tr rv sv antw antwort reply rif ref betreff objet oggetto subject \
    rechnung rechnungen offerte offerten meeting update frage fragen anfrage info infos information termin termine \
    facture factures reunion fattura fatture riunione invoice invoices quick question questions question domanda \
    besprechung sitzung call kurz kurze kurzer danke thanks merci grazie hallo hello bonjour ciao hoi gruss grusse \
    dokument dokumente document documents documento unterlagen dossier pdf scan bild image foto photo \
    neu new nouveau nuovo wichtig important urgent dringend reminder erinnerung rappel promemoria \
    projekt project projet progetto the der die das le la il und and et e von from de da fur for pour per mit with avec con \
    zum zur im in au al am an auf on of des du del della dei vom bis to bei \
    woche week semaine settimana nachste next prochaine prossima morgen tomorrow demain domani heute today kurzfristig
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    static let projectNouns: Set<String> = ["projekt", "project", "projet", "progetto", "bauprojekt", "uberbauung", "neubau",
                                            "umbau", "sanierung", "renovation", "ristrutturazione", "chantier", "cantiere", "mandat"]
    static let idLabels = ["po", "bestellung", "bestellnr", "auftrag", "auftragsnr", "order", "ref", "referenz", "reference", "réf",
                           "rif", "riferimento", "dossier", "fall", "case", "ticket", "vertrag", "contract", "contrat", "contratto",
                           "objekt", "nr", "no", "n°", "nummer", "numero"]
    static let genericAttachments: Set<String> = ["image", "logo", "signature", "signatur", "outlook", "unnamed", "untitled",
                                                  "attachment", "anhang", "allegato", "piece", "scan", "dokument", "document",
                                                  "rechnung", "invoice", "facture", "fattura", "offerte", "offer", "offerta", "devis",
                                                  "banner", "icon", "facebook", "linkedin", "twitter", "instagram", "smime", "winmail"]

    /// Strips reply / forward prefixes ("AW: WG: Re:").
    public static func strippedSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        let pre = try! NSRegularExpression(pattern: "^(?:(?:re|aw|wg|fw|fwd|tr|rv|sv|antw|r)\\s*(?:\\[\\d+\\])?\\s*:\\s*)+", options: [.caseInsensitive])
        t = pre.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    static let idPattern = try! NSRegularExpression(pattern:
        "(?:^|[^\\p{L}\\d])(po|bestellung|bestell-?nr\\.?|auftrag(?:s-?nr\\.?)?|order|ref\\.?|referenz|reference|r[ée]f\\.?|rif\\.?|riferimento|dossier|fall|case|ticket|vertrag|contract|contrat|contratto|objekt|nr\\.?|no\\.?|n°|nummer|numero)\\s*[:#.]?\\s*([A-Z0-9][A-Z0-9\\-/.]{2,}[A-Z0-9])",
        options: [.caseInsensitive])
    static let bareNumber = try! NSRegularExpression(pattern: "(?:^|[^\\d\\-./])(#?\\d{6,12})(?![\\d\\-./])")
    static let hashTicket = try! NSRegularExpression(pattern: "(?:^|\\s)#(\\d{4,})\\b")

    /// Reference numbers in `text`: labelled values with a digit, bare 6–12-digit numbers, `#1234` tickets. Dates and
    /// phone-like numbers with separators don't count as bare numbers.
    public static func ids(in text: String) -> [StoryAnchor] {
        var out: [StoryAnchor] = []
        let ns = text as NSString
        for m in idPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let v = ns.substring(with: m.range(at: 2))
            guard v.contains(where: \.isNumber), !isDateLike(v) else { continue }
            let norm = v.uppercased().filter { $0.isLetter || $0.isNumber }
            guard norm.count >= 4 else { continue }
            out.append(StoryAnchor(kind: .id, value: norm, display: v))
        }
        for m in bareNumber.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let v = ns.substring(with: m.range(at: 1)).filter(\.isNumber)
            guard !out.contains(where: { $0.value.hasSuffix(v) }) else { continue }
            out.append(StoryAnchor(kind: .id, value: v, display: v))
        }
        for m in hashTicket.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let v = ns.substring(with: m.range(at: 1))
            guard !out.contains(where: { $0.value.hasSuffix(v) }) else { continue }
            out.append(StoryAnchor(kind: .id, value: v, display: "#" + v))
        }
        return out
    }

    static func isDateLike(_ v: String) -> Bool {
        v.range(of: "^\\d{1,4}[./-]\\d{1,2}([./-]\\d{1,4})?$", options: .regularExpression) != nil
    }

    /// "Projekt Seeblick", "Überbauung Seeblick", "project Phoenix": the project noun followed by one capitalised,
    /// non-generic word.
    public static func projects(in text: String) -> [StoryAnchor] {
        let raw = text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        var out: [StoryAnchor] = []
        for (i, w) in raw.enumerated() where projectNouns.contains(KnowledgeLexicon.fold(w)) {
            var name: [String] = []
            var j = i + 1
            while j < raw.count, name.count < 1 {   // one word: "Projekt Seeblick – Vorprojekt" and "Projekt Seeblick: Grundriss" agree
                let n = raw[j], f = KnowledgeLexicon.fold(n)
                guard n.first?.isUppercase == true, !generic.contains(f), f.count >= 3, !n.allSatisfy(\.isNumber) else { break }
                name.append(n); j += 1
            }
            guard !name.isEmpty else { continue }
            let value = name.map(KnowledgeLexicon.fold).joined(separator: " ")
            out.append(StoryAnchor(kind: .proj, value: value, display: name.joined(separator: " ")))
        }
        return out
    }

    /// Attachment name → anchor, or nil for generic / inline / image-only names.
    public static func attachment(_ a: AttachmentInfo) -> StoryAnchor? {
        guard !a.isInline else { return nil }
        let name = a.name
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "bmp", "ics", "vcf", "p7s", "p7m", "rpmsg", "eml", "msg"].contains(ext) && base.count < 12 { return nil }
        var words = KnowledgeLexicon.words(base.replacingOccurrences(of: "_", with: " "))
        // Version and date noise: v3, final, 2026, 20260212, 01.
        words = words.filter { w in
            !(w.allSatisfy(\.isNumber)) && w.range(of: "^v\\d+$", options: .regularExpression) == nil
                && !["final", "def", "definitiv", "neu", "new", "copy", "kopie", "rev", "draft", "entwurf"].contains(w)
        }
        let content = words.filter { $0.count >= 4 && !genericAttachments.contains($0) && !generic.contains($0) }
        guard !content.isEmpty, !words.contains(where: { $0.hasPrefix("image0") }) else { return nil }
        return StoryAnchor(kind: .att, value: words.filter { $0.count >= 3 }.joined(separator: " "), display: name)
    }

    /// Subject stem: up to three rare-looking content words, in order. nil when fewer than two remain.
    public static func stem(_ subject: String) -> StoryAnchor? {
        let s = strippedSubject(subject)
        let ws = KnowledgeLexicon.words(s).filter { w in
            w.count >= 4 && !generic.contains(w) && !SearchLexicon.stopwords.contains(w) && !w.allSatisfy(\.isNumber)
                && !KnowledgeLexicon.invoiceWords.contains(w) && !KnowledgeLexicon.offerWords.contains(w)
        }
        guard ws.count >= 2 else { return nil }
        let top = Array(ws.prefix(3))
        return StoryAnchor(kind: .stem, value: top.joined(separator: " "), display: s)
    }

    /// All anchors of one message from what the caller may read: the subject (if `subject`), the preview (if
    /// `content`) and attachment names (if `content`).
    public static func anchors(subject: String?, preview: String?, attachments: [AttachmentInfo]) -> [StoryAnchor] {
        var out: [StoryAnchor] = []
        if let s = subject, !s.isEmpty {
            out += ids(in: s) + projects(in: s)
            if let st = stem(s) { out.append(st) }
        }
        if let p = preview, !p.isEmpty { out += ids(in: p) + projects(in: p) }
        out += attachments.compactMap(attachment)
        var seen = Set<String>()
        return out.filter { seen.insert($0.key).inserted }
    }

    /// Assignment grouping (no chaining, no bridging): anchors ordered by support (then strength); each anchor with
    /// ≥ `minSupport` UNASSIGNED members forms a group; a member joins the first group only. Stems need two members
    /// and a non-stem anchor never loses to a stem of the same size.
    public static func group<ID: Hashable & Comparable>(_ members: [ID: [StoryAnchor]], minSupport: Int = 2) -> [(anchor: StoryAnchor, members: [ID])] {
        var by: [StoryAnchor: Set<ID>] = [:]
        for (id, ans) in members { for a in ans { by[a, default: []].insert(id) } }
        let ordered = by.filter { $0.value.count >= minSupport }
            .sorted { a, b in (a.value.count, -a.key.kind.rank, b.key.value) > (b.value.count, -b.key.kind.rank, a.key.value) }
        var assigned = Set<ID>()
        var out: [(StoryAnchor, [ID])] = []
        for (a, ids) in ordered {
            let free = ids.subtracting(assigned)
            guard free.count >= minSupport else { continue }
            assigned.formUnion(free)
            out.append((a, free.sorted()))
        }
        return out
    }
}
