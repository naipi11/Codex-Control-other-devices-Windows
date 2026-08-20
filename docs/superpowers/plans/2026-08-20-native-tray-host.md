# Native Tray Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unreliable PowerShell/WinForms tray UI with a source-auditable native tray-host child process that provides a stable Windows system menu without changing Microsoft Pinyin mode, Codex remote state, or device keys.

**Architecture:** A manifest-bound `.NET Framework 4.8` Windows GUI assembly owns one persistent HWND, `Shell_NotifyIcon`, native `HMENU`, and input-context boundary. Supervisor owns all business decisions and communicates with its one child through redirected anonymous stdin/stdout pipes authenticated after a capability-channel handshake. The first task is a target-machine no-HIMC feasibility gate; failure stops the plan before production integration.

**Tech Stack:** Windows PowerShell 5.1, C# 5, .NET Framework 4.8 reference assemblies, Win32 User32/Shell32/Imm32, anonymous redirected pipes, HMAC-SHA-256/HKDF, Job Objects, Inno Setup 6, Node.js 22, GitHub Actions Windows runner.

**Spec:** `docs/superpowers/specs/2026-08-20-native-tray-host-design.md`

## Global Constraints

- No task after Task 1 may start until the target-machine no-HIMC spike passes and the user explicitly confirms the result.
- Production never reads or writes another process's HIMC or TSF compartment.
- No PowerShell, WinForms, WPF, Windows App SDK, `AttachThreadInput`, `SendInput`, network listener, named pipe, file queue, registry queue, or arbitrary command execution is allowed in TrayHost.
- TrayHost receives no device key, account token, port, Codex path, source path, or arbitrary command text.
- Generated EXE bytes are never committed; public C# source, build lock, and provenance are committed.
- Runtime and installer remain current-user, non-elevated, offline, and preserve the existing AppId, scheduled-task ownership, shortcuts, active/previous rollback, Codex process, and DPAPI device-key store.
- Use `apply_patch` for repository edits; preserve unrelated user changes; do not rewrite public history.
- Every production change follows RED -> GREEN -> focused regression -> independent review -> commit.
- Target release is `2.4.1`; no tag or Release is created before Task 11 acceptance passes.

---

### Task 1: Prove the no-HIMC menu boundary on the target machine

**Files:**
- Create: `tools/spikes/NativeTrayInputMode/NoHimcSpike.cs`
- Create: `tools/spikes/NativeTrayInputMode/NoHimcSpikeSelfTest.cs`
- Create: `tools/spikes/NativeTrayInputMode/Run-NoHimcSpike.ps1`
- Create after manual execution: `docs/superpowers/validation/2026-08-20-native-tray-input-mode-spike.md`

**Interfaces:**
- Consumes: existing product ICO at `assets/codexremote-fix/codexremote-fix.ico`.
- Produces: a non-shipping spike result; it produces no runtime or installer file.

```csharp
internal interface ISpikeNative
{
    IntPtr CreatePersistentOwner();
    IntPtr ImmAssociateContext(IntPtr hwnd, IntPtr himc);
    IntPtr ImmGetContext(IntPtr hwnd);
    bool ImmReleaseContext(IntPtr hwnd, IntPtr himc);
    bool SetForegroundWindow(IntPtr hwnd);
    IntPtr GetForegroundWindow();
    IntPtr CreatePopupMenu();
    bool AppendMenu(IntPtr menu, uint flags, UIntPtr commandId, string text);
    bool AppendSubMenu(IntPtr menu, IntPtr childMenu, string text);
    uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);
    bool PostMessage(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
    bool ShellNotifyIcon(uint message, ref NotifyIconData data);
    bool DestroyMenu(IntPtr menu);
    bool DestroyWindow(IntPtr hwnd);
}

internal sealed class NoHimcSpikeController : IDisposable
{
    public NoHimcSpikeController(ISpikeNative native);
    public void Initialize();
    public uint ShowMenu(Point point);
    public SpikeSnapshot GetSnapshot();
    public void Dispose();
}
```

- [ ] **Step 1: Write the failing call-order and ownership test**

In `NoHimcSpikeSelfTest.cs`, add literal trace assertions for:

```text
Initialize: CreateOwner -> ImmAssociateContext(owner,NULL) -> ImmGetContext(owner)==NULL -> NIM_ADD -> NIM_SETVERSION
Menu:       SetForeground -> GetForeground -> TrackPopup -> WM_NULL -> NIM_SETFOCUS -> DestroyMenu
Dispose:    ImmAssociateContext(owner,savedDefault) -> NIM_DELETE -> DestroyWindow
```

Also assert foreground failure never reaches `TrackPopupMenuEx`, reentry never creates a second menu, left-click/NIN_SELECT/NIN_KEYSELECT emit no action, and cleanup never calls `ImmDestroyContext(savedDefault)`. A nonzero result from diagnostic `ImmGetContext(owner)` is always paired with `ImmReleaseContext` before the failure is returned.
Assert the fake records one disabled title, one child `HMENU` attached under Language, Chinese/English no-op children, and one harmless no-op command before tracking.

