# AI in niivo mail: UX, privacy tiers, keys (2026-11-19)

Goal (Ryan): AI that is far better than Copilot's side pane. That means well thought through, intuitive and
genuinely productive. Code: `Sources/MailCore/AIAssist*.swift` (core, UI-free) and
`Sources/CompliantCalendar/AI*.swift` (views). The hook points in existing files are marked `// AI-HOOK`.
Tests: `Sources/CoreSelfTest/AIAssistTests.swift`.

## Principles

1. **No chat pane.** AI shows up where the work already is: list rows, the thread header, reply chips in the reader,
   the composer, the send key and ⌘K.
2. **One keystroke to accept.** Each suggestion has a key: digits 1–5 on reply chips, ↩ in the briefing and the
   palette, ⌘↩ to send past a pre-send note.
3. **Preview, edit, undo, cite.**
   - AI output never acts directly. A draft lands in the composer, where you edit it and send it yourself.
   - Bulk actions show a plan with a count and the matching rows before anything happens. "Undo all" reverts the
     whole plan, and each step uses the normal triage path.
   - Answers and summaries cite the messages they used as `[1]`, `[2]`. Clicking a citation jumps to that message.
4. **Never block the UI.**
   - Triage precomputes in the background for the top of the inbox.
   - Results are cached in the encrypted mail store, keyed by message id, changeKey and the gate decision.
     A label change or a policy tightening therefore invalidates the cached result.
   - Composer calls have a Cancel button. Every provider call times out after 60 s (the Claude CLI child is
     terminated). The pre-send check has a hard budget of 1.5 s. Summary, ask and triage calls aren't user-cancellable
     yet.
5. **Labels and trust policy gate everything** (see "Gate" below). AI never sends mail, never deletes, and never
   writes rules or forwarding.

## Privacy tiers

| Tier | Provider | Default use | Content allowed |
|---|---|---|---|
| On-device | Apple FoundationModels (`SystemLanguageModel.default`) | Triage, thread summaries, classification, NL→query | Labelled but not encrypted content, even at or above `aiMaxPriority`, because nothing leaves the Mac. Encrypted content still needs VIEW+EXTRACT |
| Cloud: Claude CLI | the local `claude -p`, isolated (see below) | Drafting, rewrite, answers | As in MCP: full only below `aiMaxPriority` and with EXTRACT |
| Cloud: OpenAI-compatible | OpenAI, Azure OpenAI, local Ollama / LM Studio | Same as Claude CLI | Same as Claude CLI. Azure OpenAI in **Switzerland North** keeps inference in CH, which is the niivo customer recommendation |

**FoundationModels on this Mac** (checked 2026-11-19, macOS 27.0.1, CLT Swift 6.4):
- `import FoundationModels` compiles and links under CLT.
- `SystemLanguageModel.default.availability` = `unavailable(modelNotReady)`, so the model isn't downloaded or Apple
  Intelligence isn't enabled.
- `OnDeviceProvider` is built and reports the reason. When it is unavailable, routing falls back to the configured
  cloud provider, and then to rule-based triage (`SplitInbox`).
- A generation smoke run was impossible on this machine: UNVERIFIED.

**Routing.**
- Light features (triage, summary, intents, NL search, bulk plan) prefer on-device. Heavy ones (draft, rewrite,
  ask) prefer the cloud provider.
- When the preferred tier is unavailable or forbidden by policy, routing uses the other tier.
- If neither is available, the feature is unavailable. Rule-based fallbacks still work: plain search, `SplitInbox`
  triage, and the rule-based pre-send checks.

## Gate (`AIGatePolicy` + `AIPromptBuilder`)

Each message is classified per call and per tier:

| Item | Cloud | On-device |
|---|---|---|
| Organisation access `off` (TrustPolicy) | no call at all | no call at all |
| Mail marked private | excluded | excluded |
| Label unknown to the published policy | excluded | excluded |
| Encrypted without VIEW+EXTRACT (`ContentPolicy.aiMayReadContent`) | metadata, subject → "Protected message" | same |
| Label priority ≥ `aiMaxPriority` | metadata | **content** |
| TrustPolicy `aiAccess` / `onDeviceAIAccess` = `metadataOnly` (BYOD default for cloud) | metadata | metadata |
| Otherwise | content | content |

