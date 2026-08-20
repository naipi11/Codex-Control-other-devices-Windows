# Native Tray Host Design

**Status:** Proposed for user review  
**Target release:** CodexRemote-fix 2.4.1  
**Scope:** Replace the PowerShell/WinForms tray UI with a compiled, source-auditable tray host without changing Codex repair, enrollment, device keys, scheduled-task ownership, or installer identity. Runtime requirement is Windows 10 1809 or later with .NET Framework 4.8 Full already installed.

## 1. Problem statement

The current installed 2.4.0 experiment displays a Win32 menu from a second temporary owner window. That window is shown, forced to the foreground, used by `TrackPopupMenuEx`, then hidden. On the target Windows 11 machine this produces two coupled failures:

- the first menu sometimes opens, while later menus can appear and immediately close;
- foreground activation changes the visible Microsoft Pinyin conversion state from Chinese to English and back.

The rejected `NotifyIcon.ContextMenu` experiment is not an acceptable fallback. The .NET Framework `NotifyIcon` implementation still calls `SetForegroundWindow`, and its actual notification-icon path does not call `ContextMenu.OnCollapse`. A design that depends on `Collapse` therefore leaves the supervisor permanently in its menu-open branch after the first right-click.

No rejected tray experiment has been pushed, tagged, or installed after independent review. The currently installed runtime remains the earlier 2.4.0 experiment; device-key SHA-256 and the active Codex process were not changed.

## 2. Goals

The replacement MUST:

1. Use the Windows system menu visual style and native menu behavior.
2. Open exactly one menu for every accepted right-click or keyboard context-menu request.
3. Keep hover, submenu navigation, Escape, selection, and outside-click dismissal responsive.
4. Preserve the user's input layout and Chinese/English IME conversion state without writing to another application's input context.
5. Keep all menu tracking, icon callbacks, and menu resource ownership out of PowerShell.
6. Preserve the current bilingual UI, status colors, toggles, language submenu, logs command, uninstall confirmation, and command authorization semantics.
7. Remain current-user only, offline, non-elevated, and fail closed.
8. Preserve device pairing, DPAPI-protected keys, Codex processes, runtime rollback, desktop shortcut, Start-menu discovery, and the single scheduled task.
9. Ship source and build provenance for every generated executable.

## 3. Non-goals

The tray host MUST NOT:

- repair or relaunch Codex;
- read, copy, delete, or transmit device keys;
- open Chromium debugging ports;
- execute PowerShell, shell commands, arbitrary paths, URLs, or arguments received over IPC;
- introduce WinForms, WPF, Windows App SDK, third-party UI libraries, a second scheduled task, a Run-key entry, or a network listener;
- modify another process's HKL, HIMC, TSF profile, composition text, or conversion mode;
- use `AttachThreadInput`, `SendInput`, simulated keyboard shortcuts, `KLF_SETFORPROCESS`, or TSF profile activation.

## 4. Chosen architecture

CodexRemote-fix will add one internal executable:

```text
Scheduled task
  -> bootstrap.ps1
    -> Supervisor.ps1
      -> CodexRemote.TrayHost.exe

Supervisor <== two anonymous redirected pipes ==> TrayHost
```

`CodexRemote.TrayHost.exe` is the only owner of the notification icon, its persistent HWND, the `HMENU`, and the native message loop. The PowerShell supervisor remains the only owner of repair decisions, state persistence, process observation, compatibility probing, and command authorization.

The executable is a .NET Framework 4.8 Windows GUI assembly written in C# 5 and using direct Win32 P/Invoke. Setup requires .NET Framework 4.8 Full (`Release >= 528040`) and aborts with a stable bilingual requirement message when it is absent. The host does not reference WinForms or WPF.

The same assembly exposes a small public `TrayHostParentClient` class. The supervisor loads that manifest-bound assembly and uses the class to start the child process, own asynchronous pipe I/O, own the Job Object, and expose non-blocking snapshot/command methods to PowerShell. Loading the assembly does not invoke its `Main` entry point.

