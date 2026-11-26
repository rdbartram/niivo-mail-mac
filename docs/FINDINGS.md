# Spike findings — Purview-aware native Office for macOS (calendar first)

Date: 2026-11-18 · Machine: macOS 27.0.1, Apple Silicon, **Command Line Tools only (no Xcode)**, Swift 6.4

Each claim is tagged **VERIFIED** (run or tested here), **DOCS** (confirmed in Microsoft Learn, not run against a tenant) or **UNVERIFIED** (an assumption that needs a tenant test).

## 1. Stack decision

| Layer | Choice | Why |
|---|---|---|
| UI | SwiftUI on macOS 15+, with AppKit where needed (`NSWindow.sharingType`) | Native, fast, and the right look. The grid is drawn in one `Canvas` pass, with no per-cell views. |
| Auth | MSAL for ObjC 2.18.1 via SwiftPM (binary xcframework) | The only supported Entra client for Apple platforms, and the route to the Enterprise SSO extension / Conditional Access. |
| Data | Microsoft Graph v1.0 (beta only for the label list) | Calendars, shared and delegated access, delta sync. |
| Offline | SQLite (system `libsqlite3`, WAL) with AES-GCM sealed payloads, key in Keychain | Local-first: the UI reads only from the store. No third-party dependency. |
| Purview | `ComplianceEngine` protocol. Today: `CachedLabelPolicyEngine` (Graph label definitions, evaluated locally). Next: `MIPPolicyEngine` (MIP C++ SDK through an ObjC++ shim). | The MIP macOS binaries can't be fetched without a licence click-through (see §3). |

**Rejected:** Catalyst/Electron (not "best native"), SwiftData (no control over encryption at rest or index-only range scans), Microsoft Graph SDK for Swift (no maintained official one; plain `URLSession` is less code than the Kiota one).

## 2. Verified results

