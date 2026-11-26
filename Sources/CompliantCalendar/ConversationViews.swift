import SwiftUI
import AppKit
import CalendarCore
import MailCore

// THREAD-HOOK: the conversation reader stack (Gmail order: newest at the bottom unless "newest on top").
// State: ConversationHub.swift. Each card uses the message's own ReaderState and reader pieces.

struct ConversationReader: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState

    var body: some View {
        let hub = ConversationHub.shared
        let mail = app.mail
        let members = hub.ordered(reader.thread)
        let threadPolicy = hub.policy(over: reader, mail: mail)
        // COMPOSE-LAYOUT: replying inline to a member → the composer sits under the stack and gets most of the height;
        // only the answered card stays expanded (derived — the user's own expansion returns on close).
        let composer: ComposerState? = {
            guard app.theme.brand, ComposeHost.shared.placement == .inline, let c = mail.composer,
                  let o = c.original, members.contains(where: { $0.id == o.id }) else { return nil }
            return c
        }()
        let expanded = ComposeLayout.replyExpansion(expanded: hub.expanded, members: members.map(\.id), answering: composer?.original?.id)
        GeometryReader { geo in
            VStack(spacing: 0) {
                header(threadPolicy, count: members.count)
                Rectangle().fill(app.theme.brand ? app.skin.hair2 : Color.secondary.opacity(0.25)).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(members) { m in
                                ConversationCard(message: m, rowReader: reader, isExpanded: expanded.contains(m.id), replying: composer != nil).id(m.id)
                                Rectangle().fill(app.theme.brand ? app.skin.hair2 : Color.secondary.opacity(0.18)).frame(height: 1)
                            }
                        }
                    }
                    .onChange(of: hub.focusedId) { _, id in
                        if let id { NMotion.with(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .top) } }
                    }
                    .onChange(of: composer?.original?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .top) }
                    }
                    .task(id: reader.header.conversationId) {
                        // Open at the latest message (bottom in Gmail order).
                        if let last = hub.newestOnTop ? members.first : members.last { proxy.scrollTo(last.id, anchor: .top) }
                    }
                }
                .frame(height: composer == nil ? nil : geo.size.height * ComposeLayout.originalMaxFraction)
                .frame(maxHeight: composer == nil ? .infinity : nil)
                if let c = composer {
                    ComposerView(composer: c, inline: true, originalInStack: true)
                        .overlay(alignment: .top) { Rectangle().fill(app.theme.brand ? app.skin.ink : Color.secondary.opacity(0.3)).frame(height: 1) }
                }
            }
        }
        .background(app.theme.brand ? AnyShapeStyle(app.skin.card) : AnyShapeStyle(.background))
        .task(id: "\(reader.header.id)|\(reader.thread.map(\.id).joined(separator: ","))") { hub.attach(reader, mail: mail) }
        .onAppear { hub.active = true }
        .onDisappear { hub.active = false }
    }

    private func header(_ p: ContentPolicy, count: Int) -> some View {
        let hub = ConversationHub.shared
        let mail = app.mail
        let own = reader.policy
        return VStack(alignment: .leading, spacing: 8) {
            ReaderLabelLine(policy: p, origin: nil)   // strictest label: restriction notices keep a line
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(own.redactDetails ? L("Private message") : (reader.header.subject.isEmpty ? L("(no subject)") : reader.header.subject))
                    .font(app.theme.brand ? app.skin.sans(NV.Size.title) : .title2.weight(.semibold))
                    .tracking(app.skin.titleTrack(NV.Size.title))
                    .fontDesign(app.theme.design)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(app.skin.caps(L("%d messages", count)))
                    .font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .caption).foregroundStyle(.secondary)
                if p.labelState != .unlabeled { LabelPill(policy: p) }   // strictest label in the conversation (compliance)
                Spacer()
                HStack(spacing: 4) {
                    Button { mail.run(.archive) } label: { NSymbol("archivebox", size: 14) }
                        .help(L("Archive conversation (E)")).accessibilityLabel(L("Archive conversation"))
                    Button { mail.run(.delete) } label: { NSymbol("trash", size: 14) }
                        .help(L("Delete conversation (#)")).accessibilityLabel(L("Delete conversation"))
                    Button { mail.triage(.markRead(false)) } label: { NSymbol("envelope.badge", size: 14) }
                        .help(L("Mark conversation unread")).accessibilityLabel(L("Mark conversation unread"))
                    Menu {
                        Button(L("Expand All")) { hub.expandAll(mail: mail) }
                        Button(L("Collapse All")) { hub.collapseAll(mail: mail) }
                        Divider()
                        Toggle(L("Newest on Top"), isOn: Binding(get: { hub.newestOnTop }, set: { hub.newestOnTop = $0 }))
                        Toggle(L("Group by Conversation"), isOn: Binding(get: { mail.groupConversations }, set: { mail.groupConversations = $0 }))
                    } label: { NSymbol("ellipsis.circle", size: 14) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("Conversation options"))
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 12) {
                Button(L("Expand all")) { hub.expandAll(mail: mail) }
                Button(L("Collapse all")) { hub.collapseAll(mail: mail) }
            }
            .buttonStyle(.borderless)
            .font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .caption)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

