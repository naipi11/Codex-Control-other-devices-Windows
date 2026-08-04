[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ReadyToken
)

Set-StrictMode -Version 2.0

$script:CcodSupervisorScriptPath=if([string]::IsNullOrWhiteSpace($PSCommandPath)){$null}else{[IO.Path]::GetFullPath($PSCommandPath)}
$script:CcodSupervisorLogPath=$null
$script:CcodSupervisorAdapterNames=@(
    'GetIdentity','ResolveLayout','StartClock','GetElapsedMilliseconds','GetUtcNow',
    'EnterLease','ExitLease','OpenReadyEvent','OpenShutdownEvent','IsEventSignaled','SignalEvent','CloseEvent',
    'ReadState','ReadJournal','EnumerateProcessIds','GetProcessSnapshot','GetSupervisorDecision','AddObservedEvent','CompleteControllerRun','GetTrayPresentation',
    'NewQueue','GetQueueCount','TryDequeue','NewTray','SetTrayPresentation','StopTrayTimer','RequestUiExit','CloseTray','NewWatcher','StopWatcher',
    'GetWorkerLeafState','WriteWorkerRequest','StartWorker','PollWorker','ReadWorkerResult','WaitWorker','GetWorkerIdentity','TerminateWorker','DisposeWorker','DeleteWorkerFile',
    'ClearFailedAttempt','SetAutomationEnabled','SetCandidateOptIn','OpenLogs','WriteLog','RunUiContext'
)
$script:CcodSupervisorCleanupAllowlist=@(
    'CCOD_SUPERVISOR_LOG_FAILED','CCOD_SUPERVISOR_TIMER_STOP_FAILED','CCOD_SUPERVISOR_WORKER_WAIT_FAILED',
    'CCOD_SUPERVISOR_WORKER_TERMINATE_FAILED','CCOD_SUPERVISOR_WORKER_DISPOSE_FAILED','CCOD_SUPERVISOR_WORKER_FILE_DELETE_FAILED',
    'CCOD_SUPERVISOR_WATCHER_STOP_FAILED','CCOD_SUPERVISOR_QUEUE_DRAIN_FAILED','CCOD_SUPERVISOR_TRAY_CLOSE_FAILED',
    'CCOD_SUPERVISOR_READY_CLOSE_FAILED','CCOD_SUPERVISOR_SHUTDOWN_CLOSE_FAILED','CCOD_SUPERVISOR_LOCAL_RELEASE_FAILED',
    'CCOD_SUPERVISOR_ACCOUNT_RELEASE_FAILED'
)

function Get-CcodSupervisorAdapterNames {
    return @($script:CcodSupervisorAdapterNames)
}

function Test-CcodSupervisorExactProperties {
    param($Value,[string[]]$Names)
    try{
        if($null -eq $Value -or $Value -isnot [pscustomobject]){return $false}
        $actual=@($Value.PSObject.Properties.Name)
        if($actual.Count -ne $Names.Count){return $false}
        for($index=0;$index -lt $Names.Count;$index++){
            if($actual[$index] -cne $Names[$index] -or $Value.PSObject.Properties[$actual[$index]].MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty){return $false}
        }
        return $true
    }catch{return $false}
}

function Test-CcodSupervisorCanonicalUtc {
    param($Value)
    if($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'){return $false}
    $parsed=[DateTime]::MinValue
    return [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodSupervisorDiagnosticRecord {
    param($Value)
    return $Value -is [Management.Automation.ErrorRecord] -or $Value -is [Management.Automation.WarningRecord] -or
        $Value -is [Management.Automation.VerboseRecord] -or $Value -is [Management.Automation.DebugRecord] -or
        $Value -is [Management.Automation.InformationRecord]
}

function Invoke-CcodSupervisorAdapterCapture {
    param([scriptblock]$Callback,[object[]]$Arguments)
    if($Callback -isnot [scriptblock]){return [pscustomobject]@{Threw=$true;Items=@()}}
    $items=[Collections.Generic.List[object]]::new();$threw=$false;$startingErrors=[object[]]@($global:Error)
    $variables=[Collections.Generic.List[Management.Automation.PSVariable]]::new()
    foreach($name in @('ErrorActionPreference','WarningPreference','VerbosePreference','DebugPreference','InformationPreference')){
        $variables.Add([Management.Automation.PSVariable]::new($name,'Continue'))
    }
    $invoker={param($InnerCallback,$InnerVariables,$InnerArguments)$InnerCallback.InvokeWithContext($null,$InnerVariables,[object[]]$InnerArguments)}
    try{
        & $invoker $Callback $variables $Arguments *>&1|ForEach-Object{
            if($items.Count -ge 16){throw 'adapter output limit exceeded'}
            $items.Add($_)
        }
    }catch{$threw=$true}
    finally{
        $historyChanged=$global:Error.Count -ne $startingErrors.Count
        if(-not $historyChanged){
            for($index=0;$index -lt $startingErrors.Count;$index++){
                if(-not [object]::ReferenceEquals($startingErrors[$index],$global:Error[$index])){$historyChanged=$true;break}
            }
        }
        if($historyChanged){$threw=$true}
        $global:Error.Clear();foreach($entry in $startingErrors){[void]$global:Error.Add($entry)}
    }
    return [pscustomobject]@{Threw=[bool]$threw;Items=@($items)}
}

function Invoke-CcodSupervisorAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments,[int]$OutputCount)
    $capture=Invoke-CcodSupervisorAdapterCapture $Callback $Arguments
    if($capture.Threw){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}
    foreach($item in $capture.Items){if(Test-CcodSupervisorDiagnosticRecord $item){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}}
    if($capture.Items.Count -ne $OutputCount){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}
    if($OutputCount -eq 1){Write-Output -NoEnumerate $capture.Items[0]}
}

function Invoke-CcodSupervisorNullableAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments)
    $capture=Invoke-CcodSupervisorAdapterCapture $Callback $Arguments
    if($capture.Threw){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}
    foreach($item in $capture.Items){if(Test-CcodSupervisorDiagnosticRecord $item){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}}
    if($capture.Items.Count -gt 1){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}
    if($capture.Items.Count -eq 1){Write-Output -NoEnumerate $capture.Items[0]}
}

