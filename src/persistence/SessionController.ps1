[CmdletBinding(DefaultParameterSetName='Manual')]
param(
    [Parameter(ParameterSetName='Supervisor')]
    [string]$RequestPath,
    [Parameter(ParameterSetName='Supervisor')]
    [string]$ResultPath,
    [Parameter(ParameterSetName='Manual')]
    [ValidateSet('Inspect','Apply','RepairRenderer','Recover')]
    [string]$Action,
    [Parameter(ParameterSetName='Manual')]
    [bool]$ExistingOnly=$true,
    [Parameter(ParameterSetName='Manual')]
    [Nullable[int]]$RendererPort=$null,
    [Parameter(ParameterSetName='Manual')]
    [Nullable[int]]$MainPort=$null,
    [Parameter(ParameterSetName='Manual')]
    [ValidateRange(500,120000)][int]$TimeoutMilliseconds=30000,
    [Parameter(ParameterSetName='Manual')]
    [bool]$RestartOrdinary=$true
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$VerbosePreference='SilentlyContinue'
$InformationPreference='SilentlyContinue'

$controllerModuleRoot=Join-Path $PSScriptRoot 'modules'
$script:CcodControllerScriptPath=[IO.Path]::GetFullPath($PSCommandPath)
Import-Module (Join-Path $controllerModuleRoot 'SessionEngine.psm1') -Force
Import-Module (Join-Path $controllerModuleRoot 'RuntimeManifest.psm1') -Force
Import-Module (Join-Path $controllerModuleRoot 'TransitionJournal.psm1') -Force
Import-Module (Join-Path $controllerModuleRoot 'KernelObjects.psm1') -Force
Import-Module (Join-Path $controllerModuleRoot 'PersistenceIO.psm1') -Force -Global

function Test-CcodControllerCanonicalGuid([object]$Value){
    if($Value -isnot [string]){return $false}
    $parsed=[guid]::Empty
    return [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function New-CcodControllerErrorResult {
    param($Request,[string]$Code,[string]$Stage,[string]$Message)
    $action=$null;$transactionId=$null
    if($null -ne $Request -and $null -ne $Request.PSObject.Properties['action'] -and $Request.action -is [string] -and @('Inspect','Apply','RepairRenderer','Recover') -ccontains $Request.action){$action=$Request.action}
    if($null -ne $Request -and $null -ne $Request.PSObject.Properties['transactionId'] -and (Test-CcodControllerCanonicalGuid $Request.transactionId)){$transactionId=$Request.transactionId}
    [pscustomobject][ordered]@{schemaVersion=1;action=$action;ok=$false;outcome='Error';safeState='Error';stage=$Stage;transactionId=$transactionId;package=$null;source=$null;special=$null;probes=$null;recovery=$null;error=[pscustomobject][ordered]@{code=$Code;stage=$Stage;message='The session controller failed safely. See the session log for details.'};logFile=$null}
}

function Write-CcodControllerDiagnostic {
    param($Result,$Request,$Paths,[hashtable]$Adapter)
    if($null -eq $Result -or $null -eq $Paths -or $null -eq $Adapter -or $null -eq $Adapter.WriteLog){return $false}
    try{
        $now=& $Adapter.UtcNow;if($now -isnot [DateTime]){return $false}
        $record=[pscustomobject][ordered]@{
            schemaVersion=1
            timestampUtc=$now.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            action=$Result.action
            transactionId=$Result.transactionId
            stage=$Result.stage
            code=$Result.error.code
        }
        & $Adapter.WriteLog $Paths.SessionLogPath ($record|ConvertTo-Json -Depth 4 -Compress)|Out-Null
        $Result.logFile=$Paths.SessionLogPath
        return $true
    }catch{return $false}
}

function Write-CcodControllerAbandonedWarning {
    param($Request,$Paths,[hashtable]$Adapter)
    if($null -eq $Request -or $null -eq $Paths -or $null -eq $Adapter -or $null -eq $Adapter.WriteLog){return $false}
    try{
        $now=& $Adapter.UtcNow;if($now -isnot [DateTime]){return $false}
        $record=[pscustomobject][ordered]@{
            schemaVersion=1
            timestampUtc=$now.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            action=$Request.action
            transactionId=$Request.transactionId
            stage='LeaseAcquire'
            code='CCOD_TRANSITION_ABANDONED'
        }
        & $Adapter.WriteLog $Paths.SessionLogPath ($record|ConvertTo-Json -Depth 4 -Compress)|Out-Null;return $true
    }catch{return $false}
}

function Assert-CcodControllerEngineResult {
    param($Result,$Request)
    $expected=@('schemaVersion','action','ok','outcome','safeState','stage','transactionId','package','source','special','probes','recovery','error','logFile')
    if($null -eq $Result -or $Result -isnot [pscustomobject] -or @($Result.PSObject.Properties).Count -ne $expected.Count){throw 'engine result is not the exact 14-field object'}
    foreach($name in $expected){if($null -eq $Result.PSObject.Properties[$name]){throw 'engine result is not the exact 14-field object'}}
    if($Result.schemaVersion -ne 1 -or $Result.action -cne $Request.action -or $Result.transactionId -cne $Request.transactionId -or $Result.ok -isnot [bool] -or $Result.outcome -isnot [string]){throw 'engine result correlation or scalar fields are invalid'}
}

function Get-CcodControllerAdapters($Adapters){
    $defaults=@{
        GetIdentity={
            $identity=$null;$process=$null
            try{
                $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess()
                [pscustomobject][ordered]@{UserSid=$identity.User.Value;SessionId=[int]$process.SessionId}
            }finally{if($null -ne $process){$process.Dispose()};if($null -ne $identity){$identity.Dispose()}}
        }
        StartStopwatch={ [Diagnostics.Stopwatch]::StartNew() }
        GetElapsedMilliseconds={param($Clock)[long]$Clock.ElapsedMilliseconds}
        EnterMutex={
            param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)
            if($Kind -ceq 'AccountTransition'){Enter-CcodMutex -Kind $Kind -UserSid $UserSid -TimeoutMilliseconds $TimeoutMilliseconds}
            else{Enter-CcodMutex -Kind $Kind -UserSid $UserSid -SessionId $SessionId -TimeoutMilliseconds $TimeoutMilliseconds}
        }
        ExitMutex={param($Lease)Exit-CcodMutex -Lease $Lease}
        ReadJournal={param($Path)Read-CcodTransition -Path $Path}
        UtcNow={ [DateTime]::UtcNow }
        EngineInvoker={param($Action,$Request,$Paths)switch($Action){'Inspect'{Invoke-CcodInspectSession -Request $Request -Paths $Paths}'Apply'{Invoke-CcodApplySession -Request $Request -Paths $Paths}'RepairRenderer'{Invoke-CcodRepairRenderer -Request $Request -Paths $Paths}'Recover'{Invoke-CcodRecoverSession -Request $Request -Paths $Paths}default{throw 'unsupported controller action'}}}
        WriteResult={param($Path,$Value)Write-CcodAtomicJson -Path $Path -Value $Value}
        WriteStdout={param($Line)[Console]::Out.WriteLine($Line)}
        WriteStderr={param($Line)[Console]::Error.WriteLine($Line)}
        WriteLog={param($Path,$Message)Write-CcodRotatingLog -Path $Path -Message $Message}
    }
    if($null -ne $Adapters){foreach($key in $Adapters.Keys){$defaults[$key]=$Adapters[$key]}}
    return $defaults
}

function Test-CcodControllerCanonicalSid([object]$Value){
    if($Value -isnot [string]){return $false}
    try{$sid=[Security.Principal.SecurityIdentifier]::new($Value)}catch{return $false}
    return $sid.Value -ceq $Value
}

function Test-CcodControllerLeaseInput {
    param($Request,$Identity)
    if($null -eq $Request -or ($Request -isnot [pscustomobject] -and $Request -isnot [Collections.IDictionary]) -or
        $null -eq $Request.PSObject.Properties['action'] -or $Request.action -isnot [string] -or @('Inspect','Apply','RepairRenderer','Recover') -cnotcontains $Request.action -or
        $null -eq $Request.PSObject.Properties['transactionId'] -or -not (Test-CcodControllerCanonicalGuid $Request.transactionId) -or
        $null -eq $Request.PSObject.Properties['timeoutMilliseconds'] -or $Request.timeoutMilliseconds -isnot [int] -or $Request.timeoutMilliseconds -lt 500 -or $Request.timeoutMilliseconds -gt 120000 -or
        $null -eq $Request.PSObject.Properties['supervisorIdentity'] -or $null -eq $Request.supervisorIdentity -or
        $null -eq $Request.supervisorIdentity.PSObject.Properties['sessionId'] -or $Request.supervisorIdentity.sessionId -isnot [string] -or
        $null -eq $Identity -or ($Identity -isnot [pscustomobject] -and $Identity -isnot [Collections.IDictionary]) -or
        $null -eq $Identity.PSObject.Properties['UserSid'] -or -not (Test-CcodControllerCanonicalSid $Identity.UserSid) -or
        $null -eq $Identity.PSObject.Properties['SessionId'] -or $Identity.SessionId -isnot [int] -or $Identity.SessionId -lt 0){return $false}
    $canonicalSession=$Identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture)
    return $Request.supervisorIdentity.sessionId -ceq $canonicalSession
}

function Get-CcodControllerRemainingBudget {
    param([int]$Total,$Clock,[hashtable]$Adapter)
    $elapsed=& $Adapter.GetElapsedMilliseconds $Clock
    if(($elapsed -isnot [int] -and $elapsed -isnot [long]) -or $elapsed -lt 0){throw 'invalid monotonic clock'}
    if($elapsed -ge $Total){return [int]0}
    return [int]($Total-[long]$elapsed)
}

function Throw-CcodControllerLeaseInvalid {
    $exception=[InvalidOperationException]::new('The kernel lease contract is invalid.')
    throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_KERNEL_LEASE_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$null)
}