## 5. Source layout and responsibilities

```text
src/trayhost/
  Program.cs                    child-mode entry point only
  TrayHostApplication.cs        STA message loop and shutdown
  TrayWindow.cs                 HWND, Shell_NotifyIcon, TaskbarCreated
  NativeMenu.cs                 HMENU creation, tracking, destruction
  InputModeGuard.cs             private Host HKL/HIMC synchronization
  PresentationSnapshot.cs       strict UI snapshot and localization fields
  PipeProtocol.cs               framing, handshake, HMAC, sequence checks
  TrayHostParentClient.cs       parent process, pipes, Job, async queues
  NativeMethods.cs              bounded P/Invoke declarations
  AssemblyInfo.cs               product and file metadata
  CodexRemote.TrayHost.manifest asInvoker and PerMonitorV2 declaration
  CodexRemote.TrayHost.exe.config .NET Framework runtime binding

src/persistence/modules/
  TrayHostClient.psm1           strict PowerShell wrapper and receipts
  ProcessWatcher.psm1           watcher-only code extracted from TrayUi
  TrayUi.psm1                   removed after supervisor migration

build/
  build-trayhost.ps1            clean compile, tests, provenance

tests/trayhost/
  TrayHostSelfTest.cs           deterministic native-boundary tests

tests/persistence/
  TrayHostBuild.SelfTest.ps1
  TrayHostClient.SelfTest.ps1
```

Each C# unit has one responsibility. The native host never imports repository PowerShell modules. `TrayHostClient.psm1` never creates a window or menu.

## 6. Process and readiness lifecycle

1. Bootstrap validates the active runtime manifest before starting Supervisor, as it does today.
2. Supervisor resolves `RuntimeRoot\bin\CodexRemote.TrayHost.exe`, rejects reparse paths, validates the exact manifest record, and loads the assembly from that immutable versioned runtime.
3. `TrayHostParentClient` creates redirected standard input, standard output, and standard error with `UseShellExecute=false`, `CreateNoWindow=true`, and no secret in the command line. Non-secret argv contains the expected parent PID, parent creation time, and runtime ID.
4. The client starts child mode and immediately assigns the returned process handle to an unnamed Job Object configured with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. ParentClient strongly references the Job handle and Host `Process` for its entire lifetime so garbage collection cannot close either early. If Job assignment fails, the client terminates that exact returned process, waits, closes every redirected stream and handle, and only then permits runtime rollback.
5. TrayHost creates no icon before the parent/host handshake and first complete presentation snapshot succeed.
6. Supervisor validates Host PID, creation time, assembly version, protocol version, runtime ID, and capability set against the process it started.
7. Host creates its HWND and icon, applies the first snapshot, and returns `UiReady` only after `NIM_ADD` and `NIM_SETVERSION` succeed.
8. Supervisor creates the process watcher and signals the bootstrap Ready event only after `UiReady`.

If any step before Ready fails, Supervisor exits without signaling Ready. Bootstrap then tries `previousRuntime` using the existing rollback contract.

After Ready, a broken pipe or Host exit removes the icon in Host cleanup and disables UI commands. Supervisor retries the exact manifest-bound Host at 1 second, 10 seconds, and 60 seconds. After three consecutive failures it records `CCOD_TRAY_HOST_UNAVAILABLE` and exits with code `3` without stopping or modifying Codex. The scheduled-task specification changes `RestartCount` from `3` to `1` and may restart that failed Supervisor once after 60 seconds; a second failed cycle leaves the task Ready so the existing desktop shortcut can trigger a deliberate retry without launching Host directly.

The Job Object and pipe-disconnect handling are both mandatory. A dead Supervisor cannot leave an orphan tray icon.

## 7. Anonymous-pipe protocol

The fixed one-parent/one-child topology uses the anonymous pipes supplied by redirected stdin/stdout. There is no discoverable pipe name, socket, port, IPC file, registry queue, or shared clipboard state.

### 7.1 Framing

Every frame uses a 60-byte little-endian header:

