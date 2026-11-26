import SwiftUI
import CalendarCore
import MailCore

// WHEN / DEEP (docs/SUITE.md, wireframes v0-4 and v0-5): the app side of loop work items. One `WorkItemsEngine` per
// mail store and account, on top of the loops engine's knowledge layer and the promises ledger. Reads run detached;
// the views read published snapshots. State the surfaces need across remounts (the confirm step, the block timer) lives
// here, so a Desk tile can mount `WhenSurface` / `DeepSurface` any number of times.
//
// Calendar writes: picking a slot only creates a `PendingFocusBlock`; the event is written by `confirmPending()` alone
// (Return in the confirm step), through `AppModel.focusWriter` (SyncEngine → Graph), on the owner's own calendar, as
// tentative, without attendees. Logs (counts only): `[When] items= proposed= taken=`, `[Deep] started= done= overrun=`.

@MainActor @Observable
final class WorkModel {
    static let shared = WorkModel()

    var revision = 0
    // When
    private(set) var queue: [WorkItem] = []
    private(set) var placed: [WorkItem] = []
    private(set) var loopTitles: [String: String] = [:]
    private(set) var proposal: SlotProposal?
    private(set) var proposalFor: String?
    /// When shows only this loop's items (nil = all loops).
    var whenLoop: String?
    /// Put this item first (Deep's "Need more time").
    var whenFirst: String?
    var pending: PendingFocusBlock?
    var pendingTitle = ""
    /// The focus card's title field (rename) and which item it belongs to.
    var editTitle = ""
    var editFor: String?
    var writeError: String?
    var writing = false
    private(set) var loaded = false
    // Deep
    var deepItemId: String?
    private(set) var deepLoop: LoopDetail?
    private(set) var deepItems: [WorkItem] = []
    var drawerOpen = false
    var timerStart: Date?
    var accumulated: TimeInterval = 0
    var timerItem: String?
    var blockMinutes = 50
    var offerCloseLoop: String?
    var newCriterion = ""
    // Loop page
    private(set) var pageItems: [String: [WorkItem]] = [:]
    private(set) var pageSuggestions: [String: [WorkItemSuggestion]] = [:]
    var newItemTitle = ""

    @ObservationIgnored private var engineId: ObjectIdentifier?
    @ObservationIgnored private var proposed = 0
    @ObservationIgnored private var taken = 0
    @ObservationIgnored private var started = 0
    @ObservationIgnored private var done = 0
    @ObservationIgnored private var overrun = 0
    @ObservationIgnored private var lastWhen = ""
    @ObservationIgnored private var lastDeep = ""

    /// Lock / sign-out / wipe / account change: nothing decrypted, pending or timed is kept.
    func reset() {
        clearState(); engineId = nil
    }
    private func clearState() {
        queue = []; placed = []; loopTitles = [:]; proposal = nil; proposalFor = nil; pending = nil; pendingTitle = ""; writeError = nil
        whenLoop = nil; whenFirst = nil; editTitle = ""; editFor = nil
        deepItemId = nil; deepLoop = nil; deepItems = []; timerStart = nil; accumulated = 0; timerItem = nil; offerCloseLoop = nil
        newCriterion = ""; pageItems = [:]; pageSuggestions = [:]; newItemTitle = ""; loaded = false; revision += 1
    }

    /// Open a surface: its Desk tile when the Desk shows, otherwise its window.
    func present(_ s: DeskSurface, openWindow: OpenWindowAction?) {
        DeskModel.shared.present(s) { openWindow?(id: s == .when ? "when" : "deep") }
    }

    /// The current account's engine (nil while locked / not started).
    func engine(_ mail: MailModel) -> WorkItemsEngine? {
        guard let l = LoopsModel.shared.engine(mail), let store = mail.store else { return nil }
        let w: WorkItemsEngine
        if let cur = store.workItems, cur.knowledge === l.knowledge, cur.account == l.account { cur.promises = store.promises; w = cur }
        else { w = store.enableWorkItems(.init(account: l.account), knowledge: l.knowledge, promises: store.promises) }
        if engineId != ObjectIdentifier(w) { clearState(); engineId = ObjectIdentifier(w) }   // another store / account
        return w
    }

    // MARK: When

    var current: WorkItem? {
        if let f = whenFirst, let x = queue.first(where: { $0.id == f }) { return x }
        return queue.first
    }

