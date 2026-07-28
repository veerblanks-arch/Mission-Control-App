# Current Decisions

Date: 2026-07-28

## Recovery

- Continue as a native Swift/AppKit app, not Tauri.
- Remove the abandoned Touch Bar implementation and private APIs from the
  active project. Git history remains the archive.
- Keep the Xcode project at the repository root.
- Store historical plans and stopping notes in `Docs/Archive`.
- Launch quietly with no Dock icon and no automatic panel.
- Keep a standard status item so Ice can hide and reveal it.
- Clicking the status item opens a resizable panel anchored beneath it.
- Clicking outside or pressing Escape closes the panel without losing drafts.

## Drop Zone and Shelf

- Replace the old Floating Basket with one top-center drop zone.
- Activate only in a roughly 300-point top-center region after a short hover.
- Follow the drag across displays and work over full-screen apps and Spaces.
- Accept multiple files and folders.
- Store references, not copies.
- Persist references until removed.
- Sort newest first and deduplicate by path.
- A small minus button removes only the reference.
- After a drop, show confirmation briefly and close after about two seconds.
- Persist ordinary file bookmarks plus a last-known path in a versioned JSON
  archive under Application Support.
- Keep unavailable references visible so they can still be inspected or
  removed.
- Defer promised-file imports from third-party apps until a later phase; Phase
  2 accepts concrete file and folder URLs from Finder.

## Data and integrations

- Clipboard history: seven days, searchable, pinned items retained.
- Calendar: EventKit.
- Media: Music and Spotify first.
- Codex: official App Server, safe dashboard and replies first.
- Notes: separate and local.
- Terminal: Apple Terminal by default, configurable later.
- Unified search excludes Calendar.

## Clipboard and screenshots

- Begin from a pasteboard baseline on launch; never import the item that was
  already copied before monitoring started.
- Capture text with its rich representations, images, files, and screenshots.
- Treat differently formatted text as separate entries.
- Refresh the capture age when an exact item is copied again. Clicking or
  dragging an existing item does not refresh its age.
- Retain unpinned items for seven days, up to 200 items and 1 GiB of cached
  payload data. Pins are exempt; unpinning starts a fresh seven-day period.
- Keep the encrypted index and encrypted per-item payloads under Application
  Support. Keep the AES-GCM key in the login Keychain.
- Refuse to create a replacement key when encrypted history already exists but
  its key is missing.
- Migrate only the last seven days of non-screenshot legacy plaintext history,
  verify the encrypted archive, then remove the plaintext archives.
- Never store concealed, transient, auto-generated, or known password-manager
  pasteboards.
- Seed common password managers in a configurable private-app exclusion list.
- Pause skips clipboard changes, screenshot discovery, and pending OCR until
  explicit resume. Paused content is never caught up.
- Follow the configured macOS screenshot location and also inspect an immediate
  `Screenshots` child folder.
- Cache screenshots independently from the original and never delete the
  original when history is removed.
- Show a top-center screenshot confirmation for 0.8 seconds; clicking it opens
  Clipboard focused on that screenshot.
- Use a header selection mode for Select All, Pin, Unpin, and Delete.
- Ordinary and bulk deletion have no confirmation and offer Undo for five
  seconds. Clear History preserves pins. Clear Everything requires
  confirmation.
- Clicking restores the item and attempts to paste into the previous app.
  Request Accessibility only when automatic paste is first needed; copying
  remains the fallback.
- A completed drag closes the panel. A cancelled drag leaves it open.

## Polish

- Defer the full aesthetic pass until Phase 8.
- Add purposeful animations for panel navigation, contextual overlays, and
  success or attention states.
- Establish a cohesive app-wide color theme while preserving system contrast
  and Reduced Motion behavior.

## Workflow

- Complete one phase at a time.
- Verify each phase on the target Mac.
- Commit locally after each accepted phase.
- Wait for explicit approval before starting the next phase.

## Phase status

- Phase 1: accepted and committed.
- Phase 2: implemented and tested in code; pending the target-Mac drag,
  multi-display, Space, and full-screen acceptance check.
- Phase 3: implemented and verified in code and on the target Mac; awaiting
  user acceptance before Phase 4.
