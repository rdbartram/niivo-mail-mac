# Workspace suite

The suite turns niivo mail from a mail client into a place where work moves. It follows the owner's and designer's
wireframes ("Workspace suite — wireframes v0 … v0-6"): one desk, a rail of surfaces, one to three tiles, and on every
surface the same pattern of **one thing in focus, context beside it, and three numbered actions**.

## Concepts: Signal → Loop → When → Deep → Done

| Step | What it means | Surface |
|---|---|---|
| **Signal** | Something arrived that may need me (mail now; Teams later). Triage decides whether it needs me; Signal shows it one at a time with who it is and which loop it belongs to. | Signal (v0-3) |
| **Loop** | A named matter or project ("Proposal for next year"). Signals are assigned to loops; a loop gathers conversations, people, organisations, files and promises (later docs, sheets and tickets). | Loop chip, loop page; People (v0-6) lists loops per person |
| **When** | A loop's next piece of work gets a slot in the calendar ("Decide on notice period, 50 min, due Fri → Thu 10:10"). | When (v0-4) |
| **Deep** | A focused block on one loop: the work item, the loop's items in a drawer, "done when" criteria, a timer. | Deep (v0-5) |
| **Done** | The "done when" criteria are met; the loop closes or moves on. | Deep's "Done, next item"; loop state `done` |

Notes (v0) link into loops and people; the tile layouts (v0-2) arrange any of these surfaces one, two or three at a time.

## Status by wireframe surface

| Surface | Wireframe | Status | Where | Notes |
|---|---|---|---|---|
| **Loops** (engine) | — (all) | **Built** (step 1, 2026-11-21) | `MailCore/Loops.swift` (types, `LoopSource`), `MailCore/LoopsEngine.swift`, `CoreSelfTest/LoopsTests.swift` | Sealed per-account store, proposals, seeding, confirm / merge / split / rename / state / due / "not this loop". Self-tested on a synthetic DE/EN/FR/IT corpus; not run on a real mailbox. |
| **Signal** | v0-3 (MacBook 14) | **Built** (step 2), not clicked through | `CompliantCalendar/SignalViews.swift`; hooks in `MailShell`, `MailViews`, `TodayViews` | Now card, Who panel, Queue with an overview header and order picker, action strip 1 / 2 / 3, Today keys kept. Duo / iPhone layouts: not built (macOS only). |
| Loop chip + loop page | v0-3 (chip), v0-5 (items) | **Built** (minimal) | `CompliantCalendar/LoopsViews.swift`, window `loop` | Chip on the reader header and list rows for confirmed memberships; page: title (rename), state, people, conversations (with origin and "Not this loop"), promises, files, timeline. No merge / split UI yet (engine only). |
| People | v0-6 | Built (People builder, 2026-11-20) | `CompliantCalendar/PeopleSurfaceViews.swift`, `MailCore/PeopleSurface.swift`, `MailCore/PeopleNotes.swift`; window `knowledge`, ⌃⌘5 | Directory, person page, organisation and place panels, action strip. Loops now come from the real engine through `LoopSource.loops(involving:account:)` (suggested loops included, marked "suggested"); the app wires `PeopleSurfaceModel.loopSource` when the loops engine starts. |
| **When** | v0-4 (MacBook 14) | **Built** (2026-11-21), builds, not clicked through | `CalendarCore/FocusSlots.swift` (slot finder, focus block), `MailCore/WorkItems*.swift`, `CompliantCalendar/WorkModel.swift`, `WhenViews.swift`; window `when`, ⌃⌘6; Desk tile; "Schedule" on the loop page | Focus = next unplaced work item, day strip with busy time (grey, no subjects), focus blocks and proposed slots, 1 / 2 / 3 take a slot → confirm step → tentative block on my own calendar; L later, S shorter, N not mine. Duo / iPhone layouts and the "all placed" week view: not built. |
| **Deep** | v0-5 (MacBook 14) | **Built** (2026-11-21), builds, not clicked through | `CompliantCalendar/DeepViews.swift`, `WorkModel.swift`; window `deep`, ⌃⌘7; Desk tile | Item in focus, drawer (I) with work items + reference rows (loop page rows: conversations, promises, files), "done when" checklist, block timer (space), 1 Done → next, 2 Need more time → When, 3 Park; offers to close the loop when all items are done. No in-place doc / sheet / ticket editing ("edit here", "lives in Jira"): items are titles + criteria. |
| Notes | v0 | Not started | — | Links to loops and people; OneNote logging exists on the People page. |
| **Desk** | v0 (rail), v0-2 | **Built** (2026-11-21), builds, not clicked through | `CompliantCalendar/DeskViews.swift`, `MailCore/Desk.swift`, `CoreSelfTest/DeskTests.swift`; hooks in `CompliantCalendarApp` (RootView, Go / Desk menus), `MailShell`, `CalendarShell`, `MailViews` (`MailRootChrome`), `LoopsViews`, `KnowledgeViews` | Default niivo main window (`desk.enabled`, default on; brand theme only). Glass rail in rail order Signal, Loops, When, Deep, People, Notes, Mail, Calendar (⌘1…⌘8); top bar with layout picker and "Classic"; ⇧⌘D toggles; the classic headers carry a Desk button. Loop chips and person / matter opens land in the Desk's Loops / People tile while the Desk shows. |
| **Tiles** | v0-2 | **Built** (Mac layouts) | as Desk | One, two, one + two, one + three (four slots, as drawn); ⌘\ / ⇧⌘\ cycle; per-tile replace menu; click focuses a tile. Mounted: Mail (full niivo mail shell), Calendar (niivo calendar shell), Signal, Loops (loop page), People. When and Deep are mounted at their `DESK-HOOK`s; Notes is still a placeholder (`// DESK-HOOK: notes`) in `DeskSurfaceContent`. Duo / iPhone layouts: not built. People needs ~980 pt and the loop page 520 pt: in narrow tiles they are clipped. |

