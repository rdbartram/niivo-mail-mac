import SwiftUI
import AppKit
import CalendarCore
import MailCore

/// Mail mode: sidebar (mailboxes + folders) · message list · reader. Keyboard-first; every content decision comes
/// from `ContentPolicy` via MailModel.
struct MailRootView: View {
    @Environment(AppModel.self) private var app
    /// DESK-HOOK: the Desk applies `MailRootChrome` once around all its tiles, so the Mail tile mounts content only.
    var chromeless = false

    var body: some View {
        if chromeless { content(app.mail) } else { content(app.mail).modifier(MailRootChrome()) }
    }
}

/// Mail's window-level sheets, overlays, key catchers and start-up tasks (MailRootView; the Desk applies it once).
struct MailRootChrome: ViewModifier {
    @Environment(AppModel.self) private var app
    @FocusState private var searchFocused: Bool

    func body(content: Content) -> some View {
        let mail = app.mail
        @Bindable var m = mail
        content
            .modifier(ClassicMailChrome(brand: app.theme.brand, searchFocused: $searchFocused))
            .modifier(AIMailOverlays())   // AI-HOOK (outside .searchable so onSubmit(of: .search) reaches the field)
            .modifier(ComposerPresentation(brand: app.theme.brand))   // niivo: inline / window (MailWindows.swift)
            .sheet(isPresented: $m.showPalette) { CommandPaletteView() }
            .sheet(isPresented: $m.showCheatSheet) { CheatSheetView() }
            .sheet(isPresented: $m.showSnooze) { SnoozePickerView() }
            .sheet(isPresented: $m.showCategories) { CategoryPickerView() }
            .overlay(alignment: .bottom) { ToastStack() }
            .background { MainMailWindowCapture(mail: mail); A11yHiddenKeys() }   // A11Y-HOOK
            .task { await app.startMailIfNeeded() }
            .task(id: mail.started) { if mail.started { await A11yPrefs.shared.loadRegional(mail) } }   // A11Y-HOOK
    }
}

extension MailRootView {
    @ViewBuilder fileprivate func content(_ mail: MailModel) -> some View {
        switch mail.phase {
        case .needsConsent(let msg):
            VStack {
                MailUnavailable(symbol: "key.horizontal", title: L("Mail needs permission"), text: msg)
                NButton(L("Try Again")) { mail.resetForRetry(); Task { try? await app.auth?.grantMailAccess(); await app.startMailIfNeeded() } }.padding(.bottom, 40)
            }
        case .unavailable(let msg):
            VStack {
                MailUnavailable(symbol: "exclamationmark.triangle", title: L("Mail is unavailable"), text: msg)
                NButton(L("Try Again")) { mail.resetForRetry(); Task { await app.startMailIfNeeded() } }.padding(.bottom, 40)
            }
        case .notStarted, .starting:
            ProgressView(L("Opening mail…")).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .wiped:
            MailUnavailable(symbol: "trash.slash", title: L("Mail data removed"), text: L("This Mac's mail cache was wiped."))
        case .fixtures, .live where app.theme.brand:
            MailShellView()
        case .fixtures, .live where SignalModel.shared.isActive(mail):
            NavigationSplitView {   // LOOPS-HOOK: Signal, full width
                MailSidebar().navigationSplitViewColumnWidth(min: 210, ideal: 240)
            } detail: { SignalView() }
        case .fixtures, .live where TodayModel.shared.flow != nil && TodayModel.shared.isActive(mail):
            NavigationSplitView {   // TODAY-HOOK: Flow, full width
                MailSidebar().navigationSplitViewColumnWidth(min: 210, ideal: 240)
            } detail: { TodayFlowView() }
        case .fixtures, .live:
            switch A11yPrefs.shared.prefs.pane {   // A11Y-HOOK: reading pane right / bottom / off
            case .right:
                NavigationSplitView {
                    MailSidebar().navigationSplitViewColumnWidth(min: 210, ideal: 240)
                } content: {
                    // GROUPS-HOOK: a selected M365 group replaces the message list + reader.
                    classicList(mail).navigationSplitViewColumnWidth(min: 320, ideal: 400)
                } detail: {
                    classicReader(mail)
                }
            case .bottom:
                NavigationSplitView {
                    MailSidebar().navigationSplitViewColumnWidth(min: 210, ideal: 240)
                } detail: {
                    VSplitView {
                        classicList(mail).frame(minHeight: 160, idealHeight: 300)
                        classicReader(mail).frame(minHeight: 200)
                    }
                }
            case .off:
                NavigationSplitView {
                    MailSidebar().navigationSplitViewColumnWidth(min: 210, ideal: 240)
                } detail: {
                    classicList(mail)
                }
            }
        }
    }

    @ViewBuilder private func classicList(_ mail: MailModel) -> some View {
        if mail.groups.isActive { GroupConversationListView() }
        else if TodayModel.shared.isActive(mail) { TodayView() }   // TODAY-HOOK
        else if case .promises? = mail.virtualFolder { PromisesListView() }   // PROMISES-HOOK
        else { MessageListView() }
    }

    @ViewBuilder private func classicReader(_ mail: MailModel) -> some View {
        if mail.groups.isActive && mail.composer == nil { GroupReaderView() } else { ReaderView() }
    }
}

struct MailUnavailable: View {
    @Environment(\.skin) private var skin
    var symbol: String, title: String, text: String
    var body: some View {
        if skin.brand {
            VStack(alignment: .leading, spacing: 14) {
                BrandEmptyState(symbol: symbol, eyebrow: L("Mail"), title: title.hasSuffix(".") ? title : title + ".")
                Text(text).font(skin.sans(NV.Size.body)).foregroundStyle(skin.muted).frame(maxWidth: 460, alignment: .leading)
            }
            .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { classic }
    }
    private var classic: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44, weight: .thin)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Classic themes: system search field + toolbar. niivo draws its own header (MailShell.swift).
private struct ClassicMailChrome: ViewModifier {
    @Environment(AppModel.self) private var app
    var brand: Bool
    var searchFocused: FocusState<Bool>.Binding
    func body(content: Content) -> some View {
        if brand {
            content
        } else {
            content
                .searchable(text: Bindable(app.mail).searchText, placement: .toolbar, prompt: L("Search mail"))
                .searchSuggestions {   // SEARCHBOX-HOOK: recent / people / operators in the system field
                    ForEach(SearchBoxState.shared.suggestions) { s in Text(s.title).searchCompletion(s.completion) }
                }
                .onSubmit(of: .search) {   // SEARCHBOX-HOOK: ↩ = Ask mode / ⌥↩ (AI-HOOK), else natural search + server
                    if app.mail.ai.askMode || NSEvent.modifierFlags.contains(.option) { app.mail.ai.searchSubmitted() } else { app.mail.submitSearch() }
                }
                .searchFocused(searchFocused)
                .onChange(of: app.mail.focusSearchToken) { searchFocused.wrappedValue = true }
                .toolbar { MailToolbar() }
        }
    }
}

/// Mail ⇄ Calendar switch, shown in both sections' toolbars (⌃⌘1 / ⌃⌘2).
struct SectionSwitch: ToolbarContent {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow   // PEOPLE2-HOOK
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {   // PEOPLE2-HOOK: People directory (⌃⌘5)
            Button { KnowledgeHub.shared.openDirectory(openWindow: openWindow) } label: { Label(L("People"), systemImage: "person.2") }
                .labelStyle(.iconOnly).help(L("People directory (⌃⌘5)"))
        }
        ToolbarItem(placement: .navigation) {
            Picker(L("Section"), selection: Bindable(app).section) {
                ForEach(AppModel.AppSection.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s) }
            }
            .pickerStyle(.segmented).labelStyle(.iconOnly).fixedSize()
            .help(L("Mail (⌃⌘1) · Calendar (⌃⌘2)"))
        }
    }
}

