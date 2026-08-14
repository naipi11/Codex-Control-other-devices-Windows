# Startup Recovery and Desktop Shortcut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent a committed completion receipt left active by a crash from blocking a later recovery replay, and provide an installer-created desktop entry for the tray supervisor.

**Architecture:** A terminal receipt is durable completion evidence for its transaction. If a crash leaves its matching active record behind and recovery later advances that same record to another legal terminal stage, `Complete-CcodTransition` clears the stale active record from the terminal receipt instead of treating it as a conflict. The desktop shortcut launches only the stable bootstrap in the installed root, never a direct special-session injection.

**Tech Stack:** Windows PowerShell 5.1, Inno Setup 6, repository PowerShell self-tests.

## Global Constraints

- Do not modify Codex binaries or paths under `C:\Program Files\WindowsApps`.
- Do not change device keys, remote pairing, MFA, SSO, passkeys, or server authorization.
- Preserve fail-closed process and loopback ownership validation.
- The desktop shortcut starts only the stable bootstrap.
- Use the bilingual shortcut name `Codex 设备连接 (Device Connection)`.

---

### Task 1: Terminal completion receipt recovery

**Files:**
- Modify: `src/persistence/modules/TransitionJournal.psm1:1014-1111`
- Modify: `tests/persistence/TransitionJournal.SelfTest.ps1`

**Interfaces:**
- Consumes: schema-1 completion receipts containing `transactionId`, `disposition`, `terminalStage`, and `state`.
- Produces: `Complete-CcodTransition` behavior where a valid archived receipt from another transaction cannot block the active transaction.

- [x] **Step 1: Write a failing regression test**

Create a `Validated` transition, complete it as `Activated`, then simulate a crash by restoring the same transaction as a legal `Recovered` active transition. Completing it as `Recovered` must clear the stale active record without adding a second archive entry.

```powershell
$result = Complete-CcodTransition -Path $path -LogPath $logPath `
  -TransactionId $transition.transactionId -Disposition Recovered `
  -Adapters @{ UtcNow = { $completedUtc }.GetNewClosure() }
Assert-CcodEqual 'Completed' $result.Outcome 'terminal receipt clears the stale active transaction'
Assert-CcodEqual $null (Read-CcodTransition -Path $path) 'terminal receipt leaves no replayable active transaction'
```

- [x] **Step 2: Verify RED**

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TransitionJournal.SelfTest.ps1`.

Expected: failure `CCOD_TRANSITION_RECEIPT_INVALID`.

- [x] **Step 3: Implement terminal-receipt precedence**

When the current transaction ID matches an `Archived` or `ArchiveFailed` receipt, clear the active record before comparing the requested disposition or current stage. Keep the conflict check for non-terminal (`Prepared`) receipts.

- [x] **Step 4: Verify GREEN**

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TransitionJournal.SelfTest.ps1`.

Expected: all transition journal self-tests pass.

- [x] **Step 5: Commit with the patch release**

```powershell
git add src/persistence/modules/TransitionJournal.psm1 tests/persistence/TransitionJournal.SelfTest.ps1
git commit -m "fix: scope completion receipts to their transaction"
```

### Task 5: Installer upgrade completion

**Root cause:** The v2.1.1 installer ran `tests\Validate.ps1` from its extracted payload, but that payload omitted `build\CodexControlOtherDevices.iss`, which the validation script requires. The installer therefore exited with code 1 after unpacking and never switched the active runtime.

- [x] Add an installer-contract regression test requiring the validation input in the payload.
- [x] Include `build\CodexControlOtherDevices.iss` in the installer payload.
- [x] Verify a clean extracted payload runs its full self-validation.
- [x] Add a cross-runtime recovery test: only a matching terminal receipt can clear a legacy `Recovered` transaction before replay.
- [x] Publish this additional fix as v2.1.2.

### Task 2: Stable desktop tray shortcut

