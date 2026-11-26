import Foundation

// VOICE2: learning the voice layers from mail, locally.
// - Detectors (Du/Sie, tu/vous, greeting, sign-off, language) return tokens from closed lists, never mail text.
// - Suggested layers for a new contact / organisation: facts first (metadata + on-device-allowed text only), an
//   optional AI step through AIPromptBuilder fills what the facts leave empty. Never saved without the user.
// - Nudges after the user edits an AI draft, rate-limited; the log stores kinds, keys and dates only.

// MARK: - Detectors (pure, on-device)

public enum VoiceSignals {
    /// Greetings, canonical spelling. Matched at the start of the first content line.
    static let greetings: [String] = [
        "Sehr geehrte Damen und Herren", "Sehr geehrter", "Sehr geehrte", "Guten Morgen", "Guten Tag", "Good morning",
        "Good afternoon", "Grüezi", "Grüessech", "Hoi", "Hallo", "Salü", "Servus", "Liebe", "Lieber", "Hi", "Hello", "Hey",
        "Dear", "Bonjour", "Bonsoir", "Salut", "Chère", "Cher", "Madame", "Monsieur", "Buongiorno", "Buonasera", "Ciao",
        "Gentile", "Caro", "Cara",
    ].sorted { $0.count > $1.count }
    static let formalGreetings: Set<String> = ["Sehr geehrte Damen und Herren", "Sehr geehrter", "Sehr geehrte", "Guten Tag",
                                               "Grüezi", "Grüessech", "Madame", "Monsieur", "Gentile"]
    static let informalGreetings: Set<String> = ["Hi", "Hoi", "Hallo", "Salü", "Servus", "Liebe", "Lieber", "Hey", "Salut", "Ciao", "Caro", "Cara"]

    /// The contact's / user's own words: quoted history, `-- ` signatures and "Sent from my" cut.
    public static func ownText(_ m: MailMessage) -> String {
        let raw = m.body ?? m.preview ?? ""
        return AIUntrustedText.stripQuotedAndSignature(AIUntrustedText.body(raw, isHTML: m.body != nil && m.bodyIsHTML))
    }

    static func contentLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Canonical greeting token ("Hoi", "Sehr geehrte", "Hi") or nil.
    public static func greeting(_ text: String) -> String? {
        guard let first = contentLines(text).first else { return nil }
        let l = first.lowercased()
        for g in greetings {
            let gl = g.lowercased()
            guard l.hasPrefix(gl) else { continue }
            let rest = l.dropFirst(gl.count)
            if rest.isEmpty || !(rest.first!.isLetter) { return g }
        }
        return nil
    }

    /// Canonical sign-off ("Liebe grüsse", "Best regards") from the last lines, or nil.
    public static func signOff(_ text: String) -> String? {
        for l in contentLines(text).suffix(6).reversed() {
            let t = l.lowercased()
            for c in VoiceSignature.closings where t.hasPrefix(c) {
                let rest = t.dropFirst(c.count).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty || [",", "!", "."].contains(rest) || (rest.hasPrefix(",") && rest.count <= 42) {
                    return c.prefix(1).uppercased() + c.dropFirst()
                }
            }
        }
        return nil
    }

    /// DE / FR / IT / EN, nil when short or unclear.
    public static func language(_ text: String) -> AILanguage? {
        switch DraftLanguage.detect(text, minimumLetters: 20, confidence: 0.6) {
        case .de: .de
        case .fr: .fr
        case .it: .it
        case .en: .en
        case nil: nil
        }
    }

    static let deInformal: Set<String> = ["du", "dir", "dich", "dein", "deine", "deinen", "deinem", "deiner", "deines", "euch", "euer", "eure"]
    static let deFormal: Set<String> = ["Sie", "Ihnen", "Ihr", "Ihre", "Ihren", "Ihrem", "Ihrer", "Ihres"]
    static let frInformal: Set<String> = ["tu", "toi", "ton", "ta", "tes", "te"]
    static let frFormal: Set<String> = ["vous", "votre", "vos"]
    static let itInformal: Set<String> = ["tu", "ti", "tuo", "tua", "tuoi", "tue"]
    static let itFormal: Set<String> = ["Lei", "Suo", "Sua", "Suoi", "Sue"]

