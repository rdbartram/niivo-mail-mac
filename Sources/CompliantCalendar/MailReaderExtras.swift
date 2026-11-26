import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers
import CalendarCore
import MailCore

// Reader extras: inline cid: images (memory only), attachment actions (Quick Look, Save As…, drag out, Open With)
// gated by `AttachmentRights`, remote images per sender, and "reveal a message" for search hits and notifications.

/// Drops everything this file holds in memory or in its temp dir (lock, wipe, sign-out).
@MainActor enum ReaderExtras {
    static func dropAll() {
        InlineImageStore.shared.clear()
        AttachmentController.shared.closeAll()
        AttachmentPreviewStore.shared.clear()   // PREVIEW-HOOK
        MailNotifier.shared.reset()
        ReaderTools.shared.clear()   // READER2-HOOK: invites, headers, source text (ReaderActions2.swift)
    }
}

// MARK: - Inline images

/// Per message: the cid → bytes map, fetched once, held in memory for the last few messages only. The rewritten
/// HTML is memoised per (message, sanitised body).
@MainActor @Observable
final class InlineImageStore {
    static let shared = InlineImageStore()
    static let keepMessages = 6

    private var parts: [String: [String: InlineImages.Part]] = [:]
    @ObservationIgnored private var memo: [String: (key: Int, html: String)] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var loading: Set<String> = []

    /// The body with resolved `cid:` images, or the body unchanged until (or unless) they are loaded.
    func html(for r: ReaderState, base: String) -> String {
        let id = r.header.id
        guard let p = parts[id], !p.isEmpty else { return base }
        let key = base.hashValue
        if let m = memo[id], m.key == key { return m.html }
        let out = InlineImages.rewrite(base, parts: p).html
        memo[id] = (key, out)
        return out
    }

    /// Only called where the reader may show the body (ReaderBody's rendered branch): inline parts are part of the
    /// message, so labelled mail gets them too. Never written to disk.
    func load(_ r: ReaderState, base: String, mail: MailModel) async {
        let id = r.header.id
        guard parts[id] == nil, !loading.contains(id), let fetcher = mail.sync?.attachments else { return }
        let cands = InlineImages.candidates(r.header.attachments, html: base)
        guard !cands.isEmpty else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        let mb = r.mailbox
        let got: [AttachmentContent] = await withTaskGroup(of: AttachmentContent?.self) { g in
            for a in cands {
                g.addTask { try? await fetcher.inlineAttachment(messageId: id, attachmentId: a.id, mailbox: mb) }
            }
            var out: [AttachmentContent] = []
            for await c in g { if let c { out.append(c) } }
            return out
        }
        guard !Task.isCancelled else { return }
        parts[id] = InlineImages.parts(from: got)
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.keepMessages {
            let drop = order.removeFirst()
            parts[drop] = nil; memo[drop] = nil
        }
    }

    func clear() { parts = [:]; memo = [:]; order = []; loading = [] }
}

// MARK: - Remote images per sender + reveal

extension MailModel {
    /// "Always load remote images from this sender": unlabelled mail only, persisted (sealed) in the mail settings.
    func senderImagesAllowed(_ r: ReaderState) -> Bool {
        guard r.policy.labelState == .unlabeled, let a = r.header.from?.address.lowercased(), !a.isEmpty else { return false }
        return settings.remoteImageSenders?.contains(a) == true
    }

    func canAlwaysLoadImages(_ r: ReaderState) -> Bool {
        r.policy.labelState == .unlabeled && !r.policy.redactDetails && !(r.header.from?.address ?? "").isEmpty
    }

    func setAlwaysLoadImages(_ on: Bool, for r: ReaderState) {
        guard let a = r.header.from?.address.lowercased(), !a.isEmpty else { return }
        guard !on || r.policy.labelState == .unlabeled else {
            toast(MailToast(text: "Remote images stay blocked for labelled mail", symbol: "photo.badge.exclamationmark"))
            return
        }
        Task {
            await update { s in
                var set = Set(s.remoteImageSenders ?? [])
                if on { set.insert(a) } else { set.remove(a) }
                s.remoteImageSenders = set.isEmpty ? nil : set.sorted()
            }
            toast(MailToast(text: on ? "Remote images from \(a) will load" : "Remote images from \(a) blocked again", symbol: "photo"))
        }
    }

