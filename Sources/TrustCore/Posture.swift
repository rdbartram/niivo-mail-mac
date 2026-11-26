import Foundation
import Security

/// Tri-state probe result. `unverified` carries a fixed reason code.
public enum ProbeResult: Sendable, Equatable {
    case yes, no, unverified(String)
}

public enum CodeSignatureState: Sendable, Equatable {
    /// Developer ID signed and satisfies the `notarized` requirement.
    case notarized
    /// Validly signed with a real identity, not notarised (e.g. a development build).
    case signedNotNotarized
    /// Ad-hoc signature (what `swift build` produces). Counts as not notarised.
    case adhoc
    case unsigned
    /// Signature present but invalid (modified bundle).
    case invalid
    case unverified(String)
}

public struct PostureReport: Sendable, Equatable {
    public var fileVault: ProbeResult
    public var sip: ProbeResult
    /// Password required after sleep/screen saver. Best effort (see `SystemPostureProbes.screenLock`).
    public var screenLock: ProbeResult
    public var osVersion: OSVersion
    public var codeSignature: CodeSignatureState
    /// Secure Enclave present, so cache keys are SE-wrapped (`EnclaveVault`). `.no` → Keychain-only keys → restrict.
    public var secureEnclave: ProbeResult
    /// `secureEnclave` defaults to `.yes` so that fixed reports built without it keep their earlier decision; real
    /// reports always come from `PostureChecker.report`, which probes it.
    public init(fileVault: ProbeResult, sip: ProbeResult, screenLock: ProbeResult, osVersion: OSVersion,
                codeSignature: CodeSignatureState, secureEnclave: ProbeResult = .yes) {
        self.fileVault = fileVault; self.sip = sip; self.screenLock = screenLock; self.osVersion = osVersion
        self.codeSignature = codeSignature; self.secureEnclave = secureEnclave
    }
}

public enum PostureDecision: Sendable, Equatable {
    case allow
    case restrict([String])
    case block([String])
}

public protocol PostureProbing: Sendable {
    func fileVault() -> ProbeResult
    func sip() -> ProbeResult
    func screenLock() -> ProbeResult
    func osVersion() -> OSVersion
    func codeSignature() -> CodeSignatureState
    func secureEnclave() -> ProbeResult
}

public extension PostureProbing {
    /// `SecureEnclave.isAvailable`: false in VMs and on Intel Macs without a T2.
    func secureEnclave() -> ProbeResult { EnclaveVault.isAvailable ? .yes : .no }
}

public struct CommandOutput: Sendable, Equatable {
    public var status: Int32, stdout: String, stderr: String
    public init(status: Int32, stdout: String, stderr: String) { self.status = status; self.stdout = stdout; self.stderr = stderr }
}

public protocol CommandRunning: Sendable {
    /// Runs an absolute-path tool with arguments; nil when it couldn't be launched or timed out.
    func run(_ executable: String, _ arguments: [String]) -> CommandOutput?
}

/// Runs read-only status tools via `Process`, capturing output (nothing reaches our stdout).
public struct ProcessCommandRunner: CommandRunning {
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 5) { self.timeout = timeout }
    public func run(_ executable: String, _ arguments: [String]) -> CommandOutput? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandOutput(status: p.terminationStatus, stdout: o, stderr: e)
    }
}

/// Real probes. All are read-only status queries that need no admin rights.
public struct SystemPostureProbes: PostureProbing {
    public var runner: CommandRunning
    /// nil = the running process (`SecCodeCopySelf`); otherwise the bundle/binary at this path.
    public var codePath: URL?
    public init(runner: CommandRunning = ProcessCommandRunner(), codePath: URL? = nil) {
        self.runner = runner; self.codePath = codePath
    }

    /// `fdesetup status`: "FileVault is On." / "FileVault is Off." (also "Encryption in progress…").
    /// No public framework API reports FileVault state for an unprivileged app, so the CLI is the pragmatic source.
    public func fileVault() -> ProbeResult {
        guard let r = runner.run("/usr/bin/fdesetup", ["status"]) else { return .unverified("fdesetupUnavailable") }
        return Self.parseFileVault(r.stdout + r.stderr)
    }
    public static func parseFileVault(_ s: String) -> ProbeResult {
        if s.contains("FileVault is On") { return .yes }
        if s.contains("FileVault is Off") { return s.contains("Encryption in progress") ? .unverified("fileVaultEncrypting") : .no }
        return .unverified("fdesetupUnparsed")
    }

    /// `csrutil status`: "System Integrity Protection status: enabled." A custom configuration (some protections
    /// off) counts as `.no`.
    public func sip() -> ProbeResult {
        guard let r = runner.run("/usr/bin/csrutil", ["status"]) else { return .unverified("csrutilUnavailable") }
        return Self.parseSIP(r.stdout + r.stderr)
    }
    public static func parseSIP(_ s: String) -> ProbeResult {
        guard let line = s.split(separator: "\n").first(where: { $0.contains("System Integrity Protection status:") })
        else { return .unverified("csrutilUnparsed") }
        let v = line.lowercased()
        if v.contains("custom configuration") || v.contains("disabled") { return .no }
        if v.contains("enabled") { return .yes }
        return .unverified("csrutilUnparsed")
    }

