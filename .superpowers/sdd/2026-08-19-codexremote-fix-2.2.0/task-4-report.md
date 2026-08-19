# Task 4 report — CodexRemote-fix installer, icon, and documentation

Date: 2026-08-19

## Outcome

Implemented the public CodexRemote-fix 2.2.0 installer contract without building or installing it. The public installer, shortcuts, release workflow, and bilingual documentation now use CodexRemote-fix. The compatibility AppId and legacy runtime, scheduled-task, and device-key identifiers remain unchanged.

## Changed files

- `package.json`
  - Set the package version to `2.2.0` and updated the public description.
- `build/CodexControlOtherDevices.iss`
  - Set public Inno names, output filename, shortcut names, upgrade message, and icon sinks to CodexRemote-fix.
  - Retained AppId `{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}` and legacy runtime paths.
  - Made the primary Start Menu and Desktop entries invoke only the stable bootstrap through Windows PowerShell with the stable `-InstallRoot` argument.
- `build/build.ps1`
  - Updated setup and checksum artifact filenames.
- `tests/persistence/InstallLifecycle.SelfTest.ps1`
  - Added exact release/version, AppId, artifact, ICO structure, shared-icon, bootstrap-only shortcut, README, and workflow assertions without weakening existing safety assertions.
- `assets/codexremote-fix/codexremote-fix.svg`
  - Retained the source vector used to generate the public icon.
- `assets/codexremote-fix/codexremote-fix.ico`
  - Replaced the malformed file with a four-image PNG ICO derived from the SVG.
- `README.md`
  - Kept English as the default document and made Quick Start installer-first.
- `README.zh-CN.md`
  - Updated the optional Chinese document to the same installer-first product contract.
- `.github/workflows/release.yml`
  - Updated workflow, uploaded artifact, build step, and GitHub release title branding.
- `docs/TECHNICAL.md`
  - Updated public title/scope branding while retaining legacy internal identifiers.
- `.superpowers/sdd/2026-08-19-codexremote-fix-2.2.0/task-4-report.md`
  - Recorded this implementation and verification evidence.

## TDD evidence

### Red

Command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

Exit code: `1`

Expected failure observed before changing the remaining implementation files:

```text
ASSERT_EQUAL: package version is exactly 2.2.0 expected=[2.2.0] actual=[2.1.6]
```

The same new test also covered the already-observed malformed ICO and legacy README/workflow branding.

### Green

Command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

Exit code: `0`

Output:

```text
Install lifecycle self-tests passed: 47
```

The two `What if:` lines emitted by existing lifecycle safety tests were informational and did not modify installation state.

## Icon structure evidence

Source: `assets/codexremote-fix/codexremote-fix.svg`

Output: `assets/codexremote-fix/codexremote-fix.ico`

```text
Reserved=0 Type=1 Count=4 Length=41959
Entry[0]=16x16, Bpp=32, Bytes=708, Offset=70, End=778
Entry[1]=32x32, Bpp=32, Bytes=1674, Offset=778, End=2452
Entry[2]=48x48, Bpp=32, Bytes=2824, Offset=2452, End=5276
Entry[3]=256x256, Bpp=32, Bytes=36683, Offset=5276, End=41959
SHA256=df335279353277c8eedafa61a991365d040ed352ab3d22e02b9267f899941383
```

Each directory range is non-empty, begins after the ICO directory, stays within the file, does not overlap its predecessor, starts with a PNG signature, and has PNG IHDR dimensions matching the directory entry. Visual inspection of the extracted 16, 48, and 256 pixel payloads confirmed that the SVG is fully framed rather than cropped.

All icon consumers resolve to the same icon bytes:

- Setup: `..\assets\codexremote-fix\codexremote-fix.ico`
- Installed icon: `{app}\assets\CodexRemote-fix.ico`
- Apps and Features / uninstall display icon: `{app}\assets\CodexRemote-fix.ico`
- Every Start Menu shortcut: `{app}\assets\CodexRemote-fix.ico`
- Desktop shortcut: `{app}\assets\CodexRemote-fix.ico`

## Additional verification

Command:

```powershell
npm test
```

Exit code: `0`

Output:

```text
Validation passed: PowerShell, JavaScript, clean-room runtime, package checker, persistence tests, repository files, and package preflight.
```

`npm test` invokes `tests/Validate.ps1 -SkipInstalledPackageCheck`; it did not build, install, or inspect a live installed Codex package.

Command:

```powershell
git diff --check
```

Exit code: `0`; no whitespace errors were reported. Git printed only the checkout's existing LF-to-CRLF conversion notices.

Static compatibility review confirmed:

- Inno AppId remains `{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}`.
- Runtime root remains `%LOCALAPPDATA%\CodexControlOtherDevices`.
- Scheduled task remains `\Codex Control Other Devices Supervisor`.
- Device-key file remains `%USERPROFILE%\.codex\remote-control-device-keys.windows.json` when `CODEX_HOME` is unset.
- The only remaining public-document occurrences of `Codex Control Other Devices` are the exact scheduled-task compatibility name.

## Boundaries and concerns

- Per the Task 4 brief, ISCC was not invoked and no setup executable was built. Therefore compiler/runtime installation behavior is intentionally outside this task's evidence; the installer contract is covered by the focused static self-test.
- No setup executable was run, and no install state, Codex binaries, `app.asar`, WindowsApps, Program Files, device keys, authorization, MFA/SSO, or passkeys were touched.
- The shared checkout contained unrelated untracked design/plan files before this task. They were left untouched and excluded from the Task 4 commit.