    /// Du/Sie, tu/vous by whole words (never substrings: "durch", "direkt", "tout"). Formal German / Italian pronouns
    /// count only capitalised and not at the start of a sentence. English (no T-V distinction) and ties → nil.
    public static func formality(_ text: String, language: AILanguage? = nil) -> VoiceFormality? {
        let lang = language ?? Self.language(text)
        if lang == .en { return nil }
        var informal = 0, formal = 0
        if let g = greeting(text) {
            if informalGreetings.contains(g) { informal += 1 } else if formalGreetings.contains(g) { formal += 1 }
        }
        var word = "", sentenceStart = true, wordAtStart = true
        func flush() {
            guard !word.isEmpty else { return }
            let lower = word.lowercased()
            switch lang {
            case .fr?:
                if frInformal.contains(lower) { informal += 1 } else if frFormal.contains(lower) { formal += 1 }
            case .it?:
                if itInformal.contains(lower) { informal += 1 } else if itFormal.contains(word) && !wordAtStart { formal += 1 }
            case .de?:
                if deInformal.contains(lower) { informal += 1 } else if deFormal.contains(word) && !wordAtStart { formal += 1 }
            default:   // unknown language: only unambiguous German / French words
                if ["du", "dir", "dich", "dein", "deine", "deinen", "deinem", "toi", "tu"].contains(lower) { informal += 1 }
                else if (word == "Sie" || word == "Ihnen") && !wordAtStart { formal += 1 }
                else if ["vous", "votre", "vos"].contains(lower) { formal += 1 }
            }
            word = ""
        }
        for ch in text {
            if ch.isLetter {
                if word.isEmpty { wordAtStart = sentenceStart }
                word.append(ch); sentenceStart = false
            } else {
                flush()
                if ".!?:\n".contains(ch) { sentenceStart = true }
            }
        }
        flush()
        if informal == formal { return nil }
        return informal > formal ? .informal : .formal
    }
}

// MARK: - Facts about a counterpart (content-free once computed)

public struct VoiceFacts: Sendable, Hashable {
    public var address: String
    public var displayName: String
    public var title: String?
    public var department: String?
    public var company: String?
    public var isInternal: Bool
    public var received: Int
    public var sent: Int
    public var since: Date?
    public var language: AILanguage?
    public var formality: VoiceFormality?
    public var greeting: String?
    public var signOff: String?
    /// The user's own replies: nil = no gate-allowed reply to look at.
    public var userGreets: Bool?
    public var userSignsOff: Bool?
    /// Messages whose text was read on-device / left out by the label gate.
    public var analysed: Int
    public var skipped: Int

    public init(address: String, displayName: String = "", title: String? = nil, department: String? = nil, company: String? = nil,
                isInternal: Bool = false, received: Int = 0, sent: Int = 0, since: Date? = nil, language: AILanguage? = nil,
                formality: VoiceFormality? = nil, greeting: String? = nil, signOff: String? = nil, userGreets: Bool? = nil,
                userSignsOff: Bool? = nil, analysed: Int = 0, skipped: Int = 0) {
        self.address = address.lowercased(); self.displayName = displayName; self.title = title; self.department = department
        self.company = company; self.isInternal = isInternal; self.received = received; self.sent = sent; self.since = since
        self.language = language; self.formality = formality; self.greeting = greeting; self.signOff = signOff
        self.userGreets = userGreets; self.userSignsOff = userSignsOff; self.analysed = analysed; self.skipped = skipped
    }
}

/// Directory facts (PeopleHub, already in memory; never fetched for this).
public struct VoiceDirectoryFacts: Sendable, Hashable {
    public var title: String?
    public var department: String?
    public var company: String?
    public init(title: String? = nil, department: String? = nil, company: String? = nil) {
        self.title = title; self.department = department; self.company = company
    }
}

public enum VoiceLearn {
    static func majority<T: Hashable>(_ xs: [T]) -> T? {
        let c = Dictionary(xs.map { ($0, 1) }, uniquingKeysWith: +)
        guard let best = c.max(by: { $0.value < $1.value }) else { return nil }
        return c.values.filter { $0 == best.value }.count == 1 ? best.key : nil
    }

