import SwiftUI
import AppKit
import MailCore
import CalendarCore

// TRIAGE2: row correction menu and the owner's "Train Triage…" window (Mail menu, ⌃⇧⌘L).
// State lives in `TriageTrainer` (@Observable): the toolchain can't expand SwiftUI's @State macro.
// TRIAGE3: the window shows the conversation (each message through the reader's own fail-closed loader and
// ReaderBody), and every answer is pinned to the newest message shown (the snapshot): "who acts next, as of then".

/// "Who acts next?" submenu for a row (also on the badge's context menu).
struct TriageRowMenu: View {
    @Environment(AppModel.self) private var app
    var row: MailRow
    var body: some View {
        let ai = app.mail.ai
        if ai.usesConversationTriage, !row.policy.redactDetails {
            Menu("Who Acts Next") {
                Button("Reply Needed") { ai.inbox.correct(row, to: .needsReply) }
                Button("Waiting on Them") { ai.inbox.correct(row, to: .waiting) }
                Button("FYI (No Badge)") { ai.inbox.correct(row, to: .fyi) }
                Button("Done") { ai.inbox.correct(row, to: .done) }
                Divider()
                Button("Never “Reply Needed” from This Sender") { ai.inbox.neverFromSender(row) }.disabled(row.message.from == nil)
                if ai.inbox.decision(for: row)?.source == .user { Button("Undo My Correction") { ai.inbox.clearOverride(row) } }
            }
        }
    }
}

// MARK: - Trainer state

/// One message of the shown conversation, with its header-level policy (its own mailbox).
struct TrainerMessage: Identifiable {
    var message: MailMessage
    var mine: Bool
    var mailbox: String
    var policy: ContentPolicy
    var id: String { message.id }
}

@MainActor @Observable
final class TriageTrainer {
    static let shared = TriageTrainer()
    weak var app: AppModel?
    private(set) var queue: [String] = []
    var index = 0
    var wrongSender = false
    private(set) var answered = 0
    var scoreLine: String?
    var score: TriageScore?
    var notice: String?

    /// The shown conversation: counted messages (as the engine counts them), oldest first. The last one is the
    /// snapshot every answer is pinned to.
    private(set) var thread: [TrainerMessage] = []
    private(set) var threadId: String?
    private(set) var snapshot: TriageSnapshot?
    var expanded: Set<String> = []
    /// Per-message reader states from `MailModel.standaloneReader` (same fail-closed rules as the reader, no mark-read).
    private(set) var readers: [String: ReaderState] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?

    var current: String? { queue.indices.contains(index) ? queue[index] : nil }

    /// A stratified sample of recent inbox + sent conversations (predicted needs-reply, waiting, FYI, done, uncertain).
    func load(n: Int = 100) {
        guard let app, let e = app.mail.store?.triage else { notice = L("Open the mail view first: triage hasn't started."); return }
        let ds = app.mail.ai.inbox.decisions
        let items = ds.compactMap { cid, d in e.facts(for: cid).map { (id: cid, decision: e.decision(for: cid, ignoreOverride: true) ?? d, latest: $0.latest) } }
        queue = TriageSampler.stratify(items, n: n, exclude: e.answeredIds())
        index = 0; wrongSender = false; notice = queue.isEmpty ? L("Nothing left to label in the last 30 days.") : nil
        prepare()
    }

    /// Loads the current conversation (store reads here, not in `body`) and opens the newest message.
    func prepare() {
        readers = [:]; loading = []; expanded = []
        guard let cid = current, let mail = app?.mail, let store = mail.store, let e = store.triage else {
            thread = []; threadId = nil; snapshot = nil; return
        }
        thread = e.countedThread(conversationId: cid).map { m, mine in
            let mb = store.mailbox(forFolder: m.folderId)
            return TrainerMessage(message: m, mine: mine, mailbox: mb, policy: mail.policy(for: m, mailbox: mb))
        }
        threadId = cid
        snapshot = thread.last.map { e.snapshot(of: $0.message) }
        if let newest = thread.last { expand(newest.id) }
    }

