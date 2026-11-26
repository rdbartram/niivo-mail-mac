import Foundation
import CalendarCore

// AI in the editor (docs/COMPOSE-LAYOUT.md "AI inline", 2026-11-26). One pattern everywhere: AI text is APPLIED into
// the normal editor (editable at once), marked as AI text until the user edits or keeps it, and Undo puts back what
// was there. Drafts, the editing actions (Rewrite, Shorten, Tone, Translate, …) and "Ask AI to change…" all go through
// `AIAppliedEdit`. UI-free so CoreSelfTest pins it; offsets are UTF-16 (= NSTextView / NSString ranges).

// MARK: - Actions

public enum AIEditTone: String, Sendable, CaseIterable, Identifiable {
    case formal, friendly, direct
    public var id: String { rawValue }
    public var title: String {
        switch self { case .formal: "More formal"; case .friendly: "Friendlier"; case .direct: "More direct" }
    }
    var instruction: String {
        switch self {
        case .formal: "Make it more formal and polite (formal address: Sie / vous / Lei where the language has it)."
        case .friendly: "Make it warmer and friendlier, still professional."
        case .direct: "Make it more direct: lead with the point or the ask, cut hedging and filler, stay polite."
        }
    }
}

/// What the user asked the AI to do with their text.
public enum AIEditAction: Sendable, Hashable, Identifiable {
    case rewrite, fixGrammar, shorten, expand, bullets
    case tone(AIEditTone)
    case translate(AILanguage)
    /// "Ask AI to change…" — the user's own words.
    case custom(String)

    public static let translations: [AILanguage] = [.en, .de, .fr, .it]
    /// Every fixed action, in menu order.
    public static var standard: [AIEditAction] {
        [.rewrite, .fixGrammar, .shorten, .expand, .bullets] + AIEditTone.allCases.map { .tone($0) } + translations.map { .translate($0) }
    }

    public var id: String {
        switch self {
        case .rewrite: "rewrite"; case .fixGrammar: "grammar"; case .shorten: "shorten"; case .expand: "expand"; case .bullets: "bullets"
        case .tone(let t): "tone-" + t.rawValue
        case .translate(let l): "translate-" + l.rawValue
        case .custom: "custom"
        }
    }

    public var title: String {
        switch self {
        case .rewrite: "Rewrite"
        case .fixGrammar: "Fix Grammar and Spelling"
        case .shorten: "Shorten"
        case .expand: "Expand"
        case .bullets: "Summarise as Bullets"
        case .tone(let t): t.title
        case .translate(let l): "Translate to " + Self.languageName(l)
        case .custom(let s): "Ask AI: “\(s)”"
        }
    }

    /// Progress text in the AI bar.
    public var progress: String {
        switch self {
        case .rewrite: "Rewriting…"; case .fixGrammar: "Fixing grammar…"; case .shorten: "Shortening…"; case .expand: "Expanding…"
        case .bullets: "Summarising…"; case .tone: "Changing the tone…"; case .translate: "Translating…"; case .custom: "Working…"
        }
    }

    static func languageName(_ l: AILanguage) -> String {
        switch l { case .en: "English"; case .de: "German"; case .fr: "French"; case .it: "Italian"; case .auto: "the email's language" }
    }

    /// The fixed part of the request (never mail text). Custom instructions are neutralised by `AIAssistant.editTask`.
    var instruction: String {
        switch self {
        case .rewrite: "Rewrite it so it reads clearly and naturally; keep every fact, request and the meaning."
        case .fixGrammar: "Fix grammar, spelling and punctuation only. Keep the wording, tone and length; change nothing else."
        case .shorten: "Make it about half as long; keep every fact and request."
        case .expand: "Expand it with a little more detail and context (about one and a half times as long). Never invent facts, prices, dates or commitments; where something is missing, phrase it as a question."
        case .bullets: "Summarise it as a short bulleted list, one line per point, each line starting with \"• \". No heading."
        case .tone(let t): t.instruction
        case .translate(.de): "Translate it into Standard German with Swiss spelling (ss, not ß). Keep the formality."
        case .translate(.fr): "Translate it into French. Keep the formality."
        case .translate(.it): "Translate it into Italian. Keep the formality."
        case .translate: "Translate it into British English."
        case .custom: ""
        }
    }

    /// The action itself sets the language / the register, so the resolved voice values must not contradict it.
    public var setsLanguage: Bool { if case .translate = self { return true }; return false }
    public var setsTone: Bool { if case .tone = self { return true }; return false }

