import SwiftUI
import AppKit
import PDFKit
import Quartz
import ImageIO
@preconcurrency import QuickLookThumbnailing
import CalendarCore
import MailCore

// Inline attachment previews under the message body (reading pane and message windows; both use ReaderContent, so
// the strip sits inside the reader's capture-shield region / the window's sharing guard).
// * Gate: `AttachmentPreviewGate` (MailCore) per attachment, re-checked after every await and before any file write.
// * Bytes: memory only, for the messages currently shown. QuickLook formats (Office…) need a file: written to the
//   session scratch dir (0700/0600, complete file protection), deleted right after the thumbnail is made, rewritten
//   while the inline viewer is open, deleted on collapse / message change / lock / quit.
// * Encrypted mail: nothing here; `ProtectedAttachmentsSection` (Purview, in-memory) handles it.

@MainActor @Observable
final class AttachmentPreviewStore {
    static let shared = AttachmentPreviewStore()

    enum Phase: Equatable { case idle, loading, ready, failed(String) }
    struct Entry {
        var phase: Phase = .idle
        var data: Data?
        var thumbnail: NSImage?
        var excerpt: String?
    }

    var settings = AttachmentPreviewSettings.load() { didSet { settings.save() } }
    private(set) var entries: [String: Entry] = [:]
    /// messageId → expanded attachment id.
    private(set) var expanded: [String: String] = [:]

