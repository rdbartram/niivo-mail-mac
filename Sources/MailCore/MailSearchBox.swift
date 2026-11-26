import Foundation

// SEARCHBOX: the main mail-list search box (Gmail-style). Natural ranked matching as you type, operators strict,
// the folder / mailbox / all-mailboxes scope respected, server `$search` merged in on ↩ or when local hits are few,
// a Best match / Newest toggle, highlight terms and a suggestions dropdown (recent searches, people, operators).
// Privacy is the SearchEngine's (`.user` caller): a row whose details stay off disk only matches on its sender.
// Server hits pass the same rule here (`admitServerHit`), because Graph matches protected content server-side.

public enum MailSearchSort: String, CaseIterable, Sendable, Hashable, Identifiable {
    case bestMatch, newest
    public var id: String { rawValue }
    public var title: String { self == .bestMatch ? "Best match" : "Newest" }
}

public struct MailBoxResult: Sendable {
    /// Best-match order (local ranked hits first, then server-only hits newest first).
    public var ranked: [MailMessage] = []
    /// Newest-first over the WHOLE match set (up to `SearchEngine.decryptPool` local + server), not a re-sort of `ranked`.
    public var newest: [MailMessage] = []
    /// Server hits dropped because their folder isn't cached for that mailbox.
    public var unattributed = 0
    /// Matching items before the limit (local).
    public var total = 0
    /// The local stage ran in natural mode (false = strict-while-typing fallback).
    public var natural = true
    public var serverMerged = false
    public init() {}

    /// Both orders come from one query: the toggle never re-queries.
    public func messages(_ sort: MailSearchSort) -> [MailMessage] {
        sort == .bestMatch ? ranked : newest
    }
}

public enum MailSearchBox {
    /// Typed (debounced) searches run natural mode without the query embedding; ↩ adds the embedding.
    /// Latency fallback: set false → strict `.all` while typing, natural on ↩ (docs/SEARCH-QUALITY.md, "main box").
    public static let naturalWhileTyping = true
    /// Fewer local hits than this → ask the server while typing too (after a longer pause).
    public static let fewLocalHits = 5

    public struct Request: Sendable {
        public var text: String
        public var scope: MailSearchScope
        public var mailbox: String
        public var folderId: String?
        public var allMailboxes: [String]
        public var limit: Int
        /// true = keystroke (debounced), false = ↩.
        public var typing: Bool
        public var now: Date
        public var labelName: @Sendable (String) -> String?
        public init(text: String, scope: MailSearchScope, mailbox: String, folderId: String?, allMailboxes: [String],
                    limit: Int = 100, typing: Bool, now: Date = Date(), labelName: @escaping @Sendable (String) -> String? = { _ in nil }) {
            self.text = text; self.scope = scope; self.mailbox = mailbox; self.folderId = folderId
            self.allMailboxes = allMailboxes; self.limit = limit; self.typing = typing; self.now = now; self.labelName = labelName
        }
        public var mailboxes: [String] { SearchScopePlan.mailboxes(scope: scope, current: mailbox, all: allMailboxes) }
        public var scopedFolder: String? { scope == .folder ? folderId : nil }
        public var query: SearchQuery { SearchQuery.parse(text, now: now) }
    }

    /// Engine options for one mailbox of the request.
    public static func options(_ r: Request, mailbox: String) -> SearchEngine.Options {
        var o = SearchEngine.Options(mailbox: mailbox, limit: r.limit)
        o.match = r.typing && !naturalWhileTyping ? .all : .natural
        o.semantic = !r.typing
        o.strictPhrases = true
        o.folderId = r.scopedFolder
        o.now = r.now
        o.labelName = r.labelName
        return o
    }

    /// Local ranked search over the scope (synchronous: run it off the main actor).
    public static func local(_ r: Request, store: MailStore) -> MailBoxResult {
        let q = r.query
        var out = MailBoxResult()
        guard !q.isEmpty else { return out }
        let engine = SearchEngine(store: store)
        var hits: [SearchHit] = []
        for mb in r.mailboxes {
            var o = options(r, mailbox: mb)
            o.limit = max(r.limit, SearchEngine.decryptPool)   // Newest needs the wider set
            out.natural = o.match == .natural
            let res = engine.search(q, o)
            out.total += res.total
            hits += res.hits
        }
        var seen = Set<String>()
        let all = hits.sorted { ($0.score, $0.message.received, $0.id) > ($1.score, $1.message.received, $1.id) }
            .map(\.message).filter { seen.insert($0.id).inserted }
        out.ranked = Array(all.prefix(r.limit))
        out.newest = Array(byDate(all).prefix(r.limit))
        return out
    }

