# niivo mail for macOS

**A fast, native, keyboard-first mail and calendar client for Microsoft 365 that takes compliance seriously.**

It reads Purview sensitivity labels and enforces them, keeps an encrypted offline cache that your organisation can
bound, and puts every AI feature behind those same labels. Written in Swift and SwiftUI, with no Electron and no web
wrapper. Mac first; other platforms later.

> **Status: early and moving fast.** It builds, it passes its own self-test suite, and it runs against a real
> Microsoft 365 tenant. A lot of features are self-tested against synthetic fixtures and a stubbed Graph but have not
> yet been exercised live. The table below says which is which. Please read [SECURITY.md](SECURITY.md) before you
> point it at anything you care about.

---

## Why this exists

On a Mac with a Microsoft 365 mailbox, you currently get to pick one of two compromises.

**Outlook for Mac** understands your organisation. Sensitivity labels, encrypted mail, Conditional Access and
"Do Not Forward" all work. But it's a large app with Outlook-on-the-web ideas inside a Mac window. It can feel heavy,
and fast keyboard-driven triage isn't really what it's built for.

**The nice clients** (Apple Mail, Spark, Mimestream, Superhuman and friends) are pleasant, quick and keyboard-friendly.
But to most of them a sensitivity label is just another header. They generally can't open encrypted mail, and
they have no idea that a "Highly Confidential" thread shouldn't be cached on an unmanaged laptop or handed to a
cloud AI. That's why IT departments block them, and that's fair enough.

niivo mail is the attempt at the missing third option. Build the Mac client people actually want to use, and make it
honour the same rules as Outlook, so IT has no reason to say no.

---

## What works today, and what doesn't

Legend: **Built** = in the app and covered by the self-tests. **Built, unverified live** = implemented and tested
offline, never run against a real tenant. **Partial** = some of it exists. **Planned** = designed, not built.

| Area | Status | Notes |
|---|---|---|
| Microsoft 365 sign-in (MSAL, delegated, public client) | Built | Multiple M365 accounts and tenants (`docs/ACCOUNTS.md`) |
| Gmail, iCloud, Outlook.com, IMAP/SMTP, JMAP | **Planned** | The provider enum declares them; none can be selected. Only Microsoft 365 works today |
| Mail: three-pane, conversations, keyset-paged list | Built | Mostly fixture-tested; live coverage is still growing |
| Keyboard-first triage, ⌘K palette, niivo / Outlook / Gmail keymaps | Built | `MailKeymap`; Outlook-compatible map in Settings |
| Composer: rich text, live Markdown, attachments, signatures | Built | |
| Undo send, snooze, send later (client-side) | Built / Partial | Server-side deferred send is unverified live |
| Shared / delegated mailboxes, M365 Groups | Built | Groups need admin consent |
| Calendar: day / work week / week, schedule view, find a time, rooms | Built | The calendar is the oldest module and has had the most live use |
| Encrypted local cache, per-account keys, crypto-shred on sign-out | Built | See SECURITY.md |
| BYOD vs managed device profiles, posture checks, app lock | Built | MDM managed preferences are read |
| Signed tenant policy overlay | **Built in the engine, not yet wired** | `PolicyLoader` verifies it, but the app doesn't fetch one yet |
| Offline grace lock / remote wipe on revocation | **Built in the engine, not yet wired** | `SessionHealth` and `Wipe` are self-tested; the app only simulates a wipe in fixture mode |
| Purview labels: read, banners, label floor on reply/forward | Built | |
| Label picker, default / mandatory label, downgrade justification | Partial | The Policy SDK path is unverified live |
| Decrypt protected (RMS / rpmsg) mail via the MIP SDK | **Built, unverified live** | Off by default; needs the separately downloaded MIP SDK |
| Encrypt on send | **Not supported** | A label that encrypts blocks the send and tells you to use Outlook. Nothing goes out labelled-but-clear |
| AI: summaries, drafts in your voice, triage, Ask with citations | Built, unverified live | Off by default. Every call goes through the label gate |
| On-device AI (Apple Foundation Models) | Built, unverified live | Never smoke-run: the model wasn't available on the dev machine |
| Local model download and management | Planned | |
| Today / Flow mode / promises ledger / workspace "Desk" | Built, unverified live | `docs/RETHINK.md`, `docs/SUITE.md` |
| OfficeMCP: local MCP server for AI agents | Built | Read-mostly, label-gated, drafts only (never sends). Graph mode is unverified live |
| Signed + notarised build | Built (script) | `scripts/bundle.sh` signs, notarises and staples when given credentials |
| Auto-update | Planned | |

