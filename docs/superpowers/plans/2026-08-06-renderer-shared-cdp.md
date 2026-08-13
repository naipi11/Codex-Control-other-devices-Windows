# External renderer Shared CDP Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Codex External renderer attached to the renderer after project-controlled Codex restarts by reusing External renderer’s renderer port and invoking its official rebind script.

**Architecture:** Add a small, testable External renderer integration module that discovers the installed runtime, validates its state, selects a preferred renderer port, and starts the official handoff script. The session engine uses the preferred renderer port only when it is available; the supervisor invokes the handoff after a validated controller transaction without weakening device-control proof requirements.

**Tech Stack:** Windows PowerShell 5.1 modules, Node.js/CDP runtime, existing self-test harnesses, JSON state files, Git worktree.

## Global Constraints

- Renderer and main Inspector ports must remain distinct IPv4 loopback ports.
- Existing explicit request ports always take precedence over automatic External renderer selection.
- A non-Codex listener must never be stopped by shared-port logic.
- External renderer files and the protected Codex installation are read-only integration targets.
- External renderer handoff failure must not invalidate an otherwise verified device-control session.
- Existing JSON schemas remain unchanged; all new results use strict property order.
- The project remains Windows-only and loopback-only.

---

### Task 1: Add External renderer integration primitives

**Files:**
- Create: `src/persistence/modules/RendererIntegration.psm1`
- Test: `tests/persistence/RendererIntegration.SelfTest.ps1`
- Modify: `src/persistence/modules/SessionEngine.psm1` import list
- Modify: `src/persistence/Supervisor.ps1` module import list

**Interfaces:**

- `Get-CcodRendererLayout -Root <string>` returns an exact object with `Installed`, `Root`, `EngineRoot`, `StartScript`, `StatePath`, `PauseFile`, and `DefaultRendererPort`.
- `Read-CcodRendererState -Layout <object> -Adapters <hashtable>` returns `$null` or an exact validated state projection with `Port`, `BrowserId`, `InjectorPid`, `CodexExe`, and `Paused`.
- `Get-CcodRendererPreferredPort -ExcludedPorts <int[]> -Adapters <hashtable>` returns a valid available port or `$null`.
- `Test-CcodRendererPaused -Layout <object> -Adapters <hashtable>` returns a Boolean without changing files.
- `Start-CcodRendererHandoff -RendererPort <int> -Layout <object> -Adapters <hashtable>` returns an exact receipt `{Outcome,Code,ProcessId}` and never throws for an optional integration failure.

- [ ] **Step 1: Write failing unit tests for layout and state validation**

Add tests that create temporary roots containing:

```text
engine/scripts/start-renderer.ps1
state.json
pause.marker
```

Assert that a valid state with `port=9444` returns `9444`, an absent state returns `9335`, an invalid port returns `$null`/fallback, and a missing start script reports `Installed=$false`.

- [ ] **Step 2: Run the focused test and confirm the expected failure**

Run:

```powershell
pwsh -NoProfile -File tests/persistence/RendererIntegration.SelfTest.ps1
```

Expected: FAIL because `RendererIntegration.psm1` does not exist yet.

- [ ] **Step 3: Implement the minimal integration module**

Use canonical paths rooted under `%LOCALAPPDATA%\CodexRenderer`; reject reparse-point traversal and malformed JSON. Treat the default renderer port as `9335`. Validate ports in `1..65535`, Browser IDs as bounded strings, injector PIDs as positive integers, and return `$null` for unavailable optional data.

- [ ] **Step 4: Add injected adapters for filesystem, port, and hidden-process operations**

The default adapter must:

```powershell
ReadText = { param($Path) [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false)) }
PathExists = { param($Path) [IO.File]::Exists($Path) }
TestLoopbackPortAvailable = { param($Port) Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue }
StartHiddenProcess = { param($FilePath,$Arguments) Start-Process -FilePath $FilePath -ArgumentList $Arguments -WindowStyle Hidden -PassThru }
```

Unit tests must replace these adapters and must not launch PowerShell or touch the real External renderer directory.

- [ ] **Step 5: Run the focused test and confirm it passes**

Run the same command and expect all External renderer integration cases to pass with zero failures.

- [ ] **Step 6: Commit the isolated primitive**

