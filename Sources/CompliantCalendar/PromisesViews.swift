import SwiftUI
import MailCore
import CalendarCore

// PROMISES: app side of the promises ledger (docs/RETHINK.md §3–§4).
// * A loop (every 5 s while mail is open) refreshes dirty conversations off the main actor and publishes the open
//   promises. Same gate as conversation triage: text is read only where the on-device tier gets `.content`.
// * Text goes to disk only where the label allows offline details (and the device allows offline bodies).
// * Morning reminder: an in-app toast the day a promise is due, generic for protected sources.
// * Logs are counts only: `[Promises] extracted=… open=… overdue=… autoDone=…`.

@MainActor @Observable
final class PromisesModel {
    @ObservationIgnored weak var ai: AIAssistModel?
    private(set) var open: [Promise] = []
    private(set) var byConversation: [String: [Promise]] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var configKey = ""
    @ObservationIgnored private var lastGen = -1
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var lastLog = ""

    init(ai: AIAssistModel) { self.ai = ai }

    var ledger: PromiseLedger? { ai?.mail?.store?.promises }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Lock / wipe / settings change: memory goes; the sealed table stays with the store.
    func reset() { open = []; byConversation = [:]; configKey = ""; lastGen = -1 }

    private func configure() -> PromiseLedger? {
        guard let ai, let mail = ai.mail, mail.started, let store = mail.store else { return nil }
        var od = AIOrgAccess(trustRawValue: ai.trustPolicy.effectiveOnDeviceAIAccess.rawValue)
        if od == .off { od = .metadataOnly }   // local rules: never text when on-device AI is off
        let engine = mail.compliance
        let gate = AIGatePolicy(engine: engine, cloudAccess: .off, onDeviceAccess: od)
        let me = mail.me?.address.lowercased() ?? ""
        let owners = Set([me] + mail.settings.identities.map { $0.address.lowercased() }
                         + mail.mailboxes.filter { $0 != "me" }.map { $0.lowercased() }).subtracting([""])
        let account = ai.app?.auth?.accountKey ?? "default"
        let offline = ai.trustPolicy.allowOfflineBodies
        let key = [account, "\(od)", "\(engine.availableLabels().count)", "\(offline)", owners.sorted().joined(separator: ",")].joined(separator: "|")
        if let l = store.promises, key == configKey { return l }
        let cfg = PromiseLedger.Config(account: account, owners: owners,
                                       exposure: { m, mb in gate.exposure(m, mailbox: mb, tier: .onDevice) },
                                       persistText: { m, mb in offline && MailContentPolicy.policy(for: m, mailbox: mb, engine: engine).allowOfflineDetails })
        let l = store.enablePromises(cfg)
        TodayModel.shared.promises = l   // TODAY-HOOK: Today's "Promises due" reads the ledger
        configKey = key
        return l
    }

    func tick() async {
        guard let ai, !(ai.app?.trust.hidesContent ?? false), let ledger = configure() else { return }
        let n = await Task.detached(priority: .utility) { ledger.refresh() }.value
        let gen = ledger.generation
        guard gen != lastGen || n > 0 || Date().timeIntervalSince(lastPublish) > 60 else { return }
        lastGen = gen; lastPublish = Date()
        publish(ledger)
        remind(ledger)
        refine(ledger)
    }

    @ObservationIgnored private var refining: Task<Void, Never>?
    @ObservationIgnored private var refineTried: Set<String> = []
    /// Optional on-device pass over uncertain candidates (never the cloud), through the normal AI gate.
    private func refine(_ ledger: PromiseLedger) {
        guard refining == nil, let ai, ai.settings.precomputeTriage, let a = ai.assistant, a.route(.triage)?.tier == .onDevice,
              let store = ai.mail?.store else { return }
        let items: [PromiseRefineItem] = ledger.uncertain().filter { !refineTried.contains($0.id) }.prefix(6).compactMap { p in
            refineTried.insert(p.id)
            guard var m = (try? store.message(id: p.sourceMessageId, includeBody: false)) ?? nil else { return nil }
            if m.body == nil, let b = try? store.body(messageId: m.id, touch: false) { m.body = b; m.bodyIsHTML = b.contains("</") }
            return PromiseRefineItem(promiseId: p.id, kind: p.kind, message: m, mailbox: p.mailbox)
        }
        guard !items.isEmpty else { return }
        refining = Task { [weak self] in
            let res = (try? await a.refinePromises(items)) ?? [:]
            for (id, r) in res { ledger.refine(id, keep: r.keep, text: r.text, due: r.due) }
            FileHandle.standardError.write(Data("[Promises] refine items=\(items.count) answered=\(res.count)\n".utf8))
            guard let self else { return }
            self.refining = nil
            self.publish(ledger)
        }
    }

