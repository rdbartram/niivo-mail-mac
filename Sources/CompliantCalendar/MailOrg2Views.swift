import SwiftUI
import MailCore

// Views for MailOrg2.swift: Favourites sidebar (both skins), row menu, Quick Step keys, settings + editor.

struct FavouriteToggle: View {
    var item: FavouriteItem
    var body: some View {
        let org = MailOrg2.shared, on = org.favourites.contains(item)
        Button(on ? "Remove from Favourites" : "Add to Favourites") { org.toggle(item) }
    }
}

/// Row menu additions (single message). Redacted rows get no sender-based items.
struct Org2RowMenu: View {
    @Environment(AppModel.self) private var app
    var row: MailRow
    var body: some View {
        let mail = app.mail, org = MailOrg2.shared
        Divider()
        ForEach(MailTray.allCases) { t in
            let on = t.holds(row.message)
            Button(on ? "Remove from \(t.title)" : t.title) { org.setTray(t, on: !on, rows: [row], mail: mail) }
        }
        if org.isIgnored(row) { Button("Stop Ignoring Conversation") { org.stopIgnoring(row, mail: mail) } }
        else { Button("Ignore Conversation") { org.ignore(row, mail: mail) } }
        if !row.policy.redactDetails, let from = row.message.from, !from.address.isEmpty {
            let vip = org.isVIP(from.address)
            Button(vip ? "Remove Sender from VIPs" : "Add Sender to VIPs") { org.setVIP(from.address, !vip) }
            Button("Show Mail with This Person") { mail.openVirtual(.list(.person(address: from.address, mailbox: row.mailbox))) }
            FavouriteToggle(item: .person(address: from.address, name: from.name))
        }
        if !org.quickSteps.steps.isEmpty {
            Menu("Quick Steps") {
                ForEach(org.quickSteps.steps) { s in
                    Button(s.shortcut.map { "\(s.name)  ⌃⇧\($0)" } ?? s.name) { org.run(s, rows: [row], mail: mail) }
                }
            }
        }
    }
}

/// ^⇧1…9 run Quick Steps (hidden buttons; same pattern as ⌘O).
struct QuickStepKeys: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ZStack {
            ForEach(1...9, id: \.self) { n in
                Button("") { MailOrg2.shared.runShortcut(n, mail: app.mail) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: [.control, .shift])
            }
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

// MARK: - Sidebar

@MainActor enum FavouriteRows {
    static func items(_ mail: MailModel) -> [FavouriteItem] {
        MailOrg2.shared.favourites.items.filter { i in if case .folder(let id, _) = i { mail.folder(id: id) != nil } else { true } }
    }
    static func move(_ item: FavouriteItem, by d: Int) {
        let org = MailOrg2.shared, ids = org.favourites.items.map(\.id)
        guard let i = ids.firstIndex(of: item.id) else { return }
        if d < 0, i > 0 { org.favourites.move(item.id, before: ids[i - 1]) }
        if d > 0, i + 1 < ids.count { org.favourites.move(item.id, before: i + 2 < ids.count ? ids[i + 2] : nil) }
    }
}

struct FavouritesSidebarBlock: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let items = FavouriteRows.items(app.mail)
        if !items.isEmpty {
            MonoLabel(L("Favourites"), color: skin.ink, wide: true, weight: .medium)
                .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
                .contextMenu { FavouritePickerMenu() }
            ForEach(items) { item in FavouriteRow(item: item) }
        }
    }
}

