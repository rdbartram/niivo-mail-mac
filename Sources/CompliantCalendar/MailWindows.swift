import SwiftUI
import AppKit
import CalendarCore
import MailCore

// Inline compose + pop-out windows (niivo theme). The model keeps ONE active composer (`MailModel.composer`, with
// its autosave and the single AI composer state); this layer only decides WHERE it is shown:
//   .inline  -> inside the reading pane, under the message header, thread visible below (or the whole pane for new mail)
//   .window  -> the "composer" window scene
// Popping out/in moves the same ComposerState object, so nothing is lost. Message windows (double-click / ⌘O) are
// independent read-only readers loaded with the same fail-closed policy as the reading pane.

@MainActor @Observable final class ComposeHost {
    static let shared = ComposeHost()
    enum Placement { case inline, window }
    var placement: Placement = .inline
    /// Setting: ⌘N / New message opens a window (default) or composes inline in the reading pane.
    var newMessageInWindow: Bool = UserDefaults.standard.object(forKey: "niivoNewMessageInWindow") as? Bool ?? true {
        didSet { UserDefaults.standard.set(newMessageInWindow, forKey: "niivoNewMessageInWindow") }
    }
    @ObservationIgnored fileprivate var routed: UUID?

    func toggle() { placement = placement == .inline ? .window : .inline }
}

/// Installed on the niivo mail root instead of `.sheet(item: $m.composer)`.
struct ComposerRouting: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    func body(content: Content) -> some View {
        let host = ComposeHost.shared
        content
            .onChange(of: app.mail.composer?.id) { _, id in
                guard let id, let c = app.mail.composer else { host.routed = nil; dismissWindow(id: "composer"); return }
                guard host.routed != id else { return }
                host.routed = id
                host.placement = c.kind == .new ? (host.newMessageInWindow ? .window : .inline) : .inline
                if A11yPrefs.shared.prefs.pane == .off { host.placement = .window }   // A11Y-HOOK: no pane to compose in
                if host.placement == .window { openWindow(id: "composer") }
            }
            .onChange(of: host.placement) { _, p in
                guard app.mail.composer != nil else { return }
                if p == .window { openWindow(id: "composer") } else { dismissWindow(id: "composer") }
            }
    }
}

/// Pop-out / pop-in control for the composer header (also ⌥↩ and ⇧⌘P).
struct ComposerPopButton: View {
    var body: some View {
        let host = ComposeHost.shared
        NIconButton(host.placement == .inline ? "arrow.up.right.square" : "arrow.down.left.square",
                    label: host.placement == .inline ? "Pop out" : "Pop back in",
                    help: host.placement == .inline ? "Open this draft in its own window (⌥↩ or ⇧⌘P)" : "Move this draft back into the reading pane (⌥↩ or ⇧⌘P)",
                    size: 24) { host.toggle() }
            .background {
                Group {
                    Button("") { host.toggle() }.keyboardShortcut(.return, modifiers: .option)
                    Button("") { host.toggle() }.keyboardShortcut("p", modifiers: [.command, .shift])
                }
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
    }
}

// MARK: - Window roots (same chrome + app lock as the main window)

/// Shared chrome for secondary windows: hidden title bar, niivo ground, capture guard, and the app lock —
/// while locked the content is replaced (never just covered).
struct SecondaryWindow<Content: View>: View {
    @Environment(AppModel.self) private var model
    var captureBlocked: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        Group {
            if model.trust.hidesContent {
                VStack(spacing: 12) {
                    NiivoMark().frame(height: 26).accessibilityHidden(true)
                    MonoLabel("Locked", color: model.skin.ink, bracket: true)
                    Text("Unlock niivo mail in the main window.").font(model.skin.sans(NV.Size.body)).foregroundStyle(model.skin.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                content()
            }
        }
        .skinned(model.skin)
        .background(model.skin.ground)
        .containerBackground(model.skin.brand ? AnyShapeStyle(model.skin.ground) : AnyShapeStyle(.windowBackground), for: .window)
        .background(SecondaryWindowControls(ground: NSColor(model.skin.ground), brand: model.theme.brand))
        .background(WindowSharingGuard(blocked: captureBlocked || model.trust.blocksScreenCapture))
        // No `.toolbar(.hidden, for: .windowToolbar)` here: on this macOS it removes the whole title bar, traffic
        // lights included (the AX tree had no close button), so pop-outs couldn't be closed.
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Minimal niivo window header: traffic-light inset, eyebrow + title, trailing actions; drags the window.
struct WindowHeader<Trailing: View>: View {
    @Environment(\.skin) private var skin
    var eyebrow: String
    var title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64)
            VStack(alignment: .leading, spacing: 0) {
                MonoLabel(eyebrow, size: NV.Size.labelSm)
                Text(title).font(skin.sans(15)).tracking(skin.titleTrack(15)).foregroundStyle(skin.ink).lineLimit(1)
            }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 10)
            trailing()
        }
        .padding(.horizontal, 12).frame(height: 50)
        .background { skin.ground.gesture(WindowDragGesture()).allowsWindowActivationEvents(true) }
        .hairline(skin)
    }
}