    /// Selects a message in the reading pane from anywhere (search window, notification): switches folder (and split
    /// tab) when the list doesn't show it. Order matters: the folder and tab setters both clear the selection.
    func reveal(messageId id: String) {
        guard let store, let h = try? store.message(id: id, includeBody: false) else { return }
        if !visibleRows.contains(where: { $0.id == id }) {
            if selectedFolderId != h.folderId { selectedFolderId = h.folderId }
            else if searchResults != nil || !searchText.isEmpty { searchText = "" }
            if showsSplitTabs {
                let b = SplitInbox.bucket(for: h)
                if splitTab != b { splitTab = b }
            }
        }
        selectedMessageId = id
        focusListToken += 1
    }
}

extension AppModel {
    /// Search hit / notification → the message in the main window's reader. `raise` brings the main window forward.
    func openMailMessage(_ id: String, raise: Bool) {
        if section != .mail { section = .mail }
        mail.reveal(messageId: id)
        if raise { Self.raiseMainWindow() }
    }

    static func raiseMainWindow() {
        NSApp.activate()
        let w = NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix("main") && $0.canBecomeMain }
            ?? NSApp.windows.first { $0.canBecomeMain && $0.isVisible }
        w?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Attachments

/// Fetches attachment bytes on demand and hands them to Quick Look, a save panel, a drag or an approved app.
/// Temp files live in a 0700 directory under the per-user temp dir, carry the quarantine flag, and are deleted when
/// the preview closes, on lock / wipe / quit, and at the next mail start.
@MainActor @Observable
final class AttachmentController: NSObject, NSWindowDelegate {
    static let shared = AttachmentController()

    private(set) var busy: Set<String> = []
    @ObservationIgnored private var panels: [NSWindow: URL] = [:]

