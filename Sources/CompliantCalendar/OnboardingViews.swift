import SwiftUI
import CalendarCore
import MailCore

// ONBOARDING: the setup sheet (six skippable steps) and the "Learn my voice" controls shared with Settings → AI.
// State: OnboardingModel.swift. No `@State` (CLT has no macro plugin): everything lives in the observable models.

struct OnboardingSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin

    var body: some View {
        let o = OnboardingModel.shared
        VStack(spacing: 0) {
            header(o)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch o.flow.step {
                    case .welcome: OnboardingWelcome()
                    case .ai: OnboardingAIStep()
                    case .localModels: OnboardingLocalModelsStep()
                    case .voice: OnboardingVoiceStep()
                    case .signatures: OnboardingSignaturesStep()
                    case .done: OnboardingDoneStep()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            footer(o)
        }
        .frame(width: 680, height: 600)
        .background(skin.ground)
    }

    private func header(_ o: OnboardingModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MonoLabel(String(format: "Setup · %02d / %02d", o.flow.index + 1, OnboardingFlow.steps.count), bracket: true)
                Spacer()
                MonoLabel(o.flow.step.title, color: skin.ink, wide: true, weight: .medium)
            }
            HStack(spacing: 4) {
                ForEach(OnboardingFlow.steps) { s in
                    Rectangle().fill(s == o.flow.step ? skin.accentFill
                                     : o.flow.progress.completed.contains(s) ? skin.ink.opacity(0.55) : skin.hair2)
                        .frame(height: 3)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
        .hairline(skin)
    }

    private func footer(_ o: OnboardingModel) -> some View {
        HStack(spacing: 10) {
            if o.flow.step != .done {
                NButton("Skip setup", kind: .quiet) { o.finish() }.keyboardShortcut(.cancelAction)
                    .help("Close setup (Esc). Run it again any time from Settings → AI.")
            }
            Spacer()
            if !o.flow.isFirst { NButton("Back", kind: .ghost) { o.back() }.keyboardShortcut("[", modifiers: .command) }
            if o.flow.step != .welcome && o.flow.step != .done {
                NButton("Skip", kind: .ghost) { o.skip() }.keyboardShortcut("]", modifiers: .command)
            }
            NButton(o.flow.step == .done ? "Start using niivo" : o.flow.step == .welcome ? "Get started" : "Continue") { o.next(app) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .hairline(skin, edge: .top)
    }
}

// MARK: Building blocks

struct OnboardingTitle: View {
    @Environment(\.skin) private var skin
    var title: String
    var lead: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(skin.sans(NV.Size.title, .medium)).tracking(skin.titleTrack(NV.Size.title)).foregroundStyle(skin.ink)
            Text(lead).font(skin.sans(NV.Size.bodyLg)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OnboardingPoint: View {
    @Environment(\.skin) private var skin
    var symbol: String
    var title: String
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            NSymbol(symbol, size: 15).foregroundStyle(skin.accentInk).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(skin.sans(NV.Size.body, .semibold)).foregroundStyle(skin.ink)
                Text(text).font(skin.sans(NV.Size.body)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OnboardingCard<C: View>: View {
    @Environment(\.skin) private var skin
    var label: String
    @ViewBuilder var content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(label, color: skin.ink, wide: true, weight: .medium)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.card, in: skin.rounded)
        .overlay(skin.rounded.strokeBorder(skin.hair, lineWidth: 1))
    }
}

/// A selectable row (radio-like), keyboard focusable; a disabled row says why.
struct OnboardingOption: View {
    @Environment(\.skin) private var skin
    var title: String
    var detail: String
    var selected: Bool
    var refusal: String?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                NSymbol(selected ? "largecircle.fill.circle" : "circle", size: 14)
                    .foregroundStyle(refusal != nil ? skin.guide : selected ? skin.accentInk : skin.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(skin.sans(NV.Size.body, .semibold)).foregroundStyle(refusal != nil ? skin.guide : skin.ink)
                    Text(detail).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
                    if let r = refusal {
                        Text(r).font(skin.sans(NV.Size.bodySm, .medium)).foregroundStyle(skin.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(selected ? skin.accentSoft : .clear, in: skin.rounded)
            .overlay(skin.rounded.strokeBorder(selected ? skin.accentInk : skin.hair, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(refusal != nil)
        .nFocusRing()
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(refusal ?? "")
    }
}

// MARK: 1. Welcome

struct OnboardingWelcome: View {
    var body: some View {
        OnboardingTitle(title: "Welcome to niivo mail",
                        lead: "Mail and calendar for Microsoft 365 that keeps your organisation's rules on this Mac. A few choices, each one skippable.")
        OnboardingPoint(symbol: "tag", title: "Labels respected",
                        text: "Purview sensitivity labels decide, per message, what may be copied, printed, captured, kept offline or shown to AI. Encrypted mail follows your own usage rights.")
        OnboardingPoint(symbol: "lock.shield", title: "Encrypted offline cache",
                        text: "Mail and calendar are cached on this Mac encrypted, with keys wrapped by this Mac's Secure Enclave (Touch ID or your Mac password to unlock). Locking the app closes the cache; your organisation's policy decides how long it may stay offline.")
        OnboardingPoint(symbol: "sparkles", title: "AI behind gates",
                        text: "AI is off until you turn it on. Every request passes the label gate and your organisation's policy first, private and unknown-label mail never reach it, and every call is logged without content.")
    }
}

// MARK: 2. AI

struct OnboardingAIStep: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin

    static func describe(_ a: AIOrgAccess) -> String {
        switch a { case .off: "off"; case .metadataOnly: "metadata only"; case .followLabels: "follows labels" }
    }

    var body: some View {
        let o = OnboardingModel.shared
        let ai = app.mail.ai
        let p = OnboardingModel.policy(ai.trustPolicy)
        let hw = OnDeviceProvider.unavailableReason()
        OnboardingTitle(title: "How should niivo use AI?",
                        lead: "AI is off on a new install. You can only choose what your organisation's policy allows; options it rules out say why.")
        ForEach(AIOnboardingChoice.allCases) { c in
            let refusal = AIChoicePolicy.policyRefusal(c, cloudAccess: p.cloud, onDeviceAccess: p.onDevice, allowedProviders: p.allowed)
                ?? (c == .onDeviceOnly ? hw.map { "Not available on this Mac: \($0)" } : nil)
            OnboardingOption(title: c.title, detail: detail(c, ai: ai), selected: o.aiPick == c, refusal: refusal) {
                o.aiPick = c; o.aiNote = nil
            }
        }
        if o.aiPick == .cloudWherePermitted {
            let allowed = AIChoicePolicy.cloudProviders(cloudAccess: p.cloud, allowedProviders: p.allowed)
            OnboardingCard(label: "Cloud provider") {
                ForEach(allowed, id: \.self) { id in
                    OnboardingOption(title: id.title, detail: providerDetail(id, ai: ai), selected: o.cloudPick == id, refusal: nil) {
                        o.cloudPick = id; o.aiNote = nil
                    }
                }
                Text("Keys, model names and endpoints are set in Settings → AI. A local server (Ollama, LM Studio) can be picked in the next step.")
                    .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted)
            }
        }
        if let n = o.aiNote { Text(n).font(skin.sans(NV.Size.body, .medium)).foregroundStyle(skin.danger) }
        OnboardingCard(label: "Your organisation's policy") {
            VStack(alignment: .leading, spacing: 4) {
                row("Cloud AI", Self.describe(p.cloud))
                row("On-device AI", Self.describe(p.onDevice))
                row("Allowed providers", p.allowed.map { $0.map(\.title).sorted().joined(separator: ", ") } ?? "any")
            }
            Text("Either way, labels decide per message: encrypted mail without EXTRACT, private and unknown-label mail never reach AI.")
                .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(skin.sans(NV.Size.body)).foregroundStyle(skin.muted)
            Spacer()
            Text(v).font(skin.mono(11, .medium)).foregroundStyle(skin.ink)
        }
    }

    private func detail(_ c: AIOnboardingChoice, ai: AIAssistModel) -> String {
        switch c {
        case .off: return "No AI features and no mail sent to any model."
        case .onDeviceOnly:
            return "Apple's on-device model (Apple Intelligence): triage lines, summaries, search and drafts. Mail never leaves this Mac."
        case .cloudWherePermitted:
            return "Drafting and longer tasks may use a cloud model (Claude CLI or an OpenAI-compatible endpoint) where your policy and each message's label allow it."
                + (ai.settings.onDeviceForLightTasks ? " Triage and summaries stay on-device when it's available." : "")
        }
    }

    private func providerDetail(_ id: AIProviderID, ai: AIAssistModel) -> String {
        switch id {
        case .claudeCLI:
            return (ai.settings.claudePath ?? ClaudeCLIProvider.locate()?.path).map { "Runs the local `claude` binary, isolated: found at \($0)." }
                ?? "Runs the local `claude` binary, isolated. Not found on this Mac yet."
        case .openAICompatible:
            let c = ai.settings.openAI
            return "OpenAI, Azure OpenAI or a local server: currently \(c.model) at \(c.baseURL)."
        case .onDevice: return ""
        }
    }
}

// MARK: 3. Local models

struct OnboardingLocalModelsStep: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin

    var body: some View {
        let o = OnboardingModel.shared
        @Bindable var b = o
        let ai = app.mail.ai
        let hw = OnDeviceProvider.unavailableReason()
        OnboardingTitle(title: "Models on this Mac",
                        lead: "niivo doesn't download models itself. It uses Apple's on-device model when macOS provides it, or a local server you run.")
        OnboardingCard(label: "Apple on-device model") {
            HStack(spacing: 8) {
                NSymbol(hw == nil ? "checkmark.circle" : "xmark.circle", size: 13).foregroundStyle(hw == nil ? skin.accentInk : skin.guide)
                Text(hw.map { "Not available: \($0)" } ?? "Available").font(skin.sans(NV.Size.body, .medium)).foregroundStyle(skin.ink)
            }
            Text("Used for triage lines, summaries, natural-language search and reply intents, and for drafts when AI is on-device only. macOS downloads and updates it (System Settings → Apple Intelligence & Siri) and manages its size.")
                .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
        }
        OnboardingCard(label: "Local server (Ollama, LM Studio)") {
            HStack(spacing: 8) {
                ForEach(LocalModelServer.known, id: \.name) { k in
                    NButton(k.name, kind: o.serverURL == k.baseURL ? .primary : .ghost) { o.serverURL = k.baseURL; o.models = []; o.probeStatus = nil }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                TextField("Server URL", text: $b.serverURL).textFieldStyle(.roundedBorder).font(skin.mono(11))
                    .onSubmit { o.probe() }
                if o.probing {
                    ProgressView().controlSize(.small)
                    NButton("Cancel", kind: .ghost) { o.cancelProbe() }
                } else {
                    NButton("Detect models", kind: .ghost) { o.probe() }
                }
            }
            if let s = o.probeStatus { Text(s).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted) }
            ForEach(o.models) { m in
                let meta = [m.parameters, m.sizeText].compactMap { $0 }.joined(separator: " · ")
                OnboardingOption(title: m.name, detail: meta.isEmpty ? "Size not reported by this server" : meta,
                                 selected: o.modelPick == m.name, refusal: nil) { o.modelPick = m.name }
            }
            if !o.models.isEmpty {
                let refusal = o.localRefusal(ai)
                HStack {
                    NButton("Use this model") { o.useLocal(ai) }.disabled(refusal != nil || o.modelPick == nil)
                    if let r = refusal { Text(r).font(skin.sans(NV.Size.bodySm, .medium)).foregroundStyle(skin.danger) }
                }
            }
            Text("niivo only asks the server which models it has, when you click Detect. Install models with the server itself (for example `ollama pull llama3.2`). A local server runs on this Mac, but niivo gates it like a cloud provider: your organisation's cloud AI policy and the cloud label rules apply.")
                .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: 4. Voice

struct OnboardingVoiceStep: View {
    var body: some View {
        OnboardingTitle(title: "Learn my voice",
                        lead: "AI drafts write like you: your own voice, then the company you reply to, then the person. Choose how each layer learns.")
        VoiceLearnModeControls(compact: false)
        VoiceLearnMeControls(inSettings: false)
    }
}

/// Mode per layer + Forget (onboarding and Settings).
struct VoiceLearnModeControls: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var compact: Bool

    static func detail(_ l: VoiceLayer) -> String {
        switch l {
        case .me: "How you write in general, learnt from your sent mail and from edits you make to AI drafts."
        case .organisation: "How you write to one company (language, Du / Sie), learnt when you reply to its people."
        case .contacts: "How you write to one person, learnt from your mail with them and your edits to drafts."
        }
    }

    var body: some View {
        let v = VoiceLearnModel.shared
        let o = OnboardingModel.shared
        let mail = app.mail
        VStack(alignment: .leading, spacing: 12) {
            ForEach(VoiceLayer.allCases) { l in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.title).font(skin.sans(NV.Size.body, .semibold)).foregroundStyle(skin.ink)
                        if !compact {
                            Text(Self.detail(l)).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Picker(l.title, selection: Binding(get: { v.modes[l] }, set: { var m = v.modes; m[l] = $0; v.modes = m })) {
                        ForEach(VoiceLearnMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                    .accessibilityLabel("Learn \(l.title)")
                    Button("Forget") { o.confirmForget = l }.buttonStyle(.borderless).foregroundStyle(skin.danger)
                        .disabled(mail.store == nil)
                        .help("Delete what niivo has saved for \(l.title) on this Mac")
                }
            }
            Text("Off: nothing is read or proposed for that layer. Suggest: niivo asks before saving a learned note. Automatic: it saves and tells you. Notes are sealed on this Mac with the mail cache key.")
                .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(o.confirmForget.map { "Forget your \($0.title) voice?" } ?? "",
                            isPresented: Binding(get: { o.confirmForget != nil }, set: { if !$0 { o.confirmForget = nil } }),
                            presenting: o.confirmForget) { l in
            Button("Forget \(l.title)", role: .destructive) { v.forget(l, mail: mail); o.confirmForget = nil }
            Button("Cancel", role: .cancel) { o.confirmForget = nil }
        } message: { l in
            Text(l == .me ? "Your Me voice goes back to the prewritten default. Company and contact notes stay."
                 : "Deletes every saved \(l == .contacts ? "contact" : "company") note on this Mac. The other layers stay.")
        }
    }
}

/// "Learn Me from my sent mail" with the exact scope, then the proposal for approval (Suggest).
struct VoiceLearnMeControls: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var inSettings: Bool

    var body: some View {
        let v = VoiceLearnModel.shared
        let mail = app.mail
        let off = v.modes.me == .off
        VStack(alignment: .leading, spacing: 10) {
            if !inSettings { MonoLabel("Learn Me from my sent mail", color: skin.ink, wide: true, weight: .medium) }
            Text("Reads about your last \(VoiceLearn.meSampleSize) sent mails on this Mac with the on-device detectors (no AI model, nothing leaves the Mac). Forwards and private mail are skipped, and so is anything your labels keep from on-device AI. Only your own words count; quoted history is cut. No mail text is kept in your voice, only a few short notes (language, Du / Sie, greeting, sign-off, length), sealed on this Mac. Bodies not yet downloaded are fetched into the encrypted cache like any message you open.")
                .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                NButton(v.modes.me == .automatic ? "Learn and save" : "Learn from sent mail", kind: .ghost) { v.learnMe(mail: mail) }
                    .disabled(off || v.learningMe || mail.store == nil)
                if v.learningMe { ProgressView().controlSize(.small) }
                if off { Text("Learning is off for Me.").font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted) }
                else if mail.store == nil { Text("Mail isn't open yet.").font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted) }
            }
            if let s = v.meStatus { Text(s).font(skin.sans(NV.Size.bodySm, .medium)).foregroundStyle(skin.ink) }
            if let p = v.meProposal {
                ScrollView {
                    Text(p).font(skin.mono(11)).foregroundStyle(skin.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: 140)
                .background(skin.soft, in: skin.rounded)
                HStack(spacing: 8) {
                    NButton("Save to my voice") { v.saveMeProposal(mail: mail) }
                    if inSettings { NButton("Edit first", kind: .ghost) { v.editMeProposal() } }
                    NButton("Discard", kind: .quiet) { v.meProposal = nil; v.meStatus = nil }
                }
            }
        }
        .padding(inSettings ? 0 : 16)
        .background(inSettings ? Color.clear : skin.card, in: skin.rounded)
        .overlay { if !inSettings { skin.rounded.strokeBorder(skin.hair, lineWidth: 1) } }
    }
}

// MARK: 5. Signatures

struct OnboardingSignaturesStep: View {
    var body: some View {
        OnboardingTitle(title: "Your signature",
                        lead: "Outlook's signatures aren't available to apps, so set one up here, or let niivo find the one your sent mail already ends with.")
        Form { SignatureSettingsSections() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 360)
    }
}

// MARK: 6. Done

struct OnboardingDoneStep: View {
    @Environment(\.skin) private var skin
    var body: some View {
        OnboardingTitle(title: "You're set", lead: "The keys worth knowing. ⌘/ shows them again any time.")
        HStack(alignment: .top, spacing: 22) {
            ForEach(MailKeymap.groups, id: \.title) { g in
                VStack(alignment: .leading, spacing: 5) {
                    MonoLabel(g.title, color: skin.ink, wide: true, weight: .medium).padding(.bottom, 3)
                    ForEach(g.commands) { c in key(c.hint, c.title) }
                }
            }
        }
        VStack(alignment: .leading, spacing: 5) {
            MonoLabel("AI", color: skin.ink, wide: true, weight: .medium).padding(.bottom, 3)
            ForEach(AICheatSheetSection.keys, id: \.0) { k in key(k.0, k.1) }
        }
        OnboardingCard(label: "Change things later") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings (⌘,) → AI: provider, local server, Learn my voice, voice notes, Run setup again.")
                Text("Settings → Send As: signatures and the default signature per identity.")
                Text("Settings → Device Trust: what your organisation's policy allows on this Mac.")
            }
            .font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink)
        }
    }

    private func key(_ hint: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(hint).font(skin.mono(10.5, .medium)).padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(Rectangle().strokeBorder(skin.hair2, lineWidth: 1))
            Text(title).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.ink)
        }
    }
}

// MARK: - Settings (ONBOARDING-HOOK in AISettingsView)

struct VoiceLearnSettingsSections: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Section("Learn my voice") {
            VoiceLearnModeControls(compact: true)
        }
        Section("Learn Me from my sent mail") {
            VoiceLearnMeControls(inSettings: true)
        }
        Section("Setup") {
            HStack {
                Button("Run setup again") { OnboardingModel.shared.rerun(app) }
                Spacer()
            }
            Text("Welcome, AI, local models, voice and signatures. Each step is skippable.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
