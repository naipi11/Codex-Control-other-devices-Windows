$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\TransitionJournal.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\StateStore.psm1') -Force

function New-CcodJournalSnapshot {
    param(
        [int]$ProcessId = 100,
        [string]$CreationTimeUtc = '2030-02-03T04:00:00.0000000Z',
        [ValidateSet('Ordinary', 'Special', 'Unrelated')][string]$Mode = 'Ordinary',
        [AllowNull()][Nullable[int]]$RendererPort = $null,
        [AllowNull()][Nullable[int]]$MainPort = $null,
        [AllowNull()][Nullable[int]]$ParentPid = $null
    )

    return [pscustomobject][ordered]@{
        Pid = $ProcessId
        CreationTimeUtc = $CreationTimeUtc
        SessionId = 1
        UserSid = 'S-1-5-21-test'
        Path = 'C:\Codex\ChatGPT.exe'
        PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
        CommandLine = '"C:\Codex\ChatGPT.exe"'
        ParentPid = $ParentPid
        IsTopLevel = $true
        Mode = $Mode
        RendererPort = $RendererPort
        MainPort = $MainPort
    }
}

function New-CcodJournalPackage {
    return [pscustomobject][ordered]@{
        FullName = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'
        FamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
        Version = '1.0.0.0'
        InstallLocation = 'C:\Codex'
        ExecutablePath = 'C:\Codex\ChatGPT.exe'
        AppAsarPath = 'C:\Codex\resources\app.asar'
        NativeDirectory = 'C:\Codex\resources\native'
        AppAsarSha256 = ('a' * 64)
        StaticClassification = 'KnownCompatible'
        SignatureState = 'Valid'
        NodePath = 'C:\Node\node.exe'
    }
}

function New-CcodRawTransition {
    return [ordered]@{
        transactionId = '5f496d99-c839-4458-a6a2-d37ea1afdbda'
        stage = 'IntentWritten'
        sourcePid = $null
        sourceCreationTimeUtc = $null
        packageFullName = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'
        appAsarSha256 = ('a' * 64)
        runtimeId = 'runtime-1'
        mainPort = $null
        rendererPort = $null
        specialPid = $null
        specialCreationTimeUtc = $null
        recoveryPid = $null
        recoveryCreationTimeUtc = $null
        createdAtUtc = '2030-02-03T04:05:06.0000000Z'
        updatedAtUtc = '2030-02-03T04:05:06.0000000Z'
    }
}

function Copy-CcodJournalValue($Value) {
    return ($Value | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
}

function Write-CcodJournalJson([string]$Path, $Value) {
    [IO.Directory]::CreateDirectory((Split-Path -Path $Path -Parent)) | Out-Null
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 16 -Compress), [Text.UTF8Encoding]::new($false))
}

function New-CcodTransitionForStage {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [switch]$Manual,
        [switch]$WithPorts,
        [switch]$WithSpecial
    )

    $transition = New-CcodRawTransition
    $transition.stage = $Stage
    if (-not $Manual) {
        $transition.sourcePid = 100
        $transition.sourceCreationTimeUtc = '2030-02-03T04:00:00.0000000Z'
    }
    if ($WithPorts) {
        $transition.rendererPort = 41001
        $transition.mainPort = 41002
    }
    if ($WithSpecial) {
        $transition.specialPid = 201
        $transition.specialCreationTimeUtc = '2030-02-03T04:05:07.0000000Z'
    }
    return $transition
}

function New-CcodObserved {
    param(
        [string]$StopObservation = 'NotApplicable',
        [string]$RecoveryObservation = 'NotApplicable',
        [string]$SpecialObservation = 'NoCandidate',
        [string]$PortObservation = 'NotApplicable',
        [object[]]$SpecialCandidates = @(),
        [object[]]$OrdinaryCandidates = @()
    )

    return [pscustomobject][ordered]@{
        StopObservation = $StopObservation
        RecoveryObservation = $RecoveryObservation
        SpecialObservation = $SpecialObservation
        PortObservation = $PortObservation
        SpecialCandidates = @($SpecialCandidates)
        OrdinaryCandidates = @($OrdinaryCandidates)
    }
}

function New-CcodSpecialFact {
    param(
        $Process = (New-CcodJournalSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002),
        [string]$Evidence = 'PreStatusCandidate',
        [string]$Validation = 'Valid'
    )

    return [pscustomobject][ordered]@{
        Process = $Process
        Evidence = $Evidence
        Validation = $Validation
    }
}

$fixedUtc = [DateTime]::Parse('2030-02-03T04:05:06.0000000Z').ToUniversalTime()
$fixedAdapters = @{ UtcNow = { $fixedUtc }.GetNewClosure() }

Invoke-CcodTest 'constructs an exact immutable initial transition from supplied facts' {
    $source = New-CcodJournalSnapshot
    $package = New-CcodJournalPackage
    $sourceBefore = $source | ConvertTo-Json -Depth 8 -Compress
    $packageBefore = $package | ConvertTo-Json -Depth 8 -Compress

    $transition = New-CcodTransition -Source $source -Package $package -RuntimeId '2.0.0-deadbeef' `
        -RendererPort 41001 -MainPort 41002 -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters $fixedAdapters

    Assert-CcodEqual 'transactionId,stage,sourcePid,sourceCreationTimeUtc,packageFullName,appAsarSha256,runtimeId,mainPort,rendererPort,specialPid,specialCreationTimeUtc,recoveryPid,recoveryCreationTimeUtc,createdAtUtc,updatedAtUtc' `
        (($transition.PSObject.Properties.Name) -join ',') 'transition has the exact fixed field order and no revision'
    Assert-CcodEqual '5f496d99-c839-4458-a6a2-d37ea1afdbda' $transition.transactionId 'transaction ID is preserved'
    Assert-CcodEqual 'IntentWritten' $transition.stage 'initial stage is intent written'
    Assert-CcodEqual 100 $transition.sourcePid 'source PID comes from the exact snapshot'
    Assert-CcodEqual '2030-02-03T04:00:00.0000000Z' $transition.sourceCreationTimeUtc 'source creation time is preserved'
    Assert-CcodEqual $package.FullName $transition.packageFullName 'package identity is preserved'
    Assert-CcodEqual ('a' * 64) $transition.appAsarSha256 'package hash is preserved'
    Assert-CcodEqual '2.0.0-deadbeef' $transition.runtimeId 'runtime identity is preserved'
    Assert-CcodEqual 41002 $transition.mainPort 'main port is preserved'
    Assert-CcodEqual 41001 $transition.rendererPort 'renderer port is preserved'
    Assert-CcodEqual $null $transition.specialPid 'special identity begins null'
    Assert-CcodEqual $null $transition.specialCreationTimeUtc 'special creation begins null'
    Assert-CcodEqual $null $transition.recoveryPid 'recovery identity begins null'
    Assert-CcodEqual $null $transition.recoveryCreationTimeUtc 'recovery creation begins null'
    Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' $transition.createdAtUtc 'creation uses the injected UTC clock'
    Assert-CcodEqual $transition.createdAtUtc $transition.updatedAtUtc 'new transition timestamps are identical'
    Assert-CcodEqual $sourceBefore ($source | ConvertTo-Json -Depth 8 -Compress) 'constructor does not mutate source input'
    Assert-CcodEqual $packageBefore ($package | ConvertTo-Json -Depth 8 -Compress) 'constructor does not mutate package input'
}

