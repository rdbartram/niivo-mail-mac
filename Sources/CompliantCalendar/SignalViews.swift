import SwiftUI
import AppKit
import CalendarCore
import MailCore

// SIGNAL (docs/SUITE.md step 2; wireframe v0-3): Today in the suite layout. One item at a time ("Now 1 of N"), the Who
// panel, the Queue (with an overview header so the order can be picked) and the action strip: 1 Assign to the
// suggested loop, 2 Other loop, 3 New loop; after assigning, the next item. Today's keys stay (R reply, E done,
// Z snooze, S schedule, D delegate; J/K next/previous). Reuses TodayModel's cards (same plan, same redaction); the
// current item IS the selected message, so Today's actions act on it unchanged. A toggle goes back to the card list.

enum SignalOrder: String, CaseIterable, Hashable { case ranked, person, clients, internalFirst, fyi
    var title: String {
        switch self { case .ranked: "Ranked"; case .person: "By person"; case .clients: "Clients first"; case .internalFirst: "Internal first"; case .fyi: "FYI first" }
    }
}

struct SignalWho: Sendable, Hashable {
    var name: String
    var org: String?
    var known: Int
    var new: Int
    var role: String?
    var isInternal: Bool
    var senderIsNew: Bool
    var loops: Int
    var lastContact: Date?
}

@MainActor @Observable
final class SignalModel {
    static let shared = SignalModel()

    struct Item: Identifiable, Hashable {
        var id: String { card.id }
        var card: TodayModel.Card
        var fyi: Bool
        var isInternal: Bool
    }

