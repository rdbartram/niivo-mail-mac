import Foundation
import CalendarCore
import MailCore

// UI-free mail logic. Kept out of the views (and out of MailModel's side effects) so it can be reasoned about and,
// later, tested: CoreSelfTest can't import an executable target, so these are compile-checked only for now.

// MARK: - Keyboard triage

/// Everything the Mail view can do from the keyboard (and the command palette / Mail menu).
enum MailCommand: String, CaseIterable, Identifiable, Sendable {
    case next, previous, open, archive, delete, reply, replyAll, forward, compose, flag, toggleRead
    case snooze, categorize, palette, search, undo, cheatSheet, loadImages, settings, sync
    case toggleConversations
    var id: String { rawValue }

    var title: String {
        switch self {
        case .next: "Next message"
        case .previous: "Previous message"
        case .open: "Open message"
        case .archive: "Archive"
        case .delete: "Delete"
        case .reply: "Reply"
        case .replyAll: "Reply all"
        case .forward: "Forward"
        case .compose: "New message"
        case .flag: "Flag / unflag"
        case .toggleRead: "Mark read / unread"
        case .snooze: "Snooze…"
        case .categorize: "Categorise…"
        case .palette: "Command palette"
        case .search: "Search mail"
        case .undo: "Undo last action"
        case .cheatSheet: "Keyboard shortcuts"
        case .loadImages: "Load remote images (this message)"
        case .settings: "Mail settings…"
        case .sync: "Sync mail now"
        case .toggleConversations: "Group by conversation"
        }
    }

    var symbol: String {
        switch self {
        case .next: "chevron.down"
        case .previous: "chevron.up"
        case .open: "envelope.open"
        case .archive: "archivebox"
        case .delete: "trash"
        case .reply: "arrowshape.turn.up.left"
        case .replyAll: "arrowshape.turn.up.left.2"
        case .forward: "arrowshape.turn.up.right"
        case .compose: "square.and.pencil"
        case .flag: "flag"
        case .toggleRead: "envelope.badge"
        case .snooze: "clock"
        case .categorize: "tag"
        case .palette: "command"
        case .search: "magnifyingglass"
        case .undo: "arrow.uturn.backward"
        case .cheatSheet: "keyboard"
        case .loadImages: "photo"
        case .settings: "gearshape"
        case .sync: "arrow.triangle.2.circlepath"
        case .toggleConversations: "bubble.left.and.bubble.right"
        }
    }

    /// Key hint shown in the cheat sheet, the palette and the Mail menu titles.
    var hint: String {
        switch self {
        case .next: "J"
        case .previous: "K"
        case .open: "↩"
        case .archive: "E"
        case .delete: "# / ⌫"
        case .reply: "R"
        case .replyAll: "A"
        case .forward: "F"
        case .compose: "C"
        case .flag: "S"
        case .toggleRead: "U"
        case .snooze: "H"
        case .categorize: "L"
        case .palette: "⌘K"
        case .search: "/"
        case .undo: "Z"
        case .cheatSheet: "⌘/"
        case .loadImages: "⇧I"
        case .settings: "⌘,"
        case .sync: "⌘R"
        case .toggleConversations: "⇧T"
        }
    }

    /// Commands that act on the selected message.
    var needsSelection: Bool {
        switch self {
        case .open, .archive, .delete, .reply, .replyAll, .forward, .flag, .toggleRead, .snooze, .categorize, .loadImages: true
        default: false
        }
    }
}

/// Bare-key map. Matches on the produced *characters* (not key codes) so layouts that type `#` with ⌥3 or `/` with
/// ⇧7 (Swiss German) still work. Command-modified keys are handled by menu items, not here.
enum MailKeymap {
    enum Key: Equatable, Sendable { case character(String), returnKey, deleteKey, downArrow, upArrow, escape }

