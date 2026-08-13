# Technical design

## Scope

The project enables the Windows desktop-to-desktop controller path only when the
installed Codex package matches the text sentinels observed in the tested code
family. This is a heuristic guard and does not prove equivalent control flow in
a future build. The project does not change account entitlements, workspace
policy, Remote host availability, SSH, or the mobile-to-desktop host path.

Verified package: `OpenAI.Codex_26.721.4979.0_x64` on Windows 11.

## Package observations

Direct inspection of the verified package established all of the following:

- Renderer assets contain the Windows-specific **Control other devices from
  this PC** UI.
- Renderer assets read Statsig gate `782640499` when deriving
  `showControlOtherDevices`.
- The Electron main bundle references `remote-control-device-key.node`.
- The shipped `getAddon()` path throws unless `process.platform` is `darwin`.
- The Windows `resources/native` directory does not contain the referenced
  module.

`src/check-package.mjs` streams the ASAR instead of extracting it. A build passes
this first guard only when all four textual sentinels exist and the native module
is absent. If an official Windows module appears, `affected` becomes false and
the launcher stops. A passing result still requires human review after updates.

## Runtime components

### PowerShell launcher

`Start-CodexControlOtherDevices.ps1` performs these steps:

1. Runs the compatibility test in a clean Windows PowerShell process.
2. Selects two currently free random loopback ports.
3. Stops only `ChatGPT.exe` processes whose resolved path equals the installed
   `OpenAI.Codex` executable.
4. Starts Codex with renderer CDP and Electron main-process Inspector flags.
5. Runs the clean-room orchestrator, installs the main-process bridge, verifies
   that its Inspector endpoint closes, and then installs the renderer bridge.
6. Records probe results in a timestamped temporary log.
7. If either bridge fails, stops the special instance and starts Codex normally.

No package file is opened for writing.

### Renderer bridge

`src/runtime/orchestrator.js` talks to Chromium DevTools Protocol on loopback
through `src/runtime/lib/cdp.js`. It evaluates
`src/runtime/renderer-payload.js` in the current renderer and registers it for
subsequent documents created in that target.

The injected code:

- enumerates the Statsig clients already registered in the renderer;
- delegates every unrelated gate lookup unchanged;
- returns `false` only for boolean lookups of gate `782640499`;
- preserves object/Promise return shapes for value lookups while changing only
  the target gate's `value`/`enabled` member to `false`;
- exposes a local probe that must report installed clients and only `false`
  values for the target gate.

The launcher treats absence of a working probe as failure.

### Main-process bridge

`src/runtime/orchestrator.js` uses the Electron Node Inspector to evaluate
`src/runtime/main-payload.js` once.

The shim changes two narrowly scoped behaviors for the process lifetime:

1. `process.platform` reports `darwin` when a best-effort JavaScript stack-name
   check contains `getAddon`; other observed calls continue to report `win32`.
   This is not object-identity binding and could also match an unrelated method
   with the same stack name.
2. Node's module loader returns the Windows JavaScript device-key adapter only
   for a request whose normalized basename is exactly
   `remote-control-device-key.node`.

The shim schedules `inspector.close()` after returning its installation status.
The orchestrator then requires an explicit TCP `ECONNREFUSED` from the endpoint;
continued reachability or a timeout is a failure and causes the launcher to
restore a normal Codex start. The renderer CDP endpoint cannot be disabled
dynamically and remains until the application exits.

## Device-key contract

The adapter implements four asynchronous operations expected by Codex:

- `createDeviceKey()`
- `deleteDeviceKey(keyId)`
- `getDeviceKeyPublic(keyId)`
- `signDeviceKey(keyId, payload)`

Keys use ECDSA P-256 with SHA-256. Public keys are exported as DER SPKI. Private
keys are exported temporarily as DER PKCS#8, protected with Windows DPAPI
`CurrentUser`, and cleared from the intermediate JavaScript buffer after the
key object or ciphertext is created.

`createDeviceKey()` accepts only the explicitly observed
`allow_os_protected_nonextractable` request. It rejects `hardware_only` rather
than silently substituting a software DPAPI key for a hardware-only request.

The store is written below `CODEX_HOME`, or `%USERPROFILE%\.codex` when that
environment variable is unset. Its schema is:

```json
{
  "schemaVersion": 1,
  "keys": {
    "dk_osn_example": {
      "algorithm": "ecdsa_p256_sha256",
      "encryptedPrivateKeyBase64": "DPAPI_CIPHERTEXT",
      "protectionClass": "os_protected_nonextractable",
      "publicKeySpkiDerBase64": "PUBLIC_KEY"
    }
  }
}
```

