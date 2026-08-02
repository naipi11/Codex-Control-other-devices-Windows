Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -Force

$script:CcodTransitionFields = @(
    'transactionId', 'stage', 'sourcePid', 'sourceCreationTimeUtc', 'packageFullName', 'appAsarSha256', 'runtimeId',
    'mainPort', 'rendererPort', 'specialPid', 'specialCreationTimeUtc', 'recoveryPid', 'recoveryCreationTimeUtc',
    'createdAtUtc', 'updatedAtUtc'
)
$script:CcodProcessSnapshotFields = @(
    'Pid', 'CreationTimeUtc', 'SessionId', 'UserSid', 'Path', 'PackageFamilyName', 'CommandLine', 'ParentPid',
    'IsTopLevel', 'Mode', 'RendererPort', 'MainPort'
)

function Throw-CcodTransitionError {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Message, $TargetObject)

    $record = [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $TargetObject
    )
    throw $record
}

function Test-CcodJournalProperty {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name)

    if ($Value -is [Collections.IDictionary]) { return $Value.Contains($Name) }
    return $null -ne $Value.PSObject.Properties[$Name]
}

function Get-CcodJournalPropertyNames {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    return @($Value.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-CcodJournalExactProperties {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Kind,
        [string]$ErrorId = 'CCOD_TRANSITION_INVALID'
    )

    $actual = @(Get-CcodJournalPropertyNames -Value $Value | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if ($actual.Count -ne $wanted.Count -or @($actual | Where-Object { $wanted -cnotcontains $_ }).Count -ne 0) {
        Throw-CcodTransitionError $ErrorId "$Kind has unexpected or missing fields" $Value
    }
}

function Get-CcodJournalAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        UtcNow = { [DateTime]::UtcNow }
        ReadJson = { param([string]$Path) Read-CcodStrictJson -Path $Path -ExpectedSchema 1 -Kind 'transition' }
        WriteJson = { param([string]$Path, $Value) Write-CcodAtomicJson -Path $Path -Value $Value }
        WriteLog = { param([string]$Path, [string]$Message) Write-CcodRotatingLog -Path $Path -Message $Message }
        FileExists = { param([string]$Path) [IO.File]::Exists($Path) }
        ReadAllLines = { param([string]$Path) [IO.File]::ReadAllLines($Path, [Text.UTF8Encoding]::new($false)) }
        Checkpoint = { param([string]$Name) }
    }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) { $resolved[$name] = $Adapters[$name] }
    }
    return $resolved
}

function Test-CcodCanonicalUtc {
    param($Value)

    if ($Value -isnot [string]) { return $false }
    $parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToUniversalTime().ToString('o') -ceq $Value
}

function Test-CcodCanonicalGuid {
    param($Value)

    if ($Value -isnot [string]) { return $false }
    $parsed = [guid]::Empty
    return [guid]::TryParseExact($Value, 'D', [ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Test-CcodJournalInteger {
    param($Value, [long]$Minimum, [long]$Maximum)

    return ($Value -is [int] -or $Value -is [long]) -and $Value -ge $Minimum -and $Value -le $Maximum
}

function Assert-CcodJournalNullableIdentity {
    param(
        [Parameter(Mandatory)]$Transition,
        [Parameter(Mandatory)][string]$PidName,
        [Parameter(Mandatory)][string]$TimeName,
        [string]$ErrorId = 'CCOD_TRANSITION_INVALID'
    )

    $pid = $Transition.$PidName
    $time = $Transition.$TimeName
    if ($null -eq $pid -and $null -eq $time) { return }
    if ($null -eq $pid -or $null -eq $time -or
        -not (Test-CcodJournalInteger -Value $pid -Minimum 1 -Maximum ([int]::MaxValue)) -or
        -not (Test-CcodCanonicalUtc -Value $time)) {
        Throw-CcodTransitionError $ErrorId "$PidName and $TimeName must be a paired legal process identity" $Transition
    }
}

function Assert-CcodTransitionValue {
    param([Parameter(Mandatory)]$Transition)

    Assert-CcodJournalExactProperties -Value $Transition -Expected $script:CcodTransitionFields -Kind 'Active transition'
    if (-not (Test-CcodCanonicalGuid -Value $Transition.transactionId)) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'transactionId must be a canonical lowercase GUID in D form' $Transition
    }
    if ($Transition.stage -isnot [string] -or @('IntentWritten', 'StopRequested', 'OrdinaryStopped', 'SpecialLaunchRequested', 'SpecialStarted', 'Validated', 'RecoveryLaunchRequested', 'Recovered', 'CloseRequested', 'Closed') -cnotcontains $Transition.stage) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'stage is not a fixed transition stage' $Transition
    }
    Assert-CcodJournalNullableIdentity -Transition $Transition -PidName 'sourcePid' -TimeName 'sourceCreationTimeUtc'
    if ($Transition.packageFullName -isnot [string] -or [string]::IsNullOrWhiteSpace($Transition.packageFullName) -or
        $Transition.appAsarSha256 -isnot [string] -or $Transition.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Transition.runtimeId -isnot [string] -or [string]::IsNullOrWhiteSpace($Transition.runtimeId)) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'packageFullName, lowercase appAsarSha256, and runtimeId are required' $Transition
    }
    $hasMainPort = $null -ne $Transition.mainPort
    $hasRendererPort = $null -ne $Transition.rendererPort
    if ($hasMainPort -ne $hasRendererPort) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'mainPort and rendererPort must be paired' $Transition
    }
    if ($hasMainPort -and (
        -not (Test-CcodJournalInteger -Value $Transition.mainPort -Minimum 1 -Maximum 65535) -or
        -not (Test-CcodJournalInteger -Value $Transition.rendererPort -Minimum 1 -Maximum 65535) -or
        $Transition.mainPort -eq $Transition.rendererPort)) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'paired ports must be legal and distinct' $Transition
    }
    Assert-CcodJournalNullableIdentity -Transition $Transition -PidName 'specialPid' -TimeName 'specialCreationTimeUtc'
    Assert-CcodJournalNullableIdentity -Transition $Transition -PidName 'recoveryPid' -TimeName 'recoveryCreationTimeUtc'
    if (-not (Test-CcodCanonicalUtc -Value $Transition.createdAtUtc) -or -not (Test-CcodCanonicalUtc -Value $Transition.updatedAtUtc)) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'createdAtUtc and updatedAtUtc must be canonical UTC timestamps' $Transition
    }
    $created = [DateTime]::ParseExact($Transition.createdAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $updated = [DateTime]::ParseExact($Transition.updatedAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    if ($updated -lt $created) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'updatedAtUtc cannot precede createdAtUtc' $Transition
    }

    $hasSource = $null -ne $Transition.sourcePid
    $hasPorts = $hasMainPort
    $hasSpecial = $null -ne $Transition.specialPid
    $hasRecovery = $null -ne $Transition.recoveryPid
    if (-not $hasSource -and $Transition.stage -ceq 'StopRequested') {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'A manual transition cannot request a source stop' $Transition
    }
    if (@('IntentWritten', 'StopRequested', 'OrdinaryStopped', 'SpecialLaunchRequested') -ccontains $Transition.stage -and $hasSpecial) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'special identity cannot exist before SpecialStarted' $Transition
    }
    if (@('SpecialStarted', 'Validated') -ccontains $Transition.stage -and -not $hasSpecial) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'SpecialStarted and Validated require special identity' $Transition
    }
    if (@('SpecialLaunchRequested', 'SpecialStarted', 'Validated') -ccontains $Transition.stage -and -not $hasPorts) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'Special launch stages require allocated distinct ports' $Transition
    }
    if ($hasSpecial -and -not $hasPorts) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'A recorded special identity requires its allocated ports' $Transition
    }
    if (@('CloseRequested', 'Closed') -ccontains $Transition.stage) {
        if ($hasSource -eq $hasSpecial) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'A close transition requires exactly one recorded source or special root' $Transition
        }
        if ($hasSource -and $hasPorts) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'An ordinary close target cannot retain debug ports' $Transition
        }
        if ($hasRecovery) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'A close transition cannot record a recovery identity' $Transition
        }
    }
    if ($Transition.stage -cne 'Recovered' -and $hasRecovery) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'recovery identity cannot exist before Recovered' $Transition
    }
    if ($Transition.stage -ceq 'Recovered' -and -not $hasRecovery) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'Recovered requires recovery identity' $Transition
    }
}

