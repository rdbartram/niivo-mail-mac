# Security

niivo mail is a mail client for organisations that label and encrypt their mail. Its security story is the product,
so this document tries to be precise about what is enforced today, what is built but not yet switched on, and what
hasn't been verified against a real tenant.

**Status labels used below:**

- **Enforced:** the app does this today.
- **Engine only:** implemented and covered by `CoreSelfTest` in a UI-free module, but the app doesn't call it yet.
- **Unverified live:** implemented, never run against a real tenant. It may not behave as documented.

File paths are relative to the repository root.

---

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub Security Advisories. On the repository page, open the
**Security** tab and choose **"Report a vulnerability"**. Don't open a public issue, and don't put details in a pull
request.

Include what you found, how to reproduce it, and which commit or build you tested. A reply may take a few days; this is
a small project. Please give us a reasonable chance to fix the problem before you publish.

In scope: anything in this repository, including the app, `OfficeMCP`, the MIP bridge and the build scripts.
Out of scope: Microsoft's services and SDKs, and Apple's platform (report those to Microsoft or Apple), unless the
problem is how we use them.

---

## Threat model

### What we protect

1. **Mail and calendar content at rest on a Mac that may not be managed** (BYOD). That covers subjects, bodies,
   recipients, attachment names, previews, and anything derived from them, such as search terms, triage state,
   people and matters, promises and loops.
2. **Labelled and encrypted content.** Purview sensitivity labels and their usage rights (VIEW, EXTRACT, PRINT,
   FORWARD and so on) should mean the same in niivo mail as in Outlook.
3. **Tokens and keys:** MSAL tokens, the cache keys, and API keys for any AI provider you configure.

### Against whom

| Adversary | What we try to do |
|---|---|
| **Someone with a lost or stolen laptop** | The cache is encrypted with keys that the Secure Enclave wraps behind user presence. The app locks. Labelled bodies aren't kept offline on BYOD |
| **A user whose access was revoked** (left the company, disabled, removed from the app) | Lock, then wipe *that account's* data on an authoritative signal from Entra, a wipe-group hit or the offline deadline. **Enforced; unverified live**, see below |
| **Other local apps running as the same user** | No plaintext content on disk. Cache keys are stored only as wrapped blobs, and the key that unwraps them is non-exportable in the Secure Enclave and needs user presence. MSAL tokens (and the no-SE fallback key) are in the keychain under our access group. The MCP relay socket needs a per-run token |
| **AI and cloud leakage** | One label gate in front of every AI feature and every MCP tool. Fail closed. On-device models are preferred |
| **Content injected by a hostile email** (prompt injection, tracking) | Mail is sanitised and wrapped as untrusted text in prompts. The reader runs with JavaScript off, a strict CSP, and remote content blocked by default |
| **Us, the developers** | No backend, no telemetry pipeline, delegated permissions only. We never see your mail, tokens or keys, and the app has nowhere to send them |

**"No backend, no telemetry" means this:**

There is no destination of ours anywhere in the code. The network destinations are all Microsoft's, yours or your
tenant's:

- **Microsoft:**
  - Entra ID (`login.microsoftonline.com`) and Microsoft Graph
  - the Azure Rights Management and MIP policy-sync services (MIP SDK only)
  - SharePoint/OneDrive download URLs that Graph itself issues, for cloud attachments
- **Yours or your tenant's:**
  - the AI provider you configure, if any
  - remote images in a message, but only when you allow them for that message or sender (never for labelled mail)
  - meeting and other links you click

MSAL and the MIP SDK send Microsoft their own client and service diagnostics. The MIP bridge sets the SDK to minimal
telemetry with no local telemetry cache (`native/mipbridge/niivo_mipbridge.cpp`).

### Explicit non-goals

- **A compromised Mac or a compromised user account.** Malware running as you, with your keychain unlocked and you
  present to approve Touch ID, can read what you can read. So can an attacker with root or a kernel exploit.
- **Stopping a determined insider.** Anyone who can read a message can photograph the screen. Copy, print and capture
  controls are friction and policy, not DRM.