Invoke-CcodTest 'constructs a manual intent with paired null source and ports' {
    $transition = New-CcodTransition -Source $null -Package (New-CcodJournalPackage) -RuntimeId '2.0.0-deadbeef' `
        -RendererPort $null -MainPort $null -TransactionId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' -Adapters $fixedAdapters

    Assert-CcodEqual $null $transition.sourcePid 'manual intent has no source PID'
    Assert-CcodEqual $null $transition.sourceCreationTimeUtc 'manual intent has no source creation time'
    Assert-CcodEqual $null $transition.mainPort 'ports are not allocated at manual intent time'
    Assert-CcodEqual $null $transition.rendererPort 'both unallocated ports remain null'
}

Invoke-CcodTest 'rejects invalid constructor facts before returning a transition' {
    $package = New-CcodJournalPackage
    $ordinary = New-CcodJournalSnapshot
    $badSourcePair = New-CcodJournalSnapshot
    $badSourcePair.Pid = $null
    $badSourceTime = New-CcodJournalSnapshot -CreationTimeUtc '2030-02-03T04:00:00Z'
    $badHash = New-CcodJournalPackage
    $badHash.AppAsarSha256 = ('A' * 64)
    $badPackage = New-CcodJournalPackage
    $badPackage.FullName = ' '

    $cases = @(
        @{ Name='noncanonical transaction GUID'; Action={ New-CcodTransition -Source $ordinary -Package $package -RuntimeId 'runtime-1' -RendererPort 41001 -MainPort 41002 -TransactionId '5F496D99-C839-4458-A6A2-D37EA1AFDBDA' -Adapters $fixedAdapters } },
        @{ Name='unpaired source identity'; Action={ New-CcodTransition -Source $badSourcePair -Package $package -RuntimeId 'runtime-1' -RendererPort 41001 -MainPort 41002 -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters $fixedAdapters } },
        @{ Name='noncanonical source time'; Action={ New-CcodTransition -Source $badSourceTime -Package $package -RuntimeId 'runtime-1' -RendererPort 41001 -MainPort 41002 -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters $fixedAdapters } },
        @{ Name='uppercase package hash'; Action={ New-CcodTransition -Source $ordinary -Package $badHash -RuntimeId 'runtime-1' -RendererPort 41001 -MainPort 41002 -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters $fixedAdapters } },
        @{ Name='empty package name'; Action={ New-CcodTransition -Source $ordinary -Package $badPackage -RuntimeId 'runtime-1' -RendererPort 41001 -MainPort 41002 -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters $fixedAdapters } },
        @{ Name='empty runtime ID'; Action={ New-CcodTransition -Source $ordinary -Package $package -RuntimeId ' ' -RendererPort 41001 -MainPort 41002 -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters $fixedAdapters } },
        @{ Name='unpaired ports'; Action={ New-CcodTransition -Source $ordinary -Package $package -RuntimeId 'runtime-1' -RendererPort 41001 -MainPort $null -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters $fixedAdapters } },
        @{ Name='identical ports'; Action={ New-CcodTransition -Source $ordinary -Package $package -RuntimeId 'runtime-1' -RendererPort 41001 -MainPort 41001 -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters $fixedAdapters } },
        @{ Name='out-of-range renderer port'; Action={ New-CcodTransition -Source $ordinary -Package $package -RuntimeId 'runtime-1' -RendererPort 0 -MainPort 41002 -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters $fixedAdapters } },
        @{ Name='non-DateTime clock'; Action={ New-CcodTransition -Source $ordinary -Package $package -RuntimeId 'runtime-1' -RendererPort 41001 -MainPort 41002 -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters @{ UtcNow = { '2030-02-03T04:05:06Z' } } } }
    )
    foreach ($case in $cases) {
        Assert-CcodThrows $case.Action 'CCOD_TRANSITION_INVALID'
    }
}

Invoke-CcodTest 'persists intent only into an empty strict store and cross-reads it through StateStore' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-create-' + [guid]::NewGuid().ToString('N'))
    try {
        $stateAdapters = @{
            UtcNow = { $fixedUtc }.GetNewClosure()
            TestVerifiedNodeCandidate = { param($Path) $Path -eq 'C:\Node\node.exe' }
        }
        Initialize-CcodState -StateRoot $root -NodeCandidates @('C:\Node\node.exe') -Adapters $stateAdapters | Out-Null
        $path = Join-Path $root 'transition.json'
        $transition = New-CcodTransition -Path $path -Source (New-CcodJournalSnapshot) -Package (New-CcodJournalPackage) `
            -RuntimeId 'runtime-1' -RendererPort 41001 -MainPort 41002 `
            -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Adapters $fixedAdapters

        Assert-CcodEqual '5f496d99-c839-4458-a6a2-d37ea1afdbda' (Read-CcodTransition -Path $path).transactionId 'persisted intent round-trips through the focused reader'
        $crossRead = Read-CcodState -StateRoot $root -Adapters $stateAdapters
        Assert-CcodEqual $true $crossRead.TransitionActionsAllowed 'Task 7 intent is accepted by StateStore validation'
        Assert-CcodEqual 'IntentWritten' $crossRead.Transition.activeTransaction.stage 'cross-reader sees the exact stage'
        Assert-CcodThrows {
            New-CcodTransition -Path $path -Source (New-CcodJournalSnapshot) -Package (New-CcodJournalPackage) `
                -RuntimeId 'runtime-2' -RendererPort 42001 -MainPort 42002 `
                -TransactionId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' -Adapters $fixedAdapters
        } 'CCOD_TRANSITION_CONFLICT'
        Assert-CcodEqual '5f496d99-c839-4458-a6a2-d37ea1afdbda' (Read-CcodTransition -Path $path).transactionId 'occupied rejection does not overwrite the active transaction'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'strictly reads valid manual and recovery stores without normalizing them' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-read-valid-' + [guid]::NewGuid().ToString('N'))
    try {
        $manualPath = Join-Path $root 'manual.json'
        $manual = New-CcodRawTransition
        Write-CcodJournalJson -Path $manualPath -Value ([ordered]@{ schemaVersion=1; activeTransaction=$manual })
        $loadedManual = Read-CcodTransition -Path $manualPath
        Assert-CcodEqual $null $loadedManual.sourcePid 'manual source pair is accepted'
        Assert-CcodEqual $null $loadedManual.mainPort 'pre-launch port pair is accepted'

        $recoveredPath = Join-Path $root 'recovered.json'
        $recovered = New-CcodRawTransition
        $recovered.stage = 'Recovered'
        $recovered.recoveryPid = 301
        $recovered.recoveryCreationTimeUtc = '2030-02-03T04:05:07.0000000Z'
        $recovered.updatedAtUtc = '2030-02-03T04:05:07.0000000Z'
        Write-CcodJournalJson -Path $recoveredPath -Value ([ordered]@{ schemaVersion=1; activeTransaction=$recovered })
        Assert-CcodEqual 301 (Read-CcodTransition -Path $recoveredPath).recoveryPid 'pre-special recovery may remain without debug ports'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'rejects every malformed strict root field type range pair and stage combination' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-read-invalid-' + [guid]::NewGuid().ToString('N'))
    try {
        $cases = @(
            @{ Name='root-missing-field'; Mutate={ param($store) $store.PSObject.Properties.Remove('activeTransaction') } },
            @{ Name='root-extra-field'; Mutate={ param($store) $store | Add-Member -NotePropertyName extra -NotePropertyValue 1 } },
            @{ Name='root-case-change'; Mutate={ param($store) $value=$store.schemaVersion; $store.PSObject.Properties.Remove('schemaVersion'); $store | Add-Member -NotePropertyName SchemaVersion -NotePropertyValue $value } },
            @{ Name='schema-type'; Mutate={ param($store) $store.schemaVersion='1' } },
            @{ Name='active-scalar'; Mutate={ param($store) $store.activeTransaction='bad' } },
            @{ Name='transaction-missing-field'; Mutate={ param($store) $store.activeTransaction.PSObject.Properties.Remove('stage') } },
            @{ Name='transaction-extra-field'; Mutate={ param($store) $store.activeTransaction | Add-Member -NotePropertyName revision -NotePropertyValue 1 } },
            @{ Name='transaction-case-change'; Mutate={ param($store) $value=$store.activeTransaction.stage; $store.activeTransaction.PSObject.Properties.Remove('stage'); $store.activeTransaction | Add-Member -NotePropertyName Stage -NotePropertyValue $value } },
            @{ Name='noncanonical-guid'; Mutate={ param($store) $store.activeTransaction.transactionId='5F496D99-C839-4458-A6A2-D37EA1AFDBDA' } },
            @{ Name='bad-stage-case'; Mutate={ param($store) $store.activeTransaction.stage='intentwritten' } },
            @{ Name='source-type'; Mutate={ param($store) $store.activeTransaction.sourcePid='100'; $store.activeTransaction.sourceCreationTimeUtc='2030-02-03T04:00:00.0000000Z' } },
            @{ Name='source-range'; Mutate={ param($store) $store.activeTransaction.sourcePid=0; $store.activeTransaction.sourceCreationTimeUtc='2030-02-03T04:00:00.0000000Z' } },
            @{ Name='source-unpaired'; Mutate={ param($store) $store.activeTransaction.sourcePid=100 } },
            @{ Name='source-time'; Mutate={ param($store) $store.activeTransaction.sourcePid=100; $store.activeTransaction.sourceCreationTimeUtc='2030-02-03T04:00:00Z' } },
            @{ Name='manual-stop'; Mutate={ param($store) $store.activeTransaction.stage='StopRequested' } },
            @{ Name='package-type'; Mutate={ param($store) $store.activeTransaction.packageFullName=1 } },
            @{ Name='package-empty'; Mutate={ param($store) $store.activeTransaction.packageFullName=' ' } },
            @{ Name='hash-case'; Mutate={ param($store) $store.activeTransaction.appAsarSha256=('A' * 64) } },
            @{ Name='runtime-type'; Mutate={ param($store) $store.activeTransaction.runtimeId=1 } },
            @{ Name='runtime-empty'; Mutate={ param($store) $store.activeTransaction.runtimeId=' ' } },
            @{ Name='port-unpaired'; Mutate={ param($store) $store.activeTransaction.rendererPort=41001 } },
            @{ Name='port-type'; Mutate={ param($store) $store.activeTransaction.rendererPort='41001'; $store.activeTransaction.mainPort=41002 } },
            @{ Name='port-range'; Mutate={ param($store) $store.activeTransaction.rendererPort=65536; $store.activeTransaction.mainPort=41002 } },
            @{ Name='port-same'; Mutate={ param($store) $store.activeTransaction.rendererPort=41001; $store.activeTransaction.mainPort=41001 } },
            @{ Name='special-launch-no-ports'; Mutate={ param($store) $store.activeTransaction.stage='SpecialLaunchRequested' } },
            @{ Name='early-special'; Mutate={ param($store) $store.activeTransaction.specialPid=201; $store.activeTransaction.specialCreationTimeUtc='2030-02-03T04:05:07.0000000Z' } },
            @{ Name='special-unpaired'; Mutate={ param($store) $store.activeTransaction.stage='SpecialStarted'; $store.activeTransaction.rendererPort=41001; $store.activeTransaction.mainPort=41002; $store.activeTransaction.specialPid=201 } },
            @{ Name='special-started-missing'; Mutate={ param($store) $store.activeTransaction.stage='SpecialStarted'; $store.activeTransaction.rendererPort=41001; $store.activeTransaction.mainPort=41002 } },
            @{ Name='recovery-early'; Mutate={ param($store) $store.activeTransaction.recoveryPid=301; $store.activeTransaction.recoveryCreationTimeUtc='2030-02-03T04:05:07.0000000Z' } },
            @{ Name='recovery-unpaired'; Mutate={ param($store) $store.activeTransaction.stage='Recovered'; $store.activeTransaction.recoveryPid=301 } },
            @{ Name='recovered-missing'; Mutate={ param($store) $store.activeTransaction.stage='Recovered' } },
            @{ Name='special-without-ports-in-recovery'; Mutate={ param($store) $store.activeTransaction.stage='RecoveryLaunchRequested'; $store.activeTransaction.specialPid=201; $store.activeTransaction.specialCreationTimeUtc='2030-02-03T04:05:07.0000000Z' } },
            @{ Name='created-time'; Mutate={ param($store) $store.activeTransaction.createdAtUtc='2030-02-03T04:05:06Z' } },
            @{ Name='updated-time-type'; Mutate={ param($store) $store.activeTransaction.updatedAtUtc=1 } },
            @{ Name='updated-before-created'; Mutate={ param($store) $store.activeTransaction.updatedAtUtc='2030-02-03T04:05:05.0000000Z' } }
        )
        foreach ($case in $cases) {
            $path = Join-Path $root ($case.Name + '.json')
            $store = Copy-CcodJournalValue ([ordered]@{ schemaVersion=1; activeTransaction=(New-CcodRawTransition) })
            & $case.Mutate $store
            Write-CcodJournalJson -Path $path -Value $store
            Assert-CcodThrows { Read-CcodTransition -Path $path } 'CCOD_TRANSITION_INVALID'
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'advances every legal stage edge with immutable exact writes and StateStore cross-reads' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-edges-' + [guid]::NewGuid().ToString('N'))
    $updatedUtc = [DateTime]::Parse('2030-02-03T04:05:08.0000000Z').ToUniversalTime()
    $setAdapters = @{ UtcNow = { $updatedUtc }.GetNewClosure() }
    $stateAdapters = @{
        UtcNow = { $updatedUtc }.GetNewClosure()
        TestVerifiedNodeCandidate = { param($Path) $Path -eq 'C:\Node\node.exe' }
    }
    $special = New-CcodJournalSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
    $recovery = New-CcodJournalSnapshot -ProcessId 301 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Ordinary
    try {
        $cases = @(
            @{ Name='intent-stop'; Expected='IntentWritten'; New='StopRequested'; Tx=(New-CcodTransitionForStage -Stage IntentWritten) },
            @{ Name='manual-intent-ordinary'; Expected='IntentWritten'; New='OrdinaryStopped'; Tx=(New-CcodTransitionForStage -Stage IntentWritten -Manual) },
            @{ Name='stop-ordinary'; Expected='StopRequested'; New='OrdinaryStopped'; Tx=(New-CcodTransitionForStage -Stage StopRequested) },
            @{ Name='stop-recovery'; Expected='StopRequested'; New='RecoveryLaunchRequested'; Tx=(New-CcodTransitionForStage -Stage StopRequested) },
            @{ Name='ordinary-special-launch'; Expected='OrdinaryStopped'; New='SpecialLaunchRequested'; Tx=(New-CcodTransitionForStage -Stage OrdinaryStopped); AddPorts=$true },
            @{ Name='ordinary-recovery'; Expected='OrdinaryStopped'; New='RecoveryLaunchRequested'; Tx=(New-CcodTransitionForStage -Stage OrdinaryStopped) },
            @{ Name='special-launch-started'; Expected='SpecialLaunchRequested'; New='SpecialStarted'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts); AddSpecial=$true },
            @{ Name='special-launch-recovery'; Expected='SpecialLaunchRequested'; New='RecoveryLaunchRequested'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts) },
            @{ Name='special-started-validated'; Expected='SpecialStarted'; New='Validated'; Tx=(New-CcodTransitionForStage -Stage SpecialStarted -WithPorts -WithSpecial) },
            @{ Name='special-started-recovery'; Expected='SpecialStarted'; New='RecoveryLaunchRequested'; Tx=(New-CcodTransitionForStage -Stage SpecialStarted -WithPorts -WithSpecial) },
            @{ Name='validated-recovery'; Expected='Validated'; New='RecoveryLaunchRequested'; Tx=(New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial) },
            @{ Name='recovery-recovered'; Expected='RecoveryLaunchRequested'; New='Recovered'; Tx=(New-CcodTransitionForStage -Stage RecoveryLaunchRequested); AddRecovery=$true }
        )
        foreach ($case in $cases) {
            $state = Join-Path $root $case.Name
            Initialize-CcodState -StateRoot $state -NodeCandidates @('C:\Node\node.exe') -Adapters $stateAdapters | Out-Null
            $path = Join-Path $state 'transition.json'
            Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$case.Tx })
            $before = Read-CcodTransition -Path $path
            $parameters = @{
                Path=$path
                TransactionId='5f496d99-c839-4458-a6a2-d37ea1afdbda'
                ExpectedStage=$case.Expected
                NewStage=$case.New
                Adapters=$setAdapters
            }
            if ($case.AddPorts) { $parameters.RendererPort=41001; $parameters.MainPort=41002 }
            if ($case.AddSpecial) { $parameters.SpecialIdentity=$special }
            if ($case.AddRecovery) { $parameters.RecoveryIdentity=$recovery }
            $after = Set-CcodTransitionStage @parameters

            Assert-CcodEqual $case.Expected $before.stage "$($case.Name) does not mutate the previously read object"
            Assert-CcodEqual $case.New $after.stage "$($case.Name) reaches its legal next stage"
            Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' $after.createdAtUtc "$($case.Name) preserves creation time"
            Assert-CcodEqual '2030-02-03T04:05:08.0000000Z' $after.updatedAtUtc "$($case.Name) updates through the injected clock"
            Assert-CcodEqual 'transactionId,stage,sourcePid,sourceCreationTimeUtc,packageFullName,appAsarSha256,runtimeId,mainPort,rendererPort,specialPid,specialCreationTimeUtc,recoveryPid,recoveryCreationTimeUtc,createdAtUtc,updatedAtUtc' `
                (($after.PSObject.Properties.Name) -join ',') "$($case.Name) rebuilds the exact immutable field order"
            if ($case.AddPorts) { Assert-CcodEqual 41001 $after.rendererPort 'ports are allocated while entering SpecialLaunchRequested' }
            if ($case.AddSpecial) { Assert-CcodEqual 201 $after.specialPid 'pre-status Mode=Unrelated candidate identity is recorded' }
            if ($case.Tx.specialPid) { Assert-CcodEqual 201 $after.specialPid "$($case.Name) preserves recorded special identity" }
            if ($case.AddRecovery) { Assert-CcodEqual 301 $after.recoveryPid 'exact ordinary recovery identity is recorded' }
            $crossRead = Read-CcodState -StateRoot $state -Adapters $stateAdapters
            Assert-CcodEqual $true $crossRead.TransitionActionsAllowed "$($case.Name) output passes the shared validator"
            Assert-CcodEqual $case.New $crossRead.Transition.activeTransaction.stage "$($case.Name) cross-read sees the committed stage"
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'accepts and preserves Task6 top-level ParentPid snapshots across journal boundaries' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-parent-pid-' + [guid]::NewGuid().ToString('N'))
    $special = New-CcodJournalSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' `
        -Mode Unrelated -RendererPort 41001 -MainPort 41002 -ParentPid 77
    $recovery = New-CcodJournalSnapshot -ProcessId 301 -CreationTimeUtc '2030-02-03T04:05:09.0000000Z' `
        -Mode Ordinary -ParentPid 0
    $specialDecision = $null
    $recoveryDecision = $null
    $specialStage = $null
    $recoveryStage = $null
    $failures = [Collections.Generic.List[string]]::new()
    try {
        try {
            $specialDecision = Get-CcodReplayDecision -Transition (New-CcodTransitionForStage -Stage OrdinaryStopped -WithPorts) `
                -Observed (New-CcodObserved -SpecialObservation Confirmed -SpecialCandidates @(
                    (New-CcodSpecialFact -Process $special -Validation Valid)
                ) -PortObservation Indeterminate)
        } catch { $failures.Add("special replay: $($_.FullyQualifiedErrorId)") }

        $recovered = New-CcodTransitionForStage -Stage RecoveryLaunchRequested
        $recovered.stage = 'Recovered'
        $recovered.recoveryPid = 301
        $recovered.recoveryCreationTimeUtc = '2030-02-03T04:05:09.0000000Z'
        $recovered.updatedAtUtc = '2030-02-03T04:05:09.0000000Z'
        try {
            $recoveryDecision = Get-CcodReplayDecision -Transition $recovered `
                -Observed (New-CcodObserved -SpecialObservation NoCandidate -OrdinaryCandidates @($recovery))
        } catch { $failures.Add("recovery replay: $($_.FullyQualifiedErrorId)") }

        $specialPath = Join-Path $root 'special.json'
        Write-CcodJournalJson -Path $specialPath -Value ([ordered]@{
            schemaVersion=1
            activeTransaction=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts)
        })
        try {
            $specialStage = Set-CcodTransitionStage -Path $specialPath `
                -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -ExpectedStage SpecialLaunchRequested `
                -NewStage SpecialStarted -SpecialIdentity $special -Adapters $fixedAdapters
        } catch { $failures.Add("special stage: $($_.FullyQualifiedErrorId)") }

        $recoveryPath = Join-Path $root 'recovery.json'
        Write-CcodJournalJson -Path $recoveryPath -Value ([ordered]@{
            schemaVersion=1
            activeTransaction=(New-CcodTransitionForStage -Stage RecoveryLaunchRequested)
        })
        try {
            $recoveryStage = Set-CcodTransitionStage -Path $recoveryPath `
                -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -ExpectedStage RecoveryLaunchRequested `
                -NewStage Recovered -RecoveryIdentity $recovery -Adapters $fixedAdapters
        } catch { $failures.Add("recovery stage: $($_.FullyQualifiedErrorId)") }

        if ($failures.Count -ne 0) { throw ('Task6 ParentPid snapshot was rejected at ' + ($failures -join '; ')) }
        Assert-CcodEqual 77 $specialDecision.AdoptedProcess.ParentPid 'special replay preserves the real Task6 parent PID'
        Assert-CcodTrue ($specialDecision.AdoptedProcess.ParentPid -is [int]) 'special replay preserves the Int32 parent type'
        Assert-CcodEqual 0 $recoveryDecision.AdoptedProcess.ParentPid 'recovery replay preserves the legal PID zero boundary'
        Assert-CcodTrue ($recoveryDecision.AdoptedProcess.ParentPid -is [int]) 'recovery replay preserves the Int32 parent type'
        Assert-CcodEqual 201 $specialStage.specialPid 'special SetStage accepts the exact Task6 top-level snapshot'
        Assert-CcodEqual 301 $recoveryStage.recoveryPid 'recovery SetStage accepts the exact Task6 top-level snapshot'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'rejects conflicts illegal edges and invalid injections before any journal write' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-invalid-edges-' + [guid]::NewGuid().ToString('N'))
    $special = New-CcodJournalSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
    $recovery = New-CcodJournalSnapshot -ProcessId 301 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Ordinary
    $badSpecialMode = Copy-CcodJournalValue $special
    $badSpecialMode.Mode = 'Ordinary'
    $badSpecialPorts = Copy-CcodJournalValue $special
    $badSpecialPorts.RendererPort = 42001
    $extraSpecial = Copy-CcodJournalValue $special
    $extraSpecial | Add-Member -NotePropertyName Proof -NotePropertyValue 'not accepted here'
    $badRecovery = Copy-CcodJournalValue $recovery
    $badRecovery.Mode = 'Unrelated'
    $negativeParent = Copy-CcodJournalValue $special
    $negativeParent.ParentPid = -1
    $overflowParent = Copy-CcodJournalValue $special
    $overflowParent.ParentPid = [long]2147483648
    $stringParent = Copy-CcodJournalValue $special
    $stringParent.ParentPid = '77'
    try {
        $cases = @(
            @{ Name='wrong-id'; Tx=(New-CcodTransitionForStage -Stage IntentWritten); Error='CCOD_TRANSITION_CONFLICT'; Params=@{ TransactionId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'; ExpectedStage='IntentWritten'; NewStage='StopRequested' } },
            @{ Name='stale-stage'; Tx=(New-CcodTransitionForStage -Stage IntentWritten); Error='CCOD_TRANSITION_CONFLICT'; Params=@{ ExpectedStage='StopRequested'; NewStage='OrdinaryStopped' } },
            @{ Name='illegal-jump'; Tx=(New-CcodTransitionForStage -Stage IntentWritten); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='IntentWritten'; NewStage='Validated' } },
            @{ Name='automatic-manual-edge'; Tx=(New-CcodTransitionForStage -Stage IntentWritten); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='IntentWritten'; NewStage='OrdinaryStopped' } },
            @{ Name='manual-stop'; Tx=(New-CcodTransitionForStage -Stage IntentWritten -Manual); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='IntentWritten'; NewStage='StopRequested' } },
            @{ Name='missing-port-allocation'; Tx=(New-CcodTransitionForStage -Stage OrdinaryStopped); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='OrdinaryStopped'; NewStage='SpecialLaunchRequested' } },
            @{ Name='unpaired-port-allocation'; Tx=(New-CcodTransitionForStage -Stage OrdinaryStopped); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='OrdinaryStopped'; NewStage='SpecialLaunchRequested'; RendererPort=41001 } },
            @{ Name='ports-on-recovery-edge'; Tx=(New-CcodTransitionForStage -Stage OrdinaryStopped); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='OrdinaryStopped'; NewStage='RecoveryLaunchRequested'; RendererPort=41001; MainPort=41002 } },
            @{ Name='reallocate-existing-ports'; Tx=(New-CcodTransitionForStage -Stage OrdinaryStopped -WithPorts); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='OrdinaryStopped'; NewStage='SpecialLaunchRequested'; RendererPort=42001; MainPort=42002 } },
            @{ Name='missing-special-identity'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='SpecialLaunchRequested'; NewStage='SpecialStarted' } },
            @{ Name='special-identity-wrong-stage'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='SpecialLaunchRequested'; NewStage='RecoveryLaunchRequested'; SpecialIdentity=$special } },
            @{ Name='both-identities'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='SpecialLaunchRequested'; NewStage='SpecialStarted'; SpecialIdentity=$special; RecoveryIdentity=$recovery } },
            @{ Name='special-mode'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts); Error='CCOD_TRANSITION_INVALID'; Params=@{ ExpectedStage='SpecialLaunchRequested'; NewStage='SpecialStarted'; SpecialIdentity=$badSpecialMode } },
            @{ Name='special-port-mismatch'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts); Error='CCOD_TRANSITION_INVALID'; Params=@{ ExpectedStage='SpecialLaunchRequested'; NewStage='SpecialStarted'; SpecialIdentity=$badSpecialPorts } },
            @{ Name='special-extra-field'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts); Error='CCOD_TRANSITION_INVALID'; Params=@{ ExpectedStage='SpecialLaunchRequested'; NewStage='SpecialStarted'; SpecialIdentity=$extraSpecial } },
            @{ Name='special-negative-parent'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts); Error='CCOD_TRANSITION_INVALID'; Params=@{ ExpectedStage='SpecialLaunchRequested'; NewStage='SpecialStarted'; SpecialIdentity=$negativeParent } },
            @{ Name='special-overflow-parent'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts); Error='CCOD_TRANSITION_INVALID'; Params=@{ ExpectedStage='SpecialLaunchRequested'; NewStage='SpecialStarted'; SpecialIdentity=$overflowParent } },
            @{ Name='special-string-parent'; Tx=(New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts); Error='CCOD_TRANSITION_INVALID'; Params=@{ ExpectedStage='SpecialLaunchRequested'; NewStage='SpecialStarted'; SpecialIdentity=$stringParent } },
            @{ Name='missing-recovery-identity'; Tx=(New-CcodTransitionForStage -Stage RecoveryLaunchRequested); Error='CCOD_TRANSITION_STAGE_INVALID'; Params=@{ ExpectedStage='RecoveryLaunchRequested'; NewStage='Recovered' } },
            @{ Name='recovery-mode'; Tx=(New-CcodTransitionForStage -Stage RecoveryLaunchRequested); Error='CCOD_TRANSITION_INVALID'; Params=@{ ExpectedStage='RecoveryLaunchRequested'; NewStage='Recovered'; RecoveryIdentity=$badRecovery } }
        )
        foreach ($case in $cases) {
            $path = Join-Path $root ($case.Name + '.json')
            Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$case.Tx })
            $before = [IO.File]::ReadAllBytes($path)
            $parameters = @{
                Path=$path
                TransactionId='5f496d99-c839-4458-a6a2-d37ea1afdbda'
                ExpectedStage=$case.Params.ExpectedStage
                NewStage=$case.Params.NewStage
                Adapters=$fixedAdapters
            }
            foreach ($name in @('TransactionId','RendererPort','MainPort','SpecialIdentity','RecoveryIdentity')) {
                if ($case.Params.ContainsKey($name)) { $parameters[$name] = $case.Params[$name] }
            }
            Assert-CcodThrows { Set-CcodTransitionStage @parameters } $case.Error
            Assert-CcodEqual ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) "$($case.Name) fails before write"
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'purely cancels an uncommitted intent with the exact replay contract' {
    $transition = New-CcodTransitionForStage -Stage IntentWritten
    $observed = New-CcodObserved
    $transitionBefore = $transition | ConvertTo-Json -Depth 16 -Compress
    $observedBefore = $observed | ConvertTo-Json -Depth 16 -Compress

    $decision = Get-CcodReplayDecision -Transition $transition -Observed $observed

    Assert-CcodEqual 'Action,Reason,AdoptedProcess,MustSuppress' (($decision.PSObject.Properties.Name) -join ',') 'replay output has exactly four fields'
    Assert-CcodEqual 'CancelKeepOrdinary' $decision.Action 'intent replay never launches or stops a process'
    Assert-CcodEqual 'IntentNotCommitted' $decision.Reason 'reason is a stable code'
    Assert-CcodEqual $null $decision.AdoptedProcess 'intent replay does not adopt a process'
    Assert-CcodEqual $false $decision.MustSuppress 'uncommitted intent does not suppress the build'
    Assert-CcodEqual $transitionBefore ($transition | ConvertTo-Json -Depth 16 -Compress) 'replay does not mutate transition input'
    Assert-CcodEqual $observedBefore ($observed | ConvertTo-Json -Depth 16 -Compress) 'replay does not mutate observed input'
    Assert-CcodTrue (-not (Get-Command Get-CcodReplayDecision).Parameters.ContainsKey('Adapters')) 'pure replay has no adapter boundary to touch IO process clock delay or log'
}

Invoke-CcodTest 'rejects malformed observed facts and contradictory Task6 special outcomes' {
    $transition = New-CcodTransitionForStage -Stage SpecialLaunchRequested -WithPorts
    $candidate = New-CcodSpecialFact
    $candidate2 = New-CcodSpecialFact -Process (New-CcodJournalSnapshot -ProcessId 202 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002)
    $ordinary = New-CcodJournalSnapshot -ProcessId 301 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Ordinary
    $cases = @(
        @{ Name='observed-missing'; Value=(New-CcodObserved); Mutate={ param($value) $value.PSObject.Properties.Remove('StopObservation') } },
        @{ Name='observed-extra'; Value=(New-CcodObserved); Mutate={ param($value) $value | Add-Member -NotePropertyName Delay -NotePropertyValue 5000 } },
        @{ Name='observed-case'; Value=(New-CcodObserved); Mutate={ param($value) $old=$value.SpecialObservation; $value.PSObject.Properties.Remove('SpecialObservation'); $value | Add-Member -NotePropertyName specialObservation -NotePropertyValue $old } },
        @{ Name='stop-enum'; Value=(New-CcodObserved -StopObservation 'notstarted'); Mutate={ param($value) } },
        @{ Name='recovery-enum'; Value=(New-CcodObserved -RecoveryObservation 'Unknown'); Mutate={ param($value) } },
        @{ Name='special-enum'; Value=(New-CcodObserved -SpecialObservation 'nocandidate'); Mutate={ param($value) } },
        @{ Name='special-array-null'; Value=(New-CcodObserved); Mutate={ param($value) $value.SpecialCandidates=$null } },
        @{ Name='special-array-string'; Value=(New-CcodObserved); Mutate={ param($value) $value.SpecialCandidates='candidate' } },
        @{ Name='ordinary-array-null'; Value=(New-CcodObserved); Mutate={ param($value) $value.OrdinaryCandidates=$null } },
        @{ Name='ordinary-array-string'; Value=(New-CcodObserved); Mutate={ param($value) $value.OrdinaryCandidates='ordinary' } },
        @{ Name='no-candidate-with-fact'; Value=(New-CcodObserved -SpecialObservation NoCandidate -SpecialCandidates @($candidate)); Mutate={ param($value) } },
        @{ Name='confirmed-empty'; Value=(New-CcodObserved -SpecialObservation Confirmed); Mutate={ param($value) } },
        @{ Name='confirmed-multiple'; Value=(New-CcodObserved -SpecialObservation Confirmed -SpecialCandidates @($candidate,$candidate2)); Mutate={ param($value) } },
        @{ Name='ambiguous-empty'; Value=(New-CcodObserved -SpecialObservation Ambiguous); Mutate={ param($value) } },
        @{ Name='ambiguous-one'; Value=(New-CcodObserved -SpecialObservation Ambiguous -SpecialCandidates @($candidate)); Mutate={ param($value) } },
        @{ Name='fact-missing'; Value=(New-CcodObserved -SpecialObservation Confirmed -SpecialCandidates @($candidate)); Mutate={ param($value) $value.SpecialCandidates[0].PSObject.Properties.Remove('Evidence') } },
        @{ Name='fact-extra'; Value=(New-CcodObserved -SpecialObservation Confirmed -SpecialCandidates @($candidate)); Mutate={ param($value) $value.SpecialCandidates[0] | Add-Member -NotePropertyName Outcome -NotePropertyValue Confirmed } },
        @{ Name='fact-evidence'; Value=(New-CcodObserved -SpecialObservation Confirmed -SpecialCandidates @($candidate)); Mutate={ param($value) $value.SpecialCandidates[0].Evidence='Candidate' } },
        @{ Name='fact-validation'; Value=(New-CcodObserved -SpecialObservation Confirmed -SpecialCandidates @($candidate)); Mutate={ param($value) $value.SpecialCandidates[0].Validation='valid' } },
        @{ Name='special-process-extra'; Value=(New-CcodObserved -SpecialObservation Confirmed -SpecialCandidates @($candidate)); Mutate={ param($value) $value.SpecialCandidates[0].Process | Add-Member -NotePropertyName PrivateProof -NotePropertyValue secret } },
        @{ Name='special-process-mode'; Value=(New-CcodObserved -SpecialObservation Confirmed -SpecialCandidates @($candidate)); Mutate={ param($value) $value.SpecialCandidates[0].Process.Mode='Ordinary' } },
        @{ Name='special-process-port'; Value=(New-CcodObserved -SpecialObservation Confirmed -SpecialCandidates @($candidate)); Mutate={ param($value) $value.SpecialCandidates[0].Process.RendererPort=42001 } },
        @{ Name='ordinary-process-extra'; Value=(New-CcodObserved -OrdinaryCandidates @($ordinary)); Mutate={ param($value) $value.OrdinaryCandidates[0] | Add-Member -NotePropertyName PrivateData -NotePropertyValue secret } },
        @{ Name='ordinary-process-mode'; Value=(New-CcodObserved -OrdinaryCandidates @($ordinary)); Mutate={ param($value) $value.OrdinaryCandidates[0].Mode='Unrelated' } },
        @{ Name='ordinary-process-child'; Value=(New-CcodObserved -OrdinaryCandidates @($ordinary)); Mutate={ param($value) $value.OrdinaryCandidates[0].IsTopLevel=$false; $value.OrdinaryCandidates[0].ParentPid=100 } }
    )
    foreach ($case in $cases) {
        $value = Copy-CcodJournalValue $case.Value
        & $case.Mutate $value
        Assert-CcodThrows { Get-CcodReplayDecision -Transition $transition -Observed $value } 'CCOD_REPLAY_INPUT_INVALID'
    }
}

Invoke-CcodTest 'decides every StopRequested observation without performing either five-second wait' {
    $transition = New-CcodTransitionForStage -Stage StopRequested
    $ordinaryEarlyHighPid = New-CcodJournalSnapshot -ProcessId 302 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Ordinary
    $ordinaryEarlyLowPid = New-CcodJournalSnapshot -ProcessId 301 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Ordinary
    $ordinaryLate = New-CcodJournalSnapshot -ProcessId 300 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Ordinary
    $cases = @(
        @{ Observation='NotStarted'; Ordinary=@(); Action='ObserveStopRequested'; Reason='StopPrimaryObservationRequired'; Suppress=$false; Adopt=$null },
        @{ Observation='SameAliveAfterPrimary5s'; Ordinary=@(); Action='ObserveStopRequested'; Reason='StopGuardObservationRequired'; Suppress=$false; Adopt=$null },
        @{ Observation='ExitedDuringPrimary5s'; Ordinary=@(); Action='RecoverOrdinary'; Reason='StopCompletedRecoveryRequired'; Suppress=$true; Adopt=$null },
        @{ Observation='IdentityChangedDuringPrimary5s'; Ordinary=@($ordinaryLate,$ordinaryEarlyHighPid,$ordinaryEarlyLowPid); Action='AdoptOrdinaryRecovery'; Reason='StopCompletedOrdinaryAdopted'; Suppress=$true; Adopt=301 },
        @{ Observation='ExitedDuringGuard5s'; Ordinary=@(); Action='RecoverOrdinary'; Reason='StopCompletedRecoveryRequired'; Suppress=$true; Adopt=$null },
        @{ Observation='IdentityChangedDuringGuard5s'; Ordinary=@($ordinaryLate); Action='AdoptOrdinaryRecovery'; Reason='StopCompletedOrdinaryAdopted'; Suppress=$true; Adopt=300 },
        @{ Observation='SameAliveAfterGuard5s'; Ordinary=@(); Action='CancelKeepOrdinary'; Reason='SourceStillAliveAfterGuard'; Suppress=$false; Adopt=$null },
        @{ Observation='Indeterminate'; Ordinary=@(); Action='SuppressAndWaitForUser'; Reason='StopObservationIndeterminate'; Suppress=$true; Adopt=$null },
        @{ Observation='NotApplicable'; Ordinary=@(); Action='SuppressAndWaitForUser'; Reason='StopObservationNotApplicable'; Suppress=$true; Adopt=$null }
    )
    foreach ($case in $cases) {
        $observed = New-CcodObserved -StopObservation $case.Observation -OrdinaryCandidates $case.Ordinary
        $before = $observed | ConvertTo-Json -Depth 16 -Compress
        $decision = Get-CcodReplayDecision -Transition $transition -Observed $observed
        Assert-CcodEqual $case.Action $decision.Action "$($case.Observation) action"
        Assert-CcodEqual $case.Reason $decision.Reason "$($case.Observation) stable reason"
        Assert-CcodEqual $case.Suppress $decision.MustSuppress "$($case.Observation) suppression"
        if ($null -eq $case.Adopt) {
            Assert-CcodEqual $null $decision.AdoptedProcess "$($case.Observation) does not adopt"
        } else {
            Assert-CcodEqual $case.Adopt $decision.AdoptedProcess.Pid "$($case.Observation) stably adopts earliest CreationTimeUtc then PID"
            Assert-CcodEqual 'Pid,CreationTimeUtc,SessionId,UserSid,Path,PackageFamilyName,CommandLine,ParentPid,IsTopLevel,Mode,RendererPort,MainPort' `
                (($decision.AdoptedProcess.PSObject.Properties.Name) -join ',') 'adopted process is an exact copied snapshot'
        }
        Assert-CcodEqual $before ($observed | ConvertTo-Json -Depth 16 -Compress) "$($case.Observation) leaves observed facts unchanged"
    }
}