    @ObservationIgnored private var refs: [String: Int] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var escMonitor: Any?
    @ObservationIgnored private weak var expandedWindow: NSWindow?
    @ObservationIgnored let scratch = PreviewScratch(
        root: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "niivo-preview", directoryHint: .isDirectory))

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AttachmentPreviewStore.shared.clear() }
        }
    }

    static func key(_ messageId: String, _ attachmentId: String) -> String { PreviewScratch.key(messageId: messageId, attachmentId: attachmentId) }
    func entry(_ messageId: String, _ attachmentId: String) -> Entry { entries[Self.key(messageId, attachmentId)] ?? Entry() }

    static func decision(_ a: AttachmentInfo, _ r: ReaderState, _ app: AppModel) -> AttachmentPreviewDecision {
        AttachmentPreviewGate.decide(a, policy: r.policy, device: AttachmentController.device(app), settings: shared.settings)
    }

    // MARK: lifecycle

    func appear(_ r: ReaderState, _ app: AppModel) {
        refs[r.header.id, default: 0] += 1
        autoLoad(r, app)
    }

    func disappear(_ messageId: String) {
        let n = (refs[messageId] ?? 1) - 1
        if n > 0 { refs[messageId] = n; return }
        refs[messageId] = nil
        drop(messageId)
    }

    /// Message no longer shown: bytes, thumbnails and files go.
    func drop(_ messageId: String) {
        let prefix = messageId + "#"
        for (k, t) in tasks where k.hasPrefix(prefix) { t.cancel(); tasks[k] = nil }
        for k in entries.keys where k.hasPrefix(prefix) { entries[k] = nil }
        if expanded.removeValue(forKey: messageId) != nil { updateEscMonitor() }
        scratch.remove(messageId: messageId)
    }

    /// Lock / wipe / sign-out / quit / setting switched off.
    func clear() {
        generation += 1
        for t in tasks.values { t.cancel() }
        tasks = [:]; entries = [:]; expanded = [:]; refs = [:]
        scratch.removeAll()
        updateEscMonitor()
    }

    func autoLoad(_ r: ReaderState, _ app: AppModel) {
        let plan = AttachmentPreviewGate.autoPlan(r.header.attachments, policy: r.policy, device: AttachmentController.device(app),
                                                  settings: settings)
        for a in plan { load(a, r, app) }
    }

    // MARK: fetch + thumbnail

    func load(_ a: AttachmentInfo, _ r: ReaderState, _ app: AppModel, thenExpand: Bool = false) {
        let d = Self.decision(a, r, app)
        guard d.mayFetch, let fetcher = app.mail.sync?.attachments else { return }
        let k = Self.key(r.header.id, a.id)
        switch entries[k]?.phase {
        case .loading?: return
        case .ready?: if thenExpand { expand(a, r, app) }; return
        default: break
        }
        entries[k] = Entry(phase: .loading)
        let gen = generation, mid = r.header.id, mb = r.mailbox
        tasks[k] = Task { [weak self] in
            let data: Data
            do { data = try await fetcher.attachmentBytes(messageId: mid, attachmentId: a.id, mailbox: mb) }
            catch {
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                self.entries[k]?.phase = .failed((error as? MailServiceError) == .offline ? "Offline" : "Couldn't load")
                return
            }
            guard let self, gen == self.generation, !Task.isCancelled, self.entries[k] != nil else { return }
            // Policy may have changed while fetching: decide again on the reader as it is now.
            let now = app.mail.reader?.header.id == mid ? app.mail.reader ?? r : r
            let d2 = Self.decision(a, now, app)
            guard d2.mayFetch, AttachmentPreviewGate.acceptsFetched(data.count, requested: d.mode, settings: self.settings) else {
                self.entries[k] = Entry(phase: .failed(d2.mayFetch ? "Too large" : "Not allowed"))
                return
            }
            var e = Entry(phase: .ready, data: data)
            switch d2.kind {
            case .image: e.thumbnail = Self.imageThumbnail(data)
            case .pdf: e.thumbnail = PDFDocument(data: data)?.page(at: 0)?.thumbnail(of: NSSize(width: 240, height: 320), for: .cropBox)
            case .text: e.excerpt = AttachmentPreviewText.firstLines(data)
            case .quickLook: e.thumbnail = await self.quickLookThumbnail(data, name: a.name, key: k, gen: gen)
            case .none: break
            }
            guard gen == self.generation, self.entries[k] != nil else { return }
            self.entries[k] = e
            self.tasks[k] = nil
            if thenExpand { self.expand(a, now, app) }
        }
    }

    nonisolated static func imageThumbnail(_ data: Data) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// File only for the duration of the generator call.
    private func quickLookThumbnail(_ data: Data, name: String, key: String, gen: Int) async -> NSImage? {
        guard let url = try? scratch.write(data, name: name, key: key) else { return nil }
        defer { if expandedKey != key { scratch.remove(key: key) } }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 320),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        let cg: CGImage? = await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in c.resume(returning: rep?.cgImage) }
        }
        guard gen == generation, let cg else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: expand / collapse

    private var expandedKey: String? { expanded.first.map { Self.key($0.key, $0.value) } }

    /// Click: ⌥ → the existing Quick Look panel; otherwise toggle the inline viewer (loading first if needed).
    func activate(_ a: AttachmentInfo, _ r: ReaderState, _ app: AppModel) {
        let d = Self.decision(a, r, app)
        if NSEvent.modifierFlags.contains(.option) || !d.mayFetch { AttachmentController.shared.preview(a, r, app); return }
        if expanded[r.header.id] == a.id { collapse(r.header.id); return }
        if entry(r.header.id, a.id).phase == .ready { expand(a, r, app) } else { load(a, r, app, thenExpand: true) }
    }

    func expand(_ a: AttachmentInfo, _ r: ReaderState, _ app: AppModel) {
        let mid = r.header.id, k = Self.key(mid, a.id)
        let d = Self.decision(a, r, app)
        guard d.mayFetch, let data = entries[k]?.data else { return }
        if expanded[mid] != nil { collapse(mid) }
        if d.kind.needsFile {
            // Re-checked just above: label offline + device download still allow a file.
            guard (try? scratch.write(data, name: a.name, key: k)) != nil else { entries[k]?.phase = .failed("Couldn't prepare"); return }
        }
        expanded[mid] = a.id
        expandedWindow = NSApp.keyWindow
        updateEscMonitor()
    }

    func collapse(_ messageId: String) {
        guard let id = expanded.removeValue(forKey: messageId) else { return }
        updateEscMonitor()
        // Let QLPreviewView detach first (main 95ef7a7: QuickLook asserts when torn down under it); lock / quit still
        // remove at once via clear().
        let k = Self.key(messageId, id), url = scratch.url(for: k), gen = generation
        guard url != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                let s = AttachmentPreviewStore.shared
                if s.generation == gen, s.expandedKey != k, s.scratch.url(for: k) == url { s.scratch.remove(key: k) }
            }
        }
    }

    /// Esc collapses the viewer, only in the window that shows it (or its capture-shield child), never in sheets,
    /// the composer's own window or search.
    private func updateEscMonitor() {
        if expanded.isEmpty {
            if let m = escMonitor { NSEvent.removeMonitor(m) }
            escMonitor = nil
            return
        }
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53 else { return e }
            nonisolated(unsafe) let ev = e
            let consumed = MainActor.assumeIsolated { () -> Bool in
                let s = AttachmentPreviewStore.shared
                guard let w = ev.window, w.attachedSheet == nil, let target = s.expandedWindow,
                      w === target || w.parent === target || target.parent === w,
                      let mid = s.expanded.keys.first else { return false }
                s.collapse(mid)
                return true
            }
            return consumed ? nil : e
        }
    }
}

// MARK: - Views

