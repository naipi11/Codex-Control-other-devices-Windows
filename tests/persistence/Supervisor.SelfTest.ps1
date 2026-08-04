$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$supervisorPath = Join-Path $repositoryRoot 'src\persistence\Supervisor.ps1'
if (-not [IO.File]::Exists($supervisorPath)) {
    throw 'CCOD_TEST_SUPERVISOR_CONTRACT_MISSING'
}

$readyToken = 'a' * 64
. $supervisorPath -ReadyToken $readyToken

function Assert-CcodTrue {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition){throw "ASSERT_TRUE_FAILED: $Message"}
}

function Assert-CcodEqual {
    param($Expected,$Actual,[string]$Message)
    if($Expected -is [array] -or $Actual -is [array]){
        $left=@($Expected)-join '|';$right=@($Actual)-join '|'
        if($left -cne $right){throw "ASSERT_EQUAL_FAILED: $Message expected=[$left] actual=[$right]"}
    }elseif($Expected -is [string] -or $Actual -is [string]){
        if([string]$Expected -cne [string]$Actual){throw "ASSERT_EQUAL_FAILED: $Message expected=[$Expected] actual=[$Actual]"}
    }elseif($Expected -ne $Actual){throw "ASSERT_EQUAL_FAILED: $Message expected=[$Expected] actual=[$Actual]"}
}

function Assert-CcodReceipt {
    param($Receipt,[string]$Outcome,[int]$ExitCode)
    Assert-CcodEqual 'SchemaVersion|Outcome|ExitCode|CleanupCodes' (@($Receipt.PSObject.Properties.Name)-join '|') 'host receipt fields are exact and ordered'
    Assert-CcodEqual 1 $Receipt.SchemaVersion 'host receipt schema'
    Assert-CcodEqual $Outcome $Receipt.Outcome 'host receipt outcome'
    Assert-CcodEqual $ExitCode $Receipt.ExitCode 'host receipt exit code'
    Assert-CcodTrue ($Receipt.CleanupCodes -is [array]) 'cleanup codes are an array'
}