    func answer(_ s: ConversationState?) {
        guard let cid = current else { return }
        if let e = app?.mail.store?.triage, let snapshot {   // no snapshot = nothing was shown: record nothing
            // As of the newest message shown, even if a newer one arrived while the window was open.
            e.recordTruth(conversationId: cid, asOf: snapshot, truth: s, wrongSenderType: wrongSender)
            app?.mail.ai.inbox.republish(cid)
        }
        answered += 1; wrongSender = false; index += 1
        prepare()
    }

    func runScore() {
        guard let app, let e = app.mail.store?.triage else { return }
        let inbox = app.mail.ai.inbox
        let listed = inbox.listedInboxConversations()
        let cov = TriageScoring.coverage(listed: listed, hasState: { inbox.decisions[$0] != nil })
        let s = TriageScoring.score(e.truthRows(repredict: true), coverage: cov.coverage, missedLatest: cov.missedLatest)
        score = s; scoreLine = s.line
        FileHandle.standardError.write(Data("[TriageScore] \(s.line)\n".utf8))   // counts only
    }

    // MARK: Messages

    func toggle(_ id: String) { if expanded.contains(id) { expanded.remove(id) } else { expand(id) } }

    func expand(_ id: String) {
        expanded.insert(id)
        guard readers[id] == nil, !loading.contains(id), let mail = app?.mail else { return }
        loading.insert(id)
        let cid = threadId
        Task { @MainActor [weak self, weak mail] in
            guard let mail else { return }
            let r = await mail.standaloneReader(id: id)   // fetches on demand under the reader's offline-details rules
            guard let self else { return }
            self.loading.remove(id)
            guard self.threadId == cid, let r else { return }
            self.readers[id] = r
        }
    }

    /// A member's live policy: the post-fetch one (rpmsg detection, the full message's label) once loaded.
    func policy(_ m: TrainerMessage) -> ContentPolicy { readers[m.id]?.policy ?? m.policy }

    /// Strictest over every shown message: the window's capture shield.
    var shownPolicy: ContentPolicy { MailThreads.strictest(thread.map(policy)) }

    // MARK: Keys (window level: a focused message body must not swallow the one-key answers)

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            nonisolated(unsafe) let ev = e
            let handled = MainActor.assumeIsolated { TriageTrainer.shared.handleKey(ev) }
            return handled ? nil : e
        }
    }

    func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    /// 1–4 answer, S skips, W toggles "wrong sender type". Only in this window (or its capture-shield child), never
    /// with ⌘/⌃/⌥, a sheet, a text field being edited, or while the app is locked.
    func handleKey(_ e: NSEvent) -> Bool {
        guard !e.isARepeat, let w = window, let ew = e.window, ew === w || ew.parent === w, w.attachedSheet == nil,
              e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(ew.firstResponder is NSText), app?.trust.hidesContent == false, current != nil else { return false }
        switch (e.charactersIgnoringModifiers ?? "").lowercased() {
        case "1": answer(.needsReply)
        case "2": answer(.waiting)
        case "3": answer(.fyi)
        case "4": answer(.done)
        case "s": answer(nil)
        case "w": wrongSender.toggle()
        default: return false
        }
        return true
    }
}

/// Registers the trainer's window and installs the key monitor while it's on screen.
struct TriageTrainerKeys: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let t = TriageTrainer.shared
            if let w = window { t.window = w; t.installKeyMonitor() } else { t.removeKeyMonitor() }
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ v: Anchor, context: Context) {}
    static func dismantleNSView(_ v: Anchor, coordinator: ()) { TriageTrainer.shared.removeKeyMonitor() }
}

// MARK: - Window

struct TriageTrainerRoot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let hidden = model.trust.hidesContent
        let t = TriageTrainer.shared
        // The shown messages' labels too (strictest, incl. the post-fetch policy).
        SecondaryWindow(captureBlocked: model.mail.screenPolicy.preventScreenCapture || t.shownPolicy.preventScreenCapture) {
            if hidden { Text(L("Locked")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { TriageTrainerScreen(t: TriageTrainer.shared) }
        }
        .frame(minWidth: 720, minHeight: 640)
        .background(TriageTrainerKeys())
        .task {
            TriageTrainer.shared.app = model
            if TriageTrainer.shared.queue.isEmpty { TriageTrainer.shared.load() } else { TriageTrainer.shared.prepare() }
        }
    }
}

