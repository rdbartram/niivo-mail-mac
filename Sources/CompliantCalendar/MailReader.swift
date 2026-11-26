import SwiftUI
import AppKit
import WebKit
import CalendarCore
import MailCore

/// Reader pane. Same contract as EventInspector: every control is driven by `ContentPolicy`.
struct ReaderView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.theme.brand, ComposeHost.shared.placement == .inline, let c = app.mail.composer,
           c.original == nil || app.mail.reader.map({ r in r.header.id != c.original?.id && !r.thread.contains { $0.id == c.original?.id } }) ?? true {
            // New message (or a reply to a message no longer in the pane) composed inline: the whole pane.
            ComposerView(composer: c, inline: true)
        } else if let r = app.mail.reader {
            // Only the reader is withheld from captures for content whose rights forbid it; the rest of the app stays
            // capturable (Ryan 2026-11-19).
            let app = app
            if app.mail.groupConversations, r.thread.count > 1 {
                // THREAD-HOOK: conversation stack; the shield follows the strictest member (each body keeps its own policy).
                ConversationReader(reader: r)
                    .captureShield(ConversationHub.shared.policy(over: r, mail: app.mail).preventScreenCapture) { $0.environment(app).skinned(app.skin) }
                    .paneFocusRing(MailFocus.shared.readerFocused, skin: app.skin)
            } else {
                ReaderContent(reader: r)
                    .captureShield(r.policy.preventScreenCapture) { $0.environment(app).skinned(app.skin) }
                    .paneFocusRing(MailFocus.shared.readerFocused, skin: app.skin)   // A11Y-HOOK
            }
        } else if app.theme.brand {
            BrandEmptyState(symbol: "envelope.open", eyebrow: L("Reader"), title: L("No message selected."),
                            hint: L("J / K to move · ⌘K commands · ⌘/ shortcuts"))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(app.skin.card)
        } else {
            VStack(spacing: 10) {
                NSymbol("envelope.open", size: 40).font(.system(size: 40, weight: .thin))
                Text(L("No message selected"))
                Text(L("J / K to move · ⌘K for commands · ⌘/ for all shortcuts")).font(.caption)
            }
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ReaderContent: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState

    /// Inline composer for this message (in the reading pane only — message windows pass `paneHost: false`).
    var paneHost = true
    private var inlineComposer: Bool {
        guard paneHost, app.theme.brand, ComposeHost.shared.placement == .inline, let c = app.mail.composer, let o = c.original else { return false }
        return o.id == reader.header.id || reader.thread.contains { $0.id == o.id }
    }

    /// Copy-out is allowed only if the label AND the device trust policy allow it.
    private var allowCopy: Bool { reader.policy.allowCopy && app.trust.effectivePolicy.allowCopyOut }

    var body: some View {
        let p = reader.policy
        VStack(spacing: 0) {
            if inlineComposer, let c = app.mail.composer {
                // COMPOSE-LAYOUT: the reply takes over the pane; the original collapses to a strip (InlineReplyPane,
                // ComposeInline.swift) and expands through the same ReaderBody path. Still inside this view's
                // capture shield and watermark.
                InlineReplyPane(composer: c, reader: reader, allowCopy: allowCopy)
            } else {
                ReaderHeader(reader: reader, allowCopy: allowCopy)
                LoopReaderChip(reader: reader)   // LOOPS-HOOK: confirmed loop chip
                PromiseReaderLine(reader: reader)   // PROMISES-HOOK: "You promised: … by Fri"
                ReaderExtrasBlock(reader: reader)   // READER2-HOOK: invite card, unsubscribe, find bar (ReaderActions2/3.swift)
                AIReaderStrip(reader: reader, allowCopy: allowCopy)   // AI-HOOK: thread summary, once requested
                RelatedStrip(reader: reader)   // STORY-HOOK: related messages across conversations (StoryViews.swift)
                if reader.thread.count > 1 {
                    if reader.thread.count > 4 { ScrollView { ThreadStrip(reader: reader) }.frame(maxHeight: 130) }
                    else { ThreadStrip(reader: reader) }
                }
                Divider()
                ReaderBody(reader: reader, allowCopy: allowCopy)
                AttachmentPreviewStrip(reader: reader).id(reader.header.id)   // PREVIEW-HOOK: inline attachment previews (AttachmentPreviews.swift)
                AISmartReplyRow(reader: reader)   // AI-HOOK: one slim row of three replies (COMPOSE-LAYOUT)
                if let f = p.footerMarking { FooterMarking(text: f) }
            }
        }
        .overlay { if let w = p.watermark { Watermark(text: w) } }
        .background(app.theme.brand ? AnyShapeStyle(app.skin.card) : AnyShapeStyle(.background))
        .modifier(ReaderExtrasHost())   // READER2-HOOK: source sheet
    }
}

