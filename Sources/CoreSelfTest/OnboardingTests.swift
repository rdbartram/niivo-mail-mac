import Foundation
import CalendarCore
import MailCore

/// ONBOARDING: step state machine + per-account completion, AI choice clamped by policy, local server parsing,
/// "Learn my voice" modes (Off / Suggest / Automatic), Forget per layer, Me learned from sent mail. Synthetic only.
@MainActor
func runOnboardingTests() async {
    section("Onboarding: steps, AI clamp, local servers, voice modes")

    // 1. Step state machine.
    var f = OnboardingFlow()
    check(f.step == .welcome && f.isFirst, "flow: a first run starts at Welcome")
    f.complete(); check(f.step == .ai, "flow: complete moves on")
    f.skip(); check(f.step == .localModels && f.progress.skipped.contains(.ai), "flow: skip marks the step skipped and moves on")
    f.back(); check(f.step == .ai, "flow: back")
    f.complete(); check(f.progress.completed.contains(.ai) && !f.progress.skipped.contains(.ai), "flow: completing a skipped step un-skips it")
    f.skip(); f.skip(); f.complete()
    check(f.step == .done && !f.progress.isFinished, "flow: reaches Done without finishing")
    f.complete()
    check(f.progress.isFinished && f.progress.completed.contains(.done), "flow: completing Done finishes")
    let at = f.progress.finishedAt
    f.complete()
    check(f.progress.finishedAt == at, "flow: finishing again keeps the first finish date")

    var g = OnboardingFlow()
    g.complete(); g.finish()
    check(g.progress.isFinished && g.progress.completed == [.welcome, .done]
          && g.progress.skipped == [.ai, .localModels, .voice, .signatures], "flow: Skip setup finishes with the rest skipped")

    var partial = OnboardingProgress(); partial.completed = [.welcome, .ai]; partial.skipped = [.localModels]
    check(OnboardingFlow(progress: partial).step == .voice, "flow: resumes at the first step neither done nor skipped")
    check(OnboardingFlow(progress: g.progress, restart: true).step == .welcome, "flow: Run setup again starts at Welcome")
    var again = OnboardingFlow(progress: g.progress, restart: true)
    again.complete()
    check(again.progress.completed.contains(.welcome) && again.progress.isFinished, "flow: re-run keeps earlier progress")

    // 2. Persistence per account.
    let suite = "niivo.selftest.onboarding.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    check(OnboardingStore.shouldAutoShow(account: "oid-a.tid-1", defaults: d), "store: a new account gets setup")
    check(!OnboardingStore.shouldAutoShow(account: nil, defaults: d) && !OnboardingStore.shouldAutoShow(account: "", defaults: d),
          "store: no account → never auto-show (fixtures, signed out)")
    OnboardingStore.save(g.progress, account: "oid-a.tid-1", defaults: d)
    check(!OnboardingStore.shouldAutoShow(account: "oid-a.tid-1", defaults: d), "store: finished account doesn't see it again")
    check(OnboardingStore.shouldAutoShow(account: "oid-b.tid-1", defaults: d), "store: a second account still gets its own setup")
    check(OnboardingStore.load(account: "OID-A.TID-1", defaults: d) == g.progress, "store: round-trip, account id case-insensitive")
    check(!OnboardingStore.key(account: "oid-a.tid-1").contains("oid-a"), "store: key holds a hash, not the account id")
    d.removePersistentDomain(forName: suite)

    // 3. AI choice clamped by policy.
    let any: Set<AIProviderID>? = nil
    check(AIChoicePolicy.clamp(.cloudWherePermitted, cloudAccess: .followLabels, onDeviceAccess: .followLabels, allowedProviders: any)
          == .cloudWherePermitted, "clamp: open policy keeps cloud")
    check(AIChoicePolicy.clamp(.cloudWherePermitted, cloudAccess: .off, onDeviceAccess: .followLabels, allowedProviders: any)
          == .onDeviceOnly, "clamp: cloud off → on-device")
    check(AIChoicePolicy.clamp(.cloudWherePermitted, cloudAccess: .off, onDeviceAccess: .off, allowedProviders: any) == .off,
          "clamp: everything off → off")
    check(AIChoicePolicy.clamp(.cloudWherePermitted, cloudAccess: .followLabels, onDeviceAccess: .followLabels,
                               allowedProviders: [.onDevice]) == .onDeviceOnly, "clamp: allow-list without cloud providers → on-device")
    check(AIChoicePolicy.clamp(.onDeviceOnly, cloudAccess: .followLabels, onDeviceAccess: .followLabels,
                               allowedProviders: [.claudeCLI]) == .off, "clamp: never moves up (on-device refused → off, not cloud)")
    check(AIChoicePolicy.clamp(.off, cloudAccess: .followLabels, onDeviceAccess: .followLabels, allowedProviders: any) == .off,
          "clamp: off stays off")
    check(AIChoicePolicy.policyRefusal(.cloudWherePermitted, cloudAccess: .off, onDeviceAccess: .followLabels, allowedProviders: any)?
            .contains("organisation") == true
          && AIChoicePolicy.policyRefusal(.onDeviceOnly, cloudAccess: .followLabels, onDeviceAccess: .off, allowedProviders: any) != nil
          && AIChoicePolicy.policyRefusal(.cloudWherePermitted, cloudAccess: .metadataOnly, onDeviceAccess: .off, allowedProviders: any) == nil,
          "clamp: refusals name the policy; metadata-only cloud is still allowed")
    check(AIChoicePolicy.cloudProviders(cloudAccess: .followLabels, allowedProviders: [.openAICompatible, .onDevice]) == [.openAICompatible],
          "clamp: cloud providers follow the allow-list")
    check(AIChoicePolicy.providerChoice(.cloudWherePermitted, current: .claudeCLI, cloud: nil) == .claudeCLI
          && AIChoicePolicy.providerChoice(.cloudWherePermitted, current: .onDevice, cloud: .openAICompatible) == .openAICompatible
          && AIChoicePolicy.providerChoice(.cloudWherePermitted, current: .onDevice, cloud: nil) == .off
          && AIChoicePolicy.providerChoice(.onDeviceOnly, current: .claudeCLI, cloud: nil) == .onDevice
          && AIChoicePolicy.choice(for: .openAICompatible) == .cloudWherePermitted,
          "clamp: maps onto the existing provider setting (cloud keeps the configured provider, never guesses one)")

    // 4. Local servers.
    check(LocalModelServer.refusal(baseURL: "http://localhost:11434/v1") == nil
          && LocalModelServer.refusal(baseURL: "https://models.example/v1") == nil
          && LocalModelServer.refusal(baseURL: "http://192.168.1.5:11434/v1") != nil
          && LocalModelServer.refusal(baseURL: "ftp://localhost") != nil && LocalModelServer.refusal(baseURL: "nope") != nil,
          "local: plain http only to loopback")
    check(LocalModelServer.ollamaTagsURL(baseURL: "http://localhost:11434/v1/")?.absoluteString == "http://localhost:11434/api/tags"
          && LocalModelServer.modelsURL(baseURL: "http://localhost:1234/v1/")?.absoluteString == "http://localhost:1234/v1/models"
          && LocalModelServer.ollamaTagsURL(baseURL: "http://localhost:1234") == nil, "local: probe URLs")
    let oa = LocalModelServer.parseOpenAIModels(Data(#"{"object":"list","data":[{"id":"llama3.2:3b"},{"id":"qwen2.5:7b"},{"x":1}]}"#.utf8))
    let ol = LocalModelServer.parseOllamaTags(Data(#"{"models":[{"name":"llama3.2:3b","size":2019393189,"details":{"parameter_size":"3.2B"}}]}"#.utf8))
    let merged = LocalModelServer.merge(openAI: oa, ollama: ol)
    check(oa.map(\.name) == ["llama3.2:3b", "qwen2.5:7b"] && ol.first?.sizeBytes == 2_019_393_189 && ol.first?.parameters == "3.2B"
          && merged.first?.sizeBytes == 2_019_393_189 && merged.last?.sizeBytes == nil,
          "local: OpenAI + Ollama lists parsed and merged")
    check(LocalModelServer.parseOpenAIModels(Data("not json".utf8)).isEmpty && LocalModelServer.parseOllamaTags(Data("{}".utf8)).isEmpty,
          "local: junk → no models")

    // 5. Voice modes gate learning.
    let defaults = VoiceLearnModes()
    check(defaults.me == .suggest && defaults.organisation == .suggest && defaults.contacts == .suggest,
          "modes: default Suggest everywhere (behaviour before the modes)")
    let old = try? JSONDecoder().decode(VoiceLearnModes.self, from: Data(#"{"me":"off"}"#.utf8))
    check(old?.me == .off && old?.contacts == .suggest, "modes: partial JSON decodes with defaults")
    let contact = VoiceContact(address: "anna@fabrikam.example", displayName: "Anna", notes: "Role: CFO")
    let org = VoiceOrg(key: "fabrikam.example", displayName: "Fabrikam", notes: "Tone: Sie / vous")
    let stamp = Date(timeIntervalSince1970: 1_790_000_000)
    func run(_ m: VoiceLearnModes, _ c: VoiceLearnCandidate) -> (VoiceLearnDecision, VoiceProfile, [VoiceLearnCandidate]) {
        var p = VoiceProfile(); var q: [VoiceLearnCandidate] = []
        let r = m.offer(c, profile: &p, queue: &q, now: stamp)
        return (r, p, q)
    }
    var off = VoiceLearnModes(); off.contacts = .off
    let r1 = run(off, .contact(contact))
    check(r1.0 == .dropped && r1.1.contacts.isEmpty && r1.2.isEmpty && off.route(.contacts) == .dropped,
          "modes: Off → nothing learnt, nothing queued (and route says don't scan)")
    let r2 = run(VoiceLearnModes(), .contact(contact))
    check(r2.0 == .queued && r2.1.contacts.isEmpty && r2.2 == [.contact(contact)], "modes: Suggest → queued, not saved")
    var auto = VoiceLearnModes(); auto.contacts = .automatic; auto.organisation = .automatic; auto.me = .automatic
    let r3 = run(auto, .contact(contact))
    check(r3.0 == .saved && r3.1.contact(address: contact.address)?.updated == stamp && r3.2.isEmpty, "modes: Automatic → saved (stamped)")
    let r4 = run(auto, .organisation(org))
    check(r4.0 == .saved && r4.1.org(key: org.key) != nil, "modes: Automatic organisation saved")
    let r5 = run(auto, .me("I write briefly."))
    check(r5.0 == .saved && r5.1.me == "I write briefly.", "modes: Automatic Me saved")
    var mixed = VoiceLearnModes(); mixed.me = .off
    check(run(mixed, .me("x")).0 == .dropped && run(mixed, .organisation(org)).0 == .queued, "modes: per layer, independent")

    // Nudges honour the modes without burning the rate limit.
    var log = VoiceNudgeLog()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for (i, a) in ["a@x.example", "b@x.example"].enumerated() {
        _ = VoiceNudges.afterSend(VoiceEdit(kinds: [.removedGreeting]), contact: a, name: "N\(i)", log: &log, now: now.addingTimeInterval(Double(i)))
    }
    var log2 = log
    let meBlocked = VoiceNudges.afterSend(VoiceEdit(kinds: [.removedGreeting]), contact: "c@x.example", name: "Cee", log: &log2, now: now,
                                          allowMe: false)
    check(meBlocked?.target == .contact(address: "c@x.example", name: "Cee") && log2.lastShown[VoiceNudgeLog.me] == nil,
          "nudges: Me off → falls back to the contact, Me's rate limit untouched")
    var log3 = log
    let contactsOff = VoiceNudges.afterSend(VoiceEdit(kinds: [.toFormal]), contact: "d@x.example", name: "Dee", log: &log3, now: now,
                                            allowContact: false)
    check(contactsOff == nil && log3.lastShown["d@x.example"] == nil, "nudges: contacts off → no contact nudge")
    var log4 = log
    let meOn = VoiceNudges.afterSend(VoiceEdit(kinds: [.removedGreeting]), contact: "c@x.example", name: "Cee", log: &log4, now: now)
    check(meOn?.target == .me, "nudges: default still offers Me after three contacts")

    // 6. Forget deletes only that layer.
    var p = VoiceProfile(me: "custom me", orgs: [org], contacts: [contact])
    var q = p; q.forget(.contacts)
    check(q.contacts.isEmpty && q.orgs == [org] && q.me == "custom me", "forget: Contacts only")
    q = p; q.forget(.organisation)
    check(q.orgs.isEmpty && q.contacts == [contact] && q.me == "custom me", "forget: Company only")
    q = p; q.forget(.me)
    check(q.meIsDefault && q.orgs == [org] && q.contacts == [contact], "forget: Me back to the default, others kept")
    p = q
    var nl = VoiceNudgeLog()
    nl.dismissed = ["contact:anna@fabrikam.example", "org:fabrikam.example"]; nl.muted = [VoiceNudgeLog.me, "anna@fabrikam.example"]
    nl.lastShown = [VoiceNudgeLog.me: now, "anna@fabrikam.example": now]
    nl.events = [.init(kind: .shortened, contact: "anna@fabrikam.example", at: now)]
    var n1 = nl; n1.forget(.contacts)
    check(n1.dismissed == ["org:fabrikam.example"] && n1.muted == [VoiceNudgeLog.me] && n1.lastShown.keys.sorted() == [VoiceNudgeLog.me]
          && n1.events.isEmpty, "forget: contacts clear their nudge history only")
    var n2 = nl; n2.forget(.organisation)
    check(n2.dismissed == ["contact:anna@fabrikam.example"] && n2.muted.count == 2, "forget: company clears its dismissals only")
    var n3 = nl; n3.forget(.me)
    check(!n3.muted.contains(VoiceNudgeLog.me) && n3.lastShown[VoiceNudgeLog.me] == nil && n3.dismissed.count == 2
          && n3.muted.contains("anna@fabrikam.example"), "forget: Me clears only its own mute / last shown")

    // 7. Me from sent mail: forwards, private and gate-blocked mail skipped; facts only.
    let L = FixtureCalendarService.labels
    let eng = CachedLabelPolicyEngine(labels: L, synced: true)
    let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
    func sent(_ i: Int, _ body: String, subject: String = "Re: plan", priv: Bool = false, label: String? = nil) -> MailMessage {
        MailMessage(id: "s\(i)", folderId: "sentitems", conversationId: "c\(i)", subject: subject,
                    from: .init(name: "Me", address: "me@contoso.example"), toRecipients: [.init(name: "", address: "x@fabrikam.example")],
                    received: stamp.addingTimeInterval(Double(i) * 3600), preview: nil, body: body, bodyIsHTML: false,
                    labelId: label, isPrivate: priv, changeKey: "ck")
    }
    let de = "Hoi Anna\n\nKannst du mir das bis Freitag schicken? Danke dir für die Hilfe mit dem Plan.\n\nLiebe Grüsse\nJordan"
    var mails = (0..<6).map { sent($0, de) }
    mails.append(sent(10, "FORWARDED-SECRET Sehr geehrte Frau Muster, Ihre Unterlagen.", subject: "WG: Unterlagen"))
    mails.append(sent(11, "PRIVATE-SECRET text", priv: true))
    let restricted = L.first { $0.name.localizedCaseInsensitiveContains("highly") || $0.name.localizedCaseInsensitiveContains("restricted") }
    if let r = restricted { mails.append(sent(12, "GATED-SECRET text", label: r.id)) }
    let facts = VoiceLearn.meFacts(sent: mails, mailbox: "me", gate: gate)
    check(facts.analysed == 6 && facts.skippedForward == 1 && facts.skippedPrivate == 1 && facts.skippedGate == (restricted == nil ? 0 : 1),
          "me: forwards, private and label-gated mail skipped")
    check(facts.language == .de && facts.formality == .informal && facts.greets == true && facts.signsOff == true,
          "me: language, Du, greeting and sign-off from own text")
    let notes = VoiceLearn.meNotes(facts) ?? ""
    check(notes.hasPrefix(VoiceLearn.meLearnedHeader) && notes.contains("German") && notes.contains("Du")
          && !notes.contains("SECRET") && !notes.contains("Freitag"), "me: notes are facts only, no mail text")
    check(VoiceLearn.meNotes(VoiceLearn.meFacts(sent: Array(mails.prefix(3)), mailbox: "me", gate: gate)) == nil,
          "me: fewer than 5 mails → no notes")
    check(VoiceLearn.meFacts(sent: (0..<60).map { sent($0, de) }, mailbox: "me", gate: gate).considered == VoiceLearn.meSampleSize,
          "me: reads at most the last 50 sent")
    let once = VoiceLearn.applyMeNotes(notes, to: "I write briefly.")
    let twice = VoiceLearn.applyMeNotes("\(VoiceLearn.meLearnedHeader) (9 mails):\n- I mostly write in English.", to: once)
    check(once.hasPrefix("I write briefly.\n\n") && once.hasSuffix(notes) && twice.hasPrefix("I write briefly.\n\n")
          && twice.components(separatedBy: VoiceLearn.meLearnedHeader).count == 2 && twice.contains("English"),
          "me: learned block appended once, then replaced")
    let blockedGate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .off)
    check(VoiceLearn.meFacts(sent: mails, mailbox: "me", gate: blockedGate).analysed == 0, "me: on-device AI off → nothing read")
}