- **Defending against a patched binary.** Posture checks and policy gates live in the app. Whoever can modify and
  re-sign the app can remove them. Notarisation and code-signature checks raise that bar; they don't remove it.
- **Encrypting outbound mail.** We don't do it yet (see Purview below). Rather than pretend, we refuse.
- **Replacing MDM, Intune or Conditional Access.** We read their signals where we can; we are not them.

---

## Mechanisms

### Identity: MSAL, public client, delegated only (Enforced)

- `Sources/CompliantCalendar/Auth.swift` uses `MSALPublicClientApplication` with a redirect URI of
  `msauth.<bundle-id>://auth`. There's no client secret, the app isn't confidential, and it requests no application
  permissions.
- Scopes are split into **incremental sets**: calendar, mail, directory, groups, drive, people, To Do, OneNote and
  presence. One that hasn't been consented doesn't break the others, and optional sets are asked for on first use.
- Authority is the configured tenant, or `organizations` when you add an account.
- Tokens live in MSAL's keychain cache (`<TEAM_ID>.com.microsoft.identity.universalstorage`). This is why ad-hoc
  builds can't sign in: without the `keychain-access-groups` entitlement the cache fails with `-34018`.

### Keys: Secure Enclave wrapping, data-protection keychain (Enforced)

- `Sources/TrustCore/EnclaveVault.swift`: each cache key is a random AES-256 key, wrapped by ECDH against a P-256
  key-agreement key held in the **Secure Enclave**. That key is non-exportable and uses
  `[.privateKeyUsage, .userPresence]` by default.
- The wrap is bound by HKDF context to its *purpose* and by AES-GCM AAD to its *slot name*, so a wrapped key can't
  be swapped into another slot.
- Without a Secure Enclave (VMs, older Intel Macs), a software P-256 key in the keychain is used instead. Posture
  reports that as **restrict**.
- `Sources/CompliantCalendar/CacheKeyring.swift`: keys are only in memory while the app is unlocked. One authenticated
  `LAContext` unwraps them all, so you see one prompt. Locking drops them, and the stores are closed.
- Swift can't guarantee that key material is zeroed in memory.

### Encrypted cache (Enforced)

- `Sources/CalendarCore/PayloadCipher.swift` and `Sources/CalendarCore/LocalStore.swift`: calendar payloads (subjects,
  bodies, attendees) are AES-GCM sealed. Index columns (times, calendar, label id) stay in plaintext so that range
  queries work.
- `Sources/MailCore/MailStore.swift`:
  - Header rows keep only ids, folder, mailbox, dates and read/flag state in plaintext. Subject, sender and preview are
    sealed. Bodies live in a separate size-capped, sealed LRU table.
  - Search uses a **blind index**: truncated HMAC-SHA256 of each token, under a key derived from the cache key. No
    plaintext terms are stored.
- Derived stores use HMAC keys tagged with the account and **fixed-size padded payloads**, so row sizes don't reveal
  content length. These are triage (`InboxStateEngine.swift`), knowledge, promises and loops.
  - Message header and body rows are *not* padded. Their ciphertext length roughly follows the plaintext length.
- **The persist rule is applied on every write path:** a protected or unknown label, or redacted private mail, means
  no body, preview, recipients or attachment names are written, and only sender tokens are indexed.
- **Sign-out crypto-shreds:** the account's wrapped keys are destroyed, so the files are unreadable even if deleting
  them fails.

### Device profiles: BYOD vs managed (Enforced)

`Sources/TrustCore/TrustPolicy.swift` defines two default profiles.

| Setting | BYOD (default) | Managed (MDM forces `profile = managed`) |
|---|---|---|
| `cacheWindowMaxDays` (mail history kept offline) | 30 | 365 |
| Offline bodies for labelled mail | no | yes |
| App lock | Touch ID / password, 5 min idle | off |
| Offline grace → lock / wipe (**enforced; unverified live**, see below) | 3 d / 14 d | 14 d / 60 d |
| Requires FileVault, SIP | yes | yes |
| Requires screen lock | yes | no |
| AI access | follow labels | follow labels |

A Mac is BYOD unless an MDM configuration profile *forces* `profile = managed`. The cache window and offline-body
rules are applied when sync starts.

