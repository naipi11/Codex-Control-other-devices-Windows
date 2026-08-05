# Bilingual Tray UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain status-circle tray UI with the approved connection-bridge icon and a context-aware Chinese/English menu that follows Windows by default and supports a persisted manual language override.

**Architecture:** Immutable UTF-8 JSON catalogs and a focused localization module provide validated strings; a separate non-safety preference module persists only `System`, `zh-CN`, or `en-US` without touching `settings.json`. `SupervisorEngine` emits semantic presentation state, `Supervisor.ps1` resolves locale and commands, and `TrayUi.psm1` owns only native WinForms controls, icon drawing, localized rendering, and confirmation UI.

**Tech Stack:** Windows PowerShell 5.1, WinForms `NotifyIcon`/`ContextMenuStrip`, `System.Drawing`, strict UTF-8 JSON, existing `PersistenceIO.psm1`, fake-first PowerShell self-tests, npm validation wrapper.

**Approved design:** `docs/superpowers/specs/2026-08-05-tray-ui-localization-design.md`

## Global Constraints

- Execute Tasks 1 through 8 in numeric order; do not skip the red test in any task.
- Support Windows 11 and Windows PowerShell 5.1 without third-party UI or localization dependencies.
- Keep `settings.json`, controller requests, status protocols, logs, error IDs, and machine-readable JSON fields in stable English.
- Store UI language independently in `state\ui-preferences.json`; invalid or missing UI preference must never set `StateDamageBlocksActions` or modify automation consent.
- Support exactly `System`, `zh-CN`, and `en-US`; map every `zh-*` Windows culture to `zh-CN` and every other culture to `en-US`.
- Keep the language root bilingual: `语言 / Language` in Chinese and `Language / 语言` in English.
- Generate 16×16 and 32×32 icons in code for Gray, Green, Yellow, and Red; do not add binary icon assets.
- Use native `ContextMenuStrip`, `ToolStripMenuItem`, and `ToolStripSeparator`; do not add owner-drawn menus.
- Preserve current STA ownership, bounded queues, no-output callbacks, atomic writes, contained paths, reparse-point rejection, runtime manifests, and exact cleanup semantics.
- Each task ends in a focused commit. Do not combine production code from a later task into an earlier commit.

---

### Task 1: Immutable Localization Catalogs

**Files:**
- Create: `src/persistence/modules/UiLocalization.psm1`
- Create: `src/persistence/resources/ui.en-US.json`
- Create: `src/persistence/resources/ui.zh-CN.json`
- Create: `tests/persistence/UiLocalization.SelfTest.ps1`

**Public interfaces:**
- `Get-CcodUiCatalog -ResourcesRoot <absolute> -LanguageMode <System|zh-CN|en-US> -SystemCultureName <name>` returns exact ordered fields `{LanguageMode, EffectiveLocale, Strings, UsedEmergencyCatalog, ErrorCode}`.
- `Get-CcodUiString -Catalog <catalog> -Key <known-key> -Arguments <object[]>` returns one bounded formatted string.

- [ ] **Step 1: Write the failing localization tests**

Use the existing `Invoke-CcodTest`, `Assert-CcodEqual`, and `Assert-CcodThrows` helpers. Cover:

```powershell
$en=Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode en-US -SystemCultureName zh-CN
$zh=Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode zh-CN -SystemCultureName en-US
Assert-CcodEqual 'en-US' $en.EffectiveLocale 'explicit English wins'
Assert-CcodEqual 'zh-CN' $zh.EffectiveLocale 'explicit Chinese wins'
Assert-CcodEqual (($en.Strings.PSObject.Properties.Name)-join ',') (($zh.Strings.PSObject.Properties.Name)-join ',') 'catalog keys and order match'
Assert-CcodEqual 'zh-CN' (Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode System -SystemCultureName zh-Hans).EffectiveLocale 'all zh cultures map to Chinese'
Assert-CcodEqual 'en-US' (Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode System -SystemCultureName fr-FR).EffectiveLocale 'other cultures map to English'
Assert-CcodThrows { Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode 'zh-cn' -SystemCultureName zh-CN } 'CCOD_UI_LANGUAGE_INVALID'
Assert-CcodThrows { Get-CcodUiString -Catalog $en -Key 'Unknown.Key' } 'CCOD_UI_STRING_INVALID'
```

Add fixtures proving that duplicate/extra/missing keys, wrong field order, wrong schema, non-string values, control characters, oversized values, malformed JSON, and reparse/containment violations are rejected. Prove a damaged selected resource falls back to the validated English catalog, and damaged English falls back to the embedded emergency English catalog with `UsedEmergencyCatalog=$true` and a stable `ErrorCode`.

