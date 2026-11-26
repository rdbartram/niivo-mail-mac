import Foundation

// MARK: - Voice layers (Me → Organisation → Contact), sealed at rest like templates and signatures

/// Du/Sie, tu/vous. `auto` mirrors the thread.
public enum VoiceFormality: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, informal, formal
    public var id: String { rawValue }
    public var title: String {
        switch self { case .auto: "Mirror the thread"; case .informal: "Informal (Du / tu)"; case .formal: "Formal (Sie / vous)" }
    }
    var instruction: String {
        switch self {
        case .auto: "mirror the thread (Du/Sie, tu/vous, first name or surname as they use it)"
        case .informal: "informal (Du in German, tu in French/Italian, first names)"
        case .formal: "formal (Sie in German, vous in French, Lei in Italian, polite address)"
        }
    }
}

/// One customer organisation, keyed by `MailDomains.companyKey` (the registrable domain, e.g. "contoso.ch").
public struct VoiceOrg: Codable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var displayName: String
    public var language: AILanguage
    public var formality: VoiceFormality
    /// Relationship notes, tone, things to remember (free text, the user's own).
    public var notes: String
    /// VOICE2: last saved by the user (nil = never stamped: an old layer is never flagged as stale).
    public var updated: Date?

    public init(key: String, displayName: String = "", language: AILanguage = .auto, formality: VoiceFormality = .auto,
                notes: String = VoiceDefaults.organisationTemplate, updated: Date? = nil) {
        self.key = key.lowercased().trimmingCharacters(in: .whitespaces)
        self.displayName = displayName; self.language = language; self.formality = formality; self.notes = notes
        self.updated = updated
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = (try c.decodeIfPresent(String.self, forKey: .key) ?? "").lowercased()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        language = (try? c.decodeIfPresent(AILanguage.self, forKey: .language)) ?? .auto
        formality = (try? c.decodeIfPresent(VoiceFormality.self, forKey: .formality)) ?? .auto
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        updated = try? c.decodeIfPresent(Date.self, forKey: .updated)
    }

    /// Display title: the name, or one derived from the domain.
    public var title: String {
        let n = displayName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? MailDomains.name(fromDomain: key) : n
    }
}

/// One person, keyed by email address (lowercased).
public struct VoiceContact: Codable, Sendable, Hashable, Identifiable {
    public var id: String { address }
    public var address: String
    public var displayName: String
    /// How to address them in the greeting ("Zoé", "Frau Muster"); empty = mirror the thread.
    public var addressAs: String
    public var language: AILanguage
    public var formality: VoiceFormality
    public var notes: String
    /// VOICE2: last saved by the user (nil = never stamped: an old layer is never flagged as stale).
    public var updated: Date?

    public init(address: String, displayName: String = "", addressAs: String = "", language: AILanguage = .auto,
                formality: VoiceFormality = .auto, notes: String = VoiceDefaults.contactTemplate, updated: Date? = nil) {
        self.address = address.lowercased().trimmingCharacters(in: .whitespaces)
        self.displayName = displayName; self.addressAs = addressAs; self.language = language; self.formality = formality
        self.notes = notes; self.updated = updated
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        address = (try c.decodeIfPresent(String.self, forKey: .address) ?? "").lowercased()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        addressAs = try c.decodeIfPresent(String.self, forKey: .addressAs) ?? ""
        language = (try? c.decodeIfPresent(AILanguage.self, forKey: .language)) ?? .auto
        formality = (try? c.decodeIfPresent(VoiceFormality.self, forKey: .formality)) ?? .auto
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        updated = try? c.decodeIfPresent(Date.self, forKey: .updated)
    }

    public var title: String {
        for s in [addressAs, displayName] {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return address.split(separator: "@").first.map(String.init) ?? address
    }
}

/// All voice layers. Separate sealed key (`ai.voice`): never inside `AIAssistSettings` (synthesised Codable).
public struct VoiceProfile: Codable, Sendable, Hashable {
    public static let storeKey = "ai.voice"
    public var me: String
    public var orgs: [VoiceOrg]
    public var contacts: [VoiceContact]