**Posture** (`Sources/TrustCore/Posture.swift`) checks FileVault, SIP, screen lock, OS version, the code signature,
notarisation and the Secure Enclave. It uses read-only status tools, so it needs no admin rights.

- **Block:** a required check is definitely failing, or the signature is invalid.
- **Restrict:** a check couldn't be verified, there's no Secure Enclave, or the build isn't notarised on BYOD.
  Restrict turns off offline labelled bodies, attachment downloads, print, copy-out and capture, and caps AI at
  metadata.

### Policy layering: the tenant can only tighten

`Sources/TrustCore/PolicyLoader.swift` merges the sources in this order:

1. **Profile defaults.** Enforced.
2. **A signed tenant policy.** It may only *tighten*. **Enforced; unverified live** (no tenant has deployed one).
   - A policy document plus a detached **Ed25519** signature, verified over the exact bytes against pinned keys.
   - Checked for validity window, tenant ID, maximum age and clock skew, with anti-rollback on the version (the
     highest version applied is persisted, so an older document is rejected after a newer one).
   - **Delivery** (`TenantPolicySource`, `Sources/TrustCore/Enforcement.swift`). There is no niivo server and no
     defined SharePoint location, so the app fetches nothing. The document comes from either:
     - **managed preferences** for the app's bundle id (`tenantPolicyDocument` as Data or as the JSON text / its
       base64, plus `tenantPolicySignature`), or
     - a file pair **next to `config.json`**: `trust-policy.json` and `trust-policy.json.sig`.
   - **Keys** come only from a **forced** managed preference `tenantPolicyPinnedKeys` (`["keyId:base64-raw-key"]`),
     optionally bound with a forced `tenantPolicyTenantId`. Without forced keys, any document is rejected, so a user
     can't pin a key of their own. The app ships no keys.
   - Honest limit: on BYOD the user can delete the file pair, which falls back to the (strict) BYOD defaults. A
     document delivered by MDM can't be removed by the user.
3. **Unforced managed preferences** (for example, your own `defaults write`). These only tighten. Enforced.
4. **MDM-forced keys.** These are applied last and are the only source allowed to relax a setting, because the
   device is already governed. Enforced.

Each key is decoded separately, so one bad value doesn't throw away the rest. "Tighten" is defined per field in
`TrustPolicy.apply(_:relax:)`:

- booleans that allow something: AND
- booleans that require something: OR
- day counts: minimum
- the open-in allowlist: intersection
- the AI level: minimum

### Session health, revocation and wipe (Enforced; unverified live)

The engine is `Sources/TrustCore/SessionHealth.swift` and `Sources/TrustCore/Wipe.swift`; the layer the app calls is
`Sources/TrustCore/Enforcement.swift` (`SessionEnforcer`, `TrustEnforcement`, `AccountWipeLayout`), and the app side is
`Sources/CompliantCalendar/TrustWiring.swift`. All of it is covered by `CoreSelfTest` with fakes (no network). **None of
it has been run against a real revocation in a real tenant yet.**

How the app uses it:

- **Inputs.** Every MSAL result on the calendar and mail token paths (silent refresh, the mail reauthentication,
  interactive sign-in failures that name an account) goes to `SessionEnforcer`. MSAL errors are read with MSAL's own
  userInfo constants. Optional scope sets (groups, OneDrive, people, To Do, presence) don't count: their failures are
  usually missing consent.
- **When.** At launch the active account refreshes once (bounded to 10 s) *before* any store opens, and interrupted
  wipes are finished first. The decision runs again on every failure, on unlock, and on a 60 s tick. Other cached
  accounts refresh silently at launch and every 6 h, so each has its own grace clock.
- **Actions** (`TrustEnforcement.action`):
  - **Prompt** for MFA, Conditional Access, consent, interaction required and claims challenges: today's "Sign-in
    required" state; cached content stays visible.
  - **Lock** for 50173/50133, a first unconfirmed revocation strike, offline grace exceeded, and a wiped account
    awaiting sign-in. Content is hidden, the stores are closed and the cache keys leave memory until a fresh token
    (or, for a wiped account, the confirmation below).
  - **Wipe** for a revoked account, a wipe-group hit or the offline deadline.
