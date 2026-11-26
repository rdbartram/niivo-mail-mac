import SwiftUI
import AppKit
import CalendarCore
import MailCore

// TODAY (docs/RETHINK.md §4): a virtual folder beside the Inbox. Cards come from one plan snapshot (MailCore Today.swift)
// over the conversation triage state; actions always name an explicit message id. Flow mode works through
// "Needs you" one conversation at a time. Logs: `[Today] needs=… waiting=… fyi=… shown=…` (counts only).

@MainActor @Observable
final class TodayModel {
    static let shared = TodayModel()

    struct Card: Identifiable, Hashable {
        var id: String { item.conversationId }
        var item: TodayItem
        var messageId: String
        var text: TodayCardText
        var age: String
    }

    var openAtLaunch: Bool = UserDefaults.standard.bool(forKey: "mail.today.openAtLaunch") {
        didSet { UserDefaults.standard.set(openAtLaunch, forKey: "mail.today.openAtLaunch") }
    }
    private(set) var plan = TodayPlan()
    private(set) var needs: [Card] = []
    private(set) var waiting: [Card] = []
    private(set) var fyi: [Card] = []
    var fyiExpanded = false
    /// Flow mode (nil = off).
    var flow: TodayFlow?
    /// TODAY-HOOK: the promises ledger (another builder). nil → the section stays an empty placeholder.
    @ObservationIgnored var promises: PromiseSource?
    @ObservationIgnored private var lastDiag = ""
    @ObservationIgnored private var launched = false

    static let folderId = VirtualFolder.today.id
    func isActive(_ mail: MailModel) -> Bool { mail.selectedFolderId == Self.folderId }

    /// After the first mail open: "Open Today at launch".
    func launch(_ mail: MailModel) {
        guard !launched else { return }
        launched = true
        if openAtLaunch, mail.ai.usesConversationTriage { mail.selectedFolderId = Self.folderId }
    }

    // MARK: Plan (called from MailModel.virtualPage: the list rows are the cards' messages)

    func rows(mail: MailModel) -> [MailMessage] {
        rebuild(mail)
        let ids = needs.map(\.messageId) + waiting.map(\.messageId)
        guard let store = mail.store else { return [] }
        return ids.compactMap { try? store.message(id: $0, includeBody: false) }
    }

    /// Decisions republished (InboxTriageModel): refresh the cards while Today is open.
    func triageChanged(_ mail: MailModel) {
        if isActive(mail) { mail.reloadList() }
        Task { await LoopsModel.shared.refresh(mail) }   // LOOPS-HOOK: row chips (throttled, detached)
    }

    private func rebuild(_ mail: MailModel) {
        guard let store = mail.store, let engine = mail.ai.inbox.engine, mail.ai.usesConversationTriage,
              !(mail.ai.app?.trust.hidesContent ?? false) else {
            plan = TodayPlan(); needs = []; waiting = []; fyi = []; return
        }
        let now = Date()
        let favPeople = Set(MailOrg2.shared.favourites.items.compactMap { i -> String? in
            if case .person(let a, _) = i { a.lowercased() } else { nil } })
        var inputs: [TodayInput] = []
        for (cid, d) in mail.ai.inbox.decisions {
            let f = engine.facts(for: cid)
            let addr = f?.senderAddress?.lowercased()
            let vip = addr.map { MailOrg2.shared.isVIP($0) || favPeople.contains($0) } ?? false
            inputs.append(TodayInput(conversationId: cid, decision: d, signals: TodaySignals.from(f, decision: d, vip: vip, now: now)))
        }
        plan = TodayPlanner.plan(inputs, now: now)
        func card(_ i: TodayItem) -> Card? {
            guard let f = engine.facts(for: i.conversationId),
                  let m = try? store.message(id: f.latestMessageId, includeBody: false) else { return nil }
            // The conversation's strictest policy, as the list's thread row.
            let members = (try? store.conversation(id: i.conversationId, limit: 50)) ?? [m]
            let p = members.reduce(mail.policy(for: m, mailbox: store.mailbox(forFolder: m.folderId))) {
                $0.merged(with: mail.policy(for: $1, mailbox: store.mailbox(forFolder: $1.folderId)))
            }
            let sender = i.section == .waiting ? m.toRecipients.first?.display ?? m.toRecipients.first?.address : (m.from?.display.isEmpty == false ? m.from?.display : m.from?.address)
            let text = TodayCardText.make(sender: sender, subject: m.subject, ask: i.decision.ask,
                                          redactDetails: p.redactDetails,
                                          allowOfflineDetails: p.allowOfflineDetails && !i.decision.restricted)
            let age = i.ageDays == 0 ? L("Today") : L("%lld d", i.ageDays)
            return Card(item: i, messageId: m.id, text: text, age: age)
        }
        needs = plan.needsYou.compactMap(card)
        waiting = plan.waiting.compactMap(card)
        fyi = plan.fyi.compactMap(card)
        if plan.diagnostic != lastDiag {
            lastDiag = plan.diagnostic
            FileHandle.standardError.write(Data((plan.diagnostic + "\n").utf8))
        }
    }

