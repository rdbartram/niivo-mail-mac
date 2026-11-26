import SwiftUI
import CalendarCore

// CALENDAR: views for added / group calendars (model: CalendarExtras.swift).

struct AddCalendarSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin

    var body: some View {
        let x = CalendarExtras.shared
        @Bindable var b = x
        VStack(alignment: .leading, spacing: 14) {
            if skin.brand { MonoLabel("Calendar", bracket: true) }
            Text(skin.brand ? "Add a calendar." : "Add Calendar").font(skin.sans(NV.Size.title)).foregroundStyle(skin.ink)
            NTabs(title: "Kind", items: CalendarExtras.AddTab.allCases, selection: $b.addTab, label: { $0.rawValue }, count: { _ in 0 },
                  divider: false, horizontalPadding: 0)
                .fixedSize()
                .onChange(of: x.addTab) { if x.addTab == .group { x.loadGroups(model) } }
            if x.addTab == .person { personPane(x, $b.addressDraft) } else { groupPane(x) }
            if let err = x.addError {
                NLabel(err, systemImage: "exclamationmark.triangle", size: 11).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !x.sources.isEmpty {
                MonoLabel("Added", size: NV.Size.labelSm)
                ForEach(x.sources) { s in
                    HStack {
                        NSymbol(Self.symbol(s), size: 11).foregroundStyle(skin.muted)
                        Text(s.displayName).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.ink).lineLimit(1)
                        if let p = x.problem(s, model) { NSymbol("exclamationmark.triangle.fill", size: 10, label: p).foregroundStyle(.orange).help(p) }
                        Spacer()
                        NIconButton("minus.circle", label: "Remove \(s.displayName)", size: 22) { x.remove(s, model) }
                    }
                }
            }
            HStack {
                Spacer()
                NButton("Done", kind: .ghost) { x.showAddCalendar = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(skin.brand ? skin.card : .clear)
    }

    @ViewBuilder private func personPane(_ x: CalendarExtras, _ text: Binding<String>) -> some View {
        Text("Someone else’s calendar, a shared mailbox or a resource. It shows if its owner has shared it with you.")
            .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
        NField("name@company.com", text: text, style: .bordered, symbol: "person.crop.circle.badge.plus", onSubmit: { x.addPerson(model) })
        HStack {
            Spacer()
            NButton(x.adding ? "Checking…" : "Add", kind: .primary) { x.addPerson(model) }
                .disabled(x.adding || x.addressDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func groupPane(_ x: CalendarExtras) -> some View {
        Text("Microsoft 365 groups you belong to. The group calendar shows alongside yours; members can add events.")
            .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
        if x.loadingGroups { ProgressView().controlSize(.small) }
        if let e = x.groupsError {
            Text(e.message).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.danger)
            if e == .needsConsent || e == .noAccess {
                NButton("Grant access…", kind: .ghost) { x.grant(Auth.groupReadScopes + Auth.groupCalendarScopes, model) { x.loadGroups(model) } }
            }
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(x.groups) { g in
                    let added = x.sources.contains { $0.id == "group:" + g.id }
                    HStack(spacing: 9) {
                        OwnerInitials(name: g.name, color: skin.accentInk)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).lineLimit(1)
                            if let m = g.mail { MonoLabel(m, size: NV.Size.labelSm).lineLimit(1) }
                        }
                        Spacer()
                        if added { MonoLabel("Added", size: NV.Size.labelSm) }
                        else { NButton("Add", kind: .ghost) { x.addGroup(g, model) }.disabled(x.adding) }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(minHeight: 120, maxHeight: 220)
    }

    static func symbol(_ s: CalendarSource) -> String {
        if case .group = s { return "person.3" } else { return "person.crop.circle" }
    }
}

/// Sidebar block: added calendars that have a problem (403 / 404 / consent), plus the Add button.
struct AddedCalendarsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    var body: some View {
        let x = CalendarExtras.shared
        VStack(alignment: .leading, spacing: 4) {
            ForEach(x.sources) { s in
                if let p = x.problem(s, model) {
                    HStack(spacing: 6) {
                        NSymbol("exclamationmark.triangle.fill", size: 10).foregroundStyle(.orange)
                        Text(s.displayName).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.ink).lineLimit(1)
                    }
                    .help(p)
                    .contextMenu { Button("Remove Calendar") { x.remove(s, model) } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(s.displayName): \(p)")
                }
            }
            Button { x.beginAdd(model) } label: { NLabel("Add calendar…", systemImage: "plus", size: 11) }
                .buttonStyle(.plain).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.accentInk)
                .help("Add someone’s calendar by address, or a Microsoft 365 group calendar")
        }
    }
}

