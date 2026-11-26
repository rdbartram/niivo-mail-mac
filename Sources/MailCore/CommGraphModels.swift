import Foundation

// Value types of the communication graph (CommGraph.swift). Everything here is sealed (AES-GCM) before it touches
// disk; node keys are HMACs, so neither names, addresses, domains, categories nor subject terms are stored in the clear.

// MARK: - Domains and companies

/// Company grouping by registrable domain. Free-mail domains never form a company.
public enum MailDomains {
    /// Exact free-mail / consumer domains (registrable form).
    public static let freeMail: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "passport.com",
        "yahoo.com", "ymail.com", "rocketmail.com", "aol.com", "icloud.com", "me.com", "mac.com",
        "gmx.ch", "gmx.de", "gmx.net", "gmx.at", "gmx.com", "web.de", "t-online.de", "freenet.de", "posteo.de",
        "bluewin.ch", "sunrise.ch", "hispeed.ch", "bluemail.ch", "swissonline.ch", "green.ch",
        "protonmail.com", "protonmail.ch", "proton.me", "pm.me", "tutanota.com", "tutanota.de", "tuta.io",
        "mail.com", "email.com", "fastmail.com", "fastmail.fm", "hey.com", "zoho.com", "yandex.com", "yandex.ru",
        "mail.ru", "qq.com", "163.com", "126.com", "laposte.net", "orange.fr", "free.fr", "libero.it", "virgilio.it",
        "btinternet.com", "sky.com", "virginmedia.com", "comcast.net", "att.net", "verizon.net",
    ]
    /// Brand families with many country TLDs (hotmail.de, yahoo.co.uk, outlook.fr, …).
    static let freeMailFamilies: Set<String> = ["gmail", "hotmail", "outlook", "live", "yahoo", "gmx", "yandex", "windowslive"]
    /// Two-label public suffixes (enough for the corridor this app serves; no network, no full PSL).
    static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk", "me.uk", "net.uk", "sch.uk", "nhs.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp", "ac.jp",
        "com.br", "com.cn", "com.mx", "co.za", "co.in", "com.sg", "com.hk", "com.tr", "co.il", "co.kr", "com.ar",
        "co.at", "or.at", "gv.at", "ac.at", "com.pl", "com.es", "com.pt", "co.it", "com.ua", "co.th", "com.my",
    ]

    public static func domain(of address: String) -> String {
        let a = address.lowercased().trimmingCharacters(in: .whitespaces)
        guard let at = a.lastIndex(of: "@") else { return "" }
        return String(a[a.index(after: at)...]).trimmingCharacters(in: CharacterSet(charactersIn: ".>"))
    }

    public static func registrable(_ domain: String) -> String {
        let labels = domain.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiPartSuffixes.contains(lastTwo) { return labels.suffix(3).joined(separator: ".") }
        return lastTwo
    }

    public static func isFreeMail(registrable r: String) -> Bool {
        if freeMail.contains(r) { return true }
        return freeMailFamilies.contains(r.split(separator: ".").first.map(String.init) ?? "")
    }

    /// Company key for an address: its registrable domain, or nil for free-mail / malformed addresses.
    public static func companyKey(for address: String) -> String? {
        let d = domain(of: address)
        guard d.contains("."), !d.contains(" ") else { return nil }
        let r = registrable(d)
        return isFreeMail(registrable: r) ? nil : r
    }

    /// "acme-industries.ch" → "Acme Industries".
    public static func name(fromDomain r: String) -> String {
        let first = r.split(separator: ".").first.map(String.init) ?? r
        return first.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { w in w.prefix(1).uppercased() + w.dropFirst() }.joined(separator: " ")
    }

    /// Organisation part of a display name: "Anna Meier | Acme AG", "Anna Meier - Acme", "Anna Meier (Acme AG)".
    /// "Meier, Anna" (surname first) is NOT an organisation.
    public static func orgName(fromDisplayName raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespaces)
        if let open = n.lastIndex(of: "("), n.hasSuffix(")") {
            let org = n[n.index(after: open)..<n.index(before: n.endIndex)].trimmingCharacters(in: .whitespaces)
            if org.count >= 2, !org.contains("@"), !org.lowercased().hasPrefix("external") { return org }
        }
        for sep in [" | ", " – ", " - ", " / "] {
            if let r = n.range(of: sep, options: .backwards) {
                let org = n[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if org.count >= 2, !org.contains("@") { return org }
            }
        }
        return nil
    }

    public static func isInternal(_ address: String, internalDomains: Set<String>) -> Bool {
        let d = domain(of: address)
        return internalDomains.contains { d == $0.lowercased() || d.hasSuffix("." + $0.lowercased()) }
    }
}