Invoke-CcodTest 'distinguishes safe absence from incomplete ambiguous and conflicting special evidence' {
    $valid = New-CcodSpecialFact -Validation Valid
    $invalid = New-CcodSpecialFact -Validation Invalid
    $indeterminate = New-CcodSpecialFact -Validation Indeterminate
    $second = New-CcodSpecialFact -Process (New-CcodJournalSnapshot -ProcessId 202 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002) -Validation Valid
    $cases = @(
        @{ Name='confirmed-valid'; Special='Confirmed'; Facts=@($valid); Action='AdoptValidatedSpecial'; Reason='SpecialValidated'; Suppress=$false; Adopt=201 },
        @{ Name='confirmed-invalid'; Special='Confirmed'; Facts=@($invalid); Action='TerminateSpecialThenRecover'; Reason='SpecialCandidateInvalid'; Suppress=$true; Adopt=201 },
        @{ Name='confirmed-indeterminate'; Special='Confirmed'; Facts=@($indeterminate); Action='SuppressAndWaitForUser'; Reason='SpecialValidationIndeterminate'; Suppress=$true; Adopt=$null },
        @{ Name='no-candidate'; Special='NoCandidate'; Facts=@(); Action='RecoverOrdinary'; Reason='SpecialCandidateAbsent'; Suppress=$true; Adopt=$null },
        @{ Name='incomplete-empty'; Special='Incomplete'; Facts=@(); Action='SuppressAndWaitForUser'; Reason='SpecialEnumerationIncomplete'; Suppress=$true; Adopt=$null },
        @{ Name='incomplete-valid'; Special='Incomplete'; Facts=@($valid); Action='SuppressAndWaitForUser'; Reason='SpecialEnumerationIncomplete'; Suppress=$true; Adopt=$null },
        @{ Name='incomplete-invalid'; Special='Incomplete'; Facts=@($invalid); Action='SuppressAndWaitForUser'; Reason='SpecialEnumerationIncomplete'; Suppress=$true; Adopt=$null },
        @{ Name='ambiguous'; Special='Ambiguous'; Facts=@($valid,$second); Action='SuppressAndWaitForUser'; Reason='SpecialCandidatesAmbiguous'; Suppress=$true; Adopt=$null },
        @{ Name='ambiguous-invalid'; Special='Ambiguous'; Facts=@($invalid,$second); Action='SuppressAndWaitForUser'; Reason='SpecialCandidatesAmbiguous'; Suppress=$true; Adopt=$null },
        @{ Name='port-conflict-empty'; Special='PortConflict'; Facts=@(); Action='SuppressAndWaitForUser'; Reason='SpecialPortConflict'; Suppress=$true; Adopt=$null },
        @{ Name='port-conflict-invalid'; Special='PortConflict'; Facts=@($invalid); Action='SuppressAndWaitForUser'; Reason='SpecialPortConflict'; Suppress=$true; Adopt=$null }
    )
    foreach ($stage in @('OrdinaryStopped','SpecialLaunchRequested')) {
        $transition = New-CcodTransitionForStage -Stage $stage -WithPorts
        foreach ($case in $cases) {
            $observed = New-CcodObserved -SpecialObservation $case.Special -SpecialCandidates $case.Facts -PortObservation Indeterminate
            $decision = Get-CcodReplayDecision -Transition $transition -Observed $observed
            Assert-CcodEqual $case.Action $decision.Action "$stage/$($case.Name) action"
            Assert-CcodEqual $case.Reason $decision.Reason "$stage/$($case.Name) stable reason"
            Assert-CcodEqual $case.Suppress $decision.MustSuppress "$stage/$($case.Name) suppression"
            if ($null -eq $case.Adopt) {
                Assert-CcodEqual $null $decision.AdoptedProcess "$stage/$($case.Name) does not select a candidate"
            } else {
                Assert-CcodEqual $case.Adopt $decision.AdoptedProcess.Pid "$stage/$($case.Name) returns the exact candidate to adopt or terminate"
            }
        }
    }
}

