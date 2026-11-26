import Foundation
import TrustCore

/// UPDATE-HOOK: Sparkle gating (TrustCore/UpdatePolicy.swift).
@MainActor
func runUpdatePolicyTests() {
    let feed = "https://github.com/example/app/releases/latest/download/appcast.xml"
    let info: [String: Any] = ["SUFeedURL": feed, "SUPublicEDKey": "AAAA"]
    let none = StaticManagedPreferences()

    check(UpdatePolicy.resolve(info: info, prefs: none).updatesAllowed, "update: feed + key → updater runs")
    check(UpdatePolicy.resolve(info: [:], prefs: none).off == .notConfigured, "update: no Info.plist keys → not configured")
    check(UpdatePolicy.resolve(info: ["SUFeedURL": feed, "SUPublicEDKey": " "], prefs: none).off == .notConfigured,
          "update: blank public key → not configured")
    check(UpdatePolicy.resolve(info: ["SUFeedURL": "http://x.example/a.xml", "SUPublicEDKey": "AAAA"], prefs: none).off
          == .notConfigured, "update: non-https feed → not configured")

    let mdmOff = StaticManagedPreferences(values: ["disableUpdates": true], forced: ["disableUpdates"])
    check(UpdatePolicy.resolve(info: info, prefs: mdmOff).off == .disabled(forced: true), "update: MDM disableUpdates wins")
    let userOff = StaticManagedPreferences(values: ["disableUpdates": "YES"])
    check(UpdatePolicy.resolve(info: info, prefs: userOff).off == .disabled(forced: false), "update: user defaults off")
    let userOn = StaticManagedPreferences(values: ["disableUpdates": false])
    check(UpdatePolicy.resolve(info: info, prefs: userOn).updatesAllowed, "update: disableUpdates=false keeps updates")

    let forcedAuto = StaticManagedPreferences(values: ["SUEnableAutomaticChecks": NSNumber(value: false)],
                                              forced: ["SUEnableAutomaticChecks"])
    let p = UpdatePolicy.resolve(info: info, prefs: forcedAuto)
    check(p.updatesAllowed && p.forcedAutomaticChecks == false, "update: forced automatic-checks locks the toggle")
    let unforcedAuto = StaticManagedPreferences(values: ["SUEnableAutomaticChecks": true])
    check(UpdatePolicy.resolve(info: info, prefs: unforcedAuto).forcedAutomaticChecks == nil,
          "update: unforced automatic-checks stays user-editable")
}
