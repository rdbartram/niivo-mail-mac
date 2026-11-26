import SwiftUI
import AppKit
import UserNotifications
import CalendarCore
import MailCore

/// Desktop notifications for new mail (opt-in) and the Dock badge. Fed by MailModel's sync changes; text always comes
/// from `MailNotificationText` (policy first), bursts become one summary, the initial sync and backfill never notify
/// (`MailArrivalTracker`). Only the message id goes into the notification payload. Clicks arrive via AlertCenter
/// (the one UNUserNotificationCenter delegate).
@MainActor @Observable
final class MailNotifier {
    static let shared = MailNotifier()

    @ObservationIgnored private var tracker = MailArrivalTracker()
    @ObservationIgnored private var armed = false
    @ObservationIgnored private var recentSingles: [Date] = []
    @ObservationIgnored private var posted: [String] = []
    @ObservationIgnored private var badgeTask: Task<Void, Never>?
    @ObservationIgnored private weak var mail: MailModel?
    /// LIFECYCLE-HOOK: unread Inbox count (Dock badge + menu bar), observable for the menu bar label.
    private(set) var unreadCount = 0
    /// LIFECYCLE-HOOK: the organisation feature's VIP list (VIPStore conforms to `MailVIPLookup`). nil -> the
    /// "VIPs only" filter is off and its switch is hidden.
    @ObservationIgnored var vipLookup: MailVIPLookup?

    /// LIFECYCLE-HOOK: actions on a single new-mail notification. Archive / Mark as Read run in the background (and
    /// need the Mac unlocked); Reply opens the app and the composer. Nothing is ever sent from the notification.
    static let messageCategory = "mail-message"
    static var categories: [UNNotificationCategory] {
        [UNNotificationCategory(identifier: messageCategory, actions: [
            UNNotificationAction(identifier: "mail.archive", title: "Archive", options: [.authenticationRequired]),
            UNNotificationAction(identifier: "mail.markRead", title: "Mark as Read", options: [.authenticationRequired]),
            UNNotificationAction(identifier: "mail.reply", title: "Reply", options: [.foreground, .authenticationRequired]),
        ], intentIdentifiers: [], options: [])]
    }

    /// Same guard as the calendar's AlertCenter: system notifications need a real bundle; screenshot runs skip them.
    static var systemEnabled: Bool {
        ProcessInfo.processInfo.environment["CC_DEMO_ALLOW_CAPTURE"] != "1" && Bundle.main.bundleIdentifier != nil
    }

    func settings(_ mail: MailModel) -> MailNotificationSettings { mail.settings.notifications ?? MailNotificationSettings() }

    /// End of MailModel.afterOpen: the first pass is done, so everything now in the store is "seen".
    func arm(_ mail: MailModel) {
        self.mail = mail
        AttachmentController.shared.start()   // sweeps leftover temp files from a previous run
        guard let store = mail.store else { return }
        tracker = MailArrivalTracker()
        let now = Date()
        for mb in mail.mailboxes {
            guard let inbox = try? store.folder(wellKnown: .inbox, mailbox: mb) else { continue }   // seeded on first sighting
            tracker.seed(mailbox: mb, newest: (try? store.messages(folderId: inbox.id, limit: 1))?.first?.received, now: now)
        }
        // LIFECYCLE-HOOK: extra notifying folders keep their own watermark (key "mailbox<US>folder").
        for fid in settings(mail).folderIds {
            guard let f = (try? store.folder(id: fid)) ?? nil else { continue }
            tracker.seed(mailbox: Self.folderKey(f.mailbox, fid), newest: (try? store.messages(folderId: fid, limit: 1))?.first?.received, now: now)
        }
        armed = true
        AppLifecycle.shared.noteMailStarted()   // LIFECYCLE-HOOK: from now on mail starts in the background
        updateBadge()
    }

    func handle(_ change: MailChange, mail: MailModel) {
        self.mail = mail
        switch change {
        case .messages(let ids):
            if armed { evaluate(ids, mail: mail) }
            scheduleBadge()
        case .folders: scheduleBadge()
        default: break
        }
    }

