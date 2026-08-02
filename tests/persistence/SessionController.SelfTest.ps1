$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1') -Force
. (Join-Path $repositoryRoot 'src\persistence\SessionController.ps1')

function New-CcodControllerRequest([string]$Action='Inspect',[string]$TransactionId='5f496d99-c839-4458-a6a2-d37ea1afdbda'){
    [pscustomobject][ordered]@{schemaVersion=1;action=$Action;transactionId=$TransactionId;runtimeId='runtime-1';supervisorIdentity=[pscustomobject][ordered]@{pid=11;creationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1'};source=$null;existingOnly=$true;rendererPort=$null;mainPort=$null;timeoutMilliseconds=30000;restartOrdinary=$true}
}
function New-CcodControllerPaths([string]$Root){
    $stable=Join-Path $Root 'install';$state=Join-Path $stable 'state';$runtime=Join-Path $stable 'runtime\runtime-1'
    [pscustomobject][ordered]@{StateRoot=[IO.Path]::GetFullPath($state);TransitionPath=[IO.Path]::GetFullPath((Join-Path $state 'transition.json'));TransitionLogPath=[IO.Path]::GetFullPath((Join-Path $stable 'logs\transactions.log'));SessionLogPath=[IO.Path]::GetFullPath((Join-Path $stable 'logs\session.log'));CheckerPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\check-package.mjs'));OrchestratorPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\runtime\orchestrator.js'));MainPayloadPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\runtime\main-payload.js'))}
}
function New-CcodControllerResult([string]$Action,[string]$TransactionId,[string]$Outcome='Inspected'){
    $safe=if($Outcome -ceq 'Closed'){'Closed'}elseif($Outcome -ceq 'Recovered'){'OrdinaryRunning'}else{'NoCodex'}
    [pscustomobject][ordered]@{schemaVersion=1;action=$Action;ok=$true;outcome=$Outcome;safeState=$safe;stage='Completed';transactionId=$TransactionId;package=$null;source=$null;special=$null;probes=$null;recovery=$null;error=$null;logFile=$null}
}

function New-CcodControllerTestLease([string]$Kind,[string]$Outcome='Acquired',[bool]$Abandoned=$false){
    [pscustomobject][ordered]@{SchemaVersion=1;Name="PrivateTest.$Kind";Kind=$Kind;Outcome=$Outcome;CreatedNew=$true;Abandoned=$Abandoned;Handle=$null;OwnerManagedThreadId=1;Released=($Outcome -cne 'Acquired')}
}

function Merge-CcodControllerTestAdapters([hashtable]$Overrides){
    $resolved=@{
        GetIdentity={ [pscustomobject][ordered]@{UserSid='S-1-5-21-111-222-333-1001';SessionId=[int]1} }
        StartStopwatch={ [pscustomobject]@{Marker='test-clock'} }
        GetElapsedMilliseconds={param($Clock)[long]0}
        EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)New-CcodControllerTestLease -Kind $Kind}
        ExitMutex={param($Lease)$Lease.Released=$true;$true}
        ReadJournal={param($Path)$null}
        UtcNow={ [DateTime]::Parse('2030-02-03T03:00:00Z').ToUniversalTime() }
    }
    if($null -ne $Overrides){foreach($name in $Overrides.Keys){$resolved[$name]=$Overrides[$name]}}
    return $resolved
}