    /// FW:/Fwd:/WG:/TR:/I: — forwarded content is someone else's voice.
    public static func isForward(_ subject: String?) -> Bool {
        let l = (subject ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        return ["fw:", "fwd:", "wg:", "tr:", "i:", "rv:"].contains { l.hasPrefix($0) }
    }

    /// Du/Sie only means something in the language they actually write to the user in. Formal needs clear evidence
    /// (≥ 2 votes, ≥ 2/3) in that language; an internal colleague or an informal greeting ("Hi", "Hoi") otherwise means
    /// informal — Swiss workplaces use Du with colleagues (owner: a colleague writing English with "Hi" was marked Sie).
    public static func decideFormality(language: AILanguage?, theirs: [(AILanguage, VoiceFormality)], mine: [(AILanguage, VoiceFormality)],
                                       greeting: String?, isInternal: Bool) -> VoiceFormality? {
        let informalGreeting = greeting.map { VoiceSignals.informalGreetings.contains($0) } ?? false
        func verdict(_ votes: [VoiceFormality]) -> VoiceFormality? {
            let f = votes.filter { $0 == .formal }.count, i = votes.count - f
            if f >= 2 && f * 3 >= votes.count * 2 { return .formal }
            if i >= 1 && i >= f { return .informal }
            return nil
        }
        if let lang = language, lang != .en {
            let v = verdict(theirs.filter { $0.0 == lang }.map(\.1)) ?? verdict(mine.filter { $0.0 == lang }.map(\.1))
            if let v { return v }
        }
        return (isInternal || informalGreeting) ? .informal : nil
    }

    /// Text is read only where the gate allows content on the on-device tier; private mail is never counted.
    public static func facts(address: String, displayName: String, directory: VoiceDirectoryFacts?, internalDomains: Set<String>,
                             received: [MailMessage], sent: [MailMessage], mailbox: String, gate: AIGatePolicy,
                             textLimit: Int = 12) -> VoiceFacts {
        let a = address.lowercased()
        let r = received.filter { !$0.isPrivate && !$0.isDraft && $0.from?.address.lowercased() == a }
        let s = sent.filter { !$0.isPrivate && !$0.isDraft }
        var f = VoiceFacts(address: a, displayName: displayName, isInternal: PeopleHistory.isInternal(a, internalDomains: internalDomains),
                           received: r.count, sent: s.count, since: (r + s).map(\.received).min())
        if let d = directory {
            func clean(_ x: String?) -> String? { x.map { AIUntrustedText.line($0, max: 80) }.flatMap { $0.isEmpty ? nil : $0 } }
            f.title = clean(d.title); f.department = clean(d.department); f.company = clean(d.company)
        }
        var langs: [AILanguage] = [], forms: [(AILanguage, VoiceFormality)] = [], greets: [String] = [], offs: [String] = []
        var userGreet: [Bool] = [], userOff: [Bool] = [], userForms: [(AILanguage, VoiceFormality)] = []
        for m in r.sorted(by: { $0.received > $1.received }).prefix(textLimit) {
            guard gate.exposure(m, mailbox: mailbox, tier: .onDevice) == .content else { f.skipped += 1; continue }
            let t = VoiceSignals.ownText(m)
            guard !t.isEmpty else { continue }
            f.analysed += 1
            let l = VoiceSignals.language(t)
            if let l { langs.append(l) }
            // Forwards carry someone else's register (a customer's "Sie" forwarded by a colleague): never evidence.
            if !VoiceLearn.isForward(m.subject), let l, let fm = VoiceSignals.formality(t, language: l) { forms.append((l, fm)) }
            if let g = VoiceSignals.greeting(t) { greets.append(g) }
            if m.body != nil, let o = VoiceSignals.signOff(t) { offs.append(o) }   // a preview rarely reaches the sign-off
        }
        for m in s.sorted(by: { $0.received > $1.received }).prefix(textLimit) {
            guard gate.exposure(m, mailbox: mailbox, tier: .onDevice) == .content else { f.skipped += 1; continue }
            let t = VoiceSignals.ownText(m)
            guard !t.isEmpty else { continue }
            f.analysed += 1
            userGreet.append(VoiceSignals.greeting(t) != nil)
            if m.body != nil { userOff.append(VoiceSignals.signOff(t) != nil) }   // previews: no sign-off evidence
            if !VoiceLearn.isForward(m.subject), let l = VoiceSignals.language(t), let fm = VoiceSignals.formality(t, language: l) {
                userForms.append((l, fm))   // the user's register with them
            }
        }
        f.language = majority(langs)
        f.greeting = majority(greets); f.signOff = majority(offs)
        f.formality = Self.decideFormality(language: f.language, theirs: forms, mine: userForms, greeting: f.greeting,
                                           isInternal: f.isInternal)
        if !userGreet.isEmpty { f.userGreets = userGreet.filter { $0 }.count * 2 > userGreet.count }
        if !userOff.isEmpty { f.userSignsOff = userOff.filter { $0 }.count * 2 > userOff.count }
        return f
    }

    static func month(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }

    static func languageName(_ l: AILanguage) -> String {
        switch l { case .de: "German"; case .fr: "French"; case .it: "Italian"; case .en: "English"; case .auto: "" }
    }

    /// First name from a display name ("Muster, Anna" → "Anna"; "Anna Muster (Northwind)" → "Anna").
    static func firstName(_ display: String) -> String? {
        var n = display.replacingOccurrences(of: "\\s*[\\(\\[].*$", with: "", options: .regularExpression)
        if let comma = n.firstIndex(of: ",") { n = String(n[n.index(after: comma)...]) }
        let first = n.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        return first.count >= 2 && first.allSatisfy({ $0.isLetter || $0 == "-" }) ? first : nil
    }

    /// Contact layer from facts only. Fields without a fact are left out (never guessed).
    public static func suggestedContact(_ f: VoiceFacts) -> VoiceContact {
        var notes: [(String, String)] = []
        let role = [f.title, f.department].compactMap { $0 }.joined(separator: ", ")
        if !role.isEmpty { notes.append(("Role", role + (f.company.map { f.isInternal ? "" : " at \($0)" } ?? ""))) }
        var address: [String] = []
        if let fm = f.formality { address.append(fm == .informal ? "Du / tu (informal)" : "Sie / vous (formal)") }
        if let g = f.greeting { address.append("they open with “\(g)”") }
        if !address.isEmpty { notes.append(("Address", address.joined(separator: "; "))) }
        var style: [String] = []
        if let o = f.signOff { style.append("they sign off with “\(o)”") }
        if let g = f.userGreets { style.append(g ? "you usually greet them" : "you usually write to them without a greeting") }
        if let o = f.userSignsOff, !o { style.append("you usually skip the sign-off") }
        if !style.isEmpty { notes.append(("Style", style.joined(separator: "; "))) }
        if let l = f.language { notes.append(("Language", "writes in \(languageName(l))")) }
        var remember = [f.isInternal ? "internal colleague" : "external"]
        if f.received + f.sent > 0 {
            remember.append("\(f.received) mail\(f.received == 1 ? "" : "s") from them, \(f.sent) from you"
                            + (f.since.map { " since \(month($0))" } ?? ""))
        }
        notes.append(("Remember", remember.joined(separator: "; ")))
        return VoiceContact(address: f.address, displayName: f.displayName,
                            addressAs: f.formality == .informal ? (firstName(f.displayName) ?? "") : "",
                            language: f.language ?? .auto, formality: f.formality ?? .auto, notes: render(notes))
    }

    /// Organisation layer from the facts of its contacts (free-mail domains: none).
    public static func suggestedOrg(key: String, displayName: String?, contacts: [VoiceFacts]) -> VoiceOrg? {
        let k = key.lowercased()
        guard !k.isEmpty, !MailDomains.isFreeMail(registrable: k) else { return nil }
        let company = majority(contacts.compactMap(\.company)) ?? contacts.compactMap(\.company).first
        let name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? company ?? MailDomains.name(fromDomain: k)
        let lang = majority(contacts.compactMap(\.language))
        let forms = Set(contacts.compactMap(\.formality))
        var notes: [(String, String)] = []
        if let c = company { notes.append(("Who they are", c)) }
        let internalOrg = !contacts.isEmpty && contacts.allSatisfy(\.isInternal)
        let total = contacts.reduce(0) { $0 + $1.received + $1.sent }
        var rel = [internalOrg ? "your own organisation" : "external organisation"]
        if total > 0, let since = contacts.compactMap(\.since).min() { rel.append("\(total) mails since \(month(since))") }
        notes.append(("Relationship", rel.joined(separator: "; ")))
        if let lang { notes.append(("Language", "usually \(languageName(lang))")) }
        if forms.count == 1, let fm = forms.first { notes.append(("Tone", fm == .informal ? "Du / tu" : "Sie / vous")) }
        return VoiceOrg(key: k, displayName: name, language: lang ?? .auto, formality: forms.count == 1 ? forms.first! : .auto,
                        notes: render(notes))
    }

    public static let contactFields = ["Role", "Address", "Style", "Language", "Remember"]
    public static let orgFields = ["Who they are", "Relationship", "Language", "Tone", "Topics", "Avoid"]

    static func render(_ fields: [(String, String)]) -> String { fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n") }

    /// "Field: value" lines → ordered pairs (other lines are kept under "").
    static func parseNotes(_ notes: String) -> [(String, String)] {
        notes.components(separatedBy: "\n").compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            if let c = t.firstIndex(of: ":") { return (String(t[..<c]), String(t[t.index(after: c)...]).trimmingCharacters(in: .whitespaces)) }
            return ("", t)
        }
    }

    /// Fills fields the facts left empty with the AI's values (facts always win); unknown keys and empty values dropped.
    public static func merge(notes: String, ai: [String: String], fields: [String]) -> String {
        var have = parseNotes(notes)
        let known = Set(have.map(\.0))
        for f in fields where !known.contains(f) {
            if let v = ai[f]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { have.append((f, v)) }
        }
        let order = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($1, $0) })
        let indexed = have.enumerated().map { ($0, $1) }
        return render(indexed.sorted { ((order[$0.1.0] ?? 99), $0.0) < ((order[$1.1.0] ?? 99), $1.0) }.map(\.1))
    }
}

