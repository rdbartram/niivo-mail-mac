import Foundation
import CalendarCore

// ONBOARDING: "Learn my voice", one mode per layer (Me / organisation / contacts), Forget per layer, and learning the
// Me layer from recent sent mail. Pure: the app (VoiceLearnModel) asks `route` before it scans anything, and applies
// the decision. Defaults are Suggest everywhere, which is how learning behaved before the modes existed.

public enum VoiceLayer: String, Codable, Sendable, CaseIterable, Identifiable {
    case me, organisation, contacts
    public var id: String { rawValue }
    public var title: String {
        switch self { case .me: "Me"; case .organisation: "Company"; case .contacts: "Contacts" }
    }
}

public enum VoiceLearnMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Nothing is read or proposed for this layer.
    case off
    /// A learned note is proposed; nothing is saved until the user accepts it.
    case suggest
    /// A learned note is saved straight away (with a visible notice and the layer editable as always).
    case automatic
    public var id: String { rawValue }
    public var title: String {
        switch self { case .off: "Off"; case .suggest: "Suggest"; case .automatic: "Automatic" }
    }
}

public enum VoiceLearnDecision: String, Sendable, Equatable {
    /// Layer is off: don't read mail for it, don't propose anything.
    case dropped
    /// Show it for approval.
    case queued
    /// Save it now.
    case saved
}

/// Something learning produced for one layer.
public enum VoiceLearnCandidate: Sendable, Hashable {
    /// The complete new Me text (the old text with the learned block replaced, see `VoiceLearn.applyMeNotes`).
    case me(String)
    case organisation(VoiceOrg)
    case contact(VoiceContact)
    public var layer: VoiceLayer {
        switch self { case .me: .me; case .organisation: .organisation; case .contact: .contacts }
    }
}

public struct VoiceLearnModes: Codable, Sendable, Hashable {
    /// UserDefaults key prefix; the app appends a per-account suffix (settings, not content).
    public static let defaultsKey = "ai.voice.learn"
    public var me: VoiceLearnMode
    public var organisation: VoiceLearnMode
    public var contacts: VoiceLearnMode

    public init(me: VoiceLearnMode = .suggest, organisation: VoiceLearnMode = .suggest, contacts: VoiceLearnMode = .suggest) {
        self.me = me; self.organisation = organisation; self.contacts = contacts
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        me = (try? c.decodeIfPresent(VoiceLearnMode.self, forKey: .me)) ?? .suggest
        organisation = (try? c.decodeIfPresent(VoiceLearnMode.self, forKey: .organisation)) ?? .suggest
        contacts = (try? c.decodeIfPresent(VoiceLearnMode.self, forKey: .contacts)) ?? .suggest
    }

    public subscript(_ l: VoiceLayer) -> VoiceLearnMode {
        get { switch l { case .me: me; case .organisation: organisation; case .contacts: contacts } }
        set { switch l { case .me: me = newValue; case .organisation: organisation = newValue; case .contacts: contacts = newValue } }
    }

    /// Ask before scanning: `.dropped` means don't even read mail for this layer.
    public func route(_ l: VoiceLayer) -> VoiceLearnDecision {
        switch self[l] { case .off: .dropped; case .suggest: .queued; case .automatic: .saved }
    }

    public var anyOn: Bool { VoiceLayer.allCases.contains { self[$0] != .off } }

    /// Routes one candidate: Off → nothing, Suggest → appended to `queue`, Automatic → written into `profile`
    /// (stamped `updated`, so the staleness check knows when it was learnt).
    @discardableResult
    public func offer(_ c: VoiceLearnCandidate, profile: inout VoiceProfile, queue: inout [VoiceLearnCandidate],
                      now: Date = .now) -> VoiceLearnDecision {
        let d = route(c.layer)
        switch d {
        case .dropped: break
        case .queued: if !queue.contains(c) { queue.append(c) }
        case .saved: Self.save(c, into: &profile, now: now)
        }
        return d
    }

    /// Writes an accepted (or automatic) candidate.
    public static func save(_ c: VoiceLearnCandidate, into p: inout VoiceProfile, now: Date = .now) {
        switch c {
        case .me(let text): p.me = text
        case .organisation(var o): o.updated = now; p.upsert(o)
        case .contact(var k): k.updated = now; p.upsert(k)
        }
    }
}

// MARK: - Forget (one layer only)

public extension VoiceProfile {
    /// Deletes what was saved for one layer. Me goes back to the prewritten default (there is always a Me layer).
    mutating func forget(_ l: VoiceLayer) {
        switch l {
        case .me: resetMe()
        case .organisation: orgs = []
        case .contacts: contacts = []
        }
    }
}

public extension VoiceNudgeLog {
    /// Forget also clears that layer's nudge history (what was dismissed, muted or shown), so learning starts over.
    mutating func forget(_ l: VoiceLayer) {
        switch l {
        case .me:
            muted.remove(Self.me); lastShown[Self.me] = nil
        case .organisation:
            dismissed = dismissed.filter { !$0.hasPrefix("org:") }
        case .contacts:
            dismissed = dismissed.filter { !$0.hasPrefix("contact:") }
            muted = muted.filter { $0 == Self.me }
            lastShown = lastShown.filter { $0.key == Self.me }
            events = []
        }
    }
}

// MARK: - Learn "Me" from recent sent mail (on-device detectors only)