function Assert-CcodTransitionConstructorInput {
    param($Source, $Package, [string]$RuntimeId, $RendererPort, $MainPort, [string]$TransactionId, [hashtable]$Adapters)

    if (-not (Test-CcodCanonicalGuid -Value $TransactionId)) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'transactionId must be a canonical lowercase GUID in D form' $TransactionId
    }
    if ($null -ne $Source) {
        if (-not (Test-CcodJournalProperty -Value $Source -Name 'Pid') -or -not (Test-CcodJournalProperty -Value $Source -Name 'CreationTimeUtc') -or
            -not (Test-CcodJournalInteger -Value $Source.Pid -Minimum 1 -Maximum ([int]::MaxValue)) -or
            -not (Test-CcodCanonicalUtc -Value $Source.CreationTimeUtc)) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'source identity must be a paired legal PID and canonical UTC creation time' $Source
        }
    }
    if ($null -eq $Package -or -not (Test-CcodJournalProperty -Value $Package -Name 'FullName') -or
        -not (Test-CcodJournalProperty -Value $Package -Name 'AppAsarSha256') -or
        $Package.FullName -isnot [string] -or [string]::IsNullOrWhiteSpace($Package.FullName) -or
        $Package.AppAsarSha256 -isnot [string] -or $Package.AppAsarSha256 -cnotmatch '^[0-9a-f]{64}$') {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'package identity and lowercase SHA-256 are required' $Package
    }
    if ([string]::IsNullOrWhiteSpace($RuntimeId)) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'runtimeId must be a non-empty string' $RuntimeId
    }
    if (($null -eq $RendererPort) -ne ($null -eq $MainPort)) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'rendererPort and mainPort must be paired' @($RendererPort, $MainPort)
    }
    if ($null -ne $RendererPort -and (
        -not (Test-CcodJournalInteger -Value $RendererPort -Minimum 1 -Maximum 65535) -or
        -not (Test-CcodJournalInteger -Value $MainPort -Minimum 1 -Maximum 65535) -or
        $RendererPort -eq $MainPort)) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'paired ports must be legal and distinct' @($RendererPort, $MainPort)
    }
    if ($null -ne $Adapters -and $Adapters.ContainsKey('UtcNow') -and $Adapters.UtcNow -isnot [scriptblock]) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'UtcNow adapter must be a scriptblock' $Adapters.UtcNow
    }
}

function Assert-CcodJournalProcessSnapshot {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][ValidateSet('Special', 'Recovery')][string]$Kind,
        $Transition,
        [string]$ErrorId = 'CCOD_TRANSITION_INVALID'
    )

    if ($Snapshot -isnot [pscustomobject] -and $Snapshot -isnot [Collections.IDictionary]) {
        Throw-CcodTransitionError $ErrorId "$Kind identity must be an exact process snapshot" $Snapshot
    }
    Assert-CcodJournalExactProperties -Value $Snapshot -Expected $script:CcodProcessSnapshotFields -Kind "$Kind process snapshot" -ErrorId $ErrorId
    if (-not (Test-CcodJournalInteger -Value $Snapshot.Pid -Minimum 1 -Maximum ([int]::MaxValue)) -or
        -not (Test-CcodCanonicalUtc -Value $Snapshot.CreationTimeUtc) -or
        -not (Test-CcodJournalInteger -Value $Snapshot.SessionId -Minimum 0 -Maximum ([int]::MaxValue)) -or
        $Snapshot.UserSid -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.UserSid) -or
        $Snapshot.Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.Path) -or
        $Snapshot.PackageFamilyName -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.PackageFamilyName) -or
        $Snapshot.CommandLine -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.CommandLine) -or
        ($null -ne $Snapshot.ParentPid -and
            -not (Test-CcodJournalInteger -Value $Snapshot.ParentPid -Minimum 0 -Maximum ([int]::MaxValue))) -or
        $Snapshot.IsTopLevel -isnot [bool] -or -not $Snapshot.IsTopLevel) {
        Throw-CcodTransitionError $ErrorId "$Kind identity is not an exact top-level process snapshot" $Snapshot
    }
    if ($Kind -ceq 'Special') {
        if (@('Unrelated', 'Special') -cnotcontains $Snapshot.Mode -or
            -not (Test-CcodJournalInteger -Value $Snapshot.RendererPort -Minimum 1 -Maximum 65535) -or
            -not (Test-CcodJournalInteger -Value $Snapshot.MainPort -Minimum 1 -Maximum 65535) -or
            -not [object]::Equals([int]$Snapshot.RendererPort, [int]$Transition.rendererPort) -or
            -not [object]::Equals([int]$Snapshot.MainPort, [int]$Transition.mainPort)) {
            Throw-CcodTransitionError $ErrorId 'Special identity must match the allocated transaction ports' $Snapshot
        }
    } elseif ($Snapshot.Mode -cne 'Ordinary' -or $null -ne $Snapshot.RendererPort -or $null -ne $Snapshot.MainPort) {
        Throw-CcodTransitionError $ErrorId 'Recovery identity must be an exact ordinary top-level snapshot' $Snapshot
    }
}