- **VERIFIED:** `swift build` builds everything, including MSAL, with CLT only. `scripts/bundle.sh` assembles an ad-hoc-signed `.app` with bundle ID `<bundle-id>` and the URL scheme `msauth.<bundle-id>`.
- **VERIFIED:** 52/52 self-checks pass (`swift run CoreSelfTest`):
  - store (in-memory **and** file-backed: reopen, mode 0600, no plaintext subject on disk, wrong key can't read)
  - compliance rules, MIP header parsing, time parsing, overlap layout
  - snapshot sync, offline outbox (including two edits to one event coalescing into one PATCH with no false conflict), If-Match conflict (server wins)
  - sanitising before disk
- **VERIFIED, against canned Graph JSON only** (a `URLProtocol` stub driving the real `GraphCalendarService`):
  - DTO decoding, delta paging (nextLink → deltaLink), `@removed`, deltaLink persistence
  - `$batch` label read where one sub-response fails (this used to throw; fixed)
  - 410 on a stale deltaLink → full round restarts
  - The JSON shapes come from the docs. **No request has reached a real tenant.**
- **VERIFIED — performance** (`swift run -c release CoreSelfTest --bench`, M-series):
  - insert 20,000 events (each sealed): **208 ms**
  - load one week with 672 events (deliberately dense; decrypt and decode): **p50 5.2 ms / p95 5.6 ms**. A normal week of about 40 events loads in **0.5 ms** in the running app.
  - overlap layout for 7 days: **0.55 ms**
- **VERIFIED:** the app launches in fixture mode. Screenshots are in `docs/img/`.
- **VERIFIED (CoreGraphics capture only) — screen-capture blocking:**
  - Launched without the override and with a Highly Confidential item selected, the window reports `kCGWindowSharingState = 0`, and `screencapture -l <windowID>` fails with "could not create image from window".
  - With the fixture-only `CC_DEMO_ALLOW_CAPTURE=1` the state is 1 and capture works (that's how the screenshots were taken).
  - **ScreenCaptureKit-based tools were not tested.**
- **NOT TESTED in the UI:** the offline drag demo in the README. The same flow is covered by self-tests at engine level only.

## 3. Purview / MIP SDK

- **DOCS:** the MIP SDK supports macOS as a C++ `.zip` (Policy, Protection and File SDKs), requiring Xcode 13+.
- **VERIFIED:** `aka.ms/mipsdkbinaries` redirects to a Microsoft Download Center page that returns 403 to scripted access. NuGet `Microsoft.InformationProtection.Policy 1.18.148` contains only headers (`build/native/include/mip_cc`) plus Windows and Linux binaries, **no macOS dylibs**. Ryan has to download the zip and accept the licence himself.
- **DOCS — permissions the MIP SDK needs** (delegated; no admin consent required, per Learn):
  - Azure Rights Management Services → `user_impersonation`
  - Microsoft Information Protection Sync Service → `UnifiedPolicy.User.Read`
- **What MIP adds over the Graph fallback:**
  1. Content-marking text (header, footer, watermark) through `ComputeActions`. Graph's label list doesn't return marking text, so in live mode those fields are empty until MIP is in.
  2. Real usage rights (`AccessCheck(Copy/Export/Print)`) rather than a conservative app-side rule.
  3. **Decrypting** label-encrypted invite bodies. Today these show "open in Outlook".
  4. Discovery audit events, so the app appears in Purview Activity explorer (`CreatePolicyHandler(isAuditDiscoveryEnabled: true)`).
- The integration plan is written up in `Sources/CalendarCore/MIPPolicyEngine.swift`.

## 4. Graph facts that shaped the design

- **DOCS:** `event: delta` exists **only for a mailbox's primary calendar** (`/me/calendarView/delta`, `/users/{id}/calendarView/delta`). Secondary and shared-in calendars use a windowed `calendarView` snapshot, replaced atomically in the store. Delegated mailboxes' primaries use delta.
- **DOCS:** delta on calendarView can't `$select` or `$expand`. The label metadata (an extended property) is therefore fetched with `$batch` (20 per request) for changed items only. Snapshot requests `$expand` it inline.
- **DOCS:** "Labeling meeting invites with Graph APIs isn't supported." Read-only labels are fine for a viewer. Applying a label from our app would need MIP plus the Outlook-compatible metadata write (out of scope).
- **UNVERIFIED — where the label lives on an event.** We read `String {00020386-0000-0000-C000-000000000046} Name msip_labels` (the `msip_labels` internet-header named property, confirmed for *mail*). **Verify against a labelled meeting** in a tenant with the Meetings label scope enabled (requires E5). If it's elsewhere, change `MIPMetadata.extendedPropertyId` in one place.
- **DOCS:** the label list is `GET /beta/me/security/informationProtection/sensitivityLabels` with `InformationProtectionPolicy.Read`. There is also a v1.0 `security/dataSecurityAndGovernance/sensitivityLabels` with `SensitivityLabel.Read`; it's worth switching once we've confirmed which one the tenant returns.
- **DOCS:** Graph has no "list mailboxes I'm a delegate on", so delegated mailboxes are configured (`delegatedMailboxes` in config.json).
- **UNVERIFIED:** all-day events with `Prefer: outlook.timezone="UTC"` — we anchor them at local midnight. Check that a CET all-day event doesn't land on the previous day.
- **UNVERIFIED:** writes and label reads for calendars *shared into* `/me/calendars` use calendar-scoped paths (`/me/calendars/{id}/events/{id}`), the same addressing as the snapshot read. Not yet run against a shared calendar.
- **UNVERIFIED:** `If-Match: W/"<changeKey>"` on event PATCH producing 412 for stale edits. It works against the fixture; Graph's behaviour on events needs a tenant test.
- **UNVERIFIED:** how recurring occurrences appear in a delta round (instances vs partial series properties). If delta returns series masters or partial instances for primary calendars, the delta apply needs an expansion step.

## 5. How labels are honoured (today)

`ContentPolicy` is the only thing views, the pasteboard and the cache writer consult.

| Situation | Copy | Export | Offline details | Screen capture | UI |
|---|---|---|---|---|---|
| Unlabelled | ✓ | ✓ | ✓ | ✓ | — |
| Label priority ≥ 2 (e.g. Confidential) | ✗ | ✗ | ✓ | ✓ | header/footer marking |
| Label priority ≥ 3 | ✗ | ✗ | ✓ | ✗ | |
| Label applies encryption | ✗ | ✗ | **✗ (body/attendees never written to disk)** | ✗ | "Encrypted" notice, watermark |
| Label ID not in synced policy, or policy never synced | ✗ | ✗ | ✗ | ✗ | "Unknown label — restricted" (**fail closed**) |
| Legacy `private` on a shared or delegated calendar | ✗ | ✗ | ✗ (subject dropped too) | — | "Private appointment" |

The priority thresholds are in `EnforcementSettings`. In production they should come from label *custom settings* (`mip::Label::GetCustomSettings`) so the tenant admin controls them, not the app.

Cache: everything except the index columns (times, calendar ID, label ID) is AES-GCM sealed with a 256-bit key held in the login Keychain (`AfterFirstUnlockThisDeviceOnly`). Sign-out wipes the DB **and** destroys the key (crypto-shred). The DB file is mode 0600 in a 0700 directory.

## 6. Known gaps and risks

1. **MIP not linked** (§3). This is the main item before anyone calls the app "Purview integrated".
2. **Live sign-in is blocked on code signing (VERIFIED).**
   - With an ad-hoc signature, MSAL's `allAccounts()` fails with `NSOSStatusErrorDomain -34018` (errSecMissingEntitlement, from `MSIDKeychainTokenCache`). Its token cache needs a `keychain-access-groups` entitlement (`<TeamID>.com.microsoft.identity.universalstorage`), and that needs a real Apple signing identity (Apple Developer team).
   - **An app registration alone is not enough to sign in.**
   - Our own cache key uses the legacy login keychain. Each ad-hoc re-sign changes the code identity, so macOS raised a Keychain ACL prompt that stalled launch. That's why fixture mode now uses an in-memory store and an ephemeral key and **never touches disk or the Keychain**.
   - Production should move both to the data-protection keychain under the team's access group.
3. **No Xcode**, which means:
   - `swift test` crashes under CLT 6.4 (hence `CoreSelfTest`)
   - SwiftUI's `@State` macro plugin is missing (worked around)
   - no Instruments
   - Entitlements and notarisation depend on a signing identity, not on Xcode.
4. **Conditional Access / device compliance:** needs the Microsoft Enterprise SSO plug-in (Company Portal) as broker. MSAL supports it, but it needs a properly signed app plus the associated-domains / SSO-extension MDM profile. Not tested.
5. **Screen-capture blocking is best-effort.** `sharingType = .none` defeated CoreGraphics window capture here, but ScreenCaptureKit-based tools weren't tested. Treat it as defence in depth, not a control to claim in an audit.
6. **Writes:** one mutation (drag to move, with If-Match and server-wins on conflict) is done end to end. Create, delete, RSVP and recurrence-instance edits follow the same outbox pattern but aren't built.
7. **Recurring series:** calendarView expands occurrences, which is right for viewing. Editing "this vs all" isn't handled.
8. **The live tenant path hasn't run.** It needs an app registration (below). Everything live-only above is marked DOCS or UNVERIFIED.

## 7. Entra app registration needed

- Public client, redirect URI `msauth.<bundle-id>://auth` (macOS platform)
- Microsoft Graph delegated permissions: `User.Read`, `Calendars.ReadWrite.Shared`, `InformationProtectionPolicy.Read`
- For the MIP phase: Azure Rights Management Services `user_impersonation`, and MIP Sync Service `UnifiedPolicy.User.Read`
- Then add `{"clientId": "…", "tenantId": "…", "delegatedMailboxes": []}` to `~/Library/Application Support/CompliantCalendar/config.json`
- **And** sign the bundle with an Apple team identity, with `keychain-access-groups = <TeamID>.com.microsoft.identity.universalstorage` (see §6.2), or sign-in fails at the token cache.

## 8. Real-tenant test (a test tenant, 2026-11-18)

Run with a browser PKCE token (`scripts/devtoken.py`) for a normal mailbox user. The app was registered with `infra/entra/register.sh`: a public client, delegated permissions only, consent per user.

- **VERIFIED:** `/me/calendars` returned 6 calendars (default, 3 more of the user's own, 2 shared in). Some calendars come back with `"owner": null`; the client treats them as in-mailbox (`/me`) calendars.
- **VERIFIED:** `calendarView` ±60 days returned 140 events: 86 occurrences, 3 `private`, 1 all-day.
- **VERIFIED — bug found and fixed:** `calendarView/delta` returns `seriesMaster` items as well as occurrences. Applying them would have doubled each series' first slot, so `seriesMaster` is now skipped.
- **VERIFIED — label list unavailable:** for this user, `GET /beta/me/security/informationProtection/sensitivityLabels` returns 403 `UnknownError`, and `GET /v1.0/security/dataSecurityAndGovernance/sensitivityLabels` returns 403 `Unauthorized`. A third client hitting a different label endpoint got 404 `UnknownError`. The token did carry `InformationProtectionPolicy.Read`.
  - Likely cause: no label policy is published to the user, or a licence gap. This is tenant-side, not client-side.
  - **Bug found and fixed:** a label-list failure used to abort the whole sync. It's now non-fatal, the reason shows in the sidebar, and labelled items stay fail-closed. A regression test covers it.
- **NOT YET VERIFIED:** where the label sits on a meeting. 0 of 140 events carried `msip_labels`, so a labelled test meeting is still needed.
- **VERIFIED — Teams join:** 15 of 68 events (±30 days) have `onlineMeeting.joinUrl`; `onlineMeetingUrl` is always null. On macOS an `https://teams.microsoft.com` link resolves to Safari, while `msteams:` resolves to Microsoft Teams.app. Join (button, ⌘J, double-click, right-click) now opens the Teams app directly and falls back to the browser.
- **Auth notes:**
  - Device-code sign-in isn't usable here.
  - Browser SSO can pick an account without a mailbox (`MailboxNotEnabledForRESTAPI`). `devtoken.py` now refuses tokens for accounts without a mailbox.
  - An administrator accepting the consent prompt creates a **tenant-wide** grant; for a per-user test, use per-user grants only.