function New-CcodSupervisorFake {
    param([string]$FailAt=$null,[bool]$ShutdownSignaled=$false,[string]$FirstLeaseOutcome='Acquired',[string]$SecondLeaseOutcome='Acquired',[bool]$AccountAbandoned=$false,[bool]$LocalAbandoned=$false)
    $world=[pscustomobject]@{
        Calls=[Collections.Generic.List[string]]::new();FailAt=$FailAt;ShutdownSignaled=$ShutdownSignaled
        FirstLeaseOutcome=$FirstLeaseOutcome;SecondLeaseOutcome=$SecondLeaseOutcome;AccountAbandoned=$AccountAbandoned;LocalAbandoned=$LocalAbandoned
        Elapsed=[Collections.Generic.Queue[long]]::new();ReadySignals=0;StateReads=0;JournalReads=0
        CommandQueue=[Collections.Generic.Queue[object]]::new();EventQueue=[Collections.Generic.Queue[object]]::new();OnTick=$null
        TryDequeueSawRealQueue=$false;NewTraySawRealQueue=$false;NewWatcherSawRealQueue=$false
        ActiveJournal=$null;Decision=[pscustomobject][ordered]@{Action='KeepOrdinary';Reason='Idle';Target=$null;AttemptKey=$null;SuppressionKey=$null;EffectiveClassification=$null;RequiresController=$false}
        ProcessIds=@();Snapshots=@{};Poll=[pscustomobject][ordered]@{Completed=$false;ExitCode=$null;StdoutText='';StdoutByteCount=0;StdoutOverflow=$false;StderrByteCount=0;StderrOverflow=$false}
        WorkerResult=$null;TickCount=0
    }
    $adapters=@{}
    foreach($name in Get-CcodSupervisorAdapterNames){
        $unusedName=$name
        $adapters[$name]={throw "UNEXPECTED_ADAPTER_$unusedName"}.GetNewClosure()
    }
    $identity=[pscustomobject][ordered]@{UserSid='S-1-5-21-111-222-333-1001';SessionId=[int]1;Pid=[int]41;CreationTimeUtc='2030-02-03T03:00:00.0000000Z'}
    $layout=[pscustomobject][ordered]@{
        InstallRoot='C:\Fake\CodexControlOtherDevices';RuntimeRoot='C:\Fake\CodexControlOtherDevices\runtime-1';RuntimeId='runtime-1'
        StateRoot='C:\Fake\CodexControlOtherDevices\state';WorkersRoot='C:\Fake\CodexControlOtherDevices\state\workers'
        ControllerPath='C:\Fake\CodexControlOtherDevices\runtime-1\src\persistence\SessionController.ps1'
        StaticWorkerPath='C:\Fake\CodexControlOtherDevices\runtime-1\src\persistence\StaticProbeWorker.ps1'
        PowerShellPath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';LogDirectory='C:\Fake\CodexControlOtherDevices\logs'
        TransitionPath='C:\Fake\CodexControlOtherDevices\state\transition.json'
    }
    $newLease={
        param([string]$Kind,[string]$Outcome,[bool]$Abandoned)
        [pscustomobject][ordered]@{SchemaVersion=1;Name="Fake-$Kind";Kind=$Kind;Outcome=$Outcome;CreatedNew=($Outcome -ceq 'Acquired');Abandoned=($Abandoned -and $Outcome -ceq 'Acquired');Handle=$(if($Outcome -ceq 'Acquired'){New-Object object}else{$null});OwnerManagedThreadId=[Threading.Thread]::CurrentThread.ManagedThreadId;Released=$false}
    }
    $newEvent={
        param([string]$Kind)
        [pscustomobject][ordered]@{SchemaVersion=1;Name="Fake-$Kind";Kind=$Kind;CreatedNew=$false;Handle=[pscustomobject]@{Kind=$Kind};Disposed=$false}
    }
    $adapters.GetIdentity={$world.Calls.Add('Identity');$identity}.GetNewClosure()
    $adapters.ResolveLayout={$world.Calls.Add('Layout');$layout}.GetNewClosure()
    $adapters.StartClock={$world.Calls.Add('Clock');[pscustomobject]@{Kind='Clock'}}.GetNewClosure()
    $adapters.GetElapsedMilliseconds={param($Clock)if($world.Elapsed.Count){[long]$world.Elapsed.Dequeue()}else{[long]0}}.GetNewClosure()
    $adapters.GetUtcNow={[DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime()}.GetNewClosure()
    $adapters.EnterLease={
        param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)
        $world.Calls.Add("Enter:$Kind`:$TimeoutMilliseconds")
        if($world.FailAt -ceq "Enter$Kind"){throw 'PRIVATE_ENTER_SECRET'}
        if($Kind -ceq 'AccountSupervisor'){& $newLease $Kind $world.FirstLeaseOutcome $world.AccountAbandoned}else{& $newLease $Kind $world.SecondLeaseOutcome $world.LocalAbandoned}
    }.GetNewClosure()
    $adapters.ExitLease={param($Lease)$world.Calls.Add("Exit:$($Lease.Kind)");if($world.FailAt -ceq "Exit$($Lease.Kind)"){throw 'PRIVATE_EXIT_SECRET'};$true}.GetNewClosure()
    $adapters.OpenReadyEvent={param($UserSid,$SessionId,$Token)$world.Calls.Add('Open:Ready');if($world.FailAt -ceq 'OpenReady'){throw 'PRIVATE_READY_SECRET'};& $newEvent 'Ready'}.GetNewClosure()
    $adapters.OpenShutdownEvent={param($UserSid,$SessionId)$world.Calls.Add('Open:Shutdown');if($world.FailAt -ceq 'OpenShutdown'){throw 'PRIVATE_SHUTDOWN_SECRET'};& $newEvent 'Shutdown'}.GetNewClosure()
    $adapters.IsEventSignaled={param($Event)$world.Calls.Add("Check:$($Event.Kind)");if($Event.Kind -ceq 'Shutdown'){[bool]$world.ShutdownSignaled}else{$false}}.GetNewClosure()
    $adapters.SignalEvent={param($Event)$world.Calls.Add("Signal:$($Event.Kind)");if($world.FailAt -ceq 'SignalReady'){throw 'PRIVATE_SIGNAL_SECRET'};$world.ReadySignals++}.GetNewClosure()
    $adapters.CloseEvent={param($Event)$world.Calls.Add("Close:$($Event.Kind)");if($world.FailAt -ceq "Close$($Event.Kind)"){throw 'PRIVATE_CLOSE_SECRET'}}.GetNewClosure()
    $adapters.ReadState={param($StateRoot)$world.Calls.Add('Read:State');$world.StateReads++;if($world.FailAt -ceq 'ReadState'){throw 'PRIVATE_STATE_SECRET'};[pscustomobject]@{AutomationEnabled=$true;Settings=[pscustomobject]@{candidateCompatibleOptIn=$false};Damage=$null}}.GetNewClosure()
    $adapters.ReadJournal={param($Path)$world.Calls.Add('Read:Journal');$world.JournalReads++;if($world.FailAt -ceq 'ReadJournal'){throw 'PRIVATE_JOURNAL_SECRET'};$world.ActiveJournal}.GetNewClosure()
    $adapters.EnumerateProcessIds={$world.Calls.Add('Enumerate');Write-Output -NoEnumerate @($world.ProcessIds)}.GetNewClosure()
    $adapters.GetProcessSnapshot={param($Pid)$world.Calls.Add("Snapshot:$Pid");if($world.Snapshots.ContainsKey([int]$Pid)){$world.Snapshots[[int]$Pid]}else{$null}}.GetNewClosure()
    $adapters.GetSupervisorDecision={param($Context)$world.Calls.Add('Decision');$world.Decision}.GetNewClosure()
    $adapters.AddObservedEvent={param($Observed,$Pid,$Created)$world.Calls.Add("Observed:$Pid");$true}.GetNewClosure()
    $adapters.CompleteControllerRun={param($Result,$TransactionId,$Action,$RuntimeId)$world.Calls.Add("Reduce:$Action");[pscustomobject][ordered]@{SessionState='Idle';BlockAutomaticActions=$false;AttemptKey=$null;RecoveryIgnoreKey=$null;SuppressionKey=$null;ErrorCode=$null;Reason='Reduced'}}.GetNewClosure()
    $adapters.GetTrayPresentation={param($Arguments)[pscustomobject][ordered]@{Color='Gray';Tooltip='Idle';StatusText='Idle';ApplyNowEnabled=$true;ManualRetryEnabled=$false;AutomationToggleEnabled=$true;AutomationChecked=$true;CandidateOptInToggleEnabled=$true;CandidateOptInChecked=$false;OpenLogsEnabled=$true;UninstallEnabled=$false;Busy=$false}}.GetNewClosure()
    $adapters.NewQueue={param($Kind)$world.Calls.Add("Queue:$Kind");if($Kind -ceq 'Command'){Write-Output -NoEnumerate $world.CommandQueue}else{Write-Output -NoEnumerate $world.EventQueue}}.GetNewClosure()
    $adapters.GetQueueCount={param($Queue)[int]$Queue.Count}.GetNewClosure()
    $adapters.TryDequeue={param($Queue)$world.TryDequeueSawRealQueue=[object]::ReferenceEquals($Queue,$world.CommandQueue);if($Queue.Count){[pscustomobject][ordered]@{Succeeded=$true;Value=$Queue.Dequeue()}}else{[pscustomobject][ordered]@{Succeeded=$false;Value=$null}}}.GetNewClosure()
    $adapters.NewTray={param($Queue,$OnTick)$world.NewTraySawRealQueue=[object]::ReferenceEquals($Queue,$world.CommandQueue);$world.Calls.Add('New:Tray');if($world.FailAt -ceq 'NewTray'){throw 'PRIVATE_TRAY_SECRET'};$world.OnTick=$OnTick;[pscustomobject]@{Kind='Tray';Timer=[pscustomobject]@{Kind='Timer'};ApplicationContext=[pscustomobject]@{Kind='App'}}}.GetNewClosure()
    $adapters.SetTrayPresentation={param($Tray,$Presentation,$PackageText,$RuntimeText)$world.Calls.Add('Set:Presentation')}.GetNewClosure()
    $adapters.StopTrayTimer={param($Tray)$world.Calls.Add('Stop:Timer');if($world.FailAt -ceq 'StopTimer'){throw 'PRIVATE_TIMER_SECRET'}}.GetNewClosure()
    $adapters.RequestUiExit={param($Tray)$world.Calls.Add('Exit:UI')}.GetNewClosure()
    $adapters.CloseTray={param($Tray)$world.Calls.Add('Close:Tray');if($world.FailAt -ceq 'CloseTray'){throw 'PRIVATE_TRAY_CLOSE_SECRET'};[pscustomobject][ordered]@{SchemaVersion=1;Closed=$true;CleanupCodes=@()}}.GetNewClosure()
    $adapters.NewWatcher={param($Queue,$OnFull)$world.NewWatcherSawRealQueue=[object]::ReferenceEquals($Queue,$world.EventQueue);$world.Calls.Add('New:Watcher');if($world.FailAt -ceq 'NewWatcher'){throw 'PRIVATE_WATCHER_SECRET'};[pscustomobject]@{Kind='Watcher';Mode='ReconciliationOnly'}}.GetNewClosure()
    $adapters.StopWatcher={param($Watcher)$world.Calls.Add('Stop:Watcher');if($world.FailAt -ceq 'StopWatcher'){throw 'PRIVATE_WATCHER_STOP_SECRET'};[pscustomobject][ordered]@{SchemaVersion=1;Stopped=$true;CleanupCodes=@()}}.GetNewClosure()
    $adapters.GetWorkerLeafState={param($Path)$world.Calls.Add("Leaf:$([IO.Path]::GetFileName($Path))");[pscustomobject][ordered]@{Exists=$false;IsReparse=$false}}.GetNewClosure()
    $adapters.WriteWorkerRequest={param($Path,$Request)$world.Calls.Add("Write:$($Request.action)")}.GetNewClosure()
    $adapters.StartWorker={param($Kind,$ScriptPath,$RequestPath,$ResultPath,$StderrPath,$Request,$PowerShellPath)$world.Calls.Add("Start:$Kind`:$($Request.action)");[pscustomobject][ordered]@{ProcessId=501;CreationTimeUtc='2030-02-03T03:05:00.0000000Z';Handle=[pscustomobject]@{Kind='Worker'}}}.GetNewClosure()
    $adapters.PollWorker={param($Slot)$world.Calls.Add("Poll:$($Slot.Kind)");$world.Poll}.GetNewClosure()
    $adapters.ReadWorkerResult={param($Path)$world.Calls.Add('Read:WorkerResult');$world.WorkerResult}.GetNewClosure()
    $adapters.WaitWorker={param($Slot,$Timeout)$world.Calls.Add("Wait:Worker:$Timeout");$true}.GetNewClosure()
    $adapters.GetWorkerIdentity={param($Pid)$world.Calls.Add("WorkerIdentity:$Pid");[pscustomobject][ordered]@{Pid=$Pid;CreationTimeUtc='2030-02-03T03:05:00.0000000Z'}}.GetNewClosure()
    $adapters.TerminateWorker={param($Slot)$world.Calls.Add("Terminate:$($Slot.ProcessId)");$true}.GetNewClosure()
    $adapters.DisposeWorker={param($Slot)$world.Calls.Add("Dispose:$($Slot.ProcessId)")}.GetNewClosure()
    $adapters.DeleteWorkerFile={param($Path)$world.Calls.Add("Delete:$([IO.Path]::GetFileName($Path))")}.GetNewClosure()
    $adapters.ClearFailedAttempt={param($StateRoot,$Package,$Hash,$Runtime,$Timestamp)$world.Calls.Add('Manual:Clear');[pscustomobject][ordered]@{Outcome='Cleared'}}.GetNewClosure()
    $adapters.SetAutomationEnabled={param($StateRoot,$Enabled)$world.Calls.Add("Automation:$Enabled")}.GetNewClosure()
    $adapters.SetCandidateOptIn={param($StateRoot,$Enabled)$world.Calls.Add("Candidate:$Enabled")}.GetNewClosure()
    $adapters.OpenLogs={param($Path)$world.Calls.Add('Open:Logs')}.GetNewClosure()
    $adapters.RunUiContext={param($Tray)$world.Calls.Add('Run:UI');if($world.FailAt -ceq 'RunUi'){throw 'PRIVATE_UI_SECRET'};if($world.TickCount -gt 0){foreach($index in 1..$world.TickCount){& $world.OnTick}}}.GetNewClosure()
    $adapters.WriteLog={param($Record)$world.Calls.Add("Log:$($Record.code)")}.GetNewClosure()
    [pscustomobject]@{World=$world;Adapters=$adapters;Identity=$identity;Layout=$layout}
}

