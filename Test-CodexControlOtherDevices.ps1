[CmdletBinding()]
param(
    [switch]$Json,
    [string[]]$NodePath
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$checker = Join-Path $projectRoot 'src\check-package.mjs'
Import-Module (Join-Path $projectRoot 'src\persistence\modules\CompatibilityProbe.psm1') -Force
$reasons = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

$result = [ordered]@{
    Ready = $false
    OperatingSystem = [System.Environment]::OSVersion.VersionString
    IsWindows = $env:OS -eq 'Windows_NT' -or $PSVersionTable.PSEdition -eq 'Desktop'
    PackageInstalled = $false
    PackageFullName = $null
    PackageFamilyName = $null
    PackageVersion = $null
    ExecutablePath = $null
    AppAsarPath = $null
    NodePath = $null
    NodeVersion = $null
    NodeMajor = $null
    NodeSupported = $false
    NodeCapabilities = $null
    SchemaVersion = $null
    StaticClassification = 'UnknownOrIncompatible'
    AppAsarSha256 = $null
    PackageSignatures = $null
    AffectedBuildDetected = $false
    Reasons = $reasons
    Warnings = $warnings
}

try {
    if (-not $result.IsWindows) {
        $reasons.Add('This workaround supports Windows only.')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME) -and
        -not [System.IO.Path]::IsPathRooted($env:CODEX_HOME)) {
        $reasons.Add('CODEX_HOME must be an absolute path so launch and rollback resolve the same key store.')
    }

    $nodeCandidates = @($NodePath)
    if (-not $PSBoundParameters.ContainsKey('NodePath')) {
        $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($nodeCommand) {
            $nodeCandidates = @([IO.Path]::GetFullPath([string]$nodeCommand.Source))
        }
    }
    $probe = Invoke-CcodStaticProbe -NodeCandidates $nodeCandidates -CheckerPath $checker
    foreach ($name in @('PackageInstalled', 'PackageFullName', 'PackageFamilyName', 'PackageVersion', 'ExecutablePath', 'AppAsarPath', 'NodePath', 'NodeVersion', 'NodeMajor', 'NodeSupported', 'NodeCapabilities', 'SchemaVersion', 'StaticClassification', 'AppAsarSha256', 'PackageSignatures', 'AffectedBuildDetected')) {
        $result[$name] = $probe.$name
    }

    switch ($probe.Code) {
        'PACKAGE_NOT_FOUND' { $reasons.Add('The Microsoft Store/MSIX OpenAI.Codex package is not installed.') }
        'PACKAGE_AMBIGUOUS' { $reasons.Add('Expected exactly one current-user OpenAI.Codex package.') }
        'PACKAGE_FAMILY_MISMATCH' { $reasons.Add('The installed package family is not the expected OpenAI.Codex package.') }
        'PACKAGE_LOCATION_INVALID' { $reasons.Add('The installed OpenAI.Codex package has an invalid install location.') }
        'NODE_NOT_FOUND' { $reasons.Add('Node.js 22 or newer is required but no supplied node.exe path is valid.') }
        'NODE_VERSION_UNSUPPORTED' { $reasons.Add("Node.js 22 or newer is required; found $($probe.NodeVersion).") }
        'CHECKER_PATH_INVALID' { $reasons.Add("Package checker path is invalid: $checker") }
        'CHECKER_NOT_FOUND' { $reasons.Add("Package checker was not found: $checker") }
        'CHECKER_FAILED' { $reasons.Add('Could not inspect the installed Codex package.') }
        'CHECKER_JSON_INVALID' { $reasons.Add('The package checker emitted malformed JSON.') }
        'CHECKER_SCHEMA_INVALID' { $reasons.Add('The package checker emitted incomplete or inconsistent evidence.') }
    }
    if ($probe.Code -eq 'CHECKER_OK' -and -not $probe.AffectedBuildDetected) {
        $reasons.Add('The installed package does not match the known Windows controller bug signature. Refusing to inject into an unreviewed build.')
    }

    $warnings.Add('Account authentication cannot be verified locally. Complete any MFA, SSO, or passkey required by the account/workspace; the tested account required MFA before enrollment.')
    $warnings.Add('The renderer debug endpoint remains on 127.0.0.1 until Codex exits; run only on a trusted machine.')

    $result.Ready = $result.IsWindows -and
        $result.PackageInstalled -and
        $result.NodeSupported -and
        $result.AffectedBuildDetected -and
        $reasons.Count -eq 0
} catch {
    $reasons.Add($_.Exception.Message)
    $result.Ready = $false
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8 -Compress
} else {
    Write-Host ''
    Write-Host 'Codex Control other devices - compatibility check' -ForegroundColor Cyan
    Write-Host ('  Ready:            {0}' -f $result.Ready)
    $packageDisplay = if ($null -eq $result.PackageVersion) { 'not found' } else { $result.PackageVersion }
    $nodeDisplay = if ($null -eq $result.NodeVersion) { 'not found' } else { $result.NodeVersion }
    Write-Host ('  Codex package:    {0}' -f $packageDisplay)
    Write-Host ('  Node.js:          {0}' -f $nodeDisplay)
    Write-Host ('  Heuristic match:  {0}' -f $result.AffectedBuildDetected)
    Write-Host ('  Static class:     {0}' -f $result.StaticClassification)

    if ($reasons.Count -gt 0) {
        Write-Host ''
        Write-Host 'Blocking findings:' -ForegroundColor Red
        foreach ($reason in $reasons) { Write-Host "  - $reason" }
    }

    Write-Host ''
    Write-Host 'Security notes:' -ForegroundColor Yellow
    foreach ($warning in $warnings) { Write-Host "  - $warning" }
    Write-Host ''
}

if (-not $result.Ready) { exit 1 }