    /// What goes to Graph `$search`: free words and phrases only (operators are applied locally to the returned hits;
    /// the KQL mapping is unverified). nil: nothing free-text to ask (operator-only query).
    public static func serverText(_ q: SearchQuery) -> String? {
        // As typed (Exchange's own word breaking / diacritics), operators stripped; only quotes and backslashes go.
        let t = q.words.joined(separator: " ").replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: "\\", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.isEmpty ? nil : t
    }

    static func byDate(_ ms: [MailMessage]) -> [MailMessage] { ms.sorted { ($0.received, $0.id) > ($1.received, $1.id) } }

    public static func shouldAskServer(typing: Bool, localCount: Int) -> Bool { !typing || localCount < fewLocalHits }

    /// A server hit is admitted only if every operator holds on what the cache would keep, it's attributable to the
    /// mailbox (folder cached) and in scope, and — where details stay off disk — every free word is in its sender.
    public static func admitServerHit(_ m: MailMessage, query q: SearchQuery, store: MailStore, mailbox: String,
                                      folderId: String?, labelName: (String) -> String? = { _ in nil }) -> Bool {
        let known = ((try? store.folder(id: m.folderId)) ?? nil) != nil
        guard known, store.mailbox(forFolder: m.folderId) == mailbox else { return false }
        if let folderId, m.folderId != folderId { return false }
        let s = store.persistable(m)
        var post = PostFilter(q: q)
        post.store = store; post.strictPhrases = true
        guard post.matchesStructure(s, folderId: folderId, labelName: labelName) else { return false }
        let pol = store.persistablePolicy(m)
        if pol.allowOfflineDetails && !pol.redactDetails { return true }
        let words = BlindIndex.tokenize(q.words.joined(separator: " "))
        let visible = SearchEngine.visibleTokens(s, details: false, subject: false)
        for (i, w) in words.enumerated() {
            let last = i == words.count - 1 && q.prefixLast
            if !visible.contains(where: { last ? $0.hasPrefix(w) : $0 == w }) { return false }
        }
        return true
    }

    /// Local ranked hits first, server-only hits (admitted) after them, newest first.
    public static func merge(_ local: MailBoxResult, server: [MailMessage], unattributed: Int, limit: Int) -> MailBoxResult {
        var r = local
        var seen = Set(local.ranked.map(\.id))
        let extra = server.filter { seen.insert($0.id).inserted }.sorted { ($0.received, $0.id) > ($1.received, $1.id) }
        r.ranked = Array((local.ranked + extra).prefix(limit))
        r.newest = Array(byDate(local.newest + extra).prefix(limit))
        r.unattributed += unattributed
        r.serverMerged = true
        return r
    }
}

extension MailSync {
    /// SEARCHBOX: server half of a main-box search — Graph `$search` per scoped mailbox (shared with `search`),
    /// fresh hits persisted for the reader, then admitted by `MailSearchBox.admitServerHit`.
    public func boxServerHits(_ r: MailSearchBox.Request, excluding: Set<String>) async -> (hits: [MailMessage], unattributed: Int) {
        let q = r.query
        guard let text = MailSearchBox.serverText(q) else { return ([], 0) }
        var out: [MailMessage] = [], dropped = 0
        var seen = excluding
        for mb in r.mailboxes {
            for m in await serverSearch(text, mailbox: mb, limit: r.limit, known: seen) {
                let known = ((try? store.folder(id: m.folderId)) ?? nil) != nil
                if !known || store.mailbox(forFolder: m.folderId) != mb { dropped += 1; continue }
                guard MailSearchBox.admitServerHit(m, query: q, store: store, mailbox: mb, folderId: r.scopedFolder, labelName: r.labelName),
                      seen.insert(m.id).inserted else { continue }
                out.append(store.persistable(m))
            }
        }
        return (out, dropped)
    }
}

// MARK: - Highlight

public enum SearchHighlight {
    /// Folded terms to mark: free words (their alternatives' typed form), phrase words and `subject:` words.
    public static func terms(_ raw: String) -> [String] {
        let q = SearchQuery.parse(raw)
        var out: [String] = []
        for t in BlindIndex.tokenize(q.words.joined(separator: " ")) + q.phrases.flatMap({ $0.split(separator: " ").map(String.init) }) + q.subjectWords
        where !out.contains(t) && !SearchLexicon.stopwords.contains(t) { out.append(t) }
        return out
    }

