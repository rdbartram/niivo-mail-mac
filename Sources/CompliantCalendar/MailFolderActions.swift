import SwiftUI
import MailCore

/// Folder-management view state (all view state lives in models). Expand state and Favourites are stored locally
/// as folder ids only (names are sealed in the store); ids that no longer exist are pruned on refresh.
@MainActor @Observable
final class MailFolderUI {
    /// Folder currently under a drag (drop highlight).
    var dropTargetId: String?
    static let shared = MailFolderUI()
    private static let expandedKey = "mail.folders.expanded", favouritesKey = "mail.folders.favourites"

    var expanded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: expandedKey) ?? []) {
        didSet { UserDefaults.standard.set(Array(expanded).sorted(), forKey: Self.expandedKey) }
    }
    var favourites: [String] = UserDefaults.standard.stringArray(forKey: favouritesKey) ?? [] {
        didSet { UserDefaults.standard.set(favourites, forKey: Self.favouritesKey) }
    }
    /// Inline rename.
    var renamingId: String?
    var renameText = ""
    /// New folder prompt: mailbox + parent (nil = top level).
    var newFolder: (mailbox: String, parentId: String?)?
    var newFolderName = ""
    var confirmDelete: MailFolder?
    var confirmEmpty: MailFolder?
    var moving: MailFolder?

    func toggle(_ id: String) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
    // ORG2-HOOK: Favourites moved to the sealed `FavouritesList` (MailOrg2.swift); `favourites` above is only the
    // legacy UserDefaults list, migrated once when the store opens.
    func isFavourite(_ id: String) -> Bool { MailOrg2.shared.isFavouriteFolder(id) }
    func setFavourite(_ id: String, _ on: Bool) { MailOrg2.shared.setFavouriteFolder(id, on) }
    func prune(known: Set<String>, loadedMailboxes: Set<String> = []) {
        guard !known.isEmpty else { return }
        MailOrg2.shared.pruneFolders(known: known, loadedMailboxes: loadedMailboxes)
        let e = expanded.intersection(known); if e != expanded { expanded = e }
    }
}

/// Drag payload for a folder (message drags carry bare message ids).
enum FolderDrag {
    static let prefix = "niivo-folder:"
    static func payload(_ f: MailFolder) -> String { prefix + f.id }
}

extension MailModel {
    var folderUI: MailFolderUI { MailFolderUI.shared }

    /// Visible tree rows of one mailbox (Outlook order for siblings).
    func folderRows(_ mailbox: String) -> [FolderTreeRow] {
        FolderTree.rows(folders[mailbox] ?? [], expanded: folderUI.expanded) { MailboxDisplay.sortKey($0) < MailboxDisplay.sortKey($1) }
    }

