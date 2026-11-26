# Compliant Office: Mail (Outlook alternative) + MCP — plan (2026-11-19)

Ryan's ask: a fully functional Outlook alternative for M365, Mac first, that builds on what Outlook does well and takes
the best modern ideas from elsewhere; supports Purview and MAM; first app of a suite meant to replace Office; and it
must speak **MCP** so AI can work with it.

## Honest scope of this pass
"Fully functional" is a multi-month product. This pass delivers a working vertical slice on fixtures, the
architecture for the rest, and a researched feature map. Real-tenant mail is **blocked on Ryan**: it needs
`Mail.ReadWrite`, `Mail.Send`, `MailboxSettings.ReadWrite` consent on the app registration, plus his explicit
go-ahead before anything is sent from his mailbox (the earlier approval covered calendar test events only).

## Verified facts that shape the design
- **MAM is not available on macOS.** Intune app protection policies cover Android, iOS/iPadOS and Windows (Edge);
  the Intune App SDK exists for iOS and Android only.
  Source: learn.microsoft.com/intune/app-management/protection/overview#supported-platforms-for-app-protection-policies
  and learn.microsoft.com/intune/developer/app-sdk/quickstart-integration.
  **Substitute on Mac:** device-based Conditional Access (Intune-enrolled, compliant Mac via Company Portal / Platform
  SSO broker through MSAL), Intune *preference file* (managed app config, supported on macOS) read from managed
  preferences, and the app enforcing MAM-equivalent controls itself: clipboard/save-as/print/share restrictions per
  label and per policy, app lock (Touch ID), selective wipe of the encrypted cache, screen-capture blocking.
- Purview labels on mail: label metadata is the `msip_labels` header/property (same as calendar items, already read
  via `$batch` singleValueExtendedProperties). Writing a label on send via Graph extended property: **UNVERIFIED**;
  encryption on send needs the MIP SDK (not in this pass).

## Targets
- `CalendarCore`: gains a label-keyed policy core (`policy(labelId:legacyPrivate:access:)`) used by events and mail.
- `MailCore` (new): models, encrypted `MailStore`, `MailService` protocol, `GraphMailService`, `FixtureMailService`,
  `MailSync` actor (optimistic actions + outbox), `AIAccessPolicy`.
- `CompliantCalendar` app: Mail window (three-pane, split inbox, command palette, keyboard triage, compose).
- `OfficeMCP` (new): stdio MCP server over the same core; draft-only writes; every result through `AIAccessPolicy`;
  access log; mail bodies wrapped as untrusted content.

## Compliance rules (blocking)
- Same as calendar: protected/unknown label → body and recipients not persisted; private → redacted.
- HTML bodies rendered with JavaScript off and remote content blocked by default (tracking pixels).
- Reply/forward via Graph `createReply`/`createReplyAll`/`createForward` so threading and history survive; a reply
  inherits the original's label and cannot downgrade it.
- MCP is an egress path around Purview: fail closed for unknown/protected/private; label priority ≥ threshold →
  metadata only; nothing sends without a human in the app.

## House rules (for every contributor/agent)
CLT only (no Xcode), no `@State` macro (state in `@Observable` models), `swift run CoreSelfTest` instead of
`swift test`, synthetic fixtures only, no real tenant calls, never print subjects/senders/bodies, commits local with
`git -c commit.gpgsign=false`, never push. Don't `bundle.sh` over a running app without checking.

## Scale requirement (Ryan, 2026-11-19): 100 GB+ mailboxes, plus several large shared/delegated ones
- Never full-mailbox sync. Headers only, in a window (default 90 days; Inbox/Sent always, other folders on first
  open). Older mail is paged on demand with a server cursor, and older content is found via server `$search`.
- Bodies are lazy, with a size-capped LRU body cache (default 500 MB).
- Store built for 1M+ rows: WAL, keyset pagination (no OFFSET), and no API that loads everything.
- Search without a plaintext index: a blind token index (HMAC of tokens with a key derived from the cache key),
  then server `$search` for older content.
- Scheduler: own Inbox first, shared mailboxes lazily or when pinned, at most 4 concurrent requests per mailbox,
  and Retry-After/backoff on 429/503.