    override init() {
        super.init()
        sweep()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AttachmentController.shared.closeAll() }
        }
    }

    static var root: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "niivo-attachments", directoryHint: .isDirectory)
    }

    /// Ensures the controller exists (its init sweeps leftovers from a previous run).
    func start() {}

    func sweep() { try? FileManager.default.removeItem(at: Self.root) }

    func closeAll() {
        for w in panels.keys { w.delegate = nil; w.close() }
        panels = [:]
        sweep()
    }

    static func device(_ app: AppModel) -> AttachmentDeviceRules {
        let t = app.trust.effectivePolicy
        return AttachmentDeviceRules(allowDownload: t.allowAttachmentsDownload, allowCopyOut: t.allowCopyOut,
                                     allowPrint: t.allowPrint, approvedOpenIn: t.approvedOpenInBundleIds)
    }

    /// Approved apps that are installed: (bundle id, name, app URL).
    static func approvedApps(_ app: AppModel) -> [(id: String, name: String, url: URL)] {
        app.trust.effectivePolicy.approvedOpenInBundleIds.compactMap { id in
            guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return (id, FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: ""), u)
        }
    }

    private func fetch(_ a: AttachmentInfo, _ r: ReaderState, _ app: AppModel) async -> Data? {
        guard let f = app.mail.sync?.attachments else { fail(app, "Attachments aren't available offline"); return nil }
        busy.insert(a.id)
        defer { busy.remove(a.id) }
        do { return try await f.attachmentBytes(messageId: r.header.id, attachmentId: a.id, mailbox: r.mailbox) }
        catch {
            fail(app, (error as? MailServiceError) == .offline ? "Offline: the attachment isn't on this Mac" : "Couldn't download the attachment")
            return nil
        }
    }

    private func fail(_ app: AppModel, _ text: String) {
        app.mail.toast(MailToast(text: text, symbol: "exclamationmark.triangle", isError: true))
    }

    /// nil when allowed; otherwise a toast with the reason.
    private func denied(_ action: AttachmentAction, _ r: ReaderState, _ app: AppModel) -> Bool {
        guard let reason = AttachmentRights.check(action, policy: r.policy, device: Self.device(app)) else { return false }
        app.mail.toast(MailToast(text: reason, symbol: "lock.fill", isError: true))
        return true
    }

    private func writeTemp(_ data: Data, name: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = Self.root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = dir.appending(path: AttachmentFiles.safeName(name))
        try data.write(to: url, options: [.withoutOverwriting])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        Self.quarantine(url)
        return url
    }

    /// Mark as downloaded (Gatekeeper / "downloaded from the internet" prompts apply to it).
    static func quarantine(_ url: URL) {
        let v = String(format: "0081;%08x;niivo mail;", Int(Date().timeIntervalSince1970))
        _ = v.withCString { p in setxattr(url.path, "com.apple.quarantine", p, strlen(p), 0, 0) }
    }

    // Quick Look in an app-owned panel: no Share / Open With buttons (those would bypass the approved-app list), and
    // capture-protected when the message is.
    func preview(_ a: AttachmentInfo, _ r: ReaderState, _ app: AppModel) {
        guard !denied(.preview, r, app) else { return }
        Task {
            guard let data = await fetch(a, r, app) else { return }
            do {
                let url = try writeTemp(data, name: a.name)
                let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
                w.title = AttachmentFiles.safeName(a.name)
                w.isReleasedWhenClosed = false
                if r.policy.preventScreenCapture || !app.trust.effectivePolicy.allowScreenCapture { w.sharingType = .none }
                guard let ql = QLPreviewView(frame: w.contentView?.bounds ?? .zero, style: .normal) else { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); return }
                ql.autoresizingMask = [.width, .height]
                ql.previewItem = url as NSURL
                w.contentView = ql
                w.delegate = self
                panels[w] = url
                w.center()
                w.makeKeyAndOrderFront(nil)
            } catch { fail(app, "Couldn't prepare the preview") }
        }
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let url = panels.removeValue(forKey: w) else { return }
        // QLPreviewView closes itself with its window (shouldCloseWithWindow); closing it again here made QuickLook
        // assert in -deactivate and abort the app. Detach the item, let QL wind down, then remove the temp file.
        (w.contentView as? QLPreviewView)?.previewItem = nil
        let dir = url.deletingLastPathComponent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { try? FileManager.default.removeItem(at: dir) }
    }

    func save(_ a: AttachmentInfo, _ r: ReaderState, _ app: AppModel) {
        guard !denied(.save, r, app) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentFiles.safeName(a.name)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            guard let data = await fetch(a, r, app) else { return }
            do { try data.write(to: dest, options: .atomic); Self.quarantine(dest) }
            catch { fail(app, "Couldn't save the attachment") }
        }
    }

    /// COMPOSE2 Save All: one folder, the same `.save` gate as a single Save As, inline images skipped, names made
    /// safe and unique (never overwriting a file already there).
    func saveAll(_ r: ReaderState, _ app: AppModel) {
        let files = r.header.attachments.filter { !$0.isInline }
        guard !files.isEmpty, !denied(.save, r, app) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Save \(files.count) Attachments"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let names = AttachmentFiles.uniqueNames(files.map(\.name), existing: existing)
        Task {
            var saved = 0
            for (a, name) in zip(files, names) {
                guard let data = await fetch(a, r, app) else { continue }
                let dest = dir.appending(path: name)
                do { try data.write(to: dest, options: [.withoutOverwriting]); Self.quarantine(dest); saved += 1 }
                catch { fail(app, "Couldn't save \(name)") }
            }
            if saved > 0 { app.mail.toast(MailToast(text: "Saved \(saved) of \(files.count) attachments", symbol: "square.and.arrow.down")) }
        }
    }

    /// Only an explicitly approved app, never the default handler. The temp copy stays until lock / quit (the app may
    /// still be reading it).
    func open(_ a: AttachmentInfo, _ r: ReaderState, with bundleId: String, _ app: AppModel) {
        guard !denied(.openIn(bundleId: bundleId), r, app),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        Task {
            guard let data = await fetch(a, r, app) else { return }
            do {
                let url = try writeTemp(data, name: a.name)
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.promptsUserIfNeeded = false
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg)
            } catch { fail(app, "Couldn't open the attachment") }
        }
    }

    /// Drag out: the file is fetched when the drop happens. Only offered when `.drag` is allowed.
    nonisolated static func exportForDrag(_ item: AttachmentDragItem) async throws -> URL {
        let data = try await item.fetcher.attachmentBytes(messageId: item.messageId, attachmentId: item.attachmentId, mailbox: item.mailbox)
        return try await MainActor.run { try AttachmentController.shared.writeTemp(data, name: item.name) }
    }
}