Legacy flat objects with the five fields `algorithm`, `keyId`,
`protectionClass`, `publicKeySpkiDerBase64`, and
`encryptedPrivateKeyBase64`, plus PEM plaintext after DPAPI decryption, are
accepted so an already authorized key from the hunterbeach runtime experiment
remains usable. The nested `keyId` must match its outer map key. The next write
upgrades the outer document to schema version 1.

The protocol compatibility label `os_protected_nonextractable` does not turn a
DPAPI-protected software key into a hardware-backed non-exportable key. This
limitation is documented explicitly in `SECURITY.md`.

## Persistent supervisor

The repository now ships a persistent current-user supervisor in addition to
the manual launcher. The supervisor owns a tray icon, watches the same-Windows-
session Codex package lifecycle, and reapplies the bridge automatically after
normal launches, crashes, and compatible updates.

### Bilingual tray UI contract

The tray layer deliberately separates policy from presentation:

- `SupervisorEngine.psm1` returns only the semantic presentation object
  `{Color, StateKey, SessionReadyVisible, ApplyNowVisible, ApplyNowEnabled,
  ManualRetryVisible, ManualRetryEnabled, AutomationToggleEnabled,
  AutomationChecked, CandidateOptInToggleEnabled, CandidateOptInChecked,
  OpenLogsEnabled, UninstallEnabled, Busy}`.
- `Supervisor.ps1` owns preference reads, locale resolution, command routing, and
  error containment.
- `TrayUi.psm1` owns the STA-thread `NotifyIcon`, native
  `ContextMenuStrip`/`ToolStripMenuItem` controls, localized text, icon resources,
  and confirmation dialogs. It does not decide whether automation is safe.

#### Catalog schema and locale resolution

`src/persistence/resources/ui.en-US.json` and `ui.zh-CN.json` are immutable UTF-8
resources. Each catalog must have exactly these ordered top-level properties:
`schemaVersion`, `locale`, `strings`. `schemaVersion` is integer `1`; `locale`
must exactly match the filename; `strings` must contain the same 32 ordered keys:

```text
Tray.Title
Status.Waiting, Status.Inspecting, Status.Transitioning, Status.Active,
Status.ActivePaused, Status.Suppressed, Status.Recovered, Status.Error
Tooltip.Waiting, Tooltip.Inspecting, Tooltip.Transitioning, Tooltip.Active,
Tooltip.ActivePaused, Tooltip.Suppressed, Tooltip.Recovered, Tooltip.Error
Menu.SessionReady, Menu.ApplyNow, Menu.ManualRetry, Menu.Automation,
Menu.CandidateOptIn, Menu.Language, Menu.FollowSystem, Menu.Chinese,
Menu.English, Menu.OpenLogs, Menu.Uninstall
Dialog.UninstallTitle, Dialog.UninstallMessage
Error.UninstallStart, Error.LanguageChange
```

The loader rejects a BOM, malformed JSON, duplicate properties (including
escaped-name collisions), extra/missing/reordered fields, control characters,
non-string values, oversized strings, and resource paths that escape the
contained resource directory. A damaged Chinese catalog falls back to the
validated English catalog; if English is also invalid, the embedded emergency
English dictionary is used with `UsedEmergencyCatalog=true`.

| `LanguageMode` | Windows culture | `EffectiveLocale` |
|---|---|---|
| `System` | `zh`, `zh-*` | `zh-CN` |
| `System` | any other culture or missing culture | `en-US` |
| `zh-CN` | any | `zh-CN` |
| `en-US` | any | `en-US` |

The language root intentionally remains bilingual: Chinese mode renders
`语言 / Language`; English mode renders `Language / 语言`.

#### UI preference schema and safety boundary

The display preference is independent of `settings.json` and has this exact schema:

```json
{
  "schemaVersion": 1,
  "languageMode": "System",
  "updatedAtUtc": "2026-08-05T00:00:00.0000000Z"
}
```

`languageMode` accepts only `System`, `zh-CN`, or `en-US`; `updatedAtUtc` must be a
canonical UTC round-trip timestamp. `Initialize-CcodUiPreference` creates the file
only on first install, while `Set-CcodUiLanguageMode` replaces it atomically.
`Read-CcodUiPreference` returns `System` with a stable fallback code for missing or
malformed data. That fallback never sets `StateDamageBlocksActions`, changes either
automation-consent switch, quarantines safety state, or blocks a controller action.

