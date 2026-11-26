import SwiftUI
import UserNotifications
import CalendarCore

/// Meeting reminders. Polls the encrypted cache (no Graph traffic), fires once per occurrence, delivers an
/// in-app banner with Join and — when allowed — a system notification whose text comes from AlertComposer.
/// Only the event id goes into the notification payload; the join link is looked up when the user acts.
@MainActor @Observable
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    struct Banner: Identifiable, Equatable {
        var id: String { eventId }
        var eventId: String
        var text: AlertComposer.Text
        var start: Date
        var calendarId: String
        var joinURL: URL?
        var policy: ContentPolicy
    }

    var banner: Banner?
    var leadMinutes = UserDefaults.standard.object(forKey: "alertLead") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(leadMinutes, forKey: "alertLead") }
    }
    private var fired = Set<String>()
    private var task: Task<Void, Never>?
    private weak var model: AppModel?
    /// System notifications need a real bundle; automated screenshot runs skip them to avoid the permission prompt.
    private let systemEnabled = ProcessInfo.processInfo.environment["CC_DEMO_ALLOW_CAPTURE"] != "1"
        && Bundle.main.bundleIdentifier != nil

    func start(_ model: AppModel) {
        self.model = model
        if systemEnabled {
            let c = UNUserNotificationCenter.current()
            c.delegate = self
            c.setNotificationCategories(Set([UNNotificationCategory(
                identifier: "meeting", actions: [UNNotificationAction(identifier: "join", title: "Join", options: [.foreground])],
                intentIdentifiers: [], options: [])] + MailNotifier.categories))   // LIFECYCLE-HOOK: mail actions
            c.requestAuthorization(options: [.alert, .sound]) { ok, err in
                FileHandle.standardError.write(Data("[Alerts] notification authorisation: \(ok)\(err.map { " (\($0.localizedDescription))" } ?? "")\n".utf8))
            }
        }
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func tick(now: Date = .now, force: Bool = false) {
        guard let model else { return }
        model.refreshMenuBar(now: now)
        let horizon = now.addingTimeInterval(TimeInterval(leadMinutes * 60))
        let due = model.alertCandidates(from: now.addingTimeInterval(-60), to: force ? now.addingTimeInterval(12 * 3600) : horizon)
        for e in (force ? Array(due.prefix(1)) : due) {
            let key = "\(e.id)@\(Int(e.start.timeIntervalSince1970))"
            guard !fired.contains(key) else { continue }
            fired.insert(key)
            fire(e, now: now, model: model)
        }
    }

    private func fire(_ e: CalendarEvent, now: Date, model: AppModel) {
        let p = model.policy(for: e)
        let cal = model.calendar(for: e)
        let mins = max(0, Int((e.start.timeIntervalSince(now) / 60).rounded(.up)))
        let owner = cal.flatMap { $0.access == .own ? nil : $0.ownerDisplay }
        let provider = e.onlineMeetingURL.map { MeetingProvider(url: $0).displayName }
        let inApp = AlertComposer.compose(subject: e.subject, location: e.location, provider: provider, ownerName: owner,
                                          minutes: mins, policy: p, surface: .inApp)
        NMotion.with(.spring(duration: 0.4)) {   // A11Y-HOOK: Reduce Motion
            banner = Banner(eventId: e.id, text: inApp, start: e.start, calendarId: e.calendarId,
                            joinURL: p.redactDetails ? nil : e.onlineMeetingURL, policy: p)
        }
        guard systemEnabled else { return }
        let sys = AlertComposer.compose(subject: e.subject, location: e.location, provider: provider, ownerName: owner,
                                        minutes: mins, policy: p, surface: .system)
        let c = UNMutableNotificationContent()
        c.title = sys.title; c.body = sys.body; c.sound = .default
        c.userInfo = ["eventId": e.id]
        if e.onlineMeetingURL != nil && !p.redactDetails { c.categoryIdentifier = "meeting" }
        // Restricted: no preview in Notification Centre summaries either.
        if sys.restricted { c.interruptionLevel = .active; c.threadIdentifier = "restricted" }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.id, content: c, trigger: nil)) { err in
            FileHandle.standardError.write(Data("[Alerts] system notification \(err.map { "failed: \($0.localizedDescription)" } ?? "delivered")\n".utf8))
        }
    }

    func dismiss() { NMotion.with(.easeOut(duration: 0.2)) { banner = nil } }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async
        -> UNNotificationPresentationOptions {
        // Meetings: app is frontmost → the in-app banner already shows it. New mail (MailNotifier) still shows.
        n.request.identifier.hasPrefix("mail") ? [.banner, .list] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        let info = r.notification.request.content.userInfo
        let mailMessage = info["mailMessageId"] as? String, mailFolder = info["mailFolderId"] as? String
        let mailAction = r.actionIdentifier
        if let mailMessage, mailAction.hasPrefix("mail.") {   // LIFECYCLE-HOOK: Archive / Mark as Read / Reply
            await MainActor.run { MailNotifier.shared.perform(action: mailAction, messageId: mailMessage, app: model) }
            return
        }
        if mailMessage != nil || mailFolder != nil {   // new-mail notification (MailNotifier)
            await MainActor.run { NSApp.activate(); MailNotifier.shared.open(messageId: mailMessage, folderId: mailFolder, app: model) }
            return
        }
        let id = info["eventId"] as? String
        let action = r.actionIdentifier
        await MainActor.run {
            guard let id, let model, let e = model.alertCandidates(from: .now.addingTimeInterval(-3600),
                                                                  to: .now.addingTimeInterval(24 * 3600)).first(where: { $0.id == id })
            else { return }
            if action == "join", let url = e.onlineMeetingURL, !model.policy(for: e).redactDetails { MeetingLauncher.join(url) }
            else { NSApp.activate(); model.reveal(e) }
        }
    }
}