private struct FavouriteRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var item: FavouriteItem
    var body: some View {
        let mail = app.mail, org = MailOrg2.shared
        let sid = org.selectionId(item)
        let selected: Bool = {
            if case .group(let id, _) = item { return mail.groups.isActive && mail.groups.selectedGroupId == id }
            return sid != nil && mail.selectedFolderId == sid
        }()
        let folder: MailFolder? = { if case .folder(let id, _) = item { mail.folder(id: id) } else { nil } }()
        let unread = folder?.unreadCount ?? 0
        let title = org.title(item, mail: mail)
        Button { org.open(item, mail: mail) } label: {
            HStack(spacing: 9) {
                NSymbol(org.symbol(item, mail: mail), size: 13).font(.system(size: 13, weight: .light))
                    .foregroundStyle(selected ? skin.ink : skin.muted).frame(width: 18)
                Text(title).font(skin.sans(NV.Size.body, selected ? .medium : .regular)).foregroundStyle(skin.ink).lineLimit(1)
                if let f = folder, f.mailbox != "me" { MailboxBadge(mailbox: f.mailbox, size: 13) }
                Spacer(minLength: 4)
                if unread > 0 { Text("\(unread)").font(skin.mono(NV.Size.label, .medium)).foregroundStyle(selected ? skin.accentInk : skin.muted) }
            }
            .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nRow(selected: selected, hoverKey: AnyHashable("fav:" + item.id), divider: false, skin: skin)
        .overlay(alignment: .top) { if org.dropBefore == item.id { Rectangle().fill(skin.accentFill).frame(height: 2) } }
        .accessibilityLabel(unread > 0 ? "\(title), \(unread) unread" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Move up") { FavouriteRows.move(item, by: -1) }
        .accessibilityAction(named: "Move down") { FavouriteRows.move(item, by: 1) }
        .draggable(MailOrg2.dragPrefix + item.id)
        .dropDestination(for: String.self) { items, _ in
            if let r = org.handleDrop(items, before: item.id) { return r }
            if let f = folder { return mail.handleSidebarDrop(items, onto: f) }   // messages dropped on a favourite folder
            return false
        } isTargeted: { t in
            if t { org.dropBefore = item.id } else if org.dropBefore == item.id { org.dropBefore = nil }
        }
        .contextMenu {
            Button("Move Up") { FavouriteRows.move(item, by: -1) }
            Button("Move Down") { FavouriteRows.move(item, by: 1) }
            Divider()
            if let f = folder { FolderContextMenu(folder: f) } else { Button("Remove from Favourites") { org.favourites.remove(item) } }
        }
    }
}

/// Classic skin: rows tagged with their list id (groups open on tap); drag to reorder.
struct FavouritesSidebarSection: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail, org = MailOrg2.shared
        let items = FavouriteRows.items(mail)
        if !items.isEmpty {
            Section(L("Favourites")) {
                ForEach(items) { item in
                    let label = Label(org.title(item, mail: mail), systemImage: org.symbol(item, mail: mail))
                    Group {
                        if let sid = org.selectionId(item) { label.tag(Optional(sid)) }
                        else { label.onTapGesture { org.open(item, mail: mail) } }
                    }
                    .contextMenu {
                        Button("Move Up") { FavouriteRows.move(item, by: -1) }
                        Button("Move Down") { FavouriteRows.move(item, by: 1) }
                        Button("Remove from Favourites") { org.favourites.remove(item) }
                    }
                }
                .onMove { from, to in
                    var all = items.map(\.id)
                    all.move(fromOffsets: from, toOffset: to)
                    let order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1, $0) })
                    org.favourites.items.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
                }
            }
        }
    }
}

/// "Pin to Favourites" menu for the sidebar: categories, trays, VIPs (folders/groups/people pin from their own menus).
struct FavouritePickerMenu: View {
    var body: some View {
        let ui = MailListUI.shared
        Menu("Add to Favourites") {
            FavouriteToggle(item: .vip)
            ForEach(MailTray.allCases) { t in Toggle(t.title, isOn: favBinding(.tray(t))) }
            ForEach(SmartView.allCases) { s in Toggle(s.title, isOn: favBinding(.smart(s))) }
            if !ui.categories.isEmpty {
                Menu("Category") { ForEach(ui.categories) { c in Toggle(c.displayName, isOn: favBinding(.category(c.displayName))) } }
            }
        }
    }
    private func favBinding(_ i: FavouriteItem) -> Binding<Bool> {
        Binding(get: { MailOrg2.shared.favourites.contains(i) }, set: { MailOrg2.shared.favourites.set(i, $0) })
    }
}

// MARK: - Settings

