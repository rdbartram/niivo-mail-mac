# Compliant Office: Mail — research (2026-11-19)

Feature map, compliance constraints and suite roadmap for the native macOS M365 mail client. Companion to
`MAIL-PLAN.md` (what we build) and `VIEWS.md` (calendar lenses). Microsoft claims carry the Learn URL they
came from; anything we could not confirm in Learn is marked **UNVERIFIED**. "None found in Learn" is an absence claim,
not proof that no API exists.

## TL;DR — the four findings that decide the architecture

| Question | Answer | Confidence |
|---|---|---|
| Can a third-party client show Purview **DLP policy tips**? | No policy-tip API found. The support matrix lists Microsoft apps only and marks third-party cloud apps "not supported". The Purview `protectionScopes`/`processContent` APIs are a different surface (for Entra-registered apps, usually AI); using them as a pre-send DLP check is **UNVERIFIED**. | High (no API) / Low (workaround) |
| Can we **write a sensitivity label on send** via Graph? | No first-class label property on `message`. JSON custom headers must start with `x-`, so `msip_labels` can't be set that way. MIME and extended-property routes are **UNVERIFIED**, and so is whether Exchange then applies marking or encryption. Reading labels works. | Medium |
| **Deferred send** via Graph? | `PidTagDeferredSendTime` (0x3FEF) is documented for EWS and Outlook add-ins only. Setting it as a Graph extended property is **UNVERIFIED**. EWS can't be the fallback: phased disablement is scheduled from 1 Oct 2026 and full retirement is 1 Apr 2027. | Medium |
| Do CA "approved client app" / "app protection policy" grants work for a Mac third-party client? | No. Both target iOS/Android (APP is also in preview for Edge on Windows). macOS isn't supported when either is the only grant. On Mac the lever is **device compliance** via Company Portal and Platform SSO. How a tenant-wide APP-required policy affects our app is **UNVERIFIED**; test in report-only mode. | High |

---

## 1. What Outlook does well — keep it

Priority: **P0** = can't ship without it, **P1** = first release after the pilot, **P2** = later or only on request.

