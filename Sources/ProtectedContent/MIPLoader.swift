import Foundation
import Darwin
import MIPBridgeABI

/// Mirrors the result codes in native/mipbridge/niivo_mipbridge.h.
public enum MIPBridgeError: Error, Sendable, Equatable, CustomStringConvertible {
    case bridgeUnavailable(String)       // dylib missing / wrong ABI / symbol missing (no content)
    case badArgument
    case auth(stage: Int)
    case claimsChallenge(stage: Int)
    case noPermission
    case accessDenied
    case badInput(stage: Int)
    case network(stage: Int)
    case timeout(stage: Int)
    case notMessage
    case unsupportedBody
    case consent
    case internalError(stage: Int)
    /// The no-disk-plaintext guard found non-empty files in the in-memory state directory after an operation.
    case plaintextOnDisk(fileCount: Int)
    case disabled

    static func from(code: Int32, stage: Int32) -> MIPBridgeError {
        let s = Int(stage)
        switch code {
        case 1: return .badArgument
        case 2: return .auth(stage: s)
        case 3: return .claimsChallenge(stage: s)
        case 4: return .noPermission
        case 5: return .accessDenied
        case 6: return .badInput(stage: s)
        case 7: return .network(stage: s)
        case 8: return .timeout(stage: s)
        case 9: return .notMessage
        case 10: return .unsupportedBody
        case 11: return .consent
        default: return .internalError(stage: s)
        }
    }

    /// Short code, safe to log (no content, no addresses).
    public var description: String {
        switch self {
        case .bridgeUnavailable(let w): "bridge-unavailable(\(w))"
        case .badArgument: "bad-argument"
        case .auth(let s): "auth(stage \(s))"
        case .claimsChallenge(let s): "claims-challenge(stage \(s))"
        case .noPermission: "no-permission"
        case .accessDenied: "access-denied"
        case .badInput(let s): "bad-input(stage \(s))"
        case .network(let s): "network(stage \(s))"
        case .timeout(let s): "timeout(stage \(s))"
        case .notMessage: "not-msg-inspector"
        case .unsupportedBody: "unsupported-body(rtf)"
        case .consent: "consent-denied"
        case .internalError(let s): "internal(stage \(s))"
        case .plaintextOnDisk(let n): "plaintext-on-disk(\(n) files)"
        case .disabled: "disabled"
        }
    }
}


/// The dlopen'ed bridge. Loaded lazily and only when decryption is enabled, so the app never depends on the MIP SDK
/// being present (it is vendored, gitignored, and not part of the app bundle yet).
final class MIPBridgeLibrary: @unchecked Sendable {
    static let expectedABI = Int32(NMB_ABI_VERSION)
    static let fileName = "libniivo_mipbridge.dylib"