#### Live language changes and resource ownership

A language menu click is handled on the tray's owning STA thread:

1. `Supervisor.ps1` resolves the requested catalog and validates the exact catalog
   contract.
2. It atomically persists the requested mode in `ui-preferences.json`.
3. `TrayUi.psm1` updates existing menu rows, language checkmarks, tooltip, and
   title text in place; the `NotifyIcon`, menu, queue, callbacks, and semantic state
   objects keep their identity.
4. If persistence or rendering fails, the previous mode/catalog is restored and a
   localized `Error.LanguageChange` message is contained; the compatibility loop
   continues.

`TrayUi.psm1` generates eight cached icons (Gray/Green/Yellow/Red × 16/32). Each
temporary bitmap and GDI HICON is disposed after its cloned `Icon` is captured.
The title image and bold title font are separately owned resources. Close is
idempotent, detaches callbacks, hides/disposes the `NotifyIcon`, disposes the native
menu and controls once, then releases title resources and cached icons.

#### Installation, manifest, and uninstall boundary

The installer includes exactly `ui.en-US.json` and `ui.zh-CN.json` in the fixed
resource allowlist. They are copied into the staged runtime, hashed in
`manifest.json`, and verified before `active.json` switches. The installed
supervisor therefore uses the same immutable catalog bytes as the runtime
manifest; do not manually copy UI files into an active runtime.

Tray uninstall is a verified launch, not an in-process cleanup shortcut. After the
native Yes/No warning (default button No), `UiActions.psm1` verifies the active
runtime pointer, manifest hashes, contained `Uninstall-CodexControlOtherDevices.ps1`,
reparse-point status, approved Windows PowerShell host, and the exact argument vector.
Only then does it start the runtime-bound uninstaller. The uninstaller performs the
existing normalization, task removal, supervisor shutdown/wait, and runtime/state
cleanup sequence, preserving the DPAPI device-key store by default. A launch
failure is logged as `CCOD_UNINSTALL_START_FAILED` and leaves the tray and current
Codex session usable.

### Source and installed layouts

The source checkout is the only trusted input. The installer copies a fixed
allowlist into a versioned runtime below `%LOCALAPPDATA%\CodexControlOtherDevices`:

```text
%LOCALAPPDATA%\CodexControlOtherDevices\
├── bootstrap.ps1                        # stable self-contained bootstrap
├── Uninstall-CodexControlOtherDevices.ps1
├── active.json                          # schema 1 active/previous pointer
├── runtime\<runtime-id>\                # staged, hashed, immutable runtime
│   ├── manifest.json                    # schema 1 file records + runtime-id
│   ├── src\persistence\Supervisor.ps1
│   ├── src\persistence\SessionController.ps1
│   ├── src\persistence\StaticProbeWorker.ps1
│   ├── src\persistence\modules\*.psm1
│   ├── src\persistence\resources\ui.*.json
│   ├── src\runtime\*                    # clean-room bridge
│   └── src\check-package.mjs
├── state\
│   ├── settings.json                    # schema 1 consent + verified Node paths
│   ├── ui-preferences.json              # schema 1 display-language preference
│   ├── status.json                      # schema 1 supervisor/session evidence
│   ├── verified-packages.json           # schema 1 suppression/verification cache
│   └── transition.json                  # schema 1 active transaction
└── logs\                                # 2 MiB rotating, 10 generations
```

`runtime-id` is derived as `projectVersion-contentHashPrefix` from the sorted
file records, so identical content has a stable id and tampering changes it.
The installer never copies `.git`, tests, docs, or the public scripts other
than the stable bootstrap/uninstaller copies. Every staged file is compared
against the source SHA-256 before the manifest is trusted.

### Schema versions

- `manifest.json` schema 1: `schemaVersion`, `projectVersion`, `runtimeId`,
  and a sorted `files` array with `path`, `length`, and lowercase `sha256`;
  it never lists itself and never accepts absolute, empty, duplicate, or
  `..`-escaping paths.
- `active.json` schema 1: `schemaVersion`, `activeRuntime`, nullable
  `previousRuntime`, and `updatedAtUtc`. The pointer is replaced atomically
  through a native handle; a failed switch restores the old bytes.
- `settings.json` schema 1: `automationEnabled` and `candidateCompatibleOptIn`
  are independent booleans, `nodeCandidates` are absolute installer-verified
  `node.exe` paths, and `updatedAtUtc` is a canonical UTC string.