- [ ] **Step 2: Run the test and verify the red state**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/UiLocalization.SelfTest.ps1
```

Expected: FAIL because the module and resources do not exist.

- [ ] **Step 3: Create exact bilingual resource catalogs**

Both files use this exact ordered schema and exact key order:

```json
{
  "schemaVersion": 1,
  "locale": "en-US",
  "strings": {
    "Tray.Title": "Codex Device Connection",
    "Status.Waiting": "Waiting for Codex",
    "Status.Inspecting": "Inspecting current Codex",
    "Status.Transitioning": "Applying compatibility bridge",
    "Status.Active": "\u201cControl other devices\u201d is active for this session",
    "Status.ActivePaused": "Current session is active; automatic repair is paused",
    "Status.Suppressed": "Compatibility action is suppressed",
    "Status.Recovered": "Ordinary Codex restored after safe recovery",
    "Status.Error": "Automatic actions blocked; review logs",
    "Tooltip.Waiting": "Codex device connection: waiting",
    "Tooltip.Inspecting": "Codex device connection: inspecting",
    "Tooltip.Transitioning": "Codex device connection: applying bridge",
    "Tooltip.Active": "Codex device connection: working",
    "Tooltip.ActivePaused": "Codex connection active; automation paused",
    "Tooltip.Suppressed": "Codex connection action suppressed",
    "Tooltip.Recovered": "Codex restored after safe recovery",
    "Tooltip.Error": "Codex connection actions blocked",
    "Menu.SessionReady": "Current session is ready",
    "Menu.ApplyNow": "Check and repair now",
    "Menu.ManualRetry": "Retry last repair",
    "Menu.Automation": "Repair new sessions automatically",
    "Menu.CandidateOptIn": "Allow compatible update trials",
    "Menu.Language": "Language / \u8bed\u8a00",
    "Menu.FollowSystem": "Follow system ({0})",
    "Menu.Chinese": "\u4e2d\u6587",
    "Menu.English": "English",
    "Menu.OpenLogs": "Open logs",
    "Menu.Uninstall": "Uninstall supervisor\u2026",
    "Dialog.UninstallTitle": "Uninstall Codex connection supervisor?",
    "Dialog.UninstallMessage": "This stops the supervisor. A managed Codex session will restart normally. Device keys are kept by default.",
    "Error.UninstallStart": "Could not start the uninstaller. Review logs.",
    "Error.LanguageChange": "Could not change language. The previous language remains active."
  }
}
```

For `ui.zh-CN.json`, keep the same schema/key order and set `locale` to `zh-CN` with these exact values:

```json
{
  "schemaVersion": 1,
  "locale": "zh-CN",
  "strings": {
    "Tray.Title": "Codex \u8bbe\u5907\u8fde\u63a5",
    "Status.Waiting": "\u7b49\u5f85 Codex",
    "Status.Inspecting": "\u6b63\u5728\u68c0\u67e5\u5f53\u524d Codex",
    "Status.Transitioning": "\u6b63\u5728\u5e94\u7528\u517c\u5bb9\u6865",
    "Status.Active": "\u5f53\u524d\u4f1a\u8bdd\u5df2\u542f\u7528\u201c\u8fde\u63a5\u5176\u4ed6\u8bbe\u5907\u201d",
    "Status.ActivePaused": "\u5f53\u524d\u4f1a\u8bdd\u5df2\u751f\u6548\uff1b\u540e\u7eed\u81ea\u52a8\u4fee\u590d\u5df2\u6682\u505c",
    "Status.Suppressed": "\u517c\u5bb9\u64cd\u4f5c\u5df2\u88ab\u6291\u5236",
    "Status.Recovered": "\u5df2\u5b89\u5168\u6062\u590d\u666e\u901a Codex",
    "Status.Error": "\u81ea\u52a8\u64cd\u4f5c\u5df2\u963b\u6b62\uff1b\u8bf7\u67e5\u770b\u65e5\u5fd7",
    "Tooltip.Waiting": "Codex \u8bbe\u5907\u8fde\u63a5\uff1a\u7b49\u5f85\u4e2d",
    "Tooltip.Inspecting": "Codex \u8bbe\u5907\u8fde\u63a5\uff1a\u68c0\u67e5\u4e2d",
    "Tooltip.Transitioning": "Codex \u8bbe\u5907\u8fde\u63a5\uff1a\u5e94\u7528\u4e2d",
    "Tooltip.Active": "Codex \u8bbe\u5907\u8fde\u63a5\uff1a\u8fd0\u884c\u6b63\u5e38",
    "Tooltip.ActivePaused": "Codex \u8fde\u63a5\u5df2\u751f\u6548\uff1b\u81ea\u52a8\u4fee\u590d\u5df2\u6682\u505c",
    "Tooltip.Suppressed": "Codex \u8fde\u63a5\u64cd\u4f5c\u5df2\u6291\u5236",
    "Tooltip.Recovered": "Codex \u5df2\u5b89\u5168\u6062\u590d",
    "Tooltip.Error": "Codex \u8fde\u63a5\u64cd\u4f5c\u5df2\u963b\u6b62",
    "Menu.SessionReady": "\u5f53\u524d\u4f1a\u8bdd\u5df2\u751f\u6548",
    "Menu.ApplyNow": "\u7acb\u5373\u68c0\u67e5\u5e76\u4fee\u590d",
    "Menu.ManualRetry": "\u91cd\u8bd5\u4e0a\u6b21\u4fee\u590d",
    "Menu.Automation": "\u81ea\u52a8\u4fee\u590d\u65b0\u4f1a\u8bdd",
    "Menu.CandidateOptIn": "\u5141\u8bb8\u517c\u5bb9\u66f4\u65b0\u8bd5\u8fd0\u884c",
    "Menu.Language": "\u8bed\u8a00 / Language",
    "Menu.FollowSystem": "\u8ddf\u968f\u7cfb\u7edf\uff08{0}\uff09",
    "Menu.Chinese": "\u4e2d\u6587",
    "Menu.English": "English",
    "Menu.OpenLogs": "\u6253\u5f00\u65e5\u5fd7",
    "Menu.Uninstall": "\u5378\u8f7d\u5b88\u62a4\u7a0b\u5e8f\u2026",
    "Dialog.UninstallTitle": "\u5378\u8f7d Codex \u8fde\u63a5\u5b88\u62a4\u7a0b\u5e8f\uff1f",
    "Dialog.UninstallMessage": "\u8fd9\u5c06\u505c\u6b62\u5b88\u62a4\u7a0b\u5e8f\u3002\u5982\u679c\u5f53\u524d Codex \u4f1a\u8bdd\u5df2\u63a5\u7ba1\uff0cCodex \u5c06\u6062\u590d\u4e3a\u666e\u901a\u542f\u52a8\u3002\u9ed8\u8ba4\u4fdd\u7559\u8bbe\u5907\u5bc6\u94a5\u3002",
    "Error.UninstallStart": "\u65e0\u6cd5\u542f\u52a8\u5378\u8f7d\u7a0b\u5e8f\uff1b\u8bf7\u67e5\u770b\u65e5\u5fd7\u3002",
    "Error.LanguageChange": "\u65e0\u6cd5\u5207\u6362\u8bed\u8a00\uff1b\u5df2\u4fdd\u7559\u539f\u8bed\u8a00\u3002"
  }
}
```

- [ ] **Step 4: Implement strict catalog loading**

In `UiLocalization.psm1` define the exact modes/keys, a complete embedded English dictionary, strict resource validation, and these core functions:

```powershell
Set-StrictMode -Version Latest
$script:CcodUiModes=@('System','zh-CN','en-US')
$script:CcodUiKeys=@(
  'Tray.Title','Status.Waiting','Status.Inspecting','Status.Transitioning','Status.Active','Status.ActivePaused','Status.Suppressed','Status.Recovered','Status.Error',
  'Tooltip.Waiting','Tooltip.Inspecting','Tooltip.Transitioning','Tooltip.Active','Tooltip.ActivePaused','Tooltip.Suppressed','Tooltip.Recovered','Tooltip.Error',
  'Menu.SessionReady','Menu.ApplyNow','Menu.ManualRetry','Menu.Automation','Menu.CandidateOptIn','Menu.Language','Menu.FollowSystem','Menu.Chinese','Menu.English','Menu.OpenLogs','Menu.Uninstall',
  'Dialog.UninstallTitle','Dialog.UninstallMessage','Error.UninstallStart','Error.LanguageChange'
)

function Resolve-CcodUiLocale {
  param([string]$LanguageMode,[string]$SystemCultureName)
  if($script:CcodUiModes -cnotcontains $LanguageMode){
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('The UI language mode is invalid.'),'CCOD_UI_LANGUAGE_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null)
  }
  if($LanguageMode -cne 'System'){return $LanguageMode}
  if($SystemCultureName -is [string] -and $SystemCultureName -cmatch '^zh(?:-|$)'){return 'zh-CN'}
  return 'en-US'
}

function Get-CcodUiString {
  [CmdletBinding()]param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$Key,[object[]]$Arguments=@())
  if($null -eq $Catalog -or $null -eq $Catalog.Strings -or $script:CcodUiKeys -cnotcontains $Key){
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('The UI string request is invalid.'),'CCOD_UI_STRING_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null)
  }
  $property=$Catalog.Strings.PSObject.Properties[$Key]
  if($null -eq $property -or $property.Value -isnot [string]){
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('The UI string request is invalid.'),'CCOD_UI_STRING_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null)
  }
  $value=if($Arguments.Count -eq 0){$property.Value}else{[string]::Format([Globalization.CultureInfo]::InvariantCulture,$property.Value,$Arguments)}
  if([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 300){
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('The UI string request is invalid.'),'CCOD_UI_STRING_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null)
  }
  return $value
}

