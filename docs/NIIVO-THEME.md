# niivo theme for niivo mail

The niivo theme is the default look of the app. The other themes (Glass, Outlook, Google, Classic) are still in the
Theme menu. Values come from the niivo brand guidelines; the `file:line` references below point into those
guidelines' source files, which are not part of this repository.

## 0. Sources and precedence

| Source | What it gave | Status |
|---|---|---|
| niivo brand guidelines: style rules | Paper-first, one cyan accent, Instrument Sans 400, JetBrains Mono caps labels, radius 0; palette, the ıı mark geometry, faces, devices, wordmark and the "never" list. | **Wins** where sources disagree. Its film sizes (measured at 1920 px) are **not** used for UI. |
| niivo brand guidelines: UI tokens (`form-lab.html`, `niivo-ci-study.md`) | Shared neutrals and the grey ladder, UI type vars, the 8-step rhythm, radius and button paddings, surface scopes, and the niivo UI token block (light + dark). | Primary for UI. |
| Parent brand type scale and spacing (`typography.css`, `spacing.css`) | The family's UI type scale and spacing. niivo inherits its structure (type, radius 0, mono chrome, plates…) and flips the colour. | Used for the type scale and paddings. |
| Bundled fonts | `instrument-sans-latin.woff2`, `jetbrains-mono-latin.woff2` (local copies of the Google Fonts faces, OFL). | Bundled (see §3). |
| Earlier niivo website tokens (`globals.css`) | Inter, neutral oklch greys, `--radius: 0.5rem`, a mono wordmark. | **Superseded** by the brand guidelines. Only `--destructive` is used, because the guidelines have no error colour. |

## 1. Tokens

### 1.1 Colour

The app's light appearance is the brand's **paper** surface. Its dark appearance is the brand's **carbon** surface.
The brand is paper-first, and `.dark` exists "only for openers and dividers" (`form-lab.html:7058-7059`), so a full
dark UI is an app extension. It is mapped token for token from the carbon surface and the token block's `.dark` rule
(`form-lab.html:7076-7079`, `niivo-ci-study.md:55`), with nothing invented.

| Token (Swift `NV.*`) | Light (paper) | Dark (carbon) | Source |
|---|---|---|---|
| `ground` (window, sidebar, list) | `#F2F1EF` paper | `#0C0C0C` carbon | `form-lab.html:7061`, `:7076`; `niivo-ci-study.md:40` |
| `card` (reader, composer body, palette) | `#FFFFFF` | `#111111` | `form-lab.html:7063`, `:7077`; `:61-62` (`--raised`) |
| `soft` (hover, quiet fills) | `#E9E8E4` | `#161614` | `form-lab.html:61-62` (`--soft`) |
| `ink` (text, strokes, the ıı) | `#111111` | `#F2F1EF` | `form-lab.html:7062`, `:7076`; `niivo-ci-study.md:41` |
| `muted` (secondary text, labels) | `#6E6E6A` gray-500 | `#8A8A86` gray-400 | `form-lab.html:7068`, `:7079`; `:18` |
| `guide` (rails, inactive glyphs) | `#9D9C9B` | `#6D6C6B` | `niivo-ci-study.md:42`, `:55` |
| `hair` (1 px dividers) | `#D8D7D3` gray-200 | `#2A2A28` gray-800 | `niivo-ci-study.md:48`; `form-lab.html:61-62` (`--line`) |
| `hair2` (control borders) | `#C9C8C4` gray-250 | `#3A3A38` gray-700 | `form-lab.html:7070` (`--border`), `:61-62` (`--line-2`) |
| `accentInk` (accent text and strokes) | `#006E88` signal-deep | `#00D0FF` | `form-lab.html:7069`, `:7079`; `niivo-ci-study.md:45`, `:62` |
| `accentFill` (the one solid: cursor, selection bar) | `#00D0FF` | `#00D0FF` | `form-lab.html:23`, `:7064`; `niivo-ci-study.md:47` |
| `accentSoft` (selected row face) | `#CEECF1` | `#0A272E` | `niivo-ci-study.md:46`, `:55` |
| `onAccent` (text on a cyan fill) | `#0C0C0C` | `#0C0C0C` | `form-lab.html:7065` |
| `danger` (unknown label, header marking, errors) | `#E7000B` = `oklch(.577 .245 27.3)` | `#FF6467` = `oklch(.704 .191 22.2)` | `globals.css:20`, `:59` (the CI has none) |
| `warning` (external recipients, restricted mode) | `systemOrange` | `systemOrange` | none in any source: system colour |

