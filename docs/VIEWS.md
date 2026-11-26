# Ways to look at calendar data — what we considered, what's built, what next

The question behind every view: **whose time, over what span, to answer which question?** An exec assistant
(e.g. one looking after six calendars) asks different questions from an individual contributor, so the app
offers several lenses on the same encrypted cache rather than one "correct" grid.

| View | Answers | Who it's for | Status |
|---|---|---|---|
| **Day / 3-day / Work week / Week, overlaid** | "What's on?" across all calendars on one column per day | Everyone; the default | ✅ built (⌘1/3/5/7) |
| **Side-by-side lanes, grouped by day** | "Who's busy when, today?" — one lane per calendar inside each day | Assistants managing several people | ✅ built (Overlap off, Group by Day) |
| **Side-by-side, grouped by calendar** | "What does Sam's week look like next to Mia's?" | Assistants, team leads | ✅ built (Group by Calendar) |
| **Schedule (rows = calendars, time →)** | "When can all of these people meet?" — plus an **Everyone free** row | Assistants, schedulers; Outlook's Scheduling Assistant, done as a first-class view | ✅ built (⌥⌘2) |
| **Search results (agenda list)** | "When is the board prep?" across ±months, grouped by day, upcoming first | Everyone | ✅ built (⌘F), in-memory only |
| **Alert banner** | "What's next, and how do I join it?" | Everyone | ✅ built |
| Agenda / "Up next" list | A scrolling list of the next N days; best on narrow windows, menubar extra, widget | Everyone; mobile-style | ◻ next — reuses SearchResultsView with a date filter |
| Month | Long-range overview, holidays, OOF | Everyone | ◻ next — needs density rules (dots vs chips) per theme |
| Free-slot finder | "Give me three 45-min slots this week that suit A, B and C" | Assistants | ◻ next — `ScheduleView.freeGaps` already does the maths; needs a picker and a "propose" action |
| Workload / heatmap (year or quarter) | "How overloaded is Sam? Where are the meeting-free days?" — hours booked per day as colour | Managers, assistants, self-reflection | ◻ later |
| Timeline across time zones | Rows per person with each person's local working hours shaded | Distributed teams | ◻ later — needs mailboxSettings.timeZone per calendar |
| Room / resource board | Rooms as rows (it's the schedule view with rooms) | Office managers | ◻ later — same view, `findRooms` + getSchedule |
| Menubar "next meeting" + Join | Glanceable without opening the app | Everyone | ✅ built |

## Two modes (sidebar switch)

| | **My Calendar** (personal) | **Assistant** |
|---|---|---|
| Primary objects | My calendars | The people I support (delegate/shared calendars) |
| Colleagues | **Teammates** by free/busy only (Graph `getSchedule`), no access to their calendar needed; status in sidebar ("Busy until 10:15"), rows in the schedule view, counted in *Everyone free* | Full calendars of each principal, side by side |
| Defaults on switch | Own calendars shown, overlaid | All calendars, lanes per person, principals first |
| Sidebar | My calendars, Teammates (+ add by email), shared/delegated below | **People I Support** with "Next 11:00 · …" and "2 meetings today", then my calendars |
| Alerts / menu bar | Own calendars | Own + delegated (assistant needs the boss's reminders) |

Free/busy is status and times only: subjects that some sharing levels expose are never decoded, and free/busy
is never written to disk.

**Menu bar** (both modes): the label shows only a countdown ("in 12 min") and a video icon, never a subject,
because it is visible over every app and in screen shares. The dropdown lists the rest of today with owner badges
and Join, and follows the lock-screen rules for labelled/private items.

## Design themes

Themes change **density, shape and fill**, not just colour, because "Outlook people" and "Google people"
read a calendar differently:

- **Glass** (default): frosted, colour-forward blocks over a soft gradient, Liquid Glass header and banner on
  macOS 26 (material fallback on 15). Meant to feel like Music/Photos rather than a 2012 Calendar.
- **Outlook**: dense (44 pt/hour), square corners, strong left colour bar, blue accent, stronger grid.
- **Google**: solid colour chips with white text, rounded, airy, blue accent.
- **Classic**: close to Apple Calendar.

## "Whose calendar is this?" — always answerable

- A stable colour per calendar: user override, else Graph colour if present *and unique*, else a palette slot
  keyed by calendar id. Graph often returns blank or duplicate colours; we never show two calendars in the
  same colour by accident.
- Owner initials badge on lane headers, schedule rows, search rows, the inspector, the alert banner and — when
  calendars overlap and more than one owner is visible — on every event block.
- Sidebar shows the **person** first for shared/delegated calendars, with the calendar name and access level
  ("Can edit" / "View only") underneath. Right-click: Colour, Meeting Alerts, Show Only This Calendar.

## Compliance rules every view obeys

- All views read from the same encrypted cache through `ContentPolicy`; no view inspects labels itself.
- `screenPolicy` merges everything that can be on screen (visible range + search results), so screen-capture
  blocking and watermarks cover search too.
- Search decrypts and matches in memory; there is no on-disk index (it would be a plaintext copy of subjects).
  Private items aren't findable by content.
- System notifications are built by `AlertComposer`: restricted items get "Confidential meeting in 5 min",
  with no subject, location or attendees on the lock screen. Only the event id goes into the notification payload.

## Recommendation for the next stage

1. **Free-slot finder** (pick people → propose three slots), reusing `FreeTime.gaps` over calendars *and* teammates.
2. Agenda + month views to complete the standard set.
3. Workload heatmap as the differentiator for assistants/managers.

## Honest status (2026-11-19)

- **What is real Liquid Glass:** the floating day header and the alert banner (macOS 26 `glassEffect`). Event
  blocks are a frosted material with tint and a specular edge, so the calendar colour stays readable (pure glass
  over a light grid renders grey). The sidebar and toolbar are stock macOS, which on 26 already gets the system glass.
- **Research basis:** this is a survey from product knowledge of Outlook, Google Calendar, Apple Calendar,
  Fantastical, Notion Calendar and Cron, plus Outlook's Scheduling Assistant. It is not a sourced market study.
- **Search** decrypts the sync window on the main thread on every keystroke. That's fine for a spike-sized cache;
  production should debounce it and run it off the main thread.
- **System notifications:** from the ad-hoc bundle `UNUserNotificationCenter.add` succeeds. Whether macOS shows
  them depends on the user allowing notifications (first-run prompt). The in-app banner always works.
- **Everyone free** treats all-day busy/OOF/tentative items as blocking the whole day (`FreeTime.gaps`, self-tested).