Export-ModuleMember -Function Get-CcodUiCatalog,Get-CcodUiString
```

`Get-CcodUiCatalog` reads with `[IO.File]::ReadAllText(path,[Text.UTF8Encoding]::new($false))`, rejects BOM/control characters, requires exact ordered top-level fields `schemaVersion,locale,strings`, exact ordered keys, exact locale, and string values of 1–300 characters. It uses English for a damaged Chinese catalog, and the full embedded dictionary only when English cannot validate.

- [ ] **Step 5: Run tests and commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/UiLocalization.SelfTest.ps1
git add src/persistence/modules/UiLocalization.psm1 src/persistence/resources/ui.en-US.json src/persistence/resources/ui.zh-CN.json tests/persistence/UiLocalization.SelfTest.ps1
git commit -m "feat: add strict bilingual UI catalogs"
```

Expected: all localization tests PASS before commit.

---

### Task 2: Non-Safety UI Preference Persistence

**Files:**
- Create: `src/persistence/modules/UiPreferences.psm1`
- Create: `tests/persistence/UiPreferences.SelfTest.ps1`

**Public interfaces:**
- `Initialize-CcodUiPreference -StateRoot <absolute>` creates exact schema 1 with `System` and refuses overwrite.
- `Read-CcodUiPreference -StateRoot <absolute>` returns exact `{LanguageMode, FallbackUsed, ErrorCode}` and never throws for missing/malformed preference content.
- `Set-CcodUiLanguageMode -StateRoot <absolute> -LanguageMode <enum>` returns exact `{LanguageMode, UpdatedAtUtc}` after atomic persistence.

- [ ] **Step 1: Write failing preference tests**

```powershell
$missing=Read-CcodUiPreference -StateRoot $stateRoot
Assert-CcodEqual 'System' $missing.LanguageMode 'missing defaults to System'
Assert-CcodEqual $true $missing.FallbackUsed 'missing fallback is observable'
Assert-CcodEqual 'CCOD_UI_PREFERENCES_MISSING' $missing.ErrorCode 'stable missing code'

[IO.File]::WriteAllText((Join-Path $stateRoot 'ui-preferences.json'),'{bad',[Text.UTF8Encoding]::new($false))
$invalid=Read-CcodUiPreference -StateRoot $stateRoot
Assert-CcodEqual 'System' $invalid.LanguageMode 'malformed defaults to System'
Assert-CcodEqual 'CCOD_UI_PREFERENCES_INVALID' $invalid.ErrorCode 'stable invalid code'

$receipt=Set-CcodUiLanguageMode -StateRoot $stateRoot -LanguageMode zh-CN -Adapters @{UtcNow={ [datetimeoffset]'2026-08-05T00:00:00Z' }}
Assert-CcodEqual 'LanguageMode,UpdatedAtUtc' (($receipt.PSObject.Properties.Name)-join ',') 'exact receipt'
Assert-CcodEqual 'zh-CN' (Read-CcodUiPreference -StateRoot $stateRoot).LanguageMode 'override persists'
foreach($bad in @('system','zh-cn','fr-FR','')){Assert-CcodThrows {Set-CcodUiLanguageMode -StateRoot $stateRoot -LanguageMode $bad} 'CCOD_UI_LANGUAGE_INVALID'}
```

Add strict schema/order/timestamp tests, contained-path/reparse tests using the fake adapter patterns in `PersistenceIO.SelfTest.ps1`, and a regression proving malformed UI preference never changes `settings.json` or controller safety state.

- [ ] **Step 2: Run the test and verify the red state**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/UiPreferences.SelfTest.ps1
```

Expected: FAIL because `UiPreferences.psm1` does not exist.

- [ ] **Step 3: Implement exact schema, adapters, fallback read, and atomic writes**

```powershell
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1')
$script:CcodUiLanguageModes=@('System','zh-CN','en-US')

function Get-CcodUiPreferenceAdapters {
  param([hashtable]$Overrides)
  $resolved=@{UtcNow={ [datetimeoffset]::UtcNow }}
  if($null -ne $Overrides){foreach($name in $Overrides.Keys){if($resolved.Keys -cnotcontains $name){throw "Unknown adapter: $name"};$resolved[$name]=$Overrides[$name]}}
  return $resolved
}

function New-CcodUiPreferenceStore {
  param([string]$LanguageMode,[string]$UpdatedAtUtc)
  [pscustomobject][ordered]@{schemaVersion=1;languageMode=$LanguageMode;updatedAtUtc=$UpdatedAtUtc}
}

function Read-CcodUiPreference {
  [CmdletBinding()]param([Parameter(Mandatory)][string]$StateRoot)
  $path=Resolve-CcodContainedPath -Root $StateRoot -RelativePath 'ui-preferences.json' -AllowMissingLeaf
  if(-not [IO.File]::Exists($path)){return [pscustomobject][ordered]@{LanguageMode='System';FallbackUsed=$true;ErrorCode='CCOD_UI_PREFERENCES_MISSING'}}
  try{
    $store=Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'UI preferences'
    Assert-CcodUiPreferenceStore $store
    return [pscustomobject][ordered]@{LanguageMode=$store.languageMode;FallbackUsed=$false;ErrorCode=$null}
  }catch{
    return [pscustomobject][ordered]@{LanguageMode='System';FallbackUsed=$true;ErrorCode='CCOD_UI_PREFERENCES_INVALID'}
  }
}

function Set-CcodUiLanguageMode {
  [CmdletBinding()]param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$LanguageMode,[hashtable]$Adapters)
  if($script:CcodUiLanguageModes -cnotcontains $LanguageMode){
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('The UI language mode is invalid.'),'CCOD_UI_LANGUAGE_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null)
  }
  $resolved=Get-CcodUiPreferenceAdapters $Adapters
  $updated=(& $resolved.UtcNow).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
  $store=New-CcodUiPreferenceStore $LanguageMode $updated
  Assert-CcodUiPreferenceStore $store
  $path=Resolve-CcodContainedPath -Root $StateRoot -RelativePath 'ui-preferences.json' -AllowMissingLeaf
  Write-CcodAtomicJson -Path $path -Value $store
  [pscustomobject][ordered]@{LanguageMode=$LanguageMode;UpdatedAtUtc=$updated}
}

Export-ModuleMember -Function Initialize-CcodUiPreference,Read-CcodUiPreference,Set-CcodUiLanguageMode
```

`Assert-CcodUiPreferenceStore` requires exact ordered fields, integer schema 1, case-exact enum, and canonical round-trip UTC. `Initialize-CcodUiPreference` calls the same atomic writer with `System` only when the file does not exist; an existing file raises `CCOD_UI_PREFERENCES_EXISTS`.

- [ ] **Step 4: Run tests and commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/UiPreferences.SelfTest.ps1
git add src/persistence/modules/UiPreferences.psm1 tests/persistence/UiPreferences.SelfTest.ps1
git commit -m "feat: persist non-safety UI language preference"
```

