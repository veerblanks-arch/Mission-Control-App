# Project Plan: Native macOS Touch Bar Productivity App
**For: Codex (coding agent) | Prepared by: Ranveer's planning session with Claude**
**Target hardware: MacBook Pro 13" with Touch Bar (no notch)**

## 0. Framing note
This is an **original app** built for the Touch Bar — not a clone of any existing notch utility's code, branding, or name. It borrows the general *category* of ideas (clipboard manager, file shelf, media controls, system HUDs) that are common across several Mac productivity utilities, but everything here — UI, architecture, feature set — is being designed fresh for Touch Bar hardware specifically, which is a meaningfully different build than a notch app.

---

## 1. Goal
A native macOS **background/menu-bar app** that turns the Touch Bar into a productivity strip with:
1. **Custom Volume & Brightness controls**
2. **Media Player with album artwork**
3. **Clipboard Manager strip**
4. **Quick File Shelf** (drag files onto the Touch Bar to stash them)
5. **Context-Aware App Switcher** (per-app custom button sets)
6. **Live CPU/RAM stats**
7. **Study/Pomodoro Timer**

Must be a real **.app bundle** built in Xcode with Swift + AppKit — not a web wrapper, not an HTML tool.

---

## 2. Tech stack (required)
- **Language:** Swift 5.9+
- **UI:** AppKit's `NSTouchBar` / `NSTouchBarItem` APIs (this is Touch Bar–specific; SwiftUI has no direct Touch Bar support, so this project is more AppKit-heavy than a typical modern Mac app).
- **IDE/build:** Xcode project, real app target.
- **Min deployment target:** macOS 12+ (Touch Bar MacBooks stopped shipping in 2019-2020, so supporting slightly older macOS versions is worth considering — confirm with Ranveer which macOS version his 13" Pro is actually running).
- **Frameworks:**
  - `AppKit` (`NSTouchBar`, `NSCustomTouchBarItem`, `NSSliderTouchBarItem`)
  - `MediaRemote.framework` (private, see caveat in Phase 2) for Now Playing info
  - `AVFoundation` for local media metadata where possible without private APIs
  - `Vision` — not needed for this version unless OCR gets added later
  - `GRDB.swift` (SQLite) for clipboard history persistence
  - `IOKit`/`host_statistics`/`task_info` (via `Darwin`/Mach APIs) for CPU/RAM stats — public, no private API risk
  - `NSWorkspace` notifications for frontmost-app tracking
- **Auto-update:** Sparkle framework.
- **Distribution:** Developer ID signed + notarized DMG, outside the Mac App Store (sandbox would block global app-switch monitoring, arbitrary file access for the shelf, and MediaRemote usage).

---

## 3. App architecture
```
TouchBarApp/
├── App/
│   ├── AppDelegate.swift            # LSUIElement, lifecycle
│   ├── TouchBarApp.swift            # @main entry
│   ├── MainTouchBarController.swift # NSTouchBarDelegate, owns the active bar
├── Core/
│   ├── TouchBarProfileManager.swift # switches active profile per frontmost app
│   ├── PermissionsManager.swift     # Touch Bar "App Controls" onboarding
├── Features/
│   ├── VolumeBrightness/
│   ├── MediaPlayer/
│   ├── ClipboardStrip/
│   ├── FileShelf/
│   ├── AppSwitcherProfiles/
│   ├── SystemStats/
│   ├── StudyTimer/
├── Storage/
│   ├── ClipboardStore.swift         # SQLite/GRDB
│   ├── Settings.swift               # UserDefaults / AppStorage
├── Resources/
└── TouchBarAppTests/
```
- App runs as a menu-bar accessory (no Dock icon).
- `NSTouchBarProvider`/`makeTouchBar()` supplies the active bar; `TouchBarProfileManager` swaps which feature set is shown based on context (frontmost app, or user-selected "pinned" mode).
- **User must manually enable "App Controls" in System Settings → Keyboard → Touch Bar** for a third-party app to take over the strip — build a clear one-time onboarding screen explaining this, since it's not obvious and the app literally won't work until it's turned on.

---

## 4. Feature phases

### Phase 0 — Scaffolding
- Xcode project, bundle ID, signing, menu bar status item (settings/quit menu).
- Enable Touch Bar customization, onboarding screen for the "App Controls" system setting.
- Default fallback Touch Bar row (so it's never blank if no feature is active).

### Phase 1 — Volume & Brightness controls
- Custom `NSSliderTouchBarItem`-based sliders, styled your own way.
- Hook into media key events (`NSEvent` local monitor / `CGEventTap`) to intercept volume/brightness key presses and update your custom UI instead of (or alongside) the system default.
- Lowest-risk phase — good first build to get comfortable with `NSTouchBar` item types before tackling anything with private APIs.

### Phase 2 — Media Player with artwork
- Now Playing track title/artist + album art thumbnail + scrubber, rendered as Touch Bar items.
- **Caveat to flag explicitly:** there's no public, sandbox-safe API for reading *other apps'* Now Playing info system-wide. This is typically done via the private `MediaRemote.framework` — widely used in this app category, works well, but is undocumented and outside Apple's official API surface (could break on a macOS update, not App-Store-safe). Confirm you're still fine with this (you said yes previously, just flagging again since this phase is where it actually gets used).
- Touch Bar image items update at a lower refresh rate than a full window — worth prototyping early to see how good the artwork actually looks at Touch Bar resolution.

### Phase 3 — Clipboard Manager strip
- Poll `NSPasteboard.general.changeCount` on a timer (no public "clipboard changed" push notification exists).
- Store history in SQLite via GRDB: text/image/file type, timestamp, source app, pinned flag.
- Render recent items as tappable `NSCustomTouchBarItem`s (text snippet or thumbnail) — Touch Bar space is limited, so this needs a "scrollable" `NSScrubber` layout to show more than 3-4 items at once.
- Tap to paste; maybe long-press or a secondary gesture to pin/delete.

### Phase 4 — Quick File Shelf (with drag support)
- Drop files onto the Touch Bar to stash them temporarily; tap an item to reveal in Finder; drag back out to move them elsewhere.
- **Flag:** Touch Bar drag-and-drop is genuinely more limited than a full window — `NSTouchBarItem` drag support isn't as flexible as `NSDraggingDestination` on a regular window. This phase should start with a small throwaway prototype to confirm what's actually achievable (accept-drop-onto-Touch-Bar, and drag-out-of-Touch-Bar) before committing to the full interaction design. If full bidirectional drag turns out to be too limited, a fallback is: drop files onto the *menu bar icon* instead, with the Touch Bar just showing/managing what's already stashed.
- Staged files live in `~/Library/Application Support/<App>/Shelf/`.

### Phase 5 — Context-Aware App Switcher
- `NSWorkspace.didActivateApplicationNotification` listener swaps the active Touch Bar profile based on frontmost app.
- Define profiles per app (start with a handful hardcoded: IntelliJ IDEA, Terminal, Chrome, Finder), each with a small set of custom buttons (e.g. IntelliJ → Build/Run/Debug/Stop).
- Apps without a defined profile fall back to a default row (or the last "pinned" feature, e.g. clipboard strip).
- v1 profiles can be hardcoded in Swift; a later version could make this user-editable via the settings window.

### Phase 6 — Live CPU/RAM stats
- CPU usage via `host_processor_info`/`host_statistics`; RAM usage via `task_info`/`vm_statistics64` — all public Mach/IOKit APIs, no private API risk here.
- Compact numeric or mini-bar-graph Touch Bar item, updating on a short timer (careful with refresh rate — too frequent will hurt idle battery/CPU, which is ironic for a CPU monitor).
- Tap to expand into a slightly more detailed popover if there's room, otherwise keep it simple text (e.g. `CPU 12%  RAM 6.2/16GB`).

### Phase 7 — Study/Pomodoro Timer
- Countdown with start/pause/reset buttons, visible progress (could use a thin colored bar across part of the Touch Bar item to show time remaining).
- Optional: quick preset buttons (25/5, 50/10) since you're using this while doing coursework.
- Optional notification/sound when a session ends.

### Phase 8 — Polish & shipping
- Preferences window (SwiftUI `Settings` scene is fine here since it's a normal window, not the Touch Bar itself).
- Launch-at-login (`SMAppService`), consistent visual style across all Touch Bar items.
- Code signing (Developer ID), notarization, Sparkle appcast for updates.
- No analytics/telemetry by default.

---

## 5. Non-functional requirements
- **Idle resource use:** target <1% CPU, <100MB RAM idle — the clipboard poll timer and CPU/RAM stat refresh are the two features most likely to blow this budget if not tuned carefully.
- **Privacy:** clipboard history and file shelf stay 100% local; no network calls in v1 (no cloud sync features were requested this time).
- **Robustness:** if "App Controls" isn't enabled in System Settings, the app should clearly say so rather than silently doing nothing.
- **Battery awareness:** since this is a laptop-only feature, consider throttling refresh rates (stats, media polling) when on battery vs. plugged in.

---

## 6. Testing plan
- Unit tests: clipboard dedup logic, CPU/RAM stat calculation accuracy (compare against Activity Monitor), timer logic.
- Manual test matrix: Touch Bar visible/asleep states, external keyboard connected (Touch Bar behavior can differ), fullscreen apps, System Settings "App Controls" toggled on/off.
- Since you only have this one Touch Bar Mac, all manual testing happens on your actual hardware — build and run after every phase rather than batching multiple phases before testing.

---

## 7. Open questions — answer before starting

1. **macOS version** — what macOS is your 13" MacBook Pro actually running? This sets the real min deployment target (older Touch Bar Macs may be capped below macOS 14).
2. **Distribution** — just for yourself, or eventually for other Touch Bar Mac owners too? (Affects whether it's worth the $99/yr Apple Developer Program for proper Developer ID signing right away, vs. running unsigned/locally for now.)
3. **Private API comfort, confirmed** — you're OK with `MediaRemote.framework` for Phase 2. Same question extends lightly to Phase 1 if intercepting system volume/brightness keys ends up requiring anything undocumented — Codex should flag it if so, but this is usually achievable with public APIs.
4. **App Switcher profiles** — which apps do you actually want profiles for first? (IntelliJ IDEA, Terminal, Chrome, Finder were my guesses based on what I know you use — confirm or adjust.)
5. **File Shelf fallback** — if full Touch Bar drag-and-drop turns out to be too limited (see Phase 4 caveat), are you OK with the fallback design (drop onto menu bar icon, manage via Touch Bar)?
6. **Visual style** — any preference (minimal/monochrome vs. colorful, icon-only vs. icon+text labels)? Touch Bar real estate is tight, so this matters more here than on a notch app.

---

## 8. How to hand this to Codex
1. Answer the Open Questions above (quick answers are fine).
2. Paste this whole file as your first message to Codex, and add: *"Before writing any code, ask me every question in section 7, one at a time, and wait for my answers before starting Phase 0."*
3. Have Codex work **phase by phase**, committing and building after each one — don't let it batch multiple phases before you've tested on your actual Touch Bar.
4. Start with Phase 1 (Volume/Brightness) even though it's not the flashiest — it's the lowest-risk way to confirm the whole `NSTouchBar` pipeline works before building anything that depends on private APIs or drag-and-drop quirks.