    func load(_ app: AppModel) async {
        let mail = app.mail
        guard let w = engine(mail), let l = LoopsModel.shared.engine(mail) else { return }
        let loop = whenLoop
        let (q, p, titles) = await Task.detached(priority: .userInitiated) { () -> ([WorkItem], [WorkItem], [String: String]) in
            let q = w.toPlace(loopId: loop), p = w.placed()
            var t: [String: String] = [:]
            for id in Set((q + p).map(\.loopId)) { if let s = l.loop(id: id)?.title { t[id] = s } }
            return (q, p, t)
        }.value
        queue = q; placed = p; loopTitles = titles; loaded = true
        if let f = whenFirst, !q.contains(where: { $0.id == f }) { whenFirst = nil }
        if editFor != current?.id { editFor = current?.id; editTitle = current?.title ?? "" }   // never overwrite while typing
        propose(app)
        await resolveLocalIds(app, w)
        revision += 1
        logWhen()
    }

    /// Slots for the current item: the owner's busy time + existing focus blocks, its own old block excluded.
    func propose(_ app: AppModel) {
        guard let item = current else { proposal = nil; proposalFor = nil; return }
        let now = Date(), cal = Calendar.current
        let horizon = max(14, item.due.map { (cal.dateComponents([.day], from: now, to: $0).day ?? 0) + 4 } ?? 0)
        let end = cal.date(byAdding: .day, value: min(horizon, 60), to: now) ?? now
        let excluded = Set([item.movingFrom?.eventId, item.slot?.eventId].compactMap { $0 } + placed.compactMap { $0.slot?.eventId })
        let busy = app.ownBusy(from: cal.startOfDay(for: now), to: end, excluding: excluded)
        let focus = placed.filter { $0.id != item.id }.compactMap { $0.slot?.interval }
        let p = SlotFinder.propose(minutes: item.minutes, due: item.due, busy: busy, focus: focus, hours: WorkHoursSetting.current,
                                   now: now, calendar: cal)
        if proposalFor != item.id || proposal?.slots != p.slots { proposed += p.slots.count }
        proposal = p; proposalFor = item.id
    }

    /// 1 / 2 / 3: opens the confirm step only (nothing is written).
    func take(_ n: Int, app: AppModel) {
        guard let item = current, let p = proposal, proposalFor == item.id, p.slots.indices.contains(n) else { return }
        guard let cal = app.focusCalendar else { writeError = L("No calendar of your own to put the block in."); return }
        writeError = nil
        let plan = FocusBlockPlan(calendarId: cal.id, subject: FocusBlockPlan.subject(userTitle: item.titleUser ? item.title : nil),
                                  slot: p.slots[n], replacing: item.movingFrom?.eventId)
        pending = PendingFocusBlock(workItemId: item.id, plan: plan)
        pendingTitle = item.title ?? L("Work item")
    }

    func cancelPending() { pending = nil; writeError = nil }

    /// Return in the confirm step: the one place a focus block is written.
    func confirmPending(_ app: AppModel) {
        guard var pend = pending, !writing, let w = engine(app.mail) else { return }
        guard let writer = app.focusWriter else { writeError = L("The calendar isn't connected."); return }
        if let block = app.stampFocusLabel(&pend.plan) { writeError = block; return }   // PURVIEW-HOOK: as a new meeting
        let moving = queue.first { $0.id == pend.workItemId }?.movingFrom
        writing = true
        Task {
            do {
                if let old = pend.plan.replacing, let m = moving { pend.plan.replacing = await app.resolveFocusEvent(old, slot: m.interval) ?? old }
                let res = try await pend.confirm(using: writer)
                let slot = WorkSlot(start: pend.plan.slot.start, end: pend.plan.slot.end, eventId: res.eventId)
                let itemId = pend.workItemId
                await Task.detached { w.schedule(itemId, slot: slot) }.value
                taken += 1
                pending = nil
                writeError = res.replacedRemoved == false ? L("Added. The earlier block couldn't be removed: delete it in the calendar.") : nil
                await app.afterFocusWrite()
            } catch {
                writeError = L("Couldn't add the block (%@).", AppModel.describe(error))
            }
            writing = false
            await load(app)
            await refreshPages(app)
        }
    }

