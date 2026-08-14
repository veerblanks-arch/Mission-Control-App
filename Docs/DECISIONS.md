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
- Calendar is out of scope; use the existing calendar app directly.
- Media: Apple Music mini-player only; no separate navigation destination.
- Codex: official App Server. Codex-created tasks remain read-only saved
  history in Silverdeck and opening them never resumes them. Silverdeck-created
  tasks support streamed responses and follow-up turns while
  Silverdeck owns them. `Hand Off` calls `thread/unsubscribe`, atomically
  records handed-off ownership, and then opens Codex. Silverdeck remembers
  that task's visual label, and an idle handed-
  off task can use `Bring Back` to call `thread/resume`, restore its original
  label, reload the same history, and accept live Silverdeck replies again.
  Tasks that originated outside Silverdeck remain read-only. A separate supported App
  Server process cannot reliably report live status for chats currently owned
  by the Codex desktop runtime, so take-back is blocked whenever the observed
  status is active and rechecked after resume.
- Four visual task labels use a generated miniature pet family inside the Codex
  dashboard: Planner owl, Builder A beaver, Builder B fox, and Reviewer cat.
  Silverdeck creates no extra agent or pet menu-bar items.
- New threads pin an `on-request` approval policy and a `workspace-write`
  sandbox mode; turns use the structured `workspaceWrite` sandbox policy.
  restricted to the selected project with network disabled. Command, file, and
  permission approvals are shown as one-time decisions in Command Mode, and
  supported Codex questions can be answered there. Unsupported protected
  requests are rejected safely and remain visible as task issues.
- New-task UI uses the accepted `thread/start` and `turn/start` state directly;
  it does not immediately depend on a readable rollout file. History loading
  retries only the known transient empty-session-metadata race.
- Notes: separate and local.
- Terminal: embedded command runner for project scripts, with Apple Terminal
  as the default external fallback and configurable adapters later.

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
- Image and screenshot drag exports remain in Droppy's cache for one day so
  delayed chat uploads can still read them. Clean up expired exports on launch,
  on future exports, and after the retention interval while Droppy remains open.

## Polish

- Defer the full aesthetic pass until Phase 9.
- Add purposeful animations for panel navigation, contextual overlays, and
  success or attention states.
- Establish a cohesive app-wide color theme while preserving system contrast
  and Reduced Motion behavior.

## Snippet

- Keep Snippet as a header action rather than a navigation-rail feature.
- Use the native macOS capture service for region, window, and active-display
  selection. Captures remain temporary until the editor finishes.
- Keep region capture as the primary button and expose all three modes in its
  adjacent menu.
- Provide pen, highlighter, arrow, rectangle, text, blur, opaque redaction,
  crop, undo/redo, color, and thickness controls.
- Keep freehand strokes mutable while drawing and commit one history action on
  mouse-up.
- Save only the flattened annotated PNG. Prefer the configured macOS screenshot
  folder's existing immediate `Screenshots` child.
- Copy and ingest the result through Clipboard's explicit generated-screenshot
  path so it is encrypted, OCR-indexed, and notified exactly once.
- Suppress only the generated snippet path from passive screenshot discovery;
  never advance the global screenshot checkpoint to hide a duplicate.
- Request Screen Recording only after an explicit capture action. When access
  is unavailable, offer the correct System Settings destination and require a
  relaunch after the permission changes.

## Apple Music mini-player

- Support Apple Music only through its local automation interface. Do not use
  Spotify, source switching, `MediaRemote`, or a network artwork loader.
- Remove the Media navigation tab and full Media page. Do not add a separate
  top-center desktop island.
- Show the compact mini-player directly below the header across every panel
  surface, including Search and Terminal.
- Hide it completely without reserving space until Apple Music has a ready
  snapshot. Keep a paused track visible.
- Show artwork, a one-line title and artist, previous, play/pause, next, and a
  thin seek/progress control. Clicking the artwork or title opens Apple Music.
- Keep Music artwork in an in-memory cache. Unavailable-player and
  Automation-permission states keep the mini-player hidden. Represent command
  and seek failures with a compact warning while a ready snapshot remains shown.
- Own polling with the panel lifecycle: start when the panel opens, then stop
  polling and cancel active work when it closes.
- Gate polling callbacks on the active lifecycle generation so an invalidated
  timer cannot revive polling after the panel closes.

## Workflow

- Complete one phase at a time.
- Verify each phase on the target Mac.
- Commit locally after each accepted phase.
- Wait for explicit approval before starting the next phase.

## Phase status

