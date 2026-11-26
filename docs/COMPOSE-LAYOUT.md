# Compose + reading pane layout

Owner, 2026-11-20: "the compose and reading pane is still very busy. When you reply you get a small window inside the
reader, which with the AI draft is even smaller… Also the sensitivity labels, do they need to be in the mail list
view… they are clipped now and realistically useless."

Target: Gmail / Apple Mail / Superhuman calm. Nothing compliance-relevant is removed; it is consolidated.
Pure rules live in `MailCore/ComposeLayout.swift` and `ListRowLayout` (covered by CoreSelfTest); views are UNVERIFIED
on screen (no app launch in the builder loop).

## Inventory (before)

| Piece | File / struct | Where it showed |
|---|---|---|
| Inline reply host | `MailReader.swift` `ReaderContent` | `ComposerView` squeezed between the reader header and the body, `frame(minHeight: 360, maxHeight: 520)` |
| Conversation reply host | `ConversationViews.swift` `ConversationCard.expanded` | same fixed-height composer inside the card being answered, every other card still expanded |
| Whole-pane compose | `MailReader.swift` `ReaderView` | new mail (or reply to a message no longer in the pane) |
| Pop-out / extra drafts | `MailWindows.swift` `ComposerWindowRoot`, `ExtraComposerWindowRoot`, `ComposerPopButton` (⌥↩ / ⇧⌘P) | own windows; classic skin uses a sheet (`ComposerPresentation`) |
| Composer frame | `MailComposer.swift` `ComposerView` | title row → one big `ScrollView` (From, To, Cc/Bcc, Subject, options, notices, AI bar, label banner, marking, format bar, editor `minHeight 260`, chips, history, Insert/Templates/Spelling + signature row, footer marking) → footer |
| Title row | `ComposerHeader` | "[ REPLY ]", error, pop-out |
| From | `ComposerFromRow` | always, plus the Cc/Bcc toggle |
| Importance + label picker | `ComposerOptions` + `LabelPicker.swift` `SensitivityLabelPicker` | full-width row ("SENSITIVITY: General ▾"), floor explanation line |
| Second label line | `EventInspector.swift` `LabelBanner` | "SENSITIVITY General" bar under the AI bar |
| Purview notices | `PurviewLabelPolicy.swift` `PurviewComposerNotices` | mandatory / encrypts / justification |
| Warnings | `ComposerWarnings`, `ComposeAssist.swift` `MailTipsBanners` | external, MailTips |
| AI bar | `AIViews.swift` `AIComposerBar` | AI DRAFT, REWRITE ▾, Undo, busy/Cancel, pre-send findings, VOICE badge (`AIVoiceViews.swift` `VoiceComposerBadge`), **side-by-side Before/After preview with Discard / Replace** |
| Format bar | `ComposerToolbar.swift` `ComposerFormatBar` | always; B I U S code size colour highlight lists quote link align clear · attach · OneDrive · Markdown ☑ |
| Editor | `MailRichEditor.swift` (NSTextView on `ComposerEditorState`) | a few lines tall inline |
| Extras | `ComposerAttachmentChips`, `CloudAttachmentRow`, `ComposerExtrasRow`, `ComposerHistoryBlock`, `ComposerLanguageAndTemplates`, `ComposerSignaturePicker` | below the editor |
| Footer | `ComposerFooter` | DISCARD · saved · CLOSE (Esc) · SEND LATER ▾ · SEND |
| Reply chips | `AIViews.swift` `AIReaderStrip` | under the inline composer: REPLY 1 YES … 5 DELEGATE · VOICE ▾ · SUMMARISE, plus the thread summary |
| Reader header | `MailReader.swift` `ReaderHeader` | LabelBanner line, header marking, subject + actions, people, attachment chips |
| List label chip | `MailViews.swift` `LabelChip` via `ListRowLayout.badges` | every labelled row, clipped |
| Conversation row | `ConversationRow.swift` | its own older layout (padding-based height, chip always) |

## After

### Reading pane while replying (pane takeover)

