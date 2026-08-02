# Persistent Tray Supervisor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and install a current-user Windows tray supervisor that automatically reapplies the existing Codex “Control other devices” compatibility bridge after normal launches, restarts, and compatible updates without modifying the Codex MSIX package.

**Architecture:** Keep the existing clean-room JavaScript bridge as the injection kernel. Add small PowerShell 5.1 modules for strict persistence I/O, runtime manifests, package/process identity, durable transitions, a pure supervisor decision engine, and thin Windows adapters. A stable bootstrap validates a versioned runtime and supervises the WinForms tray process; a limited per-user scheduled task starts bootstrap at logon.

**Tech Stack:** Windows PowerShell 5.1, WinForms/System.Drawing, WMI/CIM, ScheduledTasks, Node.js 22+, existing CDP JavaScript runtime, plain PowerShell/Node self-tests without third-party packages.

**Approved Design:** `docs/superpowers/specs/2026-08-02-persistent-tray-supervisor-design.md`

## Global Constraints

- Support Windows 11, Microsoft Store/MSIX `OpenAI.Codex`, Windows PowerShell 5.1, and Node.js 22 or newer.
- Install under `%LOCALAPPDATA%\CodexControlOtherDevices`; never execute the persistent service from the Git checkout.
- Never write to WindowsApps, repackage Codex, install a service, use IFEO, create a permanent WMI consumer, change WMI ACLs, create a firewall rule, or bind a debugger outside `127.0.0.1`.
- Run as the installing user with `LogonType=InteractiveToken`, `RunLevel=Limited`, `MultipleInstances=IgnoreNew`, one-minute restart interval, three restart attempts, `ExecutionTimeLimit=PT0S`, and battery restrictions disabled.
- Resolve the AppX package and WindowsApps entry dynamically for every transition; never trust a persisted executable path as current identity.
- Store only installer-verified absolute Node paths in `settings.json.nodeCandidates`; the supervisor must never discover Node from the scheduled task’s inherited `PATH`.
- Keep `automationEnabled` and `candidateCompatibleOptIn` as separate booleans. `CandidateCompatible` may be tried once only when both are true.
- Treat `UnknownOrIncompatible` and `NativeModulePresent` as fail-closed ordinary sessions. A native module is not proof that the UI or signing flow is fully supported.
- Use two different random IPv4 loopback ports. Require explicit main Inspector `ECONNREFUSED`, an exact `app://-/index.html` renderer target, current-document installation, new-document installation, and a non-empty Statsig proof for gate `782640499`.
- Preserve the DPAPI CurrentUser device-key format and path semantics. Uninstall preserves the key store by default and never claims to revoke server authorization.
- Reconcile every three seconds. Try `Win32_ProcessStartTrace`, fall back on access denial to temporary `__InstanceCreationEvent WITHIN 1`, and operate correctly with no event subscription.
- Control only the Windows Session that owns the tray; ignore same-name processes in every other user or Session.
- Rotate each log class at 2 MiB and retain at most 10 historical files.
- Default uninstall closes a validated special session, verifies both debugger ports closed, and starts one ordinary Codex. Keeping the special session requires explicit confirmation.
- Default automated tests must never stop, launch, inject, install a task, or uninstall the real Codex application. Real-machine acceptance is a separate, explicit final gate.

## File and Responsibility Map

```text
Install-CodexControlOtherDevices.ps1          # public install/upgrade/repair CLI
Uninstall-CodexControlOtherDevices.ps1        # public safe uninstall CLI
Start-CodexControlOtherDevices.ps1            # backward-compatible manual session CLI
Reset-CodexControlOtherDevices.ps1            # backward-compatible reset/key-backup CLI
Test-CodexControlOtherDevices.ps1             # backward-compatible read-only preflight CLI

src/persistence/
├── bootstrap.ps1                             # self-contained active/previous validator and supervisor parent
├── Supervisor.ps1                            # WinForms/WMI host and serialized controller runner
├── SessionController.ps1                     # one-JSON Inspect/Apply/Recover CLI
└── modules/
    ├── PersistenceIO.psm1                    # contained paths, reparse checks, atomic JSON, quarantine, logs
    ├── RuntimeManifest.psm1                  # runtime-id, manifest, active/previous switching
    ├── CompatibilityProbe.psm1               # AppX, Node and static package classification
    ├── ProcessControl.psm1                   # exact process snapshots, adoption, compare-and-stop, launch
    ├── StateStore.psm1                       # settings/status/verification schemas and suppression keys
    ├── TransitionJournal.psm1                # stage CAS and crash replay decisions
    ├── SessionEngine.psm1                    # apply/probe/recover orchestration and result envelope
    ├── SupervisorEngine.psm1                 # pure reconciliation/deduplication decisions
    ├── KernelObjects.psm1                    # SID/Session-scoped mutex/event names and ACLs
    ├── TrayUi.psm1                           # NotifyIcon rendering and menu-to-command mapping
    ├── ScheduledTask.psm1                    # pure task spec plus Windows task adapter
    └── InstallLifecycle.psm1                 # staging, switch, upgrade, repair and uninstall orchestration

tests/
├── PackageCheckerSelfTest.mjs
├── PersistenceSelfTest.ps1                   # aggregate PowerShell persistence tests
└── persistence/
    ├── TestSupport.ps1
    ├── PersistenceIO.SelfTest.ps1
    ├── RuntimeManifest.SelfTest.ps1
    ├── CompatibilityProbe.SelfTest.ps1
    ├── StateStore.SelfTest.ps1
    ├── ProcessControl.SelfTest.ps1
    ├── TransitionJournal.SelfTest.ps1
    ├── SessionEngine.SelfTest.ps1
    ├── SupervisorEngine.SelfTest.ps1
    ├── KernelObjects.SelfTest.ps1
    ├── TrayUi.SelfTest.ps1
    ├── Bootstrap.SelfTest.ps1
    ├── ScheduledTask.SelfTest.ps1
    └── InstallLifecycle.SelfTest.ps1
```

## Shared Data Contracts

`PackageInfo` is a `PSCustomObject` with `FullName`, `FamilyName`, `Version`, `InstallLocation`, `ExecutablePath`, `AppAsarPath`, `NativeDirectory`, `AppAsarSha256`, `StaticClassification`, `SignatureState`, and `NodePath`.

`ProcessSnapshot` is a `PSCustomObject` with `Pid`, `CreationTimeUtc`, `SessionId`, `UserSid`, `Path`, `PackageFamilyName`, `CommandLine`, `ParentPid`, `IsTopLevel`, `Mode`, `RendererPort`, and `MainPort`. `Mode` is one of `Ordinary`, `Special`, or `Unrelated`.

Controller stdout is exactly one compressed JSON object shaped as:

```json
{
  "schemaVersion": 1,
  "action": "Apply",
  "ok": true,
  "outcome": "Activated",
  "safeState": "SpecialValidated",
  "stage": "Validated",
  "transactionId": "5f496d99-c839-4458-a6a2-d37ea1afdbda",
  "package": {
    "fullName": "OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0",
    "familyName": "OpenAI.Codex_2p2nqsd0c76g0",
    "version": "1.0.0.0",
    "appAsarSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "source": {"pid": 100, "creationTimeUtc": "2026-08-02T00:00:00.0000000Z"},
  "special": {"pid": 101, "creationTimeUtc": "2026-08-02T00:00:01.0000000Z", "rendererPort": 41001, "mainPort": 41002},
  "probes": {},
  "recovery": {},
  "error": null,
  "logFile": "C:\\Users\\name\\AppData\\Local\\CodexControlOtherDevices\\logs\\session.log"
}
```

All modules that touch processes, clocks, GUIDs, AppX, Node, files outside a supplied test root, or the bridge accept an `Adapters` hashtable of scriptblocks. Self-tests supply fakes; production entrypoints construct real adapters.

---

### Task 1: Hermetic Test Harness and Package Checker Contract

**Files:**

- Create: `tests/persistence/TestSupport.ps1`
- Create: `tests/PersistenceSelfTest.ps1`
- Create: `tests/PackageCheckerSelfTest.mjs`
- Modify: `src/check-package.mjs`
- Modify: `tests/Validate.ps1`
- Modify: `package.json`

**Interfaces:**

- Produces: `Invoke-CcodTest`, `Assert-CcodTrue`, `Assert-CcodEqual`, `Assert-CcodThrows` for all later PowerShell self-tests.
- Produces: exported `inspectPackage(asarPath, nativeDirectory)` returning `{schemaVersion, classification, affected, appAsarSha256, nativeModulePresent, signatures}`.
- Preserves: current two-argument `check-package.mjs` CLI and current `affected` field.

- [ ] **Step 1: Write the failing package-checker tests**

Create fixtures in a temporary directory and assert exact classification and full-file hashing:

```js
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { inspectPackage } from "../src/check-package.mjs";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "ccod-package-test-"));
try {
  const asar = path.join(root, "app.asar");
  const body = Buffer.from("782640499 remote-control-device-key.node Remote control device keys are only available on macOS Control other devices from this PC trailing-hash-bytes");
  fs.writeFileSync(asar, body);
  const result = await inspectPackage(asar, path.join(root, "native"));
  assert.equal(result.schemaVersion, 1);
  assert.equal(result.classification, "CandidateCompatible");
  assert.equal(result.appAsarSha256, crypto.createHash("sha256").update(body).digest("hex"));
  fs.mkdirSync(path.join(root, "native"), { recursive: true });
  fs.writeFileSync(path.join(root, "native", "remote-control-device-key.node"), "fixture");
  assert.equal((await inspectPackage(asar, path.join(root, "native"))).classification, "NativeModulePresent");
} finally {
  fs.rmSync(root, { force: true, recursive: true });
}
```

