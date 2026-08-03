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
- Navigation: vertical icon rail for Clipboard, Shelf, Codex, Files, and Notes.
  Snippet and Terminal are header actions.

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

### Apple Music mini-player

- Phase 6 supports Apple Music only through its local automation interface.
  Private `MediaRemote` and network artwork loading are not part of the active
  implementation.
- There is no Media navigation tab, full Media page, source switcher, or
  separate top-center desktop island.
- A compact mini-player appears directly below the header across every panel
  surface, including Search and Terminal.
- The mini-player reserves no space and stays completely hidden unless Apple
  Music has a ready snapshot. A paused track remains visible.
- It shows artwork, a one-line title and artist, previous, play/pause, next, and
  a thin seek/progress control. Clicking its artwork or title opens Apple Music.
- Music artwork uses an in-memory cache. Unavailable and Automation-permission
  states keep the mini-player hidden. Command or seek failures that occur while
  it is visible use a compact warning with tooltip and accessibility details.
- Polling follows the panel lifecycle: it starts when the panel opens and stops
  and cancels active work when the panel closes. An active lifecycle-generation
  gate prevents a stale polling timer from reviving after closure.

### Codex

- Integrate through the supported Codex App Server, not private database reads.
- Show the recent APUSH, Bitwise, and Droppy project groups ordered by activity,
  followed by one `Normal Chats` group for temporary, one-off, older-project,
  and otherwise unmatched working directories. Each group expands to show all
  of its non-archived chats; thread-list pagination must be followed until
  exhausted rather than stopping at the first page. Project search may surface
  `Normal Chats` when one of its original working directories matches.
- Show Codex-created tasks as read-only saved history: task title, project,
  status, recent exchange, and model when available. Opening an external task
  never resumes it.
- Droppy-created tasks remain live in Droppy: the active response streams into
  the opened chat, and each idle task accepts follow-up messages and file
  attachments through the same App Server. After relaunch, a still-managed
  saved task is resumed only when the user sends a new reply.
- `Hand Off` is available after the current response finishes. It unsubscribes
  Droppy, removes the local role ownership, and only then opens the task in
  Codex. Droppy persists the handed-off task's original role. When the task is
  idle, `Bring Back` resumes that same thread through Droppy's App Server,
  restores the role, reloads its history, and makes replies live in Droppy
  again. Tasks that did not originate in Droppy remain read-only.
- Show remaining account capacity as a simple percentage (`100 - usedPercent`).
  Keep it visible in both the dashboard and opened chats.
- File drops open a reviewable new-task composer. Images attach directly;
  other files are passed as local paths. Task creation retains project search,
  role, attachments, and usage indicators.
- New tasks choose a project and one of four roles: Planner, Builder A,
  Builder B, or Reviewer. The project picker is limited to APUSH, Bitwise, and
  Droppy, with `Choose Folder...` available for an intentional one-off path.
  Tasks use the current Codex default model.
- A single compact four-pet strip sits at the top right beside the Droppy logo
  and remains visible even when no chats are running. Planner is an owl,
  Builder A a beaver, Builder B a fox, and Reviewer a cat. The menu-bar masks
  render white at high contrast; opened task rows retain the full pet artwork.
  Clicking a pet opens its running-chat dropdown; an idle role shows
  `No running chats`.
- The four-pet strip represents only Droppy-managed active tasks.
  External tasks have a generic chat identity and no invented agent role.
- A completed Droppy-managed task briefly highlights its exact chat row and, if
  open, its chat status banner. The role-strip icon does not animate. Reduced
  Motion keeps the completion state static instead of scaling the row.
- Approvals, destructive actions, shell commands, and model changes stay in
  Codex. Protected approval and input prompts are cancelled safely by the
  integration.
- A bounded App Server reconnect handles transient process exits.
- A newly started task is shown from its accepted turn immediately instead of
  reading the just-created rollout synchronously. Background history reads
  retry only the transient empty-session-metadata error with bounded backoff;
  other thread-read errors remain visible.
- A separate supported App Server process cannot claim live status for chats
  currently owned by the Codex desktop runtime. In the live check, the Desktop
  task was active while Droppy's separate App Server reported `notLoaded` but
  could read the persisted history. Existing external tasks therefore remain
  read-only saved history in Droppy and are not treated as live by the role
  strip.
