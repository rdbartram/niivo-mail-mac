import Foundation
import CalendarCore
import MIPBridgeABI

// MARK: - Public model

/// What the SDK asked a token for. Resources seen in practice (UNVERIFIED until the live probe):
/// `https://aadrm.com` (Azure Rights Management, `user_impersonation`) and
/// `https://syncservice.o365syncservice.com` (MIP Sync Service, `UnifiedPolicy.User.Read`, only for a policy engine).
/// https://learn.microsoft.com/information-protection/develop/concept-authentication-cpp
public struct MIPTokenRequest: Sendable, Hashable {
    public var authority: String
    public var resource: String
    public var scope: String
    public var claims: String

    public enum Service: String, Sendable { case rms, policySync, other }

    public var service: Service {
        let host = URL(string: resource)?.host?.lowercased() ?? resource.lowercased()
        if host == "aadrm.com" || host.hasSuffix(".aadrm.com") { return .rms }
        if host.hasSuffix("o365syncservice.com") { return .policySync }
        return .other
    }

    /// MSAL v2 scopes for this request: the SDK's scope if it gave one, else the delegated permission we consented
    /// (RMS `user_impersonation`, sync `UnifiedPolicy.User.Read`), else `<resource>/.default`.
    public var msalScopes: [String] {
        // Known services always map to the delegated permission we consent ("Grant access…" asks for exactly this),
        // whatever scope string the SDK suggests: otherwise silent + interactive ask for different scopes and loop.
        switch service {
        case .rms: return ["https://aadrm.com/user_impersonation"]
        case .policySync: return ["https://syncservice.o365syncservice.com/UnifiedPolicy.User.Read"]
        case .other:
            if !scope.isEmpty { return [scope] }
            let base = resource.hasSuffix("/") ? String(resource.dropLast()) : resource
            return [base + "/.default"]
        }
    }

    public init(authority: String, resource: String, scope: String = "", claims: String = "") {
        self.authority = authority; self.resource = resource; self.scope = scope; self.claims = claims
    }
}

/// Silent token acquisition for a MIP request. Called off the main thread; it may hop to the main actor (MSAL).
/// Throw to fail. A non-empty `claims` means a claims challenge, which a silent provider can't satisfy.
public typealias MIPTokenProvider = @Sendable (MIPTokenRequest) async throws -> String

public struct DecryptedContent: Sendable {
    /// Display HTML: the message's HTML body, or its text body escaped into a `<pre>` block. NOT yet sanitised —
    /// it must go through `HTMLSanitizer` / `MailHTML.document` like every other body. Never persist it on BYOD.
    public var html: String
    /// Licence rights for the signed-in user. Feeds `LicenceRightsStore` → `ItemRightsProvider`.
    public var rights: UsageRights
    public var rightsSource: RightsSource
    /// Licence owner (an address). Don't log it.
    public var owner: String?
    public var bodyByteCount: Int
    public var tokenCalls: Int

    public init(html: String, rights: UsageRights, rightsSource: RightsSource, owner: String? = nil,
                bodyByteCount: Int, tokenCalls: Int = 0) {
        self.html = html; self.rights = rights; self.rightsSource = rightsSource; self.owner = owner
        self.bodyByteCount = bodyByteCount; self.tokenCalls = tokenCalls
    }

    public enum RightsSource: String, Sendable {
        /// `ProtectionHandler::GetRights()` on the item's licence.
        case licence
        /// The SDK exposed no licence object; decryption succeeded, so VIEW is the only right we can prove.
        case viewImpliedByDecrypt
    }
}

/// Where MIP keeps its policy/licence cache. https://learn.microsoft.com/information-protection/develop/concept-cache-storage
public enum MIPCacheMode: Int32, Sendable {
    /// Nothing persisted; licence caching off. BYOD (and the default everywhere).
    case inMemory = 0
    /// SQLite encrypted with OS key APIs; licence caching on for offline reading. Managed Macs, only when policy
    /// allows. Learn: "A skilled adversary is able to decrypt the cache with minimal effort" — so never on BYOD.
    case onDiskEncrypted = 2
}

public struct MIPCacheConfig: Sendable, Equatable {
    public var mode: MIPCacheMode
    /// Policy: BYOD → always in memory. Managed → encrypted on disk only when the admin opted in.
    public static func resolve(isManagedDevice: Bool, policyAllowsEncryptedCache: Bool) -> MIPCacheConfig {
        MIPCacheConfig(mode: isManagedDevice && policyAllowsEncryptedCache ? .onDiskEncrypted : .inMemory)
    }
    public static let byod = MIPCacheConfig(mode: .inMemory)
}

// MARK: - No-disk-plaintext guard