Expected: all preference schema, fallback, timestamp, containment, and atomic-write tests PASS.

---

### Task 3: Semantic Tray Presentation Contract

**Files:**
- Modify: `src/persistence/modules/SupervisorEngine.psm1`
- Modify: `tests/persistence/SupervisorEngine.SelfTest.ps1`

**Contract:** existing `Get-CcodTrayPresentation` stops emitting English UI prose. It keeps its current parameter list and returns exact ordered semantic fields:

```text
Color,StateKey,SessionReadyVisible,ApplyNowVisible,ApplyNowEnabled,
ManualRetryVisible,ManualRetryEnabled,AutomationToggleEnabled,
AutomationChecked,CandidateOptInToggleEnabled,CandidateOptInChecked,
OpenLogsEnabled,UninstallEnabled,Busy
```

The projection is exact: `Waiting→Waiting/Gray`, `Inspecting→Inspecting/Gray`, `Transitioning→Transitioning/Gray`, `Active` with automation on → `Active/Green`, `Active` with automation off → `ActivePaused/Green`, `Suppressed→Suppressed/Yellow`, `Recovered→Recovered/Red`, and `Error→Error/Red` (`StateKey/Color`).

- [ ] **Step 1: Replace prose assertions with failing semantic assertions**

Create a state matrix covering Waiting, Inspecting, Transitioning, Active, ActivePaused, Suppressed, Recovered, and Error. Assert exact property names and representative behavior:

```powershell
$waiting=Get-CcodTrayPresentation -SessionState Waiting -AutomationEnabled $true -CandidateCompatibleOptIn $false -HasOrdinary $true -ControllerRunning $false -StateDamageBlocksActions $false -HasActiveTransaction $false
Assert-CcodEqual 'Gray' $waiting.Color 'waiting color'
Assert-CcodEqual 'Waiting' $waiting.StateKey 'waiting localization key suffix'
Assert-CcodEqual $true $waiting.ApplyNowVisible 'waiting permits explicit check'
Assert-CcodEqual $false $waiting.ManualRetryVisible 'retry hidden without a failed attempt'
Assert-CcodEqual $false $waiting.Busy 'waiting is idle'

$active=Get-CcodTrayPresentation -SessionState Active -AutomationEnabled $true -CandidateCompatibleOptIn $false -HasOrdinary $false -ControllerRunning $false -StateDamageBlocksActions $false -HasActiveTransaction $false
Assert-CcodEqual 'Green' $active.Color 'active color'
Assert-CcodEqual 'Active' $active.StateKey 'active key suffix'
Assert-CcodEqual $true $active.SessionReadyVisible 'ready row shown'
Assert-CcodEqual $false $active.ApplyNowVisible 'irrelevant action hidden'

$error=Get-CcodTrayPresentation -SessionState Error -AutomationEnabled $true -CandidateCompatibleOptIn $false -HasOrdinary $true -ControllerRunning $false -StateDamageBlocksActions $false -HasActiveTransaction $false
Assert-CcodEqual 'Red' $error.Color 'error color'
Assert-CcodEqual 'Error' $error.StateKey 'error key suffix'
Assert-CcodEqual $true $error.ManualRetryVisible 'failed repair can be retried'
Assert-CcodEqual $true $error.OpenLogsEnabled 'logs remain reachable'
```

Assert every state has only a known `StateKey`, only Gray/Green/Yellow/Red, all Boolean fields are actual Booleans, transition states disable mutating actions, and safety suppression never becomes actionable through presentation logic.

- [ ] **Step 2: Run the engine test and verify the red state**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/SupervisorEngine.SelfTest.ps1
```

Expected: FAIL because the current engine emits `Tooltip` and `StatusText` and lacks the new semantic visibility fields.

- [ ] **Step 3: Implement the semantic projection**

Keep controller/state evaluation unchanged. Replace only the final tray projection with an ordered object. Use one closed state table and reject an unrecognized internal state with `CCOD_TRAY_PRESENTATION_INVALID`:

```powershell
$presentation=[pscustomobject][ordered]@{
  Color=$color
  StateKey=$stateKey
  SessionReadyVisible=[bool]$sessionReadyVisible
  ApplyNowVisible=[bool]$applyNowVisible
  ApplyNowEnabled=[bool]$applyNowEnabled
  ManualRetryVisible=[bool]$manualRetryVisible
  ManualRetryEnabled=[bool]$manualRetryEnabled
  AutomationToggleEnabled=[bool]$automationToggleEnabled
  AutomationChecked=[bool]$HostState.AutomationEnabled
  CandidateOptInToggleEnabled=[bool]$candidateToggleEnabled
  CandidateOptInChecked=[bool]$HostState.CandidateCompatibleOptIn
  OpenLogsEnabled=$true
  UninstallEnabled=(-not $busy)
  Busy=[bool]$busy
}
```

Do not add catalog access to `SupervisorEngine.psm1`; this module must stay locale-neutral and testable without WinForms or resources.

- [ ] **Step 4: Run tests and commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/SupervisorEngine.SelfTest.ps1
git add src/persistence/modules/SupervisorEngine.psm1 tests/persistence/SupervisorEngine.SelfTest.ps1
git commit -m "refactor: make tray presentation semantic"
```

Expected: all engine state-matrix tests PASS.

---

### Task 4: Connection-Bridge Status Icon

**Files:**
- Modify: `src/persistence/modules/TrayUi.psm1`
- Modify: `tests/persistence/TrayUi.SelfTest.ps1`

**Adapter change:** rename the exact adapter `DrawIconCircle(Bitmap,Color,Size)` to `DrawBridgeIcon(Bitmap,Color,Size)`. Preserve the existing `CreateBitmap → Draw → GetHicon → CloneIcon → DestroyIcon` ownership pipeline and the eight cached icon clones (`4 colors × 2 sizes`).

- [ ] **Step 1: Write failing icon contract and pixel tests**

Keep fake-first unit tests and add one production-adapter pixel test per status:

```powershell
$production=& (Get-Module TrayUi) { Get-CcodTrayDefaultAdapters }
foreach($color in @('Gray','Green','Yellow','Red')){
  foreach($size in @(16,32)){
    $bitmap=& $production.CreateBitmap $color $size
    try{
      & $production.DrawBridgeIcon $bitmap $color $size
      Assert-CcodEqual $size $bitmap.Width "$color $size width"
      Assert-CcodEqual $size $bitmap.Height "$color $size height"
      Assert-CcodTrue (Test-CcodOpaquePixels -Bitmap $bitmap -Region 'base') "$color $size has dark rounded base"
      Assert-CcodTrue (Test-CcodLightPixels -Bitmap $bitmap -Region 'links') "$color $size has visible bridge links"
      Assert-CcodTrue (Test-CcodStatusPixels -Bitmap $bitmap -Region 'dot' -Color $color) "$color $size has correct status dot"
      Assert-CcodTrue (Test-CcodTransparentCorners -Bitmap $bitmap) "$color $size corners are transparent"
    } finally {& $production.DisposeIconResource $bitmap}
  }
}
```