function New-CcodTickFixture {
    $fake=New-CcodSupervisorFake
    $shutdown=[pscustomobject][ordered]@{SchemaVersion=1;Name='Fake-Shutdown';Kind='Shutdown';CreatedNew=$false;Handle=[pscustomobject]@{Kind='Shutdown'};Disposed=$false}
    $state=[pscustomobject]@{AutomationEnabled=$true;AutomaticCandidateTrialsAllowed=$false;Settings=[pscustomobject]@{candidateCompatibleOptIn=$false};VerifiedPackages=[pscustomobject][ordered]@{schemaVersion=1;packages=[ordered]@{}};Damage=[pscustomobject]@{}}
    $hostState=New-CcodSupervisorHostState -Identity $fake.Identity -Layout $fake.Layout -Clock ([pscustomobject]@{Kind='Clock'}) -ShutdownEvent $shutdown -CommandQueue $fake.World.CommandQueue -EventQueue $fake.World.EventQueue -State $state -Journal $null
    $hostState.Tray=[pscustomobject]@{Kind='Tray'}
    [pscustomobject]@{Fake=$fake;Host=$hostState}
}

function New-CcodTestTransition {
    [pscustomobject][ordered]@{
        transactionId='5f496d99-c839-4458-a6a2-d37ea1afdbda';stage='IntentWritten';sourcePid=71;sourceCreationTimeUtc='2030-02-03T03:01:00.0000000Z'
        packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';appAsarSha256=('b'*64);runtimeId='runtime-1';mainPort=41002;rendererPort=41001
        specialPid=$null;specialCreationTimeUtc=$null;recoveryPid=$null;recoveryCreationTimeUtc=$null;createdAtUtc='2030-02-03T03:02:00.0000000Z';updatedAtUtc='2030-02-03T03:02:00.0000000Z'
    }
}

