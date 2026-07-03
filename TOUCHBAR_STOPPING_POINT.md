# Touch Bar Prototype Stopping Point

Date: 2026-07-03

This repo is paused after the Phase 2 media prototype. The app currently builds as a menu-bar-only macOS app with a persistent Touch Bar Control Strip launcher, a modal Touch Bar row, and media controls that can show Music artwork, tint the row from the artwork, control transport, and scrub playback.

What worked:

- Phase 0: menu-bar-only app, no Dock icon, onboarding/settings flow, default Touch Bar row.
- Architecture fix: persistent Control Strip launcher plus system modal Touch Bar, so Droppy can be opened from other apps.
- Phase 2 media: Music metadata, artwork, dynamic tint, play/pause/skip buttons, and scrubber behavior were verified on hardware.
- The media implementation uses Music/Spotify AppleScript first because MediaRemote was unreliable on this Mac.

What was still shaky:

- The Touch Bar down-arrow/minimize behavior was the last active bug. A fix was built that uses `minimizeSystemModalTouchBar`, clears Droppy's cached modal state, and reasserts Control Strip presence, but that exact final behavior was not confirmed by the user before pausing.
- The project depends on private or runtime-only Touch Bar APIs and `DFRFoundation` for Control Strip persistence.
- Hardware-only debugging made progress slow and brittle.

Decision:

Stop investing in the Touch Bar app for now. Preserve this as a working prototype/checkpoint, then start a separate Mac overlay / Dynamic Island style project. The overlay should reuse the good ideas from this prototype: artwork-based color, compact media controls, project/profile switching, and menu-bar persistence, but avoid building core UX around the Touch Bar.
