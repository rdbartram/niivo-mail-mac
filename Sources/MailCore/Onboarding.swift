import Foundation
import CryptoKit

// ONBOARDING (docs/BACKLOG.md §17 step 5): the first-run sheet's pure parts. Step state machine + per-account
// completion, the AI choice clamped by the organisation policy, and local OpenAI-compatible server detection.
// No model is downloaded by niivo: Apple's on-device model is managed by macOS, a local server manages its own models.

public enum OnboardingStep: String, Codable, Sendable, CaseIterable, Identifiable {
    case welcome, ai, localModels, voice, signatures, done
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .welcome: "Welcome"; case .ai: "AI"; case .localModels: "Local models"; case .voice: "Voice"
        case .signatures: "Signatures"; case .done: "Done"
        }
    }
}

/// What the user did in setup, per account. Content-free.
public struct OnboardingProgress: Codable, Sendable, Hashable {
    public var completed: Set<OnboardingStep> = []
    public var skipped: Set<OnboardingStep> = []
    /// Set once the sheet was finished or dismissed: it then never opens on its own again for this account.
    public var finishedAt: Date?
    public init() {}
    public var isFinished: Bool { finishedAt != nil }
}

public struct OnboardingFlow: Sendable, Hashable {
    public private(set) var step: OnboardingStep
    public private(set) var progress: OnboardingProgress
    public static let steps = OnboardingStep.allCases

    /// A first run starts at the first step not yet completed or skipped; "Run setup again" starts at Welcome.
    public init(progress: OnboardingProgress = OnboardingProgress(), restart: Bool = false) {
        self.progress = progress
        step = restart ? .welcome
            : Self.steps.first { !progress.completed.contains($0) && !progress.skipped.contains($0) } ?? .done
    }

    public var index: Int { Self.steps.firstIndex(of: step) ?? 0 }
    public var isFirst: Bool { index == 0 }
    public var isLast: Bool { step == Self.steps.last }

    /// The current step was done: mark it and move on. On the last step this finishes.
    public mutating func complete(now: Date = .now) {
        progress.completed.insert(step); progress.skipped.remove(step)
        advance(now: now)
    }

    /// The current step was passed over (a step completed earlier stays completed).
    public mutating func skip(now: Date = .now) {
        if !progress.completed.contains(step) { progress.skipped.insert(step) }
        advance(now: now)
    }

    public mutating func back() {
        if index > 0 { step = Self.steps[index - 1] }
    }

    public mutating func go(to s: OnboardingStep) { step = s }

    /// "Skip setup" / closing the sheet: every step not completed counts as skipped and the flow is finished.
    public mutating func finish(now: Date = .now) {
        for s in Self.steps where !progress.completed.contains(s) && s != .done { progress.skipped.insert(s) }
        progress.completed.insert(.done)
        if progress.finishedAt == nil { progress.finishedAt = now }
        step = .done
    }

    private mutating func advance(now: Date) {
        if isLast { finish(now: now) } else { step = Self.steps[index + 1] }
    }
}

/// Per-account storage in UserDefaults (settings, not content). The key carries a hash of the account id, not the id.
public enum OnboardingStore {
    public static let prefix = "onboarding.v1."

