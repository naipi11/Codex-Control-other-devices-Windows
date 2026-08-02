$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\StateStore.psm1') -Force

function New-CcodStateTestAdapters {
    $fixedUtc = [DateTime]::Parse('2030-02-03T04:05:06.0000000Z').ToUniversalTime()
    return @{
        UtcNow = { $fixedUtc }.GetNewClosure()
        NewGuid = { [Guid]'11111111-2222-3333-4444-555555555555' }
    }
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-state-selftest-' + [Guid]::NewGuid().ToString('N'))
try {
    Invoke-CcodTest 'initializes independent automation consent and installer-verified absolute Node paths' {
        $state = Join-Path $root 'initial'
        Initialize-CcodStateFixture -StateRoot $state
        $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)

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
        Assert-CcodThrows { Write-CcodStatus -StateRoot $state -Status ([ordered]@{ schemaVersion = 1; session = 'Active' }) } 'CCOD_LIVE_PROBE_REQUIRED'
        Write-CcodStatus -StateRoot $state -Status ([ordered]@{ schemaVersion = 1; session = 'Active' }) -LiveProbeResult ([pscustomobject]@{ Valid = $true }) | Out-Null
        Assert-CcodEqual 'Active' (Read-CcodStatus -StateRoot $state).session 'a supplied live probe permits status reconstruction'
    }

    Invoke-CcodTest 'updates each consent without changing the other consent or verified candidates' {
        $state = Join-Path $root 'setters'
        Initialize-CcodStateFixture -StateRoot $state
        Set-CcodAutomationEnabled -StateRoot $state -Enabled $false -Adapters (New-CcodStateTestAdapters) | Out-Null
        $afterAutomation = Read-CcodSettings -StateRoot $state
        Assert-CcodEqual $false $afterAutomation.automationEnabled 'automation setter changes only automation'
        Assert-CcodEqual $true $afterAutomation.candidateCompatibleOptIn 'automation setter preserves candidate opt-in'
        Assert-CcodEqual 'C:\Node\node.exe' $afterAutomation.nodeCandidates[0] 'automation setter preserves verified candidates'
        Assert-CcodEqual $false (Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)).AutomaticCandidateTrialsAllowed 'candidate trial requires automation as well as the preserved opt-in'
        Set-CcodAutomationEnabled -StateRoot $state -Enabled $true -Adapters (New-CcodStateTestAdapters) | Out-Null
        Set-CcodCandidateCompatibleOptIn -StateRoot $state -Enabled $false -Adapters (New-CcodStateTestAdapters) | Out-Null
        $afterOptIn = Read-CcodSettings -StateRoot $state
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
