import AppKit
import MailCore
import SwiftUI

// Direct actions on message-list rows (Ryan 2026-11-19: "swipe or at least direct actions on the list items").
//  * Hover strip: read/unread, flag, snooze, archive, delete on the hovered row, without selecting it first.
//  * Trackpad swipe (two-finger horizontal): the row slides and reveals the action; past the threshold on release it fires.
//    Defaults follow Apple Mail: swipe left = archive, swipe right = read/unread. Configurable in Settings › Layout
//    (A11yPrefs / MailViewPreferences; UserDefaults `MailSwipeLeft` / `MailSwipeRight`, strip `mail.stripActions`).
// All actions go through MailModel.triage (optimistic, undoable with ⌘Z, outbox when offline).

// RowQuickAction itself lives in MailCore (MailViewPreferences.swift) so its settings persistence is testable.
extension RowQuickAction {
    func symbol(_ m: MailMessage) -> String {
        switch self {
        case .toggleRead: m.isRead ? "envelope.badge" : "envelope.open"
        case .flag: m.flag.status == .flagged ? "flag.slash" : "flag"
        case .snooze: "clock"
        case .archive: "archivebox"
        case .delete: "trash"
        }
    }

    func label(_ m: MailMessage) -> String {
        switch self {
        case .toggleRead: m.isRead ? L("Mark as Unread") : L("Mark as Read")
        case .flag: m.flag.status == .flagged ? L("Clear Flag") : L("Flag")
        case .snooze: L("Snooze")
        case .archive: L("Archive")
        case .delete: L("Delete")
        }
    }

    var shortcut: String {
        switch self {
        case .toggleRead: "U"
        case .flag: "S"   // keep in sync with MailLogic key map
        case .snooze: "H"
        case .archive: "E"
        case .delete: "⌫"
        }
    }

    @MainActor static var swipeLeft: RowQuickAction { A11yPrefs.shared.prefs.swipeLeft }
    @MainActor static var swipeRight: RowQuickAction { A11yPrefs.shared.prefs.swipeRight }
}

extension MailModel {
    /// One action on one row, independent of the current selection.
    func rowAction(_ a: RowQuickAction, id: String) {
        guard let row = visibleRows.first(where: { $0.id == id }) else { return }
        let m = row.message
        switch a {
        case .toggleRead: triage(.markRead(!m.isRead), id: id)
        case .flag: triage(.flag(FollowUpFlag(status: m.flag.status == .flagged ? .notFlagged : .flagged)), id: id)
        case .archive: archive(id: id)
        case .delete: triage(.delete, id: id, text: "Deleted")
        case .snooze:
            // The picker acts on the selection, so select first.
            selectedMessageId = id
            run(.snooze)
        }
    }
}

/// Swipe + hover-strip state. Only the row whose id matches reads a non-zero offset.
@MainActor @Observable final class RowSwipe {
    static let shared = RowSwipe()
    private(set) var activeId: String?
    private(set) var dx: CGFloat = 0
    /// The pointer is over a strip button of this row (keeps the strip up while NUI.hovered points at the button).
    var stripHover: String?
    @ObservationIgnored private var axis: Axis?
    @ObservationIgnored private var acc = CGSize.zero
    @ObservationIgnored private var swallowMomentum = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private weak var mail: MailModel?

    static let threshold: CGFloat = 90
    static let maxTravel: CGFloat = 160

    func offset(for id: String) -> CGFloat { activeId == id ? dx : 0 }

    func install(_ mail: MailModel) {
        self.mail = mail
        guard monitor == nil else { return }
        // Local monitors run on the main thread; the event never leaves it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            nonisolated(unsafe) let ev = e
            let consumed = MainActor.assumeIsolated { RowSwipe.shared.handle(ev) }
            return consumed ? nil : e
        }
    }

    /// true = event consumed.
    private func handle(_ e: NSEvent) -> Bool {
        // Momentum after a horizontal swipe must not scroll anything.
        if e.momentumPhase != [] { if e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled) { let s = swallowMomentum; swallowMomentum = false; return s }; return swallowMomentum }
        guard e.phase != [] else { return false }   // classic mouse wheel: never a swipe
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
            axis = nil; acc = .zero; dx = 0; activeId = nil; swallowMomentum = false
            return false
        }
        if axis == nil {
            acc.width += e.scrollingDeltaX; acc.height += e.scrollingDeltaY
            guard abs(acc.width) + abs(acc.height) > 6 else { return false }
            if abs(acc.width) > abs(acc.height) * 1.5, let id = hoveredRowId() {
                axis = .horizontal; activeId = id; dx = acc.width
            } else { axis = .vertical }
            return axis == .horizontal
        }
        guard axis == .horizontal, let id = activeId else { return false }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            let fire: RowQuickAction? = e.phase.contains(.cancelled) ? nil
                : (dx <= -Self.threshold ? .swipeLeft : (dx >= Self.threshold ? .swipeRight : nil))
            NMotion.with(.snappy(duration: 0.18)) { dx = 0 }   // A11Y: Reduce Motion
            activeId = nil; axis = nil; swallowMomentum = true
            if let fire { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now); mail?.rowAction(fire, id: id) }
            return true
        }
        let before = abs(dx) >= Self.threshold
        dx = max(-Self.maxTravel, min(Self.maxTravel, dx + e.scrollingDeltaX))
        if before != (abs(dx) >= Self.threshold) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        return true
    }

    private func hoveredRowId() -> String? {
        guard let mail, let key = NUI.shared.hovered?.base as? String ?? stripHover else { return nil }
        return mail.visibleRows.contains(where: { $0.id == key }) ? key : nil
    }
}