## Decisions

1. **A loop is not a Story.** Stories (StoryEngine) are the automatic, anchor-linked groups of the plan (§3.3, §5);
   loops are the user's named units of work. Loops reuse the same anchors and linking rules (§5.3) and are *seeded*
   from knowledge matters, but they are only ever *suggested* until the user confirms them. A later step may retire
   Stories in favour of loops; nothing in this step changes Stories.
2. **Never from similarity alone.** A proposal needs a shared anchor: `id` and `proj` link alone; `att` needs a shared
   non-owner person or organisation; `stem` needs that plus ≤ 21 days. Bulk / notification conversations link only by
   `id`; an `id` seen in more than 10 conversations is ignored. The owner's own organisation never counts as shared.
3. **One loop per conversation.** Assigning moves a conversation; "not this loop" stores a negative memory per
   (loop, conversation) that survives merges (moved to the survivor) and re-seeding.
4. **Seeding.** Knowledge matters of people with a direct exchange become suggested loops with *proposed*
   memberships (anchor kind + keyed evidence hash). An anchor that already seeded or belongs to any loop, in any
   state, is never seeded again, so rejected or archived suggestions stay gone. Seeding runs once per knowledge
   snapshot, detached.
5. **What is on disk.** One sealed table `loop_row` (account tag + type + HMAC keys, 1 KB buckets): loop ids, states,
   due dates, user titles, conversation ids, keyed anchor hashes. Never message ids (they change on move) and never
   anchor text. A derived (seeded) title is written only when every source message allows offline details; otherwise
   it lives in memory and the next seed pass restores it. Loops survive a header reset and go with a wipe.
6. **Labels.** Titles and items are resolved per tier at read time. Protected / redacted / private sources give
   metadata only (people, dates, counts): no anchor, no title, no subject on the loop page, no files. An AI tier sees a
   loop title only when every member conversation is text-visible for it.
7. **New-loop title.** Prefilled from the subject only when that message's text is visible *and* may be kept
   offline; otherwise the field starts empty, so pressing return never stores label-gated text as a user title.
