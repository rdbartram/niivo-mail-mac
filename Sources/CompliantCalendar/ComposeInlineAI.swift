import SwiftUI
import AppKit
import CalendarCore
import MailCore

// COMPOSE-LAYOUT (docs/COMPOSE-LAYOUT.md): editor box (all remaining height, floating format bar, inline AI
// suggestion), the slim AI bar, the AI ✦ menu and the footer. Keep / Undo are AIAssistModel.acceptPreview / undoAI.

// MARK: - Editor box

struct ComposerEditorBox: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState
    var ui: ComposeUIState
    var attachBlocked: String?
    var minHeight: CGFloat = 160

    var body: some View {
        let mail = app.mail
        let c = composer
        let primary = mail.composer === c
        @Bindable var aiState = mail.ai.composer
        let pending = primary && aiState.preview != nil
        let mode = ComposeLayout.formatBarVisible(pinned: ui.formatPinned, selectionLength: c.editor.selectionLength)
        VStack(spacing: 0) {
            if mode == .pinned {
                bar(c).padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(skin.brand ? skin.hair : Color.secondary.opacity(0.15)).frame(height: 1) }
            }
            ZStack(alignment: .topLeading) {
                // AI-HOOK: the editor mirrors its text into c.body and maps its selection for Rewrite. It stays mounted
                // under a pending suggestion (one NSTextView per composer, bound to that composer's storage).
                MailRichEditor(state: c.editor, selection: primary ? $aiState.selection : nil, plain: c.body, brand: app.theme.brand)
                    .id(c.id)
                    .opacity(pending ? 0 : 1)
                    .allowsHitTesting(!pending)
                    .accessibilityHidden(pending)
                if pending, let p = aiState.preview {
                    AISuggestionBlock(before: p.before, after: p.after, range: p.range)
                }
            }
            .frame(minHeight: minHeight, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if mode == .floating && !pending {
                    bar(c).padding(.horizontal, 8).padding(.vertical, 3)
                        .niivoGlassCapsule()   // GLASS: the floating AI bar (solid card with Reduce Transparency / Increase Contrast)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .onChange(of: pending, initial: true) { was, on in
            // While a suggestion waits, the editor is read-only and gives up focus: ⏎ keeps, Esc discards. Afterwards
            // the cursor goes back into the text.
            guard let tv = c.editor.textView else { return }
            tv.isEditable = !on
            if on, tv.window?.firstResponder === tv { tv.window?.makeFirstResponder(nil) }
            if was && !on { tv.window?.makeFirstResponder(tv) }
        }
    }

    private func bar(_ c: ComposerState) -> some View {
        ComposerFormatBar(editor: c.editor, attachBlocked: attachBlocked, onAttach: { c.pickAttachments() }, formattingOnly: true)
    }
}

