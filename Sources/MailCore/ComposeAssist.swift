import Foundation
import NaturalLanguage

// Composer helpers that need no network and no AppKit, so CoreSelfTest can pin them: recipient ranking, the reply
// From pick, MailTips → banners, templates / snippets, spell-check language detection, cloud-chip and server-attachment
// models for reopened drafts. The Graph calls live in GraphMailService+Compose.swift.

// MARK: - Recipient autocomplete

public struct RecipientSuggestion: Sendable, Hashable, Identifiable {
    /// Where the suggestion came from; the raw order is the tie-break (recent correspondents first).
    public enum Source: Int, Sendable, Hashable, Comparable {
        case recent, people, directory, group
        public static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }
    public var address: String
    public var name: String
    public var source: Source
    /// Group / distribution list (M365 group, DL, mail-enabled security group).
    public var isGroup: Bool
    /// 0…1 from the source: CommGraph proximity for `recent`, rank for `/me/people`, fixed for directory / groups.
    public var relevance: Double
    public init(address: String, name: String, source: Source, isGroup: Bool = false, relevance: Double = 0) {
        self.address = address; self.name = name; self.source = source; self.isGroup = isGroup; self.relevance = relevance
    }
    public var id: String { address.lowercased() }
    public var emailAddress: EmailAddress { EmailAddress(name: name, address: address) }
}

public enum RecipientRanker {
    /// How well `q` matches a name / address: 4 exact address, 3 prefix of the address or the whole name, 2.5 prefix
    /// of a name word, 1 substring, 0 none.
    public static func match(_ q: String, name: String, address: String) -> Double {
        let q = q.lowercased(), a = address.lowercased(), n = name.lowercased()
        if a == q { return 4 }
        if a.hasPrefix(q) || n.hasPrefix(q) { return 3 }
        let words = n.split(whereSeparator: { " ,.-_()'".contains($0) })
        if words.contains(where: { $0.hasPrefix(q) }) { return 2.5 }
        let local = a.split(separator: "@").first.map(String.init) ?? a
        if local.split(whereSeparator: { "._-".contains($0) }).contains(where: { $0.hasPrefix(q) }) { return 2.5 }
        if a.contains(q) || n.contains(q) { return 1 }
        return 0
    }