struct MailToolbar: ToolbarContent {
    @Environment(AppModel.self) private var app
    var body: some ToolbarContent {
        let mail = app.mail
        let hasSel = mail.selectedRow != nil
        ToolbarItemGroup(placement: .primaryAction) {
            MailSyncBadge()
            if mail.ai.enabled {   // AI-HOOK: Ask toggle (classic themes; niivo has it in MailHeaderBar)
                Toggle(isOn: Bindable(mail.ai).askMode) { Label(L("Ask"), systemImage: "sparkle.magnifyingglass") }
                    .help(L("Natural-language search: type, then ↩ (or ⌥↩ any time)"))
            }
            Button { mail.run(.compose) } label: { Label(L("New Message"), systemImage: "square.and.pencil") }.help(L("New message (C or ⌘N)"))
            Button { mail.run(.reply) } label: { Label(L("Reply"), systemImage: "arrowshape.turn.up.left") }.help(L("Reply (R)")).disabled(!hasSel)
            Button { mail.run(.archive) } label: { Label(L("Archive"), systemImage: "archivebox") }.help(L("Archive (E)")).disabled(!hasSel)
            Button { mail.run(.delete) } label: { Label(L("Delete"), systemImage: "trash") }.help(L("Delete (#)")).disabled(!hasSel)
            Button { mail.run(.flag) } label: { Label(L("Flag"), systemImage: "flag") }.help(L("Flag (S)")).disabled(!hasSel)
            Button { mail.run(.snooze) } label: { Label(L("Snooze"), systemImage: "clock") }.help(L("Snooze (H)")).disabled(!hasSel)
            Toggle(isOn: Bindable(mail).groupConversations) { Label(L("Conversations"), systemImage: "bubble.left.and.bubble.right") }
                .toggleStyle(.button).help(L("Group by conversation (⇧T)"))
            Button { mail.run(.palette) } label: { Label(L("Commands"), systemImage: "command") }.help(L("Command palette (⌘K)"))
            Button { mail.showSettings = true } label: { Label(L("Settings"), systemImage: "gearshape") }.help(L("Mail settings (⌘,)"))
        }
    }
}

struct MailSyncBadge: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let s = app.mail.status
        HStack(spacing: 6) {
            switch s.phase {
            case .syncing: ProgressView().controlSize(.small); Text(L("Syncing"))
            case .offline: NSymbol("icloud.slash", size: 10).foregroundStyle(.orange); Text(L("Offline"))
            case .error: NSymbol("exclamationmark.triangle.fill", size: 10).foregroundStyle(.red); Text(L("Sync error"))
            case .idle:
                // Quiet when all is well (Ryan 2026-11-19: a ticking "12 sec ago" counter is noise). Time on hover.
                NSymbol("checkmark.icloud", size: 10, label: L("Synced")).foregroundStyle(.green)
                if let d = s.lastSync { Text(d.formatted(date: .omitted, time: .shortened)).textCase(skin.brand ? .uppercase : nil) }
            }
            if !s.throttledUntil.isEmpty { NSymbol("tortoise", size: 10, label: L("Throttled")).help(L("Exchange is throttling; backing off")) }
            if app.mail.isFixtures {
                if skin.brand { MonoLabel(L("Fixtures"), size: NV.Size.labelSm, color: skin.ink).fixedSize().padding(.horizontal, 5).padding(.vertical, 1).overlay(Rectangle().strokeBorder(skin.ink, lineWidth: 1)) }
                else { Text(L("Fixtures")).padding(.horizontal, 5).background(.yellow.opacity(0.25), in: Capsule()) }
            }
        }
        .font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption).foregroundStyle(.secondary).padding(.horizontal, 6)
        .lineLimit(1)
        // Fixed slot: switching Syncing ↔ Synced must not shift the search field next to it.
        .frame(width: 128, alignment: .trailing)
        .help(s.phase == .idle ? (s.lastSync.map { "Last synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Synced")
                               : (s.notes.last ?? ""))
    }
}

// MARK: - Sidebar

