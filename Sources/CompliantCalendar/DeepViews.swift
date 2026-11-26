import SwiftUI
import CalendarCore
import MailCore

// DEEP (wireframe v0-5): a focused block on one work item. The item in focus, the loop's items in a drawer (work items
// to switch to; reference: conversations, promises, files, reusing the loop page rows), the "done when" checklist, a
// block timer (start / pause, remaining time, overrun shown calmly) and the numbered actions: 1 Done → next item,
// 2 Need more time (back to When), 3 Park. Space starts / pauses, I opens the drawer. When every item of the loop is
// done it offers (never forces) closing the loop. Mounted as a window ("deep", ⌃⌘7) and by the Desk shell.

/// DEEP-HOOK: the Deep surface. Needs `AppModel` in the environment; `itemId` picks the work item.
struct DeepSurface: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Bool
    var itemId: String?
    init(itemId: String? = nil) { self.itemId = itemId }

    var body: some View {
        let m = WorkModel.shared
        let _ = m.revision
        Group {
            if app.trust.hidesContent || !app.mail.started {
                Text(L("Unlock to work.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    if m.drawerOpen { DeepDrawer().frame(width: 260) }
                    DeepItemCard().frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 12) {
                        DeepTimerCard()
                        DeepDoneWhenCard()
                        Spacer(minLength: 0)
                        if m.offerCloseLoop != nil { DeepCloseLoopCard() }
                        DeepActionStrip()
                    }
                    .frame(width: 280)
                }
                .padding(12)
            }
        }
        .background(skin.brand ? AnyShapeStyle(skin.ground) : AnyShapeStyle(.background))
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { focused = true }
        .task(id: itemId ?? "-") { await m.loadDeep(app, prefer: itemId) }
        .accessibilityLabel(L("Deep"))
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let m = WorkModel.shared
        guard press.modifiers.subtracting(.shift).isEmpty, m.deepItem != nil, !WorkKeys.typing else { return .ignored }
        if press.key == .space { m.startPause(app); return .handled }
        switch press.characters.lowercased() {
        case "1": m.doneNext(app)
        case "2": m.needMoreTime(app, openWindow: openWindow)
        case "3": m.park(app)
        case "i": m.drawerOpen.toggle()
        default: return .ignored
        }
        return .handled
    }
}

struct DeepItemCard: View {
    @Environment(\.skin) private var skin
    var body: some View {
        let m = WorkModel.shared
        SignalPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    MonoLabel(L("Deep"), wide: true)
                    Spacer()
                    if let t = m.deepLoop?.summary.title { MonoLabel(t, size: NV.Size.labelSm) }
                    Button(m.drawerOpen ? L("Hide items") : L("Items · %lld", m.deepItems.count + (m.deepLoop?.members.count ?? 0))) { m.drawerOpen.toggle() }
                        .niivoGlassButton(skin).help(L("Loop items (I)"))   // GLASS: drawer toggle (control)
                }
                if let x = m.deepItem {
                    Text(x.title ?? L("Work item")).font(skin.sans(NV.Size.title, .medium)).foregroundStyle(skin.ink).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("Work item · %@", L(x.kind.tag).lowercased())).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted)
                    HStack(spacing: 6) {
                        NChip(L(x.state == .inProgress ? "In progress" : x.state == .scheduled ? "Scheduled" : x.state == .done ? "Done" : "Open"), tone: .ink)
                        if let s = x.slot { NChip(WhenText.slot(s.interval), tone: .muted) }
                        if let d = x.due { NChip(WhenText.due(d), tone: d < Date() ? .danger : .muted) }
                    }
                    if x.kind == .reply || x.kind == .promise {
                        Text(L("The conversation is in the drawer (I). Replying ticks nothing by itself: tick \u{201C}done when\u{201D} as you go."))
                            .font(.caption).foregroundStyle(skin.muted)
                    }
                    Spacer(minLength: 0)
                    Text(L("The timer keeps running while you work elsewhere.")).font(.caption2).foregroundStyle(skin.muted)
                } else {
                    BrandEmptyState(symbol: "checkmark.circle", eyebrow: L("Deep"), title: L("Nothing planned right now."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

struct DeepTimerCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = WorkModel.shared
        SignalPanel {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let total = TimeInterval(m.blockMinutes * 60)
                let left = total - m.elapsed
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        MonoLabel(L("Block · %@", WhenText.minutes(m.blockMinutes)), wide: true)
                        Spacer()
                        if let end = m.deepItem?.slot?.end { MonoLabel(L("ends %@", end.formatted(date: .omitted, time: .shortened)), size: NV.Size.labelSm) }
                    }
                    Text(Self.clock(abs(left))).font(skin.mono(30, .medium)).foregroundStyle(skin.ink).monospacedDigit()
                        .accessibilityLabel(left >= 0 ? L("%@ left", Self.clock(left)) : L("%@ over", Self.clock(-left)))
                    ProgressView(value: min(1, max(0, m.elapsed / max(1, total)))).tint(skin.ink)
                    if left < 0 { Text(L("%@ over. Fine: finish the thought, or take more time (2).", WhenText.minutes(Int(-left / 60)))).font(.caption).foregroundStyle(skin.muted) }
                    HStack(spacing: 6) {
                        WorkKey(title: m.isRunning ? L("Pause") : (m.elapsed > 0 ? L("Resume") : L("Start")), key: "space", enabled: m.deepItem != nil) { m.startPause(app) }
                    }
                }
            }
        }
    }
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down)); return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct DeepDoneWhenCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = WorkModel.shared
        @Bindable var model = m
        SignalPanel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    MonoLabel(L("Done when"), wide: true)
                    Spacer()
                    if let x = m.deepItem { MonoLabel(L("%lld of %lld", x.criteriaDone, x.criteria.count), size: NV.Size.labelSm) }
                }
                if let x = m.deepItem {
                    ForEach(x.criteria) { c in
                        HStack(spacing: 6) {
                            Button { let id = x.id, cid = c.id; m.edit(app) { $0.toggleCriterion(id, cid) } } label: {
                                Image(systemName: c.done ? "checkmark.circle.fill" : "circle").foregroundStyle(skin.ink)
                            }
                            .buttonStyle(.plain).accessibilityLabel(c.done ? L("Untick %@", c.text) : L("Tick %@", c.text))
                            Text(L(c.text)).font(skin.sans(NV.Size.bodySm)).foregroundStyle(c.done ? skin.muted : skin.ink).strikethrough(c.done).lineLimit(2)
                            Spacer()
                            Button { let id = x.id, cid = c.id; m.edit(app) { $0.removeCriterion(id, cid) } } label: { Image(systemName: "xmark").font(.caption2) }
                                .buttonStyle(.plain).foregroundStyle(skin.muted).accessibilityLabel(L("Remove"))
                        }
                    }
                    TextField(L("Add a criterion"), text: $model.newCriterion).textFieldStyle(.plain).font(skin.sans(NV.Size.bodySm))
                        .onSubmit {
                            let t = m.newCriterion; m.newCriterion = ""
                            let id = x.id; m.edit(app) { $0.addCriterion(id, t) }
                        }
                        .accessibilityLabel(L("Add a criterion"))
                }
            }
        }
    }
}

