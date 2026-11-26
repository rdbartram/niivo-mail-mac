# Next stage — "is this worth funding?" spike polish (started 2026-11-19)

Ryan's ask: schedule view; research other ways to view the data; a real design theme (modern macOS / glass,
Music-app feel) plus Outlook-like and Google-like options; always clear whose calendar is whose; search;
calendar colour changes; alerts; meeting links beyond Teams (Zoom, Google Meet, Webex, GoTo/"Citrix", …).

Status of Join (Teams): click arrives and hands off to Teams — log shows `join → msteams via Microsoft Teams.app`,
`join opened com.microsoft.teams2`. Whether new Teams then navigates to the meeting is **unconfirmed** (ask Ryan).

## Stages (commit + fixture screenshot after each)

1. [x] Fixtures: 6 calendars (incl. 2 delegated/shared people), Zoom/Meet/Webex/GoTo links in location/body.
2. [x] Theme tokens: `Theme` in environment, selection in AppModel. Themes: **Glass** (default, macOS 26 glass,
       material fallback), **Outlook** (dense, square, blue accent), **Google** (rounded chips, airy, pastel).
       Differ in density/shape, not only colour. Compile-check `glassEffect` under CLT first.
3. [x] Ownership + colour: palette fallback keyed by calendar id when hexColor blank/duplicate; user override
       (persisted); owner marker (initials avatar) on every block; owner shown in inspector header.
4. [x] Schedule view: rows = calendars, horizontal time axis, scaled to fit width (working hours window,
       no horizontal scroll), combined "everyone free" row. Read-only (no drag) in v1.
5. [x] Meeting providers: extract join URL in `toModel` from onlineMeeting.joinUrl → location → full body
       (body fetched only for extraction; only the URL is stored). Teams/Zoom native schemes when a handler
       exists, others https. Provider icon + name on blocks and inspector.
6. [x] Search (⌘F): decrypt + match in memory only, never a plaintext index; filter through ContentPolicy
       (redacted items not findable by subject).
7. [x] Alerts: UNUserNotificationCenter if it works from the ad-hoc bundle, else in-app banner. Text built
       from policy (labelled/private → "Confidential meeting in 5 min", no subject on lock screen).
8. [x] Research doc `docs/VIEWS.md`: views considered (week/day columns, lanes, schedule, agenda, month,
       free-slot finder, year heatmap…), what's built, recommendation.

## Compliance constraints (blocking)
- `screenPolicy` must merge whatever is on screen (schedule, search results, agenda), not just weekEvents.
- No plaintext search index; no subjects in notifications for restricted items.

# Next stage: full write path (noted 2026-11-19, Ryan)

Ensure it's possible to **move/drag, create, edit and delete** events and meetings, in own *and* delegated calendars.

## Today
- Drag to move within a day exists (`WeekView` DragGesture → `AppModel.move` → `SyncEngine.move`): optimistic
  local update, encrypted outbox (coalesced), PATCH with If-Match, 412 → server wins + conflict count. Self-tested
  against fixtures/Graph stub. **Not yet exercised against the real tenant** (all real-tenant runs were read-only).
- Missing: drag across days/calendars, resize, create, edit form, delete/cancel, recurrence, attendees.