```powershell
git add src/persistence/modules/RendererIntegration.psm1 tests/persistence/RendererIntegration.SelfTest.ps1 src/persistence/modules/SessionEngine.psm1 src/persistence/Supervisor.ps1
git commit -m "feat: add External renderer CDP integration primitives"
```

### Task 2: Make session startup prefer the shared renderer port

**Files:**
- Modify: `src/persistence/modules/SessionEngine.psm1:1-20,500-540,890-905`
- Test: `tests/persistence/SessionEngine.SelfTest.ps1`
- Test: `tests/persistence/ProcessControl.SelfTest.ps1`

**Interfaces:**

- Session adapter `GetPreferredRendererPort` accepts `ExcludedPorts` and returns an integer or `$null`.
- Existing `GetPort` remains the dynamic fallback.
- `Invoke-CcodApplySession` keeps explicit `Request.rendererPort` and `Request.mainPort` unchanged.

- [ ] **Step 1: Add a failing session-engine test**

Extend `New-CcodEngineAdapters` with:

```powershell
GetPreferredRendererPort = { param($Excluded) 9335 }
```

Run `Invoke-CcodApplySession` with no explicit renderer port and assert:

```powershell
Assert-CcodEqual 9335 $result.special.rendererPort 'External renderer preferred renderer port is selected'
Assert-CcodEqual 41002 $result.special.mainPort 'main Inspector remains distinct'
```

- [ ] **Step 2: Run the focused session test and verify it fails**

Run:

```powershell
pwsh -NoProfile -File tests/persistence/SessionEngine.SelfTest.ps1
```

Expected: FAIL because Apply currently calls only `GetPort`.

- [ ] **Step 3: Implement preferred-port selection**

In `Merge-CcodSessionAdapters`, add a default `GetPreferredRendererPort` adapter that calls `Get-CcodRendererPreferredPort -ExcludedPorts`. In `Invoke-CcodApplySession`, choose the explicit request renderer first, then the preferred port, then the existing dynamic allocator. Always choose the main port after the renderer and exclude the renderer from that allocation.

- [ ] **Step 4: Add a safe occupied-port regression**

Add a test where `GetPreferredRendererPort` returns `$null` and `GetPort` returns `41001`; assert the transaction still activates on the dynamic port and never calls `StartSpecial` with `9335`.

- [ ] **Step 5: Run SessionEngine and ProcessControl tests**

Run:

```powershell
pwsh -NoProfile -File tests/persistence/SessionEngine.SelfTest.ps1
pwsh -NoProfile -File tests/persistence/ProcessControl.SelfTest.ps1
```

Expected: all existing and new assertions pass.

- [ ] **Step 6: Commit the port-selection change**

```powershell
git add src/persistence/modules/SessionEngine.psm1 tests/persistence/SessionEngine.SelfTest.ps1 tests/persistence/ProcessControl.SelfTest.ps1
git commit -m "feat: prefer External renderer renderer CDP port"
```

### Task 3: Add post-transaction External renderer handoff

**Files:**
- Modify: `src/persistence/Supervisor.ps1:10-25,180-250,485-515`
- Test: `tests/persistence/Supervisor.SelfTest.ps1`
- Modify: `src/persistence/resources/ui.en-US.json`
- Modify: `src/persistence/resources/ui.zh-CN.json`

**Interfaces:**

- Supervisor adapter `HandoffRenderer` accepts `(Result, RendererPort)` and returns `{Outcome,Code,ProcessId}`.
- `HandoffRenderer` is called only after a successful `Apply`, `RepairRenderer`, or replay result with `safeState='SpecialValidated'`.
- Handoff is skipped when the result renderer port is not the preferred shared port or the External renderer pause marker is present.

- [ ] **Step 1: Add a failing supervisor test**

Create a worker-result fixture with:

```powershell
$result.ok = $true
$result.outcome = 'Activated'
$result.safeState = 'SpecialValidated'
$result.special.rendererPort = 9335
```

Inject `HandoffRenderer` that records its arguments. Assert exactly one call after `CompleteControllerRun`, and assert no call for failed or ordinary recovery results.

- [ ] **Step 2: Run the focused supervisor test and verify it fails**

Run:

```powershell
pwsh -NoProfile -File tests/persistence/Supervisor.SelfTest.ps1
```

Expected: FAIL because the supervisor has no handoff adapter or call site.

- [ ] **Step 3: Implement the default hidden handoff adapter**

