import SwiftUI
import CalendarCore
import MailCore
import TrustCore

// ONBOARDING (docs/BACKLOG.md §17 step 5): state for the first-run setup sheet (OnboardingViews.swift) and the
// "Learn my voice" modes it shares with Settings. Pure logic: MailCore/Onboarding.swift, MailCore/AIVoiceModes.swift.
// niivo downloads no model: Apple's on-device model is managed by macOS, and a local OpenAI-compatible server (Ollama,
// LM Studio) manages its own models; this only detects and selects them.

// MARK: - Learn my voice: modes (per account, UserDefaults), Me from sent mail, Forget

extension VoiceLearnModel {
    private static var modesKey: String {
        VoiceLearnModes.defaultsKey + "." + OnboardingStore.accountSuffix(Auth.activeAccountId ?? "local")
    }

    /// Per-account "Learn my voice" modes (settings, not content). Default: Suggest on every layer.
    var modes: VoiceLearnModes {
        get {
            _ = modesRevision
            return UserDefaults.standard.data(forKey: Self.modesKey).flatMap { try? JSONDecoder().decode(VoiceLearnModes.self, from: $0) }
                ?? VoiceLearnModes()
        }
        set {
            if !ThemePreview.isRunning, let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: Self.modesKey) }
            if newValue.me == .off { meProposal = nil }
            if newValue.contacts == .off && newValue.organisation == .off { suggestion = nil }
            if newValue.contacts == .off { nudge = nil }
            modesRevision += 1
        }
    }

    /// Me from the last 50 sent mails: on-device detectors only, same guards as the signature import. Forwards, private
    /// mail and anything the label gate keeps from on-device AI are skipped. Only the derived notes are kept.
    func learnMe(mail: MailModel) {
        guard !learningMe else { return }
        guard modes.me != .off else { meStatus = "Learning is off for Me."; return }
        guard let store = mail.store, let app = mail.ai.app, !app.trust.hidesContent, let gate = gate(mail) else {
            meStatus = "Sign in first: niivo needs your Sent Items."; return
        }
        guard app.trust.effectivePolicy.allowOfflineBodies else {
            meStatus = "Your organisation's policy keeps mail bodies off this Mac, so your voice can't be learnt from sent mail."; return
        }
        guard gate.onDeviceAccess != .off else {
            meStatus = "On-device AI is turned off by your organisation's policy, so niivo doesn't read sent mail for your voice."; return
        }
        guard let sent = try? store.folder(wellKnown: .sentitems, mailbox: "me") else { meStatus = "No Sent Items folder yet."; return }
        let heads = ((try? store.messages(folderId: sent.id, limit: VoiceLearn.meSampleSize + 10)) ?? []).filter { !$0.isDraft }
            .sorted { $0.received > $1.received }.prefix(VoiceLearn.meSampleSize).map { $0 }
        learningMe = true; meProposal = nil
        meStatus = "Reading your last \(heads.count) sent mails on this Mac…"
        Task { @MainActor [weak self] in
            var msgs: [MailMessage] = []
            for h in heads {
                var m = h
                let readable = !h.isPrivate && !VoiceLearn.isForward(h.subject) && gate.exposure(h, mailbox: "me", tier: .onDevice) == .content
                let p = mail.policy(for: h, mailbox: "me")
                if readable, m.body == nil, p.allowOfflineDetails, !p.redactDetails, !p.bodyIsProtected,
                   let sync = mail.sync, let b = try? await sync.fetchBody(id: h.id) { m = b }
                msgs.append(m)
            }
            guard let self else { return }
            self.learningMe = false
            let f = VoiceLearn.meFacts(sent: msgs, mailbox: "me", gate: gate)
            let skipped = f.skippedPrivate + f.skippedForward + f.skippedGate
            guard let notes = VoiceLearn.meNotes(f) else {
                self.meStatus = "Too little to learn from: \(f.analysed) of \(f.considered) sent mails could be read (\(skipped) skipped)."
                return
            }
            var p = mail.voiceProfile, queue: [VoiceLearnCandidate] = []
            let text = VoiceLearn.applyMeNotes(notes, to: p.me)
            switch self.modes.offer(.me(text), profile: &p, queue: &queue) {
            case .saved:
                mail.saveVoice(p)
                self.meStatus = "Saved to your Me voice from \(f.analysed) sent mails (\(skipped) skipped)."
            case .queued:
                self.meProposal = text
                self.meStatus = "Learnt from \(f.analysed) sent mails (\(skipped) skipped). Check it and save."
            case .dropped:
                self.meStatus = "Learning is off for Me."
            }
        }
    }

    func saveMeProposal(mail: MailModel) {
        guard let t = meProposal else { return }
        var p = mail.voiceProfile
        VoiceLearnModes.save(.me(t), into: &p)
        mail.saveVoice(p)
        meProposal = nil; meStatus = "Saved to your Me voice."
        VoiceEditorModel.shared.meDraft = nil
    }

    /// Settings: open the proposal in the Me editor instead (the user saves there).
    func editMeProposal() {
        guard let t = meProposal else { return }
        let m = VoiceEditorModel.shared
        m.tab = .me; m.org = nil; m.contact = nil; m.meDraft = t
        meProposal = nil
    }

    /// Deletes one layer's sealed notes (Me back to the default) and its nudge history. Other layers untouched.
    func forget(_ l: VoiceLayer, mail: MailModel) {
        var p = mail.voiceProfile
        p.forget(l)
        mail.saveVoice(p)
        if let store = mail.store { var log = store.voiceNudgeLog(); log.forget(l); try? store.save(voiceNudgeLog: log) }
        switch l {
        case .me: meProposal = nil; meStatus = nil; VoiceEditorModel.shared.meDraft = nil
        case .organisation: suggestion?.org = nil; VoiceEditorModel.shared.org = nil
        case .contacts: suggestion?.contact = nil; nudge = nil; toastNudge = nil; review = []; VoiceEditorModel.shared.contact = nil
        }
        if suggestion?.contact == nil && suggestion?.org == nil { suggestion = nil }
        mail.toast(MailToast(text: "Forgot your \(l.title) voice on this Mac", symbol: "trash"))
    }
}

