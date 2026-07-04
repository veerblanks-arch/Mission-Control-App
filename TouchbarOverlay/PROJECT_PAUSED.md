# Project Paused

Date: 2026-07-03

This overlay/menu-bar-first version of Droppy is paused for now.

The prototype reached a working menu bar app shell with clipboard history, screenshot pickup, and a top-center island-style overlay, but the overlay positioning was unreliable in real use. In particular, the collapsed island did not consistently align with the macOS menu bar and kept behaving like a floating window over the active app.

Current conclusion: do not keep pushing this implementation direction. The next project should start from a more reliable surface area instead of trying to force a custom `NSPanel` into menu bar/notch behavior.

Useful lessons to carry forward:
- A normal menu bar item is reliable; a custom always-on-top island window is not reliable enough yet.
- Positioning with `NSScreen.frame`, `visibleFrame`, and `NSStatusBarButton.window?.screen` still does not guarantee the visual alignment expected near the menu bar.
- If a future version needs a dynamic-island-style surface, it should begin with a smaller proof of positioning behavior before adding clipboard, screenshots, media, calendar, or shelf features.
- Calendar integration is still a good later feature idea, but it should wait until the host surface is stable.

Last local checkpoint before pausing:
- `38664b8 Shrink menu bar island`