public struct MeVoiceFacts: Sendable, Hashable {
    /// Sent mails looked at (newest first, up to the limit).
    public var considered = 0
    /// Mails whose own text was analysed.
    public var analysed = 0
    /// Skipped: private, forwarded, drafts, or the label gate keeps the text away from on-device AI.
    public var skippedPrivate = 0
    public var skippedForward = 0
    public var skippedGate = 0
    public var language: AILanguage?
    /// Du/Sie in the main language (needs clear evidence, see `VoiceLearn.decideFormality`).
    public var formality: VoiceFormality?
    public var greeting: String?
    public var signOff: String?
    /// Share of mails that open with a greeting / close with a sign-off.
    public var greets: Bool?
    public var signsOff: Bool?
    /// Median length of the user's own text, in words.
    public var medianWords: Int?
    public init() {}
}

public extension VoiceLearn {
    /// Default number of sent mails read when learning Me.
    static let meSampleSize = 50

    /// The user's own text of their last `limit` sent mails. Forwards (someone else's voice), private and draft
    /// items are skipped; text is read only where the gate allows content on the on-device tier.
    static func meFacts(sent: [MailMessage], mailbox: String, gate: AIGatePolicy, limit: Int = meSampleSize) -> MeVoiceFacts {
        var f = MeVoiceFacts()
        var langs: [AILanguage] = [], forms: [(AILanguage, VoiceFormality)] = [], greets: [String] = [], offs: [String] = []
        var greetFlags: [Bool] = [], offFlags: [Bool] = [], words: [Int] = []
        for m in sent.filter({ !$0.isDraft }).sorted(by: { $0.received > $1.received }).prefix(limit) {
            f.considered += 1
            if m.isPrivate { f.skippedPrivate += 1; continue }
            if isForward(m.subject) { f.skippedForward += 1; continue }
            guard gate.exposure(m, mailbox: mailbox, tier: .onDevice) == .content else { f.skippedGate += 1; continue }
            let t = VoiceSignals.ownText(m)
            guard !t.isEmpty else { continue }
            f.analysed += 1
            words.append(t.split(whereSeparator: { $0.isWhitespace }).count)
            let l = VoiceSignals.language(t)
            if let l { langs.append(l) }
            if let l, let fm = VoiceSignals.formality(t, language: l) { forms.append((l, fm)) }
            let g = VoiceSignals.greeting(t)
            greetFlags.append(g != nil)
            if let g { greets.append(g) }
            if m.body != nil {   // a preview rarely reaches the sign-off
                let o = VoiceSignals.signOff(t)
                offFlags.append(o != nil)
                if let o { offs.append(o) }
            }
        }
        f.language = majority(langs) ?? langs.first
        f.greeting = majority(greets); f.signOff = majority(offs)
        if let lang = f.language, lang != .en {
            let v = forms.filter { $0.0 == lang }.map(\.1)
            let formal = v.filter { $0 == .formal }.count
            if formal >= 2 && formal * 3 >= v.count * 2 { f.formality = .formal }
            else if v.count - formal >= 2 && (v.count - formal) * 3 >= v.count * 2 { f.formality = .informal }
        }
        if !greetFlags.isEmpty { f.greets = greetFlags.filter { $0 }.count * 2 > greetFlags.count }
        if !offFlags.isEmpty { f.signsOff = offFlags.filter { $0 }.count * 2 > offFlags.count }
        if !words.isEmpty { f.medianWords = words.sorted()[words.count / 2] }
        return f
    }

    static let meLearnedHeader = "Learned from my sent mail"

    /// Facts → a short block for the Me layer. nil when too little was analysed to say anything (< 5 mails).
    static func meNotes(_ f: MeVoiceFacts) -> String? {
        guard f.analysed >= 5 else { return nil }
        var lines: [String] = []
        if let l = f.language { lines.append("- I mostly write in \(languageName(l)).") }
        if let fm = f.formality, let l = f.language {
            lines.append(fm == .informal ? "- In \(languageName(l)) I usually write Du / tu." : "- In \(languageName(l)) I usually write Sie / vous.")
        }
        if let g = f.greets {
            lines.append(g ? "- I usually open with a greeting" + (f.greeting.map { " (“\($0)”)" } ?? "") + "."
                           : "- I usually skip the greeting.")
        }
        if let o = f.signsOff {
            lines.append(o ? "- I usually sign off" + (f.signOff.map { " with “\($0)”" } ?? "") + "."
                           : "- I usually skip the sign-off.")
        }
        if let w = f.medianWords {
            lines.append(w <= 40 ? "- My mails are short: about \(w) words." : w <= 120 ? "- My mails are medium length: about \(w) words."
                                                                              : "- My mails tend to be long: about \(w) words.")
        }
        guard !lines.isEmpty else { return nil }
        return "\(meLearnedHeader) (\(f.analysed) mails):\n" + lines.joined(separator: "\n")
    }

    /// Replaces an earlier learned block (from its header to the next blank line or the end) or appends one.
    static func applyMeNotes(_ notes: String, to me: String) -> String {
        var paras = me.components(separatedBy: "\n\n")
        if let i = paras.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(meLearnedHeader) }) {
            paras[i] = notes
            return paras.joined(separator: "\n\n")
        }
        let base = me.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? notes : base + "\n\n" + notes
    }
}
