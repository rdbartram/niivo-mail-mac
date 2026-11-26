import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CalendarCore
import MailCore

// MARK: - OneDrive cloud attachments (Outlook's "Share link" / "Attach a copy" / "Upload and share")
//
// Graph work lives in MailCore/GraphDriveService.swift; this file is the composer side: the picker sheet, the cloud
// chips under the editor (permission picker, label warning) and the send-time grant for "Specific people".
// Nothing new is persisted: listings, links and labels are in memory; "Attach a copy" goes through the existing
// attachment path (and its sealed draft storage).

@MainActor @Observable
final class DriveHub {
    static let shared = DriveHub()
    @ObservationIgnored private(set) var service: DriveService?
    /// Live only: interactive incremental consent for `Auth.driveScopes` (Files.ReadWrite + Files.Read.All).
    @ObservationIgnored var grant: (() async throws -> Void)?
    var picker: DrivePickerModel?
    /// Upload-and-share in progress: attachment/progress id → (name, fraction).
    var uploads: [UUID: (name: String, fraction: Double, composer: UUID)] = [:]

    /// Send waits for this composer's uploads (else the mail would go out with neither the file nor the link).
    func isUploading(for c: ComposerState) -> Bool { uploads.values.contains { $0.composer == c.id } }

    var isConfigured: Bool { service != nil }

    func configure(service: DriveService, grant: (() async throws -> Void)? = nil) {
        self.service = service; self.grant = grant
    }

    func open(for c: ComposerState) {
        guard let service else { c.editor.notice = "OneDrive isn't available."; return }
        let m = DrivePickerModel(service: service, composer: c)
        picker = m
        Task { await m.load() }
    }

    // MARK: Share / copy

    /// Creates the link, reads the file's label, inserts the chip into the body and the cloud row.
    func share(_ item: DriveItem, in c: ComposerState, type: ShareLinkType, scope: ShareScope) async throws {
        guard let service else { return }
        let r = try await service.share(item, type: type, scope: scope)
        guard let doc = CloudLinkChip.doc(name: item.name, link: r.link) else {
            throw DriveError.blocked("OneDrive returned a link niivo can't insert.")
        }
        let label = await service.sensitivityLabel(item)
        let e = c.editor
        e.cloud.append(CloudAttachment(item: item, link: r.link, label: label, notice: r.notice))
        e.insert(doc, at: e.selection)
        e.clearLinkTyping()   // typing after the chip must not extend its link
        e.onFormat?()
    }

    /// Downloads a copy into the normal attachment path (gate + 150 MB cap checked before downloading).
    func attachCopy(_ item: DriveItem, in c: ComposerState, gate: String?) async throws {
        guard let service else { return }
        if let why = gate { throw DriveError.blocked(why) }
        if let why = AttachmentUpload.invalidReason(size: max(item.size, 1), name: item.name) { throw DriveError.tooLarge(why) }
        let data = try await service.download(item, maxSize: AttachmentUpload.maxSize)
        if let why = AttachmentUpload.invalidReason(size: data.count, name: item.name) { throw DriveError.tooLarge(why) }
        let ext = (item.name as NSString).pathExtension
        let mime = item.mimeType ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? AttachmentUpload.mimeType(forExtension: ext)
        c.editor.add(OutgoingAttachment(name: item.name, contentType: mime, data: data))
        // The copy carries the file's label too: same warning as for a link.
        let label = await service.sensitivityLabel(item)
        if label != .none {
            c.editor.cloudCopyLabels[item.name] = label
        }
    }

    /// Local file → OneDrive › Attachments → link chip. `data` is read by the caller (mapped where possible).
    /// Returns true when the link is in; the caller removes the local attachment only then.
    @discardableResult
    func uploadAndShare(name: String, data: Data, in c: ComposerState, scope: ShareScope = .organization) async -> Bool {
        guard let service else { c.editor.notice = "OneDrive isn't available."; return false }
        let id = UUID()
        uploads[id] = (name, 0, c.id)
        AttachmentProgress.shared.observe(id) { [weak self] s, t in
            Task { @MainActor in self?.uploads[id]?.fraction = t > 0 ? Double(s) / Double(t) : 1 }
        }
        defer { AttachmentProgress.shared.stop(id); uploads.removeValue(forKey: id) }
        do {
            let item: DriveItem
            do { item = try await service.upload(name: name, data: data, progressId: id) }
            catch where !(error is MailServiceError) && !(error is DriveError) && grant != nil {
                // No token yet (consent never given): ask once, then retry.
                try await grant?()
                item = try await service.upload(name: name, data: data, progressId: id)
            }
            try await share(item, in: c, type: .view, scope: scope)
            return true
        } catch {
            c.editor.notice = Self.message(error, action: "upload \(name) to OneDrive")
            return false
        }
    }

