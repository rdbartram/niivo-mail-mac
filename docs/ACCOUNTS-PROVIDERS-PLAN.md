# Account providers plan: Outlook.com, JMAP, IMAP/iCloud, Gmail (2026-11-26)

Status: plan, nothing built. It extends `ACCOUNTS.md`, and only Microsoft 365 works today.

## Registration state
- The Entra registration's audience is `AzureADandPersonalMicrosoftAccount` (since 2026-11-26), with access token v2.
- The bundled authority is still `organizations`.
- Outlook.com needs `common` (or `consumers` for its own tile) plus a reduced scope set. Graph returns errors for personal accounts on Groups, Sites, Presence, Places, OnlineMeetings, InformationProtectionPolicy, SensitivityLabel and RMS, so asking for them at sign-in fails.
- Verified publisher: not linked yet. It must be done by an account with a Partner Center role.

## Where M365 is baked in (fix first: phase 0)
- **Boot** (`AppModel.start/goLive/startMailIfNeeded`):
  - MSAL `Auth` is built unconditionally.
  - `trust.keyring` is only created in `goLive`.
  - Mail waits on `calendarReady`, which means the label tree has loaded.
  - Split the vault/keyring/registry boot from any provider.
- **`MailService`** (`MailCore/MailModels.swift:271`):
  - The core is usable. The `deltaLink` token is opaque, so it can carry a JMAP state or IMAP UIDVALIDITY/MODSEQ.
  - Graph leaks through: `mailbox: "me"`, server rules, auto-replies, regional settings.
  - `MailMessage` lacks `internetMessageId`, `references` and `keywords`.
- **`CalendarService`** (`CalendarCore/CalendarService.swift:50`):
  - Labels, rooms, master categories and groups are mixed into the core protocol.
  - Updates are raw Graph JSON. Move to a typed `EventPatch`.
- **Graph-only services** (People, Presence, Todo, Groups, Drive, OneNote, Directory) need a "not available" variant and capability gating.
- **Labels:**
  - `MIPMetadata.read` defaults to the global home tenant.
  - Add an explicit `LabelScope` (`.tenant(id)` / `.none`) with no default argument. Under `.none`, M365 mail forwarded into a Gmail account is treated as foreign, not fail-closed.
- **Trust:**
  - `SessionHealth` is driven only by Entra signals, and `DefaultWipeExecutor` wipes the whole device. An Entra revocation would currently wipe personal accounts as well.
  - Make wipes per account. Add `TrustPolicy.personalDefault(for:)` with cloud AI off until the user opts in. Don't reuse `.byodDefault`: its `followLabels` exposes everything when there are no labels.
- **MCP:** `OfficeTools/Backend.swift` builds Graph services directly. Move to one Backend per account and register only the tools that account is capable of.

## Architecture
- An `AccountServices` factory per provider provides `mail()`, `calendar()`, `contacts()` and `credentials`.
- `MailService` is split: rules, mailbox settings and shared mailboxes become optional sub-protocols.
- Capabilities are discovered at runtime (IMAP CAPABILITY, the JMAP session) and stored on `Account`. They include focusedInbox, deltaSync, idlePush, serverDrafts, scheduledSend, keywords, autoReplies, directory, presence and drive.
- The UI hides what an account can't do.

## Providers
- **JMAP (Fastmail)**
  - `URLSession` and Codable, `/.well-known/jmap`, `Email/changes` state, EventSource push.
  - API token first.
  - Calendars may need CalDAV (UNVERIFIED).
- **IMAP/SMTP + iCloud**
  - swift-nio-imap (Apache-2.0), with our own connection actor, CONDSTORE/QRESYNC and IDLE.
  - A small `NWConnection` SMTP submitter and our own MIME parser.
  - iCloud uses app-specific passwords, stored in the keychain per account as `ThisDeviceOnly`.
  - MailCore2 is rejected: an ObjC build, and its module name collides with our `MailCore`.
- **CalDAV/CardDAV**
  - WebDAV over `URLSession` with `XMLParser`.
  - Extend `ICSImport` with RRULE and VTIMEZONE.
- **Gmail**
  - Loopback PKCE.
  - Both IMAP+XOAUTH2 and the Gmail API read scopes are *restricted*, so either needs Google verification and a CASA assessment (external, costs money, takes weeks). Start the paperwork early.
  - Until then, "Gmail via app password" works through generic IMAP.
- **Outlook.com:** same Graph code, the `consumers` authority and a reduced scope set. No labels or MIP.

## Sign-up UX
- An account-type chooser in `SignInViews.swift`: Microsoft 365, Outlook.com, Google, iCloud, Fastmail/JMAP, Other IMAP.
- Each tile follows the same flow: email → discovery → credentials → capability probe → confirm ("labels: none, AI: off until you turn it on").
- Discovery order: known-provider table → `/.well-known/jmap` → Mozilla autoconfig/ISPDB → SRV (RFC 6186) → MX hint → manual fields.
- Tell the user that ISPDB lookups reveal their domain to a third party.

## Phases (≈ engineer-weeks)
| # | Scope | Size |
|---|---|---|
| 0 | Decouple boot, factory, `LabelScope`, per-account wipe, `personalDefault`, capabilities, split protocols, MCP per account. All M365 tests stay green, plus new isolation tests. | 2–3 |
| 0.5 | Outlook.com: `common`/`consumers` authority, reduced scopes, labels hidden | 0.5 |
| 1 | JMAP mail plus the chooser UI and discovery | 2 |
| 2 | IMAP/SMTP: iCloud, generic, Gmail via app password | 4–5 |
| 3 | CalDAV/CardDAV, JMAP contacts | 3–4 |
| 4 | Gmail API plus Google OAuth, after verification | 3 + external |

Tests:
- `URLProtocol` stubs for JMAP, DAV and Gmail.
- A scripted in-memory IMAP/SMTP server behind a `ByteTransport` seam.
- Pure tests for discovery, MIME, threading, `LabelScope.none`, per-account wipe isolation, and MCP refusing Graph tools on non-M365 accounts.

Risks: swift-nio-imap maturity and the size of the IMAP client; Google verification; additive store migrations; regressions in M365 guarantees during phase 0.
