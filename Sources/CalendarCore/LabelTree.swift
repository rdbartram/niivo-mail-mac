import Foundation

// MARK: - Purview label hierarchy

extension SensitivityLabel {
    /// Microsoft order: least sensitive first (top of the Purview list), most sensitive last. Equal priorities
    /// (a parent and its sub-labels) fall back to the Graph response position, then a parent before its children,
    /// then the name, so the order is deterministic.
    public static func microsoftOrder(_ a: SensitivityLabel, _ b: SensitivityLabel) -> Bool {
        if a.priority != b.priority { return a.priority < b.priority }
        let ao = a.displayOrder ?? Int.max, bo = b.displayOrder ?? Int.max
        if ao != bo { return ao < bo }
        if (a.parentId == nil) != (b.parentId == nil) { return a.parentId == nil }
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }
}

/// The published labels as Outlook shows them: top-level labels in priority order; a parent label that has
/// sub-labels is a group header (not selectable) with its sub-labels under it.
///
/// A label is a header when it has sub-labels in the set or Graph says `isAppliable == false`. That rule is
/// structural on purpose: Purview's modern scheme replaces parent labels with label groups, whose Graph shape is
/// unverified, but a group is either referenced as a parent or reported as not appliable.
///
/// Sub-labels share their parent's priority for downgrade purposes ("sublabels for the same parent label are all
/// considered to have the same priority", https://learn.microsoft.com/purview/sensitivity-labels-teams-groups-sites),
/// so `floorRank` compares on the parent's rank.
public struct LabelTree: Sendable {
    public struct Node: Sendable, Identifiable {
        public var label: SensitivityLabel
        /// Sub-labels in Microsoft order. Empty for a plain label.
        public var children: [SensitivityLabel]
        public var isHeader: Bool
        public var id: String { label.id }
    }

    public let nodes: [Node]
    private let byId: [String: SensitivityLabel]
    private let headerIds: Set<String>

    /// `labels` may include inactive entries; inactive sub-labels are dropped, an inactive parent is kept as a header
    /// while it still has active sub-labels (Graph reports parents as `isActive: false`).
    public init(_ labels: [SensitivityLabel]) {
        var all: [String: SensitivityLabel] = [:]
        for l in labels where all[l.id.lowercased()] == nil { all[l.id.lowercased()] = l }
        var kids: [String: [SensitivityLabel]] = [:]
        for l in all.values where l.isActive {
            if let p = l.parentId?.lowercased(), all[p] != nil, p != l.id.lowercased() { kids[p, default: []].append(l) }
        }
        var nodes: [Node] = []
        var kept: [String: SensitivityLabel] = [:]
        var headers = Set<String>()
        for l in all.values {
            let key = l.id.lowercased()
            if let p = l.parentId?.lowercased(), all[p] != nil, p != key { continue }   // listed under its parent
            let children = (kids[key] ?? []).sorted(by: SensitivityLabel.microsoftOrder)
            let header = !children.isEmpty || l.isAppliable == false
            guard l.isActive || !children.isEmpty else { continue }
            if header && children.isEmpty && !l.isActive { continue }
            nodes.append(Node(label: l, children: children, isHeader: header))
            kept[key] = l
            if header { headers.insert(key) }
            for c in children { kept[c.id.lowercased()] = c }
        }
        self.nodes = nodes.sorted { SensitivityLabel.microsoftOrder($0.label, $1.label) }
        self.byId = kept
        self.headerIds = headers
    }

    /// Every label in display order: header, then its sub-labels.
    public var flattened: [SensitivityLabel] { nodes.flatMap { [$0.label] + $0.children } }
    /// Labels that can be applied, in display order (headers excluded).
    public var appliable: [SensitivityLabel] { flattened.filter { !headerIds.contains($0.id.lowercased()) } }

