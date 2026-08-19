# Startup Recovery and Desktop Shortcut Design

## Goal

Make the Windows installer provide a discoverable desktop entry point, and make
startup recovery after a failed automatic Codex takeover diagnosable and safe.

## Confirmed observations

- The installed v2.1.0 runtime is present under
  `%LOCALAPPDATA%\\CodexControlOtherDevices`; the installer is present under
  `%LOCALAPPDATA%\\CodexControlOtherDevices-installer`.
- The logon task successfully starts the tray supervisor.
- The current Codex package passes the read-only compatibility check:
  `Ready: True`, package `26.803.10989.0`, Node `22.23.1`, and
  `CandidateCompatible` classification.
- A startup transaction reached `SpecialLaunchRequested`, could not prove a
  safe recovery immediately, and repeatedly wrote the generic
  `CCOD_RECOVERY_UNPROVEN` record before ultimately returning to an ordinary
  Codex session.
- The existing session log records only action, transaction, stage, and code.
  It cannot distinguish which recovery proof failed, so the root trigger is
  not recoverable from the installed log.
- The installer currently creates Start menu shortcuts for the tray supervisor
  and compatibility check, but no desktop shortcut.

## Scope

### Startup recovery

1. Preserve the current fail-closed rule: no special session is accepted until
   its exact process identity, command line, and loopback-port ownership are
   proven.
2. Do not spin a controller repeatedly while an interrupted transaction is
   waiting for ordinary-session recovery. A recovery worker must get one
   bounded observation window, then either complete the recovery transaction
   or leave one actionable failure result for the user.
3. Preserve the first causal failure separately from the later recovery
   outcome. Session log records for Apply, Recover, and replay must include a
   sanitized `reason` field selected from a fixed allowlist; they must not
   contain command lines, account identifiers, tokens, or raw exception text.
4. A successful ordinary recovery must display a clear recoverable tray state
   and allow one explicit retry. It must not imply that remote-device
   authorization or the local device key has been removed.

### Desktop entry point

1. The installer creates a desktop shortcut named `Codex Device Connection`.
2. The shortcut starts the installed tray supervisor through the verified
   stable bootstrap. It never directly injects into, closes, or launches a
   special Codex session.
3. The existing Start menu entries remain: documentation, `Open the tray
   supervisor`, `Compatibility check`, and uninstall.
4. The shortcut is removed by the normal installer uninstaller and replaced
   safely during an upgrade.

## Non-goals

- Do not modify Codex binaries or files under `C:\\Program Files\\WindowsApps`.
- Do not change remote-device pairing, server authorization, MFA, SSO, or
  passkey handling.
- Do not introduce administrator privileges, background network listeners, or
  a second persistent service.
- Do not publish product-specific external-renderer names in user-facing
  documentation.

## Design

### Recovery result and diagnostics

The session engine will create a small causal diagnostic record before any
recovery attempt. The record contains the transaction id, action, stage,
stable error code, and one allowlisted proof reason. Recovery completion adds
its own outcome record without replacing the causal record.

The supervisor will treat a controller `Recovered` result as a terminal state
for that transaction. It will retain a single in-memory suppression key for
the recovered ordinary process, so the same recovered process is not taken
over again automatically. An explicit `Retry last repair` clears that key and
starts one fresh reconciliation. A new ordinary process remains eligible for
one automatic attempt.

The tests must cover each recovery boundary: no ordinary root yet, ordinary
root appears during the bounded wait, and recovery remains unproven. They must
also prove that the original failure record survives a successful recovery.

### Installer shortcut

The Inno Setup package will create a current-user desktop shortcut to the
verified installed bootstrap script, launched with hidden PowerShell and an
explicit `-InstallRoot`. Its target is the stable installer location, not a
versioned runtime, so installer upgrades keep the shortcut valid.

## Acceptance criteria

1. A test proves one recovery transaction writes no more than one causal
   failure record and no repeat controller loop occurs while the same recovery
   transaction is pending.
2. A test proves a successful ordinary recovery retains the original causal
   reason and exposes an explicit retry path.
3. A test proves the installer script creates the expected desktop shortcut
   with the stable bootstrap target and removes it on uninstall.
4. Existing repository tests pass on Windows.
5. The built installer provides a desktop shortcut, Start menu entries, and
   an upgrade-safe tray bootstrap.
