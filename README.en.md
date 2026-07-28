# Codex Control other devices for Windows

English | [简体中文](README.md)

Enable the UI already shipped in Codex Desktop for Windows but blocked by a
runtime defect:

**Settings → Connections → Control other devices**

This project does not modify `ChatGPT.exe`, `app.asar`, or anything under
`C:\Program Files\WindowsApps`. The fix exists only in the Codex process started
by this project. Launch Codex normally to disable it.

> [!IMPORTANT]
> Complete the MFA, SSO, or passkey checks required by the account or workspace.
> The account used for this test required MFA to be enabled before enrollment.

> [!WARNING]
> This is an unofficial, version-sensitive runtime compatibility project. It
> enables Chromium debugging on a random `127.0.0.1` port. Run it only on a
> trusted Windows machine and repeat the compatibility check after every Codex
> update.

## Verified environment

| Item | Result |
|---|---|
| Windows | Windows 11, passed |
| Codex Desktop | `26.721.4979.0`, end-to-end verified |
| Node.js | `22.23.1`, passed |
| Flow | Tab, controller authorization, device list, and remote project verified |
| Installed package changes | None |

The original hunterbeach research reported success on `26.715.7063.0`. This
implementation does not rely only on a version number. It scans the installed
`app.asar` for four text sentinels associated with the tested code family and
checks whether the native module exists. This is a heuristic compatibility
check, not proof that a future build has the same control flow.

## Root cause

Affected Windows packages have all of the following characteristics:

1. The Windows controller page, strings, and backend calls are already shipped.
2. Statsig gate `782640499` is consumed with inverted semantics: `true` hides
   `showControlOtherDevices`.
3. The main-process device-key entry point accepts only
   `process.platform === "darwin"`.
4. The Windows package does not ship `remote-control-device-key.node`.

The resulting symptom is specific: Windows displays **Control this computer**
and **SSH**, and mobile devices can control the PC, but the Windows client cannot
act as a controller because **Control other devices** is absent.

OpenAI's [Remote connections documentation](https://learn.chatgpt.com/docs/remote-connections)
describes the normal pairing, account/workspace, required authentication, and host requirements.
This project fills only the affected local Windows runtime gap. It does not
bypass account authorization, MFA/SSO/passkeys, workspace policy, or server permissions.

## What is different in this implementation

- No installed application files are copied, patched, or re-signed.
- A dependency-free streaming preflight scans the real package for four text
  sentinels and checks whether OpenAI now ships the native Windows module.
- Overrides are scoped to one Statsig gate, one native module request, and a
  best-effort platform check based on the `getAddon` stack name.
- P-256 private keys are encrypted with Windows DPAPI `CurrentUser` scope before
  being stored.
- The legacy key-store layout from the hunterbeach runtime experiment remains
  readable.
- Random loopback ports reduce collisions and predictable exposure.
- A successful launch requires the Electron main-process Inspector to close and
  verifies that its endpoint is no longer reachable.
- Any failed probe stops the special process and restores a normal Codex launch.
- Resetting preserves keys by default; optional cleanup creates a recoverable
  timestamped backup instead of deleting the file.

## Requirements

- Windows 10 or Windows 11.
- The Microsoft Store/MSIX `OpenAI.Codex` package.
- Node.js 22 or later with `node.exe` on `PATH`.
- Ability to complete the MFA, SSO, or passkey required by the account or
  workspace; the tested account required MFA.
- Another online Codex host signed in to the same account and workspace, with
  Remote Control allowed.
- A trusted local Windows environment.

## Quick start

```powershell
git clone https://github.com/naipi11/Codex-Control-other-devices-Windows.git
cd Codex-Control-other-devices-Windows

powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\Test-CodexControlOtherDevices.ps1
```

Continue only when the check reports `Ready: True` and `Heuristic match: True`.
Save current work because the launcher closes and reopens Codex Desktop:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\Start-CodexControlOtherDevices.ps1
```

Then open **Settings → Connections → Control other devices**, select **Add** or
**Set up**, and complete the authentication required for that account.

The workaround is session-only. Run the launcher again after Codex exits. A
normal Start menu or taskbar launch disables the workaround.

## How it works

1. The PowerShell preflight locates the installed Store package and Node.js.
2. A streaming scanner checks for text sentinels associated with the inverted
   gate, Windows UI, macOS-only guard, native-module reference, and missing
   Windows native binary.
3. Codex restarts with random renderer and main-process debugging ports bound to
   `127.0.0.1`.
4. The renderer bridge forces only gate `782640499` to `false` and verifies the
   result through a probe.
5. The main bridge uses a best-effort `getAddon` stack-name match for the scoped
   platform override and intercepts only `remote-control-device-key.node`.
6. The replacement creates P-256 keys, protects private material with DPAPI, and
   implements the expected public-key and signing contract.
7. The launcher verifies that the main Inspector closes; otherwise it rolls back
   to a normal launch. The renderer debugging endpoint remains until Codex exits.

See [docs/TECHNICAL.md](docs/TECHNICAL.md) for the detailed design and
[docs/CLEANROOM.md](docs/CLEANROOM.md) for the isolated implementation record.

## Security notes

The renderer debugging endpoint can execute code inside the Codex renderer. The
main-process Inspector can execute main-process Node code during its shorter
startup window. Both are loopback-only, but an untrusted process running as the
same Windows user is inside this project's threat boundary. Do not use the
workaround on a shared or untrusted machine.

Encrypted device keys are stored at:

```text
%CODEX_HOME%\remote-control-device-keys.windows.json
```

When `CODEX_HOME` is unset, the default is
`%USERPROFILE%\.codex\remote-control-device-keys.windows.json`.

The bridge uses the compatibility label `os_protected_nonextractable`, but this
JavaScript fallback is a DPAPI-protected software key, not a TPM-backed
non-exportable key. Read [SECURITY.md](SECURITY.md) before use.

## Disable and roll back

The simplest rollback is to exit Codex and launch it normally.

To stop the special instance and restart normally while keeping device keys:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\Reset-CodexControlOtherDevices.ps1
```