    var favouriteFolders: [MailFolder] {
        let all = Dictionary(folders.values.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return MailOrg2.shared.favourites.items.compactMap { if case .folder(let id, _) = $0 { all[id] } else { nil } }   // ORG2-HOOK
    }

    /// Sidebar keyboard order: favourites, then each mailbox's visible rows.
    var sidebarOrder: [MailFolder] { favouriteFolders + mailboxes.flatMap { folderRows($0).map(\.folder) } }

    func folder(id: String) -> MailFolder? { folders.values.lazy.flatMap { $0 }.first { $0.id == id } }

    // MARK: Actions (online-only, optimistic in MailSync, error toast here)

    private func runFolderOp(_ ok: String?, symbol: String, _ op: @escaping @Sendable (MailSync) async throws -> Void) {
        guard let sync else { return }
        Task { @MainActor [weak self] in
            do {
                try await op(sync)
                if let ok { self?.toast(MailToast(text: ok, symbol: symbol)) }
            } catch {
                let text = (error as? MailFolderError)?.userText ?? (error as? MailServiceError == .offline
                    ? MailFolderError.offline.userText : "Couldn't change the folder. Try again.")
                self?.toast(MailToast(text: text, symbol: "exclamationmark.triangle", isError: true))
            }
            self?.refreshFolders()
        }
    }

    func beginNewFolder(mailbox: String, parent: MailFolder?) {
        folderUI.newFolderName = ""
        folderUI.newFolder = (mailbox, parent?.id)
        if let parent { folderUI.expanded.insert(parent.id) }
    }

    func commitNewFolder() {
        guard let target = folderUI.newFolder else { return }
        let name = folderUI.newFolderName
        folderUI.newFolder = nil
        guard FolderTree.cleanName(name) != nil else { return }
        runFolderOp(nil, symbol: "folder.badge.plus") { _ = try await $0.createFolder(name: name, parentId: target.parentId, mailbox: target.mailbox) }
    }

    func beginRename(_ f: MailFolder) {
        guard !f.isProtected else { return }
        folderUI.renameText = f.displayName
        folderUI.renamingId = f.id
    }

    func commitRename() {
        guard let id = folderUI.renamingId else { return }
        let name = folderUI.renameText
        folderUI.renamingId = nil
        guard let f = folder(id: id), FolderTree.cleanName(name) != nil, name != f.displayName else { return }
        runFolderOp(nil, symbol: "pencil") { try await $0.renameFolder(id: id, to: name) }
    }

    func moveFolder(_ f: MailFolder, to parent: MailFolder?) {
        guard FolderTree.canMove(f, to: parent, in: folders[f.mailbox] ?? []) else {
            toast(MailToast(text: f.isProtected ? MailFolderError.protected.userText : MailFolderError.invalidDestination.userText,
                            symbol: "exclamationmark.triangle", isError: true))
            return
        }
        if let parent { folderUI.expanded.insert(parent.id) }
        let id = f.id, to = parent?.id
        runFolderOp("Moved \(f.displayName) to \(parent?.displayName ?? "the top level")", symbol: "folder") {
            try await $0.moveFolder(id: id, toParentId: to)
        }
    }

    func deleteFolder(_ f: MailFolder) {
        let id = f.id
        if selectedFolderId == id || FolderTree.descendants(of: id, in: folders[f.mailbox] ?? []).contains(selectedFolderId ?? "") {
            selectedFolderId = (folders[f.mailbox] ?? []).first { $0.wellKnown == .inbox }?.id
        }
        folderUI.setFavourite(id, false)
        runFolderOp("Deleted \(f.displayName)", symbol: "trash") { try await $0.deleteFolder(id: id) }
    }

    func markAllRead(_ f: MailFolder) {
        let id = f.id
        runFolderOp("Marked all as read in \(f.displayName)", symbol: "envelope.open") { try await $0.markAllRead(folderId: id) }
    }

    func emptyFolder(_ f: MailFolder) {
        let id = f.id
        runFolderOp("Emptied \(f.displayName)", symbol: "trash.slash") { try await $0.emptyFolder(folderId: id) }
    }

    /// One drop handler for sidebar rows: folders (prefixed payload) move under the target, messages move into it.
    func handleSidebarDrop(_ items: [String], onto f: MailFolder) -> Bool {
        let parts = items.flatMap { $0.split(separator: "\n").map(String.init) }
        if let p = parts.first(where: { $0.hasPrefix(FolderDrag.prefix) }) {
            guard let dragged = folder(id: String(p.dropFirst(FolderDrag.prefix.count))) else { return false }
            moveFolder(dragged, to: f)
            return true
        }
        // BULK: one plan, one toast, one ⌘Z. Messages from another mailbox are skipped (Graph can't move across).
        let r = applyBulk(.move(folderId: f.id, mailbox: f.mailbox), ids: parts, folderName: f.displayName)
        MailChrome.shared.marked = []
        return r.applied > 0
    }
}

// MARK: - Menus

struct FolderContextMenu: View {
    @Environment(AppModel.self) private var app
    var folder: MailFolder
    var body: some View {
        let mail = app.mail, ui = MailFolderUI.shared, fav = ui.isFavourite(folder.id)
        Button("New Subfolder…") { mail.beginNewFolder(mailbox: folder.mailbox, parent: folder) }
        if !folder.isProtected {
            Button("Rename") { mail.beginRename(folder) }
            Button("Move to…") { ui.moving = folder }
            Button("Delete…", role: .destructive) { ui.confirmDelete = folder }
        }
        Divider()
        Button("Mark All as Read") { mail.markAllRead(folder) }.disabled(folder.unreadCount == 0)
        if folder.canEmpty { Button("Empty \(folder.displayName)…", role: .destructive) { ui.confirmEmpty = folder } }
        Divider()
        Button(fav ? "Remove from Favourites" : "Add to Favourites") { ui.setFavourite(folder.id, !fav) }
    }
}

struct MailboxContextMenu: View {
    @Environment(AppModel.self) private var app
    var mailbox: String
    var body: some View {
        Button("New Folder…") { app.mail.beginNewFolder(mailbox: mailbox, parent: nil) }
    }
}

// MARK: - Row pieces

/// Expand/collapse chevron (or a spacer of the same width so names line up).
struct FolderDisclosure: View {
    @Environment(\.skin) private var skin
    var row: FolderTreeRow?
    var body: some View {
        if let row, row.hasChildren {
            Button { MailFolderUI.shared.toggle(row.id) } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .foregroundStyle(skin.brand ? skin.muted : Color.secondary)
                    .frame(width: 12, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.isExpanded ? "Collapse \(row.folder.displayName)" : "Expand \(row.folder.displayName)")
        } else if row != nil {
            Color.clear.frame(width: 12, height: 16)
        }
    }
}

/// The folder name, or the inline rename field while renaming.
struct FolderName: View {
    @Environment(AppModel.self) private var app
    var folder: MailFolder
    var font: Font
    var color: Color? = nil
    var body: some View {
        let ui = MailFolderUI.shared
        if ui.renamingId == folder.id {
            TextField("Folder name", text: Bindable(ui).renameText)
                .textFieldStyle(.roundedBorder).font(font)
                .onSubmit { app.mail.commitRename() }
                .onExitCommand { ui.renamingId = nil }
        } else {
            Text(folder.displayName).font(font).foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary)).lineLimit(1)
        }
    }
}