function Assert-CcodControllerLeaseResult {
    param($Lease,[string]$Kind,$Identity)
    $expected=@('SchemaVersion','Name','Kind','Outcome','CreatedNew','Abandoned','Handle','OwnerManagedThreadId','Released')
    if($null -eq $Lease -or $Lease -isnot [pscustomobject]){Throw-CcodControllerLeaseInvalid}
    $actual=@($Lease.PSObject.Properties.Name)
    if($actual.Count -ne $expected.Count){Throw-CcodControllerLeaseInvalid}
    for($index=0;$index -lt $expected.Count;$index++){
        if($actual[$index] -cne $expected[$index] -or $Lease.PSObject.Properties[$expected[$index]].MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty){Throw-CcodControllerLeaseInvalid}
    }
    if($Lease.SchemaVersion -isnot [int] -or $Lease.SchemaVersion -ne 1 -or
        $Lease.Name -isnot [string] -or $Lease.Kind -isnot [string] -or $Lease.Kind -cne $Kind -or
        $Lease.Outcome -isnot [string] -or @('Acquired','TimedOut') -cnotcontains $Lease.Outcome -or
        $Lease.CreatedNew -isnot [bool] -or $Lease.Abandoned -isnot [bool] -or $Lease.Released -isnot [bool]){Throw-CcodControllerLeaseInvalid}
    try{
        $expectedName=if($Kind -ceq 'AccountTransition'){
            Get-CcodKernelObjectName -Kind $Kind -UserSid $Identity.UserSid
        }else{
            Get-CcodKernelObjectName -Kind $Kind -UserSid $Identity.UserSid -SessionId $Identity.SessionId
        }
    }catch{Throw-CcodControllerLeaseInvalid}
    if($Lease.Name -cne $expectedName){Throw-CcodControllerLeaseInvalid}
    if($Lease.Outcome -ceq 'TimedOut'){
        if($Lease.Abandoned -or $null -ne $Lease.Handle -or $null -ne $Lease.OwnerManagedThreadId -or -not $Lease.Released){Throw-CcodControllerLeaseInvalid}
        return
    }
    if($Lease.Handle -isnot [Threading.Mutex] -or $Lease.OwnerManagedThreadId -isnot [int] -or
        $Lease.OwnerManagedThreadId -le 0 -or $Lease.OwnerManagedThreadId -ne [Threading.Thread]::CurrentThread.ManagedThreadId -or $Lease.Released){Throw-CcodControllerLeaseInvalid}
    try{
        $safeHandle=$Lease.Handle.SafeWaitHandle
        if($null -eq $safeHandle -or $safeHandle.IsClosed -or $safeHandle.IsInvalid){Throw-CcodControllerLeaseInvalid}
    }catch{Throw-CcodControllerLeaseInvalid}
}