$results=[Collections.Generic.List[string]]::new()
function Invoke-CcodTest {
    param([string]$Name,[scriptblock]$Body)
    & $Body
    $results.Add($Name);Write-Output "PASS $Name"
}

Invoke-CcodTest 'exposes only the frozen ReadyToken CLI and rejects an invalid token before adapters' {
    $parameters=(Get-Command $supervisorPath).Parameters.Keys|Where-Object{$_ -notin @('Verbose','Debug','ErrorAction','WarningAction','InformationAction','ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable')}
    Assert-CcodEqual 'ReadyToken' (@($parameters)-join '|') 'Supervisor CLI has one business parameter'
    $fake=New-CcodSupervisorFake
    $receipt=Invoke-CcodSupervisorHost -ReadyToken ('A'*64) -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'StartupRejected' 2
    Assert-CcodEqual 0 $fake.World.Calls.Count 'invalid token invokes no adapter'
}

Invoke-CcodTest 'acquires both lifetime leases and signals Ready only after all prerequisites' {
    $fake=New-CcodSupervisorFake
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodEqual 1 $fake.World.ReadySignals 'Ready signals once'
    Assert-CcodTrue $fake.World.NewTraySawRealQueue 'tray receives the command queue itself'
    Assert-CcodTrue $fake.World.NewWatcherSawRealQueue 'watcher receives the event queue itself'
    $calls=@($fake.World.Calls)
    foreach($before in @('Enter:AccountSupervisor:5000','Enter:Supervisor:5000','Open:Ready','Open:Shutdown','Read:State','Read:Journal','Queue:Command','Queue:Event','New:Tray','New:Watcher')){
        Assert-CcodTrue ([Array]::IndexOf($calls,$before) -ge 0) "$before occurs"
        Assert-CcodTrue ([Array]::IndexOf($calls,$before) -lt [Array]::IndexOf($calls,'Signal:Ready')) "$before precedes Ready"
    }
    Assert-CcodTrue ([Array]::IndexOf($calls,'Signal:Ready') -lt [Array]::IndexOf($calls,'Run:UI')) 'Ready precedes message loop'
    Assert-CcodTrue ([Array]::IndexOf($calls,'Exit:Supervisor') -lt [Array]::IndexOf($calls,'Exit:AccountSupervisor')) 'leases release in reverse order'
}

