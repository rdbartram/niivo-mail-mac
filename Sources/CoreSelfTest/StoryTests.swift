import Foundation
import CryptoKit
import CalendarCore
import MailCore
import TrustCore
import OfficeTools

// Stories (StoryEngine): related messages across conversationIds, folders and mailboxes. Synthetic fixtures only;
// nothing here prints subjects, senders or bodies.

/// Deterministic stand-in for NLTagger: known names become entities, "14 May" becomes a date token.
struct StubStoryTagger: StoryEntityTagger {
    let known: [String]
    func entities(in text: String) -> [String] {
        let l = text.lowercased()
        var out = known.filter { l.contains($0) }
        if l.contains("14 may") { out.append("date:2027-05-14") }
        return out
    }
}

@MainActor
func runStoryTests() async {
    section("Stories: related mail across conversations, folders and mailboxes (on-device)")
    let L = FixtureCalendarService.labels
    let me = "owner@niivo-test.example", team = "team@niivo-test.example"
    let base = Date().addingTimeInterval(-6 * 86_400)
    func mk(_ id: String, folder: String = "inbox", subject: String, from: (String, String), to: [(String, String)] = [(me, "Owner")],
            preview: String? = nil, day: Double, label: String? = nil, att: [String] = []) -> MailMessage {
        MailMessage(id: id, folderId: folder, conversationId: "conv-" + id, subject: subject, from: EmailAddress(name: from.1, address: from.0),
                    toRecipients: to.map { EmailAddress(name: $0.1, address: $0.0) }, received: base.addingTimeInterval(day * 86_400),
                    preview: preview, hasAttachments: !att.isEmpty,
                    attachments: att.enumerated().map { AttachmentInfo(id: "a\($0.offset)", name: $0.element, contentType: "application/pdf", size: 1_000) },
                    labelId: label)
    }
    let hotel = ("booking@hotel-duomo-siena.example", "Hotel Duomo"), desk = ("reception@hotel-duomo-siena.example", "Reception")
    let billing = ("billing@hotel-duomo-siena.example", "Billing")
    let siena = ("siena.rossi@partner-agency.example", "Siena Rossi")
    let corpus: [MailMessage] = [
        // One trip: different conversations, two senders at the hotel, a rail operator, a sent mail, a shared mailbox.
        mk("t1", subject: "Booking confirmation Hotel Duomo Siena", from: hotel,
           preview: "Your stay in Siena from 14 May 2027 to 17 May 2027 is confirmed. Reference KX4471.", day: 0),
        mk("t2", subject: "Your arrival in Siena: parking and check-in", from: desk,
           preview: "Dear guest, parking near Hotel Duomo for your arrival on 14 May 2027.", day: 0.3),
        mk("t3", folder: "trav", subject: "E-ticket Firenze to Siena", from: ("tickets@rail-italia.example", "Rail Italia"),
           preview: "Your regional train from Firenze to Siena on 14 May 2027.", day: 0.5, att: ["Ticket_Siena_14May.pdf"]),
        mk("t4", folder: "sent", subject: "Siena plans", from: (me, "Owner"), to: [("partner@family-mail.example", "Partner")],
           preview: "Hotel Duomo is booked for 14 May to 17 May, train tickets from Firenze too.", day: 0.8),
        mk("t5", folder: "sh-inbox", subject: "Invoice Hotel Duomo Siena", from: hotel, to: [(team, "Team")],
           preview: "Invoice for your stay in Siena, 14 May 2027 to 17 May 2027.", day: 1.0),
        // Protected: same hotel, close in time → joins by metadata. Different company, Siena in its subject → must not.
        mk("p1", subject: "Siena deposit", from: billing, preview: "deposit details", day: 0.4, label: L[3].id),
        mk("p2", subject: "Siena quarterly secret", from: ("cfo@unrelated-corp.example", "CFO"), preview: "Siena Hotel Duomo figures", day: 0.5, label: L[3].id),
        // Unrelated.
        mk("u1", subject: "Budget review", from: ("lea@niivo-test.example", "Lea"), preview: "numbers for the quarterly budget", day: 2.5),
        mk("u2", subject: "Server patching window", from: ("max@contoso-build.example", "Max"), preview: "maintenance for the database servers", day: 3.5),
        // The owner's case: one person, one day, several conversations, nothing in common in the subjects.
        mk("s1", subject: "Contract draft", from: siena, preview: "first version attached", day: 4.0),
        mk("s2", subject: "Lunch on Friday?", from: siena, preview: "are you free", day: 4.1),
        mk("s3", subject: "Slides for the workshop", from: siena, preview: "deck for next week", day: 4.25),
    ]
    let eng = mailEngine()
    func newStore(url: URL? = nil, contentGate: Bool = true) throws -> MailStore {
        let s = try MailStore(url: url, key: SymmetricKey(size: .bits256))
        s.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) }
        try s.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox),
                                MailFolder(id: "sent", displayName: "Sent Items", wellKnown: .sentitems),
                                MailFolder(id: "trav", displayName: "Travel")], mailbox: "me")
        try s.replace(folders: [MailFolder(id: "sh-inbox", displayName: "Inbox", wellKnown: .inbox, mailbox: team)], mailbox: team)
        try s.enableCommGraph(owners: [me, team], internalDomains: ["niivo-test.example"])
        let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
        s.enableSemanticIndex(embedder: StubEmbedder(), windowDays: 90, policy: { m, mb in gate.exposure(m, mailbox: mb, tier: .onDevice) == .content })
        let content: StoryEngine.ContentGate = { m, mb in gate.exposure(m, mailbox: mb, tier: .onDevice) == .content }
        try s.enableStories(gate: contentGate ? content : nil,
                            tagger: StubStoryTagger(known: ["siena", "hotel duomo", "firenze"]))
        return s
    }
    func drain(_ s: MailStore) throws {
        while try s.semantic!.catchUp() > 0 {}
        while try s.stories!.catchUp() > 0 {}
    }
    do {
        let s = try newStore()
        try s.upsert(messages: corpus)
        check((s.stories?.pendingCount ?? 0) == corpus.count, "every new row is queued (\(s.stories?.pendingCount ?? -1))")
        check(try s.stories!.catchUp() == 0, "catch-up waits for vectors first")
        try drain(s)
        guard let st = s.stories else { return }
        let ids = { (id: String) in Set(st.story(messageId: id)?.members.map(\.id) ?? []) }
        let trip = ids("t1")
        check(["t1", "t2", "t3", "t4", "t5"].allSatisfy(trip.contains),
              "trip: 5 messages, 5 conversationIds, 2 hotel senders + rail + sent + shared mailbox → one story (\(trip.sorted()))")
        check(Set(st.story(messageId: "t1")?.members.map(\.mailbox) ?? []) == ["me", team], "story spans mailboxes")
        check(trip.contains("p1"), "protected mail from the same company, close in time, joins by metadata")
        check(!trip.contains("p2"), "protected mail sharing only words with the trip does NOT join (content never used)")
        let p2f = st.debugFeature(messageId: "p2"), p1f = st.debugFeature(messageId: "p1")
        check(p2f?.content == false && p2f?.tokens == 0 && p1f?.content == false && p1f?.tokens == 0, "protected rows carry no content features")
        check(!trip.contains("u1") && !trip.contains("u2") && ids("u1").count <= 1 && ids("u2").count <= 1, "unrelated mail stays out")
        check(ids("s1") == ["s1", "s2", "s3"], "burst from one person on one day groups across conversations (\(ids("s1").sorted()))")
        check(!ids("s1").contains("t1"), "the burst and the trip stay separate stories")
        // Correspondent boilerplate: one frequent sender, unrelated topics every other day, same signature block →
        // no story chain; two of their mails on one real topic still link.
        do {
            let anna = ("anna.muster@fabrikam-ag.example", "Anna Muster")
            let sig = " Freundliche Gruesse Anna Muster Fabrikam Bahnhofstrasse Zuerich Telefon Disclaimer vertraulich"
            let topics = ["Quarterly forecast spreadsheet questions", "Parking permit renewal office", "Printer toner reorder request",
                          "Holiday rota December coverage", "Aurora migration cutover plan", "Aurora migration rollback checklist"]
            let b = try newStore()
            let mails = topics.enumerated().map { i, t in
                mk("b\(i)", subject: t, from: anna, preview: t.lowercased() + "." + sig, day: Double(i) * 2.2 - 6)
            }
            try b.upsert(messages: mails)
            try drain(b)
            let bids = { (id: String) in Set(b.stories?.story(messageId: id)?.members.map(\.id) ?? []) }
            // The first two can't be told apart yet (one earlier message); from the third on the signature is known.
            check(bids("b2").count <= 1 && bids("b3").count <= 1 && (0..<4).allSatisfy { bids("b\($0)").count <= 2 },
                  "same sender + same signature, different topics → no story chain (\((0..<4).map { bids("b\($0)").count }))")
            check(bids("b4") == ["b4", "b5"], "same sender, shared topic terms → linked (\(bids("b4").sorted()))")
        }
        let keys = st.storyKeys(messageIds: corpus.map(\.id))
        check(keys["t1"]?.id == keys["t5"]?.id && keys["t1"]?.id != keys["s1"]?.id && keys["u1"] == nil, "storyKeys groups by story; singletons have none")
        let title = st.story(messageId: "t2")?.fallbackTitle ?? ""
        check(title.lowercased().contains("siena") && !title.contains("deposit"), "fallback title from allowed subjects only ('\(title.count) chars')")
        check(st.story(messageId: "t2")?.titleSubjects.contains { $0.contains("deposit") } == false, "protected subject never feeds the title")

        // Incremental: one new row → one unit of work, and it joins.
        try s.upsert(messages: [mk("t6", subject: "Restaurant table in Siena", from: ("info@osteria-siena.example", "Osteria"),
                                   preview: "Table for two on 14 May 2027 near Hotel Duomo.", day: 1.2)])
        check(st.pendingCount == 1, "incremental: a new message queues only itself")
        try drain(s)
        check(ids("t1").contains("t6"), "incremental: the new message joins the trip")
        // Re-upsert with only read state changed → no work.
        var r = corpus[0]; r.isRead = true
        try s.upsert(messages: [r])
        check(st.pendingCount == 0, "read/flag changes don't requeue")
        try s.deleteMessages(ids: ["t2"])
        check(!ids("t1").contains("t2") && ids("t1").contains("t5"), "deleting a member leaves the rest of the story")
        try s.deleteMessages(ids: ["t1"])
        check(ids("t3").isSuperset(of: ["t3", "t4", "t5"]), "deleting the oldest (hub) message keeps the trip together (\(ids("t3").sorted()))")
    } catch { check(false, "stories threw \(error)") }

    section("Stories: metadata only (no content gate, e.g. BYOD on-device = metadataOnly)")
    do {
        let s = try newStore(contentGate: false)
        try s.upsert(messages: corpus)
        try drain(s)
        guard let st = s.stories else { return }
        let ids = { (id: String) in Set(st.story(messageId: id)?.members.map(\.id) ?? []) }
        check(corpus.allSatisfy { st.debugFeature(messageId: $0.id)?.tokens == 0 }, "no content features at all")
        check(ids("s1") == ["s1", "s2", "s3"], "burst still groups by metadata")
        check(ids("t1").isSuperset(of: ["t1", "t2"]) && !ids("t1").contains("t3"), "same company close in time groups; content-only links don't")
    } catch { check(false, "metadata stories threw \(error)") }

    section("Stories: nothing plaintext on disk")
    do {
        let dir = FileManager.default.temporaryDirectory.appending(path: "storytest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "m.sqlite")
        let s = try newStore(url: url)
        try s.upsert(messages: corpus)
        try drain(s)
        check((s.stories?.featureCount ?? 0) == corpus.count, "every row has a sealed feature record")
        var bytes = Data()
        for suffix in ["", "-wal", "-shm"] { if let d = try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) { bytes.append(d) } }
        let needles = ["siena", "duomo", "firenze", "kx4471", "hotel-duomo", "rail-italia", "partner-agency", "deposit", "osteria",
                       "date:2027", "ticket_siena", "workshop", "Rossi"]
        let found = needles.filter { n in bytes.range(of: Data(n.utf8)) != nil || bytes.range(of: Data(n.lowercased().utf8)) != nil
            || bytes.range(of: Data(n.capitalized.utf8)) != nil }
        check(bytes.count > 10_000 && found.isEmpty, "sqlite + WAL contain no fixture names, places, entities or dates (\(found.count) found)")
        s.stories?.dropMemory()
        check(Set(s.stories?.story(messageId: "t1")?.members.map(\.id) ?? []).contains("t5"), "stories reload from the sealed records")
        try s.wipe()
        check(s.stories?.featureCount == 0 && s.stories?.pendingCount == 0, "wipe clears story tables")
    } catch { check(false, "story disk scan threw \(error)") }

    check(StoryTitles.sanitise("\"Siena trip, May.\"\nextra") == "Siena trip, May", "on-device title is cut to one clean line")
    check(StoryTitles.sanitise("<b>x</b>") == nil, "markup in a model title is refused")

    section("Tool: story_context (gated like project_context)")
    var c = ServerConfig(); c.allowDrafts = false; c.allowTriage = false
    guard let b = try? await Backend.make(c) else { check(false, "fixture backend"); return }
    let srv = MCPServer.agent(backend: b, audit: AuditSink.make(fixtures: true, path: nil))
    check(srv.toolNames.contains("story_context"), "agent server offers story_context")
    func o(_ s: String) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]) ?? [:] }
    let ok = await srv.callTool("story_context", argumentsJSON: "{\"message_id\":\"\(FixtureMailService.Special.general)\"}")
    let ob = o(ok.text)
    check(!ok.isError && ((ob["messages"] as? [Any])?.count ?? 0) >= 1 && ob["title"] != nil, "story_context: messages + title")
    check(!ok.text.contains(FixtureMailService.Special.privateMsg), "story_context: private item never returned")
    let priv = await srv.callTool("story_context", argumentsJSON: "{\"message_id\":\"\(FixtureMailService.Special.privateMsg)\"}")
    let unk = await srv.callTool("story_context", argumentsJSON: "{\"message_id\":\"no-such-id\"}")
    check(priv.isError && unk.isError && priv.text == unk.text && priv.messageIds.isEmpty, "a hidden seed is indistinguishable from an unknown id")
    check(await srv.callTool("story_context", argumentsJSON: "{}").isError, "story_context needs a selector")
    var cOff = ServerConfig(); cOff.allowDrafts = false; cOff.allowTriage = false; cOff.aiAccessOverride = .off
    if let bo = try? await Backend.make(cOff) {
        let so = MCPServer.agent(backend: bo, audit: AuditSink.make(fixtures: true, path: nil))
        let r = await so.callTool("story_context", argumentsJSON: "{\"message_id\":\"\(FixtureMailService.Special.general)\"}")
        check(r.isError && r.messageIds.isEmpty, "AI off: story_context refuses")
    }
}