Keep the existing fake-adapter assertions that context creation paints exactly eight bitmaps, destroys every temporary HICON immediately, caches exact keys `Gray:16,Gray:32,Green:16,Green:32,Yellow:16,Yellow:32,Red:16,Red:32`, and disposes every cached clone exactly once. Assert presentation changes allocate no icon resources and an invalid color is rejected before NotifyIcon mutation.

- [ ] **Step 2: Run tray tests and verify the red state**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayUi.SelfTest.ps1
```

Expected: FAIL because `DrawBridgeIcon` is absent and the production adapter draws a plain circle.

- [ ] **Step 3: Draw the approved bridge icon in code**

The existing production adapter creates the transparent ARGB bitmap at the requested size. In `DrawBridgeIcon`, scale all geometry from the `Size` argument and use pixel-aligned coordinates appropriate to both 16×16 and 32×32:

```powershell
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([Drawing.Color]::Transparent)
$basePath=[Drawing.Drawing2D.GraphicsPath]::new()
```

Draw a dark rounded-square base inside `(2,2,28,28)`, two interlocking white bridge links centered in the tile, and one 7px status dot at the lower-right with a dark 1px outline. Use this exact palette:

```powershell
$palette=@{
  Gray   =[Drawing.Color]::FromArgb(255,138,144,153)
  Green  =[Drawing.Color]::FromArgb(255,41,179,111)
  Yellow =[Drawing.Color]::FromArgb(255,227,160,8)
  Red    =[Drawing.Color]::FromArgb(255,217,74,74)
}
```

Use base `#20252D`, white links, and a white-outlined status dot. Dispose graphics/path/pen/brush objects inside the draw adapter. Preserve the current outer pipeline that converts each bitmap with `GetHicon`, clones the icon, destroys the native handle in `finally`, disposes the bitmap, and owns all eight clones until context close.

- [ ] **Step 4: Run tests and commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayUi.SelfTest.ps1
git add src/persistence/modules/TrayUi.psm1 tests/persistence/TrayUi.SelfTest.ps1
git commit -m "feat: draw connection bridge tray icon"
```

Expected: fake ownership tests and all four production pixel tests PASS.

---

### Task 5: Localized Native Menu and Live Language Switching

**Files:**
- Modify: `src/persistence/modules/TrayUi.psm1`
- Modify: `src/persistence/Supervisor.ps1`
- Modify: `tests/persistence/TrayUi.SelfTest.ps1`
- Modify: `tests/persistence/Supervisor.SelfTest.ps1`

**Tray context contract:**
- `Rows`: `Title`, `Status`
- `Items`: `SessionReady`, `ApplyNow`, `ManualRetry`, `SetAutomationEnabled`, `SetCandidateCompatibleOptIn`, `Language`, `OpenLogs`, `Uninstall`
- `LanguageItems`: `System`, `zh-CN`, `en-US`
- `Separators`: `Status`, `Preferences`, `Danger`
- `TitleImage`: one owned bitmap cloned from the cached 16px bridge icon and disposed exactly once on context close.

**Supervisor additions:**
- command `{Kind='SetUiLanguage'; Value='System'|'zh-CN'|'en-US'; EnqueuedAtUtc=<canonical UTC>}`
- host fields `UiLanguageMode` and `UiCatalog`
- new adapters `ReadUiPreference`, `SetUiLanguageMode`, `GetSystemCultureName`, `GetUiCatalog`, and `ShowTrayError`
- updated adapter signatures `NewTray(Queue,OnTick,Catalog,LanguageMode,SystemCultureName)` and `SetTrayPresentation(Tray,Presentation,Catalog,LanguageMode,SystemCultureName)`

**Tray error surface:** `Show-CcodTrayError -Context <open-context> -Catalog <validated-catalog> -Key <Error.LanguageChange|Error.UninstallStart>` displays one localized, non-sensitive native error dialog on the owning STA thread and returns no output.

- [ ] **Step 1: Write failing menu-structure and localization tests**

Build contexts with fake ToolStrip objects and both real catalogs. Assert exact map keys, native type boundaries, grouping, visibility, enabled/checked state, and immediate text changes:

```powershell
$expectedExports='Close-CcodTrayContext,New-CcodTrayContext,Set-CcodTrayPresentation,Show-CcodTrayError,Start-CcodProcessWatcher,Stop-CcodProcessWatcher'
Assert-CcodEqual $expectedExports (((Get-Command -Module TrayUi).Name|Sort-Object)-join ',') 'exact public tray surface'
$context=New-CcodTrayContext -CommandQueue $queue -OnTick {} -Catalog $zh -LanguageMode System -SystemCultureName zh-CN -Adapters $fake
Set-CcodTrayPresentation -Context $context -Presentation $active -Catalog $zh -LanguageMode System -SystemCultureName zh-CN
Assert-CcodEqual 'Title,Status' (($context.Rows.Keys)-join ',') 'exact row map'
Assert-CcodEqual 'SessionReady,ApplyNow,ManualRetry,SetAutomationEnabled,SetCandidateCompatibleOptIn,Language,OpenLogs,Uninstall' (($context.Items.Keys)-join ',') 'exact item map'
Assert-CcodEqual 'System,zh-CN,en-US' (($context.LanguageItems.Keys)-join ',') 'exact language map'
Assert-CcodEqual 'Status,Preferences,Danger' (($context.Separators.Keys)-join ',') 'exact separator map'
Assert-CcodEqual '语言 / Language' $context.Items.Language.Text 'language root remains discoverable'
Assert-CcodEqual $true $context.Rows.Title.Properties.Font.Bold 'title is visually distinct'
Assert-CcodTrue ($null -ne $context.Rows.Title.Properties.Image) 'title carries connection-bridge image'
Assert-CcodEqual $true $context.Items.SessionReady.Visible 'active session row visible'
Assert-CcodEqual $false $context.Items.ApplyNow.Visible 'irrelevant action hidden'
```

Invoke each language child click and assert exactly one no-output queued command with a case-exact enum. Call the presentation updater with the English catalog and assert every visible tray/menu/tooltip string changes without recreating `NotifyIcon`, `ContextMenuStrip`, title image, cached icons, or the queue. Extend cleanup/failure-injection tests to prove the title image and bold font are disposed exactly once without weakening cleanup continuation.

- [ ] **Step 2: Write failing Supervisor command tests**

```powershell
$command=[pscustomobject][ordered]@{Kind='SetUiLanguage';Value='en-US';EnqueuedAtUtc='2026-08-05T00:00:00.0000000Z'}
Invoke-CcodSupervisorCommand -Command $command -HostState $host -Adapters $fake
Assert-CcodEqual 'en-US' $host.UiLanguageMode 'mode changes after persistence'
Assert-CcodEqual 'en-US' $host.UiCatalog.EffectiveLocale 'catalog refreshes immediately'
Assert-CcodEqual 1 $calls.SetUiLanguageMode 'one atomic write'
```

Prove `system`, `zh-cn`, unknown locale, missing value, extra fields, and non-string values are rejected before persistence. Prove a write/catalog failure retains the old host mode/catalog, logs a stable English error code, shows `Error.LanguageChange` through the existing catalog, and keeps Supervisor/Codex running. Error-dialog failure itself must be contained and logged without changing controller state.

- [ ] **Step 3: Run focused tests and verify the red state**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayUi.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
```