function Assert-CcodObservedFacts {
    param([Parameter(Mandatory)]$Transition, [Parameter(Mandatory)]$Observed)

    if ($Observed -isnot [pscustomobject] -and $Observed -isnot [Collections.IDictionary]) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'Observed facts must be an exact object' $Observed
    }
    Assert-CcodJournalExactProperties -Value $Observed -Expected @('StopObservation', 'RecoveryObservation', 'SpecialObservation', 'PortObservation', 'SpecialCandidates', 'OrdinaryCandidates') -Kind 'Observed replay facts' -ErrorId 'CCOD_REPLAY_INPUT_INVALID'
    if ($Observed.StopObservation -isnot [string] -or @(
        'NotStarted', 'ExitedDuringPrimary5s', 'IdentityChangedDuringPrimary5s', 'SameAliveAfterPrimary5s',
        'ExitedDuringGuard5s', 'IdentityChangedDuringGuard5s', 'SameAliveAfterGuard5s', 'Indeterminate', 'NotApplicable',
        'CloseTreePresent', 'CloseTreeAbsent', 'CloseTreeIndeterminate'
    ) -cnotcontains $Observed.StopObservation) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'StopObservation is not a fixed observed-fact enum' $Observed
    }
    if ($Observed.RecoveryObservation -isnot [string] -or @(
        'NotStarted', 'OrdinaryAppearedWithin5s', 'FiveSecondsElapsedNoOrdinary', 'Indeterminate', 'NotApplicable'
    ) -cnotcontains $Observed.RecoveryObservation) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'RecoveryObservation is not a fixed observed-fact enum' $Observed
    }
    if ($Observed.SpecialObservation -isnot [string] -or @('Confirmed', 'NoCandidate', 'Incomplete', 'Ambiguous', 'PortConflict') -cnotcontains $Observed.SpecialObservation) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'SpecialObservation is not a Task 6 detailed outcome' $Observed
    }
    if ($Observed.PortObservation -isnot [string] -or @('NotApplicable', 'BothRefused', 'Open', 'Indeterminate') -cnotcontains $Observed.PortObservation) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'PortObservation is not a fixed observed-fact enum' $Observed
    }
    if ($null -eq $Observed.SpecialCandidates -or $Observed.SpecialCandidates -is [string] -or $Observed.SpecialCandidates -isnot [Collections.IEnumerable] -or
        $null -eq $Observed.OrdinaryCandidates -or $Observed.OrdinaryCandidates -is [string] -or $Observed.OrdinaryCandidates -isnot [Collections.IEnumerable]) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'Candidate facts must be arrays' $Observed
    }
    $specialCandidates = @($Observed.SpecialCandidates)
    $ordinaryCandidates = @($Observed.OrdinaryCandidates)
    if (($Observed.SpecialObservation -ceq 'Confirmed' -and $specialCandidates.Count -ne 1) -or
        ($Observed.SpecialObservation -ceq 'NoCandidate' -and $specialCandidates.Count -ne 0) -or
        ($Observed.SpecialObservation -ceq 'Ambiguous' -and $specialCandidates.Count -lt 2)) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'SpecialObservation contradicts the number of supplied candidate facts' $Observed
    }
    foreach ($fact in $specialCandidates) {
        if ($null -eq $fact -or ($fact -isnot [pscustomobject] -and $fact -isnot [Collections.IDictionary])) {
            Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'Each special candidate fact must be an exact object' $fact
        }
        Assert-CcodJournalExactProperties -Value $fact -Expected @('Process', 'Evidence', 'Validation') -Kind 'Special candidate fact' -ErrorId 'CCOD_REPLAY_INPUT_INVALID'
        if ($fact.Evidence -isnot [string] -or @('PreStatusCandidate', 'PersistedIdentity') -cnotcontains $fact.Evidence -or
            $fact.Validation -isnot [string] -or @('Valid', 'Invalid', 'Indeterminate') -cnotcontains $fact.Validation) {
            Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'Special candidate evidence or validation enum is invalid' $fact
        }
        Assert-CcodJournalProcessSnapshot -Snapshot $fact.Process -Kind Special -Transition $Transition -ErrorId 'CCOD_REPLAY_INPUT_INVALID'
    }
    foreach ($candidate in $ordinaryCandidates) {
        Assert-CcodJournalProcessSnapshot -Snapshot $candidate -Kind Recovery -Transition $Transition -ErrorId 'CCOD_REPLAY_INPUT_INVALID'
    }
    if ($Observed.RecoveryObservation -ceq 'OrdinaryAppearedWithin5s' -and $ordinaryCandidates.Count -eq 0) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'OrdinaryAppearedWithin5s requires at least one exact ordinary candidate' $Observed
    }
    $hasPorts = $null -ne $Transition.mainPort
    if (($hasPorts -and $Observed.PortObservation -ceq 'NotApplicable') -or
        (-not $hasPorts -and $Observed.PortObservation -cne 'NotApplicable')) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'PortObservation contradicts the transaction port pair' $Observed
    }

    $closeStopObservations = @('CloseTreePresent', 'CloseTreeAbsent', 'CloseTreeIndeterminate')
    $isCloseStage = @('CloseRequested', 'Closed') -ccontains $Transition.stage
    if (-not $isCloseStage) {
        if ($closeStopObservations -ccontains $Observed.StopObservation) {
            Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'Close-only stop evidence is forbidden for a normal replay stage' $Observed
        }
        return
    }

    if ($Observed.RecoveryObservation -cne 'NotApplicable') {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'Close replay cannot carry ordinary recovery-window evidence' $Observed
    }
    if ($closeStopObservations -cnotcontains $Observed.StopObservation) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'Close replay requires close-tree stop evidence' $Observed
    }

    if ($Transition.stage -ceq 'Closed') {
        if ($Observed.StopObservation -cne 'CloseTreeAbsent' -or $Observed.SpecialObservation -cne 'NoCandidate' -or
            $specialCandidates.Count -ne 0 -or $ordinaryCandidates.Count -ne 0) {
            Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'Closed replay requires the durable complete-tree absence proof shape' $Observed
        }
        return
    }

    if ($Observed.StopObservation -ceq 'CloseTreeIndeterminate') {
        return
    }
    if ($Observed.StopObservation -ceq 'CloseTreeAbsent') {
        if ($Observed.SpecialObservation -cne 'NoCandidate' -or $specialCandidates.Count -ne 0 -or $ordinaryCandidates.Count -ne 0 -or
            ($hasPorts -and $Observed.PortObservation -cne 'BothRefused')) {
            Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'CloseTreeAbsent requires empty candidate channels and proven port closure' $Observed
        }
        return
    }

    if ($null -ne $Transition.specialPid) {
        if ($ordinaryCandidates.Count -ne 0 -or $specialCandidates.Count -ne 1 -or
            -not (Test-CcodSpecialFactMatchesJournal -Fact $specialCandidates[0] -Transition $Transition) -or
            $specialCandidates[0].Evidence -cne 'PersistedIdentity' -or $Observed.SpecialObservation -ceq 'Ambiguous') {
            Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'CloseTreePresent must prove only the exact recorded special root' $Observed
        }
        return
    }

    if ($specialCandidates.Count -ne 0 -or $Observed.SpecialObservation -cne 'NoCandidate' -or $ordinaryCandidates.Count -ne 1 -or
        -not [object]::Equals([int]$ordinaryCandidates[0].Pid, [int]$Transition.sourcePid) -or
        $ordinaryCandidates[0].CreationTimeUtc -cne $Transition.sourceCreationTimeUtc) {
        Throw-CcodTransitionError 'CCOD_REPLAY_INPUT_INVALID' 'CloseTreePresent must prove only the exact recorded ordinary root' $Observed
    }
}

function New-CcodRebuiltTransition {
    param(
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)][string]$NewStage,
        $MainPort,
        $RendererPort,
        $SpecialIdentity,
        $RecoveryIdentity,
        [Parameter(Mandatory)][string]$UpdatedAtUtc
    )

    return [pscustomobject][ordered]@{
        transactionId = $Current.transactionId
        stage = $NewStage
        sourcePid = $Current.sourcePid
        sourceCreationTimeUtc = $Current.sourceCreationTimeUtc
        packageFullName = $Current.packageFullName
        appAsarSha256 = $Current.appAsarSha256
        runtimeId = $Current.runtimeId
        mainPort = $MainPort
        rendererPort = $RendererPort
        specialPid = if ($null -ne $SpecialIdentity) { $SpecialIdentity.Pid } else { $Current.specialPid }
        specialCreationTimeUtc = if ($null -ne $SpecialIdentity) { $SpecialIdentity.CreationTimeUtc } else { $Current.specialCreationTimeUtc }
        recoveryPid = if ($null -ne $RecoveryIdentity) { $RecoveryIdentity.Pid } else { $Current.recoveryPid }
        recoveryCreationTimeUtc = if ($null -ne $RecoveryIdentity) { $RecoveryIdentity.CreationTimeUtc } else { $Current.recoveryCreationTimeUtc }
        createdAtUtc = $Current.createdAtUtc
        updatedAtUtc = $UpdatedAtUtc
    }
}

function New-CcodTransition {
    # Caller contract: durable creation, every following external action, stage
    # update, and completion run under the same SID/session transition lease.
    # The stale checks below are guards, not a lock-free compare-and-swap.
    [CmdletBinding()]
    param(
        [AllowNull()]$Source,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$RuntimeId,
        [AllowNull()][Nullable[int]]$RendererPort,
        [AllowNull()][Nullable[int]]$MainPort,
        [Parameter(Mandatory)][string]$TransactionId,
        [string]$Path,
        [hashtable]$Adapters
    )

    Assert-CcodTransitionConstructorInput -Source $Source -Package $Package -RuntimeId $RuntimeId -RendererPort $RendererPort -MainPort $MainPort -TransactionId $TransactionId -Adapters $Adapters
    $adapter = Get-CcodJournalAdapters -Adapters $Adapters
    $now = & $adapter.UtcNow
    if ($now -isnot [DateTime]) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'UtcNow adapter must return a DateTime' $now
    }
    $timestamp = $now.ToUniversalTime().ToString('o')
    $transition = [pscustomobject][ordered]@{
        transactionId = $TransactionId
        stage = 'IntentWritten'
        sourcePid = if ($null -eq $Source) { $null } else { $Source.Pid }
        sourceCreationTimeUtc = if ($null -eq $Source) { $null } else { $Source.CreationTimeUtc }
        packageFullName = $Package.FullName
        appAsarSha256 = $Package.AppAsarSha256
        runtimeId = $RuntimeId
        mainPort = $MainPort
        rendererPort = $RendererPort
        specialPid = $null
        specialCreationTimeUtc = $null
        recoveryPid = $null
        recoveryCreationTimeUtc = $null
        createdAtUtc = $timestamp
        updatedAtUtc = $timestamp
    }
    if ($PSBoundParameters.ContainsKey('Path')) {
        $active = Read-CcodTransition -Path $Path -Adapters $adapter
        if ($null -ne $active) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_CONFLICT' 'An active transition already occupies the store' $active
        }
        & $adapter.WriteJson $Path ([ordered]@{ schemaVersion=1; activeTransaction=$transition })
    }
    return $transition
}

