import SwiftUI
import CalendarCore
import MailCore

/// Composer (2026-11-20 calm layout, docs/COMPOSE-LAYOUT.md): context strip (replies) or a slim title row (new mail),
/// one compact header row, capped notices, the editor with all remaining height, the slim AI bar, the footer.
/// Still says out loud when mail leaves the organisation, when a label can't be lowered, and when "send later"
/// depends on this Mac being on.
struct ComposerView: View {
    @Environment(AppModel.self) private var app
    var composer: ComposerState
    /// Inline (reading pane) or in a niivo window: no sheet sizing.
    var inline = false
    /// Pane takeover (InlineReplyPane): the pane's reader is the original — "Show original" expands it directly.
    var paneOriginal: ReaderState? = nil
    var paneAllowCopy: Bool? = nil
    /// Conversation view: the answered message is already expanded in the stack above.
    var originalInStack = false

    var body: some View {
        let mail = app.mail
        @Bindable var c = composer
        let ui = ComposeUIHub.shared.state(c)
        let lp = mail.labelPolicy(labelId: c.labelId)
        let blocked = attachBlockReason(lp)
        GeometryReader { geo in
            VStack(spacing: 0) {
                if c.original != nil {
                    ComposeContextStripView(composer: c, ui: ui, originalInStack: originalInStack, hasPaneOriginal: paneOriginal != nil)
                    if ui.strip.expanded && !originalInStack {
                        ComposeOriginalView(reader: paneOriginal ?? ui.original, allowCopy: paneOriginal != nil ? paneAllowCopy : nil,
                                            loading: ui.loadingOriginal)
                            .frame(height: max(120, geo.size.height * ComposeLayout.originalMaxFraction))
                            .overlay(alignment: .bottom) { Rectangle().fill(app.skin.hair2).frame(height: 1) }
                    }
                } else {
                    ComposerHeader(composer: c)
                }
                ComposerCompactHeader(composer: c, ui: ui)
                if ComposeLayout.showsSubject(isReply: c.kind != .new && c.kind != .forward, revealed: ui.subjectRevealed) {
                    TextField(L("Subject"), text: $c.subject).textFieldStyle(.plain)
                        .font(app.theme.brand ? app.skin.sans(NV.Size.bodyLg) : .title3.weight(.medium))
                        .padding(.horizontal, 18).padding(.bottom, 6)
                }
                Rectangle().fill(app.theme.brand ? app.skin.hair : Color.secondary.opacity(0.15)).frame(height: 1)
                ComposerNotices(composer: c, ui: ui, cap: max(60, geo.size.height * 0.18))
                if let h = lp.headerMarking { HeaderMarking(text: h, color: lp.label.map { Color(hex: $0.hexColor, fallback: .red) }) }
                ComposerEditorBox(composer: c, ui: ui, attachBlocked: blocked, minHeight: max(80, min(160, geo.size.height * 0.3)))
                VStack(alignment: .leading, spacing: 6) {
                    ComposerAttachmentChips(editor: c.editor)
                    CloudAttachmentRow(composer: c)   // ONEDRIVE-HOOK
                    ComposerExtrasRow(composer: c)   // COMPOSE-HOOK: reopened draft's server attachments + link chips
                    ComposerHistoryBlock(composer: c)   // COMPOSE2-HOOK: collapsed quoted history (ComposerHistory.swift)
                    if let f = lp.footerMarking { FooterMarking(text: f) }
                }
                .padding(.horizontal, 18).padding(.top, 4)
                if mail.composer === c {   // AI-HOOK (primary composer only) COMPOSE2-HOOK
                    if mail.ai.enabled && c.original != nil {   // VOICE2-HOOK: voice suggestions card (was in AIComposerBar)
                        VoiceLearnCard(composer: c).padding(.horizontal, 18)
                    }
                    AIInlineBar(composer: c)
                }
                Rectangle().fill(app.theme.brand ? app.skin.hair : Color.secondary.opacity(0.15)).frame(height: 1)
                ComposerFooter(composer: c, ui: ui, attachBlocked: blocked)
            }
        }
        .frame(minWidth: inline ? 0 : 640, idealWidth: inline ? nil : 720, minHeight: inline ? 0 : 600, idealHeight: inline ? nil : 680)
        .background(app.theme.brand ? app.skin.ground : .clear)
        .overlay { if let w = lp.watermark { Watermark(text: w) } }
        .interactiveDismissDisabled()
        .onChange(of: c.from) { _, _ in mail.identityChanged(c) }
        // The sheet is its own NSWindow: apply capture exclusion here too (label of the draft or the original,
        // plus the device trust policy).
        .background(WindowSharingGuard(blocked: composerCaptureBlocked(lp)))
        .drivePickerSheet(for: c, captureBlocked: composerCaptureBlocked(lp))   // ONEDRIVE-HOOK
    }
}

