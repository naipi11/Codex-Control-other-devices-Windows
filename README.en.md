# Codex Control other devices for Windows

[English](README.en.md) | [Simplified Chinese](README.md)

Enable the UI already shipped in Codex Desktop for Windows but blocked by a runtime defect:

**Settings → Connections → Control other devices**

This project does not modify `ChatGPT.exe`, `app.asar`, or anything under
`C:\Program Files\WindowsApps`. The persistent installation is managed by a
current-user tray supervisor; manual mode remains a conservative fallback.

> [!IMPORTANT]
> Complete the MFA, SSO, or passkey checks required by the account or workspace.
> The account used for this test required MFA to be enabled before enrollment.

> [!WARNING]
> This is an unofficial, version-sensitive runtime compatibility project. It enables
> Chromium debugging on a random `127.0.0.1` port. Run it only on a trusted Windows
> machine and repeat the compatibility check after every Codex update.

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

## Persistent tray supervisor (recommended)

Installation registers a current-user logon task, **Codex Control Other Devices
Supervisor**, which starts a persistent tray supervisor. It watches ordinary Codex
launches and, only when the package is eligible, performs and verifies the
compatibility takeover. Manual mode remains a conservative fallback.

### Install

Run this read-only preflight first:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CodexControlOtherDevices.ps1
~~~

Continue only when the check reports `Ready: True`, Node.js 22 or later, and
`Heuristic match: True`. Install the supervisor and explicitly opt in to
candidate-compatible update trials:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexControlOtherDevices.ps1 -EnableCandidateCompatibleUpdates
~~~

The install root is `%LOCALAPPDATA%\CodexControlOtherDevices`. A compatible
first-seen package gets one controlled trial. Unknown, incompatible, and
native-module-present builds stay ordinary; the supervisor never takes them over.
Save unfinished work before a trial: a normal Codex launch may close and reopen
once. Simulated restart/update fixtures are not proof of an actual Windows logon
or Microsoft Store update; those cycles require real observation.

### Repair state

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexControlOtherDevices.ps1 -RepairState
~~~

Repair recreates schema-1 state with `automationEnabled=false` and
`candidateCompatibleOptIn=false`. Re-enable automation and the
candidate-compatible option, if desired, from the tray.

### Uninstall

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-CodexControlOtherDevices.ps1
~~~

By default, uninstall normalizes a special session to ordinary, then removes the
task, tray supervisor, runtime, state, and logs while preserving the DPAPI
device-key store. `-KeepCurrentSpecialSession` keeps the special session, with
the warning that renderer CDP remains open without tray monitoring.
`-BackupDeviceKeyStore` and `-RemoveDeviceKeyStore` are mutually exclusive.
Moving or deleting the local key does not revoke server authorization; revoke
the device in Codex first.

### Supervisor behavior

The **Codex Control Other Devices Supervisor** task is limited to the current
user and uses `InteractiveToken`, `IgnoreNew`, three one-minute retries, `PT0S`
execution time, and no battery-start or battery-stop restrictions.

The tray icon reports these states:

- Gray: waiting for Codex or paused.
- Green: special session verified.
- Yellow: incompatible, native-module-present, or suppressed.
- Red: takeover failed and an ordinary session was restored.

Use the tray menu to pause, resume, or retry. The supervisor reconciles every
three seconds and uses a WMI capability fallback when an optional capability is
unavailable. Project upgrades and Codex restarts do not require rerunning the
project; the installed supervisor continues to manage the current runtime.

## Manual mode

Manual mode is a per-session, conservative fallback:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-CodexControlOtherDevices.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Reset-CodexControlOtherDevices.ps1
~~~

## Security notes

Renderer CDP for a special session remains on `127.0.0.1`. It can execute code
inside the Codex renderer, so untrusted processes running as the same Windows
user are inside this project's threat boundary. The task and supervisor are
unelevated; their current-user files are part of the trust root. Manifest hashes
detect corruption, not the identity of the user who controls those files. Damaged
state disables automation rather than guessing how to recover. Default uninstall
normalizes the special session before removing the tray.

Encrypted device keys are stored at
`%CODEX_HOME%\remote-control-device-keys.windows.json`. When `CODEX_HOME` is
unset, the default is `%USERPROFILE%\.codex\remote-control-device-keys.windows.json`.
The bridge uses the compatibility label `os_protected_nonextractable`, but this
JavaScript fallback is a DPAPI-protected software key, not a TPM-backed
non-exportable key. Read [SECURITY.md](SECURITY.md) before use.

## Diagnostics

Persistent logs are stored in `%LOCALAPPDATA%\CodexControlOtherDevices\logs\`.
The primary files are `install.log`, `supervisor.log`, and `bootstrap.log`.
Logs should not contain credentials or private keys, but review local paths and
environment information before sharing them publicly.

## Project structure

~~~text
.
+-- Install-CodexControlOtherDevices.ps1
+-- Uninstall-CodexControlOtherDevices.ps1
+-- src/persistence/bootstrap.ps1
+-- src/persistence/Supervisor.ps1
+-- src/persistence/SessionController.ps1
+-- src/persistence/StaticProbeWorker.ps1
+-- src/persistence/modules/
|   +-- InstallLifecycle.psm1
|   +-- ScheduledTask.psm1
+-- tests/persistence/
+-- docs/
|   +-- TECHNICAL.md
|   +-- CLEANROOM.md
+-- SECURITY.md
+-- NOTICE.md
~~~

## Validation

~~~powershell
npm test
~~~

Repository validation covers PowerShell and Node.js syntax checks, clean-room and
persistence suites, required files, and (unless explicitly skipped) read-only
installed-package preflight. It does not simulate proof of a real Windows logon
or Microsoft Store update cycle.

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