// MARK: - Onboarding state

@MainActor @Observable
final class OnboardingModel {
    static let shared = OnboardingModel()

    var presented = false
    var flow = OnboardingFlow()
    @ObservationIgnored private var account: String?

    // AI step
    var aiPick: AIOnboardingChoice = .off
    var cloudPick: AIProviderID?
    var aiNote: String?

    // Local models step (probed only on an explicit click; loopback or https only)
    var serverURL = LocalModelServer.known[0].baseURL
    var probing = false
    var models: [LocalModelInfo] = []
    var modelPick: String?
    var probeStatus: String?
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    // Voice: Forget confirmation
    var confirmForget: VoiceLayer?

    struct Policy { var cloud: AIOrgAccess; var onDevice: AIOrgAccess; var allowed: Set<AIProviderID>? }
    static func policy(_ t: TrustPolicy) -> Policy {
        Policy(cloud: AIOrgAccess(trustRawValue: t.aiAccess.rawValue), onDevice: AIOrgAccess(trustRawValue: t.effectiveOnDeviceAIAccess.rawValue),
               allowed: t.allowedAIProviders.map { Set($0.compactMap(AIProviderID.init(rawValue:))) })
    }

    /// First run: a signed-in live account that hasn't finished or dismissed setup. Never in fixtures or the preview.
    func autoShowIfNeeded(_ app: AppModel) {
        guard !presented, !ThemePreview.isRunning, app.mode == .live, !app.trust.hidesContent, !app.mail.showSettings,
              let a = Auth.activeAccountId, OnboardingStore.shouldAutoShow(account: a) else { return }
        begin(app, restart: false)
    }

