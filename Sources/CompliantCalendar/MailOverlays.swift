import SwiftUI
import MailCore

/// ⌘K: fuzzy list of actions, folders and "go to".
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @FocusState private var focused: Bool

    var body: some View {
        let mail = app.mail
        @Bindable var m = mail
        let items = Array(mail.paletteItems.prefix(40))
        let sel = min(mail.paletteIndex, max(0, items.count - 1))
        VStack(spacing: 0) {
            HStack {
                if skin.brand { MonoLabel("⌘K", color: skin.ink, weight: .medium) }
                else { Image(systemName: "command").foregroundStyle(.secondary) }
                Button("") { app.mail.showPalette = false; app.mail.focusListToken += 1 }
                    .keyboardShortcut(.cancelAction).frame(width: 0).opacity(0)
                TextField("Type a command or folder…", text: $m.paletteQuery)
                    .textFieldStyle(.plain).font(skin.brand ? skin.sans(NV.Size.bodyLg) : .title3)
                    .focused($focused)
                    .onSubmit { if items.indices.contains(sel) { pick(items[sel]) } }
                    .onKeyPress(.downArrow) { mail.paletteIndex = min(sel + 1, items.count - 1); return .handled }
                    .onKeyPress(.upArrow) { mail.paletteIndex = max(sel - 1, 0); return .handled }
            }
            .padding(14)
            .hairline(skin)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                            HStack {
                                NSymbol(it.symbol, size: 13).fontWeight(skin.brand ? .light : nil).frame(width: 22)
                                Text(it.title).font(skin.brand ? skin.sans(NV.Size.body) : .body)
                                Spacer()
                                Text(skin.caps(it.subtitle)).font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption)
                                    .tracking(skin.track(NV.Size.labelSm)).foregroundStyle(.secondary)
                                if skin.brand { Text("→").font(skin.mono(NV.Size.label)).foregroundStyle(i == sel ? skin.ink : .clear) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(i == sel ? (skin.brand ? skin.accentSoft : Color.accentColor.opacity(0.18)) : .clear)
                            .overlay(alignment: .leading) { if skin.brand && i == sel { Rectangle().fill(skin.accentFill).frame(width: 3) } }
                            .accessibilityAddTraits(i == sel ? .isSelected : [])
                            .contentShape(Rectangle())
                            .onTapGesture { pick(it) }
                            .id(it.id)
                        }
                    }
                }
                .onChange(of: sel) { _, s in if items.indices.contains(s) { proxy.scrollTo(items[s].id) } }
            }
            .frame(height: 340)
        }
        .frame(width: 540)
        .background(skin.brand ? skin.card : .clear)
        .onAppear { focused = true }
        .onExitCommand { mail.showPalette = false }
    }

    private func pick(_ it: MailModel.PaletteItem) {
        if app.mail.runPalette(it) == "calendar" { app.section = .calendar }
    }
}