The detailed, per-feature truth lives in [docs/BACKLOG.md](docs/BACKLOG.md). Where this README and the code
disagree, the code wins. Please open an issue when you spot a difference.

---

## Security in one screen

- **No backend of ours.** The app talks to Microsoft (Entra ID, Graph, and the Rights Management and policy services
  the MIP SDK uses), to the AI provider *you* configure, and to remote images only when you allow them. It has no
  niivo server, no analytics and no telemetry pipeline. Microsoft's own SDKs send their client diagnostics to
  Microsoft.
- **Delegated only.** MSAL public client, no client secret, no application permissions. The app can only do what
  you can do.
- **Encrypted cache.** Subjects, bodies, recipients and previews are sealed with AES-GCM. Keys are wrapped by the
  Secure Enclave, and the search index is blind (HMAC). Signing out crypto-shreds the cache.
- **Labels decide what's kept offline.** Mail that's protected, private or carries an unknown label never has its
  body, preview, recipients or attachment names written to disk. On an unmanaged Mac (BYOD) the cache window is 30
  days and labelled bodies stay online-only.
- **The tenant can tighten, not loosen.** An organisation policy can only make the defaults stricter. Only an MDM
  configuration profile that forces a setting can relax one.
- **Fail closed.** If a label is unknown, its rights can't be resolved, or the policy didn't load, you get less, never
  more.
- **AI behind label gates.** AI is off by default. Encrypted mail without EXTRACT rights, private mail and
  unknown labels are kept out of every prompt. At Confidential and above, the cloud tier sees metadata only. On-device models
  are preferred for light tasks.

Full threat model, mechanisms with file references, and the list of things that aren't verified yet:
**[SECURITY.md](SECURITY.md)**.

---

## Build from source

### Requirements

- **macOS 15 or later** (`LSMinimumSystemVersion` 15.0; the package targets `.macOS(.v15)`). Apple silicon is the
  tested platform.
- **Swift 6 toolchain.** The Xcode **Command Line Tools** are enough (`xcode-select --install`). No Xcode project, no
  `.xcodeproj`, and everything is SwiftPM.
- For a real tenant you also need an **Apple Developer ID** to sign with (see below) and an **Entra app registration**.

### Build and test

```bash
swift build                      # debug build of every target
swift run CoreSelfTest           # the test suite (stands in for `swift test`, which crashes under the CLT)
```

`CoreSelfTest` covers the store, the crypto, the compliance engine, sync, the trust policy, the AI gate, the MCP server
and more, all on synthetic data. It needs no network and no account. It ends with `ALL CHECKS PASSED`.

### Run it without an account (synthetic data)

Sample data exists only in **debug** builds, and release builds never fall back to it.

```bash
./scripts/bundle.sh debug
open "build/niivo office.app" --args --fixtures
```

> **Naming lag:** the rename is in progress. Internal names still say `CompliantCalendar` (SwiftPM product, support
> folder `~/Library/Application Support/CompliantCalendar/`, `CC_*` environment variables) and `niivo office` (the
> bundle name set by `APP` in `scripts/bundle.sh`). Note the space in the path.

### Run it against your tenant

**1. Register an Entra app.** `infra/entra/register.sh` does it idempotently with `az rest`:

```bash
az login                                   # needs Application.ReadWrite.All + DelegatedPermissionGrant.ReadWrite.All
infra/entra/register.sh you@yourtenant.example
```