extension ComposerView {
    func composerCaptureBlocked(_ lp: ContentPolicy) -> Bool {
        if AppModelBox.isFixture && ProcessInfo.processInfo.environment["CC_DEMO_ALLOW_CAPTURE"] == "1" { return false }
        var p = lp
        if let o = composer.original { p = p.merged(with: app.mail.policy(for: o, mailbox: app.mail.store?.mailbox(forFolder: o.folderId) ?? "me")) }
        return p.preventScreenCapture || app.trust.blocksScreenCapture
    }

    /// Attachment gate: the draft's label merged with the original's (see AttachmentGate). TrustPolicy has no upload
    /// switch and `allowAttachmentsDownload` governs received files, so neither is consulted or loosened here.
    func attachBlockReason(_ lp: ContentPolicy) -> String? {
        var p = lp
        if let o = composer.original { p = p.merged(with: app.mail.policy(for: o, mailbox: app.mail.store?.mailbox(forFolder: o.folderId) ?? "me")) }
        return AttachmentGate.blockReason(p)
    }
}

struct ComposerHeader: View {
    @Environment(\.skin) private var skin
    @Environment(AppModel.self) private var app
    var composer: ComposerState
    var body: some View {
        HStack {
            if skin.brand {
                MonoLabel(title, color: skin.ink, bracket: true, wide: true, weight: .medium)
                NiivoCursor(size: 8)
            } else {
                NSymbol(icon).foregroundStyle(.tint)
                Text(title).font(.headline)
            }
            Spacer()
            if skin.brand && ComposeHost.shared.placement == .inline && app.mail.composer === composer { ComposerPopButton() }   // COMPOSE2-HOOK: pane draft only
            Button { app.mail.closeComposer(composer) } label: { NSymbol("xmark", size: 11) }   // COMPOSE-LAYOUT: no footer Close
                .buttonStyle(.borderless)
                .help(L("Close — keeps a draft if there's anything in it (Esc)"))
                .accessibilityLabel(L("Close draft"))
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }
    private var title: String {
        switch composer.kind { case .new: "New Message"; case .reply: "Reply"; case .replyAll: "Reply All"; case .forward: "Forward" }
    }
    private var icon: String {
        switch composer.kind { case .new: "square.and.pencil"; case .reply: "arrowshape.turn.up.left"; case .replyAll: "arrowshape.turn.up.left.2"; case .forward: "arrowshape.turn.up.right" }
    }
}

struct ComposerFromRow: View {
    @Environment(AppModel.self) private var app
    var composer: ComposerState
    var body: some View {
        @Bindable var c = composer
        let ids = app.mail.settings.identities
        HStack {
            Text(app.skin.caps("From")).font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .body).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            if app.theme.brand {
                NPicker("", selection: $c.from, options: ids.map { Optional($0) }, label: { $0.map(Self.describe) ?? "Choose" })
            } else {
                Picker(L("From"), selection: $c.from) {
                    ForEach(ids, id: \.self) { i in Text(Self.describe(i)).tag(Optional(i)) }
                }
                .labelsHidden().fixedSize()
            }
            if let f = c.from, f.mode != .selfSend { MailboxBadge(mailbox: f.mailbox, size: 16) }
            Spacer()
            Button(c.showCcBcc ? "Hide Cc/Bcc" : "Cc/Bcc") { c.showCcBcc.toggle() }.nvButton(app.skin, .quiet).font(.caption)
        }
    }
    static func describe(_ i: SendIdentity) -> String {
        switch i.mode {
        case .selfSend: return "\(i.name) <\(i.address)>"
        case .sendAs: return "\(i.name) <\(i.address)> · send as"
        case .sendOnBehalf: return "You on behalf of \(i.name) <\(i.address)>"
        }
    }
}

struct ComposerWarnings: View {
    @Environment(AppModel.self) private var app
    var composer: ComposerState
    var body: some View {
        let w = app.mail.externalWarning(composer)
        if let msg = w.message {
            HStack(alignment: .top, spacing: 8) {
                NSymbol(w.isStrong ? "exclamationmark.octagon.fill" : "globe").foregroundStyle(w.isStrong ? .red : .orange)
                Text(msg).font(.callout)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background((w.isStrong ? app.skin.danger : Color.orange).opacity(0.12), in: app.skin.rounded)
            .overlay(alignment: .leading) { if app.theme.brand { Rectangle().fill(w.isStrong ? app.skin.danger : Color.orange).frame(width: 3) } }
        }
    }
}
