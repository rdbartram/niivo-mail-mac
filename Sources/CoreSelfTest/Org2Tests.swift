import Foundation
import CalendarCore
import MailCore

// Organisation part 2: favourites order persistence, filter lists, ignore-conversation sweep, trays, VIP store,
// Quick Step plans, group management request shapes, findMeetingTimes request/parse + local fallback.

@MainActor
func runOrg2Tests() async {
    org2FavouritesTests()
    org2SweepTrayVIPTests()
    org2QuickStepTests()
    await org2GroupManageTests()
    await org2FindMeetingTimesTests()
}

private func o2(_ id: String, folder: String, conv: String = "c1", cats: [String] = [], flagged: Bool = false, read: Bool = false,
                from: String = "a@contoso.example", to: [String] = [], cc: [String] = [], draft: Bool = false) -> MailMessage {
    var m = MailMessage(id: id, folderId: folder, conversationId: conv, subject: "S", from: EmailAddress(name: "A", address: from),
                        toRecipients: to.map { EmailAddress(name: "", address: $0) }, received: Date(timeIntervalSince1970: 1_800_000_000),
                        isRead: read, flag: FollowUpFlag(status: flagged ? .flagged : .notFlagged), categories: cats)
    m.ccRecipients = cc.map { EmailAddress(name: "", address: $0) }
    m.isDraft = draft
    return m
}

private let wk: @Sendable (WellKnownFolder, String) -> String? = { w, mb in
    switch w { case .deleteditems: "del-\(mb)"; case .archive: "arc-\(mb)"; case .sentitems: "sent-\(mb)"; case .drafts: "dr-\(mb)"; default: nil }
}

@MainActor private func org2FavouritesTests() {
    section("Favourites: order, reorder, prune, sealed persistence, migration")
    do {
        let store = try mailStore()
        var (l, migrated) = FavouritesList.load(store, legacyFolders: [("f1", "me"), ("f2", "shared@contoso.example")])
        check(migrated && l.items.map(\.id) == ["folder:f1", "folder:f2", "tray:replyLater", "tray:setAside"], "legacy folder pins migrated with their mailbox; trays pinned on first run")
        l.remove(.tray(.setAside))
        l.add(.person(address: "Bob@Contoso.example", name: "Bob"))
        l.add(.category("Red"))
        l.add(.smart(.unread))
        l.add(.group(id: "g1", name: "Alpha"))
        l.add(.tray(.replyLater))   // already there
        l.add(.vip)
        l.add(.category("red"))   // duplicate (case-insensitive id)
        check(l.items.count == 8, "duplicates not added")
        l.move("vip", before: "folder:f1")
        l.move("folder:f2", before: nil)
        check(l.items.first?.id == "vip" && l.items.last?.id == "folder:f2", "drag reorder: before a row / to the end")
        l.persist(store)
        let back = FavouritesList.load(store, legacyFolders: [("zzz", "me")])
        check(!back.migrated && back.list == l, "order round-trips through the sealed store; migration runs once")
        var p = l
        p.prune(knownFolders: ["f1"], loadedMailboxes: ["me"])
        check(p.contains(.folder(id: "f2", mailbox: "shared@contoso.example")), "pins of an unloaded shared mailbox survive a prune")
        p.prune(knownFolders: [], loadedMailboxes: ["me", "shared@contoso.example"])
        check(!p.contains(.folder(id: "f1", mailbox: "me")) && p.contains(.person(address: "bob@contoso.example", name: "")) && p.contains(.group(id: "g1", name: "")),
              "missing folders of loaded mailboxes pruned; people / groups never")
        let raw = (try? store.value(for: FavouritesList.key)) ?? nil
        check(raw.map { !$0.contains("Bob") && !$0.contains("Red") } ?? false, "stored sealed (no plaintext names)")
    } catch { check(false, "favourites threw \(error)") }

    section("Filter lists: ids round-trip, routed as virtual folders")
    let lists: [FilterList] = [.person(address: "Bob@contoso.example", mailbox: "me"), .category("Project: X", mailbox: "me"),
                               .vip(mailbox: "shared@contoso.example"), .tray(.setAside, mailbox: "me")]
    for l in lists {
        let v = VirtualFolder.list(l)
        guard case .list(let back)? = VirtualFolder(id: v.id) else { check(false, "\(l) didn't parse"); continue }
        if case .person(let a, _) = l { check(back == .person(address: a.lowercased(), mailbox: "me"), "person id lower-cased") }
        else { check(back == l, "\(l.title) id round-trips (colons in the name kept)") }
    }
    check(VirtualFolder(id: VirtualFolder.smart(.unread, mailbox: "me").id) == .smart(.unread, mailbox: "me"), "smart view ids unchanged")
    check(VirtualFolder(id: "AAMkAD-real-folder") == nil, "a Graph folder id is not virtual")
    let m1 = o2("m1", folder: "inbox", from: "x@contoso.example", cc: ["bob@contoso.example"])
    check(MailFilterQuery.involves(m1, "BOB@contoso.example") && !MailFilterQuery.involves(m1, "eve@contoso.example"), "person view matches From/To/Cc")
    check(!MailFilterQuery.personExcluded.contains(.sentitems), "person view includes Sent Items")
}

