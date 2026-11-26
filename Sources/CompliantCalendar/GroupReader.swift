import SwiftUI
import CalendarCore
import MailCore

// MARK: - Groups: reader (read-only; same label gates as the mail reader)

struct GroupReaderView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let g = app.mail.groups
        if let t = g.thread {
            // Strictest policy over the thread decides the capture shield (as ReaderView does per message).
            let app = app
            GroupThreadContent(thread: t)
                .captureShield(t.merged.preventScreenCapture) { $0.environment(app).skinned(app.skin) }
        } else {
            BrandEmptyState(symbol: "bubble.left.and.bubble.right", eyebrow: "Group", title: "No conversation selected.")
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(app.theme.brand ? app.skin.card : Color.clear)
        }
    }
}

struct GroupThreadContent: View {
    @Environment(\.colorScheme) private var colorScheme   // §17: reader Dark Mode
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var thread: GroupThreadState
    var body: some View {
        let g = app.mail.groups
        let p = thread.merged
        // Copy-out only if every post's label AND the device trust policy allow it.
        let allowCopy = p.allowCopy && app.trust.effectivePolicy.allowCopyOut
        VStack(spacing: 0) {
            if let h = Self.marking(p) { HeaderMarking(text: h) }   // unreadable labels keep the restricted marking; a foreign id doesn't
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.conversation.topic.isEmpty ? "(no subject)" : thread.conversation.topic)
                        .font(skin.brand ? skin.sans(20) : .title3.weight(.semibold)).foregroundStyle(skin.ink)
                    MonoLabel("\(thread.posts.count) post\(thread.posts.count == 1 ? "" : "s") · \(g.selectedGroup?.displayName ?? "")", size: NV.Size.labelSm)
                }
                Spacer()
                NButton("Reply", systemImage: "arrowshape.turn.up.left", kind: .quiet) { g.startReply() }
                    .disabled(thread.replyRefusal != nil || thread.loading || g.pendingPost != nil)
                    .help(thread.replyRefusal ?? "Reply to this conversation")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .hairline(skin)
            if let pending = g.pendingPost { GroupPendingBar(text: pending.text, deadline: pending.deadline) }
            if let n = g.notice {
                HStack { NSymbol("checkmark.circle", size: 11); Text(n); Spacer(); Button("OK") { g.clearNotice() }.buttonStyle(.plain) }
                    .font(.caption).padding(.horizontal, 18).padding(.vertical, 6)
            }
            if thread.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let e = thread.error {
                Notice(icon: "wifi.exclamationmark", text: e).padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                MailWebView(html: MailHTML.document(GroupThreadHTML.render(thread), noSelect: !allowCopy, dark: colorScheme == .dark, brand: app.theme.brand),
                            allowRemote: false, allowCopy: allowCopy,
                            allowPrint: p.allowPrint && app.trust.effectivePolicy.allowPrint,
                            allowExport: p.allowExport && app.trust.effectivePolicy.allowCopyOut,
                            onKey: { _ in false })   // not MailKeys: the mail selection isn't what's on screen
            }
            if let f = p.footerMarking { FooterMarking(text: f) }
        }
        .overlay { if let w = p.watermark { Watermark(text: w) } }
        .background(app.theme.brand ? AnyShapeStyle(skin.card) : AnyShapeStyle(.background))
    }
}

