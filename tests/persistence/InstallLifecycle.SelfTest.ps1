$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$installLifecycleModule = Join-Path $repositoryRoot 'src\persistence\modules\InstallLifecycle.psm1'
if (-not (Test-Path -LiteralPath $installLifecycleModule -PathType Leaf)) {
    throw "InstallLifecycle module is missing: $installLifecycleModule"
}
Import-Module $installLifecycleModule -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\StateStore.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\UiPreferences.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1') -Force

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
    New-Item -ItemType Directory -Path (Join-Path $Root 'src\persistence\resources') -Force | Out-Null
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
    foreach ($module in @('PersistenceIO.psm1', 'RuntimeManifest.psm1', 'CompatibilityProbe.psm1', 'ProcessControl.psm1', 'StateStore.psm1', 'TransitionJournal.psm1', 'SessionEngine.psm1', 'SupervisorEngine.psm1', 'KernelObjects.psm1', 'TrayUi.psm1', 'UiLocalization.psm1', 'UiPreferences.psm1', 'ScheduledTask.psm1')) {
        [IO.File]::WriteAllText((Join-Path $Root "src\persistence\modules\$module"), "# $module`r`n", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\resources\ui.en-US.json'), '{"schemaVersion":1,"language":"en-US"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\resources\ui.zh-CN.json'), '{"schemaVersion":1,"language":"zh-CN"}', [Text.UTF8Encoding]::new($false))
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
        FallbackSupervisor = $null
        FallbackSupervisorLookups = 0
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
    $adapters.FindSupervisorFallback = { param($InstallRoot, $Identity) $world.Calls.Add("FindSupervisorFallback:$([IO.Path]::GetFileName($InstallRoot)):$($Identity.UserSid):$($Identity.SessionId)"); $world.FallbackSupervisorLookups++; $world.FallbackSupervisor }.GetNewClosure()
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
        $stateRoot = Join-Path $install 'state'
        $preference = Read-CcodUiPreference -StateRoot $stateRoot
        Assert-CcodEqual 'System' $preference.LanguageMode 'first install follows Windows'
        Assert-CcodEqual $false $preference.FallbackUsed 'first install persisted preference'
        $runtimeRoot = Join-Path $install "runtime\$($receipt.RuntimeId)"
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $runtimeRoot 'src\persistence\resources\ui.en-US.json') -PathType Leaf) 'English catalog staged'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $runtimeRoot 'src\persistence\resources\ui.zh-CN.json') -PathType Leaf) 'Chinese catalog staged'
        $manifest = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $receipt.RuntimeId
        Assert-CcodEqual $true $manifest.Valid 'runtime manifest validates staged resources'
        $english = @($manifest.Manifest.files | Where-Object { $_.path -ceq 'src/persistence/resources/ui.en-US.json' })
        $chinese = @($manifest.Manifest.files | Where-Object { $_.path -ceq 'src/persistence/resources/ui.zh-CN.json' })
        Assert-CcodEqual 1 $english.Count 'manifest contains English catalog exactly once'
        Assert-CcodEqual 1 $chinese.Count 'manifest contains Chinese catalog exactly once'
        Assert-CcodEqual '662b6067a48cfaeb481ae1a35e02f09fa799fa6386d0f4d2c61c19874a152713' $english[0].sha256 'manifest hashes English catalog'
        Assert-CcodEqual '5770fe0f20f1623648a185cc7a0a99ff37b6aef6c07426ffc8a984493e0f2a2f' $chinese[0].sha256 'manifest hashes Chinese catalog'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'hidden persistence module is staged and manifest-hashed' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $hiddenModule = Join-Path $source 'src\persistence\modules\HiddenRuntime.psm1'
        [IO.File]::WriteAllText($hiddenModule, "Set-StrictMode -Version Latest`r`n# hidden fixture`r`n", [Text.UTF8Encoding]::new($false))
        $hiddenItem = Get-Item -LiteralPath $hiddenModule -Force
        $hiddenItem.Attributes = $hiddenItem.Attributes -bor [IO.FileAttributes]::Hidden
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $receipt = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $runtimeRoot = Join-Path $install "runtime\$($receipt.RuntimeId)"
        $stagedModule = Join-Path $runtimeRoot 'src\persistence\modules\HiddenRuntime.psm1'
        Assert-CcodTrue (Test-Path -LiteralPath $stagedModule -PathType Leaf) 'hidden module is staged'
        $manifest = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $receipt.RuntimeId
        Assert-CcodEqual $true $manifest.Valid 'hidden module runtime manifest validates'
        $record = @($manifest.Manifest.files | Where-Object { $_.path -ceq 'src/persistence/modules/HiddenRuntime.psm1' })
        Assert-CcodEqual 1 $record.Count 'manifest contains hidden module exactly once'
        Assert-CcodEqual '19fe966336cb8900576716b6518dcddac052405ec6b59eacb9eac149e4ee8f71' $record[0].sha256 'manifest hashes hidden module bytes'
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
        $stateRoot = Join-Path $install 'state'
        Set-CcodUiLanguageMode -StateRoot $stateRoot -LanguageMode 'en-US' -Adapters @{ UtcNow = { [DateTimeOffset]::Parse('2030-02-03T03:04:06.0000000Z') } } | Out-Null
        $preferencePath = Join-Path $stateRoot 'ui-preferences.json'
        $preferenceBytes = [IO.File]::ReadAllBytes($preferencePath)
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
        Assert-CcodEqual (($preferenceBytes | ForEach-Object { $_.ToString('x2') }) -join '') (([IO.File]::ReadAllBytes($preferencePath) | ForEach-Object { $_.ToString('x2') }) -join '') 'upgrade preserves valid UI preference bytes'
        Assert-CcodEqual 'en-US' (Read-CcodUiPreference -StateRoot $stateRoot).LanguageMode 'upgrade retains selected UI language'
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