    func card(messageId: String?) -> Card? {
        guard let messageId else { return nil }
        return (needs + waiting).first { $0.messageId == messageId }
    }

    func card(conversationId: String?) -> Card? {
        guard let conversationId else { return nil }
        return (needs + waiting + fyi).first { $0.item.conversationId == conversationId }
    }

    // MARK: Actions (explicit message ids)

    enum Action: String { case reply, schedule, delegate, done, snooze, nudge }

    func perform(_ a: Action, _ c: Card, app: AppModel) {
        let mail = app.mail
        if mail.selectedMessageId != c.messageId { mail.selectedMessageId = c.messageId }
        switch a {
        case .reply:
            mail.reply(.reply, to: c.messageId)
            if mail.composer?.original?.id == c.messageId, canDraft(mail, messageId: c.messageId) { mail.ai.draft() }
        case .schedule:
            // No per-thread "Find a time" exists yet: Reply with meeting (its editor carries Find a time).
            app.replyWithMeeting(messageId: c.messageId)
        case .delegate:
            // The forward opens with the cursor above the history for the instruction. No canned text: a prefilled
            // line would count as user content and leave a stray draft when moving on.
            mail.reply(.forward, to: c.messageId)
        case .nudge:
            mail.reply(.replyAll, to: c.messageId)   // my last message: reply-all goes back to its recipients
        case .done: done(c, mail: mail)
        case .snooze: mail.run(.snooze)
        }
        // Flow moves on after Done and Schedule; replies stay on the item (composer underneath), and Snooze waits for its
        // picker (it acts on the selection), so J moves on.
        if flow != nil, a == .done || a == .schedule { flowHandled(mail) } else if flow != nil { flow?.handleCurrent(advance: false) }
    }

    /// E: the conversation is done (a "handled" mark, not a correction: no sender learning) and every Inbox member is
    /// archived in one step; one undo restores the moves and the state. Waiting cards (my own last message, in Sent)
    /// only get the state mark: nothing of mine moves.
    private func done(_ c: Card, mail: MailModel) {
        let cid = c.item.conversationId
        mail.ai.inbox.engine?.correct(conversationId: cid, to: .done, learn: false)
        mail.ai.inbox.republish(cid)
        let after: @MainActor () -> Void = { [weak mail] in mail?.ai.inbox.clearOverrideById(cid) }
        var steps: [BulkStep] = [], inverses: [BulkStep] = []
        if c.item.section != .waiting, let store = mail.store {
            let members = ((try? store.conversation(id: cid, limit: 200)) ?? []).filter { m in
                !m.isDraft && ((try? store.folder(id: m.folderId)) ?? nil)?.wellKnown == .inbox
            }
            for m in members {
                guard let arch = ((try? store.folder(wellKnown: .archive, mailbox: store.mailbox(forFolder: m.folderId))) ?? nil) else { continue }
                let a = MailAction.move(toFolderId: arch.id)
                steps.append(BulkStep(messageId: m.id, action: a))
                if let inv = TriageUndo.inverse(of: a, before: m) { inverses.append(BulkStep(messageId: m.id, action: inv)) }
            }
        }
        // The selection moves to the next card first (the list drops this one).
        let order = (needs + waiting).map(\.messageId)
        if let i = order.firstIndex(of: c.messageId) {
            mail.selectedMessageId = order.dropFirst(i + 1).first ?? (i > 0 ? order[i - 1] : nil)
        }
        mail.dropRows(Set(steps.map(\.messageId)))
        mail.pushUndo(MailModel.UndoEntry(steps: inverses, text: L("Done"), after: after))
        mail.toast(MailToast(text: L("Done"), symbol: "checkmark", action: .undoTriage))
        if !steps.isEmpty, let sync = mail.sync {
            Task { @MainActor [weak mail] in
                let r = await sync.apply(steps)
                if r.failed > 0 { mail?.toast(MailToast(text: L("Couldn't apply that change"), symbol: "exclamationmark.triangle", isError: true)) }
            }
        }
        mail.reloadList()
    }