function Get-CcodControllerStableLeaseCode {
    param($Failure)
    if($null -ne $Failure -and $Failure.FullyQualifiedErrorId -is [string]){
        $id=($Failure.FullyQualifiedErrorId -split ',')[0]
        if(@('CCOD_KERNEL_INPUT_INVALID','CCOD_KERNEL_ACL_MISMATCH','CCOD_KERNEL_OBJECT_TYPE_MISMATCH','CCOD_KERNEL_ACCESS_DENIED','CCOD_KERNEL_OPEN_FAILED','CCOD_KERNEL_LEASE_INVALID','CCOD_KERNEL_RELEASE_FAILED') -ccontains $id){return $id}
    }
    return 'CCOD_KERNEL_OPEN_FAILED'
}

function Invoke-CcodSessionController {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,[Parameter(Mandatory)][string]$ResultPath,[hashtable]$Adapters)
    $adapter=Get-CcodControllerAdapters $Adapters;$result=$null;$diagnosticWritten=$false;$accountLease=$null;$sessionLease=$null;$accountLeaseAcquired=$false;$sessionLeaseAcquired=$false;$releaseFailed=$false
    try{
        try{$identity=& $adapter.GetIdentity}catch{$identity=$null}
        if(-not (Test-CcodControllerLeaseInput $Request $identity)){
            $result=New-CcodControllerErrorResult $Request 'CCOD_REQUEST_INVALID' 'InputValidation' 'The request does not match this controller session.'
        }else{
            $total=[Math]::Min([int]$Request.timeoutMilliseconds,5000)
            try{
                $clock=& $adapter.StartStopwatch
                $remaining=Get-CcodControllerRemainingBudget $total $clock $adapter
                $accountLease=& $adapter.EnterMutex 'AccountTransition' $identity.UserSid $null $remaining
                Assert-CcodControllerLeaseResult $accountLease 'AccountTransition' $identity
                if($accountLease.Outcome -ceq 'TimedOut'){$result=New-CcodControllerErrorResult $Request 'CCOD_TRANSITION_BUSY' 'LeaseAcquire' 'The transition lease is busy.'}
                else{
                    $accountLeaseAcquired=$true
                    $remaining=Get-CcodControllerRemainingBudget $total $clock $adapter
                    $sessionLease=& $adapter.EnterMutex 'Transition' $identity.UserSid $identity.SessionId $remaining
                    Assert-CcodControllerLeaseResult $sessionLease 'Transition' $identity
                    if($sessionLease.Outcome -ceq 'TimedOut'){$result=New-CcodControllerErrorResult $Request 'CCOD_TRANSITION_BUSY' 'LeaseAcquire' 'The transition lease is busy.'}
                    else{
                        $sessionLeaseAcquired=$true
                        if($accountLease.Abandoned -or $sessionLease.Abandoned){[void](Write-CcodControllerAbandonedWarning $Request $Paths $adapter)}
                        try{$active=& $adapter.ReadJournal $Paths.TransitionPath}catch{
                            $code=if($_.FullyQualifiedErrorId -like 'CCOD_TRANSITION_*'){($_.FullyQualifiedErrorId -split ',')[0]}else{'CCOD_TRANSITION_INVALID'}
                            $result=New-CcodControllerErrorResult $Request $code 'JournalPreflight' 'The transition journal failed strict validation.'
                            $diagnosticWritten=Write-CcodControllerDiagnostic $result $Request $Paths $adapter
                        }
                        if($null -eq $result){
                            if($null -ne $active -and $Request.action -cne 'Recover'){
                                $result=New-CcodControllerErrorResult $Request 'CCOD_TRANSITION_REPLAY_REQUIRED' 'ReplayRequired' 'An active transition requires recovery.'
                            }else{
                                try{
                                    $output=@(& $adapter.EngineInvoker $Request.action $Request $Paths)
                                    $candidates=@($output|Where-Object{$_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['schemaVersion']})
                                    if($candidates.Count -ne 1){throw 'engine returned zero or multiple framed result objects'}
                                    $result=$candidates[0];Assert-CcodControllerEngineResult $result $Request
                                }catch{
                                    $result=New-CcodControllerErrorResult $Request 'CCOD_CONTROLLER_ENGINE_RESULT_INVALID' 'EngineResult' $_.Exception.Message
                                    $diagnosticWritten=Write-CcodControllerDiagnostic $result $Request $Paths $adapter
                                }
                            }
                        }
                    }
                }
            }catch{
                $result=New-CcodControllerErrorResult $Request (Get-CcodControllerStableLeaseCode $_) 'LeaseAcquire' 'The transition lease could not be acquired safely.'
                $diagnosticWritten=Write-CcodControllerDiagnostic $result $Request $Paths $adapter
            }
        }
        try{& $adapter.WriteResult $ResultPath $result|Out-Null}catch{
            $result=New-CcodControllerErrorResult $Request 'CCOD_CONTROLLER_RESULT_WRITE_FAILED' 'ResultWrite' $_.Exception.Message
            if(-not $diagnosticWritten){$diagnosticWritten=Write-CcodControllerDiagnostic $result $Request $Paths $adapter}
            try{& $adapter.WriteStderr 'CCOD_CONTROLLER_RESULT_WRITE_FAILED: result persistence failed'|Out-Null}catch{}
        }
    }finally{
        if($sessionLeaseAcquired){try{$released=& $adapter.ExitMutex $sessionLease;if($released -isnot [bool] -or -not $released){$releaseFailed=$true}}catch{$releaseFailed=$true}}
        if($accountLeaseAcquired){try{$released=& $adapter.ExitMutex $accountLease;if($released -isnot [bool] -or -not $released){$releaseFailed=$true}}catch{$releaseFailed=$true}}
    }
    if($releaseFailed){
        $result=New-CcodControllerErrorResult $Request 'CCOD_KERNEL_RELEASE_FAILED' 'LeaseRelease' 'The transition lease could not be released safely.'
        $diagnosticWritten=Write-CcodControllerDiagnostic $result $Request $Paths $adapter
        try{& $adapter.WriteResult $ResultPath $result|Out-Null}catch{
            $result=New-CcodControllerErrorResult $Request 'CCOD_CONTROLLER_RESULT_WRITE_FAILED' 'ResultWrite' 'The corrected controller result could not be persisted.'
            [void](Write-CcodControllerDiagnostic $result $Request $Paths $adapter)
            try{& $adapter.WriteStderr 'CCOD_CONTROLLER_RESULT_WRITE_FAILED: result persistence failed'|Out-Null}catch{}
        }
    }
    $line=$result|ConvertTo-Json -Depth 16 -Compress
    & $adapter.WriteStdout $line|Out-Null
    $safe=@('Activated','Inspected','NoAction','Recovered','Closed') -ccontains $result.outcome
    return [pscustomobject][ordered]@{Result=$result;ExitCode=if($safe){0}else{1}}
}