// MARK: - Optional AI step (gated exactly like draftReplyInVoice)

public extension AIAssistant {
    /// Template fields for a suggested layer from gate-admitted excerpts. Throws without a provider call when nothing
    /// is shareable as content on the routed tier. On-device facts (language, Du/Sie) are never put in this prompt.
    func suggestVoiceNotes(organisation: Bool, title: String, messages: [MailMessage], mailbox: String) async throws -> [String: String] {
        let p = try provider(.draftReply)
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        b.perItemLimit = 1_200
        for m in messages.sorted(by: { $0.received > $1.received }).prefix(8) where !m.isDraft { _ = b.add(m, mailbox: mailbox, role: "excerpt") }
        let fields = organisation ? VoiceLearn.orgFields : VoiceLearn.contactFields
        let system = """
            You prepare notes that help the user write emails to \(organisation ? "an organisation" : "one person"). \
            Fill the fields from the email excerpts only. Never invent: if the excerpts don't show something, return an \
            empty string for that field. One short line per field, in British English. Never quote the emails, never \
            include phone numbers, addresses, prices or personal details beyond a role. Formality (Du/Sie, tu/vous) \
            describes how this person and the user address EACH OTHER: ignore forwarded or quoted text written by \
            third parties (e.g. a customer's "Sie" in a forward); colleagues in the user's own organisation use Du \
            unless their own words clearly show Sie; for people who write in English, say "English, first names". \
            Output ONLY JSON with exactly \
            these keys: \(fields.map { "\"\($0)\"" }.joined(separator: ", ")).
            """
        let task = "Subject of the notes: \(AIPromptBuilder.neutralise(AIUntrustedText.line(title, max: 80))). " +
            "Emails with role=excerpt are recent mail with them (newest first)."
        let prompt = b.build(system: system, task: task)
        guard prompt.contentCount > 0 else {
            throw AIAssistError.notAllowed("None of these messages can be shared with AI (label or organisation policy)")
        }
        let out = try await call(.draftReply, p, prompt, maxTokens: 500)
        guard let o = AIOutput.json(out) as? [String: Any] else { return [:] }
        var res: [String: String] = [:]
        for f in fields {
            guard let v = o[f] as? String else { continue }
            let t = AIUntrustedText.line(v, max: 160)
            if !t.isEmpty, !["unknown", "n/a", "none", "-"].contains(t.lowercased()) { res[f] = t }
        }
        return res
    }
}