    /// The older rewrite modes map onto actions (the AIRewriteMode API stays for existing callers).
    public init(_ m: AIRewriteMode) {
        switch m {
        case .polish: self = .fixGrammar
        case .shorten: self = .shorten
        case .formal: self = .tone(.formal)
        case .friendly: self = .tone(.friendly)
        case .toGerman: self = .translate(.de)
        case .toFrench: self = .translate(.fr)
        case .toItalian: self = .translate(.it)
        case .toEnglish: self = .translate(.en)
        }
    }

    /// ⌘J palette rows for what the user typed: matching actions first (title prefix, then anywhere), then
    /// "Ask AI: …" with their words. Empty query → every fixed action. ↩ runs the first row.
    public static func palette(query: String) -> [AIEditAction] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return standard }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let prefix = standard.filter { a in a.title.range(of: q, options: opts.union(.anchored)) != nil }
        let words = standard.filter { a in !prefix.contains(a) && a.title.range(of: q, options: opts) != nil }
        return prefix + words + [.custom(q)]
    }
}

// MARK: - Target (selection vs whole body)

public enum AIEditScope: Sendable, Equatable {
    /// The user's selection.
    case selection
    /// The whole body the user wrote (signature excluded).
    case body
    /// Nothing written yet: the AI writes from the instruction alone.
    case empty
}

public struct AIEditTarget: Sendable, Equatable {
    public init(range: Range<Int>, text: String, scope: AIEditScope) { self.range = range; self.text = text; self.scope = scope }
    public var range: Range<Int>
    public var text: String
    public var scope: AIEditScope
}

public enum AIEditText {
    public static func count(_ s: String) -> Int { s.utf16.count }

    public static func slice(_ s: String, _ r: Range<Int>) -> String {
        let u = Array(s.utf16)
        let lo = max(0, min(r.lowerBound, u.count)), hi = max(lo, min(r.upperBound, u.count))
        return String(decoding: u[lo..<hi], as: UTF16.self)
    }

    public static func replacing(_ s: String, _ r: Range<Int>, with t: String) -> String {
        let u = Array(s.utf16)
        let lo = max(0, min(r.lowerBound, u.count)), hi = max(lo, min(r.upperBound, u.count))
        return String(decoding: Array(u[..<lo]) + Array(t.utf16) + Array(u[hi...]), as: UTF16.self)
    }

    /// Longest text one action works on (the prompt builder truncates a draft block at this size; a whole-body
    /// result built from a truncated head would silently drop the rest).
    public static let maxTarget = 4_000
    public static func tooLong(_ t: AIEditTarget) -> Bool { t.text.count > maxTarget }
    public static let tooLongMessage = "That's too long for one AI edit. Select a passage (up to 4,000 characters) and try again."

    /// End of the text the user wrote: before the signature block (when the body ends with it), trailing blank
    /// lines excluded.
    public static func userTextEnd(body: String, signaturePlain: String) -> Int {
        let u = Array(body.utf16)
        var end = u.count
        if !signaturePlain.isEmpty, body.hasSuffix(signaturePlain) { end -= count(signaturePlain) }
        while end > 0, let c = Unicode.Scalar(u[end - 1]), CharacterSet.whitespacesAndNewlines.contains(c) { end -= 1 }
        return end
    }

    /// What an action works on: the selection when there is one (with text in it), else the whole body the user wrote.
    public static func target(body: String, selection: Range<Int>?, signaturePlain: String) -> AIEditTarget {
        let n = count(body)
        if let s = selection, !s.isEmpty, s.lowerBound >= 0, s.upperBound <= n {
            let t = slice(body, s)
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return AIEditTarget(range: s, text: t, scope: .selection) }
        }
        let end = userTextEnd(body: body, signaturePlain: signaturePlain)
        let t = slice(body, 0..<end)
        return AIEditTarget(range: 0..<end, text: t, scope: t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .body)
    }

    /// One edit `old` → `new` as (changed range in old, changed range in new) from the common prefix / suffix.
    static func change(_ old: [UInt16], _ new: [UInt16]) -> (p: Int, oldEnd: Int, newEnd: Int) {
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var s = 0
        while s < old.count - p, s < new.count - p, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        return (p, old.count - s, new.count - s)
    }

    /// Moves `r` (in `old`) through the edit `old` → `new`. `touched` = the edit overlapped it.
    public static func follow(_ r: Range<Int>, old: String, new: String) -> (range: Range<Int>, touched: Bool) {
        guard old != new else { return (r, false) }
        let c = change(Array(old.utf16), Array(new.utf16))
        let delta = c.newEnd - c.oldEnd
        if c.oldEnd <= r.lowerBound && !(c.p == r.lowerBound && c.oldEnd > c.p) {
            return ((r.lowerBound + delta)..<(r.upperBound + delta), false)   // before (or typed right at its start)
        }
        if c.p >= r.upperBound { return (r, false) }   // after (or typed right at its end)
        let lo = min(r.lowerBound, c.p)
        let hi = max(r.upperBound, c.oldEnd) + delta
        return (lo..<max(lo, hi), true)
    }
}