/// The pending AI text in the editor box, highlighted where it replaces (the whole draft, or only the selection).
struct AISuggestionBlock: View {
    @Environment(\.skin) private var skin
    var before: String
    var after: String
    var range: Range<String.Index>?
    var body: some View {
        let seg = AISuggestionText.segments(before: before, after: after, range: range)
        var mid = AttributedString(seg.suggestion)
        mid.backgroundColor = skin.brand ? skin.accentSoft : Color.accentColor.opacity(0.16)
        let text = AttributedString(seg.prefix) + mid + AttributedString(seg.suffix)
        return ScrollView {
            Text(text)
                .font(skin.brand ? skin.sans(NV.Size.body) : .body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .background(skin.brand ? AnyShapeStyle(skin.card) : AnyShapeStyle(.background))
        .overlay(alignment: .leading) { Rectangle().fill(skin.brand ? skin.accentFill : Color.accentColor).frame(width: 2) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("AI suggestion"))
        .accessibilityValue(seg.suggestion)
    }
}

// MARK: - Inline AI bar

struct AIInlineBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState

    var body: some View {
        let ai = app.mail.ai
        @Bindable var s = ai.composer
        let phase = AISuggestionPhase.of(busy: s.busy != nil, hasPreview: s.preview != nil, canUndo: s.undoBody != nil)
        let extra = s.error != nil || !s.notes.isEmpty || s.checking || !s.findings.isEmpty
        if ai.enabled, phase != .idle || extra {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    switch phase {
                    case .working:
                        ProgressView().controlSize(.small)
                        Text(s.busy ?? "").font(small)
                        NButton(L("Cancel"), kind: .quiet) { s.cancel() }
                    case .pending:
                        NSymbol("sparkles", size: 11).foregroundStyle(skin.brand ? skin.accentInk : .accentColor)
                        Text(s.preview?.range == nil ? L("AI draft") : L("AI rewrite")).font(small)
                        if let v = s.voice {
                            // Owner: "I don't see the option to update the voice" — the badge itself opens the layers.
                            let vm = VoiceEditorModel.shared
                            let who = app.mail.voiceCounterpart(original: composer.original, to: composer.to)
                            let items = vm.items(for: who, mail: app.mail) { vm.showComposerEditor = true }
                            if items.isEmpty {
                                Text("· " + v.badge).font(small).foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                Menu {
                                    ForEach(items) { i in Button(i.title) { i.action() } }
                                    Divider()
                                    Button(L("Edit My Voice…")) { vm.openMe(app.mail) }
                                } label: {
                                    HStack(spacing: 3) { Text("· " + v.badge).lineLimit(1); NSymbol("chevron.down", size: 8) }
                                        .font(small).foregroundStyle(.secondary)
                                }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help(L("Edit the voice notes used for this draft"))
                            }
                        }
                        Spacer(minLength: 6)
                        NButton(L("Keep ⏎"), kind: .primary) { ai.acceptPreview() }.keyboardShortcut(.defaultAction)
                            .help(L("Keep the suggestion (one undo restores your text and signature)"))
                        NButton(L("Retry"), kind: .quiet) { retry(ai) }.disabled(s.retry == nil)
                        NButton(L("Discard ⎋"), kind: .quiet) { discard(s) }
                        if !s.why.isEmpty || s.pendingSignature != nil {
                            NButton(L("Why"), kind: .quiet) { s.showWhy.toggle() }
                                .popover(isPresented: $s.showWhy) { VoiceWhyView(lines: s.why, plan: s.pendingSignature) }
                        }
                    case .kept:
                        NSymbol("sparkles", size: 11).foregroundStyle(.secondary)
                        Text(L("AI text kept")).font(small).foregroundStyle(.secondary)
                        NButton(L("Undo AI change"), kind: .quiet) { ai.undoAI() }
                        Spacer(minLength: 6)
                        Button { s.undoBody = nil; s.undoSignature = nil } label: { NSymbol("xmark", size: 9) }
                            .buttonStyle(.borderless).help(L("Dismiss")).accessibilityLabel(L("Dismiss"))
                    case .idle:
                        EmptyView()
                    }
                    if phase == .working || phase == .idle { Spacer(minLength: 0) }
                    if s.checking { ProgressView().controlSize(.small); Text(L("Checking before send…")).font(small) }
                }
                if let e = s.error { Text(e).font(.caption).foregroundStyle(.secondary) }
                ForEach(s.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                if !s.findings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(s.findings) { f in NLabel(f.text, systemImage: "exclamationmark.bubble", size: 12).font(.callout) }
                        Text(L("⌘↩ again sends anyway")).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(skin.brand ? AnyShapeStyle(skin.soft) : AnyShapeStyle(.quaternary.opacity(0.4)), in: RoundedRectangle(cornerRadius: skin.brand ? 0 : 8))
                    .overlay(alignment: .leading) { if skin.brand { Rectangle().fill(Color.orange).frame(width: 3) } }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .overlay(alignment: .top) { Rectangle().fill(skin.brand ? skin.hair : Color.secondary.opacity(0.15)).frame(height: 1) }
        }
    }

    private var small: Font { skin.brand ? skin.mono(NV.Size.labelSm) : .caption }

    private func discard(_ s: AIComposerState) { s.preview = nil; s.pendingSignature = nil }

    private func retry(_ ai: AIAssistModel) {
        guard let r = ai.composer.retry else { return }
        discard(ai.composer)
        switch r {
        case .draft(let i): ai.draft(intent: i)
        case .rewrite(let m): ai.rewrite(m)
        }
    }
}

/// AI ✦ in the composer footer: Draft reply…, intents, Rewrite ▸, Voice ▸, Why. Primary composer only (AI gating and
/// the label gate are decided in AIAssistModel / AIAssistant as before).
struct AIComposeMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState

    var body: some View {
        let ai = app.mail.ai
        @Bindable var s = ai.composer
        let vm = VoiceEditorModel.shared
        @Bindable var voiceModel = vm
        let canDraft = composer.original != nil && ai.available(.draftReply)
        let who = app.mail.voiceCounterpart(original: composer.original, to: composer.to)
        let voiceItems = composer.original == nil ? [] : vm.items(for: who, mail: app.mail) { vm.showComposerEditor = true }
        Menu {
            Button(L("Draft Reply…")) { s.showPopover = true }.disabled(!canDraft)
            Section(L("Reply")) {
                ForEach(AIReplyIntent.allCases) { i in
                    Button(i.title) { intent(i, ai) }.disabled(!canDraft)
                }
            }
            Menu(L("Rewrite")) {
                ForEach([AIRewriteMode.polish, .shorten, .friendly, .formal]) { m in
                    Button(m == .polish ? L("Fix Grammar and Flow") : m.title) { ai.rewrite(m) }
                }
                Menu(L("Translate")) {
                    ForEach([AIRewriteMode.toEnglish, .toGerman, .toFrench, .toItalian]) { m in Button(m.title) { ai.rewrite(m) } }
                }
            }
            Section(L("Voice")) {
                ForEach(voiceItems) { i in Button(i.title) { i.action() } }
                Button(L("Edit My Voice…")) { vm.openMe(app.mail) }
            }
            // Why: on the pending suggestion bar (AIInlineBar), which hosts its popover.
        } label: {
            HStack(spacing: 4) { NSymbol("sparkles", size: 12); Text(L("AI")) }
                .font(skin.brand ? skin.mono(NV.Size.labelSm, .medium) : .callout)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("AI: draft a reply, rewrite the selection (or the whole text), voice (⇧⌘R drafts)"))
        .accessibilityLabel(L("AI assistance"))
        .popover(isPresented: $s.showPopover) { AIDraftPopover() }
        .background(Color.clear.popover(isPresented: $voiceModel.showComposerEditor) { VoiceQuickEditor { vm.showComposerEditor = false } })
    }

