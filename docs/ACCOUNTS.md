# Accounts — multiple sign-ins, any tenant, other providers later

Status: phase 1 (Microsoft 365, any tenant) in progress, 2026-11-20. Owner ask: "ability to add other accounts i.e.
other sign-ins to other tenants … initially M365 tenants, but would be good to support Gmail, Apple, Outlook.com,
IMAP/SMTP, JMAP etc."

## 1. Decisions (binding)

| # | Decision | Why |
|---|----------|-----|
| A1 | **Policies are per account** (owner decision, 2026-11-20). Each account's device-trust policy, AI access, screen capture, copy-out, offline storage, label rules and Purview settings apply only to that account's content. | Tenant A's admin governs tenant A's data, not tenant B's. A strictest-wins policy would let one tenant's policy switch off features on another tenant's content. |
| A2 | A window or pane that shows one account's content uses **that account's policy**. A reader or composer uses the policy of the account that owns the message or draft. | Follows from A1. |
| A3 | **Mixed surfaces** (All Inboxes, unified search, notifications, menu-bar count) apply each row's own account policy. If an account blocks capture, its rows are blanked or shielded **per row**, as with today's per-row redaction; other accounts' rows are unaffected. | Follows from A1. |
| A4 | A setting that exists **only at window level** (`NSWindow.sharingType`) takes the **most restrictive value across the accounts currently visible in that window**. This is the only place a cross-account "most restrictive" rule is used. | A window can hold only one value. Leaving the strict account's rows capturable would break that account's policy. |
| A5 | **AI**: each request uses only content its own account allows, under that account's AI policy and tier. Context is never mixed across accounts. Stories are per account. | Each tenant decides whether its content reaches a model. |
| A6 | App-wide settings that can't be per account (launch at login, menu-bar mode, theme, layout) aren't policies and stay global. | Not tenant data. |
| A7 | **Forwarding across accounts** (sending tenant A mail from tenant B's account): unlabelled content is allowed; content whose label has no protection is allowed after an explicit warning; encrypted content, or a label that can't be resolved, is blocked. Same-tenant accounts aren't "cross". Changing the From of a reply or forward to another tenant's identity goes through the same gate. | A label floor belongs to the tenant that applied it. Tenant B can't enforce tenant A's encryption. |
| A8 | Account #1 is the existing single account. Its id is its MSAL home-account identifier, **byte-identical** to the old `auth.accountKey`, so the same store files and keyring slots are reused. Nothing is resynced or deleted on update. | Zero data loss. A different string would make the keyring report `fresh`, which discards the cache. |
| A9 | A non-default account **never** falls back to the process-wide `MIPMetadata.homeTenantId`. Its tenant is passed explicitly to each Graph service, which hands it to the label parser. The global stays as a compatibility shim for the default account only. | If B's labels were parsed against A's tenant, they would read as "foreign" and B's labelled mail would be treated as unlabelled (fails open). |
| A10 | Authority: Add Account always uses `organizations` with `prompt=select_account`. Silent tokens use `https://login.microsoftonline.com/<account tenant>`. | The registration (appId <your-client-id>) was switched to multi-tenant (`AzureADMultipleOrgs`) by the owner on 2026-11-20. Another tenant still has to consent (AADSTS65001/90094 show the admin-consent URL). The single-tenant errors (AADSTS50020/700016/50194) stay mapped for older cached configs. |

## 2. Account model

`CalendarCore/Accounts.swift` (UI-free, tested):

```
Account { id, provider, tenantId?, username, displayName, colour, addedAt }
  id        = MSAL homeAccountId.identifier ("<oid>.<tid>") for Microsoft 365; provider-specific for later providers
  storeKey  = AccountStoreNaming.safeName(id), the same function CacheKeyring.safeName uses
AccountRegistry { accounts (ordered), defaultAccountId }    // add / remove / move / recolour / default
```

- The registry is persisted **sealed** (`AESGCMCipher`) in `accounts.sealed` under a keyring slot that belongs to
  no single account (`"accounts-registry"`), so removing any account, including #1, keeps the registry readable.
- **Unreadable is not absent.** If the file exists but can't be opened (keyring locked, wrong key), migration
  doesn't run and the file isn't overwritten. The app keeps working as the legacy single account until it unlocks.
- **Migration** (`AccountMigration.plan`): no registry file plus a signed-in MSAL account means one `Account` with
  `id = homeAccountId` becomes the default. Nothing is copied, renamed or resynced.
- Store files per account (unchanged naming): `<safe id>.sqlite` (calendar), `<safe id>-mail.sqlite` (mail).
  Keyring slots: `<safe id>/<purpose>`. Removing an account deletes both files and its slots, then calls
  `MSAL remove(account)`.

## 3. Provider abstraction

`AccountProvider`: `.microsoft365` (phase 1), with `.outlookCom`, `.gmail`, `.icloud`, `.imap`, `.jmap` declared
for later phases. They're not selectable in the UI.

`ProviderCapabilities` (OptionSet) describes what a provider can do: `mail`, `calendar`, `contacts`, `tasks`,
`sensitivityLabels`, `rightsManagement`, `sharedMailboxes`, `serverSearch`, `push`, `categories`, `serverRules`,
`sendAs`. Surfaces check capabilities, never the provider. For example, the label picker appears only when
`sensitivityLabels` is set, and the shared-mailbox menu only when `sharedMailboxes` is set.

Service protocols. Graph is the first implementation of each. The app already uses `CalendarService` (CalendarCore)
and `MailService` (MailCore); phase 2 adds a provider factory:

```
protocol AccountServices {          // one per signed-in account
  var account: Account { get }
  var capabilities: ProviderCapabilities { get }
  func mail() -> MailService?       // nil if the provider has no mail
  func calendar() -> CalendarService?
  func contacts() -> ContactsService?   // phase 2
}
```

| Provider | Mail | Calendar | Contacts | Labels/RMS | Notes |
|---|---|---|---|---|---|
| Microsoft 365 (Graph) | Graph | Graph | Graph | yes (MIP) | phase 1 |
| Outlook.com (MSA) | Graph (consumers) | Graph | Graph | no | needs `AzureADandPersonalMicrosoftAccount` audience |
| Gmail | Gmail API (or IMAP + XOAUTH2) | Google Calendar API | People API | no | OAuth app verification + restricted-scope security assessment for `gmail.modify` |
| iCloud | IMAP/SMTP (app-specific password) | CalDAV | CardDAV | no | no OAuth; app-specific password in the keychain |
| IMAP/SMTP | IMAP4rev1 + IDLE, SMTP AUTH (PLAIN/XOAUTH2) | none (CalDAV optional) | none (CardDAV optional) | no | UID/MODSEQ (CONDSTORE/QRESYNC) sync |
| JMAP (Fastmail, etc.) | JMAP Mail + EventSource push | JMAP Calendars | JMAP Contacts | no | session URL discovery |

## 4. Subsystems, per account

| Subsystem | Today (single) | Phase 1 |
|---|---|---|
| Auth (MSAL) | one `Auth`, `allAccounts().first` | one `Auth` per account, sharing a single MSAL application/cache; account looked up **by identifier**; silent authority `/<tenantId>`; CAE (CP1) and claims challenges per account; sign-out per account |
| Store + keyring | keyed by `accountKey` | unchanged keys (A8); one file pair and one slot pair per account |
| Label tenant | static `MIPMetadata.homeTenantId` | `homeTenant` on each `GraphMailService` / `GraphCalendarService` / `GraphGroupsService`; the static remains for the default account only (A9) |
| Label tree, policy engine | one `CachedLabelPolicyEngine` | one per account, synced from that tenant |
| MIP bridge / RMS | one coordinator | one context per account, built with that account's UPN and its RMS token (`aadrm.com`, authority = account tenant) |
| Trust policy | one effective policy | `AccountPolicies`: account id → `TrustPolicy`; `policy(for:)`, `rowShielded`, `windowSharing(visible:)` (A1–A4) |
| AI gate / Stories / semantic index | one | per account (A5): `AIContextScope.filter` drops other accounts' items before a request is built |
| Search | one index per store | one index per account (it lives in the store); unified search queries each and passes every row through its own account's policy |
| Notifier, menu-bar count | one | each item carries its account id; shielding per item (A3) |
| PeopleHub | one | per account, so directories don't mix |
| OfficeMCP / agent tools | one backend | `AccountScope`: the tool argument `account` (id, UPN or `"default"`); results tagged with `account`; no single result spans accounts |
| Shared/delegated mailboxes | `"me"` / address strings inside the one account | unchanged, now nested under their owning account |

## 5. Auth errors

`AccountAuthError.classify(errorText, tenant, clientId)` (pure, tested):

| AADSTS | Meaning | Shown |
|---|---|---|
| 50020, 700016, 50194 | app not enabled for that organisation (single-tenant registration) | "This app isn't enabled for other organisations yet." |
| 65001, 90094, 90095 | admin consent required | "An administrator of this organisation needs to approve niivo mail." + `https://login.microsoftonline.com/<tenant>/adminconsent?client_id=<appId>` (copy / open) |
| anything else | as today | MSAL's message |

We don't work around these errors. No retry loops, and no fallback to another tenant.

## 6. UI (phase 1)

- **Settings → Accounts**: list (colour dot, name, UPN, tenant, default badge), Add Account (browser PKCE with
  `prompt=select_account`), Remove (confirm; wipes that account's stores, keyring slots and MSAL account), move
  up/down, colour, make default.
- **Sidebar**: when there's more than one account, accounts appear as top-level groups with a colour dot. Each
  group holds its own folders and shared mailboxes.
- **Composer From**: identities from all accounts, labelled with the account. A reply defaults to the account that
  received the message. Changing to another tenant's identity runs the forward gate (A7).
- **All Inboxes**: spans accounts; each row shows the account colour and is shielded under its own account's policy.

## 7. Phase 2/3 — listed, not built

- Gmail: Google OAuth client (loopback/PKCE), app verification, CASA security assessment for restricted scopes,
  Gmail API history-id sync, labels mapped to folders, Google Calendar + People API.
- Outlook.com: change the audience to `AzureADandPersonalMicrosoftAccount` (`consumers` tenant); no MIP.
- IMAP/SMTP: IMAP4rev1, IDLE (one connection per watched folder), CONDSTORE/QRESYNC, SMTP AUTH with STARTTLS/
  implicit TLS, XOAUTH2 for providers that support it, and per-account password storage in the keychain.
- iCloud: IMAP/SMTP + CalDAV/CardDAV with app-specific passwords.
- JMAP: session discovery, `Email/changes`, EventSource / WebPush push, JMAP Calendars.
- Cross-provider: a mail-model adapter so Gmail labels and IMAP keywords map to folders and categories, and a
  "no labels" capability so compliance features hide cleanly.

## 8. Build status (2026-11-20)

**Built.** Phase 1a runs one live session at a time; the open account's session is the only one.
- Core, self-tested in `CoreSelfTest/AccountsTests.swift`: `CalendarCore/Accounts.swift`, `TrustCore/AccountPolicies.swift`,
  `MailCore/CrossAccount.swift` and `OfficeTools/AccountScope.swift`. The Graph mail and calendar services carry
  `accountTenant`.
- App:
  - `Auth`: a shared MSAL application, account looked up by identifier, a tenant-scoped silent authority, and
    Add Account.
  - `AccountsModel`: sealed registry, migration, add/remove/move/colour/default, switch.
  - `AppModel.switchAccount` closes the session as a lock does and resets the label engine (empty and unsynced, so
    it fails closed until the new tenant's tree loads), then opens the other account's own stores and tenant.
  - Settings → Accounts, and account rows at the top of the mail sidebar.

**Why one session at a time first.** Several app-level singletons hold one account's state: PurviewPolicy,
MailOrg2, MailNotifier, SearchBoxState, LicenceRightsStore, AttachmentPreviewStore and the ProtectedContent
coordinator. Running two accounts at once without making these per-account would mix tenants. Switching uses the
lock path, which already drops all of them.

**Phase 1b.** A `MailModel` and `SyncEngine` per account running at once, with those singletons keyed by account.
That enables All Inboxes, unified search, the From picker across accounts with the gate (A7), per-row policy and
shielding in the UI (A3), and `AccountToolRouter` in the in-app agent. Groups (`GraphGroupsService`) still parse
labels with the shim, which is correct while only one session is open; give it an `accountTenant` in 1b.

**Known limits in 1a.**
- The sidebar is an account switcher, not groups with their folders. The open account's folders follow underneath.
- At launch the app opens the account that was open last, not the "Default" one. Default only decides which
  account the app moves to after a removal.
- The trust policy is device-wide today (managed preferences and built-in defaults; there's no tenant-hosted policy
  yet), so every account gets the same values. `AccountPolicies` is where per-tenant policies go once they load.
- `config.json` shared and delegated mailboxes belong to the configured tenant's account only.
- People, Tasks and Presence are reconfigured (their caches cleared) when the account changes. The label policy
  settings (`PurviewPolicy`) are reset, and the label engine is emptied until the new tenant's tree loads.
- A silent token for account #1 (the configured tenant) uses the application's own authority, as before. Other
  accounts use `https://login.microsoftonline.com/<tenant>`.