- [ ] **Step 2: Run the package test and verify it fails because `inspectPackage` is not exported**

Run: `node.exe .\tests\PackageCheckerSelfTest.mjs`

Expected: nonzero exit with a missing export/import error.

- [ ] **Step 3: Refactor the checker without early hash termination**

Import `createHash` from `node:crypto`. Keep scanning every chunk after all needles are found so SHA-256 covers the complete file:

```js
export async function inspectPackage(asarPath, nativeDirectory) {
  const hash = createHash("sha256");
  const signatureState = Object.fromEntries([...signatures.keys()].map((name) => [name, false]));
  const longest = Math.max(...[...signatures.values()].map((needle) => needle.length));
  let carry = Buffer.alloc(0);
  for await (const chunk of createReadStream(asarPath, { highWaterMark: 4 * 1024 * 1024 })) {
    hash.update(chunk);
    const searchable = carry.length === 0 ? chunk : Buffer.concat([carry, chunk]);
    for (const [name, needle] of signatures) {
      if (!signatureState[name] && searchable.indexOf(needle) !== -1) signatureState[name] = true;
    }
    carry = searchable.subarray(Math.max(0, searchable.length - longest + 1));
  }
  const nativeModulePresent = await containsNativeDeviceKeyModule(nativeDirectory);
  const allSignatures = Object.values(signatureState).every(Boolean);
  const classification = nativeModulePresent
    ? "NativeModulePresent"
    : allSignatures ? "CandidateCompatible" : "UnknownOrIncompatible";
  return {
    affected: classification === "CandidateCompatible",
    appAsarSha256: hash.digest("hex"),
    classification,
    nativeModulePresent,
    schemaVersion: 1,
    signatures: signatureState,
  };
}
```

- [ ] **Step 4: Add the plain PowerShell test harness**

```powershell
function Assert-CcodTrue([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE: $Message" }
}
function Assert-CcodEqual($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "ASSERT_EQUAL: $Message expected=[$Expected] actual=[$Actual]" }
}
function Assert-CcodThrows([scriptblock]$Action, [string]$ErrorId) {
    try { & $Action; throw "ASSERT_THROWS: expected $ErrorId" }
    catch { if ($_.FullyQualifiedErrorId -notlike "$ErrorId*") { throw } }
}
function Invoke-CcodTest([string]$Name, [scriptblock]$Action) {
    & $Action
    [pscustomobject]@{ Name = $Name; Ok = $true }
}
```

- [ ] **Step 5: Make `PersistenceSelfTest.ps1` aggregate every `*.SelfTest.ps1` in a fresh process**

Use absolute Windows PowerShell and fail on any nonzero child exit:

```powershell
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tests = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'persistence') -Filter '*.SelfTest.ps1' | Sort-Object Name
foreach ($test in $tests) {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "Persistence self-test failed: $($test.Name)" }
}
```

- [ ] **Step 6: Wire both test families into validation**

Add `test:persistence` and `test:package` scripts to `package.json`. Update `tests/Validate.ps1` to run `PackageCheckerSelfTest.mjs` and `PersistenceSelfTest.ps1` before the optional installed-package preflight.

- [ ] **Step 7: Run the hermetic baseline**

Run:

```powershell
node.exe .\tests\PackageCheckerSelfTest.mjs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate.ps1 -SkipInstalledPackageCheck
```

Expected: all commands exit 0; persistence aggregation initially reports zero component files without touching Codex.

- [ ] **Step 8: Commit**

```powershell
git add package.json src/check-package.mjs tests/PackageCheckerSelfTest.mjs tests/PersistenceSelfTest.ps1 tests/persistence/TestSupport.ps1 tests/Validate.ps1
git commit -m "test: add persistent runtime harness"
```

### Task 2: Safe Paths, Atomic JSON, Quarantine, and Bounded Logs

**Files:**

- Create: `src/persistence/modules/PersistenceIO.psm1`
- Create: `tests/persistence/PersistenceIO.SelfTest.ps1`

**Interfaces:**

- Produces: `Resolve-CcodContainedPath -Root -RelativePath -AllowMissingLeaf`.
- Produces: `Read-CcodStrictJson -Path -ExpectedSchema -Kind` and `Write-CcodAtomicJson -Path -Value`.
- Produces: `Move-CcodCorruptState -Path -Reason` and `Write-CcodRotatingLog -Path -Message`.

- [ ] **Step 1: Write failing containment and atomic-I/O tests**

```powershell
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$module = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src\persistence\modules\PersistenceIO.psm1'
Import-Module $module -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-io-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    Assert-CcodThrows { Resolve-CcodContainedPath -Root $root -RelativePath '..\escape.json' } 'CCOD_PATH_OUTSIDE_ROOT'
    $path = Join-Path $root 'state\settings.json'
    Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; automationEnabled = $false })
    $raw = [IO.File]::ReadAllBytes($path)
    Assert-CcodTrue ($raw.Length -gt 0 -and -not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)) 'JSON must be UTF-8 without BOM'
    Assert-CcodEqual 1 (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').schemaVersion 'schema round-trip'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
```

Add tests for an existing junction/reparse ancestor, truncated JSON quarantine, 2 MiB rollover, and retention of exactly 10 history files.

- [ ] **Step 2: Run the component test and verify the module/functions are missing**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\PersistenceIO.SelfTest.ps1`

Expected: nonzero exit naming `PersistenceIO.psm1` or the first missing command.

- [ ] **Step 3: Implement canonical containment and reparse rejection**

Use `Path.GetFullPath`, a root separator suffix, case-insensitive Windows comparison, and inspect every existing component for `FileAttributes.ReparsePoint`:

```powershell
function Throw-CcodError([string]$Id, [string]$Message, $Target) {
    throw [System.Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message), $Id, [System.Management.Automation.ErrorCategory]::InvalidData, $Target)
}
function Resolve-CcodContainedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath, [switch]$AllowMissingLeaf)
    if ([IO.Path]::IsPathRooted($RelativePath)) { Throw-CcodError 'CCOD_PATH_OUTSIDE_ROOT' 'Absolute child path rejected' $RelativePath }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { Throw-CcodError 'CCOD_PATH_OUTSIDE_ROOT' 'Path escapes root' $candidate }
    Test-CcodNoReparseAncestor -Root $rootFull -Path $candidate -AllowMissingLeaf:$AllowMissingLeaf
    $candidate
}

function Test-CcodNoReparseAncestor([string]$Root, [string]$Path, [switch]$AllowMissingLeaf) {
    $rootItem = Get-Item -LiteralPath $Root.TrimEnd('\') -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-CcodError 'CCOD_REPARSE_PATH' 'Install root is a reparse point' $Root }
    $relative = $Path.Substring($Root.Length)
    $cursor = $Root.TrimEnd('\')
    foreach ($segment in ($relative -split '\\' | Where-Object { $_.Length -gt 0 })) {
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) { if ($AllowMissingLeaf) { break }; Throw-CcodError 'CCOD_PATH_MISSING' 'Required contained path is missing' $cursor }
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-CcodError 'CCOD_REPARSE_PATH' 'Contained path is a reparse point' $cursor }
    }
}
```

- [ ] **Step 4: Implement same-directory atomic UTF-8 JSON replacement**

Serialize at depth 16, write a random sibling temporary file with `UTF8Encoding($false)`, flush it, then call `File.Replace` when the target exists or `File.Move` when it does not. Always remove an unconsumed temporary file in `finally`.

```powershell
function Write-CcodAtomicJson([string]$Path, $Value) {
    $directory = Split-Path $Path -Parent
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 16) + "`n"), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $null, $true) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
```

- [ ] **Step 5: Implement strict reads, quarantine, and bounded rotation**

`Read-CcodStrictJson` must reject missing files, malformed JSON, non-object roots, and schema mismatch with stable IDs `CCOD_STATE_MISSING`, `CCOD_STATE_MALFORMED`, and `CCOD_SCHEMA_UNSUPPORTED`. `Move-CcodCorruptState` moves only a contained file to `<name>.corrupt.<UTC timestamp>.<GUID>`. `Write-CcodRotatingLog` rotates before append and removes generations older than 10.

- [ ] **Step 6: Run component and aggregate tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\PersistenceIO.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
```

Expected: both exit 0 and leave no temporary test root.

- [ ] **Step 7: Commit**

```powershell
git add src/persistence/modules/PersistenceIO.psm1 tests/persistence/PersistenceIO.SelfTest.ps1
git commit -m "feat: add safe persistence IO"
```

### Task 3: Versioned Runtime Manifest and Active/Previous Switching

**Files:**

- Create: `src/persistence/modules/RuntimeManifest.psm1`
- Create: `tests/persistence/RuntimeManifest.SelfTest.ps1`

**Interfaces:**

- Consumes: atomic I/O and contained-path functions from Task 2.
- Produces: `Get-CcodRuntimeId`, `New-CcodRuntimeManifest`, `Test-CcodRuntimeManifest`, `Read-CcodActiveRuntime`, and `Set-CcodActiveRuntime`.
- `active.json` schema 1 contains `activeRuntime`, nullable `previousRuntime`, `schemaVersion`, and `updatedAtUtc`.

- [ ] **Step 1: Write failing deterministic-manifest tests**