- `ui-preferences.json` schema 1: display-only `languageMode` and canonical
  `updatedAtUtc`; it is not safety state and malformed bytes fall back to
  `System`.
- `status.json` schema 1: nullable `session` with `supervisorPid`,
  `supervisorCreationTimeUtc`, `sessionId`, `runtimeId`, `sessionState`, and
  nullable `codex` identity/probe evidence. A non-empty `codex` requires
  `sessionState=Active` and a matching live probe.
- `verified-packages.json` schema 1: `packages` keyed by
  `packageFullName|appAsarSha256|runtimeId` with static classification,
  dynamic outcome, probe state, and confirmation time.
- `transition.json` schema 1: `activeTransaction` null or one exact
  transaction object; damaged or missing transition state disables automation.

### Controller envelope

`SessionController.ps1` is a one-shot JSON CLI. It accepts either a strict
request file or manual parameters, validates schema 1, acquires the account
then session transition mutexes, invokes the SessionEngine action, persists
the result atomically, and writes exactly one compressed JSON line to stdout.
The envelope always carries `schemaVersion`, `action`, `transactionId`,
`outcome`, `safeState`, `stage`, `package`, `source`, `special`, `probes`,
`recovery`, `error`, and `logFile`. Supervisor and worker verify correlation
by transaction id and exact persisted-vs-stdout equality.

### Journal stages and replay

The transition journal is a crash-consistent state machine. Every mutation is
atomic, and each durable stage records the source PID/creation time so a
recovery can verify ownership before acting:

| Stage | Meaning | Replay behavior |
|---|---|---|
| `IntentWritten` | manual/apply intent recorded | fresh Recover consumes it |
| `StopRequested` | verified tree stop commanded | observe ≤5 s; only identical PID |
| `SpecialLaunchRequested` | special launch commanded | observe ≤5 s; adopt exact package identity |
| `SpecialStarted` | special PID handed back | adopt or fail closed |
| `Validated` | probes complete, special proven | adopt, may become `Active` |
| `Activated` | bridge active and green | mark complete |
| `RecoveryLaunchRequested` | ordinary restart commanded | adopt new ordinary, never relaunch special |
| `Recovered` | ordinary proven | complete once, idempotent |
| `Closed` | close-tree transaction complete | archive once, idempotent |

Completion archives the transaction and clears `activeTransaction`. Each crash
window replays at most once; deduplication requires the exact rotated-log
archive record.

### Manifest/active switching and ready fallback

Upgrade stages a new runtime, generates and validates its manifest, moves it
to `runtime\<id>`, then atomically switches `active.json` so the old runtime
becomes `previousRuntime`. Only active and previous are retained; older
contained non-reparse runtime directories are deleted. The installer signals
the old supervisor through its ACL-protected shutdown event, waits for the
exact PID/creation time, and only terminates that verified identity on
timeout. Bootstrap then launches the new supervisor.

Bootstrap is self-contained: it reads the active/previous pointer, validates
every manifest hash, creates a one-time ready event named
`Local\CodexControlOtherDevices.Ready.<SID>.<SessionId>.<64-hex>`, and waits up
to 15 seconds. If the active runtime exits early or times out, bootstrap stops
that exact child, validates the previous runtime, launches it, and atomically
switches the pointer on success. If neither runtime signals ready, bootstrap
fails closed and logs the reason.

### Scheduled task

The fixed task `Codex Control Other Devices Supervisor` is registered for the
current user only:

- `LogonType=Interactive`, `RunLevel=Limited`, `MultipleInstances=IgnoreNew`;
- restart on failure: 3 attempts, 1 minute apart;
- `ExecutionTimeLimit=PT0S`, `DisallowStartIfOnBatteries=false`,
  `StopIfGoingOnBatteries=false`;
- action: `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
  -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File
  <bootstrap>`;
- working directory: the install root.

The supervisor is unelevated and never creates services, firewall rules,
IFEO, or permanent WMI consumers.

### WMI capability chain and reconciliation authority

The supervisor tries `Win32_ProcessStartTrace` first for low-latency process
start hints. Access denial falls back to a temporary
`__InstanceCreationEvent WITHIN 1` subscription; if neither is available it
records the capability and relies on reconciliation only. It never elevates
or rewrites WMI ACLs. Reconciliation runs every 3 seconds and is the
authoritative source for adoption, stop, recovery, and suppression decisions;
event hints only reduce latency.

### Exact probes