@MainActor private func org2SweepTrayVIPTests() {
    section("Ignore conversation: client-side sweep")
    var ig = IgnoredConversations()
    ig.ignore("c1", mailbox: "me", at: Date(timeIntervalSince1970: 1_799_000_000))
    var older = o2("older", folder: "inbox")
    older.received = Date(timeIntervalSince1970: 1_798_000_000)
    check(ig.sweep([BulkTarget(message: older, mailbox: "me")], folder: wk).isEmpty,
          "messages from before Ignore (e.g. restored by ⌘Z) aren't swept again")
    let targets = [
        BulkTarget(message: o2("new", folder: "inbox"), mailbox: "me"),
        BulkTarget(message: o2("deleted", folder: "del-me"), mailbox: "me"),
        BulkTarget(message: o2("sent", folder: "sent-me"), mailbox: "me"),
        BulkTarget(message: o2("draft", folder: "inbox", draft: true), mailbox: "me"),
        BulkTarget(message: o2("other", folder: "inbox", conv: "c2"), mailbox: "me"),
        BulkTarget(message: o2("shared", folder: "inbox-s"), mailbox: "shared@contoso.example"),
    ]
    let steps = ig.sweep(targets, folder: wk)
    check(steps == [BulkStep(messageId: "new", action: .delete)], "only new arrivals of the ignored conversation move to Deleted Items")
    do {
        let store = try mailStore()
        ig.persist(store)
        check(IgnoredConversations.load(store).contains("c1", mailbox: "ME"), "ignored set sealed; mailbox case-insensitive")
        ig.stop("c1", mailbox: "me")
        check(ig.sweep(targets, folder: wk).isEmpty, "stop ignoring → nothing swept")
    } catch { check(false, "ignore store threw \(error)") }

    section("Reply Later / Set Aside trays: one categorise + flag")
    let plain = o2("p", folder: "inbox", cats: ["Blue"])
    check(MailTray.plan(.replyLater, message: plain, on: true) == [.categorize(["Blue", "Reply Later"]), .flag(FollowUpFlag(status: .flagged))],
          "into the tray: category added (kept), flagged")
    let both = o2("b", folder: "inbox", cats: ["Reply Later", "Set Aside"], flagged: true)
    check(MailTray.plan(.replyLater, message: both, on: false) == [.categorize(["Set Aside"])], "out of one tray keeps the flag while another holds it")
    let one = o2("o", folder: "inbox", cats: ["reply later"], flagged: true)
    check(MailTray.plan(.replyLater, message: one, on: false) == [.categorize([]), .flag(FollowUpFlag(status: .notFlagged))], "last tray out clears the flag")
    check(MailTray.plan(.replyLater, message: one, on: true).isEmpty, "already in → no-op")

    section("VIPStore: shared, case-insensitive, sealed")
    do {
        let store = try mailStore()
        let v = VIPStore.shared(for: store)
        check(VIPStore.shared(for: store) === v && VIPStore.current === v, "one instance per store; becomes current")
        v.add(" Boss@Contoso.example ")
        v.add("not-an-address")
        check(v.contains("boss@contoso.EXAMPLE") && !v.contains("") && v.all == ["boss@contoso.example"], "contains is case-insensitive; junk refused")
        check(VIPStore(store: store).contains("boss@contoso.example"), "persisted (a fresh reader sees it)")
        v.remove("BOSS@contoso.example")
        check(!v.contains("boss@contoso.example") && !VIPStore(store: store).contains("boss@contoso.example"), "removed + persisted")
        let raw = (try? store.value(for: VIPStore.key)) ?? nil
        v.add("boss@contoso.example")
        let raw2 = (try? store.value(for: VIPStore.key)) ?? nil
        check(raw != nil && raw2.map { !$0.contains("boss") } ?? false, "stored sealed")
        VIPStore.reset()
        check(VIPStore.current.isEmpty, "reset → empty in-memory current")
        let rows = FilterList.vip(mailbox: "me").rows(store: store, vips: { v.contains($0) })
        check(rows.isEmpty, "VIP list over an empty store is empty")
    } catch { check(false, "VIP store threw \(error)") }
}

