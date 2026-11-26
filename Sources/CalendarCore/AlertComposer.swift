import Foundation

/// Builds reminder text from the content policy, never from the raw event alone. A system notification can
/// show on a locked screen, sit in Notification Centre and be mirrored to other devices, so anything private,
/// encrypted or carrying an unknown label gets generic text: no subject, location or attendees.
public enum AlertComposer {
    public struct Text: Equatable, Sendable {
        public var title: String
        public var body: String
        public var restricted: Bool
    }

    public static func isRestricted(_ p: ContentPolicy) -> Bool {
        if p.redactDetails || p.bodyIsProtected || p.preventScreenCapture { return true }
        if case .unknown = p.labelState { return true }
        return p.label?.hasProtection == true
    }

    /// - surface: `.system` (lock screen / Notification Centre) is strict; `.inApp` only hides private items,
    ///   because the same subject is already visible in the grid behind it.
    public enum Surface: Sendable { case system, inApp }

    public static func compose(subject: String, location: String?, provider: String?, ownerName: String?,
                               minutes: Int, policy p: ContentPolicy, surface: Surface) -> Text {
        let when = minutes <= 0 ? "now" : "in \(minutes) min"
        let whose = ownerName.map { "\($0)’s calendar" }
        let hide = surface == .system ? isRestricted(p) : p.redactDetails
        if hide {
            let kind = p.redactDetails ? "Private appointment" : "Confidential meeting"
            return Text(title: "\(kind) \(when)", body: [whose, "Open the calendar for details"].compactMap { $0 }.joined(separator: " · "),
                        restricted: true)
        }
        let start = minutes <= 0 ? "Starting now" : "Starts in \(minutes) min"
        return Text(title: subject, body: [start, provider ?? location, whose].compactMap { $0 }.joined(separator: " · "),
                    restricted: false)
    }
}