    static func command(for key: Key, command: Bool = false, control: Bool = false) -> MailCommand? {
        if command || control { return nil }
        switch key {
        case .returnKey: return .open
        case .deleteKey: return .delete
        case .downArrow: return .next
        case .upArrow: return .previous
        case .escape: return nil
        case .character(let c):
            switch c {
            case "j": return .next
            case "k": return .previous
            case "e": return .archive
            case "#": return .delete
            case "r": return .reply
            case "a": return .replyAll
            case "f": return .forward
            case "c": return .compose
            case "s": return .flag
            case "u": return .toggleRead
            case "h": return .snooze
            case "l": return .categorize
            case "/": return .search
            case "z": return .undo
            case "?": return .cheatSheet
            case "I": return .loadImages
            case "T": return .toggleConversations
            default: return nil
            }
        }
    }

    /// Cheat-sheet layout.
    static let groups: [(title: String, commands: [MailCommand])] = [
        ("Move", [.next, .previous, .open, .search, .palette]),
        ("Triage", [.archive, .delete, .flag, .toggleRead, .snooze, .categorize, .undo]),
        ("Write", [.compose, .reply, .replyAll, .forward]),
        ("View", [.toggleConversations, .loadImages, .sync, .settings, .cheatSheet]),
    ]
}

// MARK: - Paging

enum MailPaging {
    static let pageSize = 50
    /// Start loading the next page when a row this close to the end appears.
    static let prefetchDistance = 10
    /// Split-inbox tabs filter client-side; one trigger may pull at most this many pages looking for rows.
    static let maxPagesPerTrigger = 4

    static func shouldLoadMore(appearedIndex: Int, loadedCount: Int, reachedEnd: Bool, isLoading: Bool) -> Bool {
        guard !reachedEnd, !isLoading else { return false }
        return appearedIndex >= max(0, loadedCount - prefetchDistance)
    }

    /// After a filtered load: keep going while the visible (filtered) list is still short of a screenful.
    static func needsAnotherPage(visibleCount: Int, pagesThisTrigger: Int, lastPageCount: Int) -> Bool {
        lastPageCount >= pageSize && visibleCount < prefetchDistance * 2 && pagesThisTrigger < maxPagesPerTrigger
    }
}

// MARK: - Compose checks

enum RecipientCheck {
    /// Labels at or above this priority get the strong warning (Confidential and up on the fixture scale; same
    /// threshold AIAccessPolicy uses).
    static let strongWarningPriority = 2

    static func domain(of address: String) -> String {
        address.lowercased().split(separator: "@").last.map(String.init) ?? ""
    }

    static func isInternal(_ address: String, internalDomains: Set<String>) -> Bool {
        let d = domain(of: address)
        let internals = Set(internalDomains.map { $0.lowercased() })
        return internals.contains(d) || internals.contains { d.hasSuffix("." + $0) }
    }

    /// Addresses outside the organisation. No internal domains configured → nothing is flagged (we can't tell).
    static func external(_ addresses: [EmailAddress], internalDomains: Set<String>) -> [EmailAddress] {
        guard !internalDomains.isEmpty else { return [] }
        return addresses.filter { !isInternal($0.address, internalDomains: internalDomains) }
    }

    enum Warning: Equatable, Sendable {
        case none
        case external(count: Int, domains: [String])
        /// External recipients on mail labelled Confidential or above.
        case externalSensitive(count: Int, domains: [String], label: String)

        var message: String? {
            switch self {
            case .none: return nil
            case .external(let n, let d):
                return "\(n) recipient\(n == 1 ? " is" : "s are") outside your organisation (\(d.joined(separator: ", ")))."
            case .externalSensitive(let n, let d, let l):
                return "This message is labelled \(l) and \(n) recipient\(n == 1 ? " is" : "s are") outside your organisation (\(d.joined(separator: ", "))). Check they're allowed to receive it."
            }
        }
        var isStrong: Bool { if case .externalSensitive = self { true } else { false } }
    }

