# Native tray input-mode spike — blocked

Date: 2026-08-20
Scope: non-shipping `NoHimcSpike` only
Machine: current Windows 11 interactive session

## Automated evidence

- Native fake-boundary self-test: 5/5 passed.
- Owner creation, owner HIMC disassociation, foreground proof, native menu call ordering, `WM_NULL`, `NIM_SETFOCUS`, reentry rejection, and cleanup all passed.
- The test source does not access Codex processes, device keys, or remote-session state.

## Physical evidence

- The yellow `TEST ONLY - no-HIMC spike` icon registered in the Windows hidden-icons area.
- The first 50-trial run ended with a clean JSON receipt showing `foregroundFailures=0`, `ownerHasNoInputContext=true`, and `trackCalls=50`; the program is intentionally configured to exit at its trial limit.
- During the user's observation, the menu visibly flashed/closed before the user considered 50 interactions complete. The receipt does not prove that each menu remained selectable, so this is not a passing acceptance result.
- A later one-trial run received no user event and was stopped safely; it produced no additional evidence.

## Trace follow-up

One interactive five-cancel run completed normally with this bounded receipt:

```text
attempts=5, trackCalls=5, cancelCount=5, selectedCount=0,
foregroundFailures=0, ownerHasNoInputContext=true,
trackMinMs=498, trackMaxMs=3083, trackAverageMs=1074,
WM_NULL_Delivered=5
```

The trace contained one `WM_CONTEXTMENU` path per attempt and no immediate zero-duration return. This is useful diagnostic evidence, but it is not the required 50-trial acceptance and does not cover a selected menu command or a measured Chinese/English input-mode comparison.

## Gate result

**BLOCKED / NOT PASSED.** The current no-HIMC persistent-owner spike does not yet demonstrate stable repeated interaction on the target machine. No production TrayHost, IPC integration, installer build, push, tag, or Release may proceed from this evidence.

The installed CodexRemote-fix runtime and device-key store were not modified by the spike. The temporary spike process was stopped after each run.

## Next decision

Return to the architecture review. A follow-up spike must capture per-menu dwell/cancel/selection timing and the actual shell callback sequence, or the strict “no input-method change” requirement must be explicitly reconsidered before another implementation attempt.
