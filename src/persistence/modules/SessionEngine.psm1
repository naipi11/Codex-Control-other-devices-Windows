Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $moduleRoot 'CompatibilityProbe.psm1') -Force
Import-Module (Join-Path $moduleRoot 'PersistenceIO.psm1') -Force
Import-Module (Join-Path $moduleRoot 'StateStore.psm1') -Force
Import-Module (Join-Path $moduleRoot 'ProcessControl.psm1') -Force
Import-Module (Join-Path $moduleRoot 'TransitionJournal.psm1') -Force

function Throw-CcodSessionError {
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message, $Target)
    $exception = [InvalidOperationException]::new($Message)
    $record = [Management.Automation.ErrorRecord]::new($exception, $Code, [Management.Automation.ErrorCategory]::InvalidData, $Target)
    throw $record
}

function Assert-CcodSessionExactProperties {
    param($Value, [string[]]$Expected, [string]$Code, [string]$Kind)
    if ($null -eq $Value -or ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary])) {
        Throw-CcodSessionError $Code "$Kind must be an exact object" $Value
    }
    $actual = @($Value.PSObject.Properties.Name)
    if ($Value -is [Collections.IDictionary]) { $actual = @($Value.Keys) }
    if ($actual.Count -ne $Expected.Count) { Throw-CcodSessionError $Code "$Kind fields are invalid" $Value }
    foreach ($name in $Expected) { if ($actual -cnotcontains $name) { Throw-CcodSessionError $Code "$Kind fields are invalid" $Value } }
}

function Test-CcodSessionCanonicalUtc([object]$Value) {
    if ($Value -isnot [string]) { return $false }
    $parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodSessionCanonicalGuid([object]$Value) {
    if ($Value -isnot [string]) { return $false }
    $parsed = [guid]::Empty
    return [guid]::TryParseExact($Value, 'D', [ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Assert-CcodSessionSnapshot {
    param($Snapshot)
    Assert-CcodSessionExactProperties $Snapshot @('Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName','CommandLine','ParentPid','IsTopLevel','Mode','RendererPort','MainPort') 'CCOD_REQUEST_INVALID' 'source'
    if (($Snapshot.Pid -isnot [int] -and $Snapshot.Pid -isnot [long]) -or $Snapshot.Pid -lt 1 -or $Snapshot.Pid -gt [int]::MaxValue -or
        -not (Test-CcodSessionCanonicalUtc $Snapshot.CreationTimeUtc) -or $Snapshot.SessionId -isnot [int] -or
        $Snapshot.UserSid -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.UserSid) -or
        $Snapshot.Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.Path) -or
        $Snapshot.PackageFamilyName -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.PackageFamilyName) -or
        $Snapshot.CommandLine -isnot [string] -or $Snapshot.IsTopLevel -isnot [bool] -or
        @('Ordinary','Special','Unrelated') -cnotcontains $Snapshot.Mode) {
        Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'source snapshot is invalid' $Snapshot
    }
    foreach ($name in @('RendererPort','MainPort')) {
        $value = $Snapshot.$name
        if ($null -ne $value -and (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 65535)) {
            Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'source snapshot port is invalid' $Snapshot
        }
    }
}

function Assert-CcodSessionRequest {
    param($Request, [string]$ExpectedAction)
    Assert-CcodSessionExactProperties $Request @('schemaVersion','action','transactionId','runtimeId','supervisorIdentity','source','existingOnly','rendererPort','mainPort','timeoutMilliseconds','restartOrdinary') 'CCOD_REQUEST_INVALID' 'request'
    if (($Request.schemaVersion -isnot [int] -and $Request.schemaVersion -isnot [long]) -or $Request.schemaVersion -ne 1 -or
        $Request.action -isnot [string] -or @('Inspect','Apply','RepairRenderer','Recover') -cnotcontains $Request.action -or
        $Request.action -cne $ExpectedAction -or -not (Test-CcodSessionCanonicalGuid $Request.transactionId) -or
        $Request.runtimeId -isnot [string] -or [string]::IsNullOrWhiteSpace($Request.runtimeId) -or
        $Request.existingOnly -isnot [bool] -or $Request.restartOrdinary -isnot [bool] -or
        ($Request.timeoutMilliseconds -isnot [int] -and $Request.timeoutMilliseconds -isnot [long]) -or
        $Request.timeoutMilliseconds -lt 500 -or $Request.timeoutMilliseconds -gt 120000) {
        Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'request scalar fields are invalid' $Request
    }
    Assert-CcodSessionExactProperties $Request.supervisorIdentity @('pid','creationTimeUtc','sessionId') 'CCOD_REQUEST_INVALID' 'supervisorIdentity'
    if (($Request.supervisorIdentity.pid -isnot [int] -and $Request.supervisorIdentity.pid -isnot [long]) -or
        $Request.supervisorIdentity.pid -lt 1 -or $Request.supervisorIdentity.pid -gt [int]::MaxValue -or
        -not (Test-CcodSessionCanonicalUtc $Request.supervisorIdentity.creationTimeUtc) -or
        $Request.supervisorIdentity.sessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($Request.supervisorIdentity.sessionId)) {
        Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'supervisorIdentity is invalid' $Request.supervisorIdentity
    }
    foreach ($name in @('rendererPort','mainPort')) {
        $value = $Request.$name
        if ($null -ne $value -and (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 65535)) {
            Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'request port is invalid' $Request
        }
    }
    if ($null -ne $Request.source) { Assert-CcodSessionSnapshot $Request.source }
    switch ($Request.action) {
        'Inspect' {
            if ($null -ne $Request.source -or -not $Request.existingOnly -or $null -ne $Request.rendererPort -or $null -ne $Request.mainPort -or -not $Request.restartOrdinary) {
                Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'Inspect fields are inconsistent' $Request
            }
        }
        'Apply' {
            if (($null -eq $Request.source -and $Request.existingOnly) -or -not $Request.restartOrdinary -or
                ($null -ne $Request.source -and (-not $Request.source.IsTopLevel -or $Request.source.Mode -cne 'Ordinary')) -or
                ($null -ne $Request.rendererPort -and $null -ne $Request.mainPort -and $Request.rendererPort -eq $Request.mainPort)) {
                Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'Apply fields are inconsistent' $Request
            }
        }
        'RepairRenderer' {
            if ($null -ne $Request.source -or -not $Request.existingOnly -or $null -ne $Request.rendererPort -or $null -ne $Request.mainPort -or -not $Request.restartOrdinary) {
                Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'RepairRenderer fields are inconsistent' $Request
            }
        }
        'Recover' {
            if ($null -ne $Request.source -or -not $Request.existingOnly -or $null -ne $Request.rendererPort -or $null -ne $Request.mainPort) {
                Throw-CcodSessionError 'CCOD_REQUEST_INVALID' 'Recover fields are inconsistent' $Request
            }
        }
    }
}

function Assert-CcodSessionPaths {
    param($Paths)
    Assert-CcodSessionExactProperties $Paths @('StateRoot','TransitionPath','TransitionLogPath','SessionLogPath','CheckerPath','OrchestratorPath','MainPayloadPath') 'CCOD_PATHS_INVALID' 'Paths'
    $values = [Collections.Generic.List[string]]::new()
    foreach ($name in @('StateRoot','TransitionPath','TransitionLogPath','SessionLogPath','CheckerPath','OrchestratorPath','MainPayloadPath')) {
        $value = $Paths.$name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or -not [IO.Path]::IsPathRooted($value)) {
            Throw-CcodSessionError 'CCOD_PATHS_INVALID' "Paths.$name must be absolute" $Paths
        }
        $canonical = [IO.Path]::GetFullPath($value)
        if ($canonical -cne $value -or $values -contains $canonical.ToLowerInvariant()) {
            Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'Paths must be canonical and non-colliding' $Paths
        }
        $cursor=if([IO.File]::Exists($canonical) -or [IO.Directory]::Exists($canonical)){$canonical}else{Split-Path -Parent $canonical}
        while(-not [string]::IsNullOrWhiteSpace($cursor)){
            if([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)){
                $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'Paths may not traverse reparse points' $cursor}
            }
            $parent=Split-Path -Parent $cursor;if($parent -ceq $cursor){break};$cursor=$parent
        }
        $values.Add($canonical.ToLowerInvariant())
    }
    $expectedTransition = [IO.Path]::GetFullPath((Join-Path $Paths.StateRoot 'transition.json'))
    if ($Paths.TransitionPath -cne $expectedTransition) { Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'TransitionPath must be StateRoot\transition.json' $Paths }
    $stateParent = Split-Path -Parent $Paths.StateRoot
    foreach ($name in @('TransitionLogPath','SessionLogPath')) {
        if (-not $Paths.$name.StartsWith($stateParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'Persistent paths must share the installed stable root' $Paths
        }
    }
    $runtimeRoot=Split-Path (Split-Path $Paths.CheckerPath -Parent) -Parent
    $expectedChecker=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\check-package.mjs'))
    $expectedOrchestrator=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\runtime\orchestrator.js'))
    $expectedPayload=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\runtime\main-payload.js'))
    if(-not $runtimeRoot.StartsWith($stateParent+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $Paths.CheckerPath -cne $expectedChecker -or $Paths.OrchestratorPath -cne $expectedOrchestrator -or $Paths.MainPayloadPath -cne $expectedPayload){
        Throw-CcodSessionError 'CCOD_PATHS_INVALID' 'Runtime payload paths must be exact children of one verified runtime root' $Paths
    }
}

function New-CcodSessionResult {
    param([string]$Action, $TransactionId)
    [pscustomobject][ordered]@{
        schemaVersion=1; action=$Action; ok=$false; outcome='Error'; safeState='Error'; stage='InputValidation'
        transactionId=$TransactionId; package=$null; source=$null; special=$null; probes=$null; recovery=$null; error=$null; logFile=$null
    }
}

function Get-CcodSessionErrorCode($Record) {
    $code = [string]$Record.FullyQualifiedErrorId
    if ($code.Contains(',')) { $code = $code.Split(',')[0] }
    if ([string]::IsNullOrWhiteSpace($code) -or $code -cnotmatch '^(CCOD_|BRIDGE_)') { return 'CCOD_SESSION_FAILED' }
    return $code
}

function Set-CcodSessionFailure($Result, $Record, [string]$Stage) {
    $Result.ok=$false; $Result.outcome='Error'; $Result.safeState='Error'; $Result.stage=$Stage
    $Result.error=[pscustomobject][ordered]@{ code=(Get-CcodSessionErrorCode $Record); stage=$Stage; message='The session operation failed safely. See the session log for details.' }
    return $Result
}

function Write-CcodSessionDiagnostic {
    param($Result,[string]$Action,[string]$TransactionId,[string]$Stage,[string]$Code,$Paths,[hashtable]$Adapter)
    if($null -eq $Paths -or $null -eq $Adapter -or $null -eq $Adapter.WriteLog){return}
    $record=[pscustomobject][ordered]@{schemaVersion=1;timestampUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture);action=$Action;transactionId=$TransactionId;stage=$Stage;code=$Code}
    try{& $Adapter.WriteLog $Paths.SessionLogPath ($record|ConvertTo-Json -Depth 4 -Compress)|Out-Null;$Result.logFile=$Paths.SessionLogPath}catch{}
}