It prints `CLIENT_ID=` and `TENANT_ID=`. Know what it does before you run it:

- It creates a **single-tenant** public-client app (`AzureADMyOrg`) with **no secret**. The redirect URIs are
  `msauth.<bundle-id>://auth` and `http://localhost`.
- It requests Graph `User.Read`, `Calendars.ReadWrite.Shared` and `InformationProtectionPolicy.Read`, plus Azure
  Rights Management `user_impersonation` and the MIP sync service `UnifiedPolicy.User.Read`.
- It grants consent for **the one user you name**, not tenant-wide.
- **It does not add the mail scopes.** Add `Mail.ReadWrite`, `Mail.ReadWrite.Shared`, `Mail.Send`, `Mail.Send.Shared`
  and `MailboxSettings.ReadWrite` (delegated) yourself. The optional sets (directory, groups, OneDrive, contacts,
  To Do, OneNote, presence, rooms) are listed with their consent notes in `Sources/CompliantCalendar/Auth.swift`.
- **Its `BUNDLE_ID` must match the one you build with.** The script and `scripts/bundle.sh` currently default to
  different IDs, and MSAL fails if the redirect URI doesn't match. Edit one of them.

**2. Tell the build about it.** Create a git-ignored `build.env` in the repo root:

```bash
NIIVO_CLIENT_ID=00000000-0000-0000-0000-000000000000
NIIVO_TENANT_ID=00000000-0000-0000-0000-000000000000
```

These aren't secrets, but they are specific to your deployment, so they're baked into `Info.plist` at bundle time
rather than committed. Settings are layered: the `Info.plist` defaults first, then
`~/Library/Application Support/CompliantCalendar/config.json` (`clientId`, `tenantId`, plus optional
`delegatedMailboxes` / `sharedMailboxes`), then `CC_CLIENT_ID` / `CC_TENANT_ID` in the environment. Later sources win.
Anything set in the environment overrides `build.env`.

**3. Sign it.** An ad-hoc-signed build can't use MSAL's keychain token cache (`-34018`), so a real sign-in needs a
real identity:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TEAM_ID=TEAMID \
./scripts/bundle.sh                              # release by default
```

| Variable | Meaning |
|---|---|
| `SIGN_IDENTITY` | Code-signing identity. Hardened runtime and a timestamp are always on |
| `TEAM_ID` | Your Apple team ID. It builds the `keychain-access-groups` entitlement (MSAL's shared cache plus the app's own group) |
| `NOTARY_PROFILE` | Optional. A `xcrun notarytool store-credentials` profile name. When set, the script notarises, staples and runs `spctl --assess` |
| `PROFILE` | Optional. A provisioning profile to embed, if your entitlements need one |
| `BUNDLE_ID` | Optional. Overrides the default bundle identifier, and with it the MSAL redirect URI |
| `BUNDLE_MIP` | `0` leaves the MIP SDK out even when it's present (default `1`) |
| `VERSION` | Optional. `CFBundleShortVersionString` (default `0.1.0`) |
| `BUILD_NUMBER` | Optional. `CFBundleVersion`, must increase with every release (default: commit count of `HEAD`) |
| `SPARKLE_PUBLIC_KEY` | Optional. Sparkle EdDSA public key; empty builds an app with updates off. See [Updates](#updates) |
| `SPARKLE_FEED_URL` | Optional. Appcast URL (default: this repo's latest GitHub release) |

Without `SIGN_IDENTITY` and `TEAM_ID` the script ad-hoc signs, which is good for debug fixtures only.

### Optional: the Microsoft Information Protection SDK

Decrypting protected mail uses Microsoft's **MIP SDK** (C++). **It is not in this repository.** `vendor/` is
git-ignored, and the SDK is covered by Microsoft's own licence terms, which you accept when you download it.

1. Download the macOS File SDK from Microsoft (`docs/MIP.md` has the version, URLs and SHA-256 hashes) and extract
   it into `vendor/mip/sdk/`.
2. Run `scripts/build-mipbridge.sh`. It builds the small C-ABI bridge (`native/mipbridge/`) into
   `vendor/mip/lib/libniivo_mipbridge.dylib`.
3. Bundle with a real `SIGN_IDENTITY`. Only the signed path copies the bridge and the SDK's runtime dylibs into
   `Contents/Frameworks` and re-signs them for library validation.
4. Turn it on in **Settings → Mail → Protected messages**. It's off by default.

Without the SDK everything else builds and runs. Protected mail just shows as protected.

**Before you distribute a build that contains the MIP SDK**, read "Licence / redistribution" in `docs/MIP.md`. Three
things there matter:

- Microsoft's `redist.txt` lists four dylibs, but the bundle step copies every runtime dylib the SDK ships.
- Distributed apps must call the SDK's audit API, and this build currently disables audit discovery.
- Microsoft requires a signed Information Protection Integration Agreement (IPIA) before a public release.

## Updates

Release builds update themselves with [Sparkle 2](https://sparkle-project.org). The app checks
`https://github.com/rdbartram/niivo-mail-mac/releases/latest/download/appcast.xml`, and Sparkle installs an update
only if its EdDSA signature matches the public key baked into the app and its Developer ID signature matches the
installed app. You get **niivo mail → Check for Updates…** in the app menu, and **Settings → Updates** has the
automatic-check toggle.

