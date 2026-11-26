import SwiftUI
import MailCore

/// Template being edited in Mail Settings (no `@State` under CLT: lives here).
@MainActor @Observable
final class TemplateEditorModel {
    static let shared = TemplateEditorModel()
    var editingId: UUID?
    var name = ""
    var shortcut = ""
    var editor = ComposerEditorState()
    var plain = ""

    func open(_ t: MailTemplate?) {
        editor = ComposerEditorState()
        editor.onText = { [weak self] s in self?.plain = s }
        editor.liveMarkdown = true
        editingId = t?.id ?? UUID()
        name = t?.name ?? "Template"
        shortcut = t?.shortcut ?? ""
        editor.load(t?.doc ?? RichDoc([RichBlock()]))
        plain = editor.storage.string
    }

    var template: MailTemplate? {
        guard let id = editingId else { return nil }
        let n = name.trimmingCharacters(in: .whitespaces)
        return MailTemplate(id: id, name: n.isEmpty ? "Template" : n, shortcut: shortcut, html: RichHTML.html(editor.doc))
    }
}

/// Templates / snippets, shown under the signatures in Mail Settings.
struct TemplateSettingsSections: View {
    @Environment(AppModel.self) private var app
    static let noAttachments = "Templates can't hold attachments"
    var body: some View {
        let mail = app.mail
        let lib = mail.templateLibrary
        let model = TemplateEditorModel.shared
        @Bindable var m = model
        Section("Templates") {
            ForEach(lib.templates) { t in
                HStack {
                    NSymbol("text.badge.plus")
                    Text(t.name)
                    if !t.shortcut.isEmpty { Text(";" + t.shortcut).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Edit") { model.open(t) }.buttonStyle(.borderless)
                    Button(role: .destructive) {
                        var l = lib; l.templates.removeAll { $0.id == t.id }; mail.saveTemplates(l)
                        if model.editingId == t.id { model.editingId = nil }
                    } label: { NSymbol("minus.circle", size: 13, label: "Delete") }.buttonStyle(.borderless)
                }
            }
            Button("New Template") { model.open(nil) }
            Text("In a message, type ;shortcut then Space or Tab, or use Templates under the editor. Variables: {{firstName}} {{lastName}} {{fullName}} {{myName}} {{date}} {{subject}} — filled from the first recipient and the draft. Stored on this Mac, sealed with the mail cache key.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if model.editingId != nil {
            Section("Edit template") {
                TextField("Name", text: $m.name)
                TextField("Shortcut (letters, digits, - and _)", text: $m.shortcut)
                if !m.shortcut.isEmpty, TemplateShortcut.normalise(m.shortcut) == nil {
                    Text("Use letters, digits, - or _ only (up to 32).").font(.caption).foregroundStyle(.red)
                } else if let s = TemplateShortcut.normalise(m.shortcut), lib.templates.contains(where: { $0.shortcut == s && $0.id != model.editingId }) {
                    Text("Another template already uses ;\(s).").font(.caption).foregroundStyle(.orange)
                }
                ComposerFormatBar(editor: model.editor, attachBlocked: Self.noAttachments, onAttach: {})
                MailRichEditor(state: model.editor, selection: nil, plain: model.plain, attachBlockReason: Self.noAttachments,
                               brand: app.theme.brand, minHeight: 120)
                    .id(model.editingId).frame(minHeight: 140)
                    .background(app.theme.brand ? AnyShapeStyle(app.skin.card) : AnyShapeStyle(.quaternary.opacity(0.25)), in: app.skin.rounded)
                HStack {
                    Button("Cancel") { model.editingId = nil }
                    Spacer()
                    Button("Save Template") {
                        guard let t = model.template else { return }
                        var l = lib
                        if let i = l.templates.firstIndex(where: { $0.id == t.id }) { l.templates[i] = t } else { l.templates.append(t) }
                        mail.saveTemplates(l)
                        model.editingId = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!m.shortcut.isEmpty && TemplateShortcut.normalise(m.shortcut) == nil)
                }
            }
        }
    }
}