function Read-CcodTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Adapters)

    $adapter = Get-CcodJournalAdapters -Adapters $Adapters
    $store = & $adapter.ReadJson $Path
    if ($null -eq $store -or ($store -isnot [pscustomobject] -and $store -isnot [Collections.IDictionary])) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'Transition store must have an object root' $store
    }
    Assert-CcodJournalExactProperties -Value $store -Expected @('schemaVersion', 'activeTransaction') -Kind 'Transition store'
    if (($store.schemaVersion -isnot [int] -and $store.schemaVersion -isnot [long]) -or $store.schemaVersion -ne 1) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'Transition schemaVersion must be integer 1' $store
    }
    if ($null -eq $store.activeTransaction) { return $null }
    if ($store.activeTransaction -isnot [pscustomobject] -and $store.activeTransaction -isnot [Collections.IDictionary]) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'activeTransaction must be null or an object' $store
    }
    Assert-CcodTransitionValue -Transition $store.activeTransaction
    return $store.activeTransaction
}

function Set-CcodTransitionStage {
    # Task 10 owns the transition mutex; callers must already hold that lease.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$ExpectedStage,
        [Parameter(Mandatory)][string]$NewStage,
        [AllowNull()]$SpecialIdentity,
        [AllowNull()]$RecoveryIdentity,
        [AllowNull()][Nullable[int]]$RendererPort,
        [AllowNull()][Nullable[int]]$MainPort,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodJournalAdapters -Adapters $Adapters
    $current = Read-CcodTransition -Path $Path -Adapters $adapter
    if ($null -eq $current -or $current.transactionId -cne $TransactionId -or $current.stage -cne $ExpectedStage) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_CONFLICT' 'Transition ID or expected stage is stale under the caller-held transition lease' $current
    }

    $knownStages = @('IntentWritten', 'StopRequested', 'OrdinaryStopped', 'SpecialLaunchRequested', 'SpecialStarted', 'Validated', 'RecoveryLaunchRequested', 'Recovered', 'CloseRequested', 'Closed')
    $legal = @{
        IntentWritten = @('StopRequested', 'CloseRequested')
        StopRequested = @('OrdinaryStopped', 'RecoveryLaunchRequested')
        OrdinaryStopped = @('SpecialLaunchRequested', 'RecoveryLaunchRequested')
        SpecialLaunchRequested = @('SpecialStarted', 'RecoveryLaunchRequested')
        SpecialStarted = @('Validated', 'RecoveryLaunchRequested')
        Validated = @('RecoveryLaunchRequested')
        RecoveryLaunchRequested = @('Recovered')
        Recovered = @()
        CloseRequested = @('Closed')
        Closed = @()
    }
    if ($knownStages -cnotcontains $NewStage -or $legal[$ExpectedStage] -cnotcontains $NewStage) {
        $manualEdge = $ExpectedStage -ceq 'IntentWritten' -and $NewStage -ceq 'OrdinaryStopped' -and $null -eq $current.sourcePid
        if (-not $manualEdge) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'The requested transition stage edge is not legal' ([pscustomobject]@{ ExpectedStage=$ExpectedStage; NewStage=$NewStage })
        }
    }
    if ($ExpectedStage -ceq 'IntentWritten' -and $NewStage -ceq 'StopRequested' -and $null -eq $current.sourcePid) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'A manual transition cannot enter StopRequested' $current
    }

    $hasSpecialParameter = $PSBoundParameters.ContainsKey('SpecialIdentity')
    $hasRecoveryParameter = $PSBoundParameters.ContainsKey('RecoveryIdentity')
    $hasRendererParameter = $PSBoundParameters.ContainsKey('RendererPort')
    $hasMainParameter = $PSBoundParameters.ContainsKey('MainPort')
    if (($hasSpecialParameter -and $null -eq $SpecialIdentity) -or ($hasRecoveryParameter -and $null -eq $RecoveryIdentity) -or
        ($hasSpecialParameter -and $hasRecoveryParameter) -or
        ($hasSpecialParameter -and $NewStage -cne 'SpecialStarted' -and -not ($ExpectedStage -ceq 'IntentWritten' -and $NewStage -ceq 'CloseRequested')) -or
        ($hasRecoveryParameter -and $NewStage -cne 'Recovered')) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'Identity parameters are exclusive and valid only for their identity-recording stages' $current
    }
    if ($NewStage -ceq 'SpecialStarted' -and -not $hasSpecialParameter) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'Entering SpecialStarted requires SpecialIdentity' $current
    }
    if ($NewStage -ceq 'Recovered' -and -not $hasRecoveryParameter) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'Entering Recovered requires RecoveryIdentity' $current
    }
    if ($NewStage -ceq 'CloseRequested') {
        $willHaveSource = $null -ne $current.sourcePid
        $willHaveSpecial = $hasSpecialParameter
        if ($willHaveSource -eq $willHaveSpecial) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'Entering CloseRequested requires exactly one source or injected special identity' $current
        }
        if ($willHaveSource -and $null -ne $current.mainPort) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'An ordinary close target cannot retain debug ports' $current
        }
        if ($willHaveSpecial -and $null -eq $current.mainPort) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'A special close target requires constructor-preserved ports' $current
        }
    }
    if ($hasRendererParameter -ne $hasMainParameter -or (($hasRendererParameter -or $hasMainParameter) -and $NewStage -cne 'SpecialLaunchRequested')) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'Port parameters must be paired and supplied only while entering SpecialLaunchRequested' $current
    }

    $nextRendererPort = $current.rendererPort
    $nextMainPort = $current.mainPort
    if ($NewStage -ceq 'SpecialLaunchRequested') {
        if ($null -eq $current.rendererPort) {
            if (-not $hasRendererParameter -or $null -eq $RendererPort -or $null -eq $MainPort -or
                -not (Test-CcodJournalInteger -Value $RendererPort -Minimum 1 -Maximum 65535) -or
                -not (Test-CcodJournalInteger -Value $MainPort -Minimum 1 -Maximum 65535) -or $RendererPort -eq $MainPort) {
                Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'Entering SpecialLaunchRequested from null ports requires a legal distinct pair' $current
            }
            $nextRendererPort = [int]$RendererPort
            $nextMainPort = [int]$MainPort
        } elseif ($hasRendererParameter) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_STAGE_INVALID' 'Allocated transaction ports are immutable' $current
        }
    }

    if ($hasSpecialParameter) { Assert-CcodJournalProcessSnapshot -Snapshot $SpecialIdentity -Kind Special -Transition $current }
    if ($hasRecoveryParameter) { Assert-CcodJournalProcessSnapshot -Snapshot $RecoveryIdentity -Kind Recovery -Transition $current }

    $now = & $adapter.UtcNow
    if ($now -isnot [DateTime]) { Throw-CcodTransitionError 'CCOD_TRANSITION_INVALID' 'UtcNow adapter must return a DateTime' $now }
    $updatedAtUtc = $now.ToUniversalTime().ToString('o')
    $next = New-CcodRebuiltTransition -Current $current -NewStage $NewStage -MainPort $nextMainPort -RendererPort $nextRendererPort `
        -SpecialIdentity $SpecialIdentity -RecoveryIdentity $RecoveryIdentity -UpdatedAtUtc $updatedAtUtc
    Assert-CcodTransitionValue -Transition $next
    & $adapter.WriteJson $Path ([ordered]@{ schemaVersion=1; activeTransaction=$next })
    return $next
}

function New-CcodReplayDecisionResult {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Reason,
        $AdoptedProcess,
        [Parameter(Mandatory)][bool]$MustSuppress
    )

    return [pscustomobject][ordered]@{
        Action = $Action
        Reason = $Reason
        AdoptedProcess = $AdoptedProcess
        MustSuppress = $MustSuppress
    }
}

function Copy-CcodJournalProcessSnapshot {
    param($Snapshot)

    if ($null -eq $Snapshot) { return $null }
    $copy = [ordered]@{}
    foreach ($name in $script:CcodProcessSnapshotFields) { $copy[$name] = $Snapshot.$name }
    return [pscustomobject]$copy
}

function Get-CcodStableOrdinaryCandidate {
    param([object[]]$Candidates)

    if ($null -eq $Candidates -or @($Candidates).Count -eq 0) { return $null }
    $selected = @($Candidates | Sort-Object CreationTimeUtc, Pid)[0]
    return Copy-CcodJournalProcessSnapshot -Snapshot $selected
}

function Get-CcodInitialSpecialReplayDecision {
    param([Parameter(Mandatory)]$Observed)

    $facts = @($Observed.SpecialCandidates)
    if ($Observed.SpecialObservation -ceq 'Confirmed') {
        $process = Copy-CcodJournalProcessSnapshot -Snapshot $facts[0].Process
        switch ($facts[0].Validation) {
            'Valid' { return New-CcodReplayDecisionResult -Action 'AdoptValidatedSpecial' -Reason 'SpecialValidated' -AdoptedProcess $process -MustSuppress $false }
            'Invalid' { return New-CcodReplayDecisionResult -Action 'TerminateSpecialThenRecover' -Reason 'SpecialCandidateInvalid' -AdoptedProcess $process -MustSuppress $true }
            default { return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'SpecialValidationIndeterminate' -AdoptedProcess $null -MustSuppress $true }
        }
    }
    if ($Observed.SpecialObservation -ceq 'NoCandidate') {
        return New-CcodReplayDecisionResult -Action 'RecoverOrdinary' -Reason 'SpecialCandidateAbsent' -AdoptedProcess $null -MustSuppress $true
    }
    switch ($Observed.SpecialObservation) {
        'Ambiguous' { return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'SpecialCandidatesAmbiguous' -AdoptedProcess $null -MustSuppress $true }
        'PortConflict' { return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'SpecialPortConflict' -AdoptedProcess $null -MustSuppress $true }
        default { return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'SpecialEnumerationIncomplete' -AdoptedProcess $null -MustSuppress $true }
    }
}

function Test-CcodSpecialFactMatchesJournal {
    param([Parameter(Mandatory)]$Fact, [Parameter(Mandatory)]$Transition)

    return [object]::Equals([int]$Fact.Process.Pid, [int]$Transition.specialPid) -and
        $Fact.Process.CreationTimeUtc -ceq $Transition.specialCreationTimeUtc
}

function Get-CcodJournalSpecialReplayDecision {
    param([Parameter(Mandatory)]$Transition, [Parameter(Mandatory)]$Observed)

    $facts = @($Observed.SpecialCandidates)
    if ($Observed.SpecialObservation -ceq 'Ambiguous') {
        return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'JournalSpecialAmbiguous' -AdoptedProcess $null -MustSuppress $true
    }
    if ($Observed.SpecialObservation -ceq 'PortConflict') {
        return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'JournalSpecialPortConflict' -AdoptedProcess $null -MustSuppress $true
    }
    if ($Observed.SpecialObservation -ceq 'Incomplete') {
        return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'JournalSpecialIncomplete' -AdoptedProcess $null -MustSuppress $true
    }
    if ($Observed.SpecialObservation -ceq 'NoCandidate') {
        return New-CcodReplayDecisionResult -Action 'RecoverOrdinary' -Reason 'JournalSpecialMissing' -AdoptedProcess $null -MustSuppress $true
    }
    if ($facts.Count -eq 1 -and (Test-CcodSpecialFactMatchesJournal -Fact $facts[0] -Transition $Transition)) {
        $process = Copy-CcodJournalProcessSnapshot -Snapshot $facts[0].Process
        if ($Observed.SpecialObservation -ceq 'Confirmed' -and $facts[0].Validation -ceq 'Invalid') {
            return New-CcodReplayDecisionResult -Action 'TerminateSpecialThenRecover' -Reason 'JournalSpecialInvalid' -AdoptedProcess $process -MustSuppress $true
        }
        if ($Observed.SpecialObservation -ceq 'Confirmed' -and $facts[0].Validation -ceq 'Valid') {
            return New-CcodReplayDecisionResult -Action 'AdoptValidatedSpecial' -Reason 'JournalSpecialValidated' -AdoptedProcess $process -MustSuppress $false
        }
        if ($Observed.SpecialObservation -ceq 'Confirmed') {
            return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'JournalSpecialIndeterminate' -AdoptedProcess $null -MustSuppress $true
        }
    }
    if ($Observed.SpecialObservation -ceq 'Confirmed') {
        return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'JournalSpecialMismatch' -AdoptedProcess $null -MustSuppress $true
    }
    return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'JournalSpecialIncomplete' -AdoptedProcess $null -MustSuppress $true
}

function Get-CcodValidatedSpecialReplayDecision {
    param([Parameter(Mandatory)]$Transition, [Parameter(Mandatory)]$Observed)

    $facts = @($Observed.SpecialCandidates)
    if ($Observed.SpecialObservation -ceq 'NoCandidate') {
        return New-CcodReplayDecisionResult -Action 'RecoverOrdinary' -Reason 'ValidatedSpecialVanished' -AdoptedProcess $null -MustSuppress $true
    }
    if ($Observed.SpecialObservation -ceq 'Confirmed' -and $facts.Count -eq 1 -and
        (Test-CcodSpecialFactMatchesJournal -Fact $facts[0] -Transition $Transition) -and $facts[0].Validation -ceq 'Valid') {
        return New-CcodReplayDecisionResult -Action 'AdoptValidatedSpecial' -Reason 'ValidatedSpecialStillValid' `
            -AdoptedProcess (Copy-CcodJournalProcessSnapshot -Snapshot $facts[0].Process) -MustSuppress $false
    }
    return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'ValidatedSpecialContradictory' -AdoptedProcess $null -MustSuppress $true
}

