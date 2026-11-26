import SwiftUI
import MailCore

// VOICE: Settings → AI → Voice (Me / Organisations / Contacts), quick "Edit voice for …" popovers, the composer's
// "Voice: Me · Org · Contact" badge with its Why popover. Profile sealed in the MailStore (`ai.voice`).

@MainActor @Observable
final class VoiceStoreBox {
    static let shared = VoiceStoreBox()
    var revision = 0
    @ObservationIgnored var fallback = VoiceProfile()
}

extension MailModel {
    /// Voice layers, sealed in the MailStore; in memory when there's no store.
    var voiceProfile: VoiceProfile {
        _ = VoiceStoreBox.shared.revision
        return store?.voiceProfile() ?? VoiceStoreBox.shared.fallback
    }

    func saveVoice(_ p: VoiceProfile) {
        if let store { try? store.save(voiceProfile: p) } else { VoiceStoreBox.shared.fallback = p }
        VoiceStoreBox.shared.revision += 1
    }

    /// The main counterpart of a reply: first To that isn't one of my addresses, else the original's sender.
    func voiceCounterpart(original: MailMessage?, to: [EmailAddress]) -> EmailAddress? {
        let mine = Set(([me?.address] + settings.identities.map(\.address)).compactMap { $0?.lowercased() })
        if let o = original?.from, !mine.contains(o.address.lowercased()) { return to.first { !mine.contains($0.address.lowercased()) } ?? o }
        return to.first { !mine.contains($0.address.lowercased()) }
            ?? original?.toRecipients.first { !mine.contains($0.address.lowercased()) }
    }
}

/// Editing state (no `@State` under CLT).
@MainActor @Observable
final class VoiceEditorModel {
    static let shared = VoiceEditorModel()
    enum Tab: String, CaseIterable, Identifiable { case me, orgs, contacts; var id: String { rawValue }
        var title: String { switch self { case .me: "Me"; case .orgs: "Organisations"; case .contacts: "Contacts" } } }
    var tab: Tab = .me
    var meDraft: String?
    var org: VoiceOrg?
    var contact: VoiceContact?
    /// Quick editor popovers (reader strip / composer bar).
    var showReaderEditor = false
    var showComposerEditor = false

    /// Key / address of the layer as it was when editing began (nil = new).
    var originalKey: String?

    func begin(org o: VoiceOrg) {
        contact = nil; org = o; originalKey = o.key.isEmpty ? nil : o.key
    }

    func begin(contact c: VoiceContact) {
        org = nil; contact = c; originalKey = c.address.isEmpty ? nil : c.address
    }

    /// Settings → AI → Voice on the Me layer (composer "Edit My Voice…").
    @MainActor func openMe(_ mail: MailModel) {
        tab = .me; org = nil; contact = nil; meDraft = nil
        mail.settingsTab = .ai
        mail.showSettings = true
    }

    func editOrg(key: String, name: String?, in profile: VoiceProfile) {
        begin(org: profile.org(key: key) ?? VoiceOrg(key: key, displayName: name ?? MailDomains.name(fromDomain: key)))
        if profile.org(key: key) == nil { originalKey = nil }
    }

    func editContact(_ a: EmailAddress, in profile: VoiceProfile) {
        let first = a.name.split(separator: " ").first.map(String.init) ?? ""
        begin(contact: profile.contact(address: a.address) ?? VoiceContact(address: a.address, displayName: a.name, addressAs: first))
        if profile.contact(address: a.address) == nil { originalKey = nil }
    }

    /// "Edit voice for …" menu items for one counterpart.
    func items(for a: EmailAddress?, mail: MailModel, open: @escaping () -> Void) -> [NMenuItem] {
        guard let a else { return [] }
        let p = mail.voiceProfile
        let review = VoiceLearnModel.shared.review.contains(a.address.lowercased())   // VOICE2-HOOK: stale layer, subtle
        var out = [NMenuItem(title: "\(review ? "Review voice" : "Edit voice") for \(a.name.isEmpty ? a.address : a.name)", symbol: review ? "clock.arrow.circlepath" : "person") { [weak self] in
            self?.editContact(a, in: p); open()
        }]
        if let k = MailDomains.companyKey(for: a.address) {
            let name = p.org(key: k)?.title ?? MailDomains.orgName(fromDisplayName: a.name) ?? MailDomains.name(fromDomain: k)
            out.append(NMenuItem(title: "Edit voice for \(name)", symbol: "building.2") { [weak self] in
                self?.editOrg(key: k, name: name, in: p); open()
            })
        }
        return out
    }

