# CodexRemote-fix 2.2.0 Design

## Goal

Recover safely after a Codex Desktop package update, replace the slow classic
tray menu with a responsive bilingual Windows popup, and ship the product as a
discoverable Windows application named CodexRemote-fix.

## Confirmed causes

- The current source compatibility probe reports Codex 26.814.5167.0 as
  CandidateCompatible, while the installed runtime records 26.810.7004.0 and
  repeatedly emits CCOD_STATE_BLOCKED.
- The updated package can carry all four exact legacy defect sentinels and a
  native device-key artifact. Native-file presence alone is not evidence that
  the Windows controller UI is healthy.
- The classic WinForms ContextMenuStrip shares an STA timer with synchronous
  state/process polling and rewrites visible properties every 250 ms.
- Existing installer registration uses AppId
  {2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}; its identity must stay stable for a
  real in-place upgrade.

## Safety constraints

- Do not modify Codex binaries, app.asar, or files under Program Files/WindowsApps.
- Do not delete/recreate device keys, remote authorization, MFA, SSO, passkeys,
  or pairing while repairing or upgrading.
- Preserve fail-closed package classification, process identity checks,
  loopback-only inspection, manifest validation, and the account-transition mutex.
- Add no administrator privilege, service, external listener, telemetry, or
  runtime dependency.
- Retain the legacy internal runtime root, scheduled-task name, and key-store
  location in version 2.2.0.

## Design

### Package compatibility and stale state

CandidateCompatible requires all four exact legacy sentinels and affected=true.
It remains eligible when nativeModulePresent is also true. A native artifact
with an incomplete sentinel set is NativeModulePresent and stays fail-closed.
Malformed or contradictory output stays unknown and cannot start a trial.

When persisted verified-package identity differs from live Codex identity, the
supervisor records a fixed sanitized reason and uses the normal bounded
reconciliation path. It must not reuse an old process identity, loop
indefinitely, or clear state/key data. Repair proceeds only after normal
current-package static and dynamic validation succeeds.

### Tray interaction

Keep NotifyIcon only for system-tray integration. Left and right click open a
compact borderless non-taskbar WPF connection card in the existing STA process.
It closes on deactivation or Escape. Its controls display status, repair,
preferences, and a Follow Windows / English / Chinese language flyout. UI
events only enqueue existing validated commands.

The 250 ms cadence stays for shutdown and command responsiveness. Disk reads,
process reconciliation, and render writes occur on change or once per second.
A presentation fingerprint eliminates identical writes. While the card is open,
safety polling continues but visible renders are coalesced and flush once on
close.

### Product identity and Windows discovery

The public name becomes CodexRemote-fix, version 2.2.0. The installer retains
the original AppId and upgrades the current-user installation in place. A
multi-resolution project icon is used for Setup, uninstall, desktop, and Start
menu entries. The primary desktop and Start entry invokes only the stable
bootstrap, never a direct Codex injection. Existing legacy internal IDs remain
compatibility details.

## Acceptance criteria

1. Full legacy sentinels plus native artifact reach the controlled candidate
   path; native-only/incomplete and malformed evidence stay blocked.
2. Stale package/status mismatch has a fixed diagnostic reason and one bounded
   reconciliation path without device-key deletion.
3. Tests prove WPF host, queue-only commands, bilingual updates, unchanged
   write suppression, popup coalescing, and deterministic cleanup.
4. Installer tests prove AppId upgrade, custom icon, desktop/Start stable
   bootstrap targets, and CodexRemote-fix naming.
5. Full validation, installer compilation, and local upgrade verify tray,
   shortcuts, compatibility state, and retained pairing.

