import SwiftUI
import AppKit
import CalendarCore
import MailCore

// COMPOSE-LAYOUT (2026-11-20, docs/COMPOSE-LAYOUT.md): the calm composer.
//   InlineReplyPane          reply takes over the reading pane (inside the reader's capture shield + watermark)
//   ComposeContextStripView  "↩ Re: … · sender · date [Show original]" + the read-only original (ReaderBody path)
//   ComposerCompactHeader    one row: To/Cc chips · label pill · From (only with > 1 identity) · ⋯
//   ComposerNotices          capped notices (errors, Purview, MailTips, external warnings)
// Editor box, inline AI and footer: ComposeInlineAI.swift. Pure rules: MailCore/ComposeLayout.swift (CoreSelfTest).

/// What Try again runs again (set by AIAssistModel.draft / edit). An edit retries on the text it started from.
enum AIComposerRetry: Equatable {
    case draft(AIReplyIntent?)
    case edit(AIEditAction, source: String, scope: AIEditScope)
}

/// Per-composer view state (no @State under CLT).
@MainActor @Observable final class ComposeUIState {
    var strip = ComposeContextStrip()
    var formatPinned = false
    var subjectRevealed = false
    /// The original, loaded through MailModel.standaloneReader (same fail-closed policy path) when the strip expands
    /// outside the reading pane.
    var original: ReaderState?
    var loadingOriginal = false
    var noticesHeight: CGFloat = 0
}

@MainActor final class ComposeUIHub {
    static let shared = ComposeUIHub()
    private var states: [UUID: ComposeUIState] = [:]
    func state(_ c: ComposerState) -> ComposeUIState {
        if let s = states[c.id] { return s }
        let s = ComposeUIState()
        if states.count > 24 { states.removeAll() }   // composers are short-lived; never grows unbounded
        states[c.id] = s
        return s
    }
}

// MARK: - Pane takeover

/// The reading pane while replying to its message: the composer is the content, the original a strip at the top.
struct InlineReplyPane: View {
    var composer: ComposerState
    var reader: ReaderState
    var allowCopy: Bool
    var body: some View {
        // The pane's own reader doubles as the expanded original when it is the message being answered.
        let paneOriginal = composer.original?.id == reader.header.id ? reader : nil
        ComposerView(composer: composer, inline: true, paneOriginal: paneOriginal, paneAllowCopy: allowCopy)
    }
}

// MARK: - Context strip + original

struct ComposeContextStripView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState
    var ui: ComposeUIState
    /// The original is already on screen (the pane's reader or the conversation stack): no loading needed / no toggle.
    var originalInStack = false
    var hasPaneOriginal = false

    var body: some View {
        let mail = app.mail
        let c = composer
        if let o = c.original {
            let p = mail.policy(for: o, mailbox: mail.store?.mailbox(forFolder: o.folderId) ?? "me")
            let subject = p.redactDetails ? L("Private message") : (c.subject.isEmpty ? (o.subject.isEmpty ? L("(no subject)") : o.subject) : c.subject)
            let who = p.redactDetails ? L("Private") : (o.from?.display ?? L("(no sender)"))
            HStack(spacing: 8) {
                NSymbol(symbol(c.kind), size: 12).foregroundStyle(skin.brand ? skin.accentInk : .accentColor)
                Text(subject).font(skin.brand ? skin.sans(NV.Size.body, .medium) : .callout.weight(.semibold)).lineLimit(1).layoutPriority(1)
                Text("· \(who) · \(MessageRowView.time(o.received))")
                    .font(skin.brand ? skin.sans(NV.Size.bodySm) : .callout).foregroundStyle(.secondary).lineLimit(1)
                LabelPill(policy: p, origin: o.labelOrigin)   // the original's label stays visible
                Spacer(minLength: 6)
                if !originalInStack {
                    Button(ui.strip.expanded ? L("Hide original") : L("Show original")) { toggle(o) }
                        .nvButton(skin, .quiet).font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption)
                        .help(L("Show the message you're replying to (read-only). Esc hides it."))
                }
                if skin.brand && ComposeHost.shared.placement == .inline && mail.composer === c { ComposerPopButton() }   // ⇧⌘P / ⌥↩
                Button { mail.closeComposer(c) } label: { NSymbol("xmark", size: 11) }
                    .buttonStyle(.borderless)
                    .help(L("Close — keeps a draft if there's anything in it (Esc)"))
                    .accessibilityLabel(L("Close draft"))
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(skin.brand ? AnyShapeStyle(skin.soft.opacity(0.6)) : AnyShapeStyle(.quaternary.opacity(0.35)))
            .overlay(alignment: .bottom) { Rectangle().fill(skin.brand ? skin.hair2 : Color.secondary.opacity(0.2)).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Replying to %@", who))
            // Unknown / external / protected-elsewhere originals: the restriction notice keeps its own line.
            ReaderLabelLine(policy: p, origin: o.labelOrigin).padding(.horizontal, 18)
        }
    }

    private func toggle(_ o: MailMessage) {
        ui.strip.toggle()
        guard ui.strip.expanded, !hasPaneOriginal, ui.original?.header.id != o.id, !ui.loadingOriginal else { return }
        ui.loadingOriginal = true
        let mail = app.mail
        let state = ui
        Task { @MainActor in
            let r = await mail.standaloneReader(id: o.id)   // same fail-closed rules as the pane's reader
            state.original = r
            state.loadingOriginal = false
        }
    }

    private func symbol(_ k: MailDraft.Kind) -> String {
        switch k { case .forward: "arrowshape.turn.up.right"; case .replyAll: "arrowshape.turn.up.left.2"; default: "arrowshape.turn.up.left" }
    }
}

