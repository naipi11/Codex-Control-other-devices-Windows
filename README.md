# Codex Control other devices for Windows

Language / 语言：English · [简体中文](README.zh-CN.md)

Enables the UI that ships with Codex Desktop for Windows but is hidden by a runtime defect:

**Settings → Connections → Control other devices**

This project does not modify `ChatGPT.exe`, `app.asar`, or anything under
`C:\Program Files\WindowsApps`. After installation, a persistent tray supervisor
manages everything automatically; manual mode remains a conservative fallback.

> [!IMPORTANT]
> Complete the MFA, SSO, or passkey checks required by your account or workspace before enrolling a device.
>
> [!WARNING]
> This is an unofficial runtime compatibility project. It enables Chromium debugging on a random
> `127.0.0.1` port. Run it only on a trusted Windows machine and re-run the compatibility check
> after every Codex update.

## Quick start

Run the read-only preflight and continue only when all three checks pass:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CodexControlOtherDevices.ps1
```

```text
Ready: True
Node.js: 22 or newer
Heuristic match: True
```

Prefer the release installer when you do not want a source checkout:

1. Download `CodexControlOtherDevices-<version>-setup.exe` from the [Releases](https://github.com/naipi11/Codex-Control-other-devices-Windows/releases) page and verify its SHA-256.
2. Run the installer. It places the support files under `%LOCALAPPDATA%\CodexControlOtherDevices-installer` and installs or upgrades the persistent tray supervisor under `%LOCALAPPDATA%\CodexControlOtherDevices`.
3. Existing settings and device keys are preserved on upgrade. The tray supervisor starts automatically at the next logon (or immediately).

Install the persistent supervisor and explicitly opt in to candidate-compatible trials:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexControlOtherDevices.ps1 -EnableCandidateCompatibleUpdates
```

The install root is `%LOCALAPPDATA%\CodexControlOtherDevices`. During the first takeover, a
normal Codex launch may close and reopen once, so save unfinished work first.

Verified on Windows 11 · Codex Desktop `26.803.10989.0` · Node.js `22.23.1`:
the tab, controller enrollment, device list, and remote projects are all working.

## Everyday use

- The logon task `Codex Control Other Devices Supervisor` starts the tray supervisor automatically; no manual scripts are needed.
- A green tray icon means the current session is active. Open **Settings → Connections → Control other devices** to enroll or use it.
- New Codex builds start with `--remote-debugging-port` but no `--inspect`; the supervisor recognizes that launch shape and performs the takeover automatically.
- The tray menu supports Follow system, Chinese, and English; switching applies immediately without restarting anything.
- Updating this project or Codex does not require reinstalling the supervisor; the installer atomically switches versioned runtimes.

## Releases

Every tagged release ships a signed-package-ready Windows installer and its
SHA-256 checksum as release assets. The `.github/workflows/release.yml` workflow
builds the installer from the tag automatically, so future releases always
include a ready-to-run `CodexControlOtherDevices-<version>-setup.exe`.