    /// Signal (true) or the classic Today card list (false). The toggle stays for the time being.
    var enabled: Bool = UserDefaults.standard.object(forKey: "mail.today.signal") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "mail.today.signal") }
    }
    var order: SignalOrder = .ranked
    private(set) var proposal: LoopProposal?
    private(set) var who: SignalWho?
    private(set) var forConversation: String?
    var pickerOpen = false
    var pickerSearch = ""
    private(set) var pickerLoops: [LoopSummary] = []
    var newOpen = false
    var newTitle = ""

    func reset() { proposal = nil; who = nil; forConversation = nil; pickerOpen = false; newOpen = false; pickerLoops = []; newTitle = "" }

    func isActive(_ mail: MailModel) -> Bool {
        enabled && TodayModel.shared.isActive(mail) && TodayModel.shared.flow == nil && mail.ai.usesConversationTriage
    }

    // MARK: Queue

    func queue(_ mail: MailModel) -> [Item] {
        let t = TodayModel.shared
        let engine = mail.ai.inbox.engine
        func item(_ c: TodayModel.Card, fyi: Bool) -> Item {
            Item(card: c, fyi: fyi, isInternal: engine?.facts(for: c.item.conversationId)?.senderInternal ?? false)
        }
        let needs = t.needs.map { item($0, fyi: false) }, fyi = t.fyi.map { item($0, fyi: true) }
        switch order {
        case .ranked: return needs + fyi
        case .person:
            let groups = Dictionary(grouping: needs, by: { $0.card.text.sender })
            let first = needs.map(\.card.text.sender).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return first.flatMap { groups[$0] ?? [] } + fyi
        case .clients: return needs.filter { !$0.isInternal } + needs.filter(\.isInternal) + fyi
        case .internalFirst: return needs.filter(\.isInternal) + needs.filter { !$0.isInternal } + fyi
        case .fyi: return fyi + needs
        }
    }

    /// Counts for the overview header (content-free).
    func overview(_ q: [Item]) -> (people: Int, clients: Int, internal: Int, fyi: Int) {
        let n = q.filter { !$0.fyi }
        return (Set(n.map(\.card.text.sender)).count, n.filter { !$0.isInternal }.count, n.filter(\.isInternal).count, q.filter(\.fyi).count)
    }

    func current(_ mail: MailModel, _ q: [Item]) -> (Item, Int)? {
        if let i = q.firstIndex(where: { $0.card.messageId == mail.selectedMessageId }) { return (q[i], i) }
        return q.first.map { ($0, 0) }
    }

    func select(_ item: Item, mail: MailModel) {
        if mail.selectedMessageId != item.card.messageId { mail.selectedMessageId = item.card.messageId }
    }

    func step(_ mail: MailModel, forward: Bool) {
        let q = queue(mail)
        guard let (_, i) = current(mail, q), !q.isEmpty else { return }
        let j = forward ? min(q.count - 1, i + 1) : max(0, i - 1)
        select(q[j], mail: mail)
    }

    /// After assigning: the next item (the queue doesn't drop assigned items; they still need an answer).
    private func advance(_ mail: MailModel, from cid: String) {
        let q = queue(mail)
        guard let i = q.firstIndex(where: { $0.card.item.conversationId == cid }) else { return }
        if i + 1 < q.count { select(q[i + 1], mail: mail) }
        else { mail.toast(MailToast(text: L("End of the queue"), symbol: "checkmark")) }
    }

    // MARK: Proposal + Who (detached)

    func load(_ mail: MailModel) async {
        let q = queue(mail)
        guard let (item, _) = current(mail, q) else { proposal = nil; who = nil; forConversation = nil; return }
        // The current item IS the selection: when the selection isn't in the queue (nil, or Today's Done moved it to a
        // Waiting card), select the item shown so the header, 1/2/3 and R/E all mean the same conversation.
        if !q.contains(where: { $0.card.messageId == mail.selectedMessageId }) { select(item, mail: mail) }
        let cid = item.card.item.conversationId
        guard item.card.text.showsDetails, let l = LoopsModel.shared.engine(mail) else {
            proposal = nil; who = nil; forConversation = cid; return   // redacted: no Who, no chip
        }
        await LoopsModel.shared.refresh(mail, heavy: true)
        let sender = mail.ai.inbox.engine?.facts(for: cid)?.senderAddress?.lowercased()
        let (p, w) = await Task.detached(priority: .userInitiated) { () -> (LoopProposal, SignalWho?) in
            (l.propose(conversationId: cid), Self.who(cid, sender: sender, loops: l))
        }.value
        guard current(mail, queue(mail))?.0.card.item.conversationId == cid else { return }
        proposal = p; who = w; forConversation = cid
        newTitle = p.newTitle ?? ""
        if p.best != nil { l.noteProposalShown(cid) }
    }

    nonisolated static func who(_ cid: String, sender: String?, loops l: LoopsEngine) -> SignalWho? {
        let k = l.knowledge
        let v = k.view(.user)
        let owners = k.owners
        var addrs = Set<String>()
        for x in k.conversation(cid, tier: .user) {
            for a in [x.m.from].compactMap({ $0 }) + x.m.toRecipients + x.m.ccRecipients {
                let s = a.address.lowercased(); if !s.isEmpty, !owners.contains(s) { addrs.insert(s) }
            }
        }
        var seen = Set<String>()
        let persons = addrs.sorted().compactMap { v.person(address: $0) }.filter { seen.insert($0.key).inserted }
        guard let p = sender.flatMap({ v.person(address: $0) }) ?? persons.first else { return nil }
        let known = persons.filter { $0.conversations.count > 1 }.count
        let last = p.messageIds.compactMap { k.message($0, tier: .user) }.filter { $0.m.conversationId != cid }.map(\.m.received).max()
        let role = p.roles.first { $0.asserted || $0.userAsserted }?.role.title
        return SignalWho(name: p.name, org: p.org.map(MailDomains.name(fromDomain:)), known: known, new: persons.count - known,
                         role: role, isInternal: p.isInternal, senderIsNew: p.conversations.count <= 1,
                         loops: l.loops(withPeople: p.addresses, includeSuggested: false).count, lastContact: last)
    }

    // MARK: Actions

    func assign(to loopId: String, mail: MailModel) {
        let q = queue(mail)
        guard let (item, _) = current(mail, q), let l = LoopsModel.shared.engine(mail) else { return }
        let cid = item.card.item.conversationId
        let title = (proposal?.best?.loop.id == loopId ? proposal?.best?.loop.title : nil) ?? pickerLoops.first { $0.id == loopId }?.title
        pickerOpen = false
        advance(mail, from: cid)
        mail.toast(MailToast(text: L("Added to %@", title ?? L("loop")), symbol: "circle"))
        LoopsModel.shared.edit(mail) { $0.assign(cid, to: loopId) }
        _ = l
    }

    func assignSuggested(_ mail: MailModel) {
        guard let b = proposal?.best, proposal?.conversationId == current(mail, queue(mail))?.0.card.item.conversationId else { return }
        assign(to: b.loop.id, mail: mail)
    }

    func notThisLoop(_ mail: MailModel) {
        guard let p = proposal, let b = p.best else { return }
        let cid = p.conversationId
        LoopsModel.shared.edit(mail) { $0.notThisLoop(cid, loopId: b.loop.id) }
        Task { try? await Task.sleep(nanoseconds: 300_000_000); await load(mail) }
    }

    func createLoop(_ mail: MailModel) {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let (item, _) = current(mail, queue(mail)) else { return }
        let cid = item.card.item.conversationId
        newOpen = false
        advance(mail, from: cid)
        mail.toast(MailToast(text: L("New loop: %@", t), symbol: "circle"))
        LoopsModel.shared.edit(mail) { _ = $0.createLoop(title: t, conversations: [cid]) }
    }

    func openPicker(_ mail: MailModel) {
        guard let l = LoopsModel.shared.engine(mail) else { return }
        pickerSearch = ""; pickerOpen = true
        Task {
            let ls = await Task.detached { l.loops(includeSuggested: true).filter { $0.state == .open } }.value
            pickerLoops = ls
        }
    }

    func openNew(_ mail: MailModel) {
        newTitle = proposal?.newTitle ?? ""
        newOpen = true
    }

    // MARK: Keys (LOOPS-HOOK from TodayModel.handleKey: list and reader web view)

    /// 1 / 2 / 3 and J / K. Inert while a composer is open or a popover is up (their text fields get the keys).
    func handleKey(_ chars: String, mail: MailModel) -> Bool {
        guard isActive(mail), mail.composer == nil, !pickerOpen, !newOpen else { return false }
        switch chars {
        case "1": assignSuggested(mail); return true
        case "2": openPicker(mail); return true
        case "3": openNew(mail); return true
        case "j": step(mail, forward: true); return true
        case "k": step(mail, forward: false); return true
        default: break
        }
        // FYI items aren't Today cards: handle R / E / Z here and swallow S / D (never fall through to the mail keymap).
        guard let (item, _) = current(mail, queue(mail)), item.fyi else { return false }
        switch chars {
        case "r": mail.reply(.reply, to: item.card.messageId); return true
        case "e":
            let cid = item.card.item.conversationId
            advance(mail, from: cid)
            mail.ai.inbox.engine?.correct(conversationId: cid, to: .done, learn: false)
            mail.ai.inbox.republish(cid)
            mail.toast(MailToast(text: L("Done"), symbol: "checkmark"))
            return true
        case "z": mail.run(.snooze); return true
        case "s", "d": return true
        default: return false
        }
    }
}