@MainActor private func org2QuickStepTests() {
    section("Quick Steps: plans and validation")
    let tpl = UUID()
    let qs = QuickStep(name: "Done", actions: [.move(folderId: "proj-me", mailbox: "me", folderName: "Project"), .categorise("Red"),
                                                .categorise("Blue"), .markRead(true), .flag(false), .replyWithTemplate(templateId: tpl, name: "Thanks")], shortcut: 3)
    let m = o2("m", folder: "inbox", cats: ["Green"], flagged: true)
    let p = QuickStepPlanner.plan(qs, targets: [BulkTarget(message: m, mailbox: "me")], folder: wk)
    check(p.steps.map(\.action) == [.categorize(["Green", "Red", "Blue"]), .flag(FollowUpFlag(status: .notFlagged)), .markRead(true), .move(toFolderId: "proj-me")],
          "categories folded into one categorise; move last")
    check(p.reply?.messageId == "m" && p.reply?.templateId == tpl && p.removesFromList, "single target → reply with the template")
    let other = BulkTarget(message: o2("s", folder: "inbox-s"), mailbox: "shared@contoso.example")
    let p2 = QuickStepPlanner.plan(qs, targets: [BulkTarget(message: m, mailbox: "me"), other], folder: wk)
    check(p2.reply == nil && p2.skippedReply, "reply skipped for a multi-selection")
    check(!p2.steps.contains { $0.messageId == "s" && $0.action == .move(toFolderId: "proj-me") }, "move never crosses mailboxes")
    let arch = QuickStepPlanner.plan(QuickStep(name: "A", actions: [.archive, .tray(.replyLater)]), targets: [BulkTarget(message: o2("x", folder: "arc-me"), mailbox: "me")], folder: wk)
    check(arch.steps.map(\.action) == [.categorize(["Reply Later"]), .flag(FollowUpFlag(status: .flagged))] && !arch.removesFromList,
          "already archived → no move; tray = category + flag")
    let st = [BulkStep(messageId: "m", action: .categorize(["Green"])), BulkStep(messageId: "m", action: .flag(FollowUpFlag(status: .flagged)))]
    let mv = [BulkStep(messageId: "m", action: .move(toFolderId: "inbox"))]
    check(QuickStepPlanner.undoOrder(state: st, moves: mv).map(\.action) == [.flag(FollowUpFlag(status: .flagged)), .categorize(["Green"]), .move(toFolderId: "inbox")],
          "undo: state inverses newest first, the move back last")
    var lib = QuickStepLibrary(steps: [qs])
    check(lib.problems(QuickStep(name: "", actions: [])).count == 2, "name + action required")
    check(lib.problems(QuickStep(name: "X", actions: [.archive, .delete])).contains("Use only one of Move, Archive or Delete"), "one terminal action")
    check(lib.problems(QuickStep(name: "X", actions: [.flag(true)], shortcut: 3)) == ["^⇧3 is already used"], "shortcut clash")
    check(lib.problems(qs).isEmpty, "editing a step keeps its own shortcut")
    do {
        let store = try mailStore()
        lib.upsert(QuickStep(name: "Two", actions: [.markRead(true)], shortcut: 2))
        lib.persist(store)
        let back = QuickStepLibrary.load(store)
        check(back == lib && back.step(shortcut: 2)?.name == "Two", "library sealed + shortcut lookup")
    } catch { check(false, "quick step store threw \(error)") }
}