    /// Lock / wipe / sign-out: forget everything, clear the badge and the notifications we posted.
    func reset() {
        armed = false
        tracker = MailArrivalTracker()
        recentSingles = []
        badgeTask?.cancel()
        NSApp?.dockTile.badgeLabel = nil
        unreadCount = 0
        if Self.systemEnabled, !posted.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: posted)
        }
        posted = []
    }

    /// Settings changed: re-seed (no flood of what arrived while it was off), ask for permission, refresh the badge.
    func settingsChanged(_ s: MailNotificationSettings) {
        guard let mail else { return }
        if s.enabled, Self.systemEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                FileHandle.standardError.write(Data("[MailNotify] authorisation: \(ok)\n".utf8))
            }
        }
        if armed { arm(mail) }
        updateBadge(s)
    }

    // MARK: Arrivals

    static func folderKey(_ mailbox: String, _ folderId: String) -> String { "\(mailbox)\u{1F}\(folderId)" }

    private func evaluate(_ ids: [String], mail: MailModel) {
        let s = settings(mail)
        guard s.enabled, let store = mail.store else { return }
        var inbox: [String: Bool] = [:]
        // Tracker key: the mailbox for its Inbox, "mailbox<US>folder" for an extra folder (own watermark).
        var cands: [(message: MailMessage, mailbox: String)] = []
        var realMailbox: [String: String] = [:]
        for id in ids.prefix(1_000) {
            guard let m = try? store.message(id: id, includeBody: false), !m.isDraft else { continue }
            let mb = store.mailbox(forFolder: m.folderId)
            guard s.mailboxes.contains(mb) else { continue }
            let isInbox = inbox[m.folderId] ?? (((try? store.folder(id: m.folderId)) ?? nil)?.wellKnown == .inbox)
            inbox[m.folderId] = isInbox
            if isInbox { cands.append((m, mb)); realMailbox[mb] = mb }
            else if s.folderIds.contains(m.folderId) {   // LIFECYCLE-HOOK: per-folder notifications
                let k = Self.folderKey(mb, m.folderId); cands.append((m, k)); realMailbox[k] = mb
            }
        }
        // Every arrival advances the watermark (also ones already read elsewhere, so marking them unread later
        // doesn't look new); only the ones the filters want (MailNotificationFilter) are announced.
        let new = tracker.arrivals(cands, now: Date()).compactMap { c -> (message: MailMessage, mailbox: String)? in
            let mb = realMailbox[c.mailbox] ?? c.mailbox
            return MailNotificationFilter.shouldNotify(c.message, mailbox: mb, isInbox: inbox[c.message.folderId] ?? false,
                                                       settings: s, vip: vipLookup) ? (c.message, mb) : nil
        }
        guard !new.isEmpty, Self.systemEnabled else { return }
        // TODAY-HOOK: calm notifications. The triage engine is refreshed first, so the new conversation has a state.
        if s.needsYouOnly, mail.ai.usesConversationTriage, let engine = mail.ai.inbox.engine {
            let vip = vipLookup
            Task { @MainActor [weak self, weak mail] in
                let cids = new.map(\.message.conversationId)
                let ds = await Task.detached(priority: .userInitiated) { () -> [String: TriageDecision] in
                    engine.refresh()
                    var out: [String: TriageDecision] = [:]
                    for c in cids { if let d = engine.decision(for: c) { out[c] = d } }
                    // The triage loop may have taken the dirty set first: one more look a moment later.
                    if Set(cids).count > out.count {
                        try? await Task.sleep(for: .seconds(3))
                        engine.refresh()
                        for c in cids where out[c] == nil { if let d = engine.decision(for: c) { out[c] = d } }
                    }
                    return out
                }.value
                guard let self, let mail else { return }
                let keep = new.filter { c in
                    let fromVIP = vip.map { v in [c.message.from?.address, c.message.sender?.address].compactMap { $0?.lowercased() }.contains { v.contains($0) } } ?? false
                    return TodayNotificationFilter.allows(decision: ds[c.message.conversationId], fromVIP: fromVIP, triageActive: true)
                }
                FileHandle.standardError.write(Data("[MailNotify] needsYouOnly arrivals=\(new.count) kept=\(keep.count)\n".utf8))
                if !keep.isEmpty { self.post(keep, mail: mail) }
            }
            return
        }
        post(new, mail: mail)
    }

    private func post(_ new: [(message: MailMessage, mailbox: String)], mail: MailModel) {
        let now = Date()
        recentSingles.removeAll { now.timeIntervalSince($0) >= MailNotificationPlanner.window }
        let title: (String) -> String? = { $0 == "me" ? nil : MailboxDisplay.title($0) }
        switch MailNotificationPlanner.plan(newCount: new.count, recent: recentSingles, now: now) {
        case .none: return
        case .singles:
            let items = new.sorted { $0.message.received < $1.message.received }
            recentSingles.append(contentsOf: items.map { _ in now })
            let sync = mail.sync
            // LIFECYCLE-HOOK: locked -> nothing from the message, no body fetch, no actions.
            if AppLifecycle.shared.model?.trust.hidesContent ?? false {
                for (m, mb) in items { deliver(MailNotificationText.locked(mailboxTitle: title(mb)), id: "mail:\(m.id)", info: ["mailMessageId": m.id]) }
                return
            }
            Task { @MainActor [weak self, weak mail] in
                for (m, mb) in items {
                    guard let self, let mail else { return }
                    var h = m
                    var confirmed = false
                    // Re-read label + private flag from the full message (as the reader does) before any detail shows;
                    // labelled-looking headers skip the call, they are generic anyway.
                    if !MailNotificationText.isRestricted(m, policy: mail.policy(for: m, mailbox: mb)),
                       let full = try? await sync?.fetchBody(id: m.id) {
                        h.adoptLabel(of: full); h.isPrivate = full.isPrivate
                        confirmed = true
                    }
                    let t = MailNotificationText.compose(h, policy: mail.policy(for: h, mailbox: mb), mailboxTitle: title(mb), confirmed: confirmed)
                    self.deliver(t, id: "mail:\(m.id)", info: ["mailMessageId": m.id], category: Self.messageCategory)
                }
            }
        case .summary(let n):
            let t = MailNotificationText.summary(count: n, mailboxTitles: new.compactMap { title($0.mailbox) })
            let folder = new.first.flatMap { try? mail.store?.folder(wellKnown: .inbox, mailbox: $0.mailbox) }??.id
            deliver(t, id: "mail-summary:\(UUID().uuidString)", info: folder.map { ["mailFolderId": $0] } ?? [:])
        }
    }

    private func deliver(_ t: MailNotificationText.Text, id: String, info: [String: String], category: String? = nil) {
        let c = UNMutableNotificationContent()
        if let category { c.categoryIdentifier = category }   // LIFECYCLE-HOOK: singles only; summaries have no actions
        c.title = t.title
        if !t.subtitle.isEmpty { c.subtitle = t.subtitle }
        c.body = t.body
        c.sound = .default
        c.userInfo = info
        c.threadIdentifier = t.restricted ? "mail-restricted" : "mail"
        posted.append(id)
        if posted.count > 200 { posted.removeFirst(posted.count - 200) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { err in
            if let err { FileHandle.standardError.write(Data("[MailNotify] failed: \(err.localizedDescription)\n".utf8)) }
        }
    }

    /// Click on a mail notification (from AlertCenter).
    func open(messageId: String?, folderId: String?, app: AppModel?) {
        guard let app else { return }
        // LIFECYCLE-HOOK: ensureMainWindow recreates the main window when it was closed (menu bar mode).
        if let messageId { app.openMailMessage(messageId, raise: false); AppLifecycle.shared.ensureMainWindow(); return }
        if let folderId {
            if app.section != .mail { app.section = .mail }
            app.mail.selectedFolderId = folderId
            AppLifecycle.shared.ensureMainWindow()
        }
    }

    /// LIFECYCLE-HOOK: a notification action (from AlertCenter). Nothing while locked / wiped.
    func perform(action: String, messageId: String, app: AppModel?) {
        guard let app, !app.trust.hidesContent else { return }
        let mail = app.mail
        guard mail.started, let store = mail.store, let m = try? store.message(id: messageId, includeBody: false) else {
            if action == "mail.reply" { AppLifecycle.shared.ensureMainWindow() }
            return
        }
        switch action {
        case "mail.archive":
            let mb = store.mailbox(forFolder: m.folderId)
            guard let arch = try? store.folder(wellKnown: .archive, mailbox: mb), arch.id != m.folderId else { return }
            mail.triage(.move(toFolderId: arch.id), id: messageId, text: "Archived")
        case "mail.markRead":
            if !m.isRead { mail.triage(.markRead(true), id: messageId) }
        case "mail.reply":
            app.openMailMessage(messageId, raise: false)
            AppLifecycle.shared.ensureMainWindow()
            if mail.composer == nil { mail.reply(.reply, to: messageId) }   // rights-gated; never replaces an open draft
            else { mail.toast(MailToast(text: "Close the open message to reply", symbol: "arrowshape.turn.up.left")) }
        default: break
        }
        scheduleBadge()
    }

    // MARK: Dock badge

    private func scheduleBadge() {
        guard badgeTask == nil else { return }
        badgeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.badgeTask = nil
            self?.updateBadge()
        }
    }

    private func updateBadge(_ override: MailNotificationSettings? = nil) {
        guard let mail, let store = mail.store else { NSApp?.dockTile.badgeLabel = nil; unreadCount = 0; return }
        let s = override ?? settings(mail)
        guard s.dockBadge || s.menuBarCount else { NSApp?.dockTile.badgeLabel = nil; unreadCount = 0; return }
        var n = 0
        for mb in s.mailboxes {
            if let f = try? store.folder(wellKnown: .inbox, mailbox: mb) { n += (try? store.unreadCount(folderId: f.id)) ?? 0 }
        }
        if unreadCount != n { unreadCount = n }   // LIFECYCLE-HOOK: menu bar count
        NSApp?.dockTile.badgeLabel = s.dockBadge && n > 0 ? (n > 9_999 ? "9999+" : "\(n)") : nil
    }
}