    /// Ranges of words in `text` that start with one of `terms` (case / diacritic insensitive, like the index).
    public static func ranges(in text: String, terms: [String]) -> [Range<String.Index>] {
        guard !terms.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var start: String.Index?
        func close(_ end: String.Index) {
            guard let s = start else { return }
            start = nil
            let word = BlindIndex.tokenize(String(text[s..<end])).first ?? ""
            if word.count >= 2, terms.contains(where: { word.hasPrefix($0) }) {
                out.append(s..<end)
            }
        }
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isLetter || text[i].isNumber { if start == nil { start = i } } else { close(i) }
            i = text.index(after: i)
        }
        close(text.endIndex)
        return out
    }
}

// MARK: - Suggestions

public struct SearchSuggestion: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case recent, person, `operator` }
    public var kind: Kind
    public var title: String
    public var detail: String
    /// The whole search text after accepting this suggestion.
    public var completion: String
    public var id: String { kind.rawValue + "|" + completion }
}

public enum SearchSuggest {
    public static let operators: [(op: String, help: String)] = [
        ("from:", "Sender"), ("to:", "Recipient"), ("subject:", "Word in the subject"), ("has:attachment", "With attachments"),
        ("is:unread", "Unread"), ("is:read", "Read"), ("after:", "After a date (2026-01-31 or 7d)"),
        ("before:", "Before a date"), ("older_than:", "Older than (e.g. 1y)"), ("newer_than:", "Newer than (e.g. 2w)"),
        ("label:", "Sensitivity label"), ("category:", "Outlook category"), ("in:", "Folder"),
    ]

    /// Suggestions for the text being typed: recent searches (matching the whole text), operators for the current
    /// token, people (as `from:`) for a bare token or a `from:` / `to:` value.
    public static func items(for text: String, recent: [String], people: [(name: String, address: String)], limit: Int = 8) -> [SearchSuggestion] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var out: [SearchSuggestion] = []
        let low = trimmed.lowercased()
        for r in recent where r.lowercased() != low && (low.isEmpty || r.lowercased().hasPrefix(low) || r.lowercased().contains(" " + low)) {
            out.append(SearchSuggestion(kind: .recent, title: r, detail: "Recent", completion: r))
            if out.count == 4 { break }
        }
        guard !trimmed.isEmpty, !text.hasSuffix(" ") else { return Array(out.prefix(limit)) }
        let head = text.range(of: " ", options: .backwards).map { String(text[...$0.lowerBound]) } ?? ""
        let token = String(text.dropFirst(head.count))
        let tlow = token.lowercased()
        if let c = tlow.firstIndex(of: ":") {
            let op = String(tlow[..<c]), v = String(tlow[tlow.index(after: c)...])
            if ["from", "to", "cc"].contains(op), v.count >= 1 {
                for p in matchPeople(v, people) {
                    out.append(SearchSuggestion(kind: .person, title: p.name, detail: p.address, completion: head + op + ":" + p.address + " "))
                }
            }
        } else {
            for o in operators where o.op.hasPrefix(tlow) && o.op != tlow {
                out.append(SearchSuggestion(kind: .operator, title: o.op, detail: o.help,
                                            completion: head + o.op + (o.op.hasSuffix(":") ? "" : " ")))
            }
            if tlow.count >= 2 {
                for p in matchPeople(tlow, people) {
                    out.append(SearchSuggestion(kind: .person, title: p.name, detail: p.address, completion: head + "from:" + p.address + " "))
                }
            }
        }
        var seen = Set<String>()
        return Array(out.filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    static func matchPeople(_ v: String, _ people: [(name: String, address: String)], max: Int = 4) -> [(name: String, address: String)] {
        let f = BlindIndex.tokenize(v).first ?? v
        var out: [(name: String, address: String)] = []
        for p in people {
            let words = BlindIndex.tokenize(p.name) + BlindIndex.tokenize(p.address)
            if p.address.lowercased().hasPrefix(v) || words.contains(where: { $0.hasPrefix(f) }) { out.append(p) }
            if out.count == max { break }
        }
        return out
    }

    /// ↓ / ↑ over the list: nil = nothing highlighted (↩ then submits the search).
    public static func move(_ index: Int?, by d: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let i = index else { return d > 0 ? 0 : nil }
        let n = i + d
        return n < 0 ? nil : min(count - 1, n)
    }
}
