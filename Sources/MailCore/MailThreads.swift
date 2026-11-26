import Foundation
import CalendarCore
import SQLite3

// Conversation view (Gmail-style threads). UI-free so CoreSelfTest covers it; the app's list (ThreadRow), reader
// (ConversationReader) and actions (MailModel+Threads) sit on top.
//
// Three member sets, kept apart on purpose:
//  * row count / unread / flag / actions → messages of the thread in the CURRENT folder only;
//  * reader → current folder + Sent Items of the same mailbox (your replies participate, like Gmail);
//  * label chip → the strictest label over the reader set (an unknown label wins: under-reporting is the only
//    direction with a compliance cost).

/// Keyset cursor for the thread list: (latest received in folder, conversation id), newest first.
public struct MailThreadCursor: Sendable, Hashable {
    public var latest: Date
    public var conversationId: String
    public init(latest: Date, conversationId: String) { self.latest = latest; self.conversationId = conversationId }
}

/// One row of the threaded list.
public struct MailThreadSummary: Sendable, Hashable, Identifiable {
    public var conversationId: String
    /// Newest member in the folder (the row's representative: its id is the row id, its subject/snippet are shown).
    public var latest: MailMessage
    /// Members in the current folder, newest first (capped at `MailThreads.memberCap`; `count` is exact).
    public var members: [MailMessage]
    /// Reader set headers (folder + Sent), oldest first — participants and the strictest label come from these.
    public var readerMembers: [MailMessage]
    public var count: Int
    public var unreadCount: Int
    public var flagged: Bool
    public var id: String { conversationId }
    public var hasUnread: Bool { unreadCount > 0 }
    public var cursor: MailThreadCursor { MailThreadCursor(latest: latest.received, conversationId: conversationId) }

    public init(conversationId: String, latest: MailMessage, members: [MailMessage], readerMembers: [MailMessage],
                count: Int, unreadCount: Int, flagged: Bool) {
        self.conversationId = conversationId; self.latest = latest; self.members = members
        self.readerMembers = readerMembers; self.count = count; self.unreadCount = unreadCount; self.flagged = flagged
    }
}

public enum MailThreads {
    /// Most members unsealed per thread for a list page (counts stay exact; SQL aggregates them).
    public static let memberCap = 200

    // MARK: Participants

    /// Distinct senders in reading order (oldest first); your own addresses collapse to "me".
    /// Gmail style: one participant → full name; several → first names, at most three ("Anna … Peter, me").
    public static func participants(_ readerMembers: [MailMessage], me: Set<String>) -> [String] {
        var seen = Set<String>(), out: [(key: String, name: String)] = []
        for m in readerMembers.sorted(by: { $0.received < $1.received }) {
            guard let f = m.from ?? m.sender else { continue }
            let a = f.address.lowercased()
            let isMe = me.contains(a)
            let key = isMe ? "\u{1}me" : a
            guard seen.insert(key).inserted else { continue }
            out.append((key, isMe ? "me" : f.display))
        }
        if out.count <= 1 { return out.map(\.name) }
        let short = out.map { $0.key == "\u{1}me" ? "me" : firstName($0.name) }
        if short.count <= 3 { return short }
        return [short[0], "…", short[short.count - 2], short[short.count - 1]]
    }

    public static func participantLine(_ readerMembers: [MailMessage], me: Set<String>) -> String {
        participants(readerMembers, me: me).joined(separator: ", ").replacingOccurrences(of: "…, ", with: "… ")
    }

