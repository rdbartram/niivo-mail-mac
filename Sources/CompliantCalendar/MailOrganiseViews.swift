import SwiftUI
import AppKit
import MailCore

// Views for message-list organisation (state in MailBulk.swift).

// MARK: - Bulk bar

struct BulkBar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail, chrome = MailChrome.shared
        let ids = chrome.targets(mail)
        let set = Set(ids)
        let msgs = mail.visibleRows.filter { set.contains($0.id) }.map(\.message)
        let read = BulkPlanner.shouldMarkRead(msgs), flag = BulkPlanner.shouldFlag(msgs)
        HStack(spacing: 10) {
            Text("\(ids.count) selected").font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .callout.weight(.medium))
                .textCase(app.theme.brand ? .uppercase : nil)
            Spacer()
            button(read ? "Mark read" : "Mark unread", "envelope.open") { mail.applyBulk(.markRead(read), ids: ids); chrome.marked = [] }
            button(flag ? "Flag" : "Clear flag", "flag") { mail.applyBulk(.flag(flag), ids: ids); chrome.marked = [] }
            button("Archive", "archivebox") { mail.applyBulk(.archive, ids: ids); chrome.marked = [] }
            button("Move to…", "folder") { MailListUI.shared.moving = ids }
            button("Categorise…", "tag") { mail.showCategories = true }
            button("Snooze…", "clock") { mail.snoozeCustom = TimePreset.tomorrowMorning.date(); mail.showSnooze = true }
            button("Delete", "trash") { mail.applyBulk(.delete, ids: ids); chrome.marked = [] }
            Button("Clear") { chrome.marked = [] }.buttonStyle(.borderless).help("Clear the selection (esc)")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ids.count) messages selected")
    }
    private func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { NSymbol(symbol, size: 12, label: title) }
            .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}

// MARK: - Filter bar

struct ListFilterBar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let ui = MailListUI.shared, brand = app.theme.brand
        if app.mail.searchResults == nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SmartView.allCases) { v in
                        let on = ui.filter == v
                        Button { ui.filter = on ? nil : v; app.mail.reloadList() } label: {
                            HStack(spacing: 4) { NSymbol(v.symbol, size: 10); Text(v.title) }
                                .font(brand ? app.skin.mono(NV.Size.labelSm) : .caption)
                                .textCase(brand ? .uppercase : nil)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(on ? Color.accentColor.opacity(0.22) : Color.clear)
                                .overlay(RoundedRectangle(cornerRadius: brand ? 0 : 10)
                                    .strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.35)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(v == .mentions ? "Mentions me — uses a Microsoft Graph beta filter (read-only)" : "Show only: \(v.title)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    if ui.filter == .mentions, let note = ui.mentionsNote { Text(note).font(.caption2).foregroundStyle(.orange) }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
    }
}

// MARK: - Sidebar

enum SmartSidebarItems {
    @MainActor static func items(mail: MailModel, ui: MailListUI) -> [VirtualFolder] {
        var out: [VirtualFolder] = []
        if ui.showUnifiedInbox && mail.mailboxes.count > 1 { out.append(.unifiedInbox) }
        out += ui.sidebarSmart.map { .smart($0, mailbox: "me") }
        out.append(.promises)   // PROMISES-HOOK: the promises ledger smart folder
        return out
    }
    static func symbol(_ v: VirtualFolder) -> String {
        switch v { case .today: "sun.max"; case .unifiedInbox: "tray.2"; case .smart(let s, _): s.symbol; case .list(let l): l.symbol; case .promises: "checkmark.seal" }
    }
}

/// Classic skin: rows tagged with the virtual id, so the sidebar List's selection opens them.
struct SmartViewsSidebarSection: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let items = SmartSidebarItems.items(mail: app.mail, ui: MailListUI.shared)
        if !items.isEmpty {
            Section("Smart views") {
                ForEach(items, id: \.self) { v in
                    Label(v.title, systemImage: SmartSidebarItems.symbol(v)).tag(Optional(v.id))
                        .contextMenu { SmartSidebarMenu(view: v) }
                }
            }
        }
    }
}

/// niivo skin.
struct SmartViewsSidebarBlock: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let mail = app.mail
        let items = SmartSidebarItems.items(mail: mail, ui: MailListUI.shared)
        if !items.isEmpty {
            MonoLabel("Smart views", color: skin.ink, wide: true, weight: .medium)
                .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
            ForEach(items, id: \.self) { v in
                let selected = mail.selectedFolderId == v.id
                Button { mail.openVirtual(v) } label: {
                    HStack(spacing: 9) {
                        NSymbol(SmartSidebarItems.symbol(v), size: 13).font(.system(size: 13, weight: .light))
                            .foregroundStyle(selected ? skin.ink : skin.muted).frame(width: 18)
                        Text(v.title).font(skin.sans(NV.Size.body, selected ? .medium : .regular)).foregroundStyle(skin.ink)
                        Spacer(minLength: 4)
                    }
                    .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .nRow(selected: selected, hoverKey: AnyHashable("smart:" + v.id), divider: false, skin: skin)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .contextMenu { SmartSidebarMenu(view: v) }
            }
        }
    }
}