// MARK: - Edits to an AI draft, nudges

public enum VoiceEditKind: String, Codable, Sendable, CaseIterable {
    case removedGreeting, removedSignOff, toFormal, toInformal, changedLanguage, shortened
    /// The thread disagrees with the stored layer.
    case threadFormality, threadLanguage
}

public struct VoiceEdit: Sendable, Hashable {
    public var kinds: [VoiceEditKind]
    /// Target language for `.changedLanguage`.
    public var language: AILanguage?
    public init(kinds: [VoiceEditKind] = [], language: AILanguage? = nil) { self.kinds = kinds; self.language = language }
}

public enum VoiceEditDiff {
    /// Both sides normalised the same way (configured signature, quoted history, `-- ` blocks cut).
    public static func normalise(_ text: String, signaturePlain: String?) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: RichRun.lineBreak, with: "\n")
        if let s = signaturePlain?.replacingOccurrences(of: RichRun.lineBreak, with: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
           s.count >= 3, let r = t.range(of: s, options: .backwards) {
            t.removeSubrange(r)
        }
        return AIUntrustedText.stripQuotedAndSignature(t)
    }

    public static func compare(draft: String, sent: String) -> VoiceEdit {
        var e = VoiceEdit()
        if VoiceSignals.greeting(draft) != nil && VoiceSignals.greeting(sent) == nil { e.kinds.append(.removedGreeting) }
        if VoiceSignals.signOff(draft) != nil && VoiceSignals.signOff(sent) == nil { e.kinds.append(.removedSignOff) }
        let ld = VoiceSignals.language(draft), ls = VoiceSignals.language(sent)
        if let ld, let ls, ld != ls { e.kinds.append(.changedLanguage); e.language = ls }
        else if let fd = VoiceSignals.formality(draft, language: ld), let fs = VoiceSignals.formality(sent, language: ls ?? ld), fd != fs {
            e.kinds.append(fs == .formal ? .toFormal : .toInformal)
        }
        let a = draft.filter(\.isLetter).count, b = sent.filter(\.isLetter).count
        if a >= 80, b > 0, Double(b) < Double(a) * 0.6 { e.kinds.append(.shortened) }
        return e
    }
}