function Get-CcodControllerInstallRoot {
    $localAppData=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    if([string]::IsNullOrWhiteSpace($localAppData)){$localAppData=[Environment]::GetFolderPath('LocalApplicationData')}
    if([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Path]::IsPathRooted($localAppData)){throw 'LOCALAPPDATA is unavailable'}
    return [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($localAppData)) 'CodexControlOtherDevices'))
}

function Resolve-CcodControllerRuntime {
    param([string]$InstallRoot=(Get-CcodControllerInstallRoot),[string]$ControllerPath=$script:CcodControllerScriptPath)
    try{
        $active=Read-CcodActiveRuntime -InstallRoot $InstallRoot
        $runtimeRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path $InstallRoot 'runtime') $active.activeRuntime))
        $validation=Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $active.activeRuntime
        $expectedController=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\persistence\SessionController.ps1'))
        if(-not $validation.Valid -or [IO.Path]::GetFullPath($ControllerPath) -cne $expectedController){throw 'active runtime mismatch'}
        return [pscustomobject][ordered]@{InstallRoot=[IO.Path]::GetFullPath($InstallRoot);RuntimeRoot=$runtimeRoot;RuntimeId=$active.activeRuntime;ControllerPath=$expectedController}
    }catch{
        $exception=[InvalidOperationException]::new('This controller is not the manifest-verified active installed runtime.')
        throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_RUNTIME_UNAUTHORIZED',[Management.Automation.ErrorCategory]::SecurityError,$ControllerPath)
    }
}

