# Purview decryption via the MIP SDK (spike, 2026-11-19)

Goal: show sensitivity-label-encrypted (RMS-protected) mail and meeting bodies in niivo mail, and drive
copy/print/forward/reply from the item's **licence** rights, as Outlook does. Status: built, **wired into the
reader** (reading pane, message windows, calendar inspector) and tested offline with a stub bridge; **the live decrypt
has NOT been run yet** (see "Testing with your encrypted message" below). The app setting defaults **off**; switch it on
in Settings → Mail → Protected messages.

## SDK

| | |
|---|---|
| Version | **1.18.148** (released 2026-09-04; current supported line; 1.17 ends support 2026-12-04) — [release history](https://learn.microsoft.com/information-protection/develop/version-release-history#release-history) |
| Source | https://aka.ms/mipsdkbins → Download Center id 108481 ([setup page](https://learn.microsoft.com/information-protection/develop/setup-configure-mip#configure-your-client-workstation): "macOS, all supported versions, C++ .zip, Xcode 13+") |
| Downloaded | `https://download.microsoft.com/download/966278f4-ad94-4db3-8503-d5bf02738e51/mip_sdk_{file,protection,upe}_macos_1.18.148.zip` into `vendor/mip/dl/` |
| SHA-256 `mip_sdk_file_macos_1.18.148.zip` | `38d0d6c814ed640012924b8c5cade282b6f34032578ab47dcd2efb7774c06520` (1.1 GB; contains File + Protection + Policy dylibs) |
| SHA-256 `mip_sdk_protection_macos_1.18.148.zip` | `eede8cb781df75985326d5402db003e20d6ed395b5c25b0628c3e8ab2cb1ed42` |
| SHA-256 `mip_sdk_upe_macos_1.18.148.zip` | `894a9f9eb2fd9d4a1d24232642f2544236732ae95513201402808f9890efd0b3` |
| Extracted | `vendor/mip/sdk/` = file zip's `include/`, `bins/release/arm64/`, licence files (arm64 only; x86_64 and debug not extracted) |
| Signing | dylibs signed by Microsoft (TeamIdentifier `UBF8T346G9`), `minos 11.10` |

`vendor/` is gitignored. To reproduce on another Mac: download the three zips from the URLs above, verify the
hashes, then `unzip -q vendor/mip/dl/mip_sdk_file_macos_1.18.148.zip 'bins/release/arm64/*' 'include/*' '*.txt' '*.rtf' -d vendor/mip/sdk`
and `scripts/build-mipbridge.sh`.

## Which API decrypts protected mail

* The File SDK decrypts **message.rpmsg** (and `message_v2..v4.rpmsg` for Purview Message Encryption) through the
  *inspection* API: `FileHandler::InspectAsync()` → `mip::MsgInspector` → `GetBody()`, `GetBodyType()` (TXT/HTML/RTF),
  `GetAttachments()`. "The SDK consumer must extract the message.rpmsg file and pass it to the inspection API."
  Output is byte streams, not a file; `RemoveProtection()` doesn't accept rpmsg —
  [concept-email](https://learn.microsoft.com/information-protection/develop/concept-email#file-sdk-operations-for-rpmsg-files).
  So we need **just the rpmsg attachment**, not the full MSG/MIME. (A full `.msg` would go through
  `RemoveProtection`, but Graph gives MIME (`$value`), not MSG, so that path doesn't apply.)
* `container_decryption_option = Top`: decrypt only the message, not its attachments (same page).
* Protected **meeting invites**: "encrypted meeting invites can be opened in the same way as encrypted email" —
  [sensitivity-labels-meetings](https://learn.microsoft.com/purview/sensitivity-labels-meetings). We reuse the same
  detector on `/events/{id}/attachments`. **UNVERIFIED.**
* How Graph surfaces the rpmsg to a third-party app (fileAttachment vs only in MIME, exact content type
  `application/x-microsoft-rpmsg-message`, item class `IPM.Note.rpmsg.Microsoft Exchange`, MIME
  `Content-Class: rpmsg.message`) is **not documented on Learn — UNVERIFIED**. `RPMSGFetcher` tries
  `/attachments` (name or content type) then `$value` MIME, and the probe reports which path worked.
  Graph references: [attachment-get `$value`](https://learn.microsoft.com/graph/api/attachment-get?view=graph-rest-1.0),
  [MIME `$value`](https://learn.microsoft.com/graph/outlook-get-mime-message).

## Rights

* `FileHandler::GetProtection()` → `ProtectionHandler::GetRights()` / `AccessCheck()` / `GetOwner()` (headers
  `mip/protection/protection_handler.h`, names in `mip/protection/rights.h`: VIEW, EDIT, DOCEDIT, EXTRACT,
  AUDITEDEXTRACT, PRINT, EXPORT, FORWARD, REPLY, REPLYALL, OWNER, OBJMODEL, VIEWRIGHTSDATA, EDITRIGHTSDATA, COMMENT).
* UI guidance: OWNER → everything; PRINT/EXPORT/EXTRACT (copy *and screenshots*)/EDIT gate their controls —
  [concept-accesscheck](https://learn.microsoft.com/information-protection/develop/concept-accesscheck#scenarios).
* Mapping (`UsageRights.fromLicence`, CalendarCore/LicenceRights.swift): 1:1 onto `UsageRights`; OWNER → all;
  **AUDITEDEXTRACT ignored** (no audited-extract UX); an empty licence is an **explicit empty set**, never nil, so it
  can't fall through to the label's broader Graph rights.
* `LicenceRightsStore.shared` is the production `ItemRightsProvider` (in-memory, bounded, cleared on sign-out/wipe).
* Whether `GetProtection()` is non-null for an rpmsg inspection handler is **UNVERIFIED**. If null, the bridge
  reports `rights_source = NONE` and we grant **VIEW only** (proven by the successful decrypt).
* Also available since 1.18: `FileEngine::GetRightsForLabelId()` (rights for a label without opening content) —
  [concept-rights-for-label](https://learn.microsoft.com/information-protection/develop/concept-rights-for-label). Not used yet.

## Auth

* `mip::AuthDelegate::AcquireOAuth2Token(identity, OAuth2Challenge{authority, resource, scope, claims}, token)`;
  the SDK calls it, we never do — [concept-authentication-cpp](https://learn.microsoft.com/information-protection/develop/concept-authentication-cpp).
* Resources/scopes (app registration `<your-client-id>`, checked read-only with `az` on 2026-11-19):
  * Microsoft Rights Management Services `00000012-0000-0000-c000-000000000000`, `user_impersonation`
    (SPNs include `https://aadrm.com`, `https://api.aadrm.com`) — **admin-consented (AllPrincipals)**.
  * Microsoft Information Protection Sync Service `870c4f2e-85b6-4d43-bdda-6ed9a579b725`, `UnifiedPolicy.User.Read`
    (`https://syncservice.o365syncservice.com`) — **admin-consented (AllPrincipals)**.
  * Setup docs for both: [setup-configure-mip](https://learn.microsoft.com/information-protection/develop/setup-configure-mip#register-a-client-application-with-microsoft-entra-id).
* We use a **protection-only engine** by default (`FileEngine::Settings::SetProtectionOnlyEngine(true)`), so only the
  RMS token should be needed; `--policy-engine` on the probe loads the label policy too (needs the sync token).
* MSAL scope chosen per challenge (`MIPTokenRequest.msalScopes`): SDK scope if given, else
  `https://aadrm.com/user_impersonation` / `https://syncservice.o365syncservice.com/UnifiedPolicy.User.Read`, else
  `<resource>/.default`. Exact audience RMS expects (aadrm.com vs api.aadrm.com) is **UNVERIFIED**.
* A non-empty `claims` (CA / label-based CA challenge) fails with `claimsChallenge`; interactive re-auth is not wired.

## Cache and the no-plaintext rule

* `MipConfiguration(..., CacheStorageType::InMemory)` **and** `FileProfile::Settings(..., InMemory)`,
  `SetCanCacheLicenses(false)` — [concept-cache-storage](https://learn.microsoft.com/information-protection/develop/concept-cache-storage).
  `OnDiskEncrypted` is wired (`MIPCacheConfig.resolve`) only for **managed Macs with admin opt-in**
  (`ProtectedContentAllowEncryptedLicenceCache`); Learn itself says that cache is anti-browsing, not anti-adversary.
  BYOD is always in memory. Plaintext `OnDisk` is never offered.
* The SDK insists on a state path even in memory. Smoke test (1.18.148, offline): it created only
  `<state>/mip/logs/mip_sdk.miplog` (0 bytes). The bridge installs a no-op `LoggerDelegate`, turns off telemetry local
  caching (`DiagnosticConfiguration.isLocalCachingEnabled = false`, minimal telemetry), and audit discovery is off.
* `NoDiskPlaintextGuard`: each context gets a fresh 0700 temp dir; after every SDK call any **non-empty** file there is
  deleted and the call fails closed (`plaintextOnDisk`); the dir is removed on shutdown.
* The bridge never calls `GetDecryptedTemporaryFile*`/`Stream*`; the body comes back in a malloc'd buffer that
  `nmb_result_free` zeroes. Swift `String`s holding the HTML can't be zeroed — they live only in `ProtectedBodyStore`
  (memory) and are dropped on reset. Graph fetches use an ephemeral `URLSession` with no URL cache.
* Decrypted HTML goes through `HTMLSanitizer` before `ProtectedBodyView` → `MailHTML.document` → JS-off WKWebView. It is
  never handed to `MailStore` (which already refuses bodies for protected labels).

## How it's linked (and why not SwiftPM)

* `Sources/MIPBridgeABI/include/niivo_mipbridge.h`: a small **pure-C ABI** (`nmb_*`, ABI version 1). `MIPBridgeABI` is a
  header-only SwiftPM C target (types only, no linking) so Swift sees the exact struct/enum layout.
* `native/mipbridge/niivo_mipbridge.cpp`: the implementation over the C++ File SDK.
* `scripts/build-mipbridge.sh` builds it with Command Line Tools `clang++` into `vendor/mip/lib/libniivo_mipbridge.dylib`
  (rpath `@loader_path/../sdk/bins/release/arm64`), exporting only `nmb_*`.
* `Sources/ProtectedContent` (Swift 6, new SwiftPM target) **dlopen**s it at runtime (`MIPLoader.swift`):
  `NIIVO_MIPBRIDGE` env → app bundle `Contents/Frameworks` → `vendor/mip/lib` of the checkout. Missing → `bridgeUnavailable`.
* Why not link it into a SwiftPM target: `libmip_file_sdk` pulls ~17 `@rpath` dylibs (glib, gmime, gsf, gpgme,
  OpenSSL…); linking would make `CompliantCalendar`, `OfficeMCP` and `CoreSelfTest` fail to build on a checkout without
  `vendor/` (gitignored) and fail to *launch* until `bundle.sh` embeds the dylibs. With dlopen, **no existing product
  has an LC_LOAD_DYLIB for MIP**, everything builds with plain `swift build`, and the feature is simply unavailable
  when the dylib is absent. No Xcode project / xcframework was needed. `xcode-select` was not changed.
* Bundling later: copy `libniivo_mipbridge.dylib` + the 4 `libmip_*` + their dependency dylibs into
  `Contents/Frameworks` and adjust the bridge rpath. Hardened-runtime library validation with Microsoft-signed dylibs
  inside our (differently signed) app is **UNVERIFIED** (may need `com.apple.security.cs.disable-library-validation`).

## Targets / files

| Path | What |
|---|---|
| `Sources/MIPBridgeABI/` | C ABI header (types only, SwiftPM C target) |
| `native/mipbridge/` | C++ implementation, export list |
| `scripts/build-mipbridge.sh` | builds the bridge dylib |
| `Sources/ProtectedContent/` | `ProtectedContentService.decrypt(rpmsg:userEmail:tokens:)`, `MIPCacheConfig`, `NoDiskPlaintextGuard`, `RPMSG` detector (attachments + MIME), `RPMSGFetcher` (Graph) |
| `Sources/CalendarCore/LicenceRights.swift` | `UsageRights.fromLicence`, `LicenceRightsStore` (`ItemRightsProvider`) |
| `Sources/MIPProbe/` | CLI live probe (prints lengths/rights only) |
| `Sources/ProtectedContent/ProtectedItemOpener.swift` | testable core: bridge check → fetch → decrypt → outcome (`decrypted` / `notPermitted` / `failed(…)`), licence → `LicenceRightsStore`; `ProtectedPolicy` (rpmsg detection for unlabelled IRM mail) |
| `Sources/CompliantCalendar/ProtectedContentCoordinator.swift` | app side: states → `ProtectedBodyStore`, sanitising, policy refresh before the body is shown, `[MIP]` logs (setting off by default) |
| `Sources/CompliantCalendar/MailReader.swift` `ProtectedReaderBody` | reader hook (pane + message windows): `.task` → `open`, Try again / Grant access… |
| `Sources/CompliantCalendar/ProtectedBody.swift` | states view + `ProtectedMessagesSettings` (the toggle) |
| `Sources/CoreSelfTest/ProtectedOpenTests.swift` | stub-bridge tests: rights → policy, no-VIEW, failures, never persisted / indexed, AI without EXTRACT |
| `Sources/CompliantCalendar/Auth.swift` | +`silentToken(scopes:)`, +`username` (additive) |
| `scripts/devtoken.py --mip` | browser PKCE → JSON with Graph + RMS + sync tokens |
| `Sources/CoreSelfTest/ProtectedContentTests.swift` | offline tests |

## How it's wired in the app

1. `AppModel.compliance = CachedLabelPolicyEngine(itemRights: LicenceRightsStore.shared)` — mail and calendar share it,
   and so does `MailStore`'s persist rule. `AppModel.goLive` creates the `ProtectedContentCoordinator`; sign-out, app
   lock and switching the setting off call `reset()` (bodies, licence rights and the MIP context go; a decrypt still in
   flight is dropped).
2. A message is "protected" when its label has encryption (`ContentPolicy.bodyIsProtected`), or — unlabelled
   Encrypt-only / Do Not Forward — when the full message lists a `message.rpmsg` attachment
   (`ProtectedPolicy.awaitingLicence`: VIEW only, capture shielded, not cached, until the licence is known).
3. `ReaderBody` → `ProtectedReaderBody` (reading pane **and** pop-out message windows) runs `.task` → `coordinator.open`.
   Calendar: `EventInspector` does the same with `kind: .event` (UNVERIFIED).
4. `ProtectedItemOpener.open`: bridge loadable? (no → fallback, **no Graph call**) → `RPMSGFetcher` (attachment, then
   MIME `$value`) → `ProtectedContentService.decrypt` → outcome. VIEW (or OWNER) → body; else "You don't have rights to
   view this message".
5. `finish`: licence rights → `LicenceRightsStore` → `onRightsChanged` re-derives the pane's and the message windows'
   `ContentPolicy` → **then** the sanitised HTML is published to `ProtectedBodyStore` (memory only). So EXTRACT drives
   copy *and* the capture shield, PRINT/EXPORT drive ⌘P/⌘S, REPLY/REPLYALL/FORWARD the buttons (pane and pop-out), and
   AI follows `ContentPolicy.aiMayReadContent` (VIEW+EXTRACT) and the AI gate.
6. Never stored: the decrypted HTML is never put into `ReaderState.body`, `MailMessage.body`, `MailStore` (an item with
   a licence is `allowOfflineDetails = false`) or the search index, and it is **not given to AI at all in this build** —
   even with EXTRACT the AI features only see what Graph returns (the protected placeholder), not the decrypted body.

States: decrypting (spinner) · decrypted · "You don't have rights to view this message" · "Couldn't open… Try again"
(network / licence / Graph 5xx) · "Rights Management needs you to sign in — Grant access…" (silent RMS token failed) ·
"Protected-message support (MIP SDK) isn't installed in this build" (bridge missing) and other unavailable states, all
with **Open in Outlook**.

## Consent / scopes

* The SDK asks for a token through the bridge's auth callback; the app answers with MSAL **silently**
  (`Auth.silentToken(scopes:)`): `https://aadrm.com/user_impersonation` (Azure Rights Management Services,
  `00000012-0000-0000-c000-000000000000`). Already **admin-consented** on the app registration — no tenant change.
  MSAL gets it off the existing refresh token, so normally there's no prompt.
* If the silent call fails (interaction required, MFA step-up), the reader shows **Grant access…** →
  `Auth.grantProtectionAccess()` = interactive MSAL for the RMS scope alone (same account; MSAL can't mix Graph and RMS
  in one request), then retries.
* The rpmsg is fetched with the existing **Mail** Graph token (`Mail.ReadWrite`, already consented).
* The sync service scope (`UnifiedPolicy.User.Read`) is only needed with a full policy engine; the app uses the
  protection-only engine.
* Conditional-Access claims challenges are not handled (→ "Open it in Outlook").

## Testing with your encrypted message

Pre-reqs and the build you'll actually run:

* Build the bridge in the checkout the app is built from: `scripts/build-mipbridge.sh` →
  `vendor/mip/lib/libniivo_mipbridge.dylib`. `scripts/bundle.sh` does **not** copy it (or the `libmip_*` / glib … dylibs)
  into `Contents/Frameworks`; the app finds it through the checkout path compiled in (`#filePath`), so it only works on
  the Mac that built it. `NIIVO_MIPBRIDGE=/abs/path/libniivo_mipbridge.dylib` overrides.
* Live mail needs the **signed** bundle (ad-hoc builds run fixtures only: MSAL keychain -34018; the `CC_TOKEN_FILE`
  dev path starts the calendar only, so there's no coordinator). The signed bundle is signed with
  `--options runtime` (hardened runtime) and **without** `com.apple.security.cs.disable-library-validation`, so
  library validation will most likely refuse to `dlopen` the ad-hoc-signed bridge and the Microsoft-signed SDK dylibs
  (different team). Expected symptom: Settings → Mail → Protected messages shows
  `Not available in this build (bridge-unavailable(dlopen))` (vs `bridge-unavailable(not-found)` when the dylib isn't
  there at all, `…(abi)` for a stale bridge). **UNVERIFIED** — not run here. Two ways forward, your call (neither is
  done in this change): (a) for local testing only, add `com.apple.security.cs.disable-library-validation` to the
  entitlements `bundle.sh` writes; (b) copy the bridge + SDK dylibs into `Contents/Frameworks` and re-sign them with
  your Developer ID (same team → passes library validation; check the MIP SDK licence on re-signing redistributables).
* To see the `[MIP]` log lines, launch the signed app's binary from Terminal:
  `"build/niivo mail.app/Contents/MacOS/CompliantCalendar" 2>&1 | grep '\[MIP\]'` (Finder launches drop stderr).

1. Settings → Mail → **Protected messages** → switch on "Decrypt protected messages on this Mac (MIP SDK)". The row
   below should say `Loaded (SDK 1.18.148)`. (Equivalent: `defaults write <bundle-id> ProtectedContentDecryptEnabled
   -bool true`.)
2. Open your encrypted test message (label with encryption, or Encrypt / Do Not Forward). Expect "Protected message —
   decrypting…", then the body.
3. Check the rights against what the label grants you:
   * no EXTRACT → no text selection / ⌘C, and the reader is black in screenshots / screen sharing (capture shield);
   * Do Not Forward → Forward disabled (pane and ⌘O window), Reply / Reply all enabled;
   * no PRINT → ⌘P beeps;
   * AI strip: metadata only (subject withheld) unless the licence has EXTRACT.
4. Repeat in a pop-out window (⌘O / double-click). Switch the setting off → the body disappears ("turned off").
5. Logs go to stderr (run the dev build from Terminal to see them); content-free lines like
   ```
   [MIP] decryption enabled by the user
   [MIP] item#3f2a9c1d open (messages, own mailbox)
   [MIP] item#3f2a9c1d fetch ok via attachment, rpmsg 48213 bytes
   [MIP] item#3f2a9c1d licence: rights VIEW,REPLY,REPLYALL, source licence, body 5120 bytes, token calls 1
   [MIP] item#3f2a9c1d decrypt ok, html 5120 bytes, rights VIEW,REPLY,REPLYALL
   ```
   or `fetch failed: …` / `failed: needs-access(auth(stage 2))` / `failed: bridge-unavailable`. `item#…` is a hash, not
   the Graph id; no subject, address, owner or body is ever logged.

What to look for / how to read it:
* `source viewImpliedByDecrypt` = the SDK gave no licence object for the rpmsg (UNVERIFIED item 4): rights are then
  **VIEW only**, so Reply / Forward are disabled even if the label allows them. That's the fail-closed design, not a bug —
  tell me and we'll look at `GetProtection()` on the inspector.
* `fetch ok via mime` instead of `attachment` answers UNVERIFIED item 1.
* `needs-access` → press Grant access…; if it persists, the RMS audience is wrong (UNVERIFIED item 3).
* `unsupported-body` → the message body is RTF (item 5).
* Unlabelled encrypted mail only triggers if Graph lists `message.rpmsg` in its attachments (UNVERIFIED).

The standalone probe still works for a no-UI check:
`scripts/build-mipbridge.sh && swift build --product MIPProbe && .build/debug/MIPProbe --self-check`, then
`python3 scripts/devtoken.py --mip <tenantId> <your-client-id> /tmp/niivo-mip-tokens.json <upn>`,
`.build/debug/MIPProbe --tokens /tmp/niivo-mip-tokens.json --message '<message-id>' --client-id <your-client-id>`, `rm -P /tmp/niivo-mip-tokens.json`.

## Label policy, label on send, encrypt on send, attachments (2026-11-20)

Bridge additions **within ABI 1** (new symbols only; `nmb_create`/`nmb_inspect_rpmsg`/`nmb_result` unchanged; Swift
resolves them with `dlsym` and treats them as optional — an older bridge simply means the Graph fallback):

| Symbol | What |
|---|---|
| `nmb_policy_load` / `nmb_policy_free` | Lazily adds a **Policy SDK** `PolicyProfile` + `PolicyEngine` (InMemory, same `MipContext` and token callback) → `GetDefaultSensitivityLabel("email")`, `IsLabelingRequired("email")`, `IsDowngradeJustificationRequired()`, tenant id, per-label protection kind (`HasDoNotForwardProtection` / `HasEncryptOnlyProtection` / `HasAdhocProtection` / `HasRightsManagementPolicy`, 1.18+) |
| `nmb_label_compute` / `nmb_label_plan_free` | `PolicyHandler::ComputeActions` on an "email" `ExecutionState` (new label, existing metadata, Privileged/Standard, justification) → metadata to add/remove, needs-justification (`JustifyAction`), applies-protection; with `commit` also `NotifyCommittedActions` (documented: "sends an audit event") |
| `nmb_inspect_rpmsg_attachments` / `nmb_attachments_free` | Second inspection of the rpmsg → `MsgInspector::GetAttachments()` (`GetBytes()` only, never `GetStream`/temp files), licence rights; buffers zeroed on free |

* The policy engine needs the **policy-sync token** (`https://syncservice.o365syncservice.com/UnifiedPolicy.User.Read`,
  already admin-consented) through the same MSAL silent path (`MIPTokenRequest.policySync`). It's loaded only when the
  bridge is present **and** protected messages are switched on (Settings → Mail → Protected messages), async, never
  blocking a composer; otherwise `LabelPolicySettings.graphFallback` (no default, nothing mandatory, no justification —
  nothing invented).
* Meetings: the SDK headers name only the "email" content format; Outlook labels meetings with email-scoped labels, so the
  mail default is used for new meetings. **UNVERIFIED** for tenants with a calendar-specific default.
* **Justification**: Outlook's three choices ("Previous label no longer applies", "Previous label was incorrect", "Other").
  The text goes only to `nmb_label_compute(commit: 1)` after the send is queued; it is never logged or stored. Without the
  bridge (Graph fallback) the policy doesn't ask, so nothing is recorded — niivo doesn't pretend to audit.
  **UNVERIFIED** that the commit's audit event reaches Purview with audit *discovery* off (we pass `false`).
* **msip_labels** (`LabelMetadata`, CalendarCore/LabelPolicy.swift), per
  [concept-mip-metadata#email](https://learn.microsoft.com/information-protection/develop/concept-mip-metadata#email):
  `MSIP_Label_<guid>_Enabled=true; …_SetDate=<ISO 8601>; …_Method=Privileged|Standard; …_SiteId=<tenant>; …_ContentBits=0`,
  "; "-delimited, lower-case GUIDs. SiteId is mandatory → no tenant, no stamp. ContentBits states what niivo really did
  (no marking text inserted, no encryption) = 0. ActionId was removed in SDK 1.8 and isn't written. Written as the
  PS_INTERNET_HEADERS `msip_labels` named property on the draft (mail) and on the event POST (new meetings), **on by
  default** — the composer shows a label, so it must leave the Mac. Kill switch: `PurviewLabelStampDisabled` (defaults).
  The old `MailSettings.writeLabelProperty` stamp only applies when no `labelHeader` was computed. **UNVERIFIED** live
  that Exchange emits it as the header on send and Purview/Outlook read it back (the reader round-trip is tested).

### Known gaps (label policy)

* The policy features are **inert by default**: they need the bridge dylib (`scripts/build-mipbridge.sh`, not bundled)
  **and** Settings → Mail → Protected messages switched on (default off). Otherwise Graph fallback.
* The stamp is **hand-built** (`LabelMetadata.build`); `nmb_label_compute`'s metadata output is only used for the audit
  commit, not written to the item.
* The Purview commit fires 12 s after queueing (undo window + slack); an Undo cancels it. **Send Later** commits then
  too, before the message actually leaves. Every send under the SDK policy emits an audit event.
* A reply / forward of encrypted mail (labelled or unlabelled Do Not Forward / Encrypt-Only) is refused (it would go out
  in the clear).
* SDK content formats are only "file" and "email" (common_types.h), so meetings use the mail policy, mandatory included.
* Group posts can't carry a label (Graph), so they aren't gated here.

### Encrypt on send — honest fallback (why)

* MIP SDK "doesn't support any publishing scenarios for message.rpmsg files"
  ([concept-email](https://learn.microsoft.com/information-protection/develop/concept-email#file-sdk-operations-for-rpmsg-files)).
* It *can* label + protect a whole **.msg** (and **.eml** since 1.17) — but niivo has no MSG writer, the protected EML's
  output format is not documented, and whether Graph `sendMail` with that MIME keeps `Content-Class: rpmsg.message` +
  `message.rpmsg` so Outlook opens it is undocumented. None of it can be checked without RMS against the tenant.
* So a label that encrypts (template, Do Not Forward, Encrypt-Only, ad hoc — policy kind, else Graph `hasProtection`)
  **blocks send** ("“X” encrypts. niivo can't encrypt mail yet — send it from Outlook.") and blocks saving a new meeting
  with it. A reply whose floor is an encrypting label is blocked the same way. Nothing is ever sent labelled-but-clear.
* Next probe (not done): build an EML → `FileHandler::SetLabel` + `CommitAsync` with `enable_msg_file_type` → inspect the
  output → `POST /me/sendMail` (MIME, base64) to yourself → open in Outlook.

### Attachments of protected mail / invites

* "Show protected attachments" under a decrypted body (reading pane, message windows, calendar inspector) → refetch the
  rpmsg → `nmb_inspect_rpmsg_attachments`. Kept in `ProtectedAttachmentStore` (memory; cleared on reset).
* Rights (`ProtectedAttachmentGate`): VIEW → in-memory preview only (PDFKit / NSImage / text, copy and drag-out refused);
  **Save…** only with EXPORT or EXTRACT (OWNER implies both). No QuickLook (needs a file URL), no Open With.
* Container option stays `Top`, so an attachment that is itself protected comes back still encrypted and is flagged
  "open it in Office". **UNVERIFIED** that `GetAttachments()` is populated under `Top` (if empty, switch a second engine
  to `Msg`).
* Unlabelled protected **invites**: `RPMSGFetcher.listsRPMSG` (names/content types only) once per event when decryption
  is on; a hit → `ProtectedPolicy.awaitingLicence` → the normal decrypt path. **UNVERIFIED** Graph shape for events.

## Licence / redistribution

* Headers/samples are MIT; **binaries** are under "Microsoft Software License Terms — MIP SDK" (`LicenseTerms.rtf`):
  develop/test use is free; you may distribute only files on **REDIST.TXT**, adding significant functionality, with
  end-user terms at least as protective, indemnifying Microsoft, and the app must "**directly call into the software's
  audit API**" (§2.b.ii). "By using the software, you accept these terms" — the download/extract for this spike did
  that on Ryan's behalf.
* **Gap:** `redist.txt` lists only `libmip_core`, `libmip_file_sdk`, `libmip_protection_sdk`, `libmip_upe_sdk` for
  macOS, but `libmip_file_sdk` loads glib/gio/gobject/gmodule/gthread, gmime, gsf, gpgme/assuan/gpg-error, intl,
  idn2, unistring, pcre2, libssl/libcrypto (see `ThirdPartyNotice.txt`). Shipping those needs clarification (or a
  Protection-SDK-only design, which needs our own rpmsg parser).
* **Audit:** we currently disable audit discovery; §2.b.ii requires calling the audit API for distributed apps.
  Turn on discovery (`isAuditDiscoveryEnabled`) before any distribution.
* **IPIA:** a signed Information Protection Integration Agreement is required before releasing an MIP app publicly
  (not for internal use) — [setup-configure-mip#request-an-ipia](https://learn.microsoft.com/information-protection/develop/setup-configure-mip#request-an-information-protection-integration-agreement-ipia).
* Proxies on macOS: transparent only — [concept-mip-proxies](https://learn.microsoft.com/information-protection/develop/concept-mip-proxies).

## UNVERIFIED (needs the live probe)

1. Graph delivery shape of the rpmsg (attachment vs MIME, content type) for mail and for events.
2. Protection-only engine is enough for rpmsg inspection with only the RMS token.
3. RMS token audience/scope (`https://aadrm.com/user_impersonation`) accepted.
4. `GetProtection()` non-null on an inspection handler (else VIEW-only rights).
5. Body type in practice (HTML vs RTF; RTF is reported as unsupported).
6. Nothing but empty files in the state dir during a real online decrypt (the guard enforces it either way).
7. Library validation when bundled in the signed app.
8. Policy engine load with the sync token; default / mandatory / justification values match the tenant policy.
9. `NotifyCommittedActions` audit (with justification) visible in Purview Activity explorer.
10. `msip_labels` named property → header on send; read back by Outlook / Purview; on meetings.
11. `MsgInspector::GetAttachments()` content under container option `Top`.
12. Unlabelled protected invites expose `message.rpmsg` on `/events/{id}/attachments`.