// MARK: - Applied AI text (the state machine)

/// AI text that is in the body now. Tracks its span through the user's typing; Undo restores what it replaced
/// (the user's edits elsewhere stay); Try again replaces only the AI text or adds another version below.
public struct AIAppliedEdit: Sendable, Equatable {
    public enum Origin: Sendable, Equatable { case draft, edit }
    public enum Placement: Sendable, Equatable { case replace, insertBelow }
    public enum Change: Sendable, Equatable { case none, outside, inside, reverted }

    /// The body this state refers to (kept in step by `track`).
    public private(set) var body: String
    /// The applied text plus the blank-line separators it brought (Undo removes all of it).
    public private(set) var outer: Range<Int>
    public private(set) var lead: Int
    public private(set) var trail: Int
    /// What the AI text replaced ("" when it was added below).
    public let replaced: String
    /// The body before the AI change (a full ⌘Z back to it counts as Undo).
    public let bodyBefore: String
    public let origin: Origin
    /// The user typed inside the AI text: it is theirs now (no marker), Undo still restores what was there.
    public private(set) var edited = false

    /// The AI text without separators.
    public var span: Range<Int> { (outer.lowerBound + lead)..<max(outer.lowerBound + lead, outer.upperBound - trail) }
    public var text: String { AIEditText.slice(body, span) }

    /// Where the editor draws the AI marker (nil once edited). Leading / trailing whitespace is not marked.
    public var markRange: Range<Int>? {
        guard !edited else { return nil }
        let u = Array(body.utf16)
        var lo = span.lowerBound, hi = min(span.upperBound, u.count)
        func ws(_ i: Int) -> Bool { Unicode.Scalar(u[i]).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false }
        while lo < hi, ws(lo) { lo += 1 }
        while hi > lo, ws(hi - 1) { hi -= 1 }
        return lo < hi ? lo..<hi : nil
    }

    /// Put `text` into `body` at `target`. `.replace` swaps the target for it; `.insertBelow` adds it after the target
    /// as its own paragraph. A whole-body result keeps a blank line before whatever follows (the signature).
    public static func apply(body: String, target: Range<Int>, text: String, placement: Placement, origin: Origin,
                             separateFromFollowing: Bool = true) -> AIAppliedEdit? {
        let u = Array(body.utf16)
        guard target.lowerBound >= 0, target.upperBound <= u.count else { return nil }
        let nl = UInt16(UInt8(ascii: "\n"))
        let at: Range<Int> = placement == .replace ? target : target.upperBound..<target.upperBound
        var lead = "", trail = ""
        if placement == .insertBelow || target.isEmpty, at.lowerBound > 0 {
            let p1 = u[at.lowerBound - 1] == nl, p2 = at.lowerBound > 1 && u[at.lowerBound - 2] == nl
            lead = p1 && p2 ? "" : (p1 ? "\n" : "\n\n")
        }
        if separateFromFollowing, at.upperBound < u.count, u[at.upperBound] != nl { trail = "\n\n" }
        let insert = lead + text + trail
        let new = AIEditText.replacing(body, at, with: insert)
        let n = AIEditText.count(insert)
        return AIAppliedEdit(body: new, outer: at.lowerBound..<(at.lowerBound + n), lead: AIEditText.count(lead),
                             trail: AIEditText.count(trail), replaced: AIEditText.slice(body, at), bodyBefore: body,
                             origin: origin, edited: false)
    }

    /// The body changed (typing, ⌘Z, a signature switch): follow it.
    @discardableResult
    public mutating func track(_ newBody: String) -> Change {
        guard newBody != body else { return .none }
        if newBody == bodyBefore { body = newBody; return .reverted }
        let f = AIEditText.follow(outer, old: body, new: newBody)
        body = newBody
        outer = f.range
        if f.touched { edited = true; return .inside }
        return .outside
    }

    /// Undo: the body with the AI text (and its separators) swapped back for what it replaced.
    public var undone: String { AIEditText.replacing(body, outer, with: replaced) }

