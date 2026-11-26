import SwiftUI
import AppKit
import CalendarCore
import MailCore

// COMPOSE-LAYOUT (2026-11-20, docs/COMPOSE-LAYOUT.md): calmer reader + composer label surfaces.
//   LabelPill        — the label as a small pill (reader header next to the date; composer header, where it opens the picker)
//   ReaderLabelLine  — the notice line that stays for states carrying rights / restriction info
//   AISmartReplyRow  — one slim Gmail-style row of three reply suggestions under the body

/// Small label pill: colour swatch, name, lock when the label encrypts; red for an unknown label of ours; a quiet
/// "No label" when unlabelled. Always visible (compliance) — it replaces the full-width "SENSITIVITY …" line.
struct LabelPill: View {
    @Environment(\.skin) private var skin
    var policy: ContentPolicy
    var origin: LabelOrigin? = nil
    /// Composer (`draftMode`): the draft's label from the tree (nil + `draftId` = an id the tree doesn't know).
    var draftMode = false
    var draftLabel: SensitivityLabel? = nil
    var draftId: String? = nil
    var draftUnavailable = false
    var interactive = false

    var body: some View {
        content
            .font(skin.brand ? skin.mono(9.5, .medium) : .caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private var content: some View {
        if draftMode && draftUnavailable {
            pill(text: L("Labels unavailable"), hex: nil, colour: .orange, locked: false, symbol: "lock.trianglebadge.exclamationmark")
                .help(L("Label policy not synced — labels unavailable"))
        } else if draftMode && draftLabel == nil && draftId != nil {
            pill(text: L("Unknown label"), hex: nil, colour: skin.brand ? skin.danger : .red, locked: false, symbol: "questionmark.diamond.fill")
                .help(L("Unknown label — restricted (not in your synced label policy)"))
        } else if !draftMode, LabelDisplay.decide(policy, origin: origin).noPill {
            // Unknown / external / protected elsewhere: ReaderLabelLine carries it (restriction info), no second mark.
            EmptyView()
        } else if let l = draftMode ? draftLabel : policy.label {
            pill(text: l.name, hex: l.hexColor, colour: Color(hex: l.hexColor, fallback: .gray), locked: l.hasProtection, symbol: nil)
                .help(L("Sensitivity: %@", l.name) + (l.hasProtection ? " · " + L("Encrypted") : "") + (l.tooltip.map { "\n" + $0 } ?? ""))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Sensitivity: %@", l.name) + (l.hasProtection ? ", " + L("Encrypted") : ""))
        } else {
            pill(text: L("No label"), hex: nil, colour: .secondary, locked: false, symbol: "shield")
                .help(L("No sensitivity label"))
                .accessibilityLabel(L("No sensitivity label"))
        }
    }

    private var unknownId: String { if case .unknown(let id) = policy.labelState { return id }; return "" }

    private func pill(text: String, hex: String?, colour: Color, locked: Bool, symbol: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol { NSymbol(symbol, size: 8.5).foregroundStyle(colour) }
            else { Rectangle().fill(colour).frame(width: 6, height: 6).accessibilityHidden(true) }
            Text(text).foregroundStyle(skin.brand ? skin.ink : .primary)
            if locked { NSymbol("lock.fill", size: 7.5) }
            if interactive { Text("▾").font(skin.brand ? skin.mono(8) : .caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background {
            if skin.brand { Rectangle().strokeBorder(colour.opacity(0.7), lineWidth: 1) }
            else { Capsule().fill(colour.opacity(0.14)) }
        }
        .contentShape(Rectangle())
    }
}

private extension LabelDisplay {
    /// States shown as a ReaderLabelLine instead of a pill.
    var noPill: Bool {
        switch self { case .unknownOurs, .external, .protectedElsewhere: true; case .ours, .none: false }
    }
}

/// Reader: the label line that stays a line — states that carry restriction info (unknown label of ours, external
/// label, protected by another organisation). Ordinary labels are a pill next to the date instead.
struct ReaderLabelLine: View {
    var policy: ContentPolicy
    var origin: LabelOrigin?
    var body: some View {
        switch LabelDisplay.decide(policy, origin: origin) {
        case .unknownOurs, .external, .protectedElsewhere: LabelBanner(policy: policy, origin: origin)
        case .ours, .none: EmptyView()
        }
    }
}

/// Gmail-style: at most one slim row of three replies under the body, nothing else. They are the AI reply intents
/// (1–3 keys still work); there are no generated smart replies yet. Hidden without AI, without reply rights, or when
/// the label keeps the message from AI.
struct AISmartReplyRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var reader: ReaderState
    var body: some View {
        let ai = app.mail.ai
        if ai.enabled, ai.canDraft(reader), MailActionRights.allows(.reply, policy: reader.policy), app.mail.composer == nil {
            HStack(spacing: 8) {
                ForEach(Array(AIReplyIntent.allCases.prefix(3))) { i in
                    Button { ai.intent(i) } label: {
                        HStack(spacing: 5) {
                            if i == .confirm { NSymbol("sparkles", size: 10).foregroundStyle(skin.brand ? skin.accentInk : .accentColor) }
                            Text(i.title).lineLimit(1)
                        }
                        .fixedSize()
                    }
                    .modifier(AIChipButton(skin: skin))
                    .help(L("Draft a reply: %@", i.title) + " (\(i.rawValue))")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Suggested replies"))
        }
    }
}

/// Reader ⋯ additions (AI): Summarise (also ⇧⌘S) and Edit voice for this contact / organisation.
struct ReaderAIMenuItems: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var body: some View {
        let ai = app.mail.ai
        if ai.enabled {
            Button(L("Summarise Thread")) { ai.showThreadHeader = true; ai.summarise() }
                .disabled(app.trust.hidesContent)
            let m = VoiceEditorModel.shared
            let who = app.mail.voiceCounterpart(original: reader.header, to: [])
            let items = m.items(for: who, mail: app.mail) { m.showReaderEditor = true }
            if !items.isEmpty {
                Menu(L("Voice")) { ForEach(items) { i in Button(i.title) { i.action() } } }
            }
            Divider()
        }
    }
}

/// Anchor for the reader's voice editor popover (opened from ⋯ ▸ Voice). Only the pane's own message hosts it.
struct ReaderVoicePopoverAnchor: ViewModifier {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    func body(content: Content) -> some View {
        let m = VoiceEditorModel.shared
        @Bindable var model = m
        if reader.header.id == app.mail.reader?.header.id {
            content.background(Color.clear.popover(isPresented: $model.showReaderEditor) { VoiceQuickEditor { m.showReaderEditor = false } })
        } else {
            content
        }
    }
}