extension View {
    /// Context menu, folder drag (custom folders only) and the shared drop handler.
    func folderActions(_ f: MailFolder, mail: MailModel) -> some View {
        modifier(FolderActionsModifier(folder: f, mail: mail))
    }
    /// New folder prompt, delete / empty confirmations and the Move to… sheet. Attach once per sidebar.
    func folderDialogs() -> some View { modifier(FolderDialogs()) }
}

private struct FolderActionsModifier: ViewModifier {
    var folder: MailFolder
    var mail: MailModel
    @Environment(\.skin) private var skin
    @Environment(AppModel.self) private var app
    @ViewBuilder func body(content: Content) -> some View {
        // Drop target highlight, so it's clear which folder a dragged message lands in.
        let targeted = MailFolderUI.shared.dropTargetId == folder.id
        let tint = skin.brand ? skin.accentFill : app.theme.accent
        let base = content
            .background { if targeted { RoundedRectangle(cornerRadius: skin.brand ? 0 : 5).fill(tint.opacity(0.22)) } }
            .overlay { if targeted { RoundedRectangle(cornerRadius: skin.brand ? 0 : 5).strokeBorder(tint, lineWidth: 1.5) } }
            .contextMenu { FolderContextMenu(folder: folder) }
            .dropDestination(for: String.self) { items, _ in mail.handleSidebarDrop(items, onto: folder) }
                isTargeted: { t in
                    let ui = MailFolderUI.shared
                    if t { ui.dropTargetId = folder.id } else if ui.dropTargetId == folder.id { ui.dropTargetId = nil }
                }
        if folder.isProtected { base } else { base.draggable(FolderDrag.payload(folder)) }
    }
}