Expected: FAIL because the menu is flat English, localization arguments are absent, and `SetUiLanguage` is not accepted.

- [ ] **Step 4: Build the native grouped menu**

Update adapter/context validators first. Create the menu in this order:

```text
Title (disabled)
Status (disabled)
--- Status
SessionReady OR ApplyNow OR ManualRetry (context dependent)
--- Preferences
SetAutomationEnabled (check-on-click disabled; Supervisor owns truth)
SetCandidateCompatibleOptIn (check-on-click disabled; Supervisor owns truth)
Language / 语言 > System, 中文, English
OpenLogs
--- Danger
Uninstall
```

All click handlers call the existing bounded enqueue helper and return no pipeline output. Extend `Invoke-CcodTrayCommandCallback` with an optional, case-exact explicit value used only by the three language children; existing toggle callbacks continue reading one Boolean `Checked` value from the sender. Every queued object keeps the exact ordered fields `Kind,Value,EnqueuedAtUtc`. `Set-CcodTrayPresentation` accepts `Presentation`, `Catalog`, `LanguageMode`, and `SystemCultureName`; it resolves `Status.<StateKey>` and `Tooltip.<StateKey>`, localizes every menu item, applies all semantic visibility/enabled/checked fields, and sets exactly one language child checked.

Add a narrowly scoped `CloneIconBitmap(Icon)` adapter for the title image and a `CreateBoldFont(Font)` adapter for the title font. Validate their outputs as owned resources during context construction; attach them through ordinary native properties; dispose them in the existing best-effort cleanup sequence. Do not share an owned bitmap/font across contexts.

Add `ShowErrorDialog(Title,Message)` to the exact adapter set. The production adapter uses a native `MessageBox` with `OK` and `Error`; `Show-CcodTrayError` validates the context, STA thread, catalog, and allow-listed key before invoking it:

```powershell
[Windows.Forms.MessageBox]::Show(
  $Message,$Title,
  [Windows.Forms.MessageBoxButtons]::OK,
  [Windows.Forms.MessageBoxIcon]::Error
) | Out-Null
```

- [ ] **Step 5: Integrate localization and preference state in Supervisor**

Import `UiLocalization.psm1` and `UiPreferences.psm1`. Resolve initial state before tray creation:

```powershell
$preference=& $adapters.ReadUiPreference $stateRoot
$cultureName=& $adapters.GetSystemCultureName
$catalog=& $adapters.GetUiCatalog $resourcesRoot $preference.LanguageMode $cultureName
$hostState.UiLanguageMode=$preference.LanguageMode
$hostState.UiCatalog=$catalog
```

Add the two fields to `New-CcodSupervisorHostState` in exact order after `Tray`. Pass the validated catalog/mode/culture through the updated `NewTray` adapter. Replace the package/runtime prose arguments to `SetTrayPresentation` with catalog/mode/culture; version details remain available through logs.

Handle `SetUiLanguage` transactionally:

```powershell
$oldMode=$HostState.UiLanguageMode
$oldCatalog=$HostState.UiCatalog
try{
  Assert-CcodUiLanguageCommand $Command
  $newCatalog=& $Adapters.GetUiCatalog $resourcesRoot $Command.Value (& $Adapters.GetSystemCultureName)
  & $Adapters.SetUiLanguageMode $stateRoot $Command.Value | Out-Null
  $HostState.UiLanguageMode=$Command.Value
  $HostState.UiCatalog=$newCatalog
}catch{
  $HostState.UiLanguageMode=$oldMode
  $HostState.UiCatalog=$oldCatalog
  Write-CcodSupervisorUiFailure -HostState $HostState -Adapters $Adapters -Stage 'LanguageChange' -Code 'CCOD_UI_LANGUAGE_CHANGE_FAILED'
  try { Invoke-CcodSupervisorAdapter $Adapters.ShowTrayError @($HostState.Tray,$oldCatalog,'Error.LanguageChange') 0 } catch { Write-CcodSupervisorUiFailure -HostState $HostState -Adapters $Adapters -Stage 'ErrorDialog' -Code 'CCOD_UI_ERROR_DIALOG_FAILED' }
}
```

Refresh the existing tray context only after both catalog validation and atomic persistence succeed. Catalog validation happens before persistence, so either failure leaves both the in-memory locale and stored preference unchanged. Do not restart Supervisor or Codex.

Implement private `Write-CcodSupervisorUiFailure` to emit only the existing bounded record shape `{schemaVersion,timestampUtc,component,stage,code,outcome}` through `WriteLog`; never serialize raw exception text, paths, catalog strings, or user input. Logging failure is contained with the existing `CCOD_SUPERVISOR_LOG_FAILED` cleanup code.

- [ ] **Step 6: Run tests and commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayUi.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
git add src/persistence/modules/TrayUi.psm1 src/persistence/Supervisor.ps1 tests/persistence/TrayUi.SelfTest.ps1 tests/persistence/Supervisor.SelfTest.ps1
git commit -m "feat: add bilingual context-aware tray menu"
```

Expected: both suites PASS, including immediate language switching and no-restart regression tests.

---

### Task 6: Install, Upgrade, and Runtime Manifest Integration

**Files:**
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`

**Required behavior:**
- Stage both resource JSON files and every new module into the immutable runtime; the existing hash manifest covers them.
- First install creates `state\ui-preferences.json` with `System`.
- Upgrade and `RepairState` preserve an existing valid or malformed UI preference byte-for-byte because it is non-safety state.
- A legacy installation with no UI preference remains absent during upgrade, safely follows Windows, and creates the file on the user's first explicit language selection.

- [ ] **Step 1: Write failing lifecycle tests**

Extend first-install assertions:

```powershell
$stateRoot=Join-Path $installRoot 'state'
$preference=Read-CcodUiPreference -StateRoot $stateRoot
Assert-CcodEqual 'System' $preference.LanguageMode 'first install follows Windows'
Assert-CcodEqual $false $preference.FallbackUsed 'first install persisted preference'
$runtimeRoot=Join-Path $installRoot "runtime\$($receipt.RuntimeId)"
Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $runtimeRoot 'src\persistence\resources\ui.en-US.json') -PathType Leaf) 'English catalog staged'
Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $runtimeRoot 'src\persistence\resources\ui.zh-CN.json') -PathType Leaf) 'Chinese catalog staged'
```

Before a second upgrade, persist `en-US`, save the preference bytes, upgrade, and assert the bytes and mode are unchanged. Add a malformed-byte fixture and run both ordinary upgrade and `RepairState`; assert neither rewrites the file nor reports safety-state damage. Add missing-resource and resource-reparse fixtures that fail with stable lifecycle error IDs before activation.

