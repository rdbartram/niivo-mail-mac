import AppKit
import SwiftUI
import MailCore

// COMPOSE-HOOK (2/2): reopened-draft chips, reply with attachments, templates, spell-check language, table / rule.

// MARK: - Extras under the editor

/// Server-side attachments of a reopened draft and its OneDrive link chips (restored from the body).
struct ComposerExtrasRow: View {
    @Environment(AppModel.self) private var app
    var composer: ComposerState
    var body: some View {
        let e = composer.editor
        let restored = e.restoredLinks.filter { r in !e.cloud.contains { $0.link.url == r.url } && e.linkInBody(r.url) }
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(height: 0)   // keeps the view (and its .task) alive when there is nothing to show
            if !e.serverAttachments.isEmpty || !restored.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(e.serverAttachments) { a in serverChip(a) }
                        ForEach(restored) { r in linkChip(r) }
                    }
                }
            }
        }
        .task(id: composer.body) {   // spell-check language: detected 1.2 s after typing stops
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            e.detectLanguage()
        }
    }

    @ViewBuilder private var chipBackground: some View {
        if app.theme.brand { Rectangle().fill(app.skin.soft).overlay(Rectangle().strokeBorder(app.skin.hair2, lineWidth: 1)) }
        else { Capsule().fill(Color.accentColor.opacity(0.12)) }
    }

    private func serverChip(_ a: DraftServerAttachment) -> some View {
        HStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(for: .init(mimeType: a.contentType) ?? .data)).resizable().frame(width: 16, height: 16)
            Text(a.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
            if a.size > 0 { Text(AttachmentUpload.formattedSize(a.size)).foregroundStyle(.secondary) }
            Button { app.mail.removeServerAttachment(a, from: composer) } label: { NSymbol("xmark").font(.caption2) }
                .buttonStyle(.borderless).help("Remove from the draft")
        }
        .font(.callout).padding(.horizontal, 8).padding(.vertical, 3).background { chipBackground }
        .help("\(a.name) — already on the saved draft (not uploaded again)")
    }

    private func linkChip(_ r: CloudChipRef) -> some View {
        HStack(spacing: 5) {
            NSymbol("link")
            Text(r.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)
            Text(r.type == .edit ? "Can edit" : "Can view").foregroundStyle(.secondary)
            Button { composer.editor.removeCloudLink(SharingLink(url: r.url, type: r.type, scope: .organization)) } label: { NSymbol("xmark").font(.caption2) }
                .buttonStyle(.borderless).help("Remove link")
        }
        .font(.callout).padding(.horizontal, 8).padding(.vertical, 3).background { chipBackground }
        .help("OneDrive link from the saved draft. Its sharing scope was set when it was shared; share the file again to change it.")
    }
}

/// Spelling language (per draft), Insert (table / line) and Templates, next to the signature picker.
struct ComposerLanguageAndTemplates: View {
    @Environment(AppModel.self) private var app
    var composer: ComposerState
    var body: some View {
        let e = composer.editor
        let lib = app.mail.templateLibrary
        HStack(spacing: 8) {
            NMenuButton(label: "Insert", symbol: "tablecells", items: [
                NMenuItem(title: "Table 2 × 2") { e.insertTable(rows: 2, columns: 2) },
                NMenuItem(title: "Table 3 × 3") { e.insertTable(rows: 3, columns: 3) },
                NMenuItem(title: "Table 4 × 3") { e.insertTable(rows: 4, columns: 3) },
                NMenuItem(title: "Table 5 × 4") { e.insertTable(rows: 5, columns: 4) },
                NMenuItem(title: "Horizontal Line") { e.insertRule() },
            ])
            .help("Insert a simple table (Tab moves between cells) or a horizontal line")
            if !lib.templates.isEmpty {
                NMenuButton(label: "Templates", symbol: "text.badge.plus", items: lib.templates.map { t in
                    NMenuItem(title: t.name, hint: t.shortcut.isEmpty ? nil : ";" + t.shortcut) { app.mail.insertTemplate(t, in: composer) }
                })
                .help("Insert a template (or type ;shortcut then Space)")
            }
            NMenuButton(label: e.spellChoice?.title ?? ("Auto" + (e.detectedLanguage.map { " · \($0.title)" } ?? "")),
                        symbol: "textformat.abc",
                        items: [NMenuItem(title: "Detect Automatically", checked: e.spellChoice == nil) { e.spellChoice = nil; e.applySpellLanguage() }]
                        + DraftLanguage.allCases.map { l in NMenuItem(title: l.title, checked: e.spellChoice == l) { e.spellChoice = l; e.applySpellLanguage() } })
                .help("Spelling language for this message")
        }
    }
}

