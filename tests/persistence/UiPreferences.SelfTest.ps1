$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$persistenceModulePath = Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1'
$modulePath = Join-Path $repositoryRoot 'src\persistence\modules\UiPreferences.psm1'
if (-not [IO.File]::Exists($modulePath)) { throw 'MISSING_UI_PREFERENCES_MODULE: src\persistence\modules\UiPreferences.psm1' }
Import-Module $persistenceModulePath -Force
Import-Module $modulePath -Force

function New-CcodUiPreferenceFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-ui-preferences-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    return $root
}

function Write-CcodUiPreferenceFixture {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][string]$Text)

    [IO.File]::WriteAllText((Join-Path $StateRoot 'ui-preferences.json'), $Text, [Text.UTF8Encoding]::new($false))
}

function Get-CcodUiPreferenceBytes {
    param([Parameter(Mandatory)][string]$StateRoot)

    return [IO.File]::ReadAllBytes((Join-Path $StateRoot 'ui-preferences.json'))
}

$results = [Collections.Generic.List[object]]::new()
$stateRoot = New-CcodUiPreferenceFixture
$outsideRoot = New-CcodUiPreferenceFixture
try {
    $results.Add((Invoke-CcodTest 'defaults missing preferences with an observable stable fallback' {
        $missing = Read-CcodUiPreference -StateRoot $stateRoot
        Assert-CcodEqual 'LanguageMode,FallbackUsed,ErrorCode' (($missing.PSObject.Properties.Name) -join ',') 'missing result has exact ordered fields'
        Assert-CcodEqual 'System' $missing.LanguageMode 'missing defaults to System'
        Assert-CcodEqual $true $missing.FallbackUsed 'missing fallback is observable'
        Assert-CcodEqual 'CCOD_UI_PREFERENCES_MISSING' $missing.ErrorCode 'missing uses a stable error code'
    }))

    $results.Add((Invoke-CcodTest 'treats malformed preferences as an observable safe fallback' {
        Write-CcodUiPreferenceFixture -StateRoot $stateRoot -Text '{bad'
        $invalid = Read-CcodUiPreference -StateRoot $stateRoot
        Assert-CcodEqual 'LanguageMode,FallbackUsed,ErrorCode' (($invalid.PSObject.Properties.Name) -join ',') 'invalid result has exact ordered fields'
        Assert-CcodEqual 'System' $invalid.LanguageMode 'malformed defaults to System'
        Assert-CcodEqual $true $invalid.FallbackUsed 'malformed fallback is observable'
        Assert-CcodEqual 'CCOD_UI_PREFERENCES_INVALID' $invalid.ErrorCode 'malformed uses a stable error code'
    }))

    $results.Add((Invoke-CcodTest 'persists an exact ordered schema with an injected canonical UTC timestamp' {
        $receipt = Set-CcodUiLanguageMode -StateRoot $stateRoot -LanguageMode zh-CN -Adapters @{ UtcNow = { [datetimeoffset]'2026-08-05T00:00:00Z' } }
        Assert-CcodEqual 'LanguageMode,UpdatedAtUtc' (($receipt.PSObject.Properties.Name) -join ',') 'set receipt has exact ordered fields'
        Assert-CcodEqual 'zh-CN' $receipt.LanguageMode 'set receipt retains the requested mode'
        Assert-CcodEqual '2026-08-05T00:00:00.0000000+00:00' $receipt.UpdatedAtUtc 'set receipt normalizes to canonical UTC round-trip form'
        $raw = [IO.File]::ReadAllBytes((Join-Path $stateRoot 'ui-preferences.json'))
        Assert-CcodTrue ($raw.Length -gt 0 -and -not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)) 'preferences JSON is UTF-8 without a BOM'
        $persisted = [IO.File]::ReadAllText((Join-Path $stateRoot 'ui-preferences.json'), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        Assert-CcodEqual 'schemaVersion,languageMode,updatedAtUtc' (($persisted.PSObject.Properties.Name) -join ',') 'persisted schema has exact field order'
        Assert-CcodEqual 1 $persisted.schemaVersion 'persisted schema is version one'
        Assert-CcodEqual 'zh-CN' $persisted.languageMode 'override persists independently'
        Assert-CcodEqual '2026-08-05T00:00:00.0000000+00:00' $persisted.updatedAtUtc 'persisted timestamp is canonical'
        $read = Read-CcodUiPreference -StateRoot $stateRoot
        Assert-CcodEqual 'zh-CN' $read.LanguageMode 'override round-trips'
        Assert-CcodEqual $false $read.FallbackUsed 'valid override does not fall back'
        Assert-CcodEqual $null $read.ErrorCode 'valid override has no error code'
        $siblings = @(Get-ChildItem -LiteralPath $stateRoot -Force)
        Assert-CcodEqual 1 $siblings.Count 'atomic write leaves no temporary or backup siblings'
        Assert-CcodEqual 'ui-preferences.json' $siblings[0].Name 'atomic write leaves only the preference target'
    }))

    $results.Add((Invoke-CcodTest 'initializes System once without overwriting an existing preference' {
        $initRoot = New-CcodUiPreferenceFixture
        try {
            Initialize-CcodUiPreference -StateRoot $initRoot
            $initialized = [IO.File]::ReadAllText((Join-Path $initRoot 'ui-preferences.json'), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            Assert-CcodEqual 'schemaVersion,languageMode,updatedAtUtc' (($initialized.PSObject.Properties.Name) -join ',') 'initialized schema has exact field order'
            Assert-CcodEqual 1 $initialized.schemaVersion 'initialized schema is version one'
            Assert-CcodEqual 'System' $initialized.languageMode 'initialize writes only System'
            Assert-CcodEqual 'System' (Read-CcodUiPreference -StateRoot $initRoot).LanguageMode 'initialized value is readable'
            $before = Get-CcodUiPreferenceBytes -StateRoot $initRoot
            Assert-CcodThrows { Initialize-CcodUiPreference -StateRoot $initRoot } 'CCOD_UI_PREFERENCES_EXISTS'
            Assert-CcodEqual ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String((Get-CcodUiPreferenceBytes -StateRoot $initRoot))) 'existing preference bytes remain unchanged'
        } finally {
            if ([IO.Directory]::Exists($initRoot)) { Remove-Item -LiteralPath $initRoot -Recurse -Force }
        }
    }))

    $results.Add((Invoke-CcodTest 'surfaces a prepared-file initialization race without clobbering the competing preference' {
        $raceRoot = New-CcodUiPreferenceFixture
        $uiModule = Get-Module UiPreferences
        $winnerBytes = [Text.UTF8Encoding]::new($false).GetBytes("{`"schemaVersion`":1,`"languageMode`":`"en-US`",`"updatedAtUtc`":`"2026-08-05T00:00:00.0000000+00:00`"}`n")
        $hadWriter = & $uiModule { $null -ne (Get-Command Write-CcodAtomicJsonIfAbsent -CommandType Function -ErrorAction SilentlyContinue) }
        $originalWriter = if ($hadWriter) { & $uiModule { (Get-Command Write-CcodAtomicJsonIfAbsent -CommandType Function).ScriptBlock } } else { $null }
        $raceWriter = {
            param($Path, $Value)
            $adapters = @{
                CommitFileByHandleNoReplace = {
                    param([IO.FileStream]$Source, [string]$Destination)
                    [IO.File]::WriteAllBytes($Destination, $winnerBytes)
                    $errorCode = [CcodNativeAtomicFile]::MoveFileByHandleNoReplace($Source.SafeFileHandle, $Destination)
                    return [pscustomobject]@{ Success = ($errorCode -eq 0); ErrorCode = $errorCode }
                }
            }
            PersistenceIO\Write-CcodAtomicJsonIfAbsent -Path $Path -Value $Value -Adapters $adapters
        }.GetNewClosure()
        try {
            & $uiModule { param($Writer) Set-Item -Path Function:Write-CcodAtomicJsonIfAbsent -Value $Writer } $raceWriter
            Assert-CcodThrows { Initialize-CcodUiPreference -StateRoot $raceRoot } 'CCOD_UI_PREFERENCES_EXISTS'
            $path = Join-Path $raceRoot 'ui-preferences.json'
            Assert-CcodEqual ([Convert]::ToBase64String($winnerBytes)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) 'the initializer preserves the competing preference bytes'
            $siblings = @(Get-ChildItem -LiteralPath $raceRoot -Force)
            Assert-CcodEqual 1 $siblings.Count 'the losing initializer leaves no temporary or recovery artifact'
            Assert-CcodEqual 'ui-preferences.json' $siblings[0].Name 'the competing preference is the only state artifact'
        } finally {
            if ($hadWriter) {
                & $uiModule { param($Writer) Set-Item -Path Function:Write-CcodAtomicJsonIfAbsent -Value $Writer } $originalWriter
            } else {
                & $uiModule { Remove-Item -Path Function:Write-CcodAtomicJsonIfAbsent -ErrorAction SilentlyContinue }
            }
            if ([IO.Directory]::Exists($raceRoot)) { Remove-Item -LiteralPath $raceRoot -Recurse -Force }
        }
    }))

    $results.Add((Invoke-CcodTest 'rejects invalid language modes case-exactly before persistence' {
        foreach ($bad in @('system', 'zh-cn', 'fr-FR', '')) {
            Assert-CcodThrows { Set-CcodUiLanguageMode -StateRoot $stateRoot -LanguageMode $bad } 'CCOD_UI_LANGUAGE_INVALID'
        }
    }))

    $results.Add((Invoke-CcodTest 'rejects invalid persisted schema shapes and timestamps through the same safe fallback' {
        $invalidStores = @(
            '{"schemaVersion":1,"languageMode":"zh-CN","updatedAtUtc":"2026-08-05T00:00:00.0000000+00:00","extra":true}',
            '{"languageMode":"zh-CN","schemaVersion":1,"updatedAtUtc":"2026-08-05T00:00:00.0000000+00:00"}',
            '{"schemaVersion":"1","languageMode":"zh-CN","updatedAtUtc":"2026-08-05T00:00:00.0000000+00:00"}',
            '{"schemaVersion":1,"languageMode":"zh-cn","updatedAtUtc":"2026-08-05T00:00:00.0000000+00:00"}',
            '{"schemaVersion":1,"languageMode":"zh-CN","updatedAtUtc":"2026-08-05T08:00:00.0000000+08:00"}',
            '{"schemaVersion":1,"languageMode":"zh-CN","updatedAtUtc":"2026-08-05T00:00:00Z"}'
        )
        foreach ($store in $invalidStores) {
            Write-CcodUiPreferenceFixture -StateRoot $stateRoot -Text $store
            $invalid = Read-CcodUiPreference -StateRoot $stateRoot
            Assert-CcodEqual 'System' $invalid.LanguageMode 'invalid stored shape defaults to System'
            Assert-CcodEqual $true $invalid.FallbackUsed 'invalid stored shape reports fallback'
            Assert-CcodEqual 'CCOD_UI_PREFERENCES_INVALID' $invalid.ErrorCode 'invalid stored shape uses stable code'
        }
    }))

    $results.Add((Invoke-CcodTest 'rejects state roots reached through a reparse point' {
        $linkedRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-ui-preferences-link-' + [Guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Junction -Path $linkedRoot -Target $outsideRoot -ErrorAction Stop | Out-Null
            Assert-CcodThrows { Read-CcodUiPreference -StateRoot $linkedRoot } 'CCOD_REPARSE_PATH'
            Assert-CcodThrows { Set-CcodUiLanguageMode -StateRoot $linkedRoot -LanguageMode en-US } 'CCOD_REPARSE_PATH'
            Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $outsideRoot 'ui-preferences.json'))) 'reparse root cannot receive preference writes'
        } finally {
            if ([IO.Directory]::Exists($linkedRoot)) { [IO.Directory]::Delete($linkedRoot) }
        }
    }))

    $results.Add((Invoke-CcodTest 'never changes controller safety state while reading malformed or writing UI preferences' {
        $safetyRoot = New-CcodUiPreferenceFixture
        try {
            $settingsPath = Join-Path $safetyRoot 'settings.json'
            $statusPath = Join-Path $safetyRoot 'status.json'
            [IO.File]::WriteAllText($settingsPath, '{"schemaVersion":1,"automationEnabled":false,"candidateCompatibleOptIn":false,"nodeCandidates":[],"updatedAtUtc":"2026-08-05T00:00:00.0000000Z"}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($statusPath, '{"schemaVersion":1,"session":null}', [Text.UTF8Encoding]::new($false))
            $settingsBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsPath))
            $statusBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($statusPath))
            Write-CcodUiPreferenceFixture -StateRoot $safetyRoot -Text '{bad'
            $fallback = Read-CcodUiPreference -StateRoot $safetyRoot
            Assert-CcodEqual 'CCOD_UI_PREFERENCES_INVALID' $fallback.ErrorCode 'malformed UI preference remains isolated from safety state'
            Set-CcodUiLanguageMode -StateRoot $safetyRoot -LanguageMode en-US -Adapters @{ UtcNow = { [datetimeoffset]'2026-08-05T00:00:00Z' } } | Out-Null
            Assert-CcodEqual $settingsBefore ([Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsPath))) 'preference update leaves automation consent bytes unchanged'
            Assert-CcodEqual $statusBefore ([Convert]::ToBase64String([IO.File]::ReadAllBytes($statusPath))) 'preference update leaves controller state bytes unchanged'
        } finally {
            if ([IO.Directory]::Exists($safetyRoot)) { Remove-Item -LiteralPath $safetyRoot -Recurse -Force }
        }
    }))
} finally {
    if ([IO.Directory]::Exists($stateRoot)) { Remove-Item -LiteralPath $stateRoot -Recurse -Force }
    if ([IO.Directory]::Exists($outsideRoot)) { Remove-Item -LiteralPath $outsideRoot -Recurse -Force }
}

if ($env:CCOD_UI_PREFERENCES_SELFTEST_FORCE_FAILURE -ceq '1') { $results.Add([pscustomobject]@{ Name = 'forced failed result object'; Ok = $false }) }
foreach ($result in $results) { Write-Host $(if ($result.Ok) { 'PASS ' } else { 'FAIL ' })$result.Name }
$failed = @($results | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0) { throw ('UI_PREFERENCES_SELF_TEST_FAILED: ' + ($failed.Name -join ', ')) }
