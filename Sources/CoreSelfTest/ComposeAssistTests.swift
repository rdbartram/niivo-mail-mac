import Foundation
import MailCore

@MainActor
func runComposeAssistTests() async {
    section("Composer assist: autocomplete, MailTips, reply From, templates, table / rule, reopened drafts, spelling")

    // MARK: Autocomplete ranking
    let cands = [
        RecipientSuggestion(address: "zoe.annan@fabrikam.example", name: "Zoe Annan", source: .directory, relevance: 0.3),
        RecipientSuggestion(address: "anna.muster@contoso.example", name: "Anna Muster", source: .recent, relevance: 0.9),
        RecipientSuggestion(address: "Anna.Muster@contoso.example", name: "", source: .people, relevance: 1),
        RecipientSuggestion(address: "analytics@contoso.example", name: "Analytics Team", source: .group, isGroup: true, relevance: 0.3),
        RecipientSuggestion(address: "bob@contoso.example", name: "Bob Stone", source: .recent, relevance: 1),
        RecipientSuggestion(address: "annette@contoso.example", name: "Annette Weber", source: .people, relevance: 0.2),
        RecipientSuggestion(address: "fuzzy@contoso.example", name: "Server Fuzzy", source: .people, relevance: 0.1),
    ]
    let ranked = RecipientRanker.rank("ann", candidates: cands)
    check(ranked.first?.id == "anna.muster@contoso.example" && ranked.first?.name == "Anna Muster",
          "autocomplete: frequent correspondent with a prefix match ranks first, duplicate sources merge (name kept)")
    check(ranked.filter { $0.id == "anna.muster@contoso.example" }.count == 1, "autocomplete: one row per address (case-insensitive)")
    check(!ranked.contains { $0.address.hasPrefix("bob") }, "autocomplete: a local correspondent that doesn't match is dropped")
    check(ranked.last?.address == "fuzzy@contoso.example", "autocomplete: a server hit with no local match is kept, ranked last")
    let zi = ranked.firstIndex { $0.address.hasPrefix("zoe") } ?? 99, ai = ranked.firstIndex { $0.address.hasPrefix("annette") } ?? -1
    check(ai < zi, "autocomplete: name-prefix match from /me/people beats a word match from the directory")
    check(RecipientRanker.rank("ann", candidates: cands, excluding: [EmailAddress(name: "", address: "ANNA.muster@contoso.example")])
            .allSatisfy { $0.id != "anna.muster@contoso.example" }, "autocomplete: recipients already on the draft are excluded")
    check(ranked.first { $0.address.hasPrefix("analytics") }?.isGroup == true, "autocomplete: groups / distribution lists are marked")
    var p = PersonNode(address: "maria@contoso.example"); p.names = ["Maria Rossi": 3]
    let recent = RecipientRanker.recent(from: [p, PersonNode(address: "other@x.example")], query: "ross")
    check(recent.count == 1 && recent[0].name == "Maria Rossi" && recent[0].source == .recent, "autocomplete: CommGraph people nodes as local candidates")
    let pasted = RecipientRanker.parse("\"Muster, Anna\" <anna@contoso.example>; b@fabrikam.example\nc@x.example d@y.example, not an address")
    check(pasted.valid.map(\.address) == ["anna@contoso.example", "b@fabrikam.example", "c@x.example", "d@y.example"]
          && pasted.valid[0].name == "Muster, Anna" && pasted.invalid == ["not an address"],
          "paste of several addresses: ; , newline and spaces split; quoted names with commas kept; junk returned")

    // MARK: Directory / MailTips / attachment requests (stub)
    let headers = HeaderLog()
    MailStub.log = []
    MailStub.handler = { req, body in
        let path = req.url!.path, m = req.httpMethod ?? "GET"
        var h: [String: String] = [:]
        if let v = req.value(forHTTPHeaderField: "ConsistencyLevel") { h["ConsistencyLevel"] = v }
        headers.add(m + " " + path, h)
        switch (m, path) {
        case ("GET", "/v1.0/me/people"):
            return (200, [:], #"{"value":[{"displayName":"Anna Muster","scoredEmailAddresses":[{"address":"anna@contoso.example"}],"personType":{"class":"Person"}},{"displayName":"Sales DL","scoredEmailAddresses":[{"address":"sales@contoso.example"}],"personType":{"class":"Group","subclass":"PublicDistributionList"}}]}"#)
        case ("GET", "/v1.0/users"):
            return (200, [:], #"{"value":[{"displayName":"Anna Muster","mail":"anna@contoso.example"},{"displayName":"Annika B","userPrincipalName":"annika@contoso.example"}]}"#)
        case ("GET", "/v1.0/groups"): return (403, [:], #"{"error":{"code":"Authorization_RequestDenied"}}"#)
        case ("POST", "/v1.0/me/getMailTips"):
            return (200, [:], #"{"value":[{"emailAddress":{"address":"ooo@contoso.example"},"automaticReplies":{"message":"<p>Away until <b>Monday</b>.</p>"},"recipientScope":"internal"},{"emailAddress":{"address":"list@contoso.example"},"externalMemberCount":4,"totalMemberCount":40},{"emailAddress":{"address":"bad@contoso.example"},"error":{"code":"ErrorInvalidRecipients","message":"x"}},{"emailAddress":{"address":"full@contoso.example"},"mailboxFull":true}]}"#)
        case ("GET", "/v1.0/me/messages/d1/attachments"):
            return (200, [:], ##"{"value":[{"@odata.type":"#microsoft.graph.fileAttachment","id":"a1","name":"report.pdf","contentType":"application/pdf","size":2048,"isInline":false},{"@odata.type":"#microsoft.graph.itemAttachment","id":"a2","name":"Meeting","size":900,"isInline":false},{"@odata.type":"#microsoft.graph.fileAttachment","id":"a3","name":"logo.png","contentType":"image/png","size":10,"isInline":true}]}"##)
        case ("GET", "/v1.0/me/messages/d1/attachments/a1/$value"): return (200, [:], "PDFBYTES")
        case ("DELETE", "/v1.0/me/messages/d1/attachments/a1"): return (204, [:], "")
        default: return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let svc = GraphComposeService(mailToken: { "m" }, directoryToken: { "d" }, groupToken: { "g" }, session: URLSession(configuration: cfg))
    let hits = await svc.recipients("an\"na")
    let log = MailStub.captured()
    let peopleReq = log.first { $0.path == "/v1.0/me/people" }
    let usersReq = log.first { $0.path == "/v1.0/users" }
    check(peopleReq?.query.contains("search=%22anna%22") == true && peopleReq?.query.contains("personType") == true,
          "directory: /me/people?$search=\"anna\" (quote stripped from the term) selects personType")
    check(usersReq?.query.contains("displayName:anna") == true && usersReq?.query.contains("mail:anna") == true,
          "directory: /users?$search=\"displayName:…\" OR \"mail:…\"")
    check(headers.all.first { $0.0 == "GET /v1.0/users" }?.1["ConsistencyLevel"] == "eventual"
          && headers.all.first { $0.0 == "GET /v1.0/groups" }?.1["ConsistencyLevel"] == "eventual"
          && headers.all.first { $0.0 == "GET /v1.0/me/people" }?.1["ConsistencyLevel"] == nil,
          "directory: ConsistencyLevel: eventual on /users and /groups $search, not on /me/people")
    check(hits.contains { $0.address == "sales@contoso.example" && $0.isGroup } && hits.contains { $0.address == "annika@contoso.example" && $0.source == .directory },
          "directory: a DL from /me/people is a group; a UPN-only user is still suggested")
    MailStub.log = []
    _ = await svc.recipients("annika")
    check(!MailStub.captured().contains { $0.path == "/v1.0/groups" } && MailStub.captured().contains { $0.path == "/v1.0/me/people" },
          "directory: a source refused with 403 (no consent) isn't asked again; the others still are")

    do {
        MailStub.log = []
        let tips = try await svc.mailTips(MailTipsRequest.addresses([EmailAddress(name: "", address: "OOO@contoso.example"),
                                                                     EmailAddress(name: "", address: "ooo@contoso.example"),
                                                                     EmailAddress(name: "", address: "list@contoso.example")]), mailbox: "me")
        let req = MailStub.captured().first { $0.path == "/v1.0/me/getMailTips" }
        let body = (req?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        check(req?.method == "POST" && (body["EmailAddresses"] as? [String]) == ["ooo@contoso.example", "list@contoso.example"]
              && (body["MailTipsOptions"] as? String)?.contains("automaticReplies") == true
              && (body["MailTipsOptions"] as? String)?.contains("externalMemberCount") == true
              && (body["MailTipsOptions"] as? String)?.contains("recipientScope") == true,
              "MailTips: POST /me/getMailTips with deduplicated EmailAddresses + the options asked for")
        check(tips.count == 4 && tips[0].automaticReply != nil && tips[1].externalMemberCount == 4 && tips[1].totalMemberCount == 40
              && tips[2].error == "ErrorInvalidRecipients" && tips[3].mailboxFull, "MailTips: response parsed (OOF, member counts, error, mailbox full)")
        let banners = MailTipAdvisor.banners(tips, names: ["ooo@contoso.example": "Olive Out"])
        let kinds = banners.map(\.kind)
        check(kinds.contains(.invalid) && kinds.contains(.mailboxFull) && kinds.contains(.outOfOffice) && kinds.contains(.external) && kinds.contains(.largeAudience),
              "MailTips banners: invalid, mailbox full, out of office, external members, large audience (\(kinds))")
        let oof = banners.first { $0.kind == .outOfOffice }?.text ?? ""
        check(oof.contains("Olive Out") && oof.contains("Away until Monday.") && !oof.contains("<"), "MailTips: OOF banner names the person and shows a plain snippet (\(oof))")
        check(kinds.first == .invalid, "MailTips: the invalid-recipient banner comes first")
        check(MailTipAdvisor.banners([MailTip(address: "a@x.example", recipientScope: "internal")]).isEmpty, "MailTips: nothing to say → no banner")
    } catch { failures += 1; print("  ✗ mailTips threw \(error)") }

    do {
        let list = try await svc.attachments(messageId: "d1", mailbox: "me")
        check(list.map(\.kind) == [.file, .item, .file] && list[0].name == "report.pdf" && list[0].size == 2048 && list[2].isInline,
              "draft attachments: listed with kind (file / item) and inline flag")
        let req = MailStub.captured().first { $0.path == "/v1.0/me/messages/d1/attachments" }
        check(req?.query.contains("select=") == true && req?.query.contains("contentBytes") == false,
              "draft attachments: list selects metadata only (no bytes downloaded for chips)")
        let copy = try await svc.attachmentContent(messageId: "d1", attachment: list[0], mailbox: "me")
        let item = try await svc.attachmentContent(messageId: "d1", attachment: list[1], mailbox: "me")
        check(copy?.data == Data("PDFBYTES".utf8) && copy?.name == "report.pdf" && copy?.isInline == false && item == nil,
              "reply with attachments: file bytes via …/attachments/{id}/$value; Outlook items are not copied")
        try await svc.deleteAttachment(messageId: "d1", attachmentId: "a1", mailbox: "me")
        check(MailStub.captured().contains { $0.method == "DELETE" && $0.path == "/v1.0/me/messages/d1/attachments/a1" },
              "reopened draft: removing a server chip deletes that attachment on the server")
    } catch { failures += 1; print("  ✗ attachments threw \(error)") }

    // MARK: Auto-pick From
    let ids = [SendIdentity(address: "me@contoso.example", name: "Me"),
               SendIdentity(address: "me.alias@contoso.example", name: "Me (alias)"),
               SendIdentity(address: "support@contoso.example", name: "Support", mailbox: "support@contoso.example", mode: .sendOnBehalf),
               SendIdentity(address: "Support@Contoso.example", name: "Support", mailbox: "Support@Contoso.example", mode: .sendAs),
               SendIdentity(address: "sales@contoso.example", name: "Sales", mailbox: "sales@contoso.example", mode: .sendOnBehalf)]
    check(ReplyIdentity.pick(identities: ids, mailbox: "support@contoso.example")?.mode == .sendAs,
          "reply From: a message in the shared mailbox → its identity (case-insensitive, send as before on behalf)")
    check(ReplyIdentity.pick(identities: ids, mailbox: "SALES@contoso.example")?.address == "sales@contoso.example",
          "reply From: delegated mailbox → send on behalf of it")
    check(ReplyIdentity.pick(identities: ids, mailbox: "readonly@contoso.example") == nil && ReplyIdentity.pick(identities: ids, mailbox: "me") == nil,
          "reply From: no identity for the mailbox / own mailbox → caller's default")
    check(ReplyIdentity.pick(identities: ids, mailbox: "me", addressedTo: [EmailAddress(name: "", address: "ME.alias@contoso.example")])?.address == "me.alias@contoso.example",
          "reply From: own mailbox, mail addressed to an own alias → that alias")

    // MARK: Templates
    check(TemplateShortcut.trigger("Hello ;thx")?.shortcut == "thx" && TemplateShortcut.trigger("Hello ;thx")?.utf16Length == 4
          && TemplateShortcut.trigger(";Sig")?.shortcut == "sig", "snippet: ;name after a space or at the paragraph start triggers")
    check(TemplateShortcut.trigger("a;thx") == nil && TemplateShortcut.trigger("x ;") == nil && TemplateShortcut.trigger("x ;a b") == nil
          && TemplateShortcut.normalise(";Ok-1_x") == "ok-1_x" && TemplateShortcut.normalise("no way") == nil,
          "snippet: no trigger inside a word / empty / with spaces; shortcuts normalised")
    let v = TemplateVariables.values(recipient: EmailAddress(name: "Muster, Anna", address: "anna@contoso.example"),
                                     me: EmailAddress(name: "Jordan M", address: "r@contoso.example"), subject: "Offer",
                                     now: Date(timeIntervalSince1970: 1_790_000_000), locale: Locale(identifier: "en_GB"))
    check(v["firstname"] == "Anna" && v["lastname"] == "Muster" && v["myname"] == "Jordan M" && v["date"]?.contains("2026") == true,
          "snippet variables: \"Last, First\" names, my name, date")
    check(TemplateVariables.split(EmailAddress(name: "", address: "jean-luc.picard@x.example")).first == "Jean",
          "snippet variables: first name from the address when there's no display name")
    let tpl = MailTemplate(name: "Thanks", shortcut: ";THX", html: RichHTML.html(RichDoc([
        RichBlock(runs: [RichRun("Hi {{ firstName }},", RichStyle(bold: true))]), RichBlock(runs: [RichRun("Re {{subject}} — {{unknown}}")])])))
    let lib = TemplateLibrary(templates: [tpl])
    let expanded = TemplateExpander.expand(lib.template(shortcut: "thx")?.doc ?? RichDoc(), values: v)
    check(tpl.shortcut == "thx" && expanded.blocks.first?.text == "Hi Anna," && expanded.blocks.first?.runs.first?.style.bold == true
          && expanded.blocks.last?.text == "Re Offer — {{unknown}}", "snippet expansion: variables filled, formatting kept, unknown left visible")
    let encoded = try? JSONEncoder().encode(lib)
    check(encoded.flatMap { try? JSONDecoder().decode(TemplateLibrary.self, from: $0) } == lib
          && (try? JSONDecoder().decode(TemplateLibrary.self, from: Data("{}".utf8)))?.templates.isEmpty == true,
          "templates: library round-trips and an empty payload decodes")

    // MARK: Table + horizontal rule
    let grid = RichDoc([
        RichBlock(runs: [RichRun("Before")]),
        RichBlock(.table, runs: [RichRun("Name\t"), RichRun("Qty", RichStyle(bold: true))]),
        RichBlock(.table, runs: [RichRun("Apples\t3")]),
        RichBlock(.table, runs: [RichRun("\t")]),
        RichBlock(.rule),
        RichBlock(runs: [RichRun("After")]),
    ]).normalised()
    let gh = RichHTML.html(grid)
    check(gh.contains("<table \(RichHTML.tableMarker)=\"1\"") && gh.components(separatedBy: "<tr>").count == 4
          && gh.components(separatedBy: "<td ").count == 7 && gh.contains("<hr ") && !gh.contains("\t"),
          "table: rows → one <table> with bordered cells; rule → <hr>; no raw tabs in the HTML")
    let gback = RichHTML.parse(gh).doc
    check(gback == grid, "table / rule HTML round trip (incl. an empty row and a bold cell)")
    if gback != grid { for (a, b) in zip(grid.blocks, gback.blocks) where a != b { print("    \(a) / \(b)") }; print("    count \(grid.blocks.count)/\(gback.blocks.count)") }
    let foreign = RichHTML.parse("<table><tr><td>a</td><td>b</td></tr></table><p>x</p>").doc
    check(foreign.blocks.first?.kind == .paragraph && foreign.blocks.first?.text == "a\tb",
          "foreign tables (web / Word / signatures) still flatten to tab-separated paragraphs")
    check(RichHTML.parse("<p>a</p><hr><p>b</p>").doc.blocks.map(\.kind) == [.paragraph, .rule, .paragraph], "pasted <hr> becomes a rule")

    // MARK: Reopened draft: link chips from the body
    let link = SharingLink(url: "https://contoso-my.sharepoint.com/:w:/g/personal/x/abc", type: .edit, scope: .organization)
    var body = RichDoc([RichBlock(runs: [RichRun("See below")])])
    if let b = CloudLinkChip.block(name: "Plan.docx", link: link) { body.blocks.append(b) }
    body.blocks.append(RichBlock(runs: [RichRun("Text with "), RichRun("a normal link", RichStyle(link: "https://example.ch"))]))
    let reopened = RichHTML.parse(RichHTML.split("<html><body>" + RichHTML.html(body) + "<div>quoted</div></body></html>").editable).doc
    let chips = CloudChipScan.links(in: reopened)
    check(chips.count == 1 && chips[0].name == "Plan.docx" && chips[0].url == link.url && chips[0].type == .edit,
          "reopened draft: the OneDrive chip comes back from the body (name, link, permission); plain links don't")
    let fixture = FixtureComposeService(draftAttachments: ["d9": [DraftServerAttachment(id: "s1", name: "a.xlsx", size: 12)]])
    let kept = (try? await fixture.attachments(messageId: "d9", mailbox: "me")) ?? []
    check(kept.map(\.id) == ["s1"], "reopened draft: server attachments listed for chips (fixture)")

    // MARK: Spelling language
    check(DraftLanguage.detect("Guten Tag Frau Muster, vielen Dank für Ihre Nachricht. Wir melden uns morgen.") == .de
          && DraftLanguage.detect("Bonjour Madame, merci beaucoup pour votre message. Nous revenons vers vous demain.") == .fr
          && DraftLanguage.detect("Buongiorno, grazie mille per il messaggio. Le risponderemo domani.") == .it
          && DraftLanguage.detect("Thanks for your message, we will get back to you tomorrow.") == .en,
          "spell-check: language detected among DE / FR / IT / EN")
    check(DraftLanguage.detect("Ok") == nil && DraftLanguage.en.spellCodes.first == "en_GB", "spell-check: too short → no guess; English is British")
}
