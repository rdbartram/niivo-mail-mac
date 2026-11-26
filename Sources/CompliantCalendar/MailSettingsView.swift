import SwiftUI
import CalendarCore
import MailCore
import TrustCore

/// Settings sheet (⌘,): Mail cache, Rules, Automatic Replies, Send As, Device Trust.
struct MailSettingsView: View {
    @Environment(AppModel.self) private var app

    /// §17: the sheet's size. It used to be a fixed 820×600 (720×600), which ran past the window on smaller
    /// windows/screens. Now the ideal size is clamped to the presenting view (`MailModel.settingsHost`) and the screen.
    static func fit(ideal: CGSize, host: CGSize, screen: CGSize?, floor: CGSize = CGSize(width: 480, height: 320),
                    margin: CGSize = CGSize(width: 40, height: 40)) -> CGSize {
        var avail = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if host.width > 0, host.height > 0 { avail = CGSize(width: host.width - margin.width, height: host.height - margin.height) }
        if let screen, screen.width > 0, screen.height > 0 {
            avail = CGSize(width: min(avail.width, screen.width - margin.width), height: min(avail.height, screen.height - margin.height))
        }
        // The floor keeps it usable, but never past what's actually there (host/screen minus nothing).
        let hardW = min(host.width > 0 ? host.width : .greatestFiniteMagnitude, screen?.width ?? .greatestFiniteMagnitude)
        let hardH = min(host.height > 0 ? host.height : .greatestFiniteMagnitude, screen?.height ?? .greatestFiniteMagnitude)
        return CGSize(width: min(ideal.width, max(min(floor.width, hardW), avail.width)),
                      height: min(ideal.height, max(min(floor.height, hardH), avail.height)))
    }

    static func screenSize() -> CGSize? {
        (NSApp.mainWindow?.screen ?? NSScreen.main)?.visibleFrame.size
    }

    var body: some View {
        let mail = app.mail
        @Bindable var m = mail
        let size = Self.fit(ideal: CGSize(width: app.theme.brand ? 820 : 720, height: 600), host: mail.settingsHost, screen: Self.screenSize())
        VStack(spacing: 0) {
            if app.theme.brand {
                // niivo: indexed nav column + content pane (no TabView). Content forms inherit the niivo control styles.
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) { NiivoWordmark(size: 18, blinks: false, color: app.skin.ink) }
                            .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 18)
                        // §17: the tab list scrolls when the sheet is clamped to a short window.
                        ScrollView(.vertical) { VStack(alignment: .leading, spacing: 0) { ForEach(Array(MailModel.SettingsTab.allCases.enumerated()), id: \.element) { i, t in
                            let on = t == mail.settingsTab
                            Button { mail.settingsTab = t } label: {
                                HStack(spacing: 8) {
                                    MonoLabel(String(format: "%02d", i + 1), size: NV.Size.labelSm, color: app.skin.accentInk)
                                    Text(t.title).font(app.skin.sans(NV.Size.body, on ? .medium : .regular)).foregroundStyle(app.skin.ink)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .nRow(selected: on, hoverKey: AnyHashable("settings:" + t.rawValue), divider: false, skin: app.skin)
                            .accessibilityAddTraits(on ? .isSelected : [])
                            .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                        } } }
                        .scrollIndicators(.automatic)
                        Spacer(minLength: 0)
                        MonoLabel("⌘1–⌘\(MailModel.SettingsTab.allCases.count) switch", size: NV.Size.labelSm).padding(16)
                    }
                    .frame(width: 200)
                    .background(app.skin.ground)
                    Rectangle().fill(app.skin.hair).frame(width: 1)
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            MonoLabel(L("Settings — %@", mail.settingsTab.title), bracket: true)
                            Text(mail.settingsTab.title + ".").font(app.skin.sans(NV.Size.title)).tracking(app.skin.titleTrack(NV.Size.title))
                        }
                        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 6)
                        tab(mail.settingsTab)
                            .formStyle(.grouped)
                            .scrollContentBackground(.hidden)
                            .toggleStyle(NToggleStyle())
                            .buttonStyle(NVButtonStyle(kind: .ghost))
                            .controlSize(.regular)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .background(app.skin.card)
                }
                Rectangle().fill(app.skin.hair).frame(height: 1)
                HStack {
                    MonoLabel("niivo mail", size: NV.Size.labelSm, bracket: true)
                    Spacer()
                    NButton(L("Done")) { mail.showSettings = false; mail.focusListToken += 1 }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            } else {
                TabView(selection: $m.settingsTab) {
                    ForEach(MailModel.SettingsTab.allCases) { t in
                        tab(t).tabItem { Label(t.title, systemImage: t.symbol) }.tag(t)
                    }
                }
                .padding(.top, 8)
                Divider()
                HStack {
                    Spacer()
                    Button(L("Done")) { mail.showSettings = false; mail.focusListToken += 1 }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(app.theme.brand ? app.skin.ground : .clear)
        .task { await mail.refreshSettingsInfo(); await mail.loadRules() }
        .sheet(item: $m.ruleEditor) { e in RuleEditorView(editor: e) }
    }

    @ViewBuilder private func tab(_ t: MailModel.SettingsTab) -> some View {
        if !app.mail.started && t != .trust && t != .layout && t != .accounts {   // ACCOUNTS-HOOK
            MailUnavailable(symbol: "envelope", title: "Mail isn't open yet", text: "Switch to Mail (⌃⌘1) first.")
        } else {
            switch t {
            case .mail: MailCacheSettings()
            case .layout: LayoutAccessibilitySettings()   // A11Y-HOOK
            case .rules: RulesSettings()
            case .autoReplies: AutoRepliesSettings()
            case .identities: IdentitiesSettings()
            case .trust: TrustSettings()
            case .ai: AISettingsView()   // AI-HOOK
            case .accounts: AccountsSettings()   // ACCOUNTS-HOOK (AccountsViews.swift)
            }
        }
    }
}