    /// FYI digest: every item marked done (state only, nothing moves; no sender learning).
    func markAllFYIDone(_ mail: MailModel) {
        guard let e = mail.ai.inbox.engine else { return }
        for c in fyi { e.correct(conversationId: c.item.conversationId, to: .done, learn: false) }
        mail.ai.inbox.republish()
        mail.toast(MailToast(text: L("Marked %lld as done", fyi.count), symbol: "checkmark"))
        mail.reloadList()
    }

    private func canDraft(_ mail: MailModel, messageId: String) -> Bool {
        guard mail.ai.enabled, let a = mail.ai.assistant, let route = a.route(.draftReply), let store = mail.store,
              let m = try? store.message(id: messageId, includeBody: false) else { return false }
        return a.gate.exposure(m, mailbox: store.mailbox(forFolder: m.folderId), tier: route.tier) == .content
    }

    // MARK: Keys (TODAY-HOOK from MailKeys: list, reader web view)

    /// Bare R/S/D/E/Z on the focused (selected) card; in Flow also J/K/Esc. Returns true when handled.
    func handleKey(_ chars: String, escape: Bool = false, mail: MailModel) -> Bool {
        guard isActive(mail), let app = mail.ai.app else { return false }
        if SignalModel.shared.handleKey(chars, mail: mail) { return true }   // LOOPS-HOOK: Signal 1/2/3, J/K
        if flow != nil {
            if escape { exitFlow(); return true }
            switch chars {
            case "j": flowStep(mail, forward: true); return true
            case "k": flowStep(mail, forward: false); return true
            default: break
            }
        }
        guard let c = card(messageId: mail.selectedMessageId) else { return false }
        if c.item.section == .waiting {   // my own last message: Nudge or Done; nothing else may act on it
            switch chars {
            case "r": perform(.nudge, c, app: app); return true
            case "e": perform(.done, c, app: app); return true
            case "s", "d", "z": return true
            default: return false
            }
        }
        switch chars {
        case "r": perform(.reply, c, app: app)
        case "s": perform(.schedule, c, app: app)
        case "d": perform(.delegate, c, app: app)
        case "e": perform(.done, c, app: app)
        case "z": perform(.snooze, c, app: app)
        default: return false
        }
        return true
    }

    // MARK: Flow

    func startFlow(_ mail: MailModel) {
        guard isActive(mail) else { return }
        let ids = needs.map(\.item.conversationId)
        flow = TodayFlow(items: ids, start: card(messageId: mail.selectedMessageId)?.item.conversationId)
        showFlowCurrent(mail)
    }

    func exitFlow() { flow = nil }

    func flowStep(_ mail: MailModel, forward: Bool) {
        if forward { flow?.next() } else { flow?.previous() }
        showFlowCurrent(mail)
    }

    private func flowHandled(_ mail: MailModel) {
        flow?.handleCurrent()
        showFlowCurrent(mail)
    }

    /// The Flow item's message in the reader (set after any action, which moves the list selection itself).
    func showFlowCurrent(_ mail: MailModel) {
        guard let f = flow, let cid = f.current, let store = mail.store else { return }
        let mid = card(conversationId: cid)?.messageId ?? mail.ai.inbox.engine?.facts(for: cid)?.latestMessageId
        guard let mid, (try? store.message(id: mid, includeBody: false)) != nil else { return }
        if mail.selectedMessageId != mid { mail.selectedMessageId = mid }
    }
}

// MARK: - Bridges (TODAY-HOOK)

extension InboxTriageModel {
    func clearOverrideById(_ cid: String) {
        engine?.clearOverride(conversationId: cid)
        republish(cid)
    }
}

// MARK: - Views

/// Sidebar row (both skins call this; classic via a tagged List row).
struct TodaySidebarRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let mail = app.mail
        if mail.ai.usesConversationTriage {
            let selected = TodayModel.shared.isActive(mail)
            Button { mail.selectedFolderId = TodayModel.folderId; mail.focusListToken += 1 } label: {
                HStack(spacing: 9) {
                    NSymbol("sun.max", size: 13).font(.system(size: 13, weight: .light))
                        .foregroundStyle(selected ? skin.ink : skin.muted).frame(width: 18)
                    Text(L("Today")).font(skin.sans(NV.Size.body, selected ? .medium : .regular)).foregroundStyle(skin.ink)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 6).padding(.top, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .nRow(selected: selected, hoverKey: AnyHashable("today"), divider: false, skin: skin)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(L("What needs you, ranked (⌘⇧F: Flow)"))
        }
    }
}