    typealias FnABI = @convention(c) () -> Int32
    typealias FnVersion = @convention(c) () -> UnsafePointer<CChar>?
    // Shapes mirror the declarations in MIPBridgeABI/include/niivo_mipbridge.h (resolved with dlsym, never linked).
    typealias FnCreate = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                         UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32,
                                         nmb_token_cb?, UnsafeMutableRawPointer?, Int32,
                                         UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> OpaquePointer?
    typealias FnInspect = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int, Int32,
                                          UnsafeMutablePointer<nmb_result>?) -> Int32
    typealias FnFree = @convention(c) (UnsafeMutablePointer<nmb_result>?) -> Void
    typealias FnDestroy = @convention(c) (OpaquePointer?) -> Void
    // Optional ABI-1 additions (nil on an older bridge → Graph fallback / no attachments).
    typealias FnPolicyLoad = @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<nmb_policy>?) -> Int32
    typealias FnPolicyFree = @convention(c) (UnsafeMutablePointer<nmb_policy>?) -> Void
    typealias FnLabelCompute = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32,
                                               UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32,
                                               UnsafeMutablePointer<nmb_label_plan>?) -> Int32
    typealias FnPlanFree = @convention(c) (UnsafeMutablePointer<nmb_label_plan>?) -> Void
    typealias FnAttachments = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int, Int32,
                                              UnsafeMutablePointer<nmb_attachments>?) -> Int32
    typealias FnAttachmentsFree = @convention(c) (UnsafeMutablePointer<nmb_attachments>?) -> Void
    struct PolicyFns { let load: FnPolicyLoad; let free: FnPolicyFree; let compute: FnLabelCompute; let planFree: FnPlanFree }
    struct AttachmentFns { let inspect: FnAttachments; let free: FnAttachmentsFree }

    let path: String
    let sdkVersion: String
    let create: FnCreate
    let inspect: FnInspect
    let free: FnFree
    let destroy: FnDestroy
    var policy: PolicyFns?
    var attachments: AttachmentFns?
    private let handle: UnsafeMutableRawPointer

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Result<MIPBridgeLibrary, MIPBridgeError>?

    /// Candidate locations, first hit wins:
    ///  1. `NIIVO_MIPBRIDGE` (absolute path to the dylib) — probe / dev override;
    ///  2. the app bundle's Frameworks directory (future bundling, see docs/MIP.md);
    ///  3. `vendor/mip/lib` of this source checkout (dev builds via `swift run`).
    static func candidates(sourceFile: String = #filePath) -> [String] {
        var c: [String] = []
        if let p = ProcessInfo.processInfo.environment["NIIVO_MIPBRIDGE"], !p.isEmpty { c.append(p) }
        if let fw = Bundle.main.privateFrameworksURL { c.append(fw.appending(path: fileName).path) }
        let root = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        c.append(root.appending(path: "vendor/mip/lib/\(fileName)").path)
        return c
    }

    static func load() -> Result<MIPBridgeLibrary, MIPBridgeError> {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let r = loadUncached()
        cached = r
        return r
    }

    private static func loadUncached() -> Result<MIPBridgeLibrary, MIPBridgeError> {
        guard let path = candidates().first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return .failure(.bridgeUnavailable("not-found"))
        }
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return .failure(.bridgeUnavailable("dlopen")) }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let abi = sym("nmb_abi_version", FnABI.self), abi() == expectedABI else {
            dlclose(h); return .failure(.bridgeUnavailable("abi"))
        }
        guard let ver = sym("nmb_sdk_version", FnVersion.self), let create = sym("nmb_create", FnCreate.self),
              let inspect = sym("nmb_inspect_rpmsg", FnInspect.self), let free = sym("nmb_result_free", FnFree.self),
              let destroy = sym("nmb_destroy", FnDestroy.self) else {
            dlclose(h); return .failure(.bridgeUnavailable("symbol"))
        }
        let v = ver().map { String(cString: $0) } ?? "?"
        let lib = MIPBridgeLibrary(path: path, sdkVersion: v, create: create, inspect: inspect, free: free,
                                   destroy: destroy, handle: h)
        if let l = sym("nmb_policy_load", FnPolicyLoad.self), let f = sym("nmb_policy_free", FnPolicyFree.self),
           let c = sym("nmb_label_compute", FnLabelCompute.self), let pf = sym("nmb_label_plan_free", FnPlanFree.self) {
            lib.policy = PolicyFns(load: l, free: f, compute: c, planFree: pf)
        }
        if let i = sym("nmb_inspect_rpmsg_attachments", FnAttachments.self),
           let f = sym("nmb_attachments_free", FnAttachmentsFree.self) {
            lib.attachments = AttachmentFns(inspect: i, free: f)
        }
        return .success(lib)
    }

    private init(path: String, sdkVersion: String, create: FnCreate, inspect: FnInspect, free: FnFree,
                 destroy: FnDestroy, handle: UnsafeMutableRawPointer) {
        self.path = path; self.sdkVersion = sdkVersion; self.create = create; self.inspect = inspect
        self.free = free; self.destroy = destroy; self.handle = handle
    }
}
