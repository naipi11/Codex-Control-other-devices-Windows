$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\CompatibilityProbe.psm1') -Force

function New-CcodCheckerJson {
    param(
        [string]$Classification = 'CandidateCompatible',
        [bool]$NativeModulePresent = $false,
        [hashtable]$Signatures = @{ invertedGate = $true; deviceKeyModuleReference = $true; macOnlyGuard = $true; windowsControllerUi = $true }
    )

    return (@{
        schemaVersion = 1
        affected = $Classification -eq 'CandidateCompatible'
        classification = $Classification
        appAsarSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        nativeModulePresent = $NativeModulePresent
        signatures = $Signatures
    } | ConvertTo-Json -Compress)
}

function New-CcodProbeAdapters {
    param(
        [string]$CheckerJson = (New-CcodCheckerJson),
        [int]$CheckerExitCode = 0,
        [string]$NodeVersion = 'v22.23.1',
        [string]$FamilyName = 'OpenAI.Codex_2p2nqsd0c76g0',
        [bool]$NodeExists = $true,
        [bool]$ExecutableExists = $true,
        [bool]$OmitPackageFullName = $false,
        [string]$OmitPackageProperty = $null,
        $InvocationCounter = $null
    )

    $checker = $CheckerJson
    $exitCode = $CheckerExitCode
    $version = $NodeVersion
    $family = $FamilyName
    $exists = $NodeExists
    $executableExists = $ExecutableExists
    $omitFullName = $OmitPackageFullName
    $omitProperty = $OmitPackageProperty
    $counter = $InvocationCounter
    return @{
        GetPackage = {
            $package = [ordered]@{
                PackageFamilyName = $family
                Version = '1.0.0.0'
                InstallLocation = 'C:\Fake\Codex'
            }
            if (-not $omitFullName) { $package.PackageFullName = 'OpenAI.Codex_1_x64__2p2nqsd0c76g0' }
            if (-not [string]::IsNullOrWhiteSpace($omitProperty)) { [void]$package.Remove($omitProperty) }
            [pscustomobject]$package
        }.GetNewClosure()
        TestPath = {
            param($Path)
            if ($Path -eq 'C:\Fake\Codex\app\ChatGPT.exe') { return $executableExists }
            if ($Path -like 'C:\Node\*') { return $exists }
            return $true
        }.GetNewClosure()
        GetFullPath = { param($Path) $Path }
        GetNodeVersion = {
            param($NodePath)
            if ($null -ne $counter) { $counter.NodeVersionCount++ }
            $version
        }.GetNewClosure()
        InvokeNode = {
            param($NodePath, $Arguments)
            if ($null -ne $counter) { $counter.Count++ }
            [pscustomobject]@{ ExitCode = $exitCode; Stdout = $checker; Stderr = 'checker stderr' }
        }.GetNewClosure()
    }
}

