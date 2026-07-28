# Clean-room Windows runtime bridge

This directory is an independent implementation made from the supplied functional contract. During its creation, neither excluded source tree was opened, searched, or otherwise inspected, and no repository or Gist about the workaround was consulted. A read-only check of the locally installed `OpenAI.Codex` 26.721.4979.0 package was used only to confirm the native addon's four method names and public result fields.

## Design

- `orchestrator.js` talks only to `127.0.0.1`. It discovers debugger targets, uses a reusable JSON-RPC-over-WebSocket transport, evaluates the selected main payload, waits for an actual TCP `ECONNREFUSED` from the main Inspector port, then installs the renderer payload both in the current document and with `Page.addScriptToEvaluateOnNewDocument`. Renderer selection is fail-closed and accepts only a `page` or `webview` whose URL is exactly `app://-/index.html`; title matches, query-bearing overlay URLs, and arbitrary pages are never fallback targets.
- `renderer-payload.js` scans existing and later `globalThis.__STATSIG__` object graphs. For gate `782640499`, `checkGate`-style methods return `false`; structured gate getters preserve object metadata and Promise behavior while forcing existing `value` and `enabled` fields to `false`. Other gates and all config methods retain the original receiver, arguments, and return value. `globalThis.__CODEX_STATSIG_GATE_BRIDGE__.probe()` reports a non-vacuous check-method proof.
- `main-payload.js` intercepts only requests whose slash-normalized, case-normalized basename is `remote-control-device-key.node`. A stack-sensitive `process.platform` getter returns `darwin` only when `getAddon` appears in the best-effort stack check; ordinary reads retain the actual platform.
- Device keys report the exact algorithm identifier `ecdsa_p256_sha256`: ECDSA P-256 with SHA-256 and a DER signature. Buffer and Uint8Array payloads are signed as their exact bytes, including a Uint8Array view's offset and length. New PKCS8 DER private-key bytes are protected through Windows DPAPI `CurrentUser`; private data is supplied over stdin to the absolute Windows PowerShell path resolved beneath `SystemRoot` or `WINDIR`, never to a PATH-selected executable or on its command line. Output reports omit key material.
- The store is `remote-control-device-keys.windows.json` under resolved `CODEX_HOME`, or under `~/.codex` when `CODEX_HOME` is unset. Version 1 is strict: `{ "schemaVersion": 1, "keys": { ... } }`, with each protected record using `encryptedPrivateKeyBase64`. A legacy flat map accepts only object records containing exactly `algorithm`, `keyId`, `protectionClass`, `publicKeySpkiDerBase64`, and `encryptedPrivateKeyBase64`; inner and outer key IDs must match exactly, and DPAPI plaintext must be PEM. A successful legacy mutation migrates all records to version 1. Parsing, DPAPI decryption, private/public matching, and a concurrent-change check all complete before replacement, so malformed or unreadable data is not overwritten.

Node.js 22 or newer is required. There are no npm dependencies.

## CLI

```powershell
node .\src\runtime\orchestrator.js --renderer-port <cdp-port> --main-port <inspector-port> --timeout-ms <milliseconds> --main-payload .\src\runtime\main-payload.js
```

All four options are required. The timeout range is 500 through 300000 ms. Standard output contains exactly one JSON result; success exits 0 and failure exits 1. `node .\src\runtime\orchestrator.js --help` prints the JSON usage record.

## Tests

Run:

```powershell
node .\tests\CleanroomSelfTest.js
```

The self-test uses a newly created temporary directory and never resolves the real Codex key-store path. It checks every JavaScript file with `node --check`, exact-URL renderer selection when a title-`Codex` avatar overlay is ordered first, rejection when that query-bearing overlay is the only target, the exact filename/algorithm/record fields, absolute SystemRoot/WINDIR PowerShell resolution, protection-mode rejection, DPAPI-backed create/sign/verify/delete for raw Buffer and Uint8Array-view bytes, byte-for-byte preservation of a malformed store, strict legacy PEM loading (including key-ID mismatch and unknown-field rejection) and migration through `encryptedPrivateKeyBase64`, synchronous and Promise-shaped Statsig results for existing and delayed clients, and independent Inspector closure confirmation via `ECONNREFUSED`.
