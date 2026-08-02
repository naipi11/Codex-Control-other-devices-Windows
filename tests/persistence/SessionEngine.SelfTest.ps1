$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\SessionEngine.psm1') -Force

function New-CcodEngineSnapshot {
    param(
        [Alias('Pid')][int]$ProcessId = 100,
        [string]$CreationTimeUtc = '2030-02-03T04:00:00.0000000Z',
        [ValidateSet('Ordinary','Special','Unrelated')][string]$Mode = 'Ordinary',
        [AllowNull()][Nullable[int]]$ParentPid = $null,
        [AllowNull()][Nullable[int]]$RendererPort = $null,
        [AllowNull()][Nullable[int]]$MainPort = $null,
        [bool]$IsTopLevel = $true
    )
    [pscustomobject][ordered]@{
        Pid=$ProcessId; CreationTimeUtc=$CreationTimeUtc; SessionId=1; UserSid='S-1-5-21-test'
        Path='C:\Codex\ChatGPT.exe'; PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'
        CommandLine='"C:\Codex\ChatGPT.exe"'; ParentPid=$ParentPid; IsTopLevel=$IsTopLevel; Mode=$Mode
        RendererPort=$RendererPort; MainPort=$MainPort
    }
}

function New-CcodEngineRequest {
    param(
        [ValidateSet('Inspect','Apply','RepairRenderer','Recover')][string]$Action = 'Inspect',
        $Source = $null,
        [bool]$ExistingOnly = $true,
        [AllowNull()][Nullable[int]]$RendererPort = $null,
        [AllowNull()][Nullable[int]]$MainPort = $null,
        [bool]$RestartOrdinary = $true,
        [ValidateRange(1,120000)][int]$TimeoutMilliseconds = 30000,
        [string]$TransactionId = '5f496d99-c839-4458-a6a2-d37ea1afdbda'
    )
    [pscustomobject][ordered]@{
        schemaVersion=1; action=$Action; transactionId=$TransactionId; runtimeId='runtime-1'
        supervisorIdentity=[pscustomobject][ordered]@{ pid=11; creationTimeUtc='2030-02-03T03:00:00.0000000Z'; sessionId='1' }
        source=$Source; existingOnly=$ExistingOnly; rendererPort=$RendererPort; mainPort=$MainPort
        timeoutMilliseconds=$TimeoutMilliseconds; restartOrdinary=$RestartOrdinary
    }
}

function New-CcodEnginePaths([string]$Root) {
    $stable = Join-Path $Root 'install'
    $state = Join-Path $stable 'state'
    $runtime = Join-Path $stable 'runtime\runtime-1'
    [pscustomobject][ordered]@{
        StateRoot=[IO.Path]::GetFullPath($state)
        TransitionPath=[IO.Path]::GetFullPath((Join-Path $state 'transition.json'))
        TransitionLogPath=[IO.Path]::GetFullPath((Join-Path $stable 'logs\transactions.log'))
        SessionLogPath=[IO.Path]::GetFullPath((Join-Path $stable 'logs\session.log'))
        CheckerPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\check-package.mjs'))
        OrchestratorPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\runtime\orchestrator.js'))
        MainPayloadPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\runtime\main-payload.js'))
    }
}

function New-CcodEngineState {
    param($Status = ([pscustomobject]@{ schemaVersion=1; session=$null }), $ActiveTransaction = $null)
    [pscustomobject]@{
        Settings=[pscustomobject]@{ automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates=@('C:\Node\node.exe') }
        Status=$Status
        VerifiedPackages=[pscustomobject]@{ schemaVersion=1; packages=[pscustomobject]@{} }
        Transition=[pscustomobject]@{ schemaVersion=1; activeTransaction=$ActiveTransaction }
        AutomationEnabled=$true; AutomaticCandidateTrialsAllowed=$true; TransitionActionsAllowed=$true
        StatusRebuildRequired=$false; Damage=[pscustomobject]@{}
    }
}

function New-CcodEngineProbe {
    param([string]$Classification='CandidateCompatible')
    [pscustomobject]@{
        Ready=($Classification -ceq 'CandidateCompatible'); Code='CHECKER_OK'; StaticClassification=$Classification
        PackageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'
        FamilyName='OpenAI.Codex_2p2nqsd0c76g0'; PackageVersion='1.0.0.0'; ExecutablePath='C:\Codex\ChatGPT.exe'
        AppAsarSha256=('a' * 64); NodePath='C:\Node\node.exe'; Signatures=[pscustomobject]@{}
        NativeModulePresent=($Classification -ceq 'NativeModulePresent')
    }
}

