import SwiftUI
import AppKit
import MailCore

// Sheets + settings for message-list organisation: move picker, sweep, search scope bar, categories, keymap.

extension View {
    func organiseSheets() -> some View { modifier(OrganiseSheets()) }
}

private struct OrganiseSheets: ViewModifier {
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        let ui = MailListUI.shared
        content
            .onAppear { ui.attach(app.mail) }
            .task { await ui.loadCategories(app.mail) }   // row colours from the master list
            .sheet(isPresented: Binding(get: { ui.moving != nil }, set: { if !$0 { ui.moving = nil } })) { MoveToSheet() }
            .sheet(isPresented: Binding(get: { ui.sweep != nil }, set: { if !$0 { ui.sweep = nil } })) { SweepSheet() }
            .alert("Save Search", isPresented: Bindable(ui).savingSearch) {
                TextField("Name", text: Bindable(ui).savedSearchName)
                Button("Save") { ui.saveCurrentSearch(app.mail) }
                Button("Cancel", role: .cancel) { ui.savingSearch = false }
            } message: { Text("Saved searches stay on this Mac.") }
    }
}

struct MoveToSheet: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail, ui = MailListUI.shared
        let ids = ui.moving ?? []
        let mb = mail.visibleRows.first { ids.contains($0.id) }?.mailbox ?? mail.selectedMailbox
        let folders = (mail.folders[mb] ?? []).sorted { MailboxDisplay.sortKey($0) < MailboxDisplay.sortKey($1) }
        VStack(alignment: .leading, spacing: 10) {
            Text(ids.count == 1 ? "Move message to…" : "Move \(ids.count) messages to…").font(.headline)
            Text(MailboxDisplay.title(mb)).font(.caption).foregroundStyle(.secondary)
            List(folders) { f in
                Button {
                    let r = mail.applyBulk(.move(folderId: f.id, mailbox: f.mailbox), ids: ids, folderName: f.displayName)
                    if r.applied == 0 {
                        mail.toast(MailToast(text: "Nothing to move — already there or in another mailbox", symbol: "folder", isError: true))
                    }
                    MailChrome.shared.marked = []; ui.moving = nil; mail.focusListToken += 1
                } label: { Label(f.displayName, systemImage: MailboxDisplay.folderSymbol(f)).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
            .frame(minHeight: 280)
            Text("Messages in another mailbox stay where they are (Microsoft Graph can't move between mailboxes).")
                .font(.caption2).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { ui.moving = nil }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 380)
    }
}

// MARK: - Sweep

struct SweepSheet: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail, ui = MailListUI.shared
        if let d = ui.sweep {
            let draft = Binding(get: { ui.sweep ?? d }, set: { ui.sweep = $0 })
            let candidates = SweepRun.candidates(d, mail: mail)
            VStack(alignment: .leading, spacing: 12) {
                Text("Sweep").font(.headline)
                Text("Messages from \(d.sender.address) in \(mail.folder(id: d.folderId)?.displayName ?? "this folder")")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Which", selection: draft.mode) { ForEach(SweepModeChoice.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.radioGroup)
                if d.mode == .older { Stepper("Older than \(d.days) days", value: draft.days, in: 1...3650) }
                Picker("Action", selection: draft.moveTo) {
                    Text("Delete").tag(String?.none)
                    ForEach((mail.folders[d.mailbox] ?? []).filter { $0.id != d.folderId && $0.wellKnown != .deleteditems }
                        .sorted { MailboxDisplay.sortKey($0) < MailboxDisplay.sortKey($1) }) { f in
                        Text("Move to \(f.displayName)").tag(Optional(f.id))
                    }
                }
                if d.mode == .all {
                    Toggle("Always do this for new messages from this sender (server rule)", isOn: draft.always)
                } else {
                    Text("“Always” is only offered for all messages: Outlook rules have no age or keep-latest condition.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(candidates.count) message(s) cached on this Mac match. Older mail that isn't cached here isn't swept.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { ui.sweep = nil }.keyboardShortcut(.cancelAction)
                    Button("Sweep") { SweepRun.run(ui.sweep ?? d, candidates: candidates, mail: mail); ui.sweep = nil }
                        .keyboardShortcut(.defaultAction).disabled(candidates.isEmpty && !(d.always && d.mode == .all))
                }
            }
            .padding(20).frame(width: 460)
        }
    }
}

@MainActor enum SweepRun {
    static func mode(_ d: SweepDraft) -> SweepMode {
        switch d.mode { case .all: .all; case .keepLatest: .keepLatest; case .older: .olderThan(days: d.days) }
    }
    static func action(_ d: SweepDraft, mail: MailModel) -> SweepAction {
        if let id = d.moveTo, let f = mail.folder(id: id) { return .move(folderId: id, folderName: f.displayName) }
        return .delete
    }
    /// Cached headers of the sweep's folder from that sender (blind-index lookup, then the folder check).
    static func candidates(_ d: SweepDraft, mail: MailModel) -> [MailMessage] {
        guard let store = mail.store else { return [] }
        let fromSender = store.messages(matching: [.from(d.sender.address)], mailbox: d.mailbox, limit: 5_000)
            .filter { $0.folderId == d.folderId }
        return Sweep.select(fromSender, sender: d.sender.address, mode: mode(d))
    }
    static func run(_ d: SweepDraft, candidates: [MailMessage], mail: MailModel) {
        let act = action(d, mail: mail)
        let ids = candidates.map(\.id)
        // Visible rows go through applyBulk (optimistic + one ⌘Z); rows not loaded in the list go straight to sync.
        let visible = Set(mail.visibleRows.map(\.id))
        var op = BulkOp.delete, name: String?
        if case .move(let fid, let n) = act { op = .move(folderId: fid, mailbox: d.mailbox); name = n }
        mail.applyBulk(op, ids: ids.filter { visible.contains($0) }, folderName: name)
        let rest = ids.filter { !visible.contains($0) }
        if !rest.isEmpty, let sync = mail.sync {
            let steps = rest.map { BulkStep(messageId: $0, action: Sweep.action(act)) }
            Task { _ = await sync.apply(steps); mail.reloadList() }
        }
        if d.always, let rule = Sweep.rule(sender: d.sender, mode: mode(d), action: act), let sync = mail.sync {
            Task {
                do {
                    _ = try await sync.saveRule(rule, mailbox: d.mailbox)
                    mail.toast(MailToast(text: "Rule added for \(d.sender.address)", symbol: "line.3.horizontal.decrease.circle"))
                } catch { mail.toast(MailToast(text: "Couldn't add the rule", symbol: "exclamationmark.triangle", isError: true)) }
            }
        }
    }
}

