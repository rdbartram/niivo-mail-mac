import Foundation
import CalendarCore

// Compose + reading pane layout rules (docs/COMPOSE-LAYOUT.md, 2026-11-20). UI-free so CoreSelfTest can pin them;
// the views in CompliantCalendar (MailComposer.swift, ComposeInline.swift) only read these.

public enum ComposeLayout {
    /// The editor's share of the pane while replying inline (the original collapses to a strip).
    public static let editorMinFraction = 0.6
    /// The expanded original / conversation stack never takes more than this share.
    public static let originalMaxFraction = 0.4

    /// From picker: only when there is a choice.
    public static func showsFrom(identityCount: Int) -> Bool { identityCount > 1 }

    /// Cc / Bcc rows: on demand, or whenever they already hold recipients (a reply-all, a reopened draft).
    public static func showsCcBcc(revealed: Bool, ccCount: Int, bccCount: Int, pendingText: Bool = false) -> Bool {
        revealed || ccCount > 0 || bccCount > 0 || pendingText
    }

    /// Subject: always for new mail and forwards; a reply keeps "Re: …" and shows it only on request.
    public static func showsSubject(isReply: Bool, revealed: Bool) -> Bool { !isReply || revealed }

    /// Formatting bar: hidden until text is selected (floating mini-bar) or the user pins it with Aa.
    public static func formatBarVisible(pinned: Bool, selectionLength: Int) -> FormatBarMode {
        if pinned { return .pinned }
        return selectionLength > 0 ? .floating : .hidden
    }
    public enum FormatBarMode: Sendable, Equatable { case hidden, floating, pinned }

    /// What Esc does in the composer, most specific first.
    public enum EscapeAction: Sendable, Equatable { case discardSuggestion, collapseOriginal, closeComposer }
    public static func escape(suggestionPending: Bool, originalExpanded: Bool) -> EscapeAction {
        if suggestionPending { return .discardSuggestion }
        if originalExpanded { return .collapseOriginal }
        return .closeComposer
    }

    /// Conversation view while replying: only the message being answered stays expanded (the rest show their
    /// collapsed headers) so the editor keeps most of the height. Derived, not stored: the user's own expansion
    /// returns when the composer closes. Unknown `answering` (not in this thread) → the stack is left as it is.
    public static func replyExpansion(expanded: Set<String>, members: [String], answering: String?) -> Set<String> {
        guard let a = answering, members.contains(a) else { return expanded }
        return [a]
    }

    /// Send is held while an AI suggestion waits for Keep / Discard (⌘↩ would otherwise send the old text).
    public static func sendEnabled(suggestionPending: Bool) -> Bool { !suggestionPending }
}

/// The "↩ Re: … [Show original]" strip at the top of an inline reply. Collapsed by default.
public struct ComposeContextStrip: Sendable, Equatable {
    public var expanded = false
    public init() {}
    public mutating func toggle() { expanded.toggle() }
}

// MARK: - AI suggestion (inline, not side by side)

/// What the composer's slim AI bar shows. Driven by the existing AIComposerState fields (busy / preview / undoBody).
public enum AISuggestionPhase: Sendable, Equatable {
    case idle, working, pending, kept

    public static func of(busy: Bool, hasPreview: Bool, canUndo: Bool) -> AISuggestionPhase {
        if busy { return .working }
        if hasPreview { return .pending }
        if canUndo { return .kept }
        return .idle
    }
}

/// The body transform behind Keep (AIAssistModel.acceptPreview) and the highlighted rendering of a pending suggestion.
public enum AISuggestionText {
    /// Keep: a rewrite of a selection replaces only that range — when the body is still the text the range was taken
    /// from; otherwise (or for a whole-body draft) the suggestion replaces the body.
    public static func apply(body: String, before: String, after: String, range: Range<String.Index>?) -> String {
        guard let r = range, body == before, r.upperBound <= body.endIndex else { return after }
        var b = body
        b.replaceSubrange(r, with: after)
        return b
    }

    /// Pending rendering: text before the selection, the highlighted suggestion, text after it. A whole-body draft is
    /// all suggestion.
    public static func segments(before: String, after: String, range: Range<String.Index>?) -> (prefix: String, suggestion: String, suffix: String) {
        guard let r = range, r.upperBound <= before.endIndex else { return ("", after, "") }
        return (String(before[..<r.lowerBound]), after, String(before[r.upperBound...]))
    }
}

// MARK: - Labels in the message list

/// What a list row shows for its label (docs/COMPOSE-LAYOUT.md, docs/LIST-LAYOUT.md).
public enum LabelRowMark: Sendable, Equatable {
    /// Nothing (unlabelled, or a label that doesn't need attention in the list).
    case none
    /// A small lock / shield glyph — no text, never clipped; the name is in the tooltip and the VoiceOver row label.
    case glyph(protected: Bool, unknown: Bool)
    /// The full label chip (View ▸ Show Sensitivity Labels in List).
    case chip
}

extension LabelTree {
    /// The tenant's "Confidential" rank: the least sensitive label (or label group) whose name contains
    /// "confidential" / "vertraulich" / "confidentiel" / "confidenziale" (so "Highly Confidential" ranks above it).
    /// nil = the tenant has no such label (rows then fall back to encryption only).
    public var confidentialRank: Int? {
        flattened.filter { l in Self.confidentialNames.contains { l.name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            .map { floorRank($0.id) ?? $0.priority }.min()
    }

    static let confidentialNames = ["confidential", "vertraulich", "confidentiel", "confidenziale"]
}

extension ListRowLayout {
    /// Label in a list row. Chips on → every label that has one. Chips off (default) → a glyph only for labels that
    /// matter: encrypted, sensitivity ≥ the tenant's Confidential rank, or an unknown label of ours (restricted).
    /// No Confidential label in the tenant → encryption decides.
    public static func labelMark(_ display: LabelDisplay, rank: Int?, confidentialRank: Int?, showChips: Bool) -> LabelRowMark {
        switch display {
        case .none, .external, .protectedElsewhere: return .none
        case .unknownOurs: return showChips ? .chip : .glyph(protected: false, unknown: true)
        case .ours(let l):
            if showChips { return .chip }
            let sensitive = confidentialRank.map { (rank ?? l.priority) >= $0 } ?? false
            return l.hasProtection || sensitive ? .glyph(protected: l.hasProtection, unknown: false) : .none
        }
    }

    /// The subject-line lock for encrypted bodies: shown unless the label mark already says "encrypted".
    public static func showsBodyLock(bodyIsProtected: Bool, mark: LabelRowMark) -> Bool {
        guard bodyIsProtected else { return false }
        switch mark {
        case .glyph(protected: true, _): return false
        case .chip: return false
        default: return true
        }
    }
}