struct Org2SettingsSections: View {
    var body: some View {
        let org = MailOrg2.shared
        Section("Message list") {
            Toggle("Show sender pictures (initials, or the directory photo when available)", isOn: Bindable(org).showAvatars)
            Text("Photos are kept in memory only, never on disk.").font(.caption).foregroundStyle(.secondary)
        }
        Section("VIPs") {
            let _ = org.vipVersion
            let all = org.vips.all
            if all.isEmpty { Text("No VIPs yet. Add one from a message's menu or the contact card (⇧V on a selected message).").foregroundStyle(.secondary) }
            ForEach(all, id: \.self) { a in HStack { Text(a); Spacer(); Button("Remove") { org.setVIP(a, false) } } }
            FavouriteToggle(item: .vip)
        }
        Section("Quick Steps") {
            ForEach(org.quickSteps.steps) { s in
                HStack {
                    VStack(alignment: .leading) {
                        Text(s.name)
                        Text(s.actions.map(\.title).joined(separator: " → ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let n = s.shortcut { Text("⌃⇧\(n)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Button("Edit") { org.editingStep = s }
                    Button("Delete", role: .destructive) { org.quickSteps.remove(s.id) }
                }
            }
            Button("New Quick Step…") { org.editingStep = QuickStep(name: "", actions: []) }
            Text("Quick Steps run on this Mac only; they don't sync with Outlook.").font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: Bindable(org).editingStep) { s in QuickStepEditor(model: QuickStepEditorModel(s)) }
    }
}

@MainActor @Observable final class QuickStepEditorModel {
    var step: QuickStep
    var category = ""
    init(_ s: QuickStep) { step = s }
}

struct QuickStepEditor: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: QuickStepEditorModel
    var body: some View {
        let mail = app.mail, org = MailOrg2.shared
        let problems = org.quickSteps.problems(model.step)
        let templates = mail.store.flatMap { $0.sealed(TemplateLibrary.self, for: TemplateLibrary.storeKey) }?.templates ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text(model.step.name.isEmpty ? "New Quick Step" : model.step.name).font(.title3.weight(.semibold))
            TextField("Name", text: $model.step.name)
            Picker("Shortcut", selection: $model.step.shortcut) {
                Text("None").tag(Int?.none)
                ForEach(1...9, id: \.self) { n in Text("⌃⇧\(n)").tag(Int?.some(n)) }
            }
            Text("Actions (Move, Archive or Delete always runs last)").font(.headline)
            ForEach(Array(model.step.actions.enumerated()), id: \.offset) { i, a in
                HStack { Text(a.title); Spacer(); Button("Remove") { model.step.actions.remove(at: i) } }
            }
            HStack {
                Menu("Add Action") {
                    Button("Mark as read") { model.step.actions.append(.markRead(true)) }
                    Button("Mark as unread") { model.step.actions.append(.markRead(false)) }
                    Button("Flag") { model.step.actions.append(.flag(true)) }
                    Button("Clear flag") { model.step.actions.append(.flag(false)) }
                    ForEach(MailTray.allCases) { t in Button(t.title) { model.step.actions.append(.tray(t)) } }
                    Menu("Categorise") {
                        ForEach(MailListUI.shared.categories) { c in Button(c.displayName) { model.step.actions.append(.categorise(c.displayName)) } }
                    }
                    Button("Archive") { model.step.actions.append(.archive) }
                    Button("Delete") { model.step.actions.append(.delete) }
                    Menu("Move to folder") {
                        ForEach(mail.mailboxes, id: \.self) { mb in
                            Menu(MailboxDisplay.title(mb)) {
                                ForEach(mail.folders[mb] ?? []) { f in
                                    Button(f.displayName) { model.step.actions.append(.move(folderId: f.id, mailbox: mb, folderName: f.displayName)) }
                                }
                            }
                        }
                    }
                    Menu("Reply with template") {
                        ForEach(templates) { t in Button(t.name) { model.step.actions.append(.replyWithTemplate(templateId: t.id, name: t.name)) } }
                    }
                }
                .fixedSize()
                TextField("Category name", text: $model.category).frame(width: 160)
                Button("Add Category") {
                    let c = model.category.trimmingCharacters(in: .whitespaces)
                    if !c.isEmpty { model.step.actions.append(.categorise(c)); model.category = "" }
                }
            }
            ForEach(problems, id: \.self) { p in Text(p).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { org.editingStep = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { org.quickSteps.upsert(model.step); org.editingStep = nil }
                    .keyboardShortcut(.defaultAction).disabled(!problems.isEmpty)
            }
        }
        .padding(20).frame(width: 500)
        .task { await MailListUI.shared.loadCategories(mail) }
    }
}
