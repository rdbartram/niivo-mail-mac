import SwiftUI
import AppKit
import CalendarCore
import MailCore

// Reader extras (UI, part 1): meeting invite card + RSVP, unsubscribe, junk / block sender, the ⋯ menu items.
// Part 2 (ReaderActions3.swift): find in message, print, view source / .eml, commands, mark-as-read delay.
// Graph calls: MailCore/GraphMailService+Reader.swift, CalendarCore/InviteResponse.swift.
// Hooks (one line each): MailReader.swift (ReaderContent, ReaderActions menu, ReaderWebView keys), MailModel.loadReader
// (mark read), EventInspector (RSVP buttons), MailSettingsView (delay picker), CompliantCalendarApp (commands).

// MARK: - Shared state

@MainActor @Observable
final class ReaderTools {
    static let shared = ReaderTools()
    static let keep = 30

    // Per message (memory only): invite + headers.
    private(set) var info: [String: ReaderInfo] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var loading: Set<String> = []

    // Find in message.
    var findVisible = false
    var findQuery = ""
    var findStatus: String?
    var findFocusToken = 0
    @ObservationIgnored weak var webView: ReaderWebView?

    // Source sheet.
    var showSource = false
    var sourceTitle = ""
    var sourceHeaders: [MessageHeader] = []
    var sourceText = ""
    var sourceError: String?
    var sourceLoading = false
    var sourceAllowCopy = false
    @ObservationIgnored var sourceReader: ReaderState?

    // Unsubscribe confirmation (one-click POST names the domain first).
    var unsubscribeConfirm: URL?
    var showUnsubscribeConfirm = false
    var unsubscribed: Set<String> = []

    var busy: Set<String> = []

    /// Loaded only where the body may show (same fail-closed rule as the body fetch).
    static func mayLoad(_ p: ContentPolicy) -> Bool {
        if p.redactDetails || p.bodyIsProtected { return false }
        if case .unknown = p.labelState { return false }
        return true
    }

    func load(_ r: ReaderState, mail: MailModel) async {
        let id = r.header.id
        guard info[id] == nil, !loading.contains(id), Self.mayLoad(r.policy), let svc = mail.sync?.readerService else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        guard let got = try? await svc.readerInfo(messageId: id, mailbox: r.mailbox) else { return }
        info[id] = got
        order.append(id)
        while order.count > Self.keep { info[order.removeFirst()] = nil }
    }

    func invite(_ id: String) -> MeetingInvite? { info[id]?.invite }
    func unsubscribe(_ id: String) -> ListUnsubscribe? { info[id].flatMap { ListUnsubscribe.parse($0.headers) } }
    func setResponse(_ id: String, _ status: String) { info[id]?.invite?.myResponse = status }
    func dropInvite(_ id: String) { info[id]?.invite?.eventId = nil }

    /// Lock / wipe / sign-out: forget everything held for the reader.
    func clear() {
        info = [:]; order = []; unsubscribed = []
        showSource = false; sourceReader = nil; sourceText = ""; sourceHeaders = []; sourceTitle = ""
        findVisible = false; findQuery = ""
    }
}

// MARK: - Responder (calendar token; fixtures stay local)

@MainActor
enum InviteResponder {
    static func current(_ app: AppModel) -> InviteResponding {
        if let auth = app.auth, !app.mail.isFixtures { return GraphInviteResponder(token: { try await auth.token() }) }
        return fixtures
    }
    static let fixtures = FixtureInviteResponder()

    static func describe(_ e: Error) -> String {
        if let i = e as? InviteReply.Invalid { return InviteReply.describe(i) }
        switch e as? ServiceError {
        case .offline?: return "You're offline. Nothing was sent."
        case .unauthorized?: return "Not allowed: the calendar sign-in doesn't cover this mailbox."
        case .http(400, _)?: return "Exchange refused the response (the organiser may not allow new time proposals)."
        default: return "The response couldn't be sent. Nothing was changed."
        }
    }
}

// MARK: - RSVP sheet (mail invite card + calendar inspector)

@MainActor @Observable
final class RSVPState {
    static let shared = RSVPState()
    struct Target: Equatable {
        var eventId: String
        var mailboxPath: String
        var calendarId: String?
        var subject: String
        var start: Date
        var end: Date
        var allowProposals: Bool
        var messageId: String?
    }
    var target: Target?
    var show = false
    var response: InviteResponse = .accept
    var comment = ""
    var sendResponse = true
    var proposing = false
    var proposedStart = Date()
    var proposedEnd = Date()
    var error: String?
    var sending = false

