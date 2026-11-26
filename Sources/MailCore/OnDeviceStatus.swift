import Foundation

/// Why Apple's on-device model can or can't be used, in words a user can act on. macOS owns the model: an app can't
/// download it, only send the user to System Settings → Apple Intelligence & Siri and check again.
public enum OnDeviceStatus: Equatable, Sendable {
    case available
    /// Apple Intelligence is off in System Settings.
    case notEnabled
    /// Enabled, but macOS is still downloading or preparing the model.
    case notReady
    /// This Mac can't run Apple Intelligence (hardware, region or language).
    case notEligible
    /// Older macOS, or an SDK without FoundationModels.
    case needsNewerMacOS
    case other(String)

    /// Maps FoundationModels' `UnavailableReason` description (e.g. "modelNotReady") without importing it, so tests
    /// can cover every case on any Mac.
    public init(reason: String) {
        let r = reason.lowercased()
        if r.contains("notenabled") { self = .notEnabled }
        else if r.contains("notready") { self = .notReady }
        else if r.contains("noteligible") { self = .notEligible }
        else { self = .other(reason) }
    }

    public var isAvailable: Bool { self == .available }

    /// The user can fix it in System Settings (or by waiting), so choosing on-device AI now is reasonable.
    public var isFixable: Bool { self == .notEnabled || self == .notReady }

    public var title: String {
        switch self {
        case .available: "Available"
        case .notEnabled: "Apple Intelligence is turned off"
        case .notReady: "macOS is still preparing the model"
        case .notEligible: "This Mac can't run Apple Intelligence"
        case .needsNewerMacOS: "Needs macOS 26 or later"
        case .other(let r): "Not available (\(r))"
        }
    }

    public var help: String {
        switch self {
        case .available:
            "Apple's model is ready on this Mac."
        case .notEnabled:
            "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri. macOS then downloads the model (a few GB) in the background."
        case .notReady:
            "Apple Intelligence is on and macOS is downloading or setting up the model. Keep the Mac on Wi-Fi and power; it can take a while. You can choose on-device AI now and it starts working once the model is ready."
        case .notEligible:
            "Apple Intelligence needs an Apple silicon Mac and a supported region and language. Use a local server (Ollama, LM Studio) instead."
        case .needsNewerMacOS:
            "Update macOS, or use a local server (Ollama, LM Studio) instead."
        case .other:
            "Check System Settings → Apple Intelligence & Siri, or use a local server instead."
        }
    }

    /// System Settings → Apple Intelligence & Siri.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
}
