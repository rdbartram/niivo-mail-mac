import Foundation

/// Seam for the real Microsoft Information Protection SDK (C++ Policy + Protection SDKs, macOS zip).
///
/// Why it's a seam and not linked code yet: the macOS binaries are only distributed via
/// https://aka.ms/mipsdkbinaries (licence click-through; NuGet ships headers + Windows/Linux binaries only).
/// The developer has to download and accept the licence. Once `vendor/mip/` exists, wire `MIPShim` (ObjC++) in:
///
///   1. `mip::MipContext::Create` with ApplicationInfo{clientId, "CompliantCalendar", version}
///   2. `PolicyProfile` → `PolicyEngine::Settings(identity, AuthDelegate→MSAL token for
///      https://syncservice.o365syncservice.com/ (UnifiedPolicy.User.Read), locale)` → `ListSensitivityLabels()`
///      — gives the FULL label definition incl. content-marking text, which Graph's label list omits.
///   3. Per event: `PolicyHandler(isAuditDiscoveryEnabled: true).ComputeActions(ExecutionState{
///      contentMetadata = parsed msip_labels, contentFormat = "email" })` → AddContentHeader/Footer/Watermark
///      actions map 1:1 onto `ContentPolicy.header/footer/watermark`. Discovery audit shows our app in Purview
///      Activity explorer.
///   4. Protected invites: `ProtectionProfile` → `ProtectionEngine::CreateProtectionHandlerForConsumption(PL)` →
///      `AccessCheck(EXTRACT/PRINT/EXPORT/FORWARD/REPLY/REPLYALL…)` → conform to `ItemRightsProvider` and pass it to
///      `CachedLabelPolicyEngine(itemRights:)`; per-item licence rights then win over the label's Graph rights.
///      Also decrypts the body for display (Azure RMS `user_impersonation`).
///
/// Until then `CachedLabelPolicyEngine` resolves rights from the label (Graph `sensitivityLabel/rights`) and fails
/// closed: VIEW only for encrypted labels with unknown rights; no copy/export/print for unknown labels.
public final class MIPPolicyEngine: ComplianceEngine, @unchecked Sendable {
    private let fallback: CachedLabelPolicyEngine
    public init(fallback: CachedLabelPolicyEngine) { self.fallback = fallback }

    public static var isAvailable: Bool {
        #if canImport(MIPShim)
        return true
        #else
        return false
        #endif
    }

    public var isPolicySynced: Bool { fallback.isPolicySynced }
    public func availableLabels() -> [SensitivityLabel] { fallback.availableLabels() }
    public func policy(for event: CalendarEvent, context: ComplianceContext) -> ContentPolicy {
        fallback.policy(for: event, context: context)
    }
}