- Counts come from the server folder properties, not local COUNT(*).
- UI: a lazily paged message list. Rows are loaded per visible page.
- Benchmark: 500k synthetic messages, with targets of first page < 50 ms and search < 100 ms.

## Shared mailboxes, send-as / send-on-behalf, cache window (Ryan, 2026-11-19)
- Shared mailboxes open alongside your own and sync per mailbox, lazily or when pinned.
- `SendIdentity` (self / sendAs / sendOnBehalf) in the From picker. Send-as from a shared mailbox goes through
  `/users/{shared}/messages` so the Sent copy lands in the shared mailbox. Send-on-behalf sets `from` on a /me draft.
  Graph can't list Exchange SendAs/SendOnBehalf grants, so identities come from config plus the opened mailboxes,
  and a server refusal is shown as "You can't send as X".
- The cache window is configurable per mailbox: 30 days, 90 days (default), 1 year, 2 years, 5 years or everything.
  Headers and index tokens follow the window and backfill in the background, newest first and resumable. Bodies
  stay in the size-capped cache.

## Rules and out of office (Ryan, 2026-11-19)
- Inbox rules are Exchange server-side rules (Graph `messageRule`), so they run with the Mac off and stay in step
  with Outlook. Covers the common conditions, actions and exceptions, reordering, and one-click "Always move
  messages from X".
- A forwarding rule to an external domain is checked by `RulePolicy` and blocked by default (data-exfiltration risk).
- Out of office is `mailboxSettings.automaticRepliesSetting`: off/on/scheduled, separate internal and external
  replies, and a choice of external audience. A banner shows while it's on. Setting it for another person's mailbox
  is probably not possible with delegated Graph (UNVERIFIED; would need EXO or app permissions).

