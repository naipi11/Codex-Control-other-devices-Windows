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

## Reporting a vulnerability

Please use GitHub's **Security → Report a vulnerability** flow after Private
Vulnerability Reporting is enabled for this repository. If the private form is
not visible, open a public issue containing only a request for a private contact
channel—do not include technical exploit details. Never include ChatGPT session
data, account tokens, device keys, or diagnostic logs containing private paths
in a public issue.
