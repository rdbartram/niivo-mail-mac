import SwiftUI
import AppKit
import CalendarCore
import MailCore

// People window (⌃⌘3), Tasks window (⌃⌘4), contact card, contact editor, presence dot and the reader/list hooks.
// State lives in PeopleHub / TasksHub / PresenceHub (no @State: the toolchain can't expand SwiftUI macros).

struct PeopleCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("People") { openWindow(id: "people") }.keyboardShortcut("3", modifiers: [.command, .control])
            Button("Tasks") { openWindow(id: "tasks") }.keyboardShortcut("4", modifiers: [.command, .control])
            Button(L("People Directory")) { KnowledgeHub.shared.openDirectory(openWindow: openWindow) }.keyboardShortcut("5", modifiers: [.command, .control])   // PEOPLE2-HOOK
        }
    }
}

// MARK: - Presence dot

struct PresenceDot: View {
    @Environment(AppModel.self) private var model
    var address: String?
    var size: CGFloat = 8
    var body: some View {
        if let a = address?.lowercased(), !a.isEmpty {
            let hub = PresenceHub.shared
            let p = hub.values[a]   // read only here: a presence update re-evaluates the dot, not the row
            Circle()
                .fill(Self.color(p?.availability))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: size, height: size)
                .opacity(p == nil ? 0 : 1)
                .help(p?.label ?? "")
                .accessibilityLabel(p?.label ?? "")
                .accessibilityHidden(p == nil)
                .onAppear { model.ensurePeopleHubs(); hub.appear(a) }
                .onDisappear { hub.disappear(a) }
        }
    }
    static func color(_ a: PresenceInfo.Availability?) -> Color {
        switch a {
        case .available?, .availableIdle?: Color(red: 0.42, green: 0.73, blue: 0.27)
        case .busy?, .busyIdle?, .doNotDisturb?: Color(red: 0.77, green: 0.19, blue: 0.23)
        case .away?, .beRightBack?: Color(red: 0.99, green: 0.73, blue: 0.13)
        default: Color.gray.opacity(0.6)
        }
    }
}

extension View {
    /// List-row hook: a presence dot after the sender (nil = nothing, e.g. redacted).
    func presenceDot(_ address: String?) -> some View {
        HStack(spacing: 4) { self; PresenceDot(address: address, size: 7) }
    }
    /// Reader hook: the sender opens the contact card; presence dot alongside. nil = plain (redacted / no sender).
    func personCard(_ who: EmailAddress?) -> some View { modifier(PersonCardLink(who: who)) }
}

private struct PersonCardLink: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model
    var who: EmailAddress?
    func body(content: Content) -> some View {
        if let who, !who.address.isEmpty {
            HStack(spacing: 5) {
                PresenceDot(address: who.address)
                content
                    .senderHoverCard(who)   // ORG2-HOOK: hover card (MailAvatars.swift)
                    .contentShape(Rectangle())
                    .onTapGesture { open(who) }
                    .help("Show person")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Show contact card") { open(who) }
            }
        } else { content }
    }
    private func open(_ who: EmailAddress) {
        // PEOPLE-HOOK: clicking a sender opens the person page (timeline, role, voice notes); its "Contact card"
        // button still reaches the directory card. Falls back to the card when nothing is visible yet.
        if model.mail.started, model.mail.store != nil {
            KnowledgeHub.shared.open(person: who.address, mail: model.mail, openWindow: openWindow); return
        }
        let hub = PeopleHub.shared
        hub.app = model
        hub.show(address: who.address, name: who.name)
        openWindow(id: "people")
    }
}

/// Reader hook: "Add to To Do" for the open message (label-aware title, link back to the message).
struct TaskFromMessageButton: View {
    @Environment(AppModel.self) private var model
    var message: MailMessage
    var policy: ContentPolicy
    var body: some View {
        let hub = TasksHub.shared
        let _ = model.ensurePeopleHubs()
        if hub.isConfigured {
            NIconButton("checklist", label: "Add to To Do",
                        help: policy.allowOfflineDetails && !policy.redactDetails
                            ? "Create a To Do task linked to this message"
                            : "Create a To Do task linked to this message (titled \"\(TodoFromMail.confidentialTitle)\" because of its label)",
                        size: 24) {
                let m = message, p = policy
                let mail = model.mail
                Task {
                    let r = await hub.createFromMessage(m, policy: p)
                    mail.toast(MailToast(text: r.text, symbol: r.ok ? "checklist" : "exclamationmark.triangle", isError: !r.ok))
                }
            }
        }
    }
}

// MARK: - People window

