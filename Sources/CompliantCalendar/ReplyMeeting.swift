import SwiftUI
import CalendarCore
import MailCore

// COMPOSE2: Reply with Meeting — the calendar editor, prefilled from the message (MeetingFromMail in MailCore).

extension AppModel {
    /// Opens the event editor in Calendar with the thread's people invited, the subject, a pointer back to the message
    /// and a Teams meeting switched on. Nothing is sent until the user saves the event.
    func replyWithMeeting(messageId: String) {
        guard let store = mail.store, let m = try? store.message(id: messageId, includeBody: false) else { return }
        let mb = store.mailbox(forFolder: m.folderId)
        let p = mail.policy(for: m, mailbox: mb)
        guard MailActionRights.allows(.replyAll, policy: p) else {
            mail.toast(MailToast(text: MailActionRights.deniedReason, symbol: "lock.fill")); return
        }
        newEvent()   // next half hour, default calendar; opens the editor
        guard showEditor else { return }
        let mine = Set(mail.settings.identities.map(\.address) + [mail.me?.address ?? ""])
        let d = MeetingFromMail.draft(from: m, mine: mine, calendarId: editorDraft.calendarId, start: editorDraft.start,
                                      redact: p.redactDetails)
        editorDraft = d
        section = .calendar
    }
}