function ConvertTo-CcodSessionPackage($Probe) {
    if ($null -eq $Probe) { return $null }
    [pscustomobject][ordered]@{ fullName=$Probe.PackageFullName; familyName=$Probe.PackageFamilyName; version=$Probe.PackageVersion; appAsarSha256=$Probe.AppAsarSha256 }
}

function ConvertTo-CcodSessionSource($Snapshot) {
    if ($null -eq $Snapshot) { return $null }
    [pscustomobject][ordered]@{ pid=[int]$Snapshot.Pid; creationTimeUtc=$Snapshot.CreationTimeUtc }
}

function ConvertTo-CcodSessionSpecial($Snapshot) {
    if ($null -eq $Snapshot) { return $null }
    [pscustomobject][ordered]@{ pid=[int]$Snapshot.Pid; creationTimeUtc=$Snapshot.CreationTimeUtc; rendererPort=$Snapshot.RendererPort; mainPort=$Snapshot.MainPort }
}

function ConvertTo-CcodPublicBridgeProbes {
    param($Bridge,[ValidateSet('Full','Renderer')][string]$Mode)
    $renderer=[pscustomobject][ordered]@{targetUrl=$Bridge.renderer.targetUrl;currentDocument=[pscustomobject][ordered]@{installed=[bool]$Bridge.renderer.currentDocument.installed};newDocumentScriptInstalled=[bool]$Bridge.renderer.newDocumentScriptInstalled;probe=[pscustomobject][ordered]@{proof=[bool]$Bridge.renderer.probe.proof;targetGate=$Bridge.renderer.probe.targetGate}}
    if($Mode -ceq 'Renderer'){return [pscustomobject][ordered]@{renderer=$renderer}}
    $main=[pscustomobject][ordered]@{inspectorPortClosed=[pscustomobject][ordered]@{confirmed=[bool]$Bridge.main.inspectorPortClosed.confirmed;code=$Bridge.main.inspectorPortClosed.code}}
    return [pscustomobject][ordered]@{main=$main;renderer=$renderer}
}

function Invoke-CcodSessionBridge {
    param(
        [ValidateSet('Full','Renderer')][string]$Mode,
        [string]$NodePath,
        $Paths,
        [int]$RendererPort,
        [AllowNull()][Nullable[int]]$MainPort,
        [int]$TimeoutMilliseconds,
        [hashtable]$Adapter
    )
    $arguments=@($Paths.OrchestratorPath,'--mode',$Mode.ToLowerInvariant(),'--renderer-port',[string]$RendererPort,'--timeout-ms',[string]$TimeoutMilliseconds)
    if($Mode -ceq 'Full'){
        $arguments+=@('--main-port',[string]$MainPort,'--main-payload',$Paths.MainPayloadPath)
    }
    $invocation=& $Adapter.InvokeNode $NodePath $arguments
    return Test-CcodBridgeResult -Mode $Mode -Invocation $invocation
}

