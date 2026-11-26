import SwiftUI
import AppKit
import CryptoKit
import CalendarCore
import MailCore
import TrustCore
import OfficeTools

/// Per-composer AI state (one composer at a time).
@MainActor @Observable
final class AIComposerState {
    var showPopover = false
    var options = AIDraftOptions()
    var busy: String?
    var task: Task<Void, Never>?
    var error: String?
    /// COMPOSE-LAYOUT (2026-11-26): AI text that is IN the editor now, marked until the user edits or keeps it
    /// (MailCore AIAppliedEdit: Undo restores what it replaced, Try again swaps only the AI text).
    var applied: AIAppliedEdit?
    /// The running request's target, following the user's typing (the editor stays editable while AI works).
    var anchor: AIEditAnchor?
    var selection: TextSelection?
    var findings: [AIPreSendFinding] = []
    var checkedHash: Int?
    var checking = false
    var notes: [String] = []
    // VOICE: layers applied to the last request, its content-free Why list.
    var voice: VoiceResolution?
    var why: [String] = []
    var showWhy = false
    /// Voice layers the user switched off for the next request only (reset after it).
    var voiceOff: Set<VoiceResolution.Kind> = []
    /// Signature before the applied voice draft (Undo restores it before the body).
    var undoSignature: (id: UUID?, isDefault: Bool)?
    /// What Try again runs again.
    var retry: AIComposerRetry?
    /// ⌘J: the AI actions palette and what the user typed into it.
    var showActions = false
    var actionQuery = ""
    /// "Try again with instruction…" text.
    var retryInstruction = ""
    var showRetryInstruction = false
    func cancel() { task?.cancel(); task = nil; busy = nil; checking = false; anchor = nil }
    /// The composer went away or was replaced: nothing of this request may land in another draft.
    func detach() { cancel(); applied = nil; undoSignature = nil; showActions = false }
}

struct AIAnswerState: Identifiable {
    let id = UUID()
    var question: String
    var text: String?
    var sources: [AIPromptSource] = []
    var notes: [String] = []
    var error: String?
    /// Live agent progress ("Searching mail from zoe@…").
    var progress: String?
}

struct AIBulkState: Identifiable {
    let id = UUID()
    var request: String
    var plan: AIBulkPlan?
    var matches: [MailMessage] = []
    var error: String?
    var done = false
    var undo: [(id: String, action: MailAction)] = []
}

/// App-side AI: settings, provider construction, the background triage cache, and every feature entry point.
/// All decisions go through `AIAssistant` (MailCore) — this class only gathers inputs and shows results.
@MainActor @Observable
final class AIAssistModel {
    weak var mail: MailModel?
    weak var app: AppModel?

    var settings: AIAssistSettings { didSet { save(); reset(); cachedBinary = nil } }
    var composer = AIComposerState()
    private(set) var triage: [String: AITriage] = [:]
    /// TRIAGE2-HOOK: conversation triage (InboxTriageModel.swift). The per-message path above is the fallback.
    @ObservationIgnored private(set) lazy var inbox: InboxTriageModel = InboxTriageModel(ai: self)
    /// PROMISES-HOOK: promises ledger loop (PromisesViews.swift).
    @ObservationIgnored private(set) lazy var promises: PromisesModel = PromisesModel(ai: self)
    private(set) var summaries: [String: (summary: AIThreadSummary, count: Int)] = [:]
    var showThreadHeader = true
    var summarising: String?
    var summaryError: String?
    var askMode = false
    var answer: AIAnswerState?
    var bulk: AIBulkState?
    var showBriefing = false
    var briefingGroup = 0
    var testResult: String?
    var keyDraft = ""
    private var triageTask: Task<Void, Never>?
    /// New rows arrived while a batch was running: run again when it finishes (they used to be dropped).
    @ObservationIgnored private var triagePending = false
    @ObservationIgnored private var triageForce: Set<String> = []
    /// Last run, content-free: shown after "Re-triage" and logged (`[AI] triage …`).
    var triageStatus: String?
    @ObservationIgnored private var audit: AuditLog?
    @ObservationIgnored private var cachedBinary: URL??
    /// Gate used to key in-memory results (refreshed with every assistant build).
    @ObservationIgnored private(set) var lastGate: AIGatePolicy?
    @ObservationIgnored private var lastTier: AITier?
    @ObservationIgnored var agentAudit: AuditSink?

    /// Lock, settings change: drop in-memory results (the sealed cache stays in the encrypted store).
    func reset() { inbox.reset(); promises.reset(); triageTask?.cancel(); triageTask = nil; triage = [:]; summaries = [:]; answer = nil; bulk = nil; VoiceLearnModel.shared.reset() }   // VOICE2-HOOK

    init() {
        if let d = UserDefaults.standard.data(forKey: "ai.settings"), let s = try? JSONDecoder().decode(AIAssistSettings.self, from: d) {
            settings = s
        } else { settings = AIAssistSettings() }
    }