// MARK: - Decayed tally

/// Count + exponentially decayed weight (half-life `halfLife`). Removal subtracts the same contribution, so a
/// re-upsert or a delete leaves the weight where it would have been without the message (first/last are kept).
public struct Tally: Codable, Sendable, Hashable {
    public static let halfLife: Double = 60 * 86_400
    public var n: Int = 0
    /// Weight valid at `t`.
    var w: Double = 0
    var t: Int64 = 0
    public var first: Int64 = 0
    public var last: Int64 = 0
    enum CodingKeys: String, CodingKey { case n, w, t, first = "f", last = "l" }
    public init() {}

    static func decay(_ dt: Double) -> Double { pow(2, -dt / halfLife) }

    public mutating func add(_ ts: Int64, sign: Int = 1) {
        if sign > 0 {
            if n == 0 || ts < first { first = ts }
            if ts > last { last = ts }
        }
        n = max(0, n + sign)
        if n == 0 { self = Tally(); return }
        let ref = max(t, ts)
        w = w * Self.decay(Double(ref - t)) + Double(sign) * Self.decay(Double(ref - ts))
        if w < 1e-9 { w = 0 }
        t = ref
    }

    public func weight(at now: Int64) -> Double { now >= t ? w * Self.decay(Double(now - t)) : w }
    public var isEmpty: Bool { n == 0 }
    public static func + (a: Tally, b: Tally) -> Tally {
        var r = a
        if b.n == 0 { return r }
        if a.n == 0 { return b }
        let ref = max(a.t, b.t)
        r.w = a.w * decay(Double(ref - a.t)) + b.w * decay(Double(ref - b.t))
        r.t = ref; r.n = a.n + b.n; r.first = min(a.first, b.first); r.last = max(a.last, b.last)
        return r
    }
}

// MARK: - Nodes (sealed payloads)

public enum GraphNodeKind: Int, Sendable, CaseIterable { case person = 1, company = 2, project = 3, conversation = 4, term = 5, meta = 6, mailbox = 7 }

/// A correspondent. Ego-centric: "me" is the mailbox owner, so me↔X lives on X (`fromThem` / `toThem`).
public struct PersonNode: Codable, Sendable, Hashable {
    public var address: String
    public var names: [String: Int] = [:]
    public var company: String?
    public var isInternal = false
    /// Messages from them into the owner's mailboxes.
    public var fromThem = Tally()
    /// Messages the owner sent with them as To/Cc.
    public var toThem = Tally()
    /// Newsletters / notifications from this address (kept out of edges and companies).
    public var bulk = 0
    /// Co-communication (same message: sender↔recipient, co-recipients of small messages, meetings).
    public var neighbours: [String: Tally] = [:]
    public var projects: [String: Int] = [:]
    public var mailboxes: [String: Int] = [:]
    public init(address: String) { self.address = address }
    enum CodingKeys: String, CodingKey { case address = "a", names = "nm", company = "co", isInternal = "in", fromThem = "fr", toThem = "to", bulk = "b", neighbours = "nb", projects = "pj", mailboxes = "mb" }
    public var displayName: String { names.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? address }
    public var total: Tally { fromThem + toThem }
}

public struct CompanyNode: Codable, Sendable, Hashable {
    public var domain: String
    /// Organisation names seen in display names ("… | Acme AG").
    public var names: [String: Int] = [:]
    public var people: [String: Int] = [:]
    public var fromThem = Tally()
    public var toThem = Tally()
    public var projects: [String: Int] = [:]
    public var isInternal = false
    public init(domain: String) { self.domain = domain }
    enum CodingKeys: String, CodingKey { case domain = "d", names = "nm", people = "pp", fromThem = "fr", toThem = "to", projects = "pj", isInternal = "in" }
    public var displayName: String { names.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? MailDomains.name(fromDomain: domain) }
    public var total: Tally { fromThem + toThem }
}

public enum ProjectKind: String, Codable, Sendable, Hashable { case category, folder, topic }

