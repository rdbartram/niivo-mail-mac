import SwiftUI
import MailCore

// VOICE2: suggested voice for a new contact / organisation (composer card, never saved silently), voice nudges
// (after-send toast, thread mismatch in the composer card, "Review voice" in the Voice menu), and signature import
// from Sent Items. Pure logic lives in MailCore/AIVoiceLearn.swift. Mail text stays in memory; the nudge log is
// kinds, keys and dates only.

@MainActor @Observable
final class VoiceLearnModel {
    static let shared = VoiceLearnModel()

    struct Suggestion {
        var counterpart: String
        var name: String
        var contact: VoiceContact?
        var org: VoiceOrg?
        var aiBusy = false
        var aiNote: String?
        var aiDone = false
    }
    /// Composer card: a suggested layer for the current counterpart, or a thread-mismatch nudge.
    var suggestion: Suggestion?
    var nudge: VoiceNudge?
    /// After-send nudge shown in a toast.
    var toastNudge: VoiceNudge?
    /// Contacts whose layer is due a review (computed when a composer opens; read by the Voice menu).
    var review: Set<String> = []
    /// Signature import status line.
    var importStatus: String?
    var importing = false

    /// The text of the last accepted AI draft per composer (memory only; cleared on lock / wipe).
    @ObservationIgnored private var baselines: [UUID: (text: String, address: String, name: String)] = [:]
    @ObservationIgnored private var prepared: String?
    /// Gate-admitted headers for the current suggestion (memory only), for the optional AI step.
    @ObservationIgnored private var excerpts: [MailMessage] = []
    @ObservationIgnored private var excerptMailbox = "me"

    /// ONBOARDING: Me learnt from sent mail in Suggest mode, awaiting Save / Discard (memory only), and its status line.
    var meProposal: String?
    var meStatus: String?
    var learningMe = false
    /// Bumped when the "Learn my voice" modes change (they live in UserDefaults, see OnboardingViews.swift).
    var modesRevision = 0

    func reset() {
        suggestion = nil; nudge = nil; toastNudge = nil; review = []; baselines = [:]; prepared = nil; excerpts = []
        meProposal = nil; meStatus = nil   // ONBOARDING
    }

    // MARK: Gate (independent of whether AI is on: on-device facts only need the label gate)

    func gate(_ mail: MailModel) -> AIGatePolicy? {
        guard let app = mail.ai.app, !app.trust.hidesContent, mail.started else { return nil }
        let t = app.trust.effectivePolicy
        let allowed = t.allowedAIProviders.map { Set($0.compactMap(AIProviderID.init(rawValue:))) }
        return AIGatePolicy(engine: mail.compliance, cloudAccess: AIOrgAccess(trustRawValue: t.aiAccess.rawValue),
                            onDeviceAccess: AIOrgAccess(trustRawValue: t.effectiveOnDeviceAIAccess.rawValue),
                            allowedProviders: allowed, aiMaxPriority: AIAssistModel.cloudLabelCap)
    }

    private func log(_ mail: MailModel) -> VoiceNudgeLog { mail.store?.voiceNudgeLog() ?? fallbackLog }
    @ObservationIgnored private var fallbackLog = VoiceNudgeLog()
    private func save(_ l: VoiceNudgeLog, _ mail: MailModel) {
        if let store = mail.store { try? store.save(voiceNudgeLog: l) } else { fallbackLog = l }
    }

    // MARK: Composer opened on a reply

