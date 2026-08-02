$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\StateStore.psm1') -Force

function New-CcodStateTestAdapters {
    $fixedUtc = [DateTime]::Parse('2030-02-03T04:05:06.0000000Z').ToUniversalTime()
    return @{
        UtcNow = { $fixedUtc }.GetNewClosure()
        NewGuid = { [Guid]'11111111-2222-3333-4444-555555555555' }
        TestVerifiedNodeCandidate = { param($Path) $Path -eq 'C:\Node\node.exe' }
    }
}

function New-CcodPermissiveNodeTestAdapters {
    $adapters = New-CcodStateTestAdapters
    $adapters.TestVerifiedNodeCandidate = { param($Path) $true }
    return $adapters
}

function Initialize-CcodStateFixture([string]$StateRoot) {
    Initialize-CcodState -StateRoot $StateRoot -NodeCandidates @('C:\Node\node.exe') -CandidateCompatibleOptIn $true -Adapters (New-CcodStateTestAdapters) | Out-Null
}

function Set-CcodStateDamage([string]$StateRoot, [string]$Leaf, [string]$Variant) {
    $path = Join-Path $StateRoot $Leaf
    switch ($Variant) {
        'missing' { [IO.File]::Delete($path) }
        'malformed' { [IO.File]::WriteAllText($path, '{broken', [Text.UTF8Encoding]::new($false)) }
        'unknown-schema' {
            $value = [ordered]@{ schemaVersion = 99; ignored = $true }
            [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        }
        default { throw "Unknown damage variant: $Variant" }
    }
}

function Write-CcodStateJson([string]$StateRoot, [string]$Leaf, $Value) {
    [IO.File]::WriteAllText((Join-Path $StateRoot $Leaf), ($Value | ConvertTo-Json -Depth 16 -Compress), [Text.UTF8Encoding]::new($false))
}

function New-CcodTransitionFixture {
    return [ordered]@{
        transactionId = 'transaction-1'
        stage = 'IntentWritten'
        sourcePid = 101
        sourceCreationTimeUtc = '2030-02-03T04:05:06.0000000Z'
        packageFullName = 'pkg'
        appAsarSha256 = ('a' * 64)
        runtimeId = 'runtime-1'
        mainPort = 41001
        rendererPort = 41002
        specialPid = $null
        specialCreationTimeUtc = $null
        recoveryPid = $null
        recoveryCreationTimeUtc = $null
        createdAtUtc = '2030-02-03T04:05:06.0000000Z'
        updatedAtUtc = '2030-02-03T04:05:06.0000000Z'
    }
}

function New-CcodStatusSession {
    return [ordered]@{
        supervisorPid = 11
        supervisorCreationTimeUtc = '2030-02-03T04:05:06.0000000Z'
        sessionId = 'session-1'
        runtimeId = 'runtime-1'
        sessionState = 'Active'
        codex = [ordered]@{
            pid = 22
            creationTimeUtc = '2030-02-03T04:05:06.0000000Z'
            packageFullName = 'pkg'
            packageVersion = '1.0.0.0'
            appAsarSha256 = ('a' * 64)
            mainPort = 41001
            rendererPort = 41002
            mainProbe = 'Closed'
            rendererProbe = 'BridgeValid'
        }
    }
}

function New-CcodStatusFixture {
    return [ordered]@{ schemaVersion = 1; session = (New-CcodStatusSession) }
}

function New-CcodLiveProbeFixture {
    $session = New-CcodStatusSession
    return [pscustomobject]@{
        Valid = $true
        runtimeId = $session.runtimeId
        pid = $session.codex.pid
        creationTimeUtc = $session.codex.creationTimeUtc
        packageFullName = $session.codex.packageFullName
        packageVersion = $session.codex.packageVersion
        appAsarSha256 = $session.codex.appAsarSha256
        mainPort = $session.codex.mainPort
        rendererPort = $session.codex.rendererPort
        mainProbe = $session.codex.mainProbe
        rendererProbe = $session.codex.rendererProbe
    }
}

function New-CcodVerifiedRecord {
    return [ordered]@{
        packageFullName = 'pkg'
        packageVersion = '1.0.0.0'
        appAsarSha256 = ('a' * 64)
        runtimeId = 'runtime-1'
        staticClassification = 'CandidateCompatible'
        dynamicOutcome = 'Failed'
        probeState = 'Invalid'
        confirmedAtUtc = '2030-02-03T04:05:06.0000000Z'
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-state-selftest-' + [Guid]::NewGuid().ToString('N'))
try {
    Invoke-CcodTest 'initializes independent automation consent and installer-verified absolute Node paths' {
        $state = Join-Path $root 'initial'
        Initialize-CcodStateFixture -StateRoot $state
        $loaded = Read-CcodState -StateRoot $state -CurrentSuppressionKey 'pkg|hash|runtime' -Adapters (New-CcodStateTestAdapters)

        Assert-CcodEqual $true $loaded.Settings.automationEnabled 'fresh explicit install enables automation'
        Assert-CcodEqual $true $loaded.Settings.candidateCompatibleOptIn 'opt-in persists independently from automation'
        Assert-CcodEqual 'C:\Node\node.exe' $loaded.Settings.nodeCandidates[0] 'only the installer supplied candidate is persisted'
        Assert-CcodEqual $true $loaded.AutomaticCandidateTrialsAllowed 'healthy explicit consent and verified history permit a trial'
        Assert-CcodEqual $true $loaded.TransitionActionsAllowed 'healthy initialized transition store permits actions'
        Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' $loaded.Settings.updatedAtUtc 'state uses injected UTC clock'
        Assert-CcodThrows { Initialize-CcodState -StateRoot (Join-Path $root 'relative-node') -NodeCandidates @('node.exe') -Adapters (New-CcodStateTestAdapters) } 'CCOD_NODE_CANDIDATE_INVALID'
    }

    Invoke-CcodTest 'fails closed for every missing malformed and unknown-schema state file' {
        $rules = @(
            [pscustomobject]@{ Leaf = 'settings.json'; ExpectedAutomation = $false; ExpectedTrial = $false; ExpectedTransition = $true },
            [pscustomobject]@{ Leaf = 'verified-packages.json'; ExpectedAutomation = $true; ExpectedTrial = $false; ExpectedTransition = $true },
            [pscustomobject]@{ Leaf = 'transition.json'; ExpectedAutomation = $false; ExpectedTrial = $false; ExpectedTransition = $false },
            [pscustomobject]@{ Leaf = 'status.json'; ExpectedAutomation = $true; ExpectedTrial = $false; ExpectedTransition = $true }
        )
        foreach ($rule in $rules) {
            foreach ($variant in @('missing', 'malformed', 'unknown-schema')) {
                $state = Join-Path $root ("damage-$($rule.Leaf)-$variant")
                Initialize-CcodStateFixture -StateRoot $state
                Set-CcodStateDamage -StateRoot $state -Leaf $rule.Leaf -Variant $variant
                $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)

                Assert-CcodEqual $rule.ExpectedAutomation $loaded.AutomationEnabled "$($rule.Leaf) $variant applies the correct automation default"
                Assert-CcodEqual $rule.ExpectedTrial $loaded.AutomaticCandidateTrialsAllowed "$($rule.Leaf) $variant applies the correct candidate-trial default"
                Assert-CcodEqual $rule.ExpectedTransition $loaded.TransitionActionsAllowed "$($rule.Leaf) $variant applies the correct transition-action default"
                Assert-CcodTrue ($loaded.Damage.PSObject.Properties[$rule.Leaf] -ne $null) "$($rule.Leaf) $variant is reported as damage"
                if ($variant -ne 'missing') {
                    $quarantine = @(Get-ChildItem -LiteralPath $state -File -Filter ($rule.Leaf + '.corrupt.*'))
                    Assert-CcodEqual 1 $quarantine.Count "$($rule.Leaf) $variant is quarantined instead of silently overwritten"
                }
            }
        }
    }

    Invoke-CcodTest 'requires a live probe before rebuilding damaged status' {
        $state = Join-Path $root 'status-rebuild'
        Initialize-CcodStateFixture -StateRoot $state
        Set-CcodStateDamage -StateRoot $state -Leaf 'status.json' -Variant 'malformed'
        $damaged = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $true $damaged.StatusRebuildRequired 'damaged status is not trusted as a usable ordinary-session record'
        Assert-CcodThrows { Write-CcodStatus -StateRoot $state -Status (New-CcodStatusFixture) } 'CCOD_LIVE_PROBE_REQUIRED'
        $status = New-CcodStatusFixture
        $mismatchedProbe = New-CcodLiveProbeFixture
        $mismatchedProbe.rendererPort = 49999
        Assert-CcodThrows { Write-CcodStatus -StateRoot $state -Status $status -LiveProbeResult $mismatchedProbe } 'CCOD_LIVE_PROBE_MISMATCH'
        Write-CcodStatus -StateRoot $state -Status $status -LiveProbeResult (New-CcodLiveProbeFixture) | Out-Null
        Assert-CcodEqual 'Active' (Read-CcodStatus -StateRoot $state -Adapters (New-CcodStateTestAdapters)).session.sessionState 'a matching complete live probe permits status reconstruction'
    }

    Invoke-CcodTest 'quarantines invalid status and verified semantic combinations' {
        $statusCases = @(
            [pscustomobject]@{ Name = 'unknown state'; Mutate = { param($status) $status.session.sessionState = 'Whatever' } },
            [pscustomobject]@{ Name = 'codex ordinary'; Mutate = { param($status) $status.session.sessionState = 'Ordinary' } },
            [pscustomobject]@{ Name = 'active without codex'; Mutate = { param($status) $status.session.codex = $null } },
            [pscustomobject]@{ Name = 'open main inspector'; Mutate = { param($status) $status.session.codex.mainProbe = 'Open' } },
            [pscustomobject]@{ Name = 'invalid renderer bridge'; Mutate = { param($status) $status.session.codex.rendererProbe = 'Valid' } }
        )
        foreach ($case in $statusCases) {
            $state = Join-Path $root ('status-semantic-' + $case.Name.Replace(' ', '-'))
            Initialize-CcodStateFixture -StateRoot $state
            $status = New-CcodStatusFixture
            & $case.Mutate $status
            Write-CcodStateJson -StateRoot $state -Leaf 'status.json' -Value $status
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $true $loaded.StatusRebuildRequired "$($case.Name) status is not adopted"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'status.json.corrupt.*').Count "$($case.Name) status is quarantined"
        }
        $verifiedCases = @(
            [pscustomobject]@{ Name = 'success invalid probe'; Static = 'CandidateCompatible'; Outcome = 'Succeeded'; Probe = 'Invalid' },
            [pscustomobject]@{ Name = 'failure valid probe'; Static = 'CandidateCompatible'; Outcome = 'Failed'; Probe = 'Valid' },
            [pscustomobject]@{ Name = 'native success'; Static = 'NativeModulePresent'; Outcome = 'Succeeded'; Probe = 'Valid' },
            [pscustomobject]@{ Name = 'unknown success'; Static = 'UnknownOrIncompatible'; Outcome = 'Succeeded'; Probe = 'Valid' }
        )
        foreach ($case in $verifiedCases) {
            $state = Join-Path $root ('verified-semantic-' + $case.Name.Replace(' ', '-'))
            Initialize-CcodStateFixture -StateRoot $state
            $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
            $record = New-CcodVerifiedRecord
            $record.staticClassification = $case.Static
            $record.dynamicOutcome = $case.Outcome
            $record.probeState = $case.Probe
            Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion = 1; packages = [ordered]@{ $key = $record } })
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $false $loaded.AutomaticCandidateTrialsAllowed "$($case.Name) cannot authorize another trial"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'verified-packages.json.corrupt.*').Count "$($case.Name) verified record is quarantined"
        }
    }

    Invoke-CcodTest 'quarantines case-variant fixed enums and rejects extra live-probe fields' {
        $statusCases = @(
            [pscustomobject]@{ Name = 'lowercase session state'; Mutate = { param($status) $status.session.sessionState = 'active' } },
            [pscustomobject]@{ Name = 'lowercase main probe'; Mutate = { param($status) $status.session.codex.mainProbe = 'closed' } },
            [pscustomobject]@{ Name = 'mixed renderer probe'; Mutate = { param($status) $status.session.codex.rendererProbe = 'bridgeValid' } }
        )
        foreach ($case in $statusCases) {
            $state = Join-Path $root ('status-case-' + [Guid]::NewGuid().ToString('N'))
            Initialize-CcodStateFixture -StateRoot $state
            $status = New-CcodStatusFixture
            & $case.Mutate $status
            Write-CcodStateJson -StateRoot $state -Leaf 'status.json' -Value $status
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $true $loaded.StatusRebuildRequired "$($case.Name) cannot be adopted"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'status.json.corrupt.*').Count "$($case.Name) status is quarantined"
        }
        $verifiedCases = @(
            [pscustomobject]@{ Name = 'lowercase classification'; Field = 'staticClassification'; Value = 'candidatecompatible' },
            [pscustomobject]@{ Name = 'lowercase outcome'; Field = 'dynamicOutcome'; Value = 'failed' },
            [pscustomobject]@{ Name = 'lowercase probe'; Field = 'probeState'; Value = 'invalid' }
        )
        foreach ($case in $verifiedCases) {
            $state = Join-Path $root ('verified-case-' + [Guid]::NewGuid().ToString('N'))
            Initialize-CcodStateFixture -StateRoot $state
            $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
            $record = New-CcodVerifiedRecord
            $record[$case.Field] = $case.Value
            Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion = 1; packages = [ordered]@{ $key = $record } })
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $false $loaded.AutomaticCandidateTrialsAllowed "$($case.Name) cannot authorize a trial"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'verified-packages.json.corrupt.*').Count "$($case.Name) verified evidence is quarantined"
        }
        $state = Join-Path $root 'transition-case'
        Initialize-CcodStateFixture -StateRoot $state
        $transaction = New-CcodTransitionFixture
        $transaction.stage = 'intentwritten'
        Write-CcodStateJson -StateRoot $state -Leaf 'transition.json' -Value ([ordered]@{ schemaVersion = 1; activeTransaction = $transaction })
        $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $false $loaded.TransitionActionsAllowed 'lowercase transition stage forbids actions'
        Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'transition.json.corrupt.*').Count 'lowercase transition stage is quarantined'

        $liveState = Join-Path $root 'live-probe-extra'
        Initialize-CcodStateFixture -StateRoot $liveState
        $probe = New-CcodLiveProbeFixture
        $probe | Add-Member -NotePropertyName unexpected -NotePropertyValue 'extra'
        Assert-CcodThrows { Write-CcodStatus -StateRoot $liveState -Status (New-CcodStatusFixture) -LiveProbeResult $probe } 'CCOD_LIVE_PROBE_INVALID'
        Assert-CcodEqual $null (Read-CcodStatus -StateRoot $liveState -Adapters (New-CcodStateTestAdapters)).session 'extra probe data leaves existing status intact'
    }

    Invoke-CcodTest 'rejects coercive live-probe types and case changes before writing status' {
        $state = Join-Path $root 'live-probe-types'
        Initialize-CcodStateFixture -StateRoot $state
        $badCases = @(
            [pscustomobject]@{ Name = 'numeric valid'; Field = 'Valid'; Value = 1; ErrorId = 'CCOD_LIVE_PROBE_INVALID' },
            [pscustomobject]@{ Name = 'string valid'; Field = 'Valid'; Value = 'True'; ErrorId = 'CCOD_LIVE_PROBE_INVALID' },
            [pscustomobject]@{ Name = 'string PID'; Field = 'pid'; Value = '22'; ErrorId = 'CCOD_LIVE_PROBE_INVALID' },
            [pscustomobject]@{ Name = 'string port'; Field = 'rendererPort'; Value = '41002'; ErrorId = 'CCOD_LIVE_PROBE_INVALID' },
            [pscustomobject]@{ Name = 'case package'; Field = 'packageFullName'; Value = 'PKG'; ErrorId = 'CCOD_LIVE_PROBE_MISMATCH' },
            [pscustomobject]@{ Name = 'case hash'; Field = 'appAsarSha256'; Value = ('A' * 64); ErrorId = 'CCOD_LIVE_PROBE_INVALID' },
            [pscustomobject]@{ Name = 'case runtime'; Field = 'runtimeId'; Value = 'RUNTIME-1'; ErrorId = 'CCOD_LIVE_PROBE_MISMATCH' }
        )
        foreach ($case in $badCases) {
            $probe = New-CcodLiveProbeFixture
            $probe.($case.Field) = $case.Value
            Assert-CcodThrows { Write-CcodStatus -StateRoot $state -Status (New-CcodStatusFixture) -LiveProbeResult $probe } $case.ErrorId
        }
        Assert-CcodEqual $null (Read-CcodStatus -StateRoot $state -Adapters (New-CcodStateTestAdapters)).session 'invalid probes leave the existing empty status intact'
    }

    Invoke-CcodTest 'quarantines noncanonical Node candidate paths even when installer evidence accepts them' {
        foreach ($candidate in @('C:\Node\.\node.exe', 'C:\Node\child\..\node.exe', 'C:\Node\\node.exe')) {
            $state = Join-Path $root ('node-canonical-' + [Guid]::NewGuid().ToString('N'))
            Initialize-CcodStateFixture -StateRoot $state
            Write-CcodStateJson -StateRoot $state -Leaf 'settings.json' -Value ([ordered]@{ schemaVersion = 1; automationEnabled = $true; candidateCompatibleOptIn = $true; nodeCandidates = @($candidate); updatedAtUtc = '2030-02-03T04:05:06.0000000Z' })
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodPermissiveNodeTestAdapters)
            Assert-CcodEqual $false $loaded.AutomationEnabled "$candidate cannot reauthorize automation"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'settings.json.corrupt.*').Count "$candidate settings evidence is quarantined"
        }
    }

    Invoke-CcodTest 'quarantines every invalid transition shape and disables all actions' {
        $badCases = @(
            [pscustomobject]@{ Name = 'empty transaction'; Field = $null; Value = [ordered]@{} },
            [pscustomobject]@{ Name = 'transaction ID'; Field = 'transactionId'; Value = 1 },
            [pscustomobject]@{ Name = 'stage'; Field = 'stage'; Value = 'BadStage' },
            [pscustomobject]@{ Name = 'source PID'; Field = 'sourcePid'; Value = '101' },
            [pscustomobject]@{ Name = 'source creation'; Field = 'sourceCreationTimeUtc'; Value = 'not-a-time' },
            [pscustomobject]@{ Name = 'package full name'; Field = 'packageFullName'; Value = 1 },
            [pscustomobject]@{ Name = 'asar hash'; Field = 'appAsarSha256'; Value = 'not-a-hash' },
            [pscustomobject]@{ Name = 'runtime ID'; Field = 'runtimeId'; Value = 1 },
            [pscustomobject]@{ Name = 'main port'; Field = 'mainPort'; Value = 0 },
            [pscustomobject]@{ Name = 'renderer port'; Field = 'rendererPort'; Value = 41001 },
            [pscustomobject]@{ Name = 'special PID'; Field = 'specialPid'; Value = '22' },
            [pscustomobject]@{ Name = 'special creation'; Field = 'specialCreationTimeUtc'; Value = 'not-a-time' },
            [pscustomobject]@{ Name = 'recovery PID'; Field = 'recoveryPid'; Value = '33' },
            [pscustomobject]@{ Name = 'recovery creation'; Field = 'recoveryCreationTimeUtc'; Value = 'not-a-time' },
            [pscustomobject]@{ Name = 'created time'; Field = 'createdAtUtc'; Value = 'not-a-time' },
            [pscustomobject]@{ Name = 'updated time'; Field = 'updatedAtUtc'; Value = 'not-a-time' }
        )
        foreach ($case in $badCases) {
            $state = Join-Path $root ('transition-' + $case.Name.Replace(' ', '-'))
            Initialize-CcodStateFixture -StateRoot $state
            $transaction = New-CcodTransitionFixture
            if ($null -eq $case.Field) { $transaction = $case.Value } else { $transaction[$case.Field] = $case.Value }
            Write-CcodStateJson -StateRoot $state -Leaf 'transition.json' -Value ([ordered]@{ schemaVersion = 1; activeTransaction = $transaction })
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $false $loaded.AutomationEnabled "$($case.Name) transition disables automation"
            Assert-CcodEqual $false $loaded.TransitionActionsAllowed "$($case.Name) transition forbids stop/start/recover"
            Assert-CcodTrue ($loaded.Damage.PSObject.Properties['transition.json'] -ne $null) "$($case.Name) transition is recorded as damage"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'transition.json.corrupt.*').Count "$($case.Name) transition is quarantined"
        }
    }

    Invoke-CcodTest 'quarantines strict status verified and settings schema violations' {
        $cases = @(
            [pscustomobject]@{ Leaf = 'status.json'; Value = [ordered]@{ schemaVersion = 1; session = [ordered]@{} }; Flag = 'StatusRebuildRequired' },
            [pscustomobject]@{ Leaf = 'verified-packages.json'; Value = [ordered]@{ schemaVersion = 1; packages = [ordered]@{ 'wrong|key|value' = (New-CcodVerifiedRecord) } }; Flag = 'AutomaticCandidateTrialsAllowed' },
            [pscustomobject]@{ Leaf = 'verified-packages.json'; Value = [ordered]@{ schemaVersion = 1; packages = [ordered]@{ 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1' = ([ordered]@{ packageFullName='pkg'; packageVersion='1.0.0.0'; appAsarSha256=('a' * 64); runtimeId='runtime-1'; staticClassification='CandidateCompatible'; dynamicOutcome='Failed'; probeState='Invalid'; confirmedAtUtc='bad' }) } }; Flag = 'AutomaticCandidateTrialsAllowed' },
            [pscustomobject]@{ Leaf = 'settings.json'; Value = [ordered]@{ schemaVersion = '1'; automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates=@('C:\Node\node.exe'); updatedAtUtc='2030-02-03T04:05:06.0000000Z' }; Flag = 'AutomationEnabled' },
            [pscustomobject]@{ Leaf = 'settings.json'; Value = [ordered]@{ schemaVersion = 1; automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates='C:\Node\node.exe'; updatedAtUtc='2030-02-03T04:05:06.0000000Z' }; Flag = 'AutomationEnabled' },
            [pscustomobject]@{ Leaf = 'settings.json'; Value = [ordered]@{ schemaVersion = 1; automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates=@('C:node.exe'); updatedAtUtc='2030-02-03T04:05:06.0000000Z' }; Flag = 'AutomationEnabled' },
            [pscustomobject]@{ Leaf = 'settings.json'; Value = [ordered]@{ schemaVersion = 1; automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates=@('\\Node\node.exe'); updatedAtUtc='2030-02-03T04:05:06.0000000Z' }; Flag = 'AutomationEnabled' },
            [pscustomobject]@{ Leaf = 'settings.json'; Value = [ordered]@{ schemaVersion = 1; automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates=@('C:\Node\node.exe'); updatedAtUtc='2030-02-03T04:05:06Z' }; Flag = 'AutomationEnabled' }
        )
        foreach ($case in $cases) {
            $state = Join-Path $root ('strict-' + $case.Leaf + '-' + [Guid]::NewGuid().ToString('N'))
            Initialize-CcodStateFixture -StateRoot $state
            Write-CcodStateJson -StateRoot $state -Leaf $case.Leaf -Value $case.Value
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodTrue ($loaded.Damage.PSObject.Properties[$case.Leaf] -ne $null) "$($case.Leaf) invalid shape is damage"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter ($case.Leaf + '.corrupt.*')).Count "$($case.Leaf) invalid shape is quarantined"
        }
    }

    Invoke-CcodTest 'suppresses a previously attempted current package build key' {
        $state = Join-Path $root 'suppression-history'
        Initialize-CcodStateFixture -StateRoot $state
        $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
        Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion = 1; packages = [ordered]@{ $key = (New-CcodVerifiedRecord) } })
        $loaded = Read-CcodState -StateRoot $state -CurrentSuppressionKey $key -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $false $loaded.AutomaticCandidateTrialsAllowed 'any recorded outcome suppresses another automatic trial for the same build'
        Assert-CcodEqual $false (Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)).AutomaticCandidateTrialsAllowed 'no current build key cannot authorize a trial'
    }

    Invoke-CcodTest 'updates each consent without changing the other consent or verified candidates' {
        $state = Join-Path $root 'setters'
        Initialize-CcodStateFixture -StateRoot $state
        Set-CcodAutomationEnabled -StateRoot $state -Enabled $false -Adapters (New-CcodStateTestAdapters) | Out-Null
        $afterAutomation = Read-CcodSettings -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $false $afterAutomation.automationEnabled 'automation setter changes only automation'
        Assert-CcodEqual $true $afterAutomation.candidateCompatibleOptIn 'automation setter preserves candidate opt-in'
        Assert-CcodEqual 'C:\Node\node.exe' $afterAutomation.nodeCandidates[0] 'automation setter preserves verified candidates'
        Assert-CcodEqual $false (Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)).AutomaticCandidateTrialsAllowed 'candidate trial requires automation as well as the preserved opt-in'
        Set-CcodAutomationEnabled -StateRoot $state -Enabled $true -Adapters (New-CcodStateTestAdapters) | Out-Null
        Set-CcodCandidateCompatibleOptIn -StateRoot $state -Enabled $false -Adapters (New-CcodStateTestAdapters) | Out-Null
        $afterOptIn = Read-CcodSettings -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $true $afterOptIn.automationEnabled 'candidate opt-in setter preserves automation'
        Assert-CcodEqual $false $afterOptIn.candidateCompatibleOptIn 'candidate opt-in setter changes only its own consent'
        Assert-CcodEqual 'C:\Node\node.exe' $afterOptIn.nodeCandidates[0] 'candidate opt-in setter preserves verified candidates'
        Assert-CcodEqual $false (Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)).AutomaticCandidateTrialsAllowed 'candidate trial also requires explicit candidate opt-in'
    }

    Invoke-CcodTest 'repair preserves quarantined evidence and keeps both consent switches off' {
        $state = Join-Path $root 'repair'
        Initialize-CcodStateFixture -StateRoot $state
        Set-CcodStateDamage -StateRoot $state -Leaf 'settings.json' -Variant 'malformed'
        Repair-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters) | Out-Null
        $repaired = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $false $repaired.Settings.automationEnabled 'repair leaves automation explicitly off'
        Assert-CcodEqual $false $repaired.Settings.candidateCompatibleOptIn 'repair leaves candidate opt-in explicitly off'
        Assert-CcodTrue (@(Get-ChildItem -LiteralPath $state -File -Filter 'settings.json.corrupt.*').Count -eq 1) 'repair retains the damaged settings evidence'
    }

    Invoke-CcodTest 'constructs stable keys and resolves device-key store without touching it' {
        Assert-CcodEqual '100|2026-08-02T00:00:00.0000000Z' (Get-CcodAttemptKey -Pid 100 -CreationTimeUtc '2026-08-02T00:00:00.0000000Z') 'attempt key is PID plus creation time'
        Assert-CcodEqual '100|created|transaction' (Get-CcodRecoveryIgnoreKey -Pid 100 -CreationTimeUtc 'created' -TransactionId 'transaction') 'recovery key includes transaction lifetime'
        Assert-CcodEqual 'pkg|hash|runtime' (Get-CcodSuppressionKey -PackageFullName 'pkg' -AppAsarSha256 'hash' -RuntimeId 'runtime') 'suppression key includes runtime lifetime'
        Assert-CcodEqual 'pkg|hash' (Get-CcodStaticKey -PackageFullName 'pkg' -AppAsarSha256 'hash') 'static key excludes runtime lifetime'
        $oldCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('CODEX_HOME', (Join-Path $root 'codex-home'), 'Process')
            $path = Resolve-CcodDeviceKeyStorePath
            Assert-CcodEqual (Join-Path (Join-Path $root 'codex-home') 'remote-control-device-keys.windows.json') $path 'absolute CODEX_HOME only determines the shared device-key path'
            Assert-CcodEqual $false ([IO.File]::Exists($path)) 'resolving the device-key path does not create or touch the key file'
            [Environment]::SetEnvironmentVariable('CODEX_HOME', 'relative-codex-home', 'Process')
            Assert-CcodThrows { Resolve-CcodDeviceKeyStorePath } 'CCOD_CODEX_HOME_INVALID'
        } finally {
            [Environment]::SetEnvironmentVariable('CODEX_HOME', $oldCodexHome, 'Process')
        }
    }
} catch {
    Write-Error $_
    exit 1
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