```text
magic[4] | protocolMajor[2] | messageType[2] | payloadLength[4]
epoch[8] | sequence[8] | hmacSha256[32] | typedPayload[payloadLength]
```

- Magic is the ASCII literal `CRTH`.
- Protocol major starts at `1`.
- All integers are unsigned little-endian values.
- Payload length is at most 16 KiB.
- Each message type has one fixed binary payload schema. Strings are unsigned-16-bit-length-prefixed strict UTF-8; invalid UTF-8, control characters, missing fields, trailing bytes, wrong enums, and out-of-range values are rejected.
- Host epoch is a cryptographically random nonzero 64-bit value for each Host process.
- Authenticated sequence starts at `1` independently in each direction and must increase by exactly one.

Bootstrap uses the same header with `epoch=0`, `sequence=0`, and a 32-byte all-zero HMAC field. Exactly one `ParentHello` may travel parent-to-host and exactly one `HostHello` may travel host-to-parent. No other unauthenticated type is legal.

`ParentHello` contains the non-secret parent identity copied from argv, expected runtime ID, 32-byte random session seed, and 32-byte parent challenge. Host verifies the argv parent PID, creation time, and executable identity with OS process APIs, then requires `ParentHello` to match. `HostHello` contains the challenge echo, 32-byte Host nonce, nonzero Host epoch, Host PID/creation time, assembly version, and fixed capability bits. Parent validates Host identity only against the actual `Process` handle it started; self-reported Host identity is never sufficient.

Directional keys are defined byte-for-byte:

```text
IKM  = sessionSeed[32]
salt = SHA256(ASCII("CodexRemote.TrayHost/v1") || parentChallenge[32]
              || hostNonce[32] || LE64(hostEpoch))
PRK  = HMAC-SHA256(key=salt, data=IKM)
P2H  = HKDF-Expand(PRK, ASCII("CodexRemote.TrayHost/v1/parent-to-host"), 32)
H2P  = HKDF-Expand(PRK, ASCII("CodexRemote.TrayHost/v1/host-to-parent"), 32)
```

HKDF-Expand follows RFC 5869. HMAC input is the exact 60-byte header with the tag field zeroed, followed by the raw payload. Authenticated traffic uses `hostEpoch` and starts at sequence `1`.

HMAC, epoch, and sequence checks defend against accidental stream corruption, stale replay, and protocol confusion. They do not claim to isolate data from malicious code already executing as the same Windows user.

### 7.2 Parent-to-Host messages

- `Presentation`: complete snapshot with monotonic revision.
- `ActionAck`: accepted/rejected result for one action ID.
- `TransientError`: one allow-listed dialog/error enum.
- `Ping`.
- `Shutdown`: reason enum and final revision.

Only the newest complete `Presentation` is retained. A dedicated Host reader thread validates and coalesces snapshots, then posts a private `WM_APP` message; it never waits for the UI thread while holding a pipe or queue lock. The UI thread applies a snapshot only when no menu or uninstall confirmation is active. Host sends `PresentationAck(revision)` only after that immutable snapshot is actually applied. A menu reads the last acknowledged snapshot; it never waits for a pipe, disk, PowerShell, or a worker process.

Presentation text comes from the existing manifest-bound bilingual UI resources and is sent only by the authenticated parent. Host validates every displayed string as non-empty where required, at most 300 UTF-16 code units, and free of control characters. The snapshot carries only presentation fields; it contains no Codex path, account name, machine name, device identifier, port, token, or device key.

### 7.3 Host-to-parent messages

- `HostHello` / `UiReady`.
- `PresentationAck`: the exact revision now applied to the UI cache.
- `Action`: random 128-bit action ID, expected presentation revision, command enum, and one strictly typed optional value.
- `Pong`.
- `ShutdownAck`.
- `Fault`: one allow-listed code with no exception text.

Command enum is limited to:

```text
ApplyNow
ManualRetry
SetAutomation(bool)
SetCandidateOptIn(bool)
SetLanguageMode(System | zh-CN | en-US)
OpenLogs
RequestUninstall
```