    func prepare(_ c: ComposerState, mail: MailModel) {
        func why(_ r: String) { FileHandle.standardError.write(Data("[VoiceLearn] prepare: \(r)\n".utf8)) }
        guard let who = mail.voiceCounterpart(original: c.original, to: c.to) else { why("no counterpart"); suggestion = nil; nudge = nil; return }
        let a = who.address.lowercased()
        guard prepared != a else { return }
        prepared = a; suggestion = nil; nudge = nil; excerpts = []
        guard let store = mail.store, let gate = gate(mail) else { why("no store/gate (locked, hidden or not started)"); return }
        let modes = self.modes   // ONBOARDING: "Learn my voice", Off stops before any mail is read
        guard modes.contacts != .off || modes.organisation != .off else { why("learning off for contacts and company"); return }
        let mb = c.original.flatMap { store.mailbox(forFolder: $0.folderId) } ?? "me"
        let profile = mail.voiceProfile
        var nlog = log(mail)
        let cand = PeopleHistory.candidates(store: store, mailbox: mb, address: a, sentScan: 1_000,
                                            recipients: { $0.isPrivate ? [] : $0.toRecipients + $0.ccRecipients })
        let entry = PeopleHub.shared.people.first { $0.address?.lowercased() == a }
        let dir = entry.map { VoiceDirectoryFacts(title: $0.jobTitle, department: $0.department, company: $0.company) }
        let name = who.name.isEmpty ? a : who.name
        if modes.contacts != .off, let layer = profile.contact(address: a) {
            // Stale layer: subtle "Review voice" in the Voice menu (never a popup).
            let since = layer.updated.map { u in (cand.received + cand.sent).filter { $0.received > u && !$0.isPrivate }.count } ?? 0
            if VoiceNudges.needsReview(updated: layer.updated, mailsSince: since, now: .now) { review.insert(a) } else { review.remove(a) }
            // Thread disagrees with the layer (Du/Sie or language set explicitly).
            let thread = ((try? store.conversation(id: c.original?.conversationId ?? "", limit: 50)) ?? [])
                .filter { $0.from?.address.lowercased() == a && !$0.isDraft }
            let f = VoiceLearn.facts(address: a, displayName: name, directory: nil, internalDomains: mail.settings.internalDomains,
                                     received: thread, sent: [], mailbox: mb, gate: gate, textLimit: 4)
            nudge = VoiceNudges.mismatch(layer: layer, observedFormality: f.formality, observedLanguage: f.language,
                                         name: layer.title, log: &nlog, now: .now)
            if let n = nudge, modes.contacts == .automatic { save(nlog, mail); nudge = nil; applyNow(n, mail: mail); return }
            if nudge != nil { why("mismatch nudge"); save(nlog, mail); return }
        }
        let orgKey = MailDomains.companyKey(for: a)
        let wantContact = modes.contacts != .off && profile.contact(address: a) == nil && !nlog.dismissed.contains("contact:" + a)
        let wantOrg = modes.organisation != .off
            && (orgKey.map { profile.org(key: $0) == nil && !nlog.dismissed.contains("org:" + $0) } ?? false)
        guard wantContact || wantOrg else { why("already has voice or dismissed"); return }
        let facts = VoiceLearn.facts(address: a, displayName: who.name, directory: dir, internalDomains: mail.settings.internalDomains,
                                     received: cand.received, sent: cand.sent, mailbox: mb, gate: gate)
        var s = Suggestion(counterpart: a, name: name)
        if wantContact { s.contact = VoiceLearn.suggestedContact(facts) }
        if wantOrg, let k = orgKey {
            s.org = VoiceLearn.suggestedOrg(key: k, displayName: MailDomains.orgName(fromDisplayName: who.name), contacts: [facts])
        }
        guard s.contact != nil || s.org != nil else { why("no facts (received=\(cand.received.count) sent=\(cand.sent.count) dir=\(dir != nil))"); return }
        // ONBOARDING: Automatic layers are saved now (with a toast); Suggest layers stay in the card for approval.
        var p = profile, queue: [VoiceLearnCandidate] = []
        if let k = s.contact { modes.offer(.contact(k), profile: &p, queue: &queue) }
        if let o = s.org { modes.offer(.organisation(o), profile: &p, queue: &queue) }
        if p != profile {
            mail.saveVoice(p)
            mail.toast(MailToast(text: "Voice learnt for \(name) (automatic). Edit it under Settings → AI → Voice.", symbol: "person.wave.2"))
        }
        s.contact = queue.lazy.compactMap { if case .contact(let k) = $0 { k } else { nil } }.first
        s.org = queue.lazy.compactMap { if case .organisation(let o) = $0 { o } else { nil } }.first
        guard s.contact != nil || s.org != nil else { why("saved automatically"); return }
        why("suggestion contact=\(s.contact != nil) org=\(s.org != nil)")
        suggestion = s
        excerpts = (cand.received + cand.sent).filter { !$0.isPrivate }.sorted { $0.received > $1.received }.prefix(8).map { $0 }
        excerptMailbox = mb
    }

