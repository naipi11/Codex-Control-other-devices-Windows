Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -Force

function Throw-CcodStateError {
    param([string]$Id, [string]$Message, $TargetObject)

    $exception = [InvalidOperationException]::new($Message)
    $record = [Management.Automation.ErrorRecord]::new($exception, $Id, [Management.Automation.ErrorCategory]::InvalidData, $TargetObject)
    throw $record
}

function Get-CcodStateAdapters {
    param([hashtable]$Adapters)

    $result = @{
        UtcNow = { [DateTime]::UtcNow }
    }
    if ($null -ne $Adapters) {
        foreach ($key in $Adapters.Keys) { $result[$key] = $Adapters[$key] }
    }
    return $result
}

function Test-CcodStateProperty {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name)

    if ($Value -is [Collections.IDictionary]) { return $Value.Contains($Name) }
    return $null -ne $Value.PSObject.Properties[$Name]
}

function Get-CcodStatePath {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][string]$Leaf)

    return (Resolve-CcodContainedPath -Root $StateRoot -RelativePath $Leaf -AllowMissingLeaf)
}

function Get-CcodStateTimestamp {
    param([hashtable]$Adapters)

    $now = & $Adapters.UtcNow
    if ($now -isnot [DateTime]) {
        Throw-CcodStateError 'CCOD_CLOCK_INVALID' 'State clock must return a DateTime value' $now
    }
    return $now.ToUniversalTime().ToString('o')
}

function Assert-CcodAbsoluteNodeCandidates {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$NodeCandidates)

    foreach ($candidate in $NodeCandidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not [IO.Path]::IsPathRooted($candidate)) {
            Throw-CcodStateError 'CCOD_NODE_CANDIDATE_INVALID' 'Node candidates must be installer-verified absolute paths' $candidate
        }
    }
}

function New-CcodSettings {
    param(
        [string[]]$NodeCandidates,
        [bool]$CandidateCompatibleOptIn,
        [bool]$AutomationEnabled,
        [Parameter(Mandatory)][string]$UpdatedAtUtc
    )

    Assert-CcodAbsoluteNodeCandidates -NodeCandidates @($NodeCandidates)
    return [ordered]@{
        schemaVersion = 1
        automationEnabled = $AutomationEnabled
        candidateCompatibleOptIn = $CandidateCompatibleOptIn
        nodeCandidates = @($NodeCandidates)
        updatedAtUtc = $UpdatedAtUtc
    }
}

function New-CcodStatusStore {
    return [ordered]@{
        schemaVersion = 1
        session = $null
    }
}

function New-CcodVerifiedPackagesStore {
    return [ordered]@{
        schemaVersion = 1
        packages = [ordered]@{}
    }
}

function New-CcodTransitionStore {
    return [ordered]@{ schemaVersion = 1; activeTransaction = $null }
}

function Assert-CcodSettingsShape {
    param([Parameter(Mandatory)]$Settings)

    foreach ($name in @('automationEnabled', 'candidateCompatibleOptIn', 'nodeCandidates', 'updatedAtUtc')) {
        if (-not (Test-CcodStateProperty -Value $Settings -Name $name)) {
            Throw-CcodStateError 'CCOD_SETTINGS_INVALID' "Settings state is missing $name" $Settings
        }
    }
    if ($Settings.automationEnabled -isnot [bool] -or $Settings.candidateCompatibleOptIn -isnot [bool] -or
        $Settings.updatedAtUtc -isnot [string] -or [string]::IsNullOrWhiteSpace($Settings.updatedAtUtc)) {
        Throw-CcodStateError 'CCOD_SETTINGS_INVALID' 'Settings state has invalid consent or timestamp fields' $Settings
    }
    $candidates = @($Settings.nodeCandidates)
    if ($null -eq $Settings.nodeCandidates -or @($candidates | Where-Object { $_ -isnot [string] }).Count -ne 0) {
        Throw-CcodStateError 'CCOD_SETTINGS_INVALID' 'Settings node candidates must be a string array' $Settings
    }
    Assert-CcodAbsoluteNodeCandidates -NodeCandidates $candidates
}