struct ReaderHeader: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var allowCopy: Bool

    var body: some View {
        let m = reader.header
        let p = reader.policy
        VStack(alignment: .leading, spacing: 10) {
            ReaderLabelLine(policy: p, origin: m.labelOrigin)   // COMPOSE-LAYOUT: only restriction notices keep a line; the label is a pill by the date
            if let h = LabelDisplay.visibleMarking(p, origin: m.labelOrigin) { HeaderMarking(text: h, color: p.label.map { Color(hex: $0.hexColor, fallback: .red) }) }
            HStack(alignment: .top) {
                Text(p.redactDetails ? "Private message" : (m.subject.isEmpty ? "(no subject)" : m.subject))
                    .font(app.theme.brand ? app.skin.sans(NV.Size.title) : .title2.weight(.semibold))
                    .tracking(app.skin.titleTrack(NV.Size.title))
                    .fontDesign(app.theme.design)
                    .accessibilityAddTraits(.isHeader)   // A11Y
                Spacer()
                HStack(spacing: 4) {
                    ReaderActions(reader: reader)
                    TaskFromMessageButton(message: m, policy: p)   // PEOPLE-HOOK: Add to To Do (PeopleViews.swift)
                }
                .padding(.horizontal, 8).padding(.vertical, 4).niivoGlassCapsule()   // GLASS: the reader's action toolbar floats
            }
            people(m, p)
            if !p.redactDetails && !m.attachments.isEmpty { AttachmentChips(reader: reader) }   // READER-HOOK: MailReaderExtras.swift
        }
        .padding(18)
        .modifier(Selectable(enabled: allowCopy))
        .onCopyCommand { allowCopy ? [NSItemProvider(object: m.subject as NSString)] : [] }
    }

    @ViewBuilder private func people(_ m: MailMessage, _ p: ContentPolicy) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if reader.mailbox != "me" { MailboxBadge(mailbox: reader.mailbox, size: 18) }
                Text(p.redactDetails ? L("Private") : fromText(m)).font(app.theme.brand ? app.skin.sans(NV.Size.body, .medium) : .callout.weight(.medium))
                    .accessibilityLabel(p.redactDetails ? L("Private") : L("From %@", fromText(m)))
                    .personCard(p.redactDetails ? nil : m.from)   // PEOPLE-HOOK: click → contact card, presence dot
                Spacer()
                LabelPill(policy: p, origin: m.labelOrigin)   // COMPOSE-LAYOUT: always visible (compliance)
                Text(app.skin.caps(A11yPrefs.shared.regional.dateTime(m.received)))   // A11Y-HOOK: mailbox regional format
                    .font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .caption).foregroundStyle(.secondary)
            }
            if !p.redactDetails {
                if !m.toRecipients.isEmpty { line("To", m.toRecipients) }
                if !m.ccRecipients.isEmpty { line("Cc", m.ccRecipients) }
                if m.toRecipients.isEmpty && !p.allowOfflineDetails {
                    Text(L("Recipients aren't stored on this Mac for this label.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if reader.mailbox != "me" {
                Text(L("In %@", MailboxDisplay.title(reader.mailbox))).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func fromText(_ m: MailMessage) -> String {
        let f = m.from.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" } ?? "(no sender)"
        if let s = m.sender, let fr = m.from, s.address.lowercased() != fr.address.lowercased() {
            return "\(s.display) on behalf of \(f)"
        }
        return f
    }

    private func line(_ title: String, _ list: [EmailAddress]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(app.skin.caps(title)).font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .caption)
                .foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
            Text(list.map(\.display).joined(separator: ", ")).lineLimit(3)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)   // A11Y: "To, Anna, Ben"
    }
}

struct ReaderActions: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var body: some View {
        let mail = app.mail
        let m = reader.header
        HStack(spacing: 4) {
            // Reply / Reply all / Forward follow the label's usage rights (REPLY / REPLYALL / FORWARD).
            let p = reader.policy
            Button { mail.reply(.reply, to: m.id) } label: { NSymbol("arrowshape.turn.up.left", size: 15) }
                .accessibilityLabel(L("Reply"))   // A11Y
                .disabled(!MailActionRights.allows(.reply, policy: p))
                .help(MailActionRights.help(.reply, policy: p, otherwise: "Reply (R)"))
            Button { mail.reply(.replyAll, to: m.id) } label: { NSymbol("arrowshape.turn.up.left.2", size: 15) }
                .accessibilityLabel(L("Reply All"))
                .disabled(!MailActionRights.allows(.replyAll, policy: p))
                .help(MailActionRights.help(.replyAll, policy: p, otherwise: "Reply all (A)"))
            Button { mail.reply(.forward, to: m.id) } label: { NSymbol("arrowshape.turn.up.right", size: 15) }
                .accessibilityLabel(L("Forward"))
                .disabled(!MailActionRights.allows(.forward, policy: p))
                .help(MailActionRights.help(.forward, policy: p, otherwise: "Forward (F)"))
            Menu {
                if m.hasAttachments {   // COMPOSE-HOOK: copies the original's files into the reply
                    Button(L("Reply with Attachments")) { mail.replyWithAttachments(.reply, to: m.id) }
                        .disabled(!MailActionRights.allows(.reply, policy: p) || !MailActionRights.allows(.forward, policy: p))
                    Button(L("Reply All with Attachments")) { mail.replyWithAttachments(.replyAll, to: m.id) }
                        .disabled(!MailActionRights.allows(.replyAll, policy: p) || !MailActionRights.allows(.forward, policy: p))
                    Button("Save All Attachments…") { AttachmentController.shared.saveAll(reader, app) }   // COMPOSE2-HOOK
                        .disabled(AttachmentRights.check(.save, policy: p, device: AttachmentController.device(app)) != nil)
                    Divider()
                }
                if mail.isScheduled(m) {   // COMPOSE2-HOOK: send later → back to Drafts
                    Button("Cancel Scheduled Send") { mail.cancelScheduledSend(id: m.id) }
                }
                Button("Reply with Meeting") { app.replyWithMeeting(messageId: m.id) }   // COMPOSE2-HOOK (ReplyMeeting.swift)
                    .disabled(!MailActionRights.allows(.replyAll, policy: p))
                                Menu("Always Move Messages From \(reader.policy.redactDetails ? "Sender" : (m.from?.display ?? "Sender")) To") {
                    ForEach((mail.folders[reader.mailbox] ?? []).filter { $0.wellKnown != .inbox && $0.id != m.folderId && !$0.id.hasPrefix("local-") }) { f in
                        Button(f.displayName) { mail.suggestRule(for: m, folder: f) }
                    }
                }
                .disabled(m.from == nil || reader.mailbox != "me")
                Button(L("Load Remote Images")) { mail.allowImages(for: reader) }.disabled(reader.policy.labelState != .unlabeled)   // THREAD-HOOK: per message
                Toggle(L("Always Load Remote Images From This Sender"), isOn: Binding(   // READER-HOOK
                    get: { mail.senderImagesAllowed(reader) }, set: { mail.setAlwaysLoadImages($0, for: reader) }))
                    .disabled(!mail.canAlwaysLoadImages(reader))
                if let link = m.webLink { Button(L("Open in Outlook on the Web")) { NSWorkspace.shared.open(link) } }
                Divider()
                ReaderAIMenuItems(reader: reader)   // AI-HOOK: Summarise + Voice moved here from the reply strip (COMPOSE-LAYOUT)
                ReaderMoreItems(reader: reader)   // READER2-HOOK: print, find, source, junk, block, unsubscribe
                Divider()
                Button(L("Keyboard Shortcuts")) { mail.showCheatSheet = true }
            } label: { NSymbol("ellipsis.circle", size: 15) }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(L("More actions"))
            .modifier(ReaderVoicePopoverAnchor(reader: reader))   // VOICE-HOOK: ⋯ ▸ Voice opens the quick editor here
        }
        .buttonStyle(.borderless)
    }
}

