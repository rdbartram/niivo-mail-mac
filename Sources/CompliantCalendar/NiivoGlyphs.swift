import SwiftUI
import AppKit

// niivo glyph set: stroke-drawn on a 24-unit grid, 1.5-unit line (the kit's accent stroke, niivo-ci-study.md §2),
// square caps, mitred joins, radius 0. Nothing is round (form-lab.html:7074): lenses, clock faces and heads are
// cut-corner polygons. Only `ai` and `syncing` lean (11.03°), because they carry the ıı / the cut. No sparkles,
// no chat bubbles (niivo-ci-study.md §8). Rules: docs/NIIVO-THEME.md §1.4.

enum NGlyphKind: String, CaseIterable, Sendable {
    case archive, reply, replyAll, forward, flag, snooze, delete, compose, search, settings
    case syncIdle, syncing, syncOffline, syncError, lock, encrypted, ai, briefing, calendar, mail
    case person, company, project, alert, sidebar, palette, conversations, pin
    case inbox, drafts, sent, junk, outbox, location, organiser, people, video, copy
    case print, export, forbidden, eye, info, check, close, plus, minus, chevronLeft
    case chevronRight, chevronUp, chevronDown, shield, shieldAlert, key, attachment, globe, recurring, throttled
    case fixtures, rewrite, summarise, checklist, unknown, keyboard, noNetwork, calendarCancel, undo, image
    case away, important, tag, wiped, grip, box, boxChecked

    /// VoiceOver label when the call site gives none.
    var defaultLabel: String {
        switch self {
        case .archive: "Archive"
        case .reply: "Reply"
        case .replyAll: "Reply All"
        case .forward: "Forward"
        case .flag: "Flag"
        case .snooze: "Snooze"
        case .delete: "Delete"
        case .compose: "New Message"
        case .search: "Search"
        case .settings: "Settings"
        case .syncIdle: "Synced"
        case .syncing: "Syncing"
        case .syncOffline: "Offline"
        case .syncError: "Sync error"
        case .lock: "Lock"
        case .encrypted: "Encrypted"
        case .ai: "AI"
        case .briefing: "Briefing"
        case .calendar: "Calendar"
        case .mail: "Mail"
        case .person: "Person"
        case .company: "Company"
        case .project: "Project"
        case .alert: "Alert"
        case .sidebar: "Sidebar"
        case .palette: "Command palette"
        case .conversations: "Conversations"
        case .pin: "Pin"
        case .inbox: "Inbox"
        case .drafts: "Drafts"
        case .sent: "Sent"
        case .junk: "Junk"
        case .outbox: "Outbox"
        case .location: "Location"
        case .organiser: "Organiser"
        case .people: "People"
        case .video: "Video"
        case .copy: "Copy"
        case .print: "Print"
        case .export: "Share"
        case .forbidden: "Not allowed"
        case .eye: "View only"
        case .info: "Info"
        case .check: "Done"
        case .close: "Close"
        case .plus: "Add"
        case .minus: "Remove"
        case .chevronLeft: "Previous"
        case .chevronRight: "Next"
        case .chevronUp: "Up"
        case .chevronDown: "Down"
        case .shield: "Sensitivity label"
        case .shieldAlert: "Blocked"
        case .key: "Key"
        case .attachment: "Attachment"
        case .globe: "External"
        case .recurring: "Repeats"
        case .throttled: "Throttled"
        case .fixtures: "Fixtures"
        case .rewrite: "Rewrite"
        case .summarise: "Summarise"
        case .checklist: "Checklist"
        case .unknown: "Unknown label"
        case .keyboard: "Keyboard"
        case .noNetwork: "No network"
        case .calendarCancel: "Cancel meeting"
        case .undo: "Undo"
        case .image: "Image"
        case .away: "Away"
        case .important: "High importance"
        case .tag: "Category"
        case .wiped: "Data removed"
        case .grip: "Reorder"
        case .box: "Not selected"
        case .boxChecked: "Selected"
        }
    }