- **Per account.** Errors, strikes, grace clocks and wipe-group results are kept per account. A wipe of account A
  removes A's calendar and mail stores (and sidecars), A's vault slots (crypto-shred), A's legacy keychain items and
  A's MSAL account, plus the shared MIP licence cache (re-fetchable). Other accounts' stores, keys and sign-ins, the
  vault key and the account registry stay readable. The tombstone is per account and lives outside every wiped path.
  If the wiped account was the active one, the window explains what happened and offers to sign in again or continue
  with another account. Posture never wipes; no device-level wipe trigger exists today.
- **Coming back.** A tombstone is cleared only after an interactive sign-in, a successful Graph call and, if the
  policy sets a wipe group, a negative wipe-group check. Until then that account's stores are never opened.
- **Upgrade note.** An install with no recorded refresh is treated as "never refreshed": if the first launch after
  updating is offline, the session locks until a refresh succeeds.
- **CAE.** The `CP1` client capability stays opt-in (`defaults write <bundle id> auth.caeCP1 -bool YES`): the
  calendar service doesn't yet answer a claims challenge.

The rules:

- **Classification by explicit allowlist.** Only AADSTS codes listed in `AADSTSCatalog` with a `revoked` outcome can
  cause a wipe. That means a disabled, deleted or unassigned user, or a deleted app. Each entry cites its Microsoft Learn
  source, and all but one are marked verified. The exception is 700082 (token expired, reauth only). Unknown codes
  fall through to reauth or transient.
- **Why `AADSTS50173` locks and doesn't wipe.** 50173 means "grant expired because it was revoked". Microsoft
  documents that an ordinary password change or reset causes it too, and "revoke sessions" on its own only forces a
  new sign-in. Wiping on 50173 would wipe everyone who changed their password. So it **locks** and asks you to sign
  in. If the following *interactive* sign-in fails with disabled, deleted or unassigned, *that* is what wipes. 50133
  is treated the same way.
- **Misconfiguration guard.** Codes that also fit a wrong tenant or client ID (50034, 500341, 700016, 50105) only
  count as revoked for a tenant and client that have signed in successfully before.
- **Two strikes on silent refresh.** A revoked result on the background refresh path has to repeat at least 60 s
  later before it counts. An interactive result is authoritative straight away.
- **Wipe group (optional).** Membership of an Entra group, checked with `checkMemberGroups` every
  `wipeGroupCheckMinutes` (default 60, minimum 5; a policy can only shorten it), means wipe. It needs the
  admin-consented `GroupMember.Read.All`. A failed check never wipes and isn't counted as a check.
- **Offline grace clock.** With no successful refresh for `offlineGraceDays` the app locks, and after
  `offlineWipeDays` it wipes. A high-water mark means winding the system clock back doesn't extend the grace period.
- **Wipe order:**
  1. Write a tombstone (stored outside every wiped location).
  2. **Crypto-shred** the key vaults.
  3. Delete the stores, their sidecars and the keychain items.
  4. Mark the tombstone complete.

  The wipe is idempotent and resumes after a crash. The tombstone is cleared only by a fresh interactive sign-in
  plus server confirmation.

### Purview: labels, rights and decryption

- **Reading labels (Enforced).**
  - The app reads `msip_labels` on mail and events and resolves it against the tenant's label tree
    (`InformationProtectionPolicy.Read`). See `Sources/CalendarCore/Compliance.swift`, `LabelPolicy.swift`,
    `LabelTree.swift` and `LabelProvenance.swift`.
  - Another organisation's labels are never shown as ours.
  - A label id we can't resolve is **unknown**, and unknown is treated as the most restrictive case.
- **Label floor (Enforced).** A reply or forward can't go out with a lower label than the original.
- **Encrypted originals (Enforced).** Replying to or forwarding encrypted mail is refused, because it would go out in
  the clear. That includes unlabelled Do Not Forward and Encrypt-Only mail.
