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

Droppy no longer relies on being the focused app to expose its Touch Bar controls. The foundation now registers a persistent Control Strip item, then uses a system modal Touch Bar when that item or the menu-bar command is triggered.

The system tray/modal bridge uses AppKit selectors that are available at runtime on the target macOS build but are not surfaced as normal Swift APIs in the public headers. This is acceptable for the personal-use MVP, but it should be retested before any distribution plan.

Phase 1's custom volume and brightness controls remain deferred under this architecture. Native macOS controls are still better for those settings, and Droppy should focus first on controls that benefit from the persistent modal surface.
