import SwiftUI
import AppKit

// Hook for label-encrypted bodies (mail + calendar). The MIP SDK work plugs in by publishing a state per item id
// into `ProtectedBodyStore.shared`; until it does, items show the neutral "opening" placeholder with an
// Open-in-Outlook fallback. The view never decides whether decryption is allowed: callers only reach it when
// `ContentPolicy.bodyIsProtected` is true, and `decrypted(html:)` is still rendered through the sanitising
// `MailHTML.document` wrapper with the item's copy/print/export rights.

enum ProtectedBodyState: Equatable, Sendable {
    case decrypting
    case decrypted(html: String)
    case notPermitted
    case unavailable(reason: String)
    /// Licence / network error: the view offers "Try again".
    case retryable(reason: String)
    /// The Rights Management token needs an interactive sign-in / consent: the view offers "Grant access…".
    case needsAccess(reason: String)
}

@MainActor @Observable final class ProtectedBodyStore {
    static let shared = ProtectedBodyStore()
    /// Keyed by message / event id. Missing = `.decrypting` (the MIP layer hasn't reported yet).
    var states: [String: ProtectedBodyState] = [:]
    func state(for id: String) -> ProtectedBodyState { states[id] ?? .decrypting }
}

struct ProtectedBodyView: View {
    @Environment(\.colorScheme) private var colorScheme   // §17: reader Dark Mode
    @Environment(\.skin) private var skin
    var state: ProtectedBodyState
    var outlookLink: URL?
    var allowCopy = false
    var allowPrint = false
    var allowExport = false
    var onKey: (NSEvent) -> Bool = { _ in false }
    var onRetry: (() -> Void)?
    var onGrantAccess: (() -> Void)?

    var body: some View {
        switch state {
        case .decrypted(let html):
            MailWebView(html: MailHTML.document(html, noSelect: !allowCopy, dark: colorScheme == .dark, brand: skin.brand),
                        allowRemote: false, allowCopy: allowCopy, allowPrint: allowPrint, allowExport: allowExport, onKey: onKey)
        case .decrypting:
            placeholder(glyph: "lock.shield", title: "Protected message — decrypting…", detail: nil, busy: true)
        case .notPermitted:
            placeholder(glyph: "lock.shield", title: "You don't have rights to view this message.",
                        detail: "Its protection doesn't grant your account the View right.", busy: false)
        case .unavailable(let reason):
            placeholder(glyph: "lock.shield", title: "Protected message", detail: reason, busy: false)
        case .retryable(let reason):
            placeholder(glyph: "exclamationmark.shield", title: "Couldn't open this protected message", detail: reason, busy: false,
                        action: onRetry.map { ("Try again", $0) })
        case .needsAccess(let reason):
            placeholder(glyph: "person.badge.key", title: "Rights Management needs you to sign in", detail: reason, busy: false,
                        action: onGrantAccess.map { ("Grant access…", $0) })
        }
    }

    private func placeholder(glyph: String, title: String, detail: String?, busy: Bool,
                             action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                NSymbol(glyph, size: 14).foregroundStyle(skin.ink)
                Text(title).font(skin.brand ? skin.sans(NV.Size.body, .medium) : .callout.weight(.medium)).foregroundStyle(skin.ink)
                if busy && skin.brand { NiivoCursor(size: 8, color: skin.muted) }
                else if busy { ProgressView().controlSize(.small) }
            }
            if let detail { Text(detail).font(skin.brand ? skin.sans(NV.Size.bodySm) : .caption).foregroundStyle(skin.muted) }
            if let action { Button(action.0, action: action.1).controlSize(.small) }
            if let outlookLink {
                Link(destination: outlookLink) {
                    if skin.brand { MonoLabel("Open in Outlook →", color: skin.accentInk) } else { Text("Open in Outlook").font(.callout) }
                }
                .help("Opens this item in Outlook on the web")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { if skin.brand { FocusFrame(arm: 10).stroke(skin.hair2, lineWidth: 1) } }
        .accessibilityElement(children: .combine)
    }
}

/// Mail Settings → Mail: the user's own switch for MIP decryption (off by default, docs/MIP.md).
struct ProtectedMessagesSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section("Protected messages") {
            Toggle("Decrypt protected messages on this Mac (MIP SDK)",
                   isOn: Binding(get: { app.protectedDecryptEnabled }, set: { app.protectedDecryptEnabled = $0 }))
            Text("Opens mail encrypted with a sensitivity label (or Encrypt / Do Not Forward) here instead of only in Outlook. "
                 + "The message is decrypted in memory with Microsoft's Information Protection SDK, using your account's "
                 + "Rights Management licence; its rights decide copy, print, reply, forward, screenshots and AI. "
                 + "Decrypted content is never stored on this Mac, indexed for search or sent to AI.")
                .font(.caption).foregroundStyle(.secondary)
            if app.protectedDecryptEnabled {
                LabeledContent("MIP SDK") { Text(app.protectedBridgeStatus).font(.caption) }
            }
        }
    }
}
