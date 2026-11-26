import Foundation

// Outlook master category list (`/me/outlook/masterCategories`, MailboxSettings.ReadWrite) and the beta
// "mentions me" id lookup. Side protocols (like `MailAttachmentFetching`) so `MailService` stays unchanged.

/// Outlook's 25 colour presets (`preset0`…`preset24`) plus `none`.
public struct CategoryColor: Codable, Sendable, Hashable, Identifiable {
    public var raw: String
    public var id: String { raw }
    public init(_ raw: String) { self.raw = raw }
    public static let none = CategoryColor("none")
    public static let presets: [CategoryColor] = (0...24).map { CategoryColor("preset\($0)") }

    /// Preset names follow Learn's `categoryColor` enum (preset0 Red … preset24 DarkCranberry). The RGB values are our
    /// approximations of Outlook's swatches (Learn lists names only) — UNVERIFIED against Outlook's exact colours.
    static let table: [(String, String)] = [
        ("Red", "E7484C"), ("Orange", "F28B35"), ("Brown", "A87F5C"), ("Yellow", "F5D44B"), ("Green", "4DB052"),
        ("Teal", "38B2A5"), ("Olive", "8C9A3C"), ("Blue", "3A7BD5"), ("Purple", "8A5CD1"), ("Cranberry", "C2335E"),
        ("Steel", "7D8B99"), ("Dark steel", "4E5A66"), ("Grey", "9E9E9E"), ("Dark grey", "5F5F5F"), ("Black", "2B2B2B"),
        ("Dark red", "9B1C1F"), ("Dark orange", "C4561A"), ("Dark brown", "6B4A2E"), ("Dark yellow", "C29B14"),
        ("Dark green", "2E7A32"), ("Dark teal", "1F7A70"), ("Dark olive", "5A6424"), ("Dark blue", "1F4E99"),
        ("Dark purple", "5A3794"), ("Dark cranberry", "86203F"),
    ]
    var index: Int? { raw.hasPrefix("preset") ? Int(raw.dropFirst(6)).flatMap { (0..<25).contains($0) ? $0 : nil } : nil }
    public var name: String { index.map { Self.table[$0].0 } ?? "None" }
    /// nil for `none` (callers fall back to their own neutral colour).
    public var hex: String? { index.map { Self.table[$0].1 } }
}

public struct OutlookCategory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var color: CategoryColor
    public init(id: String, displayName: String, color: CategoryColor) { self.id = id; self.displayName = displayName; self.color = color }
}

public enum MasterCategoryError: Error, Sendable, Equatable { case duplicateName, emptyName }

public protocol MasterCategoryService: Sendable {
    func masterCategories(mailbox: String) async throws -> [OutlookCategory]
    func createCategory(displayName: String, color: CategoryColor, mailbox: String) async throws -> OutlookCategory
    /// Graph allows only `color` to change; `displayName` is fixed once created.
    func setCategoryColor(id: String, color: CategoryColor, mailbox: String) async throws -> OutlookCategory
    func deleteCategory(id: String, mailbox: String) async throws
}

/// Ids of messages that @-mention the signed-in user. Beta-only (`mentionsPreview/isMentioned`), read-only.
public protocol MentionLookup: Sendable {
    func mentionedMessageIds(mailbox: String, top: Int) async throws -> [String]
}

public enum MasterCategories {
    /// Rename = create the new name (same colour), re-tag every cached message carrying the old name, delete the old.
    /// Returns the per-message categorise actions the caller queues through `MailSync.perform` (so they're undoable
    /// in the outbox, labelled mail included — categories are metadata, not content).
    public static func retag(_ messages: [MailMessage], from old: String, to new: String) -> [BulkStep] {
        messages.compactMap { m in
            guard m.categories.contains(where: { $0.caseInsensitiveCompare(old) == .orderedSame }) else { return nil }
            var cats = m.categories.map { $0.caseInsensitiveCompare(old) == .orderedSame ? new : $0 }
            var seen = Set<String>(); cats = cats.filter { seen.insert($0.lowercased()).inserted }
            return BulkStep(messageId: m.id, action: .categorize(cats))
        }
    }

    public static func validate(name: String, existing: [OutlookCategory]) throws -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw MasterCategoryError.emptyName }
        if existing.contains(where: { $0.displayName.caseInsensitiveCompare(t) == .orderedSame }) { throw MasterCategoryError.duplicateName }
        return t
    }

    /// Colour for a category name: the master list's preset when known, else nil.
    public static func hex(for name: String, in list: [OutlookCategory]) -> String? {
        list.first { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }?.color.hex
    }
}