/// Persisted nudge state: kinds, keys (addresses / org keys / "me") and dates. Never mail text.
public struct VoiceNudgeLog: Codable, Sendable, Hashable {
    public static let storeKey = "ai.voice.nudges"
    public static let me = "me"
    public struct Event: Codable, Sendable, Hashable {
        public var kind: VoiceEditKind
        public var contact: String
        public var at: Date
    }
    public var events: [Event] = []
    public var lastShown: [String: Date] = [:]
    /// "Don't suggest for this contact" (address, org key or "me").
    public var muted: Set<String> = []
    /// Suggested layers dismissed ("contact:<address>", "org:<key>").
    public var dismissed: Set<String> = []
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        events = (try? c.decodeIfPresent([Event].self, forKey: .events)) ?? []
        lastShown = (try? c.decodeIfPresent([String: Date].self, forKey: .lastShown)) ?? [:]
        muted = (try? c.decodeIfPresent(Set<String>.self, forKey: .muted)) ?? []
        dismissed = (try? c.decodeIfPresent(Set<String>.self, forKey: .dismissed)) ?? []
    }
}

public extension MailStore {
    func voiceNudgeLog() -> VoiceNudgeLog { sealed(VoiceNudgeLog.self, for: VoiceNudgeLog.storeKey) ?? VoiceNudgeLog() }
    func save(voiceNudgeLog l: VoiceNudgeLog) throws { try setSealed(l, for: VoiceNudgeLog.storeKey) }
}

public struct VoiceNudge: Sendable, Hashable {
    public enum Target: Sendable, Hashable { case contact(address: String, name: String), me }
    public var kind: VoiceEditKind
    public var target: Target
    public var language: AILanguage?
    public var text: String
    /// Canned line added to the layer's notes, or nil when a field is set instead.
    public var prefill: String? {
        switch kind {
        case .removedGreeting: "Greeting: none, get straight to the point"
        case .removedSignOff: "Sign-off: none"
        case .shortened: "Length: much shorter than a usual draft"
        default: nil
        }
    }
    public var key: String { if case .contact(let a, _) = target { a } else { VoiceNudgeLog.me } }

    /// The layer with the change applied, for the editor (the user still saves).
    public func applied(to c: VoiceContact) -> VoiceContact {
        var c = c
        switch kind {
        case .toFormal: c.formality = .formal
        case .toInformal: c.formality = .informal
        case .threadFormality: c.formality = c.formality == .formal ? .informal : .formal
        case .changedLanguage, .threadLanguage: if let l = language { c.language = l }
        default: break
        }
        if let line = prefill, !c.notes.contains(line) {
            let n = c.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            c.notes = n.isEmpty ? line : n + "\n" + line
        }
        return c
    }

    public func applied(toMe me: String) -> String {
        let line: String
        switch kind {
        case .removedGreeting: line = "- Usually no greeting: I get straight to the point."
        case .removedSignOff: line = "- Usually no sign-off."
        case .shortened: line = "- Keep drafts much shorter."
        case .toFormal, .threadFormality: line = "- Default to the formal register (Sie / vous)."
        case .toInformal: line = "- Default to the informal register (Du / tu)."
        case .changedLanguage, .threadLanguage: line = "- I usually write in \(language.map(VoiceLearn.languageName) ?? "my own language")."
        }
        return me.contains(line) ? me : me.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + line
    }
}

public enum VoiceNudges {
    public static let interval: TimeInterval = 30 * 86_400
    public static let window: TimeInterval = 90 * 86_400
    public static let meThreshold = 3
    public static let staleAfter: TimeInterval = 180 * 86_400
    public static let staleMails = 10
    static let maxEvents = 300

    static func text(_ k: VoiceEditKind, name: String, me: Bool, language: AILanguage?) -> String {
        let who = me ? "your own voice" : name
        switch k {
        case .removedGreeting: return me ? "You keep removing the greeting — update your own voice?" : "You removed the greeting — remember that for \(name)?"
        case .removedSignOff: return me ? "You keep removing the sign-off — update your own voice?" : "You removed the sign-off — remember that for \(name)?"
        case .toFormal: return "You switched to Sie / vous — remember that for \(who)?"
        case .toInformal: return "You switched to Du / tu — remember that for \(who)?"
        case .changedLanguage: return "You rewrote it in \(language.map(VoiceLearn.languageName) ?? "another language") — remember that for \(who)?"
        case .shortened: return me ? "You keep shortening drafts a lot — update your own voice?" : "You shortened the draft a lot — remember that for \(name)?"
        case .threadFormality: return "This thread's Du / Sie differs from your voice for \(name) — update it?"
        case .threadLanguage: return "This thread is in \(language.map(VoiceLearn.languageName) ?? "another language"), unlike your voice for \(name) — update it?"
        }
    }

    static func allowed(_ key: String, _ log: VoiceNudgeLog, now: Date) -> Bool {
        !log.muted.contains(key) && (log.lastShown[key].map { now.timeIntervalSince($0) >= interval } ?? true)
    }

