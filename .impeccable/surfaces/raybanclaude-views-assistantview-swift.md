---
version: 1
slug: "raybanclaude-views-assistantview-swift"
primary_target: "RayBanClaude/Views/AssistantView.swift"
related_targets: ["RayBanClaude/Views/MainTabView.swift"]
---

# Assistant screen (Operate)

Scope: the app shell (tabs) and the Assistant tab; Translator, Memory, Settings and Onboarding inherit it. Mode: Operate. Audience: one person, glasses on, phone mostly in a pocket; glances at the screen for state, transcript, photos.

Unresolved: no simulator screenshots exist (no local Xcode); visual verification happens on the user's device.

## Direction contract

THESIS: The assistant's state is light passing through a Tashkent-modernist sun-screen facade (brise-soleil of pointed-arch openings). Refuses the category default of a glowing purple orb on black.

OWN-WORLD: Warm limestone neutrals (light #F7F4EE ground, dark #12110F), one cobalt accent from modernist mosaics (#2A4FBF / #7D9BF2) for actions and selection only, sun amber (#C9741F / #F2B45A) reserved for the lattice. System SF type at 400–500, native iOS controls, hairlines at 8% ink, 12–16 pt radii, one easing curve (0.22, 1, 0.36, 1).

STORY: Within a second the user knows if the assistant is idle, listening, thinking or speaking; taps or speaks; reads the transcript; tools appear as quiet lines (dashed while running, solid when done).

FIRST VIEWPORT: Large title = the assistant's chosen name, glasses chip (battery) and new-conversation in the toolbar. Below: the 9×5 lattice (220 pt, shrinks to 132 pt once the transcript has content), one state line under it, transcript, bottom bar with hands-free (left), 76 pt mic (centre, Liquid Glass on iOS 26), text input (right). Tab bar: Ассистент · Переводчик · Память · Настройки.

FORM: candidate 7 of 7 (Tashkent modernism brise-soleil), seed:25e38cfa43cf00c7. Raises kept from declined challengers: emission-line rail → tool state by line form (dashed pending, solid done); gate board → rows update in place; airport wayfinding → one state line, one message.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
