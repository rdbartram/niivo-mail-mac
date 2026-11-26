import SwiftUI
import MailCore

// Search window: one click / ↩ on a hit opens the reader in place (right column); double-click opens the message
// window; "Show in Mail" reveals it in the main window. Same reader + policy path as a message window
// (MessageWindows.load → ReaderContent; capture shield per the message's rights). Nothing opens until the user asks:
// arrow keys only move the highlight.

@MainActor @Observable final class SearchReaderState {
    static let shared = SearchReaderState()
    var opened: String?
    /// The search window's capture shield includes the opened reader's rights; unknown (still loading) = blocked.
    var blocksCapture: Bool {
        guard let id = opened else { return false }
        return MessageWindows.shared.readers[id].map { $0.policy.preventScreenCapture } ?? true
    }
}

struct SearchReaderColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    var body: some View {
        if let id = SearchReaderState.shared.opened {
            Rectangle().fill(skin.hair).frame(width: 1)
            SearchReaderPane(messageId: id).frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity)
        }
    }
}

private struct SearchReaderPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var messageId: String
    var body: some View {
        let mail = model.mail
        let r = MessageWindows.shared.readers[messageId]
        // No nested SecondaryWindow: the shield is window-level and driven by SearchWindowRoot (blocksCapture).
        Group {
            VStack(spacing: 0) {
                WindowHeader(eyebrow: r.map { MailboxDisplay.title($0.mailbox) } ?? "Message",
                             title: r.map { $0.policy.redactDetails ? "Private message" : $0.header.subject } ?? "Message") {
                    HStack(spacing: 2) {
                        NIconButton("arrow.up.forward.app", label: "Show in Mail", help: "Show in the mail window") {
                            model.openMailMessage(messageId, raise: true)
                        }
                        NIconButton("macwindow", label: "Open in its own window", help: "Open in its own window (double-click)") {
                            openWindow(id: "message", value: messageId)
                        }
                        NIconButton("xmark", label: "Close reader", help: "Close (esc)") { SearchReaderState.shared.opened = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                if let r { ReaderContent(reader: r, paneHost: false) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .task(id: messageId) { await MessageWindows.shared.load(messageId, mail: mail) }
        .onChange(of: messageId) { old, _ in MessageWindows.shared.readers[old] = nil }
        .onDisappear { MessageWindows.shared.readers[messageId] = nil }
    }
}
