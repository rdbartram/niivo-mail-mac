# What is a mail client for? A rethink (approved 2026-11-20: "build it")

## 1. What people actually use Outlook for
Mail isn't really the job. People open Outlook to do five things:

1. **Know what needs me.** Find out what's waiting on me, by when, and what I can safely ignore.
2. **Move things forward.** Answer, decide, delegate or schedule. A reply is a step in a piece of work, not an end in itself.
3. **Keep promises.** Track what I said I'd do and what others owe me.
4. **Remember context.** Who is this, what did we agree, where is that file, what happened in February with the architect.
5. **Coordinate time.** Meetings come out of mail and create more mail.

Outlook and Gmail are built around the *message*: a list sorted by time, one item at a time, with folders and rules for the user to maintain. The work, the commitments, the people and the matters exist only in the user's head. That's why inbox zero feels like housekeeping rather than progress.

## 2. What niivo should optimise for
- **Time to clarity.** Every morning, under a minute to know what needs me.
- **Effort per decision.** One gesture to answer, defer, delegate or drop. The AI drafts, I approve.
- **Nothing dropped.** Promises and waiting-on are tracked without me filing anything.
- **Calm.** Nothing alerts me unless I'm the one who must act. No badge counts that turn into guilt counters.
- **Trust.** Every suggestion shows why, sensitivity labels are respected everywhere, everything runs locally, and I can always correct it.

## 3. The fundamental shift: from messages to work
| Today (message-centric) | niivo (work-centric) |
|---|---|
| Inbox = every message by time | **Today** = the conversations where I'm the one who acts, ranked by who, what's asked and deadline |
| Folders and rules I maintain | **Matters** (projects/cases) form by themselves from anchors; people and organisations are first-class |
| Read → think → type a reply | **Decide** → the AI drafts in my voice → I tweak → send |
| Flags I forget | **Promises ledger**: "I'll send it Friday" becomes a commitment with a nudge; "they owe me" becomes Waiting |
| Search by keyword | **Ask**: "mails from my lawyer", "the Feb architect project", with cited answers |
| Meetings separate from mail | A thread that needs a meeting shows a "Find a time" proposal inline; meeting notes link back to the matter |

## 4. The core experience (sketch)
- **Today (home, replaces the Inbox as the default view)**
  - **Needs you (5–15):** each card has the ask in one line, who it's from, why it matters, and 2–3 one-key actions: Reply with draft, Schedule, Delegate, Done.
  - **Waiting on others:** follow-up drafts appear at the right moment.
  - **Your promises due:** things you said you'd do.
  - **FYI digest:** collapsed, so you can skim it at the end of the day.
  - **Everything else** is one click away (the classic list is still there).
- **Flow mode** works through "Needs you" one at a time, full screen: read → decide → next. Think of it as Superhuman's speed with the AI doing the typing.
- **People and matters.** Click any person or project for a timeline of threads, files, meetings, open promises and the voice notes. This is the local Work IQ.
- **Ask bar** (⌘K). One box for commands, search and questions, with answers that cite the mails they came from.
- **Batching.** The end-of-day digest and newsletters are kept out of Today, and notifications only fire for Needs-you items from VIP people.

## 5. Why the intelligence layer is the product, and what that requires
The redesign stands or falls on "Needs you" being right. That means:
- **Ground truth:** your Train Triage sessions, and every one-click correction.
- **Commitment extraction:** asks, promises and deadlines from sent and received text, under the label gates.
- **Entity layer:** people, roles, organisations and matters, with sources (Phase 2 of the plan).
- **A visible accuracy target** before Today becomes the default: needs-reply precision ≥ 0.85 on your own labelled mail.

## 6. Proposed sequence
1. **Now:** train triage (15 min), read the scores, and fix rules until precision ≥ 0.85.
2. **Today view beta:** behind a toggle, built on the conversation state (Needs you / Waiting / FYI), with one-key actions.
3. **Promises ledger:** from your sent mail ("I'll…", "bis Freitag") and from asks to you.
4. **People/matter pages + Ask** (plan Phase 2).
5. **Flow mode and digest notifications.**
6. **Today becomes the default** once the accuracy target holds for 2 weeks.

## 7. Questions for Ryan
- Should **Today** replace the inbox as home, or sit beside it?
- Is it acceptable to hold back notifications for anything that isn't Needs-you?
- Is the promises ledger valuable to you, and should it sync to To Do / Planner?
- Do you want Flow mode as keyboard-first full-screen, or inside the normal window?

## Build status (2026-11-20)
- **Built:** §4 Today as a virtual folder **beside** the Inbox (owner's answer to Q1; "Open Today at launch" is an opt-in setting), Needs you / Waiting on others / Promises due (placeholder over `PromiseSource`) / FYI digest, one-key actions R/S/D/E/Z, Flow mode inside the normal window (⌘⇧F, J/K, esc), calm notifications ("Notify only for Needs you": Needs you at medium confidence or better, or VIPs). See BACKLOG §11.
- **Interpretations:** S always opens Reply with meeting (its editor has Find a time; no per-thread proposal yet). Maybes fill only the slots the confident cards leave under the cap of 15. FYI digest = FYI conversations from the last 24 hours. E marks the conversation done without teaching the sender prior.
- **Promises ledger (§6 step 3) built:** rule extraction (DE/EN/FR/IT) from sent mail ("I'll send it Friday") and direct received requests with a deadline ("owed by you"), due dates resolved against the sent time (relative words, weekdays, Swiss/European dates, month names); text read only where the on-device gate gives `.content`; sealed per-account `promise_item` table (text on disk only where offline details are allowed); auto-done on a later send with an attachment or "attached / anbei / ci-joint / in allegato"; Promises smart folder (Done / Snooze / Open / Dismiss, overdue red), reader line, morning toast, `promises_open` MCP tool, optional on-device AI refine of uncertain candidates; feeds Today's "Promises due" via `PromiseSource`. See BACKLOG §12.
- **Not yet:** people/matter pages + Ask, end-of-day digest notification, the accuracy gate before Today becomes the default.