Import `RendererIntegration.psm1` in `Import-CcodSupervisorModules`. The default adapter calls `Start-CcodRendererHandoff`, records `CCOD_RENDERER_HANDOFF_FAILED` through the existing bounded log adapter on failure, and returns control to the normal session state.

- [ ] **Step 4: Add bilingual diagnostic strings**

Add short English and Chinese strings for the optional handoff failure/status reason without changing existing menu keys. Keep the tray status stable when External renderer is absent or paused.

- [ ] **Step 5: Run Supervisor tests and verify the call ordering**

Run the focused supervisor test and assert the event order remains:

```text
Read:WorkerResult,Reduce:Apply,HandoffRenderer,Dispose:Worker
```

Handoff must occur after the controller result is reduced and before worker cleanup completes.

- [ ] **Step 6: Commit the handoff change**

```powershell
git add src/persistence/Supervisor.ps1 tests/persistence/Supervisor.SelfTest.ps1 src/persistence/resources/ui.en-US.json src/persistence/resources/ui.zh-CN.json
git commit -m "feat: rebind External renderer after Codex session changes"
```

### Task 4: Document configuration, fallback, and recovery

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/TECHNICAL.md`
- Modify: `docs/CLEANROOM.md`
- Test: `tests/persistence/RuntimeManifest.SelfTest.ps1`

**Interfaces:**

- Public documentation explains that External renderer integration is automatic when its Windows runtime is installed, uses the saved External renderer port or `9335`, and falls back safely when the port is unavailable.
- The recovery section gives the exact manual commands to rebind an already-running session:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Reset-CodexControlOtherDevices.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-CodexControlOtherDevices.ps1
```

- [ ] **Step 1: Add English-first README section**

Document shared renderer port, separate main Inspector, pause behavior, non-Codex port fallback, and the fact that no Codex or External renderer installation files are modified.

- [ ] **Step 2: Add the matching Chinese section**

Keep headings and command examples aligned with `README.md`, with the English README remaining the default entry point.

- [ ] **Step 3: Update technical and clean-room notes**

Describe the handoff boundary and list the new module in the clean-room implementation inventory.

- [ ] **Step 4: Run manifest and documentation-oriented tests**

Run:

```powershell
pwsh -NoProfile -File tests/persistence/RuntimeManifest.SelfTest.ps1
pwsh -NoProfile -File tests/Validate.ps1
```

Expected: the runtime manifest includes the new module and all static validation passes.

- [ ] **Step 5: Commit documentation and manifest coverage**

```powershell
git add README.md README.zh-CN.md docs/TECHNICAL.md docs/CLEANROOM.md tests/persistence/RuntimeManifest.SelfTest.ps1
git commit -m "docs: document External renderer shared CDP mode"
```

### Task 5: Full verification and controlled live handoff

**Files:**
- No new source files.
- Inspect: `state/status.json`, `state/transition.json`, `logs`, External renderer `state.json`, `injector-error.log`.

**Interfaces:**

- Project self-tests remain the authoritative regression gate.
- Live validation is read-only until the user explicitly authorizes a Codex restart or state migration.

- [ ] **Step 1: Run the complete project self-test**

```powershell
pwsh -NoProfile -File tests/PersistenceSelfTest.ps1
node tests/CleanroomSelfTest.js
node tests/PackageCheckerSelfTest.mjs
```

Expected: exit code `0` and zero failing cases.

- [ ] **Step 2: Build and validate an installed runtime**

Run the repository’s existing install/test wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-CodexControlOtherDevices.ps1
```

Confirm the active runtime manifest includes `RendererIntegration.psm1`, the supervisor stays `Active`, and no protected Codex file hash changes.

- [ ] **Step 3: Perform read-only endpoint checks**

Confirm:

```text
127.0.0.1:<shared renderer port>/json/version -> HTTP 200
127.0.0.1:<shared renderer port>/json/list -> exact Codex renderer target
127.0.0.1:<main Inspector port> -> ECONNREFUSED after payload injection
```

- [ ] **Step 4: Ask before live migration if the current session is still on a dynamic port**

If the live Codex session remains on `59063`, report that code and tests are ready but the one-time migration requires restarting Codex. Do not restart or reset live state without explicit confirmation.

- [ ] **Step 5: Review the final diff and report evidence**

Run:

```powershell
git status --short
git diff --check HEAD~4
git log -5 --oneline
```

Report exact test counts, the selected shared port, whether live handoff was performed, and any remaining version/selector compatibility risk.
