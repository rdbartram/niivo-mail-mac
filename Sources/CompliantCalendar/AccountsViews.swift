import SwiftUI
import CalendarCore

/// ACCOUNTS-HOOK: Settings → Accounts (docs/ACCOUNTS.md §6). List, add (browser sign-in), remove, reorder, colour,
/// default, switch.
struct AccountsSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let acc = app.accounts
        @Bindable var a = acc
        Form {
            Section("Accounts") {
                if acc.unreadable {
                    Text("The account list is locked. Unlock niivo mail to manage accounts.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if acc.accounts.isEmpty {
                    Text("No accounts yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(acc.accounts.enumerated()), id: \.element.id) { i, account in
                    AccountRow(account: account, index: i, count: acc.accounts.count)
                }
            }
            Section {
                Button {
                    Task { await acc.add(app: app) }
                } label: { NLabel(acc.busy ? "Waiting for sign-in…" : "Add Account…", systemImage: "plus", size: 13) }
                .disabled(acc.busy || app.auth == nil || acc.unreadable)
                if let e = acc.errorText {
                    Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let url = acc.consentURL {
                    HStack {
                        Button("Copy Approval Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    }
                }
                Text("Adding an account opens the Microsoft sign-in page in your browser. Each account keeps its own "
                     + "encrypted cache, sensitivity labels and policies. Content never moves between accounts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { if !acc.loaded { acc.load(keyring: app.trust.keyring, auth: app.auth) } }
        .confirmationDialog("Remove this account?", isPresented: Binding(get: { a.pendingRemoval != nil },
                                                                        set: { if !$0 { a.pendingRemoval = nil } }),
                            presenting: a.pendingRemoval) { account in
            Button("Remove \(account.username)", role: .destructive) {
                Task { await acc.remove(account.id, app: app); acc.pendingRemoval = nil }
            }
        } message: { account in
            Text("This deletes \(account.username)'s mail and calendar cache and its sign-in from this Mac. "
                 + "Nothing on the server changes.")
        }
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var app
    let account: Account
    let index: Int
    let count: Int

    var body: some View {
        let acc = app.accounts
        HStack(spacing: 10) {
            AccountDot(colour: account.colour, size: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.title).font(.system(size: 13, weight: .medium))
                    if acc.registry.defaultAccount?.id == account.id {
                        Text("Default").font(.caption2).foregroundStyle(.secondary)
                    }
                    if acc.activeId == account.id {
                        Text("Open").font(.caption2).foregroundStyle(.tint)
                    }
                }
                Text(account.username).font(.caption).foregroundStyle(.secondary)
                Text(account.provider.displayName + (account.tenantId.map { " · tenant \($0.prefix(8))…" } ?? ""))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                if acc.activeId != account.id {
                    Button("Open This Account") { Task { await acc.switchTo(account.id, app: app) } }
                }
                if acc.registry.defaultAccount?.id != account.id {
                    Button("Make Default") { acc.makeDefault(account.id) }
                }
                Menu("Colour") {
                    ForEach(AccountColour.allCases, id: \.self) { c in
                        Button(c.title) { acc.setColour(c, for: account.id) }
                    }
                }
                Divider()
                Button("Move Up") { acc.move(account.id, by: -1) }.disabled(index == 0)
                Button("Move Down") { acc.move(account.id, by: 1) }.disabled(index == count - 1)
                Divider()
                Button("Remove…", role: .destructive) { acc.pendingRemoval = account }
            } label: { NSymbol("ellipsis.circle", size: 14, label: "Account actions") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 2)
    }
}

struct AccountDot: View {
    let colour: AccountColour
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(Color(nsColor: colour.color)).frame(width: size, height: size)
            .accessibilityLabel("Account colour \(colour.title)")
    }
}

/// Sidebar group header: one row per account when more than one is signed in. The open account shows its folders and
/// shared mailboxes below (the existing sidebar); the others switch on click.
struct SidebarAccountsSwitcher: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let acc = app.accounts
        if acc.registry.isMultiAccount {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(acc.accounts) { account in
                    Button {
                        Task { await acc.switchTo(account.id, app: app) }
                    } label: {
                        HStack(spacing: 8) {
                            AccountDot(colour: account.colour)
                            Text(account.title).font(.system(size: 12, weight: acc.activeId == account.id ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer()
                            if acc.activeId == account.id { NSymbol("chevron.down", size: 9, label: "Open") }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help(account.username)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