- **Metadata** is the sender, date, subject (wrapped), flags and label name. It never includes the body, preview,
  recipients or attachment names.
- **Excluded** items appear only as a visible note, "1 message not shared with AI (Highly Confidential)". Their
  ids never enter the prompt.
- **Trust policy.**
  - `aiAccess` covers the cloud tier.
  - `onDeviceAIAccess` (new, optional) covers on-device. When it is nil it follows `aiAccess`. `aiAccess` = `off`
    is the master switch and forces both off.
  - The BYOD default leaves `onDeviceAIAccess` nil, so on-device follows `aiAccess` (= `metadataOnly` on BYOD).
    Relaxing on-device to `followLabels` on BYOD is proposed and **waits for Ryan's sign-off**.
  - `allowedAIProviders` (new, optional, `on-device` / `claude-cli` / `openai-compatible`) restricts providers.
    When nil, any provider is allowed.
  - All three merge stricter-wins. Posture `restrict` clamps both levels to `metadataOnly`.
- **Your own draft text** is mail content too. Rewrite and pre-send use the draft's label (including the inherited
  floor) and the original's exposure.
- **Prompt construction.**
  - Mail goes into the prompt as untrusted data, between `<<MAIL n nonce=…>>` and `<<END-MAIL nonce=…>>` markers.
    The nonce is random per call, and marker look-alikes in mail text are neutralised.
  - The text passes the same pipeline as OfficeMCP: sanitise, strip hidden text, de-fang links, strip invisible
    characters.
  - Quoted history and signatures are stripped. Each item is capped at 4,000 characters and the prompt at 24,000.
- **Output** is rendered as plain text only: no HTML and no links.
- **Natural-language search and bulk plans** send only the user's own words (and today's date) to the provider.
  Retrieval and filtering run locally over the blind index.

## Features

| # | Feature | Where | Status |
|---|---|---|---|
| 1 | **Needs you triage**: a one-line "what this wants from you" replaces the preview, plus a tag (Reply needed / Waiting on them / FYI / Bulk) | Inbox rows; **Briefing** sheet (⌃⌘B) grouping today's mail by tag, with one-key group actions | Built |
| 2 | **Reply intents**: chips "Yes / confirm", "Decline", "Propose a time", "Ask for more info", "Delegate to…"; 1–5 → draft in the composer | Reader | Built |
| 2a | **Propose a time**: 2–3 real free slots from your own calendars (`FreeTime.gaps`, working hours, next 5 working days) written into the draft | Reader chip 3 | Built. Tentative holds are shown as a planned action; creating them on send is LATER |
| 3 | **Pre-send check** at ⌘↩: attachment mentioned but nothing attached, unanswered questions, a commitment ("add to follow-ups?"), a tone flag, external recipients on labelled mail (rule-based). ⌘↩ again sends anyway | Composer | Built (rule-based checks are instant; the AI part is limited to 1.5 s) |
| 4 | **Commitments and follow-ups** smart list; "waiting on" nudge after N days | List | Designed below, LATER |
| 5 | **Thread state header**: TL;DR, decisions, open questions, who owes what; collapsible; cites messages | Reader top (⌘⇧S) | Built (on demand, refreshes when the thread grows) |
| 6 | **Ask / act bar** in ⌘K: answers with citations from local retrieval, bulk actions with plan preview + confirm + undo, NL search | Palette | Built |
| 7 | **Composer**: AI draft (tone, length, language, instruction), rewrite selection or the whole body (polish, shorten, formal, translate DE/FR/IT/EN) with a side-by-side preview before replacing | Composer | Built. Voice profile and ghost text are LATER |
| 8 | **Meeting prep** "Brief me" in the event inspector | Calendar | LATER (design below) |

### Interactions

- **Inbox rows.** The AI line appears in place of the preview once it's computed, with a small tag capsule.
  Labels that may not be shared show no line.