Invoke-CcodTest 'uses one monotonic 5000ms acquisition budget' {
    $fake=New-CcodSupervisorFake
    $fake.World.Elapsed.Enqueue([long]0);$fake.World.Elapsed.Enqueue([long]4200)
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodTrue ($fake.World.Calls.Contains('Enter:AccountSupervisor:5000')) 'first lease receives full budget'
    Assert-CcodTrue ($fake.World.Calls.Contains('Enter:Supervisor:800')) 'second lease receives only remainder'
}

Invoke-CcodTest 'does not take over or signal Ready when either lifetime lease times out' {
    foreach($case in @(
        [pscustomobject]@{First='TimedOut';Second='Acquired';Expected='Enter:AccountSupervisor:5000';Forbidden='Enter:Supervisor:5000'},
        [pscustomobject]@{First='Acquired';Second='TimedOut';Expected='Enter:Supervisor:5000';Forbidden='Open:Ready'}
    )){
        $fake=New-CcodSupervisorFake -FirstLeaseOutcome $case.First -SecondLeaseOutcome $case.Second
        $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
        Assert-CcodReceipt $receipt 'StartupRejected' 2
        Assert-CcodEqual 0 $fake.World.ReadySignals 'timeout never signals Ready'
        Assert-CcodTrue ($fake.World.Calls.Contains($case.Expected)) 'expected lease attempt occurs'
        Assert-CcodTrue (-not $fake.World.Calls.Contains($case.Forbidden)) 'timeout prevents takeover path'
        Assert-CcodTrue (@($fake.World.Calls|Where-Object{$_ -like 'Terminate*'}).Count -eq 0) 'timeout never terminates another process'
    }
}