// MARK: - Views

/// Full-width Signal (both skins): the Now card on the left, Who / Queue / actions on the right.
struct SignalView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @FocusState private var focused: Bool

    var body: some View {
        let mail = app.mail
        let s = SignalModel.shared
        let _ = mail.visibleRows.count   // re-render with the list reload (the cards come from the same pass)
        let _ = LoopsModel.shared.revision
        let q = s.queue(mail)
        let cur = s.current(mail, q)
        HStack(alignment: .top, spacing: 12) {
            SignalNowCard(item: cur?.0, position: (cur?.1 ?? 0) + 1, total: q.count)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) {
                if let c = cur?.0, c.card.text.showsDetails, s.forConversation == c.card.item.conversationId, let w = s.who {
                    SignalWhoPanel(who: w)
                }
                SignalQueuePanel(queue: q, current: cur?.0).frame(maxHeight: .infinity)
                SignalActionStrip(item: cur?.0)
            }
            .frame(width: 300)
        }
        .padding(12)
        .background(skin.brand ? AnyShapeStyle(skin.ground) : AnyShapeStyle(.background))
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { press in MailKeys.handle(press, mail: mail) }
        .onAppear { focused = true }
        .task(id: mail.selectedMessageId ?? "-") { await s.load(mail) }
        .accessibilityLabel(L("Signal"))
    }
}

struct SignalPanel<Content: View>: View {
    @Environment(\.skin) private var skin
    var content: Content
    init(@ViewBuilder _ c: () -> Content) { content = c() }
    var body: some View {
        content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(skin.brand ? skin.card : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(skin.hair, lineWidth: 0.5))
    }
}