struct MailSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @FocusState private var focused: Bool

    var body: some View {
        let mail = app.mail
        List(selection: Bindable(mail).selectedFolderId) {
            SidebarAccountsSwitcher()   // ACCOUNTS-HOOK: accounts as top-level groups (AccountsViews.swift)
            TodaySidebarSection()   // TODAY-HOOK (TodayViews.swift)
            FavouritesSidebarSection()   // ORG2-HOOK (MailOrg2Views.swift)
            SmartViewsSidebarSection()   // SMART VIEWS + unified inbox (MailOrganiseViews.swift)
            ForEach(mail.mailboxes, id: \.self) { mb in
                Section {
                    MailboxErrorRow(mailbox: mb)   // MAILBOXES-HOOK
                    if mail.mailboxManager.isCollapsed(mb) {
                        EmptyView()
                    } else if mail.openedMailboxes.contains(mb) || !(mail.folders[mb] ?? []).isEmpty {
                        ForEach(mail.folderRows(mb)) { r in FolderRow(folder: r.folder, row: r).tag(Optional(r.id)).folderActions(r.folder, mail: mail) }
                    } else {
                        Button { Task { await mail.openMailbox(mb) } } label: {
                            NLabel(L("Open mailbox"), systemImage: "tray.and.arrow.down", size: 13)
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help(L("Shared and delegated mailboxes sync on first open, or in the background when pinned"))
                    }
                } header: { MailboxHeader(mailbox: mb).contextMenu { MailboxContextMenu(mailbox: mb) } }
            }
            AddMailboxRow()          // MAILBOXES-HOOK
            GroupsSidebarSection()   // GROUPS-HOOK
        }
        .listStyle(.sidebar)
        .focused($focused)   // A11Y-HOOK: pane focus cycle
        .onChange(of: MailFocus.shared.sidebarToken) { focused = true }
        .onChange(of: focused) { _, on in if on { MailFocus.shared.current = .sidebar } }
        .onKeyPress(phases: .down) { press in
            if press.key == .escape { mail.focusListToken += 1; return .handled }
            if press.key == .upArrow || press.key == .downArrow { MailFocus.shared.holdSidebar(); return .ignored }   // List moves itself
            return MailFocus.shared.tabKey(press, mail: mail)
        }
        .accessibilityLabel(L("Mailboxes and folders"))
        .folderDialogs()
        .addMailboxSheet()   // MAILBOXES-HOOK
        .scrollContentBackground(skin.brand ? .hidden : .automatic)
        .background(skin.brand ? skin.ground : .clear)
        .safeAreaInset(edge: .bottom) {
          VStack(spacing: 0) {
            SyncStatusRow()   // LIFECYCLE-HOOK: offline / throttled / sign-in / CAE
            HStack(spacing: 8) {
                if skin.brand {
                    NiivoWordmark(size: 15, blinks: false, color: skin.ink).accessibilityHidden(true)
                    Spacer()
                    MonoLabel(app.trust.policy.profile == .byod ? "BYOD" : "Managed", size: NV.Size.labelSm)
                        .help(app.trust.policy.profile == .byod ? "Personal Mac (BYOD) policy" : "Managed Mac policy")
                } else {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text(app.trust.policy.profile == .byod ? "Personal Mac (BYOD) policy" : "Managed Mac policy")
                    Spacer()
                }
                Button { app.trust.lockNow() } label: { NSymbol("lock", size: 10, label: L("Lock now")) }.buttonStyle(.borderless).help(L("Lock now"))
                    .accessibilityLabel(L("Lock now"))
            }
            .font(.caption).foregroundStyle(.secondary).padding(10)
            .hairline(skin, edge: .top)
          }
        }
    }
}

