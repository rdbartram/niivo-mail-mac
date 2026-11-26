// swift-tools-version: 6.0
import PackageDescription

// Built with SwiftPM so it works with Command Line Tools only (no Xcode on this machine).
// `CoreSelfTest` stands in for a test target: `swift test` crashes under CLT 6.4 (see docs/FINDINGS.md).
let package = Package(
    name: "CompliantOffice",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CompliantCalendar", targets: ["CompliantCalendar"]),
        .executable(name: "OfficeMCP", targets: ["OfficeMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc.git",
                 .upToNextMajor(from: "2.18.1")),
        // Auto-update (docs/RELEASING.md). Pinned exactly: the bundled helpers are re-signed by scripts/bundle.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Pure, UI-free core: models, local-first store, sync, Graph client, compliance engine.
        .target(
            name: "CalendarCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // BYOD trust: managed/tenant/default policy, posture checks, tenant-driven remote wipe, app lock. UI-free.
        .target(name: "TrustCore"),
        // Mail: models, encrypted store, Graph + fixture services, sync, AI-access policy. UI-free.
        .target(
            name: "MailCore",
            dependencies: ["CalendarCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CompliantCalendar",
            dependencies: [
                "CalendarCore",
                "MailCore",
                "TrustCore",
                "OfficeTools",
                "ProtectedContent",
                .product(name: "MSAL", package: "microsoft-authentication-library-for-objc"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // niivo brand faces (OFL 1.1, see Resources/Fonts/OFL.txt). Located by NiivoFonts without Bundle.module.
            resources: [.copy("Resources/Fonts"), .copy("Resources/Localizable.xcstrings")]
        ),
        .executableTarget(name: "CoreSelfTest", dependencies: ["CalendarCore", "MailCore", "TrustCore", "OfficeTools",
                                                              "ProtectedContent"]),
        // MCP server (stdio, JSON-RPC 2.0) so AI clients can work with mail + calendar under Purview policy.
        // The gated, read-mostly tool layer: one implementation behind the MCP server AND the in-app agent loop.
        .target(name: "OfficeTools", dependencies: ["CalendarCore", "MailCore", "TrustCore"]),
        .executableTarget(name: "OfficeMCP", dependencies: ["CalendarCore", "MailCore", "TrustCore", "OfficeTools"]),
        // SEARCHQ-HOOK: search quality bench (synthetic corpus, nDCG/MRR/recall/latency), docs/SEARCH-QUALITY.md. Not in the gate.
        .executableTarget(name: "SearchBench", dependencies: ["CalendarCore", "MailCore"]),
        // Real-tenant write probe: creates and deletes "[Spike test]" items in the default calendar.
        .executableTarget(name: "LiveWriteProbe", dependencies: ["CalendarCore"]),
        // Purview decryption (MIP File SDK). Swift side only: the C++ bridge is built by scripts/build-mipbridge.sh
        // into vendor/mip/lib and dlopen'ed at runtime, so no product links the SDK (docs/MIP.md).
        // MIPBridgeABI: header-only C target with the nmb_* ABI types (no MIP linking).
        .target(name: "MIPBridgeABI"),
        .target(name: "ProtectedContent", dependencies: ["CalendarCore", "MIPBridgeABI"]),
        // Live decrypt probe for one protected message (prints lengths/rights only). Needs the owner's approval to run.
        .executableTarget(name: "MIPProbe", dependencies: ["CalendarCore", "ProtectedContent"]),
    ]
)
