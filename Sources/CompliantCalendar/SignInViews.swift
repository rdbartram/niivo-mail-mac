import SwiftUI
import AppKit
import CalendarCore

/// First-run / signed-out screen (BACKLOG §17). Three states:
/// - not configured (a build without bundled tenant defaults and no config.json): say so plainly and let the user
///   (or their admin) enter the organisation's client ID, instead of silently opening sample data;
/// - ready to sign in: one button, and what will happen (Microsoft's sheet, one consent for calendar + mail);
/// - a failed sign-in: the classified reason (admin approval needed, wrong organisation), never a raw AADSTS dump.
struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 52, weight: .thin)).foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("niivo mail").font(.largeTitle.weight(.semibold))
                Text("Mail and calendar for Microsoft 365, with your organisation's labels respected on this Mac.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            }
            if model.mode == .unconfigured {
                NotConfiguredPanel()
            } else {
                signInPanel
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var signInPanel: some View {
        VStack(spacing: 14) {
            Button {
                Task { await model.signIn() }
            } label: {
                HStack(spacing: 8) {
                    if model.signingIn { ProgressView().controlSize(.small) }
                    Text(model.signingIn ? "Signing in…" : "Sign in with Microsoft")
                }
                .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.signingIn)

            Text("Use your work account. Microsoft's sign-in opens in a sheet; your organisation may ask you to approve access to mail and calendar once.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)

            if let e = model.signInError { SignInErrorPanel(error: e) }
            else if let err = model.lastError { Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled) }

            Label("Everything kept offline is encrypted on this Mac and removed if your access is revoked.",
                  systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct SignInErrorPanel: View {
    let error: AccountAuthError
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch error {
            case .adminConsentRequired(_, let url):
                Label("Your administrator needs to approve niivo mail", systemImage: "person.badge.key")
                    .font(.headline)
                Text("Send them this link. Once they approve it, sign in again.").foregroundStyle(.secondary)
                HStack {
                    Text(url.absoluteString).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
            case .appNotEnabledForOrganisation:
                Label("This account can't sign in to this copy yet", systemImage: "building.2")
                    .font(.headline)
                Text("Personal Microsoft accounts (Outlook.com, Hotmail) aren't supported yet. Use a work or school account, or ask whoever gave you the app whether it's set up for your organisation.")
                    .foregroundStyle(.secondary)
            case .other(let text):
                Label("Sign-in didn't complete", systemImage: "exclamationmark.triangle").font(.headline)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Plain storage for the setup fields (no @State: the CLT toolchain has no SwiftUI macro plugin).
@MainActor @Observable
final class SetupForm {
    static let shared = SetupForm()
    var clientId = ""
    var tenant = ""
    var error: String?
}

/// Shown only when the build carries no tenant defaults and there's no config.json. Writes config.json and relaunches.
private struct NotConfiguredPanel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var form = SetupForm.shared
        VStack(alignment: .leading, spacing: 10) {
            Text("This copy isn't set up for an organisation yet").font(.headline)
            Text("Your IT administrator can give you the app (client) ID of niivo mail's Entra app registration and your directory (tenant) ID or domain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Application (client) ID", text: $form.clientId).textFieldStyle(.roundedBorder)
            TextField("Tenant ID or domain, e.g. contoso.com", text: $form.tenant).textFieldStyle(.roundedBorder)
            if let e = form.error { Text(e).font(.caption).foregroundStyle(.red) }
            if let e = model.lastError { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Show configuration folder") {
                    try? FileManager.default.createDirectory(at: AppConfig.supportDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppConfig.supportDir)
                }
                Spacer()
                Button("Save and restart") { save(form) }
                    .buttonStyle(.borderedProminent)
                    .disabled(form.clientId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: 460)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func save(_ form: SetupForm) {
        let id = form.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let tenant = form.tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else { form.error = "The client ID is a GUID, like 00000000-0000-0000-0000-000000000000."; return }
        let url = AppConfig.supportDir.appending(path: "config.json")
        var config = (try? JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))) ?? AppConfig()
        config.clientId = id
        config.tenantId = tenant.isEmpty ? nil : tenant
        do {
            try FileManager.default.createDirectory(at: AppConfig.supportDir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(config).write(to: url, options: .atomic)
        } catch { form.error = "Couldn't save: \(error.localizedDescription)"; return }
        relaunch()
    }

    /// Start a fresh instance and quit: configuration is read once at launch (trust, stores and MSAL hang off it).
    private func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