function Assert-CcodStatusShape {
    param([Parameter(Mandatory)]$Status)

    if (-not (Test-CcodStateProperty -Value $Status -Name 'schemaVersion')) {
        Throw-CcodStateError 'CCOD_STATUS_INVALID' 'Status state is missing its schema version' $Status
    }
}

function Assert-CcodVerifiedPackagesShape {
    param([Parameter(Mandatory)]$VerifiedPackages)

    if (-not (Test-CcodStateProperty -Value $VerifiedPackages -Name 'packages')) {
        Throw-CcodStateError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package state is missing packages' $VerifiedPackages
    }
    if ($null -eq $VerifiedPackages.packages -or $VerifiedPackages.packages -is [string] -or $VerifiedPackages.packages -isnot [pscustomobject] -and $VerifiedPackages.packages -isnot [Collections.IDictionary]) {
        Throw-CcodStateError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package state packages must be an object' $VerifiedPackages
    }
}

function Assert-CcodTransitionShape {
    param([Parameter(Mandatory)]$Transition)

    if (-not (Test-CcodStateProperty -Value $Transition -Name 'activeTransaction')) {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'Transition state is missing activeTransaction' $Transition
    }
    if ($null -ne $Transition.activeTransaction -and $Transition.activeTransaction -isnot [pscustomobject]) {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'Transition activeTransaction must be null or an object' $Transition
    }
}

function Read-CcodTypedState {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][scriptblock]$Validator
    )

    $path = Get-CcodStatePath -StateRoot $StateRoot -Leaf $Leaf
    $value = Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind $Kind
    & $Validator $value
    return $value
}

function Write-CcodTypedState {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][scriptblock]$Validator
    )

    if ((-not (Test-CcodStateProperty -Value $Value -Name 'schemaVersion')) -or $Value.schemaVersion -ne 1) {
        Throw-CcodStateError 'CCOD_SCHEMA_UNSUPPORTED' 'State writes require schema version 1' $Value
    }
    & $Validator $Value
    Write-CcodAtomicJson -Path (Get-CcodStatePath -StateRoot $StateRoot -Leaf $Leaf) -Value $Value
}

function Initialize-CcodState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [string[]]$NodeCandidates = @(),
        [bool]$CandidateCompatibleOptIn = $false,
        [hashtable]$Adapters
    )

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    [IO.Directory]::CreateDirectory($StateRoot) | Out-Null
    $paths = @('settings.json', 'status.json', 'verified-packages.json', 'transition.json')
    foreach ($leaf in $paths) {
        if ([IO.File]::Exists((Get-CcodStatePath -StateRoot $StateRoot -Leaf $leaf))) {
            Throw-CcodStateError 'CCOD_STATE_ALREADY_INITIALIZED' 'State initialization refuses to overwrite existing evidence; use explicit repair' $StateRoot
        }
    }

    Write-CcodSettings -StateRoot $StateRoot -Settings (New-CcodSettings -NodeCandidates $NodeCandidates -CandidateCompatibleOptIn $CandidateCompatibleOptIn -AutomationEnabled $true -UpdatedAtUtc (Get-CcodStateTimestamp -Adapters $adapters))
    Write-CcodStatus -StateRoot $StateRoot -Status (New-CcodStatusStore) -LiveProbeResult ([pscustomobject]@{ Valid = $true })
    Write-CcodVerifiedPackages -StateRoot $StateRoot -VerifiedPackages (New-CcodVerifiedPackagesStore)
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'transition.json' -Value (New-CcodTransitionStore) -Validator ${function:Assert-CcodTransitionShape}
}

function Read-CcodSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)
    return Read-CcodTypedState -StateRoot $StateRoot -Leaf 'settings.json' -Kind 'settings' -Validator ${function:Assert-CcodSettingsShape}
}

function Write-CcodSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$Settings)
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'settings.json' -Value $Settings -Validator ${function:Assert-CcodSettingsShape}
}

