$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
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

$root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-controller-selftest-'+[guid]::NewGuid().ToString('N'))
try{
    $paths=New-CcodControllerPaths $root;$resultPath=Join-Path $root 'result.json'
    Invoke-CcodTest 'writes the atomic result before exactly one compressed stdout line' {
        $events=[Collections.Generic.List[string]]::new();$stdout=[Collections.Generic.List[string]]::new();$captured=[pscustomobject]@{Written=$null}
        $request=New-CcodControllerRequest
        $run=Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
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

    Invoke-CcodTest 'preserves correlation and maps the exact safe exit-code matrix including Closed' {
        foreach($outcome in @('Activated','Inspected','NoAction','Recovered','Closed','Error')){
            $stdout=[Collections.Generic.List[string]]::new();$request=New-CcodControllerRequest -TransactionId 'f81b6259-8e99-45fb-b557-c5292f05dfa3'
            $run=Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
                EngineInvoker={param($Action,$Request,$Paths)if($outcome -ceq 'Error'){[pscustomobject][ordered]@{schemaVersion=1;action=$Action;ok=$false;outcome='Error';safeState='Error';stage='Failed';transactionId=$Request.transactionId;package=$null;source=$null;special=$null;probes=$null;recovery=$null;error=[pscustomobject][ordered]@{code='TEST';stage='Failed';message='failed'};logFile=$null}}else{New-CcodControllerResult $Action $Request.transactionId $outcome}}.GetNewClosure()
                WriteResult={param($Path,$Value)};WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)}
            }
            Assert-CcodEqual $request.transactionId $run.Result.transactionId "$outcome keeps request correlation"
            $expected=if($outcome -ceq 'Error'){1}else{0};Assert-CcodEqual $expected $run.ExitCode "$outcome exit code"
        }
    }

    Invoke-CcodTest 'returns stable framing errors for malformed engine output or atomic result failure' {
        $request=New-CcodControllerRequest
        $malformed=Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{EngineInvoker={param($Action,$Request,$Paths)[pscustomobject]@{ok=$true}};WriteResult={param($Path,$Value)};WriteStdout={param($Line)};WriteStderr={param($Line)}}
        Assert-CcodEqual 'CCOD_CONTROLLER_ENGINE_RESULT_INVALID' $malformed.Result.error.code 'malformed engine output fails closed'

        $stdout=[Collections.Generic.List[string]]::new();$writeFailure=Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $resultPath -Adapters @{
            EngineInvoker={param($Action,$Request,$Paths)New-CcodControllerResult $Action $Request.transactionId}.GetNewClosure()
            WriteResult={param($Path,$Value)throw 'disk failed'};WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure();WriteStderr={param($Line)}
        }
        Assert-CcodEqual 'CCOD_CONTROLLER_RESULT_WRITE_FAILED' $writeFailure.Result.error.code 'atomic result failure has a stable code'
        Assert-CcodEqual 1 $writeFailure.ExitCode 'result write failure exits nonzero'
        Assert-CcodEqual 1 $stdout.Count 'result write failure still emits one machine-readable error line'
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

    Invoke-CcodTest 'process framing emits one stdout object and atomically writes the same invalid-request result' {
        $requestPath=[IO.Path]::GetFullPath((Join-Path $root 'process-request.json'));$processResultPath=[IO.Path]::GetFullPath((Join-Path $root 'process-result.json'));$stderrPath=[IO.Path]::GetFullPath((Join-Path $root 'process-stderr.txt'))
        $invalid=New-CcodControllerRequest;$invalid|Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        [IO.Directory]::CreateDirectory((Split-Path $requestPath -Parent))|Out-Null
        [IO.File]::WriteAllText($requestPath,($invalid|ConvertTo-Json -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
        $controllerPath=[IO.Path]::GetFullPath((Join-Path $repositoryRoot 'src\persistence\SessionController.ps1'))
        $stdout=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $controllerPath -RequestPath $requestPath -ResultPath $processResultPath 2>$stderrPath);$exitCode=$LASTEXITCODE
        $lines=@($stdout|ForEach-Object{[string]$_}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
        Assert-CcodEqual 1 $lines.Count 'process stdout contains exactly one nonblank JSON line'
        Assert-CcodEqual 1 $exitCode 'invalid request process exits nonzero'
        $fromStdout=$lines[0]|ConvertFrom-Json;$fromFile=Get-Content -LiteralPath $processResultPath -Raw|ConvertFrom-Json
        Assert-CcodEqual ($fromFile|ConvertTo-Json -Depth 16 -Compress) ($fromStdout|ConvertTo-Json -Depth 16 -Compress) 'atomic result file and stdout carry the same object'
        Assert-CcodEqual $invalid.transactionId $fromStdout.transactionId 'process framing preserves invalid request correlation when available'
        $stderrText=if([IO.File]::Exists($stderrPath)){[IO.File]::ReadAllText($stderrPath)}else{''}
        Assert-CcodTrue ($stderrText -cnotmatch 'schemaVersion') 'stderr does not contain a competing result object'
    }
}catch{Write-Error $_;exit 1}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