function Import-CcodSupervisorModules {
    if($null -eq $script:CcodSupervisorScriptPath){throw 'supervisor script path is unavailable'}
    $moduleRoot=Join-Path (Split-Path $script:CcodSupervisorScriptPath -Parent) 'modules'
    foreach($leaf in @('KernelObjects.psm1','PersistenceIO.psm1','StateStore.psm1','TransitionJournal.psm1','ProcessControl.psm1','SupervisorEngine.psm1','TrayUi.psm1')){
        Import-Module -Name (Join-Path $moduleRoot $leaf) -Force -ErrorAction Stop
    }
}

function Resolve-CcodSupervisorLayout {
    if($null -eq $script:CcodSupervisorScriptPath -or -not [IO.Path]::IsPathRooted($script:CcodSupervisorScriptPath)){throw 'runtime path is unavailable'}
    $persistenceRoot=Split-Path $script:CcodSupervisorScriptPath -Parent
    $sourceRoot=Split-Path $persistenceRoot -Parent
    $runtimeRoot=[IO.Path]::GetFullPath((Split-Path $sourceRoot -Parent))
    $runtimeId=Split-Path $runtimeRoot -Leaf
    $runtimeContainer=Split-Path $runtimeRoot -Parent
    if((Split-Path $runtimeContainer -Leaf) -cne 'runtime'){throw 'runtime container is invalid'}
    $installRoot=[IO.Path]::GetFullPath((Split-Path $runtimeContainer -Parent))
    $stateRoot=[IO.Path]::GetFullPath((Join-Path $installRoot 'state'))
    [pscustomobject][ordered]@{
        InstallRoot=$installRoot;RuntimeRoot=$runtimeRoot;RuntimeId=$runtimeId;StateRoot=$stateRoot
        WorkersRoot=[IO.Path]::GetFullPath((Join-Path $stateRoot 'workers'))
        ControllerPath=[IO.Path]::GetFullPath((Join-Path $persistenceRoot 'SessionController.ps1'))
        StaticWorkerPath=[IO.Path]::GetFullPath((Join-Path $persistenceRoot 'StaticProbeWorker.ps1'))
        PowerShellPath=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
        LogDirectory=[IO.Path]::GetFullPath((Join-Path $installRoot 'logs'))
        TransitionPath=[IO.Path]::GetFullPath((Join-Path $stateRoot 'transition.json'))
    }
}

function Get-CcodSupervisorDefaultAdapters {
    Import-CcodSupervisorModules
    $defaults=@{}
    $defaults.GetIdentity={
        $windowsIdentity=$null;$process=$null
        try{
            $windowsIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess()
            [pscustomobject][ordered]@{UserSid=$windowsIdentity.User.Value;SessionId=[int]$process.SessionId;Pid=[int]$process.Id;CreationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
        }finally{if($null -ne $process){$process.Dispose()};if($null -ne $windowsIdentity){$windowsIdentity.Dispose()}}
    }
    $defaults.ResolveLayout={Resolve-CcodSupervisorLayout}
    $defaults.StartClock={[Diagnostics.Stopwatch]::StartNew()}
    $defaults.GetElapsedMilliseconds={param($Clock)[long]$Clock.ElapsedMilliseconds}
    $defaults.GetUtcNow={[DateTime]::UtcNow}
    $defaults.EnterLease={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)if($Kind -ceq 'AccountSupervisor'){Enter-CcodMutex -Kind $Kind -UserSid $UserSid -TimeoutMilliseconds $TimeoutMilliseconds}else{Enter-CcodMutex -Kind $Kind -UserSid $UserSid -SessionId $SessionId -TimeoutMilliseconds $TimeoutMilliseconds}}
    $defaults.ExitLease={param($Lease)Exit-CcodMutex -Lease $Lease}
    $defaults.OpenReadyEvent={param($UserSid,$SessionId,$Token)Open-CcodEvent -Kind Ready -UserSid $UserSid -SessionId $SessionId -ReadyToken $Token}
    $defaults.OpenShutdownEvent={param($UserSid,$SessionId)New-CcodEvent -Kind Shutdown -UserSid $UserSid -SessionId $SessionId}
    $defaults.IsEventSignaled={param($Event)[bool]$Event.Handle.WaitOne(0)}
    $defaults.SignalEvent={param($Event)[void]$Event.Handle.Set()}
    $defaults.CloseEvent={param($Event)$Event.Handle.Dispose();$Event.Disposed=$true}
    $defaults.ReadState={param($StateRoot)Read-CcodState -StateRoot $StateRoot}
    $defaults.ReadJournal={param($Path)Read-CcodTransition -Path $Path}
    $defaults.EnumerateProcessIds={@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue|ForEach-Object{try{[int]$_.Id}finally{$_.Dispose()}})}
    $defaults.GetProcessSnapshot={param($ProcessId)Get-CcodProcessSnapshot -ProcessId $ProcessId}
    $defaults.GetSupervisorDecision={param($Context)Get-CcodSupervisorDecision -Context $Context}
    $defaults.AddObservedEvent={param($Observed,$Pid,$Created)Add-CcodObservedEvent -ObservedKeys $Observed -ProcessId $Pid -CreationTimeUtc $Created}
    $defaults.CompleteControllerRun={param($Result,$TransactionId,$Action,$RuntimeId)Complete-CcodControllerRun -Result $Result -ExpectedTransactionId $TransactionId -ExpectedAction $Action -ExpectedRuntimeId $RuntimeId}
    $defaults.GetTrayPresentation={param($Arguments)Get-CcodTrayPresentation @Arguments}
    $defaults.NewQueue={param($Kind)Write-Output -NoEnumerate ([Collections.Concurrent.ConcurrentQueue[object]]::new())}
    $defaults.GetQueueCount={param($Queue)[int]$Queue.Count}
    $defaults.TryDequeue={param($Queue)$value=$null;$ok=$Queue.TryDequeue([ref]$value);[pscustomobject][ordered]@{Succeeded=[bool]$ok;Value=$value}}
    $defaults.NewTray={param($Queue,$OnTick)New-CcodTrayContext -CommandQueue $Queue -OnTick $OnTick}
    $defaults.SetTrayPresentation={param($Tray,$Presentation,$PackageText,$RuntimeText)Set-CcodTrayPresentation -Context $Tray -Presentation $Presentation -PackageText $PackageText -RuntimeText $RuntimeText}
    $defaults.StopTrayTimer={param($Tray)$Tray.Timer.Stop()}
    $defaults.RequestUiExit={param($Tray)$Tray.ApplicationContext.ExitThread()}
    $defaults.CloseTray={param($Tray)Close-CcodTrayContext -Context $Tray}
    $defaults.NewWatcher={param($Queue,$OnFull)Start-CcodProcessWatcher -Queue $Queue -OnFullReconciliationRequired $OnFull}
    $defaults.StopWatcher={param($Watcher)Stop-CcodProcessWatcher -Watcher $Watcher}
    foreach($name in @('GetWorkerLeafState','WriteWorkerRequest','StartWorker','PollWorker','ReadWorkerResult','WaitWorker','GetWorkerIdentity','TerminateWorker','DisposeWorker','DeleteWorkerFile','ClearFailedAttempt','SetAutomationEnabled','SetCandidateOptIn','OpenLogs')){
        $operation=$name;$defaults[$name]={throw "Supervisor operation is not initialized: $operation"}.GetNewClosure()
    }
    $defaults.WriteLog={param($Record)if($null -ne $script:CcodSupervisorLogPath){Write-CcodRotatingLog -Path $script:CcodSupervisorLogPath -Message ($Record|ConvertTo-Json -Depth 4 -Compress)}}
    $defaults.RunUiContext={param($Tray)Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop;[Windows.Forms.Application]::Run($Tray.ApplicationContext)}
    return $defaults
}

