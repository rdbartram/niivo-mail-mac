import SwiftUI
import AppKit
import MailCore

// Minimal, functional AI views. No hard-coded colours: system styles + `.tint` so the niivo restyle carries over.

/// Attached once to the mail root (AI-HOOK in MailViews): toolbar toggle, sheets, shortcuts, digit keys, triage.
struct AIMailOverlays: ViewModifier {
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        let ai = app.mail.ai
        @Bindable var b = ai
        content
            .onSubmit(of: .search) { ai.searchSubmitted() }
            // The Ask toggle lives in MailHeaderBar (niivo) and MailToolbar (classic themes).
            .background {
                // Hidden key equivalents (modifier shortcuts only; bare digits are handled below).
                Group {
                    Button("") { ai.aiReply() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    Button("") {
                        if let r = app.mail.reader, ai.summary(for: r) == nil || ai.summaryIsStale(r) { ai.summarise() }
                        else { ai.showThreadHeader.toggle() }
                    }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    Button("") { ai.showBriefing = true }.keyboardShortcut("b", modifiers: [.command, .control])
                }
                .frame(width: 0, height: 0).opacity(0).disabled(!ai.enabled || app.trust.hidesContent)
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "12345"), phases: .down) { press in
                guard ai.enabled, app.mail.composer == nil, let r = app.mail.reader, ai.canDraft(r), press.modifiers.isEmpty,
                      let n = Int(press.characters), let i = AIReplyIntent(rawValue: n) else { return .ignored }
                ai.intent(i); return .handled
            }
            .onChange(of: app.mail.visibleRows.prefix(30).map(\.id)) { ai.scheduleTriage() }   // old path only (no-op with conversation triage)
            .task { ai.inbox.start(); ai.promises.start() }   // TRIAGE2-HOOK: conversation triage loop; PROMISES-HOOK: ledger loop
            .sheet(isPresented: $b.showBriefing) { AIBriefingView() }
            .sheet(item: $b.answer) { _ in AIAnswerView() }
            .sheet(item: $b.bulk) { _ in AIBulkView() }
    }
}

// MARK: Inbox row line (AI-HOOK in the row view)

