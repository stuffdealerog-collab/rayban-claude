# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Owner of Ray-Ban Meta (Gen 2) glasses living in a CIS country (Tashkent), where Meta AI is not officially available. Uses the glasses hands-free during the day: walking, commuting, in shops and cafés, meeting people who speak other languages. Russian-speaking; reads and writes Russian UI. *(Confirmed in conversation; the single primary user is the owner himself — this is a personal app distributed via sideloading/TestFlight, not a store product.)*

## Product Purpose

A personal voice assistant that replaces Meta AI on the glasses "almost natively": the user talks through the glasses' microphones, the assistant sees through their camera, answers through their speakers, and acts on the phone like a "Jarvis" — messages, calendar, mail, reminders, timers, navigation, web search — and remembers the user over time. Success: conversations feel like talking to a real person (fast, natural voice, personality, memory), and everyday errands get done by voice. *(Confirmed: user brief, 2026-11-16.)*

## Positioning

Unlike Meta AI (region-locked, generic persona) and unlike desktop agents such as OpenClaw, it lives on the iPhone and the glasses, runs on Claude, and is shaped by the user: on first launch the user names the assistant and chooses its character and manner of speaking. Its memory is a folder of plain Markdown notes (Obsidian-like) that the user can read and edit. *(Confirmed: user brief.)*

## Operating Context

- Mostly eyes-free: the phone stays in a pocket, interaction happens by voice through the glasses; the screen is glanced at for transcripts, photos, translations, and settings.
- Outdoors and on the move: bright daylight and night both matter; one-handed use.
- Real-time translation is used face-to-face with another person, sometimes showing the phone screen to them.
- Network can be mobile/slow; API cost matters (the user pays per token for Claude and per character for ElevenLabs).

## Capabilities and Constraints

- Built in GitHub Actions (no local Xcode); installed via Sideloadly (free Apple ID, 7-day signing) — no paid entitlements (no iCloud, no push, no Hotspot).
- iOS sandbox limits: the app cannot read other apps' messages (Telegram, WhatsApp, iMessage) or notifications; sending a message requires the user's tap in the system composer or the target app. Mail can be read only through the mail provider (IMAP with an app password). These limits are product truth and must be stated, not hidden.
- Voice: Apple Speech for recognition, ElevenLabs (optional key) or iOS voice for speech; A2DP stereo answers in push-to-talk mode.
- Claude API (Opus/Sonnet 5.5) with tools, web search, prompt caching.
- *(Assumption, inferred from the brief:)* Russian is the primary UI language; English secondary.

## Brand Commitments

- The assistant's name, character, and manner are user-defined at first launch; the app must not impose a fixed persona name. Default suggestion: "Джарвис" *(assumption from the brief's "в общем джарвис")*.
- The user asked for "Apple-level" animations and a beautiful, convenient design with all needed tabs. *(Confirmed: user brief.)*

## Evidence on Hand

- App icon: `RayBanClaude/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (warm gradient, white glasses, sound waves).
- No testimonials, metrics, or press exist; none may be invented.

## Product Principles

1. Voice first, screen second: every core action must work without looking at the phone.
2. Feel like a person: low latency, natural voice, consistent character, remembers context.
3. Honest about the platform: when iOS forbids something, say so and offer the closest working path.
4. The user owns the assistant: persona, memory notes, and keys are visible and editable.
5. Spend tokens deliberately: cache, keep context lean, use cheaper models where quality allows.

## Accessibility & Inclusion

- Dynamic Type and VoiceOver for all screens; Reduce Motion honored by the voice orb and transitions. *(Assumption: standard iOS expectations; no specific user need was stated.)*