    public static func accountSuffix(_ account: String) -> String {
        SHA256.hash(data: Data(account.lowercased().utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func key(account: String) -> String { prefix + accountSuffix(account) }

    public static func load(account: String, defaults: UserDefaults = .standard) -> OnboardingProgress {
        defaults.data(forKey: key(account: account)).flatMap { try? JSONDecoder().decode(OnboardingProgress.self, from: $0) }
            ?? OnboardingProgress()
    }

    public static func save(_ p: OnboardingProgress, account: String, defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(p) { defaults.set(d, forKey: key(account: account)) }
    }

    /// Opens on its own only for a signed-in account that hasn't finished (or dismissed) setup yet.
    public static func shouldAutoShow(account: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let a = account, !a.isEmpty else { return false }
        return !load(account: a, defaults: defaults).isFinished
    }
}

// MARK: - AI choice, never above what the organisation allows

public enum AIOnboardingChoice: String, Sendable, CaseIterable, Identifiable {
    case off, onDeviceOnly, cloudWherePermitted
    public var id: String { rawValue }
    public var title: String {
        switch self { case .off: "Off"; case .onDeviceOnly: "On-device only"; case .cloudWherePermitted: "Allow cloud where policy permits" }
    }
}

public enum AIChoicePolicy {
    public static let cloudProviderIds: [AIProviderID] = [.claudeCLI, .openAICompatible]

    /// Cloud providers the policy admits (same rule as `AIGatePolicy.allows`).
    public static func cloudProviders(cloudAccess: AIOrgAccess, allowedProviders: Set<AIProviderID>?) -> [AIProviderID] {
        guard cloudAccess != .off else { return [] }
        return cloudProviderIds.filter { allowedProviders?.contains($0) ?? true }
    }

    /// nil = the policy allows this choice; otherwise why not (shown next to the disabled option).
    public static func policyRefusal(_ c: AIOnboardingChoice, cloudAccess: AIOrgAccess, onDeviceAccess: AIOrgAccess,
                                     allowedProviders: Set<AIProviderID>?) -> String? {
        switch c {
        case .off: return nil
        case .onDeviceOnly:
            if onDeviceAccess == .off { return "On-device AI is turned off by your organisation's policy" }
            if let a = allowedProviders, !a.contains(.onDevice) { return "Your organisation's policy doesn't allow the on-device provider" }
            return nil
        case .cloudWherePermitted:
            if cloudAccess == .off { return "Cloud AI is turned off by your organisation's policy" }
            if cloudProviders(cloudAccess: cloudAccess, allowedProviders: allowedProviders).isEmpty {
                return "Your organisation's policy allows no cloud AI provider"
            }
            return nil
        }
    }

    /// The highest choice at or below `requested` that the policy allows (cloud → on-device → off).
    public static func clamp(_ requested: AIOnboardingChoice, cloudAccess: AIOrgAccess, onDeviceAccess: AIOrgAccess,
                             allowedProviders: Set<AIProviderID>?) -> AIOnboardingChoice {
        let order: [AIOnboardingChoice] = [.cloudWherePermitted, .onDeviceOnly, .off]
        let start = order.firstIndex(of: requested) ?? 2
        return order[start...].first {
            policyRefusal($0, cloudAccess: cloudAccess, onDeviceAccess: onDeviceAccess, allowedProviders: allowedProviders) == nil
        } ?? .off
    }

    /// The onboarding choice the stored provider setting corresponds to.
    public static func choice(for p: AIProviderChoice) -> AIOnboardingChoice {
        switch p { case .off: .off; case .onDevice: .onDeviceOnly; case .claudeCLI, .openAICompatible: .cloudWherePermitted }
    }

    /// The provider setting to store. Cloud keeps an already chosen cloud provider; otherwise `cloud` (the user's pick).
    public static func providerChoice(_ c: AIOnboardingChoice, current: AIProviderChoice, cloud: AIProviderID?) -> AIProviderChoice {
        switch c {
        case .off: return .off
        case .onDeviceOnly: return .onDevice
        case .cloudWherePermitted:
            switch cloud {
            case .claudeCLI: return .claudeCLI
            case .openAICompatible: return .openAICompatible
            default: return current == .claudeCLI || current == .openAICompatible ? current : .off
            }
        }
    }
}

// MARK: - Local OpenAI-compatible servers (Ollama, LM Studio)

public struct LocalModelInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var sizeBytes: Int64?
    public var parameters: String?
    public init(name: String, sizeBytes: Int64? = nil, parameters: String? = nil) {
        self.name = name; self.sizeBytes = sizeBytes; self.parameters = parameters
    }
    public var sizeText: String? {
        sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

public enum LocalModelServer {
    public static let known: [(name: String, baseURL: String)] = [
        ("Ollama", "http://localhost:11434/v1"), ("LM Studio", "http://localhost:1234/v1"),
    ]

    /// Same rule as `OpenAICompatibleProvider.makeRequest`: https anywhere, plain http only to this Mac.
    public static func refusal(baseURL: String) -> String? {
        let t = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), u.host != nil else { return "Not a valid URL" }
        if scheme == "https" { return nil }
        if scheme == "http" { return OpenAICompatibleProvider.isLoopback(u.host) ? nil : "Plain http is allowed only to this Mac (localhost)" }
        return "Use http://localhost… or https://"
    }

    public static func isLoopback(baseURL: String) -> Bool {
        OpenAICompatibleProvider.isLoopback(URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host)
    }

    static func trimmed(_ base: String) -> String {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    /// `{base}/models` (OpenAI-style list).
    public static func modelsURL(baseURL: String) -> URL? { URL(string: trimmed(baseURL) + "/models") }

    /// Ollama's own list (`/api/tags`) carries sizes; derived from a `…/v1` base.
    public static func ollamaTagsURL(baseURL: String) -> URL? {
        var b = trimmed(baseURL)
        if b.hasSuffix("/v1") { b.removeLast(3) } else { return nil }
        return URL(string: b + "/api/tags")
    }

    /// `{"data":[{"id":"…"}]}`
    public static func parseOpenAIModels(_ d: Data) -> [LocalModelInfo] {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let data = o["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { ($0["id"] as? String).map { LocalModelInfo(name: AIUntrustedText.line($0, max: 120)) } }
            .filter { !$0.name.isEmpty }
    }

    /// `{"models":[{"name":"…","size":123,"details":{"parameter_size":"8B"}}]}`
    public static func parseOllamaTags(_ d: Data) -> [LocalModelInfo] {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ms = o["models"] as? [[String: Any]] else { return [] }
        return ms.compactMap { m in
            guard let n = (m["name"] as? String) ?? (m["model"] as? String) else { return nil }
            let size = (m["size"] as? NSNumber)?.int64Value
            let params = (m["details"] as? [String: Any])?["parameter_size"] as? String
            return LocalModelInfo(name: AIUntrustedText.line(n, max: 120), sizeBytes: size, parameters: params.map { AIUntrustedText.line($0, max: 20) })
        }.filter { !$0.name.isEmpty }
    }

    /// Sizes from Ollama's list merged into the OpenAI list (or Ollama's list alone).
    public static func merge(openAI: [LocalModelInfo], ollama: [LocalModelInfo]) -> [LocalModelInfo] {
        guard !openAI.isEmpty else { return ollama }
        let byName = Dictionary(ollama.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return openAI.map { m in byName[m.name].map { LocalModelInfo(name: m.name, sizeBytes: $0.sizeBytes, parameters: $0.parameters) } ?? m }
    }
}