- **Encrypt on send: not supported, and blocked honestly (Enforced).** If a label applies encryption, the send (or
  meeting save) is blocked with a message telling you to use Outlook. Nothing ever goes out labelled-but-clear.
  `Sources/CompliantCalendar/PurviewLabelPolicy.swift`.
- **Label on send, default and mandatory labels, downgrade justification (Partial, unverified live).**
  - Labels are stamped as the `msip_labels` extended property.
  - Default, mandatory and justification come from the MIP Policy SDK through the bridge, and the justification is
    reported to Purview with `NotifyCommittedActions`.
  - Unverified: that Exchange turns the property into the header on send, and that the audit event reaches Purview.
- **Decrypting protected mail (Unverified live, off by default).** `Sources/ProtectedContent/` and
  `native/mipbridge/`.
  - The rpmsg is fetched through Graph and decrypted with the MIP File SDK's inspection API, in memory.
  - The SDK runs with in-memory caches and `SetCanCacheLicenses(false)`.
  - `NoDiskPlaintextGuard` gives each context a fresh `0700` temp directory. It deletes any non-empty file that
    appears there and fails the call closed.
  - Decrypted bodies are never written to the cache or the search index.
  - In this build they never reach AI either, even with EXTRACT. AI sees only what Graph returns for a protected item,
    which is a placeholder.
  - The bridge is `dlopen`ed at runtime, so no SwiftPM product links the SDK.
- **Usage rights from the licence (Unverified live).**
  - `UsageRights.fromLicence` (`Sources/CalendarCore/LicenceRights.swift`) maps the licence 1:1, and OWNER implies
    all rights.
  - An empty licence is an explicit empty set. It never falls back to the label's broader rights.
  - If the SDK returns no licence object, we grant **VIEW only**.
  - Copy, print, save, forward, reply and screen capture are all gated on those rights per item.
- **Fail-closed reader (Enforced).**
  - Each message or conversation card is loaded by a loader that checks, in order: private, protected, unknown
    label, rights.
  - Until a protected item's licence is known, it shows VIEW only, its region is shielded from capture, and it isn't
    cached.

### Screen capture (Enforced, best effort)

macOS can only exclude whole windows from capture (`NSWindow.sharingType`). Protected regions are therefore hosted in
their own child window with `sharingType = .none` (`Sources/CompliantCalendar/CaptureShield.swift`). Recent macOS
versions may not honour this for every ScreenCaptureKit client. Treat it as best effort.

### AI behind label gates (Enforced; providers unverified live)

AI is **off by default**: `AIProviderChoice.off` in `Sources/MailCore/AIAssistModels.swift`. When it's on, every
feature goes through one gate: `AIGatePolicy` and `AIPromptBuilder` in `Sources/MailCore/AIAssistGate.swift`. The
rules apply in order:

1. If the tier's access is off, the item is excluded. **Private mail and unknown labels are always excluded.**
2. **Encrypted without VIEW + EXTRACT:** metadata only, and the subject is withheld.
3. **Cloud tier, label priority ≥ the admin's cap** (default: Confidential): metadata only. The on-device tier is
   exempt from this one rule, because nothing leaves the Mac.
4. If the tier's access is metadata-only: metadata only.

More detail:

- **Tiers.** On-device is Apple Foundation Models. Cloud is the local `claude` CLI or any OpenAI-compatible endpoint.
  - The gate treats an OpenAI-compatible endpoint as **cloud** even when it's `localhost` (Ollama, LM Studio).
  - Plain `http` is only accepted for localhost.
  - Light tasks prefer on-device.
  - The organisation can switch AI off, limit it to metadata, or restrict the providers (`allowedAIProviders`), and
    can only lower these levels.
- **Prompt hygiene.**
  - Mail is sanitised: hidden text removed, links de-fanged, invisible characters stripped.
  - Each mail is wrapped in per-prompt random-nonce markers that an email can't forge.
  - Model output is treated as untrusted and rendered as plain text.
- **Claude CLI isolation** (`ClaudeCLIProvider`):
  - no built-in tools, no MCP servers except ours (agent mode only), no user settings, no auto-memory
  - an empty `0700` working directory and an allowlisted environment
  - the prompt goes in on stdin, so mail text never appears in `ps`
