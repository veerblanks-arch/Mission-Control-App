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
  Calendar, and Media. Snippet and Terminal are header actions.

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
- Apple Terminal is the default terminal, with configurable adapters later.
- Terminal opens in the current favorite folder or selected Codex project.

### Calendar and media

- Calendar uses EventKit and the accounts already configured in macOS.
- Calendar is excluded from unified search.
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
6. Media and Calendar.
7. Codex.
8. Polish, accessibility, performance, launch at login, settings, motion
   design, and a cohesive app-wide color theme.

Each phase must build successfully, be tested on the target Mac, receive a
local Git commit, and wait for explicit user approval before the next phase.

## Current checkpoint

Phase 3 is implemented. Clipboard history now captures only changes made after
monitoring starts, skips sensitive pasteboards and configured private apps,
stores its index and payloads with Keychain-backed AES-GCM encryption, and
enforces seven-day, 200-item, and 1 GiB unpinned limits. Pins are exempt.

The Clipboard panel supports search, type filters, pinned and history sections,
click-to-paste, successful-drop-aware drag-out, pause/resume, private-app
editing, bulk pin/unpin/delete, five-second deletion undo, Clear History, and a
confirmed Clear Everything action. Vision OCR indexes images locally.

Droppy follows the macOS screenshot location and its immediate `Screenshots`
subfolder. New screenshots are cached into encrypted Clipboard storage and
produce a clickable top-center confirmation lasting 0.8 seconds. Removing
history never removes the original screenshot.

Nineteen automated tests pass. Target-Mac checks verified live clipboard
capture, pause with no resume catch-up, bulk deletion and payload cleanup,
pickup from `~/Documents/Screenshots`, encrypted at-rest storage, and cached
screenshot survival after the source moved. Automatic paste after Accessibility
approval and the confirmation generated by an actual screenshot keyboard
shortcut remain manual acceptance checks.

The final polish phase must include purposeful animations across feature
transitions and contextual overlays, plus a consistent color theme. Reduced
Motion must retain clear state changes without movement-heavy effects.