// MARK: - Search scope bar

struct SearchScopeBar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail, ui = MailListUI.shared
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Picker("Scope", selection: Bindable(ui).searchScope) {
                    ForEach(MailSearchScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                Toggle("Groups", isOn: Bindable(ui).includeGroups).toggleStyle(.checkbox)
                    .disabled(!mail.groups.isConfigured)
                    .help("Also match conversation topics in your Microsoft 365 groups")
                Spacer()
                Menu {
                    Button("Save This Search…") { ui.savedSearchName = mail.searchText; ui.savingSearch = true }
                        .disabled(mail.searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !ui.memory.saved.isEmpty {
                        Section("Saved") { ForEach(ui.memory.saved) { s in Button(s.name) { ui.run(s, mail: mail) } } }
                        Menu("Remove Saved Search") { ForEach(ui.memory.saved) { s in Button(s.name) { ui.removeSaved(s.id, mail: mail) } } }
                    }
                    if !ui.memory.recent.isEmpty {
                        Section("Recent") { ForEach(ui.memory.recent, id: \.self) { q in Button(q) { mail.searchText = q } } }
                        Button("Clear Recent Searches") { ui.clearRecent(mail: mail) }
                    }
                } label: { NSymbol("clock.arrow.circlepath", size: 11, label: "Recent and saved searches") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Recent and saved searches (kept on this Mac)")
            }
            if ui.unattributed > 0 {
                Text("\(ui.unattributed) server result(s) from mailboxes not opened on this Mac were left out — open the mailbox to include them.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !ui.groupHits.isEmpty {
                Text("Groups").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(ui.groupHits.prefix(8)) { h in
                    Button { mail.groups.select(h.group); mail.groups.open(h.conversation) } label: {
                        Text("\(h.group.displayName) · \(h.conversation.topic)").lineLimit(1)
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .onAppear { ui.attach(mail); ui.ensureMemory(mail) }
    }
}

// MARK: - Settings: categories, list, keymap

struct OrganiseSettingsSection: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail, ui = MailListUI.shared
        Section("Categories") {
            if let e = ui.categoryError { Text(e).font(.caption).foregroundStyle(.red) }
            ForEach(ui.categories) { c in
                HStack {
                    Circle().fill(c.color.hex.map { Color(hex: $0) } ?? .secondary).frame(width: 10, height: 10)
                    if ui.renaming?.id == c.id {
                        TextField("Name", text: Bindable(ui).renameText).textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await ui.rename(c, to: ui.renameText, mail: mail) } }
                        Button("Rename") { Task { await ui.rename(c, to: ui.renameText, mail: mail) } }
                        Button("Cancel") { ui.renaming = nil }
                    } else {
                        Text(c.displayName)
                        Spacer()
                        Picker("Colour", selection: Binding(get: { c.color }, set: { col in Task { await ui.recolour(c, col, mail: mail) } })) {
                            Text("None").tag(CategoryColor.none)
                            ForEach(CategoryColor.presets) { p in Text(p.name).tag(p) }
                        }
                        .labelsHidden().frame(width: 140)
                        Menu {
                            Button("Rename…") { ui.renameText = c.displayName; ui.renaming = c }
                            Button("Delete", role: .destructive) { Task { await ui.delete(c, mail: mail) } }
                        } label: { NSymbol("ellipsis", size: 11, label: "More") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
            HStack {
                TextField("New category", text: Bindable(ui).newCategoryName).onSubmit { Task { await ui.createCategory(mail) } }
                Picker("Colour", selection: Bindable(ui).newCategoryColor) {
                    ForEach(CategoryColor.presets) { p in Text(p.name).tag(p) }
                }
                .labelsHidden().frame(width: 140)
                Button("Add") { Task { await ui.createCategory(mail) } }
                    .disabled(ui.newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Synced with Outlook's category list. Renaming creates the new name, re-tags messages cached on this Mac and removes the old one (Microsoft Graph can't rename a category).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await ui.loadCategories(mail) }
        Section("Message list") {
            Toggle("Show All Inboxes when you have more than one mailbox", isOn: Bindable(ui).showUnifiedInbox)
            Picker("Keyboard shortcuts", selection: Bindable(ui).keymap) { ForEach(KeymapStyle.allCases) { Text($0.title).tag($0) } }
            if ui.keymap == .outlook {
                Text("⌘R reply · ⇧⌘R reply all · ⌘J forward · ⇧⌘V move to folder · ⌥⌘R sync now. Single-key shortcuts keep working and ⌘Q still quits. Off while you're writing a message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