Invoke-CcodTest 'requires the exact journal special identity at SpecialStarted and Validated' {
    $exactProcess = New-CcodJournalSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
    $mismatchProcess = New-CcodJournalSnapshot -ProcessId 202 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
    $exactValid = New-CcodSpecialFact -Process $exactProcess -Evidence PersistedIdentity -Validation Valid
    $exactInvalid = New-CcodSpecialFact -Process $exactProcess -Evidence PersistedIdentity -Validation Invalid
    $exactIndeterminate = New-CcodSpecialFact -Process $exactProcess -Evidence PersistedIdentity -Validation Indeterminate
    $mismatchValid = New-CcodSpecialFact -Process $mismatchProcess -Evidence PersistedIdentity -Validation Valid
    $specialStarted = New-CcodTransitionForStage -Stage SpecialStarted -WithPorts -WithSpecial
    $validated = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
    $startedCases = @(
        @{ Name='exact-valid'; Special='Confirmed'; Facts=@($exactValid); Action='AdoptValidatedSpecial'; Reason='JournalSpecialValidated'; Suppress=$false; Adopt=201 },
        @{ Name='exact-invalid'; Special='Confirmed'; Facts=@($exactInvalid); Action='TerminateSpecialThenRecover'; Reason='JournalSpecialInvalid'; Suppress=$true; Adopt=201 },
        @{ Name='exact-indeterminate'; Special='Confirmed'; Facts=@($exactIndeterminate); Action='SuppressAndWaitForUser'; Reason='JournalSpecialIndeterminate'; Suppress=$true; Adopt=$null },
        @{ Name='mismatch'; Special='Confirmed'; Facts=@($mismatchValid); Action='SuppressAndWaitForUser'; Reason='JournalSpecialMismatch'; Suppress=$true; Adopt=$null },
        @{ Name='missing'; Special='NoCandidate'; Facts=@(); Action='RecoverOrdinary'; Reason='JournalSpecialMissing'; Suppress=$true; Adopt=$null },
        @{ Name='incomplete'; Special='Incomplete'; Facts=@(); Action='SuppressAndWaitForUser'; Reason='JournalSpecialIncomplete'; Suppress=$true; Adopt=$null },
        @{ Name='incomplete-invalid'; Special='Incomplete'; Facts=@($exactInvalid); Action='SuppressAndWaitForUser'; Reason='JournalSpecialIncomplete'; Suppress=$true; Adopt=$null },
        @{ Name='ambiguous'; Special='Ambiguous'; Facts=@($exactValid,$mismatchValid); Action='SuppressAndWaitForUser'; Reason='JournalSpecialAmbiguous'; Suppress=$true; Adopt=$null },
        @{ Name='ambiguous-invalid'; Special='Ambiguous'; Facts=@($exactInvalid,$mismatchValid); Action='SuppressAndWaitForUser'; Reason='JournalSpecialAmbiguous'; Suppress=$true; Adopt=$null },
        @{ Name='port-conflict-invalid'; Special='PortConflict'; Facts=@($exactInvalid); Action='SuppressAndWaitForUser'; Reason='JournalSpecialPortConflict'; Suppress=$true; Adopt=$null }
    )
    foreach ($case in $startedCases) {
        $decision = Get-CcodReplayDecision -Transition $specialStarted -Observed (New-CcodObserved -SpecialObservation $case.Special -SpecialCandidates $case.Facts -PortObservation Indeterminate)
        Assert-CcodEqual $case.Action $decision.Action "SpecialStarted/$($case.Name) action"
        Assert-CcodEqual $case.Reason $decision.Reason "SpecialStarted/$($case.Name) reason"
        Assert-CcodEqual $case.Suppress $decision.MustSuppress "SpecialStarted/$($case.Name) suppression"
        if ($null -eq $case.Adopt) { Assert-CcodEqual $null $decision.AdoptedProcess "SpecialStarted/$($case.Name) no adoption" }
        else { Assert-CcodEqual $case.Adopt $decision.AdoptedProcess.Pid "SpecialStarted/$($case.Name) exact returned process" }
    }

    $validatedCases = @(
        @{ Name='exact-valid'; Special='Confirmed'; Facts=@($exactValid); Action='AdoptValidatedSpecial'; Reason='ValidatedSpecialStillValid'; Suppress=$false; Adopt=201 },
        @{ Name='vanished'; Special='NoCandidate'; Facts=@(); Action='RecoverOrdinary'; Reason='ValidatedSpecialVanished'; Suppress=$true; Adopt=$null },
        @{ Name='exact-invalid'; Special='Confirmed'; Facts=@($exactInvalid); Action='SuppressAndWaitForUser'; Reason='ValidatedSpecialContradictory'; Suppress=$true; Adopt=$null },
        @{ Name='mismatch'; Special='Confirmed'; Facts=@($mismatchValid); Action='SuppressAndWaitForUser'; Reason='ValidatedSpecialContradictory'; Suppress=$true; Adopt=$null },
        @{ Name='incomplete'; Special='Incomplete'; Facts=@(); Action='SuppressAndWaitForUser'; Reason='ValidatedSpecialContradictory'; Suppress=$true; Adopt=$null },
        @{ Name='ambiguous'; Special='Ambiguous'; Facts=@($exactValid,$mismatchValid); Action='SuppressAndWaitForUser'; Reason='ValidatedSpecialContradictory'; Suppress=$true; Adopt=$null },
        @{ Name='port-conflict'; Special='PortConflict'; Facts=@(); Action='SuppressAndWaitForUser'; Reason='ValidatedSpecialContradictory'; Suppress=$true; Adopt=$null }
    )
    foreach ($case in $validatedCases) {
        $decision = Get-CcodReplayDecision -Transition $validated -Observed (New-CcodObserved -SpecialObservation $case.Special -SpecialCandidates $case.Facts -PortObservation Indeterminate)
        Assert-CcodEqual $case.Action $decision.Action "Validated/$($case.Name) action"
        Assert-CcodEqual $case.Reason $decision.Reason "Validated/$($case.Name) reason"
        Assert-CcodEqual $case.Suppress $decision.MustSuppress "Validated/$($case.Name) suppression"
        if ($null -eq $case.Adopt) { Assert-CcodEqual $null $decision.AdoptedProcess "Validated/$($case.Name) no adoption" }
        else { Assert-CcodEqual $case.Adopt $decision.AdoptedProcess.Pid "Validated/$($case.Name) exact returned process" }
    }
}

