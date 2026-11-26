import SwiftUI
import AppKit
import MailCore

// Microsoft 365 Groups management (GraphGroupsService+Manage.swift): files link, members, join / leave (public
// groups), follow in inbox, server favourite + local Favourites pin. Membership changes need Group.ReadWrite.All
// (write token, admin consent) and, per Learn, usually an owner/admin role → a 403 is explained, not retried.

@MainActor @Observable final class GroupManage {
    static let shared = GroupManage()
    /// OneDrive token (Files.ReadWrite ⊇ Files.Read for /groups/{id}/drive). Set at mail configure.
    @ObservationIgnored var filesToken: GraphHTTP.TokenProvider?
    var members: [GroupMember] = []
    var showMembers = false
    var showJoin = false
    var joinQuery = ""
    var joinable: [M365Group] = []
    var notice: String?
    var busy = false
    var confirmLeave: M365Group?

    private func service(_ mail: MailModel) -> GroupManageService? { mail.groups.searchService as? GroupManageService }

    private func run(_ mail: MailModel, ok: String?, _ op: @escaping @MainActor (GroupManageService) async throws -> Void) {
        guard let svc = service(mail) else { notice = "Groups aren't available."; return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await op(svc); if let ok { mail.toast(MailToast(text: ok, symbol: "checkmark")) } }
            catch GroupManageError.notAllowed { notice = "Your organisation only lets group owners or admins change membership. Ask an owner to add or remove you." }
            catch GroupManageError.alreadyMember { notice = "You're already a member." }
            catch MailServiceError.forbidden { notice = "This needs Group.ReadWrite.All (admin consent)." }
            catch { notice = "That didn't work: \(GroupsModel.message(for: error))" }
        }
    }

    func openFiles(_ g: M365Group, mail: MailModel) {
        let tok = filesToken
        run(mail, ok: nil) { svc in
            guard let u = try await svc.filesURL(groupId: g.id, filesToken: tok) else { throw MailServiceError.notFound }
            NSWorkspace.shared.open(u)
        }
    }
    func loadMembers(_ g: M365Group, mail: MailModel) {
        members = []; showMembers = true
        run(mail, ok: nil) { [weak self] svc in self?.members = try await svc.members(groupId: g.id, top: 200) }
    }
    func follow(_ g: M365Group, _ on: Bool, mail: MailModel) {
        run(mail, ok: on ? "Following \(g.displayName) in your inbox" : "Stopped following \(g.displayName)") { try await $0.setFollowInInbox(groupId: g.id, on) }
    }
    /// Local Favourites pin (always) + Outlook's server favourite (best effort, doesn't block the pin).
    func favourite(_ g: M365Group, _ on: Bool, mail: MailModel) {
        MailOrg2.shared.favourites.set(.group(id: g.id, name: g.displayName), on)
        run(mail, ok: nil) { try await $0.setFavourite(groupId: g.id, on) }
    }
    func leave(_ g: M365Group, mail: MailModel) {
        run(mail, ok: "Left \(g.displayName)") { svc in try await svc.leave(groupId: g.id); await mail.groups.reload() }
    }
    func search(mail: MailModel) {
        let q = joinQuery
        run(mail, ok: nil) { [weak self] svc in
            let mine = Set(mail.groups.groups.map(\.id))
            self?.joinable = try await svc.publicGroups(search: q).filter { !mine.contains($0.id) }
        }
    }
    func join(_ g: M365Group, mail: MailModel) {
        run(mail, ok: "Joined \(g.displayName)") { [weak self] svc in
            try await svc.join(groupId: g.id); self?.showJoin = false; await mail.groups.reload()
        }
    }
}

/// Header menu for the selected group (GroupViews hook).
struct GroupManageButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail, gm = GroupManage.shared
        if let g = mail.groups.selectedGroup {
            let fav = MailOrg2.shared.favourites.contains(.group(id: g.id, name: g.displayName))
            Menu {
                Button("Files") { gm.openFiles(g, mail: mail) }
                Button("Members…") { gm.loadMembers(g, mail: mail) }
                Divider()
                Button("Follow in Inbox") { gm.follow(g, true, mail: mail) }
                Button("Stop Following in Inbox") { gm.follow(g, false, mail: mail) }
                Button(fav ? "Remove from Favourites" : "Add to Favourites") { gm.favourite(g, !fav, mail: mail) }
                Divider()
                Button("Join a Group…") { gm.joinable = []; gm.showJoin = true }
                Button("Leave \(g.displayName)…", role: .destructive) { gm.confirmLeave = g }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Group: files, members, follow, favourite, join / leave")
            .accessibilityLabel("Group actions")
            .sheet(isPresented: Bindable(gm).showMembers) { GroupMembersSheet(title: g.displayName) }
            .sheet(isPresented: Bindable(gm).showJoin) { GroupJoinSheet() }
            .confirmationDialog("Leave \(gm.confirmLeave?.displayName ?? "this group")?", isPresented: Binding(get: { gm.confirmLeave != nil }, set: { if !$0 { gm.confirmLeave = nil } })) {
                Button("Leave Group", role: .destructive) { if let l = gm.confirmLeave { gm.leave(l, mail: mail) }; gm.confirmLeave = nil }
            } message: { Text("You'll stop getting its conversations. Private groups need an owner to add you back.") }
            .alert(gm.notice ?? "", isPresented: Binding(get: { gm.notice != nil }, set: { if !$0 { gm.notice = nil } })) { Button("OK") {} }
        }
    }
}

private struct GroupMembersSheet: View {
    var title: String
    var body: some View {
        let gm = GroupManage.shared
        VStack(alignment: .leading, spacing: 10) {
            Text("Members of \(title)").font(.title3.weight(.semibold))
            if gm.busy && gm.members.isEmpty { ProgressView() }
            List(gm.members) { m in
                VStack(alignment: .leading) {
                    Text(m.displayName)
                    Text([m.jobTitle, m.mail].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 260)
            HStack { Spacer(); Button("Done") { gm.showMembers = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 420)
    }
}

private struct GroupJoinSheet: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let gm = GroupManage.shared, mail = app.mail
        VStack(alignment: .leading, spacing: 10) {
            Text("Join a public group").font(.title3.weight(.semibold))
            HStack {
                TextField("Search group names", text: Bindable(gm).joinQuery).onSubmit { gm.search(mail: mail) }
                Button("Search") { gm.search(mail: mail) }
            }
            List(gm.joinable) { g in
                HStack { Text(g.displayName); Spacer(); Button("Join") { gm.join(g, mail: mail) }.disabled(gm.busy) }
            }
            .frame(minHeight: 220)
            Text("Many organisations only let owners add members; you'll see why if it's refused.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Close") { gm.showJoin = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 440)
    }
}