    /// Merges the sources (one row per address, best score, a name wins over none, group if any source says so),
    /// drops what's already on the draft, ranks by match quality, then relevance, then source.
    /// Server sources (people / directory / groups) match fuzzily server-side, so a server hit with no local match
    /// is kept at a low score instead of dropped.
    public static func rank(_ query: String, candidates: [RecipientSuggestion], excluding: [EmailAddress] = [],
                            limit: Int = 8) -> [RecipientSuggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let ex = Set(excluding.map { $0.address.lowercased() })
        var best: [String: (s: RecipientSuggestion, score: Double)] = [:]
        for c in candidates where !c.address.isEmpty && !ex.contains(c.id) {
            var m = match(q, name: c.name, address: c.address)
            if m == 0 { if c.source == .recent { continue } else { m = 0.5 } }
            let sourceBoost: Double = switch c.source { case .recent: 1.5; case .people: 1.2; case .directory: 0.4; case .group: 0.3 }
            let score = m * 10 + max(0, min(c.relevance, 1)) * 5 + sourceBoost
            if var cur = best[c.id] {
                if cur.s.name.isEmpty && !c.name.isEmpty { cur.s.name = c.name }
                cur.s.isGroup = cur.s.isGroup || c.isGroup
                if score > cur.score { let keepName = cur.s.name; cur.s = c; cur.score = score; if c.name.isEmpty { cur.s.name = keepName } }
                cur.s.isGroup = cur.s.isGroup || c.isGroup
                best[c.id] = cur
            } else { best[c.id] = (c, score) }
        }
        return best.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.s.source != $1.s.source { return $0.s.source < $1.s.source }
            return ($0.s.name.isEmpty ? $0.s.address : $0.s.name).lowercased() < ($1.s.name.isEmpty ? $1.s.address : $1.s.name).lowercased()
        }.prefix(limit).map(\.s)
    }

    /// Local correspondents from the CommGraph people nodes (bulk senders left out), with decayed proximity.
    public static func recent(from people: [PersonNode], query: String, now: Date = Date(), limit: Int = 40) -> [RecipientSuggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let t = Int64(now.timeIntervalSince1970)
        return people.lazy.filter { $0.bulk == 0 || !$0.toThem.isEmpty }
            .compactMap { p -> RecipientSuggestion? in
                let name = p.displayName == p.address ? "" : p.displayName
                guard match(q, name: name, address: p.address) > 0 else { return nil }
                // Mail you sent counts double: the people you write to are who you'll address again.
                let w = p.toThem.weight(at: t) * 2 + p.fromThem.weight(at: t)
                return RecipientSuggestion(address: p.address, name: name, source: .recent, relevance: 1 - exp(-w / 4))
            }
            .sorted { $0.relevance > $1.relevance }.prefix(limit).map { $0 }
    }

    /// Multiple addresses pasted at once ("a@x.ch; B <b@y.ch>\nc@z.ch", Outlook / Excel columns): separators are
    /// `,` `;` newline and tab; quoted display names may contain commas.
    public static func splitPasted(_ text: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, angle = false
        for ch in text {
            switch ch {
            case "\"": quoted.toggle(); cur.append(ch)
            case "<": angle = true; cur.append(ch)
            case ">": angle = false; cur.append(ch)
            case ",", ";", "\n", "\r", "\t", "\r\n":
                if quoted || angle { cur.append(ch) } else { out.append(cur); cur = "" }
            default: cur.append(ch)
            }
        }
        out.append(cur)
        // "a@x.ch b@y.ch" (space separated, no names) splits on spaces too.
        return out.flatMap { part -> [String] in
            let t = part.trimmingCharacters(in: .whitespaces)
            let words = t.split(separator: " ").map(String.init)
            if words.count > 1, words.allSatisfy({ $0.contains("@") && !$0.contains("<") }) { return words }
            return [t]
        }.filter { !$0.isEmpty }
    }

    /// Typed / pasted recipients → addresses ("Name <a@b>", "\"Last, First\" <a@b>", bare addresses). Fragments that
    /// aren't an address come back in `invalid` so the field keeps them for correction.
    public static func parse(_ text: String) -> (valid: [EmailAddress], invalid: [String]) {
        var valid: [EmailAddress] = [], invalid: [String] = []
        for s in splitPasted(text) {
            if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
                let addr = s[s.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
                let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if looksLikeAddress(addr) { valid.append(EmailAddress(name: name, address: addr)) } else { invalid.append(s) }
            } else {
                let a = s.trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'"))
                if looksLikeAddress(a) { valid.append(EmailAddress(name: "", address: a.hasPrefix("mailto:") ? String(a.dropFirst(7)) : a)) }
                else { invalid.append(s) }
            }
        }
        return (valid, invalid)
    }

    public static func looksLikeAddress(_ raw: String) -> Bool {
        let s = raw.hasPrefix("mailto:") ? String(raw.dropFirst(7)) : raw
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasSuffix(".") && !s.contains(" ")
    }
}

// MARK: - From for a reply in a shared / delegated mailbox

public enum ReplyIdentity {
    /// The From a reply / forward / reopened draft defaults to. A message in mailbox X → X's identity (send as
    /// preferred over send on behalf; matched case-insensitively on the mailbox or the identity address). A message
    /// in the own mailbox addressed to one of your own (self-send) aliases → that alias. nil = the caller's default.
    public static func pick(identities: [SendIdentity], mailbox: String, addressedTo: [EmailAddress] = []) -> SendIdentity? {
        let mb = mailbox.lowercased()
        if mb != "me" {
            let mine = identities.filter { $0.mode != .selfSend && ($0.mailbox.lowercased() == mb || $0.address.lowercased() == mb) }
            return mine.first { $0.mode == .sendAs } ?? mine.first
        }
        let to = Set(addressedTo.map { $0.address.lowercased() })
        return identities.first { $0.mode == .selfSend && to.contains($0.address.lowercased()) }
    }
}

// MARK: - MailTips

/// One recipient's MailTips (`POST /me/getMailTips`, resource `mailTips`).
public struct MailTip: Sendable, Hashable {
    public var address: String
    /// Out-of-office message (HTML from Exchange), nil when no automatic reply is on.
    public var automaticReply: String?
    public var mailboxFull: Bool
    public var externalMemberCount: Int?
    public var totalMemberCount: Int?
    public var deliveryRestricted: Bool
    /// "none" / "internal" / "external" / "externalPartner" / "externalNonPartner" (flags, comma-separated).
    public var recipientScope: String?
    /// Error code for this recipient (e.g. an unknown address).
    public var error: String?
    public init(address: String, automaticReply: String? = nil, mailboxFull: Bool = false, externalMemberCount: Int? = nil,
                totalMemberCount: Int? = nil, deliveryRestricted: Bool = false, recipientScope: String? = nil, error: String? = nil) {
        self.address = address; self.automaticReply = automaticReply; self.mailboxFull = mailboxFull
        self.externalMemberCount = externalMemberCount; self.totalMemberCount = totalMemberCount
        self.deliveryRestricted = deliveryRestricted; self.recipientScope = recipientScope; self.error = error
    }
    public var isExternal: Bool { recipientScope?.lowercased().contains("external") == true }
}