struct PeopleWindowRoot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SecondaryWindow(captureBlocked: model.mail.screenPolicy.preventScreenCapture || (PeopleHub.shared.card?.preventCapture ?? false)) {
            PeopleScreen(hub: PeopleHub.shared)
        }
        .frame(minWidth: 860, minHeight: 560)
        .task {
            model.ensurePeopleHubs()
            PeopleHub.shared.app = model
            if PeopleHub.shared.people.isEmpty { await PeopleHub.shared.load() }
        }
    }
}

struct PeopleScreen: View {
    @Bindable var hub: PeopleHub
    @Environment(\.skin) private var skin
    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(eyebrow: "People", title: "Contacts & colleagues") {
                if PresenceHub.shared.needsGrant {
                    NButton("Show presence", systemImage: "circle.fill", kind: .ghost) { Task { await PresenceHub.shared.turnOn() } }.fixedSize()
                }
                NButton("New contact", systemImage: "plus", kind: .ghost) { hub.newContact() }.fixedSize().disabled(!hub.isConfigured)
                NIconButton("arrow.clockwise", label: "Refresh") { Task { await hub.load() } }
            }
            if hub.needsConsent {
                consentBar
            }
            if let n = hub.notice {
                HStack { Text(n).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted); Spacer()
                    NIconButton("xmark", label: "Dismiss", size: 20) { hub.notice = nil } }
                    .padding(.horizontal, 14).padding(.vertical, 6).background(skin.soft)
            }
            HStack(spacing: 0) {
                list.frame(width: 320)
                Rectangle().fill(skin.hair).frame(width: 1)
                Group {
                    if let c = hub.card { PersonCardView(card: c, hub: hub) }
                    else { Text("Pick someone to see their card.").font(skin.sans(NV.Size.body)).foregroundStyle(skin.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: Binding(get: { hub.editor.map(EditorBox.init) }, set: { if $0 == nil { hub.editor = nil } })) { box in
            ContactEditorView(editor: box.model, hub: hub)
        }
    }

    private var consentBar: some View {
        HStack(spacing: 10) {
            Text("niivo needs permission to read your Outlook contacts and the directory.").font(skin.sans(NV.Size.bodySm))
            Spacer()
            NButton("Allow access", kind: .primary) { Task { await hub.grantAndLoad() } }.fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 8).background(skin.accentSoft)
    }

    private var list: some View {
        VStack(spacing: 0) {
            NField("Search people", text: $hub.query, label: "Search people", symbol: "magnifyingglass")
                .padding(.horizontal, 12).padding(.vertical, 8)
            HStack(spacing: 6) {
                NField("Open someone's shared contacts (address)", text: $hub.sharedOwnerDraft, label: "Shared contacts",
                       onSubmit: { Task { await hub.addSharedOwner() } })
                NIconButton("person.2.badge.plus", label: "Open shared contacts", size: 22) { Task { await hub.addSharedOwner() } }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            Rectangle().fill(skin.hair).frame(height: 1)
            if hub.loading && hub.people.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(hub.filtered) { p in
                            Button { hub.select(p) } label: { PersonRow(person: p, selected: hub.selectedId == p.id) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct EditorBox: Identifiable { let model: ContactEditorModel; var id: ObjectIdentifier { ObjectIdentifier(model) } }

struct PersonRow: View {
    var person: PersonEntry
    var selected: Bool
    @Environment(\.skin) private var skin
    var body: some View {
        HStack(spacing: 10) {
            Initials(name: person.displayName, size: 28)
                .overlay(alignment: .bottomTrailing) { PresenceDot(address: person.address, size: 8) }
            VStack(alignment: .leading, spacing: 1) {
                Text(person.displayName).font(skin.sans(NV.Size.body, .medium)).foregroundStyle(skin.ink).lineLimit(1)
                Text([person.jobTitle, person.company ?? person.department, person.address].compactMap { $0 }.first ?? "")
                    .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if person.sources.contains(.contact) { NSymbol("person.crop.square", size: 10, label: "Outlook contact").foregroundStyle(skin.muted) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? skin.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct Initials: View {
    var name: String
    var size: CGFloat
    var photo: Data? = nil
    @Environment(\.skin) private var skin
    var body: some View {
        Group {
            if let photo, let img = NSImage(data: photo) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Text(Self.letters(name)).font(skin.sans(size * 0.38, .medium)).foregroundStyle(skin.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(skin.soft)
            }
        }
        .frame(width: size, height: size)
        .clipShape(skin.brand ? AnyShape(Rectangle()) : AnyShape(Circle()))
        .accessibilityHidden(true)
    }
    static func letters(_ n: String) -> String {
        let parts = n.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

struct PersonCardView: View {
    @Bindable var card: PersonCardModel
    var hub: PeopleHub
    @Environment(\.skin) private var skin
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Initials(name: card.entry.displayName, size: 64, photo: card.photo)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(card.directory?.displayName ?? card.entry.displayName).font(skin.sans(20, .medium)).foregroundStyle(skin.ink)
                            PresenceDot(address: card.entry.address, size: 10)
                            if let a = card.entry.address, let p = PresenceHub.shared.values[a.lowercased()] {
                                Text(p.label).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted)
                            }
                        }
                        if let t = card.title { Text(t).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink) }
                        if let d = card.department { Text(d).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted) }
                        if let a = card.entry.address {
                            Link(a, destination: URL(string: "mailto:\(a)")!).font(skin.sans(NV.Size.bodySm))
                        }
                    }
                    Spacer()
                }
                if !card.phones.isEmpty || card.directory?.officeLocation != nil || card.manager != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        NSectionHeader("Contact")
                        ForEach(card.phones, id: \.self) { ph in field("Phone", ph) }
                        if let o = card.directory?.officeLocation { field("Office", o) }
                        if let m = card.manager { field("Manager", [m.displayName, m.jobTitle].compactMap { $0 }.joined(separator: " · ")) }
                    }
                }
                if !card.contacts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        NSectionHeader("Outlook contact")
                        ForEach(card.contacts) { c in
                            HStack {
                                Text(c.owner.map { "\(c.bestName) · shared by \($0)" } ?? c.bestName).font(skin.sans(NV.Size.body))
                                Spacer()
                                if c.owner == nil {
                                    NButton("Edit", kind: .ghost) { hub.edit(c) }.fixedSize()
                                    NButton("Delete", kind: .danger) { Task { await hub.delete(c) } }.fixedSize()
                                }
                            }
                        }
                    }
                } else if let a = card.entry.address {
                    NButton("Add to contacts", systemImage: "person.crop.circle.badge.plus", kind: .ghost) {
                        let parts = card.entry.displayName.split(separator: " ", maxSplits: 1).map(String.init)
                        hub.editor = ContactEditorModel(contact: Contact(givenName: parts.first ?? "", surname: parts.count > 1 ? parts[1] : "",
                                                                          emails: [EmailAddress(name: card.entry.displayName, address: a)],
                                                                          jobTitle: card.title, department: card.department,
                                                                          companyName: card.entry.company), isNew: true)
                    }.fixedSize()
                }
                items("Recent mail", card.mail, empty: "No mail with them on this Mac.")
                items("Meetings this week", card.meetings, empty: "No meetings with them this week.")
            }
            .padding(20)
        }
    }

    private func field(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MonoLabel(k, size: NV.Size.labelSm).frame(width: 70, alignment: .leading)
            Text(v).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).textSelection(.enabled)
        }
    }

    private func items(_ title: String, _ list: [PersonCardModel.Item], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NSectionHeader(title)
            if list.isEmpty { Text(empty).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted) }
            ForEach(list) { i in
                HStack(spacing: 8) {
                    NSymbol(title.hasPrefix("Meet") ? "calendar" : (i.incoming ? "arrow.down.left" : "arrow.up.right"), size: 10,
                            label: title.hasPrefix("Meet") ? "Meeting" : (i.incoming ? "From them" : "To them")).foregroundStyle(skin.muted)
                    Text(i.title).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).lineLimit(1)
                    Spacer()
                    MonoLabel(i.date.formatted(date: .abbreviated, time: .shortened), size: NV.Size.labelSm)
                }
            }
        }
    }
}