- Phase 1: accepted and committed.
- Phase 2: implemented and tested in code; pending the target-Mac drag,
  multi-display, Space, and full-screen acceptance check.
- Phase 3: accepted and committed.
- Phase 4: accepted and committed. Clipboard image drag exports received a
  post-acceptance lifetime fix after a delayed Codex upload exposed premature
  temporary-file cleanup.
- Phase 5: accepted and committed. Commit `3e8d2e7` contains the phase
  implementation, and commit `f74cb03` contains the accepted Notes editing and
  Terminal working-directory fixes. Fifty-three tests passed, and the canonical
  `Builds/Droppy.app` process was verified running.
- Phase 6: accepted by the user on 2026-08-01. Its local checkpoint records the
  compact Apple Music mini-player only, with no
  Media navigation tab, full Media page, Spotify integration, or source
  switching. Eleven focused Apple Music tests passed, the canonical
  `Builds/Droppy.app` build succeeded, and the user accepted the live target-Mac
  result.
- Phase 7 Codex: accepted, committed, and pushed in `4393df5`. Existing tasks
  are read-only saved history in Droppy and opening them never resumes them;
  Droppy-owned tasks support streamed responses and follow-up turns through
  its App Server, while `Hand Off` unsubscribes Droppy before opening Codex.
  The verified
  scope retains project search, role, attachments, and usage indicators; the
  dashboard groups the complete paginated non-archived task history into APUSH,
  Bitwise, Droppy, and a single `Normal Chats` fallback, with each group
  expanding to show all of its chats; the
  New Task picker offers only APUSH, Bitwise, and Droppy, plus an intentional
  `Choose Folder...` escape hatch; the
  pet roles remain inside the Codex dashboard without adding a second
  multi-icon status-bar item; and
  external tasks have a generic chat identity with no invented agent role.
  Completion feedback briefly highlights the exact chat row and open-chat
  banner. The live check found the Desktop task
  active while Droppy's separate App Server reported `notLoaded` but could read
  persisted history. The final four-lane review pass executed 84 tests with
  zero failures. The visible identity remains Silverdeck while the internal
  `Builds/Droppy.app` path is preserved for encrypted clipboard Keychain
  compatibility; the runner targets that exact repository path and never kills
  a separately installed Droppy app.
- Post-Phase-7 Notion connector: committed and pushed in `f6f406d`. The tab
  opens Notion Calendar and Notion home and stores configurable Notion links.
- Phase 8 Command Mode: authorized and in progress. Use a global keyboard-first
  compact panel. Resolve app, file, folder, URL, Notion, and Silverdeck
  navigation locally. Route complex multi-step work to a Silverdeck-managed
  Codex task. Ask for clarification when the target or project
  is ambiguous. Do not require confirmation for opening existing targets;
  require explicit approval for destructive, write, shell, or external actions.
  The first Shift-Command-Space press opens Command Mode and starts a
  conversational Realtime session; a second press or Escape ends it. Realtime
  transcription receives explicit Droppy, Codex, Notion, project, and app
  vocabulary hints. Menu-bar openings stay silent so they never activate the
  microphone unexpectedly, while Codex approvals can reuse an already-open
  conversation window without resetting that session.
  Installed app matching may complete a short app target such as `Chrome`, but
  an app name inside a longer task sentence never captures that task. Explicit
  `Open Droppy` opens the app; `In Droppy, review…` targets the Droppy project.
  Target-Mac feedback showed that Apple Speech required too much manual
  correction for command use, which led to the Realtime conversational upgrade
  documented below. The first live Codex handoff also exposed stale camel-case
  thread options. Every start,
  resume, and turn path now uses the installed schema's `on-request` approval
  policy; thread start and resume use `workspace-write`, while turn start keeps
  the structured `workspaceWrite` sandbox-policy type. Regression assertions
  cover each path.
  Preserve the supplied amber command-core image as the static source for a
  later animation pass.

- Phase 8 conversational voice upgrade: replace Apple Speech as the shortcut's
  primary voice path with an OpenAI Realtime WebSocket session using
  `gpt-realtime-2.1`, `gpt-live-transcribe`, semantic turn detection, streamed
  PCM audio, and interruption. Keep the model's tools deliberately narrow:
  immediate local navigation, starting a Silverdeck-managed Codex task,
  and continuing only the Codex task started by that voice session. Codex
  approvals and user questions remain visible in Command Mode. For this
  personal local build, keep the API key in macOS Keychain; a distributable
  build must replace direct standard-key authentication with a backend-issued
  client credential. Live microphone/API acceptance remains a separate gate
  from compilation and deterministic tests.