- **Briefing (⌃⌘B).** Groups are Reply needed → Waiting on them → FYI → Bulk.
  - ↑/↓ moves between groups. ↩ opens the next reply-needed message. `E` archives the whole FYI or Bulk group,
    after a plan preview, and Z undoes it.
- **Reader.** A row of reply chips. With the list focused, digits 1–5 pick a chip. ⌘⇧R opens the AI draft popover
  in the composer.
- **Thread header.** ⌘⇧S toggles it. Each line carries `[n]` citations, and clicking one selects that message.
- **Composer.**
  - The ✨ menu has AI draft…, Rewrite (polish / shorten / formal / friendly / translate) and an instruction field.
  - Results show in a preview pane (before | after) with Replace and Discard. The previous body is kept, so
    "Undo AI change" restores it.
  - A progress spinner and Cancel are always visible while a call runs.
- **⌘K.** Typing anything adds "Ask AI: …", "Search: …" and "Do: …" (bulk plan) to the top of the list.
  - Answers open in a small sheet with citations.
  - A bulk plan shows its action, the number of matching messages and the first 10 matches, with Confirm and
    Cancel.

### Keys (checked against the existing map; no clashes)

| Key | Action |
|---|---|
| ⌘⇧R | AI reply (draft popover in the composer for the selected message) |
| ⌘⇧S | Thread summary / state header toggle |
| ⌃⌘B | Briefing |
| 1–5 (list focused, message open) | Reply intent chips |
| ⌥↩ in the search field / "Ask" toggle | Natural-language search |
| ⌘K, then type | Ask / Search / Do entries |
| ⌘↩ (composer) | Send. When AI is on, the first press runs the pre-send check; if notes are shown, a second ⌘↩ sends |

The existing keys stay unchanged:
- bare keys: J K E # R A F C S U H L / Z ? ⇧I ⇧T
- ⌘K, ⌘/, ⌘, and ⌘R
- ⌃⌘1/2 and ⌃⌘L

## Agent: tools + context pack (round 3)

The assistant searches the mailbox itself instead of being handed a few messages, and every request carries a small
context pack. Design decision, from Ryan: stuffing selected messages into the prompt was rejected.

**One tool layer.** The `OfficeTools` library (new SwiftPM target) holds the tool definitions, the `AIGate`, the
untrusted-text rendering, the audit and the MCP server. OfficeMCP is now a thin executable over it, and the app uses
the same code in-process. There is ONE sanitising pipeline, `MailCore.AIUntrustedText`; OfficeTools' `Untrusted` is a
JSON wrapper that delegates to it. MCP keeps quoted history, while the prompt builder strips it.

**Agent tools.** The agent always gets a read-only server: no drafts and no triage (`MCPServer.agent`).
- `mail_search`: query plus filters `from`, `to`, `after`, `before`, `folder`, `has_attachments`, `is_unread`, `label`.
  - Filter-only calls are allowed.
  - Gating happens before the limit, so restricted rows don't eat result slots.
  - `to` only matches recipients the gate would show.
- `mail_get_message`, `mail_get_thread`, `mail_list_folders`.
- `people_history(address)`: built from cached headers (no bodies).
  - Counts by month in both directions, first and last contact, internal or external, and median reply time.
  - Threads awaiting you or them (last 30 days) and the last N exchanges.
  - Received mail comes from the blind index; sent mail comes from Sent, which is opened on demand.
- `project_context(project|keyword|category|folder|conversation_id)`: related threads, top participants, last activity.
- `company_context(company)`: people, threads, last activity, open items and projects for one company (registrable
  domain; free-mail is never a company).
- `search(query)`: ranked local search (BM25 + on-device semantic match, fused, plus recency) with facets; operators
  `from: to: company: project: label: folder: has:attachment is:unread before: after:`. All four graph-backed tools
  recompute their output from gated messages; the communication graph only proposes candidates (see MCP.md).
- `calendar_list_events`, `calendar_free_busy`, `calendar_find_free_slots`.