struct AttachmentDragItem: Transferable, Sendable {
    var messageId: String
    var attachmentId: String
    var mailbox: String
    var name: String
    var fetcher: any MailAttachmentFetching
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try await AttachmentController.exportForDrag(item))
        }
        .suggestedFileName { AttachmentFiles.safeName($0.name) }
    }
}

/// Attachment chips under the reader header: click = Quick Look, menu = Quick Look / Open With / Save As…, drag out.
/// Blocked actions stay visible and say why.
struct AttachmentChips: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState

    var body: some View {
        let visible = reader.header.attachments.filter { !$0.isInline }
        if !visible.isEmpty {
            let device = AttachmentController.device(app)
            let p = reader.policy
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visible) { a in chip(a, device: device, policy: p) }
                }
            }
        }
    }

    @ViewBuilder private func chip(_ a: AttachmentInfo, device: AttachmentDeviceRules, policy p: ContentPolicy) -> some View {
        let ctl = AttachmentController.shared
        let previewReason = AttachmentRights.check(.preview, policy: p, device: device)
        let saveReason = AttachmentRights.check(.save, policy: p, device: device)
        let dragReason = AttachmentRights.check(.drag, policy: p, device: device)
        let base = HStack(spacing: 6) {
            if ctl.busy.contains(a.id) { ProgressView().controlSize(.mini) }
            else { NSymbol(previewReason == nil ? AttachmentList.symbol(a.contentType) : "lock", size: 13) }
            VStack(alignment: .leading, spacing: 0) {
                Text(a.name).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                    .font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .caption2).foregroundStyle(.secondary)
            }
        }
        .font(app.theme.brand ? app.skin.sans(NV.Size.labelSm) : .caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(app.theme.brand ? AnyShapeStyle(app.skin.soft) : AnyShapeStyle(.quaternary.opacity(0.5)), in: app.skin.rounded)
        .overlay { if app.theme.brand { Rectangle().strokeBorder(app.skin.hair2, lineWidth: 1) } }
        .opacity(previewReason == nil ? 1 : 0.65)
        .contentShape(Rectangle())
        .onTapGesture { ctl.preview(a, reader, app) }
        .help(previewReason ?? "Quick Look (click) · more in the menu\(dragReason == nil ? " · drag to Finder" : "")")
        .contextMenu { menu(a, previewReason: previewReason, saveReason: saveReason, device: device, policy: p) }
        if dragReason == nil, let f = app.mail.sync?.attachments {
            base.draggable(AttachmentDragItem(messageId: reader.header.id, attachmentId: a.id, mailbox: reader.mailbox, name: a.name, fetcher: f))
        } else {
            base
        }
    }

    @ViewBuilder private func menu(_ a: AttachmentInfo, previewReason: String?, saveReason: String?,
                                   device: AttachmentDeviceRules, policy p: ContentPolicy) -> some View {
        let ctl = AttachmentController.shared
        Button("Quick Look") { ctl.preview(a, reader, app) }.disabled(previewReason != nil)
        let apps = AttachmentController.approvedApps(app)
        Menu("Open With") {
            if apps.isEmpty { Text("No approved apps on this Mac") }
            ForEach(apps, id: \.id) { x in
                let reason = AttachmentRights.check(.openIn(bundleId: x.id), policy: p, device: device)
                Button(x.name) { ctl.open(a, reader, with: x.id, app) }.disabled(reason != nil)
            }
        }
        .disabled(apps.isEmpty)
        Button("Save As…") { ctl.save(a, reader, app) }.disabled(saveReason != nil)
        if reader.header.attachments.filter({ !$0.isInline }).count > 1 {   // COMPOSE2
            Button("Save All Attachments…") { ctl.saveAll(reader, app) }.disabled(saveReason != nil)
        }
        if let why = saveReason ?? previewReason {
            Divider()
            Text(why)
        }
    }
}