After a Codex Desktop update, check the [Releases](https://github.com/naipi11/Codex-Control-other-devices-Windows/releases)
page for a newer installer, or run the compatibility check from this repository
to confirm the current supervisor still matches.

## External renderer shared CDP

When the External renderer Windows runtime is installed, the supervisor automatically
uses its saved renderer port, or `9335` when no saved state exists, if that
loopback port is available for the special Codex session. The renderer CDP port
can therefore be shared with External renderer; the temporary Electron main-process
Inspector remains separate and is closed after bridge installation.

If that preferred port is paused, unavailable, excluded because it is already
the main Inspector port, or occupied by a non-Codex listener, Codex Control
Other Devices selects a different dynamic loopback renderer port. A External renderer
`pause` marker skips integration. Missing or invalid External renderer state, and a
failed handoff, are handled safely without blocking the Codex session. The
integration does not promise Browser-ID or port reuse in these fallback cases.

Neither Codex nor External renderer installation files are modified.

## Tray menu

The native WinForms menu shows actions only when their semantic state allows them: Apply now, Retry,
Automation, Candidate-compatible trial, Logs, and Uninstall. Uninstall always requires explicit confirmation.

| Color | State | Meaning |
|---|---|---|
| Gray | Waiting / Inspecting / Transitioning | Waiting for Codex, inspecting the current session, or applying the bridge |
| Green | Active / ActivePaused | Current session is verified and usable |
| Yellow | Suppressed | Compatibility action is suppressed until a manual retry or a new runtime |
| Yellow | RendererHandoff | External renderer handoff did not complete; the verified Codex session remains active |
| Red | Recovered / Error | Ordinary Codex was safely restored, or automatic actions are blocked |

## Maintenance

Repair damaged state:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexControlOtherDevices.ps1 -RepairState
```

Uninstall safely (device key store is preserved by default):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-CodexControlOtherDevices.ps1
```

Options: `-BackupDeviceKeyStore` backs up the key; `-RemoveDeviceKeyStore` explicitly deletes it (mutually exclusive);
`-KeepCurrentSpecialSession` keeps the current special session (renderer CDP stays open).

Manual per-session enable or restore (conservative fallback):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-CodexControlOtherDevices.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Reset-CodexControlOtherDevices.ps1
```

## What it fixes

Affected Windows packages have all of the following characteristics:

1. The Windows controller page, strings, and backend calls are already shipped.
2. Statsig gate `782640499` is consumed with inverted semantics: `true` hides `showControlOtherDevices`.
3. The main-process device-key entry point accepts only `process.platform === "darwin"`.
4. The Windows package does not ship `remote-control-device-key.node`.

Official docs: [Remote connections](https://learn.chatgpt.com/docs/remote-connections).
This project only fills the local Windows runtime gap. It does not bypass account authorization,
MFA/SSO/passkeys, workspace policy, or server permissions.

## Security model

- Debug ports bind only to a random `127.0.0.1`; the main-process Inspector must close after injection.
- Any process running as the same Windows user can reach these ports, so only use a trusted machine.
- The device private key is stored at `%CODEX_HOME%\remote-control-device-keys.windows.json`
  (or `%USERPROFILE%\.codex\...` when `CODEX_HOME` is unset), encrypted with DPAPI current-user scope.
  It is a software key, not a TPM-backed non-exportable key.
- Moving or deleting the local key does not revoke server authorization; revoke the device in Codex first.

See [SECURITY.md](SECURITY.md) and [docs/TECHNICAL.md](docs/TECHNICAL.md).

## Diagnostics

Logs live in `%LOCALAPPDATA%\CodexControlOtherDevices\logs\`: `install.log`, `supervisor.log`,
`bootstrap.log`, and `transactions.log`.

## Troubleshooting

Still no **Control other devices** tab?

1. Confirm the tray icon is green (gray means waiting for Codex or automation is paused).
2. Re-run the preflight and confirm `Ready: True`.
3. Check `logs\supervisor.log` and `logs\install.log`.
4. Make sure security software is not blocking `node.exe` from loopback access.
5. Exit all Codex processes and retry; the supervisor restarts Codex at most once.

Enrollment or authorization fails?

- Complete MFA/SSO/passkey required by the account or workspace.
- Use the same ChatGPT account and workspace in Codex and the browser.
- For organization workspaces, confirm the admin allows Remote Control.

External renderer did not attach to an already-running session?

Rebind it manually with these commands, in this order:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Reset-CodexControlOtherDevices.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-CodexControlOtherDevices.ps1
```

## Project layout

```text
Install-CodexControlOtherDevices.ps1   Install/upgrade/repair CLI
Uninstall-CodexControlOtherDevices.ps1 Safe uninstall CLI
Start-CodexControlOtherDevices.ps1     Manual session start
Reset-CodexControlOtherDevices.ps1     Manual stop / key backup
Test-CodexControlOtherDevices.ps1      Read-only compatibility preflight
src/persistence/                       Bootstrap, tray supervisor, session controller, static probe
src/runtime/                           Clean-room bridge implementation
tests/                                 Repository tests, persistence tests, visual gallery
docs/                                  Technical docs, clean-room notes, bilingual screenshots
```

## Validation

```powershell
npm test
```

## License and provenance

[MIT](LICENSE) © 2026 naipi11. Root-cause analysis and the runtime technique come from
[hunterbeach's Codex Windows runtime remote control Gist](https://gist.github.com/hunterbeach/dc4b74bda0e045e33f308099182b4f80);
the main-process approach credits [zdaar/codex-hacks](https://github.com/zdaar/codex-hacks/blob/main/patch_codex_remote_control.py),
and the renderer injection pattern adapts [brunolemos' feature-override Gist](https://gist.github.com/brunolemos/7466058059eae140a57a7c6a42f235ae).
The final `src/runtime` is an isolated clean-room rewrite with no unlicensed upstream source text;
see [docs/CLEANROOM.md](docs/CLEANROOM.md) and [NOTICE.md](NOTICE.md).
This project is unofficial, is not affiliated with OpenAI, and does not redistribute OpenAI binaries or assets.