Host has an eight-item outbound action queue and a 64-entry per-epoch action-ID replay cache. A separate reserved control queue carries `HostHello`, `UiReady`, `PresentationAck`, `Pong`, `ShutdownAck`, and `Fault`; user actions cannot exhaust or starve it. A dedicated writer thread drains control messages before actions and never runs menu code. Supervisor accepts an action only when its revision and enabled state match the last acknowledged snapshot. Rejected or duplicate actions have no side effect.

Ping interval is 5 seconds. A side waits at most 2 seconds for its matching Pong and Host exits after 10 seconds without authenticated parent traffic.

The binary protocol uses `StandardInput.BaseStream` and `StandardOutput.BaseStream` only. Host never calls `Console.Write*`. Parent drains redirected stderr independently, retains at most 4 KiB of allow-listed diagnostic codes, and continues draining after the cap so a full error pipe cannot deadlock the child.

## 8. Supervisor integration

Supervisor stops using a WinForms `ApplicationContext` and timer. Its main thread runs an explicit 250 ms loop:

1. poll the non-blocking `TrayHostParentClient` queues;
2. normalize at most one authenticated Host action into the existing bounded command queue;
3. run `Invoke-CcodSupervisorTick` using the existing worker-slot and 1-second observation throttle;
4. wait on shutdown/process/transport handles for the remainder of the 250 ms interval.

`SetTrayPresentation` becomes a non-blocking latest-value update to `TrayHostParentClient`. It never writes synchronously to a full pipe. C# background I/O tasks serialize frames and maintain at most one pending presentation plus the bounded control queue.

Host has dedicated reader and writer threads. The reader only validates frames, coalesces state, and posts `WM_APP`; it never waits for the UI thread while holding a transport lock. Only the STA UI thread calls `EndMenu`. A parent `Shutdown` frame has priority over presentations. During its two-second shutdown deadline, ParentClient continues draining Host output so `ShutdownAck` cannot be blocked behind a full stdout pipe.

Shutdown order is:

```text
latch Supervisor shutdown
-> stop accepting Host actions
-> send authenticated Shutdown
-> wait up to 2 seconds for ShutdownAck and Host exit
-> close the Job handle to terminate a stuck Host
-> close pipes
-> continue existing watcher, worker, event, and lease cleanup
```

Language changes remain transactional: preference write first, new catalog resolution second, new presentation acknowledgement third. If acknowledgement fails, Supervisor rolls back the preference and last acknowledged presentation exactly as it does today.

Uninstall confirmation stays inside the acknowledged native menu snapshot: `Uninstall supervisor…` opens a submenu containing a disabled warning and a `Confirm uninstall` leaf. Host sends `RequestUninstall` only for that leaf. Supervisor remains the only component allowed to start the uninstaller.

## 9. Native notification icon and menu

TrayHost creates one persistent invisible top-level `WS_POPUP | WS_EX_TOOLWINDOW` HWND. That same HWND owns `Shell_NotifyIconW`, receives notification callbacks, and owns every context menu. It is never shown or hidden per menu.

Startup declares Per-Monitor-V2 DPI awareness before creating the window. Host registers a stable application GUID, calls `NIM_ADD`, then `NIM_SETVERSION` with `NOTIFYICON_VERSION_4`. On every registered `TaskbarCreated` message it performs that same `NIM_ADD -> NIM_SETVERSION` pair exactly once.

The version-4 callback opens the menu only for `WM_CONTEXTMENU`; the keyboard Context Menu key reaches that same path. `NIN_SELECT`, `NIN_KEYSELECT`, and left-click perform no application action. Menu position uses callback coordinates when valid; keyboard activation uses `Shell_NotifyIconGetRect`; `GetCursorPos` is only a final fallback. `TPMPARAMS.rcExclude` contains the icon rectangle when available.

For every accepted invocation:

