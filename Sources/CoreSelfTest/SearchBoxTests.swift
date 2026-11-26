import Foundation
import CryptoKit
import CalendarCore
import MailCore

// SEARCHBOX: the main mail-list search box — operator / free-text split, strict operators with natural ranking,
// scope, sort toggle, sealed recent searches, suggestions, highlight, and privacy (local + server-returned rows).

@MainActor
func runSearchBoxTests() async {
    section("Search box: operators strict, free words natural")
    let now = Date()
    var q = SearchQuery.parse("rechnung from:\"Anna Meier\" subject:offerte category:Blue \"projekt phoenix\" has:attachment is:unread older_than:1y newer_than:3y lieferung", now: now)
    check(q.words == ["rechnung", "projekt phoenix", "lieferung"] && q.from == ["anna meier"] && q.subjectWords == ["offerte"]
          && q.categories == ["blue"] && q.hasAttachment == true && q.isUnread == true && q.before != nil && q.after != nil,
          "split: free words vs Gmail operators (\(q.words), \(q.from), \(q.subjectWords))")
    check(q.phrases == ["projekt phoenix"], "an operator's quoted value isn't a phrase; a bare quoted phrase is (\(q.phrases))")
    q = SearchQuery.parse("hasattachments:yes isread:no", now: now)
    check(q.hasAttachment == true && q.isUnread == true && q.words.isEmpty, "Outlook-style operators (hasattachments:, isread:)")
    check(SearchQuery.parse("subject:budget").hasFilters && !SearchQuery.parse("subject:budget").isEmpty, "subject: alone is a query")
    check(MailSearchBox.serverText(SearchQuery.parse("from:anna@x.example is:unread")) == nil
          && MailSearchBox.serverText(SearchQuery.parse("Rechnung \"Projekt Phoenix\" from:anna")) == "Rechnung Projekt Phoenix",
          "server $search gets free words + phrases only; operator-only queries stay local")
    check(MailSearchBox.shouldAskServer(typing: false, localCount: 50) && MailSearchBox.shouldAskServer(typing: true, localCount: 2)
          && !MailSearchBox.shouldAskServer(typing: true, localCount: 30), "server merge: on ↩, or while typing only when local hits are few")

    section("Search box: ranked search, scope, sort, privacy")
    do {
        let s = try MailStore(url: nil, key: SymmetricKey(size: .bits256))
        let eng = mailEngine()
        let L = FixtureCalendarService.labels
        s.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) }
        try s.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox),
                                MailFolder(id: "arch", displayName: "Archive", wellKnown: .archive)], mailbox: "me")
        try s.replace(folders: [MailFolder(id: "sh-inbox", displayName: "Inbox", wellKnown: .inbox, mailbox: "team@niivo-test.example")],
                      mailbox: "team@niivo-test.example")
        let base = now.addingTimeInterval(-10 * 86_400)
        func mk(_ id: String, _ subject: String, _ from: String, _ preview: String, day: Double, folder: String = "inbox",
                label: String? = nil, att: Bool = false, read: Bool = true, cats: [String] = [], priv: Bool = false) -> MailMessage {
            var m = MailMessage(id: id, folderId: folder, conversationId: id, subject: subject,
                                from: EmailAddress(name: from, address: from.lowercased().replacingOccurrences(of: " ", with: ".") + "@fabrikam-test.example"),
                                received: base.addingTimeInterval(day * 86_400), preview: preview, hasAttachments: att, labelId: label, isPrivate: priv)
            m.isRead = read; m.categories = cats
            return m
        }
        try s.upsert(messages: [
            mk("b1", "Rechnung Serverschränke", "Anna Meier", "Anbei die Rechnung für Projekt Phoenix", day: 1, att: true, read: false),
            mk("b2", "Projekt Phoenix Kick-off", "Peter Muster", "Agenda und Rechnung folgen", day: 5),
            mk("b3", "Phoenix Projekt Notizen", "Peter Muster", "lose Notizen", day: 6, folder: "arch", cats: ["Blue"]),
            mk("b4", "Rechnung Fabrikam geheim", "Legal Desk", "Projekt Phoenix Vergleich", day: 7, label: L[3].id),   // protected
            mk("b5", "Rechnung privat", "Nina Graf", "Projekt Phoenix privat", day: 8, folder: "sh-inbox", priv: true),   // private, delegated
            mk("b6", "Rechnung Team", "Anna Meier", "Projekt Phoenix Teampostfach", day: 9, folder: "sh-inbox"),
            // (A private item in the user's own mailbox is theirs: fully searchable, like SearchHub.)
        ])
        func run(_ text: String, scope: MailSearchScope = .mailbox, folder: String? = "inbox", typing: Bool = true) -> [String] {
            MailSearchBox.local(.init(text: text, scope: scope, mailbox: "me", folderId: folder,
                                      allMailboxes: ["me", "team@niivo-test.example"], typing: typing, now: now), store: s).ranked.map(\.id)
        }
        // Natural: "rechnung phoenix" — rows with both rank above rows with one; typed prefix (no trailing space) works.
        let nat = run("rechnung phoenix")
        check(nat.first == "b1" && nat.contains("b2") && nat.contains("b3"), "natural while typing: ranked, OR-ed concepts (\(nat))")
        check(run("rechn").contains("b1"), "typed prefix without a trailing space matches")
        check(run("Rechnung", typing: false).first == "b1", "↩ runs natural too")
        // Strict operators.
        check(run("phoenix from:peter").allSatisfy { ["b2", "b3"].contains($0) } && !run("phoenix from:peter").isEmpty, "from: strict, free words ranked")
        check(run("subject:kick").elementsEqual(["b2"]), "subject: strict (prefix of a subject word) (\(run("subject:kick")))")
        check(run("phoenix category:blue").elementsEqual(["b3"]), "category: strict")
        check(run("phoenix is:unread").elementsEqual(["b1"]) && run("phoenix has:attachment").elementsEqual(["b1"]), "is:unread / has:attachment strict")
        let ph = run("\"projekt phoenix\" ")
        check(Set(ph) == ["b1", "b2"], "\"quoted phrase\" strict: adjacency in subject / preview (\(ph))")
        // Scope.
        check(!run("rechnung", scope: .folder, folder: "arch").contains("b1") && run("notizen", scope: .folder, folder: "arch") == ["b3"],
              "This folder scope filters before the limit")
        check(!run("teampostfach").contains("b6") && run("teampostfach", scope: .allMailboxes) == ["b6"], "All mailboxes scope adds added mailboxes")
        // Privacy: protected / private rows never match on subject / preview / phrase; only on their sender.
        for t in ["geheim ", "vergleich ", "\"projekt phoenix\" ", "subject:rechnung", "rechnung", "privat"] {
            let all = run(t, scope: .allMailboxes)
            check(!all.contains("b4") && !all.contains("b5"), "main box: protected/private rows never match on content ('\(t)')")
        }
        check(run("legal").contains("b4") && run("nina", scope: .allMailboxes).contains("b5"), "main box: protected / private rows still match on their sender")
        // Sort toggle: one result, two orders.
        var r = MailBoxResult(); r.ranked = [mk("x1", "a", "A", "", day: 1), mk("x2", "b", "B", "", day: 5)]; r.newest = [r.ranked[1], r.ranked[0]]
        check(r.messages(.bestMatch).map(\.id) == ["x1", "x2"] && r.messages(.newest).map(\.id) == ["x2", "x1"], "sort toggle: Best match keeps rank, Newest by date")
        check(MailSearchSort.allCases.first == .bestMatch, "Best match is the default")

        // Server hits: Graph matched protected content server-side — admitted only on the sender for those rows.
        let pq = SearchQuery.parse("vergleich ")
        let protRemote = mk("s1", "Vergleich", "Legal Desk", "Vergleich Entwurf", day: 2, label: L[3].id)
        let openRemote = mk("s2", "Vergleich offen", "Peter Muster", "Vergleich Entwurf", day: 2)
        check(!MailSearchBox.admitServerHit(protRemote, query: pq, store: s, mailbox: "me", folderId: nil)
              && MailSearchBox.admitServerHit(openRemote, query: pq, store: s, mailbox: "me", folderId: nil),
              "server hit: a protected row matched on content is dropped, an open one kept")
        check(MailSearchBox.admitServerHit(protRemote, query: SearchQuery.parse("legal "), store: s, mailbox: "me", folderId: nil),
              "server hit: a protected row matched on its sender is kept")
        check(!MailSearchBox.admitServerHit(openRemote, query: SearchQuery.parse("vergleich is:unread"), store: s, mailbox: "me", folderId: nil)
              && !MailSearchBox.admitServerHit(openRemote, query: pq, store: s, mailbox: "me", folderId: "arch")
              && !MailSearchBox.admitServerHit(openRemote, query: pq, store: s, mailbox: "team@niivo-test.example", folderId: nil)
              && !MailSearchBox.admitServerHit(protRemote, query: SearchQuery.parse("legal subject:vergleich"), store: s, mailbox: "me", folderId: nil),
              "server hit: operators, folder scope, mailbox attribution and subject: (protected) apply locally")
        let merged = MailSearchBox.merge(r, server: [openRemote, r.ranked[0]], unattributed: 2, limit: 10)
        check(merged.ranked.map(\.id) == ["x1", "x2", "s2"] && merged.newest.map(\.id) == ["x2", "s2", "x1"] && merged.unattributed == 2 && merged.serverMerged,
              "merge: server-only hits after local in Best match, by date in Newest, de-duplicated")
        // Newest covers the whole match set, not a re-sort of the Best-match head.
        let wide = MailSearchBox.local(.init(text: "rechnung phoenix", scope: .mailbox, mailbox: "me", folderId: nil, allMailboxes: ["me"],
                                             limit: 1, typing: true, now: now), store: s)
        check(wide.ranked.count == 1 && wide.newest.count == 1 && wide.newest[0].received >= wide.ranked[0].received
              && wide.newest[0].id == "b3", "Newest = the newest matches overall even when the best match is older (\(wide.ranked.map(\.id)) / \(wide.newest.map(\.id)))")

        // Recent searches: sealed in the store, never plain text on disk.
        var mem = SearchMemory()
        mem.remember("rechnung phoenix"); mem.remember("from:anna@fabrikam-test.example")
        mem.persist(s)
        check(SearchMemory.load(s).recent == ["from:anna@fabrikam-test.example", "rechnung phoenix"], "recent searches round-trip through the sealed store")
        let raw = try s.value(for: SearchMemory.key)
        check(raw.map { !$0.contains("phoenix") && !(Data(base64Encoded: $0).map { String(decoding: $0, as: UTF8.self).contains("phoenix") } ?? true) } ?? false,
              "recent searches are sealed (no plaintext in the row)")
    } catch { check(false, "search box threw \(error)") }

    section("Search box: suggestions + highlight")
    let people = [(name: "Anna Meier", address: "anna.meier@fabrikam-test.example"), (name: "Peter Muster", address: "peter@contoso-test.example")]
    var sg = SearchSuggest.items(for: "fr", recent: ["from:peter@contoso-test.example", "rechnung"], people: people)
    check(sg.contains { $0.kind == .operator && $0.completion == "from:" } && sg.contains { $0.kind == .recent && $0.title.hasPrefix("from:peter") },
          "operators + recent for a bare token")
    sg = SearchSuggest.items(for: "rechnung from:an", recent: [], people: people)
    check(sg.first?.kind == .person && sg.first?.completion == "rechnung from:anna.meier@fabrikam-test.example ", "from: value → people")
    sg = SearchSuggest.items(for: "mei", recent: [], people: people)
    check(sg.contains { $0.kind == .person && $0.completion == "from:anna.meier@fabrikam-test.example " }, "a bare name token suggests the person as from:")
    check(SearchSuggest.items(for: "", recent: ["a1", "b2"], people: people).map(\.kind) == [.recent, .recent], "empty box: recent searches only")
    check(SearchSuggest.move(nil, by: 1, count: 3) == 0 && SearchSuggest.move(2, by: 1, count: 3) == 2 && SearchSuggest.move(0, by: -1, count: 3) == nil,
          "↓/↑ navigation, ↑ from the top returns to the field")
    let terms = SearchHighlight.terms("rechnung from:anna \"projekt phoenix\" subject:kick")
    check(terms == ["rechnung", "projekt", "phoenix", "kick"], "highlight terms: free words, phrase words, subject: words (\(terms))")
    let text = "Die Rechnungen für Projekt Phönix"
    let hl = SearchHighlight.ranges(in: text, terms: ["rechnung", "phonix"]).map { String(text[$0]) }
    check(hl == ["Rechnungen", "Phönix"], "highlight: prefix, case and diacritic insensitive (\(hl))")
}