struct SignalNowCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var item: SignalModel.Item?
    var position: Int
    var total: Int
    var body: some View {
        let s = SignalModel.shared
        SignalPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    MonoLabel(L("Now"), wide: true)
                    Spacer()
                    if total > 0 { MonoLabel(L("%lld of %lld", position, total), size: NV.Size.labelSm) }
                    Button(L("List view")) { s.enabled = false }.nvButton(skin, .quiet).help(L("Back to the Today card list"))
                }
                if let item {
                    let t = item.card.text
                    HStack(spacing: 8) {
                        SenderAvatar(who: t.showsDetails ? EmailAddress(name: t.sender, address: "") : nil, size: 24)
                        Text(t.sender).font(skin.sans(NV.Size.body, .medium)).foregroundStyle(skin.ink).lineLimit(1)
                        Spacer()
                        MonoLabel(L(SignalChannel.mail.title).uppercased(), size: NV.Size.labelSm)   // Teams later (SignalChannel)
                    }
                    HStack(spacing: 6) {
                        NChip(item.fyi ? L("FYI") : L("Signal"), tone: item.fyi ? .muted : .ink)
                        if item.card.item.maybe { NChip(L("maybe"), tone: .muted) }
                    }
                    Text(t.line).font(skin.sans(NV.Size.title, .medium)).foregroundStyle(skin.ink).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    ReaderView().frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
                    if t.showsDetails { SignalLoopLine(item: item) }
                } else {
                    BrandEmptyState(symbol: "checkmark.circle", eyebrow: L("Signal"), title: L("Nothing needs you right now."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// Under the card: the suggested loop chip (or the confirmed loop) with its reason.
struct SignalLoopLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var item: SignalModel.Item
    var body: some View {
        let s = SignalModel.shared
        let cid = item.card.item.conversationId
        HStack(spacing: 8) {
            if s.forConversation == cid, let p = s.proposal {
                if let c = p.confirmedLoop {
                    LoopChip(chip: LoopsModel.Chip(id: c.id, title: c.title))
                    Text(L("in this loop")).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted)
                } else if let b = p.best {
                    LoopChip(chip: LoopsModel.Chip(id: b.loop.id, title: b.loop.title))
                    Text(L("suggested loop")).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted)
                    Text(LoopsText.reason(b.reason)).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).lineLimit(1)
                    Button(L("Not this loop")) { s.notThisLoop(app.mail) }.buttonStyle(.link).font(.caption)
                } else {
                    Text(L("No loop suggested: no shared reference, project, file or subject.")).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted)
                }
            }
            Spacer()
        }
    }
}

struct SignalWhoPanel: View {
    @Environment(\.skin) private var skin
    var who: SignalWho
    private var chips: [String] {
        var out: [String] = [who.isInternal ? L("Internal") : L("Client")]
        if let r = who.role { out.append(L(r)) }
        out.append(who.loops == 1 ? L("1 loop with them") : L("%lld loops with them", who.loops))
        if let d = who.lastContact { out.append(L("Last contact %@", Self.relative(d))) } else { out.append(L("No earlier contact")) }
        return out
    }
    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
    var body: some View {
        SignalPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    MonoLabel(L("Who"), wide: true)
                    Spacer()
                    MonoLabel(L("%lld known · %lld new", who.known, who.new), size: NV.Size.labelSm)
                }
                .padding(.horizontal, 8).padding(.vertical, 4).niivoGlassCapsule()   // GLASS: panel header
                if let o = who.org {
                    HStack(spacing: 6) { Image(systemName: "building.2").accessibilityHidden(true); Text(o).font(skin.sans(NV.Size.body, .medium)).lineLimit(1) }
                }
                HStack(spacing: 6) {
                    Circle().strokeBorder(skin.ink, lineWidth: 1).frame(width: 8, height: 8)
                    Text(who.name).font(skin.sans(NV.Size.body, .medium)).lineLimit(1)
                    Text(L("sent this")).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted)
                    if who.senderIsNew { NChip(L("new"), tone: .accent) }
                }
                FlowChips(items: chips)
            }
        }
    }
}

/// Wrapping chips (simple two-row layout: no Layout protocol needed for four short chips).
struct FlowChips: View {
    var items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) { ForEach(Array(items.prefix(2).enumerated()), id: \.offset) { NChip($0.element, tone: .muted) } }
            if items.count > 2 { HStack(spacing: 4) { ForEach(Array(items.dropFirst(2).enumerated()), id: \.offset) { NChip($0.element, tone: .muted) } } }
        }
    }
}