function Read-CcodStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)
    return Read-CcodTypedState -StateRoot $StateRoot -Leaf 'status.json' -Kind 'status' -Validator ${function:Assert-CcodStatusShape}
}

function Write-CcodStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)]$Status,
        $LiveProbeResult
    )

    if ($null -eq $LiveProbeResult -or $null -eq $LiveProbeResult.PSObject.Properties['Valid'] -or $LiveProbeResult.Valid -ne $true) {
        Throw-CcodStateError 'CCOD_LIVE_PROBE_REQUIRED' 'Status may only be rebuilt from a supplied successful live probe result' $LiveProbeResult
    }
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'status.json' -Value $Status -Validator ${function:Assert-CcodStatusShape}
}

function Read-CcodVerifiedPackages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)
    return Read-CcodTypedState -StateRoot $StateRoot -Leaf 'verified-packages.json' -Kind 'verified packages' -Validator ${function:Assert-CcodVerifiedPackagesShape}
}

function Write-CcodVerifiedPackages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$VerifiedPackages)
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'verified-packages.json' -Value $VerifiedPackages -Validator ${function:Assert-CcodVerifiedPackagesShape}
}

function Read-CcodStatePart {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)][scriptblock]$Reader,
        [Parameter(Mandatory)][hashtable]$Adapters,
        [Parameter(Mandatory)][hashtable]$Damage
    )

    try {
        return (& $Reader)
    } catch {
        $Damage[$Leaf] = (($_.FullyQualifiedErrorId -split ',')[0])
        $path = Get-CcodStatePath -StateRoot $StateRoot -Leaf $Leaf
        if ([IO.File]::Exists($path)) {
            Move-CcodCorruptState -Path $path -Reason $Damage[$Leaf] -Root $StateRoot -Adapters $Adapters | Out-Null
        }
        return $null
    }
}

function Read-CcodState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [hashtable]$Adapters)

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    $damage = @{}
    $settings = Read-CcodStatePart -StateRoot $StateRoot -Leaf 'settings.json' -Reader { Read-CcodSettings -StateRoot $StateRoot } -Adapters $adapters -Damage $damage
    $status = Read-CcodStatePart -StateRoot $StateRoot -Leaf 'status.json' -Reader { Read-CcodStatus -StateRoot $StateRoot } -Adapters $adapters -Damage $damage
    $verified = Read-CcodStatePart -StateRoot $StateRoot -Leaf 'verified-packages.json' -Reader { Read-CcodVerifiedPackages -StateRoot $StateRoot } -Adapters $adapters -Damage $damage
    $transition = Read-CcodStatePart -StateRoot $StateRoot -Leaf 'transition.json' -Reader { Read-CcodTypedState -StateRoot $StateRoot -Leaf 'transition.json' -Kind 'transition' -Validator ${function:Assert-CcodTransitionShape} } -Adapters $adapters -Damage $damage

    $automationEnabled = $null -ne $settings -and $settings.automationEnabled -eq $true -and -not $damage.ContainsKey('transition.json')
    $statusNeedsRebuild = $null -eq $status
    $candidateTrialsAllowed = $automationEnabled -and $settings.candidateCompatibleOptIn -eq $true -and $null -ne $verified -and -not $statusNeedsRebuild
    $transitionActionsAllowed = $null -ne $transition
    return [pscustomobject]@{
        Settings = $settings
        Status = $status
        VerifiedPackages = $verified
        Transition = $transition
        AutomationEnabled = [bool]$automationEnabled
        AutomaticCandidateTrialsAllowed = [bool]$candidateTrialsAllowed
        TransitionActionsAllowed = [bool]$transitionActionsAllowed
        StatusRebuildRequired = [bool]$statusNeedsRebuild
        Damage = [pscustomobject]$damage
    }
}