    /// Optional AI step: through AIPromptBuilder + the label gate + the routed tier (AIAssistant.suggestVoiceNotes).
    /// Runs on its own only alongside an AI draft the user asked for; otherwise from the card's button.
    func refineWithAI(mail: MailModel) {
        guard let s = suggestion, !s.aiBusy, !s.aiDone, let a = mail.ai.assistant, a.route(.draftReply) != nil else { return }
        let who = s.counterpart, msgs = excerpts, mb = excerptMailbox
        suggestion?.aiBusy = true; suggestion?.aiNote = nil
        Task { @MainActor [weak self] in
            var full = msgs
            if let p = a.route(.draftReply), let sync = mail.sync {
                full = []
                for m in msgs {
                    if m.body == nil, a.gate.exposure(m, mailbox: mb, tier: p.tier) == .content, let b = try? await sync.fetchBody(id: m.id) {
                        full.append(b)
                    } else { full.append(m) }
                }
            }
            var contactAI: [String: String] = [:], orgAI: [String: String] = [:], note: String?
            do {
                if s.contact != nil { contactAI = try await a.suggestVoiceNotes(organisation: false, title: s.name, messages: full, mailbox: mb) }
                if let o = s.org { orgAI = try await a.suggestVoiceNotes(organisation: true, title: o.title, messages: full, mailbox: mb) }
            } catch AIAssistError.notAllowed(let why) { note = why } catch { note = "AI couldn't add notes this time." }
            guard let self, self.suggestion?.counterpart == who else { return }   // composer moved on: drop late results
            if let c = self.suggestion?.contact {
                self.suggestion?.contact?.notes = VoiceLearn.merge(notes: c.notes, ai: contactAI, fields: VoiceLearn.contactFields)
            }
            if let o = self.suggestion?.org {
                self.suggestion?.org?.notes = VoiceLearn.merge(notes: o.notes, ai: orgAI, fields: VoiceLearn.orgFields)
            }
            self.suggestion?.aiBusy = false; self.suggestion?.aiDone = true
            self.suggestion?.aiNote = note ?? (contactAI.isEmpty && orgAI.isEmpty ? "AI found nothing to add." : "Notes refined by AI from mail it may see.")
        }
    }

    func saveSuggestion(mail: MailModel) {
        guard let s = suggestion else { return }
        var p = mail.voiceProfile
        if var o = s.org { o.updated = .now; p.upsert(o) }
        if var c = s.contact { c.updated = .now; p.upsert(c) }
        mail.saveVoice(p)
        suggestion = nil
        mail.toast(MailToast(text: "Voice saved for \(s.name)", symbol: "person.wave.2"))
    }

    func editSuggestion() {
        guard let s = suggestion else { return }
        let m = VoiceEditorModel.shared
        if let c = s.contact { m.begin(contact: c) } else if let o = s.org { m.begin(org: o) }
        m.originalKey = nil
        // Editing the contact: the organisation half stays in the card for its own Save / Dismiss.
        if s.contact != nil, s.org != nil { suggestion?.contact = nil } else { suggestion = nil }
        m.showComposerEditor = true
    }

    func dismissSuggestion(mail: MailModel) {
        guard let s = suggestion else { return }
        var l = log(mail)
        if s.contact != nil { l.dismissed.insert("contact:" + s.counterpart) }
        if let o = s.org { l.dismissed.insert("org:" + o.key) }
        save(l, mail)
        suggestion = nil
    }

    // MARK: Nudges

    func mute(_ n: VoiceNudge, mail: MailModel) {
        var l = log(mail); l.muted.insert(n.key); save(l, mail)
        if nudge == n { nudge = nil }
        if toastNudge == n { toastNudge = nil }
    }

    /// Opens Settings → AI → Voice with the change pre-filled (the user saves).
    func update(_ n: VoiceNudge, mail: MailModel) {
        let m = VoiceEditorModel.shared
        let p = mail.voiceProfile
        switch n.target {
        case .me:
            m.tab = .me; m.org = nil; m.contact = nil
            m.meDraft = n.applied(toMe: m.meDraft ?? p.me)
        case .contact(let a, let name):
            m.tab = .contacts
            let existing = p.contact(address: a)
            m.begin(contact: n.applied(to: existing ?? VoiceContact(address: a, displayName: name, notes: "")))
            if existing == nil { m.originalKey = nil }
        }
        if nudge == n { nudge = nil }
        if toastNudge == n { toastNudge = nil }
        mail.settingsTab = .ai
        mail.showSettings = true
    }

    /// AIAssistModel.acceptPreview: a whole-body voice draft sets the baseline; any later AI change re-baselines,
    /// so an AI "Shorten" never reads as the user's edit.
    func accepted(_ c: ComposerState, voiceDraft: Bool, mail: MailModel) {
        let text = VoiceEditDiff.normalise(c.body, signaturePlain: c.editor.signaturePlain)
        if voiceDraft, let who = mail.voiceCounterpart(original: c.original, to: c.to) {
            baselines[c.id] = (text, who.address.lowercased(), who.name.isEmpty ? who.address : who.name)
        } else if baselines[c.id] != nil {
            baselines[c.id]?.text = text
        }
    }

    func undone(_ c: ComposerState) { baselines[c.id] = nil }