public enum NoDiskPlaintextGuard {
    /// Regular files with content under `dir` (recursive). In `.inMemory` mode the SDK may create empty
    /// directories / zero-byte placeholders, but nothing with content.
    public static func nonEmptyFiles(in dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true, (v?.fileSize ?? 0) > 0 { out.append(u) }
        }
        return out
    }

    /// Enforce: any non-empty file is deleted and the operation fails closed.
    public static func enforce(_ dir: URL) throws {
        let hits = nonEmptyFiles(in: dir)
        guard !hits.isEmpty else { return }
        for h in hits { try? FileManager.default.removeItem(at: h) }
        throw MIPBridgeError.plaintextOnDisk(fileCount: hits.count)
    }

    /// A fresh private (0700) directory for one MIP context.
    public static func makeStateDirectory(base: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let d = base.appending(path: "niivo-mip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return d
    }
}

// MARK: - Body formatting

public enum ProtectedBodyFormat {
    public static func html(fromText text: String) -> String {
        var s = ""
        s.reserveCapacity(text.count + 32)
        for ch in text {
            switch ch {
            case "&": s += "&amp;"
            case "<": s += "&lt;"
            case ">": s += "&gt;"
            case "\"": s += "&quot;"
            default: s.append(ch)
            }
        }
        return "<pre style=\"white-space:pre-wrap;font-family:inherit\">\(s)</pre>"
    }
}

// MARK: - Service