function Test-CcodSupervisorAdapterSet {
    param($Adapters)
    try{
        if($Adapters -isnot [hashtable] -or $Adapters.Count -ne $script:CcodSupervisorAdapterNames.Count){return $false}
        foreach($name in $script:CcodSupervisorAdapterNames){if(-not $Adapters.ContainsKey($name) -or $Adapters[$name] -isnot [scriptblock]){return $false}}
        foreach($key in $Adapters.Keys){if($key -isnot [string] -or $script:CcodSupervisorAdapterNames -cnotcontains $key){return $false}}
        return $true
    }catch{return $false}
}

function Get-CcodSupervisorAdapters {
    param($Adapters)
    if($null -eq $Adapters){return Get-CcodSupervisorDefaultAdapters}
    if(-not (Test-CcodSupervisorAdapterSet $Adapters)){return $null}
    return $Adapters
}

function Test-CcodSupervisorIdentity {
    param($Identity)
    return (Test-CcodSupervisorExactProperties $Identity @('UserSid','SessionId','Pid','CreationTimeUtc')) -and
        $Identity.UserSid -is [string] -and $Identity.UserSid -cmatch '^S-1-(?:\d+-){1,14}\d+$' -and
        $Identity.SessionId -is [int] -and $Identity.SessionId -ge 0 -and $Identity.Pid -is [int] -and $Identity.Pid -gt 0 -and
        (Test-CcodSupervisorCanonicalUtc $Identity.CreationTimeUtc)
}