    /// The SF Symbol this glyph replaces (non-brand themes and fallbacks keep using it).
    var sfFallback: String {
        switch self {
        case .archive: "archivebox"
        case .reply: "arrowshape.turn.up.left"
        case .replyAll: "arrowshape.turn.up.left.2"
        case .forward: "arrowshape.turn.up.right"
        case .flag: "flag"
        case .snooze: "clock"
        case .delete: "trash"
        case .compose: "square.and.pencil"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        case .syncIdle: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath"
        case .syncOffline: "icloud.slash"
        case .syncError: "exclamationmark.arrow.triangle.2.circlepath"
        case .lock: "lock"
        case .encrypted: "lock.shield"
        case .ai: "sparkles"
        case .briefing: "sun.horizon"
        case .calendar: "calendar"
        case .mail: "envelope"
        case .person: "person.crop.circle"
        case .company: "building.2"
        case .project: "folder"
        case .alert: "exclamationmark.triangle"
        case .sidebar: "sidebar.left"
        case .palette: "command"
        case .conversations: "square.stack"
        case .pin: "pin"
        case .inbox: "tray"
        case .drafts: "doc"
        case .sent: "paperplane"
        case .junk: "xmark.bin"
        case .outbox: "tray.and.arrow.up"
        case .location: "mappin.and.ellipse"
        case .organiser: "person.crop.circle.badge.checkmark"
        case .people: "person.2"
        case .video: "video"
        case .copy: "doc.on.doc"
        case .print: "printer"
        case .export: "square.and.arrow.up"
        case .forbidden: "nosign"
        case .eye: "eye"
        case .info: "info.circle"
        case .check: "checkmark"
        case .close: "xmark"
        case .plus: "plus"
        case .minus: "minus.circle"
        case .chevronLeft: "chevron.left"
        case .chevronRight: "chevron.right"
        case .chevronUp: "chevron.up"
        case .chevronDown: "chevron.down"
        case .shield: "shield.lefthalf.filled"
        case .shieldAlert: "exclamationmark.shield"
        case .key: "key.horizontal"
        case .attachment: "paperclip"
        case .globe: "globe"
        case .recurring: "repeat"
        case .throttled: "tortoise"
        case .fixtures: "testtube.2"
        case .rewrite: "wand.and.stars"
        case .summarise: "text.append"
        case .checklist: "checklist"
        case .unknown: "questionmark.diamond"
        case .keyboard: "keyboard"
        case .noNetwork: "wifi.slash"
        case .calendarCancel: "calendar.badge.minus"
        case .undo: "arrow.uturn.backward"
        case .image: "photo"
        case .away: "airplane"
        case .important: "exclamationmark"
        case .tag: "tag"
        case .wiped: "trash.slash"
        case .grip: "line.3.horizontal"
        case .box: "circle"
        case .boxChecked: "checkmark.circle.fill"
        }
    }
}

// MARK: - Geometry (24-unit grid, y down)

/// One glyph: stroked polylines (open or closed) plus small solid fills (dots, knobs, the cut).
struct NGlyphGeometry: Sendable {
    struct Line: Sendable { var pts: [CGPoint]; var closed: Bool }
    var lines: [Line] = []
    var fills: [[CGPoint]] = []