- Renderer target must be exactly `app://-/index.html`; title matches,
  query-bearing overlays, and arbitrary pages are never accepted.
- Bridge installation covers the current document and new documents.
- Gate `782640499` must return `false` with a non-empty Statsig proof.
- Main Inspector must reach explicit TCP `ECONNREFUSED` after close; an open
  endpoint or timeout is a failure that restores an ordinary session.
- Special-process identity requires matching PID, creation time, package
  family, executable path, session, user, and debug-token tuple; PID reuse is
  rejected.

### External renderer shared CDP handoff

`RendererIntegration.psm1` is an optional persistence-layer boundary for a
locally installed External renderer Windows runtime. Before special launch, the
SessionEngine may prefer the validated port from External renderer state, or its
default port `9335` when state is absent. It uses a dynamically selected
loopback renderer port instead when that preferred port is unavailable,
excluded by the separate main Inspector port, paused, or associated state is
invalid. This is port selection, not a guarantee that a Browser-ID or port can
be reused.

After a successful, validated special session, the supervisor attempts the
handoff only when External renderer is installed and not marked with its `pause`
file. If saved state exists, it checks the local CDP identity before invoking
External renderer's own start script; unavailable or already-attached identity skips
the handoff. Missing or invalid state and any handoff failure are contained to
the optional integration and leave the Codex session usable. This boundary
does not write Codex or External renderer installation files.

### Device-key bridge boundary

The device-key bridge is unchanged by the persistence layer. Keys remain
P-256 + DPAPI `CurrentUser` at the resolved
`%CODEX_HOME%\remote-control-device-keys.windows.json` (or `~/.codex`), the
legacy flat store remains readable and migrates on write, and the supervisor
never logs key material. Uninstall preserves the store by default; explicit
backup moves it to a timestamped sibling, and explicit removal deletes it,
neither of which revokes server-side authorization.

## Failure and update behavior

Within the tested code family, the project intentionally stops on detected
mismatches and operational failures:

- missing Node.js or Store package: stop;
- missing project source: stop;
- text-sentinel mismatch: stop;
- native Windows device-key module now present: stop;
- occupied explicitly selected port: stop;
- main bridge or Inspector-close verification failure: restart Codex normally;
- renderer probe failure: restart Codex normally;
- future build missing any current sentinel: stop pending review.

The persistent supervisor adds these rules:

- a first-seen `CandidateCompatible` package is tried at most once, and only
  when `automationEnabled` and `candidateCompatibleOptIn` are both true;
- `UnknownOrIncompatible` and `NativeModulePresent` builds stay ordinary and
  are never stopped or reopened;
- a failed dynamic probe records a suppression key for
  `packageFullName|appAsarSha256|runtimeId`; only manual retry or a new
  runtime id clears it;
- damaged or missing state quarantines the evidence and disables automation
  until explicit `-RepairState`, which resets both consent switches to false;
- a validated special session survives an upgrade: the new supervisor
  reconciles and adopts it instead of restarting Codex;
- default uninstall normalizes a validated special session back to ordinary,
  verifies both debugger ports closed, and only then removes the task and
  runtime.

This is safer than relying only on a static version list, but it is not a
structured control-flow or binary-integrity check. A future build that retains
all strings while changing behavior could pass the heuristic and still be
incompatible.

## Trust boundaries

- Loopback is a network exposure boundary, not an authentication boundary.
- Any process running as the same Windows user must be considered capable of
  reaching the renderer CDP endpoint.
- DPAPI binds ciphertext to the current Windows user profile, not to this one
  Codex process.
- The scheduled task and tray supervisor run unelevated as the current user;
  everything they write under the install root is part of the same trust root.
- Manifest and state hashes detect corruption and tampering, but they do not
  authenticate the author of a checkout; source trust comes from user review
  of the repository.
- Renderer CDP stays available to same-user processes for the whole special
  session; the main Inspector is limited to the startup window and must close.
- ChatGPT account authorization, required MFA/SSO/passkey checks, workspace
  policy, and server-side device revocation remain authoritative.
- Remote hosts retain their own filesystem, credentials, approvals, plugins,
  and local security settings.

## Non-goals

- Patching or redistributing Codex application files.
- Bypassing MFA, SSO, passkeys, workspace administration, or server-side
  enrollment.
- Exposing Electron Inspector or CDP beyond `127.0.0.1`.
- Providing a TPM/CNG native key backend.
- Guaranteeing compatibility with an unreviewed future Codex build.
