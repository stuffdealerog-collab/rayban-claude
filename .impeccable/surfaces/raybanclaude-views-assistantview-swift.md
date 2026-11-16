---
version: 1
slug: "raybanclaude-views-assistantview-swift"
primary_target: "RayBanClaude/Views/AssistantView.swift"
related_targets: []
---

# Assistant home (and the app shell it sets)

Scope: `RayBanClaude/Views/AssistantView.swift` and every screen that inherits its world — translator, memory, settings, onboarding. Mode: Operate. Platform: iOS 17.2+, Liquid Glass on iOS 26.

Audience and job: one person in Tashkent wearing Ray-Ban Meta, phone mostly in a pocket. They open the app to start or stop a conversation, to see what the assistant heard and did, and to set it up. Russian UI; Uzbek and English content appears in the transcript.

Constraints: native navigation and controls; Dynamic Type; both appearances; Reduce Motion; no bundled fonts (SF Pro, including its condensed width).

## Direction contract

THESIS: A conversation is a journey on a metro line. The screen owns one idea: every turn is a station on a coloured line, every action of the assistant is a stop along the way. It refuses the category default of a glowing orb over chat bubbles.

OWN-WORLD: Tashkent Metro diagram. Midnight enamel ground (#0B1230) by night, porcelain paper (#F7F6F2) by day. Four line inks, one per job: scarlet for the assistant, cobalt for the translator, green for memory, amber for settings and notices. Porcelain station rings, 6 pt line strokes, interchange pills. Display type is SF Pro Condensed Bold; labels are short condensed capitals like station plaques.

STORY: The user sees at a glance whether the assistant is on the line and listening, reads the last exchange as stations, and knows where to press to talk or to stay connected with the phone locked.

FIRST VIEWPORT: Large condensed title with the assistant's name; under it a status strip (line swatch, state, microphone source). The transcript fills the middle with a scarlet line down the left edge: ring stations for the user, filled interchanges for answers, small ticks for tool steps, a live station at the end that pulses with the voice. A bottom cluster holds "На связи", the microphone disc with a scarlet ring, and the keyboard. Native tab bar, each tab tinted with its line colour.

FORM: challenger adopted by the user — midnight transit diagram; seed:8abd01cfa369c37b. Signature move: the conversation line with its live station. Motion grammar: things travel along the line; nothing bounces.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Unresolved

- How the line reads on a real device at large Dynamic Type sizes.
- Whether the tab tint change per tab feels right on iOS 26 glass.