| Feature | Pri | Graph API | Note |
|---|---|---|---|
| Focused Inbox | P0 | `message.inferenceClassification` (focused/other) plus `inferenceClassification/overrides` per sender — [manage-focused-inbox](https://learn.microsoft.com/graph/api/resources/manage-focused-inbox?view=graph-rest-1.0) | Server-side, so it stays in sync with Outlook. Classification only applies to the Inbox. This is the base for our split inbox (§2). |
| Rules | P1 | `messageRule` on the Inbox (list/create) — [user resource](https://learn.microsoft.com/graph/api/resources/user?view=graph-rest-1.0#methods) | Server-side rules run with the app closed. Client-only rules, as Outlook classic has, are out by design. |
| Categories | P0 | `message.categories` + master list `outlookCategory` — [mail-api-overview](https://learn.microsoft.com/graph/api/resources/mail-api-overview?view=graph-rest-1.0#common-use-cases) | Colours round-trip with Outlook. Use categories as our "labels" (§2) instead of inventing a parallel tag store. |
| Flags / follow-up with due date | P0 | `message.flag` (`followupFlag`: start, due, completed) — [followupflag](https://learn.microsoft.com/graph/api/resources/followupflag?view=graph-rest-1.0) | Setting `dueDateTime` without `startDateTime` returns 400. Flagged mail appearing in To Do: **UNVERIFIED**. |
| Shared mailboxes | P0 | `/users/{id}/messages`, `Mail.Send.Shared` — [send from another user](https://learn.microsoft.com/graph/outlook-send-mail-from-other-user) | **Graph can't list which mailboxes a user has access to** (same page). Users or admins must add them by address, or we read admin config (§3). `mailboxSettings.userPurpose` identifies shared mailboxes — [mailboxSettings](https://learn.microsoft.com/graph/api/resources/mailboxsettings?view=graph-rest-1.0). |
| Send-as / send on behalf | P0 | Set `from` and Graph fills in `sender` from the mailbox permissions — [send from another user](https://learn.microsoft.com/graph/outlook-send-mail-from-other-user#sending-with-microsoft-graph) | Which Sent Items gets the copy depends on the endpoint used and on Full Access. Show that in the UI. |
| Delegated mailboxes (assistant mode) | P1 | Same as shared, plus `delegateMeetingMessageDeliveryOptions` — [mailboxSettings](https://learn.microsoft.com/graph/api/resources/mailboxsettings?view=graph-rest-1.0) | Managing delegate permissions isn't in Graph. An Exchange Admin API for folder permissions is targeted for Q4 CY2026 — [EWS deprecation roadmap](https://learn.microsoft.com/exchange/clients-and-mobile-in-exchange-online/deprecation-of-ews-exchange-online#roadmap-for-parity-gaps). Reuses VIEWS.md's Assistant mode. |
| Conversation view | P0 | `conversationId` on `message` — [mail-api-overview](https://learn.microsoft.com/graph/api/resources/mail-api-overview?view=graph-rest-1.0#common-use-cases) | Threads are grouped on the client. Replies must go through `createReply`/`createReplyAll`/`createForward` to keep threading — [create & send](https://learn.microsoft.com/graph/outlook-create-send-messages#create-and-send-mail). |
| Search | P0 | `$search` (KQL) on `/messages` — [search-query-parameter](https://learn.microsoft.com/graph/search-query-parameter#use-$search-on-message-collections); `/search/query` for message and event — [search-api-overview](https://learn.microsoft.com/graph/api/resources/search-api-overview?view=graph-rest-1.0#scope-search-based-on-entity-types) | Server search plus local full-text search over the *permitted* cache (protected bodies aren't cached, see MAIL-PLAN). Combining `$filter` and `$search` on one request: **UNVERIFIED** (assume not). |
| Quick Steps | P1 | None found in Learn | Rebuild as client-side macros over Graph actions (move + categorise + flag). They won't sync with Outlook's Quick Steps. |
| Signatures | P0 | None found in Learn | Store the signature locally or in an open extension. Roaming signatures from Outlook don't come across. **UNVERIFIED** whether any API exposes them. |
| Automatic replies | P0 | `mailboxSettings.automaticRepliesSetting` — [update mailboxSettings](https://learn.microsoft.com/graph/api/user-update-mailboxsettings?view=graph-rest-1.0) | Supports internal and external text, scheduled windows and audience. |
| Meeting invites in mail | P0 | `eventMessage` / accept-decline on the event — **UNVERIFIED** (not searched in this pass) | Reuses CalendarCore. Show inline RSVP plus a conflict check against the cache. |
| Teams meeting from mail ("Reply with meeting") | P1 | Event with online meeting turned on (`isOnlineMeeting`) — **UNVERIFIED** in this pass | Create the event prefilled from the thread's recipients and subject. |
| S/MIME | P2 | MIME send/createReply with S/MIME — [outlook-send-mime-message](https://learn.microsoft.com/graph/outlook-send-mime-message); 4 MB S/MIME payload limit — [create message](https://learn.microsoft.com/graph/api/user-post-messages?view=graph-rest-1.0) | We'd sign and encrypt locally (Keychain or smart card). Copilot doesn't return S/MIME mail — [ai-entra-registered](https://learn.microsoft.com/purview/ai-entra-registered#capabilities-supported). |
| Sensitivity labels | P0 | Read: label metadata on the item. List: `/me/security/informationProtection/sensitivityLabels` (beta) — [list sensitivityLabels](https://learn.microsoft.com/graph/api/security-informationprotection-list-sensitivitylabels?view=graph-rest-beta). Write: see §3. | Hard compliance requirement. Detail in §3. |
| OneDrive attachments as links | P1 | `referenceAttachment` — [referenceattachment](https://learn.microsoft.com/graph/api/resources/referenceattachment?view=graph-rest-1.0) | The v1.0 resource exposes no source-URL or permission property, so creating sharing links through it isn't a clean v1.0 path. Fallback: create a sharing link via the drive API and insert it in the body. Large files: upload session, 3–150 MB — [attachment](https://learn.microsoft.com/graph/api/resources/attachment?view=graph-rest-1.0). |
| Read receipts | P2 | `isReadReceiptRequested`, `isDeliveryReceiptRequested` — [message](https://learn.microsoft.com/graph/api/resources/message?view=graph-rest-1.0#properties) | Default off. For *incoming* receipt requests, ask the user before replying. Never auto-send one. |
| Delay delivery | P1 | No first-class property. `PidTagDeferredSendTime` 0x3FEF — [MAPI](https://learn.microsoft.com/office/client-developer/outlook/mapi/pidtagdeferredsendtime-canonical-property); EWS example — [EWS send](https://learn.microsoft.com/exchange/client-developer/exchange-web-services/how-to-send-email-messages-by-using-ews-in-exchange#send-a-delayed-email-message-by-using-the-ews-managed-api); add-in API — [delay-delivery](https://learn.microsoft.com/office/dev/add-ins/outlook/delay-delivery) | Setting it as a Graph `singleValueExtendedProperty` (`SystemTime 0x3FEF`) is **UNVERIFIED**. Spike before promising server-side send-later. A client-side outbox works only while the Mac is awake. |
| Voting buttons | P2 | None found in Learn | Read-only render if we can parse the MAPI verb stream (**UNVERIFIED**). Creating votes isn't planned. |
| @mentions | P1 | `mentions` collection — seen only in **beta** cmdlet docs ([example](https://learn.microsoft.com/powershell/module/microsoft.graph.beta.users.actions/invoke-mgbetareplyusermessage?view=graph-powershell-beta#notes)) | Beta only: read it for a "mentioned me" filter, don't build on it for writes. |
| Offline / cached mode | P0 | Delta query on messages — [message](https://learn.microsoft.com/graph/api/resources/message?view=graph-rest-1.0) | Our encrypted `MailStore` plus outbox. Policy decides what may be cached (protected → metadata only). Use `Prefer: IdType="ImmutableId"` so local IDs survive moves (same page). |
| Keyboard shortcuts | P0 | n/a | Offer Outlook-compatible and Gmail/Superhuman-style keymaps (§2). |
| Add-ins | P2 | None for third-party hosts found in Learn. The Office JS sensitivity-label and delivery APIs run *inside* Outlook — [sensitivity-label add-ins](https://learn.microsoft.com/office/dev/add-ins/develop/sensitivity-label) | Our MCP server is the extensibility surface. Add-in parity isn't realistic. |
| MailTips (external recipient, OOF, large audience) | P1 | `getMailTips` — [user resource](https://learn.microsoft.com/graph/api/resources/user?view=graph-rest-1.0#methods) | Cheap pre-send warnings. Also a partial stand-in for DLP tips (§3). |

---

## 2. Modern ideas worth taking

*From product knowledge, not a sourced study.* Behaviour of non-Microsoft apps is described from general familiarity
and may be out of date. The Exchange/Graph implementation column uses the §1 sources.

"Breaks in Outlook?" means what a user sees after going back to Outlook for Mac or OWA.

| Idea | Source | Worth it? | Implementation on Exchange/Graph | Breaks in Outlook? |
|---|---|---|---|---|
| Speed: local-first UI, optimistic actions | Superhuman | **Yes, core** | Encrypted cache + delta sync + outbox (MAIL-PLAN `MailSync`) | No |
| Command palette (⌘K) | Superhuman, Linear | **Yes, core** | Client only, every action addressable | No |
| Keyboard-first triage (e/j/k/r/#) | Superhuman, Gmail | **Yes** | Client keymap over Graph move/flag/categorise | No |
| Split inbox (VIP, Team, Calendar, Newsletters…) | Superhuman, Spark | **Yes** | Client-side saved views over Focused/Other + categories + sender lists. Optional server-side rules that set a category. | Views no. Categories set by rules are visible in Outlook (fine). |
| Undo send (5–30 s) | Superhuman, Gmail | **Yes** | Hold in the local outbox before calling `send` (no Graph recall found in Learn). | No (nothing leaves until the timer ends) |
| Instant reminders / snooze | Superhuman, Spark, Gmail | **Yes** | **Option A (client):** move to a "Snoozed" folder and move back on a timer (needs the Mac awake). **Option B (server):** flag with `startDateTime`/`dueDateTime` and keep it in the Inbox. | A: mail sits in a strange folder in Outlook and never comes back if our app is gone. B: it shows as a flag (acceptable). **Prefer B, or A plus a fallback server rule (UNVERIFIED).** |
| Send later | Spark, Gmail | Yes | Server-side if the 0x3FEF spike works (§1). Otherwise client outbox with an "only while this Mac is awake" warning. | Client version: an unsent draft in Drafts |
| Screener (first-time senders held) | HEY | **Maybe — P2** | Client-side: senders not in Contacts or history go to a "Screener" view. Approving one creates an `inferenceClassification` override (focused). | Outlook shows them as normal Inbox mail (safe degradation) |
| Imbox / Feed / Paper Trail | HEY | Partly | Map to Focused, Other plus newsletter heuristics, and a receipts category | Categories only |
| Set Aside / Reply Later | HEY | **Yes** | Category "Reply later" plus a flag. A tray in the UI. | Shows as a category and flag (good) |
| Smart inbox / bundles | Spark, Shortwave, Notion Mail | Yes (P1) | Client grouping by sender domain, list-id, category | No |
| Shared drafts / team comments on a thread | Spark, Missive, Front | **P2, hard** | No Exchange primitive. Needs our own backend (comments keyed by `internetMessageId`) or a Teams chat linked to the thread. Back end needs a data-residency review. | Invisible in Outlook |
| Templates / snippets | Spark, Gmail | Yes | Local store; optional open extension | No |
| Follow-up suggestions ("no reply in 3 days") | Apple Mail, Gmail nudges | **Yes** | Client: sent items with no reply in the conversation → nudge. Optional flag. | No (a flag if set) |
| Remind Me | Apple Mail | Yes | Same as snooze option B | Flag |
| Categories auto-sorting | Apple Mail | Covered by Focused + rules | — | — |
| Hide My Email | Apple Mail | **No** | Conflicts with corporate identity and send-as policy | — |
| Smart compose | Gmail | Maybe, via MCP | Local model or a policy-gated egress (§4) | No |
| Labels (multi-folder) | Gmail | Use categories | `categories` | No |
| AI search ("what did finance say about Q4") | Shortwave, Notion Mail | **Yes, P1** | Graph `/search/query` plus local embedding index over *permitted* content only (§4). Work IQ is the Microsoft-hosted alternative (§4). | No |
| AI-organised views | Notion Mail, Shortwave | Maybe | Client classification writing categories | Categories visible |
| Shared inbox: assignment, status, collision detection | Missive, Fastmail | **P1 for shared mailboxes** | Assignment as a category ("@assignee") plus our own presence channel. Server-safe part: categories and flags. | Assignment shows as a category |
| Linear-style triage (Inbox zero as a queue; done/snooze/assign) | Linear | **Yes, the UX model** | Done = archive (well-known folder), snooze = option B, assign = category | No |

Design rule from this table: **anything that must survive a return to Outlook lives on the server as a category, flag,
folder or Focused override.** Client-only state is a view, never the source of truth.

---

## 3. Compliance & management on macOS

### 3.1 Sensitivity labels on mail

| Requirement | What Microsoft documents | What it means for us |
|---|---|---|
| Label storage | Labels are clear-text metadata, and third parties can read them — [sensitivity-labels](https://learn.microsoft.com/purview/sensitivity-labels#what-a-sensitivity-label-is). On email, all attributes are serialised into one header, `MSIP_Labels` — [MIP metadata](https://learn.microsoft.com/information-protection/develop/concept-mip-metadata#support-for-protected-coauthoring) | Read it on every message (already done for events via `$batch` extended properties). |
| Header stripping | Non-enterprise clients may strip `msip_labels`/x-headers on reply — [pspf-dlp-marking](https://learn.microsoft.com/compliance/anz/pspf-dlp-marking#risk-of-x-header-stripping) | We must *preserve* the header on reply/forward. Using `createReply*` keeps the server-side item lineage. |
| Label catalogue | `GET /me/security/informationProtection/sensitivityLabels` (**beta**, `InformationProtectionPolicy.Read`) — [list](https://learn.microsoft.com/graph/api/security-informationprotection-list-sensitivitylabels?view=graph-rest-beta). Policy settings resource `labelPolicySettings` (beta) — [informationProtection](https://learn.microsoft.com/graph/api/resources/security-informationprotection?view=graph-rest-beta) | Candidate source for **mandatory labelling, default label and downgrade justification**. Its exact fields aren't confirmed: **UNVERIFIED**. Whether the MIP Policy SDK exposes these settings is also **UNVERIFIED** (the page below covers policy retrieval and computed actions only). |
| Compute actions | The Policy SDK retrieves the user's label policy and "computes" the metadata, marking and protection to apply — [API concepts](https://learn.microsoft.com/information-protection/develop/concept-apis-use-cases#policy-sdk) | **Recommended path:** MIP Policy SDK in the app, driving the label picker, mandatory and default label, justification, and the exact `MSIP_Labels` string. |
| Inheritance on reply / attachments | v1.0 `sensitivityLabel: computeInheritance` and `computeRightsAndInheritance` (`SensitivityLabel.Evaluate`) — [sensitivityLabel](https://learn.microsoft.com/graph/api/resources/security-sensitivitylabel?view=graph-rest-1.0), [computeRightsAndInheritance](https://learn.microsoft.com/graph/api/sensitivitylabel-computerightsandinheritance?view=graph-rest-1.0#request-body) | Use it to pick the label for a reply or forward that contains labelled attachments. MAIL-PLAN's rule stays: a reply can't downgrade. |
| Writing the label on send | No `sensitivityLabel` property on `message`. JSON custom headers must start with `x-` — [message](https://learn.microsoft.com/graph/api/resources/message?view=graph-rest-1.0). MIME drafts are supported — [create message](https://learn.microsoft.com/graph/api/user-post-messages?view=graph-rest-1.0) | Candidates: (a) MIME draft carrying an `msip_labels` header, (b) extended property. Both **UNVERIFIED**, including whether Exchange then applies marking and encryption. **Fallback that is documented:** service-side auto-labeling policies for Exchange — [auto-label](https://learn.microsoft.com/purview/apply-sensitivity-label-automatically). |
| Encryption | Outlook for Mac (16.79+), new Outlook, OWA and mobile don't encrypt locally; Exchange encrypts after send, and Sent Items copies stay unencrypted — [labels in Office apps](https://learn.microsoft.com/purview/sensitivity-labels-office-apps#when-office-apps-apply-content-marking-and-encryption). Mobile Outlook doesn't decrypt either; Exchange does — [Outlook iOS/Android](https://learn.microsoft.com/exchange/clients-and-mobile-in-exchange-online/outlook-for-ios-and-android/sensitive-labeling-and-protection-outlook-for-ios-android) | **Good news:** Microsoft's own modern clients rely on the service, so we can too *if* the label write is honoured (row above). Reading protected mail: **UNVERIFIED** whether Graph returns decrypted bodies to a third-party app. Otherwise MIP SDK decryption is needed. |
| MIP SDK on Mac | C++ .zip for macOS, Xcode 13+ — [setup](https://learn.microsoft.com/information-protection/develop/setup-configure-mip#configure-your-client-workstation). Supports .msg/.eml label and protect; .rpmsg is inspect-only and produces no usable output — [email processing](https://learn.microsoft.com/information-protection/develop/concept-email). Proxies on macOS: transparent only — [proxies](https://learn.microsoft.com/information-protection/develop/concept-mip-proxies#proxies-and-the-mip-sdk) | Wrap through a C shim for Swift. **Tension:** the house rule says CLT only, no Xcode. Whether the SDK links with CLT alone is **UNVERIFIED**. Spike first. Authenticated or explicit proxies are unsupported, which matters for some corporate networks. |

### 3.2 DLP policy tips

- **No third-party policy-tip API found.** The matrix covers Outlook (Win32, Mac, mobile, web), Office, Teams and
  endpoints, and marks "3rd party cloud apps" as not supported —
  [dlp-policy-tips-reference](https://learn.microsoft.com/purview/dlp-policy-tips-reference#support-matrix-for-dlp-policy-tips-across-microsoft-apps).
  Exchange transport DLP should still apply server-side to anything we send (NDR or block) — **UNVERIFIED**, test it;
  either way users get no pre-send tip.
- **Adjacent surface:** the Purview data security APIs (`protectionScopes/compute` → `processContent`, plus
  `contentActivities`) let "enterprise applications (AI, line-of-business, SaaS)" evaluate content against DLP —
  [Purview APIs overview](https://learn.microsoft.com/purview/developer/microsoft-purview-sdk-documentation-overview#scenarios-and-api-overview),
  [Graph overview](https://learn.microsoft.com/graph/security-datasecurityandgovernance-overview#protection-scope).
  Caveats: activities are `uploadText`/`downloadText` and similar, not "send mail". Admins must target Entra-registered
  apps; the tutorial says policies created in the portal UI don't apply to them (use `New-DlpComplianceRule`) —
  [tutorial](https://learn.microsoft.com/purview/developer/use-the-api#step-1-compute-protection-scopes-for-the-user).
  **This isn't an Exchange DLP tip.** It's the right gate for the **MCP egress path** (§4). Using it as a pre-send
  check in the composer is **UNVERIFIED**.
- **Practical pre-send set:** MailTips (external recipients), label-driven rules from the Policy SDK, and
  `processContent` where the tenant opts in.

### 3.3 Intune on macOS

| Capability | Mac reality | Source |
|---|---|---|
| App protection policies (MAM) | macOS is absent from the supported list (Android, iOS/iPadOS, Windows) | [APP overview](https://learn.microsoft.com/intune/app-management/protection/overview#supported-platforms-for-app-protection-policies) |
| Device compliance + Conditional Access | The substitute. Company Portal on macOS ships the Enterprise SSO plug-in; MSAL apps use it automatically | [Enterprise SSO plug-in](https://learn.microsoft.com/entra/identity-platform/apple-sso-plugin), [macOS SSO plug-in](https://learn.microsoft.com/intune/device-configuration/templates/configure-enterprise-sso-plugin-macos#app-support) |
| Platform SSO | macOS 13+, Company Portal 5.2404+ | [Platform SSO](https://learn.microsoft.com/intune/device-configuration/settings-catalog/configure-platform-sso-macos#prerequisites) |
| Device identity keys | Secure Enclave by default for new registrations since Aug 2025. Apps must use MSAL + SSO plug-in, not raw Keychain | [SSO plug-in: key storage](https://learn.microsoft.com/entra/identity-platform/apple-sso-plugin#device-identity-key-storage) |
| Token protection | Supported for Outlook, Teams, OneDrive and Office on macOS. Apple Mail/Calendar are blocked. A third-party MSAL app's eligibility is **UNVERIFIED** | [token protection Apple](https://learn.microsoft.com/entra/identity/conditional-access/deployment-guide-token-protection-apple#supported-applications-and-resources) |
| Managed app config | Intune "Preference file" (.plist) per bundle ID, device channel, MDM-enrolled only; Intune doesn't validate the keys | [preference file](https://learn.microsoft.com/intune/device-configuration/templates/configure-preference-file-macos#prerequisites) |
| Copy/print/save, app lock, screenshot block | No Intune control on Mac. **The app enforces these itself**, keyed by label and managed preferences (MAIL-PLAN) | — (design) |
| Selective wipe | No MAM wipe on Mac. Ours: on a managed-pref flag, sign-out, or failed compliance at token refresh → crypto-erase the cache key. Full device wipe stays MDM | design; MDM wipe only for enrolled devices — [APP overview](https://learn.microsoft.com/intune/app-management/protection/overview) |

Managed preference keys we should publish (proposal): `AllowedTenants`, `DisableAIEgress`, `AIEgressMaxLabelPriority`,
`CacheProtectedBodies` (always false, informational), `BlockPrintForLabels`, `BlockCopyForLabels`, `RequireAppLock`,
`WipeOnNextLaunch`, `SharedMailboxes` (works around Graph's missing "which mailboxes can I open").

### 3.4 Conditional Access grant controls

- *Require approved client app*: "Only supports the iOS and Android for device platform condition". The grant is
  **retiring (early March 2026)**; new policies should use *Require app protection policy* —
  [CA grant](https://learn.microsoft.com/entra/identity/conditional-access/concept-conditional-access-grant#grant-access).
- *Require app protection policy*: generally available for iOS and Android, preview for Edge on Windows. Apps that
  integrate the Intune SDK or App Wrapping Tool can be managed — [APP overview](https://learn.microsoft.com/intune/app-management/protection/overview);
  the SDK is iOS/Android only (per MAIL-PLAN). Apps that don't support APP are blocked —
  [migrate](https://learn.microsoft.com/entra/identity/conditional-access/migrate-approved-client-app#create-a-conditional-access-policy).
- "Selecting macOS or Linux device platforms isn't supported when you select **Require approved client app** or
  **Require app protection policy** as the only grant controls" —
  [CA conditions](https://learn.microsoft.com/entra/identity/conditional-access/concept-conditional-access-conditions#device-platforms).
- **For us:** we can never satisfy those grants. Tenants should use "compliant device" OR "APP" (*Require one of the selected
  controls*). Microsoft documents that pattern for Windows —
  [Windows APP](https://learn.microsoft.com/entra/identity/conditional-access/policy-all-users-windows-app-protection#create-a-conditional-access-policy);
  applying it to macOS is our inference.
  The Mac then passes on device compliance through the SSO plug-in broker. A policy that *includes* macOS with APP as
  the only grant, or an all-platforms policy, blocks us. Exact sign-in behaviour is **UNVERIFIED**; validate with
  report-only mode in a test tenant.

---

## 4. AI / MCP

### 4.1 What the MCP server exposes (proposal)

| Kind | Name | Notes |
|---|---|---|
| Tool | `mail.search(query, folder?, since?, limit)` | Returns metadata plus a policy-trimmed snippet |
| Tool | `mail.get(id, part=headers\|body\|attachments)` | Body only if policy allows (below) |
| Tool | `mail.thread(conversationId)` | Same trimming per message; thread label = highest priority |
| Tool | `mail.draft(to, subject, body, replyTo?)` | **Creates a draft only.** Uses `createReply*` when replying; inherits the label |
| Tool | `mail.triage(id, action=archive\|flag\|category\|snooze)` | Reversible actions only; logged |
| Tool | `calendar.freeBusy(people, window)` / `calendar.propose(...)` | Reuses `ScheduleView.freeGaps`; proposals become drafts or tentative holds |
| Resource | `mail://inbox/focused`, `mail://flagged`, `mail://reply-later` | Read-only views |
| Prompt | `triage-my-inbox`, `draft-reply` | Templates that only call the tools above |
| Not exposed | send, delete, rules, forwarding, OOF changes, mailbox permissions | Exfiltration and persistence vectors. A human sends from the app. |

### 4.2 Security model

1. **Policy-gated egress.** Every result passes `AIAccessPolicy`. Unknown, protected or private items fail closed.
   Items at or above the label-priority threshold return metadata only. Where the tenant opts in, call `processContent`
   (`downloadText` towards the model) and honour `restrictAccess` —
   [tutorial step 2](https://learn.microsoft.com/purview/developer/use-the-api#step-2-process-content).
2. **Mirror Copilot's label behaviour** so tenants get one mental model:
   - Encrypted content needs **VIEW and EXTRACT** before an AI returns it.
   - VIEW without EXTRACT → link only.
   - Labels shown on results; the highest-priority label is inherited by generated content.
   - DKE never accessible.

   Sources: [Copilot data protection](https://learn.microsoft.com/copilot/plan/architecture-data-protection-auditing#how-microsoft-copilot-works-with-sensitivity-labels-and-encryption),
   [EXTRACT](https://learn.microsoft.com/purview/ai-m365-copilot-considerations#information-protection-considerations-for-microsoft-365-copilot).
   Check rights with `usageRightsIncluded` / `computeRightsAndInheritance` —
   [sensitivityLabel](https://learn.microsoft.com/graph/api/resources/security-sensitivitylabel?view=graph-rest-1.0).
3. **DLP-for-Copilot parity.** Tenants can stop Copilot processing labelled emails and files (emails sent on or after
   1 Jan 2025), block prompts with SITs, and exclude external email as grounding to reduce prompt injection —
   [DLP for Copilot](https://learn.microsoft.com/purview/dlp-microsoft365-copilot-location-learn-about). That policy
   location covers Microsoft's Copilot, **not our server**. Offer equivalent switches in managed preferences:
   `ExcludeLabels`, `ExcludeExternalSenders`.
4. **Prompt injection.** Bodies are untrusted, so:
   - wrap them in delimiters and strip active HTML;
   - expose no tool that sends or forwards;
   - keep hidden text out of tool results;
   - offer an "external sender" flag per message so the client model can discount it.
5. **Draft-only writes and human confirmation.** Every agent draft is tagged (category "AI draft") and can't be sent
   from MCP.
6. **Audit.** Local append-only access log (tool, item ID, label, decision; never subjects or bodies). Optionally
   mirrored to Purview via `contentActivities` — [overview](https://learn.microsoft.com/purview/developer/microsoft-purview-sdk-documentation-overview#scenarios-and-api-overview).

### 4.3 Build vs use Microsoft's MCP

Work IQ MCP is a Microsoft-hosted MCP server over Graph paths (`fetch /me/messages`, `do_action /me/sendMail`). Its
tenant policy blocks mutations by default — [Work IQ MCP](https://learn.microsoft.com/microsoft-365/copilot/extensibility/work-iq/mcp/overview),
[tool reference](https://learn.microsoft.com/microsoft-365/copilot/extensibility/work-iq/mcp/tool-reference).
**Ours is still justified:** it works offline on the local cache and applies *our* label policy. It also works without
Copilot licensing (**UNVERIFIED** whether Work IQ requires it). Offer Work IQ as an optional upstream for "ask"-style
reasoning in tenants that have it.

---

## 5. Suite roadmap

| # | App | Core API | Hard parts | Realistic? |
|---|---|---|---|---|
| 1 | **Mail + Calendar** | Graph mail/calendar | Label write on send, deferred send, MIP SDK build, shared-mailbox discovery | Yes: the pilot plus 6–9 months to daily-driver |
| 2 | Contacts / People | Graph contacts, people, directory | Contact lists and extra contact properties are EWS-parity gaps targeted Q3 CY2026 — [roadmap](https://learn.microsoft.com/exchange/clients-and-mobile-in-exchange-online/deprecation-of-ews-exchange-online#roadmap-for-parity-gaps) | Yes, small |
| 3 | To Do / Tasks | Graph `todoTask` (flags already surface there) | Planner is a separate API; keep scope to To Do first | Yes |
| 4 | Files (OneDrive/SharePoint) | Graph drive; File Provider extension | Sync conflicts, labels on files (MIP File SDK), the OneDrive client already exists | Browse and attach: yes. Full sync client: no (don't compete) |
| 5a | Docs/Sheets/Slides **viewers** | Graph format conversion of driveItem content — [get content format](https://learn.microsoft.com/en-us/graph/api/driveitem-get-content-format) (linked from [Loop compliance](https://learn.microsoft.com/microsoft-365/loop/loop-compliance-summary?view=o365-worldwide#ediscovery)); Quick Look for local files. Use for viewers: **UNVERIFIED** | Encrypted files need the MIP SDK before preview. Fidelity is whatever the converter gives | Yes, as read-only |
| 5b | Docs/Sheets/Slides **editors** | — | See below | **No, not as a small team** |

Why editors are the wall:
- **File-format fidelity:** OOXML is huge; layout, formulas, macros and SmartArt round-trips are multi-year work. Even
  mature third-party suites aren't lossless (product knowledge, **UNVERIFIED** as a sourced claim).
- **Co-authoring isn't open.** WOPI runs the *other way*: Office for the web edits files held in a partner's
  storage, and the Cloud Storage Partner Program is "for independent software vendors whose business is cloud storage.
  It's not open to Microsoft 365 customers directly" —
  [WOPI](https://learn.microsoft.com/microsoft-365/cloud-storage-partner-program/online/). It gives us no way to
  co-author natively. Whether Office's real-time co-authoring protocol is documented for third-party *editors* wasn't
  found: **UNVERIFIED**, assume closed.
- **Loop:** `.loop` files live in OneDrive, SharePoint or SharePoint Embedded and need WebSockets to `*.svc.ms` —
  [Loop requirements](https://learn.microsoft.com/microsoft-365/loop/loop-requirements?view=o365-worldwide#at-a-glance).
  No third-party Loop *editor* API found, and none found for embedding Fluid in a third-party app (**UNVERIFIED**). Render as links (which is what Microsoft itself does when Loop is
  disabled — [Loop compliance](https://learn.microsoft.com/microsoft-365/loop/loop-compliance-summary?view=o365-worldwide#foundations)).
- **Realistic end state:** native Mail, Calendar, Contacts, Tasks and Files browser, plus viewers. For editing, open
  Office for Mac or Office for the web and hand the label policy over. "Office replacement" means *replacing Outlook
  and the glue*, not Word.

### Platform risk to track
- **EWS is going.** Phased disablement from 1 Oct 2026, full retirement 1 Apr 2027 —
  [Exchange Online service description](https://learn.microsoft.com/office365/servicedescriptions/exchange-online-service-description/exchange-online-service-description#feature-availability-including-standalone-plans).
  Design on Graph only. Gaps that won't be filled are listed in the
  [deprecation article](https://learn.microsoft.com/exchange/clients-and-mobile-in-exchange-online/deprecation-of-ews-exchange-online#roadmap-for-parity-gaps).
- Beta dependencies (label catalogue, mentions) need a feature flag and a fallback.

## Next spikes (ordered)
1. Label on send: MIME draft with `msip_labels` vs an extended property, in a test tenant. Check the recipient's header,
   content marking and encryption.
2. Deferred send: `SystemTime 0x3FEF` extended property on a draft, then `send`. Check it doesn't deliver early and
   where the copy sits.
3. MIP Policy SDK build with CLT only (no Xcode); C shim for Swift.
4. CA report-only: device-compliant Mac with our MSAL app against (a) a compliant-device grant, (b) APP-only including
   macOS.
5. Graph read of an encrypted message by a third-party app: is the body returned, or `message.rpmsg`?


> **Update 2026-11-19:** copy / print / export / forward / reply now follow the label's **Purview usage rights**
> (EXTRACT, PRINT, EXPORT, FORWARD, REPLY, REPLYALL). They are resolved from the per-item licence (MIP SDK hook, not
> yet implemented), then Graph `sensitivityLabels/{id}/rights` (needs `SensitivityLabel.Read`, not yet consented),
> then a fallback: unencrypted → all rights, encrypted with unknown rights → VIEW only. The earlier priority
> thresholds are now an optional admin overlay, off by default. AI may read encrypted content only with VIEW + EXTRACT,
> as Copilot does. Source: Compliance.swift.