struct ComposerWindowRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        let mail = model.mail
        SecondaryWindow(captureBlocked: false) {
            if let c = mail.composer {
                VStack(spacing: 0) {
                    WindowHeader(eyebrow: "Message", title: c.subject.isEmpty ? "New message" : c.subject) {
                        if c.kind != .new { ComposerPopButton() }
                    }
                    ComposerView(composer: c, inline: true)
                }
            } else {
                BrandEmptyState(symbol: "square.and.pencil", eyebrow: "Message", title: "No draft open.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 560, idealHeight: 720)
        // Closing the window doesn't discard: the draft stays (autosaved) and pops back into the pane.
        .onDisappear { if mail.composer != nil, ComposeHost.shared.placement == .window { ComposeHost.shared.placement = .inline } }
    }
}

// MARK: - Message windows

@MainActor @Observable final class MessageWindows {
    static let shared = MessageWindows()
    var readers: [String: ReaderState] = [:]
    func load(_ id: String, mail: MailModel) async {
        if readers[id] == nil, let r = await mail.standaloneReader(id: id) { readers[id] = r }
    }
    /// MIP-HOOK: licence rights for `itemId` changed: this window's policy follows them (see MailModel.refreshPolicy).
    func refreshPolicy(itemId: String, mail: MailModel) {
        guard let r = readers[itemId] else { return }
        readers[itemId]?.policy = mail.reprotected(r)
    }
    func refreshPolicies(mail: MailModel) {
        for (id, r) in readers where r.policy.bodyIsProtected { readers[id]?.policy = mail.reprotected(r) }
    }
}

struct MessageWindowRoot: View {
    @Environment(AppModel.self) private var model
    var messageId: String?
    var body: some View {
        let mail = model.mail
        let r = messageId.flatMap { MessageWindows.shared.readers[$0] }
        // Only this message's rights decide (not whatever the main window shows).
        SecondaryWindow(captureBlocked: r.map { $0.policy.preventScreenCapture } ?? false) {
            VStack(spacing: 0) {
                WindowHeader(eyebrow: r.map { MailboxDisplay.title($0.mailbox) } ?? "Message",
                             title: r.map { $0.policy.redactDetails ? "Private message" : $0.header.subject } ?? "Message") {
                    if let r {
                        HStack(spacing: 2) {
                            // Usage rights (label or, once decrypted, the item's licence) gate these as in the pane.
                            NIconButton("arrowshape.turn.up.left", label: "Reply", help: "Reply (R)") { reply(.reply, r) }
                                .disabled(!MailActionRights.allows(.reply, policy: r.policy))
                            NIconButton("arrowshape.turn.up.left.2", label: "Reply all", help: "Reply all (A)") { reply(.replyAll, r) }
                                .disabled(!MailActionRights.allows(.replyAll, policy: r.policy))
                            NIconButton("arrowshape.turn.up.right", label: "Forward", help: "Forward (F)") { reply(.forward, r) }
                                .disabled(!MailActionRights.allows(.forward, policy: r.policy))
                        }
                    }
                }
                if let r { ReaderContent(reader: r, paneHost: false) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .frame(minWidth: 620, idealWidth: 820, minHeight: 520, idealHeight: 760)
        .task(id: messageId) { if let messageId { await MessageWindows.shared.load(messageId, mail: mail) } }
        .onDisappear { if let messageId { MessageWindows.shared.readers[messageId] = nil } }
    }
    /// Replies from a message window open the composer in its own window (the reading pane may show another message).
    private func reply(_ k: MailDraft.Kind, _ r: ReaderState) {
        model.mail.reply(k, to: r.header.id)
        if model.mail.composer != nil { ComposeHost.shared.placement = .window }
    }
}

// MARK: - Calendar inspector inline edit

@MainActor @Observable final class InlineEventEdit {
    static let shared = InlineEventEdit()
    var eventId: String?
    var draft = EventDraft(calendarId: "", start: .now, end: .now)
    func begin(_ e: CalendarEvent) { eventId = e.id; draft = EventDraft(e) }
    func cancel() { eventId = nil }
    func save(_ e: CalendarEvent, model: AppModel) {
        model.edit(e); model.showEditor = false
        model.editorDraft.subject = draft.subject; model.editorDraft.start = draft.start
        model.editorDraft.end = draft.end; model.editorDraft.location = draft.location
        model.saveEditor(); eventId = nil
    }
    /// Pop out to the full editor with the inline changes carried over.
    func popOut(_ e: CalendarEvent, model: AppModel) {
        let d = draft
        model.edit(e)
        model.editorDraft.subject = d.subject; model.editorDraft.start = d.start
        model.editorDraft.end = d.end; model.editorDraft.location = d.location
        eventId = nil
    }
}

struct InlineEventEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    var event: CalendarEvent
    var body: some View {
        let ed = InlineEventEdit.shared
        @Bindable var e = ed
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel("Edit", bracket: true)
            NField("Title", text: $e.draft.subject, label: "Title", style: .underline)
            HStack(spacing: 8) {
                MonoLabel("Starts", size: NV.Size.labelSm).frame(width: 46, alignment: .leading)
                DatePicker("Starts", selection: $e.draft.start).labelsHidden().datePickerStyle(.compact)
            }
            HStack(spacing: 8) {
                MonoLabel("Ends", size: NV.Size.labelSm).frame(width: 46, alignment: .leading)
                DatePicker("Ends", selection: $e.draft.end, in: ed.draft.start...).labelsHidden().datePickerStyle(.compact)
            }
            NField("Location", text: $e.draft.location, label: "Location", style: .underline)
            HStack(spacing: 8) {
                NButton("Save") { ed.save(event, model: model) }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(ed.draft.subject.trimmingCharacters(in: .whitespaces).isEmpty)
                NButton("Cancel", kind: .quiet) { ed.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                NIconButton("arrow.up.right.square", label: "Open full editor", help: "All fields: attendees, repeat, show as… (⇧⌘P)", size: 24) {
                    ed.popOut(event, model: model)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            if !event.attendees.isEmpty {
                MonoLabel("Attendees get an update when you save", size: NV.Size.labelSm)
            }
        }
        .padding(14)
        .overlay(Rectangle().strokeBorder(skin.ink, lineWidth: 1))
    }
}

/// Classic themes: the composer sheet. niivo: `ComposerRouting` (inline in the pane, or the composer window).
struct ComposerPresentation: ViewModifier {
    @Environment(AppModel.self) private var app
    var brand: Bool
    func body(content: Content) -> some View {
        if brand { content.modifier(ComposerRouting()).modifier(ExtraComposerOpener()) }   // COMPOSE2-HOOK
        else { content.sheet(item: Bindable(app.mail).composer) { c in ComposerView(composer: c) }.modifier(ExtraComposerOpener()) }
    }
}


/// Pop-out windows must always be closable (traffic lights + ⌘W) and must not drag from the content (that steals
/// text selection in the message body).
struct SecondaryWindowControls: NSViewRepresentable {
    var ground: NSColor
    var brand: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        let ground = ground, brand = brand
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            // Transparent title bar over full-size content: the traffic lights float over our WindowHeader (which
            // leaves room for them) instead of an opaque bar that cut the content off.
            w.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.titlebarSeparatorStyle = .none
            // An (empty) unified toolbar makes the title-bar strip as tall as our 50 pt WindowHeader, so the traffic
            // lights sit vertically centred in the header instead of over its top edge — on macOS 26+ the 28 pt
            // title bar's glass/edge effect blurred the top half of the header (owner's screenshot, 2026-11-20).
            if w.toolbar == nil {
                let t = NSToolbar(identifier: "niivo.secondary")
                t.showsBaselineSeparator = false
                t.displayMode = .iconOnly
                w.toolbar = t
            }
            w.toolbarStyle = .unifiedCompact
            w.backgroundColor = brand ? ground : .windowBackgroundColor
            w.isMovableByWindowBackground = false
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = false }
        }
    }
}

// MARK: - COMPOSE2: several drafts at once

/// Opens the extra composer windows the model asks for (a draft moved out of the pane to make room for another).
struct ExtraComposerOpener: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onChange(of: app.mail.windowRequests) { _, ids in
            guard !ids.isEmpty else { return }
            app.mail.windowRequests = []
            for id in ids { openWindow(id: "composer-extra", value: id) }
        }
    }
}

/// One extra draft in its own window. Closing the window closes the draft (saved, like Close); a restored window
/// whose draft is gone shows an empty state.
struct ExtraComposerWindowRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    var composerId: UUID?
    var body: some View {
        let mail = model.mail
        let c = composerId.flatMap { mail.windowComposer($0) }
        SecondaryWindow(captureBlocked: false) {
            if let c {
                VStack(spacing: 0) {
                    WindowHeader(eyebrow: "Message", title: c.subject.isEmpty ? "New message" : c.subject) { EmptyView() }
                    ComposerView(composer: c, inline: true)
                }
            } else {
                BrandEmptyState(symbol: "square.and.pencil", eyebrow: "Message", title: "This draft is closed. Open it from Drafts.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 560, idealHeight: 720)
        .onDisappear { if let c = composerId.flatMap({ mail.windowComposer($0) }) { mail.closeComposer(c) } }
        // Sent / closed / discarded (or moved back to the pane): the window goes with it.
        .onChange(of: c == nil) { _, gone in if gone, let id = composerId { dismissWindow(id: "composer-extra", value: id) } }
    }
}
