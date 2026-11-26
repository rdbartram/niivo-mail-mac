import Foundation
import CalendarCore
import MailCore

/// Thread-safe capture of request headers seen by the stub (MailStub.Captured has none).
final class HeaderLog: @unchecked Sendable {
    private let lock = NSLock(); private var items: [(String, [String: String])] = []
    func add(_ path: String, _ h: [String: String]) { lock.withLock { items.append((path, h)) } }
    var all: [(String, [String: String])] { lock.withLock { items } }
}

@MainActor
func runComposerTests() async {
    section("Composer: rich text ⇄ HTML, Markdown, signatures, attachments")

    // MARK: HTML round trip
    let img = RichImage(cid: "logo@niivo", alt: "Logo", width: 120)
    let doc = RichDoc([
        RichBlock(.heading1, runs: [RichRun("Quarterly update")]),
        RichBlock(runs: [RichRun("Hello "), RichRun("bold", RichStyle(bold: true)), RichRun(" "),
                         RichRun("it", RichStyle(italic: true)), RichRun(" "), RichRun("u", RichStyle(underline: true)), RichRun(" "),
                         RichRun("s", RichStyle(strike: true)), RichRun(" "), RichRun("red", RichStyle(color: "#C00000")), RichRun(" "),
                         RichRun("mark", RichStyle(highlight: "#FFFF00")), RichRun(" "), RichRun("big", RichStyle(size: .large)), RichRun(" "),
                         RichRun("link", RichStyle(link: "https://example.ch/a?b=1&c=2")), RichRun(" "), RichRun("x()", RichStyle(code: true))]),
        RichBlock(),
        RichBlock(.bullet, runs: [RichRun("one")]),
        RichBlock(.bullet, level: 1, runs: [RichRun("nested")]),
        RichBlock(.number, runs: [RichRun("first")]),
        RichBlock(.number, runs: [RichRun("second")]),
        RichBlock(.quote, runs: [RichRun("quoted <tag> & more")]),
        RichBlock(.code, runs: [RichRun("let a = 1")]),
        RichBlock(.code, runs: [RichRun("  indented")]),
        RichBlock(align: .center, runs: [RichRun("centred"), RichRun("", image: img)]),
        RichBlock(runs: [RichRun("Jordan", RichStyle(bold: true))], signature: true),
    ]).normalised()
    let html = RichHTML.html(doc)
    let back = RichHTML.parse(html).doc
    check(back == doc, "HTML round trip keeps every format (bold/italic/underline/strike/colour/highlight/size/link/code, headings, nested lists, quote, code block, alignment, cid image, signature)")
    if back != doc {
        for (i, (a, b)) in zip(doc.blocks, back.blocks).enumerated() where a != b { for (x, y) in zip(a.runs, b.runs) where x != y { print("    block \(i) run differs: \(x) / \(y)") }; if a.runs.count != b.runs.count || a.align != b.align { print("    block \(i) runs \(a.runs.count)/\(b.runs.count)") } }
        if doc.blocks.count != back.blocks.count { print("    count \(doc.blocks.count) vs \(back.blocks.count)") }
    }
    check(!html.contains("class=") && !html.contains("<style") && !html.hasPrefix("<html"), "outgoing HTML: inline styles only, a fragment (no <html>/<style>/class)")
    check(html.contains("<img src=\"cid:logo@niivo\""), "inline image written as <img src=\"cid:…\">")
    check(html.contains("&lt;tag&gt; &amp; more") && html.contains("href=\"https://example.ch/a?b=1&amp;c=2\""), "text and attributes escaped")
    let ul = html.range(of: "<ul"), nested = html.range(of: "<ul", range: (ul?.upperBound ?? html.startIndex)..<html.endIndex)
    check(ul != nil && nested != nil && html.contains("nested</li></ul></li></ul><ol"), "nested list nests inside the parent <li>; numbered list follows as <ol>")

    // MARK: Sanitising input
    let dirty = #"<html><head><title>T</title><style>p{color:red}</style></head><body><script>alert(1)</script><p onclick="x()" style="color:#333333;font-weight:700">Hi <a href="javascript:steal()">there</a> <img src="https://tracker.example/p.png" alt=""><iframe src="https://e"></iframe><span style="background-color:yellow">hl</span></p></body></html>"#
    let pd = RichHTML.parse(dirty)
    let outDirty = RichHTML.html(pd.doc)
    check(pd.doc.plainText == "Hi there hl", "paste: script/style/head/iframe content dropped (\(pd.doc.plainText.debugDescription))")
    check(!outDirty.contains("javascript") && !outDirty.contains("onclick") && !outDirty.contains("tracker") && !outDirty.contains("#333333"),
          "paste: javascript: link, handlers, remote image and neutral source colour are not carried")
    check(pd.droppedRemoteImages == 1 && pd.doc.blocks.first?.runs.first?.style.bold == true
          && pd.doc.blocks.first?.runs.last?.style.highlight == "#FFFF00", "paste: remote image counted and dropped; bold and highlight kept")
    let dataImg = RichHTML.parse(#"<p>a<img src="data:image/png;base64,iVBORw0KGgo="></p>"#, makeCID: { "c1@niivo" })
    check(dataImg.dataImages.first?.cid == "c1@niivo" && dataImg.dataImages.first?.mime == "image/png" && dataImg.doc.images.first?.cid == "c1@niivo",
          "pasted data: image becomes an inline attachment with a contentId")
    let word = RichHTML.parse(#"<p class=MsoListParagraph style='mso-list:l0 level2 lfo1'><![if !supportLists]><span>1.<span>&nbsp;</span></span><![endif]>Item</p><p class=MsoNormal><o:p>&nbsp;</o:p></p>"#).doc
    check(word.blocks.first?.kind == .number && word.blocks.first?.level == 1 && word.blocks.first?.text == "Item" && word.blocks.count == 2
          && word.blocks[1].isEmpty, "Word paste: mso-list paragraph → numbered item level 2; &nbsp; paragraph → empty line")
    let split = RichHTML.split("<html><body>" + html + "<hr><div id=\"divRplyFwdMsg\">quote</div></body></html>")
    check(split.prefix == "<html><body>" && split.suffix == "<hr><div id=\"divRplyFwdMsg\">quote</div></body></html>"
          && RichHTML.parse(split.editable).doc == back, "reopened draft: our region is split out, the rest is carried verbatim")
    let xs = RichHTML.split("<body><div id=\"x_niivo-compose\" dir=\"ltr\"><p>mine</p><div>in</div></div><div>tail</div></body>")
    check(xs.editable == "<p>mine</p><div>in</div>" && xs.suffix == "<div>tail</div></body>", "reopened draft: marker matched even with Exchange's x_ id prefix")

    // MARK: Markdown
    let md = RichMarkdown.parse("# Title\n\nSome **bold** and *it* and `c` and [site](https://niivo.example).\n\n- a\n  - b\n1. one\n> q\n```\nlet x = 1\n```")
    let kinds = md.blocks.filter { !$0.isEmpty }.map(\.kind)
    check(kinds == [.heading1, .paragraph, .bullet, .bullet, .number, .quote, .code], "Markdown paste: block kinds (\(kinds))")
    let para = md.blocks.first { $0.kind == .paragraph && !$0.isEmpty }
    check(para?.runs.contains { $0.text == "bold" && $0.style.bold } == true && para?.runs.contains { $0.text == "it" && $0.style.italic } == true
          && para?.runs.contains { $0.text == "c" && $0.style.code } == true && para?.runs.contains { $0.text == "site" && $0.style.link == "https://niivo.example" } == true,
          "Markdown paste: inline bold / italic / code / link")
    check(md.blocks.first { $0.text == "b" }?.level == 1, "Markdown paste: indented list item nests")
    check(RichMarkdown.looksLikeMarkdown("- a\n- b") && !RichMarkdown.looksLikeMarkdown("Just a sentence, 3 * 4 = 12."), "Markdown paste heuristic")
    check(RichMarkdown.parse("[x](javascript:alert(1))").blocks.first?.runs.allSatisfy { $0.style.link == nil } == true, "Markdown links: unsafe schemes not linked")

    // Live typing
    check(RichMarkdown.blockTrigger("- ")?.kind == .bullet && RichMarkdown.blockTrigger("1. ")?.kind == .number
          && RichMarkdown.blockTrigger("## ")?.kind == .heading2 && RichMarkdown.blockTrigger("> ")?.kind == .quote
          && RichMarkdown.blockTrigger("# ")?.kind == .heading1 && RichMarkdown.blockTrigger("x ") == nil && RichMarkdown.blockTrigger("-- ") == nil,
          "live Markdown: block triggers at line start")
    let b = RichMarkdown.inlineMatch("say **hi there**")
    check(b?.bold == true && b?.text == "hi there" && b?.utf16Length == 12, "live Markdown: **bold** on the closing *")
    check(RichMarkdown.inlineMatch("say **hi*") == nil, "live Markdown: no premature italic inside an unfinished **bold**")
    check(RichMarkdown.inlineMatch("an *idea*")?.italic == true && RichMarkdown.inlineMatch("run `make`")?.code == true
          && RichMarkdown.inlineMatch("~~old~~")?.strike == true && RichMarkdown.inlineMatch("my_var_") == nil,
          "live Markdown: *italic*, `code`, ~~strike~~; snake_case left alone")
    let l = RichMarkdown.inlineMatch("see [docs](https://learn.microsoft.com)")
    check(l?.link == "https://learn.microsoft.com" && l?.text == "docs" && RichMarkdown.inlineMatch("[x](javascript:y)") == nil, "live Markdown: [text](url) → link, unsafe scheme ignored")

    // MARK: Signatures
    let sigA = MailSignature(name: "Work", html: RichHTML.html(RichDoc([RichBlock(runs: [RichRun("Jordan Miller", RichStyle(bold: true))]),
                                                                       RichBlock(runs: [RichRun("", image: RichImage(cid: "sig-logo"))])])),
                             images: [SignatureImage(cid: "sig-logo", name: "logo.png", contentType: "image/png", data: Data([1, 2, 3]))])
    let sigB = MailSignature(name: "Short", html: "<p>R.</p>")
    var body = RichDoc([RichBlock(runs: [RichRun("Hi Zoé,")])])
    body = SignaturePlacement.apply(sigA.doc, to: body)
    body = SignaturePlacement.apply(sigB.doc, to: body)
    check(body.blocks.filter(\.signature).map(\.text) == ["R."] && body.blocks.first?.text == "Hi Zoé,", "switching signature replaces it (one signature, content kept)")
    check(SignaturePlacement.apply(nil, to: body).blocks.allSatisfy { !$0.signature }, "removing the signature")
    check(sigA.inlineAttachments.first?.contentId == "sig-logo" && sigA.inlineAttachments.first?.isInline == true
          && sigA.doc.images.first?.cid == "sig-logo", "signature image travels as an inline cid attachment")
    var prefs = ComposerPreferences(signatures: [sigA, sigB])
    prefs.newMailDefaults = [ComposerPreferences.anyIdentity: sigA.id, "support@contoso.example": sigB.id]
    prefs.replyDefaults = [ComposerPreferences.anyIdentity: sigB.id]
    check(prefs.defaultSignature(identity: "Support@Contoso.example", reply: false)?.id == sigB.id
          && prefs.defaultSignature(identity: "you@contoso.example", reply: false)?.id == sigA.id
          && prefs.defaultSignature(identity: nil, reply: true)?.id == sigB.id, "signature defaults per identity, new vs reply, with fallback")
    do {
        let store = try mailStore()
        try store.save(composerPreferences: prefs)
        check(store.composerPreferences() == prefs, "composer preferences + signatures round-trip through the sealed store")
        check(!(try store.value(for: ComposerPreferences.storeKey) ?? "").contains("Jordan Miller"), "signatures are sealed at rest")
    } catch { check(false, "prefs store threw \(error)") }

    // MARK: Gate
    let eng = mailEngine()
    check(AttachmentGate.blockReason(eng.policy(labelId: nil, isPrivate: false, access: .own)) == nil, "attachments allowed on unlabelled mail")
    check(AttachmentGate.blockReason(eng.policy(labelId: "00000000-dead-beef-0000-000000000000", isPrivate: false, access: .own)) != nil,
          "attachments blocked (fail closed) when the label isn't in the synced policy")

    // MARK: Graph: attachments
    let headers = HeaderLog()
    let quoted = "<html><body><div id=\\\"divRplyFwdMsg\\\">quoted history</div></body></html>"
    MailStub.log = []
    MailStub.handler = { req, body in
        let path = req.url!.path, m = req.httpMethod ?? "GET"
        var h: [String: String] = [:]
        for k in ["Content-Range", "Authorization", "Content-Type"] { if let v = req.value(forHTTPHeaderField: k) { h[k] = v } }
        headers.add(m + " " + path, h)
        switch (m, path) {
        case ("POST", "/v1.0/me/messages"): return (201, [:], gmsg("d-new", folder: "drafts"))
        case ("POST", "/v1.0/me/messages/orig/createReply"):
            return (201, [:], #"{"id":"d-rep","body":{"contentType":"html","content":"\#(quoted)"},"parentFolderId":"drafts"}"#)
        case ("PATCH", "/v1.0/me/messages/d-rep"): return (200, [:], gmsg("d-rep", folder: "drafts"))
        case ("POST", let p) where p.hasSuffix("/attachments/createUploadSession"):
            return (201, [:], #"{"uploadUrl":"https://outlook.office.com/api/v2.0/Users('u')/Messages('m')/AttachmentSessions('s1')?authtoken=abc","expirationDateTime":"2026-11-20T00:00:00Z","nextExpectedRanges":["0-"]}"#)
        case ("POST", let p) where p.hasSuffix("/attachments"):
            return (201, [:], #"{"id":"att-1","name":"a.txt","contentType":"text/plain","size":5,"isInline":false}"#)
        case ("PUT", let p) where p.contains("AttachmentSessions"):
            let last = (req.value(forHTTPHeaderField: "Content-Range") ?? "").hasSuffix("-\(5 * 1024 * 1024 - 1)/\(5 * 1024 * 1024)")
            return (last ? 201 : 200, [:], last ? "" : #"{"nextExpectedRanges":["x-"]}"#)
        default: return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let svc = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
    func json(_ d: Data?) -> [String: Any] { (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
    do {
        // New mail: small file + inline image ride in the create POST.
        let small = OutgoingAttachment(name: "a.txt", contentType: "text/plain", data: Data("hello".utf8))
        let inline = OutgoingAttachment(name: "pic.png", contentType: "image/png", data: Data([0x89, 0x50]), isInline: true, contentId: "pic@niivo")
        var d = MailDraft(kind: .new, to: [EmailAddress(name: "B", address: "b@contoso.example")], subject: "S",
                          bodyHTML: RichHTML.html(RichDoc([RichBlock(runs: [RichRun("x"), RichRun("", image: RichImage(cid: "pic@niivo"))])])))
        d.attachments = [small, inline]
        _ = try await svc.saveDraft(d, mailbox: "me")
        let create = json(MailStub.captured().first { $0.method == "POST" && $0.path == "/v1.0/me/messages" }?.body)
        let atts = create["attachments"] as? [[String: Any]] ?? []
        check(atts.count == 2 && atts[0]["@odata.type"] as? String == "#microsoft.graph.fileAttachment"
              && atts[0]["contentBytes"] as? String == Data("hello".utf8).base64EncodedString() && atts[0]["name"] as? String == "a.txt"
              && atts[0]["isInline"] as? Bool == false, "small attachment: fileAttachment with base64 contentBytes in the draft POST")
        check(atts.count == 2 && atts[1]["isInline"] as? Bool == true && atts[1]["contentId"] as? String == "pic@niivo"
              && ((create["body"] as? [String: Any])?["content"] as? String ?? "").contains("src=\"cid:pic@niivo\""),
              "inline image: isInline + contentId, body references cid:")

        // Reply with a large file + small file + signature: body order, attachments after the PATCH, upload session chunks.
        MailStub.log = []
        let big = OutgoingAttachment(name: "big.bin", contentType: "application/octet-stream", data: Data(repeating: 7, count: 5 * 1024 * 1024))
        var rdoc = RichDoc([RichBlock(runs: [RichRun("Thanks!")])])
        rdoc = SignaturePlacement.apply(sigB.doc, to: rdoc)
        var r = MailDraft(kind: .reply, replyTo: "orig", bodyHTML: RichHTML.html(rdoc))
        r.attachments = [small, big]
        let sent = LockedCounter()
        AttachmentProgress.shared.observe(big.id) { s, t in if t == big.size { sent.set(s) } }
        _ = try await svc.saveDraft(r, mailbox: "me")
        AttachmentProgress.shared.stop(big.id)
        let log = MailStub.captured()
        let patch = (json(log.first { $0.method == "PATCH" }?.body)["body"] as? [String: Any])?["content"] as? String ?? ""
        let iT = patch.range(of: "Thanks!"), iS = patch.range(of: "R."), iQ = patch.range(of: "quoted history")
        check(iT != nil && iS != nil && iQ != nil && iT!.lowerBound < iS!.lowerBound && iS!.lowerBound < iQ!.lowerBound
              && patch.contains("id=\"niivo-signature\""), "reply: text, then signature, then the quoted history")
        check(log.contains { $0.method == "POST" && $0.path == "/v1.0/me/messages/d-rep/attachments" }
              && json(log.first { $0.method == "PATCH" }?.body)["attachments"] == nil, "reply: small attachment POSTed to …/attachments after the PATCH")
        let sess = json(log.first { $0.path.hasSuffix("createUploadSession") }?.body)["AttachmentItem"] as? [String: Any]
        check(sess?["attachmentType"] as? String == "file" && sess?["size"] as? Int == big.size && sess?["name"] as? String == "big.bin",
              "large attachment: createUploadSession with AttachmentItem {file, name, size}")
        let puts = headers.all.filter { $0.0.hasPrefix("PUT ") }
        let total = big.size, c = AttachmentUpload.chunkSize
        check(puts.map { $0.1["Content-Range"] ?? "" } == ["bytes 0-\(c - 1)/\(total)", "bytes \(c)-\(total - 1)/\(total)"],
              "upload session: sequential chunk PUTs with Content-Range (\(puts.map { $0.1["Content-Range"] ?? "" }))")
        check(puts.allSatisfy { $0.1["Authorization"] == nil } && log.filter { $0.method == "PUT" }.map { $0.body?.count ?? 0 } == [c, total - c],
              "upload session: no bearer token on the uploadUrl; chunk bodies are the right slices")
        check(sent.value == total, "upload progress reported to the composer (\(sent.value)/\(total))")
        check(AttachmentUpload.chunks(total: 10, chunk: 4) == [0..<4, 4..<8, 8..<10] && AttachmentUpload.invalidReason(size: 151 * 1024 * 1024, name: "x") != nil,
              "chunk plan and 150 MB cap")

        // A failed attachment deletes the half-made draft instead of orphaning it.
        MailStub.handler = { req, _ in
            let path = req.url!.path, m = req.httpMethod ?? "GET"
            if m == "POST" && path == "/v1.0/me/messages" { return (201, [:], gmsg("d-bad", folder: "drafts")) }
            if m == "DELETE" { return (204, [:], "") }
            return (400, [:], #"{"error":{"code":"ErrorAttachmentSizeLimitExceeded"}}"#)
        }
        MailStub.log = []
        var bad = MailDraft(kind: .new, subject: "x")
        bad.attachments = [OutgoingAttachment(name: "a.txt", contentType: "text/plain", data: Data(repeating: 1, count: AttachmentUpload.embedBudget + 10))]
        do { _ = try await svc.saveDraft(bad, mailbox: "me"); check(false, "attachment failure should throw") }
        catch { check(MailStub.captured().contains { $0.method == "DELETE" && $0.path == "/v1.0/me/messages/d-bad" }, "failed attachment: the half-made draft is deleted") }
    } catch { check(false, "composer graph stub threw \(error)") }

    // Fixture service
    do {
        let fx = FixtureMailService()
        var d = MailDraft(kind: .new, to: [EmailAddress(name: "B", address: "b@contoso.example")], subject: "fx")
        d.attachments = [OutgoingAttachment(name: "n.txt", contentType: "text/plain", data: Data("n".utf8))]
        let saved = try await fx.saveDraft(d, mailbox: "me")
        _ = try await fx.addAttachment(OutgoingAttachment(name: "m.txt", contentType: "text/plain", data: Data("m".utf8)), toDraft: saved.id, mailbox: "me")
        let again = try await fx.message(id: saved.id, mailbox: "me")
        check(saved.hasAttachments && again.attachments.map(\.name) == ["n.txt", "m.txt"], "fixture service keeps draft attachments")
    } catch { check(false, "fixture attachments threw \(error)") }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0
    func set(_ n: Int) { lock.withLock { v = max(v, n) } }
    var value: Int { lock.withLock { v } }
}