    fileprivate mutating func l(_ v: CGFloat...) { lines.append(Line(pts: Self.pts(v), closed: false)) }
    fileprivate mutating func c(_ v: CGFloat...) { lines.append(Line(pts: Self.pts(v), closed: true)) }
    fileprivate mutating func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        lines.append(Line(pts: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)], closed: true))
    }
    fileprivate mutating func f(_ v: CGFloat...) { fills.append(Self.pts(v)) }
    fileprivate mutating func fr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        fills.append([CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)])
    }
    /// A leaning cut (11.03°, bottom edge fixed), filled.
    fileprivate mutating func cut(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        let k = h * CGFloat(tan(NV.lean))
        fills.append([CGPoint(x: x, y: y + h), CGPoint(x: x + w, y: y + h), CGPoint(x: x + w + k, y: y), CGPoint(x: x + k, y: y)])
    }
    /// Cut-corner square: the brand's stand-in for a circle.
    fileprivate mutating func oct(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        let k = r * 0.42
        c(cx - k, cy - r, cx + k, cy - r, cx + r, cy - k, cx + r, cy + k, cx + k, cy + r, cx - k, cy + r, cx - r, cy + k, cx - r, cy - k)
    }
    private static func pts(_ v: [CGFloat]) -> [CGPoint] {
        stride(from: 0, to: v.count - 1, by: 2).map { CGPoint(x: v[$0], y: v[$0 + 1]) }
    }

    fileprivate mutating func syncArrows() {
        l(4, 11, 4, 6, 19, 6); l(16, 3, 19, 6, 16, 9)        // top run → right
        l(20, 13, 20, 18, 5, 18); l(8, 15, 5, 18, 8, 21)     // bottom run → left
    }

    static func of(_ kind: NGlyphKind) -> NGlyphGeometry {
        var g = NGlyphGeometry()
        switch kind {
        case .archive:
            g.r(3, 4, 18, 5); g.l(5, 9, 5, 20, 19, 20, 19, 9); g.l(10, 13, 14, 13)
        case .reply:
            g.l(20, 19, 20, 13, 5, 13); g.l(10, 8, 5, 13, 10, 18)
        case .replyAll:
            g.l(21, 19, 21, 13, 10, 13); g.l(14, 8, 9, 13, 14, 18); g.l(8, 8, 3, 13, 8, 18)
        case .forward:
            g.l(4, 19, 4, 13, 19, 13); g.l(14, 8, 19, 13, 14, 18)
        case .flag:
            g.l(6, 21, 6, 3); g.c(6, 4, 19, 4, 15.5, 8.5, 19, 13, 6, 13)
        case .snooze:
            g.oct(12, 13.5, 7.5); g.l(12, 10, 12, 14, 15, 16); g.l(9, 2.5, 15, 2.5)
        case .delete:
            g.l(3, 6, 21, 6); g.l(9, 6, 9, 3, 15, 3, 15, 6); g.l(5.5, 6, 6.5, 21, 17.5, 21, 18.5, 6)
            g.l(10, 10, 10, 17); g.l(14, 10, 14, 17)
        case .compose:
            g.l(11, 4, 4, 4, 4, 20, 20, 20, 20, 13); g.c(9, 15, 9, 12, 17.5, 3.5, 20.5, 6.5, 12, 15)
        case .search:
            g.oct(10, 10, 6.5); g.l(15, 15, 21, 21)
        case .settings:
            g.l(3, 6, 21, 6); g.l(3, 12, 21, 12); g.l(3, 18, 21, 18)
            g.fr(7, 4, 3, 4); g.fr(14, 10, 3, 4); g.fr(9, 16, 3, 4)
        case .syncIdle:
            g.syncArrows()
        case .syncing:
            g.syncArrows(); g.cut(10.5, 9.5, 2.2, 5)
        case .syncOffline:
            g.syncArrows(); g.l(3, 3, 21, 21)
        case .syncError:
            g.syncArrows(); g.l(12, 9, 12, 12.5); g.fr(11.25, 14, 1.5, 1.5)
        case .lock:
            g.l(8, 10, 8, 4, 16, 4, 16, 10); g.r(5, 10, 14, 11); g.l(12, 14, 12, 17)
        case .encrypted:
            g.c(12, 3, 20, 6, 20, 12.5, 12, 21, 4, 12.5, 4, 6); g.fr(10.5, 9, 3, 3); g.l(12, 12, 12, 15.5)
        case .ai:
            // The ıı: the centreline of the mark's 24-unit band (NiivoMark), so the stroke weight is the band.
            let k: CGFloat = 18 / 238, ox: CGFloat = 3, oy = (24 - 236 * k) / 2
            for dx in [CGFloat(0), 116] {
                let p = [(14.565, 224.0), (66.115, 224.0), (107.435, 12.0), (55.885, 12.0)]
                    .flatMap { [ox + (CGFloat($0.0) + dx) * k, oy + CGFloat($0.1) * k] }
                g.lines.append(Line(pts: stride(from: 0, to: p.count, by: 2).map { CGPoint(x: p[$0], y: p[$0 + 1]) }, closed: true))
            }
        case .briefing:
            // Focus-frame brackets (never a full box) around three lines.
            g.l(3, 7, 3, 3, 7, 3); g.l(17, 3, 21, 3, 21, 7); g.l(21, 17, 21, 21, 17, 21); g.l(7, 21, 3, 21, 3, 17)
            g.l(7.5, 9, 16.5, 9); g.l(7.5, 12, 16.5, 12); g.l(7.5, 15, 12.5, 15)
        case .calendar:
            g.r(3, 5, 18, 16); g.l(3, 10, 21, 10); g.l(8, 3, 8, 7); g.l(16, 3, 16, 7); g.fr(14, 14, 3, 3)
        case .mail:
            g.r(3, 5, 18, 14); g.l(3, 5, 12, 13, 21, 5)
        case .person:
            g.r(8.5, 3.5, 7, 7); g.l(5, 21, 5, 17, 8, 14, 16, 14, 19, 17, 19, 21)
        case .company:
            g.l(5, 21, 5, 4, 14, 4, 14, 21); g.l(14, 9, 19, 9, 19, 21); g.l(2.5, 21, 21.5, 21)
            g.l(8, 8, 11, 8); g.l(8, 12, 11, 12); g.l(8, 16, 11, 16)
        case .project:
            g.c(3, 20, 3, 4, 10, 4, 12, 7, 21, 7, 21, 20)
        case .alert:
            g.c(12, 3.5, 21.5, 20, 2.5, 20); g.l(12, 9.5, 12, 14); g.fr(11.25, 16, 1.5, 1.5)
        case .sidebar:
            g.r(3, 4, 18, 16); g.l(9, 4, 9, 20)
        case .palette:
            g.r(3, 5, 18, 14); g.l(7, 9.5, 10, 12, 7, 14.5); g.l(12.5, 14.5, 17, 14.5)
        case .conversations:
            g.r(3, 9, 13, 11); g.l(7, 9, 7, 4, 21, 4, 21, 15, 16, 15)
        case .pin:
            g.l(8.5, 3, 15.5, 3); g.c(10, 3, 14, 3, 14, 9.5, 18, 14, 6, 14, 10, 9.5); g.l(12, 14, 12, 21)
        case .inbox:
            g.c(5.5, 5, 18.5, 5, 21, 13, 21, 20, 3, 20, 3, 13); g.l(3, 13, 8, 13, 9.5, 16, 14.5, 16, 16, 13, 21, 13)
        case .drafts:
            g.c(5, 3, 14, 3, 19, 8, 19, 21, 5, 21); g.l(14, 3, 14, 8, 19, 8)
        case .sent:
            g.c(3, 11, 21, 3, 14, 21, 11, 13); g.l(11, 13, 21, 3)
        case .junk:
            g.r(3, 4, 18, 5); g.l(5, 9, 5, 20, 19, 20, 19, 9); g.l(9.5, 11.5, 14.5, 16.5); g.l(14.5, 11.5, 9.5, 16.5)
        case .outbox:
            g.l(8, 13, 3, 13, 3, 20, 21, 20, 21, 13, 16, 13); g.l(12, 16, 12, 3.5); g.l(7.5, 8, 12, 3.5, 16.5, 8)
        case .location:
            g.c(12, 21, 5.5, 12, 5.5, 6, 8.5, 3, 15.5, 3, 18.5, 6, 18.5, 12); g.fr(10.5, 7.5, 3, 3)
        case .organiser:
            g.r(5.5, 3.5, 7, 7); g.l(2, 21, 2, 17, 5, 14, 13, 14, 14.5, 15.5); g.l(14.5, 18, 17, 20.5, 22, 15.5)
        case .people:
            g.r(4, 6.5, 6.5, 6.5); g.l(2, 21, 2, 18, 4.5, 15.5, 10, 15.5, 12.5, 18, 12.5, 21); g.r(13.5, 3.5, 6.5, 6.5); g.l(14.5, 12.5, 19.5, 12.5, 22, 15, 22, 19, 15.5, 19)
        case .video:
            g.r(2.5, 7, 13, 10); g.c(15.5, 10.5, 21.5, 7, 21.5, 17, 15.5, 13.5)
        case .copy:
            g.r(8, 8, 12, 13); g.l(8, 16, 4, 16, 4, 3, 16, 3, 16, 8)
        case .print:
            g.l(7, 9, 7, 3, 17, 3, 17, 9); g.l(7, 17, 3, 17, 3, 9, 21, 9, 21, 17, 17, 17); g.r(7, 14, 10, 7)
        case .export:
            g.l(8, 9, 4, 9, 4, 21, 20, 21, 20, 9, 16, 9); g.l(12, 15, 12, 3.5); g.l(8, 7.5, 12, 3.5, 16, 7.5)
        case .forbidden:
            g.oct(12, 12, 8.5); g.l(6.5, 6.5, 17.5, 17.5)
        case .eye:
            g.c(2, 12, 7, 6.5, 17, 6.5, 22, 12, 17, 17.5, 7, 17.5); g.r(9.5, 9.5, 5, 5)
        case .info:
            g.oct(12, 12, 9); g.l(12, 11, 12, 16.5); g.fr(11.25, 7.25, 1.5, 1.5)
        case .check:
            g.l(4, 12.5, 9.5, 18, 20, 6.5)
        case .close:
            g.l(5, 5, 19, 19); g.l(19, 5, 5, 19)
        case .plus:
            g.l(12, 4, 12, 20); g.l(4, 12, 20, 12)
        case .minus:
            g.oct(12, 12, 8.5); g.l(8, 12, 16, 12)
        case .chevronLeft:
            g.l(15, 4, 7, 12, 15, 20)
        case .chevronRight:
            g.l(9, 4, 17, 12, 9, 20)
        case .chevronUp:
            g.l(4, 15.5, 12, 7.5, 20, 15.5)
        case .chevronDown:
            g.l(4, 8.5, 12, 16.5, 20, 8.5)
        case .shield:
            g.c(12, 3, 20, 6, 20, 12.5, 12, 21, 4, 12.5, 4, 6); g.f(12, 3, 4, 6, 4, 12.5, 12, 21)
        case .shieldAlert:
            g.c(12, 3, 20, 6, 20, 12.5, 12, 21, 4, 12.5, 4, 6); g.l(12, 7.5, 12, 12.5); g.fr(11.25, 14.5, 1.5, 1.5)
        case .key:
            g.oct(7, 12, 4.5); g.l(11.5, 12, 21, 12); g.l(17, 12, 17, 15.5); g.l(20, 12, 20, 15)
        case .attachment:
            g.l(16, 8, 16, 20, 7, 20, 7, 4, 13, 4, 13, 16, 10, 16, 10, 8)
        case .globe:
            g.oct(12, 12, 9); g.l(3, 12, 21, 12); g.c(12, 3, 16, 7.5, 16, 16.5, 12, 21, 8, 16.5, 8, 7.5)
        case .recurring:
            g.l(4, 12, 4, 7, 19, 7); g.l(16, 4, 19, 7, 16, 10); g.l(20, 12, 20, 17, 5, 17); g.l(8, 14, 5, 17, 8, 20)
        case .throttled:
            g.c(4, 16, 7, 10, 16, 10, 19, 16); g.l(2, 16, 22, 16); g.l(7, 16, 7, 19.5); g.l(16, 16, 16, 19.5); g.l(18, 13, 22, 13, 22, 16)
        case .fixtures:
            g.l(7, 3, 17, 3); g.l(9, 3, 9, 18, 12, 21, 15, 18, 15, 3); g.l(9, 12, 15, 12)
        case .rewrite:
            g.l(3, 6, 15, 6); g.l(3, 11, 11, 11); g.l(3, 16, 8, 16); g.c(11.5, 21, 11.5, 18, 19, 10.5, 22, 13.5, 14.5, 21)
        case .summarise:
            g.l(3, 5, 21, 5); g.l(3, 10, 21, 10); g.l(3, 15, 11, 15); g.l(17, 13, 17, 21); g.l(13, 17, 21, 17)
        case .checklist:
            g.l(3, 6, 5, 8, 8.5, 4.5); g.l(11.5, 6, 21, 6); g.l(3, 12, 5, 14, 8.5, 10.5); g.l(11.5, 12, 21, 12); g.r(3.5, 16.5, 4.5, 4.5); g.l(11.5, 18.75, 21, 18.75)
        case .unknown:
            g.c(12, 2.5, 21.5, 12, 12, 21.5, 2.5, 12); g.l(9.5, 9.5, 9.5, 7.5, 14.5, 7.5, 14.5, 11, 12, 12.5, 12, 14); g.fr(11.25, 15.75, 1.5, 1.5)
        case .keyboard:
            g.r(2, 6, 20, 12); g.fr(5, 9, 2, 2); g.fr(9, 9, 2, 2); g.fr(13, 9, 2, 2); g.fr(17, 9, 2, 2); g.l(7, 14.5, 17, 14.5)
        case .noNetwork:
            g.l(2.5, 9.5, 7, 6, 17, 6, 21.5, 9.5); g.l(6, 13.5, 9, 11, 15, 11, 18, 13.5); g.fr(10.75, 16, 2.5, 2.5); g.l(4, 3, 20, 21)
        case .calendarCancel:
            g.r(3, 5, 18, 16); g.l(3, 10, 21, 10); g.l(8, 3, 8, 7); g.l(16, 3, 16, 7); g.l(8.5, 15.5, 15.5, 15.5)
        case .undo:
            g.l(9, 4, 4, 9, 9, 14); g.l(4, 9, 17, 9, 20, 12, 20, 17, 17, 20, 11, 20)
        case .image:
            g.r(3, 5, 18, 14); g.l(3, 16, 9, 10, 14, 15, 16.5, 12.5, 21, 17); g.fr(15, 8, 2.5, 2.5)
        case .away:
            g.c(12, 2, 13.5, 4, 13.5, 9.5, 21, 14, 21, 16, 13.5, 13.5, 13.5, 18, 16, 20, 16, 21.5, 12, 20.5, 8, 21.5, 8, 20, 10.5, 18, 10.5, 13.5, 3, 16, 3, 14, 10.5, 9.5, 10.5, 4)
        case .important:
            g.l(12, 4, 12, 15); g.fr(11.25, 18, 1.5, 1.5)
        case .tag:
            g.c(3, 3, 12, 3, 21, 12, 12, 21, 3, 12); g.fr(6.5, 6.5, 2.5, 2.5)
        case .wiped:
            g.l(3, 6, 21, 6); g.l(9, 6, 9, 3, 15, 3, 15, 6); g.l(5.5, 6, 6.5, 21, 17.5, 21, 18.5, 6); g.l(2.5, 2.5, 21.5, 21.5)
        case .grip:
            g.l(5, 8, 19, 8); g.l(5, 12, 19, 12); g.l(5, 16, 19, 16)
        case .box:
            g.r(5, 5, 14, 14)
        case .boxChecked:
            g.r(5, 5, 14, 14); g.l(8.5, 12, 11, 14.5, 16, 9.5)
        }
        return g
    }
}