/// Thumbnails under the body; a click opens the inline viewer below them.
struct AttachmentPreviewStrip: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState

    var body: some View {
        let store = AttachmentPreviewStore.shared
        let files = reader.header.attachments.filter { !$0.isInline }
        let p = reader.policy
        if store.settings.enabled, !files.isEmpty, !p.redactDetails, !p.bodyIsProtected {
            let mid = reader.header.id
            VStack(alignment: .leading, spacing: 8) {
                Text(app.skin.caps(files.count == 1 ? "Attachment" : "\(files.count) attachments"))
                    .font(app.theme.brand ? app.skin.mono(NV.Size.labelSm, .medium) : .caption.weight(.semibold))
                    .tracking(app.skin.track(NV.Size.labelSm)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(files) { a in AttachmentPreviewTile(reader: reader, a: a) }
                    }
                }
                if let id = store.expanded[mid], let a = files.first(where: { $0.id == id }) {
                    AttachmentInlineViewer(reader: reader, a: a).id(AttachmentPreviewStore.key(mid, id))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(app.theme.brand ? app.skin.hair2 : Color.secondary.opacity(0.2)).frame(height: 1) }
            .onAppear { store.appear(reader, app) }
            .onDisappear { store.disappear(mid) }
            .onChange(of: "\(p.rights.rawValue)|\(p.allowOfflineDetails)|\(store.settings.maxBytes)|\(app.trust.effectivePolicy.allowAttachmentsDownload)") {
                // Policy or setting changed while shown: drop what may no longer be held, then load what may.
                store.drop(mid); store.autoLoad(reader, app)
            }
        }
    }
}

struct AttachmentPreviewTile: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var a: AttachmentInfo

    var body: some View {
        let store = AttachmentPreviewStore.shared
        let d = AttachmentPreviewStore.decision(a, reader, app)
        let e = store.entry(reader.header.id, a.id)
        let selected = store.expanded[reader.header.id] == a.id
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(app.theme.brand ? AnyShapeStyle(app.skin.soft) : AnyShapeStyle(.quaternary.opacity(0.5)))
                face(d, e)
            }
            .frame(width: 132, height: 96)
            .clipShape(app.skin.rounded)
            .overlay {
                app.skin.rounded.strokeBorder(selected ? AnyShapeStyle(app.theme.accent)
                                              : (app.theme.brand ? AnyShapeStyle(app.skin.hair2) : AnyShapeStyle(Color.secondary.opacity(0.25))),
                                              lineWidth: selected ? 2 : 1)
            }
            Text(a.name).lineLimit(1).truncationMode(.middle)
                .font(app.theme.brand ? app.skin.sans(NV.Size.labelSm) : .caption)
            Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                .font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .caption2).foregroundStyle(.secondary)
        }
        .frame(width: 132)
        .contentShape(Rectangle())
        .onTapGesture { store.activate(a, reader, app) }
        .help(help(d))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(a.name), \(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func face(_ d: AttachmentPreviewDecision, _ e: AttachmentPreviewStore.Entry) -> some View {
        switch d.mode {
        case .automatic, .onDemand:
            switch e.phase {
            case .loading: ProgressView().controlSize(.small)
            case .ready:
                if let img = e.thumbnail {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: d.kind == .image ? .fill : .fit)
                        .frame(width: 132, height: 96).clipped()
                } else if let t = e.excerpt {
                    Text(t).font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 124, height: 88, alignment: .topLeading).clipped()
                } else { icon() }
            case .failed(let why): VStack(spacing: 2) { icon(); Text(why).font(.caption2).foregroundStyle(.secondary) }
            case .idle:
                if d.mode == .onDemand {
                    VStack(spacing: 4) {
                        icon()
                        NButton("Load preview", kind: .quiet) { store().load(a, reader, app, thenExpand: true) }.controlSize(.small)
                    }
                } else { ProgressView().controlSize(.small) }
            }
        case .blocked(let why):
            VStack(spacing: 4) {
                NSymbol("lock", size: 16).foregroundStyle(.secondary)
                Text(why == AttachmentPreviewGate.notAllowedForLabel ? why : "Preview not allowed")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 6)
            }
        case .tooLarge: VStack(spacing: 2) { icon(); Text("Too large to preview").font(.caption2).foregroundStyle(.secondary) }
        case .iconOnly, .disabled, .protectedPath: icon()
        }
    }

    private func store() -> AttachmentPreviewStore { AttachmentPreviewStore.shared }
    private func icon() -> some View { NSymbol(AttachmentList.symbol(a.contentType), size: 22).foregroundStyle(.secondary) }

    private func help(_ d: AttachmentPreviewDecision) -> String {
        switch d.mode {
        case .blocked(let why): return why
        case .automatic, .onDemand: return "Click to preview here · ⌥-click for Quick Look"
        default: return "No preview for this file type · click for Quick Look"
        }
    }
}