8. **Signal reuses Today.** Same plan, same cards, same redaction. The current item *is* the selected message, so R /
   E / Z / S / D act on it unchanged. The queue is Needs you (with maybes) then FYI; the order picker offers ranked, by
   person, clients first, internal first, FYI first. After 1 / 2 / 3 the next item is selected.
9. **Client vs internal.** "Client" in the Who panel and the overview means an external sender (not one of the
   internal domains); the person's inferred role (lawyer, architect…) shows as its own chip.
10. **Waiting on.** For the People page, a loop's `waitingOn` comes from the newest member conversation's direction
    (mine last → them, theirs last → me); done / archived loops wait on nobody.
11. **Toggle.** Today's sidebar entry opens Signal; "List view" (in Signal) and "Signal" (in the list) switch between
    them (`mail.today.signal`, default on). Flow (⌘⇧F) still takes over when started.
12. **Cost.** Knowledge refresh and seeding run only when Signal loads an item or the loop page opens (detached);
    triage changes only re-read the loop rows for the chips (throttled to 5 s). Edits are serialised end to end.
13. **FYI in Signal.** FYI items aren't Today cards: in Signal, R replies, E marks the conversation done (state only),
    Z snoozes, S / D do nothing. Waiting and Promises due stay in the List view.
14. **Channel.** `SignalChannel` has `mail` and `teams`; only mail feeds Signal today.
15. **Desk.** The Desk is the main window's default layout for the niivo theme (`desk.enabled`, default on); the
    classic Mail / Calendar shells stay reachable (⇧⌘D, "Classic" in the top bar, the Desk button in the classic
    headers). Other themes keep the classic system shells. State: `DeskState` (`desk.state` =
    `layout|slot,slot,…|focus`), self-tested.
16. **One surface, one tile.** Every surface runs off a shared model, so `slots` is a permutation of all surfaces: the
    visible tiles are its prefix, and showing a hidden surface swaps it into the focused tile. Window-wide modifiers
    (`MailRootChrome`: mail sheets, toasts, key catchers, mail start; `CalendarSheets`) are applied once around the
    Desk, not per tile. With a Signal tile, the Mail tile shows the Today list instead of a second Signal; the Signal
    tile offers "Open Signal" (selects Today) when Today isn't selected.