struct DeepActionStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let m = WorkModel.shared
        let has = m.deepItem != nil
        SignalPanel {
            VStack(spacing: 6) {
                WorkKey(title: L("Done, next item"), key: "1", primary: true, enabled: has) { m.doneNext(app) }
                HStack(spacing: 6) {
                    WorkKey(title: L("More time"), key: "2", enabled: has) { m.needMoreTime(app, openWindow: openWindow) }
                    WorkKey(title: L("Park"), key: "3", enabled: has) { m.park(app) }
                }
            }
        }
    }
}

/// Every item of the loop is done: offer to close the loop (the user decides).
struct DeepCloseLoopCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = WorkModel.shared
        SignalPanel {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Every item of this loop is done.")).font(skin.sans(NV.Size.body, .medium)).foregroundStyle(skin.ink)
                HStack(spacing: 6) {
                    NButton(L("Close the loop"), kind: .primary) { m.closeLoop(app) }
                    NButton(L("Keep it open"), kind: .quiet) { m.offerCloseLoop = nil }
                }
            }
        }
    }
}

/// Loop items: work items to switch to, then reference (conversations, promises, files) with the loop page's rows.
struct DeepDrawer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = WorkModel.shared
        SignalPanel {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { MonoLabel(L("Loop items"), wide: true); Spacer(); MonoLabel("\(m.deepItems.count + (m.deepLoop?.members.count ?? 0))", size: NV.Size.labelSm) }
                    MonoLabel(L("Work on"), size: NV.Size.labelSm)
                    ForEach(m.deepItems) { x in
                        Button { m.deepItemId = x.id; Task { await m.loadDeep(app, prefer: x.id) } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: x.state == .done ? "checkmark.circle.fill" : x.state == .inProgress ? "circle.lefthalf.filled" : "circle")
                                    .font(.caption).accessibilityHidden(true)
                                Text(x.title ?? L("Work item")).font(skin.sans(NV.Size.bodySm)).lineLimit(1).strikethrough(x.state == .done)
                                Spacer()
                                MonoLabel(L(x.kind.tag).uppercased(), size: NV.Size.labelSm)
                            }
                            .foregroundStyle(skin.ink).padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(x.id == m.deepItemId ? skin.ink : Color.clear, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(x.state == .done)
                    }
                    if let d = m.deepLoop {
                        MonoLabel(L("Reference"), size: NV.Size.labelSm)
                        ForEach(d.members) { mem in LoopMemberRow(member: mem, loopId: d.summary.id, removable: false) }
                        ForEach(d.promises) { p in
                            HStack { Image(systemName: "checkmark.circle").accessibilityHidden(true); Text(p.title).lineLimit(1); Spacer() }.font(.caption)
                        }
                        if !d.files.isEmpty { KnowledgeFileLines(files: Array(d.files.prefix(12))) }
                    }
                }
            }
        }
    }
}

struct DeepWindowRoot: View {
    var body: some View { DeepSurface().frame(minWidth: 860, minHeight: 520) }
}