private struct FolderDialogs: ViewModifier {
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        let ui = MailFolderUI.shared, mail = app.mail
        content
            .onChange(of: mail.folders) { _, all in
                ui.prune(known: Set(all.values.flatMap { $0 }.map(\.id)), loadedMailboxes: Set(all.filter { !$0.value.isEmpty }.keys))   // ORG2-HOOK
            }
            .alert(ui.newFolder?.parentId == nil ? "New Folder" : "New Subfolder",
                   isPresented: Binding(get: { ui.newFolder != nil }, set: { if !$0 { ui.newFolder = nil } })) {
                TextField("Name", text: Bindable(ui).newFolderName)
                Button("Create") { mail.commitNewFolder() }
                Button("Cancel", role: .cancel) { ui.newFolder = nil }
            } message: {
                if let pid = ui.newFolder?.parentId, let p = mail.folder(id: pid) { Text("Inside \(p.displayName)") }
            }
            .confirmationDialog("Delete \(ui.confirmDelete?.displayName ?? "folder")?",
                                isPresented: Binding(get: { ui.confirmDelete != nil }, set: { if !$0 { ui.confirmDelete = nil } })) {
                Button("Delete", role: .destructive) { if let f = ui.confirmDelete { mail.deleteFolder(f) }; ui.confirmDelete = nil }
            } message: {
                Text("The folder, its sub-folders and their messages go to Deleted Items.")
            }
            .confirmationDialog("Empty \(ui.confirmEmpty?.displayName ?? "folder")?",
                                isPresented: Binding(get: { ui.confirmEmpty != nil }, set: { if !$0 { ui.confirmEmpty = nil } })) {
                Button("Empty", role: .destructive) { if let f = ui.confirmEmpty { mail.emptyFolder(f) }; ui.confirmEmpty = nil }
            } message: {
                Text("Every message and sub-folder in it is deleted. This can't be undone here.")
            }
            .sheet(item: Binding(get: { ui.moving }, set: { ui.moving = $0 })) { f in MoveFolderSheet(folder: f) }
    }
}

/// "Move to…": the mailbox's tree, fully expanded, invalid targets disabled.
struct MoveFolderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var folder: MailFolder
    var body: some View {
        let mail = app.mail, all = mail.folders[folder.mailbox] ?? []
        let rows = FolderTree.rows(all, expanded: Set(all.map(\.id))) { MailboxDisplay.sortKey($0) < MailboxDisplay.sortKey($1) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Move \(folder.displayName) to…").font(skin.brand ? skin.sans(NV.Size.body, .medium) : .headline).padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    target(nil, label: "Top level of \(MailboxDisplay.title(folder.mailbox))", depth: 0, symbol: "tray.2", all: all)
                    ForEach(rows) { r in target(r.folder, label: r.folder.displayName, depth: r.depth + 1,
                                                symbol: MailboxDisplay.folderSymbol(r.folder), all: all) }
                }
                .padding(.vertical, 6)
            }
            Divider()
            HStack { Spacer(); Button("Cancel") { MailFolderUI.shared.moving = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
        .frame(width: 340, height: 420)
    }

    private func target(_ dest: MailFolder?, label: String, depth: Int, symbol: String, all: [MailFolder]) -> some View {
        let ok = FolderTree.canMove(folder, to: dest, in: all)
        return Button {
            MailFolderUI.shared.moving = nil
            app.mail.moveFolder(folder, to: dest)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16)
                Text(label).lineLimit(1)
                Spacer()
            }
            .padding(.leading, 14 + CGFloat(depth) * 14).padding(.trailing, 14).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!ok)
        .opacity(ok ? 1 : 0.4)
    }
}