// MARK: - Bench (CC_STORY_BENCH=1; CC_STORY_N rows, default 100k)

@MainActor
func runStoryBenchmark() async {
    let env = ProcessInfo.processInfo.environment
    guard env["CC_STORY_BENCH"] == "1" else { return }
    let n = Int(env["CC_STORY_N"] ?? "") ?? 100_000
    await runStoryBenchmark(n: n, content: true)
    await runStoryBenchmark(n: n, content: false)
}

@MainActor
func runStoryBenchmark(n: Int, content: Bool) async {
    section("Story benchmark: \(n) headers, \(content ? "content + metadata" : "metadata only"), stub tagger + synthetic vectors (temp DB) — timings on stderr")
    func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    do {
        let dir = FileManager.default.temporaryDirectory.appending(path: "storybench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MailStore(url: dir.appending(path: "b.sqlite"), key: SymmetricKey(size: .bits256))
        let eng = mailEngine()
        store.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: eng) }
        try store.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox),
                                    MailFolder(id: "sent", displayName: "Sent", wellKnown: .sentitems)], mailbox: "me")
        try store.enableCommGraph(owners: ["owner@bench.example"], internalDomains: ["bench.example"])
        let sem = store.enableSemanticIndex(embedder: nil, windowDays: 400, policy: { _, _ in true })
        let benchGate: StoryEngine.ContentGate = { m, _ in !m.id.hasSuffix("7") }
        let st = try store.enableStories(gate: content ? benchGate : nil, tagger: nil, windowDays: 400)

        var rnd: UInt64 = 0x570E
        func r(_ k: Int) -> Int { rnd = rnd &* 6364136223846793005 &+ 1442695040888963407; return Int((rnd >> 33) % UInt64(k)) }
        func zipf(_ k: Int) -> Int { let u = Double(r(1_000_000) + 1) / 1_000_001; return min(k - 1, Int(pow(Double(k), u)) - 1) }
        let vocab = (0..<2_000).map { "w\(String($0, radix: 36))x" }
        let domains = (0..<300).map { $0 % 10 == 0 ? "gmail.com" : "org\($0).example" }
        let people = (0..<3_000).map { i in EmailAddress(name: "P\(i)", address: "p\(i)@\(domains[i % 300])") }
        let owner = EmailAddress(name: "Owner", address: "owner@bench.example")
        let span = 360.0 * 86_400, t0 = Date().addingTimeInterval(-span - 3_600)
        func message(_ i: Int, at: Date) -> MailMessage {
            let p = people[zipf(people.count)]
            let subj = (0..<4).map { _ in vocab[zipf(vocab.count)] }.joined(separator: " ")
            let prev = (0..<10).map { _ in vocab[zipf(vocab.count)] }.joined(separator: " ")
            let sent = r(8) == 0
            return MailMessage(id: "b\(i)", folderId: sent ? "sent" : "inbox", conversationId: "bc\(i)", subject: subj,
                               from: sent ? owner : p, toRecipients: sent ? [p] : [owner], received: at, preview: prev)
        }
        var msgs: [MailMessage] = []
        for i in 0..<n { msgs.append(message(i, at: t0.addingTimeInterval(span * Double(i) / Double(n)))) }
        var t = Date()
        try store.bulkUpsert(msgs)
        err(String(format: "  upsert %d rows: %.1f s", n, Date().timeIntervalSince(t)))
        while try sem.catchUp(maxItems: 5_000) > 0 {}
        let centroids = (0..<400).map { _ in (0..<64).map { _ in Float(r(2001) - 1000) / 1000 } }
        try sem.putBulk(msgs.enumerated().map { i, m in
            (m.id, EmbeddedText(space: 1, vector: centroids[i % 400].map { $0 + Float(r(801) - 400) / 1000 }))
        })
        t = Date()
        var done = 0
        while true { let k = try st.catchUp(maxItems: 2_000); if k == 0 { break }; done += k }
        let total = Date().timeIntervalSince(t)
        err(String(format: "  initial linking: %d rows in %.1f s = %.2f ms/row", done, total, total * 1000 / Double(max(1, done))))
        // Incremental: 200 new rows on top of the full index.
        let extra = (0..<200).map { message(n + $0, at: Date().addingTimeInterval(-Double($0) * 60)) }
        try store.upsert(messages: extra)
        try sem.putBulk(extra.map { ($0.id, EmbeddedText(space: 1, vector: centroids[r(400)])) })
        t = Date()
        while try st.catchUp(maxItems: 64) > 0 {}
        let inc = Date().timeIntervalSince(t) * 1000 / 200
        err(String(format: "  incremental at %d rows: %.2f ms/message (target < 50)", n, inc))
        st.dropMemory()
        t = Date(); _ = st.story(messageId: "b\(n / 2)")
        err(String(format: "  cold load of the story index: %.2f s", Date().timeIntervalSince(t)))
        t = Date(); for i in 0..<100 { _ = st.story(messageId: "b\(r(n))", limit: 12); _ = i }
        err(String(format: "  story(messageId:) warm: %.2f ms", Date().timeIntervalSince(t) * 10))
        let shape = st.debugShape()
        err(String(format: "  shape: %d rows, %d stories, %.1f %% of rows in multi-message stories, largest %d",
                   shape.rows, shape.stories, shape.inStories * 100, shape.largest))
        // Real NLTagger cost on a sample (per message).
        let tagger = AppleEntityTagger()
        t = Date()
        for i in 0..<300 { _ = tagger.entities(in: "Meeting with Anna Meier in Zürich about the Basel office on 14 May 2027. " + msgs[i].preview!) }
        err(String(format: "  AppleEntityTagger: %.2f ms/message", Date().timeIntervalSince(t) * 1000 / 300))
        check(inc < 50, "story linking < 50 ms per new message at \(n) rows (\(String(format: "%.2f", inc)) ms)")
        check(shape.largest <= 300, "story size cap holds (synthetic random text; see report): largest \(shape.largest), \(Int(shape.inStories * 100)) % in stories")
    } catch { check(false, "story bench threw \(error)") }
}