struct AttachmentList: View {
    @Environment(AppModel.self) private var app
    var attachments: [AttachmentInfo]
    var body: some View {
        let visible = attachments.filter { !$0.isInline }
        if !visible.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visible) { a in
                        HStack(spacing: 6) {
                            NSymbol(Self.symbol(a.contentType))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(a.name).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(app.theme.brand ? AnyShapeStyle(app.skin.soft) : AnyShapeStyle(.quaternary.opacity(0.5)), in: app.skin.rounded)
                        .overlay { if app.theme.brand { Rectangle().strokeBorder(app.skin.hair2, lineWidth: 1) } }
                        .help(app.trust.effectivePolicy.allowAttachmentsDownload
                              ? "Opening attachments isn't wired in this build"
                              : "Downloading attachments is blocked by this Mac's trust policy")
                    }
                }
            }
        }
    }
    static func symbol(_ type: String) -> String {
        if type.hasPrefix("image/") { return "photo" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("sheet") || type.contains("excel") { return "tablecells" }
        if type.contains("presentation") || type.contains("powerpoint") { return "rectangle.on.rectangle" }
        return "doc"
    }
}

struct ThreadStrip: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(app.skin.caps("\(reader.thread.count) messages in this conversation"))
                .font(app.theme.brand ? app.skin.mono(NV.Size.labelSm, .medium) : .caption.weight(.semibold))
                .tracking(app.skin.track(NV.Size.labelSm))
                .foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 4)
            ForEach(reader.thread) { t in
                let p = app.mail.policy(for: t, mailbox: reader.mailbox)
                let current = t.id == reader.header.id
                HStack(spacing: 8) {
                    NSymbol(current ? "largecircle.fill.circle" : "circle").font(.caption2)
                        .foregroundStyle(current ? app.theme.accent : .secondary)
                    Text(p.redactDetails ? "Private" : (t.from?.display ?? "")).font(.caption.weight(current ? .semibold : .regular)).lineLimit(1)
                    Text(p.redactDetails ? "" : (t.preview ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(MessageRowView.time(t.received)).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture { app.mail.selectedMessageId = t.id }
            }
        }
        .padding(.bottom, 8)
    }
}