Invoke-CcodTest 'observes recovery once adopts ordinary roots and never erases incomplete special evidence' {
    $transition = New-CcodTransitionForStage -Stage RecoveryLaunchRequested
    $ordinaryEarlyHighPid = New-CcodJournalSnapshot -ProcessId 302 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Ordinary
    $ordinaryEarlyLowPid = New-CcodJournalSnapshot -ProcessId 301 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Ordinary
    $ordinaryLate = New-CcodJournalSnapshot -ProcessId 300 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Ordinary
    $cases = @(
        @{ Name='ordinary-appeared'; Recovery='OrdinaryAppearedWithin5s'; Special='NoCandidate'; Facts=@(); Ordinary=@($ordinaryLate,$ordinaryEarlyHighPid,$ordinaryEarlyLowPid); Action='AdoptOrdinaryRecovery'; Reason='RecoveryOrdinaryAdopted'; Suppress=$true; Adopt=301 },
        @{ Name='ordinary-before-observation'; Recovery='NotStarted'; Special='NoCandidate'; Facts=@(); Ordinary=@($ordinaryLate); Action='AdoptOrdinaryRecovery'; Reason='RecoveryOrdinaryAdopted'; Suppress=$true; Adopt=300 },
        @{ Name='observe-window'; Recovery='NotStarted'; Special='NoCandidate'; Facts=@(); Ordinary=@(); Action='RecoverOrdinary'; Reason='RecoveryObservationRequired'; Suppress=$true; Adopt=$null },
        @{ Name='launch-once'; Recovery='FiveSecondsElapsedNoOrdinary'; Special='NoCandidate'; Facts=@(); Ordinary=@(); Action='RecoverOrdinary'; Reason='RecoveryLaunchOnceRequired'; Suppress=$true; Adopt=$null },
        @{ Name='indeterminate'; Recovery='Indeterminate'; Special='NoCandidate'; Facts=@(); Ordinary=@(); Action='SuppressAndWaitForUser'; Reason='RecoveryObservationIndeterminate'; Suppress=$true; Adopt=$null },
        @{ Name='not-applicable'; Recovery='NotApplicable'; Special='NoCandidate'; Facts=@(); Ordinary=@(); Action='SuppressAndWaitForUser'; Reason='RecoveryObservationNotApplicable'; Suppress=$true; Adopt=$null },
        @{ Name='incomplete-not-empty'; Recovery='OrdinaryAppearedWithin5s'; Special='Incomplete'; Facts=@(); Ordinary=@($ordinaryLate); Action='SuppressAndWaitForUser'; Reason='RecoverySpecialEvidenceIncomplete'; Suppress=$true; Adopt=$null },
        @{ Name='port-conflict'; Recovery='NotStarted'; Special='PortConflict'; Facts=@(); Ordinary=@(); Action='SuppressAndWaitForUser'; Reason='RecoverySpecialPortConflict'; Suppress=$true; Adopt=$null }
    )
    foreach ($case in $cases) {
        $decision = Get-CcodReplayDecision -Transition $transition -Observed (New-CcodObserved -RecoveryObservation $case.Recovery -SpecialObservation $case.Special -SpecialCandidates $case.Facts -OrdinaryCandidates $case.Ordinary)
        Assert-CcodEqual $case.Action $decision.Action "$($case.Name) action"
        Assert-CcodEqual $case.Reason $decision.Reason "$($case.Name) reason"
        Assert-CcodEqual $case.Suppress $decision.MustSuppress "$($case.Name) suppression"
        if ($null -eq $case.Adopt) { Assert-CcodEqual $null $decision.AdoptedProcess "$($case.Name) no process selected" }
        else { Assert-CcodEqual $case.Adopt $decision.AdoptedProcess.Pid "$($case.Name) stable ordinary selection" }
    }

    $withSpecial = New-CcodTransitionForStage -Stage RecoveryLaunchRequested -WithPorts -WithSpecial
    $exact = New-CcodSpecialFact -Process (New-CcodJournalSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002) -Evidence PersistedIdentity -Validation Valid
    $exactDecision = Get-CcodReplayDecision -Transition $withSpecial -Observed (New-CcodObserved -RecoveryObservation NotStarted -SpecialObservation Confirmed -SpecialCandidates @($exact) -PortObservation Indeterminate)
    Assert-CcodEqual 'TerminateSpecialThenRecover' $exactDecision.Action 'exact journal special is terminated before recovery'
    Assert-CcodEqual 'RecoverySpecialStillAlive' $exactDecision.Reason 'exact live special has a stable recovery reason'
    Assert-CcodEqual 201 $exactDecision.AdoptedProcess.Pid 'termination action carries only the exact journal special snapshot'

    $exactInvalid = New-CcodSpecialFact -Process $exact.Process -Evidence PersistedIdentity -Validation Invalid
    $mismatch = New-CcodSpecialFact -Process (New-CcodJournalSnapshot -ProcessId 202 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002) -Evidence PersistedIdentity -Validation Valid
    $specialOutcomeCases = @(
        @{ Name='confirmed-invalid'; Special='Confirmed'; Facts=@($exactInvalid); Action='TerminateSpecialThenRecover'; Reason='RecoverySpecialStillAlive'; Adopt=201 },
        @{ Name='incomplete-invalid'; Special='Incomplete'; Facts=@($exactInvalid); Action='SuppressAndWaitForUser'; Reason='RecoverySpecialEvidenceIncomplete'; Adopt=$null },
        @{ Name='port-conflict-invalid'; Special='PortConflict'; Facts=@($exactInvalid); Action='SuppressAndWaitForUser'; Reason='RecoverySpecialPortConflict'; Adopt=$null },
        @{ Name='ambiguous-invalid'; Special='Ambiguous'; Facts=@($exactInvalid,$mismatch); Action='SuppressAndWaitForUser'; Reason='RecoverySpecialAmbiguous'; Adopt=$null }
    )
    foreach ($case in $specialOutcomeCases) {
        $decision = Get-CcodReplayDecision -Transition $withSpecial -Observed (New-CcodObserved -RecoveryObservation NotStarted -SpecialObservation $case.Special -SpecialCandidates $case.Facts -PortObservation Indeterminate)
        Assert-CcodEqual $case.Action $decision.Action "recovery/$($case.Name) action is dominated by the Task6 outcome"
        Assert-CcodEqual $case.Reason $decision.Reason "recovery/$($case.Name) stable reason"
        if ($null -eq $case.Adopt) { Assert-CcodEqual $null $decision.AdoptedProcess "recovery/$($case.Name) never selects incomplete evidence" }
        else { Assert-CcodEqual $case.Adopt $decision.AdoptedProcess.Pid "recovery/$($case.Name) preserves confirmed exact-journal termination" }
    }

    Assert-CcodThrows {
        Get-CcodReplayDecision -Transition $transition -Observed (New-CcodObserved -RecoveryObservation OrdinaryAppearedWithin5s)
    } 'CCOD_REPLAY_INPUT_INVALID'
}

Invoke-CcodTest 'completes Recovered without ever launching a second recovery process' {
    $transition = New-CcodTransitionForStage -Stage RecoveryLaunchRequested
    $transition.stage = 'Recovered'
    $transition.recoveryPid = 301
    $transition.recoveryCreationTimeUtc = '2030-02-03T04:05:09.0000000Z'
    $transition.updatedAtUtc = '2030-02-03T04:05:09.0000000Z'
    $journalRecovery = New-CcodJournalSnapshot -ProcessId 301 -CreationTimeUtc '2030-02-03T04:05:09.0000000Z' -Mode Ordinary
    $earlierOther = New-CcodJournalSnapshot -ProcessId 300 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Ordinary
    $laterOther = New-CcodJournalSnapshot -ProcessId 302 -CreationTimeUtc '2030-02-03T04:05:10.0000000Z' -Mode Ordinary

    $exact = Get-CcodReplayDecision -Transition $transition -Observed (New-CcodObserved -OrdinaryCandidates @($earlierOther,$journalRecovery,$laterOther))
    Assert-CcodEqual 'AdoptOrdinaryRecovery' $exact.Action 'journal recovery is adopted'
    Assert-CcodEqual 'JournalRecoveryAdopted' $exact.Reason 'exact journal recovery reason is stable'
    Assert-CcodEqual 301 $exact.AdoptedProcess.Pid 'journal identity wins over an earlier unrelated ordinary root'
    Assert-CcodEqual $true $exact.MustSuppress 'recovered failure remains suppressed'

    $fallback = Get-CcodReplayDecision -Transition $transition -Observed (New-CcodObserved -OrdinaryCandidates @($laterOther,$earlierOther))
    Assert-CcodEqual 'AdoptOrdinaryRecovery' $fallback.Action 'another exact ordinary root is safely adopted'
    Assert-CcodEqual 'StableOrdinaryFallbackAdopted' $fallback.Reason 'fallback reason is stable'
    Assert-CcodEqual 300 $fallback.AdoptedProcess.Pid 'fallback uses earliest CreationTimeUtc then PID'

    $missing = Get-CcodReplayDecision -Transition $transition -Observed (New-CcodObserved)
    Assert-CcodEqual 'CancelKeepOrdinary' $missing.Action 'missing recovered process completes without a second launch'
    Assert-CcodEqual 'RecoveredProcessAbsent' $missing.Reason 'missing recovery has a stable terminal reason'
    Assert-CcodEqual $null $missing.AdoptedProcess 'missing recovery selects no process'
    Assert-CcodEqual $true $missing.MustSuppress 'missing recovered process stays suppressed'

    $incomplete = Get-CcodReplayDecision -Transition $transition -Observed (New-CcodObserved -SpecialObservation Incomplete -OrdinaryCandidates @($journalRecovery))
    Assert-CcodEqual 'SuppressAndWaitForUser' $incomplete.Action 'incomplete special evidence blocks even an ordinary adoption'
    Assert-CcodEqual 'RecoveredSpecialContradictory' $incomplete.Reason 'recovered contradiction is stable'
}

