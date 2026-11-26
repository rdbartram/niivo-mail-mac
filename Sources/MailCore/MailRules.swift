import Foundation

// Server-side inbox rules (Exchange `messageRule`) and automatic replies (`mailboxSettings.automaticRepliesSetting`).
// Shapes mirror Graph v1.0 messageRule / messageRulePredicates / messageRuleActions 1:1 (property names verified
// against learn.microsoft.com resource pages, 2026-11-19). Only the commonly used predicates are modelled.

public struct SizeRange: Codable, Sendable, Hashable {
    /// Kilobytes, as Graph `sizeRange`.
    public var minimumSize: Int
    public var maximumSize: Int
    public init(minimumSize: Int, maximumSize: Int) { self.minimumSize = minimumSize; self.maximumSize = maximumSize }
}

public struct RuleConditions: Codable, Sendable, Hashable {
    public var fromAddresses: [EmailAddress] = []
    public var sentToAddresses: [EmailAddress] = []
    public var subjectContains: [String] = []
    public var bodyContains: [String] = []
    public var senderContains: [String] = []
    public var headerContains: [String] = []
    public var importance: Importance?
    public var hasAttachments: Bool?
    public var sentToMe: Bool?
    public var sentOnlyToMe: Bool?
    public var sentCcMe: Bool?
    public var isMeetingRequest: Bool?
    public var withinSizeRange: SizeRange?
    public init(fromAddresses: [EmailAddress] = [], sentToAddresses: [EmailAddress] = [], subjectContains: [String] = [],
                bodyContains: [String] = [], senderContains: [String] = [], headerContains: [String] = [],
                importance: Importance? = nil, hasAttachments: Bool? = nil, sentToMe: Bool? = nil,
                sentOnlyToMe: Bool? = nil, sentCcMe: Bool? = nil, isMeetingRequest: Bool? = nil,
                withinSizeRange: SizeRange? = nil) {
        self.fromAddresses = fromAddresses; self.sentToAddresses = sentToAddresses; self.subjectContains = subjectContains
        self.bodyContains = bodyContains; self.senderContains = senderContains; self.headerContains = headerContains
        self.importance = importance; self.hasAttachments = hasAttachments; self.sentToMe = sentToMe
        self.sentOnlyToMe = sentOnlyToMe; self.sentCcMe = sentCcMe; self.isMeetingRequest = isMeetingRequest
        self.withinSizeRange = withinSizeRange
    }
}

public struct RuleActions: Codable, Sendable, Hashable {
    public var moveToFolder: String?
    public var copyToFolder: String?
    public var delete: Bool?
    /// Destructive: `MailSync.saveRule` refuses it unless `confirmPermanentDelete: true`.
    public var permanentDelete: Bool?
    public var markAsRead: Bool?
    public var markImportance: Importance?
    public var assignCategories: [String] = []
    public var forwardTo: [EmailAddress] = []
    public var forwardAsAttachmentTo: [EmailAddress] = []
    public var redirectTo: [EmailAddress] = []
    public var stopProcessingRules: Bool?
    public init(moveToFolder: String? = nil, copyToFolder: String? = nil, delete: Bool? = nil, permanentDelete: Bool? = nil,
                markAsRead: Bool? = nil, markImportance: Importance? = nil, assignCategories: [String] = [],
                forwardTo: [EmailAddress] = [], forwardAsAttachmentTo: [EmailAddress] = [], redirectTo: [EmailAddress] = [],
                stopProcessingRules: Bool? = nil) {
        self.moveToFolder = moveToFolder; self.copyToFolder = copyToFolder; self.delete = delete
        self.permanentDelete = permanentDelete; self.markAsRead = markAsRead; self.markImportance = markImportance
        self.assignCategories = assignCategories; self.forwardTo = forwardTo
        self.forwardAsAttachmentTo = forwardAsAttachmentTo; self.redirectTo = redirectTo
        self.stopProcessingRules = stopProcessingRules
    }
    /// Every address mail could leave the mailbox to.
    public var outboundRecipients: [EmailAddress] { forwardTo + forwardAsAttachmentTo + redirectTo }
}

public struct MailRule: Codable, Sendable, Hashable, Identifiable {
    /// nil until created on the server.
    public var id: String?
    public var displayName: String
    public var sequence: Int
    public var isEnabled: Bool
    public var conditions: RuleConditions
    public var actions: RuleActions
    public var exceptions: RuleConditions?
    public var hasError: Bool
    public var isReadOnly: Bool
    public init(id: String? = nil, displayName: String, sequence: Int = 1, isEnabled: Bool = true,
                conditions: RuleConditions = .init(), actions: RuleActions = .init(), exceptions: RuleConditions? = nil,
                hasError: Bool = false, isReadOnly: Bool = false) {
        self.id = id; self.displayName = displayName; self.sequence = sequence; self.isEnabled = isEnabled
        self.conditions = conditions; self.actions = actions; self.exceptions = exceptions
        self.hasError = hasError; self.isReadOnly = isReadOnly
    }