function Test-CcodSupervisorLayout {
    param($Layout)
    $names=@('InstallRoot','RuntimeRoot','RuntimeId','StateRoot','WorkersRoot','ControllerPath','StaticWorkerPath','PowerShellPath','LogDirectory','TransitionPath')
    if(-not (Test-CcodSupervisorExactProperties $Layout $names) -or $Layout.RuntimeId -isnot [string] -or $Layout.RuntimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'){return $false}
    foreach($name in $names|Where-Object{$_ -ne 'RuntimeId'}){
        $value=$Layout.$name;$full=$null
        if($value -isnot [string]){return $false}
        try{$full=[IO.Path]::GetFullPath($value)}catch{return $false}
        if(-not [IO.Path]::IsPathRooted($value) -or $full -cne $value){return $false}
    }
    return $true
}

function Test-CcodSupervisorLease {
    param($Lease,[string]$Kind)
    $names=@('SchemaVersion','Name','Kind','Outcome','CreatedNew','Abandoned','Handle','OwnerManagedThreadId','Released')
    return (Test-CcodSupervisorExactProperties $Lease $names) -and $Lease.SchemaVersion -is [int] -and $Lease.SchemaVersion -eq 1 -and
        $Lease.Name -is [string] -and $Lease.Kind -is [string] -and $Lease.Kind -ceq $Kind -and $Lease.Outcome -is [string] -and
        @('Acquired','TimedOut') -ccontains $Lease.Outcome -and $Lease.CreatedNew -is [bool] -and $Lease.Abandoned -is [bool] -and
        $Lease.OwnerManagedThreadId -is [int] -and $Lease.OwnerManagedThreadId -gt 0 -and $Lease.Released -is [bool] -and
        (($Lease.Outcome -ceq 'Acquired' -and $null -ne $Lease.Handle -and -not $Lease.Released) -or ($Lease.Outcome -ceq 'TimedOut' -and $null -eq $Lease.Handle -and -not $Lease.Abandoned))
}

function Test-CcodSupervisorEvent {
    param($Event,[string]$Kind)
    return (Test-CcodSupervisorExactProperties $Event @('SchemaVersion','Name','Kind','CreatedNew','Handle','Disposed')) -and
        $Event.SchemaVersion -is [int] -and $Event.SchemaVersion -eq 1 -and $Event.Name -is [string] -and $Event.Kind -is [string] -and
        $Event.Kind -ceq $Kind -and $Event.CreatedNew -is [bool] -and $null -ne $Event.Handle -and $Event.Disposed -is [bool] -and -not $Event.Disposed
}

function New-CcodSupervisorReceipt {
    param([ValidateSet('Stopped','StartupRejected','Failed')][string]$Outcome,[int]$ExitCode,[string[]]$CleanupCodes)
    $safe=@($CleanupCodes|Where-Object{$script:CcodSupervisorCleanupAllowlist -ccontains $_}|Select-Object -Unique)
    [pscustomobject][ordered]@{SchemaVersion=1;Outcome=$Outcome;ExitCode=$ExitCode;CleanupCodes=$safe}
}

function Add-CcodSupervisorCleanupCode {
    param([Collections.Generic.List[string]]$Codes,[string]$Code)
    if($script:CcodSupervisorCleanupAllowlist -ccontains $Code -and -not $Codes.Contains($Code) -and $Codes.Count -lt 16){$Codes.Add($Code)}
}

function Invoke-CcodSupervisorCleanupStage {
    param([scriptblock]$Action,[Collections.Generic.List[string]]$Codes,[string]$Code)
    try{& $Action}catch{Add-CcodSupervisorCleanupCode $Codes $Code}
}

function Get-CcodSupervisorRemainingBudget {
    param($Clock,[hashtable]$Adapters)
    $elapsed=Invoke-CcodSupervisorAdapter $Adapters.GetElapsedMilliseconds @($Clock) 1
    if(($elapsed -isnot [int] -and $elapsed -isnot [long]) -or $elapsed -lt 0){throw 'monotonic clock is invalid'}
    if([long]$elapsed -ge 5000){return [int]0}
    return [int](5000-[long]$elapsed)
}

function Invoke-CcodSupervisorDrainQueue {
    param($Queue,[hashtable]$Adapters)
    if($null -eq $Queue){return}
    $queueArgument=[object[]]::new(1);$queueArgument[0]=$Queue
    $count=Invoke-CcodSupervisorAdapter $Adapters.GetQueueCount $queueArgument 1
    if($count -isnot [int] -or $count -lt 0){throw 'queue count is invalid'}
    $limit=[Math]::Min($count,256)
    for($index=0;$index -lt $limit;$index++){
        $receipt=Invoke-CcodSupervisorAdapter $Adapters.TryDequeue $queueArgument 1
        if(-not (Test-CcodSupervisorExactProperties $receipt @('Succeeded','Value')) -or $receipt.Succeeded -isnot [bool]){throw 'queue receipt is invalid'}
        if(-not $receipt.Succeeded){break}
    }
    $remaining=Invoke-CcodSupervisorAdapter $Adapters.GetQueueCount $queueArgument 1
    if($remaining -isnot [int] -or $remaining -ne 0){throw 'queue did not drain'}
}

function New-CcodSupervisorHostState {
    [CmdletBinding()]
    param($Identity,$Layout,$Clock,$ShutdownEvent,$CommandQueue,$EventQueue,$State,$Journal)
    if(-not (Test-CcodSupervisorIdentity $Identity) -or -not (Test-CcodSupervisorLayout $Layout) -or $null -eq $Clock -or
       -not (Test-CcodSupervisorEvent $ShutdownEvent 'Shutdown') -or $null -eq $CommandQueue -or $null -eq $EventQueue -or $null -eq $State){throw 'host state inputs are invalid'}
    [pscustomobject][ordered]@{
        SchemaVersion=1;ShutdownRequested=$false;ShutdownEvent=$ShutdownEvent;Tray=$null;State=$State;Journal=$Journal;WorkerSlot=$null
        Identity=$Identity;Layout=$Layout;CommandQueue=$CommandQueue;EventQueue=$EventQueue;Clock=$Clock
        ObservedKeys=[ordered]@{};AttemptKeys=[ordered]@{};RecoveryIgnoreKeys=[ordered]@{};SuppressionKeys=[ordered]@{}
        StaticCache=[ordered]@{};TransportRetries=[ordered]@{};TerminalRecoveries=[ordered]@{}
        Ordinary=[object[]]@();Special=[object[]]@();SpecialNeedsInspect=$false;SpecialProof=$null
        SessionState='Idle';BlockAutomaticActions=$false;Reason='Idle';ForceReconcile=$true;NextReconcileMilliseconds=[long]0;LastDecision=$null
        RuntimeCleanupCodes=[Collections.Generic.List[string]]::new()
    }
}

function Test-CcodSupervisorWorkerPaths {
    param($Paths,$WorkersRoot,[string]$Kind,[string]$RequestId)
    if(-not (Test-CcodSupervisorExactProperties $Paths @('RequestPath','ResultPath','StderrPath')) -or $RequestId -cnotmatch '^[0-9a-f]{32}$'){return $false}
    $prefix=if($Kind -ceq 'Controller'){'controller'}elseif($Kind -ceq 'StaticProbe'){'static-probe'}else{return $false}
    $expected=@(
        "$prefix-$RequestId.request.json",
        "$prefix-$RequestId.result.json",
        $(if($Kind -ceq 'Controller'){"$prefix-$RequestId.stderr.log"}else{$null})
    )
    $values=@($Paths.RequestPath,$Paths.ResultPath,$Paths.StderrPath)
    for($index=0;$index -lt $values.Count;$index++){
        if($null -eq $expected[$index]){if($null -ne $values[$index]){return $false};continue}
        $full=$null;try{$full=[IO.Path]::GetFullPath($values[$index])}catch{return $false}
        if($values[$index] -isnot [string] -or -not [IO.Path]::IsPathRooted($values[$index]) -or $full -cne $values[$index] -or
           (Split-Path $full -Parent) -cne $WorkersRoot -or (Split-Path $full -Leaf) -cne $expected[$index]){return $false}
    }
    return $true
}

function New-CcodSupervisorWorkerPaths {
    param($HostState,[ValidateSet('Controller','StaticProbe')][string]$Kind,[string]$RequestId)
    $prefix=if($Kind -ceq 'Controller'){'controller'}else{'static-probe'}
    $root=$HostState.Layout.WorkersRoot
    $paths=[pscustomobject][ordered]@{
        RequestPath=[IO.Path]::GetFullPath((Join-Path $root "$prefix-$RequestId.request.json"))
        ResultPath=[IO.Path]::GetFullPath((Join-Path $root "$prefix-$RequestId.result.json"))
        StderrPath=$(if($Kind -ceq 'Controller'){[IO.Path]::GetFullPath((Join-Path $root "$prefix-$RequestId.stderr.log"))}else{$null})
    }
    if(-not (Test-CcodSupervisorWorkerPaths $paths $root $Kind $RequestId)){throw 'worker paths are invalid'}
    return $paths
}

function New-CcodSupervisorControllerRequest {
    param($HostState,[ValidateSet('Inspect','Apply','RepairRenderer','Recover')][string]$Action,$Target)
    $transactionId=if($Action -ceq 'Recover' -and $null -ne $HostState.Journal){$HostState.Journal.transactionId}else{[guid]::NewGuid().ToString('D')}
    if($transactionId -isnot [string] -or $transactionId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'transaction identity is invalid'}
    $source=$null
    if($Action -ceq 'Apply'){
        if($null -eq $Target -or $Target.Pid -isnot [int] -or $Target.Pid -lt 1 -or -not (Test-CcodSupervisorCanonicalUtc $Target.CreationTimeUtc)){throw 'Apply target is invalid'}
        $source=[pscustomobject][ordered]@{pid=[int]$Target.Pid;creationTimeUtc=[string]$Target.CreationTimeUtc}
    }
    [pscustomobject][ordered]@{
        schemaVersion=1;action=$Action;transactionId=$transactionId;runtimeId=$HostState.Layout.RuntimeId
        supervisorIdentity=[pscustomobject][ordered]@{pid=[int]$HostState.Identity.Pid;creationTimeUtc=$HostState.Identity.CreationTimeUtc;sessionId=$HostState.Identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture)}
        source=$source;existingOnly=$true;rendererPort=$null;mainPort=$null;timeoutMilliseconds=[int]30000;restartOrdinary=$true
    }
}