**Files:**
- Modify: `build/CodexControlOtherDevices.iss:52-56`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`

**Interfaces:**
- Consumes: the stable bootstrap at `%LOCALAPPDATA%\CodexControlOtherDevices\bootstrap.ps1`.
- Produces: a desktop shortcut named `Codex 设备连接 (Device Connection)` that invokes that bootstrap with explicit `-InstallRoot`.

- [x] **Step 1: Write a failing installer-contract test**

Assert that `build/CodexControlOtherDevices.iss` contains one `{userdesktop}` icon entry targeting `powershell.exe`, with `-WindowStyle Hidden`, the stable `bootstrap.ps1`, and its explicit stable install root. Assert it does not target `Start-CodexControlOtherDevices.ps1`.

- [x] **Step 2: Verify RED**

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstallLifecycle.SelfTest.ps1`.

Expected: failure because v2.1.0 has no `{userdesktop}` entry.

- [x] **Step 3: Implement shortcut**

Add an `[Icons]` entry using the fixed stable bootstrap path, not a versioned runtime and not a `[Run]` action.

- [x] **Step 4: Verify GREEN**

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstallLifecycle.SelfTest.ps1`.

Expected: all installer lifecycle self-tests pass.

- [x] **Step 5: Commit with the patch release**

```powershell
git add build/CodexControlOtherDevices.iss tests/persistence/InstallLifecycle.SelfTest.ps1
git commit -m "feat: add desktop shortcut for tray supervisor"
```

### Task 3: Environment-independent test observation and documentation

**Files:**
- Modify: `tests/persistence/Supervisor.SelfTest.ps1:651-652`
- Modify: `README.md`
- Modify: `README.zh-CN.md`

**Interfaces:**
- Consumes: production's deferred WinForms load inside `RunUiContext`.
- Produces: a test that checks loaded assembly names without resolving and loading the WinForms type, plus installer-first bilingual guidance.

- [x] **Step 1: Correct the test observation**

Run the supervisor load in a fresh non-interactive PowerShell process, then inspect only the loaded assembly names:

```powershell
. $supervisorPath -ReadyToken ('a' * 64)
$loadedWinForms = @([AppDomain]::CurrentDomain.GetAssemblies() |
  Where-Object { $_.GetName().Name -ceq 'System.Windows.Forms' })
if ($loadedWinForms.Count -ne 0) { exit 17 }
```

- [x] **Step 2: Verify the supervisor test**

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1`.

Expected: pass without loading WinForms in the fake adapter path.

- [x] **Step 3: Update bilingual README guidance**

Document that the desktop shortcut starts only the tray supervisor, an explicit repair may close and relaunch Codex once, pairing is preserved, and `Retry last repair` is the recovery action. Do not add PowerShell commands.

- [x] **Step 4: Commit with the patch release**

```powershell
git add tests/persistence/Supervisor.SelfTest.ps1 README.md README.zh-CN.md
git commit -m "docs: explain tray startup and recovery"
```

### Task 4: Patch release validation

**Files:**
- Modify: `package.json`
- Build: `build/dist/CodexControlOtherDevices-2.1.1-setup.exe`

- [ ] **Step 1: Set `package.json` version to `2.1.1`**

- [ ] **Step 2: Run full validation**

Run `npm test`; if an installed-package preflight is environment-bound, separately record its result and do not claim full success without the successful command output.

- [ ] **Step 3: Build installer**

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File build/build.ps1 -Version 2.1.1`.

Expected: non-empty `CodexControlOtherDevices-2.1.1-setup.exe` and its SHA-256 file.

- [ ] **Step 4: Commit tracked release source**

```powershell
git add package.json
git commit -m "chore: release 2.1.1"
```

### Task 6: Take over a legacy statusless supervisor during upgrade

**Root cause:** A legacy supervisor can have a valid process but a `status.json` with `session: null`. The upgrade path previously trusted only that status identity, so it could not signal the old supervisor. The scheduled task then remained occupied by the old runtime.

**Safety boundary:** The fallback accepts exactly one process only when it is a child of this install root's stable `bootstrap.ps1`, its command line points to a runtime under this install root and includes a valid 64-hex `-ReadyToken`, and both processes run in the current Windows session under the current user's SID. A missing, ambiguous, or non-matching result is ignored.

- [x] Add a failing lifecycle test for a statusless legacy supervisor.
- [x] Add the restricted fallback identity adapter and use it for upgrade and uninstall paths.
- [x] Verify the lifecycle suite passes (37 tests).
- [x] Build and install v2.1.4 locally; verify it replaces the live legacy supervisor, clears the stale transaction, and restarts from the scheduled task.
