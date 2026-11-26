import SwiftUI
import CalendarCore

/// Menu-bar glance: what's next today across my calendars and the people I support, with one-click Join.
/// The menu-bar label is visible over every app and in every screen share, so it never shows a subject —
/// only the time and a countdown. The dropdown follows the lock-screen rules (AlertComposer `.system`).
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.trust.hidesContent {
            // Locked / wiped / blocked: nothing from the calendar in the menu bar panel either.
            VStack(spacing: 8) {
                NSymbol("lock.fill", size: 17).foregroundStyle(.secondary)
                Text("niivo mail is locked").font(.headline)
                Button("Open") { NSApp.activate(); openWindow(id: "main") }
            }
            .padding(20).frame(width: 360)
        } else {
            panel.onAppear { AppLifecycle.shared.openWindow = openWindow }   // LIFECYCLE-HOOK
        }
    }

    @ViewBuilder private var panel: some View {
        let items = Array(model.upcomingToday().prefix(6))
        VStack(alignment: .leading, spacing: 0) {
            MenuBarMailSection()   // LIFECYCLE-HOOK: unread + sync status + Open Mail
            HStack {
                Text("Today").font(.headline)
                Spacer()
                Text(model.persona == .assistant ? "You + \(model.principals.count) people" : "Your calendar")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if items.isEmpty {
                Text("Nothing else today.").foregroundStyle(.secondary).padding(14)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                MenuBarRow(event: e, isNext: i == 0)
                if i < items.count - 1 { Divider().padding(.leading, 52) }
            }
            Divider().padding(.top, 6)
            HStack {
                Button("Open Calendar") { model.section = .calendar; AppLifecycle.shared.ensureMainWindow() }   // LIFECYCLE-HOOK
                Spacer()
                Button { Task { await model.syncNow() } } label: { NSymbol("arrow.clockwise", size: 13, label: "Sync now") }
                    .buttonStyle(.borderless).help("Sync now")
            }
            .padding(10)
        }
        .frame(width: 360)
    }
}

private struct MenuBarRow: View {
    @Environment(AppModel.self) private var model
    var event: CalendarEvent
    var isNext: Bool

    var body: some View {
        let p = model.policy(for: event)
        let cal = model.calendar(for: event)
        let restricted = AlertComposer.isRestricted(p)
        let now = Date()
        let live = event.start <= now && event.end > now
        HStack(spacing: 10) {
            if let cal { OwnerBadge(calendar: cal, tint: model.tint(cal), size: 26) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if restricted { NSymbol("lock.fill", size: 10, label: "Restricted").foregroundStyle(.secondary) }
                    Text(restricted ? (p.redactDetails ? "Private appointment" : "Confidential meeting") : event.subject)
                        .font(isNext ? .body.weight(.semibold) : .body).lineLimit(1)
                }
                Text([live ? "Now" : event.start.formatted(date: .omitted, time: .shortened),
                      cal.flatMap { $0.access == .own ? nil : $0.ownerDisplay }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(live ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 6)
            if !p.redactDetails, let url = event.onlineMeetingURL {
                Button { MeetingLauncher.join(url) } label: { NLabel("Join", systemImage: "video.fill", size: 11) }
                    .buttonStyle(.borderedProminent).tint(isNext || live ? .green : .gray).controlSize(.small)
                    .help("Join \(MeetingProvider(url: url).displayName)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { NSApp.activate(); model.reveal(event) }
    }
}