    static func warning(recipients: [EmailAddress], internalDomains: Set<String>, label: SensitivityLabel?) -> Warning {
        let ext = external(recipients, internalDomains: internalDomains)
        guard !ext.isEmpty else { return .none }
        let domains = Array(Set(ext.map { domain(of: $0.address) })).sorted()
        if let label, label.priority >= strongWarningPriority {
            return .externalSensitive(count: ext.count, domains: domains, label: label.name)
        }
        return .external(count: ext.count, domains: domains)
    }

    /// Tokenises "Name <a@b>, c@d; e@f" into addresses. Invalid fragments are returned separately.
    static func parse(_ text: String) -> (valid: [EmailAddress], invalid: [String]) {
        var valid: [EmailAddress] = [], invalid: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            if let lt = s.firstIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
                let addr = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
                let name = String(s[..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                if looksLikeAddress(addr) { valid.append(EmailAddress(name: name, address: addr)) } else { invalid.append(s) }
            } else if looksLikeAddress(s) {
                valid.append(EmailAddress(name: "", address: s))
            } else { invalid.append(s) }
        }
        return (valid, invalid)
    }

    static func looksLikeAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !s.contains(" ")
    }
}

enum LabelFloorExplainer {
    /// Explains what `MailLabelFloor.enforce` did to the user's choice. nil when nothing changed.
    static func message(requested: String?, enforced: String?, labels: [SensitivityLabel]) -> String? {
        let r = requested?.lowercased(), e = enforced?.lowercased()
        guard r != e, let e else { return nil }
        let tree = LabelTree(labels)
        let floorName = tree.path(e) ?? "the original message's label"
        if let r, tree.isHeader(r), let req = tree.path(r) {
            return "“\(req)” is a group, not a label. Choose one of its sub-labels; the original's label “\(floorName)” is kept."
        }
        if let r, let req = tree.path(r) {
            return "A reply can't be labelled lower than the message it answers. “\(req)” is below “\(floorName)”, so “\(floorName)” is kept."
        }
        if r == nil { return "Replies keep the original message's label: “\(floorName)”." }
        return "That label isn't in your synced policy, so the original's label “\(floorName)” is kept."
    }

    /// Labels a reply may pick: rank ≥ the original's (all of them for new mail / unlabelled originals).
    /// Ranks are `LabelTree.floorRank` (sub-labels compare on their parent). Group headers are never allowed.
    static func allowed(labels: [SensitivityLabel], floorLabelId: String?) -> [SensitivityLabel] {
        let tree = LabelTree(labels)
        return tree.appliable.filter { tree.meetsFloor($0.id, floor: floorLabelId) }
    }
}

// MARK: - Snooze / send-later presets

enum TimePreset: String, CaseIterable, Identifiable, Sendable {
    case laterToday, tomorrowMorning, nextWeek, inOneHour
    var id: String { rawValue }
    var title: String {
        switch self {
        case .laterToday: "Later today"
        case .tomorrowMorning: "Tomorrow 8:00"
        case .nextWeek: "Next week (Mon 8:00)"
        case .inOneHour: "In 1 hour"
        }
    }

    static let snooze: [TimePreset] = [.laterToday, .tomorrowMorning, .nextWeek]
    static let sendLater: [TimePreset] = [.inOneHour, .tomorrowMorning, .nextWeek]

    /// Later today = +3 h rounded up to the hour, but at least 18:00 if that's still today; after 21:00 → tomorrow 8:00.
    func date(now: Date = .now, calendar cal: Calendar = .current) -> Date {
        func at(_ day: Date, _ h: Int) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: day)! }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        switch self {
        case .inOneHour:
            return now.addingTimeInterval(3600)
        case .laterToday:
            let h = cal.component(.hour, from: now)
            if h >= 21 { return at(tomorrow, 8) }
            let plus3 = cal.date(byAdding: .hour, value: 3, to: now)!
            let rounded = cal.nextDate(after: plus3, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? plus3
            if !cal.isDate(rounded, inSameDayAs: now) { return at(tomorrow, 8) }
            return h < 15 ? rounded : max(rounded, at(now, 18))
        case .tomorrowMorning:
            return at(tomorrow, 8)
        case .nextWeek:
            // Next Monday (strictly after today) at 8:00.
            let next = cal.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0, weekday: 2), matchingPolicy: .nextTime)
            return next.map { cal.isDate($0, inSameDayAs: now) ? cal.date(byAdding: .day, value: 7, to: $0)! : $0 } ?? at(tomorrow, 8)
        }
    }
}