// MARK: - Editor additions

extension ComposerEditorState {
    func linkInBody(_ url: String) -> Bool {
        var found = false
        storage.enumerateAttribute(.nvLink, in: NSRange(location: 0, length: storage.length)) { v, _, stop in
            if v as? String == url { found = true; stop.pointee = true }
        }
        return found
    }

    /// Insertion point for a new block: the cursor's paragraph if it's empty, else a fresh paragraph after it.
    private func blockInsertionPoint() -> NSRange {
        let ns = storage.string as NSString
        let pr = paragraphRange(selection)
        let text = ns.substring(with: pr)
        guard !text.trimmingCharacters(in: .newlines).isEmpty else { return NSRange(location: pr.location, length: 0) }
        let end = NSMaxRange(pr) - (text.hasSuffix("\n") ? 1 : 0)
        insert(RichDoc([RichBlock(), RichBlock()]), at: NSRange(location: end, length: 0))
        return NSRange(location: end + 1, length: 0)
    }

    /// Simple grid (rows of tab-separated cells), followed by an empty paragraph to keep writing in.
    func insertTable(rows: Int, columns: Int) {
        let r = max(1, min(rows, 20)), c = max(1, min(columns, 8))
        let row = RichBlock(.table, runs: c > 1 ? [RichRun(String(repeating: "\t", count: c - 1))] : [])
        let at = blockInsertionPoint()
        insert(RichDoc(Array(repeating: row, count: r) + [RichBlock()]), at: at)
        textView?.setSelectedRange(NSRange(location: at.location, length: 0))
        refreshActive()
    }

    func insertRule() {
        let at = blockInsertionPoint()
        insert(RichDoc([RichBlock(.rule), RichBlock()]), at: at)
        refreshActive()
    }

    /// Plain text of the user's content (no signature), for language detection.
    var userText: String { doc.blocks.filter { !$0.signature }.map(\.text).joined(separator: "\n") }

    func detectLanguage() {
        guard let d = DraftLanguage.detect(userText), d != detectedLanguage else { return }
        detectedLanguage = d
        if spellChoice == nil { applySpellLanguage() }
    }

    var effectiveLanguage: DraftLanguage? { spellChoice ?? detectedLanguage }

    /// NSSpellChecker's language is app-wide: set while this editor has focus (ComposerTextView), back to automatic
    /// when it loses focus.
    func applySpellLanguage() {
        guard let tv = textView, tv.window?.firstResponder === tv else { return }
        Self.setSpellLanguage(effectiveLanguage)
        tv.isContinuousSpellCheckingEnabled = false
        tv.isContinuousSpellCheckingEnabled = true   // re-check with the new language
    }

    static func setSpellLanguage(_ l: DraftLanguage?) {
        let sc = NSSpellChecker.shared
        guard let l, let code = l.spellCodes.first(where: { sc.availableLanguages.contains($0) }) else {
            sc.automaticallyIdentifiesLanguages = true
            return
        }
        sc.automaticallyIdentifiesLanguages = false
        _ = sc.setLanguage(code)
    }

    /// `;shortcut` right before the cursor (after the delimiter the user just typed, `delimiterLength` UTF-16 units)
    /// → the template, variables filled. true = expanded.
    func expandTemplateTrigger(cursor: Int, delimiterLength: Int) -> Bool {
        guard let lookup = templateLookup else { return false }
        let ns = storage.string as NSString
        let end = cursor - delimiterLength
        guard end > 0, end <= ns.length else { return false }
        let pr = ns.paragraphRange(for: NSRange(location: end - 1, length: 0))
        guard end >= pr.location else { return false }
        let before = ns.substring(with: NSRange(location: pr.location, length: end - pr.location))
        guard let t = TemplateShortcut.trigger(before), let doc = lookup(t.shortcut) else { return false }
        insert(doc, at: NSRange(location: end - t.utf16Length, length: t.utf16Length + delimiterLength))
        return true
    }
}

// MARK: - Model wiring

@MainActor @Observable
final class TemplatesBox {
    static let shared = TemplatesBox()
    var revision = 0
    @ObservationIgnored var fallback = TemplateLibrary()
}

extension MailModel {
    var templateLibrary: TemplateLibrary {
        _ = TemplatesBox.shared.revision
        return store?.templateLibrary() ?? TemplatesBox.shared.fallback
    }