Invoke-CcodTest 'treats abandoned leases as ownership and records only a fixed warning' {
    $fake=New-CcodSupervisorFake -AccountAbandoned $true -LocalAbandoned $true
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodTrue ($fake.World.Calls.Contains('Log:CCOD_SUPERVISOR_LEASE_ABANDONED')) 'abandonment produces fixed warning code'
    Assert-CcodEqual 1 $fake.World.StateReads 'fresh state is read'
    Assert-CcodEqual 1 $fake.World.JournalReads 'fresh journal is read'
}

Invoke-CcodTest 'never signals Ready when Shutdown is already signaled' {
    $fake=New-CcodSupervisorFake -ShutdownSignaled $true
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'StartupRejected' 2
    Assert-CcodEqual 0 $fake.World.ReadySignals 'pre-signaled Shutdown blocks Ready'
    Assert-CcodTrue (-not $fake.World.Calls.Contains('Run:UI')) 'message loop never starts'
    Assert-CcodTrue ($fake.World.Calls.Contains('Close:Shutdown')) 'Shutdown handle is still closed'
}

Invoke-CcodTest 'contains initialization secrets and runs every available cleanup stage' {
    foreach($stage in @('ReadState','ReadJournal','NewTray','NewWatcher','SignalReady','RunUi')){
        $fake=New-CcodSupervisorFake -FailAt $stage
        $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
        Assert-CcodReceipt $receipt 'Failed' 1
        Assert-CcodEqual 0 (($receipt|ConvertTo-Json -Compress).Contains('PRIVATE_')) "$stage secret is absent from receipt"
        Assert-CcodTrue ($fake.World.Calls.Contains('Exit:Supervisor')) "$stage releases local lease"
        Assert-CcodTrue ($fake.World.Calls.Contains('Exit:AccountSupervisor')) "$stage releases account lease"
    }
}

Invoke-CcodTest 'continues cleanup after timer watcher tray event and lease failures' {
    foreach($stage in @('StopTimer','StopWatcher','CloseTray','CloseReady','CloseShutdown','ExitSupervisor','ExitAccountSupervisor')){
        $fake=New-CcodSupervisorFake -FailAt $stage
        $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
        Assert-CcodReceipt $receipt 'Stopped' 0
        Assert-CcodTrue ($receipt.CleanupCodes.Count -ge 1) "$stage yields a bounded cleanup code"
        Assert-CcodTrue ($fake.World.Calls.Contains('Exit:AccountSupervisor')) "$stage does not skip final account release attempt"
        Assert-CcodEqual 0 (($receipt|ConvertTo-Json -Compress).Contains('PRIVATE_')) "$stage secret is absent from cleanup receipt"
    }
}

Invoke-CcodTest 'rejects malformed or partial adapter sets before any lifecycle action' {
    $fake=New-CcodSupervisorFake
    [void]$fake.Adapters.Remove('OpenReadyEvent')
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'StartupRejected' 2
    Assert-CcodEqual 0 $fake.World.Calls.Count 'partial adapter set invokes nothing'
    $fake2=New-CcodSupervisorFake;$fake2.Adapters.Extra={}
    $receipt2=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake2.Adapters
    Assert-CcodReceipt $receipt2 'StartupRejected' 2
    Assert-CcodEqual 0 $fake2.World.Calls.Count 'extra adapter set invokes nothing'
}

