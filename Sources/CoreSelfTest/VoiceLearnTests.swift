import Foundation
import CalendarCore
import MailCore

/// VOICE2: detectors, suggested layers, gated AI step, nudges + rate limit, signature import. Synthetic only.
@MainActor
func runVoiceLearnTests() async {
    section("AI voice 2: learn, nudge, signature import")
    let L = FixtureCalendarService.labels
    let eng = CachedLabelPolicyEngine(labels: L, synced: true)
    let gate = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .followLabels)
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    func msg(_ id: String, from: String, body: String, label: String? = nil, priv: Bool = false, days: Double = 0,
             to: String = "you@contoso.example", html: Bool = false) -> MailMessage {
        MailMessage(id: id, folderId: "inbox", conversationId: "conv-\(id)", subject: "Subject-\(id)",
                    from: .init(name: "Anna Muster", address: from), toRecipients: [.init(name: "", address: to)],
                    received: base.addingTimeInterval(days * 86_400), preview: nil, body: body, bodyIsHTML: html,
                    labelId: label, isPrivate: priv, changeKey: "ck")
    }

    // 1. Detectors.
    check(VoiceSignals.formality("Hoi Anna\n\nKannst du mir das bis Freitag schicken? Danke dir.\n\nLiebe Grüsse\nJordan") == .informal,
          "detect: German Du")
    check(VoiceSignals.formality("Grüezi Frau Muster\n\nBesten Dank für Ihre Nachricht. Gerne sende ich Ihnen die Unterlagen.\n\nFreundliche Grüsse") == .formal,
          "detect: German Sie (capitalised mid-sentence)")
    check(VoiceSignals.formality("Sie haben recht. Das geht durch die direkte Leitung, wie besprochen mit dem Team heute.", language: .de) == nil,
          "detect: sentence-initial 'Sie' and 'durch'/'direkte' are not Du/Sie markers")
    check(VoiceSignals.formality("Bonjour Madame,\n\nMerci pour votre message. Je vous envoie le document demain.\n\nCordialement") == .formal
          && VoiceSignals.formality("Salut Marc,\n\nTu peux me renvoyer ton fichier ? Merci à toi.\n\nA plus", language: .fr) == .informal,
          "detect: French vous / tu")
    check(VoiceSignals.formality("Hi Kim, could you send me the report by Friday? Thanks a ton.") == nil, "detect: English has no Du/Sie")
    check(VoiceSignals.greeting("Hoi Anna\n\nText") == "Hoi" && VoiceSignals.greeting("Sehr geehrte Frau Muster\nText") == "Sehr geehrte"
          && VoiceSignals.greeting("Bonjour Marc,\nTexte") == "Bonjour" && VoiceSignals.greeting("Hiking is fun\nText") == nil
          && VoiceSignals.greeting("Thanks, got it.") == nil, "detect: greetings by token (not 'Hiking')")
    check(VoiceSignals.signOff("Text here.\n\nLiebe Grüsse\nAnna") == "Liebe grüsse" && VoiceSignals.signOff("Text\n\nCheers,\nJordan") == "Cheers"
          && VoiceSignals.signOff("Just the message.") == nil, "detect: sign-offs from the closed list")
    check(VoiceSignals.language("Kannst du mir bitte die Unterlagen bis Freitag schicken? Das wäre super.") == .de
          && VoiceSignals.language("Could you please send me the documents by Friday? That would be great.") == .en, "detect: language on-device")

    // 2. Facts → suggested layer: facts only, nothing from blocked mail.
    let anna = "anna@fabrikam.ch"
    let received = [
        msg("r1", from: anna, body: "Hoi Jordan\n\nKannst du mir das Angebot bis Freitag schicken? Danke dir vielmals.\n\nLiebe Grüsse\nAnna", days: -10),
        msg("r2", from: anna, body: "Hoi Jordan\n\nDein Vorschlag passt, wir machen es so wie du gesagt hast.\n\nLiebe Grüsse\nAnna", days: -40),
        msg("r3", from: anna, body: "SECRET-CONF Sehr geehrter Herr Miller, Ihre Offerte ist bei uns eingetroffen. Freundliche Grüsse", label: L[4].id, days: -5),
        msg("r4", from: anna, body: "PRIVATE-BODY Sehr geehrter Herr, Sie Ihnen Ihre", priv: true, days: -3),
    ]
    let sent = [msg("s1", from: "you@contoso.example", body: "Passt, mache ich bis Freitag.", days: -9, to: anna),
                msg("s2", from: "you@contoso.example", body: "Klar, ich schicke dir das morgen.", days: -39, to: anna)]
    let f = VoiceLearn.facts(address: anna, displayName: "Muster, Anna", directory: VoiceDirectoryFacts(title: "Head of IT", company: "Fabrikam AG"),
                             internalDomains: ["contoso.example"], received: received, sent: sent, mailbox: "me", gate: gate)
    check(f.received == 3 && f.sent == 2 && f.skipped == 1 && f.analysed == 4 && !f.isInternal,
          "facts: counts exclude private, blocked text skipped (\(f.received)/\(f.sent)/\(f.skipped)/\(f.analysed))")
    check(f.formality == .informal && f.language == .de && f.greeting == "Hoi" && f.signOff == "Liebe grüsse"
          && f.userGreets == false, "facts: Du, German, 'Hoi', sign-off, user writes without greeting")
    let sc = VoiceLearn.suggestedContact(f)
    check(sc.formality == .informal && sc.language == .de && sc.addressAs == "Anna" && sc.notes.contains("Role: Head of IT at Fabrikam AG")
          && sc.notes.contains("without a greeting") && sc.notes.contains("3 mails from them, 2 from you"),
          "suggested contact: structured from facts")
    let all = sc.notes + sc.displayName + sc.addressAs
    check(!all.contains("SECRET") && !all.contains("Offerte") && !all.contains("PRIVATE") && !all.contains("Angebot")
          && !all.contains("Vorschlag") && !sc.notes.contains("Topics") && !sc.notes.contains("["),
          "suggested contact: no mail text, no blocked mail, no placeholder guesses")
    var pv = msg("pv", from: "you@contoso.example", body: "", days: -1, to: anna); pv.body = nil
    pv.preview = "Hoi Anna, passt, ich schicke dir das Angebot morgen. Danke dir für die schnelle Antwort und bis bald."
    let fp = VoiceLearn.facts(address: anna, displayName: "Anna", directory: nil, internalDomains: [], received: [], sent: [pv], mailbox: "me", gate: gate)
    check(fp.userSignsOff == nil && fp.userGreets == true, "facts: a preview (no body) is no evidence about sign-offs")
    let off = AIGatePolicy(engine: eng, cloudAccess: .followLabels, onDeviceAccess: .off)
    let f0 = VoiceLearn.facts(address: anna, displayName: "Anna", directory: nil, internalDomains: [], received: received, sent: sent, mailbox: "me", gate: off)
    check(f0.analysed == 0 && f0.formality == nil && f0.language == nil && f0.received == 3,
          "facts: on-device AI off by policy → metadata facts only, no text read")
    let so = VoiceLearn.suggestedOrg(key: "fabrikam.ch", displayName: nil, contacts: [f])
    check(so?.displayName == "Fabrikam AG" && so?.formality == .informal && so?.notes.contains("external organisation") == true
          && VoiceLearn.suggestedOrg(key: "gmail.com", displayName: nil, contacts: [f]) == nil, "suggested org: facts; free-mail → none")
    let merged = VoiceLearn.merge(notes: "Role: Head of IT\nRemember: external", ai: ["Role": "CEO", "Style": "prefers bullets", "Bogus": "x", "Remember": ""],
                                  fields: VoiceLearn.contactFields)
    check(merged == "Role: Head of IT\nStyle: prefers bullets\nRemember: external", "merge: facts win, AI fills gaps, unknown keys dropped")

    // 3. AI step uses the gate.
    do {
        var s = AIAssistSettings(); s.choice = .claudeCLI
        let fake = FakeProvider(reply: { _ in #"{"Role":"Head of IT","Style":"short and practical","Language":"","Remember":"unknown","Address":""}"# })
        let a = AIAssistant(settings: s, gate: gate, cloud: fake, onDevice: nil, audit: { _ in }, now: { base })
        let notes = try await a.suggestVoiceNotes(organisation: false, title: "Anna", messages: received, mailbox: "me")
        let u = fake.calls.first?.user ?? ""
        check(fake.calls.count == 1 && u.contains("Angebot") && !u.contains("SECRET-CONF") && !u.contains("PRIVATE-BODY"),
              "AI step: prompt via AIPromptBuilder, blocked / private mail never in it")
        check(notes == ["Role": "Head of IT", "Style": "short and practical"], "AI step: empty / 'unknown' values dropped (\(notes))")
        let blocked = FakeProvider(reply: { _ in "{}" })
        let b = AIAssistant(settings: s, gate: gate, cloud: blocked, onDevice: nil, audit: { _ in }, now: { base })
        var refused = false
        do { _ = try await b.suggestVoiceNotes(organisation: false, title: "Anna", messages: [received[2], received[3]], mailbox: "me") }
        catch AIAssistError.notAllowed { refused = true } catch {}
        check(refused && blocked.calls.isEmpty, "AI step: nothing shareable → refused with zero provider calls")
        var offS = s; offS.choice = .off
        var offRefused = false
        do { _ = try await AIAssistant(settings: offS, gate: gate, cloud: blocked, onDevice: nil, audit: { _ in }).suggestVoiceNotes(
            organisation: true, title: "Fabrikam", messages: received, mailbox: "me") } catch { offRefused = true }
        check(offRefused && blocked.calls.isEmpty, "AI step: AI off → no call")
    } catch { check(false, "AI step threw \(error)") }

    // 4. Edit diff + nudges.
    let draftDE = "Hoi Anna\n\nDanke dir für die Nachricht. Ich schicke dir das Angebot bis Freitag, damit du es noch prüfen kannst.\n\nLiebe Grüsse\nJordan"
    let e1 = VoiceEditDiff.compare(draft: draftDE, sent: "Danke dir für die Nachricht. Ich schicke dir das Angebot bis Freitag, damit du es noch prüfen kannst.")
    check(e1.kinds.contains(.removedGreeting) && e1.kinds.contains(.removedSignOff) && !e1.kinds.contains(.toFormal),
          "diff: removed greeting and sign-off")
    let e2 = VoiceEditDiff.compare(draft: draftDE, sent: "Grüezi Frau Muster\n\nBesten Dank für Ihre Nachricht. Ich sende Ihnen die Offerte bis Freitag, damit Sie diese prüfen können.\n\nFreundliche Grüsse\nJordan Miller")
    check(e2.kinds == [.toFormal], "diff: Du → Sie (\(e2.kinds))")
    let e3 = VoiceEditDiff.compare(draft: draftDE, sent: "Hi Anna\n\nThanks for your message. I'll send you the offer by Friday so you can still review it.\n\nCheers\nJordan")
    check(e3.kinds == [.changedLanguage] && e3.language == .en, "diff: language changed to English")
    let e4 = VoiceEditDiff.compare(draft: draftDE, sent: "Hoi Anna\n\nPasst, bis Freitag.\n\nLiebe Grüsse\nJordan")
    check(e4.kinds == [.shortened], "diff: shortened > 40 %")
    check(VoiceEditDiff.normalise("Body text\n\nJordan Miller\nConsultant\n\nOn Mon, Anna wrote:\n> old", signaturePlain: "Jordan Miller\nConsultant") == "Body text",
          "diff: signature and quoted history cut before comparing")

    var log = VoiceNudgeLog()
    let n1 = VoiceNudges.afterSend(e1, contact: anna, name: "Anna", log: &log, now: base)
    check(n1?.kind == .removedGreeting && n1?.target == .contact(address: anna, name: "Anna")
          && n1?.text == "You removed the greeting — remember that for Anna?", "nudge: removed greeting → Anna")
    check(VoiceNudges.afterSend(e2, contact: anna, name: "Anna", log: &log, now: base.addingTimeInterval(86_400)) == nil,
          "nudge: rate limit — at most one per contact per 30 days")
    let n2 = VoiceNudges.afterSend(e2, contact: anna, name: "Anna", log: &log, now: base.addingTimeInterval(31 * 86_400))
    check(n2?.kind == .toFormal && n2.map { $0.applied(to: VoiceContact(address: anna, formality: .informal)).formality } == .formal,
          "nudge: after 30 days, Du→Sie prefills the formality")
    log.muted.insert("bob@x.ch")
    _ = VoiceNudges.afterSend(e1, contact: "bob@x.ch", name: "Bob", log: &log, now: base.addingTimeInterval(2 * 86_400))
    let n3 = VoiceNudges.afterSend(e1, contact: "cara@y.ch", name: "Cara", log: &log, now: base.addingTimeInterval(3 * 86_400))
    check(n3?.target == .me && n3?.text.contains("your own voice") == true
          && n3.map { $0.applied(toMe: "Me text").contains("no greeting") } == true,
          "nudge: same edit across 3 contacts (one muted, one rate-limited) → Me")
    var mlog = log; mlog.muted.insert(VoiceNudgeLog.me)
    let nf = VoiceNudges.afterSend(e1, contact: "gil@w.ch", name: "Gil", log: &mlog, now: base.addingTimeInterval(4 * 86_400))
    check(nf?.target == .contact(address: "gil@w.ch", name: "Gil"), "nudge: Me muted → the contact is still offered")
    let mm = VoiceNudges.mismatch(layer: VoiceContact(address: "dan@z.ch", formality: .informal), observedFormality: .formal,
                                  observedLanguage: nil, name: "Dan", log: &log, now: base)
    check(mm?.kind == .threadFormality && mm.map { $0.applied(to: VoiceContact(address: "dan@z.ch", formality: .informal)).formality } == .formal
          && VoiceNudges.mismatch(layer: VoiceContact(address: "dan@z.ch", formality: .informal), observedFormality: .formal,
                                  observedLanguage: nil, name: "Dan", log: &log, now: base.addingTimeInterval(60)) == nil,
          "nudge: thread Du/Sie differs from the layer (then rate-limited)")
    let ml = VoiceNudges.mismatch(layer: VoiceContact(address: "eve@z.ch", language: .fr), observedFormality: nil, observedLanguage: .de,
                                  name: "Eve", log: &log, now: base)
    check(ml?.kind == .threadLanguage && ml?.language == .de
          && VoiceNudges.mismatch(layer: VoiceContact(address: "fay@z.ch"), observedFormality: .formal, observedLanguage: .de,
                                  name: "Fay", log: &log, now: base) == nil, "nudge: thread language differs; 'mirror' layers never nudge")
    check(VoiceNudges.needsReview(updated: base, mailsSince: 12, now: base.addingTimeInterval(181 * 86_400))
          && !VoiceNudges.needsReview(updated: base, mailsSince: 9, now: base.addingTimeInterval(181 * 86_400))
          && !VoiceNudges.needsReview(updated: nil, mailsSince: 50, now: base.addingTimeInterval(999 * 86_400)),
          "nudge: review after 180 days and ≥10 mails; unstamped layers never stale")
    do {
        let json = String(decoding: try JSONEncoder().encode(log), as: UTF8.self)
        check(!json.contains("Hoi") && !json.contains("Angebot") && !json.contains("Freitag") && !json.contains("Anna")
              && json.contains("removedGreeting") && json.contains(anna), "nudge log: kinds, keys, dates only (no mail text)")
        let old = try JSONDecoder().decode(VoiceContact.self, from: Data(#"{"address":"a@b.ch"}"#.utf8))
        check(old.updated == nil, "voice layer: old saved layer decodes with no 'updated' stamp")
    } catch { check(false, "nudge log encode threw \(error)") }

    // 5. Signature import.
    let sigHTML = "<p>Jordan Miller<br>Senior Consultant</p><p>Contoso AG · <a href=\"https://contoso.example\">contoso.example</a></p><p><img src=\"cid:logo@1\"></p>"
    func sample(_ id: String, _ html: String?, plain: String? = nil, days: Double, from: String = "you@contoso.example") -> SignatureSample {
        SignatureSample(id: id, from: from, html: html, plain: plain, received: base.addingTimeInterval(days * 86_400))
    }
    let samples = [
        sample("a", "<p>Hi Anna</p><p>Done.</p><p>Cheers,<br>Jordan</p>" + sigHTML.replacingOccurrences(of: "logo@1", with: "logo@A")
               + "<div id=\"divRplyFwdMsg\"><p>From: Anna</p><p>Jordan Miller<br>Senior Consultant</p></div>", days: -1),
        sample("b", "<p>Passt.</p><p>Liebe Grüsse<br>R.</p>" + sigHTML.replacingOccurrences(of: "logo@1", with: "logo@B"), days: -2),
        sample("c", "<p>Thanks.</p><p>Best regards,<br>Jordan</p>" + sigHTML, days: -3),
        sample("d", nil, plain: "On it.\n\nSent from my iPhone", days: -4),
        sample("e", "<p>Merci.</p>" + sigHTML, days: -5),
        sample("x", "<p>Other</p><p>Kim Example</p>", days: -6, from: "shared@contoso.example"),
    ]
    let prop = SignatureLearn.propose(samples)
    check(prop?.identity == "you@contoso.example" && prop?.support == 4 && prop?.total == 5 && prop?.exemplarId == "a",
          "signature import: identity, 4 of 5 (iPhone outlier), newest exemplar")
    check(prop?.lines.first == "Jordan Miller" && prop?.lines.contains("Senior Consultant") == true && prop?.lines.last == "[image]"
          && prop?.lines.contains { $0.contains("Cheers") || $0.contains("Grüsse") || $0.contains("From:") } == false,
          "signature import: common suffix, varying sign-offs and quoted history excluded (\(prop?.lines ?? []))")
    check(prop?.cids == ["logo@A"] && RichHTML.html(prop?.doc ?? RichDoc()).contains("https://contoso.example"),
          "signature import: HTML kept (link), image by cid of the exemplar")
    check(SignatureLearn.propose(Array(samples.prefix(2))) == nil
          && SignatureLearn.propose([sample("p", nil, plain: "One", days: 0), sample("q", nil, plain: "Two", days: 0),
                                     sample("r", nil, plain: "Three", days: 0)]) == nil,
          "signature import: too few mails / nothing common → no proposal")
    let plainSig = (0..<4).map { sample("pl\($0)", nil, plain: "Body \($0)\n\n-- \nJordan Miller\nContoso AG\n\nAm 1.1. schrieb Anna:\n> alt", days: Double(-$0)) }
    check(SignatureLearn.propose(plainSig)?.lines == ["--", "Jordan Miller", "Contoso AG"], "signature import: plain text, quoted history cut")
    // Owner, 2026-11-20: an internal colleague writing English with "Hi", plus forwarded customer mail in "Sie",
    // was suggested as Sie. Forwards don't count; English + internal → informal; formal needs ≥ 2 clear votes.
    check(VoiceLearn.isForward("FW: 4928677 : PURCHASE ORDER") && VoiceLearn.isForward("WG: Offerte") && !VoiceLearn.isForward("Re: Plan"),
          "voice: forwards recognised (FW/WG)")
    check(VoiceLearn.decideFormality(language: .en, theirs: [(.de, .formal)], mine: [], greeting: "Hi", isInternal: true) == .informal,
          "voice: English-writing colleague with Hi → informal, a stray German Sie ignored")
    check(VoiceLearn.decideFormality(language: .de, theirs: [(.de, .formal)], mine: [], greeting: nil, isInternal: true) == .informal,
          "voice: one Sie vote isn't enough against the colleague default")
    check(VoiceLearn.decideFormality(language: .de, theirs: [(.de, .formal), (.de, .formal), (.de, .informal)], mine: [], greeting: nil,
                                     isInternal: false) == .formal, "voice: clear German Sie from an external contact → formal")
    check(VoiceLearn.decideFormality(language: .en, theirs: [], mine: [], greeting: nil, isInternal: false) == nil,
          "voice: external English contact without evidence → no formality claim")

}