struct ContactEditorView: View {
    @Bindable var editor: ContactEditorModel
    var hub: PeopleHub
    @Environment(\.skin) private var skin
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.isNew ? "New contact" : "Edit contact").font(skin.sans(17, .medium))
            HStack { NField("First name", text: $editor.givenName, label: "First name"); NField("Last name", text: $editor.surname, label: "Last name") }
            NField("Email", text: $editor.email, label: "Email")
            HStack { NField("Phone", text: $editor.phone, label: "Phone"); NField("Mobile", text: $editor.mobile, label: "Mobile") }
            NField("Job title", text: $editor.jobTitle, label: "Job title")
            HStack { NField("Company", text: $editor.company, label: "Company"); NField("Department", text: $editor.department, label: "Department") }
            Text("Saved to your Outlook contacts (needs a connection).").font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted)
            HStack {
                Spacer()
                NButton("Cancel", kind: .quiet) { hub.editor = nil }.keyboardShortcut(.cancelAction).fixedSize()
                NButton("Save", kind: .primary) { let e = editor; Task { await hub.save(e) } }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!editor.canSave).fixedSize()
            }
        }
        .padding(20).frame(width: 460)
        .skinned(skin)
    }
}

// MARK: - Tasks window

struct TasksWindowRoot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SecondaryWindow(captureBlocked: false) { TasksScreen(hub: TasksHub.shared) }
            .frame(minWidth: 760, minHeight: 500)
            .task { model.ensurePeopleHubs(); if TasksHub.shared.lists.isEmpty { await TasksHub.shared.load() } }
    }
}

