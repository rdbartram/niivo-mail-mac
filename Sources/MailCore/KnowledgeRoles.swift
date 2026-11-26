import Foundation

// PEOPLE: role vocabulary for the local knowledge layer (docs/INBOX-INTELLIGENCE-PLAN.md §6.2). Pure, no I/O.
// * Roles are typed values (plus `custom(label)` for the user's own), each with DE/EN/FR/IT lexicons for titles
//   (directory / signature lines), organisation names and domains, subject vocabulary and query nouns.
// * Evidence combines per (person, role) by noisy-OR over INDEPENDENT kinds; repeats of one kind count once with a
//   small bonus. A role is asserted at conf ≥ 0.7 with ≥ 2 kinds, or with one strong kind (directory, signature,
//   user). Otherwise it's a hint.

public struct KnowledgeRole: Codable, Sendable, Hashable, Identifiable, Comparable {
    public var id: String
    public init(_ id: String) { self.id = id }
    public static func < (a: Self, b: Self) -> Bool { a.id < b.id }

    public static let lawyer = Self("lawyer"), notary = Self("notary"), architect = Self("architect")
    public static let accountant = Self("accountant"), taxAdvisor = Self("taxAdvisor"), bank = Self("bank")
    public static let insurance = Self("insurance"), propertyManager = Self("propertyManager"), doctor = Self("doctor")
    public static let school = Self("school"), customer = Self("customer"), supplier = Self("supplier")
    public static let colleague = Self("colleague"), manager = Self("manager"), recruiter = Self("recruiter")
    public static let builtIn: [KnowledgeRole] = [.lawyer, .notary, .architect, .accountant, .taxAdvisor, .bank, .insurance,
                                                  .propertyManager, .doctor, .school, .customer, .supplier, .colleague,
                                                  .manager, .recruiter]
    /// A user-defined role ("my padel coach"); stored as typed, compared folded.
    public static func custom(_ label: String) -> Self { Self("custom:" + label.trimmingCharacters(in: .whitespaces).lowercased()) }
    public var isCustom: Bool { id.hasPrefix("custom:") }

    public var title: String {
        switch id {
        case "lawyer": "Lawyer"; case "notary": "Notary"; case "architect": "Architect"; case "accountant": "Accountant / Treuhänder"
        case "taxAdvisor": "Tax advisor"; case "bank": "Bank"; case "insurance": "Insurance"; case "propertyManager": "Property manager"
        case "doctor": "Doctor"; case "school": "School"; case "customer": "Customer"; case "supplier": "Supplier"
        case "colleague": "Colleague"; case "manager": "Manager"; case "recruiter": "Recruiter"
        default: id.hasPrefix("custom:") ? String(id.dropFirst(7)).capitalized : id
        }
    }
}

/// Where a piece of evidence came from. `requires` is what the gate must allow on the source message (§6.5 rule 1).
public enum KnowledgeEvidenceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case directory, signature, domain, subject, attachment, invoice, user
    public enum Need: Sendable { case none, metadata, content }
    public var requires: Need {
        switch self {
        case .directory, .user: .none
        case .domain: .metadata
        case .signature, .subject, .attachment, .invoice: .content   // text-derived: content on the tier, never metadata
        }
    }
    public var weight: Double {
        switch self {
        case .directory: 0.9; case .signature: 0.8; case .domain: 0.5; case .subject: 0.4; case .attachment: 0.4
        case .invoice: 0.5; case .user: 1
        }
    }
    public var strong: Bool { self == .directory || self == .signature || self == .user }
    public var title: String {
        switch self {
        case .directory: "directory"; case .signature: "signature"; case .domain: "organisation name"; case .subject: "subjects"
        case .attachment: "file names"; case .invoice: "invoices"; case .user: "you said so"
        }
    }
}