Create a temporary runtime with two text files and assert ordering, lowercase SHA-256, stable runtime ID, self-exclusion, tamper rejection, invalid runtime-id rejection, active/previous rotation, and path escape rejection:

```powershell
$manifest = New-CcodRuntimeManifest -RuntimeDirectory $runtime -ProjectVersion '2.0.0'
Assert-CcodTrue ($manifest.runtimeId -match '^[A-Za-z0-9._-]{1,96}$') 'safe runtime id'
Assert-CcodEqual 'a.txt' $manifest.files[0].path 'files sorted ordinally'
Assert-CcodTrue ($manifest.files[0].sha256 -cmatch '^[0-9a-f]{64}$') 'lowercase hash'
Write-CcodAtomicJson -Path (Join-Path $runtime 'manifest.json') -Value $manifest
Assert-CcodTrue (Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $manifest.runtimeId).Valid 'manifest verifies'
[IO.File]::AppendAllText((Join-Path $runtime 'a.txt'), 'tampered')
Assert-CcodEqual $false (Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $manifest.runtimeId).Valid 'tamper rejected'
```

- [ ] **Step 2: Run and verify failure for the missing module**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\RuntimeManifest.SelfTest.ps1`

Expected: nonzero exit naming `RuntimeManifest.psm1`.

- [ ] **Step 3: Implement deterministic file records and runtime ID**

Enumerate regular files recursively, reject reparse points, exclude `manifest.json`, normalize separators to `/`, sort with `Ordinal`, and hash the canonical record stream:

```powershell
$recordLines = foreach ($file in $files) {
    $relative = $file.FullName.Substring($rootPrefix.Length).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    [pscustomobject]@{ path = $relative; length = [int64]$file.Length; sha256 = $hash }
}
$canonical = ($recordLines | ForEach-Object { '{0}`t{1}`t{2}' -f $_.path, $_.length, $_.sha256 }) -join "`n"
$digest = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-', '').ToLowerInvariant()
$runtimeId = ('{0}-{1}' -f $ProjectVersion, $digest.Substring(0, 16))
```

- [ ] **Step 4: Implement strict manifest verification**

Require schema 1, exact `runtimeId`, unique sorted relative paths, exact file set, exact byte lengths and hashes, no manifest self-entry, and no absolute/traversal/reparse path. Return `{Valid, Code, RuntimeId, Manifest}` without throwing for content mismatch; throw only for unsafe path input.

- [ ] **Step 5: Implement active/previous atomic switching**

`Set-CcodActiveRuntime -InstallRoot -NewRuntimeId` first validates the new manifest, reads the existing active pointer if present, writes `previousRuntime=<old active>` and `activeRuntime=<new>`, and never points at an unverified directory. `Read-CcodActiveRuntime` rejects unsupported schema and validates both IDs before returning them.

- [ ] **Step 6: Run tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\RuntimeManifest.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
```

Expected: both exit 0.

- [ ] **Step 7: Commit**

```powershell
git add src/persistence/modules/RuntimeManifest.psm1 tests/persistence/RuntimeManifest.SelfTest.ps1
git commit -m "feat: add versioned runtime manifests"
```

### Task 4: AppX, Node, and Static Compatibility Classification

**Files:**

- Create: `src/persistence/modules/CompatibilityProbe.psm1`
- Create: `tests/persistence/CompatibilityProbe.SelfTest.ps1`
- Modify: `Test-CodexControlOtherDevices.ps1`

**Interfaces:**

- Consumes: `inspectPackage` JSON from Task 1.
- Produces: `Get-CcodPackageIdentity`, `Resolve-CcodNodeCandidate`, `Invoke-CcodStaticProbe`, and `Get-CcodPackageClassification`.
- Preserves: existing `Test-CodexControlOtherDevices.ps1 -Json` fields and exit behavior.
- Adds: `-NodePath`, `SchemaVersion`, `PackageFullName`, `PackageFamilyName`, `AppAsarSha256`, `StaticClassification`, and `NodeCapabilities`.

- [ ] **Step 1: Write failing adapter-driven classification tests**

Use fakes instead of real AppX or Node:

```powershell
$adapters = @{
    GetPackage = { [pscustomobject]@{ PackageFullName='OpenAI.Codex_1_x64__2p2nqsd0c76g0'; PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version='1.0.0.0'; InstallLocation='C:\Fake\Codex' } }
    InvokeNode = { param($NodePath, $Arguments) [pscustomobject]@{ ExitCode=0; Stdout='{"schemaVersion":1,"classification":"CandidateCompatible","appAsarSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","nativeModulePresent":false,"signatures":{}}'; Stderr='' } }
    GetNodeVersion = { param($NodePath) 'v22.23.1' }
}
$result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters $adapters
Assert-CcodEqual 'CandidateCompatible' $result.StaticClassification 'all evidence permits one dynamic trial'
Assert-CcodEqual 'OpenAI.Codex_2p2nqsd0c76g0' $result.FamilyName 'family retained'
```

Add cases for `NativeModulePresent`, missing one sentinel, checker failure, Node 21, malformed checker JSON, a relative Node path, and all candidates missing. Assert every uncertain case becomes `UnknownOrIncompatible` without throwing a process-changing exception.

- [ ] **Step 2: Run and verify missing module failure**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\CompatibilityProbe.SelfTest.ps1`

Expected: nonzero exit naming `CompatibilityProbe.psm1`.

- [ ] **Step 3: Implement package identity with no persisted WindowsApps trust**

The real adapter calls `Get-AppxPackage -Name OpenAI.Codex`, requires exactly one current-user package, and builds paths from the returned `InstallLocation` on every call. Reject an unexpected family name before invoking Node.

```powershell
function Get-CcodPackageIdentity([hashtable]$Adapters) {
    $package = & $Adapters.GetPackage
    if ($null -eq $package) { return [pscustomobject]@{ Found=$false; StaticClassification='UnknownOrIncompatible'; Code='PACKAGE_NOT_FOUND' } }
    if ($package.PackageFamilyName -ne 'OpenAI.Codex_2p2nqsd0c76g0') { return [pscustomobject]@{ Found=$false; StaticClassification='UnknownOrIncompatible'; Code='PACKAGE_FAMILY_MISMATCH' } }
    [pscustomobject]@{
        Found = $true
        FullName = [string]$package.PackageFullName
        FamilyName = [string]$package.PackageFamilyName
        Version = [string]$package.Version
        ExecutablePath = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        AppAsarPath = Join-Path $package.InstallLocation 'app\resources\app.asar'
        NativeDirectory = Join-Path $package.InstallLocation 'app\resources\native'
    }
}
```

- [ ] **Step 4: Implement installer-verified Node candidate resolution**

`Resolve-CcodNodeCandidate` accepts only rooted, existing file paths from the supplied array, normalizes each, executes `--version`, requires major version at least 22, and returns the first passing path plus version/capabilities. It never calls `Get-Command node.exe` unless `Test-CodexControlOtherDevices.ps1` is being used manually without `-NodePath`.

- [ ] **Step 5: Implement one-JSON checker invocation and classification**

Capture stdout and stderr separately. Require exit 0, exactly one JSON object, schema 1, 64 lowercase hex hash, and one of the three exact classifications. `NativeModulePresent` and all malformed/partial results set `Ready=false`; only `CandidateCompatible` sets the current backward-compatible `AffectedBuildDetected=true`.

- [ ] **Step 6: Refactor the public preflight into a thin formatter**

Keep the current human output and old JSON fields. With `-NodePath`, pass only that path. Without it, resolve `Get-Command node.exe` for backward-compatible manual use and pass the resulting absolute path into the module.

- [ ] **Step 7: Run hermetic and read-only live checks**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\CompatibilityProbe.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CodexControlOtherDevices.ps1 -Json
```

Expected: self-test exits 0. Live preflight emits exactly one JSON object and does not start or stop Codex; its exit may be 1 only if the currently installed package is safely classified as unsupported.

- [ ] **Step 8: Commit**

```powershell
git add src/persistence/modules/CompatibilityProbe.psm1 tests/persistence/CompatibilityProbe.SelfTest.ps1 Test-CodexControlOtherDevices.ps1
git commit -m "feat: add strict Codex compatibility probe"
```

### Task 5: Versioned State Schemas and Fail-Closed Defaults

**Files:**

- Create: `src/persistence/modules/StateStore.psm1`
- Create: `tests/persistence/StateStore.SelfTest.ps1`

**Interfaces:**

- Consumes: strict JSON/quarantine functions from Task 2.
- Produces: `Initialize-CcodState`, `Read-CcodState`, `Repair-CcodState`, `Read-CcodSettings`, `Write-CcodSettings`, `Read-CcodStatus`, `Write-CcodStatus`, `Read-CcodVerifiedPackages`, `Write-CcodVerifiedPackages`, `Set-CcodAutomationEnabled`, `Set-CcodCandidateCompatibleOptIn`, `Get-CcodAttemptKey`, `Get-CcodRecoveryIgnoreKey`, `Get-CcodSuppressionKey`, `Get-CcodStaticKey`, and `Resolve-CcodDeviceKeyStorePath`.
- Settings schema 1 includes `automationEnabled`, `candidateCompatibleOptIn`, `nodeCandidates`, and `updatedAtUtc`.

- [ ] **Step 1: Write failing schema, corruption, and key tests**

