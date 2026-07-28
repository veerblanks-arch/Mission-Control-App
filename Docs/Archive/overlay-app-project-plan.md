# Project Plan: Native macOS Overlay Productivity App (Menu-Bar-First)
**For: Codex (coding agent) | Prepared by: Ranveer's planning session with Claude**
**Revision note:** This supersedes the earlier Touch Bar plan (scrapped — fighting Apple's Control Strip/focus model wasn't worth it) and revises the original notch-first plan. Since there's no notched Mac to test on yet, **the menu-bar dropdown is the primary UI for v1**, built to be fully functional and testable today. Notch-hugging visuals are a defined future phase, not a blocker.

---

## 0. Framing note
Original app, not a clone of any existing notch utility's code/branding/name. Same feature category as tools like Droppy/NotchNook/Boring Notch, built from scratch.

## Lessons carried over from the Touch Bar attempt
- **Fully test every phase on real hardware before moving on** — this caught the Touch Bar focus-scoping problem early instead of after 5 phases.
- **Explicit go-ahead gates between phases** — Codex builds one phase, stops, waits for confirmation.
- **If a phase turns into a fight against undocumented OS restrictions with no clean path, defer or cut it** rather than burning cycles forcing it (same instinct that killed the volume/brightness sliders).
- **Git is already set up locally** — keep committing per-phase with clear messages, no GitHub needed.

---

## 1. Goal
A native macOS **menu-bar background app** providing:
1. **Clipboard Manager** — searchable history, OCR on images
2. **Quick File Shelf** — drag files in, stash temporarily, drag back out
3. **Floating Basket** — summon a drop zone via drag-gesture, anywhere on screen
4. **Media Player** — Now Playing with album art
5. **Notch overlay skin** *(future phase — see §4 Phase 6)*

All UI in v1 lives in a **menu-bar dropdown panel** (click the menu bar icon → panel appears below it), not a notch overlay. This is fully testable on your current Mac and any Mac, notched or not.

---