    func begin(_ t: Target, response: InviteResponse, propose: Bool = false) {
        target = t; self.response = propose && response == .accept ? .tentativelyAccept : response
        comment = ""; sendResponse = true; proposing = propose; error = nil; sending = false
        proposedStart = t.start; proposedEnd = t.end
        show = true
    }

    var reply: InviteReply {
        InviteReply(response, comment: comment, sendResponse: proposing ? true : sendResponse,
                    proposedStart: proposing ? proposedStart : nil, proposedEnd: proposing ? proposedEnd : nil)
    }

    func send(_ app: AppModel) {
        guard let t = target, !sending else { return }
        let r = reply
        do { try r.validate(allowNewTimeProposals: t.allowProposals) } catch { self.error = InviteResponder.describe(error); return }
        sending = true; error = nil
        let responder = InviteResponder.current(app)
        Task { @MainActor in
            do {
                try await responder.respond(mailboxPath: t.mailboxPath, calendarId: t.calendarId, eventId: t.eventId, reply: r)
                if let m = t.messageId { ReaderTools.shared.setResponse(m, r.response.responseStatus) }
                self.show = false; self.sending = false
                app.mail.toast(MailToast(text: Self.done(r), symbol: "calendar.badge.checkmark"))
                await app.syncNow()
            } catch {
                self.sending = false
                self.error = InviteResponder.describe(error)
            }
        }
    }

    static func done(_ r: InviteReply) -> String {
        let verb = switch r.response { case .accept: "Accepted"; case .tentativelyAccept: "Tentatively accepted"; case .decline: "Declined" }
        if r.proposedStart != nil { return "\(verb) and proposed a new time" }
        return r.sendResponse ? "\(verb) — the organiser was told" : "\(verb) without sending a response"
    }
}

struct RSVPSheet: View {
    @Environment(AppModel.self) private var app
    @Bindable var state = RSVPState.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.proposing ? "Propose a New Time" : "Respond to Invitation").font(.title3.weight(.semibold))
            if let t = state.target {
                Text(t.subject.isEmpty ? "(no subject)" : t.subject).font(.callout.weight(.medium)).lineLimit(2)
                Text(InviteCard.range(t.start, t.end, allDay: false)).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Response", selection: $state.response) {
                ForEach(InviteResponse.allCases.filter { !state.proposing || $0 != .accept }, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if state.proposing {
                DatePicker("Start", selection: $state.proposedStart)
                DatePicker("End", selection: $state.proposedEnd)
                if let t = state.target, !t.allowProposals {
                    Text("The organiser doesn't allow new time proposals.").font(.caption).foregroundStyle(.orange)
                }
            }
            TextField("Comment (optional)", text: $state.comment, axis: .vertical).lineLimit(2...5)
            Toggle("Send a response to the organiser", isOn: $state.sendResponse)
                .disabled(state.proposing)
                .help(state.proposing ? "A proposed time is always sent to the organiser" : "Off: your calendar changes, the organiser isn't told")
            if let e = state.error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { state.show = false }.keyboardShortcut(.cancelAction)
                Button(state.sending ? "Sending…" : "Send") { state.send(app) }
                    .keyboardShortcut(.defaultAction).disabled(state.sending)
            }
        }
        .padding(20).frame(width: 420)
    }
}

/// Accept / Tentative / Propose for an attendee's copy in the calendar inspector (Decline stays where it was).
struct EventRSVPButtons: View {
    @Environment(AppModel.self) private var model
    var event: CalendarEvent
    var body: some View {
        if model.removeMode(for: event) == .decline, !event.isCancelled, let cal = model.calendar(for: event), cal.canEdit, !cal.isGroup {   // CALENDAR: group events have no per-member RSVP path
            let t = RSVPState.Target(eventId: event.id, mailboxPath: cal.mailboxPath, calendarId: cal.id, subject: event.subject,
                                     start: event.start, end: event.end, allowProposals: true, messageId: nil)
            Button { RSVPState.shared.begin(t, response: .accept) } label: { NLabel("Accept", systemImage: "checkmark.circle") }
                .modifier(BrandButton())
            Button { RSVPState.shared.begin(t, response: .tentativelyAccept) } label: { NLabel("Tentative", systemImage: "questionmark.circle") }
                .modifier(BrandButton())
            Button { RSVPState.shared.begin(t, response: .tentativelyAccept, propose: true) } label: { NLabel("Propose New Time", systemImage: "clock.arrow.2.circlepath") }
                .modifier(BrandButton())
                .sheet(isPresented: Bindable(RSVPState.shared).show) { RSVPSheet().environment(model).skinned(model.skin) }
        }
    }
}