function Get-CcodRecoveryLaunchReplayDecision {
    param([Parameter(Mandatory)]$Transition, [Parameter(Mandatory)]$Observed)

    $facts = @($Observed.SpecialCandidates)
    if ($Observed.SpecialObservation -ceq 'Confirmed') {
        if ($null -ne $Transition.specialPid -and $facts.Count -eq 1 -and
            (Test-CcodSpecialFactMatchesJournal -Fact $facts[0] -Transition $Transition)) {
            return New-CcodReplayDecisionResult -Action 'TerminateSpecialThenRecover' -Reason 'RecoverySpecialStillAlive' `
                -AdoptedProcess (Copy-CcodJournalProcessSnapshot -Snapshot $facts[0].Process) -MustSuppress $true
        }
        return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'RecoverySpecialMismatch' -AdoptedProcess $null -MustSuppress $true
    }
    if ($Observed.SpecialObservation -cne 'NoCandidate') {
        switch ($Observed.SpecialObservation) {
            'Ambiguous' { return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'RecoverySpecialAmbiguous' -AdoptedProcess $null -MustSuppress $true }
            'PortConflict' { return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'RecoverySpecialPortConflict' -AdoptedProcess $null -MustSuppress $true }
            default { return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'RecoverySpecialEvidenceIncomplete' -AdoptedProcess $null -MustSuppress $true }
        }
    }

    $ordinary = Get-CcodStableOrdinaryCandidate -Candidates @($Observed.OrdinaryCandidates)
    if ($null -ne $ordinary) {
        return New-CcodReplayDecisionResult -Action 'AdoptOrdinaryRecovery' -Reason 'RecoveryOrdinaryAdopted' -AdoptedProcess $ordinary -MustSuppress $true
    }
    switch ($Observed.RecoveryObservation) {
        'NotStarted' { return New-CcodReplayDecisionResult -Action 'RecoverOrdinary' -Reason 'RecoveryObservationRequired' -AdoptedProcess $null -MustSuppress $true }
        'FiveSecondsElapsedNoOrdinary' { return New-CcodReplayDecisionResult -Action 'RecoverOrdinary' -Reason 'RecoveryLaunchOnceRequired' -AdoptedProcess $null -MustSuppress $true }
        'Indeterminate' { return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'RecoveryObservationIndeterminate' -AdoptedProcess $null -MustSuppress $true }
        default { return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'RecoveryObservationNotApplicable' -AdoptedProcess $null -MustSuppress $true }
    }
}

function Get-CcodRecoveredReplayDecision {
    param([Parameter(Mandatory)]$Transition, [Parameter(Mandatory)]$Observed)

    if ($Observed.SpecialObservation -cne 'NoCandidate') {
        return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'RecoveredSpecialContradictory' -AdoptedProcess $null -MustSuppress $true
    }
    foreach ($candidate in @($Observed.OrdinaryCandidates)) {
        if ([object]::Equals([int]$candidate.Pid, [int]$Transition.recoveryPid) -and
            $candidate.CreationTimeUtc -ceq $Transition.recoveryCreationTimeUtc) {
            return New-CcodReplayDecisionResult -Action 'AdoptOrdinaryRecovery' -Reason 'JournalRecoveryAdopted' `
                -AdoptedProcess (Copy-CcodJournalProcessSnapshot -Snapshot $candidate) -MustSuppress $true
        }
    }
    $ordinary = Get-CcodStableOrdinaryCandidate -Candidates @($Observed.OrdinaryCandidates)
    if ($null -ne $ordinary) {
        return New-CcodReplayDecisionResult -Action 'AdoptOrdinaryRecovery' -Reason 'StableOrdinaryFallbackAdopted' -AdoptedProcess $ordinary -MustSuppress $true
    }
    return New-CcodReplayDecisionResult -Action 'CancelKeepOrdinary' -Reason 'RecoveredProcessAbsent' -AdoptedProcess $null -MustSuppress $true
}

