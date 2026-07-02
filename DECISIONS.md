# Droppy Decisions

These answers came from Section 7 of `touchbar-productivity-app-project-plan.md` before Phase 0 started.

1. macOS version: 26.5.1 (25F80).
2. Distribution: personal use first; distribution can be revisited much later.
3. Private APIs: MediaRemote.framework is acceptable for Phase 2. Any extra undocumented API need in Phase 1 should be flagged before use.
4. First app profile: Codex, specifically for switching through projects.
5. File shelf fallback: acceptable to drop files onto the menu bar icon and manage them from the Touch Bar if direct Touch Bar drag-and-drop is too limited.
6. Visual style: icon-first. Media controls should dynamically tint from the currently playing media artwork, such as turning red when the active album art is red.

## Phase 1 outcome

Custom volume and brightness controls were scrapped for MVP after hardware testing. Native macOS controls already provide reliable sliders and HUD feedback, while the custom brightness implementation was unreliable on the target Mac and would require deeper/private behavior to match the system experience.

Droppy currently shows its Touch Bar row only while the app is focused. That is a real limitation of the public AppKit Touch Bar path and should be revisited before building features whose whole value depends on staying visible while another app is active.