- **API keys** are read from the keychain on each call and never logged.
- **Multi-account:** each request uses only content from one account, under that account's policy
  (`Sources/TrustCore/AccountPolicies.swift`).

### OfficeMCP: a local MCP server for agents (Enforced; Graph mode unverified live)

`Sources/OfficeMCP/` and `Sources/OfficeTools/` run a stdio JSON-RPC server.

- It applies the **same gate** as the app.
- An unknown label or private mail is hidden.
- Encrypted mail and anything at or above the cap returns metadata only.
- "Labels couldn't be loaded" means every labelled item is hidden.
- Writes stop at **drafts**: there's no send tool. `--read-only` also removes drafts and triage, and
  `--allow-triage=false` removes flag, mark-read and snooze.
- Command-line flags can only tighten the loaded policy.
- In relay mode it holds no mailbox, store or token. It forwards to the app's private Unix socket, which lives in a
  fresh `0700` directory, accepts one connection and requires a random per-run token (`MCPSocketHost` in
  `Sources/OfficeTools/AgentTools.swift`). The app enforces a per-request call budget.
- Every tool call becomes one encrypted, content-free audit record: tool, ids, count and decision
  (`Sources/OfficeTools/Audit.swift` → `Sources/TrustCore/AuditLog.swift`, hash-chained).
- stdout carries JSON-RPC only. A stray print is redirected to stderr.

### Build integrity

`scripts/bundle.sh` signs everything with the **hardened runtime** and a secure timestamp. That covers the app, MSAL,
`OfficeMCP` and, when bundled, the MIP dylibs, which are re-signed for library validation. With `NOTARY_PROFILE` it
**notarises, staples and runs `spctl --assess`**. Release binaries are stripped before signing.

The entitlements are the minimum MSAL and the keychain need: application identifier, team identifier and
`keychain-access-groups`. On BYOD, posture puts a non-notarised build into restrict.

---

## Known limitations and unverified parts

The honest list. Most of it comes from the UNVERIFIED notes in `docs/MIP.md`, `docs/FINDINGS.md`, `docs/AI-UX.md` and
`docs/BACKLOG.md`.

- **Revocation, offline-grace wipe and the wipe group are engine only.** See above. This is the biggest gap.
- **The signed tenant policy is engine only.** It isn't fetched, and no keys are pinned.
- **The live MIP decrypt has never run.** These are all unverified:
  - how Graph delivers the rpmsg
  - the RMS token audience
  - whether the inspection handler returns a licence (if not: VIEW only)
  - library validation inside the signed bundle
  - Policy SDK engine load, and whether audit events show up in Purview
- **MIP redistribution isn't settled.** The bundle step copies every runtime dylib the SDK ships, not just the four in
  Microsoft's `redist.txt`. Audit discovery is off, although Microsoft's terms require distributed apps to call the
  audit API. A public release of a MIP-enabled build also needs an IPIA with Microsoft. See `docs/MIP.md`.
- **The label stamp on send** (`msip_labels` → header) and the label on meetings are unverified live.
- **On-device AI has never been smoke-run.** The model wasn't available on the development Mac. The cloud providers
  and the in-app Claude agent haven't been re-run live since the last changes.
- **No App Sandbox.** The app runs unsandboxed under the hardened runtime. Isolation from other local processes
  relies on the keychain access group, the Secure Enclave and file permissions, not on a container.
- **Plaintext index columns.** Ids, dates, folders, read/flag state and label ids are in plaintext in the SQLite files.
  They leak structure and volume, though not content. Message rows aren't padded.
- **Capture exclusion is best effort** (see above). Copy, print and capture gates are policy, not DRM.
- **Posture checks are advisory.** Screen-lock detection parses an undocumented tool output; anything unexpected
  counts as *unverified*, which means restrict rather than pass.
- **Many UI paths have never been clicked through by hand.** `CoreSelfTest` covers the core logic on fixtures and a
  stubbed Graph, not the SwiftUI layer.
- **CAE claims challenges** are only partly handled (one silent retry); the interactive path isn't wired for MIP
  resources.
- **No auto-update yet.** You're responsible for keeping builds current.