function Get-CcodCloseReplayDecision {
    param([Parameter(Mandatory)]$Transition, [Parameter(Mandatory)]$Observed)

    if ($Transition.stage -ceq 'Closed') {
        return New-CcodReplayDecisionResult -Action 'CompleteClosed' -Reason 'CloseAlreadyCommitted' -AdoptedProcess $null -MustSuppress $false
    }

    switch ($Observed.StopObservation) {
        'CloseTreePresent' {
            if ($null -ne $Transition.specialPid) {
                return New-CcodReplayDecisionResult -Action 'CloseRecordedTree' -Reason 'CloseSpecialStillAlive' `
                    -AdoptedProcess (Copy-CcodJournalProcessSnapshot -Snapshot @($Observed.SpecialCandidates)[0].Process) -MustSuppress $false
            }
            return New-CcodReplayDecisionResult -Action 'CloseRecordedTree' -Reason 'CloseOrdinaryStillAlive' `
                -AdoptedProcess (Copy-CcodJournalProcessSnapshot -Snapshot @($Observed.OrdinaryCandidates)[0]) -MustSuppress $false
        }
        'CloseTreeAbsent' {
            return New-CcodReplayDecisionResult -Action 'CompleteClosed' -Reason 'CloseTreeAndPortsProvenAbsent' -AdoptedProcess $null -MustSuppress $false
        }
        default {
            return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'CloseTreeIndeterminate' -AdoptedProcess $null -MustSuppress $true
        }
    }
}

function New-CcodCompletionResult {
    param(
        [Parameter(Mandatory)][string]$Outcome,
        [Parameter(Mandatory)][string]$ArchiveState,
        $ArchiveErrorId
    )

    return [pscustomobject][ordered]@{
        Outcome = $Outcome
        ArchiveState = $ArchiveState
        ArchiveErrorId = $ArchiveErrorId
    }
}

function New-CcodCompletionReceipt {
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$Disposition,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$TerminalStage,
        [Parameter(Mandatory)][string]$CompletedAtUtc,
        [Parameter(Mandatory)][string]$State,
        $ArchiveErrorId
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        transactionId = $TransactionId
        disposition = $Disposition
        terminalStage = $TerminalStage
        completedAtUtc = $CompletedAtUtc
        state = $State
        archiveErrorId = $ArchiveErrorId
    }
}

