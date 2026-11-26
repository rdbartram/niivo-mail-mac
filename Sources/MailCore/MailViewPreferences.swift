import Foundation

// Layout / accessibility preferences for the mail window (reading pane, density, preview lines, reader zoom,
// configurable swipe + hover-strip actions, UI language) and the pane focus cycle. UI-free so CoreSelfTest can
// check persistence; the app wraps it in an @Observable (A11yPrefs, Accessibility.swift).

/// Direct actions on a message-list row (hover strip, swipe, VoiceOver row actions). Symbols / labels live in the app.
public enum RowQuickAction: String, CaseIterable, Sendable, Codable {
    case toggleRead, flag, snooze, archive, delete
}

public enum ReadingPanePosition: String, CaseIterable, Sendable, Codable {
    case right, bottom, off
}

public enum ListDensity: String, CaseIterable, Sendable, Codable {
    case compact, standard, roomy
    /// Vertical row padding (niivo skin; the classic skin uses 2 pt less).
    public var rowPadding: Double {
        switch self { case .compact: 5; case .standard: 10; case .roomy: 14 }
    }
}

/// UI language. `.system` follows the macOS preferred languages (first of de / fr / it / en, else English).
public enum UILanguage: String, CaseIterable, Sendable, Codable {
    case system, en, de, fr, it
}

public struct MailViewPreferences: Equatable, Sendable {
    public var pane: ReadingPanePosition = .right
    public var density: ListDensity = .standard
    /// 0 = no preview line, up to 3.
    public var previewLines: Int = 2
    /// WKWebView pageZoom for the reader, 0.5 ... 3.0.
    public var readerZoom: Double = 1.0
    public var swipeLeft: RowQuickAction = .archive
    public var swipeRight: RowQuickAction = .toggleRead
    /// Hover-strip buttons, in display order.
    public var stripActions: [RowQuickAction] = RowQuickAction.allCases
    public var language: UILanguage = .system
    /// "Clean list" (View menu): rows show only sender, subject + snippet, date and the label chip.
    public var cleanList: Bool = false
    /// View ▸ Show Sensitivity Labels in List: full label chips on rows. Off = a glyph only for labels that matter
    /// (ListRowLayout.labelMark, docs/COMPOSE-LAYOUT.md).
    public var showLabelChips: Bool = false

    public init() {}

    // Keys. `MailSwipeLeft` / `MailSwipeRight` predate this struct (MailRowActions.swift) and are kept.
    public enum Key {
        public static let pane = "mail.readingPane"
        public static let density = "mail.listDensity"
        public static let previewLines = "mail.previewLines"
        public static let readerZoom = "mail.readerZoom"
        public static let swipeLeft = "MailSwipeLeft"
        public static let swipeRight = "MailSwipeRight"
        public static let strip = "mail.stripActions"
        public static let language = "ui.language"
        public static let cleanList = "mail.cleanList"
        public static let labelChips = "mail.listLabelChips"
    }

    public static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    public static func clampZoom(_ z: Double) -> Double { min(3.0, max(0.5, z.isFinite ? z : 1.0)) }
    public static func clampPreview(_ n: Int) -> Int { min(3, max(0, n)) }

    /// Next zoom step up (`+1`) or down (`-1`) from `z`.
    public static func stepZoom(_ z: Double, _ dir: Int) -> Double {
        if dir > 0 { return zoomSteps.first { $0 > z + 0.001 } ?? zoomSteps.last! }
        return zoomSteps.last { $0 < z - 0.001 } ?? zoomSteps.first!
    }

    public static func load(_ d: UserDefaults = .standard) -> MailViewPreferences {
        var p = MailViewPreferences()
        if let v = d.string(forKey: Key.pane).flatMap(ReadingPanePosition.init(rawValue:)) { p.pane = v }
        if let v = d.string(forKey: Key.density).flatMap(ListDensity.init(rawValue:)) { p.density = v }
        if d.object(forKey: Key.previewLines) != nil { p.previewLines = clampPreview(d.integer(forKey: Key.previewLines)) }
        if d.object(forKey: Key.readerZoom) != nil { p.readerZoom = clampZoom(d.double(forKey: Key.readerZoom)) }
        if let v = d.string(forKey: Key.swipeLeft).flatMap(RowQuickAction.init(rawValue:)) { p.swipeLeft = v }
        if let v = d.string(forKey: Key.swipeRight).flatMap(RowQuickAction.init(rawValue:)) { p.swipeRight = v }
        if let raw = d.stringArray(forKey: Key.strip) {
            var seen = Set<RowQuickAction>()
            p.stripActions = raw.compactMap(RowQuickAction.init(rawValue:)).filter { seen.insert($0).inserted }
        }
        if let v = d.string(forKey: Key.language).flatMap(UILanguage.init(rawValue:)) { p.language = v }
        p.cleanList = d.bool(forKey: Key.cleanList)
        p.showLabelChips = d.bool(forKey: Key.labelChips)
        return p
    }

