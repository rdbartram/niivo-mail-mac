import Foundation
import CalendarCore
import MIPBridgeABI

// Label policy (Policy SDK) and protected-message attachments over the bridge's ABI-1 additions. Both are optional
// symbols: an older bridge (or none) means `.graphFallback` policy and "attachments unavailable". See docs/MIP.md.

/// One attachment of a decrypted message.rpmsg. Bytes live in memory only (never a file, never QuickLook).
public struct ProtectedAttachment: Sendable, Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let contentId: String?
    public let data: Data
    public init(id: Int, name: String, contentId: String?, data: Data) {
        self.id = id; self.name = name; self.contentId = contentId; self.data = data
    }

    public enum Preview: Sendable, Equatable { case pdf, image, text, none }
    /// What can be shown straight from `Data` (PDFKit / NSImage / text). Everything else: name + size only.
    public var preview: Preview {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "bmp": return .image
        case "txt", "csv", "log", "md": return .text
        default: return .none
        }
    }
    /// A protected file inside the protected message (container option Top leaves it encrypted).
    public var isItselfProtected: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.hasPrefix("p") && ["ppdf", "ptxt", "pjpg", "ppng", "pfile"].contains(ext) || ext == "rpmsg"
    }
}

public struct ProtectedAttachments: Sendable, Equatable {
    public var items: [ProtectedAttachment]
    public var rights: UsageRights
}

/// What the licence lets the user do with a decrypted attachment. VIEW → in-memory preview only; saving, dragging
/// out, opening in another app or printing need EXPORT or EXTRACT (OWNER implies both)
/// (learn.microsoft.com/information-protection/develop/concept-accesscheck#scenarios).
public enum ProtectedAttachmentGate {
    public struct Allowed: Sendable, Equatable { public var preview: Bool; public var save: Bool; public var print: Bool }
    public static func allowed(_ rights: UsageRights) -> Allowed {
        let r = rights.normalized
        let view = r.contains(.view)
        return Allowed(preview: view, save: view && (r.contains(.export) || r.contains(.extract)),
                       print: view && r.contains(.print))
    }
}

extension ProtectedContentService {
    /// Label policy for `userEmail` (mail/meeting default, mandatory, justification). Throws `bridgeUnavailable`
    /// when the bridge or its policy symbols are missing — the caller then uses `.graphFallback`.
    public func loadLabelPolicy(userEmail: String, tokens provider: @escaping MIPTokenProvider) async throws
        -> LabelPolicySettings {
        let lib = try Self.library()
        guard let fns = lib.policy else { throw MIPBridgeError.bridgeUnavailable("policy-symbols") }
        return try await onQueue {
            try self.withContext(lib, userEmail, provider) {
                var p = nmb_policy()
                let rc = withUnsafeMutablePointer(to: &p) { fns.load(self.ctx, self.configuration.timeoutSeconds, $0) }
                defer { withUnsafeMutablePointer(to: &p) { fns.free($0) } }
                guard rc == 0 else { throw MIPBridgeError.from(code: rc, stage: p.stage) }
                func str(_ c: UnsafeMutablePointer<CChar>?) -> String { c.map { String(cString: $0) } ?? "" }
                return LabelPolicySettings(defaultLabelId: str(p.default_mail_label), mandatory: p.mail_mandatory != 0,
                                           justificationRequired: p.justification_required != 0,
                                           protection: LabelPolicySettings.parseProtection(str(p.label_protection)),
                                           tenantId: str(p.tenant_id).isEmpty ? nil : str(p.tenant_id).lowercased(),
                                           source: .mipPolicy)
            }
        }
    }

    /// PolicyHandler::ComputeActions (+ NotifyCommittedActions when `commit`) for one outgoing item.
    /// The justification text goes to the SDK only; it's never logged.
    public func planLabel(userEmail: String, labelId: String?, existingHeader: String?, privileged: Bool,
                          justification: String?, contentId: String, commit: Bool,
                          tokens provider: @escaping MIPTokenProvider) async throws -> LabelPlan {
        let lib = try Self.library()
        guard let fns = lib.policy else { throw MIPBridgeError.bridgeUnavailable("policy-symbols") }
        let existing = existingHeader.map(LabelMetadata.lines(fromHeader:)) ?? ""
        return try await onQueue {
            try self.withContext(lib, userEmail, provider) {
                var p = nmb_label_plan()
                let rc = (labelId ?? "").withCString { lid in
                    existing.withCString { ex in
                        (justification ?? "").withCString { j in
                            contentId.withCString { cid in
                                withUnsafeMutablePointer(to: &p) {
                                    fns.compute(self.ctx, lid, ex, privileged ? 1 : 0, j, cid, commit ? 1 : 0,
                                                self.configuration.timeoutSeconds, $0)
                                }
                            }
                        }
                    }
                }
                defer { withUnsafeMutablePointer(to: &p) { fns.planFree($0) } }
                guard rc == 0 else { throw MIPBridgeError.from(code: rc, stage: p.stage) }
                let add = p.metadata_add.map { String(cString: $0) } ?? ""
                return LabelPlan(metadata: .parse(lines: add), needsJustification: p.needs_justification != 0,
                                 appliesProtection: p.applies_protection != 0, committed: p.committed != 0)
            }
        }
    }

