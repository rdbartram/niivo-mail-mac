import SwiftUI
import AppKit
import MailCore

// The niivo mail window: no system toolbar, no system sidebar. A custom header bar (traffic lights inside it),
// a custom-drawn mailbox/folder tree, the message list, the reader. Other themes keep MailRootView's NavigationSplitView.

/// Layout + multi-select state for the shell (kept out of MailModel; plain observable, no @State).
@MainActor @Observable final class MailChrome {
    static let shared = MailChrome()
    var sidebarWidth: CGFloat = 236
    var listWidth: CGFloat = 410
    /// Message list height with the reading pane at the bottom (A11yPrefs).
    var listHeight: CGFloat = 320
    var sidebarVisible = true
    /// Multi-selection (⌘-click / ⇧-click / ⇧↑↓). Empty = single selection = `mail.selectedMessageId`.
    var marked: Set<String> = []
    var anchor: String?
    private var dragBase: CGFloat?

    func resize(_ keyPath: ReferenceWritableKeyPath<MailChrome, CGFloat>, by dx: CGFloat, min lo: CGFloat, max hi: CGFloat) {
        if dragBase == nil { dragBase = self[keyPath: keyPath] }
        self[keyPath: keyPath] = Swift.min(hi, Swift.max(lo, (dragBase ?? 0) + dx))
    }
    func endResize() { dragBase = nil }

    /// Ids an action applies to: the marked set when more than one, else the selected message.
    func targets(_ mail: MailModel) -> [String] {
        if marked.count > 1 { return mail.visibleRows.map(\.id).filter { marked.contains($0) } }
        return mail.selectedMessageId.map { [$0] } ?? []
    }

    /// Click with the current modifier keys: plain = select, ⌘ = toggle mark, ⇧ = range from the anchor.
    func click(_ id: String, mail: MailModel) {
        let f = NSEvent.modifierFlags
        if f.contains(.command) {
            if marked.isEmpty, let cur = mail.selectedMessageId { marked = [cur] }
            if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
            anchor = id
            mail.selectedMessageId = id
        } else if f.contains(.shift), let a = anchor ?? mail.selectedMessageId {
            extend(from: a, to: id, mail: mail)
        } else {
            marked = []; anchor = id
            mail.selectedMessageId = id
        }
    }

    func extend(from a: String, to id: String, mail: MailModel) {
        let ids = mail.visibleRows.map(\.id)
        guard let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: id) else { return }
        marked = Set(ids[min(i, j)...max(i, j)])
        anchor = a
        mail.selectedMessageId = id
    }

    /// ⇧↓ / ⇧↑ grow the range from the anchor.
    func extendByKey(_ d: Int, mail: MailModel) {
        let ids = mail.visibleRows.map(\.id)
        guard let cur = mail.selectedMessageId, let i = ids.firstIndex(of: cur) else { return }
        let j = min(max(i + d, 0), ids.count - 1)
        extend(from: anchor ?? cur, to: ids[j], mail: mail)
    }

    /// Bulk triage over the marked set (MailBulk.swift: one plan, one toast, one ⌘Z). Returns false when not a bulk case.
    /// Snooze / categorise / move open their pickers and keep the selection; the picker applies to every target.
    func bulk(_ cmd: MailCommand, mail: MailModel) -> Bool {
        guard marked.count > 1 else { return false }
        let ids = targets(mail)
        let msgs = mail.visibleRows.filter { marked.contains($0.id) }.map(\.message)
        switch cmd {
        case .archive: mail.applyBulk(.archive, ids: ids)
        case .delete: mail.applyBulk(.delete, ids: ids)
        case .toggleRead: mail.applyBulk(.markRead(BulkPlanner.shouldMarkRead(msgs)), ids: ids)
        case .flag: mail.applyBulk(.flag(BulkPlanner.shouldFlag(msgs)), ids: ids)
        case .snooze: mail.snoozeCustom = TimePreset.tomorrowMorning.date(); mail.showSnooze = true; return true
        case .categorize: mail.showCategories = true; return true
        case .undo, .palette, .search, .cheatSheet, .settings, .sync, .compose, .next, .previous: return false
        default: return false
        }
        marked = []
        return true
    }

    /// Run a header/key command, bulk-aware.
    func run(_ cmd: MailCommand, mail: MailModel) {
        if !bulk(cmd, mail: mail) { mail.run(cmd) }
    }
}

// MARK: - Window chrome