Invoke-CcodTest 'gives Shutdown absolute priority over a slot journal command and decision' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $world.ShutdownSignaled=$true;$world.ActiveJournal=New-CcodTestTransition
    $world.Decision=[pscustomobject][ordered]@{Action='ApplyOrdinary';Reason='Ready';Target=[pscustomobject]@{Pid=71;CreationTimeUtc='2030-02-03T03:01:00.0000000Z'};AttemptKey='71|2030-02-03T03:01:00.0000000Z';SuppressionKey=$null;EffectiveClassification='CandidateCompatible';RequiresController=$true}
    $world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind='ApplyNow';Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})
    $hostState.WorkerSlot=[pscustomobject]@{Kind='Controller';ProcessId=501}
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodTrue $hostState.ShutdownRequested 'shutdown latches'
    Assert-CcodTrue ($world.Calls.Contains('Exit:UI')) 'shutdown requests message-loop exit'
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Poll:*' -or $_ -like 'Start:*' -or $_ -eq 'Read:State'}).Count 'no lower priority work runs'
}

Invoke-CcodTest 'reserves the whole tick for a slot that existed at tick entry' {
    foreach($completed in @($false,$true)){
        $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
        $world.ActiveJournal=New-CcodTestTransition
        $world.Poll=[pscustomobject][ordered]@{Completed=[bool]$completed;ExitCode=$(if($completed){0}else{$null});StdoutText='';StdoutByteCount=0;StdoutOverflow=$false;StderrByteCount=0;StderrOverflow=$false}
        $hostState.WorkerSlot=[pscustomobject][ordered]@{Kind='Controller';Action='Inspect';RequestId=('c'*32);RuntimeId='runtime-1';Request=$null;RequestPath='C:\Fake\CodexControlOtherDevices\state\workers\controller-cccccccccccccccccccccccccccccccc.request.json';ResultPath='C:\Fake\CodexControlOtherDevices\state\workers\controller-cccccccccccccccccccccccccccccccc.result.json';StderrPath='C:\Fake\CodexControlOtherDevices\state\workers\controller-cccccccccccccccccccccccccccccccc.stderr.log';ProcessId=501;CreationTimeUtc='2030-02-03T03:05:00.0000000Z';Handle=[pscustomobject]@{Kind='Worker'}}
        Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
        Assert-CcodEqual 1 @($world.Calls|Where-Object{$_ -eq 'Poll:Controller'}).Count 'slot polls once'
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:*'}).Count 'no same-tick replacement starts'
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -eq 'Read:State'}).Count 'slot tick does no lower-priority state read'
        if($completed){Assert-CcodEqual $null $hostState.WorkerSlot 'completed slot clears after cleanup'}else{Assert-CcodTrue ($null -ne $hostState.WorkerSlot) 'incomplete slot remains owned'}
    }
}

Invoke-CcodTest 'starts Recover for a fresh journal before one queued command' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $world.ActiveJournal=New-CcodTestTransition
    $world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind='OpenLogs';Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodTrue ($world.Calls.Contains('Start:Controller:Recover')) 'journal starts Recover controller'
    Assert-CcodEqual 1 $world.CommandQueue.Count 'higher-priority recovery leaves command queued'
}

Invoke-CcodTest 'starts persisted-special Inspect before a queued command' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $hostState.SpecialNeedsInspect=$true
    $world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind='OpenLogs';Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodTrue ($world.Calls.Contains('Start:Controller:Inspect')) 'special proof starts Inspect'
    Assert-CcodEqual 1 $world.CommandQueue.Count 'special Inspect leaves command queued'
}

Invoke-CcodTest 'processes at most one command before reducer decisions' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $world.Decision=[pscustomobject][ordered]@{Action='RepairRenderer';Reason='Repair';Target=$null;AttemptKey=$null;SuppressionKey=$null;EffectiveClassification=$null;RequiresController=$true}
    foreach($kind in @('OpenLogs','ApplyNow')){$world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind=$kind;Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})}
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodTrue ($world.Calls.Contains('Open:Logs')) 'first command executes'
    Assert-CcodTrue $world.TryDequeueSawRealQueue 'command dequeue receives the queue object itself'
    Assert-CcodEqual 1 $world.CommandQueue.Count 'only one command is consumed'
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:*'}).Count 'decision does not run in command tick'
}

