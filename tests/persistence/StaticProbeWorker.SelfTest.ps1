$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$workerScript = Join-Path $repositoryRoot 'src\persistence\StaticProbeWorker.ps1'
if (-not [IO.File]::Exists($workerScript)) {
    throw 'MISSING_STATIC_PROBE_WORKER: src\persistence\StaticProbeWorker.ps1'
}
. $workerScript

$script:WorkerSid = 'S-1-5-21-111-222-333-1001'
$script:WorkerSession = [int]1
$script:SupervisorCreated = '2030-02-03T03:00:00.0000000Z'
$script:TargetCreated = '2030-02-03T03:01:00.0000000Z'
$script:RequestId = '5f496d99-c839-4458-a6a2-d37ea1afdbda'
$script:RuntimeId = 'runtime-1'
$script:Executable = 'C:\Fake\Codex\app\ChatGPT.exe'
$script:PackageFullName = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'
$script:PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'

function New-CcodWorkerRequest {
    [pscustomobject][ordered]@{
        schemaVersion = 1
        action = 'StaticProbe'
        requestId = $script:RequestId
        runtimeId = $script:RuntimeId
        supervisorIdentity = [pscustomobject][ordered]@{
            pid = 41
            creationTimeUtc = $script:SupervisorCreated
            sessionId = '1'
        }
        targetIdentity = [pscustomobject][ordered]@{
            pid = 101
            creationTimeUtc = $script:TargetCreated
        }
        timeoutMilliseconds = 30000
    }
}

function Copy-CcodJsonObject($Value) {
    return ($Value | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json)
}

function New-CcodTestStreamEmitter {
    param([string]$Stream,[string]$Message)
    return {
        switch -CaseSensitive ($Stream) {
            'Error' { Write-Error -Message $Message -ErrorId 'SECRET_ADAPTER_ERROR' -TargetObject $Message -ErrorAction Continue }
            'Output' { Write-Output $Message }
            'Warning' { Write-Warning $Message }
            'Verbose' { Write-Verbose $Message -Verbose }
            'Debug' { $DebugPreference='Continue';Write-Debug $Message }
            'Information' { Write-Information $Message -InformationAction Continue }
            default { throw 'invalid test stream' }
        }
    }.GetNewClosure()
}

function New-CcodWorkerPackage {
    [pscustomobject][ordered]@{
        Found = $true
        Code = 'PACKAGE_FOUND'
        FullName = $script:PackageFullName
        FamilyName = $script:PackageFamilyName
        Version = '1.0.0.0'
        InstallLocation = 'C:\Fake\Codex'
        ExecutablePath = $script:Executable
        AppAsarPath = 'C:\Fake\Codex\app\resources\app.asar'
        NativeDirectory = 'C:\Fake\Codex\app\resources\native'
    }
}

function New-CcodWorkerTargetSnapshot {
    [pscustomobject][ordered]@{
        Pid = 101
        CreationTimeUtc = $script:TargetCreated
        SessionId = 1
        UserSid = $script:WorkerSid
        Path = $script:Executable
        PackageFamilyName = $script:PackageFamilyName
        CommandLine = '"C:\Fake\Codex\app\ChatGPT.exe"'
        ParentPid = 10
        IsTopLevel = $true
        Mode = 'Ordinary'
        RendererPort = $null
        MainPort = $null
    }
}

function New-CcodTask4Probe {
    param(
        [ValidateSet('CandidateCompatible','NativeModulePresent','UnknownOrIncompatible')]
        [string]$Classification = 'CandidateCompatible',
        [string]$Code = 'CHECKER_OK'
    )
    $native = $Classification -ceq 'NativeModulePresent'
    $ready = $Classification -ceq 'CandidateCompatible'
    [pscustomobject][ordered]@{
        Ready = $ready
        Code = $Code
        Message = $null
        SchemaVersion = 1
        StaticClassification = $Classification
        AffectedBuildDetected = $ready
        PackageInstalled = $true
        PackageFullName = $script:PackageFullName
        PackageFamilyName = $script:PackageFamilyName
        FamilyName = $script:PackageFamilyName
        PackageVersion = '1.0.0.0'
        PackageInstallLocation = 'C:\Fake\Codex'
        ExecutablePath = $script:Executable
        AppAsarPath = 'C:\Fake\Codex\app\resources\app.asar'
        AppAsarSha256 = ('a' * 64)
        NodePath = 'C:\Node\node.exe'
        NodeVersion = 'v22.23.1'
        NodeMajor = 22
        NodeSupported = $true
        NodeCapabilities = [pscustomobject][ordered]@{ Supported=$true; Version='v22.23.1'; Major=22 }
        NativeModulePresent = $native
        PackageSignatures = [pscustomobject]@{ schemaVersion=1 }
        Signatures = [pscustomobject]@{ invertedGate=$true; deviceKeyModuleReference=$true; macOnlyGuard=$true; windowsControllerUi=$true }
    }
}

function New-CcodWorkerSuccessResult {
    param([string]$Classification = 'CandidateCompatible')
    $request = New-CcodWorkerRequest
    [pscustomobject][ordered]@{
        schemaVersion = 1
        action = 'StaticProbe'
        ok = $true
        requestId = $request.requestId
        runtimeId = $request.runtimeId
        targetIdentity = Copy-CcodJsonObject $request.targetIdentity
        probe = [pscustomobject][ordered]@{
            ready = $Classification -ceq 'CandidateCompatible'
            code = 'CHECKER_OK'
            staticClassification = $Classification
            packageInstalled = $true
            packageFullName = $script:PackageFullName
            packageFamilyName = $script:PackageFamilyName
            packageVersion = '1.0.0.0'
            executablePath = $script:Executable
            appAsarSha256 = ('a' * 64)
            nodeVersion = 'v22.23.1'
            nodeMajor = 22
            nodeSupported = $true
            nativeModulePresent = $Classification -ceq 'NativeModulePresent'
        }
        error = $null
    }
}

function Get-CcodTestRuntimeId {
    param([string]$ProjectVersion, [object[]]$Files)
    $lines = foreach ($file in $Files) { '{0}`t{1}`t{2}' -f $file.path,[int64]$file.length,$file.sha256 }
    $canonical = $lines -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return '{0}-{1}' -f $ProjectVersion,$digest.Substring(0,16)
}