    private func save() { if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "ai.settings") } }

    // MARK: Assistant construction (policy gate + providers + audit)

    /// Label priority from which cloud AI sees metadata only. Default: no cap, Copilot's rule (Ryan 2026-11-19: Public /
    /// General were blocked by a fixed cap of 2). Content still needs VIEW+EXTRACT when encrypted; unknown labels and
    /// private items stay excluded. An admin can set a cap (UserDefaults / MDM key `AICloudLabelPriorityCap`).
    static var cloudLabelCap: Int {
        let v = UserDefaults.standard.object(forKey: "AICloudLabelPriorityCap") as? Int
        return v ?? Int.max
    }

    var trustPolicy: TrustPolicy { app?.trust.effectivePolicy ?? .byodDefault }

    var assistant: AIAssistant? {
        guard settings.choice != .off, let mail, mail.started, app?.trust.hidesContent != true else { return nil }
        let t = trustPolicy
        let allowed = t.allowedAIProviders.map { Set($0.compactMap(AIProviderID.init(rawValue:))) }
        let gate = AIGatePolicy(engine: mail.compliance, cloudAccess: AIOrgAccess(trustRawValue: t.aiAccess.rawValue),
                                onDeviceAccess: AIOrgAccess(trustRawValue: t.effectiveOnDeviceAIAccess.rawValue),
                                allowedProviders: allowed, aiMaxPriority: Self.cloudLabelCap)
        var cloud: (any AIProvider)?
        switch settings.choice {
        case .claudeCLI:
            if cachedBinary == nil { cachedBinary = .some(settings.claudePath.map { URL(fileURLWithPath: $0) } ?? ClaudeCLIProvider.locate()) }
            if let bin = cachedBinary ?? nil { cloud = ClaudeCLIProvider(model: settings.claudeModel, binary: bin) }
        case .openAICompatible:
            cloud = OpenAICompatibleProvider(config: settings.openAI, apiKey: { AIKeychain.load() })
        case .off, .onDevice: break
        }
        let onDevice: (any AIProvider)? = OnDeviceProvider.isAvailable ? OnDeviceProvider() : nil
        let a = AIAssistant(settings: settings, gate: gate, cloud: cloud, onDevice: onDevice, audit: { [weak self] r in
            // The log is opened on the first real call (never on render).
            Task { @MainActor in
                try? self?.auditLog()?.append(.aiAccess(client: "app", tool: "ai-" + r.feature, itemIds: [], count: r.items, decision: r.decision))
            }
        })
        lastGate = gate; lastTier = a.route(.triage)?.tier
        return a
    }

    var enabled: Bool { preview != nil || (assistant?.isEnabled ?? false) }

    /// Theme preview only (`--theme-preview`, fixtures): canned triage/summary so the AI surfaces can be rendered
    /// without a provider. Never set outside ThemePreview.
    struct Preview { var triage: [String: AITriage]; var summary: AIThreadSummary? }
    @ObservationIgnored var preview: Preview?
    func available(_ f: AIFeature) -> Bool { preview != nil || assistant?.route(f) != nil }

    /// Reply intents / AI draft need the open message to be shareable as content on the drafting tier.
    func canDraft(_ r: ReaderState) -> Bool {
        if preview != nil { return true }
        guard let a = assistant, let p = a.route(.draftReply) else { return false }
        return a.gate.exposure(r.header, mailbox: r.mailbox, tier: p.tier) == .content
    }

    /// Encrypted, hash-chained, content-free log of AI calls. Fixtures: ephemeral key, temp file.
    private func auditLog() -> AuditLog? {
        if let audit { return audit }
        let fixtures = mail?.isFixtures ?? true
        let url = fixtures
            ? FileManager.default.temporaryDirectory.appending(path: "CompliantOffice-\(ProcessInfo.processInfo.processIdentifier)/ai-audit.log")
            : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/CompliantOffice/ai-audit.log")
        guard let key = fixtures ? SymmetricKey(size: .bits256) : Self.auditKey() else { return nil }
        audit = try? AuditLog(url: url, seal: { d in
            guard let c = try AES.GCM.seal(d, using: key).combined else { throw CocoaError(.coderInvalidValue) }
            return c
        }, open: { d in try AES.GCM.open(AES.GCM.SealedBox(combined: d), using: key) })
        return audit
    }

    private static func auditKey() -> SymmetricKey? {
        let svc = "ai.niivo.mail.ai-audit"
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc,
                                kSecAttrAccount as String: "audit-key", kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc,
                                  kSecAttrAccount as String: "audit-key", kSecValueData as String: k.withUnsafeBytes { Data($0) },
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? k : nil
    }

    /// Wipe / sign-out: in-memory results and the API key go. The sealed cache goes with the mail store.
    func wipe() {
        triageTask?.cancel(); composer.cancel(); inbox.reset(); promises.reset()   // TRIAGE2-HOOK, PROMISES-HOOK
        triage = [:]; summaries = [:]; answer = nil; bulk = nil
        VoiceLearnModel.shared.reset()   // VOICE2-HOOK
        AIKeychain.delete()
    }

    func testConnection() async {
        testResult = "Testing…"
        guard let a = assistant else { testResult = "AI is off"; return }
        do { testResult = "OK: “\(try await a.testConnection())”" } catch { testResult = "\(error)" }
    }

    // MARK: 1. Triage (background, cached in the sealed store)

    /// Keyed by `AICacheKey` (id + changeKey + label + current gate decision), so relabels and policy changes miss.
    func triage(for row: MailRow) -> AITriage? {
        if let preview { return row.policy.redactDetails ? nil : preview.triage[row.id] }
        guard settings.choice != .off, let g = lastGate, let tier = lastTier else { return nil }
        let exp = g.exposure(row.message, mailbox: row.mailbox, tier: tier)
        guard exp != .excluded else { return nil }
        return triage[AICacheKey.triage(row.message, exposure: exp, tier: tier)]
    }

    /// Re-triage the visible top of the inbox, ignoring cached results (testing: "is the AI working, with context?").
    func retriage() {
        if usesConversationTriage { inbox.rerun(); return }   // TRIAGE2-HOOK
        guard let mail else { return }
        triageForce = Set(mail.visibleRows.prefix(30).map(\.id))
        triageStatus = "Re-triaging…"
        scheduleTriage()
    }

    func scheduleTriage() {
        guard !usesConversationTriage else { return }   // TRIAGE2-HOOK: the conversation path has its own loop
        guard settings.precomputeTriage, let mail, mail.isInbox, let a = assistant, let p = a.route(.triage),
              let store = mail.store else { triageStatus = triageForce.isEmpty ? triageStatus : "AI triage is off"; triageForce = []; return }
        let rows = Array(mail.visibleRows.prefix(30))
        var todo: [(MailMessage, String)] = []
        for r in rows {
            let exp = a.gate.exposure(r.message, mailbox: r.mailbox, tier: p.tier)
            guard exp != .excluded else { continue }
            let key = AICacheKey.triage(r.message, exposure: exp, tier: p.tier)
            if triageForce.contains(r.id) { todo.append((r.message, r.mailbox)); continue }
            if triage[key] != nil { continue }
            if let cached = store.sealed(AITriage.self, for: key) { triage[key] = cached } else { todo.append((r.message, r.mailbox)) }
        }
        guard !todo.isEmpty else { return }
        guard triageTask == nil else { triagePending = true; return }
        let forced = !triageForce.isEmpty
        triageForce = []
        // Context from the local store: recipient role, did the user already answer, who spoke last.
        let me = ([mail.me?.address] + mail.settings.identities.map(\.address)).compactMap { $0 }
        let user = mail.me.map { "\($0.name) <\($0.address)>" }
        var context: [String: [String]] = [:]
        for (m, _) in todo {
            let thread = (try? store.conversation(id: m.conversationId, limit: 50)) ?? []
            context[m.id] = TriageContext.lines(for: m, me: me, thread: thread)
        }
        triageTask = Task { [weak self] in
            var ai = 0, rule = 0, failed = 0, tags: [AITriageTag: Int] = [:]
            defer {
                let s = "triage \(todo.count): \(ai) AI, \(rule) by rule\(failed > 0 ? ", \(failed) failed" : "") — "
                    + AITriageTag.allCases.compactMap { t in tags[t].map { "\($0) \(t.title.lowercased())" } }.joined(separator: ", ")
                // TRIAGE2-HOOK (Phase 0): route, failure kinds and token estimate vs the model's context size (H1–H3).
                let ctx = p.tier == .onDevice ? OnDeviceProvider.contextTokens : nil
                FileHandle.standardError.write(Data("[AI] \(s) | route=\(p.tier.rawValue) \(AICallStats.shared.line(.triage, contextTokens: ctx))\n".utf8))
                if forced { self?.triageStatus = s; self?.mail?.toast(MailToast(text: "Re-\(s)", symbol: "sparkles")) }
                self?.triageTask = nil
                if self?.triagePending == true { self?.triagePending = false; self?.scheduleTriage() }
            }
            for chunk in stride(from: 0, to: todo.count, by: 10).map({ Array(todo[$0..<min($0 + 10, todo.count)]) }) {
                guard !Task.isCancelled else { return }
                let res: [String: AITriage]
                do { res = try await a.triage(chunk, context: context, user: user) } catch {
                    failed += chunk.count
                    let kind = (error as? AIAssistError).flatMap { if case .provider(let e) = $0 { e.kind.rawValue } else { nil } } ?? "other"
                    FileHandle.standardError.write(Data("[AI] triage batch failed: kind=\(kind) items=\(chunk.count)\n".utf8))   // TRIAGE2-HOOK (Phase 0)
                    continue
                }
                for (m, mb) in chunk {
                    guard let t = res[m.id] else { continue }
                    if t.aiGenerated { ai += 1 } else { rule += 1 }
                    tags[t.tag, default: 0] += 1
                    let key = AICacheKey.triage(m, exposure: a.gate.exposure(m, mailbox: mb, tier: p.tier), tier: p.tier)
                    self?.triage[key] = t
                    // Persist only where the label lets details live on disk (same rule as bodies/previews).
                    if MailContentPolicy.policy(for: m, mailbox: mb, engine: a.gate.engine).allowOfflineDetails,
                       self?.trustPolicy.allowOfflineBodies == true {
                        try? store.setSealed(t, for: key)
                    }
                }
            }
        }
    }

    /// Briefing groups: today's inbox (or the newest 50) by tag.
    /// Briefing groups. TRIAGE2-HOOK: by conversation state (incl. sent-only waiting threads) unless the old path is on.
    var briefing: [InboxTriageModel.Group] {
        guard let mail else { return [] }
        if usesConversationTriage { return inbox.briefing() }
        let start = Calendar.current.startOfDay(for: .now)
        var rows = mail.visibleRows.filter { $0.message.received >= start }
        if rows.count < 5 { rows = Array(mail.visibleRows.prefix(50)) }
        let grouped = Dictionary(grouping: rows) { triage(for: $0)?.tag ?? AIAssistant.ruleTriage($0.message).tag }
        return AITriageTag.allCases.compactMap { t in grouped[t].map { InboxTriageModel.Group(tag: t, title: t.title, rows: $0) } }
    }

    // MARK: Helpers

    private func run(_ label: String, on c: AIComposerState, _ work: @escaping @MainActor () async throws -> Void) {
        c.task?.cancel(); c.error = nil; c.busy = label
        c.task = Task { @MainActor in
            do { try await work() } catch {
                if !Task.isCancelled { c.error = "\(error)" }
            }
            c.busy = nil; c.task = nil
        }
    }

    /// Headers → bodies only where the header already allows content for the routed tier (then re-gated by the builder).
    private func withBodies(_ msgs: [MailMessage], mailbox: String, feature: AIFeature, limit: Int = 6) async -> [MailMessage] {
        guard let a = assistant, let p = a.route(feature), let sync = mail?.sync else { return msgs }
        var out: [MailMessage] = []
        for (i, m) in msgs.enumerated() {
            if i == 0 || i >= msgs.count - limit, m.body == nil, a.gate.exposure(m, mailbox: mailbox, tier: p.tier) == .content,
               let full = try? await sync.fetchBody(id: m.id) { out.append(full) } else { out.append(m) }
        }
        return out
    }

    // MARK: 2. Reply intents + AI draft

    func intent(_ i: AIReplyIntent) {
        guard let mail, let r = mail.reader else { return }
        composer = AIComposerState()
        mail.reply(.reply, to: r.header.id)
        guard mail.composer != nil else { return }
        if i == .delegate { composer.options.instruction = "Delegate to: "; composer.showPopover = true; return }
        draft(intent: i)
    }

    // MARK: Gate reasons (the menu shows them on disabled items; the call refuses with the same text)

    /// Why AI can't draft a reply in this composer (nil = it can). Same MailCore check as the call itself.
    func replyRefusal(_ c: ComposerState) -> String? {
        if preview != nil { return nil }
        guard let o = c.original else { return "Drafting a reply needs a message to reply to. Use Ask AI to write new mail." }
        guard let a = assistant else { return unavailableReason }
        return a.replyRefusal(original: o, mailbox: mail?.store?.mailbox(forFolder: o.folderId) ?? "me")
    }

    /// Why the draft's own text can't go to AI (nil = it can): the draft's label (with the reply floor) and the
    /// organisation's AI policy for the routed tier.
    func editRefusal(_ c: ComposerState) -> String? {
        if preview != nil { return nil }
        guard let a = assistant else { return unavailableReason }
        return a.editRefusal(labelId: c.labelId)
    }

    private var unavailableReason: String {
        if settings.choice == .off { return "AI is off (Settings → AI)" }
        if app?.trust.hidesContent == true { return "AI is unavailable while content is hidden" }
        return "AI isn't available right now"
    }

    /// The voice for this composer's recipients (Me → Organisation → Contact), minus the layers switched off for the
    /// next request.
    func voice(for c: ComposerState, language: AILanguage = .auto) -> VoiceResolution? {
        guard let mail else { return nil }
        let who = mail.voiceCounterpart(original: c.original, to: c.to)
        return mail.voiceProfile.resolve(counterpart: who?.address, languageOverride: language, excluding: composer.voiceOff)
    }

    /// Every layer for the current recipients (the menu's on/off toggles).
    func voiceLayers(for c: ComposerState) -> [VoiceResolution.Layer] {
        guard let mail else { return [] }
        let who = mail.voiceCounterpart(original: c.original, to: c.to)
        return mail.voiceProfile.resolve(counterpart: who?.address).layers
    }

    // MARK: 2. Reply drafts (land in the editor)

    func draft(intent: AIReplyIntent? = nil, retryPlacement: AIAppliedEdit.Placement? = nil) {
        guard let mail, let c = mail.composer, let o = c.original, let a = assistant else {
            composer.error = mail?.composer.flatMap { replyRefusal($0) } ?? "AI drafting needs a reply to an existing message"; return
        }
        if let why = replyRefusal(c) { composer.error = why; return }   // never a silent call
        let mb = mail.store?.mailbox(forFolder: o.folderId) ?? "me"
        let opts = composer.options
        composer.retry = .draft(intent)
        var slotText: [String] = []
        if intent == .proposeTime, let app {
            let evs = app.aiOwnBusyEvents(from: .now, to: .now.addingTimeInterval(14 * 86400))
            slotText = AISlots.describe(AISlots.propose(events: evs, from: .now))
        }
        let name = mail.me?.name.split(separator: " ").first.map(String.init)
        // VOICE: every draft goes through the voice path (single shot on AIPromptBuilder: the label gate sees every
        // message). The tool-loop path (`draftReplyAgent`) is no longer used for drafting; slots come from the local calendar.
        let me = ([mail.me?.address] + mail.settings.identities.map(\.address)).compactMap { $0 }
        let all = ((try? mail.store?.conversation(id: o.conversationId, limit: 500)) ?? []).filter { !$0.isDraft }
        let newest = Array(all.filter { $0.id != o.id }.sorted { $0.received > $1.received }.prefix(6))
        let who = mail.voiceCounterpart(original: o, to: c.to)
        let voice = mail.voiceProfile.resolve(counterpart: who?.address, languageOverride: opts.language, excluding: composer.voiceOff)
        composer.voiceOff = []   // one request only
        let contextLines = TriageContext.lines(for: o, me: me, thread: all)
        var sent: [MailMessage] = []
        if let store = mail.store, let addr = who?.address, let p = a.route(.draftReply) {
            let g = a.gate
            let ids = Set(all.map(\.id))
            sent = PeopleHistory.candidates(store: store, mailbox: mb, address: addr,
                                            recipients: { g.exposure($0, mailbox: mb, tier: p.tier) == .content ? $0.toRecipients + $0.ccRecipients : [] })
                .sent.filter { !ids.contains($0.id) && !$0.isDraft && g.exposure($0, mailbox: mb, tier: p.tier) == .content }
                .sorted { $0.received > $1.received }.prefix(3).map { $0 }
        }
        let sigPlain = c.editor.signaturePlain
        let state = composer
        // Where it goes: an empty reply gets the draft; text the user already wrote stays and the draft goes below.
        let target = AIEditText.target(body: c.body, selection: nil, signaturePlain: sigPlain)
        let placement: AIAppliedEdit.Placement = target.scope == .empty ? .replace : .insertBelow
        if retryPlacement == nil || state.applied == nil { state.anchor = AIEditAnchor(body: c.body, range: target.range) }
        run("Drafting…", on: composer) { [weak self] in
            let full = await self?.withBodies([o] + newest, mailbox: mb, feature: .draftReply, limit: 6) ?? [o]
            let examples = await self?.withBodies(sent, mailbox: mb, feature: .draftReply, limit: 3) ?? []
            let req = AIVoiceRequest(original: full[0], mailbox: mb, thread: Array(full.dropFirst()), styleExamples: examples,
                                     contextLines: contextLines, voice: voice, intent: intent, options: opts, slots: slotText, userName: name)
            let r = try await a.draftReplyInVoice(req, signaturePlain: sigPlain.isEmpty ? nil : sigPlain)
            guard let self, self.mail?.composer === c, self.composer === state else { return }   // that draft is gone
            let used = voice.formality != .auto ? voice.formality : (r.formalityUsed ?? .auto)
            let facts = VoiceSignatureFacts.from(counterpart: who?.address, thread: all, me: me, formality: used)
            state.voice = r.voice; state.why = r.why
            state.notes = r.notes + (slotText.isEmpty ? [] : ["Planned: hold these slots as tentative (not created yet)"])
            self.land(r.text, in: c, origin: .draft, placement: retryPlacement ?? placement, retry: retryPlacement != nil,
                      separate: true, signaturePlan: VoiceSignature.decide(model: r.wantsSignature, facts: facts))
            if let m = self.mail { VoiceLearnModel.shared.refineWithAI(mail: m) }   // VOICE2-HOOK: the user asked for AI here
        }
    }

    // MARK: 7. Editing actions (selection or whole body; land in the editor)

    func rewrite(_ mode: AIRewriteMode) { edit(AIEditAction(mode)) }

    /// Runs an AI editing action on the selection (or the whole text) and applies the result with undo.
    /// `source` / `retryPlacement`: Try again on the text the first try started from.
    func edit(_ action: AIEditAction, source: (text: String, scope: AIEditScope)? = nil, retryPlacement: AIAppliedEdit.Placement? = nil) {
        guard let mail, let c = mail.composer else { return }
        guard let a = assistant else { composer.error = editRefusal(c); return }
        if let why = a.editRefusal(labelId: c.labelId) { composer.error = why; return }   // never a silent call
        let s = composer
        let target: AIEditTarget
        if let src = source, let ap = s.applied, retryPlacement != nil {
            target = AIEditTarget(range: ap.span, text: src.text, scope: src.scope)
        } else {
            let tv = c.editor.textView?.selectedRange()
            let sel = tv.flatMap { $0.length > 0 ? $0.location..<($0.location + $0.length) : nil }
            target = AIEditText.target(body: c.body, selection: sel, signaturePlain: c.editor.signaturePlain)
        }
        if target.scope == .empty, !action.isCustom {
            s.error = "Write something first, or ask AI to write it (⌘J)"; return
        }
        if AIEditText.tooLong(target) { s.error = AIEditText.tooLongMessage; return }
        let voice = self.voice(for: c)
        s.voiceOff = []   // one request only
        s.retry = .edit(action, source: target.text, scope: target.scope)
        s.voice = voice
        var why = [target.scope == .selection ? "Sent: only your selection (\(target.text.count) characters)"
                   : target.scope == .body ? "Sent: only your text (signature and quoted history not included)"
                   : "Sent: only your instruction"]
        why += voice?.summary ?? []
        s.why = why
        s.notes = []
        if retryPlacement == nil || s.applied == nil { s.anchor = AIEditAnchor(body: c.body, range: target.range) }
        run(action.progress, on: s) { [weak self] in
            let r = try await a.edit(target.text, scope: target.scope, labelId: c.labelId, action: action, voice: voice)
            guard let self, self.mail?.composer === c, self.composer === s else { return }
            self.land(r.text, in: c, origin: .edit, placement: retryPlacement ?? .replace, retry: retryPlacement != nil,
                      separate: target.scope != .selection)
        }
    }

    /// Try again (Replace the AI text, or Add another version below), optionally with an extra instruction.
    func tryAgain(_ placement: AIAppliedEdit.Placement, instruction: String? = nil) {
        guard let r = composer.retry else { return }
        let instr = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let p: AIAppliedEdit.Placement? = composer.applied == nil ? nil : placement
        switch r {
        case .draft(let i):
            if !instr.isEmpty { composer.options.instruction = instr }
            draft(intent: i, retryPlacement: p)
        case .edit(let action, let source, let scope):
            let act: AIEditAction
            if instr.isEmpty { act = action }
            else if case .custom = action { act = .custom(instr) }
            else { act = .custom(action.title + ". " + instr) }
            edit(act, source: (source, scope), retryPlacement: p)
        }
    }

    /// The one place AI text enters the editor: applied, marked, undoable.
    private func land(_ text: String, in c: ComposerState, origin: AIAppliedEdit.Origin, placement: AIAppliedEdit.Placement,
                      retry: Bool, separate: Bool, signaturePlan: VoiceSignaturePlan? = nil) {
        let s = composer
        c.editor.reconcile(c.body)   // storage and body in step before any signature switch
        if retry {
            guard var prev = s.applied, case .land(let placement) = AIRetryLanding.decide(applied: s.applied, requested: placement) else {
                s.notes.append("The AI text was undone or kept before the new version arrived, so nothing was changed.")
                return
            }
            prev.track(c.body)
            var out = text
            if origin == .draft, !c.editor.signaturePlain.isEmpty { out = VoiceSignature.dedupeName(out, signaturePlain: c.editor.signaturePlain) }
            let next = prev.retried(text: out, placement: placement)
            s.applied = next; s.anchor = nil
            c.body = next.body
            if let mail { VoiceLearnModel.shared.accepted(c, voiceDraft: origin == .draft, mail: mail) }   // VOICE2-HOOK: baseline
            return
        }
        // A new request over an older AI text: the older one is the user's now.
        s.applied = nil
        // VOICE: toggle the composer's signature (never paste it into the text) before the body goes in.
        var out = text
        if origin == .draft, let plan = signaturePlan, let mail {
            let e = c.editor
            s.undoSignature = (e.signatureId, e.signatureIsDefault)
            switch plan {
            case .full:
                if e.signatureId == nil, let sig = mail.composerPrefs.defaultSignature(identity: c.from?.address, reply: true) {
                    e.applySignature(sig, byUser: false)
                }
            case .nameOnly: if e.signatureId != nil { e.applySignature(nil, byUser: true) }
            case .unchanged: break
            }
            // The sign-off name would repeat the signature's first line ("Jordan Miller" twice): drop it.
            if !e.signaturePlain.isEmpty { out = VoiceSignature.dedupeName(out, signaturePlain: e.signaturePlain) }
        } else { s.undoSignature = nil }
        var anchor = s.anchor ?? AIEditAnchor(body: c.body, range: AIEditText.target(body: c.body, selection: nil, signaturePlain: c.editor.signaturePlain).range)
        anchor.track(c.body)
        s.anchor = nil
        let spot = anchor.placement(requested: placement)
        guard let next = AIAppliedEdit.apply(body: c.body, target: spot.range, text: out, placement: spot.placement,
                                             origin: origin, separateFromFollowing: separate) else {
            s.error = "The text changed too much while AI was working; nothing was changed"; return
        }
        if spot.moved { s.notes.append("You edited that text while AI was working, so the result was added below it.") }
        s.applied = next
        c.body = next.body
        if let mail { VoiceLearnModel.shared.accepted(c, voiceDraft: origin == .draft, mail: mail) }   // VOICE2-HOOK: edits after this feed VoiceEdit
    }

    /// Keep: the AI text is the user's (marker off). Sending keeps it too.
    func keepApplied() {
        guard composer.applied != nil else { return }
        composer.applied = nil; composer.undoSignature = nil
    }

    /// Undo: what the AI text replaced comes back (and the signature it switched); edits elsewhere stay.
    func undoApplied() {
        guard let c = mail?.composer, composer.applied != nil else { return }
        composer.cancel()   // a Try again still running must not land after the Undo
        c.editor.reconcile(c.body)
        if let (id, isDefault) = composer.undoSignature, let mail, id != c.editor.signatureId {
            c.editor.applySignature(mail.composerPrefs.signature(id: id), byUser: false)   // tracked via bodyChanged
            c.editor.signatureIsDefault = isDefault
        }
        composer.undoSignature = nil
        guard var ap = composer.applied else { return }
        ap.track(c.body)
        composer.applied = nil
        c.body = ap.undone
        if ap.origin == .draft { VoiceLearnModel.shared.undone(c) }   // VOICE2-HOOK
        else if let mail { VoiceLearnModel.shared.accepted(c, voiceDraft: false, mail: mail) }
    }

    /// Every change of the primary composer's body (typing, ⌘Z, signature switch): the AI span and a running
    /// request's target follow it.
    func bodyChanged(_ c: ComposerState) {
        guard mail?.composer === c else { return }
        composer.anchor?.track(c.body)
        guard composer.applied != nil else { return }
        if composer.applied?.track(c.body) == .reverted {   // ⌘Z all the way back = Undo
            let o = composer.applied?.origin
            composer.applied = nil; composer.undoSignature = nil
            if o == .draft { VoiceLearnModel.shared.undone(c) }
        }
    }

    // MARK: 3. Pre-send (true = intercepted; ⌘↩ again sends)

    func interceptSend(_ c: ComposerState, at: Date?) -> Bool {
        guard settings.preSendCheck, enabled, let mail, let a = assistant else { return false }
        var h = Hasher(); h.combine(c.body); h.combine(c.subject); h.combine(c.allRecipients.map(\.address))
        let hash = h.finalize()
        if composer.checkedHash == hash { composer.task?.cancel(); composer.task = nil; composer.checking = false; return false }
        composer.checkedHash = hash
        let w = mail.externalWarning(c)
        composer.findings = AIAssistant.ruleChecks(text: c.body, hasAttachments: !c.editor.attachments.isEmpty, externalLabelledWarning: w.isStrong ? w.message : nil)
        composer.checking = true
        let mb = c.original.flatMap { mail.store?.mailbox(forFolder: $0.folderId) } ?? "me"
        let original = c.original, body = c.body, label = c.labelId
        composer.task?.cancel()
        composer.task = Task { @MainActor [weak self] in
            let full = original == nil ? nil : await self?.withBodies([original!], mailbox: mb, feature: .preSend, limit: 1).first
            let ai = await withTaskGroup(of: [AIPreSendFinding]?.self) { g -> [AIPreSendFinding] in
                g.addTask { try? await a.preSendAI(draft: body, draftLabelId: label, original: full, mailbox: mb) }
                g.addTask { try? await Task.sleep(for: .milliseconds(1500)); return nil }
                let first = await g.next() ?? nil
                g.cancelAll()
                return first ?? []
            }
            guard let self, !Task.isCancelled, self.composer.checkedHash == hash else { return }
            self.composer.checking = false
            self.composer.findings += ai
            if self.composer.findings.isEmpty, self.mail?.composer === c { self.mail?.send(c, at: at) }
        }
        return true
    }

    // MARK: 5. Thread summary

    func summarise() {
        guard let mail, let r = mail.reader, let a = assistant else { return }
        showThreadHeader = true
        let conv = r.header.conversationId
        let thread = r.thread.isEmpty ? [r.header] : r.thread
        summarising = conv; summaryError = nil
        Task { @MainActor [weak self] in
            let full = await self?.withBodies(thread, mailbox: r.mailbox, feature: .summarise) ?? thread
            do {
                let s = try await a.summarise(full, mailbox: r.mailbox)
                self?.summaries[conv] = (s, thread.count)
            } catch { self?.summaryError = "\(error)" }
            self?.summarising = nil
        }
    }

    func summary(for r: ReaderState) -> AIThreadSummary? { if let s = preview?.summary { return s }; return summaries[r.header.conversationId]?.summary }
    func summaryIsStale(_ r: ReaderState) -> Bool { (summaries[r.header.conversationId]?.count ?? 0) != max(1, r.thread.count) }

    func jump(to s: AIPromptSource) {
        guard let mail, let m = try? mail.store?.message(id: s.messageId, includeBody: false) else { return }
        answer = nil
        if mail.selectedFolderId != m.folderId { mail.selectedFolderId = m.folderId }
        mail.selectedMessageId = m.id
    }

    // MARK: 6. Search, ask, bulk

    func searchSubmitted() {
        guard let mail else { return }
        let q = mail.searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, askMode || NSEvent.modifierFlags.contains(.option) else { return }
        Task { await nlSearch(q) }
    }

    func nlSearch(_ q: String) async {
        guard let mail else { return }
        let parsed = await (assistant?.searchQuery(for: q) ?? .plain(q))
        let hits = await rankedSearch(q, parsed: parsed, limit: 100)   // SEARCHQ-HOOK
        mail.aiShowSearchResults(hits, summary: parsed.fromAI ? parsed.summary : nil)
    }

    /// SEARCHQ-HOOK: ranked local retrieval (natural mode: relaxed matching, DE/EN/FR/IT expansions, typo recovery,
    /// hints) for Ask / ⌥↩, then server-only hits (older than the cache) appended. Bulk actions keep `localSearch`
    /// (every word required) so a plan never sweeps in loosely related mail.
    private func rankedSearch(_ raw: String, parsed: AISearchQuery, limit: Int) async -> [MailMessage] {
        guard let mail, let store = mail.store else { return await localSearch(parsed, limit: limit) }
        let q = SearchQuery.natural(raw: raw, ai: parsed)
        let mb = mail.selectedMailbox
        let local = await Task.detached(priority: .userInitiated) { () -> [MailMessage] in
            var o = SearchEngine.Options(mailbox: mb, limit: limit)
            o.match = .natural
            return SearchEngine(store: store).search(q, o).hits.map(\.message)
        }.value
        // Server `$search` covers mail older than the cache: always asked, with a quarter of the slots kept for it.
        var seen = Set(local.map(\.id))
        let more = await localSearch(parsed, limit: limit).filter { seen.insert($0.id).inserted }
        let reserve = more.isEmpty ? 0 : min(more.count, max(1, limit / 4))
        let head = Array(local.prefix(limit - reserve))
        return Array((head + more.prefix(reserve) + local.dropFirst(head.count) + more.dropFirst(reserve)).prefix(limit))
    }

    private func localSearch(_ q: AISearchQuery, limit: Int) async -> [MailMessage] {
        guard let mail, let sync = mail.sync else { return [] }
        let text = q.textQuery.isEmpty ? (q.from ?? "") : q.textQuery
        let names = Dictionary(mail.folders.values.flatMap { $0 }.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var raw: [MailMessage]
        if text.isEmpty {
            raw = (try? mail.store?.messages(folderId: mail.selectedFolderId ?? "", limit: 500)) ?? []
        } else {
            raw = await sync.search(text, mailbox: mail.selectedMailbox, limit: limit * 4, includeServer: true)
        }
        return Array(raw.filter { q.matches($0, folderName: names[$0.folderId]) }.prefix(limit))
    }

    func ask(_ question: String) {
        guard let a = assistant, let mail else { return }
        answer = AIAnswerState(question: question)
        if let tb = toolbox(), let p = a.route(.ask), agentCapable(p) {
            let pack = contextPack(tier: p.tier)
            let id = answer?.id
            Task { @MainActor [weak self] in
                do {
                    let r = try await a.agent(.ask, task: question, context: pack, toolbox: tb, progress: { s in
                        Task { @MainActor in if self?.answer?.id == id { self?.answer?.progress = s } }
                    })
                    let t = AIAssistant.textResult(r, provider: p.id)
                    guard self?.answer?.id == id else { return }
                    self?.answer?.text = t.text; self?.answer?.sources = t.sources; self?.answer?.notes = t.notes; self?.answer?.progress = nil
                } catch { if self?.answer?.id == id { self?.answer?.error = "\(error)"; self?.answer?.progress = nil } }
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let q = await a.searchQuery(for: question)
            let hits = Array(await self.rankedSearch(question, parsed: q, limit: 8))   // SEARCHQ-HOOK
            let mb = mail.selectedMailbox
            let full = await self.withBodies(hits.reversed(), mailbox: mb, feature: .ask, limit: 8)
            do {
                let r = try await a.ask(question, retrieved: full.reversed().map { ($0, mb) })
                self.answer?.text = r.text; self.answer?.sources = r.sources; self.answer?.notes = r.notes
            } catch { self.answer?.error = "\(error)" }
        }
    }

    func planBulk(_ request: String) {
        guard let a = assistant else { return }
        bulk = AIBulkState(request: request)
        Task { @MainActor [weak self] in
            do {
                guard let plan = try await a.bulkPlan(request) else { self?.bulk?.error = "That isn't a supported bulk action (archive, mark read, flag, unflag)."; return }
                self?.bulk?.plan = plan
                self?.bulk?.matches = await self?.localSearch(plan.query, limit: 200) ?? []
            } catch { self?.bulk?.error = "\(error)" }
        }
    }

    func runBulk() {
        guard let mail, var b = bulk, let plan = b.plan, let store = mail.store else { return }
        for m in b.matches {
            let mb = store.mailbox(forFolder: m.folderId)
            switch plan.action {
            case .archive:
                guard let arch = try? store.folder(wellKnown: .archive, mailbox: mb), m.folderId != arch.id else { continue }
                mail.triage(.move(toFolderId: arch.id), id: m.id); b.undo.append((m.id, .move(toFolderId: m.folderId)))
            case .markRead: mail.triage(.markRead(true), id: m.id); b.undo.append((m.id, .markRead(m.isRead)))
            case .flag: mail.triage(.flag(.init(status: .flagged)), id: m.id); b.undo.append((m.id, .flag(m.flag)))
            case .unflag: mail.triage(.flag(.init(status: .notFlagged)), id: m.id); b.undo.append((m.id, .flag(m.flag)))
            }
        }
        b.done = true; bulk = b
    }

    func undoBulk() {
        guard let mail, let b = bulk else { return }
        for u in b.undo.reversed() { mail.triage(u.action, id: u.id) }
        bulk = nil
    }

    // MARK: ⌘K entries

    func paletteItems(query: String) -> [MailModel.PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard enabled, !q.isEmpty else { return [] }
        var items: [MailModel.PaletteItem] = []
        if available(.ask) { items.append(.init(id: "ai-ask", title: "Ask AI: \(q)", subtitle: "answers with sources", symbol: "sparkles", kind: .section("ai-ask"))) }
        items.append(.init(id: "ai-search", title: "Search: \(q)", subtitle: "natural language", symbol: "sparkle.magnifyingglass", kind: .section("ai-search")))
        if available(.bulkPlan) { items.append(.init(id: "ai-bulk", title: "Do: \(q)", subtitle: "preview first", symbol: "checklist", kind: .section("ai-bulk"))) }
        return items
    }

    static let fixedPalette: [MailModel.PaletteItem] = [
        .init(id: "ai-reply", title: "AI reply…", subtitle: "⇧⌘R", symbol: "sparkles", kind: .section("ai-reply")),
        .init(id: "ai-summary", title: "Summarise thread", subtitle: "⇧⌘S", symbol: "text.append", kind: .section("ai-summary")),
        .init(id: "ai-briefing", title: "Briefing", subtitle: "⌃⌘B", symbol: "sun.horizon", kind: .section("ai-briefing")),
    ]

    func runPalette(_ id: String, query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        switch id {
        case "ai-ask": ask(q)
        case "ai-search": mail?.searchText = q; Task { await nlSearch(q) }
        case "ai-bulk": planBulk(q)
        case "ai-reply": aiReply()
        case "ai-summary": summarise()
        case "ai-briefing": showBriefing = true
        default: break
        }
    }

    func aiReply() {
        guard let mail, mail.selectedRow != nil else { return }
        composer = AIComposerState()
        mail.reply(.reply)
        if mail.composer != nil { composer.showPopover = true }
    }
}

// MARK: - Agent tools + context pack (shared OfficeTools layer over the live store)

extension AIAssistModel {
    /// A real tool loop exists: OpenAI-style function calling, or Claude with the relay binary AND the opt-in
    /// `ai.claudeAgent` default (off until the live agent run has verified isolation). Everything else keeps the
    /// richer single-shot paths (bodies of the original + thread, parsed search query).
    func agentCapable(_ p: any AIProvider) -> Bool {
        if p is any AIToolCallingProvider { return true }
        if p is ClaudeCLIProvider { return UserDefaults.standard.bool(forKey: "ai.claudeAgent") && ClaudeMCPServer.locateOfficeMCP() != nil }
        return false
    }

    /// nil when mail isn't running or AI is off. Built per request, so the gate always reflects the current policy.
    func toolbox() -> AppAgentToolbox? {
        guard assistant != nil, let mail, let sync = mail.sync, let store = mail.store, let app,
              let cal = app.aiCalendarService else { return nil }
        let t = trustPolicy
        return AppAgentToolbox(sync: sync, store: store, calendar: cal, engine: mail.compliance, calendars: app.calendars,
                               me: mail.me ?? EmailAddress(name: "", address: ""),
                               cloudTrust: t.aiAccess, onDeviceTrust: t.effectiveOnDeviceAIAccess,
                               cloudMaxPriority: Self.cloudLabelCap, audit: mcpAudit(fixtures: app.mode == .fixtures))
    }

    func mcpAudit(fixtures: Bool) -> AuditSink {
        if let a = agentAudit { return a }
        let a = AuditSink.make(fixtures: fixtures, path: nil)
        agentAudit = a
        return a
    }

    /// ~2 KB gated context: open message, me, now, today's agenda, people on the open message, folder, draft.
    func contextPack(tier: AITier, open: (MailMessage, String)? = nil) -> String {
        guard let mail, let gate = lastGate else { return "{}" }
        var i = AIContextInput(me: mail.me ?? EmailAddress(name: "", address: ""))
        i.mailboxes = mail.mailboxes
        i.workingHours = "08:30-17:00"
        let cal = Calendar.current
        let day = cal.startOfDay(for: .now)
        if let app {
            i.agenda = app.aiOwnBusyEvents(from: day, to: day.addingTimeInterval(86_400))
                .filter { !$0.isCancelled }
                // Private/personal/confidential items: subject never shared, shown as busy at most.
                .map { AIContextEvent(start: $0.start, end: $0.end, subject: $0.legacySensitivity == .normal ? $0.subject : "busy",
                                      labelId: $0.labelId) }
        }
        var openMsg = open
        if openMsg == nil, let r = mail.reader, let m = try? mail.store?.message(id: r.header.id, includeBody: false) {
            openMsg = (m, mail.store?.mailbox(forFolder: m.folderId) ?? "me")
        }
        if let (m, mb) = openMsg {
            i.open = (m, mb)
            if let store = mail.store, let from = m.from?.address, from.lowercased() != i.me.address.lowercased() {
                let domains: Set<String> = i.me.address.split(separator: "@").last.map { [String($0).lowercased()] } ?? []
                let vis: (MailMessage) -> Bool = { gate.exposure($0, mailbox: mb, tier: tier) != .excluded }
                let c = PeopleHistory.candidates(store: store, mailbox: mb, address: from,
                                                 recipients: { gate.exposure($0, mailbox: mb, tier: tier) == .content ? $0.toRecipients + $0.ccRecipients : [] })
                let ds = usesConversationTriage ? inbox.decisions : [:]   // TRIAGE2-HOOK: awaiting lists = conversation state
                i.people = [PeopleHistory.compute(address: from, received: c.received, sent: c.sent, internalDomains: domains, visible: vis,
                                                  triage: usesConversationTriage ? { ds[$0] } : nil)]
            }
        }
        i.folderName = mail.selectedFolder?.displayName
        if let c = mail.composer { i.draft = (c.body, c.labelId) }
        return AIContextPack.build(i, gate: gate, tier: tier)
    }
}

struct AppAgentToolbox: AIAgentToolbox {
    let sync: MailSync, store: MailStore, calendar: any CalendarService, engine: CachedLabelPolicyEngine
    let calendars: [CalendarInfo], me: EmailAddress
    let cloudTrust: TrustAIAccess, onDeviceTrust: TrustAIAccess, cloudMaxPriority: Int
    let audit: AuditSink

    func server(tier: AITier) -> MCPServer {
        let b = Backend.inProcess(sync: sync, store: store, calendar: calendar, engine: engine, calendars: calendars, me: me,
                                  trust: tier == .onDevice ? onDeviceTrust : cloudTrust,
                                  aiMaxPriority: tier == .onDevice ? Int.max : cloudMaxPriority)
        return MCPServer.agent(backend: b, audit: audit)
    }

    func executor(tier: AITier) -> (any AIToolExecutor)? { OfficeToolExecutor(server: server(tier: tier)) }

    func claudeHost(tier: AITier, callLimit: Int, onCall: @escaping @Sendable (String, String, AIToolResult) -> Void) async throws -> AIClaudeHost? {
        guard let bin = ClaudeMCPServer.locateOfficeMCP() else { return nil }
        let s = server(tier: tier)
        await s.configureAgent(callLimit: callLimit, onCall: onCall)
        let host = try MCPSocketHost(server: s)
        let cfg = ClaudeMCPServer(command: bin, args: ["--relay", host.socketPath, "--relay-token", host.token],
                                  tools: s.toolNames)
        return AIClaudeHost(server: cfg, stop: { host.stop() })
    }
}