```powershell
Initialize-CcodState -StateRoot $state -NodeCandidates @('C:\Node\node.exe') -CandidateCompatibleOptIn $true
$loaded = Read-CcodState -StateRoot $state
Assert-CcodEqual $true $loaded.Settings.candidateCompatibleOptIn 'opt-in persisted independently'
Assert-CcodEqual $true $loaded.Settings.automationEnabled 'fresh explicit install enables automation'
Assert-CcodEqual '100|2026-08-02T00:00:00.0000000Z' (Get-CcodAttemptKey -Pid 100 -CreationTimeUtc '2026-08-02T00:00:00.0000000Z') 'attempt key'
Assert-CcodEqual 'pkg|hash|runtime' (Get-CcodSuppressionKey -PackageFullName 'pkg' -AppAsarSha256 'hash' -RuntimeId 'runtime') 'suppression key'
[IO.File]::WriteAllText((Join-Path $state 'verified-packages.json'), '{broken')
$damaged = Read-CcodState -StateRoot $state
Assert-CcodEqual $false $damaged.AutomaticCandidateTrialsAllowed 'damaged history cannot re-authorize a trial'
```

Test every missing/corrupt/unknown-schema file separately. Assert `settings` damage disables automation, `verified` damage disables candidate trials, `transition` damage forbids stop/start/recover, and `status` is rebuildable only after a supplied live-probe result.

- [ ] **Step 2: Run and verify missing module failure**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\StateStore.SelfTest.ps1`

Expected: nonzero exit naming `StateStore.psm1`.

- [ ] **Step 3: Implement exact schema constructors**

```powershell
function New-CcodSettings([string[]]$NodeCandidates, [bool]$CandidateCompatibleOptIn, [bool]$AutomationEnabled, [string]$UpdatedAtUtc) {
    [ordered]@{
        schemaVersion = 1
        automationEnabled = $AutomationEnabled
        candidateCompatibleOptIn = $CandidateCompatibleOptIn
        nodeCandidates = @($NodeCandidates)
        updatedAtUtc = $UpdatedAtUtc
    }
}
function New-CcodTransitionStore {
    [ordered]@{ schemaVersion = 1; activeTransaction = $null }
}
```

Also create schema-1 empty status and verified-package stores. The installer is the only code allowed to call `Initialize-CcodState`; the supervisor never interprets missing files as a first run.
Pass `UpdatedAtUtc` from the injected clock adapter so state tests never depend on wall-clock timing.

- [ ] **Step 4: Implement fail-closed reads and quarantine**

Return a state aggregate with `AutomationEnabled`, `AutomaticCandidateTrialsAllowed`, `TransitionActionsAllowed`, `Damage`, and parsed stores. Quarantine damaged evidence, but do not overwrite it automatically. The typed Read/Write functions enforce schema 1 and always use atomic replacement. `Set-CcodAutomationEnabled` and `Set-CcodCandidateCompatibleOptIn` each rewrite only their own setting while preserving the other boolean and Node candidates. `Repair-CcodState` creates fresh stores with both booleans false and keeps timestamped quarantined files.

- [ ] **Step 5: Implement distinct key lifetimes**

Use invariant strings:

```powershell
function Get-CcodAttemptKey([int]$Pid, [string]$CreationTimeUtc) { '{0}|{1}' -f $Pid, $CreationTimeUtc }
function Get-CcodRecoveryIgnoreKey([int]$Pid, [string]$CreationTimeUtc, [string]$TransactionId) { '{0}|{1}|{2}' -f $Pid, $CreationTimeUtc, $TransactionId }
function Get-CcodSuppressionKey([string]$PackageFullName, [string]$AppAsarSha256, [string]$RuntimeId) { '{0}|{1}|{2}' -f $PackageFullName, $AppAsarSha256, $RuntimeId }
function Get-CcodStaticKey([string]$PackageFullName, [string]$AppAsarSha256) { '{0}|{1}' -f $PackageFullName, $AppAsarSha256 }
```

- [ ] **Step 6: Implement the shared device-key path resolver**

If `CODEX_HOME` is set, require it to be absolute and use it; otherwise use `[Environment]::GetFolderPath('UserProfile')\.codex`. Append only `remote-control-device-keys.windows.json`. This function never reads, moves, or deletes the key file.

- [ ] **Step 7: Run tests and commit**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\StateStore.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
```

Then commit:

```powershell
git add src/persistence/modules/StateStore.psm1 tests/persistence/StateStore.SelfTest.ps1
git commit -m "feat: add fail-closed supervisor state"
```

### Task 6: Exact Process Identity, Adoption, and Compare-and-Stop

**Files:**

- Create: `src/persistence/modules/ProcessControl.psm1`
- Create: `tests/persistence/ProcessControl.SelfTest.ps1`

**Interfaces:**

- Produces: `Get-CcodProcessSnapshot`, `Test-CcodProcessMatch`, `Get-CcodVerifiedProcessTree`, `Find-CcodTransactionProcess`, `Stop-CcodProcessIfMatch`, `Start-CcodProcess`, `Get-CcodAvailableLoopbackPort`, and `Wait-CcodPortClosed`.
- Real process adapter uses `GetPackageFamilyName` for package identity and CIM only for command line/parent metadata.

- [ ] **Step 1: Write failing identity and race tests with fake snapshots**

```powershell
$expected = [pscustomobject]@{ Pid=100; CreationTimeUtc='2026-08-02T00:00:00.0000000Z'; SessionId=1; UserSid='S-1-5-21-test'; Path='C:\Codex\ChatGPT.exe'; PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'; CommandLine='"C:\Codex\ChatGPT.exe"'; IsTopLevel=$true; Mode='Ordinary' }
Assert-CcodTrue (Test-CcodProcessMatch -Expected $expected -Actual $expected) 'exact snapshot matches'
$reused = $expected.PSObject.Copy(); $reused.CreationTimeUtc='2026-08-02T00:00:02.0000000Z'
Assert-CcodEqual $false (Test-CcodProcessMatch -Expected $expected -Actual $reused) 'PID reuse rejected'
$result = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{ GetProcess={ $null }; StopProcess={ throw 'must not run' } }
Assert-CcodEqual 'SourceExited' $result.Outcome 'natural exit cancels transition'
Assert-CcodEqual $false $result.StoppedByController 'natural exit never authorizes special launch'
```

Add cases for child `--type=renderer`, other user/session, path mismatch, family mismatch, wrong debugger ports, multiple transaction candidates, delayed exit, and a stop adapter returning no confirmed receipt.

- [ ] **Step 2: Run and verify missing module failure**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\ProcessControl.SelfTest.ps1`

Expected: nonzero exit naming `ProcessControl.psm1`.

- [ ] **Step 3: Add the package-family P/Invoke and snapshot constructor**

Compile a small namespaced C# helper once per process for `GetPackageFamilyName`. Return `$null` for `APPMODEL_ERROR_NO_PACKAGE`; treat every other error as identity failure. Capture process creation time before and after CIM metadata and reject if it changed.

- [ ] **Step 4: Implement ordinary/special classification**

An eligible root must match current SID, current Session ID, `ChatGPT.exe`, dynamic exact executable path, exact family, and no `--type=`. Special mode additionally requires exact `--remote-debugging-address=127.0.0.1`, numeric renderer/main ports, matching status identity, exact renderer URL, and a successful live probe. Parent PID alone is never sufficient.

- [ ] **Step 5: Implement compare-and-stop with an explicit receipt**

`Stop-CcodProcessIfMatch` re-reads the snapshot immediately before opening the process handle, compares every identity field, invokes the stop adapter, waits on that exact handle, and returns only one of:

```powershell
[pscustomobject]@{ Outcome='Stopped'; StoppedByController=$true; Snapshot=$actual }
[pscustomobject]@{ Outcome='SourceExited'; StoppedByController=$false; Snapshot=$null }
[pscustomobject]@{ Outcome='IdentityChanged'; StoppedByController=$false; Snapshot=$actual }
[pscustomobject]@{ Outcome='StopUnconfirmed'; StoppedByController=$false; Snapshot=$actual }
```

- [ ] **Step 6: Implement verified tree collection, transaction adoption, and safe launching**

`Get-CcodVerifiedProcessTree` starts from the exact root snapshot and includes only descendants whose parent chain reaches that root and whose creation time is not older than the root; re-read identity before termination. Find special candidates by current Session, exact package identity, both expected ports, and creation time at or after the transaction timestamp. Adopt only one. Recovery adopts any exact ordinary root before starting another. `Start-CcodProcess` uses `Start-Process -WindowStyle Hidden` only for background helpers; the Codex window itself is launched normally.

- [ ] **Step 7: Implement port helpers**

Reserve random IPv4 loopback ports, require the two ports differ, recheck before launch, and treat a binding race as a failed special launch. `Wait-CcodPortClosed` succeeds only after explicit `ECONNREFUSED`; timeout or an unrelated listener fails.

- [ ] **Step 8: Run tests and commit**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\ProcessControl.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
```

Then commit:

```powershell
git add src/persistence/modules/ProcessControl.psm1 tests/persistence/ProcessControl.SelfTest.ps1
git commit -m "feat: add exact Codex process control"
```

### Task 7: Durable Transition Journal and Crash Replay Decisions

**Files:**

- Create: `src/persistence/modules/TransitionJournal.psm1`
- Create: `tests/persistence/TransitionJournal.SelfTest.ps1`

**Interfaces:**

- Consumes: atomic state writes, state keys, and process/adoption functions from Tasks 2, 5, and 6.
- Produces: `New-CcodTransition`, `Set-CcodTransitionStage`, `Read-CcodTransition`, `Get-CcodReplayDecision`, and `Complete-CcodTransition`.
- Stage order: `IntentWritten`, `StopRequested`, `OrdinaryStopped`, `SpecialLaunchRequested`, `SpecialStarted`, `Validated`, `RecoveryLaunchRequested`, `Recovered`.