    /// Permission picker on a chip: a new link replaces the old one in the body. The old link is NOT revoked
    /// (createLink may have returned an existing link others use), which the chip says.
    func change(_ id: UUID, in c: ComposerState, type: ShareLinkType, scope: ShareScope) async {
        guard let service, let i = c.editor.cloud.firstIndex(where: { $0.id == id }) else { return }
        let old = c.editor.cloud[i]
        do {
            let r = try await service.share(old.item, type: type, scope: scope)
            guard CloudLinkChip.block(name: old.item.name, link: r.link) != nil else { return }
            c.editor.replaceCloudLink(old: old.link, new: r.link)
            if let j = c.editor.cloud.firstIndex(where: { $0.id == id }) {
                c.editor.cloud[j].link = r.link
                c.editor.cloud[j].notice = r.notice ?? (old.link.url != r.link.url
                    ? "The previous link still works until it's removed in OneDrive." : nil)
            }
        } catch {
            c.editor.notice = Self.message(error, action: "change the link for \(old.item.name)")
        }
    }

    func remove(_ id: UUID, in c: ComposerState) {
        guard let a = c.editor.cloud.first(where: { $0.id == id }) else { return }
        c.editor.removeCloudLink(a.link)
        c.editor.cloud.removeAll { $0.id == id }
    }

    /// Send hook: "Specific people" links need the recipients granted (no Microsoft notification mail).
    /// Returns an error message, nil when done.
    func grantRecipients(_ c: ComposerState) async -> String? {
        guard let service else { return nil }
        let emails = Array(Set(c.allRecipients.map { $0.address.lowercased() })).sorted()
        for a in c.editor.cloud where a.link.scope == .users && c.editor.linkStillInBody(a.link) {
            do { try await service.invite(a.item, emails: emails, type: a.link.type) }
            catch { return Self.message(error, action: "give the recipients access to \(a.item.name)") }
        }
        return nil
    }

    static func message(_ error: Error, action: String) -> String {
        if let d = error as? DriveError { return d.message }
        switch error as? MailServiceError {
        case .forbidden?: return "Couldn't \(action): permission denied by OneDrive."
        case .offline?: return "Couldn't \(action): you're offline."
        case .notFound?: return "Couldn't \(action): the file no longer exists."
        case .some: return "Couldn't \(action)."
        case nil: return "Couldn't \(action): OneDrive access hasn't been granted."
        }
    }
}

// MARK: - Picker model

@MainActor @Observable
final class DrivePickerModel: Identifiable {
    enum Tab: String, CaseIterable { case files = "My files", recent = "Recent", shared = "Shared with me", search = "Search" }
    enum Mode: String, CaseIterable { case link = "Share as link", copy = "Attach a copy" }

    let id = UUID()
    @ObservationIgnored let service: DriveService
    @ObservationIgnored weak var composer: ComposerState?
    var tab: Tab = .files
    var path: [DriveItem] = []
    var items: [DriveItem] = []
    var nextLink: URL?
    var loading = false
    var error: String?
    var needsConsent = false
    var query = ""
    var selected: DriveItem?
    var mode: Mode = .link
    var linkType: ShareLinkType = .view
    var scope: ShareScope = .organization
    var busy = false

    init(service: DriveService, composer: ComposerState) { self.service = service; self.composer = composer }

    func load() async {
        loading = true; error = nil; needsConsent = false; selected = nil
        defer { loading = false }
        do {
            let p: DrivePage
            switch tab {
            case .files: p = try await service.children(of: path.last)
            case .recent: p = try await service.recent()
            case .shared: p = try await service.sharedWithMe()
            case .search:
                let q = query.trimmingCharacters(in: .whitespaces)
                p = q.isEmpty ? DrivePage(items: []) : try await service.search(q)
            }
            items = p.items; nextLink = p.nextLink
        } catch {
            items = []; nextLink = nil
            switch error as? MailServiceError {
            case .forbidden?, .http(401, _)?, nil:
                if tab == .shared, error is MailServiceError {
                    self.error = "“Shared with me” isn't available (Microsoft is retiring this list)."
                } else {
                    needsConsent = true
                    self.error = "OneDrive needs the Files.ReadWrite and Files.Read.All permissions. Your organisation's admin may have to consent to it first."
                }
            case .offline?: self.error = "You're offline."
            case .some: self.error = tab == .shared ? "“Shared with me” isn't available (Microsoft is retiring this list)." : "OneDrive couldn't be loaded."
            }
        }
    }