- [ ] **Step 2: Run the self-test and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\spikes\NativeTrayInputMode\Run-NoHimcSpike.ps1 -SelfTest
```

Expected: compile failure naming missing `NoHimcSpikeController` members, not a compiler-discovery failure.

- [ ] **Step 3: Implement the minimum non-shipping spike**

Implement one persistent invisible `WS_POPUP | WS_EX_TOOLWINDOW` HWND, disassociate its default HIMC, register one version-4 notification icon, and open only on `WM_CONTEXTMENU`. Build a fixed native test menu containing a disabled title, `Language -> Chinese / English` no-op submenu, and a harmless no-op selection. Then use:

```csharp
if (!_native.SetForegroundWindow(_owner) || _native.GetForegroundWindow() != _owner)
    return 0;

uint command = _native.TrackPopupMenuEx(
    menu,
    TpmReturnCmd | TpmRightButton | TpmNoNotify,
    point.X,
    point.Y,
    _owner,
    IntPtr.Zero);

_native.PostMessage(_owner, WmNull, UIntPtr.Zero, IntPtr.Zero);
_native.ShellNotifyIcon(NimSetFocus, ref _iconData);
```

Put `DestroyMenu` in a `finally`. Reassociate the saved default HIMC before destroying the owner; never destroy that default HIMC.

- [ ] **Step 4: Run the automated spike test and verify GREEN**

Run the Step 2 command. Expected: all fake boundary tests pass and the script leaves no process, icon, or generated repository file.

- [ ] **Step 5: Run the target-machine physical gate**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\spikes\NativeTrayInputMode\Run-NoHimcSpike.ps1 -Trials 50
```

Record only aggregate counts and booleans. The user performs:

- 50 hidden-icons right-clicks while Microsoft Pinyin visibly shows Chinese;
- 50 more while it visibly shows English;
- hover, submenu, Escape, outside-click dismissal, and harmless selection;
- the same actions while an uncommitted Pinyin composition exists.

Pass requires 100 stable menus, no indicator change/disappearance, and no composition commit/cancel/change. Any failure stops this plan and returns to architecture review.

- [ ] **Step 6: Write the bounded validation report**

Record OS build, .NET release number, trial counts, pass/fail booleans, and that no titles, HWNDs, composition text, device data, or account data were recorded. If the owner receives `WM_ENTERMENULOOP`, measure callback-to-enter latency with QPC and report min/median/max; never use total `TrackPopupMenuEx` duration because it includes user dwell time. If that message is unavailable, report only the manual immediate-appearance result.

- [ ] **Step 7: Commit the spike gate**

```bash
git add tools/spikes/NativeTrayInputMode docs/superpowers/validation/2026-08-20-native-tray-input-mode-spike.md
git commit -m "test: add no-HIMC tray spike gate"
```

Pause for explicit user confirmation before Task 2.

---

### Task 2: Lock the net48 compiler surface and implement the binary protocol

**Files:**
- Create: `build/trayhost-packages.lock.json`
- Create: `build/TrayHostReferencePack.psm1`
- Create: `src/trayhost/PipeProtocol.cs`
- Create: `src/trayhost/PresentationSnapshot.cs`
- Create: `tests/trayhost/TrayHostProtocolSelfTest.cs`
- Create: `tests/trayhost/Invoke-TrayHostSelfTest.ps1`
- Create: `tests/persistence/TrayHostBuild.SelfTest.ps1`

**Interfaces:**
- Consumes: the approved Task 1 result.
- Produces:

```csharp
internal static class ProtocolCodec
{
    internal static void WriteBootstrap(Stream output, ProtocolFrame frame);
    internal static ProtocolFrame ReadBootstrap(Stream input, Direction expectedDirection);
    internal static SessionKeys DeriveDirectionalKeys(ParentHello parent, HostHello host);
    internal static void WriteAuthenticated(Stream output, ProtocolFrame frame, byte[] key);
    internal static ProtocolFrame ReadAuthenticated(Stream input, Direction direction, ulong epoch, ulong sequence, byte[] key);
}

public sealed class PresentationSnapshot
{
    public PresentationSnapshot(
        ulong revision,
        TrayColor color,
        TrayState state,
        LanguageMode language,
        PresentationFlags flags,
        string[] strings);
    public ulong Revision { get; private set; }
    public TrayColor Color { get; private set; }
    public TrayState State { get; private set; }
    public LanguageMode Language { get; private set; }
    public PresentationFlags Flags { get; private set; }
    public IReadOnlyList<string> Strings { get; private set; }
}

public enum TrayColor : byte { Gray = 0, Green = 1, Yellow = 2, Red = 3 }
public enum LanguageMode : byte { System = 0, Chinese = 1, English = 2 }
public enum TrayState : byte { Waiting, Inspecting, Transitioning, Active, ActivePaused, RendererHandoff, Suppressed, Recovered, Error }
public enum TrayCommand : ushort
{
    None = 0,
    ApplyNow = 1001,
    ManualRetry = 1002,
    SetAutomation = 1003,
    SetCandidateOptIn = 1004,
    SetLanguageSystem = 1005,
    SetLanguageChinese = 1006,
    SetLanguageEnglish = 1007,
    OpenLogs = 1008,
    ConfirmUninstall = 1009
}
[Flags]
public enum PresentationFlags : uint
{
    SessionReadyVisible = 1u << 0,
    ApplyNowVisible = 1u << 1,
    ApplyNowEnabled = 1u << 2,
    ManualRetryVisible = 1u << 3,
    ManualRetryEnabled = 1u << 4,
    AutomationToggleEnabled = 1u << 5,
    AutomationChecked = 1u << 6,
    CandidateOptInToggleEnabled = 1u << 7,
    CandidateOptInChecked = 1u << 8,
    OpenLogsEnabled = 1u << 9,
    UninstallEnabled = 1u << 10,
    Busy = 1u << 11
}
```