    static func firstName(_ s: String) -> String {
        if s.contains("@") { return String(s.split(separator: "@").first ?? Substring(s)) }
        // "Muster, Anna" (Outlook "Last, First") → Anna; "Anna Muster" → Anna.
        if let comma = s.firstIndex(of: ",") {
            let after = s[s.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if !after.isEmpty { return String(after.split(separator: " ").first ?? Substring(after)) }
        }
        return String(s.split(separator: " ").first ?? Substring(s))
    }

    // MARK: Policy

    /// The strictest policy over a thread: every control at its most restrictive (`ContentPolicy.merged`), and the
    /// label state chosen as unknown > highest-priority label > unlabelled. Markings come from the chosen label's
    /// policy. Used for the row chip and the conversation's capture shield — never to render a member's body
    /// (each member keeps its own policy).
    public static func strictest(_ policies: [ContentPolicy]) -> ContentPolicy {
        guard var base = policies.first else { return .open }
        for p in policies.dropFirst() where rank(p) > rank(base) { base = p }
        return policies.reduce(base) { $0.merged(with: $1) }
    }

    static func rank(_ p: ContentPolicy) -> Int {
        switch p.labelState {
        case .unlabeled: return Int.min
        case .labeled(let l): return l.priority
        case .unknown: return Int.max
        }
    }

    /// Same fail-closed rule as the single-message reader: no body fetch for private-redacted, encrypted or
    /// unknown-label mail.
    public static func mayFetchBody(_ p: ContentPolicy) -> Bool {
        if p.redactDetails || p.bodyIsProtected { return false }
        if case .unknown = p.labelState { return false }
        return true
    }

    // MARK: Reader

    /// The reader set from a whole conversation: members in the current folder plus Sent Items of the same mailbox,
    /// oldest first (`newestFirst` flips it). Other folders (Deleted, Junk, archived copies) stay out.
    public static func readerMembers(_ conversation: [MailMessage], folderId: String, sentFolderId: String?,
                                     newestFirst: Bool = false) -> [MailMessage] {
        let keep = conversation.filter { $0.folderId == folderId || ($0.folderId == sentFolderId && sentFolderId != nil) }
        var seen = Set<String>()
        let sorted = keep.filter { seen.insert($0.id).inserted }.sorted { ($0.received, $0.id) < ($1.received, $1.id) }
        return newestFirst ? sorted.reversed() : sorted
    }

    /// Expanded on open: every unread member and the newest one; read ones collapse to a one-line header.
    public static func initiallyExpanded(_ members: [MailMessage]) -> Set<String> {
        var s = Set(members.filter { !$0.isRead }.map(\.id))
        if let newest = members.max(by: { ($0.received, $0.id) < ($1.received, $1.id) }) { s.insert(newest.id) }
        return s
    }

    /// Reply / Reply all / Forward target with no explicit card: the newest non-draft member someone else sent
    /// (replying to your own Sent reply would address yourself); your own newest if nobody else wrote.
    public static func replyTarget(_ members: [MailMessage], me: Set<String> = []) -> MailMessage? {
        let sent = members.filter { !$0.isDraft }
        let newest: ([MailMessage]) -> MailMessage? = { $0.max { ($0.received, $0.id) < ($1.received, $1.id) } }
        return newest(sent.filter { !me.contains(($0.from ?? $0.sender)?.address.lowercased() ?? "") }) ?? newest(sent)
    }

    // MARK: Actions

    /// One thread action over its in-folder members: forward steps (only members that change) and undo steps built
    /// from each member's own before-state (state changes newest-first, moves back last), for ONE ⌘Z entry.
    public static func plan(_ action: MailAction, members: [MailMessage]) -> (steps: [BulkStep], undo: [BulkStep]) {
        var steps: [BulkStep] = [], state: [BulkStep] = [], moves: [BulkStep] = []
        for m in members {
            switch action {
            case .markRead(let r): if m.isRead == r { continue }
            case .flag(let f): if m.flag.status == f.status && m.flag.due == f.due { continue }
            case .categorize(let c): if m.categories == c { continue }
            default: break
            }
            steps.append(BulkStep(messageId: m.id, action: action))
            switch action {
            case .markRead: state.append(BulkStep(messageId: m.id, action: .markRead(m.isRead)))
            case .flag: state.append(BulkStep(messageId: m.id, action: .flag(m.flag)))
            case .categorize: state.append(BulkStep(messageId: m.id, action: .categorize(m.categories)))
            case .move, .delete, .snooze, .unsnooze: moves.append(BulkStep(messageId: m.id, action: .move(toFolderId: m.folderId)))
            }
        }
        return (steps, state.reversed() + moves)
    }

    /// Does this action take the thread out of the current list?
    public static func removesFromList(_ action: MailAction) -> Bool {
        switch action { case .move, .delete, .snooze, .unsnooze: true; default: false }
    }
}

// MARK: - Quoted history

/// Splits a message body at the start of its quoted history (Outlook, Gmail, Apple Mail, plain text), so the
/// conversation reader can hide it behind a "…" toggle. Runs on the already-sanitised HTML; never across messages.
public enum QuotedHistory {
    /// Markers (lowercased) that begin quoted history in HTML, earliest match wins.
    static let htmlMarkers = [
        "<div id=\"appendonsend\"", "<div id=\"divrplyfwdmsg\"", "<hr style=\"display:inline-block;width:98%\"",
        "<div class=\"gmail_quote", "<blockquote type=\"cite\"", "<div class=\"outlookmessageheader\"",
        "-----original message-----", "<div id=\"mail-editor-reference-message-container\"",
    ]

