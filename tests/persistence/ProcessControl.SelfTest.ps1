$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\ProcessControl.psm1') -Force

function New-CcodSnapshot {
    param(
        [int]$ProcessId = 100,
        [string]$CreationTimeUtc = '2026-08-02T00:00:00.0000000Z',
        [int]$SessionId = 1,
        [string]$UserSid = 'S-1-5-21-test',
        [string]$Path = 'C:\Codex\ChatGPT.exe',
        [string]$PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0',
        [string]$CommandLine = '"C:\Codex\ChatGPT.exe"',
        [AllowNull()][Nullable[int]]$ParentPid = $null,
        [bool]$IsTopLevel = $true,
        [ValidateSet('Ordinary', 'Special', 'Unrelated')][string]$Mode = 'Ordinary',
        [AllowNull()][Nullable[int]]$RendererPort = $null,
        [AllowNull()][Nullable[int]]$MainPort = $null
    )

    [pscustomobject][ordered]@{
        Pid = $ProcessId
        CreationTimeUtc = $CreationTimeUtc
        SessionId = $SessionId
        UserSid = $UserSid
        Path = $Path
        PackageFamilyName = $PackageFamilyName
        CommandLine = $CommandLine
        ParentPid = $ParentPid
        IsTopLevel = $IsTopLevel
        Mode = $Mode
        RendererPort = $RendererPort
        MainPort = $MainPort
    }
}

function New-CcodSnapshotAdapters {
    param(
        [string]$CommandLine = '"C:\Codex\ChatGPT.exe"',
        [int]$SessionId = 1,
        [string]$UserSid = 'S-1-5-21-test',
        [string]$Path = 'C:\Codex\ChatGPT.exe',
        [string]$FamilyName = 'OpenAI.Codex_2p2nqsd0c76g0',
        [int]$ParentPid = 0,
        [string]$SecondCreationTimeUtc = '2026-08-02T00:00:00.0000000Z',
        [bool]$ProbeValid = $true,
        [string]$RendererUrl = 'app://-/index.html',
        $Counter = $null
    )

    $command = $CommandLine
    $session = $SessionId
    $sid = $UserSid
    $pathValue = $Path
    $family = $FamilyName
    $parent = $ParentPid
    $creationAfter = $SecondCreationTimeUtc
    $probeIsValid = $ProbeValid
    $url = $RendererUrl
    $calls = $Counter
    $state = [pscustomobject]@{ NativeReads = 0 }
    return @{
        GetPackageIdentity = {
            if ($null -ne $calls) { $calls.Package++ }
            [pscustomobject]@{
                Found = $true
                FullName = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'
                FamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
                Version = '1.0.0.0'
                ExecutablePath = 'C:\Codex\ChatGPT.exe'
            }
        }.GetNewClosure()
        GetCurrentSessionId = { 1 }
        GetCurrentUserSid = { 'S-1-5-21-test' }
        GetNativeProcess = {
            param($ProcessId)
            $state.NativeReads++
            if ($null -ne $calls) { $calls.Native++ }
            [pscustomobject]@{
                Pid = $ProcessId
                CreationTimeUtc = if ($state.NativeReads -eq 1) { '2026-08-02T00:00:00.0000000Z' } else { $creationAfter }
                SessionId = $session
                UserSid = $sid
                Path = $pathValue
                PackageFamilyName = $family
            }
        }.GetNewClosure()
        GetCimProcess = {
            param($ProcessId)
            if ($null -ne $calls) { $calls.Cim++ }
            [pscustomobject]@{ ProcessId = $ProcessId; CommandLine = $command; ParentProcessId = $parent }
        }.GetNewClosure()
        ProbeSpecial = {
            param($ProcessId, $RendererPort, $MainPort)
            if ($null -ne $calls) { $calls.Probe++ }
            [pscustomobject]@{ Valid = $probeIsValid; RendererUrl = $url }
        }.GetNewClosure()
    }
}