/// One HTML document for the thread. Each post body is sanitised (scripts, handlers, remote loads removed; the web
/// view also blocks every remote load). A post whose label hides its content is replaced by a notice: its body never
/// reaches the web view.
enum GroupThreadHTML {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The part between <body> and </body> when a post is a full document.
    static func inner(_ html: String) -> String {
        guard let open = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) else { return html }
        let rest = html[open.upperBound...]
        if let close = rest.range(of: "</body\\s*>", options: [.regularExpression, .caseInsensitive]) { return String(rest[..<close.lowerBound]) }
        return String(rest)
    }

    /// Why a post's content stays hidden, or nil when it may be shown (same order as ReaderBody).
    static func gate(_ p: ContentPolicy) -> String? {
        if p.redactDetails { return "Marked private. Details are hidden." }
        if p.bodyIsProtected { return "This post is protected by its sensitivity label. Open it in Outlook on the web." }
        if case .unknown = p.labelState { return "This post's label isn't in your synced policy, or couldn't be read. Content stays hidden." }
        return nil
    }

    static func render(_ t: GroupThreadState) -> String {
        t.posts.map { post in
            let who = escape(post.from?.display ?? post.sender?.display ?? "Unknown sender")
            let when = post.received.map { escape($0.formatted(date: .abbreviated, time: .shortened)) } ?? ""
            var onBehalf = ""
            if let s = post.sender, let f = post.from, s.address.lowercased() != f.address.lowercased() { onBehalf = " (sent by \(escape(s.display)))" }
            let att = post.hasAttachments ? " · attachments in Outlook on the web" : ""
            let header = "<div style=\"font-size:12px;opacity:.7;margin:0 0 6px\"><b>\(who)</b>\(onBehalf) · \(when)\(att)</div>"
            let content: String
            if let notice = gate(t.policies[post.id] ?? GroupThreadHTML.missingPolicy) { content = "<p><i>\(escape(notice))</i></p>" }
            else if post.bodyIsHTML { content = inner(HTMLSanitizer.sanitize(post.body, allowRemote: false).html) }
            else { content = MailHTML.fromPlainText(post.body) }
            return "<section style=\"padding:0 0 14px;margin:0 0 14px;border-bottom:1px solid #8883\">\(header)\(content)</section>"
        }.joined()
    }

    /// A post without a computed policy is never shown (fail closed).
    static var missingPolicy: ContentPolicy {
        var p = ContentPolicy.open
        p.labelState = .unknown(id: GroupPostPolicy.unreadableLabelId)
        return p
    }
}

struct GroupPendingBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var text: String
    var deadline: Date
    var body: some View {
        HStack(spacing: 8) {
            NSymbol("paperplane", size: 11)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("\(text) \(max(0, Int(deadline.timeIntervalSince(ctx.date).rounded(.up)))) s")
            }
            Spacer()
            Button("Undo") { app.mail.groups.undoPending() }.nvButton(skin, .quiet)
        }
        .font(.caption).padding(.horizontal, 18).padding(.vertical, 6)
        .background(skin.brand ? AnyShapeStyle(skin.soft) : AnyShapeStyle(.quaternary.opacity(0.35)))
    }
}

// MARK: - Groups: composer (explicit Send → undo window → one POST)

struct GroupComposerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var composer: GroupComposerState
    var body: some View {
        @Bindable var c = composer
        let g = app.mail.groups
        VStack(alignment: .leading, spacing: 12) {
            let title = c.kind == .new ? "New conversation" : "Reply to conversation"
            if skin.brand { MonoLabel(title, bracket: true) } else { Text(title).font(.title3.weight(.semibold)) }
            Text("To: \(g.selectedGroup?.displayName ?? "group"). Every member can read this.")
                .font(skin.brand ? skin.sans(NV.Size.body) : .callout).foregroundStyle(skin.muted)
            if c.kind == .new { NField("Topic", text: $c.topic, label: "Topic", style: .bordered) }
            TextEditor(text: $c.body)
                .font(skin.brand ? skin.sans(NV.Size.body) : .body)
                .frame(minHeight: 180)
                .overlay(Rectangle().strokeBorder(skin.brand ? skin.hair : Color.secondary.opacity(0.3), lineWidth: 1))
            if let e = c.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    NSymbol("exclamationmark.triangle", size: 11).foregroundStyle(skin.brand ? skin.accentInk : Color.orange)
                    Text(e).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if g.needsWriteConsent && g.grant != nil {
                    Button("Allow posting…") { Task { await g.grantWrite() } }.nvButton(skin, .quiet).font(.caption)
                }
            }
            HStack {
                Text("Sent after \(GroupsModel.undoSeconds) s. You can undo until then.").font(.caption).foregroundStyle(skin.muted)
                Spacer()
                NButton("Cancel", kind: .quiet) { g.composer = nil }.keyboardShortcut(.cancelAction)
                NButton("Send") { g.send(c) }.keyboardShortcut(.return, modifiers: .command).disabled(!c.canSend)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(skin.brand ? skin.card : Color.clear)
    }
}

extension GroupThreadContent {
    /// The tenant's marking always; the synthetic "label unavailable — restricted" one only for a label that couldn't
    /// be read (fail closed), not for another organisation's id outside our tree (LabelProvenance.swift).
    static func marking(_ p: ContentPolicy) -> String? {
        guard let h = p.headerMarking else { return nil }
        guard h == LabelDisplay.unknownMarking else { return h }
        if case .unknown(let id) = p.labelState, id == GroupPostPolicy.unreadableLabelId { return h }
        return nil
    }
}