```text
reject reentry
-> copy the last acknowledged snapshot
-> establish the private input-mode guard
-> CreatePopupMenu / append validated items
-> SetForegroundWindow(the persistent owner HWND)
-> verify foreground ownership
-> TrackPopupMenuEx(TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY)
-> PostMessageW(owner, WM_NULL)
-> Shell_NotifyIconW(NIM_SETFOCUS)
-> DestroyMenu exactly once
-> clear reentry state
-> enqueue an allow-listed action when command != 0
```

Alignment uses `SM_MENUDROPALIGNMENT`; RTL adds `TPM_LAYOUTRTL`. The menu graph includes disabled title/status rows, conditional session/apply/retry rows, separators, checked automation and compatibility rows, a three-item radio language submenu, logs, and uninstall. It uses system metrics, fonts, colors, hover, keyboard navigation, accessibility, and DPI behavior; Host performs no owner drawing.

All success, cancel, foreground-failure, protocol-failure, and shutdown paths destroy the `HMENU` exactly once. Shutdown calls `EndMenu` only on the Host UI thread and only while its own `menuOpen` flag is true. Uninstall confirmation never opens a dialog: the native menu contains `Uninstall supervisor…` as a submenu with a disabled warning row and a separate `Confirm uninstall` leaf. Only that leaf emits `RequestUninstall`, so no second HWND or input context is created.

## 10. Input-mode feasibility gate and production guard

Windows IMM does not permit TrayHost to read another application's HWND/HIMC state reliably across process and thread boundaries. Production therefore MUST NOT call `ImmGetContext`, `ImmGetOpenStatus`, `ImmGetConversionStatus`, or `ImmGetCompositionString` on an external window. The project makes no claim that external composition text or conversion flags are programmatically observable.

### 10.1 Mandatory pre-production spike

Before the production Host or IPC integration is implemented, a non-shipping C# spike MUST run on the target Windows 11 machine. It uses one persistent hidden `WS_POPUP | WS_EX_TOOLWINDOW` owner, one Shell notification icon, `NOTIFYICON_VERSION_4`, and the final native menu sequence. The owner disassociates its own default HIMC by calling `ImmAssociateContext(owner, NULL)` and saves the returned Host-owned default handle for reassociation during cleanup. It never inspects or changes an external HIMC.

The spike passes only when all of these are true:

1. the persistent hidden owner becomes foreground successfully from the notification callback;
2. 50 consecutive hidden-icons right-clicks produce 50 stable menus;
3. hover, submenu, Escape, selection, and outside-click dismissal work;
4. Microsoft Pinyin remains visibly Chinese for 50 Chinese-mode trials and visibly English for 50 English-mode trials, with no disappearance or intermediate state;
5. the previously focused application's text input still behaves in the same mode after every trial;
6. with a live uncommitted Microsoft Pinyin composition, right-click, Escape, outside-click dismissal, and one harmless menu selection do not commit, cancel, alter, or expose the composition;
7. the owner has no associated HIMC for the entire tracking interval;
8. `PostMessage(WM_NULL)` and `NIM_SETFOCUS` complete on every cancel and selection path.

Failure of any criterion stops the native-host implementation and returns the project to design review. It is not permissible to add delays, simulate input, access an external HIMC, or publish the remaining Host around a failed input-mode spike.

### 10.2 Production guard after a successful spike

Production uses exactly the no-HIMC strategy proven by the spike. An out-of-context `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` records candidate foreground identity, but the hook callback only posts a private UI message. The Host STA thread validates and stores HWND, PID, process creation time, thread ID, window class, source HKL from `GetKeyboardLayout`, and timestamp. It records no title or user input.

Shell UI is filtered by specific classes such as `Shell_TrayWnd`, `NotifyIconOverflowWindow`, and `Progman`, not by excluding the entire `explorer.exe` process. A normal File Explorer window remains a valid source. If the current foreground is shell UI and no valid cached application exists, Host may use only that shell thread's read-only HKL as a restricted fallback; failure to obtain a valid HKL rejects the menu before foreground activation.

