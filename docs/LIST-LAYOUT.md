# Message list row layout

Owner, 2026-11-20: "the list view of the mails was what I meant needed cleaning". The row now follows Gmail's list:
one calm, dense line at a fixed height. Nothing has been removed. Rarer state shows only on the selected row; hovering
shows the actions; VoiceOver still reads everything (`messageRowAccessibility`).

## Inventory: before → after

| Element | When shown | Source | Now |
|---|---|---|---|
| Unread mark (ink cut ı / accent dot) | unread | MailViews `MessageRowView` | always, leading |
| Avatar | `MailOrg2.showAvatars` | MailAvatars `SenderAvatar` (ORG2-HOOK) | comfortable/roomy only; hidden in compact and in the clean list |
| Presence dot | avatars off | PeopleViews `.presenceDot` (PEOPLE-HOOK) | unchanged (on the sender name) |
| Sender name (+ hover card) | always | MailViews / MailAvatars `.senderHoverCard` | bold when unread, fixed column |
| Thread count | `row.count > 1` | MailViews | next to the sender |
| VIP ★ | VIP sender | MailOrg2 (ORG2-HOOK) | selected row only |
| "via X" tag | send-on-behalf | MailViews | selected row only |
| Mailbox badge | not "me" (unified views) | MailboxManager `MailboxBadge` | selected row only |
| High-importance ! | importance high | MailViews | selected row only |
| Attachment 📎 | `hasAttachments` | MailViews | badge (priority 3) |
| Flag | flagged | MailViews | selected row only; still in row actions, VoiceOver, hover strip |
| Snoozed clock | snoozed | MailViews | selected row only |
| Waiting-to-sync | `pendingSync` | MailViews | row dimmed (0.75) always; icon on the selected row |
| Encrypted lock | `bodyIsProtected` | MailViews | always unless the label mark already shows a lock (`showsBodyLock`) |
| Subject | always | MailViews | same line as the snippet |
| Preview (1–3 lines) | `previewLines > 0` | MailViews (A11Y-HOOK) | grey snippet after the subject, one line; "None" still hides it |
| "Preview not stored…" | label forbids caching | MailViews | in the snippet slot |
| AI triage tag + "ask" line | AI on, reply needed / waiting / ask | AIViews `AIRowLine` (AI-HOOK) | reply needed / waiting tag as a badge (priority 2); the ask text is in its tooltip |
| Label chip | label in our tree (or provably ours) | MailViews `LabelChip` | 2026-11-20: off by default. `LabelGlyphMark` (lock / shield / red diamond, no text) only for labels that matter; the chip only with View ▸ Show Sensitivity Labels in List. Badge priority 1 when present |
| Category dots | categories | MailViews `CategoryDots` | selected row only (first two) |
| Date / time | always | MailViews | right-aligned; the hover strip covers it |
| Hover action strip | hover | MailRowActions `RowQuickStrip` | unchanged, over the date on the right (Gmail-style) |
| Swipe actions | trackpad swipe | MailRowActions `SwipeableRow` | unchanged |
| Story group header / grouped bar | Stories view | StoryViews `rowView` | unchanged (reuses `MessageRowView`) |
| Story chips, smart-view / tray badges on rows | — | not found in `MessageRowView` (they live in the sidebar / story headers) | unchanged |
| Search result rows | search window | SearchViews (own renderer; search files out of scope) | not changed |
| Selection / hover / multi-select surface | | NiivoUI `.nRow` | unchanged |

## Rules (`ListRowLayout`, MailCore/MailViewPreferences.swift; covered by CoreSelfTest)

- At most two badges, in this order: label mark, then reply needed / waiting, then attachment. The label mark is never dropped.
- Label mark (`ListRowLayout.labelMark`, 2026-11-20, owner: "they are clipped now and realistically useless"): no chip by
  default. A glyph only when the label matters — it encrypts, its sensitivity is ≥ the tenant's "Confidential" rank
  (`LabelTree.confidentialRank`: the least sensitive label named Confidential; none → encryption decides), or it is an
  unknown label of ours (restricted). Tooltip = label name; VoiceOver reads it in the row label. **View ▸ Show
  Sensitivity Labels in List** (`mail.listLabelChips`, default off) restores the full chip for every label.
- Conversation rows (`ConversationRow`) render through `MessageRowView` (`thread:`), so heights, density, clean list and
  badges are identical; participants, thread count / unread / flag / attachments, strictest label (no provenance →
  only labels in our tree), snippet only when the newest message's own policy allows it.
- Fixed row height per density: compact 30, standard ("Comfortable") 40, roomy 50 (classic skin −2). With the reading pane
  on the right the column is narrow, so rows use two lines (sender + date / subject + snippet + badges): 46 / 58 / 66.
- AI "ask" text ("needs you…") replaces the snippet on the selected row.
- **View ▸ Comfortable / Compact** sets the density (Settings ▸ Layout keeps Roomy).
- **View ▸ Clean List** (⌥⌘K; also Settings ▸ Layout ▸ Message list) shows only the sender, subject and snippet, date and the label mark. It is persisted as `mail.cleanList`.
