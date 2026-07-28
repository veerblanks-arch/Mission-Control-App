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

## Workflow

- Complete one phase at a time.
- Verify each phase on the target Mac.
- Commit locally after each accepted phase.
- Wait for explicit approval before starting the next phase.

## Phase status

- Phase 1: accepted and committed.
- Phase 2: implemented and tested in code; pending the target-Mac drag,
  multi-display, Space, and full-screen acceptance check.
