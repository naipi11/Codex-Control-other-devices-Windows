$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$installLifecycleModule = Join-Path $repositoryRoot 'src\persistence\modules\InstallLifecycle.psm1'
if (-not (Test-Path -LiteralPath $installLifecycleModule -PathType Leaf)) {
    throw "InstallLifecycle module is missing: $installLifecycleModule"
}
Import-Module $installLifecycleModule -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\StateStore.psm1') -Force

function New-CcodLifecycleTempRoot {
    return (Join-Path ([IO.Path]::GetTempPath()) ("ccod-lifecycle-" + [guid]::NewGuid().ToString('N')))
}

function New-CcodLifecycleSourceFixture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Version = '2.0.0-test'
    )

    New-Item -ItemType Directory -Path (Join-Path $Root 'src\runtime') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'src\persistence\modules') -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $Root 'package.json'),
        (@{ name = 'codex-control-other-devices-windows'; version = $Version; private = $true } | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )
    foreach ($leaf in @('Test-CodexControlOtherDevices.ps1', 'Start-CodexControlOtherDevices.ps1', 'Reset-CodexControlOtherDevices.ps1')) {
        [IO.File]::WriteAllText((Join-Path $Root $leaf), "# $leaf`r`nWrite-Output 'fixture'`r`n", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $Root 'src\check-package.mjs'), "export default 'fixture';`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\runtime\orchestrator.js'), "module.exports = 'fixture';`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\runtime\main-payload.js'), "module.exports = 'fixture-$Version';`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\runtime\renderer-payload.js'), "module.exports = 'fixture';`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\runtime\cdp.js'), "module.exports = 'fixture';`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\Supervisor.ps1'), "# Supervisor fixture $Version`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\SessionController.ps1'), "# Controller fixture`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\StaticProbeWorker.ps1'), "# Worker fixture`r`n", [Text.UTF8Encoding]::new($false))
    foreach ($module in @('PersistenceIO.psm1', 'RuntimeManifest.psm1', 'CompatibilityProbe.psm1', 'ProcessControl.psm1', 'StateStore.psm1', 'TransitionJournal.psm1', 'SessionEngine.psm1', 'SupervisorEngine.psm1', 'KernelObjects.psm1', 'TrayUi.psm1', 'ScheduledTask.psm1')) {
        [IO.File]::WriteAllText((Join-Path $Root "src\persistence\modules\$module"), "# $module`r`n", [Text.UTF8Encoding]::new($false))
    }
    return $Root
}

function New-CcodLifecycleFakeNode {
    param([Parameter(Mandatory)][string]$Root)
    New-Item -ItemType Directory -Path (Join-Path $Root 'node') -Force | Out-Null
    $nodePath = Join-Path $Root 'node\node.exe'
    [IO.File]::WriteAllText($nodePath, 'fake node', [Text.UTF8Encoding]::new($false))
    return $nodePath
}

function New-CcodLifecycleIdentity {
    return [pscustomobject][ordered]@{
        UserSid = 'S-1-5-21-111-222-333-1001'
        SessionId = [int]1
        Pid = [int]41
        CreationTimeUtc = '2030-02-03T03:00:00.0000000Z'
    }
}

function New-CcodLifecycleNormalizeReceipt {
    param([bool]$SpecialPresent, [bool]$Normalized, [string]$Outcome = 'NoSpecial')
    return [pscustomobject][ordered]@{ SchemaVersion = 1; SpecialPresent = $SpecialPresent; Normalized = $Normalized; Outcome = $Outcome }
}