public enum MailTipsRequest {
    public static let options = "automaticReplies, mailboxFullStatus, externalMemberCount, totalMemberCount, deliveryRestriction, recipientScope"
    /// Graph caps one call at 100 addresses (UNVERIFIED limit, kept conservative); duplicates and blanks dropped.
    public static let maxAddresses = 100
    public static func addresses(_ list: [EmailAddress]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for a in list {
            let k = a.address.trimmingCharacters(in: .whitespaces).lowercased()
            if !k.isEmpty, k.contains("@"), seen.insert(k).inserted { out.append(k) }
        }
        return Array(out.prefix(maxAddresses))
    }
    public static func body(_ addresses: [String]) -> [String: Any] {
        ["EmailAddresses": addresses, "MailTipsOptions": options]
    }
}

public struct MailTipBanner: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case invalid, mailboxFull, restricted, outOfOffice, external, largeAudience }
    public var kind: Kind
    public var text: String
    public var addresses: [String]
    public var id: String { kind.rawValue + addresses.joined(separator: ",") }
    public init(kind: Kind, text: String, addresses: [String]) { self.kind = kind; self.text = text; self.addresses = addresses }
}

public enum MailTipAdvisor {
    /// Exchange's default large-audience threshold.
    public static let largeAudience = 25

    /// Out-of-office message as a short plain snippet (HTML sanitised by the composer's own parser, never rendered).
    public static func snippet(_ html: String, limit: Int = 140) -> String {
        let plain = RichHTML.parse(html).doc.plainText
            .replacingOccurrences(of: RichRun.lineBreak, with: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return plain.count > limit ? String(plain.prefix(limit - 1)) + "…" : plain
    }

    /// Banners in severity order. `names` maps addresses to display names for the text.
    public static func banners(_ tips: [MailTip], names: [String: String] = [:], largeAudience: Int = largeAudience) -> [MailTipBanner] {
        func who(_ a: String) -> String { let n = names[a.lowercased()] ?? ""; return n.isEmpty ? a : n }
        var out: [MailTipBanner] = []
        let invalid = tips.filter { $0.error != nil }
        if !invalid.isEmpty {
            out.append(MailTipBanner(kind: .invalid, text: invalid.count == 1
                ? "\(who(invalid[0].address)) couldn't be checked — the address may not exist."
                : "\(invalid.count) addresses couldn't be checked — they may not exist.", addresses: invalid.map(\.address)))
        }
        for t in tips where t.mailboxFull {
            out.append(MailTipBanner(kind: .mailboxFull, text: "\(who(t.address))'s mailbox is full — your message may not be delivered.", addresses: [t.address]))
        }
        for t in tips where t.deliveryRestricted {
            out.append(MailTipBanner(kind: .restricted, text: "\(who(t.address)) only accepts mail from certain senders — you may not be allowed.", addresses: [t.address]))
        }
        for t in tips {
            guard let r = t.automaticReply else { continue }
            let s = snippet(r)
            out.append(MailTipBanner(kind: .outOfOffice, text: s.isEmpty ? "\(who(t.address)) has automatic replies on."
                                                                         : "\(who(t.address)) has automatic replies on: “\(s)”", addresses: [t.address]))
        }
        let groupsWithExternal = tips.filter { ($0.externalMemberCount ?? 0) > 0 }
        let externalSingles = tips.filter { $0.isExternal && ($0.totalMemberCount ?? 0) <= 1 && $0.error == nil }
        if !groupsWithExternal.isEmpty || !externalSingles.isEmpty {
            var parts: [String] = []
            if !externalSingles.isEmpty {
                parts.append(externalSingles.count == 1 ? "\(who(externalSingles[0].address)) is outside your organisation"
                                                         : "\(externalSingles.count) recipients are outside your organisation")
            }
            for g in groupsWithExternal { parts.append("\(who(g.address)) has \(g.externalMemberCount ?? 0) external member\(g.externalMemberCount == 1 ? "" : "s")") }
            out.append(MailTipBanner(kind: .external, text: parts.joined(separator: "; ") + ".",
                                     addresses: externalSingles.map(\.address) + groupsWithExternal.map(\.address)))
        }
        let total = tips.reduce(0) { $0 + max(1, $1.totalMemberCount ?? 1) }
        if total >= largeAudience {
            out.append(MailTipBanner(kind: .largeAudience, text: "This message will reach about \(total) people.",
                                     addresses: tips.filter { ($0.totalMemberCount ?? 0) > 1 }.map(\.address)))
        }
        return out
    }
}

// MARK: - Templates / snippets

/// A reusable text block. Typing `;shortcut` then Space / Tab expands it; variables `{{firstName}}` etc. are filled
/// from the draft at insertion time. Local only (sealed in the MailStore kv), like signatures.
public struct MailTemplate: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Letters, digits, `-` and `_` (lower-cased), no leading `;`.
    public var shortcut: String
    /// Email-safe HTML from RichHTML.
    public var html: String
    public init(id: UUID = UUID(), name: String, shortcut: String, html: String) {
        self.id = id; self.name = name; self.shortcut = TemplateShortcut.normalise(shortcut) ?? ""; self.html = html
    }
    public var doc: RichDoc { RichHTML.parse(RichHTML.split(html).editable).doc }
}