Colour laws applied (`niivo-ci-study.md:60-64`):
- **One cyan element per view.** In the mail list that element is the selected row's bar, and on the lock screen it is the cursor. Unread rows get an ink cut `ı`, not a cyan dot.
- **On paper, cyan is never a line or text.** Accent text, the control tint and focus rings take `#006E88`. Only fills are `#00D0FF`.
- No gradients and no shadows (`:338-339`). The one exception is the toast, which floats like a window.

### 1.2 Type

| Role | Face | Size (pt) | Weight / tracking | Source |
|---|---|---|---|---|
| Human text: names, subjects, body, headlines | Instrument Sans | see scale | 400; tracking −0.02 em on titles | `niivo-ci-study.md:184-186`; `typography.css:5-8` |
| Chrome: labels, counters, times, buttons, tabs, shortcuts | JetBrains Mono, ALL CAPS | 10.5 / 9.5 | 400–500; tracking .10 em / .16 em | `niivo-ci-study.md:187`; `form-lab.html:27-28`; `typography.css:15-18` |

The UI scale comes from the family's web scale (`typography.css:9-16`), multiplied by about 0.8 to suit macOS point
density (a macOS body is 13 pt, while a web body is 16–17 px):

| Swift `NV.Size` | Web token | Web px | App pt | Used for |
|---|---|---|---|---|
| `display` | `--text-display` | 44 | 34 | lock-screen headline |
| `title` | `--text-title` | 30 | 22 | reader subject |
| `bodyLg` | `--text-body-lg` | 21 | 16 | composer subject, palette query |
| `body` | `--text-body` | 17 | 13 | sender, rows, menus |
| `bodySm` | `--text-body-sm` | 15 | 12 | previews, secondary lines |
| `label` | `--label-size` | 13 | 10.5 | mono caps labels |
| `labelSm` | `--label-size-sm` | 11 | 9.5 | mono caps eyebrows |

"Never bold" (`niivo-ci-study.md:185`, `:345`) applies to headlines and the wordmark, which stay at 400. **Deviation:**
an unread row's sender and subject use Instrument Sans **500** (Medium). A mail list needs a weight signal for unread,
and 500 is not bold.

### 1.3 Shape, spacing, borders

| Token | Value | Source |
|---|---|---|
| Radius | **0** everywhere: rows, chips, banners, buttons, fields, sheets' inner panels | `form-lab.html:32`, `:7074` ("nothing is round"); `spacing.css:7` |
| (alternative read) | 4 px for clickable controls only | `niivo-ci-study.md:23`. Not used: the UI token block says 0, and squared controls read as niivo. |
| Hairline | 1 px | `form-lab.html:32`; `spacing.css:8` |
| Rhythm | steps of 8 (8 · 16 · 24 · 32 · 48 · 64) | `form-lab.html:31`; `spacing.css:3-4` |
| Button padding | 9 × 20 (regular), 7 × 16 (small) | `form-lab.html:33`; `spacing.css:10-12` |
| Input padding | 9 × 14 | `form-lab.html:33` |
| Shadow | none, except a big soft drop on a floating window (`0 30px 70px rgba(0,0,0,.55)`) | `form-lab.html:34`; `niivo-ci-study.md:339` |
| Boxes | brackets, not full boxes, around content: the **focus frame** (four corner brackets) | `niivo-ci-study.md:214`, `:338` |
| Primary / secondary button | `ALLOW` = ink fill with paper text; `DENY` = ghost with a 2 px ink border; squared, mono caps | `niivo-ci-study.md:222` |
| Section label / index | `[ 01 — POSTFACH ]`, `[01]` (index in deep accent) | `niivo-ci-study.md:215`; `STUDIO.md` (CI V3.0 summary) |
| Bullet | a single cut `ı` | `niivo-ci-study.md:220` |
| Motion | no bounce or elastic; UI fades ≤ 200 ms; cursor blink on a 1.06 s step, on for 0–55 % | `niivo-ci-study.md:373`; `niivo-kit/lib/core.js:31`, `:68` |

