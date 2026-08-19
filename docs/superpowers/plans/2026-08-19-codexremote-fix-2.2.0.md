# CodexRemote-fix 2.2.0 Implementation Plan

> For agentic workers: use subagent-driven development or executing-plans task by task. Checklist items track progress.

**Goal:** Ship an in-place safe Codex-update recovery, a modern bilingual tray popup, and discoverable CodexRemote-fix installer.

**Architecture:** The package checker owns evidence classification; persistence accepts only internally consistent tuples. The supervisor owns recovery cadence/state reconciliation. The WPF popup is a presentation and command-queue adapter only. Installer identity changes publicly without changing legacy AppId/runtime/task/key paths.

**Tech stack:** Node.js 22, Windows PowerShell 5.1, WinForms NotifyIcon, WPF PresentationFramework, Inno Setup 6, repository self-tests.

**Spec:** docs/superpowers/specs/2026-08-19-codexremote-fix-2.2.0-design.md

## Global constraints

- Do not modify Codex binaries or WindowsApps.
- Do not delete/re-pair device keys, remote authorization, MFA, SSO, or passkeys.
- Keep legacy CodexControlOtherDevices runtime/task/key identifiers in 2.2.0.
- Only full sentinels plus optional native artifact is a compatible candidate.
- Public name is CodexRemote-fix; target version is 2.2.0.
- No elevated service, listener, telemetry, or external dependency.

---

### Task 1: Complete package-update classification contract

**Files:** src/check-package.mjs; src/persistence/modules/CompatibilityProbe.psm1; src/persistence/StaticProbeWorker.ps1; focused package/compatibility/worker self-tests.

**Interfaces:** CandidateCompatible requires all four sentinels and affected=true; native hint is permitted. NativeModulePresent requires native=true, affected=false, and incomplete sentinels; all other tuples are fail-closed.

- [x] Add red tests for native-plus-complete and native-plus-incomplete evidence.
- [x] Observe old failures and implement minimal checker/probe changes.
- [x] Run focused package, compatibility, and worker tests.

### Task 2: Bounded stale-package recovery diagnostics

**Files:** src/persistence/modules/SessionEngine.psm1; src/persistence/Supervisor.ps1; SessionEngine and SupervisorEngine self-tests.

**Interfaces:** Consume live package identity and persisted verified identity. Produce allowlisted reason and one bounded reconcile decision; never clear state/key data.

- [x] Add a failing stale-status versus live-package test asserting allowlisted reason and no state/key clear.
- [x] Observe the generic blocked result.
- [x] Implement the smallest branch using existing validation/transition primitives.
- [x] Run focused session/supervisor tests and prove no unbounded repeat path.

### Task 3: Responsive WPF tray connection card

**Files:** src/persistence/modules/TrayUi.psm1; src/persistence/Supervisor.ps1; TrayUi and Supervisor self-tests; manual gallery if needed.

**Interfaces:** Consume validated presentation/catalog/language data and existing queue. Produce a borderless WPF popup whose callbacks only enqueue validated commands, plus IsPopupOpen/fingerprint state for render coalescing.

- [x] Keep WPF-host/performance tests red; add only missing popup-close/flush and fingerprint checks.
- [x] Replace ContextMenuStrip with WPF card and tray mouse routing.
- [x] Add one-second observation throttle, fingerprint skip, popup coalescing, close flush.
- [x] Run tray/supervisor tests and manually verify English, Chinese, Follow Windows, normal/high DPI.

### Task 4: CodexRemote-fix installer, shortcuts, icon, documentation

**Files:** package.json; build/CodexControlOtherDevices.iss; build/build.ps1; assets/codexremote-fix; InstallLifecycle self-test; README files; technical documentation.

**Interfaces:** Keep AppId {2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F} and legacy bootstrap. Produce CodexRemote-fix-2.2.0-setup.exe plus custom-icon Start and desktop shortcut to stable bootstrap.

- [x] Add/retain installer contract tests for AppId/icon/public names/bootstrap targets.
- [x] Complete public naming/icon/shortcut/version changes without changing legacy internals.
- [x] Rewrite installer-first bilingual docs; no PowerShell quick start.
- [ ] Run installer tests and compile/inspect binary/hash.

### Task 5: Whole-system verification and authorized local upgrade

**Files:** build/dist/CodexRemote-fix-2.2.0-setup.exe.

- [x] Run tests/Validate.ps1 with installed-package check skipped.
- [ ] Build and verify SHA-256 sidecar against binary.
- [ ] Inspect old uninstall registration and current runtime/key locations.
- [ ] Under the user's authorization, uninstall obsolete script registration, install verified 2.2.0, and verify task, tray, shortcuts, package state, pairing.
- [ ] Commit/review source and ask before remote push/release publication.