/// Mail Settings → Notifications.
struct MailNotificationSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let mail = app.mail
        let s = MailNotifier.shared.settings(mail)
        Section("Notifications") {
            Toggle("Notify me about new mail in the Inbox", isOn: bind(\.enabled))
            if s.enabled {
                Toggle("Focused Inbox only", isOn: bind(\.focusedOnly))
                if mail.ai.usesConversationTriage {   // TODAY-HOOK: calm notifications
                    Toggle(L("Notify only for Needs you"), isOn: bind(\.needsYouOnly))
                        .help(L("Only new mail that needs your answer (medium confidence or better), or from VIPs"))
                }
                if MailNotifier.shared.vipLookup != nil {   // LIFECYCLE-HOOK
                    Toggle("Only from VIPs", isOn: bind(\.vipOnly))
                }
            }
            ForEach(mail.mailboxes, id: \.self) { mb in
                Toggle(isOn: Binding(get: { s.mailboxes.contains(mb) }, set: { on in
                    var n = s
                    if on { n.mailboxes.insert(mb) } else { n.mailboxes.remove(mb) }
                    save(n)
                })) {
                    HStack { MailboxBadge(mailbox: mb, size: 18); Text(MailboxDisplay.title(mb)) }
                }
                .disabled(!s.enabled && !s.dockBadge && !s.menuBarCount)
                if s.enabled, s.mailboxes.contains(mb) { MailboxNotificationRulePicker(mailbox: mb) }   // LIFECYCLE-HOOK
            }
            if s.enabled { NotificationFolderPicker() }   // LIFECYCLE-HOOK
            Toggle("Show the unread Inbox count on the Dock icon", isOn: bind(\.dockBadge))
            Toggle("Show the unread Inbox count in the menu bar", isOn: bind(\.menuBarCount))   // LIFECYCLE-HOOK
            Text("Labelled, private and encrypted mail shows only \u{201C}New confidential message\u{201D}, without sender or subject. "
                 + "Mail that arrives in a burst is summarised. Nothing is shown for the first sync or older mail. "
                 + "Archive, Mark as Read and Reply work from the notification; Reply opens the composer and never sends.")
                .font(.caption).foregroundStyle(.secondary)
            if !MailNotifier.systemEnabled {
                Text("System notifications need the signed app bundle; this build can't post them.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bind(_ k: WritableKeyPath<MailNotificationSettings, Bool>) -> Binding<Bool> {
        let mail = app.mail
        return Binding(get: { MailNotifier.shared.settings(mail)[keyPath: k] },
                       set: { v in var n = MailNotifier.shared.settings(mail); n[keyPath: k] = v; save(n) })
    }

    private func save(_ n: MailNotificationSettings) {
        let mail = app.mail
        Task {
            await mail.update { $0.notifications = n }
            MailNotifier.shared.settingsChanged(n)
        }
    }
}