    static func prune(_ log: inout VoiceNudgeLog, now: Date) {
        log.events.removeAll { now.timeIntervalSince($0.at) > window }
        if log.events.count > maxEvents { log.events.removeFirst(log.events.count - maxEvents) }
    }

    /// Records every edit (so the "≥3 contacts → Me" count works even while a contact is rate-limited), then decides
    /// on at most one nudge and stamps it as shown.
    public static func afterSend(_ e: VoiceEdit, contact: String, name: String, log: inout VoiceNudgeLog, now: Date) -> VoiceNudge? {
        let a = contact.lowercased()
        prune(&log, now: now)
        for k in e.kinds { log.events.append(.init(kind: k, contact: a, at: now)) }
        let order: [VoiceEditKind] = [.toFormal, .toInformal, .changedLanguage, .removedGreeting, .removedSignOff, .shortened]
        for k in order where e.kinds.contains(k) {
            let contacts = Set(log.events.filter { $0.kind == k }.map(\.contact))
            // ≥ 3 contacts → Me first; Me muted or rate-limited → still offer it for this contact.
            let targets: [Bool] = contacts.count >= meThreshold && k != .changedLanguage ? [true, false] : [false]
            for me in targets {
                let target: VoiceNudge.Target = me ? .me : .contact(address: a, name: name)
                let n = VoiceNudge(kind: k, target: target, language: e.language, text: text(k, name: name, me: me, language: e.language))
                if allowed(n.key, log, now: now) { log.lastShown[n.key] = now; return n }
            }
        }
        return nil
    }

    /// The thread disagrees with the stored contact layer (Du/Sie or language set explicitly, not "mirror").
    public static func mismatch(layer: VoiceContact?, observedFormality: VoiceFormality?, observedLanguage: AILanguage?,
                                name: String, log: inout VoiceNudgeLog, now: Date) -> VoiceNudge? {
        guard let c = layer else { return nil }
        var n: VoiceNudge?
        if let f = observedFormality, c.formality != .auto, f != c.formality {
            n = VoiceNudge(kind: .threadFormality, target: .contact(address: c.address, name: name), language: nil,
                           text: text(.threadFormality, name: name, me: false, language: nil))
        } else if let l = observedLanguage, c.language != .auto, l != c.language {
            n = VoiceNudge(kind: .threadLanguage, target: .contact(address: c.address, name: name), language: l,
                           text: text(.threadLanguage, name: name, me: false, language: l))
        }
        guard let n, allowed(n.key, log, now: now) else { return nil }
        log.lastShown[n.key] = now
        return n
    }

    /// Older than 180 days with ≥ 10 mails since: "Review voice" in the Voice menu. Never-stamped layers aren't stale.
    public static func needsReview(updated: Date?, mailsSince: Int, now: Date) -> Bool {
        guard let u = updated else { return false }
        return now.timeIntervalSince(u) > staleAfter && mailsSince >= staleMails
    }
}

// MARK: - Signature import from Sent Items (pure)

public struct SignatureSample: Sendable, Hashable {
    public var id: String
    public var from: String
    public var html: String?
    public var plain: String?
    public var received: Date
    public init(id: String, from: String, html: String? = nil, plain: String? = nil, received: Date) {
        self.id = id; self.from = from.lowercased(); self.html = html; self.plain = plain; self.received = received
    }
}

public struct SignatureProposal: Sendable, Hashable {
    public var identity: String
    /// The proposed block (rich: links, formatting, `cid:` images kept as RichImage).
    public var doc: RichDoc
    public var lines: [String]
    /// Mails containing it / mails looked at for this identity.
    public var support: Int
    public var total: Int
    /// Newest mail carrying it: its inline images supply the bytes for the `cid:`s.
    public var exemplarId: String
    public var cids: [String] { doc.images.map(\.cid) }
}

