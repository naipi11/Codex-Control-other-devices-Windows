# External renderer Shared CDP Integration Design

## Goal

Keep Codex External renderer attached after Codex restarts or Store updates while preserving the current “connect other devices” automation.

## Context

Codex External renderer expects a stable renderer CDP endpoint, normally `127.0.0.1:9335`, and its watcher is anchored to the CDP Browser ID observed at startup. The control project currently launches Codex with a dynamically selected renderer port and a separate main Inspector port. A Codex restart therefore closes External renderer’s original Browser ID and leaves External renderer polling the old endpoint.

## Chosen approach

1. Detect an installed External renderer runtime under `%LOCALAPPDATA%\CodexRenderer`.
2. Read its `state.json` port when that state is valid; otherwise use the documented/default External renderer renderer port `9335`.
3. Use that port only for Codex’s renderer CDP endpoint. Keep the main Inspector on a distinct dynamically selected loopback port.
4. After a project-controlled Codex session becomes validated, launch External renderer’s own `start-renderer.ps1 -Port <renderer-port>` in a hidden PowerShell process. The script will reuse the already-running Codex endpoint and create a watcher anchored to the new Browser ID.
5. Make handoff best-effort and idempotent:
   - skip when External renderer is not installed;
   - skip when the pause marker is present;
   - skip when the saved External renderer state already describes the current renderer session;
   - log a stable diagnostic record when the handoff cannot be started.
6. If the preferred port is occupied by a non-Codex listener, fall back to the existing dynamic-port allocator and log that shared mode was unavailable for this session. No unrelated listener is stopped.

## Components

### RendererIntegration module

New module: `src/persistence/modules/RendererIntegration.psm1`.

Responsibilities:

- Resolve and validate the External renderer root, start script, state file, and pause marker.
- Return a strict integration snapshot:

  ```text
  Installed, Root, StartScript, StatePath, PauseFile,
  RendererPort, StatePort, Paused, StateReadable
  ```

- Select a preferred renderer port without starting or stopping processes.
- Determine whether a handoff is needed from the current Codex identity and the External renderer state.
- Start the official External renderer script with hidden-window arguments and return a bounded launch receipt.

The module will not modify External renderer files or invoke arbitrary paths outside its verified installation root.

### Session engine

`SessionEngine.psm1` will use a new optional `GetPreferredRendererPort` adapter before falling back to `Get-CcodAvailableLoopbackPort`. The selected preferred port is still checked for loopback availability after the ordinary Codex source is stopped. Existing explicit request ports remain authoritative.

### Supervisor

`Supervisor.ps1` will invoke a new optional `HandoffRenderer` adapter after a controller result that validates a special session. The adapter will only launch External renderer when the current session uses the selected shared renderer port and the handoff predicate says the saved watcher is absent or stale. Handoff errors do not invalidate a verified device-control session; they are logged and exposed through the tray status reason/log.

### State and compatibility

No existing JSON schema is widened. Shared-port preference is derived from the external External renderer installation and its validated state file, so existing installations remain readable and older project state remains compatible. The project continues to record the actual renderer/main port pair in its existing status and transition records.

## Handoff sequence

```text
Supervisor sees ordinary Codex
  -> Apply transaction stops the exact source
  -> Session engine chooses External renderer renderer port (9335/state port)
  -> Session engine chooses distinct main Inspector port
  -> Codex starts and the project installs/verifies both payloads
  -> Supervisor completes the transaction
  -> External renderer start script attaches to the same renderer port
  -> External renderer records the new Browser ID and applies the active theme
```

If External renderer was already running before the transaction, its old watcher is allowed to exit with the old Codex identity; the official start script is then responsible for reconciling stale state and creating the new watcher.

## Failure handling

- Invalid External renderer JSON, invalid port, missing script, or unsafe path: treat integration as unavailable and use dynamic project behavior.
- Preferred port occupied by a non-Codex process: do not stop it; use a dynamic renderer port for this session.
- External renderer handoff process exits early: keep the Codex/device-control session active, write `CCOD_RENDERER_HANDOFF_FAILED`, and leave the next manual External renderer start possible.
- Pause marker present: do not auto-resume or apply a theme.

## Tests

Add regression coverage for:

1. Valid External renderer state selects its saved renderer port.
2. Missing/invalid state falls back to `9335` when the installation is present.
3. An installation without an External renderer keeps dynamic port allocation.
4. A non-Codex listener on `9335` causes a safe dynamic fallback.
5. A paused External renderer session does not trigger an automatic handoff.
6. A stale or missing watcher produces one bounded handoff request.
7. A validated project session remains successful when External renderer handoff fails.
8. Existing ProcessControl, SessionEngine, Supervisor, clean-room, and manifest tests remain green.

## Non-goals

- No changes to Codex’s protected installation files.
- No modifications to External renderer source or installation data.
- No automatic theme selection or theme content changes.
- No remote/network exposure; all endpoints remain loopback-only.
