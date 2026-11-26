import SwiftUI
import CalendarCore
import MailCore

// MARK: - Additional mailboxes: sidebar controls + "Add mailbox…" sheet

/// Chevron that collapses a mailbox's section (both sidebars).
struct MailboxCollapseToggle: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var mailbox: String
    var body: some View {
        let m = app.mail.mailboxManager
        let collapsed = m.isCollapsed(mailbox)
        Button { m.toggleCollapsed(mailbox) } label: {
            NSymbol(collapsed ? "chevron.right" : "chevron.down", size: 9).font(.system(size: 9, weight: .medium))
                .foregroundStyle(skin.brand ? skin.muted : Color.secondary)
                .frame(width: 20, height: 20).contentShape(Rectangle())   // the 9 pt glyph alone was too small to hit
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? "Expand \(MailboxDisplay.title(mailbox))" : "Collapse \(MailboxDisplay.title(mailbox))")
        .help(collapsed ? "Show folders" : "Hide folders")
    }
}

/// Context menu on a mailbox header: collapse, reorder, remove.
struct MailboxHeaderMenu: ViewModifier {
    @Environment(AppModel.self) private var app
    var mailbox: String
    func body(content: Content) -> some View {
        let m = app.mail.mailboxManager
        content.contextMenu {
            Button(m.isCollapsed(mailbox) ? "Show Folders" : "Hide Folders") { m.toggleCollapsed(mailbox) }
            if mailbox != "me" {
                Divider()
                Button("Move Up") { Task { await m.move(mailbox, by: -1) } }.disabled(!m.canMove(mailbox, by: -1))
                Button("Move Down") { Task { await m.move(mailbox, by: 1) } }.disabled(!m.canMove(mailbox, by: 1))
                Divider()
                Button("Remove Mailbox", role: .destructive) { Task { await m.remove(mailbox) } }
            }
            Divider()
            Button("Add Mailbox…") { m.beginAdd() }
        }
    }
}

extension View {
    func mailboxHeaderMenu(_ mailbox: String) -> some View { modifier(MailboxHeaderMenu(mailbox: mailbox)) }
}

/// Under a mailbox header: why it couldn't be synced (403 / 404 …). Remove is in the header's context menu.
struct MailboxErrorRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var mailbox: String
    var body: some View {
        if let msg = app.mail.mailboxManager.error(for: mailbox) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                NSymbol("exclamationmark.triangle", size: 10).foregroundStyle(skin.brand ? skin.accentInk : Color.orange)
                Text(msg).font(skin.brand ? skin.sans(NV.Size.labelSm + 1) : .caption).foregroundStyle(skin.brand ? skin.muted : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, skin.brand ? 16 : 4).padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

/// "Add mailbox…" row at the end of the mailbox list (both sidebars).
struct AddMailboxRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = app.mail.mailboxManager
        Button { m.beginAdd() } label: {
            if skin.brand {
                HStack(spacing: 8) { Text("+").font(skin.mono(NV.Size.label)); Text("Add mailbox…").font(skin.sans(NV.Size.body)) }
                    .foregroundStyle(skin.muted).padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
            } else {
                NLabel("Add Mailbox…", systemImage: "plus.circle", size: 13).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Open a shared or delegated mailbox, or another person's mailbox you have access to")
    }
}

/// The "Add mailbox…" sheet, attached to the sidebar container (not the row: the row can scroll out of a lazy stack,
/// and the header context menu opens the sheet too).
struct AddMailboxSheetHost: ViewModifier {
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        content.sheet(isPresented: Bindable(app.mail.mailboxManager).showAdd) { AddMailboxSheet().environment(app).skinned(app.skin) }
    }
}

extension View {
    func addMailboxSheet() -> some View { modifier(AddMailboxSheetHost()) }
}

struct AddMailboxSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = app.mail.mailboxManager
        @Bindable var b = m
        VStack(alignment: .leading, spacing: 14) {
            if skin.brand { MonoLabel("Add mailbox", bracket: true) } else { Text("Add Mailbox").font(.title3.weight(.semibold)) }
            Text("Type the mailbox's address or search the directory. Access is checked before it's added; Microsoft 365 can't list the mailboxes you can open.")
                .font(skin.brand ? skin.sans(NV.Size.body) : .callout).foregroundStyle(skin.muted)
                .fixedSize(horizontal: false, vertical: true)
            NField("name@company.com or a name", text: $b.query, label: "Mailbox", style: .bordered, symbol: "magnifyingglass") {
                Task { await m.add() }
            }
            if !m.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(m.suggestions, id: \.address) { s in
                        Button { m.pick(s) } label: {
                            HStack(spacing: 8) {
                                MailboxBadge(mailbox: s.address.lowercased(), size: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.name.isEmpty ? s.address : s.name).font(skin.brand ? skin.sans(NV.Size.body) : .body).foregroundStyle(skin.ink)
                                    Text(s.address).font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption).foregroundStyle(skin.muted)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4).padding(.horizontal, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxHeight: 200)
            } else if !m.directoryAvailable && m.grantDirectory != nil {
                Button("Allow directory lookup…") { Task { await m.allowDirectoryLookup() } }.nvButton(skin, .quiet).font(.caption)
            }
            if skin.brand {
                NPicker("Use as", selection: $b.kind, options: MailboxAccessKind.allCases, label: { $0.title })
            } else {
                Picker("Use as", selection: $b.kind) { ForEach(MailboxAccessKind.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            Text("Shared and delegate mailboxes are offered in the From picker. Exchange decides whether you may actually send as or on behalf of it.")
                .font(skin.brand ? skin.sans(NV.Size.labelSm + 1) : .caption).foregroundStyle(skin.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let e = m.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    NSymbol("exclamationmark.triangle", size: 11).foregroundStyle(skin.brand ? skin.accentInk : Color.orange)
                    Text(e).font(skin.brand ? skin.sans(NV.Size.body) : .callout).foregroundStyle(skin.ink).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                if m.validating { ProgressView().controlSize(.small); Text("Checking access…").font(.caption).foregroundStyle(skin.muted) }
                Spacer()
                NButton("Cancel", kind: .quiet) { m.showAdd = false }.keyboardShortcut(.cancelAction)
                NButton("Add") { Task { await m.add() } }.keyboardShortcut(.defaultAction)
                    .disabled(m.validating || MailboxAddress.normalise(m.query) == nil)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(skin.brand ? skin.card : Color.clear)
    }
}
