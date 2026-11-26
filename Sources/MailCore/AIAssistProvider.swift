import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Provider contract

/// One text completion. Implementations treat their output as untrusted text: callers parse it defensively and
/// render it as plain text only.
public protocol AIProvider: Sendable {
    /// Stable id used by `TrustPolicy.allowedAIProviders` and the audit log.
    var id: AIProviderID { get }
    var model: String { get }
    /// On-device providers may see more (see `AIGatePolicy`); everything else is `.cloud`.
    var tier: AITier { get }
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

public enum AIProviderID: String, Codable, Sendable, CaseIterable {
    case onDevice = "on-device", claudeCLI = "claude-cli", openAICompatible = "openai-compatible"
    public var title: String {
        switch self { case .onDevice: "On-device (Apple)"; case .claudeCLI: "Claude CLI"; case .openAICompatible: "OpenAI-compatible" }
    }
}

public enum AITier: String, Codable, Sendable { case onDevice, cloud }

public enum AIProviderError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConfigured(String)
    case unavailable(String)
    case timeout
    case cancelled
    case failed(String)
    case http(Int)
    case badOutput
    /// TRIAGE2-HOOK (Phase 0): the prompt + output didn't fit the model's context window.
    case contextOverflow
    /// TRIAGE2-HOOK (Phase 0): the model's safety guardrail or a refusal stopped the answer.
    case guardrail

    /// Never contains prompt text, output text or keys.
    public var description: String {
        switch self {
        case .notConfigured(let s): "AI provider not configured: \(s)"
        case .unavailable(let s): "AI provider unavailable: \(s)"
        case .timeout: "AI provider timed out"
        case .cancelled: "Cancelled"
        case .failed(let s): "AI provider failed: \(s)"
        case .http(let c): "AI provider HTTP \(c)"
        case .badOutput: "AI provider returned unusable output"
        case .contextOverflow: "AI provider: the request was too long for the model"
        case .guardrail: "AI provider declined (guardrail)"
        }
    }

    /// TRIAGE2-HOOK: content-free failure kind for the counters (`[AI] triage …`, plan §4.5).
    public var kind: AIFailureKind {
        switch self {
        case .contextOverflow: .contextOverflow
        case .guardrail: .guardrail
        case .unavailable, .notConfigured: .unavailable
        case .timeout: .timeout
        case .cancelled: .cancelled
        case .badOutput: .parse
        case .http(let c): c == 429 ? .rateLimited : .other
        case .failed(let s): s == "rate limited" ? .rateLimited : .other
        }
    }
}

/// TRIAGE2-HOOK (Phase 0): failure kinds counted per call, never with prompt or output text.
public enum AIFailureKind: String, Sendable, CaseIterable, Codable {
    case contextOverflow, guardrail, unavailable, timeout, parse, rateLimited, cancelled, other
}

// MARK: - Claude CLI

/// Runs the local `claude` binary non-interactively, isolated from the user's Claude Code setup. Flags checked
/// against `claude --help` (2.1.328):
/// * `-p` + prompt on **stdin** + `--output-format json` (single result object, `result` field)
/// * `--system-prompt` replaces the default prompt (static per feature: argv is visible in `ps`)
/// * `--tools ""` → no built-in tools; `--strict-mcp-config --mcp-config {"mcpServers":{}}` → no MCP servers
/// * `--setting-sources ""` → no user/project/local settings; `--safe-mode` → no CLAUDE.md, skills, plugins, hooks,
///   custom agents (auth still works, unlike `--bare`, which never reads OAuth/keychain)
/// * `--no-session-persistence`, `--disable-slash-commands`, `--permission-prompts none`
/// * cwd = a fresh empty temp directory (no project CLAUDE.md / .mcp.json to discover)
public struct ClaudeCLIProvider: AIProvider {
    public var id: AIProviderID { .claudeCLI }
    public var tier: AITier { .cloud }
    public var model: String
    public var binary: URL
    public var timeout: TimeInterval

    public init(model: String = "sonnet", binary: URL, timeout: TimeInterval = 60) {
        self.model = model; self.binary = binary; self.timeout = timeout
    }

