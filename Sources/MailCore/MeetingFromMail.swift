import Foundation
import CalendarCore

/// COMPOSE2 "Reply with Meeting": an event draft prefilled from a message (Outlook's Reply with Meeting).
/// Attendees = sender + To (required) and Cc (optional), own addresses removed, de-duplicated case-insensitively;
/// subject without RE:/FW: prefixes; notes point back at the message. Redacted (private) mail → no subject, no link.
public enum MeetingFromMail {
    public static func draft(from m: MailMessage, mine: Set<String>, calendarId: String, start: Date, minutes: Int = 30,
                             redact: Bool, online: Bool = true) -> EventDraft {
        var seen = Set(mine.map { $0.lowercased() })
        var people: [Attendee] = []
        func add(_ list: [EmailAddress], _ type: String) {
            for a in list where !a.address.isEmpty && seen.insert(a.address.lowercased()).inserted {
                people.append(Attendee(name: a.name, address: a.address, response: "none", type: type))
            }
        }
        add([m.from ?? m.sender].compactMap { $0 } + m.toRecipients, "required")
        add(m.ccRecipients, "optional")
        let subject = redact ? "" : stripPrefixes(m.subject)
        var notes = ""
        if !redact {
            notes = "About: \(m.subject)"
            if let link = m.webLink { notes += "\n\(link.absoluteString)" }
        }
        return EventDraft(calendarId: calendarId, subject: subject, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                          notes: notes, isOnlineMeeting: online, attendees: people)
    }

    /// "RE: FW: Aw: Plan" → "Plan" (EN/DE/FR/IT prefixes Outlook writes).
    public static func stripPrefixes(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        let re = try! NSRegularExpression(pattern: "^(re|fw|fwd|aw|wg|tr|r|i|rif)\\s*:\\s*", options: .caseInsensitive)
        while let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range, in: t) {
            t.removeSubrange(r)
        }
        return t
    }
}