The presentation carries exactly 18 strings in fixed order: title, status, session-ready, apply, retry, automation, compatibility, language, follow-system, Chinese, English, logs, uninstall parent, uninstall warning, confirm-uninstall, tooltip, language-change error, and uninstall-start error.

- [ ] **Step 1: Write the failing reference-pack lock test**

The exact lock content is:

```json
{
  "schemaVersion": 1,
  "packages": [
    {
      "id": "Microsoft.NETFramework.ReferenceAssemblies.net48",
      "version": "1.0.3",
      "sha512": "XWKgyeNadNcTQaIVvQB8BrdCNrEar6fo/de1OdQRZ9HFy0jcBSaM8IV5q64ZampsSnC8AlTsACaGZUuoFw41RA=="
    }
  ]
}
```

Test that a wrong package hash yields `CCOD_TRAYHOST_REFERENCE_HASH_MISMATCH`, missing reference DLLs fail, runtime assemblies under `%WINDIR%\Microsoft.NET` are never used as references, and the cache path is outside the runtime/installer payload.

- [ ] **Step 2: Verify the build-lock test is RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayHostBuild.SelfTest.ps1
```

Expected: missing lock/resolver failure.

- [ ] **Step 3: Implement the locked reference-pack resolver**

Export only:

```powershell
Resolve-CcodTrayHostReferencePack -LockPath <absolute> -CacheRoot <absolute> [-Adapters <hashtable>]
```

Download only the locked NuGet package, validate the Base64 SHA-512 catalog hash, extract to a fresh temporary directory, validate the expected net48 reference set, and atomically publish the cache. Reject reparse points and alternate streams.

- [ ] **Step 4: Write fixed-vector protocol tests and verify RED**

Cover the 60-byte little-endian header; bootstrap seq/epoch/tag zeros; RFC 5869 extract/expand; fixed seed/challenge/nonce/epoch directional key hex; HMAC over zero-tag header plus raw payload; sequence/direction/epoch; malformed UTF-8; truncated/oversized/trailing payload; invalid enums; presentation string limits; and every command enum.

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProtocolOnly
```

Expected: missing protocol types/methods.

- [ ] **Step 5: Implement the minimum protocol and presentation model**

Use strict `BinaryReader`/`BinaryWriter` helpers that validate lengths before allocation. Configure UTF-8 with replacement disabled. Implement HKDF-SHA-256 locally with `HMACSHA256`; net48 has no HKDF API. Do not add JSON or serializer dependencies.

- [ ] **Step 6: Verify protocol and build-lock GREEN**

Run Steps 2 and 4. Expected: all tests pass with no warnings or generated tracked files.

- [ ] **Step 7: Commit the build lock and protocol**

```bash
git add build/trayhost-packages.lock.json build/TrayHostReferencePack.psm1 src/trayhost/PipeProtocol.cs src/trayhost/PresentationSnapshot.cs tests/trayhost tests/persistence/TrayHostBuild.SelfTest.ps1
git commit -m "feat: add authenticated tray host protocol"
```

---

### Task 3: Implement the Win32 tray-host core

**Files:**
- Create: `src/trayhost/NativeMethods.cs`
- Create: `src/trayhost/InputModeGuard.cs`
- Create: `src/trayhost/NativeMenu.cs`
- Create: `src/trayhost/TrayWindow.cs`
- Create: `src/trayhost/TrayHostApplication.cs`
- Create: `src/trayhost/AssemblyInfo.cs`
- Create: `src/trayhost/CodexRemote.TrayHost.manifest`
- Create: `src/trayhost/CodexRemote.TrayHost.exe.config`
- Extend: `tests/trayhost/TrayHostProtocolSelfTest.cs`
- Create: `tests/trayhost/TrayHostNativeSelfTest.cs`

**Interfaces:**

```csharp
internal sealed class InputModeGuard : IDisposable
{
    internal void DetachOwnerInputContext(IntPtr owner);
    internal bool VerifyNoOwnerInputContext(IntPtr owner);
    internal void RestoreOwnerDefaultContext(IntPtr owner);
}

internal sealed class TrayWindow : IDisposable
{
    internal event Action<TrayCommand, ulong> CommandSelected;
    internal void Create(PresentationSnapshot initial);
    internal void Apply(PresentationSnapshot snapshot);
    internal void ReAddAfterTaskbarCreated();
    internal void RequestShutdown();
}

internal interface ITrayHostChannel
{
    bool TryGetLatestPresentation(out PresentationSnapshot snapshot);
    bool TryEnqueueAction(TrayCommand command, ulong revision);
    bool IsShutdownRequested { get; }
}
```

This release never calls `ActivateKeyboardLayout`; Task 1 proves the no-HIMC strategy without that setter. Enabling Host-thread layout synchronization later requires a new explicit spike and user acceptance. No external HWND is passed to an IMM API.

- [ ] **Step 1: Write failing snapshot and menu-shape tests**