    func save(_ mail: MailModel) {
        var p = mail.voiceProfile
        if var o = org {
            o.key = o.key.lowercased().trimmingCharacters(in: .whitespaces)
            if let old = originalKey, old != o.key { p.removeOrg(key: old) }   // renamed: no duplicate layer
            o.updated = .now   // VOICE2-HOOK: staleness stamp
            p.upsert(o)
        }
        if var c = contact {
            c.address = c.address.lowercased().trimmingCharacters(in: .whitespaces)
            if let old = originalKey, old != c.address { p.removeContact(address: old) }
            c.updated = .now   // VOICE2-HOOK: staleness stamp
            VoiceLearnModel.shared.review.remove(c.address)
            p.upsert(c)
        }
        mail.saveVoice(p)
        org = nil; contact = nil; originalKey = nil
    }
}

// MARK: Forms

struct VoiceOrgFields: View {
    @Bindable var model: VoiceEditorModel
    var body: some View {
        if model.org != nil {
            let b = Binding<VoiceOrg>(get: { model.org ?? VoiceOrg(key: "") }, set: { model.org = $0 })
            TextField("Domain (organisation key)", text: b.key)
            TextField("Display name", text: b.displayName)
            Picker("Language", selection: b.language) { ForEach(AILanguage.allCases, id: \.self) { Text($0 == .auto ? "Match the thread" : $0.title).tag($0) } }
            Picker("Formality", selection: b.formality) { ForEach(VoiceFormality.allCases) { Text($0.title).tag($0) } }
            VStack(alignment: .leading, spacing: 4) {
                Text("Relationship notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: b.notes).font(.callout).frame(minHeight: 120)
            }
        }
    }
}

struct VoiceContactFields: View {
    @Bindable var model: VoiceEditorModel
    var body: some View {
        if model.contact != nil {
            let b = Binding<VoiceContact>(get: { model.contact ?? VoiceContact(address: "") }, set: { model.contact = $0 })
            TextField("Email address", text: b.address)
            TextField("Name", text: b.displayName)
            TextField("Address them as (e.g. first name, or Frau Muster)", text: b.addressAs)
            Picker("Language", selection: b.language) { ForEach(AILanguage.allCases, id: \.self) { Text($0 == .auto ? "Match the thread" : $0.title).tag($0) } }
            Picker("Formality", selection: b.formality) { ForEach(VoiceFormality.allCases) { Text($0.title).tag($0) } }
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: b.notes).font(.callout).frame(minHeight: 100)
            }
        }
    }
}

// MARK: Settings → AI → Voice