function Invoke-CcodLeasedTestController {
    param($Request,$Paths,[string]$ResultPath,[hashtable]$Adapters)
    Invoke-CcodSessionController -Request $Request -Paths $Paths -ResultPath $ResultPath -Adapters (Merge-CcodControllerTestAdapters $Adapters)
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-controller-selftest-'+[guid]::NewGuid().ToString('N'))
try{
    $paths=New-CcodControllerPaths $root;$resultPath=Join-Path $root 'result.json'
    Invoke-CcodTest 'writes the atomic result before exactly one compressed stdout line' {
        $events=[Collections.Generic.List[string]]::new();$stdout=[Collections.Generic.List[string]]::new();$captured=[pscustomobject]@{Written=$null}
        $request=New-CcodControllerRequest
        $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={param($Action,$Request,$Paths)'incidental';New-CcodControllerResult $Action $Request.transactionId}.GetNewClosure()
            WriteResult={param($Path,$Value)$events.Add('write');$captured.Written=$Value}.GetNewClosure()
            WriteStdout={param($Line)$events.Add('stdout');$stdout.Add($Line)}.GetNewClosure()
            WriteStderr={param($Line)$events.Add('stderr')}.GetNewClosure()
        }
        Assert-CcodEqual 'write,stdout' ($events -join ',') 'atomic result write precedes stdout and no diagnostic leaks'
        Assert-CcodEqual 1 $stdout.Count 'stdout receives exactly one call'
        Assert-CcodTrue ($stdout[0] -cnotmatch '[\r\n]') 'compressed JSON argument contains no embedded newline'
        Assert-CcodEqual ($captured.Written|ConvertTo-Json -Depth 16 -Compress) $stdout[0] 'stdout is the same object that was written atomically'
        Assert-CcodEqual 0 $run.ExitCode 'Inspected is exit zero'
    }

    Invoke-CcodTest 'acquires account then session leases and releases them in reverse after atomic persistence' {
        $events=[Collections.Generic.List[string]]::new();$timeouts=[Collections.Generic.List[int]]::new();$elapsed=[Collections.Generic.Queue[long]]::new();$elapsed.Enqueue(0);$elapsed.Enqueue(1250)
        $request=New-CcodControllerRequest;$run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            GetElapsedMilliseconds={param($Clock)$elapsed.Dequeue()}.GetNewClosure()
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:${Kind}:$SessionId");$timeouts.Add($TimeoutMilliseconds);New-CcodControllerTestLease $Kind}.GetNewClosure()
            ExitMutex={param($Lease)$events.Add("exit:$($Lease.Kind)");$Lease.Released=$true;$true}.GetNewClosure()
            ReadJournal={param($Path)$events.Add('journal');$null}.GetNewClosure()
            EngineInvoker={param($Action,$Request,$Paths)$events.Add('engine');New-CcodControllerResult $Action $Request.transactionId}.GetNewClosure()
            WriteResult={param($Path,$Value)$events.Add('write')}.GetNewClosure()
            WriteStdout={param($Line)$events.Add('stdout')}.GetNewClosure()
            WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'enter:AccountTransition:,enter:Transition:1,journal,engine,write,exit:Transition,exit:AccountTransition,stdout' ($events -join ',') 'lease wrapper covers journal engine and result, then releases before stdout'
        Assert-CcodEqual '5000,3750' ($timeouts -join ',') 'one five-second budget supplies exact remaining milliseconds to the second wait'
        Assert-CcodEqual 0 $run.ExitCode 'normal leased inspect remains safe'
    }

    Invoke-CcodTest 'first timeout prevents local lease journal and engine and returns correlated busy' {
        $events=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -Action Apply
        $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");New-CcodControllerTestLease $Kind TimedOut}.GetNewClosure()
            ReadJournal={param($Path)$events.Add('journal');throw 'must not read journal'}.GetNewClosure()
            EngineInvoker={param($Action,$Request,$Paths)$events.Add('engine');throw 'must not invoke engine'}.GetNewClosure()
            WriteResult={param($Path,$Value)$events.Add('write')}.GetNewClosure();WriteStdout={param($Line)$events.Add('stdout')}.GetNewClosure();WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'enter:AccountTransition,write,stdout' ($events -join ',') 'first timeout has no local or state action'
        Assert-CcodEqual 'CCOD_TRANSITION_BUSY' $run.Result.error.code 'first timeout is stable busy'
        Assert-CcodEqual 'LeaseAcquire' $run.Result.stage 'busy stage is exact'
        Assert-CcodEqual $request.transactionId $run.Result.transactionId 'busy preserves canonical correlation'
    }

    Invoke-CcodTest 'second timeout releases account and prevents journal and engine' {
        $events=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest
        $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");if($Kind -ceq 'Transition'){New-CcodControllerTestLease $Kind TimedOut}else{New-CcodControllerTestLease $Kind}}.GetNewClosure()
            ExitMutex={param($Lease)$events.Add("exit:$($Lease.Kind)");$Lease.Released=$true;$true}.GetNewClosure()
            ReadJournal={param($Path)$events.Add('journal');throw 'must not read'}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$events.Add('engine');throw 'must not invoke'}.GetNewClosure()
            WriteResult={param($Path,$Value)$events.Add('write')}.GetNewClosure();WriteStdout={param($Line)$events.Add('stdout')}.GetNewClosure();WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'enter:AccountTransition,enter:Transition,write,exit:AccountTransition,stdout' ($events -join ',') 'account is released after local timeout and before stdout'
        Assert-CcodEqual 'CCOD_TRANSITION_BUSY' $run.Result.error.code 'second timeout is stable busy'
    }

    Invoke-CcodTest 'acquisition exception and actual-session mismatch fail before engine actions' {
        $request=New-CcodControllerRequest
        $exceptionEvents=[Collections.Generic.List[string]]::new();$exceptionLogs=[Collections.Generic.List[string]]::new();$failure=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$exceptionEvents.Add("enter:$Kind");throw "C:\private\acl.sddl`n--token hunter2"}.GetNewClosure()
            ReadJournal={param($Path)$exceptionEvents.Add('journal')}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$exceptionEvents.Add('engine')}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Line)$exceptionLogs.Add($Line)}.GetNewClosure()
        }
        Assert-CcodEqual 'enter:AccountTransition' ($exceptionEvents -join ',') 'acquisition exception cannot reach journal or engine'
        Assert-CcodEqual 'CCOD_KERNEL_OPEN_FAILED' $failure.Result.error.code 'unrecognized acquisition exception maps to one stable kernel code'
        Assert-CcodEqual 'LeaseAcquire' $failure.Result.stage 'acquisition exception remains in lease stage'
        Assert-CcodEqual 1 $exceptionLogs.Count 'acquisition exception writes one bounded diagnostic'
        Assert-CcodTrue ((($failure.Result|ConvertTo-Json -Depth 16 -Compress)+$exceptionLogs[0]) -cnotmatch 'private|hunter2|sddl') 'acquisition exception is redacted from framing and log'

        $mismatchEvents=[Collections.Generic.List[string]]::new();$mismatch=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            GetIdentity={ [pscustomobject][ordered]@{UserSid='S-1-5-21-111-222-333-1001';SessionId=[int]2} }
            EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$mismatchEvents.Add('enter');throw 'must not acquire'}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$mismatchEvents.Add('engine')}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
        }
        Assert-CcodEqual 0 $mismatchEvents.Count 'request session mismatch has no lease or engine action'
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $mismatch.Result.error.code 'actual session mismatch is stable request invalid'
        Assert-CcodEqual 'InputValidation' $mismatch.Result.stage 'session mismatch is input validation'
    }

    Invoke-CcodTest 'active journal permits only Recover and otherwise requires a fresh replay request' {
        $active=[pscustomobject]@{transactionId='1b2c5c27-e6e3-4ae4-a876-a59418519d41';stage='OrdinaryStopped'}
        $recoverCalls=[Collections.Generic.List[string]]::new();$recoverRequest=New-CcodControllerRequest -Action Recover
        $recovered=Invoke-CcodLeasedTestController -Request $recoverRequest -Paths $paths -ResultPath $resultPath -Adapters @{
            ReadJournal={param($Path)$active}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$recoverCalls.Add($Action);New-CcodControllerResult $Action $Request.transactionId Recovered}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'Recover' ($recoverCalls -join ',') 'active transaction dispatches exactly one Recover'
        Assert-CcodEqual 'Recovered' $recovered.Result.outcome 'Recover result remains Task 8 compatible'

        foreach($action in @('Inspect','Apply','RepairRenderer')){
            $calls=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -Action $action
            $blocked=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                ReadJournal={param($Path)$active}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$calls.Add($Action);throw 'must not invoke'}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
            }
            Assert-CcodEqual 0 $calls.Count "$action cannot bypass active journal"
            Assert-CcodEqual 'CCOD_TRANSITION_REPLAY_REQUIRED' $blocked.Result.error.code "$action returns stable replay requirement"
            Assert-CcodEqual 'ReplayRequired' $blocked.Result.stage "$action replay stage"
        }
    }

    Invoke-CcodTest 'abandonment logs one exact warning then replays or invokes once without reacquiring' {
        foreach($withJournal in @($true,$false)){
            $events=[Collections.Generic.List[string]]::new();$logs=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -Action $(if($withJournal){'Recover'}else{'Apply'})
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");New-CcodControllerTestLease $Kind Acquired ($Kind -ceq 'AccountTransition')}.GetNewClosure()
                ReadJournal={param($Path)$events.Add('journal');if($withJournal){[pscustomobject]@{transactionId='1b2c5c27-e6e3-4ae4-a876-a59418519d41';stage='SpecialStarted'}}else{$null}}.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths)$events.Add("engine:$Action");New-CcodControllerResult $Action $Request.transactionId $(if($Action -ceq 'Recover'){'Recovered'}else{'Activated'})}.GetNewClosure()
                WriteLog={param($Path,$Line)$logs.Add($Line)}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
            }
            Assert-CcodEqual 2 @($events|Where-Object{$_ -like 'enter:*'}).Count 'abandoned ownership is not released and reacquired'
            Assert-CcodEqual 1 @($events|Where-Object{$_ -like 'engine:*'}).Count 'abandoned path invokes exactly once'
            Assert-CcodEqual 1 $logs.Count 'one warning is emitted even if one of two leases is abandoned'
            $record=$logs[0]|ConvertFrom-Json
            Assert-CcodEqual 'schemaVersion,timestampUtc,action,transactionId,stage,code' (($record.PSObject.Properties.Name)-join ',') 'warning record has exact bounded fields'
            Assert-CcodEqual 'LeaseAcquire' $record.stage 'warning stage'
            Assert-CcodEqual 'CCOD_TRANSITION_ABANDONED' $record.code 'warning code'
        }
    }

    Invoke-CcodTest 'engine and result-write exceptions release both leases exactly once' {
        foreach($failurePoint in @('Engine','Write')){
            $releases=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest
            $adapters=@{
                ExitMutex={param($Lease)$releases.Add($Lease.Kind);$Lease.Released=$true;$true}.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths)if($failurePoint -ceq 'Engine'){throw 'engine secret path C:\private\x'}else{New-CcodControllerResult $Action $Request.transactionId}}.GetNewClosure()
                WriteResult={param($Path,$Value)if($failurePoint -ceq 'Write'){throw 'write secret token hunter2'}}.GetNewClosure()
                WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Line)}
            }
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters $adapters
            Assert-CcodEqual 'Transition,AccountTransition' ($releases -join ',') "$failurePoint releases local then account exactly once"
            Assert-CcodEqual 1 $run.ExitCode "$failurePoint exits unsafe"
            Assert-CcodTrue (($run.Result|ConvertTo-Json -Depth 16 -Compress) -cnotmatch 'private|hunter2|secret') "$failurePoint public framing is sanitized"
        }
    }

    Invoke-CcodTest 'clock or warning-log failure cannot bypass release and stable framing' {
        foreach($mode in @('Diagnostic','AbandonedWarning')){
            $releases=[Collections.Generic.List[string]]::new();$engineCalls=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -Action $(if($mode -ceq 'Diagnostic'){'Inspect'}else{'Apply'})
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                UtcNow={throw "C:\private\clock`n--token hunter2"}
                EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)New-CcodControllerTestLease $Kind Acquired ($mode -ceq 'AbandonedWarning' -and $Kind -ceq 'AccountTransition')}.GetNewClosure()
                EngineInvoker={param($Action,$Request,$Paths)$engineCalls.Add($Action);if($mode -ceq 'Diagnostic'){throw 'engine failed'}else{New-CcodControllerResult $Action $Request.transactionId Activated}}.GetNewClosure()
                ExitMutex={param($Lease)$releases.Add($Lease.Kind);$Lease.Released=$true;$true}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Line)throw 'log unavailable'}
            }
            Assert-CcodEqual 'Transition,AccountTransition' ($releases -join ',') "$mode still releases both leases"
            Assert-CcodEqual 1 $engineCalls.Count "$mode retains the intended single engine dispatch"
            Assert-CcodTrue (($run.Result|ConvertTo-Json -Depth 16 -Compress) -cnotmatch 'private|hunter2|clock') "$mode returns bounded public framing"
        }
    }

    Invoke-CcodTest 'preserves correlation and maps the exact safe exit-code matrix including Closed' {
        foreach($outcome in @('Activated','Inspected','NoAction','Recovered','Closed','Error')){
            $stdout=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -TransactionId 'f81b6259-8e99-45fb-b557-c5292f05dfa3'
            $run=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                EngineInvoker={param($Action,$Request,$Paths)if($outcome -ceq 'Error'){[pscustomobject][ordered]@{schemaVersion=1;action=$Action;ok=$false;outcome='Error';safeState='Error';stage='Failed';transactionId=$Request.transactionId;package=$null;source=$null;special=$null;probes=$null;recovery=$null;error=[pscustomobject][ordered]@{code='TEST';stage='Failed';message='failed'};logFile=$null}}else{New-CcodControllerResult $Action $Request.transactionId $outcome}}.GetNewClosure()
                WriteResult={param($Path,$Value)};WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)}
            }
            Assert-CcodEqual $request.transactionId $run.Result.transactionId "$outcome keeps request correlation"
            $expected=if($outcome -ceq 'Error'){1}else{0};Assert-CcodEqual $expected $run.ExitCode "$outcome exit code"
        }
    }

    Invoke-CcodTest 'returns stable framing errors for malformed engine output or atomic result failure' {
        $request=New-CcodControllerRequest
        $malformed=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{EngineInvoker={param($Action,$Request,$Paths)[pscustomobject]@{ok=$true}};WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}}
        Assert-CcodEqual 'CCOD_CONTROLLER_ENGINE_RESULT_INVALID' $malformed.Result.error.code 'malformed engine output fails closed'

        $stdout=[Collections.Generic.List[string]]::new();$writeFailure=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={param($Action,$Request,$Paths)New-CcodControllerResult $Action $Request.transactionId}.GetNewClosure()
            WriteResult={param($Path,$Value)throw 'disk failed'};WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'CCOD_CONTROLLER_RESULT_WRITE_FAILED' $writeFailure.Result.error.code 'atomic result failure has a stable code'
        Assert-CcodEqual 1 $writeFailure.ExitCode 'result write failure exits nonzero'
        Assert-CcodEqual 1 $stdout.Count 'result write failure still emits one machine-readable error line'

        $secret="C:\private\request.json`n--token hunter2`ncommand.exe --password=swordfish";$logs=[Collections.Generic.List[string]]::new()
        $leak=Invoke-CcodLeasedTestController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={param($Action,$Request,$Paths)throw $secret}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
            WriteLog={param($Path,$Message)$logs.Add($Message)}.GetNewClosure()
        }
        Assert-CcodEqual 'The session controller failed safely. See the session log for details.' $leak.Result.error.message 'controller public error is fixed and generic'
        Assert-CcodEqual $paths.SessionLogPath $leak.Result.logFile 'controller returns a safe log reference after diagnostic persistence'
        Assert-CcodEqual 1 $logs.Count 'controller failure writes one allowlisted diagnostic'
        Assert-CcodTrue ($logs[0] -cnotmatch 'private|hunter2|swordfish|command\.exe|[\r\n]') 'controller diagnostic never contains raw exception data'
        $logRecord=$logs[0]|ConvertFrom-Json
        Assert-CcodEqual 'schemaVersion,timestampUtc,action,transactionId,stage,code' (($logRecord.PSObject.Properties.Name)-join ',') 'controller diagnostic uses the fixed allowlist'
        Assert-CcodEqual 'CCOD_CONTROLLER_ENGINE_RESULT_INVALID' $logRecord.code 'controller diagnostic retains only the stable error code'

        $missingAction=[pscustomobject]@{transactionId='5f496d99-c839-4458-a6a2-d37ea1afdbda'};$missingStdout=[Collections.Generic.List[string]]::new()
        $missing=Invoke-CcodLeasedTestController -Request $missingAction -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={throw 'must not dispatch'};WriteResult={param($Path,$Value)};WriteStdout={param($Line)$missingStdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)};WriteLog={param($Path,$Message)}
        }
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $missing.Result.error.code 'a missing action is rejected before lease or engine dispatch'
        Assert-CcodEqual 1 $missingStdout.Count 'a malformed request cannot break one-line controller framing'

        $poison="C:\secret\device-key.json`n--token hunter2";$poisonLogs=[Collections.Generic.List[string]]::new()
        $poisonedRequest=[pscustomobject]@{action=$poison;transactionId="bad`n--password swordfish"}
        $poisoned=Invoke-CcodLeasedTestController -Request $poisonedRequest -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={throw 'must not dispatch'};WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)};WriteLog={param($Path,$Message)$poisonLogs.Add($Message)}.GetNewClosure()
        }
        Assert-CcodEqual $null $poisoned.Result.action 'invalid action metadata is not echoed into the public result'
        Assert-CcodEqual $null $poisoned.Result.transactionId 'noncanonical transaction metadata is not echoed into the public result'
        Assert-CcodTrue ((($poisoned.Result|ConvertTo-Json -Depth 16 -Compress)+($poisonLogs -join '')) -cnotmatch 'secret|hunter2|swordfish|device-key') 'malformed request metadata cannot bypass public and log redaction'
    }

    Invoke-CcodTest 'constructs direct manual input as the same strict eleven-field request' {
        $identity=[pscustomobject][ordered]@{pid=11;creationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1'}
        $request=New-CcodManualControllerRequest -Action Apply -RuntimeId runtime-1 -SupervisorIdentity $identity -ExistingOnly $false -RendererPort $null -MainPort 41002 -TimeoutMilliseconds 30000 -RestartOrdinary $true -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda'
        Assert-CcodEqual 'schemaVersion,action,transactionId,runtimeId,supervisorIdentity,source,existingOnly,rendererPort,mainPort,timeoutMilliseconds,restartOrdinary' (($request.PSObject.Properties.Name)-join ',') 'manual request has exact strict field order'
        Assert-CcodEqual $null $request.source 'manual Start does not invent a source snapshot'
        Assert-CcodEqual $false $request.existingOnly 'manual Start can authorize closed-app activation'
        $result=Invoke-CcodApplySession -Request $request -Paths $paths -Adapters @{ReadState={throw 'expected after validation'}}
        Assert-CcodTrue ($result.error.code -cne 'CCOD_REQUEST_INVALID') 'manual request reaches the same engine contract without a looser translation'
    }

    Invoke-CcodTest 'routes both manual construction and strict request-file input through the lease wrapper' {
        $identity=[pscustomobject][ordered]@{pid=11;creationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1'}
        $manual=New-CcodManualControllerRequest -Action Inspect -RuntimeId runtime-1 -SupervisorIdentity $identity -ExistingOnly $true -RendererPort $null -MainPort $null -TimeoutMilliseconds 30000 -RestartOrdinary $true -TransactionId '5f496d99-c839-4458-a6a2-d37ea1afdbda'
        $requestFile=Join-Path $root 'leased-request.json';Write-CcodAtomicJson -Path $requestFile -Value (New-CcodControllerRequest -TransactionId 'f81b6259-8e99-45fb-b557-c5292f05dfa3');$fromFile=Read-CcodStrictJson -Path $requestFile -ExpectedSchema 1 -Kind 'session controller request'
        foreach($case in @($manual,$fromFile)){
            $events=[Collections.Generic.List[string]]::new()
            $run=Invoke-CcodLeasedTestController -Request $case -Paths $paths -ResultPath $resultPath -Adapters @{
                EnterMutex={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)$events.Add("enter:$Kind");New-CcodControllerTestLease $Kind}.GetNewClosure();EngineInvoker={param($Action,$Request,$Paths)$events.Add("engine:$Action");New-CcodControllerResult $Action $Request.transactionId}.GetNewClosure();WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}
            }
            Assert-CcodEqual 'enter:AccountTransition,enter:Transition,engine:Inspect' (($events|Where-Object{$_ -like 'enter:*' -or $_ -like 'engine:*'})-join ',') 'both input origins execute only through both leases'
            Assert-CcodEqual 0 $run.ExitCode 'both strict input origins retain safe framing'
        }
    }

    Invoke-CcodTest 'checkout and stale controller children fail runtime authorization before state or process IO' {
        $requestPath=[IO.Path]::GetFullPath((Join-Path $root 'process-request.json'));$processResultPath=[IO.Path]::GetFullPath((Join-Path $root 'process-result.json'));$stderrPath=[IO.Path]::GetFullPath((Join-Path $root 'process-stderr.txt'))
        $invalid=New-CcodControllerRequest;$invalid|Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        [IO.Directory]::CreateDirectory((Split-Path $requestPath -Parent))|Out-Null
        [IO.File]::WriteAllText($requestPath,($invalid|ConvertTo-Json -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
        $controllerPath=[IO.Path]::GetFullPath((Join-Path $repositoryRoot 'src\persistence\SessionController.ps1'))
        $fakeLocalAppData=[IO.Path]::GetFullPath((Join-Path $root 'checkout-localappdata'));$priorLocalAppData=$env:LOCALAPPDATA
        try{$env:LOCALAPPDATA=$fakeLocalAppData;$stdout=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $controllerPath -RequestPath $requestPath -ResultPath $processResultPath 2>$stderrPath);$exitCode=$LASTEXITCODE}finally{$env:LOCALAPPDATA=$priorLocalAppData}
        $lines=@($stdout|ForEach-Object{[string]$_}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
        Assert-CcodEqual 1 $lines.Count 'process stdout contains exactly one nonblank JSON line'
        Assert-CcodEqual 1 $exitCode 'checkout controller process exits nonzero'
        $fromStdout=$lines[0]|ConvertFrom-Json;$fromFile=Get-Content -LiteralPath $processResultPath -Raw|ConvertFrom-Json
        Assert-CcodEqual ($fromFile|ConvertTo-Json -Depth 16 -Compress) ($fromStdout|ConvertTo-Json -Depth 16 -Compress) 'atomic result file and stdout carry the same object'
        Assert-CcodEqual 'CCOD_RUNTIME_UNAUTHORIZED' $fromStdout.error.code 'checkout controller cannot infer an installed root from PSScriptRoot'
        Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $fakeLocalAppData 'CodexControlOtherDevices\state')) 'checkout rejection touches no state root'
        $stderrText=if([IO.File]::Exists($stderrPath)){[IO.File]::ReadAllText($stderrPath)}else{''}
        Assert-CcodTrue ($stderrText -cnotmatch 'schemaVersion') 'stderr does not contain a competing result object'

        $staleLocalAppData=[IO.Path]::GetFullPath((Join-Path $root 'stale-localappdata'));$installRoot=Join-Path $staleLocalAppData 'CodexControlOtherDevices';$staging=Join-Path $installRoot 'staging-active'
        [IO.Directory]::CreateDirectory($staging)|Out-Null;[IO.File]::WriteAllText((Join-Path $staging 'active.txt'),'active',[Text.UTF8Encoding]::new($false))
        $manifest=New-CcodRuntimeManifest -RuntimeDirectory $staging -ProjectVersion '2.0.0';$activeRuntime=Join-Path (Join-Path $installRoot 'runtime') $manifest.runtimeId
        [IO.Directory]::CreateDirectory((Split-Path $activeRuntime -Parent))|Out-Null;[IO.Directory]::Move($staging,$activeRuntime);Write-CcodAtomicJson -Path (Join-Path $activeRuntime 'manifest.json') -Value $manifest;Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $manifest.runtimeId|Out-Null
        $staleRuntime=Join-Path $installRoot 'runtime\stale-runtime';Copy-Item -LiteralPath (Join-Path $repositoryRoot 'src') -Destination (Join-Path $staleRuntime 'src') -Recurse
        $staleController=[IO.Path]::GetFullPath((Join-Path $staleRuntime 'src\persistence\SessionController.ps1'));$staleResult=[IO.Path]::GetFullPath((Join-Path $root 'stale-result.json'))
        try{$env:LOCALAPPDATA=$staleLocalAppData;$staleStdout=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $staleController -RequestPath $requestPath -ResultPath $staleResult 2>$stderrPath);$staleExit=$LASTEXITCODE}finally{$env:LOCALAPPDATA=$priorLocalAppData}
        $staleLines=@($staleStdout|ForEach-Object{[string]$_}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
        Assert-CcodEqual 1 $staleLines.Count 'stale runtime emits one framed error'
        Assert-CcodEqual 1 $staleExit 'stale runtime exits nonzero'
        Assert-CcodEqual 'CCOD_RUNTIME_UNAUTHORIZED' (($staleLines[0]|ConvertFrom-Json).error.code) 'non-active runtime controller is rejected before request dispatch'
        Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $installRoot 'state')) 'stale runtime rejection touches no installed state'
    }
}catch{Write-Error $_;exit 1}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