## BYOD without MDM and without our own data gateway (Ryan's decision, 2026-11-19)
Ryan: data stays local and in the tenant. No gateway of ours ever holds customer data ("us having the data is
dodgy"). It must support remote wipe and similar controls.
Facts (Learn, checked 2026-11-19):
- No MAM on macOS.
- Token protection on macOS works only on MDM-managed Macs.
- Edge MAM is Windows only.
- Intune's only BYOD option on macOS is full device enrollment. Apple User Enrollment in Intune is iOS/iPadOS only.
Design (`TrustCore`, app-enforced, with the control plane in the customer's own tenant):
- **Policy sources, in this order:**
  1. managed preferences (when a Mac happens to be MDM-managed)
  2. a tenant-hosted, signed policy file (SharePoint/OneDrive location in the customer's tenant; the signing key
     pinned in config)
  3. built-in BYOD defaults, stricter than managed
- **Remote wipe without a server of ours.** The triggers come from Entra/M365:
  - session revocation, account disabled or deleted, user unassigned from the enterprise app (with
    assignment required), or added to a "wipe" group;
  - each is detected from the MSAL/Graph error on the next refresh, or from a CAE claims challenge;
  - plus an offline grace timer: no successful token refresh for N days locks the app, then wipes it.
- **Posture self-checks:** FileVault, SIP, minimum OS version, screen lock and the Gatekeeper/notarised build
  → allow, restrict or block.
- **Local controls:** encrypted cache (key in Keychain), Touch ID app lock after idle, copy/print/save/share rules
  by label and profile, screen-capture exclusion, attachments opened only in approved apps, and a local audit log.
- **Honest limit:** Entra can't tell our app from any other client on an unmanaged Mac. So compliance is
  app-enforced, not tenant-verified. A tenant that needs a hard guarantee still needs managed Macs. Bypass via
  other clients is reduced by tenant settings (block legacy auth, IMAP/POP/EWS), not eliminated.

### What the field does today (move2modern.uk, 28 Apr 2026, read 19 Nov)
- **The reference design for a BYOD Mac:** no enrollment, Conditional Access **blocks native Office desktop apps on
  unmanaged Macs**, and access is browser-only via Edge for Business, Defender for Cloud Apps session controls and the
  SharePoint unmanaged-device policy.
- **Edge Management Service for macOS:** GA since January 2026. It can't control clipboard, print or downloads.
- **Purview inline DLP in Edge:** needs E5.
- **Consequence for us:** a tenant that follows this blocks our native app too.
- **Lever to test (UNVERIFIED):**
  - Our mail access uses Graph tokens (resource "Microsoft Graph"), not the Exchange Online resource the Office
    desktop apps use.
  - Combined with "users can't consent to apps", an admin-consented app registration and "assignment required",
    an admin could allow **only our app** as a native client on unmanaged Macs while still blocking the Office
    desktop apps.
  - Must check: whether CA policies targeting Office 365/Exchange Online also apply to Graph mail calls, and which
    first-party Graph clients (PowerShell, CLI tools) would need blocking too.
  - Report-only test in a test tenant.
- Checked on Learn (concept-conditional-access-cloud-apps):
  - CA "applies to resources not clients". A public client like ours can't be targeted or excluded.
  - "Microsoft Graph functions as an umbrella resource". Graph mail calls are evaluated against the underlying
    service (Exchange Online).
  - So a "block native clients on unmanaged Macs" policy for Office 365 **also blocks our app**.
  - Consent restrictions alone don't fix this, because first-party Outlook for Mac needs no consent.
- **Allowlist recipe to test (UNVERIFIED end to end):**
  1. Scope a BYOD users group.
  2. CA allows native clients for that group on unmanaged macOS with MFA and sign-in frequency.
  3. Block Outlook for Mac at the Exchange layer: `Set-CASMailbox -MacOutlookEnabled $false`. Check that it covers
     new Outlook for Mac.
  4. Turn off EWS, IMAP, POP and ActiveSync per mailbox.
  5. Block user consent; admin-consent only our app.
  6. Set "assignment required" or disable the first-party Graph clients (Graph PowerShell, CLI).
  7. OWA stays browser-only under Defender for Cloud Apps session controls.

  Result: on that group's personal Macs our app is the only native mail client, and protection comes from
  TrustCore. Downside: MacOutlookEnabled is per mailbox, so those users lose Outlook for Mac on managed Macs too.

### move2modern part 2 (28 May 2026): the actual CA set, and how ours fits
- **CA-03 "Block Unmanaged macOS Native Apps"** targets Exchange Online + SharePoint Online + Office 365, on macOS,
  for "Mobile apps and desktop clients" (Browser not ticked). It excludes `device.isCompliant -eq True` and blocks.
  CA-04/05 cover browser-only access with MDCA session control and an 8 h sign-in frequency. The MDCA policies block
  downloads, copy/paste and print for devices without the "Intune compliant" tag. SharePoint is set to "Allow
  limited, web-only access". No Exchange-layer settings.
- **Under that set our app is blocked** (a native client, and Graph mail is evaluated as Exchange Online).
- **Variant that lets our app in** (UNVERIFIED, to test in report-only):
  - Change CA-03 for the BYOD group to target **SharePoint Online + Teams only**, dropping Exchange Online and the
    Office 365 bundle. Microsoft recommends the bundle because of service dependencies, so check that mail data
    reached through search isn't exposed.
  - Block Outlook for Mac in Exchange instead: `MacOutlookEnabled $false`, plus EWS, IMAP, POP and ActiveSync off.
  - Restrict consent and require assignment, so our app registration is the only approved Graph mail client.
  - Keep CA-02 (MFA) and add a sign-in frequency for native clients as well, so revocation reaches our app
    quickly alongside CAE.

## Threat model (Ryan, 2026-11-19), which sets scope and priorities
The app is NOT trying to stop a permitted user copying, printing or screenshotting content. That is Purview's job:
the app **honours** the label's usage rights and markings, as Outlook does.
The app's own job is:
1. **Stolen or lost device:**
   - encrypted cache, with the key in the Keychain (Secure Enclave wrapping when signed);
   - app lock;
   - FileVault posture check;
   - remote wipe;
   - offline lock/wipe timer.
2. **Data left behind** (leavers, ex-contractors, retired Macs):
   - tenant-driven wipe (disabled / deleted / unassigned / wipe group);
   - offline wipe deadline for Macs that never reconnect;
   - minimal cache on BYOD.

Consequences:
- Copy/print controls must follow the label's actual usage rights (EXTRACT, PRINT, …, via the MIP SDK), not our
  own priority threshold (`EnforcementSettings.restrictCopyAtPriority`). That threshold becomes an optional admin
  setting, off by default.
- Hardening against a malicious local admin (SIP block, anti-debug) is nice-to-have, not core.

## Communication graph + hybrid search (2026-11-19)
Code: `MailCore/CommGraph*.swift`, `MailStoreSearch.swift`, `SemanticIndex.swift`, `SearchEngine.swift`,
`SearchPages.swift`; tools in `OfficeTools/GraphTools.swift` + `PeopleTools.swift`; UI `CompliantCalendar/SearchViews.swift`.
- **Graph** (`g_node(k, kind, payload)`): node key = HMAC(graph key, kind:id), payload AES-GCM. People (ego-centric:
  me↔X lives on X), companies by registrable domain (free-mail never), category/folder projects, conversations,
  subject vocabulary (topics = terms in ≥ 3 conversations and ≤ 3 % of them). Adjacency lives inside the sealed
  person payload. Fed by the store's write paths with the *persistable* message, as a diff (old row → new row).
- **BM25**: `tokens.w` = term frequency per (token, row), sender+subject and preview kept apart; `messages.dl` = field
  lengths. df = row count per token (COUNT on the primary key, cached in memory). Exact filter tokens `f:` sender,
  `r:` recipient, `d:` company domain, `c:` category, `x:att`.
- **Semantic**: `NLEmbedding.sentenceEmbedding` per language (en 512-d; de/fr/it/pt 640-d; checked macOS 27.0.1),
  int8 per row, sealed, fixed-size markers for rows the policy refuses; embedded in the background; brute force.
- **Fusion**: RRF(k = 60) of BM25 + cosine, + recency, + graph proximity (user only).

- **Stories** (`StoryEngine.swift`, UI `StoryViews.swift`, tool `story_context`): related mail across conversationIds,
  folders and mailboxes. Per row a fixed-size (640 B) sealed feature record in `story_feat`: keyed hashes of
  participants, company domains, counterpart, conversation; and, only where the on-device AI rule gives `.content`,
  subject terms/stem, rare preview terms, NLTagger names/places/organisations, dates and attachment names. Links fuse
  IDF-weighted shared rare terms, participant overlap, `SemanticIndex` cosine and time decay over a bounded candidate
  set; stories = union-find over ≤ 4 stored edges per row. Edge kinds: conversation, content, metadata (a burst from
  one counterpart, or the same company close in time). Metadata edges never merge two stories that already have
  content evidence, so protected / private / unknown-label mail joins by metadata only and never bridges stories.
  With on-device access `metadataOnly` (BYOD default) only metadata links exist. Titles: Apple FoundationModels
  (2–5 words, memory only, from content-allowed subjects) when available, else the most shared subject term(s); the
  tool's title is always the fallback built from full-exposure subjects. `story_pending` waits for `vec_pending`.

### Leakage of what's stored (attacker = someone with the sqlite file but not the Keychain key)
| Stored | Already visible before this change | New |
|---|---|---|
| `tokens(h, rid)` | Which rows share a term (equality pattern), df per term, tokens per row | — |
| `tokens.w` | — | How often an (unknown) term occurs in a row, split subject/preview. Helps frequency analysis a little (a term with tf 2 in a subject is rare) but reveals no term |
| `messages.dl` | ≈ token count per row (from `tokens`) | Exact subject vs preview length. Low value; it was nearly derivable already |
| filter tokens `f: r: d: c: x:att` | Sender name/address tokens were already indexed | Equality of exact sender/recipient/domain/category across rows (who-talks-to-whom *pattern* between opaque ids; which rows have attachments). Recipients only on rows whose details may be cached |
| `g_node.kind` + payload size | — | Number of people / companies / projects / conversations / terms; rough node size (≈ degree). No names, no edges |
| `vecs` | — | One fixed-size sealed blob per row in the 90-day window (embeddable or not). Nothing about content or label. `vec_pending` shows which rows await embedding |
| `story_feat` / `story_pending` | — | One fixed-size sealed blob per row in the 180-day window (content-allowed or not, same size); which rows await linking. No terms, names, edges or story sizes |
Not stored anywhere: plaintext names, addresses, domains, categories, subjects, terms, vectors (checked by the
self-test: a file-backed store and its WAL are scanned for every fixture name, domain, category and subject word).
Verdict: acceptable for the threat model (stolen device / data left behind): with FileVault + the Keychain-held
key the file is opaque, and without them the counts add statistics only, no content. Vectors are treated as content
(partly invertible), so they're encrypted, label-gated (on-device rule) and limited to the cache window.