- A build without `SPARKLE_PUBLIC_KEY` (forks, local builds) has updates off and says so in Settings.
- Admins can turn updates off with the managed preference `disableUpdates = true`, or lock the automatic-check toggle
  by forcing `SUEnableAutomaticChecks`. Both go in the app's domain, via an MDM configuration profile.
- **Builds from before Sparkle can't update themselves.** Install the first Sparkle-enabled release by hand. After
  that, updates arrive in the app.

How releases are cut, plus the one-time key setup: [docs/RELEASING.md](docs/RELEASING.md).

---

## Repo layout

```
Sources/
  CalendarCore/      UI-free core: models, encrypted SQLite store, Graph calendar client, sync, label policy engine
  MailCore/          UI-free mail: encrypted store + blind index, Graph mail client, sync, AI gate, triage, knowledge
  TrustCore/         device trust: BYOD/managed policy, signed tenant policy, posture, app lock, revocation, wipe, audit
  ProtectedContent/  Purview decryption: rpmsg fetch, MIP bridge loader (dlopen), protected item opener
  MIPBridgeABI/      header-only C ABI shared with the native MIP bridge
  OfficeTools/       the gated tool layer behind both the MCP server and the in-app agent
  OfficeMCP/         stdio MCP server (JSON-RPC 2.0); also the relay to the app's private socket
  CompliantCalendar/ the SwiftUI app: MSAL auth, mail, calendar, composer, reader, settings, Desk
  CoreSelfTest/      the test runner
  SearchBench/       search-quality bench on a synthetic corpus (docs/SEARCH-QUALITY.md)
  LiveWriteProbe/    real-tenant calendar write probe (creates and deletes "[Spike test]" events)
  MIPProbe/          real-tenant decrypt probe for one protected message
native/mipbridge/    C++ bridge to the MIP SDK (built separately, never linked by SwiftPM)
scripts/             bundle.sh (app assembly, signing, notarisation), build-mipbridge.sh, devtoken.py
infra/entra/         register.sh (Entra app registration)
docs/                design notes, research, findings, backlog
```

---

## Contributing and security reports

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Please **don't** report vulnerabilities in public
issues. Use **"Report a vulnerability"** on the repository's Security tab ([SECURITY.md](SECURITY.md)).

## Licence

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party components and their licences are listed
in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

niivo mail for macOS — Copyright 2026 Ryan Bartram. If you redistribute it or build on it, keep the NOTICE file and
credit the original project: <https://github.com/rdbartram/niivo-mail-mac>.

*Microsoft 365, Outlook, Entra, Purview and the Microsoft Information Protection SDK are trademarks or products of
Microsoft. Other product names belong to their owners. niivo mail is not affiliated with or endorsed by any of them.*
