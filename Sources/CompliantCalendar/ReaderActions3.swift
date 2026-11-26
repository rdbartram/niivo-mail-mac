import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import CalendarCore
import MailCore

// Reader extras (UI, part 2): find in message, print, view source / save .eml, commands, mark-as-read delay.

// MARK: - Find in message

@MainActor
enum ReaderFind {
    static func open(_ w: ReaderWebView? = nil) {
        let x = ReaderTools.shared
        if let w { x.webView = w }
        guard x.webView != nil else { NSSound.beep(); return }
        x.findVisible = true; x.findStatus = nil; x.findFocusToken += 1
    }

    /// WKWebView find: selects (and scrolls to) the next match; wraps around.
    static func find(backwards: Bool = false) {
        let x = ReaderTools.shared
        guard let w = x.webView, !x.findQuery.isEmpty else { x.findStatus = nil; return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards; cfg.caseSensitive = false; cfg.wraps = true
        let q = x.findQuery
        w.find(q, configuration: cfg) { r in
            let found = r.matchFound
            Task { @MainActor in
                guard x.findQuery == q else { return }
                x.findStatus = found ? nil : "Not found"
            }
        }
    }

    static func close() {
        let x = ReaderTools.shared
        x.findVisible = false; x.findStatus = nil
        if let w = x.webView { w.window?.makeFirstResponder(w) }
    }
}

struct ReaderFindBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var x = ReaderTools.shared
    var body: some View {
        if x.findVisible {
            HStack(spacing: 6) {
                NSymbol("magnifyingglass", size: 12).foregroundStyle(.secondary)
                FindField(text: $x.findQuery, focusToken: x.findFocusToken,
                          onSubmit: { back in ReaderFind.find(backwards: back) }, onCancel: { ReaderFind.close() })
                    .frame(minWidth: 160, maxWidth: 260, maxHeight: 22)
                if let s = x.findStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { ReaderFind.find(backwards: true) } label: { NSymbol("chevron.up", size: 12) }.help("Previous (⇧⌘G)")
                Button { ReaderFind.find() } label: { NSymbol("chevron.down", size: 12) }.help("Next (⌘G / Return)")
                Button("Done") { ReaderFind.close() }
            }
            .buttonStyle(.borderless).font(.caption)
            .padding(.horizontal, 18).padding(.vertical, 5)
            .background(app.theme.brand ? AnyShapeStyle(app.skin.soft) : AnyShapeStyle(.bar))
            .onChange(of: x.findQuery) { _, _ in ReaderFind.find() }
        }
    }
}

/// NSSearchField wrapper: Return = next, ⇧Return = previous, Esc = close; takes focus on every new token.
struct FindField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var onSubmit: (Bool) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> C { C(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Find in message"
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        f.controlSize = .small
        return f
    }
    func updateNSView(_ f: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        if context.coordinator.token != focusToken {
            context.coordinator.token = focusToken
            DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        }
    }
    @MainActor final class C: NSObject, NSSearchFieldDelegate {
        var parent: FindField
        var token = -1
        init(_ p: FindField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { parent.text = f.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(NSEvent.modifierFlags.contains(.shift)); return true }
            if sel == #selector(NSResponder.cancelOperation(_:)) { parent.onCancel(); return true }
            return false
        }
    }
}

// MARK: - Print

/// Prints a separate document (header block + label header marking + body + footer marking + watermark) from an
/// offscreen WKWebView with JavaScript off and remote loads blocked. Gated by `ReaderGates.print`.
@MainActor
final class ReaderPrint: NSObject, WKNavigationDelegate {
    private static var active: ReaderPrint?
    private let web: WKWebView
    private let window: NSWindow?
    private let jobTitle: String

