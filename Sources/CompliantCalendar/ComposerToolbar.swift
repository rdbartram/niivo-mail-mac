import AppKit
import SwiftUI
import MailCore

/// Formatting bar above the editor: inline styles, size, colour, highlight, lists, quote, link, alignment, clear.
struct ComposerFormatBar: View {
    @Environment(AppModel.self) private var app
    var editor: ComposerEditorState
    var attachBlocked: String?
    var onAttach: () -> Void
    /// OneDrive picker (DrivePicker.swift); nil hides the button.
    var onCloud: (() -> Void)? = nil
    /// COMPOSE-LAYOUT: the floating / pinned mini-bar — styles only (attach lives in the footer, Markdown in ⋯).
    var formattingOnly = false

    static let colours: [(String, String)] = [("Red", "#C00000"), ("Orange", "#E36C09"), ("Green", "#2E7D32"), ("Blue", "#1F5FBF"),
                                              ("Purple", "#7030A0"), ("Teal", "#00838F")]
    static let highlights: [(String, String)] = [("Yellow", "#FFF59D"), ("Green", "#C8E6C9"), ("Blue", "#BBDEFB"), ("Pink", "#F8BBD0"),
                                                 ("Orange", "#FFE0B2")]

    var body: some View {
        @Bindable var e = editor
        let s = editor.active, b = editor.activeBlock
        HStack(spacing: 2) {
            tool("bold", on: s.bold, help: "Bold (⌘B)") { editor.toggle(.nvBold) }
            tool("italic", on: s.italic, help: "Italic (⌘I)") { editor.toggle(.nvItalic) }
            tool("underline", on: s.underline, help: "Underline (⌘U)") { editor.toggle(.nvUnderline) }
            tool("strikethrough", on: s.strike, help: "Strikethrough (⇧⌘X)") { editor.toggle(.nvStrike) }
            tool("chevron.left.forwardslash.chevron.right", on: s.code, help: "Inline code") { editor.toggle(.nvCode) }
            sep
            menu("textformat.size", help: "Font size", items: [
                NMenuItem(title: "Small", checked: s.size == .small) { editor.setInline(.nvSize, RichSize.small.rawValue) },
                NMenuItem(title: "Normal", checked: s.size == nil) { editor.setInline(.nvSize, nil) },
                NMenuItem(title: "Large", checked: s.size == .large) { editor.setInline(.nvSize, RichSize.large.rawValue) },
                NMenuItem(title: "Heading 1", checked: b.kind == .heading1) { editor.setBlock(.heading1) },
                NMenuItem(title: "Heading 2", checked: b.kind == .heading2) { editor.setBlock(.heading2) },
                NMenuItem(title: "Heading 3", checked: b.kind == .heading3) { editor.setBlock(.heading3) },
            ])
            menu("paintbrush", help: "Text colour", items: [NMenuItem(title: "Automatic", checked: s.color == nil) { editor.setInline(.nvColor, nil) }]
                 + Self.colours.map { c in NMenuItem(title: c.0, checked: s.color == c.1) { editor.setInline(.nvColor, c.1) } })
            menu("highlighter", help: "Highlight", items: [NMenuItem(title: "None", checked: s.highlight == nil) { editor.setInline(.nvHighlight, nil) }]
                 + Self.highlights.map { c in NMenuItem(title: c.0, checked: s.highlight == c.1) { editor.setInline(.nvHighlight, c.1) } })
            sep
            tool("list.bullet", on: b.kind == .bullet, help: "Bulleted list (⇧⌘8) — Tab / ⇧Tab to indent") { editor.setBlock(.bullet) }
            tool("list.number", on: b.kind == .number, help: "Numbered list (⇧⌘7)") { editor.setBlock(.number) }
            tool("decrease.indent", on: false, help: "Outdent (⇧Tab)") { editor.indent(-1) }.disabled(!b.kind.isList)
            tool("increase.indent", on: false, help: "Indent (Tab)") { editor.indent(1) }.disabled(!b.kind.isList)
            tool("text.quote", on: b.kind == .quote, help: "Quote") { editor.setBlock(.quote) }
            tool("curlybraces", on: b.kind == .code, help: "Code block") { editor.setBlock(.code) }
            tool("link", on: s.link != nil, help: "Insert or edit link (⌘K)") { editor.beginLink() }
                .popover(isPresented: $e.showLink, arrowEdge: .bottom) { LinkEditor(editor: editor) }
            menu(alignSymbol(b.align), help: "Alignment", items: [
                NMenuItem(title: "Left", checked: b.align == .left) { editor.setBlock(align: .left, toggle: false) },
                NMenuItem(title: "Centre", checked: b.align == .center) { editor.setBlock(align: .center, toggle: false) },
                NMenuItem(title: "Right", checked: b.align == .right) { editor.setBlock(align: .right, toggle: false) },
                NMenuItem(title: "Justify", checked: b.align == .justify) { editor.setBlock(align: .justify, toggle: false) },
            ])
            tool("textformat", on: false, help: "Clear formatting") { editor.clearFormatting() }
            if !formattingOnly {
                sep
                tool("paperclip", on: false, help: attachBlocked ?? "Attach files (or drop / paste them)") { onAttach() }
                    .disabled(attachBlocked != nil)
                if let onCloud {
                    tool("icloud", on: false, help: attachBlocked ?? "Attach from OneDrive (share a link or attach a copy)") { onCloud() }
                        .disabled(attachBlocked != nil)
                }
                Spacer()
                Toggle(isOn: $e.liveMarkdown) { Text("Markdown").font(.caption) }
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("Live Markdown: **bold**, *italic*, `code`, - lists, 1. lists, > quote, # headings convert as you type")
            }
        }
        .controlSize(.small)
    }