/// Row wrapper: slides with the swipe and reveals the action underneath; shows the hover strip.
struct SwipeableRow<Content: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var row: MailRow
    @ViewBuilder var content: Content

    var body: some View {
        let dx = RowSwipe.shared.offset(for: row.id)
        content
            .offset(x: dx)
            .background { if dx != 0 { reveal(dx) } }
            .overlay(alignment: .trailing) { RowQuickStrip(row: row).offset(x: dx) }
            .clipped()
    }

    private func reveal(_ dx: CGFloat) -> some View {
        let a: RowQuickAction = dx < 0 ? .swipeLeft : .swipeRight
        let armed = abs(dx) >= RowSwipe.threshold
        let tint: Color = switch a {
        case .delete: skin.brand ? skin.danger : .red
        case .archive: skin.brand ? skin.accentFill : app.theme.accent
        case .flag: .orange
        case .snooze: .purple
        case .toggleRead: skin.brand ? skin.ink : .blue
        }
        return ZStack(alignment: dx < 0 ? .trailing : .leading) {
            Rectangle().fill(armed ? tint : tint.opacity(0.35))
            VStack(spacing: 3) {
                NSymbol(a.symbol(row.message), size: 15, label: nil)
                Text(a.label(row.message)).font(skin.brand ? skin.mono(9, .medium) : .caption2.weight(.semibold))
                    .textCase(skin.brand ? .uppercase : nil)
            }
            .foregroundStyle(skin.brand && a == .archive ? skin.onAccent : .white)
            .padding(.horizontal, 18)
            .scaleEffect(armed ? 1 : 0.9)
        }
        .accessibilityHidden(true)
    }
}

/// Hover strip: compact icon buttons on the row's trailing edge, over the time/icons, opaque so text doesn't show through.
struct RowQuickStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var row: MailRow

    var body: some View {
        let visible = NUI.shared.hovered == AnyHashable(row.id) || RowSwipe.shared.stripHover == row.id
        if visible && RowSwipe.shared.activeId == nil && !A11yPrefs.shared.prefs.stripActions.isEmpty {
            HStack(spacing: 2) {
                ForEach(A11yPrefs.shared.prefs.stripActions, id: \.self) { a in StripButton(row: row, action: a) }
            }
            .padding(3)
            .background(skin.brand ? AnyShapeStyle(skin.card) : (NMotion.reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial)))
            .overlay { if skin.brand { Rectangle().strokeBorder(skin.hair2, lineWidth: 1) } else { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) } }
            .clipShape(RoundedRectangle(cornerRadius: skin.brand ? 0 : 6))
            .padding(.trailing, 10).padding(.top, 6)
            .frame(maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
        }
    }
}

private struct StripButton: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var row: MailRow
    var action: RowQuickAction

    var body: some View {
        let m = row.message
        let key = "strip:\(row.id):\(action.rawValue)"
        let hot = NUI.shared.hovered == AnyHashable(key)
        Button { app.mail.rowAction(action, id: row.id) } label: {
            NSymbol(action.symbol(m), size: 12, label: nil)
                .foregroundStyle(action == .delete && hot ? (skin.brand ? skin.danger : .red) : (skin.brand ? skin.ink : .primary))
                .frame(width: 24, height: 22)
                .background(hot ? (skin.brand ? skin.soft : Color.primary.opacity(0.08)) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(action.label(m)) (\(action.shortcut))")
        .accessibilityLabel(action.label(m))
        .onHover { inside in
            let s = RowSwipe.shared, ui = NUI.shared
            if inside { s.stripHover = row.id; ui.hovered = AnyHashable(key) }
            else {
                if ui.hovered == AnyHashable(key) { ui.hovered = AnyHashable(row.id) }
                if s.stripHover == row.id { s.stripHover = nil }
            }
        }
    }
}