    /// One-click "Always move messages from <sender> to <folder>" draft (not yet saved).
    public static func suggested(from message: MailMessage, toFolderId folderId: String, folderName: String? = nil) -> MailRule? {
        guard let from = message.from, !from.address.isEmpty else { return nil }
        let where_ = folderName.map { " to \($0)" } ?? ""
        return MailRule(displayName: "Move messages from \(from.display)\(where_)", sequence: 1,
                        conditions: RuleConditions(fromAddresses: [EmailAddress(name: from.name, address: from.address)]),
                        actions: RuleActions(moveToFolder: folderId, stopProcessingRules: true))
    }
}

public enum RulePolicyError: Error, Sendable, Equatable {
    /// Forward/redirect to addresses outside `internalDomains` while `blockExternalForward` is on.
    case externalForwardBlocked([String])
    case permanentDeleteNotConfirmed
    case readOnly
}

/// Guard rails for rules: auto-forwarding outside the organisation is a classic exfiltration path.
public enum RulePolicy {
    /// Returns warnings; throws when an external forward is blocked.
    @discardableResult
    public static func validate(_ rule: MailRule, internalDomains: Set<String>, blockExternalForward: Bool = true) throws -> [String] {
        var warnings: [String] = []
        let internals = Set(internalDomains.map { $0.lowercased() })
        let external = rule.actions.outboundRecipients.map { $0.address.lowercased() }.filter { addr in
            let domain = addr.split(separator: "@").last.map(String.init) ?? ""
            return !internals.contains(domain) && !internals.contains { domain.hasSuffix("." + $0) }
        }
        if !external.isEmpty {
            if blockExternalForward { throw RulePolicyError.externalForwardBlocked(external) }
            warnings.append("Forwards mail outside the organisation (\(external.count) recipient(s))")
        }
        if rule.actions.permanentDelete == true { warnings.append("Permanently deletes matching mail") }
        if rule.actions.redirectTo.isEmpty == false { warnings.append("Redirects mail (original sender kept)") }
        if rule.conditions == RuleConditions() { warnings.append("No conditions: applies to every incoming message") }
        return warnings
    }
}

// MARK: - Automatic replies + regional settings

public struct AutomaticReplies: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case disabled, alwaysEnabled, scheduled }
    public enum Audience: String, Codable, Sendable { case none, contactsOnly, all }
    public var status: Status
    public var start: Date?
    public var end: Date?
    /// Time zone the schedule was expressed in (Graph `dateTimeTimeZone.timeZone`); dates are absolute instants.
    public var timeZone: String
    public var internalReplyHTML: String
    public var externalReplyHTML: String
    public var externalAudience: Audience
    public init(status: Status = .disabled, start: Date? = nil, end: Date? = nil, timeZone: String = "UTC",
                internalReplyHTML: String = "", externalReplyHTML: String = "", externalAudience: Audience = .none) {
        self.status = status; self.start = start; self.end = end; self.timeZone = timeZone
        self.internalReplyHTML = internalReplyHTML; self.externalReplyHTML = externalReplyHTML
        self.externalAudience = externalAudience
    }
    public func isActive(at now: Date = .now) -> Bool {
        switch status {
        case .disabled: return false
        case .alwaysEnabled: return true
        case .scheduled:
            guard let start, let end else { return false }
            return now >= start && now < end
        }
    }
}

public struct WorkingHours: Codable, Sendable, Hashable {
    public var daysOfWeek: [String]
    /// "08:30:00" local to `timeZone`.
    public var startTime: String
    public var endTime: String
    public var timeZone: String
    public init(daysOfWeek: [String], startTime: String, endTime: String, timeZone: String) {
        self.daysOfWeek = daysOfWeek; self.startTime = startTime; self.endTime = endTime; self.timeZone = timeZone
    }
}

/// `mailboxSettings.timeZone` + `workingHours` (calendar features use them too).
public struct MailboxRegionalSettings: Codable, Sendable, Hashable {
    public var timeZone: String?
    public var workingHours: WorkingHours?
    // A11Y-HOOK: `dateFormat` / `timeFormat` (.NET short date / short time patterns) and `language.locale` ("de-CH").
    public var dateFormat: String?
    public var timeFormat: String?
    public var locale: String?
    public init(timeZone: String? = nil, workingHours: WorkingHours? = nil,
                dateFormat: String? = nil, timeFormat: String? = nil, locale: String? = nil) {
        self.timeZone = timeZone; self.workingHours = workingHours
        self.dateFormat = dateFormat; self.timeFormat = timeFormat; self.locale = locale
    }
}
