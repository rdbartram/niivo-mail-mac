import SwiftUI
import AppKit
import CalendarCore
import MailCore

// COMPOSE-LAYOUT (docs/COMPOSE-LAYOUT.md "AI inline", 2026-11-26): editor box (all remaining height, floating format
// bar, the AI marker), the slim AI bar, the AI ✦ menu, the ⌘J actions palette and the footer. AI text is applied
// INTO the editor (editable at once) and marked until the user edits or keeps it; Undo puts back what was there.
// State machine: MailCore AIAppliedEdit (CoreSelfTest). Calls: AIAssistModel.draft / edit / tryAgain / undoApplied.

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
        // The marker only while the AI span refers to exactly this text (it is redrawn after every edit).
        let mark = primary ? aiState.applied.flatMap { $0.body == c.body ? $0.markRange : nil } : nil
        let mode = ComposeLayout.formatBarVisible(pinned: ui.formatPinned, selectionLength: c.editor.selectionLength)
        VStack(spacing: 0) {
            if mode == .pinned {
                bar(c).padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(skin.brand ? skin.hair : Color.secondary.opacity(0.15)).frame(height: 1) }
            }
            // AI-HOOK: the editor mirrors its text into c.body; AI text is written into c.body and reconciled into the
            // storage; the marker is a layout-manager temporary attribute (never in the HTML that is saved or sent).
            MailRichEditor(state: c.editor, selection: primary ? $aiState.selection : nil, plain: c.body, brand: app.theme.brand,
                           aiMark: mark.map { NSRange(location: $0.lowerBound, length: $0.count) })
                .id(c.id)
                .frame(minHeight: minHeight, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    // Floating format bar at the bottom: at the top it covered the first lines of the reply.
                    if mode == .floating {
                        bar(c).padding(.horizontal, 8).padding(.vertical, 3)
                            .niivoGlassCapsule()   // GLASS: the floating format bar (solid card with Reduce Transparency / Increase Contrast)
                            .padding(.bottom, 6)
                    }
                }
        }
        .padding(.horizontal, 12)
        .background {
            if primary {
                Color.clear.popover(isPresented: $aiState.showActions, arrowEdge: .bottom) { AIActionsPalette(composer: c) }
            }
        }
        .onAppear { wireShortcut(c) }
        .onChange(of: primary) { _, _ in wireShortcut(c) }
    }

    /// ⌘J inside the editor (ComposerTextView) opens the AI actions for the primary composer.
    private func wireShortcut(_ c: ComposerState) {
        let mail = app.mail
        c.editor.onAIActions = { [weak mail, weak c] in
            guard let mail, let c, mail.composer === c, mail.ai.settings.choice != .off || mail.ai.preview != nil else { return false }
            mail.ai.composer.showActions = true
            return true
        }
    }

    private func bar(_ c: ComposerState) -> some View {
        ComposerFormatBar(editor: c.editor, attachBlocked: attachBlocked, onAttach: { c.pickAttachments() }, formattingOnly: true)
    }
}

// MARK: - ⌘J actions palette