    /// PATH first, then the usual install locations (a GUI app's PATH is minimal).
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: String = NSHomeDirectory(),
                              exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local", "\(home)/.claude/local/bin"]
        for d in dirs where !d.isEmpty {
            let p = (d as NSString).appendingPathComponent("claude")
            if exists(p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    public static let emptyMCPConfig = "{\"mcpServers\":{}}"

    public static func arguments(model: String, system: String) -> [String] {
        ["-p", "--output-format", "json", "--model", model, "--system-prompt", system,
         "--tools", "", "--strict-mcp-config", "--mcp-config", emptyMCPConfig, "--setting-sources", "", "--settings", #"{"autoMemoryEnabled":false}"#,
         "--safe-mode", "--no-session-persistence", "--disable-slash-commands", "--permission-prompts", "none"]
    }

    /// Allowlisted environment: enough for auth and locale, nothing from a parent Claude Code session.
    public static func environment(from parent: [String: String], binaryDir: String) -> [String: String] {
        var env: [String: String] = [:]
        for k in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] { if let v = parent[k] { env[k] = v } }
        let auth = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
                    "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "AWS_PROFILE", "AWS_REGION"]
        for k in auth { if let v = parent[k] { env[k] = v } }
        // No auto-memory: mail text must never be written into ~/.claude/projects/*/memory (see also --settings below).
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        env["PATH"] = [binaryDir, "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin"].joined(separator: ":")
        return env
    }

    public struct Result: Sendable, Equatable {
        public var text: String
        public var isError: Bool
        public var inputTokens: Int?
        public var cacheReadTokens: Int?
        public var cacheCreationTokens: Int?
    }

    /// Parses the `--output-format json` object. Anything else → `badOutput`.
    public static func parse(_ data: Data) throws -> Result {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIProviderError.badOutput }
        let usage = o["usage"] as? [String: Any]
        let isError = (o["is_error"] as? Bool) ?? ((o["subtype"] as? String).map { $0 != "success" } ?? false)
        guard let text = o["result"] as? String else {
            if isError { throw AIProviderError.failed((o["subtype"] as? String) ?? "error") }
            throw AIProviderError.badOutput
        }
        return Result(text: text, isError: isError, inputTokens: usage?["input_tokens"] as? Int,
                      cacheReadTokens: usage?["cache_read_input_tokens"] as? Int,
                      cacheCreationTokens: usage?["cache_creation_input_tokens"] as? Int)
    }

    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        // The CLI has no max-tokens flag; the prompt asks for brevity instead.
        let r = try await run(system: system, user: user)
        if r.isError { throw AIProviderError.failed("result marked as error") }
        return r.text
    }

    public func run(system: String, user: String) async throws -> Result {
        let (data, status) = try await spawn(Self.arguments(model: model, system: system), user: user, timeout: timeout)
        if let r = try? Self.parse(data) { return r }
        throw AIProviderError.failed("exit \(status)")
    }

    /// Runs the binary once (empty 0700 temp cwd, allowlisted env, prompt on stdin) and returns stdout + exit code.
    func spawn(_ args: [String], user: String, timeout: TimeInterval) async throws -> (Data, Int32) {
        let fm = FileManager.default
        let cwd = fm.temporaryDirectory.appending(path: "niivo-ai-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: cwd) }

        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = Self.environment(from: ProcessInfo.processInfo.environment, binaryDir: binary.deletingLastPathComponent().path)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe

        let box = ProcessBox(p)
        let output: (Data, Int32) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Int32), Error>) in
                let once = ResumeOnce(cont)
                let outData = DataBox(), errData = DataBox()
                let group = DispatchGroup()
                for (h, sink) in [(outPipe.fileHandleForReading, outData), (errPipe.fileHandleForReading, errData)] {
                    group.enter()
                    DispatchQueue.global().async { sink.set(h.readDataToEndOfFile()); group.leave() }
                }
                p.terminationHandler = { proc in
                    group.notify(queue: .global()) {
                        if box.timedOut { once.resume(.failure(AIProviderError.timeout)) }
                        else if box.cancelled { once.resume(.failure(AIProviderError.cancelled)) }
                        else { once.resume(.success((outData.get(), proc.terminationStatus))) }
                    }
                }
                do { try p.run() } catch {
                    once.resume(.failure(AIProviderError.unavailable("could not start claude")))
                    return
                }
                DispatchQueue.global().async {
                    let h = inPipe.fileHandleForWriting
                    try? h.write(contentsOf: Data(user.utf8))
                    try? h.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.timeout() }
            }
        } onCancel: { box.cancel() }
        return output
    }
}