## Plan
1. Outbox gains `create` and `delete` kinds (local temp id → server id remap after POST; delete = tombstone so
   delta can't resurrect it). Edit = existing coalesced `update`.
2. Grid: drag across days and lanes (lane change = move to another calendar = create + delete, confirm first),
   resize from the bottom edge, drag on empty space to create, ⌫ to delete, double-click opens the editor.
3. Editor (inspector in edit mode): subject, time, all-day, location, online meeting toggle (Teams via
   `isOnlineMeeting`/`onlineMeetingProvider`), attendees with free/busy, show-as, private flag, body.
4. Meetings vs appointments: attendees mean Exchange sends invites/updates/cancellations. A delete by the organiser
   is a cancel with a message (`POST /events/{id}/cancel`); an attendee declines instead (`/decline`). Delegates
   send on behalf of the principal, so the UI must say "Sending as Sam Rivera".
5. Recurrence: edit this occurrence vs the series (occurrence PATCH vs seriesMaster PATCH); delete one vs all.
6. Compliance on write:
   - Editing a labelled item never downgrades its label. Label is preserved; changing it needs the MIP SDK
     (justification for downgrade) → read-only label picker in the spike.
   - Mandatory-labelling policy: new meeting needs a label before save, once the policy is readable.
   - Protected (encrypted) body: edits limited to time/location until the MIP Protection SDK can re-encrypt.
   - Private items on a delegate calendar: delegate can't see them, so they can't be edited.
7. Permissions already granted: `Calendars.ReadWrite.Shared` covers own + shared/delegated writes. Delegate
   *Editor* rights on the mailbox are needed in Exchange (canEdit already gates the UI).
8. Real-tenant test on a **dedicated test calendar** ("Spike test") in the owner's mailbox, with attendee tests only
   to a second test account, so no real invites go out. Needs Ryan's go-ahead before the first write.

## Write path: status 2026-11-19
- [x] Core: create/edit/delete/cancel/decline through the encrypted outbox; sync protects pending local intent;
      14 self-tests (CoreSelfTest "Write path").
- [x] UI: editor sheet, remove sheet, drag across days and lanes, resize, drag/double-click to create, ⌘N/⌘E/⌘⌫.
- [ ] UI gestures verified by hand. Automation stopped working mid-session (macOS screen-recording/accessibility
      permission for the terminal lapsed), so drag/resize/create are compiled and wired but not yet clicked through.
- [ ] Real tenant: `LiveWriteProbe` (creates "[Spike test]" items in the default calendar, no attendees, cleans up).
- [ ] Recurrence (this occurrence vs series), attendee free/busy in the editor, delegate send-on-behalf test.

### Real-tenant results (LiveWriteProbe, 2026-11-19, the owner's own default calendar, no attendees; all items cleaned up)
13/13 after two fixes. Verified: POST/PATCH round-trip (UTC), stale If-Match on PATCH → 412, Teams link generated
from `isOnlineMeeting`, all-day with IANA zone, private flag, 404-tolerant delete, repeating create → series master,
series-master PATCH and DELETE.
Findings fixed:
1. **Exchange ignores If-Match on DELETE** (stale key accepted). `GraphCalendarService.remove` now GETs the changeKey
   and refuses on mismatch (small race window remains).
2. **changeKey changes shortly after create** (calendar assistant). Flush re-reads the created item. Async bumps
   later can still make a fast follow-up edit 412 → server wins; production should rebase benign conflicts.
- [x] Recurrence: this occurrence vs all (series-master PATCH, time shift same day only), delete/cancel series,
      new repeating events (daily/weekdays/weekly/monthly, no end). Series edits need a connection.
- [x] Attendee free/busy strip in the editor (getSchedule, memory only).
- [ ] Delegate send-on-behalf against a real principal; gestures clicked through by hand.

# Mail + BYOD trust + MCP (2026-11-19) — status
Plan: docs/MAIL-PLAN.md · Research: docs/MAIL-RESEARCH.md · MCP: docs/MCP.md
- [x] MailCore: encrypted store with keyset paging and a blind-index search (no plaintext on disk). Windowed sync
      (cache window from 30 days to everything), backfill, at most 4 requests per mailbox plus Retry-After.
      Send-as / on-behalf, undo send, client-side send-later, server rules (external forward blocked), OOF,
      AI access policy. 135 checks.
      Bench (500k headers, re-run 19 Nov): first page 0.6 ms, 2-term search 17.7 ms p50, 2.4 KB/header.
- [x] TrustCore: policy MDM > tenant-signed > BYOD defaults (stricter wins); posture checks; tenant-driven wipe
      (disabled / deleted / unassigned / wipe group / offline deadline) with a misconfiguration guard and a
      two-strike rule; a password reset only locks; app lock; sealed audit log. 147 checks.
- [x] OfficeMCP: 12 tools, draft-only, label + trust gate, untrusted-content wrapping, audit. 80 end-to-end
      checks; live handshake verified.
- [x] Mail UI: compiles; smoke-launched on fixtures into Mail (stays alive, main thread idle, no stderr).
      **Never clicked through.**
- [ ] Before any real sign-in:
  - CP1/CAE is off until claims challenges are handled.
  - Draft autosave creates a new server draft each time (needs MailDraft.id + PATCH).
  - Undo after a Graph move needs an id remap.
- [ ] Waiting on Ryan:
  - mail consent on the app registration (Mail.ReadWrite(.Shared), Mail.Send(.Shared), MailboxSettings.ReadWrite);
  - a real-mailbox probe (go-ahead needed before any send);
  - a report-only CA test of the BYOD allowlist variant (MAIL-PLAN "move2modern part 2");
  - spikes: label on send, 0x3FEF deferred send, MIP SDK without Xcode, reading encrypted mail via Graph.
