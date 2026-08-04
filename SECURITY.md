# Security policy

## Important boundary

This project starts Codex Desktop with Chromium remote debugging and a temporary
Electron main-process Inspector on random `127.0.0.1` ports. Any untrusted
process already running as your Windows user may be able to use the renderer
endpoint to execute renderer code or use the Inspector during its startup
window to execute main-process Node code. Run the workaround only on a trusted
personal machine.

The launcher requires the Electron main-process Inspector to become unreachable
after setup. If that verification fails, it stops the special instance and
restarts Codex normally. The renderer endpoint remains available until Codex
exits because Chromium does not provide a supported runtime switch to remove it.

## Persistent supervisor boundaries

The persistent tray supervisor is installed per current user, not per machine:

- The scheduled task `Codex Control Other Devices Supervisor` runs
  unelevated with `InteractiveToken`, `RunLevel=Limited`, and
  `MultipleInstances=IgnoreNew`. It cannot grant administrator rights and is
  never registered as a service or IFEO entry.
- The supervisor writes only under
  `%LOCALAPPDATA%\CodexControlOtherDevices`; the install root, state, runtime,
  and logs are part of the current user's trust root. A same-user process that
  can already modify your user files is inside the threat model.
- Manifest, active-pointer, and state hashes detect corruption and tampering,
  but they do not authenticate the author of a checkout. Source trust comes
  from user review of the repository before install.
- The renderer CDP endpoint remains on `127.0.0.1` for the whole special
  session and is available to same-user processes. The main-process Inspector
  is limited to the startup window and must close with an explicit
  `ECONNREFUSED` check.
- Damaged or missing state disables automation and quarantines the evidence;
  the user must explicitly run the installer's `-RepairState` and re-enable
  automation and candidate-compatible updates from the tray.
- A compatible first-seen package is tried at most once and only with both
  consent switches enabled. Unknown, incompatible, or native-module builds
  stay ordinary and are never stopped or reopened.
- Default uninstall normalizes a validated special session back to an ordinary
  session, verifies both debugger ports are closed, and only then removes the
  task, tray, runtime, state, and logs. Explicit
  `-KeepCurrentSpecialSession` leaves the unmonitored renderer CDP open and
  prints that warning.

## Device-key storage

- The private P-256 key is encrypted with Windows DPAPI using `CurrentUser`
  scope before it is written to disk.
- The encrypted store is located at
  `%CODEX_HOME%\remote-control-device-keys.windows.json`; if `CODEX_HOME` is
  unset, the default is
  `%USERPROFILE%\.codex\remote-control-device-keys.windows.json`.
- Decryption occurs when Codex calls `signDeviceKey()` and when a create/delete
  operation validates or migrates every existing record before replacing the
  store. Public-key reads do not normally need the private material.
- The compatibility value sent to Codex is `os_protected_nonextractable`, but
  this JavaScript fallback is not equivalent to a hardware-backed TPM key.
- Uninstall preserves the encrypted store by default. `-BackupDeviceKeyStore`
  moves it to a timestamped sibling file; `-RemoveDeviceKeyStore` deletes it.
  Both parameters are mutually exclusive, and neither revokes server-side
  authorization: revoke the device in Codex first.

## Safer operating practice

1. Complete the MFA, SSO, or passkey required by the account/workspace. The
   account used for this project's test required MFA before enrollment.
2. Keep Windows and Codex Desktop updated.
3. Run `Test-CodexControlOtherDevices.ps1` after every Codex update.
4. Treat its text-sentinel result as a heuristic, not proof of compatibility;
   audit new builds before updating the supported technique.
5. Launch Codex normally whenever remote desktop-to-desktop control is not
   needed.
6. Revoke the controller device in Codex before removing its local key store.
7. Do not run the supervisor on a shared or untrusted machine; the tray
   session keeps the renderer debugging endpoint open on `127.0.0.1`.
8. Review `%LOCALAPPDATA%\CodexControlOtherDevices\logs\` before sharing any
   diagnostic log; entries contain local paths but must never contain tokens,
   device keys, or account credentials.

## Reporting a vulnerability

Please use GitHub's **Security → Report a vulnerability** flow after Private
Vulnerability Reporting is enabled for this repository. If the private form is
not visible, open a public issue containing only a request for a private contact
channel—do not include technical exploit details. Never include ChatGPT session
data, account tokens, device keys, or diagnostic logs containing private paths
in a public issue.