Invoke-CcodTest 'passes queue objects themselves during host creation with non-empty queues' {
    $fake=New-CcodSupervisorFake
    $fake.World.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind='OpenLogs';Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})
    $fake.World.EventQueue.Enqueue([pscustomobject][ordered]@{ProcessId=71;EventKind='Started';ObservedAtUtc='2030-02-03T03:04:05.0000000Z'})
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodTrue $fake.World.NewTraySawRealQueue 'non-empty command queue is not enumerated into tray arguments'
    Assert-CcodTrue $fake.World.NewWatcherSawRealQueue 'non-empty event queue is not enumerated into watcher arguments'
    Assert-CcodTrue ($null -ne $fake.World.OnTick) 'tray callback is the second argument'
}

Invoke-CcodTest 'drains the command queue through the real queue object' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World
    foreach($kind in @('OpenLogs','ApplyNow')){$world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind=$kind;Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})}
    Invoke-CcodSupervisorDrainQueue $world.CommandQueue $fixture.Fake.Adapters
    Assert-CcodEqual 0 $world.CommandQueue.Count 'drain consumes every queued command'
    Assert-CcodTrue $world.TryDequeueSawRealQueue 'drain dequeue receives the queue object itself'
}

Invoke-CcodTest 'routes Repair StaticProbe and Apply through the one worker slot' {
    $cases=@(
        [pscustomobject]@{Decision='RepairRenderer';Kind='Controller';Action='RepairRenderer';Target=$null},
        [pscustomobject]@{Decision='InspectOrdinary';Kind='StaticProbe';Action='StaticProbe';Target=[pscustomobject]@{Pid=71;CreationTimeUtc='2030-02-03T03:01:00.0000000Z'}},
        [pscustomobject]@{Decision='ApplyOrdinary';Kind='Controller';Action='Apply';Target=[pscustomobject]@{Pid=71;CreationTimeUtc='2030-02-03T03:01:00.0000000Z'}}
    )
    foreach($case in $cases){
        $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
        $world.Decision=[pscustomobject][ordered]@{Action=$case.Decision;Reason='Test';Target=$case.Target;AttemptKey=$(if($null -ne $case.Target){'71|2030-02-03T03:01:00.0000000Z'}else{$null});SuppressionKey=$null;EffectiveClassification=$(if($case.Decision -eq 'ApplyOrdinary'){'CandidateCompatible'}else{$null});RequiresController=$true}
        Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
        Assert-CcodTrue ($world.Calls.Contains("Start:$($case.Kind):$($case.Action)")) "$($case.Decision) maps to exact worker"
        Assert-CcodEqual $case.Kind $hostState.WorkerSlot.Kind "$($case.Decision) owns one slot"
    }
}

Invoke-CcodTest 'keeps production defaults lazy and source free of forbidden direct mutations' {
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($supervisorPath,[ref]$tokens,[ref]$errors)
    Assert-CcodEqual 0 @($errors).Count 'Supervisor parses cleanly'
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    foreach($forbidden in @('Get-AppxPackage','Stop-Process','Start-Process','schtasks.exe','Set-ItemProperty','New-ItemProperty','netsh.exe')){
        Assert-CcodEqual 0 @($commands|Where-Object{$_ -ceq $forbidden}).Count "$forbidden is absent from Supervisor AST"
    }
    $loadedSystemTypes=@('System.Windows.Forms.Application'|Where-Object{$_ -as [type]})
    Assert-CcodEqual 0 $loadedSystemTypes.Count 'fake tests do not load WinForms'
}


Invoke-CcodTest 'default adapters keep imported modules visible for lease acquisition' {
    $defaults = Get-CcodSupervisorDefaultAdapters
    Assert-CcodTrue ($defaults.ContainsKey('EnterLease')) 'default EnterLease exists'
    $identity = & $defaults.GetIdentity
    Assert-CcodTrue ($identity.UserSid -is [string] -and $identity.UserSid.Length -gt 0) 'default identity returns current SID'
    $lease = $null
    try {
        $lease = & $defaults.EnterLease 'AccountSupervisor' $identity.UserSid $null 1000
        Assert-CcodEqual 'AccountSupervisor' $lease.Kind 'default EnterLease returns AccountSupervisor lease'
        Assert-CcodTrue (@('Acquired','TimedOut') -ccontains $lease.Outcome) 'default EnterLease returns a valid outcome'
    } finally {
        if ($null -ne $lease -and $lease.Outcome -ceq 'Acquired') {
            $released = & $defaults.ExitLease $lease
            Assert-CcodEqual $true $released 'default ExitLease releases the lease'
        }
    }
}
Write-Output "Supervisor self-tests passed: $($results.Count)"