$results += Invoke-CcodTest 'selected UI catalog mutation after inventory fails hash verification before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.World.CopyOverride = [pscustomobject]@{
            Match = '*ui.en-US.json'
            Action = {
                param($Source, $Destination)
                [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent)) | Out-Null
                [IO.File]::Copy($Source, $Destination, $true)
                [IO.File]::WriteAllText($Source, '{"schemaVersion":1,"language":"tampered-after-inventory"}', [Text.UTF8Encoding]::new($false))
            }
        }
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_FILE_HASH_MISMATCH'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'post-inventory catalog mutation never activates'
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

$results += Invoke-CcodTest 'missing UI catalog fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        [IO.File]::Delete((Join-Path $source 'src\persistence\resources\ui.zh-CN.json'))
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'missing catalog never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'unknown UI catalog fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'src\persistence\resources\ui.fr-FR.json'), '{"schemaVersion":1,"language":"fr-FR"}', [Text.UTF8Encoding]::new($false))
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'unknown catalog never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'case-variant UI catalog fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $catalog = Join-Path $source 'src\persistence\resources\ui.en-US.json'
        $temporary = Join-Path $source 'src\persistence\resources\catalog-temporary.json'
        [IO.File]::Move($catalog, $temporary)
        [IO.File]::Move($temporary, (Join-Path $source 'src\persistence\resources\ui.EN-us.json'))
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'case-variant catalog never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'named UI catalog alternate data stream fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $catalog = Join-Path $source 'src\persistence\resources\ui.en-US.json'
        Set-Content -LiteralPath $catalog -Stream 'ccod-test' -Value 'unmanifested stream' -NoNewline
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'named catalog stream never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'named UI resource directory alternate data stream fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $resources = Join-Path $source 'src\persistence\resources'
        Set-Content -LiteralPath ($resources + ':ccod-test') -Value 'unmanifested directory stream' -NoNewline
        Assert-CcodEqual 'unmanifested directory stream' (Get-Content -LiteralPath ($resources + ':ccod-test') -Raw) 'provider creates resource directory alternate data stream'
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'named resource directory stream never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'non-catalog resource file fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'src\persistence\resources\README.txt'), 'not a catalog', [Text.UTF8Encoding]::new($false))
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'non-catalog resource file never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'ordinary resource subdirectory fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $source 'src\persistence\resources\locales') -Force | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'ordinary resource subdirectory never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'UI resource directory reparse fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $target = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $resources = Join-Path $source 'src\persistence\resources'
        [IO.Directory]::Move($resources, $target)
        cmd /c mklink /J "`"$resources`"" "`"$target`"" | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_REPARSE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'resource directory reparse never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $target)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'UI resource file reparse fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $target = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $resource = Join-Path $source 'src\persistence\resources\ui.en-US.json'
        [IO.Directory]::CreateDirectory($target) | Out-Null
        [IO.File]::Delete($resource)
        cmd /c mklink /J "`"$resource`"" "`"$target`"" | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_REPARSE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'resource file reparse never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $target)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
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