/// Type what to change ("make it punchier") or pick an action; ↩ runs the first row. Works on the selection, or the
/// whole text when nothing is selected. When the gate refuses, the reason is shown and nothing runs.
struct AIActionsPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState
    @FocusState private var focused: Bool

    var body: some View {
        let ai = app.mail.ai
        @Bindable var s = ai.composer
        let why = ai.editRefusal(composer)
        let rows = AIEditAction.palette(query: s.actionQuery)
        let selected = composer.editor.selectionLength
        let empty = AIEditText.target(body: composer.body, selection: nil, signaturePlain: composer.editor.signaturePlain).scope == .empty
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                NSymbol("sparkles", size: 12).foregroundStyle(skin.brand ? skin.accentInk : .accentColor)
                Text(selected > 0 ? L("Selection (%lld characters)", selected) : (empty ? L("New text") : L("Whole message")))
                    .font(small).foregroundStyle(.secondary)
                Spacer()
                Text("⌘J").font(small).foregroundStyle(.tertiary)
            }
            TextField(empty ? L("Ask AI to write…") : L("Ask AI to change…"), text: $s.actionQuery)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(why != nil)
                .onSubmit { if why == nil, let first = rows.first, !(empty && !first.isCustom) { run(first, ai) } }
            if let why {
                NLabel(why, systemImage: "lock", size: 11).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if empty, composer.original != nil {
                let replyWhy = ai.replyRefusal(composer)
                Button { s.showActions = false; ai.draft() } label: { row(L("Draft a Reply"), hint: nil) }
                    .buttonStyle(.plain).disabled(replyWhy != nil).help(replyWhy ?? L("Draft a reply in your voice"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, a in
                        let off = why != nil || (empty && !a.isCustom)
                        Button { run(a, ai) } label: { row(a.title, hint: i == 0 && !off ? "↩" : nil) }
                            .buttonStyle(.plain).disabled(off)
                            .help(why ?? (off ? L("Write something first, or type what AI should write") : a.title))
                    }
                }
            }
            .frame(maxHeight: 240)
            AIVoiceLine(composer: composer)
        }
        .padding(12).frame(width: 340)
        .background(skin.brand ? AnyShapeStyle(skin.card) : AnyShapeStyle(.clear))
        .onAppear { focused = true }
    }

    private func row(_ title: String, hint: String?) -> some View {
        HStack {
            Text(title).font(skin.brand ? skin.sans(NV.Size.body) : .body).lineLimit(1)
            Spacer()
            if let hint { Text(hint).font(small).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func run(_ a: AIEditAction, _ ai: AIAssistModel) {
        ai.composer.showActions = false
        ai.composer.actionQuery = ""
        ai.edit(a)
    }

    private var small: Font { skin.brand ? skin.mono(NV.Size.labelSm) : .caption }
}

/// "Voice: Me · Northwind · Zoé" with a switch per layer for the next request only.
struct AIVoiceLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState
    var body: some View {
        let ai = app.mail.ai
        let s = ai.composer
        let layers = ai.voiceLayers(for: composer)
        if !layers.isEmpty {
            HStack(spacing: 6) {
                Text(L("Voice:")).foregroundStyle(.secondary)
                ForEach(layers, id: \.kind) { l in
                    Toggle(l.title, isOn: Binding(get: { !s.voiceOff.contains(l.kind) },
                                                  set: { on in if on { s.voiceOff.remove(l.kind) } else { s.voiceOff.insert(l.kind) } }))
                        .toggleStyle(.checkbox).lineLimit(1)
                        .help(L("Use the %@ voice notes for the next AI request", l.title))
                }
                Spacer(minLength: 0)
            }
            .font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption)
        }
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
        let phase = AIInlinePhase.of(busy: s.busy != nil, applied: s.applied)
        let extra = s.error != nil || !s.notes.isEmpty || s.checking || !s.findings.isEmpty
        if ai.enabled || ai.settings.choice != .off, phase != .idle || extra {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    switch phase {
                    case .working:
                        ProgressView().controlSize(.small)
                        Text(s.busy ?? "").font(small)
                        Text(L("· keep typing, your text is safe")).font(small).foregroundStyle(.secondary).lineLimit(1)
                        NButton(L("Cancel"), kind: .quiet) { s.cancel() }
                    case .suggested:
                        NSymbol("sparkles", size: 11).foregroundStyle(skin.brand ? skin.accentInk : .accentColor)
                        Text(s.applied?.origin == .draft ? L("AI draft · edit it freely") : L("AI edit · edit it freely"))
                            .font(small).lineLimit(1)
                        voiceBadge(s)
                        Spacer(minLength: 6)
                        NButton(L("Keep"), kind: .primary) { ai.keepApplied() }
                            .help(L("Keep the AI text as yours (sending keeps it too)"))
                        tryAgain(ai)
                        NButton(L("Undo ⎋"), kind: .quiet) { ai.undoApplied() }
                            .help(L("Put back what was there before (your other edits stay)"))
                        whyButton(s)
                    case .edited:
                        NSymbol("sparkles", size: 11).foregroundStyle(.secondary)
                        Text(L("AI text, edited by you")).font(small).foregroundStyle(.secondary)
                        NButton(L("Undo AI Change"), kind: .quiet) { ai.undoApplied() }
                            .help(L("Put back the text from before the AI change (your edits inside it go too; ⌘Z steps back instead)"))
                        Spacer(minLength: 6)
                        Button { ai.keepApplied() } label: { NSymbol("xmark", size: 9) }
                            .buttonStyle(.borderless).help(L("Dismiss")).accessibilityLabel(L("Dismiss"))
                    case .idle:
                        EmptyView()
                    }
                    if phase == .working || phase == .idle { Spacer(minLength: 0) }
                    if s.checking { ProgressView().controlSize(.small); Text(L("Checking before send…")).font(small) }
                }
                if let e = s.error {
                    HStack(spacing: 6) {
                        Text(e).font(.caption).foregroundStyle(.secondary)
                        Button { s.error = nil } label: { NSymbol("xmark", size: 8) }.buttonStyle(.borderless).accessibilityLabel(L("Dismiss"))
                    }
                }
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

    @ViewBuilder private func voiceBadge(_ s: AIComposerState) -> some View {
        if let v = s.voice {
            // Owner: "I don't see the option to update the voice" — the badge itself opens the layers.
            let vm = VoiceEditorModel.shared
            let who = app.mail.voiceCounterpart(original: composer.original, to: composer.to)
            let items = vm.items(for: who, mail: app.mail) { vm.showComposerEditor = true }
            Menu {
                ForEach(items) { i in Button(i.title) { i.action() } }
                if !items.isEmpty { Divider() }
                Button(L("Edit My Voice…")) { vm.openMe(app.mail) }
            } label: {
                HStack(spacing: 3) { Text("· " + v.badge).lineLimit(1); NSymbol("chevron.down", size: 8) }
                    .font(small).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .font(small).foregroundStyle(.secondary)
            .help(L("The voice used for this text. Edit its notes, or switch layers off for the next request in the AI menu"))
        }
    }

    private func tryAgain(_ ai: AIAssistModel) -> some View {
        @Bindable var s = ai.composer
        return Menu {
            Button(L("Replace the AI Text")) { ai.tryAgain(.replace) }
            Button(L("Add Another Version Below")) { ai.tryAgain(.insertBelow) }
            Divider()
            Button(L("Try Again with Instruction…")) { s.showRetryInstruction = true }
        } label: {
            Text(L("Try Again")).font(skin.brand ? skin.mono(NV.Size.labelSm, .medium) : .callout)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(s.retry == nil)
        .help(L("Ask again; your own edits outside the AI text stay"))
        .popover(isPresented: $s.showRetryInstruction) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L("e.g. shorter, mention Friday, less formal"), text: $s.retryInstruction).textFieldStyle(.roundedBorder)
                    .onSubmit { retry(ai, .replace) }
                HStack {
                    AIVoiceLine(composer: composer)
                    NButton(L("Add Below"), kind: .quiet) { retry(ai, .insertBelow) }
                    NButton(L("Replace"), kind: .primary) { retry(ai, .replace) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(12).frame(width: 380)
        }
    }

    private func retry(_ ai: AIAssistModel, _ p: AIAppliedEdit.Placement) {
        let t = ai.composer.retryInstruction
        ai.composer.showRetryInstruction = false
        ai.composer.retryInstruction = ""
        ai.tryAgain(p, instruction: t)
    }

    @ViewBuilder private func whyButton(_ s: AIComposerState) -> some View {
        @Bindable var b = s
        if !s.why.isEmpty {
            NButton(L("Why"), kind: .quiet) { b.showWhy.toggle() }
                .popover(isPresented: $b.showWhy) { VoiceWhyView(lines: s.why, plan: nil) }
        }
    }

    private var small: Font { skin.brand ? skin.mono(NV.Size.labelSm) : .caption }
}

// MARK: - AI ✦ menu

/// AI ✦ in the composer footer: reply drafts, the editing actions (selection or whole text), voice layers. Items the
/// gate refuses stay visible, disabled, with the reason as the section's first line. Primary composer only.
struct AIComposeMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState

    var body: some View {
        let ai = app.mail.ai
        @Bindable var s = ai.composer
        let vm = VoiceEditorModel.shared
        @Bindable var voiceModel = vm
        let replyWhy = composer.original == nil ? nil : ai.replyRefusal(composer)
        let editWhy = ai.editRefusal(composer)
        let selected = composer.editor.selectionLength > 0
        let who = app.mail.voiceCounterpart(original: composer.original, to: composer.to)
        let voiceItems = vm.items(for: who, mail: app.mail) { vm.showComposerEditor = true }
        let layers = ai.voiceLayers(for: composer)
        Menu {
            if composer.original != nil {
                Section(L("Reply")) {
                    if let replyWhy { Text(replyWhy) }
                    Button(L("Draft Reply…")) { s.showPopover = true }.disabled(replyWhy != nil)
                    ForEach(AIReplyIntent.allCases) { i in
                        Button(i.title) { intent(i, ai) }.disabled(replyWhy != nil)
                    }
                }
            }
            Section(selected ? L("Edit Selection") : L("Edit Whole Message")) {
                if let editWhy { Text(editWhy) }
                ForEach([AIEditAction.rewrite, .fixGrammar, .shorten, .expand, .bullets]) { a in
                    Button(a.title) { ai.edit(a) }.disabled(editWhy != nil)
                }
                Menu(L("Change Tone")) {
                    ForEach(AIEditTone.allCases) { t in Button(t.title) { ai.edit(.tone(t)) } }
                }
                .disabled(editWhy != nil)
                Menu(L("Translate")) {
                    ForEach(AIEditAction.translations, id: \.self) { l in Button(AIEditAction.translate(l).title) { ai.edit(.translate(l)) } }
                }
                .disabled(editWhy != nil)
                Button(L("Ask AI to Change… (⌘J)")) { s.showActions = true }
                    .disabled(editWhy != nil)
            }
            Section(layers.isEmpty ? L("Voice") : "Voice: " + layers.map(\.title).joined(separator: " · ")) {
                ForEach(layers, id: \.kind) { l in
                    Toggle(L("Use %@ (next request)", l.title), isOn: Binding(get: { !s.voiceOff.contains(l.kind) },
                                                                              set: { on in if on { s.voiceOff.remove(l.kind) } else { s.voiceOff.insert(l.kind) } }))
                }
                ForEach(voiceItems) { i in Button(i.title) { i.action() } }
                Button(L("Edit My Voice…")) { vm.openMe(app.mail) }
            }
        } label: {
            HStack(spacing: 4) { NSymbol("sparkles", size: 12); Text(L("AI")) }
                .font(skin.brand ? skin.mono(NV.Size.labelSm, .medium) : .callout)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("AI: draft a reply, rewrite / shorten / translate the selection or the whole text, voice (⌘J)"))
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
        let working = primary && mail.ai.composer.busy != nil
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
                if primary && (mail.ai.enabled || mail.ai.settings.choice != .off) { AIComposeMenu(composer: c) }   // AI-HOOK: visible (with reasons) when policy blocks
                if let at = c.savedAt {
                    Text(L("Saved %@", at.formatted(date: .omitted, time: .shortened))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button { mail.discardComposer(c) } label: { NSymbol("trash", size: 14) }
                    .buttonStyle(.borderless)
                    .help(L("Discard draft"))
                    .accessibilityLabel(L("Discard"))
                sendButton(c, working: working)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background {
            // Esc: discard a pending suggestion → hide the original → close (empty closes silently, else saved).
            Button("") { escape(c) }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            // ⌘J from a header field (the editor handles it itself in ComposerTextView). Outlook's ⌘J (Forward) is
            // disabled while a composer is open.
            if primary && (mail.ai.enabled || mail.ai.settings.choice != .off) {
                Button("") { mail.ai.composer.showActions = true }.keyboardShortcut("j", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
    }

    /// Send ▾ as one split control: Send (⌘↩) and the send-later presets.
    private func sendButton(_ c: ComposerState, working: Bool) -> some View {
        let mail = app.mail
        let enabled = ComposeLayout.sendEnabled(aiWorking: working)
        return HStack(spacing: 0) {
            Button { mail.send(c) } label: { NLabel(L("Send"), systemImage: "paperplane.fill") }
                .nvButton(skin, .primary).keyboardShortcut(.return, modifiers: .command)
                .disabled(!enabled)
                .help(enabled ? L("Send (⌘↩) — 10 seconds to undo") : L("AI is still working on this draft. Wait for it or cancel it"))
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
        let marked = mail.composer === c && s.applied?.markRange != nil
        switch ComposeLayout.escape(aiMarked: marked, originalExpanded: ui.strip.expanded) {
        case .undoAIText: mail.ai.undoApplied()
        case .collapseOriginal: ui.strip.expanded = false
        case .closeComposer: mail.closeComposer(c)
        }
    }
}