After revoking the controller in Codex, move the encrypted key store to a
recoverable backup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\Reset-CodexControlOtherDevices.ps1 `
  -BackupDeviceKeyStore
```

Moving the local key does not revoke server-side authorization. Revoke first.

## Diagnostics

```text
%TEMP%\CodexControlOtherDevices\runtime-YYYYMMDD-HHMMSS.log
%TEMP%\CodexControlOtherDevices\last-session.json
```

Logs should not contain credentials or private keys, but review local paths and
environment information before sharing them publicly.

## Troubleshooting

### The tab is still missing

- Confirm Codex was opened by `Start-CodexControlOtherDevices.ps1`.
- Repeat the preflight and require `Ready: True`.
- Inspect the latest runtime log.
- Check whether endpoint security blocked `node.exe` from loopback access.
- Exit every Codex process and retry.

### Preflight fails after a Codex update

This is intentional. OpenAI may have fixed the problem or changed an internal
contract. The sentinel check also cannot prove future compatibility. Do not
remove it. Open an issue with the Codex package version, boolean sentinel
results, and a redacted error. Do not upload `app.asar`, tokens, or device keys.

### Authorization fails

- Complete the MFA, SSO, or passkey requested by the account/workspace. If the
  flow requires MFA to be enabled first, do so before restarting enrollment.
- Use the same ChatGPT account and workspace in Codex and the browser.
- Ask the workspace administrator to allow Remote Control where applicable.

### No hosts appear

- Keep the target host online and awake.
- Use the same account and workspace.
- Enable **Allow other devices to connect** on the target host.
- Signing out disables Remote Control; turn it on after signing back in.

## Validation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\Validate.ps1
```

This validates PowerShell parsing, Node.js syntax, a temporary-directory
DPAPI/key lifecycle and compatibility suite, renderer/Inspector behavior,
required repository files, and the installed Codex package sentinels.

## Original contributions and provenance

This repository uses the problem analysis and runtime technique published by
hunterbeach as a functional specification, plus read-only inspection of Codex
Desktop `26.721.4979.0` and local end-to-end validation. Because the referenced
upstream implementations do not state a license that permits their source text
to be relicensed here, the final `src/runtime` code is an isolated clean-room
rewrite. Its implementer received only required behavior, interface fields, and
the locally installed package's calling contract, and was prohibited from
reading the earlier derived prototype, Gist source, or other online workaround
source. See [docs/CLEANROOM.md](docs/CLEANROOM.md).

Original engineering contributions in this repository include the streaming
sentinel check, random ports, verified main Inspector shutdown, automatic
normal-launch rollback, versioned/legacy-compatible DPAPI storage, the
dependency-free clean-room bridge, validation, and bilingual documentation.

The root-cause identification and runtime technique come from hunterbeach's
[Codex Windows runtime remote control Gist](https://gist.github.com/hunterbeach/dc4b74bda0e045e33f308099182b4f80).
That Gist credits the main-process approach to
[zdaar/codex-hacks](https://github.com/zdaar/codex-hacks/blob/main/patch_codex_remote_control.py)
and adapts its renderer injection pattern from
[brunolemos' feature-override Gist](https://gist.github.com/brunolemos/7466058059eae140a57a7c6a42f235ae).
These sources remain explicit so upstream discoveries are not presented as this
project's original discoveries. No unlicensed upstream source text is included
in the clean-room runtime. See [NOTICE.md](NOTICE.md) for the boundary.

No OpenAI application binary or asset is redistributed. This project is
unofficial and is not affiliated with OpenAI.

## License

[MIT](LICENSE) © 2026 naipi11. The MIT license covers this repository's original
code and documentation; referenced upstream works remain subject to their own
rights and license terms. See [NOTICE.md](NOTICE.md).
