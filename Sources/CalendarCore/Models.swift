import Foundation

/// How the signed-in user came to see a calendar.
public enum CalendarAccess: String, Codable, Sendable, CaseIterable {
    case own        // in the user's mailbox
    case shared     // another user's calendar shared with the user (read or write)
    case delegated  // user is a delegate on another mailbox (can act on owner's behalf)
}

public struct CalendarInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var ownerName: String
    public var ownerAddress: String
    /// Graph path prefix used for this calendar, e.g. `/me` or `/users/{upn}`.
    public var mailboxPath: String
    public var access: CalendarAccess
    public var canEdit: Bool
    public var hexColor: String?
    public var isDefault: Bool

    public init(id: String, name: String, ownerName: String, ownerAddress: String, mailboxPath: String,
                access: CalendarAccess, canEdit: Bool, hexColor: String?, isDefault: Bool = false) {
        self.id = id; self.name = name; self.ownerName = ownerName; self.ownerAddress = ownerAddress
        self.mailboxPath = mailboxPath; self.access = access; self.canEdit = canEdit
        self.hexColor = hexColor; self.isDefault = isDefault
    }

    /// A Microsoft 365 group calendar (`/groups/{id}`), added from the sidebar. Read and written with the group token.
    public var isGroup: Bool { mailboxPath.hasPrefix("/groups/") }
    /// The group id for a group calendar.
    public var groupId: String? { isGroup ? String(mailboxPath.dropFirst("/groups/".count)) : nil }
}

/// Outlook's legacy per-item sensitivity flag. NOT a Purview label, but must still be honoured.
public enum LegacySensitivity: String, Codable, Sendable {
    case normal, personal, `private`, confidential
}

public enum ShowAs: String, Codable, Sendable {
    case free, tentative, busy, oof, workingElsewhere, unknown
}

public struct Attendee: Codable, Sendable, Hashable {
    public var name: String
    public var address: String
    public var response: String
    /// Graph attendee type: required / optional / resource (rooms, equipment). nil = required (older cache, fixtures).
    public var type: String?
    public init(name: String, address: String, response: String, type: String? = nil) {
        self.name = name; self.address = address; self.response = response; self.type = type
    }
    public var isResource: Bool { type == "resource" }
}

public struct CalendarEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var calendarId: String
    public var subject: String
    public var start: Date          // always UTC instant
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var organizer: String?
    public var attendees: [Attendee]
    public var bodyPreview: String?
    public var showAs: ShowAs
    public var legacySensitivity: LegacySensitivity
    /// Purview sensitivity label GUID, if the item carries one (read from MIP metadata).
    public var labelId: String?
    public var changeKey: String?
    public var isCancelled: Bool
    public var onlineMeetingURL: URL?
    public var webLink: URL?
    /// True while a local edit has not been acknowledged by Exchange.
    public var pendingSync: Bool
    /// Graph `isOrganizer`. nil = unknown (older cache, fixtures): callers infer from attendees/organiser.
    public var isOrganizer: Bool?
    /// Set on occurrences/exceptions of a recurring series (Graph `seriesMasterId`).
    public var seriesMasterId: String?
    /// Outlook categories (names; colours come from the user's master category list). nil = none / older cache.
    public var categories: [String]?
    /// The calendar owner's own response (Graph `responseStatus.response`): none, organizer, accepted,
    /// tentativelyAccepted, declined, notResponded. nil = unknown.
    public var myResponse: String?
    /// Graph `allowNewTimeProposals`. nil = unknown (then "Propose new time" is offered and Exchange decides).
    public var allowNewTimeProposals: Bool?

    public init(id: String, calendarId: String, subject: String, start: Date, end: Date, isAllDay: Bool = false,
                location: String? = nil, organizer: String? = nil, attendees: [Attendee] = [],
                bodyPreview: String? = nil, showAs: ShowAs = .busy, legacySensitivity: LegacySensitivity = .normal,
                labelId: String? = nil, changeKey: String? = nil, isCancelled: Bool = false,
                onlineMeetingURL: URL? = nil, webLink: URL? = nil, pendingSync: Bool = false, isOrganizer: Bool? = nil,
                seriesMasterId: String? = nil, categories: [String]? = nil, myResponse: String? = nil,
                allowNewTimeProposals: Bool? = nil) {
        self.categories = categories; self.myResponse = myResponse; self.allowNewTimeProposals = allowNewTimeProposals
        self.id = id; self.calendarId = calendarId; self.subject = subject; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.location = location; self.organizer = organizer; self.attendees = attendees
        self.bodyPreview = bodyPreview; self.showAs = showAs; self.legacySensitivity = legacySensitivity
        self.labelId = labelId; self.changeKey = changeKey; self.isCancelled = isCancelled
        self.onlineMeetingURL = onlineMeetingURL; self.webLink = webLink; self.pendingSync = pendingSync
        self.isOrganizer = isOrganizer; self.seriesMasterId = seriesMasterId
    }
}

/// A Purview sensitivity label definition as published to the user.
public struct SensitivityLabel: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var tooltip: String?
    public var hexColor: String?
    /// Higher = more sensitive. Fed from Graph `sensitivity` ("lower is less sensitive"), which matches the Purview
    /// portal order number: 0 at the top of the list (least sensitive), the highest number at the bottom (most
    /// restrictive). https://learn.microsoft.com/purview/sensitivity-labels#label-priority-order-matters
    /// Graph's separate `priority` property is NOT read: its doc wording ("lower numbers indicate higher priority")
    /// reads as the opposite direction and the documented list response doesn't return it.
    public var priority: Int
    public var isActive: Bool
    /// Label applies encryption (RMS). Content we cannot decrypt without the Protection SDK.
    public var hasProtection: Bool
    public var headerText: String?
    public var footerText: String?
    public var watermarkText: String?
    /// Parent label (sub-label of a Purview parent label / label group). nil = top-level label.
    public var parentId: String?
    /// Graph `isAppliable`: false for a parent that has sub-labels (it can't be applied by itself). nil = unknown.
    public var isAppliable: Bool?
    /// Position in the Graph response; tie-break for labels of equal `priority` (sub-labels share their parent's).
    /// Optional so label payloads cached before this field existed still decode.
    public var displayOrder: Int?
    /// The signed-in user's usage rights under this label (Graph `sensitivityLabel/rights`, fetched for encrypted
    /// labels only). nil = unknown: an encrypted label then fails closed to VIEW only (see `CachedLabelPolicyEngine`).
    /// Meaningless for unencrypted labels, which impose no usage restrictions.
    public var rights: UsageRights?

    public init(id: String, name: String, tooltip: String? = nil, hexColor: String? = nil, priority: Int,
                isActive: Bool = true, hasProtection: Bool = false, headerText: String? = nil,
                footerText: String? = nil, watermarkText: String? = nil, parentId: String? = nil,
                rights: UsageRights? = nil, isAppliable: Bool? = nil, displayOrder: Int? = nil) {
        self.id = id; self.name = name; self.tooltip = tooltip; self.hexColor = hexColor; self.priority = priority
        self.isAppliable = isAppliable; self.displayOrder = displayOrder
        self.isActive = isActive; self.hasProtection = hasProtection; self.headerText = headerText
        self.footerText = footerText; self.watermarkText = watermarkText; self.parentId = parentId
        self.rights = rights
    }
}