    /// (visible part, quoted part). `quoted` is nil when nothing was found or the split would leave nothing visible.
    public static func split(html: String) -> (main: String, quoted: String?) {
        let lower = html.lowercased()
        var cut: String.Index?
        for mk in htmlMarkers {
            if let r = lower.range(of: mk), cut.map({ r.lowerBound < $0 }) ?? true { cut = r.lowerBound }
        }
        guard let c = cut else { return (html, nil) }
        let off = lower.distance(from: lower.startIndex, to: c)
        let idx = html.index(html.startIndex, offsetBy: off)
        let main = String(html[..<idx])
        guard hasText(main) else { return (html, nil) }
        return (main, String(html[idx...]))
    }

    /// Plain text: from the first "On … wrote:" / "From: … Sent:" header or a run of "> " lines.
    public static func split(text: String) -> (main: String, quoted: String?) {
        let lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() where i > 0 {
            let l = raw.trimmingCharacters(in: .whitespaces)
            let isHeader = (l.hasPrefix("On ") && l.hasSuffix("wrote:")) || l.hasPrefix("-----Original Message-----")
                || (l.hasPrefix("From:") && lines.dropFirst(i + 1).prefix(3).contains { $0.hasPrefix("Sent:") || $0.hasPrefix("Date:") })
                || (l.hasPrefix(">") && (i + 1 < lines.count ? lines[i + 1].hasPrefix(">") : true))
            if isHeader {
                let main = lines[..<i].joined(separator: "\n")
                guard !main.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (text, nil) }
                return (main, lines[i...].joined(separator: "\n"))
            }
        }
        return (text, nil)
    }