/// Decrypts protected message bodies through the MIP File SDK (via the dlopen'ed bridge).
/// One MIP context per signed-in user, kept for the session; `shutdown()` on sign-out / wipe.
/// All SDK calls run on one private serial queue; never call `decrypt` expecting main-thread work to progress
/// inside the token provider unless the provider hops off (MSAL silent acquisition does).
public final class ProtectedContentService: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var clientId: String
        public var appName: String
        public var appVersion: String
        public var cache: MIPCacheConfig
        /// Protection-only engine (RMS token only). Set false to also load the label policy (needs the sync token).
        public var protectionOnly: Bool
        public var timeoutSeconds: Int32
        /// Persistent private directory for `.onDiskEncrypted`; ignored for `.inMemory` (a temp dir is used).
        public var persistentStateDirectory: URL?
        public init(clientId: String, appName: String = "niivo mail", appVersion: String = "0.1",
                    cache: MIPCacheConfig = .byod, protectionOnly: Bool = true, timeoutSeconds: Int32 = 45,
                    persistentStateDirectory: URL? = nil) {
            self.clientId = clientId; self.appName = appName; self.appVersion = appVersion; self.cache = cache
            self.protectionOnly = protectionOnly; self.timeoutSeconds = timeoutSeconds
            self.persistentStateDirectory = persistentStateDirectory
        }
    }

    public let configuration: Configuration
    let queue = DispatchQueue(label: "niivo.mip.bridge")   // internal: ProtectedPolicyService.swift
    var ctx: OpaquePointer?
    var ctxUser: String?
    var stateDir: URL?
    let tokens = TokenBox()

    public init(configuration: Configuration) { self.configuration = configuration }
    deinit { if let ctx, case .success(let lib) = MIPBridgeLibrary.load() { lib.destroy(ctx) }; cleanupStateDir() }

    /// Is the bridge dylib loadable (and ABI-compatible)? Doesn't touch the network.
    public static func bridgeStatus() -> Result<(path: String, sdkVersion: String), MIPBridgeError> {
        MIPBridgeLibrary.load().map { ($0.path, $0.sdkVersion) }
    }

    /// Decrypts one `message.rpmsg` payload for `userEmail` (the signed-in account's UPN).
    public func decrypt(rpmsg: Data, userEmail: String, tokens provider: @escaping MIPTokenProvider) async throws
        -> DecryptedContent {
        let lib: MIPBridgeLibrary
        switch MIPBridgeLibrary.load() {
        case .success(let l): lib = l
        case .failure(let e): throw e
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DecryptedContent, Error>) in
            queue.async {
                do { cont.resume(returning: try self.decryptOnQueue(lib, rpmsg, userEmail, provider)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Sign-out / wipe: shuts the MIP context down and removes its state directory.
    public func shutdown() {
        queue.sync {
            if let ctx, case .success(let lib) = MIPBridgeLibrary.load() { lib.destroy(ctx) }
            ctx = nil; ctxUser = nil
            cleanupStateDir()
        }
    }

    // MARK: queue-confined

    private func decryptOnQueue(_ lib: MIPBridgeLibrary, _ rpmsg: Data, _ user: String,
                                _ provider: @escaping MIPTokenProvider) throws -> DecryptedContent {
        tokens.set(provider)
        defer { tokens.set(nil) }
        if ctx == nil || ctxUser != user.lowercased() { try openContext(lib, user) }
        var r = nmb_result()
        let rc: Int32 = rpmsg.withUnsafeBytes { buf in
            withUnsafeMutablePointer(to: &r) { rp in
                lib.inspect(ctx, buf.bindMemory(to: UInt8.self).baseAddress, buf.count, configuration.timeoutSeconds, rp)
            }
        }
        defer { withUnsafeMutablePointer(to: &r) { lib.free($0) } }
        if configuration.cache.mode == .inMemory, let stateDir { try NoDiskPlaintextGuard.enforce(stateDir) }
        guard rc == 0 else { throw MIPBridgeError.from(code: rc, stage: r.stage) }

        let rightsList = r.rights.map { String(cString: $0) }?.split(separator: ",").map(String.init) ?? []
        let source: DecryptedContent.RightsSource = r.rights_source == Int32(NMB_RIGHTS_PROTECTION_HANDLER)
            ? .licence : .viewImpliedByDecrypt
        // Explicit set, never nil: an empty licence grants nothing (not "fall back to label rights").
        let rights: UsageRights = source == .licence ? UsageRights.fromLicence(rightsList) : .viewOnly
        let owner = r.owner.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        let bytes = r.body.map { UnsafeBufferPointer(start: $0, count: r.body_len) }
        let html: String
        if r.body_type == Int32(NMB_BODY_RTF) {
            html = RTFBody.html(from: bytes.map { Data($0) } ?? Data())   // compressed / HTML-encapsulated RTF, in memory
        } else {
            let text = bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
            html = r.body_type == Int32(NMB_BODY_HTML) ? text : ProtectedBodyFormat.html(fromText: text)
        }
        return DecryptedContent(html: html, rights: rights, rightsSource: source, owner: owner,
                                bodyByteCount: r.body_len, tokenCalls: Int(r.auth_calls))
    }

    func openContext(_ lib: MIPBridgeLibrary, _ user: String) throws {
        if let ctx { lib.destroy(ctx); self.ctx = nil }
        cleanupStateDir()
        let dir: URL
        if configuration.cache.mode == .onDiskEncrypted, let p = configuration.persistentStateDirectory {
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            dir = p
        } else {
            dir = try NoDiskPlaintextGuard.makeStateDirectory()
            stateDir = dir
        }
        var err: Int32 = 0, stage: Int32 = 0
        let user = user.lowercased()
        let created = configuration.clientId.withCString { cid in
            configuration.appName.withCString { an in
                configuration.appVersion.withCString { av in
                    dir.path.withCString { sp in
                        user.withCString { ue in
                            lib.create(cid, an, av, sp, ue, configuration.protectionOnly ? 1 : 0,
                                       configuration.cache.mode.rawValue, mipTokenTrampoline,
                                       Unmanaged.passUnretained(tokens).toOpaque(), configuration.timeoutSeconds,
                                       &err, &stage)
                        }
                    }
                }
            }
        }
        if configuration.cache.mode == .inMemory, let stateDir { try NoDiskPlaintextGuard.enforce(stateDir) }
        guard let created else { throw MIPBridgeError.from(code: err, stage: stage) }
        ctx = created
        ctxUser = user
    }

    private func cleanupStateDir() {
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        stateDir = nil
    }
}

// MARK: - Token trampoline (C callback → async provider)

/// Holds the current provider; the C callback reads it on an SDK thread.
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: MIPTokenProvider?
    func set(_ p: MIPTokenProvider?) { lock.lock(); provider = p; lock.unlock() }
    func get() -> MIPTokenProvider? { lock.lock(); defer { lock.unlock() }; return provider }
}

private final class TokenResult: @unchecked Sendable {
    var token: String?
}

/// Blocks the calling SDK thread (never the main thread: decrypt runs on our private queue and the SDK's own
/// threads) while a Task fetches the token. Returns 0 ok, 2 auth failure, 3 claims challenge.
let mipTokenTrampoline: nmb_token_cb = { user, authority, resource, scope, claims, out, cap in
    guard let user, let out, cap > 1 else { return 2 }
    let box = Unmanaged<TokenBox>.fromOpaque(user).takeUnretainedValue()
    let req = MIPTokenRequest(authority: authority.map { String(cString: $0) } ?? "",
                              resource: resource.map { String(cString: $0) } ?? "",
                              scope: scope.map { String(cString: $0) } ?? "",
                              claims: claims.map { String(cString: $0) } ?? "")
    if !req.claims.isEmpty { return 3 }
    guard let provider = box.get() else { return 2 }
    let result = TokenResult()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { result.token = try await provider(req) }
        catch {
            // Content-free: scopes asked for and the MSAL error domain/code only.
            let ns = error as NSError
            FileHandle.standardError.write(Data("[MIP] token failed scopes=\(req.msalScopes) sdkScope=\(req.scope.isEmpty ? "-" : req.scope) err=\(ns.domain)#\(ns.code)\n".utf8))
        }
        sem.signal()
    }
    if sem.wait(timeout: .now() + 60) == .timedOut { return 2 }
    guard let tok = result.token, !tok.isEmpty else { return 2 }
    let utf8 = Array(tok.utf8)
    guard utf8.count < cap else { return 2 }
    utf8.withUnsafeBufferPointer { src in
        out.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
            dst.update(from: src.baseAddress!, count: utf8.count)
            dst[utf8.count] = 0
        }
    }
    return 0
}
