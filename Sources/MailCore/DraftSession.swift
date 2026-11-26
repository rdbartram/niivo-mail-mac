import Foundation

// COMPOSE2: one server draft per composer (PATCH in place) and the quoted history carried byte-for-byte.

/// HTML around the user's region of a reply/forward draft: everything before it (`<html>…<body>`) and everything after
/// it (Exchange's quoted history + `</body></html>`). Never parsed into the rich-text model; sent back exactly.
public struct DraftCarry: Sendable, Hashable {
    public var prefix: String
    public var suffix: String
    public init(prefix: String, suffix: String) { self.prefix = prefix; self.suffix = suffix }

    /// The full body with `html` as the user's part.
    public func wrap(_ html: String) -> String { prefix + html + suffix }
    /// The history alone as a document (for the read-only view): `prefix + suffix`.
    public var historyDocument: String { prefix + suffix }
    /// Whether there's any quoted content (not just an empty `<html><body></body></html>` shell).
    public var hasHistory: Bool {
        !RichHTML.parse(suffix).doc.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Same document, history dropped (only the closing `</body></html>` kept): "reply without history".
    public var withoutHistory: DraftCarry {
        let closing = suffix.range(of: "</body>", options: [.caseInsensitive, .backwards]).map { String(suffix[$0.lowerBound...]) } ?? ""
        return DraftCarry(prefix: prefix, suffix: closing)
    }

    /// Shell from createReply / createReplyAll / createForward: the user's part goes at the top of `<body>`.
    public static func shell(_ quoted: String) -> DraftCarry {
        if let r = quoted.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return DraftCarry(prefix: String(quoted[..<r.upperBound]), suffix: String(quoted[r.upperBound...]))
        }
        return DraftCarry(prefix: "", suffix: quoted)
    }

    /// A saved draft body: (carry, the user's region). Our `niivo-compose` region first; without it (Exchange dropped
    /// the id — UNVERIFIED whether it ever does), Outlook's reply header (`divRplyFwdMsg`, `appendonsend`) or the
    /// `<hr>` right before it marks where the history starts. nil when no history is recognisable.
    public static func split(_ html: String) -> (carry: DraftCarry, editable: String)? {
        if html.range(of: "<div[^>]*\\bid\\s*=\\s*[\"']?(x_)?\(RichHTML.composeMarker)", options: [.regularExpression, .caseInsensitive]) != nil {
            let parts = RichHTML.split(html)
            if parts.editable != html { return (DraftCarry(prefix: parts.prefix, suffix: parts.suffix), parts.editable) }
        }
        let starts = ["<div[^>]*\\bid\\s*=\\s*[\"']?(x_)?appendonsend", "<div[^>]*\\bid\\s*=\\s*[\"']?(x_)?divRplyFwdMsg"]
        guard let body = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        for pattern in starts {
            guard var start = html.range(of: pattern, options: [.regularExpression, .caseInsensitive], range: body.upperBound..<html.endIndex)?.lowerBound
            else { continue }
            // Outlook puts an <hr> (often inside its own div) just before divRplyFwdMsg: it belongs to the history.
            let before = html[body.upperBound..<start]
            if let hr = before.range(of: "<hr[^>]*>\\s*(</div>\\s*)?$", options: [.regularExpression, .caseInsensitive]) {
                start = hr.lowerBound
                if let open = html[body.upperBound..<start].range(of: "<div[^>]*>\\s*$", options: [.regularExpression, .caseInsensitive]) {
                    start = open.lowerBound
                }
            }
            return (DraftCarry(prefix: String(html[..<body.upperBound]), suffix: String(html[start...])),
                    String(html[body.upperBound..<start]))
        }
        return nil
    }
}

/// The server refused the deferred-send property (before `/send` was called): nothing went out.
public struct DeferredSendRefused: Error, Sendable, Equatable { public var reason: String; public init(reason: String) { self.reason = reason } }

/// Services that know the quoted history of a reply/forward draft they created (Graph, fixtures). Display only.
public protocol DraftHistoryProviding: Sendable {
    /// `prefix + suffix` of the draft's carried HTML (a document), nil when unknown or not a reply/forward.
    func draftHistory(id: String) -> String?
}

/// One composer's server draft. The first save creates it (POST or createReply…), every later save PATCHes the same
/// id; a replacement id (the old draft vanished) deletes the old one. Lives in MailCore so the exact request sequence
/// is testable against the Graph stub (CoreSelfTest).
@MainActor
public final class DraftSession {
    public private(set) var draftId: String?
    /// The composer value the server has (without `existingId`).
    public private(set) var lastSaved: MailDraft?
    public private(set) var savedAt: Date?
    /// Reopened draft whose body hasn't loaded yet: saves are skipped (they would PATCH an empty body over it).
    public private(set) var loading: Bool

    public init(draftId: String? = nil, loading: Bool = false) { self.draftId = draftId; self.loading = loading }

    /// Reopened draft finished loading: `d` is what the server has, so closing it untouched writes nothing.
    public func markLoaded(_ d: MailDraft) { lastSaved = d; loading = false }

    /// Saves `d` (no request when unchanged). false = skipped (still loading).
    @discardableResult
    public func save(_ d: MailDraft, sync: MailSync) async throws -> Bool {
        if loading { return false }
        if draftId != nil, d == lastSaved { return true }
        var upd = d
        upd.existingId = draftId
        let saved = try await sync.saveDraft(upd)
        if let old = draftId, old != saved.id { try? await sync.perform(.delete, on: old) }
        draftId = saved.id; lastSaved = d; savedAt = .now
        return true
    }

    /// Saves if needed, then returns the draft id + mailbox to send from.
    public func prepareSend(_ d: MailDraft, sync: MailSync) async throws -> (id: String, mailbox: String) {
        try await save(d, sync: sync)
        guard let id = draftId else { throw MailServiceError.notFound }
        var withId = d; withId.existingId = id
        return (id, await sync.draftMailbox(for: withId))
    }

    /// Discard: the server draft is deleted.
    public func discard(sync: MailSync) async {
        if let id = draftId { try? await sync.perform(.delete, on: id) }
        draftId = nil; lastSaved = nil
    }
}