// MARK: - Fuzzy matching (command palette)

enum FuzzyMatch {
    /// Subsequence match with bonuses for word starts and contiguity. nil = no match. Higher is better.
    static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        var qi = 0, score = 0, lastMatch = -2
        for (i, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            var s = 1
            if i == 0 || c[i - 1] == " " || c[i - 1] == "/" || c[i - 1] == "·" { s += 8 }
            if lastMatch == i - 1 { s += 5 }
            score += s
            lastMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - c.count / 10
    }

    static func rank<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return items }
        return items.compactMap { item in score(query, in: text(item)).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }
}

// MARK: - Undo

/// Inverse of a triage action, computed from the header *before* the action ran.
enum TriageUndo {
    static func inverse(of action: MailAction, before m: MailMessage) -> MailAction? {
        switch action {
        case .markRead: return .markRead(m.isRead)
        case .flag: return .flag(m.flag)
        case .categorize: return .categorize(m.categories)
        case .move, .delete, .snooze, .unsnooze: return .move(toFolderId: m.folderId)
        }
    }

    static func describe(_ action: MailAction) -> String {
        switch action {
        case .markRead(let r): r ? "Marked read" : "Marked unread"
        case .flag(let f): f.status == .flagged ? "Flagged" : "Flag cleared"
        case .categorize: "Categories updated"
        case .move: "Moved"
        case .delete: "Deleted"
        case .snooze(let d): "Snoozed until \(d.formatted(date: .abbreviated, time: .shortened))"
        case .unsnooze: "Unsnoozed"
        }
    }
}

// MARK: - Mailbox display

enum MailboxDisplay {
    static func title(_ mailbox: String) -> String {
        if mailbox == "me" { return "My Mailbox" }
        let local = mailbox.split(separator: "@").first.map(String.init) ?? mailbox
        return local.split(separator: ".").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func initials(_ mailbox: String) -> String {
        if mailbox == "me" { return "Me" }
        let parts = title(mailbox).split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined().uppercased()
        return s.count == 1 ? String(title(mailbox).prefix(2)).uppercased() : s
    }

    /// Same palette + stable hash as calendars, so a person keeps "their" colour.
    static func colorHex(_ mailbox: String) -> String {
        let sw = CalendarPalette.swatches
        return sw[Int(CalendarPalette.stableHash(mailbox) % UInt64(sw.count))].hex
    }

    static func folderSymbol(_ f: MailFolder) -> String {
        switch f.wellKnown {
        case .inbox: "tray"
        case .drafts: "doc"
        case .sentitems: "paperplane"
        case .deleteditems: "trash"
        case .archive: "archivebox"
        case .junkemail: "xmark.bin"
        case .outbox: "tray.and.arrow.up"
        case .snoozed: "clock"
        case nil: "folder"
        }
    }

    /// Sidebar order: Inbox, Snoozed, Drafts, Sent, Archive, then custom folders, Junk, Deleted.
    static func sortKey(_ f: MailFolder) -> (Int, String) {
        let rank: Int
        switch f.wellKnown {
        case .inbox: rank = 0
        case .snoozed: rank = 1
        case .drafts: rank = 2
        case .sentitems: rank = 3
        case .archive: rank = 4
        case nil: rank = 5
        case .outbox: rank = 6
        case .junkemail: rank = 7
        case .deleteditems: rank = 8
        }
        return (rank, f.displayName.lowercased())
    }
}

// MARK: - HTML for the reader

enum MailHTML {
    /// Plain-text body → escaped, pre-wrapped HTML.
    static func fromPlainText(_ s: String) -> String {
        let esc = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<pre style=\"white-space:pre-wrap;font:inherit;margin:0\">\(esc)</pre>"
    }