    /// Second pass over a message.rpmsg for its attachments (bytes in memory, zeroed by the bridge on free).
    public func decryptAttachments(rpmsg: Data, userEmail: String, tokens provider: @escaping MIPTokenProvider)
        async throws -> ProtectedAttachments {
        let lib = try Self.library()
        guard let fns = lib.attachments else { throw MIPBridgeError.bridgeUnavailable("attachment-symbols") }
        return try await onQueue {
            try self.withContext(lib, userEmail, provider) {
                var a = nmb_attachments()
                let rc: Int32 = rpmsg.withUnsafeBytes { buf in
                    withUnsafeMutablePointer(to: &a) {
                        fns.inspect(self.ctx, buf.bindMemory(to: UInt8.self).baseAddress, buf.count,
                                    self.configuration.timeoutSeconds, $0)
                    }
                }
                defer { withUnsafeMutablePointer(to: &a) { fns.free($0) } }
                if self.configuration.cache.mode == .inMemory, let d = self.stateDir { try NoDiskPlaintextGuard.enforce(d) }
                guard rc == 0 else { throw MIPBridgeError.from(code: rc, stage: a.stage) }
                var items: [ProtectedAttachment] = []
                for i in 0..<a.count {
                    let s = a.items[i]
                    let data = s.data.map { Data(bytes: $0, count: s.len) } ?? Data()
                    let cid = s.content_id.map { String(cString: $0) }
                    items.append(ProtectedAttachment(id: i, name: s.name.map { String(cString: $0) } ?? "attachment",
                                                     contentId: cid?.isEmpty == true ? nil : cid, data: data))
                }
                let list = a.rights.map { String(cString: $0) }?.split(separator: ",").map(String.init) ?? []
                let rights: UsageRights = a.rights_source == Int32(NMB_RIGHTS_PROTECTION_HANDLER)
                    ? UsageRights.fromLicence(list) : .viewOnly
                return ProtectedAttachments(items: items, rights: rights)
            }
        }
    }

    /// Optional symbols present? (no network)
    public static var supportsLabelPolicy: Bool { (try? library())?.policy != nil }
    public static var supportsAttachments: Bool { (try? library())?.attachments != nil }

    // MARK: plumbing

    static func library() throws -> MIPBridgeLibrary {
        switch MIPBridgeLibrary.load() { case .success(let l): return l; case .failure(let e): throw e }
    }

    func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async { do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) } }
        }
    }

    /// Queue-confined: token provider set for the call, context (re)opened for this user.
    func withContext<T>(_ lib: MIPBridgeLibrary, _ user: String, _ provider: @escaping MIPTokenProvider,
                        _ body: () throws -> T) throws -> T {
        tokens.set(provider)
        defer { tokens.set(nil) }
        if ctx == nil || ctxUser != user.lowercased() { try openContext(lib, user) }
        let r = try body()
        // The Policy SDK shares the state dir: anything non-empty there fails closed like a decrypt would.
        if configuration.cache.mode == .inMemory, let d = stateDir { try NoDiskPlaintextGuard.enforce(d) }
        return r
    }
}

/// `LabelPolicyProvider` over the bridge.
public struct MIPLabelPolicyProvider: LabelPolicyProvider {
    public let service: ProtectedContentService
    public let userEmail: String
    public let tokens: MIPTokenProvider
    public init(service: ProtectedContentService, userEmail: String, tokens: @escaping MIPTokenProvider) {
        self.service = service; self.userEmail = userEmail; self.tokens = tokens
    }
    public func loadPolicy() async throws -> LabelPolicySettings {
        try await service.loadLabelPolicy(userEmail: userEmail, tokens: tokens)
    }
    public func plan(labelId: String?, existingHeader: String?, privileged: Bool, justification: String?,
                     contentId: String, commit: Bool) async throws -> LabelPlan {
        try await service.planLabel(userEmail: userEmail, labelId: labelId, existingHeader: existingHeader,
                                    privileged: privileged, justification: justification, contentId: contentId,
                                    commit: commit, tokens: tokens)
    }
}


extension RPMSGFetcher {
    /// Lists the item's attachments (names + content types only) and says whether one is an rpmsg. No bytes fetched.
    public func listsRPMSG(id: String, mailbox: String = "me", kind: Kind = .event) async throws -> Bool {
        let root = mailbox == "me" ? "me" : "users/\(mailbox)"
        var c = URLComponents(url: base.appending(path: "\(root)/\(kind.rawValue)/\(id)/attachments"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "$select", value: "id,name,contentType")]
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(try await graphToken())", forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let s: URLSession = session === URLSession.shared ? Self.ephemeral : session
        let (d, r) = try await s.data(for: req)
        let status = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FetchError.http(status, step: "attachments") }
        struct Att: Decodable { var name: String?; var contentType: String? }
        struct Page: Decodable { var value: [Att] }
        let page = try JSONDecoder().decode(Page.self, from: d)
        return page.value.contains { RPMSG.isRPMSGAttachment(name: $0.name, contentType: $0.contentType) }
    }
}