function Get-CcodInstalledControllerPaths {
    param([Parameter(Mandatory)]$RuntimeContext)
    $runtimeRoot=$RuntimeContext.RuntimeRoot;$installRoot=$RuntimeContext.InstallRoot
    $stateRoot=[IO.Path]::GetFullPath((Join-Path $installRoot 'state'))
    [pscustomobject][ordered]@{
        StateRoot=$stateRoot
        TransitionPath=[IO.Path]::GetFullPath((Join-Path $stateRoot 'transition.json'))
        TransitionLogPath=[IO.Path]::GetFullPath((Join-Path $installRoot 'logs\transactions.log'))
        SessionLogPath=[IO.Path]::GetFullPath((Join-Path $installRoot 'logs\session.log'))
        CheckerPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\check-package.mjs'))
        OrchestratorPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\runtime\orchestrator.js'))
        MainPayloadPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\runtime\main-payload.js'))
    }
}

function New-CcodManualControllerRequest {
    param([string]$Action,[string]$RuntimeId,$SupervisorIdentity,[bool]$ExistingOnly,$RendererPort,$MainPort,[int]$TimeoutMilliseconds,[bool]$RestartOrdinary,[string]$TransactionId=([guid]::NewGuid().ToString('D')))
    [pscustomobject][ordered]@{schemaVersion=1;action=$Action;transactionId=$TransactionId;runtimeId=$RuntimeId;supervisorIdentity=$SupervisorIdentity;source=$null;existingOnly=$ExistingOnly;rendererPort=$RendererPort;mainPort=$MainPort;timeoutMilliseconds=$TimeoutMilliseconds;restartOrdinary=$RestartOrdinary}
}