public struct TemplateLibrary: Codable, Sendable, Hashable {
    public static let storeKey = "composer.templates"
    public var templates: [MailTemplate] = []
    public init(templates: [MailTemplate] = []) { self.templates = templates }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        templates = try c.decodeIfPresent([MailTemplate].self, forKey: .templates) ?? []
    }
    public func template(shortcut: String) -> MailTemplate? {
        let k = shortcut.lowercased()
        return templates.first { !$0.shortcut.isEmpty && $0.shortcut == k }
    }
}

public extension MailStore {
    func templateLibrary() -> TemplateLibrary { sealed(TemplateLibrary.self, for: TemplateLibrary.storeKey) ?? TemplateLibrary() }
    func save(templateLibrary l: TemplateLibrary) throws { try setSealed(l, for: TemplateLibrary.storeKey) }
}

public enum TemplateShortcut {
    public static func normalise(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix(";") { s.removeFirst() }
        guard !s.isEmpty, s.count <= 32, s.allSatisfy({ ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") && $0.isASCII }) else { return nil }
        return s
    }

    /// The `;shortcut` that ends `textBeforeCursor` (start of paragraph or after whitespace), with its UTF-16 length
    /// including the `;`. "a;b" (no space before) and URLs with `;` don't trigger.
    public static func trigger(_ textBeforeCursor: String) -> (shortcut: String, utf16Length: Int)? {
        guard let semi = textBeforeCursor.lastIndex(of: ";") else { return nil }
        let name = String(textBeforeCursor[textBeforeCursor.index(after: semi)...])
        guard let n = normalise(name), n == name.lowercased() else { return nil }
        if semi > textBeforeCursor.startIndex {
            let prev = textBeforeCursor[textBeforeCursor.index(before: semi)]
            guard prev.isWhitespace || prev == RichRun.lineBreak.first else { return nil }
        }
        return (n, (";" + name as NSString).length)
    }
}

public enum TemplateVariables {
    public static let names = ["firstName", "lastName", "fullName", "myName", "date", "subject"]

    /// "Last, First" / "First Last" / "first.last@x" → First.
    public static func split(_ r: EmailAddress?) -> (first: String, last: String, full: String) {
        guard let r else { return ("", "", "") }
        var name = r.name.trimmingCharacters(in: .whitespaces)
        if name.contains("@") || name.isEmpty {
            let local = r.address.split(separator: "@").first.map(String.init) ?? ""
            let parts = local.split(whereSeparator: { "._-".contains($0) }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            name = parts.joined(separator: " ")
        }
        if let comma = name.firstIndex(of: ",") {
            let last = name[..<comma].trimmingCharacters(in: .whitespaces)
            let first = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return (first.split(separator: " ").first.map(String.init) ?? first, last, "\(first) \(last)".trimmingCharacters(in: .whitespaces))
        }
        // "Name | Company" / "Name (Company)" → drop the organisation part.
        if let cut = name.firstIndex(where: { $0 == "|" || $0 == "(" }) { name = name[..<cut].trimmingCharacters(in: .whitespaces) }
        let words = name.split(separator: " ").map(String.init)
        return (words.first ?? "", words.count > 1 ? words.last! : "", name)
    }

    public static func values(recipient: EmailAddress?, me: EmailAddress?, subject: String, now: Date = Date(),
                              locale: Locale = .current) -> [String: String] {
        let r = split(recipient)
        let df = DateFormatter(); df.locale = locale; df.dateStyle = .long; df.timeStyle = .none
        return ["firstname": r.first, "lastname": r.last, "fullname": r.full, "myname": split(me).full,
                "date": df.string(from: now), "subject": subject]
    }
}

public enum TemplateExpander {
    /// Replaces `{{name}}` (case-insensitive, spaces allowed inside the braces) in every run. Unknown names stay as
    /// typed so the user sees them; a known name with an empty value becomes "".
    public static func expand(_ doc: RichDoc, values: [String: String]) -> RichDoc {
        let re = try! NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z]+)\\s*\\}\\}")
        var d = doc
        for bi in d.blocks.indices {
            for ri in d.blocks[bi].runs.indices where d.blocks[bi].runs[ri].image == nil {
                let t = d.blocks[bi].runs[ri].text
                guard t.contains("{{") else { continue }
                var out = "", last = t.startIndex
                for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                    guard let r = Range(m.range, in: t), let k = Range(m.range(at: 1), in: t) else { continue }
                    out += t[last..<r.lowerBound]
                    if let v = values[t[k].lowercased()] { out += v } else { out += t[r] }
                    last = r.upperBound
                }
                out += t[last...]
                d.blocks[bi].runs[ri].text = out
            }
        }
        return d
    }
}

