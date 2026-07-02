# Project Plan: Native macOS Notch Productivity App
**For: Codex (coding agent) | Prepared by: Ranveer's planning session with Claude**

## 0. Important framing note (read first)
This spec describes an **original app inspired by the general "notch utility" category** (Droppy, NotchNook, Notchmeister, Boring Notch, etc. are all examples of this genre). It is written from scratch — no source code, copy, branding, icons, or names from any existing app should be copied. Codex should:
- Pick its **own app name and icon** (suggestions in §9).
- Build functionality independently from the written spec below, not by decompiling or scraping another app.
- Treat any resemblance to existing apps as "same category of tool," not "clone the codebase."

This keeps the project on solid legal ground and also just makes for a better, maintainable Xcode project instead of a black-box copy.

---

## 1. Goal
A native macOS **background/menu-bar app** that turns the MacBook's notch and surrounding screen area into a productivity hub with:
1. **Notch Shelf** — drag files into the notch to stash them temporarily.
2. **Floating Basket** — a drop zone summoned anywhere via a "mouse jiggle" gesture while dragging.
3. **Clipboard Manager** — searchable history with OCR on images.
4. **Notch Media Player** — Now Playing controls rendered in the notch.
5. **Custom HUDs** — replacement volume/brightness overlays.

Must be a **real .app bundle built in Xcode with Swift/SwiftUI + AppKit**, code-signed and notarized — not an Electron/web wrapper, not a browser-based HTML tool.

---

## 2. Tech stack (required)
- **Language:** Swift 5.9+
- **UI:** SwiftUI for panel content, AppKit (`NSPanel`, `NSWindow`, `NSStatusItem`) for window management — SwiftUI alone cannot do borderless notch-hugging overlays or global drag tracking.
- **IDE/build:** Xcode project (`.xcodeproj` or Swift Package with an app target), not just a Swift script.
- **Min deployment target:** macOS 14 (Sonoma) — simplifies APIs; document macOS 13 fallback only if Ranveer wants broader compatibility.
- **Frameworks:**
  - `AppKit` — windowing, dragging, global event monitors
  - `Vision` — on-device OCR for clipboard images
  - `AVFoundation` / `MediaPlayer` — Now Playing info (see §7 caveat on private APIs)
  - `Core Graphics` — notch geometry, custom drawing
  - `Combine` or `async/await` — state management
  - `SQLite` via `GRDB.swift` (or Core Data) — clipboard history persistence
- **No sandbox restriction issues:** since this app needs Accessibility permissions, global event taps, and arbitrary file access, it should be distributed **outside the Mac App Store** (Developer ID + notarization), same as most notch utilities. This must be decided up front — see Open Question #2.
- **Auto-update:** Sparkle framework (industry standard for non-MAS Mac apps).

---

## 3. App architecture
```
NotchApp/
├── App/
│   ├── AppDelegate.swift          # LSUIElement = true, lifecycle, permission prompts
│   ├── NotchApp.swift             # @main entry
├── Core/
│   ├── NotchGeometry.swift        # detect notch bounds via NSScreen.safeAreaInsets
│   ├── WindowManager.swift        # manages all floating NSPanels
│   ├── PermissionsManager.swift   # Accessibility, Screen Recording, Full Disk Access
├── Features/
│   ├── NotchShelf/
│   ├── FloatingBasket/
│   ├── ClipboardManager/
│   ├── MediaPlayer/
│   ├── HUDs/
├── Extensions/                    # plugin system, see §6
├── Storage/
│   ├── ClipboardStore.swift       # SQLite/GRDB layer
│   ├── Settings.swift             # UserDefaults / AppStorage
├── Resources/
└── NotchAppTests/
```