**Gate.**
- Every result goes through `AIGate` (`excluded`, `metadata` or `content`), with `{untrusted_content, note}` wrapping.
- Hidden items are only counted (`restricted_not_shown`).
- The gate is built per request from the current `TrustPolicy` and the routed tier:
  - Cloud uses `aiAccess` and the priority ceiling.
  - On-device uses `effectiveOnDeviceAIAccess` and no priority ceiling (the same rules as `AIGatePolicy`).

**Writes.** None. The agent can only describe a *proposed action*. The UI keeps doing writes behind confirmation: the
draft preview and the bulk plan sheet.

**Loop (`AIAgent.run`).**
- At most 6 tool rounds. The final round offers no tools ("answer now").
- 90 s overall deadline, which also bounds each step.
- Cancellation propagates.
- At most 8 calls per step; extra calls are dropped from the transcript so every id gets an answer.
- Byte budgets: 12 KB per call (truncated) and 60 KB per turn (then the tool returns an error).
- Unknown tools and non-object arguments come back to the model as tool errors. They are audited as
  `tool:rejected`, so the model-supplied name never reaches the log.
- Every tool call is audited content-free (`tool:<name>`, ids count, bytes, restricted, outcome, ms).
- Progress text: "Searching mail from zoe@…", "Looking up history with …", "Finding free time…".
- Citations are `[[msg:<id>]]`. Only ids that a tool actually returned are kept, numbered `[n]` and clickable.
- Usage line: `used: 3 searches, 7 messages (2 not shared: label)`.

**Per provider.**
| Provider | How tools run |
|---|---|
| OpenAI / Azure / local | Native `tools` + `tool_calls`; tools run in-process (`OfficeToolExecutor`). |
| Claude CLI | `claude -p` gets ONLY our server via `--mcp-config` + `--strict-mcp-config`. The server is `OfficeMCP --relay <socket> --relay-token <t>`, which pipes to a socket the app hosts. `--allowedTools` is the explicit list `mcp__office__<name>` of the read-only tools (no wildcard). `--output-format stream-json --verbose`. |
| On-device | FoundationModels `Tool` is not wired. The model isn't ready on this Mac, so it can't be tested. Single shot: one `mail_search` with the task text, then the results are given as data. |

**Claude CLI ↔ the app's live session (the design).**
- OfficeMCP in normal mode must never open the app's store, because `syncNow()` flushes the outbox. Its own Graph
  mode would also need a token on disk and a second sync.
- So the app serves the tools itself:
  - `MCPSocketHost` binds a unix socket at `/tmp/niivo-XXXXXXXX/s` (directory 0700, socket 0600, path under 104 bytes).
  - It accepts ONE connection and requires a per-run 128-bit token as the first line.
  - It serves JSON-RPC from an in-process `MCPServer` over the app's live `MailSync`/`MailStore`, the same objects
    the UI uses.
  - The tools never call `syncNow()`. They may call `openFolder` (a folder sync, no outbox) and `fetchBody`.
- The OfficeMCP binary that claude spawns is only a relay. It has no mailbox access, token or store of its own.
- The app sees every call. Ids, the restricted count, audit, progress and the call budget (12 calls) come from one
  place, and calls past the budget are refused.
- The live run offered no tools to the model. Inferred cause, from the help text: `--safe-mode` disables MCP
  servers. Not re-verified live, so agent mode drops it. Isolation instead: empty
  temp cwd, `--setting-sources ""`, strict MCP, no slash commands, our own system prompt.
- The `system/init` event's server status is checked. If `office` isn't `connected`, the run fails instead of
  answering without tools.

**Context pack (`AIContextPack`, ≤ 2,048 bytes of compact JSON, attached to every agent request).** It contains:
- me and mailboxes
- now: local ISO time, weekday, tz, working hours 08:30–17:00, `next_meeting_in_min`
- today's own events
- the open message: id, conversation, from, subject, preview, categories
- a `people_history` digest of its sender
- the folder
- the composer draft

Gating and trimming:
- The open message and draft follow `AIGatePolicy` for the tier.
- Agenda subjects follow the event label (metadata → `busy`, excluded → only counted). Legacy private, personal or
  confidential items show as `busy`.