/// Sendable wrappers around non-Sendable Foundation objects used across the process callbacks.
private final class ProcessBox: @unchecked Sendable {
    private let p: Process
    private let lock = NSLock()
    private var _timedOut = false, _cancelled = false
    init(_ p: Process) { self.p = p }
    var timedOut: Bool { lock.withLock { _timedOut } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    func timeout() { lock.withLock { _timedOut = true }; if p.isRunning { p.terminate() } }
    func cancel() { lock.withLock { _cancelled = true }; if p.isRunning { p.terminate() } }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var d = Data()
    func set(_ v: Data) { lock.withLock { d = v } }
    func get() -> Data { lock.withLock { d } }
}

final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { cont = c }
    func resume(_ r: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock { let c = cont; cont = nil; return c }
        c?.resume(with: r)
    }
}

// MARK: - OpenAI-compatible (OpenAI, Azure OpenAI, local servers)

public struct OpenAIConfig: Codable, Sendable, Hashable {
    public enum Flavor: String, Codable, Sendable, CaseIterable {
        /// api.openai.com style: `{base}/chat/completions`, `Authorization: Bearer`.
        case openAI
        /// Azure OpenAI: `{endpoint}/openai/deployments/{deployment}/chat/completions?api-version=…`, `api-key`
        /// header. A resource in **Switzerland North** keeps inference in Switzerland (data residency matters
        /// for niivo customers), subject to the deployment type: use a Standard (regional) deployment, not Global.
        case azure
        /// Ollama (`http://localhost:11434/v1`), LM Studio (`http://localhost:1234/v1`): key optional.
        case local
    }
    public var flavor: Flavor
    public var baseURL: String
    /// Model name, or the deployment name on Azure.
    public var model: String
    public var apiVersion: String
    public init(flavor: Flavor = .openAI, baseURL: String = "https://api.openai.com/v1", model: String = "gpt-4.1-mini",
                apiVersion: String = "2024-10-21") {
        self.flavor = flavor; self.baseURL = baseURL; self.model = model; self.apiVersion = apiVersion
    }
}

public struct OpenAICompatibleProvider: AIProvider {
    public var id: AIProviderID { .openAICompatible }
    public var tier: AITier { .cloud }
    public var config: OpenAIConfig
    public var model: String { config.model }
    /// Read on each call from the Keychain (never stored in defaults, never logged).
    public var apiKey: @Sendable () -> String?
    public var timeout: TimeInterval
    public var transport: @Sendable (URLRequest) async throws -> (Data, Int)

    public init(config: OpenAIConfig, apiKey: @escaping @Sendable () -> String?, timeout: TimeInterval = 60,
                transport: (@Sendable (URLRequest) async throws -> (Data, Int))? = nil) {
        self.config = config; self.apiKey = apiKey; self.timeout = timeout
        self.transport = transport ?? { req in
            let (d, r) = try await URLSession.shared.data(for: req)
            return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    static func isLoopback(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]"
    }

    /// Builds the Chat Completions request. Refuses plain http except to loopback (a key or mail text must never
    /// cross the network in clear).
    public static func makeRequest(_ c: OpenAIConfig, key: String?, system: String, user: String, maxTokens: Int,
                                   timeout: TimeInterval = 60) throws -> URLRequest {
        var base = c.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let urlString: String
        switch c.flavor {
        case .openAI, .local: urlString = base + "/chat/completions"
        case .azure:
            guard let dep = c.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let ver = c.apiVersion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw AIProviderError.notConfigured("deployment")
            }
            urlString = base + "/openai/deployments/\(dep)/chat/completions?api-version=\(ver)"
        }
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else { throw AIProviderError.notConfigured("base URL") }
        guard scheme == "https" || (scheme == "http" && isLoopback(url.host)) else {
            throw AIProviderError.notConfigured("base URL must be https (http only for localhost)")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch c.flavor {
        case .azure:
            guard let key, !key.isEmpty else { throw AIProviderError.notConfigured("API key") }
            req.setValue(key, forHTTPHeaderField: "api-key")
        case .openAI:
            guard let key, !key.isEmpty else { throw AIProviderError.notConfigured("API key") }
            req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        case .local:
            if let key, !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        }
        var body: [String: Any] = [
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if c.flavor != .azure { body["model"] = c.model }   // Azure takes the deployment from the URL
        // OpenAI's current models want max_completion_tokens; Azure (api-version 2024-10-21) and local servers take
        // max_tokens. UNVERIFIED against every model family.
        body[c.flavor == .openAI ? "max_completion_tokens" : "max_tokens"] = maxTokens
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public static func parse(_ data: Data) throws -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = o["choices"] as? [[String: Any]], let first = choices.first,
              let msg = first["message"] as? [String: Any], let text = msg["content"] as? String else {
            throw AIProviderError.badOutput
        }
        return text
    }

    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let req = try Self.makeRequest(config, key: apiKey(), system: system, user: user, maxTokens: maxTokens, timeout: timeout)
        let (data, status): (Data, Int)
        do { (data, status) = try await transport(req) }
        catch is CancellationError { throw AIProviderError.cancelled }
        catch let e as URLError where e.code == .timedOut { throw AIProviderError.timeout }
        catch let e as URLError where e.code == .cancelled { throw AIProviderError.cancelled }
        catch { throw AIProviderError.failed("network") }
        guard (200..<300).contains(status) else { throw AIProviderError.http(status) }
        return try Self.parse(data)
    }
}

// MARK: - On-device (Apple FoundationModels)

/// Apple's on-device model (macOS 26+, Apple Intelligence enabled and the model downloaded). Content never leaves
/// the Mac, so `AIGatePolicy` lets it read labelled-but-unencrypted content above `aiMaxPriority`.
public struct OnDeviceProvider: AIProvider {
    public var id: AIProviderID { .onDevice }
    public var tier: AITier { .onDevice }
    public var model: String { "apple-on-device" }
    public init() {}