    public init(me: String = VoiceDefaults.me, orgs: [VoiceOrg] = [], contacts: [VoiceContact] = []) {
        self.me = me; self.orgs = orgs; self.contacts = contacts
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let saved = try c.decodeIfPresent(String.self, forKey: .me)
        me = (saved == nil || saved == VoiceDefaults.meV1) ? VoiceDefaults.me : saved!   // untouched old default → new
        orgs = (try? c.decodeIfPresent([VoiceOrg].self, forKey: .orgs)) ?? []
        contacts = (try? c.decodeIfPresent([VoiceContact].self, forKey: .contacts)) ?? []
    }

    public var meIsDefault: Bool { me == VoiceDefaults.me }
    public mutating func resetMe() { me = VoiceDefaults.me }

    public func org(key: String?) -> VoiceOrg? {
        guard let k = key?.lowercased(), !k.isEmpty else { return nil }
        return orgs.first { $0.key == k }
    }
    public func org(forAddress a: String?) -> VoiceOrg? { org(key: a.flatMap { MailDomains.companyKey(for: $0) }) }
    public func contact(address a: String?) -> VoiceContact? {
        guard let a = a?.lowercased().trimmingCharacters(in: .whitespaces), !a.isEmpty else { return nil }
        return contacts.first { $0.address == a }
    }

