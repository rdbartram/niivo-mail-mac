import SwiftUI
import MailCore

/// Signature being edited in Mail Settings (no `@State` under CLT: lives here).
@MainActor @Observable
final class SignatureEditorModel {
    static let shared = SignatureEditorModel()
    var editingId: UUID?
    var name = ""
    var editor = ComposerEditorState()
    var plain = ""
    /// VOICE2-HOOK: set by "Import from my sent mail": the identity the signature was learnt from.
    var importIdentity: String?

    func open(_ s: MailSignature?) {
        importIdentity = nil
        editor = ComposerEditorState()
        editor.onText = { [weak self] t in self?.plain = t }
        editor.liveMarkdown = true
        editingId = s?.id ?? UUID()
        name = s?.name ?? "Signature"
        for i in s?.images ?? [] { editor.inlineImages[i.cid] = OutgoingAttachment(name: i.name, contentType: i.contentType, data: i.data, isInline: true, contentId: i.cid) }
        editor.load(s?.doc ?? RichDoc([RichBlock()]))
        plain = editor.storage.string
    }

    var signature: MailSignature? {
        guard let id = editingId else { return nil }
        let doc = editor.doc
        let used = Set(doc.images.map(\.cid))
        let images = editor.inlineImages.values.filter { $0.contentId.map(used.contains) ?? false }
            .map { SignatureImage(cid: $0.contentId!, name: $0.name, contentType: $0.contentType, data: $0.data) }
        var clean = doc; clean.blocks = clean.blocks.map { var b = $0; b.signature = false; return b }
        return MailSignature(id: id, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Signature" : name, html: RichHTML.html(clean),
                             images: images.sorted { $0.cid < $1.cid })
    }
}

/// Signatures + composer preferences, shown in the Identities pane of Mail Settings.
struct SignatureSettingsSections: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail
        let prefs = mail.composerPrefs
        let model = SignatureEditorModel.shared
        @Bindable var m = model
        Section("Signatures") {
            ForEach(prefs.signatures) { s in
                HStack {
                    NSymbol("signature")
                    Text(s.name)
                    Spacer()
                    Button("Edit") { model.open(s) }.buttonStyle(.borderless)
                    Button(role: .destructive) {
                        var p = prefs; p.remove(s.id); mail.saveComposerPrefs(p)
                        if model.editingId == s.id { model.editingId = nil }
                    } label: { NSymbol("minus.circle", size: 13, label: "Delete") }.buttonStyle(.borderless)
                }
            }
            Button("New Signature") { model.open(nil) }
            SignatureImportRow()   // VOICE2-HOOK: learn from Sent Items
            Text("Signatures are stored on this Mac, sealed with the mail cache key (Graph has no API for Outlook's roaming signatures). Images are sent as inline attachments.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if model.editingId != nil {
            Section("Edit signature") {
                TextField("Name", text: $m.name)
                ComposerFormatBar(editor: model.editor, attachBlocked: nil) {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.allowsMultipleSelection = false
                    if p.runModal() == .OK { model.editor.attach(urls: p.urls, inlineImages: true) }
                }
                MailRichEditor(state: model.editor, selection: nil, plain: model.plain, attachBlockReason: nil, brand: app.theme.brand, minHeight: 120)
                    .id(model.editingId)                    .frame(minHeight: 140)
                    .background(app.theme.brand ? AnyShapeStyle(app.skin.card) : AnyShapeStyle(.quaternary.opacity(0.25)), in: app.skin.rounded)
                if let n = model.editor.notice { Text(n).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Cancel") { model.editingId = nil }
                    Spacer()
                    Button("Save Signature") {
                        guard let s = model.signature else { return }
                        var p = prefs
                        if let i = p.signatures.firstIndex(where: { $0.id == s.id }) { p.signatures[i] = s } else { p.signatures.append(s) }
                        if p.signatures.count == 1, p.newMailDefaults.isEmpty, p.replyDefaults.isEmpty {
                            p.newMailDefaults[ComposerPreferences.anyIdentity] = s.id
                            p.replyDefaults[ComposerPreferences.anyIdentity] = s.id
                        }
                        if let who = model.importIdentity?.lowercased() {   // VOICE2-HOOK: imported → default for that identity if none
                            if p.newMailDefaults[who] == nil { p.newMailDefaults[who] = s.id }
                            if p.replyDefaults[who] == nil { p.replyDefaults[who] = s.id }
                            model.importIdentity = nil
                        }
                        mail.saveComposerPrefs(p)
                        model.editingId = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        if !prefs.signatures.isEmpty {
            Section("Default signature") {
                defaultRow("Any identity", key: ComposerPreferences.anyIdentity, prefs: prefs)
                ForEach(mail.settings.identities, id: \.self) { i in defaultRow(ComposerFromRow.describe(i), key: i.address.lowercased(), prefs: prefs) }
                Text("Inserted above the quoted history on replies and forwards. Switching From swaps a default signature.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        TemplateSettingsSections()   // COMPOSE-HOOK (TemplateSettings.swift)
        Section("Replying") {   // COMPOSE2
            Toggle("Default reply is Reply All (R, ⌘R and the toolbar Reply)", isOn: Binding(get: { prefs.defaultReplyAll },
                                                        set: { v in var p = prefs; p.defaultReplyAll = v; mail.saveComposerPrefs(p) }))
            Picker("Replies include", selection: Binding(get: { prefs.replyHistory },
                                                         set: { v in var p = prefs; p.replyHistory = v; mail.saveComposerPrefs(p) })) {
                Text("The original message (below your text)").tag(ComposerPreferences.ReplyHistory.include)
                Text("Only your text").tag(ComposerPreferences.ReplyHistory.omit)
            }
            Text("Explicit Reply / Reply All menu items do what they say; if Reply All isn't allowed for a message, the default falls back to Reply. Forwards always include the message. The history Exchange quotes is sent exactly as it is, never re-formatted.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Writing") {
            Toggle("Live Markdown (**bold**, *italic*, `code`, lists, quotes, headings as you type; Markdown paste converts)",
                   isOn: Binding(get: { prefs.liveMarkdown }, set: { v in var p = prefs; p.liveMarkdown = v; mail.saveComposerPrefs(p) }))
        }
    }

    private func defaultRow(_ title: String, key: String, prefs: ComposerPreferences) -> some View {
        let mail = app.mail
        let any = key == ComposerPreferences.anyIdentity
        // COMPOSE2: an identity can say "None" even when the any-identity default has a signature.
        let opts: [UUID?] = [nil] + (any ? [] : [ComposerPreferences.noSignature]) + prefs.signatures.map(\.id)
        func label(_ id: UUID?) -> String {
            if id == ComposerPreferences.noSignature { return "None" }
            return id.flatMap { prefs.signature(id: $0)?.name } ?? (any ? "None" : "Same as any identity")
        }
        return HStack {
            Text(title).lineLimit(1)
            Spacer()
            Picker("New", selection: Binding(get: { prefs.newMailDefaults[key] }, set: { v in var p = prefs; p.newMailDefaults[key] = v; mail.saveComposerPrefs(p) })) {
                ForEach(opts, id: \.self) { Text(label($0)).tag($0) }
            }.fixedSize()
            Picker("Reply", selection: Binding(get: { prefs.replyDefaults[key] }, set: { v in var p = prefs; p.replyDefaults[key] = v; mail.saveComposerPrefs(p) })) {
                ForEach(opts, id: \.self) { Text(label($0)).tag($0) }
            }.fixedSize()
        }
    }
}
