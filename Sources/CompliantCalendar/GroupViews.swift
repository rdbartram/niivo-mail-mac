import SwiftUI
import CalendarCore
import MailCore

// MARK: - Groups: sidebar

/// Classic sidebar (inside `List`): a "Groups" section.
struct GroupsSidebarSection: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let g = app.mail.groups
        if g.isConfigured {
            Section(isExpanded: Bindable(g).expanded) {
                GroupsSidebarRows()
            } header: {
                Text("Groups")
            }
            .task { await g.loadIfNeeded() }
        }
    }
}

/// niivo sidebar: header + rows drawn like the mailbox tree.
struct GroupsSidebarBlock: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var index: Int
    var body: some View {
        let g = app.mail.groups
        if g.isConfigured {
            VStack(alignment: .leading, spacing: 0) {
                Button { g.expanded.toggle() } label: {
                    HStack(spacing: 7) {
                        MonoLabel(String(format: "%02d", index), size: NV.Size.labelSm, color: skin.accentInk)
                        MonoLabel("Groups", color: skin.ink, wide: true, weight: .medium)
                        Spacer(minLength: 0)
                        NSymbol(g.expanded ? "chevron.down" : "chevron.right", size: 9).foregroundStyle(skin.muted)
                    }
                    .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(g.expanded ? "Groups, expanded" : "Groups, collapsed")
                if g.expanded { GroupsSidebarRows() }
            }
            .task { await g.loadIfNeeded() }
        }
    }
}

struct GroupsSidebarRows: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let g = app.mail.groups
        let small: Font = skin.brand ? skin.sans(NV.Size.labelSm + 1) : .caption
        let pad: CGFloat = skin.brand ? 16 : 4
        switch g.state {
        case .idle, .loading:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading groups…") }
                .font(small).foregroundStyle(skin.muted).padding(.horizontal, pad).padding(.vertical, 4)
        case .needsConsent(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).font(small).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
                if g.grant != nil { Button("Allow Groups…") { Task { await g.grantRead() } }.nvButton(skin, .quiet).font(.caption) }
            }
            .padding(.horizontal, pad).padding(.vertical, 4)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).font(small).foregroundStyle(skin.muted)
                Button("Try Again") { Task { await g.reload() } }.nvButton(skin, .quiet).font(.caption)
            }
            .padding(.horizontal, pad).padding(.vertical, 4)
        case .ready:
            if g.groups.isEmpty {
                Text("You're not a member of any Microsoft 365 group.").font(small)
                    .foregroundStyle(skin.muted).padding(.horizontal, pad).padding(.vertical, 4)
            }
            ForEach(g.groups) { grp in GroupSidebarRow(group: grp) }
        }
    }
}

struct GroupSidebarRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var group: M365Group
    var body: some View {
        let g = app.mail.groups
        let selected = g.isActive && g.selectedGroupId == group.id
        let unseen = group.unseenCount ?? 0
        Button { g.select(group) } label: {
            HStack(spacing: 9) {
                NSymbol("person.3", size: 12).font(.system(size: 12, weight: .light))
                    .foregroundStyle(selected ? skin.ink : skin.muted).frame(width: 18)
                Text(group.displayName).font(skin.brand ? skin.sans(NV.Size.body, selected ? .medium : .regular) : .body)
                    .foregroundStyle(skin.ink).lineLimit(1)
                Spacer(minLength: 4)
                if unseen > 0 {
                    Text("\(unseen)").font(skin.brand ? skin.mono(NV.Size.label, .medium) : .caption.monospacedDigit())
                        .foregroundStyle(selected ? skin.accentInk : skin.muted)
                }
            }
            .padding(.leading, skin.brand ? 16 : 0).padding(.trailing, skin.brand ? 14 : 0).padding(.vertical, skin.brand ? 6 : 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(GroupRowChrome(selected: selected, key: "group:" + group.id))
        .accessibilityLabel(unseen > 0 ? "\(group.displayName), \(unseen) new" : group.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(group.mail ?? group.displayName)
    }
}

private struct GroupRowChrome: ViewModifier {
    @Environment(\.skin) private var skin
    var selected: Bool
    var key: String
    func body(content: Content) -> some View {
        if skin.brand { content.nRow(selected: selected, hoverKey: AnyHashable(key), divider: false, skin: skin) }
        else { content.listRowBackground(selected ? Color.accentColor.opacity(0.18) : Color.clear) }
    }
}

// MARK: - Groups: conversation list

struct GroupConversationListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let g = app.mail.groups
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if skin.brand { MonoLabel("Group", size: NV.Size.labelSm) }
                    Text(g.selectedGroup?.displayName ?? "Group").font(skin.brand ? skin.sans(17, .medium) : .headline).foregroundStyle(skin.ink).lineLimit(1)
                }
                Spacer()
                NIconButton("arrow.clockwise", label: "Refresh") { Task { await g.loadConversations() } }
                NIconButton("square.and.pencil", label: "New conversation", help: "Start a new conversation in this group") { g.startNewConversation() }
                    .disabled(g.pendingPost != nil)
                GroupManageButton()   // ORG2-HOOK: files, members, follow, favourite, join / leave (GroupManage.swift)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .hairline(skin)
            // Undo must be reachable without a conversation open (new conversation).
            if let pending = g.pendingPost, g.thread == nil { GroupPendingBar(text: pending.text, deadline: pending.deadline) }
            if let n = g.notice, g.thread == nil {
                HStack { NSymbol("info.circle", size: 11); Text(n); Spacer(); Button("OK") { g.clearNotice() }.buttonStyle(.plain) }
                    .font(.caption).padding(.horizontal, 14).padding(.vertical, 6)
            }
            if g.conversationsLoading && g.conversations.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let e = g.conversationsError {
                Notice(icon: "exclamationmark.triangle", text: e).padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if g.conversations.isEmpty {
                BrandEmptyState(symbol: "bubble.left.and.bubble.right", eyebrow: "Group", title: "No conversations yet.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(g.conversations) { c in GroupConversationRow(conversation: c, selected: g.selectedConversationId == c.id) }
                    }
                }
            }
        }
        .background(skin.brand ? AnyShapeStyle(skin.ground) : AnyShapeStyle(.background))
        .sheet(item: Bindable(g).composer) { c in GroupComposerSheet(composer: c).environment(app).skinned(app.skin) }
    }
}

struct GroupConversationRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var conversation: GroupConversation
    var selected: Bool
    var body: some View {
        // Topic and senders come from the conversation resource (no label on it), like a mail header row; the posts'
        // labels are decided in the reader, which hides what the label doesn't allow.
        Button { app.mail.groups.open(conversation) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.senders.prefix(3).joined(separator: ", ")).font(skin.brand ? skin.sans(NV.Size.body, .medium) : .body.weight(.semibold))
                        .foregroundStyle(skin.ink).lineLimit(1)
                    Spacer()
                    if conversation.hasAttachments { NSymbol("paperclip", size: 10).foregroundStyle(skin.muted) }
                    if let d = conversation.lastDelivered {
                        Text(d.formatted(date: .abbreviated, time: .shortened)).font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption).foregroundStyle(skin.muted)
                    }
                }
                Text(conversation.topic.isEmpty ? "(no subject)" : conversation.topic).font(skin.brand ? skin.sans(NV.Size.body) : .callout)
                    .foregroundStyle(skin.ink).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nRow(selected: selected, hoverKey: AnyHashable("gconv:" + conversation.id), divider: true, skin: skin)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