if($MyInvocation.InvocationName -ne '.'){
    if($PSCmdlet.ParameterSetName -ceq 'Supervisor' -and ([string]::IsNullOrWhiteSpace($RequestPath) -or [string]::IsNullOrWhiteSpace($ResultPath) -or -not [IO.Path]::IsPathRooted($RequestPath) -or -not [IO.Path]::IsPathRooted($ResultPath) -or [IO.Path]::GetFullPath($RequestPath) -cne $RequestPath -or [IO.Path]::GetFullPath($ResultPath) -cne $ResultPath)){
        $failure=New-CcodControllerErrorResult $null 'CCOD_REQUEST_INVALID' 'InputValidation' 'Canonical absolute RequestPath and ResultPath are required'
        [Console]::Out.WriteLine(($failure|ConvertTo-Json -Depth 16 -Compress));exit 1
    }
    try{$runtimeContext=Resolve-CcodControllerRuntime}catch{
        $failure=New-CcodControllerErrorResult $null 'CCOD_RUNTIME_UNAUTHORIZED' 'RuntimeAuthorization' 'The active installed runtime could not be verified.'
        if($PSCmdlet.ParameterSetName -ceq 'Supervisor'){try{Write-CcodAtomicJson -Path $ResultPath -Value $failure}catch{}}
        [Console]::Out.WriteLine(($failure|ConvertTo-Json -Depth 16 -Compress));exit 1
    }
    $paths=Get-CcodInstalledControllerPaths -RuntimeContext $runtimeContext
    if($PSCmdlet.ParameterSetName -ceq 'Supervisor'){
        try{$request=Read-CcodStrictJson -Path $RequestPath -ExpectedSchema 1 -Kind 'session controller request'}catch{
            $failure=New-CcodControllerErrorResult $null 'CCOD_REQUEST_INVALID' 'InputValidation' $_.Exception.Message
            try{Write-CcodAtomicJson -Path $ResultPath -Value $failure}catch{}
            [Console]::Out.WriteLine(($failure|ConvertTo-Json -Depth 16 -Compress));exit 1
        }
        if($request.runtimeId -isnot [string] -or $request.runtimeId -cne $runtimeContext.RuntimeId){
            $failure=New-CcodControllerErrorResult $request 'CCOD_RUNTIME_UNAUTHORIZED' 'RuntimeAuthorization' 'The request runtime does not match the active installed runtime.'
            try{Write-CcodAtomicJson -Path $ResultPath -Value $failure}catch{}
            [Console]::Out.WriteLine(($failure|ConvertTo-Json -Depth 16 -Compress));exit 1
        }
    } else {
        if([string]::IsNullOrWhiteSpace($Action)){
            $failure=New-CcodControllerErrorResult $null 'CCOD_REQUEST_INVALID' 'InputValidation' 'A manual Action is required'
            [Console]::Out.WriteLine(($failure|ConvertTo-Json -Depth 16 -Compress));exit 1
        }
        $runtimeId=$runtimeContext.RuntimeId
        $process=[Diagnostics.Process]::GetCurrentProcess()
        try{$created=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);$sessionId=[string]$process.SessionId}finally{$process.Dispose()}
        $request=New-CcodManualControllerRequest -Action $Action -RuntimeId $runtimeId -SupervisorIdentity ([pscustomobject][ordered]@{pid=$PID;creationTimeUtc=$created;sessionId=$sessionId}) -ExistingOnly $ExistingOnly -RendererPort $RendererPort -MainPort $MainPort -TimeoutMilliseconds $TimeoutMilliseconds -RestartOrdinary $RestartOrdinary
        $resultDirectory=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'CodexControlOtherDevices'))
        [IO.Directory]::CreateDirectory($resultDirectory)|Out-Null;$ResultPath=[IO.Path]::GetFullPath((Join-Path $resultDirectory ("manual-$($request.transactionId).json")))
    }
    $run=Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $ResultPath
    exit $run.ExitCode
}