    /// Try again with a new result. `.replace` swaps only the AI text (the user's edits elsewhere stay; Undo still
    /// goes back to the text before the first try). `.insertBelow` keeps this version and adds the new one below it.
    public func retried(text: String, placement: Placement) -> AIAppliedEdit {
        switch placement {
        case .replace:
            let inner = (outer.lowerBound + lead)..<max(outer.lowerBound + lead, outer.upperBound - trail)
            let new = AIEditText.replacing(body, inner, with: text)
            let n = AIEditText.count(text)
            return AIAppliedEdit(body: new, outer: outer.lowerBound..<(inner.lowerBound + n + trail), lead: lead, trail: trail,
                                 replaced: replaced, bodyBefore: bodyBefore, origin: origin, edited: false)
        case .insertBelow:
            let end = outer.upperBound - trail
            return Self.apply(body: body, target: span.lowerBound..<end, text: text, placement: .insertBelow, origin: origin)
                ?? self
        }
    }
}

/// Where a Try again result goes when it arrives. The AI text it was meant for may be gone (Undo, Esc, a full ⌘Z,
/// Keep) or edited by the user meanwhile: never overwrite their words, never fall back to replacing the whole body.
public enum AIRetryLanding: Sendable, Equatable {
    /// Nothing to retry against any more: drop the result (with a note).
    case drop
    case land(AIAppliedEdit.Placement)

    public static func decide(applied: AIAppliedEdit?, requested: AIAppliedEdit.Placement) -> AIRetryLanding {
        guard let a = applied else { return .drop }
        return a.edited ? .land(.insertBelow) : .land(requested)
    }
}

/// What the composer's slim AI bar shows.
public enum AIInlinePhase: Sendable, Equatable {
    case idle, working
    /// AI text in the editor, marked: Keep · Try again ▾ · Undo.
    case suggested
    /// The user edited inside it: the marker is gone, Undo is still offered.
    case edited

    public static func of(busy: Bool, applied: AIAppliedEdit?) -> AIInlinePhase {
        if busy { return .working }
        guard let a = applied else { return .idle }
        return a.edited ? .edited : .suggested
    }
}

/// A request's target while the call runs: the editor stays editable, so the target follows the user's typing.
/// If they typed inside it, the result can't replace it any more and is added below instead (never lost, never
/// overwriting their words).
public struct AIEditAnchor: Sendable, Equatable {
    public private(set) var body: String
    public private(set) var range: Range<Int>
    public private(set) var touched = false
    public init(body: String, range: Range<Int>) { self.body = body; self.range = range }

    public mutating func track(_ newBody: String) {
        guard newBody != body else { return }
        let f = AIEditText.follow(range, old: body, new: newBody)
        body = newBody; range = f.range
        if f.touched { touched = true }
    }

    /// Where the result goes in the current body.
    public func placement(requested: AIAppliedEdit.Placement) -> (range: Range<Int>, placement: AIAppliedEdit.Placement, moved: Bool) {
        touched ? (range, .insertBelow, true) : (range, requested, false)
    }
}

// MARK: - Gate (one function for the menu and the call)

public extension AIAssistant {
    /// Why the user's own draft text can't go to AI right now (nil = allowed). The same check guards `edit` and
    /// `rewrite`, so a disabled menu item and a refused call always give the same reason.
    func editRefusal(labelId: String?) -> String? {
        guard settings.choice != .off else { return AIAssistError.off.description }
        guard let p = route(.rewrite) else { return Self.noProvider }
        return editRefusal(labelId: labelId, tier: p.tier)
    }

    internal func editRefusal(labelId: String?, tier: AITier) -> String? {
        gate.draftExposure(labelId: labelId, tier: tier) == .content ? nil : gate.draftRefusal(labelId: labelId, tier: tier)
    }

    /// Why a reply can't be drafted from this message (nil = allowed). Guards `draftReplyInVoice` too.
    func replyRefusal(original: MailMessage, mailbox: String) -> String? {
        guard settings.choice != .off else { return AIAssistError.off.description }
        guard let p = route(.draftReply) else { return Self.noProvider }
        return replyRefusal(original: original, mailbox: mailbox, tier: p.tier)
    }

    internal func replyRefusal(original: MailMessage, mailbox: String, tier: AITier) -> String? {
        gate.exposure(original, mailbox: mailbox, tier: tier) == .content ? nil : Self.replyNotShared
    }

    static let noProvider = "No AI provider is available or allowed for this"
    static let replyNotShared = "This message can't be shared with AI (label or organisation policy)"
}

// MARK: - Edit call (voice-aware)

public extension AIAssistant {
    static let editBase = voice + """
         You edit the user's own email text as instructed. Output only the resulting text: plain, no commentary, no \
        subject line, no quotes around it, no markdown headings. Never invent facts, prices, dates or commitments. Keep \
        names, numbers and links exactly. Do not add a greeting, sign-off or signature unless the text already has one \
        or the instruction asks for it.
        """