Host may call `ActivateKeyboardLayout(sourceHkl, 0)` only on its own STA thread and only if the successful spike required that step. It never uses `KLF_SETFORPROCESS`. It never associates, reads, writes, releases, or destroys an external HIMC. Every Host-owned context association is reversed before HWND destruction; Host does not destroy the saved default context.

TSF APIs are permitted only for read-only spike diagnostics. Production does not activate a profile or write a global, process, thread-manager, or document compartment.

If source identity, HKL validation, no-HIMC verification, or foreground ownership fails, Host does not display the menu and reports one bounded `CCOD_TRAY_INPUT_MODE_UNAVAILABLE` fault. The icon remains available for a later retry.

## 11. Build and provenance

`build/build-trayhost.ps1` uses the 64-bit .NET Framework compiler at `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`, with the 32-bit compiler only as a build-machine fallback. Compilation uses `/nostdlib+` and references only `Microsoft.NETFramework.ReferenceAssemblies.net48` version `1.0.3`, restored from NuGet under a committed package lock. Restore verifies the locked package integrity; missing or mismatched reference assemblies fail the build and never fall back to the build machine's in-place runtime assemblies.

The compiler targets the Windows GUI subsystem, `asInvoker`, AnyCPU, C# 5, warnings as errors, checked arithmetic, optimization, UTF-8 compiler output, the product icon, and the committed application manifest.

The build uses only the pinned .NET Framework 4.8 reference API surface. It runs in a fresh temporary directory and atomically replaces `build/generated/trayhost` only after compile and self-test success. A static assembly-reference/API allow-list test rejects accidental calls above that target.

The executable is generated, never committed. The repository and installer include all C# source. Build also emits `trayhost-build-provenance.json` containing only:

- schema and product version;
- target framework;
- compiler file version and SHA-256;
- normalized compiler arguments;
- relative source paths and SHA-256 values;
- output length and SHA-256;
- Git commit and dirty boolean when Git is available.

It contains no username, absolute path, environment dump, machine identifier, or timestamp-dependent source value. The legacy compiler does not support deterministic output, so the project claims source-auditable builds, not cross-machine byte-for-byte reproducibility.

The generated EXE, config, provenance, tray-host source, and manifest enter the exact runtime file set and `manifest.json`. Any byte change causes runtime validation to fail. Bootstrap treats the EXE and config as required runtime files. `build/generated/` is entirely gitignored.

`Get-CcodLifecycleSourceFiles` explicitly includes `bin\CodexRemote.TrayHost.exe`, its config and provenance, every allow-listed `src\trayhost` source/manifest/config file, `TrayHostClient.psm1`, and `ProcessWatcher.psm1`; it rejects unknown files, reparse points, and alternate data streams in those sets. Watcher functions and their existing tests move unchanged out of `TrayUi.psm1` before that module is deleted. The four status icons are generated and cached by Host from the existing bridge-icon algorithm at startup, then destroyed exactly once; no untracked image is loaded at menu time.

One production EXE is compiled per release. Native self-tests and SHA-256 verification run against that exact output. `build.ps1 -UseExistingTrayHost` validates provenance, source hashes, reference-pack identity, and output hash before passing the same bytes to Inno; it never recompiles. A local one-command build may invoke `build-trayhost.ps1` once only when no validated artifact exists.

## 12. Installer, upgrade, rollback, and release

Inno keeps the existing AppId, install directory, desktop shortcut, Start-menu group, uninstaller, current-user privilege, and scheduled task. Shortcuts continue to launch stable `bootstrap.ps1`; none points directly to TrayHost.

Inno also requires .NET Framework 4.8 Full and supports an internal `/DONOTSTART=1` CI switch that skips only the post-install task launch. The public default always starts the supervisor. README and release notes state that Windows 10 1809 does not provide 4.8 by default and that offline installation stops bilingually when 4.8 is absent. Generated EXE, config, and provenance are explicitly packaged; recursive `src` packaging alone is not considered sufficient.

Upgrade sequence remains serialized by the existing account-transition lease. The old Supervisor is signaled, its Host acknowledges shutdown or is killed by its Job, and only then may active runtime switch. Device-key files are not opened by this sequence.