struct AIRowLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var row: MailRow
    var body: some View {
        // Reply needed / waiting always show a tag (an empty "ask" used to hide them); FYI / bulk only with an ask.
        // TRIAGE2-HOOK: one display model for both paths (badge only at medium+ confidence).
        if let t = app.mail.ai.display(for: row), t.ask != nil || t.badge != nil {
            HStack(spacing: 6) {
                if skin.brand {
                    if t.badge != nil { NChip(t.title, tone: .accent) }
                    if let ask = t.ask { Text(ask).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.ink).lineLimit(1) }
                } else {
                    if t.badge != nil {
                        Text(t.title).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                    if let ask = t.ask { Text(ask).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .help(t.explain)
        }
    }

    /// Hover text: who decided (AI or rule), the model's reason, and the context it was given.
    static func explain(_ t: AITriage) -> String {
        var s = t.aiGenerated ? "AI: \(t.tag.title)" : "Rule (AI unavailable): \(t.tag.title)"
        if let w = t.why { s += "\nWhy: \(w)" }
        if let c = t.context, !c.isEmpty { s += "\nContext given:\n• " + c.joined(separator: "\n• ") }
        return s
    }
}

// MARK: Reader: thread summary (the reply intents are AISmartReplyRow under the body; Summarise / Voice are in ⋯)

struct AIReaderStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var reader: ReaderState
    var allowCopy: Bool
    var body: some View {
        let ai = app.mail.ai
        // COMPOSE-LAYOUT: only once a summary was asked for (⇧⌘S or ⋯ ▸ Summarise Thread) — nothing otherwise.
        if ai.enabled, ai.showThreadHeader,
           ai.summarising == reader.header.conversationId || ai.summary(for: reader) != nil || ai.summaryError != nil {
            VStack(alignment: .leading, spacing: 8) { threadHeader(ai) }
                .padding(.horizontal, 18).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { if skin.brand { skin.soft.opacity(0.5) } }
                .overlay(alignment: .bottom) { if skin.brand { Rectangle().fill(skin.hair).frame(height: 1) } }
        }
    }

    @ViewBuilder private func threadHeader(_ ai: AIAssistModel) -> some View {
        if ai.summarising == reader.header.conversationId {
            HStack { ProgressView().controlSize(.small); Text("Summarising…").font(.caption) }
        } else if let s = ai.summary(for: reader) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    section("Decisions", s.decisions, s)
                    section("Open questions", s.openQuestions, s)
                    section("Who owes what", s.owes, s)
                    ForEach(s.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    if ai.summaryIsStale(reader) { Button("New mail in this thread — refresh") { ai.summarise() }.font(.caption) }
                }
            } label: {
                if skin.brand {
                    VStack(alignment: .leading, spacing: 4) {
                        MonoLabel("Thread", size: NV.Size.labelSm, bracket: true)
                        Text(s.tldr).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).lineLimit(3)
                    }
                } else { Text(s.tldr).font(.callout).lineLimit(3) }
            }
            .modifier(Selectable(enabled: allowCopy))
        } else if let e = ai.summaryError {
            Text(e).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func section(_ title: String, _ lines: [AICitedLine], _ s: AIThreadSummary) -> some View {
        if !lines.isEmpty {
            if skin.brand { MonoLabel(title, color: skin.ink, weight: .medium).padding(.top, 4) } else { Text(title).font(.caption.weight(.semibold)) }
            ForEach(lines, id: \.self) { l in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if skin.brand { Text("— " + l.text).font(skin.sans(NV.Size.bodySm)) } else { Text("• " + l.text).font(.caption) }
                    ForEach(l.cites, id: \.self) { n in
                        if let src = s.sources.first(where: { $0.index == n }) {
                            Button("[\(n)]") { app.mail.ai.jump(to: src) }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Composer: the AI bar (draft / rewrite / progress / pre-send notes / inline suggestion) is AIInlineBar and the
// AI ✦ menu is AIComposeMenu (ComposeInlineAI.swift, COMPOSE-LAYOUT). The side-by-side Before/After preview is gone.

/// Small squared chip button (reply intents, AI draft). Native `.bordered` small in other themes.
struct AIChipButton: ViewModifier {
    var skin: Skin
    var quiet = false
    func body(content: Content) -> some View {
        if skin.brand { content.buttonStyle(NVButtonStyle(kind: quiet ? .quiet : .ghost)) }
        else if quiet { content.buttonStyle(.borderless).controlSize(.small) }
        else { content.buttonStyle(.bordered).controlSize(.small) }
    }
}

struct AIDraftPopover: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let ai = app.mail.ai
        @Bindable var s = ai.composer
        if skin.brand {
            VStack(alignment: .leading, spacing: 12) {
                MonoLabel("AI draft", color: skin.ink, bracket: true)
                NPicker("Tone", selection: $s.options.tone, options: AITone.allCases, label: { $0.rawValue.capitalized })
                NPicker("Length", selection: $s.options.length, options: AILength.allCases, label: { $0.rawValue.capitalized })
                NPicker("Language", selection: $s.options.language, options: AILanguage.allCases, label: { $0.title })
                NField("Decline politely, propose next Tuesday…", text: $s.options.instruction, label: "Instruction", style: .bordered)
                HStack {
                    NMenuButton(label: "Intent", items: AIReplyIntent.allCases.map { i in
                        NMenuItem(title: i.title, hint: "\(i.rawValue)") { s.showPopover = false; ai.draft(intent: i) } })
                    Spacer()
                    NButton("Draft") { s.showPopover = false; ai.draft() }.keyboardShortcut(.defaultAction)
                }
                MonoLabel("AI writes a draft for you to edit. It never sends.", size: NV.Size.labelSm)
            }
            .padding(16).frame(width: 400).background(skin.card)
        } else { classic(ai) }
    }

    private func classic(_ ai: AIAssistModel) -> some View {
        @Bindable var s = ai.composer
        return Form {
            Picker("Tone", selection: $s.options.tone) { ForEach(AITone.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Picker("Length", selection: $s.options.length) { ForEach(AILength.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Picker("Language", selection: $s.options.language) { ForEach(AILanguage.allCases, id: \.self) { Text($0.title).tag($0) } }
            TextField("Instruction (e.g. decline politely, propose next Tuesday)", text: $s.options.instruction, axis: .vertical)
                .lineLimit(2...4)
            HStack {
                Menu("Intent") { ForEach(AIReplyIntent.allCases) { i in Button(i.title) { s.showPopover = false; ai.draft(intent: i) } } }
                Spacer()
                Button("Draft") { s.showPopover = false; ai.draft() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            Text("AI writes a draft for you to edit. It never sends.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 380)
    }
}

// MARK: Briefing (⌃⌘B)

struct AIBriefingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @FocusState private var focused: Bool
    var body: some View {
        let ai = app.mail.ai
        let groups = ai.briefing
        let sel = min(ai.briefingGroup, max(0, groups.count - 1))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                if skin.brand {
                    VStack(alignment: .leading, spacing: 4) {
                        MonoLabel("Briefing — \(groups.reduce(0) { $0 + $1.rows.count }) messages", bracket: true)
                        Text("What needs you.").font(skin.sans(NV.Size.title)).tracking(skin.titleTrack(NV.Size.title))
                    }
                } else { Label("Briefing", systemImage: "sun.horizon").font(.title3.weight(.semibold)) }
                Spacer()
                Button("Done") { ai.showBriefing = false }.keyboardShortcut(.cancelAction).nvButton(skin, .ghost) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                        VStack(alignment: .leading, spacing: 4) {
                            if skin.brand {
                                HStack(spacing: 8) {
                                    MonoLabel(String(format: "%02d", i + 1), size: NV.Size.labelSm, color: skin.accentInk)
                                    MonoLabel(g.title, color: skin.ink, wide: true, weight: .medium)
                                    Spacer()
                                    MonoLabel("\(g.rows.count)", color: skin.ink)
                                }
                            } else { Text("\(g.title) · \(g.rows.count)").font(.headline) }
                            ForEach(g.rows.prefix(8)) { r in
                                Button { open(r) } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(r.policy.redactDetails ? "Private message" : r.message.subject).font(skin.brand ? skin.sans(NV.Size.body) : .body).lineLimit(1)
                                        if let a = ai.display(for: r)?.ask { Text(a).font(skin.brand ? skin.sans(NV.Size.bodySm) : .caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(skin.brand ? 12 : 8)
                        .background(i == sel ? (skin.brand ? AnyShapeStyle(skin.accentSoft) : AnyShapeStyle(.tint.opacity(0.12))) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: skin.brand ? 0 : 8))
                        .overlay(alignment: .leading) { if skin.brand && i == sel { Rectangle().fill(skin.accentFill).frame(width: 3) } }
                        .overlay(alignment: .bottom) { if skin.brand { Rectangle().fill(skin.hair).frame(height: 1) } }
                    }
                }
            }
            Text("↑↓ group · ↩ open next reply-needed · E archive this group (FYI / bulk, with preview) · Esc close")
                .font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption).foregroundStyle(.secondary)
        }
        .padding(skin.brand ? 24 : 18).frame(width: 560, height: 520)
        .background(skin.brand ? skin.card : .clear)
        .background(WindowSharingGuard(blocked: app.trust.blocksScreenCapture || app.mail.screenPolicy.preventScreenCapture))
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true; ai.scheduleTriage() }
        .onKeyPress(.downArrow) { ai.briefingGroup = min(sel + 1, groups.count - 1); return .handled }
        .onKeyPress(.upArrow) { ai.briefingGroup = max(sel - 1, 0); return .handled }
        .onKeyPress(.return) {
            if let r = groups.first(where: { $0.tag == .replyNeeded })?.rows.first { open(r) }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "eE")) { _ in
            guard groups.indices.contains(sel), [.fyi, .bulk].contains(groups[sel].tag) else { return .ignored }
            var b = AIBulkState(request: "Archive \(groups[sel].title)")
            b.plan = AIBulkPlan(action: .archive, query: AISearchQuery(), description: "Archive \(groups[sel].rows.count) \(groups[sel].title) messages")
            b.matches = groups[sel].rows.map(\.message)
            ai.showBriefing = false; ai.bulk = b
            return .handled
        }
    }
    private func open(_ r: MailRow) { app.mail.ai.showBriefing = false; app.mail.selectedMessageId = r.id }
}

// MARK: Ask answer + bulk plan sheets

struct AIAnswerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let ai = app.mail.ai
        VStack(alignment: .leading, spacing: 10) {
            if skin.brand {
                MonoLabel("Ask", bracket: true)
                Text(ai.answer?.question ?? "").font(skin.sans(NV.Size.bodyLg, .medium))
            } else { Label(ai.answer?.question ?? "", systemImage: "sparkles").font(.headline) }
            if let e = ai.answer?.error { Text(e).foregroundStyle(.secondary) }
            else if let t = ai.answer?.text {
                ScrollView { Text(t).modifier(Selectable(enabled: app.trust.effectivePolicy.allowCopyOut)).frame(maxWidth: .infinity, alignment: .leading) }
                if let srcs = ai.answer?.sources, !srcs.isEmpty {
                    HStack { Text("Sources:").font(.caption); ForEach(srcs, id: \.self) { s in Button("[\(s.index)]") { ai.jump(to: s) }.buttonStyle(.link) } }
                }
                ForEach(ai.answer?.notes ?? [], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            } else if ai.answer?.error == nil {
                HStack { ProgressView().controlSize(.small); Text(ai.answer?.progress ?? "Thinking…") }
            }
            HStack { Spacer(); Button("Done") { ai.answer = nil }.keyboardShortcut(.cancelAction).nvButton(skin, .ghost) }
        }
        .font(skin.brand ? skin.sans(NV.Size.body) : .body)
        .padding(skin.brand ? 24 : 18).frame(width: 520, height: 360)
        .background(skin.brand ? skin.card : .clear)
        .background(WindowSharingGuard(blocked: app.trust.blocksScreenCapture || app.mail.screenPolicy.preventScreenCapture))
    }
}

struct AIBulkView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let ai = app.mail.ai
        let b = ai.bulk
        VStack(alignment: .leading, spacing: 10) {
            if skin.brand {
                MonoLabel("Do — preview", bracket: true)
                Text(b?.plan?.description ?? b?.request ?? "").font(skin.sans(NV.Size.bodyLg, .medium))
            } else { Label(b?.plan?.description ?? b?.request ?? "", systemImage: "checklist").font(.headline) }
            if let e = b?.error { Text(e).foregroundStyle(.secondary) }
            else if let p = b?.plan {
                Text("\(p.action.rawValue) · \(b?.matches.count ?? 0) message(s)\(p.query.summary.isEmpty ? "" : " · " + p.query.summary)").font(.callout)
                List(b?.matches.prefix(10).map { $0 } ?? []) { m in
                    Text(m.subject.isEmpty ? "(no subject)" : m.subject).lineLimit(1)
                }.frame(height: 200)
            } else { HStack { ProgressView().controlSize(.small); Text("Planning…") } }
            HStack {
                Spacer()
                if b?.done == true {
                    Button("Undo all") { ai.undoBulk() }.nvButton(skin, .ghost)
                    Button("Done") { ai.bulk = nil }.keyboardShortcut(.defaultAction).nvButton(skin, .primary)
                } else {
                    Button("Cancel") { ai.bulk = nil }.keyboardShortcut(.cancelAction).nvButton(skin, .ghost)
                    Button("Confirm") { ai.runBulk() }.nvButton(skin, .primary).keyboardShortcut(.defaultAction)
                        .disabled(b?.plan == nil || (b?.matches.isEmpty ?? true))
                }
            }
        }
        .padding(skin.brand ? 24 : 18).frame(width: 520, height: 400)
        .background(skin.brand ? skin.card : .clear)
        .background(WindowSharingGuard(blocked: app.trust.blocksScreenCapture || app.mail.screenPolicy.preventScreenCapture))
    }
}

// MARK: Settings tab

struct AISettingsView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let ai = app.mail.ai
        @Bindable var b = ai
        let t = ai.trustPolicy
        Form {
            Section("Provider") {
                Picker("AI", selection: $b.settings.choice) { ForEach(AIProviderChoice.allCases, id: \.self) { Text($0.title).tag($0) } }
                LabeledContent("On-device model") { Text(OnDeviceProvider.unavailableReason().map { "unavailable (\($0))" } ?? "available") }
                Toggle("Use on-device for triage and summaries when available", isOn: $b.settings.onDeviceForLightTasks)
                switch ai.settings.choice {
                case .claudeCLI:
                    TextField("Model", text: $b.settings.claudeModel)
                    LabeledContent("Binary") { Text(ai.settings.claudePath ?? ClaudeCLIProvider.locate()?.path ?? "not found") }
                    Text("Runs `claude -p` isolated: no tools, no MCP, no settings, CLAUDE.md or memory, empty working folder.")
                        .font(.caption).foregroundStyle(.secondary)
                case .openAICompatible:
                    Picker("Kind", selection: $b.settings.openAI.flavor) {
                        Text("OpenAI").tag(OpenAIConfig.Flavor.openAI); Text("Azure OpenAI").tag(OpenAIConfig.Flavor.azure)
                        Text("Local (Ollama / LM Studio)").tag(OpenAIConfig.Flavor.local)
                    }
                    TextField("Base URL", text: $b.settings.openAI.baseURL)
                    TextField(ai.settings.openAI.flavor == .azure ? "Deployment" : "Model", text: $b.settings.openAI.model)
                    if ai.settings.openAI.flavor == .azure {
                        TextField("API version", text: $b.settings.openAI.apiVersion)
                        Text("Use a Switzerland North resource with a Standard deployment for Swiss data residency.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        SecureField("API key (stored in the Keychain)", text: $b.keyDraft)
                        Button("Save key") { AIKeychain.save(ai.keyDraft); ai.keyDraft = "" }.disabled(ai.keyDraft.isEmpty)
                        Button("Remove") { AIKeychain.delete() }
                    }
                default: EmptyView()
                }
                HStack {
                    Button("Test connection") { Task { await ai.testConnection() } }.disabled(ai.settings.choice == .off)
                    if let r = ai.testResult { Text(r).font(.caption).foregroundStyle(.secondary) }
                }
                Text("The test sends only a synthetic prompt (\"Reply 'ok'\"), never mail.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Features") {
                Toggle("Precompute “needs you” lines for the top of the inbox", isOn: $b.settings.precomputeTriage)
                Toggle("Check before sending (⌘↩ twice to skip)", isOn: $b.settings.preSendCheck)
            }
            Section("Triage (who acts next)") {   // TRIAGE2-HOOK
                Toggle("Conversation triage (rules first, AI only when unsure)", isOn: Binding(
                    get: { ai.settings.usesConversationTriage }, set: { ai.settings.conversationTriage = $0 }))
                Stepper("Waiting after \(ai.settings.triageSettings.waitingDays) working days without an answer", value: Binding(
                    get: { ai.settings.triageSettings.waitingDays }, set: { ai.settings.waitingDays = $0 }), in: 1...15)
                    .disabled(!ai.settings.usesConversationTriage)
                if let e = app.mail.store?.triage {
                    let c = e.learningCounts()
                    LabeledContent("Learned on this account") { Text("\(c.overrides) corrections · \(c.senders) senders · \(c.truths) training answers") }
                    Button("Reset Learning") { e.resetLearning(); ai.inbox.republish() }
                }
                Text("Applies to direct (To) recipients only; plain FYI sends never count. Corrections stay on this Mac, per account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VoiceSettingsSections()   // VOICE-HOOK
            Section("Organisation policy") {
                LabeledContent("Cloud AI") { Text(t.aiAccess.rawValue) }
                LabeledContent("On-device AI") { Text(t.effectiveOnDeviceAIAccess.rawValue) }
                LabeledContent("Allowed providers") { Text(t.allowedAIProviders?.joined(separator: ", ") ?? "any") }
                Text("Labels decide per message: encrypted mail without EXTRACT, private and unknown-label mail never reach AI. Every call is audited without content.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Cheat-sheet rows for the AI keys (AI-HOOK in MailOverlays).
struct AICheatSheetSection: View {
    static let keys: [(String, String)] = [("⇧⌘R", "AI reply"), ("⇧⌘S", "Thread summary"), ("⌃⌘B", "Briefing"),
                                           ("1–5", "Reply intents (message open)"), ("⌥↩", "Natural-language search"),
                                           ("⌘K + text", "Ask / Search / Do"), ("⌘↩ ⌘↩", "Send past pre-send notes")]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI").font(.headline)
            ForEach(Self.keys, id: \.0) { k in
                HStack { Text(k.0).font(.body.monospaced()).frame(width: 90, alignment: .leading); Text(k.1) }
            }
        }
    }
}