/// Category / folder projects are maintained incrementally; topic projects are vocabulary terms that recur across
/// conversations (their message lists come from the blind index at query time).
public struct ProjectNode: Codable, Sendable, Hashable {
    public var id: String
    public var kind: ProjectKind
    public var name: String
    public var conversations: Int = 0
    public var messages = Tally()
    public var people: [String: Int] = [:]
    public var companies: [String: Int] = [:]
    public var mailboxes: [String: Int] = [:]
    /// Newest conversations first (capped).
    public var recent: [String] = []
    public init(id: String, kind: ProjectKind, name: String) { self.id = id; self.kind = kind; self.name = name }
    enum CodingKeys: String, CodingKey { case id, kind = "k", name = "nm", conversations = "c", messages = "m", people = "pp", companies = "co", mailboxes = "mb", recent = "r" }
}

public struct ConversationNode: Codable, Sendable, Hashable {
    public var id: String
    public var mailbox: String
    public var terms: [String] = []
    public var categories: [String: Int] = [:]
    public var folders: [String: Int] = [:]
    public var people: [String: Int] = [:]
    public var messages = Tally()
    public init(id: String, mailbox: String) { self.id = id; self.mailbox = mailbox }
    enum CodingKeys: String, CodingKey { case id, mailbox = "mb", terms = "tm", categories = "ct", folders = "fd", people = "pp", messages = "m" }
}

/// Local keyed vocabulary: subject term → how many conversations use it, plus its strongest co-terms.
public struct TermNode: Codable, Sendable, Hashable {
    public var term: String
    public var conversations: Int = 0
    public var co: [String: Int] = [:]
    public var last: Int64 = 0
    public init(term: String) { self.term = term }
    enum CodingKeys: String, CodingKey { case term = "t", conversations = "c", co, last = "l" }
}

public struct GraphMeta: Codable, Sendable, Hashable {
    public var conversations = 0
    public var messages = 0
    public init() {}
}

// MARK: - Subject vocabulary

public enum SubjectTerms {
    static let prefixes = ["re:", "aw:", "fw:", "fwd:", "wg:", "tr:", "rif:", "sv:", "vs:", "antw:", "r:", "i:", "[external]", "[extern]", "external:"]
    static let stop: Set<String> = [
        // en
        "the", "and", "for", "you", "your", "with", "from", "this", "that", "are", "was", "will", "have", "has", "our", "not",
        "but", "all", "can", "about", "into", "out", "new", "re", "fw", "fwd", "please", "thanks", "thank", "hello", "regarding",
        "update", "meeting", "call", "info", "information", "request", "question", "today", "tomorrow", "week", "next", "invitation",
        "accepted", "declined", "tentative", "updated", "canceled", "cancelled", "reminder", "automatic", "reply", "out", "office",
        // de
        "der", "die", "das", "und", "für", "fur", "mit", "von", "den", "dem", "des", "ein", "eine", "einen", "ist", "sind", "auf",
        "zum", "zur", "bei", "aus", "wie", "auch", "noch", "nicht", "ihr", "ihre", "wir", "sie", "uns", "aw", "wg", "antwort",
        "anfrage", "termin", "einladung", "bitte", "danke", "info", "betreff", "heute", "morgen", "woche", "nachste", "naechste",
        "angenommen", "abgelehnt", "abgesagt", "mitgliedschaft",
        // fr / it
        "les", "des", "pour", "avec", "une", "dans", "sur", "par", "est", "per", "con", "della", "delle", "che", "una", "del",
    ]

    public static func normalisedSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for p in prefixes where t.lowercased().hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces); changed = true
            }
        }
        return t
    }

    /// Distinct topic-candidate terms of a subject (≤ 8, ≥ 3 chars, no stop words, not purely numeric).
    public static func terms(_ subject: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in BlindIndex.tokenize(normalisedSubject(subject)) where t.count >= 3 && !stop.contains(t)
            && !t.allSatisfy(\.isNumber) && seen.insert(t).inserted {
            out.append(t)
            if out.count == 8 { break }
        }
        return out
    }
}

// MARK: - Capped counters

extension Dictionary where Value == Int {
    /// Add `delta`, drop zero entries, keep at most `cap` keys (lowest counts evicted).
    mutating func bump(_ k: Key, _ delta: Int, cap: Int) {
        let v = (self[k] ?? 0) + delta
        if v <= 0 { removeValue(forKey: k) } else { self[k] = v }
        if count > cap, let victim = self.min(by: { $0.value < $1.value })?.key, victim != k { removeValue(forKey: victim) }
    }
}