function New-CcodSpecialStatus {
    [pscustomobject]@{
        pid = 100
        creationTimeUtc = '2026-08-02T00:00:00.0000000Z'
        packageFullName = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'
        packageVersion = '1.0.0.0'
        rendererPort = 41001
        mainPort = 41002
    }
}

try {
    Invoke-CcodTest 'requires every process snapshot field to match exactly' {
        $expected = New-CcodSnapshot
        $actual = New-CcodSnapshot
        Assert-CcodEqual $true (Test-CcodProcessMatch -Expected $expected -Actual $actual) 'independent exact snapshots match'

        foreach ($mutation in @(
            @{ Name = 'Pid'; Value = 101 },
            @{ Name = 'Pid'; Value = '100' },
            @{ Name = 'CreationTimeUtc'; Value = '2026-08-02T00:00:02.0000000Z' },
            @{ Name = 'SessionId'; Value = 2 },
            @{ Name = 'UserSid'; Value = 'S-1-5-21-other' },
            @{ Name = 'Path'; Value = 'C:\Other\ChatGPT.exe' },
            @{ Name = 'PackageFamilyName'; Value = 'Other.Family' },
            @{ Name = 'CommandLine'; Value = '"C:\Codex\ChatGPT.exe" --type=renderer' },
            @{ Name = 'ParentPid'; Value = 50 },
            @{ Name = 'IsTopLevel'; Value = $false },
            @{ Name = 'IsTopLevel'; Value = 'True' },
            @{ Name = 'Mode'; Value = 'Special' },
            @{ Name = 'RendererPort'; Value = 41001 },
            @{ Name = 'MainPort'; Value = 41002 }
        )) {
            $changed = New-CcodSnapshot
            $changed.($mutation.Name) = $mutation.Value
            Assert-CcodEqual $false (Test-CcodProcessMatch -Expected $expected -Actual $changed) "$($mutation.Name) mismatch is rejected"
        }
    }

    Invoke-CcodTest 'classifies only the current exact package top-level process as ordinary' {
        $ordinary = Get-CcodProcessSnapshot -ProcessId 100 -Adapters (New-CcodSnapshotAdapters)
        Assert-CcodEqual 'Ordinary' $ordinary.Mode 'exact current root is ordinary'
        Assert-CcodEqual $true $ordinary.IsTopLevel 'ordinary root is top level'
        Assert-CcodEqual $null $ordinary.RendererPort 'ordinary root has no renderer port'

        foreach ($case in @(
            @{ Name = 'renderer child'; Adapters = (New-CcodSnapshotAdapters -CommandLine '"C:\Codex\ChatGPT.exe" --type=renderer' -ParentPid 100) },
            @{ Name = 'other session'; Adapters = (New-CcodSnapshotAdapters -SessionId 2) },
            @{ Name = 'other user'; Adapters = (New-CcodSnapshotAdapters -UserSid 'S-1-5-21-other') },
            @{ Name = 'path mismatch'; Adapters = (New-CcodSnapshotAdapters -Path 'C:\Other\ChatGPT.exe') },
            @{ Name = 'family mismatch'; Adapters = (New-CcodSnapshotAdapters -FamilyName 'Other.Family') }
        )) {
            $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -Adapters $case.Adapters
            Assert-CcodEqual 'Unrelated' $snapshot.Mode "$($case.Name) is never adopted"
        }
    }

    Invoke-CcodTest 'classifies special mode only with exact ports status URL and live probe' {
        $command = '"C:\Codex\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $status = New-CcodSpecialStatus
        $special = Get-CcodProcessSnapshot -ProcessId 100 -StatusEvidence $status -Adapters (New-CcodSnapshotAdapters -CommandLine $command)
        Assert-CcodEqual 'Special' $special.Mode 'all independent special evidence matches'
        Assert-CcodEqual 41001 $special.RendererPort 'renderer port is parsed'
        Assert-CcodEqual 41002 $special.MainPort 'main port is parsed'

        foreach ($case in @(
            @{ Name = 'wrong renderer port'; Command = $command.Replace('41001', '41003'); Status = $status; Probe = $true; Url = 'app://-/index.html' },
            @{ Name = 'wrong main port'; Command = $command.Replace('41002', '41004'); Status = $status; Probe = $true; Url = 'app://-/index.html' },
            @{ Name = 'status PID mismatch'; Command = $command; Status = ([pscustomobject]@{ pid=101; creationTimeUtc=$status.creationTimeUtc; packageFullName=$status.packageFullName; packageVersion=$status.packageVersion; rendererPort=41001; mainPort=41002 }); Probe = $true; Url = 'app://-/index.html' },
            @{ Name = 'query-bearing renderer URL'; Command = $command; Status = $status; Probe = $true; Url = 'app://-/index.html?overlay=1' },
            @{ Name = 'failed live probe'; Command = $command; Status = $status; Probe = $false; Url = 'app://-/index.html' }
        )) {
            $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -StatusEvidence $case.Status -Adapters (New-CcodSnapshotAdapters -CommandLine $case.Command -ProbeValid $case.Probe -RendererUrl $case.Url)
            Assert-CcodEqual 'Unrelated' $snapshot.Mode "$($case.Name) cannot prove special identity"
        }
    }

    Invoke-CcodTest 'rejects a snapshot when creation changes across CIM metadata' {
        $calls = [pscustomobject]@{ Package = 0; Native = 0; Cim = 0; Probe = 0 }
        $snapshot = Get-CcodProcessSnapshot -ProcessId 100 -Adapters (New-CcodSnapshotAdapters -SecondCreationTimeUtc '2026-08-02T00:00:02.0000000Z' -Counter $calls)
        Assert-CcodEqual $null $snapshot 'PID reuse during metadata collection fails closed'
        Assert-CcodEqual 1 $calls.Package 'package identity is dynamically resolved once for this read'
        Assert-CcodEqual 2 $calls.Native 'native identity brackets CIM metadata'
        Assert-CcodEqual 1 $calls.Cim 'CIM is used only for command and parent metadata'
        Assert-CcodEqual 0 $calls.Probe 'unstable identity is never probed'
    }

    Invoke-CcodTest 'never calls the stop boundary after exit or identity change' {
        $expected = New-CcodSnapshot
        $calls = [pscustomobject]@{ Stop = 0 }
        $exited = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) $null }
            StopProcess = { $calls.Stop++; throw 'must not run' }.GetNewClosure()
        }
        Assert-CcodEqual 'ExitedBeforeStop' $exited.Outcome 'natural exit cancels transition'
        Assert-CcodEqual $false $exited.StoppedByController 'natural exit never authorizes launch'

        $reused = New-CcodSnapshot -CreationTimeUtc '2026-08-02T00:00:02.0000000Z'
        $changed = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) $reused }.GetNewClosure()
            StopProcess = { $calls.Stop++; throw 'must not run' }.GetNewClosure()
        }
        Assert-CcodEqual 'IdentityChanged' $changed.Outcome 'PID reuse is observed without stopping'
        Assert-CcodEqual $false $changed.StoppedByController 'identity change never authorizes launch'
        Assert-CcodEqual 0 $calls.Stop 'dangerous boundary is unreachable without an exact reread'
    }

    Invoke-CcodTest 'requires an exact confirmed stop receipt' {
        $expected = New-CcodSnapshot
        $calls = [pscustomobject]@{ Stop = 0; ProcessId = 0; Timeout = 0; Snapshot = $null }
        $receipt = [pscustomobject]@{
            Outcome = 'StoppedByController'
            StoppedByController = $true
            Pid = 100
            CreationTimeUtc = '2026-08-02T00:00:00.0000000Z'
        }
        $result = Stop-CcodProcessIfMatch -Expected $expected -TimeoutMilliseconds 4321 -Adapters @{
            GetProcess = { param($ProcessId) New-CcodSnapshot }
            StopProcess = {
                param($Snapshot, $TimeoutMilliseconds)
                $calls.Stop++
                $calls.ProcessId = $Snapshot.Pid
                $calls.Timeout = $TimeoutMilliseconds
                $calls.Snapshot = $Snapshot
                $receipt
            }.GetNewClosure()
        }
        Assert-CcodEqual 'StoppedByController' $result.Outcome 'confirmed receipt authorizes the transition'
        Assert-CcodEqual $true $result.StoppedByController 'confirmation is explicit'
        Assert-CcodEqual 1 $calls.Stop 'stop boundary is called once'
        Assert-CcodEqual 100 $calls.ProcessId 'exact reread snapshot is passed to the stop boundary'
        Assert-CcodEqual 4321 $calls.Timeout 'timeout is passed without substitution'
        Assert-CcodEqual $true (Test-CcodProcessMatch -Expected $expected -Actual $calls.Snapshot) 'stop receives the exact actual snapshot'

        $unconfirmed = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) New-CcodSnapshot }
            StopProcess = { param($Snapshot, $TimeoutMilliseconds) $null }
        }
        Assert-CcodEqual 'TimedOut' $unconfirmed.Outcome 'missing receipt cannot be promoted to success'
        Assert-CcodEqual $false $unconfirmed.StoppedByController 'unconfirmed stop never authorizes launch'

        $coercedReceipt = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) New-CcodSnapshot }
            StopProcess = {
                param($Snapshot, $TimeoutMilliseconds)
                [pscustomobject]@{ Outcome='StoppedByController'; StoppedByController=$true; Pid='100'; CreationTimeUtc='2026-08-02T00:00:00.0000000Z' }
            }
        }
        Assert-CcodEqual 'TimedOut' $coercedReceipt.Outcome 'coercive receipt identity is never confirmation'

        foreach ($badReceipt in @(
            [pscustomobject]@{ Outcome='StoppedByController'; StoppedByController='True'; Pid=100; CreationTimeUtc='2026-08-02T00:00:00.0000000Z' },
            [pscustomobject]@{ Outcome='StoppedByController'; StoppedByController=$true; Pid=100; CreationTimeUtc=[DateTimeOffset]::Parse('2026-08-02T00:00:00.0000000Z') }
        )) {
            $unsafeReceipt = $badReceipt
            $resultFromUnsafeReceipt = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
                GetProcess = { param($ProcessId) New-CcodSnapshot }
                StopProcess = { param($Snapshot, $TimeoutMilliseconds) $unsafeReceipt }.GetNewClosure()
            }
            Assert-CcodEqual 'TimedOut' $resultFromUnsafeReceipt.Outcome 'receipt confirmation fields are type exact'
        }
    }

    Invoke-CcodTest 'distinguishes access denial and delayed exit' {
        $expected = New-CcodSnapshot
        $denied = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) New-CcodSnapshot }
            StopProcess = { param($Snapshot, $TimeoutMilliseconds) [pscustomobject]@{ Outcome = 'AccessDenied'; StoppedByController = $false } }
        }
        Assert-CcodEqual 'AccessDenied' $denied.Outcome 'access failure remains distinct'
        Assert-CcodEqual $false $denied.StoppedByController 'denial never authorizes launch'

        $delayed = Stop-CcodProcessIfMatch -Expected $expected -Adapters @{
            GetProcess = { param($ProcessId) New-CcodSnapshot }
            StopProcess = { param($Snapshot, $TimeoutMilliseconds) [pscustomobject]@{ Outcome = 'TimedOut'; StoppedByController = $false } }
        }
        Assert-CcodEqual 'TimedOut' $delayed.Outcome 'still-running exact handle is a timeout'
        Assert-CcodEqual $false $delayed.StoppedByController 'delayed exit never authorizes launch'
    }

    Invoke-CcodTest 'collects only identity-verified descendants whose parent chain reaches the root' {
        $root = New-CcodSnapshot
        $child = New-CcodSnapshot -ProcessId 101 -CreationTimeUtc '2026-08-02T00:00:01.0000000Z' -ParentPid 100 -IsTopLevel $false -Mode Unrelated -CommandLine '"C:\Codex\ChatGPT.exe" --type=renderer'
        $grandchild = New-CcodSnapshot -ProcessId 102 -CreationTimeUtc '2026-08-02T00:00:02.0000000Z' -ParentPid 101 -IsTopLevel $false -Mode Unrelated -CommandLine '"C:\Codex\ChatGPT.exe" --type=gpu-process'
        $otherSession = New-CcodSnapshot -ProcessId 103 -CreationTimeUtc '2026-08-02T00:00:01.0000000Z' -SessionId 2 -ParentPid 100 -IsTopLevel $false -Mode Unrelated
        $older = New-CcodSnapshot -ProcessId 104 -CreationTimeUtc '2026-08-01T23:59:59.0000000Z' -ParentPid 100 -IsTopLevel $false -Mode Unrelated
        $disconnected = New-CcodSnapshot -ProcessId 105 -CreationTimeUtc '2026-08-02T00:00:03.0000000Z' -ParentPid 999 -IsTopLevel $false -Mode Unrelated
        $wrongPath = New-CcodSnapshot -ProcessId 106 -CreationTimeUtc '2026-08-02T00:00:03.0000000Z' -Path 'C:\Other\ChatGPT.exe' -ParentPid 100 -IsTopLevel $false -Mode Unrelated
        $map = @{
            100 = $root; 101 = $child; 102 = $grandchild; 103 = $otherSession
            104 = $older; 105 = $disconnected; 106 = $wrongPath
        }
        $reads = [pscustomobject]@{ Count = 0 }
        $tree = @(Get-CcodVerifiedProcessTree -Root $root -Adapters @{
            ListProcessIds = { @(100, 101, 102, 103, 104, 105, 106) }
            GetProcess = { param($ProcessId) $reads.Count++; $map[[int]$ProcessId] }.GetNewClosure()
        })
        Assert-CcodEqual 3 $tree.Count 'only root and two verified descendants remain'
        Assert-CcodEqual '100,101,102' (($tree.Pid | Sort-Object) -join ',') 'untrusted parent links never enter the tree'
        Assert-CcodTrue ($reads.Count -ge 7) 'tree identities are read through the process adapter'
    }

    Invoke-CcodTest 'adopts exactly one special transaction candidate' {
        $expected = New-CcodSnapshot -ProcessId 200 -CreationTimeUtc '2026-08-02T00:00:05.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002 -CommandLine 'special'
        $wrongPorts = New-CcodSnapshot -ProcessId 201 -CreationTimeUtc '2026-08-02T00:00:05.0000000Z' -Mode Special -RendererPort 41003 -MainPort 41002 -CommandLine 'special'
        $tooOld = New-CcodSnapshot -ProcessId 202 -CreationTimeUtc '2026-08-01T23:59:59.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002 -CommandLine 'special'
        $otherSession = New-CcodSnapshot -ProcessId 203 -CreationTimeUtc '2026-08-02T00:00:05.0000000Z' -SessionId 2 -Mode Special -RendererPort 41001 -MainPort 41002 -CommandLine 'special'
        $map = @{ 200 = $expected; 201 = $wrongPorts; 202 = $tooOld; 203 = $otherSession }
        $adapters = @{
            GetPackageIdentity = { [pscustomobject]@{ Found=$true; FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe' } }
            GetCurrentSessionId = { 1 }
            GetCurrentUserSid = { 'S-1-5-21-test' }
            ListProcessIds = { @(200, 201, 202, 203) }
            GetProcess = { param($ProcessId, $StatusEvidence) $map[[int]$ProcessId] }.GetNewClosure()
        }
        $candidate = Find-CcodTransactionProcess -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $adapters
        Assert-CcodEqual 200 $candidate.Pid 'the sole exact candidate is adopted'

        $second = New-CcodSnapshot -ProcessId 204 -CreationTimeUtc '2026-08-02T00:00:06.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002 -CommandLine 'special'
        $map[204] = $second
        $ambiguousAdapters = $adapters.Clone()
        $ambiguousAdapters.ListProcessIds = { @(200, 204) }
        $ambiguous = Find-CcodTransactionProcess -RendererPort 41001 -MainPort 41002 -TransactionTimeUtc '2026-08-02T00:00:00.0000000Z' -Adapters $ambiguousAdapters
        Assert-CcodEqual $null $ambiguous 'multiple exact transaction candidates fail closed'
    }

    Invoke-CcodTest 'reserves a nonexcluded IPv4 loopback port' {
        $state = [pscustomobject]@{ Index = 0; Address = $null }
        $ports = @(41001, 41002)
        $port = Get-CcodAvailableLoopbackPort -ExcludedPorts @(41001) -Adapters @{
            ReserveLoopbackPort = {
                param($Address)
                $state.Address = $Address
                $value = $ports[$state.Index]
                $state.Index++
                $value
            }.GetNewClosure()
        }
        Assert-CcodEqual 41002 $port 'excluded reservation is retried'
        Assert-CcodEqual '127.0.0.1' $state.Address 'reservation binds exact IPv4 loopback'
    }

    Invoke-CcodTest 'accepts port closure only after explicit connection refusal' {
        $clock = [pscustomobject]@{ Tick = 0; Delay = 0 }
        $times = @(
            [DateTimeOffset]::Parse('2026-08-02T00:00:00.0000000Z'),
            [DateTimeOffset]::Parse('2026-08-02T00:00:00.0100000Z')
        )
        $probes = [System.Collections.Queue]::new()
        $probes.Enqueue('Open')
        $probes.Enqueue('Refused')
        $closed = Wait-CcodPortClosed -Port 41001 -TimeoutMilliseconds 1000 -PollMilliseconds 10 -Adapters @{
            GetUtcNow = { $value = $times[[Math]::Min($clock.Tick, $times.Count - 1)]; $clock.Tick++; $value }.GetNewClosure()
            ProbeLoopbackPort = { param($Port) $probes.Dequeue() }.GetNewClosure()
            Delay = { param($Milliseconds) $clock.Delay += $Milliseconds }.GetNewClosure()
        }
        Assert-CcodEqual $true $closed 'explicit refusal proves the endpoint closed'
        Assert-CcodEqual 10 $clock.Delay 'open listener is polled rather than treated as closed'

        $notClosed = Wait-CcodPortClosed -Port 41001 -TimeoutMilliseconds 10 -PollMilliseconds 5 -Adapters @{
            GetUtcNow = { [DateTimeOffset]::Parse('2026-08-02T00:00:01.0000000Z') }
            ProbeLoopbackPort = { param($Port) 'Error' }
            Delay = { param($Milliseconds) throw 'must not delay after unrelated error' }
        }
        Assert-CcodEqual $false $notClosed 'unrelated socket errors never prove closure'
    }

    Invoke-CcodTest 'adopts an existing ordinary root before starting recovery' {
        $ordinary = New-CcodSnapshot -ProcessId 300
        $calls = [pscustomobject]@{ Start = 0; Package = 0 }
        $result = Start-CcodProcess -Mode Ordinary -Adapters @{
            GetPackageIdentity = { $calls.Package++; [pscustomobject]@{ Found=$true; FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe' } }.GetNewClosure()
            GetCurrentSessionId = { 1 }
            GetCurrentUserSid = { 'S-1-5-21-test' }
            ListProcessIds = { @(300) }
            GetProcess = { param($ProcessId, $StatusEvidence) $ordinary }.GetNewClosure()
            StartProcess = { param($FilePath, $Arguments, $WindowStyle) $calls.Start++; throw 'must not start' }.GetNewClosure()
        }
        Assert-CcodEqual 'Adopted' $result.Outcome 'recovery adopts an exact live ordinary root'
        Assert-CcodEqual 300 $result.Snapshot.Pid 'adopted identity is returned'
        Assert-CcodEqual 0 $calls.Start 'adoption prevents a duplicate launch'
        Assert-CcodEqual 1 $calls.Package 'launch path is dynamically resolved even when adopting'
    }

    Invoke-CcodTest 'rechecks special ports and launches Codex visibly' {
        $calls = [pscustomobject]@{ Start = 0; Availability = @(); Path = $null; Arguments = @(); WindowStyle = 'unset' }
        $common = @{
            GetPackageIdentity = { [pscustomobject]@{ Found=$true; FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe' } }
            TestLoopbackPortAvailable = { param($Port, $Address) $calls.Availability += "$Address`:$Port"; $true }.GetNewClosure()
            StartProcess = {
                param($FilePath, $Arguments, $WindowStyle)
                $calls.Start++
                $calls.Path = $FilePath
                $calls.Arguments = @($Arguments)
                $calls.WindowStyle = $WindowStyle
                [pscustomobject]@{ Pid = 400 }
            }.GetNewClosure()
        }
        $started = Start-CcodProcess -Mode Special -RendererPort 41001 -MainPort 41002 -Adapters $common
        Assert-CcodEqual 'Started' $started.Outcome 'special process launch returns started'
        Assert-CcodEqual 1 $calls.Start 'special launch boundary is called once'
        Assert-CcodEqual '127.0.0.1:41001,127.0.0.1:41002' ($calls.Availability -join ',') 'both ports are rechecked immediately before launch'
        Assert-CcodEqual 'C:\Codex\ChatGPT.exe' $calls.Path 'dynamic package entrypoint is used'
        Assert-CcodEqual $null $calls.WindowStyle 'Codex window is never hidden'
        Assert-CcodEqual '--remote-debugging-address=127.0.0.1,--remote-debugging-port=41001,--inspect=127.0.0.1:41002' ($calls.Arguments -join ',') 'special arguments are exact'

        $blockedCalls = [pscustomobject]@{ Start = 0 }
        $blockedAdapters = $common.Clone()
        $blockedAdapters.TestLoopbackPortAvailable = { param($Port, $Address) $Port -eq 41001 }
        $blockedAdapters.StartProcess = { param($FilePath, $Arguments, $WindowStyle) $blockedCalls.Start++; throw 'must not start' }.GetNewClosure()
        $blocked = Start-CcodProcess -Mode Special -RendererPort 41001 -MainPort 41002 -Adapters $blockedAdapters
        Assert-CcodEqual 'PortUnavailable' $blocked.Outcome 'binding race fails the special launch'
        Assert-CcodEqual 0 $blockedCalls.Start 'unavailable port is rejected before process start'
    }

    Invoke-CcodTest 'uses Hidden only for an explicit background helper' {
        $call = [pscustomobject]@{ WindowStyle = $null; Path = $null }
        $result = Start-CcodProcess -BackgroundHelper -HelperPath 'C:\Runtime\helper.exe' -HelperArguments @('--serve') -Adapters @{
            StartProcess = { param($FilePath, $Arguments, $WindowStyle) $call.Path = $FilePath; $call.WindowStyle = $WindowStyle; [pscustomobject]@{ Pid = 500 } }.GetNewClosure()
        }
        Assert-CcodEqual 'Started' $result.Outcome 'helper starts through the same adapter boundary'
        Assert-CcodEqual 'C:\Runtime\helper.exe' $call.Path 'explicit helper path is preserved'
        Assert-CcodEqual 'Hidden' $call.WindowStyle 'background helper alone is hidden'
    }

    Invoke-CcodTest 'treats a post-recheck binding race as a failed special launch' {
        $result = Start-CcodProcess -Mode Special -RendererPort 41001 -MainPort 41002 -Adapters @{
            GetPackageIdentity = { [pscustomobject]@{ Found=$true; FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe' } }
            TestLoopbackPortAvailable = { param($Port, $Address) $true }
            StartProcess = { param($FilePath, $Arguments, $WindowStyle) throw [Net.Sockets.SocketException]::new(10048) }
        }
        Assert-CcodEqual 'PortUnavailable' $result.Outcome 'address-in-use after recheck fails closed'
    }
} catch {
    Write-Error $_
    exit 1
}