struct MailboxHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var mailbox: String
    var body: some View {
        let mail = app.mail
        let pinned = mail.settings.pinnedMailboxes.contains(mailbox)
        HStack(spacing: 6) {
            MailboxCollapseToggle(mailbox: mailbox)   // MAILBOXES-HOOK
            MailboxBadge(mailbox: mailbox, size: 16)
            if skin.brand { MonoLabel(MailboxDisplay.title(mailbox), color: skin.ink, wide: true).lineLimit(1) }
            else { Text(MailboxDisplay.title(mailbox)).lineLimit(1) }
            if let mode = mail.settings.identities.first(where: { $0.mailbox == mailbox && mailbox != "me" })?.mode {
                if skin.brand { MonoLabel(mode == .sendAs ? "Shared" : "Delegate", size: NV.Size.labelSm) }
                else { Text(mode == .sendAs ? "Shared" : "Delegate").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if mailbox != "me" {
                Button { Task { await mail.setPinned(mailbox, !pinned) } } label: {
                    NSymbol(pinned ? "pin.fill" : "pin", size: 10, label: pinned ? "Unpin mailbox" : "Pin mailbox")
                }
                .buttonStyle(.borderless)
                .help(pinned ? "Pinned: syncs in the background. Click to unpin." : "Pin to sync in the background")
            }
        }
        .mailboxHeaderMenu(mailbox)   // MAILBOXES-HOOK
    }
}

struct FolderRow: View {
    @Environment(\.skin) private var skin
    var folder: MailFolder
    var row: FolderTreeRow? = nil
    var body: some View {
        HStack(spacing: 4) {
            FolderDisclosure(row: row).padding(.leading, CGFloat(row?.depth ?? 0) * 14)
            Label { FolderName(folder: folder, font: skin.brand ? skin.sans(NV.Size.body) : .body) } icon: {
                NSymbol(MailboxDisplay.folderSymbol(folder), size: 13).fontWeight(skin.brand ? .light : nil)
                    .foregroundStyle(skin.brand ? skin.muted : Color.accentColor)
            }
            Spacer()
            // Server counts (`unreadItemCount`), never a local COUNT(*).
            if folder.unreadCount > 0 {
                Text("\(folder.unreadCount)").font(skin.brand ? skin.mono(NV.Size.label) : .caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// Initials on the mailbox's stable colour (same palette + hash as calendars).
struct MailboxBadge: View {
    @Environment(\.skin) private var skin
    var mailbox: String
    var size: CGFloat = 16
    var body: some View {
        Text(MailboxDisplay.initials(mailbox))
            .font(skin.brand ? skin.mono(size * 0.44, .medium) : .system(size: size * 0.46, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                if skin.brand { Rectangle().fill(Color(hex: MailboxDisplay.colorHex(mailbox))) }
                else { Circle().fill(Color(hex: MailboxDisplay.colorHex(mailbox)).gradient) }
            }
            .help(MailboxDisplay.title(mailbox))
    }
}

// MARK: - Message list

struct MessageListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @FocusState private var listFocused: Bool

    var body: some View {
        let mail = app.mail
        VStack(spacing: 0) {
            if mail.oofActive { OOFBanner() }
            if mail.showsSplitTabs { SplitTabs() }
            if mail.searchResults != nil || mail.searching { SearchHeader(); KnowledgeAnswerCard() }   // PEOPLE-HOOK: Ask answer card
            ListFilterBar()                                  // SMART VIEWS: Outlook-style filters (MailBulk.swift)
            if MailChrome.shared.marked.count > 1, MailChrome.shared.targets(mail).count > 1 { BulkBar() }   // BULK: count + actions for a multi-selection
            StoryListSwitch(mail: mail) { list(mail) }   // STORY-HOOK: Stories grouping mode (StoryViews.swift)
        }
        .background(app.theme.brand ? AnyShapeStyle(app.skin.ground)
                    : (app.theme.fill == .glass ? AnyShapeStyle(app.theme.gridBackground) : AnyShapeStyle(.background)))
        .navigationTitle(mail.listTitle)
        .organiseSheets()   // BULK / SWEEP / SEARCH: move picker, sweep sheet, save-search alert (MailOrganiseSheets.swift)
        .navigationSubtitle(MailboxDisplay.title(mail.selectedMailbox))
    }

    private func list(_ mail: MailModel) -> some View {
        let rows = mail.visibleRows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: app.theme.brand ? 0 : 2) {
                    let brand = app.theme.brand
                    let chrome = MailChrome.shared
                    let marked = chrome.marked
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        if brand {
                            // niivo: custom surface (hover / selection / multi-select), ⌘/⇧-click, drag to a folder.
                            SwipeableRow(row: row) { ListRowContent(row: row, selected: row.id == mail.selectedMessageId) }   // THREAD-HOOK
                                .nRow(selected: row.id == mail.selectedMessageId, marked: marked.contains(row.id), hoverKey: AnyHashable(row.id), skin: app.skin)
                                .id(row.id)
                                .onTapGesture {
                                    chrome.click(row.id, mail: mail); listFocused = true
                                    // A draft opens straight into the editor (as in Outlook), no double-click needed.
                                    if row.message.isDraft, chrome.marked.count <= 1 { mail.openDraft(id: row.id) }
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    if row.message.isDraft { mail.openDraft(id: row.id) } else { openWindow(id: "message", value: row.id) }
                                })
                                .draggable(BulkDrag.payload(row: row, rows: rows, marked: marked)) {
                                    MonoLabel(BulkDrag.title(row: row, marked: marked),
                                              color: app.skin.ink).padding(8).background(app.skin.card).overlay(Rectangle().strokeBorder(app.skin.ink, lineWidth: 1))
                                }
                                .onAppear { mail.rowAppeared(index: i) }
                                .contextMenu { RowMenu(row: row) }
                        } else {
                            SwipeableRow(row: row) { ListRowContent(row: row, selected: row.id == mail.selectedMessageId) }   // THREAD-HOOK
                                .id(row.id)
                                .onHover { inside in
                                    let ui = NUI.shared
                                    if inside { ui.hovered = AnyHashable(row.id) } else if ui.hovered == AnyHashable(row.id) { ui.hovered = nil }
                                }
                                .background {
                                    if marked.contains(row.id) && marked.count > 1 {
                                        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.16))
                                    }
                                }
                                .onTapGesture {
                                    chrome.click(row.id, mail: mail); listFocused = true   // ⌘/⇧-click multi-select
                                    if row.message.isDraft, chrome.marked.count <= 1 { mail.openDraft(id: row.id) }
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {   // A11Y-HOOK: double-click opens (needed with the pane off)
                                    if row.message.isDraft { mail.openDraft(id: row.id) } else { openWindow(id: "message", value: row.id) }
                                })
                                .draggable(BulkDrag.payload(row: row, rows: rows, marked: marked)) {
                                    Text(BulkDrag.title(row: row, marked: marked)).padding(6)
                                }
                                .onAppear { mail.rowAppeared(index: i) }
                                .contextMenu { RowMenu(row: row) }
                        }
                    }
                    if mail.isLoadingMore { ProgressView().controlSize(.small).padding() }
                    else if rows.isEmpty { EmptyList() }
                }
                .padding(.horizontal, app.theme.brand ? 0 : 6).padding(.vertical, app.theme.brand ? 0 : 4)
            }
            .onAppear { RowSwipe.shared.install(mail) }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .paneFocusRing(listFocused, skin: app.skin)   // A11Y-HOOK: visible focus in both skins
            .accessibilityLabel(L("Messages"))
            .messageListRotors(rows)
            .onAppear {   // Fixture-only demo aid (synthetic data): open the first message in its own window.
                if ProcessInfo.processInfo.environment["CC_DEMO_OPEN_MESSAGE"] == "1", CommandLine.arguments.contains("--fixtures"),
                   let r = rows.first(where: { !$0.message.isDraft }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openWindow(id: "message", value: r.id) }
                }
            }
            .onKeyPress(phases: .down) { press in
                if MailFocus.shared.tabKey(press, mail: mail) == .handled { return .handled }   // A11Y-HOOK: Tab / shift-Tab
                // A11Y-HOOK: reading pane off → Return opens the message in its own window (drafts keep the composer).
                if A11yPrefs.shared.prefs.pane == .off, press.key == .return, press.modifiers.isEmpty,
                   MailChrome.shared.marked.count <= 1, let r = mail.selectedRow, !r.message.isDraft {
                    openWindow(id: "message", value: r.id); return .handled
                }
                // Multi-select (both skins): ⇧↑/⇧↓ extend, esc clears, triage keys act on the whole selection.
                do {
                    let chrome = MailChrome.shared
                    if press.modifiers.contains(.shift), press.key == .downArrow || press.key == .upArrow {
                        chrome.extendByKey(press.key == .downArrow ? 1 : -1, mail: mail); return .handled
                    }
                    if press.key == .escape, chrome.marked.count > 1 { chrome.marked = []; return .handled }
                    if chrome.marked.count > 1, let cmd = MailKeymap.command(for: .character(press.characters),
                                                                             command: press.modifiers.contains(.command), control: press.modifiers.contains(.control)),
                       chrome.bulk(cmd, mail: mail) { return .handled }
                    let gmailKeeps = MailListUI.shared.keymap == .gmail && press.modifiers.isEmpty && ["x", "j", "k"].contains(press.characters)   // THREAD-HOOK
                    if !gmailKeeps, press.modifiers.isEmpty || press.key == .downArrow || press.key == .upArrow { chrome.marked = []; chrome.anchor = nil }
                }
                return MailKeys.handle(press, mail: mail)
            }
            .onChange(of: mail.selectedMessageId) { _, id in
                if let id { NMotion.with(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }   // A11Y: Reduce Motion
            }
            // A11Y-HOOK: one runloop turn later, so a click that lands focus elsewhere (sidebar) doesn't win the race.
            .onChange(of: mail.focusListToken) {
                if MailFocus.shared.keepSidebar { MailFocus.shared.keepSidebar = false; return }   // sidebar ↑↓
                DispatchQueue.main.async { listFocused = true }
            }
            .onChange(of: listFocused) { _, on in if on { MailFocus.shared.current = .list } }
            .onAppear { listFocused = true }
        }
    }
}

/// Bare-key triage. Text fields keep their keys (they have focus); the web view forwards unhandled keys here.
enum MailKeys {
    @MainActor static func handle(_ press: KeyPress, mail: MailModel) -> KeyPress.Result {
        let key: MailKeymap.Key
        switch press.key {
        case .return: key = .returnKey
        case .delete, .deleteForward: key = .deleteKey
        case .downArrow: key = .downArrow
        case .upArrow: key = .upArrow
        case .escape: key = .escape
        default: key = .character(press.characters)
        }
        if press.modifiers.isEmpty, TodayModel.shared.handleKey(press.characters, escape: press.key == .escape, mail: mail) { return .handled }   // TODAY-HOOK
        if press.modifiers.subtracting(.shift).isEmpty, MailOrg2.shared.handleKey(press.characters, mail: mail) { return .handled }   // ORG2-HOOK
        if press.modifiers.isEmpty, ConversationHub.shared.gmailKey(key, mail: mail) { return .handled }   // THREAD-HOOK: Gmail n/p/o/x/u
        guard let cmd = MailKeymap.command(for: key, command: press.modifiers.contains(.command),
                                           control: press.modifiers.contains(.control)) else { return .ignored }
        mail.run(cmd)
        return .handled
    }