- Untrusted strings are wrapped and neutralised.
- To fit the size limit it drops, in order: the draft, then people, then agenda items, then the preview.

**Rewired.** Applies only when a real tool loop exists (`agentCapable`): an OpenAI-style provider, or Claude with
the relay binary AND `defaults write <bundle> ai.claudeAgent -bool YES`. That flag is off until a live run checks
isolation without `--safe-mode`. Otherwise the richer single-shot paths stay.
- **Ask** (palette ⌘K / search ⇧⌘A): full agent loop with live progress.
- **Draft reply**, including all intents and **Propose a time** (the agent is told to use `calendar_find_free_slots`;
  locally computed slots are given as a hint): the agent loop, when the original is `content` for the routed tier.
  Otherwise the old single-shot path, which refuses.

Not rewired yet (honest):
- The thread header summary (structured JSON output) and **Do** (bulk plan) stay single shot. Triage stays batch
  single shot (by design).

## Claude CLI isolation (flags checked against `claude --help`, v2.1.328)

```
claude -p --output-format json --model <m> --system-prompt <static feature prompt>
       --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources ""
       --safe-mode --no-session-persistence --disable-slash-commands --permission-prompts none
```

- The working directory is a fresh empty temp directory, and the prompt goes on **stdin**. The argv carries only
  static text, because argv is visible in `ps`.
- The environment is an allowlist (HOME, USER, PATH, LANG, TMPDIR, ANTHROPIC_* auth variables). The parent's
  CLAUDE_CODE_* session variables are dropped.
- `--bare` is not used. It never reads OAuth or the keychain, so subscription logins would break.
- The binary is looked up in PATH, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.claude/local`.

## LATER (designed, not built)

- **Commitments / follow-ups (4).**
  - Extract "I'll…/we will…" promises from Sent and asks of the user from the Inbox, as `{who, what, due,
    messageId}`, cached like triage.
  - A "Follow-ups" smart list with Waiting on me, Waiting on them and Overdue.
  - When a waiting-on item gets no reply after N days (default 3), a nudge chip drafts a polite follow-up.
- **Voice profile (7).**
  - Derived from your last ~50 sent mails: style notes such as greeting, sign-off, length, formality per language.
    The mails themselves are not stored.
  - The notes are sealed in the mail store, with a settings view to read and delete them.
  - Gated like any other content (cloud vs on-device).
- **Ghost-text inline completion (7).** Needs on-device latency, so it waits for FoundationModels to be available.
- **Meeting prep (8).**
  - "Brief me" in the event inspector and alert banner: recent threads with the attendees (local search by
    address), open items and last decisions.
  - Event content is gated by `EventAIAccess` rules (as in OfficeMCP) and mail by the gate above.
- **Tentative holds on send** for Propose a time.
  - Create tentative events through the calendar write path when the draft is sent, and remove them when a slot is
    accepted.
  - Today the holds are shown as a planned action only.

## UNVERIFIED

- **Agent, live (round 3).** The one allowed `claude -p` agent run (`CC_AI_LIVE=agent`, fixtures through the relay)
  ran with `--safe-mode`. MCP was disabled, so claude made no tool call and printed a pseudo tool call as its answer.
  - The test failed as it should.
  - The fix is in: no `--safe-mode` in agent mode, plus the init-status check.
  - It has **not** been re-run live. All deterministic checks pass, including the relay driven by the real OfficeMCP binary.
- The bundle step must copy `OfficeMCP` into `Contents/MacOS` (`scripts/bundle.sh`, not touched here). Until then
  `ClaudeMCPServer.locateOfficeMCP` finds it only in a dev checkout (`.build/{release,debug}`), and the Claude agent
  falls back to single shot.
- The in-process agent on a live Graph session is untested. `mail_search` can upsert server-only hits into the
  on-disk cache (they are persisted under the same persist policy as sync), and `openFolder` may sync Sent on first
  use.
- On-device agent: FoundationModels `Tool` is not wired (the model is not ready on this Mac), so it runs single shot
  with one pre-search.