    /// Settings → "Run setup again": Settings closes first (one sheet per window).
    func rerun(_ app: AppModel) {
        app.mail.showSettings = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            self.begin(app, restart: true)
        }
    }

    func begin(_ app: AppModel, restart: Bool) {
        account = Auth.activeAccountId
        flow = OnboardingFlow(progress: account.map { OnboardingStore.load(account: $0) } ?? OnboardingProgress(), restart: restart)
        syncAIPick(app.mail.ai)
        probeStatus = nil; models = []; modelPick = nil
        presented = true
        if app.mode == .live { Task { await app.startMailIfNeeded() } }   // the voice and signature steps read Sent Items
    }

    func syncAIPick(_ ai: AIAssistModel) {
        let c = ai.settings.choice
        aiPick = AIChoicePolicy.choice(for: c)
        cloudPick = c == .claudeCLI ? .claudeCLI : c == .openAICompatible ? .openAICompatible : nil
        aiNote = nil
    }

    private func persist() {
        guard !ThemePreview.isRunning, let a = account else { return }
        OnboardingStore.save(flow.progress, account: a)
    }

    func next(_ app: AppModel) {
        if flow.step == .ai, !applyAI(app.mail.ai) { return }
        flow.complete(); persist()
        if flow.progress.isFinished { close() }
    }
    func skip() { flow.skip(); persist(); if flow.progress.isFinished { close() } }
    func back() { flow.back() }
    /// "Skip setup", Esc, or closing: finished for this account (it doesn't come back on its own).
    func finish() { flow.finish(); persist(); close() }
    private func close() { cancelProbe(); presented = false }

    // MARK: AI

    /// Writes the choice into the existing AI setting (`AIAssistSettings.choice`), clamped by policy, only when it changed
    /// (a change resets AI results). Cloud needs a concrete provider.
    @discardableResult
    func applyAI(_ ai: AIAssistModel) -> Bool {
        let p = Self.policy(ai.trustPolicy)
        let eff = AIChoicePolicy.clamp(aiPick, cloudAccess: p.cloud, onDeviceAccess: p.onDevice, allowedProviders: p.allowed)
        aiPick = eff
        let allowedCloud = AIChoicePolicy.cloudProviders(cloudAccess: p.cloud, allowedProviders: p.allowed)
        let pick = cloudPick.flatMap { allowedCloud.contains($0) ? $0 : nil }
        let new = AIChoicePolicy.providerChoice(eff, current: ai.settings.choice, cloud: pick)
        if eff == .cloudWherePermitted && new == .off { aiNote = "Pick a cloud provider first."; return false }
        aiNote = nil
        if new != ai.settings.choice { ai.settings.choice = new }
        return true
    }

    // MARK: Local server

    func probe() {
        probeTask?.cancel()
        if let r = LocalModelServer.refusal(baseURL: serverURL) { probeStatus = r; return }
        guard let list = LocalModelServer.modelsURL(baseURL: serverURL) else { probeStatus = "Not a valid URL"; return }
        let tags = LocalModelServer.ollamaTagsURL(baseURL: serverURL)
        probing = true; models = []; modelPick = nil
        probeStatus = "Asking \(list.host ?? "the server") for its models…"
        probeTask = Task { @MainActor [weak self] in
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 4
            let session = URLSession(configuration: cfg)
            func get(_ u: URL?) async -> Data? {
                guard let u, !Task.isCancelled, let (d, r) = try? await session.data(from: u),
                      (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return d
            }
            let oa = await get(list).map(LocalModelServer.parseOpenAIModels) ?? []
            let ol = await get(tags).map(LocalModelServer.parseOllamaTags) ?? []
            guard let self, !Task.isCancelled else { return }
            self.probing = false
            self.models = LocalModelServer.merge(openAI: oa, ollama: ol)
            self.modelPick = self.models.first?.name
            self.probeStatus = self.models.isEmpty ? "Nothing answered there, or the server lists no models."
                : "\(self.models.count) model\(self.models.count == 1 ? "" : "s") on this server."
        }
    }

    func cancelProbe() {
        guard probing else { return }
        probeTask?.cancel(); probeTask = nil; probing = false; probeStatus = "Cancelled."
    }

    /// Why the local server can't be selected (it is gated like a cloud provider), nil if it can.
    func localRefusal(_ ai: AIAssistModel) -> String? {
        let p = Self.policy(ai.trustPolicy)
        if let r = AIChoicePolicy.policyRefusal(.cloudWherePermitted, cloudAccess: p.cloud, onDeviceAccess: p.onDevice, allowedProviders: p.allowed) {
            return r + " (a local server is gated like cloud AI)"
        }
        if !AIChoicePolicy.cloudProviders(cloudAccess: p.cloud, allowedProviders: p.allowed).contains(.openAICompatible) {
            return "Your organisation's policy doesn't allow OpenAI-compatible providers"
        }
        return nil
    }

    func useLocal(_ ai: AIAssistModel) {
        guard let m = modelPick, localRefusal(ai) == nil, LocalModelServer.refusal(baseURL: serverURL) == nil else { return }
        var s = ai.settings
        s.openAI = OpenAIConfig(flavor: .local, baseURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines), model: m)
        s.choice = .openAICompatible
        if s != ai.settings { ai.settings = s }   // one write: settings changes reset AI results
        aiPick = .cloudWherePermitted; cloudPick = .openAICompatible
        probeStatus = "niivo will use \(m) on this server."
    }
}