    public func save(_ d: UserDefaults = .standard) {
        d.set(pane.rawValue, forKey: Key.pane)
        d.set(density.rawValue, forKey: Key.density)
        d.set(Self.clampPreview(previewLines), forKey: Key.previewLines)
        d.set(Self.clampZoom(readerZoom), forKey: Key.readerZoom)
        d.set(swipeLeft.rawValue, forKey: Key.swipeLeft)
        d.set(swipeRight.rawValue, forKey: Key.swipeRight)
        d.set(stripActions.map(\.rawValue), forKey: Key.strip)
        d.set(language.rawValue, forKey: Key.language)
        d.set(cleanList, forKey: Key.cleanList)
        d.set(showLabelChips, forKey: Key.labelChips)
    }
}

// MARK: - Pane focus cycle

/// The mail window's focusable panes, in Tab order.
public enum MailPane: String, CaseIterable, Sendable {
    case sidebar, list, reader, composer

    /// Next pane (`forward`) or previous one among those present. `present` lists which panes exist right now
    /// (the sidebar can be hidden, the reading pane off, the composer closed). Wraps around.
    public static func cycle(from current: MailPane?, forward: Bool, present: Set<MailPane>) -> MailPane? {
        let order = allCases.filter { present.contains($0) }
        guard !order.isEmpty else { return nil }
        guard let cur = current, let i = order.firstIndex(of: cur) else { return forward ? order.first : order.last }
        let n = order.count
        return order[(i + (forward ? 1 : n - 1)) % n]
    }
}

// MARK: - Message list row layout (Gmail-style, 2026-11-20; docs/LIST-LAYOUT.md)

/// The few badges a row may show, in priority order. The label slot (a glyph by default, the chip when the user turns
/// chips on — `labelMark`) is compliance and always wins its slot.
public enum ListRowBadge: String, Sendable, CaseIterable {
    case label, replyNeeded, waiting, attachment
}

/// Pure layout decisions for a message-list row, so CoreSelfTest can pin them.
public enum ListRowLayout {
    /// At most `limit` badges, by priority: the label mark (when `labelMark` isn't `.none`), then reply-needed /
    /// waiting, then attachment. Clean list: the label mark only.
    public static func badges(label: Bool, triage: ListRowBadge?, attachment: Bool, clean: Bool, limit: Int = 2) -> [ListRowBadge] {
        var out: [ListRowBadge] = label ? [.label] : []
        if clean { return out }
        if let t = triage, t == .replyNeeded || t == .waiting { out.append(t) }
        if attachment { out.append(.attachment) }
        // The label chip is never the one dropped.
        return Array(out.prefix(max(limit, label ? 1 : 0)))
    }

    /// One fixed height per density, so rows never jump when badges come and go (niivo skin; classic −2).
    public static func rowHeight(_ d: ListDensity, twoLine: Bool = false) -> Double {
        switch d {
        case .compact: twoLine ? 46 : 30
        case .standard: twoLine ? 58 : 40
        case .roomy: twoLine ? 66 : 50
        }
    }

    /// With the reading pane on the right the list column is narrow: sender + date on line one, subject + snippet +
    /// badges on line two (Gmail's split view). Pane at the bottom / off: one line across the full width.
    public static func twoLine(_ pane: ReadingPanePosition) -> Bool { pane == .right }

    /// Avatars: off in compact and in the clean list (Gmail compact has none), else as the user set them.
    public static func showsAvatar(_ d: ListDensity, clean: Bool, avatarsOn: Bool) -> Bool {
        avatarsOn && !clean && d != .compact
    }

    /// Secondary indicators (flag, importance, VIP, snoozed, via, mailbox, categories, waiting-to-sync): only on the
    /// selected row, never in the clean list. Hover shows the action strip instead (it covers the date).
    public static func showsSecondary(selected: Bool, clean: Bool) -> Bool { selected && !clean }

    /// Snippet after the subject on the same line ("Subject — preview"); nil when there's nothing to add.
    public static func snippet(_ preview: String?, previewLines: Int) -> String? {
        guard previewLines > 0, let p = preview?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        return p.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