function Get-CcodTestRuntimeRecords {
    param([string]$RuntimeRoot)
    $records = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $RuntimeRoot -File -Recurse | Where-Object { $_.Name -cne 'manifest.json' }) {
        $records.Add([pscustomobject][ordered]@{
            path = $file.FullName.Substring($RuntimeRoot.TrimEnd('\').Length + 1).Replace('\','/')
            length = [int64]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    $records.Sort([Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path)})
    return $records.ToArray()
}

function New-CcodAuthorizedRuntimeFixture {
    param([string]$Root)
    $install = Join-Path $Root 'install'
    $staging = Join-Path $install 'staging'
    foreach ($relative in @(
        'src\persistence\StaticProbeWorker.ps1',
        'src\persistence\modules\RuntimeManifest.psm1',
        'src\persistence\modules\PersistenceIO.psm1',
        'src\persistence\modules\StateStore.psm1',
        'src\persistence\modules\CompatibilityProbe.psm1',
        'src\persistence\modules\ProcessControl.psm1',
        'src\check-package.mjs'
    )) {
        $source = Join-Path $repositoryRoot $relative
        $destination = Join-Path $staging $relative
        [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
        [IO.File]::WriteAllBytes($destination,[IO.File]::ReadAllBytes($source))
    }
    $records = @(Get-CcodTestRuntimeRecords -RuntimeRoot $staging)
    $runtimeId = Get-CcodTestRuntimeId -ProjectVersion '2.0.0' -Files $records
    $runtime = Join-Path (Join-Path $install 'runtime') $runtimeId
    [IO.Directory]::CreateDirectory((Split-Path $runtime -Parent)) | Out-Null
    [IO.Directory]::Move($staging,$runtime)
    $manifest = [pscustomobject][ordered]@{schemaVersion=1;projectVersion='2.0.0';runtimeId=$runtimeId;files=$records}
    [IO.File]::WriteAllText((Join-Path $runtime 'manifest.json'),($manifest|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $active = [pscustomobject][ordered]@{schemaVersion=1;activeRuntime=$runtimeId;previousRuntime=$null;updatedAtUtc='2030-02-03T04:05:06.0000000Z'}
    [IO.File]::WriteAllText((Join-Path $install 'active.json'),($active|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $workers = Join-Path $install 'state\workers'
    [IO.Directory]::CreateDirectory($workers)|Out-Null
    return [pscustomobject][ordered]@{
        InstallRoot=[IO.Path]::GetFullPath($install)
        RuntimeRoot=[IO.Path]::GetFullPath($runtime)
        RuntimeId=$runtimeId
        WorkerPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\persistence\StaticProbeWorker.ps1'))
        ManifestPath=[IO.Path]::GetFullPath((Join-Path $runtime 'manifest.json'))
        ActivePath=[IO.Path]::GetFullPath((Join-Path $install 'active.json'))
        WorkersRoot=[IO.Path]::GetFullPath($workers)
    }
}

function New-CcodWorkerHarness {
    param(
        [string]$Root,
        $Request = (New-CcodWorkerRequest),
        [string]$Classification = 'CandidateCompatible',
        [string]$ProbeCode = 'CHECKER_OK',
        [string]$Drift = 'None',
        [bool]$WriteFailure = $false
    )
    $install = [IO.Path]::GetFullPath((Join-Path $Root 'install'))
    $runtime = [IO.Path]::GetFullPath((Join-Path $install 'runtime\runtime-1'))
    $workers = [IO.Path]::GetFullPath((Join-Path $install 'state\workers'))
    [IO.Directory]::CreateDirectory($workers)|Out-Null
    $requestPath = [IO.Path]::GetFullPath((Join-Path $workers ("static-probe-$($script:RequestId).request.json")))
    $resultPath = [IO.Path]::GetFullPath((Join-Path $workers ("static-probe-$($script:RequestId).result.json")))
    [IO.File]::WriteAllText($requestPath,($Request|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    $context = [pscustomobject][ordered]@{
        InstallRoot=$install;RuntimeRoot=$runtime;RuntimeId='runtime-1';WorkerPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\persistence\StaticProbeWorker.ps1'))
        StateRoot=[IO.Path]::GetFullPath((Join-Path $install 'state'));WorkersRoot=$workers;CheckerPath=[IO.Path]::GetFullPath((Join-Path $runtime 'src\check-package.mjs'));AuthorizationId='auth-1'
    }
    $events=[Collections.Generic.List[string]]::new();$stdout=[Collections.Generic.List[string]]::new();$written=[Collections.Generic.List[object]]::new();$probeCalls=[Collections.Generic.List[object]]::new()
    $parentReads=[pscustomobject]@{Count=0};$targetReads=[pscustomobject]@{Count=0};$packageReads=[pscustomobject]@{Count=0}
    $classificationValue=$Classification;$probeCodeValue=$ProbeCode;$driftValue=$Drift;$writeFails=$WriteFailure
    $workerSid=[string]$script:WorkerSid;$supervisorCreated=[string]$script:SupervisorCreated
    $basePackage=New-CcodWorkerPackage;$baseTarget=New-CcodWorkerTargetSnapshot;$baseProbe=New-CcodTask4Probe -Classification $classificationValue -Code $probeCodeValue
    $adapters=@{
        GetScriptPath={ $context.WorkerPath }.GetNewClosure()
        AuthorizeRuntime={param($Path)$context}.GetNewClosure()
        ImportRuntime={param($Context)[pscustomobject]@{TestRuntimeManifest={}}}
        CompleteRuntimeAuthorization={param($Context)$Context}
        ReauthorizeRuntime={param($Path)if($driftValue -ceq 'Runtime'){ $changed=Copy-CcodJsonObject $context;$changed.AuthorizationId='auth-2';$changed }else{$context}}.GetNewClosure()
        ReadRequest={param($Path)[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false))|ConvertFrom-Json}.GetNewClosure()
        ReadSettings={param($StateRoot)[pscustomobject][ordered]@{schemaVersion=1;automationEnabled=$true;candidateCompatibleOptIn=$true;nodeCandidates=@('C:\Node\node.exe');updatedAtUtc='2030-02-03T04:05:06.0000000Z'}}
        GetCurrentIdentity={ [pscustomobject][ordered]@{Pid=900;UserSid=$workerSid;SessionId=[int]1} }.GetNewClosure()
        GetParentProcessId={ [int]41 }
        GetProcessIdentity={param($Pid)$parentReads.Count++;if($driftValue -ceq 'Parent' -and $parentReads.Count -gt 1){[pscustomobject][ordered]@{Pid=41;CreationTimeUtc='2030-02-03T03:00:01.0000000Z';SessionId=1;UserSid=$workerSid}}else{[pscustomobject][ordered]@{Pid=41;CreationTimeUtc=$supervisorCreated;SessionId=1;UserSid=$workerSid}}}.GetNewClosure()
        GetPackageIdentity={ $packageReads.Count++;$package=$basePackage|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json;if($driftValue -ceq 'Package' -and $packageReads.Count -gt 1){$package.Version='2.0.0.0'};$package }.GetNewClosure()
        GetTargetSnapshot={param($Pid,$Package)$targetReads.Count++;$snapshot=$baseTarget|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json;if($driftValue -ceq 'Target' -and $targetReads.Count -gt 1){$snapshot.CreationTimeUtc='2030-02-03T03:01:01.0000000Z'};$snapshot}.GetNewClosure()
        StartDeadline={param($Timeout)[pscustomobject]@{Timeout=$Timeout}}
        InvokeProbe={param($NodeCandidates,$CheckerPath,$Deadline)$probeCalls.Add([pscustomobject]@{Nodes=@($NodeCandidates);Checker=$CheckerPath;Deadline=$Deadline});$baseProbe|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json}.GetNewClosure()
        WriteResult={param($Path,$Value)$events.Add('write');if($writeFails){throw 'private disk failure'};$written.Add(($Value|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json))}.GetNewClosure()
        WriteStdout={param($Line)$events.Add('stdout');$stdout.Add($Line)}.GetNewClosure()
        WriteStderr={param($Line)$events.Add('stderr')}.GetNewClosure()
    }
    [pscustomobject][ordered]@{RequestPath=$requestPath;ResultPath=$resultPath;Context=$context;Adapters=$adapters;Events=$events;Stdout=$stdout;Written=$written;ProbeCalls=$probeCalls}
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-static-worker-'+[guid]::NewGuid().ToString('N'))
try {
    Invoke-CcodTest 'strictly rejects every request shape, order, type, case, and correlation mutation' {
        $base=New-CcodWorkerRequest
        Assert-CcodStaticProbeRequest -Request $base|Out-Null
        foreach($field in @('schemaVersion','action','requestId','runtimeId','supervisorIdentity','targetIdentity','timeoutMilliseconds')){
            $bad=Copy-CcodJsonObject $base;[void]$bad.PSObject.Properties.Remove($field)
            Assert-CcodThrows {Assert-CcodStaticProbeRequest -Request $bad|Out-Null} 'CCOD_STATIC_REQUEST_INVALID'
        }
        $cases=[Collections.Generic.List[object]]::new()
        $extra=Copy-CcodJsonObject $base;$extra|Add-Member -NotePropertyName installRoot -NotePropertyValue 'C:\private';$cases.Add($extra)
        $wrongOrder=[pscustomobject][ordered]@{action='StaticProbe';schemaVersion=1;requestId=$base.requestId;runtimeId=$base.runtimeId;supervisorIdentity=$base.supervisorIdentity;targetIdentity=$base.targetIdentity;timeoutMilliseconds=30000};$cases.Add($wrongOrder)
        foreach($change in @(
            @{Name='schemaVersion';Value=[long]1},@{Name='action';Value='staticprobe'},@{Name='requestId';Value=$base.requestId.ToUpperInvariant()},
            @{Name='runtimeId';Value='../runtime'},@{Name='timeoutMilliseconds';Value=[long]30000},@{Name='timeoutMilliseconds';Value=499},@{Name='timeoutMilliseconds';Value=120001}
        )){$bad=Copy-CcodJsonObject $base;$bad.($change.Name)=$change.Value;$cases.Add($bad)}
        $supervisorCases=@(
            [pscustomobject][ordered]@{pid=[long]41;creationTimeUtc=$script:SupervisorCreated;sessionId='1'},
            [pscustomobject][ordered]@{creationTimeUtc=$script:SupervisorCreated;pid=41;sessionId='1'},
            [pscustomobject][ordered]@{pid=41;creationTimeUtc='2030-02-03T03:00:00Z';sessionId='1'},
            [pscustomobject][ordered]@{pid=41;creationTimeUtc=$script:SupervisorCreated;sessionId='01'},
            [pscustomobject][ordered]@{pid=41;creationTimeUtc=$script:SupervisorCreated;sessionId=1},
            [pscustomobject][ordered]@{pid=41;creationTimeUtc=$script:SupervisorCreated;sessionId='1';path='C:\private'}
        )
        foreach($identity in $supervisorCases){$bad=Copy-CcodJsonObject $base;$bad.supervisorIdentity=$identity;$cases.Add($bad)}
        $targetCases=@(
            [pscustomobject][ordered]@{pid=[long]101;creationTimeUtc=$script:TargetCreated},
            [pscustomobject][ordered]@{creationTimeUtc=$script:TargetCreated;pid=101},
            [pscustomobject][ordered]@{pid=101;creationTimeUtc='2030-02-03T03:01:00Z'},
            [pscustomobject][ordered]@{pid=101;creationTimeUtc=$script:TargetCreated;executablePath='C:\private'}
        )
        foreach($identity in $targetCases){$bad=Copy-CcodJsonObject $base;$bad.targetIdentity=$identity;$cases.Add($bad)}
        foreach($bad in $cases){Assert-CcodThrows {Assert-CcodStaticProbeRequest -Request $bad|Out-Null} 'CCOD_STATIC_REQUEST_INVALID'}
    }

    Invoke-CcodTest 'strictly rejects every result and public probe schema mutation' {
        $request=New-CcodWorkerRequest;$base=New-CcodWorkerSuccessResult
        Assert-CcodStaticProbeResult -Result $base -ExpectedRequest $request|Out-Null
        foreach($field in @('schemaVersion','action','ok','requestId','runtimeId','targetIdentity','probe','error')){
            $bad=Copy-CcodJsonObject $base;[void]$bad.PSObject.Properties.Remove($field)
            Assert-CcodThrows {Assert-CcodStaticProbeResult -Result $bad -ExpectedRequest $request|Out-Null} 'CCOD_STATIC_RESULT_INVALID'
        }
        $extra=Copy-CcodJsonObject $base;$extra|Add-Member -NotePropertyName path -NotePropertyValue 'C:\private';Assert-CcodThrows {Assert-CcodStaticProbeResult $extra $request|Out-Null} 'CCOD_STATIC_RESULT_INVALID'
        $wrong=[pscustomobject][ordered]@{action='StaticProbe';schemaVersion=1;ok=$true;requestId=$base.requestId;runtimeId=$base.runtimeId;targetIdentity=$base.targetIdentity;probe=$base.probe;error=$null};Assert-CcodThrows {Assert-CcodStaticProbeResult $wrong $request|Out-Null} 'CCOD_STATIC_RESULT_INVALID'
        foreach($field in @('requestId','runtimeId')){$bad=Copy-CcodJsonObject $base;$bad.$field='mismatch';Assert-CcodThrows {Assert-CcodStaticProbeResult $bad $request|Out-Null} 'CCOD_STATIC_RESULT_INVALID'}
        foreach($field in @('ready','code','staticClassification','packageInstalled','packageFullName','packageFamilyName','packageVersion','executablePath','appAsarSha256','nodeVersion','nodeMajor','nodeSupported','nativeModulePresent')){
            $bad=Copy-CcodJsonObject $base;[void]$bad.probe.PSObject.Properties.Remove($field)
            Assert-CcodThrows {Assert-CcodStaticProbeResult $bad $request|Out-Null} 'CCOD_STATIC_RESULT_INVALID'
        }
        foreach($mutation in @(
            @{Name='ready';Value=1},@{Name='code';Value='CHECKER_FAILED'},@{Name='staticClassification';Value='candidatecompatible'},
            @{Name='packageInstalled';Value=1},@{Name='packageFullName';Value=''},@{Name='packageFamilyName';Value="Other`nFamily"},
            @{Name='packageVersion';Value=''},@{Name='executablePath';Value='relative.exe'},@{Name='appAsarSha256';Value=('A'*64)},
            @{Name='nodeVersion';Value='v21.0.0'},@{Name='nodeMajor';Value=[long]22},@{Name='nodeSupported';Value=$false},@{Name='nativeModulePresent';Value=$true}
        )){$bad=Copy-CcodJsonObject $base;$bad.probe.($mutation.Name)=$mutation.Value;Assert-CcodThrows {Assert-CcodStaticProbeResult $bad $request|Out-Null} 'CCOD_STATIC_RESULT_INVALID'}
        $failure=New-CcodStaticProbeErrorResult -Request $request -Code 'CCOD_STATIC_PROBE_FAILED' -Stage 'StaticProbe'
        Assert-CcodStaticProbeResult -Result $failure -ExpectedRequest $request|Out-Null
        $failure.error.message="secret`npath";Assert-CcodThrows {Assert-CcodStaticProbeResult $failure $request|Out-Null} 'CCOD_STATIC_RESULT_INVALID'
    }

    Invoke-CcodTest 'authorizes only the strict active manifest bound self path before module use' {
        $fixture=New-CcodAuthorizedRuntimeFixture -Root (Join-Path $root 'runtime-fixture')
        $authorization=Get-CcodStaticProbeRuntimeAuthorization -ScriptPath $fixture.WorkerPath
        Assert-CcodEqual $fixture.RuntimeId $authorization.RuntimeId 'runtime directory, manifest, computed ID, and active pointer bind'
        Assert-CcodEqual $fixture.WorkerPath $authorization.WorkerPath 'authorization binds the exact worker self path'
        Assert-CcodThrows {Get-CcodStaticProbeRuntimeAuthorization -ScriptPath $workerScript|Out-Null} 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'

        $active=Get-Content -LiteralPath $fixture.ActivePath -Raw|ConvertFrom-Json
        $wrongOrder=[pscustomobject][ordered]@{activeRuntime=$active.activeRuntime;schemaVersion=1;previousRuntime=$null;updatedAtUtc=$active.updatedAtUtc}
        [IO.File]::WriteAllText($fixture.ActivePath,($wrongOrder|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {Get-CcodStaticProbeRuntimeAuthorization -ScriptPath $fixture.WorkerPath|Out-Null} 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'
        [IO.File]::WriteAllText($fixture.ActivePath,([pscustomobject][ordered]@{schemaVersion=1;activeRuntime=$fixture.RuntimeId;previousRuntime=$null;updatedAtUtc='2030-02-03T04:05:06.0000000Z'}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))

        $manifest=Get-Content -LiteralPath $fixture.ManifestPath -Raw|ConvertFrom-Json;$manifest.files[0].length=[string]$manifest.files[0].length
        [IO.File]::WriteAllText($fixture.ManifestPath,($manifest|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {Get-CcodStaticProbeRuntimeAuthorization -ScriptPath $fixture.WorkerPath|Out-Null} 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'
    }

    Invoke-CcodTest 'rejects every hostile active pointer shape before importing runtime code' {
        foreach($variant in @('MissingFile','MissingField','ExtraField','WrongOrder','WrongCase','WrongType','BadUtc','EqualPrevious','WrongRuntimeCase')){
            $fixture=New-CcodAuthorizedRuntimeFixture -Root (Join-Path $root ('active-'+$variant.ToLowerInvariant()))
            $active=Get-Content -LiteralPath $fixture.ActivePath -Raw|ConvertFrom-Json
            switch -CaseSensitive ($variant) {
                'MissingFile' {[IO.File]::Delete($fixture.ActivePath)}
                'MissingField' {[void]$active.PSObject.Properties.Remove('activeRuntime')}
                'ExtraField' {$active|Add-Member -NotePropertyName installRoot -NotePropertyValue 'C:\private'}
                'WrongOrder' {$active=[pscustomobject][ordered]@{activeRuntime=$active.activeRuntime;schemaVersion=1;previousRuntime=$null;updatedAtUtc=$active.updatedAtUtc}}
                'WrongCase' {$active=[pscustomobject][ordered]@{SchemaVersion=1;activeRuntime=$active.activeRuntime;previousRuntime=$null;updatedAtUtc=$active.updatedAtUtc}}
                'WrongType' {$active.schemaVersion='1'}
                'BadUtc' {$active.updatedAtUtc='2030-02-03T04:05:06Z'}
                'EqualPrevious' {$active.previousRuntime=$active.activeRuntime}
                'WrongRuntimeCase' {$active.activeRuntime=$active.activeRuntime.ToUpperInvariant()}
            }
            if($variant -cne 'MissingFile'){[IO.File]::WriteAllText($fixture.ActivePath,($active|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
            Assert-CcodThrows {Get-CcodStaticProbeRuntimeAuthorization -ScriptPath $fixture.WorkerPath|Out-Null} 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'
        }
    }

    Invoke-CcodTest 'rejects every hostile manifest root record path hash self-binding and reparse mutation' {
        $variants=@(
            'RootMissing','RootExtra','RootOrder','RootCase','RootType','RecordMissing','RecordExtra','RecordOrder','RecordCase','LengthString',
            'Duplicate','Unsorted','AbsolutePath','TraversalPath','AdsPath','RequiredMissing','RecordHashTamper','FileHashTamper','SelfPathMismatch','ManifestReparse'
        )
        foreach($variant in $variants){
            $fixture=New-CcodAuthorizedRuntimeFixture -Root (Join-Path $root ('manifest-'+$variant.ToLowerInvariant()))
            $manifest=Get-Content -LiteralPath $fixture.ManifestPath -Raw|ConvertFrom-Json
            $adapters=$null;$scriptPath=$fixture.WorkerPath
            switch -CaseSensitive ($variant) {
                'RootMissing' {[void]$manifest.PSObject.Properties.Remove('files')}
                'RootExtra' {$manifest|Add-Member -NotePropertyName installRoot -NotePropertyValue 'C:\private'}
                'RootOrder' {$manifest=[pscustomobject][ordered]@{projectVersion=$manifest.projectVersion;schemaVersion=1;runtimeId=$manifest.runtimeId;files=$manifest.files}}
                'RootCase' {$manifest=[pscustomobject][ordered]@{SchemaVersion=1;projectVersion=$manifest.projectVersion;runtimeId=$manifest.runtimeId;files=$manifest.files}}
                'RootType' {$manifest.files='not-an-array'}
                'RecordMissing' {[void]$manifest.files[0].PSObject.Properties.Remove('sha256')}
                'RecordExtra' {$manifest.files[0]|Add-Member -NotePropertyName source -NotePropertyValue 'private'}
                'RecordOrder' {$record=$manifest.files[0];$manifest.files[0]=[pscustomobject][ordered]@{length=$record.length;path=$record.path;sha256=$record.sha256}}
                'RecordCase' {$record=$manifest.files[0];$manifest.files[0]=[pscustomobject][ordered]@{Path=$record.path;length=$record.length;sha256=$record.sha256}}
                'LengthString' {$manifest.files[0].length=[string]$manifest.files[0].length}
                'Duplicate' {$manifest.files=@($manifest.files[0])+@($manifest.files)}
                'Unsorted' {$swap=$manifest.files[0];$manifest.files[0]=$manifest.files[1];$manifest.files[1]=$swap}
                'AbsolutePath' {$manifest.files[0].path='C:/private/file.ps1'}
                'TraversalPath' {$manifest.files[0].path='../private/file.ps1'}
                'AdsPath' {$manifest.files[0].path='src/check-package.mjs:secret'}
                'RequiredMissing' {$manifest.files=@($manifest.files|Where-Object{$_.path -cne 'src/persistence/StaticProbeWorker.ps1'})}
                'RecordHashTamper' {$manifest.files[0].sha256=('b'*64)}
                'FileHashTamper' {[IO.File]::AppendAllText($fixture.WorkerPath,' ',[Text.UTF8Encoding]::new($false))}
                'SelfPathMismatch' {$shadow=Join-Path $fixture.RuntimeRoot 'src\persistence\shadow\StaticProbeWorker.ps1';[IO.Directory]::CreateDirectory((Split-Path $shadow -Parent))|Out-Null;[IO.File]::Copy($fixture.WorkerPath,$shadow);$scriptPath=[IO.Path]::GetFullPath($shadow)}
                'ManifestReparse' {$reparsePath=$fixture.ManifestPath;$adapters=@{GetItem={param($Path)$item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;if($item.FullName -ceq $reparsePath){[pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint}}else{$item}}.GetNewClosure()}}
            }
            if($variant -notin @('FileHashTamper','SelfPathMismatch','ManifestReparse')){[IO.File]::WriteAllText($fixture.ManifestPath,($manifest|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}
            Assert-CcodThrows {Get-CcodStaticProbeRuntimeAuthorization -ScriptPath $scriptPath -Adapters $adapters|Out-Null} 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'
        }
    }

    Invoke-CcodTest 'rejects raw duplicate JSON keys and invalid UTF8 before trusting active manifest or request objects' {
        $activeFixture=New-CcodAuthorizedRuntimeFixture -Root (Join-Path $root 'raw-duplicate-active')
        $active=Get-Content -LiteralPath $activeFixture.ActivePath -Raw|ConvertFrom-Json
        $activeJson='{"schemaVersion":1,"schemaVersion":1,"activeRuntime":"'+$active.activeRuntime+'","previousRuntime":null,"updatedAtUtc":"'+$active.updatedAtUtc+'"}'
        [IO.File]::WriteAllText($activeFixture.ActivePath,$activeJson,[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {Get-CcodStaticProbeRuntimeAuthorization -ScriptPath $activeFixture.WorkerPath|Out-Null} 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'

        foreach($variant in @('Root','Record')){
            $fixture=New-CcodAuthorizedRuntimeFixture -Root (Join-Path $root ('raw-duplicate-manifest-'+$variant.ToLowerInvariant()))
            $manifest=Get-Content -LiteralPath $fixture.ManifestPath -Raw|ConvertFrom-Json
            $json=$manifest|ConvertTo-Json -Depth 20 -Compress
            if($variant -ceq 'Root'){$json=$json.Replace('{"schemaVersion":1,','{"schemaVersion":1,"schemaVersion":1,')}
            else{$prefix='"path":"'+$manifest.files[0].path+'",';$json=$json.Replace($prefix,$prefix+$prefix)}
            [IO.File]::WriteAllText($fixture.ManifestPath,$json,[Text.UTF8Encoding]::new($false))
            Assert-CcodThrows {Get-CcodStaticProbeRuntimeAuthorization -ScriptPath $fixture.WorkerPath|Out-Null} 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'
        }

        $utf8Fixture=New-CcodAuthorizedRuntimeFixture -Root (Join-Path $root 'invalid-utf8-active')
        $bytes=[Collections.Generic.List[byte]]::new();$bytes.AddRange([Text.Encoding]::ASCII.GetBytes('{"schemaVersion":1,"activeRuntime":"'));$bytes.Add(0xC3);$bytes.Add(0x28);$bytes.AddRange([Text.Encoding]::ASCII.GetBytes('","previousRuntime":null,"updatedAtUtc":"2030-02-03T04:05:06.0000000Z"}'))
        [IO.File]::WriteAllBytes($utf8Fixture.ActivePath,$bytes.ToArray())
        Assert-CcodThrows {Get-CcodStaticProbeRuntimeAuthorization -ScriptPath $utf8Fixture.WorkerPath|Out-Null} 'CCOD_STATIC_RUNTIME_UNAUTHORIZED'

        $requestHarness=New-CcodWorkerHarness -Root (Join-Path $root 'raw-duplicate-request')
        $request=New-CcodWorkerRequest;$json=$request|ConvertTo-Json -Depth 20 -Compress;$json=$json.Replace('{"schemaVersion":1,','{"schemaVersion":1,"schemaVersion":1,')
        [IO.File]::WriteAllText($requestHarness.RequestPath,$json,[Text.UTF8Encoding]::new($false))
        $run=Invoke-CcodStaticProbeWorker $requestHarness.RequestPath $requestHarness.ResultPath $requestHarness.Adapters
        Assert-CcodEqual 1 $run.ExitCode 'duplicate request key fails closed'
        Assert-CcodEqual $null $requestHarness.Written[0].requestId 'duplicate request never gains correlation'
        Assert-CcodEqual 0 $requestHarness.ProbeCalls.Count 'duplicate request never probes'
    }

    Invoke-CcodTest 'imports only exact private bound runtime APIs and unloads every module command surface' {
        $fixture=New-CcodAuthorizedRuntimeFixture -Root (Join-Path $root 'private-runtime-api')
        $context=Get-CcodStaticProbeRuntimeAuthorization -ScriptPath $fixture.WorkerPath
        $api=Import-CcodStaticProbeRuntime -Context $context
        Assert-CcodEqual 'TestRuntimeManifest,ReadStrictJson,WriteAtomicJson,ReadSettings,GetPackageIdentity,InvokeStaticProbe,GetProcessSnapshot,ModulePaths' (($api.PSObject.Properties.Name)-join ',') 'private runtime API has only the seven allowed callbacks and path evidence'
        foreach($name in @('TestRuntimeManifest','ReadStrictJson','WriteAtomicJson','ReadSettings','GetPackageIdentity','InvokeStaticProbe','GetProcessSnapshot')){Assert-CcodTrue ($api.$name -is [scriptblock]) "$name is a private bound callback"}
        Assert-CcodEqual 'RuntimeManifest,PersistenceIO,StateStore,CompatibilityProbe,ProcessControl' (($api.ModulePaths.PSObject.Properties.Name)-join ',') 'module path evidence is exact'
        foreach($entry in @(
            @{Name='RuntimeManifest';Path='src\persistence\modules\RuntimeManifest.psm1'},@{Name='PersistenceIO';Path='src\persistence\modules\PersistenceIO.psm1'},
            @{Name='StateStore';Path='src\persistence\modules\StateStore.psm1'},@{Name='CompatibilityProbe';Path='src\persistence\modules\CompatibilityProbe.psm1'},@{Name='ProcessControl';Path='src\persistence\modules\ProcessControl.psm1'}
        )){Assert-CcodEqual ([IO.Path]::GetFullPath((Join-Path $fixture.RuntimeRoot $entry.Path))) $api.ModulePaths.($entry.Name) "$($entry.Name) callback is bound to the verified path"}
        Complete-CcodStaticProbeRuntimeAuthorization -Context $context -RuntimeApi $api|Out-Null
        foreach($forbidden in @('Start-CcodProcess','Stop-CcodProcessIfMatch','Write-CcodSettings','Write-CcodStatus','Write-CcodVerifiedPackages','Set-CcodAutomationEnabled','Set-CcodCandidateCompatibleOptIn','ProcessControl\Start-CcodProcess','ProcessControl\Stop-CcodProcessIfMatch','StateStore\Write-CcodSettings','StateStore\Write-CcodStatus','StateStore\Write-CcodVerifiedPackages')){Assert-CcodEqual $null (Get-Command $forbidden -ErrorAction SilentlyContinue) "$forbidden is unreachable after private binding"}
        foreach($path in @($api.ModulePaths.PSObject.Properties.Value)){Assert-CcodEqual 0 @(Get-Module|Where-Object{$_.Path -ceq $path}).Count "$path is unloaded after binding"}
    }

    Invoke-CcodTest 'production defaults import the verified runtime before strict request read and atomic result write' {
        $fixture=New-CcodAuthorizedRuntimeFixture -Root (Join-Path $root 'production-defaults')
        $request=New-CcodWorkerRequest;$request.runtimeId=$fixture.RuntimeId
        $requestPath=[IO.Path]::GetFullPath((Join-Path $fixture.WorkersRoot ("static-probe-$($request.requestId).request.json")))
        $resultPath=[IO.Path]::GetFullPath((Join-Path $fixture.WorkersRoot ("static-probe-$($request.requestId).result.json")))
        [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $stdout=[Collections.Generic.List[string]]::new();$stderr=[Collections.Generic.List[string]]::new()
        $scriptPath=$fixture.WorkerPath;$workerSid=[string]$script:WorkerSid;$supervisorCreated=[string]$script:SupervisorCreated
        $package=New-CcodWorkerPackage;$target=New-CcodWorkerTargetSnapshot;$probe=New-CcodTask4Probe
        $adapters=@{
            GetScriptPath={$scriptPath}.GetNewClosure()
            ReadSettings={param($StateRoot)[pscustomobject][ordered]@{schemaVersion=1;automationEnabled=$true;candidateCompatibleOptIn=$true;nodeCandidates=@('C:\Node\node.exe');updatedAtUtc='2030-02-03T04:05:06.0000000Z'}}
            GetCurrentIdentity={[pscustomobject][ordered]@{Pid=900;UserSid=$workerSid;SessionId=[int]1}}.GetNewClosure()
            GetParentProcessId={[int]41}
            GetProcessIdentity={param($Pid)[pscustomobject][ordered]@{Pid=41;CreationTimeUtc=$supervisorCreated;SessionId=1;UserSid=$workerSid}}.GetNewClosure()
            GetPackageIdentity={$package|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json}.GetNewClosure()
            GetTargetSnapshot={param($Pid,$Package)$target|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json}.GetNewClosure()
            StartDeadline={param($Timeout)[pscustomobject]@{Timeout=$Timeout}}
            InvokeProbe={param($NodeCandidates,$CheckerPath,$Deadline)$probe|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json}.GetNewClosure()
            WriteStdout={param($Line)$stdout.Add($Line)}.GetNewClosure()
            WriteStderr={param($Line)$stderr.Add($Line)}.GetNewClosure()
        }
        $run=Invoke-CcodStaticProbeWorker -RequestPath $requestPath -ResultPath $resultPath -Adapters $adapters
        Assert-CcodEqual 0 $run.ExitCode 'verified production defaults complete successfully'
        Assert-CcodTrue ([IO.File]::Exists($resultPath)) 'default atomic writer creates the result after verified import'
        $durable=[IO.File]::ReadAllText($resultPath,[Text.UTF8Encoding]::new($false))|ConvertFrom-Json
        Assert-CcodEqual $true $durable.ok 'default strict reader and atomic writer preserve a successful frame'
        Assert-CcodEqual 1 $stdout.Count 'default path emits one correlated stdout frame'
        Assert-CcodEqual 0 $stderr.Count 'default path emits no diagnostic stream'
        foreach($forbidden in @('Start-CcodProcess','Stop-CcodProcessIfMatch','Write-CcodSettings','Write-CcodStatus','Write-CcodVerifiedPackages','Set-CcodAutomationEnabled','Set-CcodCandidateCompatibleOptIn')){
            Assert-CcodEqual $null (Get-Command $forbidden -ErrorAction SilentlyContinue) "verified imports do not expose $forbidden"
        }
    }

    Invoke-CcodTest 'accepts all three checker classifications and publishes one atomic correlated frame before stdout' {
        foreach($classification in @('CandidateCompatible','NativeModulePresent','UnknownOrIncompatible')){
            $harness=New-CcodWorkerHarness -Root (Join-Path $root $classification) -Classification $classification
            $run=Invoke-CcodStaticProbeWorker -RequestPath $harness.RequestPath -ResultPath $harness.ResultPath -Adapters $harness.Adapters
            Assert-CcodEqual 0 $run.ExitCode "$classification exits zero"
            Assert-CcodEqual 'write,stdout' ($harness.Events -join ',') "$classification writes before stdout exactly once"
            Assert-CcodEqual 1 $harness.Written.Count "$classification writes one result"
            Assert-CcodEqual 1 $harness.Stdout.Count "$classification emits one stdout line"
            Assert-CcodEqual ($harness.Written[0]|ConvertTo-Json -Depth 20 -Compress) $harness.Stdout[0] "$classification stdout matches durable object"
            Assert-CcodEqual $classification $harness.Written[0].probe.staticClassification "$classification is retained"
            Assert-CcodEqual ($classification -ceq 'CandidateCompatible') $harness.Written[0].probe.ready 'only Candidate is ready'
            Assert-CcodEqual 'ready,code,staticClassification,packageInstalled,packageFullName,packageFamilyName,packageVersion,executablePath,appAsarSha256,nodeVersion,nodeMajor,nodeSupported,nativeModulePresent' (($harness.Written[0].probe.PSObject.Properties.Name)-join ',') 'only the public 13 fields are published'
            Assert-CcodEqual 'C:\Node\node.exe' $harness.ProbeCalls[0].Nodes[0] 'only strict settings node candidates reach the probe'
        }
    }

    Invoke-CcodTest 'fails closed on operational probe errors and every pre/post identity or runtime drift' {
        $operational=New-CcodWorkerHarness -Root (Join-Path $root 'operational') -ProbeCode 'CHECKER_FAILED'
        $run=Invoke-CcodStaticProbeWorker $operational.RequestPath $operational.ResultPath $operational.Adapters
        Assert-CcodEqual 1 $run.ExitCode 'checker failure exits nonzero'
        Assert-CcodEqual $false $operational.Written[0].ok 'checker failure is not fabricated as Unknown success'
        foreach($drift in @('Parent','Target','Package','Runtime')){
            $harness=New-CcodWorkerHarness -Root (Join-Path $root ('drift-'+$drift)) -Drift $drift
            $run=Invoke-CcodStaticProbeWorker $harness.RequestPath $harness.ResultPath $harness.Adapters
            Assert-CcodEqual 1 $run.ExitCode "$drift drift exits nonzero"
            Assert-CcodEqual $false $harness.Written[0].ok "$drift drift cannot authorize Apply"
            Assert-CcodEqual $script:RequestId $harness.Written[0].requestId "$drift failure preserves correlation"
        }
    }

    Invoke-CcodTest 'binds the request runtime to the preauthorized active runtime before any probe' {
        $request=New-CcodWorkerRequest;$request.runtimeId='runtime-2'
        $harness=New-CcodWorkerHarness -Root (Join-Path $root 'request-runtime-mismatch') -Request $request
        $run=Invoke-CcodStaticProbeWorker $harness.RequestPath $harness.ResultPath $harness.Adapters
        Assert-CcodEqual 1 $run.ExitCode 'request runtime mismatch fails closed'
        Assert-CcodEqual 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' $harness.Written[0].error.code 'request runtime mismatch uses the runtime authorization code'
        Assert-CcodEqual 0 $harness.ProbeCalls.Count 'request runtime mismatch is rejected before probing'
    }

    Invoke-CcodTest 'rejects every relative noncanonical colliding existing misnamed or reparse framing path' {
        foreach($variant in @('RelativeRequest','RelativeResult','NoncanonicalRequest','NoncanonicalResult','SamePath','ResultExists','WrongRequestName','WrongResultName','ReparseRequest')){
            $harness=New-CcodWorkerHarness -Root (Join-Path $root ('framing-'+$variant.ToLowerInvariant()))
            $requestPath=$harness.RequestPath;$resultPath=$harness.ResultPath
            switch -CaseSensitive ($variant) {
                'RelativeRequest' {$requestPath=[IO.Path]::GetFileName($requestPath)}
                'RelativeResult' {$resultPath=[IO.Path]::GetFileName($resultPath)}
                'NoncanonicalRequest' {$requestPath=Join-Path (Split-Path $requestPath -Parent) ('..\workers\'+[IO.Path]::GetFileName($requestPath))}
                'NoncanonicalResult' {$resultPath=Join-Path (Split-Path $resultPath -Parent) ('..\workers\'+[IO.Path]::GetFileName($resultPath))}
                'SamePath' {$resultPath=$requestPath}
                'ResultExists' {[IO.File]::WriteAllText($resultPath,'{}',[Text.UTF8Encoding]::new($false))}
                'WrongRequestName' {$wrong=Join-Path (Split-Path $requestPath -Parent) 'static-probe-00000000-0000-0000-0000-000000000000.request.json';[IO.File]::Copy($requestPath,$wrong);$requestPath=[IO.Path]::GetFullPath($wrong)}
                'WrongResultName' {$resultPath=[IO.Path]::GetFullPath((Join-Path (Split-Path $resultPath -Parent) 'static-probe-00000000-0000-0000-0000-000000000000.result.json'))}
                'ReparseRequest' {$reparsePath=$requestPath;$harness.Adapters.GetItem={param($Path)$item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;if($item.FullName -ceq $reparsePath){[pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint}}else{$item}}.GetNewClosure()}
            }
            $run=Invoke-CcodStaticProbeWorker $requestPath $resultPath $harness.Adapters
            Assert-CcodEqual 1 $run.ExitCode "$variant framing fails closed"
            Assert-CcodEqual 0 $harness.ProbeCalls.Count "$variant framing never probes"
            Assert-CcodEqual 0 $harness.Stdout.Count "$variant framing emits no stdout"
        }
    }

    Invoke-CcodTest 'rejects every wrong supervisor parent identity before target or Node work' {
        foreach($variant in @('RealParentPid','IdentityPid','CreationReuse','OtherSid','OtherSession','NaturalExit')){
            $harness=New-CcodWorkerHarness -Root (Join-Path $root ('parent-'+$variant.ToLowerInvariant()))
            $identity=[pscustomobject][ordered]@{Pid=41;CreationTimeUtc=$script:SupervisorCreated;SessionId=1;UserSid=$script:WorkerSid}
            switch -CaseSensitive ($variant) {
                'RealParentPid' {$harness.Adapters.GetParentProcessId={[int]42}}
                'IdentityPid' {$identity.Pid=42}
                'CreationReuse' {$identity.CreationTimeUtc='2030-02-03T03:00:01.0000000Z'}
                'OtherSid' {$identity.UserSid='S-1-5-21-111-222-333-1002'}
                'OtherSession' {$identity.SessionId=2}
                'NaturalExit' {$identity=$null}
            }
            if($variant -cne 'RealParentPid'){$harness.Adapters.GetProcessIdentity={$identity}.GetNewClosure()}
            $run=Invoke-CcodStaticProbeWorker $harness.RequestPath $harness.ResultPath $harness.Adapters
            Assert-CcodEqual 1 $run.ExitCode "$variant supervisor identity fails closed"
            Assert-CcodEqual 'CCOD_STATIC_SUPERVISOR_CHANGED' $harness.Written[0].error.code "$variant uses the supervisor change code"
            Assert-CcodEqual 0 $harness.ProbeCalls.Count "$variant never reaches Node work"
        }
    }

    Invoke-CcodTest 'rejects every unsafe target topology user session package and lifecycle identity' {
        foreach($variant in @('NonTopLevel','NonOrdinary','OtherSid','OtherSession','OtherPath','OtherFamily','PidReuse','CreationReuse','NaturalExit')){
            $harness=New-CcodWorkerHarness -Root (Join-Path $root ('target-'+$variant.ToLowerInvariant()))
            $snapshot=New-CcodWorkerTargetSnapshot
            switch -CaseSensitive ($variant) {
                'NonTopLevel' {$snapshot.IsTopLevel=$false}
                'NonOrdinary' {$snapshot.Mode='Special'}
                'OtherSid' {$snapshot.UserSid='S-1-5-21-111-222-333-1002'}
                'OtherSession' {$snapshot.SessionId=2}
                'OtherPath' {$snapshot.Path='C:\Fake\Other\ChatGPT.exe'}
                'OtherFamily' {$snapshot.PackageFamilyName='Other.Family_123'}
                'PidReuse' {$snapshot.Pid=102}
                'CreationReuse' {$snapshot.CreationTimeUtc='2030-02-03T03:01:01.0000000Z'}
                'NaturalExit' {$snapshot=$null}
            }
            $harness.Adapters.GetTargetSnapshot={$snapshot}.GetNewClosure()
            $run=Invoke-CcodStaticProbeWorker $harness.RequestPath $harness.ResultPath $harness.Adapters
            Assert-CcodEqual 1 $run.ExitCode "$variant target identity fails closed"
            Assert-CcodEqual 'CCOD_STATIC_TARGET_CHANGED' $harness.Written[0].error.code "$variant uses the target change code"
            Assert-CcodEqual 0 $harness.ProbeCalls.Count "$variant never reaches Node work"
        }
    }

    Invoke-CcodTest 'rejects damaged settings before static probing' {
        foreach($variant in @('Null','Missing','Extra','WrongType','BadUtc','RelativeNode','WrongLeaf','NodeType','NoncanonicalNode')){
            $harness=New-CcodWorkerHarness -Root (Join-Path $root ('settings-'+$variant.ToLowerInvariant()))
            $settings=[pscustomobject][ordered]@{schemaVersion=1;automationEnabled=$true;candidateCompatibleOptIn=$true;nodeCandidates=@('C:\Node\node.exe');updatedAtUtc='2030-02-03T04:05:06.0000000Z'}
            switch -CaseSensitive ($variant) {
                'Null' {$settings=$null}
                'Missing' {[void]$settings.PSObject.Properties.Remove('nodeCandidates')}
                'Extra' {$settings|Add-Member -NotePropertyName path -NotePropertyValue 'C:\private'}
                'WrongType' {$settings.schemaVersion='1'}
                'BadUtc' {$settings.updatedAtUtc='2030-02-03T04:05:06Z'}
                'RelativeNode' {$settings.nodeCandidates=@('node.exe')}
                'WrongLeaf' {$settings.nodeCandidates=@('C:\Node\node.cmd')}
                'NodeType' {$settings.nodeCandidates=@(22)}
                'NoncanonicalNode' {$settings.nodeCandidates=@('C:\Node\..\Node\node.exe')}
            }
            $harness.Adapters.ReadSettings={$settings}.GetNewClosure()
            $run=Invoke-CcodStaticProbeWorker $harness.RequestPath $harness.ResultPath $harness.Adapters
            Assert-CcodEqual 1 $run.ExitCode "$variant settings fail closed"
            Assert-CcodEqual 'CCOD_STATIC_STATE_INVALID' $harness.Written[0].error.code "$variant settings use the state code"
            Assert-CcodEqual 0 $harness.ProbeCalls.Count "$variant settings never probe"
        }
    }

    Invoke-CcodTest 'maps empty Node Node21 version timeout and checker failures to operational failure only' {
        foreach($variant in @('EmptyCandidates','Node21','VersionTimeout','CheckerTimeout','CheckerExit','CheckerMalformed')){
            $probeCode=switch -CaseSensitive ($variant){'EmptyCandidates'{'NODE_NOT_FOUND'}'Node21'{'NODE_UNSUPPORTED'}'CheckerExit'{'CHECKER_EXIT_FAILED'}'CheckerMalformed'{'CHECKER_OUTPUT_INVALID'}default{'CHECKER_FAILED'}}
            $harness=New-CcodWorkerHarness -Root (Join-Path $root ('operational-'+$variant.ToLowerInvariant())) -ProbeCode $probeCode
            if($variant -ceq 'EmptyCandidates'){$harness.Adapters.ReadSettings={ [pscustomobject][ordered]@{schemaVersion=1;automationEnabled=$true;candidateCompatibleOptIn=$true;nodeCandidates=@();updatedAtUtc='2030-02-03T04:05:06.0000000Z'} }}
            if($variant -in @('VersionTimeout','CheckerTimeout')){$timeout=[Management.Automation.ErrorRecord]::new([TimeoutException]::new('private timeout'),'CCOD_STATIC_PROBE_TIMEOUT',[Management.Automation.ErrorCategory]::OperationTimeout,$null);$harness.Adapters.InvokeProbe={throw $timeout}.GetNewClosure()}
            $run=Invoke-CcodStaticProbeWorker $harness.RequestPath $harness.ResultPath $harness.Adapters
            Assert-CcodEqual 1 $run.ExitCode "$variant is an operational failure"
            Assert-CcodEqual $(if($variant -in @('VersionTimeout','CheckerTimeout')){'CCOD_STATIC_PROBE_TIMEOUT'}else{'CCOD_STATIC_PROBE_FAILED'}) $harness.Written[0].error.code "$variant has a bounded operational code"
            Assert-CcodEqual $null $harness.Written[0].probe "$variant never fabricates Unknown success"
        }
    }

    Invoke-CcodTest 'rejects independent post-probe active pointer and manifest hash drift' {
        foreach($variant in @('Pointer','Hash')){
            $harness=New-CcodWorkerHarness -Root (Join-Path $root ('post-runtime-'+$variant.ToLowerInvariant()))
            $after=Copy-CcodJsonObject $harness.Context
            if($variant -ceq 'Pointer'){$after.RuntimeId='runtime-2';$after.RuntimeRoot=$after.RuntimeRoot.Replace('runtime-1','runtime-2')}
            else{$after.AuthorizationId='auth-2'}
            $harness.Adapters.ReauthorizeRuntime={$after}.GetNewClosure()
            $run=Invoke-CcodStaticProbeWorker $harness.RequestPath $harness.ResultPath $harness.Adapters
            Assert-CcodEqual 1 $run.ExitCode "$variant drift fails closed"
            Assert-CcodEqual 'CCOD_STATIC_RUNTIME_UNAUTHORIZED' $harness.Written[0].error.code "$variant drift uses runtime authorization code"
        }
    }

    Invoke-CcodTest 'rejects unsafe framing paths and invalid requests without leaking untrusted correlation' {
        $harness=New-CcodWorkerHarness -Root (Join-Path $root 'paths')
        $outside=[IO.Path]::GetFullPath((Join-Path $root 'outside-result.json'))
        $run=Invoke-CcodStaticProbeWorker $harness.RequestPath $outside $harness.Adapters
        Assert-CcodEqual 1 $run.ExitCode 'out-of-root result fails'
        Assert-CcodEqual 0 $harness.Written.Count 'out-of-root result is never written'
        Assert-CcodEqual 0 $harness.Stdout.Count 'stdout requires an atomic result first'

        $bad=New-CcodWorkerRequest;$bad.action='staticprobe'
        $invalid=New-CcodWorkerHarness -Root (Join-Path $root 'invalid-request') -Request $bad
        $run=Invoke-CcodStaticProbeWorker $invalid.RequestPath $invalid.ResultPath $invalid.Adapters
        Assert-CcodEqual 1 $run.ExitCode 'invalid request exits nonzero'
        Assert-CcodEqual $null $invalid.Written[0].requestId 'invalid request does not echo request correlation'
        Assert-CcodEqual $null $invalid.Written[0].runtimeId 'invalid request does not echo runtime correlation'
        Assert-CcodEqual $null $invalid.Written[0].targetIdentity 'invalid request does not echo target correlation'
        Assert-CcodEqual 'The static probe worker failed safely.' $invalid.Written[0].error.message 'public error is fixed and sanitized'
    }

    Invoke-CcodTest 'atomic result failure emits no stdout and no raw callback data' {
        $harness=New-CcodWorkerHarness -Root (Join-Path $root 'write-failure') -WriteFailure $true
        $run=Invoke-CcodStaticProbeWorker $harness.RequestPath $harness.ResultPath $harness.Adapters
        Assert-CcodEqual 1 $run.ExitCode 'atomic failure exits nonzero'
        Assert-CcodEqual 0 $harness.Stdout.Count 'atomic failure emits zero stdout lines'
        Assert-CcodTrue (($harness.Events -join ',') -cnotmatch 'stdout') 'stdout is unreachable after atomic failure'
    }

    Invoke-CcodTest 'rejects every emitted stream from the atomic-result adapter without stdout or secret leakage' {
        foreach($stream in @('Error','Output','Warning','Verbose','Debug','Information')){
            $harness=New-CcodWorkerHarness -Root (Join-Path $root ('write-stream-'+$stream.ToLowerInvariant()))
            $inner=$harness.Adapters.WriteResult;$secret="SECRET_WRITE_STREAM_${stream}_C:\private\token.txt";$emit=New-CcodTestStreamEmitter $stream $secret
            $harness.Adapters.WriteResult={param($Path,$Value)& $emit;& $inner $Path $Value}.GetNewClosure()
            $emitted=@(Invoke-CcodStaticProbeWorker $harness.RequestPath $harness.ResultPath $harness.Adapters *>&1)
            Assert-CcodEqual 1 $emitted.Count "$stream callback stream is contained inside the worker"
            $run=$emitted[0]
            Assert-CcodEqual 1 $run.ExitCode "$stream callback stream fails closed"
            Assert-CcodEqual 0 $harness.Stdout.Count "$stream callback stream emits zero stdout lines"
            Assert-CcodTrue (-not (($emitted|Out-String).Contains($secret))) "$stream callback secret is never public"
        }
    }

    Invoke-CcodTest 'contains diagnostic streams at every worker orchestration adapter boundary' {
        $stages=@(
            'GetScriptPath','AuthorizeRuntime','GetItem','FileExists','DirectoryExists','ImportRuntime','CompleteRuntimeAuthorization','ReadRequest',
            'StartDeadline','ReadSettings','GetCurrentIdentity','GetParentProcessId','GetProcessIdentity','GetPackageIdentity','GetTargetSnapshot',
            'InvokeProbe','ReauthorizeRuntime','WriteStdout','WriteStderr'
        )
        foreach($name in $stages){
            $harness=New-CcodWorkerHarness -Root (Join-Path $root ('adapter-stream-'+$name.ToLowerInvariant())) -WriteFailure ($name -ceq 'WriteStderr')
            $secret="SECRET_ADAPTER_STREAM_${name}_C:\private\token.txt";$emit=New-CcodTestStreamEmitter 'Warning' $secret
            if($name -ceq 'GetItem'){$inner={param($Path)Get-Item -LiteralPath $Path -Force -ErrorAction Stop}}
            elseif($name -ceq 'FileExists'){$inner={param($Path)[IO.File]::Exists($Path)}}
            elseif($name -ceq 'DirectoryExists'){$inner={param($Path)[IO.Directory]::Exists($Path)}}
            else{$inner=$harness.Adapters[$name]}
            Assert-CcodTrue ($inner -is [scriptblock]) "$name test boundary exists"
            $harness.Adapters[$name]={& $emit;& $inner @args}.GetNewClosure()
            $emitted=@(Invoke-CcodStaticProbeWorker $harness.RequestPath $harness.ResultPath $harness.Adapters *>&1)
            Assert-CcodEqual 1 $emitted.Count "$name diagnostic stream is contained"
            Assert-CcodEqual 1 $emitted[0].ExitCode "$name diagnostic stream fails closed"
            Assert-CcodTrue (-not (($emitted|Out-String).Contains($secret))) "$name diagnostic secret is never public"
        }
    }

    Invoke-CcodTest 'owned Node timeout terminates only an identity-matched helper' {
        foreach($matches in @($true,$false)){
            $terminated=[Collections.Generic.List[int]]::new()
            $identityReads=[pscustomobject]@{Count=0}
            $expected='2030-02-03T03:02:00.0000000Z'
            $adapters=@{
                StartNode={param($Path,$Arguments)[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;Handle='fake';StdoutTask='stdout';StderrTask='stderr'}}.GetNewClosure()
                WaitNode={param($Owned,$Milliseconds)$false}
                GetProcessIdentity={param($Pid)$identityReads.Count++;if($matches -and $identityReads.Count -gt 1){$null}else{[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$(if($matches){$expected}else{'2030-02-03T03:02:01.0000000Z'});SessionId=1;UserSid=$script:WorkerSid}}}.GetNewClosure()
                TerminateNode={param($Owned)$terminated.Add($Owned.Pid);[pscustomobject][ordered]@{Pid=$Owned.Pid;CreationTimeUtc=$Owned.CreationTimeUtc;Exited=$true}}.GetNewClosure()
                FinishNode={param($Owned)[pscustomobject]@{ExitCode=1;Stdout='';Stderr=''}}
                DisposeNode={param($Owned)}
            }
            Assert-CcodThrows {Invoke-CcodStaticProbeOwnedNode -NodePath 'C:\Node\node.exe' -Arguments @('--version') -TimeoutMilliseconds 500 -Adapters $adapters|Out-Null} 'CCOD_STATIC_PROBE_TIMEOUT'
            Assert-CcodEqual $(if($matches){1}else{0}) $terminated.Count 'only the exact owned Node identity may be terminated'
        }
    }

    Invoke-CcodTest 'latches real wrapper timeouts even when Task4 catches version or checker adapter exceptions' {
        foreach($mode in @('Version','Checker','VersionDiagnostic')){
            $modeValue=[string]$mode;$expected='2030-02-03T03:02:00.0000000Z';$deadline=New-CcodStaticDeadline 500
            $calls=[pscustomobject]@{Task4=0;Start=0;Wait=0;Identity=0;Dispose=0;Caught=0;CaughtId=$null}
            Assert-CcodTrue ($deadline.PSObject.Properties.Name -ccontains 'TimedOut') 'deadline exposes an internal timeout latch'
            $owned=@{
                StartNode={param($Path,$Arguments)$calls.Start++;[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;Handle='fake';StdoutTask='stdout';StderrTask='stderr'}}.GetNewClosure()
                WaitNode={param($Owned,$Milliseconds)$calls.Wait++;$false}.GetNewClosure()
                GetProcessIdentity={param($Pid)$calls.Identity++;[pscustomobject][ordered]@{Pid=501;CreationTimeUtc='2030-02-03T03:02:01.0000000Z';SessionId=1;UserSid=$script:WorkerSid}}.GetNewClosure()
                TerminateNode={param($Owned)throw 'must not terminate a mismatched identity'}
                FinishNode={param($Owned)throw 'timeout cannot finish'}
                DisposeNode={param($Owned)$calls.Dispose++}.GetNewClosure()
            }
            $invokeStatic={param($NodeCandidates,$CheckerPath,$TaskAdapters)$calls.Task4++;try{if($modeValue.StartsWith('Version',[StringComparison]::Ordinal)){& $TaskAdapters.GetNodeVersion $NodeCandidates[0]|Out-Null}else{& $TaskAdapters.InvokeNode $NodeCandidates[0] @($CheckerPath)|Out-Null}}catch{$calls.Caught++;$calls.CaughtId=($_.FullyQualifiedErrorId -split ',')[0]};if($modeValue -ceq 'VersionDiagnostic'){Write-Warning 'private caught-timeout diagnostic'};[pscustomobject]@{Code='CHECKER_FAILED'}}.GetNewClosure()
            $failure=$null;try{Invoke-CcodStaticProbeWithDeadline -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Deadline $deadline -WorkerAdapters @{OwnedNodeAdapters=$owned} -InvokeStaticProbe $invokeStatic|Out-Null}catch{$failure=$_}
            Assert-CcodTrue ($null -ne $failure) "$modeValue caught timeout must escape Task4: timed=$($deadline.TimedOut) calls=$($calls|ConvertTo-Json -Compress)"
            Assert-CcodTrue ($failure.FullyQualifiedErrorId -like 'CCOD_STATIC_PROBE_TIMEOUT*') "$modeValue caught timeout keeps the public timeout ID"
            Assert-CcodEqual $true $deadline.TimedOut "$modeValue timeout remains latched after Task4 catches it"
            Assert-CcodEqual 'CCOD_STATIC_PROBE_TIMEOUT' $calls.CaughtId "$modeValue Task4 catches the real owned-helper timeout rather than a scope error"
        }
    }

    Invoke-CcodTest 'keeps deadline helper delegates bound when the worker is loaded in a child scope' {
        $workerSource=[IO.File]::ReadAllText($workerScript,[Text.UTF8Encoding]::new($false,$true))
        foreach($mode in @('Version','Checker')){
            $scopeResult=& {
                param($Source,$ModeValue,$WorkerSid)
                $loader=[scriptblock]::Create($Source);. $loader
                $expected='2030-02-03T03:02:00.0000000Z';$deadline=New-CcodStaticDeadline 500;$calls=[pscustomobject]@{Start=0};$caught=[pscustomobject]@{Id=$null}
                $owned=@{
                    StartNode={param($Path,$Arguments)$calls.Start++;[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;Handle='fake';StdoutTask='stdout';StderrTask='stderr'}}.GetNewClosure()
                    WaitNode={param($Owned,$Milliseconds)$false}
                    GetProcessIdentity={param($Pid)[pscustomobject][ordered]@{Pid=501;CreationTimeUtc='2030-02-03T03:02:01.0000000Z';SessionId=1;UserSid=$WorkerSid}}.GetNewClosure()
                    TerminateNode={param($Owned)throw 'must not terminate a mismatched identity'}
                    FinishNode={param($Owned)throw 'timeout cannot finish'}
                    DisposeNode={param($Owned)}
                }
                $task4={param($NodeCandidates,$CheckerPath,$TaskAdapters)try{if($ModeValue -ceq 'Version'){& $TaskAdapters.GetNodeVersion $NodeCandidates[0]|Out-Null}else{& $TaskAdapters.InvokeNode $NodeCandidates[0] @($CheckerPath)|Out-Null}}catch{$caught.Id=($_.FullyQualifiedErrorId -split ',')[0]};[pscustomobject]@{Code='CHECKER_FAILED'}}.GetNewClosure()
                $failure=$null;try{Invoke-CcodStaticProbeWithDeadline -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Deadline $deadline -WorkerAdapters @{OwnedNodeAdapters=$owned} -InvokeStaticProbe $task4|Out-Null}catch{$failure=$_}
                [pscustomobject][ordered]@{FailureId=$(if($null -eq $failure){$null}else{Get-CcodStaticProbeErrorId $failure});CaughtId=$caught.Id;TimedOut=$deadline.TimedOut;StartCalls=$calls.Start}
            } $workerSource ([string]$mode) ([string]$script:WorkerSid)
            Assert-CcodEqual 'CCOD_STATIC_PROBE_TIMEOUT' $scopeResult.FailureId "$mode child-scope timeout escapes Task4"
            Assert-CcodEqual 'CCOD_STATIC_PROBE_TIMEOUT' $scopeResult.CaughtId "$mode child-scope adapter invokes the real owned helper"
            Assert-CcodEqual $true $scopeResult.TimedOut "$mode child-scope timeout latch is set"
            Assert-CcodEqual 1 $scopeResult.StartCalls "$mode child-scope adapter reaches the owned helper"
        }
    }

    Invoke-CcodTest 'requires an exact confirmed Node termination receipt and post-exit identity check' {
        foreach($variant in @('TerminateThrows','ReceiptNotExited','ReceiptMismatch','StillRunning','ConfirmedExit')){
            $expected='2030-02-03T03:02:00.0000000Z';$calls=[pscustomobject]@{Identity=0;Terminate=0;Dispose=0}
            $adapters=@{
                StartNode={param($Path,$Arguments)[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;Handle='fake';StdoutTask='stdout';StderrTask='stderr'}}.GetNewClosure()
                WaitNode={param($Owned,$Milliseconds)$false}
                GetProcessIdentity={param($Pid)$calls.Identity++;if($calls.Identity -gt 1 -and $variant -ceq 'ConfirmedExit'){$null}else{[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;SessionId=1;UserSid=$script:WorkerSid}}}.GetNewClosure()
                TerminateNode={param($Owned)$calls.Terminate++;switch -CaseSensitive ($variant){'TerminateThrows'{throw 'private terminate failure'}'ReceiptNotExited'{[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;Exited=$false}}'ReceiptMismatch'{[pscustomobject][ordered]@{Pid=502;CreationTimeUtc=$expected;Exited=$true}}default{[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;Exited=$true}}}}.GetNewClosure()
                FinishNode={param($Owned)throw 'timeout cannot finish'}
                DisposeNode={param($Owned)$calls.Dispose++}.GetNewClosure()
            }
            $expectedCode=if($variant -ceq 'ConfirmedExit'){'CCOD_STATIC_PROBE_TIMEOUT'}else{'CCOD_STATIC_PROBE_FAILED'}
            Assert-CcodThrows {Invoke-CcodStaticProbeOwnedNode -NodePath 'C:\Node\node.exe' -Arguments @('--version') -TimeoutMilliseconds 500 -Adapters $adapters|Out-Null} $expectedCode
            Assert-CcodEqual 1 $calls.Terminate "$variant attempts one exact termination"
            Assert-CcodEqual 1 $calls.Dispose "$variant disposes the owned handle once"
        }
    }

    Invoke-CcodTest 'cleans every partial Node start after identity binding or by the exact unbound handle' {
        foreach($variant in @('ReadSetupFailure','IdentityRetry','IdentityReadUnavailable','IdentityUnavailable')){
            $expected='2030-02-03T03:02:00.0000000Z';$calls=[pscustomobject]@{Bind=0;Identity=0;Terminate=0;Unbound=0;Dispose=0}
            $adapters=@{
                CreateProcess={param($StartInfo)'fake-process'}
                StartProcess={param($Process)$true}
                GetStartedIdentity={param($Process)$calls.Bind++;if($variant -in @('ReadSetupFailure','IdentityReadUnavailable') -or ($variant -eq 'IdentityRetry' -and $calls.Bind -gt 1)){[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected}}else{throw 'private identity failure'}}.GetNewClosure()
                BeginRead={param($Process)throw 'private async read failure'}
                GetProcessIdentity={param($Pid)$calls.Identity++;if($variant -ceq 'IdentityReadUnavailable' -or $calls.Identity -gt 1){$null}else{[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;SessionId=1;UserSid=$script:WorkerSid}}}.GetNewClosure()
                TerminateStarted={param($Process,$Owned)$calls.Terminate++;[pscustomobject][ordered]@{Pid=$Owned.Pid;CreationTimeUtc=$Owned.CreationTimeUtc;Exited=$true}}.GetNewClosure()
                TerminateUnbound={param($Process)$calls.Unbound++;$true}.GetNewClosure()
                DisposeProcess={param($Process)$calls.Dispose++}.GetNewClosure()
            }
            Assert-CcodThrows {Start-CcodStaticOwnedNode -Path 'C:\Node\node.exe' -Arguments @('--version') -Adapters $adapters|Out-Null} 'CCOD_STATIC_PROBE_FAILED'
            Assert-CcodEqual 1 $calls.Dispose "$variant disposes the process handle once"
            Assert-CcodEqual $(if($variant -in @('IdentityReadUnavailable','IdentityUnavailable')){0}else{1}) $calls.Terminate "$variant uses bound cleanup only with an exact identity"
            Assert-CcodEqual $(if($variant -in @('IdentityReadUnavailable','IdentityUnavailable')){1}else{0}) $calls.Unbound "$variant uses exact-handle cleanup when identity binding or recheck is unavailable"
        }
    }

    Invoke-CcodTest 'contains all six diagnostic streams at every owned Node adapter boundary' {
        foreach($boundary in @('StartNode','WaitNode','GetProcessIdentity','TerminateNode','FinishNode','DisposeNode')){
            foreach($stream in @('Error','Output','Warning','Verbose','Debug','Information')){
                $boundaryValue=[string]$boundary;$streamValue=[string]$stream;$expected='2030-02-03T03:02:00.0000000Z';$reads=[pscustomobject]@{Count=0}
                $adapters=@{
                    StartNode={param($Path,$Arguments)[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;Handle='fake';StdoutTask='stdout';StderrTask='stderr'}}.GetNewClosure()
                    WaitNode={param($Owned,$Milliseconds)($boundaryValue -in @('FinishNode','DisposeNode'))}.GetNewClosure()
                    GetProcessIdentity={param($Pid)$reads.Count++;if($reads.Count -gt 1){$null}else{[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;SessionId=1;UserSid=$script:WorkerSid}}}.GetNewClosure()
                    TerminateNode={param($Owned)[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;Exited=$true}}.GetNewClosure()
                    FinishNode={param($Owned)[pscustomobject][ordered]@{ExitCode=0;Stdout='v22.23.1';Stderr=''}}
                    DisposeNode={param($Owned)}
                }
                $secret="SECRET_OWNED_NODE_${boundaryValue}_${streamValue}_C:\private\token.txt";$emit=New-CcodTestStreamEmitter $streamValue $secret;$inner=$adapters[$boundaryValue]
                $adapters[$boundaryValue]={& $emit;& $inner @args}.GetNewClosure()
                $failure=$null;try{Invoke-CcodStaticProbeOwnedNode -NodePath 'C:\Node\node.exe' -Arguments @('--version') -TimeoutMilliseconds 500 -Adapters $adapters|Out-Null}catch{$failure=$_}
                Assert-CcodTrue ($null -ne $failure) "$boundaryValue $streamValue stream fails closed"
                Assert-CcodTrue ($failure.FullyQualifiedErrorId -like 'CCOD_STATIC_PROBE_FAILED*') "$boundaryValue $streamValue stream maps to a fixed failure"
                Assert-CcodTrue (-not (($failure|Out-String).Contains($secret))) "$boundaryValue $streamValue stream does not leak"
            }
        }
    }

    Invoke-CcodTest 'contains all six diagnostic streams at every partial-start Node adapter boundary' {
        foreach($boundary in @('CreateProcess','StartProcess','GetStartedIdentity','BeginRead','GetProcessIdentity','TerminateStarted','TerminateUnbound','DisposeProcess')){
            foreach($stream in @('Error','Output','Warning','Verbose','Debug','Information')){
                $boundaryValue=[string]$boundary;$streamValue=[string]$stream;$expected='2030-02-03T03:02:00.0000000Z';$calls=[pscustomobject]@{Identity=0}
                $unbound=$boundaryValue -ceq 'TerminateUnbound';$cleanupPath=$boundaryValue -in @('GetProcessIdentity','TerminateStarted','TerminateUnbound','DisposeProcess')
                $adapters=@{
                    CreateProcess={param($StartInfo)'fake-process'}
                    StartProcess={param($Process)$true}
                    GetStartedIdentity={param($Process)if($unbound){throw 'private identity unavailable'};[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected}}.GetNewClosure()
                    BeginRead={param($Process)if($cleanupPath){throw 'private read setup failure'};[pscustomobject][ordered]@{StdoutTask='stdout';StderrTask='stderr'}}.GetNewClosure()
                    GetProcessIdentity={param($Pid)$calls.Identity++;if($calls.Identity -gt 1){$null}else{[pscustomobject][ordered]@{Pid=501;CreationTimeUtc=$expected;SessionId=1;UserSid=$script:WorkerSid}}}.GetNewClosure()
                    TerminateStarted={param($Process,$Owned)[pscustomobject][ordered]@{Pid=$Owned.Pid;CreationTimeUtc=$Owned.CreationTimeUtc;Exited=$true}}
                    TerminateUnbound={param($Process)$true}
                    DisposeProcess={param($Process)}
                }
                $secret="SECRET_NODE_START_${boundaryValue}_${streamValue}_C:\private\token.txt";$emit=New-CcodTestStreamEmitter $streamValue $secret;$inner=$adapters[$boundaryValue]
                $adapters[$boundaryValue]={& $emit;& $inner @args}.GetNewClosure()
                $failure=$null;try{Start-CcodStaticOwnedNode -Path 'C:\Node\node.exe' -Arguments @('--version') -Adapters $adapters|Out-Null}catch{$failure=$_}
                Assert-CcodTrue ($null -ne $failure) "$boundaryValue $streamValue stream fails closed"
                Assert-CcodTrue ($failure.FullyQualifiedErrorId -like 'CCOD_STATIC_PROBE_FAILED*') "$boundaryValue $streamValue stream maps to a fixed failure"
                Assert-CcodTrue (-not (($failure|Out-String).Contains($secret))) "$boundaryValue $streamValue stream does not leak"
            }
        }
    }

    Invoke-CcodTest 'AST exposes only the two CLI paths and no forbidden mutation surface' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($workerScript,[ref]$tokens,[ref]$errors)
        Assert-CcodEqual 0 @($errors).Count 'worker parses without errors'
        Assert-CcodEqual 'RequestPath,ResultPath' (($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)-join ',') 'production CLI exposes only framing paths'
        $forbidden=@('SessionEngine.psm1','TransitionJournal.psm1','SessionController.ps1','Invoke-CcodApplySession','Invoke-CcodRepairRenderer','Invoke-CcodRecoverSession','Start-CcodProcess','Stop-CcodProcessIfMatch','Start-Process','Stop-Process','Write-CcodSettings','Write-CcodStatus','Write-CcodVerifiedPackages','Set-CcodAutomationEnabled','Set-CcodCandidateCompatibleOptIn')
        $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
        foreach($name in $forbidden){Assert-CcodTrue ($commands -cnotcontains $name) "worker has no forbidden command $name"}
        $strings=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst]},$true)|ForEach-Object{$_.Value})
        foreach($module in @('SessionEngine.psm1','TransitionJournal.psm1','SessionController.ps1')){Assert-CcodTrue ($strings -cnotcontains $module) "worker never imports $module"}
    }
} catch {
    Write-Error $_
    exit 1
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
