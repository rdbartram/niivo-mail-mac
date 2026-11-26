import Foundation
import CalendarCore
import ProtectedContent

/// Offline checks for the MIP decrypt path (docs/MIP.md). Nothing here touches the network or a tenant.
@MainActor
func runProtectedContentTests() async {
    section("Protected content (MIP) — offline")

    // Licence rights mapping.
    check(UsageRights.fromLicence(["VIEW", "EXTRACT", "REPLY", "REPLYALL", "FORWARD", "PRINT"])
          == [.view, .extract, .reply, .replyAll, .forward, .print], "licence rights map 1:1 onto UsageRights")
    check(UsageRights.fromLicence(["VIEW", "AUDITEDEXTRACT"]) == [.view], "AUDITEDEXTRACT is not EXTRACT (ignored)")
    check(UsageRights.fromLicence(["OWNER"]) == .all, "licence OWNER expands to every right")
    check(UsageRights.fromLicence([]) == [] && UsageRights.fromLicence(["bogus"]) == [],
          "empty / unknown licence → explicit empty set, not nil")
    check(UsageRights.fromLicence(["view,reply"]) == [.view, .reply], "comma-joined bridge output parses")

    // LicenceRightsStore as ItemRightsProvider.
    let L = FixtureCalendarService.labels
    let store = LicenceRightsStore(capacity: 3)
    let eng = CachedLabelPolicyEngine(labels: L, synced: true, itemRights: store)
    let protected = L.first(where: \.hasProtection)!
    let before = eng.policy(labelId: protected.id, isPrivate: false, access: .own, itemId: "m1")
    check(before.rightsSource != .itemLicence, "not decrypted yet → label rights, not licence")
    store.set([], for: "m1")
    let empty = eng.policy(labelId: protected.id, isPrivate: false, access: .own, itemId: "m1")
    check(empty.rightsSource == .itemLicence && empty.rights.isEmpty && !empty.allowCopy && !empty.allowForward,
          "empty licence stays empty (no fall-through to broader label rights)")
    store.set([.view, .reply], for: "m1")
    let doNotForward = eng.policy(labelId: protected.id, isPrivate: false, access: .own, itemId: "m1")
    check(doNotForward.allowReply && !doNotForward.allowForward && !doNotForward.allowCopy
          && doNotForward.preventScreenCapture && !doNotForward.allowOfflineDetails && !doNotForward.aiMayReadContent,
          "licence VIEW+REPLY: reply ok, no forward/copy, capture blocked, not cached, no AI")
    let unlabelledIRM = eng.policy(labelId: nil, isPrivate: false, access: .own, itemId: "m1")
    check(unlabelledIRM.bodyIsProtected && unlabelledIRM.rightsSource == .itemLicence,
          "licence on an unlabelled (IRM) item still applies")
    for i in 2...4 { store.set([.view], for: "m\(i)") }
    check(store.count == 3 && store.rights(itemId: "m1", labelId: nil) == nil, "store is bounded (oldest evicted)")
    store.removeAll()
    check(store.count == 0, "removeAll (sign-out / wipe) clears licence rights")

    // Cache configuration.
    check(MIPCacheConfig.byod.mode == .inMemory, "BYOD default: in-memory licence cache")
    check(MIPCacheConfig.resolve(isManagedDevice: false, policyAllowsEncryptedCache: true).mode == .inMemory,
          "BYOD never gets an on-disk cache, even if policy says allow")
    check(MIPCacheConfig.resolve(isManagedDevice: true, policyAllowsEncryptedCache: false).mode == .inMemory,
          "managed without admin opt-in: in memory")
    check(MIPCacheConfig.resolve(isManagedDevice: true, policyAllowsEncryptedCache: true).mode == .onDiskEncrypted,
          "managed + admin opt-in: encrypted on disk")
    check(MIPCacheMode.inMemory.rawValue == 0 && MIPCacheMode.onDiskEncrypted.rawValue == 2,
          "cache modes match mip::CacheStorageType (plaintext OnDisk=1 never used)")

    // No-disk-plaintext guard.
    do {
        let dir = try NoDiskPlaintextGuard.makeStateDirectory()
        let perms = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        check(perms == 0o700, "state directory is private (0700)")
        try FileManager.default.createDirectory(at: dir.appending(path: "mip/logs"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appending(path: "mip/logs/empty.miplog").path, contents: Data())
        var threw = false
        do { try NoDiskPlaintextGuard.enforce(dir) } catch { threw = true }
        check(!threw, "guard tolerates empty placeholder files")
        let leak = dir.appending(path: "mip/leak.db")
        FileManager.default.createFile(atPath: leak.path, contents: Data("synthetic".utf8))
        var caught: MIPBridgeError?
        do { try NoDiskPlaintextGuard.enforce(dir) } catch let e as MIPBridgeError { caught = e } catch {}
        check(caught == .plaintextOnDisk(fileCount: 1) && !FileManager.default.fileExists(atPath: leak.path),
              "guard fails closed on a non-empty file and deletes it")
        try? FileManager.default.removeItem(at: dir)
    } catch { check(false, "guard setup threw \(error)") }

    // Text body → escaped HTML.
    check(ProtectedBodyFormat.html(fromText: "<b>&\"x\"</b>").contains("&lt;b&gt;&amp;&quot;x&quot;&lt;/b&gt;"),
          "text bodies are HTML-escaped before display")

    // Token request routing.
    check(MIPTokenRequest(authority: "", resource: "https://aadrm.com").msalScopes == ["https://aadrm.com/user_impersonation"],
          "RMS resource → user_impersonation scope")
    check(MIPTokenRequest(authority: "", resource: "https://syncservice.o365syncservice.com/").msalScopes
          == ["https://syncservice.o365syncservice.com/UnifiedPolicy.User.Read"], "sync resource → UnifiedPolicy.User.Read")
    check(MIPTokenRequest(authority: "", resource: "https://api.aadrm.com/").service == .rms
          && MIPTokenRequest(authority: "", resource: "https://example.test").msalScopes == ["https://example.test/.default"],
          "resource host matching; unknown resource → /.default")

    // rpmsg detection on synthetic data.
    check(RPMSG.isRPMSGName("message.rpmsg") && RPMSG.isRPMSGName("MESSAGE_V2.RPMSG") && RPMSG.isRPMSGName("message_v4.rpmsg")
          && !RPMSG.isRPMSGName("message_v9.rpmsg") && !RPMSG.isRPMSGName("invoice.rpmsg.pdf"),
          "rpmsg attachment names (message, message_v2..v4)")
    check(RPMSG.isRPMSGAttachment(name: "x.bin", contentType: "application/x-microsoft-rpmsg-message")
          && !RPMSG.isRPMSGAttachment(name: "report.pdf", contentType: "application/pdf"), "rpmsg content type")
    let payload = Data((0..<300).map { UInt8($0 % 251) })
    let b64 = payload.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    let mime = """
    MIME-Version: 1.0\r
    Content-Class: rpmsg.message\r
    Content-Type: multipart/mixed;\r
    \tboundary="_000_SYNTH_"\r
    \r
    --_000_SYNTH_\r
    Content-Type: multipart/alternative; boundary="_001_ALT_"\r
    \r
    --_001_ALT_\r
    Content-Type: text/plain; charset="us-ascii"\r
    \r
    Synthetic placeholder body.\r
    --_001_ALT_--\r
    \r
    --_000_SYNTH_\r
    Content-Type: application/x-microsoft-rpmsg-message; name="message.rpmsg"\r
    Content-Disposition: attachment; filename="message.rpmsg"\r
    Content-Transfer-Encoding: base64\r
    \r
    \(b64)\r
    --_000_SYNTH_--\r

    """
    let mimeData = Data(mime.utf8)
    check(RPMSG.isProtectedMIME(mimeData), "synthetic protected MIME detected")
    check(RPMSG.extract(fromMIME: mimeData) == payload, "rpmsg part extracted and base64-decoded byte-exact")
    let plain = Data("MIME-Version: 1.0\nContent-Type: text/plain\n\nhello\n".utf8)
    check(!RPMSG.isProtectedMIME(plain) && RPMSG.extract(fromMIME: plain) == nil, "plain MIME → not protected")
    let byNameOnly = Data("""
    Content-Type: multipart/mixed; boundary=b1

    --b1
    Content-Type: application/octet-stream
    Content-Disposition: attachment; filename="message_v2.rpmsg"
    Content-Transfer-Encoding: base64

    \(Data("abc".utf8).base64EncodedString())
    --b1--

    """.utf8)
    check(RPMSG.extract(fromMIME: byNameOnly) == Data("abc".utf8), "rpmsg found by filename (LF line endings)")

    // Bridge (only if built; never fails the suite when vendor/mip is absent).
    switch ProtectedContentService.bridgeStatus() {
    case .failure(let e):
        print("  - SKIPPED bridge checks: \(e) (run scripts/build-mipbridge.sh)")
    case .success(let s):
        check(!s.sdkVersion.isEmpty && s.sdkVersion != "?", "bridge loads via dlopen, ABI ok, MIP SDK \(s.sdkVersion)")
        // Offline: an empty engine identity is rejected before any MipContext / network work.
        let svc = ProtectedContentService(configuration: .init(clientId: "00000000-0000-0000-0000-000000000000"))
        var err: MIPBridgeError?
        do { _ = try await svc.decrypt(rpmsg: Data([1, 2, 3]), userEmail: "", tokens: { _ in "" }) }
        catch let e as MIPBridgeError { err = e } catch {}
        check(err == .badArgument, "bridge rejects bad arguments offline (\(err.map(String.init(describing:)) ?? "no error"))")
        svc.shutdown()
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                                                                        includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("niivo-mip-") && !NoDiskPlaintextGuard.nonEmptyFiles(in: $0).isEmpty } ?? []
        check(leftovers.isEmpty, "no non-empty MIP state left in temp after shutdown")
    }
}
