import Foundation
import MailCore

// Synthetic Swiss business mailbox (DE majority, EN, some FR/IT) with graded relevance judgements.
// Everything here is invented: people, companies, numbers. Dates are relative to the run's `now`, because the
// semantic index cuts its 90-day window with the real clock.

struct BenchQuery {
    enum Category: String, CaseIterable { case keyword, crossLanguage, paraphrase, people, time, attachment, phrase, typo, umlaut, abbreviation, body, prefix }
    var text: String
    var category: Category
    /// Held out: written before any improvement and not consulted while tuning expansions / weights.
    var holdout: Bool
    /// message id → grade (2 = what the user is looking for, 1 = related / partially relevant).
    var qrels: [String: Int]
}

struct BenchCorpus {
    var messages: [MailMessage] = []
    /// Full bodies + attachment names, delivered later as if the user had opened the message.
    var opened: [String: (body: String, attachments: [AttachmentInfo])] = [:]
    var queries: [BenchQuery] = []
    /// Labelled (unknown label → fail-closed) rows whose content contains query terms. Must never match on content.
    var protectedIds: Set<String> = []
    static let me = EmailAddress(name: "Alex Frei", address: "alex.frei@niivo.example")
}

func p(_ n: String, _ a: String) -> EmailAddress { EmailAddress(name: n, address: a) }

let anna = p("Anna Meier", "anna.meier@fabrikam.ch")
let peter = p("Peter Müller", "peter.mueller@fabrikam.ch")
let annaS = p("Anna Schmid", "anna.schmid@niivo.example")
let thomas = p("Thomas Brunner", "thomas.brunner@contoso-treuhand.example")
let sophie = p("Sophie Dubois", "sophie.dubois@lumen-sa.example")
let marco = p("Marco Rossi", "marco.rossi@ticinonet.example")
let james = p("James Carter", "james.carter@northwind.example")
let sarah = p("Sarah Thompson", "sarah.thompson@adatum.example")
let reto = p("Reto Huber", "reto.huber@niivo.example")
let laura = p("Laura Keller", "laura.keller@niivo.example")
let nina = p("Nina Graf", "nina.graf@gruenwald-immobilien.example")
let mike = p("Mike Ward", "mike.ward@greendc.example")
let beat = p("Beat Zürcher", "beat.zuercher@netzwerk-ag.example")
let lukas = p("Lukas Weber", "lukas.weber82@gmail.example")
let digitec = p("Techshop", "noreply@techshop.example")
let nzz = p("Daily Briefing", "newsletter@dailynews.example")
let teams = p("Microsoft Teams", "noreply@email.teams.microsoft.com")
let itsec = p("IT Security", "security@niivo.example")
let hotel = p("Seminarhotel Phoenix", "info@hotel-phoenix.example")
let legal = p("Rechtsdienst", "legal@contoso-treuhand.example")

