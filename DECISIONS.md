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

The system tray/modal bridge uses AppKit selectors that are available at runtime on the target macOS build but are not surfaced as normal Swift APIs in the public headers. It also requires `DFRElementSetControlStripPresenceForIdentifier` from the private DFRFoundation framework so the Droppy icon actually appears in the minimized Control Strip. This is acceptable for the personal-use MVP, but it should be retested before any distribution plan.

Phase 1's custom volume and brightness controls remain deferred under this architecture. Native macOS controls are still better for those settings, and Droppy should focus first on controls that benefit from the persistent modal surface.

## Phase 2 notes

Media controls now prefer local Music/Spotify AppleScript metadata because dynamically loaded `MediaRemote.framework` repeatedly returned nil or `Operation not permitted` on the target machine. MediaRemote remains a fallback for transport commands and unsupported players. Music.app metadata, artwork, tinting, and scrubber behavior were verified on hardware after fixing an artwork pipe deadlock in the `osascript` runner.

## Pause decision

On 2026-07-03, the Touch Bar app was paused after Phase 2 because the project was spending too much effort fighting Apple's ownership of the Touch Bar surface. The working prototype is preserved as a checkpoint, but the next product direction is a Mac overlay / Dynamic Island style app, where the UI can be built with normal windows, animations, and AppKit/SwiftUI behavior instead of private Touch Bar modal APIs.

## Overlay app restart

These answers came from Section 6 of `TouchbarOverlay/overlay-app-project-plan.md` before the menu-bar-first Phase 0 started.

1. Global hotkey: keep `Cmd+Shift+V` for the clipboard panel.
2. Panel behavior: build a draggable/resizable menu-bar panel first. The resting compact pill / hover-popout idea is deferred until the basic shell is stable.
3. Scope: core-only through Phase 5. Screenshot annotation and cloud file sharing stay deferred as future ideas.
4. Distribution: personal use first; public release can be revisited later.

Phase 0 should replace the runtime Touch Bar entry point with a menu-bar status item and overlay panel shell while keeping the existing Xcode target intact.

## Phase 1 notes

Calendar integration should be considered after the four core features are stable. The useful version should match the user's real calendar, which means it needs an explicit calendar-source decision later rather than a fake standalone calendar widget now.

For the first clipboard-manager implementation, use a clean local persistence boundary rather than adding package/network dependency work. GRDB/SQLite can replace the store later if the history model needs heavier querying.