function Assert-CcodCompletionReceipt {
    param([Parameter(Mandatory)]$Receipt)

    if ($Receipt -isnot [pscustomobject] -and $Receipt -isnot [Collections.IDictionary]) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_RECEIPT_INVALID' 'Completion receipt must be an exact object' $Receipt
    }
    Assert-CcodJournalExactProperties -Value $Receipt -Expected @('schemaVersion', 'transactionId', 'disposition', 'terminalStage', 'completedAtUtc', 'state', 'archiveErrorId') `
        -Kind 'Completion receipt' -ErrorId 'CCOD_TRANSITION_RECEIPT_INVALID'
    if (($Receipt.schemaVersion -isnot [int] -and $Receipt.schemaVersion -isnot [long]) -or $Receipt.schemaVersion -ne 1 -or
        -not (Test-CcodCanonicalGuid -Value $Receipt.transactionId) -or
        $Receipt.disposition -isnot [string] -or @('Cancelled', 'Activated', 'Recovered', 'Closed') -cnotcontains $Receipt.disposition -or
        $Receipt.terminalStage -isnot [string] -or @('IntentWritten', 'StopRequested', 'Validated', 'Recovered', 'Closed') -cnotcontains $Receipt.terminalStage -or
        -not (Test-CcodCanonicalUtc -Value $Receipt.completedAtUtc) -or
        $Receipt.state -isnot [string] -or @('Prepared', 'Archived', 'ArchiveFailed') -cnotcontains $Receipt.state) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_RECEIPT_INVALID' 'Completion receipt fields are invalid' $Receipt
    }
    $terminalValid = ($Receipt.disposition -ceq 'Cancelled' -and @('IntentWritten', 'StopRequested') -ccontains $Receipt.terminalStage) -or
        ($Receipt.disposition -ceq 'Activated' -and $Receipt.terminalStage -ceq 'Validated') -or
        ($Receipt.disposition -ceq 'Recovered' -and $Receipt.terminalStage -ceq 'Recovered') -or
        ($Receipt.disposition -ceq 'Closed' -and $Receipt.terminalStage -ceq 'Closed')
    $errorValid = ($Receipt.state -ceq 'ArchiveFailed' -and $Receipt.archiveErrorId -ceq 'CCOD_TRANSITION_ARCHIVE_FAILED') -or
        ($Receipt.state -cne 'ArchiveFailed' -and $null -eq $Receipt.archiveErrorId)
    if (-not $terminalValid -or -not $errorValid) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_RECEIPT_INVALID' 'Completion receipt terminal or error evidence is inconsistent' $Receipt
    }
}

function Read-CcodCompletionReceipt {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Adapters)

    if (-not (& $Adapters.FileExists $Path)) { return $null }
    $receipt = & $Adapters.ReadJson $Path
    Assert-CcodCompletionReceipt -Receipt $receipt
    return $receipt
}

function Assert-CcodCompletionRequest {
    param($Transition, [string]$TransactionId, [string]$Disposition)

    if (-not (Test-CcodCanonicalGuid -Value $TransactionId) -or @('Cancelled', 'Activated', 'Recovered', 'Closed') -cnotcontains $Disposition -or
        $null -eq $Transition -or $Transition.transactionId -cne $TransactionId) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_COMPLETION_INVALID' 'Completion does not match the active transition' $Transition
    }
    $validTerminal = ($Disposition -ceq 'Cancelled' -and @('IntentWritten', 'StopRequested') -ccontains $Transition.stage) -or
        ($Disposition -ceq 'Activated' -and $Transition.stage -ceq 'Validated') -or
        ($Disposition -ceq 'Recovered' -and $Transition.stage -ceq 'Recovered') -or
        ($Disposition -ceq 'Closed' -and $Transition.stage -ceq 'Closed')
    if (-not $validTerminal) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_COMPLETION_INVALID' 'Disposition is not legal for the active terminal stage' $Transition
    }
}

function Assert-CcodCompletionPaths {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$LogPath)

    foreach ($candidate in @($Path, $LogPath)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not [IO.Path]::IsPathRooted($candidate)) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_COMPLETION_INVALID' 'Completion paths must be absolute' $candidate
        }
        try { $full = [IO.Path]::GetFullPath($candidate) }
        catch { Throw-CcodTransitionError 'CCOD_TRANSITION_COMPLETION_INVALID' 'Completion path is invalid' $candidate }
        if (-not [string]::Equals($full, $candidate, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::IsNullOrWhiteSpace([IO.Path]::GetFileName($candidate))) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_COMPLETION_INVALID' 'Completion paths must be canonical absolute file paths' $candidate
        }
    }
    if ([string]::Equals($Path, $LogPath, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($LogPath) -ieq 'transaction-completion.receipt.json') {
        Throw-CcodTransitionError 'CCOD_TRANSITION_COMPLETION_INVALID' 'Transition log and receipt paths must not collide with the state path' @($Path, $LogPath)
    }
}

function New-CcodArchiveRecord {
    param($Transition, [string]$Disposition, [string]$CompletedAtUtc)

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        transactionId = $Transition.transactionId
        disposition = $Disposition
        terminalStage = $Transition.stage
        sourcePid = $Transition.sourcePid
        sourceCreationTimeUtc = $Transition.sourceCreationTimeUtc
        specialPid = $Transition.specialPid
        specialCreationTimeUtc = $Transition.specialCreationTimeUtc
        recoveryPid = $Transition.recoveryPid
        recoveryCreationTimeUtc = $Transition.recoveryCreationTimeUtc
        appAsarSha256 = $Transition.appAsarSha256
        runtimeId = $Transition.runtimeId
        completedAtUtc = $CompletedAtUtc
        archiveState = 'Archived'
    }
}

function Assert-CcodArchiveRecord {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$Disposition,
        [AllowNull()][AllowEmptyString()][string]$TerminalStage
    )

    $terminalValid = ($Record.disposition -ceq 'Cancelled' -and @('IntentWritten', 'StopRequested') -ccontains $Record.terminalStage) -or
        ($Record.disposition -ceq 'Activated' -and $Record.terminalStage -ceq 'Validated') -or
        ($Record.disposition -ceq 'Recovered' -and $Record.terminalStage -ceq 'Recovered') -or
        ($Record.disposition -ceq 'Closed' -and $Record.terminalStage -ceq 'Closed')
    if (($Record.schemaVersion -isnot [int] -and $Record.schemaVersion -isnot [long]) -or $Record.schemaVersion -ne 1 -or
        -not (Test-CcodCanonicalGuid -Value $Record.transactionId) -or $Record.transactionId -cne $TransactionId -or
        $Record.disposition -cne $Disposition -or (-not [string]::IsNullOrEmpty($TerminalStage) -and $Record.terminalStage -cne $TerminalStage) -or -not $terminalValid -or
        $Record.appAsarSha256 -isnot [string] -or $Record.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Record.runtimeId -isnot [string] -or [string]::IsNullOrWhiteSpace($Record.runtimeId) -or
        -not (Test-CcodCanonicalUtc -Value $Record.completedAtUtc) -or $Record.archiveState -cne 'Archived') {
        Throw-CcodTransitionError 'CCOD_TRANSITION_ARCHIVE_FAILED' 'Archived transaction evidence conflicts with the completion request' $Record
    }
    Assert-CcodJournalNullableIdentity -Transition $Record -PidName 'sourcePid' -TimeName 'sourceCreationTimeUtc' -ErrorId 'CCOD_TRANSITION_ARCHIVE_FAILED'
    Assert-CcodJournalNullableIdentity -Transition $Record -PidName 'specialPid' -TimeName 'specialCreationTimeUtc' -ErrorId 'CCOD_TRANSITION_ARCHIVE_FAILED'
    Assert-CcodJournalNullableIdentity -Transition $Record -PidName 'recoveryPid' -TimeName 'recoveryCreationTimeUtc' -ErrorId 'CCOD_TRANSITION_ARCHIVE_FAILED'
}

function Find-CcodArchiveRecord {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$Disposition,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$TerminalStage,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    $expected = @('schemaVersion', 'transactionId', 'disposition', 'terminalStage', 'sourcePid', 'sourceCreationTimeUtc', 'specialPid', 'specialCreationTimeUtc', 'recoveryPid', 'recoveryCreationTimeUtc', 'appAsarSha256', 'runtimeId', 'completedAtUtc', 'archiveState')
    $paths = @($LogPath)
    for ($generation = 1; $generation -le 10; $generation++) { $paths += "$LogPath.$generation" }
    foreach ($candidatePath in $paths) {
        if (-not (& $Adapters.FileExists $candidatePath)) { continue }
        foreach ($line in @(& $Adapters.ReadAllLines $candidatePath)) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Throw-CcodTransitionError 'CCOD_TRANSITION_ARCHIVE_FAILED' 'Transaction log contains malformed JSONL evidence' $candidatePath
            }
            if ($null -eq $record -or ($record -isnot [pscustomobject] -and $record -isnot [Collections.IDictionary])) {
                Throw-CcodTransitionError 'CCOD_TRANSITION_ARCHIVE_FAILED' 'Transaction log contains a non-object record' $candidatePath
            }
            if (-not (Test-CcodJournalProperty -Value $record -Name 'transactionId') -or $record.transactionId -cne $TransactionId) { continue }
            Assert-CcodJournalExactProperties -Value $record -Expected $expected -Kind 'Archived transaction record' -ErrorId 'CCOD_TRANSITION_ARCHIVE_FAILED'
            Assert-CcodArchiveRecord -Record $record -TransactionId $TransactionId -Disposition $Disposition -TerminalStage $TerminalStage
            return $record
        }
    }
    return $null
}

function Get-CcodReplayDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Transition,
        [Parameter(Mandatory)]$Observed
    )

    Assert-CcodTransitionValue -Transition $Transition
    Assert-CcodObservedFacts -Transition $Transition -Observed $Observed
    if (@('CloseRequested', 'Closed') -ccontains $Transition.stage) {
        return Get-CcodCloseReplayDecision -Transition $Transition -Observed $Observed
    }
    if ($Transition.stage -ceq 'IntentWritten') {
        return New-CcodReplayDecisionResult -Action 'CancelKeepOrdinary' -Reason 'IntentNotCommitted' -AdoptedProcess $null -MustSuppress $false
    }
    if ($Transition.stage -ceq 'StopRequested') {
        switch ($Observed.StopObservation) {
            'NotStarted' {
                return New-CcodReplayDecisionResult -Action 'ObserveStopRequested' -Reason 'StopPrimaryObservationRequired' -AdoptedProcess $null -MustSuppress $false
            }
            'SameAliveAfterPrimary5s' {
                return New-CcodReplayDecisionResult -Action 'ObserveStopRequested' -Reason 'StopGuardObservationRequired' -AdoptedProcess $null -MustSuppress $false
            }
            { @('ExitedDuringPrimary5s', 'IdentityChangedDuringPrimary5s', 'ExitedDuringGuard5s', 'IdentityChangedDuringGuard5s') -ccontains $_ } {
                $ordinary = Get-CcodStableOrdinaryCandidate -Candidates @($Observed.OrdinaryCandidates)
                if ($null -ne $ordinary) {
                    return New-CcodReplayDecisionResult -Action 'AdoptOrdinaryRecovery' -Reason 'StopCompletedOrdinaryAdopted' -AdoptedProcess $ordinary -MustSuppress $true
                }
                return New-CcodReplayDecisionResult -Action 'RecoverOrdinary' -Reason 'StopCompletedRecoveryRequired' -AdoptedProcess $null -MustSuppress $true
            }
            'SameAliveAfterGuard5s' {
                return New-CcodReplayDecisionResult -Action 'CancelKeepOrdinary' -Reason 'SourceStillAliveAfterGuard' -AdoptedProcess $null -MustSuppress $false
            }
            'Indeterminate' {
                return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'StopObservationIndeterminate' -AdoptedProcess $null -MustSuppress $true
            }
            default {
                return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'StopObservationNotApplicable' -AdoptedProcess $null -MustSuppress $true
            }
        }
    }
    if (@('OrdinaryStopped', 'SpecialLaunchRequested') -ccontains $Transition.stage) {
        return Get-CcodInitialSpecialReplayDecision -Observed $Observed
    }
    if ($Transition.stage -ceq 'SpecialStarted') {
        return Get-CcodJournalSpecialReplayDecision -Transition $Transition -Observed $Observed
    }
    if ($Transition.stage -ceq 'Validated') {
        return Get-CcodValidatedSpecialReplayDecision -Transition $Transition -Observed $Observed
    }
    if ($Transition.stage -ceq 'RecoveryLaunchRequested') {
        return Get-CcodRecoveryLaunchReplayDecision -Transition $Transition -Observed $Observed
    }
    if ($Transition.stage -ceq 'Recovered') {
        return Get-CcodRecoveredReplayDecision -Transition $Transition -Observed $Observed
    }
    return New-CcodReplayDecisionResult -Action 'SuppressAndWaitForUser' -Reason 'ReplayStageNotImplemented' -AdoptedProcess $null -MustSuppress $true
}

function Complete-CcodTransition {
    # Completion participates in the same caller-held lease as the transition
    # action it finalizes. Receipt recovery provides crash safety, not locking.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$Disposition,
        [hashtable]$Adapters
    )

    Assert-CcodCompletionPaths -Path $Path -LogPath $LogPath
    $adapter = Get-CcodJournalAdapters -Adapters $Adapters
    $logDirectory = Split-Path -Path $LogPath -Parent
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        Throw-CcodTransitionError 'CCOD_TRANSITION_COMPLETION_INVALID' 'LogPath must have an absolute parent directory' $LogPath
    }
    $receiptPath = Join-Path $logDirectory 'transaction-completion.receipt.json'
    $receipt = Read-CcodCompletionReceipt -Path $receiptPath -Adapters $adapter
    $transition = Read-CcodTransition -Path $Path -Adapters $adapter
    if ($null -eq $transition) {
        if (-not (Test-CcodCanonicalGuid -Value $TransactionId) -or @('Cancelled', 'Activated', 'Recovered', 'Closed') -cnotcontains $Disposition) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_COMPLETION_INVALID' 'Completion identity or disposition is invalid' $TransactionId
        }
        if ($null -ne $receipt -and $receipt.transactionId -ceq $TransactionId -and $receipt.disposition -ceq $Disposition -and
            @('Archived', 'ArchiveFailed') -ccontains $receipt.state) {
            $errorId = if ($receipt.state -ceq 'ArchiveFailed') { 'CCOD_TRANSITION_ARCHIVE_FAILED' } else { $null }
            return New-CcodCompletionResult -Outcome 'AlreadyCompleted' -ArchiveState 'PreviouslyWritten' -ArchiveErrorId $errorId
        }
        $archivedRecord = Find-CcodArchiveRecord -LogPath $LogPath -TransactionId $TransactionId -Disposition $Disposition -TerminalStage $null -Adapters $adapter
        if ($null -ne $archivedRecord) {
            return New-CcodCompletionResult -Outcome 'AlreadyCompleted' -ArchiveState 'PreviouslyWritten' -ArchiveErrorId $null
        }
        Throw-CcodTransitionError 'CCOD_TRANSITION_COMPLETION_INVALID' 'No active or durably completed matching transaction exists' $TransactionId
    }
    Assert-CcodCompletionRequest -Transition $transition -TransactionId $TransactionId -Disposition $Disposition
    if ($null -ne $receipt -and $receipt.transactionId -ceq $TransactionId) {
        if ($receipt.disposition -cne $Disposition -or $receipt.terminalStage -cne $transition.stage) {
            Throw-CcodTransitionError 'CCOD_TRANSITION_RECEIPT_INVALID' 'Existing completion receipt conflicts with the active transition' $receipt
        }
        if (@('Archived', 'ArchiveFailed') -ccontains $receipt.state) {
            & $adapter.WriteJson $Path ([ordered]@{ schemaVersion=1; activeTransaction=$null })
            & $adapter.Checkpoint 'AfterClear'
            $errorId = if ($receipt.state -ceq 'ArchiveFailed') { 'CCOD_TRANSITION_ARCHIVE_FAILED' } else { $null }
            $resumedArchiveState = if ($receipt.state -ceq 'ArchiveFailed') { 'WriteFailed' } else { 'PreviouslyWritten' }
            return New-CcodCompletionResult -Outcome 'Completed' -ArchiveState $resumedArchiveState -ArchiveErrorId $errorId
        }
        $completedAtUtc = $receipt.completedAtUtc
    } else {
        $now = & $adapter.UtcNow
        if ($now -isnot [DateTime]) { Throw-CcodTransitionError 'CCOD_TRANSITION_COMPLETION_INVALID' 'UtcNow adapter must return a DateTime' $now }
        $completedAtUtc = $now.ToUniversalTime().ToString('o')
        $prepared = New-CcodCompletionReceipt -TransactionId $TransactionId -Disposition $Disposition -TerminalStage $transition.stage `
            -CompletedAtUtc $completedAtUtc -State 'Prepared' -ArchiveErrorId $null
        & $adapter.WriteJson $receiptPath $prepared
        & $adapter.Checkpoint 'AfterPreparedReceipt'
    }

    $archiveFailed = $false
    $existingRecord = $null
    try {
        $existingRecord = Find-CcodArchiveRecord -LogPath $LogPath -TransactionId $TransactionId -Disposition $Disposition -TerminalStage $transition.stage -Adapters $adapter
    } catch {
        $archiveFailed = $true
    }
    $archiveState = 'PreviouslyWritten'
    if (-not $archiveFailed -and $null -eq $existingRecord) {
        $record = New-CcodArchiveRecord -Transition $transition -Disposition $Disposition -CompletedAtUtc $completedAtUtc
        try {
            & $adapter.WriteLog $LogPath ($record | ConvertTo-Json -Depth 8 -Compress)
        } catch {
            $archiveFailed = $true
        }
    }
    if ($archiveFailed) {
        $failedReceipt = New-CcodCompletionReceipt -TransactionId $TransactionId -Disposition $Disposition -TerminalStage $transition.stage `
            -CompletedAtUtc $completedAtUtc -State 'ArchiveFailed' -ArchiveErrorId 'CCOD_TRANSITION_ARCHIVE_FAILED'
        & $adapter.WriteJson $receiptPath $failedReceipt
        & $adapter.Checkpoint 'AfterTerminalReceipt'
        & $adapter.WriteJson $Path ([ordered]@{ schemaVersion=1; activeTransaction=$null })
        & $adapter.Checkpoint 'AfterClear'
        return New-CcodCompletionResult -Outcome 'Completed' -ArchiveState 'WriteFailed' -ArchiveErrorId 'CCOD_TRANSITION_ARCHIVE_FAILED'
    }
    if ($null -eq $existingRecord) {
        & $adapter.Checkpoint 'AfterArchiveAppend'
        $archiveState = 'Written'
    }
    $archived = New-CcodCompletionReceipt -TransactionId $TransactionId -Disposition $Disposition -TerminalStage $transition.stage `
        -CompletedAtUtc $completedAtUtc -State 'Archived' -ArchiveErrorId $null
    & $adapter.WriteJson $receiptPath $archived
    & $adapter.Checkpoint 'AfterTerminalReceipt'
    & $adapter.WriteJson $Path ([ordered]@{ schemaVersion=1; activeTransaction=$null })
    & $adapter.Checkpoint 'AfterClear'
    return New-CcodCompletionResult -Outcome 'Completed' -ArchiveState $archiveState -ArchiveErrorId $null
}

Export-ModuleMember -Function New-CcodTransition, Set-CcodTransitionStage, Read-CcodTransition, Get-CcodReplayDecision, Complete-CcodTransition