struct SmartSidebarMenu: View {
    var view: VirtualFolder
    var body: some View {
        let ui = MailListUI.shared
        switch view {
        case .unifiedInbox: Button("Hide All Inboxes") { ui.showUnifiedInbox = false }
        case .smart(let s, _):
            Button("Remove from Sidebar") { ui.sidebarSmart.removeAll { $0 == s } }
            FavouriteToggle(item: .smart(s))   // ORG2-HOOK
        case .list, .today, .promises: EmptyView()   // TODAY-HOOK, PROMISES-HOOK
        }
        Menu("Add Smart View") {
            ForEach(SmartView.allCases.filter { !ui.sidebarSmart.contains($0) }) { s in Button(s.title) { ui.sidebarSmart.append(s) } }
            if !ui.showUnifiedInbox { Button("All Inboxes") { ui.showUnifiedInbox = true } }
        }
        FavouritePickerMenu()   // ORG2-HOOK
    }
}

// MARK: - Row menus

/// Extra items for a single row: move, sweep, categorise.
struct OrganiseRowMenu: View {
    @Environment(AppModel.self) private var app
    var row: MailRow
    var body: some View {
        let mail = app.mail, ui = MailListUI.shared
        Divider()
        Button("Move to…") { ui.moving = [row.id] }
        if let from = row.message.from, !from.address.isEmpty, !row.policy.redactDetails {
            Button("Sweep…") { ui.sweep = SweepDraft(sender: from, folderId: row.message.folderId, mailbox: row.mailbox) }
        }
        Menu("Categorise") {
            ForEach(mail.knownCategories, id: \.self) { c in
                let has = row.message.categories.contains(c)
                Button(has ? "✓ \(c)" : c) { mail.applyBulk(has ? .removeCategory(c) : .addCategory(c), ids: [row.id]) }
            }
        }
    }
}

/// Context menu for a row inside a multi-selection: acts on every selected message.
struct BulkRowMenu: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail, chrome = MailChrome.shared
        let ids = chrome.targets(mail)
        let set = Set(ids)
        let msgs = mail.visibleRows.filter { set.contains($0.id) }.map(\.message)
        let read = BulkPlanner.shouldMarkRead(msgs), flag = BulkPlanner.shouldFlag(msgs)
        Text("\(ids.count) messages")
        Button(read ? "Mark as Read" : "Mark as Unread") { mail.applyBulk(.markRead(read), ids: ids); chrome.marked = [] }
        Button(flag ? "Flag" : "Clear Flag") { mail.applyBulk(.flag(flag), ids: ids); chrome.marked = [] }
        Menu("Categorise") {
            ForEach(mail.knownCategories, id: \.self) { c in
                let all = msgs.allSatisfy { $0.categories.contains(c) }
                Button(all ? "✓ \(c)" : c) { mail.applyBulk(all ? .removeCategory(c) : .addCategory(c), ids: ids) }
            }
        }
        Button("Snooze…") { mail.snoozeCustom = TimePreset.tomorrowMorning.date(); mail.showSnooze = true }
        Divider()
        Button("Archive") { mail.applyBulk(.archive, ids: ids); chrome.marked = [] }
        Button("Move to…") { MailListUI.shared.moving = ids }
        Button("Delete", role: .destructive) { mail.applyBulk(.delete, ids: ids); chrome.marked = [] }
    }
}

// MARK: - Outlook keymap menu items

/// Outlook-compatible shortcuts (Settings → Mail → Keyboard shortcuts). ⌘Q is never touched. Disabled while an
/// inline composer is open so ⇧⌘V / ⌘J don't fire while writing.
struct OutlookKeymapMenu: View {
    var model: AppModel
    var body: some View {
        let mail = model.mail
        if MailListUI.shared.keymap == .outlook {
            let enabled = model.section == .mail && mail.started && !model.trust.hidesContent && mail.openComposers.isEmpty && mail.selectedRow != nil
            Divider()
            Button("Reply (Outlook ⌘R)") { mail.run(.reply) }.keyboardShortcut("r", modifiers: .command).disabled(!enabled)
            Button("Reply All (Outlook ⇧⌘R)") { mail.run(.replyAll) }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!enabled)
            Button("Forward (Outlook ⌘J)") { mail.run(.forward) }.keyboardShortcut("j", modifiers: .command).disabled(!enabled)
            Button("Move to Folder… (Outlook ⇧⌘V)") {
                let ids = MailChrome.shared.targets(mail)
                if !ids.isEmpty { MailListUI.shared.moving = ids }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift]).disabled(!enabled)
        }
    }
}
