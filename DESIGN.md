# Design

World: Tashkent modernism — pale limestone facades, cobalt mosaic, light falling through sun-screen lattices. Platform: iOS (SwiftUI, native controls, Liquid Glass on iOS 26). Mode: Operate — the chrome stays quiet; the lattice is the one rich moment.

Source of truth in code: `RayBanClaude/Design/Theme.swift` (tokens) and `RayBanClaude/Design/LatticeView.swift` (signature).

## Color

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | #F7F4EE | #12110F | Screen ground |
| `surface` | #FDFBF7 | #1C1A18 | Inputs, suggestion rows, cards |
| `raised` | #EFE9DF | #262421 | User bubbles, secondary buttons |
| `textPrimary` | #1F1B16 | #EFE9DE | Body text |
| `textSecondary` | #5E554A | #AAA398 | State line, captions |
| `textMuted` | #7B7266 | #8A847A | Meta, icons |
| `hairline` | ink at 8% | ink at 8% | Borders, dividers |
| `accent` | #2A4FBF | #7D9BF2 | Primary action, selection, links — nothing else |
| `sun` | #C9741F | #F2B45A | Lattice light only |
| `positive` / `negative` | #16A34A / #DC2626 | #4CC38A / #E5484D | Meaning only |

One accent. Surfaces stay neutral; color lives in the lattice.

## Type

San Francisco through system text styles (Dynamic Type). Weights 400–500, 600 only for button labels. Hierarchy by size and color. Sentence case, no tracked uppercase labels, no trailing periods on labels, no exclamation marks.

## Space and shape

4 pt grid: 4, 8, 12, 16, 24, 32. Screen gutters 16, sections 24–32. Radii: controls 10, cards 16, panels 20; nested radius = outer − padding. Elevation by surface step plus hairline; one soft neutral shadow only on the pre-iOS 26 mic button.

## Motion

One curve everywhere: `timingCurve(0.22, 1, 0.36, 1)`. Press 0.97 scale; entrances 0.3–0.45 s; onboarding steps slide 40 pt with opacity. Live motion only where something is live: the lattice, the listening waveform symbol, the pulsing icon of a running tool. Reduce Motion freezes the lattice to static intensities.

## Signature: the lattice

9 × 5 pointed-arch openings, 6 pt gaps, stone hairline frames, sun-colored fill by intensity:
- idle — lit from the side where the sun is at the current local time (static);
- listening — cells near the centre brighten with microphone level;
- thinking — a diagonal band of light crosses the facade every 2.4 s;
- speaking — light ripples outward with the voice level (ElevenLabs metering; steady wave for the iOS voice).
States cross-fade over 0.45 s.

## Components

- Tool rows in the transcript: SF Symbol + label + a rule that is dashed while running and solid when done; failures in `negative`.
- Mic button: 76 pt circle, accent when idle, raised surface while busy; `glassEffect(.regular.tint(...).interactive())` on iOS 26.
- Lists and settings: native inset-grouped `Form`/`List` with hidden scroll background over `background`.
- Icons: SF Symbols only; no emoji anywhere in the interface.

Credits: process from Impeccable; slop rules from unslop by Damir Sokolovsky (CC BY 4.0).