struct TriageTrainerScreen: View {
    @Bindable var t: TriageTrainer
    @Environment(\.skin) private var skin
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowHeader(eyebrow: L("Triage"), title: L("Who acts next?")) {
                NButton(L("New sample"), systemImage: "shuffle", kind: .ghost) { t.load() }.fixedSize()
                NButton(L("Score"), systemImage: "chart.bar", kind: .ghost) { t.runScore() }.fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                if let n = t.notice { Text(n).font(skin.sans(NV.Size.body)).foregroundStyle(skin.muted) }
                if t.current != nil {
                    MonoLabel(L("%lld of %lld · %lld answered this session", t.index + 1, t.queue.count, t.answered), color: skin.muted)
                    if t.thread.isEmpty {
                        Text(L("This conversation is gone. Press S to skip.")).font(skin.sans(NV.Size.body))
                        Spacer(minLength: 0)
                    } else {
                        TriageTrainerThread(t: t).frame(maxHeight: .infinity)
                        Text(prompt).font(skin.sans(NV.Size.body, .medium))
                    }
                    HStack(spacing: 8) {
                        key("1", L("Needs reply from you")) { t.answer(.needsReply) }
                        key("2", L("Waiting on them")) { t.answer(.waiting) }
                        key("3", L("FYI")) { t.answer(.fyi) }
                        key("4", L("Done")) { t.answer(.done) }
                        key("S", L("Skip")) { t.answer(nil) }
                    }
                    Text(L("You're judging the conversation as it stood at the latest message above. If it needed a reply then but you've since dealt with it outside email (a call, in person), choose Done. A later email, yours or theirs, is a new message: it's asked about separately and never makes this answer wrong."))
                        .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
                    Toggle(L("Wrong sender type (W): e.g. a newsletter shown as a person"), isOn: $t.wrongSender)
                        .font(skin.sans(NV.Size.bodySm))
                } else if t.notice == nil {
                    Text(L("Sample done. Press Score, or New sample for more.")).font(skin.sans(NV.Size.body))
                    Spacer(minLength: 0)
                }
                if let s = t.score { TriageScoreView(score: s) }
            }
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// "As of the latest message (date, from …): who needs to act?"
    private var prompt: String {
        guard let m = t.thread.last else { return "" }
        let p = t.policy(m)
        let who = m.mine ? L("you") : (p.redactDetails ? L("a private sender") : (m.message.from?.display ?? L("an unknown sender")))
        return L("As of the latest message (%@, from %@): who needs to act?", A11yPrefs.shared.regional.dateTime(m.message.received), who)
    }

    private func key(_ k: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        NButton("\(k)  \(title)", kind: .ghost, action: action).fixedSize().disabled(t.current == nil)
    }
}

/// The conversation, newest last: older messages one line each, the newest expanded; click to expand / collapse.
struct TriageTrainerThread: View {
    @Environment(\.skin) private var skin
    var t: TriageTrainer
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(t.thread) { m in
                        TriageTrainerMessage(t: t, m: m, isNewest: m.id == t.thread.last?.id).id(m.id)
                        Rectangle().fill(skin.hair2).frame(height: 1)
                    }
                }
            }
            .task(id: t.threadId) { if let last = t.thread.last { proxy.scrollTo(last.id, anchor: .top) } }
        }
        .background(skin.card)
        .overlay { Rectangle().stroke(skin.hair2, lineWidth: 1) }
    }
}