/// Classic skin: a List row tagged with Today's id (the sidebar List's selection opens it).
struct TodaySidebarSection: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.mail.ai.usesConversationTriage {
            Label(L("Today"), systemImage: "sun.max").tag(Optional(TodayModel.folderId))
        }
    }
}

/// The Today list (replaces the message list while Today is selected; the reader stays beside it).
struct TodayView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @FocusState private var focused: Bool

    var body: some View {
        let mail = app.mail
        let t = TodayModel.shared
        let _ = mail.visibleRows.count   // re-render with the list reload (the cards come from the same pass)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    NSectionHeader(L("Needs you"), index: 1)
                    Button(L("Signal")) { SignalModel.shared.enabled = true }.niivoGlassButton(skin)   // GLASS
                        .help(L("One item at a time with loops (Signal)"))   // LOOPS-HOOK
                    if !t.needs.isEmpty {
                        Button(L("Flow")) { t.startFlow(mail) }.niivoGlassButton(skin).help(L("One at a time (⌘⇧F)"))
                    }
                }
                if t.needs.isEmpty {
                    Text(L("Nothing needs you right now.")).font(skin.sans(NV.Size.body)).foregroundStyle(skin.muted).padding(14)
                }
                ForEach(t.needs) { c in TodayCardRow(card: c) }
                if t.plan.hidden > 0 {
                    Text(L("%lld more in the Inbox", t.plan.hidden)).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
                NSectionHeader(L("Waiting on others"), index: 2).padding(.top, 10)
                if t.waiting.isEmpty {
                    Text(L("Nobody owes you an answer.")).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).padding(14)
                }
                ForEach(t.waiting) { c in TodayCardRow(card: c) }
                NSectionHeader(L("Promises due"), index: 3).padding(.top, 10)
                promises(t)
                NSectionHeader(L("FYI"), index: 4).padding(.top, 10)
                fyiDigest(t, mail: mail)
            }
            .padding(.bottom, 16)
        }
        .background(skin.brand ? AnyShapeStyle(skin.ground) : AnyShapeStyle(.background))
        .focusable().focused($focused).focusEffectDisabled()
        .paneFocusRing(focused, skin: skin)
        .onKeyPress(phases: .down) { press in MailKeys.handle(press, mail: mail) }
        .onChange(of: mail.focusListToken) { DispatchQueue.main.async { focused = true } }
        .onAppear { focused = true; if mail.selectedMessageId == nil, let f = t.needs.first { mail.selectedMessageId = f.messageId } }
        .accessibilityLabel(L("Today"))
    }

    @ViewBuilder private func promises(_ t: TodayModel) -> some View {
        // TODAY-HOOK: PromiseSource (another builder); empty until it exists.
        let due = t.promises?.promisesDue(before: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now) ?? []
        if due.isEmpty {
            Text(L("No promises due.")).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).padding(14)
        } else {
            ForEach(due) { p in
                Text(p.title).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private func fyiDigest(_ t: TodayModel, mail: MailModel) -> some View {
        let names = Array(NSOrderedSet(array: t.fyi.map(\.text.sender)).compactMap { $0 as? String }.prefix(5))
        HStack(spacing: 8) {
            Button { t.fyiExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    NSymbol(t.fyiExpanded ? "chevron.down" : "chevron.right", size: 10)
                    Text(L("%lld for information", t.fyi.count)).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink)
                    if !names.isEmpty {
                        Text(names.joined(separator: ", ")).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if !t.fyi.isEmpty { Button(L("Mark all done")) { t.markAllFYIDone(mail) }.nvButton(skin, .quiet) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        if t.fyiExpanded {
            ForEach(t.fyi) { c in
                HStack(spacing: 8) {
                    Text(c.text.sender).font(skin.sans(NV.Size.bodySm, .medium)).foregroundStyle(skin.ink).lineLimit(1)
                    Text(c.text.line).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).lineLimit(1)
                }
                .padding(.horizontal, 28).padding(.vertical, 3)
            }
        }
    }
}

struct TodayCardRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var card: TodayModel.Card

    var body: some View {
        let mail = app.mail
        let selected = mail.selectedMessageId == card.messageId
        let waiting = card.item.section == .waiting
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(card.text.sender).font(skin.sans(NV.Size.body, .medium)).foregroundStyle(skin.ink).lineLimit(1)
                if card.item.maybe { NChip(L("maybe"), tone: .muted) }
                Spacer(minLength: 4)
                MonoLabel(card.age, size: NV.Size.labelSm)
            }
            Text(card.text.line).font(skin.sans(NV.Size.body)).foregroundStyle(card.text.isAsk ? skin.ink : skin.muted).lineLimit(2)
            HStack(spacing: 5) {
                if card.text.showsDetails {
                    ForEach(card.item.reasons, id: \.self) { r in NChip(L(r.title), tone: r == .vip || r == .deadline ? .accent : .muted) }
                }
                Spacer(minLength: 4)
                if selected { actions(waiting) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
        .nRow(selected: selected, hoverKey: AnyHashable("today:" + card.id), skin: skin)
        .onTapGesture { mail.selectedMessageId = card.messageId; mail.focusListToken += 1 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.text.sender), \(card.text.line)")
    }

    @ViewBuilder private func actions(_ waiting: Bool) -> some View {
        let t = TodayModel.shared
        HStack(spacing: 2) {
            if waiting {
                Button(L("Nudge")) { t.perform(.nudge, card, app: app) }.nvButton(skin, .quiet).help(L("Follow-up draft (R)"))
                NIconButton("checkmark", label: L("Done"), help: L("No longer waiting (E)")) { t.perform(.done, card, app: app) }
            } else {
                NIconButton("arrowshape.turn.up.left", label: L("Reply"), help: L("Reply with a draft (R)")) { t.perform(.reply, card, app: app) }
                NIconButton("calendar.badge.plus", label: L("Schedule"), help: L("Reply with meeting (S)")) { t.perform(.schedule, card, app: app) }
                NIconButton("arrowshape.turn.up.right", label: L("Delegate"), help: L("Forward with an instruction (D)")) { t.perform(.delegate, card, app: app) }
                NIconButton("checkmark", label: L("Done"), help: L("Done and archive (E) · Undo in the toast")) { t.perform(.done, card, app: app) }
                NIconButton("clock", label: L("Snooze"), help: L("Snooze (Z)")) { t.perform(.snooze, card, app: app) }
            }
        }
    }
}

/// Flow mode: one conversation, full width, reader with the inline composer underneath.
struct TodayFlowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @FocusState private var focused: Bool

    var body: some View {
        let mail = app.mail
        let t = TodayModel.shared
        let f = t.flow
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MonoLabel(L("Flow"), color: skin.ink, wide: true, weight: .medium)
                if let f, !f.finished { MonoLabel(L("%lld of %lld", f.position.0, f.position.1), size: NV.Size.labelSm) }
                Spacer()
                Text(L("R reply · S schedule · D delegate · E done · Z snooze · J/K next/previous · esc exit"))
                    .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).lineLimit(1)
                Button(L("Exit")) { t.exitFlow() }.niivoGlassButton(skin).help(L("Exit Flow (esc)"))   // GLASS
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .hairline(skin)
            if let f, f.finished {
                VStack(alignment: .leading, spacing: 10) {
                    BrandEmptyState(symbol: "checkmark.circle", eyebrow: L("Flow"), title: L("You're clear."))
                    Text(L("%lld handled, %lld left for later.", f.summary.handled, f.summary.skipped))
                        .font(skin.sans(NV.Size.body)).foregroundStyle(skin.muted)
                    NButton(L("Back to Today"), kind: .quiet) { t.exitFlow() }
                }
                .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ReaderView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(skin.brand ? AnyShapeStyle(skin.ground) : AnyShapeStyle(.background))
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            if press.key == .escape { t.exitFlow(); return .handled }
            return MailKeys.handle(press, mail: mail)
        }
        .onAppear { focused = true }
        .onChange(of: mail.selectedFolderId) { if !t.isActive(mail) { t.exitFlow() } }
    }
}

// MARK: - Settings (Mail Settings → Today)

struct TodaySettingsSection: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.mail.ai.usesConversationTriage {
            Section(L("Today")) {
                Toggle(L("Open Today at launch"), isOn: Bindable(TodayModel.shared).openAtLaunch)
                Text(L("Today lists the conversations where you're the one who acts, ranked by who, what's asked and how long it has waited. The Inbox stays as it is."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