    func more() async {
        guard let u = nextLink else { return }
        do { let p = try await service.nextPage(u); items += p.items; nextLink = p.nextLink }
        catch { nextLink = nil; self.error = "More files couldn't be loaded." }
    }

    func open(_ folder: DriveItem) async { tab = .files; path.append(folder); await load() }
    func up(to n: Int) async { path = Array(path.prefix(n)); await load() }
}

// MARK: - Picker sheet

struct DrivePickerSheet: View {
    @Environment(AppModel.self) private var app
    var model: DrivePickerModel
    var captureBlocked: Bool

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if app.theme.brand { MonoLabel("Attach from OneDrive", color: app.skin.ink, bracket: true, wide: true, weight: .medium) }
                else { NLabel("Attach from OneDrive", systemImage: "icloud").font(.headline) }
                Spacer()
                if m.loading { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 6) {
                ForEach(DrivePickerModel.Tab.allCases, id: \.self) { t in
                    NButton(t.rawValue, kind: m.tab == t ? .primary : .quiet) { m.tab = t; if t != .search { Task { await m.load() } } }
                }
            }
            if m.tab == .search {
                TextField("Search your OneDrive", text: $m.query).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await m.load() } }
            }
            if m.tab == .files {
                HStack(spacing: 4) {
                    Button("OneDrive") { Task { await m.up(to: 0) } }.buttonStyle(.link)
                    ForEach(Array(m.path.enumerated()), id: \.offset) { i, f in
                        Text("›").foregroundStyle(.secondary)
                        Button(f.name) { Task { await m.up(to: i + 1) } }.buttonStyle(.link)
                    }
                }.font(.callout)
            }
            if let e = m.error {
                HStack {
                    NLabel(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    if m.needsConsent, let grant = DriveHub.shared.grant {
                        NButton("Grant access…", kind: .ghost) { Task { try? await grant(); await m.load() } }
                    }
                }
            }
            List(selection: Binding(get: { m.selected?.id }, set: { id in m.selected = m.items.first { $0.id == id } })) {
                ForEach(m.items) { i in row(i).tag(i.id) }
                if m.nextLink != nil { Button("Load more…") { Task { await m.more() } }.buttonStyle(.link) }
            }
            .frame(minHeight: 260)
            if let s = m.selected, !s.isFolder { options(s) }
            HStack {
                Spacer()
                NButton("Cancel", kind: .quiet) { DriveHub.shared.picker = nil }.keyboardShortcut(.cancelAction)
                NButton(m.mode == .link ? "Insert link" : "Attach copy", kind: .primary) { Task { await commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(m.selected == nil || m.selected?.isFolder == true || m.busy)
            }
        }
        .padding(18)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480)
        .background(app.theme.brand ? app.skin.ground : .clear)
        .background(WindowSharingGuard(blocked: captureBlocked))
    }

    private func row(_ i: DriveItem) -> some View {
        HStack(spacing: 8) {
            if i.isFolder { NSymbol("folder") } else {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (i.name as NSString).pathExtension) ?? .data))
                    .resizable().frame(width: 16, height: 16)
            }
            Text(i.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            if i.isFolder { Text(i.childCount.map { "\($0) items" } ?? "").foregroundStyle(.secondary).font(.caption) }
            else { Text(AttachmentUpload.formattedSize(i.size)).foregroundStyle(.secondary).font(.caption) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if i.isFolder { Task { await model.open(i) } } }
    }

    @ViewBuilder private func options(_ s: DriveItem) -> some View {
        @Bindable var m = model
        HStack(spacing: 14) {
            NPicker("", selection: $m.mode, options: DrivePickerModel.Mode.allCases, label: { $0.rawValue })
            if m.mode == .link {
                NPicker("", selection: $m.linkType, options: ShareLinkType.allCases, label: { $0 == .edit ? "Can edit" : "Can view" })
                NPicker("", selection: $m.scope, options: [ShareScope.organization, .users, .anonymous], label: { $0.title })
            }
        }
        if m.mode == .copy, s.size > AttachmentUpload.maxSize {
            NLabel("\(s.name) is larger than 150 MB: share it as a link instead.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        if m.mode == .link, m.scope == .users {
            Text("The people you send this to get access when you press Send (no extra email from Microsoft).")
                .font(.caption).foregroundStyle(.secondary)
        }
        if m.mode == .link, m.scope == .anonymous {
            Text("Anyone with the link can open it, without signing in. Your organisation may not allow this.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func commit() async {
        guard let s = model.selected, let c = model.composer else { return }
        model.busy = true
        defer { model.busy = false }
        do {
            switch model.mode {
            case .link: try await DriveHub.shared.share(s, in: c, type: model.linkType, scope: model.scope)
            case .copy: try await DriveHub.shared.attachCopy(s, in: c, gate: app.mail.attachGateReason(c))
            }
            DriveHub.shared.picker = nil
        } catch {
            model.error = DriveHub.message(error, action: model.mode == .link ? "share \(s.name)" : "attach \(s.name)")
        }
    }
}

extension View {
    /// Presents the OneDrive picker for this composer only.
    func drivePickerSheet(for c: ComposerState, captureBlocked: Bool) -> some View {
        modifier(DrivePickerPresenter(composer: c, captureBlocked: captureBlocked))
    }
}

struct DrivePickerPresenter: ViewModifier {
    @Environment(AppModel.self) private var app
    var composer: ComposerState
    var captureBlocked: Bool
    func body(content: Content) -> some View {
        let hub = DriveHub.shared
        content.sheet(item: Binding(get: { hub.picker?.composer === composer ? hub.picker : nil },
                                    set: { if $0 == nil { hub.picker = nil } })) { m in
            DrivePickerSheet(model: m, captureBlocked: captureBlocked).environment(app)
        }
    }
}

// MARK: - Cloud chips + offers under the editor

struct CloudAttachmentRow: View {
    @Environment(AppModel.self) private var app
    var composer: ComposerState

    var body: some View {
        let e = composer.editor
        let hub = DriveHub.shared
        let big = e.attachments.filter { DriveUpload.suggestsCloud(size: $0.size) }
        if hub.isConfigured && (!e.cloud.isEmpty || !big.isEmpty || !e.oversize.isEmpty || !hub.uploads.isEmpty || !e.cloudCopyLabels.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(e.cloud) { a in chip(a) }
                ForEach(Array(e.cloudCopyLabels.keys.sorted()), id: \.self) { n in
                    if let l = e.cloudCopyLabels[n] { labelWarnings(name: n, label: l, scope: .organization) }
                }
                ForEach(big) { a in
                    offer("\(a.name) is \(AttachmentUpload.formattedSize(a.size)): large attachments are often refused.") {
                        Task { if await hub.uploadAndShare(name: a.name, data: a.data, in: composer) { e.remove(a.id) } }
                    }
                }
                ForEach(e.oversize, id: \.self) { u in
                    offer("\(u.lastPathComponent) is larger than 150 MB.") {
                        guard let data = try? Data(contentsOf: u, options: .alwaysMapped) else { e.notice = "Couldn't read \(u.lastPathComponent)."; return }
                        Task { if await hub.uploadAndShare(name: u.lastPathComponent, data: data, in: composer) { e.oversize.removeAll { $0 == u } } }
                    }
                }
                ForEach(Array(hub.uploads.keys), id: \.self) { k in
                    if let u = hub.uploads[k] {
                        HStack { Text("Uploading \(u.name) to OneDrive…").font(.caption); ProgressView(value: u.fraction).frame(width: 120).controlSize(.mini) }
                    }
                }
            }
        }
    }

    private func offer(_ text: String, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            NLabel(text, systemImage: "icloud.and.arrow.up").font(.caption).foregroundStyle(.secondary)
            NButton("Upload to OneDrive and share", kind: .ghost, action: action)
        }
    }

    private func chip(_ a: CloudAttachment) -> some View {
        let hub = DriveHub.shared
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                NSymbol("link")
                Text(a.item.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                NMenuButton(label: a.link.type == .edit ? "Can edit" : "Can view", symbol: nil, items: ShareLinkType.allCases.map { t in
                    NMenuItem(title: t == .edit ? "Can edit" : "Can view", checked: a.link.type == t) {
                        Task { await hub.change(a.id, in: composer, type: t, scope: a.link.scope) }
                    }
                })
                NMenuButton(label: a.link.scope.title, symbol: nil, items: [ShareScope.organization, .users, .anonymous].map { s in
                    NMenuItem(title: s.title, checked: a.link.scope == s) {
                        Task { await hub.change(a.id, in: composer, type: a.link.type, scope: s) }
                    }
                })
                Button { hub.remove(a.id, in: composer) } label: { NSymbol("xmark").font(.caption2) }.buttonStyle(.borderless).help("Remove link")
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background {
                if app.theme.brand { Rectangle().fill(app.skin.soft).overlay(Rectangle().strokeBorder(app.skin.hair2, lineWidth: 1)) }
                else { Capsule().fill(Color.accentColor.opacity(0.12)) }
            }
            if let n = a.notice { Text(n).font(.caption).foregroundStyle(.secondary) }
            labelWarnings(name: a.item.name, label: a.label, scope: a.link.scope)
        }
    }

    /// Derived on every render against the composer's CURRENT label, so lowering the label brings the warning back.
    @ViewBuilder private func labelWarnings(name: String, label: DriveFileLabel, scope: ShareScope) -> some View {
        let tree = app.mail.compliance.labelTree()
        let external = !RecipientCheck.external(composer.allRecipients, internalDomains: app.mail.settings.internalDomains).isEmpty
        switch CloudLabelCheck.evaluate(file: label, fileName: name, mailLabelId: composer.labelId, tree: tree) {
        case .ok: EmptyView()
        case .raise(let id, let msg):
            HStack(spacing: 8) {
                NLabel(msg, systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                NButton("Raise to “\(tree.path(id) ?? "")”", kind: .ghost) { composer.setLabel(id, engine: app.mail.compliance) }
            }
        case .pickHigher(let msg):
            NLabel(msg, systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
        case .unknown(let msg):
            NLabel(msg, systemImage: "questionmark.diamond").font(.caption).foregroundStyle(.orange)
        }
        if let w = CloudLabelCheck.externalWarning(file: label, tree: tree, scope: scope, hasExternalRecipients: external) {
            NLabel(w, systemImage: "lock.trianglebadge.exclamationmark").font(.caption).foregroundStyle(.red)
        }
    }
}

// MARK: - Editor: body links of cloud chips

extension ComposerEditorState {
    private func linkRanges(_ url: String) -> [NSRange] {
        var out: [NSRange] = []
        storage.enumerateAttribute(.nvLink, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            if v as? String == url { out.append(r) }
        }
        return out
    }

    func linkStillInBody(_ l: SharingLink) -> Bool { !linkRanges(l.url).isEmpty }

    /// Points the chip's body runs at the new link; the "View"/"Edit" run follows the new permission.
    func replaceCloudLink(old: SharingLink, new: SharingLink) {
        guard let url = RichHTML.safeLink(new.url) else { return }
        for r in linkRanges(old.url).reversed() {
            let text = (storage.string as NSString).substring(with: r)
            if text == CloudLinkChip.verb(.view) || text == CloudLinkChip.verb(.edit) {
                let verb = CloudLinkChip.verb(new.type)
                var attrs = storage.attributes(at: r.location, effectiveRange: nil)
                attrs[.nvLink] = url
                edit(r, replacement: verb) {
                    storage.replaceCharacters(in: r, with: NSAttributedString(string: verb, attributes: attrs))
                    RichTextBridge.restyle(storage, NSRange(location: r.location, length: (verb as NSString).length))
                }
            } else {
                edit(r) { storage.addAttribute(.nvLink, value: url, range: r); RichTextBridge.restyle(storage, r) }
            }
        }
    }

    /// Removing the chip removes only its own span ("📄 Name · View"); the paragraph goes too only when the span was
    /// all it held, so text the user typed around the chip survives.
    func removeCloudLink(_ l: SharingLink) {
        let rs = linkRanges(l.url)
        guard let first = rs.first, let last = rs.last else { return }
        let ns = storage.string as NSString
        let prefix = CloudLinkChip.icon + " "
        let pl = (prefix as NSString).length
        var start = first.location
        if start >= pl, ns.substring(with: NSRange(location: start - pl, length: pl)) == prefix { start -= pl }
        var span = NSRange(location: start, length: NSMaxRange(last) - start)
        let pr = paragraphRange(span)
        if ns.substring(with: pr).trimmingCharacters(in: .newlines) == ns.substring(with: span) { span = pr }
        edit(span, replacement: "") { storage.replaceCharacters(in: span, with: "") }
    }

    /// Same as after `commitLink`: the cursor's typing attributes lose the link.
    func clearLinkTyping() {
        guard let tv = textView else { return }
        var t = tv.typingAttributes
        t.removeValue(forKey: .nvLink)
        t.merge(RichTextBridge.display(t)) { $1 }
        t.removeValue(forKey: .link); t.removeValue(forKey: .underlineStyle)
        tv.typingAttributes = t
    }
}
