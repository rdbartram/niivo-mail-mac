import Foundation
import MailCore

// Accessibility / layout / localisation: view-preference persistence (reading pane, density, preview lines, zoom,
// swipe + strip actions, language), the pane focus cycle, the bundled String Catalog, mailbox regional formats.

@MainActor
func runA11yTests() async {
    a11yPrefsTests()
    a11yPaneCycleTests()
    a11yCatalogTests()
    await a11yRegionalTests()
}

@MainActor
private func a11yPrefsTests() {
    section("A11y: view preferences persistence")
    let suite = "a11y-selftest-\(UUID().uuidString)"
    guard let d = UserDefaults(suiteName: suite) else { check(false, "UserDefaults suite"); return }
    defer { d.removePersistentDomain(forName: suite) }

    let def = MailViewPreferences.load(d)
    check(def.pane == .right && def.density == .standard && def.previewLines == 2 && def.readerZoom == 1.0,
          "defaults: pane right, standard density, 2 preview lines, 100 % zoom")
    check(def.swipeLeft == .archive && def.swipeRight == .toggleRead && def.stripActions == RowQuickAction.allCases,
          "defaults: swipe left archive, right read/unread, every strip button")

    // Old builds wrote only the swipe keys: still honoured.
    d.set("delete", forKey: "MailSwipeLeft")
    check(MailViewPreferences.load(d).swipeLeft == .delete, "legacy MailSwipeLeft key read")

    var p = MailViewPreferences()
    p.pane = .bottom; p.density = .compact; p.previewLines = 0; p.readerZoom = 1.25
    p.swipeLeft = .snooze; p.swipeRight = .flag; p.stripActions = [.archive, .delete]; p.language = .de
    p.save(d)
    let back = MailViewPreferences.load(d)
    check(back == p, "pane / density / preview / zoom / swipe / strip / language round-trip")
    check(d.string(forKey: "MailSwipeRight") == "flag", "swipe right stored under the existing MailSwipeRight key")

    p.pane = .off; p.save(d)
    check(MailViewPreferences.load(d).pane == .off, "reading pane off persists")

    d.set(9, forKey: MailViewPreferences.Key.previewLines)
    d.set(42.0, forKey: MailViewPreferences.Key.readerZoom)
    d.set(["flag", "bogus", "flag", "archive"], forKey: MailViewPreferences.Key.strip)
    d.set("sideways", forKey: MailViewPreferences.Key.pane)
    let clamped = MailViewPreferences.load(d)
    check(clamped.previewLines == 3 && clamped.readerZoom == 3.0, "out-of-range preview lines / zoom clamped")
    check(clamped.stripActions == [.flag, .archive], "unknown + duplicate strip actions dropped")
    check(clamped.pane == .right, "unknown pane value → default")

    check(MailViewPreferences.stepZoom(1.0, 1) == 1.1 && MailViewPreferences.stepZoom(1.0, -1) == 0.9
          && MailViewPreferences.stepZoom(3.0, 1) == 3.0 && MailViewPreferences.stepZoom(0.5, -1) == 0.5,
          "zoom steps up / down, clamped at 50 % and 300 %")
}

@MainActor
private func a11yPaneCycleTests() {
    section("A11y: pane focus cycle")
    let all: Set<MailPane> = [.sidebar, .list, .reader, .composer]
    check(MailPane.cycle(from: .sidebar, forward: true, present: all) == .list, "sidebar → list")
    check(MailPane.cycle(from: .list, forward: true, present: all) == .reader, "list → reader")
    check(MailPane.cycle(from: .reader, forward: true, present: all) == .composer, "reader → composer")
    check(MailPane.cycle(from: .composer, forward: true, present: all) == .sidebar, "composer → wraps to sidebar")
    check(MailPane.cycle(from: .sidebar, forward: false, present: all) == .composer, "⇧Tab from sidebar wraps back")
    let noPane: Set<MailPane> = [.sidebar, .list]
    check(MailPane.cycle(from: .list, forward: true, present: noPane) == .sidebar, "reading pane off: list ↔ sidebar only")
    check(MailPane.cycle(from: .reader, forward: true, present: [.list]) == .list, "unknown current → first present pane")
    check(MailPane.cycle(from: nil, forward: false, present: all) == .composer, "no current, backwards → last pane")
}

/// The real catalog from the source tree (the app ships the same file in its resource bundle).
private func catalogURL() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("CompliantCalendar/Resources/Localizable.xcstrings")
}