    public mutating func upsert(_ o: VoiceOrg) {
        guard !o.key.isEmpty else { return }
        if let i = orgs.firstIndex(where: { $0.key == o.key }) { orgs[i] = o } else { orgs.append(o) }
        orgs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    public mutating func upsert(_ c: VoiceContact) {
        guard c.address.contains("@") else { return }
        if let i = contacts.firstIndex(where: { $0.address == c.address }) { contacts[i] = c } else { contacts.append(c) }
        contacts.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    public mutating func removeOrg(key: String) { orgs.removeAll { $0.key == key.lowercased() } }
    public mutating func removeContact(address: String) { contacts.removeAll { $0.address == address.lowercased() } }

    /// Me → Organisation of the counterpart → Contact. More specific wins: language and formality resolve in code
    /// (per-draft language choice > Contact > Organisation > mirror the thread), and the prompt states the result.
    public func resolve(counterpart: String?, languageOverride: AILanguage = .auto) -> VoiceResolution {
        let org = org(forAddress: counterpart)
        let contact = contact(address: counterpart)
        var layers = [VoiceResolution.Layer(kind: .me, title: "Me", text: me)]
        if let org { layers.append(.init(kind: .organisation, title: org.title, text: Self.describe(org))) }
        if let contact { layers.append(.init(kind: .contact, title: contact.title, text: Self.describe(contact))) }

        var language = AILanguage.auto, languageFrom = "thread"
        if languageOverride != .auto { language = languageOverride; languageFrom = "your choice for this draft" }
        else if let l = contact?.language, l != .auto { language = l; languageFrom = "Contact" }
        else if let l = org?.language, l != .auto { language = l; languageFrom = "Organisation" }
        var formality = VoiceFormality.auto, formalityFrom = "thread"
        if let f = contact?.formality, f != .auto { formality = f; formalityFrom = "Contact" }
        else if let f = org?.formality, f != .auto { formality = f; formalityFrom = "Organisation" }
        let addressAs = contact.flatMap { $0.addressAs.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.addressAs }
        return VoiceResolution(layers: layers, language: language, languageFrom: languageFrom, formality: formality,
                               formalityFrom: formalityFrom, addressAs: addressAs, orgKey: org?.key,
                               counterpart: counterpart?.lowercased())
    }

    static func describe(_ o: VoiceOrg) -> String {
        var s = "Organisation: \(o.title)\n"
        if o.language != .auto { s += "Default language: \(o.language.title)\n" }
        if o.formality != .auto { s += "Formality: \(o.formality.title)\n" }
        let n = o.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { s += "Notes:\n\(n)" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func describe(_ c: VoiceContact) -> String {
        var s = "Contact: \(c.title)\n"
        if !c.addressAs.trimmingCharacters(in: .whitespaces).isEmpty { s += "Address them as: \(c.addressAs)\n" }
        if c.language != .auto { s += "Language: \(c.language.title)\n" }
        if c.formality != .auto { s += "Formality: \(c.formality.title)\n" }
        let n = c.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { s += "Notes:\n\(n)" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The layers applied to one draft, in order (general → specific), plus the resolved values.
public struct VoiceResolution: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case me, organisation, contact }
    public struct Layer: Sendable, Hashable {
        public var kind: Kind
        public var title: String
        public var text: String
    }
    public var layers: [Layer]
    public var language: AILanguage
    public var languageFrom: String
    public var formality: VoiceFormality
    public var formalityFrom: String
    public var addressAs: String?
    public var orgKey: String?
    public var counterpart: String?

    /// "Voice: Me · Northwind · Zoé"
    public var badge: String { "Voice: " + layers.map(\.title).joined(separator: " · ") }

    /// Content-free lines for the "Why" popover.
    public var summary: [String] {
        var out = ["Layers: " + layers.map { l in
            switch l.kind { case .me: "Me"; case .organisation: "Organisation (\(l.title))"; case .contact: "Contact (\(l.title))" }
        }.joined(separator: " → ")]
        out.append("Language: \(language == .auto ? "match the thread" : language.title) (from \(languageFrom))")
        out.append("Formality: \(formality.title) (from \(formalityFrom))")
        if let a = addressAs { out.append("Address as: \(a) (from Contact)") }
        return out
    }
}

public extension MailStore {
    func voiceProfile() -> VoiceProfile { sealed(VoiceProfile.self, for: VoiceProfile.storeKey) ?? VoiceProfile() }
    func save(voiceProfile p: VoiceProfile) throws { try setSealed(p, for: VoiceProfile.storeKey) }
}

// MARK: - Prewritten defaults (the user edits these)

public enum VoiceDefaults {
    /// The first shipped default (20 Nov 2026). A saved profile still holding it verbatim is upgraded to `me`.
    public static let meV1 = """
        I am a Swiss-based consultant. English is my native language and I write fluent German.

        How I write:
        - Direct, warm and brief. I lead with the answer or the decision, then add only the context that is needed.
        - No corporate filler. Never "I hope this email finds you well", "Please do not hesitate to contact me", \
        "I just wanted to reach out" or similar padding.
        - Short paragraphs of one to three sentences. Bullets only when there are three or more items.
        - English: British spelling (organise, colour, centre, programme).
        - German: Swiss conventions. "ss", never "ß". "Grüezi" or "Hoi" only if the thread already uses it. Du or Sie \
        mirrors the thread unless my notes for the organisation or contact say otherwise.
        - French or Italian: plain and polite, tu/vous mirrors the thread.
        - I commit to concrete next steps and dates ("I'll send the revised plan by Thursday"). I never over-promise.
        - I never invent facts, figures, prices, names or dates. If something is missing I leave a [placeholder] for \
        myself to fill in.

        How I sign off (closing line, then my name on its own line):
        - Casual English: "Cheers," / "Jordan"
        - Formal English: "Best regards," / "Jordan"
        - German with Du: "Liebe Grüsse," / "Jordan"
        - German with Sie: "Freundliche Grüsse," / "Jordan Miller"
        """

    public static let me = """
        I am a Swiss-based consultant. English is my native language and I write fluent German.

        How I write:
        - Direct, warm and brief. I lead with the answer or the decision, then add only the context that is needed.
        - No corporate filler. Never "I hope this email finds you well", "Please do not hesitate to contact me", \
        "I just wanted to reach out" or similar padding.
        - Short paragraphs of one to three sentences. Bullets only when there are three or more items.
        - English: British spelling (organise, colour, centre, programme).
        - German: Swiss conventions. "ss", never "ß". "Grüezi" or "Hoi" only if the thread already uses it. Du or Sie \
        mirrors the thread unless my notes for the organisation or contact say otherwise.
        - French or Italian: plain and polite, tu/vous mirrors the thread.
        - I commit to concrete next steps and dates ("I'll send the revised plan by Thursday"). I never over-promise.
        - I never invent facts, figures, prices, names or dates. If something is missing I leave a [placeholder] for \
        myself to fill in.

        Greetings and sign-offs are proportional, not automatic:
        - A quick reply in an ongoing conversation, or to a colleague (e.g. acknowledging an "fyi"), is just the         message: no greeting, no sign-off. "Thanks, got it." is a complete email.
        - If the other person skipped the greeting, I skip it too.
        - A greeting ("Hi Anna," / "Hoi Anna" / "Grüezi Frau Muster") and a sign-off only when starting a conversation,         replying to someone outside the company for the first time in a thread, or when the tone is formal.

        When I do sign off (closing line, then my name on its own line):
        - Casual English: "Cheers," / "Jordan"
        - Formal English: "Best regards," / "Jordan"
        - German with Du: "Liebe Grüsse," / "Jordan"
        - German with Sie: "Freundliche Grüsse," / "Jordan Miller"
        """

    public static let organisationTemplate = """
        Who they are: [what the organisation does, in one line]
        Relationship: [e.g. managed-service customer since 20XX / prospect / partner]
        Language: [their usual language; mixed DE/FR teams → answer each person in their own language]
        Tone: [e.g. Sie with management, Du with the IT team; keep it short and practical]
        Topics: [the projects or services we usually write about]
        Avoid: [anything sensitive, e.g. don't mention pricing by email, don't name other customers]
        """

    public static let contactTemplate = """
        Role: [their role, e.g. head of IT, project lead]
        Address: [e.g. first name with Du / "Frau [Surname]" with Sie]
        Style: [e.g. prefers bullet points and dates; likes a short call over long emails]
        Language: [e.g. writes in French, reads English fine]
        Remember: [anything useful, e.g. works part-time Mon-Wed]
        """

    /// Built-in, not user-editable: how a reply is shaped regardless of voice.
    public static let replyRules = """
        You draft email replies in the user's own voice, for the user to review and edit. Rules:
        1. Answer every question and request in the message being answered. If the information is missing, say \
        what happens next or leave a [placeholder].
        2. Write in the language of the thread unless the resolved settings below set a language.
        3. Mirror the thread's formality (Du/Sie, tu/vous, first name or surname) unless the resolved settings say \
        otherwise. Greeting and sign-off are proportional: in an ongoing conversation, a short acknowledgement, an \
        internal colleague or when the other person wrote none, write NO greeting and NO sign-off — just the \
        message. Use them only to open a conversation, for a first reply to someone outside the organisation, or \
        when the tone is formal.
        4. Keep the reply shorter than the message being answered unless real detail is needed.
        5. Never repeat or quote earlier messages: the history is attached below the reply automatically.
        6. When a sign-off is appropriate (rule 3), follow the user's sign-off rules: a closing line and the name \
        only. Never write a signature block (title, company, phone, address, links); the app adds it when appropriate.
        7. Never invent facts, figures, prices, commitments or dates: use [placeholders] instead.
        """

    static let outputFormat = """
        Output ONLY JSON: {"body": "<the reply text, plain; greeting and sign-off only if rule 3 calls for them>", \
        "signature": true|false, "formality": "formal"|"informal"}. "signature" = whether the user's full signature \
        block suits this reply (true for a first or formal reply to someone outside the organisation; false for a \
        quick, informal or internal back-and-forth). "formality" = the register you used.
        """
}

// MARK: - Signature decision + stripping (pure, local)

public enum VoiceSignaturePlan: String, Sendable, Hashable {
    /// Keep / apply the configured signature for this identity.
    case full
    /// Sign-off name only: the signature block is switched off for this draft.
    case nameOnly
    /// Model gave no usable answer and no rule applies: leave the composer's signature as it is.
    case unchanged
}

/// App facts about the reply (never mail text).
public struct VoiceSignatureFacts: Sendable, Hashable {
    public var isExternal: Bool
    public var userRepliedInThread: Bool
    public var threadCount: Int
    /// Resolved from the layers, or from the model when the layers say "mirror".
    public var formality: VoiceFormality
    public init(isExternal: Bool, userRepliedInThread: Bool, threadCount: Int, formality: VoiceFormality) {
        self.isExternal = isExternal; self.userRepliedInThread = userRepliedInThread
        self.threadCount = threadCount; self.formality = formality
    }

    /// From the thread and the user's addresses (internal = the counterpart shares a domain with one of them).
    public static func from(counterpart: String?, thread: [MailMessage], me: [String], formality: VoiceFormality) -> VoiceSignatureFacts {
        let mine = Set(me.map { $0.lowercased() })
        let myDomains = Set(mine.compactMap { $0.split(separator: "@").last.map(String.init) })
        let d = counterpart?.lowercased().split(separator: "@").last.map(String.init)
        let external = d.map { !myDomains.contains($0) } ?? true
        let t = thread.filter { !$0.isDraft }
        let replied = t.contains { m in m.from.map { mine.contains($0.address.lowercased()) } ?? false }
        return VoiceSignatureFacts(isExternal: external, userRepliedInThread: replied, threadCount: t.count, formality: formality)
    }
}

public enum VoiceSignature {
    /// Rules first, then the model's opinion:
    /// formal (Sie/vous) → full; first reply to an external contact → full; deep (3+ messages, user already replied)
    /// and internal or Du → name only; otherwise the model's `signature` field; no field → unchanged.
    public static func decide(model: Bool?, facts f: VoiceSignatureFacts) -> VoiceSignaturePlan {
        if f.formality == .formal { return .full }
        if f.isExternal && !f.userRepliedInThread { return .full }
        let deep = f.userRepliedInThread && f.threadCount >= 3
        if deep && (!f.isExternal || f.formality == .informal) { return .nameOnly }
        guard let model else { return .unchanged }
        return model ? .full : .nameOnly
    }

    static let closings = [
        "cheers", "best", "best regards", "kind regards", "warm regards", "regards", "many thanks", "thanks", "thank you",
        "all the best", "best wishes",
        "liebe grüsse", "liebe grüße", "lg", "freundliche grüsse", "freundliche grüße", "beste grüsse", "beste grüße",
        "viele grüsse", "viele grüße", "herzliche grüsse", "herzliche grüße", "mit freundlichen grüssen",
        "mit freundlichen grüßen", "gruss", "gruß", "grüsse", "grüße", "en gruess", "liebe grüess",
        "cordialement", "bien cordialement", "meilleures salutations", "bien à vous", "salutations", "amicalement",
        "cordiali saluti", "distinti saluti", "un caro saluto", "saluti", "a presto",
        "speak soon", "talk soon", "bis bald", "à bientôt",
    ].sorted { $0.count > $1.count }

    /// Closing alone ("Cheers,") or with the name on the same line ("Cheers, Jordan").
    static func closingLine(_ l: String) -> (isClosing: Bool, hasName: Bool) {
        let t = l.trimmingCharacters(in: .whitespaces).lowercased()
        for c in closings where t.hasPrefix(c) {
            let rest = t.dropFirst(c.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest == "," || rest == "!" || rest == "." { return (true, false) }
            if rest.hasPrefix(","), rest.count <= 42, !rest.contains("@"), !rest.contains(where: \.isNumber) { return (true, true) }
        }
        return (false, false)
    }

    static func looksLikeName(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.count <= 40 && !t.contains("@") && !t.contains("://") && !t.contains(where: \.isNumber)
            && t.split(separator: " ").count <= 4
    }

    /// With the full signature on: drop a trailing name line that the signature's first line repeats ("Jordan Miller").
    public static func dedupeName(_ text: String, signaturePlain: String) -> String {
        guard let first = signaturePlain.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return text }
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard lines.count > 1, let last = lines.last?.trimmingCharacters(in: .whitespaces), !last.isEmpty, first.hasPrefix(last) else { return text }
        let prev = closingLine(lines[lines.count - 2])
        if prev.isClosing && !prev.hasName { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Removes a signature block the model wrote: everything after the sign-off + name, `-- ` blocks, and the
    /// configured signature's text (`signaturePlain`, local only, never sent to the model).
    public static func strip(_ text: String, signaturePlain: String? = nil) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
        if let sig = signaturePlain?.trimmingCharacters(in: .whitespacesAndNewlines), sig.count >= 3, let r = t.range(of: sig) {
            t = String(t[..<r.lowerBound])
        }
        var lines = t.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0 == "-- " || $0 == "--" }) { lines = Array(lines[..<i]) }
        // Configured signature's first line (often the full name + title) written after the sign-off.
        let sigFirst = signaturePlain?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let tail = max(0, lines.count - 14)
        let firstContent = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // A sign-off candidate is never the first content line ("Thanks, Anna." as an opener), and is cut only when
        // what follows the name looks like a signature block, not prose (long lines, sentences ending in . ? !).
        func cut(at ci: Int) -> Int? {
            guard ci != firstContent else { return nil }
            var keepTo = ci
            if !closingLine(lines[ci]).hasName,
               let ni = lines.indices.first(where: { $0 > ci && !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }),
               ni <= ci + 2, looksLikeName(lines[ni]) {
                keepTo = ni
            }
            let dropped = lines[(keepTo + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let prose = dropped.contains { l in
                l.count > 70 || (l.count > 25 && [".", "?", "!"].contains(l.last ?? " ") && !l.contains("@") && !l.contains("www"))
            }
            return prose ? nil : keepTo
        }
        if let ci = lines.indices.last(where: { $0 >= tail && closingLine(lines[$0]).isClosing }), let keepTo = cut(at: ci) {
            lines = Array(lines[...keepTo])
        } else if let sigFirst, sigFirst.count >= 3, let si = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == sigFirst }),
                  si >= tail {
            lines = Array(lines[..<si])
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Drafting in the user's voice (single shot, everything through AIPromptBuilder)

public struct AIVoiceRequest: Sendable {
    public var original: MailMessage
    public var mailbox: String
    /// The conversation (any order; drafts and the original are dropped; newest `threadLimit` kept, newest first).
    public var thread: [MailMessage]
    /// The user's own sent replies to this counterpart (newest first; only `.content` ones are used, max 3).
    public var styleExamples: [MailMessage]
    /// `TriageContext.lines` for the original (app facts, never mail text).
    public var contextLines: [String]
    public var voice: VoiceResolution
    public var intent: AIReplyIntent?
    public var options: AIDraftOptions
    public var slots: [String]
    public var userName: String?
    public var threadLimit: Int
    public init(original: MailMessage, mailbox: String, thread: [MailMessage] = [], styleExamples: [MailMessage] = [],
                contextLines: [String] = [], voice: VoiceResolution, intent: AIReplyIntent? = nil,
                options: AIDraftOptions = AIDraftOptions(), slots: [String] = [], userName: String? = nil, threadLimit: Int = 6) {
        self.original = original; self.mailbox = mailbox; self.thread = thread; self.styleExamples = styleExamples
        self.contextLines = contextLines; self.voice = voice; self.intent = intent; self.options = options
        self.slots = slots; self.userName = userName; self.threadLimit = threadLimit
    }
}

public struct AIVoiceDraft: Sendable, Hashable {
    public var text: String
    /// The model's opinion on the full signature block (nil = missing / unparseable).
    public var wantsSignature: Bool?
    public var formalityUsed: VoiceFormality?
    public var voice: VoiceResolution
    /// Content-free: layers, resolved values, what context went in.
    public var why: [String]
    public var sources: [AIPromptSource]
    public var notes: [String]
    public var provider: AIProviderID
}

public extension AIAssistant {
    static let layerCap = 4_000

    /// System prompt: reply rules → layers in order (Me, Organisation, Contact) → resolved values → output format.
    /// Layer text is the user's own, but still neutralised (no fake mail markers) and capped.
    static func voiceSystem(_ v: VoiceResolution) -> String {
        var s = VoiceDefaults.replyRules + "\n\nThe user's voice, from general to specific. Later layers are more specific and win on conflicts.\n"
        for (i, l) in v.layers.enumerated() {
            let head: String
            switch l.kind {
            case .me: head = "Layer \(i + 1): Me (how the user writes)"
            case .organisation: head = "Layer \(i + 1): Organisation (\(AIPromptBuilder.neutralise(AIUntrustedText.line(l.title, max: 80))))"
            case .contact: head = "Layer \(i + 1): Contact (\(AIPromptBuilder.neutralise(AIUntrustedText.line(l.title, max: 80))))"
            }
            let body = AIUntrustedText.truncate(AIPromptBuilder.neutralise(AIUntrustedText.stripInvisible(l.text)), layerCap)
            s += "\n=== \(head) ===\n\(body)\n"
        }
        s += "\nResolved for this draft (follow these): language: "
        s += v.language.instruction
        s += " Formality: \(v.formality.instruction)."
        if let a = v.addressAs { s += " Address them as: \(AIPromptBuilder.neutralise(AIUntrustedText.line(a, max: 60)))." }
        return s + "\n\n" + VoiceDefaults.outputFormat
    }

    /// Refuses (no provider call) unless the original is shareable as content on the routed tier.
    func draftReplyInVoice(_ r: AIVoiceRequest, signaturePlain: String? = nil) async throws -> AIVoiceDraft {
        let p = try provider(.draftReply)
        guard gate.exposure(r.original, mailbox: r.mailbox, tier: p.tier) == .content else {
            throw AIAssistError.notAllowed("This message can't be shared with AI (label or organisation policy)")
        }
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        // The answering message first, so the total-size downgrade never reaches it.
        b.add(r.original, mailbox: r.mailbox, role: "answering", context: r.contextLines)
        let earlier = r.thread.filter { $0.id != r.original.id && !$0.isDraft }
            .sorted { $0.received > $1.received }.prefix(max(0, r.threadLimit))
        b.perItemLimit = 1_500
        var threadContent = 0, threadMeta = 0
        for m in earlier where b.add(m, mailbox: r.mailbox, role: "earlier") != nil {
            if b.sources.last?.exposure == .content { threadContent += 1 } else { threadMeta += 1 }
        }
        let threadIds = Set(earlier.map(\.id) + [r.original.id])
        var examples = 0, skipped = 0
        b.perItemLimit = 600
        for m in r.styleExamples where !threadIds.contains(m.id) && !m.isDraft {
            guard examples < 3 else { break }
            guard gate.exposure(m, mailbox: r.mailbox, tier: p.tier) == .content else { skipped += 1; continue }
            var e = m
            // Cut the user's own signature locally so the model doesn't imitate it.
            let plain = AIUntrustedText.stripQuotedAndSignature(AIUntrustedText.body(m.body ?? m.preview ?? "", isHTML: m.body != nil && m.bodyIsHTML))
            e.body = VoiceSignature.strip(plain, signaturePlain: signaturePlain); e.bodyIsHTML = false
            if b.add(e, mailbox: r.mailbox, role: "style-example") != nil { examples += 1 }
        }
        var task = "Draft a reply to the email with role=answering. Emails with role=earlier are the rest of the thread, " +
            "newest first. Emails with role=style-example are the user's own past replies to this person: imitate their " +
            "tone, length and phrasing, never their content.\n"
        if let intent = r.intent { task += "Intent: \(intent.instruction)\n" }
        if r.options.tone != .neutral { task += "Tone for this draft: \(r.options.tone.rawValue).\n" }
        task += "Length: \(r.options.length.rawValue).\n"
        if !r.slots.isEmpty { task += "Available slots (from the user's calendar):\n" + r.slots.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        if let n = r.userName, !n.isEmpty { task += "User's first name: \(AIUntrustedText.line(n, max: 80))\n" }
        let instr = AIUntrustedText.line(r.options.instruction, max: 600)
        if !instr.isEmpty { task += "User's instruction (trusted, from the user): \(AIPromptBuilder.neutralise(instr))\n" }
        let prompt = b.build(system: Self.voiceSystem(r.voice), task: task)
        let out = try await call(.draftReply, p, prompt, maxTokens: r.options.length == .long ? 1_400 : 900)
        let parsed = Self.parseVoiceDraft(out, signaturePlain: signaturePlain)

        var why = r.voice.summary
        why.append("Answering: 1 message")
        if threadContent + threadMeta > 0 {
            why.append("Thread: \(threadContent + threadMeta) earlier message\(threadContent + threadMeta == 1 ? "" : "s")"
                       + (threadMeta > 0 ? " (\(threadMeta) metadata only)" : ""))
        }
        if examples > 0 { why.append("Style: \(examples) of your sent replies to them") }
        if skipped > 0 { why.append("Style: \(skipped) sent repl\(skipped == 1 ? "y" : "ies") not shared (label)") }
        why += r.contextLines.map { "Context: " + $0 }
        why.append("Provider: \(p.id.rawValue) (\(p.tier == .onDevice ? "on-device" : "cloud"))")
        return AIVoiceDraft(text: parsed.body, wantsSignature: parsed.signature, formalityUsed: parsed.formality, voice: r.voice,
                            why: why, sources: prompt.sources, notes: prompt.notes, provider: p.id)
    }

    /// Model output is untrusted: JSON when possible, else the whole text as the body. Any signature it wrote is cut.
    static func parseVoiceDraft(_ text: String, signaturePlain: String? = nil) -> (body: String, signature: Bool?, formality: VoiceFormality?) {
        var body = text, sig: Bool?, formality: VoiceFormality?
        let json = AIOutput.json(text) as? [String: Any]
        if json?["body"] as? String == nil, let lenient = lenientBody(text) {
            // Truncated or slightly malformed JSON: never show raw JSON in the composer.
            body = lenient
            if let r = text.range(of: #""signature"\s*:\s*(true|false)"#, options: .regularExpression) { sig = text[r].hasSuffix("true") }
        }
        if let o = json, let b = o["body"] as? String {
            body = b
            sig = o["signature"] as? Bool ?? (o["signature"] as? String).flatMap { ["true": true, "false": false][$0.lowercased()] }
            switch (o["formality"] as? String)?.lowercased() {
            case "formal": formality = .formal
            case "informal": formality = .informal
            default: break
            }
        }
        return (VoiceSignature.strip(AIOutput.plain(body, max: 8_000), signaturePlain: signaturePlain), sig, formality)
    }

    /// The "body" string from JSON-looking output that didn't parse (cut off at max tokens, raw newlines inside).
    static func lenientBody(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("```"),
              let r = t.range(of: #""body"\s*:\s*""#, options: .regularExpression) else { return nil }
        var out = "", escaped = false
        var it = t[r.upperBound...].makeIterator()
        while let ch = it.next() {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": break
                case "u":
                    var hex = ""
                    for _ in 0..<4 { if let h = it.next() { hex.append(h) } }
                    if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" { escaped = true }
            else if ch == "\"" { break }
            else { out.append(ch) }
        }
        let b = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }
}
