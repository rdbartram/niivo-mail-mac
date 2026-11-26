import Foundation
import CalendarCore
import MailCore

// Compose + reading pane layout (docs/COMPOSE-LAYOUT.md): header visibility, strip, Esc, conversation collapse,
// AI suggestion phases + body transform, list label marks and the chips toggle. Pure rules only, no UI.
@MainActor
func runComposeLayoutTests() {
    section("Compose layout: header, strip, Esc, AI suggestion, list label marks")
    let C = ComposeLayout.self

    // Header row
    check(!C.showsFrom(identityCount: 0) && !C.showsFrom(identityCount: 1) && C.showsFrom(identityCount: 2),
          "From only when there is more than one identity")
    check(!C.showsCcBcc(revealed: false, ccCount: 0, bccCount: 0) && C.showsCcBcc(revealed: true, ccCount: 0, bccCount: 0)
          && C.showsCcBcc(revealed: false, ccCount: 1, bccCount: 0) && C.showsCcBcc(revealed: false, ccCount: 0, bccCount: 2)
          && C.showsCcBcc(revealed: false, ccCount: 0, bccCount: 0, pendingText: true),
          "Cc/Bcc on demand, or whenever they hold (or are typing) recipients")
    check(C.showsSubject(isReply: false, revealed: false) && !C.showsSubject(isReply: true, revealed: false)
          && C.showsSubject(isReply: true, revealed: true), "subject: new/forward always, replies on request")
    check(C.formatBarVisible(pinned: false, selectionLength: 0) == .hidden
          && C.formatBarVisible(pinned: false, selectionLength: 3) == .floating
          && C.formatBarVisible(pinned: true, selectionLength: 0) == .pinned
          && C.formatBarVisible(pinned: true, selectionLength: 5) == .pinned, "format bar: hidden, floating on selection, Aa pins it")
    check(C.editorMinFraction >= 0.6 && C.originalMaxFraction + C.editorMinFraction <= 1.0, "editor keeps ≥ 60 % of the pane")

    // Context strip + Esc
    var strip = ComposeContextStrip()
    check(strip.expanded == false, "original collapsed to the strip by default")
    strip.toggle(); check(strip.expanded, "Show original expands")
    strip.toggle(); check(!strip.expanded, "…and collapses again")
    check(C.escape(suggestionPending: true, originalExpanded: true) == .discardSuggestion
          && C.escape(suggestionPending: false, originalExpanded: true) == .collapseOriginal
          && C.escape(suggestionPending: false, originalExpanded: false) == .closeComposer,
          "Esc: discard suggestion → collapse original → close (save / empty closes silently)")
    check(!C.sendEnabled(suggestionPending: true) && C.sendEnabled(suggestionPending: false), "send waits for Keep / Discard")

    // Conversation view while replying
    let members = ["m1", "m2", "m3"]
    check(C.replyExpansion(expanded: ["m1", "m3"], members: members, answering: "m2") == ["m2"],
          "replying collapses every card except the one being answered")
    check(C.replyExpansion(expanded: ["m1", "m3"], members: members, answering: nil) == ["m1", "m3"]
          && C.replyExpansion(expanded: ["m1"], members: members, answering: "other") == ["m1"],
          "no reply in this thread: the user's own expansion is untouched")

    // AI suggestion: phases follow the existing AIComposerState fields
    let P = AISuggestionPhase.self
    check(P.of(busy: false, hasPreview: false, canUndo: false) == .idle, "AI: idle")
    check(P.of(busy: true, hasPreview: false, canUndo: true) == .working, "AI: working wins")
    check(P.of(busy: false, hasPreview: true, canUndo: false) == .pending, "AI: suggestion pending (Keep / Retry / Discard)")
    check(P.of(busy: false, hasPreview: false, canUndo: true) == .kept, "AI: kept → one undo available")
    check(P.of(busy: false, hasPreview: true, canUndo: true) == .pending, "AI: a new suggestion over a kept one is pending")

    // AI suggestion: Keep's body transform (acceptPreview) + pending rendering
    let T = AISuggestionText.self
    let before = "Hi Anna,\nthanks for the note.\nBest"
    let r = before.range(of: "thanks for the note.")!
    check(T.apply(body: before, before: before, after: "Thank you so much.", range: r) == "Hi Anna,\nThank you so much.\nBest",
          "Keep a rewrite: only the selection is replaced")
    check(T.apply(body: before, before: before, after: "New draft", range: nil) == "New draft", "Keep a draft: the body is replaced")
    check(T.apply(body: before + "!", before: before, after: "X", range: r) == "X", "body changed since: whole replace (old behaviour)")
    let seg = T.segments(before: before, after: "Thank you so much.", range: r)
    check(seg.prefix == "Hi Anna,\n" && seg.suggestion == "Thank you so much." && seg.suffix == "\nBest",
          "pending rewrite renders prefix · highlighted suggestion · suffix")
    let whole = T.segments(before: before, after: "Draft", range: nil)
    check(whole.prefix.isEmpty && whole.suggestion == "Draft" && whole.suffix.isEmpty, "pending draft is all suggestion")
    // Undo state transition (acceptPreview → undoAI) modelled on the same fields
    var body = before, undo: String? = nil, preview: (String, String, Range<String.Index>?)? = (before, "Thank you.", r)
    if let p = preview { undo = body; body = T.apply(body: body, before: p.0, after: p.1, range: p.2); preview = nil }
    check(P.of(busy: false, hasPreview: preview != nil, canUndo: undo != nil) == .kept && body.contains("Thank you."), "Keep → kept")
    if let u = undo { body = u; undo = nil }
    check(body == before && P.of(busy: false, hasPreview: false, canUndo: undo != nil) == .idle, "one undo restores the previous text")

    // List: label marks
    let pub = SensitivityLabel(id: "p", name: "Public", priority: 0)
    let gen = SensitivityLabel(id: "g", name: "General", priority: 1)
    let conf = SensitivityLabel(id: "c", name: "Confidential", priority: 2)
    let confAll = SensitivityLabel(id: "c1", name: "All Employees", priority: 2, parentId: "c")
    let high = SensitivityLabel(id: "h", name: "Highly Confidential", priority: 3)
    let enc = SensitivityLabel(id: "e", name: "General Encrypted", priority: 1, hasProtection: true)
    let tree = LabelTree([pub, gen, conf, confAll, high, enc])
    check(tree.confidentialRank == 2, "Confidential rank from the label tree (the lowest label named Confidential)")
    check(LabelTree([pub, gen]).confidentialRank == nil, "no Confidential label → nil")
    check(LabelTree([pub, SensitivityLabel(id: "v", name: "Vertraulich", priority: 4), SensitivityLabel(id: "sv", name: "Streng vertraulich", priority: 5)]).confidentialRank == 4,
          "German tenant: Vertraulich (not Streng vertraulich) is the threshold")
    let rank = tree.confidentialRank
    let LR = ListRowLayout.self
    func mark(_ l: SensitivityLabel, chips: Bool = false, cr: Int? = rank) -> LabelRowMark {
        LR.labelMark(.ours(l), rank: nil, confidentialRank: cr, showChips: chips)   // rows pass rank nil (label priority)
    }
    check(mark(pub) == .none && mark(gen) == .none, "Public / General: no mark in the list")
    check(mark(conf) == .glyph(protected: false, unknown: false) && mark(confAll) == .glyph(protected: false, unknown: false)
          && mark(high) == .glyph(protected: false, unknown: false), "≥ Confidential (sub-labels included): shield glyph")
    check(mark(enc) == .glyph(protected: true, unknown: false), "encrypted label below Confidential: lock glyph")
    check(mark(conf, cr: nil) == .none && mark(enc, cr: nil) == .glyph(protected: true, unknown: false),
          "no Confidential rank known: protection decides")
    check(LR.labelMark(.unknownOurs(id: "x"), rank: nil, confidentialRank: rank, showChips: false) == .glyph(protected: false, unknown: true),
          "unknown label of ours: still marked (restricted)")
    check(LR.labelMark(.external, rank: nil, confidentialRank: rank, showChips: true) == .none
          && LR.labelMark(.none, rank: nil, confidentialRank: rank, showChips: true) == .none, "external / unlabelled: nothing, even with chips on")
    check(mark(gen, chips: true) == .chip && mark(pub, chips: true) == .chip, "chips toggle restores full chips for every label")
    check(LR.showsBodyLock(bodyIsProtected: true, mark: .none) && !LR.showsBodyLock(bodyIsProtected: true, mark: .glyph(protected: true, unknown: false))
          && LR.showsBodyLock(bodyIsProtected: true, mark: .glyph(protected: false, unknown: false)) && !LR.showsBodyLock(bodyIsProtected: false, mark: .none),
          "encrypted body without a lock mark keeps its subject-line lock")

    // List: chips toggle persistence
    let suite = "composelayout-selftest-\(UUID().uuidString)"
    guard let d = UserDefaults(suiteName: suite) else { check(false, "UserDefaults suite"); return }
    defer { d.removePersistentDomain(forName: suite) }
    check(MailViewPreferences.load(d).showLabelChips == false, "label chips in the list: off by default")
    var p = MailViewPreferences(); p.showLabelChips = true; p.save(d)
    check(MailViewPreferences.load(d).showLabelChips, "label chips toggle persists")
}