- [ ] **Step 1: Write failing stage-CAS and replay-table tests**

```powershell
$tx = New-CcodTransition -Source $source -Package $package -RuntimeId '2.0.0-deadbeef' -RendererPort 41001 -MainPort 41002 -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda'
Assert-CcodEqual 'IntentWritten' $tx.stage 'initial stage'
Set-CcodTransitionStage -Path $journal -ExpectedStage 'IntentWritten' -NewStage 'StopRequested'
Assert-CcodThrows { Set-CcodTransitionStage -Path $journal -ExpectedStage 'IntentWritten' -NewStage 'OrdinaryStopped' } 'CCOD_TRANSITION_CONFLICT'
$replayTx = $tx.PSObject.Copy()
$replayTx.stage = 'SpecialLaunchRequested'
Assert-CcodEqual 'RecoverOrdinary' (Get-CcodReplayDecision -Transition $replayTx -Observed @{ SpecialCandidates=@(); OrdinaryCandidates=@() }).Action 'interrupted special launch recovers ordinary'
```

Cover every stage, `StopRequested` source alive/exited/late exit, unique/multiple special candidates, valid special adoption, `RecoveryLaunchRequested` ordinary adoption, repeated replay, and terminal archival.

- [ ] **Step 2: Run and verify missing module failure**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\TransitionJournal.SelfTest.ps1`

Expected: nonzero exit naming `TransitionJournal.psm1`.

- [ ] **Step 3: Implement schema-1 transition creation and expected-stage CAS**

Store `schemaVersion` and nullable `activeTransaction` at the top level. The transaction contains all fixed fields from the design, including source/special/recovery identities and both ports. `Set-CcodTransitionStage` reads the current file, verifies `transactionId` and `ExpectedStage`, creates a new immutable ordered object, and atomically writes it before the next external action.

- [ ] **Step 4: Implement the pure replay decision table**

Return an object with `Action`, `Reason`, `AdoptedProcess`, and `MustSuppress`. Use this exact action set:

```powershell
$actions = @(
    'CancelKeepOrdinary',
    'ObserveStopRequested',
    'AdoptValidatedSpecial',
    'TerminateSpecialThenRecover',
    'RecoverOrdinary',
    'AdoptOrdinaryRecovery',
    'SuppressAndWaitForUser'
)
```

No replay path starts a new special session. `StopRequested` observes the exact handle for five seconds and then guards the exact PID for another five seconds. `SpecialLaunchRequested` and `SpecialStarted` adopt only one transaction-matching special process. `RecoveryLaunchRequested` observes for five seconds and adopts an ordinary process before launching one.

- [ ] **Step 5: Implement terminal archival and idempotency**

Append a sanitized terminal record to the rotating transaction log, then atomically set `activeTransaction=$null`. Calling completion again with the same transaction ID returns `AlreadyCompleted` and performs no process action.

- [ ] **Step 6: Run tests and commit**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\TransitionJournal.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
```

Then commit:

```powershell
git add src/persistence/modules/TransitionJournal.psm1 tests/persistence/TransitionJournal.SelfTest.ps1
git commit -m "feat: add crash-safe transition journal"
```

### Task 8: Transactional Session Engine and Machine-Readable Controller

**Files:**

- Create: `src/persistence/modules/SessionEngine.psm1`
- Create: `src/persistence/SessionController.ps1`
- Create: `tests/persistence/SessionEngine.SelfTest.ps1`
- Modify: `src/runtime/orchestrator.js`
- Modify: `tests/CleanroomSelfTest.js`
- Modify: `Start-CodexControlOtherDevices.ps1`
- Modify: `Reset-CodexControlOtherDevices.ps1`

**Interfaces:**

- Consumes: package, state, process, and journal modules from Tasks 4–7 plus the existing `src/runtime/orchestrator.js` protocol.
- Produces: `Invoke-CcodInspectSession`, `Invoke-CcodApplySession`, `Invoke-CcodRepairRenderer`, `Invoke-CcodRecoverSession`, `Invoke-CcodReplayTransition`, and `Test-CcodBridgeResult`.
- Controller actions: `Inspect`, `Apply`, `RepairRenderer`, and `Recover`; stdout is exactly one compressed schema-1 JSON envelope.
- Public `Start` keeps `RendererDebugPort`, `MainInspectorPort`, and `TimeoutSeconds`. Public `Reset` keeps `BackupDeviceKeyStore` and `DoNotRestart`.

- [ ] **Step 1: Write failing result-contract and transition tests**

Test success and every failure stage through injected adapters:

```powershell
$result = Invoke-CcodApplySession -Request ([pscustomobject]@{
    Action='Apply'; Source=$source; RuntimeId='2.0.0-deadbeef'; ExistingOnly=$true; RendererPort=41001; MainPort=41002; TimeoutMilliseconds=30000
}) -Paths $paths -Adapters $successfulAdapters
Assert-CcodEqual 1 $result.schemaVersion 'controller schema'
Assert-CcodEqual 'Activated' $result.outcome 'success outcome'
Assert-CcodEqual 'SpecialValidated' $result.safeState 'success requires probes'
Assert-CcodEqual $true $result.probes.main.inspectorPortClosed.confirmed 'main inspector refusal'
Assert-CcodEqual $true $result.probes.renderer.newDocumentScriptInstalled 'future document coverage'
Assert-CcodEqual $true $result.probes.renderer.probe.proof 'non-empty renderer proof'
```

Add cases for source exit during preflight, changed identity before stop, unconfirmed stop, renderer-port race, main failure, renderer failure, malformed bridge JSON, failure to close each port, recovery adoption, recovery launch once, renderer target replacement/repair, and suppression after incomplete replay. Assert no failure terminates a process outside the transaction snapshot.

- [ ] **Step 2: Run and verify missing engine failure**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\SessionEngine.SelfTest.ps1`

Expected: nonzero exit naming `SessionEngine.psm1`.

- [ ] **Step 3: Implement the stable result envelope factory**

```powershell
function New-CcodControllerResult([string]$Action, [string]$Outcome, [string]$SafeState, [string]$Stage, [string]$TransactionId) {
    [ordered]@{
        schemaVersion = 1; action = $Action; ok = $false; outcome = $Outcome
        safeState = $SafeState; stage = $Stage; transactionId = $TransactionId
        package = $null; source = $null; special = $null; probes = [ordered]@{}
        recovery = [ordered]@{}; error = $null; logFile = $null
    }
}
```

Errors use stable `error.code`, `error.stage`, and a newline-free message capped at 300 characters. Logs are redacted and written separately; they never share stdout.

- [ ] **Step 4: Implement Apply as journaled external actions**

Use this order exactly: static probe; source re-read; create intent; write `StopRequested`; compare-and-stop; require `StoppedByController`; write `OrdinaryStopped`; allocate/recheck ports; write `SpecialLaunchRequested`; start special; write `SpecialStarted`; invoke Node orchestrator; validate bridge; write `Validated`; update status/verified history; complete journal. Any exception after confirmed stop enters `Recover` once and writes the compatibility suppression key.

- [ ] **Step 5: Implement strict bridge validation**

Require orchestrator exit 0 and one JSON object with `ok=true`, `protocolVersion=1`, main `confirmed=true` and code `ECONNREFUSED`, renderer `newDocumentScriptInstalled=true`, and probe `proof=true` for target gate `782640499`. Treat missing fields as `BRIDGE_PROOF_INCOMPLETE`.

- [ ] **Step 6: Add renderer-only repair without reopening the main Inspector**

Extend `orchestrator.js` with optional `--mode full|renderer`, defaulting to `full` so the existing CLI remains compatible. Renderer mode command is `node orchestrator.js --mode renderer --renderer-port PORT --timeout-ms MS`; it selects the exact URL, installs current/new-document scripts, and returns the same renderer proof without accepting or connecting to a main port. Export and self-test the mode parser and renderer runner. `Invoke-CcodRepairRenderer` first revalidates the special process/package/status/port and uses renderer mode; failure normalizes to an ordinary session and suppresses the package/runtime combination.

- [ ] **Step 7: Implement Recover and replay**

Stop only a special PID/creation time proven by the active transaction, verify both recorded ports reach refusal, write `RecoveryLaunchRequested`, observe/adopt an ordinary root for five seconds, start one only if none exists, write `Recovered`, set the recovery-ignore and suppression keys, archive, and clear the active transaction.

- [ ] **Step 8: Implement the controller CLI framing**

Use `-RequestPath` and `-ResultPath` for supervisor calls and direct parameters only for manual compatibility. In supervisor mode, validate a strict schema-1 request, atomically write the result file, emit the same compressed object once on stdout, and set exit 0 only for safe `Activated`, `Inspected`, `NoAction`, or `Recovered` outcomes.

- [ ] **Step 9: Convert manual Start and Reset into thin wrappers**

`Start` may use `ExistingOnly=false` to preserve manual “start when closed” behavior. When no source exists, the engine writes a manual transaction with `source=null`, skips `StopRequested`, enters `OrdinaryStopped`, and still performs ordinary recovery if special launch fails. `Reset` calls the exact recover/normalize path, then optionally moves the device-key store using `Resolve-CcodDeviceKeyStorePath`. Neither wrapper contains its own process-kill loop.

- [ ] **Step 10: Run engine and clean-room regression tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\SessionEngine.SelfTest.ps1
node.exe .\tests\CleanroomSelfTest.js
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
```