$results += Invoke-CcodTest 'upgrade and repair preserve malformed UI preference without safety damage' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-ui-malformed' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        $stateRoot = Join-Path $install 'state'
        $preferencePath = Join-Path $stateRoot 'ui-preferences.json'
        [byte[]]$malformed = 0x00,0x7b,0xff,0x13,0x0a
        [IO.File]::WriteAllBytes($preferencePath, $malformed)
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-ui-malformed-v2';`n", [Text.UTF8Encoding]::new($false))
        $upgrade = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Assert-CcodEqual 'Upgraded' $upgrade.Outcome 'malformed preference does not block ordinary upgrade'
        Assert-CcodEqual '007bff130a' (([IO.File]::ReadAllBytes($preferencePath) | ForEach-Object { $_.ToString('x2') }) -join '') 'ordinary upgrade preserves malformed UI preference bytes'
        $repairFake = New-CcodLifecycleFake -NodePath $nodePath
        $repair = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -RepairState -Adapters $repairFake.Adapters
        Assert-CcodEqual 'Repaired' $repair.Outcome 'malformed preference does not block repair'
        Assert-CcodEqual '007bff130a' (([IO.File]::ReadAllBytes($preferencePath) | ForEach-Object { $_.ToString('x2') }) -join '') 'repair preserves malformed UI preference bytes'
        $state = Read-CcodState -StateRoot $stateRoot
        Assert-CcodEqual $false $state.Settings.automationEnabled 'repair applies its ordinary safety reset'
        Assert-CcodEqual 4 (@(Get-ChildItem -LiteralPath $stateRoot -File -ErrorAction Stop | Where-Object { $_.Name -like '*.corrupt.*' })).Count 'repair quarantines only its four safety-state files'
        Assert-CcodEqual 0 (@(Get-ChildItem -LiteralPath $stateRoot -File -ErrorAction Stop | Where-Object { $_.Name -like 'ui-preferences.json.corrupt.*' })).Count 'repair does not quarantine malformed UI preference'
        Assert-CcodEqual 0 $repairFake.World.TaskInstalled 'repair does not reinstall task for malformed preference'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'legacy missing UI preference remains absent across upgrade and follows Windows' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-ui-legacy' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        $stateRoot = Join-Path $install 'state'
        $preferencePath = Join-Path $stateRoot 'ui-preferences.json'
        [IO.File]::Delete($preferencePath)
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-ui-legacy-v2';`n", [Text.UTF8Encoding]::new($false))
        $upgrade = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Assert-CcodEqual 'Upgraded' $upgrade.Outcome 'legacy preference absence does not block upgrade'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $preferencePath)) 'legacy missing preference remains absent after upgrade'
        $preference = Read-CcodUiPreference -StateRoot $stateRoot
        Assert-CcodEqual 'System' $preference.LanguageMode 'legacy missing preference follows Windows'
        Assert-CcodEqual $true $preference.FallbackUsed 'legacy missing preference uses safe fallback'
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