    /// After `queueSend` succeeded, once per composer: compare locally, record kinds, maybe one toast.
    func sent(_ c: ComposerState, mail: MailModel) {
        guard let b = baselines.removeValue(forKey: c.id) else { return }
        let modes = self.modes   // ONBOARDING: no nudge (and no edit log) when Me and Contacts are both off
        guard modes.me != .off || modes.contacts != .off else { return }
        let edit = VoiceEditDiff.compare(draft: b.text, sent: VoiceEditDiff.normalise(c.body, signaturePlain: c.editor.signaturePlain))
        guard !edit.kinds.isEmpty else { return }
        var l = log(mail)
        let name = mail.voiceProfile.contact(address: b.address)?.title ?? b.name.split(separator: " ").first.map(String.init) ?? b.name
        let n = VoiceNudges.afterSend(edit, contact: b.address, name: name, log: &l, now: .now,
                                      allowMe: modes.me != .off, allowContact: modes.contacts != .off)
        save(l, mail)
        guard let n else { return }
        if modes[n.target == .me ? .me : .contacts] == .automatic { applyNow(n, mail: mail); return }
        toastNudge = n
        mail.toast(MailToast(text: n.text, symbol: "person.wave.2", action: .voiceNudge))
    }

    /// ONBOARDING: Automatic mode applies a nudge straight away (visible toast; the layer stays editable).
    func applyNow(_ n: VoiceNudge, mail: MailModel) {
        var p = mail.voiceProfile
        switch n.target {
        case .me: p.me = n.applied(toMe: p.me)
        case .contact(let a, let name):
            var k = n.applied(to: p.contact(address: a) ?? VoiceContact(address: a, displayName: name, notes: ""))
            k.updated = .now
            p.upsert(k)
        }
        mail.saveVoice(p)
        let who: String = if case .contact(_, let name) = n.target { name } else { "your own voice" }
        mail.toast(MailToast(text: "Voice updated for \(who) (automatic). Edit it under Settings → AI → Voice.", symbol: "person.wave.2"))
    }

    // MARK: Signature import (Settings → Signatures)

    func importSignature(mail: MailModel) {
        guard !importing else { return }
        guard let store = mail.store, let app = mail.ai.app, !app.trust.hidesContent else {
            importStatus = "Sign in first: niivo needs your Sent Items."; return
        }
        guard app.trust.effectivePolicy.allowOfflineBodies else {
            importStatus = "Your organisation's policy keeps mail bodies off this Mac, so a signature can't be learnt."; return
        }
        guard let sent = try? store.folder(wellKnown: .sentitems, mailbox: "me") else { importStatus = "No Sent Items folder yet."; return }
        let heads = ((try? store.messages(folderId: sent.id, limit: 150)) ?? []).filter { m in
            let p = mail.policy(for: m, mailbox: "me")
            return !m.isPrivate && !m.isDraft && p.allowOfflineDetails && !p.redactDetails && !p.bodyIsProtected
        }
        importing = true; importStatus = "Reading your last \(heads.count) sent mails…"
        Task { @MainActor [weak self] in
            defer { self?.importing = false }
            var samples: [SignatureSample] = [], full: [String: MailMessage] = [:]
            for h in heads {
                var m = h
                if m.body == nil, let sync = mail.sync, let b = try? await sync.fetchBody(id: h.id) { m = b }
                guard let body = m.body, let from = m.from?.address else { continue }
                full[m.id] = m
                samples.append(SignatureSample(id: m.id, from: from, html: m.bodyIsHTML ? body : nil, plain: m.bodyIsHTML ? nil : body,
                                               received: m.received))
            }
            guard let prop = SignatureLearn.propose(samples) else {
                self?.importStatus = "No signature found: no closing block repeats in at least a quarter of your last \(samples.count) sent mails."
                return
            }
            var doc = prop.doc
            var images: [SignatureImage] = []
            if !prop.cids.isEmpty, let ex = full[prop.exemplarId], let fetcher = mail.sync?.attachments {
                let cands = InlineImages.candidates(ex.attachments, html: ex.body ?? "")
                var got: [AttachmentContent] = []
                for a in cands { if let c = try? await fetcher.inlineAttachment(messageId: ex.id, attachmentId: a.id, mailbox: "me") { got.append(c) } }
                let parts = InlineImages.parts(from: got)
                for cid in Set(prop.cids) {
                    guard let part = parts[InlineImages.normalise(cid)] else { continue }
                    let ext = part.contentType.split(separator: "/").last.map(String.init) ?? "png"
                    images.append(SignatureImage(cid: cid, name: "signature-image.\(ext)", contentType: part.contentType, data: part.data))
                }
            }
            let have = Set(images.map(\.cid))
            let missing = Set(prop.cids).subtracting(have).count
            if missing > 0 {   // an image we couldn't load would send as a broken reference: leave it out
                doc.blocks = doc.blocks.map { b in var b = b; b.runs.removeAll { $0.image.map { !have.contains($0.cid) } ?? false }; return b }
            }
            let sig = MailSignature(name: "From sent mail", html: RichHTML.html(doc), images: images)
            SignatureEditorModel.shared.open(sig)
            SignatureEditorModel.shared.importIdentity = prop.identity
            self?.importStatus = "Found in \(prop.support) of \(prop.total) sent mails from \(prop.identity)"
                + (missing > 0 ? " (\(missing) image\(missing == 1 ? "" : "s") couldn't be loaded and were left out)" : "")
                + ". Check it below and save."
        }
    }
}