// MARK: - Shapes

/// The stroked part of a glyph, scaled from the 24-unit grid into the rect (centred, aspect kept).
struct NGlyphLines: Shape {
    var kind: NGlyphKind
    nonisolated func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        var p = Path()
        for ln in NGlyphGeometry.of(kind).lines {
            p.addLines(ln.pts.map { CGPoint(x: o.x + $0.x * s, y: o.y + $0.y * s) })
            if ln.closed { p.closeSubpath() }
        }
        return p
    }
}

/// The solid part of a glyph (dots, knobs, the cut).
struct NGlyphFills: Shape {
    var kind: NGlyphKind
    nonisolated func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        var p = Path()
        for poly in NGlyphGeometry.of(kind).fills {
            p.addLines(poly.map { CGPoint(x: o.x + $0.x * s, y: o.y + $0.y * s) }); p.closeSubpath()
        }
        return p
    }
}

/// A niivo glyph. Tints with `foregroundStyle`. `weight` is the stroke in **grid units** (default 1.5 of 24, so a
/// 14 pt glyph draws a 0.875 pt line). `label == ""` hides it from VoiceOver (decorative, next to text).
struct NGlyph: View {
    let kind: NGlyphKind
    let size: CGFloat
    let weight: CGFloat?
    let label: String?