@MainActor
private func a11yCatalogTests() {
    section("A11y: String Catalog (DE / FR / IT)")
    let cat: StringCatalog
    do { cat = try StringCatalog(contentsOf: catalogURL()) } catch { check(false, "catalog loads: \(error)"); return }
    check(cat.sourceLanguage == "en" && cat.table.count >= 100, "catalog loads (\(cat.table.count) keys, source en)")
    let sample = ["Archive", "Delete", "Reply", "Forward", "New message", "Search mail", "Settings", "Mark as Read",
                  "Favourites", "No message selected.", "Subject", "Send", "Layout & Accessibility", "%lld selected"]
    for k in sample {
        check(["de", "fr", "it"].allSatisfy { cat.has(k, language: $0) }, "\"\(k)\" has DE, FR and IT")
    }
    let sharpS = cat.table.filter { $0.value["de"]?.contains("ß") == true }.map(\.key)
    check(sharpS.isEmpty, "Swiss German orthography: no ß in DE values \(sharpS.prefix(3))")
    func placeholders(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "%(lld|@|d)")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }.sorted()
    }
    let bad = cat.table.filter { k, v in v.values.contains { placeholders($0) != placeholders(k) } }.map(\.key)
    check(bad.isEmpty, "format placeholders match the source in every language \(bad.prefix(3))")
    check(cat.string("Archive", language: "de") == "Archivieren", "lookup DE")
    check(cat.string("No such key", language: "fr") == "No such key", "missing key falls back to the English source")
    check(StringCatalog.resolve(.system, preferred: ["de-CH", "en-GB"]) == "de"
          && StringCatalog.resolve(.system, preferred: ["ja-JP", "fr-CH"]) == "fr"
          && StringCatalog.resolve(.system, preferred: ["ja-JP"]) == "en"
          && StringCatalog.resolve(.it, preferred: ["de-CH"]) == "it", "language: system preference (first supported) or explicit choice")
}

@MainActor
private func a11yRegionalTests() async {
    section("A11y: mailbox regional date / time formats")
    let utc = TimeZone(identifier: "UTC")!
    let d = ISO8601DateFormatter().date(from: "2026-11-16T08:05:00Z")!
    let ch = MailRegionalFormat(MailboxRegionalSettings(dateFormat: "dd.MM.yyyy", timeFormat: "HH:mm", locale: "de-CH"), timeZone: utc)
    check(ch.shortDate(d) == "16.11.2026" && ch.shortTime(d) == "08:05", "de-CH dd.MM.yyyy / HH:mm → 16.11.2026 08:05 (\(ch.dateTime(d)))")
    let us = MailRegionalFormat(MailboxRegionalSettings(dateFormat: "M/d/yyyy", timeFormat: "h:mm tt", locale: "en-US"), timeZone: utc)
    check(us.shortDate(d) == "11/16/2026" && us.shortTime(d) == "8:05 AM", ".NET tt → AM/PM (\(us.dateTime(d)))")
    check(MailRegionalFormat.icuPattern("dddd, MMMM d, yyyy") == "EEEE, MMMM d, yyyy", ".NET dddd → ICU EEEE")
    check(MailRegionalFormat.icuPattern("d") == nil, "single-letter standard specifier → system format")
    check(ch.listTime(d, now: d.addingTimeInterval(3600)) == "08:05", "list column: same day → mailbox time format")
    let fr = MailRegionalFormat(MailboxRegionalSettings(locale: "fr-CH"), timeZone: utc)
    let old = fr.listTime(d, now: d.addingTimeInterval(86400 * 30))
    check(old.contains("nov"), "list column: older → day + month in the mailbox locale (\(old))")
    let none = MailRegionalFormat(nil, fallbackLocale: Locale(identifier: "en_GB"), timeZone: utc)
    check(!none.shortDate(d).isEmpty && none.datePattern == nil, "no regional settings → system formats")
    do {
        let r = try await FixtureMailService().regionalSettings(mailbox: "me")
        check(r.dateFormat == "dd.MM.yyyy" && r.timeFormat == "HH:mm" && r.locale == "de-CH", "fixture mailbox carries date/time format + locale")
        let json = try JSONEncoder().encode(MailboxRegionalSettings(timeZone: "UTC"))
        let old = try JSONDecoder().decode(MailboxRegionalSettings.self, from: Data(#"{"timeZone":"UTC"}"#.utf8))
        check(!json.isEmpty && old.dateFormat == nil, "older cached settings without the new fields still decode")
    } catch { check(false, "regional fixture threw \(error)") }
}