function New-CcodSupervisorStaticRequest {
    param($HostState,$Target,[string]$RequestId)
    if($null -eq $Target -or $Target.Pid -isnot [int] -or $Target.Pid -lt 1 -or -not (Test-CcodSupervisorCanonicalUtc $Target.CreationTimeUtc)){throw 'static target is invalid'}
    [pscustomobject][ordered]@{
        schemaVersion=1;action='StaticProbe';requestId=$RequestId;runtimeId=$HostState.Layout.RuntimeId
        supervisorIdentity=[pscustomobject][ordered]@{pid=[int]$HostState.Identity.Pid;creationTimeUtc=$HostState.Identity.CreationTimeUtc;sessionId=$HostState.Identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture)}
        targetIdentity=[pscustomobject][ordered]@{pid=[int]$Target.Pid;creationTimeUtc=[string]$Target.CreationTimeUtc};timeoutMilliseconds=[int]30000
    }
}

function Start-CcodSupervisorWorkerSlot {
    param($HostState,[hashtable]$Adapters,[ValidateSet('Controller','StaticProbe')][string]$Kind,[string]$Action,$Target)
    if($null -ne $HostState.WorkerSlot){throw 'worker slot is occupied'}
    $requestId=[guid]::NewGuid().ToString('N')
    $paths=New-CcodSupervisorWorkerPaths $HostState $Kind $requestId
    $request=if($Kind -ceq 'StaticProbe'){New-CcodSupervisorStaticRequest $HostState $Target $requestId}else{New-CcodSupervisorControllerRequest $HostState $Action $Target}
    $ownedFiles=[Collections.Generic.List[string]]::new()
    try{
        foreach($path in @($paths.RequestPath,$paths.ResultPath,$paths.StderrPath)){
            if($null -eq $path){continue}
            $leaf=Invoke-CcodSupervisorAdapter $Adapters.GetWorkerLeafState @($path) 1
            if(-not (Test-CcodSupervisorExactProperties $leaf @('Exists','IsReparse')) -or $leaf.Exists -isnot [bool] -or $leaf.IsReparse -isnot [bool] -or $leaf.Exists -or $leaf.IsReparse){throw 'worker leaf is unsafe'}
        }
        Invoke-CcodSupervisorAdapter $Adapters.WriteWorkerRequest @($paths.RequestPath,$request) 0;$ownedFiles.Add($paths.RequestPath)
        $scriptPath=if($Kind -ceq 'StaticProbe'){$HostState.Layout.StaticWorkerPath}else{$HostState.Layout.ControllerPath}
        $started=Invoke-CcodSupervisorAdapter $Adapters.StartWorker @($Kind,$scriptPath,$paths.RequestPath,$paths.ResultPath,$paths.StderrPath,$request,$HostState.Layout.PowerShellPath) 1
        if(-not (Test-CcodSupervisorExactProperties $started @('ProcessId','CreationTimeUtc','Handle')) -or $started.ProcessId -isnot [int] -or $started.ProcessId -lt 1 -or
           -not (Test-CcodSupervisorCanonicalUtc $started.CreationTimeUtc) -or $null -eq $started.Handle){throw 'worker start receipt is invalid'}
        $HostState.WorkerSlot=[pscustomobject][ordered]@{
            Kind=$Kind;Action=$request.action;RequestId=$requestId;RuntimeId=$HostState.Layout.RuntimeId;Request=$request
            RequestPath=$paths.RequestPath;ResultPath=$paths.ResultPath;StderrPath=$paths.StderrPath
            ProcessId=[int]$started.ProcessId;CreationTimeUtc=$started.CreationTimeUtc;Handle=$started.Handle
        }
        return $HostState.WorkerSlot
    }catch{
        foreach($path in @($ownedFiles)){try{Invoke-CcodSupervisorAdapter $Adapters.DeleteWorkerFile @($path) 0}catch{}}
        throw
    }
}

function Clear-CcodSupervisorWorkerSlot {
    param($HostState,[hashtable]$Adapters)
    $slot=$HostState.WorkerSlot
    if($null -eq $slot){return}
    try{Invoke-CcodSupervisorAdapter $Adapters.DisposeWorker @($slot) 0}catch{Add-CcodSupervisorCleanupCode $HostState.RuntimeCleanupCodes 'CCOD_SUPERVISOR_WORKER_DISPOSE_FAILED'}
    foreach($path in @($slot.RequestPath,$slot.ResultPath,$slot.StderrPath)){
        if($null -eq $path){continue}
        try{Invoke-CcodSupervisorAdapter $Adapters.DeleteWorkerFile @($path) 0}catch{Add-CcodSupervisorCleanupCode $HostState.RuntimeCleanupCodes 'CCOD_SUPERVISOR_WORKER_FILE_DELETE_FAILED'}
    }
    $HostState.WorkerSlot=$null
}