## 2. Tech stack
- **Language:** Swift 5.9+
- **UI:** SwiftUI for the dropdown panel content, AppKit (`NSStatusItem`, `NSPopover` or a custom borderless `NSPanel`) for the menu-bar shell.
- **IDE/build:** Xcode project, real app target.
- **Min deployment target:** macOS 13+ (confirm against whatever your Touch Bar Mac runs, but this app should also be tested on any newer Mac you have access to, since it's not hardware-locked like the Touch Bar version was).
- **Frameworks:**
  - `AppKit` — status item, popover/panel, drag & drop
  - `Vision` — OCR for clipboard images
  - `MediaRemote.framework` (private, same caveat as before) — Now Playing info
  - `GRDB.swift` (SQLite) — clipboard history
  - `NSWorkspace` — fullscreen/app-switch awareness
- **Distribution:** Developer ID signed + notarized, outside Mac App Store (same reasoning as before — sandbox blocks too much of this).
- **Auto-update:** Sparkle.

---

## 3. Architecture
```
OverlayApp/
├── App/
│   ├── AppDelegate.swift        # LSUIElement, lifecycle
│   ├── OverlayApp.swift         # @main
├── Core/
│   ├── StatusItemController.swift  # menu bar icon + panel presentation
│   ├── PermissionsManager.swift    # Accessibility, etc.
├── Features/
│   ├── ClipboardManager/
│   ├── FileShelf/
│   ├── FloatingBasket/
│   ├── MediaPlayer/
├── NotchLayer/                  # future — isolated so it can be added without touching core logic
├── Storage/
│   ├── ClipboardStore.swift
│   ├── Settings.swift
├── Resources/
└── OverlayAppTests/
```
- Menu bar icon (`NSStatusItem`) is the single entry point — click to open the panel, which hosts all four features (tabs or a scrollable stack).
- Panel built as a borderless `NSPanel` (not `NSPopover`) from the start, since `NSPanel` gives more control over positioning/animation and makes the later notch-attached version a smaller lift (same underlying panel, different position/shape).
- `NotchLayer` is kept as an isolated, swappable module — when notch hardware is available, this becomes an alternate presentation mode for the same underlying panel/data, not a rewrite.

---

## 4. Feature phases

### Phase 0 — Scaffolding
- Menu bar status item, click-to-open panel (empty shell), quit/settings menu, `LSUIElement`.
- Confirm panel opens/closes cleanly, positioned under the menu bar icon.

### Phase 1 — Clipboard Manager
- Poll `NSPasteboard.general.changeCount`, store history in SQLite (GRDB): text/image/file, timestamp, source app, pinned flag.
- Panel UI: scrollable list, text snippet/image thumbnail previews, click to copy-and-paste.
- OCR via `Vision` (`VNRecognizeTextRequest`) on copied images — fully local.
- No default global hotkey for now; the user already has custom MacBook hotkeys. Revisit only as an optional setting later.

### Phase 2 — Quick File Shelf
- Drag files onto the panel (or directly onto the menu bar icon while the panel's closed) to stash them.
- Staged in `~/Library/Application Support/<App>/Shelf/`.
- Right-click: Move, Copy, Share, Rename, Remove from shelf.
- Drag items back out to Finder/other apps — this is a regular `NSDraggingSource` from a normal window, so it should be far less finicky than the Touch Bar drag attempt was.

### Phase 3 — Floating Basket
- Global drag-session monitoring (`NSEvent` global monitor) to detect a "jiggle" gesture mid-drag.
- Summon a temporary floating drop-zone panel at the cursor.
- Optional: watched-folder auto-populate via `FSEvents`.

### Phase 4 — Media Player with artwork
- Now Playing track/artist/artwork/scrubber in the panel.
- `MediaRemote.framework` (private, confirmed acceptable) — same caveat as always: undocumented, could break on an OS update.
- This is a straightforward reuse of whatever you learned building this in the Touch Bar attempt, just rendered in a normal SwiftUI view instead of constrained Touch Bar items — should actually be easier this time.

### Phase 5 — Polish pass on the menu-bar experience
- Settings window: toggle features, optional hotkeys, launch-at-login.
- Consistent animation/spring curve across panel open/close and internal transitions.
- This is a real "ship it as v1" checkpoint — the app should be fully usable and polished as a menu-bar tool before any notch work begins.

### Phase 6 — Notch overlay skin *(future, only once notch hardware is available)*
- New presentation mode in `NotchLayer`: instead of a menu-bar dropdown, the same panel/data renders as a notch-hugging overlay (detect notch via `NSScreen.safeAreaInsets`), with expand-on-hover/drag-enter behavior.
- Non-notch Macs keep using the Phase 0–5 menu-bar UI as a permanent fallback, not a placeholder — this dual-mode design is why building the panel as a swappable `NSPanel`-based module from the start (§3) matters.

---

## 5. Non-functional requirements
- Idle CPU <1%, RAM <100MB — clipboard polling and any watched-folder monitoring are the main risks.
- 100% local/offline, no telemetry by default.
- Every phase must be independently testable on your current Mac — no phase should require hardware you don't have (that's the whole point of this revision).

---

## 6. Open questions
1. Global hotkey decision: no default hotkey for now because the user's MacBook already has custom hotkeys. Optional hotkeys can be revisited later.
2. Should the panel be a fixed size/position under the menu bar icon, or resizable/draggable by the user?
3. Any interest in the screenshot annotation editor or cloud file-sharing stretch goals from the original plan, or staying scoped to the four core features through Phase 5?
4. Distribution scope unchanged — just for you, or eventually others?

---

## 7. How to hand this to Codex
Same as before:
> "Read PROJECT_PLAN.md (this replaces the Touch Bar version — we're building a menu-bar-first overlay app now, notch support deferred to Phase 6 until notch hardware is available). Before writing any code, ask me the open questions in section 6, then start Phase 0. Wait for my go-ahead between every phase, and commit locally after each one."