$results += Invoke-CcodTest 'upgrade stops a verified fallback supervisor when status has no session identity' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-fallback' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $status = Read-CcodStatus -StateRoot (Join-Path $install 'state')
        Assert-CcodTrue ($null -eq $status.session) 'fixture reproduces the legacy status without a supervisor identity'
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-fallback-v2';`n", [Text.UTF8Encoding]::new($false))
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.World.FallbackSupervisor = [pscustomobject][ordered]@{
            Pid = 97
            CreationTimeUtc = '2030-02-03T03:00:00.0000000Z'
            SessionId = $fake.World.Identity.SessionId
            UserSid = $fake.World.Identity.UserSid
        }
        $upgrade = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Assert-CcodEqual 'Upgraded' $upgrade.Outcome 'fallback upgrade outcome'
        Assert-CcodEqual 1 $fake.World.FallbackSupervisorLookups 'legacy status triggers one verified fallback lookup'
        Assert-CcodEqual 1 $fake.World.ShutdownSignaled 'verified fallback supervisor receives shutdown signal'
        Assert-CcodTrue ($fake.World.Calls -contains 'WaitSupervisor:97:10000') 'upgrade waits for the verified fallback pid'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'fallback accepts a deleted legacy runtime only through the exact stable bootstrap parent' {
    $install = New-CcodLifecycleTempRoot
    try {
        $identity = New-CcodLifecycleIdentity
        New-Item -ItemType Directory -Path $install -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'bootstrap.ps1'), '# fixture bootstrap', [Text.UTF8Encoding]::new($false))
        $oldSupervisor = Join-Path $install 'runtime\2.1.1-deleted\src\persistence\Supervisor.ps1'
        $bootstrap = Join-Path $install 'bootstrap.ps1'
        $processes = @(
            [pscustomobject][ordered]@{
                ProcessId = 97
                ParentProcessId = 96
                SessionId = $identity.SessionId
                CreationDate = [DateTime]::Parse('2030-02-03T03:00:00Z').ToUniversalTime()
                CommandLine = "powershell.exe -File `"$oldSupervisor`" -ReadyToken $('a' * 64)"
            },
            [pscustomobject][ordered]@{
                ProcessId = 96
                ParentProcessId = 1
                SessionId = $identity.SessionId
                CreationDate = [DateTime]::Parse('2030-02-03T02:59:59Z').ToUniversalTime()
                CommandLine = "powershell.exe -File `"$bootstrap`" -InstallRoot `"$install`""
            }
        )
        $module = Get-Module InstallLifecycle
        $fallback = & $module {
            param($Root, $CurrentIdentity, $Snapshots)
            Get-CcodLifecycleVerifiedSupervisorFallback -InstallRoot $Root -Identity $CurrentIdentity -ProcessEnumerator { param($Ignored) $Snapshots } -OwnerSidResolver { param($Process) [pscustomobject]@{ ReturnValue = 0; Sid = $CurrentIdentity.UserSid } }
        } $install $identity $processes
        Assert-CcodEqual 97 $fallback.Pid 'legacy runtime process is accepted only with the exact bootstrap parent'
        Assert-CcodEqual $identity.UserSid $fallback.UserSid 'fallback carries the verified owner SID'
    } finally {
        if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'fallback rejects a legacy runtime whose parent is not the stable bootstrap' {
    $install = New-CcodLifecycleTempRoot
    try {
        $identity = New-CcodLifecycleIdentity
        New-Item -ItemType Directory -Path $install -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'bootstrap.ps1'), '# fixture bootstrap', [Text.UTF8Encoding]::new($false))
        $oldSupervisor = Join-Path $install 'runtime\2.1.1-deleted\src\persistence\Supervisor.ps1'
        $processes = @(
            [pscustomobject][ordered]@{
                ProcessId = 97
                ParentProcessId = 96
                SessionId = $identity.SessionId
                CreationDate = [DateTime]::Parse('2030-02-03T03:00:00Z').ToUniversalTime()
                CommandLine = "powershell.exe -File `"$oldSupervisor`" -ReadyToken $('a' * 64)"
            },
            [pscustomobject][ordered]@{
                ProcessId = 96
                ParentProcessId = 1
                SessionId = $identity.SessionId
                CreationDate = [DateTime]::Parse('2030-02-03T02:59:59Z').ToUniversalTime()
                CommandLine = "powershell.exe -File `"C:\unrelated\bootstrap.ps1`" -InstallRoot `"$install`""
            }
        )
        $module = Get-Module InstallLifecycle
        $fallback = & $module {
            param($Root, $CurrentIdentity, $Snapshots)
            Get-CcodLifecycleVerifiedSupervisorFallback -InstallRoot $Root -Identity $CurrentIdentity -ProcessEnumerator { param($Ignored) $Snapshots } -OwnerSidResolver { param($Process) [pscustomobject]@{ ReturnValue = 0; Sid = $CurrentIdentity.UserSid } }
        } $install $identity $processes
        Assert-CcodTrue ($null -eq $fallback) 'lookalike parent does not authorize fallback termination'
    } finally {
        if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'installer exposes a desktop entry that only starts the stable tray bootstrap' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $entries = @(Get-Content -LiteralPath $installerScript | Where-Object { $_ -cmatch '^Name: "\{userdesktop\}\\' })
    Assert-CcodEqual 1 $entries.Count 'installer defines exactly one desktop entry'
    $entry = [string]$entries[0]
    Assert-CcodTrue ($entry -cmatch 'Name: "\{userdesktop\}\\Codex 设备连接 \(Device Connection\)"') 'desktop entry has the bilingual product name'
    Assert-CcodTrue ($entry -cmatch 'Filename: "\{sys\}\\WindowsPowerShell\\v1\.0\\powershell\.exe"') 'desktop entry uses the Windows PowerShell host'
    Assert-CcodTrue ($entry -cmatch '-WindowStyle Hidden') 'desktop entry hides the bootstrap host window'
    Assert-CcodTrue ($entry -cmatch '\{localappdata\}\\CodexControlOtherDevices\\bootstrap\.ps1') 'desktop entry targets the stable bootstrap'
    Assert-CcodTrue ($entry -cmatch '-InstallRoot ""\{localappdata\}\\CodexControlOtherDevices""') 'desktop entry supplies the stable install root'
    Assert-CcodTrue ($entry -cnotmatch 'Start-CodexControlOtherDevices\.ps1') 'desktop entry never invokes a direct repair session'
}

$results += Invoke-CcodTest 'installer carries the Inno contract needed by its self-validation' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $sourceEntries = @(Get-Content -LiteralPath $installerScript | Where-Object { $_ -cmatch '^Source: "\.\.\\build\\CodexControlOtherDevices\.iss"; DestDir: "\{app\}\\build";' })
    Assert-CcodEqual 1 $sourceEntries.Count 'installer carries the build contract used by Validate.ps1'
}

Write-Output "Install lifecycle self-tests passed: $($results.Count)"