public enum KnowledgeLexicon {
    /// Fold for matching: lower-case, no diacritics, ß → ss.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ß", with: "ss").lowercased()
    }
    static func words(_ s: String) -> [String] {
        fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Title cues (directory job titles, signature lines). Matched as a whole word or as the START of a word
    /// (compounds: "Rechtsanwältin", "Treuhandexperte"), folded.
    static let titleCues: [KnowledgeRole: [String]] = [
        .lawyer: ["rechtsanwalt", "rechtsanwaltin", "anwalt", "anwaltin", "advokat", "fursprecher", "lawyer", "attorney",
                  "solicitor", "barrister", "counsel", "avocat", "avocate", "avvocato", "avvocata", "legale", "iur"],
        .notary: ["notar", "notarin", "notary", "notaire", "notaio", "notaia"],
        .architect: ["architekt", "architektin", "architect", "architecte", "architetto", "architetta"],
        .accountant: ["treuhander", "treuhanderin", "treuhandexperte", "treuhandexpertin", "buchhalter", "buchhalterin",
                      "accountant", "bookkeeper", "comptable", "fiduciaire", "fiduciario", "fiduciaria", "contabile", "commercialista"],
        .taxAdvisor: ["steuerberater", "steuerberaterin", "steuerexperte", "steuerexpertin", "fiscaliste", "fiscalista"],
        .doctor: ["arzt", "arztin", "physician", "medecin", "medico"],
        .recruiter: ["recruiter", "personalberater", "personalberaterin", "recruteur", "recruteuse", "selezionatore"],
        .propertyManager: ["bewirtschafter", "bewirtschafterin", "liegenschaftsverwalter", "gerant", "gerante", "amministratore"],
        .school: ["lehrer", "lehrerin", "teacher", "enseignant", "enseignante", "insegnante", "schulleiter", "schulleiterin"],
    ]
    /// Two-word title cues (folded, space-joined).
    static let titlePhrases: [KnowledgeRole: [String]] = [
        .lawyer: ["lic iur", "legal counsel", "attorney at law", "avocat e"],
        .taxAdvisor: ["tax advisor", "tax adviser", "tax consultant", "conseiller fiscal", "consulente fiscale"],
        .doctor: ["dr med", "dott med"],
        .recruiter: ["talent acquisition"],
        .propertyManager: ["property manager"],
        .accountant: ["expert comptable"],
    ]
    /// A title line with one of these is support staff, not the professional ("Anwaltsassistentin" ≠ "my lawyer").
    static let supportCues = ["assistent", "assistentin", "assistant", "assistante", "assistente", "sekretar", "sekretariat",
                              "secretary", "secretaire", "segretari", "paralegal", "praktikant", "stagiaire", "empfang",
                              "reception", "sachbearbeiter", "anwaltsassistent", "kanzleiassistent"]

    /// Organisation name / domain tokens (registrable domain label + display-name org part), folded.
    static let orgCues: [KnowledgeRole: [String]] = [
        .lawyer: ["advokatur", "anwalt", "anwalte", "anwaelte", "rechtsanwalte", "rechtsanwaelte", "kanzlei", "law", "legal", "lawfirm",
                  "avocats", "avvocati", "avocat", "studiolegale"],
        .notary: ["notariat", "notar", "notaires", "notariato"],
        .architect: ["architekt", "architekten", "architektur", "architects", "architectes", "architetti", "arch"],
        .accountant: ["treuhand", "fiduciaire", "fiduciaria", "revision", "accounting", "buchhaltung"],
        .taxAdvisor: ["steuerberatung", "taxes", "tax"],
        .bank: ["bank", "banque", "banca", "kantonalbank", "raiffeisen", "ubs", "postfinance"],
        .insurance: ["versicherung", "versicherungen", "assurance", "assurances", "assicurazione", "assicurazioni", "insurance"],
        .propertyManager: ["immobilien", "liegenschaften", "verwaltung", "regie", "gerance", "immobiliare"],
        .doctor: ["praxis", "arztpraxis", "klinik", "clinic", "spital", "cabinet"],
        .school: ["schule", "school", "ecole", "scuola", "gymnasium", "primarschule"],
        .recruiter: ["recruiting", "personal", "talent", "jobs"],
    ]

    /// Recurring subject / attachment vocabulary (folded word or word start).
    static let subjectCues: [KnowledgeRole: [String]] = [
        .lawyer: ["mandat", "vollmacht", "klage", "rechtsoffnung", "gericht", "vergleich", "procuration", "plainte", "procura", "ricorso", "lawsuit"],
        .notary: ["beurkundung", "kaufvertrag", "grundbuch", "acte", "rogito"],
        .architect: ["baueingabe", "baubewilligung", "baugesuch", "grundriss", "plane", "bauprojekt", "permis", "plans", "planimetria", "licenza"],
        .accountant: ["jahresabschluss", "buchhaltung", "steuererklarung", "bilanz", "bilan", "bilancio", "comptes"],
        .taxAdvisor: ["steuererklarung", "steuerveranlagung", "declaration", "dichiarazione"],
        .propertyManager: ["mietvertrag", "nebenkosten", "mietzins", "bail", "loyer", "affitto", "locazione"],
        .insurance: ["police", "polizze", "schadenmeldung", "sinistre", "sinistro"],
        .school: ["elternabend", "zeugnis", "schulreise", "bulletin", "pagella"],
        .recruiter: ["bewerbung", "kandidat", "candidature", "candidatura", "position"],
    ]

    static let invoiceWords: Set<String> = ["rechnung", "invoice", "facture", "fattura", "honorarrechnung", "zahlungserinnerung"]
    static let offerWords: Set<String> = ["offerte", "offer", "angebot", "offre", "offerta", "quote", "devis", "preventivo"]

    /// Query nouns → role (folded). Includes inflections ("Anwalts", "Architekten") and plural forms.
    static let queryNouns: [String: KnowledgeRole] = {
        var m: [String: KnowledgeRole] = [:]
        let table: [KnowledgeRole: [String]] = [
            .lawyer: ["lawyer", "attorney", "solicitor", "anwalt", "anwaltin", "anwalts", "anwalten", "rechtsanwalt", "rechtsanwaltin",
                      "avocat", "avocate", "avvocato", "avvocata", "advokat"],
            .notary: ["notary", "notar", "notarin", "notaire", "notaio"],
            .architect: ["architect", "architekt", "architekten", "architektin", "architecte", "architetto", "architetta"],
            .accountant: ["accountant", "treuhander", "treuhanderin", "treuhand", "fiduciaire", "fiduciario", "comptable", "commercialista", "buchhalter"],
            .taxAdvisor: ["steuerberater", "fiscaliste"],
            .bank: ["bank", "banque", "banca"],
            .insurance: ["insurance", "versicherung", "assurance", "assicurazione"],
            .propertyManager: ["landlord", "vermieter", "verwaltung", "regie", "gerance", "proprietaire", "padrone"],
            .doctor: ["doctor", "arzt", "arztin", "medecin", "medico", "hausarzt"],
            .school: ["school", "schule", "ecole", "scuola", "teacher", "lehrer", "lehrerin"],
            .customer: ["customer", "client", "kunde", "kunden", "cliente"],
            .supplier: ["supplier", "vendor", "lieferant", "lieferanten", "fournisseur", "fornitore"],
            .colleague: ["colleague", "kollege", "kollegin", "collegue", "collega"],
            .manager: ["manager", "boss", "chef", "chefin", "vorgesetzte", "vorgesetzter", "capo"],
            .recruiter: ["recruiter", "headhunter", "recruteur"],
        ]
        for (r, ws) in table { for w in ws { m[w] = r } }
        return m
    }()

    /// Roles a title text (directory title or one signature line) supports. Support staff lines support nothing.
    public static func rolesInTitle(_ text: String) -> [(KnowledgeRole, String)] {
        let ws = words(text)
        guard !ws.isEmpty else { return [] }
        if ws.contains(where: { w in supportCues.contains { w.hasPrefix($0) || w.hasSuffix($0) } }) { return [] }
        let joined = " " + ws.joined(separator: " ") + " "
        var out: [(KnowledgeRole, String)] = []
        for (r, cues) in titleCues {
            if let c = cues.first(where: { c in ws.contains { $0 == c || ($0.hasPrefix(c) && c.count >= 5) } }) { out.append((r, c)) }
        }
        for (r, ps) in titlePhrases where !out.contains(where: { $0.0 == r }) {
            if let p = ps.first(where: { joined.contains(" " + $0 + " ") }) { out.append((r, p)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    public static func isSupportTitle(_ text: String) -> Bool {
        words(text).contains { w in supportCues.contains { w.hasPrefix($0) || w.hasSuffix($0) } }
    }

    /// Roles an organisation name or domain supports ("mueller-architekten.example", "Advokatur Muster AG").
    public static func rolesInOrg(_ text: String) -> [(KnowledgeRole, String)] {
        let ws = words(text.replacingOccurrences(of: ".", with: " "))
        var out: [(KnowledgeRole, String)] = []
        for (r, cues) in orgCues {
            let hit = cues.first { c in ws.contains { w in w == c || (c.count >= 5 && (w.hasPrefix(c) || w.hasSuffix(c))) } }
            if let hit { out.append((r, hit)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Roles a subject (or attachment name) supports.
    public static func rolesInSubject(_ text: String) -> [(KnowledgeRole, String)] {
        let ws = words(text)
        var out: [(KnowledgeRole, String)] = []
        for (r, cues) in subjectCues {
            if let c = cues.first(where: { c in ws.contains { $0 == c || ($0.hasPrefix(c) && c.count >= 6) } }) { out.append((r, c)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    public static func isInvoice(_ text: String) -> Bool { words(text).contains { w in invoiceWords.contains { w.hasPrefix($0) } } }
    public static func isOffer(_ text: String) -> Bool { words(text).contains { w in offerWords.contains { w.hasPrefix($0) } } }
}

/// Noisy-OR over independent evidence kinds (§6.2).
public enum KnowledgeScore {
    public static let assertAt = 0.7
    public static let orgPropagation = 0.6

    /// `kinds`: kind → number of supporting items (≥ 1). Repeats of one kind count once, +0.05 per extra item (max +0.1).
    public static func combine(_ kinds: [KnowledgeEvidenceKind: Int]) -> Double {
        var miss = 1.0
        for (k, n) in kinds where n > 0 {
            let w = min(0.95, k.weight + min(0.1, 0.05 * Double(n - 1)))
            miss *= (1 - w)
        }
        return 1 - miss
    }

    public static func isAsserted(_ kinds: [KnowledgeEvidenceKind: Int]) -> Bool {
        let present = kinds.filter { $0.value > 0 }
        if present.keys.contains(where: \.strong) { return true }
        return combine(present) >= assertAt && present.count >= 2
    }
}