struct SignalQueuePanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var queue: [SignalModel.Item]
    var current: SignalModel.Item?
    var body: some View {
        let s = SignalModel.shared
        @Bindable var model = s
        let o = s.overview(queue)
        SignalPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    MonoLabel(L("Queue"), wide: true)
                    Spacer()
                    MonoLabel("\(queue.count)", size: NV.Size.labelSm)
                }
                // Overview: who is waiting, so the order can be picked (the owner asked for an overview as well).
                Text(L("%lld people · %lld clients · %lld internal · %lld FYI", o.people, o.clients, o.internal, o.fyi))
                    .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted)
                Picker(L("Order"), selection: $model.order) {
                    ForEach(SignalOrder.allCases, id: \.self) { Text(L($0.title)).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(queue) { i in
                            let on = i.id == current?.id
                            Button { s.select(i, mail: app.mail) } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(i.fyi ? Color.clear : skin.ink).overlay(Circle().strokeBorder(skin.ink, lineWidth: 1)).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(i.card.text.sender).font(skin.sans(NV.Size.bodySm, .medium)).foregroundStyle(skin.ink).lineLimit(1)
                                        Text(i.card.text.line).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if i.card.text.showsDetails, let c = LoopsModel.shared.confirmed[i.card.item.conversationId] { LoopChip(chip: c, compact: true) }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(skin.brand ? skin.ground : Color(nsColor: .windowBackgroundColor)))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? skin.ink : Color.clear, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(i.card.text.sender), \(i.card.text.line)")
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }
}

struct SignalActionStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var item: SignalModel.Item?
    var body: some View {
        let s = SignalModel.shared
        @Bindable var model = s
        let mail = app.mail
        let cid = item?.card.item.conversationId
        let p = s.forConversation == cid ? s.proposal : nil
        let details = item?.card.text.showsDetails ?? false
        SignalPanel {
            VStack(spacing: 6) {
                key(p?.best.map { L("Assign to %@", $0.loop.title ?? L("suggested loop")) } ?? L("No suggested loop"), "1", primary: true,
                    enabled: details && p?.best != nil) { s.assignSuggested(mail) }
                HStack(spacing: 6) {
                    key(L("Other loop"), "2", enabled: details && item != nil) { s.openPicker(mail) }
                        .popover(isPresented: $model.pickerOpen) { LoopPicker() }
                    key(L("New loop"), "3", enabled: details && item != nil) { s.openNew(mail) }
                        .popover(isPresented: $model.newOpen) { NewLoopField() }
                }
                Text(L("R reply · E done · Z snooze · S schedule · D delegate · J/K next/previous"))
                    .font(skin.sans(NV.Size.labelSm)).foregroundStyle(skin.muted).lineLimit(2)
            }
        }
    }

    @ViewBuilder private func key(_ title: String, _ k: String, primary: Bool = false, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(skin.sans(NV.Size.bodySm, .medium)).lineLimit(1)
                Spacer(minLength: 4)
                NiivoKeyCap(key: k)
            }
        }
        .buttonStyle(NiivoGlassKeyStyle(primary: primary)).disabled(!enabled)   // GLASS: action strip keys (NiivoGlass.swift)
        .help(L("%@ (%@)", title, k))
    }
}

/// "Other loop": search over open loops (suggested ones included, marked).
struct LoopPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let s = SignalModel.shared
        @Bindable var model = s
        let q = s.pickerSearch.lowercased()
        let ls = s.pickerLoops.filter { q.isEmpty || ($0.title ?? "").lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Search loops"), text: $model.pickerSearch).textFieldStyle(.roundedBorder)
                .onSubmit { if let f = ls.first { s.assign(to: f.id, mail: app.mail) } }
            if ls.isEmpty { Text(L("No open loops match.")).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ls.prefix(40)) { l in
                        Button { s.assign(to: l.id, mail: app.mail) } label: {
                            HStack {
                                Text(l.title ?? L("Loop")).lineLimit(1)
                                if !l.confirmed { NChip(L("suggested"), tone: .muted) }
                                Spacer()
                                Text(L("%lld conversations", l.conversationCount)).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12).frame(width: 320)
    }
}

/// "New loop": the prefilled title (only when the subject may be kept offline), editable.
struct NewLoopField: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let s = SignalModel.shared
        @Bindable var model = s
        VStack(alignment: .leading, spacing: 8) {
            Text(L("New loop")).font(.headline)
            TextField(L("Loop title"), text: $model.newTitle).textFieldStyle(.roundedBorder).onSubmit { s.createLoop(app.mail) }
            HStack {
                Spacer()
                Button(L("Cancel")) { s.newOpen = false }
                Button(L("Create")) { s.createLoop(app.mail) }.keyboardShortcut(.defaultAction)
                    .disabled(s.newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12).frame(width: 300)
    }
}