    private var sep: some View { Divider().frame(height: 14).padding(.horizontal, 3) }

    private func alignSymbol(_ a: RichAlign) -> String {
        switch a { case .left: "text.alignleft"; case .center: "text.aligncenter"; case .right: "text.alignright"; case .justify: "text.justify" }
    }

    private func tool(_ symbol: String, on: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NSymbol(symbol).frame(width: 22, height: 20)
                .background {
                    if on {
                        if app.theme.brand { Rectangle().fill(app.skin.soft).overlay(Rectangle().strokeBorder(app.skin.hair2, lineWidth: 1)) }
                        else { RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18)) }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func menu(_ symbol: String, help: String, items: [NMenuItem]) -> some View {
        Menu {
            ForEach(items) { i in Button { i.action() } label: { if i.checked { Label(i.title, systemImage: "checkmark") } else { Text(i.title) } } }
        } label: { NSymbol(symbol) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26).help(help)
    }
}

struct LinkEditor: View {
    var editor: ComposerEditorState
    var body: some View {
        @Bindable var e = editor
        VStack(alignment: .leading, spacing: 8) {
            TextField("Text", text: $e.linkText).frame(width: 280)
            TextField("Address (https://…, mailto:…)", text: $e.linkURL).frame(width: 280)
                .onSubmit { e.notice = e.commitLink() }
            if let n = e.notice, e.showLink { Text(n).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Remove link") { editor.removeLink() }.disabled(e.linkURL.isEmpty)
                Spacer()
                Button("Cancel") { e.showLink = false }.keyboardShortcut(.cancelAction)
                Button("Apply") { e.notice = e.commitLink() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

/// Attachment chips: name, size, upload progress, remove.
struct ComposerAttachmentChips: View {
    @Environment(AppModel.self) private var app
    var editor: ComposerEditorState
    var body: some View {
        if !editor.attachments.isEmpty || editor.notice != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !editor.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { ForEach(editor.attachments) { a in chip(a) } }
                    }
                    let total = editor.attachments.reduce(0) { $0 + $1.size }
                    if total > 25 * 1024 * 1024 {
                        NLabel("\(AttachmentUpload.formattedSize(total)) in total — your organisation's message size limit (often 35 MB) may refuse it.",
                               systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                if let n = editor.notice, !editor.showLink {
                    HStack { NLabel(n, systemImage: "lock.trianglebadge.exclamationmark").font(.caption).foregroundStyle(.orange)
                        Button { editor.notice = nil } label: { NSymbol("xmark").font(.caption2) }.buttonStyle(.borderless) }
                }
            }
        }
    }

    private func chip(_ a: OutgoingAttachment) -> some View {
        HStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(for: .init(mimeType: a.contentType) ?? .data)).resizable().frame(width: 16, height: 16)
            Text(a.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
            Text(AttachmentUpload.formattedSize(a.size)).foregroundStyle(.secondary)
            if let p = editor.progress[a.id], p < 1 { ProgressView(value: p).frame(width: 40).controlSize(.mini) }
            Button { editor.remove(a.id) } label: { NSymbol("xmark").font(.caption2) }.buttonStyle(.borderless).help("Remove")
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background {
            if app.theme.brand { Rectangle().fill(app.skin.soft).overlay(Rectangle().strokeBorder(app.skin.hair2, lineWidth: 1)) }
            else { Capsule().fill(Color.accentColor.opacity(0.12)) }
        }
        .help("\(a.name) — \(AttachmentUpload.isSmall(a) ? "sent with the draft" : "uploaded in chunks (upload session)")")
    }
}

/// Signature switcher in the composer.
struct ComposerSignaturePicker: View {
    @Environment(AppModel.self) private var app
    var composer: ComposerState
    var body: some View {
        let prefs = app.mail.composerPrefs
        let e = composer.editor
        if !prefs.signatures.isEmpty {
            NMenuButton(label: prefs.signature(id: e.signatureId)?.name ?? "No signature", symbol: "signature",
                        items: [NMenuItem(title: "No signature", checked: e.signatureId == nil) { e.applySignature(nil, byUser: true) }]
                        + prefs.signatures.map { s in NMenuItem(title: s.name, checked: e.signatureId == s.id) { e.applySignature(s, byUser: true) } })
            .help("Signature (goes above the quoted history)")
        }
    }
}

// MARK: - Wiring

extension MailModel {
    /// Composer preferences (signatures, live Markdown), sealed in the MailStore; in memory when there's no store.
    var composerPrefs: ComposerPreferences {
        _ = ComposerPrefsBox.shared.revision   // observe changes
        return store?.composerPreferences() ?? ComposerPrefsBox.shared.fallback
    }

    func saveComposerPrefs(_ p: ComposerPreferences) {
        if let store { try? store.save(composerPreferences: p) } else { ComposerPrefsBox.shared.fallback = p }
        ComposerPrefsBox.shared.revision += 1
    }

    /// New composer: live-Markdown setting, the identity's default signature (not for reopened drafts).
    func prepareEditor(_ c: ComposerState) {
        let e = c.editor
        guard e.preparedFor != c.id else { return }
        e.preparedFor = c.id
        wireTemplates(c)   // COMPOSE-HOOK: ;shortcut expansion
        let prefs = composerPrefs
        e.liveMarkdown = prefs.liveMarkdown
        guard c.savedDraftId == nil else { return }
        let reply = c.kind != .new
        if let sig = prefs.defaultSignature(identity: c.from?.address, reply: reply) { e.applySignature(sig, byUser: false) }
        e.textView?.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Attachment gate for a composer: its label merged with the original's (AttachmentGate).
    func attachGateReason(_ c: ComposerState) -> String? {
        var p = labelPolicy(labelId: c.labelId)
        if let o = c.original { p = p.merged(with: policy(for: o, mailbox: store?.mailbox(forFolder: o.folderId) ?? "me")) }
        return AttachmentGate.blockReason(p)
    }

    /// From changed: swap a default signature for the new identity's default.
    func identityChanged(_ c: ComposerState) {
        let e = c.editor
        guard e.signatureIsDefault else { return }
        let sig = composerPrefs.defaultSignature(identity: c.from?.address, reply: c.kind != .new)
        if sig?.id != e.signatureId { e.applySignature(sig, byUser: false) }
    }
}

@MainActor @Observable
final class ComposerPrefsBox {
    static let shared = ComposerPrefsBox()
    var revision = 0
    @ObservationIgnored var fallback = ComposerPreferences()
}

extension ComposerState {
    /// Attach via the open panel.
    func pickAttachments() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.canChooseFiles = true
        p.prompt = "Attach"
        if p.runModal() == .OK { editor.attach(urls: p.urls, inlineImages: false) }
    }
}