    init(_ kind: NGlyphKind, size: CGFloat = 14, weight: CGFloat? = nil, label: String? = nil) {
        self.kind = kind; self.size = size; self.weight = weight; self.label = label
    }

    static let defaultWeight: CGFloat = 1.5

    var body: some View {
        let lw = (weight ?? Self.defaultWeight) * size / 24
        let art = ZStack {
            NGlyphLines(kind: kind)
                .stroke(style: StrokeStyle(lineWidth: lw, lineCap: .square, lineJoin: .miter, miterLimit: 10))
            NGlyphFills(kind: kind).fill()
        }
        .frame(width: size, height: size)
        if label == "" {
            art.accessibilityHidden(true)
        } else {
            art.accessibilityElement()
                .accessibilityLabel(label ?? kind.defaultLabel)
                .accessibilityAddTraits(.isImage)
        }
    }
}

// MARK: - Sheet (preview render)

/// Every glyph at 24 pt with its mono name, plus a row at the real 14 pt size.
struct NiivoGlyphSheet: View {
    @Environment(\.skin) private var skin
    var columns = 7

    var body: some View {
        let kinds = NGlyphKind.allCases
        let rows = stride(from: 0, to: kinds.count, by: columns).map { Array(kinds[$0..<min($0 + columns, kinds.count)]) }
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                MonoLabel("NIIVO GLYPHS — 24 GRID · 1.5 LINE · SQUARE CUT", bracket: true)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { ri in
                    HStack(spacing: 0) {
                        ForEach(rows[ri], id: \.self) { k in
                            VStack(spacing: 10) {
                                NGlyph(k, size: 24).foregroundStyle(skin.ink)
                                MonoLabel(k.rawValue, size: NV.Size.labelSm)
                            }
                            .frame(width: 112, height: 84)
                            .overlay(alignment: .trailing) { Rectangle().fill(skin.hair).frame(width: 1) }
                        }
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(skin.hair).frame(height: 1) }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(skin.hair).frame(height: 1) }
            .overlay(alignment: .leading) { Rectangle().fill(skin.hair).frame(width: 1) }
            VStack(alignment: .leading, spacing: 10) {
                MonoLabel("14 PT — TOOLBAR / ROW SIZE", size: NV.Size.labelSm)
                ForEach(rows.indices, id: \.self) { ri in
                    HStack(spacing: 14) {
                        ForEach(rows[ri], id: \.self) { k in NGlyph(k).foregroundStyle(skin.ink) }
                    }
                }
                MonoLabel("14 PT — MUTED / ACCENT INK", size: NV.Size.labelSm)
                ForEach(rows.indices, id: \.self) { ri in
                    HStack(spacing: 14) {
                        ForEach(rows[ri], id: \.self) { k in NGlyph(k).foregroundStyle(k == .ai ? skin.accentInk : skin.muted) }
                    }
                }
            }
        }
        .padding(32)
        .background(skin.ground)
    }
}

// MARK: - AppKit images

enum NiivoGlyphs {
    /// The menu-bar item: the solid ıı (small-size rule: no hole below 32 px), monochrome template, 18 × 18 pt.
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let w: CGFloat = 15, h = w * 236 / 238
            let box = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
            cg.setFillColor(NSColor.black.cgColor)
            cg.addPath(NiivoIconArt.markPath(in: box, solid: true))
            cg.fillPath()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "niivo mail"
        return img
    }

    /// For NSAlert / notification-style surfaces: the app icon art (carbon, signal ıı, no shadow) at 128 pt.
    static func alertImage() -> NSImage {
        let side: CGFloat = 128
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            NiivoIconArt.draw(in: cg, side: rect.width, colorway: .signal, pointSize: 64)
            return true
        }
        img.accessibilityDescription = "niivo mail"
        return img
    }
}