    /// Same mapping for raw AppKit events (from the reader's WKWebView).
    @MainActor static func handle(_ e: NSEvent, mail: MailModel) -> Bool {
        let f = e.modifierFlags
        let key: MailKeymap.Key
        switch e.keyCode {
        case 36, 76: key = .returnKey
        case 51, 117: key = .deleteKey
        case 125: key = .downArrow
        case 126: key = .upArrow
        case 53: key = .escape
        default: key = .character(e.characters ?? "")
        }
        if f.intersection([.command, .control, .option, .shift]).isEmpty,
           TodayModel.shared.handleKey(e.characters ?? "", escape: e.keyCode == 53, mail: mail) { return true }   // TODAY-HOOK
        if f.intersection([.command, .control, .option]).isEmpty, ConversationHub.shared.gmailKey(key, mail: mail) { return true }   // THREAD-HOOK
        guard let cmd = MailKeymap.command(for: key, command: f.contains(.command), control: f.contains(.control)) else { return false }
        mail.run(cmd)
        return true
    }
}

struct EmptyList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        if skin.brand {
            let search = app.mail.searchResults != nil
            BrandEmptyState(symbol: search ? "magnifyingglass" : "tray",
                            eyebrow: search ? "Search" : (app.mail.showsSplitTabs ? SplitTabs.title(app.mail.splitTab) : "Folder"),
                            title: search ? "No results." : (app.mail.showsSplitTabs ? "Nothing here. Nice." : "No messages."),
                            hint: search ? nil : "C — new message")
                .padding(.top, 60).frame(maxWidth: .infinity)
        } else { classic }
    }
    private var classic: some View {
        VStack(spacing: 8) {
            Image(systemName: app.mail.searchResults != nil ? "magnifyingglass" : "tray").font(.largeTitle.weight(.thin))
            Text(app.mail.searchResults != nil ? "No results" : (app.mail.showsSplitTabs ? "Nothing here. Nice." : "No messages"))
        }
        .foregroundStyle(.secondary).padding(.top, 60).frame(maxWidth: .infinity)
    }
}

struct SplitTabs: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail
        if app.theme.brand {
            NVTabBar(title: L("Inbox"), items: InboxBucket.allCases, selection: Bindable(mail).splitTab,
                     label: { Self.title($0) }, count: { mail.splitCount($0) })
        } else {
            Picker(L("Inbox"), selection: Bindable(mail).splitTab) {
                ForEach(InboxBucket.allCases, id: \.self) { b in
                    let n = mail.splitCount(b)
                    Text(n > 0 ? "\(Self.title(b)) \(n)" : Self.title(b)).tag(b)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }
    static func title(_ b: InboxBucket) -> String {
        switch b { case .important: "Important"; case .other: "Other"; case .newsletters: "Newsletters"; case .notifications: "Notifications" }
    }
}

struct SearchHeader: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let scope = MailListUI.shared.searchScope
        let where_ = scope == .allMailboxes ? "all mailboxes"
            : (scope == .folder ? (app.mail.selectedFolder?.displayName ?? "this folder") : MailboxDisplay.title(app.mail.selectedMailbox))
        VStack(spacing: 0) {
            HStack {
                if app.mail.searching { ProgressView().controlSize(.small) }
                Text(app.mail.searching ? "Searching this Mac and the server…"
                                        : "\(app.mail.searchResults?.count ?? 0) results in \(where_)")
                Spacer()
                SearchSortToggle()   // SEARCHBOX-HOOK: Best match / Newest
                Button(L("Clear")) { app.mail.searchText = "" }.buttonStyle(.borderless)
            }
            .font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .caption).textCase(app.theme.brand ? .uppercase : nil)
            .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 5)
            SearchScopeBar()   // SEARCH SCOPE: folder / mailbox / all mailboxes, groups, recent + saved (MailOrganiseSheets.swift)
        }
        .hairline(app.skin)
    }
}

struct OOFBanner: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: 8) {
            NSymbol("airplane", size: app.theme.brand ? NV.Size.bodySm : 12).foregroundStyle(.orange)
            if let until = app.mail.oofUntil {
                Text(L("Automatic replies are on until %@", A11yPrefs.shared.regional.dateTime(until)))
            } else { Text(L("Automatic replies are on")) }
            Spacer()
            Button(L("Settings")) { app.mail.settingsTab = .autoReplies; app.mail.showSettings = true }.buttonStyle(.borderless)
            Button(L("Turn Off")) { Task { await app.mail.turnOffAutoReplies() } }.buttonStyle(.borderless)
        }
        .font(app.theme.brand ? app.skin.sans(NV.Size.bodySm) : .callout).padding(.horizontal, 12).padding(.vertical, 7)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .leading) { if app.theme.brand { Rectangle().fill(.orange).frame(width: 3) } }
    }
}

struct RowMenu: View {
    @Environment(AppModel.self) private var app
    var row: MailRow
    var body: some View {
        let marked = MailChrome.shared.marked
        if marked.count > 1 && marked.contains(row.id) { BulkRowMenu() } else { single }   // BULK
    }
    @ViewBuilder private var single: some View {
        let mail = app.mail
        // Disabled per the label's usage rights (menu items can't show tooltips, so .help is best effort).
        Button(L("Reply")) { mail.reply(.reply, to: row.id) }
            .disabled(!MailActionRights.allows(.reply, policy: row.policy))
            .help(MailActionRights.help(.reply, policy: row.policy, otherwise: "Reply"))
        Button(L("Reply All")) { mail.reply(.replyAll, to: row.id) }
            .disabled(!MailActionRights.allows(.replyAll, policy: row.policy))
            .help(MailActionRights.help(.replyAll, policy: row.policy, otherwise: "Reply all"))
        Button(L("Forward")) { mail.reply(.forward, to: row.id) }
            .disabled(!MailActionRights.allows(.forward, policy: row.policy))
            .help(MailActionRights.help(.forward, policy: row.policy, otherwise: "Forward"))
        if row.message.hasAttachments {   // COMPOSE-HOOK
            Button(L("Reply with Attachments")) { mail.replyWithAttachments(.reply, to: row.id) }
                .disabled(!MailActionRights.allows(.reply, policy: row.policy) || !MailActionRights.allows(.forward, policy: row.policy))
        }
        Divider()
        Button(row.message.isRead ? "Mark as Unread" : "Mark as Read") { mail.triage(.markRead(!row.message.isRead), id: row.id) }
        Button(row.message.flag.status == .flagged ? "Clear Flag" : "Flag") {
            mail.triage(.flag(FollowUpFlag(status: row.message.flag.status == .flagged ? .notFlagged : .flagged)), id: row.id)
        }
        OrganiseRowMenu(row: row)   // move to, sweep, categorise (MailOrganiseViews.swift)
        TriageRowMenu(row: row)   // TRIAGE2-HOOK: who acts next (conversation state correction)
        Org2RowMenu(row: row)   // ORG2-HOOK: trays, ignore, VIP, person view, quick steps
        Divider()
        Button(L("Delete"), role: .destructive) { mail.triage(.delete, id: row.id) }
    }
}