/// Hidden title bar with full-size content while the niivo mail shell is on screen; restores the standard title bar
/// (for the calendar's toolbar) otherwise. The traffic lights stay where macOS puts them, inside our header.
struct WindowChrome: NSViewRepresentable {
    var custom: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        let custom = custom
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = custom
            w.titleVisibility = custom ? .hidden : .visible
            if custom { w.styleMask.insert(.fullSizeContentView) } else { w.styleMask.remove(.fullSizeContentView) }
            w.backgroundColor = custom ? NSColor(NV.ground) : .windowBackgroundColor
        }
    }
}

// MARK: - Shell

struct MailShellView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.deskTile) private var deskTile   // DESK-HOOK
    var body: some View {
        let chrome = MailChrome.shared
        VStack(spacing: 0) {
            MailHeaderBar().zIndex(10)   // SEARCHBOX-HOOK: the suggestions dropdown draws over the list
            if !deskTile.inTile { PostureBanner().fixedSize(horizontal: false, vertical: true) }   // DESK-HOOK: the Desk shows it once
            HStack(spacing: 0) {
                if chrome.sidebarVisible && !deskTile.compact {   // DESK-HOOK: narrow tile
                    NiivoSidebar().frame(width: chrome.sidebarWidth)
                    NSplitHandle(onDrag: { chrome.resize(\.sidebarWidth, by: $0, min: 190, max: 360) }, onEnd: chrome.endResize)
                }
                if TodayModel.shared.flow != nil, TodayModel.shared.isActive(app.mail) {
                    TodayFlowView().frame(maxWidth: .infinity)   // TODAY-HOOK: Flow, full width (pane preference ignored)
                } else if SignalModel.shared.isActive(app.mail) && !deskTile.signalTiled {   // DESK-HOOK: Signal has its own tile
                    SignalView().frame(maxWidth: .infinity)   // LOOPS-HOOK: Signal, full width
                } else {
                switch deskTile.signalTiled && SignalModel.shared.isActive(app.mail) ? .off : A11yPrefs.shared.prefs.pane {   // A11Y-HOOK: reading pane right / bottom / off; DESK-HOOK: Signal's Now card is the reader
                case .right:
                    list.frame(width: chrome.listWidth)
                    NSplitHandle(onDrag: { chrome.resize(\.listWidth, by: $0, min: 320, max: 640) }, onEnd: chrome.endResize)
                    reader.frame(maxWidth: .infinity)
                case .bottom:
                    VStack(spacing: 0) {
                        list.frame(height: chrome.listHeight)
                        NSplitHandleH(onDrag: { chrome.resize(\.listHeight, by: $0, min: 140, max: 900) }, onEnd: chrome.endResize)
                        reader.frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                case .off:
                    list.frame(maxWidth: .infinity)
                }
                }
            }
        }
        .background(skin.ground)
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(.hidden, for: .windowToolbar)
        .background { OpenMessageKey() }
        .background { QuickStepKeys() }   // ORG2-HOOK: ^⇧1–9
    }

    // GROUPS-HOOK: a selected M365 group replaces the message list + reader.
    @ViewBuilder private var list: some View {
        VStack(spacing: 0) {
            if app.mail.groups.isActive { GroupConversationListView() }
            else if TodayModel.shared.isActive(app.mail) { TodayView() }   // TODAY-HOOK
            else if case .promises? = app.mail.virtualFolder { PromisesListView() }   // PROMISES-HOOK
            else { MessageListView() }
        }
    }

    // The inline mail composer lives in ReaderView: it wins over the group reader.
    @ViewBuilder private var reader: some View {
        if app.mail.groups.isActive && app.mail.composer == nil { GroupReaderView() } else { ReaderView() }
    }
}