/// The expanded original: the reader's own body path (policy, protected bodies, remote-image gate), read-only.
struct ComposeOriginalView: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState?
    var allowCopy: Bool?
    var loading: Bool
    var body: some View {
        if let r = reader {
            let p = r.policy
            let copy = allowCopy ?? (p.allowCopy && app.trust.effectivePolicy.allowCopyOut)
            VStack(spacing: 0) {
                if let h = LabelDisplay.visibleMarking(p, origin: r.header.labelOrigin) {
                    HeaderMarking(text: h, color: p.label.map { Color(hex: $0.hexColor, fallback: .red) })
                }
                if !p.redactDetails && !r.header.attachments.isEmpty { AttachmentChips(reader: r).padding(.horizontal, 18).padding(.vertical, 4) }
                ReaderBody(reader: r, allowCopy: copy)
                if let f = p.footerMarking { FooterMarking(text: f) }
            }
            .overlay { if let w = p.watermark { Watermark(text: w) } }
        } else {
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Text(loading ? L("Loading…") : L("The original isn't available.")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Compact header row

struct ComposerCompactHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState
    var ui: ComposeUIState

    var body: some View {
        @Bindable var c = composer
        let mail = app.mail
        let tree = mail.compliance.labelTree()
        let ids = mail.settings.identities
        let cc = ComposeLayout.showsCcBcc(revealed: c.showCcBcc, ccCount: c.cc.count, bccCount: c.bcc.count,
                                          pendingText: !c.ccText.isEmpty || !c.bccText.isEmpty)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                RecipientField(field: .to, composer: c, autofocus: true)   // COMPOSE-HOOK (ComposerAssist.swift)
                if cc {
                    RecipientField(field: .cc, composer: c)
                    RecipientField(field: .bcc, composer: c)
                }
            }
            if !cc {
                Button(L("Cc/Bcc")) { c.showCcBcc = true }
                    .nvButton(skin, .quiet).font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption)
                    .help(L("Add Cc / Bcc recipients"))
            }
            // Compliance: the draft's label, always visible; click → the Outlook-structured picker (LabelPicker.swift).
            SensitivityLabelPicker(tree: tree, currentId: c.labelId, floorLabelId: c.floorLabelId, compact: true) {
                c.setLabel($0, engine: mail.compliance)
            }
            if ComposeLayout.showsFrom(identityCount: ids.count) {
                Menu {
                    ForEach(ids, id: \.self) { i in
                        Toggle(ComposerFromRow.describe(i), isOn: Binding(get: { c.from == i }, set: { if $0 { c.from = i } }))
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let f = c.from, f.mode != .selfSend { MailboxBadge(mailbox: f.mailbox, size: 14) }
                        Text(L("From")).foregroundStyle(.secondary)
                        Text(c.from.map { $0.mode == .selfSend ? $0.address : ComposerFromRow.describe($0) } ?? L("Choose")).lineLimit(1)
                    }
                    .font(skin.brand ? skin.sans(NV.Size.bodySm) : .caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(c.from.map(ComposerFromRow.describe) ?? L("From"))
                .accessibilityLabel(L("From"))
            }
            ComposerMoreMenu(composer: c, ui: ui)
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 6)
    }
}

/// ⋯: the rarer composer options.
struct ComposerMoreMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState
    var ui: ComposeUIState

    var body: some View {
        @Bindable var c = composer
        @Bindable var e = composer.editor
        let mail = app.mail
        let prefs = mail.composerPrefs
        let lib = mail.templateLibrary
        let blocked = mail.attachGateReason(c)
        Menu {
            Toggle(L("Show Cc and Bcc"), isOn: $c.showCcBcc)
            if c.kind != .new { Toggle(L("Edit Subject"), isOn: Binding(get: { ui.subjectRevealed }, set: { ui.subjectRevealed = $0 })) }
            Menu(L("Importance")) {
                ForEach([Importance.normal, .high, .low], id: \.self) { i in
                    Toggle(i == .high ? L("High") : i == .low ? L("Low") : L("Normal"),
                           isOn: Binding(get: { c.importance == i }, set: { if $0 { c.importance = i } }))
                }
            }
            Menu(L("Send Later")) {
                ForEach(TimePreset.sendLater, id: \.title) { p in
                    Button("\(p.title) — \(p.date().formatted(date: .abbreviated, time: .shortened))") { mail.send(c, at: p.date()) }
                }
                Button(L("Custom…")) { c.showSendLater = true }
            }
            Divider()
            if !lib.templates.isEmpty {
                Menu(L("Templates")) {
                    ForEach(lib.templates) { t in Button(t.shortcut.isEmpty ? t.name : "\(t.name)  ;\(t.shortcut)") { mail.insertTemplate(t, in: c) } }
                }
            }
            Menu(L("Insert")) {
                Button(L("Table 2 × 2")) { e.insertTable(rows: 2, columns: 2) }
                Button(L("Table 3 × 3")) { e.insertTable(rows: 3, columns: 3) }
                Button(L("Table 4 × 3")) { e.insertTable(rows: 4, columns: 3) }
                Button(L("Table 5 × 4")) { e.insertTable(rows: 5, columns: 4) }
                Button(L("Horizontal Line")) { e.insertRule() }
            }
            if !prefs.signatures.isEmpty {
                Menu(L("Signature")) {
                    Toggle(L("No signature"), isOn: Binding(get: { e.signatureId == nil }, set: { if $0 { e.applySignature(nil, byUser: true) } }))
                    ForEach(prefs.signatures) { s in
                        Toggle(s.name, isOn: Binding(get: { e.signatureId == s.id }, set: { if $0 { e.applySignature(s, byUser: true) } }))
                    }
                }
            }
            Menu(L("Spelling Language")) {
                Toggle(L("Detect Automatically") + (e.detectedLanguage.map { " (\($0.title))" } ?? ""),
                       isOn: Binding(get: { e.spellChoice == nil }, set: { if $0 { e.spellChoice = nil; e.applySpellLanguage() } }))
                ForEach(DraftLanguage.allCases) { l in
                    Toggle(l.title, isOn: Binding(get: { e.spellChoice == l }, set: { if $0 { e.spellChoice = l; e.applySpellLanguage() } }))
                }
            }
            Toggle(L("Live Markdown"), isOn: $e.liveMarkdown)
            Toggle(L("Formatting Bar"), isOn: Binding(get: { ui.formatPinned }, set: { ui.formatPinned = $0 }))
            Divider()
            if DriveHub.shared.isConfigured {
                Button(L("Attach from OneDrive…")) { DriveHub.shared.open(for: c) }.disabled(blocked != nil)
            }
            Button(L("Encryption: niivo can't encrypt yet — encrypting labels are sent from Outlook")) {}.disabled(true)
            if skin.brand && mail.composer === c {
                Button(ComposeHost.shared.placement == .inline ? L("Pop Out") : L("Pop Back In")) { ComposeHost.shared.toggle() }
            }
        } label: { NSymbol("ellipsis.circle", size: 14) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("More options: send later, templates, signature, importance, Markdown…"))
        .accessibilityLabel(L("More composer options"))
    }
}

// MARK: - Notices (capped, so they can never squeeze the editor)

struct ComposerNotices: View {
    @Environment(\.skin) private var skin
    var composer: ComposerState
    var ui: ComposeUIState
    var cap: CGFloat

    var body: some View {
        let c = composer
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let e = c.error { NLabel(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(skin.brand ? skin.danger : .red) }
                PurviewComposerNotices(composer: c)   // PURVIEW-HOOK
                if let msg = c.floorMessage { NLabel(msg, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                ComposerWarnings(composer: c)
                MailTipsBanners(composer: c)   // COMPOSE-HOOK: kept mounted (its zero-height spacer keeps the MailTips task alive)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                if abs(h - ui.noticesHeight) > 0.5 { ui.noticesHeight = h }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(ui.noticesHeight, cap))
    }
}