function Invoke-CcodSupervisorPollSlot {
    param($HostState,[hashtable]$Adapters)
    $slot=$HostState.WorkerSlot
    $poll=Invoke-CcodSupervisorAdapter $Adapters.PollWorker @($slot) 1
    $fields=@('Completed','ExitCode','StdoutText','StdoutByteCount','StdoutOverflow','StderrByteCount','StderrOverflow')
    if(-not (Test-CcodSupervisorExactProperties $poll $fields) -or $poll.Completed -isnot [bool] -or $poll.StdoutText -isnot [string] -or
       $poll.StdoutByteCount -isnot [int] -or $poll.StdoutByteCount -lt 0 -or $poll.StdoutOverflow -isnot [bool] -or
       $poll.StderrByteCount -isnot [int] -or $poll.StderrByteCount -lt 0 -or $poll.StderrOverflow -isnot [bool]){Clear-CcodSupervisorWorkerSlot $HostState $Adapters;return}
    if(-not $poll.Completed){return}
    try{
        if($poll.ExitCode -isnot [int] -or $poll.StdoutByteCount -gt 1048576 -or $poll.StderrByteCount -gt 65536 -or $poll.StdoutOverflow -or $poll.StderrOverflow){throw 'worker framing failed'}
        if(-not [string]::IsNullOrEmpty($poll.StdoutText)){
            $result=Invoke-CcodSupervisorNullableAdapter $Adapters.ReadWorkerResult @($slot.ResultPath)
            if($null -eq $result){throw 'worker result is missing'}
            $fromStdout=$poll.StdoutText|ConvertFrom-Json -ErrorAction Stop
            if(($fromStdout|ConvertTo-Json -Depth 20 -Compress) -cne ($result|ConvertTo-Json -Depth 20 -Compress)){throw 'worker frames differ'}
            if($slot.Kind -ceq 'Controller'){
                $reduced=Invoke-CcodSupervisorAdapter $Adapters.CompleteControllerRun @($result,$slot.Request.transactionId,$slot.Action,$slot.RuntimeId) 1
                if($null -ne $reduced){$HostState.SessionState=[string]$reduced.SessionState;$HostState.BlockAutomaticActions=[bool]$reduced.BlockAutomaticActions;$HostState.Reason=[string]$reduced.Reason}
            }
        }
    }catch{$HostState.SessionState='Error';$HostState.BlockAutomaticActions=$true;$HostState.Reason='WorkerFramingFailed'}
    finally{Clear-CcodSupervisorWorkerSlot $HostState $Adapters}
}

function Invoke-CcodSupervisorCommand {
    param($HostState,[hashtable]$Adapters,$Command)
    if(-not (Test-CcodSupervisorExactProperties $Command @('Kind','Value','EnqueuedAtUtc')) -or $Command.Kind -isnot [string] -or
       @('ApplyNow','ManualRetry','SetAutomationEnabled','SetCandidateCompatibleOptIn','OpenLogs','Uninstall') -cnotcontains $Command.Kind -or
       -not (Test-CcodSupervisorCanonicalUtc $Command.EnqueuedAtUtc)){return}
    switch($Command.Kind){
        'ApplyNow' {$HostState.ForceReconcile=$true}
        'SetAutomationEnabled' {if($Command.Value -is [bool]){Invoke-CcodSupervisorAdapter $Adapters.SetAutomationEnabled @($HostState.Layout.StateRoot,[bool]$Command.Value) 0;$HostState.ForceReconcile=$true}}
        'SetCandidateCompatibleOptIn' {if($Command.Value -is [bool]){Invoke-CcodSupervisorAdapter $Adapters.SetCandidateOptIn @($HostState.Layout.StateRoot,[bool]$Command.Value) 0;$HostState.ForceReconcile=$true}}
        'OpenLogs' {Invoke-CcodSupervisorAdapter $Adapters.OpenLogs @($HostState.Layout.LogDirectory) 0}
        'ManualRetry' {$HostState.ForceReconcile=$true}
        'Uninstall' {return}
    }
}

function New-CcodSupervisorEngineContext {
    param($HostState)
    $state=$HostState.State
    $settings=if($null -ne $state.PSObject.Properties['Settings']){$state.Settings}else{$null}
    $candidate=$false;if($null -ne $settings -and $null -ne $settings.PSObject.Properties['candidateCompatibleOptIn'] -and $settings.candidateCompatibleOptIn -is [bool]){$candidate=$settings.candidateCompatibleOptIn}
    $verified=if($null -ne $state.PSObject.Properties['VerifiedPackages']){$state.VerifiedPackages}else{$null}
    $damaged=$null -eq $verified
    if($null -ne $state.PSObject.Properties['Damage'] -and $null -ne $state.Damage){$damaged=$damaged -or @($state.Damage.PSObject.Properties).Count -gt 0}
    [pscustomobject][ordered]@{
        AutomationEnabled=[bool]$state.AutomationEnabled;CandidateCompatibleOptIn=[bool]$candidate
        AutomaticCandidateTrialsAllowed=$(if($null -ne $state.PSObject.Properties['AutomaticCandidateTrialsAllowed']){[bool]$state.AutomaticCandidateTrialsAllowed}else{$false})
        StateDamageBlocksActions=[bool]$damaged;ControllerRunning=[bool]($null -ne $HostState.WorkerSlot);ActiveTransaction=$HostState.Journal
        CurrentUserSid=$HostState.Identity.UserSid;CurrentSessionId=[int]$HostState.Identity.SessionId;RuntimeId=$HostState.Layout.RuntimeId
        PackageFullName=$null;AppAsarSha256=$null;Classification=$null;VerifiedPackages=$verified
        Ordinary=[object[]]@($HostState.Ordinary);Special=[object[]]@($HostState.Special)
        AttemptKeys=$HostState.AttemptKeys;RecoveryIgnoreKeys=$HostState.RecoveryIgnoreKeys;SuppressionKeys=$HostState.SuppressionKeys
    }
}

function Invoke-CcodSupervisorRefreshObservations {
    param($HostState,[hashtable]$Adapters)
    $ids=Invoke-CcodSupervisorAdapter $Adapters.EnumerateProcessIds @() 1
    if($ids -isnot [array]){throw 'process enumeration is invalid'}
    $ordinary=[Collections.Generic.List[object]]::new();$special=[Collections.Generic.List[object]]::new()
    foreach($pidValue in @($ids|Select-Object -First 256)){
        if($pidValue -isnot [int] -or $pidValue -lt 1){continue}
        $snapshot=Invoke-CcodSupervisorNullableAdapter $Adapters.GetProcessSnapshot @([int]$pidValue)
        if($null -eq $snapshot){continue}
        if($snapshot.UserSid -cne $HostState.Identity.UserSid -or $snapshot.SessionId -ne $HostState.Identity.SessionId -or -not $snapshot.IsTopLevel){continue}
        if($snapshot.Mode -ceq 'Ordinary'){$ordinary.Add($snapshot)}
        elseif($snapshot.Mode -ceq 'Special'){$special.Add([pscustomobject][ordered]@{Snapshot=$snapshot;IdentityValid=$true;ProbeValid=$false})}
    }
    $HostState.Ordinary=[object[]]@($ordinary);$HostState.Special=[object[]]@($special)
    $HostState.SpecialNeedsInspect=$special.Count -gt 0 -and $null -eq $HostState.SpecialProof
}