extension CacheWindow {
    var title: String {
        switch self {
        case .days(let d): "\(d) days"
        case .years(let y): y == 1 ? "1 year" : "\(y) years"
        case .everything: "Everything"
        }
    }
}

struct MailCacheSettings: View {
    @Environment(AppModel.self) private var app
    static let bodySizes = [100, 250, 500, 1024, 2048]

    var body: some View {
        let mail = app.mail
        Form {
            if app.theme.brand {
                Section("Writing") {
                    Toggle("New message opens in its own window (off: compose in the reading pane)",
                           isOn: Bindable(ComposeHost.shared).newMessageInWindow)
                    Text("Replies and forwards open in the reading pane; pop them out with ⌥↩ or ⇧⌘P.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Header history kept on this Mac (per mailbox)") {
                ForEach(mail.mailboxes, id: \.self) { mb in windowRow(mb) }
                if mail.maxWindowDays < 3650 {
                    Text("This Mac's trust policy caps history at \(mail.maxWindowDays) days.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Older mail is still reachable: scroll to the end of a folder to page it from the server, and search asks the server too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Message bodies") {
                Picker("Body cache size", selection: Binding(get: { mail.settings.bodyCacheBytes / (1024 * 1024) },
                                                             set: { v in Task { await mail.update { $0.bodyCacheBytes = v * 1024 * 1024 } } })) {
                    ForEach(Self.bodySizes, id: \.self) { s in Text(s >= 1024 ? "\(s / 1024) GB" : "\(s) MB").tag(s) }
                }
                LabeledContent("In use") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(mail.bodyCacheUsed), countStyle: .file))
                }
                Text("Bodies are encrypted and evicted oldest-first. Labelled mail that may not be stored offline is never cached.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AttachmentPreviewSettingsSection()   // PREVIEW-HOOK (AttachmentPreviews.swift)
            ProtectedMessagesSettings()
            Section("Shared and delegated mailboxes") {
                ForEach(mail.mailboxes.filter { $0 != "me" }, id: \.self) { mb in
                    Toggle(isOn: Binding(get: { mail.settings.pinnedMailboxes.contains(mb) },
                                         set: { on in Task { await mail.setPinned(mb, on) } })) {
                        HStack { MailboxBadge(mailbox: mb, size: 18); Text(mb) }
                    }
                }
                Text("Pinned mailboxes sync in the background; others sync when you open them.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Inbox") {
                Toggle("Split inbox (Important · Other · Newsletters · Notifications)", isOn: Bindable(mail).splitInboxEnabled)
                MarkReadSettingRow()   // READER2-HOOK
                LabeledContent("Internal domains") { Text(mail.settings.internalDomains.sorted().joined(separator: ", ")) }
            }
            TodaySettingsSection()   // TODAY-HOOK (TodayViews.swift)
            MailNotificationSettingsSection()   // NOTIFY-HOOK (MailNotifier.swift)
            AppLifecycleSettingsSection()   // LIFECYCLE-HOOK: login item, menu bar, default mail app (AppLifecycle.swift)
            OrganiseSettingsSection()   // CATEGORIES master list + keymap + All Inboxes (MailOrganiseSheets.swift)
            Org2SettingsSections()   // ORG2-HOOK: avatars, VIPs, Quick Steps (MailOrg2Views.swift)
        }
        .formStyle(.grouped)
    }

    private func windowRow(_ mb: String) -> some View {
        let mail = app.mail
        let info = mail.backfill[mb]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                MailboxBadge(mailbox: mb, size: 18)
                Text(MailboxDisplay.title(mb))
                Spacer()
                Picker("Keep", selection: Binding(get: { mail.settings.window(for: mb) },
                                                  set: { w in Task { await mail.setWindow(w, for: mb) } })) {
                    ForEach(CacheWindow.presets.filter(mail.allows), id: \.self) { w in Text(w.title).tag(w) }
                }
                .labelsHidden().fixedSize()
            }
            HStack {
                if let info {
                    if info.done { NLabel("Backfill complete", systemImage: "checkmark.circle", size: 13).foregroundStyle(.green) }
                    else { NLabel("Backfilling", systemImage: "arrow.down.circle", size: 13) }
                    if let o = info.oldest { Text("· oldest cached \(o.formatted(date: .abbreviated, time: .omitted))") }
                } else { Text("Not synced yet") }
                Spacer()
                if info?.done != true { Button("Backfill now") { Task { await mail.backfillNow(mb) } }.controlSize(.small) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rules

@MainActor @Observable
final class RuleEditorState: Identifiable {
    let id = UUID()
    var rule: MailRule
    var fromText: String
    var subjectText: String
    var senderText: String
    var categoriesText: String
    var forwardText: String
    var confirmPermanentDelete = false

    init(rule: MailRule) {
        self.rule = rule
        fromText = rule.conditions.fromAddresses.map(\.address).joined(separator: ", ")
        subjectText = rule.conditions.subjectContains.joined(separator: ", ")
        senderText = rule.conditions.senderContains.joined(separator: ", ")
        categoriesText = rule.actions.assignCategories.joined(separator: ", ")
        forwardText = rule.actions.forwardTo.map(\.address).joined(separator: ", ")
    }

    static func list(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func build() -> MailRule {
        var r = rule
        r.conditions.fromAddresses = RecipientCheck.parse(fromText).valid
        r.conditions.subjectContains = Self.list(subjectText)
        r.conditions.senderContains = Self.list(senderText)
        r.actions.assignCategories = Self.list(categoriesText)
        r.actions.forwardTo = RecipientCheck.parse(forwardText).valid
        return r
    }
}

struct RulesSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Inbox rules run on the Exchange server, so they work with this Mac off and match Outlook. Drag to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { mail.editRule(nil) } label: { NLabel("New Rule", systemImage: "plus", size: 13) }
            }
            if let e = mail.ruleError, mail.ruleEditor == nil {
                NLabel(e, systemImage: "hand.raised.fill", size: 12).font(.callout).foregroundStyle(.red)
            }
            List {
                ForEach(mail.rules, id: \.id) { r in RuleRow(rule: r) }
                    .onMove { from, to in Task { await mail.moveRules(from: from, to: to) } }
            }
            .listStyle(.inset)
        }
        .padding(16)
    }
}

struct RuleRow: View {
    @Environment(AppModel.self) private var app
    var rule: MailRule
    var body: some View {
        let mail = app.mail
        HStack {
            NSymbol("line.3.horizontal", size: 13).foregroundStyle(.tertiary)
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { _ in Task { await mail.toggleRule(rule) } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(rule.isReadOnly)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(rule.displayName)
                    if rule.hasError { Tag("Error") }
                    if rule.isReadOnly { Tag("Read-only") }
                }
                Text(Self.summary(rule, folders: mail.folders["me"] ?? [])).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Edit") { mail.editRule(rule) }.disabled(rule.isReadOnly)
            Button(role: .destructive) { Task { await mail.deleteRule(rule) } } label: { NSymbol("trash", size: 13, label: "Delete rule") }
                .buttonStyle(.borderless).disabled(rule.isReadOnly)
        }
    }

    static func summary(_ r: MailRule, folders: [MailFolder]) -> String {
        var when: [String] = []
        if !r.conditions.fromAddresses.isEmpty { when.append("from " + r.conditions.fromAddresses.map(\.display).joined(separator: ", ")) }
        if !r.conditions.subjectContains.isEmpty { when.append("subject has “" + r.conditions.subjectContains.joined(separator: "”, “") + "”") }
        if !r.conditions.senderContains.isEmpty { when.append("sender has “" + r.conditions.senderContains.joined(separator: "”, “") + "”") }
        if r.conditions.hasAttachments == true { when.append("has attachments") }
        var then: [String] = []
        if let f = r.actions.moveToFolder { then.append("move to " + (folders.first { $0.id == f }?.displayName ?? "folder")) }
        if r.actions.markAsRead == true { then.append("mark read") }
        if r.actions.delete == true { then.append("delete") }
        if r.actions.permanentDelete == true { then.append("delete permanently") }
        if !r.actions.assignCategories.isEmpty { then.append("categorise") }
        if !r.actions.forwardTo.isEmpty { then.append("forward") }
        return "If " + (when.isEmpty ? "any message" : when.joined(separator: " and ")) + " → " + (then.isEmpty ? "nothing" : then.joined(separator: ", "))
    }
}

struct RuleEditorView: View {
    @Environment(AppModel.self) private var app
    var editor: RuleEditorState

    var body: some View {
        let mail = app.mail
        @Bindable var e = editor
        let folders = (mail.folders["me"] ?? []).filter { !$0.id.hasPrefix("local-") }
        let size = MailSettingsView.fit(ideal: CGSize(width: 560, height: 620), host: mail.settingsHost,
                                        screen: MailSettingsView.screenSize(), margin: CGSize(width: 80, height: 80))
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $e.rule.displayName)
                Section("When a message arrives that…") {
                    TextField("is from", text: $e.fromText, prompt: Text("address, address"))
                    TextField("subject contains", text: $e.subjectText, prompt: Text("words, phrases"))
                    TextField("sender contains", text: $e.senderText)
                    Toggle("has attachments", isOn: Binding(get: { e.rule.conditions.hasAttachments == true },
                                                             set: { e.rule.conditions.hasAttachments = $0 ? true : nil }))
                    Picker("importance", selection: $e.rule.conditions.importance) {
                        Text("Any").tag(Importance?.none); Text("High").tag(Importance?.some(.high)); Text("Low").tag(Importance?.some(.low))
                    }
                }
                Section("Do this") {
                    Picker("Move to", selection: $e.rule.actions.moveToFolder) {
                        Text("Don't move").tag(String?.none)
                        ForEach(folders) { f in Text(f.displayName).tag(String?.some(f.id)) }
                    }
                    Toggle("Mark as read", isOn: Binding(get: { e.rule.actions.markAsRead == true },
                                                         set: { e.rule.actions.markAsRead = $0 ? true : nil }))
                    TextField("Categorise as", text: $e.categoriesText)
                    TextField("Forward to", text: $e.forwardText, prompt: Text("address"))
                    Toggle("Delete (to Deleted Items)", isOn: Binding(get: { e.rule.actions.delete == true },
                                                                      set: { e.rule.actions.delete = $0 ? true : nil }))
                    Toggle("Delete permanently", isOn: Binding(get: { e.rule.actions.permanentDelete == true },
                                                               set: { e.rule.actions.permanentDelete = $0 ? true : nil }))
                    if e.rule.actions.permanentDelete == true {
                        Toggle("I understand this can't be undone", isOn: $e.confirmPermanentDelete).foregroundStyle(.red)
                    }
                    Toggle("Stop processing more rules", isOn: Binding(get: { e.rule.actions.stopProcessingRules == true },
                                                                       set: { e.rule.actions.stopProcessingRules = $0 ? true : nil }))
                }
                if let err = mail.ruleError {
                    NLabel(err, systemImage: "hand.raised.fill", size: 13).foregroundStyle(.red)
                }
                ForEach(mail.ruleWarnings, id: \.self) { w in NLabel(w, systemImage: "exclamationmark.triangle", size: 13).foregroundStyle(.orange) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { mail.ruleEditor = nil; mail.ruleError = nil }.keyboardShortcut(.cancelAction)
                Button("Save Rule") {
                    Task { if await mail.saveRule(e.build(), confirmPermanentDelete: e.confirmPermanentDelete) { mail.ruleEditor = nil } }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        // §17: on top of the (already clamped) Settings sheet; 620 was taller than the sheet itself.
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Automatic replies

struct AutoRepliesSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail
        @Bindable var m = mail
        Form {
            Picker("Automatic replies", selection: $m.autoRepliesDraft.status) {
                Text("Off").tag(AutomaticReplies.Status.disabled)
                Text("On").tag(AutomaticReplies.Status.alwaysEnabled)
                Text("Scheduled").tag(AutomaticReplies.Status.scheduled)
            }
            .pickerStyle(.segmented)
            if mail.autoRepliesDraft.status == .scheduled {
                DatePicker("Start", selection: Binding(get: { mail.autoRepliesDraft.start ?? .now }, set: { mail.autoRepliesDraft.start = $0 }))
                DatePicker("End", selection: Binding(get: { mail.autoRepliesDraft.end ?? Date().addingTimeInterval(86400) },
                                                     set: { mail.autoRepliesDraft.end = $0 }))
            }
            Section("Inside your organisation (HTML)") {
                TextEditor(text: $m.autoRepliesDraft.internalReplyHTML).frame(minHeight: 80).font(.callout.monospaced())
            }
            Section("Outside your organisation (HTML)") {
                Picker("Send to", selection: $m.autoRepliesDraft.externalAudience) {
                    Text("Nobody outside").tag(AutomaticReplies.Audience.none)
                    Text("My contacts only").tag(AutomaticReplies.Audience.contactsOnly)
                    Text("Everyone outside").tag(AutomaticReplies.Audience.all)
                }
                TextEditor(text: $m.autoRepliesDraft.externalReplyHTML).frame(minHeight: 80).font(.callout.monospaced())
                    .disabled(mail.autoRepliesDraft.externalAudience == .none)
            }
            if let e = mail.autoRepliesError { NLabel(e, systemImage: "exclamationmark.triangle", size: 13).foregroundStyle(.red) }
            HStack {
                Text("For your own mailbox. Setting another person's out-of-office isn't possible with delegated Graph access.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { if let r = mail.autoReplies { mail.autoRepliesDraft = r } }
                Button("Save") { Task { await mail.saveAutoReplies() } }.buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .task { await mail.refreshAutoReplies() }
    }
}

// MARK: - Send-as identities

struct IdentitiesSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail
        @Bindable var m = mail
        Form {
            Section("From addresses") {
                ForEach(mail.settings.identities, id: \.self) { i in
                    HStack {
                        MailboxBadge(mailbox: i.mailbox, size: 18)
                        Text(ComposerFromRow.describe(i))
                        Spacer()
                        if i.mode != .selfSend {
                            Button(role: .destructive) { Task { await mail.update { $0.identities.removeAll { $0 == i } } } } label: {
                                NSymbol("minus.circle", size: 13, label: "Remove")
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                Text("Graph can't list Send As / Send on Behalf grants, so they're configured here. If Exchange refuses, the composer says “You can't send as …”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add") {
                TextField("Address", text: $m.newIdentity.address, prompt: Text("support@contoso.example"))
                TextField("Display name", text: $m.newIdentity.name)
                Picker("Permission", selection: $m.newIdentity.mode) {
                    Text("Send as (shared mailbox)").tag(SendMode.sendAs)
                    Text("Send on behalf of").tag(SendMode.sendOnBehalf)
                }
                Button("Add Identity") {
                    var i = mail.newIdentity
                    i.address = i.address.trimmingCharacters(in: .whitespaces)
                    guard RecipientCheck.looksLikeAddress(i.address) else { return }
                    i.mailbox = i.address
                    if i.name.isEmpty { i.name = MailboxDisplay.title(i.address) }
                    mail.newIdentity = SendIdentity(address: "", name: "", mailbox: "me", mode: .sendAs)
                    Task { await mail.update { s in if !s.identities.contains(i) { s.identities.append(i) } } }
                }
                .disabled(!RecipientCheck.looksLikeAddress(mail.newIdentity.address.trimmingCharacters(in: .whitespaces)))
            }
            SignatureSettingsSections()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Device trust

struct TrustSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let t = app.trust
        let p = t.effectivePolicy
        Form {
            Section("Profile") {
                LabeledContent("Device profile") { Text(p.profile == .byod ? "Personal Mac (BYOD, unmanaged)" : "Managed Mac") }
                LabeledContent("Decision") { Text(Self.decision(t.postureDecision)) }
                if let r = t.lastRefresh { LabeledContent("Last refresh") { Text(r.formatted(date: .abbreviated, time: .standard)) } }
            }
            Section("Policy sources (applied in this order)") {
                ForEach(Array((t.loaded?.sources ?? []).enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            NSymbol(s.applied ? "checkmark.circle.fill" : "circle", size: 13, label: s.applied ? "Applied" : "Not applied").foregroundStyle(s.applied ? .green : .secondary)
                            Text(Self.sourceName(s.source))
                            Spacer()
                            if !s.keys.isEmpty { Text("\(s.keys.count) key(s)").font(.caption).foregroundStyle(.secondary) }
                        }
                        if !s.notes.isEmpty { Text(s.notes.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                Text("No tenant-hosted policy file is configured yet.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Effective controls") {
                LabeledContent("Mail history kept") { Text("\(p.cacheWindowMaxDays) days max") }
                LabeledContent("App lock") { Text(p.appLock.requireBiometric ? "Touch ID / password, after \(p.appLock.idleMinutes) min idle and on sleep" : "Off") }
                flag("Copy out of the app", p.allowCopyOut)
                flag("Screen capture", p.allowScreenCapture)
                flag("Print", p.allowPrint)
                flag("Download attachments", p.allowAttachmentsDownload)
                flag("Offline bodies for labelled mail", p.allowOfflineBodiesForLabelled)
                LabeledContent("AI / MCP access") { Text(p.aiAccess.rawValue) }
                LabeledContent("Offline grace") { Text("lock after \(p.offlineGraceDays) d, wipe after \(p.offlineWipeDays) d") }
                Text("Copy-out and screen-capture controls apply to Mail in this build; the calendar still follows labels only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Posture") {
                if let r = t.posture {
                    probe("FileVault", TrustModel.describe(r.fileVault))
                    probe("System Integrity Protection", TrustModel.describe(r.sip))
                    probe("Screen lock", TrustModel.describe(r.screenLock))
                    probe("macOS \(r.osVersion.description)", (r.osVersion < p.minimumOSVersion ? "Below \(p.minimumOSVersion.description)" : "OK",
                                                               r.osVersion < p.minimumOSVersion ? false : true))
                    probe("Code signature", TrustModel.describe(r.codeSignature))
                    probe("Secure Enclave (cache keys)", TrustModel.describe(r.secureEnclave))
                } else if t.postureChecking { ProgressView().controlSize(.small) }
                ForEach(t.postureReasons, id: \.self) { Text("• " + $0).font(.caption) }
            }
            Section {
                HStack {
                    Button("Re-check Posture") { Task { await t.checkPosture() } }.disabled(t.postureChecking)
                    Button("Reload Policy") { t.reloadPolicy() }
                    Spacer()
                    Button { t.lockNow() } label: { NLabel("Lock Now", systemImage: "lock.fill", size: 13) }
                }
                if app.isFixtureMode {
                    Button(role: .destructive) { app.mail.showSettings = false; app.simulateRemoteWipe() } label: {
                        NLabel("Simulate Remote Wipe (fixtures, in-memory only)", systemImage: "trash.slash", size: 13)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func flag(_ name: String, _ on: Bool) -> some View {
        LabeledContent(name) { NSymbol(on ? "checkmark" : "nosign", size: 13, label: on ? "On" : "Off").foregroundStyle(on ? .green : .red) }
    }

    private func probe(_ name: String, _ r: (text: String, ok: Bool?)) -> some View {
        LabeledContent(name) {
            HStack(spacing: 4) {
                NSymbol(r.ok == true ? "checkmark.circle.fill" : (r.ok == false ? "xmark.octagon.fill" : "questionmark.circle"), size: 13,
                        label: r.ok == true ? "Passed" : (r.ok == false ? "Failed" : "Unknown"))
                    .foregroundStyle(r.ok == true ? .green : (r.ok == false ? .red : .orange))
                Text(r.text)
            }
        }
    }

    static func sourceName(_ s: PolicySourceKind) -> String {
        switch s {
        case .managedForced: "Managed preferences (MDM, forced)"
        case .managedUnforced: "Managed preferences (unforced, tighten only)"
        case .tenantSigned: "Tenant-signed policy file"
        case .defaults: "Built-in defaults"
        }
    }

    static func decision(_ d: PostureDecision) -> String {
        switch d { case .allow: "Allowed"; case .restrict: "Restricted"; case .block: "Blocked" }
    }
}
