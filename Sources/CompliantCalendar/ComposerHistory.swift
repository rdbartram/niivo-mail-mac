import SwiftUI
import MailCore
import CalendarCore

// COMPOSE2: the quoted history under the user's text — a collapsed "… history" row; expanded it is a read-only,
// sanitised render (no scripts, no remote images). The bytes that are saved and sent are never taken from here.

struct ComposerHistoryBlock: View {
    @Environment(\.colorScheme) private var colorScheme   // §17: reader Dark Mode
    @Environment(AppModel.self) private var app
    var composer: ComposerState

    var body: some View {
        let c = composer
        let e = c.editor
        let mail = app.mail
        if c.omitHistory && c.kind != .new {
            HStack(spacing: 8) {
                Text("Sent without the quoted history (Mail Settings → Send As → Replying).").font(.caption).foregroundStyle(.secondary)
                if c.savedAt == nil { Button("Include history") { c.omitHistory = false }.nvButton(app.skin, .quiet).font(.caption) }
                Spacer()
            }
        } else if c.kind != .new || e.historyHTML != nil {
            let gate = blockedReason
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        guard gate == nil else { return }
                        if e.historyHTML == nil { Task { await mail.saveDraft(c) } }   // the history comes with the first save
                        e.historyExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            NSymbol(e.historyExpanded ? "chevron.down" : "ellipsis", size: 12)
                            Text(title).lineLimit(1)
                        }
                    }
                    .nvButton(app.skin, .quiet).font(.caption)
                    .disabled(gate != nil)
                    .help(gate ?? (e.historyExpanded ? "Hide the quoted history" : "Show the quoted history (read-only; sent exactly as it is)"))
                    .accessibilityLabel(e.historyExpanded ? "Hide quoted history" : "Show quoted history")
                    Spacer()
                }
                if let gate { Text(gate).font(.caption).foregroundStyle(.secondary) }
                if e.historyExpanded, gate == nil {
                    if let h = e.historyHTML {
                        let s = HTMLSanitizer.sanitize(h, allowRemote: false)
                        MailWebView(html: MailHTML.document(s.html, noSelect: !allowCopy, dark: colorScheme == .dark, brand: app.theme.brand),
                                    allowRemote: false, allowCopy: allowCopy, onKey: { _ in false })
                            .frame(minHeight: 180, idealHeight: 280)
                            .overlay { Rectangle().strokeBorder(app.skin.hair2, lineWidth: 1) }
                            .accessibilityLabel("Quoted history, read-only")
                    } else {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Saving the draft to fetch the history…").font(.caption) }
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var title: String {
        if let o = composer.original, composer.editor.historyHTML == nil {
            let who = originalPolicy?.redactDetails == true ? "the sender" : (o.from?.display ?? "the sender")
            return "… history — \(who)'s message is quoted below your text when the draft is saved"
        }
        return composer.editor.historyExpanded ? "Hide history" : "… history"
    }

    private var originalPolicy: ContentPolicy? {
        composer.original.map { app.mail.policy(for: $0, mailbox: app.mail.store?.mailbox(forFolder: $0.folderId) ?? "me") }
    }

    /// Expanding shows the original's content: not for private/redacted or protected originals (it still goes out).
    private var blockedReason: String? {
        guard let p = originalPolicy else { return nil }
        if p.redactDetails { return "The quoted history of a private message isn't shown here. It's still included." }
        if p.bodyIsProtected { return "The quoted history of a protected message isn't shown here. It's still included." }
        return nil
    }

    private var allowCopy: Bool { originalPolicy?.allowCopy ?? true }
}
