import SwiftUI
import CalendarCore
import MailCore

// LIST-HOOK: View menu for the message list (2026-11-20, docs/LIST-LAYOUT.md). Comfortable / Compact density, the
// "Clean List" toggle (sender, subject + snippet, date, label mark only) and "Show Sensitivity Labels in List"
// (docs/COMPOSE-LAYOUT.md). Persisted in MailViewPreferences (A11yPrefs.shared). The row itself is MessageRowView
// (MailViews.swift); its pure decisions live in ListRowLayout.

struct MailListViewMenu: View {
    var model: AppModel
    var body: some View {
        @Bindable var a = A11yPrefs.shared
        Divider()
        Toggle(L("Comfortable"), isOn: Binding(get: { a.prefs.density != .compact },
                                               set: { if $0 { a.prefs.density = .standard } }))
        Toggle(L("Compact"), isOn: Binding(get: { a.prefs.density == .compact },
                                           set: { a.prefs.density = $0 ? .compact : .standard }))
        Toggle(L("Clean List"), isOn: $a.prefs.cleanList)
            .keyboardShortcut("k", modifiers: [.command, .option])
        Toggle(L("Show Sensitivity Labels in List"), isOn: $a.prefs.showLabelChips)
        Divider()
    }
}

/// The tenant's "Confidential" rank for list label marks, cached (the label tree is rebuilt on every call; rows ask
/// for it on every render). Refreshed at most every few seconds, so a label sync shows up without a restart.
@MainActor final class ListLabelRanks {
    static let shared = ListLabelRanks()
    private var cached: (at: Date, rank: Int?)?
    func confidential(_ engine: CachedLabelPolicyEngine) -> Int? {
        if let c = cached, Date().timeIntervalSince(c.at) < 5 { return c.rank }
        let r = engine.labelTree().confidentialRank
        cached = (Date(), r)
        return r
    }
}

/// The list's label mark when chips are off: a small lock (encrypted) / shield (≥ Confidential) / red diamond (unknown
/// label of ours — restricted) in the label colour. No text, never clipped; the name is in the tooltip and VoiceOver
/// reads it (the row's own label lists it too).
struct LabelGlyphMark: View {
    @Environment(\.skin) private var skin
    var policy: ContentPolicy
    var mark: LabelRowMark
    var body: some View {
        if case .glyph(let protected, let unknown) = mark {
            let label = policy.label
            let name = label?.name ?? L("Unknown label — restricted")
            let colour: Color = unknown ? (skin.brand ? skin.danger : .red) : Color(hex: label?.hexColor, fallback: .secondary)
            NSymbol(unknown ? "questionmark.diamond.fill" : protected ? "lock.fill" : "shield.lefthalf.filled", size: 10)
                .foregroundStyle(colour)
                .frame(width: 14)
                .help(L("Sensitivity: %@", name) + (protected ? " · " + L("Encrypted") : ""))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Sensitivity: %@", name) + (protected ? ", " + L("Encrypted") : ""))
        }
    }
}