    private init(html: String, title: String, window: NSWindow?) {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 1000), configuration: cfg)
        self.window = window; self.jobTitle = title
        super.init()
        web.navigationDelegate = self
        let w = web
        RemoteBlocker.get { list in
            guard let list else { NSSound.beep(); ReaderPrint.active = nil; return }   // never print with remote loads open
            w.configuration.userContentController.add(list)
            w.loadHTMLString(html, baseURL: nil)
        }
    }

    static func print(_ r: ReaderState, app: AppModel) {
        let p = r.policy
        if let why = ReaderGates.print(p, devicePrint: app.trust.effectivePolicy.allowPrint) {
            app.mail.toast(MailToast(text: why, symbol: "printer", isError: true)); NSSound.beep(); return
        }
        guard let rendered = app.mail.rendered(r) else { NSSound.beep(); return }
        let m = r.header
        let html = PrintDocument.html(
            bodyHTML: InlineImageStore.shared.html(for: r, base: rendered.html), subject: m.subject,
            from: m.from.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" } ?? "",
            to: (m.toRecipients + m.ccRecipients).map(\.display).joined(separator: ", "),
            date: m.received.formatted(date: .complete, time: .shortened),
            headerMarking: p.headerMarking, footerMarking: p.footerMarking, watermark: p.watermark)
        active = ReaderPrint(html: html, title: m.subject, window: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { run() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let s = action.request.url?.scheme
        return (s == nil || s == "about") ? .allow : .cancel
    }

    private func run() {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        let op = web.printOperation(with: info)
        op.jobTitle = jobTitle.isEmpty ? "Message" : jobTitle
        op.showsPrintPanel = true; op.showsProgressPanel = true
        op.view?.frame = web.bounds   // WKWebView prints blank pages without a frame
        if let w = window { op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
        Self.active = nil
    }
}

// MARK: - View source / save .eml

@MainActor
enum ReaderSource {
    static func open(_ r: ReaderState, app: AppModel) {
        let x = ReaderTools.shared
        guard ReaderGates.source(r.policy) == nil, let svc = app.mail.sync?.readerService else { NSSound.beep(); return }
        x.sourceReader = r; x.sourceTitle = r.header.subject
        x.sourceHeaders = []; x.sourceText = ""; x.sourceError = nil; x.sourceLoading = true
        x.sourceAllowCopy = r.policy.allowCopy && app.trust.effectivePolicy.allowCopyOut
        x.showSource = true
        let id = r.header.id, mb = r.mailbox
        Task { @MainActor in
            defer { x.sourceLoading = false }
            do {
                async let h = svc.internetHeaders(messageId: id, mailbox: mb)
                async let mime = svc.mimeSource(messageId: id, mailbox: mb)
                let (hh, mm) = try await (h, mime)
                guard x.sourceReader?.header.id == id else { return }
                x.sourceHeaders = hh
                let cap = 1_000_000
                let text = String(decoding: mm.prefix(cap), as: UTF8.self)
                x.sourceText = mm.count > cap ? text + "\n\n… (\(mm.count - cap) more bytes not shown)" : text
            } catch {
                x.sourceError = "The source couldn't be loaded."
            }
        }
    }

    static func saveEML(_ r: ReaderState, app: AppModel) {
        guard ReaderGates.saveEML(r.policy, deviceCopyOut: app.trust.effectivePolicy.allowCopyOut) == nil,
              let svc = app.mail.sync?.readerService else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "eml") ?? .data]
        panel.nameFieldStringValue = AttachmentFiles.safeName((r.header.subject.isEmpty ? "message" : r.header.subject) + ".eml")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = r.header.id, mb = r.mailbox
        Task { @MainActor in
            do {
                let data = try await svc.mimeSource(messageId: id, mailbox: mb)
                try data.write(to: url, options: .atomic)
                app.mail.toast(MailToast(text: "Saved \(url.lastPathComponent)", symbol: "square.and.arrow.down"))
            } catch {
                app.mail.toast(MailToast(text: "The message couldn't be saved", symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }
}

struct SourceSheet: View {
    @Bindable var x = ReaderTools.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Source — \(x.sourceTitle.isEmpty ? "(no subject)" : x.sourceTitle)").font(.headline).lineLimit(1)
                Spacer()
                Button("Close") { x.showSource = false; x.sourceText = ""; x.sourceHeaders = []; x.sourceReader = nil }
                    .keyboardShortcut(.cancelAction)
            }
            if x.sourceLoading { ProgressView().frame(maxWidth: .infinity) }
            if let e = x.sourceError { Text(e).foregroundStyle(.red) }
            TabView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if x.sourceHeaders.isEmpty && !x.sourceLoading {
                            Text("No internet headers (mail that never left Exchange has none).").foregroundStyle(.secondary)
                        }
                        ForEach(Array(x.sourceHeaders.enumerated()), id: \.offset) { _, h in
                            (Text(h.name + ": ").bold() + Text(h.value)).font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .modifier(SelectableIf(on: x.sourceAllowCopy))
                }
                .tabItem { Text("Headers") }
                ScrollView([.vertical, .horizontal]) {
                    Text(x.sourceText).font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .modifier(SelectableIf(on: x.sourceAllowCopy))
                }
                .tabItem { Text("MIME") }
            }
        }
        .padding(16).frame(minWidth: 640, idealWidth: 760, minHeight: 460, idealHeight: 600)
    }
}