// MARK: - Invite card (reader)

struct InviteCard: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState

    var body: some View {
        let extras = ReaderTools.shared
        Group {
            if let inv = extras.invite(reader.header.id), inv.kind == .request || inv.kind == .cancelled {
                card(inv)
            }
        }
        .task(id: reader.header.id) { await extras.load(reader, mail: app.mail) }
        .sheet(isPresented: Bindable(RSVPState.shared).show) { RSVPSheet().environment(app).skinned(app.skin) }
    }

    @ViewBuilder private func card(_ inv: MeetingInvite) -> some View {
        let brand = app.theme.brand
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                NSymbol(inv.kind == .cancelled ? "calendar.badge.minus" : "calendar.badge.plus", size: 16)
                Text(app.skin.caps(inv.kind == .cancelled ? "Meeting cancelled" : "Meeting invitation"))
                    .font(brand ? app.skin.mono(NV.Size.labelSm, .medium) : .caption.weight(.semibold))
                Spacer()
                if let r = inv.myResponse, let s = Self.responseText(r) { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
            if let s = inv.start, let e = inv.end {
                Text(Self.range(s, e, allDay: inv.isAllDay)).font(brand ? app.skin.sans(NV.Size.body, .medium) : .callout.weight(.medium))
            }
            if let l = inv.location { Label(l, systemImage: "mappin.and.ellipse").font(.caption) }
            if let o = inv.organizer { Label("Organiser: \(o.display)", systemImage: "person.crop.circle").font(.caption) }
            if inv.isOutOfDate { Text("A newer update to this meeting has arrived.").font(.caption).foregroundStyle(.orange) }
            if inv.kind == .request { conflicts(inv) }
            HStack(spacing: 8) {
                if inv.canRespond, let t = target(inv) {
                    Button { RSVPState.shared.begin(t, response: .accept) } label: { NLabel("Accept", systemImage: "checkmark.circle") }
                        .modifier(BrandButton(kind: .primary))
                    Button { RSVPState.shared.begin(t, response: .tentativelyAccept) } label: { NLabel("Tentative", systemImage: "questionmark.circle") }
                        .modifier(BrandButton())
                    Button { RSVPState.shared.begin(t, response: .decline) } label: { NLabel("Decline", systemImage: "xmark.circle") }
                        .modifier(BrandButton(kind: .danger))
                    Button { RSVPState.shared.begin(t, response: .tentativelyAccept, propose: true) } label: { NLabel("Propose New Time", systemImage: "clock.arrow.2.circlepath") }
                        .modifier(BrandButton())
                        .disabled(!inv.allowNewTimeProposals)
                        .help(inv.allowNewTimeProposals ? "Tentative or decline with a proposed time" : "The organiser doesn't allow new time proposals")
                } else if inv.canRemoveFromCalendar, let ev = inv.eventId {
                    Button { removeCancelled(ev) } label: { NLabel("Remove from Calendar", systemImage: "trash") }
                        .modifier(BrandButton(kind: .danger))
                        .disabled(ReaderTools.shared.busy.contains(ev))
                } else if inv.kind == .request, inv.eventId == nil {
                    Text("This meeting isn't in your calendar any more.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(brand ? AnyShapeStyle(app.skin.soft) : AnyShapeStyle(.quaternary.opacity(0.4)), in: app.skin.rounded)
        .overlay { if brand { Rectangle().strokeBorder(app.skin.hair2, lineWidth: 1) } }
        .padding(.horizontal, 18).padding(.bottom, 8)
    }

    private func target(_ inv: MeetingInvite) -> RSVPState.Target? {
        guard let id = inv.eventId, let s = inv.start, let e = inv.end else { return nil }
        return RSVPState.Target(eventId: id, mailboxPath: reader.mailbox == "me" ? "me" : "users/\(reader.mailbox)", calendarId: nil,
                                subject: inv.subject, start: s, end: e, allowProposals: inv.allowNewTimeProposals,
                                messageId: reader.header.id)
    }

    /// Conflicts against the user's own cached calendars; the invite's own tentative copy doesn't count.
    @ViewBuilder private func conflicts(_ inv: MeetingInvite) -> some View {
        if reader.mailbox == "me", let s = inv.start, let e = inv.end {
            let own = Set(app.calendars.filter { $0.access == .own }.map(\.id))
            let evs = (try? app.store?.events(from: s.addingTimeInterval(-86_400), to: e.addingTimeInterval(86_400), calendarIds: own)) ?? []
            let hits = InviteConflicts.conflicts(start: s, end: e, isAllDay: inv.isAllDay, in: evs, excludingEventId: inv.eventId)
                .filter { !($0.start == s && $0.end == e && $0.subject == inv.subject) }
            if hits.isEmpty {
                Label("No conflicts in your calendar", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Conflicts with \(hits.count) item\(hits.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    ForEach(hits.prefix(3), id: \.id) { h in
                        let p = app.policy(for: h)
                        Text("· \(p.redactDetails ? "Private appointment" : h.subject) (\(h.start.formatted(date: .omitted, time: .shortened))–\(h.end.formatted(date: .omitted, time: .shortened)))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func removeCancelled(_ eventId: String) {
        let x = ReaderTools.shared, id = reader.header.id
        let mbPath = reader.mailbox == "me" ? "me" : "users/\(reader.mailbox)"
        let responder = InviteResponder.current(app)
        x.busy.insert(eventId)
        Task { @MainActor in
            defer { x.busy.remove(eventId) }
            do {
                try await responder.removeEvent(mailboxPath: mbPath, calendarId: nil, eventId: eventId)
                x.dropInvite(id)
                app.mail.toast(MailToast(text: "Removed from your calendar", symbol: "calendar.badge.minus"))
                await app.syncNow()
            } catch {
                app.mail.toast(MailToast(text: InviteResponder.describe(error), symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }

    static func responseText(_ r: String) -> String? {
        switch r {
        case "accepted": "You accepted"
        case "tentativelyAccepted": "You replied tentative"
        case "declined": "You declined"
        case "organizer": "You're the organiser"
        default: nil
        }
    }

    static func range(_ s: Date, _ e: Date, allDay: Bool) -> String {
        if allDay { return s.formatted(date: .complete, time: .omitted) + " · all day" }
        let sameDay = Calendar.current.isDate(s, inSameDayAs: e)
        return s.formatted(date: .complete, time: .shortened) + " – "
            + (sameDay ? e.formatted(date: .omitted, time: .shortened) : e.formatted(date: .abbreviated, time: .shortened))
    }
}

// MARK: - Unsubscribe bar (reader)

struct UnsubscribeBar: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var body: some View {
        let x = ReaderTools.shared
        if let u = x.unsubscribe(reader.header.id), !reader.policy.redactDetails, !x.unsubscribed.contains(reader.header.id) {
            HStack(spacing: 8) {
                NSymbol("envelope.badge", size: 13).foregroundStyle(.secondary)
                Text("This message is from a mailing list.").foregroundStyle(.secondary)
                Spacer()
                Button("Unsubscribe…") { ReaderUnsubscribe.start(u, reader: reader, app: app) }
                    .help(u.oneClickURL.map { "Asks first, then tells \($0.host ?? "the sender") you're unsubscribing" } ?? "Opens a draft unsubscribe email for you to send")
            }
            .font(.caption).padding(.horizontal, 18).padding(.vertical, 5)
            .background(app.theme.brand ? AnyShapeStyle(app.skin.soft) : AnyShapeStyle(.quaternary.opacity(0.3)))
            .alert("Unsubscribe?", isPresented: Bindable(x).showUnsubscribeConfirm) {
                Button("Unsubscribe", role: .destructive) { ReaderUnsubscribe.confirmOneClick(reader: reader, app: app) }
                Button("Cancel", role: .cancel) { x.unsubscribeConfirm = nil }
            } message: {
                Text("niivo will send an unsubscribe request to \(x.unsubscribeConfirm?.host ?? "the sender"). This tells the sender that your address is active. Nothing else is sent.")
            }
        }
    }
}

@MainActor
enum ReaderUnsubscribe {
    static func start(_ u: ListUnsubscribe, reader: ReaderState, app: AppModel) {
        if let url = u.oneClickURL {
            ReaderTools.shared.unsubscribeConfirm = url
            ReaderTools.shared.showUnsubscribeConfirm = true
        } else if let m = u.mailto.first, let d = ListUnsubscribe.draft(from: m) {
            // Draft only: the user reviews and sends it themselves.
            app.mail.compose()
            if let c = app.mail.composer {
                c.to = [EmailAddress(name: "", address: d.to)]
                c.subject = d.subject
                c.body = d.body
            }
            app.mail.toast(MailToast(text: "Unsubscribe email drafted — review and send it", symbol: "envelope"))
        } else if let url = u.https.first {
            NSWorkspace.shared.open(url)   // no one-click support: the sender's page opens; the user acts there
        }
    }

    static func confirmOneClick(reader: ReaderState, app: AppModel) {
        let x = ReaderTools.shared
        guard let url = x.unsubscribeConfirm, let host = url.host else { return }
        x.unsubscribeConfirm = nil
        let id = reader.header.id
        if app.mail.isFixtures {   // fixtures never leave the Mac
            x.unsubscribed.insert(id)
            app.mail.toast(MailToast(text: "Unsubscribed (fixture — nothing sent)", symbol: "checkmark"))
            return
        }
        Task { @MainActor in
            do {
                try await Unsubscriber.oneClick(url, confirmedHost: host)
                x.unsubscribed.insert(id)
                app.mail.toast(MailToast(text: "Unsubscribe request sent to \(host)", symbol: "checkmark"))
            } catch {
                app.mail.toast(MailToast(text: "\(host) didn't accept the unsubscribe request", symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }
}

// MARK: - Junk / block sender

@MainActor
enum ReaderJunk {
    static func junkFolder(_ app: AppModel, _ mb: String) -> MailFolder? { (app.mail.folders[mb] ?? []).first { $0.wellKnown == .junkemail } }
    static func inboxFolder(_ app: AppModel, _ mb: String) -> MailFolder? { (app.mail.folders[mb] ?? []).first { $0.wellKnown == .inbox } }

    /// Report to Microsoft (no server-side move), then move through the normal triage path (undo + local state).
    static func report(_ action: JunkReport, reader: ReaderState, app: AppModel) {
        let id = reader.header.id, mb = reader.mailbox
        let dest = action == .notJunk ? inboxFolder(app, mb) : junkFolder(app, mb)
        if let svc = app.mail.sync?.readerService, !app.mail.isFixtures {
            Task { _ = try? await svc.report(action, messageId: id, mailbox: mb, move: false) }
        }
        if let d = dest {
            let text = switch action { case .junk: "Reported as junk"; case .phish: "Reported as phishing"; case .notJunk: "Marked as not junk" }
            app.mail.triage(.move(toFolderId: d.id), id: id, text: text)
        }
    }

    static func block(reader: ReaderState, app: AppModel) {
        guard reader.mailbox == "me", let addr = reader.header.from?.address, let junk = junkFolder(app, "me"),
              let rule = BlockSender.rule(for: addr, junkFolderId: junk.id) else { return }
        Task { @MainActor in
            if await app.mail.saveRule(rule) {
                app.mail.toast(MailToast(text: "Blocked \(addr): an inbox rule now moves their mail to Junk", symbol: "hand.raised"))
                report(.junk, reader: reader, app: app)
            } else {
                app.mail.toast(MailToast(text: app.mail.ruleError ?? "Couldn't create the block rule", symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }
}

// MARK: - More menu items (inside ReaderActions' ⋯ menu)

struct ReaderMoreItems: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var body: some View {
        let p = reader.policy, trust = app.trust.effectivePolicy
        let printWhy = ReaderGates.print(p, devicePrint: trust.allowPrint)
        let sourceWhy = ReaderGates.source(p)
        let inJunk = ReaderJunk.junkFolder(app, reader.mailbox).map { $0.id == reader.header.folderId } ?? false
        Divider()
        Button("Print…") { ReaderPrint.print(reader, app: app) }.disabled(printWhy != nil || app.mail.rendered(reader) == nil)
        Button("Find in Message…") { ReaderFind.open() }.disabled(ReaderTools.shared.webView == nil)
        Button("View Source…") { ReaderSource.open(reader, app: app) }.disabled(sourceWhy != nil)
        Button("Save as .eml…") { ReaderSource.saveEML(reader, app: app) }
            .disabled(ReaderGates.saveEML(p, deviceCopyOut: trust.allowCopyOut) != nil)
        if let why = printWhy ?? sourceWhy { Text(why) }
        Divider()
        if inJunk {
            Button("Not Junk") { ReaderJunk.report(.notJunk, reader: reader, app: app) }
        } else {
            Button("Report Junk") { ReaderJunk.report(.junk, reader: reader, app: app) }
            Button("Report Phishing") { ReaderJunk.report(.phish, reader: reader, app: app) }
        }
        Button("Block \(p.redactDetails ? "Sender" : (reader.header.from?.address ?? "Sender"))") { ReaderJunk.block(reader: reader, app: app) }
            .disabled(reader.mailbox != "me" || reader.header.from == nil || ReaderJunk.junkFolder(app, "me") == nil)
            .help("Graph has no blocked-senders list: this creates an inbox rule that moves their mail to Junk")
        if let u = ReaderTools.shared.unsubscribe(reader.header.id) {
            Button("Unsubscribe…") { ReaderUnsubscribe.start(u, reader: reader, app: app) }
        }
    }
}