struct TasksScreen: View {
    @Bindable var hub: TasksHub
    @Environment(\.skin) private var skin
    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(eyebrow: "Microsoft To Do", title: hub.selectedList?.displayName ?? "Tasks") {
                NToggle("Completed", isOn: $hub.showCompleted).fixedSize()
                NIconButton("arrow.clockwise", label: "Refresh") { Task { await hub.load() } }
            }
            if hub.needsConsent {
                HStack {
                    Text("niivo needs permission to use Microsoft To Do.").font(skin.sans(NV.Size.bodySm)); Spacer()
                    NButton("Allow access") { Task { await hub.grantAndLoad() } }.fixedSize()
                }.padding(.horizontal, 14).padding(.vertical, 8).background(skin.accentSoft)
            }
            if let n = hub.notice {
                HStack { Text(n).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted); Spacer()
                    NIconButton("xmark", label: "Dismiss", size: 20) { hub.notice = nil } }
                    .padding(.horizontal, 14).padding(.vertical, 6).background(skin.soft)
            }
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(hub.lists) { l in
                            Button { Task { await hub.select(l.id) } } label: {
                                HStack {
                                    NSymbol(l.kind == .flaggedEmails ? "flag" : l.kind == .defaultList ? "house" : "list.bullet", size: 11, label: "")
                                    Text(l.displayName).font(skin.sans(NV.Size.body)).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(hub.selectedListId == l.id ? skin.accentSoft : Color.clear)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 220)
                Rectangle().fill(skin.hair).frame(width: 1)
                VStack(spacing: 0) {
                    if hub.selectedList?.kind == .flaggedEmails {
                        Text("Flagged mail appears here automatically (Exchange). Flag a message to add it.")
                            .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).padding(10)
                    } else if hub.selectedList != nil {
                        NField("Add a task", text: $hub.newTitle, label: "New task", symbol: "plus", onSubmit: { Task { await hub.add() } })
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(hub.visibleTasks) { t in TaskRow(task: t, hub: hub) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct TaskRow: View {
    var task: TodoTask
    var hub: TasksHub
    @Environment(\.skin) private var skin
    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await hub.toggle(task) } } label: {
                NSymbol(task.isCompleted ? "checkmark.circle.fill" : "circle", size: 14,
                        label: task.isCompleted ? "Mark not completed" : "Mark completed")
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(skin.sans(NV.Size.body)).strikethrough(task.isCompleted).foregroundStyle(task.isCompleted ? skin.muted : skin.ink)
                HStack(spacing: 8) {
                    if let d = task.due { MonoLabel("Due \(d.formatted(date: .abbreviated, time: .omitted))", size: NV.Size.labelSm) }
                    if task.isReminderOn, let r = task.reminder { MonoLabel("Reminder \(r.formatted(date: .abbreviated, time: .shortened))", size: NV.Size.labelSm) }
                    if let url = task.linked.first?.webUrl { Link("Open message", destination: url).font(skin.sans(NV.Size.bodySm)) }
                }
            }
            Spacer()
            Menu {
                Button("Due today") { Task { await hub.setDue(task, Date()) } }
                Button("Due tomorrow") { Task { await hub.setDue(task, Calendar.current.date(byAdding: .day, value: 1, to: Date())) } }
                Button("Due next week") { Task { await hub.setDue(task, Calendar.current.date(byAdding: .day, value: 7, to: Date())) } }
                Button("Clear due date") { Task { await hub.setDue(task, nil) } }
                Button("Remind me in 1 hour") { Task { await hub.setReminder(task, Date().addingTimeInterval(3600)) } }
                Button("Remind me tomorrow 09:00") {
                    let d = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                                  of: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
                    Task { await hub.setReminder(task, d) }
                }
                Button("Clear reminder") { Task { await hub.setReminder(task, nil) } }
                Button("Delete task") { Task { await hub.delete(task) } }
            } label: { NSymbol("calendar.badge.clock", size: 12, label: "Dates and reminder") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Due date, reminder, delete")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .opacity(task.id.hasPrefix("pending-") ? 0.6 : 1)
        .hairline(skin)
    }
}