struct SelectableIf: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}

/// Reader hook: invite card, unsubscribe bar, find bar, source sheet.
struct ReaderExtrasBlock: View {
    var reader: ReaderState
    var body: some View {
        VStack(spacing: 0) {
            InviteCard(reader: reader)
            UnsubscribeBar(reader: reader)
            ReaderFindBar()
        }
    }
}

struct ReaderExtrasHost: ViewModifier {
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        content.sheet(isPresented: Bindable(ReaderTools.shared).showSource) { SourceSheet().environment(app).skinned(app.skin) }
    }
}

// MARK: - Commands

struct ReaderCommands: Commands {
    var model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Print Message…") {
                if model.section == .mail, let r = model.mail.reader { ReaderPrint.print(r, app: model) } else { NSSound.beep() }
            }
            .keyboardShortcut("p", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Message…") { ReaderFind.open() }.keyboardShortcut("f", modifiers: [.command, .option])
            Button("Find Next") { ReaderFind.find() }.keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { ReaderFind.find(backwards: true) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Mark as read on view (0 s / 5 s / never)

enum MarkReadDelay: Int, CaseIterable, Identifiable {
    case immediately = 0, fiveSeconds = 5, never = -1
    var id: Int { rawValue }
    var title: String {
        switch self { case .immediately: "Immediately"; case .fiveSeconds: "After 5 seconds"; case .never: "Never" }
    }
    static let key = "mail.markReadDelay"
    static var current: MarkReadDelay {
        get { MarkReadDelay(rawValue: UserDefaults.standard.object(forKey: key) as? Int ?? 0) ?? .immediately }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

@MainActor
final class MarkReadScheduler {
    static let shared = MarkReadScheduler()
    private var task: Task<Void, Never>?

    /// Called when the reading pane opens a message. Moving on cancels a pending delayed mark.
    /// THREAD-HOOK: `thread` (conversation view) marks every unread member that is shown, like Gmail.
    func opened(_ header: MailMessage, thread: [MailMessage] = [], mail: MailModel) {
        task?.cancel(); task = nil
        let ids = ([header] + thread).filter { !$0.isRead && !$0.isDraft }.map(\.id)
        guard !ids.isEmpty, let sync = mail.sync else { return }
        // A11Y-HOOK: with the reading pane off, selecting a row in the list is not "viewing" it.
        guard A11yPrefs.shared.prefs.pane != .off else { return }
        let id = header.id
        let unique = Array(Set(ids))
        switch MarkReadDelay.current {
        case .never: return
        case .immediately: task = Task { _ = await sync.apply(unique.map { BulkStep(messageId: $0, action: .markRead(true)) }) }
        case .fiveSeconds:
            task = Task { @MainActor [weak mail] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let mail, mail.selectedMessageId == id else { return }
                _ = await sync.apply(unique.map { BulkStep(messageId: $0, action: .markRead(true)) })
            }
        }
    }
}

@MainActor @Observable
final class MarkReadSettingHolder {
    static let shared = MarkReadSettingHolder()
    var delay: MarkReadDelay = MarkReadDelay.current { didSet { MarkReadDelay.current = delay } }
}

struct MarkReadSettingRow: View {
    @Bindable var holder = MarkReadSettingHolder.shared
    var body: some View {
        Picker("Mark as read when viewed", selection: $holder.delay) {
            ForEach(MarkReadDelay.allCases) { Text($0.title).tag($0) }
        }
    }
}