Assert literal top-level order, disabled title/status, optional rows, checked toggles, three radio languages, logs, and `Uninstall supervisor… -> disabled warning -> Confirm uninstall`. Assert invalid status, language, color, flags, control characters, or extra strings fail.

- [ ] **Step 2: Verify native-core RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -NativeOnly
```

Expected: missing native types.

- [ ] **Step 3: Implement menu construction with an injected platform**

Create an internal `ITrayPlatform` implemented by `Win32TrayPlatform`. `NativeMenu.Show` receives one immutable snapshot and enforces:

```text
no-HIMC verify -> CreatePopupMenu -> SetForeground -> foreground proof
-> TrackPopup(TPM_RETURNCMD|TPM_RIGHTBUTTON|TPM_NONOTIFY)
-> WM_NULL -> NIM_SETFOCUS -> DestroyMenu once
```

- [ ] **Step 4: Add failing lifecycle tests**

Cover left/NIN inert behavior, WM_CONTEXTMENU only, reentry, cancel, selection, foreground failure, `TaskbarCreated` exact `NIM_ADD -> NIM_SETVERSION`, Explorer restart, `EndMenu` only during tracking, `WM_QUERYENDSESSION`/`WM_ENDSESSION`, keyboard positioning via `Shell_NotifyIconGetRect` with cursor fallback, PerMonitorV2 setup before the first HWND, and cleanup of menu/icons/hook/HWND/default-HIMC association. Assert allow-listed transient errors use `NIM_MODIFY | NIF_INFO` with the acknowledged title/error string and create no dialog HWND. Add literal hook tests: the WinEvent callback only posts a candidate; STA validation binds HWND+PID+process creation time+thread ID+window class+HKL; shell UI classes are rejected while normal File Explorer is accepted; no external HWND is passed to IMM.

- [ ] **Step 5: Implement the persistent window and message loop**

Use one invisible top-level owner, PerMonitorV2 awareness, version-4 callbacks, `Shell_NotifyIconGetRect` keyboard positioning, icon exclusion rectangle, system alignment, RTL, GDI-cached status icons, and no owner drawing. Install the out-of-context foreground hook; post candidate HWNDs to the Host UI thread and perform all identity/HKL validation there.

- [ ] **Step 6: Add forbidden-import and stream tests**

Reject production references/imports for PowerShell, WinForms, WPF, Windows App SDK, networking, `AttachThreadInput`, `SendInput`, external IMM calls, or `Console.Write*`.

- [ ] **Step 7: Verify native-core GREEN**

Run `-NativeOnly`, then the full `Invoke-TrayHostSelfTest.ps1`. Run `git diff --check`.

- [ ] **Step 8: Commit the native host core**

```bash
git add src/trayhost tests/trayhost
git commit -m "feat: add native no-HIMC tray host core"
```

---

### Task 4: Implement ParentTransport, Job ownership, and the child handshake

**Files:**
- Create: `src/trayhost/ParentTransport.cs`
- Create: `src/trayhost/HostTransport.cs`
- Create: `src/trayhost/JobObject.cs`
- Create: `src/trayhost/TrayHostParentClient.cs`
- Create: `src/trayhost/Program.cs`
- Extend: `src/trayhost/TrayHostApplication.cs`
- Extend: `tests/trayhost/Invoke-TrayHostSelfTest.ps1`
- Create: `tests/trayhost/TrayHostTransportSelfTest.cs`
- Create: `tests/trayhost/TrayHostHostTransportSelfTest.cs`
- Create: `tests/trayhost/TrayHostParentClientSelfTest.cs`

**Interfaces:**

```csharp
public sealed class TrayHostParentClient : IDisposable
{
    public static TrayHostParentClient Start(TrayHostStartOptions options);
    public TrayHostStartReceipt Receipt { get; }
    public bool TryPublish(PresentationSnapshot snapshot);
    public bool TryDequeueEvent(out TrayHostEvent value);
    public bool BeginShutdown(ShutdownReason reason, ulong finalRevision);
    public bool WaitForStopped(TimeSpan timeout);
    public bool WaitForActivity(TimeSpan timeout);
    public TrayHostHealth GetHealth();
}

public sealed class TrayHostStartOptions
{
    public string ExePath { get; set; }
    public string RuntimeId { get; set; }
    public int ParentPid { get; set; }
    public long ParentCreationFileTimeUtc { get; set; }
    public PresentationSnapshot InitialPresentation { get; set; }
}

public sealed class TrayHostStartReceipt
{
    public int HostPid { get; internal set; }
    public long HostCreationFileTimeUtc { get; internal set; }
    public string RuntimeId { get; internal set; }
    public ushort ProtocolMajor { get; internal set; }
    public ulong Capabilities { get; internal set; }
}

public enum TrayHostHealth : byte { Starting, Ready, Stopping, Stopped, Faulted }
public enum ShutdownReason : byte { SupervisorExit, Upgrade, Uninstall, ParentFault }
public enum TrayHostEventKind : byte { PresentationAck, Action, Fault, Exited }

