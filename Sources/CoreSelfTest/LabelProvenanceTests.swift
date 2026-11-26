import Foundation
import CryptoKit
import CalendarCore
import MailCore
import ProtectedContent

// Foreign-tenant labels (2026-11-20): every path a label reaches a row / reader applies the same rule — a label id
// outside our tree that isn't provably ours never shows as one of our labels; the policy stays fail-closed.
// Synthetic GUIDs and tenants only.

@MainActor
func runLabelProvenanceTests() {
    section("Labels: provenance, foreign tenants, display rule, census")
    let home = "11111111-aaaa-4000-8000-000000000001", other = "22222222-bbbb-4000-8000-000000000002"
    let L = FixtureCalendarService.labels
    let oursId = L[0].id
    let eng = CachedLabelPolicyEngine(labels: L, synced: true)
    let foreignId = "99999999-0000-4000-8000-0000000000ff"
    func hdr(_ id: String, site: String?, bits: Int? = nil) -> String {
        var s = "MSIP_Label_\(id)_Enabled=true; MSIP_Label_\(id)_Method=Standard"
        if let site { s += "; MSIP_Label_\(id)_SiteId=\(site)" }
        if let bits { s += "; MSIP_Label_\(id)_ContentBits=\(bits)" }
        return s
    }

    // 1. Parser provenance.
    let rOurs = MIPMetadata.read(hdr(oursId, site: home), homeTenant: home)
    check(rOurs == LabelReading(labelId: oursId, origin: .home), "our SiteId → our label, origin home")
    let rBraced = MIPMetadata.read(hdr(oursId, site: "{\(home.uppercased())}"), homeTenant: home)
    check(rBraced.origin == .home, "SiteId in braces / upper case still recognised as ours")
    let rForeign = MIPMetadata.read(hdr(foreignId, site: other), homeTenant: home)
    check(rForeign.labelId == nil && rForeign.origin == .foreign, "foreign SiteId → no label, origin foreign")
    let rForeignEnc = MIPMetadata.read(hdr(foreignId, site: other, bits: 8), homeTenant: home)
    check(rForeignEnc.labelId == nil && rForeignEnc.origin == .foreignProtected, "foreign encrypting label (ContentBits 0x8) → foreignProtected, no label")
    let rNoSite = MIPMetadata.read(hdr(foreignId, site: nil), homeTenant: home)
    check(rNoSite.labelId == foreignId && rNoSite.origin == .noSite, "no SiteId → id kept (could be ours), origin noSite")
    let rBoth = MIPMetadata.read(hdr(foreignId, site: nil) + "; " + hdr(oursId, site: home), homeTenant: home)
    check(rBoth == LabelReading(labelId: oursId, origin: .home), "our label beats a SiteId-less one")
    let rNoTenant = MIPMetadata.read(hdr(foreignId, site: other), homeTenant: nil)
    check(rNoTenant.labelId == foreignId && rNoTenant.origin == .tenantUnknown, "tenant unknown → first enabled, marked unverified")
    check(MIPMetadata.read(nil) == .none && MIPMetadata.read("MSIP_Label_x_Enabled=false") == .none, "absent / disabled → none")
    check(MIPMetadata.activeLabelId(in: hdr(foreignId, site: other), homeTenant: home) == nil
          && MIPMetadata.activeLabelId(in: hdr(oursId, site: home), homeTenant: home) == oursId, "activeLabelId keeps its contract")

    // 2. Display rule per path.
    func pol(_ id: String?) -> ContentPolicy { eng.policy(labelId: id, isPrivate: false, access: .own, itemId: "x") }
    if case .ours(let l) = LabelDisplay.decide(pol(oursId), origin: .home) { check(l.id == oursId, "ours in tree → chip with its name") }
    else { check(false, "ours in tree → chip with its name") }
    check(LabelDisplay.decide(pol(oursId), origin: nil).showsChip, "in our tree → chip even without provenance (pre-v2 row)")
    check(LabelDisplay.decide(pol(foreignId), origin: .noSite) == .external, "no SiteId + unknown id → external, no chip")
    check(LabelDisplay.decide(pol(foreignId), origin: nil) == .external, "cached pre-v2 unknown id → external, no chip")
    check(LabelDisplay.decide(pol(foreignId), origin: .tenantUnknown) == .external, "tenant-unknown unknown id → external")
    check(LabelDisplay.decide(pol(foreignId), origin: .home) == .unknownOurs(id: foreignId), "provably ours but not synced → honest unknown chip")
    check(!LabelDisplay.decide(pol(foreignId), origin: .noSite).showsChip && LabelDisplay.external.noticeText == "External label",
          "external: no chip, reader notice says External label")
    check(LabelDisplay.decide(ProtectedPolicy.awaitingLicence(pol(nil)), origin: .foreignProtected) == .protectedElsewhere,
          "rpmsg / foreign template → Protected by another organisation, never a label name")
    check(LabelDisplay.decide(pol(nil), origin: .foreignProtected) == .none,
          "foreign ContentBits alone (body readable) → no 'protected' notice")
    check(LabelDisplay.decide(ProtectedPolicy.awaitingLicence(pol(nil)), origin: .foreign) == .protectedElsewhere,
          "rpmsg-detected protection + foreign label → Protected by another organisation")
    check(LabelDisplay.decide(ProtectedPolicy.awaitingLicence(pol(nil)), origin: nil) == .none, "our own encrypt-only mail isn't called foreign")
    check(LabelDisplay.decide(pol(nil), origin: .foreign) == .none, "foreign unencrypted label → nothing shown")
    check(LabelDisplay.visibleMarking(pol(foreignId), origin: .noSite) == nil
          && LabelDisplay.visibleMarking(pol(foreignId), origin: .home) == LabelDisplay.unknownMarking,
          "synthetic 'unavailable — restricted' marking only for provably-ours ids")

    // 2b. Replies don't launder a foreign / unproven id into one of ours.
    let tree = eng.labelTree()
    var orig = MailMessage(id: "o1", folderId: "inbox", conversationId: "c", subject: "S", from: nil, received: Date())
    orig.applyLabel(rNoSite)
    check(MailLabelFloor.inheritableLabel(orig, tree: tree) == nil, "reply: SiteId-less unknown id not inherited")
    let reply = MailDraft(kind: .reply, replyTo: "o1", subject: "Re: S")
    check(MailLabelFloor.enforce(reply, original: orig, engine: eng).labelId == nil, "reply floor: foreign id never stamped on our reply")
    orig.applyLabel(LabelReading(labelId: foreignId, origin: .home))
    check(MailLabelFloor.inheritableLabel(orig, tree: tree) == foreignId, "reply: provably-ours id (not synced) still inherited (fail closed)")
    orig.applyLabel(LabelReading(labelId: foreignId, origin: nil))
    check(MailLabelFloor.inheritableLabel(orig, tree: tree) == foreignId, "reply: legacy unknown id still inherited (fail closed, as before)")
    orig.applyLabel(LabelReading(labelId: oursId, origin: nil))
    check(MailLabelFloor.inheritableLabel(orig, tree: tree) == oursId.lowercased(), "reply: id in our tree inherited whatever its origin")

    // 3. The gates did NOT loosen for an unknown id (whatever the display says).
    let pu = pol(foreignId)
    check(!pu.allowOfflineDetails && pu.preventScreenCapture && pu.rights == .unknownLabel, "unknown id: not cached, capture blocked, restricted rights")
    let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
    var m = MailMessage(id: "u1", folderId: "inbox", conversationId: "c", subject: "S", from: nil, received: Date())
    m.applyLabel(rNoSite)
    check(gate.exposure(m, mailbox: "me", tier: .onDevice) == .excluded && gate.exposure(m, mailbox: "me", tier: .cloud) == .excluded,
          "unknown id (no SiteId): AI excluded on both tiers")
    var enc = MailMessage(id: "u2", folderId: "inbox", conversationId: "c", subject: "S", from: nil, received: Date())
    enc.applyLabel(rForeignEnc)
    check(MailContentPolicy.policy(for: enc, mailbox: "me", engine: eng).labelState == .unlabeled,
          "foreign protected label never becomes our (or an unknown) label")

    // 4. Provenance survives the cache; old payloads decode as not proven.
    do {
        let data = try JSONEncoder().encode(m)
        check(try JSONDecoder().decode(MailMessage.self, from: data).labelOrigin == .noSite, "labelOrigin round-trips")
        var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        obj.removeValue(forKey: "labelOrigin")
        let old = try JSONDecoder().decode(MailMessage.self, from: JSONSerialization.data(withJSONObject: obj))
        check(old.labelOrigin == nil && old.labelId == foreignId, "pre-provenance payload decodes with origin nil")
        var h = old; h.adoptLabel(of: enc)
        check(h.labelId == nil && h.labelOrigin == .foreignProtected, "reader/notifier adopt label + origin together")
    } catch { check(false, "provenance codable: \(error)") }

    // 5. Census (counts only).
    do {
        let store = try MailStore(url: nil, key: SymmetricKey(size: .bits256))
        try store.replace(folders: [MailFolder(id: "inbox", displayName: "Inbox", wellKnown: .inbox)], mailbox: "me")
        func row(_ id: String, _ r: LabelReading) -> MailMessage {
            var x = MailMessage(id: id, folderId: "inbox", conversationId: id, subject: "s", from: nil, received: Date()); x.applyLabel(r); return x
        }
        var legacy = row("r6", .none); legacy.labelId = foreignId   // pre-v2 cached foreign id
        try store.upsert(messages: [row("r1", rOurs), row("r2", rForeign), row("r3", rForeignEnc), row("r4", rNoSite),
                                    row("r5", .none), legacy])
        let c = try store.labelCensus(known: Set(L.map { $0.id.lowercased() }))
        check(c.rows == 6 && c.ours == 1 && c.foreignIgnored == 2 && c.noSite == 1 && c.unknownId == 2 && c.rpmsgForeign == 1,
              "census: rows 6, ours 1, foreign 2, noSite 1, unknownId 2, foreign-protected 1")
        check(c.logLine.hasPrefix("[Labels] rows=6 ") && !c.logLine.contains(foreignId) && !c.logLine.contains("s"+"ubject"),
              "census log line is content-free")
    } catch { check(false, "census store: \(error)") }

    // 6. OfficeMCP: tenant from the access token's tid claim.
    func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    let jwt = b64(#"{"alg":"none"}"#) + "." + b64(#"{"tid":"\#(home.uppercased())","oid":"x"}"#) + ".sig"
    check(MIPMetadata.tenantId(fromAccessToken: jwt) == home, "MCP: tenant read from token tid")
    check(MIPMetadata.tenantId(fromAccessToken: "not-a-jwt") == nil, "MCP: opaque token → nil")
}

// Message list rows (Gmail-style, docs/LIST-LAYOUT.md): badge priority, fixed heights, clean list persistence.
@MainActor
func runListLayoutTests() {
    section("List rows: badges, heights, clean list")
    let B = ListRowLayout.self
    check(B.badges(label: true, triage: .replyNeeded, attachment: true, clean: false) == [.label, .replyNeeded],
          "at most two badges: label mark first, then reply-needed (attachment dropped)")
    check(B.badges(label: false, triage: .waiting, attachment: true, clean: false) == [.waiting, .attachment], "no label: waiting, attachment")
    check(B.badges(label: false, triage: nil, attachment: true, clean: false) == [.attachment], "attachment alone")
    check(B.badges(label: true, triage: .replyNeeded, attachment: true, clean: true) == [.label], "clean list: label mark only")
    check(B.badges(label: true, triage: nil, attachment: true, clean: false, limit: 0) == [.label], "the label mark is never the one dropped")
    check(B.badges(label: false, triage: .label, attachment: false, clean: false).isEmpty, "only triage tags count as triage badges")
    check(B.twoLine(.right) && !B.twoLine(.bottom) && !B.twoLine(.off), "two-line rows only beside a right reading pane")
    check(ListDensity.allCases.allSatisfy { B.rowHeight($0, twoLine: true) > B.rowHeight($0) }, "two-line rows are taller, still fixed")
    check(ListDensity.allCases.allSatisfy { B.rowHeight($0) > 0 } && B.rowHeight(.compact) < B.rowHeight(.standard)
          && B.rowHeight(.standard) < B.rowHeight(.roomy), "one fixed height per density, increasing")
    check(!B.showsAvatar(.compact, clean: false, avatarsOn: true) && B.showsAvatar(.standard, clean: false, avatarsOn: true)
          && !B.showsAvatar(.standard, clean: true, avatarsOn: true) && !B.showsAvatar(.roomy, clean: false, avatarsOn: false),
          "avatars: not in compact or clean list, else as set")
    check(B.showsSecondary(selected: true, clean: false) && !B.showsSecondary(selected: false, clean: false)
          && !B.showsSecondary(selected: true, clean: true), "secondary indicators: selected row only, never in clean list")
    check(B.snippet("  Line one\nline two ", previewLines: 2) == "Line one line two" && B.snippet("x", previewLines: 0) == nil
          && B.snippet("  ", previewLines: 2) == nil, "snippet: one line, honours 'no preview'")

    let suite = "listlayout-selftest-\(UUID().uuidString)"
    guard let d = UserDefaults(suiteName: suite) else { check(false, "UserDefaults suite"); return }
    defer { d.removePersistentDomain(forName: suite) }
    check(MailViewPreferences.load(d).cleanList == false, "clean list off by default")
    var p = MailViewPreferences(); p.cleanList = true; p.density = .compact; p.save(d)
    let q = MailViewPreferences.load(d)
    check(q.cleanList && q.density == .compact, "clean list + compact density persist")
}
