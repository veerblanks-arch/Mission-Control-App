# Mission Control

Mission Control is a native macOS menu-bar workspace for the things that
usually interrupt your flow: copied content, files, notes, screenshots,
terminal sessions, music, and AI coding tasks.

It stays out of the way until it is needed. Open the panel from the menu bar,
choose a focused tool, and return to the app you were using without managing a
collection of separate windows.

## What it does

- **Clipboard** keeps a searchable local history of text, images, and files.
  Pinned items can be retained while ordinary history expires automatically.
- **Shelf** stores references to useful files and folders without moving or
  deleting the originals.
- **Screenshots and snippets** support region capture, annotation, redaction,
  cropping, and copying the finished image back into the workspace.
- **File Finder** searches a selected favorite folder and supports Quick Look,
  opening, drag-out, Reveal in Finder, and Copy Path.
- **Notes** provides local searchable notes with autosave, Markdown export, and
  recoverable deletion.
- **Terminal** provides retained shell sessions for project commands and
  long-running jobs, with an Apple Terminal fallback.
- **Apple Music** exposes a compact player with artwork, transport controls, and
  progress while music is available.
- **Codex workspace** organizes project chats, starts new tasks with a project
  and role, shows live responses for tasks created in Mission Control, and
  opens external task history without pretending to own those sessions.
- **Unified Search** ranks results across Clipboard, Shelf, Files, and Notes.

## Design principles

Mission Control is built around a few boundaries:

- Local data stays local unless a feature explicitly needs an external service.
- File organization uses references, so a Shelf action does not alter the
  source file.
- Long-running work remains visible and cancellable instead of being hidden in
  a detached process.
- External AI tasks are clearly separated from tasks managed by the app.
- The interface is keyboard-friendly, accessible, and mindful of Reduced
  Motion preferences.

## Requirements

- macOS on Apple silicon
- Xcode with the macOS SDK and command-line tools
- Swift 5
- Apple Music automation permission for the music controls
- The normal macOS permissions required by the tools you choose to use

## Build

From the repository root:

```bash
./Scripts/build-debug.sh
```

The debug application is written to `Builds/MissionControl.app` by the current build
script. To run the debug target with the standard launch arguments, use:

```bash
./Scripts/run-debug.sh
```

To run the test suite in Xcode, select the `Droppy` scheme and run the tests.

## Project layout

```text
MissionControl/ Swift and AppKit application code
MissionControl/         Clipboard, Shelf, Files, Notes, Terminal, Music, and Codex
DroppyTests/             Unit and integration-focused tests
Scripts/                 Local build and debug helpers
Docs/                    Product decisions and implementation notes
```

Mission Control is a native AppKit application. Feature state is kept in
small, focused modules, while the menu-bar controller and overlay coordinate
the shared workspace surface.
