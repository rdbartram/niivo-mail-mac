# Inbox intelligence: conversation state, Stories and a local knowledge layer (plan)

Status: approved 2026-11-20. **Phases 0, 1 and 2 built** (2026-11-20, self-tested on fixtures, not yet run on the
owner's mailbox; see "Build status" at the end). Scope:

1. The triage tags (Reply needed / Waiting / FYI / Bulk).
2. Stories (related mail across conversations).
3. A local "Work IQ"-style knowledge layer that answers questions such as *"show me mails from my lawyer"* and
   *"show me details of that project I did back in Feb for that architect"*.

It replaces the per-message triage cache and the union-find story linker. The privacy model is unchanged: label
gate, tiers, sealed storage and content-free logs all stay.

---

## 0. TL;DR

- **Triage moves from messages to conversations.**
  - Each conversation has one state: needs reply / waiting / FYI / done, with snoozed as an overlay.
  - A deterministic state machine drives it from facts the app already has: who sent the last message, did I reply,
    To or Cc, bulk, invites, flags, snooze.
  - The LLM only decides the cases the rules can't, and writes the "ask" line.
- **Every inbox conversation always has a state.** Rules run on every sync, so the AI is never on the critical path.
  Today's missed, stale and lost-after-sync tags all come from AI-only tagging.
- **A Story is a named matter**: a project, case, deal or ticket. It isn't a similarity cluster.
  - A conversation joins a story only through an explicit **anchor**: a shared reference number, a project name, a
    non-generic attachment, a subject stem, or a user action.
  - Similarity and shared people only *propose* candidates.
  - Clustering is **assignment** with no bridging, so a conversation can't chain two stories together. Story ids
    persist, so rename, merge and split survive a rebuild.
- **The knowledge layer is entities plus facts with provenance.**
  - Entities: people, organisations, roles inferred from evidence (lawyer, architect, Treuhänder, …) and matters
    (= Stories). Every fact cites its messages, carries a confidence and passes the label gate per tier and per
    account.
  - Queries resolve entities first ("my lawyer" → person; "that architect" + "Feb" → matter), then hand off to the
    existing ranked search. The answer is a cited project card.
- **One-click corrections feed local learning.** Corrections build per-sender priors, a small on-device scorer, story
  must-link / cannot-link constraints and user-asserted facts. All of it is sealed and per account.
- **An eval harness gates changes.** It's a synthetic DE/EN/FR/IT corpus with gold triage, gold stories, gold roles
  and gold queries, plus an owner mode that reports aggregates only.
- **Order:**
  - Phase 1 fixes tagging: state machine, rules, never untagged.
  - **Phase 2 makes the two example queries work**: roles, time parsing, person and matter cards, built on CommGraph
    and an interim query-time matter grouping.
  - Later phases add the scorer, Stories v3, controls and learning.

---

## 1. How it works today, and why it feels wrong

### 1.1 Triage (tags)

| Piece | Where | What it does |
|---|---|---|
| `AITriageTag` (`replyNeeded`, `waitingOnThem`, `fyi`, `bulk`), `AITriage` (tag, ask, why, context) | `MailCore/AIAssistModels.swift` | Result type, **per message** |
| `TriageContext.lines` | same | Content-free facts for the model: To/Cc, internal/external, thread length, "user replied after this one", who sent the last message |
| `AIAssistant.triage` / `parseTriage` / `ruleTriage` | `MailCore/AIAssistFeatures.swift` | Batches of 10, 1,200 chars per item, LLM returns a JSON array. The rule fallback gives only `bulk` or `fyi` |
| `AIGatePolicy.exposure`, `AIPromptBuilder.add` | `MailCore/AIAssistGate.swift` | Per message: content / metadata / excluded for the tier. The body is `m.body ?? m.preview` |
| `scheduleTriage`, `retriage`, `triage(for:)` | `CompliantCalendar/AIAssistModel.swift` | Inbox only, the **top 30 visible rows**. Triggered by `onChange(visibleRows.prefix(30).map(\.id))` (`AIViews.swift`). Cache key `AICacheKey.triage(id, changeKey, label, exposure, tier)` |
| `SplitInbox.bucket` | `MailCore/MailPolicy.swift` | Local-part heuristics (`noreply`, `newsletter`, …). `notificationDomains` are `.example` placeholders |

**Proven weaknesses, read from the code:**

1. **Tags get lost after a sync.**
   - The cache key contains `changeKey`. Graph changes `changeKey` on any property change (read, flag), and
     `MailSync` copies the server's value in (`MailSync.swift:537`).
   - The key changes and the cached tag is orphaned.
   - Nothing re-triggers it, because scheduling fires only when the **id list** of the top 30 changes.
   - The code proves the mechanism. That it explains "the latest mails weren't tagged" is a hypothesis (H0 below):
     new arrivals do change the id list.
2. **A failed batch is skipped silently.** `catch { failed += chunk.count; continue }` has no rule fallback and no
   retry. Those rows stay untagged until the id list changes.
3. **Partial output leaves holes.** The rule fallback runs only if `out.isEmpty`. If 7 of 10 come back, 3 stay
   untagged.
4. **Tags go stale.** The key ignores thread state. After you reply, the representative inbox message (`threadPage`
   → `t.latest`) is unchanged, so "Reply needed" stays cached for good.
5. **Coverage is narrow.** The inbox's top 30 rows only. Nothing below, nothing in other folders or mailboxes.
6. **Rules can't express action.** `ruleTriage` never returns reply or waiting. With AI off, unavailable or blocked by
   the label gate, every person-to-person mail is "FYI".
7. **Per message, not per conversation.** The model sees the newest inbound message plus a few context lines, not
   the thread.
8. **Bulk detection is thin.** No List-Unsubscribe / Precedence / Auto-Submitted, no `sender ≠ from`.
9. **No learning.** Corrections can't be recorded. The only control is "Re-triage".
10. **Duplicate logic.** "Awaiting me / awaiting them" already exists in `OfficeTools/GraphTools.swift:113`
    (`company_context`) and `PeopleTools.swift:112` (`people_history`, via CommGraph history), as "newest message in
    the thread is from me or not". It's a third, simpler notion of the same state. Phase 1 replaces both with reads
    of `conv_state`, so the MCP tools, Briefing and list agree.
11. **Opaque failures.** `OnDeviceProvider` turns every error into `failed("on-device generation")`.

**Hypotheses to verify (content-free counters, Phase 0):**

- **H0, orphaning.** Visible rows whose tag vanished after a read or flag sync. Counter: rows with an in-memory tag
  under an older key but none under the current key.

- **H1, on-device context overflow.**
  - The on-device context is 4,096 tokens, input and output combined ([Apple forum](https://developer.apple.com/forums/thread/806542)).
  - A 10-item batch adds a ~250-token system prompt and up to 1,200 chars of body per item (when bodies are cached),
    plus `maxTokens = 90 × n + 50`. That can overflow and fail the whole batch (see 2).
  - Previews-only batches probably fit.
- **H2, guardrail refusals** on some business content.
- **H3, routing.** The owner runs the cloud tier with `onDeviceForLightTasks`, so triage is on-device.

### 1.2 Stories

`MailCore/StoryEngine.swift` (v2), `CompliantCalendar/StoryViews.swift`, `OfficeTools/StoryTools.swift`
(`story_context`), tests in `CoreSelfTest/StoryTests.swift`.

- **Per-message features.**
  - Participants (HMAC), an anchor (= the counterpart), orgs, conversation and timestamp.
  - When the gate allows content, ≤ 40 tokens: subject terms, subject stem, ≤ 16 preview terms, NLTagger entities and
    dates, attachment names.
  - Sealed in a fixed 640-byte record in `story_feat`.
- **Linking.**
  - Candidates come from postings plus `SemanticIndex` neighbours within ±14 days.
  - The score fuses IDF-weighted token overlap, participant overlap, a same-counterpart burst, semantic cosine and
    time decay. ≤ 4 edges per message.
- **Clustering.**
  - Union-find over conv / content / meta edges.
  - Caps: `storyCap` 60, `maxSpan` 21 days, a size-scaled merge threshold (0.38 → 0.74), `metaOnlyCap` 30.
  - Meta edges never bridge two content stories.
  - Per-counterpart boilerplate suppression.
- **Titles.** On-device FoundationModels, otherwise the fallback `StoryTitles.fallback`.

**Evidence from the owner's mailbox (~1,000 rows, content-free):**

| Measure | Value | Reading |
|---|---|---|
| Rows in stories (before the boilerplate fix) | 86 % | A "story" meant "anything with a neighbour" |
| Stories spanning ≥ 20 conversations | 3 | Single-link chaining |
| Cross-conversation edges: content / meta | 1,374 / 23 | Text overlap drives almost everything |
| …sharing people / with the same anchor | 1,161 / 1,079 | ≈ 79 % are the **same counterpart**: "mail from Anna" was read as "the same topic" |
| Matched tokens | Mostly high-df body and subject terms | Everyday words and signatures, not topic identifiers |

**Structural problems (not tuning):**

1. **The wrong unit.** Messages, not conversations. Each message re-matches the counterpart's vocabulary, so the
   evidence inflates.
2. **Similarity is treated as identity.** Nothing requires a reason a person would accept ("same PO", "same
   project").
3. **Single-link chaining.** A → B → C merges A and C with no evidence between them. The caps only limit the damage.
4. **No persistent identity.** The id is "s" + the lowest rid. It changes with window ageing, `reset()` and version
   bumps.
5. **No user controls, no feedback.**
6. **Per-language `NLEmbedding` spaces.** DE and FR mail share no vector space. Search found vectors neutral to
   negative (SEARCH-QUALITY.md).

### 1.3 Search and context today (the knowledge layer builds on these)

- **`SearchEngine` natural mode** (`SearchUnderstanding.swift`, `NaturalQuery`):
  - Lexicon expansion and sender hints ("from X", "von X").
  - Relative time: yesterday, last/this week, last/this month, recently.
  - No month names ("Feb"), seasons, years, roles or projects.
  - RRF fusion with recency.
- **CommGraph** (`CommGraph.swift`):
  - Sealed person, org, project and conversation nodes. `PersonNode.fromThem/toThem` tallies, company, `isInternal`,
    neighbours.
  - Projects are categories, folders and subject terms (`ProjectNode`).
  - It's **not a gate**. Tools recompute visible numbers from gated messages.
- **MCP tools** `people_history`, `project_context`, `company_context`, `search` (`OfficeTools`). They're the
  read-side shape a knowledge answer should reuse.
- **Directory**: `GraphPeopleService` already has `jobTitle`, `department` and `companyName` for org people.

---

## 2. State of the art

### 2.1 Mail products

| Product | What it does | Lesson for us |
|---|---|---|
| **Gmail Priority Inbox** | A per-user model of P(user acts). Hundreds of features in **social** (interaction with the sender), **content**, **thread** (did the user start it or reply) and **label** groups. Global plus per-user model, ID3-style binning ([Aberdeen, Pacovsky & Slater 2010](https://research.google.com/pubs/archive/36955.pdf)) | Social and thread features carry the signal. Logistic models on cheap features work. Personalise with a prior |
| **Gmail Nudges** | "Received 3 days ago. Reply?" / "Sent 5 days ago. Follow up?", only for mail you'd normally answer ([9to5Google](https://9to5google.com/2018/05/14/new-gmail-web-nudge-ai-reminders/), [Mailmeteor](https://mailmeteor.com/blog/gmail-nudges)) | "Waiting" is time-based state on *sent* mail. Nudge only high-confidence threads |
| **Superhuman Auto Labels** | Respond / Waiting / FYI / Notifications / Promotions / News. Respond, Waiting and FYI are never auto-archived. Custom labels from rules or AI prompts feed Split Inbox ([help](https://help.superhuman.com/hc/en-us/articles/46005854346893-Email-Assistant-by-Superhuman-Mail-Gmail), [Custom Split Inbox](https://help.superhuman.com/hc/en-us/articles/38458483333907-Custom-Split-Inbox)) | Our tag set matches the market. Keep action states separate from channel |
| **Shortwave** | AI bundles (newsletters, travel, notifications). Drag mail into a bundle; feedback teaches it. Plain-English AI filters (reviews: [Zapier](https://zapier.com/blog/shortwave-vs-superhuman/), [clean.email](https://clean.email/blog/email-clients/shortwave-review)) | Grouping works when users can correct it with a gesture |
| **HEY** | The Screener approves a new sender once and routes them to Imbox / Feed / Paper Trail. Human rules, no AI ([how it works](https://www.hey.com/how-it-works/), [Screener](https://help.hey.com/article/722-the-screener)) | Sender-level decisions beat per-message guessing for channels |
| **Outlook Focused Inbox** | Learns from moves. "Always move to Focused/Other" is a sender override ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/5756853/emails-going-into-other-tab)) | Sender-level overrides again |
| **Outlook Copilot "Prioritize my inbox"** | High / normal / low from people on the thread, job titles and content, with a short reason. User instructions such as "It's from my manager". Only new mail ([Microsoft Support](https://support.microsoft.com/en-us/outlook/copilot-outlook/prioritize-my-inbox)) | Always explain why. Let users state rules in words. Never block delivery |
| **Apple Mail categories** | Primary / Transactions / Updates / Promotions. Time-sensitive mail also shows in Primary. No custom categories ([AppleInsider](https://appleinsider.com/articles/25/03/31/macos-sequoia-154-arrives-with-apple-mail-categories-password-timers-and-more), [Computerworld](https://www.computerworld.com/article/3951741/how-to-use-apples-mail-categorization-ai-in-macos-15-4.html)) | Channel classification can run on device. Urgency overrides channel |
| **Spark** | Smart Inbox (People / Notifications / Newsletters). Moving a sender reclassifies their future mail. Gatekeeper screens new senders ([help](https://sparkmailapp.com/help/manage-your-inbox/customize-your-inbox), [9to5Mac](https://9to5mac.com/2022/10/04/spark-mail-app-major-update/)) | Sender-level learning |

None of these ships automatic cross-conversation "stories" based on similarity. Bundles and activities are either
typed or user-seeded, which supports anchors plus user seeds.

### 2.2 Microsoft Work IQ (the reference for the knowledge layer)

- **What Microsoft says it is.**
  - Announced at Ignite 2025 as "the intelligence layer behind Microsoft 365 Copilot and agents", which "helps
    Copilot understand you, your job, and your company".
  - It combines the **work graph** (documents, emails, meetings, chats), the **user's preferences and working
    style**, and **inference** of context ([Copilot blog, 2025-11-18](https://www.microsoft.com/en-us/copilot/blog/2025/11/18/microsoft-ignite-2025-copilot-and-agents-built-to-power-the-frontier-firm/),
    [Ignite 2025 Book of News](https://news.microsoft.com/ignite-2025-book-of-news/)).
- **Three layers per Learn** ([Work IQ in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/agents-experience/add-work-iq)):
  - **Data**: signals from files, email, meetings, chats and business apps.
  - **Memory**: a persistent understanding of how people and teams work, kept consistent across sessions.
  - **Inference**: models, skills and tools that act through **Work IQ MCP** tools, governed by Agent 365.
- **Related Learn pages** (found second-hand, not fetched or verified): [Work IQ MCP / Agent 365 tooling servers](https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview),
  [Copilot personalization and memory](https://learn.microsoft.com/en-us/copilot/microsoft-365/copilot-personalization-memory),
  [Semantic indexing for Microsoft 365 Copilot](https://learn.microsoft.com/en-us/microsoftsearch/semantic-index-for-copilot).
- **How Microsoft uses it internally:** [Inside Track](https://www.microsoft.com/insidetrack/blog/intelligence-on-tap-how-work-iq-enables-ai-and-agents-at-microsoft/).
- **What it is *not*, for us.** It's a cloud, tenant-wide service. It's licensed per Copilot seat or billed by usage.
  Reportedly, memory is exposed to agents via Work IQ MCP behind a tenant admin policy that's on by default
  (secondary reporting, [WindowsForum](https://windowsforum.com/news/microsoft-work-iq-mcp-to-let-ai-agents-read-copilot-memory-admin-policy-and-privacy-controls.451137/)).
- **Our local equivalent maps 1:1:**

| Work IQ layer | Our layer |
|---|---|
| Data | `MailStore` + Sent + calendar (gated) |
| Memory | Sealed entities, facts, preferences and corrections, per account |
| Inference | Rules + on-device LLM, cloud only through the gate |
| Work IQ MCP | Our existing MCP tools (`people_history`, `project_context`, plus the new `entity_lookup` / `matter_card`) |

  The difference is the point: **on the Mac, per account, label-gated, with provenance on every fact**.

### 2.3 Research

- **Email speech acts.**
  - Classify by sender intent (request, propose, deliver, commit) from n-grams, POS and date/time features
    ([Cohen, Carvalho & Mitchell, EMNLP 2004](https://aclanthology.org/W04-3240/)).
  - Thread sequence helps ([Carvalho & Cohen, SIGIR 2005](https://dl.acm.org/doi/10.1145/1076034.1076094)).
  - → Classify with the thread as context.
- **Requests and commitments.**
  - Precise definitions: a request expects the recipient to act, a commitment promises future action. Hard cases
    include meeting announcements (= requests), conditional requests and third-party commitments
    ([Lampert, Dale & Paris, AAAI-WS 2008](https://cdn.aaai.org/Workshops/2008/WS-08-04/WS08-04-008.pdf);
    [ALTA 2008](https://web.science.mq.edu.au/~rdale/publications/papers/2008/alta.pdf)).
  - Zoning messages (ignoring quotes and signatures) improves request detection (same authors, NAACL 2010).
- **Reply prediction.**
  - Logistic regression on questions and dates/times ([Dredze, Blitzer & Pereira, CEAS 2005](https://www.researchgate.net/publication/221650852_Reply_Expectation_Prediction_for_Email_Management)).
  - Relational features (sent/received per contact, address book, supervisor) help ([Dredze, Brooks & Carroll, IUI 2008](https://www.cs.jhu.edu/~mdredze/publications/dredze_intelligent_email_iui08.pdf)).
  - Enterprise reply likelihood and latency modelled from content, metadata, historical interaction and temporal
    features ([Yang, Dumais, Bennett & Awadallah, SIGIR 2017](https://www.microsoft.com/en-us/research/publication/characterizing-predicting-enterprise-email-reply-behavior/)).
  - Deferral is a distinct behaviour ([Sarrafzadeh et al., WSDM 2019](https://arxiv.org/pdf/1901.04375)).
- **Smart Reply's triggering model.** A cheap feed-forward filter decides *whether* to run the expensive model:
  AUC 0.854, triggers on ~11 % of mail ([Kannan et al., KDD 2016](https://research.google.com/pubs/archive/45189.pdf)).
  → Run a cascade.
- **Commitments in production.** Cortana "Commitments" (with MSR, 2017) found "I'll send you the report by Friday"
  in *sent* mail and scanned locally ([GeekWire](https://www.geekwire.com/2017/microsofts-cortana-will-now-keep-accountable-promises-forgot-made/),
  [VentureBeat](https://venturebeat.com/ai/microsofts-cortana-can-now-remind-you-to-keep-your-emailed-promises)).
- **Activities, not similarity.** Assigning mail to user activities by combining similarity, people and thread
  information, framed as **recommendation** ([Dredze et al., IUI 2006](https://www.cs.jhu.edu/~mdredze/publications/iui06-dredze.pdf)).
  → Stories = activities.
- **Topic detection and tracking.** Single-link clustering needs background correction and **time decay**
  ([Allan et al., TDT pilot 1998](https://ciir.cs.umass.edu/pubfiles/ir-137.pdf)). Time decay was the strongest
  feature after content in event threading (Nallapati et al., CIKM 2004).
- **Evaluation.** Only **BCubed** satisfies all four formal clustering constraints ([Amigó et al., Inf. Retr. 2009](https://link.springer.com/article/10.1007/s10791-009-9106-z)).
  ARI is a secondary metric (Hubert & Arabie 1985).

- **Not separately researched for this plan:**
  - Gmail category tabs, beyond the Priority Inbox paper.
  - Thread reconstruction: Graph's `conversationId` is taken as given. Dredze 2006 uses in-reply-to threading only
    as a baseline.
  - Entity linking literature: role inference here is a rule-plus-evidence design, validated on the bench, not a
    published method.
  - Embedding clustering with time decay: covered only via TDT time decay (Allan 1998, Nallapati 2004) and our own
    SEARCH-QUALITY measurements.

### 2.4 Platform facts that constrain the design

- **FoundationModels (on-device).**
  - The context is 4,096 tokens, input plus output. Overflow throws `exceededContextWindowSize`.
  - `contextSize` and `tokenCount(for:)` (back-deployed to 26.x) allow runtime budgeting ([forum](https://developer.apple.com/forums/thread/806542),
    [InfoQ](https://infoq.com/news/2026/03/apple-foundation-models-context)).
  - `@Generable` gives constrained, typed output.
  - macOS 27 / WWDC26 adds new base models, a `LanguageModel` protocol (any local or server model behind a session)
    and an Evaluations framework ([WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)).
    Model names and sizes are *as reported* by third parties ([dev.to](https://dev.to/hariharanjagan/whats-new-in-apples-foundation-models-framework-at-wwdc-2026-5227)).
  - Rule: never hard-code 4,096.
- **NaturalLanguage.**
  - `NLEmbedding` is per language. `NLContextualEmbedding` is multilingual but flat (SEARCH-QUALITY.md).
  - Embeddings are **candidate recall only**, never a link or fact decision.
- **Graph.**
  - `internetMessageHeaders` comes only with `$select`, and in full. It inflates list pages ([message resource](https://learn.microsoft.com/en-us/graph/api/resources/message?view=graph-rest-1.0)).
  - Probe `singleValueExtendedProperties` `String 0x1045` (PidTagListUnsubscribe) on list calls (unverified). We
    already expand one extended property for `msip_labels`.
  - `meetingMessageType` needs the `eventMessage` cast (`GraphMailService+Reader.swift`).

### 2.5 What predicts "needs reply" and "waiting"

| Signal | Direction | Tier | Source |
|---|---|---|---|
| The user sent the last message | Strongly against needs-reply; toward waiting or done | metadata | thread |
| The user replied after the last inbound | Against | metadata | thread |
| The user is in **To**, few other recipients | For | metadata | design assumption (Copilot uses people on the thread); validated on the bench |
| The user's historical reply rate to the sender (`toThem/fromThem`, decayed) | Strongest personal prior | metadata (CommGraph) | Aberdeen 2010, Dredze 2008 |
| The user started the thread, back-and-forth depth | For | metadata | Aberdeen 2010 |
| Bulk headers, noreply, `sender ≠ from` via an ESP | Hard against | metadata / headers | HEY, Spark, RFC 2369 |
| Meeting request not yet answered | For (RSVP) | metadata | Lampert 2008 |
| "?" to the reader, imperative, "bitte / könnten Sie / pourriez-vous / potrebbe", a deadline | For | **content** (gated) | Cohen 2004, Dredze 2005 |
| Auto-reply / OOF, "Danke!" / "Merci" closers | Against | subject / content | Lampert 2008 |
| My last sent message asks something, no answer after N days | **Waiting** | content of own sent mail | Gmail Nudges, Cortana |

---

## 3. Product definition

### 3.1 Two axes, not one tag

1. **Channel**, per conversation, mostly sender-level: `person`, `bulk`, `notification`, `calendar`, `automated`
   (auto-reply, bounce, receipt). Bulk becomes a channel, not an action state. This replaces `AITriageTag.bulk` and
   lines up with the `SplitInbox` buckets.
2. **Action state** (who acts next), per conversation:

| State | Ball with | Typical evidence | Shown as |
|---|---|---|---|
| **needsReply** | me | Inbound last, addressed to me, request / question / invite, my reply rate to them | "Reply needed" + ask line |
| **waiting** | them | I sent last and asked something, or I marked it waiting | "Waiting on Anna · 3 d" |
| **fyi** | nobody | Cc, broadcast, notification, "thanks" closer | No badge (FYI is the default) |
| **done** | nobody | My reply closed it, acknowledgement, archived, marked done | Hidden from the briefing |
| *snoozed* (overlay) | — | `MailMessage.snoozedUntil` | Snooze clock. Recomputed on wake |

There's **one badge at most**: Reply needed or Waiting. FYI is the absence of a badge, which removes a lot of the
"tags feel wrong" noise.

### 3.2 State machine (per conversation)

Events: `inbound(m)`, `outbound(m)` (also from other devices via Sent sync), `archive/delete`, `flag`,
`snooze/wake`, `tick(now)`, `override(s)`, `policyChanged`.

| From \ event | inbound to me (person) | inbound Cc / list / bulk | outbound (mine) | archive | tick | override(s) |
|---|---|---|---|---|---|---|
| *(new)* | classify → needsReply / fyi | fyi | classify → waiting / done | done | — | s (sticky) |
| needsReply | needsReply (refresh ask) | needsReply | → waiting if my message asks something, else **done** | **done** | after `nudgeAfter` (3 working days): "Received 3 d ago" | s |
| waiting | → classify (answer → needsReply / done / fyi) | waiting | waiting (follow-up sent) | stays waiting (default; open question) | after `followUpAfter`: "Follow up?" | s |
| fyi | → classify | fyi | → waiting / done | done | — | s |
| done | → classify (**reopens**) | done | waiting / done | done | — | s |

- **Overrides** win while the message they were set on is still the newest one. The next inbound or outbound message
  expires them and normal classification resumes. *(TRIAGE3, 2026-11-20: an expired override is no longer a prior.
  It judged an older message. Sender-level correction counts still act as a prior.)*
- **Sender-level overrides** ("never reply needed from X") persist.
- **Flags.** A flag due date sets the nudge time. A flag doesn't change the state (`FollowUpFlag` stays
  Outlook-compatible).
- **Calendar.**
  - An unanswered `meetingRequest` → needsReply ("RSVP").
  - Answered, or already on the calendar → done.
  - Responses to my invites → fyi.
- **Time.** States carry `since`. Nudges are pure functions of `now`.

### 3.3 What a Story is

> A **Story** is a named matter that spans **two or more conversations**: a project, case, deal, order, ticket or
> event. Every member is there for a reason you can show in one line: "same PO 4500123456", "project Phoenix", "same
> file Offerte_Q3.pdf", "you added it".

- **Membership.** A conversation belongs to at most one story.
- **Not stories.**
  - "Mail from Anna" is the person view.
  - "All newsletters" is a channel.
  - A single long thread is a conversation.
- **Target coverage.** ~10–30 % of person-channel conversations.
- **Lifecycle.**
  - `suggested` (not shown as a badge) → `active` → `dormant` (45 days without a new member) → `closed`.
  - `pinned` = user-named or user-edited. Pinned stories are never auto-dissolved.
- **Stories are the "matter" entities** of the knowledge layer (Section 6).

---

## 4. Triage pipeline architecture

```
 sync write path ─► ConversationFacts (L0) ─► TriageRules (L1) ─► decided? ─yes─► ConversationTriage (sealed)
                                                  │no
                     CommGraph tallies, priors ─► LocalScorer (L2) ─► confident? ─yes─► ConversationTriage
                                                                     │no / ask line wanted
                                                                     ▼
                                                    LLMTriage (L3: per thread, batched by token budget, gated)
```

### 4.1 L0: `ConversationFacts` (new `MailCore/InboxState.swift`)

Built from `MailStore.conversation(id:)`. Inbox and Sent are always live-synced (`MailSync.liveFolders`), so my
replies are local.

```swift
struct ConversationFacts: Sendable, Hashable {
    var conversationKey: UInt64            // HMAC(account, conversationId)
    var account: String                    // per-account policy
    var lastInboundAt, lastOutboundAt: Date?
    var lastFromMe, repliedAfterLastInbound, iStarted: Bool
    var myRole: Role                       // .to / .cc / .bccOrList (last inbound)
    var otherRecipients, inboundCount, outboundCount: Int
    var senderInternal: Bool
    var channel: Channel                   // .person/.bulk/.notification/.calendar/.automated
    var meeting: MeetingKind?
    var flagged: Bool; var flagDue, snoozedUntil: Date?
    var senderReplyRate: Double            // CommGraph toThem/fromThem, decayed
    var cues: Cues?                        // CONTENT bits, on-device gate only
    var signature: UInt64                  // last 3 member ids + folder states + override version
}
```

- **`ChannelClassifier`** replaces the `SplitInbox.bucket` internals but keeps its API for the tabs. Inputs:
  - local parts
  - `sender ≠ from` with an ESP domain
  - auto-reply subjects ("Automatische Antwort", "Abwesenheitsnotiz", "Out of Office", "Réponse automatique",
    "Risposta automatica")
  - categories
  - List-Unsubscribe once the probe confirms it (Phase 3)
  - a sender override table
  - `notificationDomains` moves into test fixtures.
- **`cues`** are lexical, DE/EN/FR/IT, and only where `exposure(.onDevice) == .content`:
  - "?" in the non-quoted part
  - request lexicon ("bitte", "könnten/können Sie", "please", "could you", "merci de", "pourriez-vous", "per favore",
    "potrebbe")
  - future dates (`NSDataDetector`)
  - closers
  - Stored as bits, never text.

### 4.2 L1: `TriageRules` (pure)

`decide(_ f: ConversationFacts, now:) -> Decision?` returns a state, a confidence and a reason code (an enum,
content-free), or nil.

| # | Rule | Result |
|---|---|---|
| R1 | channel ∈ {bulk, notification, automated}, no override | fyi (channel badge) |
| R2 | unanswered meeting request | needsReply `.rsvp` |
| R3 | lastFromMe and my message has a question / request cue | waiting |
| R4 | lastFromMe, no cue | done if the thread is ≥ 2 inbound deep and my message is short; else undecided |
| R5 | repliedAfterLastInbound | never needsReply |
| R6 | myRole = bccOrList | fyi |
| R7 | myRole = cc, ≥ 3 others, no name / question cue | fyi |
| R8 | inbound last, To, ≤ 2 others, question / request / deadline cue | needsReply (high) |
| R9 | inbound last, closer only | done |
| R10 | conversation override since the last event | override |
| R11 | sender override | as overridden |

The rules run in the sync tick (< 1 ms per conversation). **Every inbox conversation has a state when it's shown.**

### 4.3 L2: `LocalScorer` (on-device, per account)

- **Model.** Logistic regression on ~20 binned features: role, recipients, internal, iStarted, depth, reply-rate
  band, `log(1+toThem)`, `log(1+fromThem)`, hour/weekday, cue bits, channel, flags.
- **Prior.** A Beta(α, β) per sender from outcomes and corrections.
- **Start.** Hand-set weights tuned on the bench, then online SGD on the user's data. Weights are sealed in kv
  `ai.triage.model.<account>`.
- **Bands.**
  - p ≥ 0.75 → needsReply.
  - p ≤ 0.25 → fyi.
  - Otherwise uncertain → L3 if allowed. If not, show the L2 state at low confidence (a dot, no badge).

### 4.4 L3: LLM per thread

- **When.** The uncertain band, or needsReply with no ask line.
- **Input per item = one conversation.**
  - The newest inbound message plus ≤ 2 earlier messages (including my last sent one), via `AIPromptBuilder`.
  - The facts as `Context:` lines. These extend `TriageContext.lines` with the reply-rate band and an L1/L2 hint.
- **Output.**
  - On-device: `@Generable struct ThreadVerdict { state; askLine; deadline?; userCommitment?; why }`.
  - Cloud: the same JSON schema.
  - Missing items fall back **per item** to L2.
- **Batching by token budget.**
  - `tokenCount(for:)` against `contextSize`, minus ~60 output tokens per item. Typically 3–6 threads on-device,
    ≤ 12 in the cloud.
  - On overflow, halve the batch and retry once, then fall back to L2.
- **Gate.** Per message as today. A thread that's all metadata goes as metadata, and still has its L1/L2 state.
- **Hard rules win.** R1, R2, R5, R6 and R10 can't be flipped to needsReply by the LLM.

### 4.5 Storage, cache, recompute, latency

- **`conv_state(key BLOB PRIMARY KEY, payload BLOB)`** (sealed, fixed size).
  - `key` = HMAC(account, conversationId).
  - Payload `ConversationTriage { state, ball, since, confidence, source(.rule/.scorer/.llm/.user), reason, ask?, why?, signature }`.
  - Ask and why text are persisted only where `MailContentPolicy.allowOfflineDetails` allows. Otherwise they're
    memory-only.
- **Cache key = `signature`**, not `changeKey`. Read and flag don't invalidate it. A new message, my reply, a move
  or an override do.
- **Triggers.**
  - Store write paths queue the conversation key (the `story_pending` pattern) on insert, move or delete of any
    member, including Sent.
  - Flag and snooze changes.
  - An hourly tick (nudges are computed on read).
  - Policy or tier change: drop L3 results, keep L1/L2.
- **Scope.** L0–L2 run for **every** conversation with an inbox member in the window (default 30 days), across all
  mailboxes. L3 runs from a background queue, visible rows first, on-device concurrency 1, cloud 2.
- **Waiting scope.**
  - Also every conversation whose **last message is mine** (Sent) within the window, even with no inbox member,
    for example threads I started.
  - Also archived conversations in `waiting` (per 3.2).
  - They surface in the Briefing's Waiting / "Follow up?" groups, in a "Waiting" smart view (`MailListUI` filter),
    and in the MCP `awaiting_them` lists.
- **Per-exposure rules.**

| Exposure (on-device tier) | L0 facts | L1 / L2 | L3 | Persisted |
|---|---|---|---|---|
| content | all, incl. cues | yes | content | state + ask/why per `allowOfflineDetails` |
| metadata | no cues | yes | metadata only | state only |
| excluded / private / unknown label | `myRole` and `otherRecipients` **unknown**: `sanitizeForCache` empties recipients on disk for protected / unknown labels. Direction and time only | **direction-only rules**: lastFromMe → waiting / done; inbound → `needsReply?` at low confidence (no badge, dot only) | never | state only (no text) |

  "0 untagged" counts every inbox conversation, including excluded ones (they get the direction-only state).
- **Gated context for L3.** The reply-rate band in `Context:` lines comes from CommGraph tallies, which aren't a
  gate.
  - For the **cloud tier** it's recomputed from gate-passing messages (the CommGraph tool rule), or dropped.
  - On-device it may use the tallies, because metadata never leaves the Mac.
- **Failures are counted by kind:** `contextOverflow`, `guardrail`, `unavailable`, `timeout`, `parse`.

| Path | Budget |
|---|---|
| New mail → L1/L2 state shown | the same sync tick (< 5 ms per conversation) |
| L3 ask line, visible rows | p50 ≤ 4 s on-device, ≤ 8 s cloud |
| Briefing open | reads `conv_state` only |

### 4.6 UI (`AIViews.swift`, the tag slot in `LIST-LAYOUT.md`)

- **Badges.** needsReply or waiting only. Solid = rule, LLM or user; outlined = scorer.
- **One-click correction.**
  - A click on the tag (or a shortcut) cycles Reply needed → Waiting → None.
  - The menu adds "Done" and "Never for this sender".
  - Hover shows the reason ("You're in To, they asked a question, you usually reply to Anna").
- **Briefing (⌃⌘B).** Grouped by **conversation**, ordered by ball and age. It includes a "Follow up?" group.

---

## 5. Stories redesign (StoryEngine v3)

### 5.1 Pipeline

```
conversation changed ─► ConvFeatures (sealed, fixed size)
   ─► candidate stories (people∖hubs ∪ org ∪ time ∪ anchor postings ∪ embedding kNN)
   ─► StoryLinker: ≥ 1 ANCHOR required, score vs story ─► assign / suggest / none
user actions (add, not related, merge, split, rename) ─► story_def / story_member / story_constraint ─► always win
```

### 5.2 `ConvFeatures` (replaces the message-level `Feat`)

Aggregated per conversation. They stay HMAC hashes, stay sealed and stay **fixed size** (1 KB), so the file still
doesn't show which conversations had content.

| Feature | Notes |
|---|---|
| people, orgs | Minus the owner. Minus **hub contacts** (in > 5 % of conversations: assistant, manager, own team), from CommGraph |
| **anchors** (typed, new `StoryAnchors.swift`) | `id:` reference numbers, normalised (Rechnung / facture / fattura / invoice no., PO / Bestellung, order, ticket `#12345` / `INC…` / `[ABC-123]`, Offerte no., contract, Fall / dossier / case no.). `att:` non-generic attachment stems (`image001`, `scan`, `document`, `invoice` … dropped). `stem:` normalised subject stem (strip RE/AW/WG/FW/TR/R/I, `[EXTERNAL]`; needs ≥ 2 non-generic terms). `proj:` gazetteer of user-named stories and project names |
| topic terms | Rare subject and entity terms after three-level boilerplate filtering: per counterpart (as today), **per org**, **global signature/footer**. Preview body terms are **no longer link evidence**: they were the main noise source |
| vector | Optional, candidates only (5.6) |
| span, channel, content bit | |

### 5.3 Linking rules

C = conversation, S = candidate story.

| Evidence (C ↔ S) | Can it link on its own? |
|---|---|
| The user put C in S | yes |
| Same `id:` anchor (df ≤ 10 conversations) | **yes** |
| Same `proj:` | yes |
| Same non-generic `att:` | yes, with a shared non-hub person or org |
| Same `stem:` (≥ 2 rare terms) | yes, within 21 days and with a shared non-hub person or org |
| ≥ 2 rare topic terms + shared non-hub person + Δt ≤ 14 d | **suggestion only** (or confirmed by L3) |
| Embedding similarity, same counterpart, same org, time | **never**. Candidates only |

- **Score.** `score = max(anchor evidence) + 0.3 × topic`, decayed by `exp(-Δt/14d)` against S's most recent member
  (TDT-style). Assign at ≥ θ_assign with ≥ 1 linking anchor. Otherwise make a suggestion at ≥ θ_suggest.
- **No chaining, no bridging.**
  - C joins the best story only.
  - Anchors into two stories → join the best one and record a **merge suggestion**.
  - Auto merges happen only when both stories share an `id:` anchor and neither is pinned.
- **New stories.** Two unassigned conversations sharing a linking anchor. One conversation never makes a story.
- **Hard negatives.**
  - Bulk, notification and automated conversations join only through an `id:` (a ticket notification belongs to its
    ticket's story). They never start or bridge a story.
  - Generic subjects never count as a stem: Rechnung, Offerte, Meeting, Update, Frage, Anfrage, Info, Termin,
    Facture, Réunion, Fattura, Riunione, Invoice, Quick question, ….
  - The same counterpart alone never links.
- **Metadata-only conversations** join only by user action. The invariant stays: metadata never bridges.
- **Limits.**
  - Auto-assignment cap of 25 conversations per story (unlimited for the user).
  - Anchors with df > 10 conversations are demoted to topic terms (footer customer numbers).
  - Dormant after 45 days.
  - 180-day feature window. Story definitions outlive it.

### 5.4 Persistent identity and user controls

- **Sealed tables that survive `reset()` and version bumps.** Only `ConvFeatures` are rebuilt.
  - `story_def(sid, payload)`: random 128-bit sid, title, `userNamed`, state, created, last activity, anchor hashes,
    participant summary.
  - `story_member(convKey, payload)`: sid, source (auto / user), reason code.
  - `story_constraint(pairKey, payload)`: must-link and cannot-link.
- **Actions** in the row menu, the story header and `RelatedStrip`:
  - Add to story… / New story from selection (seeds and gazetteer).
  - **Not part of this story** (cannot-link plus an anchor penalty).
  - Merge (keep the older sid), Split (cannot-link between the halves), Rename (permanent), Close.
  - Accept or dismiss a suggestion ("Also about *Phoenix*? Same PO 4500123456").
- **Reason chips on every member.** The anchor text shows only if the gate allows it at read time.

### 5.5 Naming

- Use `StoryTitles.onDeviceTitle` over gated subjects plus the dominant anchor text when it's allowed.
- Cloud naming only if every input is cloud-allowed.
- The fallback stays.
- Name on create, merge or split only. A user rename is final.

### 5.6 Embeddings

Embeddings are candidate generation only (k = 10), and they must win on the bench before they're turned on. Re-test
the macOS 27 options with the bench, not by hand.

### 5.7 Files

- **`StoryEngine.swift`.** Replace `Feat`, `score`, `link`, `Memory.union` and `rebuild` with `ConvFeatures`,
  `StoryLinker` and `StoryStore`. Keep hashing, sealing, the pending queue and catch-up. `version = "3"`.
- **New `StoryAnchors.swift`** (pure, tested): anchor regexes, normaliser, generic lists.
- **`StoryViews.swift`.** Actions, reason chips, suggestion banner.
- **`StoryTools.swift`.** A stable sid and reason codes per member.
- **Diagnostics.** `debugShape`, `debugSizeBuckets` and `debugLinks` gain anchor-type, suggestion and constraint
  counts.

---

## 6. Local knowledge layer ("Work IQ, but local")

Target questions:

- *"Show me mails from my lawyer."*
- *"Show me details of that project I did back in Feb for that architect."*
- The same in German, French and Italian.

### 6.1 Model: entities, facts, provenance

```
Entity:  person(address set) | org(registrable domain / name) | matter(= Story sid, or an interim matter) | role(type)
Fact:    (subject, predicate, object, confidence, provenance[rid], evidenceKinds, account, tierFloor, createdAt, userAsserted?)
         predicates: hasRole(person|org, role) · worksFor(person, org) · participant(matter, person, weight)
                     hasAnchor(matter, id) · activeDuring(matter, interval) · counterpartOf(matter, org)
                     sameAs(person, person)   (two addresses, one person)
```

- **Roles are typed values**, not free text: `lawyer`, `notary`, `architect`, `accountant/treuhand`, `tax advisor`,
  `bank`, `insurance`, `landlord/property manager`, `doctor`, `school`, `customer`, `supplier`, `colleague`,
  `manager`, `recruiter`, plus `custom(label)` for user-defined roles. Each type has a DE/EN/FR/IT lexicon (see
  6.2).
- **Provenance.** Every fact stores the rids that support it, each with its evidence kind (directory, signature,
  domain, subject, attachment, invoice direction, user). Nothing is a fact without at least one rid or a user
  assertion.
- **Storage.**
  - New sealed tables `kn_entity(key, payload)` and `kn_fact(key, payload)`. The key is an HMAC under a key derived
    from the index key (the CommGraph pattern, `HKDF info "knowledge-v1"`).
  - Payloads are fixed-size buckets where practical.
  - **One namespace per account**: the HMAC includes the account, and the policy is per account.
  - Wiped with the store, never sent anywhere.
- **Relationship to existing nodes.** CommGraph `PersonNode` and `ProjectNode` stay the metadata backbone (tallies,
  neighbours, company). Facts point at their keys instead of duplicating them. Matters are Stories (5.x); before
  Stories v3 exists, they're interim matters (6.4).

### 6.2 Role inference (evidence → `hasRole` facts)

| Evidence kind | Example | Weight | Needs content? |
|---|---|---|---|
| Directory `jobTitle` / `department` (`GraphPeopleService`) | "Rechtsanwältin", "Legal Counsel" | 0.9 | no (directory) |
| Signature title line (last zone of the non-quoted body) | "lic. iur., Rechtsanwalt", "dipl. Architekt ETH SIA", "Avocate", "Avvocato", "Notar", "dipl. Treuhandexperte", "Dr. med." | 0.8 | **yes** (on-device gate) |
| Org name / domain tokens | `advokatur`, `anwalt`, `law`, `legal`, `avocats`, `notariat`, `architekt(en)`, `arch`, `treuhand`, `fiduciaire`, `revision`, `immobilien`, `verwaltung`, `régie`, `praxis`, `schule` | 0.5 | no (address / display name) |
| Recurring subject / attachment vocabulary | "Honorarrechnung", "Mandat", "Vollmacht", "Klage"; "Baueingabe", "Baubewilligung", "Pläne", "Grundriss"; "Steuererklärung", "Jahresabschluss"; "Mietvertrag", "Nebenkosten" | 0.4 each, capped | subject: metadata on-device, gated per label |
| Invoice direction | They send me "Rechnung" / invoice anchors → supplier; I send Offerte / Rechnung → customer | 0.5 | subject / anchors |
| User assertion | "This is my lawyer" / "Not my lawyer" | ∞ / −∞ | no |

- **Combination.** Noisy-OR per (entity, role):
  - `conf = 1 − Π(1 − wᵢ)` over **independent** evidence kinds (repeats of one kind count once, with a small bonus).
  - A role is *asserted* at conf ≥ 0.7 with ≥ 2 kinds, or 1 strong kind (directory, signature, user). Otherwise it's
    a hint.
- **Propagation.** A role on an org (law firm) propagates to its people at 0.6×, unless a person's own evidence says
  otherwise (a law firm's assistant isn't "my lawyer"; signature evidence wins).
- **"My" X.** Candidates with role X are ranked by relationship strength with me: CommGraph `toThem` (I write to
  them) weighted over `fromThem`, recency, and whether I'm in To. "My lawyer" excludes people who only appear with me
  in Cc on someone else's matter (opposing counsel). Ties show **disambiguation chips**, never a silent guess.
- **Where it runs.** Incrementally, from the same pending queue as Stories (a per-person dirty set). Signature
  parsing runs only on messages whose body is already cached and content-allowed on-device. It never fetches bodies
  just for this (open question 4).

### 6.3 Query understanding

`KnowledgeQuery.interpret(_ text:, now:, locale:)` is deterministic first and extends `NaturalQuery`:

| Slot | Parses | Examples |
|---|---|---|
| role | the role lexicon + possessive ("my", "mein/meine/meinem", "mon/ma", "mio/mia", "our/unser") | "my lawyer", "meinem Anwalt", "ma fiduciaire", "il mio architetto" |
| person / org | names (existing `senderWords`) + entity gazetteer (display names, orgs, user-named roles) | "Anna", "Müller Architekten" |
| matter | project nouns ("project / Projekt / projet / progetto / matter / Fall / dossier / case / Auftrag / Bau…"), story titles, anchors ("PO 4500…") | "that project", "the Phoenix thing" |
| time | **month names and abbreviations** in DE/EN/FR/IT ("Feb", "Februar", "février", "febbraio"), "back in / im / en / a" + month → the **most recent past** occurrence; seasons ("last summer" = Jun–Aug of the last completed summer; "im Frühling"); years; "Anfang / Mitte / Ende März"; quarters; "vor 2 Monaten"; existing relative phrases | "back in Feb" → 2026-02-01…2026-02-28 (if now = Nov 2026) |
| intent | `mails` (list), `details` / `what happened` (card), `files` / `attachments`, `who` | "show me details of…" → card |
| vagueness | "that / jenes / ce / quel" + a noun marks the slot as *resolve by context*, not as a keyword | "that architect" = role architect, not the literal word |

- **Fuzzy time is soft.** A window gets a ±25 % margin with decay, not a hard filter (people misremember months).
- **LLM fallback.** When the rules leave unresolved spans, an on-device `@Generable QueryFrame { roles, people,
  timeFrom, timeTo, matterHints, intent }` parses the query.
  - The query is the user's own text, not mail, so on-device parsing needs no label gate.
  - Cloud parsing only if the user's AI settings allow the cloud tier for "Ask".
  - The model never sees candidate entities here, only the query.

### 6.4 Resolution and answering

```
QueryFrame ─► resolve entities (role facts → people/orgs; names → people; matter hints → stories/anchors)
          ─► matter lookup (stories where participant ∈ resolved people ∧ activeDuring ∩ time ≠ ∅)
          ─► ranked search (SearchEngine natural: sender/participant set + soft time window + remaining terms)
          ─► card assembly (gated per row at read time) ─► optional LLM summary (gated, cited)
```

- **"Mails from my lawyer".**
  - role = lawyer, possessive → top-ranked lawyer entity (or chips).
  - The result is a **filtered list**: from or to their address set, newest first, with search ranking when extra
    terms exist.
  - The header says "Your lawyer: Dr. A. Muster (Kanzlei X) · why: signature 'Rechtsanwältin', 14 mails, you write
    to her" with provenance links.
- **"Details of that project back in Feb for that architect".**
  - Resolve role = architect → candidates. Time = Feb 2026 (soft).
  - Matters: Stories (v3) whose participants include a candidate and whose span overlaps Feb.
  - **Before Stories v3, an interim matter:** at query time, take the conversations involving the candidate within
    the window ±25 %. Group them by `StoryAnchors` (`id:`, `att:`, `stem:`). The largest anchored group is the
    matter; unanchored conversations are "also in that period".
  - The answer is a **Matter card**:

| Card part | Source | Gate |
|---|---|---|
| Title | Story title / interim: dominant anchor or subject stem | Text only if a supporting message's subject is allowed at read time |
| People and roles | `participant` + `hasRole` facts | Per fact (6.5) |
| Dates | First and last activity, key dates (meetings from the calendar) | metadata |
| Key IDs and files | Anchors, attachments (open via the existing reader path) | Per message |
| Last state | `ConversationTriage` of member conversations (e.g. "waiting on architect since 12 Mar") | metadata |
| Summary (optional) | LLM over gated members, citations `[n]` → messages | AI gate, tier |
| Citations | Every line links its rids | — |

- **Surfaces.**
  - Ask / ⌥↩ (SearchHub) shows the card above the result list.
  - The MCP gets `entity_lookup(query)` and `matter_card(id | query)` (read-only, same gate as `project_context`).
    The in-app agent gets both.
  - Their outputs recompute everything visible from gated messages (the CommGraph rule: facts propose, the gate
    disposes).

### 6.5 Compliance rules for facts

1. **A fact is only as visible as its evidence.** For a given tier and account, a fact is usable only if ≥ 1 of its
   supporting rids, *on its own* sufficient for the fact, has an exposure that allows the evidence kind:
   - content kinds (signature, body) need `content`
   - subject and anchor kinds need the subject to be allowed for that tier (`subjectForMetadata` rules)
   - address, domain and directory kinds need metadata.
   It's re-evaluated **at read time**, because labels change.
2. **Content-gated evidence is never used.** A message whose exposure is `metadata` contributes only metadata
   evidence kinds. `excluded` / private / unknown-label messages contribute **nothing**: not even counts in a role
   score, since a role derived from a private mail would leak it.
3. **Persisting derived text.** A fact derived from content is persisted (sealed) only if the source message's
   `MailContentPolicy.allowOfflineDetails` is true. Otherwise it's memory-only and recomputed after unlock.
4. **Per account.** Facts, priors and corrections never cross accounts unless the user opts in (open question 3).
   The policy is per account (`AIGatePolicy` per mailbox).
5. **Cloud.** A cloud LLM sees a fact only if rule 1 holds for the cloud tier, and only as `Context:` lines with
   the same nonce wrapping as mail. The default is on-device.
6. **Logs.** Only counts (facts by kind, roles by type, resolution success), like `debugLinks`.

### 6.6 User corrections

- **Roles.**
  - On a person or card: "Not my lawyer" (−∞ for that role and person; the next candidate is promoted), "This is
    my …" (role picker plus custom labels), "Same person as…" (`sameAs`), "Wrong company".
- **Matters.**
  - Rename (Story rename), "Not part of this project" (Story cannot-link), "Add these mails".
  - An interim matter can be **saved as a Story** (pinned), which seeds Stories v3.
- **Storage.** User assertions are facts with `userAsserted = true`, sealed, per account, and survive rebuilds. A
  user assertion is never hidden by rule 1 (the user said it), but **citations** still follow the gate.

---

## 7. Feedback and learning

| Signal | Capture | Used for |
|---|---|---|
| Triage override | `triage_feedback` (sealed): convKey, from→to, the numeric `ConversationFacts` vector, ts, account | `LocalScorer` SGD, sender Beta prior, rule audit counts |
| "Never for this sender" / channel move | `sender_override` (HMAC(account, address)) | R11, `ChannelClassifier` |
| I replied within 48 h | implicit positive | sender prior (w 0.3) |
| Archived without reply / unread > 7 d | implicit negative | sender prior (w 0.2) |
| Follow-up sent on a waiting thread | implicit positive | `followUpAfter` |
| Story add / not related / merge / split | `story_constraint`, anchor penalties | linker |
| Role and matter corrections | `kn_fact` user assertions | resolution, role weights per evidence kind |

All of it is sealed, local and per account. There's no telemetry, and audit records hold counts only.

**Drift guards:**

- Clamped weights.
- Decaying learning rate.
- "Reset learning" in Settings → AI.
- Implicit signals never override an explicit correction.
- Settings → AI shows correction counts.

---

## 8. Evaluation harness

### 8.1 Synthetic corpus (`InboxBench`, in `Sources/SearchBench` + `CoreSelfTest`)

- **Volume and mix.** A deterministic generator: ~600 conversations, ~2,000 messages. DE 55 %, EN 25 %, FR 12 %,
  IT 8 %. `.example` domains. **No real mail.**
- **Gold labels per conversation:** state@now, ball, ask (some), story id (~60 stories of 2–12 conversations).
- **Gold per persona:** roles.
- **~60 knowledge queries with gold.**
- **Triage and story hard cases:**
  - the same counterpart on 3 topics
  - other vendors' Rechnungen
  - signature-heavy senders
  - a hub colleague
  - generic subjects
  - ticket notifications with IDs
  - a FR reply to a DE thread
  - auto-replies
  - a Cc request addressed by name
  - an invite already answered
  - my unanswered question (5 d)
  - "Danke!" closers
  - protected / unknown-label rows (any leak fails the run, `LEAK`)
- **Knowledge personas:**
  - my lawyer (signature only)
  - opposing counsel (lawyer, but only in Cc on another matter)
  - a law firm's assistant
  - two architects: mine, with a Feb project of 6 conversations and a PO plus plans PDF, and one who only sends
    newsletters
  - a Treuhänder who sends a "Jahresabschluss" every March
  - a notaire in French
  - an avvocato in Italian
  - a role evidenced **only** by protected mail (must stay unknown)
  - a person with two addresses
- **Query set** (DE/EN/FR/IT): role, role + time, vague matter, person + topic, anchor ID, files ("die Pläne vom
  Architekten"), and "who is my …". 20 % are held out and written before tuning (the SEARCH-QUALITY discipline).

### 8.2 Metrics and targets

| Area | Metric | Target |
|---|---|---|
| Triage | untagged inbox conversations | **0** |
| | needsReply precision @ recall | **P ≥ 0.85 at R ≥ 0.80** |
| | waiting P / R | ≥ 0.80 / ≥ 0.70 |
| | fyi → needsReply false alarms | ≤ 5 % |
| | rules-only (AI off) needsReply P / R | ≥ 0.75 / ≥ 0.60 |
| Stories | BCubed precision / recall | **≥ 0.90** / ≥ 0.70 |
| | ARI (secondary) | ≥ 0.6 |
| | conversations in stories | 10–30 % |
| | largest auto story | ≤ 25 conversations |
| | links from same-counterpart-only evidence | 0 |
| Knowledge | role inference P / R (personas) | **≥ 0.90** / ≥ 0.70 |
| | "my X" top-1 correct (or chips containing it) | ≥ 0.90 (≥ 0.98) |
| | time-expression parse accuracy (table of ~80 phrases × 4 languages) | 100 % |
| | matter query: right matter top-1 / top-3 | **≥ 0.80** / ≥ 0.95 |
| | cited messages nDCG@10 vs gold | ≥ 0.85 |
| | facts usable from protected-only evidence | **0** (privacy gate) |
| Latency | L0–L2 per conversation | p95 < 5 ms |
| | knowledge query → card (no LLM) | p95 < 300 ms on 50k rows |

### 8.3 Owner mode (real mailbox, content-free)

- `--inbox-score` reads corrections plus an optional in-app **labelling session**:
  - 50 conversations ("Who acts next?")
  - 30 story pairs ("Same matter?")
  - 10 role checks ("Is X your lawyer?")
  - 10 of his own questions marked right or wrong on the card.
- It prints **aggregates only**: confusion counts, P/R, override rate, BCubed on the labelled pairs, role precision,
  query success, failure counts by kind. No subjects, names, addresses or ids.

---

## 9. Phased implementation

| Phase | Scope | Files | Tests | Success criteria | Effort |
|---|---|---|---|---|---|
| **0. Instrument** | `AIProviderError` kinds (`contextOverflow`, `guardrail`, `unavailable`); `OnDeviceProvider` maps `LanguageModelSession.GenerationError`; the `[AI] triage` log gets per-kind counts and the token estimate | `AIAssistProvider.swift`, `AIAssistModel.swift` | `AIAssistTests` | The owner run shows which of H1–H3 is real | ½ day |
| **1. Conversation state, never untagged** | `ConversationFacts` incl. **lexical cues** (DE/EN/FR/IT, gated) and `ChannelClassifier`; `TriageRules` R1–R11 incl. a minimal `sender_override` table (for R11 and "Never for this sender"); `ConversationTriage`, `conv_state` + queue; all inbox conversations in the window, plus mine-last Sent threads and archived waiting threads; cache by signature; L3 per thread with per-item fallback **to the L1 state, or `undecided`** (no scorer yet); halving retry; token-budgeted batches; `@Generable` on-device; one badge + one-click sticky override; briefing by conversation; bulk → channel; `company_context` / `people_history` "awaiting" read `conv_state`. **Undecided without L3** (AI off or gated) shows a low-confidence state from direction: inbound last → dot "maybe reply", mine last → "waiting" without a badge. It never shows a blank | **new** `MailCore/InboxState.swift`; `AIAssistModels.swift`; `AIAssistFeatures.swift`; `AIAssistModel.swift` (scheduler rewrite: no `prefix(30)`, no `onChange` trigger); `AIViews.swift`; `MailStore.swift`; `MailPolicy.swift` | **new** `CoreSelfTest/InboxStateTests.swift`: every transition in 3.2, R1–R11, "read/flag keeps the state", "my reply flips needsReply", "failed batch keeps the L1 state", partial JSON, the exposure table in 4.5; **~40 synthetic triage fixture threads** (the seed of InboxBench) with gold states | 0 untagged; stable across sync; a reply clears "Reply needed" within one tick; rules-only needsReply P ≥ 0.75 on the fixtures (full-bench floor in Phase 3) | 5–6 days |
| **2. Knowledge v1: the two example queries** | `StoryAnchors` (pure; brought forward); `kn_entity` / `kn_fact` with provenance + per-account HMAC; role inference from directory, domain/org tokens, subject/attachment vocabulary, invoice direction, and signatures of cached content-allowed bodies; `KnowledgeQuery` (role + possessive, month / season / year time in 4 languages, vague references, intent); resolution → **interim matters** (query-time anchor grouping) → existing `SearchEngine` natural ranking; Person card + Matter card with citations; "Not my lawyer" / "This is my …" corrections; MCP `entity_lookup`, `matter_card` | **new** `MailCore/Knowledge.swift` (store, facts, gate rules 6.5), **new** `MailCore/KnowledgeRoles.swift` (lexicons, noisy-OR), **new** `MailCore/KnowledgeQuery.swift`, **new** `MailCore/StoryAnchors.swift`; `SearchUnderstanding.swift` (month / season parsing shared); `SearchEngine+Natural.swift` (participant-set filter); `OfficeTools/GraphTools.swift` or a new `KnowledgeTools.swift`; Ask / SearchHub views | **InboxBench v1, knowledge part**: personas, query set, time table; privacy test "role from protected-only mail stays unknown"; gate re-check on relabel | "my lawyer" top-1 ≥ 0.9; Feb-architect matter top-1 ≥ 0.8 on the bench; the owner's two queries answer correctly with citations | 6–8 days |
| **3. Bulk headers, scorer, feedback, nudges** | Probe `String 0x1045` on list calls (live probe like `LiveWriteProbe`) and adopt it if cheap; `LocalScorer` + sender Beta prior from CommGraph; `triage_feedback` (`sender_override` exists since Phase 1); waiting from the cues of my own sent mail; nudges | `InboxState.swift`, **new** `InboxScorer.swift`, `GraphMailService.swift`, `CommGraph.swift` (reply-rate accessor), `AIViews.swift` | Scorer tests; **InboxBench, triage part** (extends the Phase 1 fixtures) | needsReply P ≥ 0.85 @ R ≥ 0.80 (with LLM); rules-only floor P ≥ 0.75 / R ≥ 0.60; L3 calls ≤ 30 % of conversations | 5–6 days |
| **4. Stories v3 core** | `ConvFeatures`, `StoryLinker` (assignment, anchors required, no bridging), hub contacts, 3-level boilerplate, `story_def` / `story_member` / `story_constraint`, migration (drop v2, rebuild); knowledge matters switch from interim to Stories (`participant`, `activeDuring`, `hasAnchor` facts) | `StoryEngine.swift`, `StoryTools.swift`, `Knowledge.swift`, `StoryTests.swift` | **InboxBench, story part**: BCubed, ARI, size, coverage; "metadata never bridges"; anchors in 4 languages | BP ≥ 0.90, BR ≥ 0.70; 10–30 % in stories on the owner's mailbox (`debugShape`); matter query top-1 not worse than interim | 7–9 days |
| **5. Story controls, learning, naming** | Add / not related / merge / split / rename / close, suggestions, reason chips, constraints, anchor penalties; "save interim matter as Story"; naming on create/merge | `StoryViews.swift`, `StoryEngine.swift`, `AIViews.swift`, knowledge card views | UI-model tests; constraints survive `reset()` | Any wrong story fixed in ≤ 2 clicks | 4–5 days |
| **6. Owner scoring, L3 refinements** | `--inbox-score` + labelling sheet; LLM confirmation of suggested links and of ambiguous roles (gated, on-device first); commitments ("you said you'd send…"); optional gated card summaries | **new** `InboxScoring.swift`, `AIAssistFeatures.swift` | Aggregate-only output test (no strings from mail) | Owner report available; targets met on his labels | 3–4 days |

**Why this order:**

- Phase 1 fixes what the owner sees every day.
- Phase 2 delivers the two example queries early. It doesn't need Stories v3: roles come from directory, domain,
  subject and signature evidence, and "that project" resolves through query-time anchor grouping around the resolved
  person and month.
- Phase 4 then swaps interim matters for persistent Stories, with no API change for the cards.

**Not doing:**

- Core ML training pipelines (LR on device is enough).
- Cloud-side learning or memory.
- Cross-account fact sharing by default.
- Auto-archiving.

---

## 10. Risks and open questions

**Risks:**

- **Rigid rules on edge cases** (Cc'd but addressed by name). R7 requires "no cue"; override in one click.
- **Header fetch cost.** Probe first. Otherwise heuristics plus sender overrides (HEY's model).
- **Story coverage drops sharply** (86 % → ~15 %) and may feel like a regression. Suggestions and "add to story"
  cover discovery.
- **Role inference from signatures** needs cached bodies. With previews only, roles fall back to
  directory, domain and subject evidence, so recall on small firms with generic domains (e.g. `@bluewin.ch`) is lower.
- **The on-device model varies by macOS version and region.** Budget at runtime. L1/L2 and the deterministic query
  parser are the source of truth; the LLM only refines.

**Open questions for the owner (max 5):**

1. **Waiting scope.** Should "Waiting" mean only threads where your last message asked something (on-device reading
   of your own sent mail), or every sent thread without an answer after N days (Gmail-style, metadata only)?
2. **Story bar.** Is it fine that most mail is in no story? Only anchored matters (IDs, project names, same files,
   your seeds) would form stories; the rest would be suggestions.
3. **Multi-account.** Should facts, roles, priors and overrides stay strictly per account, or may they be shared
   across your own accounts on this Mac (still sealed and gated per account)?
4. **Body fetch for roles.** May the app fetch and cache bodies in the background (only for content-allowed labels,
   recent mail from frequent correspondents) so signatures can be read? Without it, "my lawyer" relies on directory,
   domain and subject evidence until you've opened their mail.
5. **Labelling.** Will you spend ~15 minutes once in-app (50 threads, 30 story pairs, 10 role checks, 10 of your own
   questions), so owner-mode scoring has ground truth?

---

## Build status (Phases 0–1, 2026-11-20)

**Owner decisions applied.** (1) Waiting = my last message asked something (cue bits, gated), or N working days
without an answer with at least one direct (To) recipient; N is a setting (default 3). "Plain FYI" never counts: an
FYI marker or closer in my message, a forward (FW/WG/TR/I) with no ask, or a send with nobody in To. Before N days a
no-ask send is `done` at low confidence (no badge). (3) All triage tables are per account (HMAC keys prefixed with
an account tag). (5) The training tool is built. (2, 4) not needed for this phase.

**Phase 0 counters** (read from the owner's run log after deploy; nothing is confirmed yet):
- `[AI] triage …` (old path) now ends with `route=<tier> calls ok onDevice cloud fail[kind=n] estTok max/avg ctx=<model context>`,
  and a failed batch logs `kind=` instead of the type name. H1 = `fail[contextOverflow]` > 0 or `estTok max` ≥ `ctx`;
  H2 = `fail[guardrail]`; H3 = `route=onDevice`.
- `[AI] triage threads=… answered keptRule route fail[…]` (new L3 path) carries the same stats.
- `[Triage] conversations … listedUntagged=x/y h0 legacyKeyChanged=a/b`: H0 = how often the old cache key changed for
  the same visible message id (what orphaned tags); `listedUntagged` should be 0.
- `OnDeviceProvider` maps FoundationModels errors (`LanguageModelError` on 27, `GenerationError` on 26) to
  `contextOverflow` / `guardrail` / `unavailable` / `rateLimited` / `parse`.

**Interpretations.** With on-device AI switched off by policy, the rules still use metadata (direction, To/Cc) but
never read text. Excluded rows: inbound → "maybe reply" dot; mine last → waiting (no badge) after N days, else done.
L3 can only decide non-hard, non-restricted rows; on hard needsReply rows it may only add the ask line.

**Not done in Phase 1.** `@Generable` (macro; JSON on both tiers); `tokenCount(for:)` (chars/4 estimate against
`contextSize` instead); meeting kind on list rows (R2 is implemented and tested with injected facts); the Waiting
smart view; nudge UI beyond hover text and the Briefing's "Follow up?" group; `notificationDomains` still in
`SplitInbox`; the MCP process computes the state on its own store, so it doesn't see the app's overrides.

**TRIAGE3 (2026-11-20): truth pinned in time, and the trainer shows the conversation.** Owner feedback: the trainer
showed no body, and "needs reply" depends on when you look.
- **Snapshot.** Each answer is pinned to the newest message the user saw (`TriageSnapshot`: a keyed tag of the
  message id and its received time; never the raw id). Answers are keyed by conversation HMAC + a tag of the
  snapshot time, so one conversation can hold answers for several snapshots. The answer also stores whether the
  conversation was in the inbox at the time.
- **Scoring.** Each answer is compared with the prediction recomputed *as of its snapshot*
  (`ConversationFactsBuilder.build(…asOf:)`: only the messages up to the snapshot, and the stored inbox membership
  rather than today's folders). The clock is the time of the answer. Later messages never count against an answer;
  the score shows them as "moved on since".
  - Limits: read, flag, snooze, meeting state and the label gate are today's values.
  - L3 verdicts are used only while the snapshot's signature is still cached, so as-of predictions are mostly
    rules-only.
- **Overrides.** The one-click correction and trainer answers are live only while their snapshot message is the
  newest counted message, compared by received time because Graph ids change on move. The next inbound message or
  the user's reply expires them.
  - The old one-click correction had the same staleness problem: an expired override still acted as a prior. That
    prior is gone; see §3.2.
  - A trainer answer about a snapshot that is no longer the newest is kept as truth but never becomes an override.
  - Answer 4 (Done) means "as of this message nothing is left", which includes "needed a reply then, handled outside
    email since". The window copy says so.
- **Migration.** A pre-snapshot answer is pinned to the message whose conversation prefix has the stored event
  signature, which is the newest message when it was saved, and is then re-keyed. If no prefix matches, it stays
  unpinned and is left out of scoring ("older answers not scored").
  - A pre-snapshot override stays live only while the event signature is unchanged. That is the same moment, so it
    expires with the next message.
- **Trainer UI.**
  - The conversation renders oldest first: older messages on one line each, the newest expanded, click to toggle.
  - Each line shows the sender, or "You → recipients" for the user's own messages, plus the date.
  - Bodies come through `MailModel.standaloneReader` and `ReaderBody`: the same fail-closed fetch, notices, offline
    rule and markings as the reader, with no mark-as-read.
  - Answer keys 1–4 / S / W run from a window-level key monitor. `ReaderBody` / `ProtectedReaderBody` take an
    `onKey` override (`// TRIAGE3-HOOK`), so keys inside a body never run mail triage on the main window.
  - The capture shield uses the strictest policy over the shown messages, including post-fetch policies.
- **Not verified.** The window hasn't been run: focus, body heights and the shield child window are untested by
  hand. `ReaderTools.shared.webView` (Find in Message) follows the last web view created, which may be the trainer's.

---

## Build status (Phase 2, knowledge v1, 2026-11-20)

**Built and self-tested on a synthetic corpus; not run on the owner's mailbox, UI not clicked through.**

- **Files.** `MailCore/StoryAnchors.swift` (anchors, pure), `MailCore/KnowledgeRoles.swift` (roles, lexicons,
  noisy-OR), `MailCore/Knowledge.swift` (per-account engine, read-time gate, sealed `kn_entity` / `kn_fact`),
  `MailCore/KnowledgeQuery.swift` (interpretation, resolution, interim matters, cards, hand-off, diagnostic),
  `CoreSelfTest/KnowledgeTests.swift`, app `KnowledgeViews.swift`. Shared edits are marked `// PEOPLE-HOOK`
  (MailStore tables / wipe, MailModel search + palette, SearchBoxState.reset, MailViews, the window scene, hover card,
  sender click).
- **Gate.** Facts keep only (message id, evidence kind, lexicon cue). Every read re-evaluates the source message:
  private, unknown-label and redacted rows contribute nothing (the person doesn't exist if that's all there is);
  metadata-only rows contribute addresses, domains and counts; text kinds (signature, subject, attachment names,
  invoice direction) need on-device content (user tier) or content on the AI tier. Signatures are read only from
  bodies already in the cache. Derived role facts are persisted only when every text source allows offline details.
- **Search hand-off.** One `from:` and one `to:` query per resolved address (exact blind filters, so old mail isn't
  lost to the newest-rows pool), the soft window (±25 %, at least 3 days) as bounds, leftover words as hints only for
  "what did I agree…" / details questions. Matter members come first.
- **Self-test results (synthetic):** time phrases 14/14; persona roles 8/8; "my lawyer" top-1 5/5 (EN/DE/FR/IT/"who
  is"), never opposing counsel (Cc only) or the firm's assistant; "Feb architect project" right matter top-1 5/5,
  unanchored and other-project threads excluded; protected-only person has no role (user and cloud tiers); private /
  unknown-label senders absent; relabel removes the fact; corrections both ways; per-account isolation.

**Interpretations.** On-device AI switched off by policy is treated as metadata-only (the triage precedent): roles
then come from directory titles and domains only. "My X" requires a direct exchange (I wrote to them in To, or they
wrote to me in To). The newsletter-only architect may carry an architect role but never ranks as "my" architect.
Sender click in the reader now opens the person page; its "Contact card" button reaches the directory card. The
summary on the card reuses `ask(_:retrieved:)` (gated, cited) and is UNVERIFIED (no real provider was called).

**Not done.** MCP `entity_lookup` / `matter_card`; the InboxBench knowledge set in `SearchBench` (the synthetic
corpus lives in `CoreSelfTest`); the on-device `QueryFrame` LLM fallback; `sameAs` / "Wrong company" UI (the core
`setSamePerson` exists); open promises are read through `PromiseSource` (arrived on main with the merge) but nothing implements it yet, so the pages show a placeholder; "save interim
matter as Story"; incremental refresh (a store change rebuilds the snapshot; the 50k-row latency target is unmeasured).