- OpenAI's first-party Remote connections can continue the same host chats from
  a paired ChatGPT mobile app. The current App Server schema exposes remote
  status but no client request for third-party pairing or relay takeover, so
  Droppy does not present that private first-party path as an integration API.

## Delivery phases

1. Recovery: remove legacy Touch Bar/private APIs, organize documentation,
   restore the anchored panel and silent launch, add a reliable build workflow,
   and add baseline tests.
2. Drop Zone and Shelf.
3. Clipboard and Screenshots.
4. Snippet.
5. Files, Notes, Terminal, and unified search.
6. Apple Music mini-player.
7. Codex.
8. Polish, accessibility, performance, launch at login, settings, motion
   design, and a cohesive app-wide color theme.

Each phase must build successfully, be tested on the target Mac, receive a
local Git commit, and wait for explicit user approval before the next phase.

## Current checkpoint

Phase 5 is accepted and committed. The main implementation is recorded in
commit `3e8d2e7`, with the accepted Notes editing and Terminal working-directory
fixes in commit `f74cb03`.

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
fallback. Fresh sessions start in the user's home folder, while new tabs created
from an existing session retain that session's working folder. Closing the
overlay does not stop its sessions; quitting Droppy warns before stopping running
shells and their child processes. Restart and quit wait for the old process tree
to exit. A second normal app launch leaves the existing instance and its sessions
untouched.

Droppy's accessory-app menu includes the standard macOS editing commands so
keyboard cut, copy, paste, undo, redo, and Select All work in Notes and other
text fields.

Unified search is a separate header action that groups ranked Clipboard, Shelf,
Files, and Notes results and opens the correct destination. Empty queries do no
work, and stale file searches are cancelled.

Fifty-three automated tests pass. The canonical build is
`Builds/Droppy.app`; its live process path was verified after replacing the
previous running copy. The user completed the target-Mac interaction acceptance
check and explicitly authorized Phase 6.

Phase 6 is implemented and accepted. The user accepted the live target-Mac
result on 2026-08-01. The final
scope is an Apple Music-only mini-player directly below the header across every
panel surface, including Search and Terminal. There is no Media navigation tab,
full Media page, source switcher, Spotify integration, network artwork loader,
or separate top-center desktop island.

The mini-player stays completely hidden without reserving space until Apple
Music has a ready snapshot; paused tracks remain visible. It shows artwork, a
one-line title and artist, previous, play/pause, next, and a thin seek/progress
control. Clicking its artwork or title opens Apple Music. Unavailable-player and
Automation-permission states keep it hidden; command and seek failures use a
compact warning while a ready snapshot remains visible.

Polling starts when the panel opens and stops and cancels active work when the
panel closes. The reviewer-reported timer race is fixed by gating polling
callbacks on the active panel lifecycle generation.

Eleven focused Apple Music tests passed after the reviewer feedback fix for
compact command-error presentation, and the canonical `Builds/Droppy.app` build
succeeded. The target-Mac Apple Music and mini-player UI result was accepted by
the user.

Phase 7 Codex is implemented and verified in code, but target-Mac acceptance
and the local commit are pending. It must not be treated as accepted yet.
The verified scope includes the recent-project expandable dashboard with a
single `Normal Chats` fallback, project-only search, project-and-role task
creation limited to APUSH, Bitwise, and Droppy plus `Choose Folder...`, a
saved-history viewer with `Open in Codex`,
remaining capacity in the dashboard and opened histories, exact returned model
caching for Droppy-started tasks, live follow-up messages for Droppy-owned
tasks, bidirectional persisted `Hand Off`/`Bring Back` mobility using
unsubscribe and resume, the top-right
four-pet strip for Droppy-managed active tasks, generic identity for external tasks,
exact-chat completion feedback with Reduced Motion, and the persisted-history
live-status finding documented above. The final mobility pass executed 78
tests with zero failures, and `Scripts/build-debug.sh` produced the canonical
`Builds/Droppy.app` successfully. Target-Mac acceptance and the local commit
remain pending.

The final polish phase must include purposeful animations across feature
transitions and contextual overlays, plus a consistent color theme. Reduced
Motion must retain clear state changes without movement-heavy effects.
