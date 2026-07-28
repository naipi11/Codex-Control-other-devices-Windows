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