public sealed class TrayHostEvent
{
    public TrayHostEventKind Kind { get; internal set; }
    public Guid ActionId { get; internal set; }
    public TrayCommand Command { get; internal set; }
    public ulong Revision { get; internal set; }
    public bool? BoolValue { get; internal set; }
    public LanguageMode? LanguageValue { get; internal set; }
    public string ErrorCode { get; internal set; }
}
```

`TrayHostStartOptions` contains canonical manifest-verified EXE path, runtime ID, parent PID, parent creation time, and the complete initial presentation. Seed/challenges never appear in argv or receipts. `Start` performs: child start -> Job assignment -> ParentHello/HostHello -> send initial presentation -> receive matching PresentationAck -> receive UiReady. It returns only after that bounded sequence succeeds.

`Program.Main` accepts exactly two modes:

```text
--child --parent-pid <int> --parent-created <filetime> --runtime-id <safe-id>
--headless-smoke
```

Unknown/missing arguments exit `2`. `--headless-smoke` creates no HWND, icon, menu, or external endpoint; it runs an in-process loopback through the real codec/ParentTransport/HostTransport for handshake, HMAC, initial PresentationAck, one synthetic allow-listed Action, and ShutdownAck, then exits `0` with no console output. It cannot execute a business action.

- [ ] **Step 1: Write failing pure transport tests**

Cover parent latest-presentation coalescing, broken-pipe health, continuous stderr drain with 4 KiB retained cap, and no lock held while posting/waiting. In HostTransport tests cover reserved control priority, eight-action bound, 64-ID replay cache, and UI bridging: while a menu is open, a new presentation remains pending and unacknowledged; after menu close the UI applies exactly the newest snapshot and emits one `PresentationAck` for that revision.

- [ ] **Step 2: Verify transport RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -TransportOnly
```

- [ ] **Step 3: Implement reader/writer transport threads**

Parent and Host readers validate then queue/post; writers drain control before actions; none runs UI. Use raw `BaseStream`, not text readers/writers. HostTransport is the only owner of Host inbound latest-presentation state, outbound control/action queues, and the apply/ack bridge.

- [ ] **Step 4: Write failing real-child/Job tests**

The test assembly supplies a non-shipping peer through an internal injected child-process factory/argument seam; production `Start` always uses fixed `--child` arguments and exposes no test-mode option. Assert handshake, wrong argv parent identity, forged self-reported PID, Job assignment failure exact kill/wait/dispose, parent disposal, queued-presentation shutdown priority, Ack within two seconds, initial-presentation Ack before UiReady, and no UI before `UiReady`.

- [ ] **Step 5: Implement ParentClient and SafeJobHandle**

Keep strong `_job`, `_process`, and `_transport` references. On any pre-Job failure, kill the exact returned process handle, wait, close streams, and dispose before throwing. `Dispose` is idempotent and follows the spec shutdown order.

- [ ] **Step 6: Verify ParentClient GREEN**

Run `-TransportOnly`, `-ParentClientOnly`, and then the full native suite.

- [ ] **Step 7: Commit transport and lifecycle**

```bash
git add src/trayhost tests/trayhost
git commit -m "feat: add tray host parent transport"
```

---

### Task 5: Produce and verify one source-auditable TrayHost artifact

**Files:**
- Create: `build/TrayHostBuild.psm1`
- Create: `build/build-trayhost.ps1`
- Modify: `build/build.ps1`
- Modify: `.gitignore`
- Extend: `tests/persistence/TrayHostBuild.SelfTest.ps1`

**Interfaces:**

```powershell
Invoke-CcodTrayHostBuild -RepositoryRoot <absolute> -Version <semver> -OutputDirectory <absolute> [-Adapters <hashtable>]
Test-CcodTrayHostArtifact -RepositoryRoot <absolute> -Version <semver> -ArtifactDirectory <absolute>
```

Output is exactly `CodexRemote.TrayHost.exe`, its config, and `trayhost-build-provenance.json`.

- [ ] **Step 1: Extend failing build tests**

Assert `/nostdlib+`, only locked net48 references, Windows GUI subsystem, asInvoker/PerMonitorV2 manifests, warnings-as-errors, output tamper failure, source tamper failure, compiler/reference/source/output hashes in provenance, no absolute/private fields, and whole `build/generated/` ignored.

- [ ] **Step 2: Verify build RED**

Run `TrayHostBuild.SelfTest.ps1`; expected missing build functions.

- [ ] **Step 3: Implement clean compile, exact-byte self-test, and atomic publish**

Compile in a new temporary directory, run the production EXE's headless self-test and external self-test suite against those exact bytes, create provenance, then atomically replace the artifact directory.

- [ ] **Step 4: Add `build.ps1` reuse contract**

Add:

```powershell
[switch]$UseExistingTrayHost
[string]$TrayHostArtifactDirectory
```

Without an artifact, call `build-trayhost.ps1` exactly once. With `-UseExistingTrayHost`, verify provenance/source/output hashes and never invoke the compiler.

