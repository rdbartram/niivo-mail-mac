import SwiftUI
import CalendarCore
import MailCore

/// THREAD-HOOK: one conversation in the list. Renders through MessageRowView (2026-11-20, docs/COMPOSE-LAYOUT.md) so
/// it has the same fixed heights, density, clean list, avatar and badge rules as single messages. Facts come from the
/// store-grouped summary: participants over the reader set, count / unread / flag over the folder, the strictest label
/// over the reader set (MailThreads); the snippet also needs the newest message's own policy.
struct ConversationRow: View {
    var row: MailRow
    var thread: MailThreadSummary
    var selected: Bool

    var body: some View {
        MessageRowView(row: row, selected: selected, thread: thread)
    }
}