struct ReaderBody: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    var reader: ReaderState
    var allowCopy: Bool
    /// TRIAGE3-HOOK: keys the web view doesn't use. nil = mail triage on the main window's selection (the reader);
    /// other windows (Train Triage) pass their own so a stray key never archives or deletes there.
    var onKey: ((NSEvent) -> Bool)? = nil

    var body: some View {
        let p = reader.policy
        let mail = app.mail
        let keys = onKey ?? { e in MailKeys.handle(e, mail: mail) }
        Group {
            if p.redactDetails {
                pad(Notice(icon: "lock.fill", text: L("Marked private by the owner. Details are hidden for delegates and shared viewers.")))
            } else if p.bodyIsProtected {
                // MIP hook: ProtectedBodyStore publishes decrypting / decrypted / notPermitted / … per id; the
                // coordinator decrypts in memory (docs/MIP.md). Rights below are the item's licence once decrypted.
                ProtectedReaderBody(reader: reader, allowCopy: allowCopy, onKey: onKey)
            } else if case .unknown = p.labelState {
                pad(Notice(icon: "questionmark.diamond", text: L("This message's label isn't in your synced policy. Content stays hidden until the policy syncs.")))
            } else if reader.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = reader.error {
                pad(Notice(icon: "wifi.exclamationmark", text: err))
            } else if let r = mail.rendered(reader) {
                // READER-HOOK: cid: images resolved in memory (MailReaderExtras.swift); the body as-is until they load.
                let html = InlineImageStore.shared.html(for: reader, base: r.html)
                // §17: Dark Mode. Bodies that hard-code colours are adapted; "Show original colours" is per message.
                let id = reader.header.id
                let original = ReaderColours.shared.showsOriginal(id)
                VStack(spacing: 0) {
                    if r.blocked > 0 && !mail.remoteAllowed(for: reader) { RemoteBar(count: r.blocked, labelled: p.labelState != .unlabeled, reader: reader) }
                    if scheme == .dark && (original || ReaderAppearance.setsOwnColours(html)) { OriginalColoursBar(messageId: id, original: original) }
                    MailWebView(html: MailHTML.document(html, noSelect: !allowCopy, original: original, dark: scheme == .dark, brand: app.theme.brand),
                                allowRemote: mail.remoteAllowed(for: reader), allowCopy: allowCopy,
                                allowPrint: p.allowPrint && app.trust.effectivePolicy.allowPrint,
                                allowExport: p.allowExport && app.trust.effectivePolicy.allowCopyOut,
                                onKey: keys,   // TRIAGE3-HOOK
                                onPrint: { ReaderPrint.print(reader, app: app) })   // READER2-HOOK
                }
                .task(id: "\(reader.header.id)|\(r.html.hashValue)") { await InlineImageStore.shared.load(reader, base: r.html, mail: mail) }
            } else {
                pad(Text(reader.header.preview ?? "").font(.callout).foregroundStyle(.secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func pad<V: View>(_ v: V) -> some View {
        v.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Protected body for the reading pane and message windows: kicks off decryption and renders its state.
struct ProtectedReaderBody: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var allowCopy: Bool
    var onKey: ((NSEvent) -> Bool)? = nil   // TRIAGE3-HOOK: see ReaderBody.onKey

    var body: some View {
        let p = reader.policy, id = reader.header.id, mb = reader.mailbox
        let st = ProtectedBodyStore.shared.state(for: id)
        let pc = app.protectedContent
        let view = ProtectedBodyView(state: st, outlookLink: reader.header.webLink,
                                     allowCopy: allowCopy,
                                     allowPrint: p.allowPrint && app.trust.effectivePolicy.allowPrint,
                                     allowExport: p.allowExport && app.trust.effectivePolicy.allowCopyOut,
                                     onKey: onKey ?? { e in MailKeys.handle(e, mail: app.mail) },   // TRIAGE3-HOOK
                                     onRetry: pc.map { pc in { pc.retry(itemId: id, mailbox: mb) } },
                                     onGrantAccess: pc.map { pc in { pc.requestAccess(itemId: id, mailbox: mb) } })
        Group {
            if case .decrypted = st {
                view.safeAreaInset(edge: .bottom) {   // PURVIEW-HOOK: decrypted attachments, licence-gated
                    ProtectedAttachmentsSection(itemId: id, mailbox: mb, coordinator: pc, allowCopyOut: app.trust.effectivePolicy.allowCopyOut).padding(.horizontal, 18).padding(.vertical, 6)
                }
            } else { view.padding(18).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .task(id: "\(id)|\(app.protectedDecryptEnabled)|\(app.protectedEpoch)") { pc?.open(itemId: id, mailbox: mb) }
    }
}

/// §17: per-message "Show original colours" in Dark Mode. Memory only: message ids are never persisted, and it
/// resets on lock/relaunch. Only changes the wrapper CSS (no effect on sanitising, remote blocking or rights).
@MainActor @Observable final class ReaderColours {
    static let shared = ReaderColours()
    private var original: Set<String> = []
    func showsOriginal(_ id: String) -> Bool { original.contains(id) }
    func toggle(_ id: String) { if original.contains(id) { original.remove(id) } else { original.insert(id) } }
}

struct OriginalColoursBar: View {
    @Environment(AppModel.self) private var app
    var messageId: String
    var original: Bool
    var body: some View {
        HStack(spacing: 8) {
            NSymbol("circle.lefthalf.filled").foregroundStyle(.secondary)
            Text(original ? L("Showing the original colours") : L("Colours adapted for Dark Mode")).foregroundStyle(.secondary)
            Spacer()
            Button(original ? L("Adapt for Dark Mode") : L("Show Original Colours")) { ReaderColours.shared.toggle(messageId) }
                .help(L("This message only"))
        }
        .font(.caption).padding(.horizontal, 18).padding(.vertical, 6)
        .background(app.theme.brand ? AnyShapeStyle(app.skin.soft) : AnyShapeStyle(.quaternary.opacity(0.35)))
    }
}

struct RemoteBar: View {
    @Environment(AppModel.self) private var app
    var count: Int
    var labelled: Bool
    var reader: ReaderState?
    var body: some View {
        HStack(spacing: 8) {
            NSymbol("photo.badge.exclamationmark").foregroundStyle(.secondary)
            Text("\(count) remote image\(count == 1 ? "" : "s") blocked")
            if labelled { Text(L("· stays blocked for labelled mail")).foregroundStyle(.secondary) }
            Spacer()
            if !labelled { Button(L("Load Images")) { if let r = reader { app.mail.allowImages(for: r) } else { app.mail.allowImages() } }.help(L("This message only (⇧I)")) }   // THREAD-HOOK: per message
            if !labelled, let r = reader, app.mail.canAlwaysLoadImages(r) {
                Button(L("Always From This Sender")) { app.mail.setAlwaysLoadImages(true, for: r) }
                    .help("Remote images from \(r.header.from?.address ?? "this sender") always load (never for labelled mail)")
            }
        }
        .font(.caption).padding(.horizontal, 18).padding(.vertical, 6)
        .background(app.theme.brand ? AnyShapeStyle(app.skin.soft) : AnyShapeStyle(.quaternary.opacity(0.35)))
    }
}

// MARK: - WKWebView with JavaScript off and remote loads blocked

/// Compiles the "block every http(s) load" rule list once. It covers what the regex sanitiser can't (CSS `url()`,
/// `<video poster>`, …): with it attached, nothing in the body reaches the network.
@MainActor enum RemoteBlocker {
    private static var list: WKContentRuleList?
    private static var failed = false
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    // url-filter is a restricted regex (no `|` alternation), hence one rule per scheme.
    static let rules = """
    [{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}]
    """

    static func get(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let list { done(list); return }
        if failed { done(nil); return }
        waiting.append(done)
        guard waiting.count == 1 else { return }
        Task { @MainActor in
            let l = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "cc-block-remote-v1",
                                                                                        encodedContentRuleList: rules)
            list = l
            failed = l == nil
            let w = waiting; waiting = []
            for f in w { f(l) }
        }
    }
}

final class ReaderWebView: WKWebView {
    var allowCopy = true
    /// The app has no Print / Save As command of its own; these only stop WebKit's ⌘P / ⌘S from bypassing the label.
    var allowPrint = true
    var allowExport = true
    var onKey: ((NSEvent) -> Bool)?
    /// READER2-HOOK: ⌘P prints the marked-up message (ReaderActions3.swift) instead of WebKit's bare page.
    var onPrint: (() -> Void)?
    /// THREAD-HOOK: conversation cards size the view to its content and let the stack's scroll view scroll.
    var forwardsScroll = false

    override func scrollWheel(with e: NSEvent) {
        if forwardsScroll, let next = nextResponder { next.scrollWheel(with: e) } else { super.scrollWheel(with: e) }
    }

    /// Only character keys and ⌫ go to mail triage; arrows/Return/Space keep scrolling the message.
    override func keyDown(with e: NSEvent) {
        if MailFocus.shared.readerKey(e, from: self) { return }   // A11Y-HOOK: Tab / ⇧Tab cycle panes, Esc → list
        let forward = e.keyCode == 51 || e.keyCode == 117
            || ((e.characters ?? "").unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains($0) }
                && !(e.characters ?? "").isEmpty && e.keyCode != 49)
        if forward, onKey?(e) == true { return }
        super.keyDown(with: e)
    }

    /// performKeyEquivalent runs for every ⌘-key in the window: only swallow copy & co. while the web view (or its
    /// content) is first responder, so the search field keeps ⌘A/⌘C.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let focused = (window?.firstResponder as? NSView).map { $0 === self || $0.isDescendant(of: self) } ?? false
        if focused, e.modifierFlags.contains(.command), let c = e.charactersIgnoringModifiers?.lowercased() {
            let denied = (!allowCopy && ["c", "x", "a"].contains(c))     // EXTRACT
                || (!allowExport && c == "s")                             // EXPORT
                || (!allowPrint && c == "p")                              // PRINT
            if denied { NSSound.beep(); return true }
            // READER2-HOOK: ⌘F / ⌘G find in this message; ⌘P prints with the label's markings.
            if c == "f", !e.modifierFlags.contains(.shift) { ReaderFind.open(self); return true }
            if c == "g" { ReaderFind.find(backwards: e.modifierFlags.contains(.shift)); return true }
            if c == "p", !e.modifierFlags.contains(.shift), let onPrint { onPrint(); return true }
        }
        return super.performKeyEquivalent(with: e)
    }

    // A11Y-HOOK: reading-pane focus ring.
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { MailFocus.shared.readerResponder(self, focused: true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { MailFocus.shared.readerResponder(self, focused: false) }
        return ok
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        if !allowCopy { menu.removeAllItems() }
        super.willOpenMenu(menu, with: event)
    }
}

struct MailWebView: NSViewRepresentable {
    var html: String
    var allowRemote: Bool
    var allowCopy: Bool
    var allowPrint = true
    var allowExport = true
    var onKey: (NSEvent) -> Bool
    var onPrint: (() -> Void)? = nil   // READER2-HOOK
    /// THREAD-HOOK: content height (points) after each load — measured by the app, page JavaScript stays off.
    var onHeight: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReaderWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.websiteDataStore = .nonPersistent()     // no cookies / storage from mail
        let w = ReaderWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = context.coordinator
        w.allowsLinkPreview = false
        w.allowsBackForwardNavigationGestures = false
        ReaderTools.shared.webView = w   // READER2-HOOK: find in message targets the latest reader
        MailFocus.shared.register(w)     // A11Y-HOOK: pane focus + persisted reader zoom (pageZoom)
        w.setAccessibilityLabel(L("Message body"))
        // §17: no white flash before the first paint / while the remote blocker compiles, and no white overscroll
        // in Dark Mode: the SwiftUI ground shows through until the document paints its own background.
        if w.responds(to: NSSelectorFromString("setDrawsBackground:")) || w.responds(to: NSSelectorFromString("_setDrawsBackground:")) { w.setValue(false, forKey: "drawsBackground") }
        w.underPageBackgroundColor = .clear
        return w
    }

    func updateNSView(_ w: ReaderWebView, context: Context) {
        w.allowCopy = allowCopy
        w.allowPrint = allowPrint
        w.allowExport = allowExport
        w.onKey = onKey
        w.onPrint = onPrint
        w.forwardsScroll = onHeight != nil   // THREAD-HOOK
        context.coordinator.onHeight = onHeight
        let key = "\(html.hashValue)|\(allowRemote)|\(allowCopy)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        let ucc = w.configuration.userContentController
        ucc.removeAllContentRuleLists()
        if allowRemote {
            w.loadHTMLString(html, baseURL: nil)
            return
        }
        // Don't load anything until the blocker is attached; if it can't compile, fall back to text only.
        let doc = html
        RemoteBlocker.get { [weak w, weak coord = context.coordinator] list in
            guard let w, coord?.loadedKey == key else { return }
            if let list {
                ucc.add(list)
                w.loadHTMLString(doc, baseURL: nil)
            } else {
                w.loadHTMLString(MailHTML.document(MailHTML.fromPlainText(MailWebView.textOnly(doc)), noSelect: !allowCopy)
                                 + "<!-- remote blocker unavailable: text only -->", baseURL: nil)
            }
        }
    }

    /// Crude tag strip for the no-blocker fallback (no element survives, so nothing can load).
    static func textOnly(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<(style|head)[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey = ""
        var onHeight: ((CGFloat) -> Void)?   // THREAD-HOOK

        /// THREAD-HOOK: app-evaluated (not page) script; allowsContentJavaScript stays false.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let onHeight else { return }
            let zoom = webView.pageZoom
            webView.evaluateJavaScript("(function(){var e=document.getElementById('nv-thread-end');if(e){return e.getBoundingClientRect().top+window.scrollY+8;}return document.body?document.body.offsetHeight:0;})()") { v, _ in
                if let h = (v as? NSNumber)?.doubleValue, h > 0 { onHeight(CGFloat(h) * zoom + 4) }
            }
        }

        /// Only the initial about:blank document load is allowed. A clicked http(s)/mailto link opens in the default
        /// app; everything else (meta refresh, form posts, frames) is cancelled.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            if action.navigationType == .linkActivated, let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            if url == nil || url?.scheme == "about" { return .allow }
            return .cancel
        }
    }
}
