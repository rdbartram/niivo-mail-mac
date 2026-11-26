import SwiftUI
import MailCore

// COMPOSE2: scheduled (send later) messages — cancel puts the draft back in Drafts.

extension MailModel {
    /// The default reply (R, ⌘R, toolbar Reply): reply all when set and allowed, else reply.
    func defaultReplyKind() -> MailDraft.Kind {
        guard composerPrefs.defaultReplyAll, let store, let id = selectedMessageId,
              let o = try? store.message(id: id, includeBody: false),
              MailActionRights.allows(.replyAll, policy: policy(for: o, mailbox: store.mailbox(forFolder: o.folderId))) else { return .reply }
        return .replyAll
    }

    /// A message waiting to be sent later: client-side (draft with a time) or held by Exchange (Outbox).
    func isScheduled(_ m: MailMessage) -> Bool {
        if m.scheduledSend != nil { return true }
        guard let store, let f = try? store.folder(id: m.folderId) else { return false }
        return f.wellKnown == .outbox
    }

    func cancelScheduledSend(id: String) {
        guard let sync else { return }
        Task {
            do {
                let local = try await sync.cancelScheduledSend(id: id)
                toast(MailToast(text: local ? "Scheduled send cancelled — the draft is in Drafts"
                                            : "Moved back to Drafts — it won't be sent", symbol: "clock.badge.xmark"))
                refreshFolders(); reloadList()
            } catch {
                toast(MailToast(text: "Exchange wouldn't release the scheduled message. Delete it from Outbox in Outlook to stop it.",
                                symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }
}