    static func hasText(_ html: String) -> Bool {
        let stripped = html.replacingOccurrences(of: "<(style|head)[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Preferences + Gmail keys

public struct MailThreadPreferences: Equatable, Sendable {
    /// Group by conversation (default ON). Key predates this struct (MailModel.groupConversations).
    public var grouped = true
    /// Conversation reader order: false = Gmail (newest at the bottom), true = newest on top.
    public var newestOnTop = false
    public init() {}
    public enum Key {
        public static let grouped = "mail.groupConversations"
        public static let newestOnTop = "mail.threadNewestOnTop"
    }
    public static func load(_ d: UserDefaults = .standard) -> MailThreadPreferences {
        var p = MailThreadPreferences()
        if d.object(forKey: Key.grouped) != nil { p.grouped = d.bool(forKey: Key.grouped) }
        if d.object(forKey: Key.newestOnTop) != nil { p.newestOnTop = d.bool(forKey: Key.newestOnTop) }
        return p
    }
    public func save(_ d: UserDefaults = .standard) {
        d.set(grouped, forKey: Key.grouped); d.set(newestOnTop, forKey: Key.newestOnTop)
    }
}

/// Gmail-only keys (when "Gmail shortcuts" is chosen). j/k, e, #, r/a/f and s go through the shared keymap.
public enum GmailThreadKey: Equatable, Sendable {
    case nextMessage, previousMessage, expand, toggleSelect, backToList
    public static func action(for characters: String) -> GmailThreadKey? {
        switch characters {
        case "n": .nextMessage
        case "p": .previousMessage
        case "o": .expand
        case "x": .toggleSelect
        case "u": .backToList
        default: nil
        }
    }
}

// MARK: - Store

extension MailStore {
    /// Threaded keyset page of a folder: one summary per conversation with messages in `folderId`, newest thread
    /// first. Grouping, counts, unread and flag are SQL aggregates (covering index messages_by_folder_conv); only the
    /// page's members are unsealed. `sentFolderId` adds the mailbox's Sent Items to each thread's reader set.
    public func threads(folderId: String, sentFolderId: String? = nil, before: MailThreadCursor? = nil,
                        limit: Int = 50) throws -> [MailThreadSummary] {
        var sql = """
            SELECT conversation_id, MAX(received) AS latest, COUNT(*), SUM(is_read = 0), MAX(flagged)
            FROM messages WHERE folder_id = ? GROUP BY conversation_id
            """
        var params: [Bind] = [.text(folderId)]
        if let before {
            let t = Int64(before.latest.timeIntervalSince1970)
            sql += " HAVING latest < ? OR (latest = ? AND conversation_id < ?)"
            params += [.int(t), .int(t), .text(before.conversationId)]
        }
        sql += " ORDER BY latest DESC, conversation_id DESC LIMIT ?"
        params.append(.int(Int64(limit)))
        struct Agg { var conv: String; var count: Int; var unread: Int; var flagged: Bool }
        let aggs = try query(sql, params) { s in
            Agg(conv: storeText(s, 0), count: Int(sqlite3_column_int64(s, 2)), unread: Int(sqlite3_column_int64(s, 3)),
                flagged: sqlite3_column_int64(s, 4) != 0)
        }
        guard !aggs.isEmpty else { return [] }
        // Members of this page only: folder (+ Sent), newest first, capped per conversation.
        let folders = [folderId] + (sentFolderId.map { $0 == folderId ? [] : [$0] } ?? [])
        let convPH = Array(repeating: "?", count: aggs.count).joined(separator: ",")
        let folderPH = Array(repeating: "?", count: folders.count).joined(separator: ",")
        let msql = """
            SELECT payload FROM (
              SELECT payload, ROW_NUMBER() OVER (PARTITION BY conversation_id, folder_id = ? ORDER BY received DESC, id DESC) AS rn
              FROM messages WHERE conversation_id IN (\(convPH)) AND folder_id IN (\(folderPH))
            ) WHERE rn <= ?
            """
        let mparams: [Bind] = [.text(folderId)] + aggs.map { .text($0.conv) } + folders.map { .text($0) } + [.int(Int64(MailThreads.memberCap))]
        let all = try query(msql, mparams) { s in try self.unseal(MailMessage.self, storeBlob(s, 0)) }
        var byConv: [String: [MailMessage]] = [:]
        for m in all { byConv[m.conversationId, default: []].append(m) }
        return aggs.compactMap { a in
            let ms = byConv[a.conv] ?? []
            let inFolder = ms.filter { $0.folderId == folderId }.sorted { ($0.received, $0.id) > ($1.received, $1.id) }
            guard let latest = inFolder.first else { return nil }
            let reader = ms.sorted { ($0.received, $0.id) < ($1.received, $1.id) }
            return MailThreadSummary(conversationId: a.conv, latest: latest, members: inFolder, readerMembers: reader,
                                     count: a.count, unreadCount: a.unread, flagged: a.flagged)
        }
    }

    /// Thread members in one folder (all of them — actions must reach every member, not just the page's cap).
    public func threadMembers(conversationId: String, folderId: String) throws -> [MailMessage] {
        try query("SELECT payload FROM messages WHERE conversation_id = ? AND folder_id = ? ORDER BY received DESC, id DESC",
                  [.text(conversationId), .text(folderId)]) { s in try self.unseal(MailMessage.self, storeBlob(s, 0)) }
    }

    /// EXPLAIN QUERY PLAN of the thread page (self-test: the grouping must use the covering index).
    public func threadQueryPlan(folderId: String) throws -> String {
        try query("EXPLAIN QUERY PLAN SELECT conversation_id, MAX(received) AS latest, COUNT(*), SUM(is_read = 0), MAX(flagged) FROM messages WHERE folder_id = ? GROUP BY conversation_id ORDER BY latest DESC, conversation_id DESC LIMIT 50",
                  [.text(folderId)]) { s in storeText(s, 3) }.joined(separator: " | ")
    }
}
