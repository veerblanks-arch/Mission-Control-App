# Droppy Native macOS Project Plan

## Product direction

Droppy is a native Swift/AppKit menu-bar productivity utility. It launches
quietly as an `LSUIElement` app with no Dock icon. Its ordinary status item can
be hidden by Ice. Clicking the item opens a resizable panel anchored beneath
the real menu-bar button.

Droppy does not keep a permanent fake island over the menu bar. The top-center
surface is contextual: it appears for file drags, screenshots, and Codex task
notifications, then dismisses according to the behavior of that feature.

## Core interaction

- Main panel: anchored below the Droppy status item, resizable, closes on
  click-away or Escape, and preserves drafts.
- Drop zone: appears at the top-center of the display under the cursor after a
  short drag hover. It accepts multiple files and folders.
- Shelf: stores persistent references to original files, ordered newest first.
  Adding the same path again updates its timestamp. Removing a reference never
  deletes the original file.
- Navigation: vertical icon rail for Clipboard, Shelf, Codex, Files, Notes,
  and Media. Snippet and Terminal are header actions.

## Feature decisions

### Clipboard and screenshots

- Searchable local history expires after seven days unless pinned.
- Sensitive, concealed, and transient pasteboard content is never stored.
- Clicking an item pastes into the previously active app.
- Text, images, and files can be dragged out.
- Vision OCR makes copied images and screenshots searchable.
- New screenshots enter Clipboard history, not the Shelf.

### Snippet

- Region capture is the default; window and full-screen capture are secondary.
- Annotation tools: pen, highlighter, arrow, rectangle, text, blur/redaction,
  crop, undo/redo, color, and thickness.
- Done saves only the annotated result to the configured screenshot folder,
  copies it, and adds it to Clipboard history.

### Files, notes, and terminal

- File Finder searches one user-selected favorite folder at a time.
- Defaults include Downloads, Documents, Desktop, and the screenshot folder.
- Files support Quick Look, open, drag-out, Reveal in Finder, and Copy Path.
- Notes are separate, local, searchable, autosaved, and exportable. Deleted
  notes remain recoverable for 30 days.
- Droppy includes an embedded command runner for project scripts, streaming
  output, and long-running jobs. Apple Terminal remains the default external
  terminal, with configurable adapters later.
- New command sessions start in the current favorite folder or selected Codex
  project.

### Media

- Media supports Music and Spotify through their local automation interfaces.
- Private `MediaRemote` is not part of the active implementation.

### Codex

- Integrate through the supported Codex App Server, not private database reads.
- Show three tasks by default, with search for the rest.
- Show task title, project, status, model, recent exchange, and account usage.
- A visible Send button submits replies. `Command-Return` is optional.
- File drops open a reviewable new-task composer. Images attach directly;
  other files are passed as local paths.
- New tasks use the current Codex default model.
- Approvals, destructive actions, shell commands, and model changes stay in
  Codex.
- Completed and permission-waiting tasks use menu-icon-sized top-center agents.
  They remain until clicked, open the matching Codex task, and use a brief exit
  animation. Reduced Motion uses static poses and fades.

## Delivery phases

1. Recovery: remove legacy Touch Bar/private APIs, organize documentation,
   restore the anchored panel and silent launch, add a reliable build workflow,
   and add baseline tests.
2. Drop Zone and Shelf.
3. Clipboard and Screenshots.
4. Snippet.
5. Files, Notes, Terminal, and unified search.
6. Media.
7. Codex.
8. Polish, accessibility, performance, launch at login, settings, motion
   design, and a cohesive app-wide color theme.

Each phase must build successfully, be tested on the target Mac, receive a
local Git commit, and wait for explicit user approval before the next phase.

## Current checkpoint

Phase 5 is implemented and awaiting acceptance.

Files adds bookmark-backed favorite folders, defaulting to Downloads,
Documents, Desktop, and the configured screenshot folder. It browses the
selected folder, performs cancellable recursive search capped at 200 results,
skips hidden files and package descendants, and supports open, Quick Look,
drag-out, Reveal in Finder, and Copy Path. Unreadable saved favorites are never
overwritten.

Notes is local, searchable, autosaved with debounced atomic writes, exportable
as Markdown, and uses a recoverable Trash with automatic cleanup after 30 days.
Pending edits flush when Droppy quits, and unreadable note archives are preserved
rather than treated as empty.

Terminal is a compact header action backed by SwiftTerm 1.11.2 and a real PTY.
It supports multiple retained zsh sessions, long-running commands, ANSI output,
Control-C, clear, restart, selectable working folders, and an Apple Terminal
fallback. Closing the overlay does not stop its sessions; quitting Droppy warns
before stopping running shells and their child processes. Restart and quit wait
for the old process tree to exit. A second normal app launch leaves the existing
instance and its sessions untouched.

Unified search is a separate header action that groups ranked Clipboard, Shelf,
Files, and Notes results and opens the correct destination. Empty queries do no
work, and stale file searches are cancelled.

Fifty-one automated tests pass. The canonical build is
`Builds/Droppy.app`; its live process path was verified after replacing the
previous running copy. Phase 5 still needs the target-Mac interaction acceptance
check before it is considered accepted.

The final polish phase must include purposeful animations across feature
transitions and contextual overlays, plus a consistent color theme. Reduced
Motion must retain clear state changes without movement-heavy effects.