    func saveTemplates(_ l: TemplateLibrary) {
        if let store { try? store.save(templateLibrary: l) } else { TemplatesBox.shared.fallback = l }
        TemplatesBox.shared.revision += 1
    }

    func templateDoc(_ t: MailTemplate, for c: ComposerState) -> RichDoc {
        TemplateExpander.expand(t.doc, values: TemplateVariables.values(recipient: c.to.first ?? c.cc.first,
                                                                        me: c.from?.emailAddress ?? me, subject: c.subject))
    }

    func insertTemplate(_ t: MailTemplate, in c: ComposerState) {
        c.editor.insert(templateDoc(t, for: c), at: c.editor.selection)
    }

    /// Per composer: `;shortcut` expansion looks templates up at the time of typing.
    func wireTemplates(_ c: ComposerState) {
        c.editor.templateLookup = { [weak self, weak c] shortcut in
            guard let self, let c, let t = self.templateLibrary.template(shortcut: shortcut) else { return nil }
            return self.templateDoc(t, for: c)
        }
    }

    /// Fixtures: canned people and MailTips (never the network).
    func configureComposeFixtures() { ComposeHub.shared.configure(service: FixtureComposeService()) }

    /// Live: mail token for MailTips / attachments, the optional directory consent for people + users, the optional
    /// Groups consent for groups. A source without consent is simply empty.
    func configureComposeLive(auth: Auth) {
        ComposeHub.shared.configure(service: GraphComposeService(
            mailToken: { try await auth.mailToken() }, directoryToken: { try await auth.directoryToken() },
            groupToken: { try await auth.groupToken(write: false) }))
    }

    /// Reopened draft: its attachments stay on the server and show as chips (never downloaded or re-uploaded; a
    /// PATCH save leaves them alone).
    func loadDraftExtras(_ c: ComposerState, id: String, mailbox: String) {
        guard let svc = ComposeHub.shared.service else { return }
        Task { @MainActor [weak c] in
            guard let list = try? await svc.attachments(messageId: id, mailbox: mailbox), let c else { return }
            c.editor.serverAttachments = list.filter { !$0.isInline }
        }
    }

    func removeServerAttachment(_ a: DraftServerAttachment, from c: ComposerState) {
        c.editor.serverAttachments.removeAll { $0.id == a.id }
        guard let draft = c.savedDraftId, let svc = ComposeHub.shared.service else { return }
        let mb = c.from.map { $0.mode == .selfSend ? "me" : $0.mailbox } ?? "me"
        Task { @MainActor in
            do { try await svc.deleteAttachment(messageId: draft, attachmentId: a.id, mailbox: mb) }
            catch { c.editor.serverAttachments.append(a); c.error = "Couldn't remove \(a.name) from the draft." }
        }
    }

    /// Reply (or reply all) and copy the original's file attachments into the draft: list them, GET each file's
    /// bytes, add them as attachments (they upload with the draft like any other, through the same label gate).
    /// Needs the forward right too: the files reach the reply's recipients.
    func replyWithAttachments(_ kind: MailDraft.Kind = .reply, to messageId: String? = nil) {
        guard let store, let id = messageId ?? selectedMessageId, let o = try? store.message(id: id, includeBody: false) else { return }
        let mb = store.mailbox(forFolder: o.folderId)
        guard MailActionRights.allows(.forward, policy: policy(for: o, mailbox: mb)) else {
            toast(MailToast(text: MailActionRights.deniedReason, symbol: "lock.fill")); return
        }
        reply(kind, to: id)
        guard let c = composer, c.original?.id == id else { return }
        if let why = attachGateReason(c) { c.editor.notice = why; return }
        guard let svc = ComposeHub.shared.service else { c.editor.notice = "The attachments couldn't be copied."; return }
        c.editor.notice = "Copying the original's attachments…"
        Task { @MainActor [weak c] in
            guard let c else { return }
            do {
                let list = try await svc.attachments(messageId: id, mailbox: mb).filter { !$0.isInline }
                var copied = 0
                var skipped: [String] = []
                for a in list {
                    if a.kind != .file || a.size > AttachmentUpload.maxSize { skipped.append(a.name); continue }
                    if let out = try await svc.attachmentContent(messageId: id, attachment: a, mailbox: mb) { c.editor.add(out); copied += 1 }
                    else { skipped.append(a.name) }
                }
                c.editor.notice = !skipped.isEmpty ? "Not copied (Outlook items, links or over 150 MB): \(skipped.joined(separator: ", "))."
                    : copied == 0 ? "The original has no file attachments." : nil
            } catch {
                c.editor.notice = "Couldn't copy the original's attachments."
            }
        }
    }
}