/// ⌘/ — every shortcut, grouped.
struct CheatSheetView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                if skin.brand {
                    VStack(alignment: .leading, spacing: 6) {
                        MonoLabel("⌘/ — Shortcuts", bracket: true)
                        Text("Every key, one place.").font(skin.sans(NV.Size.title)).tracking(skin.titleTrack(NV.Size.title))
                    }
                } else {
                    Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                }
                Spacer()
                Button("Done") { app.mail.showCheatSheet = false }.keyboardShortcut(.cancelAction).nvButton(skin, .ghost)
            }
            HStack(alignment: .top, spacing: 28) {
                ForEach(Array(MailKeymap.groups.enumerated()), id: \.element.title) { gi, g in
                    VStack(alignment: .leading, spacing: 6) {
                        if skin.brand {
                            HStack(spacing: 6) {
                                MonoLabel(String(format: "%02d", gi + 1), color: skin.accentInk)
                                MonoLabel(g.title, color: skin.ink, wide: true, weight: .medium)
                            }
                            .padding(.bottom, 4).frame(maxWidth: .infinity, alignment: .leading).hairline(skin)
                        } else {
                            Text(g.title).font(.headline)
                        }
                        ForEach(g.commands) { c in
                            HStack {
                                Text(c.title).font(skin.brand ? skin.sans(NV.Size.body) : .body)
                                Spacer(minLength: 16)
                                if skin.brand {
                                    Text(c.hint).font(skin.mono(11, .medium)).padding(.horizontal, 6).padding(.vertical, 1)
                                        .overlay(Rectangle().strokeBorder(skin.hair2, lineWidth: 1))
                                } else {
                                    Text(c.hint).font(.callout.monospaced()).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                    .frame(minWidth: 190)
                }
            }
            if app.mail.ai.enabled { AICheatSheetSection() }   // AI-HOOK
            if MailListUI.shared.keymap == .gmail {   // THREAD-HOOK: Gmail shortcuts
                Text("Gmail shortcuts: J / K conversations · N / P messages in the conversation · O or ↩ expand · X select · U back to the list · E archive · # delete · R / A / F reply, reply all, forward")
                    .font(skin.brand ? skin.sans(NV.Size.bodySm) : .callout)
            }
            Text("Mail ⌃⌘1 · Calendar ⌃⌘2 · New message ⌘N · Send ⌘↩ · Find ⌘F. Letter keys work when the message list or reader has focus.")
                .font(skin.brand ? skin.sans(NV.Size.bodySm) : .caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(skin.brand ? skin.card : .clear)
    }
}

struct SnoozePickerView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail
        @Bindable var m = mail
        VStack(alignment: .leading, spacing: 10) {
            if app.theme.brand { MonoLabel("Snooze until", color: app.skin.ink, bracket: true) } else { Text("Snooze until…").font(.headline) }
            ForEach(TimePreset.snooze) { p in
                Button { mail.snooze(until: p.date()) } label: {
                    HStack { Text(p.title); Spacer(); Text(p.date().formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.vertical, 4)
            }
            Divider()
            DatePicker("Custom", selection: $m.snoozeCustom, in: Date()...)
            HStack {
                Text("Snooze is client-side: it comes back while Mail is open on this Mac (or the next time it is opened).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { mail.showSnooze = false; mail.focusListToken += 1 }.keyboardShortcut(.cancelAction)
                Button("Snooze") { mail.snooze(until: mail.snoozeCustom) }.keyboardShortcut(.defaultAction).nvButton(app.skin, .primary)
            }
        }
        .padding(20).frame(width: 440)
    }
}

struct CategoryPickerView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mail = app.mail
        // BULK: with a multi-selection a category is "on" when every selected message has it; toggling adds/removes it on all.
        let ids = MailChrome.shared.targets(mail)
        let bulk = ids.count > 1
        let msgs = mail.visibleRows.filter { ids.contains($0.id) }.map(\.message)
        let current: Set<String> = bulk ? Set(mail.knownCategories.filter { c in msgs.allSatisfy { $0.categories.contains(c) } })
                                        : Set(mail.selectedRow?.message.categories ?? [])
        VStack(alignment: .leading, spacing: 8) {
            if app.theme.brand { MonoLabel(bulk ? "Categories · \(ids.count) messages" : "Categories", color: app.skin.ink, bracket: true) }
            else { Text(bulk ? "Categories (\(ids.count) messages)" : "Categories").font(.headline) }
            Text("Sensitivity labels on received mail are set by the sender and can't be changed here.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(mail.knownCategories, id: \.self) { cat in
                Button {
                    if bulk { mail.applyBulk(current.contains(cat) ? .removeCategory(cat) : .addCategory(cat), ids: ids); return }
                    var s = current
                    if s.contains(cat) { s.remove(cat) } else { s.insert(cat) }
                    mail.setCategories(s.sorted())
                } label: {
                    HStack {
                        NSymbol(current.contains(cat) ? "checkmark.circle.fill" : "circle", size: 13,
                                label: current.contains(cat) ? "Selected" : "Not selected")
                        Circle().fill(CategoryDots.color(cat)).frame(width: 9, height: 9)
                        Text(cat)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.vertical, 2)
            }
            HStack { Spacer(); Button("Done") { mail.showCategories = false; mail.focusListToken += 1 }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 340)
    }
}