    /// Best effort: `sysadminctl -screenLock status` (writes to stderr), e.g. "screenLock delay is 900 seconds",
    /// "screenLock is immediate", "screenLock is off". The output format is not a documented contract, and it says
    /// nothing about how soon the display sleeps, so anything unexpected is UNVERIFIED rather than a pass.
    public func screenLock() -> ProbeResult {
        guard let r = runner.run("/usr/sbin/sysadminctl", ["-screenLock", "status"]) else {
            return .unverified("sysadminctlUnavailable")
        }
        return Self.parseScreenLock(r.stdout + r.stderr)
    }
    public static func parseScreenLock(_ s: String) -> ProbeResult {
        let v = s.lowercased()
        if v.contains("screenlock is off") { return .no }
        if v.contains("screenlock is immediate") || v.contains("screenlock delay is") { return .yes }
        return .unverified("screenLockUnparsed")
    }

    public func osVersion() -> OSVersion { OSVersion(ProcessInfo.processInfo.operatingSystemVersion) }

    /// `SecStaticCode` validity, then the `notarized` code requirement; ad-hoc via the signing-information flags.
    public func codeSignature() -> CodeSignatureState {
        var staticCode: SecStaticCode?
        if let codePath {
            guard SecStaticCodeCreateWithPath(codePath as CFURL, [], &staticCode) == errSecSuccess else {
                return .unverified("staticCodeCreateFailed")
            }
        } else {
            var me: SecCode?
            guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
                  SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess else { return .unverified("copySelfFailed") }
        }
        guard let staticCode else { return .unverified("noStaticCode") }
        let validity = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        if validity == errSecCSUnsigned { return .unsigned }
        guard validity == errSecSuccess else { return .invalid }
        var info: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let d = info as? [String: Any], let flags = (d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
           flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return .adhoc
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString("notarized" as CFString, [], &req) == errSecSuccess, let req else {
            return .unverified("requirementFailed")
        }
        return SecStaticCodeCheckValidity(staticCode, [], req) == errSecSuccess ? .notarized : .signedNotNotarized
    }
}

/// Fixed probe values for tests.
public struct StaticPostureProbes: PostureProbing {
    public var report: PostureReport
    public init(_ report: PostureReport) { self.report = report }
    public func fileVault() -> ProbeResult { report.fileVault }
    public func sip() -> ProbeResult { report.sip }
    public func screenLock() -> ProbeResult { report.screenLock }
    public func osVersion() -> OSVersion { report.osVersion }
    public func codeSignature() -> CodeSignatureState { report.codeSignature }
    public func secureEnclave() -> ProbeResult { report.secureEnclave }
}

public enum PostureChecker {
    public static func report(_ probes: PostureProbing) -> PostureReport {
        PostureReport(fileVault: probes.fileVault(), sip: probes.sip(), screenLock: probes.screenLock(),
                      osVersion: probes.osVersion(), codeSignature: probes.codeSignature(),
                      secureEnclave: probes.secureEnclave())
    }

    /// Rules:
    /// - OS below the minimum, or a required FileVault/SIP/screen lock that is definitely off → block.
    /// - A required check that couldn't be verified → restrict (fail toward less data, not toward lock-out).
    /// - Invalid code signature → block (modified bundle). Not notarised (ad-hoc, unsigned, dev-signed) → restrict on
    ///   BYOD, allowed on managed Macs (MDM governs what runs there). This is advisory: whoever can patch the binary
    ///   can patch this check out too.
    /// - No Secure Enclave (VM, old Intel) → restrict on every profile: cache keys are Keychain-only, not
    ///   hardware-bound and not presence-gated.
    public static func decide(_ r: PostureReport, policy p: TrustPolicy) -> PostureDecision {
        var block: [String] = [], restrict: [String] = []
        if r.osVersion < p.minimumOSVersion { block.append("osBelowMinimum") }
        func req(_ required: Bool, _ v: ProbeResult, _ name: String) {
            guard required else { return }
            switch v {
            case .yes: break
            case .no: block.append("\(name)Off")
            case .unverified(let why): restrict.append("\(name)Unverified:\(why)")
            }
        }
        req(p.requireFileVault, r.fileVault, "fileVault")
        req(p.requireSIP, r.sip, "sip")
        req(p.requireScreenLock, r.screenLock, "screenLock")
        switch r.codeSignature {
        case .notarized: break
        case .invalid: block.append("codeSignatureInvalid")
        case .adhoc, .unsigned, .signedNotNotarized, .unverified:
            if p.profile == .byod { restrict.append("notNotarized") }
        }
        switch r.secureEnclave {
        case .yes: break
        case .no: restrict.append("noSecureEnclave")
        case .unverified(let why): restrict.append("secureEnclaveUnverified:\(why)")
        }
        if !block.isEmpty { return .block(block + restrict) }
        if !restrict.isEmpty { return .restrict(restrict) }
        return .allow
    }
}