/// THREAD-HOOK: a store-grouped conversation renders as ConversationRow (ConversationRow.swift), everything else as MessageRowView.
struct ListRowContent: View {
    var row: MailRow
    var selected: Bool
    var body: some View {
        if let t = row.thread { ConversationRow(row: row, thread: t, selected: selected) } else { MessageRowView(row: row, selected: selected) }
    }
}

/// Message-list row, Gmail-style (2026-11-20, docs/LIST-LAYOUT.md): one calm line at a fixed height — unread mark,
/// avatar, sender (bold when unread), subject + grey snippet, at most two badges (label chip first, always), date.
/// Everything else (flag, importance, VIP, snoozed, via, mailbox, categories, waiting-to-sync) shows on the selected row
/// only; hovering swaps the date for the action strip (RowQuickStrip). VoiceOver still reads every state
/// (`messageRowAccessibility`).
struct MessageRowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var row: MailRow
    var selected: Bool
    /// THREAD-HOOK: a store-grouped conversation (ConversationRow) renders through this same row: participants instead
    /// of the sender, the thread's count / unread / flag / attachments, the strictest label, and a snippet only when the
    /// newest message's own policy allows it as well.
    var thread: MailThreadSummary? = nil

    var body: some View {
        let m = row.message
        let p = row.policy
        let theme = app.theme
        let b = skin.brand
        let prefs = A11yPrefs.shared.prefs
        let clean = prefs.cleanList
        let unread = thread.map(\.hasUnread) ?? !m.isRead
        let two = ListRowLayout.twoLine(prefs.pane)
        HStack(alignment: .center, spacing: prefs.density == .compact ? 8 : 10) {
            if b {
                // Unread: an ink cut ı (cyan is reserved for the selection bar, the one cyan element in the list).
                NiivoCut(height: 11, color: unread ? skin.ink : .clear).frame(width: 6)
                    .accessibilityHidden(true)
            } else {
                Circle().fill(unread ? theme.accent : Color.clear).frame(width: 7, height: 7)
            }
            if ListRowLayout.showsAvatar(prefs.density, clean: clean, avatarsOn: MailOrg2.shared.showAvatars) {   // ORG2-HOOK
                SenderAvatar(who: p.redactDetails ? nil : m.from, size: prefs.density == .roomy ? 30 : 24)
            }
            if two {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        sender(m, p, unread: unread)
                        Spacer(minLength: 6)
                        if ListRowLayout.showsSecondary(selected: selected, clean: clean) { secondary(m, p) }
                        date(m, unread: unread)
                    }
                    HStack(spacing: 6) {
                        subjectAndSnippet(m, p, unread: unread, clean: clean, previewLines: prefs.previewLines).layoutPriority(1)
                        Spacer(minLength: 4)
                        badges(m, p, clean: clean)
                    }
                }
            } else {
                sender(m, p, unread: unread)
                    .frame(width: senderWidth(prefs.density), alignment: .leading)
                subjectAndSnippet(m, p, unread: unread, clean: clean, previewLines: prefs.previewLines)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                if ListRowLayout.showsSecondary(selected: selected, clean: clean) { secondary(m, p) }
                badges(m, p, clean: clean)
                date(m, unread: unread)
            }
        }
        .frame(height: ListRowLayout.rowHeight(prefs.density, twoLine: two) - (b ? 0 : 2))   // A11Y-HOOK: density → one fixed height
        .padding(.horizontal, b ? 14 : 10)
        .contentShape(Rectangle())
        .background {
            // niivo: the list's .nRow draws hover / selection / multi-select.
            if !b {
                RoundedRectangle(cornerRadius: max(theme.corner, 4), style: .continuous)
                    .fill(selected ? theme.accent.opacity(0.16) : Color.clear)
            }
        }
        .overlay(alignment: .leading) {
            if !b && theme.leadingBar > 0 && selected { Rectangle().fill(theme.accent).frame(width: theme.leadingBar) }
        }
        .opacity(m.pendingSync ? 0.75 : 1)
        .messageRowAccessibility(row, selected: selected, mail: app.mail)   // A11Y-HOOK: gated label + row actions
    }

    private func senderWidth(_ d: ListDensity) -> CGFloat { d == .compact ? 150 : 170 }

    private func date(_ m: MailMessage, unread: Bool) -> some View {
        let b = skin.brand
        return Text(b ? Self.time(m.received).uppercased() : Self.time(m.received))
            .font(b ? skin.mono(NV.Size.labelSm) : .caption.monospacedDigit())
            .fontWeight(unread ? .semibold : .regular)
            .foregroundStyle(unread ? (b ? skin.ink : .primary) : .secondary)
            .lineLimit(1).fixedSize()
    }

    @ViewBuilder private func sender(_ m: MailMessage, _ p: ContentPolicy, unread: Bool) -> some View {
        let b = skin.brand
        let font: Font = b ? skin.sans(NV.Size.body, unread ? .semibold : .regular) : (unread ? .body.weight(.semibold) : .body)
        if let t = thread {
            // Gmail: participants over the reader set, and every message you see in the conversation (replies included).
            let names = p.redactDetails ? L("Private") : MailThreads.participantLine(t.readerMembers, me: app.mail.meAddresses)
            HStack(spacing: 4) {
                Text(names).font(font).foregroundStyle(b ? skin.ink : .primary).lineLimit(1).truncationMode(.tail)
                if t.readerMembers.count > 1 {
                    Text("\(t.readerMembers.count)").font(b ? skin.mono(NV.Size.labelSm) : .caption).foregroundStyle(.secondary).fixedSize()
                        .accessibilityLabel(L("%d messages", t.readerMembers.count))
                }
            }
        } else {
            HStack(spacing: 4) {
                Text(p.redactDetails ? "Private" : (m.from?.display ?? "(no sender)"))
                    .font(font)
                    .foregroundStyle(b ? skin.ink : .primary).lineLimit(1).truncationMode(.tail)
                    .presenceDot(p.redactDetails || MailOrg2.shared.showAvatars ? nil : m.from?.address)   // PEOPLE-HOOK; ORG2-HOOK: on the avatar when shown
                    .senderHoverCard(p.redactDetails ? nil : m.from)   // ORG2-HOOK: hover card (MailAvatars.swift)
                if row.count > 1 {
                    Text("\(row.count)").font(b ? skin.mono(NV.Size.labelSm) : .caption).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
    }

    /// The label slot: a glyph only for labels that matter, the chip when the user turned chips on (ListRowLayout.labelMark).
    private func labelMark(_ m: MailMessage, _ p: ContentPolicy) -> LabelRowMark {
        ListRowLayout.labelMark(LabelDisplay.decide(p, origin: labelOrigin(m)), rank: nil,
                                confidentialRank: ListLabelRanks.shared.confidential(app.mail.compliance),
                                showChips: A11yPrefs.shared.prefs.showLabelChips)
    }

    /// A conversation's strictest label may come from another member: its provenance isn't the newest message's, so
    /// only labels in our tree show (the old ConversationRow rule).
    private func labelOrigin(_ m: MailMessage) -> LabelOrigin? { thread == nil ? m.labelOrigin : nil }

    /// "Subject — snippet" on one line; the snippet in grey. Redacted / not-stored rows say so instead.
    private func subjectAndSnippet(_ m: MailMessage, _ p: ContentPolicy, unread: Bool, clean: Bool, previewLines: Int) -> some View {
        let b = skin.brand
        let subject = p.redactDetails ? "Private message" : (m.subject.isEmpty ? "(no subject)" : m.subject)
        let snippet: String? = {
            if p.redactDetails { return nil }
            if thread != nil {   // the newest message's own policy must allow the snippet too
                let own = app.mail.policy(for: m, mailbox: row.mailbox)
                if own.redactDetails || !own.allowOfflineDetails { return nil }
            }
            if selected, !clean, let ask = app.mail.ai.display(for: row)?.ask, !ask.isEmpty { return ask }   // TRIAGE2-HOOK   // AI-HOOK: "needs you" on the selected row
            if let s = ListRowLayout.snippet(m.preview, previewLines: previewLines) { return s }
            return !p.allowOfflineDetails && previewLines > 0 ? L("Preview not stored on this Mac for this label") : nil
        }()
        let subjText: AttributedString = p.redactDetails || m.subject.isEmpty ? AttributedString(subject) : SearchBoxState.shared.marked(m.subject, skin: skin)   // SEARCHBOX-HOOK: highlight
        let subj = Text(subjText).font(b ? skin.sans(NV.Size.body, unread ? .medium : .regular) : .callout.weight(unread ? .medium : .regular))
            .foregroundStyle(b ? skin.ink : .primary)
        let line = snippet.map { s in
            subj + Text(AttributedString("  —  ") + SearchBoxState.shared.marked(s, skin: skin)).font(b ? skin.sans(NV.Size.bodySm) : .callout).foregroundStyle(.secondary)
        } ?? subj
        return HStack(spacing: 5) {
            if ListRowLayout.showsBodyLock(bodyIsProtected: p.bodyIsProtected, mark: labelMark(m, p)) {
                NSymbol("lock.fill", size: 9, label: L("Encrypted")).foregroundStyle(.secondary)   // compliance: encryption the label mark doesn't show
            }
            line.lineLimit(1).truncationMode(.tail)
        }
    }

    /// At most two: label mark (when there is one), reply-needed / waiting, attachment (ListRowLayout.badges).
    @ViewBuilder private func badges(_ m: MailMessage, _ p: ContentPolicy, clean: Bool) -> some View {
        let triage = p.redactDetails ? nil : app.mail.ai.display(for: row)   // AI-HOOK, TRIAGE2-HOOK: conversation state
        let t: ListRowBadge? = triage?.badge
        let mark = labelMark(m, p)
        let attachment = thread.map { $0.members.contains(where: \.hasAttachments) } ?? m.hasAttachments
        let list = ListRowLayout.badges(label: mark != .none, triage: t, attachment: attachment, clean: clean)
        HStack(spacing: 5) {
            if !p.redactDetails, let c = LoopsModel.shared.confirmed[m.conversationId] { LoopChip(chip: c, compact: true) }   // LOOPS-HOOK
            ForEach(list, id: \.self) { badge in
                switch badge {
                case .label:
                    if mark == .chip { LabelChip(policy: p, origin: labelOrigin(m)) } else { LabelGlyphMark(policy: p, mark: mark) }
                case .replyNeeded, .waiting:
                    let title = triage?.title ?? ""
                    Text(skin.brand ? title.uppercased() : title)
                        .font(skin.brand ? skin.mono(9, .medium) : .caption2.weight(.semibold)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .foregroundStyle(skin.brand ? skin.accentInk : Color.accentColor)
                        .overlay { if skin.brand { Rectangle().strokeBorder(skin.accentInk.opacity(0.6), lineWidth: 1) } }
                        .background { if !skin.brand { Capsule().fill(Color.accentColor.opacity(0.14)) } }
                        .help(triage.map { $0.explain + ($0.ask.map { "\n\($0)" } ?? "") + (app.mail.ai.usesConversationTriage ? "\nClick to change" : "") } ?? "")
                        .onTapGesture { if app.mail.ai.usesConversationTriage { app.mail.ai.inbox.cycle(row) } }   // TRIAGE2-HOOK: one-click correction
                        .contextMenu { TriageRowMenu(row: row) }
                case .attachment:
                    NSymbol("paperclip", size: 10, label: L("Attachment")).foregroundStyle(.secondary)
                }
            }
            if !clean, triage?.maybe == true {   // TRIAGE2-HOOK: low-confidence state → a dot, never a badge
                Circle().strokeBorder(skin.brand ? skin.accentInk.opacity(0.7) : Color.accentColor.opacity(0.7), lineWidth: 1)
                    .frame(width: 6, height: 6).help((triage?.state == .waiting ? "Maybe waiting" : "Maybe reply") + "\n" + (triage?.explain ?? ""))
                    .accessibilityLabel(triage?.state == .waiting ? "Maybe waiting" : "Maybe reply")
            }
        }
    }

    /// Selected row only (never in the clean list): the state that used to crowd every row.
    private func secondary(_ m: MailMessage, _ p: ContentPolicy) -> some View {
        let b = skin.brand
        return HStack(spacing: 5) {
            if !p.redactDetails, MailOrg2.shared.isVIP(m.from?.address) { NSymbol("star.fill", size: 9, label: "VIP").foregroundStyle(.orange) }   // ORG2-HOOK
            if let s = m.sender, let f = m.from, s.address.lowercased() != f.address.lowercased(), !p.redactDetails {
                Tag("via \(s.display)").help("\(s.display) sent this on behalf of \(f.display)")
            }
            if row.mailbox != "me" { MailboxBadge(mailbox: row.mailbox, size: 14) }
            if !m.categories.isEmpty && !p.redactDetails { CategoryDots(categories: Array(m.categories.prefix(2))) }
            if m.importance == .high { NSymbol("exclamationmark", size: 10, label: L("High importance")).fontWeight(.bold).foregroundStyle(b ? skin.danger : .red) }
            if thread?.flagged ?? (m.flag.status == .flagged) { NSymbol("flag.fill", size: 10, label: L("Flagged")).foregroundStyle(.orange) }
            if m.snoozedUntil != nil { NSymbol("clock", size: 10, label: L("Snoozed")).foregroundStyle(.secondary) }
            if m.pendingSync { NSymbol("clock.arrow.circlepath", size: 10, label: L("Waiting to sync")).foregroundStyle(.orange) }
        }
        .lineLimit(1).fixedSize()
    }

    /// A11Y-HOOK: mailbox regional settings (MailRegionalFormat), system formats until they're read.
    @MainActor static func time(_ d: Date) -> String { A11yPrefs.shared.regional.listTime(d) }
}

/// Compact label chip for rows (the reader uses the full LabelBanner).
/// Compact label chip for rows (the reader uses the full LabelBanner). niivo: squared, label colour fill (same 0.14 as
/// before) plus a 1 pt border in the label colour, mono 10 pt medium — never smaller or fainter than the classic chip.
struct LabelChip: View {
    @Environment(\.skin) private var skin
    var policy: ContentPolicy
    /// nil = not proven ours: an id outside our tree gets no chip (LabelProvenance.swift).
    var origin: LabelOrigin? = nil
    var body: some View {
        if LabelDisplay.decide(policy, origin: origin).showsChip { chip }
    }

    @ViewBuilder private var chip: some View {
        switch policy.labelState {
        case .unlabeled: EmptyView()
        case .labeled(let l):
            let c = Color(hex: l.hexColor, fallback: .gray)
            if skin.brand {
                // Quiet (Ryan 2026-11-19): caption mono, 1 pt border in the label colour, no fill, truncates, full name on hover.
                HStack(spacing: 3) {
                    if l.hasProtection { NSymbol("lock.fill", size: 7, label: L("Protected")).fontWeight(.semibold) }
                    Text(l.name).font(skin.mono(9)).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 4).padding(.vertical, 1)
                .foregroundStyle(c)
                .overlay(Rectangle().strokeBorder(c.opacity(0.8), lineWidth: 1))
                .frame(maxWidth: 140, alignment: .trailing)
                .help("Sensitivity: \(l.name)\(l.hasProtection ? " · encrypted" : "")")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sensitivity: \(l.name)\(l.hasProtection ? ", encrypted" : "")")
            } else {
                Text(l.name).font(.caption2.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .foregroundStyle(c)
                    .background(c.opacity(0.14), in: Capsule())
            }
        case .unknown:
            if skin.brand {
                Text(L("Unknown label")).font(skin.mono(9, .semibold)).foregroundStyle(skin.danger).lineLimit(1)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(Rectangle().strokeBorder(skin.danger, lineWidth: 1))
                    .help(L("Unknown label — restricted (not in your synced label policy)"))
                    .accessibilityLabel(L("Unknown sensitivity label, restricted"))
            } else {
                Text(L("Unknown label")).font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(.red.opacity(0.1), in: Capsule())
            }
        }
    }
}

struct CategoryDots: View {
    @Environment(\.skin) private var skin
    var categories: [String]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(categories, id: \.self) { c in
                HStack(spacing: 3) {
                    if skin.brand { Rectangle().fill(Self.color(c)).frame(width: 7, height: 7) }
                    else { Circle().fill(Self.color(c)).frame(width: 7, height: 7) }
                    Text(c).font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption2).textCase(skin.brand ? .uppercase : nil).foregroundStyle(.secondary)
                }
            }
        }
    }
    /// The Outlook master list's colour when known (MailBulk.swift), else a stable hashed colour.
    @MainActor static func color(_ c: String) -> Color {
        MailListUI.shared.color(for: c) ?? Color(hex: MailboxDisplay.colorHex("category:" + c.lowercased()))
    }
}

// MARK: - Toasts

struct ToastStack: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: 6) {
            ForEach(app.mail.toasts) { t in ToastView(toast: t) }
        }
        .padding(.bottom, 16)
        .animation(NMotion.animation(.spring(duration: 0.25)), value: app.mail.toasts)   // A11Y: Reduce Motion
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var app
    var toast: MailToast
    var body: some View {
        HStack(spacing: 10) {
            NSymbol(toast.symbol, size: 12).foregroundStyle(toast.isError ? .red : .secondary)
            Text(toast.text).lineLimit(2)
            if let d = toast.deadline {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("\(max(0, Int(d.timeIntervalSince(ctx.date).rounded(.up))))s").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            switch toast.action {
            case .none: EmptyView()
            case .undoTriage: Button(L("Undo")) { Task { await app.mail.undo() } }.help("Z")
            case .undoSend(let token): Button(L("Undo")) { Task { await app.mail.undoSend(token) } }.nvButton(app.skin, .primary).help("Z")
            case .voiceNudge: VoiceNudgeToastActions(toast: toast)   // VOICE2-HOOK
            }
            Button { app.mail.dismissToast(toast) } label: { NSymbol("xmark", size: 12, label: L("Dismiss")) }.buttonStyle(.borderless)
        }
        .font(app.theme.brand ? app.skin.sans(NV.Size.body) : .callout)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .modifier(ToastSurface(brand: app.theme.brand, skin: app.skin))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// niivo: a floating window, so the one shadow the CI allows (big, soft); squared card with a hairline.
private struct ToastSurface: ViewModifier {
    var brand: Bool
    var skin: Skin
    func body(content: Content) -> some View {
        if brand {
            content.background(skin.card).overlay(Rectangle().strokeBorder(skin.hair2, lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
        } else {
            content.nMaterial(.regularMaterial, in: Capsule(), reduce: NMotion.reduceTransparency).shadow(   // A11Y: Reduce Transparency
                color: .black.opacity(0.15), radius: 8, y: 3)
        }
    }
}