/// Floating reminder at the top of the calendar.
struct AlertBannerView: View {
    @Environment(AppModel.self) private var model
    var banner: AlertCenter.Banner

    var body: some View {
        let cal = model.calendars.first { $0.id == banner.calendarId }
        let tint = model.tint(cal)
        HStack(spacing: 12) {
            if let cal { OwnerBadge(calendar: cal, tint: tint, size: 30) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if banner.text.restricted { NSymbol("lock.fill", size: 13, label: "Restricted").foregroundStyle(.secondary) }
                    Text(banner.text.title).font(.headline).lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    let m = Int((banner.start.timeIntervalSince(ctx.date) / 60).rounded(.up))
                    Text(m > 0 ? "Starts in \(m) min · \(banner.start.formatted(date: .omitted, time: .shortened))"
                               : "Started \(banner.start.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let url = banner.joinURL {
                Button { MeetingLauncher.join(url); model.alerts.dismiss() } label: {
                    NLabel("Join \(MeetingProvider(url: url).displayName)", systemImage: "video.fill", size: 13)
                }
                .modifier(BrandButton(kind: .primary, prominent: true)).tint(.green)
            }
            Button("Show") {
                if let e = model.alertCandidates(from: banner.start.addingTimeInterval(-60), to: banner.start.addingTimeInterval(60))
                    .first(where: { $0.id == banner.eventId }) { model.reveal(e) }
                model.alerts.dismiss()
            }
            .modifier(BrandButton())
            Button { model.alerts.dismiss() } label: { NSymbol("xmark", size: 13, label: "Dismiss") }
                .buttonStyle(.borderless).help("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 640)
        .modifier(BannerSurface(tint: tint))
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct BannerSurface: ViewModifier {
    @Environment(\.skin) private var skin
    var tint: Color
    func body(content: Content) -> some View {
        if skin.brand {
            // niivo: square card, 1 pt ink frame, calendar-colour left bar.
            content.background(skin.card)
                .overlay(Rectangle().strokeBorder(skin.ink, lineWidth: 1))
                .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 4) }
        } else if NMotion.reduceTransparency {   // A11Y-HOOK: solid instead of glass / material
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(tint.opacity(0.5), lineWidth: 1))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint.opacity(0.18)), in: .rect(cornerRadius: 18))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }
}