    /// Composer text → minimal HTML (paragraphs + line breaks).
    static func fromComposer(_ s: String) -> String {
        let esc = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let paras = esc.components(separatedBy: "\n\n").map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
        return "<html><body>\(paras.joined())</body></html>"
    }

    /// Wraps sanitised content in a document with readable defaults. `noSelect` disables selection and dragging in CSS
    /// (the only lever with JavaScript off).
    /// `brand`: niivo reader: paper ground, Instrument Sans body (embedded as data: fonts, see `fontFaceCSS`).
    /// The CSP only narrows what the sanitiser + content rule list already enforce: no script, frames, objects or forms,
    /// and fonts from data: URLs only. Images/styles keep their previous reach (the rule list still blocks remote loads).
    /// §17 Dark Mode: the light defaults below are followed by `ReaderAppearance.darkCSS` (inside a
    /// `prefers-color-scheme: dark` screen query, so it tracks the window's appearance and print stays light).
    /// `original`: "Show original colours", no dark rules.
    /// `dark`: the app's appearance (SwiftUI `colorScheme`). Bodies that hard-code colours are remapped for it.
    static func document(_ body: String, noSelect: Bool, original: Bool = false, dark: Bool = false, brand: Bool = false) -> String {
        let mode = ReaderAppearance.mode(for: body, original: original)
        let body = ReaderAppearance.displayBody(body, mode: mode, dark: dark)
        let fg = brand ? "#111111" : "#1D1D1F"
        let link = brand ? "#006E88" : "#0A66D8"
        let bg = brand ? "#F2F1EF" : "#FFFFFF"
        let font = brand ? "15px/1.55 'Instrument Sans',-apple-system,system-ui,sans-serif" : "14px -apple-system,system-ui,sans-serif"
        let quote = brand ? "border-left:2px solid #111111;margin-left:0;padding-left:12px;color:#6E6E6A"
                          : "border-left:3px solid #8884;margin-left:0;padding-left:10px;color:#888"
        let sel = noSelect ? "*{-webkit-user-select:none!important;user-select:none!important;-webkit-user-drag:none!important}" : ""
        let csp = "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; form-action 'none'; base-uri 'none'; font-src data:; img-src * data: cid: blob:; style-src 'unsafe-inline' *; media-src *"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>
        \(brand ? fontFaceCSS : "")
        html,body{margin:0;padding:\(brand ? "16px 24px" : "12px 18px");background:\(bg);color:\(fg);font:\(font);\(brand ? "line-height:1.55;" : "line-height:1.45;")word-wrap:break-word}
        a{color:\(link)} img{max-width:100%;height:auto} table{max-width:100%} blockquote{\(quote)}
        \(brand ? "pre,code{font-family:'JetBrains Mono',ui-monospace,monospace;font-size:13px}" : "")
        \(sel)
        \(ReaderAppearance.darkCSS(mode, brand: brand, dark: dark))
        </style></head><body>\(body)</body></html>
        """
    }

    /// @font-face rules for the bundled brand faces as base64 data: URLs (computed once). Empty if the fonts are missing.
    static let fontFaceCSS: String = {
        guard let dir = NiivoFonts.fontsDirectory else { return "" }
        func face(_ family: String, _ file: String, _ weights: String) -> String {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return "" }
            return "@font-face{font-family:'\(family)';font-style:normal;font-weight:\(weights);src:url(data:font/woff2;base64,\(d.base64EncodedString())) format('woff2');}"
        }
        return face("Instrument Sans", "instrument-sans-latin.woff2", "400 700") + face("JetBrains Mono", "jetbrains-mono-latin.woff2", "100 800")
    }()
}