    /// Exchange assigns the real id after the outbox flush; keep the item pointing at it.
    private func resolveLocalIds(_ app: AppModel, _ w: WorkItemsEngine) async {
        for x in placed + queue {
            for e in [x.slot?.eventId, x.movingFrom?.eventId].compactMap({ $0 }) where e.hasPrefix("local-") {
                if let real = await app.remappedEventId(e) { w.remapEvent(x.id, from: e, to: real) }
            }
        }
    }

    func later(_ app: AppModel) { act(app) { w, id in
        let cal = Calendar.current
        w.postpone(id, until: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400))
    } }
    func shorter(_ app: AppModel) {
        guard let m = current?.minutes else { return }
        let next = max(10, Int((Double(m) * 0.6 / 5).rounded()) * 5)
        act(app) { w, id in w.setMinutes(id, next) }
    }
    func notMine(_ app: AppModel) { act(app) { w, id in w.remove(id) } }

    private func act(_ app: AppModel, _ body: @escaping @Sendable (WorkItemsEngine, String) -> Void) {
        guard let id = current?.id, let w = engine(app.mail) else { return }
        pending = nil
        Task {
            await Task.detached { body(w, id) }.value
            await load(app)
            await refreshPages(app)
        }
    }

    private func logWhen() {
        let s = "[When] items=\(queue.count) proposed=\(proposed) taken=\(taken)"
        if s != lastWhen { lastWhen = s; FileHandle.standardError.write(Data((s + "\n").utf8)) }
    }

    // MARK: Deep

    var deepItem: WorkItem? { deepItems.first { $0.id == deepItemId } }

    /// The item in focus: the one asked for, else in progress, else the block happening now, else the next block today,
    /// else the first item waiting to be placed.
    func loadDeep(_ app: AppModel, prefer: String? = nil) async {
        let mail = app.mail
        guard let w = engine(mail), let l = LoopsModel.shared.engine(mail) else { return }
        let want = prefer ?? deepItemId
        let promises = TodayModel.shared.promises.map(PromiseBox.init)
        let (pick, items, detail) = await Task.detached(priority: .userInitiated) { () -> (String?, [WorkItem], LoopDetail?) in
            let all = w.allItems(), now = Date()
            let cal = Calendar.current
            let pick = want.flatMap { id in all.first { $0.id == id && $0.state != .done } }
                ?? all.first { $0.state == .inProgress }
                ?? all.first { $0.state == .scheduled && ($0.slot.map { $0.start <= now && now < $0.end } ?? false) }
                ?? all.filter { $0.state == .scheduled && ($0.slot.map { $0.start > now && cal.isDate($0.start, inSameDayAs: now) } ?? false) }
                    .min { $0.slot!.start < $1.slot!.start }
                ?? w.toPlace(now: now).first
            guard let pick else { return (nil, [], nil) }
            return (pick.id, w.items(loopId: pick.loopId), l.detail(pick.loopId, tier: .user, promises: promises?.source))
        }.value
        if deepItemId != pick { deepItemId = pick; newCriterion = "" }
        deepItems = items; deepLoop = detail
        if let x = deepItem, timerItem != x.id {
            timerItem = x.id; timerStart = nil; accumulated = 0
            blockMinutes = x.slot?.minutes ?? x.minutes
        }
        revision += 1
    }

    var elapsed: TimeInterval { accumulated + (timerStart.map { Date().timeIntervalSince($0) } ?? 0) }
    var isRunning: Bool { timerStart != nil }

    func startPause(_ app: AppModel) {
        guard let x = deepItem, let w = engine(app.mail) else { return }
        if let s = timerStart { accumulated += Date().timeIntervalSince(s); timerStart = nil; return }
        timerStart = Date()
        if x.state != .inProgress {
            started += 1; logDeep()
            let id = x.id
            Task { await Task.detached { w.start(id) }.value; await loadDeep(app) }
        }
    }

    private func finishTimer() {
        if elapsed > TimeInterval(blockMinutes * 60) { overrun += 1 }
        timerStart = nil; accumulated = 0; timerItem = nil
    }

    /// 1: Done → the loop's next item; when every item of the loop is done, offer (not force) closing the loop.
    func doneNext(_ app: AppModel) {
        guard let x = deepItem, let w = engine(app.mail) else { return }
        finishTimer(); done += 1; logDeep()
        let id = x.id, loop = x.loopId
        Task {
            let (all, next) = await Task.detached { () -> (Bool, String?) in
                w.markDone(id)
                let rest = w.items(loopId: loop).filter { $0.state != .done }
                return (w.allDone(loopId: loop), rest.first?.id)
            }.value
            if all, LoopsModel.shared.engine(app.mail)?.loop(id: loop)?.state == .open { offerCloseLoop = loop }
            deepItemId = next
            await loadDeep(app, prefer: next)
            await refreshPages(app)
        }
    }

    /// 2: Need more time → back to When with this item first (the worked block stays on the calendar).
    func needMoreTime(_ app: AppModel, openWindow: OpenWindowAction?) {
        guard let x = deepItem, let w = engine(app.mail) else { return }
        finishTimer()
        let id = x.id
        whenFirst = id; whenLoop = nil
        Task {
            await Task.detached { w.needMoreTime(id) }.value
            await load(app); await loadDeep(app)
            present(.when, openWindow: openWindow)
        }
    }

    /// 3: Park until tomorrow (out of the queue; its block is released).
    func park(_ app: AppModel) {
        guard let x = deepItem, let w = engine(app.mail) else { return }
        finishTimer()
        let id = x.id
        let cal = Calendar.current
        let until = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
        Task {
            await Task.detached { w.postpone(id, until: until, unplace: true) }.value
            deepItemId = nil
            await loadDeep(app); await load(app)
        }
    }

    func closeLoop(_ app: AppModel) {
        guard let loop = offerCloseLoop else { return }
        offerCloseLoop = nil
        LoopsModel.shared.edit(app.mail) { $0.setState(loop, .done) }
    }

    /// When's focus card editor (title, kind, minutes, due) on the current item.
    func editCurrent(_ app: AppModel, _ body: @escaping @Sendable (WorkItemsEngine, String) -> Void) {
        guard let id = current?.id, let w = engine(app.mail) else { return }
        Task {
            await Task.detached { body(w, id) }.value
            await load(app)
            await refreshPages(app)
        }
    }

    func edit(_ app: AppModel, _ body: @escaping @Sendable (WorkItemsEngine) -> Void) {
        guard let w = engine(app.mail) else { return }
        Task {
            await Task.detached { body(w) }.value
            await loadDeep(app)
            await refreshPages(app)
        }
    }

    private func logDeep() {
        let s = "[Deep] started=\(started) done=\(done) overrun=\(overrun)"
        if s != lastDeep { lastDeep = s; FileHandle.standardError.write(Data((s + "\n").utf8)) }
    }

    // MARK: Loop page (items + suggestions)

    func loadPage(_ loopId: String, app: AppModel) async {
        let mail = app.mail
        guard let w = engine(mail), let l = LoopsModel.shared.engine(mail) else { return }
        let triage = mail.store?.triage
        let (items, sug) = await Task.detached(priority: .userInitiated) { () -> ([WorkItem], [WorkItemSuggestion]) in
            let convs = l.conversations(inLoop: loopId)
            let needs = Set(convs.filter { triage?.decision(for: $0)?.state == .needsReply })
            return (w.items(loopId: loopId), w.suggestions(loopId: loopId, conversations: convs, needsReply: needs))
        }.value
        pageItems[loopId] = items; pageSuggestions[loopId] = sug
        revision += 1
    }

    func refreshPages(_ app: AppModel) async {
        for id in Array(pageItems.keys) { await loadPage(id, app: app) }
    }

    func pageEdit(_ loopId: String, app: AppModel, _ body: @escaping @Sendable (WorkItemsEngine) -> Void) {
        guard let w = engine(app.mail) else { return }
        Task {
            await Task.detached { body(w) }.value
            await loadPage(loopId, app: app)
            if loaded { await load(app) }
        }
    }
}

/// Working hours for slot finding (Settings: `work.hours.start` / `work.hours.end`, minutes from midnight).
enum WorkHoursSetting {
    static var current: SlotHours {
        let d = UserDefaults.standard
        let s = d.object(forKey: "work.hours.start") as? Int ?? 510, e = d.object(forKey: "work.hours.end") as? Int ?? 1020
        return (0..<e).contains(s) && e <= 24 * 60 ? SlotHours(startMinute: s, endMinute: e) : .standard
    }
}