struct TriageTrainerMessage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var t: TriageTrainer
    var m: TrainerMessage
    var isNewest: Bool

    var body: some View {
        let p = t.policy(m)
        if t.expanded.contains(m.id) { expanded(p) } else { collapsed(p) }
    }

    /// "You → Anna, Ben" for my messages, the sender for theirs ("Private" when redacted).
    private func who(_ p: ContentPolicy) -> String {
        if p.redactDetails { return m.mine ? L("You") : L("Private") }
        guard m.mine else { return m.message.from?.display ?? L("(no sender)") }
        let to = (m.message.toRecipients + m.message.ccRecipients).map(\.display)
        return to.isEmpty ? L("You") : L("You → %@", to.joined(separator: ", "))
    }

    private func line(_ p: ContentPolicy, preview: Bool) -> some View {
        HStack(spacing: 8) {
            if m.mine { MonoLabel(L("You"), size: NV.Size.labelSm, color: skin.ink) }
            Text(who(p)).font(skin.sans(NV.Size.bodySm, .medium)).lineLimit(1).layoutPriority(1)
            if p.bodyIsProtected { NSymbol("lock.fill", size: 9, label: L("Encrypted")).foregroundStyle(skin.muted) }
            if preview {
                Text(p.redactDetails || !p.allowOfflineDetails ? "" : (m.message.preview ?? ""))
                    .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if isNewest { MonoLabel(L("Latest"), size: NV.Size.labelSm, color: skin.muted) }
            Text(A11yPrefs.shared.regional.dateTime(m.message.received)).font(skin.mono(NV.Size.labelSm)).foregroundStyle(skin.muted)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { t.toggle(m.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func collapsed(_ p: ContentPolicy) -> some View {
        line(p, preview: true).accessibilityHint(L("Expands the message"))
    }

    @ViewBuilder private func expanded(_ p: ContentPolicy) -> some View {
        let allowCopy = p.allowCopy && app.trust.effectivePolicy.allowCopyOut
        VStack(alignment: .leading, spacing: 0) {
            if let h = p.headerMarking {
                HeaderMarking(text: h, color: p.label.map { Color(hex: $0.hexColor, fallback: .red) }).padding(.horizontal, 14).padding(.top, 6)
            }
            line(p, preview: false).accessibilityHint(L("Collapses the message"))
            if !p.redactDetails, !m.mine, !(m.message.toRecipients + m.message.ccRecipients).isEmpty {
                let to = (m.message.toRecipients + m.message.ccRecipients).map { app.mail.meAddresses.contains($0.address.lowercased()) ? L("me") : $0.display }
                Text(L("to %@", to.joined(separator: ", "))).font(skin.sans(NV.Size.labelSm)).foregroundStyle(skin.muted).lineLimit(1)
                    .padding(.horizontal, 14).padding(.bottom, 6)
            }
            if let r = t.readers[m.id] {
                // The reader's own body path: private / protected / unknown-label notices, sanitised HTML, offline rule.
                // Keys inside the body never reach mail triage here (the window monitor answers 1–4 / S / W).
                ReaderBody(reader: r, allowCopy: allowCopy, onKey: { _ in false })
                    .frame(height: !MailThreads.mayFetchBody(r.policy) || r.error != nil ? (r.policy.bodyIsProtected ? 420 : 90) : (isNewest ? 360 : 260))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(14)
            }
            if let f = p.footerMarking { FooterMarking(text: f) }
        }
        .overlay { if let w = p.watermark { Watermark(text: w) } }
        .modifier(Selectable(enabled: allowCopy))
    }
}

struct TriageScoreView: View {
    @Environment(\.skin) private var skin
    var score: TriageScore
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MonoLabel(L("Score: %lld labelled · %lld skipped · %lld moved on since (scored as of your answer) · %lld older answers not scored",
                        score.labelled, score.skipped, score.movedOn, score.stale), color: skin.ink)
            Text(String(format: L("Accuracy %.0f %% · coverage %.0f %% · newest without a state: %d"), score.accuracy * 100, score.coverage * 100, score.missedLatest))
                .font(skin.sans(NV.Size.bodySm))
            ForEach(ConversationState.allCases, id: \.self) { s in
                if let p = score.perState[s] {
                    Text(String(format: "%@  P %.2f · R %.2f · F1 %.2f · n %d", s.title, p.precision, p.recall, p.f1, p.support))
                        .font(skin.mono(NV.Size.labelSm))
                }
            }
            Text(L("Confusion (rows = your answer, columns = app): ") + ConversationState.allCases.map { tr in
                ConversationState.allCases.map { "\(score.confusion[tr]?[$0] ?? 0)" }.joined(separator: " ")
            }.joined(separator: " | ")).font(skin.mono(NV.Size.labelSm)).foregroundStyle(skin.muted)
        }
    }
}