public enum SignatureLearn {
    static let quoteHeaders = [
        "^On .{4,200} wrote:\\s*$", "^Am .{4,200} schrieb .{1,200}:\\s*$", "^Le .{4,200} a écrit\\s*:\\s*$",
        "^Il giorno .{4,200} ha scritto:\\s*$", "^-{2,}\\s*(Original Message|Ursprüngliche Nachricht|Message d'origine|Messaggio originale)\\s*-{2,}",
        "^_{10,}\\s*$", "^(From|Von|De|Da):\\s.+$",
    ]

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: RichRun.objectReplacement, with: " [image] ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func isQuoteHeader(_ l: String) -> Bool {
        quoteHeaders.contains { l.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// The sample as blocks: HTML parsed (Outlook / Gmail / Apple quote containers cut), quoted history cut at the
    /// first reply header or quote. `-- ` and "Sent from my" are kept: they are what a signature looks like.
    static func blocks(_ s: SignatureSample) -> [RichBlock] {
        var bs: [RichBlock]
        if let h = s.html, !h.isEmpty {
            bs = RichHTML.parse(AIUntrustedText.stripQuotedHTML(h), makeCID: { UUID().uuidString }).doc.blocks
        } else {
            bs = RichDoc.plain(s.plain ?? "").blocks
        }
        var out: [RichBlock] = []
        for b in bs {
            if b.kind == .quote { break }
            let first = norm(b.text.components(separatedBy: RichRun.lineBreak).first ?? "")
            if isQuoteHeader(first) || first.hasPrefix(">") { break }
            out.append(b)
        }
        return out
    }

    static func lines(_ b: RichBlock) -> [String] {
        b.text.components(separatedBy: RichRun.lineBreak).map(norm).filter { !$0.isEmpty }
    }

    /// Longest run of trailing lines shared by ≥ `share` of the samples (indices of the samples carrying it).
    public static func commonSuffix(_ docs: [[String]], share: Double = 0.6, minSamples: Int = 3) -> (lines: [String], members: [Int])? {
        guard docs.count >= minSamples else { return nil }
        let need = max(minSamples, Int((Double(docs.count) * share).rounded(.up)))
        var best: (lines: [String], members: [Int])?
        var k = 1
        while true {
            var groups: [[String]: [Int]] = [:]
            for (i, d) in docs.enumerated() where d.count >= k { groups[Array(d.suffix(k)), default: []].append(i) }
            guard let top = groups.max(by: { $0.value.count < $1.value.count }), top.value.count >= need else { break }
            best = (top.key, top.value.sorted())
            k += 1
        }
        return best
    }

    /// Per identity (the most frequent sender among the samples): the common trailing block, if it looks like a signature.
    public static func propose(_ samples: [SignatureSample]) -> SignatureProposal? {
        let byFrom = Dictionary(grouping: samples, by: \.from)
        guard let (identity, mine) = byFrom.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }) else { return nil }
        let sorted = mine.sorted { $0.received > $1.received }
        let docBlocks = sorted.map(blocks)
        let docLines = docBlocks.map { $0.flatMap(lines) }
        // A quarter is enough: mails sent from niivo before a signature existed, phone replies and one-liners all
        // lack it (owner's import found no 60 % majority, 2026-11-20). The block must still recur ≥ 3 times.
        let found0 = commonSuffix(docLines, share: 0.25, minSamples: 3)
        FileHandle.standardError.write(Data("[SigLearn] samples=\(samples.count) identity=\(mine.count) withLines=\(docLines.filter { !$0.isEmpty }.count) support=\(found0?.members.count ?? 0) lines=\(found0?.lines.count ?? 0)\n".utf8))
        guard let found = found0, found.lines.joined().count >= 12 || found.lines.count >= 2 else { return nil }
        // Exemplar: newest member, preferring one written in HTML (formatting, links, images).
        let ex = found.members.first { sorted[$0].html != nil } ?? found.members[0]
        var need = found.lines.count
        var picked: [RichBlock] = []
        for b in docBlocks[ex].reversed() where need > 0 {
            let ls = lines(b)
            if ls.isEmpty { if !picked.isEmpty { picked.insert(RichBlock(), at: 0) }; continue }
            if ls.count <= need { picked.insert(b, at: 0); need -= ls.count; continue }
            picked.insert(trimLeadingLines(b, keep: need), at: 0); need = 0
        }
        while picked.first?.isEmpty == true { picked.removeFirst() }
        let doc = RichDoc(picked.map { var b = $0; b.signature = false; return b }).normalised()
        return SignatureProposal(identity: identity, doc: doc, lines: found.lines, support: found.members.count, total: sorted.count,
                                 exemplarId: sorted[ex].id)
    }

    /// Keeps only the last `keep` non-empty lines of a block (its runs cut at line breaks).
    static func trimLeadingLines(_ b: RichBlock, keep: Int) -> RichBlock {
        var segs: [[RichRun]] = [[]]
        for r in b.runs {
            if r.image != nil { segs[segs.count - 1].append(r); continue }
            let parts = r.text.components(separatedBy: RichRun.lineBreak)
            for (i, p) in parts.enumerated() {
                if i > 0 { segs.append([]) }
                if !p.isEmpty { segs[segs.count - 1].append(RichRun(p, r.style)) }
            }
        }
        var kept: [[RichRun]] = [], n = 0
        for s in segs.reversed() {
            let nonEmpty = !norm(s.map(\.text).joined()).isEmpty
            if nonEmpty { if n == keep { break }; n += 1 }
            kept.insert(s, at: 0)
        }
        var out = b
        out.runs = kept.enumerated().flatMap { i, s in i == 0 ? s : [RichRun(RichRun.lineBreak)] + s }
        return out
    }
}