    func publish(_ ledger: PromiseLedger) {
        let o = ledger.open()
        open = o
        byConversation = Dictionary(grouping: o, by: \.conversationId)
        let line = ledger.diagnostic()
        if line != lastLog { lastLog = line; FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }

    /// The morning a promise is due: one toast per promise, generic when its source is protected.
    private func remind(_ ledger: PromiseLedger) {
        let now = Date(), cal = Calendar.current
        guard cal.component(.hour, from: now) >= 8, let mail = ai?.mail else { return }
        for p in open where p.isDueToday(now: now, calendar: cal) && !(p.remindedOn.map { cal.isDate($0, inSameDayAs: now) } ?? false) {
            let restricted = !p.persistText || p.text == nil
            let text = restricted ? L("A promise is due today") : L("Due today: %@", p.text ?? "")
            mail.toast(MailToast(text: text, symbol: "checkmark.seal"))
            ledger.markReminded(p.id, on: now)
            break   // one at a time; the next tick shows the next
        }
    }

    // MARK: Actions

    private func act(_ f: (PromiseLedger) -> Void) {
        guard let l = ledger else { return }
        f(l); publish(l)
    }
    func done(_ p: Promise) { act { $0.markDone(p.id) } }
    func dismiss(_ p: Promise) { act { $0.dismiss(p.id) } }
    func snooze(_ p: Promise, days: Int) {
        let cal = Calendar.current
        let until = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date()))?.addingTimeInterval(8 * 3_600) ?? Date()
        act { $0.snooze(p.id, until: until) }
    }
    func openConversation(_ p: Promise) { ai?.app?.openMailMessage(p.sourceMessageId, raise: false) }
}

// MARK: - Views

/// The "Promises" smart folder: open promises by due date (overdue in red).
struct PromisesListView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let m = app.mail.ai.promises
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Promises")).font(.title3.weight(.semibold))
                Spacer()
                Text("\(m.open.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if m.open.isEmpty {
                VStack(spacing: 6) {
                    Text(L("No open promises.")).foregroundStyle(.secondary)
                    Text(L("Things you say you'll do in sent mail, and requests with a deadline sent to you, appear here."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(m.open) { p in PromiseRow(promise: p, now: now, model: m) }
                }
                .listStyle(.plain)
            }
        }
        .task { m.start() }
    }
}

struct PromiseRow: View {
    var promise: Promise
    var now: Date
    var model: PromisesModel
    var body: some View {
        let p = promise
        let overdue = p.isOverdue(now: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !p.certain { Circle().fill(.secondary).frame(width: 5, height: 5).help(L("Uncertain: check it's a real promise")) }
                Text(p.text ?? L("Promise in a protected message")).lineLimit(2)
                Spacer(minLength: 6)
                if let d = PromiseDisplay.dueShort(p, now: now) {
                    Text(d).font(.caption.weight(overdue ? .semibold : .regular)).foregroundStyle(overdue ? .red : .secondary)
                }
            }
            HStack(spacing: 10) {
                Text([p.kind.title, p.counterpart].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(L("Done")) { model.done(p) }
                Menu(L("Snooze")) {
                    Button(L("Tomorrow")) { model.snooze(p, days: 1) }
                    Button(L("In 3 days")) { model.snooze(p, days: 3) }
                    Button(L("Next week")) { model.snooze(p, days: 7) }
                }
                .fixedSize()
                Button(L("Open")) { model.openConversation(p) }
                Button(L("Dismiss")) { model.dismiss(p) }
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(.vertical, 4)
        .foregroundStyle(overdue ? Color.red : Color.primary)
        .accessibilityElement(children: .contain)
    }
}

/// Reader: a slim line under the header for an open promise in this conversation.
struct PromiseReaderLine: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var body: some View {
        let ps = app.mail.ai.promises.byConversation[reader.header.conversationId] ?? []
        if !reader.policy.redactDetails, let p = ps.first {
            let now = Date()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal").font(.caption)
                Text(PromiseDisplay.readerLine(p, now: now)).font(.caption).lineLimit(1)
                if ps.count > 1 { Text("+\(ps.count - 1)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(L("Done")) { app.mail.ai.promises.done(p) }.buttonStyle(.borderless).font(.caption)
            }
            .foregroundStyle(p.isOverdue(now: now) ? Color.red : Color.secondary)
            .padding(.horizontal, 18).padding(.bottom, 6)
        }
    }
}