17. **Shortcuts.** ⌘1…⌘8 pick surfaces while the Desk shows; the calendar's day counts keep ⌘1 / 3 / 5 / 7 in the
    classic shell only (the Desk's calendar tile has the day picker). ⌃⌘1 / ⌃⌘2 bring the Mail / Calendar tile forward.
    ⌘\ cycles layouts. Trade-off: in the Desk, day counts have no key.
18. **Section follows focus.** `app.section` follows the focused tile (Calendar → calendar; Mail, Signal, Loops,
    People → mail), because ⌘N, Find, Sync and the Mail menu branch on it.
19. **Capture.** The window guard in the Desk is the union over visible tiles: device trust policy, the calendar's
    label policy when the Calendar tile shows, and the People window's rule (mail screen policy or the selected
    person's protected sources) when the People tile shows.
20. **Glass.** Liquid Glass only on the control layer (rail, tile headers, action strips, floating bars, chips over
    content); content stays solid. Solid with Reduce Transparency / Increase Contrast; material before macOS 26; never
    tinted with the cyan fill. Details: `docs/NIIVO-THEME.md` §8.
21. **Fitting the shells into tiles.** The default is one tile (Mail): a full mail shell (236 pt mailboxes + 410 pt
    list + reader) doesn't fit half a 14-inch screen. Tiles narrower than 1000 pt hide the shells' own sidebars. Tiled
    shells drop their traffic-light inset and section tabs, and the posture banner shows once under the Desk's top
    bar. With a Signal tile and Today selected, the Mail tile shows the Today list without a reader (Signal's Now card
    is the reader, so there is one reader and one inline composer).
22. **Opening into the Desk.** Loop chips and person / matter opens *reveal* the Loops / People tile beside the
    focused one (`DeskState.reveal`), never over the tile clicked in; with one tile they open their window as before.
    A section change from elsewhere (notifications, mailto / .ics, menu bar, People actions) brings the Mail or
    Calendar tile forward, and a new composer brings the Mail tile forward when neither Mail nor Signal shows.

23. **Work items.** A loop holds work items (title, kind mail reply / doc / sheet / ticket / task / promise, minutes,
    due, "done when" checklist ≤ 8, state open / scheduled / inProgress / done, slot with event id). The loop's open
    promises and needs-reply conversations are *suggested* on the loop page (Add / Not this); nothing is stored until
    the user adds one. An item's source (promise id / conversation id) is never suggested again, nor a dismissed one;
    the exception is a *done* reply item: that conversation may be suggested again when it needs a reply again. Kind,
    estimate, due date and title are edited on When's focus card; a scheduled item whose block passed without work
    starting (missed) goes back to the front of When.
24. **What is on disk.** Sealed table `work_item` (account tag + type byte 1 item / 2 dismissed + HMAC key, HKDF
    "work-items-v1", 1 KB buckets): ids, loop id, kind, minutes, due, criteria, state, slots, source ids (never message
    ids) and the title only when the user typed it or every source may keep offline details (promise `persistText`;
    every text-visible message of the conversation `persistable`). Derived titles are re-resolved at read time, so a
    source that turned protected hides its title. Dismissals are keyed hashes. Survives `resetHeaders`, goes with `wipe`.
25. **Slots.** `SlotFinder.propose` (pure): working hours 08:30–17:00 Mon–Fri (`work.hours.start` / `.end` defaults),
    every meeting and focus block padded by 10 min, starts on 5-min marks, slots ending before the due day is over first,
    then mornings for work ≥ 45 min, then earliest; a long free gap also offers an afternoon start. Nothing free before
    due → "Nothing free before it's due" and later slots. Busy = own calendars only, FreeTime's rules (free / cancelled
    don't block, all-day busy blocks the day). Day windows use wall-clock `Calendar` arithmetic (DST-safe).
26. **Calendar write.** 1 / 2 / 3 only open a confirm card; Return ("Add to my calendar") is the one write:
    `PendingFocusBlock.confirm` → `SyncEngine.create` (outbox → Graph POST) on the owner's *own* default calendar
    (never a principal's, even in the assistant persona; never a group), `showAs: tentative`, no attendees, no Teams
    link, no body. Nobody is ever invited. The tenant's default meeting label and its stamp are applied exactly as for a
    new meeting in the event editor (and a mandatory-label block stops the write). Rescheduling a future block creates
    the new one and deletes the old one in the same confirm; the old id is resolved first (Exchange's id for a local
    one, else the own-calendar block at that time), only attendee-less events are ever deleted, and an old block that
    can't be removed is reported, not hidden. Local event ids are replaced by Exchange's after the flush.
27. **Subjects leave the label gate.** A calendar subject goes to Exchange and the calendar cache, so it is
    "Focus: <title>" only for a title the user typed; anything derived from mail gives "Focus block".
28. **Deep.** The block timer counts against the slot length (or the estimate); overrun is shown calmly ("12 min over")
    and counted. Done ticks nothing automatically; when every item of a loop is done Deep *offers* to close the loop.
    Need more time keeps the worked block and puts the item first in When; Park releases it until tomorrow.
29. **Shortcuts.** ⌃⌘6 When, ⌃⌘7 Deep (windows). Inside the surfaces bare keys: When 1 / 2 / 3, L, S, N, ↩, esc;
    Deep 1 / 2 / 3, space, I; ignored while a text field has the keyboard. Schedule, Deep, Reschedule, More time and
    ⌃⌘6 / ⌃⌘7 open the When / Deep *tile* while the Desk shows (`DeskModel.present`), else the window. Glass on keys,
    slot chips and the drawer toggle only (§20). Lock / wipe / account change drop the pending block and the timer.

## Diagnostics

`[Loops] open= confirmed= suggested= proposalsShown= accepted=` (counts only; `accepted` = assignments to the
proposal shown as best).

`[When] items= proposed= taken=` and `[Deep] started= done= overrun=` (counts only; `proposed` = slots shown, `taken` =
confirmed focus blocks, `overrun` = blocks finished past their length).