- [ ] **Step 5: Verify build GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayHostBuild.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\build-trayhost.ps1 -Version 2.4.1 -OutputDirectory build\generated\trayhost
```

- [ ] **Step 6: Commit build provenance**

```bash
git add build .gitignore tests/persistence/TrayHostBuild.SelfTest.ps1
git commit -m "build: add locked net48 tray host build"
```

---

### Task 6: Extract the process watcher from TrayUi

**Files:**
- Create: `src/persistence/modules/ProcessWatcher.psm1`
- Create: `tests/persistence/ProcessWatcher.SelfTest.ps1`
- Modify: `src/persistence/modules/TrayUi.psm1`
- Modify: `tests/persistence/TrayUi.SelfTest.ps1`
- Modify: `src/persistence/Supervisor.ps1`

**Interfaces:**

```powershell
Start-CcodProcessWatcher -Queue <queue> -OnFullReconciliationRequired <scriptblock> [-Adapters <hashtable>]
Stop-CcodProcessWatcher -Watcher <strict handle>
```

Error IDs, bounded hint behavior, fallbacks, cleanup receipt, and adapter contracts remain byte-for-byte equivalent.

- [ ] **Step 1: Move watcher tests first and verify RED**

Copy watcher-only behavioral tests into the new test file and import the missing module. Run it; expected missing-module failure.

- [ ] **Step 2: Move watcher production code without semantic edits**

Move watcher adapters, validation, start/stop, and cleanup. Export only the two functions. Remove watcher exports from TrayUi. Import ProcessWatcher explicitly in Supervisor.

- [ ] **Step 3: Verify GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProcessWatcher.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayUi.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Supervisor.SelfTest.ps1
```

- [ ] **Step 4: Commit the extraction**

```bash
git add src/persistence/modules/ProcessWatcher.psm1 src/persistence/modules/TrayUi.psm1 src/persistence/Supervisor.ps1 tests/persistence
git commit -m "refactor: separate process watcher from tray UI"
```

---

### Task 7: Add the strict PowerShell TrayHost client wrapper

**Files:**
- Create: `src/persistence/modules/TrayHostClient.psm1`
- Create: `tests/persistence/TrayHostClient.SelfTest.ps1`

**Interfaces:**

```powershell
Start-CcodTrayHostClient -RuntimeRoot <absolute> -RuntimeId <safe id> -InitialPresentation <strict object> [-Adapters <hashtable>]
Set-CcodTrayHostPresentation -Client <strict context> -Presentation <strict object>
Receive-CcodTrayHostEvent -Client <strict context>
Wait-CcodTrayHostActivity -Client <strict context> -TimeoutMilliseconds <0..250>
Stop-CcodTrayHostClient -Client <strict context> -TimeoutMilliseconds 2000
```

- [ ] **Step 1: Write failing wrapper validation tests**

Cover contained manifest-bound EXE, reparse/ADS/hash mismatch, wrong assembly/type, malformed start receipt, no path/seed/exception leakage, non-blocking latest publish, exact event schema, and idempotent close. Old-revision and duplicate-action authorization belongs to Supervisor tests, not this schema wrapper.

- [ ] **Step 2: Verify wrapper RED**

Run the new self-test; expected missing module/functions.

- [ ] **Step 3: Implement the wrapper with injected adapters**

Load the exact assembly only after manifest validation. Convert presentation/action values through literal enum maps. Return only strict PSCustomObject receipts and stable `CCOD_TRAYHOST_*` errors.

- [ ] **Step 4: Verify wrapper GREEN**

Run the new self-test, RuntimeManifest self-test, and the native ParentClient suite.

- [ ] **Step 5: Commit the wrapper**

```bash
git add src/persistence/modules/TrayHostClient.psm1 tests/persistence/TrayHostClient.SelfTest.ps1
git commit -m "feat: add manifest-bound tray host client"
```

---

### Task 8: Replace the WinForms UI loop in Supervisor

**Files:**
- Modify: `src/persistence/Supervisor.ps1`
- Modify: `tests/persistence/Supervisor.SelfTest.ps1`
- Delete: `src/persistence/modules/TrayUi.psm1`
- Delete: `tests/persistence/TrayUi.SelfTest.ps1`
- Delete: `tests/manual/Show-TrayUiGallery.ps1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1` fixture module set

**Interfaces:**

Remove adapters:

```text
NewTray, StopTrayTimer, RequestUiExit, CloseTray, RunUiContext
```

Add adapters:

```text
StartTrayHost, PublishTrayPresentation, TryReadTrayHostEvent,
WaitLoopActivity, StopTrayHost
```

- [ ] **Step 1: Write failing Supervisor contract tests**

Assert Host/handshake failure prevents Ready; `UiReady` precedes watcher creation and Ready; one 250 ms loop accepts at most one action; publishes latest snapshot without blocking; rejects stale/duplicate actions; retries at 1/10/60 seconds; third failure exits code 3 without changing Codex; shutdown ordering matches the spec; and language preference commits only after `PresentationAck` with rollback on failure.