/// The expanded viewer: PDF (scrolling pages), image (pinch / ⌘-scroll to zoom), text, or QuickLook for Office files.
struct AttachmentInlineViewer: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var a: AttachmentInfo

    var body: some View {
        let store = AttachmentPreviewStore.shared
        let mid = reader.header.id
        let d = AttachmentPreviewStore.decision(a, reader, app)
        let e = store.entry(mid, a.id)
        // Copy / drag out of the viewer: label EXTRACT (already required to preview) and device copy-out.
        let canCopy = reader.policy.allowCopy && app.trust.effectivePolicy.allowCopyOut
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                NSymbol(AttachmentList.symbol(a.contentType), size: 13).foregroundStyle(.secondary)
                Text(a.name).lineLimit(1).truncationMode(.middle).font(app.theme.brand ? app.skin.sans(NV.Size.labelSm, .medium) : .callout.weight(.medium))
                Spacer()
                NButton("Open", systemImage: "eye", kind: .quiet) { AttachmentController.shared.preview(a, reader, app) }
                    .help("Quick Look (⌥-click a thumbnail)")
                NButton("Close", systemImage: "xmark", kind: .quiet) { store.collapse(mid) }.help("Close preview (Esc)")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(app.theme.brand ? AnyShapeStyle(app.skin.soft) : AnyShapeStyle(.quaternary.opacity(0.4)))
            if let data = e.data, d.mayFetch {
                AttachmentRenderer(kind: d.kind, data: data,
                                   fileURL: d.kind.needsFile ? store.scratch.url(for: AttachmentPreviewStore.key(mid, a.id)) : nil,
                                   canCopy: canCopy)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity).frame(minHeight: 260, idealHeight: 420, maxHeight: 520)
        .clipShape(app.skin.rounded)
        .overlay { app.skin.rounded.strokeBorder(app.theme.brand ? AnyShapeStyle(app.skin.hair2) : AnyShapeStyle(Color.secondary.opacity(0.25)), lineWidth: 1) }
    }
}

/// AppKit renderers. In-memory for image / PDF / text; QLPreviewView only for a scratch file (closed on dismantle).
struct AttachmentRenderer: NSViewRepresentable {
    var kind: AttachmentPreviewKind
    var data: Data
    var fileURL: URL?
    var canCopy: Bool

    func makeNSView(context: Context) -> NSView {
        switch kind {
        case .pdf:
            let v = GatedPDFView()
            v.canCopy = canCopy; v.autoScales = true; v.displayMode = .singlePageContinuous
            v.document = PDFDocument(data: data)
            return v
        case .image:
            let iv = NSImageView()
            iv.image = NSImage(data: data)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.allowsCutCopyPaste = canCopy
            iv.isEditable = false
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.allowsMagnification = true; scroll.minMagnification = 0.25; scroll.maxMagnification = 8
            scroll.documentView = iv
            iv.translatesAutoresizingMaskIntoConstraints = false
            if let cv = scroll.contentView as NSView? {
                NSLayoutConstraint.activate([iv.widthAnchor.constraint(equalTo: cv.widthAnchor),
                                             iv.heightAnchor.constraint(equalTo: cv.heightAnchor)])
            }
            return scroll
        case .text:
            let scroll = NSTextView.scrollableTextView()
            if let t = scroll.documentView as? NSTextView {
                t.string = String(decoding: data.prefix(512 * 1024), as: UTF8.self)
                t.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                t.isEditable = false; t.isSelectable = canCopy
            }
            return scroll
        case .quickLook:
            guard let url = fileURL, let ql = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
            ql.shouldCloseWithWindow = false   // closed exactly once, in dismantleNSView (double close aborts QuickLook)
            ql.previewItem = url as NSURL
            return ql
        case .none:
            return NSView()
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let ql = nsView as? QLPreviewView else { return }
        ql.previewItem = nil
        ql.close()
    }
}

/// Mail Settings → "Show attachment previews" + automatic size cap.
struct AttachmentPreviewSettingsSection: View {
    @Bindable var store = AttachmentPreviewStore.shared
    var body: some View {
        Section("Attachments") {
            Toggle("Show attachment previews", isOn: Binding(get: { store.settings.enabled }, set: { on in
                store.settings.enabled = on
                if !on { store.clear() }
            }))
            Picker("Load previews automatically up to", selection: $store.settings.maxMB) {
                ForEach(AttachmentPreviewSettings.choicesMB, id: \.self) { Text("\($0) MB").tag($0) }
            }
            .disabled(!store.settings.enabled)
            Text("Larger files show a Load preview button. Previews stay in memory; Office files are written briefly to a private temporary folder, only when the label allows offline storage. Private, unknown-label and encrypted messages are never previewed here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