Expected: all exit 0; no real Codex process is touched.

- [ ] **Step 11: Commit**

```powershell
git add src/persistence/modules/SessionEngine.psm1 src/persistence/SessionController.ps1 tests/persistence/SessionEngine.SelfTest.ps1 src/runtime/orchestrator.js tests/CleanroomSelfTest.js Start-CodexControlOtherDevices.ps1 Reset-CodexControlOtherDevices.ps1
git commit -m "feat: add transactional session controller"
```

### Task 9: Pure Supervisor Reconciliation Engine

**Files:**

- Create: `src/persistence/modules/SupervisorEngine.psm1`
- Create: `tests/persistence/SupervisorEngine.SelfTest.ps1`

**Interfaces:**

- Consumes: package/process/state shapes from Tasks 4–6.
- Produces: `Get-CcodSupervisorDecision`, `Add-CcodObservedEvent`, `Complete-CcodControllerRun`, and `Get-CcodTrayPresentation`.
- Decision actions: `Wait`, `AdoptSpecial`, `RepairRenderer`, `InspectOrdinary`, `ApplyOrdinary`, `KeepOrdinary`, `ReplayTransition`, and `ShowError`.
- The package checker emits only the three static classifications. Supervisor context promotes `CandidateCompatible` to `VerifiedCompatible` only when the exact package-full-name/hash/runtime key has a successful dynamic record.

- [ ] **Step 1: Write the failing decision matrix**

```powershell
$decision = Get-CcodSupervisorDecision -Context ([pscustomobject]@{
    AutomationEnabled=$true; CandidateCompatibleOptIn=$true; ActiveTransaction=$null
    Classification='CandidateCompatible'; Ordinary=@($ordinary); Special=@()
    AttemptKeys=@{}; RecoveryIgnoreKeys=@{}; SuppressionKeys=@{}
})
Assert-CcodEqual 'ApplyOrdinary' $decision.Action 'authorized candidate applies once'
$decision = Get-CcodSupervisorDecision -Context ([pscustomobject]@{
    AutomationEnabled=$true; CandidateCompatibleOptIn=$false; ActiveTransaction=$null
    Classification='CandidateCompatible'; Ordinary=@($ordinary); Special=@()
    AttemptKeys=@{}; RecoveryIgnoreKeys=@{}; SuppressionKeys=@{}
})
Assert-CcodEqual 'KeepOrdinary' $decision.Action 'candidate opt-in is independent'
```

Cover no process, validated special, renderer target replacement requiring repair, paused automation with active special, unknown/native-module builds, suppressed package/runtime, recovery PID, duplicate WMI events, new PID after user restart, different Session, state damage, active transaction, and controller child already running.

- [ ] **Step 2: Run and verify missing module failure**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\SupervisorEngine.SelfTest.ps1`

Expected: nonzero exit naming `SupervisorEngine.psm1`.

- [ ] **Step 3: Implement a pure, side-effect-free decision function**

Order decisions so recovery and safety dominate convenience:

```powershell
if ($Context.StateDamageBlocksActions) { return New-CcodDecision 'ShowError' 'StateDamaged' }
if ($null -ne $Context.ActiveTransaction) { return New-CcodDecision 'ReplayTransition' 'ActiveTransaction' }
if ($Context.Special.Count -eq 1 -and $Context.Special[0].ProbeValid) { return New-CcodDecision 'AdoptSpecial' 'ValidatedSpecial' }
if ($Context.Special.Count -eq 1 -and $Context.Special[0].IdentityValid -and -not $Context.Special[0].ProbeValid) { return New-CcodDecision 'RepairRenderer' 'RendererTargetChanged' }
if ($Context.Ordinary.Count -eq 0) { return New-CcodDecision 'Wait' 'NoCodex' }
if (-not $Context.AutomationEnabled) { return New-CcodDecision 'KeepOrdinary' 'AutomationDisabled' }
if ([string]::IsNullOrWhiteSpace($Context.Classification)) { return New-CcodDecision 'InspectOrdinary' 'StaticProbeRequired' }
if ($Context.Classification -ne 'CandidateCompatible' -and $Context.Classification -ne 'VerifiedCompatible') { return New-CcodDecision 'KeepOrdinary' $Context.Classification }
if ($Context.Classification -eq 'CandidateCompatible' -and -not $Context.CandidateCompatibleOptIn) { return New-CcodDecision 'KeepOrdinary' 'CandidateOptInRequired' }
```

Then apply attempt/recovery/suppression keys and permit one queued controller request.
`Add-CcodObservedEvent` adds only a previously unseen `Pid|CreationTimeUtc` key and returns `$true`; duplicates return `$false`. Remove the key only after that exact process exits. This function never performs process I/O itself.

- [ ] **Step 4: Implement controller completion reduction**

Map controller `safeState`, not its attempted action, to new session status. Only `SpecialValidated` becomes `Active`; `OrdinaryRunning` after failure becomes `Recovered`; state/identity uncertainty becomes `Error` and disables new automatic actions.

- [ ] **Step 5: Implement tray presentation as pure data**

Return `Color`, `Tooltip`, `StatusText`, and menu enable/checked flags. An active special session remains green even when future automation is paused; the tooltip states both conditions.

- [ ] **Step 6: Run tests and commit**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\SupervisorEngine.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
```

Then commit:

```powershell
git add src/persistence/modules/SupervisorEngine.psm1 tests/persistence/SupervisorEngine.SelfTest.ps1
git commit -m "feat: add supervisor decision engine"
```

### Task 10: WinForms Tray Host and WMI Capability Fallback

**Files:**

- Create: `src/persistence/modules/KernelObjects.psm1`
- Create: `src/persistence/modules/TrayUi.psm1`
- Create: `src/persistence/Supervisor.ps1`
- Create: `tests/persistence/KernelObjects.SelfTest.ps1`
- Create: `tests/persistence/TrayUi.SelfTest.ps1`

**Interfaces:**

- Consumes: pure decisions/presentations from Task 9 and controller CLI from Task 8.
- Produces: `Get-CcodKernelObjectName`, `New-CcodMutexSecurity`, `New-CcodEventSecurity`, `Enter-CcodMutex`, `New-CcodEvent`, `New-CcodTrayContext`, `Set-CcodTrayPresentation`, `Start-CcodProcessWatcher`, `Stop-CcodProcessWatcher`, and the long-running supervisor entrypoint.
- Watcher mode is `Trace`, `Intrinsic`, or `ReconciliationOnly`.

- [ ] **Step 1: Write failing kernel-object, presentation, and watcher-fallback tests**

Test menu binding without showing UI and inject watcher adapters:

```powershell
$watcher = Start-CcodProcessWatcher -Queue $queue -Adapters @{
    RegisterTrace = { throw [System.Management.ManagementException]::new('Access denied') }
    RegisterIntrinsic = { [pscustomobject]@{ SourceIdentifier='ccod-intrinsic'; JobId=7 } }
}
Assert-CcodEqual 'Intrinsic' $watcher.Mode 'access denied falls back without elevation'
$presentation = Get-CcodTrayPresentation -SessionState 'Active' -AutomationEnabled $false
Assert-CcodEqual 'Green' $presentation.Color 'active CDP remains visible while paused'
Assert-CcodTrue ($presentation.Tooltip -match 'paused') 'tooltip shows future automation paused'
```

Add `ReconciliationOnly`, duplicate event, command enablement, and disposal tests.

In `KernelObjects.SelfTest.ps1`, assert the exact `Local\CodexControlOtherDevices.<Kind>.<SID>.<SessionId>` name, allowed SID set, cross-process mutual exclusion, event signaling, ACL mismatch rejection, and abandoned mutex acquisition/recovery logging.

- [ ] **Step 2: Run and verify missing module failure**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\KernelObjects.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\TrayUi.SelfTest.ps1
```

Expected: nonzero exits naming the missing modules.

- [ ] **Step 3: Implement SID/Session-scoped kernel objects and ACL validation**

Build `MutexSecurity` and `EventWaitHandleSecurity` with FullControl only for current user, LocalSystem, and BuiltinAdministrators. On an existing object, read and compare its allow list before use. Treat `AbandonedMutexException` as an acquired lease that requires transition replay and a warning log, not as an unlocked/no-op condition.

- [ ] **Step 4: Implement temporary watcher capability fallback**

Try `Register-WmiEvent -Class Win32_ProcessStartTrace`. On `ManagementException` or access denial, register this temporary query:

```sql
SELECT * FROM __InstanceCreationEvent WITHIN 1
WHERE TargetInstance ISA 'Win32_Process'
AND TargetInstance.Name = 'ChatGPT.exe'
```

Callbacks enqueue only PID, event kind, and observed UTC into a `ConcurrentQueue[object]`. Identity is re-read when the UI timer drains the queue. Always run authoritative reconciliation every three seconds. Cleanup unregisters the subscriber, removes its job, and drains queued events.

- [ ] **Step 5: Implement cached colored icons without leaked native handles**

Draw gray/green/yellow/red 16×16 and 32×32 circles once. Convert each bitmap HICON to an owned clone, call `DestroyIcon` immediately on the temporary handle, cache the cloned `Icon`, and dispose all clones at application exit. Never allocate an icon on each timer tick.

- [ ] **Step 6: Build the `ApplicationContext` and menu**

Create `NotifyIcon`, `ContextMenuStrip`, read-only status/package/runtime rows, and commands for Apply now, Manual retry, Pause/Resume, Allow controlled compatible-update trials, Open logs, and Uninstall. The opt-in checkbox calls only `Set-CcodCandidateCompatibleOptIn` and never silently enables automation. UI handlers enqueue command objects only. A 250 ms WinForms timer drains commands/events and polls one hidden controller child; no WMI callback touches a control.

- [ ] **Step 7: Run the controller as a hidden child with file framing**

Use `ProcessStartInfo` with system PowerShell, `UseShellExecute=false`, `CreateNoWindow=true`, hidden window, absolute request/result paths, and redirected stderr to the rotating log. Atomically write request JSON before start. Accept only a schema-1 result whose transaction ID matches the request.

During each three-second active-session reconciliation, run the read-only `Inspect` action when no controller child is active. If exact special identity remains valid but the renderer target/proof changed, enqueue one `RepairRenderer` request; never reopen the main Inspector.

- [ ] **Step 8: Implement supervisor initialization and ready signaling**

Acquire `Local\CodexControlOtherDevices.Supervisor.<SID>.<SessionId>` with explicit current-user/SYSTEM/Administrators ACL, load state, replay any valid transaction before ordinary reconciliation, construct tray/watcher, then open and set the one-time ready event. Reject a pre-existing kernel object whose ACL differs from the expected allow list.

- [ ] **Step 9: Run non-interactive tray tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\TrayUi.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\KernelObjects.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
```