func buildCorpus(now: Date, calendar: Calendar = .current) -> BenchCorpus {
    var c = BenchCorpus()
    let me = BenchCorpus.me
    func ago(_ d: Double, hour: Int = 10) -> Date {
        let day = calendar.date(byAdding: .day, value: -Int(d), to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: hour, minute: 15, second: 0, of: day)!
    }
    // Wednesday of the previous calendar week (always "last week", whatever weekday the bench runs on).
    var cal = calendar; cal.firstWeekday = 2
    let thisMonday = cal.dateInterval(of: .weekOfYear, for: now)!.start
    let lastWeekWed = cal.date(byAdding: .day, value: -5, to: thisMonday)!.addingTimeInterval(10 * 3600)
    let lastWeekThu = lastWeekWed.addingTimeInterval(86_400 + 3_600)
    let twoWeeksWed = lastWeekWed.addingTimeInterval(-7 * 86_400)

    func add(_ id: String, _ from: EmailAddress, _ subject: String, _ body: String, _ date: Date, to: [EmailAddress]? = nil,
             att: [String] = [], conv: String? = nil, label: String? = nil) {
        let sent = from == me
        let flat = body.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        let preview = String(flat.prefix(200))
        let atts = att.enumerated().map { i, n in
            AttachmentInfo(id: "\(id)-a\(i)", name: n, contentType: n.hasSuffix(".pdf") ? "application/pdf" : "application/octet-stream", size: 120_000)
        }
        c.messages.append(MailMessage(id: id, folderId: sent ? "sent" : "inbox", conversationId: conv ?? id, subject: subject, from: from,
                                      toRecipients: to ?? [me], received: date, preview: preview, isRead: true,
                                      hasAttachments: !att.isEmpty, labelId: label))
        c.opened[id] = (body, atts)
    }
    func d(_ n: Double) -> Date { ago(n) }

    // Fabrikam: invoices, delay, maintenance contract.
    add("inv-fab-1", anna, "Rechnung RE-2026-0412", "Guten Tag Herr Frei\n\nAnbei erhalten Sie unsere Rechnung RE-2026-0412 über CHF 18'450.00 für die Lieferung der Serverschränke und das Montagematerial. Zahlbar innert 30 Tagen netto.\n\nFreundliche Grüsse\nAnna Meier\nBuchhaltung Fabrikam AG", d(12), att: ["Rechnung_RE-2026-0412.pdf"])
    add("inv-fab-2", anna, "Zahlungserinnerung: Rechnung RE-2026-0412", "Guten Tag\n\nGemäss unserer Buchhaltung ist die Rechnung RE-2026-0412 noch offen. Wir bitten Sie, den Betrag von CHF 18'450.00 in den nächsten 10 Tagen zu überweisen. Sollte sich Ihre Zahlung mit diesem Schreiben gekreuzt haben, betrachten Sie es als gegenstandslos.\n\nFabrikam AG", d(2))
    add("inv-fab-3", anna, "Rechnung RE-2026-0233 Wartung Q3", "Guten Tag\n\nIn der Beilage senden wir Ihnen die Rechnung für die Wartungsleistungen im dritten Quartal. Bei Fragen stehe ich gerne zur Verfügung.\n\nAnna Meier, Fabrikam AG", d(75), att: ["RE-2026-0233.pdf"])
    add("fab-delay", peter, "Lieferverzögerung Serverschränke", "Hallo Alex\n\nLeider verzögert sich die Lieferung der Serverschränke um ca. zwei Wochen, da unser Zulieferer Engpässe bei den Seitenwänden hat. Neuer Liefertermin ist KW 47. Entschuldige die Umstände.\n\nGruss Peter", d(20))
    add("fab-contract", peter, "Wartungsvertrag 2027 – zur Unterschrift", "Hallo Alex\n\nWie besprochen sende ich dir den Wartungsvertrag 2027 für die Serverinfrastruktur zur Unterschrift. Laufzeit 24 Monate, Reaktionszeit 4 Stunden an Werktagen. Die Preise sind gegenüber dem Vorjahr unverändert, der Pikettdienst ist als Option aufgeführt. Bitte unterschreibe beide Exemplare und sende uns eines zurück. Die Kündigungsfrist beträgt sechs Monate auf Ende der Laufzeit.\n\nGruss Peter", d(9), att: ["Wartungsvertrag_2027_Fabrikam.pdf"], conv: "c-fabcon")
    add("fab-contract-q", me, "Re: Wartungsvertrag 2027 – zur Unterschrift", "Hallo Peter, danke dir. Eine Frage zum Vertrag: ist der Pikettdienst am Wochenende inbegriffen oder nur werktags? Dann unterschreibe ich diese Woche.\n\nGruss Alex", d(8), to: [peter], conv: "c-fabcon")

    // Other vendors' invoices (hard negatives for "Fabrikam").
    add("inv-adatum", sarah, "Invoice INV-5531 – October consulting", "Hi Alex,\n\nPlease find attached invoice INV-5531 for the consulting days delivered in October (6 days). Payment terms are 30 days. Let me know if you need a PO number on it.\n\nBest regards,\nSarah", d(15), att: ["INV-5531.pdf"])
    add("inv-lumen", sophie, "Facture 2026-88 – prestations octobre", "Bonjour Monsieur Frei,\n\nVeuillez trouver ci-joint notre facture 2026-88 pour les prestations du mois d'octobre. Le paiement est à effectuer sous 30 jours.\n\nMeilleures salutations\nSophie Dubois, Lumen SA", d(18), att: ["Facture_2026-88.pdf"])
    add("inv-ticino", marco, "Fattura n. 341 – canone hosting novembre", "Buongiorno Alex,\n\nin allegato trova la fattura n. 341 relativa al canone di hosting per il mese di novembre. Il pagamento è previsto entro 30 giorni.\n\nCordiali saluti\nMarco Rossi, TicinoNet", d(6), att: ["Fattura_341.pdf"])
    add("inv-digitec", digitec, "Ihre Rechnung zur Bestellung 88123451", "Vielen Dank für Ihre Bestellung. Die Rechnung finden Sie in Ihrem Kundenkonto. Lieferung: 2x USB-C Dockingstation.", d(25))
    add("inv-digitec-2", digitec, "Rechnung zur Bestellung 87011223", "Vielen Dank für Ihre Bestellung. Die Rechnung finden Sie in Ihrem Kundenkonto. Lieferung: 1x Monitor 27 Zoll.", d(60))

    // Server move.
    add("srv-1", reto, "Serverumzug RZ Glattbrugg – Planung", "Hallo zusammen\n\nWir ziehen am Wochenende vom 14./15. die produktiven Server ins Rechenzentrum Glattbrugg um. Bitte prüft bis Mittwoch eure Applikationen auf der Liste im Anhang und meldet Abhängigkeiten.\n\nGruss Reto", d(16), to: [me, laura], conv: "c-srv")
    add("srv-2", me, "Re: Serverumzug RZ Glattbrugg – Planung", "Danke Reto. Für die ERP-VMs brauchen wir ein Wartungsfenster ab 18 Uhr, sonst ist die Buchhaltung blockiert. Die Datenbank sollte zuletzt verschoben werden.\n\nAlex", d(15), to: [reto], conv: "c-srv")
    add("srv-3", reto, "Serverumzug: Checkliste Cutover", "Hallo Alex\n\nAnbei die Checkliste für den Cutover. Reihenfolge: Storage, Hypervisor, Datenbank, Applikationen. Rollback-Entscheid spätestens Sonntag 12 Uhr.\n\nReto", d(11), att: ["Cutover_Checkliste.xlsx"])
    add("srv-4", mike, "Colocation move – cutover window confirmed", "Hi Alex,\n\nwe confirm the cutover window for your rack relocation to our Glattbrugg facility on Saturday from 06:00. Our remote hands team will be on site. Please send the final cabling plan by Thursday.\n\nMike Ward, Green DC", d(10))
    add("srv-5", reto, "Umzug abgeschlossen – alle Systeme laufen", "Hallo zusammen\n\nDer Umzug der Server ist abgeschlossen. Alle VMs laufen im neuen RZ, die Backups sind wieder grün. Danke für eure Geduld!\n\nReto", d(4), to: [me, laura, annaS])
    add("office-move", laura, "Büroumzug Winterthur: Kisten packen bis Freitag", "Hallo zusammen\n\nFür den Büroumzug nach Winterthur bitte eure persönlichen Sachen bis Freitag in die beschrifteten Kisten packen. Die Zügelfirma kommt am Montag um 7 Uhr.\n\nLaura", d(30))

    // Audit (Swiss: "Revision").
    add("aud-1", annaS, "Revision 2026: Unterlagen für Contoso Treuhand", "Hallo Alex\n\nFür die Revision brauche ich bis Ende Monat noch die Lizenzübersicht und die Zugriffsberechtigungen aufs ERP. Kannst du mir das als Export schicken?\n\nDanke, Anna", d(14))
    add("aud-2", annaS, "Audit – offene Punkte Jahresabschluss", "Hallo Alex\n\nDie Revisoren von Contoso haben noch drei offene Punkte zum IT-Kontrollsystem: Passwortrichtlinie, Backup-Tests und Rechtevergabe. Details in der Liste.\n\nAnna", d(5), att: ["Offene_Punkte_Revision.xlsx"])
    add("aud-3", thomas, "Prüfungsplanung Revision 2026", "Sehr geehrter Herr Frei\n\nGerne bestätigen wir den Termin für die Zwischenrevision am 2. Dezember. Wir werden insbesondere die IT-Kontrollen und das Berechtigungskonzept prüfen.\n\nFreundliche Grüsse\nThomas Brunner, Contoso Treuhand AG", d(22))
    add("aud-4", thomas, "Revisionsbericht 2025 (final)", "Sehr geehrter Herr Frei\n\nIn der Beilage erhalten Sie den finalen Revisionsbericht 2025 mit unseren Empfehlungen zum internen Kontrollsystem.\n\nThomas Brunner", d(120), att: ["Revisionsbericht_2025.pdf"])
    add("annaS-spesen", annaS, "Spesenabrechnung Oktober", "Hallo Alex\n\nDeine Spesenabrechnung für Oktober ist noch nicht eingereicht. Bitte bis Freitag die Belege hochladen.\n\nAnna", d(7))
    add("mwst-1", thomas, "MWST-Abrechnung Q3 – Rückfrage", "Sehr geehrter Herr Frei\n\nZur Mehrwertsteuer-Abrechnung des dritten Quartals haben wir eine Rückfrage betreffend die Vorsteuer auf den Hardwarekäufen. Können Sie uns die Belege zustellen?\n\nThomas Brunner", d(28))

    // Offers / quotes.
    add("off-1", beat, "Offerte 2026-117: Firewall-Erneuerung", "Guten Tag Herr Frei\n\nGerne unterbreiten wir Ihnen unsere Offerte für die Erneuerung des Firewall-Clusters (2x FortiGate 200F) inkl. Installation und Konfiguration. Die Offerte ist 30 Tage gültig.\n\nBeat Zürcher, Netzwerk AG", lastWeekWed, att: ["Offerte_2026-117.pdf"])
    add("off-2", sophie, "Offre : migration Exchange Online", "Bonjour Monsieur Frei,\n\nSuite à notre entretien, voici notre offre pour la migration de vos boîtes aux lettres vers Exchange Online, y compris la formation des utilisateurs.\n\nSophie Dubois", twoWeeksWed)
    add("off-3", beat, "Offerte 2026-098: Switches Etage 3", "Guten Tag Herr Frei\n\nAnbei unsere Offerte für den Ersatz der Switches im 3. Stock (4x 48 Port PoE).\n\nBeat Zürcher", d(45), att: ["Offerte_2026-098.pdf"])
    add("off-4", james, "Quote for additional licences", "Hi Alex,\n\nas requested here is our quote for 25 additional licences of the planning suite, including the first year of support. Prices are valid until the end of the month.\n\nCheers,\nJames", lastWeekThu)
    add("off-5", marco, "Offerta manutenzione stampanti", "Buongiorno,\n\ncome richiesto le inviamo l'offerta per la manutenzione annuale delle stampanti nella sede di Lugano.\n\nMarco Rossi", d(60))

    // Contracts.
    add("con-2", james, "Signed service agreement", "Hi Alex,\n\nattached is the countersigned service agreement for the support of your planning environment. Term starts on the first of next month.\n\nJames Carter, Northwind", d(26), att: ["Northwind_Service_Agreement_signed.pdf"])
    add("con-3", nina, "Mietvertrag Bahnhofstraße 12 – Änderung Nebenkosten", "Sehr geehrter Herr Frei\n\nAufgrund der gestiegenen Energiepreise passen wir die Nebenkosten-Akontozahlung ab Januar an. Den Nachtrag zum Mietvertrag finden Sie in der Beilage.\n\nNina Graf, Grünwald Immobilien", d(33), att: ["Nachtrag_Mietvertrag.pdf"])
    add("imm-2", nina, "Nebenkostenabrechnung 2025 Bahnhofstrasse 12", "Sehr geehrter Herr Frei\n\nIn der Beilage erhalten Sie die Nebenkostenabrechnung 2025 für die Büroräume an der Bahnhofstrasse 12. Das Guthaben wird mit der nächsten Miete verrechnet.\n\nNina Graf", d(50), att: ["NK_2025.pdf"])

    // Project Phoenix vs. Hotel Phoenix.
    add("phx-1", laura, "Projekt Phoenix: Kick-off am Montag", "Hallo zusammen\n\nDas Projekt Phoenix startet am Montag mit dem Kick-off um 9 Uhr im Sitzungszimmer Rigi. Ziel: neues Kundenportal bis Juni.\n\nLaura", d(19))
    add("phx-2", laura, "Protokoll Kick-off", "Hallo zusammen\n\nIm Anhang das Protokoll vom Kick-off zum Projekt Phoenix. Nächste Schritte: Anforderungen sammeln, Lieferanten anfragen.\n\nLaura", d(17), att: ["Protokoll_Kickoff.docx"])
    add("phx-neg", hotel, "Ihre Buchung im Seminarhotel Phoenix", "Guten Tag\n\nVielen Dank für Ihre Buchung. Wir freuen uns, Sie am Projekt-Workshop im Seminarhotel Phoenix begrüssen zu dürfen.", d(40))

    // Board, vacation, security, budget, hiring, FR/IT threads.
    add("vr-1", laura, "VR-Sitzung 12. Dezember: Traktanden", "Hallo Alex\n\nHier die Traktandenliste für die VR-Sitzung vom 12. Dezember. Bitte deinen IT-Bericht bis am 5. Dezember liefern.\n\nLaura", d(3))
    add("vr-2", annaS, "Unterlagen Verwaltungsratssitzung Q4", "Hallo zusammen\n\nIm Anhang die Unterlagen für die Verwaltungsratssitzung: Quartalszahlen, Budget, Risikobericht.\n\nAnna", d(1), att: ["VR_Q4_Unterlagen.pdf"])
    add("fer-1", laura, "Ferienabwesenheit 3.–14. Dezember", "Hallo zusammen\n\nich bin vom 3. bis 14. Dezember in den Ferien. Stellvertretung: Reto. In dringenden Fällen per SMS.\n\nLaura", d(8))
    add("fer-2", laura, "Automatische Antwort: Abwesend", "Ich bin bis am 2. November abwesend und habe keinen Zugriff auf meine E-Mails. Bitte wende dich an Reto Huber.", d(24))
    add("sec-1", itsec, "Warnung: Phishing-Mails im Namen der Post", "Achtung: Zurzeit sind gefälschte E-Mails im Namen der Post im Umlauf, die zur Eingabe von Kreditkartendaten auffordern. Bitte keine Links anklicken und verdächtige Mails melden.", d(9))
    add("sec-2", reto, "Sicherheitsvorfall: kompromittiertes Konto gesperrt", "Hallo Alex\n\nHeute Nacht wurde ein Benutzerkonto in der Buchhaltung kompromittiert und für den Versand von Spam missbraucht. Ich habe das Konto gesperrt und das Passwort zurückgesetzt. MFA ist jetzt erzwungen.\n\nReto", d(35))
    add("bud-1", annaS, "Budget 2027 IT – Entwurf", "Hallo Alex\n\nAnbei der Entwurf fürs IT-Budget 2027. Bitte die Positionen Hardware und Lizenzen bis nächste Woche prüfen.\n\nAnna", d(13), att: ["Budget_2027_IT.xlsx"], conv: "c-bud")
    add("bud-2", me, "Re: Budget 2027 IT – Entwurf", "Hallo Anna, bei den Lizenzen fehlen die 25 zusätzlichen Planungslizenzen von Northwind. Sonst passt es.\n\nAlex", d(12), to: [annaS], conv: "c-bud")
    add("hr-1", lukas, "Bewerbung als System Engineer", "Sehr geehrte Damen und Herren\n\nMit grossem Interesse habe ich Ihr Stelleninserat als System Engineer gelesen und sende Ihnen meine Bewerbungsunterlagen.\n\nFreundliche Grüsse\nLukas Weber", d(21), att: ["Lebenslauf_Lukas_Weber.pdf", "Zeugnisse.pdf"])
    add("hr-2", laura, "Interviewtermine System Engineer", "Hallo Alex\n\nFür die Stelle System Engineer habe ich drei Kandidaten zu Interviews eingeladen: Dienstag 9 Uhr, 11 Uhr und Donnerstag 14 Uhr. Passt dir das?\n\nLaura", d(18))
    add("lum-2", sophie, "Planification de la migration Exchange", "Bonjour Alex,\n\nvoici le planning proposé pour la migration Exchange: phase pilote la semaine 48, puis migration des boîtes aux lettres par département.\n\nSophie", d(12))
    add("tic-2", marco, "Riunione tecnica: problemi di rete a Lugano", "Ciao Alex,\n\nproponiamo una riunione tecnica giovedì per discutere i problemi di rete nella sede di Lugano: perdita di pacchetti sul collegamento VPN.\n\nMarco", d(7))

    // Protected rows (unknown label → fail-closed: no subject / preview in the index, no vector).
    add("conf-1", legal, "Rechnung Fabrikam Vergleich", "Vertraulich: Vergleichsvorschlag zur strittigen Rechnung von Fabrikam, Serverumzug und Audit-Feststellungen.", d(6), label: "aaaaaaaa-0000-0000-0000-unknownlabel")
    add("conf-2", legal, "Offerte Firewall Vertrag", "Vertraulich: Rechtsprüfung Offerte und Vertrag.", d(9), label: "aaaaaaaa-0000-0000-0000-unknownlabel")
    c.protectedIds = ["conf-1", "conf-2"]

    // Filler: newsletters, notifications, tickets, other projects, small talk (some hard negatives on purpose).
    var rnd: UInt64 = 0x5EA2C4
    func r(_ k: Int) -> Int { rnd = rnd &* 6364136223846793005 &+ 1442695040888963407; return Int((rnd >> 33) % UInt64(k)) }
    let nzzTopics = ["Bundesrat beschliesst neue Energiestrategie", "SNB belässt den Leitzins", "Zürcher Wohnungsmarkt angespannt", "Wahlen in Deutschland", "Swiss Market Index im Plus", "Klimakonferenz endet ohne Einigung", "Neue S-Bahn-Linie im Glattal", "Inflation sinkt auf 0,9 Prozent"]
    let products = ["Kopfhörer", "Notebooks", "Kaffeemaschinen", "Smartphones", "Monitore", "Velozubehör", "Spielkonsolen"]
    let tickets = ["Drucker im 2. OG druckt nicht", "VPN verbindet nicht", "Laptop startet langsam", "Teams-Kamera schwarz", "Passwort abgelaufen", "Outlook-Signatur fehlt", "Bildschirm flackert", "Zugriff auf Laufwerk P: verweigert"]
    let colleagues = [laura, reto, annaS, p("Martin Frey", "martin.frey@niivo.example"), p("Claudia Steiner", "claudia.steiner@niivo.example")]
    let customers = [james, sarah, p("Daniel Roth", "daniel.roth@kunde-ag.example"), p("Isabelle Favre", "isabelle.favre@romandie-sa.example")]
    let smallTalk = [("Mittagessen Freitag?", "Wer kommt am Freitag mit zum Mittagessen ins Bistro? Ich reserviere für 12 Uhr."),
                     ("Kaffeemaschine kaputt", "Die Kaffeemaschine im 3. Stock ist wieder kaputt, der Service ist bestellt."),
                     ("Geburtstagsapéro", "Am Donnerstag um 16 Uhr gibt es einen kleinen Apéro, ich habe Geburtstag."),
                     ("Parkplätze Tiefgarage", "Ab nächstem Monat werden die Parkplätze in der Tiefgarage neu vergeben."),
                     ("Weekly Sync", "Agenda: Status Projekte, Tickets, Ferienplanung. Bitte Updates im Teams-Kanal posten.")]
    let atlas = ["Statusbericht KW", "Revision 3 des Pflichtenhefts", "Testprotokoll Sprint", "Abnahme Termin", "Offerte an Kunde in Arbeit"]
    for i in 0..<300 {
        let k = r(10), day = Double(r(180))
        switch k {
        case 0:
            let t = nzzTopics[r(nzzTopics.count)]
            add("n\(i)", nzz, "Daily Briefing: \(t)", "Guten Morgen. \(t). Ausserdem: das Wetter, die Börse und was heute wichtig ist. Jetzt lesen.", d(day))
        case 1:
            let pr = products[r(products.count)]
            add("n\(i)", digitec, "Wochenangebote: \(pr) bis 40% günstiger", "Nur diese Woche: \(pr) und viele weitere Tagesangebote. Gratis Lieferung ab CHF 50.", d(day))
        case 2:
            let ch = ["Allgemein", "IT-Betrieb", "Projekt Atlas", "Verkauf"][r(4)]
            add("n\(i)", teams, "Du wurdest in \(ch) erwähnt", "\(colleagues[r(colleagues.count)].name) hat dich in einer Nachricht im Kanal \(ch) erwähnt.", d(day))
        case 3:
            let t = tickets[r(tickets.count)]
            add("n\(i)", colleagues[r(colleagues.count)], "Ticket #\(4_000 + i): \(t)", "Hallo IT\n\n\(t). Kannst du dir das anschauen? Danke!", d(day))
        case 4:
            let a = atlas[r(atlas.count)]
            add("n\(i)", colleagues[r(colleagues.count)], "Projekt Atlas: \(a) \(r(52) + 1)", "Hallo zusammen\n\nAnbei der aktuelle Stand zum Projekt Atlas: \(a). Offene Punkte werden im nächsten Meeting besprochen.", d(day))
        case 5:
            let cu = customers[r(customers.count)]
            let issue = ["login issue on the portal", "slow report generation", "question about the API limits", "export to Excel fails"][r(4)]
            add("n\(i)", cu, "Support case \(70_000 + i): \(issue)", "Hello,\n\nwe have a \(issue). Could you please have a look and get back to us? Thanks.", d(day))
        case 6:
            let st = smallTalk[r(smallTalk.count)]
            add("n\(i)", colleagues[r(colleagues.count)], st.0, st.1, d(day), to: [me] + colleagues.prefix(3))
        case 7:
            add("n\(i)", me, "Re: Ticket #\(4_000 + r(300))", "Erledigt, bitte nochmals testen. Gruss Alex", d(day), to: [colleagues[r(colleagues.count)]])
        case 8:
            let who = [anna, peter, beat, nina, mike][r(5)]
            let msg = ["Kurze Rückfrage zu Ihrem letzten Schreiben", "Termin nächste Woche", "Neue Kontaktdaten", "Betriebsferien über Weihnachten"][r(4)]
            add("n\(i)", who, msg, "Guten Tag Herr Frei\n\n\(msg). Bitte melden Sie sich bei Gelegenheit.\n\nFreundliche Grüsse\n\(who.name)", d(day))
        default:
            let s = ["Einladung: Webinar Cloud Security", "Your Microsoft 365 weekly digest", "Rappel: formation sécurité", "Promemoria: scadenza certificato SSL", "Swisscom: Ihre Rechnung ist online"][r(5)]
            add("n\(i)", p("Info", "info@vendor\(r(20)).ch"), s, "\(s). Weitere Informationen finden Sie online.", d(day))
        }
    }

    let fab = ["inv-fab-1": 2, "inv-fab-2": 2, "inv-fab-3": 2]
    let srv = ["srv-1": 2, "srv-3": 2, "srv-4": 2, "srv-5": 2, "srv-2": 1]
    let pdfContracts = ["fab-contract": 2, "con-2": 2, "con-3": 2, "fab-contract-q": 1]
    func q(_ t: String, _ cat: BenchQuery.Category, _ rel: [String: Int], holdout: Bool = false) {
        c.queries.append(BenchQuery(text: t, category: cat, holdout: holdout, qrels: rel))
    }
    q("Rechnung Fabrikam", .keyword, fab)
    q("invoice from Fabrikam", .crossLanguage, fab)
    q("invoice Lumen", .crossLanguage, ["inv-lumen": 2])
    q("Rechnung Adatum", .crossLanguage, ["inv-adatum": 2])
    q("the thing about the server move", .paraphrase, srv)
    q("Rechenzentrum Umzug", .paraphrase, srv)
    q("what did Anna send about the audit", .people, ["aud-1": 2, "aud-2": 2, "aud-3": 1, "aud-4": 1])
    q("Thomas Brunner Revision", .people, ["aud-3": 2, "aud-4": 2, "aud-1": 1, "aud-2": 1, "mwst-1": 1])
    q("last week's offer", .time, ["off-1": 2, "off-4": 2])
    q("Offerte Firewall", .keyword, ["off-1": 2, "off-3": 1])
    q("the PDF contract", .attachment, pdfContracts)
    q("Vertrag PDF", .attachment, pdfContracts)
    q("\"Projekt Phoenix\"", .phrase, ["phx-1": 2, "phx-2": 2])
    q("Rechnug Fabrikam", .typo, fab)
    q("Serverumzg", .typo, ["srv-1": 2, "srv-3": 2, "srv-2": 1, "srv-5": 1])
    q("Bahnhofstrasse Nebenkosten", .umlaut, ["con-3": 2, "imm-2": 2])
    q("Aenderung Mietvertrag", .umlaut, ["con-3": 2])
    q("board meeting agenda", .abbreviation, ["vr-1": 2, "vr-2": 1])
    q("VAT return question", .abbreviation, ["mwst-1": 2])
    q("Laura vacation", .people, ["fer-1": 2, "fer-2": 1])
    q("phishing warning", .crossLanguage, ["sec-1": 2])
    q("budget 2027", .keyword, ["bud-1": 2, "bud-2": 2])
    q("job application system engineer", .crossLanguage, ["hr-1": 2, "hr-2": 1])
    q("delayed delivery from Fabrikam", .paraphrase, ["fab-delay": 2])
    q("Exchange migration plan", .crossLanguage, ["lum-2": 2, "off-2": 1])
    q("Peter Müller", .people, ["fab-delay": 2, "fab-contract": 2, "fab-contract-q": 1])
    q("Mueller Wartungsvertrag", .umlaut, ["fab-contract": 2, "fab-contract-q": 2])
    q("Kündigungsfrist Wartungsvertrag", .body, ["fab-contract": 2])
    q("Glattbrugg", .keyword, ["srv-1": 2, "srv-4": 2, "srv-2": 1])
    q("Zahlungserinn", .prefix, ["inv-fab-2": 2])
    q("Verwaltungsrat Unterlagen gestern", .time, ["vr-2": 2])
    q("fattura hosting", .keyword, ["inv-ticino": 2])
    q("network problems Lugano", .crossLanguage, ["tic-2": 2])
    q("mail from Sophie", .people, ["inv-lumen": 2, "off-2": 2, "lum-2": 2])
    q("Cutover", .keyword, ["srv-3": 2, "srv-4": 2])
    // Held out (not consulted while tuning).
    q("invoice Ticinonet", .crossLanguage, ["inv-ticino": 2], holdout: true)
    q("rack relocation datacenter", .paraphrase, srv, holdout: true)
    q("what did Reto say about the migration", .people, ["srv-1": 2, "srv-3": 2, "srv-5": 2, "srv-4": 1, "srv-2": 1], holdout: true)
    q("firewall offer from last week", .time, ["off-1": 2], holdout: true)
    q("Lebenslauf PDF", .attachment, ["hr-1": 2], holdout: true)
    q("Wartungsvertarg", .typo, ["fab-contract": 2, "fab-contract-q": 2], holdout: true)
    q("Zuercher Offerte", .umlaut, ["off-1": 2, "off-3": 2], holdout: true)
    q("MWST", .abbreviation, ["mwst-1": 2], holdout: true)
    q("holiday absence December", .crossLanguage, ["fer-1": 2, "fer-2": 1], holdout: true)
    q("Anna Schmid expenses", .people, ["annaS-spesen": 2], holdout: true)
    q("\"Revision 2026\"", .phrase, ["aud-1": 2, "aud-3": 2], holdout: true)
    q("compromised account blocked", .paraphrase, ["sec-2": 2], holdout: true)
    q("quote licences", .crossLanguage, ["off-4": 2], holdout: true)
    q("Nebenkostenabrechnung", .keyword, ["imm-2": 2], holdout: true)
    q("audit open points", .crossLanguage, ["aud-2": 2, "aud-1": 1], holdout: true)
    return c
}
