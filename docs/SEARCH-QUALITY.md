# Search quality

The owner's verdict: "the AI search still sucks". This file holds the bench used to measure that and the numbers
before and after the fix.

## The cause, from reading the code

* **Ask / ⌥↩** (`AIAssistModel.localSearch`) went through `MailSync.search`, which calls `MailStore.search`. That
  search needs **every word** in the blind index (AND) and orders hits **newest first**, with no ranking. The LLM's
  parsed terms were joined and searched with the same AND. The hybrid `SearchEngine` (BM25 + vectors) served only
  SearchHub (⇧⌘F) and the MCP `search` tool.
* `SearchEngine` is AND as well. So "invoice from Fabrikam", "what did Anna send about the audit" and "last week's
  offer" could only match mail that literally contains *invoice*, *from*, *what*, *did*, *week*, …
* The index held only the **first 24 distinct preview words**. It held no body text, no attachment names and no
  parts of German compounds ("Serverumzug" was never "Umzug").
* The semantic side used `NLEmbedding` per language, each in its own space, so a German query never met English mail.
  Its cosine signal is weak, and recency outweighed the RRF rank gaps at the head of the list.

## Bench

`swift run -c release SearchBench [--bodies 0|50|100] [--only a,b] [--detail cfg]` (Sources/SearchBench). It is
**not** part of the gate.