function Test-CcodReplaySpecialRoot {
    param($Snapshot,$Transition,$Probe,$Request,[hashtable]$Adapter,[switch]$RequireRecordedIdentity)
    if($null -eq $Snapshot){return $false}
    $identity=& $Adapter.CurrentIdentity
    if(-not $Snapshot.IsTopLevel -or [string]$Snapshot.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or
        [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or $Snapshot.UserSid -cne $identity.UserSid -or
        -not $Snapshot.Path.Equals($Probe.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or $Snapshot.PackageFamilyName -cne $Probe.PackageFamilyName -or
        $Snapshot.RendererPort -ne $Transition.rendererPort -or $Snapshot.MainPort -ne $Transition.mainPort){return $false}
    if($RequireRecordedIdentity -and ($Snapshot.Pid -ne $Transition.specialPid -or $Snapshot.CreationTimeUtc -cne $Transition.specialCreationTimeUtc)){return $false}
    if(-not $RequireRecordedIdentity -and [DateTime]::Parse($Snapshot.CreationTimeUtc).ToUniversalTime() -lt [DateTime]::Parse($Transition.createdAtUtc).ToUniversalTime()){return $false}
    return $true
}

function Get-CcodStageAwareSpecialObservation {
    param($Transition,$State,$Probe,$Request,$Paths,[hashtable]$Adapter)
    $candidate=$null;$outcome='NoCandidate';$conflicts=@();$validation='Indeterminate';$bridge=$null;$mode=$null
    if($Transition.stage -ceq 'SpecialLaunchRequested'){
        $raw=& $Adapter.ObserveSpecial $Transition $Paths $Request.timeoutMilliseconds
        $outcome=$raw.Outcome;$conflicts=@($raw.ConflictOwners);$candidates=@($raw.Candidates)
        if($candidates.Count -eq 0 -and $null -ne $raw.Snapshot){$candidates=@($raw.Snapshot)}
        if($outcome -ceq 'Confirmed' -and $candidates.Count -eq 1 -and $conflicts.Count -eq 0){$candidate=$candidates[0]}
        if($null -ne $candidate -and (Test-CcodReplaySpecialRoot $candidate $Transition $Probe $Request $Adapter)){
            $mode='Full'
            try{$bridge=Invoke-CcodSessionBridge -Mode Full -NodePath $Probe.NodePath -Paths $Paths -RendererPort $Transition.rendererPort -MainPort $Transition.mainPort -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $Adapter;$validation='Valid'}catch{$validation='Invalid'}
        }elseif($null -ne $candidate){$validation='Invalid'}
    } else {
        $candidate=& $Adapter.GetProcess $Transition.specialPid $State.Status
        if($null -ne $candidate){$outcome='Confirmed'}
        if($null -ne $candidate -and (Test-CcodReplaySpecialRoot $candidate $Transition $Probe $Request $Adapter -RequireRecordedIdentity)){
            $mainClosed=& $Adapter.WaitPortClosed $Transition.mainPort (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds)
            if($Transition.stage -ceq 'SpecialStarted' -and -not $mainClosed){$mode='Full'}elseif($mainClosed){$mode='Renderer'}
            if($null -ne $mode){
                try{$bridge=Invoke-CcodSessionBridge -Mode $mode -NodePath $Probe.NodePath -Paths $Paths -RendererPort $Transition.rendererPort -MainPort $(if($mode -ceq 'Full'){$Transition.mainPort}else{$null}) -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $Adapter;$validation='Valid'}catch{$validation='Invalid'}
            }else{$validation='Invalid'}
        }elseif($null -ne $candidate){$validation='Invalid'}
    }
    return [pscustomobject]@{Outcome=$outcome;Snapshot=$candidate;Candidates=if($null -eq $candidate){@()}else{@($candidate)};ConflictOwners=@($conflicts);Validation=$validation;Bridge=$bridge;BridgeMode=$mode}
}

function Complete-CcodActivatedReplay {
    param($Result,$Request,$Paths,[hashtable]$Adapter,$Probe,$Special,$Bridge,[string]$JournalTransactionId)
    $status=[pscustomobject][ordered]@{schemaVersion=1;session=[pscustomobject][ordered]@{supervisorPid=[int]$Request.supervisorIdentity.pid;supervisorCreationTimeUtc=$Request.supervisorIdentity.creationTimeUtc;sessionId=$Request.supervisorIdentity.sessionId;runtimeId=$Request.runtimeId;sessionState='Active';codex=[pscustomobject][ordered]@{pid=[int]$Special.Pid;creationTimeUtc=$Special.CreationTimeUtc;packageFullName=$Probe.PackageFullName;packageVersion=$Probe.PackageVersion;appAsarSha256=$Probe.AppAsarSha256;mainPort=[int]$Special.MainPort;rendererPort=[int]$Special.RendererPort;mainProbe='Closed';rendererProbe='BridgeValid'}}}
    $live=[pscustomobject][ordered]@{Valid=$true;runtimeId=$Request.runtimeId;pid=[int]$Special.Pid;creationTimeUtc=$Special.CreationTimeUtc;packageFullName=$Probe.PackageFullName;packageVersion=$Probe.PackageVersion;appAsarSha256=$Probe.AppAsarSha256;mainPort=[int]$Special.MainPort;rendererPort=[int]$Special.RendererPort;mainProbe='Closed';rendererProbe='BridgeValid'}
    & $Adapter.WriteStatus $Paths.StateRoot $status $live
    $verified=& $Adapter.ReadVerified $Paths.StateRoot;$succeeded=New-CcodVerifiedStoreWithRecord $verified $Probe $Request.runtimeId 'Succeeded' 'Valid' (& $Adapter.UtcNow);& $Adapter.WriteVerified $Paths.StateRoot $succeeded
    & $Adapter.CompleteTransition $Paths.TransitionPath $Paths.TransitionLogPath $JournalTransactionId 'Activated'|Out-Null
    $Result.special=ConvertTo-CcodSessionSpecial $Special
    if($null -ne $Bridge){$mode=if($null -ne $Bridge.PSObject.Properties['main']){'Full'}else{'Renderer'};$Result.probes=ConvertTo-CcodPublicBridgeProbes $Bridge $mode}
    $Result.ok=$true;$Result.outcome='NoAction';$Result.safeState='SpecialValidated';$Result.stage='Activated';return $Result
}

function Complete-CcodRecoveredReplay {
    param($Result,$Request,$Paths,[hashtable]$Adapter,$Probe,$Ordinary,[string]$JournalTransactionId)
    & $Adapter.WriteStatus $Paths.StateRoot ([pscustomobject][ordered]@{schemaVersion=1;session=$null}) $null
    $store=& $Adapter.ReadVerified $Paths.StateRoot;$failed=New-CcodVerifiedStoreWithRecord $store $Probe $Request.runtimeId 'Failed' 'NotRun' (& $Adapter.UtcNow);& $Adapter.WriteVerified $Paths.StateRoot $failed
    & $Adapter.CompleteTransition $Paths.TransitionPath $Paths.TransitionLogPath $JournalTransactionId 'Recovered'|Out-Null
    $ignore=Get-CcodRecoveryIgnoreKey -Pid $Ordinary.Pid -CreationTimeUtc $Ordinary.CreationTimeUtc -TransactionId $JournalTransactionId
    $suppression=Get-CcodSuppressionKey -PackageFullName $Probe.PackageFullName -AppAsarSha256 $Probe.AppAsarSha256 -RuntimeId $Request.runtimeId
    $Result.source=ConvertTo-CcodSessionSource $Ordinary;$Result.special=$null
    $Result.recovery=[pscustomobject][ordered]@{pid=[int]$Ordinary.Pid;creationTimeUtc=$Ordinary.CreationTimeUtc;ignoreKey=$ignore;suppressionKey=$suppression;portsClosed=$true;disposition='ReplayAdopted';priorTransactionId=$JournalTransactionId}
    $Result.ok=$true;$Result.outcome='Recovered';$Result.safeState='OrdinaryRunning';$Result.stage='Recovered';return $Result
}

function ConvertTo-CcodJournalPackage($Probe) {
    [pscustomobject][ordered]@{
        FullName=$Probe.PackageFullName; FamilyName=$Probe.PackageFamilyName; Version=$Probe.PackageVersion
        InstallLocation='Unavailable'; ExecutablePath=$Probe.ExecutablePath; AppAsarPath='Unavailable'; NativeDirectory='Unavailable'
        AppAsarSha256=$Probe.AppAsarSha256; StaticClassification=$Probe.StaticClassification; SignatureState='Valid'; NodePath=$Probe.NodePath
    }
}

function New-CcodVerifiedStoreWithRecord {
    param($Store,$Probe,[string]$RuntimeId,[ValidateSet('Succeeded','Failed')][string]$Outcome,[ValidateSet('Valid','Invalid','NotRun')][string]$ProbeState,[datetime]$UtcNow)
    $packages=[ordered]@{}
    if($null -ne $Store -and $null -ne $Store.packages){
        foreach($property in $Store.packages.PSObject.Properties){$packages[$property.Name]=$property.Value}
        if($Store.packages -is [Collections.IDictionary]){foreach($key in $Store.packages.Keys){$packages[$key]=$Store.packages[$key]}}
    }
    $key=Get-CcodSuppressionKey -PackageFullName $Probe.PackageFullName -AppAsarSha256 $Probe.AppAsarSha256 -RuntimeId $RuntimeId
    $packages[$key]=[pscustomobject][ordered]@{
        packageFullName=$Probe.PackageFullName;packageVersion=$Probe.PackageVersion;appAsarSha256=$Probe.AppAsarSha256;runtimeId=$RuntimeId
        staticClassification=$Probe.StaticClassification;dynamicOutcome=$Outcome;probeState=$ProbeState
        confirmedAtUtc=$UtcNow.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    }
    return [pscustomobject][ordered]@{schemaVersion=1;packages=[pscustomobject]$packages}
}

function Get-CcodTreeDepth {
    param($Snapshot,[hashtable]$ByPid)
    $depth=0;$seen=@{};$cursor=$Snapshot
    while($null -ne $cursor.ParentPid -and $ByPid.ContainsKey([int]$cursor.ParentPid) -and -not $seen.ContainsKey([int]$cursor.ParentPid)){
        $seen[[int]$cursor.ParentPid]=$true;$depth++;$cursor=$ByPid[[int]$cursor.ParentPid]
    }
    return $depth
}

function Get-CcodChildFirstVerifiedTree {
    param($Root,$StatusEvidence,[hashtable]$Adapter)
    $tree=@(& $Adapter.GetTree $Root $StatusEvidence)
    if($tree.Count -lt 1){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recorded special tree could not be verified' $Root}
    $byPid=@{};foreach($member in $tree){$byPid[[int]$member.Pid]=$member}
    if(-not $byPid.ContainsKey([int]$Root.Pid)){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Verified tree omitted the recorded root' $Root}
    return @($tree|Sort-Object @{Expression={-(Get-CcodTreeDepth $_ $byPid)}},@{Expression={$_.Pid}})
}

function Get-CcodProcessControlTimeout([int]$TimeoutMilliseconds) {
    return [Math]::Min(60000,$TimeoutMilliseconds)
}

function Get-CcodCurrentPackageRoots {
    param($StatusEvidence,$Probe,$Request,[hashtable]$Adapter)
    $identity=& $Adapter.CurrentIdentity
    if($null -eq $identity -or [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or [string]::IsNullOrWhiteSpace([string]$identity.UserSid)){
        Throw-CcodSessionError 'CCOD_SOURCE_AMBIGUOUS' 'The request supervisor does not match the current Windows session identity' $Request.supervisorIdentity
    }
    return @(& $Adapter.ListProcesses $StatusEvidence|Where-Object{
        $_.IsTopLevel -and
        [string]$_.SessionId -ceq [string]$Request.supervisorIdentity.sessionId -and
        $_.UserSid -ceq $identity.UserSid -and
        $_.Path.Equals($Probe.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -and
        $_.PackageFamilyName -ceq $Probe.PackageFamilyName
    }|Sort-Object CreationTimeUtc,Pid)
}

function Find-CcodOrdinarySnapshot {
    param($StatusEvidence,[hashtable]$Adapter)
    $candidates=@(& $Adapter.ListProcesses $StatusEvidence|Where-Object{$_.IsTopLevel -and $_.Mode -ceq 'Ordinary'}|Sort-Object CreationTimeUtc,Pid)
    if($candidates.Count -gt 0){return $candidates[0]}
    return $null
}

function Wait-CcodOrdinarySnapshot {
    param($StatusEvidence,[hashtable]$Adapter)
    for($index=0;$index -lt 5;$index++){
        $candidate=Find-CcodOrdinarySnapshot $StatusEvidence $Adapter;if($null -ne $candidate){return $candidate}
        & $Adapter.Delay 1000
    }
    return Find-CcodOrdinarySnapshot $StatusEvidence $Adapter
}

function Invoke-CcodRecoveryOperation {
    param($Result,$Request,$Paths,[hashtable]$Adapter,$State,$Probe,[string]$CurrentStage,$Special,$RendererPort,$MainPort,[string]$PriorTransactionId)
    $Result.stage='Recovery';$processTimeout=Get-CcodProcessControlTimeout $Request.timeoutMilliseconds
    if($null -ne $Special){
        $tree=Get-CcodChildFirstVerifiedTree $Special $State.Status $Adapter
        foreach($member in $tree){
            $current=& $Adapter.GetProcess $member.Pid $State.Status
            if($null -eq $current){continue}
            if(-not (& $Adapter.ProcessMatch $member $current)){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Verified tree identity changed before stop' $member}
            $receipt=& $Adapter.StopProcess $member $State.Status $processTimeout
            if($receipt.Outcome -cne 'Stopped' -and $receipt.Outcome -cne 'SourceExited'){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'A verified tree member did not stop safely' $member}
        }
    }
    $portsClosed=$true
    if($null -ne $RendererPort -and $null -ne $MainPort){
        foreach($port in @($RendererPort,$MainPort)){if(-not (& $Adapter.WaitPortClosed $port $processTimeout)){$portsClosed=$false}}
    }
    if(-not $portsClosed){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recorded debug ports did not explicitly refuse' $Special}
    if($CurrentStage -cne 'RecoveryLaunchRequested'){
        $transition=& $Adapter.SetTransition $Paths.TransitionPath $PriorTransactionId $CurrentStage 'RecoveryLaunchRequested' $null $null $null $null
    }
    $ordinary=Wait-CcodOrdinarySnapshot $State.Status $Adapter;$disposition='AdoptedDuringObservation'
    if($null -eq $ordinary){
        $start=& $Adapter.StartOrdinary $processTimeout
        $disposition='LaunchedOnce'
        if($null -ne $start.Snapshot){$ordinary=$start.Snapshot}else{$ordinary=Wait-CcodOrdinarySnapshot $State.Status $Adapter}
    }
    if($null -eq $ordinary -or $ordinary.Mode -cne 'Ordinary' -or -not $ordinary.IsTopLevel){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Ordinary recovery identity was not proven' $ordinary}
    $transition=& $Adapter.SetTransition $Paths.TransitionPath $PriorTransactionId 'RecoveryLaunchRequested' 'Recovered' $null $ordinary $null $null
    $store=& $Adapter.ReadVerified $Paths.StateRoot
    $failed=New-CcodVerifiedStoreWithRecord $store $Probe $Request.runtimeId 'Failed' 'NotRun' (& $Adapter.UtcNow)
    & $Adapter.WriteVerified $Paths.StateRoot $failed
    & $Adapter.WriteStatus $Paths.StateRoot ([pscustomobject][ordered]@{schemaVersion=1;session=$null}) $null
    & $Adapter.CompleteTransition $Paths.TransitionPath $Paths.TransitionLogPath $PriorTransactionId 'Recovered'|Out-Null
    $ignore=Get-CcodRecoveryIgnoreKey -Pid $ordinary.Pid -CreationTimeUtc $ordinary.CreationTimeUtc -TransactionId $PriorTransactionId
    $suppression=Get-CcodSuppressionKey -PackageFullName $Probe.PackageFullName -AppAsarSha256 $Probe.AppAsarSha256 -RuntimeId $Request.runtimeId
    $Result.recovery=[pscustomobject][ordered]@{pid=[int]$ordinary.Pid;creationTimeUtc=$ordinary.CreationTimeUtc;ignoreKey=$ignore;suppressionKey=$suppression;portsClosed=$portsClosed;disposition=$disposition;priorTransactionId=$PriorTransactionId}
    $Result.ok=$true;$Result.outcome='Recovered';$Result.safeState='OrdinaryRunning';$Result.stage='Recovered';$Result.special=$null
    return $Result
}

function Invoke-CcodCloseVerifiedTree {
    param([object[]]$Tree,$StatusEvidence,[hashtable]$Adapter,[int]$TimeoutMilliseconds,$RendererPort,$MainPort)
    if($Tree.Count -lt 1){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close target tree was not verified' $null}
    $processTimeout=Get-CcodProcessControlTimeout $TimeoutMilliseconds
    $byPid=@{};foreach($member in $Tree){$byPid[[int]$member.Pid]=$member}
    $ordered=@($Tree|Sort-Object @{Expression={-(Get-CcodTreeDepth $_ $byPid)}},@{Expression={$_.Pid}})
    foreach($member in $ordered){
        $current=& $Adapter.GetProcess $member.Pid $StatusEvidence
        if($null -eq $current){continue}
        if(-not (& $Adapter.ProcessMatch $member $current)){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close tree identity changed before stop' $member}
        $receipt=& $Adapter.StopProcess $member $StatusEvidence $processTimeout
        if($receipt.Outcome -cne 'Stopped' -and $receipt.Outcome -cne 'SourceExited'){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close tree member did not stop safely' $member}
    }
    foreach($member in $Tree){
        $current=& $Adapter.GetProcess $member.Pid $StatusEvidence
        if($null -ne $current -and (& $Adapter.ProcessMatch $member $current)){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close tree member remains alive after stop' $member}
    }
    if($null -ne $RendererPort -and $null -ne $MainPort){
        foreach($port in @($RendererPort,$MainPort)){if(-not (& $Adapter.WaitPortClosed $port $processTimeout)){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'A recorded close port did not explicitly refuse' $port}}
    }
}

function Complete-CcodCloseResult {
    param($Result,$Paths,[hashtable]$Adapter,[string]$JournalTransactionId)
    & $Adapter.WriteStatus $Paths.StateRoot ([pscustomobject][ordered]@{schemaVersion=1;session=$null}) $null
    & $Adapter.CompleteTransition $Paths.TransitionPath $Paths.TransitionLogPath $JournalTransactionId 'Closed'|Out-Null
    $Result.ok=$true;$Result.outcome='Closed';$Result.safeState='Closed';$Result.stage='Closed';$Result.special=$null
    return $Result
}

function Merge-CcodSessionAdapters($Adapters) {
    $defaults = @{
        ReadState={ param($StateRoot,$SuppressionKey) Read-CcodState -StateRoot $StateRoot -CurrentSuppressionKey $SuppressionKey }
        StaticProbe={ param($NodeCandidates,$CheckerPath) Invoke-CcodStaticProbe -NodeCandidates $NodeCandidates -CheckerPath $CheckerPath }
        ListProcesses={ param($StatusEvidence)
            $current=[Diagnostics.Process]::GetCurrentProcess();try{$sessionId=$current.SessionId}finally{$current.Dispose()}
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$identity.User.Value}finally{$identity.Dispose()}
            $snapshots=[Collections.Generic.List[object]]::new()
            foreach($process in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)){
                $snapshot=Get-CcodProcessSnapshot -ProcessId $process.Id -StatusEvidence $StatusEvidence
                if($null -ne $snapshot -and $snapshot.SessionId -eq $sessionId -and $snapshot.UserSid -ceq $sid){$snapshots.Add($snapshot)}
            }
            return $snapshots.ToArray()
        }
        GetProcess={ param($Pid,$StatusEvidence) Get-CcodProcessSnapshot -ProcessId $Pid -StatusEvidence $StatusEvidence }
        ProcessMatch={ param($Expected,$Actual) Test-CcodProcessMatch -Expected $Expected -Actual $Actual }
        NewTransition={ param($Path,$Source,$Package,$RuntimeId,$RendererPort,$MainPort,$TransactionId) New-CcodTransition -Path $Path -Source $Source -Package $Package -RuntimeId $RuntimeId -RendererPort $RendererPort -MainPort $MainPort -TransactionId $TransactionId }
        SetTransition={ param($Path,$TransactionId,$ExpectedStage,$NewStage,$SpecialIdentity,$RecoveryIdentity,$RendererPort,$MainPort)
            $parameters=@{Path=$Path;TransactionId=$TransactionId;ExpectedStage=$ExpectedStage;NewStage=$NewStage}
            if($null -ne $SpecialIdentity){$parameters.SpecialIdentity=$SpecialIdentity}; if($null -ne $RecoveryIdentity){$parameters.RecoveryIdentity=$RecoveryIdentity}
            if($null -ne $RendererPort){$parameters.RendererPort=$RendererPort}; if($null -ne $MainPort){$parameters.MainPort=$MainPort}; Set-CcodTransitionStage @parameters }
        CompleteTransition={ param($Path,$LogPath,$TransactionId,$Disposition) Complete-CcodTransition -Path $Path -LogPath $LogPath -TransactionId $TransactionId -Disposition $Disposition }
        StopProcess={ param($Expected,$StatusEvidence,$TimeoutMilliseconds) Stop-CcodProcessIfMatch -Expected $Expected -StatusEvidence $StatusEvidence -TimeoutMilliseconds $TimeoutMilliseconds }
        GetPort={ param($Excluded) Get-CcodAvailableLoopbackPort -ExcludedPorts $Excluded }
        StartSpecial={ param($RendererPort,$MainPort,$TimeoutMilliseconds) Start-CcodProcess -Mode Special -RendererPort $RendererPort -MainPort $MainPort -StartupTimeoutMilliseconds $TimeoutMilliseconds }
        InvokeNode={ param($NodePath,$Arguments)
            $stderrPath=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ccod-node-$([guid]::NewGuid().ToString('N')).err")))
            try{$output=@(& $NodePath @Arguments 2>$stderrPath);$exitCode=$LASTEXITCODE;$stderr=if([IO.File]::Exists($stderrPath)){[IO.File]::ReadAllText($stderrPath)}else{''}}
            finally{if([IO.File]::Exists($stderrPath)){[IO.File]::Delete($stderrPath)}}
            [pscustomobject][ordered]@{ExitCode=$exitCode;Stdout=($output -join "`n");Stderr=$stderr}
        }
        WriteStatus={ param($StateRoot,$Status,$LiveProbe) Write-CcodStatus -StateRoot $StateRoot -Status $Status -LiveProbeResult $LiveProbe }
        ReadVerified={ param($StateRoot) Read-CcodVerifiedPackages -StateRoot $StateRoot }
        WriteVerified={ param($StateRoot,$Verified) Write-CcodVerifiedPackages -StateRoot $StateRoot -VerifiedPackages $Verified }
        UtcNow={ [DateTime]::UtcNow }
        GetTree={ param($Root,$StatusEvidence) Get-CcodVerifiedProcessTree -Root $Root -StatusEvidence $StatusEvidence }
        WaitPortClosed={ param($Port,$TimeoutMilliseconds) Wait-CcodPortClosed -Port $Port -TimeoutMilliseconds $TimeoutMilliseconds }
        StartOrdinary={ param($TimeoutMilliseconds) Start-CcodProcess -Mode Ordinary -StartupTimeoutMilliseconds $TimeoutMilliseconds }
        Delay={ param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
        WriteLog={ param($Path,$Message) Write-CcodRotatingLog -Path $Path -Message $Message }
        ObserveSpecial={ param($Transition,$Paths,$TimeoutMilliseconds)
            if($null -eq $Transition.mainPort){return [pscustomobject]@{Outcome='NoCandidate';Snapshot=$null;Candidates=@();ConflictOwners=@();Validation='Indeterminate'}}
            $observation=Get-CcodTransactionProcessResult -RendererPort $Transition.rendererPort -MainPort $Transition.mainPort -TransactionTimeUtc $Transition.createdAtUtc
            $validation=if($null -ne $observation.Snapshot -and $observation.Snapshot.Mode -ceq 'Special'){'Valid'}else{'Indeterminate'}
            return [pscustomobject]@{Outcome=$observation.Outcome;Snapshot=$observation.Snapshot;Candidates=@($observation.Candidates);ConflictOwners=@($observation.ConflictOwners);Validation=$validation}
        }
        ObserveSpecialIsDefault=$true
        CurrentIdentity={
            $current=[Diagnostics.Process]::GetCurrentProcess();try{$sessionId=[string]$current.SessionId}finally{$current.Dispose()}
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$identity.User.Value}finally{$identity.Dispose()}
            [pscustomobject][ordered]@{SessionId=$sessionId;UserSid=$sid}
        }
    }
    if ($null -ne $Adapters) {
        foreach($key in $Adapters.Keys){$defaults[$key]=$Adapters[$key]}
        if($Adapters.ContainsKey('ObserveSpecial') -and -not $Adapters.ContainsKey('ObserveSpecialIsDefault')){$defaults.ObserveSpecialIsDefault=$false}
    }
    return $defaults
}

function Test-CcodBridgeResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Full','Renderer')][string]$Mode, [Parameter(Mandatory)]$Invocation)
    Assert-CcodSessionExactProperties $Invocation @('ExitCode','Stdout','Stderr') 'BRIDGE_PROOF_INCOMPLETE' 'bridge invocation'
    if (($Invocation.ExitCode -isnot [int] -and $Invocation.ExitCode -isnot [long]) -or $Invocation.ExitCode -ne 0 -or $Invocation.Stdout -isnot [string] -or $Invocation.Stderr -isnot [string]) {
        Throw-CcodSessionError 'BRIDGE_PROOF_INCOMPLETE' 'Bridge process did not return a successful framed result' $Invocation
    }
    try { $parsed = $Invocation.Stdout | ConvertFrom-Json -ErrorAction Stop } catch { Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Bridge stdout is not one JSON object' $Invocation }
    if ($null -eq $parsed -or $parsed -is [array]) { Throw-CcodSessionError 'CCOD_BRIDGE_JSON_INVALID' 'Bridge stdout is not one JSON object' $Invocation }
    $expected = if($Mode -ceq 'Full'){@('ok','protocolVersion','main','renderer')}else{@('ok','protocolVersion','renderer')}
    Assert-CcodSessionExactProperties $parsed $expected 'BRIDGE_PROOF_INCOMPLETE' 'bridge proof'
    if ($parsed.ok -isnot [bool] -or -not $parsed.ok -or $parsed.protocolVersion -ne 1) { Throw-CcodSessionError 'BRIDGE_PROOF_INCOMPLETE' 'Bridge proof header is incomplete' $parsed }
    if ($Mode -ceq 'Full') {
        Assert-CcodSessionExactProperties $parsed.main @('inspectorPortClosed','payloadReport') 'BRIDGE_PROOF_INCOMPLETE' 'main proof'
        if ($null -eq $parsed.main.inspectorPortClosed -or $parsed.main.inspectorPortClosed.confirmed -isnot [bool] -or -not $parsed.main.inspectorPortClosed.confirmed -or $parsed.main.inspectorPortClosed.code -cne 'ECONNREFUSED' -or
            $null -eq $parsed.main.payloadReport -or $parsed.main.payloadReport.installed -isnot [bool] -or -not $parsed.main.payloadReport.installed) {
            Throw-CcodSessionError 'BRIDGE_PROOF_INCOMPLETE' 'Main proof is incomplete' $parsed
        }
    }
    Assert-CcodSessionExactProperties $parsed.renderer @('targetUrl','currentDocument','newDocumentScriptInstalled','probe') 'BRIDGE_PROOF_INCOMPLETE' 'renderer proof'
    if ($parsed.renderer.targetUrl -cne 'app://-/index.html' -or $null -eq $parsed.renderer.currentDocument -or
        $parsed.renderer.currentDocument.installed -isnot [bool] -or -not $parsed.renderer.currentDocument.installed -or
        $parsed.renderer.newDocumentScriptInstalled -isnot [bool] -or -not $parsed.renderer.newDocumentScriptInstalled -or
        $null -eq $parsed.renderer.probe -or $parsed.renderer.probe.proof -isnot [bool] -or -not $parsed.renderer.probe.proof -or
        $parsed.renderer.probe.targetGate -cne '782640499') {
        Throw-CcodSessionError 'BRIDGE_PROOF_INCOMPLETE' 'Renderer proof is incomplete' $parsed
    }
    return $parsed
}

function Invoke-CcodSessionCore {
    param([string]$Action, $Request, $Paths, $Adapters, [scriptblock]$Body)
    $transactionId = $null
    if ($null -ne $Request -and $null -ne $Request.PSObject.Properties['transactionId'] -and (Test-CcodSessionCanonicalGuid $Request.transactionId)) { $transactionId=$Request.transactionId }
    $result = New-CcodSessionResult -Action $Action -TransactionId $transactionId
    $adapter=$null;$pathsValidated=$false
    try {
        Assert-CcodSessionRequest -Request $Request -ExpectedAction $Action
        $result.transactionId=$Request.transactionId
        Assert-CcodSessionPaths -Paths $Paths
        $pathsValidated=$true
        $adapter = Merge-CcodSessionAdapters $Adapters
        return & $Body $result $adapter
    } catch {
        $result=Set-CcodSessionFailure -Result $result -Record $_ -Stage $result.stage
        if($pathsValidated){Write-CcodSessionDiagnostic $result $Action $result.transactionId $result.stage $result.error.code $Paths $adapter}
        return $result
    }
}

function Invoke-CcodInspectSession {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    return Invoke-CcodSessionCore Inspect $Request $Paths $Adapters {
        param($result,$adapter)
        $result.stage='InspectState'
        $state=& $adapter.ReadState $Paths.StateRoot $null
        if(-not $state.TransitionActionsAllowed){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'State damage blocks session inspection' $state.Damage}
        $processes=@(& $adapter.ListProcesses $state.Status|Where-Object{[string]$_.SessionId -ceq [string]$Request.supervisorIdentity.sessionId})
        $ordinary=@($processes|Where-Object{$_.IsTopLevel -and $_.Mode -ceq 'Ordinary'})
        $statusSession=$state.Status.session
        if($null -ne $statusSession -and $null -ne $statusSession.codex){
            $recorded=@($processes|Where-Object{$_.Pid -eq $statusSession.codex.pid -and $_.CreationTimeUtc -ceq $statusSession.codex.creationTimeUtc})
            if($recorded.Count -eq 1){
                $result.special=ConvertTo-CcodSessionSpecial $recorded[0]
                $result.ok=$true;$result.outcome='Inspected';$result.safeState=if($recorded[0].Mode -ceq 'Special'){'SpecialValidated'}else{'RendererRepairRequired'};$result.stage='Inspected';return $result
            }
        }
        if($ordinary.Count -gt 0){$result.source=ConvertTo-CcodSessionSource $ordinary[0];$result.safeState='OrdinaryRunning'}else{$result.safeState='NoCodex'}
        $result.ok=$true;$result.outcome='Inspected';$result.stage='Inspected';return $result
    }
}

function Invoke-CcodApplySession {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    return Invoke-CcodSessionCore Apply $Request $Paths $Adapters {
        param($result,$adapter)
        $result.stage='StaticProbe';$state=& $adapter.ReadState $Paths.StateRoot $null
        if(-not $state.TransitionActionsAllowed){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'State damage blocks Apply' $state.Damage}
        $probe=& $adapter.StaticProbe $state.Settings.nodeCandidates $Paths.CheckerPath
        $result.package=ConvertTo-CcodSessionPackage $probe
        $suppressionKey=Get-CcodSuppressionKey -PackageFullName $probe.PackageFullName -AppAsarSha256 $probe.AppAsarSha256 -RuntimeId $Request.runtimeId
        $state=& $adapter.ReadState $Paths.StateRoot $suppressionKey
        if($state.StatusRebuildRequired){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Status requires a dedicated live rebuild before Apply' $state.Damage}
        $prior=$null
        if($null -ne $state.VerifiedPackages -and $null -ne $state.VerifiedPackages.packages){$property=$state.VerifiedPackages.packages.PSObject.Properties[$suppressionKey];if($null -ne $property){$prior=$property.Value}}
        $priorSucceeded=$null -ne $prior -and $prior.dynamicOutcome -ceq 'Succeeded' -and $prior.probeState -ceq 'Valid'
        if($probe.StaticClassification -cne 'CandidateCompatible' -or -not $probe.Ready -or (-not $state.AutomaticCandidateTrialsAllowed -and -not $priorSucceeded)){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Package is not authorized for Apply' $probe}
        $source=$Request.source
        if($null -eq $source -and -not $Request.existingOnly){
            $roots=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter)
            if($roots.Count -gt 1 -or ($roots.Count -eq 1 -and $roots[0].Mode -cne 'Ordinary')){Throw-CcodSessionError 'CCOD_SOURCE_AMBIGUOUS' 'Current package roots do not prove one ordinary source' $roots}
            if($roots.Count -eq 1){$source=$roots[0]}
        }
        if($null -ne $source){
            $identity=& $adapter.CurrentIdentity
            if($null -eq $identity -or [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or
                [string]$source.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or $source.UserSid -cne $identity.UserSid -or
                -not $source.Path.Equals($probe.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or $source.PackageFamilyName -cne $probe.PackageFamilyName){
                Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Source identity is outside the current supervisor package boundary' $source
            }
            $actual=& $adapter.GetProcess $source.Pid $state.Status
            if($null -eq $actual -or -not (& $adapter.ProcessMatch $source $actual)){Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Source identity changed before transaction start' $source}
            $source=$actual;$result.source=ConvertTo-CcodSessionSource $source
        }
        $journalPackage=ConvertTo-CcodJournalPackage $probe
        $result.stage='IntentWritten';$transition=& $adapter.NewTransition $Paths.TransitionPath $source $journalPackage $Request.runtimeId $null $null $Request.transactionId
        if($null -ne $source){
            $result.stage='StopRequested';$transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'IntentWritten' 'StopRequested' $null $null $null $null
            $stop=& $adapter.StopProcess $source $state.Status (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds)
            if($stop.Outcome -cne 'Stopped' -or $stop.StoppedByController -isnot [bool] -or -not $stop.StoppedByController){
                & $adapter.CompleteTransition $Paths.TransitionPath $Paths.TransitionLogPath $Request.transactionId 'Cancelled' | Out-Null
                if($stop.Outcome -ceq 'SourceExited'){$result.ok=$true;$result.outcome='NoAction';$result.safeState='NoCodex';$result.stage='Cancelled';return $result}
                Throw-CcodSessionError 'CCOD_STOP_UNCONFIRMED' 'Only an exact Stopped receipt authorizes special launch' $stop
            }
            $result.stage='OrdinaryStopped';$transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'StopRequested' 'OrdinaryStopped' $null $null $null $null
        } else {
            $result.stage='OrdinaryStopped';$transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'IntentWritten' 'OrdinaryStopped' $null $null $null $null
        }
        $currentStage='OrdinaryStopped';$special=$null;$renderer=$Request.rendererPort;$main=$Request.mainPort;$recoveryAttempted=$false
        try {
            if($null -eq $renderer){$renderer=& $adapter.GetPort @()}
            if($null -eq $main){$main=& $adapter.GetPort @($renderer)}
            if($null -eq $renderer -or $null -eq $main -or $renderer -eq $main){Throw-CcodSessionError 'CCOD_PORT_UNAVAILABLE' 'Two distinct loopback ports are required' $null}
            $result.stage='SpecialLaunchRequested';$transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'OrdinaryStopped' 'SpecialLaunchRequested' $null $null $renderer $main;$currentStage='SpecialLaunchRequested'
            $start=& $adapter.StartSpecial $renderer $main (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds)
            if($start.Outcome -cne 'Started' -or $null -eq $start.Snapshot){Throw-CcodSessionError 'CCOD_SPECIAL_START_FAILED' 'Special startup was not proven' $start}
            $special=$start.Snapshot;$result.special=ConvertTo-CcodSessionSpecial $special
            $result.stage='SpecialStarted';$transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'SpecialLaunchRequested' 'SpecialStarted' $special $null $null $null;$currentStage='SpecialStarted'
            $bridge=Invoke-CcodSessionBridge -Mode Full -NodePath $probe.NodePath -Paths $Paths -RendererPort $renderer -MainPort $main -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $adapter
            $result.probes=ConvertTo-CcodPublicBridgeProbes $bridge Full
            $result.stage='Validated';$transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'SpecialStarted' 'Validated' $null $null $null $null;$currentStage='Validated'
            $status=[pscustomobject][ordered]@{schemaVersion=1;session=[pscustomobject][ordered]@{supervisorPid=[int]$Request.supervisorIdentity.pid;supervisorCreationTimeUtc=$Request.supervisorIdentity.creationTimeUtc;sessionId=$Request.supervisorIdentity.sessionId;runtimeId=$Request.runtimeId;sessionState='Active';codex=[pscustomobject][ordered]@{pid=[int]$special.Pid;creationTimeUtc=$special.CreationTimeUtc;packageFullName=$probe.PackageFullName;packageVersion=$probe.PackageVersion;appAsarSha256=$probe.AppAsarSha256;mainPort=[int]$main;rendererPort=[int]$renderer;mainProbe='Closed';rendererProbe='BridgeValid'}}}
            $live=[pscustomobject][ordered]@{Valid=$true;runtimeId=$Request.runtimeId;pid=[int]$special.Pid;creationTimeUtc=$special.CreationTimeUtc;packageFullName=$probe.PackageFullName;packageVersion=$probe.PackageVersion;appAsarSha256=$probe.AppAsarSha256;mainPort=[int]$main;rendererPort=[int]$renderer;mainProbe='Closed';rendererProbe='BridgeValid'}
            & $adapter.WriteStatus $Paths.StateRoot $status $live
            $verified=& $adapter.ReadVerified $Paths.StateRoot;$succeeded=New-CcodVerifiedStoreWithRecord $verified $probe $Request.runtimeId 'Succeeded' 'Valid' (& $adapter.UtcNow);& $adapter.WriteVerified $Paths.StateRoot $succeeded
            & $adapter.CompleteTransition $Paths.TransitionPath $Paths.TransitionLogPath $Request.transactionId 'Activated' | Out-Null
            $result.ok=$true;$result.outcome='Activated';$result.safeState='SpecialValidated';$result.stage='Completed';return $result
        } catch {
            Write-CcodSessionDiagnostic $result 'Apply' $Request.transactionId $result.stage (Get-CcodSessionErrorCode $_) $Paths $adapter
            if($recoveryAttempted){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recursive recovery is forbidden' $_}
            $recoveryAttempted=$true
            $recoveryRenderer=$null;$recoveryMain=$null
            if(@('SpecialLaunchRequested','SpecialStarted','Validated') -ccontains $currentStage){$recoveryRenderer=$renderer;$recoveryMain=$main}
            return Invoke-CcodRecoveryOperation $result $Request $Paths $adapter $state $probe $currentStage $special $recoveryRenderer $recoveryMain $Request.transactionId
        }
    }
}

function Invoke-CcodRepairRenderer {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    return Invoke-CcodSessionCore RepairRenderer $Request $Paths $Adapters {
        param($result,$adapter)
        $result.stage='RepairState';$state=& $adapter.ReadState $Paths.StateRoot $null
        if(-not $state.TransitionActionsAllowed -or $null -eq $state.Status.session -or $null -eq $state.Status.session.codex){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'No persisted special session is repairable' $state.Damage}
        $codex=$state.Status.session.codex;$current=& $adapter.GetProcess $codex.pid $state.Status
        $probe=& $adapter.StaticProbe $state.Settings.nodeCandidates $Paths.CheckerPath;$result.package=ConvertTo-CcodSessionPackage $probe
        $identity=& $adapter.CurrentIdentity
        if($null -eq $current -or $current.Pid -ne $codex.pid -or $current.CreationTimeUtc -cne $codex.creationTimeUtc -or -not $current.IsTopLevel -or
            [string]$current.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or
            $current.UserSid -cne $identity.UserSid -or -not $current.Path.Equals($probe.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or
            $current.PackageFamilyName -cne $probe.PackageFamilyName -or $current.RendererPort -ne $codex.rendererPort -or $current.MainPort -ne $codex.mainPort -or
            $state.Status.session.sessionId -cne $Request.supervisorIdentity.sessionId -or $state.Status.session.runtimeId -cne $Request.runtimeId){Throw-CcodSessionError 'CCOD_SOURCE_CHANGED' 'Persisted special identity changed before renderer repair' $codex}
        if($probe.PackageFullName -cne $codex.packageFullName -or $probe.AppAsarSha256 -cne $codex.appAsarSha256){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'Live package does not match persisted renderer repair evidence' $probe}
        $recoveryAttempted=$false
        try{
            if(-not (& $adapter.WaitPortClosed $codex.mainPort (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds))){Throw-CcodSessionError 'CCOD_MAIN_INSPECTOR_OPEN' 'Main Inspector refusal is not proven before renderer repair' $codex.mainPort}
            $bridge=Invoke-CcodSessionBridge -Mode Renderer -NodePath $probe.NodePath -Paths $Paths -RendererPort $codex.rendererPort -MainPort $null -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $adapter
            $result.probes=ConvertTo-CcodPublicBridgeProbes $bridge Renderer;$result.special=ConvertTo-CcodSessionSpecial $current
            $live=[pscustomobject][ordered]@{Valid=$true;runtimeId=$state.Status.session.runtimeId;pid=[int]$codex.pid;creationTimeUtc=$codex.creationTimeUtc;packageFullName=$codex.packageFullName;packageVersion=$codex.packageVersion;appAsarSha256=$codex.appAsarSha256;mainPort=[int]$codex.mainPort;rendererPort=[int]$codex.rendererPort;mainProbe='Closed';rendererProbe='BridgeValid'}
            & $adapter.WriteStatus $Paths.StateRoot $state.Status $live
            $result.ok=$true;$result.outcome='NoAction';$result.safeState='SpecialValidated';$result.stage='RendererRepaired';return $result
        }catch{
            Write-CcodSessionDiagnostic $result 'RepairRenderer' $Request.transactionId $result.stage (Get-CcodSessionErrorCode $_) $Paths $adapter
            if($recoveryAttempted){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recursive renderer recovery is forbidden' $_}
            $recoveryAttempted=$true
            $journalPackage=ConvertTo-CcodJournalPackage $probe
            $transition=& $adapter.NewTransition $Paths.TransitionPath $null $journalPackage $Request.runtimeId $null $null $Request.transactionId
            $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'IntentWritten' 'OrdinaryStopped' $null $null $null $null
            $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'OrdinaryStopped' 'SpecialLaunchRequested' $null $null $codex.rendererPort $codex.mainPort
            $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'SpecialLaunchRequested' 'SpecialStarted' $current $null $null $null
            return Invoke-CcodRecoveryOperation $result $Request $Paths $adapter $state $probe 'SpecialStarted' $current $codex.rendererPort $codex.mainPort $Request.transactionId
        }
    }
}

function Invoke-CcodRecoverSession {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,$Adapters)
    return Invoke-CcodSessionCore Recover $Request $Paths $Adapters {
        param($result,$adapter)
        $result.stage='RecoverState';$state=& $adapter.ReadState $Paths.StateRoot $null
        if(-not $state.TransitionActionsAllowed){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'State damage blocks recovery' $state.Damage}
        if($null -ne $state.Transition.activeTransaction){
            $replayed=Invoke-CcodReplayTransition -Request $Request -Paths $Paths -Transition $state.Transition.activeTransaction -Adapters $adapter
            if($Request.restartOrdinary -or -not $replayed.ok){return $replayed}
            $state=& $adapter.ReadState $Paths.StateRoot $null
            if($null -ne $state.Transition.activeTransaction){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Older transaction did not clear before separate close intent' $state.Transition.activeTransaction}
        }
        $probe=& $adapter.StaticProbe $state.Settings.nodeCandidates $Paths.CheckerPath;$result.package=ConvertTo-CcodSessionPackage $probe
        $roots=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter)
        $statusCodex=$null;if($null -ne $state.Status.session){$statusCodex=$state.Status.session.codex}
        if($Request.restartOrdinary){
            $special=$null;$renderer=$null;$main=$null
            if($null -ne $statusCodex){
                $candidate=& $adapter.GetProcess $statusCodex.pid $state.Status
                if($roots.Count -ne 1 -or $null -eq $candidate -or $candidate.CreationTimeUtc -cne $statusCodex.creationTimeUtc -or
                    -not (& $adapter.ProcessMatch $roots[0] $candidate) -or $candidate.RendererPort -ne $statusCodex.rendererPort -or $candidate.MainPort -ne $statusCodex.mainPort){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Persisted special identity is missing, changed, or accompanied by another root' $statusCodex}
                $special=$candidate;$renderer=$statusCodex.rendererPort;$main=$statusCodex.mainPort
            } else {
                if($roots.Count -gt 1){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Multiple current-package roots make normalization ambiguous' $roots}
                if($roots.Count -eq 1 -and $roots[0].Mode -cne 'Ordinary'){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'A status-less debug root is not owned for ordinary recovery' $roots[0]}
            }
            if($null -eq $special -and $roots.Count -eq 1){
                & $adapter.WriteStatus $Paths.StateRoot ([pscustomobject][ordered]@{schemaVersion=1;session=$null}) $null
                $result.source=ConvertTo-CcodSessionSource $roots[0];$result.ok=$true;$result.outcome='NoAction';$result.safeState='OrdinaryRunning';$result.stage='OrdinaryKept';return $result
            }
            $journalPackage=ConvertTo-CcodJournalPackage $probe
            $transition=& $adapter.NewTransition $Paths.TransitionPath $null $journalPackage $Request.runtimeId $null $null $Request.transactionId
            $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'IntentWritten' 'OrdinaryStopped' $null $null $null $null
            $currentStage='OrdinaryStopped'
            if($null -ne $special){
                $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'OrdinaryStopped' 'SpecialLaunchRequested' $null $null $renderer $main
                $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'SpecialLaunchRequested' 'SpecialStarted' $special $null $null $null
                $currentStage='SpecialStarted';$result.special=ConvertTo-CcodSessionSpecial $special
            }
            return Invoke-CcodRecoveryOperation $result $Request $Paths $adapter $state $probe $currentStage $special $renderer $main $Request.transactionId
        }
        $target=$null;$isSpecial=$false
        if($null -ne $statusCodex){
            $candidate=& $adapter.GetProcess $statusCodex.pid $state.Status
            if($roots.Count -ne 1 -or $null -eq $candidate -or $candidate.CreationTimeUtc -cne $statusCodex.creationTimeUtc -or -not (& $adapter.ProcessMatch $roots[0] $candidate)){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Recorded Active root is missing, changed, or accompanied by another root' $statusCodex}
            $target=$candidate;$isSpecial=$true
        } else {
            if($roots.Count -gt 1){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Multiple current-package close roots are ambiguous' $roots}
            if($roots.Count -eq 1){
                $target=$roots[0]
                if($target.Mode -cne 'Ordinary'){
                    if($null -eq $target.RendererPort -or $null -eq $target.MainPort -or $target.RendererPort -eq $target.MainPort){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'A status-less debug root lacks one valid distinct port pair' $target}
                    $isSpecial=$true
                }
            }
        }
        if($null -eq $target){$result.ok=$true;$result.outcome='Closed';$result.safeState='Closed';$result.stage='Closed';return $result}
        $tree=@(& $adapter.GetTree $target $state.Status)
        if($tree.Count -lt 1){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Current close target tree is not exact and verified' $target}
        $renderer=$null;$main=$null;$source=$target
        if($isSpecial){if($null -ne $statusCodex){$renderer=$statusCodex.rendererPort;$main=$statusCodex.mainPort}else{$renderer=$target.RendererPort;$main=$target.MainPort};$source=$null;$result.special=ConvertTo-CcodSessionSpecial $target}else{$result.source=ConvertTo-CcodSessionSource $target}
        $journalPackage=ConvertTo-CcodJournalPackage $probe
        $result.stage='IntentWritten';$transition=& $adapter.NewTransition $Paths.TransitionPath $source $journalPackage $Request.runtimeId $renderer $main $Request.transactionId
        $result.stage='CloseRequested';$specialIdentity=if($isSpecial){$target}else{$null}
        $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'IntentWritten' 'CloseRequested' $specialIdentity $null $null $null
        Invoke-CcodCloseVerifiedTree $tree $state.Status $adapter $Request.timeoutMilliseconds $renderer $main
        $transition=& $adapter.SetTransition $Paths.TransitionPath $Request.transactionId 'CloseRequested' 'Closed' $null $null $null $null
        return Complete-CcodCloseResult $result $Paths $adapter $Request.transactionId
    }
}

function Invoke-CcodReplayTransition {
    [CmdletBinding()] param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Paths,[Parameter(Mandatory)]$Transition,$Adapters)
    return Invoke-CcodSessionCore Recover $Request $Paths $Adapters {
        param($result,$adapter)
        $result.stage=$Transition.stage
        $state=& $adapter.ReadState $Paths.StateRoot $null
        if(-not $state.TransitionActionsAllowed){Throw-CcodSessionError 'CCOD_STATE_BLOCKED' 'State damage blocks transition replay' $state.Damage}
        if($Transition.stage -ceq 'Closed'){
            $portObservation=if($null -eq $Transition.mainPort){'NotApplicable'}else{'Indeterminate'}
            $observed=[pscustomobject][ordered]@{StopObservation='CloseTreeAbsent';RecoveryObservation='NotApplicable';SpecialObservation='NoCandidate';PortObservation=$portObservation;SpecialCandidates=@();OrdinaryCandidates=@()}
            $decision=Get-CcodReplayDecision -Transition $Transition -Observed $observed
            if($decision.Action -cne 'CompleteClosed'){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Closed replay did not select archival completion' $decision}
            return Complete-CcodCloseResult $result $Paths $adapter $Transition.transactionId
        }
        $probe=& $adapter.StaticProbe $state.Settings.nodeCandidates $Paths.CheckerPath;$result.package=ConvertTo-CcodSessionPackage $probe
        if(@('SpecialLaunchRequested','SpecialStarted','Validated') -ccontains $Transition.stage -and
            ($Transition.runtimeId -cne $Request.runtimeId -or $Transition.packageFullName -cne $probe.PackageFullName -or $Transition.appAsarSha256 -cne $probe.AppAsarSha256)){
            Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'The active runtime package does not match the durable transition identity' $Transition
        }
        if($Transition.stage -ceq 'CloseRequested'){
            $identity=& $adapter.CurrentIdentity
            if($null -eq $identity -or [string]$identity.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or [string]::IsNullOrWhiteSpace([string]$identity.UserSid)){
                Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Close replay supervisor does not match the current Windows session identity' $Request.supervisorIdentity
            }
            $portObservation=if($null -eq $Transition.mainPort){'NotApplicable'}else{'Indeterminate'}
            $recordedPid=if($null -ne $Transition.specialPid){$Transition.specialPid}else{$Transition.sourcePid}
            $recordedTime=if($null -ne $Transition.specialPid){$Transition.specialCreationTimeUtc}else{$Transition.sourceCreationTimeUtc}
            $current=& $adapter.GetProcess $recordedPid $state.Status
            if($null -eq $current -or $current.CreationTimeUtc -cne $recordedTime -or -not $current.IsTopLevel -or
                [string]$current.SessionId -cne [string]$Request.supervisorIdentity.sessionId -or $current.UserSid -cne $identity.UserSid -or
                -not $current.Path.Equals($probe.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or $current.PackageFamilyName -cne $probe.PackageFamilyName){
                $cold=[pscustomobject][ordered]@{StopObservation='CloseTreeIndeterminate';RecoveryObservation='NotApplicable';SpecialObservation='NoCandidate';PortObservation=$portObservation;SpecialCandidates=@();OrdinaryCandidates=@()}
                $decision=Get-CcodReplayDecision -Transition $Transition -Observed $cold
                Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Cold close replay cannot prove absence of the complete recorded tree' $decision
            }
            $tree=@(& $adapter.GetTree $current $state.Status)
            if($tree.Count -lt 1){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Recorded close root does not yield a verified tree' $current}
            if($null -ne $Transition.specialPid){
                $fact=[pscustomobject][ordered]@{Process=$current;Evidence='PersistedIdentity';Validation='Indeterminate'}
                $present=[pscustomobject][ordered]@{StopObservation='CloseTreePresent';RecoveryObservation='NotApplicable';SpecialObservation='Confirmed';PortObservation=$portObservation;SpecialCandidates=@($fact);OrdinaryCandidates=@()}
            } else {
                $present=[pscustomobject][ordered]@{StopObservation='CloseTreePresent';RecoveryObservation='NotApplicable';SpecialObservation='NoCandidate';PortObservation='NotApplicable';SpecialCandidates=@();OrdinaryCandidates=@($current)}
            }
            $decision=Get-CcodReplayDecision -Transition $Transition -Observed $present
            if($decision.Action -cne 'CloseRecordedTree'){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close replay did not authorize the exact recorded tree' $decision}
            Invoke-CcodCloseVerifiedTree $tree $state.Status $adapter $Request.timeoutMilliseconds $Transition.rendererPort $Transition.mainPort
            $closedPort=if($null -eq $Transition.mainPort){'NotApplicable'}else{'BothRefused'}
            $absent=[pscustomobject][ordered]@{StopObservation='CloseTreeAbsent';RecoveryObservation='NotApplicable';SpecialObservation='NoCandidate';PortObservation=$closedPort;SpecialCandidates=@();OrdinaryCandidates=@()}
            $decision=Get-CcodReplayDecision -Transition $Transition -Observed $absent
            if($decision.Action -cne 'CompleteClosed'){Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Close tree absence did not authorize completion' $decision}
            $transition=& $adapter.SetTransition $Paths.TransitionPath $Transition.transactionId 'CloseRequested' 'Closed' $null $null $null $null
            return Complete-CcodCloseResult $result $Paths $adapter $Transition.transactionId
        }
        $ordinary=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter|Where-Object{$_.Mode -ceq 'Ordinary'})
        $stopObservation='NotApplicable';$recoveryObservation='NotApplicable'
        if($Transition.stage -ceq 'StopRequested'){
            $expected=& $adapter.GetProcess $Transition.sourcePid $state.Status
            if($null -eq $expected){$stopObservation='ExitedDuringPrimary5s'}
            elseif($expected.CreationTimeUtc -cne $Transition.sourceCreationTimeUtc){$stopObservation='IdentityChangedDuringPrimary5s'}
            else{
                $stopObservation='SameAliveAfterPrimary5s'
                for($index=0;$index -lt 5;$index++){
                    & $adapter.Delay 1000;$current=& $adapter.GetProcess $Transition.sourcePid $state.Status
                    if($null -eq $current){$stopObservation='ExitedDuringPrimary5s';break}
                    if(-not (& $adapter.ProcessMatch $expected $current)){$stopObservation='IdentityChangedDuringPrimary5s';break}
                }
                if($stopObservation -ceq 'SameAliveAfterPrimary5s'){
                    $stopObservation='SameAliveAfterGuard5s'
                    for($index=0;$index -lt 5;$index++){
                        & $adapter.Delay 1000;$current=& $adapter.GetProcess $Transition.sourcePid $state.Status
                        if($null -eq $current){$stopObservation='ExitedDuringGuard5s';break}
                        if(-not (& $adapter.ProcessMatch $expected $current)){$stopObservation='IdentityChangedDuringGuard5s';break}
                    }
                }
            }
            $ordinary=@(Get-CcodCurrentPackageRoots $state.Status $probe $Request $adapter|Where-Object{$_.Mode -ceq 'Ordinary'})
        }
        if($Transition.stage -ceq 'RecoveryLaunchRequested'){
            $candidate=Find-CcodOrdinarySnapshot $state.Status $adapter
            if($null -ne $candidate){$ordinary=@($candidate);$recoveryObservation='OrdinaryAppearedWithin5s'}else{$recoveryObservation='NotStarted'}
        }
        if(@('SpecialLaunchRequested','SpecialStarted','Validated') -ccontains $Transition.stage){
            $specialObservation=Get-CcodStageAwareSpecialObservation $Transition $state $probe $Request $Paths $adapter
        } elseif($adapter.ObserveSpecialIsDefault -and @('RecoveryLaunchRequested','Recovered') -ccontains $Transition.stage -and $null -ne $Transition.specialPid){
            $recorded=& $adapter.GetProcess $Transition.specialPid $state.Status
            if($null -eq $recorded -or $recorded.CreationTimeUtc -cne $Transition.specialCreationTimeUtc){
                $specialObservation=[pscustomobject]@{Outcome='NoCandidate';Snapshot=$null;Candidates=@();ConflictOwners=@();Validation='Indeterminate'}
            } else {
                $validation='Indeterminate'
                if(@('SpecialStarted','Validated') -ccontains $Transition.stage -and (& $adapter.WaitPortClosed $Transition.mainPort (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds))){
                    try{
                        Invoke-CcodSessionBridge -Mode Renderer -NodePath $probe.NodePath -Paths $Paths -RendererPort $Transition.rendererPort -MainPort $null -TimeoutMilliseconds $Request.timeoutMilliseconds -Adapter $adapter|Out-Null;$validation='Valid'
                    }catch{$validation='Indeterminate'}
                }
                $specialObservation=[pscustomobject]@{Outcome='Confirmed';Snapshot=$recorded;Candidates=@($recorded);ConflictOwners=@();Validation=$validation}
            }
        } else {
            $specialObservation=& $adapter.ObserveSpecial $Transition $Paths $Request.timeoutMilliseconds
        }
        $specialFacts=@()
        foreach($candidate in @($specialObservation.Candidates)){
            $evidence=if(@('SpecialStarted','Validated','RecoveryLaunchRequested','Recovered') -ccontains $Transition.stage){'PersistedIdentity'}else{'PreStatusCandidate'}
            $specialFacts+=,[pscustomobject][ordered]@{Process=$candidate;Evidence=$evidence;Validation=$specialObservation.Validation}
        }
        if($specialFacts.Count -eq 0 -and $null -ne $specialObservation.Snapshot){
            $evidence=if(@('SpecialStarted','Validated','RecoveryLaunchRequested','Recovered') -ccontains $Transition.stage){'PersistedIdentity'}else{'PreStatusCandidate'}
            $specialFacts+=,[pscustomobject][ordered]@{Process=$specialObservation.Snapshot;Evidence=$evidence;Validation=$specialObservation.Validation}
        }
        $portObservation=if($null -eq $Transition.mainPort){'NotApplicable'}else{'Indeterminate'}
        $observed=[pscustomobject][ordered]@{StopObservation=$stopObservation;RecoveryObservation=$recoveryObservation;SpecialObservation=$specialObservation.Outcome;PortObservation=$portObservation;SpecialCandidates=@($specialFacts);OrdinaryCandidates=@($ordinary)}
        $decision=Get-CcodReplayDecision -Transition $Transition -Observed $observed
        switch($decision.Action){
            'CancelKeepOrdinary' {
                if($Transition.stage -ceq 'Recovered'){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recovered identity is missing and cannot be cancelled' $Transition}
                & $adapter.CompleteTransition $Paths.TransitionPath $Paths.TransitionLogPath $Transition.transactionId 'Cancelled'|Out-Null
                $result.ok=$true;$result.outcome='NoAction';$result.safeState=if($ordinary.Count -gt 0){'OrdinaryRunning'}else{'NoCodex'};$result.stage='Cancelled';if($ordinary.Count -gt 0){$result.source=ConvertTo-CcodSessionSource $ordinary[0]};return $result
            }
            'AdoptValidatedSpecial' {
                if($Transition.stage -ceq 'SpecialLaunchRequested'){
                    $transition=& $adapter.SetTransition $Paths.TransitionPath $Transition.transactionId 'SpecialLaunchRequested' 'SpecialStarted' $decision.AdoptedProcess $null $null $null
                    $transition=& $adapter.SetTransition $Paths.TransitionPath $Transition.transactionId 'SpecialStarted' 'Validated' $null $null $null $null
                }elseif($Transition.stage -ceq 'SpecialStarted'){
                    $transition=& $adapter.SetTransition $Paths.TransitionPath $Transition.transactionId 'SpecialStarted' 'Validated' $null $null $null $null
                }elseif($Transition.stage -cne 'Validated'){
                    Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Only a Validated transaction may complete Activated' $Transition
                }
                return Complete-CcodActivatedReplay $result $Request $Paths $adapter $probe $decision.AdoptedProcess $specialObservation.Bridge $Transition.transactionId
            }
            'AdoptOrdinaryRecovery' {
                if($Transition.stage -ceq 'Recovered'){
                    if($null -ne $Transition.mainPort){foreach($port in @($Transition.rendererPort,$Transition.mainPort)){if(-not (& $adapter.WaitPortClosed $port (Get-CcodProcessControlTimeout $Request.timeoutMilliseconds))){Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' 'Recovered replay ports are not explicitly refused' $port}}}
                    return Complete-CcodRecoveredReplay $result $Request $Paths $adapter $probe $decision.AdoptedProcess $Transition.transactionId
                }
                return Invoke-CcodRecoveryOperation $result $Request $Paths $adapter $state $probe $Transition.stage $null $Transition.rendererPort $Transition.mainPort $Transition.transactionId
            }
            { @('RecoverOrdinary','TerminateSpecialThenRecover') -ccontains $_ } {
                $special=$null;if($decision.Action -ceq 'TerminateSpecialThenRecover'){$special=$decision.AdoptedProcess}
                return Invoke-CcodRecoveryOperation $result $Request $Paths $adapter $state $probe $Transition.stage $special $Transition.rendererPort $Transition.mainPort $Transition.transactionId
            }
            default {Throw-CcodSessionError 'CCOD_RECOVERY_UNPROVEN' "Replay action $($decision.Action) requires user intervention" $decision}
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-CcodInspectSession','Invoke-CcodApplySession','Invoke-CcodRepairRenderer',
    'Invoke-CcodRecoverSession','Invoke-CcodReplayTransition','Test-CcodBridgeResult'
)