### 1.4 Iconography: niivo glyphs and the app icon

This replaces the earlier "keep SF Symbols" stance. Toolbar and row actions use `NGlyph` (`NiivoGlyphs.swift`).
`NIconButton` maps SF Symbol names to glyphs automatically when the niivo theme is on (`NGlyphKind(sf:)`).
`NGlyphKind.sfFallback` keeps the SF Symbol for the non-brand themes.

- **Grid and line:** 24 units, a 1.5-unit stroke (the kit's accent stroke, `niivo-ci-study.md` §2), square caps and
  mitred joins. `weight` is in grid units.
- **Nothing is round** (`form-lab.html:7074`): lenses, clock faces and heads are cut-corner polygons.
- **Lean only where the brand leans:** `ai` is the ıı and `syncing` carries a cut. Everything else is upright.
- **No sparkles, no chat bubbles, no robots for AI.** `briefing` uses the focus-frame brackets.
- **Colour:** glyphs are ink or muted. At most one glyph per view takes `accentInk`.
- **App icon** (`IconRender`, from the form-lab `icon` rules and the ICON engine): the ıı only, never the cursor, never animated.
  It is signal #00D0FF on carbon #0C0C0C, one ink including the shadow.
  The squircle is Apple's 824/1024 continuous mask ("Only OS app icons follow the platform mask", `form-lab.html:367`).
- **Icon sizes:** at 96 pt and up the icon gets the cut-noise shadow, 74 units down, with no blur. Below 32 pt the ıı is solid.
- **Icon variants:** dark is paper on carbon. Light is ink on paper with a 1 px #E1E0DC edge.
- **Menu bar:** the solid ıı as an 18 pt template image. Alerts use the icon art at 128 pt.
- **Build:** `CompliantCalendar --render-icon build/icon` writes the iconset, `AppIcon.icns` and previews.
  `scripts/bundle.sh` embeds `build/icon/AppIcon.icns` and sets `CFBundleIconFile`.

## 2. How the tokens map to the app

Code: `Sources/CompliantCalendar/NiivoTheme.swift` has the tokens (`NV`), fonts (`NiivoFonts`), the per-theme resolved
look (`Skin`, read from `\.skin`), and the brand components: `NiivoMark`, `NiivoWordmark`, `NiivoCursor`, `NiivoCut`,
`MonoLabel`, `FocusFrame`, `BrandEmptyState`, `NVButtonStyle` / `.nvButton(_:_:)`, `NVTabBar`.
`Theme.niivo` (`Theme.swift`) is first in `Theme.all` and is the default. `Skin(theme:)` maps the other four themes back
to system values, so one code path styles every theme and their old look is kept.

| Surface | niivo treatment |
|---|---|
| Window / sidebar / list | `ground` (paper / carbon) behind everything; the sidebar list gets a hidden scroll background on `ground`. The reader and composer body use `card`. |
| Lock screen (`TrustViews.swift`, `NiivoGate`) | Words sit in a left column at 6.7 % inset (`niivo-ci-study.md:203-206`). The wordmark is 104 pt with the blinking cyan cursor, the only cyan on screen. The headline is "niivo mail is locked." in 34 pt Instrument Sans 400, ending in a full stop. The `ALLOW`-style primary button is ink-filled mono caps. Bracketed mono chrome (`[ NIIVO MAIL ]`, `[ 01 — LOCKED ]`) runs top and bottom, with the `NIIVO.AI` byline. The outline ıı is drawn large in `hair2` and bleeds off the right and bottom edges. The blocked and wiped states use the same layout in danger red, with cut bullets. |
| Sidebar | Mailbox headers are mono caps with tracking; the mailbox badges are squared. Folder icons are SF Symbols at light weight in `muted`. The footer has the wordmark (no blink), `BYOD` / `MANAGED` and Lock. |
| Message rows | Flat and full-bleed with a 1 pt `hair` divider, radius 0. Unread is an ink cut `ı` plus Instrument Sans 500. The selected row gets an `accentSoft` face and a 3 pt `#00D0FF` bar, the one cyan element in the list. Times are mono caps. |
| Split-inbox tabs | `NVTabBar`: mono caps tabs with a 2 pt ink underline on the selected one. Counts are in deep accent. Each tab is a button with the selected trait; ←/→ move between tabs. It shrinks to 9.5 pt and then scrolls when the column is narrow. |
| Reader header | Subject in 22 pt Instrument Sans 400 at −0.02 em. Mono caps date and To/Cc labels. Squared attachment chips. |
| Toolbar | Native toolbar and SF Symbols, kept for macOS behaviour. The sync badge is mono caps, and FIXTURES is an ink-outlined chip. |
| Empty states | `BrandEmptyState`: a focus frame with brackets, a bracketed mono eyebrow, a sentence ending in a full stop, and a mono hint. |
| Notices (encrypted, unknown, private) | A focus frame with brackets instead of a grey rounded box. |
| Composer | `[ NEW MESSAGE ]` header with the cursor. Mono caps field labels. Squared recipient tokens (external ones are orange-outlined). Subject in 18 pt Instrument Sans. Body on `card` with a `hair2` border. Send is the ink primary button. Warnings get a 3 pt leading bar. |
| ⌘K palette | `⌘K` mono prefix and a 16 pt query. Rows use Instrument Sans with mono caps hints. The selected row is `accentSoft` with a 3 pt cyan bar and `→`. |
| Cheat sheet | `[ ⌘/ — SHORTCUTS ]` eyebrow and a headline. Groups are indexed `01 02 …` in deep accent over a hairline. Keycaps are squared with an outline. |
| Settings | Light pass: `ground` background, a wordmark plus `[ SETTINGS ]` footer, and an ink `DONE` button. The tab content stays native `Form`. |
| Calendar | Light pass: squared cyan today chip with carbon text, mono caps weekdays, Instrument Sans event titles, mono event times, radius 0 blocks with a 3 pt leading bar. The inspector reuses the restyled label banner, markings, notices and controls summary. |
| Toasts | `card` with a `hair2` border, plus the one shadow the CI allows (a floating window). |
| Message body (WKWebView) | Unchanged: the sender's HTML on white. Process-registered fonts don't reach the WebContent process. |

### Compliance markings: before → after (niivo); never subtler

| Marking | Before (all themes) | niivo |
|---|---|---|
| Label banner | label colour fill 0.14, radius 8, name callout **semibold** | same fill 0.14 and **semibold** name (14 pt), **plus** 4 pt leading bar in label colour, 1 pt border at 0.55, mono `SENSITIVITY` eyebrow in label colour |
| Unknown label banner | red fill 0.10, radius 8, "Unknown label — restricted" callout semibold (ink) | danger fill **0.12**, **1.5 pt danger border**, 4 pt danger bar, `RESTRICTED` bold mono eyebrow, text semibold **in danger** |
| Row chip | caption2 (10 pt) semibold, fill 0.14, capsule | mono **10 pt medium**, fill 0.14, **plus 1 pt border** in label colour |
| Row "Unknown label" | caption2 semibold red, fill 0.10 | mono 10 pt **bold**, fill **0.12**, **1 pt danger border** |
| Header marking (reader, inspector) | caption (10 pt) bold, tracking 1, red, fill 0.08 | mono **11 pt** bold, tracking 1.76, danger, fill **0.10**, **1 pt danger border** |
| Header marking (composer) | caption bold red text, no box | the same boxed marking as the reader (louder) |
| Footer marking | caption2 (10 pt) secondary | mono **10.5 pt medium** muted, over a hairline |
| Watermark | 15 pt bold, red 0.07, −30° tile | 15 pt **JetBrains Mono bold**, danger 0.07 (**0.10** in Dark Mode), same tile |
| Posture banner | caption, orange/red fill 0.12 | same fill, plus a 3 pt leading bar and a mono `RESTRICTED` / `BLOCKED` tag |

Tenant marking text is always shown verbatim; it is never uppercased or rewritten. Red stays red even though the CI
says "never cyan and red on one surface" (`niivo-ci-study.md:64`): compliance wins over the brand law. The other four
themes keep exactly their previous marking styles.

### Default theme

`Theme.niivo` is the fallback when no theme is saved. On first launch after this change, `AppModel.initialTheme()`
**moves a previously saved theme to niivo once** (flag `themeNiivoDefault`). Any choice made after that is kept.

## 3. Fonts

Both faces are bundled from the brand guidelines' font folder, latin subset only, because the latin-ext files carry the
same PostScript names. They are SwiftPM resources of the `CompliantCalendar` target, registered at launch with
`CTFontManagerRegisterFontsForURL(.process)`. CoreText reads the variable woff2 directly. A spike on this machine
resolved `InstrumentSans-Regular` (400 / Medium / SemiBold / Bold instances) and `JetBrainsMono-Regular` through
`NSFont(name:)`.

Licence: **SIL Open Font License 1.1**, which allows bundling and embedding. The fonts' own name tables say so:

- Instrument Sans: "Copyright 2022 The Instrument Sans Project Authors (https://github.com/Instrument/instrument-sans)", licence URL `https://scripts.sil.org/OFL`
- JetBrains Mono: "Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)", licence URL `https://scripts.sil.org/OFL`

Both name tables have an empty licence-description field. `Resources/Fonts/OFL.txt` therefore carries the OFL 1.1 text
(copied from a local Google Fonts download of OFL.txt) with these two copyright lines.

If the resource bundle can't be found (for example, an `.app` assembled without it), the app falls back to SF Pro / SF
Mono and logs it, so it doesn't crash. `--theme-preview` fails loudly instead.

## 4. Screenshots

`build/theme-preview/*.png`, from `swift run CompliantCalendar --theme-preview build/theme-preview` (or the built
binary). The entry point (`AppEntry` in `ThemePreview.swift`) runs this mode *instead of* the App scene, so no window,
menu-bar item or notifications appear. It always runs on fixtures and never writes UserDefaults. It renders through an
offscreen `NSWindow` + `cacheDisplay`, so List, TextField and segmented controls draw. The cursor is pinned "on".
The mail body is a WKWebView, which doesn't draw in an offscreen cache, so reader bodies of unlabelled mail show blank
in previews. The selected fixture message is encrypted, so its notice shows instead.

## 5. What couldn't be matched

- **The Cuts / dither texture** (`niivo-ci-study.md` §8, "The Cuts") is a film and print texture, and the CI bans it on UI ("Scramble on … UI"). It is not used.
- **Iso drawings and the creature** are film devices, and iso is banned below 320 px. The app uses only the flat outline ıı, on the lock screen.
- **Icons:** the CI allows only `· + ✳ → ▸ ✕`. SF Symbols stay for toolbar and row actions (native, accessible); see §1.4.
- **Unread weight:** Instrument Sans 500 instead of 400 (§1.2).
- **One cyan per view:** the mail window has the selection bar, plus the toolbar's native control tint in deep accent (not cyan). The calendar's today chip is its one cyan element.
- **System controls** (pickers, menus, DatePicker, `Form`, toolbar items) keep their macOS shapes. Native behaviour and accessibility take priority over radius 0.
- **Dark Mode** is an app extension of a paper-first brand, mapped from the carbon surface (§1.1).
- **Danger red** comes from the website's `--destructive`, because the CI has no error colour.

## 6. Phase 2: full niivo chrome (2026-11-19)

### 6.1 Window chrome
- **Mail and calendar:** the niivo theme replaces `NavigationSplitView`, `.searchable`, `.toolbar` and `.inspector` with custom shells.
  - Mail: `MailShell.swift` (`MailShellView`, `MailHeaderBar`, `NiivoSidebar`).
  - Calendar: `CalendarShell.swift` (`CalendarShellView`, `CalendarHeaderBar`, `NiivoCalendarSidebar`, inspector as a right column).
- **Window:** `WindowChrome` sets `fullSizeContentView`, a transparent title bar and a hidden title. The traffic lights sit in a 64 pt inset inside the 50 pt header, and `WindowDragGesture` moves the window.
- **Other themes** keep the system chrome unchanged.
- **Posture banner:** inside the shell, under the header.
- **Post-unlock:** `PostUnlockSync` shows a muted mono "Syncing" / "Opening mail" plus a cursor while the background sync runs.
- **Menu bar:** every header action is a menu or key command too, so everything works without the menu bar.
- **Menu-bar extra:** the solid ıı template image (`NiivoGlyphs.menuBarImage()`).
- **Context menus stay native NSMenu.** This is deliberate: accessibility, standard submenus, and the right-click muscle memory people already have. Everything else that pops up is an `NPopoverList`.

### 6.2 Components (`NiivoUI.swift`)
| Component | What it is |
|---|---|
| `NButton(title, systemImage:, kind: .primary/.ghost/.quiet/.danger, large:, role:)` | Square button |
| `NIconButton(sfSymbol, label:, help:, isOn:, size:)` | Square icon button; draws the niivo `NGlyph` when one maps to the symbol |
| `NTabs` (= `NVTabBar`) | Mono tab strip, ←/→ keys |
| `NField(prompt, text:, label:, style: .underline/.bordered, symbol:, focus:, onSubmit:)` | Text field |
| `NToggle` / `NToggleStyle` | 30×16 square switch |
| `NPicker(title, selection:, options:, label:)` / `NMenuButton(label:, symbol:, items: [NMenuItem])` | Custom popovers: ↑↓ ↩ esc |
| `NChip(text, tone:)` | Chip |
| `NSectionHeader` | Section header |
| `.nRow(selected:marked:hoverKey:divider:skin:)` | Row hover, selection and multi-select |
| `NSplitHandle` | Pane resize handle |
| `.nFocusRing()` | 2 pt `accentInk` focus ring |

- **Hover state** lives in the `NUI.shared` observable, never per-row `@State`.
- **Settings:** an indexed nav column (⌘1–⌘6) plus a content pane. Forms inherit `NToggleStyle` and `NVButtonStyle`.

### 6.3 Message list
- **Rows:** custom rows in a `LazyVStack`. Keyset paging is unchanged (`rowAppeared` → 50/page).
- **Selection:** ⌘-click toggles, ⇧-click selects a range, and ⇧↑/⇧↓ extend it.
- **Bulk keys:** E, #, U and S apply to the whole selection; esc clears it.
- **Drag:** drag rows onto a sidebar folder to move them (same mailbox only).
- **Perf (fixtures, 30 rows):** 200 j/k steps took 712 ms, about 3.6 ms per step, worst 11 ms. Each step is a model change plus a forced layout/display pass of the shell in an offscreen window (`ThemePreview`, "perf:" line).
  - This doesn't prove anything at 500k rows. That rests on lazy rows plus keyset paging; the store benchmark measured paging under 1 ms.

### 6.4 Reader body
- **Fonts:** `MailHTML.document(..., brand:)` embeds Instrument Sans and JetBrains Mono as base64 `data:` woff2 `@font-face`, on a paper ground.
- **CSP:** `default-src 'none'; script-src 'none'; object-src/frame-src/child-src 'none'; form-action 'none'; base-uri 'none'; font-src data:`.
  - Images and styles keep their previous reach.
  - The content rule list and JS-off are unchanged.

### 6.5 Sensitivity labels: quieter by Ryan's request (supersedes "never subtler" for our own chips)
- **List rows:** mono 9 pt chip with a 1 pt border and text in the label colour, and no fill.
  - It truncates at 140 pt; hover shows the full name.
  - A lock appears when the label encrypts.
- **Reader and calendar inspector:** a slim one-line bar (colour tick, "Sensitivity", the label name, 🔒 "Encrypted"), with a hairline in the label colour.
- **Unknown label:** the same small size with a red 1 pt frame: "Unknown label — restricted".
- **Purview-defined content is unchanged:** header/footer marking text and the watermark are rendered as the tenant defines them.

### 6.6 Calendar
- **Grid:** the week/day grid sits on the paper ground with 1 pt hairline rules and mono hour labels. The weekday headers were already mono.
- **Events:** square cards with a calendar-colour wash and a 3 pt left bar. Selection is a 1 pt ink frame, with no shadows.
- **Now line:** cyan with a square head, the view's one cyan element.
- **Sidebar:** custom, with indexed sections. Calendars get a square check in the calendar colour and `OwnerInitials` for anything not your own.
- **Restyled with niivo buttons:** inspector, editor, alert banner (square card, ink frame, colour bar).


## 7. Round 3 (2026-11-19): inline compose, windows, quieter markings

### 7.1 Inline compose and pop-out (`MailWindows.swift`)
- **One active draft.** The model keeps a single draft (`MailModel.composer`, with its autosave and AI state); `ComposeHost` only decides where it is shown. Popping out or back in moves the same `ComposerState`, so nothing is lost.
- **Reply, reply-all, forward:** open inline in the reading pane, under the message header, with the AI strip and thread below.
- **New message:** opens in the composer window by default. `ComposeHost.newMessageInWindow` (stored in UserDefaults as `niivoNewMessageInWindow`) can make it compose inline, filling the whole pane.
- **Pop out / back:** the button in the composer header, or ⌥↩ or ⇧⌘P. Closing the window keeps the draft and pops it back into the pane.
- **Message windows:** double-click a row or press ⌘O; several can be open at once. Each window is an independent reader built by `MailModel.standaloneReader(id:)`, which applies the same fail-closed rules as the reading pane. Replies from a message window open in the composer window.
- **Shared chrome and lock:** every secondary window uses `SecondaryWindow`: hidden title bar, niivo header, capture guard. While the app is locked, a window's content is *replaced* by a "Locked" placeholder, not just covered.
- **Calendar inspector:** Edit opens an inline editor for title, start, end and location (`InlineEventEditor`). ⇧⌘P pops out to the full editor with the changes carried over. Native compact date pickers are kept here as an exception.
- **Classic themes:** keep the composer sheet.

### 7.2 Markings (Ryan, round 3)
- **Header marking:** Graph's label definitions carry no marking font size or colour. So the tenant's header text is shown verbatim at caption size (10 pt, Purview's default) in the label colour, as one plain line, the way Outlook shows it. There is no box or fill.
- **Footer marking:** 10 pt, muted.
- **Watermark:** text unchanged; opacity 0.045 (light) / 0.065 (dark), at a 340 × 120 pt pitch.
- **Reader sensitivity line:** one step smaller (8.5–9 pt mono).
- **Unknown label:** stays red, small.

### 7.3 Protected bodies (`ProtectedBody.swift`), the hook for MIP decryption
- **States:** `ProtectedBodyState` is `.decrypting` / `.decrypted(html:)` / `.notPermitted` / `.unavailable(reason:)`.
- **How the MIP layer plugs in:** it publishes a state per item id into `ProtectedBodyStore.shared.states`.
- **What renders it:** `ProtectedBodyView(state:outlookLink:allowCopy:allowPrint:allowExport:)`, used by the reader and the calendar inspector.
  - Until a state is published, the item shows "Protected message — opening…" plus an "Open in Outlook →" link when a webLink exists.
  - `decrypted` HTML is still rendered through `MailHTML.document`, with the label's copy, print and export rights.
- **Unchanged:** the policy logic that decides when a body is protected.

### 7.4 Glyphs everywhere
- `NSymbol(sfName, size:)` and `NLabel(title, systemImage:)` draw the niivo glyph under the brand theme whenever `NGlyphKind(sf:)` maps the name, and the SF Symbol otherwise.
- The deliberate exceptions are listed below.

#### Exceptions: where SF Symbols stay under the niivo theme
- **Native menus and controls:** `Menu`, `.contextMenu`/NSMenu items, `Picker` (including segmented), toolbar items (`MailToolbar`, `SectionSwitch`) and `TabView` `.tabItem` labels. AppKit draws these and can't host custom views. Examples: the meeting context menu (`MeetingLauncher`), calendar colour swatches, the persona and section pickers.
- **Hidden by the brand button style:** `NVButtonStyle` renders `.titleOnly`, so a `Label` icon inside it never draws (Touch ID unlock, the AI chip buttons).
- **Non-brand branches:** views that only render when `skin.brand == false` keep plain SF Symbols.
- **Menu-bar item:** the solid ıı template image (`NiivoGlyphs.menuBarImage()`), not a glyph.
- **Native compact `DatePicker`s:** the event editor and the inspector's inline edit.
- **Everything else:** uses `NSymbol` / `NLabel`, which fall back to the SF Symbol only when no glyph maps (`NGlyphKind(sf:)`). Standalone icons that carry meaning pass `label:` (`NSymbol` hides unlabelled icons from VoiceOver).

## 8. Liquid Glass (2026-11-21, `NiivoGlass.swift`)

Glass is the **control layer** that floats above content. Content stays solid and readable.

| Glass (control layer) | Solid (content) |
|---|---|
| Desk rail, tile headers, Desk layout picker | Mail list rows, reader body, loop page, People columns |
| Signal action strip 1 / 2 / 3, Who panel header | Signal Now card and Queue panel |
| People action strip 1 / 2 / 3 | Today card rows and their icon buttons |
| Reader header action toolbar, compose's floating AI bar | Compose body |
| Loop chip on the reader header | Loop chip on list rows (`compact`: rows are content) |
| Today's Signal / Flow buttons, Flow's Exit | |

API: `.niivoGlass(in:tint:interactive:)`, `.niivoGlassCard(radius:)`, `.niivoGlassCapsule()`, `NiivoGlassContainer`
(wraps `GlassEffectContainer`), `NiivoGlassKeyStyle(primary:)` + `NiivoKeyCap` for numbered action keys,
`.niivoGlassButton(skin, prominent:)` (`.glass` / `.glassProminent`).

Rules:
- **Availability.** Real Liquid Glass (`glassEffect`) on macOS 26+, `.regularMaterial` with a hairline edge on macOS
  15–25. The package still targets macOS 15.
- **Accessibility.** Reduce Transparency or Increase Contrast (system setting or `colorSchemeContrast == .increased`)
  → solid `skin.card` with a `hair2` edge; primary keys go back to the solid ink key.
- **Tint.** Neutral or ink only, never `accentFill`: the one cyan element per view stays a solid fill. Primary keys are
  ink-tinted glass.
- **Shape.** Glass is rounded (14 pt panels, 9 pt keys, capsules). This is a deliberate exception to "radius 0": glass
  controls float like windows and take the system's floating-control shapes. Content surfaces keep radius 0.
- **Shadows.** None added; the glass carries its own depth. The floating AI bar lost its hand-made shadow.
- **Desk tiles** are solid `card` panels with a 12 pt corner, a `hair` edge, and a 1.5 pt `accentInk` frame on the
  focused tile (a line, not the cyan fill).
- `glassEffectUnion` / `glassEffectID` are not used: they need `@Namespace`, and this toolchain has no SwiftUI macro
  plugin (the code base avoids `@State` / `@Namespace`).