@MainActor private func org2GroupManageTests() async {
    section("Groups: members, files link, join / leave ($ref), follow in inbox, favourite (stub)")
    let flags = Flags()
    MailStub.log = []
    MailStub.handler = { req, body in
        let path = req.url!.path, m = req.httpMethod ?? "GET"
        switch (m, path) {
        case ("GET", "/v1.0/me"): return (200, [:], #"{"id":"me-id"}"#)
        case ("GET", "/v1.0/groups/g1/members/microsoft.graph.user"):
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer r" { flags.hit("readTok") }
            return (200, [:], #"{"value":[{"id":"u2","displayName":"Zed"},{"id":"u1","displayName":"Amy","mail":"amy@contoso.example","jobTitle":"PM"}]}"#)
        case ("GET", "/v1.0/groups/g1/drive"):
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer f" { flags.hit("filesTok") }
            return (200, [:], #"{"webUrl":"https://contoso.sharepoint.com/sites/g1/Shared%20Documents"}"#)
        case ("GET", "/v1.0/groups/g2/drive"): return (200, [:], #"{"webUrl":"javascript:alert(1)"}"#)
        case ("POST", "/v1.0/groups/g1/members/$ref"):
            let o = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            if o?["@odata.id"] as? String == "https://graph.microsoft.com/v1.0/directoryObjects/me-id" { flags.hit("joinShape") }
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer w" { flags.hit("writeTok") }
            return (204, [:], "")
        case ("POST", "/v1.0/groups/g9/members/$ref"): return (403, [:], #"{"error":{"code":"Authorization_RequestDenied"}}"#)
        case ("DELETE", "/v1.0/groups/g1/members/me-id/$ref"): flags.hit("leave"); return (204, [:], "")
        case ("POST", "/v1.0/groups/g1/subscribeByMail"), ("POST", "/v1.0/groups/g1/unsubscribeByMail"),
             ("POST", "/v1.0/groups/g1/addFavorite"), ("POST", "/v1.0/groups/g1/removeFavorite"):
            flags.hit(String(path.split(separator: "/").last!))
            return (204, [:], "")
        default: return (404, [:], #"{"error":{"code":"NotFound"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let gsvc = GraphGroupsService(readToken: { "r" }, writeToken: { "w" }, session: URLSession(configuration: cfg))
    do {
        let mem = try await gsvc.members(groupId: "g1", top: 100)
        check(mem.map(\.displayName) == ["Amy", "Zed"] && mem.first?.jobTitle == "PM" && flags.count("readTok") == 1, "members (users only, sorted) on the read token")
        let u = try await gsvc.filesURL(groupId: "g1", filesToken: { "f" })
        check(u?.host == "contoso.sharepoint.com" && flags.count("filesTok") == 1, "files webUrl via the OneDrive token")
        check(try await gsvc.filesURL(groupId: "g2", filesToken: nil) == nil, "non-https webUrl refused")
        try await gsvc.join(groupId: "g1")
        check(flags.count("joinShape") == 1 && flags.count("writeTok") == 1, "join → POST members/$ref {@odata.id: directoryObjects/me}")
        try await gsvc.leave(groupId: "g1")
        check(flags.count("leave") == 1 && MailStub.captured().contains { $0.path.hasSuffix("/members/me-id/$ref") }, "leave → DELETE …/members/{me}/$ref (never the object)")
        do { try await gsvc.join(groupId: "g9"); check(false, "403 join should throw") }
        catch { check(error as? GroupManageError == .notAllowed, "403 → notAllowed (members can't add themselves in most tenants)") }
        try await gsvc.setFollowInInbox(groupId: "g1", true)
        try await gsvc.setFollowInInbox(groupId: "g1", false)
        try await gsvc.setFavourite(groupId: "g1", true)
        try await gsvc.setFavourite(groupId: "g1", false)
        check(["subscribeByMail", "unsubscribeByMail", "addFavorite", "removeFavorite"].allSatisfy { flags.count($0) == 1 }, "follow / unfollow / favourite / unfavourite POSTs")
    } catch { check(false, "group manage threw \(error)") }
    MailStub.handler = nil
}

@MainActor private func org2FindMeetingTimesTests() async {
    section("Find a time: findMeetingTimes request/parse, local fallback")
    let from = Date(timeIntervalSince1970: 1_800_000_000), to = from.addingTimeInterval(5 * 86_400)
    do {
        let body = try FindMeetingTimes.body(attendees: ["a@contoso.example", "junk"], from: from, to: to, minutes: 45)
        let o = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let att = o?["attendees"] as? [[String: Any]]
        let slots = ((o?["timeConstraint"] as? [String: Any])?["timeSlots"] as? [[String: Any]])
        let start = slots?.first?["start"] as? [String: String]
        check(att?.count == 1 && (att?.first?["emailAddress"] as? [String: String])?["address"] == "a@contoso.example", "attendees: addresses only, required")
        check(o?["meetingDuration"] as? String == "PT45M" && start?["timeZone"] == "UTC" && start?["dateTime"]?.count == 19, "ISO duration; UTC dateTimeTimeZone")
        let json = #"{"emptySuggestionsReason":"","meetingTimeSuggestions":[{"confidence":50,"organizerAvailability":"free","meetingTimeSlot":{"start":{"dateTime":"2027-01-15T09:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2027-01-15T09:45:00.0000000","timeZone":"UTC"}}},{"confidence":100,"organizerAvailability":"free","suggestionReason":"Suggested because it is one of the nearest times when all attendees are available.","meetingTimeSlot":{"start":{"dateTime":"2027-01-15T13:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2027-01-15T13:45:00.0000000","timeZone":"UTC"}}}]}"#
        let r = try FindMeetingTimes.parse(Data(json.utf8))
        check(r.suggestions.count == 2 && r.suggestions.first?.confidence == 100 && r.emptyReason == nil, "suggestions parsed, best confidence first")
        check(r.suggestions.first.map { $0.end.timeIntervalSince($0.start) } == 45 * 60, "slot times parsed in UTC")
        let empty = try FindMeetingTimes.parse(Data(#"{"emptySuggestionsReason":"attendeesUnavailable","meetingTimeSuggestions":[]}"#.utf8))
        check(empty.suggestions.isEmpty && empty.emptyReason == "attendeesUnavailable", "empty reason surfaced (→ app falls back)")
    } catch { check(false, "findMeetingTimes threw \(error)") }
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let monday = cal.date(from: DateComponents(year: 2027, month: 1, day: 11, hour: 7))!
    let busy = CalendarEvent(id: "e", calendarId: "c", subject: "Busy", start: cal.date(bySettingHour: 8, minute: 0, second: 0, of: monday)!,
                             end: cal.date(bySettingHour: 12, minute: 0, second: 0, of: monday)!)
    let local = FindMeetingTimes.localSlots(events: [busy], from: monday, days: 1, minutes: 30, calendar: cal)
    check(local.first.map { cal.component(.hour, from: $0.start) } == 12 && local.allSatisfy { $0.end.timeIntervalSince($0.start) == 1_800 },
          "local fallback: first free slot after the busy block, requested length")
    await org2FindClientStub(from: from, to: to)
    let sat = cal.date(from: DateComponents(year: 2027, month: 1, day: 16, hour: 7))!
    check(FindMeetingTimes.localSlots(events: [], from: sat, days: 2, minutes: 30, calendar: cal).isEmpty, "weekends skipped")
}
