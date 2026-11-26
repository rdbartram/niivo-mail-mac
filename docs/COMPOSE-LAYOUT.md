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
- Every send path (⌘↩, Send ▾, ⋯ ▸ Send Later, Schedule) is refused while an AI suggestion is pending
  (`MailModel.send`); closing a composer drops its pending suggestion.
- "Show original" expands the original through the same `ReaderBody(reader:)` path (policy, protected bodies,
  remote-image gate). Collapsed by default (`ComposeContextStrip.expanded == false`).
- Esc: discard a pending AI suggestion → collapse the original → close the composer (closeComposer: empty closes
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

### AI inline

- AI ✦ (footer) menu: Draft reply…, the five intents (1–5 shortcuts in the reader are unchanged), Rewrite ▸ (polish,
  shorten, formal, friendlier, Translate ▸), Voice ▸ (edit voice for contact / org), Why.
- The result renders **inside the editor box** as a highlighted suggestion block over the still-mounted editor:
  the whole draft for an AI reply, or the body with only the selection replaced for a rewrite
  (`AISuggestionText.segments`). Under it a slim bar: "AI draft · Voice: … · Keep ⏎ · Retry · Discard ⎋ · Why".
  While a suggestion is pending the editor is read-only and Send waits.
- Keep = the existing `AIAssistModel.acceptPreview` (signature plan + dedupe + one undo via `undoAI`), unchanged apart
  from the body transform now being the pure `AISuggestionText.apply`. Busy / Cancel, errors, notes, pre-send
  findings and "Undo AI change" live in the same slim bar (`AISuggestionPhase`).
- No more Before/After split, no reply chip row under the composer.

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