function New-CcodLifecycleFake {
    param([string]$NodePath)

    $world = [pscustomobject]@{
        Calls = [Collections.Generic.List[string]]::new()
        ValidateSource = $true
        NodePath = $NodePath
        Identity = New-CcodLifecycleIdentity
        NowUtc = [DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime()
        TaskInstalled = 0
        TaskRemoved = 0
        TaskStarted = 0
        AutomationPaused = 0
        TransitionLeaseCalls = 0
        ShutdownSignaled = 0
        WaitSupervisorExit = $true
        TerminateSupervisorCalls = 0
        LastTerminateIdentity = $null
        NormalizeReceipt = New-CcodLifecycleNormalizeReceipt -SpecialPresent $false -Normalized $false
        NormalizeCalls = 0
        KeyPath = $null
        BackupCalls = 0
        RemoveKeyCalls = 0
        LastBackupPath = $null
        LogRecords = [Collections.Generic.List[object]]::new()
        CopyOverride = $null
    }
    $adapters = @{}
    $adapters.ValidateSource = { param($SourceRoot) $world.Calls.Add("Validate:$([IO.Path]::GetFileName($SourceRoot))"); [bool]$world.ValidateSource }.GetNewClosure()
    $adapters.GetProjectVersion = { param($SourceRoot) (Get-Content -LiteralPath (Join-Path $SourceRoot 'package.json') -Raw | ConvertFrom-Json).version }.GetNewClosure()
    $adapters.DiscoverNodeCandidates = { $world.Calls.Add('DiscoverNode'); @($world.NodePath) }.GetNewClosure()
    $adapters.ValidateNodeCandidate = { param($Path) $world.Calls.Add("ValidateNode:$([IO.Path]::GetFileName($Path))"); $Path -ceq $world.NodePath }.GetNewClosure()
    $adapters.GetCurrentIdentity = { $world.Calls.Add('Identity'); $world.Identity }.GetNewClosure()
    $adapters.UtcNow = { $world.Calls.Add('Now'); $world.NowUtc }.GetNewClosure()
    $adapters.InstallSupervisorTask = { param($InstallRoot, $UserSid) $world.Calls.Add("InstallTask:$([IO.Path]::GetFileName($InstallRoot)):$UserSid"); $world.TaskInstalled++ }.GetNewClosure()
    $adapters.RemoveSupervisorTask = { $world.Calls.Add('RemoveTask'); $world.TaskRemoved++ }.GetNewClosure()
    $adapters.StartSupervisorTask = { $world.Calls.Add('StartTask'); $world.TaskStarted++ }.GetNewClosure()
    $adapters.SignalSupervisorShutdown = { param($UserSid, $SessionId) $world.Calls.Add("SignalShutdown:${UserSid}:${SessionId}"); $world.ShutdownSignaled++ }.GetNewClosure()
    $adapters.WaitSupervisorExit = { param($SupervisorIdentity, $TimeoutMilliseconds) $world.Calls.Add("WaitSupervisor:$($SupervisorIdentity.Pid):$TimeoutMilliseconds"); [bool]$world.WaitSupervisorExit }.GetNewClosure()
    $adapters.TerminateSupervisor = { param($SupervisorIdentity) $world.Calls.Add("TerminateSupervisor:$($SupervisorIdentity.Pid)"); $world.TerminateSupervisorCalls++; $world.LastTerminateIdentity = $SupervisorIdentity; $true }.GetNewClosure()
    $adapters.NormalizeSpecialSession = { param($InstallRoot, $RuntimeId, $Identity) $world.Calls.Add("Normalize:$RuntimeId"); $world.NormalizeCalls++; $world.NormalizeReceipt }.GetNewClosure()
    $adapters.SetAutomationEnabled = { param($StateRoot, $Enabled) $world.Calls.Add("Automation:$Enabled"); $world.AutomationPaused++ }.GetNewClosure()
    $adapters.EnterTransitionLease = { param($UserSid, $SessionId) $world.Calls.Add("EnterTransitionLease"); $world.TransitionLeaseCalls++; [pscustomobject][ordered]@{ SchemaVersion = 1; Name = "Fake-Transition"; Kind = 'Transition'; Outcome = 'Acquired'; CreatedNew = $false; Abandoned = $false; Handle = [pscustomobject]@{ Kind = 'Mutex' }; OwnerManagedThreadId = [Threading.Thread]::CurrentThread.ManagedThreadId; Released = $false } }.GetNewClosure()
    $adapters.ExitTransitionLease = { param($Lease) $world.Calls.Add('ExitTransitionLease'); $true }.GetNewClosure()
    $adapters.ResolveDeviceKeyStore = { param() $world.Calls.Add('ResolveKey'); [string]$world.KeyPath }.GetNewClosure()
    $adapters.BackupDeviceKeyStore = { param($Path, $BackupPath) $world.Calls.Add("BackupKey:$([IO.Path]::GetFileName($Path))"); $world.BackupCalls++; $world.LastBackupPath = $BackupPath; [IO.File]::Move($Path, $BackupPath); $BackupPath }.GetNewClosure()
    $adapters.RemoveDeviceKeyStore = { param($Path) $world.Calls.Add("RemoveKey:$([IO.Path]::GetFileName($Path))"); $world.RemoveKeyCalls++; [IO.File]::Delete($Path) }.GetNewClosure()
    $adapters.CopyFile = {
        param($Source, $Destination)
        $world.Calls.Add("Copy:$([IO.Path]::GetFileName($Source))")
        if ($null -ne $world.CopyOverride -and $Source -like $world.CopyOverride.Match) {
            & $world.CopyOverride.Action $Source $Destination
            return
        }
        [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent)) | Out-Null
        [IO.File]::Copy($Source, $Destination, $true)
    }.GetNewClosure()
    $adapters.WriteLog = { param($InstallRoot, $Record) $world.Calls.Add("Log:$($Record.code)"); $world.LogRecords.Add($Record) }.GetNewClosure()
    [pscustomobject]@{ World = $world; Adapters = $adapters }
}

