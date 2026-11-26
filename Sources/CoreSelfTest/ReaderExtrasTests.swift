import Foundation
import CalendarCore
import MailCore

/// cid: images, attachment rights, notification text + bursts, search hits that only the server had.
@MainActor
func runReaderExtrasTests() async {
    inlineImageTests()
    readerAppearanceTests()   // §17: Dark Mode reader
    attachmentRightsTests()
    notificationTextTests()
    notificationBurstTests()
    await attachmentsSurviveDeltaTests()
    await searchOpenTests()
    await inlineGraphStubTests()
}

@MainActor
private func inlineImageTests() {
    section("Reader: inline cid: images (memory only)")
    let png = FixtureMailService.fixturePNG
    check(InlineImages.normalise("cid:<Image001.PNG@01DA>") == "image001.png@01da", "cid normalised: scheme, <>, case")
    check(InlineImages.normalise("cid:logo%40example") == "logo@example", "cid normalised: percent-decoded")

    let html = #"<p>Hi</p><img width="10" src="cid:logo@x"><img src='cid:%3CChart@X%3E'><img src="cid:missing"><img src="https://t.example/p.gif"><a href="cid:logo@x">x</a>"#
    check(InlineImages.referencedIds(in: html) == ["logo@x", "chart@x", "missing"], "only <img src=cid:…> references are collected")

    let parts = InlineImages.parts(from: [
        AttachmentContent(id: "a1", name: "logo.png", contentType: "image/png", contentId: "<logo@x>", isInline: true, data: png),
        AttachmentContent(id: "a2", name: "chart.gif", contentType: "image/gif", contentId: "chart@x", isInline: true, data: png),
        AttachmentContent(id: "a3", name: "evil.svg", contentType: "image/svg+xml", contentId: "missing", isInline: true, data: Data("<svg/>".utf8)),
    ])
    check(parts["logo@x"] != nil && parts["chart@x"] != nil && parts["missing"] == nil, "parts keyed by normalised contentId; SVG refused")
    let out = InlineImages.rewrite(html, parts: parts)
    check(out.resolved == 2 && out.unresolved == 1, "two images resolved, unknown cid left alone (\(out.resolved)/\(out.unresolved))")
    check(out.html.contains("src=\"data:image/png;base64,\(png.base64EncodedString())\"") && out.html.contains("data:image/gif;base64,"),
          "cid: rewritten to data: URLs with the part's type")
    check(out.html.contains(#"src="cid:missing""#) && out.html.contains(#"href="cid:logo@x""#) && out.html.contains("https://t.example/p.gif"),
          "links, unknown ids and remote URLs untouched by the rewrite")
    let sanitised = HTMLSanitizer.sanitize(#"<img src="cid:logo@x"><img src="https://t.example/p.gif">"#).html
    let both = InlineImages.rewrite(sanitised, parts: parts).html
    check(both.contains("data:image/png") && both.contains("data-remote-blocked") && !both.contains("t.example"),
          "after the sanitiser: inline image resolved, remote image still blocked")

    let big = Data(count: InlineImages.maxPartBytes + 1)
    check(InlineImages.parts(from: [AttachmentContent(id: "b", name: "b.png", contentType: "image/png", contentId: "b", isInline: true, data: big)]).isEmpty,
          "a part over the per-image cap (real byte count) is dropped")
    let chunk = Data(count: 4 * 1024 * 1024)
    let many = (0..<8).map { AttachmentContent(id: "m\($0)", name: "", contentType: "image/jpeg", contentId: "m\($0)", isInline: true, data: chunk) }
    let capped = InlineImages.parts(from: many)
    check(capped.count == InlineImages.maxTotalBytes / chunk.count, "total cap per message enforced (\(capped.count) of 8 kept)")

    let atts = [AttachmentInfo(id: "i1", name: "logo.png", contentType: "image/png", size: 2_000, isInline: true),
                AttachmentInfo(id: "f1", name: "report.pdf", contentType: "application/pdf", size: 90_000),
                AttachmentInfo(id: "i2", name: "huge.png", contentType: "image/png", size: InlineImages.maxPartBytes + 1, isInline: true),
                AttachmentInfo(id: "f2", name: "photo.jpg", contentType: "image/jpeg", size: 3_000)]
    check(InlineImages.candidates(atts, html: "<p>no images</p>").isEmpty, "no cid reference → nothing fetched")
    check(InlineImages.candidates(atts, html: html).map(\.id) == ["i1", "f2"], "candidates: inline + images, within the size cap, no PDFs")
}

@MainActor
private func attachmentRightsTests() {
    section("Reader: attachment actions follow labels and the trust policy")
    let eng = mailEngine()
    let L = FixtureCalendarService.labels
    func pol(_ label: String?, priv: Bool = false, mailbox: String = "me") -> ContentPolicy {
        MailContentPolicy.policy(for: MailMessage(id: "x", folderId: "f", conversationId: "c", subject: "s", from: nil, received: Date(),
                                                  labelId: label, isPrivate: priv), mailbox: mailbox, engine: eng)
    }
    let managed = AttachmentDeviceRules(allowDownload: true, allowCopyOut: true, allowPrint: true, approvedOpenIn: ["com.apple.Preview"])
    let byod = AttachmentDeviceRules(allowDownload: false, allowCopyOut: true, allowPrint: true, approvedOpenIn: [])
    let open = pol(nil)
    check(AttachmentRights.check(.preview, policy: open, device: managed) == nil
          && AttachmentRights.check(.save, policy: open, device: managed) == nil
          && AttachmentRights.check(.drag, policy: open, device: managed) == nil, "unlabelled + managed: preview, save, drag allowed")
    check(AttachmentRights.check(.openIn(bundleId: "com.apple.preview"), policy: open, device: managed) == nil, "approved app (case-insensitive) allowed")
    check(AttachmentRights.check(.openIn(bundleId: "com.example.Unknown"), policy: open, device: managed)?.contains("approved") == true,
          "app not on approvedOpenInBundleIds refused with a reason")
    check(AttachmentRights.check(.preview, policy: open, device: byod)?.contains("trust policy") == true, "BYOD default: download blocked, reason given")
    var noCopyOut = managed; noCopyOut.allowCopyOut = false
    check(AttachmentRights.check(.preview, policy: open, device: noCopyOut) == nil
          && AttachmentRights.check(.save, policy: open, device: noCopyOut) != nil
          && AttachmentRights.check(.drag, policy: open, device: noCopyOut) != nil, "no device copy-out: preview only")
    var noPrint = managed; noPrint.allowPrint = false
    check(AttachmentRights.check(.openIn(bundleId: "com.apple.Preview"), policy: open, device: noPrint)?.contains("Printing") == true,
          "device print off: file can't leave the app")
    let hc = pol(L[3].id)
    check(AttachmentRights.check(.preview, policy: hc, device: managed)?.contains("encrypted") == true, "encrypted label: every action blocked")
    let unknown = pol(FixtureCalendarService.orphanLabelId)
    check(AttachmentRights.check(.preview, policy: unknown, device: managed) != nil, "unknown label: fail closed")
    var noExtract = open; noExtract.rights.subtract([.extract])
    check(AttachmentRights.check(.preview, policy: noExtract, device: managed)?.contains("EXTRACT") == true, "no EXTRACT right: blocked")
    var noPrintRight = open; noPrintRight.rights.subtract([.print])
    check(AttachmentRights.check(.preview, policy: noPrintRight, device: managed) == nil
          && AttachmentRights.check(.save, policy: noPrintRight, device: managed)?.contains("PRINT") == true, "no PRINT right: preview yes, save no")
    let priv = pol(nil, priv: true, mailbox: "sam@contoso.example")
    if priv.redactDetails { check(AttachmentRights.check(.preview, policy: priv, device: managed) != nil, "private item on a delegate's view: blocked") }

    check(AttachmentFiles.safeName("../../etc/passwd") == "passwd", "file name: path components dropped")
    check(AttachmentFiles.safeName("..\\..\\Win\\evil.exe") == "evil.exe", "file name: backslash paths dropped")
    check(AttachmentFiles.safeName(".hidden") == "hidden" && AttachmentFiles.safeName("..") == "attachment" && AttachmentFiles.safeName("") == "attachment",
          "file name: no dot-files, never empty")
    check(AttachmentFiles.safeName("a\u{0}b\nc:d.pdf") == "abcd.pdf", "file name: control characters and colons removed")
    let long = AttachmentFiles.safeName(String(repeating: "x", count: 300) + ".docx")
    check(long.count <= 120 && long.hasSuffix(".docx"), "file name: capped, extension kept")
}

@MainActor
private func notificationTextTests() {
    section("Notifications: text from the policy")
    let eng = mailEngine()
    let L = FixtureCalendarService.labels
    let sender = EmailAddress(name: "Ana Board", address: "ana@contoso.example")
    func msg(_ label: String? = nil, priv: Bool = false) -> MailMessage {
        MailMessage(id: "n", folderId: "inbox", conversationId: "c", subject: "Acquisition of Fabrikam", from: sender, received: Date(),
                    preview: "The numbers for\n the board   are attached and final", labelId: label, isPrivate: priv)
    }
    func text(_ m: MailMessage, mailbox: String = "me", title: String? = nil) -> MailNotificationText.Text {
        MailNotificationText.compose(m, policy: MailContentPolicy.policy(for: m, mailbox: mailbox, engine: eng), mailboxTitle: title, confirmed: true)
    }
    let o = text(msg())
    check(o.title == "Ana Board" && o.subtitle == "Acquisition of Fabrikam" && !o.restricted, "unlabelled: sender + subject")
    check(o.body == "The numbers for the board are attached and final", "unlabelled: short preview, whitespace flattened (\(o.body))")
    for (i, l) in L.enumerated() {
        let t = text(msg(l.id))
        check(t.restricted && t.title == MailNotificationText.confidentialTitle && !t.body.contains("Fabrikam") && !t.title.contains("Ana")
              && !t.subtitle.contains("Fabrikam") && !t.body.contains("numbers"), "label #\(i) (\(l.name)): no sender, subject or preview")
    }
    let u = text(msg(FixtureCalendarService.orphanLabelId))
    check(u.restricted && !u.subtitle.contains("Fabrikam"), "unknown label: generic")
    let p = text(msg(priv: true))
    check(p.restricted && !p.title.contains("Ana") && !p.subtitle.contains("Fabrikam"), "private (own mailbox too): generic")
    let shared = text(msg(), mailbox: "support@contoso.example", title: "Support")
    check(shared.body.hasPrefix("In Support") && shared.title == "Ana Board", "shared mailbox named in the body")
    let sharedHC = text(msg(L[3].id), mailbox: "support@contoso.example", title: "Support")
    check(sharedHC.body == "In Support" && sharedHC.restricted, "confidential in a shared mailbox: only the mailbox is named")
    var noDetails = MailContentPolicy.policy(for: msg(), engine: eng); noDetails.allowOfflineDetails = false
    let nd = MailNotificationText.compose(msg(), policy: noDetails, mailboxTitle: nil, confirmed: true)
    check(nd.body.isEmpty && !nd.restricted, "offline details not allowed: no preview")
    let unconfirmed = MailNotificationText.compose(msg(), policy: MailContentPolicy.policy(for: msg(), engine: eng), mailboxTitle: nil, confirmed: false)
    check(unconfirmed.restricted && unconfirmed.title == MailNotificationText.confidentialTitle && !unconfirmed.subtitle.contains("Fabrikam"),
          "label not confirmed from the full message (delta header, failed lookup) → generic")
    var long = msg(); long.preview = String(repeating: "word ", count: 80)
    check(text(long).body.count <= MailNotificationText.previewLimit, "preview capped at \(MailNotificationText.previewLimit) characters")
    var noSubject = msg(); noSubject.subject = ""; noSubject.from = nil
    let ns = text(noSubject)
    check(ns.title == "New message" && ns.subtitle == "(no subject)", "no sender / subject → neutral placeholders")
}

@MainActor
private func notificationBurstTests() {
    section("Notifications: bursts summarised, initial sync silent")
    let now = Date()
    check(MailNotificationPlanner.plan(newCount: 0, recent: [], now: now) == .none, "nothing new → nothing")
    check(MailNotificationPlanner.plan(newCount: 2, recent: [], now: now) == .singles(2), "two new → two notifications")
    check(MailNotificationPlanner.plan(newCount: 12, recent: [], now: now) == .summary(12), "twelve at once → one summary")
    check(MailNotificationPlanner.plan(newCount: 2, recent: [now.addingTimeInterval(-10), now.addingTimeInterval(-5)], now: now) == .summary(2),
          "rate limit: 2 more within a minute of 2 → summary")
    check(MailNotificationPlanner.plan(newCount: 3, recent: [now.addingTimeInterval(-120)], now: now) == .singles(3), "old posts fall out of the window")
    let s = MailNotificationText.summary(count: 12, mailboxTitles: ["Support", "Support"])
    check(s.title == "12 new messages" && s.body == "Inbox · Support" && s.subtitle.isEmpty, "summary: count + mailbox, no subjects")
    check(MailNotificationText.summary(count: 1, mailboxTitles: []).title == "1 new message", "summary singular")
    check(MailNotificationText.summary(count: 5, mailboxTitles: ["A", "B"]).body == "Inbox · 2 mailboxes", "summary across mailboxes")

    func m(_ id: String, _ ago: TimeInterval) -> MailMessage {
        MailMessage(id: id, folderId: "inbox", conversationId: id, subject: id, from: nil, received: now.addingTimeInterval(-ago))
    }
    var t = MailArrivalTracker()
    t.seed(mailbox: "me", newest: now.addingTimeInterval(-600), now: now)
    let backfill = t.arrivals([(m("old1", 3_600), "me"), (m("old2", 86_400), "me")], now: now)
    check(backfill.isEmpty, "backfill / older mail never notifies")
    let fresh = t.arrivals([(m("new1", 30), "me"), (m("new2", 20), "me")], now: now)
    check(fresh.map(\.message.id) == ["new1", "new2"], "mail newer than the watermark notifies")
    check(t.arrivals([(m("new1", 30), "me")], now: now).isEmpty, "the same message never notifies twice")
    check(t.arrivals([(m("late", 25), "me")], now: now).isEmpty, "watermark advances: an older straggler doesn't notify")
    let first = t.arrivals([(m("s1", 5), "shared@x"), (m("s2", 4), "shared@x")], now: now)
    check(first.isEmpty && t.isSeeded("shared@x"), "a mailbox's first sighting (initial sync) only seeds")
    check(t.arrivals([(m("s3", 1), "shared@x")], now: now).map(\.message.id) == ["s3"], "then new mail in it notifies")
    var reset = MailArrivalTracker()
    reset.seed(mailbox: "me", newest: now.addingTimeInterval(-30 * 86_400), now: now)
    check(reset.arrivals([(m("refetched", 3 * 3_600), "me")], now: now).isEmpty, "cache reset re-delivering hours-old mail stays silent")
}

@MainActor
private func attachmentsSurviveDeltaTests() async {
    section("Reader: attachment list survives a header-only sync")
    do {
        let svc = FX()
        let store = try mailStore()
        let sync = MailSync(service: svc, store: store, compliance: mailEngine(), mailboxes: FX.mailboxes, onChange: { _ in })
        await sync.syncNow()
        let first = try await sync.fetchBody(id: FX.Special.attachments)
        check(!first.attachments.isEmpty, "full message brings the attachment list (\(first.attachments.count))")
        try await sync.perform(.markRead(true), on: FX.Special.attachments)
        await sync.flush()
        await sync.syncNow()
        let again = try await sync.fetchBody(id: FX.Special.attachments)
        check(again.attachments.map(\.id) == first.attachments.map(\.id), "second open (body cached, header re-synced) still lists them")
    } catch { check(false, "attachments after delta threw \(error)") }
}

@MainActor
private func searchOpenTests() async {
    section("Search: server-only hits open in the reader")
    do {
        let store = try mailStore()
        let sync = MailSync(service: FX(), store: store, compliance: mailEngine(), mailboxes: FX.mailboxes, onChange: { _ in })
        let hits = await sync.search("Spreadsheet", mailbox: "me", limit: 20, includeServer: true)
        check(!hits.isEmpty, "server search finds the fixture message (\(hits.count))")
        if let h = hits.first {
            check((try? store.message(id: h.id, includeBody: false)) != nil, "server-only hit is in the store, so the reader can load it")
            let full = try? await sync.fetchBody(id: h.id)
            check(full?.id == h.id, "its body loads like any cached message")
        }
        if let id = hits.first?.id {
            var local = try store.message(id: id, includeBody: false)!
            local.snoozedUntil = Date().addingTimeInterval(3_600)
            local.pendingSync = true
            try store.upsert(message: local)
            _ = await sync.search("Spreadsheet", mailbox: "me", limit: 20, includeServer: true)
            let after = try store.message(id: id, includeBody: false)
            check(after?.pendingSync == true && after?.snoozedUntil != nil, "a cached row keeps its local state when the server hit repeats")
        }
    } catch { check(false, "search open threw \(error)") }
}

@MainActor
private func inlineGraphStubTests() async {
    section("Graph: attachment endpoints (stub)")
    let png = FixtureMailService.fixturePNG
    MailStub.handler = { req, _ in
        let path = req.url?.path ?? ""
        if path.hasSuffix("/attachments/att-1/$value") { return (200, [:], "RAWBYTES") }
        if path.hasSuffix("/attachments/att-1") {
            return (200, [:], ##"{"@odata.type":"#microsoft.graph.fileAttachment","id":"att-1","name":"logo.png","contentType":"image/png","isInline":true,"contentId":"logo@x","contentBytes":"\##(png.base64EncodedString())"}"##)
        }
        if path.hasSuffix("/attachments/item-1") { return (200, [:], ##"{"@odata.type":"#microsoft.graph.itemAttachment","id":"item-1","name":"fwd"}"##) }
        return (404, [:], #"{"error":{"code":"ErrorItemNotFound"}}"#)
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let svc = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
    do {
        let c = try await svc.inlineAttachment(messageId: "m1", attachmentId: "att-1", mailbox: "me")
        check(c.contentId == "logo@x" && c.data == png && c.isInline, "inline attachment: contentId + decoded bytes")
        let raw = try await svc.attachmentBytes(messageId: "m1", attachmentId: "att-1", mailbox: "shared@contoso.example")
        check(raw == Data("RAWBYTES".utf8), "$value returns the raw bytes")
        let last = MailStub.lock.withLock { MailStub.log.last }
        check(last?.path.contains("/users/shared@contoso.example/messages/m1/attachments/att-1/$value") == true, "shared mailbox uses /users/{mailbox}")
    } catch { check(false, "attachment stub threw \(error)") }
    do { _ = try await svc.inlineAttachment(messageId: "m1", attachmentId: "item-1", mailbox: "me"); check(false, "item attachment should not inline") }
    catch { check(true, "item attachment (no contentBytes) isn't inlined") }
    do { _ = try await svc.attachmentBytes(messageId: "m1", attachmentId: "gone", mailbox: "me"); check(false, "404 should throw") }
    catch { check((error as? MailServiceError) == .notFound, "404 → notFound") }
    MailStub.handler = nil
}


/// §17: the reader follows Dark Mode. Display-only: sanitiser / CSP / remote blocking are not involved.
@MainActor
private func readerAppearanceTests() {
    section("Reader: Dark Mode body (§17)")
    let plain = "<pre style=\"white-space:pre-wrap;font:inherit;margin:0\">Hi &lt;3</pre>"
    check(!ReaderAppearance.setsOwnColours(plain), "plain-text body sets no colours")
    check(!ReaderAppearance.setsOwnColours("<p>Hello <b>there</b></p><img src=\"data:image/png;base64,AA\">"), "simple HTML sets no colours")
    for styled in ["<td bgcolor=\"#ffffff\">x</td>", "<span style=\"color: #1F497D\">x</span>", "<font color=red>x</font>",
                   "<style>a:link{color:#0563C1}</style>", "<div style='BACKGROUND:#FFF'>x</div>", "<body text=\"#000000\">x</body>"] {
        check(ReaderAppearance.setsOwnColours(styled), "hard-coded colours detected: \(styled)")
    }
    let selfDark = "<style>body{color:#000}@media (prefers-color-scheme: dark){body{color:#fff}}</style>x"
    check(ReaderAppearance.mode(for: plain, original: false) == .plain, "no colours ⇒ native dark stylesheet")
    check(ReaderAppearance.mode(for: "<font color=red>x</font>", original: false) == .adapted, "hard-coded colours ⇒ adapted")
    check(ReaderAppearance.mode(for: selfDark, original: false) == .selfAdapting, "own prefers-color-scheme rules ⇒ self-adapting")
    check(ReaderAppearance.displayBody(selfDark, mode: .selfAdapting, dark: true) == selfDark, "self-adapting body is never remapped")
    check(ReaderAppearance.mode(for: plain, original: true) == .original, "Show original colours wins")
    check(ReaderAppearance.darkCSS(.original, brand: false).isEmpty && ReaderAppearance.darkCSS(.original, brand: true).isEmpty,
          "original emits no dark rules")
    check(ReaderAppearance.darkCSS(.adapted, brand: true, dark: false).isEmpty, "adapted without a remap emits no dark rules (no dark-on-dark)")
    for m in [ReaderColourMode.plain, .selfAdapting, .adapted] {
        let css = ReaderAppearance.darkCSS(m, brand: true)
        check(css.hasPrefix("@media screen and (prefers-color-scheme: dark){") && css.hasSuffix("}"),
              "\(m.rawValue): dark rules are screen + dark scoped (light + print unchanged)")
        check(!css.lowercased().contains("http") && !css.contains("url(") && !css.contains("@import") && !css.contains("filter"),
              "\(m.rawValue): dark rules load nothing and filter nothing")
    }
    check(ReaderAppearance.darkCSS(.plain, brand: false).contains("background:#1E1E1E;color:#EDEDED"), "plain: system dark ground + light text")

    // Remap: lightness inverted, hue kept; only colour literals in style values / <style> / colour attributes.
    let lum: (String) -> Double = { s in
        guard let (r, g, b, _) = ReaderAppearance.parse(s) else { return -1 }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    for dark in ["#000", "#000000", "black", "windowtext", "rgb(0, 0, 0)", "#1F497D", "navy", "hsl(210, 60%, 20%)", "rgba(0,0,0,0.9)"] {
        let out = ReaderAppearance.remapToken(dark)
        check(out != nil && lum(out!) > 0.45, "dark text colour \(dark) becomes light (\(out ?? "nil"))")
    }
    for light in ["#fff", "white", "#F2F2F2", "rgb(255,255,255)"] {
        let out = ReaderAppearance.remapToken(light)
        check(out != nil && lum(out!) < 0.15, "light ground \(light) becomes dark (\(out ?? "nil"))")
    }
    check(ReaderAppearance.remapToken("transparent") == nil && ReaderAppearance.remapToken("inherit") == nil, "keywords left alone")
    let msg = ##"<style>p{color:#000;font-family:"Calibri"}</style><table bgcolor="#ffffff"><tr><td style="background:#FFF url(cid:x) no-repeat;color:navy">Use color:#000 here</td></tr></table><img src="data:image/png;base64,AAAA#fff" style="border:1px solid #000">"##
    let out = ReaderAppearance.remapForDark(msg)
    check(out.contains("bgcolor=\"#121212\""), "bgcolor attribute remapped")
    check(out.contains("p{color:#EDEDED;font-family:\"Calibri\"}"), "<style> block colour remapped, other properties kept")
    check(out.contains("background:#121212 url(cid:x) no-repeat"), "background colour remapped, url(...) untouched")
    check(out.contains(">Use color:#000 here<"), "text nodes are never rewritten")
    check(out.contains("src=\"data:image/png;base64,AAAA#fff\""), "image sources untouched")
    check(out.contains("border:1px solid #EDEDED"), "border colour remapped")
    check(!out.contains("<script") && out.count < msg.count + 40, "remap adds no markup")
    check(ReaderAppearance.displayBody(msg, mode: .adapted, dark: false) == msg, "light appearance: body unchanged")
}