Invoke-CcodTest 'archives clears and remains idempotent across module reload' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-complete-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    $completionAdapters = @{ UtcNow = { $completedUtc }.GetNewClosure() }
    $stateAdapters = @{
        UtcNow = { $completedUtc }.GetNewClosure()
        TestVerifiedNodeCandidate = { param($Path) $Path -eq 'C:\Node\node.exe' }
    }
    try {
        Initialize-CcodState -StateRoot (Join-Path $root 'state') -NodeCandidates @('C:\Node\node.exe') -Adapters $stateAdapters | Out-Null
        $path = Join-Path $root 'state\transition.json'
        $logPath = Join-Path $root 'logs\transactions.log'
        $transition = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
        Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$transition })

        $completed = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters $completionAdapters
        Assert-CcodEqual 'Outcome,ArchiveState,ArchiveErrorId' (($completed.PSObject.Properties.Name) -join ',') 'completion result has exact stable fields'
        Assert-CcodEqual 'Completed' $completed.Outcome 'first completion reports completed'
        Assert-CcodEqual 'Written' $completed.ArchiveState 'first archive is written'
        Assert-CcodEqual $null $completed.ArchiveErrorId 'successful archive has no error ID'
        Assert-CcodEqual $null (Read-CcodTransition -Path $path) 'successful completion clears active transaction'
        Assert-CcodEqual $true (Read-CcodState -StateRoot (Join-Path $root 'state') -Adapters $stateAdapters).TransitionActionsAllowed 'cleared Task 7 store cross-reads through StateStore'

        $receiptPath = Join-Path $root 'logs\transaction-completion.receipt.json'
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        Assert-CcodEqual 'schemaVersion,transactionId,disposition,terminalStage,completedAtUtc,state,archiveErrorId' (($receipt.PSObject.Properties.Name) -join ',') 'receipt has a fixed small schema'
        Assert-CcodEqual 'Archived' $receipt.state 'durable receipt records completed archival'
        Assert-CcodEqual $null $receipt.archiveErrorId 'archived receipt has no error ID'

        $records = @([IO.File]::ReadAllLines($logPath, [Text.UTF8Encoding]::new($false)) | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-CcodEqual 1 $records.Count 'first completion archives exactly one JSONL record'
        Assert-CcodEqual 'schemaVersion,transactionId,disposition,terminalStage,sourcePid,sourceCreationTimeUtc,specialPid,specialCreationTimeUtc,recoveryPid,recoveryCreationTimeUtc,appAsarSha256,runtimeId,completedAtUtc,archiveState' `
            (($records[0].PSObject.Properties.Name) -join ',') 'archive record is a fixed whitelist'
        Assert-CcodEqual 'Archived' $records[0].archiveState 'archive record is terminal'
        foreach ($forbidden in @('Path','CommandLine','Probe','Token','Key','Signature','packageFullName')) {
            Assert-CcodEqual $null $records[0].PSObject.Properties[$forbidden] "archive omits $forbidden"
        }

        $repeat = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters $completionAdapters
        Assert-CcodEqual 'AlreadyCompleted' $repeat.Outcome 'same-process retry is idempotent'
        Assert-CcodEqual 'PreviouslyWritten' $repeat.ArchiveState 'same-process retry reads durable evidence'
        Assert-CcodEqual 1 @([IO.File]::ReadAllLines($logPath)).Count 'same-process retry does not append'

        Remove-Module TransitionJournal -Force
        Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\TransitionJournal.psm1') -Force
        $reloadRepeat = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters $completionAdapters
        Assert-CcodEqual 'AlreadyCompleted' $reloadRepeat.Outcome 'module reload retry is idempotent from disk evidence'
        Assert-CcodEqual 'PreviouslyWritten' $reloadRepeat.ArchiveState 'reload retry preserves prior archive state'
        Assert-CcodEqual 1 @([IO.File]::ReadAllLines($logPath)).Count 'module reload retry does not append'
    } finally {
        if (Get-Module TransitionJournal) { Remove-Module TransitionJournal -Force }
        Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\TransitionJournal.psm1') -Force
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'replays every durable completion crash window without duplicate archival' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-crashes-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    try {
        $cases = @(
            @{ Point='AfterPreparedReceipt'; Receipt='Prepared'; LogCount=0; Active=$true; RetryOutcome='Completed'; RetryArchive='Written' },
            @{ Point='AfterArchiveAppend'; Receipt='Prepared'; LogCount=1; Active=$true; RetryOutcome='Completed'; RetryArchive='PreviouslyWritten' },
            @{ Point='AfterTerminalReceipt'; Receipt='Archived'; LogCount=1; Active=$true; RetryOutcome='Completed'; RetryArchive='PreviouslyWritten' },
            @{ Point='AfterClear'; Receipt='Archived'; LogCount=1; Active=$false; RetryOutcome='AlreadyCompleted'; RetryArchive='PreviouslyWritten' }
        )
        foreach ($case in $cases) {
            $caseRoot = Join-Path $root $case.Point
            $path = Join-Path $caseRoot 'state\transition.json'
            $logPath = Join-Path $caseRoot 'logs\transactions.log'
            $receiptPath = Join-Path $caseRoot 'logs\transaction-completion.receipt.json'
            $transition = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
            Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$transition })
            $point = $case.Point
            $crashAdapters = @{
                UtcNow = { $completedUtc }.GetNewClosure()
                Checkpoint = {
                    param([string]$Name)
                    if ($Name -ceq $point) {
                        throw [Management.Automation.ErrorRecord]::new(
                            [InvalidOperationException]::new("Injected crash at $Name"),
                            'CCOD_TEST_CRASH',
                            [Management.Automation.ErrorCategory]::OperationStopped,
                            $Name
                        )
                    }
                }.GetNewClosure()
            }
            Assert-CcodThrows {
                Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters $crashAdapters
            } 'CCOD_TEST_CRASH'
            Assert-CcodEqual $case.Active ($null -ne (Read-CcodTransition -Path $path)) "$($case.Point) active-state crash evidence"
            Assert-CcodEqual $case.Receipt ((Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).state) "$($case.Point) durable receipt state"
            $lineCount = if ([IO.File]::Exists($logPath)) { @([IO.File]::ReadAllLines($logPath)).Count } else { 0 }
            Assert-CcodEqual $case.LogCount $lineCount "$($case.Point) archived line count before replay"

            Remove-Module TransitionJournal -Force
            Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\TransitionJournal.psm1') -Force
            $retry = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() }
            Assert-CcodEqual $case.RetryOutcome $retry.Outcome "$($case.Point) retry outcome"
            Assert-CcodEqual $case.RetryArchive $retry.ArchiveState "$($case.Point) retry archive state"
            Assert-CcodEqual $null (Read-CcodTransition -Path $path) "$($case.Point) retry clears active state"
            Assert-CcodEqual 1 @([IO.File]::ReadAllLines($logPath)).Count "$($case.Point) retry leaves exactly one archive record"
        }
    } finally {
        if (Get-Module TransitionJournal) { Remove-Module TransitionJournal -Force }
        Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\TransitionJournal.psm1') -Force
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'clears a terminal receipt left active after recovery supersedes its stage' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-terminal-recovery-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    try {
        $path = Join-Path $root 'state\transition.json'
        $logPath = Join-Path $root 'logs\transactions.log'
        $validated = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
        Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$validated })
        Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $validated.transactionId -Disposition Activated -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() } | Out-Null

        $recovered = Copy-CcodJournalValue $validated
        $recovered.stage = 'Recovered'
        $recovered.recoveryPid = 301
        $recovered.recoveryCreationTimeUtc = '2030-02-03T04:05:09.0000000Z'
        $recovered.updatedAtUtc = '2030-02-03T04:05:09.0000000Z'
        Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$recovered })

        $result = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $validated.transactionId -Disposition Recovered -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() }
        Assert-CcodEqual 'Completed' $result.Outcome 'terminal receipt clears the stale active transaction'
        Assert-CcodEqual 'PreviouslyWritten' $result.ArchiveState 'terminal receipt preserves its prior archive evidence'
        Assert-CcodEqual $null (Read-CcodTransition -Path $path) 'terminal receipt leaves no replayable active transaction'
        $records = @([IO.File]::ReadAllLines($logPath) | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-CcodEqual 1 $records.Count 'terminal receipt does not duplicate the archive record'
        Assert-CcodEqual 'Activated' $records[0].disposition 'terminal receipt retains its original completed disposition'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'durably records archive failures and still clears the active transaction' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-log-failures-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    try {
        foreach ($case in @('append-failure','malformed-existing-log')) {
            $caseRoot = Join-Path $root $case
            $path = Join-Path $caseRoot 'state\transition.json'
            $logPath = Join-Path $caseRoot 'logs\transactions.log'
            $receiptPath = Join-Path $caseRoot 'logs\transaction-completion.receipt.json'
            $transition = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
            Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$transition })
            $adapters = @{ UtcNow={ $completedUtc }.GetNewClosure() }
            if ($case -ceq 'append-failure') {
                $adapters.WriteLog = {
                    param([string]$Path, [string]$Message)
                    throw [Management.Automation.ErrorRecord]::new(
                        [IO.IOException]::new('Injected log rotation failure'),
                        'CCOD_TEST_LOG_FAILURE',
                        [Management.Automation.ErrorCategory]::WriteError,
                        $Path
                    )
                }
            } else {
                [IO.Directory]::CreateDirectory((Split-Path -Path $logPath -Parent)) | Out-Null
                [IO.File]::WriteAllText($logPath, "not-json`r`n", [Text.UTF8Encoding]::new($false))
            }

            $result = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters $adapters
            Assert-CcodEqual 'Completed' $result.Outcome "$case completion still finishes"
            Assert-CcodEqual 'WriteFailed' $result.ArchiveState "$case returns stable archive failure state"
            Assert-CcodEqual 'CCOD_TRANSITION_ARCHIVE_FAILED' $result.ArchiveErrorId "$case returns only stable error ID"
            Assert-CcodEqual $null (Read-CcodTransition -Path $path) "$case clears active only after durable failure receipt"
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
            Assert-CcodEqual 'ArchiveFailed' $receipt.state "$case persists archive failure"
            Assert-CcodEqual 'CCOD_TRANSITION_ARCHIVE_FAILED' $receipt.archiveErrorId "$case receipt contains no raw exception"

            $repeat = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() }
            Assert-CcodEqual 'AlreadyCompleted' $repeat.Outcome "$case repeat is disk-idempotent"
            Assert-CcodEqual 'PreviouslyWritten' $repeat.ArchiveState "$case repeat reports prior durable receipt"
            Assert-CcodEqual 'CCOD_TRANSITION_ARCHIVE_FAILED' $repeat.ArchiveErrorId "$case repeat preserves stable failure ID"
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'deduplicates an older completion from parsed rotated log evidence after receipt rollover' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-old-receipt-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    $adapters = @{ UtcNow={ $completedUtc }.GetNewClosure() }
    try {
        $path = Join-Path $root 'state\transition.json'
        $logPath = Join-Path $root 'logs\transactions.log'
        $first = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
        Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$first })
        Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $first.transactionId -Disposition Activated -Adapters $adapters | Out-Null
        [IO.File]::Move($logPath, "$logPath.7")

        $second = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
        $second.transactionId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$second })
        Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $second.transactionId -Disposition Activated -Adapters $adapters | Out-Null

        $oldRepeat = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $first.transactionId -Disposition Activated -Adapters $adapters
        Assert-CcodEqual 'AlreadyCompleted' $oldRepeat.Outcome 'old transaction is found after current receipt rolls over'
        Assert-CcodEqual 'PreviouslyWritten' $oldRepeat.ArchiveState 'parsed generation evidence is durable completion proof'
        Assert-CcodEqual $null $oldRepeat.ArchiveErrorId 'old successful archive retains no error'
        Assert-CcodEqual 1 @([IO.File]::ReadAllLines($logPath)).Count 'current transaction log is not appended for old retry'
        Assert-CcodEqual 1 @([IO.File]::ReadAllLines("$logPath.7")).Count 'rotated old transaction remains one exact record'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'rejects relative noncanonical and colliding completion paths before any IO' {
    $absolutePath = Join-Path ([IO.Path]::GetTempPath()) 'ccod-path-validation\state\transition.json'
    $absoluteLog = Join-Path ([IO.Path]::GetTempPath()) 'ccod-path-validation\logs\transactions.log'
    $noncanonicalLog = Join-Path (Split-Path -Path $absoluteLog -Parent) '..\logs\transactions.log'
    $sentinel = @{
        FileExists = { param([string]$Path) throw 'CCOD_TEST_IO_TOUCHED' }
        ReadJson = { param([string]$Path) throw 'CCOD_TEST_IO_TOUCHED' }
        WriteJson = { param([string]$Path, $Value) throw 'CCOD_TEST_IO_TOUCHED' }
        WriteLog = { param([string]$Path, [string]$Message) throw 'CCOD_TEST_IO_TOUCHED' }
        ReadAllLines = { param([string]$Path) throw 'CCOD_TEST_IO_TOUCHED' }
        UtcNow = { throw 'CCOD_TEST_IO_TOUCHED' }
    }
    $cases = @(
        @{ Name='relative transition'; Path='state\transition.json'; LogPath=$absoluteLog },
        @{ Name='relative log'; Path=$absolutePath; LogPath='logs\transactions.log' },
        @{ Name='noncanonical log'; Path=$absolutePath; LogPath=$noncanonicalLog },
        @{ Name='colliding paths'; Path=$absolutePath; LogPath=$absolutePath },
        @{ Name='receipt collision'; Path=$absolutePath; LogPath=(Join-Path (Split-Path -Path $absoluteLog -Parent) 'transaction-completion.receipt.json') }
    )
    foreach ($case in $cases) {
        Assert-CcodThrows {
            Complete-CcodTransition -Path $case.Path -LogPath $case.LogPath -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda' -Disposition Activated -Adapters $sentinel
        } 'CCOD_TRANSITION_COMPLETION_INVALID'
    }
}

Invoke-CcodTest 'never claims completion when a receipt or clear write fails' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-write-failures-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    try {
        $cases = @(
            @{ Phase='Prepared'; Receipt=$null; LogCount=0 },
            @{ Phase='Terminal'; Receipt='Prepared'; LogCount=1 },
            @{ Phase='Clear'; Receipt='Archived'; LogCount=1 }
        )
        foreach ($case in $cases) {
            $caseRoot = Join-Path $root $case.Phase
            $path = Join-Path $caseRoot 'state\transition.json'
            $logPath = Join-Path $caseRoot 'logs\transactions.log'
            $receiptPath = Join-Path $caseRoot 'logs\transaction-completion.receipt.json'
            $transition = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
            Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$transition })
            $phase = $case.Phase
            $writeAdapters = @{
                UtcNow = { $completedUtc }.GetNewClosure()
                WriteJson = {
                    param([string]$TargetPath, $Value)
                    $isReceipt = [IO.Path]::GetFileName($TargetPath) -ieq 'transaction-completion.receipt.json'
                    $isClear = -not $isReceipt -and $null -eq $Value.activeTransaction
                    $shouldFail = ($phase -ceq 'Prepared' -and $isReceipt -and $Value.state -ceq 'Prepared') -or
                        ($phase -ceq 'Terminal' -and $isReceipt -and $Value.state -ceq 'Archived') -or
                        ($phase -ceq 'Clear' -and $isClear)
                    if ($shouldFail) {
                        throw [Management.Automation.ErrorRecord]::new(
                            [IO.IOException]::new("Injected $phase write failure"),
                            'CCOD_TEST_WRITE_FAILURE',
                            [Management.Automation.ErrorCategory]::WriteError,
                            $TargetPath
                        )
                    }
                    [IO.Directory]::CreateDirectory((Split-Path -Path $TargetPath -Parent)) | Out-Null
                    [IO.File]::WriteAllText($TargetPath, (($Value | ConvertTo-Json -Depth 16) + "`n"), [Text.UTF8Encoding]::new($false))
                }.GetNewClosure()
            }
            Assert-CcodThrows {
                Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters $writeAdapters
            } 'CCOD_TEST_WRITE_FAILURE'
            Assert-CcodTrue ($null -ne (Read-CcodTransition -Path $path)) "$($case.Phase) failure keeps active transaction"
            if ($null -eq $case.Receipt) {
                Assert-CcodEqual $false ([IO.File]::Exists($receiptPath)) 'Prepared failure has no false receipt'
            } else {
                Assert-CcodEqual $case.Receipt ((Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).state) "$($case.Phase) preserves prior durable receipt stage"
            }
            $lineCount = if ([IO.File]::Exists($logPath)) { @([IO.File]::ReadAllLines($logPath)).Count } else { 0 }
            Assert-CcodEqual $case.LogCount $lineCount "$($case.Phase) failure archive count"

            $retry = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() }
            Assert-CcodEqual 'Completed' $retry.Outcome "$($case.Phase) retry completes only after a successful clear"
            Assert-CcodEqual $null (Read-CcodTransition -Path $path) "$($case.Phase) retry clears active"
            Assert-CcodEqual 1 @([IO.File]::ReadAllLines($logPath)).Count "$($case.Phase) retry leaves one archive"
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'never deduplicates semantically invalid exact-ID archive evidence' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-invalid-archive-' + [guid]::NewGuid().ToString('N'))
    $completedAt = '2030-02-03T04:06:00.0000000Z'
    try {
        $path = Join-Path $root 'state\transition.json'
        $logPath = Join-Path $root 'logs\transactions.log'
        $receiptPath = Join-Path $root 'logs\transaction-completion.receipt.json'
        $transition = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
        Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$transition })
        Write-CcodJournalJson -Path $receiptPath -Value ([ordered]@{
            schemaVersion=1; transactionId=$transition.transactionId; disposition='Activated'; terminalStage='Validated'
            completedAtUtc=$completedAt; state='Prepared'; archiveErrorId=$null
        })
        $invalidRecord = [ordered]@{
            schemaVersion=1; transactionId=$transition.transactionId; disposition='Activated'; terminalStage='Validated'
            sourcePid=$transition.sourcePid; sourceCreationTimeUtc=$transition.sourceCreationTimeUtc
            specialPid=$transition.specialPid; specialCreationTimeUtc=$transition.specialCreationTimeUtc
            recoveryPid=$null; recoveryCreationTimeUtc=$null; appAsarSha256=('A' * 64); runtimeId=$transition.runtimeId
            completedAtUtc=$completedAt; archiveState='Archived'
        }
        [IO.File]::WriteAllText($logPath, (($invalidRecord | ConvertTo-Json -Compress) + "`r`n"), [Text.UTF8Encoding]::new($false))

        $result = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters @{ UtcNow={ [DateTime]::Parse($completedAt).ToUniversalTime() } }
        Assert-CcodEqual 'Completed' $result.Outcome 'invalid archive evidence still completes through durable failure receipt'
        Assert-CcodEqual 'WriteFailed' $result.ArchiveState 'invalid exact-ID archive is not trusted as prior success'
        Assert-CcodEqual 'CCOD_TRANSITION_ARCHIVE_FAILED' $result.ArchiveErrorId 'invalid archive exposes only stable error ID'
        Assert-CcodEqual 'ArchiveFailed' ((Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).state) 'invalid archive result is durable before clear'
        Assert-CcodEqual $null (Read-CcodTransition -Path $path) 'invalid archive still clears after failure receipt'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'supports each terminal disposition rejects mismatches and exports only five public functions' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-dispositions-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    try {
        $cases = @(
            @{ Name='cancel-intent'; Disposition='Cancelled'; Tx=(New-CcodTransitionForStage -Stage IntentWritten); Bad='Activated' },
            @{ Name='cancel-stop'; Disposition='Cancelled'; Tx=(New-CcodTransitionForStage -Stage StopRequested); Bad='Recovered' },
            @{ Name='activate'; Disposition='Activated'; Tx=(New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial); Bad='Cancelled' }
        )
        $recovered = New-CcodTransitionForStage -Stage RecoveryLaunchRequested
        $recovered.stage = 'Recovered'
        $recovered.recoveryPid = 301
        $recovered.recoveryCreationTimeUtc = '2030-02-03T04:05:09.0000000Z'
        $recovered.updatedAtUtc = '2030-02-03T04:05:09.0000000Z'
        $cases += @{ Name='recover'; Disposition='Recovered'; Tx=$recovered; Bad='Activated' }
        foreach ($case in $cases) {
            $caseRoot = Join-Path $root $case.Name
            $path = Join-Path $caseRoot 'state\transition.json'
            $logPath = Join-Path $caseRoot 'logs\transactions.log'
            Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$case.Tx })
            Assert-CcodThrows {
                Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $case.Tx.transactionId -Disposition $case.Bad -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() }
            } 'CCOD_TRANSITION_COMPLETION_INVALID'
            Assert-CcodTrue ($null -ne (Read-CcodTransition -Path $path)) "$($case.Name) invalid disposition writes nothing"
            $result = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $case.Tx.transactionId -Disposition $case.Disposition -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() }
            Assert-CcodEqual 'Completed' $result.Outcome "$($case.Name) legal disposition completes"
        }
        Assert-CcodEqual 'Complete-CcodTransition,Get-CcodReplayDecision,New-CcodTransition,Read-CcodTransition,Set-CcodTransitionStage' `
            ((Get-Command -Module TransitionJournal | Sort-Object Name | ForEach-Object Name) -join ',') 'module exports exactly the five planned functions'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'uses the bounded 2 MiB ten-generation transaction log through completion' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-rotation-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    try {
        $path = Join-Path $root 'state\transition.json'
        $logPath = Join-Path $root 'logs\transactions.log'
        $transition = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
        Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$transition })
        [IO.Directory]::CreateDirectory((Split-Path -Path $logPath -Parent)) | Out-Null
        $prefix = '{"transactionId":"older","padding":"'
        $suffix = '"}'
        $paddingLength = 2MB - $prefix.Length - $suffix.Length - 16
        [IO.File]::WriteAllText($logPath, ($prefix + ('x' * $paddingLength) + $suffix + "`r`n"), [Text.UTF8Encoding]::new($false))
        for ($generation = 1; $generation -le 10; $generation++) {
            [IO.File]::WriteAllText("$logPath.$generation", ("{`"transactionId`":`"older-$generation`"}`r`n"), [Text.UTF8Encoding]::new($false))
        }

        $result = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() }
        Assert-CcodEqual 'Completed' $result.Outcome 'bounded log completion succeeds'
        Assert-CcodEqual 'Written' $result.ArchiveState 'new archive is written after rotation'
        $history = @(Get-ChildItem -LiteralPath (Split-Path -Path $logPath -Parent) -File | Where-Object { $_.Name -match '^transactions\.log\.\d+$' })
        Assert-CcodEqual 10 $history.Count 'completion retains at most ten historical generations'
        Assert-CcodTrue ([IO.File]::Exists("$logPath.10")) 'generation ten is retained'
        Assert-CcodTrue (-not [IO.File]::Exists("$logPath.11")) 'generation eleven is never retained'
        Assert-CcodTrue ((Get-Item -LiteralPath $logPath).Length -le 2MB) 'current transaction log remains bounded'
        Assert-CcodTrue ((Get-Item -LiteralPath "$logPath.1").Length -le 2MB) 'rotated transaction log remains bounded'
        Assert-CcodEqual $transition.transactionId (([IO.File]::ReadAllText($logPath) | ConvertFrom-Json).transactionId) 'new current log contains the completion record'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'resumes a durable ArchiveFailed receipt as Completed WriteFailed before clear' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-failed-receipt-crash-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    try {
        $path = Join-Path $root 'state\transition.json'
        $logPath = Join-Path $root 'logs\transactions.log'
        $transition = New-CcodTransitionForStage -Stage Validated -WithPorts -WithSpecial
        Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$transition })
        $adapters = @{
            UtcNow = { $completedUtc }.GetNewClosure()
            WriteLog = { param([string]$Path, [string]$Message) throw 'CCOD_TEST_LOG_FAIL_BEFORE_APPEND' }
            Checkpoint = {
                param([string]$Name)
                if ($Name -ceq 'AfterTerminalReceipt') {
                    throw [Management.Automation.ErrorRecord]::new(
                        [InvalidOperationException]::new('Crash after ArchiveFailed receipt'),
                        'CCOD_TEST_CRASH',
                        [Management.Automation.ErrorCategory]::OperationStopped,
                        $Name
                    )
                }
            }
        }
        Assert-CcodThrows {
            Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters $adapters
        } 'CCOD_TEST_CRASH'
        Assert-CcodEqual 'ArchiveFailed' ((Get-Content -LiteralPath (Join-Path $root 'logs\transaction-completion.receipt.json') -Raw | ConvertFrom-Json).state) 'failed receipt is durable before crash'
        Assert-CcodTrue ($null -ne (Read-CcodTransition -Path $path)) 'active transition remains before clear'

        $retry = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $transition.transactionId -Disposition Activated -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() }
        Assert-CcodEqual 'Completed' $retry.Outcome 'retry finishes the pending clear'
        Assert-CcodEqual 'WriteFailed' $retry.ArchiveState 'retry preserves actual failed archive result'
        Assert-CcodEqual 'CCOD_TRANSITION_ARCHIVE_FAILED' $retry.ArchiveErrorId 'retry exposes stable archive failure ID'
        Assert-CcodEqual $null (Read-CcodTransition -Path $path) 'retry clears after durable failed receipt'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'advances exact durable close edges with special injection and fixed fifteen fields' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-close-edges-' + [guid]::NewGuid().ToString('N'))
    $special = New-CcodJournalSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
    try {
        $ordinaryPath = Join-Path $root 'ordinary.json'
        $ordinary = New-CcodTransitionForStage -Stage IntentWritten
        $ordinary.mainPort = $null
        $ordinary.rendererPort = $null
        Write-CcodJournalJson -Path $ordinaryPath -Value ([ordered]@{ schemaVersion=1; activeTransaction=$ordinary })
        $ordinaryRequested = Set-CcodTransitionStage -Path $ordinaryPath -TransactionId $ordinary.transactionId -ExpectedStage IntentWritten -NewStage CloseRequested -Adapters $fixedAdapters
        Assert-CcodEqual 'CloseRequested' $ordinaryRequested.stage 'ordinary close request is durable before stop'
        Assert-CcodEqual 15 @($ordinaryRequested.PSObject.Properties).Count 'ordinary close adds no transition field'
        Assert-CcodEqual $null $ordinaryRequested.specialPid 'ordinary close preserves source-only target'
        $ordinaryClosed = Set-CcodTransitionStage -Path $ordinaryPath -TransactionId $ordinary.transactionId -ExpectedStage CloseRequested -NewStage Closed -Adapters $fixedAdapters
        Assert-CcodEqual 'Closed' $ordinaryClosed.stage 'ordinary close reaches terminal Closed'

        $specialPath = Join-Path $root 'special.json'
        $specialIntent = New-CcodTransitionForStage -Stage IntentWritten -Manual -WithPorts
        Write-CcodJournalJson -Path $specialPath -Value ([ordered]@{ schemaVersion=1; activeTransaction=$specialIntent })
        $specialRequested = Set-CcodTransitionStage -Path $specialPath -TransactionId $specialIntent.transactionId -ExpectedStage IntentWritten -NewStage CloseRequested -SpecialIdentity $special -Adapters $fixedAdapters
        Assert-CcodEqual 201 $specialRequested.specialPid 'special close injects exact existing identity on the durable close edge'
        Assert-CcodEqual 15 @($specialRequested.PSObject.Properties).Count 'special close adds no transition field'
        $specialClosed = Set-CcodTransitionStage -Path $specialPath -TransactionId $specialIntent.transactionId -ExpectedStage CloseRequested -NewStage Closed -Adapters $fixedAdapters
        Assert-CcodEqual 201 $specialClosed.specialPid 'Closed preserves the exact special identity'

        $illegalPath = Join-Path $root 'illegal.json'
        Write-CcodJournalJson -Path $illegalPath -Value ([ordered]@{ schemaVersion=1; activeTransaction=(New-CcodTransitionForStage -Stage IntentWritten -Manual -WithPorts) })
        Assert-CcodThrows {
            Set-CcodTransitionStage -Path $illegalPath -TransactionId $specialIntent.transactionId -ExpectedStage IntentWritten -NewStage StopRequested -SpecialIdentity $special -Adapters $fixedAdapters
        } 'CCOD_TRANSITION_STAGE_INVALID'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'decides close replay from exact root and explicit port observation without recovery launch' {
    $specialProcess = New-CcodJournalSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
    $specialFact = New-CcodSpecialFact -Process $specialProcess -Evidence PersistedIdentity -Validation Indeterminate
    $specialClose = New-CcodTransitionForStage -Stage CloseRequested -Manual -WithPorts -WithSpecial
    $liveSpecial = Get-CcodReplayDecision -Transition $specialClose -Observed (New-CcodObserved -StopObservation CloseTreePresent -SpecialObservation Confirmed -SpecialCandidates @($specialFact) -PortObservation Open)
    Assert-CcodEqual 'CloseRecordedTree' $liveSpecial.Action 'exact recorded special tree is closed even when renderer validation is broken'
    Assert-CcodEqual 201 $liveSpecial.AdoptedProcess.Pid 'close action carries only the exact recorded root'
    Assert-CcodEqual $false $liveSpecial.MustSuppress 'exact close target does not itself imply recovery suppression'

    $coldSpecialGone = Get-CcodReplayDecision -Transition $specialClose -Observed (New-CcodObserved -StopObservation CloseTreeIndeterminate -SpecialObservation NoCandidate -PortObservation BothRefused)
    Assert-CcodEqual 'SuppressAndWaitForUser' $coldSpecialGone.Action 'cold replay cannot promote a missing root to complete-tree absence'
    $specialGone = Get-CcodReplayDecision -Transition $specialClose -Observed (New-CcodObserved -StopObservation CloseTreeAbsent -SpecialObservation NoCandidate -PortObservation BothRefused)
    Assert-CcodEqual 'CompleteClosed' $specialGone.Action 'retained verified special tree plus two explicit refusals completes close'
    Assert-CcodEqual $null $specialGone.AdoptedProcess 'completed close performs no process action'

    $ordinary = New-CcodJournalSnapshot -ProcessId 100 -CreationTimeUtc '2030-02-03T04:00:00.0000000Z' -Mode Ordinary
    $ordinaryClose = New-CcodTransitionForStage -Stage CloseRequested
    $ordinaryClose.mainPort = $null
    $ordinaryClose.rendererPort = $null
    $liveOrdinary = Get-CcodReplayDecision -Transition $ordinaryClose -Observed (New-CcodObserved -StopObservation CloseTreePresent -OrdinaryCandidates @($ordinary) -PortObservation NotApplicable)
    Assert-CcodEqual 'CloseRecordedTree' $liveOrdinary.Action 'exact recorded ordinary root is closed without a port requirement'
    $coldOrdinaryGone = Get-CcodReplayDecision -Transition $ordinaryClose -Observed (New-CcodObserved -StopObservation CloseTreeIndeterminate -PortObservation NotApplicable)
    Assert-CcodEqual 'SuppressAndWaitForUser' $coldOrdinaryGone.Action 'cold ordinary close remains indeterminate when the recorded root is already gone'
    $ordinaryGone = Get-CcodReplayDecision -Transition $ordinaryClose -Observed (New-CcodObserved -StopObservation CloseTreeAbsent -PortObservation NotApplicable)
    Assert-CcodEqual 'CompleteClosed' $ordinaryGone.Action 'retained verified ordinary target completes when ports are inapplicable'

    foreach ($case in @(
        @{ Name='open-port'; Observed=(New-CcodObserved -StopObservation CloseTreeIndeterminate -PortObservation Open) },
        @{ Name='indeterminate-port'; Observed=(New-CcodObserved -StopObservation CloseTreeIndeterminate -PortObservation Indeterminate) },
        @{ Name='incomplete-tree'; Observed=(New-CcodObserved -StopObservation CloseTreeIndeterminate -SpecialObservation Incomplete -PortObservation BothRefused) },
        @{ Name='mismatched-tree'; Observed=(New-CcodObserved -StopObservation CloseTreeIndeterminate -SpecialObservation Confirmed -SpecialCandidates @((New-CcodSpecialFact -Process (New-CcodJournalSnapshot -ProcessId 202 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002))) -PortObservation Open) }
    )) {
        $decision = Get-CcodReplayDecision -Transition $specialClose -Observed $case.Observed
        Assert-CcodEqual 'SuppressAndWaitForUser' $decision.Action "$($case.Name) never reinterprets unsafe close evidence as absence"
    }

    $closed = Copy-CcodJournalValue $specialClose
    $closed.stage = 'Closed'
    $terminal = Get-CcodReplayDecision -Transition $closed -Observed (New-CcodObserved -StopObservation CloseTreeAbsent -SpecialObservation NoCandidate -PortObservation Indeterminate)
    Assert-CcodEqual 'CompleteClosed' $terminal.Action 'durable Closed performs archival only'
    Assert-CcodTrue ($terminal.Action -cnotmatch 'Recover|Launch') 'close replay action set never requests ordinary recovery'
}

Invoke-CcodTest 'enforces the close observed-fact XOR matrix without weakening normal replay' {
    $specialClose = New-CcodTransitionForStage -Stage CloseRequested -Manual -WithPorts -WithSpecial
    $specialFact = New-CcodSpecialFact -Process (New-CcodJournalSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002) -Evidence PersistedIdentity -Validation Indeterminate
    $ordinaryClose = New-CcodTransitionForStage -Stage CloseRequested
    $ordinary = New-CcodJournalSnapshot
    $normal = New-CcodTransitionForStage -Stage StopRequested

    foreach ($case in @(
        @{ Name='close uses normal stop enum'; Transition=$specialClose; Observed=(New-CcodObserved -StopObservation NotApplicable -PortObservation BothRefused) },
        @{ Name='present lacks exact target'; Transition=$specialClose; Observed=(New-CcodObserved -StopObservation CloseTreePresent -PortObservation Open) },
        @{ Name='absent carries a target'; Transition=$specialClose; Observed=(New-CcodObserved -StopObservation CloseTreeAbsent -SpecialObservation Confirmed -SpecialCandidates @($specialFact) -PortObservation BothRefused) },
        @{ Name='special close carries ordinary candidate'; Transition=$specialClose; Observed=(New-CcodObserved -StopObservation CloseTreePresent -OrdinaryCandidates @($ordinary) -PortObservation Open) },
        @{ Name='ordinary close carries special candidate'; Transition=$ordinaryClose; Observed=(New-CcodObserved -StopObservation CloseTreePresent -SpecialObservation Confirmed -SpecialCandidates @($specialFact) -PortObservation NotApplicable) },
        @{ Name='normal replay uses close stop enum'; Transition=$normal; Observed=(New-CcodObserved -StopObservation CloseTreeIndeterminate) },
        @{ Name='normal replay uses close port evidence with null pair'; Transition=$normal; Observed=(New-CcodObserved -PortObservation BothRefused) }
    )) {
        Assert-CcodThrows { Get-CcodReplayDecision -Transition $case.Transition -Observed $case.Observed } 'CCOD_REPLAY_INPUT_INVALID'
    }

    $legalNormal = Get-CcodReplayDecision -Transition $normal -Observed (New-CcodObserved -StopObservation NotStarted)
    Assert-CcodEqual 'ObserveStopRequested' $legalNormal.Action 'normal replay retains its existing observed-fact domain'

    $normalWithPorts = New-CcodTransitionForStage -Stage SpecialStarted -WithPorts -WithSpecial
    $normalFact = New-CcodSpecialFact -Process (New-CcodJournalSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002) -Evidence PersistedIdentity -Validation Valid
    $legalPairedNormal = Get-CcodReplayDecision -Transition $normalWithPorts -Observed (New-CcodObserved -SpecialObservation Confirmed -SpecialCandidates @($normalFact) -PortObservation Open)
    Assert-CcodEqual 'AdoptValidatedSpecial' $legalPairedNormal.Action 'paired normal replay validates then ignores the semantically valid port observation'

    foreach ($port in @('Open','BothRefused','Indeterminate')) {
        $closed = Copy-CcodJournalValue $specialClose
        $closed.stage = 'Closed'
        $decision = Get-CcodReplayDecision -Transition $closed -Observed (New-CcodObserved -StopObservation CloseTreeAbsent -PortObservation $port)
        Assert-CcodEqual 'CompleteClosed' $decision.Action "Closed archives with paired-port observation $port"
    }
}

Invoke-CcodTest 'completes and deduplicates Closed through the existing durable receipt windows' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-close-completion-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    try {
        $path = Join-Path $root 'state\transition.json'
        $logPath = Join-Path $root 'logs\transactions.log'
        $closed = New-CcodTransitionForStage -Stage Closed -Manual -WithPorts -WithSpecial
        Write-CcodJournalJson -Path $path -Value ([ordered]@{ schemaVersion=1; activeTransaction=$closed })
        $first = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $closed.transactionId -Disposition Closed -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() }
        Assert-CcodEqual 'Completed' $first.Outcome 'Closed completion archives and clears'
        Assert-CcodEqual $null (Read-CcodTransition -Path $path) 'Closed completion clears active evidence'
        $repeat = Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $closed.transactionId -Disposition Closed -Adapters @{ UtcNow={ $completedUtc }.GetNewClosure() }
        Assert-CcodEqual 'AlreadyCompleted' $repeat.Outcome 'Closed completion is disk-idempotent'
        Assert-CcodEqual 1 @([IO.File]::ReadAllLines($logPath)).Count 'Closed completion archives exactly once'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'replays every Closed completion crash window with the fixed archive whitelist' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-journal-close-crashes-' + [guid]::NewGuid().ToString('N'))
    $completedUtc = [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime()
    try {
        foreach($case in @(
            @{Point='AfterPreparedReceipt';Active=$true},
            @{Point='AfterArchiveAppend';Active=$true},
            @{Point='AfterTerminalReceipt';Active=$true},
            @{Point='AfterClear';Active=$false}
        )){
            $caseRoot=Join-Path $root $case.Point;$path=Join-Path $caseRoot 'state\transition.json';$logPath=Join-Path $caseRoot 'logs\transactions.log'
            $closed=New-CcodTransitionForStage -Stage Closed -Manual -WithPorts -WithSpecial
            Write-CcodJournalJson -Path $path -Value ([ordered]@{schemaVersion=1;activeTransaction=$closed})
            $point=$case.Point;$adapters=@{UtcNow={$completedUtc}.GetNewClosure();Checkpoint={param($Name)if($Name -ceq $point){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('close crash'),'CCOD_TEST_CRASH',[Management.Automation.ErrorCategory]::OperationStopped,$Name)}}.GetNewClosure()}
            Assert-CcodThrows {Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $closed.transactionId -Disposition Closed -Adapters $adapters} 'CCOD_TEST_CRASH'
            Assert-CcodEqual $case.Active ($null -ne (Read-CcodTransition -Path $path)) "$($case.Point) preserves the expected active close evidence"
            Remove-Module TransitionJournal -Force;Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\TransitionJournal.psm1') -Force
            $retry=Complete-CcodTransition -Path $path -LogPath $logPath -TransactionId $closed.transactionId -Disposition Closed -Adapters @{UtcNow={$completedUtc}.GetNewClosure()}
            Assert-CcodTrue (@('Completed','AlreadyCompleted') -ccontains $retry.Outcome) "$($case.Point) retry closes idempotently"
            $records=@([IO.File]::ReadAllLines($logPath)|ForEach-Object{$_|ConvertFrom-Json});Assert-CcodEqual 1 $records.Count "$($case.Point) leaves one close archive record"
            Assert-CcodEqual 'schemaVersion,transactionId,disposition,terminalStage,sourcePid,sourceCreationTimeUtc,specialPid,specialCreationTimeUtc,recoveryPid,recoveryCreationTimeUtc,appAsarSha256,runtimeId,completedAtUtc,archiveState' (($records[0].PSObject.Properties.Name)-join ',') "$($case.Point) close archive remains fixed whitelist"
            Assert-CcodEqual 'Closed' $records[0].disposition "$($case.Point) archive disposition remains Closed"
        }
    } finally {
        if(Get-Module TransitionJournal){Remove-Module TransitionJournal -Force};Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\TransitionJournal.psm1') -Force
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    }
}