try {
    Invoke-CcodTest 'classifies complete candidate evidence as eligible for one dynamic trial' {
        $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters (New-CcodProbeAdapters)
        Assert-CcodEqual 'CandidateCompatible' $result.StaticClassification 'all evidence permits one dynamic trial'
        Assert-CcodEqual 'OpenAI.Codex_2p2nqsd0c76g0' $result.FamilyName 'family retained'
        Assert-CcodEqual $true $result.Ready 'complete candidate evidence is ready'
        Assert-CcodEqual $true $result.AffectedBuildDetected 'candidate retains backward-compatible affected field'
        Assert-CcodEqual 'C:\Node\node.exe' $result.NodePath 'only the normalized installer candidate is retained'
        Assert-CcodEqual 1 $result.SchemaVersion 'checker schema is retained'
    }

    Invoke-CcodTest 'fails closed when the native device-key module is present' {
        $json = New-CcodCheckerJson -Classification 'NativeModulePresent' -NativeModulePresent $true
        $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters (New-CcodProbeAdapters -CheckerJson $json)
        Assert-CcodEqual 'NativeModulePresent' $result.StaticClassification 'native module has its distinct classification'
        Assert-CcodEqual $false $result.Ready 'native module never permits a trial'
        Assert-CcodEqual $false $result.AffectedBuildDetected 'native module does not look affected'
    }

    Invoke-CcodTest 'fails closed when one sentinel is absent' {
        $json = New-CcodCheckerJson -Classification 'UnknownOrIncompatible' -Signatures @{ invertedGate = $true; deviceKeyModuleReference = $true; macOnlyGuard = $true; windowsControllerUi = $false }
        $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters (New-CcodProbeAdapters -CheckerJson $json)
        Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification 'missing sentinel must not be treated as a compatible build'
        Assert-CcodEqual $false $result.Ready 'missing sentinel fails closed'
    }

    Invoke-CcodTest 'fails closed when the checker exits unsuccessfully' {
        $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters (New-CcodProbeAdapters -CheckerExitCode 1)
        Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification 'checker failure is uncertain evidence'
        Assert-CcodEqual $false $result.Ready 'checker failure does not throw or permit a trial'
    }

    Invoke-CcodTest 'rejects unsupported Node 21 before invoking the checker' {
        $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters (New-CcodProbeAdapters -NodeVersion 'v21.9.0')
        Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification 'Node 21 cannot validate a package'
        Assert-CcodEqual $false $result.Ready 'unsupported Node fails closed'
        Assert-CcodEqual $false $result.NodeCapabilities.Supported 'capabilities expose the Node version gate'
    }

    Invoke-CcodTest 'rejects malformed checker JSON without changing process state' {
        $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters (New-CcodProbeAdapters -CheckerJson '{not json')
        Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification 'malformed JSON is uncertain evidence'
        Assert-CcodEqual $false $result.Ready 'malformed JSON fails closed without throwing'
    }

    Invoke-CcodTest 'rejects a relative Node candidate even if the fake says it exists' {
        $result = Invoke-CcodStaticProbe -NodeCandidates @('node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters (New-CcodProbeAdapters)
        Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification 'relative paths cannot become trusted Node paths'
        Assert-CcodEqual $false $result.Ready 'relative Node candidates fail closed'
        Assert-CcodEqual $null $result.NodePath 'relative Node path is not retained'
    }

    Invoke-CcodTest 'fails closed when no supplied Node candidate exists' {
        $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\missing.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters (New-CcodProbeAdapters -NodeExists $false)
        Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification 'missing candidates are uncertain evidence'
        Assert-CcodEqual $false $result.Ready 'missing candidates do not permit a trial'
        Assert-CcodEqual $null $result.NodePath 'no non-existing path is retained'
    }

    Invoke-CcodTest 'rejects an unexpected current package family before Node invocation' {
        $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters (New-CcodProbeAdapters -FamilyName 'Other.Family_123')
        Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification 'unexpected family cannot be inspected'
        Assert-CcodEqual $false $result.Ready 'family mismatch fails closed'
        Assert-CcodEqual 'PACKAGE_FAMILY_MISMATCH' $result.Code 'family mismatch has an auditable code'
    }

    Invoke-CcodTest 'fails closed before checker invocation when the current package executable is absent' {
        $calls = [pscustomobject]@{ Count = 0; NodeVersionCount = 0 }
        $adapters = New-CcodProbeAdapters -ExecutableExists $false -InvocationCounter $calls
        $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters $adapters
        Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification 'missing executable is not a usable package entrypoint'
        Assert-CcodEqual $false $result.Ready 'missing executable fails closed'
        Assert-CcodEqual 'PACKAGE_EXECUTABLE_MISSING' $result.Code 'missing executable has an auditable code'
        Assert-CcodEqual 0 $calls.NodeVersionCount 'missing executable must not invoke Node'
        Assert-CcodEqual 0 $calls.Count 'missing executable must not invoke the package checker'
    }

    Invoke-CcodTest 'fails closed for an empty Node candidate list without PATH discovery' {
        $calls = [pscustomobject]@{ Count = 0; NodeVersionCount = 0 }
        $adapters = New-CcodProbeAdapters -InvocationCounter $calls
        $result = Invoke-CcodStaticProbe -NodeCandidates @() -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters $adapters
        Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification 'an empty supplied list is not a trusted Node source'
        Assert-CcodEqual $false $result.Ready 'empty Node list fails closed'
        Assert-CcodEqual 'NODE_NOT_FOUND' $result.Code 'empty Node list has an auditable code'
        Assert-CcodEqual 0 $calls.NodeVersionCount 'empty Node list must not invoke Node'
        Assert-CcodEqual 0 $calls.Count 'empty Node list must not invoke the package checker'
    }

    Invoke-CcodTest 'fails closed for incomplete package metadata without Node invocation' {
        $calls = [pscustomobject]@{ Count = 0; NodeVersionCount = 0 }
        $adapters = New-CcodProbeAdapters -OmitPackageFullName $true -InvocationCounter $calls
        $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters $adapters
        Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification 'incomplete package metadata is uncertain evidence'
        Assert-CcodEqual $false $result.Ready 'incomplete package metadata fails closed'
        Assert-CcodEqual 'PACKAGE_METADATA_INVALID' $result.Code 'incomplete metadata has an auditable code'
        Assert-CcodEqual 0 $calls.NodeVersionCount 'incomplete metadata must not invoke Node'
        Assert-CcodEqual 0 $calls.Count 'incomplete metadata must not invoke the package checker'
    }

    Invoke-CcodTest 'fails closed for every missing required package metadata field' {
        foreach ($missing in @('PackageFullName', 'PackageFamilyName', 'Version', 'InstallLocation')) {
            $calls = [pscustomobject]@{ Count = 0; NodeVersionCount = 0 }
            $adapters = New-CcodProbeAdapters -OmitPackageProperty $missing -InvocationCounter $calls
            $result = Invoke-CcodStaticProbe -NodeCandidates @('C:\Node\node.exe') -CheckerPath 'C:\Runtime\check-package.mjs' -Adapters $adapters
            Assert-CcodEqual 'UnknownOrIncompatible' $result.StaticClassification "missing $missing is uncertain evidence"
            Assert-CcodEqual $false $result.Ready "missing $missing fails closed"
            Assert-CcodEqual 'PACKAGE_METADATA_INVALID' $result.Code "missing $missing has an auditable code"
            Assert-CcodEqual 0 $calls.NodeVersionCount "missing $missing must not invoke Node"
            Assert-CcodEqual 0 $calls.Count "missing $missing must not invoke the package checker"
        }
    }
} catch {
    Write-Error $_
    exit 1
}