function Invoke-CcodSupervisorTick {
    param($HostState,[hashtable]$Adapters)
    if($null -eq $HostState -or $HostState.ShutdownRequested){return}
    $signaled=Invoke-CcodSupervisorAdapter $Adapters.IsEventSignaled @($HostState.ShutdownEvent) 1
    if($signaled -isnot [bool]){throw 'shutdown state is invalid'}
    if($signaled){
        $HostState.ShutdownRequested=$true
        Invoke-CcodSupervisorAdapter $Adapters.RequestUiExit @($HostState.Tray) 0
        return
    }
    if($null -ne $HostState.WorkerSlot){Invoke-CcodSupervisorPollSlot $HostState $Adapters;return}
    $HostState.State=Invoke-CcodSupervisorAdapter $Adapters.ReadState @($HostState.Layout.StateRoot) 1
    if($null -eq $HostState.State){throw 'state read is invalid'}
    $HostState.Journal=Invoke-CcodSupervisorNullableAdapter $Adapters.ReadJournal @($HostState.Layout.TransitionPath)
    if($null -ne $HostState.Journal){Start-CcodSupervisorWorkerSlot $HostState $Adapters 'Controller' 'Recover' $null|Out-Null;return}
    if($HostState.SpecialNeedsInspect){Start-CcodSupervisorWorkerSlot $HostState $Adapters 'Controller' 'Inspect' $null|Out-Null;return}
    $queueArgument=[object[]]::new(1);$queueArgument[0]=$HostState.CommandQueue
    $dequeued=Invoke-CcodSupervisorAdapter $Adapters.TryDequeue $queueArgument 1
    if(-not (Test-CcodSupervisorExactProperties $dequeued @('Succeeded','Value')) -or $dequeued.Succeeded -isnot [bool]){throw 'command queue receipt is invalid'}
    if($dequeued.Succeeded){Invoke-CcodSupervisorCommand $HostState $Adapters $dequeued.Value;return}
    $elapsed=Invoke-CcodSupervisorAdapter $Adapters.GetElapsedMilliseconds @($HostState.Clock) 1
    if(($elapsed -isnot [int] -and $elapsed -isnot [long]) -or $elapsed -lt 0){throw 'reconciliation clock is invalid'}
    if($HostState.ForceReconcile -or [long]$elapsed -ge $HostState.NextReconcileMilliseconds){
        Invoke-CcodSupervisorRefreshObservations $HostState $Adapters
        $deadline=[long]$HostState.NextReconcileMilliseconds
        if($deadline -le 0){$deadline=3000}
        while($deadline -le [long]$elapsed){$deadline+=3000}
        $HostState.NextReconcileMilliseconds=$deadline;$HostState.ForceReconcile=$false
    }
    $context=New-CcodSupervisorEngineContext $HostState
    $decision=Invoke-CcodSupervisorAdapter $Adapters.GetSupervisorDecision @($context) 1
    if(-not (Test-CcodSupervisorExactProperties $decision @('Action','Reason','Target','AttemptKey','SuppressionKey','EffectiveClassification','RequiresController'))){throw 'supervisor decision is invalid'}
    $HostState.LastDecision=$decision;$HostState.Reason=[string]$decision.Reason
    switch($decision.Action){
        'RepairRenderer' {Start-CcodSupervisorWorkerSlot $HostState $Adapters 'Controller' 'RepairRenderer' $decision.Target|Out-Null;return}
        'InspectOrdinary' {Start-CcodSupervisorWorkerSlot $HostState $Adapters 'StaticProbe' 'StaticProbe' $decision.Target|Out-Null;return}
        'ApplyOrdinary' {Start-CcodSupervisorWorkerSlot $HostState $Adapters 'Controller' 'Apply' $decision.Target|Out-Null;return}
    }
}