- [ ] **Step 2: Verify Supervisor RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Supervisor.SelfTest.ps1
```

- [ ] **Step 3: Implement the explicit loop**

Replace `Application.Run` and WinForms timer with:

```powershell
while (-not $hostState.ShutdownRequested) {
    Receive-CcodSupervisorTrayHostEvents -HostState $hostState -Adapters $adapter
    Invoke-CcodSupervisorTick -HostState $hostState -Adapters $adapter
    Invoke-CcodSupervisorAdapter $adapter.WaitLoopActivity @($hostState.TrayHost, 250) 0
}
```

The actual loop accounts for elapsed work so total cadence remains 250 ms. It continues draining during the two-second Host shutdown wait.

- [ ] **Step 4: Remove legacy UI only after focused GREEN**

Delete TrayUi and gallery files, remove WinForms imports/adapters, and update module fixtures. Keep ProcessWatcher imported.

- [ ] **Step 5: Verify GREEN and regression**

Run Supervisor, TrayHostClient, ProcessWatcher, RuntimeManifest, and `npm run test:persistence`.

- [ ] **Step 6: Request independent review and commit**

Review readiness ordering, command authorization, language transaction, shutdown, retries, and absence of Codex/key mutation.

```bash
git add src/persistence tests
git commit -m "feat: integrate native tray host with supervisor"
```

---

### Task 9: Bind TrayHost into runtime, bootstrap, task, and Inno

**Files:**
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify: `src/persistence/modules/RuntimeManifest.psm1`
- Modify: `src/persistence/bootstrap.ps1`
- Modify: `src/persistence/modules/ScheduledTask.psm1`
- Modify: `build/CodexControlOtherDevices.iss`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `tests/persistence/RuntimeManifest.SelfTest.ps1`
- Modify: `tests/persistence/Bootstrap.SelfTest.ps1`
- Modify: `tests/persistence/ScheduledTask.SelfTest.ps1`

**Required runtime files:**

```text
bin/CodexRemote.TrayHost.exe
bin/CodexRemote.TrayHost.exe.config
bin/trayhost-build-provenance.json
src/trayhost/PipeProtocol.cs
src/trayhost/PresentationSnapshot.cs
src/trayhost/NativeMethods.cs
src/trayhost/InputModeGuard.cs
src/trayhost/NativeMenu.cs
src/trayhost/TrayWindow.cs
src/trayhost/TrayHostApplication.cs
src/trayhost/ParentTransport.cs
src/trayhost/HostTransport.cs
src/trayhost/JobObject.cs
src/trayhost/TrayHostParentClient.cs
src/trayhost/Program.cs
src/trayhost/AssemblyInfo.cs
src/trayhost/CodexRemote.TrayHost.manifest
src/trayhost/CodexRemote.TrayHost.exe.config
src/persistence/modules/TrayHostClient.psm1
src/persistence/modules/ProcessWatcher.psm1
```

- [ ] **Step 1: Write failing runtime/install tests**

Assert exact source inclusion; unknown file/reparse/ADS rejection; binary/config/provenance tamper rejection; bootstrap fallback when EXE/config missing; Inno maps `build/generated/trayhost` explicitly to `{app}\bin`; `.NET Full Release >= 528040`; `/DONOTSTART=1` maps only to `-DoNotStart`; shortcuts still target bootstrap; task RestartCount=1 and PT1M. Lifecycle source-collector tests use a synthetic installer package root containing `bin`; repository root is not treated as a finished package, and direct installation from an unbuilt checkout is no longer supported.

- [ ] **Step 2: Verify four focused RED suites**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ScheduledTask.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

- [ ] **Step 3: Implement lifecycle and installer changes**

Add exact allow-listed source trees and binary records; make Host/config required bootstrap files; stop Host before runtime switch; change task restart contract; package generated artifacts explicitly; add bilingual net48 failure text and CI switch.

- [ ] **Step 4: Verify focused GREEN**

Run the four suites plus `npm test`.

- [ ] **Step 5: Commit runtime packaging**

```bash
git add src/persistence build/CodexControlOtherDevices.iss tests/persistence
git commit -m "build: package native tray host runtime"
```

---

### Task 10: Prepare 2.4.1 docs, candidate build, and artifact promotion workflows

**Files:**
- Modify: `package.json`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/TECHNICAL.md`
- Create: `.github/workflows/trayhost-candidate.yml`
- Modify: `.github/workflows/release.yml`
- Create: `tests/persistence/ReleaseWorkflow.SelfTest.ps1`
- Create: `tests/persistence/TrayHostInstalled.SelfTest.ps1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`

- [ ] **Step 1: Write failing exact-version and workflow tests**

Assert 2.4.1 setup/checksum names, English-default bilingual README, net48 prerequisite/no automatic download, source-auditable Host explanation, and two separate workflows.

Candidate workflow:

```text
locked net48 restore -> compile once -> native exact-byte tests -> npm test
-> build -UseExistingTrayHost -> install /DONOTSTART=1
-> headless installed validation -> always cleanup -> upload one candidate artifact
```

Promotion workflow:

```text
workflow_dispatch(tag, candidate_run_id) -> download exact candidate artifact
-> verify provenance commit == tag target -> verify all hashes
-> create/upload Release without compiling or rebuilding
```

- [ ] **Step 2: Verify RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

- [ ] **Step 3: Update version and documentation**

Set package/readme/test assertions to 2.4.1. Explain that Windows 10 1809 requires preinstalled .NET Framework 4.8, TrayHost is internal and cannot be launched directly, and device pairing persists across upgrade.

- [ ] **Step 4: Implement headless installed validation**

`TrayHostInstalled.SelfTest.ps1` verifies installed EXE/config/provenance against active manifest and runs the production EXE's `--headless-smoke` path without Codex, Explorer, or input method dependencies.

- [ ] **Step 5: Implement candidate workflow with unconditional cleanup**

Candidate artifact contains exactly installer, checksum, and provenance JSON. Cleanup uses `if: always()` and verifies no Host/Supervisor/task/installer-owned shortcut remains.

- [ ] **Step 6: Implement promotion-only release workflow**

Use `actions/download-artifact` with the supplied run ID and GitHub token. Reject missing/expired artifacts, tag/commit mismatch, wrong asset names, or hash mismatch. This workflow contains no compiler, Inno, npm build, or source checkout mutation step.