    /// System prompt for an edit: the rules, the user's voice layers (Me → Organisation → Contact), and only those
    /// resolved values the action doesn't set itself (Translate decides the language, Tone the register).
    static func editSystem(voice v: VoiceResolution?, action: AIEditAction) -> String {
        var s = editBase
        if let v, !v.layers.isEmpty {
            s += "\n\nThe user's voice, from general to specific. Later layers are more specific and win on conflicts. " +
                "Use it for wording and register; the instruction in the task wins over it.\n" + voiceLayerBlocks(v)
        }
        var resolved: [String] = []
        // A free-form instruction may ask for another language or register itself: then it wins.
        let unless = action.isCustom ? " unless the user's instruction asks otherwise" : ""
        if !action.setsLanguage { resolved.append("keep the language of the text (do not translate)" + unless) }
        if !action.setsTone, let v, v.formality != .auto { resolved.append("formality: \(v.formality.instruction)" + unless) }
        if let a = v?.addressAs { resolved.append("if the text greets them, address them as \(AIPromptBuilder.neutralise(AIUntrustedText.line(a, max: 60)))") }
        if !resolved.isEmpty { s += "\nFor this edit: " + resolved.joined(separator: "; ") + "." }
        return s
    }

    /// The task line: what to do with the DRAFT block. The user's own words are neutralised and capped.
    static func editTask(_ a: AIEditAction, scope: AIEditScope) -> String {
        let what: String
        switch scope {
        case .selection: what = "The DRAFT block is a passage the user selected in their email; return only its replacement."
        case .body: what = "The DRAFT block is the user's whole email text (signature not included)."
        case .empty: what = "There is no text yet: write the email body the user asks for."
        }
        if case .custom(let s) = a {
            let instr = AIPromptBuilder.neutralise(AIUntrustedText.line(s, max: 600))
            return what + "\nUser's instruction (trusted, from the user): " + instr
        }
        return what + "\n" + a.instruction
    }

    /// Edit the user's own text. Only the target text (and the user's voice notes) goes to the provider — never the
    /// original or the thread. Refused before any call when the draft's label or the organisation forbids it.
    func edit(_ text: String, scope: AIEditScope, labelId: String?, action: AIEditAction, voice v: VoiceResolution? = nil) async throws -> AITextResult {
        let p = try provider(.rewrite)
        if let why = editRefusal(labelId: labelId, tier: p.tier) { throw AIAssistError.notAllowed(why) }
        if case .custom(let s) = action, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIAssistError.notAllowed("Say what to change")
        }
        guard scope == .empty ? action.isCustom : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIAssistError.notAllowed("Write something first, or ask AI to write it")
        }
        guard text.count <= AIEditText.maxTarget else { throw AIAssistError.notAllowed(AIEditText.tooLongMessage) }
        var b = AIPromptBuilder(gate: gate, tier: p.tier)
        if scope != .empty { b.addDraft(text) }
        let prompt = b.build(system: Self.editSystem(voice: v, action: action), task: Self.editTask(action, scope: scope))
        let budget = scope == .empty ? 900 : max(300, AIEditText.count(text) * (action == .expand ? 2 : 1))
        let out = try await call(.rewrite, p, prompt, maxTokens: min(budget, 2_400))
        return AITextResult(text: AIOutput.plain(out, max: 8_000), sources: [], notes: [], provider: p.id)
    }
}

public extension AIEditAction {
    var isCustom: Bool { if case .custom = self { return true }; return false }
}

// MARK: - Voice layers off for one request

public extension VoiceProfile {
    /// `resolve` without some layers (the user switched them off for one request): a dropped layer's language,
    /// formality and form of address go with it.
    func resolve(counterpart: String?, languageOverride: AILanguage = .auto, excluding off: Set<VoiceResolution.Kind>) -> VoiceResolution {
        guard !off.isEmpty else { return resolve(counterpart: counterpart, languageOverride: languageOverride) }
        var p = self
        if off.contains(.contact), let a = counterpart?.lowercased().trimmingCharacters(in: .whitespaces) { p.contacts.removeAll { $0.address == a } }
        if off.contains(.organisation), let a = counterpart, let k = MailDomains.companyKey(for: a)?.lowercased() { p.orgs.removeAll { $0.key == k } }
        var r = p.resolve(counterpart: counterpart, languageOverride: languageOverride)
        if off.contains(.me) { r.layers.removeAll { $0.kind == .me } }
        return r
    }
}