function Set-CcodAutomationEnabled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][bool]$Enabled, [hashtable]$Adapters)

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    $settings = Read-CcodSettings -StateRoot $StateRoot
    Write-CcodSettings -StateRoot $StateRoot -Settings (New-CcodSettings -NodeCandidates @($settings.nodeCandidates) -CandidateCompatibleOptIn $settings.candidateCompatibleOptIn -AutomationEnabled $Enabled -UpdatedAtUtc (Get-CcodStateTimestamp -Adapters $adapters))
}

function Set-CcodCandidateCompatibleOptIn {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][bool]$Enabled, [hashtable]$Adapters)

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    $settings = Read-CcodSettings -StateRoot $StateRoot
    Write-CcodSettings -StateRoot $StateRoot -Settings (New-CcodSettings -NodeCandidates @($settings.nodeCandidates) -CandidateCompatibleOptIn $Enabled -AutomationEnabled $settings.automationEnabled -UpdatedAtUtc (Get-CcodStateTimestamp -Adapters $adapters))
}

function Repair-CcodState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [hashtable]$Adapters)

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    [IO.Directory]::CreateDirectory($StateRoot) | Out-Null
    foreach ($leaf in @('settings.json', 'status.json', 'verified-packages.json', 'transition.json')) {
        $path = Get-CcodStatePath -StateRoot $StateRoot -Leaf $leaf
        if ([IO.File]::Exists($path)) {
            Move-CcodCorruptState -Path $path -Reason 'explicit repair' -Root $StateRoot -Adapters $adapters | Out-Null
        }
    }
    Write-CcodSettings -StateRoot $StateRoot -Settings (New-CcodSettings -NodeCandidates @() -CandidateCompatibleOptIn $false -AutomationEnabled $false -UpdatedAtUtc (Get-CcodStateTimestamp -Adapters $adapters))
    Write-CcodStatus -StateRoot $StateRoot -Status (New-CcodStatusStore) -LiveProbeResult ([pscustomobject]@{ Valid = $true })
    Write-CcodVerifiedPackages -StateRoot $StateRoot -VerifiedPackages (New-CcodVerifiedPackagesStore)
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'transition.json' -Value (New-CcodTransitionStore) -Validator ${function:Assert-CcodTransitionShape}
}

function Get-CcodAttemptKey([int]$Pid, [string]$CreationTimeUtc) { '{0}|{1}' -f $Pid, $CreationTimeUtc }
function Get-CcodRecoveryIgnoreKey([int]$Pid, [string]$CreationTimeUtc, [string]$TransactionId) { '{0}|{1}|{2}' -f $Pid, $CreationTimeUtc, $TransactionId }
function Get-CcodSuppressionKey([string]$PackageFullName, [string]$AppAsarSha256, [string]$RuntimeId) { '{0}|{1}|{2}' -f $PackageFullName, $AppAsarSha256, $RuntimeId }
function Get-CcodStaticKey([string]$PackageFullName, [string]$AppAsarSha256) { '{0}|{1}' -f $PackageFullName, $AppAsarSha256 }

function Resolve-CcodDeviceKeyStorePath {
    [CmdletBinding()]
    param()

    $codexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
    if ([string]::IsNullOrWhiteSpace($codexHome)) {
        $codexHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    } elseif (-not [IO.Path]::IsPathRooted($codexHome)) {
        Throw-CcodStateError 'CCOD_CODEX_HOME_INVALID' 'CODEX_HOME must be an absolute path' $codexHome
    }
    return (Join-Path $codexHome 'remote-control-device-keys.windows.json')
}

Export-ModuleMember -Function Initialize-CcodState, Read-CcodState, Repair-CcodState, Read-CcodSettings, Write-CcodSettings, Read-CcodStatus, Write-CcodStatus, Read-CcodVerifiedPackages, Write-CcodVerifiedPackages, Set-CcodAutomationEnabled, Set-CcodCandidateCompatibleOptIn, Get-CcodAttemptKey, Get-CcodRecoveryIgnoreKey, Get-CcodSuppressionKey, Get-CcodStaticKey, Resolve-CcodDeviceKeyStorePath