    public func label(_ id: String?) -> SensitivityLabel? {
        guard let id, !id.isEmpty else { return nil }
        return byId[id.lowercased()]
    }
    public func parent(of id: String?) -> SensitivityLabel? {
        guard let l = label(id), let p = l.parentId else { return nil }
        return byId[p.lowercased()]
    }
    public func isHeader(_ id: String?) -> Bool { id.map { headerIds.contains($0.lowercased()) } ?? false }
    /// Known to the tree and not a group header.
    public func isSelectable(_ id: String?) -> Bool { label(id) != nil && !isHeader(id) }

    /// "Parent › Child" for a sub-label, the name otherwise. nil when the id isn't known.
    public func path(_ id: String?) -> String? {
        guard let l = label(id) else { return nil }
        if let p = parent(of: l.id) { return "\(p.name) › \(l.name)" }
        return l.name
    }

    /// The rank a label is compared on for "never downgrade": the parent's priority for a sub-label, its own
    /// otherwise. Higher = more sensitive. nil = unknown to the published policy (callers fail closed).
    public func floorRank(_ id: String?) -> Int? {
        guard let l = label(id) else { return nil }
        return parent(of: l.id)?.priority ?? l.priority
    }

    /// May `id` be chosen when the floor is `floorId`? Unknown floor → everything known is allowed.
    public func meetsFloor(_ id: String?, floor floorId: String?) -> Bool {
        guard let floor = floorRank(floorId) else { return true }
        guard let mine = floorRank(id) else { return false }
        return mine >= floor
    }
}

// MARK: - Graph mapping

/// Maps `GET /beta/me/security/informationProtection/sensitivityLabels` to `SensitivityLabel`s, without the
/// per-label rights call. https://learn.microsoft.com/graph/api/resources/security-sensitivitylabel?view=graph-rest-beta
///
/// * A parent often arrives only nested in its child (`parent` object, `isActive: false`, `isAppliable: false`);
///   it is synthesised as a header entry just before its first child.
/// * Sub-labels with no colour of their own take the parent's: Purview sub-labels inherit only the label colour.
/// * `displayOrder` is the response position. That Graph returns labels in Purview order is assumed, not documented.
public enum GraphLabelMapper {
    public static func decode(_ data: Data) throws -> [SensitivityLabel] {
        map(try JSONDecoder().decode(GPage<GLabel>.self, from: data).value)
    }

    static func map(_ raw: [GLabel]) -> [SensitivityLabel] {
        var out: [SensitivityLabel] = []
        var index: [String: Int] = [:]
        func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
        func add(_ l: SensitivityLabel) {
            if let i = index[l.id.lowercased()] {
                // Seen nested first: the top-level copy wins for fields it carries, keeps the earlier position.
                var merged = l; merged.displayOrder = out[i].displayOrder
                if merged.isAppliable == nil { merged.isAppliable = out[i].isAppliable }
                out[i] = merged
                return
            }
            index[l.id.lowercased()] = out.count
            var x = l; x.displayOrder = out.count
            out.append(x)
        }
        for l in raw {
            if let p = l.parent, index[p.id.lowercased()] == nil {
                add(SensitivityLabel(id: p.id, name: p.name ?? "", tooltip: nonEmpty(p.tooltip) ?? nonEmpty(p.description),
                                     hexColor: nonEmpty(p.color), priority: p.sensitivity ?? l.sensitivity ?? 0,
                                     isActive: p.isActive ?? false, hasProtection: p.hasProtection ?? false,
                                     isAppliable: p.isAppliable ?? false))
            }
            let parentColour = l.parent.flatMap { nonEmpty($0.color) }
            add(SensitivityLabel(id: l.id, name: l.name, tooltip: nonEmpty(l.tooltip) ?? nonEmpty(l.description),
                                 hexColor: nonEmpty(l.color) ?? parentColour, priority: l.sensitivity ?? 0,
                                 isActive: l.isActive ?? true, hasProtection: l.hasProtection ?? false,
                                 parentId: l.parent?.id, isAppliable: l.isAppliable))
        }
        return out
    }
}