    /// In an open reply the intents draft into it (AIAssistModel.intent would open another reply).
    private func intent(_ i: AIReplyIntent, _ ai: AIAssistModel) {
        if i == .delegate { ai.composer.options.instruction = "Delegate to: "; ai.composer.showPopover = true; return }
        ai.draft(intent: i)
    }
}

// MARK: - Footer

struct ComposerFooter: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState
    var ui: ComposeUIState
    var attachBlocked: String?

    var body: some View {
        @Bindable var c = composer
        let mail = app.mail
        let primary = mail.composer === c
        let pending = primary && mail.ai.composer.preview != nil
        VStack(spacing: 8) {
            if c.showSendLater {
                HStack {
                    DatePicker(L("Send at"), selection: $c.customSendAt, in: Date()...)
                    NButton(L("Schedule"), kind: .primary) { mail.send(c, at: c.customSendAt) }
                    NButton(L("Cancel"), kind: .quiet) { c.showSendLater = false }
                }
                Text(mail.settings.serverDeferredSend
                     ? "Exchange holds the message and sends it at that time (deferred send, unverified path)."
                     : "Sent by this Mac when it's due: the draft waits in Drafts, and if the Mac is off or asleep it goes out the next time Mail is opened.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button { c.pickAttachments() } label: { NSymbol("paperclip", size: 14) }
                    .buttonStyle(.borderless).disabled(attachBlocked != nil)
                    .help(attachBlocked ?? L("Attach files (or drop / paste them)"))
                    .accessibilityLabel(L("Attach files"))
                Button { ui.formatPinned.toggle() } label: {
                    Text("Aa").font(skin.brand ? skin.sans(NV.Size.body, .medium) : .callout.weight(.medium))
                        .padding(.horizontal, 4)
                        .background { if ui.formatPinned { Rectangle().fill(skin.brand ? skin.soft : Color.accentColor.opacity(0.18)) } }
                }
                .buttonStyle(.borderless)
                .help(ui.formatPinned ? L("Hide the formatting bar") : L("Show the formatting bar (it also appears when you select text)"))
                .accessibilityLabel(L("Formatting bar"))
                .accessibilityAddTraits(ui.formatPinned ? .isSelected : [])
                if primary && mail.ai.enabled { AIComposeMenu(composer: c) }   // AI-HOOK
                if let at = c.savedAt {
                    Text(L("Saved %@", at.formatted(date: .omitted, time: .shortened))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button { mail.discardComposer(c) } label: { NSymbol("trash", size: 14) }
                    .buttonStyle(.borderless)
                    .help(L("Discard draft"))
                    .accessibilityLabel(L("Discard"))
                sendButton(c, pending: pending)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background {
            // Esc: discard a pending suggestion → hide the original → close (empty closes silently, else saved).
            Button("") { escape(c) }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    /// Send ▾ as one split control: Send (⌘↩) and the send-later presets.
    private func sendButton(_ c: ComposerState, pending: Bool) -> some View {
        let mail = app.mail
        let enabled = ComposeLayout.sendEnabled(suggestionPending: pending)
        return HStack(spacing: 0) {
            Button { mail.send(c) } label: { NLabel(L("Send"), systemImage: "paperplane.fill") }
                .nvButton(skin, .primary).keyboardShortcut(.return, modifiers: .command)
                .disabled(!enabled)
                .help(enabled ? L("Send (⌘↩) — 10 seconds to undo") : L("Keep or discard the AI suggestion first"))
            Menu {
                ForEach(TimePreset.sendLater, id: \.title) { p in
                    Button("\(p.title) — \(p.date().formatted(date: .abbreviated, time: .shortened))") { mail.send(c, at: p.date()) }
                }
                Divider()
                Button(L("Custom…")) { c.showSendLater = true }
            } label: { NSymbol("chevron.down", size: 10) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 6)
            .disabled(!enabled)
            .help(L("Send later"))
            .accessibilityLabel(L("Send later"))
        }
    }

    private func escape(_ c: ComposerState) {
        let mail = app.mail
        let s = mail.ai.composer
        let pending = mail.composer === c && s.preview != nil
        switch ComposeLayout.escape(suggestionPending: pending, originalExpanded: ui.strip.expanded) {
        case .discardSuggestion: s.preview = nil; s.pendingSignature = nil
        case .collapseOriginal: ui.strip.expanded = false
        case .closeComposer: mail.closeComposer(c)
        }
    }
}