// MARK: - Spell-check language

public enum DraftLanguage: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case de, en, fr, it
    public var id: String { rawValue }
    public var title: String { switch self { case .de: "Deutsch"; case .en: "English"; case .fr: "Français"; case .it: "Italiano" } }
    /// NSSpellChecker language codes, most specific first (British English per house style, Swiss German first).
    public var spellCodes: [String] {
        switch self { case .de: ["de_CH", "de"]; case .en: ["en_GB", "en"]; case .fr: ["fr_CH", "fr"]; case .it: ["it_CH", "it"] }
    }

    /// Dominant language among DE/EN/FR/IT, nil when the text is too short or the guess is weak.
    public static func detect(_ text: String, minimumLetters: Int = 12, confidence: Double = 0.6) -> DraftLanguage? {
        guard text.filter(\.isLetter).count >= minimumLetters else { return nil }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.german, .english, .french, .italian]
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= confidence else { return nil }
        switch lang { case .german: return .de; case .english: return .en; case .french: return .fr; case .italian: return .it; default: return nil }
    }
}

// MARK: - Reopened drafts: server attachments and cloud-link chips

/// An attachment already on the server draft: shown as a chip, never downloaded or re-uploaded on save.
public struct DraftServerAttachment: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case file, item, reference }
    public var id: String
    public var name: String
    public var contentType: String
    public var size: Int
    public var isInline: Bool
    public var kind: Kind
    public init(id: String, name: String, contentType: String = "application/octet-stream", size: Int = 0, isInline: Bool = false, kind: Kind = .file) {
        self.id = id; self.name = name; self.contentType = contentType; self.size = size; self.isInline = isInline; self.kind = kind
    }
}

/// A OneDrive link chip found in a reopened draft's body ("📄 Name · View/Edit", `CloudLinkChip`). The sharing scope
/// isn't in the body, so it isn't claimed.
public struct CloudChipRef: Sendable, Hashable, Identifiable {
    public var name: String
    public var url: String
    public var type: ShareLinkType
    public var id: String { url }
}

public enum CloudChipScan {
    public static func links(in doc: RichDoc) -> [CloudChipRef] {
        var out: [CloudChipRef] = []
        for b in doc.blocks {
            let rs = b.runs
            guard rs.count >= 4 else { continue }
            for i in 0...(rs.count - 4) {
                guard rs[i].image == nil, rs[i].text.hasSuffix(CloudLinkChip.icon + " "),
                      let url = rs[i + 1].style.link, rs[i + 2].text == " · ", rs[i + 2].style.link == nil,
                      rs[i + 3].style.link == url else { continue }
                let verb = rs[i + 3].text
                guard verb == CloudLinkChip.verb(.view) || verb == CloudLinkChip.verb(.edit) else { continue }
                if !out.contains(where: { $0.url == url }) {
                    out.append(CloudChipRef(name: rs[i + 1].text, url: url, type: verb == CloudLinkChip.verb(.edit) ? .edit : .view))
                }
            }
        }
        return out
    }
}