/// One message of the stack: a one-line header when collapsed; the message's own reader pieces when expanded.
struct ConversationCard: View {
    @Environment(AppModel.self) private var app
    var message: MailMessage
    var rowReader: ReaderState
    /// Expanded in the stack (ConversationHub.expanded, or only the answered card while replying — COMPOSE-LAYOUT).
    var isExpanded: Bool
    /// While replying the stack is derived (only the answered card open): taps don't toggle hidden state.
    var replying = false

    var body: some View {
        let hub = ConversationHub.shared
        let mail = app.mail
        let m = message
        let mb = mail.store?.mailbox(forFolder: m.folderId) ?? rowReader.mailbox
        let st = hub.state(for: m.id, mail: mail)
        let p = st?.policy ?? mail.policy(for: m, mailbox: mb)
        let focused = hub.focusedId == m.id
        Group {
            if isExpanded { expanded(st, p) } else { collapsed(p) }
        }
        .overlay(alignment: .leading) {
            if focused { Rectangle().fill(app.theme.accent).frame(width: 3) }
        }
    }

    private func collapsed(_ p: ContentPolicy) -> some View {
        let m = message
        let mail = app.mail
        let b = app.theme.brand
        return HStack(spacing: 8) {
            SenderAvatar(who: p.redactDetails ? nil : m.from, size: 22)
            Text(p.redactDetails ? L("Private") : (m.from?.display ?? L("(no sender)")))
                .font(b ? app.skin.sans(NV.Size.bodySm, m.isRead ? .regular : .semibold) : .callout.weight(m.isRead ? .regular : .semibold))
                .lineLimit(1).layoutPriority(1)
            if p.bodyIsProtected { NSymbol("lock.fill", size: 9, label: L("Encrypted")).foregroundStyle(.secondary) }
            Text(p.redactDetails || !p.allowOfflineDetails ? "" : (m.preview ?? ""))
                .font(b ? app.skin.sans(NV.Size.bodySm) : .callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            LabelGlyphMark(policy: p, mark: ListRowLayout.labelMark(LabelDisplay.decide(p, origin: nil), rank: nil,
                                                                   confidentialRank: ListLabelRanks.shared.confidential(mail.compliance),
                                                                   showChips: false))   // same rule as the list
            if m.hasAttachments { NSymbol("paperclip", size: 10, label: L("Attachment")).foregroundStyle(.secondary) }
            Text(MessageRowView.time(m.received)).font(b ? app.skin.mono(NV.Size.labelSm) : .caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { if !replying { ConversationHub.shared.toggle(m.id, mail: mail) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(L("Expands the message"))
    }

    @ViewBuilder private func expanded(_ st: ReaderState?, _ p: ContentPolicy) -> some View {
        let m = message
        let mail = app.mail
        let allowCopy = p.allowCopy && app.trust.effectivePolicy.allowCopyOut
        VStack(alignment: .leading, spacing: 0) {
            if let h = p.headerMarking {
                HeaderMarking(text: h, color: p.label.map { Color(hex: $0.hexColor, fallback: .red) }).padding(.horizontal, 18).padding(.top, 8)
            }
            cardHeader(m, p, st)
            // COMPOSE-LAYOUT: the reply composer sits under the stack (ConversationReader), not inside this card.
            if let st {
                ReaderExtrasBlock(reader: st)
                if st.header.id == mail.reader?.header.id {   // the pane's own message keeps the reader strips
                    AIReaderStrip(reader: st, allowCopy: allowCopy)   // AI-HOOK: thread summary, once requested
                    RelatedStrip(reader: st)   // STORY-HOOK
                }
                if !p.redactDetails && !st.header.attachments.isEmpty { AttachmentChips(reader: st).padding(.horizontal, 18).padding(.bottom, 6) }
                ConversationBody(reader: st, allowCopy: allowCopy)
                AttachmentPreviewStrip(reader: st).id(st.header.id)   // PREVIEW-HOOK: same gate as the single reader
                if st.header.id == mail.reader?.header.id { AISmartReplyRow(reader: st) }   // AI-HOOK: three replies (COMPOSE-LAYOUT)
                if let f = p.footerMarking { FooterMarking(text: f) }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(18)
            }
        }
        .overlay { if let w = p.watermark { Watermark(text: w) } }
        .modifier(Selectable(enabled: allowCopy))
        .task(id: m.id) { ConversationHub.shared.load(m.id, mail: mail) }
    }

    private func cardHeader(_ m: MailMessage, _ p: ContentPolicy, _ st: ReaderState?) -> some View {
        let mail = app.mail
        let hub = ConversationHub.shared
        let b = app.theme.brand
        let to = (m.toRecipients + m.ccRecipients).map { mail.meAddresses.contains($0.address.lowercased()) ? L("me") : $0.display }
        return HStack(alignment: .top, spacing: 10) {
            SenderAvatar(who: p.redactDetails ? nil : m.from, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.redactDetails ? L("Private") : (m.from?.display ?? L("(no sender)")))
                    .font(b ? app.skin.sans(NV.Size.body, .medium) : .callout.weight(.semibold))
                    .personCard(p.redactDetails ? nil : m.from)
                if !p.redactDetails, !to.isEmpty {
                    Text(L("to %@", to.joined(separator: ", "))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !replying { hub.toggle(m.id, mail: mail) } }
            Spacer(minLength: 6)
            ReaderLabelLine(policy: p, origin: m.labelOrigin).frame(maxWidth: 220)
            LabelPill(policy: p, origin: m.labelOrigin)   // COMPOSE-LAYOUT: pill by the date, always visible
            Text(A11yPrefs.shared.regional.dateTime(m.received)).font(b ? app.skin.mono(NV.Size.labelSm) : .caption).foregroundStyle(.secondary)
            if let st {
                // The single reader's own actions on THIS message (reply / all / forward by id, ⋯ menu: print, source,
                // junk, meeting, remote images …), gated by its own policy.
                ReaderActions(reader: st)
                TaskFromMessageButton(message: st.header, policy: p)   // PEOPLE-HOOK
            } else { HStack(spacing: 2) {
                // Reply / Reply all / Forward on THIS message, gated by its own usage rights.
                Button { hub.focusedId = m.id; mail.reply(.reply, to: m.id) } label: { NSymbol("arrowshape.turn.up.left", size: 13) }
                    .disabled(!MailActionRights.allows(.reply, policy: p)).accessibilityLabel(L("Reply"))
                    .help(MailActionRights.help(.reply, policy: p, otherwise: "Reply"))
                Button { hub.focusedId = m.id; mail.reply(.replyAll, to: m.id) } label: { NSymbol("arrowshape.turn.up.left.2", size: 13) }
                    .disabled(!MailActionRights.allows(.replyAll, policy: p)).accessibilityLabel(L("Reply All"))
                    .help(MailActionRights.help(.replyAll, policy: p, otherwise: "Reply all"))
                Button { hub.focusedId = m.id; mail.reply(.forward, to: m.id) } label: { NSymbol("arrowshape.turn.up.right", size: 13) }
                    .disabled(!MailActionRights.allows(.forward, policy: p)).accessibilityLabel(L("Forward"))
                    .help(MailActionRights.help(.forward, policy: p, otherwise: "Forward"))
            }
            .buttonStyle(.borderless) }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}

/// A member's body. Open bodies render in a content-sized web view with quoted history behind "•••"; every other
/// state (private, protected / decrypt-on-demand, unknown label, loading, error) is the single reader's own ReaderBody.
struct ConversationBody: View {
    @Environment(\.colorScheme) private var colorScheme   // §17: reader Dark Mode
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var allowCopy: Bool

    var body: some View {
        let p = reader.policy
        let mail = app.mail
        let hub = ConversationHub.shared
        let id = reader.header.id
        if !MailThreads.mayFetchBody(p) || reader.loading || reader.error != nil {
            // Protected bodies decrypt on demand in their own (scrolling) view; notices are short.
            ReaderBody(reader: reader, allowCopy: allowCopy).frame(height: p.bodyIsProtected ? 420 : 90)
        } else if let r = mail.rendered(reader) {
            let parts = split(r.html)
            let html = InlineImageStore.shared.html(for: reader, base: hub.showQuoted.contains(id) ? r.html : parts.main)
            VStack(alignment: .leading, spacing: 0) {
                if r.blocked > 0 && !mail.remoteAllowed(for: reader) {
                    RemoteBar(count: r.blocked, labelled: p.labelState != .unlabeled, reader: reader)
                }
                MailWebView(html: MailHTML.document(html + Self.sentinel, noSelect: !allowCopy, dark: colorScheme == .dark, brand: app.theme.brand),
                            allowRemote: mail.remoteAllowed(for: reader), allowCopy: allowCopy,
                            allowPrint: p.allowPrint && app.trust.effectivePolicy.allowPrint,
                            allowExport: p.allowExport && app.trust.effectivePolicy.allowCopyOut,
                            onKey: { e in MailKeys.handle(e, mail: mail) },
                            onPrint: { ReaderPrint.print(reader, app: app) },
                            onHeight: { h in hub.heights[id] = h })
                    .frame(height: min(max(hub.heights[id] ?? 320, 48), 40_000))
                if parts.hasQuoted {
                    let shown = hub.showQuoted.contains(id)
                    Button { if shown { hub.showQuoted.remove(id) } else { hub.showQuoted.insert(id) } } label: {
                        Text("•••").font(.caption.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 1)
                            .background(app.theme.brand ? AnyShapeStyle(app.skin.soft) : AnyShapeStyle(.quaternary), in: Capsule())
                    }
                    .buttonStyle(.plain).padding(.horizontal, 18).padding(.bottom, 8)
                    .help(shown ? L("Hide quoted text") : L("Show quoted text"))
                    .accessibilityLabel(shown ? L("Hide quoted text") : L("Show quoted text"))
                }
            }
            .task(id: "\(id)|\(r.html.hashValue)") { await InlineImageStore.shared.load(reader, base: r.html, mail: mail) }
        } else {
            Text(reader.header.preview ?? "").font(.callout).foregroundStyle(.secondary).padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// End marker measured after load (not clamped to the viewport like scrollHeight); inert markup, no script.
    static let sentinel = "<div id=\"nv-thread-end\" style=\"clear:both;height:0;margin:0;padding:0\"></div>"

    /// Split the sanitised HTML; plain-text bodies split on the text, then convert.
    private func split(_ html: String) -> (main: String, hasQuoted: Bool) {
        let s = QuotedHistory.split(html: html)
        if s.quoted != nil { return (s.main, true) }
        if !reader.bodyIsHTML, let body = reader.body {
            let t = QuotedHistory.split(text: body)
            if t.quoted != nil { return (MailHTML.fromPlainText(t.main), true) }
        }
        return (html, false)
    }
}