Expected: both exit 0 without leaving a tray icon, event subscriber, job, or child process.

- [ ] **Step 10: Commit**

```powershell
git add src/persistence/modules/KernelObjects.psm1 src/persistence/modules/TrayUi.psm1 src/persistence/Supervisor.ps1 tests/persistence/KernelObjects.SelfTest.ps1 tests/persistence/TrayUi.SelfTest.ps1
git commit -m "feat: add persistent tray supervisor host"
```

### Task 11: Stable Bootstrap and Limited Scheduled Task

**Files:**

- Create: `src/persistence/bootstrap.ps1`
- Create: `src/persistence/modules/ScheduledTask.psm1`
- Create: `tests/persistence/Bootstrap.SelfTest.ps1`
- Create: `tests/persistence/ScheduledTask.SelfTest.ps1`

**Interfaces:**

- Consumes: runtime/active schema from Task 3, but bootstrap remains self-contained and imports no active-runtime code before verification.
- Produces: bootstrap ready/fallback behavior and `Get-CcodSupervisorTaskSpec`, `New-CcodSupervisorTaskDefinition`, `Install-CcodSupervisorTask`, `Get-CcodSupervisorTaskSnapshot`, `Remove-CcodSupervisorTask`.
- Fixed task name: `Codex Control Other Devices Supervisor`.

- [ ] **Step 1: Write failing bootstrap ready/fallback tests**

Build two temporary runtime directories. The active fake supervisor exits before ready; the previous fake opens the passed event, sets it, sleeps briefly, and exits 0. Run real bootstrap against the fixture and assert it selects previous, atomically updates `active.json`, never touches a Codex process, and exits 0. Add both-invalid, ready-timeout, invalid manifest, stale ready event, and later nonzero supervisor exit cases.

Fake supervisor body:

```powershell
param([string]$ReadyEventName)
$event = [Threading.EventWaitHandle]::OpenExisting($ReadyEventName)
$event.Set() | Out-Null
Start-Sleep -Milliseconds 200
exit 0
```

- [ ] **Step 2: Write failing pure scheduled-task spec tests**

```powershell
$spec = Get-CcodSupervisorTaskSpec -InstallRoot 'C:\Users\name\AppData\Local\CodexControlOtherDevices' -UserSid 'S-1-5-21-test'
Assert-CcodEqual 'Codex Control Other Devices Supervisor' $spec.TaskName 'fixed task name'
Assert-CcodEqual 'Interactive' $spec.LogonType 'maps to InteractiveToken XML'
Assert-CcodEqual 'Limited' $spec.RunLevel 'no elevation'
Assert-CcodEqual 'IgnoreNew' $spec.MultipleInstances 'single task instance'
Assert-CcodEqual 3 $spec.RestartCount 'bounded retries'
Assert-CcodEqual 'PT1M' $spec.RestartInterval 'one minute'
Assert-CcodEqual 'PT0S' $spec.ExecutionTimeLimit 'no 72-hour limit'
Assert-CcodTrue ($spec.Argument -match '-WindowStyle Hidden') 'background console hidden'
Assert-CcodTrue ([IO.Path]::IsPathRooted($spec.Execute)) 'absolute PowerShell path'
```

- [ ] **Step 3: Run both tests and verify missing implementations**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\Bootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\ScheduledTask.SelfTest.ps1
```

Expected: both fail because bootstrap/module does not exist.

- [ ] **Step 4: Implement self-contained bootstrap validation**

Bootstrap uses only .NET and its own local functions to parse schema-1 `active.json`, validate runtime-id regex, reject reparse paths, parse/validate schema-1 `manifest.json`, and compare every listed file length/hash before executing `Supervisor.ps1`. Do not dot-source any active runtime file during validation.

- [ ] **Step 5: Implement one-time ready and previous-runtime fallback**

Generate a 32-byte random token with `RandomNumberGenerator`, create `Local\CodexControlOtherDevices.Ready.<SID>.<SessionId>.<64 lowercase hex>` with explicit ACL, launch the runtime supervisor hidden, and wait at most 15 seconds. If it exits or times out before ready, stop that exact child, validate and try previous once. Only after previous signals ready, atomically make it active. After ready, wait for the child; propagate nonzero abnormal exit and zero intentional exit.

- [ ] **Step 6: Implement the task model and Windows adapter**

Build the task with these exact cmdlets/values:

```powershell
$action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument -WorkingDirectory $spec.WorkingDirectory
$principal = New-ScheduledTaskPrincipal -UserId $spec.UserSid -LogonType Interactive -RunLevel Limited
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $spec.UserSid
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings
```

`Install-CcodSupervisorTask` and `Remove-CcodSupervisorTask` honor `ShouldProcess`. Snapshot verification resolves the registered principal back to SID and parses exported XML for `InteractiveToken`, `PT0S`, battery values, and absolute action.

- [ ] **Step 7: Run tests and commit**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\Bootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\ScheduledTask.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
```

Then commit:

```powershell
git add src/persistence/bootstrap.ps1 src/persistence/modules/ScheduledTask.psm1 tests/persistence/Bootstrap.SelfTest.ps1 tests/persistence/ScheduledTask.SelfTest.ps1
git commit -m "feat: add stable bootstrap and logon task"
```

### Task 12: Atomic Install, Upgrade, Repair, and Safe Uninstall

**Files:**

- Create: `src/persistence/modules/InstallLifecycle.psm1`
- Create: `Install-CodexControlOtherDevices.ps1`
- Create: `Uninstall-CodexControlOtherDevices.ps1`
- Create: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `package.json`

**Interfaces:**

- Consumes: persistence, manifest, state, scheduled-task, process, and session modules.
- Produces: `Invoke-CcodInstall`, `Invoke-CcodRepairState`, and `Invoke-CcodUninstall`; public scripts only validate parameters, call these functions, and format results.
- Installer parameters: `InstallRoot`, `EnableCandidateCompatibleUpdates`, `RepairState`, `DoNotStart`, and standard `WhatIf/Confirm`.
- Uninstaller parameters: `InstallRoot`, `KeepCurrentSpecialSession`, `BackupDeviceKeyStore`, `RemoveDeviceKeyStore`, and standard `WhatIf/Confirm`.
- Produces: versioned runtime layout, stable bootstrap/uninstaller copies, active/previous pointer, initialized state, installed task, and complete cleanup.

- [ ] **Step 1: Write failing lifecycle tests with fake task/process adapters**

Use a temporary install root and a source fixture. Assert:

```powershell
$install = Invoke-CcodInstall -SourceRoot $source -InstallRoot $root -EnableCandidateCompatibleUpdates $true -Adapters $fakeAdapters
Assert-CcodEqual $true $install.Installed 'first install succeeds'
Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $root 'bootstrap.ps1')) 'stable bootstrap copied'
Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $root 'active.json')) 'active pointer written'
Assert-CcodEqual $true (Read-CcodState -StateRoot (Join-Path $root 'state')).Settings.candidateCompatibleOptIn 'explicit consent persisted'
$second = Invoke-CcodInstall -SourceRoot $sourceV2 -InstallRoot $root -EnableCandidateCompatibleUpdates $true -Adapters $fakeAdapters
Assert-CcodEqual $install.RuntimeId $second.PreviousRuntimeId 'upgrade retains one rollback runtime'
```

Add staging-copy failure, source reparse, hash mismatch, invalid active pointer, bootstrap ready rollback, old supervisor shutdown timeout, `RepairState` booleans false, `WhatIf`, ordinary uninstall, special-session normalization, explicit keep warning, key preservation, key backup/removal, and out-of-root deletion refusal.