    /// nil → available; otherwise a short reason (shown in Settings).
    public static func unavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let r): return "\(r)"
            @unknown default: return "unknown"
            }
        }
        return "needs macOS 26"
        #else
        return "FoundationModels not in this SDK"
        #endif
    }

    public static var isAvailable: Bool { unavailableReason() == nil }

    /// TRIAGE2-HOOK (Phase 0): the model's context size in tokens (input + output), read at run time, never
    /// hard-coded (plan §2.4). nil when the model isn't available.
    public static var contextTokens: Int? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable { return SystemLanguageModel.default.contextSize }
        #endif
        return nil
    }

    /// Maps FoundationModels errors to content-free kinds (H1 overflow, H2 guardrail, availability). Before Phase 0
    /// every error became `failed("on-device generation")`.
    static func map(_ error: any Error) -> AIProviderError {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded: return .contextOverflow
            case .guardrailViolation, .refusal: return .guardrail
            case .rateLimited: return .failed("rate limited")
            case .timeout: return .timeout
            case .unsupportedLanguageOrLocale: return .unavailable("language")
            default: return .failed("on-device generation")
            }
        }
        if #available(macOS 26.0, *), let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: return .contextOverflow
            case .guardrailViolation, .refusal: return .guardrail
            case .assetsUnavailable: return .unavailable("assets")
            case .unsupportedLanguageOrLocale: return .unavailable("language")
            case .rateLimited, .concurrentRequests: return .failed("rate limited")
            case .decodingFailure, .unsupportedGuide: return .badOutput
            @unknown default: return .failed("on-device generation")
            }
        }
        #endif
        return .failed("on-device generation")
    }

    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard Self.isAvailable else { throw AIProviderError.unavailable(Self.unavailableReason() ?? "") }
            let session = LanguageModelSession(instructions: system)
            do {
                let r = try await session.respond(to: user, options: GenerationOptions(maximumResponseTokens: maxTokens))
                return r.content
            } catch is CancellationError { throw AIProviderError.cancelled }
            catch { throw Self.map(error) }   // TRIAGE2-HOOK (Phase 0)
        }
        #endif
        throw AIProviderError.unavailable(Self.unavailableReason() ?? "")
    }
}

// MARK: - Keychain for the API key

/// The OpenAI-compatible key lives only in the login Keychain (this device only).
public enum AIKeychain {
    public static let service = "ai.niivo.mail.ai-key"

    public static func load(account: String = "openai") -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ key: String, account: String = "openai") -> Bool {
        delete(account: account)
        guard !key.isEmpty else { return true }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: Data(key.utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete(account: String = "openai") -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let s = SecItemDelete(q as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}