- [ ] **Step 2: Run lifecycle tests and verify the red state**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstallLifecycle.SelfTest.ps1
```

Expected: FAIL because resources are not staged and first install does not initialize UI preference.

- [ ] **Step 3: Stage the exact resource set under current containment rules**

After collecting `.psm1` modules, add the resource directory to the source inventory:

```powershell
$resourcesRoot=Join-Path $root 'src\persistence\resources'
if(-not [IO.Directory]::Exists($resourcesRoot)){
  Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'UI resource directory is missing.' $resourcesRoot
}
if(Test-CcodLifecycleReparse -Path $resourcesRoot){
  Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'UI resource directory is a reparse point.' $resourcesRoot
}
$resourceNames=[Collections.Generic.List[string]]::new()
foreach($resource in Get-ChildItem -LiteralPath $resourcesRoot -Filter 'ui.*.json' -File -ErrorAction Stop){
  if(Test-CcodLifecycleReparse -Path $resource.FullName){
    Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'UI resource is a reparse point.' $resource.FullName
  }
  $resourceNames.Add($resource.Name)
  $relative.Add(('src\persistence\resources\'+$resource.Name))
}
$expectedResources=@('ui.en-US.json','ui.zh-CN.json')
if((@($resourceNames|Sort-Object)-join ',') -cne (@($expectedResources|Sort-Object)-join ',')){
  Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'The UI resource set is incomplete or contains unknown files.' $resourcesRoot
}
```

Run every new relative path through the lifecycle's existing source containment, destination containment, reparse rejection, staging copy, SHA-256 comparison, and manifest generation. Do not introduce a resource-specific trust path.

- [ ] **Step 4: Initialize preference only on first install**

Import `UiPreferences.psm1`. Immediately after `Initialize-CcodState` on the non-upgrade path:

```powershell
Initialize-CcodUiPreference -StateRoot $stateRoot | Out-Null
```

Do not call it on upgrade or repair. Do not add `ui-preferences.json` to safety-state repair, quarantine, or corruption blocking logic.

- [ ] **Step 5: Run lifecycle and manifest tests, then commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/RuntimeManifest.SelfTest.ps1
git add src/persistence/modules/InstallLifecycle.psm1 tests/persistence/InstallLifecycle.SelfTest.ps1
git commit -m "feat: install UI resources and language preference"
```

Expected: first install, upgrade, repair, reparse rejection, resource hashing, and preference preservation tests PASS.

---

### Task 7: Confirmed Safe Uninstall from the Tray

**Files:**
- Create: `src/persistence/modules/UiActions.psm1`
- Create: `tests/persistence/UiActions.SelfTest.ps1`
- Modify: `src/persistence/modules/TrayUi.psm1`
- Modify: `src/persistence/Supervisor.ps1`
- Modify: `tests/persistence/TrayUi.SelfTest.ps1`
- Modify: `tests/persistence/Supervisor.SelfTest.ps1`

**Public interface:**
- `Start-CcodTrayUninstall -InstallRoot <absolute> -RuntimeRoot <absolute> -PowerShellPath <absolute>` returns exact `{Started, Pid, CreationTimeUtc}`.
- Tray adapter `ConfirmUninstall(Title,Message)` returns one Boolean.
- Supervisor adapter `StartUninstall(InstallRoot,RuntimeRoot,PowerShellPath)` returns the strict receipt.

- [ ] **Step 1: Write failing launcher safety tests**

Use fake process and filesystem adapters. Prove:

```powershell
$receipt=Start-CcodTrayUninstall -InstallRoot $installRoot -RuntimeRoot $runtimeRoot -PowerShellPath $pwsh -Adapters $fake
Assert-CcodEqual 'Started,Pid,CreationTimeUtc' (($receipt.PSObject.Properties.Name)-join ',') 'exact receipt'
Assert-CcodEqual $pwsh $calls.FilePath 'approved host executable'
Assert-CcodEqual '-NoProfile' $calls.Arguments[0] 'profile disabled'
Assert-CcodEqual '-ExecutionPolicy' $calls.Arguments[1] 'policy switch'
Assert-CcodEqual 'Bypass' $calls.Arguments[2] 'policy value'
Assert-CcodEqual '-File' $calls.Arguments[3] 'script switch'
Assert-CcodEqual $runtimeUninstaller $calls.Arguments[4] 'manifest-bound uninstaller'
Assert-CcodEqual '-InstallRoot' $calls.Arguments[5] 'root switch'
Assert-CcodEqual $installRoot $calls.Arguments[6] 'exact install root'
Assert-CcodEqual '-Confirm:$false' $calls.Arguments[7] 'second prompt suppressed after tray confirmation'
```

Reject a missing runtime manifest, inactive/mismatched runtime, unhashed uninstaller, manifest mismatch, reparse point, escaped path, wrong host path, extra arguments, malformed process receipt, and launch failure with stable error IDs. Tests must prove no process starts before all verification completes.

- [ ] **Step 2: Write failing confirmation and routing tests**

In Tray UI tests, click `Uninstall` twice with `ConfirmUninstall` returning false then true. Assert cancel queues nothing and confirmation queues exactly one ordered `{Kind='Uninstall';Value=$null;EnqueuedAtUtc=<canonical UTC>}`. Assert the localized title/message are passed to the adapter and the default production dialog is `YesNo`, `Warning`, default button `No`.

In Supervisor tests, prove `Uninstall` calls `StartUninstall` once and does not directly set `ShutdownRequested` or call `RequestUiExit`; the existing uninstaller owns normalization, task removal, shutdown signaling, wait, and cleanup order. Prove launch failure logs `CCOD_UNINSTALL_START_FAILED`, calls `ShowTrayError` with `Error.UninstallStart`, leaves Supervisor/current Codex alive, and keeps the tray usable. A dialog failure is separately contained as `CCOD_UI_ERROR_DIALOG_FAILED`.

- [ ] **Step 3: Run focused tests and verify the red state**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/UiActions.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayUi.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
```

Expected: FAIL because `UiActions.psm1` is absent, confirmation is absent, and Supervisor currently treats `Uninstall` as a no-op.

- [ ] **Step 4: Implement the isolated verified launcher**

`UiActions.psm1` imports `PersistenceIO.psm1` and `RuntimeManifest.psm1` and is the only new module allowed to start the uninstaller. Use an adapter resolver with exact keys `ReadActiveRuntime`, `ValidateRuntimeManifest`, `GetItem`, and `StartProcess`.

```powershell
function Start-CcodTrayUninstall {
  [CmdletBinding()]param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$PowerShellPath,
    [hashtable]$Adapters
  )
  $resolved=Get-CcodUiActionAdapters $Adapters
  $scriptPath=Resolve-CcodVerifiedRuntimeUninstaller -RuntimeRoot $RuntimeRoot -Adapters $resolved
  $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-InstallRoot',$InstallRoot,'-Confirm:$false')
  $started=& $resolved.StartProcess $PowerShellPath $arguments
  Assert-CcodStartedProcessReceipt $started
  [pscustomobject][ordered]@{Started=$true;Pid=[int]$started.Pid;CreationTimeUtc=[string]$started.CreationTimeUtc}
}

Export-ModuleMember -Function Start-CcodTrayUninstall
```

The module passes a `string[]` argument vector to its `StartProcess` adapter and never interpolates user-controlled values into PowerShell source. The Windows PowerShell 5.1 production adapter must encode each vector element with a local Windows command-line quoting routine equivalent to the repository's `ConvertTo-CcodManagedArgument`, join only those individually encoded arguments into `ProcessStartInfo.Arguments`, set `UseShellExecute=$false`, `CreateNoWindow=$true`, and `WindowStyle=Hidden`, then call `[Diagnostics.Process]::Start`. It returns exact `{Pid,CreationTimeUtc}` and disposes the temporary `Process` handle in `finally` after reading identity. Test paths containing spaces, quotes, and trailing backslashes against the quoting routine. Require `RuntimeRoot` to equal `InstallRoot\runtime\<activeRuntime>` from `Read-CcodActiveRuntime`, verify the full runtime with `Test-CcodRuntimeManifest`, require its validated `Manifest.files` to contain exact path `Uninstall-CodexControlOtherDevices.ps1`, resolve that path beneath the runtime with `Resolve-CcodContainedPath`, and reject a reparse point before launch. Do not use the mutable stable-root copy for tray uninstall.

- [ ] **Step 5: Add localized confirmation and Supervisor routing**

The production `ConfirmUninstall` adapter calls:

```powershell
[Windows.Forms.MessageBox]::Show(
  $Message,$Title,
  [Windows.Forms.MessageBoxButtons]::YesNo,
  [Windows.Forms.MessageBoxIcon]::Warning,
  [Windows.Forms.MessageBoxDefaultButton]::Button2
) -eq [Windows.Forms.DialogResult]::Yes
```

The tray click callback only enqueues after confirmation. Import `UiActions.psm1` in Supervisor, add `StartUninstall` to the exact adapter set, and replace the no-op branch with one verified launch. On success, return to the UI loop and let the existing uninstaller normalize a special Codex session, remove the scheduled task, signal/wait the Supervisor, preserve device keys by default, and remove persistence/runtime artifacts in its established order. On failure, log the stable English error and invoke `ShowTrayError(HostState.Tray,HostState.UiCatalog,'Error.UninstallStart')` inside its own containment block.

- [ ] **Step 6: Run tests and commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/UiActions.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayUi.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
git add src/persistence/modules/UiActions.psm1 src/persistence/modules/TrayUi.psm1 src/persistence/Supervisor.ps1 tests/persistence/UiActions.SelfTest.ps1 tests/persistence/TrayUi.SelfTest.ps1 tests/persistence/Supervisor.SelfTest.ps1
git commit -m "feat: confirm and launch safe tray uninstall"
```

Expected: launcher, confirmation, failure-containment, and orderly-exit tests PASS.

---

### Task 8: Documentation, Full Validation, and Installed Acceptance

**Files:**
- Create: `tests/manual/Show-TrayUiGallery.ps1`
- Create: `docs/assets/tray-menu-zh-CN.png`
- Create: `docs/assets/tray-menu-en-US.png`
- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `docs/TECHNICAL.md`

- [ ] **Step 1: Create a manual gallery before touching the live installation**

The gallery imports the production localization and Tray UI modules, creates one temporary NotifyIcon/context menu, and cycles these fixtures without inspecting, stopping, or launching Codex:

```powershell
$states=@(
  [pscustomobject]@{Color='Gray';StateKey='Waiting'},
  [pscustomobject]@{Color='Green';StateKey='Active'},
  [pscustomobject]@{Color='Yellow';StateKey='Suppressed'},
  [pscustomobject]@{Color='Red';StateKey='Error'}
)
foreach($locale in @('zh-CN','en-US')){
  $catalog=Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode $locale -SystemCultureName zh-CN
  foreach($state in $states){Show-CcodGalleryState -Context $context -State $state -Catalog $catalog}
}
```

Add `-Locale`, `-State`, and `-DurationSeconds` parameters with strict ValidateSet values. Ensure `finally` disposes the context, NotifyIcon, menu, and all generated icons. The script must print a warning that it is visual-only and never writes preference/safety state.

- [ ] **Step 2: Update Chinese and English README files symmetrically**

Document:
- the connection-bridge status colors and meanings;
- context-aware action visibility;
- `System`/中文/English selection and immediate switching;
- preference path and non-safety fallback behavior;
- confirmed uninstall behavior and device-key retention;
- gallery command and screenshots;
- rollback/uninstall commands already supported by the project.

Keep headings and facts aligned between `README.md` and `README.en.md`; do not machine-translate command names, file paths, log codes, or JSON.

- [ ] **Step 3: Update technical architecture documentation**

In `docs/TECHNICAL.md`, add exact catalog schema/key validation, locale resolution table, `ui-preferences.json` schema, component ownership, semantic presentation fields, live-language command flow, icon disposal, manifest inclusion, and verified uninstall launch sequence. Explicitly state that UI preference corruption cannot block compatibility actions.

- [ ] **Step 4: Run the complete repository validation**

```powershell
npm test
git diff --check
git status --short
```

Expected: every self-test collected by `tests/Validate.ps1` passes, diff check is silent, and only intended documentation/gallery changes remain before commit.

- [ ] **Step 5: Upgrade the installed supervisor and run live acceptance**

Use the repository's documented upgrade entry point. Do not manually copy into the active immutable runtime. Verify in order:

1. Scheduled task and tray Supervisor start normally; no duplicate tray process appears.
2. On the current Chinese Windows installation, `System` displays Chinese with the bilingual language root.
3. Choose `语言 / Language → English`; menu and tooltip change immediately, without restarting Supervisor or Codex.
4. Restart only Supervisor; English remains selected.
5. Choose `Language / 语言 → 中文`; Chinese appears immediately.
6. Choose `语言 / Language → 跟随系统（中文）`; `state\ui-preferences.json` contains `languageMode: System`.
7. Exercise Waiting, Active, Suppressed, and a synthetic/manual gallery Error state; status dot and menu actions match the semantic state.
8. Cancel uninstall once and verify no state changes; do not confirm live uninstall unless the user explicitly requests actual removal.
9. Inspect the 16px tray icon and native menu on light and dark taskbars, at 100% and one high-DPI scale, and with Windows high-contrast mode; verify the bridge outline, status dot, focus, checkmarks, and text remain legible.
10. Capture the real native menu as `docs/assets/tray-menu-zh-CN.png` and `docs/assets/tray-menu-en-US.png`; inspect both images before linking them from the corresponding README.

- [ ] **Step 6: Finalize and commit documentation, gallery, and screenshots**

```powershell
git add tests/manual/Show-TrayUiGallery.ps1 docs/assets/tray-menu-zh-CN.png docs/assets/tray-menu-en-US.png README.md README.en.md docs/TECHNICAL.md
git commit -m "docs: document bilingual tray supervisor UI"
```

- [ ] **Step 7: Final evidence and branch review**

```powershell
npm test
git log --oneline --decorate -10
git status --short --branch
```

Expected: tests PASS; commits are ordered catalog → preference → semantic presentation → icon → menu → lifecycle → uninstall → docs; worktree is clean; installed Supervisor and current Codex session remain healthy.

<!-- END OF PLAN -->