function Invoke-CcodSupervisorHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ReadyToken,[hashtable]$Adapters)
    if($ReadyToken -cnotmatch '^[0-9a-f]{64}$'){return New-CcodSupervisorReceipt 'StartupRejected' 2 @()}
    $adapter=Get-CcodSupervisorAdapters $Adapters
    if($null -eq $adapter){return New-CcodSupervisorReceipt 'StartupRejected' 2 @()}
    $codes=[Collections.Generic.List[string]]::new();$outcome='Failed';$exitCode=1
    $accountLease=$null;$localLease=$null;$accountOwned=$false;$localOwned=$false
    $readyEvent=$null;$shutdownEvent=$null;$commandQueue=$null;$eventQueue=$null;$tray=$null;$watcher=$null;$hostState=$null
    try{
        do{
            $identity=Invoke-CcodSupervisorAdapter $adapter.GetIdentity @() 1
            if(-not (Test-CcodSupervisorIdentity $identity)){throw 'identity contract is invalid'}
            $layout=Invoke-CcodSupervisorAdapter $adapter.ResolveLayout @() 1
            if(-not (Test-CcodSupervisorLayout $layout)){throw 'layout contract is invalid'}
            $script:CcodSupervisorLogPath=[IO.Path]::GetFullPath((Join-Path $layout.LogDirectory 'supervisor.log'))
            $clock=Invoke-CcodSupervisorAdapter $adapter.StartClock @() 1
            if($null -eq $clock){throw 'clock contract is invalid'}
            $remaining=Get-CcodSupervisorRemainingBudget $clock $adapter
            $accountLease=Invoke-CcodSupervisorAdapter $adapter.EnterLease @('AccountSupervisor',$identity.UserSid,$null,[int]$remaining) 1
            if(-not (Test-CcodSupervisorLease $accountLease 'AccountSupervisor')){throw 'account lease contract is invalid'}
            if($accountLease.Outcome -ceq 'TimedOut'){$outcome='StartupRejected';$exitCode=2;break}
            $accountOwned=$true
            $remaining=Get-CcodSupervisorRemainingBudget $clock $adapter
            $localLease=Invoke-CcodSupervisorAdapter $adapter.EnterLease @('Supervisor',$identity.UserSid,[int]$identity.SessionId,[int]$remaining) 1
            if(-not (Test-CcodSupervisorLease $localLease 'Supervisor')){throw 'local lease contract is invalid'}
            if($localLease.Outcome -ceq 'TimedOut'){$outcome='StartupRejected';$exitCode=2;break}
            $localOwned=$true
            if($accountLease.Abandoned -or $localLease.Abandoned){
                $record=[pscustomobject][ordered]@{schemaVersion=1;timestampUtc=(Invoke-CcodSupervisorAdapter $adapter.GetUtcNow @() 1).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);component='Supervisor';stage='LeaseAcquire';code='CCOD_SUPERVISOR_LEASE_ABANDONED';outcome='Warning'}
                try{Invoke-CcodSupervisorAdapter $adapter.WriteLog @($record) 0}catch{Add-CcodSupervisorCleanupCode $codes 'CCOD_SUPERVISOR_LOG_FAILED'}
            }
            $readyEvent=Invoke-CcodSupervisorAdapter $adapter.OpenReadyEvent @($identity.UserSid,[int]$identity.SessionId,$ReadyToken) 1
            if(-not (Test-CcodSupervisorEvent $readyEvent 'Ready')){throw 'Ready event contract is invalid'}
            $shutdownEvent=Invoke-CcodSupervisorAdapter $adapter.OpenShutdownEvent @($identity.UserSid,[int]$identity.SessionId) 1
            if(-not (Test-CcodSupervisorEvent $shutdownEvent 'Shutdown')){throw 'Shutdown event contract is invalid'}
            $shutdown=Invoke-CcodSupervisorAdapter $adapter.IsEventSignaled @($shutdownEvent) 1
            if($shutdown -isnot [bool]){throw 'Shutdown state is invalid'}
            if($shutdown){$outcome='StartupRejected';$exitCode=2;break}
            $state=Invoke-CcodSupervisorAdapter $adapter.ReadState @($layout.StateRoot) 1
            if($null -eq $state){throw 'state contract is invalid'}
            $journal=Invoke-CcodSupervisorAdapter $adapter.ReadJournal @($layout.TransitionPath) 1
            $commandQueue=Invoke-CcodSupervisorAdapter $adapter.NewQueue @('Command') 1
            $eventQueue=Invoke-CcodSupervisorAdapter $adapter.NewQueue @('Event') 1
            if($null -eq $commandQueue -or $null -eq $eventQueue){throw 'queue contract is invalid'}
            $hostState=New-CcodSupervisorHostState -Identity $identity -Layout $layout -Clock $clock -ShutdownEvent $shutdownEvent -CommandQueue $commandQueue -EventQueue $eventQueue -State $state -Journal $journal
            $hostStateRef=$hostState;$adapterRef=$adapter
            $onTick={Invoke-CcodSupervisorTick $hostStateRef $adapterRef}.GetNewClosure()
            $trayArguments=[object[]]::new(2);$trayArguments[0]=$commandQueue;$trayArguments[1]=$onTick
            $tray=Invoke-CcodSupervisorAdapter $adapter.NewTray $trayArguments 1
            if($null -eq $tray){throw 'tray contract is invalid'}
            $hostState.Tray=$tray
            $onFull={}.GetNewClosure()
            $watcherArguments=[object[]]::new(2);$watcherArguments[0]=$eventQueue;$watcherArguments[1]=$onFull
            $watcher=Invoke-CcodSupervisorAdapter $adapter.NewWatcher $watcherArguments 1
            if($null -eq $watcher){throw 'watcher contract is invalid'}
            $shutdown=Invoke-CcodSupervisorAdapter $adapter.IsEventSignaled @($shutdownEvent) 1
            if($shutdown -isnot [bool]){throw 'Shutdown state is invalid'}
            if($shutdown){$outcome='StartupRejected';$exitCode=2;break}
            Invoke-CcodSupervisorAdapter $adapter.SignalEvent @($readyEvent) 0
            Invoke-CcodSupervisorAdapter $adapter.RunUiContext @($tray) 0
            $outcome='Stopped';$exitCode=0
        }while($false)
    }catch{$outcome='Failed';$exitCode=1}
    finally{
        if($null -ne $hostState){$hostState.ShutdownRequested=$true}
        if($null -ne $tray){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.StopTrayTimer @($tray) 0} $codes 'CCOD_SUPERVISOR_TIMER_STOP_FAILED'}
        if($null -ne $watcher){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.StopWatcher @($watcher) 1|Out-Null} $codes 'CCOD_SUPERVISOR_WATCHER_STOP_FAILED'}
        if($null -ne $eventQueue){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorDrainQueue $eventQueue $adapter} $codes 'CCOD_SUPERVISOR_QUEUE_DRAIN_FAILED'}
        if($null -ne $commandQueue){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorDrainQueue $commandQueue $adapter} $codes 'CCOD_SUPERVISOR_QUEUE_DRAIN_FAILED'}
        if($null -ne $tray){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.CloseTray @($tray) 1|Out-Null} $codes 'CCOD_SUPERVISOR_TRAY_CLOSE_FAILED'}
        if($null -ne $readyEvent){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.CloseEvent @($readyEvent) 0} $codes 'CCOD_SUPERVISOR_READY_CLOSE_FAILED'}
        if($null -ne $shutdownEvent){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.CloseEvent @($shutdownEvent) 0} $codes 'CCOD_SUPERVISOR_SHUTDOWN_CLOSE_FAILED'}
        if($localOwned){Invoke-CcodSupervisorCleanupStage {$released=Invoke-CcodSupervisorAdapter $adapter.ExitLease @($localLease) 1;if($released -isnot [bool] -or -not $released){throw 'local lease release failed'}} $codes 'CCOD_SUPERVISOR_LOCAL_RELEASE_FAILED'}
        if($accountOwned){Invoke-CcodSupervisorCleanupStage {$released=Invoke-CcodSupervisorAdapter $adapter.ExitLease @($accountLease) 1;if($released -isnot [bool] -or -not $released){throw 'account lease release failed'}} $codes 'CCOD_SUPERVISOR_ACCOUNT_RELEASE_FAILED'}
        $script:CcodSupervisorLogPath=$null
    }
    return New-CcodSupervisorReceipt $outcome $exitCode @($codes)
}

if($MyInvocation.InvocationName -ne '.'){
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $ReadyToken
    [Console]::Out.WriteLine(($receipt|ConvertTo-Json -Depth 6 -Compress))
    exit $receipt.ExitCode
}
