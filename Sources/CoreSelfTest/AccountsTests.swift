import Foundation
import CryptoKit
import CalendarCore
import MailCore
import TrustCore
import OfficeTools

// ACCOUNTS (docs/ACCOUNTS.md): multiple accounts, any tenant. Synthetic ids, tenants and GUIDs only.

@MainActor
func runAccountsTests() async {
    section("Accounts: registry, migration, per-account tenant + policy, store isolation, cross-tenant gate, MCP scope")
    let tA = "aaaaaaaa-0000-4000-8000-00000000000a", tB = "bbbbbbbb-0000-4000-8000-00000000000b"
    let idA = "11111111-1111-4111-8111-111111111111.\(tA)", idB = "22222222-2222-4222-8222-222222222222.\(tB)"
    let a = Account(id: idA, tenantId: tA, username: "ryan@a.example", displayName: "A")
    let b = Account(id: idB, tenantId: tB, username: "ryan@b.example", displayName: "B")

    // 1. Registry persistence is sealed.
    var reg = AccountRegistry()
    reg.add(a); reg.add(b)
    check(reg.defaultAccount?.id == idA && reg.accounts.count == 2, "first account added becomes the default")
    check(reg.accounts[1].colour != reg.accounts[0].colour, "second account gets a different colour")
    reg.add(Account(id: idB, tenantId: tB, username: "ryan@b.example", displayName: "B renamed"))
    check(reg.accounts.count == 2 && reg.account(idB)?.displayName == "B renamed", "re-adding an account refreshes it, no duplicate")
    reg.move(idB, by: -1); check(reg.accounts.first?.id == idB, "reorder moves an account up")
    reg.setColour(.amber, for: idA); check(reg.account(idA)?.colour == .amber, "colour change persists in the model")
    let key = SymmetricKey(size: .bits256)
    let sealed = try? reg.sealed(with: AESGCMCipher(key: key))
    let plain = sealed.map { String(decoding: $0, as: UTF8.self) } ?? ""
    check(sealed != nil && !plain.contains("ryan@b.example") && !plain.contains(tB), "sealed registry has no UPN or tenant in the clear")
    let reopened = sealed.flatMap { try? AccountRegistry.open($0, with: AESGCMCipher(key: key)) }
    check(reopened == reg, "sealed registry round-trips")
    check(sealed.flatMap { try? AccountRegistry.open($0, with: AESGCMCipher(key: SymmetricKey(size: .bits256))) } == nil,
          "registry can't be opened with another key")
    var reg2 = reg
    let removed = reg2.remove(idA)
    check(removed?.id == idA && reg2.defaultAccount?.id == idB, "removing the default moves the default to the next account")
    check(AccountStoreNaming.files(idA).allSatisfy { !$0.contains(AccountStoreNaming.safeName(idB)) }, "removal wipes only that account's files")

    // 2. Migration from the single-account build: same id → same store + keyring names, nothing resynced.
    let legacyKey = idA   // what `auth.accountKey` returned before accounts existed
    if case .migrate(let m) = AccountMigration.plan(sealedFile: nil, open: { _ in AccountRegistry() },
                                                    legacy: (legacyKey, "ryan@a.example")) {
        let acc = m.defaultAccount
        check(acc?.id == legacyKey && acc?.tenantId == tA, "legacy account becomes account #1 with its tenant")
        check(acc?.storeKey == "11111111-1111-4111-8111-111111111111.\(tA)"
              && AccountStoreNaming.calendarFile(legacyKey) == "\(legacyKey).sqlite"
              && AccountStoreNaming.mailFile(legacyKey) == "\(legacyKey)-mail.sqlite",
              "account #1 keeps the pre-accounts store file names (no resync, no data loss)")
    } else { check(false, "no registry + signed in → migrate") }
    check(AccountMigration.plan(sealedFile: nil, open: { _ in AccountRegistry() }, legacy: nil) == .empty, "nobody signed in → empty")
    check(AccountMigration.plan(sealedFile: Data([1, 2, 3]), open: { _ in throw CocoaError(.fileReadCorruptFile) },
                                legacy: (legacyKey, "x")) == .unreadable,
          "registry present but locked → unreadable (no migration, no overwrite)")
    if case .use(let u) = AccountMigration.plan(sealedFile: sealed, open: { try AccountRegistry.open($0, with: AESGCMCipher(key: key)) },
                                                legacy: (legacyKey, "x")) {
        check(u == reg, "existing registry is used as is")
    } else { check(false, "existing registry → use") }

    // 3. Per-account label provenance: same label GUID is ours in A, foreign in B.
    let guid = "c0ffee00-0000-4000-8000-000000000001"
    let hdrA = "MSIP_Label_\(guid)_Enabled=true; MSIP_Label_\(guid)_SiteId=\(tA)"
    check(MIPMetadata.read(hdrA, homeTenant: MIPMetadata.tenant(forAccount: a.tenantId)).origin == .home, "A's label is ours in A")
    check(MIPMetadata.read(hdrA, homeTenant: MIPMetadata.tenant(forAccount: b.tenantId)).origin == .foreign
          && MIPMetadata.read(hdrA, homeTenant: b.tenantId).labelId == nil, "the same label is foreign in B")
    // Service level: the global shim says A; B's Graph service still parses B's label as B's own.
    let savedHome = MIPMetadata.homeTenantId
    MIPMetadata.homeTenantId = tA
    let hdrB = "MSIP_Label_\(guid)_Enabled=true; MSIP_Label_\(guid)_SiteId=\(tB)"
    GraphStub.handler = { _ in
        (200, #"{"id":"m1","subject":"s","receivedDateTime":"2026-11-20T08:00:00Z","parentFolderId":"inbox","conversationId":"c1","singleValueExtendedProperties":[{"id":"String {00020386-0000-0000-C000-000000000046} Name msip_labels","value":"\#(hdrB)"}]}"#)
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [GraphStub.self]
    let svcB = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg), accountTenant: tB)
    let svcDefault = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
    let mB = try? await svcB.message(id: "m1", mailbox: "me")
    let mShim = try? await svcDefault.message(id: "m1", mailbox: "me")
    check(mB?.labelId == guid && mB?.labelOrigin == .home, "B's service reads B's label as B's own while the shim says A")
    check(mShim != nil && mShim?.labelId == nil, "the default-account shim (A) treats B's label as foreign")
    GraphStub.handler = nil
    MIPMetadata.homeTenantId = savedHome

    // 4. Store isolation: writes for A never land in B.
    let dir = FileManager.default.temporaryDirectory.appending(path: "acct-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let kA = SymmetricKey(size: .bits256), kB = SymmetricKey(size: .bits256)
    let urlA = dir.appending(path: AccountStoreNaming.mailFile(idA)), urlB = dir.appending(path: AccountStoreNaming.mailFile(idB))
    check(urlA != urlB, "each account has its own mail store file")
    if let sA = try? MailStore(url: urlA, cipher: AESGCMCipher(key: kA), indexKey: kA),
       let sB = try? MailStore(url: urlB, cipher: AESGCMCipher(key: kB), indexKey: kB) {
        let stores = AccountStores()
        stores.attach(sA, for: idA); stores.attach(sB, for: idB)
        let msg = MailMessage(id: "only-in-a", folderId: "inbox", conversationId: "c", subject: "tenant A secret",
                              from: nil, received: Date())
        try? stores.upsert([msg], account: idA)
        check((try? sA.message(id: "only-in-a")) != nil, "A's write is in A's store")
        check((try? sB.message(id: "only-in-a")) == nil, "A's write never lands in B's store")
        var unknownThrew = false
        do { try stores.upsert([msg], account: "nobody") } catch { unknownThrew = true }
        check(unknownThrew, "a write for an unknown account fails instead of falling back")
        let rawB = (try? Data(contentsOf: urlB)) ?? Data()
        check(rawB.range(of: Data("tenant A secret".utf8)) == nil, "B's file doesn't contain A's content")
    } else { check(false, "per-account stores open") }

    // 5. Policies per account (owner decision 2026-11-20): no strictest-wins across accounts.
    var strictB = TrustPolicy.byodDefault
    strictB.allowScreenCapture = false; strictB.allowCopyOut = false; strictB.aiAccess = .off
    var looseA = TrustPolicy.managedDefault
    looseA.allowScreenCapture = true; looseA.allowCopyOut = true; looseA.aiAccess = .followLabels
    let pol = AccountPolicies([idA: looseA, idB: strictB])
    check(pol.policy(for: idA).allowScreenCapture && pol.policy(for: idA).aiAccess == .followLabels,
          "A's content uses A's policy, untouched by B's stricter one")
    check(!pol.policy(for: idB).allowScreenCapture && pol.aiAccess(for: idB) == .off, "B's content uses B's policy")
    check(pol.policy(for: "unknown") == pol.fallback, "an account without a policy gets the device default")
    // Mixed list: only B's rows are shielded.
    let rows = [AccountTagged(accountId: idA, value: "a1"), AccountTagged(accountId: idB, value: "b1"),
                AccountTagged(accountId: idA, value: "a2")]
    let shielded = UnifiedRows.shielded(rows, isShielded: pol.rowShielded(account:))
    check(shielded.map(\.shielded) == [false, true, false], "mixed list: only account B's rows are shielded")
    check(pol.allowsCopyOut(accounts: [idA]) && !pol.allowsCopyOut(accounts: [idA, idB]), "copy-out follows each item's account")
    check(pol.windowAllowsCapture(visible: [idA]) && !pol.windowAllowsCapture(visible: [idA, idB]),
          "window-level capture: most restrictive among the accounts visible in that window only")
    // AI context per account.
    let ctx = [AccountTagged(accountId: idA, value: "a-mail"), AccountTagged(accountId: idB, value: "b-mail")]
    let aiA = AIContextScope.filter(ctx, for: idA) { pol.aiAccess(for: $0) != .off }
    let aiB = AIContextScope.filter(ctx, for: idB) { pol.aiAccess(for: $0) != .off }
    check(aiA.map(\.value) == ["a-mail"], "AI request for A gets only A's content")
    check(aiB.isEmpty, "AI request for B (AI off in B) gets nothing, and never A's content")

    // 6. Cross-account forward gate.
    let conf = SensitivityLabel(id: "11110000-0000-4000-8000-000000000001", name: "Confidential", priority: 2)
    let enc = SensitivityLabel(id: "11110000-0000-4000-8000-000000000002", name: "Highly Confidential", priority: 3,
                               hasProtection: true)
    let treeA = LabelTree([conf, enc])
    func msg(_ label: String?, att: [AttachmentInfo] = []) -> MailMessage {
        MailMessage(id: "f", folderId: "inbox", conversationId: "c", subject: "s", from: nil, received: Date(),
                    attachments: att, labelId: label)
    }
    let a2 = Account(id: "33333333-3333-4333-8333-333333333333.\(tA)", tenantId: tA, username: "other@a.example")
    check(CrossAccountForward.evaluate(original: msg(enc.id), sourceAccount: a, sourceTree: treeA, sending: a2) == .allow,
          "same tenant, other account: not cross-tenant (label floor as usual)")
    check(CrossAccountForward.evaluate(original: msg(nil), sourceAccount: a, sourceTree: treeA, sending: b) == .allow,
          "unlabelled mail may go via another tenant")
    if case .confirm(let w) = CrossAccountForward.evaluate(original: msg(conf.id), sourceAccount: a, sourceTree: treeA, sending: b) {
        check(w.contains("Confidential"), "unprotected label → confirm, warning names the label")
    } else { check(false, "unprotected label → confirm") }
    if case .block = CrossAccountForward.evaluate(original: msg(enc.id), sourceAccount: a, sourceTree: treeA, sending: b) {
        check(true, "protected label → blocked across tenants")
    } else { check(false, "protected label → blocked across tenants") }
    if case .block = CrossAccountForward.evaluate(original: msg(nil, att: [AttachmentInfo(id: "x", name: "message.rpmsg",
                                                                                          contentType: "application/x-microsoft-rpmsg-message", size: 1)]),
                                                  sourceAccount: a, sourceTree: treeA, sending: b) {
        check(true, "encrypted (rpmsg) → blocked across tenants")
    } else { check(false, "encrypted (rpmsg) → blocked across tenants") }
    if case .block = CrossAccountForward.evaluate(original: msg("deadbeef-0000-4000-8000-000000000000"), sourceAccount: a,
                                                  sourceTree: treeA, sending: b) {
        check(true, "label not in the source tree → blocked (fail closed)")
    } else { check(false, "label not in the source tree → blocked (fail closed)") }
    // Reply From defaults to the receiving account.
    let ids = [AccountTagged(accountId: idA, value: SendIdentity(address: "ryan@a.example", name: "R")),
               AccountTagged(accountId: idB, value: SendIdentity(address: "ryan@b.example", name: "R")),
               AccountTagged(accountId: idB, value: SendIdentity(address: "team@b.example", name: "Team", mailbox: "team@b.example"))]
    var inB = msg(nil); inB.toRecipients = [EmailAddress(name: "Team", address: "team@b.example")]
    check(AccountIdentityDefault.replyIdentity(receivedBy: idB, message: inB, identities: ids)?.value.address == "team@b.example",
          "reply From: the receiving account's identity that was addressed")
    check(AccountIdentityDefault.replyIdentity(receivedBy: idA, message: inB, identities: ids)?.value.address == "ryan@a.example",
          "reply From never picks another account's identity")

    // 7. Consent / single-tenant errors.
    let appId = "11111111-2222-3333-4444-555555555555"
    if case .adminConsentRequired(let t, let url) = AccountAuthError.classify("AADSTS65001: The user or administrator has not consented",
                                                                              tenant: tB, clientId: appId) {
        check(t == tB && url.absoluteString == "https://login.microsoftonline.com/\(tB)/adminconsent?client_id=\(appId)",
              "AADSTS65001 → admin-consent URL for that tenant")
    } else { check(false, "AADSTS65001 → admin consent") }
    if case .adminConsentRequired = AccountAuthError.classify("AADSTS90094: admin consent required", tenant: tB, clientId: appId) {
        check(true, "AADSTS90094 → admin consent")
    } else { check(false, "AADSTS90094 → admin consent") }
    check(AccountAuthError.classify("AADSTS50020: User account from identity provider does not exist in tenant", tenant: nil, clientId: appId)
          == .appNotEnabledForOrganisation
          && AccountAuthError.classify("AADSTS700016: Application not found in the directory", tenant: nil, clientId: appId)
          == .appNotEnabledForOrganisation, "AADSTS50020 / 700016 → app isn't enabled for other organisations")
    check(AccountAuthError.appNotEnabledForOrganisation.message.hasPrefix("This app isn't enabled for other organisations yet"),
          "single-tenant message wording")
    check(AccountAuthError.classify("AADSTS50076: MFA required", tenant: tB, clientId: appId) == .other("AADSTS50076: MFA required"),
          "other errors pass through")

    // 8. MCP scoping: one server per account, results tagged, no cross-account answers.
    var cA = ServerConfig(); cA.accountId = idA; cA.allowDrafts = false; cA.allowTriage = false
    var cB = ServerConfig(); cB.accountId = idB; cB.allowDrafts = false; cB.allowTriage = false
    if let bA = try? await Backend.make(cA), let bB = try? await Backend.make(cB) {
        let sA = MCPServer.agent(backend: bA, audit: AuditSink.make(fixtures: true, path: nil))
        let sB = MCPServer.agent(backend: bB, audit: AuditSink.make(fixtures: true, path: nil))
        let r = await sA.callTool("mail_list_folders", argumentsJSON: "{}")
        check(!r.isError && r.text.contains("\"account\":\"\(idA)\""), "tool result is tagged with its account")
        let other = await sA.callTool("mail_list_folders", argumentsJSON: "{\"account\":\"\(idB)\"}")
        check(other.isError, "a server refuses a call naming another account")
        let router = AccountToolRouter(servers: [idA: sA, idB: sB], defaultAccount: idA)
        check(router.resolve(argumentsJSON: "{}") == idA, "no account named → default account")
        check(router.resolve(argumentsJSON: "{\"account\":\"\(idB)\"}") == idB, "named account → its own server")
        check(router.resolve(argumentsJSON: "{\"account\":\"elsewhere\"}") == nil, "unknown account → refused")
        let viaB = await router.call("mail_list_folders", argumentsJSON: "{\"account\":\"\(idB)\"}")
        check(!viaB.isError && viaB.text.contains(idB) && !viaB.text.contains(idA), "routed result carries only B")
        let bad = await router.call("mail_list_folders", argumentsJSON: "{\"account\":\"all\"}")
        check(bad.isError, "\"all\" accounts in one call is refused")
    } else { check(false, "fixture backends per account start") }
}