```
┌ ↩ Re: Subject · Sender · 14:02   [label pill]   Show original ▾   ⧉   × ┐   context strip (ComposeContextStrip)
│ (expanded: the original's ReaderBody, read-only, ≤ 40 % of the pane)  │
├ To  [Anna ×] [Ben ×]  Cc/Bcc                [● General ▾] [From ▾] [⋯] ┤   one compact header row
│ (notices only when there is something to say; capped height)          │
│                                                                       │
│ editor — all remaining height (≥ 60 % of the pane)                    │
│   (floating format mini-bar while text is selected, or pinned by Aa)  │
│                                                                       │
├ 📎  Aa  ✦ AI          saved 14:03            🗑   [ Send | ▾ ]        ┤   footer
└───────────────────────────────────────────────────────────────────────┘
```

- `ReaderContent` (single message) renders `InlineReplyPane` instead of the reader when the pane's composer answers
  that message; `ConversationReader` puts `ComposerView(originalInStack: true)` under the (capped) stack. Both stay
  inside the reader's `captureShield` + watermark, so the original's rights still govern the pane. The strip honours
  `redactDetails` ("Private message") and shows the original's label pill; unknown / external / protected-elsewhere
  originals keep their notice line under the strip; header markings stay visible.
- Every send path (⌘↩, Send ▾, ⋯ ▸ Send Later, Schedule) is refused only while an AI request is still running
  (`MailModel.send`, `ComposeLayout.sendEnabled(aiWorking:)`). AI text already in the editor is sent as yours.
  Closing or replacing a composer cancels its request and drops its AI state (`AIComposerState.detach`).
- "Show original" expands the original through the same `ReaderBody(reader:)` path (policy, protected bodies,
  remote-image gate). Collapsed by default (`ComposeContextStrip.expanded == false`).
- Esc: undo AI text that is still marked → collapse the original → close the composer (closeComposer: empty closes
  silently, otherwise the draft is saved). `ComposeLayout.escape(…)`.
- Conversation view: the thread stack shows only the message being answered expanded (others as collapsed headers),
  derived while replying (`ComposeLayout.replyExpansion`) — `ConversationHub.expanded` is not mutated, so the user's
  own expansion returns on close. The stack is capped at 40 % and the composer sits below it.
- New messages (and windows / the classic sheet) use the same compact composer; the strip only appears for replies.

### Composer

- **One header row**: To chips (Cc / Bcc on demand, or when they have recipients), label pill (always visible;
  click → picker; floor reasons inside the picker), From (only with more than one identity — `ComposeLayout.showsFrom`),
  ⋯ menu (send later, templates, insert, signature, spelling language, importance, Markdown, OneDrive, edit subject,
  encryption notice). Subject: new / forward always; replies on demand via ⋯ (`ComposeLayout.showsSubject`).
- Duplicate label lines removed (`LabelBanner` in the composer and the "SENSITIVITY" option row). One pill.
- Format bar hidden by default; a floating mini-bar appears on selection, `Aa` in the footer pins it
  (`ComposeLayout.formatBarVisible`). Markdown moved into ⋯.
- Footer: attach, Aa, AI ✦ | saved time | Discard (trash), Send split button (Send ▾ = send later presets + Custom…).
  The CLOSE button is gone (Esc / strip ×).

### AI inline (2026-11-26: AI text lands in the editor)

Owner, second-device test (BACKLOG §17): "odd UI that doesn't make it possible to edit AI drafts … a bad odd flow",
"we are missing the AI editing options". Cause: the 2026-11-20 version showed the result as a read-only SwiftUI
`Text` over a hidden, non-editable editor; the only ways out were Keep ⏎ / Retry / Discard, Retry took no instruction,
and Send was refused until you chose.

One pattern now, for drafts, the editing actions and "Ask AI to change…" (pure state machine `AIAppliedEdit` in
`MailCore/AIEditing.swift`, CoreSelfTest `AIEditingTests.swift`):