extension MailSync {
    /// The service's master-category endpoint, if it has one (Graph, fixtures).
    nonisolated public var masterCategoryService: MasterCategoryService? { service as? MasterCategoryService }
    /// The service's beta mentions lookup, if it has one.
    nonisolated public var mentionLookup: MentionLookup? { service as? MentionLookup }
}

// MARK: - Graph

struct GMCategory: Decodable { var id: String; var displayName: String?; var color: String? }

extension GraphMailService: MasterCategoryService, MentionLookup {
    private func catPath(_ mailbox: String) -> String { "\(p(mailbox))/outlook/masterCategories" }
    private func model(_ c: GMCategory) -> OutlookCategory {
        OutlookCategory(id: c.id, displayName: c.displayName ?? "", color: CategoryColor(c.color ?? "none"))
    }

    public func masterCategories(mailbox: String) async throws -> [OutlookCategory] {
        let page: GMPage<GMCategory> = try await get(url(catPath(mailbox)), mailbox: mailbox)
        return page.value.map(model)
    }

    public func createCategory(displayName: String, color: CategoryColor, mailbox: String) async throws -> OutlookCategory {
        let c: GMCategory = try await send(url(catPath(mailbox)), method: "POST", mailbox: mailbox,
                                           json: ["displayName": displayName, "color": color.raw])
        return model(c)
    }

    public func setCategoryColor(id: String, color: CategoryColor, mailbox: String) async throws -> OutlookCategory {
        let c: GMCategory = try await send(url("\(catPath(mailbox))/\(id)"), method: "PATCH", mailbox: mailbox, json: ["color": color.raw])
        return model(c)
    }

    public func deleteCategory(id: String, mailbox: String) async throws {
        let _: GMEmpty = try await send(url("\(catPath(mailbox))/\(id)"), method: "DELETE", mailbox: mailbox, json: nil)
    }

    /// UNVERIFIED against a tenant: beta `$filter=mentionsPreview/isMentioned eq true` (Learn: "Supports filter").
    /// Only ids are selected — no content leaves Graph through this call.
    public func mentionedMessageIds(mailbox: String, top: Int = 100) async throws -> [String] {
        struct IdOnly: Decodable { var id: String }
        var c = URLComponents(string: "https://graph.microsoft.com/beta/\(p(mailbox))/messages")!
        c.queryItems = [URLQueryItem(name: "$filter", value: "mentionsPreview/isMentioned eq true"),
                        URLQueryItem(name: "$select", value: "id"), URLQueryItem(name: "$top", value: "\(min(max(top, 1), 1000))")]
        let page: GMPage<IdOnly> = try await get(c.url!, mailbox: mailbox)
        return page.value.map(\.id)
    }
}

// MARK: - Fixtures

extension FixtureMailService: MasterCategoryService, MentionLookup {
    public func masterCategories(mailbox: String) async throws -> [OutlookCategory] { FixtureCategories.shared.list() }
    public func createCategory(displayName: String, color: CategoryColor, mailbox: String) async throws -> OutlookCategory {
        try FixtureCategories.shared.create(displayName, color)
    }
    public func setCategoryColor(id: String, color: CategoryColor, mailbox: String) async throws -> OutlookCategory {
        try FixtureCategories.shared.recolour(id, color)
    }
    public func deleteCategory(id: String, mailbox: String) async throws { FixtureCategories.shared.delete(id) }
    public func mentionedMessageIds(mailbox: String, top: Int) async throws -> [String] { [] }
}

final class FixtureCategories: @unchecked Sendable {
    static let shared = FixtureCategories()
    private let lock = NSLock()
    private var items: [OutlookCategory] = [
        OutlookCategory(id: "cat-1", displayName: "Customer", color: CategoryColor("preset7")),
        OutlookCategory(id: "cat-2", displayName: "Finance", color: CategoryColor("preset4")),
        OutlookCategory(id: "cat-3", displayName: "Follow up", color: CategoryColor("preset1")),
        OutlookCategory(id: "cat-4", displayName: "Internal", color: CategoryColor("preset10")),
    ]
    private var next = 5
    func list() -> [OutlookCategory] { lock.withLock { items } }
    func create(_ name: String, _ color: CategoryColor) throws -> OutlookCategory {
        try lock.withLock {
            if items.contains(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) { throw MailServiceError.conflict }
            let c = OutlookCategory(id: "cat-\(next)", displayName: name, color: color); next += 1
            items.append(c); return c
        }
    }
    func recolour(_ id: String, _ color: CategoryColor) throws -> OutlookCategory {
        try lock.withLock {
            guard let i = items.firstIndex(where: { $0.id == id }) else { throw MailServiceError.notFound }
            items[i].color = color; return items[i]
        }
    }
    func delete(_ id: String) { lock.withLock { items.removeAll { $0.id == id } } }
}