// MARK: Composer card (VOICE2-HOOK in AIComposerBar)

struct VoiceLearnCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState
    var body: some View {
        let v = VoiceLearnModel.shared
        let mail = app.mail
        // Not a Group: an empty Group has no view, so its .task never ran and no suggestion ever appeared (owner,
        // first draft to a new contact, 2026-11-20). The zero-height spacer keeps a real view to hang .task on.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if let s = v.suggestion {
                card {
                    Text(s.contact != nil ? "New contact — suggested voice notes for \(s.name)" : "New organisation — suggested voice notes for \(s.org?.title ?? "")")
                        .font(.callout.weight(.semibold))
                    if let c = s.contact { Text(c.notes).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let o = s.org {
                        Text("Organisation (\(o.title)): " + o.notes.replacingOccurrences(of: "\n", with: " · "))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let n = s.aiNote { Text(n).font(.caption2).foregroundStyle(.secondary) }
                    HStack(spacing: 8) {
                        NButton("Save") { v.saveSuggestion(mail: mail) }
                        NButton("Edit", kind: .ghost) { v.editSuggestion() }
                        if !s.aiDone, mail.ai.available(.draftReply) {
                            if s.aiBusy { ProgressView().controlSize(.small) }
                            else { NButton("Fill in with AI", kind: .quiet) { v.refineWithAI(mail: mail) }.help("Only mail your labels allow AI to see is used") }
                        }
                        Spacer()
                        NButton("Dismiss", kind: .quiet) { v.dismissSuggestion(mail: mail) }
                    }
                    Text("Facts from your mail history on this Mac; nothing is saved until you choose Save.").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let n = v.nudge {
                card {
                    Text(n.text).font(.callout)
                    HStack(spacing: 8) {
                        NButton("Update voice") { v.update(n, mail: mail) }
                        NButton("Not now", kind: .quiet) { v.nudge = nil }
                        Spacer()
                        NButton("Don't suggest for \(n.target == .me ? "me" : "this contact")", kind: .quiet) { v.mute(n, mail: mail) }
                    }
                }
            }
        }
        .task(id: composer.id) { v.prepare(composer, mail: mail) }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { content() }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(skin.brand ? AnyShapeStyle(skin.soft) : AnyShapeStyle(.quaternary.opacity(0.4)), in: RoundedRectangle(cornerRadius: skin.brand ? 0 : 8))
            .overlay(alignment: .leading) { if skin.brand { Rectangle().fill(skin.ink).frame(width: 3) } }
    }
}

/// Toast buttons for an after-send nudge (VOICE2-HOOK in ToastView).
struct VoiceNudgeToastActions: View {
    @Environment(AppModel.self) private var app
    var toast: MailToast
    var body: some View {
        if let n = VoiceLearnModel.shared.toastNudge {
            Button("Update voice") { app.mail.dismissToast(toast); VoiceLearnModel.shared.update(n, mail: app.mail) }
                .nvButton(app.skin, .primary)
            Button("Don't suggest") { app.mail.dismissToast(toast); VoiceLearnModel.shared.mute(n, mail: app.mail) }
                .help(n.target == .me ? "Stop suggesting changes to your own voice" : "Stop suggesting voice changes for this contact")
        }
    }
}

/// Settings → Signatures (VOICE2-HOOK in SignatureSettingsSections).
struct SignatureImportRow: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let v = VoiceLearnModel.shared
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Import from my sent mail") { v.importSignature(mail: app.mail) }.disabled(v.importing)
                if v.importing { ProgressView().controlSize(.small) }
            }
            Text("Outlook signatures aren't available to apps through Microsoft 365, so niivo learns yours from your sent mail: the block your last 50 sent mails end with (only mail your labels allow on this Mac).")
                .font(.caption).foregroundStyle(.secondary)
            if let s = v.importStatus { Text(s).font(.caption) }
        }
    }
}
