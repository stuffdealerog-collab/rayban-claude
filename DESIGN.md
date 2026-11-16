# Design

World: the Tashkent Metro diagram. Midnight enamel by night, porcelain paper by day, four line inks that each do one job, and a conversation drawn as a line with stations. Platform: iOS (SwiftUI, native navigation and controls, Liquid Glass on iOS 26). Mode: Operate — the world lends type, palette, density and one signature move; layout and controls stay native.

Source of truth in code: `RayBanClaude/Design/Theme.swift` (tokens) and `RayBanClaude/Design/LineKit.swift` (the line components).

## Color

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | #F7F6F2 | #0B1230 | Screen ground: paper map / enamel |
| `surface` | #FFFFFF | #131C47 | Cards, fields, list rows |
| `raised` | #E9E7E0 | #1C2759 | Secondary buttons |
| `porcelain` | #FFFFFF | #F7F6F2 | Station fills, the microphone disc |
| `ink` | #0B1230 | #0B1230 | Text and outlines on porcelain |
| `textPrimary` | #0B1230 | #F7F6F2 | Body text, station outlines |
| `textSecondary` | #434D72 | #B7C0E0 | Supporting text |
| `textMuted` | #68718F | #8B96C2 | Plates, meta |
| `hairline` | ink at 12% | porcelain at 12% | Borders |
| `negative` | #A85400 | #FFB13D | Faults — amber, as on a service notice; red is a line colour here |

Line inks (`Theme.Tone`), each with a fill colour and a text-safe variant:

| Tone | Fill light / dark | Text light / dark | Job |
|---|---|---|---|
| `assistant` | #DC1F2E / #E02A38 | #C0161F / #FF7178 | Conversation with the assistant and everything that is the assistant itself (voice, Claude, staying on the line), primary action, camera steps |
| `translator` | #1E5BFF / #2A63FF | #1848D8 / #8FB0FF | Translator and anything from the outside world: mail, web, maps, contacts |
| `memory` | #16994A / #2CC561 | #0F7A39 / #5BDD88 | Memory notes |
| `system` | #F2B200 / #FFC20E | #8A5A00 / #FFD257 | Settings, the glasses, calendar, reminders, timers, the journal |

Text and icons on a fill (`Tone.onColor`): white on scarlet and cobalt, ink on green and amber — at least 4.5:1 in both appearances.

The selected tab tints the tab bar with its line colour. The same table governs Settings icon tiles, tool steps in the transcript and the stations on the welcome map: a colour always names its line.

## Type

San Francisco only, through system text styles (Dynamic Type).
- **Sign voice** — `Font.sign(_:)`: SF Pro Condensed Bold. Screen titles, station names, button labels, note headings.
- **Plates** — `plateStyle()`: condensed semibold capitals at caption size with 0.6 tracking. Who spoke and when («ВЫ · 18:42»), section labels. Short, never a sentence.
- **Body** — SF Pro regular; the user's own words are title3 semibold, answers are body with 3 pt extra leading.
- Tabular digits wherever numbers line up (battery, counts).

## Space and shape

4 pt grid: 4, 8, 12, 16, 24, 32. Screen gutters 16–20. Radii: controls 12, cards 16, panels 22; pills for line badges and side buttons. Elevation by surface step; one soft offset shadow under the microphone disc.

## Signature: the conversation line

`LineRow` puts a 6 pt line in a 30 pt rail on the left of every row; rails join into one continuous line.
- **Station** — hollow ring in the text colour: something the user said.
- **Interchange** — porcelain disc in a line-coloured ring: an answer.
- **Transfer** — a short branch to a small station in another line's ink: a tool step that leaves the assistant's line (calendar branches to amber, notes to green, mail and web to cobalt). A step on the assistant's own line (the glasses camera) is a plain tick. The branch station blinks while the step runs and turns amber on a fault; the row's right column shows how long the step took in tabular digits.
- **Tick** — short bar beside the line for service notices.
- **Live station** — at the end of the line. It breathes with the microphone level while listening, carries a travelling arc while thinking, and fills with the line colour and pulses with the voice while speaking.
- **Planned track** — dotted line and hollow stations for suggestions that have not happened yet.

The same vocabulary carries the other screens: the translator's language pair is two terminus stations, notes are stations on the green line grouped under line pills, onboarding progress is a line of stations, and the welcome screen draws a small map where four lines meet at the assistant's interchange (`RouteMap`).

## Motion

One curve everywhere: `timingCurve(0.22, 1, 0.36, 1)`. Things travel along the line or fade; nothing bounces. A new turn fades in while the line travels from the previous station down to the new one (`RailLine` animates both its first draw and its extension when a row stops being the last). Press: 0.96 scale. Live motion only where something is live: the live station, the running transfer, the listening waveform symbol. Reduce Motion draws lines at once, freezes the live station at a steady size and stops every blink.

## Components

- Titles: one large condensed title in `textPrimary` at the leading edge of the system navigation bar on all four tabs, toolbar items on the right. Memory and Settings use `toolbarTitleDisplayMode(.inlineLarge)` and collapse when their lists scroll, as any iOS list does. The two screens with a conversation line (assistant, translator) use `FixedTitle`, a leading toolbar item that does not collapse: their transcript is always scrolled to its end, and the assistant's name must stay large.
- `LineStatus` — line swatch, state in plain words, optional detail on the right.
- `MicButton` — 80 pt porcelain disc in a 6 pt scarlet ring; inverts to scarlet while busy.
- `SideControl` — capsule with icon and label; glass on iOS 26; filled with the line colour when on.
- `LinePill` — small capsule in a line colour for folder and language badges.
- `ServiceNotice` — amber box with a warning icon for errors.
- Settings and lists: native inset-grouped `Form`/`List` over `background` with rows on `surface` and section labels in the world's text colours; each row carries an icon tile in the ink of the line it belongs to.
- Choices in onboarding are stations on the scarlet line; the chosen one becomes an interchange.
- App icon: four lines meeting at a porcelain interchange on midnight enamel (`scripts/design/make_app_icon.py`).
- Icons: SF Symbols only; no emoji anywhere in the interface.

Credits: process from Impeccable (direction chosen by the user from a dealt hand, seed:8abd01cfa369c37b); slop rules from unslop by Damir Sokolovsky (CC BY 4.0).