The release version is 2.4.1. This avoids ambiguity with the unpushed but locally installed 2.4.0 experiment. The rejected local `NotifyIcon.ContextMenu` commit is superseded; its UI code is not included in the generated runtime.

Candidate workflow order is:

1. checkout, Node 22 setup, and locked net48 reference-pack restore;
2. install Inno Setup;
3. compile TrayHost once and run native self-tests against that exact EXE;
4. run `npm test`;
5. run `build.ps1 -UseExistingTrayHost` and build the installer without recompilation;
6. silently install with `/DONOTSTART=1` on the hosted runner;
7. run `Validate.ps1 -SkipInstalledPackageCheck`, headless TrayHost/IPC smoke tests, and verify EXE/config/provenance hashes against the installed runtime manifest without requiring Codex MSIX, Explorer, or an interactive notification area;
8. silently uninstall and verify no Host, Supervisor, task, or installer-owned shortcut remains;
9. upload installer, checksum, and provenance JSON as one immutable candidate artifact.

The target machine downloads and installs that exact Actions artifact and records its run ID, source commit, and hashes. Only after the full notification-area/Microsoft Pinyin/Codex/device-key acceptance gate and explicit user confirmation does a separate promotion workflow accept `tag` plus `candidate_run_id`, download the same artifact, verify that provenance commit equals the tag target, verify every hash, and create the Release. Promotion contains no compiler, package build, or Inno step. The acceptance report is committed after Release promotion so it cannot change the tagged candidate commit.

Hosted-runner validation is described only as structural and headless integration. Real notification-area, Microsoft Pinyin, Codex Remote, and device-key validation remains the current-machine gate.

## 13. Security and privacy invariants

- Host receives no device key, account token, CDP port, source path, or arbitrary command text.
- Parent validates the child process object, PID, creation time, exact executable path, runtime ID, and manifest hash.
- Host validates non-secret parent PID, creation time, image path, and runtime ID from argv with OS APIs, then requires `ParentHello` to match them over the inherited capability channel.
- Every post-handshake message is length-bounded, sequence-checked, schema-exact, and HMAC-authenticated.
- Protocol failure deletes the icon, closes both pipes, and exits Host.
- Host command failure never changes checked state optimistically; only an acknowledged new snapshot changes UI truth.
- Host logs only allow-listed codes, revisions, timings, and booleans. No HWND title, composition text, exception text, IPC payload, or user-entered text is logged.
- Same-user arbitrary code execution is outside the IPC isolation claim and is documented honestly.

## 14. Automated verification

### Native tests

- strict fixed-binary snapshot, action, bootstrap-handshake, frame, UTF-8 string, length, HMAC, epoch, and sequence validation;
- truncated, oversized, trailing-byte, invalid-enum, malformed-string, wrong-version, wrong-direction, replay, and forged frames fail closed;
- exact menu order, enabled/visible/checked/radio semantics, bilingual strings, and command mapping;
- injected Win32 boundary verifies `SetForegroundWindow -> TrackPopupMenuEx -> PostMessage(WM_NULL) -> NIM_SETFOCUS` order;
- success, cancel, error, reentry, shutdown, and `TaskbarCreated` resource ownership;
- `DestroyMenu`, `DestroyIcon`, hooks, pipes, process, and Job handles close exactly once; the saved Host default HIMC is reassociated and never destroyed by the project;
- no external HIMC API is called; source HKL is read only and only the Host UI-thread HKL may receive a setter when the successful spike proves it necessary;
- parent death, Host crash, heartbeat timeout, pipe corruption, and three-retry exhaustion;
- assembly references and imports exclude PowerShell, WinForms, WPF, Windows App SDK, networking, `AttachThreadInput`, and `SendInput`.

### PowerShell and lifecycle tests