- **Applied, editable, marked.** The result is written into the body at once. The editor stays editable and focused.
  The AI text carries a soft accent background, a layout-manager temporary attribute, so it never reaches the saved or
  sent HTML. Typing inside it makes it yours: the marker goes and the bar says "AI text, edited by you".
- **Slim bar:** "AI draft · edit it freely · Voice: Me · Org · Contact ▾ · Keep · Try again ▾ · Undo ⎋ · Why".
  - Undo puts back what the AI text replaced, including a signature switch. Your edits elsewhere stay. ⌘Z all the
    way back counts as Undo.
  - Try again ▸ offers Replace the AI text, Add another version below, and Try again with instruction…. Your text
    outside the AI span is never touched.
  - Keep just removes the marker. Sending keeps it too: Send no longer waits for a decision, only for a request that
    is still running.
- **Where it goes.**
  - An empty reply gets the draft above the signature. If you already wrote something, the draft goes below it,
    never over it.
  - An action works on the selection, or on the whole text you wrote (signature excluded) when nothing is selected.
  - The editor stays editable while AI works. The request's target follows your typing (`AIEditAnchor`). If you typed
    inside the target, the result is added below with a note instead of overwriting your words.
- **Actions** (AI ✦ menu "Edit Selection" / "Edit Whole Message", and the ⌘J palette):
  - Rewrite, Fix Grammar and Spelling, Shorten, Expand and Summarise as Bullets.
  - Change Tone ▸ More formal / Friendlier / More direct.
  - Translate ▸ English / German / French / Italian.
  - Ask AI to change… (free text; on an empty draft it writes from the instruction).
- **⌘J** opens the actions palette. Type what you want, or a word to filter, and ↩ runs the first row. The editor
  handles ⌘J itself; a hidden footer button covers the header fields. Outlook's ⌘J (Forward) is already disabled
  while a composer is open.
- **Gate.** Items the gate refuses stay visible but disabled, with the reason as the section's first line (palette:
  under the field). The reason comes from the same MailCore function the call uses (`AIAssistant.editRefusal`,
  `replyRefusal`), so the menu and a refused call always agree, and a refused call never reaches a provider.
  - Edits send only the target text plus your voice notes: never the original, the thread or style examples.
  - The tiers are unchanged. The draft's label (with the reply floor) and the routed tier decide.
- **Voice.**
  - Drafts and edits use the resolved voice for the current recipients (Me → Organisation → Contact).
  - Each layer can be switched off for the next request: AI ✦ ▸ Voice, the palette, or the Try again with
    instruction popover. A dropped layer's language, register and form of address go with it.
  - In edits, Translate decides the language and Tone the register, so the resolved voice never contradicts them.
  - Applying a draft sets the voice-learning baseline (`VoiceLearnModel.accepted`), so your later edits feed the
    existing VoiceEdit / nudge path. Undo clears it.
- The floating format bar now sits at the bottom of the editor, where it no longer covers the first lines.

### Reader

- `LabelBanner`'s "SENSITIVITY General" line → a small `LabelPill` next to the date (unknown / external / protected
  elsewhere keep their notice line; unlabelled shows "No label" quietly). Header markings unchanged.
- Under the body: one slim suggestion row with three replies (Yes / confirm, Decline, Propose a time) — the intent
  drafts (no generated smart replies exist yet). The thread summary shows at the top only once requested;
  Summarise and Edit voice moved into the reader's ⋯ menu.
- Attachment chips, the inline preview strip (PREVIEW-HOOK) and the action icons are unchanged.

### List

- `ListRowLayout.labelMark`: no chip by default. A glyph (lock for encrypted, shield otherwise, red for an unknown
  label of ours) only when the label matters: protected, or sensitivity ≥ the tenant's "Confidential" rank
  (`LabelTree.confidentialRank`; unknown → protection only). Tooltip = label name; VoiceOver reads it in the row label.
- View ▸ Show Sensitivity Labels in List (`mail.listLabelChips`, default off) restores full chips.
- `ConversationRow` renders through `MessageRowView` (same height, density, clean list, badge rules).