* **Corpus (synthetic):** 348 messages, of which 48 are story messages and 300 are filler (newsletters, Teams
  notifications, tickets, another project, small talk, other vendors' invoices).
  * Mostly German, with English, French and Italian.
  * Swiss business vocabulary: Offerte, Rechnung, Revision, VR-Sitzung, MWST, Ferien.
  * Two people called Anna. Hard negatives: other vendors' Rechnungen, an office move, a "Phoenix" hotel.
  * Two **protected** rows (unknown label, fail-closed) whose content holds query words.
* **Previews and bodies:** previews are ≤ 200 characters. `--bodies N` simulates N % of messages having been opened,
  so the body and attachment names are cached, as a reader fetch would leave them.
* **Queries:** 50, with graded judgements (2 = target, 1 = related). They cover keyword, cross-language, paraphrase,
  people, time, attachment, phrase, typo, Umlaut/ss, abbreviation, body-only and prefix. **15 are held out.** They were
  written before any change, and their per-query results weren't looked at while tuning weights.
  * Caveat: the lexicon was written *after* the held-out queries by the same author and covers their vocabulary. Treat
    the held-out numbers as weak evidence, and the "vectors don't help" finding as limited to queries the lexicon
    covers.
* **Metrics:**
  * nDCG@10 with gain 2^g − 1.
  * MRR, using the first item with grade ≥ 1.
  * Recall@20.
  * Latency p50 / p95 over 3 rounds × 50 queries, on an in-memory store and a release build. Real query embedding is
    included.
* **Privacy:** any protected row in any result list is reported as `LEAK`.

### Configurations

| name | what |
|---|---|
| legacy | `MailStore.search`: the old Ask / ⌥↩ path and the main list search. AND, newest first. |
| hub | `SearchEngine` `.all` with Apple `NLEmbedding`: the old SearchHub / MCP path. |
| nat-noexp-nosem | natural mode, no lexicon expansion, no vectors |
| nat-nosem | natural mode, no vectors |
| **ask** | natural mode with Apple vectors and the default weights: the new Ask / ⌥↩ path |
| **ask-typed** | the same, with the last word as a prefix: the new SearchHub type-ahead |
| ask-ctx | natural mode with `NLContextualEmbedding` (multilingual, 512-d, mean-pooled, centred) |

## Results (bodies cached 0 %, macOS 27, M-series, 2026-11-20)

Baseline = the code before this change (frozen first run). The legacy and hub rows re-run on the new index are within ±0.005.

| config | nDCG@10 | MRR | R@20 | dev nDCG | holdout nDCG | p50 ms | p95 ms | privacy |
|---|---|---|---|---|---|---|---|---|
| legacy (baseline) | 0.336 | 0.360 | 0.311 | 0.337 | 0.333 | 0.2 | 1.5 | ok |
| hub (baseline) | 0.381 | 0.396 | 0.492 | 0.397 | 0.343 | 19.2 | 26.0 | ok |
| nat-noexp-nosem | 0.712 | 0.763 | 0.800 | 0.737 | 0.655 | 0.8 | 3.3 | ok |
| nat-nosem | 0.941 | 0.962 | 0.961 | 0.951 | 0.917 | 1.4 | 3.5 | ok |
| **ask** | **0.939** | **0.962** | **0.961** | 0.949 | 0.916 | 12.5 | 15.6 | ok |
| **ask-typed** | **0.929** | **0.952** | **0.961** | 0.935 | 0.916 | 12.4 | 15.5 | ok |
| ask-ctx | 0.941 | 0.962 | 0.961 | 0.951 | 0.917 | 12.1 | 14.4 | ok |

With **100 % of bodies cached**:

| config | nDCG@10 | MRR | R@20 | holdout nDCG |
|---|---|---|---|---|
| legacy | 0.356 | 0.380 | 0.331 | 0.333 |
| ask | 0.956 | 0.982 | 0.981 | 0.982 |
| ask-typed | 0.957 | 0.982 | 0.981 | 0.983 |

At 50 % the numbers equal 0 %. The deterministic 50 % subset doesn't include the messages whose bodies or attachment
names make the difference here.

A stubbed AI parse that adds off-target keywords ("update", "status", "information") through `SearchQuery.natural`
scores 0.939, the same as `ask`. AI-added words are optional concepts and can't lower coverage.

nDCG@10 per category, bodies at 0 %:

| category (n) | legacy | hub | ask | ask-typed |
|---|---|---|---|---|
| keyword (7) | 0.968 | 0.971 | 0.982 | 0.982 |
| crossLanguage (11) | 0.166 | 0.317 | 0.984 | 0.984 |
| paraphrase (5) | 0.000 | 0.087 | 0.976 | 0.976 |
| people (7) | 0.226 | 0.300 | 0.813 | 0.819 |
| time (3) | 0.000 | 0.000 | 1.000 | 1.000 |
| attachment (3) | 0.000 | 0.000 | 0.660 | 0.660 |
| phrase (2) | 1.000 | 1.000 | 1.000 | 1.000 |
| typo (3) | 0.000 | 0.108 | 0.975 | 0.975 |
| umlaut (4) | 0.653 | 0.653 | 0.948 | 0.903 |
| abbreviation (3) | 0.333 | 0.170 | 1.000 | 1.000 |
| body (1) | 0.000 | 0.000 | 1.000 | 0.631 |
| prefix (1) | 1.000 | 1.000 | 1.000 | 1.000 |

### What moved the numbers (each step measured)

1. **Relaxed matching** (`nat-noexp-nosem`) took nDCG from 0.38 to 0.71. Words are OR-ed into concept groups and
   scored with coverage-weighted BM25. Stopwords are dropped. Time, attachment and sender phrases become hints.
2. **Expansions** (`nat-nosem`) took it from 0.71 to 0.94:
   * DE/EN/FR/IT business lexicon groups (`SearchLexicon.groups`)
   * Umlaut ↔ digraph variants
   * German compound heads, matched on both the index and the query side
   * typo or truncation recovery: 3-char prefix candidates, then edit distance ≤ 1–2 or prefix-of
3. **Fusion fix and bundle** (`nat-nosem` 0.837 → 0.941, like for like). The first natural run used RRF plus
   recency, and recency at 0.3/(k+1) beat the rank gaps at the head of the list. The same step also brought:
   * normalised scores: keyword / max + semantic + hints + 0.1·recency
   * the Umlaut-at-start variant fix ("Aenderung")
   * synonym weight 0.6
   * prefix-of typo recovery
   * policy-based visibility (which fixed a leak in the first run, see Privacy)
4. **Body, all-preview and attachment-name indexing** (index v3) lifted the held-out set from 0.917 to 0.982 when
   bodies are cached.
5. **Semantic vectors don't help on this corpus.**
   * Apple `NLEmbedding` at weight 0.3 / floor 0.3 *cost* 0.026 nDCG.
   * At 0.1 over a 0.5 floor, with semantic-only hits allowed only when nothing matched a keyword, it is neutral
     (0.939 vs 0.941).
   * `NLContextualEmbedding` (multilingual, centred) is neutral as well (0.941). Raw mean-pooled cosines sit at about
     0.7 for everything, and after centring the gaps are small.
   * It is **not adopted**. Stories read the stored vectors (`storyCosine`), and switching spaces would shift them
     under the StoryEngine tuning for no measured gain. `ContextualSentenceEmbedder` stays in MailCore so the bench can
     re-measure it.

### Still weak

* **people (0.81):** "Peter Müller" also matches everything he wrote. The judgements list only three targets; filler
  mail from him counts as 0. `--detail ask` shows his filler mail on top, so this is judgement strictness rather than a
  bad ranking.
* **attachment (0.66):** headers carry only `hasAttachments`. Graph delta sync doesn't return attachment names, so
  "Lebenslauf PDF" finds nothing until the message has been opened once.

## What changed (code)

* `SearchEngine.Options.match` takes `.all` or `.natural`. `.all` stays the default and is unchanged, used by
  type-ahead tests, the MCP `search` tool and bulk plans.
  * `.natural` is in `SearchEngine+Natural.swift`. It uses the same filters, gate and visibility rules.
  * The pure logic is in `SearchUnderstanding.swift`: variants, lexicon, stopwords, time / sender / attachment hints,
    edit distance, body stripping, fusion, `SearchQuery.natural(raw:ai:)`.
* `MailStore.postings` returns one hash's postings (bounded, newest first). Expansions read a third as many.
* **Index v3** (`SearchIndexVersion.current = "3"`) adds:
  * every preview term (was the first 24)
  * compound heads
  * non-inline attachment names
  * up to 600 terms from the first 4,000 characters of a cached body (markup and quoted history stripped)

  All of these only when the persist policy allows offline details. A header-only delta re-reads the cached body, so
  its terms survive.
* **App:**
  * ⌥↩ NL search and the non-agent Ask retrieval use ranked natural search over the local store. Server-only hits
    are always fetched, with a quarter of the slots reserved for them. Bulk plans keep the AND `localSearch`.
  * The MCP / agent `search` tool (`GraphTools`), which the agent Ask path uses, defaults to `.natural`. It takes a new
    `match: "all"` argument for the strict mode. `total_is_capped` only uses the keyword-pool rule in `.all`.
  * SearchHub uses `.natural` while typing.
  * Marked `// SEARCHQ-HOOK` in `AIAssistModel.swift`, `SearchViews.swift`, `GraphTools.swift`, `ToolDefs.swift`,
    `MailStore.swift` and `Package.swift`.
* **LLM rewrite:** the existing `searchQuery(for:)` call is kept. It only ever sees the user's words. Its keywords
  (often translations), dates and attachment flag merge into the natural query, and its sender guess stays a scored
  word, not a filter. AI keywords are optional concepts (`SearchQuery.hintWords`). No mail content is sent for
  rewriting.

## Privacy

* The first natural run leaked one protected row: typo recovery verified against the decrypted subject. Fixed.
* A row whose details stay off disk matches on its sender only, also through typo recovery. Verification uses the
  persist policy, not the decrypted subject. The bench reports `privacy ok` for every config, and CoreSelfTest pins
  this.
* `.ai` callers:
  * A concept counts on a metadata item only if the matching word is visible (sender or unwithheld subject).
  * Semantic hits count only on `.full` items.
  * The excluded-item count is unchanged.
* Body terms are indexed only for rows whose label allows offline details, the same rule as the body LRU.

## Re-index / migration

* Opening a store from an older build starts the resumable `reindexStep`, because the version is "2" and current is
  "3". SearchHub already runs it in the background, 2,000 rows per step. Until it finishes, older rows match on their
  v2 tokens.
* Bodies already cached are picked up by the reindex.
* Vectors are untouched, so there is no re-embedding.
* The index grows: all preview terms instead of 24 per row, plus body terms for opened messages. The size was not
  measured. At 100k synthetic headers `CC_SEARCH_BENCH` wrote 263 MB.
* **Scale:** `CC_SEARCH_BENCH=1 CC_SEARCH_N=100000`, release build, with vectors not yet loaded.
  * Natural mode: typed p50 70 ms / p95 117 ms; submitted p50 64 ms / p95 104 ms.
  * `.all` keyword search: p95 80 ms.
  * The Apple query embedding adds about 23 ms on top, which puts typed SearchHub near the 150 ms target at 100k.
    500k was not measured.
  * If 500k turns out slower, keep SearchHub on `.all` while typing and use `.natural` on Enter.
* **Other readers of the token table:**
  * `SearchPages` topic pages (`.term`) and `project:t:…` filters now also match preview words past the 24th, body
    terms of opened mail and compound heads.
  * StoryEngine doesn't read tokens. CommGraph topic terms come from subjects, not from the token table.

## Main search box (SEARCHBOX, 2026-11-20)

The mail-list search box now runs `MailSearchBox` (MailCore/MailSearchBox.swift), not the strict newest-first
`MailSync.search(scope:)`.

* **Typing** (120 ms debounce): `.natural`, no query embedding (`semantic = false`), `strictPhrases = true`, the folder
  scope passed as `Options.folderId` so it filters before the limit. **↩**: the same plus the embedding, and Graph
  `$search` merged in. While typing, Graph is asked only when local hits are < 5, after a further 600 ms.
* **Operators are strict, free words rank.** New: `subject:` (exact blind token, then prefix of a subject word),
  `category:` (`c:` filter token), `older_than:` / `newer_than:`, Outlook-style `hasattachments:` / `isread:`.
  `"quoted phrase"` is strict in the box only (adjacency in subject / preview, else the cached body); Ask and
  SearchHub still only boost phrases. An operator's quoted value (`from:"Anna Meier"`) is no longer taken as a phrase.
* **Server hits:** only free words + phrases go to `$search` (the KQL operator mapping is unverified); every operator
  is re-applied locally on the sanitised hit, and a row whose details stay off disk is kept only if every free word is
  in its sender (`admitServerHit`), because Graph matches protected content server-side.
* **Postings join order:** when a filter token (from:, category:, subject: …) has fewer rows than the term, it drives
  the join (`postings`, CROSS JOIN). Same result set, fewer rows walked.
* **Latency, `CC_SEARCH_BENCH=1 CC_SEARCH_N=100000`, release, `MailSearchBox.local` itself** (mailbox scope, 120
  keystroke prefixes of the 40 bench queries, one mailbox; parallel builds were running on the Mac). In both runs the
  bench's own `.all` check "search p95 under 100 ms" failed at 139–140 ms (80 ms in the earlier run above); not
  re-measured on main, so whether that is load or a regression is UNVERIFIED (the check is outside the gate):
  * typed keystrokes p50 69.7 ms, **p95 118.0 ms** (first run, before the join-order change: p95 125.0 ms; both under the 150 ms target, so natural stays on while typing;
    `MailSearchBox.naturalWhileTyping = false` is the one-line strict-while-typing fallback);
  * with `is:unread after:90d` p95 58.1 ms; with `from:<address>` p95 10.9 ms (226.1 ms before the join-order change);
  * "This folder" scope p95 108.2 ms; ↩ (natural, no vectors loaded in the bench) p50 47.7 ms, p95 67.4 ms.
  * "All mailboxes" runs the engine once per mailbox in sequence: not measured.
  * Recall caveat: `is:unread`, `is:read`, `label:` and `to:name` are post-filters on the top `decryptPool` (400)
    candidates by score, so on large mailboxes they can miss matches (unchanged engine behaviour).
  * Quality bench after the shared parser / postings changes: ask-typed nDCG@10 0.929, ask 0.939 (unchanged).
  * Not measured: the Apple query embedding on ↩ (about 23 ms, see above) and the Graph round trip.