struct VoiceSettingsSections: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail
        let profile = mail.voiceProfile
        let m = VoiceEditorModel.shared
        @Bindable var model = m
        Section("Voice") {
            Picker("Layer", selection: $model.tab) { ForEach(VoiceEditorModel.Tab.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            Text("AI drafts use Me, then the organisation of the person you reply to, then that person. The more specific layer wins. Stored on this Mac, sealed with the mail cache key.")
                .font(.caption).foregroundStyle(.secondary)
        }
        switch m.tab {
        case .me:
            Section("Me: how I write") {
                let draft = Binding<String>(get: { m.meDraft ?? profile.me }, set: { m.meDraft = $0 })
                TextEditor(text: draft).font(.callout).frame(minHeight: 260)
                HStack {
                    Button("Reset to default") { var p = profile; p.resetMe(); mail.saveVoice(p); m.meDraft = nil }
                        .disabled(profile.meIsDefault && m.meDraft == nil)
                    Spacer()
                    Button("Save") { var p = profile; p.me = m.meDraft ?? p.me; mail.saveVoice(p); m.meDraft = nil }
                        .disabled(m.meDraft == nil || m.meDraft == profile.me)
                }
            }
        case .orgs:
            Section("Organisations") {
                if profile.orgs.isEmpty { Text("None yet. Use “Edit voice for …” on a message, or add one here.").foregroundStyle(.secondary) }
                ForEach(profile.orgs) { o in
                    HStack {
                        Image(systemName: "building.2")
                        Text(o.title)
                        Text(o.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit") { m.begin(org: o) }.buttonStyle(.borderless)
                        Button(role: .destructive) { var p = profile; p.removeOrg(key: o.key); mail.saveVoice(p); if m.org?.key == o.key { m.org = nil } } label: {
                            NSymbol("minus.circle", size: 13, label: "Delete")
                        }.buttonStyle(.borderless)
                    }
                }
                Button("Add organisation") { m.begin(org: VoiceOrg(key: "")) }
            }
            if m.org != nil { editorSection(mail, title: "Edit organisation") { VoiceOrgFields(model: m) } }
        case .contacts:
            Section("Contacts") {
                if profile.contacts.isEmpty { Text("None yet. Use “Edit voice for …” on a message, or add one here.").foregroundStyle(.secondary) }
                ForEach(profile.contacts) { c in
                    HStack {
                        Image(systemName: "person")
                        Text(c.title)
                        Text(c.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit") { m.begin(contact: c) }.buttonStyle(.borderless)
                        Button(role: .destructive) { var p = profile; p.removeContact(address: c.address); mail.saveVoice(p); if m.contact?.address == c.address { m.contact = nil } } label: {
                            NSymbol("minus.circle", size: 13, label: "Delete")
                        }.buttonStyle(.borderless)
                    }
                }
                Button("Add contact") { m.begin(contact: VoiceContact(address: "")) }
            }
            if m.contact != nil { editorSection(mail, title: "Edit contact") { VoiceContactFields(model: m) } }
        }
    }

    private func editorSection<C: View>(_ mail: MailModel, title: String, @ViewBuilder _ fields: () -> C) -> some View {
        let m = VoiceEditorModel.shared
        return Section(title) {
            fields()
            HStack {
                Button("Cancel") { m.org = nil; m.contact = nil }
                Spacer()
                Button("Save") { m.save(mail) }.disabled(!Self.valid(m))
            }
        }
    }

    static func valid(_ m: VoiceEditorModel) -> Bool {
        if let o = m.org { return o.key.contains(".") && !o.key.contains("@") && !o.key.contains(" ") }
        if let c = m.contact { return RecipientCheck.parse(c.address).0.count == 1 }
        return false
    }
}

/// Quick editor for one organisation or contact (popover from the reader strip / composer bar).
struct VoiceQuickEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var onClose: () -> Void
    var body: some View {
        let m = VoiceEditorModel.shared
        VStack(alignment: .leading, spacing: 8) {
            if skin.brand { MonoLabel(m.org != nil ? "Organisation voice" : "Contact voice", color: skin.ink, bracket: true) }
            else { Text(m.org != nil ? "Organisation voice" : "Contact voice").font(.headline) }
            Form {
                VoiceOrgFields(model: m)
                VoiceContactFields(model: m)
            }
            .formStyle(.grouped)
            HStack {
                Text("The more specific layer wins: Contact over Organisation over Me.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                NButton("Cancel", kind: .ghost) { m.org = nil; m.contact = nil; onClose() }
                NButton("Save") { m.save(app.mail); onClose() }.disabled(!VoiceSettingsSections.valid(m)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 460, height: 520)
        .background(skin.brand ? AnyShapeStyle(skin.card) : AnyShapeStyle(.clear))
    }
}

/// Reader strip (VOICE-HOOK in AIReaderStrip): "Voice ▾" → Edit voice for <contact> / <org>.
struct VoiceReaderMenu: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var body: some View {
        let m = VoiceEditorModel.shared
        @Bindable var model = m
        let who = app.mail.voiceCounterpart(original: reader.header, to: [])
        let items = m.items(for: who, mail: app.mail) { m.showReaderEditor = true }
        if !items.isEmpty {
            NMenuButton(label: "Voice", symbol: "person.wave.2", items: items)
                .fixedSize()   // never wrap "Voice" onto three lines in a crowded reply bar
                .help("Tell the AI how to write to this person or organisation")
                .background(Color.clear.popover(isPresented: $model.showReaderEditor) {
                    VoiceQuickEditor { m.showReaderEditor = false }
                })
        }
    }
}

/// Composer bar (VOICE-HOOK in AIComposerBar): applied layers + Why, and Edit voice.
struct VoiceComposerBadge: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: ComposerState
    var body: some View {
        let ai = app.mail.ai
        @Bindable var s = ai.composer
        let m = VoiceEditorModel.shared
        @Bindable var model = m
        let who = app.mail.voiceCounterpart(original: composer.original, to: composer.to)
        HStack(spacing: 6) {
            if let v = s.voice {
                Button { s.showWhy.toggle() } label: {
                    Label(v.badge, systemImage: "person.wave.2").lineLimit(1)
                }
                .modifier(AIChipButton(skin: skin, quiet: true))
                .help("Why this draft looks like this")
                .popover(isPresented: $s.showWhy) { VoiceWhyView(lines: s.why, plan: nil) }
            }
            let items = m.items(for: who, mail: app.mail) { m.showComposerEditor = true }
            if !items.isEmpty {
                NMenuButton(label: s.voice == nil ? "Voice" : "Edit voice", symbol: "slider.horizontal.3", items: items)
                    .background(Color.clear.popover(isPresented: $model.showComposerEditor) {
                        VoiceQuickEditor { m.showComposerEditor = false }
                    })
            }
        }
    }
}

/// Content-free: layers, resolved values, which context went in, the signature decision.
struct VoiceWhyView: View {
    @Environment(\.skin) private var skin
    var lines: [String]
    var plan: VoiceSignaturePlan?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if skin.brand { MonoLabel("Why", color: skin.ink, bracket: true) } else { Text("Why").font(.headline) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text("• " + l).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let plan {
                Text("• Signature: " + (plan == .full ? "your configured signature" : plan == .nameOnly ? "sign-off name only (signature off for this draft)" : "left as it is"))
                    .font(.callout)
            }
            Text("No message text is shown here or logged.").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(14).frame(width: 380, alignment: .leading)
        .background(skin.brand ? AnyShapeStyle(skin.card) : AnyShapeStyle(.clear))
    }
}