- App runs as an **accessory app** (`NSApp.setActivationPolicy(.accessory)`), no Dock icon, lives in the menu bar.
- Notch overlay window: borderless `NSPanel`, `.floating` level, positioned using `NSScreen.main.safeAreaInsets` / `auxiliaryTopLeftArea` (available on notched Macs) to get exact notch bounds.
- On non-notched Macs, gracefully degrade: shelf becomes a menu-bar dropdown instead of a notch overlay (Open Question #3).

---

## 4. Feature breakdown & build phases

### Phase 0 — Scaffolding (½–1 day)
- New Xcode project, bundle ID, signing team, `LSUIElement`, menu bar status item with a settings/quit menu.
- Basic permissions onboarding screen (Accessibility access request, explain why).
- CI-friendly build (xcodebuild scheme) so Codex can build/test headlessly.

### Phase 1 — Notch Shelf (MVP)
- Detect notch geometry per-display; support multi-monitor (shelf only shows on the built-in display).
- Borderless panel that visually "hugs" the notch, expands on hover/drag-enter.
- `NSDraggingDestination` to accept files dropped near the notch.
- Temporary in-memory + on-disk staging folder (`~/Library/Application Support/<App>/Shelf/`) for stashed files.
- Right-click context menu on stashed items: Move, Copy, Share, Compress (zip), Convert (basic image/video format conversion via `sips`/`ffmpeg`-free native APIs where possible).
- Spring-based expand/collapse animation (SwiftUI `.spring()` or Core Animation).
- Auto-hide in fullscreen apps (`NSWorkspace` fullscreen notifications).

### Phase 2 — Floating Basket
- Global `NSEvent.addGlobalMonitorForEvents` to detect "mouse jiggle" (rapid direction reversals) while a drag session is active (`NSDraggingSession` state).
- Summon a floating drop-zone panel at cursor location.
- Support multiple simultaneous baskets.
- "Watched folder" support: user designates a folder; new files auto-populate a basket (via `DispatchSource` file-system events / `FSEvents` API).

### Phase 3 — Clipboard Manager
- Poll `NSPasteboard.general.changeCount` (no public "clipboard changed" notification exists — polling on a timer, e.g. every 0.3–0.5s, is the standard approach).
- Store history in SQLite (via GRDB) with type (text/image/file), timestamp, source app, pin/favorite flag, tags.
- Rich preview UI (text snippet, image thumbnail).
- OCR: run `VNRecognizeTextRequest` (Vision framework) on copied/dragged images, entirely on-device.
- "Drag-out OCR": holding Shift while dragging an image out converts it to extracted text on drop.
- Basic built-in screenshot annotation editor (optional — mark as stretch goal, Open Question #6).
- Full keyboard navigation (arrow keys + Enter to paste) via a global hotkey (e.g. `Cmd+Shift+V`) using `Carbon.HIToolbox` hotkey registration or a library like `HotKey`.

### Phase 4 — Notch Media Player
- **Caveat to flag to Codex explicitly:** there is no public, sandbox-safe API for reading *other apps'* Now Playing info. Real-world notch apps typically use the private `MediaRemote.framework` (reverse-engineered, works but Apple could break it any OS update, and it's technically outside public API surface). Options, in order of "safeness":
  1. **Safest/simplest:** only control/display Now Playing for apps that support `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter` integration your app can query — this is limited.
  2. **Common in practice:** link against `MediaRemote.framework` privately (this is what most menu-bar Now Playing apps, including well-known ones, actually do). Not App-Store-safe, fine for Developer-ID distribution.
  3. Document this choice as a decision Ranveer needs to sign off on (Open Question #4) since it affects long-term maintenance risk.
- Render album art, track title/artist, seek scrubber, play/pause/skip inside the notch panel.

### Phase 5 — Custom HUDs
- Volume/brightness overlays that replace the system HUD. Note: fully suppressing the *system's* native HUD isn't officially supported either — most apps achieve this via a private/undocumented technique or simply render their HUD on top/instead visually convincingly. Flag as another "uses undocumented behavior" item (same Open Question #4 bucket).
- Listen for volume/brightness key events (`NSEvent` local monitor for media keys, or `CGEventTap`).
- Animated slider UI matching your own design language (not copying anyone else's visual style).

### Phase 6 — Extension/plugin system
- Define a lightweight `NotchExtension` protocol (id, icon, SwiftUI view, lifecycle hooks).
- Load built-in "extensions" the same way third-party ones would be loaded later (even if you don't ship a public plugin SDK on day one).
- Example first-party extensions to build: Pomodoro timer, weather, quick notes.

### Phase 7 — Settings, permissions, onboarding
- Preferences window (SwiftUI `Settings` scene): toggle each feature independently, hotkey customization, launch-at-login (`SMAppService`).
- Guided permission requests: Accessibility (for global event monitoring), Screen Recording (only if you add a screenshot tool).

### Phase 8 — Polish & shipping
- App icon, consistent spring-animation curve across all panels (define one `Animation` constant reused everywhere).
- Code signing (Developer ID Application cert) + notarization (`notarytool`) + stapling.
- Sparkle appcast for auto-updates.
- No analytics/telemetry by default (privacy-respecting, matches the good practice seen across this app category).
- Basic crash-reporting opt-in only (e.g. Sentry, off by default).

---

## 5. Non-functional requirements
- **Idle resource use:** target <1% CPU and <100MB RAM when idle (clipboard polling and event monitors are the main risk here — Codex should benchmark this).
- **Privacy:** OCR and clipboard storage stay 100% local; no network calls unless explicitly building the optional cloud file-share feature (see Open Question #7).
- **Compatibility:** macOS 14+; notch-only features degrade gracefully on non-notch Macs (menu-bar fallback UI).
- **Stability:** app must never crash from a malformed drag payload or a denied permission — always fail into a visible "permission needed" state, never silently.

---

## 6. Data & storage
- Clipboard DB: local SQLite file, not iCloud-synced by default (avoid the complexity/privacy questions of syncing clipboard data across devices unless requested).
- Shelf files: staged under `~/Library/Application Support/<App>/Shelf/`, cleared on demand or after a configurable retention period.
- Settings: `UserDefaults`/`@AppStorage`.

---

## 7. Distribution
- Direct download DMG, Developer ID signed + notarized (Apple Developer Program membership required, $99/yr).
- Not distributed via Mac App Store initially (App Sandbox would block global event monitoring, arbitrary file shelf access, and the private MediaRemote usage). This is a real trade-off to confirm with Ranveer.

---

## 8. Testing plan
- Unit tests: notch geometry detection, clipboard dedup logic, OCR pipeline (mock Vision results).
- Manual test matrix: notched MacBook (14/16" Pro, Air), non-notch Mac fallback, multi-monitor, fullscreen-app auto-hide, permission-denied states.

---

## 9. Suggested original app names (pick one, avoid anything close to existing notch apps)
`Nook`, `Aperture Bar`, `Slot`, `Wedge`, `Hollow`, `Inlet` — any of these are fine starting points; final naming/trademark search is Ranveer's call.

---

## 10. Open questions — please answer before handing this to Codex

**Scope**
1. Do you want all 5 features (Shelf, Basket, Clipboard, Media Player, HUDs) in v1, or should Codex build an MVP first (I'd suggest: Shelf + Clipboard first, since those are the highest-value, lowest-API-risk features) and add the rest in later phases?
2. Should this be free-forever / open source, or do you want a licensing gate (e.g. free tier + paid "Pro" unlock) built in from the start?

**Technical risk tolerance**
3. Are you okay with the app requiring Accessibility permissions and running outside the Mac App Store (Developer ID distribution)? This is basically required for the Basket/global-jiggle-detection and clipboard-polling features to work at all.
4. Are you okay with Codex using the **private, undocumented** `MediaRemote.framework` for Now Playing info in the notch, and undocumented techniques for suppressing the system volume/brightness HUD? These are widely used in this app category but are not officially supported by Apple and could break on a future macOS update. If you'd rather avoid private APIs entirely, the Media Player and custom HUD features would need to be cut or significantly scaled back for v1.

**Hardware/testing**
5. Do you have a notched MacBook to actually test on (this whole project only makes visual sense on 2021+ MacBook Pro/Air), or is this being built for eventual distribution to others too?

**Feature depth**
6. Do you want the built-in screenshot annotation editor in v1, or is that a "nice to have later"?
7. Any interest in a cloud/temporary-file-sharing feature (generating shareable links), which would require a backend (e.g. Supabase) and therefore network calls/hosting costs — or should everything stay 100% local/offline?
8. Do you want a plugin/extension architecture from day one, or should extensions just be a handful of first-party features baked in (simpler, faster to ship)?

**Design**
9. Any preferences on visual style (glassmorphism/blur, flat/solid, light-only vs. full dark mode support)? Codex will need some direction here since we're intentionally not copying anyone else's visual design.

---

## 11. How to hand this to Codex
1. Answer the Open Questions above (even short answers are fine — "MVP first, Shelf+Clipboard only, okay with private APIs, testing on my M3 MacBook Pro, no cloud, no plugin system yet, dark mode default").
2. Paste this whole file into Codex as the task brief, or point Codex at the file directly if it has filesystem access.
3. Ask Codex to work **phase by phase** (Phase 0 → Phase 1 → ...), committing after each phase, rather than attempting everything in one pass — this keeps the codebase reviewable and buildable at every step.
4. After each phase, actually build and run the app on your Mac before moving to the next phase — several of these features (notch geometry, drag detection, permission prompts) are very hard to verify without real hardware testing.