function New-CcodEngineActiveStatus {
    [pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
}

function New-CcodEngineTransition {
    param(
        [ValidateSet('IntentWritten','StopRequested','OrdinaryStopped','SpecialLaunchRequested','SpecialStarted','Validated','RecoveryLaunchRequested','Recovered','CloseRequested','Closed')][string]$Stage,
        [switch]$WithPorts,[switch]$WithSpecial,[switch]$WithRecovery,[switch]$Manual,
        [string]$TransactionId='3f91d267-44f2-4f23-855d-2b4577e7c118'
    )
    [pscustomobject][ordered]@{
        transactionId=$TransactionId;stage=$Stage;sourcePid=if($Manual){$null}else{100};sourceCreationTimeUtc=if($Manual){$null}else{'2030-02-03T04:00:00.0000000Z'}
        packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';appAsarSha256=('a'*64);runtimeId='runtime-1'
        mainPort=if($WithPorts){41002}else{$null};rendererPort=if($WithPorts){41001}else{$null}
        specialPid=if($WithSpecial){201}else{$null};specialCreationTimeUtc=if($WithSpecial){'2030-02-03T04:05:07.0000000Z'}else{$null}
        recoveryPid=if($WithRecovery){301}else{$null};recoveryCreationTimeUtc=if($WithRecovery){'2030-02-03T04:06:01.0000000Z'}else{$null}
        createdAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:06:02.0000000Z'
    }
}

function New-CcodFullBridgeInvocation {
    $proof = [ordered]@{
        ok=$true; protocolVersion=1
        main=[ordered]@{ inspectorPortClosed=[ordered]@{ confirmed=$true; code='ECONNREFUSED' }; payloadReport=[ordered]@{ installed=$true } }
        renderer=[ordered]@{
            targetUrl='app://-/index.html'; currentDocument=[ordered]@{ installed=$true }
            newDocumentScriptInstalled=$true; probe=[ordered]@{ proof=$true; targetGate='782640499' }
        }
    }
    [pscustomobject][ordered]@{ ExitCode=0; Stdout=($proof | ConvertTo-Json -Depth 16 -Compress); Stderr='' }
}

function New-CcodRendererBridgeInvocation {
    $proof=[ordered]@{ok=$true;protocolVersion=1;renderer=[ordered]@{targetUrl='app://-/index.html';currentDocument=[ordered]@{installed=$true};newDocumentScriptInstalled=$true;probe=[ordered]@{proof=$true;targetGate='782640499'}}}
    [pscustomobject][ordered]@{ExitCode=0;Stdout=($proof|ConvertTo-Json -Depth 16 -Compress);Stderr=''}
}

function Invoke-CcodParserOnlyBridgeChild {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $driver=@'
const orchestrator = require(process.argv[1]);
try {
  const options = orchestrator.parseArguments(process.argv.slice(2));
  const renderer = {targetUrl:'app://-/index.html',currentDocument:{installed:true},newDocumentScriptInstalled:true,probe:{proof:true,targetGate:'782640499'}};
  const proof = options.mode === 'full'
    ? {ok:true,protocolVersion:1,main:{inspectorPortClosed:{confirmed:true,code:'ECONNREFUSED'},payloadReport:{installed:true}},renderer}
    : {ok:true,protocolVersion:1,renderer};
  process.stdout.write(JSON.stringify(proof));
} catch (error) {
  process.stdout.write(JSON.stringify({ok:false,error:{code:error.code || 'UNEXPECTED_ERROR'}}));
  process.exitCode = 1;
}
'@
    $stderrPath=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ccod-parser-$([guid]::NewGuid().ToString('N')).err")))
    try{
        $node=(Get-Command node.exe -ErrorAction Stop).Source
        $parserPath=[IO.Path]::GetFullPath((Join-Path $repositoryRoot 'src\runtime\orchestrator.js'))
        $cliArguments=@($Arguments|Select-Object -Skip 1)
        $stdout=@(& $node -e $driver $parserPath @cliArguments 2>$stderrPath)
        $exitCode=$LASTEXITCODE
        $stderr=if([IO.File]::Exists($stderrPath)){[IO.File]::ReadAllText($stderrPath)}else{''}
    }finally{if([IO.File]::Exists($stderrPath)){[IO.File]::Delete($stderrPath)}}
    [pscustomobject][ordered]@{ExitCode=$exitCode;Stdout=($stdout -join "`n");Stderr=$stderr}
}

function New-CcodEngineAdapters {
    param(
        $State=(New-CcodEngineState),
        $Probe=(New-CcodEngineProbe),
        [object[]]$Processes=@(),
        [string]$StopOutcome='Stopped',
        $Events=$null,
        $Counters=$null
    )
    $stateValue=$State; $probeValue=$Probe; $processValues=@($Processes); $stopValue=$StopOutcome
    $eventsValue=$Events
    if($null -eq $eventsValue){$eventsValue=[Collections.Generic.List[string]]::new()}
    $counts=if($null -eq $Counters){[pscustomobject]@{ SpecialStart=0; OrdinaryStart=0; Recover=0; Node=0 }}else{$Counters}
    $active=[pscustomobject]@{ Stage='IntentWritten' }
    $snapshotFactory=${function:New-CcodEngineSnapshot}
    $fullBridgeFactory=${function:New-CcodFullBridgeInvocation}
    $rendererBridgeFactory=${function:New-CcodRendererBridgeInvocation}
    return @{
        ReadState={ param($StateRoot,$SuppressionKey) $stateValue }.GetNewClosure()
        StaticProbe={ param($NodeCandidates,$CheckerPath) $eventsValue.Add('StaticProbe'); $probeValue }.GetNewClosure()
        ListProcesses={ param($StatusEvidence) @($processValues) }.GetNewClosure()
        GetProcess={ param($Pid,$StatusEvidence) @($processValues | Where-Object { $_.Pid -eq $Pid } | Select-Object -First 1) }.GetNewClosure()
        ProcessMatch={ param($Expected,$Actual) $null -ne $Actual -and $Expected.Pid -eq $Actual.Pid -and $Expected.CreationTimeUtc -ceq $Actual.CreationTimeUtc -and $Expected.Mode -ceq $Actual.Mode }
        NewTransition={
            param($Path,$Source,$Package,$RuntimeId,$RendererPort,$MainPort,$TransactionId)
            $eventsValue.Add('IntentWritten'); $active.Stage='IntentWritten'
            [pscustomobject]@{ transactionId=$TransactionId; stage='IntentWritten'; sourcePid=if($Source){$Source.Pid}else{$null}; sourceCreationTimeUtc=if($Source){$Source.CreationTimeUtc}else{$null}; packageFullName=$Package.FullName; appAsarSha256=$Package.AppAsarSha256; runtimeId=$RuntimeId; mainPort=$MainPort; rendererPort=$RendererPort; specialPid=$null; specialCreationTimeUtc=$null; recoveryPid=$null; recoveryCreationTimeUtc=$null; createdAtUtc='2030-02-03T04:05:06.0000000Z'; updatedAtUtc='2030-02-03T04:05:06.0000000Z' }
        }.GetNewClosure()
        SetTransition={
            param($Path,$TransactionId,$ExpectedStage,$NewStage,$SpecialIdentity,$RecoveryIdentity,$RendererPort,$MainPort)
            $eventsValue.Add($NewStage); $active.Stage=$NewStage
            [pscustomobject]@{ transactionId=$TransactionId; stage=$NewStage; mainPort=$MainPort; rendererPort=$RendererPort; specialPid=if($SpecialIdentity){$SpecialIdentity.Pid}else{$null}; specialCreationTimeUtc=if($SpecialIdentity){$SpecialIdentity.CreationTimeUtc}else{$null}; recoveryPid=if($RecoveryIdentity){$RecoveryIdentity.Pid}else{$null}; recoveryCreationTimeUtc=if($RecoveryIdentity){$RecoveryIdentity.CreationTimeUtc}else{$null} }
        }.GetNewClosure()
        CompleteTransition={ param($Path,$LogPath,$TransactionId,$Disposition) $eventsValue.Add("Complete:$Disposition"); [pscustomobject]@{ Outcome='Completed' } }.GetNewClosure()
        StopProcess={
            param($Expected,$StatusEvidence,$TimeoutMilliseconds)
            $eventsValue.Add('StopProcess')
            [pscustomobject]@{ Outcome=$stopValue; StoppedByController=($stopValue -ceq 'Stopped'); Snapshot=if($stopValue -ceq 'SourceExited'){$null}else{$Expected} }
        }.GetNewClosure()
        GetPort={ param($Excluded) if(@($Excluded) -contains 41001){41002}else{41001} }
        StartSpecial={
            param($RendererPort,$MainPort,$TimeoutMilliseconds)
            $eventsValue.Add('StartSpecial'); $counts.SpecialStart++
            [pscustomobject]@{ Outcome='Started'; Snapshot=(& $snapshotFactory -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort $RendererPort -MainPort $MainPort); Process=[pscustomobject]@{Id=201} }
        }.GetNewClosure()
        InvokeNode={ param($NodePath,$Arguments) $eventsValue.Add('InvokeNode'); $counts.Node++; if((@($Arguments)-join ',') -cmatch '--mode,renderer(?:,|$)'){& $rendererBridgeFactory}else{& $fullBridgeFactory} }.GetNewClosure()
        WriteStatus={ param($StateRoot,$Status,$LiveProbe) $eventsValue.Add('WriteStatus') }.GetNewClosure()
        ReadVerified={ param($StateRoot) [pscustomobject]@{ schemaVersion=1; packages=[pscustomobject]@{} } }
        WriteVerified={ param($StateRoot,$Verified) $eventsValue.Add('WriteVerified') }.GetNewClosure()
        UtcNow={ [DateTime]::Parse('2030-02-03T04:06:00.0000000Z').ToUniversalTime() }
        GetTree={ param($Root,$StatusEvidence) @($Root) }
        WaitPortClosed={ param($Port,$TimeoutMilliseconds) $true }
        StartOrdinary={ param($TimeoutMilliseconds) $counts.OrdinaryStart++; [pscustomobject]@{ Outcome='Adopted'; Snapshot=(& $snapshotFactory -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z'); Process=$null } }.GetNewClosure()
        Delay={ param($Milliseconds) }
        CurrentIdentity={ [pscustomobject][ordered]@{SessionId='1';UserSid='S-1-5-21-test'} }
        Events=$eventsValue
        Counters=$counts
    }
}

function Assert-CcodEngineResultContract($Result,[string]$TransactionId,[string]$Message) {
    Assert-CcodEqual 'schemaVersion,action,ok,outcome,safeState,stage,transactionId,package,source,special,probes,recovery,error,logFile' (($Result.PSObject.Properties.Name) -join ',') "$Message exact 14 fields"
    Assert-CcodEqual $TransactionId $Result.transactionId "$Message request correlation"
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-engine-selftest-' + [guid]::NewGuid().ToString('N'))
try {
    $paths = New-CcodEnginePaths -Root $root

    Invoke-CcodTest 'exports exactly the six public SessionEngine functions' {
        Assert-CcodEqual 'Invoke-CcodApplySession,Invoke-CcodInspectSession,Invoke-CcodRecoverSession,Invoke-CcodRepairRenderer,Invoke-CcodReplayTransition,Test-CcodBridgeResult' `
            ((Get-Command -Module SessionEngine | Sort-Object Name | ForEach-Object Name) -join ',') 'public API remains exact'
    }

    Invoke-CcodTest 'strictly validates full and renderer bridge framing and proof' {
        $full = Test-CcodBridgeResult -Mode Full -Invocation (New-CcodFullBridgeInvocation)
        Assert-CcodEqual $true $full.ok 'full proof passes'
        $rendererProof = [ordered]@{ ok=$true; protocolVersion=1; renderer=[ordered]@{ targetUrl='app://-/index.html'; currentDocument=[ordered]@{installed=$true}; newDocumentScriptInstalled=$true; probe=[ordered]@{proof=$true;targetGate='782640499'} } }
        $renderer = Test-CcodBridgeResult -Mode Renderer -Invocation ([pscustomobject][ordered]@{ ExitCode=0; Stdout=($rendererProof|ConvertTo-Json -Depth 16 -Compress); Stderr='diagnostic' })
        Assert-CcodEqual $false ($null -ne $renderer.PSObject.Properties['main']) 'renderer proof forbids a main result'
        Assert-CcodThrows { Test-CcodBridgeResult -Mode Full -Invocation ([pscustomobject][ordered]@{ExitCode=0;Stdout='{} {}';Stderr=''}) } 'CCOD_BRIDGE_JSON_INVALID'
        foreach($invocation in @(
            [pscustomobject][ordered]@{ExitCode=0;Stdout='{"ok":true,"protocolVersion":1}';Stderr=''},
            [pscustomobject][ordered]@{ExitCode=1;Stdout='{}';Stderr='failed'}
        )) { Assert-CcodThrows { Test-CcodBridgeResult -Mode Full -Invocation $invocation } 'BRIDGE_PROOF_INCOMPLETE' }
        $wrongCode=New-CcodFullBridgeInvocation;$wrongObject=$wrongCode.Stdout|ConvertFrom-Json;$wrongObject.main.inspectorPortClosed.code='EOTHER';$wrongCode.Stdout=$wrongObject|ConvertTo-Json -Depth 16 -Compress
        Assert-CcodThrows {Test-CcodBridgeResult -Mode Full -Invocation $wrongCode} 'BRIDGE_PROOF_INCOMPLETE'
    }

    Invoke-CcodTest 'returns exact correlated results and rejects request or path coercion before adapters' {
        $request = New-CcodEngineRequest
        $before = $request | ConvertTo-Json -Depth 16 -Compress
        $result = Invoke-CcodInspectSession -Request $request -Paths $paths -Adapters (New-CcodEngineAdapters)
        Assert-CcodEngineResultContract $result $request.transactionId 'valid inspect'
        Assert-CcodEqual 'Inspected' $result.outcome 'valid no-process inspect is safe'
        Assert-CcodEqual 'NoCodex' $result.safeState 'no process remains a read-only fact'
        Assert-CcodEqual $before ($request | ConvertTo-Json -Depth 16 -Compress) 'request input is not mutated'

        $extra = New-CcodEngineRequest
        $extra | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        $invalid = Invoke-CcodInspectSession -Request $extra -Paths $paths -Adapters @{ ReadState={throw 'must not run'} }
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $invalid.error.code 'extra request field fails closed'
        Assert-CcodEngineResultContract $invalid $extra.transactionId 'invalid request'

        $poisoned=New-CcodEngineRequest;$poisoned.transactionId="C:\secret\device-key.json`n--token hunter2"
        $poisonedResult=Invoke-CcodInspectSession -Request $poisoned -Paths $paths -Adapters @{ReadState={throw 'must not run'}}
        Assert-CcodEqual $null $poisonedResult.transactionId 'a noncanonical transaction ID is never echoed from an invalid request'
        Assert-CcodTrue (($poisonedResult|ConvertTo-Json -Depth 16 -Compress) -cnotmatch 'secret|hunter2|device-key') 'invalid request metadata cannot bypass the fixed public error envelope'

        $badPaths = New-CcodEnginePaths -Root $root
        $badPaths.CheckerPath = 'relative\check-package.mjs'
        $pathFailure = Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $badPaths -Adapters @{ ReadState={throw 'must not run'} }
        Assert-CcodEqual 'CCOD_PATHS_INVALID' $pathFailure.error.code 'relative path fails before state or process adapters'

        $outsidePaths=New-CcodEnginePaths -Root $root;$outsidePaths.OrchestratorPath=[IO.Path]::GetFullPath((Join-Path $root 'outside\orchestrator.js'))
        $outsideFailure=Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $outsidePaths -Adapters @{ReadState={throw 'must not run'}}
        Assert-CcodEqual 'CCOD_PATHS_INVALID' $outsideFailure.error.code 'runtime payload outside the shared verified runtime root fails before adapters'

        $specialSource=New-CcodEngineSnapshot -Mode Special -RendererPort 41001 -MainPort 41002
        $sourceFailure=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $specialSource) -Paths $paths -Adapters @{ReadState={throw 'must not run'}}
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $sourceFailure.error.code 'Apply source must be an exact top-level ordinary snapshot'
        $samePorts=New-CcodEngineRequest -Action Apply -Source (New-CcodEngineSnapshot) -RendererPort 41001 -MainPort 41001
        $portFailure=Invoke-CcodApplySession -Request $samePorts -Paths $paths -Adapters @{ReadState={throw 'must not run'}}
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' $portFailure.error.code 'equal requested ports fail before source or journal adapters'
    }

    Invoke-CcodTest 'publishes fixed errors and writes only allowlisted bounded session diagnostics' {
        $secret="C:\secret\device-key.json`n--token hunter2`ncommand.exe --password=swordfish"
        $messages=[Collections.Generic.List[string]]::new()
        $result=Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $paths -Adapters @{
            ReadState={throw $secret}.GetNewClosure()
            WriteLog={param($Path,$Message)$messages.Add($Message);'incidental adapter output'}.GetNewClosure()
        }
        Assert-CcodTrue ($result -is [pscustomobject]) 'diagnostic adapter output never corrupts the one-result engine frame'
        Assert-CcodEqual 'CCOD_SESSION_FAILED' $result.error.code 'unknown adapter errors use the stable session code'
        Assert-CcodEqual 'The session operation failed safely. See the session log for details.' $result.error.message 'public error text is fixed and generic'
        Assert-CcodTrue ($result.error.message.Length -le 300) 'public error text remains bounded'
        Assert-CcodEqual $paths.SessionLogPath $result.logFile 'successful diagnostic persistence returns only the safe log reference'
        Assert-CcodEqual 1 $messages.Count 'one core failure writes one diagnostic record'
        Assert-CcodTrue ($messages[0] -cnotmatch 'secret|hunter2|swordfish|command\.exe|[\r\n]') 'diagnostic record excludes raw path command secret and multiline text'
        $record=$messages[0]|ConvertFrom-Json
        Assert-CcodEqual 'schemaVersion,timestampUtc,action,transactionId,stage,code' (($record.PSObject.Properties.Name)-join ',') 'diagnostic log uses the fixed allowlist'

        [IO.Directory]::CreateDirectory((Split-Path $paths.SessionLogPath -Parent))|Out-Null
        [IO.File]::WriteAllText($paths.SessionLogPath,('x'*(2MB+1)),[Text.UTF8Encoding]::new($false))
        $default=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TransactionId '9c2324b9-07a4-4ad3-9de5-c48dde73c713') -Paths $paths -Adapters @{ReadState={throw $secret}.GetNewClosure()}
        Assert-CcodEqual $paths.SessionLogPath $default.logFile 'default adapter writes the same safe session log reference'
        Assert-CcodTrue ((Get-Item -LiteralPath $paths.SessionLogPath).Length -lt 2MB) 'default rotating log replaces an unsafe oversized current file'
        $lines=@(Get-Content -LiteralPath $paths.SessionLogPath|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
        Assert-CcodEqual 1 $lines.Count 'default failure log contains one bounded JSONL record'
        Assert-CcodTrue ($lines[0] -cnotmatch 'secret|hunter2|swordfish|command\.exe') 'default rotating log is redacted by construction'
        Assert-CcodEqual $false (Test-Path -LiteralPath ($paths.SessionLogPath+'.11')) 'rotation never creates an eleventh history generation'
    }

    Invoke-CcodTest 'inspects ordinary validated special and renderer-broken identity without mutation' {
        $ordinary = New-CcodEngineSnapshot
        $ordinaryResult = Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($ordinary))
        Assert-CcodEqual 'OrdinaryRunning' $ordinaryResult.safeState 'ordinary root remains unchanged'
        Assert-CcodEqual 100 $ordinaryResult.source.pid 'ordinary identity is reduced safely'

        $status = [pscustomobject]@{ schemaVersion=1; session=[pscustomobject]@{ supervisorPid=11; supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z'; sessionId='1'; runtimeId='runtime-1'; sessionState='Active'; codex=[pscustomobject]@{ pid=201; creationTimeUtc='2030-02-03T04:05:07.0000000Z'; packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; packageVersion='1.0.0.0'; appAsarSha256=('a'*64); mainPort=41002; rendererPort=41001; mainProbe='Closed'; rendererProbe='BridgeValid' } } }
        $special = New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $specialResult = Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $paths -Adapters (New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($special))
        Assert-CcodEqual 'SpecialValidated' $specialResult.safeState 'only live validated special maps active'
        Assert-CcodEqual 201 $specialResult.special.pid 'special identity is reduced safely'

        $broken = New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $brokenResult = Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $paths -Adapters (New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($broken))
        Assert-CcodEqual 'RendererRepairRequired' $brokenResult.safeState 'persisted immutable special identity survives renderer probe damage'

        $otherSession=New-CcodEngineSnapshot;$otherSession.SessionId=2
        $ignored=Invoke-CcodInspectSession -Request (New-CcodEngineRequest) -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($otherSession))
        Assert-CcodEqual 'NoCodex' $ignored.safeState 'another Windows session is ignored even through an injected process adapter'
    }

    Invoke-CcodTest 'only the exact Stopped receipt authorizes special launch' {
        foreach($outcome in @('SourceExited','IdentityChanged','StopUnconfirmed')) {
            $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
            $source=New-CcodEngineSnapshot
            $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -ExistingOnly $true) -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($source) -StopOutcome $outcome -Counters $counters)
            Assert-CcodEqual 0 $counters.SpecialStart "$outcome never starts special"
            Assert-CcodTrue (@('NoAction','Error') -ccontains $result.outcome) "$outcome returns a non-activated outcome"
        }
    }

    Invoke-CcodTest 'applies the exact journal-before-external-action order and returns validated evidence' {
        $events=[Collections.Generic.List[string]]::new()
        $source=New-CcodEngineSnapshot
        $adapters=New-CcodEngineAdapters -Processes @($source) -Events $events
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -ExistingOnly $true) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'StaticProbe,IntentWritten,StopRequested,StopProcess,OrdinaryStopped,SpecialLaunchRequested,StartSpecial,SpecialStarted,InvokeNode,Validated,WriteStatus,WriteVerified,Complete:Activated' ($events -join ',') 'journal checkpoints precede each external action'
        Assert-CcodEqual 'Activated' $result.outcome 'successful apply is activated'
        Assert-CcodEqual 'SpecialValidated' $result.safeState 'successful apply requires full proof'
        Assert-CcodEqual $true $result.probes.main.inspectorPortClosed.confirmed 'main refusal evidence is retained'
        Assert-CcodEqual $true $result.probes.renderer.newDocumentScriptInstalled 'future renderer documents are covered'
        Assert-CcodEqual '782640499' $result.probes.renderer.probe.targetGate 'exact gate proof is retained'
        Assert-CcodTrue (($result.probes|ConvertTo-Json -Depth 16 -Compress) -cnotmatch 'payloadReport') 'raw main payload reports never enter the public result envelope'
        Assert-CcodEngineResultContract $result '5f496d99-c839-4458-a6a2-d37ea1afdbda' 'successful apply'
    }

    Invoke-CcodTest 'passes the exact request timeout through every real orchestrator parser child boundary' {
        $timeout=43210
        $source=New-CcodEngineSnapshot
        $applyAdapters=New-CcodEngineAdapters -Processes @($source)
        $applyArguments=[Collections.Generic.List[string]]::new()
        $applyAdapters.InvokeNode={param($NodePath,$Arguments)$applyArguments.Add(($Arguments -join ','));Invoke-CcodParserOnlyBridgeChild -Arguments @($Arguments)}.GetNewClosure()
        $apply=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -TimeoutMilliseconds $timeout) -Paths $paths -Adapters $applyAdapters

        $status=[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $repairAdapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($special)
        $repairArguments=[Collections.Generic.List[string]]::new()
        $repairAdapters.InvokeNode={param($NodePath,$Arguments)$repairArguments.Add(($Arguments -join ','));Invoke-CcodParserOnlyBridgeChild -Arguments @($Arguments)}.GetNewClosure()
        $repair=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer -TimeoutMilliseconds $timeout) -Paths $paths -Adapters $repairAdapters

        $replayAdapters=New-CcodEngineAdapters -Processes @($special)
        $replayArguments=[Collections.Generic.List[string]]::new()
        $replayAdapters.InvokeNode={param($NodePath,$Arguments)$replayArguments.Add(($Arguments -join ','));Invoke-CcodParserOnlyBridgeChild -Arguments @($Arguments)}.GetNewClosure()
        $replay=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TimeoutMilliseconds $timeout) -Paths $paths -Transition (New-CcodEngineTransition -Stage SpecialStarted -WithPorts -WithSpecial) -Adapters $replayAdapters

        Assert-CcodEqual 'Activated' $apply.outcome 'Apply real parser child accepts the full bridge command'
        Assert-CcodEqual 'NoAction' $repair.outcome 'Repair real parser child accepts the renderer command'
        Assert-CcodEqual 'NoAction' $replay.outcome 'replay real parser child accepts the renderer command'
        foreach($captured in @($applyArguments[0],$repairArguments[0],$replayArguments[0])){
            Assert-CcodTrue ($captured -cmatch "--timeout-ms,$timeout(?:,|$)") 'each bridge command carries the exact request timeout once'
            Assert-CcodEqual 1 ([regex]::Matches($captured,'(?:^|,)--timeout-ms(?:,|$)').Count) 'each bridge command contains one timeout option'
        }
    }

    Invoke-CcodTest 'accepts 120 seconds for the bridge while capping process-control calls at 60 seconds' {
        $source=New-CcodEngineSnapshot
        $captured=[pscustomobject]@{Stop=$null;Start=$null;Bridge=$null}
        $adapters=New-CcodEngineAdapters -Processes @($source)
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$captured.Stop=$TimeoutMilliseconds;[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $adapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)$captured.Start=$TimeoutMilliseconds;[pscustomobject]@{Outcome='Started';Snapshot=(New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort $RendererPort -MainPort $MainPort);Process=[pscustomobject]@{Id=201}}}.GetNewClosure()
        $adapters.InvokeNode={param($NodePath,$Arguments)$captured.Bridge=@($Arguments);Invoke-CcodParserOnlyBridgeChild -Arguments @($Arguments)}.GetNewClosure()
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -TimeoutMilliseconds 120000) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Activated' $result.outcome '120-second public timeout reaches a valid bridge result'
        Assert-CcodEqual 60000 $captured.Stop 'source stop stays inside the ProcessControl 60000ms API limit'
        Assert-CcodEqual 60000 $captured.Start 'special start stays inside the ProcessControl 60000ms API limit'
        Assert-CcodTrue (($captured.Bridge -join ',') -cmatch '--timeout-ms,120000(?:,|$)') 'bridge receives the full 120-second value'

        $tooLarge=Invoke-CcodInspectSession -Request (New-CcodEngineRequest -TimeoutMilliseconds 120000) -Paths $paths -Adapters (New-CcodEngineAdapters)
        Assert-CcodEqual 'Inspected' $tooLarge.outcome '120000 is accepted by the shared request contract'
        $invalid=New-CcodEngineRequest;$invalid.timeoutMilliseconds=120001
        Assert-CcodEqual 'CCOD_REQUEST_INVALID' (Invoke-CcodInspectSession -Request $invalid -Paths $paths -Adapters @{ReadState={throw 'must not run'}}).error.code '120001 is rejected before adapters'
    }

    Invoke-CcodTest 'discovers one existing ordinary source and rejects manual Start root ambiguity' {
        $ordinary=New-CcodEngineSnapshot
        $events=[Collections.Generic.List[string]]::new();$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $adapters=New-CcodEngineAdapters -Processes @($ordinary) -Events $events -Counters $counters
        $activated=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -ExistingOnly $false) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Activated' $activated.outcome 'one existing ordinary root converts to special'
        Assert-CcodEqual 100 $activated.source.pid 'the discovered ordinary identity is retained in the result'
        Assert-CcodTrue (($events -join ',') -cmatch 'IntentWritten,StopRequested,StopProcess,OrdinaryStopped') 'discovered ordinary root is journaled and exactly stopped before launch'

        $second=New-CcodEngineSnapshot -Pid 101 -CreationTimeUtc '2030-02-03T04:00:01.0000000Z'
        $multipleCounters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $multiple=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -ExistingOnly $false -TransactionId '30fc56b0-547b-4b60-996a-d82b7301384c') -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($ordinary,$second) -Counters $multipleCounters)
        Assert-CcodEqual 'CCOD_SOURCE_AMBIGUOUS' $multiple.error.code 'multiple ordinary roots cannot be silently reduced to source null'
        Assert-CcodEqual 0 $multipleCounters.SpecialStart 'ambiguous ordinary roots never start special'

        $debug=New-CcodEngineSnapshot -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $debugCounters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $ambiguous=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -ExistingOnly $false -TransactionId 'b56470ad-948a-4df7-b5f2-04a4df86a256') -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($debug) -Counters $debugCounters)
        Assert-CcodEqual 'CCOD_SOURCE_AMBIGUOUS' $ambiguous.error.code 'an existing debug root cannot be treated as a closed app'
        Assert-CcodEqual 0 $debugCounters.SpecialStart 'debug ambiguity never starts another special root'

        $foreignSessionCounters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $foreignSessionAdapters=New-CcodEngineAdapters -Processes @() -Counters $foreignSessionCounters
        $foreignSessionAdapters.CurrentIdentity={[pscustomobject][ordered]@{SessionId='2';UserSid='S-1-5-21-test'}}
        $foreignSession=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -ExistingOnly $false -TransactionId '6e053d2c-80a3-4d47-8a43-9d238f0d84b1') -Paths $paths -Adapters $foreignSessionAdapters
        Assert-CcodEqual 'CCOD_SOURCE_AMBIGUOUS' $foreignSession.error.code 'manual Start cannot target a supervisor identity from another Windows session'
        Assert-CcodEqual 0 $foreignSessionCounters.SpecialStart 'session identity mismatch never starts special'

        $foreignSource=New-CcodEngineSnapshot;$foreignSource.SessionId=2
        $foreignSourceCounters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $foreignSourceResult=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $foreignSource -TransactionId '5a543a32-a62e-4e61-ae43-f290080c83d9') -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($foreignSource) -Counters $foreignSourceCounters)
        Assert-CcodEqual 'CCOD_SOURCE_CHANGED' $foreignSourceResult.error.code 'an explicit source must belong to the current supervisor session and user'
        Assert-CcodEqual 0 $foreignSourceCounters.SpecialStart 'foreign-session explicit source is never stopped or replaced'
    }

    Invoke-CcodTest 'rejects damaged status before old verified history can authorize Apply' {
        $state=New-CcodEngineState
        $state.StatusRebuildRequired=$true
        $state.AutomaticCandidateTrialsAllowed=$false
        $key='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|'+('a'*64)+'|runtime-1'
        $record=[pscustomobject]@{packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);runtimeId='runtime-1';staticClassification='CandidateCompatible';dynamicOutcome='Succeeded';probeState='Valid';confirmedAtUtc='2030-02-03T04:06:00.0000000Z'}
        $state.VerifiedPackages=[pscustomobject]@{schemaVersion=1;packages=[pscustomobject]@{$key=$record}}
        $events=[Collections.Generic.List[string]]::new();$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -ExistingOnly $false) -Paths $paths -Adapters (New-CcodEngineAdapters -State $state -Events $events -Counters $counters)
        Assert-CcodEqual 'CCOD_STATE_BLOCKED' $result.error.code 'status rebuild is a hard Apply gate even with a historical success'
        Assert-CcodEqual 0 $counters.SpecialStart 'damaged status blocks process actions'
        Assert-CcodTrue (($events -join ',') -cnotmatch 'IntentWritten') 'damaged status blocks journal creation'
    }

    Invoke-CcodTest 'recovers exactly once after each representative post-stop failure and records suppression' {
        foreach($failure in @('Port','Start','Bridge','Status','History')) {
            $events=[Collections.Generic.List[string]]::new();$source=New-CcodEngineSnapshot
            $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0;PortChecks=0;DelayedMs=0}
            $adapters=New-CcodEngineAdapters -Processes @($source) -Events $events -Counters $counters
            $adapters.ListProcesses={ param($StatusEvidence) @() }
            $adapters.Delay={param($Milliseconds)$counters.DelayedMs+=$Milliseconds}.GetNewClosure()
            $baseSet=$adapters.SetTransition
            $adapters.SetTransition={param($Path,$TransactionId,$ExpectedStage,$NewStage,$SpecialIdentity,$RecoveryIdentity,$RendererPort,$MainPort)if($NewStage -ceq 'RecoveryLaunchRequested'){$counters.Recover++};& $baseSet $Path $TransactionId $ExpectedStage $NewStage $SpecialIdentity $RecoveryIdentity $RendererPort $MainPort}.GetNewClosure()
            $baseWait=$adapters.WaitPortClosed
            $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$counters.PortChecks++;& $baseWait $Port $TimeoutMilliseconds}.GetNewClosure()
            switch($failure){
                'Port' {$adapters.GetPort={param($Excluded)$null}}
                'Start' {$adapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)$counters.SpecialStart++;[pscustomobject]@{Outcome='Failed';Snapshot=$null;Process=$null}}.GetNewClosure()}
                'Bridge' {$adapters.InvokeNode={param($NodePath,$Arguments)$counters.Node++;[pscustomobject][ordered]@{ExitCode=0;Stdout='{}';Stderr=''}}.GetNewClosure()}
                'Status' {$writeCounter=[pscustomobject]@{Count=0};$adapters.WriteStatus={param($StateRoot,$Status,$LiveProbe)$writeCounter.Count++;if($writeCounter.Count -eq 1){throw 'status write failed'};$events.Add('WriteStatus')}.GetNewClosure()}
                'History' {$writeCounter=[pscustomobject]@{Count=0};$adapters.WriteVerified={param($StateRoot,$Verified)$writeCounter.Count++;if($writeCounter.Count -eq 1){throw 'history write failed'};$events.Add('WriteVerified')}.GetNewClosure()}
            }
            $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source) -Paths $paths -Adapters $adapters
            Assert-CcodEqual 1 $counters.Recover "$failure enters Recover exactly once"
            Assert-CcodEqual 1 $counters.OrdinaryStart "$failure launches ordinary at most once after its five-second observation"
            Assert-CcodEqual 'Recovered' $result.outcome "$failure returns a proven recovered outcome"
            Assert-CcodTrue (-not [string]::IsNullOrWhiteSpace($result.recovery.suppressionKey)) "$failure returns the durable suppression key"
            if($failure -ceq 'Start'){Assert-CcodEqual 2 $counters.PortChecks 'recorded launch ports are proven refused even when no special PID was committed'}
        }
    }

    Invoke-CcodTest 'recovers an exact special tree child-to-parent and never stops unrelated or PID-reused members' {
        $source=New-CcodEngineSnapshot
        $rootSpecial=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $child=New-CcodEngineSnapshot -Pid 202 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -ParentPid 201 -RendererPort 41001 -MainPort 41002 -IsTopLevel $false
        $unrelated=New-CcodEngineSnapshot -Pid 999 -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $stopped=[Collections.Generic.List[int]]::new();$adapters=New-CcodEngineAdapters -Processes @($source)
        $adapters.InvokeNode={param($NodePath,$Arguments)throw 'bridge failed'}
        $adapters.ListProcesses={param($StatusEvidence)@()}
        $adapters.GetTree={param($Root,$StatusEvidence)@($rootSpecial,$child)}.GetNewClosure()
        $adapters.GetProcess={param($ProcessId,$StatusEvidence)switch($ProcessId){201{$rootSpecial}202{$child}999{$unrelated}default{$source}}}.GetNewClosure()
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$stopped.Add([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $result=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source) -Paths $paths -Adapters $adapters
        Assert-CcodEqual '100,202,201' ($stopped -join ',') 'ordinary source stops first and only the verified special tree is then stopped child before parent'
        Assert-CcodEqual 'Recovered' $result.outcome 'exact tree stop proceeds to ordinary recovery'

        $stopped.Clear();$reused=New-CcodEngineSnapshot -Pid 202 -CreationTimeUtc '2030-02-03T04:06:08.0000000Z' -Mode Unrelated -ParentPid 201 -RendererPort 41001 -MainPort 41002 -IsTopLevel $false
        $adapters.GetProcess={param($ProcessId,$StatusEvidence)if($ProcessId -eq 202){$reused}elseif($ProcessId -eq 201){$rootSpecial}else{$source}}.GetNewClosure()
        $unsafe=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -TransactionId '616a0ad7-27fe-4d08-8556-b5cc7c2bd0b3') -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Error' $unsafe.outcome 'PID reuse makes recovery unsafe'
        Assert-CcodEqual '100' ($stopped -join ',') 'after the authorized source stop no special member is stopped following a child identity mismatch'
    }

    Invoke-CcodTest 'uses fake five-second recovery observation before adoption or one launch' {
        $source=New-CcodEngineSnapshot;$ordinary=New-CcodEngineSnapshot -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z'
        $clock=[pscustomobject]@{Delayed=0;Polls=0};$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $adapters=New-CcodEngineAdapters -Processes @($source) -Counters $counters
        $adapters.StartSpecial={param($RendererPort,$MainPort,$TimeoutMilliseconds)[pscustomobject]@{Outcome='Failed';Snapshot=$null;Process=$null}}
        $adapters.Delay={param($Milliseconds)$clock.Delayed+=$Milliseconds}.GetNewClosure()
        $adapters.ListProcesses={param($StatusEvidence)$clock.Polls++;if($clock.Polls -ge 4){@($ordinary)}else{@()}}.GetNewClosure()
        $adopted=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 3000 $clock.Delayed 'ordinary appearing in the fourth poll is adopted after three fake seconds'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'adoption avoids an ordinary launch'
        Assert-CcodEqual 301 $adopted.recovery.pid 'adoption returns the exact ordinary snapshot'

        $clock.Delayed=0;$adapters.ListProcesses={param($StatusEvidence)@()};$launched=Invoke-CcodApplySession -Request (New-CcodEngineRequest -Action Apply -Source $source -TransactionId '7db414e1-54f3-49a5-b11f-a8a2c266df00') -Paths $paths -Adapters $adapters
        Assert-CcodEqual 5000 $clock.Delayed 'launch occurs only after the full fake five-second absence window'
        Assert-CcodEqual 1 $counters.OrdinaryStart 'ordinary is launched exactly once'
        Assert-CcodEqual 301 $launched.recovery.pid 'launch receipt exact snapshot is journaled'
    }

    Invoke-CcodTest 'replays every normal stage without ever starting special and preserves request correlation' {
        $source=New-CcodEngineSnapshot;$special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        foreach($case in @(
            @{Stage='IntentWritten';Transition=(New-CcodEngineTransition -Stage IntentWritten);Processes=@($source);Expected='NoAction'},
            @{Stage='StopRequested';Transition=(New-CcodEngineTransition -Stage StopRequested);Processes=@($source);Expected='NoAction'},
            @{Stage='OrdinaryStopped';Transition=(New-CcodEngineTransition -Stage OrdinaryStopped);Processes=@();Expected='Recovered'},
            @{Stage='SpecialLaunchRequested';Transition=(New-CcodEngineTransition -Stage SpecialLaunchRequested -WithPorts);Processes=@();Expected='Recovered'},
            @{Stage='SpecialStarted';Transition=(New-CcodEngineTransition -Stage SpecialStarted -WithPorts -WithSpecial);Processes=@($special);Expected='NoAction'},
            @{Stage='Validated';Transition=(New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial);Processes=@($special);Expected='NoAction'},
            @{Stage='RecoveryLaunchRequested';Transition=(New-CcodEngineTransition -Stage RecoveryLaunchRequested -WithPorts -WithSpecial);Processes=@();Expected='Recovered'},
            @{Stage='Recovered';Transition=(New-CcodEngineTransition -Stage Recovered -WithPorts -WithSpecial -WithRecovery);Processes=@((New-CcodEngineSnapshot -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z'));Expected='Recovered'}
        )){
            $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$clock=[pscustomobject]@{Delayed=0}
            $events=[Collections.Generic.List[string]]::new();$adapters=New-CcodEngineAdapters -Processes $case.Processes -Counters $counters -Events $events
            $adapters.Delay={param($Milliseconds)$clock.Delayed+=$Milliseconds}.GetNewClosure()
            $adapters.ObserveSpecial={param($Transition,$Paths,$TimeoutMilliseconds)
                if($case.Stage -in @('SpecialStarted','Validated')){[pscustomobject]@{Outcome='Confirmed';Snapshot=$special;Candidates=@($special);ConflictOwners=@();Validation='Valid'}}
                else{[pscustomobject]@{Outcome='NoCandidate';Snapshot=$null;Candidates=@();ConflictOwners=@();Validation='Indeterminate'}}
            }.GetNewClosure()
            $request=New-CcodEngineRequest -Action Recover -TransactionId 'a8f08753-4e7a-4466-880a-ae4fcc3b9c59'
            $result=Invoke-CcodReplayTransition -Request $request -Paths $paths -Transition $case.Transition -Adapters $adapters
            Assert-CcodEqual $case.Expected $result.outcome "$($case.Stage) replay reaches its safe expected outcome"
            Assert-CcodEqual $request.transactionId $result.transactionId "$($case.Stage) replay result keeps request correlation, not the older journal ID"
            Assert-CcodEqual 0 $counters.SpecialStart "$($case.Stage) replay never starts special"
        }
    }

    Invoke-CcodTest 'advances each proven activation crash window through Validated before Activated completion' {
        $candidate=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        foreach($case in @(
            [pscustomobject]@{Name='AfterPid';Transition=(New-CcodEngineTransition -Stage SpecialLaunchRequested -WithPorts);MainClosed=$false;ExpectedMode='full';State=(New-CcodEngineState)},
            [pscustomobject]@{Name='SpecialStartedMainOpen';Transition=(New-CcodEngineTransition -Stage SpecialStarted -WithPorts -WithSpecial);MainClosed=$false;ExpectedMode='full';State=(New-CcodEngineState)},
            [pscustomobject]@{Name='SpecialStartedMainRefused';Transition=(New-CcodEngineTransition -Stage SpecialStarted -WithPorts -WithSpecial);MainClosed=$true;ExpectedMode='renderer';State=(New-CcodEngineState)},
            [pscustomobject]@{Name='AfterValidated';Transition=(New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial);MainClosed=$true;ExpectedMode='renderer';State=(New-CcodEngineState)},
            [pscustomobject]@{Name='AfterStatus';Transition=(New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial);MainClosed=$true;ExpectedMode='renderer';State=(New-CcodEngineState -Status (New-CcodEngineActiveStatus))},
            [pscustomobject]@{Name='AfterHistory';Transition=(New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial);MainClosed=$true;ExpectedMode='renderer';State=(New-CcodEngineState -Status (New-CcodEngineActiveStatus))},
            [pscustomobject]@{Name='AfterCompletion';Transition=(New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial);MainClosed=$true;ExpectedMode='renderer';State=(New-CcodEngineState -Status (New-CcodEngineActiveStatus))}
        )){
            if($case.Name -ceq 'AfterHistory'){
                $key='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|'+('a'*64)+'|runtime-1'
                $case.State.VerifiedPackages=[pscustomobject]@{schemaVersion=1;packages=[pscustomobject]@{$key=[pscustomobject]@{packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);runtimeId='runtime-1';staticClassification='CandidateCompatible';dynamicOutcome='Succeeded';probeState='Valid';confirmedAtUtc='2030-02-03T04:06:00.0000000Z'}}}
            }
            $events=[Collections.Generic.List[string]]::new();$captured=[pscustomobject]@{Arguments=$null};$adapters=New-CcodEngineAdapters -State $case.State -Processes @($candidate) -Events $events
            $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)[bool]$case.MainClosed}.GetNewClosure()
            $adapters.InvokeNode={param($NodePath,$Arguments)$captured.Arguments=@($Arguments);Invoke-CcodParserOnlyBridgeChild -Arguments @($Arguments)}.GetNewClosure()
            if($case.Transition.stage -ceq 'SpecialLaunchRequested'){$adapters.ObserveSpecial={param($Transition,$Paths,$TimeoutMilliseconds)[pscustomobject]@{Outcome='Confirmed';Snapshot=$candidate;Candidates=@($candidate);ConflictOwners=@();Validation='Indeterminate'}}.GetNewClosure()}
            if($case.Name -ceq 'AfterCompletion'){$adapters.CompleteTransition={param($Path,$LogPath,$TransactionId,$Disposition)$events.Add("Complete:$Disposition");[pscustomobject]@{Outcome='AlreadyCompleted'}}.GetNewClosure()}
            $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover) -Paths $paths -Transition $case.Transition -Adapters $adapters
            Assert-CcodEqual 'NoAction' $result.outcome "$($case.Name) re-establishes validated special state"
            Assert-CcodEqual 'SpecialValidated' $result.safeState "$($case.Name) never reports Active without proof"
            Assert-CcodTrue (($captured.Arguments -join ',') -cmatch "--mode,$($case.ExpectedMode)(?:,|$)") "$($case.Name) uses the stage-appropriate bridge mode"
            Assert-CcodTrue (($events -join ',') -cmatch 'WriteStatus,WriteVerified,Complete:Activated$') "$($case.Name) rebuilds status/history before completion"
            if($case.Transition.stage -ceq 'SpecialLaunchRequested'){Assert-CcodTrue (($events -join ',') -cmatch 'SpecialStarted,Validated,WriteStatus') 'after-PID replay durably records both missing stages before Active status'}
            if($case.Transition.stage -ceq 'SpecialStarted'){Assert-CcodTrue (($events -join ',') -cmatch 'Validated,WriteStatus') "$($case.Name) records Validated before Active status"}
        }
    }

    Invoke-CcodTest 'binds replay to the exact journal runtime package name and asar hash before side effects' {
        foreach($field in @('runtimeId','packageFullName','appAsarSha256')){
            $transition=New-CcodEngineTransition -Stage Validated -WithPorts -WithSpecial
            switch($field){'runtimeId'{$transition.runtimeId='runtime-old'};'packageFullName'{$transition.packageFullName='OpenAI.Codex_0.9.0.0_x64__2p2nqsd0c76g0'};'appAsarSha256'{$transition.appAsarSha256=('b'*64)}}
            $candidate=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
            $events=[Collections.Generic.List[string]]::new();$counts=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
            $adapters=New-CcodEngineAdapters -Processes @($candidate) -Events $events -Counters $counts
            $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$true}
            $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Transition $transition -Adapters $adapters
            Assert-CcodEqual 'CCOD_RECOVERY_UNPROVEN' $result.error.code "$field mismatch fails closed before replay activity"
            Assert-CcodEqual 0 $counts.Node "$field mismatch invokes no bridge child"
            Assert-CcodTrue (($events -join ',') -cnotmatch 'Validated|WriteStatus|WriteVerified|Complete:') "$field mismatch performs no journal status history or completion write"
        }
    }

    Invoke-CcodTest 'replays Recovered side effects idempotently and never archives it as Cancelled' {
        $ordinary=New-CcodEngineSnapshot -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z'
        $transition=New-CcodEngineTransition -Stage Recovered -WithPorts -WithSpecial -WithRecovery
        $events=[Collections.Generic.List[string]]::new();$adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status (New-CcodEngineActiveStatus)) -Processes @($ordinary) -Events $events
        $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TransactionId 'a8f08753-4e7a-4466-880a-ae4fcc3b9c59') -Paths $paths -Transition $transition -Adapters $adapters
        Assert-CcodEqual 'Recovered' $result.outcome 'Recovered replay adopts the journaled ordinary root'
        Assert-CcodEqual 'WriteStatus,WriteVerified,Complete:Recovered' (($events|Where-Object{$_ -in @('WriteStatus','WriteVerified','Complete:Recovered')}) -join ',') 'Recovered replay finishes all idempotent side effects before archival'
        Assert-CcodTrue (-not [string]::IsNullOrWhiteSpace($result.recovery.ignoreKey)) 'Recovered replay returns the durable ignore key'
        Assert-CcodTrue (-not [string]::IsNullOrWhiteSpace($result.recovery.suppressionKey)) 'Recovered replay returns the suppression key'
        Assert-CcodEqual $transition.transactionId $result.recovery.priorTransactionId 'Recovered replay side effects correlate to the journal transaction'

        $missingEvents=[Collections.Generic.List[string]]::new();$missing=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TransactionId 'd28e874b-9cb3-4d1e-8fc5-4a9abc2334f9') -Paths $paths -Transition $transition -Adapters (New-CcodEngineAdapters -Processes @() -Events $missingEvents)
        Assert-CcodEqual 'Error' $missing.outcome 'missing Recovered identity remains unproven'
        Assert-CcodTrue (($missingEvents -join ',') -cnotmatch 'Complete:Cancelled') 'Recovered is never archived with the Cancelled disposition'
    }

    Invoke-CcodTest 'uses exact fake primary five seconds plus guard five seconds for StopRequested' {
        $source=New-CcodEngineSnapshot;$clock=[pscustomobject]@{Delayed=0};$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $adapters=New-CcodEngineAdapters -Processes @($source) -Counters $counters
        $adapters.Delay={param($Milliseconds)$clock.Delayed+=$Milliseconds}.GetNewClosure()
        $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover) -Paths $paths -Transition (New-CcodEngineTransition -Stage StopRequested) -Adapters $adapters
        Assert-CcodEqual 10000 $clock.Delayed 'unchanged source receives primary 5 seconds and independent guard 5 seconds'
        Assert-CcodEqual 'NoAction' $result.outcome 'same live source is kept after both windows'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'guard completion does not launch recovery ordinary'
        Assert-CcodEqual 0 $counters.SpecialStart 'stop replay never starts special'
    }

    Invoke-CcodTest 'durably closes current special or ordinary trees without any ordinary restart' {
        foreach($mode in @('Special','Ordinary')){
            $source=New-CcodEngineSnapshot
            $rootProcess=if($mode -ceq 'Special'){New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002}else{$source}
            $child=New-CcodEngineSnapshot -Pid ($rootProcess.Pid+1) -CreationTimeUtc '2030-02-03T04:05:08.0000000Z' -Mode Unrelated -ParentPid $rootProcess.Pid -RendererPort $rootProcess.RendererPort -MainPort $rootProcess.MainPort -IsTopLevel $false
            $status=if($mode -ceq 'Special'){[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}}else{[pscustomobject]@{schemaVersion=1;session=$null}}
            $events=[Collections.Generic.List[string]]::new();$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$alive=@{}
            $alive[[int]$rootProcess.Pid]=$rootProcess;$alive[[int]$child.Pid]=$child
            $adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($rootProcess) -Events $events -Counters $counters
            $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure()
            $adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure()
            $adapters.GetTree={param($Root,$StatusEvidence)@($rootProcess,$child)}.GetNewClosure()
            $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$events.Add("Stop:$($Expected.Pid)");$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
            $result=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false) -Paths $paths -Adapters $adapters
            Assert-CcodEqual 'Closed' $result.outcome "$mode close reaches durable Closed"
            Assert-CcodEqual 'Closed' $result.safeState "$mode close reports the explicit closed safe state"
            Assert-CcodTrue (($events -join ',') -cmatch 'IntentWritten,CloseRequested,Stop:') "$mode commits CloseRequested before the first external stop"
            Assert-CcodEqual "Stop:$($child.Pid),Stop:$($rootProcess.Pid)" ((@($events|Where-Object{$_ -like 'Stop:*'})) -join ',') "$mode close stops child before root"
            Assert-CcodTrue (($events -join ',') -cmatch 'Closed,WriteStatus,Complete:Closed$') "$mode commits Closed then clears status and archives"
            Assert-CcodEqual 0 $counters.OrdinaryStart "$mode close never starts ordinary"
        }
    }

    Invoke-CcodTest 'closes an already empty session and leaves unsafe close evidence durable' {
        $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$adapters=New-CcodEngineAdapters -Processes @() -Counters $counters
        $empty=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Closed' $empty.outcome 'no current Codex is already closed without inventing a target transaction'

        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $status=[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
        $events=[Collections.Generic.List[string]]::new();$unsafeAdapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($special) -Events $events -Counters $counters
        $unsafeAdapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        $unsafeAdapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$false}
        $unsafe=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false -TransactionId 'd2cb8a7d-c7b3-4c1c-8a33-f627bb03b927') -Paths $paths -Adapters $unsafeAdapters
        Assert-CcodEqual 'Error' $unsafe.outcome 'open or indeterminate recorded port prevents Closed'
        Assert-CcodTrue (($events -join ',') -cmatch 'CloseRequested') 'unsafe close retains the durable CloseRequested checkpoint'
        Assert-CcodTrue (($events -join ',') -cnotmatch 'Complete:Closed') 'unsafe close is not archived as complete'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'unsafe close never falls into ordinary recovery'
    }

    Invoke-CcodTest 'owns one status-less debug root for close and rejects open ambiguous or unproven roots' {
        $debug=New-CcodEngineSnapshot -Mode Unrelated -RendererPort 41001 -MainPort 41002;$alive=@{100=$debug};$events=[Collections.Generic.List[string]]::new();$stops=[Collections.Generic.List[int]]::new()
        $counts=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$adapters=New-CcodEngineAdapters -Processes @($debug) -Events $events -Counters $counts
        $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$stops.Add([int]$Expected.Pid);$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure();$adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$true}
        $closed=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Closed' $closed.outcome 'one exact status-less debug root is durably close-owned'
        Assert-CcodEqual '100' ($stops -join ',') 'status-less debug root is actually stopped before Closed'
        Assert-CcodTrue (($events -join ',') -cmatch 'IntentWritten,CloseRequested,Closed') 'debug root close uses durable close checkpoints'

        $openDebug=New-CcodEngineSnapshot -Mode Unrelated -RendererPort 41001 -MainPort 41002;$openAlive=@{100=$openDebug};$openAdapters=New-CcodEngineAdapters -Processes @($openDebug) -Counters $counts
        $openAdapters.ListProcesses={param($StatusEvidence)@($openAlive.Values)}.GetNewClosure();$openAdapters.GetProcess={param($ProcessId,$StatusEvidence)if($openAlive.ContainsKey([int]$ProcessId)){$openAlive[[int]$ProcessId]}else{$null}}.GetNewClosure();$openAdapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        $openAdapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$openAlive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure();$openAdapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$false}
        $open=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false -TransactionId '9c2324b9-07a4-4ad3-9de5-c48dde73c713') -Paths $paths -Adapters $openAdapters
        Assert-CcodEqual 'CCOD_CLOSE_UNPROVEN' $open.error.code 'open debug ports prevent a false Closed result'

        $second=New-CcodEngineSnapshot -Pid 101 -CreationTimeUtc '2030-02-03T04:00:01.0000000Z' -Mode Unrelated -RendererPort 41003 -MainPort 41004
        $multiStops=[pscustomobject]@{Count=0};$multiAdapters=New-CcodEngineAdapters -Processes @($debug,$second) -Counters $counts;$multiAdapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$multiStops.Count++;throw 'must not stop'}.GetNewClosure()
        $multiple=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false -TransactionId 'bb31007a-54c8-49bb-9302-fab21e2b69e8') -Paths $paths -Adapters $multiAdapters
        Assert-CcodEqual 'CCOD_CLOSE_UNPROVEN' $multiple.error.code 'multiple current-package roots are never reduced to one close target'
        Assert-CcodEqual 0 $multiStops.Count 'ambiguous roots are not stopped'

        $unpaired=New-CcodEngineSnapshot -Mode Unrelated;$unpaired.RendererPort=41001
        $unproven=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -RestartOrdinary $false -TransactionId '4658e91c-30a5-447f-8654-24264f90076e') -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($unpaired) -Counters $counts)
        Assert-CcodEqual 'CCOD_CLOSE_UNPROVEN' $unproven.error.code 'a debug root without a valid distinct port pair is not close-owned'
    }

    Invoke-CcodTest 'never starts ordinary while a status-less debug root remains' {
        $debug=New-CcodEngineSnapshot -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $counts=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $result=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover) -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($debug) -Counters $counts)
        Assert-CcodEqual 'CCOD_RECOVERY_UNPROVEN' $result.error.code 'normal recovery refuses to coexist with an unowned debug root'
        Assert-CcodEqual 0 $counts.OrdinaryStart 'ordinary is not started beside a debug root'
    }

    Invoke-CcodTest 'suppresses cold missing-root close replay but completes a retained exact live tree' {
        $request=New-CcodEngineRequest -Action Recover -RestartOrdinary $false
        $cold=New-CcodEngineTransition -Stage CloseRequested -WithPorts -WithSpecial -Manual
        $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$adapters=New-CcodEngineAdapters -Processes @() -Counters $counters
        $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$true}
        $coldResult=Invoke-CcodReplayTransition -Request $request -Paths $paths -Transition $cold -Adapters $adapters
        Assert-CcodEqual 'Error' $coldResult.outcome 'cold replay with already-missing root stays indeterminate even when both ports refuse'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'cold close replay never starts ordinary'

        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Special -RendererPort 41001 -MainPort 41002
        $alive=@{201=$special};$events=[Collections.Generic.List[string]]::new();$liveAdapters=New-CcodEngineAdapters -Processes @($special) -Events $events -Counters $counters
        $liveAdapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$liveAdapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure()
        $liveAdapters.GetTree={param($Root,$StatusEvidence)@($Root)};$liveAdapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure();$liveAdapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$true}
        $live=Invoke-CcodReplayTransition -Request $request -Paths $paths -Transition $cold -Adapters $liveAdapters
        Assert-CcodEqual 'Closed' $live.outcome 'same-execution retained exact tree can prove absence and complete close'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'live close replay still never starts ordinary'

        $closed=New-CcodEngineTransition -Stage Closed -WithPorts -WithSpecial -Manual;$closed.runtimeId='runtime-old';$closed.appAsarSha256=('b'*64)
        $terminalAdapters=New-CcodEngineAdapters -Processes @() -Counters $counters
        $terminalAdapters.StaticProbe={throw 'terminal Closed replay must not require current package or Node evidence'}
        $terminal=Invoke-CcodReplayTransition -Request $request -Paths $paths -Transition $closed -Adapters $terminalAdapters
        Assert-CcodEqual 'Closed' $terminal.outcome 'Closed replay performs archival only without requiring a live tree again'
    }

    Invoke-CcodTest 'rejects durable close replay from a different current Windows session before stop' {
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $alive=@{201=$special};$stops=[pscustomobject]@{Count=0};$adapters=New-CcodEngineAdapters -Processes @($special)
        $adapters.CurrentIdentity={[pscustomobject][ordered]@{SessionId='2';UserSid='S-1-5-21-test'}}
        $adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$stops.Count++;throw 'must not stop across sessions'}.GetNewClosure()
        $result=Invoke-CcodReplayTransition -Request (New-CcodEngineRequest -Action Recover -TransactionId 'f14a0fad-6b37-4614-8be2-d38e16b9c030') -Paths $paths -Transition (New-CcodEngineTransition -Stage CloseRequested -WithPorts -WithSpecial -Manual) -Adapters $adapters
        Assert-CcodEqual 'CCOD_RECOVERY_UNPROVEN' $result.error.code 'close replay requires the current controller session to match the request supervisor'
        Assert-CcodEqual 0 $stops.Count 'cross-session close replay performs no process action'
    }

    Invoke-CcodTest 'finishes an older recovery before creating a separate DoNotRestart close transaction' {
        $old=New-CcodEngineTransition -Stage Recovered -WithRecovery;$ordinary=New-CcodEngineSnapshot -Pid 301 -CreationTimeUtc '2030-02-03T04:06:01.0000000Z';$alive=@{301=$ordinary}
        $withOld=New-CcodEngineState -ActiveTransaction $old;$withoutOld=New-CcodEngineState;$reads=[pscustomobject]@{Count=0};$events=[Collections.Generic.List[string]]::new();$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $adapters=New-CcodEngineAdapters -State $withOld -Processes @($ordinary) -Events $events -Counters $counters
        $adapters.ReadState={param($StateRoot,$SuppressionKey)$reads.Count++;if($reads.Count -le 2){$withOld}else{$withoutOld}}.GetNewClosure()
        $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $request=New-CcodEngineRequest -Action Recover -RestartOrdinary $false -TransactionId '16df4637-47f5-4758-89a4-f04c7e7375cf'
        $result=Invoke-CcodRecoverSession -Request $request -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Closed' $result.outcome 'old recovery is safely finalized and its ordinary result is then closed'
        Assert-CcodEqual $request.transactionId $result.transactionId 'separate close keeps the new request correlation ID'
        Assert-CcodTrue (($events -join ',') -cmatch 'Complete:Recovered,StaticProbe,IntentWritten,CloseRequested') 'older transaction archives before the independent close intent'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'DoNotRestart never starts another ordinary after CloseRequested'
    }

    Invoke-CcodTest 'repairs only the recorded renderer endpoint and never supplies main Inspector arguments' {
        $status=[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
        $broken=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $captured=[pscustomobject]@{Arguments=$null};$repairOrder=[Collections.Generic.List[string]]::new();$adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($broken)
        $rendererProof=[ordered]@{ok=$true;protocolVersion=1;renderer=[ordered]@{targetUrl='app://-/index.html';currentDocument=[ordered]@{installed=$true};newDocumentScriptInstalled=$true;probe=[ordered]@{proof=$true;targetGate='782640499'}}}
        $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$repairOrder.Add("Wait:${Port}:${TimeoutMilliseconds}");$true}.GetNewClosure()
        $adapters.InvokeNode={param($NodePath,$Arguments)$repairOrder.Add('InvokeNode');$captured.Arguments=@($Arguments);[pscustomobject][ordered]@{ExitCode=0;Stdout=($rendererProof|ConvertTo-Json -Depth 16 -Compress);Stderr=''}}.GetNewClosure()
        $result=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'NoAction' $result.outcome 'successful renderer repair needs no process normalization'
        Assert-CcodEqual 'SpecialValidated' $result.safeState 'renderer-only proof restores validated special state'
        Assert-CcodEqual "$($paths.OrchestratorPath),--mode,renderer,--renderer-port,41001,--timeout-ms,30000" ($captured.Arguments -join ',') 'renderer repair passes renderer mode, its recorded port, and the request timeout'
        Assert-CcodTrue (($captured.Arguments -join ',') -cnotmatch 'main') 'renderer repair never passes a main connector argument'
        Assert-CcodEqual 'Wait:41002:30000,InvokeNode' ($repairOrder -join ',') 'explicit main refusal is proven before renderer-only child invocation'

        $missing=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer -TransactionId '36cafc98-f225-43bd-ae33-b9a608ac68da') -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @())
        Assert-CcodEqual 'Error' $missing.outcome 'renderer repair fails closed without exact persisted special identity'
    }

    Invoke-CcodTest 'normalizes once without renderer or Active writes when repair main refusal is unproven' {
        $status=[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002;$alive=@{201=$special}
        $counts=[pscustomobject]@{Wait=0;Node=0;ActiveWrites=0;RecoveryStages=0;SpecialStart=0;OrdinaryStart=0;Recover=0}
        $adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($special) -Counters $counts
        $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$counts.Wait++;return ($counts.Wait -gt 1)}.GetNewClosure()
        $adapters.InvokeNode={param($NodePath,$Arguments)$counts.Node++;New-CcodFullBridgeInvocation}.GetNewClosure()
        $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $baseSet=$adapters.SetTransition;$adapters.SetTransition={param($Path,$TransactionId,$ExpectedStage,$NewStage,$SpecialIdentity,$RecoveryIdentity,$RendererPort,$MainPort)if($NewStage -ceq 'RecoveryLaunchRequested'){$counts.RecoveryStages++};& $baseSet $Path $TransactionId $ExpectedStage $NewStage $SpecialIdentity $RecoveryIdentity $RendererPort $MainPort}.GetNewClosure()
        $adapters.WriteStatus={param($StateRoot,$Status,$LiveProbe)if($null -ne $LiveProbe){$counts.ActiveWrites++}}
        $result=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Recovered' $result.outcome 'unproven main refusal enters ordinary normalization'
        Assert-CcodEqual 1 $counts.RecoveryStages 'repair failure enters recovery exactly once'
        Assert-CcodEqual 0 $counts.Node 'renderer child is never invoked while main refusal is unproven'
        Assert-CcodEqual 0 $counts.ActiveWrites 'failed repair never writes Active status evidence'
    }

    Invoke-CcodTest 'rejects every mismatched live repair identity dimension before renderer activity' {
        $status=[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
        foreach($field in @('Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName','RendererPort','MainPort')){
            $candidate=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
            switch($field){'Pid'{$candidate.Pid=202};'CreationTimeUtc'{$candidate.CreationTimeUtc='2030-02-03T04:05:08.0000000Z'};'SessionId'{$candidate.SessionId=2};'UserSid'{$candidate.UserSid='S-1-5-21-other'};'Path'{$candidate.Path='C:\Other\ChatGPT.exe'};'PackageFamilyName'{$candidate.PackageFamilyName='Other.Family'};'RendererPort'{$candidate.RendererPort=42001};'MainPort'{$candidate.MainPort=42002}}
            $counts=[pscustomobject]@{Node=0;Wait=0;SpecialStart=0;OrdinaryStart=0;Recover=0};$adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($candidate) -Counters $counts
            $adapters.WaitPortClosed={param($Port,$TimeoutMilliseconds)$counts.Wait++;$true}.GetNewClosure();$adapters.InvokeNode={param($NodePath,$Arguments)$counts.Node++;New-CcodFullBridgeInvocation}.GetNewClosure()
            $result=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer -TransactionId ([guid]::NewGuid().ToString('D'))) -Paths $paths -Adapters $adapters
            Assert-CcodEqual 'CCOD_SOURCE_CHANGED' $result.error.code "$field mismatch fails the repair identity gate"
            Assert-CcodEqual 0 $counts.Wait "$field mismatch performs no port observation"
            Assert-CcodEqual 0 $counts.Node "$field mismatch performs no renderer activity"
        }
    }

    Invoke-CcodTest 'normal Recover keeps ordinary or starts exactly one ordinary when Codex is closed' {
        $ordinary=New-CcodEngineSnapshot;$counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0}
        $kept=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover) -Paths $paths -Adapters (New-CcodEngineAdapters -Processes @($ordinary) -Counters $counters)
        Assert-CcodEqual 'NoAction' $kept.outcome 'an existing exact ordinary root is already normalized'
        Assert-CcodEqual 'OrdinaryRunning' $kept.safeState 'existing ordinary root is reported without mutation'
        Assert-CcodEqual 0 $counters.OrdinaryStart 'existing ordinary root is never duplicated'

        $clock=[pscustomobject]@{Delayed=0};$adapters=New-CcodEngineAdapters -Processes @() -Counters $counters;$adapters.Delay={param($Milliseconds)$clock.Delayed+=$Milliseconds}.GetNewClosure()
        $started=Invoke-CcodRecoverSession -Request (New-CcodEngineRequest -Action Recover -TransactionId 'fc711735-3020-439d-b95f-e820866cfb45') -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Recovered' $started.outcome 'closed Codex is returned to an ordinary session'
        Assert-CcodEqual 5000 $clock.Delayed 'normal Recover observes absence for fake five seconds before launch'
        Assert-CcodEqual 1 $counters.OrdinaryStart 'normal Recover launches ordinary exactly once'
    }

    Invoke-CcodTest 'renderer repair failure normalizes once and suppresses the failed runtime' {
        $status=[pscustomobject]@{schemaVersion=1;session=[pscustomobject]@{supervisorPid=11;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-1';sessionState='Active';codex=[pscustomobject]@{pid=201;creationTimeUtc='2030-02-03T04:05:07.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=41002;rendererPort=41001;mainProbe='Closed';rendererProbe='BridgeValid'}}}
        $special=New-CcodEngineSnapshot -Pid 201 -CreationTimeUtc '2030-02-03T04:05:07.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002;$alive=@{201=$special}
        $counters=[pscustomobject]@{SpecialStart=0;OrdinaryStart=0;Recover=0;Node=0};$adapters=New-CcodEngineAdapters -State (New-CcodEngineState -Status $status) -Processes @($special) -Counters $counters
        $adapters.InvokeNode={param($NodePath,$Arguments)[pscustomobject][ordered]@{ExitCode=0;Stdout='{}';Stderr=''}}
        $adapters.ListProcesses={param($StatusEvidence)@($alive.Values)}.GetNewClosure();$adapters.GetProcess={param($ProcessId,$StatusEvidence)if($alive.ContainsKey([int]$ProcessId)){$alive[[int]$ProcessId]}else{$null}}.GetNewClosure();$adapters.GetTree={param($Root,$StatusEvidence)@($Root)}
        $adapters.StopProcess={param($Expected,$StatusEvidence,$TimeoutMilliseconds)$alive.Remove([int]$Expected.Pid);[pscustomobject]@{Outcome='Stopped';StoppedByController=$true;Snapshot=$Expected}}.GetNewClosure()
        $result=Invoke-CcodRepairRenderer -Request (New-CcodEngineRequest -Action RepairRenderer) -Paths $paths -Adapters $adapters
        Assert-CcodEqual 'Recovered' $result.outcome 'renderer proof failure returns a proven ordinary recovery'
        Assert-CcodEqual 1 $counters.OrdinaryStart 'renderer repair recovery launches ordinary at most once'
        Assert-CcodTrue (-not [string]::IsNullOrWhiteSpace($result.recovery.suppressionKey)) 'renderer repair failure returns suppression evidence'
    }

    Invoke-CcodTest 'production adapter declarations call upstream APIs and contain no empty process placeholder' {
        $moduleText=[IO.File]::ReadAllText((Join-Path $repositoryRoot 'src\persistence\modules\SessionEngine.psm1'))
        foreach($command in @('Invoke-CcodStaticProbe','Get-CcodProcessSnapshot','Test-CcodProcessMatch','Stop-CcodProcessIfMatch','Get-CcodVerifiedProcessTree','Get-CcodTransactionProcessResult','Get-CcodAvailableLoopbackPort','Start-CcodProcess','Wait-CcodPortClosed','Read-CcodState','Write-CcodStatus','Write-CcodVerifiedPackages','New-CcodTransition','Set-CcodTransitionStage','Complete-CcodTransition')){Assert-CcodTrue ($moduleText -cmatch [regex]::Escape($command)) "production adapters wire $command"}
        Assert-CcodTrue ($moduleText -cnotmatch 'ListProcesses=\{\s*param\([^)]*\)\s*@\(\)\s*\}') 'production process enumeration is not an always-empty placeholder'
    }
} catch {
    Write-Error $_
    exit 1
} finally {
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
