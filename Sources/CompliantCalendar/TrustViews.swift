import SwiftUI
import TrustCore

/// Replaces the whole window content (not an overlay, so sheets can't show through) while the app is locked,
/// posture-blocked or wiped. State lives in models, so sheets re-present on unlock.
struct TrustGateView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    /// Preview only: render the locked state without locking.
    var previewState: AppLockState? = nil

    var body: some View {
        if skin.brand { NiivoGate(previewState: previewState) } else { classic }
    }

    private var classic: some View {
        let t = app.trust
        return ZStack {
            LinearGradient(colors: [.indigo.opacity(0.18), .pink.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(.background)
            VStack(spacing: 16) {
                if case .wiped(let reason, let at) = t.wipe { wiped(reason, at) }
                else if t.isBlocked { blocked() }
                else { locked() }
            }
            .padding(40).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func locked() -> some View {
        let t = app.trust
        Image(systemName: "lock.fill").font(.system(size: 52, weight: .thin)).foregroundStyle(.secondary)
        Text("niivo mail is locked").font(.title.weight(.semibold))
        Text(Self.reason(previewState ?? t.lockState)).foregroundStyle(.secondary)
        Button { Task { await t.unlock() } } label: { Label("Unlock with Touch ID", systemImage: "touchid") }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        if t.unlockFailed { Text("Not unlocked. Try again or use your Mac password.").font(.caption).foregroundStyle(.red) }
    }

    @ViewBuilder private func blocked() -> some View {
        let t = app.trust
        Image(systemName: "exclamationmark.shield.fill").font(.system(size: 52, weight: .thin)).foregroundStyle(.red)
        Text("This Mac doesn't meet your organisation's requirements").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
        VStack(alignment: .leading, spacing: 4) { ForEach(t.postureReasons, id: \.self) { Text("• " + $0) } }
        Button("Check Again") { Task { await t.checkPosture() } }.disabled(t.postureChecking)
    }

    @ViewBuilder private func wiped(_ reason: String, _ at: Date) -> some View {
        Image(systemName: "trash.slash.fill").font(.system(size: 52, weight: .thin)).foregroundStyle(.red)
        Text("Your organisation removed its data from this Mac").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
        Text("Reason: \(reason) · \(at.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
        Text("Mail and calendar caches were deleted. Sign in again once your access is restored.")
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        if app.isFixtureMode {
            Text("Simulation: only the in-memory fixture stores were wiped.").font(.caption).foregroundStyle(.orange)
            Button("Reset Demo") { Task { await app.resetWipeSimulation() } }.buttonStyle(.borderedProminent)
        }
    }

    static func reason(_ s: AppLockState) -> String {
        guard case .locked(let r) = s else { return "" }
        switch r {
        case .launch: return "Unlock to show mail and calendar."
        case .idle: return "Locked after a period of inactivity."
        case .sleep: return "Locked when the Mac slept."
        case .policyChanged: return "Your organisation's policy changed."
        case .manual: return "Locked."
        }
    }
}

/// The niivo lock screen: paper (carbon in Dark Mode), words in a left column, the wordmark with its blinking cursor
/// (the one cyan element), and the ıı drawn large off the bottom-right edge. Same states and actions as the classic gate.
struct NiivoGate: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var previewState: AppLockState?

    var body: some View {
        let t = app.trust
        GeometryReader { g in
            let inset = max(48, g.size.width * 0.067)
            ZStack(alignment: .topLeading) {
                skin.ground
                // The drawing: the outline ıı, bleeding off the right and bottom edges. Decorative only.
                NiivoMark()
                    .stroke(skin.hair2, lineWidth: 1.5)
                    .frame(width: g.size.height * 0.95 * 238 / 236, height: g.size.height * 0.95)
                    .position(x: g.size.width - g.size.height * 0.30, y: g.size.height * 0.72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        MonoLabel("niivo mail", bracket: true, wide: true)
                        Spacer()
                        MonoLabel(t.policy.profile == .byod ? "Personal Mac (BYOD) policy" : "Managed Mac policy", wide: true)
                    }
                    Spacer(minLength: 24)
                    content(t)
                        .frame(maxWidth: 560, alignment: .leading)
                    Spacer(minLength: 24)
                    HStack(alignment: .firstTextBaseline) {
                        MonoLabel("niivo.ai", color: skin.ink, wide: true)
                        Spacer()
                        MonoLabel(stateLabel(t), color: isAlarm(t) ? skin.danger : skin.muted, bracket: true)
                    }
                }
                .padding(.horizontal, inset).padding(.vertical, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isAlarm(_ t: TrustModel) -> Bool { t.isWiped || t.isBlocked }
    private func stateLabel(_ t: TrustModel) -> String {
        if t.isWiped { return "02 — Wiped" }
        if t.isBlocked { return "03 — Blocked" }
        return "01 — Locked"
    }

    @ViewBuilder private func content(_ t: TrustModel) -> some View {
        if case .wiped(let reason, let at) = t.wipe {
            VStack(alignment: .leading, spacing: 18) {
                MonoLabel("Data removed", color: skin.danger, bracket: true)
                headline("Your organisation removed its data from this Mac.")
                Text("Reason: \(reason) · \(at.formatted(date: .abbreviated, time: .shortened))").font(skin.sans(15)).foregroundStyle(skin.muted)
                Text("Mail and calendar caches were deleted. Sign in again once your access is restored.")
                    .font(skin.sans(15)).foregroundStyle(skin.muted)
                if app.isFixtureMode {
                    MonoLabel("Simulation: only the in-memory fixture stores were wiped.", color: .orange)
                    Button("Reset Demo") { Task { await app.resetWipeSimulation() } }.nvButton(skin, .primary, large: true)
                }
            }
        } else if t.isBlocked {
            VStack(alignment: .leading, spacing: 18) {
                MonoLabel("Requirements not met", color: skin.danger, bracket: true)
                headline("This Mac doesn't meet your organisation's requirements.")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(t.postureReasons, id: \.self) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            NiivoCut(height: 11, color: skin.danger)
                            Text(r).font(skin.sans(15)).foregroundStyle(skin.ink)
                        }
                    }
                }
                Button("Check Again") { Task { await t.checkPosture() } }.disabled(t.postureChecking).nvButton(skin, .ghost, large: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                NiivoWordmark(size: 104, color: skin.ink).padding(.bottom, 40)
                headline("niivo mail is locked.").padding(.bottom, 10)
                Text(TrustGateView.reason(previewState ?? t.lockState))
                    .font(skin.sans(16)).foregroundStyle(skin.muted).padding(.bottom, 30)
                HStack(spacing: 14) {
                    Button { Task { await t.unlock() } } label: { Label("Unlock with Touch ID", systemImage: "touchid") }
                        .nvButton(skin, .primary, large: true).keyboardShortcut(.defaultAction)
                    MonoLabel("↩ Return", size: NV.Size.labelSm, wide: true)
                }
                if t.unlockFailed {
                    MonoLabel("Not unlocked. Try again or use your Mac password.", color: skin.danger).padding(.top, 14)
                }
            }
        }
    }

    private func headline(_ s: String) -> some View {
        Text(s).font(skin.sans(NV.Size.display)).tracking(skin.titleTrack(NV.Size.display))
            .foregroundStyle(skin.ink).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Posture `.restrict`: the app works with tighter controls; say so once per session.
struct PostureBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let t = app.trust
        if t.isBlocked || (t.postureDecision != .allow && !app.postureBannerDismissed) {
            let tone: Color = t.isBlocked ? skin.danger : .orange
            HStack(spacing: 8) {
                if skin.brand {
                    Rectangle().fill(tone).frame(width: 3).padding(.vertical, -5)
                    MonoLabel(t.isBlocked ? "Blocked" : "Restricted", color: tone, weight: .medium)
                } else {
                    Image(systemName: t.isBlocked ? "exclamationmark.octagon.fill" : "exclamationmark.shield").foregroundStyle(tone)
                }
                Text((t.isBlocked ? "This Mac doesn't meet your organisation's requirements: " : (skin.brand ? "" : "Restricted mode: "))
                     + t.postureReasons.joined(separator: " · ")).lineLimit(1).help(t.postureReasons.joined(separator: "\n"))
                Spacer()
                Button("Details") { app.mail.settingsTab = .trust; app.mail.showSettings = true }.nvButton(skin, .quiet)
                if t.isBlocked { Button("Check Again") { Task { await t.checkPosture() } }.nvButton(skin, .quiet) }
                else { Button { app.postureBannerDismissed = true } label: { NSymbol("xmark", size: 10, label: "Dismiss") }.buttonStyle(.borderless).accessibilityLabel("Dismiss") }
            }
            .font(skin.brand ? skin.sans(NV.Size.bodySm) : .caption).padding(.horizontal, 12).padding(.vertical, 5)
            .background(tone.opacity(0.12))
            .hairline(skin)
        }
    }
}