function Read-CcodLifecycleActivePointer {
    param([Parameter(Mandatory)][string]$Root)
    return (Get-Content -LiteralPath (Join-Path $Root 'active.json') -Raw | ConvertFrom-Json)
}

function Set-CcodLifecycleTestStatus {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeId
    )

    $status = [ordered]@{
        schemaVersion = 1
        session = [ordered]@{
            supervisorPid = 41
            supervisorCreationTimeUtc = '2030-02-03T03:00:00.0000000Z'
            sessionId = '1'
            runtimeId = $RuntimeId
            sessionState = 'Ordinary'
            codex = $null
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $InstallRoot 'state\status.json'),
        ($status | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false)
    )
}

$results = @()

$results += Invoke-CcodTest 'first install stages verifies activates task and persists consent' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $receipt = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -EnableCandidateCompatibleUpdates -Adapters $fake.Adapters
        Assert-CcodEqual 'Installed' $receipt.Outcome 'first install outcome'
        Assert-CcodEqual $true $receipt.Installed 'first install flag'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'bootstrap.ps1') -PathType Leaf) 'stable bootstrap copied'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'active.json') -PathType Leaf) 'active pointer written'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install "runtime\$($receipt.RuntimeId)") -PathType Container) 'runtime staged'
        Assert-CcodEqual 1 $fake.World.TaskInstalled 'task installed'
        Assert-CcodEqual 1 $fake.World.TaskStarted 'task started'
        Assert-CcodEqual $null $receipt.PreviousRuntimeId 'first install has no previous runtime'
        $state = Read-CcodState -StateRoot (Join-Path $install 'state')
        Assert-CcodEqual $true $state.Settings.candidateCompatibleOptIn 'explicit consent persisted'
        Assert-CcodEqual $true $state.Settings.automationEnabled 'automation enabled on first install'
        Assert-CcodEqual $nodePath $state.Settings.nodeCandidates[0] 'verified node candidate persisted'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'upgrade retains one previous runtime and starts the new task' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-a' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-v2';`n", [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $second = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake2.Adapters
        Assert-CcodEqual 'Upgraded' $second.Outcome 'upgrade outcome'
        Assert-CcodEqual $first.RuntimeId $second.PreviousRuntimeId 'upgrade retains previous runtime id'
        Assert-CcodTrue ($second.RuntimeId -cne $first.RuntimeId) 'new runtime id differs'
        Assert-CcodEqual 1 $fake2.World.TaskInstalled 'upgrade reinstalls task'
        Assert-CcodEqual 1 $fake2.World.ShutdownSignaled 'old supervisor shutdown signaled'
        Assert-CcodEqual 1 $fake2.World.WaitSupervisorExit 'old supervisor exit waited'
        $pointer = Read-CcodLifecycleActivePointer -Root $install
        Assert-CcodEqual $second.RuntimeId $pointer.activeRuntime 'active points at new runtime'
        Assert-CcodEqual $first.RuntimeId $pointer.previousRuntime 'previous points at old runtime'
        $runtimeRoot = Join-Path $install 'runtime'
        $ids = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory | ForEach-Object { $_.Name } | Sort-Object)
        Assert-CcodEqual (($ids -join '|')) ((@($first.RuntimeId, $second.RuntimeId) | Sort-Object) -join '|') 'only active and previous runtime remain'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'staging copy failure fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.World.CopyOverride = [pscustomobject]@{ Match = '*Supervisor.ps1'; Action = { param($Source, $Destination) throw 'PRIVATE_COPY_SECRET' } }
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_STAGING_FAILED'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'staging failure never writes active pointer'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'bootstrap.ps1'))) 'staging failure never writes bootstrap'
        Assert-CcodEqual 0 (Get-ChildItem -LiteralPath $install -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq '.staging' }).Count 'staging directory cleaned'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'manifest hash mismatch fails closed and cleans staging' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.World.CopyOverride = [pscustomobject]@{ Match = '*SessionController.ps1'; Action = { param($Source, $Destination) [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent)) | Out-Null; [IO.File]::WriteAllText($Destination, 'tampered', [Text.UTF8Encoding]::new($false)) } }
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_FILE_HASH_MISMATCH'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'hash mismatch never activates'
        Assert-CcodEqual 0 (Get-ChildItem -LiteralPath $install -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq '.staging' }).Count 'hash mismatch cleans staging'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'source reparse point fails closed before staging' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $junctionTarget = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $source 'outside-target') -Force | Out-Null
        New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
        $junction = Join-Path $source 'src\runtime\escape'
        cmd /c mklink /J "`"$junction`"" "`"$junctionTarget`"" | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_REPARSE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'source reparse never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $junctionTarget)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'invalid active pointer fails closed before upgrade' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-a' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'active.json'), '{"schemaVersion":9,"activeRuntime":"x","previousRuntime":null,"updatedAtUtc":"2030-02-03T03:04:05.0000000Z"}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-v2';`n", [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_SCHEMA_UNSUPPORTED'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'old supervisor shutdown timeout terminates only the verified identity' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-a' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-v2';`n", [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.WaitSupervisorExit = $false
        $second = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake2.Adapters
        Assert-CcodEqual 'Upgraded' $second.Outcome 'timeout still completes upgrade'
        Assert-CcodEqual 1 $fake2.World.TerminateSupervisorCalls 'timeout terminates exactly one supervisor'
        Assert-CcodEqual $fake2.World.Identity.Pid $fake2.World.LastTerminateIdentity.Pid 'termination uses the current supervisor identity'
        Assert-CcodTrue (($fake2.World.Calls -contains 'TerminateSupervisor:41')) 'termination targets the verified pid only'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'repair state quarantines damage and resets consent with preserved valid node candidates' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -EnableCandidateCompatibleUpdates -Adapters $fake.Adapters | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'state\settings.json'), '{broken', [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $receipt = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -RepairState -Adapters $fake2.Adapters
        Assert-CcodEqual 'Repaired' $receipt.Outcome 'repair outcome'
        Assert-CcodEqual $true $receipt.RepairCompleted 'repair completed flag'
        Assert-CcodEqual 0 $fake2.World.TaskInstalled 'repair does not reinstall task'
        Assert-CcodEqual 0 $fake2.World.TaskStarted 'repair does not start task'
        $state = Read-CcodState -StateRoot (Join-Path $install 'state')
        Assert-CcodEqual $false $state.Settings.automationEnabled 'repair resets automation'
        Assert-CcodEqual $false $state.Settings.candidateCompatibleOptIn 'repair resets consent'
        Assert-CcodEqual $nodePath $state.Settings.nodeCandidates[0] 'repair preserves revalidated node candidate'
        Assert-CcodTrue (@(Get-ChildItem -LiteralPath (Join-Path $install 'state') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.corrupt.*' }).Count -ge 1) 'damaged settings quarantined'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'whatif install performs no task process or install mutation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -EnableCandidateCompatibleUpdates -Adapters $fake.Adapters -WhatIf
        Assert-CcodTrue (-not (Test-Path -LiteralPath $install)) 'whatif creates no install root'
        Assert-CcodEqual 0 $fake.World.TaskInstalled 'whatif installs no task'
        Assert-CcodEqual 0 $fake.World.TaskStarted 'whatif starts no task'
        Assert-CcodEqual 0 $fake.World.ShutdownSignaled 'whatif signals no shutdown'
        Assert-CcodEqual 0 $fake.World.NormalizeCalls 'whatif normalizes no session'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'ordinary uninstall removes task runtime state and logs and preserves keys' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $keyRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $keyPath = Join-Path $keyRoot 'remote-control-device-keys.windows.json'
        New-Item -ItemType Directory -Path $keyRoot -Force | Out-Null
        [IO.File]::WriteAllText($keyPath, '{}', [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.KeyPath = $keyPath
        $receipt = Invoke-CcodUninstall -InstallRoot $install -Adapters $fake2.Adapters
        Assert-CcodEqual 'Uninstalled' $receipt.Outcome 'uninstall outcome'
        Assert-CcodEqual 1 $fake2.World.TaskRemoved 'task removed'
        Assert-CcodEqual 1 $fake2.World.NormalizeCalls 'session normalization checked'
        Assert-CcodEqual 1 $fake2.World.ShutdownSignaled 'supervisor shutdown signaled'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $install)) 'install root removed'
        Assert-CcodEqual $true $receipt.KeptDeviceKeyStore 'key store kept by default'
        Assert-CcodTrue (Test-Path -LiteralPath $keyPath -PathType Leaf) 'key file still present'
        Assert-CcodEqual 0 $fake2.World.BackupCalls 'default uninstall does not back up keys'
        Assert-CcodEqual 0 $fake2.World.RemoveKeyCalls 'default uninstall does not remove keys'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $keyRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'uninstall normalizes a special session by default' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.NormalizeReceipt = New-CcodLifecycleNormalizeReceipt -SpecialPresent $true -Normalized $true -Outcome 'Recovered'
        $receipt = Invoke-CcodUninstall -InstallRoot $install -Adapters $fake2.Adapters
        Assert-CcodEqual 'Uninstalled' $receipt.Outcome 'normalized special uninstall succeeds'
        Assert-CcodEqual 1 $fake2.World.NormalizeCalls 'special normalization invoked'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'uninstall fails closed when special normalization fails' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.NormalizeReceipt = New-CcodLifecycleNormalizeReceipt -SpecialPresent $true -Normalized $false -Outcome 'Failed'
        Assert-CcodThrows { Invoke-CcodUninstall -InstallRoot $install -Adapters $fake2.Adapters } 'CCOD_UNINSTALL_NORMALIZATION_FAILED'
        Assert-CcodEqual 0 $fake2.World.TaskRemoved 'failed normalization does not remove task'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'bootstrap.ps1')) 'failed normalization keeps install intact'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'keep current special session skips normalization and records the CDP warning' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.NormalizeReceipt = New-CcodLifecycleNormalizeReceipt -SpecialPresent $true -Normalized $false -Outcome 'NoSpecial'
        $receipt = Invoke-CcodUninstall -InstallRoot $install -KeepCurrentSpecialSession -Adapters $fake2.Adapters
        Assert-CcodEqual 'Uninstalled' $receipt.Outcome 'explicit keep uninstalls'
        Assert-CcodEqual 0 $fake2.World.NormalizeCalls 'keep skips session normalization'
        Assert-CcodTrue (@($fake2.World.LogRecords | Where-Object { $_.code -eq 'CCOD_UNINSTALL_UNMONITORED_CDP' }).Count -eq 1) 'unmonitored CDP warning recorded'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'explicit backup moves the key store after normalization' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $keyRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $keyPath = Join-Path $keyRoot 'remote-control-device-keys.windows.json'
        New-Item -ItemType Directory -Path $keyRoot -Force | Out-Null
        [IO.File]::WriteAllText($keyPath, '{}', [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.KeyPath = $keyPath
        $receipt = Invoke-CcodUninstall -InstallRoot $install -BackupDeviceKeyStore -Adapters $fake2.Adapters
        Assert-CcodEqual 1 $fake2.World.BackupCalls 'backup invoked once'
        Assert-CcodEqual 1 $fake2.World.NormalizeCalls 'normalization precedes backup'
        Assert-CcodTrue (@($fake2.World.Calls | Where-Object { $_ -like 'Normalize:*' }).Count -eq 1) 'normalization call recorded'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $keyPath)) 'key moved away'
        Assert-CcodTrue (Test-Path -LiteralPath $receipt.BackupPath -PathType Leaf) 'backup file exists'
        Assert-CcodTrue ($receipt.BackupPath -like "$keyPath.backup.*") 'backup name carries UTC timestamp suffix'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $keyRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'explicit removal deletes keys and prints the server revocation reminder' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $keyRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $keyPath = Join-Path $keyRoot 'remote-control-device-keys.windows.json'
        New-Item -ItemType Directory -Path $keyRoot -Force | Out-Null
        [IO.File]::WriteAllText($keyPath, '{}', [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.KeyPath = $keyPath
        $receipt = Invoke-CcodUninstall -InstallRoot $install -RemoveDeviceKeyStore -Adapters $fake2.Adapters
        Assert-CcodEqual 1 $fake2.World.RemoveKeyCalls 'key removal invoked once'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $keyPath)) 'key file deleted'
        Assert-CcodTrue (@($fake2.World.LogRecords | Where-Object { $_.code -eq 'CCOD_UNINSTALL_REVOKE_REMINDER' }).Count -eq 1) 'revocation reminder recorded'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $keyRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'simultaneous backup and removal is rejected' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Assert-CcodThrows { Invoke-CcodUninstall -InstallRoot $install -BackupDeviceKeyStore -RemoveDeviceKeyStore -Adapters $fake.Adapters } 'CCOD_UNINSTALL_KEY_CONFLICT'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'bootstrap.ps1')) 'conflict leaves install intact'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'whatif uninstall removes nothing and preserves keys' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $keyRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $keyPath = Join-Path $keyRoot 'remote-control-device-keys.windows.json'
        New-Item -ItemType Directory -Path $keyRoot -Force | Out-Null
        [IO.File]::WriteAllText($keyPath, '{}', [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.KeyPath = $keyPath
        Invoke-CcodUninstall -InstallRoot $install -BackupDeviceKeyStore -Adapters $fake2.Adapters -WhatIf
        Assert-CcodEqual 0 $fake2.World.TaskRemoved 'whatif removes no task'
        Assert-CcodEqual 0 $fake2.World.BackupCalls 'whatif backs up no keys'
        Assert-CcodTrue (Test-Path -LiteralPath $install) 'whatif keeps install'
        Assert-CcodTrue (Test-Path -LiteralPath $keyPath) 'whatif keeps keys'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $keyRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'remove path validation refuses out-of-root and reparse targets' {
    $install = New-CcodLifecycleTempRoot
    $outside = New-CcodLifecycleTempRoot
    try {
        New-Item -ItemType Directory -Path $install -Force | Out-Null
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Assert-CcodThrows { Test-CcodLifecycleRemovePath -Root $install -Path (Join-Path $outside 'file.json') } 'CCOD_INSTALL_PATH_OUTSIDE_ROOT'
        Assert-CcodEqual $true (Test-CcodLifecycleRemovePath -Root $install -Path (Join-Path $install 'state')) 'contained path is accepted'
    } finally {
        foreach ($path in @($install, $outside)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}


$results += Invoke-CcodTest 'default adapters keep module session state for private helpers' {
    $mod = Get-Module InstallLifecycle
    Assert-CcodTrue ($null -ne $mod) 'InstallLifecycle module is loaded'
    $adapters = & $mod { Get-CcodLifecycleAdapters }
    Assert-CcodTrue ($adapters.ContainsKey('GetProjectVersion')) 'GetProjectVersion adapter exists'
    Assert-CcodTrue ($adapters.ContainsKey('NormalizeSpecialSession')) 'NormalizeSpecialSession adapter exists'

    $source = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-default-adapters' | Out-Null
        $version = & $adapters.GetProjectVersion $source
        Assert-CcodEqual '2.0.0-default-adapters' $version 'default GetProjectVersion resolves package.json through module-private helper'
    } finally {
        if (Test-Path -LiteralPath $source) { Remove-Item -LiteralPath $source -Recurse -Force }
    }

    $commandNames = @($adapters.GetProjectVersion.Ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    Assert-CcodTrue ($commandNames -contains 'Get-CcodLifecycleProjectVersion') 'default GetProjectVersion still targets the private helper'
}
Write-Output "Install lifecycle self-tests passed: $($results.Count)"