- [ ] **Step 2: Run and verify missing lifecycle module**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\InstallLifecycle.SelfTest.ps1`

Expected: nonzero exit naming `InstallLifecycle.psm1`.

- [ ] **Step 3: Define the exact runtime copy allowlist**

Copy only these source groups into a new sibling staging directory under the install root: `src/runtime/**`, `src/check-package.mjs`, `src/persistence/Supervisor.ps1`, `src/persistence/SessionController.ps1`, all `src/persistence/modules/*.psm1`, and the public Test/Start/Reset scripts needed by runtime/manual diagnostics. Copy bootstrap and uninstaller separately to stable root names. Reject any source/destination reparse point.

- [ ] **Step 4: Implement first install and atomic activation**

Run hermetic validation with `-SkipInstalledPackageCheck`, discover all currently existing Node candidates from the interactive installer environment, validate each as Node 22+, stage files, generate/verify manifest, move staging to `runtime\<runtime-id>`, initialize all state files, atomically set active, install the task, and start it unless `DoNotStart`.

- [ ] **Step 5: Implement upgrade without disturbing a validated special session**

Stage/verify the new runtime, atomically switch active/previous, signal the old supervisor’s ACL-protected shutdown event, wait for its exact PID/creation time, then start the scheduled task. Bootstrap performs ready rollback. The new supervisor reconciles and adopts a still-valid special Codex instead of restarting it. Retain active and one previous runtime; delete only older contained non-reparse runtime directories.

- [ ] **Step 6: Implement explicit state repair**

`-RepairState` quarantines damaged files, initializes schema 1 with `automationEnabled=false` and `candidateCompatibleOptIn=false`, preserves Node candidates only after revalidation, and does not start a transition. The user must resume and opt in explicitly afterward.

- [ ] **Step 7: Implement safe uninstall ordering**

Acquire transition lock and pause automation. If a validated special session exists, default to controller Recover/Normalize, require both ports closed, and adopt/start one ordinary instance. `KeepCurrentSpecialSession` requires interactive confirmation or explicit noninteractive switch and logs the unmonitored-CDP warning. Then remove task, signal supervisor exit, terminate only its verified PID on timeout, preserve device keys by default, and delete only canonical contained non-reparse install paths.

- [ ] **Step 8: Implement key backup/removal semantics**

Reject simultaneous backup and removal. Backup moves the exact resolved store to `remote-control-device-keys.windows.json.backup.<UTC timestamp>` only after successful session normalization. Removal requires explicit `RemoveDeviceKeyStore` plus confirmation and prints that server authorization remains until revoked in Codex.

- [ ] **Step 9: Update package metadata**

Set `package.json` version to `2.0.0`, change the description to the persistent current-user supervisor, and use safe-default scripts:

```json
{
  "scripts": {
    "preflight": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-CodexControlOtherDevices.ps1",
    "test": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Validate.ps1 -SkipInstalledPackageCheck",
    "test:installed": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Validate.ps1",
    "test:package": "node tests/PackageCheckerSelfTest.mjs",
    "test:persistence": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/PersistenceSelfTest.ps1",
    "test:runtime": "node tests/CleanroomSelfTest.js"
  }
}
```

- [ ] **Step 10: Run lifecycle tests and dry runs**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexControlOtherDevices.ps1 -EnableCandidateCompatibleUpdates -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-CodexControlOtherDevices.ps1 -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
```

Expected: all exit 0; `WhatIf` creates no task, process, or install directory.

- [ ] **Step 11: Commit**

```powershell
git add package.json src/persistence/modules/InstallLifecycle.psm1 Install-CodexControlOtherDevices.ps1 Uninstall-CodexControlOtherDevices.ps1 tests/persistence/InstallLifecycle.SelfTest.ps1
git commit -m "feat: add persistent install lifecycle"
```

### Task 13: Documentation, Full Validation, and Explicit Real-Machine Acceptance

**Files:**

- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `docs/TECHNICAL.md`
- Modify: `docs/CLEANROOM.md`
- Modify: `SECURITY.md`
- Modify: `tests/Validate.ps1`

**Interfaces:**

- Documents: install, tray states, pause/retry, compatible-update behavior, fallback, repair, uninstall, security boundary, manual mode, and real acceptance limits.
- Validation: hermetic checks remain default-safe; installed-package preflight remains read-only; process-changing acceptance is explicit.

- [ ] **Step 1: Update Chinese and English quick-start documentation**

Document these exact commands:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexControlOtherDevices.ps1 -EnableCandidateCompatibleUpdates
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexControlOtherDevices.ps1 -RepairState
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-CodexControlOtherDevices.ps1
```

Explain that a compatible first-seen package gets one controlled trial, unknown/native-module builds stay ordinary, normal launch may close/reopen once, and actual Store-update/logon observation is not simulated proof.

- [ ] **Step 2: Update technical and clean-room documentation**

Add the source/installed layouts, schema versions, controller envelope, key lifetimes, journal stages, replay table, manifest/active switching, ready fallback, WMI capability chain, three-second authority, task settings, exact probes, and unchanged device-key bridge boundary.

- [ ] **Step 3: Update the security document**

State that renderer CDP remains available to same-user processes for the special session, task/supervisor are unelevated, current-user files are part of the trust root, hashes detect corruption rather than authenticate the user, state damage disables automation, and default uninstall normalizes the session before removing the tray.

- [ ] **Step 4: Extend repository validation requirements**

Require all new public scripts/modules/tests/docs, parse every `.ps1` and `.psm1`, syntax-check all `.js/.mjs`, run package/persistence/clean-room tests, and keep real package preflight behind `SkipInstalledPackageCheck`.

- [ ] **Step 5: Run the full hermetic suite**

Run:

```powershell
node.exe .\tests\PackageCheckerSelfTest.mjs
node.exe .\tests\CleanroomSelfTest.js
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate.ps1 -SkipInstalledPackageCheck
npm test
```

Expected: every command exits 0, no task is installed, no tray remains, and no real Codex process is changed.

- [ ] **Step 6: Run the read-only live preflight**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CodexControlOtherDevices.ps1 -Json`

Expected: exactly one schema-1 JSON object. Record classification, package full name/version, AppX family, `app.asar` hash, and verified Node path without printing credentials or device keys.

- [ ] **Step 7: Commit documentation and validation**

```powershell
git add README.md README.en.md docs/TECHNICAL.md docs/CLEANROOM.md SECURITY.md tests/Validate.ps1
git commit -m "docs: document persistent tray supervisor"
```

- [ ] **Step 8: Install the reviewed build for the current user**

After all commits pass review, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexControlOtherDevices.ps1 -EnableCandidateCompatibleUpdates -Confirm:$false
```

Expected: versioned runtime exists under `%LOCALAPPDATA%\CodexControlOtherDevices`, the task is registered as limited current-user interactive, and one tray icon appears.

- [ ] **Step 9: Verify the registered task and supervisor without changing Codex**

Inspect task XML/snapshot and assert absolute bootstrap path, `InteractiveToken`, Limited, IgnoreNew, three one-minute retries, PT0S, battery flags disabled, one supervisor/bootstrap chain, correct SID/Session, and no non-loopback listener.

- [ ] **Step 10: Perform the authorized ordinary-launch takeover acceptance**

Launch Codex through its normal Start-menu/AUMID path. Confirm at most one automatic close/reopen, exact special-process identity, main Inspector refusal, renderer probe proof, green tray state, and the “Control other devices” label. Reload/navigate the Codex renderer and confirm renderer-only repair restores the proof without reopening the main Inspector. Quit Codex and confirm it remains closed; launch normally again and confirm the bridge reapplies once.

- [ ] **Step 11: Verify pause, resume, retry, and failure isolation**

Pause from the tray, quit, launch normally, and confirm no takeover. Resume and use Apply now against the ordinary instance. Use fixture/injected failure tests—not the live package—to confirm unknown classification, native-module classification, damaged state, and bridge failure keep or recover one ordinary instance without loops.

- [ ] **Step 12: Verify uninstall in a full cycle, then reinstall final state**

Run normal uninstall, confirm a special session becomes ordinary, both debug ports close, task/tray/bootstrap/runtime/logs are removed, and the DPAPI key store remains. Re-run the install command from Step 8 and recheck task/tray so delivery ends installed and active.

- [ ] **Step 13: Record deferred real-cycle evidence honestly**

Record Windows logon and an actual future Microsoft Store Codex update as pending observation unless they occur during execution. Do not label simulated restart/update fixtures as a completed real logon or Store update.

## Spec Coverage Self-Review Map

| Design requirement | Implementation tasks |
|---|---|
| Stable versioned install, manifest, active/previous, ready rollback | 2, 3, 11, 12 |
| Limited current-user scheduled task | 11, 12 |
| Tray icon, states, commands, WMI fallback, reconciliation | 9, 10 |
| Dynamic AppX/Node/package classification | 1, 4 |
| Exact process identity and one-time takeover | 6, 8, 9 |
| Current/new renderer coverage without reopening main Inspector | 8, 9, 10, 13 |
| Durable journal, crash replay, recovery and suppression | 5, 7, 8 |
| Unknown/native fail-closed and candidate opt-in | 4, 5, 9 |
| Pause/resume/retry and damaged-state defaults | 5, 9, 10, 12 |
| Safe upgrade, repair and uninstall/key preservation | 11, 12 |
| Existing clean-room/DPAPI/security invariants | 1, 8, 13 |
| Hermetic tests and explicit real-machine acceptance | all tasks; final gates in 13 |

## Final Verification Commands

```powershell
git status --short
git diff --check origin/main...HEAD
node.exe .\tests\PackageCheckerSelfTest.mjs
node.exe .\tests\CleanroomSelfTest.js
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PersistenceSelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate.ps1 -SkipInstalledPackageCheck
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CodexControlOtherDevices.ps1 -Json
```

Expected repository result: clean worktree; all hermetic tests pass; live preflight is valid JSON; system-mutating acceptance evidence is recorded separately; final machine state has one limited current-user task, one tray supervisor, no non-loopback debug listener, and the persistent runtime installed under `%LOCALAPPDATA%\CodexControlOtherDevices`.