- parent client loads only a contained manifest-bound EXE;
- initial Host failure prevents Supervisor Ready and triggers previous-runtime fallback;
- post-Ready Host failure retries three times, then exits Supervisor with the stable unavailable code without changing Codex;
- snapshot coalescing and action normalization are bounded and non-blocking;
- language persistence rollback includes Host acknowledgement failure;
- shutdown ordering removes Host before runtime switch;
- runtime file-set, reparse, alternate-stream, installer, shortcut, and uninstall checks include TrayHost;
- device-key SHA-256 remains identical across install, upgrade, Host crash, rollback, and uninstall-with-backup.

## 15. Current-machine acceptance gate

No release may be published until the target Windows 11 machine passes all of the following with Microsoft Pinyin in both Chinese and English modes:

1. Hidden-icons panel open: 50 consecutive right-clicks, 50 menus open, zero flashes, zero duplicate menus.
2. Hidden-icons panel closed/direct icon: 50 additional right-clicks with the same result.
3. Every menu supports immediate hover, language submenu navigation, Escape, selection, and outside-click dismissal.
4. The taskbar input indicator never changes between Chinese and English during any open, close, cancel, or command.
5. Source-window HKL is unchanged before and after every trial, and typing in the same source field immediately afterward confirms that Chinese/English behavior is unchanged. No user manually switches input mode during a measured trial.
6. Testing with an in-progress Microsoft Pinyin composition confirms that opening, Escape, outside-click dismissal, and one harmless menu selection do not commit, cancel, alter, or expose that composition; this is a black-box acceptance check, not a cross-process IMM claim.
7. First menu appears within 100 ms on the target machine; subsequent menus are not perceptibly slower than the Windows Bluetooth tray menu.
8. Explorer restart restores one icon; Host crash and Supervisor crash leave no ghost or duplicate icon.
9. Upgrade, rollback, reboot, desktop shortcut, Start-menu search, bilingual language switching, uninstall, remote connection, and device-key hash all pass.

Failure of any input-mode or repeated-menu criterion blocks release. The implementation returns to design review rather than adding another focus, delay, or popup patch.

## 16. Rejected alternatives

- **PowerShell WPF popup:** custom sizing, activation, and deactivation repeatedly produced stuck windows and latency.
- **WinForms ContextMenuStrip:** managed popup ordering competed with the Windows 11 hidden-icons flyout.
- **Manual HMENU with a second temporary owner:** caused the reported repeated-open and input-mode failures.
- **Legacy NotifyIcon.ContextMenu:** still foregrounds a hidden framework window and does not provide the required Collapse lifecycle in the actual notification-icon path.
- **Named pipe:** unnecessary discoverable endpoint for a fixed parent-child relationship.
- **File/registry queue:** latency, residue, TOCTOU, and replay surface.
- **AttachThreadInput or simulated input:** changes keyboard/focus state and violates the safety boundary.
- **Windows App SDK/third-party tray framework:** adds deployment dependencies while still wrapping the same notification-area APIs.

## 17. Primary references

- Microsoft: [TrackPopupMenu notification-icon foreground and WM_NULL requirements](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-trackpopupmenu)
- Microsoft: [Shell_NotifyIcon, NOTIFYICON_VERSION_4, and NIM_SETFOCUS](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw)
- Microsoft: [Notification area callback behavior](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area)
- Microsoft: [AnonymousPipeServerStream](https://learn.microsoft.com/en-us/dotnet/api/system.io.pipes.anonymouspipeserverstream)
- Microsoft: [Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
- Microsoft: [IMM cross-thread access constraints](https://learn.microsoft.com/en-us/windows/win32/intl/developing-ime-aware-multiple-thread-applications)
- Microsoft: [ImmAssociateContext](https://learn.microsoft.com/en-us/windows/win32/api/imm/nf-imm-immassociatecontext)
- Microsoft: [.NET Framework versions and dependencies](https://learn.microsoft.com/en-us/dotnet/framework/install/versions-and-dependencies)
- Microsoft NuGet: [Microsoft.NETFramework.ReferenceAssemblies.net48 1.0.3](https://www.nuget.org/packages/Microsoft.NETFramework.ReferenceAssemblies.net48/1.0.3)