/// ⌘O: open the selected message in its own window.
private struct OpenMessageKey: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("") { if let id = app.mail.selectedMessageId { openWindow(id: "message", value: id) } }
            .keyboardShortcut("o", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// The header: traffic-light inset, section tabs, sidebar toggle, folder title, search, sync state, square actions.
struct MailHeaderBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindowPeople   // PEOPLE2-HOOK
    @Environment(\.skin) private var skin
    @Environment(\.deskTile) private var deskTile   // DESK-HOOK
    @FocusState private var searchFocused: Bool

    var body: some View {
        let mail = app.mail
        let chrome = MailChrome.shared
        @Bindable var m = mail
        let hasSel = mail.selectedRow != nil
        let n = chrome.marked.count
        HStack(spacing: 10) {
            if !deskTile.inTile {   // DESK-HOOK: a Desk tile has no traffic lights and no section tabs (the rail switches)
            Color.clear.frame(width: 64)   // traffic lights
            NTabs(title: L("Section"), items: AppModel.AppSection.allCases, selection: Bindable(app).section,
                  label: { $0.title }, count: { _ in 0 }, divider: false, horizontalPadding: 0)
                .fixedSize()
                .help(L("Mail (⌃⌘1) · Calendar (⌃⌘2)"))
            if app.theme.brand { DeskToggleButton() }   // DESK-HOOK: back to the Desk (⇧⌘D)
            }
            NIconButton("person.2", label: L("People"), help: L("People directory (⌃⌘5)")) { KnowledgeHub.shared.openDirectory(openWindow: openWindowPeople) }   // PEOPLE2-HOOK
            NIconButton("sidebar.left", label: L("Show or hide mailboxes"), isOn: chrome.sidebarVisible ? nil : false) { chrome.sidebarVisible.toggle() }
            VStack(alignment: .leading, spacing: 0) {
                Text(mail.selectedFolder?.displayName ?? "Mail").font(skin.sans(15)).tracking(skin.titleTrack(15)).foregroundStyle(skin.ink).lineLimit(1)
                MonoLabel(MailboxDisplay.title(mail.selectedMailbox), size: NV.Size.labelSm).lineLimit(1)
            }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if n > 1 {
                NChip(L("%lld selected", n), tone: .accent)
                Button(L("Clear")) { chrome.marked = [] }.nvButton(skin, .quiet).help(L("Clear the selection (esc)"))
            }
            NField(L("Search mail"), text: $m.searchText, style: .bordered, symbol: "magnifyingglass", focus: $searchFocused) {
                // SEARCHBOX-HOOK: ↩ = highlighted suggestion, else Ask mode / ⌥↩ (AI-HOOK), else natural search + server.
                if SearchBoxState.shared.acceptHighlighted() { return }
                SearchBoxState.shared.dropdownOpen = false
                if mail.ai.askMode || NSEvent.modifierFlags.contains(.option) { mail.ai.searchSubmitted() } else { mail.submitSearch() }
            }
            .frame(minWidth: 120, idealWidth: 230, maxWidth: 260)
            .layoutPriority(-1)
            .onChange(of: mail.focusSearchToken) { searchFocused = true }
            .onChange(of: searchFocused) { if searchFocused { SearchBoxState.shared.focused(mail) } else { _ = SearchBoxState.shared.dismiss() } }   // SEARCHBOX-HOOK
            .onKeyPress(.downArrow) { SearchBoxState.shared.move(1) ? .handled : .ignored }   // SEARCHBOX-HOOK
            .onKeyPress(.upArrow) { SearchBoxState.shared.move(-1) ? .handled : .ignored }   // SEARCHBOX-HOOK
            .overlay(alignment: .topLeading) { SearchSuggestionsDropdown().offset(y: 34) }   // SEARCHBOX-HOOK: suggestions
            .onExitCommand { if SearchBoxState.shared.dismiss() { return }; if !mail.searchText.isEmpty { mail.searchText = "" }; mail.focusListToken += 1 }
            .help(L("Search (⌘F)"))
            if mail.ai.enabled {   // AI-HOOK: Ask toggle (natural-language search)
                NIconButton("sparkle.magnifyingglass", label: L("Ask"), help: L("Natural-language search: type, then ↩ (or ⌥↩ any time)"),
                            isOn: mail.ai.askMode) { mail.ai.askMode.toggle() }
            }
            PostUnlockSync()
            MailSyncBadge()
            HStack(spacing: 2) {
                NIconButton("square.and.pencil", label: L("New message"), help: L("New message (C or ⌘N)")) { mail.run(.compose) }
                NIconButton("arrowshape.turn.up.left", label: L("Reply"), help: L("Reply (R)")) { mail.run(.reply) }.disabled(!hasSel || n > 1)
                NIconButton("archivebox", label: L("Archive"), help: L("Archive (E)")) { chrome.run(.archive, mail: mail) }.disabled(!hasSel)
                NIconButton("trash", label: L("Delete"), help: L("Delete (#)")) { chrome.run(.delete, mail: mail) }.disabled(!hasSel)
                NIconButton("flag", label: L("Flag"), help: L("Flag (S)")) { chrome.run(.flag, mail: mail) }.disabled(!hasSel)
                NIconButton("clock", label: L("Snooze"), help: L("Snooze (H)")) { mail.run(.snooze) }.disabled(!hasSel || n > 1)
                NIconButton("bubble.left.and.bubble.right", label: L("Group by conversation"), help: L("Group by conversation (⇧T)"),
                            isOn: mail.groupConversations) { mail.groupConversations.toggle() }
                StoryModeButton()   // STORY-HOOK
            }
            .padding(.leading, 4)
            HStack(spacing: 2) {
                NIconButton("command", label: L("Command palette"), help: L("Command palette (⌘K)")) { mail.run(.palette) }
                NIconButton("questionmark.square", label: L("Keyboard shortcuts"), help: L("Keyboard shortcuts (⌘/)")) { mail.run(.cheatSheet) }
                NIconButton("gearshape", label: L("Settings"), help: L("Settings (⌘,)")) { mail.showSettings = true }
                NIconButton("lock", label: L("Lock now"), help: L("Lock now (⌃⌘L)")) { app.trust.lockNow() }
            }
            .padding(.leading, 4)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background { skin.ground.gesture(WindowDragGesture()).allowsWindowActivationEvents(true) }
        .hairline(skin)
    }
}

// MARK: - Sidebar (custom-drawn tree)

struct NiivoSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @FocusState private var focused: Bool

    var body: some View {
        let mail = app.mail
        let all = mail.sidebarOrder.filter { !mail.mailboxManager.isCollapsed($0.mailbox) }   // visible rows, favourites first
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    TodaySidebarRow()   // TODAY-HOOK: Today beside the Inbox (TodayViews.swift)
                    FavouritesSidebarBlock()   // ORG2-HOOK: folders, groups, people, categories, smart views, trays (MailOrg2Views.swift)
                    SmartViewsSidebarBlock()   // SMART VIEWS + unified inbox (MailOrganiseViews.swift)
                    ForEach(Array(mail.mailboxes.enumerated()), id: \.element) { i, mb in
                        mailboxHeader(mb, index: i + 1).mailboxHeaderMenu(mb)   // MAILBOXES-HOOK
                        MailboxErrorRow(mailbox: mb)
                        if mail.mailboxManager.isCollapsed(mb) {
                            EmptyView()
                        } else if mail.openedMailboxes.contains(mb) || !(mail.folders[mb] ?? []).isEmpty {
                            ForEach(mail.folderRows(mb)) { r in folderRow(r.folder, selected: r.id == mail.selectedFolderId, row: r) }
                        } else {
                            Button { Task { await mail.openMailbox(mb) } } label: {
                                HStack(spacing: 8) { Text("→").font(skin.mono(NV.Size.label)); Text(L("Open mailbox")).font(skin.sans(NV.Size.body)) }
                                    .foregroundStyle(skin.muted).padding(.horizontal, 16).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(L("Shared and delegated mailboxes sync on first open, or in the background when pinned"))
                        }
                    }
                    AddMailboxRow()                                            // MAILBOXES-HOOK
                    GroupsSidebarBlock(index: mail.mailboxes.count + 1)        // GROUPS-HOOK
                }
                .padding(.bottom, 12)
            }
            .focusable().focused($focused).focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, all, mail) }
            .onKeyPress(.upArrow) { move(-1, all, mail) }
            .onKeyPress(.rightArrow) { mail.focusListToken += 1; return .handled }
            // A11Y-HOOK: Tab / shift-Tab cycle panes, Esc back to the list, focus requests from MailFocus.
            .onKeyPress(.escape) { mail.focusListToken += 1; return .handled }
            .onKeyPress(phases: .down) { MailFocus.shared.tabKey($0, mail: mail) }
            .onChange(of: MailFocus.shared.sidebarToken) { focused = true }
            .onChange(of: focused) { _, on in if on { MailFocus.shared.current = .sidebar } }
            .overlay { if focused { Rectangle().strokeBorder(skin.accentInk, lineWidth: 2).allowsHitTesting(false) } }
            .accessibilityLabel(L("Mailboxes and folders"))
            SyncStatusRow()   // LIFECYCLE-HOOK: offline / throttled / sign-in / CAE
            HStack(spacing: 8) {
                NiivoWordmark(size: 15, blinks: false, color: skin.ink).accessibilityHidden(true)
                Spacer()
                MonoLabel(app.trust.policy.profile == .byod ? "BYOD" : "Managed", size: NV.Size.labelSm)
                    .help(app.trust.policy.profile == .byod ? "Personal Mac (BYOD) policy" : "Managed Mac policy")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .hairline(skin, edge: .top)
        }
        .background(skin.ground)
        .folderDialogs()
        .addMailboxSheet()   // MAILBOXES-HOOK
    }

    private func move(_ d: Int, _ all: [MailFolder], _ mail: MailModel) -> KeyPress.Result {
        guard !all.isEmpty else { return .ignored }
        let i = all.firstIndex { $0.id == mail.selectedFolderId } ?? -1
        MailFocus.shared.holdSidebar()   // A11Y-HOOK: arrows keep the sidebar focused
        mail.selectedFolderId = all[min(max(i + d, 0), all.count - 1)].id
        return .handled
    }

    private func mailboxHeader(_ mb: String, index: Int) -> some View {
        let mail = app.mail
        let pinned = mail.settings.pinnedMailboxes.contains(mb)
        return HStack(spacing: 7) {
            MailboxCollapseToggle(mailbox: mb)   // MAILBOXES-HOOK
            MonoLabel(String(format: "%02d", index), size: NV.Size.labelSm, color: skin.accentInk)
            MonoLabel(MailboxDisplay.title(mb), color: skin.ink, wide: true, weight: .medium).lineLimit(1)
                .contentShape(Rectangle()).onTapGesture { mail.mailboxManager.toggleCollapsed(mb) }
            if let mode = mail.settings.identities.first(where: { $0.mailbox == mb && mb != "me" })?.mode {
                MonoLabel(mode == .sendAs ? "Shared" : "Delegate", size: NV.Size.labelSm)
            }
            Spacer(minLength: 0)
            if mb != "me" {
                Button { Task { await mail.setPinned(mb, !pinned) } } label: {
                    NSymbol(pinned ? "pin.fill" : "pin", size: 10).font(.system(size: 10, weight: .light)).foregroundStyle(pinned ? skin.ink : skin.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pinned ? "Unpin mailbox" : "Pin mailbox")
                .help(pinned ? "Pinned: syncs in the background. Click to unpin." : "Pin to sync in the background")
            }
        }
        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
        .contextMenu { MailboxContextMenu(mailbox: mb) }
    }

    private func folderRow(_ f: MailFolder, selected: Bool, row: FolderTreeRow?, favourite: Bool = false) -> some View {
        let mail = app.mail
        // A11Y-HOOK: a click hands the keyboard to the list (also when the folder was already selected).
        return Button { mail.selectedFolderId = f.id; mail.focusListToken += 1 } label: {
            HStack(spacing: 9) {
                FolderDisclosure(row: row)
                NSymbol(MailboxDisplay.folderSymbol(f), size: 13).font(.system(size: 13, weight: .light))
                    .foregroundStyle(selected ? skin.ink : skin.muted).frame(width: 18)
                FolderName(folder: f, font: skin.sans(NV.Size.body, selected ? .medium : .regular), color: skin.ink)
                Spacer(minLength: 4)
                // Server counts (`unreadItemCount`), never a local COUNT(*).
                if f.unreadCount > 0 { Text("\(f.unreadCount)").font(skin.mono(NV.Size.label, .medium)).foregroundStyle(selected ? skin.accentInk : skin.muted) }
            }
            .padding(.leading, 16 + CGFloat(row?.depth ?? 0) * 14).padding(.trailing, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nRow(selected: selected, hoverKey: AnyHashable((favourite ? "fav:" : "folder:") + f.id), divider: false, skin: skin)
        .accessibilityLabel(f.unreadCount > 0 ? L("%@, %lld unread", f.displayName, f.unreadCount) : f.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Drop messages (same mailbox) or a folder here; context menu; custom folders drag (MailFolderActions).
        .folderActions(f, mail: mail)
    }
}

/// Subtle "syncing…" while the post-unlock background sync runs (calendar sync, mail opening). The UI is usable
/// from the encrypted cache meanwhile (AppModel.resumeAfterUnlock).
struct PostUnlockSync: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let calSyncing: Bool = { if case .syncing = app.status { true } else { false } }()
        let mailOpening: Bool = { switch app.mail.phase { case .starting: true; default: false } }()
        if calSyncing || mailOpening {
            HStack(spacing: 5) {
                NiivoCursor(size: 7, color: skin.muted)
                MonoLabel(mailOpening ? "Opening mail" : "Syncing", size: NV.Size.labelSm)
            }
            .fixedSize()
            .help(mailOpening ? "Mail is opening in the background — cached content is already usable" : "Calendar syncing in the background")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(mailOpening ? "Opening mail" : "Syncing")
        }
    }
}