- [ ] **Step 7: Verify GREEN and commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
npm test
```

```bash
git add package.json README.md README.zh-CN.md docs/TECHNICAL.md .github/workflows tests
git commit -m "chore: prepare native tray host release 2.4.1"
```

---

### Task 11: Validate the exact candidate artifact on the target machine

**Files:**
- Create but do not commit yet: `docs/superpowers/validation/2026-08-20-native-tray-host-acceptance.md`
- No production changes unless a failing criterion returns the work to its owning task.

- [ ] **Step 1: Run fresh local source verification**

```powershell
npm test
git status --short
```

Require clean source before publishing a candidate commit.

- [ ] **Step 2: Push the candidate commit and run candidate workflow**

```bash
git push origin main
gh workflow run trayhost-candidate.yml --ref main
```

Capture candidate commit SHA and Actions run ID. Wait for the complete candidate workflow to succeed.

- [ ] **Step 3: Download and verify the exact candidate**

```bash
gh run download <candidate-run-id> --name CodexRemote-fix-2.4.1-candidate --dir build/candidate/2.4.1
```

Verify installer/checksum/provenance names, provenance commit equals candidate SHA, and installer SHA-256 equals checksum. This directory is gitignored.

- [ ] **Step 4: Record protected pre-install state**

Record device-key SHA-256, active runtime ID, task state, exact Supervisor/Host process identities, and Codex root count. Do not print key contents or private command lines.

- [ ] **Step 5: Upgrade using the downloaded candidate**

```powershell
$setup = [IO.Path]::GetFullPath('build\candidate\2.4.1\CodexRemote-fix-2.4.1-setup.exe')
$log = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'CodexRemote-fix-2.4.1-candidate-install.log'))
$process = Start-Process -FilePath $setup -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=$log") -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0) { throw "Installer failed: $($process.ExitCode)" }
```

Verify active runtime 2.4.1, one Supervisor, one Host, manifest/hash match, task Running, one Codex root, and unchanged key SHA-256.

- [ ] **Step 6: Run installed-package tests from the installed package root**

```powershell
$packageRoot = Join-Path $env:LOCALAPPDATA 'CodexControlOtherDevices-installer'
Push-Location $packageRoot
try {
    npm run test:installed
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayHostInstalled.SelfTest.ps1 -InstallRoot (Join-Path $env:LOCALAPPDATA 'CodexControlOtherDevices') -PackageRoot $packageRoot
} finally {
    Pop-Location
}
```

- [ ] **Step 7: Perform the full physical menu/input gate**

Repeat the spec's 50 hidden-icons + 50 direct-icon trials in Chinese and English modes, composition trials, hover/submenu/Escape/outside click, language changes, harmless and enabled commands, Explorer restart, Host crash recovery, Supervisor crash recovery, reboot, and shortcut/Start-menu discovery.

- [ ] **Step 8: Verify Codex and key invariants again**

Confirm remote connection remains active, the setting tab remains available, no re-pair is required, one Codex root remains, and the device-key SHA-256 exactly matches Step 4.

- [ ] **Step 9: Obtain independent release review**

Review production C#, IPC, Supervisor, runtime/installer, exact candidate hashes, test evidence, privacy, and the uncommitted acceptance report. Any Critical or Important finding blocks Task 12.

- [ ] **Step 10: Pause for explicit user confirmation**

Do not tag, promote, or commit the report until the user confirms that real tray and input behavior is correct.

---

### Task 12: Promote the accepted candidate and publish CodexRemote-fix 2.4.1

**Files:**
- Commit after Release: `docs/superpowers/validation/2026-08-20-native-tray-host-acceptance.md`

- [ ] **Step 1: Verify candidate identity and tag absence**

```bash
git status --short
git rev-parse HEAD
git tag --list v2.4.1
```

Only the uncommitted acceptance report may be present. HEAD must equal the accepted candidate SHA and no tag may exist.

- [ ] **Step 2: Tag the exact candidate commit**

```bash
git tag -a v2.4.1 <candidate-sha> -m "CodexRemote-fix 2.4.1"
git push origin v2.4.1
```

- [ ] **Step 3: Promote the exact candidate artifact**

```bash
gh workflow run release.yml -f tag=v2.4.1 -f candidate_run_id=<candidate-run-id>
```

Wait for promotion to download and verify the candidate; it must not compile or rebuild.

- [ ] **Step 4: Verify published assets**

Require:

```text
CodexRemote-fix-2.4.1-setup.exe
CodexRemote-fix-2.4.1-setup.exe.sha256.txt
trayhost-build-provenance.json
```

Release installer SHA-256 must equal both the accepted local candidate and its checksum. Provenance commit must equal the tag target.

- [ ] **Step 5: Commit and push the acceptance report after promotion**

Add Release URL, candidate run ID, candidate SHA, three asset hashes, and final verification booleans, then:

```bash
git add docs/superpowers/validation/2026-08-20-native-tray-host-acceptance.md
git commit -m "test: record native tray host acceptance"
git push origin main
```

- [ ] **Step 6: Final verification**

Confirm tag points to the accepted candidate commit, the report commit is its descendant on `main`, worktree is clean, Release and promotion workflow succeeded, installed 2.4.1 remains active, one Host/Supervisor exists, and device-key SHA-256 remains unchanged.
