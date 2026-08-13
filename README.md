# Codex Control other devices for Windows

Language / 语言: English · [简体中文](README.zh-CN.md)

Enables the UI that ships with Codex Desktop for Windows but is hidden by a runtime defect:

**Settings → Connections → Control other devices**

This project does not modify `ChatGPT.exe`, `app.asar`, or anything under
`C:\Program Files\WindowsApps`. After installation, a persistent tray supervisor
manages everything automatically.

> [!IMPORTANT]
> Complete the MFA, SSO, or passkey checks required by your account or workspace before enrolling a device.

> [!WARNING]
> This is an unofficial runtime compatibility project. It enables Chromium debugging on a random
> `127.0.0.1` port. Run it only on a trusted Windows machine, and re-run the compatibility check
> after every Codex update.

## Quick start

1. Download the latest installer from the [Releases](https://github.com/naipi11/Codex-Control-other-devices-Windows/releases) page and verify its SHA-256.
2. Run `CodexControlOtherDevices-<version>-setup.exe`; no administrator rights are required.
3. The tray supervisor starts automatically. When the tray icon is green, open **Settings → Connections → Control other devices** to enroll or use the device.

Latest release: [v2.1.0](https://github.com/naipi11/Codex-Control-other-devices-Windows/releases/tag/v2.1.0) —
[CodexControlOtherDevices-2.1.0-setup.exe](https://github.com/naipi11/Codex-Control-other-devices-Windows/releases/download/v2.1.0/CodexControlOtherDevices-2.1.0-setup.exe)
· SHA-256: `383d595aa11513c4ae1b57ef49b1ec55b3d3d1b7703f169bbdcb8503fdb37516`

To upgrade, run the new installer over the previous installation. Existing settings and device
keys are preserved.

Verified on Windows 11 · Codex Desktop `26.803.10989.0` · Node.js `22.23.1`:
the tab, controller enrollment, device list, and remote projects are all working.

## Everyday use

- The logon task `Codex Control Other Devices Supervisor` starts the tray supervisor automatically; no manual steps are needed.
- A green tray icon means the current session is active. Open **Settings → Connections → Control other devices** to enroll or use it.
- New Codex builds start with `--remote-debugging-port` but no `--inspect`; the supervisor recognizes that launch shape and performs the takeover automatically.
- The tray menu supports Follow system, Chinese, and English; switching applies immediately without restarting anything.
- Updating this project or Codex does not require reinstalling the supervisor; the installer atomically switches versioned runtimes.

## Releases

Every tagged release ships a Windows installer and its SHA-256 checksum as release assets.
The `.github/workflows/release.yml` workflow builds the installer from the tag automatically,
so future releases always include a ready-to-run `CodexControlOtherDevices-<version>-setup.exe`.

After a Codex Desktop update, check the [Releases](https://github.com/naipi11/Codex-Control-other-devices-Windows/releases)
page for a newer installer, or run the **Compatibility check** shortcut from the Start menu
to confirm the current supervisor still matches.

## External renderer shared CDP

When the External renderer Windows runtime is installed, the supervisor automatically
uses its saved renderer port, or `9335` when no saved state exists, if that
loopback port is available for the special Codex session. The renderer CDP port
can therefore be shared with External renderer; the temporary Electron main-process
Inspector remains separate and is closed after bridge installation.

If that preferred port is paused, unavailable, excluded because it is already
the main Inspector port, or occupied by a non-Codex listener, Codex Control
Other Devices selects a different dynamic loopback renderer port. An External renderer
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

## Troubleshooting

Still no **Control other devices** tab?

1. Confirm the tray icon is green (gray means waiting for Codex or automation is paused).
2. Run the **Compatibility check** shortcut from the Start menu and confirm `Ready: True`.
3. Check the logs under `%LOCALAPPDATA%\CodexControlOtherDevices\logs\`.
4. Make sure security software is not blocking `node.exe` from loopback access.
5. Exit all Codex processes and retry; the supervisor restarts Codex at most once.

Enrollment or authorization fails?

- Complete MFA/SSO/passkey required by the account or workspace.
- Use the same ChatGPT account and workspace in Codex and the browser.
- For organization workspaces, confirm the admin allows Remote Control.

External renderer did not attach to an already-running session?

Exit Codex, start the tray supervisor from the Start menu (**Open the tray supervisor**),
then relaunch Codex.

## Uninstall

Use the tray menu → **Uninstall**, or uninstall **Codex Control other devices** from
Windows Settings → Apps → Installed apps. The device key store is preserved or backed up
on uninstall; removing it locally does not revoke server authorization, so revoke the
device in Codex first.

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

## Project layout

```text
src/persistence/   Tray supervisor, session controller, installer lifecycle
src/runtime/       Clean-room bridge implementation
tests/             Repository tests and persistence tests
docs/              Technical docs, clean-room notes, bilingual screenshots
```

## License and provenance

[MIT](LICENSE) © 2026 naipi11. Root-cause analysis and the runtime technique come from
[hunterbeach's Codex Windows runtime remote control Gist](https://gist.github.com/hunterbeach/dc4b74bda0e045e33f308099182b4f80);
the main-process approach credits [zdaar/codex-hacks](https://github.com/zdaar/codex-hacks/blob/main/patch_codex_remote_control.py),
and the renderer injection pattern adapts [brunolemos' feature-override Gist](https://gist.github.com/brunolemos/7466058059eae140a57a7c6a42f235ae).
The final `src/runtime` is an isolated clean-room rewrite with no unlicensed upstream source text;
see [docs/CLEANROOM.md](docs/CLEANROOM.md) and [NOTICE.md](NOTICE.md).
This project is unofficial, is not affiliated with OpenAI, and does not redistribute OpenAI binaries or assets.
